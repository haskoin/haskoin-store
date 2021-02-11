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
import           Data.ByteString.Short         (fromShort)
import           Data.Char                     (isSpace)
import           Data.Default                  (Default (..))
import           Data.Function                 (on, (&))
import           Data.HashMap.Strict           (HashMap)
import qualified Data.HashMap.Strict           as HashMap
import           Data.HashSet                  (HashSet)
import qualified Data.HashSet                  as HashSet
import           Data.Int                      (Int64)
import           Data.List                     (nub, sortBy)
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
import           Data.Time.Clock               (NominalDiffTime, diffUTCTime)
import           Data.Time.Clock.System        (getSystemTime, systemSeconds,
                                                systemToUTCTime)
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
import           Haskoin.Store.Stats
import           Haskoin.Store.WebCommon
import           Haskoin.Transaction
import           Haskoin.Util
import           NQE                           (Inbox, receive,
                                                withSubscription)
import           Network.HTTP.Types            (Status (..), status400,
                                                status403, status404, status500,
                                                status503, statusIsClientError,
                                                statusIsServerError,
                                                statusIsSuccessful)
import           Network.Wai                   (Middleware, Request (..),
                                                responseStatus)
import           Network.Wai.Handler.Warp      (defaultSettings, setHost,
                                                setPort)
import qualified Network.Wreq                  as Wreq
import qualified System.Metrics                as Metrics
import qualified System.Metrics.Counter        as Metrics (Counter)
import qualified System.Metrics.Counter        as Metrics.Counter
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

data ErrorCounter = ErrorCounter
    { clientErrors :: Metrics.Counter
    , serverErrors :: Metrics.Counter
    }

createErrorCounter :: MonadIO m
                   => Text
                   -> Metrics.Store
                   -> m ErrorCounter
createErrorCounter t s = liftIO $ do
    clientErrors <- Metrics.createCounter (t <> ".client_errors") s
    serverErrors <- Metrics.createCounter (t <> ".server_errors") s
    return ErrorCounter{..}

data WebMetrics = WebMetrics
    { everyResponseTime       :: !StatDist
    , everyError              :: !ErrorCounter
    , blockResponseTime       :: !StatDist
    , rawBlockResponseTime    :: !StatDist
    , blockErrors             :: !ErrorCounter
    , txResponseTime          :: !StatDist
    , txsBlockResponseTime    :: !StatDist
    , txErrors                :: !ErrorCounter
    , txAfterResponseTime     :: !StatDist
    , postTxResponseTime      :: !StatDist
    , postTxErrors            :: !ErrorCounter
    , mempoolResponseTime     :: !StatDist
    , addrTxResponseTime      :: !StatDist
    , addrTxFullResponseTime  :: !StatDist
    , addrBalanceResponseTime :: !StatDist
    , addrUnspentResponseTime :: !StatDist
    , xPubResponseTime        :: !StatDist
    , xPubTxResponseTime      :: !StatDist
    , xPubTxFullResponseTime  :: !StatDist
    , xPubUnspentResponseTime :: !StatDist
    , multiaddrResponseTime   :: !StatDist
    , multiaddrErrors         :: !ErrorCounter
    , unspentResponseTime     :: !StatDist
    , unspentErrors           :: !ErrorCounter
    , rawtxResponseTime       :: !StatDist
    , rawtxErrors             :: !ErrorCounter
    , peerResponseTime        :: !StatDist
    , healthResponseTime      :: !StatDist
    , dbStatsResponseTime     :: !StatDist
    , eventsConnected         :: !Metrics.Gauge
    }

createMetrics :: MonadIO m => Metrics.Store -> m WebMetrics
createMetrics s = liftIO $ do
    everyResponseTime         <- d "all.response_time_ms"
    everyError                <- e "all.errors"
    blockResponseTime         <- d "block.response_time_ms"
    blockErrors               <- e "block.errors"
    rawBlockResponseTime      <- d "block_raw.response_time_ms"
    txResponseTime            <- d "tx.response_time"
    txsBlockResponseTime      <- d "txs_block.response_time"
    txErrors                  <- e "tx.errors"
    txAfterResponseTime       <- d "tx_after.response_time_ms"
    postTxResponseTime        <- d "tx_post.response_time_ms"
    postTxErrors              <- e "tx_post.errors"
    mempoolResponseTime       <- d "mempool.response_time_ms"
    addrBalanceResponseTime   <- d "addr_balance.response_time_ms"
    addrTxResponseTime        <- d "addr_tx.response_time_ms"
    addrTxFullResponseTime    <- d "addr_tx_full.response_time_ms"
    addrUnspentResponseTime   <- d "addr_unspent.response_time_ms"
    xPubResponseTime          <- d "xpub_balance.response_time_ms"
    xPubTxResponseTime        <- d "xpub_tx.response_time_ms"
    xPubTxFullResponseTime    <- d "xpub_tx_full.response_time_ms"
    xPubUnspentResponseTime   <- d "xpub_unspent.response_time_ms"
    multiaddrResponseTime     <- d "multiaddr.response_time_ms"
    multiaddrErrors           <- e "multiaddr.errors"
    rawtxResponseTime         <- d "rawtx.response_time_ms"
    rawtxErrors               <- e "rawtx.errors"
    peerResponseTime          <- d "peer.response_time_ms"
    healthResponseTime        <- d "health.response_time_ms"
    dbStatsResponseTime       <- d "dbstats.response_time_ms"
    eventsConnected           <- g "events.connected"
    unspentResponseTime       <- d "unspent.response_time_ms"
    unspentErrors             <- e "unspent.errors"
    return WebMetrics{..}
  where
    d x = createStatDist       ("web." <> x) s
    g x = Metrics.createGauge  ("web." <> x) s
    e x = createErrorCounter   ("web." <> x) s

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
            => (WebMetrics -> StatDist)
            -> Int
            -> WebT m a
            -> WebT m a
withMetrics df i go =
    lift (asks webMetrics) >>= \case
        Nothing -> go
        Just m -> do
            x <-
                liftWith $ \run ->
                bracket
                (systemToUTCTime <$> liftIO getSystemTime)
                (end m)
                (const (run go))
            restoreT $ return x
  where
    end metrics t1 = do
        t2 <- systemToUTCTime <$> liftIO getSystemTime
        let diff = round $ diffUTCTime t2 t1 * 1000
        df metrics `addStatEntry` StatEntry diff (fromIntegral i)
        everyResponseTime metrics `addStatEntry` StatEntry diff (fromIntegral i)

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

raise_ :: MonadIO m => Except -> WebT m a
raise_ err =
    lift (asks webMetrics) >>= \case
    Nothing -> S.raise err
    Just metrics -> do
        let status = errStatus err
        if | statusIsClientError status -> liftIO $
                 Metrics.Counter.inc (clientErrors (everyError metrics))
           | statusIsServerError status -> liftIO $
                 Metrics.Counter.inc (serverErrors (everyError metrics))
           | otherwise ->
                 return ()
        S.raise err

raise :: MonadIO m => (WebMetrics -> ErrorCounter) -> Except -> WebT m a
raise metric err =
    lift (asks webMetrics) >>= \case
    Nothing -> S.raise err
    Just metrics -> do
        let status = errStatus err
        if | statusIsClientError status -> liftIO $ do
                 Metrics.Counter.inc (clientErrors (everyError metrics))
                 Metrics.Counter.inc (clientErrors (metric metrics))
           | statusIsServerError status -> liftIO $ do
                 Metrics.Counter.inc (serverErrors (everyError metrics))
                 Metrics.Counter.inc (serverErrors (metric metrics))
           | otherwise ->
                 return ()
        S.raise err

errStatus :: Except -> Status
errStatus ThingNotFound = status404
errStatus BadRequest    = status400
errStatus UserError{}   = status400
errStatus StringError{} = status400
errStatus ServerError   = status500
errStatus BlockTooLarge = status403

defHandler :: Monad m => Except -> WebT m ()
defHandler e = do
    proto <- setupContentType False
    S.status $ errStatus e
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
    S.get  "/blockchain/multiaddr" scottyMultiAddr
    S.post "/blockchain/unspent" scottyBinfoUnspent
    S.get  "/blockchain/unspent" scottyBinfoUnspent
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
    withMetrics blockResponseTime 1 $
    maybe (raise blockErrors ThingNotFound) (return . pruneTx noTx) =<<
    getBlock h

getBlocks :: (MonadUnliftIO m, MonadLoggerIO m)
          => [H.BlockHash]
          -> Bool
          -> WebT m [BlockData]
getBlocks hs notx =
    (pruneTx notx <$>) . catMaybes <$> mapM getBlock (nub hs)

scottyBlocks ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetBlocks -> WebT m [BlockData]
scottyBlocks (GetBlocks hs (NoTx notx)) =
    withMetrics blockResponseTime (length hs) $ getBlocks hs notx

pruneTx :: Bool -> BlockData -> BlockData
pruneTx False b = b
pruneTx True b  = b {blockDataTxs = take 1 (blockDataTxs b)}

-- GET BlockRaw --

scottyBlockRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockRaw
    -> WebT m (RawResult H.Block)
scottyBlockRaw (GetBlockRaw h) =
    withMetrics rawBlockResponseTime 1 $
    RawResult <$> getRawBlock h

getRawBlock ::
       (MonadUnliftIO m, MonadLoggerIO m) => H.BlockHash -> WebT m H.Block
getRawBlock h =
    withMetrics rawBlockResponseTime 1 $ do
    b <- maybe (raise blockErrors ThingNotFound) return =<< getBlock h
    refuseLargeBlock blockErrors b
    toRawBlock b

toRawBlock :: (Monad m, StoreReadBase m) => BlockData -> m H.Block
toRawBlock b = do
    let ths = blockDataTxs b
    txs <- map transactionData . catMaybes <$> mapM getTransaction ths
    return H.Block {H.blockHeader = blockDataHeader b, H.blockTxns = txs}

refuseLargeBlock :: MonadIO m
                 => (WebMetrics -> ErrorCounter)
                 -> BlockData
                 -> WebT m ()
refuseLargeBlock metric BlockData {blockDataTxs = txs} = do
    WebLimits {maxLimitFull = f} <- lift $ asks (webMaxLimits . webConfig)
    when (length txs > fromIntegral f) $ raise metric BlockTooLarge

-- GET BlockBest / BlockBestRaw --

scottyBlockBest ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetBlockBest -> WebT m BlockData
scottyBlockBest (GetBlockBest (NoTx notx)) =
    withMetrics blockResponseTime 1 $
    getBestBlock >>= \case
        Nothing -> raise blockErrors ThingNotFound
        Just bb -> getBlock bb >>= \case
            Nothing -> raise blockErrors ThingNotFound
            Just b  -> return $ pruneTx notx b

scottyBlockBestRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockBestRaw
    -> WebT m (RawResult H.Block)
scottyBlockBestRaw _ =
    withMetrics rawBlockResponseTime 1 $
    fmap RawResult $
    maybe (raise blockErrors ThingNotFound) getRawBlock =<< getBestBlock

-- GET BlockLatest --

scottyBlockLatest ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockLatest
    -> WebT m [BlockData]
scottyBlockLatest (GetBlockLatest (NoTx noTx)) =
    withMetrics blockResponseTime 100 $
    maybe (raise blockErrors ThingNotFound) (go [] <=< getBlock) =<< getBestBlock
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
scottyBlockHeight (GetBlockHeight h (NoTx notx)) =
    withMetrics blockResponseTime 1 $
    (`getBlocks` notx) =<< getBlocksAtHeight (fromIntegral h)

scottyBlockHeights ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockHeights
    -> WebT m [BlockData]
scottyBlockHeights (GetBlockHeights (HeightsParam heights) (NoTx notx)) =
    withMetrics blockResponseTime (length heights) $ do
    bhs <- concat <$> mapM getBlocksAtHeight (fromIntegral <$> heights)
    getBlocks bhs notx

scottyBlockHeightRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockHeightRaw
    -> WebT m (RawResultList H.Block)
scottyBlockHeightRaw (GetBlockHeightRaw h) =
    withMetrics rawBlockResponseTime 1 $
    RawResultList <$> (mapM getRawBlock =<< getBlocksAtHeight (fromIntegral h))

-- GET BlockTime / BlockTimeRaw --

scottyBlockTime :: (MonadUnliftIO m, MonadLoggerIO m)
                => GetBlockTime -> WebT m BlockData
scottyBlockTime (GetBlockTime (TimeParam t) (NoTx notx)) =
    withMetrics blockResponseTime 1 $ do
    ch <- lift $ asks (storeChain . webStore . webConfig)
    m <- blockAtOrBefore ch t
    maybe (raise blockErrors ThingNotFound) (return . pruneTx notx) m

scottyBlockMTP :: (MonadUnliftIO m, MonadLoggerIO m)
               => GetBlockMTP -> WebT m BlockData
scottyBlockMTP (GetBlockMTP (TimeParam t) (NoTx noTx)) =
    withMetrics blockResponseTime 1 $ do
    ch <- lift $ asks (storeChain . webStore . webConfig)
    m <- blockAtOrAfterMTP ch t
    maybe (raise blockErrors ThingNotFound) (return . pruneTx noTx) m

scottyBlockTimeRaw :: (MonadUnliftIO m, MonadLoggerIO m)
                   => GetBlockTimeRaw -> WebT m (RawResult H.Block)
scottyBlockTimeRaw (GetBlockTimeRaw (TimeParam t)) =
    withMetrics rawBlockResponseTime 1 $ do
    ch <- lift $ asks (storeChain . webStore . webConfig)
    m <- blockAtOrBefore ch t
    b <- maybe (raise blockErrors ThingNotFound) return m
    refuseLargeBlock blockErrors b
    RawResult <$> toRawBlock b

scottyBlockMTPRaw :: (MonadUnliftIO m, MonadLoggerIO m)
                  => GetBlockMTPRaw -> WebT m (RawResult H.Block)
scottyBlockMTPRaw (GetBlockMTPRaw (TimeParam t)) =
    withMetrics rawBlockResponseTime 1 $ do
    ch <- lift $ asks (storeChain . webStore . webConfig)
    m <- blockAtOrAfterMTP ch t
    b <- maybe (raise blockErrors ThingNotFound) return m
    refuseLargeBlock blockErrors b
    RawResult <$> toRawBlock b

-- GET Transactions --

scottyTx :: (MonadUnliftIO m, MonadLoggerIO m) => GetTx -> WebT m Transaction
scottyTx (GetTx txid) =
    withMetrics txResponseTime 1 $
    maybe (raise txErrors ThingNotFound) return =<< getTransaction txid

scottyTxs ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetTxs -> WebT m [Transaction]
scottyTxs (GetTxs txids) =
    withMetrics txResponseTime (length txids) $
    catMaybes <$> mapM getTransaction (nub txids)

scottyTxRaw ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetTxRaw -> WebT m (RawResult Tx)
scottyTxRaw (GetTxRaw txid) =
    withMetrics txResponseTime 1 $ do
    tx <- maybe (raise txErrors ThingNotFound) return =<< getTransaction txid
    return $ RawResult $ transactionData tx

scottyTxsRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetTxsRaw
    -> WebT m (RawResultList Tx)
scottyTxsRaw (GetTxsRaw txids) =
    withMetrics txResponseTime (length txids) $ do
    txs <- catMaybes <$> mapM getTransaction (nub txids)
    return $ RawResultList $ transactionData <$> txs

getTxsBlock :: (MonadUnliftIO m, MonadLoggerIO m)
            => H.BlockHash
            -> WebT m [Transaction]
getTxsBlock h = do
    b <- maybe (raise txErrors ThingNotFound) return =<< getBlock h
    refuseLargeBlock txErrors b
    catMaybes <$> mapM getTransaction (blockDataTxs b)

scottyTxsBlock ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetTxsBlock -> WebT m [Transaction]
scottyTxsBlock (GetTxsBlock h) =
    withMetrics txsBlockResponseTime 1 $ getTxsBlock h

scottyTxsBlockRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetTxsBlockRaw
    -> WebT m (RawResultList Tx)
scottyTxsBlockRaw (GetTxsBlockRaw h) =
    withMetrics txsBlockResponseTime 1 $
    RawResultList . fmap transactionData <$> getTxsBlock h

-- GET TransactionAfterHeight --

scottyTxAfter ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetTxAfter
    -> WebT m (GenericResult (Maybe Bool))
scottyTxAfter (GetTxAfter txid height) =
    withMetrics txAfterResponseTime 1 $
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
    withMetrics postTxResponseTime 1 $
    lift (asks webConfig) >>= \cfg -> lift (publishTx cfg tx) >>= \case
        Right ()             -> return $ TxId (txHash tx)
        Left e@(PubReject _) -> raise postTxErrors $ UserError $ show e
        _                    -> raise postTxErrors ServerError

-- | Publish a new transaction to the network.
publishTx ::
       (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m)
    => WebConfig
    -> Tx
    -> m (Either PubExcept ())
publishTx cfg tx =
    withSubscription pub $ \s ->
        getTransaction (txHash tx) >>= \case
            Just _  -> return $ Right ()
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
            Nothing         -> return $ Left PubTimeout
            Just (Left e)   -> return $ Left e
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
    withMetrics mempoolResponseTime 1 $ do
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
    withMetrics addrTxResponseTime 1 $
    getAddressTxs addr =<< paramToLimits False pLimits

scottyAddrsTxs ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrsTxs -> WebT m [TxRef]
scottyAddrsTxs (GetAddrsTxs addrs pLimits) =
    withMetrics addrTxResponseTime (length addrs) $
    getAddressesTxs addrs =<< paramToLimits False pLimits

scottyAddrTxsFull ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetAddrTxsFull
    -> WebT m [Transaction]
scottyAddrTxsFull (GetAddrTxsFull addr pLimits) =
    withMetrics addrTxFullResponseTime 1 $ do
    txs <- getAddressTxs addr =<< paramToLimits True pLimits
    catMaybes <$> mapM (getTransaction . txRefHash) txs

scottyAddrsTxsFull :: (MonadUnliftIO m, MonadLoggerIO m)
                   => GetAddrsTxsFull -> WebT m [Transaction]
scottyAddrsTxsFull (GetAddrsTxsFull addrs pLimits) =
    withMetrics addrTxFullResponseTime (length addrs) $ do
    txs <- getAddressesTxs addrs =<< paramToLimits True pLimits
    catMaybes <$> mapM (getTransaction . txRefHash) txs

scottyAddrBalance :: (MonadUnliftIO m, MonadLoggerIO m)
                  => GetAddrBalance -> WebT m Balance
scottyAddrBalance (GetAddrBalance addr) =
    withMetrics addrBalanceResponseTime 1 $
    getDefaultBalance addr

scottyAddrsBalance ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrsBalance -> WebT m [Balance]
scottyAddrsBalance (GetAddrsBalance addrs) =
    withMetrics addrBalanceResponseTime (length addrs) $
    getBalances addrs

scottyAddrUnspent ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrUnspent -> WebT m [Unspent]
scottyAddrUnspent (GetAddrUnspent addr pLimits) =
    withMetrics addrUnspentResponseTime 1 $
    getAddressUnspents addr =<< paramToLimits False pLimits

scottyAddrsUnspent ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrsUnspent -> WebT m [Unspent]
scottyAddrsUnspent (GetAddrsUnspent addrs pLimits) =
    withMetrics addrUnspentResponseTime (length addrs) $
    getAddressesUnspents addrs =<< paramToLimits False pLimits

-- GET XPubs --

scottyXPub ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetXPub -> WebT m XPubSummary
scottyXPub (GetXPub xpub deriv (NoCache noCache)) =
    withMetrics xPubResponseTime 1 $
    lift . runNoCache noCache $ xPubSummary $ XPubSpec xpub deriv

getXPubTxs :: (MonadUnliftIO m, MonadLoggerIO m)
           => XPubKey -> DeriveType -> LimitsParam -> Bool -> WebT m [TxRef]
getXPubTxs xpub deriv plimits nocache = do
    limits <- paramToLimits False plimits
    lift . runNoCache nocache $ xPubTxs (XPubSpec xpub deriv) limits

scottyXPubTxs ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetXPubTxs -> WebT m [TxRef]
scottyXPubTxs (GetXPubTxs xpub deriv plimits (NoCache nocache)) =
    withMetrics xPubTxResponseTime 1 $
    getXPubTxs xpub deriv plimits nocache

scottyXPubTxsFull ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetXPubTxsFull
    -> WebT m [Transaction]
scottyXPubTxsFull (GetXPubTxsFull xpub deriv plimits (NoCache nocache)) =
    withMetrics xPubTxFullResponseTime 1 $ do
    refs <- getXPubTxs xpub deriv plimits nocache
    txs <- lift . runNoCache nocache $ mapM (getTransaction . txRefHash) refs
    return $ catMaybes txs

scottyXPubBalances ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetXPubBalances -> WebT m [XPubBal]
scottyXPubBalances (GetXPubBalances xpub deriv (NoCache noCache)) =
    withMetrics xPubResponseTime 1 $
    filter f <$> lift (runNoCache noCache (xPubBals spec))
  where
    spec = XPubSpec xpub deriv
    f = not . nullBalance . xPubBal

scottyXPubUnspent ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetXPubUnspent
    -> WebT m [XPubUnspent]
scottyXPubUnspent (GetXPubUnspent xpub deriv pLimits (NoCache noCache)) =
    withMetrics xPubUnspentResponseTime 1 $ do
    limits <- paramToLimits False pLimits
    lift . runNoCache noCache $ xPubUnspents (XPubSpec xpub deriv) limits

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

getBinfoAddrsParam :: MonadIO m => Text -> WebT m (HashSet BinfoAddr)
getBinfoAddrsParam name = do
    net <- lift (asks (storeNetwork . webStore . webConfig))
    p <- S.param (cs name) `S.rescue` const (return "")
    case parseBinfoAddr net p of
        Nothing -> raise multiaddrErrors (UserError "invalid active address")
        Just xs -> return $ HashSet.fromList xs

getBinfoActive :: MonadIO m => WebT m (HashMap XPubKey XPubSpec, HashSet Address)
getBinfoActive = do
    active <- getBinfoAddrsParam "active"
    p2sh <- getBinfoAddrsParam "activeP2SH"
    bech32 <- getBinfoAddrsParam "activeBech32"
    let xspec d b = (\x -> (x, XPubSpec x d)) <$> xpub b
        xspecs = HashMap.fromList $ concat
                 [ mapMaybe (xspec DeriveNormal) (HashSet.toList active)
                 , mapMaybe (xspec DeriveP2SH) (HashSet.toList p2sh)
                 , mapMaybe (xspec DeriveP2WPKH) (HashSet.toList bech32)
                 ]
        addrs = HashSet.fromList . mapMaybe addr $ HashSet.toList active
    return (xspecs, addrs)
  where
    addr (BinfoAddr a) = Just a
    addr (BinfoXpub x) = Nothing
    xpub (BinfoXpub x) = Just x
    xpub (BinfoAddr _) = Nothing

scottyBinfoUnspent :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoUnspent =
    getBinfoActive >>= \(xspecs, addrs) ->
    let len = HashSet.size addrs + HashMap.size xspecs
    in withMetrics unspentResponseTime len $ do
    xuns <- get_xpub_unspents xspecs
    auns <- get_addr_unspents addrs
    net <- lift $ asks (storeNetwork . webStore . webConfig)
    numtxid <- lift $ asks (webNumTxId . webConfig)
    etxs <- if numtxid then Just <$> get_etxs xuns auns else return Nothing
    height <- get_height
    limit <- get_limit
    min_conf <- get_min_conf
    let g k = map (xpub_unspent etxs height k)
        xbus = concatMap (uncurry g) (HashMap.toList xuns)
        abus = map (unspent etxs height) auns
        f u@BinfoUnspent{..} =
            ((getBinfoUnspentHash, getBinfoUnspentOutputIndex), u)
        busm = HashMap.fromList (map f (xbus ++ abus))
        bus =
            take limit $
            filter ((min_conf <=) . getBinfoUnspentConfirmations) $
            sortBy
            (flip compare `on` getBinfoUnspentConfirmations)
            (HashMap.elems busm)
    setHeaders
    S.json $ binfoUnspentsToJSON net (BinfoUnspents bus)
  where
    get_limit = fmap (min 1000) $ S.param "limit" `S.rescue` const (return 250)
    get_min_conf = S.param "limit" `S.rescue` const (return 0)
    get_etxs xuns auns = do
        let als = map (outPointHash . unspentPoint) auns
            xelems = concat (HashMap.elems xuns)
            xls = map (outPointHash . unspentPoint . xPubUnspent) xelems
            ids = HashSet.fromList (als ++ xls)
            f i = fmap (i,) <$> getTransaction i
        HashMap.fromList . catMaybes <$> mapM f (HashSet.toList ids)
    get_height =
        getBestBlock >>= \case
        Nothing -> raise unspentErrors ThingNotFound
        Just bh -> getBlock bh >>= \case
            Nothing -> raise unspentErrors ThingNotFound
            Just b  -> return (blockDataHeight b)
    xpub_unspent etxs height xpub (XPubUnspent p u) =
        let path = toSoft (listToPath p)
            xp = BinfoXPubPath xpub <$> path
            bu = unspent etxs height u
        in bu {getBinfoUnspentXPub = xp}
    unspent etxs height Unspent{..} =
        let conf = case unspentBlock of
                       MemRef{}     -> 0
                       BlockRef h _ -> height - h
            hash = outPointHash unspentPoint
            idx = outPointIndex unspentPoint
            val = unspentAmount
            script = fromShort unspentScript
            txi = getBinfoTxId etxs hash
        in BinfoUnspent
           { getBinfoUnspentHash = hash
           , getBinfoUnspentOutputIndex = idx
           , getBinfoUnspentScript = script
           , getBinfoUnspentValue = val
           , getBinfoUnspentConfirmations = conf
           , getBinfoUnspentTxIndex = txi
           , getBinfoUnspentXPub = Nothing
           }
    get_xpub_unspents = mapM (`xPubUnspents` def)
    get_addr_unspents = (`getAddressesUnspents` def) . HashSet.toList

scottyMultiAddr :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyMultiAddr =
    get_addrs >>= \(addrs, xpubs, saddrs, sxpubs, xspecs) ->
    let len = HashSet.size addrs + HashSet.size xpubs
    in withMetrics multiaddrResponseTime len $ do
    prune <- get_prune
    n <- get_count
    offset <- get_offset
    cashaddr <- get_cashaddr
    numtxid <- lift $ asks (webNumTxId . webConfig)
    xbals <- get_xbals xspecs
    let sxbals = subset sxpubs xbals
    xtrs <- get_xtrs xspecs
    abals <- get_abals addrs
    atrs <- get_atrs addrs
    ticker <- lift $ asks webTicker
    local <- get_price ticker
    let xtns = HashMap.map length xtrs
        xtrset = Set.fromList . concat $ HashMap.elems xtrs
        xabals = compute_xabals xbals
        sxabals = compute_xabals sxbals
        sabals = subset saddrs abals
        sallbals = sabals <> sxabals
        allbals = abals <> xabals
        abook = compute_abook addrs xbals
        sxaddrs = compute_xaddrs sxbals
        salladdrs = sxaddrs <> saddrs
        bal = compute_bal allbals
        alltrs = xtrset <> atrs
        txids = compute_txids alltrs
    txs <- get_txs salladdrs (n + offset) txids
    let etxids =
            if numtxid
            then compute_etxids prune abook (map fst (filter snd txs))
            else []
    etxs <- if numtxid
            then Just <$> get_etxs etxids
            else return Nothing
    best <- get_best_block
    peers <- get_peers
    net <- lift $ asks (storeNetwork . webStore . webConfig)
    let ibal = fromIntegral bal
        btxs = binfo_txs etxs abook prune ibal txs
        ftxs = drop offset btxs
        baddrs = toBinfoAddrs sabals sxbals xtns
        abaddrs = toBinfoAddrs abals xbals xtns
        recv = sum $ map getBinfoAddrReceived abaddrs
        sent = sum $ map getBinfoAddrSent abaddrs
        txn = fromIntegral $ Set.size alltrs
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
        { getBinfoMultiAddrAddresses = baddrs
        , getBinfoMultiAddrWallet = wallet
        , getBinfoMultiAddrTxs = ftxs
        , getBinfoMultiAddrInfo = info
        , getBinfoMultiAddrRecommendFee = True
        , getBinfoMultiAddrCashAddr = cashaddr
        }
  where
    get_best_block =
        getBestBlock >>= \case
        Nothing -> raise multiaddrErrors ThingNotFound
        Just bh -> getBlock bh >>= \case
            Nothing -> raise multiaddrErrors ThingNotFound
            Just b  -> return b
    get_price ticker = do
        code <- T.toUpper <$> S.param "currency" `S.rescue` const (return "USD")
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
    subset ks =
        HashMap.filterWithKey (\k _ -> k `HashSet.member` ks)
    addr (BinfoAddr a) = Just a
    addr (BinfoXpub x) = Nothing
    xpub (BinfoXpub x) = Just x
    xpub (BinfoAddr _) = Nothing
    binfo_txs _ _ _ _ [] = []
    binfo_txs etxs abook prune ibal ((t, i):ts) =
        let b = toBinfoTx etxs abook prune ibal t
            nbal = case getBinfoTxResultBal b of
                Nothing     -> ibal
                Just (_, x) -> ibal - x
         in if i
            then b : binfo_txs etxs abook prune nbal ts
            else binfo_txs etxs abook prune nbal ts
    get_addrs = do
        (xspecs, addrs) <- getBinfoActive
        sh <- getBinfoAddrsParam "onlyShow"
        let xpubs = HashMap.keysSet xspecs
            actives = HashSet.map BinfoAddr addrs <>
                      HashSet.map BinfoXpub xpubs
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
    get_xtrs =
        let f (k, s) = (,) k <$> xPubTxs s def
        in fmap HashMap.fromList . mapM f . HashMap.toList
    get_atrs =
        let f x = getAddressesTxs x def
        in fmap Set.fromList . f . HashSet.toList
    get_txs _ _ [] = return []
    get_txs _ 0 _ = return []
    get_txs s n (i:is) =
        getTransaction i >>= \case
        Nothing -> get_txs s n is
        Just t ->
            if addr_in_set s t
            then ((t, True):) <$> get_txs s (n - 1) is
            else ((t, False):) <$> get_txs s n is
    addr_in_set s t =
        let f StoreCoinbase{}                    = False
            f StoreInput{inputAddress = Nothing} = False
            f StoreInput{inputAddress = Just a}  = a `HashSet.member` s
            g StoreOutput{outputAddress = m} = case m of
                Nothing -> False
                Just a  -> a `HashSet.member` s
            i = any f (transactionInputs t)
            o = any g (transactionOutputs t)
        in i || o
    get_etxs =
        let f t = (txHash (transactionData t), t)
            g = HashMap.fromList . map f . catMaybes
        in fmap g . mapM getTransaction
    get_peers = do
        ps <- lift $ getPeersInformation =<<
            asks (storeManager . webStore . webConfig)
        return (fromIntegral (length ps))
    compute_txids = map txRefHash . Set.toDescList
    compute_etxids prune abook =
        let f = relevantTxs (HashMap.keysSet abook) prune
        in HashSet.toList . foldl HashSet.union HashSet.empty . map f
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
    withMetrics rawtxResponseTime 1 $
    lift (asks (webNumTxId . webConfig)) >>= \num -> S.param "txid" >>= \case
        BinfoTxIdHash h -> go num h
        BinfoTxIdIndex i ->
            if | not num || isBinfoTxIndexNull i -> raise rawtxErrors ThingNotFound
               | isBinfoTxIndexBlock i           -> block i
               | isBinfoTxIndexHash i            -> hash i
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
        Nothing -> raise rawtxErrors ThingNotFound
        Just t -> get_format >>= \case
            "hex" -> hex t
            _     -> js num t
    block i =
        let Just (height, pos) = binfoTxIndexBlock i
        in getBlocksAtHeight height >>= \case
            [] -> raise rawtxErrors ThingNotFound
            h:_ -> getBlock h >>= \case
                Nothing -> raise rawtxErrors ThingNotFound
                Just BlockData{..} ->
                    if length blockDataTxs > fromIntegral pos
                    then go True (blockDataTxs !! fromIntegral pos)
                    else raise rawtxErrors ThingNotFound
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
            Just k  -> g 10 k
    hash h = hmem h >>= \case
        Nothing -> hblock h >>= \case
            Nothing -> raise rawtxErrors ThingNotFound
            Just x  -> go True x
        Just x -> go True x

-- GET Network Information --

scottyPeers :: (MonadUnliftIO m, MonadLoggerIO m)
            => GetPeers
            -> WebT m [PeerInformation]
scottyPeers _ =
    withMetrics peerResponseTime 1 $
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
    withMetrics healthResponseTime 1 $ do
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
    withMetrics dbStatsResponseTime 1 $ do
    setHeaders
    db <- lift $ asks (databaseHandle . storeDB . webStore . webConfig)
    statsM <- lift (getProperty db Stats)
    S.text $ maybe "Could not get stats" cs statsM

-----------------------
-- Parameter Parsing --
-----------------------

-- | Returns @Nothing@ if the parameter is not supplied. Raises an exception on
-- parse failure.
paramOptional :: (Param a, MonadIO m) => WebT m (Maybe a)
paramOptional = go Proxy
  where
    go :: (Param a, MonadIO m) => Proxy a -> WebT m (Maybe a)
    go proxy = do
        net <- lift $ asks (storeNetwork . webStore . webConfig)
        tsM :: Maybe [Text] <- p `S.rescue` const (return Nothing)
        case tsM of
            Nothing -> return Nothing -- Parameter was not supplied
            Just ts -> maybe (raise_ err) (return . Just) $ parseParam net ts
      where
        l = proxyLabel proxy
        p = Just <$> S.param (cs l)
        err = UserError $ "Unable to parse param " <> cs l

-- | Raises an exception if the parameter is not supplied
param :: (Param a, MonadIO m) => WebT m a
param = go Proxy
  where
    go :: (Param a, MonadIO m) => Proxy a -> WebT m a
    go proxy = do
        resM <- paramOptional
        case resM of
            Just res -> return res
            _ ->
                raise_ . UserError $
                "The param " <> cs (proxyLabel proxy) <> " was not defined"

-- | Returns the default value of a parameter if it is not supplied. Raises an
-- exception on parse failure.
paramDef :: (Default a, Param a, MonadIO m) => WebT m a
paramDef = fromMaybe def <$> paramOptional

-- | Does not raise exceptions. Will call @Scotty.next@ if the parameter is
-- not supplied or if parsing fails.
paramLazy :: (Param a, MonadIO m) => WebT m a
paramLazy = do
    resM <- paramOptional `S.rescue` const (return Nothing)
    maybe S.next return resM

parseBody :: (MonadIO m, Serialize a) => WebT m a
parseBody = do
    b <- S.body
    case hex b <|> bin (L.toStrict b) of
        Nothing -> raise_ $ UserError "Failed to parse request body"
        Just x  -> return x
  where
    bin = eitherToMaybe . Serialize.decode
    hex = bin <=< decodeHex . cs . C.filter (not . isSpace)

parseOffset :: MonadIO m => WebT m OffsetParam
parseOffset = do
    res@(OffsetParam o) <- paramDef
    limits <- lift $ asks (webMaxLimits . webConfig)
    when (maxLimitOffset limits > 0 && fromIntegral o > maxLimitOffset limits) $
        raise_ . UserError $
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

parseLimits :: MonadIO m => WebT m LimitsParam
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
        t1 <- systemToUTCTime <$> liftIO getSystemTime
        app req $ \res -> do
            t2 <- systemToUTCTime <$> liftIO getSystemTime
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

