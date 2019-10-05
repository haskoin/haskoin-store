{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE MultiWayIf            #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
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
    , BlockTx(..)
    , XPubBal(..)
    , XPubUnspent(..)
    , Balance(..)
    , PeerInformation(..)
    , HealthCheck(..)
    , PubExcept(..)
    , Event(..)
    , TxAfterHeight(..)
    , JsonSerial(..)
    , BinSerial(..)
    , Except(..)
    , TxId(..)
    , UnixTime
    , BlockPos
    , BlockDB(..)
    , LayeredDB(..)
    , WebConfig(..)
    , MaxLimits(..)
    , Offset
    , Limit
    , newLayeredDB
    , withStore
    , runWeb
    , store
    , getBestBlock
    , getBlocksAtHeight
    , getBlock
    , getTransaction
    , getTxData
    , getSpenders
    , getSpender
    , fromTransaction
    , toTransaction
    , getBalance
    , getMempool
    , getAddressUnspents
    , getAddressUnspentsLimit
    , getAddressesUnspentsLimit
    , getAddressTxs
    , getAddressTxsFull
    , getAddressTxsLimit
    , getAddressesTxsFull
    , getAddressesTxsLimit
    , getPeersInformation
    , xpubBals
    , xpubUnspent
    , xpubUnspentLimit
    , xpubSummary
    , publishTx
    , transactionData
    , isCoinbase
    , confirmed
    , cbAfterHeight
    , healthCheck
    , withBlockMem
    , withLayeredDB
    ) where

import           Conduit
import           Control.Monad
import qualified Control.Monad.Except               as E
import           Control.Monad.Logger
import           Control.Monad.Trans.Maybe
import           Data.Foldable
import           Data.Function
import qualified Data.HashMap.Strict                as H
import           Data.List
import           Data.Maybe
import           Data.Serialize                     (decode)
import qualified Data.Text                          as T
import           Data.Word                          (Word32)
import           Database.RocksDB                   as R
import           Haskoin
import           Haskoin.Node
import           Network.Haskoin.Store.Block
import           Network.Haskoin.Store.Data
import           Network.Haskoin.Store.Data.Cached
import           Network.Haskoin.Store.Data.Memory
import           Network.Haskoin.Store.Data.RocksDB
import           Network.Haskoin.Store.Messages
import           Network.Haskoin.Store.Web
import           Network.Socket                     (SockAddr (..))
import           NQE
import           System.Random
import           UnliftIO

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
    -> Inbox BlockMessage
    -> m ()
store cfg mgri chi bsi = do
    let ncfg =
            NodeConfig
                { nodeConfMaxPeers = storeConfMaxPeers cfg
                , nodeConfDB = blockDB . layeredDB $ storeConfDB cfg
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
