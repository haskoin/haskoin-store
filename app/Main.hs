{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
import           Control.Arrow
import           Control.Concurrent.NQE
import           Control.Exception
import           Control.Monad
import           Control.Monad.Logger
import           Control.Monad.Trans
import           Data.Aeson                  (ToJSON (..), Value (..), object,
                                              (.=))
import           Data.Bits
import           Data.Maybe
import           Data.String.Conversions
import qualified Data.Text                   as T
import           Database.RocksDB            hiding (get)
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Crypto
import           Network.Haskoin.Node
import           Network.Haskoin.Store
import           Network.Haskoin.Transaction
import           Network.HTTP.Types
import           Options.Applicative
import           System.Directory
import           System.Exit                 (die)
import           System.FilePath
import           System.IO.Unsafe
import           Text.Read                   (readMaybe)
import           UnliftIO
import           Web.Scotty.Trans

data OptConfig = OptConfig
    { optConfigDir      :: !(Maybe FilePath)
    , optConfigPort     :: !(Maybe Int)
    , optConfigNetwork  :: !(Maybe Network)
    , optConfigDiscover :: !(Maybe Bool)
    , optConfigPeers    :: !(Maybe [(Host, Maybe Port)])
    }

data Config = Config
    { configDir      :: !FilePath
    , configPort     :: !Int
    , configNetwork  :: !Network
    , configDiscover :: !Bool
    , configPeers    :: ![(Host, Maybe Port)]
    }

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
    }

instance Parsable BlockHash where
    parseParam =
        maybe (Left "Could not decode block hash") Right . hexToBlockHash . cs

instance Parsable TxHash where
    parseParam =
        maybe (Left "Could not decode tx hash") Right . hexToTxHash . cs

instance Parsable Address where
    parseParam =
        maybe (Left "Could not decode address") Right . base58ToAddr . cs

data Except
    = NotFound
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
    toJSON NotFound = object ["error" .= String "Not found"]
    toJSON BadRequest = object ["error" .= String "Bad request"]
    toJSON ServerError = object ["error" .= String "You made me kill a unicorn"]
    toJSON (StringError _) = object ["error" .= String "You made me kill a unicorn"]
    toJSON (UserError s) = object ["error" .= s]

config :: Parser OptConfig
config =
    OptConfig <$>
    optional
        (option
             str
             (metavar "DIR" <> long "dir" <> short 'd' <>
              help
                  ("Directory to store blockchain data (default: " <>
                   myDirectory <>
                   ")"))) <*>
    optional
        (option
             auto
             (metavar "PORT" <> long "port" <> short 'p' <>
              help ("Port number (default: " <> show defPort <> ")"))) <*>
    optional
        (option
             (eitherReader networkReader)
             (metavar "NETWORK" <> long "network" <> short 'n' <>
              help
                  ("Network to use: " <>
                   "btc|btc-test|btc-regtest|bch|bch-test|bch-regtest (default: " <>
                   getNetworkName defNetwork <>
                   ")"))) <*>
    optional (switch (long "discover" <> help "Enable peer discovery")) <*>
    optional
        (option
             (eitherReader peerReader)
             (metavar "PEERS" <> long "peers" <>
              help
                  ("Comma-separated list of peers to connect to " <>
                   "(i.e. localhost,peer.example.com:8333)")))

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
defHandler NotFound      = status status404 >> json NotFound
defHandler BadRequest    = status status400 >> json BadRequest
defHandler (UserError s) = status status400 >> json (UserError s)
defHandler e             = status status400 >> json e

maybeJSON :: (Monad m, ToJSON a) => Maybe a -> ActionT Except m ()
maybeJSON Nothing  = raise NotFound
maybeJSON (Just x) = json x

myDirectory :: FilePath
myDirectory = unsafePerformIO $ getAppUserDataDirectory "haskoin-store"
{-# NOINLINE myDirectory #-}

main :: IO ()
main =
    runStderrLoggingT $ do
        opt <- liftIO (execParser opts)
        let conf = optToConfig opt
        when (null (configPeers conf) && not (configDiscover conf)) . liftIO $
            die "Specify --discover or --peers [PEER,...]"
        liftIO . setNetwork $ configNetwork conf
        b <- Inbox <$> newTQueueIO
        s <- Inbox <$> newTQueueIO
        let wdir = configDir conf </> networkName
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
        supervisor
            KillAll
            s
            [runWeb conf pub mgr db, runStore conf pub mgr b db]
  where
    opts =
        info
            (helper <*> config)
            (fullDesc <> progDesc "Blockchain store and API" <>
             Options.Applicative.header "haskoin-store: a blockchain indexer")

runWeb ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Config
    -> Publisher Inbox StoreEvent
    -> Manager
    -> DB
    -> m ()
runWeb conf pub mgr db = do
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
            getBlocksAtHeights heights db Nothing >>= json
        get "/blocks" $ do
            blocks <- param "blocks"
            getBlocks blocks db Nothing >>= json
        get "/mempool" $ lift (getMempool db Nothing) >>= json
        get "/transaction/:txid" $ do
            txid <- param "txid"
            lift (getTx txid db Nothing) >>= maybeJSON
        get "/transactions" $ do
            txids <- param "txids"
            lift (getTxs txids db Nothing) >>= json
        get "/address/:address/transactions" $ do
            address <- param "address"
            lift (getAddrTxs address db Nothing) >>= json
        get "/address/transactions" $ do
            addresses <- param "addresses"
            lift (getAddrsTxs addresses db Nothing) >>= json
        get "/address/:address/unspent" $ do
            address <- param "address"
            lift (getUnspent address db Nothing) >>= json
        get "/address/unspent" $ do
            addresses <- param "addresses"
            lift (getUnspents addresses db Nothing) >>= json
        get "/address/:address/balance" $ do
            address <- param "address"
            getBalance address db Nothing >>= json
        get "/address/balances" $ do
            addresses <- param "addresses"
            getBalances addresses db Nothing >>= json
        post "/transactions" $ do
            NewTx tx <- jsonData
            d <- lift (publishTx pub mgr db tx)
            case d of
                Left e -> do
                    status status400
                    json (UserError ("Invalid transaction: " <> show e))
                Right j -> json j
        get "/dbstats" $ getProperty db Stats >>= text . cs . fromJust
        notFound $ raise NotFound
  where
    runner f l = do
        u <- askUnliftIO
        unliftIO u (runLoggingT l f)

runStore ::
       (MonadLoggerIO m, MonadUnliftIO m)
    => Config
    -> Publisher Inbox StoreEvent
    -> Manager
    -> BlockStore
    -> DB
    -> m ()
runStore conf pub mgr b db = do
    s <- Inbox <$> newTQueueIO
    c <- Inbox <$> newTQueueIO
    let cfg =
            StoreConfig
            { storeConfBlocks = b
            , storeConfSupervisor = s
            , storeConfChain = c
            , storeConfManager = mgr
            , storeConfPublisher = pub
            , storeConfMaxPeers = 20
            , storeConfInitPeers =
                  map (second (fromMaybe defaultPort)) (configPeers conf)
            , storeConfDiscover = configDiscover conf
            , storeConfDB = db
            }
    store cfg
