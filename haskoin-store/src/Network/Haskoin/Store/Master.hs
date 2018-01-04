{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}
module Network.Haskoin.Store.Master where

import           Control.Concurrent.NQE
import           Control.Monad.Base
import           Control.Monad.Catch
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.Trans.Control
import           Data.Monoid
import           Data.String.Conversions
import           Data.Text                   (Text)
import           Network.Haskoin.Block
import           Network.Haskoin.Network
import           Network.Haskoin.Node
import           Network.Haskoin.Store.Block
import           Network.Socket              (SockAddr (..))
import           System.Directory
import           System.FilePath

type Store = Inbox NodeEvent

newtype StoreEvent =
    BlockEvent BlockEvent

type StoreSupervisor = Inbox SupervisorMessage

data StoreConfig = StoreConfig
    { storeConfDir        :: !FilePath
    , storeConfMailbox    :: !Store
    , storeConfBlocks     :: !BlockStore
    , storeConfSupervisor :: !StoreSupervisor
    , storeConfChain      :: !Chain
    , storeConfListener   :: !(Listen StoreEvent)
    }

data StoreRead = StoreRead
    { mySelf       :: !Store
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
store cfg = do
    $(logDebug) $ logMe <> "Launching store"
    let nodeDir = storeConfDir cfg </> "node"
        blockDir = storeConfDir cfg </> "blocks"
    liftIO $ createDirectoryIfMissing False nodeDir
    ns <- Inbox <$> liftIO newTQueueIO
    mgr <- Inbox <$> liftIO newTQueueIO
    let nodeCfg =
            NodeConfig
            { maxPeers = 20
            , directory = nodeDir
            , initPeers = []
            , noNewPeers = False
            , nodeEvents = (`sendSTM` storeConfMailbox cfg)
            , netAddress = NetworkAddress 0 (SockAddrInet 0 0)
            , nodeSupervisor = ns
            , nodeChain = storeConfChain cfg
            , nodeManager = mgr
            }
    let storeRead = StoreRead
            { mySelf = storeConfMailbox cfg
            , myBlockStore = storeConfBlocks cfg
            , myChain = storeConfChain cfg
            , myManager = mgr
            , myDir = storeConfDir cfg
            , myListener = storeConfListener cfg
            }
    let blockCfg = BlockConfig
            { blockConfDir = blockDir
            , blockConfMailbox = storeConfBlocks cfg
            , blockConfChain = storeConfChain cfg
            , blockConfManager = mgr
            , blockConfListener = storeConfListener cfg . BlockEvent
            }
    supervisor
        KillAll
        (storeConfSupervisor cfg)
        [runReaderT run storeRead, node nodeCfg, blockStore blockCfg]
  where
    run =
        forever $ do
            $(logDebug) $ logMe <> "Awaiting message"
            msg <- receive $ storeConfMailbox cfg
            storeDispatch msg

storeDispatch :: MonadStore m => NodeEvent -> m ()

storeDispatch (ManagerEvent (ManagerAvailable p)) = do
    $(logDebug) $ logMe <> "Peer became available"
    b <- asks myBlockStore
    BlockPeerAvailable p `send` b

storeDispatch (ManagerEvent (ManagerConnect p)) = do
    $(logDebug) $ logMe <> "New peer connected"
    b <- asks myBlockStore
    BlockPeerConnect p `send` b

storeDispatch (ManagerEvent _) = $(logDebug) $ logMe <> "Ignoring manager event"

storeDispatch (ChainEvent (ChainNewBest bn)) = do
    $(logDebug) $
        logMe <> "Chain synced at height " <> cs (show $ nodeHeight bn)
    b <- asks myBlockStore
    BlockChainNew bn `send` b

storeDispatch (ChainEvent _) =
    $(logDebug) $ logMe <> "Ignoring chain event"

storeDispatch (PeerEvent _) = $(logDebug) $ logMe <> "Ignoring peer event"

logMe :: Text
logMe = "[Store] "
