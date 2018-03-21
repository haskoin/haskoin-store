{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
import           Control.Arrow
import           Control.Concurrent.NQE
import           Control.Exception
import           Control.Monad
import           Control.Monad.Logger
import           Data.Aeson                  (ToJSON (..), Value (..), object,
                                              (.=))
import           Data.Bits
import           Data.Default                (def)
import           Data.Maybe
import           Data.Monoid
import           Data.Serialize              (decodeLazy)
import           Data.String.Conversions
import qualified Data.Text                   as T
import qualified Database.RocksDB            as RocksDB
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

type StoreM = ActionT Except IO

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
defNetwork = bitcoinNetwork

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
                   "bitcoin|bitcoincash|testnet3|cashtest|regtest (default: " <>
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
    | s == getNetworkName bitcoinNetwork = Right bitcoinNetwork
    | s == getNetworkName testnet3Network = Right testnet3Network
    | s == getNetworkName bitcoinCashNetwork = Right bitcoinCashNetwork
    | s == getNetworkName regTestNetwork = Right regTestNetwork
    | s == getNetworkName cashTestNetwork = Right cashTestNetwork
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

defHandler :: Except -> StoreM ()
defHandler ServerError   = json ServerError
defHandler NotFound      = status status404 >> json NotFound
defHandler BadRequest    = status status400 >> json BadRequest
defHandler (UserError s) = status status400 >> json (UserError s)
defHandler e             = status status400 >> json e

maybeJSON :: ToJSON a => Maybe a -> StoreM ()
maybeJSON Nothing  = raise NotFound
maybeJSON (Just x) = json x

myDirectory :: FilePath
myDirectory = unsafePerformIO $ getAppUserDataDirectory "haskoin-store"
{-# NOINLINE myDirectory #-}

main :: IO ()
main =
    execParser opts >>= \opt -> do
        let conf = optToConfig opt
        when (null (configPeers conf) && not (configDiscover conf)) $
            die "Specify --discover or --peers [PEER,...]"
        setNetwork $ configNetwork conf
        b <- Inbox <$> liftIO newTQueueIO
        s <- Inbox <$> liftIO newTQueueIO
        let wdir = configDir conf </> networkName
        liftIO $ createDirectoryIfMissing True wdir
        db <-
            RocksDB.open
                (wdir </> "blocks")
                def
                { RocksDB.createIfMissing = True
                , RocksDB.compression = RocksDB.SnappyCompression
                , RocksDB.maxOpenFiles = -1
                , RocksDB.writeBufferSize = 2 `shift` 30
                }
        mgr <- Inbox <$> liftIO newTQueueIO
        supervisor
            KillAll
            s
            [runWeb (configPort conf) db mgr, runStore conf mgr b db]
  where
    opts =
        info
            (helper <*> config)
            (fullDesc <> progDesc "Blockchain store and API" <>
             Options.Applicative.header "haskoin-store: a blockchain indexer")
    runWeb port db mgr =
        scottyT port id $ do
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
            get "/transaction/:txid" $ do
                txid <- param "txid"
                getTx txid db Nothing >>= maybeJSON
            get "/transactions" $ do
                txids <- param "txids"
                getTxs txids db Nothing >>= json
            get "/address/:address/transactions" $ do
                address <- param "address"
                getAddrTxs address db Nothing >>= json
            get "/address/transactions" $ do
                addresses <- param "addresses"
                getAddrsTxs addresses db Nothing >>= json
            get "/address/:address/unspent" $ do
                address <- param "address"
                getUnspent address db Nothing >>= json
            get "/address/unspent" $ do
                addresses <- param "addresses"
                getUnspents addresses db Nothing >>= json
            get "/address/:address/balance" $ do
                address <- param "address"
                getBalance address db Nothing >>= json
            get "/address/balances" $ do
                addresses <- param "addresses"
                getBalances addresses db Nothing >>= json
            post "/transaction" $ do
                te <- decodeLazy <$> body
                case te of
                    Left _ -> do
                        status status400
                        json (UserError "Invalid transaction")
                    Right tx ->
                        postTransaction db mem tx >>= \case
                            Just DoubleSpend -> do
                                status status400
                                json (UserError "Input already spent")
                            Just InvalidOutput -> do
                                status status400
                                json (UserError "Invalid previous output")
                            Just OrphanTx -> do
                                status status400
                                json (UserError "Unknown previous output")
                            Just OverSpend -> do
                                status status400
                                json (UserError "Spends excessive amount")
                            Just NoPeers -> do
                                status status500
                                json (UserError "No peers connected")
                            Nothing -> json (SentTx (txHash tx))
            get "/dbstats" $
                RocksDB.getProperty db RocksDB.Stats >>= text . cs . fromJust
            notFound $ raise NotFound
    runStore conf mgr b db =
        runStderrLoggingT $ do
            s <- Inbox <$> liftIO newTQueueIO
            c <- Inbox <$> liftIO newTQueueIO
            let cfg =
                    StoreConfig
                    { storeConfBlocks = b
                    , storeConfSupervisor = s
                    , storeConfChain = c
                    , storeConfManager = mgr
                    , storeConfListener = const (return ())
                    , storeConfMaxPeers = 20
                    , storeConfInitPeers =
                          map
                              (second (fromMaybe defaultPort))
                              (configPeers conf)
                    , storeConfDiscover = configDiscover conf
                    , storeConfDB = db
                    }
            store cfg
