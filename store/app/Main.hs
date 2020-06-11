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
import           Haskoin.Node            (withConnection)
import           Haskoin.Store           (StoreConfig (..), WebConfig (..),
                                          WebLimits (..), WebTimeouts (..),
                                          runWeb, withStore)
import           Options.Applicative     (Parser, auto, eitherReader,
                                          execParser, fullDesc, header, help,
                                          helper, info, long, many, metavar,
                                          option, progDesc, short, showDefault,
                                          strOption, switch, value)
import           Paths_haskoin_store     as P
import           System.Exit             (exitSuccess)
import           System.FilePath         ((</>))
import           System.IO.Unsafe        (unsafePerformIO)
import           Text.Read               (readMaybe)
import           UnliftIO.Directory      (createDirectoryIfMissing,
                                          getAppUserDataDirectory)

data Config = Config
    { configDir         :: !FilePath
    , configHost        :: !String
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
    , configPeerTimeout :: !Int
    , configPeerTooOld  :: !Int
    }

myDirectory :: FilePath
myDirectory = unsafePerformIO $ getAppUserDataDirectory "haskoin-store"
{-# NOINLINE myDirectory #-}

defPort :: Int
defPort = 3000

defHost :: String
defHost = "0.0.0.0"

defNetwork :: Network
defNetwork = bch

netNames :: String
netNames = intercalate "|" (map getNetworkName allNets)

defRedisMin :: Int
defRedisMin = 100

defRedisMax :: Integer
defRedisMax = 100 * 1000 * 1000

defPeerTimeout :: Int
defPeerTimeout = 120

defPeerTooOld :: Int
defPeerTooOld = 48 * 3600

config :: Parser Config
config = do
    configDir <-
        strOption $
        metavar "WORKDIR" <> long "dir" <> short 'd' <> help "Data directory" <>
        showDefault <>
        value myDirectory
    configHost <-
        strOption $
        metavar "HOST" <> long "host" <> help "Listen on network interface" <>
        showDefault <>
        value defHost
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
    configReqLog <- switch $ long "req-log" <> help "HTTP request logging"
    maxLimitCount <-
        option auto $
        metavar "MAXLIMIT" <> long "max-limit" <>
        help "Max limit for listings (0 for no limit)" <>
        showDefault <>
        value (maxLimitCount def)
    maxLimitFull <-
        option auto $
        metavar "MAXLIMITFULL" <> long "max-full" <>
        help "Max limit for full listings (0 for no limit)" <>
        showDefault <>
        value (maxLimitFull def)
    maxLimitOffset <-
        option auto $
        metavar "MAXOFFSET" <> long "max-offset" <>
        help "Max offset (0 for no limit)" <>
        showDefault <>
        value (maxLimitOffset def)
    maxLimitDefault <-
        option auto $
        metavar "LIMITDEFAULT" <> long "def-limit" <>
        help "Default limit (0 for max)" <>
        showDefault <>
        value (maxLimitDefault def)
    maxLimitGap <-
        option auto $
        metavar "MAXGAP" <> long "max-gap" <> help "Max gap for xpub queries" <>
        showDefault <>
        value (maxLimitGap def)
    maxLimitInitialGap <-
        option auto $
        metavar "INITGAP" <> long "init-gap" <> help "Max gap for empty xpub" <>
        showDefault <>
        value (maxLimitInitialGap def)
    blockTimeout <-
        option auto $
        metavar "BLOCKSECONDS" <> long "block-timeout" <>
        help "Last block mined timeout (0 for infinite)" <>
        showDefault <>
        value (blockTimeout def)
    txTimeout <-
        option auto $
        metavar "TXSECONDS" <> long "tx-timeout" <>
        help "Last transaction broadcast timeout (0 for infinite)" <>
        showDefault <>
        value (txTimeout def)
    configPeerTimeout <-
        option auto $
        metavar "TIMEOUT" <> long "peer-timeout" <>
        help "Disconnect if peer doesn't send message for this many seconds" <>
        showDefault <>
        value defPeerTimeout
    configPeerTooOld <-
        option auto $
        metavar "TIMEOUT" <> long "peer-old" <>
        help "Disconnect if peer has been connected for this many seconds" <>
        showDefault <>
        value defPeerTooOld
    configRedis <-
        switch $ long "cache" <> help "Redis cache for extended public keys"
    configRedisURL <-
        strOption $
        metavar "URL" <> long "redis" <> help "URL for Redis cache" <> value ""
    configRedisMin <-
        option auto $
        metavar "MINADDRS" <> long "cache-min" <>
        help "Minimum used xpub addresses to cache" <>
        showDefault <>
        value defRedisMin
    configRedisMax <-
        option auto $
        metavar "MAXKEYS" <> long "cache-keys" <>
        help "Maximum number of keys in Redis xpub cache" <>
        showDefault <>
        value defRedisMax
    configWipeMempool <-
        switch $ long "wipe-mempool" <> help "Wipe mempool when starting"
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

main :: IO ()
main = do
    conf <- execParser opts
    when (configVersion conf) $ do
        putStrLn $ showVersion P.version
        exitSuccess
    if null (configPeers conf) && not (configDiscover conf)
        then run conf {configDiscover = True}
        else run conf
  where
    opts =
        info (helper <*> config) $
        fullDesc <>
        progDesc "Bitcoin (BCH & BTC) block chain index with HTTP API" <>
        Options.Applicative.header
            ("haskoin-store version " <> showVersion P.version)

run :: Config -> IO ()
run Config { configHost = host
           , configPort = port
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
           , configPeerTimeout = peertimeout
           , configPeerTooOld = peerold
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
                    , storeConfPeerTimeout = peertimeout
                    , storeConfPeerTooOld = peerold
                    , storeConfConnect = withConnection
                    }
        withStore scfg $ \st ->
            runWeb
                WebConfig
                    { webHost = host
                    , webPort = port
                    , webStore = st
                    , webMaxLimits = limits
                    , webReqLog = reqlog
                    , webWebTimeouts = tos
                    }
  where
    l _ lvl
        | deb = True
        | otherwise = LevelInfo <= lvl
    wd = db_dir </> getNetworkName net
