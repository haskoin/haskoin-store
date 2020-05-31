{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE FunctionalDependencies    #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE Strict                    #-}
module Haskoin.Store.WebCommon

where

import           Control.Applicative       ((<|>))
import           Control.Arrow             (second, (&&&))
import           Control.Lens              ((.~), (?~), (^.))
import           Control.Monad             (forever, guard, unless, when, (<=<))
import           Control.Monad.Except      (MonadError)
import           Control.Monad.Trans       (MonadIO, liftIO)
import qualified Data.Aeson                as Json
import qualified Data.ByteString           as B
import           Data.Default              (Default, def)
import           Data.Maybe                (maybeToList)
import           Data.Monoid               (Endo (..), appEndo)
import           Data.Proxy
import qualified Data.Serialize            as S
import           Data.String               (IsString (..))
import           Data.String.Conversions   (cs)
import           Data.Text                 (Text)
import qualified Data.Text                 as Text
import qualified Data.Text.Lazy            as TL
import           Data.Word                 (Word32, Word64)
import           Haskoin.Address
import           Haskoin.Block             (Block, BlockHash, blockHashToHex,
                                            hexToBlockHash)
import           Haskoin.Constants
import           Haskoin.Crypto            (Hash256)
import           Haskoin.Keys
import qualified Haskoin.Store.Data        as Store
import           Haskoin.Transaction
import           Haskoin.Util
import           Network.HTTP.Types        (StdMethod (..))
import           Network.HTTP.Types.Status
import qualified Network.Wreq              as HTTP
import           Network.Wreq.Types        (ResponseChecker)
import           Numeric.Natural           (Natural)
import           Text.Read                 (readMaybe)
import qualified Web.Scotty.Trans          as Scotty

{- API Resources -}

-- | List of available API calls together with arguments and return types.
-- For example:
--
-- > AddressTxs :: [Address] -> ApiResource [TxRef]
--
-- @AddressTxs@ takes a list of addresses @[Address]@ as argument and
-- returns a list of transaction references @[TxRef]@.
-- data ApiResource a where
--     BlockRaw :: BlockHash -> ApiResource (Store.GenericResult Block)
--     BlockLatest :: ApiResource [Store.BlockData]
--     BlockHeights :: [Word32] -> ApiResource [Store.BlockData]
--     BlockTime :: Store.UnixTime -> ApiResource Store.BlockData
--     BlockTimeRaw :: Store.UnixTime -> ApiResource (Store.GenericResult Block)
--     -- Transactions
--     Mempool :: ApiResource [TxHash]
--     TxsDetails :: [TxHash] -> ApiResource [Store.Transaction]
--     PostTx :: Tx -> ApiResource Store.TxId
--     TxsRaw :: [TxHash] -> ApiResource [Tx]
--     TxAfter :: TxHash -> Word32 -> ApiResource (Store.GenericResult Bool)
--     TxsBlock :: BlockHash -> ApiResource [Store.Transaction]
--     TxsBlockRaw :: BlockHash -> ApiResource [Tx]
--     -- Address
--     AddressTxs :: [Address] -> ApiResource [Store.TxRef]
--     AddressTxsFull :: [Address] -> ApiResource [Store.Transaction]
--     AddressBalances :: [Address] -> ApiResource [Store.Balance]
--     AddressUnspent :: [Address] -> ApiResource [Store.Unspent]
--     -- XPubs
--     XPubEvict :: XPubKey -> ApiResource (Store.GenericResult Bool)
--     XPubSummary :: XPubKey -> ApiResource Store.XPubSummary
--     XPubTxs :: XPubKey -> ApiResource [Store.TxRef]
--     XPubTxsFull :: XPubKey -> ApiResource [Store.Transaction]
--     XPubBalances :: XPubKey -> ApiResource [Store.XPubBal]
--     XPubUnspent :: XPubKey -> ApiResource [Store.XPubUnspent]
--     -- Network
--     Events :: ApiResource [Store.Event]
--     Health :: ApiResource Store.HealthCheck
--     Peers :: ApiResource [Store.PeerInformation]
--
-- resourcePath :: Network -> ApiResource a -> (Text, Scotty.RoutePattern)
-- resourcePath net =
--     \case
--         Blocks {} -> double "/blocks"
--         BlockLatest -> double "/block/latest"
--         BlockRaw b -> paramPath net b $ \q -> "/block/" <> q <> "/raw"
--         BlockHeight i -> paramPath net (HeightParam i) ("/block/height/" <>)
--         BlockHeightRaw i ->
--             paramPath net (HeightParam i) $ \q ->
--                 "/block/height/" <> q <> "/raw"
--         BlockHeights {} -> double "/block/heights"
--         BlockTime t -> paramPath net (TimeParam t) ("/block/time/" <>)
--         BlockTimeRaw t ->
--             paramPath net (TimeParam t) $ \q -> "/block/time/" <> q <> "/raw"
--         -- Transactions
--         Mempool -> double "/mempool"
--         TxsDetails {} -> double "/transactions"
--         PostTx {} -> double "/transactions"
--         TxsRaw {} -> double "/transactions/raw"
--         TxAfter h i ->
--             paramPath2 net h (HeightParam i) $ \a b ->
--                 "/transactions/" <> a <> "/after/" <> b
--         TxsBlock b -> paramPath net b ("/transactions/block/" <>)
--         TxsBlockRaw b ->
--             paramPath net b $ \q -> "/transactions/block/" <> q <> "/raw"
--         -- Address
--         AddressTxs {} -> double "/address/transactions"
--         AddressTxsFull {} -> double "/address/transactions/full"
--         AddressBalances {} -> double "/address/balances"
--         AddressUnspent {} -> double "/address/unspent"
--         -- XPubs
--         XPubEvict pub -> paramPath net pub $ \q -> "/xpub/" <> q <> "/evict"
--         XPubSummary pub -> paramPath net pub ("/xpub/" <>)
--         XPubTxs pub ->
--             paramPath net pub $ \q -> "/xpub/" <> q <> "/transactions"
--         XPubTxsFull pub ->
--             paramPath net pub $ \q -> "/xpub/" <> q <> "/transactions/full"
--         XPubBalances pub ->
--             paramPath net pub $ \q -> "/xpub/" <> q <> "/balances"
--         XPubUnspent pub -> paramPath net pub $ \q -> "/xpub/" <> q <> "/unspent"
--         -- Network
--         Events -> double "/events"
--         Health -> double "/health"
--         Peers -> double "/peers"


data PostBox = forall s . S.Serialize s => PostBox s
data ParamBox = forall p . (Eq p, Param p) => ParamBox p
data ProxyBox = forall p . Param p => ProxyBox (Proxy p)

{- Resource Paths -}

class S.Serialize b => ApiResource a b | a -> b where
    resourceMethod :: Proxy a -> StdMethod
    resourcePath :: Proxy a -> ([Text] -> Text)
    queryParams :: a -> ([ParamBox], [ParamBox]) -- (resource, querystring)
    queryParams _ = ([],[])
    captureParams :: Proxy a -> [ProxyBox]
    captureParams _ = []
    resourceBody :: a -> Maybe PostBox
    resourceBody = const Nothing

{- GET BlockBest -}

newtype GetBlockBest = GetBlockBest NoTx

instance ApiResource GetBlockBest Store.BlockData where
    resourceMethod _ = GET
    resourcePath _ _ = "/block/best"
    queryParams (GetBlockBest t) = ([], [ParamBox t | t /= def])

{- GET BlockBestRaw -}

data GetBlockBestRaw = GetBlockBestRaw

instance ApiResource GetBlockBestRaw (Store.RawResult Block) where
    resourceMethod _ = GET
    resourcePath _ _ = "/block/best/raw"

{- GET Block -}

data GetBlock = GetBlock BlockHash NoTx

instance ApiResource GetBlock Store.BlockData where
    resourceMethod _ = GET
    resourcePath _ [h] = "/block/" <> h
    resourcePath _ _ = error "Invalid resource path"
    queryParams (GetBlock h t) = ([ParamBox h], [ParamBox t | t /= def])
    captureParams _ = [ProxyBox (Proxy :: Proxy BlockHash)]

{- GET Blocks -}

data GetBlocks = GetBlocks [BlockHash] NoTx

instance ApiResource GetBlocks [Store.BlockData] where
    resourceMethod _ = GET
    resourcePath _ _ = "/blocks"
    queryParams (GetBlocks hs t) =
        ([], [ParamBox hs] <> [ParamBox t | t /= def])

{- GET BlockRaw -}

newtype GetBlockRaw = GetBlockRaw BlockHash

instance ApiResource GetBlockRaw (Store.RawResult Block) where
    resourceMethod _ = GET
    resourcePath _ [h] = "/block/" <> h <> "/raw"
    resourcePath _ _ = error "Invalid resource path"
    queryParams (GetBlockRaw h) = ([ParamBox h], [])
    captureParams _ = [ProxyBox (Proxy :: Proxy BlockHash)]

{- GET BlockHeight -}

data GetBlockHeight = GetBlockHeight HeightParam NoTx

instance ApiResource GetBlockHeight [Store.BlockData] where
    resourceMethod _ = GET
    resourcePath _ [h] = "/block/height/" <> h
    resourcePath _ _ = error "Invalid resource path"
    queryParams (GetBlockHeight h t) = ([ParamBox h], [ParamBox t | t /= def])
    captureParams _ = [ProxyBox (Proxy :: Proxy HeightParam)]

{- GET BlockHeightRaw -}

newtype GetBlockHeightRaw = GetBlockHeightRaw HeightParam

instance ApiResource GetBlockHeightRaw (Store.RawResultList Block) where
    resourceMethod _ = GET
    resourcePath _ [h] = "/block/height/" <> h <> "/raw"
    resourcePath _ _ = error "Invalid resource path"
    queryParams (GetBlockHeightRaw h) = ([ParamBox h], [])
    captureParams _ = [ProxyBox (Proxy :: Proxy HeightParam)]

{- Helpers -}

asProxy :: a -> Proxy a
asProxy = const Proxy

queryPath :: ApiResource a b => Network -> a -> Text
queryPath net a = f $ encParam <$> fst (queryParams a)
  where
    f = resourcePath $ asProxy a
    encParam (ParamBox p) =
        case encodeParam net p of
            Just [res] -> res
            _ -> error "Invalid query param"

capturePath :: ApiResource a b => Proxy a -> Scotty.RoutePattern
capturePath proxy = 
    fromString $ cs $ f $ toLabel <$> captureParams proxy
  where
    f = resourcePath proxy
    toLabel (ProxyBox p) = ":" <> proxyLabel p

{- Options -}

class Param a where
    proxyLabel :: Proxy a -> Text
    paramLabel :: a -> Text
    paramLabel = proxyLabel . asProxy
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
    { startParamHeight :: Word32
    }
    | StartParamTime
    { startParamTime :: Store.UnixTime
    }
    deriving (Eq, Show)

instance Param StartParam where
    proxyLabel = const "height"
    encodeParam _ p =
        return $
        case p of
            StartParamHash h   -> [txHashToHex (TxHash h)]
            StartParamHeight h -> [cs $ show h]
            StartParamTime t   -> [cs $ show t]
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

newtype HeightParam = HeightParam
    { getHeightParam :: Word32
    } deriving (Eq, Show, Read)

instance Param HeightParam where
    proxyLabel = const "height"
    encodeParam _ (HeightParam h) = Just [cs $ show h]
    parseParam _ [s] = HeightParam <$> readMaybe (cs s)
    parseParam _ _   = Nothing

newtype HeightsParam = HeightsParam
    { getHeightsParam :: [Word32]
    } deriving (Eq, Show, Read)

instance Param HeightsParam where
    proxyLabel = const "heights"
    encodeParam _ (HeightsParam hs) = Just $ cs . show <$> hs
    parseParam _ xs = HeightsParam <$> mapM (readMaybe . cs) xs

newtype TimeParam = TimeParam
    { getTimeParam :: Store.UnixTime
    } deriving (Eq, Show, Read)

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

newtype OffsetParam = OffsetParam
    { getOffsetParam :: Word32
    } deriving (Eq, Show, Read)

instance Default OffsetParam where
    def = OffsetParam 0

instance Param OffsetParam where
    proxyLabel = const "offset"
    encodeParam _ (OffsetParam o) = Just [cs $ show o]
    parseParam _ [s] = OffsetParam <$> readMaybe (cs s)
    parseParam _ _   = Nothing

newtype LimitParam = LimitParam
    { getLimitParam :: Word32
    } deriving (Eq, Show, Read)

instance Param LimitParam where
    proxyLabel = const "limit"
    encodeParam _ (LimitParam l) = Just [cs $ show l]
    parseParam _ [s] = LimitParam <$> readMaybe (cs s)
    parseParam _ _   = Nothing

instance Param Store.DeriveType where
    proxyLabel = const "derive"
    encodeParam _ =
        \case
            Store.DeriveNormal -> Just ["standard"]
            Store.DeriveP2SH -> Just ["compat"]
            Store.DeriveP2WPKH -> Just ["segwit"]
    parseParam _ =
        \case
            ["standard"] -> Just Store.DeriveNormal
            ["compat"] -> Just Store.DeriveP2SH
            ["segwit"] -> Just Store.DeriveP2WPKH
            _ -> Nothing

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

