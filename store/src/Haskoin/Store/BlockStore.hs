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
import           Control.Monad.Except          (ExceptT, MonadError (..),
                                                runExceptT)
import           Control.Monad.Logger          (MonadLoggerIO, logDebugS,
                                                logErrorS, logInfoS, logWarnS)
import           Control.Monad.Reader          (MonadReader, ReaderT (..), asks)
import           Control.Monad.Trans           (lift)
import           Control.Monad.Trans.Maybe     (MaybeT (MaybeT), runMaybeT)
import           Data.HashMap.Strict           (HashMap)
import qualified Data.HashMap.Strict           as HashMap
import           Data.HashSet                  (HashSet)
import qualified Data.HashSet                  as HashSet
import           Data.List                     (partition)
import           Data.Maybe                    (catMaybes, listToMaybe,
                                                mapMaybe)
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
import           Haskoin.Node                  (OnlinePeer (..), Peer,
                                                PeerException (..),
                                                chainBlockMain,
                                                chainGetAncestor, chainGetBest,
                                                chainGetBlock, chainGetParents,
                                                killPeer, managerGetPeer,
                                                managerGetPeers, sendMessage)
import           Haskoin.Node                  (Chain, PeerManager,
                                                managerPeerText)
import           Haskoin.Store.Common          (StoreEvent (..), StoreRead (..),
                                                sortTxs)
import           Haskoin.Store.Data            (TxData (..), TxRef (..),
                                                UnixTime, Unspent (..))
import           Haskoin.Store.Database.Reader (DatabaseReader)
import           Haskoin.Store.Database.Writer (DatabaseWriter,
                                                runDatabaseWriter)
import           Haskoin.Store.Logic           (ImportException (Orphan),
                                                deleteTx, getOldMempool,
                                                importBlock, initBest,
                                                newMempoolTx, revertBlock)
import           Network.Socket                (SockAddr)
import           NQE                           (Inbox, Listen, Mailbox,
                                                inboxToMailbox, query, receive,
                                                send, sendSTM)
import           System.Random                 (randomRIO)
import           UnliftIO                      (Exception, MonadIO,
                                                MonadUnliftIO, STM, TVar,
                                                atomically, liftIO, modifyTVar,
                                                newTVarIO, readTVar, readTVarIO,
                                                throwIO, withAsync, writeTVar)
import           UnliftIO.Concurrent           (threadDelay)

-- | Messages for block store actor.
data BlockStoreMessage
    = BlockNewBest !BlockNode
      -- ^ new block header in chain
    | BlockPeerConnect !Peer !SockAddr
      -- ^ new peer connected
    | BlockPeerDisconnect !Peer !SockAddr
      -- ^ peer disconnected
    | BlockReceived !Peer !Block
      -- ^ new block received from a peer
    | BlockNotFound !Peer ![BlockHash]
      -- ^ block not found
    | TxRefReceived !Peer !Tx
      -- ^ transaction received from peer
    | TxRefAvailable !Peer ![TxHash]
      -- ^ peer has transactions available
    | BlockPing !(Listen ())
      -- ^ internal housekeeping ping

-- | Mailbox for block store.
type BlockStore = Mailbox BlockStoreMessage

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

data PendingTx =
    PendingTx
        { pendingTxTime :: !UnixTime
        , pendingTx     :: !Tx
        , pendingDeps   :: !(HashSet TxHash)
        }
    deriving (Show, Eq, Ord)

-- | Block store process state.
data BlockRead =
    BlockRead
        { mySelf   :: !BlockStore
        , myConfig :: !BlockStoreConfig
        , myPeer   :: !(TVar (Maybe Syncing))
        , myTxs    :: !(TVar (HashMap TxHash PendingTx))
        }

-- | Configuration for a block store.
data BlockStoreConfig =
    BlockStoreConfig
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
    getUnspent = runRocksDB . getUnspent
    getBalance = runRocksDB . getBalance
    getMempool = runRocksDB getMempool
    getAddressesTxs as = runRocksDB . getAddressesTxs as
    getAddressesUnspents as = runRocksDB . getAddressesUnspents as
    getAddressUnspents a = runRocksDB . getAddressUnspents a
    getAddressTxs a = runRocksDB . getAddressTxs a

-- | Run block store process.
blockStore ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => BlockStoreConfig
    -> Inbox BlockStoreMessage
    -> m ()
blockStore cfg inbox = do
    pb <- newTVarIO Nothing
    ts <- newTVarIO HashMap.empty
    runReaderT
        (ini >> wipe >> run)
        BlockRead
            { mySelf = inboxToMailbox inbox
            , myConfig = cfg
            , myPeer = pb
            , myTxs = ts
            }
  where
    del x n txs =
        forM (zip [x ..] txs) $ \(i, tx) -> do
            $(logDebugS) "BlockStore" $
                "Wiping mempool tx " <> cs (show i) <> "/" <> cs (show n) <>
                ": " <>
                txHashToHex (txRefHash tx)
            deleteTx True False (txRefHash tx)
    wipeit x n txs = do
        let (txs1, txs2) = splitAt 1000 txs
        case txs1 of
            [] -> return ()
            _ ->
                runImport (del x n txs1) >>= \case
                    Left e -> do
                        $(logErrorS) "BlockStore" $
                            "Could not delete mempool, database corrupt: " <>
                            cs (show e)
                        throwIO CorruptDatabase
                    Right _ -> wipeit (x + length txs1) n txs2
    wipe
        | blockConfWipeMempool cfg =
            getMempool >>= \mem -> wipeit 1 (length mem) mem
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
        p' <- managerPeerText peer =<< asks (blockConfManager . myConfig)
        $(logDebugS) "BlockStore" $
            "Processing block : " <> blockText blocknode (blockTxns block) <>
            " (peer" <>
            p' <>
            ")"
        lift (runImport (importBlock block blocknode)) >>= \case
            Right deletedtxids -> do
                listener <- asks (blockConfListener . myConfig)
                $(logInfoS) "BlockStore" $
                    "Best block: " <> blockText blocknode (blockTxns block)
                atomically $ do
                    mapM_ (listener . StoreTxDeleted) deletedtxids
                    listener (StoreBestBlock blockhash)
                lift (touchPeer peer >> syncMe peer)
            Left e -> do
                $(logErrorS) "BlockStore" $
                    "Error importing block: " <> hexhash <> ": " <>
                    fromString (show e) <>
                    " (peer " <>
                    p' <>
                    ")"
                killPeer (PeerMisbehaving (show e)) peer
  where
    header = blockHeader block
    blockhash = headerHash header
    hexhash = blockHashToHex blockhash
    checkpeer = do
        pm <- managerGetPeer peer =<< asks (blockConfManager . myConfig)
        case pm of
            Nothing -> do
                $(logWarnS) "BlockStore" $
                    "Ignoring block " <> hexhash <> " from disconnected peer"
                mzero
            Just _ ->
                lift (touchPeer peer) >>= \case
                    True -> return ()
                    False -> do
                        p' <-
                            managerPeerText peer =<<
                            asks (blockConfManager . myConfig)
                        $(logDebugS) "BlockStore" $
                            "Ignoring block " <> hexhash <>
                            " from non-syncing peer " <>
                            p'
                        killPeer (PeerMisbehaving "Sent unpexpected block") peer
                        mzero
    getblocknode =
        asks (blockConfChain . myConfig) >>= chainGetBlock blockhash >>= \case
            Nothing -> do
                p' <-
                    managerPeerText peer =<< asks (blockConfManager . myConfig)
                $(logErrorS) "BlockStore" $
                    "Header not found for block: " <> hexhash <> " (peer " <> p' <>
                    ")"
                killPeer (PeerMisbehaving "Sent unknown block") peer
                mzero
            Just n -> return n

processNoBlocks ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Peer
    -> [BlockHash]
    -> ReaderT BlockRead m ()
processNoBlocks p hs = do
    p' <- managerPeerText p =<< asks (blockConfManager . myConfig)
    forM_ (zip [(1 :: Int) ..] hs) $ \(i, h) ->
        $(logErrorS) "BlockStore" $
        "Block " <> cs (show i) <> "/" <> cs (show (length hs)) <> " " <>
        blockHashToHex h <>
        " not found (peer " <>
        p' <>
        ")"
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
pendingTxs i = do
    ts <- asks myTxs
    atomically $ do
        pend <- readTVar ts
        let (txs, orp) =
                partition (null . pendingDeps . snd) (HashMap.toList pend)
        let ret = take i (sortit pend txs)
        writeTVar ts (HashMap.fromList (fltr ret txs <> orp))
        return ret
  where
    fltr ret =
        let ths = HashSet.fromList (map (txHash . pendingTx) ret)
            f = not . (`HashSet.member` ths) . txHash . pendingTx . snd
         in filter f
    sortit pend =
        mapMaybe (flip HashMap.lookup pend . txHash . snd) .
        sortTxs . map pendingTx . map snd

fulfillOrphans :: MonadIO m => TxHash -> BlockT m ()
fulfillOrphans th = do
    ts <- asks myTxs
    atomically $ do
        pend <- readTVar ts
        let pend' = HashMap.map upd pend
        writeTVar ts pend'
  where
    upd p = p {pendingDeps = HashSet.delete th (pendingDeps p)}

updateOrphans :: (StoreRead m, MonadLoggerIO m, MonadReader BlockRead m) => m ()
updateOrphans = do
    tb <- asks myTxs
    pend1 <- readTVarIO tb
    let pend2 = HashMap.filter (not . null . pendingDeps) pend1
    pend3 <-
        fmap (HashMap.fromList . catMaybes) $
        forM (HashMap.elems pend2) $ \p -> do
            let tx = pendingTx p
            e <- exists (txHash tx)
            if e
                then return Nothing
                else do
                    uns <-
                        fmap catMaybes $
                        forM (txIn tx) (getUnspent . prevOutput)
                    let f p1 u =
                            p1
                                { pendingDeps =
                                      HashSet.delete
                                          (outPointHash (unspentPoint u))
                                          (pendingDeps p1)
                                }
                    return $ Just (txHash tx, foldl f p uns)
    atomically $ writeTVar tb pend3
  where
    exists th =
        getTxData th >>= \case
            Nothing -> return False
            Just TxData {txDataDeleted = True} -> return False
            Just TxData {txDataDeleted = False} -> return True

data MemImport
    = MemOrphan !PendingTx
    | MemImported !TxHash ![TxHash]

processMempool :: (MonadUnliftIO m, MonadLoggerIO m) => BlockT m ()
processMempool = do
    pendingTxs 2000 >>= \txs ->
        if null txs
            then return ()
            else go txs
  where
    pend p = do
        ex <-
            fmap (HashSet.fromList . catMaybes) $
            forM (txIn (pendingTx p)) $ \i -> do
                let op = prevOutput i
                    h = outPointHash op
                getUnspent op >>= \case
                    Nothing -> return (Just h)
                    Just _ -> return Nothing
        addPendingTx $ p {pendingDeps = ex}
    go txs = do
        output <-
            runImport . fmap catMaybes . forM (zip [(1 :: Int) ..] txs) $ \(i, p) -> do
                let tx = pendingTx p
                    t = pendingTxTime p
                    th = txHash tx
                    h Orphan {} = do
                        $(logWarnS) "BlockStore" $
                            "Mempool " <> cs (show i) <> "/" <>
                            cs (show (length txs)) <>
                            ": " <>
                            txHashToHex th <>
                            ": orphan"
                        return (Just (MemOrphan p))
                    h e = do
                        $(logWarnS) "BlockStore" $
                            "Mempool " <> cs (show i) <> "/" <>
                            cs (show (length txs)) <>
                            ": " <>
                            txHashToHex th <>
                            ": " <>
                            cs (show e)
                        return Nothing
                    f =
                        newMempoolTx tx t >>= \case
                            Just ls -> do
                                $(logInfoS) "BlockStore" $
                                    "Mempool " <> cs (show i) <> "/" <>
                                    cs (show (length txs)) <>
                                    ": " <>
                                    txHashToHex th <>
                                    ": ok"
                                return (Just (MemImported th ls))
                            Nothing -> do
                                $(logInfoS) "BlockStore" $
                                    "Mempool " <> cs (show i) <> "/" <>
                                    cs (show (length txs)) <>
                                    ": " <>
                                    txHashToHex th <>
                                    ": already imported"
                                return Nothing
                catchError f h
        case output of
            Left e -> do
                $(logErrorS) "BlockStore" $
                    "Mempool import failed: " <> cs (show e)
            Right xs -> do
                forM_ xs $ \case
                    MemOrphan p -> pend p
                    MemImported th deleted -> do
                        fulfillOrphans th
                        l <- asks (blockConfListener . myConfig)
                        atomically $ do
                            mapM_ (l . StoreTxDeleted) deleted
                            l (StoreMempoolNew th)

processTxs ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Peer
    -> [TxHash]
    -> ReaderT BlockRead m ()
processTxs p hs = do
    sync <- isInSync
    when sync $ do
        p' <- managerPeerText p =<< asks (blockConfManager . myConfig)
        $(logDebugS) "BlockStore" $
            "Received inventory with " <> cs (show (length hs)) <>
            " transactions from peer " <>
            p'
        xs <-
            fmap catMaybes . forM (zip [(1 :: Int) ..] hs) $ \(i, h) ->
                haveit h >>= \case
                    True -> do
                        $(logDebugS) "BlockStore" $
                            "Tx inv " <> cs (show i) <> "/" <>
                            cs (show (length hs)) <>
                            ": " <>
                            txHashToHex h <>
                            ": Already have it " <>
                            "(peer " <>
                            p' <>
                            ")"
                        return Nothing
                    False -> do
                        $(logDebugS) "BlockStore" $
                            "Tx inv " <> cs (show i) <> "/" <>
                            cs (show (length hs)) <>
                            ": " <>
                            txHashToHex h <>
                            ": Requesting… " <>
                            "(peer " <>
                            p' <>
                            ")"
                        return (Just h)
        unless (null xs) $ go xs
  where
    haveit h =
        isPending h >>= \case
            True -> return True
            False ->
                getTxData h >>= \case
                    Nothing -> return False
                    Just txd -> return (not (txDataDeleted txd))
    go xs = do
        net <- asks (blockConfNet . myConfig)
        let inv =
                if getSegWit net
                    then InvWitnessTx
                    else InvTx
        MGetData (GetData (map (InvVector inv . getTxHash) xs)) `sendMessage` p

touchPeer :: MonadIO m => Peer -> ReaderT BlockRead m Bool
touchPeer p =
    getSyncingState >>= \case
        Just Syncing {syncingPeer = s}
            | p == s -> do
                box <- asks myPeer
                now <- fromIntegral . systemSeconds <$> liftIO getSystemTime
                atomically . modifyTVar box . fmap $ \x -> x {syncingTime = now}
                return True
        _ -> return False

checkTime :: (MonadUnliftIO m, MonadLoggerIO m) => ReaderT BlockRead m ()
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

processDisconnect ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Peer
    -> ReaderT BlockRead m ()
processDisconnect p =
    asks myPeer >>= readTVarIO >>= \case
        Nothing -> return ()
        Just Syncing {syncingPeer = p'}
            | p == p' -> do
                $(logWarnS) "BlockStore" "Syncing peer disconnected"
                resetPeer
                getPeer >>= \case
                    Nothing -> do
                        $(logWarnS) "BlockStore" "No new syncing peer available"
                    Just peer -> do
                        ns <-
                            managerPeerText peer =<<
                            asks (blockConfManager . myConfig)
                        $(logWarnS) "BlockStore" $ "New syncing peer " <> ns
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
        forM_ (zip [(1 :: Int) ..] old) $ \(i, txid) -> do
            $(logInfoS) "BlockStore" $
                "Deleting " <> cs (show i) <> "/" <> cs (show (length old)) <>
                ": " <>
                txHashToHex txid <>
                " (old mempool tx)…"
            runImport (deleteTx True False txid) >>= \case
                Left e -> do
                    $(logErrorS) "BlockStore" $
                        "Could not delete old mempool tx: " <> txHashToHex txid <>
                        ": " <>
                        cs (show e)
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
        p' <- managerPeerText peer =<< asks (blockConfManager . myConfig)
        $(logInfoS) "BlockStore" $
            "Requesting " <> fromString (show (length vectors)) <>
            " blocks (peer " <>
            p' <>
            ")"
        forM_ (zip [(1 :: Int) ..] blocknodes) $ \(i, bn) -> do
            $(logDebugS) "BlockStore" $
                "Requesting block " <> cs (show i) <> "/" <>
                cs (show (length vectors)) <>
                ": " <>
                blockText bn [] <>
                " (peer " <>
                p' <>
                ")"
        MGetData (GetData vectors) `sendMessage` peer
  where
    checksyncingpeer =
        getSyncingState >>= \case
            Nothing -> return ()
            Just Syncing {syncingPeer = p}
                | p == peer -> return ()
                | otherwise -> mzero
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
            lift updateOrphans >> resetPeer >> mempool peer >> mzero
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

blockText :: BlockNode -> [Tx] -> Text
blockText bn txs
   | null txs = height <> sep <> time <> sep <> hash
   | otherwise = height <> sep <> time <> sep <> txcount <> sep <> hash
  where
    height = cs $ show (nodeHeight bn)
    systime =
        posixSecondsToUTCTime (fromIntegral (blockTimestamp (nodeHeader bn)))
    time =
        cs $
        formatTime defaultTimeLocale (iso8601DateFormat (Just "%H:%M")) systime
    hash = blockHashToHex (headerHash (nodeHeader bn))
    txcount = cs (show (length txs)) <> " txs"
    sep = " | "
