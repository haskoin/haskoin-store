{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE UndecidableInstances      #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Network.Haskoin.Node.Chain
( chain
) where

import           Control.Concurrent.NQE
import           Control.Monad
import           Control.Monad.Base
import           Control.Monad.Catch
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.Trans.Control
import           Control.Monad.Trans.Maybe
import           Control.Monad.Trans.Resource
import qualified Data.ByteString              as BS
import           Data.Default
import           Data.Either
import           Data.List
import           Data.Maybe
import           Data.Serialize               (decode, encode)
import           Data.String.Conversions
import           Data.Text                    (Text)
import           Database.RocksDB             (DB)
import qualified Database.RocksDB             as RocksDB
import           Network.Haskoin.Block
import           Network.Haskoin.Network
import           Network.Haskoin.Node.Common
import           Network.Haskoin.Util

type MonadChain m
     = ( BlockHeaders m
       , MonadLoggerIO m
       , MonadReader ChainReader m
       , MonadResource m)

data ChainState = ChainState
    { syncingPeer :: !(Maybe Peer)
    , newPeers    :: ![Peer]
    , mySynced    :: !Bool
    }

data ChainReader = ChainReader
    { headerDB   :: !DB
    , myConfig   :: !ChainConfig
    , chainState :: !(TVar ChainState)
    }

instance (Monad m, MonadLoggerIO m, MonadReader ChainReader m, MonadResource m) =>
         BlockHeaders m where
    addBlockHeader bn = do
        db <- asks headerDB
        let bs = encode bn
            sh = encode $ headerHash $ nodeHeader bn
        RocksDB.put db def sh bs
    getBlockHeader bh = do
        db <- asks headerDB
        let sh = encode bh
        bsM <- RocksDB.get db def sh
        return $
            fromRight (error "Could not decode block header") . decode <$> bsM
    getBestBlockHeader = do
        best <-
            runMaybeT $ do
                db <- asks headerDB
                bs <- MaybeT (RocksDB.get db def "best")
                MaybeT (return (eitherToMaybe (decode bs)))
        case best of
            Nothing -> do
                let msg = "Could not get best block from database"
                $(logError) $ logMe <> cs msg
                error msg
            Just b -> return b
    setBestBlockHeader bn = do
        db <- asks headerDB
        let bs = encode bn
        RocksDB.put db def "best" bs
    addBlockHeaders bns = do
        db <- asks headerDB
        RocksDB.write db def $
            map
                (\bn ->
                     RocksDB.Put
                         (encode $ headerHash $ nodeHeader bn)
                         (encode bn))
                bns

chain ::
       ( MonadBase IO m
       , MonadBaseControl IO m
       , MonadLoggerIO m
       , MonadThrow m
       , MonadMask m
       , MonadCatch m
       , Forall (Pure m)
       )
    => ChainConfig
    -> m ()
chain cfg =
    runResourceT $ do
        let opts =
                def
                { RocksDB.createIfMissing = True
                , RocksDB.compression = RocksDB.NoCompression
                }
        hdb <- RocksDB.open (chainConfDbFile cfg) opts
        $(logDebug) $ logMe <> "Added genesis block node"
        st <-
            liftIO $
            newTVarIO
                ChainState
                {syncingPeer = Nothing, mySynced = False, newPeers = []}
        let rd = ChainReader {myConfig = cfg, headerDB = hdb, chainState = st}
        run `runReaderT` rd
  where
    run = do
        let gs = encode genesisNode
        addBlockHeader genesisNode
        db <- asks headerDB
        RocksDB.put db def "best" gs
        forever $ do
            stats
            $(logDebug) $ logMe <> "Awaiting message"
            msg <- receive $ chainConfChain cfg
            processChainMessage msg
    stats = do
        nps <-
            fmap (length . newPeers) $ liftIO . readTVarIO =<< asks chainState
        $(logDebug) $ logMe <> "Pending peers: " <> logShow nps

processChainMessage :: MonadChain m => ChainMessage -> m ()
processChainMessage (ChainNewHeaders p hcs) = do
    stb <- asks chainState
    st <- liftIO $ readTVarIO stb
    let spM = syncingPeer st
    t <- computeTime
    bb <- getBestBlockHeader
    bhsE <- connectBlocks t (map fst hcs)
    case bhsE of
        Right bhs -> conn bb bhs spM
        Left e -> do
            $(logInfo) $ logMe <> "Could not connect headers: " <> cs e
            case spM of
                Nothing -> do
                    bb' <- getBestBlockHeader
                    $(logDebug) $ logMe <> "Sync from this peer later"
                    liftIO . atomically . modifyTVar stb $ \s ->
                        s {newPeers = nub $ p : newPeers s}
                    syncHeaders bb' p
                Just sp
                    | sp == p -> do
                        $(logError) $ logMe <> "Syncing peer sent bad headers"
                        mgr <- chainConfManager <$> asks myConfig
                        managerKill PeerSentBadHeaders p mgr
                        liftIO . atomically . modifyTVar stb $ \s ->
                            s {syncingPeer = Nothing}
                        processSyncQueue
                    | otherwise -> do
                        $(logDebug) $ logMe <> "Sync from this peer later"
                        liftIO . atomically . modifyTVar stb $ \s ->
                            s {newPeers = nub $ p : newPeers s}
  where
    synced bb = do
        $(logDebug) $
            logMe <> "Headers synced to height " <> cs (show $ nodeHeight bb)
        st <- asks chainState
        liftIO . atomically . modifyTVar st $ \s -> s {syncingPeer = Nothing}
        MSendHeaders `sendMessage` p
        processSyncQueue
    upeer bb = do
        mgr <- chainConfManager <$> asks myConfig
        managerSetPeerBest p bb mgr
    conn bb bhs spM = do
        bb' <- getBestBlockHeader
        when (bb /= bb') $ do
            $(logDebug) $
                logMe <> "New best block at height " <> logShow (nodeHeight bb')
            mgr <- chainConfManager <$> asks myConfig
            managerSetBest bb' mgr
            l <- chainConfListener <$> asks myConfig
            liftIO . atomically . l $ ChainNewBest bb'
        case length hcs of
            0 -> synced bb'
            2000 ->
                case spM of
                    Just sp
                        | sp == p -> do
                            upeer $ head bhs
                            $(logDebug) $ logMe <> "Syncing more headers"
                            syncHeaders (head bhs) p
                    _ -> do
                        $(logDebug) $ logMe <> "Sync from this peer later"
                        st <- asks chainState
                        liftIO . atomically . modifyTVar st $ \s ->
                            s {newPeers = nub $ p : newPeers s}
            _ -> do
                upeer $ head bhs
                synced bb'

processChainMessage (ChainNewPeer p) = do
    $(logDebug) $ logMe <> "Got connected peer"
    st <- asks chainState
    sp <- liftIO . atomically $ do
        modifyTVar st $ \s -> s {newPeers = p : newPeers s}
        syncingPeer <$> readTVar st
    case sp of
        Nothing -> processSyncQueue
        Just _  -> return ()

processChainMessage (ChainRemovePeer p) = do
    $(logWarn) $ logMe <> "Got peer disconnection"
    st <- asks chainState
    sp <-
        liftIO . atomically $ do
            modifyTVar st $ \s -> s {newPeers = filter (/= p) (newPeers s)}
            syncingPeer <$> readTVar st
    case sp of
        Just p' ->
            when (p == p') $ do
                liftIO . atomically . modifyTVar st $ \s ->
                    s {syncingPeer = Nothing}
                processSyncQueue
        Nothing -> return ()

processChainMessage (ChainGetBest reply) = do
    b <- getBestBlockHeader
    $(logDebug) $ logMe <> "Best block at height " <> logShow (nodeHeight b)
    liftIO . atomically $ reply b

processChainMessage (ChainGetAncestor h n reply) = do
    $(logDebug) $
        logMe <> "Got request for ancestor of " <> logShow (nodeHeight n) <>
        " at height " <>
        logShow h
    a <- getAncestor h n
    liftIO . atomically $ reply a

processChainMessage (ChainGetSplit r l reply) = do
    $(logDebug) $
        logMe <> "Got request for split point between " <>
        logShow (nodeHeight r) <>
        " and " <>
        logShow (nodeHeight l)
    s <- splitPoint r l
    liftIO . atomically $ reply s

processChainMessage (ChainGetBlock h reply) = do
    $(logDebug) $ logMe <> "Got request for block " <> logShow h
    b <- getBlockHeader h
    liftIO . atomically $ reply b

processChainMessage (ChainSendHeaders _) =
    -- TODO: implement header syncing for peers
    $(logDebug) $ logMe <> "Ignoring sendheaders from peer"

processChainMessage (ChainIsSynced reply) = do
    st <- asks chainState
    s <- liftIO $ mySynced <$> readTVarIO st
    $(logDebug) $ logMe <> "Synced: " <> logShow s
    liftIO . atomically $ reply s

processSyncQueue :: MonadChain m => m ()
processSyncQueue = do
    s <- asks chainState >>= liftIO . readTVarIO
    when (isNothing (syncingPeer s)) $ getBestBlockHeader >>= go s
  where
    go s bb =
        case newPeers s of
            [] -> do
                $(logDebug) $ logMe <> "No more peers to sync"
                t <- computeTime
                let h2 = t - 2 * 60 * 60
                    tg = blockTimestamp (nodeHeader bb) > h2
                if tg
                    then unless (mySynced s) $ do
                             $(logDebug) $ logMe <> "Headers are now synced"
                             l <- chainConfListener <$> asks myConfig
                             st <- asks chainState
                             liftIO . atomically $ do
                                 l $ ChainSynced bb
                                 writeTVar st s {mySynced = True}
                    else do
                        $(logDebug) $ logMe <> "Headers are not yet in sync"
                        l <- chainConfListener <$> asks myConfig
                        st <- asks chainState
                        liftIO . atomically $ do
                            l $ ChainNotSynced bb
                            writeTVar st s {mySynced = False}
            p:_ -> do
                $(logDebug) $ logMe <> "Syncing against new peer"
                syncHeaders bb p

syncHeaders :: MonadChain m => BlockNode -> Peer -> m ()
syncHeaders bb p = do
    $(logDebug) $ logMe <> "Attempting to sync headers with a peer"
    st <- asks chainState
    s <- liftIO $ readTVarIO st
    liftIO . atomically . writeTVar st $
        s {syncingPeer = Just p, newPeers = filter (/= p) (newPeers s)}
    loc <- blockLocator bb
    let m =
            MGetHeaders
                GetHeaders
                { getHeadersVersion = myVersion
                , getHeadersBL = loc
                , getHeadersHashStop =
                      fromRight (error "Could not decode zero hash") .
                      decode $
                      BS.replicate 32 0
                }
    PeerOutgoing m `send` p

logMe :: Text
logMe = "[Chain] "
