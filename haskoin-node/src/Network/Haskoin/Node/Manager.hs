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
import           Control.Monad.Trans.Resource
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
import           System.FilePath
import           System.Random

type MonadManager m
     = ( MonadBase IO m
       , MonadBaseControl IO m
       , MonadThrow m
       , MonadLoggerIO m
       , MonadReader ManagerReader m
       , MonadResource m)

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

newtype PeerAddress = PeerAddress {getPeerAddress :: SockAddr}
    deriving (Eq, Show)

instance Serialize PeerAddress where
    get = do
        b <- S.getWord8
        guard (b == 0x01)
        PeerAddress <$> decodeSockAddr
    put pa = do
        S.putWord8 0x01
        encodeSockAddr $ getPeerAddress pa

data PeerTimeAddress = PeerTimeAddress
    { getPeerNextConnect :: !Word32
    , getPeerTimeAddress :: !PeerAddress
    } deriving (Eq, Show)

instance Serialize PeerTimeAddress where
    get = do
        b <- S.getWord8
        guard (b == 0x00)
        t <- S.get
        a <- S.get
        return $ PeerTimeAddress t a
    put pta = do
        S.putWord8 0x00
        S.put (getPeerNextConnect pta)
        S.put (getPeerTimeAddress pta)

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
    withConnectLoop (mgrConfManager cfg) $
        runResourceT $ do
            let opts =
                    def
                    { RocksDB.createIfMissing = True
                    , RocksDB.compression = RocksDB.NoCompression
                    }
            pdb <- RocksDB.open (mgrConfDir cfg </> "peers") opts
            let rd =
                    ManagerReader
                    { mySelf = mgrConfManager cfg
                    , myChain = mgrConfChain cfg
                    , myConfig = cfg
                    , myPeerDB = pdb
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

resolvePeers :: MonadManager m => m [SockAddr]
resolvePeers = do
    cfg <- asks myConfig
    confPeers <- concat <$> mapM toSockAddr (mgrConfPeers cfg)
    if mgrConfNoNewPeers cfg
        then return confPeers
        else do
            seedPeers <- concat <$> mapM (toSockAddr . (, defaultPort)) seeds
            return $ confPeers <> seedPeers

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

storePeer :: MonadManager m => SockAddr -> m ()
storePeer sa = do
    db <- asks myPeerDB
    now <- computeTime
    let p = PeerAddress sa
        k = encode p
    m <- RocksDB.get db def k
    when (isNothing m) $ do
        $(logDebug) $ logMe <> "Storing peer " <> logShow sa
        let v = encode (PeerTimeAddress now p)
        RocksDB.write db def [RocksDB.Put v k, RocksDB.Put k v]

banPeer :: MonadManager m => SockAddr -> m ()
banPeer sa = do
    $(logWarn) $ logMe <> "Banning peer " <> logShow sa
    db <- asks myPeerDB
    let p = PeerAddress sa
        k = encode p
    m <- RocksDB.get db def k
    now <- computeTime
    let v = encode (PeerTimeAddress (now + 3600 * 6) p)
    case m of
        Nothing -> RocksDB.write db def [RocksDB.Put v k, RocksDB.Put k v]
        Just bs ->
            RocksDB.write
                db
                def
                [RocksDB.Del bs, RocksDB.Put k v, RocksDB.Put v k]

backoffPeer :: MonadManager m => SockAddr -> m ()
backoffPeer sa = do
    db <- asks myPeerDB
    onlinePeers <- map onlinePeerAddress <$> getOnlinePeers
    let p = PeerAddress sa
        k = encode p
    m <- RocksDB.get db def k
    now <- computeTime
    r <-
        liftIO . randomRIO $
        if null onlinePeers
            then (90, 300)
            else (900, 1800)
    case m of
        Nothing -> do
            let v = encode (PeerTimeAddress (now + r) p)
            RocksDB.write db def [RocksDB.Put v k, RocksDB.Put k v]
        Just bs -> do
            let v = fromRight err (decode bs)
                t = max (now + r) (getPeerNextConnect v)
                v' = encode (PeerTimeAddress t p)
            when (t == now + r) $ do
                $(logWarn) $ logMe <> "Backing off peer " <> logShow sa
                RocksDB.write
                    db
                    def
                    [RocksDB.Del bs, RocksDB.Put k v', RocksDB.Put v' k]
  where
    err = error "Could not decode PeerTimeAddress from database"

getNewPeer :: MonadManager m => m (Maybe SockAddr)
getNewPeer = do
    ManagerConfig {..} <- asks myConfig
    onlinePeers <- map onlinePeerAddress <$> getOnlinePeers
    configPeers <- concat <$> mapM toSockAddr mgrConfPeers
    if mgrConfNoNewPeers
        then return $ find (not . (`elem` onlinePeers)) configPeers
        else do
            $(logDebug) $ logMe <> "Attempting to get a new peer from database"
            pdb <- asks myPeerDB
            now <- computeTime
            RocksDB.withIterator pdb def $ \it -> do
                RocksDB.iterSeek it (BS.singleton 0x00)
                runMaybeT $ go now it onlinePeers
  where
    go now it onlinePeers = do
        guard =<< RocksDB.iterValid it
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
        $(logDebug) $ logMe <> "Awaiting message"
        msg <- receive mgr
        processManagerMessage msg

processManagerMessage :: MonadManager m => ManagerMessage -> m ()

processManagerMessage (ManagerSetFilter bf) = do
    $(logDebug) $ logMe <> "Setting Bloom filter"
    setFilter bf

processManagerMessage (ManagerSetBest bb) = do
    $(logDebug) $
        logMe <> "Setting my best block to height " <> logShow (nodeHeight bb)
    bbb <- asks myBestBlock
    liftIO . atomically $ writeTVar bbb bb

processManagerMessage ManagerPing = do
    $(logDebug) $ logMe <> "Attempting to connect to new peers"
    connectNewPeers

processManagerMessage (ManagerGetAddr p) = do
    pn <- peerString p
    $(logDebug) $ logMe <> "Ignoring address request from peer " <> cs pn

processManagerMessage (ManagerNewPeers p as) =
    void . runMaybeT $ do
        ManagerConfig {..} <- asks myConfig
        guard (not mgrConfNoNewPeers)
        pn <- peerString p
        $(logDebug) $
            logMe <> "Received " <> logShow (length as) <> " new peers from " <>
            cs pn
        forM_ as $ \(_, na) ->
            let sa = naAddress na
            in storePeer sa

processManagerMessage (ManagerKill e p) =
    void . runMaybeT $ do
        op <- MaybeT $ findPeer p
        $(logError) $ logMe <> "Killing peer " <> logShow (onlinePeerAddress op)
        banPeer $ onlinePeerAddress op
        onlinePeerAsync op `cancelWith` e

processManagerMessage (ManagerSetPeerBest p bn) = do
    m <- findPeer p
    case m of
        Nothing -> return ()
        Just op ->
            $(logDebug) $
            logMe <> "Setting best block " <> logShow (nodeHeight bn) <>
            " for peer " <>
            logShow (onlinePeerAddress op)
    modifyPeer f p
  where
    f op = op {onlinePeerBestBlock = bn}

processManagerMessage (ManagerGetPeerBest p reply) = do
    op <- findPeer p
    let bn = fmap onlinePeerBestBlock op
    case (op, bn) of
        (Just o, Just b) ->
            $(logDebug) $
            logMe <> "Requested peer " <> logShow (onlinePeerAddress o) <>
            " best block at height " <>
            logShow (nodeHeight b)
        _ -> $(logWarn) $ logMe <> "Requested best block for unknown peer"
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
        pn <- peerString p
        case bf of
            Nothing -> return ()
            Just b -> do
                $(logDebug) $ logMe <> "Sending bloom filter to peer " <> cs pn
                b `peerSetFilter` p
    askForPeers = do
        pn <- peerString p
        mgrConfNoNewPeers <$> asks myConfig >>= \io ->
            unless io $ do
                $(logDebug) $ logMe <> "Asking for new peers to peer " <> cs pn
                MGetAddr `sendMessage` p
    announcePeer =
        void . runMaybeT $ do
            op <- MaybeT $ findPeer p
            guard (not (onlinePeerConnected op))
            $(logInfo) $
                logMe <> "Connected peer " <> logShow (onlinePeerAddress op)
            l <- mgrConfMgrListener <$> asks myConfig
            liftIO . atomically . l $ ManagerConnect p
            ch <- asks myChain
            chainNewPeer p ch
            setPeerAnnounced p

processManagerMessage (ManagerGetPeerVersion p reply) = do
    pn <- peerString p
    $(logDebug) $ logMe <> "Getting version from peer " <> cs pn
    v <- fmap onlinePeerVersion <$> findPeer p
    liftIO . atomically $ reply v

processManagerMessage (ManagerGetPeers reply) = do
    $(logDebug) $ logMe <> "Peer list requested"
    getPeers >>= liftIO . atomically . reply

processManagerMessage (ManagerPeerPing p i) = do
    pn <- peerString p
    $(logDebug) $ logMe <> "Got time measurement from peer " <> cs pn
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
        $(logDebug) $
            logMe <> "Notifying listeners of disconnected peer " <>
            logShow (onlinePeerAddress op)
        asks myChain >>= chainRemovePeer p
        l <- mgrConfMgrListener <$> asks myConfig
        liftIO . atomically . l $ ManagerDisconnect p
    | otherwise =
        $(logDebug) $
        logMe <> "Disconnected unannounced peer " <>
        logShow (onlinePeerAddress op)

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
            $(logDebug) $ logMe <> "Not connected to any peer"
            ps' <- resolvePeers
            $(logDebug) $
                logMe <> "Resolved " <> logShow (length ps') <> " peers"
            mapM_ storePeer ps'
        _ ->
            $(logDebug) $
            logMe <> "Connected to " <> logShow (length ps) <> "/" <> logShow mo <>
            " peers"
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
    $(logDebug) $ logMe <> "Loading bloom filter"
    bfb <- asks myBloomFilter
    liftIO . atomically . writeTVar bfb $ Just bl
    ops <- getOnlinePeers
    forM_ ops $ \op ->
        when (onlinePeerConnected op) $
        if acceptsFilters $ onlinePeerServices op
            then do
                $(logDebug) $
                    logMe <> "Asking peer " <> logShow (onlinePeerAddress op) <>
                    "to load Bloom filter"
                bl `peerSetFilter` onlinePeerMailbox op
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
