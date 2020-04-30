{-# LANGUAGE ApplicativeDo     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections     #-}
module Main where

import           Control.Arrow           (second)
import           Control.Monad           (when)
import           Control.Monad.Logger    (LogLevel (..), filterLogger, logInfoS,
                                          runStderrLoggingT)
import           Data.Default            (def)
import           Data.List               (intercalate)
import           Data.Maybe              (fromMaybe)
import           Data.String.Conversions (cs)
import           Data.Version            (showVersion)
import           Haskoin                 (Network (..), allNets, bch,
                                          bchRegTest, bchTest, btc, btcRegTest,
                                          btcTest)
import           Haskoin.Store           (StoreConfig (..), WebConfig (..),
                                          WebLimits (..), WebTimeouts (..),
                                          runWeb, withStore)
import           Options.Applicative     (Parser, auto, eitherReader,
                                          execParser, fullDesc, header, help,
                                          helper, info, long, many, metavar,
                                          option, progDesc, short, showDefault,
                                          strOption, switch, value)
import           Paths_haskoin_store     as P
import           System.Exit             (die, exitSuccess)
import           System.FilePath         ((</>))
import           System.IO.Unsafe        (unsafePerformIO)
import           Text.Read               (readMaybe)
import           UnliftIO                (MonadUnliftIO, liftIO)
import           UnliftIO.Directory      (createDirectoryIfMissing,
                                          getAppUserDataDirectory)

data Config = Config
    { configDir         :: !FilePath
    , configPort        :: !Int
    , configNetwork     :: !Network
    , configDiscover    :: !Bool
    , configPeers       :: ![(String, Maybe Int)]
    , configVersion     :: !Bool
    , configDebug       :: !Bool
    , configReqLog      :: !Bool
    , configWebLimits   :: !WebLimits
    , configWebTimeouts :: !WebTimeouts
    , configRedis       :: !Bool
    , configRedisURL    :: !String
    , configRedisMin    :: !Int
    , configRedisMax    :: !Integer
    , configWipeMempool :: !Bool
    }

defPort :: Int
defPort = 3000

defNetwork :: Network
defNetwork = btc

netNames :: String
netNames = intercalate "|" (map getNetworkName allNets)

defRedisMin :: Int
defRedisMin = 100

defRedisMax :: Integer
defRedisMax = 100 * 1000 * 1000

config :: Parser Config
config = do
    configDir <-
        strOption $
        metavar "WORKDIR" <> long "dir" <> short 'd' <> help "Data directory" <>
        showDefault <>
        value myDirectory
    configPort <-
        option auto $
        metavar "PORT" <> long "listen" <> short 'l' <> help "Listening port" <>
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
    configVersion <- switch $ long "version" <> short 'v' <> help "Show version"
    configDebug <- switch $ long "debug" <> help "Show debug messages"
    configReqLog <- switch $ long "reqlog" <> help "HTTP request logging"
    maxLimitCount <-
        option auto $
        metavar "MAXLIMIT" <> long "maxlimit" <>
        help "Max limit for listings (0 for no limit)" <>
        showDefault <>
        value (maxLimitCount def)
    maxLimitFull <-
        option auto $
        metavar "MAXLIMITFULL" <> long "maxfull" <>
        help "Max limit for full listings (0 for no limit)" <>
        showDefault <>
        value (maxLimitFull def)
    maxLimitOffset <-
        option auto $
        metavar "MAXOFFSET" <> long "maxoffset" <>
        help "Max offset (0 for no limit)" <>
        showDefault <>
        value (maxLimitOffset def)
    maxLimitDefault <-
        option auto $
        metavar "LIMITDEFAULT" <> long "deflimit" <>
        help "Default limit (0 for max)" <>
        showDefault <>
        value (maxLimitDefault def)
    maxLimitGap <-
        option auto $
        metavar "MAXGAP" <> long "maxgap" <> help "Max gap for xpub queries" <>
        showDefault <>
        value (maxLimitGap def)
    maxLimitInitialGap <-
        option auto $
        metavar "INITGAP" <> long "initgap" <> help "Max gap for empty xpub" <>
        showDefault <>
        value (maxLimitInitialGap def)
    blockTimeout <-
        option auto $
        metavar "BLOCKSECONDS" <> long "blocktimeout" <>
        help "Last block mined timeout (0 for infinite)" <>
        showDefault <>
        value (blockTimeout def)
    txTimeout <-
        option auto $
        metavar "TXSECONDS" <> long "txtimeout" <>
        help "Last transaction broadcast timeout (0 for infinite)" <>
        showDefault <>
        value (txTimeout def)
    configRedis <-
        switch $ long "cache" <> help "Redis cache for extended public keys"
    configRedisURL <-
        strOption $
        metavar "URL" <> long "redis" <> help "URL for Redis cache" <> value ""
    configRedisMin <-
        option auto $
        metavar "MINADDRS" <> long "cachemin" <>
        help "Minimum used xpub addresses to cache" <>
        showDefault <>
        value defRedisMin
    configRedisMax <-
        option auto $
        metavar "MAXKEYS" <> long "cachekeys" <>
        help "Maximum number of keys in Redis xpub cache" <>
        showDefault <>
        value defRedisMax
    configWipeMempool <-
        switch $ long "wipemempool" <> help "Wipe mempool when starting"
    pure
        Config
            { configWebLimits = WebLimits {..}
            , configWebTimeouts = WebTimeouts {..}
            , ..
            }

networkReader :: String -> Either String Network
networkReader s
    | s == getNetworkName btc = Right btc
    | s == getNetworkName btcTest = Right btcTest
    | s == getNetworkName btcRegTest = Right btcRegTest
    | s == getNetworkName bch = Right bch
    | s == getNetworkName bchTest = Right bchTest
    | s == getNetworkName bchRegTest = Right bchRegTest
    | otherwise = Left "Network name invalid"

peerReader :: String -> Either String (String, Maybe Int)
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

run :: MonadUnliftIO m => Config -> m ()
run Config { configPort = port
           , configNetwork = net
           , configDiscover = disc
           , configPeers = peers
           , configDir = db_dir
           , configDebug = deb
           , configWebLimits = limits
           , configReqLog = reqlog
           , configWebTimeouts = tos
           , configRedis = redis
           , configRedisURL = redisurl
           , configRedisMin = cachemin
           , configRedisMax = redismax
           , configWipeMempool = wipemempool
           } =
    runStderrLoggingT . filterLogger l $ do
        $(logInfoS) "Main" $
            "Creating working directory if not found: " <> cs wd
        createDirectoryIfMissing True wd
        let scfg =
                StoreConfig
                    { storeConfMaxPeers = 20
                    , storeConfInitPeers =
                          map (second (fromMaybe (getDefaultPort net))) peers
                    , storeConfDiscover = disc
                    , storeConfDB = wd </> "db"
                    , storeConfNetwork = net
                    , storeConfCache =
                          if redis
                              then Just redisurl
                              else Nothing
                    , storeConfGap = maxLimitGap limits
                    , storeConfInitialGap = maxLimitInitialGap limits
                    , storeConfCacheMin = cachemin
                    , storeConfMaxKeys = redismax
                    , storeConfWipeMempool = wipemempool
                    }
         in withStore scfg $ \st ->
                let wcfg =
                        WebConfig
                            { webPort = port
                            , webStore = st
                            , webMaxLimits = limits
                            , webReqLog = reqlog
                            , webWebTimeouts = tos
                            }
                 in runWeb wcfg
  where
    l _ lvl
        | deb = True
        | otherwise = LevelInfo <= lvl
    wd = db_dir </> getNetworkName net
