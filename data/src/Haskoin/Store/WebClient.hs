{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE Strict                #-}
module Haskoin.Store.WebClient
( ApiConfig(..)
, apiCall
, apiBatch
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
import           Haskoin.Address
import           Haskoin.Block
import           Haskoin.Constants
import           Haskoin.Keys
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
-- { configNetwork = btc
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
          { configNetwork = btc
          , configHost = "https://api.haskoin.com/"
          }

-- | Make a call to the haskoin-store API.
--
-- Usage:
--
-- > apiCall def (AddressTxs addrs) noOpts
--
-- Add an option:
--
-- > apiCall def (AddressUnspent addrs) (optLimit 10)
--
-- Multiple options can be passed with <>:
--
-- > apiCall def (AddressUnspent addrs) (optOffset 5 <> optLimit 10)
--
-- Options are of type @Endo Network.Wreq.Options@ so you can customize them.
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
-- > apiBatch 20 def (AddressTxs addrs) noOpts
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

{- API Internal -}

toOptions ::
       ApiResource a b => Network -> a -> Either String (Endo HTTP.Options)
toOptions net res =
    mconcat <$> mapM f (resourceParams res)
  where
    f (ParamBox p) = toOption net p

toOption :: Param a => Network -> a -> Either String (Endo HTTP.Options)
toOption net a = do
    res <- maybeToEither "Invalid Param" $ encodeParam net a
    return $ applyOpt (paramLabel a) res

-- resourceBatch :: Natural -> ApiResource a -> [ApiResource a]
-- resourceBatch i =
--     \case
--         AddressTxs xs -> AddressTxs <$> chunksOf i xs
--         AddressTxsFull xs -> AddressTxsFull <$> chunksOf i xs
--         AddressBalances xs -> AddressBalances <$> chunksOf i xs
--         AddressUnspent xs -> AddressUnspent <$> chunksOf i xs
--         TxsDetails xs -> TxsDetails <$> chunksOf i xs
--         TxsRaw xs -> TxsRaw <$> chunksOf i xs
--         Blocks xs -> Blocks <$> chunksOf i xs
--         BlockHeights xs -> BlockHeights <$> chunksOf i xs
--         res -> [res]

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

{- Utilities -}

chunksOf :: Natural -> [a] -> [[a]]
chunksOf n xs
    | null xs = []
    | otherwise =
        uncurry (:) $ second (chunksOf n) $ splitAt (fromIntegral n) xs

