{-# LANGUAGE FlexibleContexts #-}

module Haskoin.Store.Manager
  ( StoreConfig (..),
    Store (..),
    withStore,
  )
where

import Control.Monad (forever, unless, when)
import Control.Monad.Logger (MonadLoggerIO)
import Control.Monad.Reader (ReaderT (ReaderT), runReaderT)
import Data.Serialize (decode)
import Data.Time.Clock (NominalDiffTime)
import Data.Word (Word32)
import Haskoin
  ( BlockHash (..),
    Inv (..),
    InvType (..),
    InvVector (..),
    Message (..),
    MessageCommand (..),
    Network,
    NetworkAddress (..),
    NotFound (..),
    Pong (..),
    Reject (..),
    TxHash (..),
    VarString (..),
    sockToHostAddress,
  )
import Haskoin.Node
  ( Chain,
    ChainEvent (..),
    HostPort,
    Node (..),
    NodeConfig (..),
    NodeEvent (..),
    PeerEvent (..),
    PeerManager,
    WithConnection,
    withNode,
  )
import Haskoin.Store.BlockStore
  ( BlockStore,
    BlockStoreConfig (..),
    blockStoreBlockSTM,
    blockStoreHeadSTM,
    blockStoreNotFoundSTM,
    blockStorePeerConnectSTM,
    blockStorePeerDisconnectSTM,
    blockStoreTxHashSTM,
    blockStoreTxSTM,
    withBlockStore,
  )
import Haskoin.Store.Cache
  ( CacheConfig (..),
    CacheWriter,
    cacheNewBlock,
    cacheNewTx,
    cacheWriter,
    connectRedis,
    newCacheMetrics,
  )
import Haskoin.Store.Common
  ( StoreEvent (..),
    createDataMetrics,
  )
import Haskoin.Store.Database.Reader
  ( DatabaseReader (..),
    DatabaseReaderT,
    withDatabaseReader,
  )
import NQE
  ( Inbox,
    Process (..),
    Publisher,
    publishSTM,
    receive,
    withProcess,
    withPublisher,
    withSubscription,
  )
import Network.Socket (SockAddr (..))
import qualified System.Metrics as Metrics (Store)
import UnliftIO
  ( MonadIO,
    MonadUnliftIO,
    STM,
    atomically,
    link,
    withAsync,
  )
import UnliftIO.Concurrent (threadDelay)

-- | Store mailboxes.
data Store = Store
  { storeManager :: !PeerManager,
    storeChain :: !Chain,
    storeBlock :: !BlockStore,
    storeDB :: !DatabaseReader,
    storeCache :: !(Maybe CacheConfig),
    storePublisher :: !(Publisher StoreEvent),
    storeNetwork :: !Network
  }

-- | Configuration for a 'Store'.
data StoreConfig = StoreConfig
  { -- | max peers to connect to
    storeConfMaxPeers :: !Int,
    -- | static set of peers to connect to
    storeConfInitPeers :: ![HostPort],
    -- | discover new peers
    storeConfDiscover :: !Bool,
    -- | RocksDB database path
    storeConfDB :: !FilePath,
    -- | network constants
    storeConfNetwork :: !Network,
    -- | Redis cache configuration
    storeConfCache :: !(Maybe String),
    -- | gap on extended public key with no transactions
    storeConfInitialGap :: !Word32,
    -- | gap for extended public keys
    storeConfGap :: !Word32,
    -- | cache xpubs with more than this many used addresses
    storeConfCacheMin :: !Int,
    -- | maximum number of keys in Redis cache
    storeConfMaxKeys :: !Integer,
    -- | do not index new mempool transactions
    storeConfNoMempool :: !Bool,
    -- | wipe mempool when starting
    storeConfWipeMempool :: !Bool,
    -- | sync mempool from peers
    storeConfSyncMempool :: !Bool,
    -- | disconnect peer if message not received for this many seconds
    storeConfPeerTimeout :: !NominalDiffTime,
    -- | disconnect peer if it has been connected this long
    storeConfPeerMaxLife :: !NominalDiffTime,
    -- | connect to peers using the function 'withConnection'
    storeConfConnect :: !(SockAddr -> WithConnection),
    -- | delay in microseconds to retry getting cache lock
    storeConfCacheRetryDelay :: !Int,
    -- | stats store
    storeConfStats :: !(Maybe Metrics.Store)
  }

withStore ::
  (MonadLoggerIO m, MonadUnliftIO m) =>
  StoreConfig ->
  (Store -> m a) ->
  m a
withStore cfg action =
  connectDB cfg $
    ReaderT $ \db ->
      withPublisher $ \pub ->
        withPublisher $ \node_pub ->
          withSubscription node_pub $ \node_sub ->
            withNode (nodeCfg cfg db node_pub) $ \node ->
              withCache cfg (nodeChain node) db pub $ \mcache ->
                withBlockStore (blockStoreCfg cfg node pub db) $ \b ->
                  withAsync (nodeForwarder b pub node_sub) $ \a1 ->
                    link a1
                      >> action
                        Store
                          { storeManager = nodeManager node,
                            storeChain = nodeChain node,
                            storeBlock = b,
                            storeDB = db,
                            storeCache = mcache,
                            storePublisher = pub,
                            storeNetwork = storeConfNetwork cfg
                          }

connectDB :: MonadUnliftIO m => StoreConfig -> DatabaseReaderT m a -> m a
connectDB cfg f = do
  stats <- mapM createDataMetrics (storeConfStats cfg)
  withDatabaseReader
    (storeConfNetwork cfg)
    (storeConfInitialGap cfg)
    (storeConfGap cfg)
    (storeConfDB cfg)
    stats
    f

blockStoreCfg ::
  StoreConfig ->
  Node ->
  Publisher StoreEvent ->
  DatabaseReader ->
  BlockStoreConfig
blockStoreCfg cfg node pub db =
  BlockStoreConfig
    { blockConfChain = nodeChain node,
      blockConfManager = nodeManager node,
      blockConfListener = pub,
      blockConfDB = db,
      blockConfNet = storeConfNetwork cfg,
      blockConfNoMempool = storeConfNoMempool cfg,
      blockConfWipeMempool = storeConfWipeMempool cfg,
      blockConfSyncMempool = storeConfSyncMempool cfg,
      blockConfPeerTimeout = storeConfPeerTimeout cfg,
      blockConfStats = storeConfStats cfg
    }

nodeCfg ::
  StoreConfig ->
  DatabaseReader ->
  Publisher NodeEvent ->
  NodeConfig
nodeCfg cfg db pub =
  NodeConfig
    { nodeConfMaxPeers = storeConfMaxPeers cfg,
      nodeConfDB = databaseHandle db,
      nodeConfColumnFamily = Nothing,
      nodeConfPeers = storeConfInitPeers cfg,
      nodeConfDiscover = storeConfDiscover cfg,
      nodeConfEvents = pub,
      nodeConfNetAddr =
        NetworkAddress
          0
          (sockToHostAddress (SockAddrInet 0 0)),
      nodeConfNet = storeConfNetwork cfg,
      nodeConfTimeout = storeConfPeerTimeout cfg,
      nodeConfPeerMaxLife = storeConfPeerMaxLife cfg,
      nodeConfConnect = storeConfConnect cfg
    }

withCache ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  StoreConfig ->
  Chain ->
  DatabaseReader ->
  Publisher StoreEvent ->
  (Maybe CacheConfig -> m a) ->
  m a
withCache cfg chain db pub action =
  case storeConfCache cfg of
    Nothing ->
      action Nothing
    Just redisurl ->
      mapM newCacheMetrics (storeConfStats cfg) >>= \metrics ->
        connectRedis redisurl >>= \conn ->
          withSubscription pub $ \evts ->
            let conf = c conn metrics
             in withProcess (f conf) $ \p ->
                  cacheWriterProcesses evts (getProcessMailbox p) $ do
                    action (Just conf)
  where
    f conf cwinbox = runReaderT (cacheWriter conf cwinbox) db
    c conn metrics =
      CacheConfig
        { cacheConn = conn,
          cacheMin = storeConfCacheMin cfg,
          cacheChain = chain,
          cacheMax = storeConfMaxKeys cfg,
          cacheRetryDelay = storeConfCacheRetryDelay cfg,
          cacheMetrics = metrics
        }

cacheWriterProcesses ::
  MonadUnliftIO m =>
  Inbox StoreEvent ->
  CacheWriter ->
  m a ->
  m a
cacheWriterProcesses evts cwm action =
  withAsync events $ \a1 -> link a1 >> action
  where
    events = cacheWriterEvents evts cwm

cacheWriterEvents :: MonadIO m => Inbox StoreEvent -> CacheWriter -> m ()
cacheWriterEvents evts cwm =
  forever $
    receive evts >>= \e ->
      e `cacheWriterDispatch` cwm

cacheWriterDispatch :: MonadIO m => StoreEvent -> CacheWriter -> m ()
cacheWriterDispatch (StoreBestBlock _) = cacheNewBlock
cacheWriterDispatch (StoreMempoolNew t) = cacheNewTx t
cacheWriterDispatch (StoreMempoolDelete t) = cacheNewTx t
cacheWriterDispatch _ = const (return ())

nodeForwarder ::
  MonadIO m =>
  BlockStore ->
  Publisher StoreEvent ->
  Inbox NodeEvent ->
  m ()
nodeForwarder b pub sub =
  forever $ receive sub >>= atomically . storeDispatch b pub

-- | Dispatcher of node events.
storeDispatch ::
  BlockStore ->
  Publisher StoreEvent ->
  NodeEvent ->
  STM ()
storeDispatch b pub (PeerEvent (PeerConnected p)) = do
  publishSTM (StorePeerConnected p) pub
  blockStorePeerConnectSTM p b
storeDispatch b pub (PeerEvent (PeerDisconnected p)) = do
  publishSTM (StorePeerDisconnected p) pub
  blockStorePeerDisconnectSTM p b
storeDispatch b _ (ChainEvent (ChainBestBlock bn)) =
  blockStoreHeadSTM bn b
storeDispatch _ _ (ChainEvent _) =
  return ()
storeDispatch _ pub (PeerMessage p (MPong (Pong n))) =
  publishSTM (StorePeerPong p n) pub
storeDispatch b _ (PeerMessage p (MBlock block)) =
  blockStoreBlockSTM p block b
storeDispatch b _ (PeerMessage p (MTx tx)) =
  blockStoreTxSTM p tx b
storeDispatch b _ (PeerMessage p (MNotFound (NotFound is))) = do
  let blocks =
        [ BlockHash h
          | InvVector t h <- is,
            t == InvBlock || t == InvWitnessBlock
        ]
  unless (null blocks) $ blockStoreNotFoundSTM p blocks b
storeDispatch b pub (PeerMessage p (MInv (Inv is))) = do
  let txs = [TxHash h | InvVector t h <- is, t == InvTx || t == InvWitnessTx]
  publishSTM (StoreTxAnnounce p txs) pub
  unless (null txs) $ blockStoreTxHashSTM p txs b
storeDispatch _ pub (PeerMessage p (MReject r)) =
  when (rejectMessage r == MCTx) $
    case decode (rejectData r) of
      Left _ -> return ()
      Right th ->
        let reject =
              StoreTxReject
                p
                th
                (rejectCode r)
                (getVarString (rejectReason r))
         in publishSTM reject pub
storeDispatch _ _ _ =
  return ()
