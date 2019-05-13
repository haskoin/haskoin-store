{-# LANGUAGE ApplicativeDo     #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE MultiWayIf        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
import           Conduit
import           Control.Arrow
import           Control.Exception          ()
import           Control.Monad
import           Control.Monad.Logger
import           Control.Monad.Trans.Maybe
import           Data.Aeson.Encoding        (encodingToLazyByteString,
                                             fromEncoding)
import           Data.Bits
import           Data.ByteString.Builder
import qualified Data.ByteString.Lazy       as L
import qualified Data.ByteString.Lazy.Char8 as C
import           Data.Char
import           Data.Function
import           Data.List
import           Data.Maybe
import           Data.Serialize             as Serialize
import           Data.String.Conversions
import qualified Data.Text.Lazy             as T
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

defHandler :: Monad m => Network -> Except -> ActionT Except m ()
defHandler net e = do
    proto <- setupBin
    case e of
        ThingNotFound -> status status404
        BadRequest    -> status status400
        UserError _   -> status status400
        StringError _ -> status status400
        ServerError   -> status status500
    S.raw $ serialAny net proto e

maybeSerial :: (Monad m, JsonSerial a, BinSerial a) => Network -> Bool -- ^ protobuf
            -> Maybe a -> ActionT Except m ()
maybeSerial _ _ Nothing        = raise ThingNotFound
maybeSerial net proto (Just x) = S.raw $ serialAny net proto x

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
        defaultHandler (defHandler net)
        S.get "/block/best" $ do
            cors
            n <- parse_no_tx
            proto <- setupBin
            res <-
                runMaybeT $ do
                    bh <-
                        MaybeT $ withBlockDB defaultReadOptions db getBestBlock
                    b <-
                        MaybeT . withBlockDB defaultReadOptions db $ getBlock bh
                    if n
                        then return b {blockDataTxs = take 1 (blockDataTxs b)}
                        else return b
            maybeSerial net proto res
        S.get "/block/:block" $ do
            cors
            block <- param "block"
            n <- parse_no_tx
            proto <- setupBin
            res <-
                runMaybeT $ do
                    b <-
                        MaybeT . withBlockDB defaultReadOptions db $
                        getBlock block
                    if n
                        then return b {blockDataTxs = take 1 (blockDataTxs b)}
                        else return b
            maybeSerial net proto res
        S.get "/block/height/:height" $ do
            cors
            height <- param "height"
            no_tx <- parse_no_tx
            proto <- setupBin
            res <-
                do bs <-
                       withBlockDB defaultReadOptions db $
                       getBlocksAtHeight height
                   fmap catMaybes . forM bs $ \bh ->
                       runMaybeT $ do
                           b <-
                               MaybeT . withBlockDB defaultReadOptions db $
                               getBlock bh
                           return
                               b
                                   { blockDataTxs =
                                         if no_tx
                                             then take 1 (blockDataTxs b)
                                             else blockDataTxs b
                                   }
            S.raw $ serialAny net proto res
        S.get "/block/heights" $ do
            cors
            heights <- param "heights"
            no_tx <- parse_no_tx
            proto <- setupBin
            res <-
                withBlockDB defaultReadOptions db $ do
                    bs <- concat <$> mapM getBlocksAtHeight (nub heights)
                    fmap catMaybes . forM bs $ \bh ->
                        runMaybeT $ do
                            b <- MaybeT $ getBlock bh
                            return
                                b
                                    { blockDataTxs =
                                          if no_tx
                                              then take 1 (blockDataTxs b)
                                              else blockDataTxs b
                                    }
            S.raw $ serialAny net proto res
        S.get "/blocks" $ do
            cors
            blocks <- param "blocks"
            no_tx <- parse_no_tx
            proto <- setupBin
            res <-
                withBlockDB defaultReadOptions db $
                fmap catMaybes . forM blocks $ \bh ->
                    runMaybeT $ do
                        b <- MaybeT $ getBlock bh
                        return
                            b
                                { blockDataTxs =
                                      if no_tx
                                          then take 1 (blockDataTxs b)
                                          else blockDataTxs b
                                }
            S.raw $ serialAny net proto res
        S.get "/mempool" $ do
            cors
            (l, s) <- parse_limits
            proto <- setupBin
            stream $ \io flush' ->
                runResourceT . withBlockDB defaultReadOptions db $ do
                    runConduit $ getMempoolLimit l s .| streamAny net proto io
                    liftIO flush'
        S.get "/transaction/:txid" $ do
            cors
            txid <- param "txid"
            proto <- setupBin
            res <- withBlockDB defaultReadOptions db $ getTransaction txid
            maybeSerial net proto res
        S.get "/transaction/:txid/hex" $ do
            cors
            txid <- param "txid"
            res <- withBlockDB defaultReadOptions db $ getTransaction txid
            case res of
                Nothing -> raise ThingNotFound
                Just x ->
                    text . cs . encodeHex $ Serialize.encode (transactionData x)
        S.get "/transaction/:txid/bin" $ do
            cors
            txid <- param "txid"
            res <- withBlockDB defaultReadOptions db $ getTransaction txid
            case res of
                Nothing -> raise ThingNotFound
                Just x -> do
                    S.setHeader "Content-Type" "application/octet-stream"
                    S.raw $ Serialize.encodeLazy (transactionData x)
        S.get "/transaction/:txid/after/:height" $ do
            cors
            txid <- param "txid"
            height <- param "height"
            proto <- setupBin
            res <-
                withBlockDB defaultReadOptions db $
                cbAfterHeight 10000 height txid
            S.raw $ serialAny net proto res
        S.get "/transactions" $ do
            cors
            txids <- param "txids"
            proto <- setupBin
            res <-
                withBlockDB defaultReadOptions db $
                catMaybes <$> mapM getTransaction (nub txids)
            S.raw $ serialAny net proto res
        S.get "/transactions/hex" $ do
            cors
            txids <- param "txids"
            res <-
                withBlockDB defaultReadOptions db $
                catMaybes <$> mapM getTransaction (nub txids)
            S.json $ map (encodeHex . Serialize.encode . transactionData) res
        S.get "/transactions/bin" $ do
            cors
            txids <- param "txids"
            res <-
                withBlockDB defaultReadOptions db $
                catMaybes <$> mapM getTransaction (nub txids)
            S.setHeader "Content-Type" "application/octet-stream"
            S.raw . L.concat $ map (Serialize.encodeLazy . transactionData) res
        S.get "/address/:address/transactions" $ do
            cors
            a <- parse_address
            (l, s) <- parse_limits
            proto <- setupBin
            stream $ \io flush' ->
                runResourceT . withBlockDB defaultReadOptions db $ do
                    runConduit $
                        getAddressTxsLimit l s a .| streamAny net proto io
                    liftIO flush'
        S.get "/address/:address/transactions/full" $ do
            cors
            a <- parse_address
            (l, s) <- parse_limits
            proto <- setupBin
            stream $ \io flush' ->
                runResourceT . withBlockDB defaultReadOptions db $ do
                    runConduit $
                        getAddressTxsFull l s a .| streamAny net proto io
                    liftIO flush'
        S.get "/address/transactions" $ do
            cors
            as <- parse_addresses
            (l, s) <- parse_limits
            proto <- setupBin
            stream $ \io flush' ->
                runResourceT . withBlockDB defaultReadOptions db $ do
                    runConduit $
                        getAddressesTxsLimit l s as .| streamAny net proto io
                    liftIO flush'
        S.get "/address/transactions/full" $ do
            cors
            as <- parse_addresses
            (l, s) <- parse_limits
            proto <- setupBin
            stream $ \io flush' ->
                runResourceT . withBlockDB defaultReadOptions db $ do
                    runConduit $
                        getAddressesTxsFull l s as .| streamAny net proto io
                    liftIO flush'
        S.get "/address/:address/unspent" $ do
            cors
            a <- parse_address
            (l, s) <- parse_limits
            proto <- setupBin
            stream $ \io flush' ->
                runResourceT . withBlockDB defaultReadOptions db $ do
                    runConduit $
                        getAddressUnspentsLimit l s a .| streamAny net proto io
                    liftIO flush'
        S.get "/address/unspent" $ do
            cors
            as <- parse_addresses
            (l, s) <- parse_limits
            proto <- setupBin
            stream $ \io flush' ->
                runResourceT . withBlockDB defaultReadOptions db $ do
                    runConduit $
                        getAddressesUnspentsLimit l s as .|
                        streamAny net proto io
                    liftIO flush'
        S.get "/address/:address/balance" $ do
            cors
            address <- parse_address
            proto <- setupBin
            res <-
                withBlockDB defaultReadOptions db $
                getBalance address >>= \case
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
            S.raw $ serialAny net proto res
        S.get "/address/balances" $ do
            cors
            addresses <- parse_addresses
            proto <- setupBin
            res <-
                withBlockDB defaultReadOptions db $ do
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
                    mapM (\a -> f a <$> getBalance a) addresses
            S.raw $ serialAny net proto res
        S.get "/xpub/:xpub/balances" $ do
            cors
            xpub <- parse_xpub
            proto <- setupBin
            res <- withBlockDB defaultReadOptions db $ xpubBals xpub
            S.raw $ serialAny net proto res
        S.get "/xpub/:xpub/transactions" $ do
            cors
            x <- parse_xpub
            (l, s) <- parse_limits
            proto <- setupBin
            bs <- withBlockDB defaultReadOptions db $ xpubBals x
            stream $ \io flush' ->
                runResourceT . withBlockDB defaultReadOptions db $ do
                    runConduit $ xpubTxsLimit l s bs .| streamAny net proto io
                    liftIO flush'
        S.get "/xpub/:xpub/transactions/full" $ do
            cors
            xpub <- parse_xpub
            (l, s) <- parse_limits
            proto <- setupBin
            bs <- withBlockDB defaultReadOptions db $ xpubBals xpub
            stream $ \io flush' ->
                runResourceT . withBlockDB defaultReadOptions db $ do
                    runConduit $ xpubTxsFull l s bs .| streamAny net proto io
                    liftIO flush'
        S.get "/xpub/:xpub/unspent" $ do
            cors
            x <- parse_xpub
            proto <- setupBin
            (l, s) <- parse_limits
            stream $ \io flush' ->
                runResourceT . withBlockDB defaultReadOptions db $ do
                    runConduit $
                        xpubUnspentLimit l s x .| streamAny net proto io
                    liftIO flush'
        S.get "/xpub/:xpub" $ do
            cors
            x <- parse_xpub
            (l, s) <- parse_limits
            proto <- setupBin
            res <-
                lift . runResourceT $
                withBlockDB defaultReadOptions db $ xpubSummary l s x
            S.raw $ serialAny net proto res
        S.post "/transactions" $ do
            cors
            proto <- setupBin
            b <- body
            let bin = eitherToMaybe . Serialize.decode
                hex = bin <=< decodeHex . cs . C.filter (not . isSpace)
            tx <-
                case hex b <|> bin (L.toStrict b) of
                    Nothing -> raise (UserError "decode tx fail")
                    Just x -> return x
            lift (publishTx net pub st db tx) >>= \case
                Right () -> do
                    S.raw $ serialAny net proto (TxId (txHash tx))
                    lift $
                        $(logDebugS) "Main" $
                        "Success publishing tx " <> txHashToHex (txHash tx)
                Left e -> do
                    case e of
                        PubNoPeers -> status status500
                        PubTimeout -> status status500
                        PubPeerDisconnected -> status status500
                        PubNotFound -> status status500
                        PubReject _ -> status status400
                    S.raw $ serialAny net proto (UserError (show e))
                    lift $
                        $(logErrorS) "Main" $
                        "Error publishing tx " <> txHashToHex (txHash tx) <>
                        ": " <>
                        cs (show e)
                    finish
        S.get "/dbstats" $ do
            cors
            getProperty db Stats >>= text . cs . fromJust
        S.get "/events" $ do
            cors
            proto <- setupBin
            stream $ \io flush' ->
                withSubscription pub $ \sub ->
                    forever $
                    flush' >> receive sub >>= \se -> do
                        let me =
                                case se of
                                    StoreBestBlock block_hash ->
                                        Just (EventBlock block_hash)
                                    StoreMempoolNew tx_hash ->
                                        Just (EventTx tx_hash)
                                    _ -> Nothing
                        case me of
                            Nothing -> return ()
                            Just e -> do
                                let bs =
                                        serialAny net proto e <>
                                        if proto
                                            then mempty
                                            else "\n"
                                io (lazyByteString bs)
        S.get "/peers" $ do
            cors
            proto <- setupBin
            ps <- getPeersInformation (storeManager st)
            S.raw $ serialAny net proto ps
        S.get "/health" $ do
            cors
            proto <- setupBin
            h <-
                liftIO . withBlockDB defaultReadOptions db $
                healthCheck net (storeManager st) (storeChain st)
            when (not (healthOK h) || not (healthSynced h)) $ status status503
            S.raw $ serialAny net proto h
        notFound $ raise ThingNotFound
  where
    parse_limits = do
        let b = do
                height <- param "height"
                pos <- param "pos" `rescue` const (return maxBound)
                return $ StartBlock height pos
            m = do
                time <- param "time"
                return $ StartMem (PreciseUnixTime time)
            o = do
                o <- param "offset" `rescue` const (return 0)
                return $ StartOffset o
        l <- (Just <$> param "limit") `rescue` const (return Nothing)
        s <- b <|> m <|> o
        return (l, s)
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
    is_binary x =
        let ts =
                map
                    (T.takeWhile (/= ';'))
                    (T.splitOn "," (T.filter (not . isSpace) x))
         in elem "application/octet-stream" ts
