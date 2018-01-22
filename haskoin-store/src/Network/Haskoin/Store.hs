{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TemplateHaskell       #-}
module Network.Haskoin.Store
    ( BlockStore
    , StoreConfig(..)
    , StoreEvent(..)
    , BlockEvent(..)
    , BlockValue(..)
    , DetailedTx(..)
    , AddressTx(..)
    , Unspent(..)
    , AddressBalance(..)
    , store
    , blockGetBest
    , blockGetHeight
    , blockGet
    , blockGetTx
    , blockGetAddrTxs
    , blockGetAddrUnspent
    , blockGetAddrBalance
    ) where

import           Control.Concurrent.NQE
import           Control.Monad.Base
import           Control.Monad.Catch
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.Trans.Control
import           Data.Monoid
import           Data.String.Conversions
import           Data.Text                   (Text)
import           Data.Word
import           Network.Haskoin.Block
import           Network.Haskoin.Network
import           Network.Haskoin.Node
import           Network.Haskoin.Store.Block
import           Network.Haskoin.Store.Types
import           Network.Socket              (SockAddr (..))
import           System.Directory
import           System.FilePath

newtype StoreEvent =
    BlockEvent BlockEvent

type StoreSupervisor = Inbox SupervisorMessage

data StoreConfig = StoreConfig
    { storeConfDir        :: !FilePath
    , storeConfBlocks     :: !BlockStore
    , storeConfSupervisor :: !StoreSupervisor
    , storeConfChain      :: !Chain
    , storeConfListener   :: !(Listen StoreEvent)
    , storeConfMaxPeers   :: !Int
    , storeConfInitPeers  :: ![HostPort]
    , storeConfNoNewPeers :: !Bool
    , storeConfCacheNo    :: !Word32
    , storeConfBlockNo    :: !Word32
    }

data StoreRead = StoreRead
    { myMailbox    :: !(Inbox NodeEvent)
    , myBlockStore :: !BlockStore
    , myChain      :: !Chain
    , myManager    :: !Manager
    , myDir        :: !FilePath
    , myListener   :: !(Listen StoreEvent)
    }

type MonadStore m
     = ( MonadBase IO m
       , MonadThrow m
       , MonadBaseControl IO m
       , MonadLoggerIO m
       , MonadReader StoreRead m)

store ::
       (MonadLoggerIO m, MonadBaseControl IO m, MonadMask m, Forall (Pure m))
    => StoreConfig
    -> m ()
store StoreConfig {..} = do
    $(logDebug) $ logMe <> "Launching store"
    let nodeDir = storeConfDir </> "node"
        blockDir = storeConfDir </> "blocks"
    liftIO $ createDirectoryIfMissing False nodeDir
    ns <- Inbox <$> liftIO newTQueueIO
    mgr <- Inbox <$> liftIO newTQueueIO
    sm <- Inbox <$> liftIO newTQueueIO
    let nodeCfg =
            NodeConfig
            { maxPeers = storeConfMaxPeers
            , directory = nodeDir
            , initPeers = storeConfInitPeers
            , noNewPeers = storeConfNoNewPeers
            , nodeEvents = (`sendSTM` sm)
            , netAddress = NetworkAddress 0 (SockAddrInet 0 0)
            , nodeSupervisor = ns
            , nodeChain = storeConfChain
            , nodeManager = mgr
            }
    let storeRead = StoreRead
            { myMailbox = sm
            , myBlockStore = storeConfBlocks
            , myChain = storeConfChain
            , myManager = mgr
            , myDir = storeConfDir
            , myListener = storeConfListener
            }
    let blockCfg = BlockConfig
            { blockConfDir = blockDir
            , blockConfMailbox = storeConfBlocks
            , blockConfChain = storeConfChain
            , blockConfManager = mgr
            , blockConfListener = storeConfListener . BlockEvent
            , blockConfCacheNo = storeConfCacheNo
            , blockConfBlockNo = storeConfBlockNo
            }
    supervisor
        KillAll
        storeConfSupervisor
        [runReaderT run storeRead, node nodeCfg, blockStore blockCfg]
  where
    run =
        forever $ do
            $(logDebug) $ logMe <> "Awaiting message"
            sm <- asks myMailbox
            storeDispatch =<< receive sm

storeDispatch :: MonadStore m => NodeEvent -> m ()

storeDispatch (ManagerEvent (ManagerConnect p)) = do
    $(logDebug) $ logMe <> "New peer connected"
    b <- asks myBlockStore
    BlockPeerConnect p `send` b

storeDispatch (ManagerEvent (ManagerDisconnect p)) = do
    $(logDebug) $ logMe <> "Peer disconnected"
    b <- asks myBlockStore
    BlockPeerDisconnect p `send` b

storeDispatch (ChainEvent (ChainNewBest bn)) = do
    $(logDebug) $
        logMe <> "Chain synced at height " <> cs (show $ nodeHeight bn)
    b <- asks myBlockStore
    BlockChainNew bn `send` b

storeDispatch (ChainEvent _) =
    $(logDebug) $ logMe <> "Ignoring chain event"

storeDispatch (PeerEvent (p, GotBlock block)) = do
    $(logDebug) $ logMe <> "Received a block"
    b <- asks myBlockStore
    BlockReceived p block `send` b

storeDispatch (PeerEvent (p, BlockNotFound hash)) = do
    $(logDebug) $ logMe <> "A block could not be found: " <> cs (show hash)
    b <- asks myBlockStore
    BlockNotReceived p hash `send` b

storeDispatch (PeerEvent _) = $(logDebug) $ logMe <> "Ignoring peer event"

logMe :: Text
logMe = "[Store] "
