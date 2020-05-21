{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
module Haskoin.Store.Web
    ( -- * Web
      WebConfig (..)
    , Except (..)
    , WebLimits (..)
    , WebTimeouts (..)
    , runWeb
    ) where

import           Conduit                       ()
import           Control.Applicative           ((<|>))
import           Control.Monad                 (forever, guard, unless, when,
                                                (<=<))
import           Control.Monad.Logger          (MonadLogger, MonadLoggerIO,
                                                askLoggerIO, logInfoS,
                                                monadLoggerLog)
import           Control.Monad.Reader          (ReaderT, asks, local,
                                                runReaderT)
import           Control.Monad.Trans           (lift)
import           Control.Monad.Trans.Maybe     (MaybeT (..), runMaybeT)
import           Data.Aeson                    (Encoding, ToJSON (..))
import           Data.Aeson.Encoding           (encodingToLazyByteString, list,
                                                pair, pairs, unsafeToEncoding)
import qualified Data.ByteString               as B
import           Data.ByteString.Builder       (char7, lazyByteString,
                                                lazyByteStringHex)
import qualified Data.ByteString.Lazy          as L
import qualified Data.ByteString.Lazy.Char8    as C
import           Data.Char                     (isSpace)
import           Data.Default                  (Default (..))
import           Data.List                     (nub)
import           Data.Maybe                    (catMaybes, fromMaybe, isJust,
                                                listToMaybe, mapMaybe)
import           Data.Serialize                as Serialize
import           Data.String.Conversions       (cs)
import           Data.Text                     (Text)
import qualified Data.Text.Encoding            as T
import qualified Data.Text.Lazy                as TL
import           Data.Time.Clock               (NominalDiffTime, diffUTCTime,
                                                getCurrentTime)
import           Data.Time.Clock.System        (getSystemTime, systemSeconds)
import           Data.Version                  (showVersion)
import           Data.Word                     (Word32, Word64)
import           Database.RocksDB              (Property (..), getProperty)
import           Haskoin                       (Address, Block (..),
                                                BlockHash (..),
                                                BlockHeader (..), BlockHeight,
                                                BlockNode (..), GetData (..),
                                                Hash256, InvType (..),
                                                InvVector (..), Message (..),
                                                Network (..), OutPoint (..), Tx,
                                                TxHash (..), VarString (..),
                                                Version (..), decodeHex,
                                                eitherToMaybe, headerHash,
                                                hexToBlockHash, hexToTxHash,
                                                stringToAddr, txHash,
                                                xPubImport)
import           Haskoin.Node                  (Chain, OnlinePeer (..),
                                                PeerManager, chainGetBest,
                                                managerGetPeers, sendMessage)
import           Haskoin.Store.Cache           (CacheT, evictFromCache,
                                                withCache)
import           Haskoin.Store.Common          (Limits (..), PubExcept (..),
                                                Start (..), StoreEvent (..),
                                                StoreRead (..), blockAtOrBefore,
                                                getTransaction, nub')
import           Haskoin.Store.Data            (BlockData (..), BlockRef (..),
                                                DeriveType (..), Event (..),
                                                Except (..), GenericResult (..),
                                                HealthCheck (..),
                                                PeerInformation (..),
                                                StoreInput (..),
                                                Transaction (..), TxId (..),
                                                TxRef (..), UnixTime, Unspent,
                                                XPubBal (..), XPubSpec (..),
                                                balanceToEncoding,
                                                blockDataToEncoding, isCoinbase,
                                                nullBalance, transactionData,
                                                transactionToEncoding,
                                                unspentToEncoding,
                                                xPubBalToEncoding,
                                                xPubUnspentToEncoding)
import           Haskoin.Store.Database.Reader (DatabaseReader (..),
                                                DatabaseReaderT,
                                                withDatabaseReader)
import           Haskoin.Store.Manager         (Store (..))
import           Network.HTTP.Types            (Status (..), status400,
                                                status403, status404, status500,
                                                status503)
import           Network.Wai                   (Middleware, Request (..),
                                                responseStatus)
import           NQE                           (Publisher, receive,
                                                withSubscription)
import qualified Paths_haskoin_store           as P (version)
import           Text.Printf                   (printf)
import           Text.Read                     (readMaybe)
import           UnliftIO                      (MonadIO, MonadUnliftIO,
                                                askRunInIO, liftIO, timeout)
import           Web.Scotty.Internal.Types     (ActionT)
import           Web.Scotty.Trans              (Parsable, ScottyError)
import qualified Web.Scotty.Trans              as S

type WebT m = ActionT Except (ReaderT WebConfig m)

data WebConfig =
    WebConfig
        { webPort        :: !Int
        , webStore       :: !Store
        , webMaxLimits   :: !WebLimits
        , webReqLog      :: !Bool
        , webWebTimeouts :: !WebTimeouts
        }

data WebLimits =
    WebLimits
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
            { maxLimitCount = 20000
            , maxLimitFull = 5000
            , maxLimitOffset = 50000
            , maxLimitDefault = 2000
            , maxLimitGap = 32
            , maxLimitInitialGap = 20
            }

data WebTimeouts =
    WebTimeouts
        { txTimeout    :: !Word64
        , blockTimeout :: !Word64
        }
    deriving (Eq, Show)

instance Default WebTimeouts where
    def = WebTimeouts {txTimeout = 300, blockTimeout = 7200}

newtype MyBlockHash =
    MyBlockHash BlockHash

newtype MyTxHash =
    MyTxHash TxHash

instance Parsable MyBlockHash where
    parseParam =
        maybe (Left "could not decode block hash") (Right . MyBlockHash) . hexToBlockHash . cs

instance Parsable MyTxHash where
    parseParam =
        maybe (Left "could not decode tx hash") (Right . MyTxHash) . hexToTxHash . cs

data StartParam
    = StartParamHash
          { startParamHash :: !Hash256}
    | StartParamHeight
          { startParamHeight :: !Word32}
    | StartParamTime
          { startParamTime :: !UnixTime}

instance Parsable StartParam where
    parseParam s = maybe (Left "could not decode start") Right (h <|> g <|> t)
      where
        h = do
            guard (TL.length s == 32 * 2)
            x <- fmap B.reverse (decodeHex (TL.toStrict s)) >>= eitherToMaybe . decode
            return StartParamHash {startParamHash = x}
        g = do
            x <- readMaybe (TL.unpack s)
            guard $ x <= 1230768000
            return StartParamHeight {startParamHeight = x}
        t = do
            x <- readMaybe (TL.unpack s)
            guard $ x > 1230768000
            return StartParamTime {startParamTime = x}

runInWebReader ::
       MonadIO m
    => CacheT (DatabaseReaderT m) a
    -> ReaderT WebConfig m a
runInWebReader f = do
    bdb <- asks (storeDB . webStore)
    mc <- asks (storeCache . webStore)
    lift $ withDatabaseReader bdb (withCache mc f)

runNoCache :: MonadIO m => Bool -> ReaderT WebConfig m a -> ReaderT WebConfig m a
runNoCache False f = f
runNoCache True f =
    local (\s -> s {webStore = (webStore s) {storeCache = Nothing}}) f

instance (MonadUnliftIO m, MonadLoggerIO m) =>
         StoreRead (ReaderT WebConfig m) where
    getMaxGap = runInWebReader getMaxGap
    getInitialGap = runInWebReader getInitialGap
    getNetwork = runInWebReader getNetwork
    getBestBlock = runInWebReader getBestBlock
    getBlocksAtHeight height = runInWebReader (getBlocksAtHeight height)
    getBlock bh = runInWebReader (getBlock bh)
    getTxData th = runInWebReader (getTxData th)
    getSpender op = runInWebReader (getSpender op)
    getSpenders th = runInWebReader (getSpenders th)
    getUnspent op = runInWebReader (getUnspent op)
    getBalance a = runInWebReader (getBalance a)
    getBalances as = runInWebReader (getBalances as)
    getMempool = runInWebReader getMempool
    getAddressesTxs as = runInWebReader . getAddressesTxs as
    getAddressesUnspents as = runInWebReader . getAddressesUnspents as
    xPubBals = runInWebReader . xPubBals
    xPubSummary = runInWebReader . xPubSummary
    xPubUnspents xpub = runInWebReader . xPubUnspents xpub
    xPubTxs xpub = runInWebReader . xPubTxs xpub

instance (MonadUnliftIO m, MonadLoggerIO m) => StoreRead (WebT m) where
    getNetwork = lift getNetwork
    getBestBlock = lift getBestBlock
    getBlocksAtHeight = lift . getBlocksAtHeight
    getBlock = lift . getBlock
    getTxData = lift . getTxData
    getSpender = lift . getSpender
    getSpenders = lift . getSpenders
    getUnspent = lift . getUnspent
    getBalance = lift . getBalance
    getBalances = lift . getBalances
    getMempool = lift getMempool
    getAddressesTxs as = lift . getAddressesTxs as
    getAddressesUnspents as = lift . getAddressesUnspents as
    xPubBals = lift . xPubBals
    xPubSummary = lift . xPubSummary
    xPubUnspents xpub = lift . xPubUnspents xpub
    xPubTxs xpub = lift . xPubTxs xpub
    getMaxGap = lift getMaxGap
    getInitialGap = lift getInitialGap

defHandler :: Monad m => Except -> WebT m ()
defHandler e = do
    proto <- setupBin
    case e of
        ThingNotFound -> S.status status404
        BadRequest    -> S.status status400
        UserError _   -> S.status status400
        StringError _ -> S.status status400
        ServerError   -> S.status status500
        BlockTooLarge -> S.status status403
    protoSerial proto e

maybeSerial ::
       (Monad m, ToJSON a, Serialize a)
    => Bool -- ^ binary
    -> Maybe a
    -> WebT m ()
maybeSerial _ Nothing      = S.raise ThingNotFound
maybeSerial proto (Just x) = S.raw (serialAny proto x)

maybeSerialRaw :: (Monad m, Serialize a) => Bool -> Maybe a -> WebT m ()
maybeSerialRaw _ Nothing      = S.raise ThingNotFound
maybeSerialRaw proto (Just x) = S.raw (serialAnyRaw proto x)

maybeSerialNet ::
       (Monad m, Serialize a)
    => Bool
    -> (Network -> a -> Encoding)
    -> Maybe a
    -> WebT m ()
maybeSerialNet _ _ Nothing = S.raise ThingNotFound
maybeSerialNet proto f (Just x) = do
    net <- lift $ asks (storeNetwork . webStore)
    S.raw (serialAnyNet proto (f net) x)

protoSerial ::
       (Monad m, ToJSON a, Serialize a)
    => Bool
    -> a
    -> WebT m ()
protoSerial proto x = do
    S.raw (serialAny proto x)

protoSerialRaw ::
       (Monad m, Serialize a)
    => Bool
    -> a
    -> WebT m ()
protoSerialRaw proto x = do
    S.raw (serialAnyRaw proto x)

protoSerialRawList ::
       (Monad m, Serialize a)
    => Bool
    -> [a]
    -> WebT m ()
protoSerialRawList proto x = do
    S.raw (serialAnyRawList proto x)

protoSerialNet ::
       (Monad m, Serialize a)
    => Bool
    -> (Network -> a -> Encoding)
    -> a
    -> WebT m ()
protoSerialNet proto f x = do
    net <- lift $ asks (storeNetwork . webStore)
    S.raw (serialAnyNet proto (f net) x)

scottyBestBlock ::
       (MonadUnliftIO m, MonadLoggerIO m, MonadIO m) => Bool -> WebT m ()
scottyBestBlock raw = do
    limits <- lift $ asks webMaxLimits
    setHeaders
    n <- parseNoTx
    proto <- setupBin
    bm <-
        runMaybeT $ do
            h <- MaybeT getBestBlock
            MaybeT $ getBlock h
    b <-
        case bm of
            Nothing -> S.raise ThingNotFound
            Just b  -> return b
    if raw
        then do
            refuseLargeBlock limits b
            rawBlock b >>= protoSerialRaw proto
        else protoSerialNet proto blockDataToEncoding (pruneTx n b)

scottyBlock :: (MonadUnliftIO m, MonadLoggerIO m) => Bool -> WebT m ()
scottyBlock raw = do
    limits <- lift $ asks webMaxLimits
    setHeaders
    MyBlockHash block <- S.param "block"
    n <- parseNoTx
    proto <- setupBin
    b <-
        getBlock block >>= \case
            Nothing -> S.raise ThingNotFound
            Just b -> return b
    if raw
        then do
            refuseLargeBlock limits b
            rawBlock b >>= protoSerialRaw proto
        else protoSerialNet proto blockDataToEncoding (pruneTx n b)

scottyBlockHeight :: (MonadUnliftIO m, MonadLoggerIO m) => Bool -> WebT m ()
scottyBlockHeight raw = do
    limits <- lift $ asks webMaxLimits
    setHeaders
    height <- S.param "height"
    n <- parseNoTx
    proto <- setupBin
    hs <- getBlocksAtHeight height
    if raw
        then do
            blocks <- catMaybes <$> mapM getBlock hs
            mapM_ (refuseLargeBlock limits) blocks
            rawblocks <- mapM rawBlock blocks
            protoSerialRawList proto rawblocks
        else do
            blocks <- catMaybes <$> mapM getBlock hs
            let blocks' = map (pruneTx n) blocks
            protoSerialNet proto (list . blockDataToEncoding) blocks'

scottyBlockTime :: (MonadUnliftIO m, MonadLoggerIO m) => Bool -> WebT m ()
scottyBlockTime raw = do
    limits <- lift $ asks webMaxLimits
    setHeaders
    q <- S.param "time"
    n <- parseNoTx
    proto <- setupBin
    m <- fmap (pruneTx n) <$> blockAtOrBefore q
    if raw
        then maybeSerial proto =<<
             case m of
                 Nothing -> return Nothing
                 Just d -> do
                     refuseLargeBlock limits d
                     Just <$> rawBlock d
        else maybeSerialNet proto blockDataToEncoding m

scottyBlockHeights :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBlockHeights = do
    setHeaders
    heights <- S.param "heights"
    n <- parseNoTx
    proto <- setupBin
    bhs <- concat <$> mapM getBlocksAtHeight (heights :: [BlockHeight])
    blocks <- map (pruneTx n) . catMaybes <$> mapM getBlock bhs
    protoSerialNet proto (list . blockDataToEncoding) blocks

scottyBlockLatest :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBlockLatest = do
    setHeaders
    n <- parseNoTx
    proto <- setupBin
    getBestBlock >>= \case
        Just h -> do
            blocks <- reverse <$> go 100 n h
            protoSerialNet proto (list . blockDataToEncoding) blocks
        Nothing -> S.raise ThingNotFound
  where
    go 0 _ _ = return []
    go i n h =
        getBlock h >>= \case
            Nothing -> return []
            Just b ->
                let b' = pruneTx n b
                    i' = i - 1 :: Int
                    prev = prevBlock (blockDataHeader b)
                 in if blockDataHeight b <= 0
                        then return []
                        else (b' :) <$> go i' n prev


scottyBlocks :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBlocks = do
    setHeaders
    bhs <- map (\(MyBlockHash h) -> h) <$> S.param "blocks"
    n <- parseNoTx
    proto <- setupBin
    bks <- map (pruneTx n) . catMaybes <$> mapM getBlock (nub bhs)
    protoSerialNet proto (list . blockDataToEncoding) bks

scottyMempool :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyMempool = do
    setHeaders
    l <- fromIntegral <$> getLimit False
    o <- fromIntegral <$> getOffset
    proto <- setupBin
    txs <- take l . drop o . map txRefHash <$> getMempool
    protoSerial proto txs

scottyTransaction :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyTransaction = do
    setHeaders
    MyTxHash txid <- S.param "txid"
    proto <- setupBin
    res <- getTransaction txid
    maybeSerialNet proto transactionToEncoding res

scottyRawTransaction :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyRawTransaction = do
    setHeaders
    MyTxHash txid <- S.param "txid"
    proto <- setupBin
    res <- fmap transactionData <$> getTransaction txid
    maybeSerialRaw proto res

scottyTxAfterHeight :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyTxAfterHeight = do
    setHeaders
    MyTxHash txid <- S.param "txid"
    height <- S.param "height"
    proto <- setupBin
    res <- cbAfterHeight 10000 height txid
    protoSerial proto res

scottyTransactions :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyTransactions = do
    setHeaders
    txids <- map (\(MyTxHash h) -> h) <$> S.param "txids"
    proto <- setupBin
    txs <- catMaybes <$> mapM getTransaction (nub txids)
    protoSerialNet proto (list . transactionToEncoding) txs

scottyBlockTransactions :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBlockTransactions = do
    limits <- lift $ asks webMaxLimits
    setHeaders
    MyBlockHash h <- S.param "block"
    proto <- setupBin
    getBlock h >>= \case
        Just b -> do
            refuseLargeBlock limits b
            let ths = blockDataTxs b
            txs <- catMaybes <$> mapM getTransaction ths
            protoSerialNet proto (list . transactionToEncoding) txs
        Nothing -> S.raise ThingNotFound

scottyRawTransactions ::
       (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyRawTransactions = do
    setHeaders
    txids <- map (\(MyTxHash h) -> h) <$> S.param "txids"
    proto <- setupBin
    txs <- map transactionData . catMaybes <$> mapM getTransaction (nub txids)
    protoSerialRawList proto txs

rawBlock :: (Monad m, StoreRead m) => BlockData -> m Block
rawBlock b = do
    let h = blockDataHeader b
        ths = blockDataTxs b
    txs <- map transactionData . catMaybes <$> mapM getTransaction ths
    return Block {blockHeader = h, blockTxns = txs}

scottyRawBlockTransactions ::
       (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyRawBlockTransactions = do
    limits <- lift $ asks webMaxLimits
    setHeaders
    MyBlockHash h <- S.param "block"
    proto <- setupBin
    getBlock h >>= \case
        Just b -> do
            refuseLargeBlock limits b
            let ths = blockDataTxs b
            txs <- map transactionData . catMaybes <$> mapM getTransaction ths
            protoSerialRawList proto txs
        Nothing -> S.raise ThingNotFound

scottyAddressTxs :: (MonadUnliftIO m, MonadLoggerIO m) => Bool -> WebT m ()
scottyAddressTxs full = do
    setHeaders
    a <- parseAddress
    l <- getLimits full
    proto <- setupBin
    if full
        then do
            getAddressTxsFull l a >>=
                protoSerialNet proto (list . transactionToEncoding)
        else do
            getAddressTxsLimit l a >>= protoSerial proto

scottyAddressesTxs ::
       (MonadUnliftIO m, MonadLoggerIO m) => Bool -> WebT m ()
scottyAddressesTxs full = do
    setHeaders
    as <- parseAddresses
    l <- getLimits full
    proto <- setupBin
    if full
        then getAddressesTxsFull l as >>=
             protoSerialNet proto (list . transactionToEncoding)
        else getAddressesTxsLimit l as >>= protoSerial proto

scottyAddressUnspent :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyAddressUnspent = do
    setHeaders
    a <- parseAddress
    l <- getLimits False
    proto <- setupBin
    uns <- getAddressUnspentsLimit l a
    protoSerialNet proto (list . unspentToEncoding) uns

scottyAddressesUnspent :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyAddressesUnspent = do
    setHeaders
    as <- parseAddresses
    l <- getLimits False
    proto <- setupBin
    uns <- getAddressesUnspentsLimit l as
    protoSerialNet proto (list . unspentToEncoding) uns

scottyAddressBalance :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyAddressBalance = do
    setHeaders
    a <- parseAddress
    proto <- setupBin
    res <- getBalance a
    protoSerialNet proto balanceToEncoding res

scottyAddressesBalances :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyAddressesBalances = do
    setHeaders
    as <- parseAddresses
    proto <- setupBin
    res <- getBalances as
    protoSerialNet proto (list . balanceToEncoding) res

scottyXpubBalances :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyXpubBalances = do
    setHeaders
    nocache <- parseNoCache
    xpub <- parseXpub
    proto <- setupBin
    res <-
        filter (not . nullBalance . xPubBal) <$>
        lift (runNoCache nocache (xPubBals xpub))
    protoSerialNet proto (list . xPubBalToEncoding) res

scottyXpubTxs :: (MonadUnliftIO m, MonadLoggerIO m) => Bool -> WebT m ()
scottyXpubTxs full = do
    setHeaders
    nocache <- parseNoCache
    xpub <- parseXpub
    l <- getLimits full
    proto <- setupBin
    txs <- lift . runNoCache nocache $ xPubTxs xpub l
    if full
        then do
            txs' <-
                fmap catMaybes . lift . runNoCache nocache $
                mapM (getTransaction . txRefHash) txs
            protoSerialNet proto (list . transactionToEncoding) txs'
        else protoSerial proto txs

scottyXpubEvict :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyXpubEvict =
    lift (asks (storeCache . webStore)) >>= \cache -> do
        setHeaders
        xpub <- parseXpub
        proto <- setupBin
        lift . withCache cache $ evictFromCache [xpub]
        protoSerial proto (GenericResult True)


scottyXpubUnspents :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyXpubUnspents = do
    setHeaders
    nocache <- parseNoCache
    xpub <- parseXpub
    proto <- setupBin
    l <- getLimits False
    uns <- lift . runNoCache nocache $ xPubUnspents xpub l
    protoSerialNet proto (list . xPubUnspentToEncoding) uns

scottyXpubSummary :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyXpubSummary = do
    setHeaders
    nocache <- parseNoCache
    xpub <- parseXpub
    proto <- setupBin
    res <- lift . runNoCache nocache $ xPubSummary xpub
    protoSerial proto res

scottyPostTx ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => WebT m ()
scottyPostTx = do
    net <- lift $ asks (storeNetwork . webStore)
    pub <- lift $ asks (storePublisher . webStore)
    mgr <- lift $ asks (storeManager . webStore)
    setHeaders
    proto <- setupBin
    b <- S.body
    let bin = eitherToMaybe . Serialize.decode
        hex = bin <=< decodeHex . cs . C.filter (not . isSpace)
    tx <-
        case hex b <|> bin (L.toStrict b) of
            Nothing -> S.raise $ UserError "decode tx fail"
            Just x  -> return x
    lift (publishTx net pub mgr tx) >>= \case
        Right () -> do
            protoSerial proto (TxId (txHash tx))
        Left e -> do
            case e of
                PubNoPeers          -> S.status status500
                PubTimeout          -> S.status status500
                PubPeerDisconnected -> S.status status500
                PubReject _         -> S.status status400
            protoSerial proto (UserError (show e))
            S.finish

scottyDbStats :: MonadLoggerIO m => WebT m ()
scottyDbStats = do
    setHeaders
    db <- lift $ asks (databaseHandle . storeDB . webStore)
    stats <- lift (getProperty db Stats)
    case stats of
        Nothing -> do
            S.text "Could not get stats"
        Just txt -> do
            S.text $ cs txt

scottyEvents :: MonadLoggerIO m => WebT m ()
scottyEvents = do
    pub <- lift $ asks (storePublisher . webStore)
    setHeaders
    proto <- setupBin
    S.stream $ \io flush' ->
        withSubscription pub $ \sub ->
            forever $
            flush' >> receive sub >>= \se -> do
                let me =
                        case se of
                            StoreBestBlock b     -> Just (EventBlock b)
                            StoreMempoolNew t    -> Just (EventTx t)
                            StoreTxDeleted t     -> Just (EventTx t)
                            StoreBlockReverted b -> Just (EventBlock b)
                            _                    -> Nothing
                case me of
                    Nothing -> return ()
                    Just e ->
                        let bs =
                                serialAny proto e <>
                                if proto
                                    then mempty
                                    else "\n"
                         in io (lazyByteString bs)

scottyPeers :: MonadLoggerIO m => WebT m ()
scottyPeers = do
    mgr <- lift $ asks (storeManager . webStore)
    setHeaders
    proto <- setupBin
    ps <- getPeersInformation mgr
    protoSerial proto ps

scottyHealth ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => WebT m ()
scottyHealth = do
    net <- lift $ asks (storeNetwork . webStore)
    mgr <- lift $ asks (storeManager . webStore)
    chn <- lift $ asks (storeChain . webStore)
    tos <- lift $ asks webWebTimeouts
    setHeaders
    proto <- setupBin
    h <- lift $ healthCheck net mgr chn tos
    when (not (healthOK h) || not (healthSynced h)) $ S.status status503
    protoSerial proto h

runWeb :: (MonadLoggerIO m, MonadUnliftIO m) => WebConfig -> m ()
runWeb cfg@WebConfig {webPort = port, webReqLog = reqlog} = do
    req_logger <-
        if reqlog
            then Just <$> logIt
            else return Nothing
    runner <- askRunInIO
    S.scottyT port (runner . (`runReaderT` cfg)) $ do
        case req_logger of
            Just m  -> S.middleware m
            Nothing -> return ()
        S.defaultHandler defHandler
        S.get "/block/best" $ scottyBestBlock False
        S.get "/block/best/raw" $ scottyBestBlock True
        S.get "/block/:block" $ scottyBlock False
        S.get "/block/:block/raw" $ scottyBlock True
        S.get "/block/height/:height" $ scottyBlockHeight False
        S.get "/block/height/:height/raw" $ scottyBlockHeight True
        S.get "/block/time/:time" $ scottyBlockTime False
        S.get "/block/time/:time/raw" $ scottyBlockTime True
        S.get "/block/heights" scottyBlockHeights
        S.get "/block/latest" scottyBlockLatest
        S.get "/blocks" scottyBlocks
        S.get "/mempool" scottyMempool
        S.get "/transaction/:txid" scottyTransaction
        S.get "/transaction/:txid/raw" scottyRawTransaction
        S.get "/transaction/:txid/after/:height" scottyTxAfterHeight
        S.get "/transactions" scottyTransactions
        S.get "/transactions/raw" scottyRawTransactions
        S.get "/transactions/block/:block" scottyBlockTransactions
        S.get "/transactions/block/:block/raw" scottyRawBlockTransactions
        S.get "/address/:address/transactions" $ scottyAddressTxs False
        S.get "/address/:address/transactions/full" $ scottyAddressTxs True
        S.get "/address/transactions" $ scottyAddressesTxs False
        S.get "/address/transactions/full" $ scottyAddressesTxs True
        S.get "/address/:address/unspent" scottyAddressUnspent
        S.get "/address/unspent" scottyAddressesUnspent
        S.get "/address/:address/balance" scottyAddressBalance
        S.get "/address/balances" scottyAddressesBalances
        S.get "/xpub/:xpub/balances" scottyXpubBalances
        S.get "/xpub/:xpub/transactions" $ scottyXpubTxs False
        S.get "/xpub/:xpub/transactions/full" $ scottyXpubTxs True
        S.get "/xpub/:xpub/unspent" scottyXpubUnspents
        S.get "/xpub/:xpub/evict" scottyXpubEvict
        S.get "/xpub/:xpub" scottyXpubSummary
        S.post "/transactions" scottyPostTx
        S.get "/dbstats" scottyDbStats
        S.get "/events" scottyEvents
        S.get "/peers" scottyPeers
        S.get "/health" scottyHealth
        S.notFound $ S.raise ThingNotFound

getStart :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m (Maybe Start)
getStart =
    runMaybeT $ do
        s <-
            MaybeT $
            (Just <$> S.param "height") `S.rescue` const (return Nothing)
        do case s of
               StartParamHash {startParamHash = h} ->
                   start_tx h <|> start_block h
               StartParamHeight {startParamHeight = h} -> start_height h
               StartParamTime {startParamTime = q} -> start_time q
  where
    start_height h = do
        return $ AtBlock h
    start_block h = do
        b <- MaybeT $ getBlock (BlockHash h)
        return $ AtBlock (blockDataHeight b)
    start_tx h = do
        _ <- MaybeT $ getTxData (TxHash h)
        return $ AtTx (TxHash h)
    start_time q = do
        b <- MaybeT $ blockAtOrBefore q
        let g = blockDataHeight b
        return $ AtBlock g

getLimits :: (MonadLoggerIO m, MonadUnliftIO m) => Bool -> WebT m Limits
getLimits full = do
    o <- getOffset
    l <- getLimit full
    s <- getStart
    return Limits {limit = l, offset = o, start = s}

getOffset :: Monad m => WebT m Word32
getOffset = do
    limits <- lift $ asks webMaxLimits
    o <- S.param "offset" `S.rescue` const (return 0)
    when (maxLimitOffset limits > 0 && o > maxLimitOffset limits) .
        S.raise . UserError $
        "offset exceeded: " <> show o <> " > " <> show (maxLimitOffset limits)
    return o

getLimit ::
       Monad m
    => Bool
    -> WebT m Word32
getLimit full = do
    limits <- lift $ asks webMaxLimits
    l <- (Just <$> S.param "limit") `S.rescue` const (return Nothing)
    let m =
            if full
                then if maxLimitFull limits > 0
                         then maxLimitFull limits
                         else maxLimitCount limits
                else maxLimitCount limits
    let d = maxLimitDefault limits
    return $
        case l of
            Nothing ->
                if d > 0 || m > 0
                    then (min m d)
                    else 0
            Just n ->
                if m > 0
                    then (min m n)
                    else n

parseAddress :: Monad m => WebT m Address
parseAddress = do
    net <- lift $ asks (storeNetwork . webStore)
    address <- S.param "address"
    case stringToAddr net address of
        Nothing -> S.next
        Just a  -> return a

parseAddresses :: Monad m => WebT m [Address]
parseAddresses = do
    net <- lift $ asks (storeNetwork . webStore)
    addresses <- S.param "addresses"
    let as = mapMaybe (stringToAddr net) addresses
    unless (length as == length addresses) S.next
    return as

parseXpub :: Monad m => WebT m XPubSpec
parseXpub = do
    net <- lift $ asks (storeNetwork . webStore)
    t <- S.param "xpub"
    d <- parseDeriveAddrs
    case xPubImport net t of
        Nothing -> S.next
        Just x  -> return XPubSpec {xPubSpecKey = x, xPubDeriveType = d}

parseDeriveAddrs ::
       Monad m => WebT m DeriveType
parseDeriveAddrs =
    lift (asks (storeNetwork . webStore)) >>= \case
      net
          | getSegWit net -> do
              t <- S.param "derive" `S.rescue` const (return "standard")
              return $
                  case (t :: Text) of
                      "segwit" -> DeriveP2WPKH
                      "compat" -> DeriveP2SH
                      _        -> DeriveNormal
          | otherwise -> return DeriveNormal

parseNoCache :: (Monad m, ScottyError e) => ActionT e m Bool
parseNoCache = S.param "nocache" `S.rescue` const (return False)

parseNoTx :: (Monad m, ScottyError e) => ActionT e m Bool
parseNoTx = S.param "notx" `S.rescue` const (return False)

pruneTx :: Bool -> BlockData -> BlockData
pruneTx False b = b
pruneTx True b  = b {blockDataTxs = take 1 (blockDataTxs b)}

setHeaders :: (Monad m, ScottyError e) => ActionT e m ()
setHeaders = do
    S.setHeader "Access-Control-Allow-Origin" "*"

serialAny ::
       (ToJSON a, Serialize a)
    => Bool -- ^ binary
    -> a
    -> L.ByteString
serialAny True  = runPutLazy . put
serialAny False = encodingToLazyByteString . toEncoding

serialAnyRaw :: Serialize a => Bool -> a -> L.ByteString
serialAnyRaw True x = runPutLazy (put x)
serialAnyRaw False x = encodingToLazyByteString (pairs ps)
  where
    ps = "result" `pair` unsafeToEncoding str
    str = char7 '"' <> lazyByteStringHex (runPutLazy (put x)) <> char7 '"'

serialAnyRawList :: Serialize a => Bool -> [a] -> L.ByteString
serialAnyRawList True x = runPutLazy (put x)
serialAnyRawList False xs = encodingToLazyByteString (list f xs)
  where
    f x = unsafeToEncoding (str x)
    str x = char7 '"' <> lazyByteStringHex (runPutLazy (put x)) <> char7 '"'

serialAnyNet ::
       Serialize a => Bool -> (a -> Encoding) -> a -> L.ByteString
serialAnyNet True _  = runPutLazy . put
serialAnyNet False f = encodingToLazyByteString . f

setupBin :: Monad m => ActionT Except m Bool
setupBin =
    let p = do
            S.setHeader "Content-Type" "application/octet-stream"
            return True
        j = do
            S.setHeader "Content-Type" "application/json"
            return False
     in S.header "accept" >>= \case
            Nothing -> j
            Just x ->
                if is_binary x
                    then p
                    else j
  where
    is_binary = (== "application/octet-stream")

instance MonadLoggerIO m => MonadLoggerIO (WebT m) where
    askLoggerIO = lift askLoggerIO

instance MonadLogger m => MonadLogger (WebT m) where
    monadLoggerLog loc src lvl = lift . monadLoggerLog loc src lvl

healthCheck ::
       (MonadUnliftIO m, StoreRead m)
    => Network
    -> PeerManager
    -> Chain
    -> WebTimeouts
    -> m HealthCheck
healthCheck net mgr ch tos = do
    cb <- chain_best
    bb <- block_best
    pc <- peer_count
    tm <- get_current_time
    ml <- get_mempool_last
    let ck = block_ok cb
        bk = block_ok bb
        pk = peer_count_ok pc
        bd = block_time_delta tm cb
        td = tx_time_delta tm bd ml
        lk = timeout_ok (blockTimeout tos) bd
        tk = timeout_ok (txTimeout tos) td
        sy = in_sync bb cb
        ok = ck && bk && pk && lk && (tk || not sy)
    return
        HealthCheck
            { healthBlockBest = block_hash <$> bb
            , healthBlockHeight = block_height <$> bb
            , healthHeaderBest = node_hash <$> cb
            , healthHeaderHeight = node_height <$> cb
            , healthPeers = pc
            , healthNetwork = getNetworkName net
            , healthOK = ok
            , healthSynced = sy
            , healthLastBlock = bd
            , healthLastTx = td
            , healthVersion = showVersion P.version
            }
  where
    block_hash = headerHash . blockDataHeader
    block_height = blockDataHeight
    node_hash = headerHash . nodeHeader
    node_height = nodeHeight
    get_mempool_last = listToMaybe <$> getMempool
    get_current_time = fromIntegral . systemSeconds <$> liftIO getSystemTime
    peer_count_ok pc = fromMaybe 0 pc > 0
    block_ok = isJust
    node_timestamp = fromIntegral . blockTimestamp . nodeHeader
    in_sync bb cb = fromMaybe False $ do
        bh <- blockDataHeight <$> bb
        nh <- nodeHeight <$> cb
        return $ compute_delta bh nh <= 1
    block_time_delta tm cb = do
        bt <- node_timestamp <$> cb
        return $ compute_delta bt tm
    tx_time_delta tm bd ml = do
        bd' <- bd
        tt <- memRefTime . txRefBlock <$> ml <|> bd
        return $ min (compute_delta tt tm) bd'
    timeout_ok to td = fromMaybe False $ do
        td' <- td
        return $
          getAllowMinDifficultyBlocks net ||
          to == 0 ||
          td' <= to
    peer_count = fmap length <$> timeout 10000000 (managerGetPeers mgr)
    block_best = runMaybeT $ do
        h <- MaybeT getBestBlock
        MaybeT $ getBlock h
    chain_best = timeout 10000000 $ chainGetBest ch
    compute_delta a b = if b > a then b - a else 0

-- | Obtain information about connected peers from peer manager process.
getPeersInformation :: MonadIO m => PeerManager -> m [PeerInformation]
getPeersInformation mgr = mapMaybe toInfo <$> managerGetPeers mgr
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

-- | Check if any of the ancestors of this transaction is a coinbase after the
-- specified height. Returns 'Nothing' if answer cannot be computed before
-- hitting limits.
cbAfterHeight ::
       (MonadIO m, StoreRead m)
    => Int -- ^ how many ancestors to test before giving up
    -> BlockHeight
    -> TxHash
    -> m (GenericResult (Maybe Bool))
cbAfterHeight d h t
    | d <= 0 = return $ GenericResult Nothing
    | otherwise = do
        x <- fmap snd <$> tst d t
        return $ GenericResult x
  where
    tst e x
        | e <= 0 = return Nothing
        | otherwise = do
            let e' = e - 1
            getTransaction x >>= \case
                Nothing -> return Nothing
                Just tx ->
                    if any isCoinbase (transactionInputs tx)
                        then return $
                             Just (e', blockRefHeight (transactionBlock tx) > h)
                        else case transactionBlock tx of
                                 BlockRef {blockRefHeight = b}
                                     | b <= h -> return $ Just (e', False)
                                 _ ->
                                     r e' . nub' $
                                     map
                                         (outPointHash . inputPoint)
                                         (transactionInputs tx)
    r e [] = return $ Just (e, False)
    r e (n:ns) =
        tst e n >>= \case
            Nothing -> return Nothing
            Just (e', s) ->
                if s
                    then return $ Just (e', True)
                    else r e' ns

getAddressTxsLimit ::
       (Monad m, StoreRead m)
    => Limits
    -> Address
    -> m [TxRef]
getAddressTxsLimit limits addr = getAddressTxs addr limits

getAddressTxsFull ::
       (Monad m, StoreRead m)
    => Limits
    -> Address
    -> m [Transaction]
getAddressTxsFull limits addr = do
    txs <- getAddressTxsLimit limits addr
    catMaybes <$> mapM (getTransaction . txRefHash) txs

getAddressesTxsLimit ::
       (Monad m, StoreRead m)
    => Limits
    -> [Address]
    -> m [TxRef]
getAddressesTxsLimit limits addrs = getAddressesTxs addrs limits

getAddressesTxsFull ::
       (Monad m, StoreRead m)
    => Limits
    -> [Address]
    -> m [Transaction]
getAddressesTxsFull limits addrs =
    fmap catMaybes $
    getAddressesTxsLimit limits addrs >>=
    mapM (getTransaction . txRefHash)

getAddressUnspentsLimit ::
       (Monad m, StoreRead m)
    => Limits
    -> Address
    -> m [Unspent]
getAddressUnspentsLimit limits addr = getAddressUnspents addr limits

getAddressesUnspentsLimit ::
       (Monad m, StoreRead m)
    => Limits
    -> [Address]
    -> m [Unspent]
getAddressesUnspentsLimit limits addrs = getAddressesUnspents addrs limits

-- | Publish a new transaction to the network.
publishTx ::
       (MonadUnliftIO m, StoreRead m)
    => Network
    -> Publisher StoreEvent
    -> PeerManager
    -> Tx
    -> m (Either PubExcept ())
publishTx net pub mgr tx =
    withSubscription pub $ \s ->
        getTransaction (txHash tx) >>= \case
            Just _ -> return $ Right ()
            Nothing -> go s
  where
    go s =
        managerGetPeers mgr >>= \case
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
    f p s =
        liftIO (timeout t (g p s)) >>= \case
            Nothing -> return $ Left PubTimeout
            Just (Left e) -> return $ Left e
            Just (Right ()) -> return $ Right ()
    g p s =
        receive s >>= \case
            StoreTxReject p' h' c _
                | p == p' && h' == txHash tx -> return . Left $ PubReject c
            StorePeerDisconnected p' _
                | p == p' -> return $ Left PubPeerDisconnected
            StoreMempoolNew h'
                | h' == txHash tx -> return $ Right ()
            _ -> g p s

logIt :: (MonadUnliftIO m, MonadLoggerIO m) => m Middleware
logIt = do
    runner <- askRunInIO
    return $ \app req respond -> do
        t1 <- getCurrentTime
        app req $ \res -> do
            t2 <- getCurrentTime
            let d = diffUTCTime t2 t1
                s = responseStatus res
            runner $
                $(logInfoS) "Web" $
                fmtReq req <> " [" <> fmtStatus s <> " / " <> fmtDiff d <> "]"
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

refuseLargeBlock :: Monad m => WebLimits -> BlockData -> ActionT Except m ()
refuseLargeBlock WebLimits {maxLimitFull = f} BlockData {blockDataTxs = txs} =
    when (length txs > fromIntegral f) $ S.raise BlockTooLarge
