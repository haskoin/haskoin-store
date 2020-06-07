{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedStrings          #-}
module Haskoin.Store.WebCommon

where

import           Control.Applicative       ((<|>))
import           Control.Monad             (guard)
import           Data.Default              (Default, def)
import           Data.Proxy                (Proxy(..))
import qualified Data.Serialize            as S
import           Data.String               (IsString (..))
import           Data.String.Conversions   (cs)
import           Data.Text                 (Text)
import qualified Data.Text                 as Text
import           Haskoin.Address
import           Haskoin.Block             (Block, BlockHash, blockHashToHex,
                                            hexToBlockHash)
import           Haskoin.Constants
import           Haskoin.Crypto            (Hash256)
import           Haskoin.Keys
import qualified Haskoin.Store.Data        as Store
import           Haskoin.Transaction
import           Network.HTTP.Types        (StdMethod (..))
import           Numeric.Natural           (Natural)
import           Text.Read                 (readMaybe)
import qualified Web.Scotty.Trans          as Scotty

-------------------
-- API Resources --
-------------------

class S.Serialize b => ApiResource a b | a -> b where
    resourceMethod :: Proxy a -> StdMethod
    resourceMethod _ = GET
    resourcePath :: Proxy a -> ([Text] -> Text)
    queryParams :: a -> ([ParamBox], [ParamBox]) -- (resource, querystring)
    queryParams _ = ([],[])
    captureParams :: Proxy a -> [ProxyBox]
    captureParams _ = []
    resourceBody :: a -> Maybe PostBox
    resourceBody = const Nothing

data PostBox = forall s . S.Serialize s => PostBox !s
data ParamBox = forall p . (Eq p, Param p) => ParamBox !p
data ProxyBox = forall p . Param p => ProxyBox !(Proxy p)

--------------------
-- Resource Paths --
--------------------

-- Blocks
data GetBlock = GetBlock !BlockHash !NoTx
data GetBlocks = GetBlocks ![BlockHash] !NoTx
newtype GetBlockRaw = GetBlockRaw BlockHash
newtype GetBlockBest = GetBlockBest NoTx
data GetBlockBestRaw = GetBlockBestRaw
newtype GetBlockLatest = GetBlockLatest NoTx
data GetBlockHeight = GetBlockHeight !HeightParam !NoTx
data GetBlockHeights = GetBlockHeights !HeightsParam !NoTx
newtype GetBlockHeightRaw = GetBlockHeightRaw HeightParam
data GetBlockTime = GetBlockTime !TimeParam !NoTx
newtype GetBlockTimeRaw = GetBlockTimeRaw TimeParam
-- Transactions
newtype GetTx = GetTx TxHash
newtype GetTxs = GetTxs [TxHash]
newtype GetTxRaw = GetTxRaw TxHash
newtype GetTxsRaw = GetTxsRaw [TxHash]
newtype GetTxsBlock = GetTxsBlock BlockHash
newtype GetTxsBlockRaw = GetTxsBlockRaw BlockHash
data GetTxAfter = GetTxAfter !TxHash !HeightParam
newtype PostTx = PostTx Tx
data GetMempool = GetMempool !(Maybe LimitParam) !OffsetParam
data GetEvents = GetEvents
-- Address
data GetAddrTxs = GetAddrTxs !Address !LimitsParam
data GetAddrsTxs = GetAddrsTxs ![Address] !LimitsParam
data GetAddrTxsFull = GetAddrTxsFull !Address !LimitsParam
data GetAddrsTxsFull = GetAddrsTxsFull ![Address] !LimitsParam
newtype GetAddrBalance = GetAddrBalance Address
newtype GetAddrsBalance = GetAddrsBalance [Address]
data GetAddrUnspent = GetAddrUnspent !Address !LimitsParam
data GetAddrsUnspent = GetAddrsUnspent ![Address] !LimitsParam
-- XPubs
data GetXPub = GetXPub !XPubKey !Store.DeriveType !NoCache
data GetXPubTxs = GetXPubTxs !XPubKey !Store.DeriveType !LimitsParam !NoCache
data GetXPubTxsFull = GetXPubTxsFull !XPubKey !Store.DeriveType !LimitsParam !NoCache
data GetXPubBalances = GetXPubBalances !XPubKey !Store.DeriveType !NoCache
data GetXPubUnspent = GetXPubUnspent !XPubKey !Store.DeriveType !LimitsParam !NoCache
data GetXPubEvict = GetXPubEvict !XPubKey !Store.DeriveType
-- Network
data GetPeers = GetPeers
data GetHealth = GetHealth

------------
-- Blocks --
------------

instance ApiResource GetBlock Store.BlockData where
    resourcePath _ = ("/block/" <:>)
    queryParams (GetBlock h t) = ([ParamBox h], noDefBox t)
    captureParams _ = [ProxyBox (Proxy :: Proxy BlockHash)]

instance ApiResource GetBlocks [Store.BlockData] where
    resourcePath _ _ = "/blocks"
    queryParams (GetBlocks hs t) = ([], [ParamBox hs] <> noDefBox t)

instance ApiResource GetBlockRaw (Store.RawResult Block) where
    resourcePath _ = "/block/" <+> "/raw"
    queryParams (GetBlockRaw h) = ([ParamBox h], [])
    captureParams _ = [ProxyBox (Proxy :: Proxy BlockHash)]

instance ApiResource GetBlockBest Store.BlockData where
    resourcePath _ _ = "/block/best"
    queryParams (GetBlockBest t) = ([], noDefBox t)

instance ApiResource GetBlockBestRaw (Store.RawResult Block) where
    resourcePath _ _ = "/block/best/raw"

instance ApiResource GetBlockLatest [Store.BlockData] where
    resourcePath _ _ = "/block/latest"
    queryParams (GetBlockLatest t) = ([], noDefBox t)

instance ApiResource GetBlockHeight [Store.BlockData] where
    resourcePath _ = ("/block/height/" <:>)
    queryParams (GetBlockHeight h t) = ([ParamBox h], noDefBox t)
    captureParams _ = [ProxyBox (Proxy :: Proxy HeightParam)]

instance ApiResource GetBlockHeights [Store.BlockData] where
    resourcePath _ _ = "/block/height"
    queryParams (GetBlockHeights hs t) = ([], [ParamBox hs] <> noDefBox t)

instance ApiResource GetBlockHeightRaw (Store.RawResultList Block) where
    resourcePath _ = "/block/height/" <+> "/raw"
    queryParams (GetBlockHeightRaw h) = ([ParamBox h], [])
    captureParams _ = [ProxyBox (Proxy :: Proxy HeightParam)]

instance ApiResource GetBlockTime Store.BlockData where
    resourcePath _ = ("/block/time/" <:>)
    queryParams (GetBlockTime u t) = ([ParamBox u], noDefBox t)
    captureParams _ = [ProxyBox (Proxy :: Proxy TimeParam)]

instance ApiResource GetBlockTimeRaw (Store.RawResult Block) where
    resourcePath _ = "/block/time/" <+> "/raw"
    queryParams (GetBlockTimeRaw u) = ([ParamBox u], [])
    captureParams _ = [ProxyBox (Proxy :: Proxy TimeParam)]

------------------
-- Transactions --
------------------

instance ApiResource GetTx Store.Transaction where
    resourcePath _ = ("/transaction/" <:>)
    queryParams (GetTx h) = ([ParamBox h], [])
    captureParams _ = [ProxyBox (Proxy :: Proxy TxHash)]

instance ApiResource GetTxs [Store.Transaction] where
    resourcePath _ _ = "/transactions"
    queryParams (GetTxs hs) = ([], [ParamBox hs])

instance ApiResource GetTxRaw (Store.RawResult Tx) where
    resourcePath _ = "/transaction/" <+> "/raw"
    queryParams (GetTxRaw h) = ([ParamBox h], [])
    captureParams _ = [ProxyBox (Proxy :: Proxy TxHash)]

instance ApiResource GetTxsRaw (Store.RawResultList Tx) where
    resourcePath _ _ = "/transactions/raw"
    queryParams (GetTxsRaw hs) = ([], [ParamBox hs])

instance ApiResource GetTxsBlock [Store.Transaction] where
    resourcePath _ = ("/transactions/block/" <:>)
    queryParams (GetTxsBlock h) = ([ParamBox h], [])
    captureParams _ = [ProxyBox (Proxy :: Proxy BlockHash)]

instance ApiResource GetTxsBlockRaw (Store.RawResultList Tx) where
    resourcePath _ = "/transactions/block/" <+> "/raw"
    queryParams (GetTxsBlockRaw h) = ([ParamBox h], [])
    captureParams _ = [ProxyBox (Proxy :: Proxy BlockHash)]

instance ApiResource GetTxAfter (Store.GenericResult (Maybe Bool)) where
    resourcePath _ = "/transaction/" <++> "/after/"
    queryParams (GetTxAfter h i) = ([ParamBox h, ParamBox i], [])
    captureParams _ =
        [ ProxyBox (Proxy :: Proxy TxHash)
        , ProxyBox (Proxy :: Proxy HeightParam)
        ]

instance ApiResource PostTx Store.TxId where
    resourceMethod _ = POST
    resourcePath _ _ = "/transactions"
    resourceBody (PostTx tx) = Just $ PostBox tx

instance ApiResource GetMempool [TxHash] where
    resourcePath _ _ = "/mempool"
    queryParams (GetMempool l o) = ([], noMaybeBox l <> noDefBox o)

instance ApiResource GetEvents [Store.Event] where
    resourcePath _ _ = "/events"

-------------
-- Address --
-------------

instance ApiResource GetAddrTxs [Store.TxRef] where
    resourcePath _ = "/address/" <+> "/transactions"
    queryParams (GetAddrTxs a (LimitsParam l o sM)) =
        ([ParamBox a], noMaybeBox l <> noDefBox o <> noMaybeBox sM)
    captureParams _ = [ProxyBox (Proxy :: Proxy Address)]

instance ApiResource GetAddrsTxs [Store.TxRef] where
    resourcePath _ _ = "/address/transactions"
    queryParams (GetAddrsTxs as (LimitsParam l o sM)) =
        ([] , [ParamBox as] <> noMaybeBox l <> noDefBox o <> noMaybeBox sM)

instance ApiResource GetAddrTxsFull [Store.Transaction] where
    resourcePath _ = "/address/" <+> "/transactions/full"
    queryParams (GetAddrTxsFull a (LimitsParam l o sM)) =
        ([ParamBox a], noMaybeBox l <> noDefBox o <> noMaybeBox sM)
    captureParams _ = [ProxyBox (Proxy :: Proxy Address)]

instance ApiResource GetAddrsTxsFull [Store.Transaction] where
    resourcePath _ _ = "/address/transactions/full"
    queryParams (GetAddrsTxsFull as (LimitsParam l o sM)) =
        ([] , [ParamBox as] <> noMaybeBox l <> noDefBox o <> noMaybeBox sM)

instance ApiResource GetAddrBalance Store.Balance where
    resourcePath _ = "/address/" <+> "/balance"
    queryParams (GetAddrBalance a) = ([ParamBox a], [])
    captureParams _ = [ProxyBox (Proxy :: Proxy Address)]

instance ApiResource GetAddrsBalance [Store.Balance] where
    resourcePath _ _ = "/address/balances"
    queryParams (GetAddrsBalance as) = ([] , [ParamBox as])

instance ApiResource GetAddrUnspent [Store.Unspent] where
    resourcePath _ = "/address/" <+> "/unspent"
    queryParams (GetAddrUnspent a (LimitsParam l o sM)) =
        ([ParamBox a], noMaybeBox l <> noDefBox o <> noMaybeBox sM)
    captureParams _ = [ProxyBox (Proxy :: Proxy Address)]

instance ApiResource GetAddrsUnspent [Store.Unspent] where
    resourcePath _ _ = "/address/unspent"
    queryParams (GetAddrsUnspent as (LimitsParam l o sM)) =
        ([] , [ParamBox as] <> noMaybeBox l <> noDefBox o <> noMaybeBox sM)

-----------
-- XPubs --
-----------

instance ApiResource GetXPub Store.XPubSummary where
    resourcePath _ = ("/xpub/" <:>)
    queryParams (GetXPub p d n) = ([ParamBox p], noDefBox d <> noDefBox n)
    captureParams _ = [ProxyBox (Proxy :: Proxy XPubKey)]

instance ApiResource GetXPubTxs [Store.TxRef] where
    resourcePath _ = "/xpub/" <+> "/transactions"
    queryParams (GetXPubTxs p d (LimitsParam l o sM) n) =
        ( [ParamBox p]
        , noDefBox d <> noMaybeBox l <> noDefBox o <> noMaybeBox sM <> noDefBox n
        )
    captureParams _ = [ProxyBox (Proxy :: Proxy XPubKey)]

instance ApiResource GetXPubTxsFull [Store.Transaction] where
    resourcePath _ = "/xpub/" <+> "/transactions/full"
    queryParams (GetXPubTxsFull p d (LimitsParam l o sM) n) =
        ( [ParamBox p]
        , noDefBox d <> noMaybeBox l <> noDefBox o <> noMaybeBox sM <> noDefBox n
        )
    captureParams _ = [ProxyBox (Proxy :: Proxy XPubKey)]

instance ApiResource GetXPubBalances [Store.XPubBal] where
    resourcePath _ = "/xpub/" <+> "/balances"
    queryParams (GetXPubBalances p d n) = ([ParamBox p], noDefBox d <> noDefBox n)
    captureParams _ = [ProxyBox (Proxy :: Proxy XPubKey)]

instance ApiResource GetXPubUnspent [Store.XPubUnspent] where
    resourcePath _ = "/xpub/" <+> "/unspent"
    queryParams (GetXPubUnspent p d (LimitsParam l o sM) n) =
        ( [ParamBox p]
        , noDefBox d <> noMaybeBox l <> noDefBox o <> noMaybeBox sM <> noDefBox n
        )
    captureParams _ = [ProxyBox (Proxy :: Proxy XPubKey)]

instance ApiResource GetXPubEvict (Store.GenericResult Bool) where
    resourcePath _ = "/xpub/" <+> "/evict"
    queryParams (GetXPubEvict p d) = ([ParamBox p], noDefBox d)
    captureParams _ = [ProxyBox (Proxy :: Proxy XPubKey)]

-------------
-- Network --
-------------

instance ApiResource GetPeers [Store.PeerInformation] where
    resourcePath _ _ = "/peers"

instance ApiResource GetHealth Store.HealthCheck where
    resourcePath _ _ = "/health"

-------------
-- Helpers --
-------------

(<:>) :: Text -> [Text] -> Text
(<:>) = (<+> "")

(<+>) :: Text -> Text -> [Text] -> Text
a <+> b = fill 1 [a, b]

(<++>) :: Text -> Text -> [Text] -> Text
a <++> b = fill 2 [a, b]

fill :: Int -> [Text] -> [Text] -> Text
fill i a b
    | length b /= i = error "Invalid query parameters"
    | otherwise = mconcat $ uncurry (<>) <$> zip a (b <> repeat "")

noDefBox :: (Default p, Param p, Eq p) => p -> [ParamBox]
noDefBox p = [ParamBox p | p /= def]

noMaybeBox :: (Param p, Eq p) => Maybe p -> [ParamBox]
noMaybeBox (Just p) = [ParamBox p]
noMaybeBox _ = []

asProxy :: a -> Proxy a
asProxy = const Proxy

queryPath :: ApiResource a b => Network -> a -> Text
queryPath net a = f $ encParam <$> fst (queryParams a)
  where
    f = resourcePath $ asProxy a
    encParam (ParamBox p) =
        case encodeParam net p of
            Just [res] -> res
            _          -> error "Invalid query param"

capturePath :: ApiResource a b => Proxy a -> Scotty.RoutePattern
capturePath proxy =
    fromString $ cs $ f $ toLabel <$> captureParams proxy
  where
    f = resourcePath proxy
    toLabel (ProxyBox p) = ":" <> proxyLabel p

paramLabel :: Param p => p -> Text
paramLabel = proxyLabel . asProxy

-------------
-- Options --
-------------

class Param a where
    proxyLabel :: Proxy a -> Text
    encodeParam :: Network -> a -> Maybe [Text]
    parseParam :: Network -> [Text] -> Maybe a

instance Param Address where
    proxyLabel = const "address"
    encodeParam net a = (:[]) <$> addrToString net a
    parseParam net [a] = stringToAddr net a
    parseParam _ _     = Nothing

instance Param [Address] where
    proxyLabel = const "addresses"
    encodeParam = mapM . addrToString
    parseParam = mapM . stringToAddr

data StartParam = StartParamHash
    { startParamHash :: Hash256
    }
    | StartParamHeight
    { startParamHeight :: Natural
    }
    | StartParamTime
    { startParamTime :: Store.UnixTime
    }
    deriving (Eq, Show)

instance Param StartParam where
    proxyLabel = const "height"
    encodeParam _ p =
        case p of
            StartParamHash h -> return [txHashToHex (TxHash h)]
            StartParamHeight h -> do
                guard $ h <= 1230768000
                return [cs $ show h]
            StartParamTime t -> do
                guard $ t > 1230768000
                return [cs $ show t]
    parseParam _ [s] = parseHash <|> parseHeight <|> parseUnix
      where
        parseHash = do
            guard (Text.length s == 32 * 2)
            TxHash x <- hexToTxHash s
            return $ StartParamHash x
        parseHeight = do
            x <- readMaybe $ cs s
            guard $ x <= 1230768000
            return $ StartParamHeight x
        parseUnix = do
            x <- readMaybe $ cs s
            guard $ x > 1230768000
            return $ StartParamTime x
    parseParam _ _ = Nothing

newtype OffsetParam = OffsetParam
    { getOffsetParam :: Natural
    } deriving (Eq, Show, Read, Enum, Ord, Num, Real, Integral)

instance Default OffsetParam where
    def = OffsetParam 0

instance Param OffsetParam where
    proxyLabel = const "offset"
    encodeParam _ (OffsetParam o) = Just [cs $ show o]
    parseParam _ [s] = OffsetParam <$> readMaybe (cs s)
    parseParam _ _   = Nothing

newtype LimitParam = LimitParam
    { getLimitParam :: Natural
    } deriving (Eq, Show, Read, Enum, Ord, Num, Real, Integral)

instance Param LimitParam where
    proxyLabel = const "limit"
    encodeParam _ (LimitParam l) = Just [cs $ show l]
    parseParam _ [s] = LimitParam <$> readMaybe (cs s)
    parseParam _ _   = Nothing

data LimitsParam =
    LimitsParam
        { paramLimit  :: Maybe LimitParam -- 0 means maximum
        , paramOffset :: OffsetParam
        , paramStart  :: Maybe StartParam
        }
    deriving (Eq, Show)

instance Default LimitsParam where
    def = LimitsParam Nothing def Nothing

newtype HeightParam = HeightParam
    { getHeightParam :: Natural
    } deriving (Eq, Show, Read, Enum, Ord, Num, Real, Integral)

instance Param HeightParam where
    proxyLabel = const "height"
    encodeParam _ (HeightParam h) = Just [cs $ show h]
    parseParam _ [s] = HeightParam <$> readMaybe (cs s)
    parseParam _ _   = Nothing

newtype HeightsParam = HeightsParam
    { getHeightsParam :: [Natural]
    } deriving (Eq, Show, Read)

instance Param HeightsParam where
    proxyLabel = const "heights"
    encodeParam _ (HeightsParam hs) = Just $ cs . show <$> hs
    parseParam _ xs = HeightsParam <$> mapM (readMaybe . cs) xs

newtype TimeParam = TimeParam
    { getTimeParam :: Store.UnixTime
    } deriving (Eq, Show, Read, Enum, Ord, Num, Real, Integral)

instance Param TimeParam where
    proxyLabel = const "time"
    encodeParam _ (TimeParam t) = Just [cs $ show t]
    parseParam _ [s] = TimeParam <$> readMaybe (cs s)
    parseParam _ _   = Nothing

instance Param XPubKey where
    proxyLabel = const "xpub"
    encodeParam net p = Just [xPubExport net p]
    parseParam net [s] = xPubImport net s
    parseParam _ _     = Nothing

instance Param Store.DeriveType where
    proxyLabel = const "derive"
    encodeParam net p = do
        guard (getSegWit net || p == Store.DeriveNormal)
        case p of
            Store.DeriveNormal -> Just ["standard"]
            Store.DeriveP2SH   -> Just ["compat"]
            Store.DeriveP2WPKH -> Just ["segwit"]
    parseParam net d = do
        res <- case d of
            ["standard"] -> Just Store.DeriveNormal
            ["compat"]   -> Just Store.DeriveP2SH
            ["segwit"]   -> Just Store.DeriveP2WPKH
            _            -> Nothing
        guard (getSegWit net || res == Store.DeriveNormal)
        return res

newtype NoCache = NoCache
    { getNoCache :: Bool
    } deriving (Eq, Show, Read)

instance Default NoCache where
    def = NoCache False

instance Param NoCache where
    proxyLabel = const "nocache"
    encodeParam _ (NoCache True)  = Just ["true"]
    encodeParam _ (NoCache False) = Just ["false"]
    parseParam _ = \case
        ["true"] -> Just $ NoCache True
        ["false"] -> Just $ NoCache False
        _ -> Nothing

newtype NoTx = NoTx
    { getNoTx :: Bool
    } deriving (Eq, Show, Read)

instance Default NoTx where
    def = NoTx False

instance Param NoTx where
    proxyLabel = const "notx"
    encodeParam _ (NoTx True)  = Just ["true"]
    encodeParam _ (NoTx False) = Just ["false"]
    parseParam _ = \case
        ["true"] -> Just $ NoTx True
        ["false"] -> Just $ NoTx False
        _ -> Nothing

instance Param BlockHash where
    proxyLabel = const "block"
    encodeParam _ b = Just [blockHashToHex b]
    parseParam _ [s] = hexToBlockHash s
    parseParam _ _   = Nothing

instance Param [BlockHash] where
    proxyLabel = const "blocks"
    encodeParam _ bs = Just $ blockHashToHex <$> bs
    parseParam _ = mapM hexToBlockHash

instance Param TxHash where
    proxyLabel = const "txid"
    encodeParam _ t = Just [txHashToHex t]
    parseParam _ [s] = hexToTxHash s
    parseParam _ _   = Nothing

instance Param [TxHash] where
    proxyLabel = const "txids"
    encodeParam _ ts = Just $ txHashToHex <$> ts
    parseParam _ = mapM hexToTxHash

