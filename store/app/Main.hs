{-# LANGUAGE ApplicativeDo     #-}
{-# LANGUAGE CPP               #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections     #-}
module Main where

import           Control.Applicative       ((<|>))
import           Control.Arrow             (second)
import           Control.Monad             (when)
import           Control.Monad.Logger      (LogLevel (..), filterLogger,
                                            logInfoS, runStderrLoggingT)
import           Control.Monad.Trans.Maybe (MaybeT (..), runMaybeT)
import           Data.Char                 (toLower)
import           Data.Default              (Default (..))
import           Data.List                 (intercalate)
import           Data.Maybe                (fromMaybe)
import           Data.String.Conversions   (cs)
import qualified Data.Text                 as T
import           Data.Word                 (Word32)
import           Haskoin                   (Network (..), allNets, bch,
                                            bchRegTest, bchTest, btc,
                                            btcRegTest, btcTest, eitherToMaybe)
import           Haskoin.Node              (withConnection)
import           Haskoin.Store             (StoreConfig (..), WebConfig (..),
                                            WebLimits (..), WebTimeouts (..),
                                            runWeb, withStore)
import           Haskoin.Store.Stats       (withStats)
import           Options.Applicative       (Parser, auto, eitherReader,
                                            execParser, flag, fullDesc, header,
                                            help, helper, info, long, many,
                                            metavar, option, progDesc, short,
                                            showDefault, strOption, switch,
                                            value)
import           System.Exit               (exitSuccess)
import           System.FilePath           ((</>))
import           System.IO.Unsafe          (unsafePerformIO)
import           Text.Read                 (readMaybe)
import           UnliftIO                  (MonadIO)
import           UnliftIO.Directory        (createDirectoryIfMissing,
                                            getAppUserDataDirectory)
import           UnliftIO.Environment      (lookupEnv)

version :: String
#ifdef CURRENT_PACKAGE_VERSION
version = CURRENT_PACKAGE_VERSION
#else
version = "Unavailable"
#endif

data Config = Config
    { configDir             :: !FilePath
    , configHost            :: !String
    , configPort            :: !Int
    , configNetwork         :: !Network
    , configAsert           :: !Word32
    , configDiscover        :: !Bool
    , configPeers           :: ![(String, Maybe Int)]
    , configVersion         :: !Bool
    , configDebug           :: !Bool
    , configMaxPending      :: !Int
    , configWebLimits       :: !WebLimits
    , configWebTimeouts     :: !WebTimeouts
    , configRedis           :: !Bool
    , configRedisURL        :: !String
    , configRedisMin        :: !Int
    , configRedisMax        :: !Integer
    , configWipeMempool     :: !Bool
    , configNoMempool       :: !Bool
    , configPeerTimeout     :: !Int
    , configPeerMaxLife     :: !Int
    , configMaxPeers        :: !Int
    , configMaxDiff         :: !Int
    , configCacheRefresh    :: !Int
    , configCacheRetryDelay :: !Int
    , configNumTxId         :: !Bool
    , configStatsd          :: !Bool
    , configStatsdHost      :: !String
    , configStatsdPort      :: !Int
    , configStatsdPrefix    :: !String
    }

instance Default Config where
    def = Config { configDir             = defDirectory
                 , configHost            = defHost
                 , configPort            = defPort
                 , configNetwork         = defNetwork
                 , configAsert           = defAsert
                 , configDiscover        = defDiscover
                 , configPeers           = defPeers
                 , configVersion         = False
                 , configDebug           = defDebug
                 , configMaxPending      = defMaxPending
                 , configWebLimits       = defWebLimits
                 , configWebTimeouts     = defWebTimeouts
                 , configRedis           = defRedis
                 , configRedisURL        = defRedisURL
                 , configRedisMin        = defRedisMin
                 , configRedisMax        = defRedisMax
                 , configWipeMempool     = defWipeMempool
                 , configNoMempool       = defNoMempool
                 , configPeerTimeout     = defPeerTimeout
                 , configPeerMaxLife     = defPeerMaxLife
                 , configMaxPeers        = defMaxPeers
                 , configMaxDiff         = defMaxDiff
                 , configCacheRefresh    = defCacheRefresh
                 , configCacheRetryDelay = defCacheRetryDelay
                 , configNumTxId         = defNumTxId
                 , configStatsd          = defStatsd
                 , configStatsdHost      = defStatsdHost
                 , configStatsdPort      = defStatsdPort
                 , configStatsdPrefix    = defStatsdPrefix
                 }

defEnv :: MonadIO m => String -> a -> (String -> Maybe a) -> m a
defEnv e d p = do
    ms <- lookupEnv e
    return $ fromMaybe d $ p =<< ms

defCacheRefresh :: Int
defCacheRefresh = unsafePerformIO $
    defEnv "CACHE_REFRESH" 750 readMaybe
{-# NOINLINE defCacheRefresh #-}

defCacheRetryDelay :: Int
defCacheRetryDelay = unsafePerformIO $
    defEnv "CACHE_RETRY_DELAY" 100000 readMaybe
{-# NOINLINE defCacheRetryDelay #-}

defMaxPending :: Int
defMaxPending = unsafePerformIO $
    defEnv "MAX_PENDING_TXS" 100 readMaybe
{-# NOINLINE defMaxPending #-}

defMaxPeers :: Int
defMaxPeers = unsafePerformIO $
    defEnv "MAX_PEERS" 20 readMaybe
{-# NOINLINE defMaxPeers #-}

defDirectory :: FilePath
defDirectory = unsafePerformIO $ do
    d <- getAppUserDataDirectory "haskoin-store"
    defEnv "DIR" d pure
{-# NOINLINE defDirectory #-}

defHost :: String
defHost = unsafePerformIO $
    defEnv "HOST" "*" pure
{-# NOINLINE defHost #-}

defPort :: Int
defPort = unsafePerformIO $
    defEnv "PORT" 3000 readMaybe
{-# NOINLINE defPort #-}

defNetwork :: Network
defNetwork = unsafePerformIO $
    defEnv "NET" bch (eitherToMaybe . networkReader)
{-# NOINLINE defNetwork #-}

defAsert :: Word32
defAsert = unsafePerformIO $
    defEnv "ASERT" 0 readMaybe
{-# NOINLINE defAsert #-}

defRedisMin :: Int
defRedisMin = unsafePerformIO $
    defEnv "CACHE_MIN" 100 readMaybe
{-# NOINLINE defRedisMin #-}

defRedis :: Bool
defRedis = unsafePerformIO $
    defEnv "CACHE" False parseBool
{-# NOINLINE defRedis #-}

defDiscover :: Bool
defDiscover = unsafePerformIO $
    defEnv "DISCOVER" False parseBool
{-# NOINLINE defDiscover #-}

defPeers :: [(String, Maybe Int)]
defPeers = unsafePerformIO $
    defEnv "PEER" [] (mapM (eitherToMaybe . peerReader) . words)
{-# NOINLINE defPeers #-}

defDebug :: Bool
defDebug = unsafePerformIO $
    defEnv "DEBUG" False parseBool
{-# NOINLINE defDebug #-}

defNumTxId :: Bool
defNumTxId = unsafePerformIO $
    defEnv "NUMTXID" False parseBool
{-# NOINLINE defNumTxId #-}

defWebLimits :: WebLimits
defWebLimits = unsafePerformIO $ do
    max_limit  <- defEnv "MAX_LIMIT" (maxLimitCount def) readMaybe
    max_full   <- defEnv "MAX_FULL" (maxLimitFull def) readMaybe
    max_offset <- defEnv "MAX_OFFSET" (maxLimitOffset def) readMaybe
    def_limit  <- defEnv "DEF_LIMIT" (maxLimitDefault def) readMaybe
    max_gap    <- defEnv "MAX_GAP" (maxLimitGap def) readMaybe
    init_gap   <- defEnv "INIT_GAP" (maxLimitInitialGap def) readMaybe
    return WebLimits { maxLimitCount = max_limit
                     , maxLimitFull = max_full
                     , maxLimitOffset = max_offset
                     , maxLimitDefault = def_limit
                     , maxLimitGap = max_gap
                     , maxLimitInitialGap = init_gap
                     }
{-# NOINLINE defWebLimits #-}

defWebTimeouts :: WebTimeouts
defWebTimeouts = unsafePerformIO $ do
    block_timeout <- defEnv "BLOCK_TIMEOUT" (blockTimeout def) readMaybe
    tx_timeout    <- defEnv "TX_TIMEOUT" (txTimeout def) readMaybe
    return WebTimeouts { txTimeout = tx_timeout
                       , blockTimeout = block_timeout
                       }
{-# NOINLINE defWebTimeouts #-}

defWipeMempool :: Bool
defWipeMempool = unsafePerformIO $
    defEnv "WIPE_MEMPOOL" False parseBool
{-# NOINLINE defWipeMempool #-}

defNoMempool :: Bool
defNoMempool = unsafePerformIO $
    defEnv "NO_MEMPOOL" False parseBool
{-# NOINLINE defNoMempool #-}

defRedisURL :: String
defRedisURL = unsafePerformIO $
    defEnv "REDIS" "" pure
{-# NOINLINE defRedisURL #-}

defRedisMax :: Integer
defRedisMax = unsafePerformIO $
    defEnv "CACHE_KEYS" 100000000 readMaybe
{-# NOINLINE defRedisMax #-}

defPeerTimeout :: Int
defPeerTimeout = unsafePerformIO $
    defEnv "PEER_TIMEOUT" 120 readMaybe
{-# NOINLINE defPeerTimeout #-}

defPeerMaxLife :: Int
defPeerMaxLife = unsafePerformIO $
    defEnv "PEER_MAX_LIFE" (48 * 3600) readMaybe
{-# NOINLINE defPeerMaxLife #-}

defMaxDiff :: Int
defMaxDiff = unsafePerformIO $
    defEnv "MAX_DIFF" 2 readMaybe
{-# NOINLINE defMaxDiff #-}

defStatsd :: Bool
defStatsd = unsafePerformIO $
    defEnv "STATSD" False parseBool
{-# NOINLINE defStatsd #-}

defStatsdHost :: String
defStatsdHost = unsafePerformIO $
    defEnv "STATSD_HOST" "localhost" pure
{-# NOINLINE defStatsdHost #-}

defStatsdPort :: Int
defStatsdPort = unsafePerformIO $
    defEnv "STATSD_PORT" 8125 readMaybe
{-# NOINLINE defStatsdPort #-}

defStatsdPrefix :: String
defStatsdPrefix =
    unsafePerformIO $
    runMaybeT go >>= \case
        Nothing -> return "haskoin_store"
        Just x -> return x
  where
    go = prefix <|> nomad
    prefix = MaybeT $ lookupEnv "STATSD_PREFIX"
    nomad = do
        task <- MaybeT $ lookupEnv "NOMAD_TASK_NAME"
        service <- MaybeT $ lookupEnv "NOMAD_ALLOC_INDEX"
        return $ task <> "." <> service
{-# NOINLINE defStatsdPrefix #-}

netNames :: String
netNames = intercalate "|" (map getNetworkName allNets)

parseBool :: String -> Maybe Bool
parseBool str = case map toLower str of
    "yes"   -> Just True
    "true"  -> Just True
    "on"    -> Just True
    "1"     -> Just True
    "no"    -> Just False
    "false" -> Just False
    "off"   -> Just False
    "0"     -> Just False
    _       -> Nothing

config :: Parser Config
config = do
    configDir <-
        strOption $
        metavar "PATH"
        <> long "dir"
        <> short 'd'
        <> help "Data directory"
        <> showDefault
        <> value (configDir def)
    configHost <-
        strOption $
        metavar "HOST"
        <> long "host"
        <> help "Host to bind"
        <> showDefault
        <> value (configHost def)
    configPort <-
        option auto $
        metavar "INT"
        <> long "port"
        <> help "REST API listening port"
        <> showDefault
        <> value (configPort def)
    configNetwork <-
        option (eitherReader networkReader) $
        metavar netNames
        <> long "net"
        <> short 'n'
        <> help "Network to connect to"
        <> showDefault
        <> value (configNetwork def)
    configAsert <-
        option auto $
        metavar "TIME"
        <> long "asert"
        <> help "ASERT (axon) activation time"
        <> value (configAsert def)
    configDiscover <-
        flag (configDiscover def) True $
        long "discover"
        <> help "Peer discovery"
    configPeers <-
        fmap (mappend defPeers) $
        many $
        option (eitherReader peerReader) $
        metavar "HOST"
        <> long "peer"
        <> short 'p'
        <> help "Network peer (as many as required)"
    configMaxPeers <-
        option auto $
        metavar "INT"
        <> long "max-peers"
        <> help "Do not connect to more than this many peers"
        <> showDefault
        <> value (configMaxPeers def)
    configVersion <-
        switch $
        long "version"
        <> short 'v'
        <> help "Show version"
    configDebug <-
        flag (configDebug def) True $
        long "debug"
        <> help "Show debug messages"
    maxLimitCount <-
        option auto $
        metavar "INT"
        <> long "max-limit"
        <> help "Hard limit for simple listings (0 = inf)"
        <> showDefault
        <> value (maxLimitCount (configWebLimits def))
    maxLimitFull <-
        option auto $
        metavar "INT"
        <> long "max-full"
        <> help "Hard limit for full listings (0 = inf)"
        <> showDefault
        <> value (maxLimitFull (configWebLimits def))
    maxLimitOffset <-
        option auto $
        metavar "INT"
        <> long "max-offset"
        <> help "Hard limit for offsets (0 = inf)"
        <> showDefault
        <> value (maxLimitOffset (configWebLimits def))
    maxLimitDefault <-
        option auto $
        metavar "INT"
        <> long "def-limit"
        <> help "Soft default limit (0 = inf)"
        <> showDefault
        <> value (maxLimitDefault (configWebLimits def))
    maxLimitGap <-
        option auto $
        metavar "INT"
        <> long "max-gap"
        <> help "Max gap for xpub queries"
        <> showDefault
        <> value (maxLimitGap (configWebLimits def))
    maxLimitInitialGap <-
        option auto $
        metavar "INT"
        <> long "init-gap"
        <> help "Max gap for empty xpub"
        <> showDefault
        <> value (maxLimitInitialGap (configWebLimits def))
    blockTimeout <-
        option auto $
        metavar "SECONDS"
        <> long "block-timeout"
        <> help "Last block mined health timeout (0 = inf)"
        <> showDefault
        <> value (blockTimeout (configWebTimeouts def))
    txTimeout <-
        option auto $
        metavar "SECONDS"
        <> long "tx-timeout"
        <> help "Last tx recived health timeout (0 = inf)"
        <> showDefault
        <> value (txTimeout (configWebTimeouts def))
    configPeerTimeout <-
        option auto $
        metavar "SECONDS"
        <> long "peer-timeout"
        <> help "Unresponsive peer timeout"
        <> showDefault
        <> value (configPeerTimeout def)
    configPeerMaxLife <-
        option auto $
        metavar "SECONDS"
        <> long "peer-max-life"
        <> help "Disconnect peers older than this"
        <> showDefault
        <> value (configPeerMaxLife def)
    configMaxPending <-
        option auto $
        metavar "INT"
        <> long "max-pending-txs"
        <> help "Maximum pending txs to fail health check"
        <> showDefault
        <> value (configMaxPending def)
    configRedis <-
        flag (configRedis def) True $
        long "cache"
        <> help "Redis cache for extended public keys"
    configRedisURL <-
        strOption $
        metavar "URL"
        <> long "redis"
        <> help "URL for Redis cache"
        <> value (configRedisURL def)
    configRedisMin <-
        option auto $
        metavar "INT"
        <> long "cache-min"
        <> help "Minimum used xpub addresses to cache"
        <> showDefault
        <> value (configRedisMin def)
    configRedisMax <-
        option auto $
        metavar "INT"
        <> long "cache-keys"
        <> help "Maximum number of keys in Redis xpub cache"
        <> showDefault
        <> value (configRedisMax def)
    configCacheRefresh <-
        option auto $
        metavar "MILLISECONDS"
        <> long "cache-refresh"
        <> help "Refresh cache this frequently"
        <> showDefault
        <> value (configCacheRefresh def)
    configCacheRetryDelay <-
        option auto $
        metavar "MICROSECONDS"
        <> long "cache-retry-delay"
        <> help "Delay to retry getting cache lock to index xpub"
        <> showDefault
        <> value (configCacheRetryDelay def)
    configNoMempool <-
        flag (configNoMempool def) True $
        long "no-mempool"
        <> help "Do not index new mempool transactions"
    configWipeMempool <-
        flag (configWipeMempool def) True $
        long "wipe-mempool"
        <> help "Wipe mempool at start"
    configMaxDiff <-
        option auto $
        metavar "INT"
        <> long "max-diff"
        <> help "Maximum difference between headers and blocks"
        <> showDefault
        <> value (configMaxDiff def)
    configNumTxId <-
        flag (configNumTxId def) True $
        long "numtxid"
        <> help "Numeric tx_index field"
    configStatsd <-
        flag (configStatsd def) True $
        long "statsd"
        <> help "Enable statsd metrics"
    configStatsdHost <-
        strOption $
        metavar "HOST"
        <> long "statsd-host"
        <> help "Host to send statsd metrics"
        <> showDefault
        <> value (configStatsdHost def)
    configStatsdPort <-
        option auto $
        metavar "PORT"
        <> long "statsd-port"
        <> help "Port to send statsd metrics"
        <> showDefault
        <> value (configStatsdPort def)
    configStatsdPrefix <-
        strOption $
        metavar "PREFIX"
        <> long "statsd-prefix"
        <> help "Prefix for statsd metrics"
        <> showDefault
        <> value (configStatsdPrefix def)
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
        putStrLn version
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
            ("haskoin-store version " <> version)

run :: Config -> IO ()
run Config { configHost = host
           , configPort = port
           , configNetwork = net
           , configAsert = asert
           , configDiscover = disc
           , configPeers = peers
           , configDir = db_dir
           , configDebug = deb
           , configMaxPending = pend
           , configWebLimits = limits
           , configWebTimeouts = tos
           , configRedis = redis
           , configRedisURL = redisurl
           , configRedisMin = cachemin
           , configRedisMax = redismax
           , configWipeMempool = wipemempool
           , configPeerTimeout = peertimeout
           , configPeerMaxLife = peerlife
           , configMaxPeers = maxpeers
           , configMaxDiff = maxdiff
           , configNoMempool = nomem
           , configCacheRefresh = crefresh
           , configCacheRetryDelay = cretrydelay
           , configNumTxId = numtxid
           , configStatsd = statsd
           , configStatsdHost = statsdhost
           , configStatsdPort = statsdport
           , configStatsdPrefix = statsdpfx
           } =
    runStderrLoggingT . filterLogger l . with_stats $ \stats -> do
        $(logInfoS) "Main" $
            "Creating working directory if not found: " <> cs wd
        createDirectoryIfMissing True wd
        let scfg =
                StoreConfig
                    { storeConfMaxPeers = maxpeers
                    , storeConfInitPeers =
                          map (second (fromMaybe (getDefaultPort net))) peers
                    , storeConfDiscover = disc
                    , storeConfDB = wd </> "db"
                    , storeConfNetwork = net'
                    , storeConfCache =
                          if redis
                              then Just redisurl
                              else Nothing
                    , storeConfGap = maxLimitGap limits
                    , storeConfInitialGap = maxLimitInitialGap limits
                    , storeConfCacheMin = cachemin
                    , storeConfMaxKeys = redismax
                    , storeConfWipeMempool = wipemempool
                    , storeConfNoMempool = nomem
                    , storeConfPeerTimeout = fromIntegral peertimeout
                    , storeConfPeerMaxLife = fromIntegral peerlife
                    , storeConfConnect = withConnection
                    , storeConfCacheRefresh = crefresh
                    , storeConfCacheRetryDelay = cretrydelay
                    , storeConfStats = stats
                    }
        withStore scfg $ \st ->
            runWeb
                WebConfig
                    { webHost = host
                    , webPort = port
                    , webStore = st
                    , webMaxLimits = limits
                    , webTimeouts = tos
                    , webMaxPending = pend
                    , webVersion = version
                    , webMaxDiff = maxdiff
                    , webNoMempool = nomem
                    , webNumTxId = numtxid
                    , webStats = stats
                    }
  where
    with_stats go
        | statsd = do
            $(logInfoS) "Main" $
                "Sending stats to " <> T.pack statsdhost <>
                ":" <> cs (show statsdport) <>
                " with prefix: " <> T.pack statsdpfx
            withStats
                (T.pack statsdhost)
                statsdport
                (T.pack statsdpfx)
                (go . Just)
        | otherwise = go Nothing
    net' | asert == 0 = net
         | otherwise = net { getAsertActivationTime = Just asert }
    l _ lvl
        | deb = True
        | otherwise = LevelInfo <= lvl
    wd = db_dir </> getNetworkName net'
