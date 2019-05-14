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
    , StartFrom(..)
    , UnixTime
    , BlockPos
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
    , getMempoolLimit
    , getAddressUnspents
    , getAddressUnspentsLimit
    , getAddressesUnspentsLimit
    , getAddressTxs
    , getAddressTxsFull
    , getAddressTxsLimit
    , getAddressesTxsFull
    , getAddressesTxsLimit
    , getPeersInformation
    , xpubTxs
    , xpubTxsLimit
    , xpubTxsFull
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
    , mergeSourcesBy
    , withBlockDB
    , withBlockSTM
    , withBalanceSTM
    , withUnspentSTM
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
import           Network.Haskoin.Store.Data.RocksDB
import           Network.Haskoin.Store.Data.STM
import           Network.Haskoin.Store.Messages
import           Network.Socket                     (SockAddr (..))
import           NQE
import           System.Random
import           UnliftIO

data PubExcept
    = PubNoPeers
    | PubReject RejectCode
    | PubTimeout
    | PubNotFound
    | PubPeerDisconnected
    deriving Eq

instance Show PubExcept where
    show PubNoPeers = "no peers"
    show (PubReject c) =
        "rejected: " <>
        case c of
            RejectMalformed       -> "malformed"
            RejectInvalid         -> "invalid"
            RejectObsolete        -> "obsolete"
            RejectDuplicate       -> "duplicate"
            RejectNonStandard     -> "not standard"
            RejectDust            -> "dust"
            RejectInsufficientFee -> "insufficient fee"
            RejectCheckpoint      -> "checkpoint"
    show PubTimeout = "timeout"
    show PubNotFound = "not found"
    show PubPeerDisconnected = "peer disconnected"

instance Exception PubExcept

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

healthCheck ::
       (MonadUnliftIO m, StoreRead m)
    => Network
    -> Manager
    -> Chain
    -> m HealthCheck
healthCheck net mgr ch = do
    n <- timeout (5 * 1000 * 1000) $ chainGetBest ch
    b <-
        runMaybeT $ do
            h <- MaybeT getBestBlock
            MaybeT $ getBlock h
    p <- timeout (5 * 1000 * 1000) $ managerGetPeers mgr
    let k = isNothing n || isNothing b || maybe False (not . null) p
        s =
            isJust $ do
                x <- n
                y <- b
                guard $ nodeHeight x - blockDataHeight y <= 1
    return
        HealthCheck
            { healthBlockBest = headerHash . blockDataHeader <$> b
            , healthBlockHeight = blockDataHeight <$> b
            , healthHeaderBest = headerHash . nodeHeader <$> n
            , healthHeaderHeight = nodeHeight <$> n
            , healthPeers = length <$> p
            , healthNetwork = getNetworkName net
            , healthOK = k
            , healthSynced = s
            }

-- | Publish a new transaction to the network.
publishTx ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Network
    -> Publisher StoreEvent
    -> Store
    -> DB
    -> Tx
    -> m (Either PubExcept ())
publishTx net pub st db tx = do
    $(logDebugS) "PubTx" $
        "Preparing to publish tx: " <> txHashToHex (txHash tx)
    e <- withSubscription pub $ \s ->
        withBlockDB defaultReadOptions db $
        getTransaction (txHash tx) >>= \case
            Just _ -> do
                $(logErrorS) "PubTx" $
                    "Tx already in DB: " <> txHashToHex (txHash tx)
                return $ Right ()
            Nothing ->
                E.runExceptT $ do
                    $(logDebugS) "PubTx" $ "Getting peers from manager..."
                    managerGetPeers (storeManager st) >>= \case
                        [] -> do
                            $(logErrorS) "PubTx" $ "No peers connected."
                            E.throwError PubNoPeers
                        OnlinePeer { onlinePeerMailbox = p
                                   , onlinePeerAddress = a
                                   }:_ -> do
                            $(logDebugS) "PubTx" $
                                "Sending tx " <> txHashToHex (txHash tx) <>
                                " to peer " <>
                                T.pack (show a)
                            MTx tx `sendMessage` p
                            let t =
                                    if getSegWit net
                                        then InvWitnessTx
                                        else InvTx
                            sendMessage
                                (MGetData
                                     (GetData
                                          [InvVector t (getTxHash (txHash tx))]))
                                p
                            f p s
    $(logDebugS) "PubTx" $ "Finished for tx: " <> txHashToHex (txHash tx)
    return e
  where
    t = 15 * 1000 * 1000
    f p s = do
        $(logDebugS) "PubTx" $
            "Waiting for peer to relay tx " <> txHashToHex (txHash tx)
        liftIO (timeout t (E.runExceptT (g p s))) >>= \case
            Nothing -> do
                $(logErrorS) "PubTx" $
                    "Peer did not relay tx " <> txHashToHex (txHash tx)
                E.throwError PubTimeout
            Just (Left e) -> do
                $(logErrorS) "PubTx" $
                    "Error publishing tx " <> txHashToHex (txHash tx) <>
                    T.pack (show e)
                E.throwError e
            Just (Right ()) -> do
                $(logDebugS) "PubTx" $
                    "Success publishing tx " <> txHashToHex (txHash tx)
    g p s =
        receive s >>= \case
            StoreTxReject p' h' c _
                | p == p' && h' == txHash tx -> E.throwError $ PubReject c
            StorePeerDisconnected p' _
                | p == p' -> E.throwError PubPeerDisconnected
            StoreMempoolNew h'
                | h' == txHash tx -> return ()
            _ -> g p s

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

xpubBals :: (Monad m, BalanceRead m) => XPubKey -> m [XPubBal]
xpubBals xpub = (<>) <$> go 0 0 <*> go 1 0
  where
    go m n = do
        xs <- catMaybes <$> mapM (uncurry b) (as m n)
        case xs of
            [] -> return []
            _  -> (xs <>) <$> go m (n + 20)
    b a p =
        getBalance a >>= \case
            Nothing -> return Nothing
            Just b' -> return $ Just XPubBal {xPubBalPath = p, xPubBal = b'}
    as m n =
        map
            (\(a, _, n') -> (a, [m, n']))
            (take 20 (deriveAddrs (pubSubKey xpub m) n))

xpubTxs ::
       (Monad m, BalanceRead m, StoreStream m)
    => Maybe BlockRef
    -> [XPubBal]
    -> ConduitT () BlockTx m ()
xpubTxs m bs = do
    xs <-
        forM bs $ \XPubBal {xPubBal = b} ->
            return $ getAddressTxs (balanceAddress b) m
    mergeSourcesBy (flip compare `on` blockTxBlock) xs .| dedup

xpubTxsLimit ::
       (Monad m, BalanceRead m, StoreStream m)
    => Maybe Word32
    -> StartFrom
    -> [XPubBal]
    -> ConduitT () BlockTx m ()
xpubTxsLimit l s bs = do
    xpubTxs (mbr s) bs .| (offset s >> limit l)

xpubTxsFull ::
       (Monad m, BalanceRead m, StoreStream m, StoreRead m)
    => Maybe Word32
    -> StartFrom
    -> [XPubBal]
    -> ConduitT () Transaction m ()
xpubTxsFull l s bs =
    xpubTxsLimit l s bs .| concatMapMC (getTransaction . blockTxHash)

xpubUnspent ::
       (Monad m, StoreStream m, BalanceRead m, StoreRead m)
    => Maybe BlockRef
    -> XPubKey
    -> ConduitT () XPubUnspent m ()
xpubUnspent mbr xpub = do
    bals <- lift $ xpubBals xpub
    xs <-
        forM bals $ \XPubBal {xPubBalPath = p, xPubBal = b} ->
            return $ getAddressUnspents (balanceAddress b) mbr .| mapC (f p)
    mergeSourcesBy (flip compare `on` (unspentBlock . xPubUnspent)) xs
  where
    f p t = XPubUnspent {xPubUnspentPath = p, xPubUnspent = t}

xpubUnspentLimit ::
       (Monad m, StoreStream m, BalanceRead m, StoreRead m)
    => Maybe Word32
    -> StartFrom
    -> XPubKey
    -> ConduitT () XPubUnspent m ()
xpubUnspentLimit l s x =
    xpubUnspent (mbr s) x .| (offset s >> limit l)

xpubSummary ::
       (Monad m, StoreStream m, BalanceRead m, StoreRead m)
    => Maybe Word32
    -> StartFrom
    -> XPubKey
    -> m XPubSummary
xpubSummary l s x = do
    bs <- xpubBals x
    let f XPubBal {xPubBalPath = p, xPubBal = Balance {balanceAddress = a}} =
            (a, p)
        pm = H.fromList $ map f bs
    txs <- runConduit $ xpubTxsFull l s bs .| sinkList
    let as =
            nub
                [ a
                | t <- txs
                , let is = transactionInputs t
                , let os = transactionOutputs t
                , let ais =
                          mapMaybe
                              (eitherToMaybe . scriptToAddressBS . inputPkScript)
                              is
                , let aos =
                          mapMaybe
                              (eitherToMaybe . scriptToAddressBS . outputScript)
                              os
                , a <- ais ++ aos
                ]
        ps = H.fromList $ mapMaybe (\a -> (a, ) <$> H.lookup a pm) as
        ex = foldl max 0 [i | XPubBal {xPubBalPath = [x, i]} <- bs, x == 0]
        ch = foldl max 0 [i | XPubBal {xPubBalPath = [x, i]} <- bs, x == 1]
    return
        XPubSummary
            { xPubSummaryReceived =
                  sum (map (balanceTotalReceived . xPubBal) bs)
            , xPubSummaryConfirmed = sum (map (balanceAmount . xPubBal) bs)
            , xPubSummaryZero = sum (map (balanceZero . xPubBal) bs)
            , xPubSummaryPaths = ps
            , xPubSummaryTxs = txs
            , xPubChangeIndex = ch
            , xPubExternalIndex = ex
            }

-- | Check if any of the ancestors of this transaction is a coinbase after the
-- specified height. Returns 'Nothing' if answer cannot be computed before
-- hitting limits.
cbAfterHeight ::
       (Monad m, StoreRead m)
    => Int -- ^ how many ancestors to test before giving up
    -> BlockHeight
    -> TxHash
    -> m TxAfterHeight
cbAfterHeight d h t
    | d <= 0 = return $ TxAfterHeight Nothing
    | otherwise = TxAfterHeight <$> runMaybeT (snd <$> tst d t)
  where
    tst e x
        | e <= 0 = MaybeT $ return Nothing
        | otherwise = do
            let e' = e - 1
            tx <- MaybeT $ getTransaction x
            if any isCoinbase (transactionInputs tx)
                then return (e', blockRefHeight (transactionBlock tx) > h)
                else case transactionBlock tx of
                         BlockRef {blockRefHeight = b}
                             | b <= h -> return (e', False)
                         _ ->
                             r e' . nub $
                             map
                                 (outPointHash . inputPoint)
                                 (transactionInputs tx)
    r e [] = return (e, False)
    r e (n:ns) = do
        (e', s) <- tst e n
        if s
            then return (e', True)
            else r e' ns

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

getMempoolLimit ::
       (Monad m, StoreStream m)
    => Maybe Word32
    -> StartFrom
    -> ConduitT () TxHash m ()
getMempoolLimit _ StartBlock {} = return ()
getMempoolLimit l (StartMem t) =
    getMempool (Just t) .| mapC snd .| limit l
getMempoolLimit l s =
    getMempool Nothing .| mapC snd .| (offset s >> limit l)

getAddressTxsLimit ::
       (Monad m, StoreStream m)
    => Maybe Word32
    -> StartFrom
    -> Address
    -> ConduitT () BlockTx m ()
getAddressTxsLimit l s a =
    getAddressTxs a (mbr s) .| (offset s >> limit l)

getAddressTxsFull ::
       (Monad m, StoreStream m, StoreRead m)
    => Maybe Word32
    -> StartFrom
    -> Address
    -> ConduitT () Transaction m ()
getAddressTxsFull l s a =
    getAddressTxsLimit l s a .| concatMapMC (getTransaction . blockTxHash)

getAddressesTxsLimit ::
       (Monad m, StoreStream m)
    => Maybe Word32
    -> StartFrom
    -> [Address]
    -> ConduitT () BlockTx m ()
getAddressesTxsLimit l s as =
    mergeSourcesBy
        (flip compare `on` blockTxBlock)
        (map (`getAddressTxs` mbr s) as) .|
    dedup .|
    (offset s >> limit l)

getAddressesTxsFull ::
       (Monad m, StoreStream m, StoreRead m)
    => Maybe Word32
    -> StartFrom
    -> [Address]
    -> ConduitT () Transaction m ()
getAddressesTxsFull l s as =
    mergeSourcesBy
        (flip compare `on` blockTxBlock)
        (map (`getAddressTxs` mbr s) as) .|
    dedup .|
    (offset s >> limit l) .|
    concatMapMC (getTransaction . blockTxHash)

getAddressUnspentsLimit ::
       (Monad m, StoreStream m)
    => Maybe Word32
    -> StartFrom
    -> Address
    -> ConduitT () Unspent m ()
getAddressUnspentsLimit l s a =
    getAddressUnspents a (mbr s) .| (offset s >> limit l)

getAddressesUnspentsLimit ::
       (Monad m, StoreStream m)
    => Maybe Word32
    -> StartFrom
    -> [Address]
    -> ConduitT () Unspent m ()
getAddressesUnspentsLimit l s as =
    mergeSourcesBy
        (flip compare `on` unspentBlock)
        (map (`getAddressUnspents` mbr s) as) .|
    (offset s >> limit l)

offset :: Monad m => StartFrom -> ConduitT i i m ()
offset (StartOffset o) = dropC (fromIntegral o)
offset _               = return ()

limit :: Monad m => Maybe Word32 -> ConduitT i i m ()
limit Nothing  = mapC id
limit (Just n) = takeC (fromIntegral n)

mbr :: StartFrom -> Maybe BlockRef
mbr (StartBlock h p) = Just (BlockRef h p)
mbr (StartMem t)     = Just (MemRef t)
mbr (StartOffset _)  = Nothing

dedup :: (Eq i, Monad m) => ConduitT i i m ()
dedup =
    let dd Nothing =
            await >>= \case
                Just x -> do
                    yield x
                    dd (Just x)
                Nothing -> return ()
        dd (Just x) =
            await >>= \case
                Just y
                    | x == y -> dd (Just x)
                    | otherwise -> do
                        yield y
                        dd (Just y)
                Nothing -> return ()
      in dd Nothing
