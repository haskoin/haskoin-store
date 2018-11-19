{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiWayIf #-}
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
    , XPubTx(..)
    , XPubBal(..)
    , XPubUnspent(..)
    , Balance(..)
    , PeerInformation(..)
    , withStore
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
    , getAddressTxs
    , getPeersInformation
    , xpubTxs
    , xpubBals
    , xpubUnspent
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
    , xPubTxToJSON
    , xPubTxToEncoding
    , xPubBalToJSON
    , xPubBalToEncoding
    , xPubUnspentToJSON
    , xPubUnspentToEncoding
    , cbAfterHeight
    , mergeSourcesBy
    ) where

import           Conduit
import           Control.Monad.Except
import           Control.Monad.Logger
import           Control.Monad.Trans.Maybe
import           Data.Foldable
import           Data.Function
import           Data.List
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

xpubAddrs ::
       (Monad m, StoreStream i m)
    => i
    -> XPubKey
    -> m [(Address, SoftPath)]
xpubAddrs i k = (<>) <$> go 0 0 <*> go 1 0
  where
    go m n = do
        let g a = not <$> runConduit (getAddressTxs i a .| nullC)
        t <- or <$> mapM (g . fst) (as m n)
        if t
            then (as m n <>) <$> go m (n + 100)
            else return []
    as m n =
        map
            (\(a, _, n') -> (a, Deriv :/ m :/ n'))
            (take 100 (deriveAddrs (pubSubKey k m) n))

xpubTxs ::
       (Monad m, StoreStream i m)
    => i
    -> XPubKey
    -> ConduitT () XPubTx m ()
xpubTxs i xpub = do
    as <- lift $ xpubAddrs i xpub
    let cds = map (uncurry cnd) as
    mergeSourcesBy (compare `on` (addressTxBlock . xPubTx)) cds
  where
    cnd a p = getAddressTxs i a .| mapC (f p)
    f p t = XPubTx {xPubTxPath = pathToList p, xPubTx = t}

xpubBals ::
       (Monad m, StoreStream i m, BalanceRead i m)
    => i
    -> XPubKey
    -> m [XPubBal]
xpubBals i xpub = do
    as <- xpubAddrs i xpub
    fmap catMaybes . forM as $ \(a, p) ->
        getBalance i a >>= \case
            Nothing -> return Nothing
            Just b ->
                return $ Just XPubBal {xPubBalPath = pathToList p, xPubBal = b}

xpubUnspent ::
       (Monad m, StoreStream i m, StoreRead i m)
    => i
    -> XPubKey
    -> ConduitT () XPubUnspent m ()
xpubUnspent i xpub = do
    as <- lift $ xpubAddrs i xpub
    let cds = map (uncurry cnd) as
    mergeSourcesBy (compare `on` (unspentBlock . xPubUnspent)) cds
  where
    cnd a p = getAddressUnspents i a .| mapC (f p)
    f p t =
        XPubUnspent
            {xPubUnspentPath = pathToList p, xPubUnspent = t}

-- | Check if any of the ancestors of this transaction is a coinbase after the
-- specified height. Returns 'Nothing' if answer cannot be computed before
-- hitting limits.
cbAfterHeight ::
       (Monad m, StoreRead i m)
    => i
    -> Int
    -> BlockHeight
    -> TxHash
    -> m (Maybe Bool)
cbAfterHeight _ 0 _ _ = return Nothing

cbAfterHeight i d h t =
    runMaybeT $ do
        tx <- MaybeT $ getTransaction i t
        if any isCoinbase (transactionInputs tx)
            then return $ blockRefHeight (transactionBlock tx) > h
            else case transactionBlock tx of
                     BlockRef {blockRefHeight = b}
                         | b <= h -> return False
                     _ ->
                         r . nub $
                         map (outPointHash . inputPoint) (transactionInputs tx)
  where
    r [] = return False
    r (n:ns) = do
        x <- MaybeT $ cbAfterHeight i (d - 1) h n
        if x
            then return True
            else r ns

-- Snatched from:
-- https://github.com/cblp/conduit-merge/blob/master/src/Data/Conduit/Merge.hs
mergeSourcesBy ::
       (Foldable f, Monad m)
    => (a -> a -> Ordering)
    -> f (ConduitT () a m ())
    -> ConduitT i a m ()
mergeSourcesBy f = mergeSealed . fmap sealConduitT . toList
  where
    mergeSealed sources = do
        prefetchedSources <- lift $ traverse ($$++ await) sources
        go [(a, s) | (s, Just a) <- prefetchedSources]
    go [] = pure ()
    go sources = do
        let (a, src1):sources1 = sortBy (f `on` fst) sources
        yield a
        (src2, mb) <- lift $ src1 $$++ await
        let sources2 =
                case mb of
                    Nothing -> sources1
                    Just b  -> (b, src2) : sources1
        go sources2
