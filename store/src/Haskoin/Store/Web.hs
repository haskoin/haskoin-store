{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
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
import           Control.Monad.Logger          (LogLevel (..), MonadLogger,
                                                MonadLoggerIO, askLoggerIO,
                                                liftLoc, logInfoS,
                                                monadLoggerLog, toLogStr)
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
import           Data.Proxy                    (Proxy (..))
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
                                                RawResult (..),
                                                RawResultList (..),
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
import           Haskoin.Store.WebCommon
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

data WebConfig = WebConfig
    { webPort        :: !Int
    , webStore       :: !Store
    , webMaxLimits   :: !WebLimits
    , webReqLog      :: !Bool
    , webWebTimeouts :: !WebTimeouts
    }

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
            { maxLimitCount = 20000
            , maxLimitFull = 5000
            , maxLimitOffset = 50000
            , maxLimitDefault = 2000
            , maxLimitGap = 32
            , maxLimitInitialGap = 20
            }

data WebTimeouts = WebTimeouts
    { txTimeout    :: !Word64
    , blockTimeout :: !Word64
    }
    deriving (Eq, Show)

instance Default WebTimeouts where
    def = WebTimeouts {txTimeout = 300, blockTimeout = 7200}

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

{---------------------}
{- Serializing Stuff -}
{---------------------}

setupContentType :: Monad m => ActionT Except m Bool
setupContentType = maybe goJson setType =<< S.header "accept"
  where
    setType "application/octet-stream" = goBinary
    setType _                          = goJson
    goBinary = do
        S.setHeader "Content-Type" "application/octet-stream"
        return True
    goJson = do
        S.setHeader "Content-Type" "application/json"
        return False

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
protoSerial proto x =
    S.raw (serialAny proto x)

protoSerialRaw ::
       (Monad m, Serialize a)
    => Bool
    -> a
    -> WebT m ()
protoSerialRaw proto x =
    S.raw (serialAnyRaw proto x)

protoSerialRawList ::
       (Monad m, Serialize a)
    => Bool
    -> [a]
    -> WebT m ()
protoSerialRawList proto x =
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

serialAny ::
       (ToJSON a, Serialize a)
    => Bool -- ^ binary
    -> a
    -> L.ByteString
serialAny True  = runPutLazy . put
serialAny False = encodingToLazyByteString . toEncoding

serialAnyNet ::
       Serialize a => Bool -> (a -> Encoding) -> a -> L.ByteString
serialAnyNet True _  = runPutLazy . put
serialAnyNet False f = encodingToLazyByteString . f

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

{-----------------}
{- Path Handlers -}
{-----------------}

runWeb :: (MonadUnliftIO m , MonadLoggerIO m) => WebConfig -> m ()
runWeb cfg@WebConfig {webPort = port, webReqLog = reqlog} = do
    reqLogger <- logIt
    runner <- askRunInIO
    S.scottyT port (runner . (`runReaderT` cfg)) $ do
        when reqlog $ S.middleware reqLogger
        S.defaultHandler defHandler
        handlePaths
        S.notFound $ S.raise ThingNotFound

handlePaths ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => S.ScottyT Except (ReaderT WebConfig m) ()
handlePaths = do
    -- Block Paths
    path (GetBlock <$> paramLazy <*> paramDef) scottyBlock blockDataToEncoding
    path (GetBlocks <$> param <*> paramDef)
         scottyBlocks
         (list . blockDataToEncoding)
    path (GetBlockRaw <$> paramLazy) scottyBlockRaw (const toEncoding)
    path (GetBlockBest <$> paramDef) scottyBlockBest blockDataToEncoding
    path (return GetBlockBestRaw) scottyBlockBestRaw (const toEncoding)
    path (GetBlockHeight <$> paramLazy <*> paramDef)
         scottyBlockHeight
         (list . blockDataToEncoding)
    path (GetBlockHeightRaw <$> paramLazy) scottyBlockHeightRaw (const toEncoding)

    S.get "/block/time/:time" $ scottyBlockTime False
    S.get "/block/time/:time/raw" $ scottyBlockTime True
    S.get "/block/heights" scottyBlockHeights
    S.get "/block/latest" scottyBlockLatest
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

path ::
       (ApiResource a b, MonadIO m)
    => WebT m a
    -> (a -> WebT m b)
    -> (Network -> b -> Encoding)
    -> S.ScottyT Except (ReaderT WebConfig m) ()
path parser action encJson =
    S.addroute (resourceMethod proxy) (capturePath proxy) $ do
        setHeaders
        proto <- setupContentType
        net <- lift $ asks (storeNetwork . webStore)
        apiRes <- parser
        res <- action apiRes
        S.raw $
            if proto
                then runPutLazy $ put res
                else encodingToLazyByteString $ encJson net res
  where
    toProxy :: WebT m a -> Proxy a
    toProxy = const Proxy
    proxy = toProxy parser

{- GET Block / GET Blocks -}

scottyBlock ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetBlock -> WebT m BlockData
scottyBlock (GetBlock h (NoTx noTx)) =
    maybe (S.raise ThingNotFound) (return . pruneTx noTx) =<< getBlock h

scottyBlocks ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetBlocks -> WebT m [BlockData]
scottyBlocks (GetBlocks hs (NoTx noTx)) =
    map (pruneTx noTx) . catMaybes <$> mapM getBlock (nub hs)

pruneTx :: Bool -> BlockData -> BlockData
pruneTx False b = b
pruneTx True b  = b {blockDataTxs = take 1 (blockDataTxs b)}

{- GET BlockRaw -}

scottyBlockRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockRaw
    -> WebT m (RawResult Block)
scottyBlockRaw (GetBlockRaw h) = RawResult <$> getRawBlock h

getRawBlock :: (MonadUnliftIO m, MonadLoggerIO m) => BlockHash -> WebT m Block
getRawBlock h = do
    b <- maybe (S.raise ThingNotFound) return =<< getBlock h
    refuseLargeBlock b
    toRawBlock b

toRawBlock :: (Monad m, StoreRead m) => BlockData -> m Block
toRawBlock b = do
    let ths = blockDataTxs b
    txs <- map transactionData . catMaybes <$> mapM getTransaction ths
    return Block {blockHeader = blockDataHeader b, blockTxns = txs}

refuseLargeBlock :: Monad m => BlockData -> WebT m ()
refuseLargeBlock BlockData {blockDataTxs = txs} = do
    WebLimits {maxLimitFull = f} <- lift $ asks webMaxLimits
    when (length txs > fromIntegral f) $ S.raise BlockTooLarge

{- GET BlockBest / BlockBestRaw -}

scottyBlockBest ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetBlockBest -> WebT m BlockData
scottyBlockBest (GetBlockBest noTx) = do
    bestM <- getBestBlock
    maybe (S.raise ThingNotFound) (scottyBlock . (`GetBlock` noTx)) bestM

scottyBlockBestRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockBestRaw
    -> WebT m (RawResult Block)
scottyBlockBestRaw _ =
    RawResult <$> (maybe (S.raise ThingNotFound) getRawBlock =<< getBestBlock)

{- GET BlockHeight / BlockHeightRaw -}

scottyBlockHeight ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetBlockHeight -> WebT m [BlockData]
scottyBlockHeight (GetBlockHeight (HeightParam height) noTx) =
    scottyBlocks . (`GetBlocks` noTx) =<< getBlocksAtHeight height

scottyBlockHeightRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockHeightRaw
    -> WebT m (RawResultList Block)
scottyBlockHeightRaw (GetBlockHeightRaw (HeightParam height)) =
    RawResultList <$> (mapM getRawBlock =<< getBlocksAtHeight height)

{- Remove this comment -}

scottyBlockTime :: (MonadUnliftIO m, MonadLoggerIO m) => Bool -> WebT m ()
scottyBlockTime raw = do
    setHeaders
    TimeParam q <- paramLazy
    n <- getNoTx <$> param
    proto <- setupContentType
    m <- fmap (pruneTx n) <$> blockAtOrBefore q
    if raw
        then maybeSerial proto =<<
             case m of
                 Nothing -> return Nothing
                 Just d -> do
                     refuseLargeBlock d
                     Just <$> toRawBlock d
        else maybeSerialNet proto blockDataToEncoding m

scottyBlockHeights :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBlockHeights = do
    setHeaders
    HeightsParam heights <- param
    n <- getNoTx <$> param
    proto <- setupContentType
    bhs <- concat <$> mapM getBlocksAtHeight heights
    blocks <- map (pruneTx n) . catMaybes <$> mapM getBlock bhs
    protoSerialNet proto (list . blockDataToEncoding) blocks

scottyBlockLatest :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBlockLatest = do
    setHeaders
    n <- getNoTx <$> param
    proto <- setupContentType
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


scottyMempool :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyMempool = do
    setHeaders
    l <- fromIntegral <$> parseLimit False
    o <- fromIntegral <$> parseOffset
    proto <- setupContentType
    txs <- take l . drop o . map txRefHash <$> getMempool
    protoSerial proto txs

scottyTransaction :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyTransaction = do
    setHeaders
    txid <- paramLazy
    proto <- setupContentType
    res <- getTransaction txid
    maybeSerialNet proto transactionToEncoding res

scottyRawTransaction :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyRawTransaction = do
    setHeaders
    txid <- paramLazy
    proto <- setupContentType
    res <- fmap transactionData <$> getTransaction txid
    maybeSerialRaw proto res

scottyTxAfterHeight :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyTxAfterHeight = do
    setHeaders
    txid <- paramLazy
    HeightParam height <- paramLazy
    proto <- setupContentType
    res <- cbAfterHeight 10000 height txid
    protoSerial proto res

scottyTransactions :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyTransactions = do
    setHeaders
    txids <- param
    proto <- setupContentType
    txs <- catMaybes <$> mapM getTransaction (nub txids)
    protoSerialNet proto (list . transactionToEncoding) txs

scottyBlockTransactions :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBlockTransactions = do
    setHeaders
    h <- paramLazy
    proto <- setupContentType
    getBlock h >>= \case
        Just b -> do
            refuseLargeBlock b
            let ths = blockDataTxs b
            txs <- catMaybes <$> mapM getTransaction ths
            protoSerialNet proto (list . transactionToEncoding) txs
        Nothing -> S.raise ThingNotFound

scottyRawTransactions ::
       (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyRawTransactions = do
    setHeaders
    txids <- param
    proto <- setupContentType
    txs <- map transactionData . catMaybes <$> mapM getTransaction (nub txids)
    protoSerialRawList proto txs

scottyRawBlockTransactions ::
       (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyRawBlockTransactions = do
    setHeaders
    h <- paramLazy
    proto <- setupContentType
    getBlock h >>= \case
        Just b -> do
            refuseLargeBlock b
            let ths = blockDataTxs b
            txs <- map transactionData . catMaybes <$> mapM getTransaction ths
            protoSerialRawList proto txs
        Nothing -> S.raise ThingNotFound

scottyAddressTxs :: (MonadUnliftIO m, MonadLoggerIO m) => Bool -> WebT m ()
scottyAddressTxs full = do
    setHeaders
    a <- paramLazy
    l <- parseLimits full
    proto <- setupContentType
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
    as <- param
    l <- parseLimits full
    proto <- setupContentType
    if full
        then getAddressesTxsFull l as >>=
             protoSerialNet proto (list . transactionToEncoding)
        else getAddressesTxsLimit l as >>= protoSerial proto

scottyAddressUnspent :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyAddressUnspent = do
    setHeaders
    a <- paramLazy
    l <- parseLimits False
    proto <- setupContentType
    uns <- getAddressUnspentsLimit l a
    protoSerialNet proto (list . unspentToEncoding) uns

scottyAddressesUnspent :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyAddressesUnspent = do
    setHeaders
    as <- param
    l <- parseLimits False
    proto <- setupContentType
    uns <- getAddressesUnspentsLimit l as
    protoSerialNet proto (list . unspentToEncoding) uns

scottyAddressBalance :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyAddressBalance = do
    setHeaders
    a <- paramLazy
    proto <- setupContentType
    res <- getBalance a
    protoSerialNet proto balanceToEncoding res

scottyAddressesBalances :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyAddressesBalances = do
    setHeaders
    as <- param
    proto <- setupContentType
    res <- getBalances as
    protoSerialNet proto (list . balanceToEncoding) res

scottyXpubBalances :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyXpubBalances = do
    setHeaders
    nocache <- getNoCache <$> param
    xpub <- parseXPubSpec
    proto <- setupContentType
    res <-
        filter (not . nullBalance . xPubBal) <$>
        lift (runNoCache nocache (xPubBals xpub))
    protoSerialNet proto (list . xPubBalToEncoding) res

scottyXpubTxs :: (MonadUnliftIO m, MonadLoggerIO m) => Bool -> WebT m ()
scottyXpubTxs full = do
    setHeaders
    nocache <- getNoCache <$> param
    xpub <- parseXPubSpec
    l <- parseLimits full
    proto <- setupContentType
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
        xpub <- parseXPubSpec
        proto <- setupContentType
        lift . withCache cache $ evictFromCache [xpub]
        protoSerial proto (GenericResult True)


scottyXpubUnspents :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyXpubUnspents = do
    setHeaders
    nocache <- getNoCache <$> param
    xpub <- parseXPubSpec
    proto <- setupContentType
    l <- parseLimits False
    uns <- lift . runNoCache nocache $ xPubUnspents xpub l
    protoSerialNet proto (list . xPubUnspentToEncoding) uns

scottyXpubSummary :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyXpubSummary = do
    setHeaders
    nocache <- getNoCache <$> param
    xpub <- parseXPubSpec
    proto <- setupContentType
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
    proto <- setupContentType
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
    proto <- setupContentType
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
    proto <- setupContentType
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
    proto <- setupContentType
    h <- lift $ healthCheck net mgr chn tos
    when (not (healthOK h) || not (healthSynced h)) $ S.status status503
    protoSerial proto h

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

{---------------------}
{- Parameter Parsing -}
{---------------------}

-- | Returns @Nothing@ if the parameter is not supplied. Raises an exception on
-- parse failure.
paramOptional :: (Param a, Monad m) => WebT m (Maybe a)
paramOptional = go Proxy
  where
    go :: (Param a, Monad m) => Proxy a -> WebT m (Maybe a)
    go proxy = do
        net <- lift $ asks (storeNetwork . webStore)
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
    resM <- paramOptional `S.rescue` (const $ return Nothing)
    maybe (S.next) return resM

parseStart :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m (Maybe Start)
parseStart =
    runMaybeT $ do
        s <- MaybeT paramOptional
        case s of
            StartParamHash {startParamHash = h} -> start_tx h <|> start_block h
            StartParamHeight {startParamHeight = h} -> start_height h
            StartParamTime {startParamTime = q} -> start_time q
  where
    start_height h = return $ AtBlock h
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

parseLimits :: (MonadLoggerIO m, MonadUnliftIO m) => Bool -> WebT m Limits
parseLimits full = Limits <$> parseOffset <*> parseLimit full <*> parseStart

parseOffset :: Monad m => WebT m Word32
parseOffset = do
    OffsetParam o <- paramDef
    limits <- lift $ asks webMaxLimits
    when (maxLimitOffset limits > 0 && o > maxLimitOffset limits) $
        S.raise . UserError $
        "offset exceeded: " <> show o <> " > " <> show (maxLimitOffset limits)
    return o

parseLimit :: Monad m => Bool -> WebT m Word32
parseLimit full = do
    limits <- lift $ asks webMaxLimits
    let m
            | full && maxLimitFull limits > 0 = maxLimitFull limits
            | otherwise = maxLimitCount limits
        d = maxLimitDefault limits
    f m . maybe d getLimitParam <$> paramOptional
  where
    f a 0 = a
    f 0 b = b
    f a b = min a b

parseXPubSpec :: Monad m => WebT m XPubSpec
parseXPubSpec = (<$> parseDeriveType) . XPubSpec =<< paramLazy

parseDeriveType :: Monad m => WebT m DeriveType
parseDeriveType = do
    dType <- paramDef -- Default is DeriveNormal
    net <- lift $ asks (storeNetwork . webStore)
    when (not (getSegWit net) && dType /= DeriveNormal) $
        S.raise . UserError $
        "Invalid derivation on network " <> getNetworkName net
    return dType

{-------------}
{- Utilities -}
{-------------}

setHeaders :: (Monad m, ScottyError e) => ActionT e m ()
setHeaders = S.setHeader "Access-Control-Allow-Origin" "*"

defHandler :: Monad m => Except -> WebT m ()
defHandler e = do
    proto <- setupContentType
    case e of
        ThingNotFound -> S.status status404
        BadRequest    -> S.status status400
        UserError _   -> S.status status400
        StringError _ -> S.status status400
        ServerError   -> S.status status500
        BlockTooLarge -> S.status status403
    protoSerial proto e

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

