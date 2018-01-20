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
import           Data.ByteString             (ByteString)
import qualified Data.ByteString             as BS
import           Data.Default
import           Data.Function
import           Data.List
import           Data.Maybe
import           Data.Serialize              (Get, Put, Serialize, decode,
                                              encode, get, put)
import qualified Data.Serialize              as S
import           Data.String.Conversions
import           Data.Text                   (Text)
import           Data.Time.Clock
import           Data.Word
import           Database.LevelDB            (DB, MonadResource, runResourceT)
import qualified Database.LevelDB            as LevelDB
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Network
import           Network.Haskoin.Node.Common
import           Network.Haskoin.Node.Peer
import           Network.Socket              (SockAddr (..))
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
    { getPeerTime        :: !Word32
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
        S.put (getPeerTime pta)
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
            let opts = def {LevelDB.createIfMissing = True}
            pdb <- LevelDB.open (mgrConfDir cfg </> "peers") opts
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

storePeer :: MonadManager m => Word32 -> SockAddr -> m ()
storePeer t sa = do
    pdb <- asks myPeerDB
    let p = PeerAddress sa
        k = encode p
        v = encode $ PeerTimeAddress t p
    m <- LevelDB.get pdb def k
    case m of
        Nothing -> LevelDB.write pdb def [LevelDB.Put v k, LevelDB.Put k v]
        Just x ->
            LevelDB.write
                pdb
                def
                [LevelDB.Del x, LevelDB.Put v k, LevelDB.Put k v]

deletePeer :: MonadManager m => SockAddr -> m ()
deletePeer sa = do
    $(logDebug) $ logMe <> "Deleting peer address " <> logShow sa
    pdb <- asks myPeerDB
    let p = PeerAddress sa
        k = encode p
    m <- LevelDB.get pdb def k
    case m of
        Nothing -> return ()
        Just v ->
            LevelDB.write
                pdb
                def
                [LevelDB.Del k, LevelDB.Del v]

getNewPeer :: MonadManager m => m (Maybe SockAddr)
getNewPeer = do
    ManagerConfig {..} <- asks myConfig
    ops <- map onlinePeerAddress <$> getOnlinePeers
    cps <- concat <$> mapM toSockAddr mgrConfPeers
    if mgrConfNoNewPeers
        then return $ find (not . (`elem` ops)) cps
        else do
            $(logDebug) $ logMe <> "Attempting to get a new peer from database"
            pdb <- asks myPeerDB
            LevelDB.withIterator pdb def $ \i -> do
                LevelDB.iterSeek i (BS.singleton 0x01)
                LevelDB.iterPrev i
                runMaybeT $ go i ops
  where
    go i ops = do
        valid <- LevelDB.iterValid i
        guard valid
        val <- MaybeT $ LevelDB.iterValue i
        e <- MaybeT . return . either (const Nothing) Just $ decode val
        let a = getPeerAddress e
        if a `elem` ops
            then do
                LevelDB.iterPrev i
                go i ops
            else return a

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
            i <- liftIO $ randomRIO (30 * 1000 * 1000, 90 * 1000 * 1000)
            threadDelay i

managerLoop :: (MonadManager m, MonadMask m) => m ()
managerLoop =
    forever $ do
        mgr <- asks mySelf
        $(logDebug) $ logMe <> "Awaiting message"
        msg <- receive mgr
        processManagerMessage msg

processManagerMessage :: MonadManager m => ManagerMessage -> m ()

processManagerMessage (ManagerSetFilter bf) = do
    $(logDebug) $ logMe <> "Set Bloom filter"
    setFilter bf

processManagerMessage (ManagerSetBest bb) = do
    $(logDebug) $
        logMe <> "Setting best block to height " <> logShow (nodeHeight bb)
    bbb <- asks myBestBlock
    liftIO . atomically $ writeTVar bbb bb

processManagerMessage ManagerPing = do
    $(logDebug) $ logMe <> "Attempting to connect to new peers"
    connectNewPeers

processManagerMessage (ManagerGetAddr _) =
    $(logDebug) $ logMe <> "Ignoring peer address request from peer"

processManagerMessage (ManagerNewPeers p as) =
    void . runMaybeT $ do
        ManagerConfig {..} <- asks myConfig
        guard (not mgrConfNoNewPeers)
        $(logDebug) $ logMe <> "Processing received addresses"
        pn <- peerString p
        $(logDebug) $
            logMe <> "Received " <> logShow (length as) <> " new peers from " <>
            cs pn
        cur <- computeTime
        forM_ as $ \(t, na) ->
            let sa = naAddress na
                t' = res cur t
            in storePeer t' sa
  where
    res cur t =
        if t > cur
            then cur
            else t

processManagerMessage (ManagerKill e p) =
    void . runMaybeT $ do
        $(logError) $ logMe <> "Killing a peer"
        op <- MaybeT $ findPeer p
        deletePeer $ onlinePeerAddress op
        onlinePeerAsync op `cancelWith` e

processManagerMessage (ManagerSetPeerBest p bn) = do
    $(logDebug) $ logMe <> "Setting peer best block"
    modifyPeer f p
  where
    f op = op {onlinePeerBestBlock = bn}

processManagerMessage (ManagerGetPeerBest p reply) = do
    $(logDebug) $ logMe <> "Request for peer best block"
    bn <- fmap onlinePeerBestBlock <$> findPeer p
    liftIO . atomically $ reply bn

processManagerMessage (ManagerSetPeerVersion p v) =
    void . runMaybeT $ do
        modifyPeer f p
        op <- MaybeT $ findPeer p
        runExceptT testVersion >>= \case
            Left ex -> do
                deletePeer $ onlinePeerAddress op
                onlinePeerAsync op `cancelWith` ex
            Right () -> do
                computeTime >>= (`storePeer` onlinePeerAddress op)
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
        case bf of
            Nothing -> return ()
            Just b -> do
                $(logDebug) $ logMe <> "Sending bloom filter"
                b `peerSetFilter` p
    askForPeers =
        mgrConfNoNewPeers <$> asks myConfig >>= \io ->
            unless io $ do
                $(logDebug) $ logMe <> "Asking for peers"
                MGetAddr `sendMessage` p
    announcePeer =
        void . runMaybeT $ do
            op <- MaybeT $ findPeer p
            guard $ not $ onlinePeerConnected op
            $(logDebug) $ logMe <> "Announcing peer"
            l <- mgrConfMgrListener <$> asks myConfig
            liftIO . atomically . l $ ManagerConnect p
            ch <- asks myChain
            chainNewPeer p ch
            setPeerAnnounced p

processManagerMessage (ManagerGetPeerVersion p reply) = do
    $(logDebug) $ logMe <> "Getting peer version"
    v <- fmap onlinePeerVersion <$> findPeer p
    liftIO . atomically $ reply v

processManagerMessage (ManagerGetChain reply) = do
    $(logDebug) $ logMe <> "Providing chain"
    asks myChain >>= liftIO . atomically . reply

processManagerMessage (ManagerGetPeers reply) = do
    $(logDebug) $ logMe <> "Providing up-to-date peers"
    getPeers >>= liftIO . atomically . reply

processManagerMessage (ManagerPeerPing p i) = do
    $(logDebug) $ logMe <> "Got ping time measurement from peer"
    modifyPeer (\x -> x {onlinePeerPings = take 11 $ i : onlinePeerPings x}) p

processManagerMessage (PeerStopped (p, _ex)) = do
    opb <- asks onlinePeers
    m <- liftIO . atomically $ do
        m <- findPeerAsync p opb
        when (isJust m) $ removePeer p opb
        return m
    case m of
        Just op -> processPeerOffline op
        Nothing -> return ()

processPeerOffline :: MonadManager m => OnlinePeer -> m ()
processPeerOffline op
    | onlinePeerConnected op = do
        let p = onlinePeerMailbox op
        $(logWarn) $
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
            getNewPeer >>= \m ->
                when (isNothing m) $ do
                    ps' <- resolvePeers
                    $(logDebug) $
                        logMe <> "Resolved " <> logShow (length ps') <> " peers"
                    mapM_ (storePeer 0) ps'
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
        $(logDebug) $ logMe <> "Connecting to a peer"
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
                $(logDebug) $ logMe <> "Asking peer to load Bloom filter"
                bl `peerSetFilter` onlinePeerMailbox op
            else do
                $(logError) $ logMe <> "Peer does not support bloom filters"
                deletePeer (onlinePeerAddress op)
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
