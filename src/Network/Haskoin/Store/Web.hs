{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections     #-}

module Network.Haskoin.Store.Web where
import           Conduit                           hiding (runResourceT)
import           Control.Applicative               ((<|>))
import           Control.Exception                 ()
import           Control.Monad
import           Control.Monad.Logger
import           Control.Monad.Reader              (ReaderT)
import qualified Control.Monad.Reader              as R
import           Control.Monad.Trans.Maybe
import           Data.Aeson                        (ToJSON (..), object, (.=))
import           Data.Aeson.Encoding               (encodingToLazyByteString,
                                                    fromEncoding)
import qualified Data.ByteString                   as B
import           Data.ByteString.Builder
import qualified Data.ByteString.Lazy              as L
import qualified Data.ByteString.Lazy.Char8        as C
import           Data.Char
import           Data.Foldable
import           Data.Function
import qualified Data.HashMap.Strict               as H
import           Data.List
import           Data.Maybe
import           Data.Serialize                    as Serialize
import           Data.String.Conversions
import           Data.Text                         (Text)
import qualified Data.Text                         as T
import qualified Data.Text.Encoding                as T
import qualified Data.Text.Lazy                    as T.Lazy
import           Data.Time.Clock
import           Data.Time.Clock.System
import           Data.Vector                       (Vector, cons, (!))
import qualified Data.Vector                       as V
import           Data.Word
import           Database.RocksDB                  as R
import           Haskoin
import           Haskoin.Node
import           Network.Haskoin.Store.Data
import           Network.Haskoin.Store.Data.Cached
import           Network.Haskoin.Store.Messages
import           Network.HTTP.Types
import           Network.Wai
import           NQE
import           Text.Printf
import           Text.Read                         (readMaybe)
import           UnliftIO
import           UnliftIO.Resource
import           Web.Scotty.Internal.Types         (ActionT)
import           Web.Scotty.Trans                  (Parsable, ScottyError)
import qualified Web.Scotty.Trans                  as S

type WebT m = ActionT Except (ReaderT LayeredDB m)

type DeriveAddrs = XPubKey -> KeyIndex -> [(Address, PubKey, KeyIndex)]

type Offset = Word32
type Limit = Word32

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
        , webDB        :: !LayeredDB
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
        , maxLimitGap     :: !Word32
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

instance MonadIO m => StoreRead (WebT m) where
    isInitialized = lift isInitialized
    getBestBlock = lift getBestBlock
    getBlocksAtHeight = lift . getBlocksAtHeight
    getBlock = lift . getBlock
    getTxData = lift . getTxData
    getSpender = lift . getSpender
    getSpenders = lift . getSpenders
    getOrphanTx = lift . getOrphanTx
    getUnspent = lift . getUnspent
    getBalance = lift . getBalance
    getMempool = lift getMempool

askDB :: Monad m => WebT m LayeredDB
askDB = lift R.ask

runStream :: MonadUnliftIO m => s -> ReaderT s (ResourceT m) a -> m a
runStream s f = runResourceT (R.runReaderT f s)

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

scottyBestBlock :: MonadUnliftIO m => Network -> Bool -> WebT m ()
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

scottyBlock :: MonadUnliftIO m => Network -> Bool -> WebT m ()
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
    if raw
        then S.stream $ \io flush' -> do
                 runStream db . runConduit $
                     yieldMany hs .| concatMapMC getBlock .| mapMC rawBlock .|
                     streamAny net proto io
                 flush'
        else S.stream $ \io flush' -> do
                 runStream db . runConduit $
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
    S.stream $ \io flush' -> do
        runStream db . runConduit $
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
    getBestBlock >>= \case
        Just h ->
            S.stream $ \io flush' -> do
                runStream db . runConduit $ f n h 100 .| streamAny net proto io
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
    S.stream $ \io flush' -> do
        runStream db . runConduit $
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
    S.stream $ \io flush' -> do
        runStream db . runConduit $
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
    getBlock h >>= \case
        Just b ->
            S.stream $ \io flush' -> do
                runStream db . runConduit $
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
    S.stream $ \io flush' -> do
        runStream db . runConduit $
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
    getBlock h >>= \case
        Just b ->
            S.stream $ \io flush' -> do
                runStream db . runConduit $
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
    S.stream $ \io flush' -> do
        runStream db . runConduit $ f proto o l s a io
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
    S.stream $ \io flush' -> do
        runStream db . runConduit $ f proto l s as io
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
    S.stream $ \io flush' -> do
        runStream db . runConduit $
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
    S.stream $ \io flush' -> do
        runStream db . runConduit $
            getAddressesUnspentsLimit l s as .| streamAny net proto io
        flush'

scottyAddressBalance :: MonadLoggerIO m => Network -> WebT m ()
scottyAddressBalance net = do
    setHeaders
    a <- parseAddress net
    proto <- setupBin
    res <-
        getBalance a >>= \case
            Just b -> return b
            Nothing ->
                return
                    Balance
                        { balanceAddress = a
                        , balanceAmount = 0
                        , balanceUnspentCount = 0
                        , balanceZero = 0
                        , balanceTxCount = 0
                        , balanceTotalReceived = 0
                        }
    protoSerial net proto res

scottyAddressesBalances ::
       (MonadLoggerIO m, MonadUnliftIO m) => Network -> WebT m ()
scottyAddressesBalances net = do
    setHeaders
    as <- parseAddresses net
    proto <- setupBin
    let f a Nothing =
            Balance
                { balanceAddress = a
                , balanceAmount = 0
                , balanceUnspentCount = 0
                , balanceZero = 0
                , balanceTxCount = 0
                , balanceTotalReceived = 0
                }
        f _ (Just b) = b
    db <- askDB
    S.stream $ \io flush' -> do
        runStream db . runConduit $
            yieldMany as .| mapMC (\a -> f a <$> getBalance a) .|
            streamAny net proto io
        flush'

scottyXpubBalances ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Network
    -> MaxLimits
    -> WebT m ()
scottyXpubBalances net max_limits = do
    setHeaders
    xpub <- parseXpub net
    proto <- setupBin
    derive <- parseDeriveAddrs net
    db <- askDB
    S.stream $ \io flush' -> do
        runStream db . runConduit $
            xpubBals max_limits derive xpub .| streamAny net proto io
        flush'

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
    txs <- liftIO $ runStream db $ xpubTxs limits s l derive x
    if full
        then protoSerial net proto txs
        else do
            fts <- catMaybes <$> mapM (getTransaction . blockTxHash) txs
            protoSerial net proto fts

xpubTxs ::
       (Functor m, Monad m, StoreRead m, StoreStream m)
    => MaxLimits
    -> Maybe BlockRef
    -> Maybe Limit
    -> DeriveAddrs
    -> XPubKey
    -> m [BlockTx]
xpubTxs max_limits start limit derive xpub = do
    ts <-
        fmap (nub . sortBy (flip compare `on` blockTxBlock)) . runConduit $
        (go 0 >> go 1) .| concatC .| sinkList
    case limit of
        Nothing -> return ts
        Just l -> return $ take (fromIntegral l) ts
  where
    go m = yieldMany (addrs m) .| mapMC txs .| gap (maxLimitGap max_limits)
    addrs m = map (\(a, _, _) -> a) (derive (pubSubKey xpub m) 0)
    txs a =
        case limit of
            Just l ->
                runConduit $
                getAddressTxs a start .| takeC (fromIntegral l) .| sinkList
            Nothing -> runConduit $ getAddressTxs a start .| sinkList
    gap n =
        let r 0 = return ()
            r i =
                await >>= \case
                    Just [] -> r (i - 1)
                    Just xs -> yield xs >> r n
                    Nothing -> return ()
         in r n

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
    S.stream $ \io flush' -> do
        runStream db . runConduit $
            xpubUnspentLimit net limits l s derive x .| streamAny net proto io
        flush'

scottyXpubSummary ::
       (MonadLoggerIO m, MonadUnliftIO m) => Network -> MaxLimits -> WebT m ()
scottyXpubSummary net max_limits = do
    setHeaders
    x <- parseXpub net
    derive <- parseDeriveAddrs net
    proto <- setupBin
    db <- askDB
    res <- liftIO . runStream db $ xpubSummary max_limits derive x
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
    LayeredDB {layeredDB = BlockDB {blockDB = db}} <- askDB
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
                            StoreBestBlock block_hash ->
                                Just (EventBlock block_hash)
                            StoreMempoolNew tx_hash -> Just (EventTx tx_hash)
                            _ -> Nothing
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
    h <-
        liftIO . runStream db $
        healthCheck net (storeManager st) (storeChain st) tos
    when (not (healthOK h) || not (healthSynced h)) $ S.status status503
    protoSerial net proto h

runWeb :: (MonadLoggerIO m, MonadUnliftIO m) => WebConfig -> m ()
runWeb WebConfig { webDB = db
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
    S.scottyT port (runner . withLayeredDB db) $ do
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
        S.get "/xpub/:xpub/balances" $ scottyXpubBalances net limits
        S.get "/xpub/:xpub/transactions" $ scottyXpubTxs net limits False
        S.get "/xpub/:xpub/transactions/full" $ scottyXpubTxs net limits True
        S.get "/xpub/:xpub/unspent" $ scottyXpubUnspents net limits
        S.get "/xpub/:xpub" $ scottyXpubSummary net limits
        S.post "/transactions" $ scottyPostTx net st pub
        S.get "/dbstats" scottyDbStats
        S.get "/events" $ scottyEvents net pub
        S.get "/peers" $ scottyPeers net st
        S.get "/health" $ scottyHealth net st tos
        S.notFound $ S.raise ThingNotFound

getStart :: MonadUnliftIO m => WebT m (Maybe BlockRef)
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

parseDeriveAddrs :: (Monad m, ScottyError e) => Network -> ActionT e m DeriveAddrs
parseDeriveAddrs net
    | getSegWit net = do
          t <- S.param "derive" `S.rescue` const (return "standard")
          return $ case (t :: Text) of
            "segwit" -> deriveWitnessAddrs
            "compat" -> deriveCompatWitnessAddrs
            _        -> deriveAddrs
    | otherwise = return deriveAddrs

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
    maybe_chain_best <- timeout (5 * 1000 * 1000) $ chainGetBest ch
    maybe_block_best <- runMaybeT $ MaybeT . getBlock =<< MaybeT getBestBlock
    peers <- timeout (5 * 1000 * 1000) $ managerGetPeers mgr
    maybe_mempool_last <- fmap fst . listToMaybe <$> getMempool
    now <- fromIntegral . systemSeconds <$> liftIO getSystemTime
    let maybe_block_time_delta =
            (now -) . fromIntegral . blockTimestamp . blockDataHeader <$>
            maybe_block_best
        maybe_tx_time_delta =
            (now -) <$> maybe_mempool_last <|> maybe_block_time_delta
        peers_ok = maybe False (not . Data.List.null) peers
        block_timeout_ok =
            getAllowMinDifficultyBlocks net ||
            blockTimeout tos == 0 ||
            maybe False (<= blockTimeout tos) maybe_block_time_delta
        tx_timeout_ok =
            getAllowMinDifficultyBlocks net ||
            txTimeout tos == 0 ||
            maybe False (<= txTimeout tos) maybe_tx_time_delta
        status_ok =
            isJust maybe_chain_best &&
            isJust maybe_block_best &&
            peers_ok &&
            block_timeout_ok &&
            tx_timeout_ok
        synced =
            isJust $ do
                x <- maybe_chain_best
                y <- maybe_block_best
                guard $ nodeHeight x - blockDataHeight y <= 1
    return
        HealthCheck
            { healthBlockBest =
                  headerHash . blockDataHeader <$> maybe_block_best
            , healthBlockHeight = blockDataHeight <$> maybe_block_best
            , healthHeaderBest = headerHash . nodeHeader <$> maybe_chain_best
            , healthHeaderHeight = nodeHeight <$> maybe_chain_best
            , healthPeers = length <$> peers
            , healthNetwork = getNetworkName net
            , healthOK = status_ok
            , healthSynced = synced
            , healthLastBlock = maybe_block_time_delta
            , healthLastTx = maybe_tx_time_delta
            }

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
                , peerAddress = as
                , peerVersion = vs
                , peerServices = sv
                , peerRelay = rl
                }

xpubBals ::
       (MonadResource m, MonadUnliftIO m, StoreRead m)
    => MaxLimits
    -> DeriveAddrs
    -> XPubKey
    -> ConduitT i XPubBal m ()
xpubBals limits derive xpub = go 0 >> go 1
  where
    go m =
        yieldMany (addrs m) .| mapMC (uncurry bal) .| gap (maxLimitGap limits)
    bal a p =
        getBalance a >>= \case
            Nothing -> return Nothing
            Just b' -> return $ Just XPubBal {xPubBalPath = p, xPubBal = b'}
    addrs m =
        map (\(a, _, n') -> (a, [m, n'])) (derive (pubSubKey xpub m) 0)
    gap n =
        let r 0 = return ()
            r i =
                await >>= \case
                    Just (Just b) -> yield b >> r n
                    Just Nothing -> r (i - 1)
                    Nothing -> return ()
         in r n

xpubUnspent ::
       ( MonadResource m
       , MonadUnliftIO m
       , StoreStream m
       , StoreRead m
       )
    => Network
    -> MaxLimits
    -> Maybe BlockRef
    -> DeriveAddrs
    -> XPubKey
    -> ConduitT i XPubUnspent m ()
xpubUnspent _net max_limits start derive xpub =
    xpubBals max_limits derive xpub .| go
  where
    go =
        awaitForever $ \XPubBal {xPubBalPath = p, xPubBal = b} ->
            getAddressUnspents (balanceAddress b) start .|
            mapC (\t -> XPubUnspent {xPubUnspentPath = p, xPubUnspent = t})

xpubUnspentLimit ::
       ( MonadResource m
       , MonadUnliftIO m
       , StoreStream m
       , StoreRead m
       )
    => Network
    -> MaxLimits
    -> Maybe Limit
    -> Maybe BlockRef
    -> DeriveAddrs
    -> XPubKey
    -> ConduitT i XPubUnspent m ()
xpubUnspentLimit net max_limits limit start derive xpub =
    xpubUnspent net max_limits start derive xpub .| applyLimit limit

xpubSummary ::
       (MonadResource m, MonadUnliftIO m, StoreStream m, StoreRead m)
    => MaxLimits
    -> DeriveAddrs
    -> XPubKey
    -> m XPubSummary
xpubSummary max_limits derive x = do
    bs <- runConduit $ xpubBals max_limits derive x .| sinkList
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

-- Snatched from:
-- https://github.com/cblp/conduit-merge/blob/master/src/Data/Conduit/Merge.hs
mergeSourcesBy ::
       (Foldable f, Monad m)
    => (a -> a -> Ordering)
    -> f (ConduitT () a m ())
    -> ConduitT i a m ()
mergeSourcesBy f = mergeSealed . fmap sealConduitT . toList
  where
    mergeSealed sources = do
        prefetchedSources <- lift $ traverse ($$++ await) sources
        go . V.fromList . nubBy (\a b -> f (fst a) (fst b) == EQ) $
            sortBy (f `on` fst) [(a, s) | (s, Just a) <- prefetchedSources]
    go sources
        | V.null sources = pure ()
        | otherwise = do
            let (a, src1) = V.head sources
                sources1 = V.tail sources
            yield a
            (src2, mb) <- lift $ src1 $$++ await
            let sources2 =
                    case mb of
                        Nothing -> sources1
                        Just b ->
                            insertNubInSortedBy (f `on` fst) (b, src2) sources1
            go sources2

insertNubInSortedBy :: (a -> a -> Ordering) -> a -> Vector a -> Vector a
insertNubInSortedBy f x xs
    | null xs = x `cons` xs
    | otherwise =
        case find_idx 0 (length xs - 1) of
            Nothing -> x `cons` xs
            Just i ->
                let (xs1, xs2) = V.splitAt i xs
                 in xs1 <> x `cons` xs2
  where
    find_idx a b
        | f (xs ! a) x == EQ = Nothing
        | f (xs ! b) x == EQ = Nothing
        | f (xs ! b) x == LT = Just (b + 1)
        | f (xs ! a) x == GT = Just a
        | b - a == 1 = Just b
        | otherwise =
            let c = a + (b - a) `div` 2
                z = xs ! c
             in if f z x == GT
                    then find_idx a c
                    else find_idx c b

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
       (MonadResource m, MonadUnliftIO m, StoreStream m)
    => Maybe Limit
    -> Maybe BlockRef
    -> [Address]
    -> ConduitT i BlockTx m ()
getAddressesTxsLimit limit start addrs =
    mergeSourcesBy (flip compare `on` blockTxBlock) xs .| applyLimit limit
  where
    xs = map (`getAddressTxs` start) addrs

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
       (Monad m, StoreStream m)
    => Maybe Limit
    -> Maybe BlockRef
    -> [Address]
    -> ConduitT i Unspent m ()
getAddressesUnspentsLimit limit start addrs =
    mergeSourcesBy
        (flip compare `on` unspentBlock)
        (map (`getAddressUnspents` start) addrs) .|
    applyLimit limit

applyOffsetLimit :: Monad m => Offset -> Maybe Limit -> ConduitT i i m ()
applyOffsetLimit offset limit = applyOffset offset >> applyLimit limit

applyOffset :: Monad m => Offset -> ConduitT i i m ()
applyOffset = dropC . fromIntegral

applyLimit :: Monad m => Maybe Limit -> ConduitT i i m ()
applyLimit Nothing  = mapC id
applyLimit (Just l) = takeC (fromIntegral l)

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
fmtDiff d = cs (printf "%0.3f" (realToFrac (d * 1000) :: Double) :: String) <> " ms"

fmtStatus :: Status -> Text
fmtStatus s = cs (show (statusCode s)) <> " " <> cs (statusMessage s)
