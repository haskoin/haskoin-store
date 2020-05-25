{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Strict            #-}
module Haskoin.Store.WebClient
( ApiConfig(..)
, apiCall
, apiBatch
, ApiResource(..)
, noOpts
, optBlockHeight
, optBlockHash
, optUnix
, optTxHash
, optOffset
, optLimit
, optStandard
, optSegwit
, optCompat
, optNoCache
, optNoTx
)

where

import           Control.Arrow             (second)
import           Control.Lens              ((.~), (?~), (^.))
import           Control.Monad.Except      (MonadError)
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
import           Haskoin.Transaction
import           Haskoin.Util
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
       (MonadIO m, MonadError String m, S.Serialize a)
    => ApiConfig
    -> ApiResource a
    -> Endo HTTP.Options
    -> m a
apiCall (ApiConfig net host) res opts = do
    args <- liftEither $ resourceArgs net res
    let url = host <> getNetworkName net <> resourcePath net res
    case res of
        PostTx tx -> postBinary (args <> opts) url tx
        _         -> getBinary (args <> opts) url

-- | Batch commands that have a large list of arguments:
--
-- > apiBatch 20 def (AddressTxs addrs) noOpts
--
apiBatch ::
       ( MonadIO m
       , MonadError String m
       , S.Serialize a
       , Monoid a
       )
    => Natural
    -> ApiConfig
    -> ApiResource a
    -> Endo HTTP.Options
    -> m a
apiBatch i conf res opts = mconcat <$> mapM f (resourceBatch i res)
  where
    f r = apiCall conf r opts

{- API Resources -}

-- | List of available API calls together with arguments and return types.
-- For example:
--
-- > AddressTxs :: [Address] -> ApiResource [TxRef]
--
-- @AddressTxs@ takes a list of addresses @[Address]@ as argument and
-- returns a list of transaction references @[TxRef]@.
data ApiResource a where
    AddressTxs :: [Address] -> ApiResource [Store.TxRef]
    AddressTxsFull :: [Address] -> ApiResource [Store.Transaction]
    AddressBalances :: [Address] -> ApiResource [Store.Balance]
    AddressUnspent :: [Address] -> ApiResource [Store.Unspent]
    XPubEvict :: XPubKey -> ApiResource (Store.GenericResult Bool)
    XPubSummary :: XPubKey -> ApiResource Store.XPubSummary
    XPubTxs :: XPubKey -> ApiResource [Store.TxRef]
    XPubTxsFull :: XPubKey -> ApiResource [Store.Transaction]
    XPubBalances :: XPubKey -> ApiResource [Store.XPubBal]
    XPubUnspent :: XPubKey -> ApiResource [Store.XPubUnspent]
    TxsDetails :: [TxHash] -> ApiResource [Store.Transaction]
    PostTx :: Tx -> ApiResource Store.TxId
    TxsRaw :: [TxHash] -> ApiResource [Tx]
    TxAfter :: TxHash -> Natural -> ApiResource (Store.GenericResult Bool)
    TxsBlock :: BlockHash -> ApiResource [Store.Transaction]
    TxsBlockRaw :: BlockHash -> ApiResource [Tx]
    Mempool :: ApiResource [TxHash]
    Events :: ApiResource [Store.Event]
    BlockBest :: ApiResource Store.BlockData
    BlockBestRaw :: ApiResource (Store.GenericResult Block)
    BlockLatest :: ApiResource [Store.BlockData]
    Blocks :: [BlockHash] -> ApiResource [Store.BlockData]
    BlockRaw :: BlockHash -> ApiResource (Store.GenericResult Block)
    BlockHeight :: Natural -> ApiResource [Store.BlockData]
    BlockHeightRaw :: Natural -> ApiResource [Block]
    BlockHeights :: [Natural] -> ApiResource [Store.BlockData]
    BlockTime :: Natural -> ApiResource Store.BlockData
    BlockTimeRaw :: Natural -> ApiResource (Store.GenericResult Block)
    Health :: ApiResource Store.HealthCheck
    Peers :: ApiResource [Store.PeerInformation]

{- API Options -}

-- | Don't pass any options to @apiCall@
noOpts :: Endo HTTP.Options
noOpts = Endo id

-- | Param: __height__
--
-- If a block height is specified, only entities confirmed at or below that
-- height will be returned.
optBlockHeight :: Natural -> Endo HTTP.Options
optBlockHeight h = applyOpt "height" [cs $ show h]

-- | Param: __height__
--
-- If a block hash is specified, only entities confirmed at or below that
-- block's height will be returned. No filtering will be done if the block
-- cannot be found.
optBlockHash :: BlockHash -> Endo HTTP.Options
optBlockHash h = applyOpt "height" [blockHashToHex h]

-- | Param: __height__
--
-- If a Unix timestamp is specified, find the last block mined at or before that
-- time and return entries confirmed up to that block's height. No filtering
-- will be done if the block cannot be found.
optUnix :: Natural -> Endo HTTP.Options
optUnix u = applyOpt "height" [cs $ show u]

-- | Param: __height__
--
-- If a transaction hash is specified, only entries at or below that
-- transaction's place in the block chain will be returned. No filtering will be
-- done if the transaction cannot be found or is not confirmed.
optTxHash :: TxHash -> Endo HTTP.Options
optTxHash h = applyOpt "height" [txHashToHex h]

-- | Param: __offset__
--
-- Skip this many entries at the start of the result set.
optOffset :: Natural -> Endo HTTP.Options
optOffset o = applyOpt "offset" [cs $ show o]

-- | Param: __limit__
--
-- Maximum number of entries to return.
optLimit :: Natural -> Endo HTTP.Options
optLimit l = applyOpt "limit" [cs $ show l]

-- | Param: __derive__
--
-- standard: derive regular P2PKH addresses.
optStandard :: Endo HTTP.Options
optStandard = applyOpt "derive" ["standard"]

-- | Param: __derive__
--
-- segwit: derive segwit P2WPKH addresses.
optSegwit :: Endo HTTP.Options
optSegwit = applyOpt "derive" ["segwit"]

-- | Param: __derive__
--
-- compat: derive P2SH-P2WPKH backwards-compatible segwit addresses.
optCompat :: Endo HTTP.Options
optCompat = applyOpt "derive" ["compat"]

-- | Param: __nocache__
--
-- Do not use the cache for this query.
optNoCache :: Endo HTTP.Options
optNoCache = applyOpt "nocache" ["true"]

-- | Param: __notx__
--
-- Do not include transactions other than coinbase.
optNoTx :: Endo HTTP.Options
optNoTx = applyOpt "notx" ["true"]

{- API Internal -}

resourceArgs :: Network -> ApiResource a -> Either String (Endo HTTP.Options)
resourceArgs net =
    \case
        AddressTxs as -> argAddrs net as
        AddressTxsFull as -> argAddrs net as
        AddressBalances as -> argAddrs net as
        AddressUnspent as -> argAddrs net as
        TxsDetails hs -> return $ applyOpt "txids" (txHashToHex <$> hs)
        TxsRaw hs -> return $ applyOpt "txids" (txHashToHex <$> hs)
        TxAfter h i ->
            return $
            applyOpt "txid" [txHashToHex h] <> applyOpt "height" [cs $ show i]
        TxsBlock b -> return $ applyOpt "block" [blockHashToHex b]
        TxsBlockRaw b -> return $ applyOpt "block" [blockHashToHex b]
        Blocks bs -> return $ applyOpt "blocks" (blockHashToHex <$> bs)
        BlockRaw b -> return $ applyOpt "block" [blockHashToHex b]
        BlockHeight i -> return $ applyOpt "height" [cs $ show i]
        BlockHeightRaw i -> return $ applyOpt "height" [cs $ show i]
        BlockHeights is -> return $ applyOpt "heights" (cs . show <$> is)
        BlockTime i -> return $ applyOpt "time" [cs $ show i]
        BlockTimeRaw i -> return $ applyOpt "time" [cs $show i]
        _ -> return noOpts

argAddrs :: Network -> [Address] -> Either String (Endo HTTP.Options)
argAddrs net addrs = do
    addrsTxt <- liftEither $ addrToTextE `mapM` addrs
    return $ applyOpt "addresses" addrsTxt
  where
    addrToTextE = maybeToEither "Invalid Address" . addrToString net

resourcePath :: Network -> ApiResource a -> String
resourcePath net =
    \case
        AddressTxs {} -> "/address/transactions"
        AddressTxsFull {} -> "/address/transactions/full"
        AddressBalances {} -> "/address/balances"
        AddressUnspent {} -> "/address/unspent"
        XPubEvict pub -> "/xpub/" <> cs (xPubExport net pub) <> "/evict"
        XPubSummary pub -> "/xpub/" <> cs (xPubExport net pub)
        XPubTxs pub -> "/xpub/" <> cs (xPubExport net pub) <> "/transactions"
        XPubTxsFull pub ->
            "/xpub/" <> cs (xPubExport net pub) <> "/transactions/full"
        XPubBalances pub -> "/xpub/" <> cs (xPubExport net pub) <> "/balances"
        XPubUnspent pub -> "/xpub/" <> cs (xPubExport net pub) <> "/unspent"
        TxsDetails {} -> "/transactions"
        PostTx {} -> "/transactions"
        TxsRaw {} -> "/transactions"
        TxAfter h i ->
            "/transactions/" <> cs (txHashToHex h) <> "/after/" <> show i
        TxsBlock b -> "/transactions/block/" <> cs (blockHashToHex b)
        TxsBlockRaw b ->
            "/transactions/block/" <> cs (blockHashToHex b) <> "/raw"
        Mempool -> "/mempool"
        Events -> "/events"
        BlockBest -> "/block/best"
        BlockBestRaw -> "/block/best/raw"
        BlockLatest -> "/block/latest"
        Blocks {} -> "/blocks"
        BlockRaw b -> "/block/" <> cs (blockHashToHex b) <> "/raw"
        BlockHeight i -> "/block/height/" <> show i
        BlockHeightRaw i -> "/block/height/" <> show i <> "/raw"
        BlockHeights {} -> "/block/heights"
        BlockTime t -> "/block/time/" <> show t
        BlockTimeRaw t -> "/block/time/" <> show t <> "/raw"
        Health -> "/health"
        Peers -> "/peers"

resourceBatch :: Natural -> ApiResource a -> [ApiResource a]
resourceBatch i =
    \case
        AddressTxs xs -> AddressTxs <$> chunksOf i xs
        AddressTxsFull xs -> AddressTxsFull <$> chunksOf i xs
        AddressBalances xs -> AddressBalances <$> chunksOf i xs
        AddressUnspent xs -> AddressUnspent <$> chunksOf i xs
        TxsDetails xs -> TxsDetails <$> chunksOf i xs
        TxsRaw xs -> TxsRaw <$> chunksOf i xs
        Blocks xs -> Blocks <$> chunksOf i xs
        BlockHeights xs -> BlockHeights <$> chunksOf i xs
        res -> [res]

{- API Helpers -}

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

