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
import           Control.Arrow
import           Control.Exception                 ()
import           Control.Monad
import           Control.Monad.Logger
import           Control.Monad.Reader              (MonadReader, ReaderT)
import qualified Control.Monad.Reader              as R
import           Control.Monad.Trans.Maybe
import           Data.Aeson                        (ToJSON (..), object, (.=))
import           Data.Aeson.Encoding               (encodingToLazyByteString,
                                                    fromEncoding)
import           Data.Bits
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
import           Data.UUID                         (UUID)
import           Data.UUID.V4
import           Data.Version
import           Data.Word                         (Word32)
import           Database.RocksDB                  as R
import           Haskoin
import           Haskoin.Node
import           Network.Haskoin.Store.Data
import           Network.Haskoin.Store.Data.Cached
import           Network.Haskoin.Store.Messages
import           Network.HTTP.Types
import           NQE
import qualified Paths_haskoin_store               as P
import           Text.Read                         (readMaybe)
import           UnliftIO
import           UnliftIO.Resource
import           Web.Scotty.Internal.Types         (ActionT (ActionT, runAM))
import           Web.Scotty.Trans                  as S

type WebT m = ActionT Except (ReaderT LayeredDB m)

data Except
    = ThingNotFound UUID
    | ServerError UUID
    | BadRequest UUID
    | UserError UUID String
    | StringError String
    deriving Eq

instance Show Except where
    show (ThingNotFound u) = "not found"
    show (ServerError u)   = "you made me kill a unicorn"
    show (BadRequest u)    = "bad request"
    show (UserError u s)   = s
    show (StringError s)   = "you killed the dragon with your bare hands"

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
    binSerial _ = Serialize.put . T.encodeUtf8 . T.pack . show

data WebConfig =
    WebConfig
        { webPort      :: !Int
        , webNetwork   :: !Network
        , webDB        :: !LayeredDB
        , webPublisher :: !(Publisher StoreEvent)
        , webStore     :: !Store
        }

instance Parsable BlockHash where
    parseParam =
        maybe (Left "could not decode block hash") Right . hexToBlockHash . cs

instance Parsable TxHash where
    parseParam =
        maybe (Left "could not decode tx hash") Right . hexToTxHash . cs

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

instance (MonadResource m, MonadUnliftIO m) =>
         StoreStream (WebT (ReaderT LayeredDB m)) where
    getMempool = transPipe lift . getMempool
    getOrphans = transPipe lift getOrphans
    getAddressUnspents a x = transPipe lift $ getAddressUnspents a x
    getAddressTxs a x = transPipe lift $ getAddressTxs a x
    getAddressBalances = transPipe lift getAddressBalances
    getUnspents = transPipe lift getUnspents

askDB :: Monad m => WebT m LayeredDB
askDB = lift R.ask

defHandler :: Monad m => Network -> Except -> WebT m ()
defHandler net e = do
    proto <- setupBin
    case e of
        ThingNotFound _ -> status status404
        BadRequest _    -> status status400
        UserError _ _   -> status status400
        StringError _   -> status status400
        ServerError _   -> status status500
    protoSerial net proto e

maybeSerial ::
       (Monad m, JsonSerial a, BinSerial a)
    => Network
    -> UUID
    -> Bool -- ^ binary
    -> Maybe a
    -> WebT m ()
maybeSerial _ u _ Nothing        = raise $ ThingNotFound u
maybeSerial net _ proto (Just x) = S.raw $ serialAny net proto x

protoSerial ::
       (Monad m, JsonSerial a, BinSerial a)
    => Network
    -> Bool
    -> a
    -> WebT m ()
protoSerial net proto = S.raw . serialAny net proto

scottyBestBlock :: MonadLoggerIO m => Network -> WebT m ()
scottyBestBlock net = do
    cors
    (i, u) <- uuid
    $(logDebugS) i "Get best block"
    n <- parseNoTx
    proto <- setupBin
    res <-
        runMaybeT $ do
            h <- MaybeT getBestBlock
            b <- MaybeT $ getBlock h
            return $ pruneTx n b
    $(logDebugS) i $
        "Response block hash: " <>
        maybe "[none]" (blockHashToHex . headerHash . blockDataHeader) res
    maybeSerial net u proto res

scottyBlock :: MonadLoggerIO m => Network -> WebT m ()
scottyBlock net = do
    cors
    block <- param "block"
    (i, u) <- uuid
    $(logDebugS) i $ "Get block: " <> blockHashToHex block
    n <- parseNoTx
    proto <- setupBin
    res <-
        runMaybeT $ do
            b <- MaybeT $ getBlock block
            return $ pruneTx n b
    $(logDebugS) i $ maybe "Block not found" (const "Block found") res
    maybeSerial net u proto res

scottyBlockHeight :: MonadLoggerIO m => Network -> WebT m ()
scottyBlockHeight net = do
    cors
    height <- param "height"
    (i, u) <- uuid
    $(logDebugS) i $ "Get blocks at height: " <> cs (show height)
    n <- parseNoTx
    proto <- setupBin
    res <-
        fmap catMaybes $ do
            hs <- getBlocksAtHeight height
            forM hs $ \h ->
                runMaybeT $ do
                    b <- MaybeT $ getBlock h
                    return $ pruneTx n b
    $(logDebugS) i $ "Blocks returned: " <> cs (show (length res))
    protoSerial net proto res

scottyBlockHeights :: MonadLoggerIO m => Network -> WebT m ()
scottyBlockHeights net = do
    cors
    heights <- param "heights"
    (i, u) <- uuid
    $(logDebugS) i $ "Get blocks at multiple heights: " <> cs (show heights)
    n <- parseNoTx
    proto <- setupBin
    bs <- concat <$> mapM getBlocksAtHeight (nub heights)
    res <-
        fmap catMaybes . forM bs $ \bh ->
            runMaybeT $ do
                b <- MaybeT $ getBlock bh
                return $ pruneTx n b
    $(logDebugS) i $ "Blocks returned: " <> cs (show (length res))
    protoSerial net proto res

scottyBlocks :: MonadLoggerIO m => Network -> WebT m ()
scottyBlocks net = do
    cors
    blocks <- param "blocks"
    (i, u) <- uuid
    $(logDebugS) i $ "Get multiple blocks: " <> cs (show blocks)
    n <- parseNoTx
    proto <- setupBin
    res <-
        fmap catMaybes . forM blocks $ \bh ->
            runMaybeT $ do
                b <- MaybeT $ getBlock bh
                return $ pruneTx n b
    $(logDebugS) i $ "Blocks returned: " <> cs (show (length res))
    protoSerial net proto res

scottyMempool :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> WebT m ()
scottyMempool net = do
    cors
    (l, s) <- parseLimits
    (i, u) <- uuid
    proto <- setupBin
    db <- askDB
    $(logDebugS) i "Get mempool"
    stream $ \io flush' -> do
        runResourceT . withLayeredDB db $
            runConduit $ getMempoolLimit l s .| streamAny net proto io
        flush'
    $(logDebugS) i "Mempool streaming complete"

scottyTransaction :: MonadLoggerIO m => Network -> WebT m ()
scottyTransaction net = do
    cors
    txid <- param "txid"
    (i, u) <- uuid
    $(logDebugS) i $ "Get transaction: " <> txHashToHex txid
    proto <- setupBin
    res <- getTransaction txid
    case res of
        Nothing -> $(logDebugS) i "Transaction not found"
        Just _  -> $(logDebugS) i "Transaction found"
    maybeSerial net u proto res

scottyRawTransaction :: MonadLoggerIO m => Bool -> WebT m ()
scottyRawTransaction hex = do
    cors
    txid <- param "txid"
    (i, u) <- uuid
    $(logDebugS) i $ "Get raw transaction: " <> txHashToHex txid
    res <- getTransaction txid
    case res of
        Nothing -> do
            $(logDebugS) i "Transaction not found"
            raise $ ThingNotFound u
        Just x -> do
            $(logDebugS) i "Transaction found"
            if hex
                then text . cs . encodeHex . Serialize.encode $
                     transactionData x
                else do
                    S.setHeader "Content-Type" "application/octet-stream"
                    S.raw $ Serialize.encodeLazy (transactionData x)

scottyTxAfterHeight :: MonadLoggerIO m => Network -> WebT m ()
scottyTxAfterHeight net = do
    cors
    txid <- param "txid"
    height <- param "height"
    (i, _) <- uuid
    $(logDebugS) i $
        "Is transaction " <> txHashToHex txid <> "after height" <>
        cs (show height) <> "?"
    proto <- setupBin
    res <- cbAfterHeight 10000 height txid
    case txAfterHeight res of
      Nothing    -> $(logDebugS) i $ "Could not find out"
      Just False -> $(logDebugS) i "No"
      Just True  -> $(logDebugS) i "Yes"
    protoSerial net proto res

scottyTransactions :: MonadLoggerIO m => Network -> WebT m ()
scottyTransactions net = do
    cors
    txids <- param "txids"
    proto <- setupBin
    (i, _) <- uuid
    $(logDebugS) i $ "Get transactions: " <> cs (show txids)
    res <- catMaybes <$> mapM getTransaction (nub txids)
    $(logDebugS) i $ "Transactions returned: " <> cs (show (length res))
    protoSerial net proto res

scottyRawTransactions :: MonadLoggerIO m => Bool -> WebT m ()
scottyRawTransactions hex = do
    cors
    txids <- param "txids"
    (i, _) <- uuid
    $(logDebugS) i $ "Get raw transactions: " <> cs (show txids)
    res <- catMaybes <$> mapM getTransaction (nub txids)
    $(logDebugS) i $ "Transactions returned: " <> cs (show (length res))
    if hex
        then S.json $ map (encodeHex . Serialize.encode . transactionData) res
        else do
            S.setHeader "Content-Type" "application/octet-stream"
            S.raw . L.concat $ map (Serialize.encodeLazy . transactionData) res

scottyAddressTxs ::
       (MonadLoggerIO m, MonadUnliftIO m) => Network -> Bool -> WebT m ()
scottyAddressTxs net full = do
    cors
    a <- parseAddress net
    (l, s) <- parseLimits
    proto <- setupBin
    (i, _) <- uuid
    $(logDebugS) i $
        "Get transactions for address: " <> fromMaybe "???" (addrToString net a)
    db <- askDB
    stream $ \io flush' -> do
        runResourceT . withLayeredDB db . runConduit $ f proto l s a io
        flush'
    $(logDebugS) i "Streamed transactions"
  where
    f proto l s a io
        | full = getAddressTxsFull l s a .| streamAny net proto io
        | otherwise = getAddressTxsLimit l s a .| streamAny net proto io

scottyAddressesTxs ::
       (MonadLoggerIO m, MonadUnliftIO m) => Network -> Bool -> WebT m ()
scottyAddressesTxs net full = do
    cors
    as <- parseAddresses net
    (l, s) <- parseLimits
    proto <- setupBin
    (i, _) <- uuid
    $(logDebugS) i $
        "Get transactions for addresses: [" <>
        T.intercalate "," (map (fromMaybe "???" . addrToString net) as) <> "]"
    db <- askDB
    stream $ \io flush' -> do
        runResourceT . withLayeredDB db . runConduit $ f proto l s as io
        flush'
    $(logDebugS) i "Streamed transactions"
  where
    f proto l s as io
        | full = getAddressesTxsFull l s as .| streamAny net proto io
        | otherwise = getAddressesTxsLimit l s as .| streamAny net proto io

scottyAddressUnspent ::
       (MonadLoggerIO m, MonadUnliftIO m) => Network -> WebT m ()
scottyAddressUnspent net = do
    cors
    a <- parseAddress net
    (i, _) <- uuid
    $(logDebugS) i $
        "Get UTXO for address: " <> fromMaybe "???" (addrToString net a)
    (l, s) <- parseLimits
    proto <- setupBin
    db <- askDB
    stream $ \io flush' -> do
        runResourceT . withLayeredDB db . runConduit $
            getAddressUnspentsLimit l s a .| streamAny net proto io
        flush'
    $(logDebugS) i "Streamed UTXO"

scottyAddressesUnspent ::
       (MonadLoggerIO m, MonadUnliftIO m) => Network -> WebT m ()
scottyAddressesUnspent net = do
    cors
    as <- parseAddresses net
    (l, s) <- parseLimits
    (i, _) <- uuid
    $(logDebugS) i $
        "Get UTXO for addresses: [" <>
        T.intercalate "," (map (fromMaybe "???" . addrToString net) as) <> "]"
    proto <- setupBin
    db <- askDB
    stream $ \io flush' -> do
        runResourceT . withLayeredDB db . runConduit $
            getAddressesUnspentsLimit l s as .| streamAny net proto io
        flush'
    $(logDebugS) i "Streamed UTXO"

scottyAddressBalance :: MonadLoggerIO m => Network -> WebT m ()
scottyAddressBalance net = do
    cors
    a <- parseAddress net
    proto <- setupBin
    (i, _) <- uuid
    $(logDebugS) i $
        "Get balance for address: " <> fromMaybe "???" (addrToString net a)
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
    $(logDebugS) i "Returned balance"
    protoSerial net proto res

scottyAddressesBalances :: MonadLoggerIO m => Network -> WebT m ()
scottyAddressesBalances net = do
    cors
    as <- parseAddresses net
    proto <- setupBin
    (i, _) <- uuid
    $(logDebugS) i $
        "Get UTXO for addresses: [" <>
        T.intercalate "," (map (fromMaybe "???" . addrToString net) as) <>
        "]"
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
    res <- mapM (\a -> f a <$> getBalance a) as
    $(logDebugS) i $ "Returned balances: " <> cs (show (length res))
    protoSerial net proto res

scottyXpubBalances :: (MonadUnliftIO m, MonadLoggerIO m) => Network -> WebT m ()
scottyXpubBalances net = do
    cors
    xpub <- parseXpub net
    proto <- setupBin
    (i, _) <- uuid
    $(logDebugS) i $ "Get balances for xpub: " <> xPubExport net xpub
    db <- askDB
    res <- liftIO . runResourceT . withLayeredDB db $ xpubBals xpub
    $(logDebugS) i $ "Returned balances: " <> cs (show (length res))
    protoSerial net proto res

scottyXpubTxs ::
       (MonadLoggerIO m, MonadUnliftIO m) => Network -> Bool -> WebT m ()
scottyXpubTxs net full = do
    cors
    x <- parseXpub net
    (l, s) <- parseLimits
    proto <- setupBin
    (i, _) <- uuid
    $(logDebugS) i $ "Get transactions for xpub: " <> xPubExport net x
    db <- askDB
    bs <- liftIO . runResourceT . withLayeredDB db $ xpubBals x
    stream $ \io flush' -> do
        runResourceT . withLayeredDB db . runConduit $ f proto l s bs io
        flush'
    $(logDebugS) i "Streamed balances"
  where
    f proto l s bs io
        | full =
            getAddressesTxsFull l s (map (balanceAddress . xPubBal) bs) .|
            streamAny net proto io
        | otherwise =
            getAddressesTxsLimit l s (map (balanceAddress . xPubBal) bs) .|
            streamAny net proto io

scottyXpubUnspents :: MonadLoggerIO m => Network -> WebT m ()
scottyXpubUnspents net = do
    cors
    x <- parseXpub net
    proto <- setupBin
    (l, s) <- parseLimits
    (i, _) <- uuid
    $(logDebugS) i $ "Get UTXO for xpub: " <> xPubExport net x
    db <- askDB
    stream $ \io flush' -> do
        runResourceT . withLayeredDB db . runConduit $
            xpubUnspentLimit net l s x .| streamAny net proto io
        flush'
    $(logDebugS) i "Streamed UTXO"

scottyXpubSummary :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> WebT m ()
scottyXpubSummary net = do
    cors
    x <- parseXpub net
    (l, s) <- parseLimits
    (i, _) <- uuid
    $(logDebugS) i $ "Get summary for xpub: " <> xPubExport net x
    proto <- setupBin
    db <- askDB
    res <- liftIO . runResourceT . withLayeredDB db $ xpubSummary l s x
    $(logDebugS) i "Returning summary"
    protoSerial net proto res

scottyPostTx ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Network
    -> Store
    -> Publisher StoreEvent
    -> WebT m ()
scottyPostTx net st pub = do
    cors
    proto <- setupBin
    b <- body
    (i, u) <- uuid
    $(logDebugS) i "Received transaction to publish"
    let bin = eitherToMaybe . Serialize.decode
        hex = bin <=< decodeHex . cs . C.filter (not . isSpace)
    tx <-
        case hex b <|> bin (L.toStrict b) of
            Nothing -> do
                $(logDebugS) i "Decode tx fail"
                raise $ UserError u "decode tx fail"
            Just x -> do
                $(logDebugS) i $ "Transaction id: " <> txHashToHex (txHash x)
                return x
    lift (publishTx net pub st tx) >>= \case
        Right () -> do
            protoSerial net proto (TxId (txHash tx))
            $(logDebugS) i "Success publishing transaction"
        Left e -> do
            case e of
                PubNoPeers          -> status status500
                PubTimeout          -> status status500
                PubPeerDisconnected -> status status500
                PubNotFound         -> status status500
                PubReject _         -> status status400
            protoSerial net proto (UserError u (show e))
            $(logWarnS) i $
                "Could not publish: " <> txHashToHex (txHash tx) <> ": " <>
                cs (show e)
            finish

scottyDbStats :: MonadLoggerIO m => WebT m ()
scottyDbStats = do
    cors
    (i, _) <- uuid
    $(logDebugS) i "Get DB stats"
    LayeredDB {layeredDB = BlockDB {blockDB = db}} <- askDB
    stats <- lift (getProperty db Stats)
    case stats of
      Nothing -> do
          $(logWarnS) i "Could not get stats"
          text "Could not get stats"
      Just txt -> do
          $(logDebugS) i "Returning stats"
          text $ cs txt

scottyEvents ::
       (MonadLoggerIO m, MonadUnliftIO m)
    => Network
    -> Publisher StoreEvent
    -> WebT m ()
scottyEvents net pub = do
    cors
    (i, _) <- uuid
    proto <- setupBin
    $(logDebugS) i "Streaming events..."
    stream $ \io flush' ->
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
    $(logDebugS) i "Finished streaming events"

scottyPeers :: MonadLoggerIO m => Network -> Store -> WebT m ()
scottyPeers net st = do
    cors
    proto <- setupBin
    (i, _) <- uuid
    $(logDebugS) i "Get peer information"
    ps <- getPeersInformation (storeManager st)
    $(logDebugS) i $ "Returned peers: " <> cs (show (length ps))
    protoSerial net proto ps

scottyHealth ::
       (MonadLoggerIO m, MonadUnliftIO m) => Network -> Store -> WebT m ()
scottyHealth net st = do
    cors
    proto <- setupBin
    (i, _) <- uuid
    $(logDebugS) i "Get health information"
    h <- lift $ healthCheck net (storeManager st) (storeChain st)
    if not (healthOK h) || not (healthSynced h)
        then do
            $(logDebugS) i "Not healthy"
            status status503
        else $(logDebugS) i "Healthy"
    protoSerial net proto h

runWeb :: (MonadLoggerIO m, MonadUnliftIO m) => WebConfig -> m ()
runWeb WebConfig { webDB = db
                 , webPort = port
                 , webNetwork = net
                 , webStore = st
                 , webPublisher = pub
                 } = do
    runner <- askRunInIO
    scottyT port (runner . withLayeredDB db) $ do
        defaultHandler (defHandler net)
        S.get "/block/best" $ scottyBestBlock net
        S.get "/block/:block" $ scottyBlock net
        S.get "/block/height/:height" $ scottyBlockHeight net
        S.get "/block/heights" $ scottyBlockHeights net
        S.get "/blocks" $ scottyBlocks net
        S.get "/mempool" $ scottyMempool net
        S.get "/transaction/:txid" $ scottyTransaction net
        S.get "/transaction/:txid/hex" $ scottyRawTransaction True
        S.get "/transaction/:txid/bin" $ scottyRawTransaction False
        S.get "/transaction/:txid/after/:height" $ scottyTxAfterHeight net
        S.get "/transactions" $ scottyTransactions net
        S.get "/transactions/hex" $ scottyRawTransactions True
        S.get "/transactions/bin" $ scottyRawTransactions False
        S.get "/address/:address/transactions" $ scottyAddressTxs net False
        S.get "/address/:address/transactions/full" $ scottyAddressTxs net True
        S.get "/address/transactions" $ scottyAddressesTxs net False
        S.get "/address/transactions/full" $ scottyAddressesTxs net True
        S.get "/address/:address/unspent" $ scottyAddressUnspent net
        S.get "/address/unspent" $ scottyAddressesUnspent net
        S.get "/address/:address/balance" $ scottyAddressBalance net
        S.get "/address/balances" $ scottyAddressesBalances net
        S.get "/xpub/:xpub/balances" $ scottyXpubBalances net
        S.get "/xpub/:xpub/transactions" $ scottyXpubTxs net False
        S.get "/xpub/:xpub/transactions/full" $ scottyXpubTxs net True
        S.get "/xpub/:xpub/unspent" $ scottyXpubUnspents net
        S.get "/xpub/:xpub" $ scottyXpubSummary net
        S.post "/transactions" $ scottyPostTx net st pub
        S.get "/dbstats" scottyDbStats
        S.get "/events" $ scottyEvents net pub
        S.get "/peers" $ scottyPeers net st
        S.get "/health" $ scottyHealth net st
        notFound $ do
            (i, u) <- uuid
            $(logDebugS) i "Requested resource not found"
            raise (ThingNotFound u)

parseLimits :: (ScottyError e, Monad m) => ActionT e m (Maybe Word32, StartFrom)
parseLimits = do
    let b = do
            height <- param "height"
            pos <- param "pos" `rescue` const (return maxBound)
            return $ StartBlock height pos
        m = do
            time <- param "time"
            return $ StartMem time
        o = do
            o <- param "offset" `rescue` const (return 0)
            return $ StartOffset o
    l <- (Just <$> param "limit") `rescue` const (return Nothing)
    s <- b <|> m <|> o
    return (l, s)

parseAddress net = do
    address <- param "address"
    case stringToAddr net address of
        Nothing -> next
        Just a  -> return a

parseAddresses net = do
    addresses <- param "addresses"
    let as = mapMaybe (stringToAddr net) addresses
    unless (length as == length addresses) next
    return as

parseXpub :: (Monad m, ScottyError e) => Network -> ActionT e m XPubKey
parseXpub net = do
    t <- param "xpub"
    case xPubImport net t of
        Nothing -> next
        Just x  -> return x

parseNoTx :: (Monad m, ScottyError e) => ActionT e m Bool
parseNoTx = param "notx" `rescue` const (return False)

pruneTx False b = b
pruneTx True b  = b {blockDataTxs = take 1 (blockDataTxs b)}

cors :: Monad m => ActionT e m ()
cors = setHeader "Access-Control-Allow-Origin" "*"

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
            setHeader "Content-Type" "application/octet-stream"
            return True
        j = do
            setHeader "Content-Type" "application/json"
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
    -> m HealthCheck
healthCheck net mgr ch = do
    n <- timeout (5 * 1000 * 1000) $ chainGetBest ch
    b <-
        runMaybeT $ do
            h <- MaybeT getBestBlock
            MaybeT $ getBlock h
    p <- timeout (5 * 1000 * 1000) $ managerGetPeers mgr
    let k = isNothing n || isNothing b || maybe False (not . null) p
        s =
            isJust $ do
                x <- n
                y <- b
                guard $ nodeHeight x - blockDataHeight y <= 1
    return
        HealthCheck
            { healthBlockBest = headerHash . blockDataHeader <$> b
            , healthBlockHeight = blockDataHeight <$> b
            , healthHeaderBest = headerHash . nodeHeader <$> n
            , healthHeaderHeight = nodeHeight <$> n
            , healthPeers = length <$> p
            , healthNetwork = getNetworkName net
            , healthOK = k
            , healthSynced = s
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
       (MonadResource m, MonadUnliftIO m, StoreRead m) => XPubKey -> m [XPubBal]
xpubBals xpub =
    runConduit $
    mergeSourcesBy (compare `on` xPubBalPath) [go 0, go 1] .| sinkList
  where
    go m = yieldMany (addrs m) .| mapMC (uncurry bal) .| gap 20
    bal a p =
        getBalance a >>= \case
            Nothing -> return Nothing
            Just b' -> return $ Just XPubBal {xPubBalPath = p, xPubBal = b'}
    addrs m =
        map (\(a, _, n') -> (a, [m, n'])) (deriveAddrs (pubSubKey xpub m) 0)
    gap n =
        let r 0 = return ()
            r i =
                awaitForever $ \case
                    Just b -> yield b >> r n
                    Nothing -> r (i - 1)
         in r n

xpubUnspent ::
       ( MonadResource m
       , MonadUnliftIO m
       , StoreStream m
       , StoreRead m
       )
    => Network
    -> Maybe BlockRef
    -> XPubKey
    -> ConduitT () XPubUnspent m ()
xpubUnspent net mbr xpub = do
    xs <- do
        bs <- lift $ xpubBals xpub
        return $ map g bs
    mergeSourcesBy (flip compare `on` (unspentBlock . xPubUnspent)) xs
  where
    f p t = XPubUnspent {xPubUnspentPath = p, xPubUnspent = t}
    g XPubBal {xPubBalPath = p, xPubBal = b} =
        getAddressUnspents (balanceAddress b) mbr .| mapC (f p)

xpubUnspentLimit ::
       ( MonadResource m
       , MonadUnliftIO m
       , StoreStream m
       , StoreRead m
       )
    => Network
    -> Maybe Word32
    -> StartFrom
    -> XPubKey
    -> ConduitT () XPubUnspent m ()
xpubUnspentLimit net l s x =
    xpubUnspent net (mbr s) x .| (offset s >> limit l)

xpubSummary ::
       (MonadResource m, MonadUnliftIO m, StoreStream m, StoreRead m)
    => Maybe Word32
    -> StartFrom
    -> XPubKey
    -> m XPubSummary
xpubSummary l s x = do
    bs <- xpubBals x
    let f XPubBal {xPubBalPath = p, xPubBal = Balance {balanceAddress = a}} =
            (a, p)
        pm = H.fromList $ map f bs
    txs <-
        runConduit $
        getAddressesTxsFull l s (map (balanceAddress . xPubBal) bs) .| sinkList
    let as =
            nub
                [ a
                | t <- txs
                , let is = transactionInputs t
                , let os = transactionOutputs t
                , let ais =
                          mapMaybe
                              (eitherToMaybe . scriptToAddressBS . inputPkScript)
                              is
                , let aos =
                          mapMaybe
                              (eitherToMaybe . scriptToAddressBS . outputScript)
                              os
                , a <- ais ++ aos
                ]
        ps = H.fromList $ mapMaybe (\a -> (a, ) <$> H.lookup a pm) as
        ex = foldl max 0 [i | XPubBal {xPubBalPath = [x, i]} <- bs, x == 0]
        ch = foldl max 0 [i | XPubBal {xPubBalPath = [x, i]} <- bs, x == 1]
    return
        XPubSummary
            { xPubSummaryReceived =
                  sum (map (balanceTotalReceived . xPubBal) bs)
            , xPubSummaryConfirmed = sum (map (balanceAmount . xPubBal) bs)
            , xPubSummaryZero = sum (map (balanceZero . xPubBal) bs)
            , xPubSummaryPaths = ps
            , xPubSummaryTxs = txs
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
        go [(a, s) | (s, Just a) <- prefetchedSources]
    go [] = pure ()
    go sources = do
        let (a, src1):sources1 = sortBy (f `on` fst) sources
        yield a
        (src2, mb) <- lift $ src1 $$++ await
        let sources2 =
                case mb of
                    Nothing -> sources1
                    Just b  -> (b, src2) : sources1
        go sources2

getMempoolLimit ::
       (Monad m, StoreStream m)
    => Maybe Word32
    -> StartFrom
    -> ConduitT () TxHash m ()
getMempoolLimit _ StartBlock {} = return ()
getMempoolLimit l (StartMem t) =
    getMempool (Just t) .| mapC snd .| limit l
getMempoolLimit l s =
    getMempool Nothing .| mapC snd .| (offset s >> limit l)

getAddressTxsLimit ::
       (Monad m, StoreStream m)
    => Maybe Word32
    -> StartFrom
    -> Address
    -> ConduitT () BlockTx m ()
getAddressTxsLimit l s a =
    getAddressTxs a (mbr s) .| (offset s >> limit l)

getAddressTxsFull ::
       (Monad m, StoreStream m, StoreRead m)
    => Maybe Word32
    -> StartFrom
    -> Address
    -> ConduitT () Transaction m ()
getAddressTxsFull l s a =
    getAddressTxsLimit l s a .| concatMapMC (getTransaction . blockTxHash)

getAddressesTxsLimit ::
       (MonadResource m, MonadUnliftIO m, StoreStream m)
    => Maybe Word32
    -> StartFrom
    -> [Address]
    -> ConduitT () BlockTx m ()
getAddressesTxsLimit l s as =
    mergeSourcesBy (flip compare `on` blockTxBlock) xs .| dedup .|
    (offset s >> limit l)
  where
    xs = map (\a -> getAddressTxs a (mbr s)) as

getAddressesTxsFull ::
       (MonadResource m, MonadUnliftIO m, StoreStream m, StoreRead m)
    => Maybe Word32
    -> StartFrom
    -> [Address]
    -> ConduitT () Transaction m ()
getAddressesTxsFull l s as =
    getAddressesTxsLimit l s as .| concatMapMC (getTransaction . blockTxHash)

getAddressUnspentsLimit ::
       (Monad m, StoreStream m)
    => Maybe Word32
    -> StartFrom
    -> Address
    -> ConduitT () Unspent m ()
getAddressUnspentsLimit l s a =
    getAddressUnspents a (mbr s) .| (offset s >> limit l)

getAddressesUnspentsLimit ::
       (Monad m, StoreStream m)
    => Maybe Word32
    -> StartFrom
    -> [Address]
    -> ConduitT () Unspent m ()
getAddressesUnspentsLimit l s as =
    mergeSourcesBy
        (flip compare `on` unspentBlock)
        (map (`getAddressUnspents` mbr s) as) .|
    (offset s >> limit l)

offset :: Monad m => StartFrom -> ConduitT i i m ()
offset (StartOffset o) = dropC (fromIntegral o)
offset _               = return ()

limit :: Monad m => Maybe Word32 -> ConduitT i i m ()
limit Nothing  = mapC id
limit (Just n) = takeC (fromIntegral n)

mbr :: StartFrom -> Maybe BlockRef
mbr (StartBlock h p) = Just (BlockRef h p)
mbr (StartMem t)     = Just (MemRef t)
mbr (StartOffset _)  = Nothing

conduitToQueue :: MonadIO m => TBQueue (Maybe a) -> ConduitT a Void m ()
conduitToQueue q =
    await >>= \case
        Just x -> atomically (writeTBQueue q (Just x)) >> conduitToQueue q
        Nothing -> atomically $ writeTBQueue q Nothing

queueToConduit :: MonadIO m => TBQueue (Maybe a) -> ConduitT () a m ()
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
            OnlinePeer {onlinePeerMailbox = p, onlinePeerAddress = a}:_ -> do
                MTx tx `sendMessage` p
                let t =
                        if getSegWit net
                            then InvWitnessTx
                            else InvTx
                sendMessage
                    (MGetData (GetData [InvVector t (getTxHash (txHash tx))]))
                    p
                f p s
    t = 15 * 1000 * 1000
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

uuid :: MonadLoggerIO m => WebT m (Text, UUID)
uuid = do
    u <- liftIO nextRandom
    r <- request
    let t = "Web<" <> cs (show u) <> ">"
    $(logDebugS) t $ cs (show r)
    return (t, u)
