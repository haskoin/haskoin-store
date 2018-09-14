{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TemplateHaskell       #-}
module Haskoin.Store
    ( Store(..)
    , BlockStore
    , Output(..)
    , Spender(..)
    , BlockRef(..)
    , StoreConfig(..)
    , StoreEvent(..)
    , BlockValue(..)
    , DetailedTx(..)
    , DetailedInput(..)
    , DetailedOutput(..)
    , NewTx(..)
    , AddrOutput(..)
    , AddressBalance(..)
    , TxException(..)
    , withStore
    , getBestBlock
    , getBlockAtHeight
    , getBlock
    , getBlocks
    , getTx
    , getAddrTxs
    , getUnspent
    , getBalance
    , getMempool
    , publishTx
    ) where

import           Control.Monad.Except
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.Trans.Maybe
import           Data.Serialize
import           Data.String
import           Data.String.Conversions
import           Database.RocksDB
import           Haskoin.Node
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Network
import           Network.Haskoin.Store.Block
import           Network.Haskoin.Store.Types
import           Network.Haskoin.Transaction
import           Network.Socket              (SockAddr (..))
import           NQE
import           System.Random
import           UnliftIO

-- | Context for the store.
type MonadStore m = (MonadLoggerIO m, MonadReader StoreRead m)

-- | Running store state.
data StoreRead = StoreRead
    { myMailbox    :: !(Inbox NodeEvent)
    , myBlockStore :: !BlockStore
    , myChain      :: !Chain
    , myManager    :: !Manager
    , myListener   :: !(Listen StoreEvent)
    , myPublisher  :: !(Publisher StoreEvent)
    , myBlockDB    :: !DB
    , myNetwork    :: !Network
    }

-- | Run a Haskoin Store instance. It will launch a network node, a
-- 'BlockStore', connect to the network and start synchronizing blocks and
-- transactions.
withStore ::
       (MonadLoggerIO m, MonadUnliftIO m)
    => StoreConfig
    -> (Store -> m a)
    -> m a
withStore StoreConfig {..} f = do
    sm <- newInbox =<< newTQueueIO
    withNode (node_cfg sm) $ \(mg, ch) -> do
        ls <- newInbox =<< newTQueueIO
        bs <- newInbox =<< newTQueueIO
        pb <- newInbox =<< newTQueueIO
        let store_read =
                StoreRead
                    { myMailbox = sm
                    , myBlockStore = bs
                    , myChain = ch
                    , myManager = mg
                    , myPublisher = pb
                    , myListener = (`sendSTM` ls)
                    , myBlockDB = storeConfDB
                    , myNetwork = storeConfNetwork
                    }
        let block_cfg =
                BlockConfig
                    { blockConfMailbox = bs
                    , blockConfChain = ch
                    , blockConfManager = mg
                    , blockConfListener = (`sendSTM` ls)
                    , blockConfDB = storeConfDB
                    , blockConfNet = storeConfNetwork
                    }
        withAsync (runReaderT run store_read) $ \st ->
            withAsync (blockStore block_cfg) $ \bt ->
                withAsync (publisher pb (receiveSTM ls)) $ \pu -> do
                    link st
                    link bt
                    link pu
                    f (Store mg ch bs pb)
  where
    run =
        forever $ do
            sm <- asks myMailbox
            storeDispatch =<< receive sm
    node_cfg sm =
        NodeConfig
            { maxPeers = storeConfMaxPeers
            , database = storeConfDB
            , initPeers = storeConfInitPeers
            , discover = storeConfDiscover
            , nodeEvents = (`sendSTM` sm)
            , netAddress = NetworkAddress 0 (SockAddrInet 0 0)
            , nodeNet = storeConfNetwork
            }

-- | Dispatcher of node events.
storeDispatch :: MonadStore m => NodeEvent -> m ()

storeDispatch (ManagerEvent (ManagerConnect p)) = do
    b <- asks myBlockStore
    l <- asks myListener
    atomically (l (PeerConnected p))
    BlockPeerConnect p `send` b

storeDispatch (ManagerEvent (ManagerDisconnect p)) = do
    b <- asks myBlockStore
    l <- asks myListener
    atomically (l (PeerDisconnected p))
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

storeDispatch (PeerEvent (p, TxAvail ts)) = do
    b <- asks myBlockStore
    TxAvailable p ts `send` b

storeDispatch (PeerEvent (p, GotTx tx)) = do
    b <- asks myBlockStore
    TxReceived p tx `send` b

storeDispatch (PeerEvent (p, Rejected Reject {..})) =
    void . runMaybeT $ do
        l <- asks myListener
        guard (rejectMessage == MCTx)
        pstr <- peerString p
        tx_hash <- decode_tx_hash pstr rejectData
        case rejectCode of
            RejectInvalid -> do
                $(logErrorS) "Store" $
                    "Peer " <> pstr <> " rejected invalid tx hash: " <>
                    txHashToHex tx_hash
                atomically (l (TxException tx_hash InvalidTx))
            RejectDuplicate -> do
                $(logErrorS) "Store" $
                    "Peer " <> pstr <> " rejected double-spend tx hash: " <>
                    txHashToHex tx_hash
                atomically (l (TxException tx_hash DoubleSpend))
            RejectNonStandard -> do
                $(logErrorS) "Store" $
                    "Peer " <> pstr <> " rejected non-standard tx hash: " <>
                    txHashToHex tx_hash
                atomically (l (TxException tx_hash NonStandard))
            RejectDust -> do
                $(logErrorS) "Store" $
                    "Peer " <> pstr <> " rejected dust tx hash: " <>
                    txHashToHex tx_hash
                atomically (l (TxException tx_hash Dust))
            RejectInsufficientFee -> do
                $(logErrorS) "Store" $
                    "Peer " <> pstr <> " rejected low fee tx hash: " <>
                    txHashToHex tx_hash
                atomically (l (TxException tx_hash LowFee))
            _ -> do
                $(logErrorS) "Store" $
                    "Peer " <> pstr <> " rejected tx hash: " <>
                    cs (show rejectCode)
                atomically (l (TxException tx_hash PeerRejectOther))
  where
    decode_tx_hash pstr bytes =
        case decode bytes of
            Left e -> do
                $(logErrorS) "Store" $
                    "Could not decode rejection data from peer " <> pstr <> ": " <>
                    cs e
                MaybeT (return Nothing)
            Right h -> return h

storeDispatch (PeerEvent (_, TxNotFound tx_hash)) = do
    l <- asks myListener
    atomically (l (TxException tx_hash CouldNotImport))

storeDispatch (PeerEvent _) = return ()

-- | Publish a new transaction to the network.
publishTx ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Network
    -> Store
    -> DB
    -> Tx
    -> m (Either TxException DetailedTx)
publishTx net Store {..} db tx =
    withSnapshot db $ \s ->
        getTx net (txHash tx) db s >>= \case
            Just d -> return (Right d)
            Nothing ->
                timeout 10000000 (runExceptT (go s)) >>= \case
                    Nothing -> return (Left PublishTimeout)
                    Just e -> return e
  where
    go s = do
        p <-
            managerGetPeers storeManager >>= \case
                [] -> throwError NoPeers
                p:_ -> return (onlinePeerMailbox p)
        ExceptT . withPubSub storePublisher (newTBQueueIO 1000) $ \sub ->
            runExceptT (send_it s sub p)
    send_it s sub p = do
        h <- is_at_height s
        unless h $ throwError NotAtHeight
        r <- liftIO randomIO
        MTx tx `sendMessage` p
        MPing (Ping r) `sendMessage` p
        recv_loop sub p r
        maybeToExceptT
            CouldNotImport
            (MaybeT (withSnapshot db $ getTx net (txHash tx) db))
    recv_loop sub p r =
        receive sub >>= \case
            PeerPong p' n
                | p == p' && n == r -> do
                    TxPublished tx `send` storeBlock
                    recv_loop sub p r
            MempoolNew h
                | h == txHash tx -> return ()
            PeerDisconnected p'
                | p' == p -> throwError PeerIsGone
            TxException h AlreadyImported
                | h == txHash tx -> return ()
            TxException h x
                | h == txHash tx -> throwError x
            _ -> recv_loop sub p r
    is_at_height s = do
        bb <- getBestBlockHash db s
        cb <- chainGetBest storeChain
        return (headerHash (nodeHeader cb) == bb)

-- | Peer information to show on logs.
peerString :: (MonadStore m, IsString a) => Peer -> m a
peerString p = do
    mgr <- asks myManager
    managerGetPeer mgr p >>= \case
        Nothing -> return "[unknown]"
        Just o -> return $ fromString $ show $ onlinePeerAddress o
