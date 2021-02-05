{-# LANGUAGE CPP                 #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE MultiWayIf          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TupleSections       #-}
module Haskoin.Store.Web
    ( -- * Web
      WebConfig (..)
    , Except (..)
    , WebLimits (..)
    , WebTimeouts (..)
    , runWeb
    ) where

import           Conduit                       (await, runConduit, takeC, yield,
                                                (.|))
import           Control.Applicative           ((<|>))
import           Control.Arrow                 (second)
import           Control.Lens
import           Control.Monad                 (forever, unless, when, (<=<))
import           Control.Monad.Logger          (MonadLoggerIO, logDebugS,
                                                logErrorS, logInfoS)
import           Control.Monad.Reader          (ReaderT, ask, asks, local,
                                                runReaderT)
import           Control.Monad.Trans           (lift)
import           Control.Monad.Trans.Control   (liftWith, restoreT)
import           Control.Monad.Trans.Maybe     (MaybeT (..), runMaybeT)
import           Data.Aeson                    (Encoding, ToJSON (..), Value)
import           Data.Aeson.Encode.Pretty      (Config (..), defConfig,
                                                encodePretty')
import           Data.Aeson.Encoding           (encodingToLazyByteString, list)
import           Data.Aeson.Text               (encodeToLazyText)
import           Data.ByteString.Builder       (lazyByteString)
import qualified Data.ByteString.Lazy          as L
import qualified Data.ByteString.Lazy.Char8    as C
import           Data.Char                     (isSpace)
import           Data.Default                  (Default (..))
import           Data.Function                 ((&))
import           Data.HashMap.Strict           (HashMap)
import qualified Data.HashMap.Strict           as HashMap
import qualified Data.HashSet                  as HashSet
import           Data.Int                      (Int64)
import           Data.List                     (nub)
import qualified Data.Map.Strict               as Map
import           Data.Maybe                    (catMaybes, fromJust, fromMaybe,
                                                listToMaybe, mapMaybe)
import           Data.Proxy                    (Proxy (..))
import           Data.Serialize                as Serialize
import qualified Data.Set                      as Set
import           Data.String                   (fromString)
import           Data.String.Conversions       (cs)
import           Data.Text                     (Text)
import qualified Data.Text                     as T
import qualified Data.Text.Encoding            as T
import           Data.Text.Lazy                (toStrict)
import qualified Data.Text.Lazy                as TL
import           Data.Time.Clock               (NominalDiffTime, diffUTCTime,
                                                getCurrentTime)
import           Data.Time.Clock.System        (getSystemTime, systemSeconds)
import           Data.Word                     (Word32, Word64)
import           Database.RocksDB              (Property (..), getProperty)
import           Haskoin.Address
import qualified Haskoin.Block                 as H
import           Haskoin.Constants
import           Haskoin.Keys
import           Haskoin.Network
import           Haskoin.Node                  (Chain, OnlinePeer (..),
                                                PeerManager, chainGetBest,
                                                getPeers, sendMessage)
import           Haskoin.Store.BlockStore
import           Haskoin.Store.Cache
import           Haskoin.Store.Common
import           Haskoin.Store.Data
import           Haskoin.Store.Database.Reader
import           Haskoin.Store.Manager
import           Haskoin.Store.WebCommon
import           Haskoin.Transaction
import           Haskoin.Util
import           Network.HTTP.Types            (Status (..), status400,
                                                status403, status404, status500,
                                                status503, statusIsSuccessful)
import           Network.Wai                   (Middleware, Request (..),
                                                responseStatus)
import           Network.Wai.Handler.Warp      (defaultSettings, setHost,
                                                setPort)
import qualified Network.Wreq                  as Wreq
import           NQE                           (Inbox, receive,
                                                withSubscription)
import qualified System.Metrics                as Metrics
import qualified System.Metrics.Counter        as Metrics.Counter
import qualified System.Metrics.Counter        as Metrics (Counter)
import qualified System.Metrics.Distribution   as Metrics (Distribution)
import qualified System.Metrics.Distribution   as Metrics.Distribution
import qualified System.Metrics.Gauge          as Metrics (Gauge)
import qualified System.Metrics.Gauge          as Metrics.Gauge
import           Text.Printf                   (printf)
import           UnliftIO                      (MonadIO, MonadUnliftIO, TVar,
                                                askRunInIO, atomically, bracket,
                                                bracket_, handleAny, liftIO,
                                                newTVarIO, readTVarIO, timeout,
                                                withAsync, writeTVar)
import           UnliftIO.Concurrent           (threadDelay)
import           Web.Scotty.Internal.Types     (ActionT)
import           Web.Scotty.Trans              (Parsable)
import qualified Web.Scotty.Trans              as S

type WebT m = ActionT Except (ReaderT WebState m)

data WebLimits = WebLimits
    { maxLimitCount      :: !Word32
    , maxLimitFull       :: !Word32
    , maxLimitOffset     :: !Word32
    , maxLimitDefault    :: !Word32
    , maxLimitGap        :: !Word32
    , maxLimitInitialGap :: !Word32
    }
    deriving (Eq, Show)

instance Default WebLimits where
    def =
        WebLimits
            { maxLimitCount = 200000
            , maxLimitFull = 5000
            , maxLimitOffset = 50000
            , maxLimitDefault = 100
            , maxLimitGap = 32
            , maxLimitInitialGap = 20
            }

data WebConfig = WebConfig
    { webHost       :: !String
    , webPort       :: !Int
    , webStore      :: !Store
    , webMaxDiff    :: !Int
    , webMaxPending :: !Int
    , webMaxLimits  :: !WebLimits
    , webTimeouts   :: !WebTimeouts
    , webVersion    :: !String
    , webNoMempool  :: !Bool
    , webNumTxId    :: !Bool
    , webStats      :: !(Maybe Metrics.Store)
    }

data WebState = WebState
    { webConfig  :: !WebConfig
    , webTicker  :: !(TVar (HashMap Text BinfoTicker))
    , webMetrics :: !(Maybe WebMetrics)
    }

data WebMetrics = WebMetrics
    { totalRequests           :: !Metrics.Counter
    , responseTime            :: !Metrics.Distribution
    , blockRequests           :: !Metrics.Counter
    , blockResponseTime       :: !Metrics.Distribution
    , blockItems              :: !Metrics.Counter
    , rawBlockRequests        :: !Metrics.Counter
    , rawBlockResponseTime    :: !Metrics.Distribution
    , rawBlockItems           :: !Metrics.Counter
    , txRequests              :: !Metrics.Counter
    , txResponseTime          :: !Metrics.Distribution
    , txBlockRequests         :: !Metrics.Counter
    , txBlockResponseTime     :: !Metrics.Distribution
    , txItems                 :: !Metrics.Counter
    , txAfterRequests         :: !Metrics.Counter
    , txAfterResponseTime     :: !Metrics.Distribution
    , postTxRequests          :: !Metrics.Counter
    , postTxResponseTime      :: !Metrics.Distribution
    , mempoolRequests         :: !Metrics.Counter
    , mempoolResponseTime     :: !Metrics.Distribution
    , addrTxRequests          :: !Metrics.Counter
    , addrTxResponseTime      :: !Metrics.Distribution
    , addrTxItems             :: !Metrics.Counter
    , addrBalanceRequests     :: !Metrics.Counter
    , addrBalanceResponseTime :: !Metrics.Distribution
    , addrBalanceItems        :: !Metrics.Counter
    , addrUnspentRequests     :: !Metrics.Counter
    , addrUnspentResponseTime :: !Metrics.Distribution
    , addrUnspentItems        :: !Metrics.Counter
    , xPubRequests            :: !Metrics.Counter
    , xPubResponseTime        :: !Metrics.Distribution
    , xPubTxRequests          :: !Metrics.Counter
    , xPubTxResponseTime      :: !Metrics.Distribution
    , xPubTxFullRequests      :: !Metrics.Counter
    , xPubTxFullResponseTime  :: !Metrics.Distribution
    , xPubUnspentRequests     :: !Metrics.Counter
    , xPubUnspentResponseTime :: !Metrics.Distribution
    , xPubEvictRequests       :: !Metrics.Counter
    , xPubEvictResponseTime   :: !Metrics.Distribution
    , multiaddrRequests       :: !Metrics.Counter
    , multiaddrResponseTime   :: !Metrics.Distribution
    , multiaddrItems          :: !Metrics.Counter
    , rawtxRequests           :: !Metrics.Counter
    , rawtxResponseTime       :: !Metrics.Distribution
    , peerRequests            :: !Metrics.Counter
    , peerResponseTime        :: !Metrics.Distribution
    , healthRequests          :: !Metrics.Counter
    , healthResponseTime      :: !Metrics.Distribution
    , dbStatsRequests         :: !Metrics.Counter
    , dbStatsResponseTime     :: !Metrics.Distribution
    , eventsConnected         :: !Metrics.Gauge
    }

createMetrics :: MonadIO m => Metrics.Store -> m WebMetrics
createMetrics s = liftIO $ do
    totalRequests             <- c "requests"
    responseTime              <- d "response_time"
    blockRequests             <- c "block.requests"
    blockResponseTime         <- d "block.response_time"
    blockItems                <- c "block.items"
    rawBlockRequests          <- c "block_raw.requests"
    rawBlockResponseTime      <- d "block_raw.response_time"
    rawBlockItems             <- c "block_raw.items"
    txRequests                <- c "tx.requests"
    txResponseTime            <- d "tx.response_time"
    txItems                   <- c "tx.items"
    txAfterRequests           <- c "tx_after.requests"
    txAfterResponseTime       <- d "tx_after.response_time"
    txBlockRequests           <- c "tx_block.requests"
    txBlockResponseTime       <- d "tx_block.response_time"
    postTxRequests            <- c "tx_post.requests"
    postTxResponseTime        <- d "tx_post.response_time"
    mempoolRequests           <- c "mempool.requests"
    mempoolResponseTime       <- d "mempool.response_time"
    addrTxRequests            <- c "addr_tx.requests"
    addrTxResponseTime        <- d "addr_tx.response_time"
    addrTxItems               <- c "addr_tx.items"
    addrBalanceRequests       <- c "addr_balance.requests"
    addrBalanceResponseTime   <- d "addr_balance.response_time"
    addrBalanceItems          <- c "addr_balance.items"
    addrUnspentRequests       <- c "addr_unspent.requests"
    addrUnspentResponseTime   <- d "addr_unspent.response_time"
    addrUnspentItems          <- c "addr_unspent.items"
    xPubRequests              <- c "xpub.requests"
    xPubResponseTime          <- d "xpub.response_time"
    xPubTxRequests            <- c "xpub_tx.requests"
    xPubTxResponseTime        <- d "xpub_tx.response_time"
    xPubTxFullRequests        <- c "xpub_tx_full.requests"
    xPubTxFullResponseTime    <- d "xpub_tx_full.response_time"
    xPubUnspentRequests       <- c "xpub_tx_full.requests"
    xPubUnspentResponseTime   <- d "xpub_tx_full.response_time"
    xPubEvictRequests         <- c "xpub_evict.requests"
    xPubEvictResponseTime     <- d "xpub_evict.response_time"
    multiaddrRequests         <- c "multiaddr.requests"
    multiaddrResponseTime     <- d "multiaddr.response_time"
    multiaddrItems            <- c "multiaddr.items"
    rawtxRequests             <- c "rawtx.requests"
    rawtxResponseTime         <- d "rawtx.response_time"
    peerRequests              <- c "peer.requests"
    peerResponseTime          <- d "peer.response_time"
    healthRequests            <- c "health.requests"
    healthResponseTime        <- d "health.response_time"
    dbStatsRequests           <- c "dbstats.requests"
    dbStatsResponseTime       <- d "dbstats.response_time"
    eventsConnected           <- g "events.connected"
    return WebMetrics{..}
  where
    c x = Metrics.createCounter      ("haskoin.store.web" <> x) s
    d x = Metrics.createDistribution ("haskoin.store.web" <> x) s
    g x = Metrics.createGauge        ("haskoin.store.web" <> x) s

withGaugeIncrease :: MonadUnliftIO m
                  => (WebMetrics -> Metrics.Gauge)
                  -> WebT m a
                  -> WebT m a
withGaugeIncrease gf go =
    lift (asks webMetrics) >>= \case
        Nothing -> go
        Just m -> do
            s <- liftWith $ \run ->
                bracket_
                (start m)
                (end m)
                (run go)
            restoreT $ return s
  where
    start m = liftIO $ Metrics.Gauge.inc (gf m)
    end m = liftIO $ Metrics.Gauge.dec (gf m)

withMetrics :: MonadUnliftIO m
            => (WebMetrics -> Metrics.Counter)
            -> (WebMetrics -> Metrics.Distribution)
            -> (Maybe (WebMetrics -> Metrics.Counter, Int64))
            -> WebT m a
            -> WebT m a
withMetrics cf df mi go =
    lift (asks webMetrics) >>= \case
        Nothing -> go
        Just m -> do
            s <- liftWith $ \run ->
                nostats $
                bracket
                (liftIO getCurrentTime)
                (end m)
                (const (run go))
            restoreT $ return s
  where
    nostats = local $ \s -> s { webMetrics = Nothing }
    end metrics t1 = do
        t2 <- liftIO getCurrentTime
        let diff = realToFrac $ diffUTCTime t2 t1 * 1000
            c = cf metrics
            d = df metrics
        liftIO $ Metrics.Counter.inc (totalRequests metrics)
        liftIO $ Metrics.Distribution.add (responseTime metrics) diff
        liftIO $ Metrics.Counter.inc c
        liftIO $ Metrics.Distribution.add d diff
        case mi of
            Nothing -> return ()
            Just (fi, n) -> do
                let i = fi metrics
                liftIO $ Metrics.Counter.add i n

data WebTimeouts = WebTimeouts
    { txTimeout    :: !Word64
    , blockTimeout :: !Word64
    }
    deriving (Eq, Show)

data SerialAs = SerialAsBinary | SerialAsJSON | SerialAsPrettyJSON
    deriving (Eq, Show)

instance Default WebTimeouts where
    def = WebTimeouts {txTimeout = 300, blockTimeout = 7200}

instance (MonadUnliftIO m, MonadLoggerIO m) =>
         StoreReadBase (ReaderT WebState m) where
    getNetwork = runInWebReader getNetwork
    getBestBlock = runInWebReader getBestBlock
    getBlocksAtHeight height = runInWebReader (getBlocksAtHeight height)
    getBlock bh = runInWebReader (getBlock bh)
    getTxData th = runInWebReader (getTxData th)
    getSpender op = runInWebReader (getSpender op)
    getUnspent op = runInWebReader (getUnspent op)
    getBalance a = runInWebReader (getBalance a)
    getMempool = runInWebReader getMempool

instance (MonadUnliftIO m, MonadLoggerIO m) =>
         StoreReadExtra (ReaderT WebState m) where
    getMaxGap = runInWebReader getMaxGap
    getInitialGap = runInWebReader getInitialGap
    getBalances as = runInWebReader (getBalances as)
    getAddressesTxs as = runInWebReader . getAddressesTxs as
    getAddressesUnspents as = runInWebReader . getAddressesUnspents as
    xPubBals = runInWebReader . xPubBals
    xPubSummary = runInWebReader . xPubSummary
    xPubUnspents xpub = runInWebReader . xPubUnspents xpub
    xPubTxs xpub = runInWebReader . xPubTxs xpub

instance (MonadUnliftIO m, MonadLoggerIO m) => StoreReadBase (WebT m) where
    getNetwork = lift getNetwork
    getBestBlock = lift getBestBlock
    getBlocksAtHeight = lift . getBlocksAtHeight
    getBlock = lift . getBlock
    getTxData = lift . getTxData
    getSpender = lift . getSpender
    getUnspent = lift . getUnspent
    getBalance = lift . getBalance
    getMempool = lift getMempool

instance (MonadUnliftIO m, MonadLoggerIO m) => StoreReadExtra (WebT m) where
    getBalances = lift . getBalances
    getAddressesTxs as = lift . getAddressesTxs as
    getAddressesUnspents as = lift . getAddressesUnspents as
    xPubBals = lift . xPubBals
    xPubSummary = lift . xPubSummary
    xPubUnspents xpub = lift . xPubUnspents xpub
    xPubTxs xpub = lift . xPubTxs xpub
    getMaxGap = lift getMaxGap
    getInitialGap = lift getInitialGap

-------------------
-- Path Handlers --
-------------------

runWeb :: (MonadUnliftIO m, MonadLoggerIO m) => WebConfig -> m ()
runWeb cfg@WebConfig{ webHost = host
                    , webPort = port
                    , webStore = store
                    , webStats = stats
                    } = do
    ticker <- newTVarIO HashMap.empty
    metrics <- mapM createMetrics stats
    let st = WebState { webConfig = cfg, webTicker = ticker, webMetrics = metrics }
    withAsync (price (storeNetwork store) ticker) $ \_ -> do
        reqLogger <- logIt
        runner <- askRunInIO
        S.scottyOptsT opts (runner . (`runReaderT` st)) $ do
            S.middleware reqLogger
            S.defaultHandler defHandler
            handlePaths
            S.notFound $ S.raise ThingNotFound
  where
    opts = def {S.settings = settings defaultSettings}
    settings = setPort port . setHost (fromString host)

price :: (MonadUnliftIO m, MonadLoggerIO m)
      => Network
      -> TVar (HashMap Text BinfoTicker)
      -> m ()
price net v =
    case code of
        Nothing -> return ()
        Just s  -> go s
  where
    code | net == btc = Just "btc"
         | net == bch = Just "bch"
         | otherwise = Nothing
    go s = forever $ do
        let err e = $(logErrorS) "Price" $ cs (show e)
            url = "https://api.blockchain.info/ticker" <> "?" <>
                  "base" <> "=" <> s
        handleAny err $ do
            r <- liftIO $ Wreq.asJSON =<< Wreq.get url
            atomically . writeTVar v $ r ^. Wreq.responseBody
        threadDelay $ 5 * 60 * 1000 * 1000 -- five minutes


defHandler :: Monad m => Except -> WebT m ()
defHandler e = do
    proto <- setupContentType False
    case e of
        ThingNotFound -> S.status status404
        BadRequest    -> S.status status400
        UserError _   -> S.status status400
        StringError _ -> S.status status400
        ServerError   -> S.status status500
        BlockTooLarge -> S.status status403
    S.raw $ protoSerial proto toEncoding toJSON e

handlePaths :: (MonadUnliftIO m, MonadLoggerIO m)
            => S.ScottyT Except (ReaderT WebState m) ()
handlePaths = do
    -- Block Paths
    pathPretty
        (GetBlock <$> paramLazy <*> paramDef)
        scottyBlock
        blockDataToEncoding
        blockDataToJSON
    pathCompact
        (GetBlocks <$> param <*> paramDef)
        scottyBlocks
        (list . blockDataToEncoding)
        (json_list blockDataToJSON)
    pathCompact
        (GetBlockRaw <$> paramLazy)
        scottyBlockRaw
        (const toEncoding)
        (const toJSON)
    pathPretty
        (GetBlockBest <$> paramDef)
        scottyBlockBest
        blockDataToEncoding
        blockDataToJSON
    pathCompact
        (GetBlockBestRaw & return)
        scottyBlockBestRaw
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetBlockLatest <$> paramDef)
        scottyBlockLatest
        (list . blockDataToEncoding)
        (json_list blockDataToJSON)
    pathPretty
        (GetBlockHeight <$> paramLazy <*> paramDef)
        scottyBlockHeight
        (list . blockDataToEncoding)
        (json_list blockDataToJSON)
    pathCompact
        (GetBlockHeights <$> param <*> paramDef)
        scottyBlockHeights
        (list . blockDataToEncoding)
        (json_list blockDataToJSON)
    pathCompact
        (GetBlockHeightRaw <$> paramLazy)
        scottyBlockHeightRaw
        (const toEncoding)
        (const toJSON)
    pathPretty
        (GetBlockTime <$> paramLazy <*> paramDef)
        scottyBlockTime
        blockDataToEncoding
        blockDataToJSON
    pathCompact
        (GetBlockTimeRaw <$> paramLazy)
        scottyBlockTimeRaw
        (const toEncoding)
        (const toJSON)
    pathPretty
        (GetBlockMTP <$> paramLazy <*> paramDef)
        scottyBlockMTP
        blockDataToEncoding
        blockDataToJSON
    pathCompact
        (GetBlockMTPRaw <$> paramLazy)
        scottyBlockMTPRaw
        (const toEncoding)
        (const toJSON)
    -- Transaction Paths
    pathPretty
        (GetTx <$> paramLazy)
        scottyTx
        transactionToEncoding
        transactionToJSON
    pathCompact
        (GetTxs <$> param)
        scottyTxs
        (list . transactionToEncoding)
        (json_list transactionToJSON)
    pathCompact
        (GetTxRaw <$> paramLazy)
        scottyTxRaw
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetTxsRaw <$> param)
        scottyTxsRaw
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetTxsBlock <$> paramLazy)
        scottyTxsBlock
        (list . transactionToEncoding)
        (json_list transactionToJSON)
    pathCompact
        (GetTxsBlockRaw <$> paramLazy)
        scottyTxsBlockRaw
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetTxAfter <$> paramLazy <*> paramLazy)
        scottyTxAfter
        (const toEncoding)
        (const toJSON)
    pathCompact
        (PostTx <$> parseBody)
        scottyPostTx
        (const toEncoding)
        (const toJSON)
    pathPretty
        (GetMempool <$> paramOptional <*> parseOffset)
        scottyMempool
        (const toEncoding)
        (const toJSON)
    -- Address Paths
    pathPretty
        (GetAddrTxs <$> paramLazy <*> parseLimits)
        scottyAddrTxs
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetAddrsTxs <$> param <*> parseLimits)
        scottyAddrsTxs
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetAddrTxsFull <$> paramLazy <*> parseLimits)
        scottyAddrTxsFull
        (list . transactionToEncoding)
        (json_list transactionToJSON)
    pathCompact
        (GetAddrsTxsFull <$> param <*> parseLimits)
        scottyAddrsTxsFull
        (list . transactionToEncoding)
        (json_list transactionToJSON)
    pathPretty
        (GetAddrBalance <$> paramLazy)
        scottyAddrBalance
        balanceToEncoding
        balanceToJSON
    pathCompact
        (GetAddrsBalance <$> param)
        scottyAddrsBalance
        (list . balanceToEncoding)
        (json_list balanceToJSON)
    pathPretty
        (GetAddrUnspent <$> paramLazy <*> parseLimits)
        scottyAddrUnspent
        (list . unspentToEncoding)
        (json_list unspentToJSON)
    pathCompact
        (GetAddrsUnspent <$> param <*> parseLimits)
        scottyAddrsUnspent
        (list . unspentToEncoding)
        (json_list unspentToJSON)
    -- XPubs
    pathPretty
        (GetXPub <$> paramLazy <*> paramDef <*> paramDef)
        scottyXPub
        (const toEncoding)
        (const toJSON)
    pathPretty
        (GetXPubTxs <$> paramLazy <*> paramDef <*> parseLimits <*> paramDef)
        scottyXPubTxs
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetXPubTxsFull <$> paramLazy <*> paramDef <*> parseLimits <*> paramDef)
        scottyXPubTxsFull
        (list . transactionToEncoding)
        (json_list transactionToJSON)
    pathPretty
        (GetXPubBalances <$> paramLazy <*> paramDef <*> paramDef)
        scottyXPubBalances
        (list . xPubBalToEncoding)
        (json_list xPubBalToJSON)
    pathPretty
        (GetXPubUnspent <$> paramLazy <*> paramDef <*> parseLimits <*> paramDef)
        scottyXPubUnspent
        (list . xPubUnspentToEncoding)
        (json_list xPubUnspentToJSON)
    pathCompact
        (GetXPubEvict <$> paramLazy <*> paramDef)
        scottyXPubEvict
        (const toEncoding)
        (const toJSON)
    -- Network
    pathPretty
        (GetPeers & return)
        scottyPeers
        (const toEncoding)
        (const toJSON)
    pathPretty
         (GetHealth & return)
         scottyHealth
         (const toEncoding)
         (const toJSON)
    S.get "/events" scottyEvents
    S.get "/dbstats" scottyDbStats
    -- Blockchain.info
    S.post "/blockchain/multiaddr" scottyMultiAddr
    S.get "/blockchain/rawtx/:txid" scottyBinfoTx
  where
    json_list f net = toJSONList . map (f net)

pathPretty ::
       (ApiResource a b, MonadIO m)
    => WebT m a
    -> (a -> WebT m b)
    -> (Network -> b -> Encoding)
    -> (Network -> b -> Value)
    -> S.ScottyT Except (ReaderT WebState m) ()
pathPretty parser action encJson encValue =
    pathCommon parser action encJson encValue True

pathCompact ::
       (ApiResource a b, MonadIO m)
    => WebT m a
    -> (a -> WebT m b)
    -> (Network -> b -> Encoding)
    -> (Network -> b -> Value)
    -> S.ScottyT Except (ReaderT WebState m) ()
pathCompact parser action encJson encValue =
    pathCommon parser action encJson encValue False

pathCommon ::
       (ApiResource a b, MonadIO m)
    => WebT m a
    -> (a -> WebT m b)
    -> (Network -> b -> Encoding)
    -> (Network -> b -> Value)
    -> Bool
    -> S.ScottyT Except (ReaderT WebState m) ()
pathCommon parser action encJson encValue pretty =
    S.addroute (resourceMethod proxy) (capturePath proxy) $ do
        setHeaders
        proto <- setupContentType pretty
        net <- lift $ asks (storeNetwork . webStore . webConfig)
        apiRes <- parser
        res <- action apiRes
        S.raw $ protoSerial proto (encJson net) (encValue net) res
  where
    toProxy :: WebT m a -> Proxy a
    toProxy = const Proxy
    proxy = toProxy parser

protoSerial
    :: Serialize a
    => SerialAs
    -> (a -> Encoding)
    -> (a -> Value)
    -> a
    -> L.ByteString
protoSerial SerialAsBinary _ _     = runPutLazy . put
protoSerial SerialAsJSON f _       = encodingToLazyByteString . f
protoSerial SerialAsPrettyJSON _ g =
    encodePretty' defConfig {confTrailingNewline = True} . g

setHeaders :: (Monad m, S.ScottyError e) => ActionT e m ()
setHeaders = S.setHeader "Access-Control-Allow-Origin" "*"

setupContentType :: Monad m => Bool -> ActionT Except m SerialAs
setupContentType pretty = do
    accept <- S.header "accept"
    maybe goJson setType accept
  where
    setType "application/octet-stream" = goBinary
    setType _                          = goJson
    goBinary = do
        S.setHeader "Content-Type" "application/octet-stream"
        return SerialAsBinary
    goJson = do
        S.setHeader "Content-Type" "application/json"
        p <- S.param "pretty" `S.rescue` const (return pretty)
        return $ if p then SerialAsPrettyJSON else SerialAsJSON

-- GET Block / GET Blocks --

scottyBlock ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetBlock -> WebT m BlockData
scottyBlock (GetBlock h (NoTx noTx)) =
    withMetrics
    blockRequests
    blockResponseTime
    (Just (blockItems, 1)) $
    maybe (S.raise ThingNotFound) (return . pruneTx noTx) =<< getBlock h

scottyBlocks ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetBlocks -> WebT m [BlockData]
scottyBlocks (GetBlocks hs (NoTx noTx)) =
    withMetrics
        blockRequests
        blockResponseTime
        (Just (blockItems, fromIntegral (length hs))) $
    (pruneTx noTx <$>) . catMaybes <$> mapM getBlock (nub hs)

pruneTx :: Bool -> BlockData -> BlockData
pruneTx False b = b
pruneTx True b  = b {blockDataTxs = take 1 (blockDataTxs b)}

-- GET BlockRaw --

scottyBlockRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockRaw
    -> WebT m (RawResult H.Block)
scottyBlockRaw (GetBlockRaw h) =
    withMetrics
        rawBlockRequests
        rawBlockResponseTime
        (Just (rawBlockItems, 1)) $
    RawResult <$> getRawBlock h

getRawBlock ::
       (MonadUnliftIO m, MonadLoggerIO m) => H.BlockHash -> WebT m H.Block
getRawBlock h =
    withMetrics
        rawBlockRequests
        rawBlockResponseTime
        (Just (rawBlockItems, 1)) $
    do
    b <- maybe (S.raise ThingNotFound) return =<< getBlock h
    refuseLargeBlock b
    toRawBlock b

toRawBlock :: (Monad m, StoreReadBase m) => BlockData -> m H.Block
toRawBlock b = do
    let ths = blockDataTxs b
    txs <- map transactionData . catMaybes <$> mapM getTransaction ths
    return H.Block {H.blockHeader = blockDataHeader b, H.blockTxns = txs}

refuseLargeBlock :: Monad m => BlockData -> WebT m ()
refuseLargeBlock BlockData {blockDataTxs = txs} = do
    WebLimits {maxLimitFull = f} <- lift $ asks (webMaxLimits . webConfig)
    when (length txs > fromIntegral f) $ S.raise BlockTooLarge

-- GET BlockBest / BlockBestRaw --

scottyBlockBest ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetBlockBest -> WebT m BlockData
scottyBlockBest (GetBlockBest noTx) =
    withMetrics
        blockRequests
        blockResponseTime
        (Just (blockItems, 1)) $
    do
    bestM <- getBestBlock
    maybe (S.raise ThingNotFound) (scottyBlock . (`GetBlock` noTx)) bestM

scottyBlockBestRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockBestRaw
    -> WebT m (RawResult H.Block)
scottyBlockBestRaw _ =
    withMetrics
        rawBlockRequests
        rawBlockResponseTime
        (Just (rawBlockItems, 1)) $
    do
    RawResult <$> (maybe (S.raise ThingNotFound) getRawBlock =<< getBestBlock)

-- GET BlockLatest --

scottyBlockLatest ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockLatest
    -> WebT m [BlockData]
scottyBlockLatest (GetBlockLatest (NoTx noTx)) =
    withMetrics
        blockRequests
        blockResponseTime
        (Just (blockItems, 100)) $
    maybe (S.raise ThingNotFound) (go [] <=< getBlock) =<< getBestBlock
  where
    go acc Nothing = return acc
    go acc (Just b)
        | blockDataHeight b <= 0 = return acc
        | length acc == 99 = return (b:acc)
        | otherwise = do
            let prev = H.prevBlock (blockDataHeader b)
            go (pruneTx noTx b : acc) =<< getBlock prev

-- GET BlockHeight / BlockHeights / BlockHeightRaw --

scottyBlockHeight ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetBlockHeight -> WebT m [BlockData]
scottyBlockHeight (GetBlockHeight h noTx) =
    withMetrics
        blockRequests
        blockResponseTime
        (Just (blockItems, 1)) $
    scottyBlocks . (`GetBlocks` noTx) =<< getBlocksAtHeight (fromIntegral h)

scottyBlockHeights ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockHeights
    -> WebT m [BlockData]
scottyBlockHeights (GetBlockHeights (HeightsParam heights) noTx) =
    withMetrics
        blockRequests
        blockResponseTime
        (Just (blockItems, fromIntegral (length heights))) $
    do
    bhs <- concat <$> mapM getBlocksAtHeight (fromIntegral <$> heights)
    scottyBlocks (GetBlocks bhs noTx)

scottyBlockHeightRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockHeightRaw
    -> WebT m (RawResultList H.Block)
scottyBlockHeightRaw (GetBlockHeightRaw h) =
    withMetrics
        rawBlockRequests
        rawBlockResponseTime
        (Just (rawBlockItems, 1)) $
    RawResultList <$> (mapM getRawBlock =<< getBlocksAtHeight (fromIntegral h))

-- GET BlockTime / BlockTimeRaw --

scottyBlockTime :: (MonadUnliftIO m, MonadLoggerIO m)
                => GetBlockTime -> WebT m BlockData
scottyBlockTime (GetBlockTime (TimeParam t) (NoTx noTx)) =
    withMetrics
        blockRequests
        blockResponseTime
        (Just (blockItems, 1)) $
    do
    ch <- lift $ asks (storeChain . webStore . webConfig)
    m <- blockAtOrBefore ch t
    maybe (S.raise ThingNotFound) (return . pruneTx noTx) m

scottyBlockMTP :: (MonadUnliftIO m, MonadLoggerIO m)
               => GetBlockMTP -> WebT m BlockData
scottyBlockMTP (GetBlockMTP (TimeParam t) (NoTx noTx)) =
    withMetrics
        blockRequests
        blockResponseTime
        (Just (blockItems, 1)) $
    do
    ch <- lift $ asks (storeChain . webStore . webConfig)
    m <- blockAtOrAfterMTP ch t
    maybe (S.raise ThingNotFound) (return . pruneTx noTx) m

scottyBlockTimeRaw :: (MonadUnliftIO m, MonadLoggerIO m)
                   => GetBlockTimeRaw -> WebT m (RawResult H.Block)
scottyBlockTimeRaw (GetBlockTimeRaw (TimeParam t)) =
    withMetrics
        rawBlockRequests
        rawBlockResponseTime
        (Just (rawBlockItems, 1)) $
    do
    ch <- lift $ asks (storeChain . webStore . webConfig)
    m <- blockAtOrBefore ch t
    b <- maybe (S.raise ThingNotFound) return m
    refuseLargeBlock b
    RawResult <$> toRawBlock b

scottyBlockMTPRaw :: (MonadUnliftIO m, MonadLoggerIO m)
                  => GetBlockMTPRaw -> WebT m (RawResult H.Block)
scottyBlockMTPRaw (GetBlockMTPRaw (TimeParam t)) =
    withMetrics
        rawBlockRequests
        rawBlockResponseTime
        (Just (rawBlockItems, 1)) $
    do
    ch <- lift $ asks (storeChain . webStore . webConfig)
    m <- blockAtOrAfterMTP ch t
    b <- maybe (S.raise ThingNotFound) return m
    refuseLargeBlock b
    RawResult <$> toRawBlock b

-- GET Transactions --

scottyTx :: (MonadUnliftIO m, MonadLoggerIO m) => GetTx -> WebT m Transaction
scottyTx (GetTx txid) =
    withMetrics
        txRequests
        txResponseTime
        (Just (txItems, 1)) $
    maybe (S.raise ThingNotFound) return =<< getTransaction txid

scottyTxs ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetTxs -> WebT m [Transaction]
scottyTxs (GetTxs txids) =
    withMetrics
        txRequests
        txResponseTime
        (Just (txItems, fromIntegral (length txids))) $
    catMaybes <$> mapM getTransaction (nub txids)

scottyTxRaw ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetTxRaw -> WebT m (RawResult Tx)
scottyTxRaw (GetTxRaw txid) =
    withMetrics
        txRequests
        txResponseTime
        (Just (txItems, 1)) $
    do
    tx <- maybe (S.raise ThingNotFound) return =<< getTransaction txid
    return $ RawResult $ transactionData tx

scottyTxsRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetTxsRaw
    -> WebT m (RawResultList Tx)
scottyTxsRaw (GetTxsRaw txids) =
    withMetrics
        txRequests
        txResponseTime
        (Just (txItems, fromIntegral (length txids))) $
    do
    txs <- catMaybes <$> mapM getTransaction (nub txids)
    return $ RawResultList $ transactionData <$> txs

scottyTxsBlock ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetTxsBlock -> WebT m [Transaction]
scottyTxsBlock (GetTxsBlock h) =
    withMetrics
        txBlockRequests
        txBlockResponseTime
        Nothing $
    do
    b <- maybe (S.raise ThingNotFound) return =<< getBlock h
    refuseLargeBlock b
    catMaybes <$> mapM getTransaction (blockDataTxs b)

scottyTxsBlockRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetTxsBlockRaw
    -> WebT m (RawResultList Tx)
scottyTxsBlockRaw (GetTxsBlockRaw h) =
    withMetrics
        txBlockRequests
        txBlockResponseTime
        Nothing $
    RawResultList . fmap transactionData <$> scottyTxsBlock (GetTxsBlock h)

-- GET TransactionAfterHeight --

scottyTxAfter ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetTxAfter
    -> WebT m (GenericResult (Maybe Bool))
scottyTxAfter (GetTxAfter txid height) =
    withMetrics
        txAfterRequests
        txAfterResponseTime
        Nothing $
    GenericResult <$> cbAfterHeight (fromIntegral height) txid

-- | Check if any of the ancestors of this transaction is a coinbase after the
-- specified height. Returns 'Nothing' if answer cannot be computed before
-- hitting limits.
cbAfterHeight ::
       (MonadIO m, StoreReadBase m)
    => H.BlockHeight
    -> TxHash
    -> m (Maybe Bool)
cbAfterHeight height txid =
    inputs 10000 HashSet.empty HashSet.empty [txid]
  where
    inputs 0 _ _ [] = return Nothing
    inputs i is ns [] =
        let is' = HashSet.union is ns
            ns' = HashSet.empty
            ts = HashSet.toList (HashSet.difference ns is)
        in case ts of
               [] -> return (Just False)
               _  -> inputs i is' ns' ts
    inputs i is ns (t:ts) = getTransaction t >>= \case
        Nothing -> return Nothing
        Just tx | height_check tx ->
                      if cb_check tx
                      then return (Just True)
                      else let ns' = HashSet.union (ins tx) ns
                          in inputs (i - 1) is ns' ts
                | otherwise -> inputs (i - 1) is ns ts
    cb_check = any isCoinbase . transactionInputs
    ins = HashSet.fromList . map (outPointHash . inputPoint) . transactionInputs
    height_check tx =
        case transactionBlock tx of
            BlockRef h _ -> h > height
            _            -> True

-- POST Transaction --

scottyPostTx :: (MonadUnliftIO m, MonadLoggerIO m) => PostTx -> WebT m TxId
scottyPostTx (PostTx tx) =
    withMetrics
        postTxRequests
        postTxResponseTime
        Nothing $
    lift (asks webConfig) >>= \cfg -> lift (publishTx cfg tx) >>= \case
        Right () -> return $ TxId (txHash tx)
        Left e@(PubReject _) -> S.raise $ UserError $ show e
        _ -> S.raise ServerError

-- | Publish a new transaction to the network.
publishTx ::
       (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m)
    => WebConfig
    -> Tx
    -> m (Either PubExcept ())
publishTx cfg tx =
    withSubscription pub $ \s ->
        getTransaction (txHash tx) >>= \case
            Just _ -> return $ Right ()
            Nothing -> go s
  where
    pub = storePublisher (webStore cfg)
    mgr = storeManager (webStore cfg)
    net = storeNetwork (webStore cfg)
    go s =
        getPeers mgr >>= \case
            [] -> return $ Left PubNoPeers
            OnlinePeer {onlinePeerMailbox = p}:_ -> do
                MTx tx `sendMessage` p
                let v =
                        if getSegWit net
                            then InvWitnessTx
                            else InvTx
                sendMessage
                    (MGetData (GetData [InvVector v (getTxHash (txHash tx))]))
                    p
                f p s
    t = 5 * 1000 * 1000
    f p s
      | webNoMempool cfg = return $ Right ()
      | otherwise =
        liftIO (timeout t (g p s)) >>= \case
            Nothing -> return $ Left PubTimeout
            Just (Left e) -> return $ Left e
            Just (Right ()) -> return $ Right ()
    g p s =
        receive s >>= \case
            StoreTxReject p' h' c _
                | p == p' && h' == txHash tx -> return . Left $ PubReject c
            StorePeerDisconnected p'
                | p == p' -> return $ Left PubPeerDisconnected
            StoreMempoolNew h'
                | h' == txHash tx -> return $ Right ()
            _ -> g p s

-- GET Mempool / Events --

scottyMempool ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetMempool -> WebT m [TxHash]
scottyMempool (GetMempool limitM (OffsetParam o)) =
    withMetrics
        mempoolRequests
        mempoolResponseTime
        Nothing $
    do
    wl <- lift $ asks (webMaxLimits . webConfig)
    let wl' = wl { maxLimitCount = 0 }
        l = Limits (validateLimit wl' False limitM) (fromIntegral o) Nothing
    map snd . applyLimits l <$> getMempool

scottyEvents :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyEvents =
    withGaugeIncrease eventsConnected $ do
    setHeaders
    proto <- setupContentType False
    pub <- lift $ asks (storePublisher . webStore . webConfig)
    S.stream $ \io flush' ->
        withSubscription pub $ \sub ->
            forever $
            flush' >> receiveEvent sub >>= maybe (return ()) (io . serial proto)
  where
    serial proto e =
        lazyByteString $ protoSerial proto toEncoding toJSON e <> newLine proto
    newLine SerialAsBinary     = mempty
    newLine SerialAsJSON       = "\n"
    newLine SerialAsPrettyJSON = mempty

receiveEvent :: Inbox StoreEvent -> IO (Maybe Event)
receiveEvent sub = do
    se <- receive sub
    return $
        case se of
            StoreBestBlock b  -> Just (EventBlock b)
            StoreMempoolNew t -> Just (EventTx t)
            _                 -> Nothing

-- GET Address Transactions --

scottyAddrTxs ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrTxs -> WebT m [TxRef]
scottyAddrTxs (GetAddrTxs addr pLimits) =
    withMetrics
        addrTxRequests
        addrTxResponseTime
        (Just (addrTxItems, 1)) $
    getAddressTxs addr =<< paramToLimits False pLimits

scottyAddrsTxs ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrsTxs -> WebT m [TxRef]
scottyAddrsTxs (GetAddrsTxs addrs pLimits) =
    withMetrics
        addrTxRequests
        addrTxResponseTime
        (Just (addrTxItems, fromIntegral (length addrs))) $
    getAddressesTxs addrs =<< paramToLimits False pLimits

scottyAddrTxsFull ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetAddrTxsFull
    -> WebT m [Transaction]
scottyAddrTxsFull (GetAddrTxsFull addr pLimits) =
    withMetrics
        addrTxRequests
        addrTxResponseTime
        (Just (addrTxItems, 1)) $
    do
    txs <- getAddressTxs addr =<< paramToLimits True pLimits
    catMaybes <$> mapM (getTransaction . txRefHash) txs

scottyAddrsTxsFull :: (MonadUnliftIO m, MonadLoggerIO m)
                   => GetAddrsTxsFull -> WebT m [Transaction]
scottyAddrsTxsFull (GetAddrsTxsFull addrs pLimits) =
    withMetrics
        addrTxRequests
        addrTxResponseTime
        (Just (addrTxItems, fromIntegral (length addrs))) $
    do
    txs <- getAddressesTxs addrs =<< paramToLimits True pLimits
    catMaybes <$> mapM (getTransaction . txRefHash) txs

scottyAddrBalance :: (MonadUnliftIO m, MonadLoggerIO m)
                  => GetAddrBalance -> WebT m Balance
scottyAddrBalance (GetAddrBalance addr) =
    withMetrics
        addrBalanceRequests
        addrBalanceResponseTime
        (Just (addrBalanceItems, 1)) $
    getDefaultBalance addr

scottyAddrsBalance ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrsBalance -> WebT m [Balance]
scottyAddrsBalance (GetAddrsBalance addrs) =
    withMetrics
        addrBalanceRequests
        addrBalanceResponseTime
        (Just (addrBalanceItems, fromIntegral (length addrs))) $
    getBalances addrs

scottyAddrUnspent ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrUnspent -> WebT m [Unspent]
scottyAddrUnspent (GetAddrUnspent addr pLimits) =
    withMetrics
        addrUnspentRequests
        addrUnspentResponseTime
        (Just (addrUnspentItems, 1)) $
    getAddressUnspents addr =<< paramToLimits False pLimits

scottyAddrsUnspent ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrsUnspent -> WebT m [Unspent]
scottyAddrsUnspent (GetAddrsUnspent addrs pLimits) =
    withMetrics
        addrUnspentRequests
        addrUnspentResponseTime
        (Just (addrUnspentItems, fromIntegral (length addrs))) $
    getAddressesUnspents addrs =<< paramToLimits False pLimits

-- GET XPubs --

scottyXPub ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetXPub -> WebT m XPubSummary
scottyXPub (GetXPub xpub deriv (NoCache noCache)) =
    withMetrics
        xPubRequests
        xPubResponseTime
        Nothing $
    lift . runNoCache noCache $ xPubSummary $ XPubSpec xpub deriv

scottyXPubTxs ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetXPubTxs -> WebT m [TxRef]
scottyXPubTxs (GetXPubTxs xpub deriv pLimits (NoCache noCache)) =
    withMetrics
        xPubTxRequests
        xPubTxResponseTime
        Nothing $
    do
    limits <- paramToLimits False pLimits
    lift . runNoCache noCache $ xPubTxs (XPubSpec xpub deriv) limits

scottyXPubTxsFull ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetXPubTxsFull
    -> WebT m [Transaction]
scottyXPubTxsFull (GetXPubTxsFull xpub deriv pLimits n@(NoCache noCache)) =
    withMetrics
        xPubTxFullRequests
        xPubTxFullResponseTime
        Nothing $
    do
    refs <- scottyXPubTxs (GetXPubTxs xpub deriv pLimits n)
    txs <- lift . runNoCache noCache $ mapM (getTransaction . txRefHash) refs
    return $ catMaybes txs

scottyXPubBalances ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetXPubBalances -> WebT m [XPubBal]
scottyXPubBalances (GetXPubBalances xpub deriv (NoCache noCache)) =
    withMetrics
        xPubRequests
        xPubResponseTime
        Nothing $
    filter f <$> lift (runNoCache noCache (xPubBals spec))
  where
    spec = XPubSpec xpub deriv
    f = not . nullBalance . xPubBal

scottyXPubUnspent ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetXPubUnspent
    -> WebT m [XPubUnspent]
scottyXPubUnspent (GetXPubUnspent xpub deriv pLimits (NoCache noCache)) =
    withMetrics
        xPubUnspentRequests
        xPubUnspentResponseTime
        Nothing $
    do
    limits <- paramToLimits False pLimits
    lift . runNoCache noCache $ xPubUnspents (XPubSpec xpub deriv) limits

scottyXPubEvict ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetXPubEvict
    -> WebT m (GenericResult Bool)
scottyXPubEvict (GetXPubEvict xpub deriv) =
    withMetrics
        xPubEvictRequests
        xPubEvictResponseTime
        Nothing $ do
    cache <- lift $ asks (storeCache . webStore . webConfig)
    lift . withCache cache $ evictFromCache [XPubSpec xpub deriv]
    return $ GenericResult True

---------------------------------------
-- Blockchain.info API Compatibility --
---------------------------------------

netBinfoSymbol :: Network -> BinfoSymbol
netBinfoSymbol net
  | net == btc =
        BinfoSymbol{ getBinfoSymbolCode = "BTC"
                   , getBinfoSymbolString = "BTC"
                   , getBinfoSymbolName = "Bitcoin"
                   , getBinfoSymbolConversion = 100 * 1000 * 1000
                   , getBinfoSymbolAfter = True
                   , getBinfoSymbolLocal = False
                   }
  | net == bch =
        BinfoSymbol{ getBinfoSymbolCode = "BCH"
                   , getBinfoSymbolString = "BCH"
                   , getBinfoSymbolName = "Bitcoin Cash"
                   , getBinfoSymbolConversion = 100 * 1000 * 1000
                   , getBinfoSymbolAfter = True
                   , getBinfoSymbolLocal = False
                   }
  | otherwise =
        BinfoSymbol{ getBinfoSymbolCode = "XTS"
                   , getBinfoSymbolString = "¤"
                   , getBinfoSymbolName = "Test"
                   , getBinfoSymbolConversion = 100 * 1000 * 1000
                   , getBinfoSymbolAfter = False
                   , getBinfoSymbolLocal = False
                   }

binfoTickerToSymbol :: Text -> BinfoTicker -> BinfoSymbol
binfoTickerToSymbol code BinfoTicker{..} =
    BinfoSymbol{ getBinfoSymbolCode = code
               , getBinfoSymbolString = binfoTickerSymbol
               , getBinfoSymbolName = name
               , getBinfoSymbolConversion =
                       100 * 1000 * 1000 / binfoTicker15m -- sat/usd
               , getBinfoSymbolAfter = False
               , getBinfoSymbolLocal = True
               }
  where
    name = case code of
        "EUR" -> "Euro"
        "USD" -> "U.S. dollar"
        "GBP" -> "British pound"
        x     -> x

scottyMultiAddr :: (MonadUnliftIO m, MonadLoggerIO m)
                => WebT m ()
scottyMultiAddr =
    get_addrs >>= \(addrs, xpubs, saddrs, sxpubs, xspecs) ->
    let len = fromIntegral (HashSet.size addrs + HashSet.size xpubs)
    in withMetrics
       multiaddrRequests
       multiaddrResponseTime
       (Just (multiaddrItems, len)) $
    do
    prune <- get_prune
    n <- get_count
    offset <- get_offset
    cashaddr <- get_cashaddr
    numtxid <- lift $ asks (webNumTxId . webConfig)
    xbals <- get_xbals xspecs
    let sxbals = compute_sxbals sxpubs xbals
    sxtrs <- get_sxtrs sxpubs xspecs
    sabals <- get_abals saddrs
    satrs <- get_atrs n offset saddrs
    ticker <- lift $ asks webTicker
    local <- get_price ticker
    let sxtns = HashMap.map length sxtrs
        sxtrset = Set.fromList . concat $ HashMap.elems sxtrs
        sxabals = compute_xabals sxbals
        sallbals = sabals <> sxabals
        abook = compute_abook addrs xbals
        sxaddrs = compute_xaddrs sxbals
        salladdrs = sxaddrs <> saddrs
        bal = compute_bal sallbals
        salltrs = sxtrset <> satrs
        stxids = compute_txids n offset salltrs
    stxs <- get_txs stxids
    let etxids = if numtxid
                then compute_etxids prune abook stxs
                else []
    etxs <- if numtxid
            then Just <$> get_etxs etxids
            else return Nothing
    best <- scottyBlockBest (GetBlockBest (NoTx True))
    peers <- get_peers
    net <- lift $ asks (storeNetwork . webStore . webConfig)
    let ibal = fromIntegral bal
        btxs = binfo_txs etxs abook salladdrs prune ibal stxs
        ftxs = take n $ drop offset btxs
        addrs = toBinfoAddrs sabals sxbals sxtns
        recv = sum $ map getBinfoAddrReceived addrs
        sent = sum $ map getBinfoAddrSent addrs
        txn = sum $ map getBinfoAddrTxCount addrs
        wallet =
            BinfoWallet
            { getBinfoWalletBalance = bal
            , getBinfoWalletTxCount = txn
            , getBinfoWalletFilteredCount = fromIntegral (length ftxs)
            , getBinfoWalletTotalReceived = recv
            , getBinfoWalletTotalSent = sent
            }
        coin = netBinfoSymbol net
        block =
            BinfoBlockInfo
            { getBinfoBlockInfoHash = H.headerHash (blockDataHeader best)
            , getBinfoBlockInfoHeight = blockDataHeight best
            , getBinfoBlockInfoTime = H.blockTimestamp (blockDataHeader best)
            , getBinfoBlockInfoIndex = blockDataHeight best
            }
        info =
            BinfoInfo
            { getBinfoConnected = peers
            , getBinfoConversion = 100 * 1000 * 1000
            , getBinfoLocal = local
            , getBinfoBTC = coin
            , getBinfoLatestBlock = block
            }
    setHeaders
    S.json $ binfoMultiAddrToJSON net
        BinfoMultiAddr
        { getBinfoMultiAddrAddresses = addrs
        , getBinfoMultiAddrWallet = wallet
        , getBinfoMultiAddrTxs = ftxs
        , getBinfoMultiAddrInfo = info
        , getBinfoMultiAddrRecommendFee = True
        , getBinfoMultiAddrCashAddr = cashaddr
        }
  where
    get_price ticker = do
        code <- T.toUpper <$> S.param "local" `S.rescue` const (return "USD")
        prices <- readTVarIO ticker
        case HashMap.lookup code prices of
            Nothing -> return def
            Just p  -> return $ binfoTickerToSymbol code p
    get_prune = fmap not $ S.param "no_compact"
        `S.rescue` const (return False)
    get_cashaddr = S.param "cashaddr"
        `S.rescue` const (return False)
    get_count = do
        d <- lift (asks (maxLimitDefault . webMaxLimits . webConfig))
        x <- lift (asks (maxLimitFull . webMaxLimits . webConfig))
        i <- min x <$> (S.param "n" `S.rescue` const (return d))
        return (fromIntegral i :: Int)
    get_offset = do
        x <- lift (asks (maxLimitOffset . webMaxLimits . webConfig))
        o <- min x <$> (S.param "offset" `S.rescue` const (return 0))
        return (fromIntegral o :: Int)
    get_addrs_param name = do
        net <- lift (asks (storeNetwork . webStore . webConfig))
        p <- S.param name `S.rescue` const (return "")
        case parseBinfoAddr net p of
            Nothing -> S.raise (UserError "invalid active address")
            Just xs -> return $ HashSet.fromList xs
    addr (BinfoAddr a) = Just a
    addr (BinfoXpub x) = Nothing
    xpub (BinfoXpub x) = Just x
    xpub (BinfoAddr _) = Nothing
    binfo_txs _ _ _ _ _ [] = []
    binfo_txs etxs abook salladdrs prune ibal (t:ts) =
        let b = toBinfoTx etxs abook salladdrs prune ibal t
            nbal = case getBinfoTxResultBal b of
                Nothing     -> ibal
                Just (_, x) -> ibal - x
         in b : binfo_txs etxs abook salladdrs prune nbal ts
    get_addrs = do
        active <- get_addrs_param "active"
        p2sh <- get_addrs_param "activeP2SH"
        bech32 <- get_addrs_param "activeBech32"
        sh <- get_addrs_param "onlyShow"
        let xspec d b = (\x -> (x, XPubSpec x d)) <$> xpub b
            xspecs = HashMap.fromList $ concat
                     [ mapMaybe (xspec DeriveNormal) (HashSet.toList active)
                     , mapMaybe (xspec DeriveP2SH) (HashSet.toList p2sh)
                     , mapMaybe (xspec DeriveP2WPKH) (HashSet.toList bech32)
                     ]
            actives = active <> p2sh <> bech32
            addrs = HashSet.fromList . mapMaybe addr $ HashSet.toList actives
            xpubs = HashSet.fromList . mapMaybe xpub $ HashSet.toList actives
            sh' = if HashSet.null sh
                  then actives
                  else sh `HashSet.intersection` actives
            saddrs = HashSet.fromList . mapMaybe addr $ HashSet.toList sh'
            sxpubs = HashSet.fromList . mapMaybe xpub $ HashSet.toList sh'
        return (addrs, xpubs, saddrs, sxpubs, xspecs)
    get_xbals =
        let f = not . nullBalance . xPubBal
            g = HashMap.fromList . map (second (filter f))
            h (k, s) = (,) k <$> xPubBals s
        in fmap g . mapM h . HashMap.toList
    get_abals =
        let f b = (balanceAddress b, b)
            g = HashMap.fromList . map f
        in fmap g . getBalances . HashSet.toList
    get_sxtrs sxpubs =
        let f (k, s) = (,) k <$> xPubTxs s def
            g = ((`HashSet.member` sxpubs) . fst)
        in fmap HashMap.fromList . mapM f . filter g . HashMap.toList
    get_atrs n offset =
        let i = fromIntegral (n + offset)
            f x = getAddressesTxs x def{limit = i}
        in fmap Set.fromList . f . HashSet.toList
    get_txs = fmap catMaybes . mapM getTransaction
    get_etxs =
        let f t = (txHash (transactionData t), t)
            g = HashMap.fromList . map f . catMaybes
        in fmap g . mapM getTransaction
    get_peers = do
        ps <- lift $ getPeersInformation =<<
            asks (storeManager . webStore . webConfig)
        return (fromIntegral (length ps))
    compute_txids n offset = map txRefHash . take (n + offset) . Set.toDescList
    compute_etxids prune abook =
        let f = relevantTxs (HashMap.keysSet abook) prune
        in HashSet.toList . foldl HashSet.union HashSet.empty . map f
    compute_sxbals sxpubs =
        let f k _ = k `HashSet.member` sxpubs
        in HashMap.filterWithKey f
    compute_xabals =
        let f b = (balanceAddress (xPubBal b), xPubBal b)
        in HashMap.fromList . concatMap (map f) . HashMap.elems
    compute_bal =
        let f b = balanceAmount b + balanceZero b
        in sum . map f . HashMap.elems
    compute_abook addrs xbals =
        let f k XPubBal{..} =
                let a = balanceAddress xPubBal
                    e = error "lions and tigers and bears"
                    s = toSoft (listToPath xPubBalPath)
                    m = fromMaybe e s
                in (a, Just (BinfoXPubPath k m))
            g k = map (f k)
            amap = HashMap.map (const Nothing) $
                   HashSet.toMap addrs
            xmap = HashMap.fromList .
                   concatMap (uncurry g) $
                   HashMap.toList xbals
        in amap <> xmap
    compute_xaddrs =
        let f = map (balanceAddress . xPubBal)
        in HashSet.fromList . concatMap f . HashMap.elems
    sent BinfoTx{getBinfoTxResultBal = Just (r, _)}
      | r < 0 = fromIntegral (negate r)
      | otherwise = 0
    sent _ = 0
    received BinfoTx{getBinfoTxResultBal = Just (r, _)}
      | r > 0 = fromIntegral r
      | otherwise = 0
    received _ = 0

scottyBinfoTx :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoTx =
    withMetrics
        rawtxRequests
        rawtxResponseTime
        Nothing $
    lift (asks (webNumTxId . webConfig)) >>= \num -> S.param "txid" >>= \case
        BinfoTxIdHash h -> go num h
        BinfoTxIdIndex i ->
            if | not num || isBinfoTxIndexNull i -> S.raise ThingNotFound
               | isBinfoTxIndexBlock i -> block i
               | isBinfoTxIndexHash i -> hash i
  where
    get_format = S.param "format" `S.rescue` const (return ("json" :: Text))
    js num t = do
        let etxids = if num
                     then HashSet.toList $ relevantTxs HashSet.empty False t
                     else []
        etxs' <- if num
                 then Just . catMaybes <$> mapM getTransaction etxids
                 else return Nothing
        let f t = (txHash (transactionData t), t)
            etxs = HashMap.fromList . map f <$> etxs'
        net <- lift $ asks (storeNetwork . webStore . webConfig)
        setHeaders
        S.json . binfoTxToJSON net $ toBinfoTxSimple etxs t
    hex t = do
        setHeaders
        S.text . TL.fromStrict . encodeHex . encode $ transactionData t
    go num h = getTransaction h >>= \case
        Nothing -> S.raise ThingNotFound
        Just t -> get_format >>= \case
            "hex" -> hex t
            _ -> js num t
    block i =
        let Just (height, pos) = binfoTxIndexBlock i
        in getBlocksAtHeight height >>= \case
            [] -> S.raise ThingNotFound
            h:_ -> getBlock h >>= \case
                Nothing -> S.raise ThingNotFound
                Just BlockData{..} ->
                    if length blockDataTxs > fromIntegral pos
                    then go True (blockDataTxs !! fromIntegral pos)
                    else S.raise ThingNotFound
    hmatch h = listToMaybe . filter (matchBinfoTxHash h)
    hmem h = hmatch h . map snd <$> getMempool
    hblock h =
        let g 0 _ = return Nothing
            g i k =
                getBlock k >>= \case
                Nothing -> return Nothing
                Just BlockData{..} ->
                    case hmatch h blockDataTxs of
                        Nothing -> g (i - 1) (H.prevBlock blockDataHeader)
                        Just x  -> return (Just x)
        in getBestBlock >>= \case
            Nothing -> return Nothing
            Just k -> g 10 k
    hash h = hmem h >>= \case
        Nothing -> hblock h >>= \case
            Nothing -> S.raise ThingNotFound
            Just x -> go True x
        Just x -> go True x

-- GET Network Information --

scottyPeers :: (MonadUnliftIO m, MonadLoggerIO m)
            => GetPeers
            -> WebT m [PeerInformation]
scottyPeers _ =
    withMetrics
        peerRequests
        peerResponseTime
        Nothing $
    lift $
    getPeersInformation =<< asks (storeManager . webStore . webConfig)

-- | Obtain information about connected peers from peer manager process.
getPeersInformation
    :: MonadLoggerIO m => PeerManager -> m [PeerInformation]
getPeersInformation mgr =
    mapMaybe toInfo <$> getPeers mgr
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
                , peerAddress = show as
                , peerVersion = vs
                , peerServices = sv
                , peerRelay = rl
                }

scottyHealth ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetHealth -> WebT m HealthCheck
scottyHealth _ =
    withMetrics
        healthRequests
        healthResponseTime
        Nothing $
    do
    h <- lift $ asks webConfig >>= healthCheck
    unless (isOK h) $ S.status status503
    return h

blockHealthCheck :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m)
                 => WebConfig -> m BlockHealth
blockHealthCheck cfg = do
    let ch = storeChain $ webStore cfg
        blockHealthMaxDiff = webMaxDiff cfg
    blockHealthHeaders <-
        H.nodeHeight <$> chainGetBest ch
    blockHealthBlocks <-
        maybe 0 blockDataHeight <$>
        runMaybeT (MaybeT getBestBlock >>= MaybeT . getBlock)
    return BlockHealth {..}

lastBlockHealthCheck :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m)
                     => Chain -> WebTimeouts -> m TimeHealth
lastBlockHealthCheck ch tos = do
    n <- fromIntegral . systemSeconds <$> liftIO getSystemTime
    t <- fromIntegral . H.blockTimestamp . H.nodeHeader <$> chainGetBest ch
    let timeHealthAge = n - t
        timeHealthMax = fromIntegral $ blockTimeout tos
    return TimeHealth {..}

lastTxHealthCheck :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m)
                  => WebConfig -> m TimeHealth
lastTxHealthCheck WebConfig {..} = do
    n <- fromIntegral . systemSeconds <$> liftIO getSystemTime
    b <- fromIntegral . H.blockTimestamp . H.nodeHeader <$> chainGetBest ch
    t <- listToMaybe <$> getMempool >>= \case
        Just t -> let x = fromIntegral $ fst t
                  in return $ max x b
        Nothing -> return b
    let timeHealthAge = n - t
        timeHealthMax = fromIntegral to
    return TimeHealth {..}
  where
    ch = storeChain webStore
    to = if webNoMempool then blockTimeout webTimeouts else txTimeout webTimeouts

pendingTxsHealthCheck :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m)
                      => WebConfig -> m MaxHealth
pendingTxsHealthCheck cfg = do
    let maxHealthMax = webMaxPending cfg
    maxHealthNum <- blockStorePendingTxs (storeBlock (webStore cfg))
    return MaxHealth {..}

peerHealthCheck :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m)
                => PeerManager -> m CountHealth
peerHealthCheck mgr = do
    let countHealthMin = 1
    countHealthNum <- length <$> getPeers mgr
    return CountHealth {..}

healthCheck :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m)
            => WebConfig -> m HealthCheck
healthCheck cfg@WebConfig {..} = do
    healthBlocks     <- blockHealthCheck cfg
    healthLastBlock  <- lastBlockHealthCheck (storeChain webStore) webTimeouts
    healthLastTx     <- lastTxHealthCheck cfg
    healthPendingTxs <- pendingTxsHealthCheck cfg
    healthPeers      <- peerHealthCheck (storeManager webStore)
    let healthNetwork = getNetworkName (storeNetwork webStore)
        healthVersion = webVersion
        hc = HealthCheck {..}
    unless (isOK hc) $ do
        let t = toStrict $ encodeToLazyText hc
        $(logErrorS) "Web" $ "Health check failed: " <> t
    return hc

scottyDbStats :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyDbStats =
    withMetrics
        dbStatsRequests
        dbStatsResponseTime
        Nothing $
    do
    setHeaders
    db <- lift $ asks (databaseHandle . storeDB . webStore . webConfig)
    statsM <- lift (getProperty db Stats)
    S.text $ maybe "Could not get stats" cs statsM

-----------------------
-- Parameter Parsing --
-----------------------

-- | Returns @Nothing@ if the parameter is not supplied. Raises an exception on
-- parse failure.
paramOptional :: (Param a, Monad m) => WebT m (Maybe a)
paramOptional = go Proxy
  where
    go :: (Param a, Monad m) => Proxy a -> WebT m (Maybe a)
    go proxy = do
        net <- lift $ asks (storeNetwork . webStore . webConfig)
        tsM :: Maybe [Text] <- p `S.rescue` const (return Nothing)
        case tsM of
            Nothing -> return Nothing -- Parameter was not supplied
            Just ts -> maybe (S.raise err) (return . Just) $ parseParam net ts
      where
        l = proxyLabel proxy
        p = Just <$> S.param (cs l)
        err = UserError $ "Unable to parse param " <> cs l

-- | Raises an exception if the parameter is not supplied
param :: (Param a, Monad m) => WebT m a
param = go Proxy
  where
    go :: (Param a, Monad m) => Proxy a -> WebT m a
    go proxy = do
        resM <- paramOptional
        case resM of
            Just res -> return res
            _ ->
                S.raise . UserError $
                "The param " <> cs (proxyLabel proxy) <> " was not defined"

-- | Returns the default value of a parameter if it is not supplied. Raises an
-- exception on parse failure.
paramDef :: (Default a, Param a, Monad m) => WebT m a
paramDef = fromMaybe def <$> paramOptional

-- | Does not raise exceptions. Will call @Scotty.next@ if the parameter is
-- not supplied or if parsing fails.
paramLazy :: (Param a, Monad m) => WebT m a
paramLazy = do
    resM <- paramOptional `S.rescue` const (return Nothing)
    maybe S.next return resM

parseBody :: (MonadIO m, Serialize a) => WebT m a
parseBody = do
    b <- S.body
    case hex b <|> bin (L.toStrict b) of
        Nothing -> S.raise $ UserError "Failed to parse request body"
        Just x  -> return x
  where
    bin = eitherToMaybe . Serialize.decode
    hex = bin <=< decodeHex . cs . C.filter (not . isSpace)

parseOffset :: Monad m => WebT m OffsetParam
parseOffset = do
    res@(OffsetParam o) <- paramDef
    limits <- lift $ asks (webMaxLimits . webConfig)
    when (maxLimitOffset limits > 0 && fromIntegral o > maxLimitOffset limits) $
        S.raise . UserError $
        "offset exceeded: " <> show o <> " > " <> show (maxLimitOffset limits)
    return res

parseStart ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Maybe StartParam
    -> WebT m (Maybe Start)
parseStart Nothing = return Nothing
parseStart (Just s) =
    runMaybeT $
    case s of
        StartParamHash {startParamHash = h}     -> start_tx h <|> start_block h
        StartParamHeight {startParamHeight = h} -> start_height h
        StartParamTime {startParamTime = q}     -> start_time q
  where
    start_height h = return $ AtBlock $ fromIntegral h
    start_block h = do
        b <- MaybeT $ getBlock (H.BlockHash h)
        return $ AtBlock (blockDataHeight b)
    start_tx h = do
        _ <- MaybeT $ getTxData (TxHash h)
        return $ AtTx (TxHash h)
    start_time q = do
        ch <- lift $ asks (storeChain . webStore . webConfig)
        b <- MaybeT $ blockAtOrBefore ch q
        let g = blockDataHeight b
        return $ AtBlock g

parseLimits :: Monad m => WebT m LimitsParam
parseLimits = LimitsParam <$> paramOptional <*> parseOffset <*> paramOptional

paramToLimits ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Bool
    -> LimitsParam
    -> WebT m Limits
paramToLimits full (LimitsParam limitM o startM) = do
    wl <- lift $ asks (webMaxLimits . webConfig)
    Limits (validateLimit wl full limitM) (fromIntegral o) <$> parseStart startM

validateLimit :: WebLimits -> Bool -> Maybe LimitParam -> Word32
validateLimit wl full limitM =
    f m $ maybe d (fromIntegral . getLimitParam) limitM
  where
    m | full && maxLimitFull wl > 0 = maxLimitFull wl
      | otherwise = maxLimitCount wl
    d = maxLimitDefault wl
    f a 0 = a
    f 0 b = b
    f a b = min a b

---------------
-- Utilities --
---------------

runInWebReader ::
       MonadIO m
    => CacheT (DatabaseReaderT m) a
    -> ReaderT WebState m a
runInWebReader f = do
    bdb <- asks (storeDB . webStore . webConfig)
    mc <- asks (storeCache . webStore . webConfig)
    lift $ runReaderT (withCache mc f) bdb

runNoCache :: MonadIO m => Bool -> ReaderT WebState m a -> ReaderT WebState m a
runNoCache False f = f
runNoCache True f = local g f
  where
    g s = s { webConfig = h (webConfig s) }
    h c = c { webStore = i (webStore c) }
    i s = s { storeCache = Nothing }

logIt :: (MonadUnliftIO m, MonadLoggerIO m) => m Middleware
logIt = do
    runner <- askRunInIO
    return $ \app req respond -> do
        t1 <- getCurrentTime
        app req $ \res -> do
            t2 <- getCurrentTime
            let d = diffUTCTime t2 t1
                s = responseStatus res
                msg = fmtReq req <> " [" <> fmtStatus s <> " / " <> fmtDiff d <> "]"
            if statusIsSuccessful s
                then runner $ $(logDebugS) "Web" msg
                else runner $ $(logErrorS) "Web" msg
            respond res

fmtReq :: Request -> Text
fmtReq req =
    let m = requestMethod req
        v = httpVersion req
        p = rawPathInfo req
        q = rawQueryString req
     in T.decodeUtf8 $ m <> " " <> p <> q <> " " <> cs (show v)

fmtDiff :: NominalDiffTime -> Text
fmtDiff d =
    cs (printf "%0.3f" (realToFrac (d * 1000) :: Double) :: String) <> " ms"

fmtStatus :: Status -> Text
fmtStatus s = cs (show (statusCode s)) <> " " <> cs (statusMessage s)

