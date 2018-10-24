{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE MultiWayIf        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections     #-}
module Network.Haskoin.Store.Block
      ( blockStore
      ) where

import           Control.Monad.Except
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.Trans.Maybe
import           Data.Maybe
import           Data.String
import           Data.Time.Clock.System
import           Database.RocksDB
import           Haskoin
import           Haskoin.Node
import           Network.Haskoin.Store.Data
import           Network.Haskoin.Store.Data.ImportDB
import           Network.Haskoin.Store.Logic
import           Network.Haskoin.Store.Messages
import           NQE
import           System.Random
import           UnliftIO
import           UnliftIO.Concurrent

data BlockException
    = BlockNotInChain !BlockHash
    | Uninitialized
    | UnexpectedGenesisNode
    | SyncingPeerExpected
    | AncestorNotInChain !BlockHeight
                         !BlockHash
    deriving (Show, Eq, Ord, Exception)

data Syncing = Syncing
    { syncingPeer :: !Peer
    , syncingTime :: !UnixTime
    , syncingHead :: !BlockNode
    }

-- | Block store process state.
data BlockRead = BlockRead
    { mySelf   :: !BlockStore
    , myConfig :: !BlockConfig
    , myPeer   :: !(TVar (Maybe Syncing))
    }

-- | Run block store process.
blockStore ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => BlockConfig
    -> Inbox BlockMessage
    -> m ()
blockStore cfg inbox = do
    $(logInfoS) "Block" "Initializing block store..."
    pb <- newTVarIO Nothing
    runReaderT
        (ini >> run)
        BlockRead {mySelf = inboxToMailbox inbox, myConfig = cfg, myPeer = pb}
  where
    ini = do
        db <- blockConfDB <$> asks myConfig
        net <- blockConfNet <$> asks myConfig
        runExceptT (initDB net db) >>= \case
            Left e -> do
                $(logErrorS) "Block" $
                    "Could not initialize block store: " <> fromString (show e)
                throwIO e
            Right () -> $(logInfoS) "Block" "Initialization complete"
    run =
        withAsync (pingMe (inboxToMailbox inbox)) $ \_ ->
            forever $ receive inbox >>= processBlockMessage

isSynced :: (MonadReader BlockRead m, MonadUnliftIO m) => m Bool
isSynced = do
    db <- blockConfDB <$> asks myConfig
    getBestBlock (db, defaultReadOptions) >>= \case
        Nothing -> throwIO Uninitialized
        Just bb -> do
            ch <- blockConfChain <$> asks myConfig
            chainGetBest ch >>= \cb -> return (headerHash (nodeHeader cb) == bb)

mempool ::
       (MonadReader BlockRead m, MonadUnliftIO m, MonadLoggerIO m) => Peer -> m ()
mempool p = MMempool `sendMessage` p

processBlock ::
       (MonadReader BlockRead m, MonadUnliftIO m, MonadLoggerIO m)
    => Peer
    -> Block
    -> m ()
processBlock p b = do
    $(logDebugS) "Block" ("Processing incoming block " <> hex)
    void . runMaybeT $ do
        iss >>= \x ->
            unless x $ do
                $(logErrorS)
                    "Block"
                    ("Cannot accept block " <> hex <> " from non-syncing peer")
                mzero
        db <- blockConfDB <$> asks myConfig
        n <- cbn
        upr
        net <- blockConfNet <$> asks myConfig
        runExceptT (newBlock net db b n) >>= \case
            Right () -> do
                l <- blockConfListener <$> asks myConfig
                atomically $ l (StoreBestBlock (headerHash (blockHeader b)))
                lift $ isSynced >>= \x -> when x (mempool p)
            Left e -> do
                $(logErrorS) "Block" $
                    "Error importing block " <>
                    fromString (show $ headerHash (blockHeader b)) <>
                    ": " <>
                    fromString (show e)
                killPeer (PeerMisbehaving (show e)) p
    syncMe
  where
    hex = blockHashToHex (headerHash (blockHeader b))
    upr =
        asks myPeer >>= \box ->
            readTVarIO box >>= \case
                Nothing -> throwIO SyncingPeerExpected
                Just s@Syncing {syncingHead = h} ->
                    if nodeHeader h == blockHeader b
                        then resetPeer
                        else do
                            now <- systemSeconds <$> liftIO getSystemTime
                            atomically . writeTVar box $
                                Just s {syncingTime = now}
    iss =
        asks myPeer >>= readTVarIO >>= \case
            Just Syncing {syncingPeer = p'} -> return $ p == p'
            Nothing -> return False
    cbn =
        blockConfChain <$> asks myConfig >>=
        chainGetBlock (headerHash (blockHeader b)) >>= \case
            Nothing -> do
                killPeer (PeerMisbehaving "Sent unknown block") p
                $(logErrorS)
                    "Block"
                    ("Block " <> hex <> " rejected as header not found")
                mzero
            Just n -> return n

processNoBlocks ::
       (MonadReader BlockRead m, MonadUnliftIO m, MonadLoggerIO m)
    => Peer
    -> [BlockHash]
    -> m ()
processNoBlocks p _bs = do
    $(logErrorS) "Block" "Killing peer that could not find blocks"
    killPeer (PeerMisbehaving "Sent notfound message with block hashes") p

processTx ::
       (MonadReader BlockRead m, MonadUnliftIO m, MonadLoggerIO m)
    => Peer
    -> Tx
    -> m ()
processTx _p tx =
    isSynced >>= \x ->
        when x $ do
            $(logInfoS) "Block" $ "Incoming tx: " <> txHashToHex (txHash tx)
            now <- preciseUnixTime <$> liftIO getSystemTime
            net <- blockConfNet <$> asks myConfig
            db <- blockConfDB <$> asks myConfig
            runExceptT (runImportDB db $ \i -> newMempoolTx net i tx now) >>= \case
                Left e ->
                    $(logErrorS) "Block" $
                    "Error importing tx: " <> txHashToHex (txHash tx) <> ": " <>
                    fromString (show e)
                Right () -> do
                    l <- blockConfListener <$> asks myConfig
                    atomically $ l (StoreMempoolNew (txHash tx))

processTxs ::
       (MonadReader BlockRead m, MonadUnliftIO m, MonadLoggerIO m)
    => Peer
    -> [TxHash]
    -> m ()
processTxs p hs =
    isSynced >>= \x ->
        when x $ do
            db <- blockConfDB <$> asks myConfig
            $(logDebugS) "Block" $
                "Received " <> fromString (show (length hs)) <>
                " tranasaction inventory"
            xs <-
                fmap catMaybes . forM hs $ \h ->
                    runMaybeT $ do
                        t <- getTransaction (db, defaultReadOptions) h
                        guard (isNothing t)
                        return (getTxHash h)
            $(logDebugS) "Block" $
                "Requesting " <> fromString (show (length xs)) <>
                " new transactions"
            MGetData (GetData (map (InvVector InvTx) xs)) `sendMessage` p

checkTime :: (MonadReader BlockRead m, MonadUnliftIO m, MonadLoggerIO m) => m ()
checkTime =
    asks myPeer >>= readTVarIO >>= \case
        Nothing -> return ()
        Just Syncing {syncingTime = t, syncingPeer = p} -> do
            n <- systemSeconds <$> liftIO getSystemTime
            when (n > t + 60) $ do
                $(logErrorS) "Block" "Peer timeout"
                killPeer PeerTimeout p

processDisconnect ::
       (MonadReader BlockRead m, MonadUnliftIO m, MonadLoggerIO m)
    => Peer
    -> m ()
processDisconnect p =
    asks myPeer >>= readTVarIO >>= \case
        Nothing -> return ()
        Just Syncing {syncingPeer = p'}
            | p == p' -> do
                $(logErrorS) "Block" "Syncing peer disconnected"
                resetPeer
                syncMe
            | otherwise -> return ()

purgeMempool ::
       (MonadReader BlockRead m, MonadUnliftIO m, MonadLoggerIO m) => m ()
purgeMempool = $(logErrorS) "Block" "Mempool purging not implemented"

syncMe :: (MonadReader BlockRead m, MonadUnliftIO m, MonadLoggerIO m) => m ()
syncMe =
    void . runMaybeT $ do
        rev
        p <-
            gpr >>= \case
                Nothing -> do
                    $(logWarnS)
                        "Block"
                        "Not syncing blocks as no peers available"
                    mzero
                Just p -> return p
        b <- mbn
        d <- dbn
        c <- cbn
        when (end b d c) mzero
        ns <- bls c b
        setPeer p (last ns)
        vs <- mapM f ns
        $(logInfoS) "Block" $
            "Requesting " <> fromString (show (length vs)) <> " blocks"
        MGetData (GetData vs) `sendMessage` p
  where
    gpr =
        asks myPeer >>= readTVarIO >>= \case
            Just Syncing {syncingPeer = p} -> return (Just p)
            Nothing ->
                blockConfManager <$> asks myConfig >>= managerGetPeers >>= \case
                    [] -> return Nothing
                    OnlinePeer {onlinePeerMailbox = p}:_ -> return (Just p)
    cbn = chainGetBest =<< blockConfChain <$> asks myConfig
    dbn = do
        db <- blockConfDB <$> asks myConfig
        bb <-
            getBestBlock (db, defaultReadOptions) >>= \case
                Nothing -> do
                    $(logErrorS) "Block" "Best block not in database"
                    throwIO Uninitialized
                Just b -> return b
        ch <- blockConfChain <$> asks myConfig
        chainGetBlock bb ch >>= \case
            Nothing -> do
                $(logErrorS) "Block" $
                    "Block header not found for best block " <>
                    blockHashToHex bb
                throwIO (BlockNotInChain bb)
            Just x -> return x
    mbn =
        asks myPeer >>= readTVarIO >>= \case
            Just Syncing {syncingHead = b} -> return b
            Nothing -> dbn
    end b d c
        | nodeHeader b == nodeHeader c = True
        | otherwise = nodeHeight b > nodeHeight d + 500
    f GenesisNode {} = throwIO UnexpectedGenesisNode
    f BlockNode {nodeHeader = bh} =
        return $ InvVector InvBlock (getBlockHash (headerHash bh))
    bls c b = do
        t <- top c (tts (nodeHeight c) (nodeHeight b))
        ch <- blockConfChain <$> asks myConfig
        ps <- chainGetParents (nodeHeight b + 1) t ch
        return $
            if length ps < 500
                then ps <> [c]
                else ps
    tts c b
        | c <= b + 501 = c
        | otherwise = b + 501
    top c t = do
        ch <- blockConfChain <$> asks myConfig
        if t == nodeHeight c
            then return c
            else chainGetAncestor t c ch >>= \case
                     Just x -> return x
                     Nothing -> do
                         $(logErrorS) "Block" $
                             "Unknown header for ancestor of block " <>
                             blockHashToHex (headerHash (nodeHeader c)) <>
                             " at height " <>
                             fromString (show t)
                         throwIO $
                             AncestorNotInChain t (headerHash (nodeHeader c))
    rev = do
        d <- headerHash . nodeHeader <$> dbn
        ch <- blockConfChain <$> asks myConfig
        chainBlockMain d ch >>= \m ->
            unless m $ do
                $(logErrorS) "Block" $
                    "Reverting best block " <> blockHashToHex d <>
                    " as it is not in main chain..."
                resetPeer
                db <- blockConfDB <$> asks myConfig
                runExceptT (runImportDB db $ \i -> revertBlock i d) >>= \case
                    Left e -> do
                        $(logErrorS) "Block" $
                            "Could not revert best block: " <>
                            fromString (show e)
                        throwIO e
                    Right () -> rev

resetPeer :: (MonadReader BlockRead m, MonadLoggerIO m) => m ()
resetPeer = do
    $(logDebugS) "Block" "Resetting syncing peer..."
    box <- asks myPeer
    atomically $ writeTVar box Nothing

setPeer :: (MonadReader BlockRead m, MonadIO m) => Peer -> BlockNode -> m ()
setPeer p b = do
    box <- asks myPeer
    now <- systemSeconds <$> liftIO getSystemTime
    atomically . writeTVar box $
        Just Syncing {syncingPeer = p, syncingHead = b, syncingTime = now}

processBlockMessage ::
       (MonadReader BlockRead m, MonadUnliftIO m, MonadLoggerIO m)
    => BlockMessage
    -> m ()
processBlockMessage (BlockNewBest bn) = do
    $(logDebugS) "Block" $
        "New best block header " <> fromString (show (nodeHeight bn)) <> ": " <>
        blockHashToHex (headerHash (nodeHeader bn))
    syncMe
processBlockMessage (BlockPeerConnect _p sa) = do
    $(logDebugS) "Block" $ "New peer connected: " <> fromString (show sa)
    syncMe
processBlockMessage (BlockPeerDisconnect p _sa) = processDisconnect p
processBlockMessage (BlockReceived p b) = processBlock p b
processBlockMessage (BlockNotFound p bs) = processNoBlocks p bs
processBlockMessage (BlockTxReceived p tx) = processTx p tx
processBlockMessage (BlockTxAvailable p ts) = processTxs p ts
processBlockMessage BlockPing = checkTime
processBlockMessage PurgeMempool = purgeMempool

pingMe :: MonadIO m => Mailbox BlockMessage -> m ()
pingMe mbox = forever $ do
    threadDelay =<< liftIO (randomRIO (5 * 1000 * 1000, 10 * 1000 * 1000))
    BlockPing `send` mbox
