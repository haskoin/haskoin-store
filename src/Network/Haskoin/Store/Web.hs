{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
module Network.Haskoin.Store.Web where

import           Conduit                            hiding (runResourceT)
import           Control.Applicative                ((<|>))
import           Control.Monad                      (forM_, forever, guard,
                                                     mzero, unless, when, (<=<))
import           Control.Monad.Logger               (Loc, LogLevel, LogSource,
                                                     LogStr, LoggingT (..),
                                                     MonadLogger, MonadLoggerIO,
                                                     askLoggerIO, logInfoS,
                                                     monadLoggerLog,
                                                     runLoggingT)
import           Control.Monad.Reader               (ReaderT, ask, runReaderT)
import           Control.Monad.Trans.Maybe          (MaybeT (..), runMaybeT)
import           Data.Aeson                         (ToJSON (..), object, (.=))
import           Data.Aeson.Encoding                (encodingToLazyByteString,
                                                     fromEncoding)
import qualified Data.ByteString                    as B
import           Data.ByteString.Builder            (Builder, lazyByteString)
import qualified Data.ByteString.Lazy               as L
import qualified Data.ByteString.Lazy.Char8         as C
import           Data.Char                          (isSpace)
import           Data.Function                      (on)
import qualified Data.HashMap.Strict                as H
import           Data.List                          (nub, sortBy)
import           Data.Maybe                         (catMaybes, fromMaybe,
                                                     isJust, isNothing,
                                                     listToMaybe, mapMaybe)
import           Data.Serialize                     as Serialize
import           Data.String.Conversions            (cs)
import           Data.Text                          (Text)
import qualified Data.Text                          as T
import qualified Data.Text.Encoding                 as T
import qualified Data.Text.Lazy                     as T.Lazy
import           Data.Time.Clock                    (NominalDiffTime,
                                                     diffUTCTime,
                                                     getCurrentTime)
import           Data.Time.Clock.System             (getSystemTime,
                                                     systemSeconds)
import           Data.Word                          (Word32, Word64)
import           Database.RocksDB                   (Property (..), getProperty)
import           Haskoin                            (Address, Block (..),
                                                     BlockHash (..),
                                                     BlockHeader (..),
                                                     BlockHeight,
                                                     BlockNode (..),
                                                     GetData (..), Hash256,
                                                     InvType (..),
                                                     InvVector (..), KeyIndex,
                                                     Message (..), Network (..),
                                                     OutPoint (..), Tx,
                                                     TxHash (..),
                                                     VarString (..),
                                                     Version (..), XPubKey,
                                                     decodeHex, deriveAddr,
                                                     deriveCompatWitnessAddr,
                                                     deriveWitnessAddr,
                                                     eitherToMaybe, headerHash,
                                                     hexToBlockHash,
                                                     hexToTxHash, pubSubKey,
                                                     sockToHostAddress,
                                                     stringToAddr, txHash,
                                                     xPubImport)
import           Haskoin.Node                       (Chain, Manager,
                                                     OnlinePeer (..),
                                                     chainGetBest,
                                                     managerGetPeers,
                                                     sendMessage)
import           Network.Haskoin.Store.Data.RocksDB (withRocksDB)
import           Network.Haskoin.Store.Data.Types   (Balance (..),
                                                     BinSerial (..),
                                                     BlockDB (..),
                                                     BlockData (..),
                                                     BlockRef (..),
                                                     BlockTx (..), Event (..),
                                                     HealthCheck (..),
                                                     JsonSerial (..), Limit,
                                                     Offset,
                                                     PeerInformation (..),
                                                     PubExcept (..), Store (..),
                                                     StoreEvent (..),
                                                     StoreInput (..),
                                                     StoreRead (..),
                                                     StoreStream (..),
                                                     Transaction (..),
                                                     TxAfterHeight (..),
                                                     TxData (..), TxId (..),
                                                     UnixTime, Unspent,
                                                     XPubBal (..),
                                                     XPubSummary (..),
                                                     XPubUnspent (..),
                                                     applyLimit,
                                                     applyOffsetLimit,
                                                     blockAtOrBefore,
                                                     getTransaction, isCoinbase,
                                                     transactionData,
                                                     zeroBalance)
import           Network.HTTP.Types                 (Status (..), status400,
                                                     status404, status500,
                                                     status503)
import           Network.Wai                        (Middleware, Request (..),
                                                     responseStatus)
import           NQE                                (Publisher, receive,
                                                     withSubscription)
import           Text.Printf                        (printf)
import           Text.Read                          (readMaybe)
import           UnliftIO                           (Exception, TBQueue,
                                                     askRunInIO, atomically,
                                                     readTBQueue, timeout,
                                                     writeTBQueue)
import           UnliftIO.Resource                  (runResourceT)
import           Web.Scotty.Internal.Types          (ActionT)
import           Web.Scotty.Trans                   (Parsable, ScottyError)
import qualified Web.Scotty.Trans                   as S

type LoggerIO = Loc -> LogSource -> LogLevel -> LogStr -> IO ()

type WebT m = ActionT Except (ReaderT BlockDB m)

type DeriveAddr = XPubKey -> KeyIndex -> Address

data Except
    = ThingNotFound
    | ServerError
    | BadRequest
    | UserError String
    | StringError String
    deriving Eq

instance Show Except where
    show ThingNotFound   = "not found"
    show ServerError     = "you made me kill a unicorn"
    show BadRequest      = "bad request"
    show (UserError s)   = s
    show (StringError _) = "you killed the dragon with your bare hands"

instance Exception Except

instance ScottyError Except where
    stringError = StringError
    showError = T.Lazy.pack . show

instance ToJSON Except where
    toJSON e = object ["error" .= T.pack (show e)]

instance JsonSerial Except where
    jsonSerial _ = toEncoding
    jsonValue _ = toJSON

instance BinSerial Except where
    binSerial _ ex =
        case ex of
            ThingNotFound -> putWord8 0
            ServerError   -> putWord8 1
            BadRequest    -> putWord8 2
            UserError s   -> putWord8 3 >> Serialize.put s
            StringError s -> putWord8 4 >> Serialize.put s
    binDeserial _ =
        getWord8 >>= \case
            0 -> return ThingNotFound
            1 -> return ServerError
            2 -> return BadRequest
            3 -> UserError <$> Serialize.get
            4 -> StringError <$> Serialize.get
            _ -> mzero

data WebConfig =
    WebConfig
        { webPort      :: !Int
        , webNetwork   :: !Network
        , webDB        :: !BlockDB
        , webPublisher :: !(Publisher StoreEvent)
        , webStore     :: !Store
        , webMaxLimits :: !MaxLimits
        , webReqLog    :: !Bool
        , webTimeouts  :: !Timeouts
        }

data MaxLimits =
    MaxLimits
        { maxLimitCount   :: !Word32
        , maxLimitFull    :: !Word32
        , maxLimitOffset  :: !Word32
        , maxLimitDefault :: !Word32
        }
    deriving (Eq, Show)

data Timeouts =
    Timeouts
        { txTimeout    :: !Word64
        , blockTimeout :: !Word64
        }
    deriving (Eq, Show)

newtype MyBlockHash = MyBlockHash {myBlockHash :: BlockHash}
newtype MyTxHash = MyTxHash {myTxHash :: TxHash}

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
            x <- fmap B.reverse (decodeHex (cs s)) >>= eitherToMaybe . decode
            return StartParamHash {startParamHash = x}
        g = do
            x <- readMaybe (cs s) :: Maybe Integer
            guard $ 0 <= x && x <= 1230768000
            return StartParamHeight {startParamHeight = fromIntegral x}
        t = do
            x <- readMaybe (cs s)
            guard $ x > 1230768000
            return StartParamTime {startParamTime = x}

instance MonadLoggerIO m => StoreRead (WebT m) where
    getBestBlock = lift getBestBlock
    getBlocksAtHeight = lift . getBlocksAtHeight
    getBlock = lift . getBlock
    getTxData = lift . getTxData
    getSpender = lift . getSpender
    getSpenders = lift . getSpenders
    getOrphanTx = lift . getOrphanTx
    getUnspent = lift . getUnspent
    getBalance = lift . getBalance
    getBalances = lift . getBalances
    getMempool = lift getMempool
    getAddressesTxs addrs start limit =
        lift (getAddressesTxs addrs start limit)
    getAddressesUnspents addrs start limit =
        lift (getAddressesUnspents addrs start limit)

askDB :: Monad m => WebT m BlockDB
askDB = lift ask

runStream ::
       MonadUnliftIO m
    => LoggerIO
    -> s
    -> ReaderT s (ResourceT (LoggingT m)) a
    -> m a
runStream l s f = runLoggingT (runResourceT (runReaderT f s)) l

defHandler :: Monad m => Network -> Except -> WebT m ()
defHandler net e = do
    proto <- setupBin
    case e of
        ThingNotFound -> S.status status404
        BadRequest    -> S.status status400
        UserError _   -> S.status status400
        StringError _ -> S.status status400
        ServerError   -> S.status status500
    protoSerial net proto e

maybeSerial ::
       (Monad m, JsonSerial a, BinSerial a)
    => Network
    -> Bool -- ^ binary
    -> Maybe a
    -> WebT m ()
maybeSerial _ _ Nothing        = S.raise ThingNotFound
maybeSerial net proto (Just x) = S.raw $ serialAny net proto x

protoSerial ::
       (Monad m, JsonSerial a, BinSerial a)
    => Network
    -> Bool
    -> a
    -> WebT m ()
protoSerial net proto = S.raw . serialAny net proto

scottyBestBlock ::
       (MonadLoggerIO m, MonadUnliftIO m) => Network -> Bool -> WebT m ()
scottyBestBlock net raw = do
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
        then rawBlock b >>= protoSerial net proto
        else protoSerial net proto (pruneTx n b)

scottyBlock ::
       (MonadLoggerIO m, MonadUnliftIO m) => Network -> Bool -> WebT m ()
scottyBlock net raw = do
    setHeaders
    block <- myBlockHash <$> S.param "block"
    n <- parseNoTx
    proto <- setupBin
    b <-
        getBlock block >>= \case
            Nothing -> S.raise ThingNotFound
            Just b -> return b
    if raw
        then rawBlock b >>= protoSerial net proto
        else protoSerial net proto (pruneTx n b)

scottyBlockHeight ::
       (MonadLoggerIO m, MonadUnliftIO m) => Network -> Bool -> WebT m ()
scottyBlockHeight net raw = do
    setHeaders
    height <- S.param "height"
    n <- parseNoTx
    proto <- setupBin
    hs <- getBlocksAtHeight height
    db <- askDB
    l <- askLoggerIO
    if raw
        then S.stream $ \io flush' -> do
                 runStream l db . runConduit $
                     yieldMany hs .| concatMapMC getBlock .| mapMC rawBlock .|
                     streamAny net proto io
                 flush'
        else S.stream $ \io flush' -> do
                 runStream l db . runConduit $
                     yieldMany hs .| concatMapMC getBlock .| mapC (pruneTx n) .|
                     streamAny net proto io
                 flush'

scottyBlockTime ::
       (MonadLoggerIO m, MonadUnliftIO m) => Network -> Bool -> WebT m ()
scottyBlockTime net raw = do
    setHeaders
    q <- S.param "time"
    n <- parseNoTx
    proto <- setupBin
    m <- fmap (pruneTx n) <$> blockAtOrBefore q
    if raw
        then maybeSerial net proto =<<
             case m of
                 Nothing -> return Nothing
                 Just d  -> Just <$> rawBlock d
        else maybeSerial net proto m

scottyBlockHeights :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> WebT m ()
scottyBlockHeights net = do
    setHeaders
    heights <- S.param "heights"
    n <- parseNoTx
    proto <- setupBin
    db <- askDB
    l <- askLoggerIO
    S.stream $ \io flush' -> do
        runStream l db . runConduit $
            yieldMany (nub heights) .| concatMapMC getBlocksAtHeight .|
            concatMapMC getBlock .|
            mapC (pruneTx n) .|
            streamAny net proto io
        flush'

scottyBlockLatest :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> WebT m ()
scottyBlockLatest net = do
    setHeaders
    n <- parseNoTx
    proto <- setupBin
    db <- askDB
    l <- askLoggerIO
    getBestBlock >>= \case
        Just h ->
            S.stream $ \io flush' -> do
                runStream l db . runConduit $
                    f n h 100 .| streamAny net proto io
                flush'
        Nothing -> S.raise ThingNotFound
  where
    f :: (Monad m, StoreRead m)
      => Bool
      -> BlockHash
      -> Int
      -> ConduitT () BlockData m ()
    f _ _ 0 = return ()
    f n h i =
        lift (getBlock h) >>= \case
            Nothing -> return ()
            Just b -> do
                yield $ pruneTx n b
                if blockDataHeight b <= 0
                    then return ()
                    else f n (prevBlock (blockDataHeader b)) (i - 1)


scottyBlocks :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> WebT m ()
scottyBlocks net = do
    setHeaders
    blocks <- map myBlockHash <$> S.param "blocks"
    n <- parseNoTx
    proto <- setupBin
    db <- askDB
    l <- askLoggerIO
    S.stream $ \io flush' -> do
        runStream l db . runConduit $
            yieldMany (nub blocks) .| concatMapMC getBlock .| mapC (pruneTx n) .|
            streamAny net proto io
        flush'

scottyMempool :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> WebT m ()
scottyMempool net = do
    setHeaders
    proto <- setupBin
    txs <- map snd <$> getMempool
    protoSerial net proto txs

scottyTransaction :: MonadLoggerIO m => Network -> WebT m ()
scottyTransaction net = do
    setHeaders
    txid <- myTxHash <$> S.param "txid"
    proto <- setupBin
    res <- getTransaction txid
    maybeSerial net proto res

scottyRawTransaction :: MonadLoggerIO m => Network -> WebT m ()
scottyRawTransaction net = do
    setHeaders
    txid <- myTxHash <$> S.param "txid"
    proto <- setupBin
    res <- fmap transactionData <$> getTransaction txid
    maybeSerial net proto res

scottyTxAfterHeight :: MonadLoggerIO m => Network -> WebT m ()
scottyTxAfterHeight net = do
    setHeaders
    txid <- myTxHash <$> S.param "txid"
    height <- S.param "height"
    proto <- setupBin
    res <- cbAfterHeight 10000 height txid
    protoSerial net proto res

scottyTransactions :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> WebT m ()
scottyTransactions net = do
    setHeaders
    txids <- map myTxHash <$> S.param "txids"
    proto <- setupBin
    db <- askDB
    l <- askLoggerIO
    S.stream $ \io flush' -> do
        runStream l db . runConduit $
            yieldMany (nub txids) .| concatMapMC getTransaction .|
            streamAny net proto io
        flush'

scottyBlockTransactions ::
       (MonadLoggerIO m, MonadUnliftIO m) => Network -> WebT m ()
scottyBlockTransactions net = do
    setHeaders
    h <- myBlockHash <$> S.param "block"
    proto <- setupBin
    db <- askDB
    l <- askLoggerIO
    getBlock h >>= \case
        Just b ->
            S.stream $ \io flush' -> do
                runStream l db . runConduit $
                    yieldMany (blockDataTxs b) .| concatMapMC getTransaction .|
                    streamAny net proto io
                flush'
        Nothing -> S.raise ThingNotFound

scottyRawTransactions ::
       (MonadLoggerIO m, MonadUnliftIO m) => Network -> WebT m ()
scottyRawTransactions net = do
    setHeaders
    txids <- map myTxHash <$> S.param "txids"
    proto <- setupBin
    db <- askDB
    l <- askLoggerIO
    S.stream $ \io flush' -> do
        runStream l db . runConduit $
            yieldMany (nub txids) .| concatMapMC getTransaction .|
            mapC transactionData .|
            streamAny net proto io
        flush'

rawBlock :: (Monad m, StoreRead m) => BlockData -> m Block
rawBlock b = do
    let h = blockDataHeader b
    txs <-
        runConduit $
        yieldMany (blockDataTxs b) .| concatMapMC getTransaction .|
        mapC transactionData .|
        sinkList
    return Block {blockHeader = h, blockTxns = txs}

scottyRawBlockTransactions ::
       (MonadLoggerIO m, MonadUnliftIO m) => Network -> WebT m ()
scottyRawBlockTransactions net = do
    setHeaders
    h <- myBlockHash <$> S.param "block"
    proto <- setupBin
    db <- askDB
    l <- askLoggerIO
    getBlock h >>= \case
        Just b ->
            S.stream $ \io flush' -> do
                runStream l db . runConduit $
                    yieldMany (blockDataTxs b) .| concatMapMC getTransaction .|
                    mapC transactionData .|
                    streamAny net proto io
                flush'
        Nothing -> S.raise ThingNotFound

scottyAddressTxs ::
       (MonadLoggerIO m, MonadUnliftIO m)
    => Network
    -> MaxLimits
    -> Bool
    -> WebT m ()
scottyAddressTxs net limits full = do
    setHeaders
    a <- parseAddress net
    s <- getStart
    o <- getOffset limits
    l <- getLimit limits full
    proto <- setupBin
    db <- askDB
    lg <- askLoggerIO
    S.stream $ \io flush' -> do
        runStream lg db . runConduit $ f proto o l s a io
        flush'
  where
    f proto o l s a io
        | full = getAddressTxsFull o l s a .| streamAny net proto io
        | otherwise = getAddressTxsLimit o l s a .| streamAny net proto io

scottyAddressesTxs ::
       (MonadLoggerIO m, MonadUnliftIO m)
    => Network
    -> MaxLimits
    -> Bool
    -> WebT m ()
scottyAddressesTxs net limits full = do
    setHeaders
    as <- parseAddresses net
    s <- getStart
    l <- getLimit limits full
    proto <- setupBin
    db <- askDB
    lg <- askLoggerIO
    S.stream $ \io flush' -> do
        runStream lg db . runConduit $ f proto l s as io
        flush'
  where
    f proto l s as io
        | full = getAddressesTxsFull l s as .| streamAny net proto io
        | otherwise = getAddressesTxsLimit l s as .| streamAny net proto io

scottyAddressUnspent ::
       (MonadLoggerIO m, MonadUnliftIO m) => Network -> MaxLimits -> WebT m ()
scottyAddressUnspent net limits = do
    setHeaders
    a <- parseAddress net
    s <- getStart
    o <- getOffset limits
    l <- getLimit limits False
    proto <- setupBin
    db <- askDB
    lg <- askLoggerIO
    S.stream $ \io flush' -> do
        runStream lg db . runConduit $
            getAddressUnspentsLimit o l s a .| streamAny net proto io
        flush'

scottyAddressesUnspent ::
       (MonadLoggerIO m, MonadUnliftIO m) => Network -> MaxLimits -> WebT m ()
scottyAddressesUnspent net limits = do
    setHeaders
    as <- parseAddresses net
    s <- getStart
    l <- getLimit limits False
    proto <- setupBin
    db <- askDB
    lg <- askLoggerIO
    S.stream $ \io flush' -> do
        runStream lg db . runConduit $
            getAddressesUnspentsLimit l s as .| streamAny net proto io
        flush'

scottyAddressBalance :: MonadLoggerIO m => Network -> WebT m ()
scottyAddressBalance net = do
    setHeaders
    a <- parseAddress net
    proto <- setupBin
    res <- fromMaybe (zeroBalance a) <$> getBalance a
    protoSerial net proto res

scottyAddressesBalances ::
       (MonadLoggerIO m, MonadUnliftIO m) => Network -> WebT m ()
scottyAddressesBalances net = do
    setHeaders
    as <- parseAddresses net
    proto <- setupBin
    res <- zipWith f as <$> getBalances as
    protoSerial net proto res
  where
    f a Nothing  = zeroBalance a
    f _ (Just b) = b

scottyXpubBalances ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Network
    -> WebT m ()
scottyXpubBalances net = do
    setHeaders
    xpub <- parseXpub net
    proto <- setupBin
    derive <- parseDeriveAddrs net
    res <- lift (xpubBals derive xpub)
    protoSerial net proto res

scottyXpubTxs ::
       (MonadLoggerIO m, MonadUnliftIO m)
    => Network
    -> MaxLimits
    -> Bool
    -> WebT m ()
scottyXpubTxs net limits full = do
    setHeaders
    x <- parseXpub net
    s <- getStart
    l <- getLimit limits full
    derive <- parseDeriveAddrs net
    proto <- setupBin
    db <- askDB
    lg <- askLoggerIO
    S.stream $ \io flush' -> do
        runStream lg db . runConduit $ f proto l s derive io x
        flush'
  where
    f proto l s derive io x
        | full =
            xpubTxs s l derive x .|
            concatMapMC (getTransaction . blockTxHash) .|
            streamAny net proto io
        | otherwise = xpubTxs s l derive x .| streamAny net proto io

xpubTxs ::
       (MonadUnliftIO m, StoreRead m, StoreStream m)
    => Maybe BlockRef
    -> Maybe Limit
    -> DeriveAddr
    -> XPubKey
    -> ConduitT i BlockTx m ()
xpubTxs start limit derive xpub = do
    bs <- lift (xpubBals derive xpub)
    let as = map (balanceAddress . xPubBal) bs
    ts <- mapM_ (\a -> getAddressTxs a start .| applyLimit limit) as .| sinkList
    let ts' = nub $ sortBy (flip compare `on` blockTxBlock) ts
    forM_ ts' yield .| applyLimit limit

scottyXpubUnspents ::
       (MonadLoggerIO m, MonadUnliftIO m) => Network -> MaxLimits -> WebT m ()
scottyXpubUnspents net limits = do
    setHeaders
    x <- parseXpub net
    proto <- setupBin
    s <- getStart
    l <- getLimit limits False
    derive <- parseDeriveAddrs net
    db <- askDB
    lg <- askLoggerIO
    S.stream $ \io flush' -> do
        runStream lg db . runConduit $
            xpubUnspentLimit l s derive x .| streamAny net proto io
        flush'

scottyXpubSummary ::
       (MonadLoggerIO m, MonadUnliftIO m) => Network -> WebT m ()
scottyXpubSummary net = do
    setHeaders
    x <- parseXpub net
    derive <- parseDeriveAddrs net
    proto <- setupBin
    db <- askDB
    lg <- askLoggerIO
    res <- liftIO . runStream lg db $ xpubSummary derive x
    protoSerial net proto res

scottyPostTx ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Network
    -> Store
    -> Publisher StoreEvent
    -> WebT m ()
scottyPostTx net st pub = do
    setHeaders
    proto <- setupBin
    b <- S.body
    let bin = eitherToMaybe . Serialize.decode
        hex = bin <=< decodeHex . cs . C.filter (not . isSpace)
    tx <-
        case hex b <|> bin (L.toStrict b) of
            Nothing -> S.raise $ UserError "decode tx fail"
            Just x  -> return x
    lift (publishTx net pub st tx) >>= \case
        Right () -> do
            protoSerial net proto (TxId (txHash tx))
        Left e -> do
            case e of
                PubNoPeers          -> S.status status500
                PubTimeout          -> S.status status500
                PubPeerDisconnected -> S.status status500
                PubReject _         -> S.status status400
            protoSerial net proto (UserError (show e))
            S.finish

scottyDbStats :: MonadLoggerIO m => WebT m ()
scottyDbStats = do
    setHeaders
    BlockDB {blockDB = db} <- askDB
    stats <- lift (getProperty db Stats)
    case stats of
      Nothing -> do
          S.text "Could not get stats"
      Just txt -> do
          S.text $ cs txt

scottyEvents ::
       (MonadLoggerIO m, MonadUnliftIO m)
    => Network
    -> Publisher StoreEvent
    -> WebT m ()
scottyEvents net pub = do
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
                                serialAny net proto e <>
                                if proto
                                    then mempty
                                    else "\n"
                         in io (lazyByteString bs)

scottyPeers :: MonadLoggerIO m => Network -> Store -> WebT m ()
scottyPeers net st = do
    setHeaders
    proto <- setupBin
    ps <- getPeersInformation (storeManager st)
    protoSerial net proto ps

scottyHealth ::
       (MonadLoggerIO m, MonadUnliftIO m)
    => Network
    -> Store
    -> Timeouts
    -> WebT m ()
scottyHealth net st tos = do
    setHeaders
    proto <- setupBin
    db <- askDB
    lg <- askLoggerIO
    h <-
        liftIO . runStream lg db $
        healthCheck net (storeManager st) (storeChain st) tos
    when (not (healthOK h) || not (healthSynced h)) $ S.status status503
    protoSerial net proto h

runWeb :: (MonadLoggerIO m, MonadUnliftIO m) => WebConfig -> m ()
runWeb WebConfig { webDB = bdb
                 , webPort = port
                 , webNetwork = net
                 , webStore = st
                 , webPublisher = pub
                 , webMaxLimits = limits
                 , webReqLog = reqlog
                 , webTimeouts = tos
                 } = do
    req_logger <-
        if reqlog
            then Just <$> logIt
            else return Nothing
    runner <- askRunInIO
    S.scottyT port (runner . withRocksDB bdb) $ do
        case req_logger of
            Just m  -> S.middleware m
            Nothing -> return ()
        S.defaultHandler (defHandler net)
        S.get "/block/best" $ scottyBestBlock net False
        S.get "/block/best/raw" $ scottyBestBlock net True
        S.get "/block/:block" $ scottyBlock net False
        S.get "/block/:block/raw" $ scottyBlock net True
        S.get "/block/height/:height" $ scottyBlockHeight net False
        S.get "/block/height/:height/raw" $ scottyBlockHeight net True
        S.get "/block/time/:time" $ scottyBlockTime net False
        S.get "/block/time/:time/raw" $ scottyBlockTime net True
        S.get "/block/heights" $ scottyBlockHeights net
        S.get "/block/latest" $ scottyBlockLatest net
        S.get "/blocks" $ scottyBlocks net
        S.get "/mempool" $ scottyMempool net
        S.get "/transaction/:txid" $ scottyTransaction net
        S.get "/transaction/:txid/raw" $ scottyRawTransaction net
        S.get "/transaction/:txid/after/:height" $ scottyTxAfterHeight net
        S.get "/transactions" $ scottyTransactions net
        S.get "/transactions/raw" $ scottyRawTransactions net
        S.get "/transactions/block/:block" $ scottyBlockTransactions net
        S.get "/transactions/block/:block/raw" $ scottyRawBlockTransactions net
        S.get "/address/:address/transactions" $
            scottyAddressTxs net limits False
        S.get "/address/:address/transactions/full" $
            scottyAddressTxs net limits True
        S.get "/address/transactions" $ scottyAddressesTxs net limits False
        S.get "/address/transactions/full" $ scottyAddressesTxs net limits True
        S.get "/address/:address/unspent" $ scottyAddressUnspent net limits
        S.get "/address/unspent" $ scottyAddressesUnspent net limits
        S.get "/address/:address/balance" $ scottyAddressBalance net
        S.get "/address/balances" $ scottyAddressesBalances net
        S.get "/xpub/:xpub/balances" $ scottyXpubBalances net
        S.get "/xpub/:xpub/transactions" $ scottyXpubTxs net limits False
        S.get "/xpub/:xpub/transactions/full" $ scottyXpubTxs net limits True
        S.get "/xpub/:xpub/unspent" $ scottyXpubUnspents net limits
        S.get "/xpub/:xpub" $ scottyXpubSummary net
        S.post "/transactions" $ scottyPostTx net st pub
        S.get "/dbstats" scottyDbStats
        S.get "/events" $ scottyEvents net pub
        S.get "/peers" $ scottyPeers net st
        S.get "/health" $ scottyHealth net st tos
        S.notFound $ S.raise ThingNotFound

getStart :: (MonadLoggerIO m, MonadUnliftIO m) => WebT m (Maybe BlockRef)
getStart =
    runMaybeT $ do
        s <- MaybeT $ (Just <$> S.param "height") `S.rescue` const (return Nothing)
        do case s of
               StartParamHash {startParamHash = h} ->
                   start_tx h <|> start_block h
               StartParamHeight {startParamHeight = h} -> start_height h
               StartParamTime {startParamTime = q} -> start_time q
  where
    start_height h = return $ BlockRef h maxBound
    start_block h = do
        b <- MaybeT $ getBlock (BlockHash h)
        let g = blockDataHeight b
        return $ BlockRef g maxBound
    start_tx h = do
        t <- MaybeT $ getTxData (TxHash h)
        return $ txDataBlock t
    start_time q = do
        d <- MaybeT getBestBlock >>= MaybeT . getBlock
        if q <= fromIntegral (blockTimestamp (blockDataHeader d))
            then do
                b <- MaybeT $ blockAtOrBefore q
                let g = blockDataHeight b
                return $ BlockRef g maxBound
            else return $ MemRef q

getOffset :: Monad m => MaxLimits -> ActionT Except m Offset
getOffset limits = do
    o <- S.param "offset" `S.rescue` const (return 0)
    when (maxLimitOffset limits > 0 && o > maxLimitOffset limits) .
        S.raise . UserError $
        "offset exceeded: " <> show o <> " > " <> show (maxLimitOffset limits)
    return o

getLimit ::
       Monad m
    => MaxLimits
    -> Bool
    -> ActionT Except m (Maybe Limit)
getLimit limits full = do
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
                    then Just (min m d)
                    else Nothing
            Just n ->
                if m > 0
                    then Just (min m n)
                    else Just n

parseAddress :: (Monad m, ScottyError e) => Network -> ActionT e m Address
parseAddress net = do
    address <- S.param "address"
    case stringToAddr net address of
        Nothing -> S.next
        Just a  -> return a

parseAddresses :: (Monad m, ScottyError e) => Network -> ActionT e m [Address]
parseAddresses net = do
    addresses <- S.param "addresses"
    let as = mapMaybe (stringToAddr net) addresses
    unless (length as == length addresses) S.next
    return as

parseXpub :: (Monad m, ScottyError e) => Network -> ActionT e m XPubKey
parseXpub net = do
    t <- S.param "xpub"
    case xPubImport net t of
        Nothing -> S.next
        Just x  -> return x

parseDeriveAddrs :: (Monad m, ScottyError e) => Network -> ActionT e m DeriveAddr
parseDeriveAddrs net
    | getSegWit net = do
          t <- S.param "derive" `S.rescue` const (return "standard")
          return $ case (t :: Text) of
            "segwit" -> \i -> fst . deriveWitnessAddr i
            "compat" -> \i -> fst . deriveCompatWitnessAddr i
            _        -> \i -> fst . deriveAddr i
    | otherwise = return (\i -> fst . deriveAddr i)

parseNoTx :: (Monad m, ScottyError e) => ActionT e m Bool
parseNoTx = S.param "notx" `S.rescue` const (return False)

pruneTx :: Bool -> BlockData -> BlockData
pruneTx False b = b
pruneTx True b  = b {blockDataTxs = take 1 (blockDataTxs b)}

setHeaders :: (Monad m, ScottyError e) => ActionT e m ()
setHeaders = do
    S.setHeader "Access-Control-Allow-Origin" "*"

serialAny ::
       (JsonSerial a, BinSerial a)
    => Network
    -> Bool -- ^ binary
    -> a
    -> L.ByteString
serialAny net True  = runPutLazy . binSerial net
serialAny net False = encodingToLazyByteString . jsonSerial net

streamAny ::
       (JsonSerial i, BinSerial i, MonadIO m)
    => Network
    -> Bool -- ^ protobuf
    -> (Builder -> IO ())
    -> ConduitT i o m ()
streamAny net True io = binConduit net .| mapC lazyByteString .| streamConduit io
streamAny net False io = jsonListConduit net .| streamConduit io

jsonListConduit :: (JsonSerial a, Monad m) => Network -> ConduitT a Builder m ()
jsonListConduit net =
    yield "[" >> mapC (fromEncoding . jsonSerial net) .| intersperseC "," >> yield "]"

binConduit :: (BinSerial i, Monad m) => Network -> ConduitT i L.ByteString m ()
binConduit net = mapC (runPutLazy . binSerial net)

streamConduit :: MonadIO m => (i -> IO ()) -> ConduitT i o m ()
streamConduit io = mapM_C (liftIO . io)

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
       (MonadUnliftIO m, StoreRead m, StoreStream m)
    => Network
    -> Manager
    -> Chain
    -> Timeouts
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
        tt <- fst <$> ml <|> bd
        return $ min (compute_delta tt tm) bd'
    timeout_ok to td = fromMaybe False $ do
        td' <- td
        return $
          getAllowMinDifficultyBlocks net ||
          to == 0 ||
          td' <= to
    peer_count = fmap length <$> timeout 500000 (managerGetPeers mgr)
    block_best = runMaybeT $ do
        h <- MaybeT getBestBlock
        MaybeT $ getBlock h
    chain_best = timeout 500000 $ chainGetBest ch
    compute_delta a b = if b > a then b - a else 0

-- | Obtain information about connected peers from peer manager process.
getPeersInformation :: MonadIO m => Manager -> m [PeerInformation]
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
                , peerAddress = sockToHostAddress as
                , peerVersion = vs
                , peerServices = sv
                , peerRelay = rl
                }

deriveAddresses :: DeriveAddr -> XPubKey -> Word32 -> [(Word32, Address)]
deriveAddresses derive xpub start = map (\i -> (i, derive xpub i)) [start ..]

xpubBals ::
       (MonadUnliftIO m, StoreRead m)
    => DeriveAddr
    -> XPubKey
    -> m [XPubBal]
xpubBals derive xpub = do
    ext <- derive_until_gap 0 (deriveAddresses derive (pubSubKey xpub 0) 0)
    chg <- derive_until_gap 1 (deriveAddresses derive (pubSubKey xpub 1) 0)
    return (ext ++ chg)
  where
    xbalance _ Nothing _  = Nothing
    xbalance m (Just b) n = Just XPubBal {xPubBalPath = [m, n], xPubBal = b}
    derive_until_gap _ [] = return []
    derive_until_gap m as = do
        let n = 32
        let (as1, as2) = splitAt n as
        mbs <- getBalances (map snd as1)
        let xbs = zipWith (xbalance m) mbs (map fst as1)
        if all isNothing mbs
            then return (catMaybes xbs)
            else (catMaybes xbs <>) <$> derive_until_gap m as2

xpubUnspent ::
       ( MonadResource m
       , MonadUnliftIO m
       , StoreStream m
       , StoreRead m
       )
    => Maybe BlockRef
    -> DeriveAddr
    -> XPubKey
    -> ConduitT i XPubUnspent m ()
xpubUnspent start derive xpub = do
    xs <- filter positive <$> lift (xpubBals derive xpub)
    yieldMany xs .| go
  where
    positive XPubBal {xPubBal = Balance {balanceUnspentCount = c}} = c > 0
    go =
        awaitForever $ \XPubBal { xPubBalPath = p
                                , xPubBal = Balance {balanceAddress = a}
                                } ->
            getAddressUnspents a start .|
            mapC (\t -> XPubUnspent {xPubUnspentPath = p, xPubUnspent = t})

xpubUnspentLimit ::
       ( MonadResource m
       , MonadUnliftIO m
       , StoreStream m
       , StoreRead m
       )
    => Maybe Limit
    -> Maybe BlockRef
    -> DeriveAddr
    -> XPubKey
    -> ConduitT i XPubUnspent m ()
xpubUnspentLimit limit start derive xpub =
    xpubUnspent start derive xpub .| applyLimit limit

xpubSummary ::
       (MonadResource m, MonadUnliftIO m, StoreStream m, StoreRead m)
    => DeriveAddr
    -> XPubKey
    -> m XPubSummary
xpubSummary derive x = do
    bs <- xpubBals derive x
    let f XPubBal {xPubBalPath = p, xPubBal = Balance {balanceAddress = a}} =
            (a, p)
        pm = H.fromList $ map f bs
        ex = foldl max 0 [i | XPubBal {xPubBalPath = [0, i]} <- bs]
        ch = foldl max 0 [i | XPubBal {xPubBalPath = [1, i]} <- bs]
        uc =
            sum
                [ c
                | XPubBal {xPubBal = Balance {balanceUnspentCount = c}} <- bs
                ]
        xt = [b | b@XPubBal {xPubBalPath = [0, _]} <- bs]
        rx =
            sum
                [ r
                | XPubBal {xPubBal = Balance {balanceTotalReceived = r}} <- xt
                ]
    return
        XPubSummary
            { xPubSummaryConfirmed = sum (map (balanceAmount . xPubBal) bs)
            , xPubSummaryZero = sum (map (balanceZero . xPubBal) bs)
            , xPubSummaryReceived = rx
            , xPubUnspentCount = uc
            , xPubSummaryPaths = pm
            , xPubChangeIndex = ch
            , xPubExternalIndex = ex
            }

-- | Check if any of the ancestors of this transaction is a coinbase after the
-- specified height. Returns 'Nothing' if answer cannot be computed before
-- hitting limits.
cbAfterHeight ::
       (MonadIO m, StoreRead m)
    => Int -- ^ how many ancestors to test before giving up
    -> BlockHeight
    -> TxHash
    -> m TxAfterHeight
cbAfterHeight d h t
    | d <= 0 = return $ TxAfterHeight Nothing
    | otherwise = do
        x <- fmap snd <$> tst d t
        return $ TxAfterHeight x
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
                                     r e' . nub $
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
       (Monad m, StoreStream m)
    => Offset
    -> Maybe Limit
    -> Maybe BlockRef
    -> Address
    -> ConduitT i BlockTx m ()
getAddressTxsLimit offset limit start addr =
    getAddressTxs addr start .| applyOffsetLimit offset limit

getAddressTxsFull ::
       (Monad m, StoreStream m, StoreRead m)
    => Offset
    -> Maybe Limit
    -> Maybe BlockRef
    -> Address
    -> ConduitT i Transaction m ()
getAddressTxsFull offset limit start addr =
    getAddressTxsLimit offset limit start addr .|
    concatMapMC (getTransaction . blockTxHash)

getAddressesTxsLimit ::
       (MonadUnliftIO m, StoreRead m)
    => Maybe Limit
    -> Maybe BlockRef
    -> [Address]
    -> ConduitT i BlockTx m ()
getAddressesTxsLimit limit start addrs = do
    ts <- lift (getAddressesTxs addrs start limit)
    forM_ ts yield

getAddressesTxsFull ::
       (MonadResource m, MonadUnliftIO m, StoreStream m, StoreRead m)
    => Maybe Limit
    -> Maybe BlockRef
    -> [Address]
    -> ConduitT i Transaction m ()
getAddressesTxsFull limit start addrs =
    getAddressesTxsLimit limit start addrs .|
    concatMapMC (getTransaction . blockTxHash)

getAddressUnspentsLimit ::
       (Monad m, StoreStream m)
    => Offset
    -> Maybe Limit
    -> Maybe BlockRef
    -> Address
    -> ConduitT i Unspent m ()
getAddressUnspentsLimit offset limit start addr =
    getAddressUnspents addr start .| applyOffsetLimit offset limit

getAddressesUnspentsLimit ::
       (Monad m, StoreRead m)
    => Maybe Limit
    -> Maybe BlockRef
    -> [Address]
    -> ConduitT i Unspent m ()
getAddressesUnspentsLimit limit start addrs = do
    uns <- lift (getAddressesUnspents addrs start limit)
    forM_ uns yield

conduitToQueue :: MonadIO m => TBQueue (Maybe a) -> ConduitT a Void m ()
conduitToQueue q =
    await >>= \case
        Just x -> atomically (writeTBQueue q (Just x)) >> conduitToQueue q
        Nothing -> atomically $ writeTBQueue q Nothing

queueToConduit :: MonadIO m => TBQueue (Maybe a) -> ConduitT i a m ()
queueToConduit q =
    atomically (readTBQueue q) >>= \case
        Just x -> yield x >> queueToConduit q
        Nothing -> return ()

dedup :: (Eq i, Monad m) => ConduitT i i m ()
dedup =
    let dd Nothing =
            await >>= \case
                Just x -> do
                    yield x
                    dd (Just x)
                Nothing -> return ()
        dd (Just x) =
            await >>= \case
                Just y
                    | x == y -> dd (Just x)
                    | otherwise -> do
                        yield y
                        dd (Just y)
                Nothing -> return ()
      in dd Nothing

-- | Publish a new transaction to the network.
publishTx ::
       (MonadUnliftIO m, StoreRead m)
    => Network
    -> Publisher StoreEvent
    -> Store
    -> Tx
    -> m (Either PubExcept ())
publishTx net pub st tx =
    withSubscription pub $ \s ->
        getTransaction (txHash tx) >>= \case
            Just _ -> return $ Right ()
            Nothing -> go s
  where
    go s =
        managerGetPeers (storeManager st) >>= \case
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

logIt :: (MonadLoggerIO m, MonadUnliftIO m) => m Middleware
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
