{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
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
, DelCachedXPub(..)
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
import           Control.Exception
import           Control.Lens              ((.~), (?~), (^.))
import           Control.Monad.Except
import qualified Data.Aeson                as A
import qualified Data.ByteString.Lazy      as BL
import           Data.Bytes.Get
import           Data.Bytes.Put
import           Data.Bytes.Serial
import           Data.Default              (Default, def)
import           Data.Monoid               (Endo (..), appEndo)
import           Data.String.Conversions   (cs)
import           Data.Text                 (Text)
import qualified Data.Text                 as Text
import           Haskoin.Constants
import qualified Haskoin.Store.Data        as Store
import           Haskoin.Store.WebCommon
import           Haskoin.Transaction
import           Haskoin.Util
import           Network.HTTP.Client       (Request (..))
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
    { configNetwork :: !Network
    , configHost    :: !String
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
       (ApiResource a b, MonadIO m, MonadError Store.Except m)
    => ApiConfig
    -> a
    -> m b
apiCall (ApiConfig net apiHost) res = do
    args <- liftEither $ toOptions net res
    let url = apiHost <> getNetworkName net <> cs (queryPath net res)
    case resourceMethod $ asProxy res of
        GET -> liftEither =<< liftIO (getBinary args url)
        POST ->
            case resourceBody res of
                Just (PostBox val) ->
                    liftEither =<< liftIO (postBinary args url val)
                _ -> throwError $ Store.StringError "Could not post resource"
        _ -> throwError $ Store.StringError "Unsupported HTTP method"

-- | Batch commands that have a large list of arguments:
--
-- > apiBatch 20 def (GetAddrsTxs addrs def)
--
apiBatch ::
       (Batchable a b, MonadIO m, MonadError Store.Except m)
    => Natural
    -> ApiConfig
    -> a
    -> m b
apiBatch i conf res = mconcat <$> mapM (apiCall conf) (resourceBatch i res)

class (ApiResource a b, Monoid b) => Batchable a b where
    resourceBatch :: Natural -> a -> [a]

instance Batchable GetBlocks (Store.SerialList Store.BlockData) where
    resourceBatch i (GetBlocks hs t) =
        (`GetBlocks` t) <$> chunksOf i hs

instance Batchable GetBlockHeights (Store.SerialList Store.BlockData) where
    resourceBatch i (GetBlockHeights (HeightsParam hs) n) =
        (`GetBlockHeights` n) <$>
        (HeightsParam <$> chunksOf i hs)

instance Batchable GetTxs (Store.SerialList Store.Transaction) where
    resourceBatch i (GetTxs ts) =
        GetTxs <$> chunksOf i ts

instance Batchable GetTxsRaw (Store.RawResultList Tx) where
    resourceBatch i (GetTxsRaw ts) =
        GetTxsRaw <$> chunksOf i ts

instance Batchable GetAddrsTxs (Store.SerialList Store.TxRef) where
    resourceBatch i (GetAddrsTxs as l) =
        (`GetAddrsTxs` l) <$> chunksOf i as

instance Batchable GetAddrsTxsFull (Store.SerialList Store.Transaction) where
    resourceBatch i (GetAddrsTxsFull as l) =
        (`GetAddrsTxsFull` l) <$> chunksOf i as

instance Batchable GetAddrsBalance (Store.SerialList Store.Balance) where
    resourceBatch i (GetAddrsBalance as) =
        GetAddrsBalance <$> chunksOf i as

instance Batchable GetAddrsUnspent (Store.SerialList Store.Unspent) where
    resourceBatch i (GetAddrsUnspent as l) =
        (`GetAddrsUnspent` l) <$> chunksOf i as

------------------
-- API Internal --
------------------

toOptions ::
       ApiResource a b => Network -> a -> Either Store.Except (Endo HTTP.Options)
toOptions net res =
    mconcat <$> mapM f (snd $ queryParams res)
  where
    f (ParamBox p) = toOption net p

toOption :: Param a => Network -> a -> Either Store.Except (Endo HTTP.Options)
toOption net a = do
    res <- maybeToEither (Store.UserError "Invalid Param") $ encodeParam net a
    return $ applyOpt (paramLabel a) res

applyOpt :: Text -> [Text] -> Endo HTTP.Options
applyOpt p t = Endo $ HTTP.param p .~ [Text.intercalate "," t]

getBinary ::
       Serial a
    => Endo HTTP.Options
    -> String
    -> IO (Either Store.Except a)
getBinary opts url = do
    resE <- try $ HTTP.getWith (binaryOpts opts) url
    return $ do
        res <- resE
        toExcept $ runGetS deserialize $ BL.toStrict $ res ^. HTTP.responseBody

postBinary ::
       (Serial a, Serial r)
    => Endo HTTP.Options
    -> String
    -> a
    -> IO (Either Store.Except r)
postBinary opts url body = do
    resE <- try $ HTTP.postWith (binaryOpts opts) url (runPutL (serialize body))
    return $ do
        res <- resE
        toExcept $ runGetL deserialize $ res ^. HTTP.responseBody

binaryOpts :: Endo HTTP.Options -> HTTP.Options
binaryOpts opts =
    appEndo (opts <> accept <> stat) HTTP.defaults
  where
    accept = Endo $ HTTP.header "Accept" .~ ["application/octet-stream"]
    stat   = Endo $ HTTP.checkResponse ?~ checkStatus

checkStatus :: ResponseChecker
checkStatus req res
    | statusIsSuccessful status = return ()
    | isHealthPath && code == 503 = return () -- Ignore health checks
    | otherwise = do
        e <- A.decodeStrict <$> res ^. HTTP.responseBody
        throwIO $
            case e of
                Just except -> except :: Store.Except
                Nothing     -> Store.StringError "could not decode error"
  where
    code = res ^. HTTP.responseStatus . HTTP.statusCode
    message = res ^. HTTP.responseStatus . HTTP.statusMessage
    status = mkStatus code message
    isHealthPath = "/health" `Text.isInfixOf` cs (path req)

---------------
-- Utilities --
---------------

toExcept :: Either String a -> Either Store.Except a
toExcept (Right a)  = Right a
toExcept (Left err) = Left $ Store.UserError err

chunksOf :: Natural -> [a] -> [[a]]
chunksOf n xs
    | null xs = []
    | otherwise =
        uncurry (:) $ second (chunksOf n) $ splitAt (fromIntegral n) xs

