{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE TemplateHaskell            #-}
module Network.Haskoin.Store.Block
    ( blockGetBest
    , blockGetHeight
    , blockGet
    , blockGetTx
    , blockGetAddrTxs
    , blockGetAddrUnspent
    , blockGetAddrBalance
    , blockStore
    ) where

import           Control.Applicative
import           Control.Arrow
import           Control.Concurrent.NQE
import           Control.Monad.Base
import           Control.Monad.Catch
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.Trans.Control
import           Control.Monad.Trans.Maybe
import qualified Data.ByteString              as BS
import           Data.Conduit                 (($$))
import qualified Data.Conduit.List            as CL
import           Data.Default
import           Data.Function
import           Data.List
import qualified Data.Map.Strict              as M
import           Data.Maybe
import           Data.Monoid
import           Data.Serialize               as S
import           Data.String.Conversions
import           Data.Text                    (Text)
import           Data.Word
import           Database.LevelDB             (runResourceT)
import qualified Database.LevelDB             as LevelDB
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Crypto
import           Network.Haskoin.Node
import           Network.Haskoin.Script
import           Network.Haskoin.Store.Common
import           Network.Haskoin.Store.Types
import           Network.Haskoin.Transaction

blockStore ::
       ( MonadBase IO m
       , MonadBaseControl IO m
       , MonadThrow m
       , MonadLoggerIO m
       , MonadMask m
       , Forall (Pure m)
       )
    => BlockConfig
    -> m ()
blockStore BlockConfig {..} =
    runResourceT $ do
        let opts = def {LevelDB.createIfMissing = True, LevelDB.maxOpenFiles = 128}
        db <- LevelDB.open blockConfDir opts
        $(logDebug) $ logMe <> "Database opened"
        pbox <- liftIO $ newTVarIO []
        dbox <- liftIO $ newTVarIO []
        ubox <-
            liftIO $
            newTVarIO
                UnspentCache
                { unspentCache = M.empty
                , unspentCacheBlocks = M.empty
                , unspentCacheCount = 0
                }
        peerbox <- liftIO $ newTVarIO Nothing
        runReaderT
            (syncBlocks >> run)
            BlockRead
            { mySelf = blockConfMailbox
            , myBlockDB = db
            , myDir = blockConfDir
            , myChain = blockConfChain
            , myManager = blockConfManager
            , myListener = blockConfListener
            , myPending = pbox
            , myDownloaded = dbox
            , myPeer = peerbox
            , myUnspentCache = ubox
            , myCacheNo = blockConfCacheNo
            , myBlockNo = blockConfBlockNo
            }
  where
    run =
        forever $ do
            $(logDebug) $ logMe <> "Awaiting message"
            msg <- receive blockConfMailbox
            processBlockMessage msg

spendAddr ::
       AddrUnspentKey
    -> AddrUnspentValue
    -> SpentValue
    -> (AddrSpentKey, AddrSpentValue)
spendAddr uk uv s = (sk, sv)
  where
    sk =
        AddrSpentKey
        { addrSpentKey = addrUnspentKey uk
        , addrSpentHeight = addrUnspentHeight uk
        , addrSpentOutPoint = addrUnspentOutPoint uk
        }
    sv =
        AddrSpentValue
        { addrSpentValue = s
        , addrSpentOutput = addrUnspentOutput uv
        , addrSpentPos = addrUnspentPos uv
        }

unspendAddr :: AddrSpentKey -> AddrSpentValue -> (AddrUnspentKey, AddrUnspentValue)
unspendAddr sk sv = (uk, uv)
  where
    uk = AddrUnspentKey
         { addrUnspentKey = addrSpentKey sk
         , addrUnspentHeight = addrSpentHeight sk
         , addrUnspentOutPoint = addrSpentOutPoint sk
         }
    uv = AddrUnspentValue
         { addrUnspentOutput = addrSpentOutput sv
         , addrUnspentPos = addrSpentPos sv
         }


getBestBlockHash :: MonadBlock m => m BlockHash
getBestBlockHash = do
    $(logDebug) $ logMe <> "Processing best block request from database"
    db <- asks myBlockDB
    BestBlockKey `retrieveValue` db >>= \case
        Nothing -> do
            importBlock genesisBlock
            $(logDebug) $ logMe <> "Stored genesis"
            return (headerHash genesisHeader)
        Just bb -> return bb

getBlockAtHeight :: MonadBlock m => BlockHeight -> m (Maybe BlockValue)
getBlockAtHeight height = do
    $(logDebug) $
        logMe <> "Processing block request at height: " <> cs (show height)
    db <- asks myBlockDB
    runMaybeT $ do
        h <- MaybeT $ HeightKey height `retrieveValue` db
        MaybeT $ BlockKey h `retrieveValue` db

getBlockValue :: MonadBlock m => BlockHash -> m (Maybe BlockValue)
getBlockValue bh = do
    db <- asks myBlockDB
    BlockKey bh `retrieveValue` db

getAddrSpent :: MonadBlock m => Address -> m [(AddrSpentKey, AddrSpentValue)]
getAddrSpent addr = do
    db <- asks myBlockDB
    MultiAddrSpentKey addr `valuesForKey` db $$ CL.consume

getAddrUnspent ::
       MonadBlock m => Address -> m [(AddrUnspentKey, AddrUnspentValue)]
getAddrUnspent addr = do
    db <- asks myBlockDB
    MultiAddrUnspentKey addr `valuesForKey` db $$ CL.consume

getAddrBalance ::
    MonadBlock m => Address -> m (Maybe AddressBalance)
getAddrBalance addr =
    runMaybeT $ do
        db <- asks myBlockDB
        bal <- MaybeT $ MultiBalance addr `valuesForKey` db $$ CL.head
        best <- fmap (fromMaybe e) $ BestBlockKey `retrieveValue` db
        block <- fmap (fromMaybe e) $ BlockKey best `retrieveValue` db
        let h = blockValueHeight block
            bs = second (i h) bal
            is = sum (map immatureValue (balanceImmature (snd bs)))
            ub = balanceValue (snd bs)
        return
            AddressBalance
            { addressBalAddress = addr
            , addressBalConfirmed = ub
            , addressBalUnconfirmed = ub
            , addressBalImmature = is
            , addressBalBlock =
                  BlockRef
                  { blockRefHeight = blockValueHeight block
                  , blockRefHash = best
                  , blockRefMainChain = True
                  }
            }
  where
    e = error "Colud not retrieve best block from database"
    i h BalanceValue {..} =
        let f Immature {..} = blockRefHeight immatureBlock <= h - 99
            (ms, is) = partition f balanceImmature
        in BalanceValue
           { balanceValue = balanceValue + sum (map immatureValue ms)
           , balanceImmature = is
           }

getStoredTx :: MonadBlock m => TxHash -> m (Maybe DetailedTx)
getStoredTx th =
    runMaybeT $ do
        db <- asks myBlockDB
        xs <- valuesForKey (BaseTxKey th) db $$ CL.consume
        TxValue {..} <- MaybeT (return (findTx xs))
        let ss = filterSpents xs
        return (DetailedTx txValue txValueBlock ss txValueOuts)
  where
    findTx xs =
        listToMaybe
            [ v
            | (f, s) <- xs
            , case f of
                  MultiTxKey {} -> True
                  _             -> False
            , let MultiTx v = s
            ]
    filterSpents xs =
        [ (k, v)
        | (f, s) <- xs
        , case f of
              MultiTxKeySpent {} -> True
              _                  -> False
        , let MultiTxKeySpent k = f
        , let MultiTxSpent v = s
        ]

revertBestBlock :: MonadBlock m => m ()
revertBestBlock =
    void . runMaybeT $ do
        best <- getBestBlockHash
        guard (best /= headerHash genesisHeader)
        $(logDebug) $ logMe <> "Reverting block " <> logShow best
        ch <- asks myChain
        bn <-
            chainGetBlock best ch >>= \case
                Just bn -> return bn
                Nothing -> do
                    $(logError) $
                        logMe <> "Could not obtain best block from chain"
                    error "BUG: Could not obtain best block from chain"
        BlockValue {..} <-
            getBlockValue best >>= \case
                Just b -> return b
                Nothing -> do
                    $(logError) $ logMe <> "Could not retrieve best block"
                    error "BUG: Could not retrieve best block"
        txs <- mapMaybe (fmap txValue) <$> getBlockTxs blockValueTxs
        db <- asks myBlockDB
        let block = Block blockValueHeader txs
        blockOps <- blockBatchOps block (nodeHeight bn) (nodeWork bn) False
        LevelDB.write db def blockOps

syncBlocks :: MonadBlock m => m ()
syncBlocks = do
    mgr <- asks myManager
    peerbox <- asks myPeer
    pbox <- asks myPending
    ch <- asks myChain
    chainBest <- chainGetBest ch
    let bestHash = headerHash (nodeHeader chainBest)
    myBestHash <- getBestBlockHash
    void . runMaybeT $ do
        guard (myBestHash /= bestHash)
        liftIO (readTVarIO pbox) >>= guard . null
        myBest <- MaybeT (chainGetBlock myBestHash ch)
        splitBlock <- chainGetSplitBlock chainBest myBest ch
        let splitHash = headerHash (nodeHeader splitBlock)
        $(logDebug) $ logMe <> "Split block: " <> logShow splitHash
        revertUntil myBest splitBlock
        blockNo <- asks myBlockNo
        let chainHeight = nodeHeight chainBest
            splitHeight = nodeHeight splitBlock
            topHeight = min chainHeight (splitHeight + blockNo + 1)
        targetBlock <-
            MaybeT $
            if topHeight == chainHeight
                then return (Just chainBest)
                else chainGetAncestor topHeight chainBest ch
        requestBlocks <-
            (++ [chainBest | targetBlock == chainBest]) <$>
            chainGetParents (splitHeight + 1) targetBlock ch
        p <-
            MaybeT (liftIO (readTVarIO peerbox)) <|>
            MaybeT (listToMaybe <$> managerGetPeers mgr)
        liftIO . atomically $ writeTVar peerbox (Just p)
        downloadBlocks p (map (headerHash . nodeHeader) requestBlocks)
  where
    revertUntil myBest splitBlock
        | myBest == splitBlock = return ()
        | otherwise = do
            revertBestBlock
            newBestHash <- getBestBlockHash
            $(logDebug) $ logMe <> "Reverted to block " <> logShow newBestHash
            ch <- asks myChain
            newBest <- MaybeT (chainGetBlock newBestHash ch)
            revertUntil newBest splitBlock
    downloadBlocks p bhs = do
        $(logDebug) $
            logMe <> "Downloading " <> logShow (length bhs) <> " blocks"
        getBlocks p bhs
        pbox <- asks myPending
        liftIO . atomically $ writeTVar pbox bhs

importBlocks :: MonadBlock m => m ()
importBlocks = do
    dbox <- asks myDownloaded
    best <- getBestBlockHash
    m <- liftIO . atomically $ do
        ds <- readTVar dbox
        case find ((== best) . prevBlock . blockHeader) ds of
            Nothing -> return Nothing
            Just b -> do
                modifyTVar dbox (filter (/= b))
                return (Just b)
    case m of
        Just block -> do
            importBlock block
            mbox <- asks mySelf
            BlockProcess `send` mbox
        Nothing    -> syncBlocks

importBlock :: MonadBlock m => Block -> m ()
importBlock block@Block {..} = do
    $(logDebug) $ logMe <> "Importing block " <> logShow blockHash
    ch <- asks myChain
    bn <-
        chainGetBlock blockHash ch >>= \case
            Just bn -> return bn
            Nothing -> do
                $(logError) $ logMe <> "Could not obtain block from chain"
                error "BUG: Could not obtain block from chain"
    blockOps <- blockBatchOps block (nodeHeight bn) (nodeWork bn) True
    db <- asks myBlockDB
    LevelDB.write db def blockOps
    $(logDebug) $ logMe <> "Stored block " <> logShow (nodeHeight bn)
    l <- asks myListener
    liftIO . atomically . l $ BestBlock blockHash
  where
    blockHash = headerHash blockHeader

getBlockTxs :: MonadBlock m => [TxHash] -> m [Maybe TxValue]
getBlockTxs hs = do
    db <- asks myBlockDB
    forM hs (\h -> retrieveValue (TxKey h) db)

blockBatchOps :: MonadBlock m =>
       Block -> BlockHeight -> BlockWork -> Bool -> m [LevelDB.BatchOp]
blockBatchOps block@Block {..} height work main = do
    outputOps <- concat <$> mapM (outputBatchOps blockRef) blockTxns
    spent <- concat <$> zipWithM (spentOutputs blockRef) blockTxns [0 ..]
    spentOps <- concat <$> zipWithM (spentBatchOps blockRef) blockTxns [0 ..]
    txOps <- forM blockTxns (txBatchOp blockRef spent)
    addrOps <-
        concat <$> zipWithM (addrBatchOps blockRef spent) blockTxns [0 ..]
    balOps <- balanceBatchOps blockRef (map (fst . snd) spent) blockTxns
    unspentCachePrune
    return $
        concat
            [ [blockOp]
            , bestOp
            , heightOp
            , txOps
            , outputOps
            , spentOps
            , addrOps
            , balOps
            ]
  where
    blockHash = headerHash blockHeader
    blockKey = BlockKey blockHash
    txHashes = map txHash blockTxns
    size = fromIntegral (BS.length (S.encode block))
    blockValue = BlockValue height work blockHeader size main txHashes
    blockRef = BlockRef blockHash height main
    blockOp = insertOp blockKey blockValue
    bestOp = [insertOp BestBlockKey blockHash | main]
    heightKey = HeightKey height
    heightOp = [insertOp heightKey blockHash | main]

getOutput ::
       MonadBlock m
    => OutputKey
    -> m (Maybe OutputValue)
getOutput key = runMaybeT (fromCache <|> fromDB)
  where
    hash = outPointHash (outPoint key)
    index = outPointIndex (outPoint key)
    fromDB = do
        db <- asks myBlockDB
        $(logDebug) $
            logMe <> "Cache miss for output " <> cs (show hash) <> "/" <>
            cs (show index)
        MaybeT $ key `retrieveValue` db
    fromCache = do
        ubox <- asks myUnspentCache
        cache@UnspentCache {..} <- liftIO $ readTVarIO ubox
        m <- MaybeT . return $ M.lookup key unspentCache
        $(logDebug) $
            logMe <> "Cache hit for output " <> cs (show hash) <> " " <>
            cs (show index)
        liftIO . atomically $
            writeTVar
                ubox
                cache
                { unspentCache = M.delete key unspentCache
                , unspentCacheCount = unspentCacheCount - 1
                }
        return m


unspentCachePrune :: MonadBlock m => m ()
unspentCachePrune = do
    n <- asks myCacheNo
    ubox <- asks myUnspentCache
    cache <- liftIO (readTVarIO ubox)
    let new = clear (fromIntegral n) cache
        del = unspentCacheCount cache - unspentCacheCount new
    liftIO . atomically $ writeTVar ubox new
    $(logDebug) $
        logMe <> "Deleted " <> cs (show del) <> " of " <>
        cs (show (unspentCacheCount cache)) <>
        " entries from UTXO cache"
  where
    clear n c@UnspentCache {..}
        | unspentCacheCount < n = c
        | otherwise =
            let (del, keep) = M.splitAt 1 unspentCacheBlocks
                ks =
                    [ k
                    | keys <- M.elems del
                    , k <- keys
                    , isJust (M.lookup k unspentCache)
                    ]
                count = unspentCacheCount - length ks
                cache = foldl' (flip M.delete) unspentCache ks
            in clear
                   n
                   UnspentCache
                   { unspentCache = cache
                   , unspentCacheBlocks = keep
                   , unspentCacheCount = count
                   }

spentOutputs ::
       MonadBlock m
    => BlockRef
    -> Tx
    -> Word32 -- ^ position in block
    -> m [(OutputKey, (OutputValue, SpentValue))]
spentOutputs block tx pos =
    fmap catMaybes . forM (zip [0 ..] (txIn tx)) $ \(i, TxIn {..}) ->
        if outPointHash prevOutput == zero
            then return Nothing
            else do
                let key = OutputKey prevOutput
                val <- fromMaybe e <$> getOutput key
                let spent = SpentValue (txHash tx) i block pos
                return $ Just (key, (val, spent))
  where
    zero = "0000000000000000000000000000000000000000000000000000000000000000"
    e = error "Colud not retrieve information for output being spent"

balanceBatchOps ::
       MonadBlock m => BlockRef -> [OutputValue] -> [Tx] -> m [LevelDB.BatchOp]
balanceBatchOps block spent txs =
    if blockRefMainChain block
        then do
            bals <- catMaybes <$> mapM balance addrs
            let matBals = M.fromList $ map (uncurry update) bals
                finalBals = M.unionsWith j [matBals, addrBals, coinbaseBals]
            return $ map (uncurry insertOp) (M.toList finalBals)
        else return $
             map
                 (\a ->
                      deleteOp
                          BalanceKey {balanceAddress = a, balanceBlock = block})
                 addrs
  where
    j bv1 bv2 =
        let val = balanceValue bv1 + balanceValue bv2
            imm = balanceImmature bv1 ++ balanceImmature bv2
        in BalanceValue
           { balanceValue = val
           , balanceImmature =
                 sortBy (flip compare `on` (blockRefHeight . immatureBlock)) imm
           }
    mature = (<= blockRefHeight block - 99) . blockRefHeight . immatureBlock
    update BalanceKey {..} BalanceValue {..} =
        let (ms, is) = partition mature balanceImmature
            mbal = sum (map immatureValue ms)
            k =
                BalanceKey
                {balanceAddress = balanceAddress, balanceBlock = block}
            v =
                BalanceValue
                {balanceValue = balanceValue + mbal, balanceImmature = is}
        in (k, v)
    addrs = nub (M.keys addrMap ++ M.keys coinbaseMap)
    addrBals =
        let f addr amount =
                ( BalanceKey {balanceAddress = addr, balanceBlock = block}
                , BalanceValue {balanceValue = amount, balanceImmature = []})
        in M.fromList $ map (uncurry f) (M.assocs addrMap)
    coinbaseBals =
        let f addr amount =
                ( BalanceKey {balanceAddress = addr, balanceBlock = block}
                , BalanceValue
                  {balanceValue = 0, balanceImmature = [Immature block amount]})
        in M.fromList $ map (uncurry f) (M.assocs coinbaseMap)
    balance addr = do
        db <- asks myBlockDB
        MultiBalance addr `valuesForKey` db $$ CL.head
    addrMap = foldl' credit debits (concatMap txOut (tail txs))
    coinbaseMap = foldl' coinbase M.empty (txOut (head txs))
    debits = foldl' debit M.empty spent
    debit m OutputValue {..} =
        case scriptToAddressBS outScript of
            Nothing -> m
            Just a  -> M.insertWith subtract a (fromIntegral outputValue) m
    credit m TxOut {..} =
        case scriptToAddressBS scriptOutput of
            Nothing -> m
            Just a  -> M.insertWith (+) a (fromIntegral outValue) m
    coinbase m TxOut {..} =
        case scriptToAddressBS scriptOutput of
            Nothing -> m
            Just a  -> M.insertWith (+) a (fromIntegral outValue) m

addrBatchOps ::
       MonadBlock m
    => BlockRef
    -> [(OutputKey, (OutputValue, SpentValue))]
    -> Tx
    -> Word32
    -> m [LevelDB.BatchOp]
addrBatchOps block spent tx pos = do
    ins <-
        fmap concat . forM (txIn tx) $ \ti@TxIn {..} ->
            if outPointHash prevOutput == zero
                then return []
                else if mainchain
                         then spend ti
                         else unspend ti
    let outs = concat . catMaybes $ zipWith output (txOut tx) [0 ..]
    return $ ins ++ outs
  where
    height = blockRefHeight block
    mainchain = blockRefMainChain block
    output TxOut {..} i =
        let ok = OutputKey (OutPoint (txHash tx) i)
            ov =
                OutputValue
                { outputValue = outValue
                , outBlock = block
                , outScript = scriptOutput
                }
            m = ok `lookup` spent
        in case scriptToAddressBS scriptOutput of
               Just addr ->
                   if mainchain
                       then Just (insertOutput ok addr ov m)
                       else Just (deleteOutput ok addr)
               Nothing -> Nothing
    deleteOutput ok addr =
        [ deleteOp
              AddrSpentKey
              { addrSpentKey = addr
              , addrSpentHeight = height
              , addrSpentOutPoint = ok
              }
        , deleteOp
              AddrUnspentKey
              { addrUnspentKey = addr
              , addrUnspentHeight = height
              , addrUnspentOutPoint = ok
              }
        ]
    insertOutput ok hash ov =
        \case
            Nothing ->
                let uk =
                        AddrUnspentKey
                        { addrUnspentKey = hash
                        , addrUnspentHeight = height
                        , addrUnspentOutPoint = ok
                        }
                    uv =
                        AddrUnspentValue
                        {addrUnspentOutput = ov, addrUnspentPos = pos}
                in [insertOp uk uv]
            Just (_, s) ->
                let sk =
                        AddrSpentKey
                        { addrSpentKey = hash
                        , addrSpentHeight = height
                        , addrSpentOutPoint = ok
                        }
                    sv =
                        AddrSpentValue
                        { addrSpentValue = s
                        , addrSpentOutput = ov
                        , addrSpentPos = pos
                        }
                in [insertOp sk sv]
    zero = "0000000000000000000000000000000000000000000000000000000000000000"
    eo = error "Colud not find spent output"
    spend TxIn {..} =
        fmap (concat . maybeToList) . runMaybeT $ do
            let (ok, s, maddr, height') = getSpent prevOutput
            addr <- MaybeT $ return maddr
            db <- asks myBlockDB
            let uk =
                    AddrUnspentKey
                    { addrUnspentKey = addr
                    , addrUnspentHeight = height'
                    , addrUnspentOutPoint = ok
                    }
            uv <- MaybeT $ uk `retrieveValue` db
            let (sk, sv) = spendAddr uk uv s
            return [deleteOp uk, insertOp sk sv]
    unspend TxIn {..} =
        fmap (concat . maybeToList) . runMaybeT $ do
            let (ok, _s, maddr, height') = getSpent prevOutput
            addr <- MaybeT $ return maddr
            db <- asks myBlockDB
            let sk =
                    AddrSpentKey
                    { addrSpentKey = addr
                    , addrSpentHeight = height'
                    , addrSpentOutPoint = ok
                    }
            sv <- MaybeT $ sk `retrieveValue` db
            let (uk, uv) = unspendAddr sk sv
            return [deleteOp sk, insertOp uk uv]
    getSpent po =
        let ok = OutputKey po
            (ov, s) = fromMaybe eo $ ok `lookup` spent
            maddr = scriptToAddressBS (outScript ov)
            height' = blockRefHeight (outBlock ov)
        in (ok, s, maddr, height')

txBatchOp ::
       MonadBlock m
    => BlockRef
    -> [(OutputKey, (OutputValue, SpentValue))]
    -> Tx
    -> m LevelDB.BatchOp
txBatchOp block spent tx =
    return $ insertOp (TxKey (txHash tx)) (TxValue block tx vs)
  where
    zero = "0000000000000000000000000000000000000000000000000000000000000000"
    e = error "Could not find spent output information"
    vs =
        [ (k, v)
        | ti <- txIn tx
        , let output = prevOutput ti
        , outPointHash output /= zero
        , let k = OutputKey output
        , let (v, _) = fromMaybe e (k `lookup` spent)
        ]


addToCache :: MonadBlock m => BlockRef -> [(OutputKey, OutputValue)] -> m ()
addToCache BlockRef {..} xs = do
    ubox <- asks myUnspentCache
    UnspentCache {..} <- liftIO (readTVarIO ubox)
    let cache = foldl' (\c (k, v) -> M.insert k v c) unspentCache xs
        keys = map fst xs
        blocks = M.insertWith (++) blockRefHeight keys unspentCacheBlocks
        count = unspentCacheCount + length xs
    liftIO . atomically $
        writeTVar
            ubox
            UnspentCache
            { unspentCache = cache
            , unspentCacheBlocks = blocks
            , unspentCacheCount = count
            }

outputBatchOps :: MonadBlock m => BlockRef -> Tx -> m [LevelDB.BatchOp]
outputBatchOps block@BlockRef {..} tx = do
    let os = zipWith f (txOut tx) [0 ..]
    addToCache block os
    return $ map (uncurry insertOp) os
  where
    f TxOut {..} i =
        let key = OutputKey {outPoint = OutPoint (txHash tx) i}
            value =
                OutputValue
                { outputValue = outValue
                , outBlock = block
                , outScript = scriptOutput
                }
        in (key, value)

spentBatchOps ::
       MonadBlock m
    => BlockRef
    -> Tx
    -> Word32 -- ^ position in block
    -> m [LevelDB.BatchOp]
spentBatchOps block tx pos = return . catMaybes $ zipWith f (txIn tx) [0 ..]
  where
    zero = "0000000000000000000000000000000000000000000000000000000000000000"
    f TxIn {..} index =
        if outPointHash prevOutput == zero
            then Nothing
            else Just $
                 insertOp
                     (SpentKey prevOutput)
                     (SpentValue (txHash tx) index block pos)

processBlockMessage :: MonadBlock m => BlockMessage -> m ()

processBlockMessage (BlockChainNew bn) = do
    $(logDebug) $
        logMe <> "Got new block from chain actor: " <> logShow blockHash <>
        " at " <>
        logShow blockHeight
    syncBlocks
  where
    blockHash = headerHash $ nodeHeader bn
    blockHeight = nodeHeight bn

processBlockMessage (BlockGetHeight height reply) = do
    $(logDebug) $ logMe <> "Get new block at height " <> cs (show height)
    getBlockAtHeight height >>= liftIO . atomically . reply

processBlockMessage (BlockGetBest reply) = do
    $(logDebug) $ logMe <> "Got request for best block"
    h <- getBestBlockHash
    b <- fromMaybe e <$> getBlockValue h
    liftIO . atomically $ reply b
  where
    e = error "Could not get best block from database"

processBlockMessage (BlockPeerAvailable _) = do
    $(logDebug) $ logMe <> "A peer became available, syncing blocks"
    syncBlocks

processBlockMessage (BlockPeerConnect _) = do
    $(logDebug) $ logMe <> "A peer just connected, syncing blocks"
    syncBlocks

processBlockMessage (BlockGet bh reply) = do
    $(logDebug) $ logMe <> "Request to get block information"
    m <- getBlockValue bh
    liftIO . atomically $ reply m

processBlockMessage (BlockGetTx th reply) = do
    $(logDebug) $ logMe <> "Request to get transaction: " <> cs (txHashToHex th)
    m <- getStoredTx th
    liftIO . atomically $ reply m

processBlockMessage (BlockGetAddrSpent addr reply) = do
    $(logDebug) $ logMe <> "Get outputs for address " <> cs (show addr)
    os <- getAddrSpent addr
    liftIO . atomically $ reply os

processBlockMessage (BlockGetAddrUnspent addr reply) = do
    $(logDebug) $ logMe <> "Get outputs for address " <> cs (show addr)
    os <- getAddrUnspent addr
    liftIO . atomically $ reply os

processBlockMessage (BlockGetAddrBalance addr reply) = do
    $(logDebug) $ logMe <> "Get balance for address " <> cs (show addr)
    ab <- getAddrBalance addr
    liftIO . atomically $ reply ab

processBlockMessage (BlockReceived _p b) = do
    $(logDebug) $ logMe <> "Received a block"
    pbox <- asks myPending
    dbox <- asks myDownloaded
    let hash = headerHash (blockHeader b)
    liftIO . atomically $ do
        ps <- readTVar pbox
        when (hash `elem` ps) $ do
            modifyTVar dbox (b :)
            modifyTVar pbox (filter (/= hash))
    mbox <- asks mySelf
    best <- getBestBlockHash
    -- Only send BlockProcess message if download box has a block to process
    when (prevBlock (blockHeader b) == best) (BlockProcess `send` mbox)

processBlockMessage BlockProcess = do
    $(logDebug) $ logMe <> "Processing downloaded block"
    importBlocks

processBlockMessage (BlockPeerDisconnect p) = do
    $(logDebug) $ logMe <> "A peer disconnected"
    purgePeer p

processBlockMessage (BlockNotReceived p h) = do
    $(logDebug) $ logMe <> "Block not found: " <> cs (show h)
    purgePeer p

purgePeer :: MonadBlock m => Peer -> m ()
purgePeer p = do
    peerbox <- asks myPeer
    pbox <- asks myPending
    dbox <- asks myDownloaded
    mgr <- asks myManager
    purge <-
        liftIO . atomically $ do
            p' <- readTVar peerbox
            if Just p == p'
                then do
                    writeTVar peerbox Nothing
                    writeTVar dbox []
                    writeTVar pbox []
                    return True
                else return False
    when purge $
        managerKill (PeerMisbehaving "Peer purged from block store") p mgr
    syncBlocks

blockGetBest :: (MonadBase IO m, MonadIO m) => BlockStore -> m BlockValue
blockGetBest b = BlockGetBest `query` b

blockGetTx :: (MonadBase IO m, MonadIO m) => TxHash -> BlockStore -> m (Maybe DetailedTx)
blockGetTx h b = BlockGetTx h `query` b

blockGet :: (MonadBase IO m, MonadIO m) => BlockHash -> BlockStore -> m (Maybe BlockValue)
blockGet h b = BlockGet h `query` b

blockGetHeight ::
       (MonadBase IO m, MonadIO m)
    => BlockHeight
    -> BlockStore
    -> m (Maybe BlockValue)
blockGetHeight h b = BlockGetHeight h `query` b

blockGetAddrTxs ::
       (MonadBase IO m, MonadIO m) => Address -> BlockStore -> m [AddressTx]
blockGetAddrTxs addr b = do
    us <- BlockGetAddrUnspent addr `query` b
    ss <- BlockGetAddrSpent addr `query` b
    let utx =
            [ AddressTx
            { addressTxAddress = addr
            , addressTxId = outPointHash (outPoint (addrUnspentOutPoint k))
            , addressTxAmount = fromIntegral (outputValue (addrUnspentOutput v))
            , addressTxBlock = outBlock (addrUnspentOutput v)
            , addressTxPos = addrUnspentPos v
            }
            | (k, v) <- us
            ]
        stx =
            [ AddressTx
            { addressTxAddress = addr
            , addressTxId = outPointHash (outPoint (addrSpentOutPoint k))
            , addressTxAmount = fromIntegral (outputValue (addrSpentOutput v))
            , addressTxBlock = outBlock (addrSpentOutput v)
            , addressTxPos = addrSpentPos v
            }
            | (k, v) <- ss
            ]
        itx =
            [ AddressTx
            { addressTxAddress = addr
            , addressTxId = spentInHash s
            , addressTxAmount = -fromIntegral (outputValue (addrSpentOutput v))
            , addressTxBlock = spentInBlock s
            , addressTxPos = spentInPos s
            }
            | (_, v) <- ss
            , let s = addrSpentValue v
            ]
        ts = sortBy (flip compare `on` f) (itx ++ stx ++ utx)
        zs =
            [ atx {addressTxAmount = amount}
            | xs@(atx:_) <- groupBy ((==) `on` addressTxId) ts
            , let amount = sum (map addressTxAmount xs)
            ]
    return zs
  where
    f AddressTx {..} = (blockRefHeight addressTxBlock, addressTxPos)

blockGetAddrUnspent ::
       (MonadBase IO m, MonadIO m)
    => Address
    -> BlockStore
    -> m [Unspent]
blockGetAddrUnspent addr b = do
    xs <- BlockGetAddrUnspent addr `query` b
    return $ map (uncurry toUnspent) xs
  where
    toUnspent AddrUnspentKey {..} AddrUnspentValue {..} =
        Unspent
        { unspentTxId = outPointHash (outPoint addrUnspentOutPoint)
        , unspentIndex = outPointIndex (outPoint addrUnspentOutPoint)
        , unspentValue = outputValue addrUnspentOutput
        , unspentBlock = outBlock addrUnspentOutput
        }

blockGetAddrBalance ::
       (MonadBase IO m, MonadIO m)
    => Address
    -> BlockStore
    -> m (Maybe AddressBalance)
blockGetAddrBalance addr b = BlockGetAddrBalance addr `query` b

logMe :: Text
logMe = "[Block] "
