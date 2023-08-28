{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# OPTIONS_GHC -Wno-deprecations #-}

module Haskoin.Store.Web
  ( -- * Web
    WebConfig (..),
    Except (..),
    WebLimits (..),
    runWeb,
  )
where

import Conduit
  ( ConduitT,
    await,
    concatMapC,
    concatMapMC,
    dropC,
    dropWhileC,
    headC,
    iterMC,
    mapC,
    runConduit,
    sinkList,
    takeC,
    takeWhileC,
    yield,
    (.|),
  )
import Control.Applicative ((<|>))
import Control.Arrow (second)
import Control.Lens ((.~), (^.))
import Control.Monad
  ( forM_,
    forever,
    join,
    unless,
    when,
    (<=<),
    (>=>),
  )
import Control.Monad.Logger
  ( MonadLoggerIO,
    logDebugS,
    logErrorS,
    logWarnS,
  )
import Control.Monad.Reader
  ( ReaderT,
    asks,
    local,
    runReaderT,
  )
import Control.Monad.Trans (lift)
import Control.Monad.Trans.Control (liftWith, restoreT)
import Control.Monad.Trans.Maybe
  ( MaybeT (..),
    runMaybeT,
  )
import Data.Aeson
  ( Encoding,
    ToJSON (..),
    Value,
  )
import Data.Aeson qualified as A
import Data.Aeson.Encode.Pretty
  ( Config (..),
    defConfig,
    encodePretty',
  )
import Data.Aeson.Encoding
  ( encodingToLazyByteString,
    list,
  )
import Data.Aeson.Text (encodeToLazyText)
import Data.Base16.Types (assertBase16)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Base16 (decodeBase16, isBase16)
import Data.ByteString.Builder (byteString, lazyByteString)
import Data.ByteString.Char8 qualified as C
import Data.ByteString.Lazy qualified as L
import Data.Bytes.Get
import Data.Bytes.Put
import Data.Bytes.Serial
import Data.Char (isSpace)
import Data.Default (Default (..))
import Data.Function ((&))
import Data.Functor (void)
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HashMap
import Data.HashSet (HashSet)
import Data.HashSet qualified as HashSet
import Data.Int (Int64)
import Data.List (nub)
import Data.Maybe
  ( catMaybes,
    fromJust,
    fromMaybe,
    isJust,
    mapMaybe,
    maybeToList,
  )
import Data.Proxy (Proxy (..))
import Data.Serialize (decode)
import Data.String (fromString)
import Data.String.Conversions (cs)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Data.Text.Lazy (toStrict)
import Data.Text.Lazy qualified as TL
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Time.Clock.System
  ( getSystemTime,
    systemSeconds,
    systemToUTCTime,
  )
import Data.Vault.Lazy qualified as V
import Data.Word (Word32, Word64)
import Database.RocksDB
  ( Property (..),
    getProperty,
  )
import GHC.RTS.Flags (ConcFlags (ConcFlags))
import Haskoin.Address
import Haskoin.Block qualified as H
import Haskoin.Crypto.Hash (Hash160 (..))
import Haskoin.Crypto.Keys
import Haskoin.Network
import Haskoin.Node
  ( Chain,
    OnlinePeer (..),
    PeerMgr,
    chainGetAncestor,
    chainGetBest,
    getPeers,
    sendMessage,
  )
import Haskoin.Script
import Haskoin.Store.BlockStore
import Haskoin.Store.Cache
import Haskoin.Store.Common
import Haskoin.Store.Data
import Haskoin.Store.Database.Reader
import Haskoin.Store.Manager
import Haskoin.Store.Stats
import Haskoin.Store.WebCommon
import Haskoin.Transaction
import Haskoin.Util
import NQE
  ( Inbox,
    Publisher,
    receive,
    withSubscription,
  )
import Network.HTTP.Types
  ( Status (..),
    hContentType,
    requestEntityTooLarge413,
    status400,
    status404,
    status409,
    status413,
    status500,
    status503,
    statusIsClientError,
    statusIsServerError,
    statusIsSuccessful,
  )
import Network.Wai
  ( Middleware,
    Request (..),
    Response,
    getRequestBodyChunk,
    responseLBS,
    responseStatus,
  )
import Network.Wai qualified as S
import Network.Wai.Handler.Warp
  ( defaultSettings,
    setHost,
    setPort,
  )
import Network.Wai.Handler.WebSockets (websocketsOr)
import Network.Wai.Middleware.RequestSizeLimit
import Network.Wai.Middleware.Timeout
import Network.WebSockets
  ( ServerApp,
    acceptRequest,
    defaultConnectionOptions,
    pendingRequest,
    rejectRequestWith,
    requestPath,
    sendTextData,
  )
import Network.WebSockets qualified as WebSockets
import Network.Wreq qualified as Wreq
import Network.Wreq.Session as Wreq (Session)
import Network.Wreq.Session qualified as Wreq.Session
import System.IO.Unsafe (unsafeInterleaveIO)
import System.Metrics qualified as Metrics
import System.Metrics.Gauge qualified as Metrics (Gauge)
import System.Metrics.Gauge qualified as Metrics.Gauge
import UnliftIO
  ( MonadIO,
    MonadUnliftIO,
    TVar,
    askRunInIO,
    atomically,
    bracket,
    bracket_,
    handleAny,
    liftIO,
    modifyTVar,
    newTVarIO,
    readTVarIO,
    timeout,
    withAsync,
    withRunInIO,
    writeTVar,
  )
import UnliftIO.Concurrent (threadDelay)
import Web.Scotty.Internal.Types (ActionT)
import Web.Scotty.Trans qualified as S

type WebT m = ActionT Except (ReaderT WebState m)

data WebLimits = WebLimits
  { maxItemCount :: !Word32,
    maxFullItemCount :: !Word32,
    maxOffset :: !Word32,
    defItemCount :: !Word32,
    xpubGap :: !Word32,
    xpubGapInit :: !Word32,
    maxBodySize :: !Word32,
    txTimeout :: !Word64,
    blockTimeout :: !Word64
  }
  deriving (Eq, Show)

instance Default WebLimits where
  def =
    WebLimits
      { maxItemCount = 200000,
        maxFullItemCount = 5000,
        maxOffset = 50000,
        defItemCount = 100,
        xpubGap = 32,
        xpubGapInit = 20,
        maxBodySize = 1024 * 1024,
        txTimeout = 3600 `div` 2,
        blockTimeout = 4 * 3600
      }

data WebConfig = WebConfig
  { host :: !String,
    port :: !Int,
    store :: !Store,
    maxLaggingBlocks :: !Int,
    maxPendingTxs :: !Int,
    minPeers :: !Int,
    limits :: !WebLimits,
    version :: !String,
    noMempool :: !Bool,
    statsStore :: !(Maybe Metrics.Store),
    tickerRefresh :: !Int,
    tickerURL :: !String,
    priceHistoryURL :: !String,
    noSlow :: !Bool,
    noBlockchainInfo :: !Bool,
    healthCheckInterval :: !Int
  }

data WebState = WebState
  { config :: !WebConfig,
    ticker :: !(TVar (HashMap Text BinfoTicker)),
    metrics :: !(Maybe WebMetrics),
    session :: !Wreq.Session,
    health :: !(TVar HealthCheck)
  }

data WebMetrics = WebMetrics
  { all :: !StatDist,
    -- Addresses
    addressTx :: !StatDist,
    addressTxFull :: !StatDist,
    addressBalance :: !StatDist,
    addressUnspent :: !StatDist,
    xpub :: !StatDist,
    xpubDelete :: !StatDist,
    xpubTxFull :: !StatDist,
    xpubTx :: !StatDist,
    xpubBalance :: !StatDist,
    xpubUnspent :: !StatDist,
    -- Transactions
    tx :: !StatDist,
    txRaw :: !StatDist,
    txAfter :: !StatDist,
    txBlock :: !StatDist,
    txBlockRaw :: !StatDist,
    txPost :: !StatDist,
    mempool :: !StatDist,
    -- Blocks
    block :: !StatDist,
    blockRaw :: !StatDist,
    -- Blockchain
    binfoMultiaddr :: !StatDist,
    binfoBalance :: !StatDist,
    binfoAddressRaw :: !StatDist,
    binfoUnspent :: !StatDist,
    binfoTxRaw :: !StatDist,
    binfoBlock :: !StatDist,
    binfoBlockHeight :: !StatDist,
    binfoBlockLatest :: !StatDist,
    binfoBlockRaw :: !StatDist,
    binfoMempool :: !StatDist,
    binfoExportHistory :: !StatDist,
    -- Blockchain /q endpoints
    binfoQaddresstohash :: !StatDist,
    binfoQhashtoaddress :: !StatDist,
    binfoQaddrpubkey :: !StatDist,
    binfoQpubkeyaddr :: !StatDist,
    binfoQhashpubkey :: !StatDist,
    binfoQgetblockcount :: !StatDist,
    binfoQlatesthash :: !StatDist,
    binfoQbcperblock :: !StatDist,
    binfoQtxtotalbtcoutput :: !StatDist,
    binfoQtxtotalbtcinput :: !StatDist,
    binfoQtxfee :: !StatDist,
    binfoQtxresult :: !StatDist,
    binfoQgetreceivedbyaddress :: !StatDist,
    binfoQgetsentbyaddress :: !StatDist,
    binfoQaddressbalance :: !StatDist,
    binfoQaddressfirstseen :: !StatDist,
    -- Others
    health :: !StatDist,
    peers :: !StatDist,
    db :: !StatDist,
    events :: !Metrics.Gauge.Gauge,
    -- Request
    key :: !(V.Key (TVar (Maybe (WebMetrics -> StatDist))))
  }

createMetrics :: (MonadIO m) => Metrics.Store -> m WebMetrics
createMetrics s = liftIO $ do
  all <- d "all"

  -- Addresses
  addressTx <- d "address_transactions"
  addressTxFull <- d "address_transactions_full"
  addressBalance <- d "address_balance"
  addressUnspent <- d "address_unspent"
  xpub <- d "xpub"
  xpubDelete <- d "xpub_delete"
  xpubTxFull <- d "xpub_transactions_full"
  xpubTx <- d "xpub_transactions"
  xpubBalance <- d "xpub_balances"
  xpubUnspent <- d "xpub_unspent"

  -- Transactions
  tx <- d "transaction"
  txRaw <- d "transaction_raw"
  txAfter <- d "transaction_after"
  txPost <- d "transaction_post"
  txBlock <- d "transactions_block"
  txBlockRaw <- d "transactions_block_raw"
  mempool <- d "mempool"

  -- Blocks
  block <- d "block"
  blockRaw <- d "block_raw"

  -- Blockchain
  binfoMultiaddr <- d "blockchain_multiaddr"
  binfoBalance <- d "blockchain_balance"
  binfoAddressRaw <- d "blockchain_rawaddr"
  binfoUnspent <- d "blockchain_unspent"
  binfoTxRaw <- d "blockchain_rawtx"
  binfoBlock <- d "blockchain_blocks"
  binfoBlockHeight <- d "blockchain_block_height"
  binfoBlockLatest <- d "blockchain_latestblock"
  binfoBlockRaw <- d "blockchain_rawblock"
  binfoMempool <- d "blockchain_mempool"
  binfoExportHistory <- d "blockchain_export_history"

  -- Blockchain /q endpoints
  binfoQaddresstohash <- d "blockchain_q_addresstohash"
  binfoQhashtoaddress <- d "blockchain_q_hashtoaddress"
  binfoQaddrpubkey <- d "blockckhain_q_addrpubkey"
  binfoQpubkeyaddr <- d "blockchain_q_pubkeyaddr"
  binfoQhashpubkey <- d "blockchain_q_hashpubkey"
  binfoQgetblockcount <- d "blockchain_q_getblockcount"
  binfoQlatesthash <- d "blockchain_q_latesthash"
  binfoQbcperblock <- d "blockchain_q_bcperblock"
  binfoQtxtotalbtcoutput <- d "blockchain_q_txtotalbtcoutput"
  binfoQtxtotalbtcinput <- d "blockchain_q_txtotalbtcinput"
  binfoQtxfee <- d "blockchain_q_txfee"
  binfoQtxresult <- d "blockchain_q_txresult"
  binfoQgetreceivedbyaddress <- d "blockchain_q_getreceivedbyaddress"
  binfoQgetsentbyaddress <- d "blockchain_q_getsentbyaddress"
  binfoQaddressbalance <- d "blockchain_q_addressbalance"
  binfoQaddressfirstseen <- d "blockchain_q_addressfirstseen"

  -- Others
  health <- d "health"
  peers <- d "peers"
  db <- d "dbstats"

  events <- g "events_connected"
  key <- V.newKey
  return WebMetrics {..}
  where
    d x = createStatDist ("web." <> x) s
    g x = Metrics.createGauge ("web." <> x) s

withGaugeIO :: (MonadUnliftIO m) => Metrics.Gauge -> m a -> m a
withGaugeIO g =
  bracket_
    (liftIO $ Metrics.Gauge.inc g)
    (liftIO $ Metrics.Gauge.dec g)

withGaugeIncrease ::
  (MonadUnliftIO m) =>
  (WebMetrics -> Metrics.Gauge) ->
  WebT m a ->
  WebT m a
withGaugeIncrease gf go =
  lift (asks (.metrics)) >>= \case
    Nothing -> go
    Just m -> do
      s <- liftWith $ \run -> withGaugeIO (gf m) (run go)
      restoreT $ return s

setMetrics :: (MonadUnliftIO m) => (WebMetrics -> StatDist) -> WebT m ()
setMetrics df =
  asks (.metrics) >>= mapM_ go
  where
    go m = do
      req <- S.request
      let t = fromMaybe e $ V.lookup m.key (vault req)
      atomically $ writeTVar t (Just df)
    e = error "The ways of the warrior are yet to be mastered."

data SerialAs = SerialAsBinary | SerialAsJSON | SerialAsPrettyJSON
  deriving (Eq, Show)

instance
  (MonadUnliftIO m, MonadLoggerIO m) =>
  StoreReadBase (ReaderT WebState m)
  where
  getCtx = runInWebReader getCtx
  getNetwork = runInWebReader getNetwork
  getBestBlock = runInWebReader getBestBlock
  getBlocksAtHeight height = runInWebReader (getBlocksAtHeight height)
  getBlock bh = runInWebReader (getBlock bh)
  getTxData th = runInWebReader (getTxData th)
  getSpender op = runInWebReader (getSpender op)
  getUnspent op = runInWebReader (getUnspent op)
  getBalance a = runInWebReader (getBalance a)
  getMempool = runInWebReader getMempool

instance
  (MonadUnliftIO m, MonadLoggerIO m) =>
  StoreReadExtra (ReaderT WebState m)
  where
  getMaxGap = runInWebReader getMaxGap
  getInitialGap = runInWebReader getInitialGap
  getBalances as = runInWebReader (getBalances as)
  getAddressesTxs as = runInWebReader . getAddressesTxs as
  getAddressTxs a = runInWebReader . getAddressTxs a
  getAddressUnspents a = runInWebReader . getAddressUnspents a
  getAddressesUnspents as = runInWebReader . getAddressesUnspents as
  xPubBals = runInWebReader . xPubBals
  xPubUnspents xpub xbals = runInWebReader . xPubUnspents xpub xbals
  xPubTxs xpub xbals = runInWebReader . xPubTxs xpub xbals
  xPubTxCount xpub = runInWebReader . xPubTxCount xpub
  getNumTxData = runInWebReader . getNumTxData

instance (MonadUnliftIO m, MonadLoggerIO m) => StoreReadBase (WebT m) where
  getCtx = lift getCtx
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
  getAddressTxs a = lift . getAddressTxs a
  getAddressUnspents a = lift . getAddressUnspents a
  getAddressesUnspents as = lift . getAddressesUnspents as
  xPubBals = lift . xPubBals
  xPubUnspents xpub xbals = lift . xPubUnspents xpub xbals
  xPubTxs xpub xbals = lift . xPubTxs xpub xbals
  xPubTxCount xpub = lift . xPubTxCount xpub
  getMaxGap = lift getMaxGap
  getInitialGap = lift getInitialGap
  getNumTxData = lift . getNumTxData

-------------------
-- Path Handlers --
-------------------

runWeb :: (MonadUnliftIO m, MonadLoggerIO m) => WebConfig -> m ()
runWeb config = do
  ticker <- newTVarIO HashMap.empty
  metrics <- mapM createMetrics config.statsStore
  session <- liftIO Wreq.Session.newAPISession
  health <- runHealthCheck >>= newTVarIO
  let state = WebState {..}
  withAsync (priceUpdater session ticker) $ \_a1 ->
    withAsync (healthCheckLoop health) $ \_a2 -> do
      logger <- logIt metrics
      runner <- askRunInIO
      S.scottyOptsT opts (runner . flip runReaderT state) $ do
        S.middleware $ webSocketEvents state
        S.middleware logger
        S.middleware $ reqSizeLimit config.limits.maxBodySize
        S.defaultHandler defHandler
        handlePaths config
        S.notFound $ raise ThingNotFound
  where
    priceUpdater session =
      unless (config.noSlow || config.noBlockchainInfo)
        . price
          config.store.net
          session
          config.tickerURL
          config.tickerRefresh
    runHealthCheck = runReaderT (healthCheck config) config.store.db
    healthCheckLoop v = forever $ do
      threadDelay (config.healthCheckInterval * 1000 * 1000)
      runHealthCheck >>= atomically . writeTVar v
    opts = def {S.settings = settings defaultSettings}
    settings = setPort config.port . setHost (fromString config.host)

getRates ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  Network ->
  Wreq.Session ->
  String ->
  Text ->
  [Word64] ->
  m [BinfoRate]
getRates net session url currency times = do
  handleAny err $ do
    r <-
      liftIO $
        Wreq.asJSON
          =<< Wreq.Session.postWith opts session url body
    return $ r ^. Wreq.responseBody
  where
    err _ = do
      $(logErrorS) "Web" "Could not get historic prices"
      return []
    body = toJSON times
    base =
      Wreq.defaults
        & Wreq.param "base" .~ [T.toUpper $ T.pack net.name]
    opts = base & Wreq.param "quote" .~ [currency]

price ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  Network ->
  Wreq.Session ->
  String ->
  Int ->
  TVar (HashMap Text BinfoTicker) ->
  m ()
price net session url pget v = forM_ purl $ \u -> forever $ do
  let err e = $(logErrorS) "Price" $ cs (show e)
  handleAny err $ do
    r <- liftIO $ Wreq.asJSON =<< Wreq.Session.get session u
    atomically . writeTVar v $ r ^. Wreq.responseBody
  threadDelay pget
  where
    purl = case code of
      Nothing -> Nothing
      Just x -> Just (url <> "?base=" <> x)
      where
        code
          | net == btc = Just "btc"
          | net == bch = Just "bch"
          | otherwise = Nothing

raise :: (MonadIO m) => Except -> WebT m a
raise err =
  lift (asks (.metrics)) >>= \case
    Nothing -> S.raise err
    Just m -> do
      req <- S.request
      mM <- case V.lookup m.key (vault req) of
        Nothing -> return Nothing
        Just t -> readTVarIO t
      let status = errStatus err
      if
        | statusIsClientError status ->
            liftIO $ do
              addClientError m.all
              forM_ mM $ \f -> addClientError (f m)
        | statusIsServerError status ->
            liftIO $ do
              addServerError m.all
              forM_ mM $ \f -> addServerError (f m)
        | otherwise ->
            return ()
      S.raise err

errStatus :: Except -> Status
errStatus ThingNotFound = status404
errStatus BadRequest = status400
errStatus UserError {} = status400
errStatus StringError {} = status400
errStatus ServerError = status500
errStatus TxIndexConflict {} = status409
errStatus ServerTimeout = status500
errStatus RequestTooLarge = status413

defHandler :: (Monad m) => Except -> WebT m ()
defHandler e = do
  setHeaders
  S.status $ errStatus e
  S.json e

handlePaths ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  WebConfig ->
  S.ScottyT Except (ReaderT WebState m) ()
handlePaths WebConfig {..} = do
  -- Block Paths
  pathCompact
    (GetBlock <$> paramLazy <*> paramDef)
    scottyBlock
    (marshalEncoding net)
    (marshalValue net)
  pathCompact
    (GetBlockBest <$> paramDef)
    scottyBlockBest
    (marshalEncoding net)
    (marshalValue net)
  pathCompact
    (GetBlockHeight <$> paramLazy <*> paramDef)
    (fmap SerialList . scottyBlockHeight)
    (list (marshalEncoding net) . (.get))
    (json_list (marshalValue net) . (.get))
  pathCompact
    (GetBlockTime <$> paramLazy <*> paramDef)
    scottyBlockTime
    (marshalEncoding net)
    (marshalValue net)
  pathCompact
    (GetBlockMTP <$> paramLazy <*> paramDef)
    scottyBlockMTP
    (marshalEncoding net)
    (marshalValue net)
  pathCompact
    (GetTx <$> paramLazy)
    scottyTx
    (marshalEncoding net)
    (marshalValue net)
  pathCompact
    (GetTxRaw <$> paramLazy)
    scottyTxRaw
    toEncoding
    toJSON
  pathCompact
    (PostTx <$> parseBody)
    scottyPostTx
    toEncoding
    toJSON
  pathCompact
    (GetMempool <$> paramOptional <*> parseOffset)
    (fmap SerialList . scottyMempool)
    toEncoding
    toJSON
  pathCompact
    (GetAddrTxs <$> paramLazy <*> parseLimits)
    (fmap SerialList . scottyAddrTxs)
    toEncoding
    toJSON
  pathCompact
    (GetAddrBalance <$> paramLazy)
    scottyAddrBalance
    (marshalEncoding net)
    (marshalValue net)
  pathCompact
    (GetAddrUnspent <$> paramLazy <*> parseLimits)
    (fmap SerialList . scottyAddrUnspent)
    (list (marshalEncoding net) . (.get))
    (json_list (marshalValue net) . (.get))
  pathCompact
    (GetPeers & return)
    (fmap SerialList . scottyPeers)
    toEncoding
    toJSON
  pathCompact
    (GetHealth & return)
    scottyHealth
    toEncoding
    toJSON
  S.get "/events" scottyEvents
  S.get "/dbstats" scottyDbStats
  unless noSlow $ do
    pathCompact
      (GetBlocks <$> param <*> paramDef)
      (fmap SerialList . scottyBlocks)
      (list (marshalEncoding net) . (.get))
      (json_list (marshalValue net) . (.get))
    pathCompact
      (GetBlockRaw <$> paramLazy)
      scottyBlockRaw
      toEncoding
      toJSON
    pathCompact
      (GetBlockBestRaw & return)
      scottyBlockBestRaw
      toEncoding
      toJSON
    pathCompact
      (GetBlockLatest <$> paramDef)
      (fmap SerialList . scottyBlockLatest)
      (list (marshalEncoding net) . (.get))
      (json_list (marshalValue net) . (.get))
    pathCompact
      (GetBlockHeights <$> param <*> paramDef)
      (fmap SerialList . scottyBlockHeights)
      (list (marshalEncoding net) . (.get))
      (json_list (marshalValue net) . (.get))
    pathCompact
      (GetBlockHeightRaw <$> paramLazy)
      scottyBlockHeightRaw
      toEncoding
      toJSON
    pathCompact
      (GetBlockTimeRaw <$> paramLazy)
      scottyBlockTimeRaw
      toEncoding
      toJSON
    pathCompact
      (GetBlockMTPRaw <$> paramLazy)
      scottyBlockMTPRaw
      toEncoding
      toJSON
    pathCompact
      (GetTxs <$> param)
      (fmap SerialList . scottyTxs)
      (list (marshalEncoding net) . (.get))
      (json_list (marshalValue net) . (.get))
    pathCompact
      (GetTxsRaw <$> param)
      scottyTxsRaw
      toEncoding
      toJSON
    pathCompact
      (GetTxsBlock <$> paramLazy)
      (fmap SerialList . scottyTxsBlock)
      (list (marshalEncoding net) . (.get))
      (json_list (marshalValue net) . (.get))
    pathCompact
      (GetTxsBlockRaw <$> paramLazy)
      scottyTxsBlockRaw
      toEncoding
      toJSON
    pathCompact
      (GetTxAfter <$> paramLazy <*> paramLazy)
      scottyTxAfter
      toEncoding
      toJSON
    pathCompact
      (GetAddrsTxs <$> param <*> parseLimits)
      (fmap SerialList . scottyAddrsTxs)
      toEncoding
      toJSON
    pathCompact
      (GetAddrTxsFull <$> paramLazy <*> parseLimits)
      (fmap SerialList . scottyAddrTxsFull)
      (list (marshalEncoding net) . (.get))
      (json_list (marshalValue net) . (.get))
    pathCompact
      (GetAddrsTxsFull <$> param <*> parseLimits)
      (fmap SerialList . scottyAddrsTxsFull)
      (list (marshalEncoding net) . (.get))
      (json_list (marshalValue net) . (.get))
    pathCompact
      (GetAddrsBalance <$> param)
      (fmap SerialList . scottyAddrsBalance)
      (list (marshalEncoding net) . (.get))
      (json_list (marshalValue net) . (.get))
    pathCompact
      (GetAddrsUnspent <$> param <*> parseLimits)
      (fmap SerialList . scottyAddrsUnspent)
      (list (marshalEncoding net) . (.get))
      (json_list (marshalValue net) . (.get))
    pathCompact
      (GetXPub <$> paramLazy <*> paramDef <*> paramDef)
      scottyXPub
      toEncoding
      toJSON
    pathCompact
      (GetXPubTxs <$> paramLazy <*> paramDef <*> parseLimits <*> paramDef)
      (fmap SerialList . scottyXPubTxs)
      toEncoding
      toJSON
    pathCompact
      (GetXPubTxsFull <$> paramLazy <*> paramDef <*> parseLimits <*> paramDef)
      (fmap SerialList . scottyXPubTxsFull)
      (list (marshalEncoding net) . (.get))
      (json_list (marshalValue net) . (.get))
    pathCompact
      (GetXPubBalances <$> paramLazy <*> paramDef <*> paramDef)
      (fmap SerialList . scottyXPubBalances)
      (list (marshalEncoding net) . (.get))
      (json_list (marshalValue net) . (.get))
    pathCompact
      (GetXPubUnspent <$> paramLazy <*> paramDef <*> parseLimits <*> paramDef)
      (fmap SerialList . scottyXPubUnspent)
      (list (marshalEncoding net) . (.get))
      (json_list (marshalValue net) . (.get))
    pathCompact
      (DelCachedXPub <$> paramLazy <*> paramDef)
      scottyDelXPub
      toEncoding
      toJSON
    unless noBlockchainInfo $ do
      S.post "/blockchain/multiaddr" scottyMultiAddr
      S.get "/blockchain/multiaddr" scottyMultiAddr
      S.get "/blockchain/balance" scottyShortBal
      S.post "/blockchain/balance" scottyShortBal
      S.get "/blockchain/rawaddr/:addr" scottyRawAddr
      S.get "/blockchain/address/:addr" scottyRawAddr
      S.get "/blockchain/xpub/:addr" scottyRawAddr
      S.post "/blockchain/unspent" scottyBinfoUnspent
      S.get "/blockchain/unspent" scottyBinfoUnspent
      S.get "/blockchain/rawtx/:txid" scottyBinfoTx
      S.get "/blockchain/rawblock/:block" scottyBinfoBlock
      S.get "/blockchain/latestblock" scottyBinfoLatest
      S.get "/blockchain/unconfirmed-transactions" scottyBinfoMempool
      S.get "/blockchain/block-height/:height" scottyBinfoBlockHeight
      S.get "/blockchain/blocks/:milliseconds" scottyBinfoBlocksDay
      S.get "/blockchain/export-history" scottyBinfoHistory
      S.post "/blockchain/export-history" scottyBinfoHistory
      S.get "/blockchain/q/addresstohash/:addr" scottyBinfoAddrToHash
      S.get "/blockchain/q/hashtoaddress/:hash" scottyBinfoHashToAddr
      S.get "/blockchain/q/addrpubkey/:pubkey" scottyBinfoAddrPubkey
      S.get "/blockchain/q/pubkeyaddr/:addr" scottyBinfoPubKeyAddr
      S.get "/blockchain/q/hashpubkey/:pubkey" scottyBinfoHashPubkey
      S.get "/blockchain/q/getblockcount" scottyBinfoGetBlockCount
      S.get "/blockchain/q/latesthash" scottyBinfoLatestHash
      S.get "/blockchain/q/bcperblock" scottyBinfoSubsidy
      S.get "/blockchain/q/txtotalbtcoutput/:txid" scottyBinfoTotalOut
      S.get "/blockchain/q/txtotalbtcinput/:txid" scottyBinfoTotalInput
      S.get "/blockchain/q/txfee/:txid" scottyBinfoTxFees
      S.get "/blockchain/q/txresult/:txid/:addr" scottyBinfoTxResult
      S.get "/blockchain/q/getreceivedbyaddress/:addr" scottyBinfoReceived
      S.get "/blockchain/q/getsentbyaddress/:addr" scottyBinfoSent
      S.get "/blockchain/q/addressbalance/:addr" scottyBinfoAddrBalance
      S.get "/blockchain/q/addressfirstseen/:addr" scottyFirstSeen
  where
    json_list f = toJSONList . map f
    net = store.net

pathCompact ::
  (ApiResource a b, MonadIO m) =>
  WebT m a ->
  (a -> WebT m b) ->
  (b -> Encoding) ->
  (b -> Value) ->
  S.ScottyT Except (ReaderT WebState m) ()
pathCompact parser action encJson encValue =
  pathCommon parser action encJson encValue False

pathCommon ::
  (ApiResource a b, MonadIO m) =>
  WebT m a ->
  (a -> WebT m b) ->
  (b -> Encoding) ->
  (b -> Value) ->
  Bool ->
  S.ScottyT Except (ReaderT WebState m) ()
pathCommon parser action encJson encValue pretty =
  S.addroute (resourceMethod proxy) (capturePath proxy) $ do
    setHeaders
    proto <- setupContentType pretty
    apiRes <- parser
    res <- action apiRes
    S.raw $ protoSerial proto encJson encValue res
  where
    toProxy :: WebT m a -> Proxy a
    toProxy = const Proxy
    proxy = toProxy parser

streamEncoding :: (Monad m) => Encoding -> WebT m ()
streamEncoding e = do
  S.setHeader "Content-Type" "application/json; charset=utf-8"
  S.raw (encodingToLazyByteString e)

protoSerial ::
  (Serial a) =>
  SerialAs ->
  (a -> Encoding) ->
  (a -> Value) ->
  a ->
  L.ByteString
protoSerial SerialAsBinary _ _ = runPutL . serialize
protoSerial SerialAsJSON f _ = encodingToLazyByteString . f
protoSerial SerialAsPrettyJSON _ g =
  encodePretty' defConfig {confTrailingNewline = True} . g

setHeaders :: (Monad m, S.ScottyError e) => ActionT e m ()
setHeaders = S.setHeader "Access-Control-Allow-Origin" "*"

waiExcept :: Status -> Except -> Response
waiExcept s e =
  responseLBS s hs e'
  where
    hs =
      [ ("Access-Control-Allow-Origin", "*"),
        ("Content-Type", "application/json")
      ]
    e' = A.encode e

setupJSON :: (Monad m) => Bool -> ActionT Except m SerialAs
setupJSON pretty = do
  S.setHeader "Content-Type" "application/json"
  p <- S.param "pretty" `S.rescue` const (return pretty)
  return $ if p then SerialAsPrettyJSON else SerialAsJSON

setupBinary :: (Monad m) => ActionT Except m SerialAs
setupBinary = do
  S.setHeader "Content-Type" "application/octet-stream"
  return SerialAsBinary

setupContentType :: (Monad m) => Bool -> ActionT Except m SerialAs
setupContentType pretty = do
  accept <- S.header "accept"
  maybe (setupJSON pretty) setType accept
  where
    setType "application/octet-stream" = setupBinary
    setType _ = setupJSON pretty

-- GET Block / GET Blocks --

scottyBlock ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetBlock -> WebT m BlockData
scottyBlock (GetBlock h (NoTx noTx)) = do
  setMetrics (.block)
  getBlock h >>= \case
    Nothing ->
      raise ThingNotFound
    Just b -> do
      return $ pruneTx noTx b

getBlocks ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  [H.BlockHash] ->
  Bool ->
  WebT m [BlockData]
getBlocks hs notx =
  (pruneTx notx <$>) . catMaybes <$> mapM getBlock (nub hs)

scottyBlocks ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetBlocks -> WebT m [BlockData]
scottyBlocks (GetBlocks hs (NoTx notx)) = do
  setMetrics (.block)
  getBlocks hs notx

pruneTx :: Bool -> BlockData -> BlockData
pruneTx False b = b
pruneTx True BlockData {..} = BlockData {txs = take 1 txs, ..}

-- GET BlockRaw --

scottyBlockRaw ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetBlockRaw ->
  WebT m (RawResult H.Block)
scottyBlockRaw (GetBlockRaw h) = do
  setMetrics (.blockRaw)
  b <- getRawBlock h
  return $ RawResult b

getRawBlock ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  H.BlockHash ->
  WebT m H.Block
getRawBlock h = do
  b <- getBlock h >>= maybe (raise ThingNotFound) return
  lift (toRawBlock b)

toRawBlock :: (MonadUnliftIO m, StoreReadBase m) => BlockData -> m H.Block
toRawBlock b = do
  let ths = b.txs
  txs <- mapM f ths
  return H.Block {header = b.header, txs}
  where
    f x = withRunInIO $ \run ->
      unsafeInterleaveIO . run $
        getTransaction x >>= \case
          Nothing -> undefined
          Just t -> return $ transactionData t

-- GET BlockBest / BlockBestRaw --

scottyBlockBest ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetBlockBest -> WebT m BlockData
scottyBlockBest (GetBlockBest (NoTx notx)) = do
  setMetrics (.block)
  getBestBlock >>= \case
    Nothing -> raise ThingNotFound
    Just bb ->
      getBlock bb >>= \case
        Nothing -> raise ThingNotFound
        Just b -> do
          return $ pruneTx notx b

scottyBlockBestRaw ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetBlockBestRaw ->
  WebT m (RawResult H.Block)
scottyBlockBestRaw _ = do
  setMetrics (.blockRaw)
  getBestBlock >>= \case
    Nothing -> raise ThingNotFound
    Just bb -> do
      b <- getRawBlock bb
      return $ RawResult b

-- GET BlockLatest --

scottyBlockLatest ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetBlockLatest ->
  WebT m [BlockData]
scottyBlockLatest (GetBlockLatest (NoTx noTx)) = do
  setMetrics (.block)
  blocks <-
    getBestBlock
      >>= maybe
        (raise ThingNotFound)
        (go [] <=< getBlock)
  return blocks
  where
    go acc Nothing = return $ reverse acc
    go acc (Just b)
      | b.height <= 0 = return $ reverse acc
      | length acc == 99 = return . reverse $ pruneTx noTx b : acc
      | otherwise = go (pruneTx noTx b : acc) =<< getBlock b.header.prev

-- GET BlockHeight / BlockHeights / BlockHeightRaw --

scottyBlockHeight ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetBlockHeight -> WebT m [BlockData]
scottyBlockHeight (GetBlockHeight h (NoTx notx)) = do
  setMetrics (.block)
  blocks <- (`getBlocks` notx) =<< getBlocksAtHeight (fromIntegral h)
  return blocks

scottyBlockHeights ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetBlockHeights ->
  WebT m [BlockData]
scottyBlockHeights (GetBlockHeights (HeightsParam heights) (NoTx notx)) = do
  setMetrics (.block)
  bhs <- concat <$> mapM getBlocksAtHeight (fromIntegral <$> heights)
  blocks <- getBlocks bhs notx
  return blocks

scottyBlockHeightRaw ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetBlockHeightRaw ->
  WebT m (RawResultList H.Block)
scottyBlockHeightRaw (GetBlockHeightRaw h) = do
  setMetrics (.blockRaw)
  blocks <- mapM getRawBlock =<< getBlocksAtHeight (fromIntegral h)
  return $ RawResultList blocks

-- GET BlockTime / BlockTimeRaw --

scottyBlockTime ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetBlockTime ->
  WebT m BlockData
scottyBlockTime (GetBlockTime (TimeParam t) (NoTx notx)) = do
  setMetrics (.block)
  ch <- lift $ asks (.config.store.chain)
  blockAtOrBefore ch t >>= \case
    Nothing -> raise ThingNotFound
    Just b -> do
      return $ pruneTx notx b

scottyBlockMTP ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetBlockMTP ->
  WebT m BlockData
scottyBlockMTP (GetBlockMTP (TimeParam t) (NoTx notx)) = do
  setMetrics (.block)
  ch <- lift $ asks (.config.store.chain)
  blockAtOrAfterMTP ch t >>= \case
    Nothing -> raise ThingNotFound
    Just b -> do
      return $ pruneTx notx b

scottyBlockTimeRaw ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetBlockTimeRaw ->
  WebT m (RawResult H.Block)
scottyBlockTimeRaw (GetBlockTimeRaw (TimeParam t)) = do
  setMetrics (.blockRaw)
  ch <- lift $ asks (.config.store.chain)
  blockAtOrBefore ch t >>= \case
    Nothing -> raise ThingNotFound
    Just b -> do
      raw <- lift $ toRawBlock b
      return $ RawResult raw

scottyBlockMTPRaw ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetBlockMTPRaw ->
  WebT m (RawResult H.Block)
scottyBlockMTPRaw (GetBlockMTPRaw (TimeParam t)) = do
  setMetrics (.blockRaw)
  ch <- lift $ asks (.config.store.chain)
  blockAtOrAfterMTP ch t >>= \case
    Nothing -> raise ThingNotFound
    Just b -> do
      raw <- lift $ toRawBlock b
      return $ RawResult raw

-- GET Transactions --

scottyTx :: (MonadUnliftIO m, MonadLoggerIO m) => GetTx -> WebT m Transaction
scottyTx (GetTx txid) = do
  setMetrics (.tx)
  getTransaction txid >>= \case
    Nothing -> raise ThingNotFound
    Just tx -> do
      return tx

scottyTxs ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetTxs -> WebT m [Transaction]
scottyTxs (GetTxs txids) = do
  setMetrics (.tx)
  txs <- catMaybes <$> mapM f (nub txids)
  return txs
  where
    f x = lift $
      withRunInIO $ \run ->
        unsafeInterleaveIO . run $
          getTransaction x

scottyTxRaw ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetTxRaw -> WebT m (RawResult Tx)
scottyTxRaw (GetTxRaw txid) = do
  setMetrics (.txRaw)
  getTransaction txid >>= \case
    Nothing -> raise ThingNotFound
    Just tx -> do
      return $ RawResult (transactionData tx)

scottyTxsRaw ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetTxsRaw ->
  WebT m (RawResultList Tx)
scottyTxsRaw (GetTxsRaw txids) = do
  setMetrics (.txRaw)
  txs <- catMaybes <$> mapM f (nub txids)
  return $ RawResultList $ transactionData <$> txs
  where
    f x = lift $
      withRunInIO $ \run ->
        unsafeInterleaveIO . run $
          getTransaction x

getTxsBlock ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  H.BlockHash ->
  WebT m [Transaction]
getTxsBlock h =
  getBlock h >>= \case
    Nothing -> raise ThingNotFound
    Just b -> do
      txs <- mapM f b.txs
      return txs
  where
    f x = lift $
      withRunInIO $ \run ->
        unsafeInterleaveIO . run $
          getTransaction x >>= \case
            Nothing -> undefined
            Just t -> return t

scottyTxsBlock ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetTxsBlock ->
  WebT m [Transaction]
scottyTxsBlock (GetTxsBlock h) = do
  setMetrics (.txBlock)
  txs <- getTxsBlock h
  return txs

scottyTxsBlockRaw ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetTxsBlockRaw ->
  WebT m (RawResultList Tx)
scottyTxsBlockRaw (GetTxsBlockRaw h) = do
  setMetrics (.txBlockRaw)
  txs <- fmap transactionData <$> getTxsBlock h
  return $ RawResultList txs

-- GET TransactionAfterHeight --

scottyTxAfter ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetTxAfter ->
  WebT m (GenericResult (Maybe Bool))
scottyTxAfter (GetTxAfter txid height) = do
  setMetrics (.txAfter)
  (result, count) <- cbAfterHeight (fromIntegral height) txid
  return $ GenericResult result

-- | Check if any of the ancestors of this transaction is a coinbase after the
-- specified height. Returns 'Nothing' if answer cannot be computed before
-- hitting limits.
cbAfterHeight ::
  (MonadIO m, StoreReadBase m) =>
  H.BlockHeight ->
  TxHash ->
  m (Maybe Bool, Int)
cbAfterHeight height txid =
  inputs n HashSet.empty HashSet.empty [txid]
  where
    n = 10000
    inputs 0 _ _ [] = return (Nothing, 10000)
    inputs i is ns [] =
      let is' = HashSet.union is ns
          ns' = HashSet.empty
          ts = HashSet.toList (HashSet.difference ns is)
       in case ts of
            [] -> return (Just False, n - i)
            _ -> inputs i is' ns' ts
    inputs i is ns (t : ts) =
      getTransaction t >>= \case
        Nothing -> return (Nothing, n - i)
        Just tx
          | height_check tx ->
              if cb_check tx
                then return (Just True, n - i + 1)
                else
                  let ns' = HashSet.union (ins tx) ns
                   in inputs (i - 1) is ns' ts
          | otherwise -> inputs (i - 1) is ns ts
    cb_check = any isCoinbase . (.inputs)
    ins = HashSet.fromList . map (.outpoint.hash) . (.inputs)
    height_check tx =
      case tx.block of
        BlockRef h _ -> h > height
        MemRef _ -> True

-- POST Transaction --

scottyPostTx :: (MonadUnliftIO m, MonadLoggerIO m) => PostTx -> WebT m TxId
scottyPostTx (PostTx tx) = do
  setMetrics (.txPost)
  lift (asks (.config)) >>= \cfg ->
    lift (publishTx cfg tx) >>= \case
      Right () -> return (TxId (txHash tx))
      Left e@(PubReject _) -> raise $ UserError (show e)
      _ -> raise ServerError

-- | Publish a new transaction to the network.
publishTx ::
  (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m) =>
  WebConfig ->
  Tx ->
  m (Either PubExcept ())
publishTx cfg tx =
  withSubscription pub $ \s ->
    getTransaction (txHash tx) >>= \case
      Just _ -> return $ Right ()
      Nothing -> go s
  where
    pub = cfg.store.pub
    mgr = cfg.store.peerMgr
    net = cfg.store.net
    go s =
      getPeers mgr >>= \case
        [] -> return $ Left PubNoPeers
        OnlinePeer {mailbox = p} : _ -> do
          MTx tx `sendMessage` p
          let v =
                if net.segWit
                  then InvWitnessTx
                  else InvTx
          sendMessage
            (MGetData (GetData [InvVector v (txHash tx).get]))
            p
          f p s
    t = 5 * 1000 * 1000
    f p s
      | cfg.noMempool = return $ Right ()
      | otherwise =
          liftIO (UnliftIO.timeout t (g p s)) >>= \case
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
scottyMempool (GetMempool limitM (OffsetParam o)) = do
  setMetrics (.mempool)
  WebLimits {..} <- lift $ asks (.config.limits)
  let wl' = WebLimits {maxItemCount = 0, ..}
      l = Limits (validateLimit wl' False limitM) (fromIntegral o) Nothing
  ths <- map snd . applyLimits l <$> getMempool
  return ths

webSocketEvents :: WebState -> Middleware
webSocketEvents s =
  websocketsOr defaultConnectionOptions events
  where
    pub = s.config.store.pub
    gauge = (.events) <$> s.metrics
    events pending = withSubscription pub $ \sub -> do
      let path = requestPath $ pendingRequest pending
      if path == "/events"
        then do
          conn <- acceptRequest pending
          forever $
            receiveEvent sub >>= \case
              Nothing -> return ()
              Just event -> sendTextData conn (A.encode event)
        else
          rejectRequestWith
            pending
            WebSockets.defaultRejectRequest
              { WebSockets.rejectBody =
                  L.toStrict $ A.encode ThingNotFound,
                WebSockets.rejectCode =
                  404,
                WebSockets.rejectMessage =
                  "Not Found",
                WebSockets.rejectHeaders =
                  [("Content-Type", "application/json")]
              }

scottyEvents :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyEvents =
  withGaugeIncrease (.events) $ do
    setHeaders
    proto <- setupContentType False
    pub <- lift $ asks (.config.store.pub)
    S.stream $ \io flush' ->
      withSubscription pub $ \sub ->
        forever $ do
          flush'
          receiveEvent sub >>= \case
            Nothing -> return ()
            Just msg -> io (serial proto msg)
  where
    serial proto e =
      lazyByteString $
        protoSerial proto toEncoding toJSON e <> newLine proto
    newLine SerialAsBinary = mempty
    newLine SerialAsJSON = "\n"
    newLine SerialAsPrettyJSON = mempty

receiveEvent :: Inbox StoreEvent -> IO (Maybe Event)
receiveEvent sub =
  go <$> receive sub
  where
    go = \case
      StoreBestBlock b -> Just (EventBlock b)
      StoreMempoolNew t -> Just (EventTx t)
      StoreMempoolDelete t -> Just (EventTx t)
      _ -> Nothing

-- GET Address Transactions --

scottyAddrTxs ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetAddrTxs -> WebT m [TxRef]
scottyAddrTxs (GetAddrTxs addr pLimits) = do
  setMetrics (.addressTx)
  txs <- getAddressTxs addr =<< paramToLimits False pLimits
  return txs

scottyAddrsTxs ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetAddrsTxs -> WebT m [TxRef]
scottyAddrsTxs (GetAddrsTxs addrs pLimits) = do
  setMetrics (.addressTx)
  txs <- getAddressesTxs addrs =<< paramToLimits False pLimits
  return txs

scottyAddrTxsFull ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetAddrTxsFull ->
  WebT m [Transaction]
scottyAddrTxsFull (GetAddrTxsFull addr pLimits) = do
  setMetrics (.addressTxFull)
  txs <- getAddressTxs addr =<< paramToLimits True pLimits
  ts <- catMaybes <$> mapM (getTransaction . (.txid)) txs
  return ts

scottyAddrsTxsFull ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetAddrsTxsFull ->
  WebT m [Transaction]
scottyAddrsTxsFull (GetAddrsTxsFull addrs pLimits) = do
  setMetrics (.addressTxFull)
  txs <- getAddressesTxs addrs =<< paramToLimits True pLimits
  ts <- catMaybes <$> mapM (getTransaction . (.txid)) txs
  return ts

scottyAddrBalance ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetAddrBalance ->
  WebT m Balance
scottyAddrBalance (GetAddrBalance addr) = do
  setMetrics (.addressBalance)
  getDefaultBalance addr

scottyAddrsBalance ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetAddrsBalance -> WebT m [Balance]
scottyAddrsBalance (GetAddrsBalance addrs) = do
  setMetrics (.addressBalance)
  balances <- getBalances addrs
  return balances

scottyAddrUnspent ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetAddrUnspent -> WebT m [Unspent]
scottyAddrUnspent (GetAddrUnspent addr pLimits) = do
  setMetrics (.addressUnspent)
  unspents <- getAddressUnspents addr =<< paramToLimits False pLimits
  return unspents

scottyAddrsUnspent ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetAddrsUnspent -> WebT m [Unspent]
scottyAddrsUnspent (GetAddrsUnspent addrs pLimits) = do
  setMetrics (.addressUnspent)
  unspents <- getAddressesUnspents addrs =<< paramToLimits False pLimits
  return unspents

-- GET XPubs --

scottyXPub ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetXPub -> WebT m XPubSummary
scottyXPub (GetXPub xpub deriv (NoCache noCache)) = do
  setMetrics (.xpub)
  let xspec = XPubSpec xpub deriv
  xbals <- lift . runNoCache noCache $ xPubBals xspec
  return $ xPubSummary xspec xbals

scottyDelXPub ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  DelCachedXPub ->
  WebT m (GenericResult Bool)
scottyDelXPub (DelCachedXPub xpub deriv) = do
  setMetrics (.xpubDelete)
  let xspec = XPubSpec xpub deriv
  cacheM <- lift $ asks (.config.store.cache)
  n <- lift $ withCache cacheM (cacheDelXPubs [xspec])
  return (GenericResult (n > 0))

getXPubTxs ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  XPubKey ->
  DeriveType ->
  LimitsParam ->
  Bool ->
  WebT m [TxRef]
getXPubTxs xpub deriv plimits nocache = do
  limits <- paramToLimits False plimits
  let xspec = XPubSpec xpub deriv
  xbals <- xPubBals xspec
  lift . runNoCache nocache $ xPubTxs xspec xbals limits

scottyXPubTxs ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetXPubTxs -> WebT m [TxRef]
scottyXPubTxs (GetXPubTxs xpub deriv plimits (NoCache nocache)) = do
  setMetrics (.xpubTx)
  txs <- getXPubTxs xpub deriv plimits nocache
  return txs

scottyXPubTxsFull ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetXPubTxsFull ->
  WebT m [Transaction]
scottyXPubTxsFull (GetXPubTxsFull xpub deriv plimits (NoCache nocache)) = do
  setMetrics (.xpubTxFull)
  refs <- getXPubTxs xpub deriv plimits nocache
  txs <-
    fmap catMaybes $
      lift . runNoCache nocache $
        mapM (getTransaction . (.txid)) refs
  return txs

scottyXPubBalances ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetXPubBalances -> WebT m [XPubBal]
scottyXPubBalances (GetXPubBalances xpub deriv (NoCache noCache)) = do
  setMetrics (.xpubBalance)
  balances <- lift (runNoCache noCache (xPubBals spec))
  return balances
  where
    spec = XPubSpec xpub deriv

scottyXPubUnspent ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetXPubUnspent ->
  WebT m [XPubUnspent]
scottyXPubUnspent (GetXPubUnspent xpub deriv pLimits (NoCache noCache)) = do
  setMetrics (.xpubUnspent)
  limits <- paramToLimits False pLimits
  let xspec = XPubSpec xpub deriv
  xbals <- xPubBals xspec
  unspents <- lift . runNoCache noCache $ xPubUnspents xspec xbals limits
  return unspents

---------------------------------------
-- Blockchain.info API Compatibility --
---------------------------------------

netBinfoSymbol :: Network -> BinfoSymbol
netBinfoSymbol net
  | net == btc =
      BinfoSymbol
        { code = "BTC",
          symbol = "BTC",
          name = "Bitcoin",
          conversion = 100 * 1000 * 1000,
          after = True,
          local = False
        }
  | net == bch =
      BinfoSymbol
        { code = "BCH",
          symbol = "BCH",
          name = "Bitcoin Cash",
          conversion = 100 * 1000 * 1000,
          after = True,
          local = False
        }
  | otherwise =
      BinfoSymbol
        { code = "XTS",
          symbol = "¤",
          name = "Test",
          conversion = 100 * 1000 * 1000,
          after = False,
          local = False
        }

binfoTickerToSymbol :: Text -> BinfoTicker -> BinfoSymbol
binfoTickerToSymbol code BinfoTicker {..} =
  BinfoSymbol
    { code,
      symbol,
      name,
      conversion = 100 * 1000 * 1000 / fifteen, -- sat/usd
      after = False,
      local = True
    }
  where
    name = case code of
      "EUR" -> "Euro"
      "USD" -> "U.S. dollar"
      "GBP" -> "British pound"
      x -> x

getBinfoAddrsParam ::
  (MonadIO m) =>
  Text ->
  WebT m (HashSet BinfoAddr)
getBinfoAddrsParam name = do
  net <- lift $ asks (.config.store.net)
  ctx <- lift $ asks (.config.store.ctx)
  p <- S.param (cs name) `S.rescue` const (return "")
  if T.null p
    then return HashSet.empty
    else case parseBinfoAddr net ctx p of
      Nothing -> raise (UserError "invalid address")
      Just xs -> return $ HashSet.fromList xs

getBinfoActive ::
  (MonadIO m) =>
  WebT m (HashSet XPubSpec, HashSet Address)
getBinfoActive = do
  active <- getBinfoAddrsParam "active"
  p2sh <- getBinfoAddrsParam "activeP2SH"
  bech32 <- getBinfoAddrsParam "activeBech32"
  let xspec d b = (`XPubSpec` d) <$> xpub b
      xspecs =
        HashSet.fromList $
          concat
            [ mapMaybe (xspec DeriveNormal) (HashSet.toList active),
              mapMaybe (xspec DeriveP2SH) (HashSet.toList p2sh),
              mapMaybe (xspec DeriveP2WPKH) (HashSet.toList bech32)
            ]
      addrs = HashSet.fromList $ mapMaybe addr $ HashSet.toList active
  return (xspecs, addrs)
  where
    addr (BinfoAddr a) = Just a
    addr (BinfoXpub _) = Nothing
    xpub (BinfoXpub x) = Just x
    xpub (BinfoAddr _) = Nothing

getNumTxId :: (MonadIO m) => WebT m Bool
getNumTxId = fmap not $ S.param "txidindex" `S.rescue` const (return False)

getChainHeight :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m H.BlockHeight
getChainHeight = do
  ch <- lift $ asks (.config.store.chain)
  (.height) <$> chainGetBest ch

scottyBinfoUnspent :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoUnspent = do
  setMetrics (.binfoUnspent)
  (xspecs, addrs) <- getBinfoActive
  numtxid <- getNumTxId
  limit <- get_limit
  min_conf <- get_min_conf
  net <- lift $ asks (.config.store.net)
  ctx <- lift $ asks (.config.store.ctx)
  height <- getChainHeight
  let mn u = min_conf > u.confirmations
  xbals <- lift $ getXBals xspecs
  bus <-
    lift . runConduit $
      getBinfoUnspents numtxid height xbals xspecs addrs
        .| (dropWhileC mn >> takeC limit .| sinkList)
  setHeaders
  streamEncoding (marshalEncoding (net, ctx) (BinfoUnspents bus))
  where
    get_limit = fmap (min 1000) $ S.param "limit" `S.rescue` const (return 250)
    get_min_conf = S.param "confirmations" `S.rescue` const (return 0)

getBinfoUnspents ::
  (StoreReadExtra m, MonadIO m) =>
  Bool ->
  H.BlockHeight ->
  HashMap XPubSpec [XPubBal] ->
  HashSet XPubSpec ->
  HashSet Address ->
  ConduitT () BinfoUnspent m ()
getBinfoUnspents numtxid height xbals xspecs addrs = do
  cs' <- conduits
  joinDescStreams cs' .| mapC (uncurry binfo)
  where
    binfo u xp =
      let conf = case u.block of
            MemRef _ -> 0
            BlockRef h _ -> height - h + 1
       in BinfoUnspent
            { txid = u.outpoint.hash,
              index = u.outpoint.index,
              script = u.script,
              value = u.value,
              confirmations = fromIntegral conf,
              txidx = encodeBinfoTxId numtxid u.outpoint.hash,
              xpub = xp
            }
    conduits = (<>) <$> xconduits <*> pure acounduits
    xconduits = lift $ do
      let f x (XPubUnspent u p) =
            let path = toSoft (listToPath p)
                xp = BinfoXPubPath x.key <$> path
             in (u, xp)
          g x = do
            let h l = xPubUnspents x (xBals x xbals) l
                l = def {limit = 16} :: Limits
            return $ streamThings h Nothing l .| mapC (f x)
      mapM g (HashSet.toList xspecs)
    acounduits =
      let f u = (u, Nothing)
          h a l = getAddressUnspents a l
          l = def {limit = 16} :: Limits
          g a = streamThings (h a) Nothing l .| mapC f
       in map g (HashSet.toList addrs)

getXBals ::
  (StoreReadExtra m) =>
  HashSet XPubSpec ->
  m (HashMap XPubSpec [XPubBal])
getXBals =
  fmap HashMap.fromList . mapM f . HashSet.toList
  where
    f x = (x,) . filter (not . nullBalance . (.balance)) <$> xPubBals x

xBals :: XPubSpec -> HashMap XPubSpec [XPubBal] -> [XPubBal]
xBals = HashMap.findWithDefault []

getBinfoTxs ::
  (StoreReadExtra m, MonadIO m) =>
  HashMap XPubSpec [XPubBal] -> -- xpub balances
  HashMap Address (Maybe BinfoXPubPath) -> -- address book
  HashSet XPubSpec -> -- show xpubs
  HashSet Address -> -- show addrs
  HashSet Address -> -- balance addresses
  BinfoFilter ->
  Bool -> -- numtxid
  Bool -> -- prune outputs
  Int64 -> -- starting balance
  ConduitT () BinfoTx m ()
getBinfoTxs
  xbals
  abook
  sxspecs
  saddrs
  baddrs
  bfilter
  numtxid
  prune
  bal = do
    cs' <- conduits
    joinDescStreams cs' .| go bal
    where
      sxspecs_ls = HashSet.toList sxspecs
      saddrs_ls = HashSet.toList saddrs
      conduits =
        (<>)
          <$> mapM xpub_c sxspecs_ls
          <*> pure (map addr_c saddrs_ls)
      xpub_c x = do
        let f l = xPubTxs x (xBals x xbals) l
            l = def {limit = 16} :: Limits
        lift . return $
          streamThings f (Just (.txid)) l
      addr_c a = do
        let f l = getAddressTxs a l
            l = def {limit = 16} :: Limits
        streamThings f (Just (.txid)) l
      binfo_tx = toBinfoTx numtxid abook prune
      compute_bal_change t =
        let ins = map (.output) t.inputs
            out = t.outputs
            f b BinfoTxOutput {..} =
              let val = fromIntegral value
               in case address of
                    Nothing -> 0
                    Just a
                      | a `HashSet.member` baddrs ->
                          if b then val else negate val
                      | otherwise -> 0
         in sum $ map (f False) ins <> map (f True) out
      go b =
        await >>= \case
          Nothing -> return ()
          Just (TxRef _ t) ->
            lift (getTransaction t) >>= \case
              Nothing -> go b
              Just x -> do
                let a = binfo_tx b x
                    b' = b - compute_bal_change a
                    c = isJust a.blockHeight
                    Just (d, _) = a.balance
                    r = d + fromIntegral a.fee
                case bfilter of
                  BinfoFilterAll ->
                    yield a >> go b'
                  BinfoFilterSent
                    | 0 > r -> yield a >> go b'
                    | otherwise -> go b'
                  BinfoFilterReceived
                    | r > 0 -> yield a >> go b'
                    | otherwise -> go b'
                  BinfoFilterMoved
                    | r == 0 -> yield a >> go b'
                    | otherwise -> go b'
                  BinfoFilterConfirmed
                    | c -> yield a >> go b'
                    | otherwise -> go b'
                  BinfoFilterMempool
                    | c -> return ()
                    | otherwise -> yield a >> go b'

getCashAddr :: (Monad m) => WebT m Bool
getCashAddr = S.param "cashaddr" `S.rescue` const (return False)

getAddress :: (Monad m, MonadUnliftIO m) => TL.Text -> WebT m Address
getAddress param' = do
  txt <- S.param param'
  net <- lift $ asks (.config.store.net)
  case textToAddr net txt of
    Nothing -> raise ThingNotFound
    Just a -> return a

getBinfoAddr :: (Monad m) => TL.Text -> WebT m BinfoAddr
getBinfoAddr param' = do
  txt <- S.param param'
  net <- lift $ asks (.config.store.net)
  ctx <- lift $ asks (.config.store.ctx)
  let x =
        BinfoAddr
          <$> textToAddr net txt
          <|> BinfoXpub <$> xPubImport net ctx txt
  maybe S.next return x

scottyBinfoHistory :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoHistory = do
  setMetrics (.binfoExportHistory)
  (xspecs, addrs) <- getBinfoActive
  (startM, endM) <- get_dates
  (code, price') <- getPrice
  xbals <- getXBals xspecs
  let xaddrs = HashSet.fromList $ concatMap (map get_addr) (HashMap.elems xbals)
      aaddrs = xaddrs <> addrs
      cur = price'.fifteen
      cs' = conduits (HashMap.toList xbals) addrs endM
  txs <-
    lift $
      runConduit $
        joinDescStreams cs'
          .| takeWhileC (is_newer startM)
          .| concatMapMC get_transaction
          .| sinkList
  let times = map (\Transaction {..} -> timestamp) txs
  net <- lift $ asks (.config.store.net)
  url <- lift $ asks (.config.priceHistoryURL)
  session <- lift $ asks (.session)
  rates <- map (.price) <$> lift (getRates net session url code times)
  let hs = zipWith (convert cur aaddrs) txs (rates <> repeat 0.0)
  setHeaders
  streamEncoding $ toEncoding hs
  where
    is_newer
      (Just BlockData {height = bh})
      TxRef {block = BlockRef {height = th}} =
        bh <= th
    is_newer Nothing TxRef {} = True
    get_addr = (.balance.address)
    get_transaction TxRef {txid = h} =
      getTransaction h
    convert cur addrs tx rate =
      let ins = tx.inputs
          outs = tx.outputs
          fins = filter (input_addr addrs) ins
          fouts = filter (output_addr addrs) outs
          vin = fromIntegral . sum $ map (.value) fins
          vout = fromIntegral . sum $ map (.value) fouts
          fee = tx.fee
          v = vout - vin
          t = tx.timestamp
          h = txHash $ transactionData tx
       in toBinfoHistory v t rate cur fee h
    input_addr addrs' StoreInput {address = Just a} =
      a `HashSet.member` addrs'
    input_addr _ _ = False
    output_addr addrs' StoreOutput {address = Just a} =
      a `HashSet.member` addrs'
    output_addr _ _ = False
    get_dates = do
      BinfoDate start <- S.param "start"
      BinfoDate end' <- S.param "end"
      let end = end' + 24 * 60 * 60
      ch <- lift $ asks (.config.store.chain)
      startM <- blockAtOrAfter ch start
      endM <- blockAtOrBefore ch end
      return (startM, endM)
    conduits xpubs addrs endM =
      map (uncurry (xpub_c endM)) xpubs
        <> map (addr_c endM) (HashSet.toList addrs)
    addr_c endM a = do
      let f l = getAddressTxs a l
          l = def {limit = 16, start = AtBlock . (.height) <$> endM} :: Limits
      streamThings f (Just (.txid)) l
    xpub_c endM x bs = do
      let f l = xPubTxs x bs l
          l = def {limit = 16, start = AtBlock . (.height) <$> endM} :: Limits
      streamThings f (Just (.txid)) l

getPrice :: (MonadIO m) => WebT m (Text, BinfoTicker)
getPrice = do
  code <- T.toUpper <$> S.param "currency" `S.rescue` const (return "USD")
  ticker <- lift $ asks (.ticker)
  prices <- readTVarIO ticker
  case HashMap.lookup code prices of
    Nothing -> return (code, def)
    Just p -> return (code, p)

getSymbol :: (MonadIO m) => WebT m BinfoSymbol
getSymbol = uncurry binfoTickerToSymbol <$> getPrice

scottyBinfoBlocksDay :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoBlocksDay = do
  setMetrics (.binfoBlock)
  t <- min h . (`div` 1000) <$> S.param "milliseconds"
  ch <- lift $ asks (.config.store.chain)
  m <- blockAtOrBefore ch t
  bs <- go (d t) m
  streamEncoding $ toEncoding $ map toBinfoBlockInfo bs
  where
    h = fromIntegral (maxBound :: H.Timestamp)
    d = subtract (24 * 3600)
    go _ Nothing = return []
    go t (Just b)
      | b.header.timestamp <= fromIntegral t =
          return []
      | otherwise = do
          b' <- getBlock b.header.prev
          (b :) <$> go t b'

scottyMultiAddr :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyMultiAddr = do
  setMetrics (.binfoMultiaddr)
  (addrs', _, saddrs, sxpubs, xspecs) <- get_addrs
  numtxid <- getNumTxId
  cashaddr <- getCashAddr
  local' <- getSymbol
  offset <- getBinfoOffset
  n <- getBinfoCount "n"
  prune <- get_prune
  fltr <- get_filter
  xbals <- getXBals xspecs
  xtxns <- get_xpub_tx_count xbals xspecs
  let sxbals = only_show_xbals sxpubs xbals
      xabals = compute_xabals xbals
      addrs = addrs' `HashSet.difference` HashMap.keysSet xabals
  abals <- get_abals addrs
  let sxspecs = only_show_xspecs sxpubs xspecs
      sxabals = compute_xabals sxbals
      sabals = only_show_abals saddrs abals
      sallbals = sabals <> sxabals
      sbal = compute_bal sallbals
      allbals = abals <> xabals
      abook = compute_abook addrs xbals
      sxaddrs = compute_xaddrs sxbals
      salladdrs = saddrs <> sxaddrs
      bal = compute_bal allbals
      ibal = fromIntegral sbal
  ftxs <-
    lift . runConduit $
      getBinfoTxs
        xbals
        abook
        sxspecs
        saddrs
        salladdrs
        fltr
        numtxid
        prune
        ibal
        .| (dropC offset >> takeC n .| sinkList)
  net <- lift $ asks (.config.store.net)
  ctx <- lift $ asks (.config.store.ctx)
  best <- get_best_block
  peers <- get_peers
  let baddrs = toBinfoAddrs sabals sxbals xtxns
      abaddrs = toBinfoAddrs abals xbals xtxns
      recv = sum $ map (.received) abaddrs
      sent' = sum $ map (.sent) abaddrs
      txn = fromIntegral $ length ftxs
      wallet =
        BinfoWallet
          { balance = bal,
            txs = txn,
            filtered = txn,
            received = recv,
            sent = sent'
          }
      coin = netBinfoSymbol net
  let block =
        BinfoBlockInfo
          { hash = H.headerHash best.header,
            height = best.height,
            timestamp = best.header.timestamp,
            index = best.height
          }
  let info =
        BinfoInfo
          { connected = peers,
            conversion = 100 * 1000 * 1000,
            fiat = local',
            crypto = coin,
            head = block
          }
  let multiaddr =
        BinfoMultiAddr
          { addresses = baddrs,
            wallet = wallet,
            txs = ftxs,
            info = info,
            recommendFee = True,
            cashAddr = cashaddr
          }
  setHeaders
  streamEncoding $ marshalEncoding (net, ctx) multiaddr
  where
    get_xpub_tx_count xbals =
      fmap HashMap.fromList
        . mapM
          ( \x ->
              (x,)
                . fromIntegral
                <$> xPubTxCount x (xBals x xbals)
          )
        . HashSet.toList
    get_filter =
      S.param "filter" `S.rescue` const (return BinfoFilterAll)
    get_best_block =
      getBestBlock >>= \case
        Nothing -> raise ThingNotFound
        Just bh ->
          getBlock bh >>= \case
            Nothing -> raise ThingNotFound
            Just b -> return b
    get_prune =
      fmap not $
        S.param "no_compact"
          `S.rescue` const (return False)
    only_show_xbals sxpubs =
      HashMap.filterWithKey (\k _ -> k.key `HashSet.member` sxpubs)
    only_show_xspecs sxpubs =
      HashSet.filter (\k -> k.key `HashSet.member` sxpubs)
    only_show_abals saddrs =
      HashMap.filterWithKey (\k _ -> k `HashSet.member` saddrs)
    addr (BinfoAddr a) = Just a
    addr (BinfoXpub _) = Nothing
    xpub (BinfoXpub x) = Just x
    xpub (BinfoAddr _) = Nothing
    get_addrs = do
      (xspecs, addrs) <- getBinfoActive
      sh <- getBinfoAddrsParam "onlyShow"
      let xpubs = HashSet.map (.key) xspecs
          actives =
            HashSet.map BinfoAddr addrs
              <> HashSet.map BinfoXpub xpubs
          sh' = if HashSet.null sh then actives else sh
          saddrs = HashSet.fromList $ mapMaybe addr $ HashSet.toList sh'
          sxpubs = HashSet.fromList $ mapMaybe xpub $ HashSet.toList sh'
      return (addrs, xpubs, saddrs, sxpubs, xspecs)
    get_abals =
      let f b = (b.address, b)
          g = HashMap.fromList . map f
       in fmap g . getBalances . HashSet.toList
    get_peers = do
      ps <- lift $ getPeersInformation =<< asks (.config.store.peerMgr)
      return (fromIntegral (length ps))
    compute_xabals =
      let f b = (b.balance.address, b.balance)
       in HashMap.fromList . concatMap (map f) . HashMap.elems
    compute_bal =
      let f b = b.confirmed + b.unconfirmed
       in sum . map f . HashMap.elems
    compute_abook addrs xbals =
      let f xs xb =
            let a = xb.balance.address
                e = error "lions and tigers and bears"
                s = toSoft (listToPath xb.path)
             in (a, Just (BinfoXPubPath xs.key (fromMaybe e s)))
          amap =
            HashMap.map (const Nothing) $
              HashSet.toMap addrs
          xmap =
            HashMap.fromList
              . concatMap (uncurry (map . f))
              $ HashMap.toList xbals
       in amap <> xmap
    compute_xaddrs =
      let f = map (.balance.address)
       in HashSet.fromList . concatMap f . HashMap.elems

getBinfoCount :: (MonadUnliftIO m, MonadLoggerIO m) => TL.Text -> WebT m Int
getBinfoCount str = do
  d <- lift $ asks (.config.limits.defItemCount)
  x <- lift $ asks (.config.limits.maxFullItemCount)
  i <- min x <$> (S.param str `S.rescue` const (return d))
  return (fromIntegral i :: Int)

getBinfoOffset ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  WebT m Int
getBinfoOffset = do
  x <- lift $ asks (.config.limits.maxOffset)
  o <- S.param "offset" `S.rescue` const (return 0)
  when (o > x) $
    raise $
      UserError $
        "offset exceeded: " <> show o <> " > " <> show x
  return (fromIntegral o :: Int)

scottyRawAddr :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyRawAddr = do
  setMetrics (.binfoAddressRaw)
  getBinfoAddr "addr" >>= \case
    BinfoAddr addr -> do_addr addr
    BinfoXpub xpub -> do_xpub xpub
  where
    do_xpub xpub = do
      numtxid <- getNumTxId
      derive <- S.param "derive" `S.rescue` const (return DeriveNormal)
      let xspec = XPubSpec xpub derive
      n <- getBinfoCount "limit"
      off <- getBinfoOffset
      xbals <- getXBals $ HashSet.singleton xspec
      net <- lift $ asks (.config.store.net)
      let summary = xPubSummary xspec (xBals xspec xbals)
          abook = compute_abook xpub (xBals xspec xbals)
          xspecs = HashSet.singleton xspec
          saddrs = HashSet.empty
          baddrs = HashMap.keysSet abook
          bfilter = BinfoFilterAll
          amnt = summary.confirmed + summary.unconfirmed
      txs <-
        lift $
          runConduit $
            getBinfoTxs
              xbals
              abook
              xspecs
              saddrs
              baddrs
              bfilter
              numtxid
              False
              (fromIntegral amnt)
              .| (dropC off >> takeC n .| sinkList)
      let ra =
            BinfoRawAddr
              { address = BinfoXpub xpub,
                balance = amnt,
                ntx = fromIntegral $ length txs,
                utxo = summary.utxo,
                received = summary.received,
                sent = fromIntegral summary.received - fromIntegral amnt,
                txs = txs
              }
      setHeaders
      ctx <- asks (.config.store.ctx)
      streamEncoding $ marshalEncoding (net, ctx) ra
    compute_abook xpub xbals =
      let f xb =
            let a = xb.balance.address
                e = error "black hole swallows all your code"
                s = toSoft $ listToPath xb.path
                m = fromMaybe e s
             in (a, Just (BinfoXPubPath xpub m))
       in HashMap.fromList $ map f xbals
    do_addr addr = do
      numtxid <- getNumTxId
      n <- getBinfoCount "limit"
      off <- getBinfoOffset
      bal <- fromMaybe (zeroBalance addr) <$> getBalance addr
      net <- lift $ asks (.config.store.net)
      let abook = HashMap.singleton addr Nothing
          xspecs = HashSet.empty
          saddrs = HashSet.singleton addr
          bfilter = BinfoFilterAll
          amnt = bal.confirmed + bal.unconfirmed
      txs <-
        lift $
          runConduit $
            getBinfoTxs
              HashMap.empty
              abook
              xspecs
              saddrs
              saddrs
              bfilter
              numtxid
              False
              (fromIntegral amnt)
              .| (dropC off >> takeC n .| sinkList)
      let ra =
            BinfoRawAddr
              { address = BinfoAddr addr,
                balance = amnt,
                ntx = bal.txs,
                utxo = bal.utxo,
                received = bal.received,
                sent = fromIntegral bal.received - fromIntegral amnt,
                txs = txs
              }
      setHeaders
      ctx <- asks (.config.store.ctx)
      streamEncoding $ marshalEncoding (net, ctx) ra

scottyBinfoReceived :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoReceived = do
  setMetrics (.binfoQgetreceivedbyaddress)
  a <- getAddress "addr"
  b <- fromMaybe (zeroBalance a) <$> getBalance a
  setHeaders
  S.text $ cs $ show b.received

scottyBinfoSent :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoSent = do
  setMetrics (.binfoQgetsentbyaddress)
  a <- getAddress "addr"
  b <- fromMaybe (zeroBalance a) <$> getBalance a
  setHeaders
  S.text $ cs $ show $ b.received - b.confirmed - b.unconfirmed

scottyBinfoAddrBalance :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoAddrBalance = do
  setMetrics (.binfoQaddressbalance)
  a <- getAddress "addr"
  b <- fromMaybe (zeroBalance a) <$> getBalance a
  setHeaders
  S.text $ cs $ show $ b.confirmed + b.unconfirmed

scottyFirstSeen :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyFirstSeen = do
  setMetrics (.binfoQaddressfirstseen)
  a <- getAddress "addr"
  ch <- lift $ asks (.config.store.chain)
  bb <- chainGetBest ch
  let top = bb.height
      bot = 0
  i <- go ch bb a bot top
  setHeaders
  S.text $ cs $ show i
  where
    go ch bb a bot top = do
      let mid = bot + (top - bot) `div` 2
          n = top - bot < 2
      x <- hasone a bot
      y <- hasone a mid
      z <- hasone a top
      if
        | x -> getblocktime ch bb bot
        | n -> getblocktime ch bb top
        | y -> go ch bb a bot mid
        | z -> go ch bb a mid top
        | otherwise -> return 0
    getblocktime ch bb h =
      (.header.timestamp) . fromJust <$> chainGetAncestor h bb ch
    hasone a h = do
      let l = Limits 1 0 (Just (AtBlock h))
      not . null <$> getAddressTxs a l

scottyShortBal :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyShortBal = do
  setMetrics (.binfoBalance)
  (xspecs, addrs) <- getBinfoActive
  cashaddr <- getCashAddr
  net <- lift $ asks (.config.store.net)
  abals <-
    catMaybes
      <$> mapM
        (get_addr_balance net cashaddr)
        (HashSet.toList addrs)
  xbals <- mapM (get_xspec_balance net) (HashSet.toList xspecs)
  let res = HashMap.fromList (abals <> xbals)
  setHeaders
  streamEncoding $ toEncoding res
  where
    to_short_bal bal =
      BinfoShortBal
        { final = bal.confirmed + bal.unconfirmed,
          ntx = bal.txs,
          received = bal.received
        }
    get_addr_balance net cashaddr a =
      let net' =
            if
              | cashaddr -> net
              | net == bch -> btc
              | net == bchTest -> btcTest
              | net == bchTest4 -> btcTest
              | otherwise -> net
       in case addrToText net' a of
            Nothing -> return Nothing
            Just a' ->
              getBalance a >>= \case
                Nothing -> return $ Just (a', to_short_bal (zeroBalance a))
                Just b -> return $ Just (a', to_short_bal b)
    is_ext XPubBal {path = 0 : _} = True
    is_ext _ = False
    get_xspec_balance net xpub = do
      xbals <- xPubBals xpub
      xts <- xPubTxCount xpub xbals
      let val = sum $ map (.balance.confirmed) xbals
          zro = sum $ map (.balance.unconfirmed) xbals
          exs = filter is_ext xbals
          rcv = sum $ map (.balance.received) exs
          sbl =
            BinfoShortBal
              { final = val + zro,
                ntx = fromIntegral xts,
                received = rcv
              }
      ctx <- asks (.config.store.ctx)
      return (xPubExport net ctx xpub.key, sbl)

getBinfoHex :: (Monad m) => WebT m Bool
getBinfoHex =
  (== ("hex" :: Text))
    <$> S.param "format" `S.rescue` const (return "json")

scottyBinfoBlockHeight :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoBlockHeight = do
  numtxid <- getNumTxId
  height <- S.param "height"
  setMetrics (.binfoBlockHeight)
  block_hashes <- getBlocksAtHeight height
  block_headers <- catMaybes <$> mapM getBlock block_hashes
  next_block_hashes <- getBlocksAtHeight (height + 1)
  next_block_headers <- catMaybes <$> mapM getBlock next_block_hashes
  binfo_blocks <-
    mapM (get_binfo_blocks numtxid next_block_headers) block_headers
  setHeaders
  net <- lift $ asks (.config.store.net)
  ctx <- lift $ asks (.config.store.ctx)
  streamEncoding $ marshalEncoding (net, ctx) binfo_blocks
  where
    get_tx th =
      withRunInIO $ \run ->
        unsafeInterleaveIO $
          run $
            fromJust <$> getTransaction th
    get_binfo_blocks numtxid next_block_headers block_header = do
      let my_hash = H.headerHash block_header.header
          get_prev = (.header.prev)
          get_hash = H.headerHash . (.header)
      txs <- lift $ mapM get_tx block_header.txs
      let next_blocks =
            map get_hash $
              filter
                ((== my_hash) . get_prev)
                next_block_headers
          binfo_txs = map (toBinfoTxSimple numtxid) txs
          binfo_block = toBinfoBlock block_header binfo_txs next_blocks
      return binfo_block

scottyBinfoLatest :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoLatest = do
  numtxid <- getNumTxId
  setMetrics (.binfoBlockLatest)
  best <- get_best_block
  streamEncoding $
    toEncoding
      BinfoHeader
        { hash = H.headerHash best.header,
          timestamp = best.header.timestamp,
          index = best.height,
          height = best.height,
          txids = map (encodeBinfoTxId numtxid) best.txs
        }
  where
    get_best_block =
      getBestBlock >>= \case
        Nothing -> raise ThingNotFound
        Just bh ->
          getBlock bh >>= \case
            Nothing -> raise ThingNotFound
            Just b -> return b

scottyBinfoBlock :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoBlock = do
  numtxid <- getNumTxId
  hex <- getBinfoHex
  setMetrics (.binfoBlockRaw)
  S.param "block" >>= \case
    BinfoBlockHash bh -> go numtxid hex bh
    BinfoBlockIndex i ->
      getBlocksAtHeight i >>= \case
        [] -> raise ThingNotFound
        bh : _ -> go numtxid hex bh
  where
    get_tx th =
      withRunInIO $ \run ->
        unsafeInterleaveIO $
          run $
            fromJust <$> getTransaction th
    go numtxid hex bh =
      getBlock bh >>= \case
        Nothing -> raise ThingNotFound
        Just b -> do
          txs <- lift $ mapM get_tx b.txs
          let my_hash = H.headerHash b.header
              get_prev = (.header.prev)
              get_hash = H.headerHash . (.header)
          nxt_headers <-
            fmap catMaybes $
              mapM getBlock
                =<< getBlocksAtHeight (b.height + 1)
          let nxt =
                map get_hash $
                  filter
                    ((== my_hash) . get_prev)
                    nxt_headers
          if hex
            then do
              let x = H.Block b.header (map transactionData txs)
              setHeaders
              S.text . encodeHexLazy . runPutL $ serialize x
            else do
              let btxs = map (toBinfoTxSimple numtxid) txs
                  y = toBinfoBlock b btxs nxt
              setHeaders
              net <- lift $ asks (.config.store.net)
              ctx <- lift $ asks (.config.store.ctx)
              streamEncoding $ marshalEncoding (net, ctx) y

getBinfoTx ::
  (MonadLoggerIO m, MonadUnliftIO m) =>
  BinfoTxId ->
  WebT m (Either Except Transaction)
getBinfoTx txid = do
  tx <- case txid of
    BinfoTxIdHash h -> maybeToList <$> getTransaction h
    BinfoTxIdIndex i -> getNumTransaction i
  case tx of
    [t] -> return $ Right t
    [] -> return $ Left ThingNotFound
    ts ->
      let tids = map (txHash . transactionData) ts
       in return $ Left (TxIndexConflict tids)

scottyBinfoTx :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoTx = do
  numtxid <- getNumTxId
  hex <- getBinfoHex
  txid <- S.param "txid"
  setMetrics (.binfoTxRaw)
  tx <-
    getBinfoTx txid >>= \case
      Right t -> return t
      Left e -> raise e
  if hex then hx tx else js numtxid tx
  where
    js numtxid t = do
      net <- lift $ asks (.config.store.net)
      ctx <- lift $ asks (.config.store.ctx)
      setHeaders
      streamEncoding $ marshalEncoding (net, ctx) $ toBinfoTxSimple numtxid t
    hx t = do
      setHeaders
      S.text . encodeHexLazy . runPutL . serialize $ transactionData t

scottyBinfoTotalOut :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoTotalOut = do
  txid <- S.param "txid"
  setMetrics (.binfoQtxtotalbtcoutput)
  tx <-
    getBinfoTx txid >>= \case
      Right t -> return t
      Left e -> raise e
  S.text $ cs $ show $ sum $ map (.value) tx.outputs

scottyBinfoTxFees :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoTxFees = do
  txid <- S.param "txid"
  setMetrics (.binfoQtxfee)
  tx <-
    getBinfoTx txid >>= \case
      Right t -> return t
      Left e -> raise e
  let i = sum $ map (.value) $ filter f tx.inputs
      o = sum $ map (.value) tx.outputs
  S.text . cs . show $ i - o
  where
    f StoreInput {} = True
    f StoreCoinbase {} = False

scottyBinfoTxResult :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoTxResult = do
  txid <- S.param "txid"
  addr <- getAddress "addr"
  setMetrics (.binfoQtxresult)
  tx <-
    getBinfoTx txid >>= \case
      Right t -> return t
      Left e -> raise e
  let i = toInteger $ sum $ map (.value) $ filter (f addr) tx.inputs
      o = toInteger $ sum $ map (.value) $ filter (g addr) tx.outputs
  S.text $ cs $ show $ o - i
  where
    f addr StoreInput {address = Just a} = a == addr
    f _ _ = False
    g addr StoreOutput {address = Just a} = a == addr
    g _ _ = False

scottyBinfoTotalInput :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoTotalInput = do
  txid <- S.param "txid"
  setMetrics (.binfoQtxtotalbtcinput)
  tx <-
    getBinfoTx txid >>= \case
      Right t -> return t
      Left e -> raise e
  S.text $ cs $ show $ sum $ map (.value) $ filter f $ tx.inputs
  where
    f StoreInput {} = True
    f StoreCoinbase {} = False

scottyBinfoMempool :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoMempool = do
  setMetrics (.binfoMempool)
  numtxid <- getNumTxId
  offset <- getBinfoOffset
  n <- getBinfoCount "limit"
  mempool <- getMempool
  let txids = map snd $ take n $ drop offset mempool
  txs <- catMaybes <$> mapM getTransaction txids
  net <- lift $ asks (.config.store.net)
  setHeaders
  let mem = BinfoMempool $ map (toBinfoTxSimple numtxid) txs
  ctx <- lift $ asks (.config.store.ctx)
  streamEncoding $ marshalEncoding (net, ctx) mem

scottyBinfoGetBlockCount :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoGetBlockCount = do
  setMetrics (.binfoQgetblockcount)
  ch <- asks (.config.store.chain)
  bn <- chainGetBest ch
  setHeaders
  S.text $ cs $ show bn.height

scottyBinfoLatestHash :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoLatestHash = do
  setMetrics (.binfoQlatesthash)
  ch <- asks (.config.store.chain)
  bn <- chainGetBest ch
  setHeaders
  S.text $ TL.fromStrict $ H.blockHashToHex $ H.headerHash bn.header

scottyBinfoSubsidy :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoSubsidy = do
  setMetrics (.binfoQbcperblock)
  ch <- asks (.config.store.chain)
  net <- asks (.config.store.net)
  bn <- chainGetBest ch
  setHeaders
  S.text $
    cs $
      show $
        (/ (100 * 1000 * 1000 :: Double)) $
          fromIntegral $
            H.computeSubsidy net (bn.height + 1)

scottyBinfoAddrToHash :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoAddrToHash = do
  setMetrics (.binfoQaddresstohash)
  addr <- getAddress "addr"
  setHeaders
  S.text $ encodeHexLazy $ runPutL $ serialize addr.hash160

scottyBinfoHashToAddr :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoHashToAddr = do
  setMetrics (.binfoQhashtoaddress)
  bs <- maybe S.next return . decodeHex =<< S.param "hash"
  net <- asks (.config.store.net)
  hash <- either (const S.next) return $ decode bs
  addr <- maybe S.next return $ addrToText net $ PubKeyAddress hash
  setHeaders
  S.text $ TL.fromStrict addr

scottyBinfoAddrPubkey :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoAddrPubkey = do
  setMetrics (.binfoQaddrpubkey)
  hex <- S.param "pubkey"
  ctx <- lift $ asks (.config.store.ctx)
  pubkey <-
    maybe S.next (return . pubKeyAddr ctx) $
      eitherToMaybe . unmarshal ctx =<< decodeHex hex
  net <- lift $ asks (.config.store.net)
  setHeaders
  case addrToText net pubkey of
    Nothing -> raise ThingNotFound
    Just a -> do
      S.text $ TL.fromStrict a

scottyBinfoPubKeyAddr :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoPubKeyAddr = do
  setMetrics (.binfoQpubkeyaddr)
  addr <- getAddress "addr"
  mi <- strm addr
  i <- case mi of
    Nothing -> raise ThingNotFound
    Just i -> return i
  pk <- case extr addr i of
    Left e -> raise $ UserError e
    Right t -> return t
  setHeaders
  S.text $ encodeHexLazy $ L.fromStrict pk
  where
    strm addr = do
      runConduit $ do
        let f l = getAddressTxs addr l
            l = def {limit = 8} :: Limits
        streamThings f (Just (.txid)) l
          .| concatMapMC (getTransaction . (.txid))
          .| concatMapC (filter (inp addr) . (.inputs))
          .| headC
    inp addr StoreInput {address = Just a} = a == addr
    inp _ _ = False
    extr addr StoreInput {script, pkscript, witness} = do
      Script sig <- decode script
      Script pks <- decode pkscript
      case addr of
        PubKeyAddress {} ->
          case sig of
            [OP_PUSHDATA _ _, OP_PUSHDATA pub _] ->
              Right pub
            [OP_PUSHDATA _ _] ->
              case pks of
                [OP_PUSHDATA pub _, OP_CHECKSIG] ->
                  Right pub
                _ -> Left "Could not parse scriptPubKey"
            _ -> Left "Could not parse scriptSig"
        WitnessPubKeyAddress {} ->
          case witness of
            [_, pub] -> return pub
            _ -> Left "Could not parse scriptPubKey"
        _ -> Left "Address does not have public key"
    extr _ _ = Left "Incorrect input type"

scottyBinfoHashPubkey :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoHashPubkey = do
  setMetrics (.binfoQhashpubkey)
  ctx <- lift $ asks (.config.store.ctx)
  pkm <- (eitherToMaybe . unmarshal ctx <=< decodeHex) <$> S.param "pubkey"
  addr <- case pkm of
    Nothing -> raise $ UserError "Could not decode public key"
    Just pk -> return $ pubKeyAddr ctx pk
  setHeaders
  S.text $ encodeHexLazy $ runPutL $ serialize addr.hash160

-- GET Network Information --

scottyPeers ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetPeers ->
  WebT m [PeerInfo]
scottyPeers _ = do
  setMetrics (.peers)
  ps <- lift $ getPeersInformation =<< asks (.config.store.peerMgr)
  return ps

-- | Obtain information about connected peers from peer manager process.
getPeersInformation ::
  (MonadLoggerIO m) => PeerMgr -> m [PeerInfo]
getPeersInformation mgr =
  mapMaybe toInfo <$> getPeers mgr
  where
    toInfo op = do
      ver <- op.version
      return
        PeerInfo
          { userAgent = ver.userAgent.get,
            address = show op.address,
            version = ver.version,
            services = ver.services,
            relay = ver.relay
          }

scottyHealth ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetHealth -> WebT m HealthCheck
scottyHealth _ = do
  setMetrics (.health)
  h <- asks (.health) >>= readTVarIO
  unless (isOK h) $ S.status status503
  return h

blockHealthCheck ::
  (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m) =>
  WebConfig ->
  m BlockHealth
blockHealthCheck cfg = do
  let ch = cfg.store.chain
  headers <- (.height) <$> chainGetBest ch
  blocks <-
    maybe 0 (.height)
      <$> runMaybeT (MaybeT getBestBlock >>= MaybeT . getBlock)
  return
    BlockHealth
      { headers,
        blocks,
        max = fromIntegral cfg.maxLaggingBlocks
      }

lastBlockHealthCheck ::
  (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m) =>
  Chain ->
  WebLimits ->
  m TimeHealth
lastBlockHealthCheck ch WebLimits {blockTimeout} = do
  n <- fromIntegral . systemSeconds <$> liftIO getSystemTime
  t <- fromIntegral . (.header.timestamp) <$> chainGetBest ch
  return
    TimeHealth
      { age = n - t,
        max = fromIntegral blockTimeout
      }

lastTxHealthCheck ::
  (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m) =>
  WebConfig ->
  m TimeHealth
lastTxHealthCheck WebConfig {noMempool, store, limits} = do
  n <- fromIntegral . systemSeconds <$> liftIO getSystemTime
  b <- fromIntegral . (.header.timestamp) <$> chainGetBest ch
  t <-
    getMempool >>= \case
      t : _ ->
        let x = fromIntegral $ fst t
         in return $ max x b
      [] -> return b
  return
    TimeHealth
      { age = n - t,
        max = fromIntegral to
      }
  where
    ch = store.chain
    to =
      if noMempool
        then limits.blockTimeout
        else limits.txTimeout

pendingTxsHealthCheck ::
  (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m) =>
  WebConfig ->
  m MaxHealth
pendingTxsHealthCheck cfg = do
  n <- blockStorePendingTxs cfg.store.block
  return
    MaxHealth
      { max = fromIntegral cfg.maxPendingTxs,
        count = fromIntegral n
      }

peerHealthCheck ::
  (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m) =>
  WebConfig ->
  m CountHealth
peerHealthCheck cfg = do
  count <- fromIntegral . length <$> getPeers cfg.store.peerMgr
  return CountHealth {min = fromIntegral cfg.minPeers, count}

healthCheck ::
  (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m) =>
  WebConfig ->
  m HealthCheck
healthCheck cfg = do
  blocks <- blockHealthCheck cfg
  lastBlock <- lastBlockHealthCheck cfg.store.chain cfg.limits
  lastTx <- lastTxHealthCheck cfg
  pendingTxs <- pendingTxsHealthCheck cfg
  peers <- peerHealthCheck cfg
  time <- round . utcTimeToPOSIXSeconds <$> liftIO getCurrentTime
  let check =
        HealthCheck
          { network = cfg.store.net.name,
            version = cfg.version,
            ..
          }
  unless (isOK check) $ do
    let t = toStrict $ encodeToLazyText check
    $(logErrorS) "Web" $ "Health check failed: " <> t
  return check

scottyDbStats :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyDbStats = do
  setMetrics (.db)
  setHeaders
  db <- lift $ asks (.config.store.db.db)
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
      net <- lift $ asks (.config.store.net)
      ctx <- lift $ asks (.config.store.ctx)
      tsM :: Maybe [Text] <- p `S.rescue` const (return Nothing)
      case tsM of
        Nothing -> return Nothing -- Parameter was not supplied
        Just ts -> maybe (raise err) (return . Just) $ parseParam net ctx ts
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
          raise . UserError $
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

parseBody :: (MonadIO m, Serial a) => WebT m a
parseBody = do
  b <- L.toStrict <$> S.body
  case hex b <> bin b of
    Left _ -> raise $ UserError "Failed to parse request body"
    Right x -> return x
  where
    bin = runGetS deserialize
    hex b =
      let ns = C.filter (not . isSpace) b
       in if isBase16 ns
            then bin . decodeBase16 $ assertBase16 ns
            else Left "Invalid hex input"

parseOffset :: (MonadIO m) => WebT m OffsetParam
parseOffset = do
  res@(OffsetParam o) <- paramDef
  limits <- lift $ asks (.config.limits)
  when (limits.maxOffset > 0 && fromIntegral o > limits.maxOffset) $
    raise . UserError $
      "offset exceeded: " <> show o <> " > " <> show limits.maxOffset
  return res

parseStart ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  Maybe StartParam ->
  WebT m (Maybe Start)
parseStart Nothing = return Nothing
parseStart (Just s) =
  runMaybeT $
    case s of
      StartParamHash {hash = h} -> start_tx h <|> start_block h
      StartParamHeight {height = h} -> start_height h
      StartParamTime {time = q} -> start_time q
  where
    start_height h = return $ AtBlock $ fromIntegral h
    start_block h = do
      b <- MaybeT $ getBlock (H.BlockHash h)
      return $ AtBlock b.height
    start_tx h = do
      _ <- MaybeT $ getTxData (TxHash h)
      return $ AtTx (TxHash h)
    start_time q = do
      ch <- lift $ asks (.config.store.chain)
      b <- MaybeT $ blockAtOrBefore ch q
      return $ AtBlock b.height

parseLimits :: (MonadIO m) => WebT m LimitsParam
parseLimits = LimitsParam <$> paramOptional <*> parseOffset <*> paramOptional

paramToLimits ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  Bool ->
  LimitsParam ->
  WebT m Limits
paramToLimits full (LimitsParam limitM o startM) = do
  wl <- lift $ asks (.config.limits)
  Limits (validateLimit wl full limitM) (fromIntegral o) <$> parseStart startM

validateLimit :: WebLimits -> Bool -> Maybe LimitParam -> Word32
validateLimit wl full limitM =
  f m $ maybe d (fromIntegral . (.get)) limitM
  where
    m
      | full && wl.maxFullItemCount > 0 = wl.maxFullItemCount
      | otherwise = wl.maxItemCount
    d = wl.defItemCount
    f a 0 = a
    f 0 b = b
    f a b = min a b

---------------
-- Utilities --
---------------

runInWebReader ::
  (MonadIO m) =>
  CacheT (DatabaseReaderT m) a ->
  ReaderT WebState m a
runInWebReader f = do
  bdb <- asks (.config.store.db)
  mc <- asks (.config.store.cache)
  lift $ runReaderT (withCache mc f) bdb

runNoCache :: (MonadIO m) => Bool -> ReaderT WebState m a -> ReaderT WebState m a
runNoCache False f = f
runNoCache True f = local g f
  where
    g s = s {config = h s.config}
    h c = c {store = i c.store}
    i s = s {cache = Nothing}

logIt ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  Maybe WebMetrics ->
  m Middleware
logIt metrics = do
  runner <- askRunInIO
  return $ \app request respond -> do
    req <-
      case metrics of
        Nothing -> return request
        Just m -> do
          stat_var <- newTVarIO Nothing
          return request {vault = V.insert m.key stat_var request.vault}
    bracket start (end req) $ \_ ->
      app req $ \res -> do
        let s = responseStatus res
            msg = fmtReq req <> ": " <> fmtStatus s
        if statusIsSuccessful s
          then runner $ $(logDebugS) "Web" msg
          else runner $ $(logErrorS) "Web" msg
        respond res
  where
    start = runMaybeT $ do
      _ <- MaybeT $ return metrics
      systemToUTCTime <$> lift getSystemTime
    end req mt1 = void $ runMaybeT $ do
      m <- MaybeT $ return metrics
      t1 <- MaybeT $ return mt1
      t2 <- systemToUTCTime <$> lift getSystemTime
      let ms = realToFrac (diffUTCTime t2 t1) * 1000
      addStatTime m.all ms
      stat_var <- MaybeT $ return $ V.lookup m.key req.vault
      f <- MaybeT $ readTVarIO stat_var
      addStatTime (f m) ms

reqSizeLimit :: (Integral i) => i -> Middleware
reqSizeLimit i = requestSizeLimitMiddleware lim
  where
    max_len _req = return (Just (fromIntegral i))
    lim =
      setOnLengthExceeded too_big $
        setMaxLengthForRequest
          max_len
          defaultRequestSizeLimitSettings
    too_big _ _app _req send =
      send $
        waiExcept requestEntityTooLarge413 RequestTooLarge

reqTimeout :: (Integral i) => i -> Middleware
reqTimeout = timeoutAs res . fromIntegral
  where
    err = ServerTimeout
    res = responseLBS sta [hdr] (A.encode err)
    sta = errStatus err
    hdr = (hContentType, "application/json")

fmtReq :: Request -> Text
fmtReq req =
  let m = requestMethod req
      v = httpVersion req
      p = rawPathInfo req
      q = rawQueryString req
   in T.decodeUtf8 (m <> " " <> p <> q <> " " <> cs (show v))

fmtStatus :: Status -> Text
fmtStatus s = cs (show (statusCode s)) <> " " <> cs (statusMessage s)
