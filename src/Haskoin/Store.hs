{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecordWildCards       #-}
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
    , AddrTx(..)
    , AddressBalance(..)
    , TxException(..)
    , PeerInformation(..)
    , withStore
    , store
    , getBestBlock
    , getBlocksAtHeight
    , getBlock
    , getBlocks
    , getTx
    , getAddrTxs
    , getUnspent
    , getBalance
    , getMempool
    , getPeersInformation
    , publishTx
    ) where

import           Control.Monad.Except
import           Control.Monad.Logger
import           Control.Monad.Trans.Maybe
import           Data.Default
import           Data.Maybe
import           Data.Serialize
import           Database.RocksDB
import           Haskoin.Node
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Network
import           Network.Haskoin.Node.Common
import           Network.Haskoin.Store.Block
import           Network.Haskoin.Store.Types
import           Network.Haskoin.Transaction
import           Network.Socket              (SockAddr (..))
import           NQE
import           UnliftIO

withStore ::
       (MonadLoggerIO m, MonadUnliftIO m)
    => StoreConfig
    -> (Store -> m a)
    -> m a
withStore cfg f =
    withPublisher $ \pub -> do
        mgr_inbox <- newInbox
        ch_inbox <- newInbox
        withProcess (store cfg pub mgr_inbox ch_inbox) $ \(Process bs_async bs) -> do
            link bs_async
            f
                Store
                    { storeManager = inboxToMailbox mgr_inbox
                    , storeChain = inboxToMailbox ch_inbox
                    , storeBlock = bs
                    , storePublisher = pub
                    }

-- | Run a Haskoin Store instance. It will launch a network node and a
-- 'BlockStore', connect to the network and start synchronizing blocks and
-- transactions.
store ::
       (MonadLoggerIO m, MonadUnliftIO m)
    => StoreConfig
    -> Publisher StoreEvent
    -> Inbox ManagerMessage
    -> Inbox ChainMessage
    -> Inbox BlockMessage
    -> m ()
store StoreConfig {..} pub mgr_inbox ch_inbox bs_inbox = do
    let node_cfg =
            NodeConfig
                { nodeConfMaxPeers = storeConfMaxPeers
                , nodeConfDB = storeConfDB
                , nodeConfPeers = storeConfInitPeers
                , nodeConfDiscover = storeConfDiscover
                , nodeConfEvents = storeDispatch (inboxToMailbox bs_inbox) pub
                , nodeConfNetAddr = NetworkAddress 0 (SockAddrInet 0 0)
                , nodeConfNet = storeConfNetwork
                }
    withAsync (node node_cfg mgr_inbox ch_inbox) $ \node_async -> do
        link node_async
        let block_cfg =
                BlockConfig
                    { blockConfChain = inboxToMailbox ch_inbox
                    , blockConfManager = inboxToMailbox mgr_inbox
                    , blockConfListener = (`sendSTM` pub) . Event
                    , blockConfDB = storeConfDB
                    , blockConfUnspentDB = storeConfUnspentDB
                    , blockConfNet = storeConfNetwork
                    }
        blockStore block_cfg bs_inbox

-- | Dispatcher of node events.
storeDispatch :: BlockStore -> Publisher StoreEvent -> NodeEvent -> STM ()

storeDispatch b pub (PeerEvent (PeerConnected p)) = do
    Event (StorePeerConnected p) `sendSTM` pub
    BlockPeerConnect p `sendSTM` b

storeDispatch b pub (PeerEvent (PeerDisconnected p)) = do
    Event (StorePeerDisconnected p) `sendSTM` pub
    BlockPeerDisconnect p `sendSTM` b

storeDispatch b _ (ChainEvent (ChainBestBlock bn)) =
    BlockNewBest bn `sendSTM` b

storeDispatch _ _ (ChainEvent _) = return ()

storeDispatch _ pub (PeerEvent (PeerMessage p (MPong (Pong n)))) =
    Event (StorePeerPong p n) `sendSTM` pub

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

storeDispatch b _ (PeerEvent (PeerMessage p (MInv (Inv is)))) = do
    let txs = [TxHash h | InvVector t h <- is, t == InvTx || t == InvWitnessTx]
    unless (null txs) $ BlockTxAvailable p txs `sendSTM` b

storeDispatch _ pub (PeerEvent (PeerMessage _ (MReject Reject {..}))) =
    when (rejectMessage == MCTx) $
    case decode_tx_hash rejectData of
        Nothing -> return ()
        Just tx_hash ->
            let e = Event . StoreTxException tx_hash
                m =
                    case rejectCode of
                        RejectInvalid         -> InvalidTx
                        RejectDuplicate       -> DoubleSpend
                        RejectNonStandard     -> NonStandard
                        RejectDust            -> Dust
                        RejectInsufficientFee -> LowFee
                        _                     -> PeerRejectOther
             in e m `sendSTM` pub
  where
    decode_tx_hash bytes =
        case decode bytes of
            Left _  -> Nothing
            Right h -> Just h

storeDispatch _ _ (PeerEvent _) = return ()

-- | Publish a new transaction to the network.
publishTx ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Network
    -> Store
    -> DB
    -> Tx
    -> m (Either TxException DetailedTx)
publishTx net Store {..} db tx =
    getTx net (txHash tx) db def >>= \case
        Just d -> return (Right d)
        Nothing ->
            timeout (10 * 1000 * 1000) (runExceptT go) >>= \case
                Nothing -> return (Left PublishTimeout)
                Just e -> return e
  where
    go = do
        p <-
            managerGetPeers storeManager >>= \case
                [] -> throwError NoPeers
                p:_ -> return (onlinePeerMailbox p)
        ExceptT . withSubscription storePublisher $ \sub ->
            runExceptT (send_it sub p)
    send_it sub p = do
        h <- is_at_height
        unless h $ throwError NotAtHeight
        MTx tx `sendMessage` p
        recv_loop sub p
        maybeToExceptT CouldNotImport . MaybeT $ getTx net (txHash tx) db def
    recv_loop sub p =
        receive sub >>= \case
            StoreMempoolNew h
                | h == txHash tx -> return ()
            StorePeerDisconnected p'
                | p' == p -> throwError PeerIsGone
            StoreTxException h AlreadyImported
                | h == txHash tx -> return ()
            StoreTxException h x
                | h == txHash tx -> throwError x
            _ -> recv_loop sub p
    is_at_height = do
        bb <- getBestBlockHash db def
        cb <- chainGetBest storeChain
        return (headerHash (nodeHeader cb) == bb)

-- | Obtain information about connected peers from peer manager process.
getPeersInformation :: MonadIO m => Manager -> m [PeerInformation]
getPeersInformation mgr = mapMaybe toInfo <$> managerGetPeers mgr
  where
    toInfo op = do
        ver <- onlinePeerVersion op
        let as = onlinePeerAddress op
            ua = getVarString $ userAgent ver
            vs = version ver
            sv = services ver
            rl = relay ver
        return
            PeerInformation
                { peerUserAgent = ua
                , peerAddress = as
                , peerVersion = vs
                , peerServices = sv
                , peerRelay = rl
                }
