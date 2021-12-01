{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections     #-}
module Haskoin.Store.BlockStore
    ( -- * Block Store
      BlockStore
    , BlockStoreConfig(..)
    , withBlockStore
    , blockStorePeerConnect
    , blockStorePeerConnectSTM
    , blockStorePeerDisconnect
    , blockStorePeerDisconnectSTM
    , blockStoreHead
    , blockStoreHeadSTM
    , blockStoreBlock
    , blockStoreBlockSTM
    , blockStoreNotFound
    , blockStoreNotFoundSTM
    , blockStoreTx
    , blockStoreTxSTM
    , blockStoreTxHash
    , blockStoreTxHashSTM
    , blockStorePendingTxs
    , blockStorePendingTxsSTM
    ) where

import           Control.Monad                 (forM, forM_, forever, mzero,
                                                unless, void, when)
import           Control.Monad.Except          (ExceptT (..), MonadError,
                                                catchError, runExceptT)
import           Control.Monad.Logger          (MonadLoggerIO, logDebugS,
                                                logErrorS, logInfoS, logWarnS)
import           Control.Monad.Reader          (MonadReader, ReaderT (..), ask,
                                                asks)
import           Control.Monad.Trans           (lift)
import           Control.Monad.Trans.Maybe     (runMaybeT)
import qualified Data.ByteString               as B
import           Data.HashMap.Strict           (HashMap)
import qualified Data.HashMap.Strict           as HashMap
import           Data.HashSet                  (HashSet)
import qualified Data.HashSet                  as HashSet
import           Data.List                     (delete)
import           Data.Maybe                    (catMaybes, fromJust, isJust,
                                                mapMaybe)
import           Data.Serialize                (encode)
import           Data.String                   (fromString)
import           Data.String.Conversions       (cs)
import           Data.Text                     (Text)
import           Data.Time.Clock               (NominalDiffTime, UTCTime,
                                                diffUTCTime, getCurrentTime)
import           Data.Time.Clock.POSIX         (posixSecondsToUTCTime,
                                                utcTimeToPOSIXSeconds)
import           Data.Time.Format              (defaultTimeLocale, formatTime,
                                                iso8601DateFormat)
import           Haskoin                       (Block (..), BlockHash (..),
                                                BlockHeader (..), BlockHeight,
                                                BlockNode (..), GetData (..),
                                                InvType (..), InvVector (..),
                                                Message (..), Network (..),
                                                OutPoint (..), Tx (..),
                                                TxHash (..), TxIn (..),
                                                blockHashToHex, headerHash,
                                                txHash, txHashToHex)
import           Haskoin.Node                  (Chain, OnlinePeer (..), Peer,
                                                PeerException (..), PeerManager,
                                                chainBlockMain,
                                                chainGetAncestor, chainGetBest,
                                                chainGetBlock, chainGetParents,
                                                getPeers, killPeer, peerText,
                                                sendMessage, setBusy, setFree)
import           Haskoin.Store.Common
import           Haskoin.Store.Data
import           Haskoin.Store.Database.Reader
import           Haskoin.Store.Database.Writer
import           Haskoin.Store.Logic           (ImportException (Orphan),
                                                deleteUnconfirmedTx,
                                                importBlock, initBest,
                                                newMempoolTx, revertBlock)
import           Haskoin.Store.Stats
import           NQE                           (Listen, Mailbox, Publisher,
                                                inboxToMailbox, newInbox,
                                                publish, query, receive, send,
                                                sendSTM)
import qualified System.Metrics                as Metrics
import qualified System.Metrics.Gauge          as Metrics (Gauge)
import qualified System.Metrics.Gauge          as Metrics.Gauge
import           System.Random                 (randomRIO)
import           UnliftIO                      (Exception, MonadIO,
                                                MonadUnliftIO, STM, TVar, async,
                                                atomically, liftIO, link,
                                                modifyTVar, newTVarIO, readTVar,
                                                readTVarIO, throwIO, withAsync,
                                                writeTVar)
import           UnliftIO.Concurrent           (threadDelay)

data BlockStoreMessage
    = BlockNewBest !BlockNode
    | BlockPeerConnect !Peer
    | BlockPeerDisconnect !Peer
    | BlockReceived !Peer !Block
    | BlockNotFound !Peer ![BlockHash]
    | TxRefReceived !Peer !Tx
    | TxRefAvailable !Peer ![TxHash]
    | BlockPing !(Listen ())

data BlockException
    = BlockNotInChain !BlockHash
    | Uninitialized
    | CorruptDatabase
    | AncestorNotInChain !BlockHeight !BlockHash
    | MempoolImportFailed
    deriving (Show, Eq, Ord, Exception)

data Syncing =
    Syncing
        { syncingPeer   :: !Peer
        , syncingTime   :: !UTCTime
        , syncingBlocks :: ![BlockHash]
        }

data PendingTx =
    PendingTx
        { pendingTxTime :: !UTCTime
        , pendingTx     :: !Tx
        , pendingDeps   :: !(HashSet TxHash)
        }
    deriving (Show, Eq, Ord)

-- | Block store process state.
data BlockStore =
    BlockStore
        { myMailbox :: !(Mailbox BlockStoreMessage)
        , myConfig  :: !BlockStoreConfig
        , myPeer    :: !(TVar (Maybe Syncing))
        , myTxs     :: !(TVar (HashMap TxHash PendingTx))
        , requested :: !(TVar (HashSet TxHash))
        , myMetrics :: !(Maybe StoreMetrics)
        }

data StoreMetrics = StoreMetrics
    { storeHeight         :: !Metrics.Gauge
    , headersHeight       :: !Metrics.Gauge
    , storePendingTxs     :: !Metrics.Gauge
    , storePeersConnected :: !Metrics.Gauge
    , storeMempoolSize    :: !Metrics.Gauge
    }

newStoreMetrics :: MonadIO m => Metrics.Store -> m StoreMetrics
newStoreMetrics s = liftIO $ do
    storeHeight             <- g "height"
    headersHeight           <- g "headers"
    storePendingTxs         <- g "pending_txs"
    storePeersConnected     <- g "peers_connected"
    storeMempoolSize        <- g "mempool_size"
    return StoreMetrics{..}
  where
    g x = Metrics.createGauge   ("store." <> x) s

setStoreHeight :: MonadIO m => BlockT m ()
setStoreHeight =
    asks myMetrics >>= \case
    Nothing -> return ()
    Just m ->
        getBestBlock >>= \case
        Nothing -> setit m 0
        Just bb -> getBlock bb >>= \case
            Nothing -> setit m 0
            Just b  -> setit m (blockDataHeight b)
  where
    setit m i = liftIO $ storeHeight m `Metrics.Gauge.set` fromIntegral i

setHeadersHeight :: MonadIO m => BlockT m ()
setHeadersHeight =
    asks myMetrics >>= \case
    Nothing -> return ()
    Just m -> do
        h <- fmap nodeHeight $ chainGetBest =<< asks (blockConfChain . myConfig)
        liftIO $ headersHeight m `Metrics.Gauge.set` fromIntegral h

setPendingTxs :: MonadIO m => BlockT m ()
setPendingTxs =
    asks myMetrics >>= \case
    Nothing -> return ()
    Just m -> do
        s <- asks myTxs >>= \t -> atomically (HashMap.size <$> readTVar t)
        liftIO $ storePendingTxs m `Metrics.Gauge.set` fromIntegral s

setPeersConnected :: MonadIO m => BlockT m ()
setPeersConnected =
    asks myMetrics >>= \case
    Nothing -> return ()
    Just m -> do
        ps <- fmap length $ getPeers =<< asks (blockConfManager . myConfig)
        liftIO $ storePeersConnected m `Metrics.Gauge.set` fromIntegral ps

setMempoolSize :: MonadIO m => BlockT m ()
setMempoolSize =
    asks myMetrics >>= \case
    Nothing -> return ()
    Just m -> do
        s <- length <$> getMempool
        liftIO $ storeMempoolSize m `Metrics.Gauge.set` fromIntegral s

-- | Configuration for a block store.
data BlockStoreConfig =
    BlockStoreConfig
        { blockConfManager     :: !PeerManager
        -- ^ peer manager from running node
        , blockConfChain       :: !Chain
        -- ^ chain from a running node
        , blockConfListener    :: !(Publisher StoreEvent)
        -- ^ listener for store events
        , blockConfDB          :: !DatabaseReader
        -- ^ RocksDB database handle
        , blockConfNet         :: !Network
        -- ^ network constants
        , blockConfNoMempool   :: !Bool
        -- ^ do not index new mempool transactions
        , blockConfWipeMempool :: !Bool
        -- ^ wipe mempool at start
        , blockConfSyncMempool :: !Bool
        -- ^ sync mempool from peers
        , blockConfPeerTimeout :: !NominalDiffTime
        -- ^ disconnect syncing peer if inactive for this long
        , blockConfStats       :: !(Maybe Metrics.Store)
        }

type BlockT m = ReaderT BlockStore m

runImport :: MonadLoggerIO m
          => WriterT (ExceptT ImportException m) a
          -> BlockT m (Either ImportException a)
runImport f =
    ReaderT $ \r -> runExceptT $ runWriter (blockConfDB (myConfig r)) f

runRocksDB :: ReaderT DatabaseReader m a -> BlockT m a
runRocksDB f =
    ReaderT $ runReaderT f . blockConfDB . myConfig

instance MonadIO m => StoreReadBase (BlockT m) where
    getNetwork =
        runRocksDB getNetwork
    getBestBlock =
        runRocksDB getBestBlock
    getBlocksAtHeight =
        runRocksDB . getBlocksAtHeight
    getBlock =
        runRocksDB . getBlock
    getTxData =
        runRocksDB . getTxData
    getSpender =
        runRocksDB . getSpender
    getUnspent =
        runRocksDB . getUnspent
    getBalance =
        runRocksDB . getBalance
    getMempool =
        runRocksDB getMempool

instance MonadUnliftIO m => StoreReadExtra (BlockT m) where
    getMaxGap =
        runRocksDB getMaxGap
    getInitialGap =
        runRocksDB getInitialGap
    getAddressesTxs as =
        runRocksDB . getAddressesTxs as
    getAddressesUnspents as =
        runRocksDB . getAddressesUnspents as
    getAddressUnspents a =
        runRocksDB . getAddressUnspents a
    getAddressTxs a =
        runRocksDB . getAddressTxs a
    getNumTxData =
        runRocksDB . getNumTxData

-- | Run block store process.
withBlockStore ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => BlockStoreConfig
    -> (BlockStore -> m a)
    -> m a
withBlockStore cfg action = do
    pb <- newTVarIO Nothing
    ts <- newTVarIO HashMap.empty
    rq <- newTVarIO HashSet.empty
    inbox <- newInbox
    metrics <- mapM newStoreMetrics (blockConfStats cfg)
    let r = BlockStore { myMailbox = inboxToMailbox inbox
                       , myConfig = cfg
                       , myPeer = pb
                       , myTxs = ts
                       , requested = rq
                       , myMetrics = metrics
                       }
    withAsync (runReaderT (go inbox) r) $ \a -> do
        link a
        action r
  where
    go inbox = do
        ini
        wipe
        run inbox
    del txs = do
        $(logInfoS) "BlockStore" $
            "Deleting " <> cs (show (length txs)) <> " transactions"
        forM_ txs $ \(_, th) -> deleteUnconfirmedTx False th
    wipe_it txs = do
        let (txs1, txs2) = splitAt 1000 txs
        unless (null txs1) $
            runImport (del txs1) >>= \case
                Left e -> do
                    $(logErrorS) "BlockStore" $
                        "Could not wipe mempool: " <> cs (show e)
                    throwIO e
                Right () -> wipe_it txs2
    wipe
        | blockConfWipeMempool cfg =
              getMempool >>= wipe_it
        | otherwise =
              return ()
    ini = runImport initBest >>= \case
              Left e -> do
                  $(logErrorS) "BlockStore" $
                      "Could not initialize: " <> cs (show e)
                  throwIO e
              Right () -> return ()
    run inbox =
          withAsync (pingMe (inboxToMailbox inbox))
          $ const
          $ forever
          $ receive inbox >>=
          ReaderT . runReaderT . processBlockStoreMessage

isInSync :: MonadLoggerIO m => BlockT m Bool
isInSync =
    getBestBlock >>= \case
        Nothing -> do
            $(logErrorS) "BlockStore" "Block database uninitialized"
            throwIO Uninitialized
        Just bb -> do
            cb <- asks (blockConfChain . myConfig) >>= chainGetBest
            if headerHash (nodeHeader cb) == bb
                then clearSyncingState >> return True
                else return False

guardMempool :: Monad m => BlockT m () -> BlockT m ()
guardMempool f = do
    n <- asks (blockConfNoMempool . myConfig)
    unless n f

syncMempool :: Monad m => BlockT m () -> BlockT m ()
syncMempool f = do
    s <- asks (blockConfSyncMempool . myConfig)
    when s f

mempool :: (MonadUnliftIO m, MonadLoggerIO m) => Peer -> BlockT m ()
mempool p = guardMempool $ syncMempool $ void $ async $ do
    isInSync >>= \s -> when s $ do
        $(logDebugS) "BlockStore" $
            "Requesting mempool from peer: " <> peerText p
        MMempool `sendMessage` p

processBlock :: (MonadUnliftIO m, MonadLoggerIO m)
             => Peer -> Block -> BlockT m ()
processBlock peer block = void . runMaybeT $ do
    checkPeer peer >>= \case
        True -> return ()
        False -> do
            $(logErrorS) "BlockStore" $
                "Non-syncing peer " <> peerText peer
                <> " sent me a block: "
                <> blockHashToHex blockhash
            PeerMisbehaving "Sent unexpected block" `killPeer` peer
            mzero
    node <- getBlockNode blockhash >>= \case
        Just b -> return b
        Nothing -> do
            $(logErrorS) "BlockStore" $
                "Peer " <> peerText peer
                <> " sent unknown block: "
                <> blockHashToHex blockhash
            PeerMisbehaving "Sent unknown block" `killPeer` peer
            mzero
    $(logDebugS) "BlockStore" $
        "Processing block: " <> blockText node Nothing
        <> " from peer: " <> peerText peer
    lift . notify (Just block) $
        runImport (importBlock block node) >>= \case
            Left e   -> failure e
            Right () -> success node
  where
    header = blockHeader block
    blockhash = headerHash header
    hexhash = blockHashToHex blockhash
    success node = do
        $(logInfoS) "BlockStore" $
            "Best block: " <> blockText node (Just block)
        removeSyncingBlock $ headerHash $ nodeHeader node
        touchPeer
        isInSync >>= \case
            False -> syncMe
            True -> do
                updateOrphans
                mempool peer
    failure e = do
        $(logErrorS) "BlockStore" $
            "Error importing block " <> hexhash
            <> " from peer: " <> peerText peer <> ": "
            <> cs (show e)
        killPeer (PeerMisbehaving (show e)) peer

setSyncingBlocks :: (MonadReader BlockStore m, MonadIO m)
                 => [BlockHash] -> m ()
setSyncingBlocks hs =
    asks myPeer >>= \box ->
    atomically $ modifyTVar box $ \case
        Nothing -> Nothing
        Just x  -> Just x { syncingBlocks = hs }

getSyncingBlocks :: (MonadReader BlockStore m, MonadIO m) => m [BlockHash]
getSyncingBlocks =
    asks myPeer >>= readTVarIO >>= \case
        Nothing -> return []
        Just x  -> return $ syncingBlocks x

addSyncingBlocks :: (MonadReader BlockStore m, MonadIO m)
                 => [BlockHash] -> m ()
addSyncingBlocks hs =
    asks myPeer >>= \box ->
    atomically $ modifyTVar box $ \case
        Nothing -> Nothing
        Just x  -> Just x { syncingBlocks = syncingBlocks x <> hs }

removeSyncingBlock :: (MonadReader BlockStore m, MonadIO m)
                   => BlockHash -> m ()
removeSyncingBlock h = do
    box <- asks myPeer
    atomically $ modifyTVar box $ \case
        Nothing -> Nothing
        Just x  -> Just x { syncingBlocks = delete h (syncingBlocks x) }

checkPeer :: (MonadLoggerIO m, MonadReader BlockStore m) => Peer -> m Bool
checkPeer p =
    fmap syncingPeer <$> getSyncingState >>= \case
        Nothing -> return False
        Just p' -> return $ p == p'

getBlockNode :: (MonadLoggerIO m, MonadReader BlockStore m)
             => BlockHash -> m (Maybe BlockNode)
getBlockNode blockhash =
    chainGetBlock blockhash =<< asks (blockConfChain . myConfig)

processNoBlocks ::
       MonadLoggerIO m
    => Peer
    -> [BlockHash]
    -> BlockT m ()
processNoBlocks p hs = do
    forM_ (zip [(1 :: Int) ..] hs) $ \(i, h) ->
        $(logErrorS) "BlockStore" $
            "Block "
            <> cs (show i) <> "/"
            <> cs (show (length hs)) <> " "
            <> blockHashToHex h
            <> " not found by peer: "
            <> peerText p
    killPeer (PeerMisbehaving "Did not find requested block(s)") p

processTx :: MonadLoggerIO m => Peer -> Tx -> BlockT m ()
processTx p tx = guardMempool $ do
    t <- liftIO getCurrentTime
    $(logDebugS) "BlockManager" $
        "Received tx " <> txHashToHex (txHash tx)
        <> " by peer: " <> peerText p
    addPendingTx $ PendingTx t tx HashSet.empty

pruneOrphans :: MonadIO m => BlockT m ()
pruneOrphans = guardMempool $ do
    ts <- asks myTxs
    now <- liftIO getCurrentTime
    atomically . modifyTVar ts . HashMap.filter $ \p ->
        now `diffUTCTime` pendingTxTime p > 600

addPendingTx :: MonadIO m => PendingTx -> BlockT m ()
addPendingTx p = do
    ts <- asks myTxs
    rq <- asks requested
    atomically $ do
        modifyTVar ts $ HashMap.insert th p
        modifyTVar rq $ HashSet.delete th
        HashMap.size <$> readTVar ts
    setPendingTxs
  where
    th = txHash (pendingTx p)

addRequestedTx :: MonadIO m => TxHash -> BlockT m ()
addRequestedTx th = do
    qbox <- asks requested
    atomically $ modifyTVar qbox $ HashSet.insert th
    liftIO $ void $ async $ do
        threadDelay 20000000
        atomically $ modifyTVar qbox $ HashSet.delete th

isPending :: MonadIO m => TxHash -> BlockT m Bool
isPending th = do
    tbox <- asks myTxs
    qbox  <- asks requested
    atomically $ do
        ts <- readTVar tbox
        rs <- readTVar qbox
        return $ th `HashMap.member` ts
              || th `HashSet.member` rs

pendingTxs :: MonadIO m => Int -> BlockT m [PendingTx]
pendingTxs i = do
    selected <- asks myTxs >>= \box -> atomically $ do
        pending <- readTVar box
        let (selected, rest) = select pending
        writeTVar box rest
        return (selected)
    setPendingTxs
    return selected
  where
    select pend =
        let eligible = HashMap.filter (null . pendingDeps) pend
            orphans = HashMap.difference pend eligible
            selected = take i $ sortit eligible
            remaining = HashMap.filter (`notElem` selected) eligible
         in (selected, remaining <> orphans)
    sortit m =
        let sorted = sortTxs $ map pendingTx $ HashMap.elems m
            txids = map (txHash . snd) sorted
         in mapMaybe (`HashMap.lookup` m) txids

fulfillOrphans :: MonadIO m => BlockStore -> TxHash -> m ()
fulfillOrphans block_read th =
    atomically $ modifyTVar box (HashMap.map fulfill)
  where
    box = myTxs block_read
    fulfill p = p {pendingDeps = HashSet.delete th (pendingDeps p)}

updateOrphans
    :: ( StoreReadBase m
       , MonadLoggerIO m
       , MonadReader BlockStore m
       )
    => m ()
updateOrphans = do
    box <- asks myTxs
    pending <- readTVarIO box
    let orphans = HashMap.filter (not . null . pendingDeps) pending
    updated <- forM orphans $ \p -> do
        let tx = pendingTx p
        exists (txHash tx) >>= \case
            True  -> return Nothing
            False -> Just <$> fill_deps p
    let pruned = HashMap.map fromJust $ HashMap.filter isJust updated
    atomically $ writeTVar box pruned
  where
    exists th = getTxData th >>= \case
        Nothing                             -> return False
        Just TxData {txDataDeleted = True}  -> return False
        Just TxData {txDataDeleted = False} -> return True
    prev_utxos tx = catMaybes <$> mapM (getUnspent . prevOutput) (txIn tx)
    fulfill p unspent =
        let unspent_hash = outPointHash (unspentPoint unspent)
            new_deps = HashSet.delete unspent_hash (pendingDeps p)
        in p {pendingDeps = new_deps}
    fill_deps p = do
        let tx = pendingTx p
        unspents <- prev_utxos tx
        return $ foldl fulfill p unspents

newOrphanTx :: MonadLoggerIO m
            => BlockStore
            -> UTCTime
            -> Tx
            -> WriterT m ()
newOrphanTx block_read time tx = do
    $(logDebugS) "BlockStore" $
        "Import tx "
        <> txHashToHex (txHash tx)
        <> ": Orphan"
    let box = myTxs block_read
    unspents <- catMaybes <$> mapM getUnspent prevs
    let unspent_set = HashSet.fromList (map unspentPoint unspents)
        missing_set = HashSet.difference prev_set unspent_set
        missing_txs = HashSet.map outPointHash missing_set
    atomically . modifyTVar box $
        HashMap.insert
        (txHash tx)
        PendingTx { pendingTxTime = time
                  , pendingTx = tx
                  , pendingDeps = missing_txs
                  }
  where
    prev_set = HashSet.fromList prevs
    prevs = map prevOutput (txIn tx)

importMempoolTx
    :: (MonadLoggerIO m, MonadError ImportException m)
    => BlockStore
    -> UTCTime
    -> Tx
    -> WriterT m Bool
importMempoolTx block_read time tx =
    catchError new_mempool_tx handle_error
  where
    tx_hash = txHash tx
    handle_error Orphan = do
        newOrphanTx block_read time tx
        return False
    handle_error _ = return False
    seconds = floor (utcTimeToPOSIXSeconds time)
    new_mempool_tx =
        newMempoolTx tx seconds >>= \case
            True -> do
                $(logInfoS) "BlockStore" $
                    "Import tx " <> txHashToHex (txHash tx)
                    <> ": OK"
                fulfillOrphans block_read tx_hash
                return True
            False -> do
                $(logDebugS) "BlockStore" $
                    "Import tx " <> txHashToHex (txHash tx)
                    <> ": Already imported"
                return False

notify :: MonadIO m => Maybe Block -> BlockT m a -> BlockT m a
notify block go = do
    old <- HashSet.union e . HashSet.fromList . map snd <$> getMempool
    x <- go
    new <- HashSet.fromList . map snd <$> getMempool
    l <- asks (blockConfListener . myConfig)
    forM_ (old `HashSet.difference` new) $ \h ->
        publish (StoreMempoolDelete h) l
    forM_ (new `HashSet.difference` old) $ \h ->
        publish (StoreMempoolNew h) l
    case block of
        Just b -> publish (StoreBestBlock (headerHash (blockHeader b))) l
        Nothing -> return ()
    return x
  where
    e = case block of
        Just b -> HashSet.fromList (map txHash (blockTxns b))
        Nothing -> HashSet.empty

processMempool :: MonadLoggerIO m => BlockT m ()
processMempool = guardMempool . notify Nothing $ do
    txs <- pendingTxs 2000
    block_read <- ask
    unless (null txs) (import_txs block_read txs)
  where
    run_import block_read p =
        let t = pendingTx p
            h = txHash t
        in importMempoolTx block_read (pendingTxTime p) (pendingTx p)
    import_txs block_read txs =
        let r = mapM (run_import block_read) txs
         in runImport r >>= \case
            Left e   -> report_error e
            Right _ -> return ()
    report_error e = do
        $(logErrorS) "BlockImport" $
            "Error processing mempool: " <> cs (show e)
        throwIO e

processTxs ::
       MonadLoggerIO m
    => Peer
    -> [TxHash]
    -> BlockT m ()
processTxs p hs = guardMempool $ do
    s <- isInSync
    when s $ do
        $(logDebugS) "BlockStore" $
            "Received inventory with "
            <> cs (show (length hs))
            <> " transactions from peer: "
            <> peerText p
        xs <- catMaybes <$> zip_counter process_tx
        unless (null xs) $ go xs
  where
    len = length hs
    zip_counter = forM (zip [(1 :: Int) ..] hs) . uncurry
    process_tx i h =
        isPending h >>= \case
            True -> do
                $(logDebugS) "BlockStore" $
                    "Tx " <> cs (show i) <> "/" <> cs (show len)
                    <> " " <> txHashToHex h <> ": "
                    <> "Pending"
                return Nothing
            False -> getActiveTxData h >>= \case
                Just _ -> do
                    $(logDebugS) "BlockStore" $
                        "Tx " <> cs (show i) <> "/" <> cs (show len)
                        <> " " <> txHashToHex h <> ": "
                        <> "Already Imported"
                    return Nothing
                Nothing -> do
                    $(logDebugS) "BlockStore" $
                        "Tx " <> cs (show i) <> "/" <> cs (show len)
                        <> " " <> txHashToHex h <> ": "
                        <> "Requesting"
                    return (Just h)
    go xs = do
        mapM_ addRequestedTx xs
        net <- asks (blockConfNet . myConfig)
        let inv = if getSegWit net then InvWitnessTx else InvTx
            vec = map (InvVector inv . getTxHash) xs
            msg = MGetData (GetData vec)
        msg `sendMessage` p

touchPeer :: ( MonadIO m
             , MonadReader BlockStore m
             )
          => m ()
touchPeer =
    getSyncingState >>= \case
        Nothing -> return ()
        Just _ -> do
            box <- asks myPeer
            now <- liftIO getCurrentTime
            atomically $
                modifyTVar box $
                fmap $ \x -> x { syncingTime = now }

checkTime :: MonadLoggerIO m => BlockT m ()
checkTime =
    asks myPeer >>= readTVarIO >>= \case
        Nothing -> return ()
        Just Syncing { syncingTime = t
                     , syncingPeer = p
                     } -> do
            now <- liftIO getCurrentTime
            peer_time_out <- asks (blockConfPeerTimeout . myConfig)
            when (now `diffUTCTime` t > peer_time_out) $ do
                $(logErrorS) "BlockStore" $
                    "Syncing peer timeout: " <> peerText p
                killPeer PeerTimeout p

revertToMainChain :: MonadLoggerIO m => BlockT m ()
revertToMainChain = do
    h <- headerHash . nodeHeader <$> getBest
    ch <- asks (blockConfChain . myConfig)
    chainBlockMain h ch >>= \x -> unless x $ do
        $(logWarnS) "BlockStore" $
            "Reverting best block: "
            <> blockHashToHex h
        runImport (revertBlock h) >>= \case
            Left e -> do
                $(logErrorS) "BlockStore" $
                    "Could not revert block "
                    <> blockHashToHex h
                    <> ": " <> cs (show e)
                throwIO e
            Right () -> setSyncingBlocks []
        revertToMainChain

getBest :: MonadLoggerIO m => BlockT m BlockNode
getBest = do
    bb <- getBestBlock >>= \case
        Just b -> return b
        Nothing -> do
            $(logErrorS) "BlockStore" "No best block set"
            throwIO Uninitialized
    ch <- asks (blockConfChain . myConfig)
    chainGetBlock bb ch >>= \case
        Just x -> return x
        Nothing -> do
            $(logErrorS) "BlockStore" $
                "Header not found for best block: "
                <> blockHashToHex bb
            throwIO (BlockNotInChain bb)

getSyncBest :: MonadLoggerIO m => BlockT m BlockNode
getSyncBest = do
    bb <- getSyncingBlocks >>= \case
        [] -> getBestBlock >>= \case
            Just b -> return b
            Nothing -> do
                $(logErrorS) "BlockStore" "No best block set"
                throwIO Uninitialized
        hs -> return $ last hs
    ch <- asks (blockConfChain . myConfig)
    chainGetBlock bb ch >>= \case
        Just x -> return x
        Nothing -> do
            $(logErrorS) "BlockStore" $
                "Header not found for block: "
                <> blockHashToHex bb
            throwIO (BlockNotInChain bb)

shouldSync :: MonadLoggerIO m => BlockT m (Maybe Peer)
shouldSync =
    isInSync >>= \case
        True -> return Nothing
        False -> getSyncingState >>= \case
            Nothing -> return Nothing
            Just Syncing { syncingPeer = p, syncingBlocks = bs }
                | 100 > length bs -> return (Just p)
                | otherwise -> return Nothing

syncMe :: MonadLoggerIO m => BlockT m ()
syncMe = do
    revertToMainChain
    shouldSync >>= \case
        Nothing -> return ()
        Just p -> do
            bb <- getSyncBest
            bh <- getbh
            when (bb /= bh) $ do
                bns <- sel bb bh
                iv <- getiv bns
                $(logDebugS) "BlockStore" $
                    "Requesting "
                    <> fromString (show (length iv))
                    <> " blocks from peer: " <> peerText p
                addSyncingBlocks $ map (headerHash . nodeHeader) bns
                MGetData (GetData iv) `sendMessage` p
  where
    getiv bns = do
        w <- getSegWit <$> asks (blockConfNet . myConfig)
        let i = if w then InvWitnessBlock else InvBlock
            f = InvVector i . getBlockHash . headerHash . nodeHeader
        return $ map f bns
    getbh =
        chainGetBest =<< asks (blockConfChain . myConfig)
    sel bb bh = do
        let sh = geth bb bh
        t <- top sh bh
        ch <- asks (blockConfChain . myConfig)
        ps <- chainGetParents (nodeHeight bb + 1) t ch
        return $ if 500 > length ps
                 then ps <> [bh]
                 else ps
    geth bb bh =
        min (nodeHeight bb + 501)
            (nodeHeight bh)
    top sh bh =
        if sh == nodeHeight bh
        then return bh
        else findAncestor sh bh

findAncestor :: (MonadLoggerIO m, MonadReader BlockStore m)
             => BlockHeight -> BlockNode -> m BlockNode
findAncestor height target = do
    ch <- asks (blockConfChain . myConfig)
    chainGetAncestor height target ch >>= \case
        Just ancestor -> return ancestor
        Nothing -> do
            let h = headerHash $ nodeHeader target
            $(logErrorS) "BlockStore" $
                "Could not find header for ancestor of block "
                <> blockHashToHex h <> " at height "
                <> cs (show (nodeHeight target))
            throwIO $ AncestorNotInChain height h

finishPeer :: (MonadLoggerIO m, MonadReader BlockStore m)
           => Peer -> m ()
finishPeer p = do
    box <- asks myPeer
    readTVarIO box >>= \case
        Just Syncing { syncingPeer = p' } | p == p' -> reset_it box
        _                                           -> return ()
  where
    reset_it box = do
        atomically $ writeTVar box Nothing
        $(logDebugS) "BlockStore" $ "Releasing peer: " <> peerText p
        setFree p

trySetPeer :: MonadLoggerIO m => Peer -> BlockT m Bool
trySetPeer p =
    getSyncingState >>= \case
        Just _  -> return False
        Nothing -> set_it
  where
    set_it =
        setBusy p >>= \case
            False -> return False
            True -> do
                $(logDebugS) "BlockStore" $
                    "Locked peer: " <> peerText p
                box <- asks myPeer
                now <- liftIO getCurrentTime
                atomically . writeTVar box $
                    Just Syncing { syncingPeer = p
                                  , syncingTime = now
                                  , syncingBlocks = []
                                  }
                return True

trySyncing :: MonadLoggerIO m => BlockT m ()
trySyncing =
    isInSync >>= \case
        True -> return ()
        False -> getSyncingState >>= \case
            Just _  -> return ()
            Nothing -> online_peer
  where
    recurse [] = return ()
    recurse (p : ps) =
        trySetPeer p >>= \case
            False -> recurse ps
            True  -> syncMe
    online_peer = do
        ops <- getPeers =<< asks (blockConfManager . myConfig)
        let ps = map onlinePeerMailbox ops
        recurse ps

trySyncingPeer :: (MonadUnliftIO m, MonadLoggerIO m) => Peer -> BlockT m ()
trySyncingPeer p =
    isInSync >>= \case
        True -> mempool p
        False -> trySetPeer p >>= \case
            False -> return ()
            True  -> syncMe

getSyncingState
    :: (MonadIO m, MonadReader BlockStore m) => m (Maybe Syncing)
getSyncingState =
    readTVarIO =<< asks myPeer

clearSyncingState
    :: (MonadLoggerIO m, MonadReader BlockStore m) => m ()
clearSyncingState =
    asks myPeer >>= readTVarIO >>= \case
        Nothing                          -> return ()
        Just Syncing { syncingPeer = p } -> finishPeer p

processBlockStoreMessage :: (MonadUnliftIO m, MonadLoggerIO m)
                         => BlockStoreMessage -> BlockT m ()

processBlockStoreMessage (BlockNewBest _) =
    trySyncing

processBlockStoreMessage (BlockPeerConnect p) =
    trySyncingPeer p

processBlockStoreMessage (BlockPeerDisconnect p) =
    finishPeer p

processBlockStoreMessage (BlockReceived p b) =
    processBlock p b

processBlockStoreMessage (BlockNotFound p bs) =
    processNoBlocks p bs

processBlockStoreMessage (TxRefReceived p tx) =
    processTx p tx

processBlockStoreMessage (TxRefAvailable p ts) =
    processTxs p ts

processBlockStoreMessage (BlockPing r) = do
    setStoreHeight
    setHeadersHeight
    setPendingTxs
    setPeersConnected
    setMempoolSize
    trySyncing
    processMempool
    pruneOrphans
    checkTime
    atomically (r ())

pingMe :: MonadLoggerIO m => Mailbox BlockStoreMessage -> m ()
pingMe mbox =
    forever $ do
        BlockPing `query` mbox
        delay <- liftIO $
            randomRIO (  100 * 1000
                      , 1000 * 1000 )
        threadDelay delay

blockStorePeerConnect :: MonadIO m => Peer -> BlockStore -> m ()
blockStorePeerConnect peer store =
    BlockPeerConnect peer `send` myMailbox store

blockStorePeerDisconnect
    :: MonadIO m => Peer -> BlockStore -> m ()
blockStorePeerDisconnect peer store =
    BlockPeerDisconnect peer `send` myMailbox store

blockStoreHead
    :: MonadIO m => BlockNode -> BlockStore -> m ()
blockStoreHead node store =
    BlockNewBest node `send` myMailbox store

blockStoreBlock
    :: MonadIO m => Peer -> Block -> BlockStore -> m ()
blockStoreBlock peer block store =
    BlockReceived peer block `send` myMailbox store

blockStoreNotFound
    :: MonadIO m => Peer -> [BlockHash] -> BlockStore -> m ()
blockStoreNotFound peer blocks store =
    BlockNotFound peer blocks `send` myMailbox store

blockStoreTx
    :: MonadIO m => Peer -> Tx -> BlockStore -> m ()
blockStoreTx peer tx store =
    TxRefReceived peer tx `send` myMailbox store

blockStoreTxHash
    :: MonadIO m => Peer -> [TxHash] -> BlockStore -> m ()
blockStoreTxHash peer txhashes store =
    TxRefAvailable peer txhashes `send` myMailbox store

blockStorePeerConnectSTM
    :: Peer -> BlockStore -> STM ()
blockStorePeerConnectSTM peer store =
    BlockPeerConnect peer `sendSTM` myMailbox store

blockStorePeerDisconnectSTM
    :: Peer -> BlockStore -> STM ()
blockStorePeerDisconnectSTM peer store =
    BlockPeerDisconnect peer `sendSTM` myMailbox store

blockStoreHeadSTM
    :: BlockNode -> BlockStore -> STM ()
blockStoreHeadSTM node store =
    BlockNewBest node `sendSTM` myMailbox store

blockStoreBlockSTM
    :: Peer -> Block -> BlockStore -> STM ()
blockStoreBlockSTM peer block store =
    BlockReceived peer block `sendSTM` myMailbox store

blockStoreNotFoundSTM
    :: Peer -> [BlockHash] -> BlockStore -> STM ()
blockStoreNotFoundSTM peer blocks store =
    BlockNotFound peer blocks `sendSTM` myMailbox store

blockStoreTxSTM
    :: Peer -> Tx -> BlockStore -> STM ()
blockStoreTxSTM peer tx store =
    TxRefReceived peer tx `sendSTM` myMailbox store

blockStoreTxHashSTM
    :: Peer -> [TxHash] -> BlockStore -> STM ()
blockStoreTxHashSTM peer txhashes store =
    TxRefAvailable peer txhashes `sendSTM` myMailbox store

blockStorePendingTxs
    :: MonadIO m => BlockStore -> m Int
blockStorePendingTxs =
    atomically . blockStorePendingTxsSTM

blockStorePendingTxsSTM
    :: BlockStore -> STM Int
blockStorePendingTxsSTM BlockStore {..} = do
    x <- HashMap.keysSet <$> readTVar myTxs
    y <- readTVar requested
    return $ HashSet.size $ x `HashSet.union` y

blockText :: BlockNode -> Maybe Block -> Text
blockText bn mblock = case mblock of
    Nothing ->
        height <> sep <> time <> sep <> hash
    Just block ->
        height <> sep <> time <> sep <> hash <> sep <> size block
  where
    height = cs $ show (nodeHeight bn)
    systime = posixSecondsToUTCTime
            $ fromIntegral
            $ blockTimestamp
            $ nodeHeader bn
    time =
        cs $ formatTime
                defaultTimeLocale
                (iso8601DateFormat (Just "%H:%M"))
                systime
    hash = blockHashToHex (headerHash (nodeHeader bn))
    sep = " | "
    size = (<> " bytes") . cs . show . B.length . encode
