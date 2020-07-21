{-# LANGUAGE ApplicativeDo     #-}
{-# LANGUAGE CPP               #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections     #-}
module Main where

import           Control.Arrow           (second)
import           Control.Monad           (when)
import           Control.Monad.Logger    (LogLevel (..), filterLogger, logInfoS,
                                          runStderrLoggingT)
import           Data.Char               (toLower)
import           Data.Default            (Default (..))
import           Data.List               (intercalate)
import           Data.Maybe              (fromMaybe)
import           Data.String.Conversions (cs)
import           Haskoin                 (Network (..), allNets, bch,
                                          bchRegTest, bchTest, btc, btcRegTest,
                                          btcTest, eitherToMaybe)
import           Haskoin.Node            (withConnection)
import           Haskoin.Store           (StoreConfig (..), WebConfig (..),
                                          WebLimits (..), WebTimeouts (..),
                                          runWeb, withStore)
import           Options.Applicative     (Parser, auto, eitherReader,
                                          execParser, flag, fullDesc, header,
                                          help, helper, info, long, many,
                                          metavar, option, progDesc, short,
                                          showDefault, strOption, switch, value)
import           System.Exit             (exitSuccess)
import           System.FilePath         ((</>))
import           System.IO.Unsafe        (unsafePerformIO)
import           Text.Read               (readMaybe)
import           UnliftIO                (MonadIO)
import           UnliftIO.Directory      (createDirectoryIfMissing,
                                          getAppUserDataDirectory)
import           UnliftIO.Environment    (lookupEnv)

version :: String
#ifdef CURRENT_PACKAGE_VERSION
version = CURRENT_PACKAGE_VERSION
#else
version = "Unavailable"
#endif

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
    , configMaxPending  :: !Int
    , configWebLimits   :: !WebLimits
    , configWebTimeouts :: !WebTimeouts
    , configRedis       :: !Bool
    , configRedisURL    :: !String
    , configRedisMin    :: !Int
    , configRedisMax    :: !Integer
    , configWipeMempool :: !Bool
    , configPeerTimeout :: !Int
    , configPeerMaxLife :: !Int
    , configMaxPeers    :: !Int
    , configMaxDiff     :: !Int
    }

instance Default Config where
    def = Config { configDir         = defDirectory
                 , configHost        = defHost
                 , configPort        = defPort
                 , configNetwork     = defNetwork
                 , configDiscover    = defDiscover
                 , configPeers       = defPeers
                 , configVersion     = False
                 , configDebug       = defDebug
                 , configReqLog      = defReqLog
                 , configMaxPending  = defMaxPending
                 , configWebLimits   = defWebLimits
                 , configWebTimeouts = defWebTimeouts
                 , configRedis       = defRedis
                 , configRedisURL    = defRedisURL
                 , configRedisMin    = defRedisMin
                 , configRedisMax    = defRedisMax
                 , configWipeMempool = defWipeMempool
                 , configPeerTimeout = defPeerTimeout
                 , configPeerMaxLife = defPeerMaxLife
                 , configMaxPeers    = defMaxPeers
                 , configMaxDiff     = defMaxDiff
                 }

defEnv :: MonadIO m => String -> a -> (String -> Maybe a) -> m a
defEnv e d p = do
    ms <- lookupEnv e
    return $ fromMaybe d $ p =<< ms

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

defReqLog :: Bool
defReqLog = unsafePerformIO $
    defEnv "REQ_LOG" False parseBool
{-# NOINLINE defReqLog #-}

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
    configReqLog <-
        flag (configReqLog def) True $
        long "req-log"
        <> help "HTTP request logging"
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
    configWipeMempool <-
        flag (configWipeMempool def) True $
        long "wipe-mempool"
        <> help "Wipe mempool at start"
    configMaxDiff <-
        option auto $
        metavar "INT"
        <> long "max-diff"
        <> help "Maximum difference between headers and blocks"
        <> value (configMaxDiff def)
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
           , configDiscover = disc
           , configPeers = peers
           , configDir = db_dir
           , configDebug = deb
           , configMaxPending = pend
           , configWebLimits = limits
           , configReqLog = reqlog
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
           } =
    runStderrLoggingT . filterLogger l $ do
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
                    , storeConfPeerTimeout = fromIntegral peertimeout
                    , storeConfPeerMaxLife = fromIntegral peerlife
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
                    , webTimeouts = tos
                    , webMaxPending = pend
                    , webVersion = version
                    , webMaxDiff = maxdiff
                    }
  where
    l _ lvl
        | deb = True
        | otherwise = LevelInfo <= lvl
    wd = db_dir </> getNetworkName net
