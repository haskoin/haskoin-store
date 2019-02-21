{-# LANGUAGE ApplicativeDo     #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
import           Conduit
import           Control.Arrow
import           Control.Exception          ()
import           Control.Monad
import           Control.Monad.Logger
import           Control.Monad.Trans.Maybe
import           Data.Aeson                 as A
import           Data.Bits
import           Data.ByteString.Builder
import qualified Data.ByteString.Lazy.Char8 as C
import           Data.Char
import           Data.Function
import           Data.List
import           Data.Maybe
import           Data.Serialize             as Serialize
import           Data.String.Conversions
import           Data.Version
import           Database.RocksDB           as R
import           Haskoin
import           Haskoin.Node
import           Haskoin.Store
import           Network.HTTP.Types
import           NQE
import           Options.Applicative
import           Paths_haskoin_store        as P
import           System.Directory
import           System.Exit
import           System.FilePath
import           System.IO.Unsafe
import           Text.Read                  (readMaybe)
import           UnliftIO
import           Web.Scotty.Trans           as S

data Config = Config
    { configDir      :: !FilePath
    , configPort     :: !Int
    , configNetwork  :: !Network
    , configDiscover :: !Bool
    , configPeers    :: ![(Host, Maybe Port)]
    , configVersion  :: !Bool
    }

defPort :: Int
defPort = 3000

defNetwork :: Network
defNetwork = btc

instance Parsable BlockHash where
    parseParam =
        maybe (Left "could not decode block hash") Right . hexToBlockHash . cs

instance Parsable TxHash where
    parseParam =
        maybe (Left "could not decode tx hash") Right . hexToTxHash . cs

data Except
    = ThingNotFound
    | ServerError
    | BadRequest
    | UserError String
    | StringError String
    deriving (Show, Eq)

instance Exception Except

instance ScottyError Except where
    stringError = StringError
    showError = cs . show

instance ToJSON Except where
    toJSON ThingNotFound = object ["error" .= String "not found"]
    toJSON BadRequest = object ["error" .= String "bad request"]
    toJSON ServerError = object ["error" .= String "you made me kill a unicorn"]
    toJSON (StringError _) = object ["error" .= String "you made me kill a unicorn"]
    toJSON (UserError s) = object ["error" .= s]

data JsonEvent
    = JsonEventTx TxHash
    | JsonEventBlock BlockHash
    deriving (Eq, Show)

instance ToJSON JsonEvent where
    toJSON (JsonEventTx tx_hash) =
        object ["type" .= String "tx", "id" .= tx_hash]
    toJSON (JsonEventBlock block_hash) =
        object ["type" .= String "block", "id" .= block_hash]

netNames :: String
netNames = intercalate "|" (map getNetworkName allNets)

config :: Parser Config
config = do
    configDir <-
        option str $
        metavar "DIR" <> long "dir" <> short 'd' <> help "Data directory" <>
        showDefault <>
        value myDirectory
    configPort <-
        option auto $
        metavar "INT" <> long "listen" <> short 'l' <> help "Listening port" <>
        showDefault <>
        value defPort
    configNetwork <-
        option (eitherReader networkReader) $
        metavar netNames <> long "net" <> short 'n' <>
        help "Network to connect to" <>
        showDefault <>
        value defNetwork
    configDiscover <-
        switch $
        long "auto" <> short 'a' <> help "Peer discovery"
    configPeers <-
        many . option (eitherReader peerReader) $
        metavar "HOST" <> long "peer" <> short 'p' <>
        help "Network peer (as many as required)"
    configVersion <-
        switch $ long "version" <> short 'v' <> help "Show version"
    return Config {..}

networkReader :: String -> Either String Network
networkReader s
    | s == getNetworkName btc = Right btc
    | s == getNetworkName btcTest = Right btcTest
    | s == getNetworkName btcRegTest = Right btcRegTest
    | s == getNetworkName bch = Right bch
    | s == getNetworkName bchTest = Right bchTest
    | s == getNetworkName bchRegTest = Right bchRegTest
    | otherwise = Left "Network name invalid"

peerReader :: String -> Either String (Host, Maybe Port)
peerReader s = do
    let (host, p) = span (/= ':') s
    when (null host) (Left "Peer name or address not defined")
    port <-
        case p of
            [] -> return Nothing
            ':':p' ->
                case readMaybe p' of
                    Nothing -> Left "Peer port number cannot be read"
                    Just n  -> return (Just n)
            _ -> Left "Peer information could not be parsed"
    return (host, port)

defHandler :: Monad m => Except -> ActionT Except m ()
defHandler ServerError   = S.json ServerError
defHandler ThingNotFound = status status404 >> S.json ThingNotFound
defHandler BadRequest    = status status400 >> S.json BadRequest
defHandler (UserError s) = status status400 >> S.json (UserError s)
defHandler e             = status status400 >> S.json e

maybeJSON :: (Monad m, ToJSON a) => Maybe a -> ActionT Except m ()
maybeJSON Nothing  = raise ThingNotFound
maybeJSON (Just x) = S.json x

myDirectory :: FilePath
myDirectory = unsafePerformIO $ getAppUserDataDirectory "haskoin-store"
{-# NOINLINE myDirectory #-}

main :: IO ()
main =
    runStderrLoggingT $ do
        conf <- liftIO (execParser opts)
        when (configVersion conf) . liftIO $ do
            putStrLn $ showVersion P.version
            exitSuccess
        when (null (configPeers conf) && not (configDiscover conf)) . liftIO $
            die "ERROR: Specify peers to connect or enable peer discovery."
        let net = configNetwork conf
        let wdir = configDir conf </> getNetworkName net
        liftIO $ createDirectoryIfMissing True wdir
        db <-
            open
                (wdir </> "db")
                R.defaultOptions
                    { createIfMissing = True
                    , compression = SnappyCompression
                    , maxOpenFiles = -1
                    , writeBufferSize = 2 `shift` 30
                    }
        withPublisher $ \pub ->
            withStore (scfg conf db pub) $ \st -> runWeb conf st db pub
  where
    scfg conf db pub =
        StoreConfig
            { storeConfMaxPeers = 20
            , storeConfInitPeers =
                  map
                      (second (fromMaybe (getDefaultPort (configNetwork conf))))
                      (configPeers conf)
            , storeConfDiscover = configDiscover conf
            , storeConfDB = db
            , storeConfNetwork = configNetwork conf
            , storeConfListen = (`sendSTM` pub) . Event
            }
    opts =
        info (helper <*> config) $
        fullDesc <> progDesc "Blockchain store and API" <>
        Options.Applicative.header
            ("haskoin-store version " <> showVersion P.version)

runWeb ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Config
    -> Store
    -> DB
    -> Publisher StoreEvent
    -> m ()
runWeb conf st db pub = do
    l <- askLoggerIO
    scottyT (configPort conf) (runner l) $ do
        defaultHandler defHandler
        S.get "/block/best" $ do
            cors
            n <- parse_no_tx
            res <-
                withSnapshot db $ \s ->
                    runMaybeT $ do
                        let d = (db, defaultReadOptions {useSnapshot = Just s})
                        bh <- MaybeT $ getBestBlock d
                        b <- MaybeT $ getBlock d bh
                        if n
                            then return
                                     b {blockDataTxs = take 1 (blockDataTxs b)}
                            else return b
            maybeJSON (blockDataToJSON net <$> res)
        S.get "/block/:block" $ do
            cors
            block <- param "block"
            n <- parse_no_tx
            res <-
                withSnapshot db $ \s ->
                    runMaybeT $ do
                        let d = (db, defaultReadOptions {useSnapshot = Just s})
                        b <- MaybeT $ getBlock d block
                        if n
                            then return
                                     b {blockDataTxs = take 1 (blockDataTxs b)}
                            else return b
            maybeJSON (blockDataToJSON net <$> res)
        S.get "/block/height/:height" $ do
            cors
            height <- param "height"
            n <- parse_no_tx
            res <-
                withSnapshot db $ \s -> do
                    let d = (db, defaultReadOptions {useSnapshot = Just s})
                    bs <- getBlocksAtHeight d height
                    fmap catMaybes . forM bs $ \bh ->
                        runMaybeT $ do
                            b <- MaybeT $ getBlock d bh
                            return . blockDataToJSON net $
                                if n
                                    then b
                                             { blockDataTxs =
                                                   take 1 (blockDataTxs b)
                                             }
                                    else b
            S.json res
        S.get "/block/heights" $ do
            cors
            heights <- param "heights"
            n <- parse_no_tx
            res <-
                withSnapshot db $ \s -> do
                    let d = (db, defaultReadOptions {useSnapshot = Just s})
                    bs <- mapM (getBlocksAtHeight d) (nub heights)
                    forM bs $ \hs ->
                        fmap catMaybes . forM hs $ \bh ->
                            runMaybeT $ do
                                b <- MaybeT $ getBlock d bh
                                return . blockDataToJSON net $
                                    if n
                                        then b
                                                 { blockDataTxs =
                                                       take 1 (blockDataTxs b)
                                                 }
                                        else b
            S.json res
        S.get "/blocks" $ do
            cors
            blocks <- param "blocks"
            n <- parse_no_tx
            res <-
                withSnapshot db $ \s -> do
                    let d = (db, defaultReadOptions {useSnapshot = Just s})
                    fmap catMaybes . forM blocks $ \bh ->
                        runMaybeT $ do
                            b <- MaybeT $ getBlock d bh
                            return . blockDataToJSON net $
                                if n
                                    then b
                                             { blockDataTxs =
                                                   take 1 (blockDataTxs b)
                                             }
                                    else b
            S.json res
        S.get "/mempool" $ do
            cors
            setHeader "Content-Type" "application/json"
            (mlimit, mbr) <- parse_limits
            mpu <-
                case mbr of
                    Just BlockRef {} ->
                        raise $
                        UserError "mempool transactions do not have height"
                    Just (MemRef t) -> return $ Just t
                    Nothing -> return Nothing
            stream $ \io flush' ->
                withSnapshot db $ \s ->
                    runResourceT . runConduit $
                    getMempool
                        (db, defaultReadOptions {useSnapshot = Just s})
                        mpu .|
                    mapC snd .|
                    apply_limit mlimit .|
                    jsonListConduit toEncoding .|
                    streamConduit io >>
                    liftIO flush'
        S.get "/transaction/:txid" $ do
            cors
            txid <- param "txid"
            res <-
                withSnapshot db $ \s -> do
                    let d = (db, defaultReadOptions {useSnapshot = Just s})
                    getTransaction d txid
            let f = transactionToJSON net
            maybeJSON $ fmap f res
        S.get "/transaction/:txid/hex" $ do
            cors
            txid <- param "txid"
            res <-
                withSnapshot db $ \s -> do
                    let d = (db, defaultReadOptions {useSnapshot = Just s})
                    getTransaction d txid
            case res of
                Nothing -> raise ThingNotFound
                Just x ->
                    text . cs . encodeHex $ Serialize.encode (transactionData x)
        S.get "/transaction/:txid/after/:height" $ do
            cors
            txid <- param "txid"
            height <- param "height"
            res <-
                withSnapshot db $ \s -> do
                    let d = (db, defaultReadOptions {useSnapshot = Just s})
                    cbAfterHeight d 10000 height txid
            S.json $ object ["result" .= res]
        S.get "/transactions" $ do
            cors
            txids <- param "txids"
            res <-
                withSnapshot db $ \s -> do
                    let d = (db, defaultReadOptions {useSnapshot = Just s})
                    catMaybes <$> mapM (getTransaction d) (nub txids)
            S.json $ map (transactionToJSON net) res
        S.get "/transactions/hex" $ do
            cors
            txids <- param "txids"
            res <-
                withSnapshot db $ \s -> do
                    let d = (db, defaultReadOptions {useSnapshot = Just s})
                    catMaybes <$> mapM (getTransaction d) (nub txids)
            S.json $ map (encodeHex . Serialize.encode . transactionData) res
        S.get "/address/:address/transactions" $ do
            cors
            address <- parse_address
            setHeader "Content-Type" "application/json"
            (mlimit, mbr) <- parse_limits
            liftIO $ print (mlimit, mbr)
            stream $ \io flush' ->
                withSnapshot db $ \s ->
                    runResourceT . runConduit $
                    getAddressTxs
                        (db, defaultReadOptions {useSnapshot = Just s})
                        address
                        mbr .|
                    apply_limit mlimit .|
                    jsonListConduit toEncoding .|
                    streamConduit io >>
                    liftIO flush'
        S.get "/address/transactions" $ do
            cors
            addresses <- parse_addresses
            setHeader "Content-Type" "application/json"
            (mlimit, mbr) <- parse_limits
            stream $ \io flush' ->
                withSnapshot db $ \s ->
                    runResourceT . runConduit $
                    mergeSourcesBy
                        (flip compare `on` blockTxBlock)
                        (map (\a ->
                                  getAddressTxs
                                      ( db
                                      , defaultReadOptions
                                            {useSnapshot = Just s})
                                      a
                                      mbr)
                             addresses) .|
                    dedup .|
                    apply_limit mlimit .|
                    jsonListConduit toEncoding .|
                    streamConduit io >>
                    liftIO flush'
        S.get "/address/:address/unspent" $ do
            cors
            address <- parse_address
            setHeader "Content-Type" "application/json"
            (mlimit, mbr) <- parse_limits
            stream $ \io flush' ->
                withSnapshot db $ \s ->
                    runResourceT . runConduit $
                    getAddressUnspents
                        (db, defaultReadOptions {useSnapshot = Just s})
                        address
                        mbr .|
                    apply_limit mlimit .|
                    jsonListConduit (unspentToEncoding net) .|
                    streamConduit io >>
                    liftIO flush'
        S.get "/address/unspent" $ do
            cors
            addresses <- parse_addresses
            setHeader "Content-Type" "application/json"
            (mlimit, mbr) <- parse_limits
            stream $ \io flush' ->
                withSnapshot db $ \s ->
                    runResourceT . runConduit $
                    mergeSourcesBy
                        (flip compare `on` unspentBlock)
                        (map (\a ->
                                  getAddressUnspents
                                      ( db
                                      , defaultReadOptions
                                            {useSnapshot = Just s})
                                      a
                                      mbr)
                             addresses) .|
                    apply_limit mlimit .|
                    jsonListConduit (unspentToEncoding net) .|
                    streamConduit io >>
                    liftIO flush'
        S.get "/address/:address/balance" $ do
            cors
            address <- parse_address
            res <-
                withSnapshot db $ \s -> do
                    let d = (db, defaultReadOptions {useSnapshot = Just s})
                    getBalance d address >>= \case
                        Just b -> return b
                        Nothing ->
                            return
                                Balance
                                    { balanceAddress = address
                                    , balanceAmount = 0
                                    , balanceUnspentCount = 0
                                    , balanceZero = 0
                                    , balanceTxCount = 0
                                    , balanceTotalReceived = 0
                                    }
            S.json $ balanceToJSON net res
        S.get "/address/balances" $ do
            cors
            addresses <- parse_addresses
            res <-
                withSnapshot db $ \s -> do
                    let d = (db, defaultReadOptions {useSnapshot = Just s})
                        f a Nothing =
                            Balance
                                { balanceAddress = a
                                , balanceAmount = 0
                                , balanceUnspentCount = 0
                                , balanceZero = 0
                                , balanceTxCount = 0
                                , balanceTotalReceived = 0
                                }
                        f _ (Just b) = b
                    mapM (\a -> f a <$> getBalance d a) addresses
            S.json $ map (balanceToJSON net) res
        S.get "/xpub/:xpub/balances" $ do
            cors
            xpub <- parse_xpub
            res <-
                withSnapshot db $ \s -> do
                    let d = (db, defaultReadOptions {useSnapshot = Just s})
                    runResourceT $ xpubBals d xpub
            S.json $ map (xPubBalToJSON net) res
        S.get "/xpub/:xpub/transactions" $ do
            cors
            xpub <- parse_xpub
            setHeader "Content-Type" "application/json"
            (mlimit, mbr) <- parse_limits
            stream $ \io flush' ->
                withSnapshot db $ \s ->
                    runResourceT . runConduit $
                    xpubTxs
                        (db, defaultReadOptions {useSnapshot = Just s})
                        mbr
                        xpub .|
                    dedup .|
                    apply_limit mlimit .|
                    jsonListConduit toEncoding .|
                    streamConduit io >>
                    liftIO flush'
        S.get "/xpub/:xpub/unspent" $ do
            cors
            xpub <- parse_xpub
            setHeader "Content-Type" "application/json"
            (mlimit, mbr) <- parse_limits
            stream $ \io flush' ->
                withSnapshot db $ \s ->
                    runResourceT . runConduit $
                    xpubUnspent
                        (db, defaultReadOptions {useSnapshot = Just s})
                        mbr
                        xpub .|
                    apply_limit mlimit .|
                    jsonListConduit (xPubUnspentToEncoding net) .|
                    streamConduit io >>
                    liftIO flush'
        S.post "/transactions" $ do
            cors
            hex_tx <- C.filter (not . isSpace) <$> body
            bin_tx <-
                case decodeHex (cs hex_tx) of
                    Nothing -> do
                        status status400
                        S.json (UserError "decode hex fail")
                        finish
                    Just x -> return x
            tx <-
                case Serialize.decode bin_tx of
                    Left _ -> do
                        status status400
                        S.json (UserError "decode tx within hex fail")
                        finish
                    Right x -> return x
            lift (publishTx pub st db tx) >>= \case
                Right () -> S.json $ object ["txid" .= txHash tx]
                Left e -> do
                    case e of
                        PubNoPeers -> status status500
                        PubTimeout -> status status500
                        PubPeerDisconnected -> status status500
                        PubNotFound -> status status500
                        PubReject _ -> status status400
                    S.json (UserError (show e))
                    finish
        S.get "/dbstats" $ do
            cors
            getProperty db Stats >>= text . cs . fromJust
        S.get "/events" $ do
            cors
            setHeader "Content-Type" "application/x-json-stream"
            stream $ \io flush' ->
                withSubscription pub $ \sub ->
                    forever $
                    flush' >> receive sub >>= \case
                        StoreBestBlock block_hash -> do
                            let bs =
                                    A.encode (JsonEventBlock block_hash) <> "\n"
                            io (lazyByteString bs)
                        StoreMempoolNew tx_hash -> do
                            let bs = A.encode (JsonEventTx tx_hash) <> "\n"
                            io (lazyByteString bs)
                        _ -> return ()
        S.get "/peers" $ do
            cors
            getPeersInformation (storeManager st) >>= S.json
        S.get "/health" $ do
            cors
            h <-
                liftIO $
                healthCheck
                    net
                    (db, defaultReadOptions)
                    (storeManager st)
                    (storeChain st)
            when (not (healthOK h) || not (healthSynced h)) $ status status503
            S.json h
        notFound $ raise ThingNotFound
  where
    parse_limits = do
        let b = do
                height <- param "height"
                pos <- param "pos" `rescue` const (return maxBound)
                return $ BlockRef height pos
            m = do
                time <- param "time"
                return $ MemRef (PreciseUnixTime time)
        mlimit <- fmap Just (param "limit") `rescue` const (return Nothing)
        case mlimit of
            Just l
                | l < 0 -> raise $ UserError "limit cannot be negative"
            _ -> return ()
        mbr <- Just <$> b <|> Just <$> m <|> return Nothing
        return (mlimit, mbr)
    apply_limit Nothing = mapC id
    apply_limit (Just l) = takeC l
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
    parse_address = do
        address <- param "address"
        case stringToAddr net address of
            Nothing -> next
            Just a -> return a
    parse_addresses = do
        addresses <- param "addresses"
        let as = mapMaybe (stringToAddr net) addresses
        unless (length as == length addresses) next
        return as
    parse_xpub = do
        t <- param "xpub"
        case xPubImport net t of
            Nothing -> next
            Just x -> return x
    net = configNetwork conf
    parse_no_tx = param "notx" `rescue` const (return False)
    runner f l = do
        u <- askUnliftIO
        unliftIO u (runLoggingT l f)
    cors = setHeader "Access-Control-Allow-Origin" "*"

jsonListConduit :: Monad m => (a -> Encoding) -> ConduitT a Builder m ()
jsonListConduit f =
    yield "[" >> mapC (fromEncoding . f) .| intersperseC "," >> yield "]"

streamConduit :: MonadIO m => (i -> IO ()) -> ConduitT i o m ()
streamConduit io = mapM_C (liftIO . io)
