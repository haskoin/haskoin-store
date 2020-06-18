{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections     #-}
module Haskoin.Store.BlockStore
    ( -- * Block Store
      BlockStore
    , BlockStoreMessage
    , BlockStoreInbox
    , BlockStoreConfig(..)
    , blockStore
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
import           Haskoin.Store.Data            (TxData (..), TxRef (..),
                                                Unspent (..))
import           Haskoin.Store.Database.Reader (DatabaseReader)
import           Haskoin.Store.Database.Writer
import           Haskoin.Store.Logic           (ImportException (Orphan),
                                                deleteUnconfirmedTx,
                                                getOldMempool, importBlock,
                                                initBest, newMempoolTx,
                                                revertBlock)
import           NQE                           (Inbox, Listen, Mailbox,
                                                Publisher, inboxToMailbox,
                                                publish, query, receive, send,
                                                sendSTM)
import           System.Random                 (randomRIO)
import           UnliftIO                      (Exception, MonadIO,
                                                MonadUnliftIO, STM, TVar, async,
                                                atomically, liftIO, modifyTVar,
                                                newTVarIO, readTVar, readTVarIO,
                                                throwIO, withAsync, writeTVar)
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

type BlockStoreInbox = Inbox BlockStoreMessage
type BlockStore = Mailbox BlockStoreMessage

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
data BlockRead =
    BlockRead
        { mySelf    :: !BlockStore
        , myConfig  :: !BlockStoreConfig
        , myPeer    :: !(TVar (Maybe Syncing))
        , myTxs     :: !(TVar (HashMap TxHash PendingTx))
        , requested :: !(TVar (HashSet TxHash))
        }

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
        , blockConfWipeMempool :: !Bool
        -- ^ wipe mempool at start
        , blockConfPeerTimeout :: !NominalDiffTime
        -- ^ disconnect syncing peer if inactive for this long
        }

type BlockT m = ReaderT BlockRead m

runImport :: MonadLoggerIO m
          => WriterT (ExceptT ImportException m) a
          -> BlockT m (Either ImportException a)
runImport f =
    ReaderT $ \r -> runExceptT $ runWriter (blockConfDB (myConfig r)) f

runRocksDB :: ReaderT DatabaseReader m a -> BlockT m a
runRocksDB f =
    ReaderT $ runReaderT f . blockConfDB . myConfig

instance MonadIO m => StoreRead (BlockT m) where
    getMaxGap =
        runRocksDB getMaxGap
    getInitialGap =
        runRocksDB getInitialGap
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
    getSpenders =
        runRocksDB . getSpenders
    getUnspent =
        runRocksDB . getUnspent
    getBalance =
        runRocksDB . getBalance
    getMempool =
        runRocksDB getMempool
    getAddressesTxs as =
        runRocksDB . getAddressesTxs as
    getAddressesUnspents as =
        runRocksDB . getAddressesUnspents as
    getAddressUnspents a =
        runRocksDB . getAddressUnspents a
    getAddressTxs a =
        runRocksDB . getAddressTxs a

-- | Run block store process.
blockStore ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => BlockStoreConfig
    -> BlockStoreInbox
    -> m ()
blockStore cfg inbox = do
    pb <- newTVarIO Nothing
    ts <- newTVarIO HashMap.empty
    rq <- newTVarIO HashSet.empty
    runReaderT
        (ini >> wipe >> run)
        BlockRead { mySelf = inboxToMailbox inbox
                  , myConfig = cfg
                  , myPeer = pb
                  , myTxs = ts
                  , requested = rq
                  }
  where
    del txs = do
        $(logInfoS) "BlockStore" $
            "Deleting " <> cs (show (length txs)) <> " transactions"
        forM_ txs $ \tx ->
            deleteUnconfirmedTx False (txRefHash tx)
    wipeit txs = do
        let (txs1, txs2) = splitAt 1000 txs
        unless (null txs1) $
            runImport (del txs1) >>= \case
                Left e -> do
                    $(logErrorS) "BlockStore" $
                        "Could not wipe mempool: " <> cs (show e)
                    throwIO e
                Right () -> wipeit txs2
    wipe
        | blockConfWipeMempool cfg =
              getMempool >>= wipeit
        | otherwise =
              return ()
    ini = runImport initBest >>= \case
              Left e -> do
                  $(logErrorS) "BlockStore" $
                      "Could not initialize: " <> cs (show e)
                  throwIO e
              Right () -> return ()
    run = withAsync (pingMe (inboxToMailbox inbox))
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

mempool :: MonadLoggerIO m => Peer -> m ()
mempool p = do
    $(logDebugS) "BlockStore" $
        "Requesting mempool from peer: " <> peerText p
    MMempool `sendMessage` p

processBlock :: MonadLoggerIO m => Peer -> Block -> BlockT m ()
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
    lift $ runImport (importBlock block node) >>= \case
        Left e -> failure e
        Right () -> success node
  where
    header = blockHeader block
    blockhash = headerHash header
    hexhash = blockHashToHex blockhash
    success node = do
        $(logInfoS) "BlockStore" $
            "Best block: " <> blockText node (Just block)
        notify
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
    notify = do
        listener <- asks (blockConfListener . myConfig)
        publish (StoreBestBlock blockhash) listener

setSyncingBlocks :: (MonadReader BlockRead m, MonadIO m)
                 => [BlockHash] -> m ()
setSyncingBlocks hs =
    asks myPeer >>= \box ->
    atomically $ modifyTVar box $ \case
        Nothing -> Nothing
        Just x  -> Just x { syncingBlocks = hs }

getSyncingBlocks :: (MonadReader BlockRead m, MonadIO m) => m [BlockHash]
getSyncingBlocks =
    asks myPeer >>= readTVarIO >>= \case
        Nothing -> return []
        Just x  -> return $ syncingBlocks x

addSyncingBlocks :: (MonadReader BlockRead m, MonadIO m)
                 => [BlockHash] -> m ()
addSyncingBlocks hs =
    asks myPeer >>= \box ->
    atomically $ modifyTVar box $ \case
        Nothing -> Nothing
        Just x  -> Just x { syncingBlocks = syncingBlocks x <> hs }

removeSyncingBlock :: (MonadReader BlockRead m, MonadIO m)
                   => BlockHash -> m ()
removeSyncingBlock h = do
    box <- asks myPeer
    atomically $ modifyTVar box $ \case
        Nothing -> Nothing
        Just x  -> Just x { syncingBlocks = delete h (syncingBlocks x) }

checkPeer :: (MonadLoggerIO m, MonadReader BlockRead m) => Peer -> m Bool
checkPeer p =
    fmap syncingPeer <$> getSyncingState >>= \case
        Nothing -> return False
        Just p' -> return $ p == p'

getBlockNode :: (MonadLoggerIO m, MonadReader BlockRead m)
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
processTx p tx = do
    t <- liftIO getCurrentTime
    $(logDebugS) "BlockManager" $
        "Received tx " <> txHashToHex (txHash tx)
        <> " by peer: " <> peerText p
    addPendingTx $ PendingTx t tx HashSet.empty

pruneOrphans :: MonadIO m => BlockT m ()
pruneOrphans = do
    ts <- asks myTxs
    now <- liftIO getCurrentTime
    atomically . modifyTVar ts . HashMap.filter $ \p ->
        now `diffUTCTime` pendingTxTime p > 600

addPendingTx :: MonadIO m => PendingTx -> BlockT m ()
addPendingTx p = do
    ts <- asks myTxs
    atomically $ modifyTVar ts $ HashMap.insert th p
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
pendingTxs i = asks myTxs >>= \box -> atomically $ do
    pending <- readTVar box
    let (selected, rest) = select pending
    writeTVar box rest
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

fulfillOrphans :: MonadIO m => BlockRead -> TxHash -> m ()
fulfillOrphans block_read th =
    atomically $ modifyTVar box (HashMap.map fulfill)
  where
    box = myTxs block_read
    fulfill p = p {pendingDeps = HashSet.delete th (pendingDeps p)}

updateOrphans
    :: ( StoreRead m
       , MonadLoggerIO m
       , MonadReader BlockRead m
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
            => BlockRead
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
    => BlockRead
    -> UTCTime
    -> Tx
    -> WriterT m Bool
importMempoolTx block_read time tx =
    catchError new_mempool_tx handle_error
  where
    tx_hash = txHash tx
    handle_error Orphan = do
        newOrphanTx block_read time tx
        $(logWarnS) "BlockStore" $
            "Import tx " <> txHashToHex tx_hash
            <> ": Orphan"
        return False
    handle_error _ = do
        $(logWarnS) "BlockStore" $
            "Import tx " <> txHashToHex tx_hash
            <> ": Failed"
        return False
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
                $(logInfoS) "BlockStore" $
                    "Import tx " <> txHashToHex (txHash tx)
                    <> ": Already imported"
                return False

processMempool :: MonadLoggerIO m => BlockT m ()
processMempool = do
    txs <- pendingTxs 2000
    block_read <- ask
    unless (null txs) (import_txs block_read txs >>= success)
  where
    run_import block_read p =
        importMempoolTx
            block_read
            (pendingTxTime p)
            (pendingTx p) >>= \case
                True -> return $ Just (txHash (pendingTx p))
                False -> return Nothing
    import_txs block_read txs =
        let r = mapM (run_import block_read) txs
         in runImport r >>= \case
            Left e   -> report_error e >> return []
            Right ms -> return (catMaybes ms)
    report_error e = do
        $(logErrorS) "BlockImport" $
            "Error processing mempool: " <> cs (show e)
        throwIO e
    success = mapM_ notify
    notify txid = do
        listener <- asks (blockConfListener . myConfig)
        publish (StoreMempoolNew txid) listener

processTxs ::
       MonadLoggerIO m
    => Peer
    -> [TxHash]
    -> BlockT m ()
processTxs p hs = do
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
             , MonadReader BlockRead m
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

pruneMempool :: MonadLoggerIO m => BlockT m ()
pruneMempool = do
    s <- isInSync
    when s $ do
        now <- liftIO getCurrentTime
        let seconds = floor (utcTimeToPOSIXSeconds now)
        getOldMempool seconds >>= \old ->
            unless (null old) $
            runImport (mapM_ delete_it old) >>= \case
                Left e -> do
                    $(logErrorS) "BlockStore" $
                        "Could not prune mempool: "
                        <> cs (show e)
                    throwIO e
                Right x -> return x
  where
    delete_it txid = do
        $(logDebugS) "BlockStore" $
            "Deleting "
            <> ": " <> txHashToHex txid
            <> " (old mempool tx)"
        deleteUnconfirmedTx False txid

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
        False -> cont
  where
    cont = getSyncingState >>= \case
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

findAncestor :: (MonadLoggerIO m, MonadReader BlockRead m)
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

finishPeer :: (MonadLoggerIO m, MonadReader BlockRead m)
           => Peer -> m ()
finishPeer p = do
    box <- asks myPeer
    readTVarIO box >>= \case
        Just Syncing { syncingPeer = p' } | p == p' -> reset_it box
        _ -> return ()
  where
    reset_it box = do
        atomically $ writeTVar box Nothing
        $(logDebugS) "BlockStore" $ "Releasing peer: " <> peerText p
        setFree p

trySetPeer :: MonadLoggerIO m => Peer -> BlockT m Bool
trySetPeer p =
    getSyncingState >>= \case
        Just _ -> return False
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
            Just _ -> return ()
            Nothing -> online_peer
  where
    recurse [] = return ()
    recurse (p : ps) =
        trySetPeer p >>= \case
            False -> recurse ps
            True -> syncMe
    online_peer = do
        ops <- getPeers =<< asks (blockConfManager . myConfig)
        let ps = map onlinePeerMailbox ops
        recurse ps

trySyncingPeer :: MonadLoggerIO m => Peer -> BlockT m ()
trySyncingPeer p =
    isInSync >>= \case
        True -> return ()
        False -> trySetPeer p >>= \case
            False -> return ()
            True -> syncMe

getSyncingState
    :: (MonadIO m, MonadReader BlockRead m) => m (Maybe Syncing)
getSyncingState =
    readTVarIO =<< asks myPeer

clearSyncingState
    :: (MonadLoggerIO m, MonadReader BlockRead m) => m ()
clearSyncingState =
    asks myPeer >>= readTVarIO >>= \case
        Nothing -> return ()
        Just Syncing { syncingPeer = p } -> finishPeer p

processBlockStoreMessage
    :: MonadLoggerIO m => BlockStoreMessage -> BlockT m ()

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
    trySyncing
    processMempool
    pruneOrphans
    checkTime
    pruneMempool
    atomically (r ())

pingMe :: MonadLoggerIO m => BlockStore -> m ()
pingMe mbox =
    forever $ do
        delay <- liftIO $
            randomRIO (  100 * 1000
                      , 1000 * 1000 )
        threadDelay delay
        BlockPing `query` mbox

blockStorePeerConnect :: MonadIO m => Peer -> BlockStore -> m ()
blockStorePeerConnect peer store =
    BlockPeerConnect peer `send` store

blockStorePeerDisconnect
    :: MonadIO m => Peer -> BlockStore -> m ()
blockStorePeerDisconnect peer store =
    BlockPeerDisconnect peer `send` store

blockStoreHead
    :: MonadIO m => BlockNode -> BlockStore -> m ()
blockStoreHead node store =
    BlockNewBest node `send` store

blockStoreBlock
    :: MonadIO m => Peer -> Block -> BlockStore -> m ()
blockStoreBlock peer block store =
    BlockReceived peer block `send` store

blockStoreNotFound
    :: MonadIO m => Peer -> [BlockHash] -> BlockStore -> m ()
blockStoreNotFound peer blocks store =
    BlockNotFound peer blocks `send` store

blockStoreTx
    :: MonadIO m => Peer -> Tx -> BlockStore -> m ()
blockStoreTx peer tx store =
    TxRefReceived peer tx `send` store

blockStoreTxHash
    :: MonadIO m => Peer -> [TxHash] -> BlockStore -> m ()
blockStoreTxHash peer txhashes store =
    TxRefAvailable peer txhashes `send` store

blockStorePeerConnectSTM
    :: Peer -> BlockStore -> STM ()
blockStorePeerConnectSTM peer store =
    BlockPeerConnect peer `sendSTM` store

blockStorePeerDisconnectSTM
    :: Peer -> BlockStore -> STM ()
blockStorePeerDisconnectSTM peer store =
    BlockPeerDisconnect peer `sendSTM` store

blockStoreHeadSTM
    :: BlockNode -> BlockStore -> STM ()
blockStoreHeadSTM node store =
    BlockNewBest node `sendSTM` store

blockStoreBlockSTM
    :: Peer -> Block -> BlockStore -> STM ()
blockStoreBlockSTM peer block store =
    BlockReceived peer block `sendSTM` store

blockStoreNotFoundSTM
    :: Peer -> [BlockHash] -> BlockStore -> STM ()
blockStoreNotFoundSTM peer blocks store =
    BlockNotFound peer blocks `sendSTM` store

blockStoreTxSTM
    :: Peer -> Tx -> BlockStore -> STM ()
blockStoreTxSTM peer tx store =
    TxRefReceived peer tx `sendSTM` store

blockStoreTxHashSTM
    :: Peer -> [TxHash] -> BlockStore -> STM ()
blockStoreTxHashSTM peer txhashes store =
    TxRefAvailable peer txhashes `sendSTM` store

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
