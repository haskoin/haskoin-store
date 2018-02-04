{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}
module Network.Haskoin.Node.Node
    ( node
    ) where

import           Control.Concurrent.Async.Lifted.Safe
import           Control.Concurrent.NQE
import           Control.Monad.Base
import           Control.Monad.Catch
import           Control.Monad.Logger
import           Control.Monad.Trans
import           Control.Monad.Trans.Control
import           Data.Monoid
import           Data.Text                            (Text)
import           Network.Haskoin.Node.Chain
import           Network.Haskoin.Node.Common
import           Network.Haskoin.Node.Manager
import           System.FilePath

node ::
       ( MonadBase IO m
       , MonadBaseControl IO m
       , MonadLoggerIO m
       , MonadThrow m
       , MonadMask m
       , MonadCatch m
       , Forall (Pure m)
       )
    => NodeConfig
    -> m ()
node cfg = do
    psup <- Inbox <$> liftIO newTQueueIO
    $(logInfo) $ logMe <> "Starting node"
    supervisor
        KillAll
        (nodeSupervisor cfg)
        [chain chCfg, manager (mgrCfg psup), peerSup psup]
  where
    peerSup psup = supervisor (Notify deadPeer) psup []
    chCfg =
        ChainConfig
        { chainConfDbFile = directory cfg </> "headers"
        , chainConfListener = nodeEvents cfg . ChainEvent
        , chainConfManager = nodeManager cfg
        , chainConfChain = nodeChain cfg
        }
    mgrCfg psup =
        ManagerConfig
        { mgrConfMaxPeers = maxPeers cfg
        , mgrConfDir = directory cfg
        , mgrConfDiscover = discover cfg
        , mgrConfMgrListener = nodeEvents cfg . ManagerEvent
        , mgrConfPeerListener = nodeEvents cfg . PeerEvent
        , mgrConfNetAddr = netAddress cfg
        , mgrConfPeers = initPeers cfg
        , mgrConfManager = nodeManager cfg
        , mgrConfChain = nodeChain cfg
        , mgrConfPeerSupervisor = psup
        }
    deadPeer ex = PeerStopped ex `sendSTM` nodeManager cfg

logMe :: Text
logMe = "[Node] "
