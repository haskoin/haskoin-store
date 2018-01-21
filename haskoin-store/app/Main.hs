{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
import           Control.Concurrent.NQE
import           Control.Exception
import           Control.Monad.Logger
import           Control.Monad.Trans
import           Data.Aeson                  (ToJSON (..), Value (..), object,
                                              (.=))
import           Data.Maybe
import           Data.Monoid
import           Data.String.Conversions
import           Data.Word
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Crypto
import           Network.Haskoin.Store
import           Network.Haskoin.Transaction
import           Network.HTTP.Types
import           Options.Applicative
import           System.Directory
import           System.FilePath
import           Web.Scotty.Trans

type StoreM = ActionT Except IO

data Config = Config
    { configDir     :: !(Maybe FilePath)
    , configCache   :: !(Maybe Word32)
    , configBlocks  :: !(Maybe Word32)
    , configPort    :: !(Maybe Int)
    , configNetwork :: !(Maybe String)
    } deriving (Show, Eq)

instance Parsable BlockHash where
    parseParam =
        maybe (Left "Could not decode block hash") Right . hexToBlockHash . cs

instance Parsable TxHash where
    parseParam =
        maybe (Left "Could not decode tx hash") Right . hexToTxHash . cs

instance Parsable Address where
    parseParam =
        maybe (Left "Could not decode address") Right . base58ToAddr . cs

data Except = NotFound | ServerError | StringError String deriving (Show, Eq)

instance Exception Except

instance ScottyError Except where
    stringError = StringError
    showError = cs . show

instance ToJSON Except where
    toJSON NotFound = object ["error" .= String "Not Found"]
    toJSON ServerError = object ["error" .= String "You made me kill a unicorn"]
    toJSON (StringError s) = object ["error" .= s]

config :: Parser Config
config =
    Config <$>
    optional
        (option
             str
             (metavar "DIR" <> long "dir" <> short 'd' <>
              help
                  "Directory to store blockchain data (default: system-dependent)")) <*>
    optional
        (option
             auto
             (metavar "COUNT" <> long "cache" <> short 'c' <>
              help
                  "Number of entries in UTXO cache for faster synchronisation (default: 250'000)")) <*>
    optional
        (option
             auto
             (metavar "BLOCKS" <> long "blocks" <> short 'b' <>
              help
                  "Number of blocks to download per request to peer (default: 200)")) <*>
    optional
        (option
             auto
             (metavar "PORT" <> long "port" <> short 'p' <>
              help "Port number (default: 3000)")) <*>
    optional
        (option
             str
             (metavar "NETWORK" <> long "network" <> short 'n' <>
              help
                  "Network to use: \"bitcoin\", \"testnet\", \"regtest\" (default: \"bitcoin\")"))

defHandler :: Except -> StoreM ()
defHandler ServerError = json ServerError
defHandler NotFound    = status status404 >> json NotFound
defHandler e           = json e

maybeJSON :: ToJSON a => Maybe a -> StoreM ()
maybeJSON Nothing  = raise NotFound
maybeJSON (Just x) = json x

main :: IO ()
main =
    execParser opts >>= \Config {..} -> do
        case configNetwork of
            Nothing -> setProdnet
            Just "testnet" -> setTestnet
            Just "regtest" -> setRegtest
            Just "bitcoin" -> setProdnet
            Just _ ->
                error
                    "NETWORK environment variable must be \"bitcoin\", \"testnet\" or \"regtest\""
        let port = fromMaybe 3000 configPort
            blocks = fromMaybe 200 configBlocks
            cache = fromMaybe 250000 configCache
        dir <- maybe (getAppUserDataDirectory "haskoin-store") return configDir
        b <- Inbox <$> liftIO newTQueueIO
        s <- Inbox <$> liftIO newTQueueIO
        supervisor KillAll s [runWeb port b, runStore cache blocks dir b]
  where
    opts =
        info
            (helper <*> config)
            (fullDesc <> progDesc "Blockchain store and API" <>
             Options.Applicative.header "haskoin-store: a blockchain indexer")
    runWeb port b =
        scottyT port id $ do
            defaultHandler defHandler
            get "/block/best" $ blockGetBest b >>= json
            get "/block/hash/:block" $ do
                block <- param "block"
                block `blockGet` b >>= maybeJSON
            get "/block/height/:height" $ do
                height <- param "height"
                height `blockGetHeight` b >>= maybeJSON
            get "/transaction/:txid" $ do
                txid <- param "txid"
                txid `blockGetTx` b >>= maybeJSON
            get "/address/transactions/:address" $ do
                address <- param "address"
                address `blockGetAddrTxs` b >>= json
            get "/address/unspent/:address" $ do
                address <- param "address"
                address `blockGetAddrUnspent` b >>= json
            get "/address/balance/:address" $ do
                address <- param "address"
                address `blockGetAddrBalance` b >>= maybeJSON
            notFound $ raise NotFound
    runStore cache blocks dir b =
        runStderrLoggingT $ do
            s <- Inbox <$> liftIO newTQueueIO
            c <- Inbox <$> liftIO newTQueueIO
            let wdir = dir </> networkName
            liftIO $ createDirectoryIfMissing True wdir
            let cfg =
                    StoreConfig
                    { storeConfDir = wdir
                    , storeConfBlocks = b
                    , storeConfSupervisor = s
                    , storeConfChain = c
                    , storeConfListener = const (return ())
                    , storeConfMaxPeers = 20
                    , storeConfInitPeers = []
                    , storeConfNoNewPeers = False
                    , storeConfCacheNo = cache
                    , storeConfBlockNo = blocks
                    }
            store cfg
