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

import           Control.Applicative           ((<|>))
import           Control.Monad                 (forM, forM_, forever, mzero,
                                                unless, void, when)
import           Control.Monad.Logger          (MonadLoggerIO, logDebugS,
                                                logErrorS, logInfoS, logWarnS)
import           Control.Monad.Reader          (MonadReader, ReaderT (..), ask,
                                                asks)
import           Control.Monad.Trans           (lift)
import           Control.Monad.Trans.Maybe     (MaybeT (MaybeT), runMaybeT)
import qualified Data.ByteString               as B
import           Data.HashMap.Strict           (HashMap)
import qualified Data.HashMap.Strict           as HashMap
import           Data.HashSet                  (HashSet)
import qualified Data.HashSet                  as HashSet
import           Data.Maybe                    (catMaybes, fromJust, isJust,
                                                listToMaybe, mapMaybe)
import           Data.Serialize                (encode)
import           Data.String                   (fromString)
import           Data.String.Conversions       (cs)
import           Data.Text                     (Text)
import           Data.Time.Clock.POSIX         (posixSecondsToUTCTime)
import           Data.Time.Clock.System        (getSystemTime, systemSeconds)
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
                                                killPeer, managerGetPeer,
                                                managerGetPeers,
                                                managerPeerText, sendMessage)
import           Haskoin.Store.Common          (StoreEvent (..), StoreRead (..),
                                                sortTxs)
import           Haskoin.Store.Data            (TxData (..), TxRef (..),
                                                UnixTime, Unspent (..))
import           Haskoin.Store.Database.Reader (DatabaseReader)
import           Haskoin.Store.Database.Writer
import           Haskoin.Store.Logic           (ImportException (Orphan),
                                                deleteUnconfirmedTx,
                                                getOldMempool, importBlock,
                                                initBest, newMempoolTx,
                                                revertBlock)
import           Network.Socket                (SockAddr)
import           NQE                           (Inbox, Listen, Mailbox,
                                                inboxToMailbox, query, receive,
                                                send, sendSTM)
import           System.Random                 (randomRIO)
import           UnliftIO                      (Exception, MonadIO,
                                                MonadUnliftIO, STM, TVar,
                                                atomically, catch, liftIO,
                                                modifyTVar, newTVarIO, readTVar,
                                                readTVarIO, throwIO, withAsync,
                                                writeTVar)
import           UnliftIO.Concurrent           (threadDelay)

data BlockStoreMessage
    = BlockNewBest !BlockNode
    | BlockPeerConnect !Peer !SockAddr
    | BlockPeerDisconnect !Peer !SockAddr
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

data Syncing = Syncing
    { syncingPeer :: !Peer
    , syncingTime :: !UnixTime
    , syncingHead :: !BlockNode
    }

data PendingTx = PendingTx
    { pendingTxTime :: !UnixTime
    , pendingTx     :: !Tx
    , pendingDeps   :: !(HashSet TxHash)
    }
    deriving (Show, Eq, Ord)

-- | Block store process state.
data BlockRead = BlockRead
    { mySelf   :: !BlockStore
    , myConfig :: !BlockStoreConfig
    , myPeer   :: !(TVar (Maybe Syncing))
    , myTxs    :: !(TVar (HashMap TxHash PendingTx))
    }

-- | Configuration for a block store.
data BlockStoreConfig = BlockStoreConfig
    { blockConfManager     :: !PeerManager
    -- ^ peer manager from running node
    , blockConfChain       :: !Chain
    -- ^ chain from a running node
    , blockConfListener    :: !(Listen StoreEvent)
    -- ^ listener for store events
    , blockConfDB          :: !DatabaseReader
    -- ^ RocksDB database handle
    , blockConfNet         :: !Network
    -- ^ network constants
    , blockConfWipeMempool :: !Bool
    -- ^ wipe mempool at start
    , blockConfPeerTimeout :: !Int
    -- ^ disconnect syncing peer if inactive for this long
    }

type BlockT m = ReaderT BlockRead m

runImport :: MonadLoggerIO m => WriterT m a -> BlockT m a
runImport f = ReaderT $ \r -> runWriter (blockConfDB (myConfig r)) f

runRocksDB :: ReaderT DatabaseReader m a -> BlockT m a
runRocksDB f =
    ReaderT $ \BlockRead {myConfig = BlockStoreConfig {blockConfDB = db}} ->
        runReaderT f db

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
    runReaderT
        (ini >> wipe >> run)
        BlockRead { mySelf = inboxToMailbox inbox
                  , myConfig = cfg
                  , myPeer = pb
                  , myTxs = ts
                  }
  where
    del x n txs =
        forM_ (zip [x ..] txs) $ \(i, tx) -> do
            $(logInfoS) "BlockStore" $
                "Deleting "
                <> cs (show i) <> "/" <> cs (show n) <> ": "
                <> txHashToHex (txRefHash tx) <> "…"
            deleteUnconfirmedTx False (txRefHash tx)
    wipeit x n txs = do
        let (txs1, txs2) = splitAt 1000 txs
        unless (null txs1) $ do
            runImport (del x n txs1)
            wipeit (x + length txs1) n txs2
    wipe
        | blockConfWipeMempool cfg =
            getMempool >>= \mem -> wipeit 1 (length mem) mem
        | otherwise = return ()
    ini = runImport initBest
    run = withAsync (pingMe (inboxToMailbox inbox)) . const . forever $
        receive inbox >>= ReaderT . runReaderT . processBlockStoreMessage

isInSync :: MonadLoggerIO m => BlockT m Bool
isInSync = getBestBlock >>= \case
    Nothing -> do
        $(logErrorS) "BlockStore" "Block database uninitialized"
        throwIO Uninitialized
    Just bb -> do
        cb <- asks (blockConfChain . myConfig) >>= chainGetBest
        return (headerHash (nodeHeader cb) == bb)

mempool :: MonadLoggerIO m => Peer -> m ()
mempool p = do
    $(logDebugS) "BlockStore" "Requesting mempool from network peer"
    MMempool `sendMessage` p

processBlock ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Peer
    -> Block
    -> BlockT m ()
processBlock peer block = void . runMaybeT $ do
    checks <- checkPeer peer
    unless checks mzero
    blocknode <- MaybeT $ getBlockNode peer blockhash
    pt <- managerPeerText peer =<< asks (blockConfManager . myConfig)
    $(logDebugS) "BlockStore" $
        "Processing block : " <> blockText blocknode Nothing
        <> " (peer" <> pt <> ")"
    let do_import = runImport $ importBlock block blocknode
    lift $ catch (do_import >> success blocknode) (failure pt)
  where
    header = blockHeader block
    blockhash = headerHash header
    hexhash = blockHashToHex blockhash
    success blocknode = do
        $(logInfoS) "BlockStore" $
            "Best block: " <> blockText blocknode (Just block)
        notify
        _ <- touchPeer peer
        syncMe peer
    failure pt e = do
        $(logErrorS) "BlockStore" $
            "Error importing block: "
            <> hexhash <> ": " <> cs (show (e :: ImportException))
            <> " (peer " <> pt <> ")"
        killPeer (PeerMisbehaving (show e)) peer
    notify = do
        listener <- asks (blockConfListener . myConfig)
        atomically $ listener (StoreBestBlock blockhash)

checkPeer :: (MonadLoggerIO m, MonadReader BlockRead m) => Peer -> m Bool
checkPeer peer =
    asks (blockConfManager . myConfig)
    >>= managerGetPeer peer
    >>= maybe disconnected (const connected)
  where
    disconnected = do
        $(logDebugS) "BlockStore" "Ignoring data from disconnected peer"
        return False
    connected = touchPeer peer >>= \case
        True -> return True
        False -> remove
    remove = do
        pt <- managerPeerText peer =<< asks (blockConfManager . myConfig)
        $(logDebugS) "BlockStore" $
            "Ignoring data from non-syncing peer: " <> pt
        killPeer (PeerMisbehaving "Sent unpexpected data") peer
        return False

getBlockNode :: (MonadUnliftIO m, MonadLoggerIO m, MonadReader BlockRead m)
             => Peer -> BlockHash -> m (Maybe BlockNode)
getBlockNode peer blockhash = runMaybeT $
    asks (blockConfChain . myConfig)
    >>= chainGetBlock blockhash
    >>= \case
        Nothing -> do
            p' <- managerPeerText peer =<< asks (blockConfManager . myConfig)
            $(logErrorS) "BlockStore" $
                "Header not found for block: "
                <> blockHashToHex blockhash
                <> " (peer " <> p' <> ")"
            killPeer (PeerMisbehaving "Sent unknown block") peer
            mzero
        Just n -> return n

processNoBlocks ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Peer
    -> [BlockHash]
    -> BlockT m ()
processNoBlocks p hs = do
    p' <- managerPeerText p =<< asks (blockConfManager . myConfig)
    forM_ (zip [(1 :: Int) ..] hs) $ \(i, h) ->
        $(logErrorS) "BlockStore" $
        "Block " <> cs (show i) <> "/" <> cs (show (length hs)) <> " "
        <> blockHashToHex h <> " not found (peer " <> p' <> ")"
    killPeer (PeerMisbehaving "Did not find requested block(s)") p

processTx :: (MonadUnliftIO m, MonadLoggerIO m) => Peer -> Tx -> BlockT m ()
processTx p tx = do
    t <- fromIntegral . systemSeconds <$> liftIO getSystemTime
    p' <- managerPeerText p =<< asks (blockConfManager . myConfig)
    $(logDebugS) "BlockManager" $
        "Received tx " <> txHashToHex (txHash tx) <> " (peer " <> p' <> ")"
    addPendingTx $ PendingTx t tx HashSet.empty

pruneOrphans :: MonadIO m => BlockT m ()
pruneOrphans = do
    ts <- asks myTxs
    now <- fromIntegral . systemSeconds <$> liftIO getSystemTime
    atomically . modifyTVar ts . HashMap.filter $ \p ->
        pendingTxTime p > now - 600

addPendingTx :: MonadIO m => PendingTx -> BlockT m ()
addPendingTx p = do
    ts <- asks myTxs
    atomically $ modifyTVar ts $ HashMap.insert th p
  where
    th = txHash (pendingTx p)

isPending :: MonadIO m => TxHash -> BlockT m Bool
isPending th = do
    ts <- asks myTxs
    atomically $ HashMap.member th <$> readTVar ts

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

newOrphanTx :: (MonadUnliftIO m, MonadLoggerIO m)
            => BlockRead -> UnixTime -> Tx -> WriterT m ()
newOrphanTx block_read time tx = do
    $(logDebugS) "BlockStore" $
        "Mempool "
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

importMempoolTx :: (MonadUnliftIO m, MonadLoggerIO m)
                => BlockRead -> UnixTime -> Tx -> WriterT m Bool
importMempoolTx block_read time tx =
    catch new_mempool_tx handle_error
  where
    tx_hash = txHash tx
    handle_error Orphan = do
        newOrphanTx block_read time tx
        return False
    handle_error _ = do
        $(logDebugS) "BlockStore" $
            "Mempool " <> txHashToHex tx_hash <> ": Failed"
        return False
    new_mempool_tx =
        newMempoolTx tx time >>= \case
        True -> do
            $(logDebugS) "BlockStore" $
                "Mempool " <> txHashToHex (txHash tx) <> ": OK"
            fulfillOrphans block_read tx_hash
            return True
        False -> do
            $(logDebugS) "BlockStore" $
                "Mempool " <> txHashToHex (txHash tx) <> ": No action"
            return False

processMempool :: (MonadUnliftIO m, MonadLoggerIO m) => BlockT m ()
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
    import_txs block_read =
        fmap catMaybes . runImport . mapM (run_import block_read)
    success = mapM_ notify
    notify txid = do
        l <- asks (blockConfListener . myConfig)
        atomically $ l (StoreMempoolNew txid)

processTxs ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Peer
    -> [TxHash]
    -> BlockT m ()
processTxs p hs = isInSync >>= \s -> when s $ do
    pt <- managerPeerText p =<< asks (blockConfManager . myConfig)
    $(logDebugS) "BlockStore" $
        "Received inventory with "
        <> cs (show (length hs))
        <> " transactions from peer " <> pt
    xs <- catMaybes <$> zip_counter (process_tx pt)
    unless (null xs) $ go xs
  where
    len = length hs
    zip_counter = forM (zip [(1 :: Int) ..] hs) . uncurry
    have_it h = isPending h >>= \case
        True -> return True
        False -> getTxData h >>= \case
            Nothing -> return False
            Just txd -> return (not (txDataDeleted txd))
    process_tx pt i h = have_it h >>= \case
        True  -> do_have pt i h
        False -> dont_have pt i h
    do_have pt i h = do
        $(logDebugS) "BlockStore" $
            "Tx inv " <> cs (show i) <> "/" <> cs (show len)
            <> ": " <> txHashToHex h
            <> ": Already have it (peer " <> pt <> ")"
        return Nothing
    dont_have pt i h = do
        $(logDebugS) "BlockStore" $
            "Tx inv " <> cs (show i) <> "/" <> cs (show len)
            <> ": " <> txHashToHex h
            <> ": Requesting… (peer " <> pt <> ")"
        return (Just h)
    go xs = do
        net <- asks (blockConfNet . myConfig)
        let inv = if getSegWit net then InvWitnessTx else InvTx
            vec = map (InvVector inv . getTxHash) xs
            msg = MGetData (GetData vec)
        msg `sendMessage` p

touchPeer :: (MonadIO m, MonadReader BlockRead m)
          => Peer -> m Bool
touchPeer p =
    getSyncingState >>= \case
        Just Syncing {syncingPeer = s}
            | p == s -> do
                box <- asks myPeer
                now <- fromIntegral . systemSeconds <$>
                    liftIO getSystemTime
                atomically . modifyTVar box . fmap $ \x ->
                    x {syncingTime = now}
                return True
        _ -> return False

checkTime :: (MonadUnliftIO m, MonadLoggerIO m) => BlockT m ()
checkTime =
    asks myPeer >>= readTVarIO >>= \case
        Nothing -> return ()
        Just Syncing {syncingTime = t, syncingPeer = p} -> do
            n <- fromIntegral . systemSeconds <$> liftIO getSystemTime
            peertout <- asks (blockConfPeerTimeout . myConfig)
            when (n > t + fromIntegral peertout) $ do
                p' <- managerPeerText p =<< asks (blockConfManager . myConfig)
                $(logErrorS) "BlockStore" $ "Timeout syncing peer " <> p'
                resetPeer
                killPeer PeerTimeout p

processDisconnect
    :: (MonadUnliftIO m, MonadLoggerIO m)
    => Peer
    -> BlockT m ()
processDisconnect p =
    asks myPeer >>= readTVarIO >>= \case
        Just Syncing {syncingPeer = p'} | p == p' -> dc
        _ -> return ()
  where
    dc = do
        $(logDebugS) "BlockStore" "Syncing peer disconnected"
        resetPeer
        getPeer >>= \case
            Nothing -> $(logWarnS) "BlockStore" "No peers available"
            Just peer -> do
                ns <- managerPeerText peer =<<
                      asks (blockConfManager . myConfig)
                $(logDebugS) "BlockStore" $ "New syncing peer " <> ns
                syncMe peer

pruneMempool :: (MonadUnliftIO m, MonadLoggerIO m) => BlockT m ()
pruneMempool =
    isInSync >>= \sync ->
    when sync . runImport $ do
        now <- fromIntegral . systemSeconds <$> liftIO getSystemTime
        getOldMempool now >>= \old ->
            unless (null old) $
            mapM_ delete_it old
  where
    failed txid e =
        $(logErrorS) "BlockStore" $
            "Could not delete old mempool tx: "
            <> txHashToHex txid <> ": "
            <> cs (show (e :: ImportException))
    delete_it txid = do
        $(logDebugS) "BlockStore" $
            "Deleting "
            <> ": " <> txHashToHex txid
            <> " (old mempool tx)…"
        catch (deleteUnconfirmedTx False txid) (failed txid)

syncMe :: (MonadUnliftIO m, MonadLoggerIO m) => Peer -> BlockT m ()
syncMe peer = void . runMaybeT $ do
    checksyncingpeer
    reverttomainchain
    syncbest <- syncbestnode
    bestblock <- bestblocknode
    chainbest <- chainbestnode
    end syncbest bestblock chainbest
    blocknodes <- selectblocks chainbest syncbest
    setPeer peer (last blocknodes)
    net <- asks (blockConfNet . myConfig)
    let inv = if getSegWit net then InvWitnessBlock else InvBlock
        vecf = InvVector inv . getBlockHash . headerHash . nodeHeader
        vectors = map vecf blocknodes
    pt <- managerPeerText peer =<< asks (blockConfManager . myConfig)
    $(logDebugS) "BlockStore" $
        "Requesting "
        <> fromString (show (length vectors))
        <> " blocks from peer: " <> pt
    MGetData (GetData vectors) `sendMessage` peer
  where
    checksyncingpeer = getSyncingState >>= \case
        Nothing -> return ()
        Just Syncing {syncingPeer = p}
            | p == peer -> return ()
            | otherwise -> mzero
    chainbestnode = chainGetBest =<< asks (blockConfChain . myConfig)
    bestblocknode = do
        bb <- lift getBestBlock >>= \case
            Nothing -> do
                $(logErrorS) "BlockStore" "No best block set"
                throwIO Uninitialized
            Just b -> return b
        ch <- asks (blockConfChain . myConfig)
        chainGetBlock bb ch >>= \case
            Nothing -> do
                $(logErrorS) "BlockStore" $
                    "Header not found for best block: " <> blockHashToHex bb
                throwIO (BlockNotInChain bb)
            Just x -> return x
    syncbestnode =
        asks myPeer >>= readTVarIO >>= \case
            Just Syncing {syncingHead = b} -> return b
            Nothing -> bestblocknode
    end syncbest bestblock chainbest
        | nodeHeader bestblock == nodeHeader chainbest = do
              lift updateOrphans
              resetPeer
              mempool peer
              mzero
        | nodeHeader syncbest == nodeHeader chainbest =
              mzero
        | nodeHeight syncbest > nodeHeight bestblock + 500 =
              mzero
        | otherwise =
              return ()
    selectblocks chainbest syncbest = do
        let sync_height = maxsyncheight
                          (nodeHeight chainbest)
                          (nodeHeight syncbest)
        synctop <- top chainbest sync_height
        ch <- asks (blockConfChain . myConfig)
        parents <- chainGetParents (nodeHeight syncbest + 1) synctop ch
        return $ if length parents < 500
                 then parents <> [chainbest]
                 else parents
    maxsyncheight chainheight syncbestheight
        | chainheight <= syncbestheight + 501 = chainheight
        | otherwise = syncbestheight + 501
    top chainbest syncheight =
        if syncheight == nodeHeight chainbest
        then return chainbest
        else findancestor chainbest syncheight
    findancestor chainbest syncheight = do
        ch <- asks (blockConfChain . myConfig)
        m <- chainGetAncestor syncheight chainbest ch
        case m of
            Just x -> return x
            Nothing -> do
                $(logErrorS) "BlockStore" $
                    "Could not find header for ancestor of block: "
                    <> blockHashToHex (headerHash (nodeHeader chainbest))
                throwIO $ AncestorNotInChain
                          syncheight
                          (headerHash (nodeHeader chainbest))
    reverttomainchain = do
        bestblockhash <- headerHash . nodeHeader <$> bestblocknode
        ch <- asks (blockConfChain . myConfig)
        chainBlockMain bestblockhash ch >>= \y ->
            unless y $ do_revert bestblockhash
    do_revert bestblockhash = do
        $(logErrorS) "BlockStore" $
            "Reverting best block: "
            <> blockHashToHex bestblockhash
        resetPeer
        lift $ runImport $ revertBlock bestblockhash
        reverttomainchain

resetPeer :: (MonadLoggerIO m, MonadReader BlockRead m) => m ()
resetPeer = do
    box <- asks myPeer
    atomically $ writeTVar box Nothing

setPeer :: (MonadIO m, MonadReader BlockRead m) => Peer -> BlockNode -> m ()
setPeer p b = do
    box <- asks myPeer
    now <- fromIntegral . systemSeconds <$> liftIO getSystemTime
    atomically . writeTVar box $
        Just Syncing {syncingPeer = p, syncingHead = b, syncingTime = now}

getPeer :: (MonadIO m, MonadReader BlockRead m) => m (Maybe Peer)
getPeer = runMaybeT $ MaybeT syncingpeer <|> MaybeT onlinepeer
  where
    syncingpeer = fmap syncingPeer <$> getSyncingState
    onlinepeer =
        listToMaybe . map onlinePeerMailbox <$>
        (managerGetPeers =<< asks (blockConfManager . myConfig))

getSyncingState :: (MonadIO m, MonadReader BlockRead m) => m (Maybe Syncing)
getSyncingState = readTVarIO =<< asks myPeer

processBlockStoreMessage ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => BlockStoreMessage
    -> BlockT m ()
processBlockStoreMessage (BlockNewBest _) =
    getPeer >>= \case
        Nothing -> return ()
        Just p -> syncMe p
processBlockStoreMessage (BlockPeerConnect p _) = syncMe p
processBlockStoreMessage (BlockPeerDisconnect p _sa) = processDisconnect p
processBlockStoreMessage (BlockReceived p b) = processBlock p b
processBlockStoreMessage (BlockNotFound p bs) = processNoBlocks p bs
processBlockStoreMessage (TxRefReceived p tx) = processTx p tx
processBlockStoreMessage (TxRefAvailable p ts) = processTxs p ts
processBlockStoreMessage (BlockPing r) = do
    processMempool
    pruneOrphans
    checkTime
    pruneMempool
    atomically (r ())

pingMe :: MonadLoggerIO m => BlockStore -> m ()
pingMe mbox =
    forever $ do
        threadDelay =<< liftIO (randomRIO (100 * 1000, 1000 * 1000))
        BlockPing `query` mbox

blockStorePeerConnect :: MonadIO m => Peer -> SockAddr -> BlockStore -> m ()
blockStorePeerConnect peer addr store = BlockPeerConnect peer addr `send` store

blockStorePeerDisconnect :: MonadIO m => Peer -> SockAddr -> BlockStore -> m ()
blockStorePeerDisconnect peer addr store =
    BlockPeerDisconnect peer addr `send` store

blockStoreHead :: MonadIO m => BlockNode -> BlockStore -> m ()
blockStoreHead node store = BlockNewBest node `send` store

blockStoreBlock :: MonadIO m => Peer -> Block -> BlockStore -> m ()
blockStoreBlock peer block store = BlockReceived peer block `send` store

blockStoreNotFound :: MonadIO m => Peer -> [BlockHash] -> BlockStore -> m ()
blockStoreNotFound peer blocks store = BlockNotFound peer blocks `send` store

blockStoreTx :: MonadIO m => Peer -> Tx -> BlockStore -> m ()
blockStoreTx peer tx store = TxRefReceived peer tx `send` store

blockStoreTxHash :: MonadIO m => Peer -> [TxHash] -> BlockStore -> m ()
blockStoreTxHash peer txhashes store =
    TxRefAvailable peer txhashes `send` store

blockStorePeerConnectSTM :: Peer -> SockAddr -> BlockStore -> STM ()
blockStorePeerConnectSTM peer addr store = BlockPeerConnect peer addr `sendSTM` store

blockStorePeerDisconnectSTM :: Peer -> SockAddr -> BlockStore -> STM ()
blockStorePeerDisconnectSTM peer addr store =
    BlockPeerDisconnect peer addr `sendSTM` store

blockStoreHeadSTM :: BlockNode -> BlockStore -> STM ()
blockStoreHeadSTM node store = BlockNewBest node `sendSTM` store

blockStoreBlockSTM :: Peer -> Block -> BlockStore -> STM ()
blockStoreBlockSTM peer block store = BlockReceived peer block `sendSTM` store

blockStoreNotFoundSTM :: Peer -> [BlockHash] -> BlockStore -> STM ()
blockStoreNotFoundSTM peer blocks store = BlockNotFound peer blocks `sendSTM` store

blockStoreTxSTM :: Peer -> Tx -> BlockStore -> STM ()
blockStoreTxSTM peer tx store = TxRefReceived peer tx `sendSTM` store

blockStoreTxHashSTM :: Peer -> [TxHash] -> BlockStore -> STM ()
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
    systime =
        posixSecondsToUTCTime (fromIntegral (blockTimestamp (nodeHeader bn)))
    time =
        cs $
        formatTime defaultTimeLocale (iso8601DateFormat (Just "%H:%M")) systime
    hash = blockHashToHex (headerHash (nodeHeader bn))
    sep = " | "
    size = (<> " bytes") . cs . show . B.length . encode
