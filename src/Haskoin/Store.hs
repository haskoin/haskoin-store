module Haskoin.Store
    ( Store(..)
    , BlockStore
    , StoreConfig(..)
    , StoreRead(..)
    , StoreWrite(..)
    , StoreStream(..)
    , StoreEvent(..)
    , BlockData(..)
    , Transaction(..)
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
    , WebConfig(..)
    , MaxLimits(..)
    , Timeouts(..)
    , Offset
    , Limit
    , withStore
    , runWeb
    , store
    , getTransaction
    , fromTransaction
    , toTransaction
    , transactionData
    , getAddressUnspentsLimit
    , getAddressesUnspentsLimit
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
    , isCoinbase
    , confirmed
    , cbAfterHeight
    , healthCheck
    , withBlockMem
    , withRocksDB
    , connectRocksDB
    , initRocksDB
    ) where

import           Control.Monad                      (unless, when)
import           Control.Monad.Logger               (MonadLoggerIO)
import           Data.Serialize                     (decode)
import           Haskoin                            (BlockHash (..), Inv (..),
                                                     InvType (..),
                                                     InvVector (..),
                                                     Message (..),
                                                     MessageCommand (..),
                                                     NetworkAddress (..),
                                                     NotFound (..), Pong (..),
                                                     Reject (..), TxHash (..),
                                                     VarString (..),
                                                     sockToHostAddress)
import           Haskoin.Node                       (ChainEvent (..),
                                                     ChainMessage,
                                                     ManagerMessage,
                                                     NodeConfig (..),
                                                     NodeEvent (..),
                                                     PeerEvent (..), node)
import           Network.Haskoin.Store.Block        (blockStore)
import           Network.Haskoin.Store.Data.Memory  (withBlockMem)
import           Network.Haskoin.Store.Data.RocksDB (connectRocksDB,
                                                     initRocksDB, withRocksDB)
import           Network.Haskoin.Store.Data.Types   (Balance (..),
                                                     BinSerial (..),
                                                     BlockConfig (..),
                                                     BlockDB (..),
                                                     BlockData (..),
                                                     BlockMessage (..),
                                                     BlockPos, BlockRef (..),
                                                     BlockStore, BlockTx (..),
                                                     Event (..),
                                                     HealthCheck (..),
                                                     JsonSerial (..), Limit,
                                                     Offset,
                                                     PeerInformation (..),
                                                     PubExcept (..),
                                                     Spender (..), Store (..),
                                                     StoreConfig (..),
                                                     StoreEvent (..),
                                                     StoreRead (..),
                                                     StoreStream (..),
                                                     StoreWrite (..),
                                                     Transaction (..),
                                                     TxAfterHeight (..),
                                                     TxId (..), UnixTime,
                                                     Unspent (..), XPubBal (..),
                                                     XPubUnspent (..),
                                                     confirmed, fromTransaction,
                                                     getTransaction, isCoinbase,
                                                     toTransaction,
                                                     transactionData)
import           Network.Haskoin.Store.Web          (Except (..),
                                                     MaxLimits (..),
                                                     Timeouts (..),
                                                     WebConfig (..),
                                                     cbAfterHeight,
                                                     getAddressTxsFull,
                                                     getAddressTxsLimit,
                                                     getAddressUnspentsLimit,
                                                     getAddressesTxsFull,
                                                     getAddressesTxsLimit,
                                                     getAddressesUnspentsLimit,
                                                     getPeersInformation,
                                                     healthCheck, publishTx,
                                                     runWeb, xpubBals,
                                                     xpubSummary, xpubUnspent,
                                                     xpubUnspentLimit)
import           Network.Socket                     (SockAddr (..))
import           NQE                                (Inbox, Listen,
                                                     Process (..),
                                                     inboxToMailbox, newInbox,
                                                     sendSTM, withProcess)
import           UnliftIO                           (MonadUnliftIO, link,
                                                     withAsync)

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
                , nodeConfDB = blockDB (storeConfDB cfg)
                , nodeConfPeers = storeConfInitPeers cfg
                , nodeConfDiscover = storeConfDiscover cfg
                , nodeConfEvents = storeDispatch b l
                , nodeConfNetAddr =
                      NetworkAddress 0 (sockToHostAddress (SockAddrInet 0 0))
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
