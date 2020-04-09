{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
module Network.Haskoin.Store.Web where

import           Conduit                            ()
import           Control.Applicative                ((<|>))
import           Control.Monad                      (forever, guard, mzero,
                                                     unless, when, (<=<))
import           Control.Monad.Logger               (Loc, LogLevel, LogSource,
                                                     LogStr, MonadLogger,
                                                     MonadLoggerIO, askLoggerIO,
                                                     logInfoS, monadLoggerLog)
import           Control.Monad.Reader               (ReaderT, ask)
import           Control.Monad.Trans                (lift)
import           Control.Monad.Trans.Maybe          (MaybeT (..), runMaybeT)
import           Data.Aeson                         (ToJSON (..), object, (.=))
import           Data.Aeson.Encoding                (encodingToLazyByteString)
import qualified Data.ByteString                    as B
import           Data.ByteString.Builder            (lazyByteString)
import qualified Data.ByteString.Lazy               as L
import qualified Data.ByteString.Lazy.Char8         as C
import           Data.Char                          (isSpace)
import           Data.List                          (nub)
import           Data.Maybe                         (catMaybes, fromMaybe,
                                                     isJust, listToMaybe,
                                                     mapMaybe)
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
                                                     InvVector (..),
                                                     Message (..), Network (..),
                                                     OutPoint (..), Tx,
                                                     TxHash (..),
                                                     VarString (..),
                                                     Version (..), decodeHex,
                                                     eitherToMaybe, headerHash,
                                                     hexToBlockHash,
                                                     hexToTxHash,
                                                     sockToHostAddress,
                                                     stringToAddr, txHash,
                                                     xPubImport)
import           Haskoin.Node                       (Chain, Manager,
                                                     OnlinePeer (..),
                                                     chainGetBest,
                                                     managerGetPeers,
                                                     sendMessage)
import           Network.Haskoin.Store.Common       (BinSerial (..),
                                                     BlockDB (..),
                                                     BlockData (..),
                                                     BlockRef (..),
                                                     BlockTx (..),
                                                     DeriveType (..),
                                                     Event (..),
                                                     HealthCheck (..),
                                                     JsonSerial (..), Limit,
                                                     Offset,
                                                     PeerInformation (..),
                                                     PubExcept (..), Store (..),
                                                     StoreEvent (..),
                                                     StoreInput (..),
                                                     StoreRead (..),
                                                     Transaction (..),
                                                     TxAfterHeight (..),
                                                     TxData (..), TxId (..),
                                                     UnixTime, Unspent,
                                                     XPubBal (..),
                                                     XPubSpec (..), applyOffset,
                                                     blockAtOrBefore,
                                                     getTransaction, isCoinbase,
                                                     nullBalance,
                                                     transactionData)
import           Network.Haskoin.Store.Data.RocksDB (withRocksDB)
import           Network.HTTP.Types                 (Status (..), status400,
                                                     status403, status404,
                                                     status500, status503)
import           Network.Wai                        (Middleware, Request (..),
                                                     responseStatus)
import           NQE                                (Publisher, receive,
                                                     withSubscription)
import           Text.Printf                        (printf)
import           Text.Read                          (readMaybe)
import           UnliftIO                           (Exception, MonadIO,
                                                     MonadUnliftIO, askRunInIO,
                                                     liftIO, timeout)
import           Web.Scotty.Internal.Types          (ActionT)
import           Web.Scotty.Trans                   (Parsable, ScottyError)
import qualified Web.Scotty.Trans                   as S

type LoggerIO = Loc -> LogSource -> LogLevel -> LogStr -> IO ()

type WebT m = ActionT Except (ReaderT BlockDB m)

data Except
    = ThingNotFound
    | ServerError
    | BadRequest
    | UserError String
    | StringError String
    | BlockTooLarge
    deriving Eq

instance Show Except where
    show ThingNotFound   = "not found"
    show ServerError     = "you made me kill a unicorn"
    show BadRequest      = "bad request"
    show (UserError s)   = s
    show (StringError _) = "you killed the dragon with your bare hands"
    show BlockTooLarge   = "block too large"

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
            BlockTooLarge -> putWord8 5
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
    getOrphans = lift getOrphans

defHandler :: Monad m => Network -> Except -> WebT m ()
defHandler net e = do
    proto <- setupBin
    case e of
        ThingNotFound -> S.status status404
        BadRequest    -> S.status status400
        UserError _   -> S.status status400
        StringError _ -> S.status status400
        ServerError   -> S.status status500
        BlockTooLarge -> S.status status403
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
       (MonadLoggerIO m, MonadIO m) => Network -> MaxLimits -> Bool -> WebT m ()
scottyBestBlock net limits raw = do
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
            rawBlock b >>= protoSerial net proto
        else protoSerial net proto (pruneTx n b)

scottyBlock :: MonadLoggerIO m => Network -> MaxLimits -> Bool -> WebT m ()
scottyBlock net limits raw = do
    setHeaders
    block <- myBlockHash <$> S.param "block"
    n <- parseNoTx
    proto <- setupBin
    b <-
        getBlock block >>= \case
            Nothing -> S.raise ThingNotFound
            Just b -> return b
    if raw
        then do
            refuseLargeBlock limits b
            rawBlock b >>= protoSerial net proto
        else protoSerial net proto (pruneTx n b)

scottyBlockHeight :: MonadLoggerIO m => Network -> MaxLimits -> Bool -> WebT m ()
scottyBlockHeight net limits raw = do
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
            protoSerial net proto rawblocks
        else do
            blocks <- catMaybes <$> mapM getBlock hs
            let blocks' = map (pruneTx n) blocks
            protoSerial net proto blocks'

scottyBlockTime :: MonadLoggerIO m => Network -> MaxLimits -> Bool -> WebT m ()
scottyBlockTime net limits raw = do
    setHeaders
    q <- S.param "time"
    n <- parseNoTx
    proto <- setupBin
    m <- fmap (pruneTx n) <$> blockAtOrBefore q
    if raw
        then maybeSerial net proto =<<
             case m of
                 Nothing -> return Nothing
                 Just d -> do
                     refuseLargeBlock limits d
                     Just <$> rawBlock d
        else maybeSerial net proto m

scottyBlockHeights :: MonadLoggerIO m => Network -> WebT m ()
scottyBlockHeights net = do
    setHeaders
    heights <- S.param "heights"
    n <- parseNoTx
    proto <- setupBin
    bhs <- concat <$> mapM getBlocksAtHeight (heights :: [BlockHeight])
    blocks <- map (pruneTx n) . catMaybes <$> mapM getBlock bhs
    protoSerial net proto blocks

scottyBlockLatest :: MonadLoggerIO m => Network -> WebT m ()
scottyBlockLatest net = do
    setHeaders
    n <- parseNoTx
    proto <- setupBin
    getBestBlock >>= \case
        Just h -> do
            blocks <- reverse <$> go 100 n h
            protoSerial net proto blocks
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


scottyBlocks :: MonadLoggerIO m => Network -> WebT m ()
scottyBlocks net = do
    setHeaders
    bhs <- map myBlockHash <$> S.param "blocks"
    n <- parseNoTx
    proto <- setupBin
    bks <- map (pruneTx n) . catMaybes <$> mapM getBlock (nub bhs)
    protoSerial net proto bks

scottyMempool :: MonadLoggerIO m => Network -> WebT m ()
scottyMempool net = do
    setHeaders
    proto <- setupBin
    txs <- map blockTxHash <$> getMempool
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

scottyTransactions :: MonadLoggerIO m => Network -> WebT m ()
scottyTransactions net = do
    setHeaders
    txids <- map myTxHash <$> S.param "txids"
    proto <- setupBin
    txs <- catMaybes <$> mapM getTransaction (nub txids)
    protoSerial net proto txs

scottyBlockTransactions :: MonadLoggerIO m => Network -> MaxLimits -> WebT m ()
scottyBlockTransactions net limits = do
    setHeaders
    h <- myBlockHash <$> S.param "block"
    proto <- setupBin
    getBlock h >>= \case
        Just b -> do
            refuseLargeBlock limits b
            let ths = blockDataTxs b
            txs <- catMaybes <$> mapM getTransaction ths
            protoSerial net proto txs
        Nothing -> S.raise ThingNotFound

scottyRawTransactions ::
       MonadLoggerIO m => Network -> WebT m ()
scottyRawTransactions net = do
    setHeaders
    txids <- map myTxHash <$> S.param "txids"
    proto <- setupBin
    txs <- map transactionData . catMaybes <$> mapM getTransaction (nub txids)
    protoSerial net proto txs

rawBlock :: (Monad m, StoreRead m) => BlockData -> m Block
rawBlock b = do
    let h = blockDataHeader b
        ths = blockDataTxs b
    txs <- map transactionData . catMaybes <$> mapM getTransaction ths
    return Block {blockHeader = h, blockTxns = txs}

scottyRawBlockTransactions ::
       MonadLoggerIO m => Network -> MaxLimits -> WebT m ()
scottyRawBlockTransactions net limits = do
    setHeaders
    h <- myBlockHash <$> S.param "block"
    proto <- setupBin
    getBlock h >>= \case
        Just b -> do
            refuseLargeBlock limits b
            let ths = blockDataTxs b
            txs <- map transactionData . catMaybes <$> mapM getTransaction ths
            protoSerial net proto txs
        Nothing -> S.raise ThingNotFound

scottyAddressTxs :: MonadLoggerIO m => Network -> MaxLimits -> Bool -> WebT m ()
scottyAddressTxs net limits full = do
    setHeaders
    a <- parseAddress net
    s <- getStart
    o <- getOffset limits
    l <- getLimit limits full
    proto <- setupBin
    if full
        then do
            getAddressTxsFull o l s a >>= protoSerial net proto
        else do
            getAddressTxsLimit o l s a >>= protoSerial net proto

scottyAddressesTxs ::
       MonadLoggerIO m => Network -> MaxLimits -> Bool -> WebT m ()
scottyAddressesTxs net limits full = do
    setHeaders
    as <- parseAddresses net
    s <- getStart
    l <- getLimit limits full
    proto <- setupBin
    if full
        then getAddressesTxsFull l s as >>= protoSerial net proto
        else getAddressesTxsLimit l s as >>= protoSerial net proto

scottyAddressUnspent :: MonadLoggerIO m => Network -> MaxLimits -> WebT m ()
scottyAddressUnspent net limits = do
    setHeaders
    a <- parseAddress net
    s <- getStart
    o <- getOffset limits
    l <- getLimit limits False
    proto <- setupBin
    uns <- getAddressUnspentsLimit o l s a
    protoSerial net proto uns

scottyAddressesUnspent :: MonadLoggerIO m => Network -> MaxLimits -> WebT m ()
scottyAddressesUnspent net limits = do
    setHeaders
    as <- parseAddresses net
    s <- getStart
    l <- getLimit limits False
    proto <- setupBin
    uns <- getAddressesUnspentsLimit l s as
    protoSerial net proto uns

scottyAddressBalance :: MonadLoggerIO m => Network -> WebT m ()
scottyAddressBalance net = do
    setHeaders
    a <- parseAddress net
    proto <- setupBin
    res <- getBalance a
    protoSerial net proto res

scottyAddressesBalances :: MonadLoggerIO m => Network -> WebT m ()
scottyAddressesBalances net = do
    setHeaders
    as <- parseAddresses net
    proto <- setupBin
    res <- getBalances as
    protoSerial net proto res

scottyXpubBalances :: MonadLoggerIO m => Network -> WebT m ()
scottyXpubBalances net = do
    setHeaders
    xpub <- parseXpub net
    proto <- setupBin
    res <- filter (not . nullBalance . xPubBal) <$> xPubBals xpub
    protoSerial net proto res

scottyXpubTxs :: MonadLoggerIO m => Network -> MaxLimits -> Bool -> WebT m ()
scottyXpubTxs net limits full = do
    setHeaders
    xpub <- parseXpub net
    start <- getStart
    limit <- getLimit limits full
    proto <- setupBin
    txs <- xPubTxs xpub start 0 limit
    if full
        then do
            txs' <- catMaybes <$> mapM (getTransaction . blockTxHash) txs
            protoSerial net proto txs'
        else protoSerial net proto txs

scottyXpubUnspents :: MonadLoggerIO m => Network -> MaxLimits -> WebT m ()
scottyXpubUnspents net limits = do
    setHeaders
    xpub <- parseXpub net
    proto <- setupBin
    start <- getStart
    limit <- getLimit limits False
    uns <- xPubUnspents xpub start 0 limit
    protoSerial net proto uns

scottyXpubSummary :: MonadLoggerIO m => Network -> WebT m ()
scottyXpubSummary net = do
    setHeaders
    xpub <- parseXpub net
    proto <- setupBin
    res <- xPubSummary xpub
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
    BlockDB {blockDB = db} <- lift ask
    stats <- lift (getProperty db Stats)
    case stats of
      Nothing -> do
          S.text "Could not get stats"
      Just txt -> do
          S.text $ cs txt

scottyEvents :: MonadLoggerIO m => Network -> Publisher StoreEvent -> WebT m ()
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
       (MonadUnliftIO m, MonadLoggerIO m)
    => Network
    -> Store
    -> Timeouts
    -> WebT m ()
scottyHealth net st tos = do
    setHeaders
    proto <- setupBin
    h <- lift $ healthCheck net (storeManager st) (storeChain st) tos
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
        S.get "/block/best" $ scottyBestBlock net limits False
        S.get "/block/best/raw" $ scottyBestBlock net limits True
        S.get "/block/:block" $ scottyBlock net limits False
        S.get "/block/:block/raw" $ scottyBlock net limits True
        S.get "/block/height/:height" $ scottyBlockHeight net limits False
        S.get "/block/height/:height/raw" $ scottyBlockHeight net limits True
        S.get "/block/time/:time" $ scottyBlockTime net limits False
        S.get "/block/time/:time/raw" $ scottyBlockTime net limits True
        S.get "/block/heights" $ scottyBlockHeights net
        S.get "/block/latest" $ scottyBlockLatest net
        S.get "/blocks" $ scottyBlocks net
        S.get "/mempool" $ scottyMempool net
        S.get "/transaction/:txid" $ scottyTransaction net
        S.get "/transaction/:txid/raw" $ scottyRawTransaction net
        S.get "/transaction/:txid/after/:height" $ scottyTxAfterHeight net
        S.get "/transactions" $ scottyTransactions net
        S.get "/transactions/raw" $ scottyRawTransactions net
        S.get "/transactions/block/:block" $ scottyBlockTransactions net limits
        S.get "/transactions/block/:block/raw" $
            scottyRawBlockTransactions net limits
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

getStart :: MonadLoggerIO m => WebT m (Maybe BlockRef)
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

parseXpub :: (Monad m, ScottyError e) => Network -> ActionT e m XPubSpec
parseXpub net = do
    t <- S.param "xpub"
    d <- parseDeriveAddrs net
    case xPubImport net t of
        Nothing -> S.next
        Just x  -> return XPubSpec {xPubSpecKey = x, xPubDeriveType = d}

parseDeriveAddrs ::
       (Monad m, ScottyError e) => Network -> ActionT e m DeriveType
parseDeriveAddrs net
    | getSegWit net = do
        t <- S.param "derive" `S.rescue` const (return "standard")
        return $
            case (t :: Text) of
                "segwit" -> DeriveP2WPKH
                "compat" -> DeriveP2SH
                _        -> DeriveNormal
    | otherwise = return DeriveNormal

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
        tt <- memRefTime . blockTxBlock <$> ml <|> bd
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
       (Monad m, StoreRead m)
    => Offset
    -> Maybe Limit
    -> Maybe BlockRef
    -> Address
    -> m [BlockTx]
getAddressTxsLimit offset limit start addr =
    applyOffset offset <$> getAddressTxs addr start limit

getAddressTxsFull ::
       (Monad m, StoreRead m)
    => Offset
    -> Maybe Limit
    -> Maybe BlockRef
    -> Address
    -> m [Transaction]
getAddressTxsFull offset limit start addr = do
    txs <- getAddressTxsLimit offset limit start addr
    catMaybes <$> mapM (getTransaction . blockTxHash) txs

getAddressesTxsLimit ::
       (Monad m, StoreRead m)
    => Maybe Limit
    -> Maybe BlockRef
    -> [Address]
    -> m [BlockTx]
getAddressesTxsLimit limit start addrs =
    getAddressesTxs addrs start limit

getAddressesTxsFull ::
       (Monad m, StoreRead m)
    => Maybe Limit
    -> Maybe BlockRef
    -> [Address]
    -> m [Transaction]
getAddressesTxsFull limit start addrs =
    fmap catMaybes $
    getAddressesTxsLimit limit start addrs >>=
    mapM (getTransaction . blockTxHash)

getAddressUnspentsLimit ::
       (Monad m, StoreRead m)
    => Offset
    -> Maybe Limit
    -> Maybe BlockRef
    -> Address
    -> m [Unspent]
getAddressUnspentsLimit offset limit start addr =
    applyOffset offset <$> getAddressUnspents addr start limit

getAddressesUnspentsLimit ::
       (Monad m, StoreRead m)
    => Maybe Limit
    -> Maybe BlockRef
    -> [Address]
    -> m [Unspent]
getAddressesUnspentsLimit limit start addrs =
    getAddressesUnspents addrs start limit

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

refuseLargeBlock :: Monad m => MaxLimits -> BlockData -> ActionT Except m ()
refuseLargeBlock MaxLimits {maxLimitFull = f} BlockData {blockDataTxs = txs} =
    when (length txs > fromIntegral f) $ S.raise BlockTooLarge
