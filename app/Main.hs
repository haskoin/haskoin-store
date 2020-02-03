{-# LANGUAGE ApplicativeDo     #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE MultiWayIf        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Main where

import           Conduit
import           Control.Arrow
import           Control.Exception       ()
import           Control.Monad
import           Control.Monad.Logger
import           Data.Bits
import           Data.List
import           Data.Maybe
import           Data.String.Conversions
import           Data.Version
import           Database.RocksDB        as R
import           Haskoin
import           Haskoin.Node
import           Haskoin.Store
import           NQE
import           Options.Applicative
import           Paths_haskoin_store     as P
import           System.Exit
import           System.FilePath
import           System.IO.Unsafe
import           Text.Read               (readMaybe)
import           UnliftIO
import           UnliftIO.Directory

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
        { maxLimitCount = 10000
        , maxLimitFull = 500
        , maxLimitOffset = 50000
        , maxLimitDefault = 100
        , maxLimitGap = 20
        }

defTimeouts :: Timeouts
defTimeouts = Timeouts {blockTimeout = 7200, txTimeout = 600}

config :: Parser Config
config = do
    configDir <-
        option str $
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
        metavar "MAXOFFSET" <> long "maxoffset" <> help "Max offset (0 for no limit)" <>
        showDefault <>
        value (maxLimitOffset defMaxLimits)
    maxLimitDefault <-
        option auto $
        metavar "LIMITDEFAULT" <> long "deflimit" <> help "Default limit (0 for max)" <>
        showDefault <>
        value (maxLimitDefault defMaxLimits)
    maxLimitGap <-
        option auto $
        metavar "GAP" <> long "gap" <> help "Extended public key gap" <>
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
           } =
    runStderrLoggingT . filterLogger l $ do
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
                        , storeConfListen = (`sendSTM` pub) . Event
                        }
             in withStore scfg $ \st ->
                    let wcfg =
                            WebConfig
                                { webPort = port
                                , webNetwork = net
                                , webDB = db
                                , webPublisher = pub
                                , webStore = st
                                , webMaxLimits = limits
                                , webReqLog = reqlog
                                , webTimeouts = tos
                                }
                     in runWeb wcfg
  where
    l _ lvl
        | deb = True
        | otherwise = LevelInfo <= lvl
    wd = db_dir </> getNetworkName net
