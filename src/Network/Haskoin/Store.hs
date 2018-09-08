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
    , BlockRef(..)
    , StoreConfig(..)
    , StoreEvent(..)
    , BlockValue(..)
    , DetailedTx(..)
    , NewTx(..)
    , AddressTx(..)
    , Unspent(..)
    , AddressBalance(..)
    , TxException(..)
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
    , getMempool
    , publishTx
    ) where

import           Control.Concurrent.NQE
import           Control.Monad.Except
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.Trans.Maybe
import           Data.Serialize
import           Data.String
import           Data.String.Conversions
import           Database.RocksDB
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Network
import           Network.Haskoin.Node
import           Network.Haskoin.Store.Block
import           Network.Haskoin.Store.Types
import           Network.Haskoin.Transaction
import           Network.Socket              (SockAddr (..))
import           System.Random
import           UnliftIO

type MonadStore m = (MonadLoggerIO m, MonadReader StoreRead m)

data StoreRead = StoreRead
    { myMailbox    :: !(Inbox NodeEvent)
    , myBlockStore :: !BlockStore
    , myChain      :: !Chain
    , myManager    :: !Manager
    , myListener   :: !(Listen StoreEvent)
    , myPublisher  :: !(Publisher Inbox TBQueue StoreEvent)
    , myBlockDB    :: !DB
    , myNetwork    :: !Network
    }

store :: (MonadLoggerIO m, MonadUnliftIO m) => StoreConfig m -> m ()
store StoreConfig {..} = do
    $(logInfoS) "Store" "Launching..."
    ns <- Inbox <$> newTQueueIO
    sm <- Inbox <$> newTQueueIO
    ls <- Inbox <$> newTQueueIO
    let node_cfg =
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
            , nodeNet = storeConfNetwork
            }
    let store_read =
            StoreRead
            { myMailbox = sm
            , myBlockStore = storeConfBlocks
            , myChain = storeConfChain
            , myManager = storeConfManager
            , myPublisher = storeConfPublisher
            , myListener = (`sendSTM` ls)
            , myBlockDB = storeConfDB
            , myNetwork = storeConfNetwork
            }
    let block_cfg =
            BlockConfig
            { blockConfMailbox = storeConfBlocks
            , blockConfChain = storeConfChain
            , blockConfManager = storeConfManager
            , blockConfListener = (`sendSTM` ls)
            , blockConfDB = storeConfDB
            , blockConfNet = storeConfNetwork
            }
    supervisor
        KillAll
        storeConfSupervisor
        [ runReaderT run store_read
        , node node_cfg
        , blockStore block_cfg
        , boundedPublisher storeConfPublisher ls
        ]
  where
    run =
        forever $ do
            sm <- asks myMailbox
            storeDispatch =<< receive sm

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
                    cs (txHashToHex tx_hash)
                atomically (l (TxException tx_hash InvalidTx))
            RejectDuplicate -> do
                $(logErrorS) "Store" $
                    "Peer " <> pstr <> " rejected double-spend tx hash: " <>
                    cs (txHashToHex tx_hash)
                atomically (l (TxException tx_hash DoubleSpend))
            RejectNonStandard -> do
                $(logErrorS) "Store" $
                    "Peer " <> pstr <> " rejected non-standard tx hash: " <>
                    cs (txHashToHex tx_hash)
                atomically (l (TxException tx_hash NonStandard))
            RejectDust -> do
                $(logErrorS) "Store" $
                    "Peer " <> pstr <> " rejected dust tx hash: " <>
                    cs (txHashToHex tx_hash)
                atomically (l (TxException tx_hash Dust))
            RejectInsufficientFee -> do
                $(logErrorS) "Store" $
                    "Peer " <> pstr <> " rejected low fee tx hash: " <>
                    cs (txHashToHex tx_hash)
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

publishTx ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Network
    -> Publisher Inbox TBQueue StoreEvent
    -> Manager
    -> Chain
    -> DB
    -> BlockStore
    -> Tx
    -> m (Either TxException DetailedTx)
publishTx net pub mgr ch db bl tx =
    getTx net (txHash tx) db Nothing >>= \case
        Just d -> return (Right d)
        Nothing ->
            timeout 10000000 (runExceptT go) >>= \case
                Nothing -> return (Left PublishTimeout)
                Just e -> return e
  where
    go = do
        p <-
            managerGetPeers mgr >>= \case
                [] -> throwError NoPeers
                p:_ -> return (onlinePeerMailbox p)
        ExceptT . withBoundedPubSub 1000 pub $ \sub ->
            runExceptT (send_it sub p)
    send_it sub p = do
        h <- is_at_height
        unless h $ throwError NotAtHeight
        r <- liftIO randomIO
        MTx tx `sendMessage` p
        MPing (Ping r) `sendMessage` p
        recv_loop sub p r
        maybeToExceptT
            CouldNotImport
            (MaybeT (getTx net (txHash tx) db Nothing))
    recv_loop sub p r =
        receive sub >>= \case
            PeerPong p' n
                | p == p' && n == r -> do
                      TxPublished tx `send` bl
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
    is_at_height = do
        bb <- getBestBlockHash db Nothing
        cb <- chainGetBest ch
        return (headerHash (nodeHeader cb) == bb)

peerString :: (MonadStore m, IsString a) => Peer -> m a
peerString p = do
    mgr <- asks myManager
    managerGetPeer mgr p >>= \case
        Nothing -> return "[unknown]"
        Just o -> return $ fromString $ show $ onlinePeerAddress o
