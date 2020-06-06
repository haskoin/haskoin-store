{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE Strict                #-}
module Haskoin.Store.WebClient
( ApiConfig(..)
, apiCall
, apiBatch
-- Blocks
, GetBlock(..)
, GetBlocks(..)
, GetBlockRaw(..)
, GetBlockBest(..)
, GetBlockBestRaw(..)
, GetBlockLatest(..)
, GetBlockHeight(..)
, GetBlockHeights(..)
, GetBlockHeightRaw(..)
, GetBlockTime(..)
, GetBlockTimeRaw(..)
-- Transactions
, GetTx(..)
, GetTxs(..)
, GetTxRaw(..)
, GetTxsRaw(..)
, GetTxsBlock(..)
, GetTxsBlockRaw(..)
, GetTxAfter(..)
, PostTx(..)
, GetMempool(..)
, GetEvents(..)
-- Address
, GetAddrTxs(..)
, GetAddrsTxs(..)
, GetAddrTxsFull(..)
, GetAddrsTxsFull(..)
, GetAddrBalance(..)
, GetAddrsBalance(..)
, GetAddrUnspent(..)
, GetAddrsUnspent(..)
-- XPubs
, GetXPub(..)
, GetXPubTxs(..)
, GetXPubTxsFull(..)
, GetXPubBalances(..)
, GetXPubUnspent(..)
, GetXPubEvict(..)
-- Network
, GetPeers(..)
, GetHealth(..)
-- Params
, StartParam(..)
, OffsetParam(..)
, LimitParam(..)
, LimitsParam(..)
, HeightParam(..)
, HeightsParam(..)
, Store.DeriveType(..)
, NoCache(..)
, NoTx(..)
)

where

import           Control.Arrow             (second)
import           Control.Lens              ((.~), (?~), (^.))
import           Control.Monad.Except      (MonadError, throwError)
import           Control.Monad.Trans       (MonadIO, liftIO)
import           Data.Default              (Default, def)
import           Data.Monoid               (Endo (..), appEndo)
import qualified Data.Serialize            as S
import           Data.String.Conversions   (cs)
import           Data.Text                 (Text)
import qualified Data.Text                 as Text
import           Haskoin.Constants
import qualified Haskoin.Store.Data        as Store
import           Haskoin.Store.WebCommon
import           Haskoin.Transaction
import           Haskoin.Util
import           Network.HTTP.Types        (StdMethod (..))
import           Network.HTTP.Types.Status
import qualified Network.Wreq              as HTTP
import           Network.Wreq.Types        (ResponseChecker)
import           Numeric.Natural           (Natural)

-- | Configuration specifying the Network and the Host for API calls.
-- Default instance:
--
-- @
-- ApiConfig
-- { configNetwork = bch
-- , configHost = "https://api.haskoin.com/"
-- }
-- @
--
data ApiConfig = ApiConfig
    { configNetwork :: Network
    , configHost    :: String
    }
    deriving (Eq, Show)

instance Default ApiConfig where
    def = ApiConfig
          { configNetwork = bch
          , configHost = "https://api.haskoin.com/"
          }

-- | Make a call to the haskoin-store API.
--
-- Usage (default options):
--
-- > apiCall def $ GetAddrsTxs addrs def
--
-- With options:
--
-- > apiCall def $ GetAddrsUnspent addrs def{ paramLimit = Just 10 }
--
apiCall ::
       (ApiResource a b, MonadIO m, MonadError String m)
    => ApiConfig
    -> a
    -> m b
apiCall (ApiConfig net host) res = do
    args <- liftEither $ toOptions net res
    let url = host <> getNetworkName net <> cs (queryPath net res)
    case resourceMethod $ asProxy res of
        GET -> getBinary args url
        POST ->
            case resourceBody res of
                Just (PostBox val) -> postBinary args url val
                _                  -> throwError "Could not post resource"
        _ -> throwError "Unsupported HTTP method"

-- | Batch commands that have a large list of arguments:
--
-- > apiBatch 20 def (GetAddrsTxs addrs def)
--
apiBatch ::
       (Batchable a b, MonadIO m, MonadError String m)
    => Natural
    -> ApiConfig
    -> a
    -> m b
apiBatch i conf res = mconcat <$> mapM (apiCall conf) (resourceBatch i res)

class (ApiResource a b, Monoid b) => Batchable a b where
    resourceBatch :: Natural -> a -> [a]

instance Batchable GetBlocks [Store.BlockData] where
    resourceBatch i (GetBlocks hs t) = (`GetBlocks` t) <$> chunksOf i hs

instance Batchable GetBlockHeights [Store.BlockData] where
    resourceBatch i (GetBlockHeights (HeightsParam hs) n) =
        (`GetBlockHeights` n) <$> (HeightsParam <$> chunksOf i hs)

instance Batchable GetTxs [Store.Transaction] where
    resourceBatch i (GetTxs ts) = GetTxs <$> chunksOf i ts

instance Batchable GetTxsRaw (Store.RawResultList Tx) where
    resourceBatch i (GetTxsRaw ts) = GetTxsRaw <$> chunksOf i ts

instance Batchable GetAddrsTxs [Store.TxRef] where
    resourceBatch i (GetAddrsTxs as l) = (`GetAddrsTxs` l) <$> chunksOf i as

instance Batchable GetAddrsTxsFull [Store.Transaction] where
    resourceBatch i (GetAddrsTxsFull as l) =
        (`GetAddrsTxsFull` l) <$> chunksOf i as

instance Batchable GetAddrsBalance [Store.Balance] where
    resourceBatch i (GetAddrsBalance as) = GetAddrsBalance <$> chunksOf i as

instance Batchable GetAddrsUnspent [Store.Unspent] where
    resourceBatch i (GetAddrsUnspent as l) =
        (`GetAddrsUnspent` l) <$> chunksOf i as

------------------
-- API Internal --
------------------

toOptions ::
       ApiResource a b => Network -> a -> Either String (Endo HTTP.Options)
toOptions net res =
    mconcat <$> mapM f (snd $ queryParams res)
  where
    f (ParamBox p) = toOption net p

toOption :: Param a => Network -> a -> Either String (Endo HTTP.Options)
toOption net a = do
    res <- maybeToEither "Invalid Param" $ encodeParam net a
    return $ applyOpt (paramLabel a) res

applyOpt :: Text -> [Text] -> Endo HTTP.Options
applyOpt p t = Endo $ HTTP.param p .~ [Text.intercalate "," t]

getBinary ::
       (MonadIO m, MonadError String m, S.Serialize a)
    => Endo HTTP.Options
    -> String
    -> m a
getBinary opts url = do
    res <- liftIO $ HTTP.getWith (binaryOpts opts) url
    liftEither $ S.decodeLazy $ res ^. HTTP.responseBody

postBinary ::
       (MonadIO m, MonadError String m, S.Serialize a, S.Serialize r)
    => Endo HTTP.Options
    -> String
    -> a
    -> m r
postBinary opts url body = do
    res <- liftIO $ HTTP.postWith (binaryOpts opts) url (S.encode body)
    liftEither $ S.decodeLazy $ res ^. HTTP.responseBody

binaryOpts :: Endo HTTP.Options -> HTTP.Options
binaryOpts opts =
    appEndo (opts <> accept <> stat) HTTP.defaults
  where
    accept = Endo $ HTTP.header "Accept" .~ ["application/octet-stream"]
    stat   = Endo $ HTTP.checkResponse ?~ checkStatus

-- TODO: Capture this and return JSON error
checkStatus :: ResponseChecker
checkStatus _ r
    | statusIsSuccessful status = return ()
    | otherwise = error $ "HTTP Error " <> show code <> ": " <> cs message
  where
    code = r ^. HTTP.responseStatus . HTTP.statusCode
    message = r ^. HTTP.responseStatus . HTTP.statusMessage
    status = mkStatus code message

---------------
-- Utilities --
---------------

chunksOf :: Natural -> [a] -> [[a]]
chunksOf n xs
    | null xs = []
    | otherwise =
        uncurry (:) $ second (chunksOf n) $ splitAt (fromIntegral n) xs

