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
import           Data.List               (intercalate)
import           Data.Maybe              (fromMaybe)
import           Data.String.Conversions (cs)
import           Data.Version            (showVersion)
import           Database.Redis          (defaultConnectInfo, parseConnectInfo,
                                          withCheckedConnect)
import           Haskoin                 (Network (..), allNets, bch,
                                          bchRegTest, bchTest, btc, btcRegTest,
                                          btcTest)
import           Haskoin.Node            (Host, Port)
import           Haskoin.Store           (CacheReaderConfig (..),
                                          MaxLimits (..), StoreConfig (..),
                                          Timeouts (..), WebConfig (..),
                                          connectRocksDB, runWeb, withStore)
import           NQE                     (inboxToMailbox, newInbox,
                                          withPublisher)
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
import           UnliftIO                (MonadUnliftIO, liftIO, withRunInIO)
import           UnliftIO.Directory      (createDirectoryIfMissing,
                                          getAppUserDataDirectory)

data Config = Config
    { configDir       :: !FilePath
    , configPort      :: !Int
    , configNetwork   :: !Network
    , configDiscover  :: !Bool
    , configPeers     :: ![(Host, Maybe Port)]
    , configVersion   :: !Bool
    , configDebug     :: !Bool
    , configReqLog    :: !Bool
    , configMaxLimits :: !MaxLimits
    , configTimeouts  :: !Timeouts
    , configRedis     :: !Bool
    , configRedisURL  :: !String
    }

defPort :: Int
defPort = 3000

defNetwork :: Network
defNetwork = btc

netNames :: String
netNames = intercalate "|" (map getNetworkName allNets)

defMaxLimits :: MaxLimits
defMaxLimits =
    MaxLimits
        { maxLimitCount = 20000
        , maxLimitFull = 5000
        , maxLimitOffset = 50000
        , maxLimitDefault = 2000
        , maxLimitGap = 32
        }

defTimeouts :: Timeouts
defTimeouts = Timeouts {blockTimeout = 7200, txTimeout = 600}

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
        value (maxLimitCount defMaxLimits)
    maxLimitFull <-
        option auto $
        metavar "MAXLIMITFULL" <> long "maxfull" <>
        help "Max limit for full listings (0 for no limit)" <>
        showDefault <>
        value (maxLimitFull defMaxLimits)
    maxLimitOffset <-
        option auto $
        metavar "MAXOFFSET" <> long "maxoffset" <>
        help "Max offset (0 for no limit)" <>
        showDefault <>
        value (maxLimitOffset defMaxLimits)
    maxLimitDefault <-
        option auto $
        metavar "LIMITDEFAULT" <> long "deflimit" <>
        help "Default limit (0 for max)" <>
        showDefault <>
        value (maxLimitDefault defMaxLimits)
    maxLimitGap <-
        option auto $
        metavar "MAXGAP" <> long "maxgap" <> help "Max gap for xpub queries" <>
        showDefault <>
        value (maxLimitGap defMaxLimits)
    blockTimeout <-
        option auto $
        metavar "BLOCKSECONDS" <> long "blocktimeout" <>
        help "Last block mined timeout (0 for infinite)" <>
        showDefault <>
        value (blockTimeout defTimeouts)
    txTimeout <-
        option auto $
        metavar "TXSECONDS" <> long "txtimeout" <>
        help "Last transaction broadcast timeout (0 for infinite)" <>
        showDefault <>
        value (txTimeout defTimeouts)
    configRedis <-
        switch $ long "cache" <> help "Redis cache for extended public keys"
    configRedisURL <-
        strOption $
        metavar "URL" <> long "redis" <> help "URL for Redis cache" <> value ""
    pure
        Config
            { configMaxLimits = MaxLimits {..}
            , configTimeouts = Timeouts {..}
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

run :: MonadUnliftIO m => Config -> m ()
run Config { configPort = port
           , configNetwork = net
           , configDiscover = disc
           , configPeers = peers
           , configDir = db_dir
           , configDebug = deb
           , configMaxLimits = limits
           , configReqLog = reqlog
           , configTimeouts = tos
           , configRedis = redis
           , configRedisURL = redisurl
           } =
    runStderrLoggingT . filterLogger l $ do
        $(logInfoS) "Main" $
            "Creating working directory if not found: " <> cs wd
        createDirectoryIfMissing True wd
        db <- connectRocksDB (maxLimitGap limits) (wd </> "db")
        withcache $ \maybecache ->
            withPublisher $ \pub ->
                let scfg =
                        StoreConfig
                            { storeConfMaxPeers = 20
                            , storeConfInitPeers =
                                  map
                                      (second (fromMaybe (getDefaultPort net)))
                                      peers
                            , storeConfDiscover = disc
                            , storeConfDB = db
                            , storeConfNetwork = net
                            , storeConfPublisher = pub
                            , storeConfCache = maybecache
                            , storeConfGap = maxLimitGap limits
                            }
                 in withStore scfg $ \st ->
                        let crcfg =
                                case maybecache of
                                    Nothing -> Nothing
                                    Just (conn, mbox) ->
                                        Just
                                            CacheReaderConfig
                                                { cacheReaderConn = conn
                                                , cacheReaderWriter =
                                                      inboxToMailbox mbox
                                                , cacheReaderGap =
                                                      maxLimitGap limits
                                                }
                            wcfg =
                                WebConfig
                                    { webPort = port
                                    , webNetwork = net
                                    , webDB = db
                                    , webPublisher = pub
                                    , webStore = st
                                    , webMaxLimits = limits
                                    , webReqLog = reqlog
                                    , webTimeouts = tos
                                    , webCache = crcfg
                                    }
                         in runWeb wcfg
  where
    withcache f =
        if redis
            then do
                conninfo <-
                    if null redisurl
                        then return defaultConnectInfo
                        else case parseConnectInfo redisurl of
                                 Left e -> error e
                                 Right r -> return r
                cachembox <- newInbox
                withRunInIO $ \r ->
                    withCheckedConnect conninfo $ \conn ->
                        r $ f (Just (conn, cachembox))
            else f Nothing
    l _ lvl
        | deb = True
        | otherwise = LevelInfo <= lvl
    wd = db_dir </> getNetworkName net
