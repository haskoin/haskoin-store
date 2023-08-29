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
import Control.Monad.Trans.Control
  ( MonadBaseControl,
    control,
    liftWith,
    restoreM,
    restoreT,
  )
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
import Data.Time.Clock.POSIX (getPOSIXTime, utcTimeToPOSIXSeconds)
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
import System.Metrics qualified as Metrics
import System.Metrics.Counter (Counter)
import System.Metrics.Counter qualified as Metrics.Counter
import System.Metrics.Distribution (Distribution)
import System.Metrics.Distribution qualified as Metrics.Distribution
import System.Metrics.Gauge (Gauge)
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
  { -- Addresses
    addressTx :: !Distribution,
    addressTxFull :: !Distribution,
    addressBalance :: !Distribution,
    addressUnspent :: !Distribution,
    xpub :: !Distribution,
    xpubDelete :: !Distribution,
    xpubTxFull :: !Distribution,
    xpubTx :: !Distribution,
    xpubBalance :: !Distribution,
    xpubUnspent :: !Distribution,
    -- Transactions
    tx :: !Distribution,
    txRaw :: !Distribution,
    txAfter :: !Distribution,
    txBlock :: !Distribution,
    txBlockRaw :: !Distribution,
    txPost :: !Distribution,
    mempool :: !Distribution,
    -- Blocks
    block :: !Distribution,
    blockRaw :: !Distribution,
    -- Blockchain
    binfoMultiaddr :: !Distribution,
    binfoBalance :: !Distribution,
    binfoAddressRaw :: !Distribution,
    binfoUnspent :: !Distribution,
    binfoTxRaw :: !Distribution,
    binfoBlock :: !Distribution,
    binfoBlockHeight :: !Distribution,
    binfoBlockLatest :: !Distribution,
    binfoBlockRaw :: !Distribution,
    binfoMempool :: !Distribution,
    binfoExportHistory :: !Distribution,
    -- Blockchain /q endpoints
    binfoQaddresstohash :: !Distribution,
    binfoQhashtoaddress :: !Distribution,
    binfoQaddrpubkey :: !Distribution,
    binfoQpubkeyaddr :: !Distribution,
    binfoQhashpubkey :: !Distribution,
    binfoQgetblockcount :: !Distribution,
    binfoQlatesthash :: !Distribution,
    binfoQbcperblock :: !Distribution,
    binfoQtxtotalbtcoutput :: !Distribution,
    binfoQtxtotalbtcinput :: !Distribution,
    binfoQtxfee :: !Distribution,
    binfoQtxresult :: !Distribution,
    binfoQgetreceivedbyaddress :: !Distribution,
    binfoQgetsentbyaddress :: !Distribution,
    binfoQaddressbalance :: !Distribution,
    binfoQaddressfirstseen :: !Distribution,
    -- Errors
    serverErrors :: Counter,
    clientErrors :: Counter,
    -- Others
    health :: !Distribution,
    peers :: !Distribution,
    db :: !Distribution,
    events :: !Gauge
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

  -- Errors

  serverErrors <- c "server_errors"
  clientErrors <- c "client_errors"

  -- Others
  health <- d "health"
  peers <- d "peers"
  db <- d "dbstats"

  events <- g "events_connected"
  return WebMetrics {..}
  where
    d x = Metrics.createDistribution ("web." <> x) s
    g x = Metrics.createGauge ("web." <> x) s
    c x = Metrics.createCounter ("web." <> x) s

withGaugeIO :: (MonadUnliftIO m) => Gauge -> m a -> m a
withGaugeIO g =
  bracket_
    (liftIO $ Metrics.Gauge.inc g)
    (liftIO $ Metrics.Gauge.dec g)

withGaugeIncrease ::
  (MonadUnliftIO m) =>
  (WebMetrics -> Gauge) ->
  WebT m a ->
  WebT m a
withGaugeIncrease gf go =
  lift (asks (.metrics)) >>= \case
    Nothing -> go
    Just m -> do
      s <- liftWith $ \run -> withGaugeIO (gf m) (run go)
      restoreT $ return s

withMetrics ::
  (MonadUnliftIO m) => (WebMetrics -> Distribution) -> WebT m a -> WebT m a
withMetrics df go =
  asks (.metrics) >>= \case
    Nothing -> go
    Just m ->
      restoreT . return
        =<< liftWith (\run -> bracket time (stop m) (const (run go)))
  where
    time = (* 1000) . realToFrac <$> liftIO getPOSIXTime
    stop m t1 = do
      t2 <- time
      let ms = t2 - t1
      liftIO $ Metrics.Distribution.add (df m) ms

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
raise err = do
  asks (.metrics) >>= mapM_ \m -> do
    let status = errStatus err
    liftIO $
      mapM_ Metrics.Counter.inc $
        if
          | statusIsClientError status -> Just m.clientErrors
          | statusIsServerError status -> Just m.serverErrors
          | otherwise -> Nothing
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
scottyBlock (GetBlock h (NoTx noTx)) = withMetrics (.block) $ do
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
scottyBlocks (GetBlocks hs (NoTx notx)) =
  withMetrics (.block) $
    getBlocks hs notx

pruneTx :: Bool -> BlockData -> BlockData
pruneTx False b = b
pruneTx True BlockData {..} = BlockData {txs = take 1 txs, ..}

-- GET BlockRaw --

scottyBlockRaw ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetBlockRaw ->
  WebT m (RawResult H.Block)
scottyBlockRaw (GetBlockRaw h) =
  withMetrics (.blockRaw) $
    RawResult <$> getRawBlock h

getRawBlock ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  H.BlockHash ->
  WebT m H.Block
getRawBlock h =
  getBlock h >>= maybe (raise ThingNotFound) return >>= lift . toRawBlock

toRawBlock :: (MonadUnliftIO m, StoreReadBase m) => BlockData -> m H.Block
toRawBlock b = do
  txs <- map transactionData . catMaybes <$> mapM getTransaction b.txs
  return H.Block {header = b.header, txs}

-- GET BlockBest / BlockBestRaw --

scottyBlockBest ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetBlockBest -> WebT m BlockData
scottyBlockBest (GetBlockBest (NoTx notx)) =
  withMetrics (.block) $
    maybe (raise ThingNotFound) (return . pruneTx notx) <=< runMaybeT $
      MaybeT getBestBlock >>= MaybeT . getBlock

scottyBlockBestRaw ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetBlockBestRaw ->
  WebT m (RawResult H.Block)
scottyBlockBestRaw _ =
  withMetrics (.blockRaw) $
    maybe (raise ThingNotFound) (return . RawResult) <=< runMaybeT $
      MaybeT getBestBlock >>= lift . getRawBlock

-- GET BlockLatest --

scottyBlockLatest ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetBlockLatest ->
  WebT m [BlockData]
scottyBlockLatest (GetBlockLatest (NoTx noTx)) =
  withMetrics (.block) $
    getBestBlock >>= maybe (raise ThingNotFound) (go [] <=< getBlock)
  where
    go acc Nothing = return $ reverse acc
    go acc (Just b)
      | b.height <= 0 = return $ reverse acc
      | length acc == 99 = return . reverse $ pruneTx noTx b : acc
      | otherwise = go (pruneTx noTx b : acc) =<< getBlock b.header.prev

-- GET BlockHeight / BlockHeights / BlockHeightRaw --

scottyBlockHeight ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetBlockHeight -> WebT m [BlockData]
scottyBlockHeight (GetBlockHeight h (NoTx notx)) =
  withMetrics (.block) $
    getBlocksAtHeight (fromIntegral h)
      >>= (`getBlocks` notx)

scottyBlockHeights ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetBlockHeights ->
  WebT m [BlockData]
scottyBlockHeights (GetBlockHeights (HeightsParam heights) (NoTx notx)) =
  withMetrics (.block) $
    mapM (getBlocksAtHeight . fromIntegral) heights
      >>= (`getBlocks` notx) . concat

scottyBlockHeightRaw ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetBlockHeightRaw ->
  WebT m (RawResultList H.Block)
scottyBlockHeightRaw (GetBlockHeightRaw h) =
  withMetrics (.blockRaw) $
    fmap RawResultList $
      mapM getRawBlock =<< getBlocksAtHeight (fromIntegral h)

-- GET BlockTime / BlockTimeRaw --

scottyBlockTime ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetBlockTime ->
  WebT m BlockData
scottyBlockTime (GetBlockTime (TimeParam t) (NoTx notx)) =
  withMetrics (.block) $ do
    ch <- asks (.config.store.chain)
    blockAtOrBefore ch t >>= \case
      Nothing -> raise ThingNotFound
      Just b -> return $ pruneTx notx b

scottyBlockMTP ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetBlockMTP ->
  WebT m BlockData
scottyBlockMTP (GetBlockMTP (TimeParam t) (NoTx notx)) =
  withMetrics (.block) $ do
    ch <- asks (.config.store.chain)
    blockAtOrAfterMTP ch t >>= \case
      Nothing -> raise ThingNotFound
      Just b -> return $ pruneTx notx b

scottyBlockTimeRaw ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetBlockTimeRaw ->
  WebT m (RawResult H.Block)
scottyBlockTimeRaw (GetBlockTimeRaw (TimeParam t)) =
  withMetrics (.blockRaw) $ do
    ch <- asks (.config.store.chain)
    blockAtOrBefore ch t >>= \case
      Nothing -> raise ThingNotFound
      Just b -> RawResult <$> lift (toRawBlock b)

scottyBlockMTPRaw ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetBlockMTPRaw ->
  WebT m (RawResult H.Block)
scottyBlockMTPRaw (GetBlockMTPRaw (TimeParam t)) =
  withMetrics (.blockRaw) $ do
    ch <- asks (.config.store.chain)
    blockAtOrAfterMTP ch t >>= \case
      Nothing -> raise ThingNotFound
      Just b -> RawResult <$> lift (toRawBlock b)

-- GET Transactions --

scottyTx :: (MonadUnliftIO m, MonadLoggerIO m) => GetTx -> WebT m Transaction
scottyTx (GetTx txid) =
  withMetrics (.tx) $
    getTransaction txid >>= maybe (raise ThingNotFound) return

scottyTxs ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetTxs -> WebT m [Transaction]
scottyTxs (GetTxs txids) =
  withMetrics (.tx) $
    catMaybes <$> mapM getTransaction (nub txids)

scottyTxRaw ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetTxRaw -> WebT m (RawResult Tx)
scottyTxRaw (GetTxRaw txid) =
  withMetrics (.txRaw) $
    getTransaction txid
      >>= \case
        Nothing -> raise ThingNotFound
        Just tx -> return $ RawResult (transactionData tx)

scottyTxsRaw ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetTxsRaw ->
  WebT m (RawResultList Tx)
scottyTxsRaw (GetTxsRaw txids) =
  withMetrics (.txRaw) $
    RawResultList . map transactionData . catMaybes
      <$> mapM getTransaction (nub txids)

getTxsBlock ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  H.BlockHash ->
  WebT m [Transaction]
getTxsBlock h =
  getBlock h >>= \case
    Nothing -> raise ThingNotFound
    Just b -> catMaybes <$> mapM getTransaction b.txs

scottyTxsBlock ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetTxsBlock ->
  WebT m [Transaction]
scottyTxsBlock (GetTxsBlock h) =
  withMetrics (.txBlock) $ getTxsBlock h

scottyTxsBlockRaw ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetTxsBlockRaw ->
  WebT m (RawResultList Tx)
scottyTxsBlockRaw (GetTxsBlockRaw h) =
  withMetrics (.txBlockRaw) $
    RawResultList . map transactionData <$> getTxsBlock h

-- GET TransactionAfterHeight --

scottyTxAfter ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetTxAfter ->
  WebT m (GenericResult (Maybe Bool))
scottyTxAfter (GetTxAfter txid height) =
  withMetrics (.txAfter) $
    GenericResult . fst <$> cbAfterHeight (fromIntegral height) txid

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
scottyPostTx (PostTx tx) =
  withMetrics (.txPost) $ do
    cfg <- asks (.config)
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
scottyMempool (GetMempool limitM (OffsetParam o)) =
  withMetrics (.mempool) $ do
    WebLimits {..} <- asks (.config.limits)
    let wl' = WebLimits {maxItemCount = 0, ..}
        l = Limits (validateLimit wl' False limitM) (fromIntegral o) Nothing
    map snd . applyLimits l <$> getMempool

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
scottyAddrTxs (GetAddrTxs addr pLimits) =
  withMetrics (.addressTx) $
    getAddressTxs addr =<< paramToLimits False pLimits

scottyAddrsTxs ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetAddrsTxs -> WebT m [TxRef]
scottyAddrsTxs (GetAddrsTxs addrs pLimits) =
  withMetrics (.addressTx) $
    getAddressesTxs addrs =<< paramToLimits False pLimits

scottyAddrTxsFull ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetAddrTxsFull ->
  WebT m [Transaction]
scottyAddrTxsFull (GetAddrTxsFull addr pLimits) =
  withMetrics (.addressTxFull) $ do
    txs <- getAddressTxs addr =<< paramToLimits True pLimits
    catMaybes <$> mapM (getTransaction . (.txid)) txs

scottyAddrsTxsFull ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetAddrsTxsFull ->
  WebT m [Transaction]
scottyAddrsTxsFull (GetAddrsTxsFull addrs pLimits) =
  withMetrics (.addressTxFull) $ do
    txs <- getAddressesTxs addrs =<< paramToLimits True pLimits
    catMaybes <$> mapM (getTransaction . (.txid)) txs

scottyAddrBalance ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetAddrBalance ->
  WebT m Balance
scottyAddrBalance (GetAddrBalance addr) =
  withMetrics (.addressBalance) $ getDefaultBalance addr

scottyAddrsBalance ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetAddrsBalance -> WebT m [Balance]
scottyAddrsBalance (GetAddrsBalance addrs) =
  withMetrics (.addressBalance) $ getBalances addrs

scottyAddrUnspent ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetAddrUnspent -> WebT m [Unspent]
scottyAddrUnspent (GetAddrUnspent addr pLimits) =
  withMetrics (.addressUnspent) $
    getAddressUnspents addr =<< paramToLimits False pLimits

scottyAddrsUnspent ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetAddrsUnspent -> WebT m [Unspent]
scottyAddrsUnspent (GetAddrsUnspent addrs pLimits) =
  withMetrics (.addressUnspent) $
    getAddressesUnspents addrs =<< paramToLimits False pLimits

-- GET XPubs --

scottyXPub ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetXPub -> WebT m XPubSummary
scottyXPub (GetXPub xpub deriv (NoCache noCache)) =
  withMetrics (.xpub) $
    let xs = XPubSpec xpub deriv
     in xPubSummary xs <$> lift (runNoCache noCache $ xPubBals xs)

scottyDelXPub ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  DelCachedXPub ->
  WebT m (GenericResult Bool)
scottyDelXPub (DelCachedXPub xpub deriv) =
  withMetrics (.xpubDelete) $ do
    c <- asks (.config.store.cache)
    n <- lift (withCache c $ cacheDelXPubs [XPubSpec xpub deriv])
    return $ GenericResult (n > 0)

getXPubTxs ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  XPubKey ->
  DeriveType ->
  LimitsParam ->
  Bool ->
  WebT m [TxRef]
getXPubTxs xpub deriv plimits nocache = do
  limits <- paramToLimits False plimits
  let xs = XPubSpec xpub deriv
  xbals <- xPubBals xs
  lift $ runNoCache nocache $ xPubTxs xs xbals limits

scottyXPubTxs ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetXPubTxs -> WebT m [TxRef]
scottyXPubTxs (GetXPubTxs xpub deriv plimits (NoCache nocache)) =
  withMetrics (.xpubTx) $
    getXPubTxs xpub deriv plimits nocache

scottyXPubTxsFull ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetXPubTxsFull ->
  WebT m [Transaction]
scottyXPubTxsFull (GetXPubTxsFull xpub deriv plimits (NoCache nocache)) =
  withMetrics (.xpubTxFull) $
    fmap catMaybes $
      lift . runNoCache nocache . mapM (getTransaction . (.txid))
        =<< getXPubTxs xpub deriv plimits nocache

scottyXPubBalances ::
  (MonadUnliftIO m, MonadLoggerIO m) => GetXPubBalances -> WebT m [XPubBal]
scottyXPubBalances (GetXPubBalances xpub deriv (NoCache noCache)) =
  withMetrics (.xpubBalance) $
    lift $
      runNoCache noCache $
        xPubBals (XPubSpec xpub deriv)

scottyXPubUnspent ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  GetXPubUnspent ->
  WebT m [XPubUnspent]
scottyXPubUnspent (GetXPubUnspent xpub deriv pLimits (NoCache noCache)) =
  withMetrics (.xpubUnspent) $ do
    limits <- paramToLimits False pLimits
    let xspec = XPubSpec xpub deriv
    xbals <- xPubBals xspec
    lift $ runNoCache noCache $ xPubUnspents xspec xbals limits

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
  net <- asks (.config.store.net)
  ctx <- asks (.config.store.ctx)
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
getChainHeight = fmap (.height) $ chainGetBest =<< asks (.config.store.chain)

scottyBinfoUnspent :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoUnspent =
  withMetrics (.binfoUnspent) $ do
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
            let h = xPubUnspents x (xBals x xbals)
                l = let Limits {..} = def in Limits {limit = 16, ..}
            return $ streamThings h Nothing l .| mapC (f x)
      mapM g (HashSet.toList xspecs)
    acounduits =
      let f u = (u, Nothing)
          h = getAddressUnspents
          l = let Limits {..} = def in Limits {limit = 16, ..}
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
        let f = xPubTxs x (xBals x xbals)
            l = Limits {limit = 16, offset = 0, start = Nothing}
        lift . return $
          streamThings f (Just (.txid)) l
      addr_c a = do
        let l = Limits {limit = 16, offset = 0, start = Nothing}
        streamThings (getAddressTxs a) (Just (.txid)) l
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
  net <- asks (.config.store.net)
  case textToAddr net txt of
    Nothing -> raise ThingNotFound
    Just a -> return a

getBinfoAddr :: (Monad m) => TL.Text -> WebT m BinfoAddr
getBinfoAddr param' = do
  txt <- S.param param'
  net <- asks (.config.store.net)
  ctx <- asks (.config.store.ctx)
  let x =
        BinfoAddr
          <$> textToAddr net txt
          <|> BinfoXpub <$> xPubImport net ctx txt
  maybe S.next return x

scottyBinfoHistory :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoHistory =
  withMetrics (.binfoExportHistory) $ do
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
    net <- asks (.config.store.net)
    url <- asks (.config.priceHistoryURL)
    session <- asks (.session)
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
    lim endM =
      Limits
        { limit = 16,
          offset = 0,
          start = AtBlock . (.height) <$> endM
        }
    addr_c endM a =
      streamThings (getAddressTxs a) (Just (.txid)) (lim endM)
    xpub_c endM x bs =
      streamThings (xPubTxs x bs) (Just (.txid)) (lim endM)

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
scottyBinfoBlocksDay =
  withMetrics (.binfoBlock) $ do
    t <- min h . (`div` 1000) <$> S.param "milliseconds"
    ch <- asks (.config.store.chain)
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
scottyMultiAddr =
  withMetrics (.binfoMultiaddr) $ do
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
    net <- asks (.config.store.net)
    ctx <- asks (.config.store.ctx)
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
  d <- asks (.config.limits.defItemCount)
  x <- asks (.config.limits.maxFullItemCount)
  i <- min x <$> (S.param str `S.rescue` const (return d))
  return (fromIntegral i :: Int)

getBinfoOffset ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  WebT m Int
getBinfoOffset = do
  x <- asks (.config.limits.maxOffset)
  o <- S.param "offset" `S.rescue` const (return 0)
  when (o > x) $
    raise $
      UserError $
        "offset exceeded: " <> show o <> " > " <> show x
  return (fromIntegral o :: Int)

scottyRawAddr :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyRawAddr =
  withMetrics (.binfoAddressRaw) $
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
          balance = bal.confirmed + bal.unconfirmed
      txs <-
        lift . runConduit $
          getBinfoTxs
            HashMap.empty
            abook
            xspecs
            saddrs
            saddrs
            bfilter
            numtxid
            False
            (fromIntegral balance)
            .| (dropC off >> takeC n .| sinkList)
      let ra =
            BinfoRawAddr
              { address = BinfoAddr addr,
                balance,
                ntx = bal.txs,
                utxo = bal.utxo,
                received = bal.received,
                sent = fromIntegral bal.received - fromIntegral balance,
                txs
              }
      setHeaders
      ctx <- asks (.config.store.ctx)
      streamEncoding $ marshalEncoding (net, ctx) ra

scottyBinfoReceived :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoReceived =
  withMetrics (.binfoQgetreceivedbyaddress) $ do
    a <- getAddress "addr"
    b <- fromMaybe (zeroBalance a) <$> getBalance a
    setHeaders
    S.text $ cs $ show b.received

scottyBinfoSent :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoSent =
  withMetrics (.binfoQgetsentbyaddress) $ do
    a <- getAddress "addr"
    b <- fromMaybe (zeroBalance a) <$> getBalance a
    setHeaders
    S.text $ cs $ show $ b.received - b.confirmed - b.unconfirmed

scottyBinfoAddrBalance :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoAddrBalance =
  withMetrics (.binfoQaddressbalance) $ do
    a <- getAddress "addr"
    b <- fromMaybe (zeroBalance a) <$> getBalance a
    setHeaders
    S.text $ cs $ show $ b.confirmed + b.unconfirmed

scottyFirstSeen :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyFirstSeen =
  withMetrics (.binfoQaddressfirstseen) $ do
    a <- getAddress "addr"
    ch <- asks (.config.store.chain)
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
      chainGetAncestor h bb ch >>= \case
        Just b -> return b.header.timestamp
        Nothing -> do
          lift . $(logErrorS) "Web" $
            "Could not get ancestor at height "
              <> cs (show h)
              <> " for block "
              <> H.blockHashToHex (H.headerHash bb.header)
          error "Block ancestor retreival error"
    hasone a h = do
      let l = Limits 1 0 (Just (AtBlock h))
      not . null <$> getAddressTxs a l

scottyShortBal :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyShortBal =
  withMetrics (.binfoBalance) $ do
    (xspecs, addrs) <- getBinfoActive
    cashaddr <- getCashAddr
    net <- asks (.config.store.net)
    abals <- catMaybes <$> mapM (getabal net cashaddr) (HashSet.toList addrs)
    xbals <- mapM (getxbal net) (HashSet.toList xspecs)
    let res = HashMap.fromList (abals <> xbals)
    setHeaders
    streamEncoding $ toEncoding res
  where
    shorten bal =
      BinfoShortBal
        { final = bal.confirmed + bal.unconfirmed,
          ntx = bal.txs,
          received = bal.received
        }
    getabal net cashaddr a =
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
                Nothing -> return $ Just (a', shorten (zeroBalance a))
                Just b -> return $ Just (a', shorten b)
    getxbal net xpub = do
      xbals <- xPubBals xpub
      ntx <- fromIntegral <$> xPubTxCount xpub xbals
      let val = sum $ map (.balance.confirmed) xbals
          zro = sum $ map (.balance.unconfirmed) xbals
          exs = [x | x@XPubBal {path = 0 : _} <- xbals]
          final = val + zro
          received = sum $ map (.balance.received) exs
          sbl = BinfoShortBal {final, ntx, received}
      ctx <- asks (.config.store.ctx)
      return (xPubExport net ctx xpub.key, sbl)

getBinfoHex :: (Monad m) => WebT m Bool
getBinfoHex =
  (== ("hex" :: Text))
    <$> S.param "format" `S.rescue` const (return "json")

scottyBinfoBlockHeight :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoBlockHeight =
  withMetrics (.binfoBlockHeight) $ do
    numtxid <- getNumTxId
    height <- S.param "height"
    bs <- fmap catMaybes $ getBlocksAtHeight height >>= mapM getBlock
    ns <- fmap catMaybes $ getBlocksAtHeight (height + 1) >>= mapM getBlock
    is <- mapM (get_binfo_blocks numtxid ns) bs
    setHeaders
    net <- asks (.config.store.net)
    ctx <- asks (.config.store.ctx)
    streamEncoding $ marshalEncoding (net, ctx) is
  where
    get_binfo_blocks numtxid ns b = do
      txs <- catMaybes <$> mapM getTransaction b.txs
      let h x = H.headerHash x.header
          nbs = [h n | n <- ns, n.header.prev == h b]
          bts = map (toBinfoTxSimple numtxid) txs
      return $ toBinfoBlock b bts nbs

scottyBinfoLatest :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoLatest =
  withMetrics (.binfoBlockLatest) $ do
    numtxid <- getNumTxId
    mb <- runMaybeT $ MaybeT getBestBlock >>= MaybeT . getBlock
    b <- maybe (raise ThingNotFound) return mb
    streamEncoding $
      toEncoding
        BinfoHeader
          { hash = H.headerHash b.header,
            timestamp = b.header.timestamp,
            index = b.height,
            height = b.height,
            txids = map (encodeBinfoTxId numtxid) b.txs
          }

scottyBinfoBlock :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoBlock =
  withMetrics (.binfoBlockRaw) $ do
    numtxid <- getNumTxId
    hex <- getBinfoHex
    S.param "block" >>= \case
      BinfoBlockHash bh -> go numtxid hex bh
      BinfoBlockIndex i ->
        getBlocksAtHeight i >>= \case
          [] -> raise ThingNotFound
          bh : _ -> go numtxid hex bh
  where
    go numtxid hex bh = do
      b <- maybe (raise ThingNotFound) return =<< getBlock bh
      txs <- catMaybes <$> mapM getTransaction b.txs
      nhs <- fmap catMaybes $ getBlocksAtHeight (b.height + 1) >>= mapM getBlock
      let h x = H.headerHash x.header
          nxt = [h n | n <- nhs, n.header.prev == h b]
      if hex
        then do
          let x = H.Block b.header (map transactionData txs)
          setHeaders
          S.text . encodeHexLazy . runPutL $ serialize x
        else do
          let bts = map (toBinfoTxSimple numtxid) txs
              y = toBinfoBlock b bts nxt
          setHeaders
          net <- asks (.config.store.net)
          ctx <- asks (.config.store.ctx)
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
scottyBinfoTx =
  withMetrics (.binfoTxRaw) $ do
    numtxid <- getNumTxId
    hex <- getBinfoHex
    txid <- S.param "txid"
    tx <-
      getBinfoTx txid >>= \case
        Right t -> return t
        Left e -> raise e
    if hex then hx tx else js numtxid tx
  where
    js numtxid t = do
      net <- asks (.config.store.net)
      ctx <- asks (.config.store.ctx)
      setHeaders
      streamEncoding $ marshalEncoding (net, ctx) $ toBinfoTxSimple numtxid t
    hx t = do
      setHeaders
      S.text . encodeHexLazy . runPutL . serialize $ transactionData t

scottyBinfoTotalOut :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoTotalOut =
  withMetrics (.binfoQtxtotalbtcoutput) $ do
    txid <- S.param "txid"
    tx <-
      getBinfoTx txid >>= \case
        Right t -> return t
        Left e -> raise e
    S.text $ cs $ show $ sum $ map (.value) tx.outputs

scottyBinfoTxFees :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoTxFees =
  withMetrics (.binfoQtxfee) $ do
    txid <- S.param "txid"
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
scottyBinfoTxResult =
  withMetrics (.binfoQtxresult) $ do
    txid <- S.param "txid"
    addr <- getAddress "addr"
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
scottyBinfoTotalInput =
  withMetrics (.binfoQtxtotalbtcinput) $ do
    txid <- S.param "txid"
    tx <-
      getBinfoTx txid >>= \case
        Right t -> return t
        Left e -> raise e
    S.text $ cs $ show $ sum $ map (.value) $ filter f $ tx.inputs
  where
    f StoreInput {} = True
    f StoreCoinbase {} = False

scottyBinfoMempool :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoMempool =
  withMetrics (.binfoMempool) $ do
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
scottyBinfoGetBlockCount =
  withMetrics (.binfoQgetblockcount) $ do
    ch <- asks (.config.store.chain)
    bn <- chainGetBest ch
    setHeaders
    S.text $ cs $ show bn.height

scottyBinfoLatestHash :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoLatestHash =
  withMetrics (.binfoQlatesthash) $ do
    ch <- asks (.config.store.chain)
    bn <- chainGetBest ch
    setHeaders
    S.text $ TL.fromStrict $ H.blockHashToHex $ H.headerHash bn.header

scottyBinfoSubsidy :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoSubsidy =
  withMetrics (.binfoQbcperblock) $ do
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
scottyBinfoAddrToHash =
  withMetrics (.binfoQaddresstohash) $ do
    addr <- getAddress "addr"
    setHeaders
    S.text $ encodeHexLazy $ runPutL $ serialize addr.hash160

scottyBinfoHashToAddr :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoHashToAddr =
  withMetrics (.binfoQhashtoaddress) $ do
    bs <- maybe S.next return . decodeHex =<< S.param "hash"
    net <- asks (.config.store.net)
    hash <- either (const S.next) return $ decode bs
    addr <- maybe S.next return $ addrToText net $ PubKeyAddress hash
    setHeaders
    S.text $ TL.fromStrict addr

scottyBinfoAddrPubkey :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoAddrPubkey =
  withMetrics (.binfoQaddrpubkey) $ do
    hex <- S.param "pubkey"
    ctx <- asks (.config.store.ctx)
    pubkey <-
      maybe S.next (return . pubKeyAddr ctx) $
        eitherToMaybe . unmarshal ctx =<< decodeHex hex
    net <- asks (.config.store.net)
    setHeaders
    case addrToText net pubkey of
      Nothing -> raise ThingNotFound
      Just a -> do
        S.text $ TL.fromStrict a

scottyBinfoPubKeyAddr :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoPubKeyAddr =
  withMetrics (.binfoQpubkeyaddr) $ do
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
        let l = Limits {limit = 8, offset = 0, start = Nothing}
        streamThings (getAddressTxs addr) (Just (.txid)) l
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
scottyBinfoHashPubkey =
  withMetrics (.binfoQhashpubkey) $ do
    ctx <- asks (.config.store.ctx)
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
scottyPeers _ =
  withMetrics (.peers) $ do
    lift . getPeersInformation =<< asks (.config.store.peerMgr)

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
scottyHealth _ =
  withMetrics (.health) $ do
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
  n <- round <$> liftIO getPOSIXTime
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
  n <- round <$> liftIO getPOSIXTime
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
  time <- round <$> liftIO getPOSIXTime
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
scottyDbStats =
  withMetrics (.db) $ do
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
  return $ \app req respond ->
    app req $ \res -> do
      let s = responseStatus res
          msg = fmtReq req <> ": " <> fmtStatus s
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
   in T.decodeUtf8 (m <> " " <> p <> q <> " " <> cs (show v))

fmtStatus :: Status -> Text
fmtStatus s = cs (show (statusCode s)) <> " " <> cs (statusMessage s)
