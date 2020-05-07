module Haskoin.Store.Manager
    ( StoreConfig(..)
    , Store(..)
    , withStore
    ) where

import           Control.Monad                 (forever, unless, when)
import           Control.Monad.Logger          (MonadLoggerIO)
import           Data.Serialize                (decode)
import           Data.Word                     (Word32)
import           Haskoin                       (BlockHash (..), Inv (..),
                                                InvType (..), InvVector (..),
                                                Message (..),
                                                MessageCommand (..), Network,
                                                NetworkAddress (..),
                                                NotFound (..), Pong (..),
                                                Reject (..), TxHash (..),
                                                VarString (..),
                                                sockToHostAddress)
import           Haskoin.Node                  (Chain, ChainEvent (..),
                                                HostPort, NodeConfig (..),
                                                NodeEvent (..), PeerEvent (..),
                                                PeerManager, WithConnection,
                                                node)
import           Haskoin.Store.BlockStore      (BlockStoreConfig (..),
                                                blockStore)
import           Haskoin.Store.Cache           (CacheConfig (..), CacheWriter,
                                                cacheNewBlock, cacheNewTx,
                                                cacheWriter, connectRedis)
import           Haskoin.Store.Common          (BlockStore,
                                                BlockStoreMessage (..),
                                                StoreEvent (..))
import           Haskoin.Store.Database.Reader (DatabaseReader (..),
                                                connectRocksDB,
                                                withDatabaseReader)
import           Network.Socket                (SockAddr (..))
import           NQE                           (Inbox, Listen, Process (..),
                                                Publisher,
                                                PublisherMessage (Event),
                                                inboxToMailbox, newInbox,
                                                receive, sendSTM, withProcess,
                                                withPublisher, withSubscription)
import           UnliftIO                      (MonadIO, MonadUnliftIO, link,
                                                withAsync)

-- | Store mailboxes.
data Store =
    Store
        { storeManager   :: !PeerManager
        , storeChain     :: !Chain
        , storeBlock     :: !BlockStore
        , storeDB        :: !DatabaseReader
        , storeCache     :: !(Maybe CacheConfig)
        , storePublisher :: !(Publisher StoreEvent)
        , storeNetwork   :: !Network
        }

-- | Configuration for a 'Store'.
data StoreConfig =
    StoreConfig
        { storeConfMaxPeers    :: !Int
      -- ^ max peers to connect to
        , storeConfInitPeers   :: ![HostPort]
      -- ^ static set of peers to connect to
        , storeConfDiscover    :: !Bool
      -- ^ discover new peers
        , storeConfDB          :: !FilePath
      -- ^ RocksDB database path
        , storeConfNetwork     :: !Network
      -- ^ network constants
        , storeConfCache       :: !(Maybe String)
      -- ^ Redis cache configuration
        , storeConfInitialGap  :: !Word32
      -- ^ gap on extended public key with no transactions
        , storeConfGap         :: !Word32
      -- ^ gap for extended public keys
        , storeConfCacheMin    :: !Int
      -- ^ cache xpubs with more than this many used addresses
        , storeConfMaxKeys     :: !Integer
      -- ^ maximum number of keys in Redis cache
        , storeConfWipeMempool :: !Bool
      -- ^ wipe mempool when starting
        , storeConfPeerTimeout :: !Int
      -- ^ disconnect peer if message not received for this many seconds
        , storeConfPeerTooOld  :: !Int
      -- ^ disconnect peer if it has been connected this long
        , storeConfConnect     :: !WithConnection
      -- ^ connect to peers using the function 'withConnection'
        }

withStore ::
       (MonadLoggerIO m, MonadUnliftIO m)
    => StoreConfig
    -> (Store -> m a)
    -> m a
withStore cfg action = do
    chaininbox <- newInbox
    let chain = inboxToMailbox chaininbox
    maybecacheconn <-
        case storeConfCache cfg of
            Nothing       -> return Nothing
            Just redisurl -> Just <$> connectRedis redisurl
    db <-
        connectRocksDB
            (storeConfNetwork cfg)
            (storeConfInitialGap cfg)
            (storeConfGap cfg)
            (storeConfDB cfg)
    case maybecacheconn of
        Nothing -> launch db Nothing chaininbox
        Just cacheconn -> do
            let cachecfg =
                    CacheConfig
                        { cacheConn = cacheconn
                        , cacheMin = storeConfCacheMin cfg
                        , cacheChain = chain
                        , cacheMax = storeConfMaxKeys cfg
                        }
            withProcess (withDatabaseReader db . cacheWriter cachecfg) $ \p ->
                launch db (Just (cachecfg, getProcessMailbox p)) chaininbox
  where
    launch db maybecache chaininbox =
        withPublisher $ \pub -> do
            managerinbox <- newInbox
            blockstoreinbox <- newInbox
            let blockstore = inboxToMailbox blockstoreinbox
                manager = inboxToMailbox managerinbox
                chain = inboxToMailbox chaininbox
            let nodeconfig =
                    NodeConfig
                        { nodeConfMaxPeers = storeConfMaxPeers cfg
                        , nodeConfDB = databaseHandle db
                        , nodeConfPeers = storeConfInitPeers cfg
                        , nodeConfDiscover = storeConfDiscover cfg
                        , nodeConfEvents =
                              storeDispatch blockstore ((`sendSTM` pub) . Event)
                        , nodeConfNetAddr =
                              NetworkAddress
                                  0
                                  (sockToHostAddress (SockAddrInet 0 0))
                        , nodeConfNet = storeConfNetwork cfg
                        , nodeConfTimeout = storeConfPeerTimeout cfg
                        , nodeConfPeerOld = storeConfPeerTooOld cfg
                        , nodeConfConnect = storeConfConnect cfg
                        }
            withAsync (node nodeconfig managerinbox chaininbox) $ \nodeasync -> do
                link nodeasync
                let blockstoreconfig =
                        BlockStoreConfig
                            { blockConfChain = chain
                            , blockConfManager = manager
                            , blockConfListener = (`sendSTM` pub) . Event
                            , blockConfDB = db
                            , blockConfNet = storeConfNetwork cfg
                            , blockConfWipeMempool = storeConfWipeMempool cfg
                            , blockConfPeerTimeout = storeConfPeerTimeout cfg
                            }
                    runaction =
                        action
                            Store
                                { storeManager = manager
                                , storeChain = chain
                                , storeBlock = blockstore
                                , storeDB = db
                                , storeCache = fst <$> maybecache
                                , storePublisher = pub
                                , storeNetwork = storeConfNetwork cfg
                                }
                case maybecache of
                    Nothing ->
                        launch2 blockstoreconfig blockstoreinbox runaction
                    Just (_, cache) ->
                        withSubscription pub $ \evts ->
                            withAsync (cacheWriterEvents evts cache) $ \evtsasync ->
                                link evtsasync >>
                                launch2
                                    blockstoreconfig
                                    blockstoreinbox
                                    runaction
    launch2 blockstoreconfig blockstoreinbox runaction =
        withAsync (blockStore blockstoreconfig blockstoreinbox) $ \blockstoreasync ->
            link blockstoreasync >> runaction

cacheWriterEvents :: MonadIO m => Inbox StoreEvent -> CacheWriter -> m ()
cacheWriterEvents evts cwm = forever $ receive evts >>= (`cacheWriterDispatch` cwm)

cacheWriterDispatch :: MonadIO m => StoreEvent -> CacheWriter -> m ()
cacheWriterDispatch (StoreBestBlock _)   = cacheNewBlock
cacheWriterDispatch (StoreMempoolNew th) = cacheNewTx th
cacheWriterDispatch (StoreTxDeleted th)  = cacheNewTx th
cacheWriterDispatch _                    = const (return ())

-- | Dispatcher of node events.
storeDispatch :: BlockStore -> Listen StoreEvent -> Listen NodeEvent

storeDispatch b pub (PeerEvent (PeerConnected p a)) = do
    pub (StorePeerConnected p a)
    BlockPeerConnect p a `sendSTM` b

storeDispatch b pub (PeerEvent (PeerDisconnected p a)) = do
    pub (StorePeerDisconnected p a)
    BlockPeerDisconnect p a `sendSTM` b

storeDispatch b _ (ChainEvent (ChainBestBlock bn)) =
    BlockNewBest bn `sendSTM` b

storeDispatch _ _ (ChainEvent _) = return ()

storeDispatch _ pub (PeerEvent (PeerMessage p (MPong (Pong n)))) =
    pub (StorePeerPong p n)

storeDispatch b _ (PeerEvent (PeerMessage p (MBlock block))) =
    BlockReceived p block `sendSTM` b

storeDispatch b _ (PeerEvent (PeerMessage p (MTx tx))) =
    BlockTxReceived p tx `sendSTM` b

storeDispatch b _ (PeerEvent (PeerMessage p (MNotFound (NotFound is)))) = do
    let blocks =
            [ BlockHash h
            | InvVector t h <- is
            , t == InvBlock || t == InvWitnessBlock
            ]
    unless (null blocks) $ BlockNotFound p blocks `sendSTM` b

storeDispatch b pub (PeerEvent (PeerMessage p (MInv (Inv is)))) = do
    let txs = [TxHash h | InvVector t h <- is, t == InvTx || t == InvWitnessTx]
    pub (StoreTxAvailable p txs)
    unless (null txs) $ BlockTxAvailable p txs `sendSTM` b

storeDispatch _ pub (PeerEvent (PeerMessage p (MReject r))) =
    when (rejectMessage r == MCTx) $
    case decode (rejectData r) of
        Left _ -> return ()
        Right th ->
            pub $
            StoreTxReject p th (rejectCode r) (getVarString (rejectReason r))

storeDispatch _ _ (PeerEvent _) = return ()
