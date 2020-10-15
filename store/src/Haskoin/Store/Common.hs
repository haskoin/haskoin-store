{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TupleSections     #-}
module Haskoin.Store.Common
    ( Limits(..)
    , Start(..)
    , StoreReadBase(..)
    , StoreReadExtra(..)
    , StoreWrite(..)
    , StoreEvent(..)
    , PubExcept(..)
    , getActiveBlock
    , getActiveTxData
    , getDefaultBalance
    , getSpenders
    , xPubBalsTxs
    , xPubBalsUnspents
    , getTransaction
    , blockAtOrBefore
    , deOffset
    , applyLimits
    , applyLimitsC
    , sortTxs
    , nub'
    , microseconds
    ) where

import           Conduit                    (ConduitT, dropC, mapC, takeC)
import           Control.DeepSeq            (NFData)
import           Control.Exception          (Exception)
import           Control.Monad.Trans        (lift)
import           Control.Monad.Trans.Maybe  (MaybeT (..), runMaybeT)
import           Control.Monad.Trans.Reader (runReaderT)
import           Data.ByteString            (ByteString)
import           Data.Default               (Default (..))
import           Data.Function              (on)
import           Data.Hashable              (Hashable)
import qualified Data.HashSet               as H
import           Data.IntMap.Strict         (IntMap)
import qualified Data.IntMap.Strict         as I
import           Data.List                  (sortBy)
import           Data.Maybe                 (catMaybes)
import           Data.Serialize             (Serialize (..))
import           Data.Time.Clock.System     (getSystemTime, systemNanoseconds,
                                             systemSeconds)
import           Data.Word                  (Word32, Word64)
import           GHC.Generics               (Generic)
import           Haskoin                    (Address, BlockHash,
                                             BlockHeader (..), BlockHeight,
                                             BlockNode (..), KeyIndex,
                                             Network (..), OutPoint (..),
                                             RejectCode (..), Tx (..),
                                             TxHash (..), TxIn (..),
                                             XPubKey (..), deriveAddr,
                                             deriveCompatWitnessAddr,
                                             deriveWitnessAddr, headerHash,
                                             lastSmallerOrEqual, pubSubKey,
                                             txHash)
import           Haskoin.Node               (Chain, Peer)
import           Haskoin.Store.Data         (Balance (..), BlockData (..),
                                             DeriveType (..), Spender,
                                             Transaction, TxData (..),
                                             TxRef (..), UnixTime, Unspent (..),
                                             XPubBal (..), XPubSpec (..),
                                             XPubSummary (..), XPubUnspent (..),
                                             nullBalance, toTransaction,
                                             zeroBalance)
import           UnliftIO                   (MonadIO, liftIO)

type DeriveAddr = XPubKey -> KeyIndex -> Address

type Offset = Word32
type Limit = Word32

data Start = AtTx
    { atTxHash :: !TxHash
    }
    | AtBlock
    { atBlockHeight :: !BlockHeight
    }
    deriving (Eq, Show)

data Limits = Limits
    { limit  :: !Word32
    , offset :: !Word32
    , start  :: !(Maybe Start)
    }
    deriving (Eq, Show)

defaultLimits :: Limits
defaultLimits = Limits { limit = 0, offset = 0, start = Nothing }

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
    getBalances :: [Address] -> m [Balance]
    getBalances as =
        zipWith f as <$> mapM getBalance as
      where
        f a Nothing  = zeroBalance a
        f _ (Just b) = b
    getAddressesTxs :: [Address] -> Limits -> m [TxRef]
    getAddressTxs :: Address -> Limits -> m [TxRef]
    getAddressTxs a = getAddressesTxs [a]
    getAddressUnspents :: Address -> Limits -> m [Unspent]
    getAddressUnspents a = getAddressesUnspents [a]
    getAddressesUnspents :: [Address] -> Limits -> m [Unspent]
    xPubBals :: XPubSpec -> m [XPubBal]
    xPubBals xpub = do
        igap <- getInitialGap
        gap <- getMaxGap
        ext1 <- derive_until_gap gap 0 (take (fromIntegral igap) (aderiv 0 0))
        if all (nullBalance . xPubBal) ext1
            then return []
            else do
                ext2 <- derive_until_gap gap 0 (aderiv 0 igap)
                chg <- derive_until_gap gap 1 (aderiv 1 0)
                return (ext1 <> ext2 <> chg)
      where
        aderiv m =
            deriveAddresses
                (deriveFunction (xPubDeriveType xpub))
                (pubSubKey (xPubSpecKey xpub) m)
        xbalance m b n = XPubBal {xPubBalPath = [m, n], xPubBal = b}
        derive_until_gap _ _ [] = return []
        derive_until_gap gap m as = do
            let (as1, as2) = splitAt (fromIntegral gap) as
            bs <- getBalances (map snd as1)
            let xbs = zipWith (xbalance m) bs (map fst as1)
            if all nullBalance bs
                then return xbs
                else (xbs <>) <$> derive_until_gap gap m as2
    xPubSummary :: XPubSpec -> m XPubSummary
    xPubSummary xpub = do
        bs <- filter (not . nullBalance . xPubBal) <$> xPubBals xpub
        let ex = foldl max 0 [i | XPubBal {xPubBalPath = [0, i]} <- bs]
            ch = foldl max 0 [i | XPubBal {xPubBalPath = [1, i]} <- bs]
            uc =
                sum
                    [ c
                    | XPubBal {xPubBal = Balance {balanceUnspentCount = c}} <-
                          bs
                    ]
            xt = [b | b@XPubBal {xPubBalPath = [0, _]} <- bs]
            rx =
                sum
                    [ r
                    | XPubBal {xPubBal = Balance {balanceTotalReceived = r}} <-
                          xt
                    ]
        return
            XPubSummary
                { xPubSummaryConfirmed = sum (map (balanceAmount . xPubBal) bs)
                , xPubSummaryZero = sum (map (balanceZero . xPubBal) bs)
                , xPubSummaryReceived = rx
                , xPubUnspentCount = uc
                , xPubChangeIndex = ch
                , xPubExternalIndex = ex
                }
    xPubUnspents :: XPubSpec -> Limits -> m [XPubUnspent]
    xPubUnspents xpub limits = do
        xs <- filter positive <$> xPubBals xpub
        sortBy (compare `on` unsblock) . applyLimits limits <$> xUns limits xs
      where
        unsblock = unspentBlock . xPubUnspent
        positive XPubBal {xPubBal = Balance {balanceUnspentCount = c}} = c > 0
    xPubTxs :: XPubSpec -> Limits -> m [TxRef]
    xPubTxs xpub limits = do
        bs <- xPubBals xpub
        let as = map (balanceAddress . xPubBal) bs
        getAddressesTxs as limits
    getMaxGap :: m Word32
    getInitialGap :: m Word32

class StoreWrite m where
    setBest :: BlockHash -> m ()
    insertBlock :: BlockData -> m ()
    setBlocksAtHeight :: [BlockHash] -> BlockHeight -> m ()
    insertTx :: TxData -> m ()
    insertSpender :: OutPoint -> Spender -> m ()
    deleteSpender :: OutPoint -> m ()
    insertAddrTx :: Address -> TxRef -> m ()
    deleteAddrTx :: Address -> TxRef -> m ()
    insertAddrUnspent :: Address -> Unspent -> m ()
    deleteAddrUnspent :: Address -> Unspent -> m ()
    addToMempool :: TxHash -> UnixTime -> m ()
    deleteFromMempool :: TxHash -> m ()
    setBalance :: Balance -> m ()
    insertUnspent :: Unspent -> m ()
    deleteUnspent :: OutPoint -> m ()

getSpenders :: StoreReadBase m => TxHash -> m (IntMap Spender)
getSpenders th =
    getActiveTxData th >>= \case
        Nothing -> return I.empty
        Just td -> I.fromList . catMaybes <$>
                   mapM get_spender [0 .. length (txOut (txData td)) - 1]
  where
    get_spender i = fmap (i,) <$> getSpender (OutPoint th (fromIntegral i))

getActiveBlock :: StoreReadExtra m => BlockHash -> m (Maybe BlockData)
getActiveBlock bh = getBlock bh >>= \case
    Just b | blockDataMainChain b -> return (Just b)
    _ -> return Nothing

getActiveTxData :: StoreReadBase m => TxHash -> m (Maybe TxData)
getActiveTxData th = getTxData th >>= \case
    Just td | not (txDataDeleted td) -> return (Just td)
    _ -> return Nothing

getDefaultBalance :: StoreReadBase m => Address -> m Balance
getDefaultBalance a = getBalance a >>= \case
    Nothing -> return $ zeroBalance a
    Just  b -> return b

xUns :: StoreReadExtra f => Limits -> [XPubBal] -> f [XPubUnspent]
xUns limits bs = concat <$> mapM g bs
  where
    f p t = XPubUnspent {xPubUnspentPath = p, xPubUnspent = t}
    g b =
        map (f (xPubBalPath b)) <$>
        getAddressUnspents (balanceAddress (xPubBal b)) (deOffset limits)

deriveAddresses :: DeriveAddr -> XPubKey -> Word32 -> [(Word32, Address)]
deriveAddresses derive xpub start = map (\i -> (i, derive xpub i)) [start ..]

deriveFunction :: DeriveType -> DeriveAddr
deriveFunction DeriveNormal i = fst . deriveAddr i
deriveFunction DeriveP2SH i   = fst . deriveCompatWitnessAddr i
deriveFunction DeriveP2WPKH i = fst . deriveWitnessAddr i

xPubBalsUnspents ::
       StoreReadExtra m
    => [XPubBal]
    -> Limits
    -> m [XPubUnspent]
xPubBalsUnspents bals limits = do
    let xs = filter positive bals
    applyLimits limits <$> xUns limits xs
  where
    positive XPubBal {xPubBal = Balance {balanceUnspentCount = c}} = c > 0

xPubBalsTxs ::
       StoreReadExtra m
    => [XPubBal]
    -> Limits
    -> m [TxRef]
xPubBalsTxs bals limits = do
    let as = map balanceAddress . filter (not . nullBalance) $ map xPubBal bals
    ts <- concat <$> mapM (\a -> getAddressTxs a (deOffset limits)) as
    let ts' = sortBy (flip compare `on` txRefBlock) (nub' ts)
    return $ applyLimits limits ts'

getTransaction ::
       (Monad m, StoreReadBase m) => TxHash -> m (Maybe Transaction)
getTransaction h = runMaybeT $ do
    d <- MaybeT $ getTxData h
    sm <- lift $ getSpenders h
    return $ toTransaction d sm

blockAtOrBefore :: (MonadIO m, StoreReadExtra m)
                => Chain
                -> UnixTime
                -> m (Maybe BlockData)
blockAtOrBefore ch q = runMaybeT $ do
    net <- lift getNetwork
    x <- MaybeT $ liftIO $ runReaderT (lastSmallerOrEqual net f) ch
    MaybeT $ getBlock (headerHash (nodeHeader x))
  where
    f x =
        let t = fromIntegral (blockTimestamp (nodeHeader x))
         in return $ t `compare` q


-- | Events that the store can generate.
data StoreEvent
    = StoreBestBlock !BlockHash
    | StoreMempoolNew !TxHash
    | StorePeerConnected !Peer
    | StorePeerDisconnected !Peer
    | StorePeerPong !Peer !Word64
    | StoreTxAvailable !Peer ![TxHash]
    | StoreTxReject !Peer !TxHash !RejectCode !ByteString
      -- ^ block no longer head of main chain

data PubExcept = PubNoPeers
    | PubReject RejectCode
    | PubTimeout
    | PubPeerDisconnected
    deriving (Eq, NFData, Generic, Serialize)

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
deOffset l = l { limit = limit l + offset l, offset = 0}

applyLimitsC :: Monad m => Limits -> ConduitT i i m ()
applyLimitsC Limits {..} = applyOffsetC offset >> applyLimitC limit

applyOffsetC :: Monad m => Offset -> ConduitT i i m ()
applyOffsetC = dropC . fromIntegral

applyLimitC :: Monad m => Limit -> ConduitT i i m ()
applyLimitC 0 = mapC id
applyLimitC l = takeC (fromIntegral l)

sortTxs :: [Tx] -> [(Word32, Tx)]
sortTxs txs = go [] thset $ zip [0 ..] txs
  where
    thset = H.fromList (map txHash txs)
    go [] _ [] = []
    go orphans ths [] = go [] ths orphans
    go orphans ths ((i, tx):xs) =
      let ops = map (outPointHash . prevOutput) (txIn tx)
          orp = any (`H.member` ths) ops
       in if orp
            then go ((i, tx) : orphans) ths xs
            else (i, tx) : go orphans (txHash tx `H.delete` ths) xs

nub' :: (Eq a, Hashable a) => [a] -> [a]
nub' = H.toList . H.fromList

microseconds :: MonadIO m => m Integer
microseconds =
    let f t = toInteger (systemSeconds t) * 1000000
            + toInteger (systemNanoseconds t) `div` 1000
    in liftIO $ f <$> getSystemTime
