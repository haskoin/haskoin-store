{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
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
    , MempoolException(..)
    , SentTx(..)
    , store
    , getBestBlock
    , getBlockAtHeight
    , getBlocksAtHeights
    , getBlock
    , getBlocks
    , getTx
    , getTxs
    , getAddrTxs
    , getAddrsTxs
    , getUnspent
    , getUnspents
    , getBalance
    , getBalances
    -- , postTransaction
    ) where

import           Control.Concurrent.NQE
import           Control.Monad.Except
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Data.String
import           Network.Haskoin.Network
import           Network.Haskoin.Node
import           Network.Haskoin.Store.Block
import           Network.Haskoin.Store.Types
import           Network.Socket              (SockAddr (..))
import           UnliftIO

type MonadStore m = (MonadLoggerIO m, MonadReader StoreRead m)

data StoreRead = StoreRead
    { myMailbox    :: !(Inbox NodeEvent)
    , myBlockStore :: !BlockStore
    , myChain      :: !Chain
    , myManager    :: !Manager
    , myListener   :: !(Listen StoreEvent)
    }

store :: (MonadLoggerIO m, MonadUnliftIO m) => StoreConfig -> m ()
store StoreConfig {..} = do
    $(logInfo) $ logMe <> "Launching store"
    ns <- Inbox <$> liftIO newTQueueIO
    sm <- Inbox <$> liftIO newTQueueIO
    let nodeCfg =
            NodeConfig
            { maxPeers = storeConfMaxPeers
            , database = storeConfDB
            , initPeers = storeConfInitPeers
            , discover = storeConfDiscover
            , nodeEvents = (`sendSTM` sm)
            , netAddress = NetworkAddress 0 (SockAddrInet 0 0)
            , nodeSupervisor = ns
            , nodeChain = storeConfChain
            , nodeManager = storeConfManager
            }
    let storeRead = StoreRead
            { myMailbox = sm
            , myBlockStore = storeConfBlocks
            , myChain = storeConfChain
            , myManager = storeConfManager
            , myListener = storeConfListener
            }
    let blockCfg = BlockConfig
            { blockConfMailbox = storeConfBlocks
            , blockConfChain = storeConfChain
            , blockConfManager = storeConfManager
            , blockConfListener = storeConfListener . BlockEvent
            , blockConfDB = storeConfDB
            }
    supervisor
        KillAll
        storeConfSupervisor
        [runReaderT run storeRead, node nodeCfg, blockStore blockCfg]
  where
    run =
        forever $ do
            sm <- asks myMailbox
            storeDispatch =<< receive sm

storeDispatch :: MonadStore m => NodeEvent -> m ()

storeDispatch (ManagerEvent (ManagerConnect p)) = do
    b <- asks myBlockStore
    BlockPeerConnect p `send` b

storeDispatch (ManagerEvent (ManagerDisconnect p)) = do
    b <- asks myBlockStore
    BlockPeerDisconnect p `send` b

storeDispatch (ChainEvent (ChainNewBest bn)) = do
    b <- asks myBlockStore
    BlockChainNew bn `send` b

storeDispatch (ChainEvent _) = return ()

storeDispatch (PeerEvent (p, GotBlock block)) = do
    b <- asks myBlockStore
    BlockReceived p block `send` b

storeDispatch (PeerEvent (p, BlockNotFound hash)) = do
    b <- asks myBlockStore
    BlockNotReceived p hash `send` b

storeDispatch (PeerEvent _) = return ()

-- postTransaction ::
--        MonadIO m => DB -> Mempool -> Tx -> m (Maybe MempoolException)
-- postTransaction db mem tx = do
--     SendTx tx `query` mem

logMe :: IsString a => a
logMe = "[Store] "
