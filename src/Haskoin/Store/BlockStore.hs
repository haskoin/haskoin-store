{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections     #-}
module Haskoin.Store.BlockStore
    ( BlockStoreConfig(..)
    , blockStore
    ) where

import           Control.Applicative           ((<|>))
import           Control.Monad                 (forM, forM_, forever, guard,
                                                mzero, unless, void, when)
import           Control.Monad.Except          (ExceptT, MonadError (..),
                                                runExceptT)
import           Control.Monad.Logger          (MonadLoggerIO, logDebugS,
                                                logErrorS, logInfoS, logWarnS)
import           Control.Monad.Reader          (MonadReader, ReaderT (..), asks)
import           Control.Monad.Trans           (lift)
import           Control.Monad.Trans.Maybe     (MaybeT (MaybeT), runMaybeT)
import           Data.Maybe                    (catMaybes, isNothing,
                                                listToMaybe)
import           Data.String                   (fromString)
import           Data.String.Conversions       (cs)
import           Data.Time.Clock.System        (getSystemTime, systemSeconds)
import           Haskoin                       (Block (..), BlockHash (..),
                                                BlockHeight, BlockNode (..),
                                                GetData (..), InvType (..),
                                                InvVector (..), Message (..),
                                                Network (..), Tx, TxHash (..),
                                                blockHashToHex, headerHash,
                                                txHash, txHashToHex)
import           Haskoin.Node                  (OnlinePeer (..), Peer,
                                                PeerException (..),
                                                chainBlockMain,
                                                chainGetAncestor, chainGetBest,
                                                chainGetBlock, chainGetParents,
                                                killPeer, managerGetPeers,
                                                sendMessage)
import           Haskoin.Node                  (Chain, Manager)
import           Haskoin.Store.Common          (BlockStore,
                                                BlockStoreMessage (..),
                                                BlockTx (..), StoreEvent (..),
                                                StoreRead (..), StoreWrite (..),
                                                UnixTime)
import           Haskoin.Store.Database.Reader (DatabaseReader)
import           Haskoin.Store.Database.Writer (DatabaseWriter,
                                                runDatabaseWriter)
import           Haskoin.Store.Logic           (ImportException, deleteTx,
                                                getOldMempool, getOldOrphans,
                                                importBlock, importOrphan,
                                                initBest, newMempoolTx,
                                                revertBlock)
import           NQE                           (Inbox, Listen, inboxToMailbox,
                                                query, receive)
import           System.Random                 (randomRIO)
import           UnliftIO                      (Exception, MonadIO,
                                                MonadUnliftIO, TVar, atomically,
                                                liftIO, modifyTVar, newTVarIO,
                                                readTVar, readTVarIO, throwIO,
                                                withAsync, writeTVar)
import           UnliftIO.Concurrent           (threadDelay)

data BlockException
    = BlockNotInChain !BlockHash
    | Uninitialized
    | CorruptDatabase
    | AncestorNotInChain !BlockHeight
                         !BlockHash
    deriving (Show, Eq, Ord, Exception)

data Syncing = Syncing
    { syncingPeer :: !Peer
    , syncingTime :: !UnixTime
    , syncingHead :: !BlockNode
    }

-- | Block store process state.
data BlockRead =
    BlockRead
        { mySelf   :: !BlockStore
        , myConfig :: !BlockStoreConfig
        , myPeer   :: !(TVar (Maybe Syncing))
        , myTxs    :: !(TVar [Tx])
        }

-- | Configuration for a block store.
data BlockStoreConfig =
    BlockStoreConfig
        { blockConfManager     :: !Manager
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
        }

type BlockT m = ReaderT BlockRead m

runImport ::
       MonadLoggerIO m
    => ReaderT DatabaseWriter (ExceptT ImportException m) a
    -> ReaderT BlockRead m (Either ImportException a)
runImport f =
    ReaderT $ \r -> runExceptT (runDatabaseWriter (blockConfDB (myConfig r)) f)

runRocksDB :: ReaderT DatabaseReader m a -> ReaderT BlockRead m a
runRocksDB f =
    ReaderT $ \BlockRead {myConfig = BlockStoreConfig {blockConfDB = db}} ->
        runReaderT f db

instance MonadIO m => StoreRead (ReaderT BlockRead m) where
    getMaxGap = runRocksDB getMaxGap
    getInitialGap = runRocksDB getInitialGap
    getNetwork = runRocksDB getNetwork
    getBestBlock = runRocksDB getBestBlock
    getBlocksAtHeight = runRocksDB . getBlocksAtHeight
    getBlock = runRocksDB . getBlock
    getTxData = runRocksDB . getTxData
    getSpender = runRocksDB . getSpender
    getSpenders = runRocksDB . getSpenders
    getOrphanTx = runRocksDB . getOrphanTx
    getUnspent = runRocksDB . getUnspent
    getBalance = runRocksDB . getBalance
    getMempool = runRocksDB getMempool
    getAddressesTxs addrs start limit =
        runRocksDB (getAddressesTxs addrs start limit)
    getAddressesUnspents addrs start limit =
        runRocksDB (getAddressesUnspents addrs start limit)
    getOrphans = runRocksDB getOrphans
    getAddressUnspents a s = runRocksDB . getAddressUnspents a s
    getAddressTxs a s = runRocksDB . getAddressTxs a s

-- | Run block store process.
blockStore ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => BlockStoreConfig
    -> Inbox BlockStoreMessage
    -> m ()
blockStore cfg inbox = do
    pb <- newTVarIO Nothing
    ts <- newTVarIO []
    runReaderT
        (ini >> wipe >> run)
        BlockRead
            { mySelf = inboxToMailbox inbox
            , myConfig = cfg
            , myPeer = pb
            , myTxs = ts
            }
  where
    del txs =
        forM (zip [(1 :: Integer) ..] txs) $ \(i, tx) -> do
            $(logDebugS) "BlockStore" $
                "Wiping mempool tx " <> cs (show i) <> "/" <>
                cs (show (length txs)) <>
                ": " <>
                txHashToHex (blockTxHash tx)
            deleteTx True (blockTxHash tx)
    wipe
        | blockConfWipeMempool cfg = do
            take 1000 <$> getMempool >>= \case
                [] -> return ()
                txs ->
                    runImport (del txs) >>= \case
                        Left e -> do
                            $(logErrorS) "BlockStore" $
                                "Could not delete mempool, database corrupt: " <>
                                cs (show e)
                            throwIO CorruptDatabase
                        Right _ -> return ()
        | otherwise = return ()
    ini = do
        runImport initBest >>= \case
            Left e -> do
                $(logErrorS) "BlockStore" $
                    "Could not initialize block store: " <> fromString (show e)
                throwIO e
            Right () -> return ()
    run =
        withAsync (pingMe (inboxToMailbox inbox)) . const . forever $ do
            receive inbox >>= \x ->
                ReaderT $ \r -> runReaderT (processBlockStoreMessage x) r

isInSync ::
       (MonadLoggerIO m, StoreRead m, MonadReader BlockRead m)
    => m Bool
isInSync =
    getBestBlock >>= \case
        Nothing -> do
            $(logErrorS) "BlockStore" "Block database uninitialized"
            throwIO Uninitialized
        Just bb ->
            asks (blockConfChain . myConfig) >>= chainGetBest >>= \cb ->
                return (headerHash (nodeHeader cb) == bb)

mempool :: MonadLoggerIO m => Peer -> m ()
mempool p = do
    $(logDebugS) "BlockStore" "Requesting mempool from network peer"
    MMempool `sendMessage` p

processBlock ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Peer
    -> Block
    -> ReaderT BlockRead m ()
processBlock peer block = do
    void . runMaybeT $ do
        checkpeer
        blocknode <- getblocknode
        lift (runImport (importBlock block blocknode)) >>= \case
            Right deletedtxids -> do
                listener <- asks (blockConfListener . myConfig)
                $(logInfoS) "BlockStore" $ "Best block indexed: " <> hexhash
                atomically $ do
                    mapM_ (listener . StoreTxDeleted) deletedtxids
                    listener (StoreBestBlock blockhash)
                lift (syncMe peer)
            Left e -> do
                $(logErrorS) "BlockStore" $
                    "Error importing block: " <> hexhash <> ": " <>
                    fromString (show e)
                killPeer (PeerMisbehaving (show e)) peer
  where
    header = blockHeader block
    blockhash = headerHash header
    hexhash = blockHashToHex blockhash
    checkpeer =
        getSyncingState >>= \case
            Just Syncing {syncingPeer = syncingpeer}
                | peer == syncingpeer -> return ()
            _ -> do
                $(logErrorS) "BlockStore" $ "Peer sent unexpected block: " <> hexhash
                killPeer (PeerMisbehaving "Sent unpexpected block") peer
                mzero
    getblocknode =
        asks (blockConfChain . myConfig) >>= chainGetBlock blockhash >>= \case
            Nothing -> do
                $(logErrorS) "BlockStore" $ "Block header not found: " <> hexhash
                killPeer (PeerMisbehaving "Sent unknown block") peer
                mzero
            Just n -> return n

processNoBlocks ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Peer
    -> [BlockHash]
    -> ReaderT BlockRead m ()
processNoBlocks p _bs = do
    $(logErrorS) "BlockStore" (cs m)
    killPeer (PeerMisbehaving m) p
  where
    m = "I do not like peers that cannot find them blocks"

processTx :: (MonadUnliftIO m, MonadLoggerIO m) => Peer -> Tx -> BlockT m ()
processTx _p tx = asks myTxs >>= \b -> atomically (modifyTVar b (tx :))

processMempool :: (MonadUnliftIO m, MonadLoggerIO m) => BlockT m ()
processMempool = do
    g >>= \case
        [] -> return ()
        txs -> do
            output <-
                runImport . forM (zip [(1 :: Int) ..] txs) $ \(i, tx) -> do
                    now <- fromIntegral . systemSeconds <$> liftIO getSystemTime
                    $(logInfoS) "BlockStore" $
                        "New mempool tx " <> cs (show i) <> "/" <>
                        cs (show (length txs)) <>
                        ": " <>
                        txHashToHex (txHash tx)
                    fmap (txHash tx, ) <$> newMempoolTx tx now `catchError` h
            case output of
                Left e -> do
                    $(logErrorS) "BlockStore" $
                        "Importing mempool failed: " <> cs (show e)
                Right xs -> do
                    l <- asks (blockConfListener . myConfig)
                    atomically $ forM_ (catMaybes xs) $ \(th, deleted) -> do
                            mapM_ (l . StoreTxDeleted) deleted
                            l (StoreMempoolNew th)
  where
    h _ = return Nothing
    g =
        asks myTxs >>= \b ->
            atomically $ do
                txs <- readTVar b
                writeTVar b []
                return txs

processOrphans ::
       (MonadUnliftIO m, MonadLoggerIO m) => BlockT m ()
processOrphans =
    isInSync >>= \sync ->
        when sync $ do
            now <- fromIntegral . systemSeconds <$> liftIO getSystemTime
            old <- getOldOrphans now
            case old of
                [] -> return ()
                _ -> do
                    $(logInfoS) "BlockStore" $
                        "Removing " <> cs (show (length old)) <>
                        " expired orphan transactions"
                    void . runImport $ mapM_ deleteOrphanTx old
            orphans <- getOrphans
            case orphans of
                [] -> return ()
                _  -> go orphans
  where
    h _ = return Nothing
    go os = do
        output <-
            runImport . forM (zip [(1 :: Int) ..] os) $ \(i, (t, tx)) -> do
                $(logInfoS) "BlockStore" $
                    "Attempting to import orphan tx " <> cs (show i) <> "/" <>
                    cs (show (length os)) <>
                    ": " <>
                    txHashToHex (txHash tx)
                fmap (txHash tx, ) <$> importOrphan t tx `catchError` h
        case output of
            Left e -> do
                $(logErrorS) "BlockStore" $
                    "Importing orphans failed: " <> cs (show e)
            Right xs -> do
                l <- asks (blockConfListener . myConfig)
                atomically $
                    forM_ (catMaybes xs) $ \(th, deleted) -> do
                        mapM_ (l . StoreTxDeleted) deleted
                        l (StoreMempoolNew th)

processTxs ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Peer
    -> [TxHash]
    -> ReaderT BlockRead m ()
processTxs p hs =
    isInSync >>= \sync ->
        when sync $ do
            xs <-
                fmap catMaybes . forM hs $ \h ->
                    runMaybeT $ do
                        t <- lift $ getTxData h
                        guard (isNothing t)
                        return (getTxHash h)
            unless (null xs) $ do
                $(logInfoS) "BlockStore" $
                    "Requesting " <> fromString (show (length xs)) <>
                    " new transactions"
                net <- blockConfNet <$> asks myConfig
                let inv =
                        if getSegWit net
                            then InvWitnessTx
                            else InvTx
                MGetData (GetData (map (InvVector inv) xs)) `sendMessage` p

checkTime :: (MonadUnliftIO m, MonadLoggerIO m) => ReaderT BlockRead m ()
checkTime =
    asks myPeer >>= readTVarIO >>= \case
        Nothing -> return ()
        Just Syncing {syncingTime = t, syncingPeer = p} -> do
            n <- fromIntegral . systemSeconds <$> liftIO getSystemTime
            when (n > t + 60) $ do
                $(logErrorS) "BlockStore" "Syncing peer timeout"
                resetPeer
                killPeer PeerTimeout p

processDisconnect ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Peer
    -> ReaderT BlockRead m ()
processDisconnect p =
    asks myPeer >>= readTVarIO >>= \case
        Nothing -> return ()
        Just Syncing {syncingPeer = p'}
            | p == p' -> do
                resetPeer
                getPeer >>= \case
                    Nothing ->
                        $(logWarnS)
                            "BlockStore"
                            "No peers available after syncing peer disconnected"
                    Just peer -> do
                        $(logWarnS) "BlockStore" "Selected another peer to sync"
                        syncMe peer
            | otherwise -> return ()

pruneMempool :: (MonadUnliftIO m, MonadLoggerIO m) => BlockT m ()
pruneMempool =
    isInSync >>= \sync ->
        when sync $ do
            now <- fromIntegral . systemSeconds <$> liftIO getSystemTime
            getOldMempool now >>= \case
                [] -> return ()
                old -> deletetxs old
  where
    deletetxs old = do
        $(logInfoS) "BlockStore" $
            "Removing " <> cs (show (length old)) <> " old mempool transactions"
        forM_ old $ \txid ->
            runImport (deleteTx True txid) >>= \case
                Left _ -> return ()
                Right txids -> do
                    listener <- asks (blockConfListener . myConfig)
                    atomically $ mapM_ (listener . StoreTxDeleted) txids

syncMe :: (MonadUnliftIO m, MonadLoggerIO m) => Peer -> BlockT m ()
syncMe peer =
    void . runMaybeT $ do
        checksyncingpeer
        reverttomainchain
        syncbest <- syncbestnode
        bestblock <- bestblocknode
        chainbest <- chainbestnode
        end syncbest bestblock chainbest
        blocknodes <- selectblocks chainbest syncbest
        setPeer peer (last blocknodes)
        net <- asks (blockConfNet . myConfig)
        let inv =
                if getSegWit net
                    then InvWitnessBlock
                    else InvBlock
            vectors =
                map
                    (InvVector inv . getBlockHash . headerHash . nodeHeader)
                    blocknodes
        $(logInfoS) "BlockStore" $
            "Requesting " <> fromString (show (length vectors)) <> " blocks"
        MGetData (GetData vectors) `sendMessage` peer
  where
    checksyncingpeer =
        getSyncingState >>= \case
            Nothing -> return ()
            Just Syncing {syncingPeer = p}
                | p == peer -> return ()
                | otherwise -> do
                    $(logInfoS) "BlockStore" "Already syncing against another peer"
                    mzero
    chainbestnode = chainGetBest =<< asks (blockConfChain . myConfig)
    bestblocknode = do
        bb <-
            lift getBestBlock >>= \case
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
            resetPeer >> mempool peer >> mzero
        | nodeHeader syncbest == nodeHeader chainbest = do mzero
        | otherwise =
            when (nodeHeight syncbest > nodeHeight bestblock + 500) mzero
    selectblocks chainbest syncbest = do
        synctop <-
            top
                chainbest
                (maxsyncheight (nodeHeight chainbest) (nodeHeight syncbest))
        ch <- asks (blockConfChain . myConfig)
        parents <- chainGetParents (nodeHeight syncbest + 1) synctop ch
        return $
            if length parents < 500
                then parents <> [chainbest]
                else parents
    maxsyncheight chainheight syncbestheight
        | chainheight <= syncbestheight + 501 = chainheight
        | otherwise = syncbestheight + 501
    top chainbest syncheight = do
        ch <- asks (blockConfChain . myConfig)
        if syncheight == nodeHeight chainbest
            then return chainbest
            else chainGetAncestor syncheight chainbest ch >>= \case
                     Just x -> return x
                     Nothing -> do
                         $(logErrorS) "BlockStore" $
                             "Could not find header for ancestor of block: " <>
                             blockHashToHex (headerHash (nodeHeader chainbest))
                         throwIO $
                             AncestorNotInChain
                                 syncheight
                                 (headerHash (nodeHeader chainbest))
    reverttomainchain = do
        bestblockhash <- headerHash . nodeHeader <$> bestblocknode
        ch <- asks (blockConfChain . myConfig)
        chainBlockMain bestblockhash ch >>= \y ->
            unless y $ do
                $(logErrorS) "BlockStore" $
                    "Reverting best block: " <> blockHashToHex bestblockhash
                resetPeer
                lift (runImport (revertBlock bestblockhash)) >>= \case
                    Left e -> do
                        $(logErrorS) "BlockStore" $
                            "Could not revert best block: " <> cs (show e)
                        throwIO e
                    Right txids -> do
                        listener <- asks (blockConfListener . myConfig)
                        atomically $ do
                            mapM_ (listener . StoreTxDeleted) txids
                            listener (StoreBlockReverted bestblockhash)
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
processBlockStoreMessage (BlockNewBest _) = do
    getPeer >>= \case
        Nothing -> do
            $(logDebugS)
                "BlockStore"
                "New best block event received but no peers available"
        Just p -> syncMe p
processBlockStoreMessage (BlockPeerConnect p _) = syncMe p
processBlockStoreMessage (BlockPeerDisconnect p _sa) = processDisconnect p
processBlockStoreMessage (BlockReceived p b) = processBlock p b
processBlockStoreMessage (BlockNotFound p bs) = processNoBlocks p bs
processBlockStoreMessage (BlockTxReceived p tx) = processTx p tx
processBlockStoreMessage (BlockTxAvailable p ts) = processTxs p ts
processBlockStoreMessage (BlockPing r) = do
    processMempool
    processOrphans
    checkTime
    pruneMempool
    atomically (r ())

pingMe :: MonadLoggerIO m => BlockStore -> m ()
pingMe mbox =
    forever $ do
        threadDelay =<< liftIO (randomRIO (100 * 1000, 1000 * 1000))
        BlockPing `query` mbox
