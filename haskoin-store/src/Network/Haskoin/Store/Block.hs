{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE TemplateHaskell            #-}
module Network.Haskoin.Store.Block
    ( blockStore
    , getBestBlock
    , getBlockAtHeight
    , getBlock
    , getUnspent
    , getAddrTxs
    , getBalance
    , getTx
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
import           Data.Default
import           Data.Function
import           Data.List
import           Data.Map                     (Map)
import qualified Data.Map.Strict              as M
import           Data.Maybe
import           Data.Monoid
import           Data.Serialize               as S
import           Data.String.Conversions
import           Data.Text                    (Text)
import           Data.Word
import           Database.RocksDB             (DB, Snapshot)
import qualified Database.RocksDB             as RocksDB
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Crypto
import           Network.Haskoin.Node
import           Network.Haskoin.Script
import           Network.Haskoin.Store.Common
import           Network.Haskoin.Store.Types
import           Network.Haskoin.Transaction

data BlockRead = BlockRead
    { myBlockDB      :: !DB
    , mySelf         :: !BlockStore
    , myDir          :: !FilePath
    , myChain        :: !Chain
    , myManager      :: !Manager
    , myListener     :: !(Listen BlockEvent)
    , myPending      :: !(TVar [BlockHash])
    , myDownloaded   :: !(TVar [Block])
    , myPeer         :: !(TVar (Maybe Peer))
    , myUnspentCache :: !(TVar UnspentCache)
    , myCacheNo      :: !Word32
    , myBlockNo      :: !Word32
    }

type MonadBlock m
     = ( MonadBase IO m
       , MonadThrow m
       , MonadBaseControl IO m
       , MonadLoggerIO m
       , MonadReader BlockRead m)

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
blockStore BlockConfig {..} = do
    pbox <- liftIO $ newTVarIO []
    dbox <- liftIO $ newTVarIO []
    ubox <-
        liftIO $
        newTVarIO
            UnspentCache {unspentCache = M.empty, unspentCacheBlocks = M.empty}
    peerbox <- liftIO $ newTVarIO Nothing
    runReaderT
        (loadBest >> syncBlocks >> run)
        BlockRead
        { mySelf = blockConfMailbox
        , myBlockDB = blockConfDB
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
    stats = do
        cache <- liftIO . readTVarIO =<< asks myUnspentCache
        pending <- liftIO . readTVarIO =<< asks myPending
        downloaded <- liftIO . readTVarIO =<< asks myDownloaded
        $(logDebug) $
            logMe <> "Cache blocks count: " <>
            cs (show (M.size (unspentCacheBlocks cache)))
        $(logDebug) $
            logMe <> "Cache entry count: " <>
            cs (show (M.size (unspentCache cache)))
        $(logDebug) $
            logMe <> "Pending block count: " <> cs (show (length pending))
        $(logDebug) $
            logMe <> "Download count: " <> cs (show (length downloaded))
    run =
        forever $ do
            stats
            $(logDebug) $ logMe <> "Awaiting message"
            processBlockMessage =<< receive blockConfMailbox
    loadBest =
        retrieveValue BestBlockKey blockConfDB Nothing >>= \case
            Nothing -> do
                importBlock genesisBlock
                $(logDebug) $ logMe <> "Stored Genesis block in database"
            Just _ -> return ()


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


getBestBlockHash :: MonadIO m => DB -> Maybe Snapshot -> m (Maybe BlockHash)
getBestBlockHash = retrieveValue BestBlockKey

getBestBlock :: MonadIO m => DB -> Maybe Snapshot -> m (Maybe BlockValue)
getBestBlock db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ f . Just
        Just _ -> f s
  where
    f s' =
        runMaybeT $ do
            h <- MaybeT (getBestBlockHash db s')
            MaybeT (getBlock h db s')

getBlockAtHeight ::
       MonadIO m => BlockHeight -> DB -> Maybe Snapshot -> m (Maybe BlockValue)
getBlockAtHeight height db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ f . Just
        Just _ -> f s
  where
    f s' =
        runMaybeT $ do
            h <- MaybeT (retrieveValue (HeightKey height) db s')
            MaybeT (retrieveValue (BlockKey h) db s')

getBlock ::
       MonadIO m => BlockHash -> DB -> Maybe Snapshot -> m (Maybe BlockValue)
getBlock = retrieveValue . BlockKey

getAddrSpent ::
       MonadIO m
    => Address
    -> DB
    -> Maybe Snapshot
    -> m [(AddrSpentKey, AddrSpentValue)]
getAddrSpent = valuesForKey . MultiAddrSpentKey

getAddrUnspent ::
       MonadIO m
    => Address
    -> DB
    -> Maybe Snapshot
    -> m [(AddrUnspentKey, AddrUnspentValue)]
getAddrUnspent = valuesForKey . MultiAddrUnspentKey

getBalance ::
       MonadIO m => Address -> DB -> Maybe Snapshot -> m (Maybe AddressBalance)
getBalance addr db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ g . Just
        Just _ -> g s
  where
    g s' =
        runMaybeT $ do
            bal <-
                MaybeT
                    (fmap listToMaybe (valuesForKey (MultiBalance addr) db s'))
            best <- fmap (fromMaybe e) (getBestBlockHash db s')
            block <- fmap (fromMaybe e) (getBlock best db s')
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
    e = error "Colud not retrieve best block from database"
    i h BalanceValue {..} =
        let f Immature {..} = blockRefHeight immatureBlock <= h - 99
            (ms, is) = partition f balanceImmature
        in BalanceValue
           { balanceValue = balanceValue + sum (map immatureValue ms)
           , balanceImmature = is
           }

getTx ::
       MonadIO m => TxHash -> DB -> Maybe Snapshot -> m (Maybe DetailedTx)
getTx th db s =
    runMaybeT $ do
        xs <- valuesForKey (BaseTxKey th) db s
        TxValue {..} <- MaybeT (return (findTx xs))
        let ss = filterSpents xs
        return (DetailedTx txValue txValueBlock ss txValueOuts)
  where
    findTx xs =
        listToMaybe
            [ v
            | (f, s') <- xs
            , case f of
                  MultiTxKey {} -> True
                  _             -> False
            , let MultiTx v = s'
            ]
    filterSpents xs =
        [ (k, v)
        | (f, s') <- xs
        , case f of
              MultiTxKeySpent {} -> True
              _                  -> False
        , let MultiTxKeySpent k = f
        , let MultiTxSpent v = s'
        ]

revertBestBlock :: MonadBlock m => m ()
revertBestBlock =
    void . runMaybeT $ do
        db <- asks myBlockDB
        best <- fromMaybe e <$> getBestBlockHash db Nothing
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
            getBlock best db Nothing >>= \case
                Just b -> return b
                Nothing -> do
                    $(logError) $ logMe <> "Could not retrieve best block"
                    error "BUG: Could not retrieve best block"
        txs <- mapMaybe (fmap txValue) <$> getBlockTxs blockValueTxs db Nothing
        let block = Block blockValueHeader txs
        blockOps <- blockBatchOps block (nodeHeight bn) (nodeWork bn) False
        RocksDB.write db def blockOps
  where
    e = error "Could not get best block from database"

syncBlocks :: MonadBlock m => m ()
syncBlocks = do
    mgr <- asks myManager
    peerbox <- asks myPeer
    ch <- asks myChain
    chainBest <- chainGetBest ch
    let bestHash = headerHash (nodeHeader chainBest)
    db <- asks myBlockDB
    myBestHash <- fromMaybe e <$> getBestBlockHash db Nothing
    void . runMaybeT $ do
        guard (myBestHash /= bestHash)
        guard =<< do
            pbox <- asks myPending
            dbox <- asks myDownloaded
            liftIO . atomically $
                (&&) <$> (null <$> readTVar pbox) <*> (null <$> readTVar dbox)
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
    e = error "Colud not get best block from database"
    revertUntil myBest splitBlock
        | myBest == splitBlock = return ()
        | otherwise = do
            revertBestBlock
            db <- asks myBlockDB
            newBestHash <- fromMaybe e <$> getBestBlockHash db Nothing
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
    db <- asks myBlockDB
    best <- fromMaybe e <$> getBestBlockHash db Nothing
    m <-
        liftIO . atomically $ do
            ds <- readTVar dbox
            let (xs, ys) = partition ((== best) . prevBlock . blockHeader) ds
            case xs of
                [] -> return Nothing
                b:_ -> do
                    writeTVar dbox ys
                    return (Just b)
    case m of
        Just block -> do
            importBlock block
            mbox <- asks mySelf
            BlockProcess `send` mbox
        Nothing -> syncBlocks
  where
    e = error "Could not get best block from database"

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
    $(logDebug) $
        logMe <> "Writing " <> logShow (length blockOps) <>
        " entries for block " <>
        logShow (nodeHeight bn)
    RocksDB.write db def blockOps
    $(logDebug) $ logMe <> "Stored block " <> logShow (nodeHeight bn)
    l <- asks myListener
    liftIO . atomically . l $ BestBlock blockHash
  where
    blockHash = headerHash blockHeader

getBlockTxs ::
       MonadIO m => [TxHash] -> DB -> Maybe Snapshot -> m [Maybe TxValue]
getBlockTxs hs db s = forM hs (\h -> retrieveValue (TxKey h) db s)

blockBatchOps ::
       MonadBlock m
    => Block
    -> BlockHeight
    -> BlockWork
    -> Bool
    -> m [RocksDB.BatchOp]
blockBatchOps block@Block {..} height work main = do
    outputs <- M.fromList . concat <$> mapM (outputBatchOps blockRef) blockTxns
    let outputOps = map (uncurry insertOp) (M.toList outputs)
    spent <- concat <$> zipWithM (spentOutputs blockRef outputs) blockTxns [0 ..]
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
    -> Map OutputKey OutputValue
    -> m (Maybe OutputValue)
getOutput key os = runMaybeT (fromMap <|> fromCache <|> fromDB)
  where
    hash = outPointHash (outPoint key)
    index = outPointIndex (outPoint key)
    fromMap = MaybeT (return (M.lookup key os))
    fromDB = do
        db <- asks myBlockDB
        asks myCacheNo >>= \n ->
            when (n /= 0) . $(logDebug) $
            logMe <> "Cache miss for output " <> cs (show hash) <> "/" <>
            cs (show index)
        MaybeT $ retrieveValue key db Nothing
    fromCache = do
        guard . (/= 0) =<< asks myCacheNo
        ubox <- asks myUnspentCache
        cache@UnspentCache {..} <- liftIO $ readTVarIO ubox
        m <- MaybeT . return $ M.lookup key unspentCache
        $(logDebug) $
            logMe <> "Cache hit for output " <> cs (show hash) <> " " <>
            cs (show index)
        liftIO . atomically $
            writeTVar ubox cache {unspentCache = M.delete key unspentCache}
        return m


unspentCachePrune :: MonadBlock m => m ()
unspentCachePrune =
    void . runMaybeT $ do
        n <- asks myCacheNo
        guard (n /= 0)
        ubox <- asks myUnspentCache
        cache <- liftIO (readTVarIO ubox)
        let new = clear (fromIntegral n) cache
            del = M.size (unspentCache cache) - M.size (unspentCache new)
        liftIO . atomically $ writeTVar ubox new
        $(logDebug) $
            logMe <> "Deleted " <> cs (show del) <> " of " <>
            cs (show (M.size (unspentCache cache))) <>
            " entries from UTXO cache"
  where
    clear n c@UnspentCache {..}
        | M.size unspentCache < n = c
        | otherwise =
            let (del, keep) = M.splitAt 1 unspentCacheBlocks
                ks =
                    [ k
                    | keys <- M.elems del
                    , k <- keys
                    , isJust (M.lookup k unspentCache)
                    ]
                cache = foldl' (flip M.delete) unspentCache ks
            in clear
                   n
                   UnspentCache
                   {unspentCache = cache, unspentCacheBlocks = keep}

spentOutputs ::
       MonadBlock m
    => BlockRef
    -> Map OutputKey OutputValue
    -> Tx
    -> Word32 -- ^ position in block
    -> m [(OutputKey, (OutputValue, SpentValue))]
spentOutputs block os tx pos =
    fmap catMaybes . forM (zip [0 ..] (txIn tx)) $ \(i, TxIn {..}) ->
        if outPointHash prevOutput == zero
            then return Nothing
            else do
                let key = OutputKey prevOutput
                val <- fromMaybe e <$> getOutput key os
                let spent = SpentValue (txHash tx) i block pos
                return $ Just (key, (val, spent))
  where
    zero = "0000000000000000000000000000000000000000000000000000000000000000"
    e = error "Colud not retrieve information for output being spent"

balanceBatchOps ::
       MonadBlock m => BlockRef -> [OutputValue] -> [Tx] -> m [RocksDB.BatchOp]
balanceBatchOps block spent txs =
    if blockRefMainChain block
        then do
            cur <- (M.fromList . map f . catMaybes) <$> mapM balance addrs
            let bals = map (g cur) addrs
            return $ map (uncurry insertOp) bals
        else return $
             map
                 (\a ->
                      deleteOp
                          BalanceKey {balanceAddress = a, balanceBlock = block})
                 addrs
  where
    f (BalanceKey {..}, BalanceValue {..}) =
        (balanceAddress, (balanceValue, balanceImmature))
    g cur addr =
        let bal = maybe 0 fst (M.lookup addr cur)
            imms = concat (maybeToList (snd <$> M.lookup addr cur))
            cred = fromMaybe 0 (M.lookup addr creditMap)
            deb = fromMaybe 0 (M.lookup addr debitMap)
            (mts, imms') = partition mature imms
            mat = sum (map immatureValue mts)
            bal' = bal + mat + cred - deb
            imms'' =
                [ Immature {immatureBlock = block, immatureValue = value}
                | value <- maybeToList (M.lookup addr coinbaseMap)
                ] ++
                imms'
            k = BalanceKey {balanceAddress = addr, balanceBlock = block}
            v = BalanceValue {balanceValue = bal', balanceImmature = imms''}
        in (k, v)
    mature = (<= blockRefHeight block - 99) . blockRefHeight . immatureBlock
    addrs = nub (M.keys creditMap ++ M.keys debitMap ++ M.keys coinbaseMap)
    balance addr = do
        db <- asks myBlockDB
        firstValue (MultiBalance addr) db Nothing
    creditMap = foldl' credit M.empty (concatMap txOut (tail txs))
    coinbaseMap = foldl' coinbase M.empty (txOut (head txs))
    debitMap = foldl' debit M.empty spent
    debit m OutputValue {..} =
        case scriptToAddressBS outScript of
            Nothing -> m
            Just a  -> M.insertWith (+) a outputValue m
    credit m TxOut {..} =
        case scriptToAddressBS scriptOutput of
            Nothing -> m
            Just a  -> M.insertWith (+) a outValue m
    coinbase m TxOut {..} =
        case scriptToAddressBS scriptOutput of
            Nothing -> m
            Just a  -> M.insertWith (+) a outValue m

addrBatchOps ::
       MonadBlock m
    => BlockRef
    -> [(OutputKey, (OutputValue, SpentValue))]
    -> Tx
    -> Word32
    -> m [RocksDB.BatchOp]
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
            uv <- MaybeT (retrieveValue uk db Nothing)
            let (sk, sv) = spendAddr uk uv s
            return [deleteOp uk, insertOp sk sv]
    unspend TxIn {..} =
        fmap (concat . maybeToList) . runMaybeT $ do
            let (ok, _s, maddr, height') = getSpent prevOutput
            addr <- MaybeT (return maddr)
            db <- asks myBlockDB
            let sk =
                    AddrSpentKey
                    { addrSpentKey = addr
                    , addrSpentHeight = height'
                    , addrSpentOutPoint = ok
                    }
            sv <- MaybeT (retrieveValue sk db Nothing)
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
    -> m RocksDB.BatchOp
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
addToCache BlockRef {..} xs = void . runMaybeT $ do
    guard . (/= 0) =<< asks myCacheNo
    ubox <- asks myUnspentCache
    UnspentCache {..} <- liftIO (readTVarIO ubox)
    let cache = foldl' (\c (k, v) -> M.insert k v c) unspentCache xs
        keys = map fst xs
        blocks = M.insertWith (++) blockRefHeight keys unspentCacheBlocks
    liftIO . atomically $
        writeTVar
            ubox
            UnspentCache
            { unspentCache = cache
            , unspentCacheBlocks = blocks
            }

outputBatchOps :: MonadBlock m => BlockRef -> Tx -> m [(OutputKey, OutputValue)]
outputBatchOps block@BlockRef {..} tx = do
    let os = zipWith f (txOut tx) [0 ..]
    addToCache block os
    return os
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
    -> m [RocksDB.BatchOp]
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

processBlockMessage (BlockPeerConnect _) = do
    $(logDebug) $ logMe <> "A peer just connected, syncing blocks"
    syncBlocks

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
    db <- asks myBlockDB
    best <- fromMaybe e <$> getBestBlockHash db Nothing
    -- Only send BlockProcess message if download box has a block to process
    when (prevBlock (blockHeader b) == best) (BlockProcess `send` mbox)
  where
    e = error "Could not get best block from database"

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

getAddrTxs :: MonadIO m => Address -> DB -> Maybe Snapshot -> m [AddressTx]
getAddrTxs addr db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ g . Just
        Just _ -> g s
  where
    f AddressTx {..} = (blockRefHeight addressTxBlock, addressTxPos)
    g s' = do
        us <- getAddrUnspent addr db s'
        ss <- getAddrSpent addr db s'
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
                , addressTxId = spentInHash p
                , addressTxAmount = -fromIntegral (outputValue (addrSpentOutput v))
                , addressTxBlock = spentInBlock p
                , addressTxPos = spentInPos p
                }
                | (_, v) <- ss
                , let p = addrSpentValue v
                ]
            ts = sortBy (flip compare `on` f) (itx ++ stx ++ utx)
            zs =
                [ atx {addressTxAmount = amount}
                | xs@(atx:_) <- groupBy ((==) `on` addressTxId) ts
                , let amount = sum (map addressTxAmount xs)
                ]
        return zs

getUnspent :: MonadIO m => Address -> DB -> Maybe Snapshot -> m [Unspent]
getUnspent addr db s = do
    xs <- getAddrUnspent addr db s
    return $ map (uncurry toUnspent) xs
  where
    toUnspent AddrUnspentKey {..} AddrUnspentValue {..} =
        Unspent
        { unspentTxId = outPointHash (outPoint addrUnspentOutPoint)
        , unspentIndex = outPointIndex (outPoint addrUnspentOutPoint)
        , unspentValue = outputValue addrUnspentOutput
        , unspentBlock = outBlock addrUnspentOutput
        }

logMe :: Text
logMe = "[Block] "
