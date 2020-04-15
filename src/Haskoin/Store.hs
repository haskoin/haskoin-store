module Haskoin.Store
    ( StoreConfig (..)
    , store
    , withStore
    , module X )
    where

import           Control.Monad                             (forever, unless,
                                                            when)
import           Control.Monad.Logger                      (MonadLoggerIO)
import           Data.Serialize                            (decode)
import           Data.Word                                 (Word32)
import           Database.Redis                            (Connection)
import           Haskoin                                   (BlockHash (..),
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
                                                            sockToHostAddress)
import           Haskoin.Node                              (ChainEvent (..),
                                                            ChainMessage,
                                                            HostPort,
                                                            ManagerMessage,
                                                            NodeConfig (..),
                                                            NodeEvent (..),
                                                            PeerEvent (..),
                                                            node)
import           Network.Haskoin.Store.BlockStore          as X
import           Network.Haskoin.Store.CacheWriter         as X
import           Network.Haskoin.Store.Common              as X
import           Network.Haskoin.Store.Data.CacheReader    as X
import           Network.Haskoin.Store.Data.DatabaseReader as X
import           Network.Haskoin.Store.Data.DatabaseWriter as X
import           Network.Haskoin.Store.Data.MemoryDatabase as X
import           Network.Haskoin.Store.Data.Types          as X
import           Network.Haskoin.Store.Logic               as X
import           Network.Haskoin.Store.Web                 as X
import           Network.Socket                            (SockAddr (..))
import           NQE                                       (Inbox, Listen,
                                                            Process (..),
                                                            Publisher,
                                                            PublisherMessage (Event),
                                                            inboxToMailbox,
                                                            newInbox, receive,
                                                            send, sendSTM,
                                                            withProcess,
                                                            withSubscription)
import           UnliftIO                                  (MonadIO,
                                                            MonadUnliftIO, link,
                                                            withAsync)

-- | Configuration for a 'Store'.
data StoreConfig =
    StoreConfig
        { storeConfMaxPeers  :: !Int
      -- ^ max peers to connect to
        , storeConfInitPeers :: ![HostPort]
      -- ^ static set of peers to connect to
        , storeConfDiscover  :: !Bool
      -- ^ discover new peers?
        , storeConfDB        :: !DatabaseReader
      -- ^ RocksDB database handler
        , storeConfNetwork   :: !Network
      -- ^ network constants
        , storeConfPublisher :: !(Publisher StoreEvent)
      -- ^ publish store events
        , storeConfCache     :: !(Maybe (Connection, CacheWriterInbox))
      -- ^ Redis cache configuration
        , storeConfGap       :: !Word32
      -- ^ gap for extended public keys
        }

withStore ::
       (MonadLoggerIO m, MonadUnliftIO m)
    => StoreConfig
    -> (Store -> m a)
    -> m a
withStore cfg f = do
    mgri <- newInbox
    chi <- newInbox
    withProcess (store cfg mgri chi) $ \(Process _ b) ->
        f
            Store
                { storeManager = inboxToMailbox mgri
                , storeChain = inboxToMailbox chi
                , storeBlock = b
                }

-- | Run a Haskoin Store instance. It will launch a network node and a
-- 'BlockStore', connect to the network and start synchronizing blocks and
-- transactions.
store ::
       (MonadLoggerIO m, MonadUnliftIO m)
    => StoreConfig
    -> Inbox ManagerMessage
    -> Inbox ChainMessage
    -> Inbox BlockStoreMessage
    -> m ()
store cfg mgri chi bsi = do
    let ncfg =
            NodeConfig
                { nodeConfMaxPeers = storeConfMaxPeers cfg
                , nodeConfDB = databaseHandle (storeConfDB cfg)
                , nodeConfPeers = storeConfInitPeers cfg
                , nodeConfDiscover = storeConfDiscover cfg
                , nodeConfEvents = storeDispatch b ((`sendSTM` l) . Event)
                , nodeConfNetAddr =
                      NetworkAddress 0 (sockToHostAddress (SockAddrInet 0 0))
                , nodeConfNet = storeConfNetwork cfg
                , nodeConfTimeout = 10
                }
    withAsync (node ncfg mgri chi) $ \a -> do
        link a
        let bcfg =
                BlockStoreConfig
                    { blockConfChain = inboxToMailbox chi
                    , blockConfManager = inboxToMailbox mgri
                    , blockConfListener = (`sendSTM` l) . Event
                    , blockConfDB = storeConfDB cfg
                    , blockConfNet = storeConfNetwork cfg
                    }
        case storeConfCache cfg of
            Nothing -> blockStore bcfg bsi
            Just cacheinfo -> do
                let cwm = inboxToMailbox (snd cacheinfo)
                    crconf =
                        CacheReaderConfig
                            { cacheReaderConn = fst cacheinfo
                            , cacheReaderWriter = cwm
                            , cacheReaderGap = storeConfGap cfg
                            }
                    cwconf =
                        CacheWriterConfig
                            { cacheWriterReader = crconf
                            , cacheWriterChain = c
                            , cacheWriterMailbox = snd cacheinfo
                            , cacheWriterNetwork = storeConfNetwork cfg
                            }
                    cw =
                        withDatabaseReader
                            (storeConfDB cfg)
                            (cacheWriter cwconf)
                withAsync cw $ \w ->
                    withSubscription l $ \evts -> do
                        link w
                        withAsync (cacheWriterEvents evts cwm) $ \cwd -> do
                            link cwd
                            blockStore bcfg bsi
  where
    l = storeConfPublisher cfg
    b = inboxToMailbox bsi
    c = inboxToMailbox chi

cacheWriterEvents :: MonadIO m => Inbox StoreEvent -> CacheWriter -> m ()
cacheWriterEvents evts cwm = forever $ receive evts >>= (`cacheWriterDispatch` cwm)

cacheWriterDispatch :: MonadIO m => StoreEvent -> CacheWriter -> m ()
cacheWriterDispatch (StoreBestBlock _)    = send CacheNewBlock
cacheWriterDispatch (StoreMempoolNew txh) = send (CacheNewTx txh)
cacheWriterDispatch (StoreTxDeleted txh)  = send (CacheDelTx txh)
cacheWriterDispatch _                     = const (return ())

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
