{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
module Network.Haskoin.Node.Manager
    ( manager
    ) where

import           Control.Concurrent.Lifted
import           Control.Concurrent.NQE
import           Control.Concurrent.Unique
import           Control.Monad
import           Control.Monad.Base
import           Control.Monad.Catch
import           Control.Monad.Except
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.Trans.Control
import           Control.Monad.Trans.Maybe
import           Data.Bits
import           Data.ByteString              (ByteString)
import qualified Data.ByteString              as BS
import           Data.Default
import           Data.Either
import           Data.Function
import           Data.List
import           Data.Maybe
import           Data.Serialize               (Get, Put, Serialize, decode,
                                               encode, get, put)
import qualified Data.Serialize               as S
import           Data.String.Conversions
import           Data.Text                    (Text)
import           Data.Time.Clock
import           Data.Word
import           Database.RocksDB             (DB)
import qualified Database.RocksDB             as RocksDB
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Network
import           Network.Haskoin.Node.Common
import           Network.Haskoin.Node.Peer
import           Network.Haskoin.Util
import           Network.Socket               (SockAddr (..))
import           System.Random

type MonadManager m
     = ( MonadBase IO m
       , MonadBaseControl IO m
       , MonadThrow m
       , MonadLoggerIO m
       , MonadReader ManagerReader m)

data OnlinePeer = OnlinePeer
    { onlinePeerAddress     :: !SockAddr
    , onlinePeerConnected   :: !Bool
    , onlinePeerVersion     :: !Word32
    , onlinePeerServices    :: !Word64
    , onlinePeerRemoteNonce :: !Word64
    , onlinePeerUserAgent   :: !ByteString
    , onlinePeerRelay       :: !Bool
    , onlinePeerBestBlock   :: !BlockNode
    , onlinePeerAsync       :: !(Async ())
    , onlinePeerMailbox     :: !Peer
    , onlinePeerNonce       :: !Word64
    , onlinePeerPings       :: ![NominalDiffTime]
    }

data ManagerReader = ManagerReader
    { mySelf           :: !Manager
    , myChain          :: !Chain
    , myConfig         :: !ManagerConfig
    , myPeerDB         :: !DB
    , myPeerSupervisor :: !(Inbox SupervisorMessage)
    , onlinePeers      :: !(TVar [OnlinePeer])
    , myBloomFilter    :: !(TVar (Maybe BloomFilter))
    , myBestBlock      :: !(TVar BlockNode)
    }

data Priority
    = PriorityNetwork
    | PrioritySeed
    | PriorityManual
    deriving (Eq, Show, Ord)

newtype PeerAddress = PeerAddress
    { getPeerAddress :: SockAddr
    } deriving (Eq, Show)

instance Serialize Priority where
    get =
        S.getWord8 >>= \case
            0x00 -> return PriorityManual
            0x01 -> return PrioritySeed
            0x02 -> return PriorityNetwork
            _ -> mzero
    put PriorityManual  = S.putWord8 0x00
    put PrioritySeed    = S.putWord8 0x01
    put PriorityNetwork = S.putWord8 0x02

instance Serialize PeerAddress where
    get = do
        guard . (== 0x81) =<< S.getWord8
        getPeerAddress <- decodeSockAddr
        return PeerAddress {..}
    put PeerAddress {..} = do
        S.putWord8 0x81
        encodeSockAddr getPeerAddress

data PeerTimeAddress = PeerTimeAddress
    { getPeerPrio        :: !Priority
    , getPeerBanned      :: !Word32
    , getPeerLastConnect :: !Word32
    , getPeerNextConnect :: !Word32
    , getPeerTimeAddress :: !PeerAddress
    } deriving (Eq, Show)

instance Serialize PeerTimeAddress where
    get = do
        guard . (== 0x80) =<< S.getWord8
        getPeerPrio <- S.get
        getPeerBanned <- S.get
        getPeerLastConnect <- (maxBound -) <$> S.get
        getPeerNextConnect <- S.get
        getPeerTimeAddress <- S.get
        return PeerTimeAddress {..}
    put PeerTimeAddress {..} = do
        S.putWord8 0x80
        S.put getPeerPrio
        S.put getPeerBanned
        S.put (maxBound - getPeerLastConnect)
        S.put getPeerNextConnect
        S.put getPeerTimeAddress

manager ::
       ( MonadBase IO m
       , MonadBaseControl IO m
       , MonadThrow m
       , MonadLoggerIO m
       , MonadMask m
       , Forall (Pure m)
       )
    => ManagerConfig
    -> m ()
manager cfg = do
    bb <- chainGetBest $ mgrConfChain cfg
    opb <- liftIO $ newTVarIO []
    bfb <- liftIO $ newTVarIO Nothing
    bbb <- liftIO $ newTVarIO bb
    withConnectLoop (mgrConfManager cfg) $ do
        let rd =
                ManagerReader
                { mySelf = mgrConfManager cfg
                , myChain = mgrConfChain cfg
                , myConfig = cfg
                , myPeerDB = mgrConfDB cfg
                , myPeerSupervisor = mgrConfPeerSupervisor cfg
                , onlinePeers = opb
                , myBloomFilter = bfb
                , myBestBlock = bbb
                }
        run `runReaderT` rd
  where
    run = do
        connectNewPeers
        managerLoop

resolvePeers :: MonadManager m => m [(SockAddr, Priority)]
resolvePeers = do
    cfg <- asks myConfig
    confPeers <-
        fmap
            (map (, PriorityManual) . concat)
            (mapM toSockAddr (mgrConfPeers cfg))
    if mgrConfDiscover cfg
        then do
            seedPeers <-
                fmap
                    (map (, PrioritySeed) . concat)
                    (mapM (toSockAddr . (, defaultPort)) seeds)
            return (confPeers ++ seedPeers)
        else return confPeers

encodeSockAddr :: SockAddr -> Put
encodeSockAddr (SockAddrInet6 p _ (a, b, c, d) _) = do
    S.putWord32be a
    S.putWord32be b
    S.putWord32be c
    S.putWord32be d
    S.putWord16be (fromIntegral p)

encodeSockAddr (SockAddrInet p a) = do
    S.putWord32be 0x00000000
    S.putWord32be 0x00000000
    S.putWord32be 0x0000ffff
    S.putWord32host a
    S.putWord16be (fromIntegral p)

encodeSockAddr x = error $ "Colud not encode address: " <> show x

decodeSockAddr :: Get SockAddr
decodeSockAddr = do
    a <- S.getWord32be
    b <- S.getWord32be
    c <- S.getWord32be
    if a == 0x00000000 && b == 0x00000000 && c == 0x0000ffff
        then do
            d <- S.getWord32host
            p <- S.getWord16be
            return $ SockAddrInet (fromIntegral p) d
        else do
            d <- S.getWord32be
            p <- S.getWord16be
            return $ SockAddrInet6 (fromIntegral p) 0 (a, b, c, d) 0

connectPeer :: MonadManager m => SockAddr -> m ()
connectPeer sa = do
    db <- asks myPeerDB
    let p = PeerAddress sa
        k = encode p
    m <- RocksDB.get db def k
    case m of
        Nothing -> do
            let msg = "Could not find peer to mark connected"
            $(logError) $ logMe <> cs msg
            error msg
        Just bs -> do
            now <- computeTime
            let v = fromRight (error "Cannot decode peer info") (decode bs)
                v' = v { getPeerLastConnect = now }
                bs' = encode v'
            RocksDB.write
                db
                def
                [RocksDB.Del bs, RocksDB.Put bs' k, RocksDB.Put k bs']

storePeer :: MonadManager m => SockAddr -> Priority -> m ()
storePeer sa prio = do
    db <- asks myPeerDB
    let p = PeerAddress sa
        k = encode p
    m <- RocksDB.get db def k
    case m of
        Nothing -> do
            let v =
                    encode
                        PeerTimeAddress
                        { getPeerPrio = prio
                        , getPeerBanned = 0
                        , getPeerLastConnect = 0
                        , getPeerNextConnect = 0
                        , getPeerTimeAddress = p
                        }
            RocksDB.write db def [RocksDB.Put v k, RocksDB.Put k v]
        Just bs -> do
            let v@PeerTimeAddress {..} =
                    fromRight (error "Cannot decode peer info") (decode bs)
            when (getPeerPrio < prio) $ do
                let bs' = encode v {getPeerPrio = prio}
                RocksDB.write
                    db
                    def
                    [RocksDB.Del bs, RocksDB.Put bs' k, RocksDB.Put k bs']

banPeer :: MonadManager m => SockAddr -> m ()
banPeer sa = do
    db <- asks myPeerDB
    let p = PeerAddress sa
        k = encode p
    m <- RocksDB.get db def k
    case m of
        Nothing -> e "Cannot find peer to be banned"
        Just bs -> do
            now <- computeTime
            let v = fromRight (error "Cannot decode peer info") (decode bs)
                v' =
                    v
                    { getPeerBanned = now
                    , getPeerNextConnect = now + 6 * 60 * 60
                    }
                bs' = encode v'
            when (getPeerPrio v == PriorityNetwork) $ do
                $(logWarn) $ logMe <> "Banning peer " <> logShow sa
                RocksDB.write
                    db
                    def
                    [RocksDB.Del bs, RocksDB.Put k bs', RocksDB.Put bs' k]
  where
    e msg = do
        $(logError) $ logMe <> cs msg
        error msg

backoffPeer :: MonadManager m => SockAddr -> m ()
backoffPeer sa = do
    db <- asks myPeerDB
    onlinePeers <- map onlinePeerAddress <$> getOnlinePeers
    let p = PeerAddress sa
        k = encode p
    m <- RocksDB.get db def k
    case m of
        Nothing -> e "Cannot find peer to backoff in database"
        Just bs -> do
            now <- computeTime
            r <-
                liftIO . randomRIO $
                if null onlinePeers
                    then (90, 300) -- Don't backoff so much if possibly offline
                    else (900, 1800)
            let v =
                    fromRight
                        (error "Could not decode peer info from db")
                        (decode bs)
                t = max (now + r) (getPeerNextConnect v)
                v' = v {getPeerNextConnect = t}
                bs' = encode v'
            when (getPeerPrio v == PriorityNetwork) $ do
                $(logWarn) $
                    logMe <> "Backing off peer " <> logShow sa <> " for " <>
                    logShow r <>
                    " seconds"
                RocksDB.write
                    db
                    def
                    [RocksDB.Del bs, RocksDB.Put k bs', RocksDB.Put bs' k]
  where
    e msg = do
        $(logError) $ logMe <> cs msg
        error msg

getNewPeer :: MonadManager m => m (Maybe SockAddr)
getNewPeer = do
    ManagerConfig {..} <- asks myConfig
    onlinePeers <- map onlinePeerAddress <$> getOnlinePeers
    configPeers <- concat <$> mapM toSockAddr mgrConfPeers
    if mgrConfDiscover
        then do
            pdb <- asks myPeerDB
            now <- computeTime
            RocksDB.withIter pdb def $ \it -> do
                RocksDB.iterSeek it (BS.singleton 0x80)
                runMaybeT $ go now it onlinePeers
        else return $ find (not . (`elem` onlinePeers)) configPeers
  where
    go now it onlinePeers = do
        kbs <- MaybeT (RocksDB.iterKey it)
        k <- MaybeT (return (eitherToMaybe (decode kbs)))
        vbs <- MaybeT (RocksDB.iterValue it)
        v <- MaybeT (return (eitherToMaybe (decode vbs)))
        guard (getPeerNextConnect k <= now)
        if getPeerAddress v `elem` onlinePeers
            then do
                RocksDB.iterNext it
                go now it onlinePeers
            else return (getPeerAddress v)

getConnectedPeers :: MonadManager m => m [OnlinePeer]
getConnectedPeers = filter onlinePeerConnected <$> getOnlinePeers

withConnectLoop ::
       ( MonadBaseControl IO m
       , MonadLoggerIO m
       , Forall (Pure m)
       )
    => Manager
    -> m a
    -> m a
withConnectLoop mgr f = withAsync go $ const f
  where
    go =
        forever $ do
            ManagerPing `send` mgr
            i <- liftIO (randomRIO (30, 90))
            threadDelay (i * 1000 * 1000)

managerLoop :: (MonadManager m, MonadMask m) => m ()
managerLoop =
    forever $ do
        mgr <- asks mySelf
        msg <- receive mgr
        processManagerMessage msg

processManagerMessage :: MonadManager m => ManagerMessage -> m ()

processManagerMessage (ManagerSetFilter bf) = setFilter bf

processManagerMessage (ManagerSetBest bb) = do
    bbb <- asks myBestBlock
    liftIO . atomically $ writeTVar bbb bb

processManagerMessage ManagerPing = connectNewPeers

processManagerMessage (ManagerGetAddr p) = do
    pn <- peerString p
    $(logWarn) $ logMe <> "Ignoring address request from peer " <> cs pn

processManagerMessage (ManagerNewPeers p as) =
    void . runMaybeT $ do
        ManagerConfig {..} <- asks myConfig
        guard mgrConfDiscover
        pn <- peerString p
        $(logInfo) $
            logMe <> "Received " <> logShow (length as) <> " peers from " <>
            cs pn
        forM_ as $ \(_, na) ->
            let sa = naAddress na
            in storePeer sa PriorityNetwork

processManagerMessage (ManagerKill e p) =
    void . runMaybeT $ do
        op <- MaybeT $ findPeer p
        $(logError) $ logMe <> "Killing peer " <> logShow (onlinePeerAddress op)
        banPeer $ onlinePeerAddress op
        onlinePeerAsync op `cancelWith` e

processManagerMessage (ManagerSetPeerBest p bn) = modifyPeer f p
  where
    f op = op {onlinePeerBestBlock = bn}

processManagerMessage (ManagerGetPeerBest p reply) = do
    op <- findPeer p
    let bn = fmap onlinePeerBestBlock op
    liftIO . atomically $ reply bn

processManagerMessage (ManagerSetPeerVersion p v) =
    void . runMaybeT $ do
        modifyPeer f p
        op <- MaybeT $ findPeer p
        runExceptT testVersion >>= \case
            Left ex -> do
                banPeer $ onlinePeerAddress op
                onlinePeerAsync op `cancelWith` ex
            Right () -> do
                loadFilter
                askForPeers
                connectPeer (onlinePeerAddress op)
                announcePeer
  where
    f op =
        op
        { onlinePeerVersion = version v
        , onlinePeerServices = services v
        , onlinePeerRemoteNonce = verNonce v
        , onlinePeerUserAgent = getVarString (userAgent v)
        , onlinePeerRelay = relay v
        }
    testVersion = do
        when (services v .&. nodeNetwork == 0) $ throwError NotNetworkPeer
        bfb <- asks myBloomFilter
        bf <- liftIO $ readTVarIO bfb
        when (isJust bf && services v .&. nodeBloom == 0) $
            throwError BloomFiltersNotSupported
        myself <-
            any ((verNonce v ==) . onlinePeerNonce) <$> lift getOnlinePeers
        when myself $ throwError PeerIsMyself
    loadFilter = do
        bfb <- asks myBloomFilter
        bf <- liftIO $ readTVarIO bfb
        case bf of
            Nothing -> return ()
            Just b  -> b `peerSetFilter` p
    askForPeers =
        mgrConfDiscover <$> asks myConfig >>= \discover ->
            when discover (MGetAddr `sendMessage` p)
    announcePeer =
        void . runMaybeT $ do
            op <- MaybeT $ findPeer p
            guard (not (onlinePeerConnected op))
            $(logInfo) $
                logMe <> "Connected to " <> logShow (onlinePeerAddress op)
            l <- mgrConfMgrListener <$> asks myConfig
            liftIO . atomically . l $ ManagerConnect p
            ch <- asks myChain
            chainNewPeer p ch
            setPeerAnnounced p

processManagerMessage (ManagerGetPeerVersion p reply) = do
    v <- fmap onlinePeerVersion <$> findPeer p
    liftIO . atomically $ reply v

processManagerMessage (ManagerGetPeers reply) =
    getPeers >>= liftIO . atomically . reply

processManagerMessage (ManagerPeerPing p i) =
    modifyPeer (\x -> x {onlinePeerPings = take 11 $ i : onlinePeerPings x}) p

processManagerMessage (PeerStopped (p, _ex)) = do
    opb <- asks onlinePeers
    m <- liftIO . atomically $ do
        m <- findPeerAsync p opb
        when (isJust m) $ removePeer p opb
        return m
    case m of
        Just op -> do
            backoffPeer (onlinePeerAddress op)
            processPeerOffline op
        Nothing -> return ()

processPeerOffline :: MonadManager m => OnlinePeer -> m ()
processPeerOffline op
    | onlinePeerConnected op = do
        let p = onlinePeerMailbox op
        $(logWarn) $
            logMe <> "Disconnected peer " <> logShow (onlinePeerAddress op)
        asks myChain >>= chainRemovePeer p
        l <- mgrConfMgrListener <$> asks myConfig
        liftIO . atomically . l $ ManagerDisconnect p
    | otherwise =
        $(logWarn) $
        logMe <> "Could not connect to peer " <> logShow (onlinePeerAddress op)

getPeers :: MonadManager m => m [Peer]
getPeers = do
    ps <- getConnectedPeers
    return . map onlinePeerMailbox $
        sortBy (compare `on` median . onlinePeerPings) ps

connectNewPeers :: (MonadManager m) => m ()
connectNewPeers = do
    mo <- mgrConfMaxPeers <$> asks myConfig
    ps <- getOnlinePeers
    let n = mo - length ps
    case ps of
        [] -> do
            $(logWarn) $ logMe <> "No peers connected"
            ps' <- resolvePeers
            mapM_ (uncurry storePeer) ps'
        _ ->
            $(logInfo) $
            logMe <> "Peers connected: " <> logShow (length ps) <> "/" <>
            logShow mo
    void $ runMaybeT $ go n
  where
    go 0 = MaybeT $ return Nothing
    go n = do
        ad <- mgrConfNetAddr <$> asks myConfig
        mgr <- asks mySelf
        ch <- asks myChain
        pl <- mgrConfPeerListener <$> asks myConfig
        sa <- MaybeT getNewPeer
        $(logInfo) $ logMe <> "Connecting to peer " <> logShow sa
        bbb <- asks myBestBlock
        bb <- liftIO $ readTVarIO bbb
        nonce <- liftIO randomIO
        let pc =
                PeerConfig
                { peerConfConnect = NetworkAddress 0 sa
                , peerConfInitBest = bb
                , peerConfLocal = ad
                , peerConfManager = mgr
                , peerConfChain = ch
                , peerConfListener = pl
                , peerConfNonce = nonce
                }
        psup <- asks myPeerSupervisor
        pmbox <- liftIO $ newTBQueueIO 100
        uid <- liftIO newUnique
        let p = UniqueInbox {uniqueInbox = Inbox pmbox, uniqueId = uid}
        lg <- askLoggerIO
        a <- psup `addChild` (peer pc p `runLoggingT` lg)
        newPeerConnection sa nonce p a
        go (n - 1)

newPeerConnection ::
       MonadManager m => SockAddr -> Word64 -> Peer -> Async () -> m ()
newPeerConnection sa nonce p a =
    addPeer
        OnlinePeer
        { onlinePeerAddress = sa
        , onlinePeerConnected = False
        , onlinePeerVersion = 0
        , onlinePeerServices = 0
        , onlinePeerRemoteNonce = 0
        , onlinePeerUserAgent = BS.empty
        , onlinePeerRelay = False
        , onlinePeerBestBlock = genesisNode
        , onlinePeerAsync = a
        , onlinePeerMailbox = p
        , onlinePeerNonce = nonce
        , onlinePeerPings = []
        }

peerString :: MonadManager m => Peer -> m String
peerString p = maybe "unknown" (show . onlinePeerAddress) <$> findPeer p

setPeerAnnounced :: MonadManager m => Peer -> m ()
setPeerAnnounced = modifyPeer (\x -> x {onlinePeerConnected = True})

setFilter :: MonadManager m => BloomFilter -> m ()
setFilter bl = do
    bfb <- asks myBloomFilter
    liftIO . atomically . writeTVar bfb $ Just bl
    ops <- getOnlinePeers
    forM_ ops $ \op ->
        when (onlinePeerConnected op) $
        if acceptsFilters $ onlinePeerServices op
            then bl `peerSetFilter` onlinePeerMailbox op
            else do
                $(logError) $
                    logMe <> "Peer " <> logShow (onlinePeerAddress op) <>
                    "does not support bloom filters"
                banPeer (onlinePeerAddress op)
                onlinePeerAsync op `cancelWith` BloomFiltersNotSupported

logMe :: Text
logMe = "[Manager] "

findPeer :: MonadManager m => Peer -> m (Maybe OnlinePeer)
findPeer p = find ((== p) . onlinePeerMailbox) <$> getOnlinePeers

findPeerAsync :: Async () -> TVar [OnlinePeer] -> STM (Maybe OnlinePeer)
findPeerAsync a t = find ((== a) . onlinePeerAsync) <$> readTVar t

modifyPeer :: MonadManager m => (OnlinePeer -> OnlinePeer) -> Peer -> m ()
modifyPeer f p = modifyOnlinePeers $ map upd
  where
    upd op =
        if onlinePeerMailbox op == p
            then f op
            else op

addPeer :: MonadManager m => OnlinePeer -> m ()
addPeer op = modifyOnlinePeers $ nubBy f . (op :)
  where
    f = (==) `on` onlinePeerMailbox

removePeer :: Async () -> TVar [OnlinePeer] -> STM ()
removePeer a t = modifyTVar t $ filter ((/= a) . onlinePeerAsync)

getOnlinePeers :: MonadManager m => m [OnlinePeer]
getOnlinePeers = asks onlinePeers >>= liftIO . atomically . readTVar

modifyOnlinePeers :: MonadManager m => ([OnlinePeer] -> [OnlinePeer]) -> m ()
modifyOnlinePeers f = asks onlinePeers >>= liftIO . atomically . (`modifyTVar` f)

median :: Fractional a => [a] -> Maybe a
median ls
    | null ls = Nothing
    | length ls `mod` 2 == 0 =
        Just . (/ 2) . sum . take 2 $ drop (length ls `div` 2 - 1) ls
    | otherwise = Just . head $ drop (length ls `div` 2) ls
