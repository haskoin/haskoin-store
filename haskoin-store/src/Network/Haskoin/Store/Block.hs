{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TupleSections              #-}
module Network.Haskoin.Store.Block
    ( blockStore
    , getBestBlock
    , getBlockAtHeight
    , getBlock
    , getUnspent
    , getAddrTxs
    , getBalance
    , getTx
    , getOutput
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
import           Data.Serialize               (encode)
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

data UnspentCache = UnspentCache
    { unspentCache       :: !(Map OutPoint OutputValue)
    , unspentCacheBlocks :: !(Map BlockHeight [OutPoint])
    }

data BlockRead = BlockRead
    { myBlockDB      :: !DB
    , mySelf         :: !BlockStore
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

data AddressDelta = AddressDelta
    { addressDeltaOutput      :: !AddrOutputMap
    , addressDeltaBalance     :: !Word64
    , addressDeltaImmature    :: ![Immature]
    , addressDeltaTxCount     :: !Word64
    , addressDeltaOutputCount :: !Word64
    , addressDeltaSpentCount  :: !Word64
    } deriving (Show, Eq)

instance Monoid AddressDelta where
    mempty =
        AddressDelta
        { addressDeltaOutput = M.empty
        , addressDeltaBalance = 0
        , addressDeltaImmature = []
        , addressDeltaTxCount = 0
        , addressDeltaOutputCount = 0
        , addressDeltaSpentCount = 0
        }
    a `mappend` b =
        AddressDelta
        { addressDeltaOutput =
              addressDeltaOutput b `M.union` addressDeltaOutput a
        , addressDeltaBalance = addressDeltaBalance a + addressDeltaBalance b
        , addressDeltaImmature =
              addressDeltaImmature a ++ addressDeltaImmature b
        , addressDeltaTxCount = addressDeltaTxCount a + addressDeltaTxCount b
        , addressDeltaOutputCount =
              addressDeltaOutputCount a + addressDeltaOutputCount b
        , addressDeltaSpentCount =
              addressDeltaSpentCount a + addressDeltaSpentCount b
        }

data AddrOutputKey = AddrOutputKey
    { addrOutputKeyHeight   :: !BlockHeight
    , addrOutputKeyOutPoint :: !OutPoint
    } deriving (Show, Eq, Ord)

data AddrOutputValue = AddrOutputValue
    { addrOutputValue      :: !OutputValue
    , addrOutputValueSpent :: !(Maybe SpentValue)
    } deriving (Show, Eq, Ord)

type PrevOutMap = Map OutPoint OutputValue
type OutputMap = Map OutPoint OutputValue
type AddressMap = Map Address AddressDelta
type AddrOutputMap = Map AddrOutputKey AddrOutputValue
type SpentMap = Map OutPoint SpentValue

data BlockData = BlockData
    { blockPrevOutMap :: !PrevOutMap
    , blockAddrMap    :: !AddressMap
    , blockSpentMap   :: !SpentMap
    , blockNewOutMap  :: !OutputMap
    } deriving (Show, Eq)

instance Monoid BlockData where
    mempty = BlockData M.empty M.empty M.empty M.empty
    a `mappend` b = BlockData
        { blockPrevOutMap = M.union (blockPrevOutMap b) (blockPrevOutMap a)
        , blockAddrMap = M.unionWith (<>) (blockAddrMap a) (blockAddrMap b)
        , blockSpentMap = M.union (blockSpentMap b) (blockSpentMap a)
        , blockNewOutMap = M.union (blockNewOutMap b) (blockNewOutMap a)
        }

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

getBestBlockHash :: MonadIO m => DB -> Maybe Snapshot -> m (Maybe BlockHash)
getBestBlockHash = retrieveValue BestBlockKey

getBestBlock :: MonadIO m => DB -> Maybe Snapshot -> m (Maybe BlockValue)
getBestBlock db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ f . Just
        Just _  -> f s
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
        Just _  -> f s
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

getOutput ::
       MonadIO m
    => OutPoint
    -> DB
    -> Maybe Snapshot
    -> m (Maybe (OutputValue, Maybe SpentValue))
getOutput op db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ f . Just
        Just _ -> f s
  where
    f s' = runMaybeT $ do
        out <- MaybeT (retrieveValue (OutputKey op) db s')
        maybeSpent <- retrieveValue (SpentKey op) db s'
        return (out, maybeSpent)

getBalance ::
       MonadIO m => Address -> DB -> Maybe Snapshot -> m (Maybe AddressBalance)
getBalance addr db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ g . Just
        Just _ -> g s
  where
    g s' =
        runMaybeT $ do
            bal <- MaybeT (firstValue (MultiBalance addr) db s')
            best <- getBestBlockHash db s' >>= me
            block <- getBlock best db s' >>= me
            let h = blockValueHeight block
                bs = second (i h) bal
                is = sum (map immatureValue (balanceImmature (snd bs)))
                ub = balanceValue (snd bs)
            return
                AddressBalance
                { addressBalAddress = addr
                , addressBalConfirmed = ub
                , addressBalImmature = is
                , addressBalBlock =
                      BlockRef
                      { blockRefHeight = blockValueHeight block
                      , blockRefHash = best
                      , blockRefMainChain = True
                      }
                , addressBalTxCount = balanceTxCount (snd bal)
                , addressBalUnspentCount =
                      balanceOutputCount (snd bal) - balanceSpentCount (snd bal)
                , addressBalSpentCount = balanceSpentCount (snd bal)
                }
    me Nothing = error "Could not retrieve best block from database"
    me (Just x) = return x
    i h bal@BalanceValue {..} =
        let minHeight =
                if h < 99
                    then 0
                    else h - 99
        in bal
           { balanceImmature =
                 filter
                     ((>= minHeight) . blockRefHeight . immatureBlock)
                     balanceImmature
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
        best <-
            getBestBlockHash db Nothing >>= me "Could not retrieve best block"
        guard (best /= headerHash genesisHeader)
        $(logDebug) $ logMe <> "Reverting block " <> logShow best
        ch <- asks myChain
        bn <- chainGetBlock best ch >>= me "Could not retrieve block from chain"
        BlockValue {..} <-
            getBlock best db Nothing >>= me "Could not retrieve best block"
        txs <- mapMaybe (fmap txValue) <$> getBlockTxs blockValueTxs db Nothing
        let block = Block blockValueHeader txs
        blockOps <- blockBatchOps block (nodeHeight bn) (nodeWork bn) False
        RocksDB.write db def blockOps
  where
    me msg Nothing = do
        $(logError) $ logMe <> cs msg
        error msg
    me _ (Just x) = return x

syncBlocks :: MonadBlock m => m ()
syncBlocks = do
    mgr <- asks myManager
    peerbox <- asks myPeer
    ch <- asks myChain
    chainBest <- chainGetBest ch
    let bestHash = headerHash (nodeHeader chainBest)
    db <- asks myBlockDB
    myBestHash <-
        getBestBlockHash db Nothing >>= me "Could not get best block hash"
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
    me msg Nothing = do
        $(logError) $ logMe <> cs msg
        error msg
    me _ (Just x) = return x
    revertUntil myBest splitBlock
        | myBest == splitBlock = return ()
        | otherwise = do
            revertBestBlock
            db <- asks myBlockDB
            newBestHash <-
                getBestBlockHash db Nothing >>=
                me "Could not get best block hash"
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
    best <- getBestBlockHash db Nothing >>= me "Could not get block hash"
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
    me msg Nothing = do
        $(logError) $ logMe <> cs msg
        error msg
    me _ (Just x) = return x

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
    ops <- blockBatchOps block (nodeHeight bn) (nodeWork bn) True
    db <- asks myBlockDB
    $(logDebug) $
        logMe <> "Writing " <> logShow (length ops) <>
        " entries for block " <>
        logShow (nodeHeight bn)
    RocksDB.write db def ops
    $(logInfo) $ logMe <> "Stored block " <> logShow (nodeHeight bn)
    l <- asks myListener
    liftIO . atomically . l $ BestBlock blockHash
    unspentCachePrune
  where
    blockHash = headerHash blockHeader

getBlockTxs ::
       MonadIO m => [TxHash] -> DB -> Maybe Snapshot -> m [Maybe TxValue]
getBlockTxs hs db s = forM hs (\h -> retrieveValue (TxKey h) db s)

addrOutputOps :: Bool -> Address -> AddrOutputKey -> AddrOutputValue -> [RocksDB.BatchOp]
addrOutputOps main addr AddrOutputKey {..} AddrOutputValue {..} =
    let skey =
            AddrSpentKey
            { addrSpentKey = addr
            , addrSpentHeight = addrOutputKeyHeight
            , addrSpentOutPoint = OutputKey addrOutputKeyOutPoint
            }
        sval s =
            AddrSpentValue
            { addrSpentOutput = addrOutputValue
            , addrSpentValue = s
            }
        ukey =
            AddrUnspentKey
            { addrUnspentKey = addr
            , addrUnspentHeight = addrOutputKeyHeight
            , addrUnspentOutPoint = OutputKey addrOutputKeyOutPoint
            }
        uval = AddrUnspentValue {addrUnspentOutput = addrOutputValue}
        outputInSameBlock s =
            blockRefHash (outBlock addrOutputValue) ==
            blockRefHash (spentInBlock s)
    in if main
           then case addrOutputValueSpent of
                    Nothing -> [deleteOp skey, insertOp ukey uval]
                    Just s -> [deleteOp ukey, insertOp skey (sval s)]
           else case addrOutputValueSpent of
                    Nothing -> [deleteOp ukey]
                    Just s ->
                        if outputInSameBlock s
                            then [deleteOp skey]
                            else [deleteOp skey, insertOp ukey uval]

blockOp ::
    MonadBlock m
    => Block
    -> BlockHeight
    -> BlockWork
    -> Bool
    -> BlockData
    -> m [RocksDB.BatchOp]
blockOp block height work main BlockData {..} = do
    addrops <- addrOps
    cache
    return $
        [blockHashOp, blockHeightOp, bestOp] <>
        concat [txOps, outOps, spentOps, addrops]
  where
    header = blockHeader block
    hash = headerHash header
    blockRef =
        BlockRef
        {blockRefHash = hash, blockRefHeight = height, blockRefMainChain = main}
    txs = blockTxns block
    cache = do
        let entries = M.toList blockNewOutMap
        addToCache blockRef entries
    blockHashOp =
        let key = BlockKey (headerHash header)
            value =
                BlockValue
                { blockValueHeight = height
                , blockValueWork = work
                , blockValueHeader = header
                , blockValueSize = fromIntegral (BS.length (encode block))
                , blockValueMainChain = main
                , blockValueTxs = map txHash txs
                }
        in if main
               then insertOp key value
               else deleteOp key
    blockHeightOp =
        if main
            then let key = HeightKey height
                 in insertOp key (headerHash header)
            else let key = HeightKey height
                 in deleteOp key
    bestOp =
        if main
            then insertOp BestBlockKey (headerHash header)
            else insertOp BestBlockKey (prevBlock header)
    txOps =
        let outs =
                mapMaybe
                    (\op -> (OutputKey op, ) <$> op `M.lookup` blockPrevOutMap)
            f tx =
                insertOp
                    (TxKey (txHash tx))
                    (TxValue blockRef tx (outs (map prevOutput (txIn tx))))
        in map f txs
    outOps =
        let os = M.toList blockNewOutMap
            xs = map (first OutputKey) os
        in if main
               then map (uncurry insertOp) xs
               else map (deleteOp . fst) xs
    spentOps =
        let ss = M.toList blockSpentMap
            xs = map (first SpentKey) ss
        in if main
               then map (uncurry insertOp) xs
               else map (deleteOp . fst) xs
    addrOps = do
        let ls = M.toList blockAddrMap
        fmap concat . forM ls $ \(addr, AddressDelta {..}) -> do
            db <- asks myBlockDB
            maybeBal <- firstValue (MultiBalance addr) db Nothing
            let balKey =
                    BalanceKey {balanceAddress = addr, balanceBlock = blockRef}
                balVal =
                    case maybeBal of
                        Nothing ->
                            BalanceValue
                            { balanceValue = addressDeltaBalance
                            , balanceImmature = addressDeltaImmature
                            , balanceTxCount = addressDeltaTxCount
                            , balanceOutputCount = addressDeltaOutputCount
                            , balanceSpentCount = addressDeltaSpentCount
                            }
                        Just (_, BalanceValue {..}) ->
                            let minHeight =
                                    if height >= 99
                                        then height - 99
                                        else 0
                                immature =
                                    filter
                                        ((>= minHeight) .
                                         blockRefHeight . immatureBlock)
                                        balanceImmature
                            in BalanceValue
                               { balanceValue =
                                     balanceValue + addressDeltaBalance
                               , balanceImmature = immature
                               , balanceTxCount =
                                     balanceTxCount + addressDeltaTxCount
                               , balanceOutputCount =
                                     balanceOutputCount +
                                     addressDeltaOutputCount
                               , balanceSpentCount =
                                     balanceSpentCount + addressDeltaSpentCount
                               }
                bop =
                    if main
                        then insertOp balKey balVal
                        else deleteOp balKey
                os = M.toList addressDeltaOutput
                sops = concatMap (uncurry (addrOutputOps main addr)) os
            return (bop : sops)

blockBatchOps ::
       MonadBlock m
    => Block
    -> BlockHeight
    -> BlockWork
    -> Bool
    -> m [RocksDB.BatchOp]
blockBatchOps block@Block {..} height work main = do
    let start =
            BlockData
            { blockPrevOutMap = M.empty
            , blockAddrMap = M.empty
            , blockSpentMap = M.empty
            , blockNewOutMap = M.empty
            }
    bd <- foldM f start (zip [0 ..] blockTxns)
    stats bd
    blockOp block height work main bd
  where
    stats BlockData {..} = do
        let logBlock =
                logMe <> "Block " <> logShow (headerHash blockHeader) <> " "
            newOutCount = M.size blockNewOutMap
            spentCount = M.size blockSpentMap
        $(logDebug) $ logBlock <> "new outputs: " <> logShow newOutCount
        $(logDebug) $ logBlock <> "spent: " <> logShow spentCount
    blockRef =
        BlockRef
        { blockRefHash = headerHash blockHeader
        , blockRefHeight = height
        , blockRefMainChain = main
        }
    f blockData (pos, tx) = do
        prevOutMap <- getPrevOutputs tx (blockPrevOutMap blockData)
        let spentMap = getSpentOutputs blockRef pos tx
            newOutMap = getNewOutputs blockRef pos tx
            addrMap = getAddrDelta blockRef pos spentMap newOutMap prevOutMap
            txData =
                BlockData
                { blockPrevOutMap = prevOutMap <> newOutMap
                , blockNewOutMap = newOutMap
                , blockAddrMap = addrMap
                , blockSpentMap = spentMap
                }
        return (blockData <> txData)

getAddrDelta ::
       BlockRef -> Word32 -> SpentMap -> OutputMap -> PrevOutMap -> AddressMap
getAddrDelta blockRef pos spentMap newOutMap prevMap =
    M.fromList (map (\addr -> (addr, addrDelta addr)) addrs)
  where
    addrDelta addr =
        let sm = fromMaybe M.empty (M.lookup addr addrSpentMap)
            om = fromMaybe M.empty (M.lookup addr addrOutputMap)
            xm = M.union sm om
            ob = sum (map (outputValue . addrOutputValue) (M.elems om))
            sb = sum (map (outputValue . addrOutputValue) (M.elems sm))
            im = [Immature blockRef sb | pos == 0]
        in AddressDelta
           { addressDeltaOutput = xm
           , addressDeltaBalance = fromIntegral ob - fromIntegral sb
           , addressDeltaImmature = im
           , addressDeltaTxCount = 1
           , addressDeltaOutputCount = fromIntegral (M.size om)
           , addressDeltaSpentCount = fromIntegral (M.size sm)
           }
    addrs = nub (M.keys addrSpentMap ++ M.keys addrOutputMap)
    addrSpentMap =
        M.fromListWith (<>) (mapMaybe (uncurry spend) (M.toList spentMap))
    addrOutputMap =
        M.fromListWith (<>) (mapMaybe (uncurry newOutput) (M.toList newOutMap))
    spend outpoint spent@SpentValue {..} = do
        output@OutputValue {..} <- outpoint `M.lookup` prevMap
        address <- scriptToAddressBS outScript
        let key = AddrOutputKey (blockRefHeight outBlock) outpoint
            value = AddrOutputValue output (Just spent)
        return (address, M.singleton key value)
    newOutput outpoint output@OutputValue {..} = do
        address <- scriptToAddressBS outScript
        let key = AddrOutputKey (blockRefHeight outBlock) outpoint
            value = AddrOutputValue output Nothing
        return (address, M.singleton key value)

getSpentOutputs :: BlockRef -> Word32 -> Tx -> SpentMap
getSpentOutputs block pos tx = M.fromList (mapMaybe f (zip [0 ..] (txIn tx)))
  where
    f (i, TxIn {..}) =
        if outPointHash prevOutput == zero
            then Nothing
            else let key = prevOutput
                     val =
                         SpentValue
                         { spentInHash = txHash tx
                         , spentInIndex = i
                         , spentInBlock = block
                         , spentInPos = pos
                         }
                 in Just (key, val)

getNewOutputs :: BlockRef -> Word32 -> Tx -> OutputMap
getNewOutputs block pos tx = foldl' f M.empty (zip [0 ..] (txOut tx))
  where
    f m (i, TxOut {..}) =
        let key = OutPoint (txHash tx) i
            val =
                OutputValue
                { outputValue = outValue
                , outBlock = block
                , outScript = scriptOutput
                , outPos = pos
                }
        in M.insert key val m

getPrevOutputs :: MonadBlock m => Tx -> PrevOutMap -> m PrevOutMap
getPrevOutputs tx prevOutMap = foldM f M.empty (map prevOutput (txIn tx))
  where
    f m outpoint@OutPoint {..} = do
        let key = outpoint
        maybeOutput <-
            if outPointHash == zero
                then return Nothing
                else do
                    maybeOutput <- getOutPointData key prevOutMap
                    case maybeOutput of
                        Just output -> return (Just output)
                        Nothing -> do
                            let msg = "Could not get previous output"
                            $(logError) $ logMe <> cs msg
                            error msg
        case maybeOutput of
            Nothing -> return m
            Just output -> return (M.insert key output m)

getOutPointData ::
       MonadBlock m
    => OutPoint
    -> PrevOutMap
    -> m (Maybe OutputValue)
getOutPointData key os = runMaybeT (fromMap <|> fromCache <|> fromDB)
  where
    hash = outPointHash key
    index = outPointIndex key
    fromMap = MaybeT (return (M.lookup key os))
    fromDB = do
        db <- asks myBlockDB
        asks myCacheNo >>= \n ->
            when (n /= 0) . $(logDebug) $
            logMe <> "Cache miss for output " <> cs (show hash) <> "/" <>
            cs (show index)
        MaybeT $ retrieveValue (OutputKey key) db Nothing
    fromCache = do
        guard . (/= 0) =<< asks myCacheNo
        ubox <- asks myUnspentCache
        cache@UnspentCache {..} <- liftIO $ readTVarIO ubox
        m <- MaybeT . return $ M.lookup key unspentCache
        $(logDebug) $
            logMe <> "Cache hit for output " <> cs (show hash) <> "/" <>
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

addToCache :: MonadBlock m => BlockRef -> [(OutPoint, OutputValue)] -> m ()
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
        Just _  -> g s
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
                , addressTxPos = outPos (addrUnspentOutput v)
                }
                | (k, v) <- us
                ]
            stx =
                [ AddressTx
                { addressTxAddress = addr
                , addressTxId = outPointHash (outPoint (addrSpentOutPoint k))
                , addressTxAmount = fromIntegral (outputValue (addrSpentOutput v))
                , addressTxBlock = outBlock (addrSpentOutput v)
                , addressTxPos = outPos (addrSpentOutput v)
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
        , unspentPos = outPos addrUnspentOutput
        }

logMe :: Text
logMe = "[Block] "

zero :: TxHash
zero = "0000000000000000000000000000000000000000000000000000000000000000"
