{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
module Network.Haskoin.Node.Common where

import           Control.Concurrent.Async.Lifted.Safe
import           Control.Concurrent.NQE
import           Control.Concurrent.Unique
import           Control.Exception.Lifted
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Control
import           Control.Monad.Trans.Maybe
import           Data.Hashable
import           Data.Maybe
import           Data.String.Conversions
import           Data.Text                            (Text)
import           Data.Time.Clock
import           Data.Time.Clock.POSIX
import           Data.Word
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Network
import           Network.Haskoin.Transaction
import           Network.Socket                       (AddrInfo (..),
                                                       AddrInfoFlag (..),
                                                       Family (..),
                                                       NameInfoFlag (..),
                                                       SockAddr (..),
                                                       SocketType (..),
                                                       addrAddress,
                                                       defaultHints,
                                                       getAddrInfo, getNameInfo)
import           Text.Read

type HostPort = (Host, Port)
type Host = String
type Port = Int

data UniqueInbox a = UniqueInbox
    { uniqueInbox :: Inbox a
    , uniqueId    :: Unique
    }

type PeerSupervisor = Inbox SupervisorMessage
type NodeSupervisor = Inbox SupervisorMessage

type Peer = UniqueInbox PeerMessage
type Chain = Inbox ChainMessage
type Manager = Inbox ManagerMessage

instance Eq (UniqueInbox a) where
    UniqueInbox {uniqueId = a} == UniqueInbox {uniqueId = b} = a == b

instance Hashable (UniqueInbox a) where
    hashWithSalt n UniqueInbox {uniqueId = i} = hashWithSalt n i
    hash UniqueInbox {uniqueId = i} = hash i

instance Mailbox UniqueInbox where
    mailboxEmptySTM UniqueInbox {uniqueInbox = mbox} = mailboxEmptySTM mbox
    sendSTM msg UniqueInbox {uniqueInbox = mbox} = msg `sendSTM` mbox
    receiveSTM UniqueInbox {uniqueInbox = mbox} = receiveSTM mbox
    requeueMsg msg UniqueInbox {uniqueInbox = mbox} = msg `requeueMsg` mbox

data NodeConfig = NodeConfig
    { maxPeers       :: !Int
    , directory      :: !FilePath
    , initPeers      :: ![HostPort]
    , noNewPeers     :: !Bool
    , nodeEvents     :: !(Listen NodeEvent)
    , netAddress     :: !NetworkAddress
    , nodeSupervisor :: !(Inbox SupervisorMessage)
    , nodeChain      :: !Chain
    , nodeManager    :: !Manager
    }

data ManagerConfig = ManagerConfig
    { mgrConfMaxPeers       :: !Int
    , mgrConfDir            :: !FilePath
    , mgrConfPeers          :: ![HostPort]
    , mgrConfNoNewPeers     :: !Bool
    , mgrConfMgrListener    :: !(Listen ManagerEvent)
    , mgrConfPeerListener   :: !(Listen PeerEvent)
    , mgrConfNetAddr        :: !NetworkAddress
    , mgrConfManager        :: !Manager
    , mgrConfChain          :: !Chain
    , mgrConfPeerSupervisor :: !PeerSupervisor
    }

data NodeEvent
    = ManagerEvent !ManagerEvent
    | ChainEvent !ChainEvent
    | PeerEvent !PeerEvent

data ManagerEvent
    = ManagerConnect !Peer
    | ManagerAvailable !Peer
    | ManagerDisconnect !Peer

data ManagerMessage
    = ManagerSetFilter !BloomFilter
    | ManagerSetBest !BlockNode
    | ManagerPing
    | ManagerGetAddr !Peer
    | ManagerNewPeers !Peer
                      ![NetworkAddressTime]
    | ManagerKill !PeerException
                  !Peer
    | ManagerSetPeerBest !Peer
                         !BlockNode
    | ManagerGetPeerBest !Peer
                         !(Reply (Maybe BlockNode))
    | ManagerSetPeerVersion !Peer
                            !Version
    | ManagerGetPeerVersion !Peer
                            !(Reply (Maybe Word32))
    | ManagerGetChain !(Reply Chain)
    | ManagerGetAllPeers !(Reply [Peer])
    | ManagerGetPeers !Bool
                      !Bool
                      !(Reply [Peer])
    | ManagerPeerPing !Peer
                      !NominalDiffTime
    | ManagerTakePeer !Peer
                      !(Reply Bool)
    | ManagerFreePeer !Peer
    | PeerStopped !(Async (), Either SomeException ())

data ChainConfig = ChainConfig
    { chainConfDbFile   :: !FilePath
    , chainConfListener :: !(Listen ChainEvent)
    , chainConfManager  :: !Manager
    , chainConfChain    :: !Chain
    }

data ChainMessage
    = ChainNewHeaders !Peer
                      ![BlockHeaderCount]
    | ChainNewPeer !Peer
    | ChainRemovePeer !Peer
    | ChainGetBest !(BlockNode -> STM ())
    | ChainGetAncestor !BlockHeight
                       !BlockNode
                       !(Reply (Maybe BlockNode))
    | ChainGetSplit !BlockNode
                    !BlockNode
                    !(Reply BlockNode)
    | ChainGetBlock !BlockHash
                    !(Reply (Maybe BlockNode))
    | ChainSendHeaders !Peer
    | ChainFreePeer !Peer
    | ChainIsSynced !(Reply Bool)

data ChainEvent
    = ChainNewBest !BlockNode
    | ChainSynced !BlockNode
    | ChainNotSynced !BlockNode
    deriving (Eq, Show)

data PeerConfig = PeerConfig
    { peerConfConnect  :: !NetworkAddress
    , peerConfInitBest :: !BlockNode
    , peerConfLocal    :: !NetworkAddress
    , peerConfManager  :: !Manager
    , peerConfChain    :: !Chain
    , peerConfListener :: !(Listen PeerEvent)
    , peerConfNonce    :: !Word64
    }

data PeerException
    = PeerMisbehaving !String
    | DecodeMessageError !String
    | CannotDecodePayload !String
    | MessageHeaderEmpty
    | PeerIsMyself
    | PayloadTooLarge !Word32
    | PeerAddressInvalid
    | BloomFiltersNotSupported
    | PeerSentBadHeaders
    | NotNetworkPeer
    | PeerTimeout
    deriving (Eq, Show)

instance Exception PeerException

data PeerEvent
    = ReceivedInvTxs !Peer
                     ![TxHash]
    | ReceivedBlock !Peer
                    !Block
    | ReceivedMerkleBlock !Peer
                          !MerkleBlock
    | ReceivedTx !Peer
                 !Tx
    | ReceivedGetBlocks !Peer
                        !GetBlocks
    | ReceivedGetHeaders !Peer
                         !GetHeaders
    | ReceivedNotFound !Peer
                       ![InvVector]
    | ReceivedGetData !Peer
                      ![InvVector]
    | ReceivedMempool !Peer
    | ReceivedReject !Peer
                     !Reject

data PeerMessage
    = PeerOutgoing !Message
    | PeerIncoming !Message

logShow :: Show a => a -> Text
logShow x = cs (show x)

toSockAddr :: (MonadBaseControl IO m, MonadIO m) => HostPort -> m [SockAddr]
toSockAddr (host, port) = go `catch` e
  where
    go =
        fmap (map addrAddress) . liftIO $
        getAddrInfo
            (Just
                 defaultHints
                 { addrFlags = [AI_ADDRCONFIG]
                 , addrSocketType = Stream
                 , addrFamily = AF_INET
                 })
            (Just host)
            (Just (show port))
    e :: Monad m => SomeException -> m [SockAddr]
    e _ = return []

fromSockAddr ::
       (MonadBaseControl IO m, MonadIO m) => SockAddr -> m (Maybe HostPort)
fromSockAddr sa = go `catch` e
  where
    go = do
        (hostM, portM) <- liftIO $ getNameInfo flags True True sa
        return $ (,) <$> hostM <*> (readMaybe =<< portM)
    flags = [NI_NUMERICHOST, NI_NUMERICSERV]
    e :: Monad m => SomeException -> m (Maybe a)
    e _ = return Nothing

computeTime :: MonadIO m => m Word32
computeTime = round <$> liftIO getPOSIXTime

myVersion :: Word32
myVersion = 70012

managerSetBest :: MonadIO m => BlockNode -> Manager -> m ()
managerSetBest bn mgr = ManagerSetBest bn `send` mgr

managerSetPeerVersion :: MonadIO m => Peer -> Version -> Manager -> m ()
managerSetPeerVersion p v mgr = ManagerSetPeerVersion p v `send` mgr

managerGetPeerVersion :: MonadIO m => Peer -> Manager -> m (Maybe Word32)
managerGetPeerVersion p mgr = ManagerGetPeerVersion p `query` mgr

managerGetPeerBest :: MonadIO m => Peer -> Manager -> m (Maybe BlockNode)
managerGetPeerBest p mgr = ManagerGetPeerBest p `query` mgr

managerSetPeerBest :: MonadIO m => Peer -> BlockNode -> Manager -> m ()
managerSetPeerBest p bn mgr = ManagerSetPeerBest p bn `send` mgr

managerGetPeers ::
       MonadIO m
    => Bool -- ^ only at height
    -> Bool -- ^ only not busy
    -> Manager
    -> m [Peer]
managerGetPeers th tb mgr = ManagerGetPeers th tb `query` mgr

managerGetAllPeers :: MonadIO m => Manager -> m [Peer]
managerGetAllPeers mgr = ManagerGetAllPeers `query` mgr

managerGetChain :: MonadIO m => Manager -> m Chain
managerGetChain mgr = ManagerGetChain `query` mgr

managerGetAddr :: MonadIO m => Peer -> Manager -> m ()
managerGetAddr p mgr = ManagerGetAddr p `send` mgr

managerTakePeer :: MonadIO m => Peer -> Manager -> m Bool
managerTakePeer p mgr = ManagerTakePeer p `query` mgr

managerFreePeer :: MonadIO m => Peer -> Manager -> m ()
managerFreePeer p mgr = ManagerFreePeer p `send` mgr

managerTakeAny ::
       (MonadIO m)
    => Bool -- ^ only at height
    -> Manager
    -> m (Maybe Peer)
managerTakeAny th mgr = go =<< managerGetPeers th True mgr
  where
    go [] = return Nothing
    go (p:ps) =
        managerTakePeer p mgr >>= \x ->
            if x
                then return $ Just p
                else go ps

managerKill :: MonadIO m => PeerException -> Peer -> Manager -> m ()
managerKill e p mgr = ManagerKill e p `send` mgr

managerNewPeers ::
       MonadIO m => Peer -> [NetworkAddressTime] -> Manager -> m ()
managerNewPeers p as mgr = ManagerNewPeers p as `send` mgr

setManagerFilter :: MonadIO m => BloomFilter -> Manager -> m ()
setManagerFilter bf mgr = ManagerSetFilter bf `send` mgr

sendMessage :: MonadIO m => Message -> Peer -> m ()
sendMessage msg p = PeerOutgoing msg `send` p

peerSetFilter :: MonadIO m => BloomFilter -> Peer -> m ()
peerSetFilter f p = MFilterLoad (FilterLoad f) `sendMessage` p

withPeer ::
       (MonadIO m, MonadBaseControl IO m)
    => Peer
    -> Manager
    -> (Peer -> m a)
    -> m (Maybe a)
withPeer p mgr f =
    bracket (managerTakePeer p mgr) g $ \k ->
        if k
            then Just <$> f p
            else return Nothing
  where
    g k = when k $ managerFreePeer p mgr

withAnyPeer ::
       (MonadIO m, MonadBaseControl IO m)
    => Manager
    -> (Peer -> m a)
    -> m (Maybe a)
withAnyPeer mgr f =
    bracket
        (managerTakeAny False mgr)
        (maybe (return ()) (`managerFreePeer` mgr))
        (maybe (return Nothing) (fmap Just . f))

getMerkleBlocks ::
       (MonadIO m)
    => Peer
    -> [BlockHash]
    -> m ()
getMerkleBlocks p bhs = PeerOutgoing (MGetData (GetData ivs)) `send` p
  where
    ivs = map (InvVector InvMerkleBlock . getBlockHash) bhs

getBlocks ::
       MonadIO m => Peer -> [BlockHash] -> m ()
getBlocks p bhs = PeerOutgoing (MGetData (GetData ivs)) `send` p
  where
    ivs = map (InvVector InvBlock . getBlockHash) bhs

getTxs ::
       MonadIO m
    => Peer
    -> [TxHash]
    -> m ()
getTxs p ths = PeerOutgoing (MGetData (GetData ivs)) `send` p
  where
    ivs = map (InvVector InvTx . getTxHash) ths

buildVersion ::
       MonadIO m
    => Word64
    -> BlockHeight
    -> NetworkAddress
    -> NetworkAddress
    -> m Version
buildVersion nonce height loc rmt = do
    time <- fromIntegral <$> computeTime
    return
        Version
        { version = myVersion
        , services = naServices loc
        , timestamp = time
        , addrRecv = rmt
        , addrSend = loc
        , verNonce = nonce
        , userAgent = VarString haskoinUserAgent
        , startHeight = height
        , relay = False
        }

chainNewPeer :: MonadIO m => Peer -> Chain -> m ()
chainNewPeer p ch = ChainNewPeer p `send` ch

chainFreePeer :: MonadIO m => Peer -> Chain -> m ()
chainFreePeer p ch = ChainFreePeer p `send` ch

chainRemovePeer :: MonadIO m => Peer -> Chain -> m ()
chainRemovePeer p ch = ChainRemovePeer p `send` ch

chainGetBlock :: MonadIO m => BlockHash -> Chain -> m (Maybe BlockNode)
chainGetBlock bh ch = ChainGetBlock bh `query` ch

chainGetBest :: MonadIO m => Chain -> m BlockNode
chainGetBest ch = ChainGetBest `query` ch

chainGetAncestor ::
       MonadIO m => BlockHeight -> BlockNode -> Chain -> m (Maybe BlockNode)
chainGetAncestor h n c = ChainGetAncestor h n `query` c

chainGetParents ::
       MonadIO m => BlockHeight -> BlockNode -> Chain -> m [BlockNode]
chainGetParents height top ch = go [] top
  where
    go acc b
        | height >= nodeHeight b = return acc
        | otherwise = do
            m <- chainGetBlock (prevBlock $ nodeHeader b) ch
            case m of
                Nothing -> return acc
                Just p  -> go (p : acc) p

chainGetSplitBlock ::
       MonadIO m => BlockNode -> BlockNode -> Chain -> m BlockNode
chainGetSplitBlock l r c = ChainGetSplit l r `query` c

chainBlockMain :: MonadIO m => BlockHash -> Chain -> m Bool
chainBlockMain bh ch =
    fmap (fromMaybe False) $
    runMaybeT $ do
        bb <- chainGetBest ch
        bn <- MaybeT $ bh `chainGetBlock` ch
        ba <- MaybeT $ chainGetAncestor (nodeHeight bn) bb ch
        return $ bn == ba

chainIsSynced :: MonadIO m => Chain -> m Bool
chainIsSynced ch = ChainIsSynced `query` ch
