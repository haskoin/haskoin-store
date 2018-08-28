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
    $(logInfo) $ logMe <> "Launching store"
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

storeDispatch (PeerEvent (_, Rejected Reject {..})) =
    void . runMaybeT $ do
        l <- asks myListener
        guard (rejectMessage == MCTx)
        tx_hash <- decode_tx_hash rejectData
        case rejectCode of
            RejectInvalid -> do
                $(logError) $
                    logMe <> "Peer rejected invalid tx hash: " <>
                    cs (txHashToHex tx_hash)
                atomically (l (TxException tx_hash InvalidTx))
            RejectDuplicate -> do
                $(logError) $
                    logMe <> "Peer rejected double-spend tx hash: " <>
                    cs (txHashToHex tx_hash)
                atomically (l (TxException tx_hash DoubleSpend))
            RejectNonStandard -> do
                $(logError) $
                    logMe <> "Peer rejected non-standard tx hash: " <>
                    cs (txHashToHex tx_hash)
                atomically (l (TxException tx_hash NonStandard))
            RejectDust -> do
                $(logError) $
                    logMe <> "Peer rejected dust tx hash: " <>
                    cs (txHashToHex tx_hash)
                atomically (l (TxException tx_hash Dust))
            RejectInsufficientFee -> do
                $(logError) $
                    logMe <> "Peer rejected low fee tx hash: " <>
                    cs (txHashToHex tx_hash)
                atomically (l (TxException tx_hash LowFee))
            _ -> do
                $(logError) $
                    logMe <> "Peer rejected tx hash: " <> cs (show rejectCode)
                atomically (l (TxException tx_hash PeerRejectOther))
  where
    decode_tx_hash bytes =
        case decode bytes of
            Left e -> do
                $(logError) $
                    logMe <> "Colud not decode from peer tx rejection hash: " <>
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
    -> Tx
    -> m (Either TxException DetailedTx)
publishTx net pub mgr ch db tx =
    getTx net (txHash tx) db Nothing >>= \case
        Just d -> return (Right d)
        Nothing ->
            timeout 10000000 (runExceptT go) >>= \case
                Nothing -> return (Left PublishTimeout)
                Just e -> return e
  where
    go = do
        $(logDebug) $
            "Attempting to publish tx hash: " <> cs (txHashToHex (txHash tx))
        p <-
            managerGetPeers mgr >>= \case
                [] -> throwError NoPeers
                p:_ -> return p
        $(logInfo) $ "Got a peer to publish transaction"
        ExceptT . withBoundedPubSub 1000 pub $ \sub ->
            runExceptT (send_it sub p)
    send_it sub p = do
        h <- is_at_height
        unless h $ throwError NotAtHeight
        MTx tx `sendMessage` p
        MMempool `sendMessage` p
        recv_loop sub p
        maybeToExceptT
            CouldNotImport
            (MaybeT (getTx net (txHash tx) db Nothing))
    recv_loop sub p =
        receive sub >>= \case
            MempoolNew h
                | h == txHash tx -> ExceptT (return (Right ()))
            PeerDisconnected p'
                | p' == p -> ExceptT (return (Left PeerIsGone))
            TxException h AlreadyImported
                | h == txHash tx -> ExceptT (return (Right ()))
            TxException h x
                | h == txHash tx -> ExceptT (return (Left x))
            _ -> recv_loop sub p
    is_at_height = do
        bb <- getBestBlockHash db Nothing
        cb <- chainGetBest ch
        return (headerHash (nodeHeader cb) == bb)

logMe :: IsString a => a
logMe = "[Store] "
