{-# LANGUAGE ApplicativeDo     #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
import           Conduit
import           Control.Arrow
import           Control.Exception
import           Control.Monad
import           Control.Monad.Logger
import           Data.Aeson              (ToJSON (..), Value (..), encode,
                                          object, (.=))
import           Data.Bits
import           Data.ByteString.Builder (lazyByteString)
import           Data.List
import           Data.Maybe
import           Data.String.Conversions
import qualified Data.Text               as T
import           Data.Version
import           Database.RocksDB        hiding (get)
import           Haskoin
import           Haskoin.Node
import           Haskoin.Store
import           Network.HTTP.Types
import           NQE
import           Options.Applicative
import           Paths_haskoin_store     as P
import           System.Directory
import           System.Exit
import           System.FilePath
import           System.IO.Unsafe
import           Text.Read               (readMaybe)
import           UnliftIO
import           Web.Scotty.Trans

data OptConfig = OptConfig
    { optConfigDir      :: !(Maybe FilePath)
    , optConfigMemDB    :: !(Maybe FilePath)
    , optConfigPort     :: !(Maybe Int)
    , optConfigNetwork  :: !(Maybe Network)
    , optConfigDiscover :: !(Maybe Bool)
    , optConfigPeers    :: !(Maybe [(Host, Maybe Port)])
    , optConfigMaxReqs  :: !(Maybe Int)
    , optConfigVersion  :: !Bool
    }

data Config = Config
    { configDir      :: !FilePath
    , configMemDB    :: !(Maybe FilePath)
    , configPort     :: !Int
    , configNetwork  :: !Network
    , configDiscover :: !Bool
    , configPeers    :: ![(Host, Maybe Port)]
    , configMaxReqs  :: !Int
    }

maxUriArgs :: Int
maxUriArgs = 500

maxPubSubQueue :: Int
maxPubSubQueue = 10000

defMaxReqs :: Int
defMaxReqs = 10000

defPort :: Int
defPort = 3000

defNetwork :: Network
defNetwork = btc

defDiscovery :: Bool
defDiscovery = False

defPeers :: [(Host, Maybe Port)]
defPeers = []

optToConfig :: OptConfig -> Config
optToConfig OptConfig {..} =
    Config
    { configDir = fromMaybe myDirectory optConfigDir
    , configMemDB = optConfigMemDB
    , configPort = fromMaybe defPort optConfigPort
    , configNetwork = fromMaybe defNetwork optConfigNetwork
    , configDiscover = fromMaybe defDiscovery optConfigDiscover
    , configPeers = fromMaybe defPeers optConfigPeers
    , configMaxReqs = fromMaybe defMaxReqs optConfigMaxReqs
    }

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
    | OutOfBounds
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
    toJSON OutOfBounds = object ["error" .= String "too many elements requested"]
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
netNames = intercalate "|" $ map getNetworkName allNets

config :: Parser OptConfig
config = do
    optConfigDir <-
        optional . option str $
        metavar "DIR" <> long "dir" <> short 'd' <>
        help ("Data directory (default: " <> myDirectory <> ")")
    optConfigMemDB <-
        optional . option str $
        metavar "UTXO" <> long "utxo" <> short 'u' <>
        help "Memory directory for UTXO"
    optConfigPort <-
        optional . option auto $
        metavar "PORT" <> long "port" <> short 'p' <>
        help ("Port to listen (default: " <> show defPort <> ")")
    optConfigNetwork <-
        optional . option (eitherReader networkReader) $
        metavar "NETWORK" <> long "network" <> short 'n' <>
        help ("Network: " <> netNames <> " (default: " <> net <> ")")
    optConfigDiscover <-
        optional . switch $ long "discover" <> help "Enable peer discovery"
    optConfigPeers <-
        optional . option (eitherReader peerReader) $
        metavar "PEERS" <> long "peers" <>
        help "Network peers (i.e. localhost,peer.example.com:8333)"
    optConfigMaxReqs <-
        optional . option auto $
        metavar "MAXREQ" <> long "maxreq" <>
        help ("Maximum returned entries (default:" <> show defMaxReqs <> ")")
    optConfigVersion <-
        switch $ long "version" <> short 'v' <> help "Show version"
    return OptConfig {..}
  where
    net = getNetworkName defNetwork

networkReader :: String -> Either String Network
networkReader s
    | s == getNetworkName btc = Right btc
    | s == getNetworkName btcTest = Right btcTest
    | s == getNetworkName btcRegTest = Right btcRegTest
    | s == getNetworkName bch = Right bch
    | s == getNetworkName bchTest = Right bchTest
    | s == getNetworkName bchRegTest = Right bchRegTest
    | otherwise = Left "Network name invalid"

peerReader :: String -> Either String [(Host, Maybe Port)]
peerReader = mapM hp . ls
  where
    hp s = do
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
    ls = map T.unpack . T.split (== ',') . T.pack

defHandler :: Monad m => Except -> ActionT Except m ()
defHandler ServerError   = json ServerError
defHandler OutOfBounds   = status status413 >> json OutOfBounds
defHandler ThingNotFound = status status404 >> json ThingNotFound
defHandler BadRequest    = status status400 >> json BadRequest
defHandler (UserError s) = status status400 >> json (UserError s)
defHandler e             = status status400 >> json e

maybeJSON :: (Monad m, ToJSON a) => Maybe a -> ActionT Except m ()
maybeJSON Nothing  = raise ThingNotFound
maybeJSON (Just x) = json x

myDirectory :: FilePath
myDirectory = unsafePerformIO $ getAppUserDataDirectory "haskoin-store"
{-# NOINLINE myDirectory #-}

main :: IO ()
main =
    runStderrLoggingT $ do
        opt <- liftIO (execParser opts)
        when (optConfigVersion opt) . liftIO $ do
            putStrLn $ showVersion P.version
            exitSuccess
        let conf = optToConfig opt
        when (null (configPeers conf) && not (configDiscover conf)) . liftIO $
            die "Specify: --discover | --peers PEER,..."
        let net = configNetwork conf
        let wdir = configDir conf </> getNetworkName net
        liftIO $ createDirectoryIfMissing True wdir
        db <-
            open
                (wdir </> "blocks")
                defaultOptions
                    { createIfMissing = True
                    , compression = SnappyCompression
                    , maxOpenFiles = -1
                    , writeBufferSize = 2 `shift` 30
                    }
        mudb <-
            case configMemDB conf of
                Nothing -> return Nothing
                Just d ->
                    Just <$>
                    open
                        d
                        defaultOptions
                            { createIfMissing = True
                            , compression = SnappyCompression
                            }
        withStore (store_conf conf db mudb) $ \st -> runWeb conf st db
  where
    store_conf conf db mudb =
        StoreConfig
            { storeConfMaxPeers = 20
            , storeConfInitPeers =
                  map
                      (second (fromMaybe (getDefaultPort (configNetwork conf))))
                      (configPeers conf)
            , storeConfDiscover = configDiscover conf
            , storeConfDB = db
            , storeConfUnspentDB = mudb
            , storeConfNetwork = configNetwork conf
            }
    opts =
        info (helper <*> config) $
        fullDesc <> progDesc "Blockchain store and API" <>
        Options.Applicative.header
            ("haskoin-store version " <> showVersion P.version)

testLength :: Monad m => Int -> ActionT Except m ()
testLength l = when (l <= 0 || l > maxUriArgs) (raise OutOfBounds)

runWeb ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Config
    -> Store
    -> DB
    -> m ()
runWeb conf st db = do
    l <- askLoggerIO
    scottyT (configPort conf) (runner l) $ do
        defaultHandler defHandler
        get "/block/best" $ do
            res <- withSnapshot db $ getBestBlock db
            json res
        get "/block/:block" $ do
            block <- param "block"
            res <- withSnapshot db $ getBlock block db
            maybeJSON res
        get "/block/height/:height" $ do
            height <- param "height"
            res <- withSnapshot db $ getBlockAtHeight height db
            maybeJSON res
        get "/block/heights" $ do
            heights <- param "heights"
            testLength (length (heights :: [BlockHeight]))
            res <-
                withSnapshot db $ \s ->
                    mapM (\h -> getBlockAtHeight h db s) heights
            json res
        get "/blocks" $ do
            blocks <- param "blocks"
            testLength (length blocks)
            res <- withSnapshot db $ getBlocks blocks db
            json res
        get "/mempool" $ do
            res <- withSnapshot db $ getMempool db
            json res
        get "/transaction/:txid" $ do
            txid <- param "txid"
            res <- withSnapshot db $ getTx net txid db
            maybeJSON res
        get "/transactions" $ do
            txids <- param "txids"
            testLength (length (txids :: [TxHash]))
            res <- withSnapshot db $ \s -> mapM (\t -> getTx net t db s) txids
            json res
        get "/address/:address/transactions" $ do
            address <- parse_address
            height <- parse_height
            x <- parse_max
            res <- withSnapshot db $ \s -> addrTxsMax net db s x height address
            json res
        get "/address/transactions" $ do
            addresses <- parse_addresses
            height <- parse_height
            x <- parse_max
            res <-
                withSnapshot db $ \s -> addrsTxsMax net db s x height addresses
            json res
        get "/address/:address/unspent" $ do
            address <- parse_address
            height <- parse_height
            x <- parse_max
            res <- withSnapshot db $ \s -> addrUnspentMax db s x height address
            json res
        get "/address/unspent" $ do
            addresses <- parse_addresses
            height <- parse_height
            x <- parse_max
            res <-
                withSnapshot db $ \s -> addrsUnspentMax db s x height addresses
            json res
        get "/address/:address/balance" $ do
            address <- parse_address
            res <- withSnapshot db $ getBalance address db
            json res
        get "/address/balances" $ do
            addresses <- parse_addresses
            res <-
                withSnapshot db $ \s -> mapM (\a -> getBalance a db s) addresses
            json res
        post "/transactions" $ do
            NewTx tx <- jsonData
            lift (publishTx net st db tx) >>= \case
                Left PublishTimeout -> do
                    status status500
                    json (UserError (show PublishTimeout))
                Left e -> do
                    status status400
                    json (UserError (show e))
                Right j -> json j
        get "/dbstats" $ getProperty db Stats >>= text . cs . fromJust
        get "/events" $ do
            setHeader "Content-Type" "application/x-json-stream"
            stream $ \io flush ->
                withPubSub (storePublisher st) (newTBQueueIO maxPubSubQueue) $ \sub ->
                    forever $
                    flush >> receive sub >>= \case
                        BestBlock block_hash -> do
                            let bs = encode (JsonEventBlock block_hash) <> "\n"
                            io (lazyByteString bs)
                        MempoolNew tx_hash -> do
                            let bs = encode (JsonEventTx tx_hash) <> "\n"
                            io (lazyByteString bs)
                        _ -> return ()
        get "/peers" $ getPeersInformation (storeManager st) >>= json
        notFound $ raise ThingNotFound
  where
    parse_address = do
        address <- param "address"
        case stringToAddr net address of
            Nothing -> next
            Just a -> return a
    parse_addresses = do
        addresses <- param "addresses"
        let as = mapMaybe (stringToAddr net) addresses
        if length as == length addresses
            then testLength (length as) >> return as
            else next
    parse_max = do
        x <- param "max" `rescue` const (return (configMaxReqs conf))
        when (x < 1 || x > configMaxReqs conf) (raise OutOfBounds)
        return x
    parse_height = (Just <$> param "height") `rescue` const (return Nothing)
    net = configNetwork conf
    runner f l = do
        u <- askUnliftIO
        unliftIO u (runLoggingT l f)

addrTxsMax ::
       MonadUnliftIO m
    => Network
    -> DB
    -> Snapshot
    -> Int
    -> Maybe BlockHeight
    -> Address
    -> m [DetailedTx]
addrTxsMax net db s c h a = concat <$> addrsTxsMax net db s c h [a]

addrsTxsMax ::
       MonadUnliftIO m
    => Network
    -> DB
    -> Snapshot
    -> Int
    -> Maybe BlockHeight
    -> [Address]
    -> m [[DetailedTx]]
addrsTxsMax net db s c h addrs
    | c <= 0 = return []
    | otherwise =
        case addrs of
            [] -> return []
            (a:as) -> do
                ts <-
                    runResourceT . runConduit $
                    getAddrTxs net a h db s .| takeC c .| sinkList
                mappend [ts] <$> addrsTxsMax net db s (c - length ts) h as

addrUnspentMax ::
       MonadUnliftIO m
    => DB
    -> Snapshot
    -> Int
    -> Maybe BlockHeight
    -> Address
    -> m [AddrOutput]
addrUnspentMax db s c h a = concat <$> addrsUnspentMax db s c h [a]

addrsUnspentMax ::
       MonadUnliftIO m
    => DB
    -> Snapshot
    -> Int
    -> Maybe BlockHeight
    -> [Address]
    -> m [[AddrOutput]]
addrsUnspentMax db s c h addrs
    | c <= 0 = return []
    | otherwise =
        case addrs of
            [] -> return []
            (a:as) -> do
                os <-
                    runResourceT . runConduit $
                    getUnspent a h db s .| takeC c .| sinkList
                mappend [os] <$> addrsUnspentMax db s (c - length os) h as
