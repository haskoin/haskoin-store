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
        $(logInfoS) "Main" "Populating cache..."
        cache <- newCache defaultReadOptions db
        (us, bs) <- atomically $ cacheSize cache
        $(logInfoS) "Main" $ "Addresses: " <> cs (show bs)
        $(logInfoS) "Main" $ "UTXO: " <> cs (show us)
        withPublisher $ \pub -> do
            let scfg =
                    StoreConfig
                        { storeConfMaxPeers = 20
                        , storeConfInitPeers =
                              map
                                  (second
                                       (fromMaybe
                                            (getDefaultPort (configNetwork conf))))
                                  (configPeers conf)
                        , storeConfDiscover = configDiscover conf
                        , storeConfDB = db
                        , storeConfNetwork = configNetwork conf
                        , storeConfListen = (`sendSTM` pub) . Event
                        , storeConfCache = cache
                        }
            withStore scfg $ \st -> do
                let wcfg =
                        WebConfig
                            { webPort = configPort conf
                            , webNetwork = configNetwork conf
                            , webDB = db
                            , webCache = cache
                            , webPublisher = pub
                            , webStore = st
                            }
                runWeb wcfg
  where
    opts =
        info (helper <*> config) $
        fullDesc <> progDesc "Blockchain store and API" <>
        Options.Applicative.header
            ("haskoin-store version " <> showVersion P.version)
