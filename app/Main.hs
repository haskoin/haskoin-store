{-# LANGUAGE ApplicativeDo     #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
import           Conduit
import           Control.Arrow
import           Control.Concurrent.NQE
import           Control.Exception
import           Control.Monad
import           Control.Monad.Logger
import           Data.Aeson              (ToJSON (..), Value (..), encode,
                                          object, (.=))
import           Data.Bits
import           Data.ByteString.Builder (lazyByteString)
import           Data.Function
import           Data.List
import           Data.Maybe
import           Data.String.Conversions
import qualified Data.Text               as T
import           Data.Version
import           Database.RocksDB        hiding (get)
import           Haskoin
import           Network.Haskoin.Node
import           Network.Haskoin.Store
import           Network.HTTP.Types
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
    , optConfigPort     :: !(Maybe Int)
    , optConfigNetwork  :: !(Maybe Network)
    , optConfigDiscover :: !(Maybe Bool)
    , optConfigPeers    :: !(Maybe [(Host, Maybe Port)])
    , optConfigMaxReqs  :: !(Maybe Int)
    , optConfigVersion  :: !Bool
    }

data Config = Config
    { configDir      :: !FilePath
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
        b <- Inbox <$> newTQueueIO
        s <- Inbox <$> newTQueueIO
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
        mgr <- Inbox <$> newTQueueIO
        pub <- Inbox <$> newTQueueIO
        ch <- Inbox <$> newTQueueIO
        supervisor
            KillAll
            s
            [runWeb conf pub mgr ch b db, runStore conf pub mgr ch b db]
  where
    opts =
        info (helper <*> config) $
        fullDesc <> progDesc "Blockchain store and API" <>
        Options.Applicative.header ("haskoin-store version " <> showVersion P.version)

testLength :: Monad m => Int -> ActionT Except m ()
testLength l = when (l <= 0 || l > maxUriArgs) (raise OutOfBounds)

runWeb ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Config
    -> Publisher Inbox TBQueue StoreEvent
    -> Manager
    -> Chain
    -> BlockStore
    -> DB
    -> m ()
runWeb conf pub mgr ch bl db = do
    l <- askLoggerIO
    scottyT (configPort conf) (runner l) $ do
        defaultHandler defHandler
        get "/block/best" $ getBestBlock db Nothing >>= json
        get "/block/:block" $ do
            block <- param "block"
            getBlock block db Nothing >>= maybeJSON
        get "/block/height/:height" $ do
            height <- param "height"
            getBlockAtHeight height db Nothing >>= maybeJSON
        get "/block/heights" $ do
            heights <- param "heights"
            testLength (length heights)
            getBlocksAtHeights heights db Nothing >>= json
        get "/blocks" $ do
            blocks <- param "blocks"
            testLength (length blocks)
            getBlocks blocks db Nothing >>= json
        get "/mempool" $ lift (getMempool db Nothing) >>= json
        get "/transaction/:txid" $ do
            txid <- param "txid"
            lift (getTx net txid db Nothing) >>= maybeJSON
        get "/transactions" $ do
            txids <- param "txids"
            testLength (length txids)
            lift (getTxs net txids db Nothing) >>= json
        get "/address/:address/outputs" $ do
            address <- parse_address
            height <- parse_height
            x <- parse_max
            lift (addrTxsMax db x height address) >>= json
        get "/address/outputs" $ do
            addresses <- parse_addresses
            height <- parse_height
            x <- parse_max
            lift (addrsTxsMax db x height addresses) >>= json
        get "/address/:address/unspent" $ do
            address <- parse_address
            height <- parse_height
            x <- parse_max
            lift (addrUnspentMax db x height address) >>= json
        get "/address/unspent" $ do
            addresses <- parse_addresses
            height <- parse_height
            x <- parse_max
            lift (addrsUnspentMax db x height addresses) >>= json
        get "/address/:address/balance" $ do
            address <- parse_address
            getBalance address db Nothing >>= json
        get "/address/balances" $ do
            addresses <- parse_addresses
            getBalances addresses db Nothing >>= json
        post "/transactions" $ do
            NewTx tx <- jsonData
            lift (publishTx net pub mgr ch db bl tx) >>= \case
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
                withBoundedPubSub maxPubSubQueue pub $ \sub ->
                    forever $
                    flush >> receive sub >>= \case
                        BestBlock block_hash -> do
                            let bs = encode (JsonEventBlock block_hash) <> "\n"
                            io (lazyByteString bs)
                        MempoolNew tx_hash -> do
                            let bs = encode (JsonEventTx tx_hash) <> "\n"
                            io (lazyByteString bs)
                        _ -> return ()
        notFound $ raise ThingNotFound
  where
    parse_address = do
        address <- param "address"
        case stringToAddr net address of
            Nothing -> next
            Just a  -> return a
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

runStore ::
       (MonadLoggerIO m, MonadUnliftIO m)
    => Config
    -> Publisher Inbox TBQueue StoreEvent
    -> Manager
    -> Chain
    -> BlockStore
    -> DB
    -> m ()
runStore conf pub mgr ch b db = do
    s <- Inbox <$> newTQueueIO
    let net = configNetwork conf
        cfg =
            StoreConfig
                { storeConfBlocks = b
                , storeConfSupervisor = s
                , storeConfChain = ch
                , storeConfManager = mgr
                , storeConfPublisher = pub
                , storeConfMaxPeers = 20
                , storeConfInitPeers =
                      map
                          (second (fromMaybe (getDefaultPort net)))
                          (configPeers conf)
                , storeConfDiscover = configDiscover conf
                , storeConfDB = db
                , storeConfNetwork = net
                }
    store cfg

addrTxsMax ::
       MonadUnliftIO m
    => DB
    -> Int
    -> Maybe BlockHeight
    -> Address
    -> m [AddrOutput]
addrTxsMax db c h = addrsTxsMax db c h . (: [])

addrsTxsMax ::
       MonadUnliftIO m
    => DB
    -> Int
    -> Maybe BlockHeight
    -> [Address]
    -> m [AddrOutput]
addrsTxsMax db c h as =
    runResourceT $
    runConduit $ getAddrsOutputs as h db Nothing .| capRecords f c .| sinkList
  where
    f = (==) `on` g
    g AddrOutput {..} =
        (addrOutputAddress addrOutputKey, blockRefHash <$> outBlock addrOutput)

addrUnspentMax ::
       MonadUnliftIO m
    => DB
    -> Int
    -> Maybe BlockHeight
    -> Address
    -> m [AddrOutput]
addrUnspentMax db c h = addrsUnspentMax db c h . (: [])

addrsUnspentMax ::
       MonadUnliftIO m
    => DB
    -> Int
    -> Maybe BlockHeight
    -> [Address]
    -> m [AddrOutput]
addrsUnspentMax db c h as =
    runResourceT $
    runConduit $ getUnspents as h db Nothing .| capRecords f c .| sinkList
  where
    f = (==) `on` g
    g AddrOutput {..} =
        (addrOutputAddress addrOutputKey, blockRefHash <$> outBlock addrOutput)

capRecords :: Monad m => (a -> a -> Bool) -> Int -> ConduitT a a m ()
capRecords f c = void $ mapAccumWhileC go (Nothing, c)
  where
    go x (acc, n)
        | n > 0 = Right ((Just x, n - 1), x)
        | otherwise =
            case acc of
                Nothing -> Left (Just x, n - 1)
                Just y ->
                    if f x y
                        then Right ((Just x, n - 1), x)
                        else Left (Just x, n - 1)
