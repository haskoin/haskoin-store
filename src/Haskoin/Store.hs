{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
module Haskoin.Store
    ( Store(..)
    , BlockStore
    , StoreConfig(..)
    , StoreEvent(..)
    , BlockData(..)
    , Transaction(..)
    , Input(..)
    , Output(..)
    , Spender(..)
    , BlockRef(..)
    , Unspent(..)
    , AddressTx(..)
    , Balance(..)
    , PeerInformation(..)
    , withStore
    , store
    , getBestBlock
    , getBlocksAtHeight
    , getBlock
    , getTransaction
    , getBalance
    , getMempool
    , getAddressUnspents
    , getAddressTxs
    , getPeersInformation
    , publishTx
    , transactionData
    , isCoinbase
    , confirmed
    , transactionToJSON
    , transactionToEncoding
    , outputToJSON
    , outputToEncoding
    , inputToJSON
    , inputToEncoding
    , unspentToJSON
    , unspentToEncoding
    , balanceToJSON
    , balanceToEncoding
    , addressTxToJSON
    , addressTxToEncoding
    ) where

import           Control.Monad.Except
import           Control.Monad.Logger
import           Data.Maybe
import           Haskoin
import           Haskoin.Node
import           Network.Haskoin.Store.Block
import           Network.Haskoin.Store.Data
import           Network.Haskoin.Store.Messages
import           Network.Socket                 (SockAddr (..))
import           NQE
import           UnliftIO

withStore ::
       (MonadLoggerIO m, MonadUnliftIO m)
    => StoreConfig
    -> (Store -> m a)
    -> m a
withStore cfg f = do
    mgri <- newInbox
    chi <- newInbox
    withProcess (store cfg mgri chi) $ \(Process a b) -> do
        link a
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
    -> Inbox BlockMessage
    -> m ()
store cfg mgri chi bsi = do
    let ncfg =
            NodeConfig
                { nodeConfMaxPeers = storeConfMaxPeers cfg
                , nodeConfDB = storeConfDB cfg
                , nodeConfPeers = storeConfInitPeers cfg
                , nodeConfDiscover = storeConfDiscover cfg
                , nodeConfEvents = storeDispatch b l
                , nodeConfNetAddr = NetworkAddress 0 (SockAddrInet 0 0)
                , nodeConfNet = storeConfNetwork cfg
                , nodeConfTimeout = 10
                }
    withAsync (node ncfg mgri chi) $ \a -> do
        link a
        let bcfg =
                BlockConfig
                    { blockConfChain = inboxToMailbox chi
                    , blockConfManager = inboxToMailbox mgri
                    , blockConfListener = l
                    , blockConfDB = storeConfDB cfg
                    , blockConfNet = storeConfNetwork cfg
                    }
        blockStore bcfg bsi
  where
    l = storeConfListen cfg
    b = inboxToMailbox bsi

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

storeDispatch b _ (PeerEvent (PeerMessage p (MInv (Inv is)))) = do
    let txs = [TxHash h | InvVector t h <- is, t == InvTx || t == InvWitnessTx]
    unless (null txs) $ BlockTxAvailable p txs `sendSTM` b

storeDispatch _ _ (PeerEvent _) = return ()

-- | Publish a new transaction to the network.
publishTx :: (MonadUnliftIO m, MonadLoggerIO m) => Manager -> Tx -> m Bool
publishTx mgr tx =
    managerGetPeers mgr >>= \case
        [] -> return False
        ps -> do
            forM_ ps (\OnlinePeer {onlinePeerMailbox = p} -> MTx tx `sendMessage` p)
            return True


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
