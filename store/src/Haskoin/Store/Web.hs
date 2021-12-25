{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# OPTIONS_GHC -Wno-deprecations #-}

module Haskoin.Store.Web (
    -- * Web
    WebConfig (..),
    Except (..),
    WebLimits (..),
    WebTimeouts (..),
    runWeb,
) where

import Conduit (
    ConduitT,
    await,
    concatMapC,
    concatMapMC,
    dropC,
    dropWhileC,
    headC,
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
import Control.Monad (
    forM_,
    forever,
    join,
    unless,
    when,
    (<=<),
 )
import Control.Monad.Logger (
    MonadLoggerIO,
    logDebugS,
    logErrorS,
    logWarnS,
 )
import Control.Monad.Reader (
    ReaderT,
    asks,
    local,
    runReaderT,
 )
import Control.Monad.Trans (lift)
import Control.Monad.Trans.Control (liftWith, restoreT)
import Control.Monad.Trans.Maybe (
    MaybeT (..),
    runMaybeT,
 )
import Data.Aeson (
    Encoding,
    ToJSON (..),
    Value,
 )
import qualified Data.Aeson as A
import Data.Aeson.Encode.Pretty (
    Config (..),
    defConfig,
    encodePretty',
 )
import Data.Aeson.Encoding (
    encodingToLazyByteString,
    list,
 )
import Data.Aeson.Text (encodeToLazyText)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Base16 as B16
import Data.ByteString.Builder (lazyByteString)
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Lazy as L
import Data.Bytes.Get
import Data.Bytes.Put
import Data.Bytes.Serial
import Data.Char (isSpace)
import Data.Default (Default (..))
import Data.Function ((&))
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import Data.HashSet (HashSet)
import qualified Data.HashSet as HashSet
import Data.Int (Int64)
import Data.List (nub)
import Data.Maybe (
    catMaybes,
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
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Text.Lazy (toStrict)
import qualified Data.Text.Lazy as TL
import Data.Time.Clock (diffUTCTime)
import Data.Time.Clock.System (
    getSystemTime,
    systemSeconds,
    systemToUTCTime,
 )
import qualified Data.Vault.Lazy as V
import Data.Word (Word32, Word64)
import Database.RocksDB (
    Property (..),
    getProperty,
 )
import Haskoin.Address
import qualified Haskoin.Block as H
import Haskoin.Constants
import Haskoin.Data
import Haskoin.Keys
import Haskoin.Network
import Haskoin.Node (
    Chain,
    OnlinePeer (..),
    PeerManager,
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
import NQE (
    Inbox,
    Publisher,
    receive,
    withSubscription,
 )
import Network.HTTP.Types (
    Status (..),
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
import Network.Wai (
    Middleware,
    Request (..),
    Response,
    getRequestBodyChunk,
    responseLBS,
    responseStatus,
 )
import Network.Wai.Handler.Warp (
    defaultSettings,
    setHost,
    setPort,
 )
import Network.Wai.Handler.WebSockets (websocketsOr)
import Network.Wai.Middleware.RequestSizeLimit
import Network.WebSockets (
    ServerApp,
    acceptRequest,
    defaultConnectionOptions,
    pendingRequest,
    rejectRequestWith,
    requestPath,
    sendTextData,
 )
import qualified Network.WebSockets as WebSockets
import qualified Network.Wreq as Wreq
import Network.Wreq.Session as Wreq (Session)
import qualified Network.Wreq.Session as Wreq.Session
import System.IO.Unsafe (unsafeInterleaveIO)
import qualified System.Metrics as Metrics
import qualified System.Metrics.Gauge as Metrics (Gauge)
import qualified System.Metrics.Gauge as Metrics.Gauge
import UnliftIO (
    MonadIO,
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
import qualified Web.Scotty.Trans as S

type WebT m = ActionT Except (ReaderT WebState m)

data WebLimits = WebLimits
    { maxLimitCount :: !Word32
    , maxLimitFull :: !Word32
    , maxLimitOffset :: !Word32
    , maxLimitDefault :: !Word32
    , maxLimitGap :: !Word32
    , maxLimitInitialGap :: !Word32
    , maxLimitBody :: !Word32
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
            , maxLimitBody = 1024 * 1024
            }

data WebConfig = WebConfig
    { webHost :: !String
    , webPort :: !Int
    , webStore :: !Store
    , webMaxDiff :: !Int
    , webMaxPending :: !Int
    , webMaxLimits :: !WebLimits
    , webTimeouts :: !WebTimeouts
    , webVersion :: !String
    , webNoMempool :: !Bool
    , webStats :: !(Maybe Metrics.Store)
    , webPriceGet :: !Int
    , webTickerURL :: !String
    , webHistoryURL :: !String
    }

data WebState = WebState
    { webConfig :: !WebConfig
    , webTicker :: !(TVar (HashMap Text BinfoTicker))
    , webMetrics :: !(Maybe WebMetrics)
    , webWreqSession :: !Wreq.Session
    }

data WebMetrics = WebMetrics
    { statAll :: !StatDist
    , -- Addresses
      statAddressTransactions :: !StatDist
    , statAddressTransactionsFull :: !StatDist
    , statAddressBalance :: !StatDist
    , statAddressUnspent :: !StatDist
    , statXpub :: !StatDist
    , statXpubDelete :: !StatDist
    , statXpubTransactionsFull :: !StatDist
    , statXpubTransactions :: !StatDist
    , statXpubBalances :: !StatDist
    , statXpubUnspent :: !StatDist
    , -- Transactions
      statTransaction :: !StatDist
    , statTransactionRaw :: !StatDist
    , statTransactionAfter :: !StatDist
    , statTransactionsBlock :: !StatDist
    , statTransactionsBlockRaw :: !StatDist
    , statTransactionPost :: !StatDist
    , statMempool :: !StatDist
    , -- Blocks
      statBlock :: !StatDist
    , statBlockRaw :: !StatDist
    , -- Blockchain
      statBlockchainMultiaddr :: !StatDist
    , statBlockchainBalance :: !StatDist
    , statBlockchainRawaddr :: !StatDist
    , statBlockchainUnspent :: !StatDist
    , statBlockchainRawtx :: !StatDist
    , statBlockchainRawblock :: !StatDist
    , statBlockchainMempool :: !StatDist
    , statBlockchainBlockHeight :: !StatDist
    , statBlockchainBlocks :: !StatDist
    , statBlockchainLatestblock :: !StatDist
    , statBlockchainExportHistory :: !StatDist
    , -- Blockchain /q endpoints
      statBlockchainQaddresstohash :: !StatDist
    , statBlockchainQhashtoaddress :: !StatDist
    , statBlockchainQaddrpubkey :: !StatDist
    , statBlockchainQpubkeyaddr :: !StatDist
    , statBlockchainQhashpubkey :: !StatDist
    , statBlockchainQgetblockcount :: !StatDist
    , statBlockchainQlatesthash :: !StatDist
    , statBlockchainQbcperblock :: !StatDist
    , statBlockchainQtxtotalbtcoutput :: !StatDist
    , statBlockchainQtxtotalbtcinput :: !StatDist
    , statBlockchainQtxfee :: !StatDist
    , statBlockchainQtxresult :: !StatDist
    , statBlockchainQgetreceivedbyaddress :: !StatDist
    , statBlockchainQgetsentbyaddress :: !StatDist
    , statBlockchainQaddressbalance :: !StatDist
    , statBlockchainQaddressfirstseen :: !StatDist
    , -- Others
      statHealth :: !StatDist
    , statPeers :: !StatDist
    , statDbstats :: !StatDist
    , statEvents :: !Metrics.Gauge.Gauge
    , -- Request
      statKey :: !(V.Key (TVar (Maybe (WebMetrics -> StatDist))))
    }

createMetrics :: MonadIO m => Metrics.Store -> m WebMetrics
createMetrics s = liftIO $ do
    statAll <- d "all"

    -- Addresses
    statAddressTransactions <- d "address_transactions"
    statAddressTransactionsFull <- d "address_transactions_full"
    statAddressBalance <- d "address_balance"
    statAddressUnspent <- d "address_unspent"
    statXpub <- d "xpub"
    statXpubDelete <- d "xpub_delete"
    statXpubTransactionsFull <- d "xpub_transactions_full"
    statXpubTransactions <- d "xpub_transactions"
    statXpubBalances <- d "xpub_balances"
    statXpubUnspent <- d "xpub_unspent"

    -- Transactions
    statTransaction <- d "transaction"
    statTransactionRaw <- d "transaction_raw"
    statTransactionAfter <- d "transaction_after"
    statTransactionPost <- d "transaction_post"
    statTransactionsBlock <- d "transactions_block"
    statTransactionsBlockRaw <- d "transactions_block_raw"
    statMempool <- d "mempool"

    -- Blocks
    statBlockBest <- d "block_best"
    statBlockLatest <- d "block_latest"
    statBlock <- d "block"
    statBlockRaw <- d "block_raw"
    statBlockHeight <- d "block_height"
    statBlockHeightRaw <- d "block_height_raw"
    statBlockTime <- d "block_time"
    statBlockTimeRaw <- d "block_time_raw"
    statBlockMtp <- d "block_mtp"
    statBlockMtpRaw <- d "block_mtp_raw"

    -- Blockchain
    statBlockchainMultiaddr <- d "blockchain_multiaddr"
    statBlockchainBalance <- d "blockchain_balance"
    statBlockchainRawaddr <- d "blockchain_rawaddr"
    statBlockchainUnspent <- d "blockchain_unspent"
    statBlockchainRawtx <- d "blockchain_rawtx"
    statBlockchainRawblock <- d "blockchain_rawblock"
    statBlockchainLatestblock <- d "blockchain_latestblock"
    statBlockchainMempool <- d "blockchain_mempool"
    statBlockchainBlockHeight <- d "blockchain_block_height"
    statBlockchainBlocks <- d "blockchain_blocks"
    statBlockchainExportHistory <- d "blockchain_export_history"

    -- Blockchain /q endpoints
    statBlockchainQaddresstohash <- d "blockchain_q_addresstohash"
    statBlockchainQhashtoaddress <- d "blockchain_q_hashtoaddress"
    statBlockchainQaddrpubkey <- d "blockckhain_q_addrpubkey"
    statBlockchainQpubkeyaddr <- d "blockchain_q_pubkeyaddr"
    statBlockchainQhashpubkey <- d "blockchain_q_hashpubkey"
    statBlockchainQgetblockcount <- d "blockchain_q_getblockcount"
    statBlockchainQlatesthash <- d "blockchain_q_latesthash"
    statBlockchainQbcperblock <- d "blockchain_q_bcperblock"
    statBlockchainQtxtotalbtcoutput <- d "blockchain_q_txtotalbtcoutput"
    statBlockchainQtxtotalbtcinput <- d "blockchain_q_txtotalbtcinput"
    statBlockchainQtxfee <- d "blockchain_q_txfee"
    statBlockchainQtxresult <- d "blockchain_q_txresult"
    statBlockchainQgetreceivedbyaddress <- d "blockchain_q_getreceivedbyaddress"
    statBlockchainQgetsentbyaddress <- d "blockchain_q_getsentbyaddress"
    statBlockchainQaddressbalance <- d "blockchain_q_addressbalance"
    statBlockchainQaddressfirstseen <- d "blockchain_q_addressfirstseen"

    -- Others
    statHealth <- d "health"
    statPeers <- d "peers"
    statDbstats <- d "dbstats"

    statEvents <- g "events_connected"
    statKey <- V.newKey
    return WebMetrics{..}
  where
    d x = createStatDist ("web_" <> x) s
    g x = Metrics.createGauge ("web_" <> x) s

withGaugeIO :: MonadUnliftIO m => Metrics.Gauge -> m a -> m a
withGaugeIO g =
    bracket_
        (liftIO $ Metrics.Gauge.inc g)
        (liftIO $ Metrics.Gauge.dec g)

withGaugeIncrease ::
    MonadUnliftIO m =>
    (WebMetrics -> Metrics.Gauge) ->
    WebT m a ->
    WebT m a
withGaugeIncrease gf go =
    lift (asks webMetrics) >>= \case
        Nothing -> go
        Just m -> do
            s <- liftWith $ \run -> withGaugeIO (gf m) (run go)
            restoreT $ return s

setMetrics :: MonadUnliftIO m => (WebMetrics -> StatDist) -> WebT m ()
setMetrics df =
    asks webMetrics >>= mapM_ go
  where
    go m = do
        req <- S.request
        let t = fromMaybe e $ V.lookup (statKey m) (vault req)
        atomically $ writeTVar t (Just df)
    e = error "the ways of the warrior are yet to be mastered"

addItemCount :: MonadUnliftIO m => Int -> WebT m ()
addItemCount i =
    asks webMetrics >>= mapM_ \m ->
        addStatItems (statAll m) (fromIntegral i)
            >> S.request >>= \req ->
                forM_ (V.lookup (statKey m) (vault req)) \t ->
                    readTVarIO t >>= mapM_ \s ->
                        addStatItems (s m) (fromIntegral i)

data WebTimeouts = WebTimeouts
    { txTimeout :: !Word64
    , blockTimeout :: !Word64
    }
    deriving (Eq, Show)

data SerialAs = SerialAsBinary | SerialAsJSON | SerialAsPrettyJSON
    deriving (Eq, Show)

instance Default WebTimeouts where
    def = WebTimeouts{txTimeout = 300, blockTimeout = 7200}

instance
    (MonadUnliftIO m, MonadLoggerIO m) =>
    StoreReadBase (ReaderT WebState m)
    where
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
runWeb
    cfg@WebConfig
        { webHost = host
        , webPort = port
        , webStore = store'
        , webStats = stats
        , webPriceGet = pget
        , webTickerURL = turl
        , webMaxLimits = WebLimits{..}
        } = do
        ticker <- newTVarIO HashMap.empty
        metrics <- mapM createMetrics stats
        session <- liftIO Wreq.Session.newAPISession
        let st =
                WebState
                    { webConfig = cfg
                    , webTicker = ticker
                    , webMetrics = metrics
                    , webWreqSession = session
                    }
            net = storeNetwork store'
        withAsync (price net session turl pget ticker) $
            const $ do
                reqLogger <- logIt metrics
                runner <- askRunInIO
                S.scottyOptsT opts (runner . (`runReaderT` st)) $ do
                    S.middleware (webSocketEvents st)
                    S.middleware reqLogger
                    S.middleware (reqSizeLimit maxLimitBody)
                    S.defaultHandler defHandler
                    handlePaths
                    S.notFound $ raise ThingNotFound
      where
        opts = def{S.settings = settings defaultSettings}
        settings = setPort port . setHost (fromString host)

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
            & Wreq.param "base" .~ [T.toUpper (T.pack (getNetworkName net))]
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

raise :: MonadIO m => Except -> WebT m a
raise err =
    lift (asks webMetrics) >>= \case
        Nothing -> S.raise err
        Just m -> do
            req <- S.request
            mM <- case V.lookup (statKey m) (vault req) of
                Nothing -> return Nothing
                Just t -> readTVarIO t
            let status = errStatus err
            if
                    | statusIsClientError status ->
                        liftIO $ do
                            addClientError (statAll m)
                            forM_ mM $ \f -> addClientError (f m)
                    | statusIsServerError status ->
                        liftIO $ do
                            addServerError (statAll m)
                            forM_ mM $ \f -> addServerError (f m)
                    | otherwise ->
                        return ()
            S.raise err

errStatus :: Except -> Status
errStatus ThingNotFound = status404
errStatus BadRequest = status400
errStatus UserError{} = status400
errStatus StringError{} = status400
errStatus ServerError = status500
errStatus TxIndexConflict{} = status409
errStatus ServerTimeout = status500
errStatus RequestTooLarge = status413

defHandler :: Monad m => Except -> WebT m ()
defHandler e = do
    setHeaders
    S.status $ errStatus e
    S.json e

handlePaths ::
    (MonadUnliftIO m, MonadLoggerIO m) =>
    S.ScottyT Except (ReaderT WebState m) ()
handlePaths = do
    -- Block Paths
    pathCompact
        (GetBlock <$> paramLazy <*> paramDef)
        scottyBlock
        blockDataToEncoding
        blockDataToJSON
    pathCompact
        (GetBlocks <$> param <*> paramDef)
        (fmap SerialList . scottyBlocks)
        (\n -> list (blockDataToEncoding n) . getSerialList)
        (\n -> json_list blockDataToJSON n . getSerialList)
    pathCompact
        (GetBlockRaw <$> paramLazy)
        scottyBlockRaw
        (const toEncoding)
        (const toJSON)
    pathCompact
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
        (fmap SerialList . scottyBlockLatest)
        (\n -> list (blockDataToEncoding n) . getSerialList)
        (\n -> json_list blockDataToJSON n . getSerialList)
    pathCompact
        (GetBlockHeight <$> paramLazy <*> paramDef)
        (fmap SerialList . scottyBlockHeight)
        (\n -> list (blockDataToEncoding n) . getSerialList)
        (\n -> json_list blockDataToJSON n . getSerialList)
    pathCompact
        (GetBlockHeights <$> param <*> paramDef)
        (fmap SerialList . scottyBlockHeights)
        (\n -> list (blockDataToEncoding n) . getSerialList)
        (\n -> json_list blockDataToJSON n . getSerialList)
    pathCompact
        (GetBlockHeightRaw <$> paramLazy)
        scottyBlockHeightRaw
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetBlockTime <$> paramLazy <*> paramDef)
        scottyBlockTime
        blockDataToEncoding
        blockDataToJSON
    pathCompact
        (GetBlockTimeRaw <$> paramLazy)
        scottyBlockTimeRaw
        (const toEncoding)
        (const toJSON)
    pathCompact
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
    pathCompact
        (GetTx <$> paramLazy)
        scottyTx
        transactionToEncoding
        transactionToJSON
    pathCompact
        (GetTxs <$> param)
        (fmap SerialList . scottyTxs)
        (\n -> list (transactionToEncoding n) . getSerialList)
        (\n -> json_list transactionToJSON n . getSerialList)
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
        (fmap SerialList . scottyTxsBlock)
        (\n -> list (transactionToEncoding n) . getSerialList)
        (\n -> json_list transactionToJSON n . getSerialList)
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
    pathCompact
        (GetMempool <$> paramOptional <*> parseOffset)
        (fmap SerialList . scottyMempool)
        (const toEncoding)
        (const toJSON)
    -- Address Paths
    pathCompact
        (GetAddrTxs <$> paramLazy <*> parseLimits)
        (fmap SerialList . scottyAddrTxs)
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetAddrsTxs <$> param <*> parseLimits)
        (fmap SerialList . scottyAddrsTxs)
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetAddrTxsFull <$> paramLazy <*> parseLimits)
        (fmap SerialList . scottyAddrTxsFull)
        (\n -> list (transactionToEncoding n) . getSerialList)
        (\n -> json_list transactionToJSON n . getSerialList)
    pathCompact
        (GetAddrsTxsFull <$> param <*> parseLimits)
        (fmap SerialList . scottyAddrsTxsFull)
        (\n -> list (transactionToEncoding n) . getSerialList)
        (\n -> json_list transactionToJSON n . getSerialList)
    pathCompact
        (GetAddrBalance <$> paramLazy)
        scottyAddrBalance
        balanceToEncoding
        balanceToJSON
    pathCompact
        (GetAddrsBalance <$> param)
        (fmap SerialList . scottyAddrsBalance)
        (\n -> list (balanceToEncoding n) . getSerialList)
        (\n -> json_list balanceToJSON n . getSerialList)
    pathCompact
        (GetAddrUnspent <$> paramLazy <*> parseLimits)
        (fmap SerialList . scottyAddrUnspent)
        (\n -> list (unspentToEncoding n) . getSerialList)
        (\n -> json_list unspentToJSON n . getSerialList)
    pathCompact
        (GetAddrsUnspent <$> param <*> parseLimits)
        (fmap SerialList . scottyAddrsUnspent)
        (\n -> list (unspentToEncoding n) . getSerialList)
        (\n -> json_list unspentToJSON n . getSerialList)
    -- XPubs
    pathCompact
        (GetXPub <$> paramLazy <*> paramDef <*> paramDef)
        scottyXPub
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetXPubTxs <$> paramLazy <*> paramDef <*> parseLimits <*> paramDef)
        (fmap SerialList . scottyXPubTxs)
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetXPubTxsFull <$> paramLazy <*> paramDef <*> parseLimits <*> paramDef)
        (fmap SerialList . scottyXPubTxsFull)
        (\n -> list (transactionToEncoding n) . getSerialList)
        (\n -> json_list transactionToJSON n . getSerialList)
    pathCompact
        (GetXPubBalances <$> paramLazy <*> paramDef <*> paramDef)
        (fmap SerialList . scottyXPubBalances)
        (\n -> list (xPubBalToEncoding n) . getSerialList)
        (\n -> json_list xPubBalToJSON n . getSerialList)
    pathCompact
        (GetXPubUnspent <$> paramLazy <*> paramDef <*> parseLimits <*> paramDef)
        (fmap SerialList . scottyXPubUnspent)
        (\n -> list (xPubUnspentToEncoding n) . getSerialList)
        (\n -> json_list xPubUnspentToJSON n . getSerialList)
    pathCompact
        (DelCachedXPub <$> paramLazy <*> paramDef)
        scottyDelXPub
        (const toEncoding)
        (const toJSON)
    -- Network
    pathCompact
        (GetPeers & return)
        (fmap SerialList . scottyPeers)
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetHealth & return)
        scottyHealth
        (const toEncoding)
        (const toJSON)
    S.get "/events" scottyEvents
    S.get "/dbstats" scottyDbStats
    -- Blockchain.info
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
    json_list f net = toJSONList . map (f net)

pathCompact ::
    (ApiResource a b, MonadIO m) =>
    WebT m a ->
    (a -> WebT m b) ->
    (Network -> b -> Encoding) ->
    (Network -> b -> Value) ->
    S.ScottyT Except (ReaderT WebState m) ()
pathCompact parser action encJson encValue =
    pathCommon parser action encJson encValue False

pathCommon ::
    (ApiResource a b, MonadIO m) =>
    WebT m a ->
    (a -> WebT m b) ->
    (Network -> b -> Encoding) ->
    (Network -> b -> Value) ->
    Bool ->
    S.ScottyT Except (ReaderT WebState m) ()
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

streamEncoding :: Monad m => Encoding -> WebT m ()
streamEncoding e = do
    S.setHeader "Content-Type" "application/json; charset=utf-8"
    S.raw (encodingToLazyByteString e)

protoSerial ::
    Serial a =>
    SerialAs ->
    (a -> Encoding) ->
    (a -> Value) ->
    a ->
    L.ByteString
protoSerial SerialAsBinary _ _ = runPutL . serialize
protoSerial SerialAsJSON f _ = encodingToLazyByteString . f
protoSerial SerialAsPrettyJSON _ g =
    encodePretty' defConfig{confTrailingNewline = True} . g

setHeaders :: (Monad m, S.ScottyError e) => ActionT e m ()
setHeaders = S.setHeader "Access-Control-Allow-Origin" "*"

waiExcept :: Status -> Except -> Response
waiExcept s e =
    responseLBS s hs e'
  where
    hs =
        [ ("Access-Control-Allow-Origin", "*")
        , ("Content-Type", "application/json")
        ]
    e' = A.encode e

setupJSON :: Monad m => Bool -> ActionT Except m SerialAs
setupJSON pretty = do
    S.setHeader "Content-Type" "application/json"
    p <- S.param "pretty" `S.rescue` const (return pretty)
    return $ if p then SerialAsPrettyJSON else SerialAsJSON

setupBinary :: Monad m => ActionT Except m SerialAs
setupBinary = do
    S.setHeader "Content-Type" "application/octet-stream"
    return SerialAsBinary

setupContentType :: Monad m => Bool -> ActionT Except m SerialAs
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
    setMetrics statBlock
    getBlock h >>= \case
        Nothing ->
            raise ThingNotFound
        Just b -> do
            addItemCount 1
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
    setMetrics statBlock
    bs <- getBlocks hs notx
    addItemCount (length bs)
    return bs

pruneTx :: Bool -> BlockData -> BlockData
pruneTx False b = b
pruneTx True b = b{blockDataTxs = take 1 (blockDataTxs b)}

-- GET BlockRaw --

scottyBlockRaw ::
    (MonadUnliftIO m, MonadLoggerIO m) =>
    GetBlockRaw ->
    WebT m (RawResult H.Block)
scottyBlockRaw (GetBlockRaw h) = do
    setMetrics statBlockRaw
    b <- getRawBlock h
    addItemCount 1
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
    let ths = blockDataTxs b
    txs <- mapM f ths
    return H.Block{H.blockHeader = blockDataHeader b, H.blockTxns = txs}
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
    setMetrics statBlock
    getBestBlock >>= \case
        Nothing -> raise ThingNotFound
        Just bb ->
            getBlock bb >>= \case
                Nothing -> raise ThingNotFound
                Just b -> do
                    addItemCount 1
                    return $ pruneTx notx b

scottyBlockBestRaw ::
    (MonadUnliftIO m, MonadLoggerIO m) =>
    GetBlockBestRaw ->
    WebT m (RawResult H.Block)
scottyBlockBestRaw _ = do
    setMetrics statBlockRaw
    getBestBlock >>= \case
        Nothing -> raise ThingNotFound
        Just bb -> do
            b <- getRawBlock bb
            addItemCount 1
            return $ RawResult b

-- GET BlockLatest --

scottyBlockLatest ::
    (MonadUnliftIO m, MonadLoggerIO m) =>
    GetBlockLatest ->
    WebT m [BlockData]
scottyBlockLatest (GetBlockLatest (NoTx noTx)) = do
    setMetrics statBlock
    blocks <-
        getBestBlock
            >>= maybe
                (raise ThingNotFound)
                (go [] <=< getBlock)
    addItemCount (length blocks)
    return blocks
  where
    go acc Nothing = return $ reverse acc
    go acc (Just b)
        | blockDataHeight b <= 0 = return $ reverse acc
        | length acc == 99 = return . reverse $ pruneTx noTx b : acc
        | otherwise = do
            let prev = H.prevBlock (blockDataHeader b)
            go (pruneTx noTx b : acc) =<< getBlock prev

-- GET BlockHeight / BlockHeights / BlockHeightRaw --

scottyBlockHeight ::
    (MonadUnliftIO m, MonadLoggerIO m) => GetBlockHeight -> WebT m [BlockData]
scottyBlockHeight (GetBlockHeight h (NoTx notx)) = do
    setMetrics statBlock
    blocks <- (`getBlocks` notx) =<< getBlocksAtHeight (fromIntegral h)
    addItemCount (length blocks)
    return blocks

scottyBlockHeights ::
    (MonadUnliftIO m, MonadLoggerIO m) =>
    GetBlockHeights ->
    WebT m [BlockData]
scottyBlockHeights (GetBlockHeights (HeightsParam heights) (NoTx notx)) = do
    setMetrics statBlock
    bhs <- concat <$> mapM getBlocksAtHeight (fromIntegral <$> heights)
    blocks <- getBlocks bhs notx
    addItemCount (length blocks)
    return blocks

scottyBlockHeightRaw ::
    (MonadUnliftIO m, MonadLoggerIO m) =>
    GetBlockHeightRaw ->
    WebT m (RawResultList H.Block)
scottyBlockHeightRaw (GetBlockHeightRaw h) = do
    setMetrics statBlockRaw
    blocks <- mapM getRawBlock =<< getBlocksAtHeight (fromIntegral h)
    addItemCount (length blocks)
    return $ RawResultList blocks

-- GET BlockTime / BlockTimeRaw --

scottyBlockTime ::
    (MonadUnliftIO m, MonadLoggerIO m) =>
    GetBlockTime ->
    WebT m BlockData
scottyBlockTime (GetBlockTime (TimeParam t) (NoTx notx)) = do
    setMetrics statBlock
    ch <- lift $ asks (storeChain . webStore . webConfig)
    blockAtOrBefore ch t >>= \case
        Nothing -> raise ThingNotFound
        Just b -> do
            addItemCount 1
            return $ pruneTx notx b

scottyBlockMTP ::
    (MonadUnliftIO m, MonadLoggerIO m) =>
    GetBlockMTP ->
    WebT m BlockData
scottyBlockMTP (GetBlockMTP (TimeParam t) (NoTx notx)) = do
    setMetrics statBlock
    ch <- lift $ asks (storeChain . webStore . webConfig)
    blockAtOrAfterMTP ch t >>= \case
        Nothing -> raise ThingNotFound
        Just b -> do
            addItemCount 1
            return $ pruneTx notx b

scottyBlockTimeRaw ::
    (MonadUnliftIO m, MonadLoggerIO m) =>
    GetBlockTimeRaw ->
    WebT m (RawResult H.Block)
scottyBlockTimeRaw (GetBlockTimeRaw (TimeParam t)) = do
    setMetrics statBlockRaw
    ch <- lift $ asks (storeChain . webStore . webConfig)
    blockAtOrBefore ch t >>= \case
        Nothing -> raise ThingNotFound
        Just b -> do
            raw <- lift $ toRawBlock b
            addItemCount 1
            return $ RawResult raw

scottyBlockMTPRaw ::
    (MonadUnliftIO m, MonadLoggerIO m) =>
    GetBlockMTPRaw ->
    WebT m (RawResult H.Block)
scottyBlockMTPRaw (GetBlockMTPRaw (TimeParam t)) = do
    setMetrics statBlockRaw
    ch <- lift $ asks (storeChain . webStore . webConfig)
    blockAtOrAfterMTP ch t >>= \case
        Nothing -> raise ThingNotFound
        Just b -> do
            raw <- lift $ toRawBlock b
            addItemCount 1
            return $ RawResult raw

-- GET Transactions --

scottyTx :: (MonadUnliftIO m, MonadLoggerIO m) => GetTx -> WebT m Transaction
scottyTx (GetTx txid) = do
    setMetrics statTransaction
    getTransaction txid >>= \case
        Nothing -> raise ThingNotFound
        Just tx -> do
            addItemCount 1
            return tx

scottyTxs ::
    (MonadUnliftIO m, MonadLoggerIO m) => GetTxs -> WebT m [Transaction]
scottyTxs (GetTxs txids) = do
    setMetrics statTransaction
    txs <- catMaybes <$> mapM f (nub txids)
    addItemCount (length txs)
    return txs
  where
    f x = lift $
        withRunInIO $ \run ->
            unsafeInterleaveIO . run $
                getTransaction x

scottyTxRaw ::
    (MonadUnliftIO m, MonadLoggerIO m) => GetTxRaw -> WebT m (RawResult Tx)
scottyTxRaw (GetTxRaw txid) = do
    setMetrics statTransactionRaw
    getTransaction txid >>= \case
        Nothing -> raise ThingNotFound
        Just tx -> do
            addItemCount 1
            return $ RawResult (transactionData tx)

scottyTxsRaw ::
    (MonadUnliftIO m, MonadLoggerIO m) =>
    GetTxsRaw ->
    WebT m (RawResultList Tx)
scottyTxsRaw (GetTxsRaw txids) = do
    setMetrics statTransactionRaw
    txs <- catMaybes <$> mapM f (nub txids)
    addItemCount (length txs)
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
            txs <- mapM f (blockDataTxs b)
            addItemCount (length txs)
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
    setMetrics statTransactionsBlock
    txs <- getTxsBlock h
    addItemCount (length txs)
    return txs

scottyTxsBlockRaw ::
    (MonadUnliftIO m, MonadLoggerIO m) =>
    GetTxsBlockRaw ->
    WebT m (RawResultList Tx)
scottyTxsBlockRaw (GetTxsBlockRaw h) = do
    setMetrics statTransactionsBlockRaw
    txs <- fmap transactionData <$> getTxsBlock h
    addItemCount (length txs)
    return $ RawResultList txs

-- GET TransactionAfterHeight --

scottyTxAfter ::
    (MonadUnliftIO m, MonadLoggerIO m) =>
    GetTxAfter ->
    WebT m (GenericResult (Maybe Bool))
scottyTxAfter (GetTxAfter txid height) = do
    setMetrics statTransactionAfter
    (result, count) <- cbAfterHeight (fromIntegral height) txid
    addItemCount count
    return $ GenericResult result

{- | Check if any of the ancestors of this transaction is a coinbase after the
 specified height. Returns 'Nothing' if answer cannot be computed before
 hitting limits.
-}
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
    cb_check = any isCoinbase . transactionInputs
    ins = HashSet.fromList . map (outPointHash . inputPoint) . transactionInputs
    height_check tx =
        case transactionBlock tx of
            BlockRef h _ -> h > height
            _ -> True

-- POST Transaction --

scottyPostTx :: (MonadUnliftIO m, MonadLoggerIO m) => PostTx -> WebT m TxId
scottyPostTx (PostTx tx) = do
    setMetrics statTransactionPost
    addItemCount 1
    lift (asks webConfig) >>= \cfg ->
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
    pub = storePublisher (webStore cfg)
    mgr = storeManager (webStore cfg)
    net = storeNetwork (webStore cfg)
    go s =
        getPeers mgr >>= \case
            [] -> return $ Left PubNoPeers
            OnlinePeer{onlinePeerMailbox = p} : _ -> do
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
scottyMempool (GetMempool limitM (OffsetParam o)) = do
    setMetrics statMempool
    wl <- lift $ asks (webMaxLimits . webConfig)
    let wl' = wl{maxLimitCount = 0}
        l = Limits (validateLimit wl' False limitM) (fromIntegral o) Nothing
    ths <- map snd . applyLimits l <$> getMempool
    addItemCount (length ths)
    return ths

webSocketEvents :: WebState -> Middleware
webSocketEvents s =
    websocketsOr defaultConnectionOptions events
  where
    pub = (storePublisher . webStore . webConfig) s
    gauge = statEvents <$> webMetrics s
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
                        { WebSockets.rejectBody = L.toStrict $ A.encode ThingNotFound
                        , WebSockets.rejectCode = 404
                        , WebSockets.rejectMessage = "Not Found"
                        , WebSockets.rejectHeaders = [("Content-Type", "application/json")]
                        }

scottyEvents :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyEvents =
    withGaugeIncrease statEvents $ do
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
    setMetrics statAddressTransactions
    txs <- getAddressTxs addr =<< paramToLimits False pLimits
    addItemCount (length txs)
    return txs

scottyAddrsTxs ::
    (MonadUnliftIO m, MonadLoggerIO m) => GetAddrsTxs -> WebT m [TxRef]
scottyAddrsTxs (GetAddrsTxs addrs pLimits) = do
    setMetrics statAddressTransactions
    txs <- getAddressesTxs addrs =<< paramToLimits False pLimits
    addItemCount (length txs)
    return txs

scottyAddrTxsFull ::
    (MonadUnliftIO m, MonadLoggerIO m) =>
    GetAddrTxsFull ->
    WebT m [Transaction]
scottyAddrTxsFull (GetAddrTxsFull addr pLimits) = do
    setMetrics statAddressTransactionsFull
    txs <- getAddressTxs addr =<< paramToLimits True pLimits
    ts <- catMaybes <$> mapM (getTransaction . txRefHash) txs
    addItemCount (length ts)
    return ts

scottyAddrsTxsFull ::
    (MonadUnliftIO m, MonadLoggerIO m) =>
    GetAddrsTxsFull ->
    WebT m [Transaction]
scottyAddrsTxsFull (GetAddrsTxsFull addrs pLimits) = do
    setMetrics statAddressTransactionsFull
    txs <- getAddressesTxs addrs =<< paramToLimits True pLimits
    ts <- catMaybes <$> mapM (getTransaction . txRefHash) txs
    addItemCount (length ts)
    return ts

scottyAddrBalance ::
    (MonadUnliftIO m, MonadLoggerIO m) =>
    GetAddrBalance ->
    WebT m Balance
scottyAddrBalance (GetAddrBalance addr) = do
    setMetrics statAddressBalance
    addItemCount 1
    getDefaultBalance addr

scottyAddrsBalance ::
    (MonadUnliftIO m, MonadLoggerIO m) => GetAddrsBalance -> WebT m [Balance]
scottyAddrsBalance (GetAddrsBalance addrs) = do
    setMetrics statAddressBalance
    balances <- getBalances addrs
    addItemCount (length balances)
    return balances

scottyAddrUnspent ::
    (MonadUnliftIO m, MonadLoggerIO m) => GetAddrUnspent -> WebT m [Unspent]
scottyAddrUnspent (GetAddrUnspent addr pLimits) = do
    setMetrics statAddressUnspent
    unspents <- getAddressUnspents addr =<< paramToLimits False pLimits
    addItemCount (length unspents)
    return unspents

scottyAddrsUnspent ::
    (MonadUnliftIO m, MonadLoggerIO m) => GetAddrsUnspent -> WebT m [Unspent]
scottyAddrsUnspent (GetAddrsUnspent addrs pLimits) = do
    setMetrics statAddressUnspent
    unspents <- getAddressesUnspents addrs =<< paramToLimits False pLimits
    addItemCount (length unspents)
    return unspents

-- GET XPubs --

scottyXPub ::
    (MonadUnliftIO m, MonadLoggerIO m) => GetXPub -> WebT m XPubSummary
scottyXPub (GetXPub xpub deriv (NoCache noCache)) = do
    setMetrics statXpub
    let xspec = XPubSpec xpub deriv
    xbals <- lift . runNoCache noCache $ xPubBals xspec
    addItemCount (length xbals)
    return $ xPubSummary xspec xbals

scottyDelXPub ::
    (MonadUnliftIO m, MonadLoggerIO m) =>
    DelCachedXPub ->
    WebT m (GenericResult Bool)
scottyDelXPub (DelCachedXPub xpub deriv) = do
    setMetrics statXpubDelete
    let xspec = XPubSpec xpub deriv
    cacheM <- lift (asks (storeCache . webStore . webConfig))
    n <- lift $ withCache cacheM (cacheDelXPubs [xspec])
    addItemCount (fromIntegral n)
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
    txs <- lift . runNoCache nocache $ xPubTxs xspec xbals limits
    addItemCount (length txs)
    return txs

scottyXPubTxs ::
    (MonadUnliftIO m, MonadLoggerIO m) => GetXPubTxs -> WebT m [TxRef]
scottyXPubTxs (GetXPubTxs xpub deriv plimits (NoCache nocache)) = do
    setMetrics statXpubTransactions
    txs <- getXPubTxs xpub deriv plimits nocache
    addItemCount (length txs)
    return txs

scottyXPubTxsFull ::
    (MonadUnliftIO m, MonadLoggerIO m) =>
    GetXPubTxsFull ->
    WebT m [Transaction]
scottyXPubTxsFull (GetXPubTxsFull xpub deriv plimits (NoCache nocache)) = do
    setMetrics statXpubTransactionsFull
    refs <- getXPubTxs xpub deriv plimits nocache
    txs <-
        fmap catMaybes $
            lift . runNoCache nocache $
                mapM (getTransaction . txRefHash) refs
    addItemCount (length txs)
    return txs

scottyXPubBalances ::
    (MonadUnliftIO m, MonadLoggerIO m) => GetXPubBalances -> WebT m [XPubBal]
scottyXPubBalances (GetXPubBalances xpub deriv (NoCache noCache)) = do
    setMetrics statXpubBalances
    balances <- filter f <$> lift (runNoCache noCache (xPubBals spec))
    addItemCount (length balances)
    return balances
  where
    spec = XPubSpec xpub deriv
    f = not . nullBalance . xPubBal

scottyXPubUnspent ::
    (MonadUnliftIO m, MonadLoggerIO m) =>
    GetXPubUnspent ->
    WebT m [XPubUnspent]
scottyXPubUnspent (GetXPubUnspent xpub deriv pLimits (NoCache noCache)) = do
    setMetrics statXpubUnspent
    limits <- paramToLimits False pLimits
    let xspec = XPubSpec xpub deriv
    xbals <- xPubBals xspec
    unspents <- lift . runNoCache noCache $ xPubUnspents xspec xbals limits
    addItemCount (length unspents)
    return unspents

---------------------------------------
-- Blockchain.info API Compatibility --
---------------------------------------

netBinfoSymbol :: Network -> BinfoSymbol
netBinfoSymbol net
    | net == btc =
        BinfoSymbol
            { getBinfoSymbolCode = "BTC"
            , getBinfoSymbolString = "BTC"
            , getBinfoSymbolName = "Bitcoin"
            , getBinfoSymbolConversion = 100 * 1000 * 1000
            , getBinfoSymbolAfter = True
            , getBinfoSymbolLocal = False
            }
    | net == bch =
        BinfoSymbol
            { getBinfoSymbolCode = "BCH"
            , getBinfoSymbolString = "BCH"
            , getBinfoSymbolName = "Bitcoin Cash"
            , getBinfoSymbolConversion = 100 * 1000 * 1000
            , getBinfoSymbolAfter = True
            , getBinfoSymbolLocal = False
            }
    | otherwise =
        BinfoSymbol
            { getBinfoSymbolCode = "XTS"
            , getBinfoSymbolString = "¤"
            , getBinfoSymbolName = "Test"
            , getBinfoSymbolConversion = 100 * 1000 * 1000
            , getBinfoSymbolAfter = False
            , getBinfoSymbolLocal = False
            }

binfoTickerToSymbol :: Text -> BinfoTicker -> BinfoSymbol
binfoTickerToSymbol code BinfoTicker{..} =
    BinfoSymbol
        { getBinfoSymbolCode = code
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
        x -> x

getBinfoAddrsParam ::
    MonadIO m =>
    Text ->
    WebT m (HashSet BinfoAddr)
getBinfoAddrsParam name = do
    net <- lift (asks (storeNetwork . webStore . webConfig))
    p <- S.param (cs name) `S.rescue` const (return "")
    if T.null p
        then return HashSet.empty
        else case parseBinfoAddr net p of
            Nothing -> raise (UserError "invalid address")
            Just xs -> return $ HashSet.fromList xs

getBinfoActive ::
    MonadIO m =>
    WebT m (HashMap XPubKey XPubSpec, HashSet Address)
getBinfoActive = do
    active <- getBinfoAddrsParam "active"
    p2sh <- getBinfoAddrsParam "activeP2SH"
    bech32 <- getBinfoAddrsParam "activeBech32"
    let xspec d b = (\x -> (x, XPubSpec x d)) <$> xpub b
        xspecs =
            HashMap.fromList $
                concat
                    [ mapMaybe (xspec DeriveNormal) (HashSet.toList active)
                    , mapMaybe (xspec DeriveP2SH) (HashSet.toList p2sh)
                    , mapMaybe (xspec DeriveP2WPKH) (HashSet.toList bech32)
                    ]
        addrs = HashSet.fromList . mapMaybe addr $ HashSet.toList active
    return (xspecs, addrs)
  where
    addr (BinfoAddr a) = Just a
    addr (BinfoXpub _) = Nothing
    xpub (BinfoXpub x) = Just x
    xpub (BinfoAddr _) = Nothing

getNumTxId :: MonadIO m => WebT m Bool
getNumTxId = fmap not $ S.param "txidindex" `S.rescue` const (return False)

getChainHeight :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m H.BlockHeight
getChainHeight = do
    ch <- lift $ asks (storeChain . webStore . webConfig)
    H.nodeHeight <$> chainGetBest ch

scottyBinfoUnspent :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoUnspent =
    setMetrics statBlockchainUnspent
        >> getBinfoActive >>= \(xspecs, addrs) ->
            getNumTxId >>= \numtxid ->
                get_limit >>= \limit ->
                    get_min_conf >>= \min_conf -> do
                        let len = HashSet.size addrs + HashMap.size xspecs
                        net <- lift $ asks (storeNetwork . webStore . webConfig)
                        height <- getChainHeight
                        let mn BinfoUnspent{..} = min_conf > getBinfoUnspentConfirmations
                            xspecs' = HashSet.fromList $ HashMap.elems xspecs
                        bus <-
                            lift . runConduit $
                                getBinfoUnspents numtxid height xspecs' addrs
                                    .| (dropWhileC mn >> takeC limit .| sinkList)
                        setHeaders
                        addItemCount (length bus)
                        streamEncoding (binfoUnspentsToEncoding net (BinfoUnspents bus))
  where
    get_limit = fmap (min 1000) $ S.param "limit" `S.rescue` const (return 250)
    get_min_conf = S.param "confirmations" `S.rescue` const (return 0)

getBinfoUnspents ::
    (StoreReadExtra m, MonadIO m) =>
    Bool ->
    H.BlockHeight ->
    HashSet XPubSpec ->
    HashSet Address ->
    ConduitT () BinfoUnspent m ()
getBinfoUnspents numtxid height xspecs addrs = do
    cs' <- conduits
    joinDescStreams cs' .| mapC (uncurry binfo)
  where
    binfo Unspent{..} xp =
        let conf = case unspentBlock of
                MemRef{} -> 0
                BlockRef h _ -> height - h + 1
            hash = outPointHash unspentPoint
            idx = outPointIndex unspentPoint
            val = unspentAmount
            script = unspentScript
            txi = encodeBinfoTxId numtxid hash
         in BinfoUnspent
                { getBinfoUnspentHash = hash
                , getBinfoUnspentOutputIndex = idx
                , getBinfoUnspentScript = script
                , getBinfoUnspentValue = val
                , getBinfoUnspentConfirmations = fromIntegral conf
                , getBinfoUnspentTxIndex = txi
                , getBinfoUnspentXPub = xp
                }
    conduits = (<>) <$> xconduits <*> pure acounduits
    xconduits = lift $ do
        let f x (XPubUnspent u p) =
                let path = toSoft (listToPath p)
                    xp = BinfoXPubPath (xPubSpecKey x) <$> path
                 in (u, xp)
            g x = do
                bs <- xPubBals x
                return $
                    streamThings
                        (xPubUnspents x bs)
                        Nothing
                        def{limit = 250}
                        .| mapC (f x)
        mapM g (HashSet.toList xspecs)
    acounduits =
        let f u = (u, Nothing)
            g a =
                streamThings
                    (getAddressUnspents a)
                    Nothing
                    def{limit = 250}
                    .| mapC f
         in map g (HashSet.toList addrs)

getBinfoTxs ::
    (StoreReadExtra m, MonadIO m) =>
    HashMap Address (Maybe BinfoXPubPath) -> -- address book
    HashSet XPubSpec -> -- show xpubs
    HashSet Address -> -- show addrs
    HashSet Address -> -- balance addresses
    BinfoFilter ->
    Bool -> -- numtxid
    Bool -> -- prune outputs
    Int64 -> -- starting balance
    ConduitT () BinfoTx m ()
getBinfoTxs abook sxspecs saddrs baddrs bfilter numtxid prune bal = do
    cs' <- conduits
    joinDescStreams cs' .| go bal
  where
    sxspecs_ls = HashSet.toList sxspecs
    saddrs_ls = HashSet.toList saddrs
    conduits = (<>) <$> mapM xpub_c sxspecs_ls <*> pure (map addr_c saddrs_ls)
    xpub_c x = lift $ do
        bs <- xPubBals x
        return $ streamThings (xPubTxs x bs) (Just txRefHash) def{limit = 50}
    addr_c a = streamThings (getAddressTxs a) (Just txRefHash) def{limit = 50}
    binfo_tx b = toBinfoTx numtxid abook prune b
    compute_bal_change BinfoTx{..} =
        let ins = map getBinfoTxInputPrevOut getBinfoTxInputs
            out = getBinfoTxOutputs
            f b BinfoTxOutput{..} =
                let val = fromIntegral getBinfoTxOutputValue
                 in case getBinfoTxOutputAddress of
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
                            c = isJust (getBinfoTxBlockHeight a)
                            Just (d, _) = getBinfoTxResultBal a
                            r = d + fromIntegral (getBinfoTxFee a)
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

getCashAddr :: Monad m => WebT m Bool
getCashAddr = S.param "cashaddr" `S.rescue` const (return False)

getAddress :: (Monad m, MonadUnliftIO m) => TL.Text -> WebT m Address
getAddress param' = do
    txt <- S.param param'
    net <- lift $ asks (storeNetwork . webStore . webConfig)
    case textToAddr net txt of
        Nothing -> raise ThingNotFound
        Just a -> return a

getBinfoAddr :: Monad m => TL.Text -> WebT m BinfoAddr
getBinfoAddr param' = do
    txt <- S.param param'
    net <- lift $ asks (storeNetwork . webStore . webConfig)
    let x =
            BinfoAddr <$> textToAddr net txt
                <|> BinfoXpub <$> xPubImport net txt
    maybe S.next return x

scottyBinfoHistory :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoHistory =
    setMetrics statBlockchainExportHistory
        >> getBinfoActive >>= \(xspecs, addrs) ->
            get_dates >>= \(startM, endM) -> do
                (code, price') <- getPrice
                xpubs <- mapM (\x -> (,) x <$> xPubBals x) (HashMap.elems xspecs)
                let xaddrs = HashSet.fromList $ concatMap (map get_addr . snd) xpubs
                    aaddrs = xaddrs <> addrs
                    cur = binfoTicker15m price'
                    cs' = conduits xpubs addrs endM
                txs <-
                    lift . runConduit $
                        joinDescStreams cs'
                            .| takeWhileC (is_newer startM)
                            .| concatMapMC get_transaction
                            .| sinkList
                let times = map transactionTime txs
                net <- lift $ asks (storeNetwork . webStore . webConfig)
                url <- lift $ asks (webHistoryURL . webConfig)
                session <- lift $ asks webWreqSession
                rates <- map binfoRatePrice <$> lift (getRates net session url code times)
                let hs = zipWith (convert cur aaddrs) txs (rates <> repeat 0.0)
                setHeaders
                addItemCount (length hs)
                streamEncoding $ toEncoding hs
  where
    is_newer (Just BlockData{..}) TxRef{txRefBlock = BlockRef{..}} =
        blockRefHeight >= blockDataHeight
    is_newer _ _ = True
    get_addr = balanceAddress . xPubBal
    get_transaction TxRef{txRefHash = h} =
        getTransaction h
    convert cur addrs tx rate =
        let ins = transactionInputs tx
            outs = transactionOutputs tx
            fins = filter (input_addr addrs) ins
            fouts = filter (output_addr addrs) outs
            vin = fromIntegral . sum $ map inputAmount fins
            vout = fromIntegral . sum $ map outputAmount fouts
            v = vout - vin
            t = transactionTime tx
            h = txHash $ transactionData tx
         in toBinfoHistory v t rate cur h
    input_addr addrs' StoreInput{inputAddress = Just a} =
        a `HashSet.member` addrs'
    input_addr _ _ = False
    output_addr addrs' StoreOutput{outputAddr = Just a} =
        a `HashSet.member` addrs'
    output_addr _ _ = False
    get_dates = do
        BinfoDate start <- S.param "start"
        BinfoDate end' <- S.param "end"
        let end = end' + 24 * 60 * 60
        ch <- lift $ asks (storeChain . webStore . webConfig)
        startM <- blockAtOrAfter ch start
        endM <- blockAtOrBefore ch end
        return (startM, endM)
    conduits xpubs addrs endM =
        map (uncurry (xpub_c endM)) xpubs
            <> map (addr_c endM) (HashSet.toList addrs)
    addr_c endM a =
        streamThings
            (getAddressTxs a)
            (Just txRefHash)
            def
                { limit = 50
                , start = AtBlock . blockDataHeight <$> endM
                }
    xpub_c endM x bs =
        streamThings
            (xPubTxs x bs)
            (Just txRefHash)
            def
                { limit = 50
                , start = AtBlock . blockDataHeight <$> endM
                }

getPrice :: MonadIO m => WebT m (Text, BinfoTicker)
getPrice = do
    code <- T.toUpper <$> S.param "currency" `S.rescue` const (return "USD")
    ticker <- lift $ asks webTicker
    prices <- readTVarIO ticker
    case HashMap.lookup code prices of
        Nothing -> return (code, def)
        Just p -> return (code, p)

getSymbol :: MonadIO m => WebT m BinfoSymbol
getSymbol = uncurry binfoTickerToSymbol <$> getPrice

scottyBinfoBlocksDay :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoBlocksDay = do
    setMetrics statBlockchainBlocks
    t <- min h . (`div` 1000) <$> S.param "milliseconds"
    ch <- lift $ asks (storeChain . webStore . webConfig)
    m <- blockAtOrBefore ch t
    bs <- go (d t) m
    addItemCount (length bs)
    streamEncoding $ toEncoding $ map toBinfoBlockInfo bs
  where
    h = fromIntegral (maxBound :: H.Timestamp)
    d = subtract (24 * 3600)
    go _ Nothing = return []
    go t (Just b)
        | H.blockTimestamp (blockDataHeader b) <= fromIntegral t =
            return []
        | otherwise = do
            b' <- getBlock (H.prevBlock (blockDataHeader b))
            (b :) <$> go t b'

scottyMultiAddr :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyMultiAddr = do
    setMetrics statBlockchainMultiaddr
    (addrs', _, saddrs, sxpubs, xspecs) <- get_addrs
    numtxid <- getNumTxId
    cashaddr <- getCashAddr
    local' <- getSymbol
    offset <- getBinfoOffset
    n <- getBinfoCount "n"
    prune <- get_prune
    fltr <- get_filter
    xbals <- get_xbals xspecs
    xtxns <- get_xpub_tx_count xbals xspecs
    let sxbals = subset sxpubs xbals
        xabals = compute_xabals xbals
        addrs = addrs' `HashSet.difference` HashMap.keysSet xabals
    abals <- get_abals addrs
    let sxspecs = compute_sxspecs sxpubs xspecs
        sxabals = compute_xabals sxbals
        sabals = subset saddrs abals
        sallbals = sabals <> sxabals
        sbal = compute_bal sallbals
        allbals = abals <> xabals
        abook = compute_abook addrs xbals
        sxaddrs = compute_xaddrs sxbals
        salladdrs = saddrs <> sxaddrs
        bal = compute_bal allbals
    let ibal = fromIntegral sbal
    ftxs <-
        lift . runConduit $
            getBinfoTxs abook sxspecs saddrs salladdrs fltr numtxid prune ibal
                .| (dropC offset >> takeC n .| sinkList)
    best <- get_best_block
    peers <- get_peers
    net <- lift $ asks (storeNetwork . webStore . webConfig)
    let baddrs = toBinfoAddrs sabals sxbals xtxns
        abaddrs = toBinfoAddrs abals xbals xtxns
        recv = sum $ map getBinfoAddrReceived abaddrs
        sent' = sum $ map getBinfoAddrSent abaddrs
        txn = fromIntegral $ length ftxs
        wallet =
            BinfoWallet
                { getBinfoWalletBalance = bal
                , getBinfoWalletTxCount = txn
                , getBinfoWalletFilteredCount = txn
                , getBinfoWalletTotalReceived = recv
                , getBinfoWalletTotalSent = sent'
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
                , getBinfoLocal = local'
                , getBinfoBTC = coin
                , getBinfoLatestBlock = block
                }
    setHeaders
    addItemCount (length abook + length ftxs)
    streamEncoding $
        binfoMultiAddrToEncoding
            net
            BinfoMultiAddr
                { getBinfoMultiAddrAddresses = baddrs
                , getBinfoMultiAddrWallet = wallet
                , getBinfoMultiAddrTxs = ftxs
                , getBinfoMultiAddrInfo = info
                , getBinfoMultiAddrRecommendFee = True
                , getBinfoMultiAddrCashAddr = cashaddr
                }
  where
    get_xpub_tx_count xbals =
        let f (k, s) =
                case HashMap.lookup k xbals of
                    Nothing -> return (k, 0)
                    Just bs -> do
                        n <- xPubTxCount s bs
                        return (k, fromIntegral n)
         in fmap HashMap.fromList . mapM f . HashMap.toList
    get_filter = S.param "filter" `S.rescue` const (return BinfoFilterAll)
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
    subset ks =
        HashMap.filterWithKey (\k _ -> k `HashSet.member` ks)
    compute_sxspecs sxpubs =
        HashSet.fromList . HashMap.elems . subset sxpubs
    addr (BinfoAddr a) = Just a
    addr (BinfoXpub _) = Nothing
    xpub (BinfoXpub x) = Just x
    xpub (BinfoAddr _) = Nothing
    get_addrs = do
        (xspecs, addrs) <- getBinfoActive
        sh <- getBinfoAddrsParam "onlyShow"
        let xpubs = HashMap.keysSet xspecs
            actives =
                HashSet.map BinfoAddr addrs
                    <> HashSet.map BinfoXpub xpubs
            sh' = if HashSet.null sh then actives else sh
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
    get_peers = do
        ps <-
            lift $
                getPeersInformation
                    =<< asks (storeManager . webStore . webConfig)
        return (fromIntegral (length ps))
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
            amap =
                HashMap.map (const Nothing) $
                    HashSet.toMap addrs
            xmap =
                HashMap.fromList
                    . concatMap (uncurry g)
                    $ HashMap.toList xbals
         in amap <> xmap
    compute_xaddrs =
        let f = map (balanceAddress . xPubBal)
         in HashSet.fromList . concatMap f . HashMap.elems

getBinfoCount :: (MonadUnliftIO m, MonadLoggerIO m) => TL.Text -> WebT m Int
getBinfoCount str = do
    d <- lift (asks (maxLimitDefault . webMaxLimits . webConfig))
    x <- lift (asks (maxLimitFull . webMaxLimits . webConfig))
    i <- min x <$> (S.param str `S.rescue` const (return d))
    return (fromIntegral i :: Int)

getBinfoOffset ::
    (MonadUnliftIO m, MonadLoggerIO m) =>
    WebT m Int
getBinfoOffset = do
    x <- lift (asks (maxLimitOffset . webMaxLimits . webConfig))
    o <- S.param "offset" `S.rescue` const (return 0)
    when (o > x) $
        raise $
            UserError $ "offset exceeded: " <> show o <> " > " <> show x
    return (fromIntegral o :: Int)

scottyRawAddr :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyRawAddr =
    setMetrics statBlockchainRawaddr
        >> getBinfoAddr "addr" >>= \case
            BinfoAddr addr -> do_addr addr
            BinfoXpub xpub -> do_xpub xpub
  where
    do_xpub xpub = do
        numtxid <- getNumTxId
        derive <- S.param "derive" `S.rescue` const (return DeriveNormal)
        let xspec = XPubSpec xpub derive
        n <- getBinfoCount "limit"
        off <- getBinfoOffset
        xbals <- xPubBals xspec
        net <- lift $ asks (storeNetwork . webStore . webConfig)
        let summary = xPubSummary xspec xbals
            abook = compute_abook xpub xbals
            xspecs = HashSet.singleton xspec
            saddrs = HashSet.empty
            baddrs = HashMap.keysSet abook
            bfilter = BinfoFilterAll
            amnt =
                xPubSummaryConfirmed summary
                    + xPubSummaryZero summary
        txs <-
            lift . runConduit $
                getBinfoTxs
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
                    { binfoRawAddr = BinfoXpub xpub
                    , binfoRawBalance = amnt
                    , binfoRawTxCount = fromIntegral $ length txs
                    , binfoRawUnredeemed = xPubUnspentCount summary
                    , binfoRawReceived = xPubSummaryReceived summary
                    , binfoRawSent =
                        fromIntegral (xPubSummaryReceived summary)
                            - fromIntegral amnt
                    , binfoRawTxs = txs
                    }
        setHeaders
        addItemCount (length abook + length txs)
        streamEncoding $ binfoRawAddrToEncoding net ra
    compute_abook xpub xbals =
        let f XPubBal{..} =
                let a = balanceAddress xPubBal
                    e = error "black hole swallows all your code"
                    s = toSoft (listToPath xPubBalPath)
                    m = fromMaybe e s
                 in (a, Just (BinfoXPubPath xpub m))
         in HashMap.fromList $ map f xbals
    do_addr addr = do
        numtxid <- getNumTxId
        n <- getBinfoCount "limit"
        off <- getBinfoOffset
        bal <- fromMaybe (zeroBalance addr) <$> getBalance addr
        net <- lift $ asks (storeNetwork . webStore . webConfig)
        let abook = HashMap.singleton addr Nothing
            xspecs = HashSet.empty
            saddrs = HashSet.singleton addr
            bfilter = BinfoFilterAll
            amnt = balanceAmount bal + balanceZero bal
        txs <-
            lift . runConduit $
                getBinfoTxs
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
                    { binfoRawAddr = BinfoAddr addr
                    , binfoRawBalance = amnt
                    , binfoRawTxCount = balanceTxCount bal
                    , binfoRawUnredeemed = balanceUnspentCount bal
                    , binfoRawReceived = balanceTotalReceived bal
                    , binfoRawSent =
                        fromIntegral (balanceTotalReceived bal)
                            - fromIntegral amnt
                    , binfoRawTxs = txs
                    }
        setHeaders
        addItemCount (1 + length txs)
        streamEncoding $ binfoRawAddrToEncoding net ra

scottyBinfoReceived :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoReceived = do
    setMetrics statBlockchainQgetreceivedbyaddress
    a <- getAddress "addr"
    b <- fromMaybe (zeroBalance a) <$> getBalance a
    setHeaders
    addItemCount 1
    S.text . cs . show $ balanceTotalReceived b

scottyBinfoSent :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoSent = do
    setMetrics statBlockchainQgetsentbyaddress
    a <- getAddress "addr"
    b <- fromMaybe (zeroBalance a) <$> getBalance a
    setHeaders
    addItemCount 1
    S.text . cs . show $ balanceTotalReceived b - balanceAmount b - balanceZero b

scottyBinfoAddrBalance :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoAddrBalance = do
    setMetrics statBlockchainQaddressbalance
    a <- getAddress "addr"
    b <- fromMaybe (zeroBalance a) <$> getBalance a
    setHeaders
    addItemCount 1
    S.text . cs . show $ balanceAmount b + balanceZero b

scottyFirstSeen :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyFirstSeen = do
    setMetrics statBlockchainQaddressfirstseen
    a <- getAddress "addr"
    ch <- lift $ asks (storeChain . webStore . webConfig)
    bb <- chainGetBest ch
    let top = H.nodeHeight bb
        bot = 0
    i <- go ch bb a bot top
    setHeaders
    addItemCount 1
    S.text . cs $ show i
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
        H.blockTimestamp . H.nodeHeader . fromJust
            <$> chainGetAncestor h bb ch
    hasone a h = do
        let l = Limits 1 0 (Just (AtBlock h))
        not . null <$> getAddressTxs a l

scottyShortBal :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyShortBal = do
    setMetrics statBlockchainBalance
    (xspecs, addrs) <- getBinfoActive
    cashaddr <- getCashAddr
    net <- lift $ asks (storeNetwork . webStore . webConfig)
    abals <-
        catMaybes
            <$> mapM (get_addr_balance net cashaddr) (HashSet.toList addrs)
    xbals <- mapM (get_xspec_balance net) (HashMap.elems xspecs)
    let res = HashMap.fromList (abals <> xbals)
    setHeaders
    addItemCount (length abals)
    streamEncoding $ toEncoding res
  where
    to_short_bal Balance{..} =
        BinfoShortBal
            { binfoShortBalFinal = balanceAmount + balanceZero
            , binfoShortBalTxCount = balanceTxCount
            , binfoShortBalReceived = balanceTotalReceived
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
    is_ext XPubBal{xPubBalPath = 0 : _} = True
    is_ext _ = False
    get_xspec_balance net xpub = do
        xbals <- xPubBals xpub
        xts <- xPubTxCount xpub xbals
        let val = sum $ map (balanceAmount . xPubBal) xbals
            zro = sum $ map (balanceZero . xPubBal) xbals
            exs = filter is_ext xbals
            rcv = sum $ map (balanceTotalReceived . xPubBal) exs
            sbl =
                BinfoShortBal
                    { binfoShortBalFinal = val + zro
                    , binfoShortBalTxCount = fromIntegral xts
                    , binfoShortBalReceived = rcv
                    }
        addItemCount (length xbals)
        return (xPubExport net (xPubSpecKey xpub), sbl)

getBinfoHex :: Monad m => WebT m Bool
getBinfoHex =
    (== ("hex" :: Text))
        <$> S.param "format" `S.rescue` const (return "json")

scottyBinfoBlockHeight :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoBlockHeight =
    getNumTxId >>= \numtxid ->
        S.param "height" >>= \height ->
            setMetrics statBlockchainBlockHeight
                >> getBlocksAtHeight height >>= \block_hashes -> do
                    block_headers <- catMaybes <$> mapM getBlock block_hashes
                    next_block_hashes <- getBlocksAtHeight (height + 1)
                    next_block_headers <- catMaybes <$> mapM getBlock next_block_hashes
                    binfo_blocks <-
                        mapM (get_binfo_blocks numtxid next_block_headers) block_headers
                    setHeaders
                    net <- lift $ asks (storeNetwork . webStore . webConfig)
                    addItemCount (length binfo_blocks)
                    streamEncoding $ binfoBlocksToEncoding net binfo_blocks
  where
    get_tx th =
        withRunInIO $ \run ->
            unsafeInterleaveIO $
                run $ fromJust <$> getTransaction th
    get_binfo_blocks numtxid next_block_headers block_header = do
        let my_hash = H.headerHash (blockDataHeader block_header)
            get_prev = H.prevBlock . blockDataHeader
            get_hash = H.headerHash . blockDataHeader
        txs <- lift $ mapM get_tx (blockDataTxs block_header)
        addItemCount (length txs)
        let next_blocks =
                map get_hash $
                    filter
                        ((== my_hash) . get_prev)
                        next_block_headers
        let binfo_txs = map (toBinfoTxSimple numtxid) txs
            binfo_block = toBinfoBlock block_header binfo_txs next_blocks
        return binfo_block

scottyBinfoLatest :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoLatest = do
    numtxid <- getNumTxId
    setMetrics statBlockchainLatestblock
    best <- get_best_block
    let binfoTxIndices = map (encodeBinfoTxId numtxid) (blockDataTxs best)
        binfoHeaderHash = H.headerHash (blockDataHeader best)
        binfoHeaderTime = H.blockTimestamp (blockDataHeader best)
        binfoHeaderIndex = binfoHeaderTime
        binfoHeaderHeight = blockDataHeight best
    addItemCount 1
    streamEncoding $ toEncoding BinfoHeader{..}
  where
    get_best_block =
        getBestBlock >>= \case
            Nothing -> raise ThingNotFound
            Just bh ->
                getBlock bh >>= \case
                    Nothing -> raise ThingNotFound
                    Just b -> return b

scottyBinfoBlock :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoBlock =
    getNumTxId >>= \numtxid ->
        getBinfoHex >>= \hex ->
            setMetrics statBlockchainRawblock
                >> S.param "block" >>= \case
                    BinfoBlockHash bh -> go numtxid hex bh
                    BinfoBlockIndex i ->
                        getBlocksAtHeight i >>= \case
                            [] -> raise ThingNotFound
                            bh : _ -> go numtxid hex bh
  where
    get_tx th =
        withRunInIO $ \run ->
            unsafeInterleaveIO $
                run $ fromJust <$> getTransaction th
    go numtxid hex bh =
        getBlock bh >>= \case
            Nothing -> raise ThingNotFound
            Just b -> do
                txs <- lift $ mapM get_tx (blockDataTxs b)
                let my_hash = H.headerHash (blockDataHeader b)
                    get_prev = H.prevBlock . blockDataHeader
                    get_hash = H.headerHash . blockDataHeader
                nxt_headers <-
                    fmap catMaybes $
                        mapM getBlock
                            =<< getBlocksAtHeight (blockDataHeight b + 1)
                let nxt =
                        map get_hash $
                            filter
                                ((== my_hash) . get_prev)
                                nxt_headers
                if hex
                    then do
                        let x = H.Block (blockDataHeader b) (map transactionData txs)
                        setHeaders
                        S.text . encodeHexLazy . runPutL $ serialize x
                    else do
                        let btxs = map (toBinfoTxSimple numtxid) txs
                            y = toBinfoBlock b btxs nxt
                        setHeaders
                        net <- lift $ asks (storeNetwork . webStore . webConfig)
                        addItemCount (length btxs + 1)
                        streamEncoding $ binfoBlockToEncoding net y

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
    setMetrics statBlockchainRawtx
    tx <-
        getBinfoTx txid >>= \case
            Right t -> return t
            Left e -> raise e
    addItemCount 1
    if hex then hx tx else js numtxid tx
  where
    js numtxid t = do
        net <- lift $ asks (storeNetwork . webStore . webConfig)
        setHeaders
        streamEncoding $ binfoTxToEncoding net $ toBinfoTxSimple numtxid t
    hx t = do
        setHeaders
        S.text . encodeHexLazy . runPutL . serialize $ transactionData t

scottyBinfoTotalOut :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoTotalOut = do
    txid <- S.param "txid"
    setMetrics statBlockchainQtxtotalbtcoutput
    tx <-
        getBinfoTx txid >>= \case
            Right t -> return t
            Left e -> raise e
    addItemCount 1
    S.text . cs . show . sum . map outputAmount $ transactionOutputs tx

scottyBinfoTxFees :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoTxFees = do
    txid <- S.param "txid"
    setMetrics statBlockchainQtxfee
    tx <-
        getBinfoTx txid >>= \case
            Right t -> return t
            Left e -> raise e
    let i =
            sum . map inputAmount . filter f $
                transactionInputs tx
        o = sum . map outputAmount $ transactionOutputs tx
    addItemCount 1
    S.text . cs . show $ i - o
  where
    f StoreInput{} = True
    f StoreCoinbase{} = False

scottyBinfoTxResult :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoTxResult = do
    txid <- S.param "txid"
    addr <- getAddress "addr"
    setMetrics statBlockchainQtxresult
    tx <-
        getBinfoTx txid >>= \case
            Right t -> return t
            Left e -> raise e
    let i =
            toInteger . sum . map inputAmount . filter (f addr) $
                transactionInputs tx
        o =
            toInteger . sum . map outputAmount . filter (g addr) $
                transactionOutputs tx
    addItemCount 1
    S.text . cs . show $ o - i
  where
    f addr StoreInput{inputAddress = Just a} = a == addr
    f _ _ = False
    g addr StoreOutput{outputAddr = Just a} = a == addr
    g _ _ = False

scottyBinfoTotalInput :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoTotalInput = do
    txid <- S.param "txid"
    setMetrics statBlockchainQtxtotalbtcinput
    tx <-
        getBinfoTx txid >>= \case
            Right t -> return t
            Left e -> raise e
    addItemCount 1
    S.text . cs . show . sum . map inputAmount . filter f $ transactionInputs tx
  where
    f StoreInput{} = True
    f StoreCoinbase{} = False

scottyBinfoMempool :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoMempool = do
    setMetrics statBlockchainMempool
    numtxid <- getNumTxId
    offset <- getBinfoOffset
    n <- getBinfoCount "limit"
    mempool <- getMempool
    let txids = map snd $ take n $ drop offset mempool
    txs <- catMaybes <$> mapM getTransaction txids
    net <- lift $ asks (storeNetwork . webStore . webConfig)
    setHeaders
    let mem = BinfoMempool $ map (toBinfoTxSimple numtxid) txs
    addItemCount (length txs)
    streamEncoding $ binfoMempoolToEncoding net mem

scottyBinfoGetBlockCount :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoGetBlockCount = do
    setMetrics statBlockchainQgetblockcount
    ch <- asks (storeChain . webStore . webConfig)
    bn <- chainGetBest ch
    setHeaders
    addItemCount 1
    S.text . cs . show $ H.nodeHeight bn

scottyBinfoLatestHash :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoLatestHash = do
    setMetrics statBlockchainQlatesthash
    ch <- asks (storeChain . webStore . webConfig)
    bn <- chainGetBest ch
    setHeaders
    addItemCount 1
    S.text . TL.fromStrict . H.blockHashToHex . H.headerHash $ H.nodeHeader bn

scottyBinfoSubsidy :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoSubsidy = do
    setMetrics statBlockchainQbcperblock
    ch <- asks (storeChain . webStore . webConfig)
    net <- asks (storeNetwork . webStore . webConfig)
    bn <- chainGetBest ch
    setHeaders
    addItemCount 1
    S.text . cs . show . (/ (100 * 1000 * 1000 :: Double)) . fromIntegral $
        H.computeSubsidy net (H.nodeHeight bn + 1)

scottyBinfoAddrToHash :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoAddrToHash = do
    setMetrics statBlockchainQaddresstohash
    addr <- getAddress "addr"
    setHeaders
    addItemCount 1
    S.text . encodeHexLazy . runPutL . serialize $ getAddrHash160 addr

scottyBinfoHashToAddr :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoHashToAddr = do
    setMetrics statBlockchainQhashtoaddress
    bs <- maybe S.next return . decodeHex =<< S.param "hash"
    net <- asks (storeNetwork . webStore . webConfig)
    hash <- either (const S.next) return (decode bs)
    addr <- maybe S.next return (addrToText net (PubKeyAddress hash))
    setHeaders
    addItemCount 1
    S.text $ TL.fromStrict addr

scottyBinfoAddrPubkey :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoAddrPubkey = do
    setMetrics statBlockchainQaddrpubkey
    hex <- S.param "pubkey"
    pubkey <-
        maybe S.next (return . pubKeyAddr) $
            eitherToMaybe . runGetS deserialize =<< decodeHex hex
    net <- lift $ asks (storeNetwork . webStore . webConfig)
    setHeaders
    case addrToText net pubkey of
        Nothing -> raise ThingNotFound
        Just a -> do
            addItemCount 1
            S.text $ TL.fromStrict a

scottyBinfoPubKeyAddr :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoPubKeyAddr = do
    setMetrics statBlockchainQpubkeyaddr
    addr <- getAddress "addr"
    mi <- strm addr
    i <- case mi of
        Nothing -> raise ThingNotFound
        Just i -> return i
    pk <- case extr addr i of
        Left e -> raise $ UserError e
        Right t -> return t
    setHeaders
    addItemCount 1
    S.text $ encodeHexLazy $ L.fromStrict pk
  where
    strm addr =
        runConduit $
            streamThings (getAddressTxs addr) (Just txRefHash) def{limit = 50}
                .| concatMapMC (getTransaction . txRefHash)
                .| concatMapC (filter (inp addr) . transactionInputs)
                .| headC
    inp addr StoreInput{inputAddress = Just a} = a == addr
    inp _ _ = False
    extr addr StoreInput{inputSigScript, inputPkScript, inputWitness} = do
        Script sig <- decode inputSigScript
        Script pks <- decode inputPkScript
        case addr of
            PubKeyAddress{} ->
                case sig of
                    [OP_PUSHDATA _ _, OP_PUSHDATA pub _] ->
                        Right pub
                    [OP_PUSHDATA _ _] ->
                        case pks of
                            [OP_PUSHDATA pub _, OP_CHECKSIG] ->
                                Right pub
                            _ -> Left "Could not parse scriptPubKey"
                    _ -> Left "Could not parse scriptSig"
            WitnessPubKeyAddress{} ->
                case inputWitness of
                    [_, pub] -> return pub
                    _ -> Left "Could not parse scriptPubKey"
            _ -> Left "Address does not have public key"
    extr _ _ = Left "Incorrect input type"

scottyBinfoHashPubkey :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoHashPubkey = do
    setMetrics statBlockchainQhashpubkey
    pkm <- (eitherToMaybe . runGetS deserialize <=< decodeHex) <$> S.param "pubkey"
    addr <- case pkm of
        Nothing -> raise $ UserError "Could not decode public key"
        Just pk -> return $ pubKeyAddr pk
    setHeaders
    addItemCount 1
    S.text . encodeHexLazy . runPutL . serialize $ getAddrHash160 addr

-- GET Network Information --

scottyPeers ::
    (MonadUnliftIO m, MonadLoggerIO m) =>
    GetPeers ->
    WebT m [PeerInformation]
scottyPeers _ = do
    setMetrics statPeers
    ps <-
        lift $
            getPeersInformation
                =<< asks (storeManager . webStore . webConfig)
    addItemCount (length ps)
    return ps

-- | Obtain information about connected peers from peer manager process.
getPeersInformation ::
    MonadLoggerIO m => PeerManager -> m [PeerInformation]
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
scottyHealth _ = do
    setMetrics statHealth
    h <- lift $ asks webConfig >>= healthCheck
    unless (isOK h) $ S.status status503
    addItemCount 1
    return h

blockHealthCheck ::
    (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m) =>
    WebConfig ->
    m BlockHealth
blockHealthCheck cfg = do
    let ch = storeChain $ webStore cfg
        blockHealthMaxDiff = fromIntegral $ webMaxDiff cfg
    blockHealthHeaders <-
        H.nodeHeight <$> chainGetBest ch
    blockHealthBlocks <-
        maybe 0 blockDataHeight
            <$> runMaybeT (MaybeT getBestBlock >>= MaybeT . getBlock)
    return BlockHealth{..}

lastBlockHealthCheck ::
    (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m) =>
    Chain ->
    WebTimeouts ->
    m TimeHealth
lastBlockHealthCheck ch tos = do
    n <- fromIntegral . systemSeconds <$> liftIO getSystemTime
    t <- fromIntegral . H.blockTimestamp . H.nodeHeader <$> chainGetBest ch
    let timeHealthAge = n - t
        timeHealthMax = fromIntegral $ blockTimeout tos
    return TimeHealth{..}

lastTxHealthCheck ::
    (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m) =>
    WebConfig ->
    m TimeHealth
lastTxHealthCheck WebConfig{..} = do
    n <- fromIntegral . systemSeconds <$> liftIO getSystemTime
    b <- fromIntegral . H.blockTimestamp . H.nodeHeader <$> chainGetBest ch
    t <-
        getMempool >>= \case
            t : _ ->
                let x = fromIntegral $ fst t
                 in return $ max x b
            [] -> return b
    let timeHealthAge = n - t
        timeHealthMax = fromIntegral to
    return TimeHealth{..}
  where
    ch = storeChain webStore
    to =
        if webNoMempool
            then blockTimeout webTimeouts
            else txTimeout webTimeouts

pendingTxsHealthCheck ::
    (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m) =>
    WebConfig ->
    m MaxHealth
pendingTxsHealthCheck cfg = do
    let maxHealthMax = fromIntegral $ webMaxPending cfg
    maxHealthNum <-
        fromIntegral
            <$> blockStorePendingTxs (storeBlock (webStore cfg))
    return MaxHealth{..}

peerHealthCheck ::
    (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m) =>
    PeerManager ->
    m CountHealth
peerHealthCheck mgr = do
    let countHealthMin = 1
    countHealthNum <- fromIntegral . length <$> getPeers mgr
    return CountHealth{..}

healthCheck ::
    (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m) =>
    WebConfig ->
    m HealthCheck
healthCheck cfg@WebConfig{..} = do
    healthBlocks <- blockHealthCheck cfg
    healthLastBlock <- lastBlockHealthCheck (storeChain webStore) webTimeouts
    healthLastTx <- lastTxHealthCheck cfg
    healthPendingTxs <- pendingTxsHealthCheck cfg
    healthPeers <- peerHealthCheck (storeManager webStore)
    let healthNetwork = getNetworkName (storeNetwork webStore)
        healthVersion = webVersion
        hc = HealthCheck{..}
    unless (isOK hc) $ do
        let t = toStrict $ encodeToLazyText hc
        $(logErrorS) "Web" $ "Health check failed: " <> t
    return hc

scottyDbStats :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyDbStats = do
    setMetrics statDbstats
    setHeaders
    db <- lift $ asks (databaseHandle . storeDB . webStore . webConfig)
    statsM <- lift (getProperty db Stats)
    addItemCount 1
    S.text $ maybe "Could not get stats" cs statsM

-----------------------
-- Parameter Parsing --
-----------------------

{- | Returns @Nothing@ if the parameter is not supplied. Raises an exception on
 parse failure.
-}
paramOptional :: (Param a, MonadIO m) => WebT m (Maybe a)
paramOptional = go Proxy
  where
    go :: (Param a, MonadIO m) => Proxy a -> WebT m (Maybe a)
    go proxy = do
        net <- lift $ asks (storeNetwork . webStore . webConfig)
        tsM :: Maybe [Text] <- p `S.rescue` const (return Nothing)
        case tsM of
            Nothing -> return Nothing -- Parameter was not supplied
            Just ts -> maybe (raise err) (return . Just) $ parseParam net ts
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

{- | Returns the default value of a parameter if it is not supplied. Raises an
 exception on parse failure.
-}
paramDef :: (Default a, Param a, MonadIO m) => WebT m a
paramDef = fromMaybe def <$> paramOptional

{- | Does not raise exceptions. Will call @Scotty.next@ if the parameter is
 not supplied or if parsing fails.
-}
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
    hex b = case B16.decodeBase16 $ C.filter (not . isSpace) b of
        Right x -> bin x
        Left s -> Left (T.unpack s)

parseOffset :: MonadIO m => WebT m OffsetParam
parseOffset = do
    res@(OffsetParam o) <- paramDef
    limits <- lift $ asks (webMaxLimits . webConfig)
    when (maxLimitOffset limits > 0 && fromIntegral o > maxLimitOffset limits) $
        raise . UserError $
            "offset exceeded: " <> show o <> " > " <> show (maxLimitOffset limits)
    return res

parseStart ::
    (MonadUnliftIO m, MonadLoggerIO m) =>
    Maybe StartParam ->
    WebT m (Maybe Start)
parseStart Nothing = return Nothing
parseStart (Just s) =
    runMaybeT $
        case s of
            StartParamHash{startParamHash = h} -> start_tx h <|> start_block h
            StartParamHeight{startParamHeight = h} -> start_height h
            StartParamTime{startParamTime = q} -> start_time q
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
    (MonadUnliftIO m, MonadLoggerIO m) =>
    Bool ->
    LimitsParam ->
    WebT m Limits
paramToLimits full (LimitsParam limitM o startM) = do
    wl <- lift $ asks (webMaxLimits . webConfig)
    Limits (validateLimit wl full limitM) (fromIntegral o) <$> parseStart startM

validateLimit :: WebLimits -> Bool -> Maybe LimitParam -> Word32
validateLimit wl full limitM =
    f m $ maybe d (fromIntegral . getLimitParam) limitM
  where
    m
        | full && maxLimitFull wl > 0 = maxLimitFull wl
        | otherwise = maxLimitCount wl
    d = maxLimitDefault wl
    f a 0 = a
    f 0 b = b
    f a b = min a b

---------------
-- Utilities --
---------------

runInWebReader ::
    MonadIO m =>
    CacheT (DatabaseReaderT m) a ->
    ReaderT WebState m a
runInWebReader f = do
    bdb <- asks (storeDB . webStore . webConfig)
    mc <- asks (storeCache . webStore . webConfig)
    lift $ runReaderT (withCache mc f) bdb

runNoCache :: MonadIO m => Bool -> ReaderT WebState m a -> ReaderT WebState m a
runNoCache False f = f
runNoCache True f = local g f
  where
    g s = s{webConfig = h (webConfig s)}
    h c = c{webStore = i (webStore c)}
    i s = s{storeCache = Nothing}

logIt ::
    (MonadUnliftIO m, MonadLoggerIO m) =>
    Maybe WebMetrics ->
    m Middleware
logIt metrics = do
    runner <- askRunInIO
    return $ \app req respond -> do
        var <- newTVarIO B.empty
        req' <-
            let rb = req_body var (getRequestBodyChunk req)
                rq = req{requestBody = rb}
             in case metrics of
                    Nothing -> return rq
                    Just m -> do
                        stat_var <- newTVarIO Nothing
                        let vt =
                                V.insert (statKey m) stat_var $
                                    vault rq
                        return rq{vault = vt}
        bracket start (end var runner req') $ \_ ->
            app req' $ \res -> do
                b <- readTVarIO var
                let s = responseStatus res
                    msg = fmtReq b req' <> ": " <> fmtStatus s
                if statusIsSuccessful s
                    then runner $ $(logDebugS) "Web" msg
                    else runner $ $(logErrorS) "Web" msg
                respond res
  where
    start = systemToUTCTime <$> getSystemTime
    req_body var old_body = do
        b <- old_body
        unless (B.null b) . atomically $ modifyTVar var (<> b)
        return b
    add_stat d s = do
        addStatQuery s
        addStatTime s d
    end var runner req t1 = do
        t2 <- systemToUTCTime <$> getSystemTime
        let diff = round $ diffUTCTime t2 t1 * 1000
        case metrics of
            Nothing -> return ()
            Just m -> do
                let m_stat_var = V.lookup (statKey m) (vault req)
                add_stat diff (statAll m)
                case m_stat_var of
                    Nothing -> return ()
                    Just stat_var ->
                        readTVarIO stat_var >>= \case
                            Nothing -> return ()
                            Just f -> add_stat diff (f m)
        when (diff > 10000) $ do
            b <- readTVarIO var
            runner $
                $(logWarnS) "Web" $
                    "Slow [" <> cs (show diff) <> " ms]: " <> fmtReq b req

reqSizeLimit :: Integral i => i -> Middleware
reqSizeLimit i = requestSizeLimitMiddleware lim
  where
    max_len _req = return (Just (fromIntegral i))
    lim =
        setOnLengthExceeded too_big $
            setMaxLengthForRequest
                max_len
                defaultRequestSizeLimitSettings
    too_big _ = \_app _req send ->
        send $
            waiExcept requestEntityTooLarge413 RequestTooLarge

fmtReq :: ByteString -> Request -> Text
fmtReq bs req =
    let m = requestMethod req
        v = httpVersion req
        p = rawPathInfo req
        q = rawQueryString req
        txt = case T.decodeUtf8' bs of
            Left _ -> " {invalid utf8}"
            Right "" -> ""
            Right t -> " [" <> t <> "]"
     in T.decodeUtf8 (m <> " " <> p <> q <> " " <> cs (show v)) <> txt

fmtStatus :: Status -> Text
fmtStatus s = cs (show (statusCode s)) <> " " <> cs (statusMessage s)
