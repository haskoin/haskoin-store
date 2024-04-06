{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}

module Haskoin.Store.Common
  ( Limits (..),
    Start (..),
    StoreReadBase (..),
    StoreReadExtra (..),
    StoreWrite (..),
    StoreEvent (..),
    PubExcept (..),
    DataMetrics (..),
    getActiveBlock,
    getActiveTxData,
    getDefaultBalance,
    getTransaction,
    getNumTransaction,
    blockAtOrAfter,
    blockAtOrBefore,
    blockAtOrAfterMTP,
    xPubSummary,
    deriveAddresses,
    deriveFunction,
    deOffset,
    applyLimits,
    applyLimitsC,
    applyLimit,
    applyLimitC,
    sortTxs,
    nub',
    microseconds,
    streamThings,
    joinDescStreams,
    createDataMetrics,
  )
where

import Conduit
  ( ConduitT,
    await,
    dropC,
    mapC,
    sealConduitT,
    takeC,
    yield,
    ($$++),
  )
import Control.DeepSeq (NFData)
import Control.Exception (Exception)
import Control.Monad (forM)
import Control.Monad.Trans (lift)
import Control.Monad.Trans.Maybe (MaybeT (..), runMaybeT)
import Control.Monad.Trans.Reader (runReaderT)
import Data.ByteString (ByteString)
import Data.Default (Default (..))
import qualified Data.Graph as G
import qualified Data.HashSet as H
import qualified Data.HashMap.Strict as M
import Data.Hashable (Hashable)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as I
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, mapMaybe)
import Data.Ord (Down (..))
import Data.Serialize (Serialize (..))
import Data.Time.Clock.System
  ( getSystemTime,
    systemNanoseconds,
    systemSeconds,
  )
import Data.Word (Word32, Word64)
import GHC.Generics (Generic)
import Haskoin
  ( Address,
    BlockHash,
    BlockHeader (..),
    BlockHeight,
    BlockNode (..),
    KeyIndex,
    Network (..),
    OutPoint (..),
    RejectCode (..),
    Tx (..),
    TxHash (..),
    TxIn (..),
    XPubKey (..),
    deriveAddr,
    deriveCompatWitnessAddr,
    deriveWitnessAddr,
    firstGreaterOrEqual,
    headerHash,
    lastSmallerOrEqual,
    mtp,
    pubSubKey,
    txHash,
  )
import Haskoin.Node (Chain, Peer)
import Haskoin.Store.Data
  ( Balance (..),
    BlockData (..),
    DeriveType (..),
    Spender,
    Transaction (..),
    TxData (..),
    TxRef (..),
    UnixTime,
    Unspent (..),
    XPubBal (..),
    XPubSpec (..),
    XPubSummary (..),
    XPubUnspent (..),
    nullBalance,
    toTransaction,
    zeroBalance,
  )
import qualified System.Metrics as Metrics
import System.Metrics.Counter (Counter)
import qualified System.Metrics.Counter as Counter
import UnliftIO (MonadIO, liftIO)

type DeriveAddr = XPubKey -> KeyIndex -> Address

type Offset = Word32

type Limit = Word32

data Start
  = AtTx {atTxHash :: !TxHash}
  | AtBlock {atBlockHeight :: !BlockHeight}
  deriving (Eq, Show)

data Limits = Limits
  { limit :: !Word32,
    offset :: !Word32,
    start :: !(Maybe Start)
  }
  deriving (Eq, Show)

defaultLimits :: Limits
defaultLimits = Limits {limit = 0, offset = 0, start = Nothing}

instance Default Limits where
  def = defaultLimits

class Monad m => StoreReadBase m where
  getNetwork :: m Network
  getBestBlock :: m (Maybe BlockHash)
  getBlocksAtHeight :: BlockHeight -> m [BlockHash]
  getBlock :: BlockHash -> m (Maybe BlockData)
  getTxData :: TxHash -> m (Maybe TxData)
  getSpender :: OutPoint -> m (Maybe Spender)
  getBalance :: Address -> m (Maybe Balance)
  getUnspent :: OutPoint -> m (Maybe Unspent)
  getMempool :: m [(UnixTime, TxHash)]

class StoreReadBase m => StoreReadExtra m where
  getAddressesTxs :: [Address] -> Limits -> m [TxRef]
  getAddressesUnspents :: [Address] -> Limits -> m [Unspent]
  getInitialGap :: m Word32
  getMaxGap :: m Word32
  getNumTxData :: Word64 -> m [TxData]
  getBalances :: [Address] -> m [Balance]
  getAddressTxs :: Address -> Limits -> m [TxRef]
  getAddressUnspents :: Address -> Limits -> m [Unspent]
  xPubBals :: XPubSpec -> m [XPubBal]
  xPubUnspents :: XPubSpec -> [XPubBal] -> Limits -> m [XPubUnspent]
  xPubTxs :: XPubSpec -> [XPubBal] -> Limits -> m [TxRef]
  xPubTxCount :: XPubSpec -> [XPubBal] -> m Word32

class StoreWrite m where
  setBest :: BlockHash -> m ()
  insertBlock :: BlockData -> m ()
  setBlocksAtHeight :: [BlockHash] -> BlockHeight -> m ()
  insertTx :: TxData -> m ()
  insertAddrTx :: Address -> TxRef -> m ()
  deleteAddrTx :: Address -> TxRef -> m ()
  insertAddrUnspent :: Address -> Unspent -> m ()
  deleteAddrUnspent :: Address -> Unspent -> m ()
  addToMempool :: TxHash -> UnixTime -> m ()
  deleteFromMempool :: TxHash -> m ()
  setBalance :: Balance -> m ()
  insertUnspent :: Unspent -> m ()
  deleteUnspent :: OutPoint -> m ()

getActiveBlock :: StoreReadExtra m => BlockHash -> m (Maybe BlockData)
getActiveBlock bh =
  getBlock bh >>= \case
    Just b | blockDataMainChain b -> return (Just b)
    _ -> return Nothing

getActiveTxData :: StoreReadBase m => TxHash -> m (Maybe TxData)
getActiveTxData th =
  getTxData th >>= \case
    Just td | not (txDataDeleted td) -> return (Just td)
    _ -> return Nothing

getDefaultBalance :: StoreReadBase m => Address -> m Balance
getDefaultBalance a =
  getBalance a >>= \case
    Nothing -> return $ zeroBalance a
    Just b -> return b

deriveAddresses :: DeriveAddr -> XPubKey -> Word32 -> [(Word32, Address)]
deriveAddresses derive xpub start = map (\i -> (i, derive xpub i)) [start ..]

deriveFunction :: DeriveType -> DeriveAddr
deriveFunction DeriveNormal i = fst . deriveAddr i
deriveFunction DeriveP2SH i = fst . deriveCompatWitnessAddr i
deriveFunction DeriveP2WPKH i = fst . deriveWitnessAddr i

xPubSummary :: XPubSpec -> [XPubBal] -> XPubSummary
xPubSummary _xspec xbals =
  XPubSummary
    { xPubSummaryConfirmed = sum (map (balanceAmount . xPubBal) bs),
      xPubSummaryZero = sum (map (balanceZero . xPubBal) bs),
      xPubSummaryReceived = rx,
      xPubUnspentCount = uc,
      xPubChangeIndex = ch,
      xPubExternalIndex = ex
    }
  where
    bs = filter (not . nullBalance . xPubBal) xbals
    ex = foldl max 0 [i | XPubBal {xPubBalPath = [0, i]} <- bs]
    ch = foldl max 0 [i | XPubBal {xPubBalPath = [1, i]} <- bs]
    uc = sum [balanceUnspentCount (xPubBal b) | b <- bs]
    xt = [b | b@XPubBal {xPubBalPath = [0, _]} <- bs]
    rx = sum [balanceTotalReceived (xPubBal b) | b <- xt]

getTransaction ::
  (Monad m, StoreReadBase m) => TxHash -> m (Maybe Transaction)
getTransaction h = fmap toTransaction <$> getTxData h

getNumTransaction ::
  (Monad m, StoreReadExtra m) => Word64 -> m [Transaction]
getNumTransaction i = map toTransaction <$> getNumTxData i

blockAtOrAfter ::
  (MonadIO m, StoreReadExtra m) =>
  Chain ->
  UnixTime ->
  m (Maybe BlockData)
blockAtOrAfter ch q = runMaybeT $ do
  net <- lift getNetwork
  x <- MaybeT $ liftIO $ runReaderT (firstGreaterOrEqual net f) ch
  MaybeT $ getBlock (headerHash (nodeHeader x))
  where
    f x =
      let t = fromIntegral (blockTimestamp (nodeHeader x))
       in return $ t `compare` q

blockAtOrBefore ::
  (MonadIO m, StoreReadExtra m) =>
  Chain ->
  UnixTime ->
  m (Maybe BlockData)
blockAtOrBefore ch q = runMaybeT $ do
  net <- lift getNetwork
  x <- MaybeT $ liftIO $ runReaderT (lastSmallerOrEqual net f) ch
  MaybeT $ getBlock (headerHash (nodeHeader x))
  where
    f x =
      let t = fromIntegral (blockTimestamp (nodeHeader x))
       in return $ t `compare` q

blockAtOrAfterMTP ::
  (MonadIO m, StoreReadExtra m) =>
  Chain ->
  UnixTime ->
  m (Maybe BlockData)
blockAtOrAfterMTP ch q = runMaybeT $ do
  net <- lift getNetwork
  x <- MaybeT $ liftIO $ runReaderT (firstGreaterOrEqual net f) ch
  MaybeT $ getBlock (headerHash (nodeHeader x))
  where
    f x = do
      t <- fromIntegral <$> mtp x
      return $ t `compare` q

-- | Events that the store can generate.
data StoreEvent
  = StoreBestBlock !BlockHash
  | StoreMempoolNew !TxHash
  | StoreMempoolDelete !TxHash
  | StorePeerConnected !Peer
  | StorePeerDisconnected !Peer
  | StorePeerPong !Peer !Word64
  | StoreTxAnnounce !Peer ![TxHash]
  | StoreTxReject !Peer !TxHash !RejectCode !ByteString

data PubExcept
  = PubNoPeers
  | PubReject RejectCode
  | PubTimeout
  | PubPeerDisconnected
  deriving (Eq, NFData, Generic, Serialize)

instance Show PubExcept where
  show PubNoPeers = "no peers"
  show (PubReject c) =
    "rejected: "
      <> case c of
        RejectMalformed -> "malformed"
        RejectInvalid -> "invalid"
        RejectObsolete -> "obsolete"
        RejectDuplicate -> "duplicate"
        RejectNonStandard -> "not standard"
        RejectDust -> "dust"
        RejectInsufficientFee -> "insufficient fee"
        RejectCheckpoint -> "checkpoint"
  show PubTimeout = "peer timeout or silent rejection"
  show PubPeerDisconnected = "peer disconnected"

instance Exception PubExcept

applyLimits :: Limits -> [a] -> [a]
applyLimits Limits {..} = applyLimit limit . applyOffset offset

applyOffset :: Offset -> [a] -> [a]
applyOffset = drop . fromIntegral

applyLimit :: Limit -> [a] -> [a]
applyLimit 0 = id
applyLimit l = take (fromIntegral l)

deOffset :: Limits -> Limits
deOffset l = case limit l of
  0 -> l {offset = 0}
  _ -> l {limit = limit l + offset l, offset = 0}

applyLimitsC :: Monad m => Limits -> ConduitT i i m ()
applyLimitsC Limits {..} = applyOffsetC offset >> applyLimitC limit

applyOffsetC :: Monad m => Offset -> ConduitT i i m ()
applyOffsetC = dropC . fromIntegral

applyLimitC :: Monad m => Limit -> ConduitT i i m ()
applyLimitC 0 = mapC id
applyLimitC l = takeC (fromIntegral l)

sortTxs :: [Tx] -> [(Word32, Tx)]
sortTxs txs = ts
  where
    hm :: M.HashMap TxHash Int
    hm = M.fromList $ zip (map txHash txs) [0 ..]
    ns :: [(Tx, Int, [Int])]
    ns =
      let is tx = nub' $ map (outPointHash . prevOutput) (txIn tx)
          hs tx = mapMaybe (`M.lookup` hm) (is tx)
          tp i tx = (tx, i, hs tx)
       in zipWith tp [0 ..] txs
    (g, n, _) = G.graphFromEdges ns
    vs = G.reverseTopSort g
    ts =
      let f (tx, i, _) = (fromIntegral i, tx)
       in map (f . n) vs

nub' :: (Eq a, Hashable a) => [a] -> [a]
nub' = H.toList . H.fromList

microseconds :: MonadIO m => m Integer
microseconds =
  let f t =
        toInteger (systemSeconds t) * 1000000
          + toInteger (systemNanoseconds t) `div` 1000
   in liftIO $ f <$> getSystemTime

streamThings ::
  Monad m =>
  (Limits -> m [a]) ->
  Maybe (a -> TxHash) ->
  Limits ->
  ConduitT () a m ()
streamThings getit gettx limits =
  lift (getit limits) >>= \case
    [] -> return ()
    ls -> mapM_ yield ls >> go limits (last ls)
  where
    h l x = case gettx of
      Just g -> Just l {offset = 1, start = Just (AtTx (g x))}
      Nothing -> case limit l of
        0 -> Nothing
        _ -> Just l {offset = offset l + limit l}
    go l x = case h l x of
      Nothing -> return ()
      Just l' ->
        lift (getit l') >>= \case
          [] -> return ()
          ls -> mapM_ yield ls >> go l' (last ls)

joinDescStreams ::
  (Monad m, Ord a) =>
  [ConduitT () a m ()] ->
  ConduitT () a m ()
joinDescStreams xs = do
  let ss = map sealConduitT xs
  go Nothing =<< g ss
  where
    j (x, y) = (,[x]) <$> y
    g ss =
      let l = mapMaybe j <$> lift (traverse ($$++ await) ss)
       in Map.fromListWith (++) <$> l
    go m mp = case Map.lookupMax mp of
      Nothing -> return ()
      Just (x, ss) -> do
        case m of
          Nothing -> yield x
          Just x'
            | x == x' -> return ()
            | otherwise -> yield x
        mp1 <- g ss
        let mp2 = Map.deleteMax mp
            mp' = Map.unionWith (++) mp1 mp2
        go (Just x) mp'

data DataMetrics = DataMetrics
  { dataBestCount :: !Counter,
    dataBlockCount :: !Counter,
    dataTxCount :: !Counter,
    dataMempoolCount :: !Counter,
    dataBalanceCount :: !Counter,
    dataUnspentCount :: !Counter,
    dataAddrTxCount :: !Counter,
    dataXPubBals :: !Counter,
    dataXPubUnspents :: !Counter,
    dataXPubTxs :: !Counter,
    dataXPubTxCount :: !Counter
  }

createDataMetrics :: MonadIO m => Metrics.Store -> m DataMetrics
createDataMetrics s = liftIO $ do
  dataBestCount <- Metrics.createCounter "data.best_block" s
  dataBlockCount <- Metrics.createCounter "data.blocks" s
  dataTxCount <- Metrics.createCounter "data.txs" s
  dataMempoolCount <- Metrics.createCounter "data.mempool" s
  dataBalanceCount <- Metrics.createCounter "data.balances" s
  dataUnspentCount <- Metrics.createCounter "data.unspents" s
  dataAddrTxCount <- Metrics.createCounter "data.address_txs" s
  dataXPubBals <- Metrics.createCounter "data.xpub_balances" s
  dataXPubUnspents <- Metrics.createCounter "data.xpub_unspents" s
  dataXPubTxs <- Metrics.createCounter "data.xpub_txs" s
  dataXPubTxCount <- Metrics.createCounter "data.xpub_tx_count" s
  return DataMetrics {..}
