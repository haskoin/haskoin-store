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
import           Data.Word                  (Word32)
import           Database.RocksDB           as R
import           Haskoin
import           Haskoin.Node
import           Haskoin.Store
import           Network.HTTP.Types
import           NQE
import           Options.Applicative
import           Paths_haskoin_store        as P
import           System.Exit
import           System.FilePath
import           System.IO.Unsafe
import           Text.Read                  (readMaybe)
import           UnliftIO
import           UnliftIO.Directory
import           Web.Scotty.Trans

data Config = Config
    { configDir      :: !FilePath
    , configPort     :: !Int
    , configNetwork  :: !Network
    , configDiscover :: !Bool
    , configPeers    :: ![(Host, Maybe Port)]
    , configVersion  :: !Bool
    , configCache    :: !FilePath
    , configDebug    :: !Bool
    , configMaxCount :: !Word32
    }

defPort :: Int
defPort = 3000

defNetwork :: Network
defNetwork = btc

netNames :: String
netNames = intercalate "|" (map getNetworkName allNets)

defMaxCount :: Word32
defMaxCount = 10000

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
    configDiscover <- switch $ long "auto" <> short 'a' <> help "Peer discovery"
    configPeers <-
        many . option (eitherReader peerReader) $
        metavar "HOST" <> long "peer" <> short 'p' <>
        help "Network peer (as many as required)"
    configCache <-
        option str $
        long "cache" <> short 'c' <> help "Memory mapped disk for cache" <>
        value ""
    configVersion <- switch $ long "version" <> short 'v' <> help "Show version"
    configDebug <- switch $ long "debug" <> help "Show debug messages"
    configMaxCount <-
        option auto $
        metavar "INT" <> long "max" <> short 'x' <>
        help "Max offset or length (0 for no limit)" <>
        showDefault <>
        value defMaxCount
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
main = do
    conf <- liftIO (execParser opts)
    when (configVersion conf) . liftIO $ do
        putStrLn $ showVersion P.version
        exitSuccess
    when (null (configPeers conf) && not (configDiscover conf)) . liftIO $
        die "ERROR: Specify peers to connect or enable peer discovery."
    run conf
  where
    opts =
        info (helper <*> config) $
        fullDesc <> progDesc "Blockchain store and API" <>
        Options.Applicative.header
            ("haskoin-store version " <> showVersion P.version)

cacheDir :: Network -> FilePath -> Maybe FilePath
cacheDir net "" = Nothing
cacheDir net ch = Just (ch </> getNetworkName net </> "cache")

run :: MonadUnliftIO m => Config -> m ()
run Config { configPort = port
           , configNetwork = net
           , configDiscover = disc
           , configPeers = peers
           , configCache = cache_path
           , configDir = db_dir
           , configDebug = deb
           , configMaxCount = max_count
           } =
    runStderrLoggingT . filterLogger l . flip finally clear $ do
        $(logInfoS) "Main" $
            "Creating working directory if not found: " <> cs wd
        createDirectoryIfMissing True wd
        db <-
            do dbh <-
                   open
                       (wd </> "db")
                       R.defaultOptions
                           { createIfMissing = True
                           , compression = SnappyCompression
                           , maxOpenFiles = -1
                           , writeBufferSize = 2 `shift` 30
                           }
               return BlockDB {blockDB = dbh, blockDBopts = defaultReadOptions}
        cdb <-
            case cd of
                Nothing -> return Nothing
                Just ch -> do
                    $(logInfoS) "Main" $ "Deleting cache directory: " <> cs ch
                    removePathForcibly ch
                    $(logInfoS) "Main" $ "Creating cache directory: " <> cs ch
                    createDirectoryIfMissing True ch
                    dbh <- open ch R.defaultOptions {createIfMissing = True}
                    return $
                        Just
                            BlockDB
                                { blockDB = dbh
                                , blockDBopts = defaultReadOptions
                                }
        $(logInfoS) "Main" "Populating cache (if active)..."
        ldb <- newLayeredDB db cdb
        $(logInfoS) "Main" "Finished populating cache"
        withPublisher $ \pub ->
            let scfg =
                    StoreConfig
                        { storeConfMaxPeers = 20
                        , storeConfInitPeers =
                              map
                                  (second (fromMaybe (getDefaultPort net)))
                                  peers
                        , storeConfDiscover = disc
                        , storeConfDB = ldb
                        , storeConfNetwork = net
                        , storeConfListen = (`sendSTM` pub) . Event
                        }
             in withStore scfg $ \str ->
                    let wcfg =
                            WebConfig
                                { webPort = port
                                , webNetwork = net
                                , webDB = ldb
                                , webPublisher = pub
                                , webStore = str
                                , webMaxCount = max_count
                                }
                     in runWeb wcfg
  where
    l _ lvl
        | deb = True
        | otherwise = LevelInfo <= lvl
    clear =
        case cd of
            Nothing -> return ()
            Just ch -> do
                $(logInfoS) "Main" $ "Deleting cache directory: " <> cs ch
                removePathForcibly ch
    wd = db_dir </> getNetworkName net
    cd =
        case cache_path of
            "" -> Nothing
            ch -> Just (ch </> getNetworkName net </> "cache")
