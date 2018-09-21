{-# LANGUAGE ApplicativeDo     #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
import           Conduit
import           Control.Arrow
import           Control.Exception
import           Control.Monad
import           Control.Monad.Logger
import           Data.Aeson              (ToJSON (..), Value (..), encode,
                                          object, (.=))
import           Data.Bits
import           Data.ByteString.Builder (lazyByteString)
import           Data.Default
import           Data.Foldable
import           Data.Function
import           Data.List
import           Data.Maybe
import           Data.String.Conversions
import qualified Data.Text               as T
import           Data.Version
import           Database.RocksDB        hiding (get)
import           Haskoin
import           Haskoin.Node
import           Haskoin.Store
import           Network.HTTP.Types
import           NQE
import           Options.Applicative
import           Paths_haskoin_store     as P
import           System.Directory
import           System.Exit
import           System.FilePath
import           System.IO.Unsafe
import           Text.Read               (readMaybe)
import           UnliftIO
import           Web.Scotty.Trans

data OptConfig = OptConfig
    { optConfigDir      :: !(Maybe FilePath)
    , optConfigMemDB    :: !(Maybe FilePath)
    , optConfigPort     :: !(Maybe Int)
    , optConfigNetwork  :: !(Maybe Network)
    , optConfigDiscover :: !(Maybe Bool)
    , optConfigPeers    :: !(Maybe [(Host, Maybe Port)])
    , optConfigMaxReqs  :: !(Maybe Int)
    , optConfigVersion  :: !Bool
    }

data Config = Config
    { configDir      :: !FilePath
    , configMemDB    :: !(Maybe FilePath)
    , configPort     :: !Int
    , configNetwork  :: !Network
    , configDiscover :: !Bool
    , configPeers    :: ![(Host, Maybe Port)]
    , configMaxReqs  :: !Int
    }

maxUriArgs :: Int
maxUriArgs = 500

maxPubSubQueue :: Int
maxPubSubQueue = 10000

defMaxReqs :: Int
defMaxReqs = 10000

defPort :: Int
defPort = 3000

defNetwork :: Network
defNetwork = btc

defDiscovery :: Bool
defDiscovery = False

defPeers :: [(Host, Maybe Port)]
defPeers = []

optToConfig :: OptConfig -> Config
optToConfig OptConfig {..} =
    Config
    { configDir = fromMaybe myDirectory optConfigDir
    , configMemDB = optConfigMemDB
    , configPort = fromMaybe defPort optConfigPort
    , configNetwork = fromMaybe defNetwork optConfigNetwork
    , configDiscover = fromMaybe defDiscovery optConfigDiscover
    , configPeers = fromMaybe defPeers optConfigPeers
    , configMaxReqs = fromMaybe defMaxReqs optConfigMaxReqs
    }

instance Parsable BlockHash where
    parseParam =
        maybe (Left "could not decode block hash") Right . hexToBlockHash . cs

instance Parsable TxHash where
    parseParam =
        maybe (Left "could not decode tx hash") Right . hexToTxHash . cs

data Except
    = ThingNotFound
    | ServerError
    | BadRequest
    | UserError String
    | OutOfBounds
    | StringError String
    deriving (Show, Eq)

instance Exception Except

instance ScottyError Except where
    stringError = StringError
    showError = cs . show

instance ToJSON Except where
    toJSON ThingNotFound = object ["error" .= String "not found"]
    toJSON BadRequest = object ["error" .= String "bad request"]
    toJSON ServerError = object ["error" .= String "you made me kill a unicorn"]
    toJSON OutOfBounds = object ["error" .= String "too many elements requested"]
    toJSON (StringError _) = object ["error" .= String "you made me kill a unicorn"]
    toJSON (UserError s) = object ["error" .= s]

data JsonEvent
    = JsonEventTx TxHash
    | JsonEventBlock BlockHash
    deriving (Eq, Show)

instance ToJSON JsonEvent where
    toJSON (JsonEventTx tx_hash) =
        object ["type" .= String "tx", "id" .= tx_hash]
    toJSON (JsonEventBlock block_hash) =
        object ["type" .= String "block", "id" .= block_hash]

netNames :: String
netNames = intercalate "|" $ map getNetworkName allNets

config :: Parser OptConfig
config = do
    optConfigDir <-
        optional . option str $
        metavar "DIR" <> long "dir" <> short 'd' <>
        help ("Data directory (default: " <> myDirectory <> ")")
    optConfigMemDB <-
        optional . option str $
        metavar "UTXO" <> long "utxo" <> short 'u' <>
        help "Memory directory for UTXO"
    optConfigPort <-
        optional . option auto $
        metavar "PORT" <> long "port" <> short 'p' <>
        help ("Listening port (default: " <> show defPort <> ")")
    optConfigNetwork <-
        optional . option (eitherReader networkReader) $
        metavar "NETWORK" <> long "net" <> short 'n' <>
        help ("Network: " <> netNames <> " (default: " <> net <> ")")
    optConfigDiscover <-
        optional . switch $
        long "auto" <> short 'a' <> help "Enable automatic peer discovery"
    optConfigPeers <-
        optional . option (eitherReader peerReader) $
        metavar "PEERS" <> long "peers" <> short 'e' <>
        help "Network peers (i.e. \"localhost,peer.example.com:8333\")"
    optConfigMaxReqs <-
        optional . option auto $
        metavar "MAX" <> long "max" <> short 'x' <>
        help ("Maximum returned entries (default:" <> show defMaxReqs <> ")")
    optConfigVersion <-
        switch $ long "version" <> short 'v' <> help "Show version"
    return OptConfig {..}
  where
    net = getNetworkName defNetwork

networkReader :: String -> Either String Network
networkReader s
    | s == getNetworkName btc = Right btc
    | s == getNetworkName btcTest = Right btcTest
    | s == getNetworkName btcRegTest = Right btcRegTest
    | s == getNetworkName bch = Right bch
    | s == getNetworkName bchTest = Right bchTest
    | s == getNetworkName bchRegTest = Right bchRegTest
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

defHandler :: Monad m => Except -> ActionT Except m ()
defHandler ServerError   = json ServerError
defHandler OutOfBounds   = status status413 >> json OutOfBounds
defHandler ThingNotFound = status status404 >> json ThingNotFound
defHandler BadRequest    = status status400 >> json BadRequest
defHandler (UserError s) = status status400 >> json (UserError s)
defHandler e             = status status400 >> json e

maybeJSON :: (Monad m, ToJSON a) => Maybe a -> ActionT Except m ()
maybeJSON Nothing  = raise ThingNotFound
maybeJSON (Just x) = json x

myDirectory :: FilePath
myDirectory = unsafePerformIO $ getAppUserDataDirectory "haskoin-store"
{-# NOINLINE myDirectory #-}

main :: IO ()
main =
    runStderrLoggingT $ do
        opt <- liftIO (execParser opts)
        when (optConfigVersion opt) . liftIO $ do
            putStrLn $ showVersion P.version
            exitSuccess
        let conf = optToConfig opt
        when (null (configPeers conf) && not (configDiscover conf)) . liftIO $
            die "Specify: -a | -e PEER,..."
        let net = configNetwork conf
        let wdir = configDir conf </> getNetworkName net
        liftIO $ createDirectoryIfMissing True wdir
        db <-
            open
                (wdir </> "blocks")
                defaultOptions
                    { createIfMissing = True
                    , compression = SnappyCompression
                    , maxOpenFiles = -1
                    , writeBufferSize = 2 `shift` 30
                    }
        mudb <-
            case configMemDB conf of
                Nothing -> return Nothing
                Just d ->
                    Just <$>
                    open
                        d
                        defaultOptions
                            { createIfMissing = True
                            , compression = SnappyCompression
                            , maxOpenFiles = -1
                            , writeBufferSize = 2 `shift` 30
                            }
        withStore (store_conf conf db mudb) $ \st -> runWeb conf st db
  where
    store_conf conf db mudb =
        StoreConfig
            { storeConfMaxPeers = 20
            , storeConfInitPeers =
                  map
                      (second (fromMaybe (getDefaultPort (configNetwork conf))))
                      (configPeers conf)
            , storeConfDiscover = configDiscover conf
            , storeConfDB = db
            , storeConfUnspentDB = mudb
            , storeConfNetwork = configNetwork conf
            }
    opts =
        info (helper <*> config) $
        fullDesc <> progDesc "Blockchain store and API" <>
        Options.Applicative.header
            ("haskoin-store version " <> showVersion P.version)

testLength :: Monad m => Int -> ActionT Except m ()
testLength l = when (l <= 0 || l > maxUriArgs) (raise OutOfBounds)

runWeb ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Config
    -> Store
    -> DB
    -> m ()
runWeb conf st db = do
    l <- askLoggerIO
    scottyT (configPort conf) (runner l) $ do
        defaultHandler defHandler
        get "/block/best" $ do
            res <-
                withSnapshot db $ \s ->
                    getBestBlock db def {useSnapshot = Just s}
            json res
        get "/block/:block" $ do
            block <- param "block"
            res <-
                withSnapshot db $ \s ->
                    getBlock block db def {useSnapshot = Just s}
            maybeJSON res
        get "/block/height/:height" $ do
            height <- param "height"
            res <-
                withSnapshot db $ \s ->
                    getBlocksAtHeight height db def {useSnapshot = Just s}
            json res
        get "/block/heights" $ do
            heights <- param "heights"
            testLength (length (heights :: [BlockHeight]))
            res <-
                withSnapshot db $ \s ->
                    let opts = def {useSnapshot = Just s}
                     in mapM (\h -> getBlocksAtHeight h db opts) heights
            json res
        get "/blocks" $ do
            blocks <- param "blocks"
            testLength (length blocks)
            res <-
                withSnapshot db $ \s ->
                    getBlocks blocks db def {useSnapshot = Just s}
            json res
        get "/mempool" $ do
            res <-
                withSnapshot db $ \s -> getMempool db def {useSnapshot = Just s}
            json res
        get "/transaction/:txid" $ do
            txid <- param "txid"
            res <-
                withSnapshot db $ \s ->
                    getTx net txid db def {useSnapshot = Just s}
            maybeJSON res
        get "/transactions" $ do
            txids <- param "txids"
            testLength (length (txids :: [TxHash]))
            res <-
                withSnapshot db $ \s ->
                    let opts = def {useSnapshot = Just s}
                     in mapM (\t -> getTx net t db opts) txids
            json res
        get "/address/:address/transactions" $ do
            address <- parse_address
            height <- parse_height
            x <- parse_max
            res <-
                withSnapshot db $ \s ->
                    let opts = def {useSnapshot = Just s}
                     in addrTxsMax db opts x height address
            json res
        get "/address/transactions" $ do
            addresses <- parse_addresses
            height <- parse_height
            x <- parse_max
            res <-
                withSnapshot db $ \s ->
                    let opts = def {useSnapshot = Just s}
                     in addrsTxsMax db opts x height addresses
            json res
        get "/address/:address/unspent" $ do
            address <- parse_address
            height <- parse_height
            x <- parse_max
            res <-
                withSnapshot db $ \s ->
                    let opts = def {useSnapshot = Just s}
                     in addrUnspentMax db opts x height address
            json res
        get "/address/unspent" $ do
            addresses <- parse_addresses
            height <- parse_height
            x <- parse_max
            res <-
                withSnapshot db $ \s ->
                    let opts = def {useSnapshot = Just s}
                     in addrsUnspentMax db opts x height addresses
            json res
        get "/address/:address/balance" $ do
            address <- parse_address
            res <-
                withSnapshot db $ \s ->
                    let opts = def {useSnapshot = Just s}
                     in getBalance address db opts
            json res
        get "/address/balances" $ do
            addresses <- parse_addresses
            res <-
                withSnapshot db $ \s ->
                    let opts = def {useSnapshot = Just s}
                     in mapM (\a -> getBalance a db opts) addresses
            json res
        post "/transactions" $ do
            NewTx tx <- jsonData
            lift (publishTx net st db tx) >>= \case
                Left PublishTimeout -> do
                    status status500
                    json (UserError (show PublishTimeout))
                Left e -> do
                    status status400
                    json (UserError (show e))
                Right j -> json j
        get "/dbstats" $ getProperty db Stats >>= text . cs . fromJust
        get "/events" $ do
            setHeader "Content-Type" "application/x-json-stream"
            stream $ \io flush ->
                withPubSub (storePublisher st) (newTBQueueIO maxPubSubQueue) $ \sub ->
                    forever $
                    flush >> receive sub >>= \case
                        BestBlock block_hash -> do
                            let bs = encode (JsonEventBlock block_hash) <> "\n"
                            io (lazyByteString bs)
                        MempoolNew tx_hash -> do
                            let bs = encode (JsonEventTx tx_hash) <> "\n"
                            io (lazyByteString bs)
                        _ -> return ()
        get "/peers" $ getPeersInformation (storeManager st) >>= json
        notFound $ raise ThingNotFound
  where
    parse_address = do
        address <- param "address"
        case stringToAddr net address of
            Nothing -> next
            Just a  -> return a
    parse_addresses = do
        addresses <- param "addresses"
        let as = mapMaybe (stringToAddr net) addresses
        if length as == length addresses
            then testLength (length as) >> return as
            else next
    parse_max = do
        x <- param "max" `rescue` const (return (configMaxReqs conf))
        when (x < 1 || x > configMaxReqs conf) (raise OutOfBounds)
        return x
    parse_height = (Just <$> param "height") `rescue` const (return Nothing)
    net = configNetwork conf
    runner f l = do
        u <- askUnliftIO
        unliftIO u (runLoggingT l f)

addrTxsMax ::
       MonadUnliftIO m
    => DB
    -> ReadOptions
    -> Int
    -> Maybe BlockHeight
    -> Address
    -> m [AddrTx]
addrTxsMax db opts c h a = addrsTxsMax db opts c h [a]

addrsTxsMax ::
       MonadUnliftIO m
    => DB
    -> ReadOptions
    -> Int
    -> Maybe BlockHeight
    -> [Address]
    -> m [AddrTx]
addrsTxsMax db opts c h addrs =
    runResourceT . runConduit $
    mergeSourcesBy (flip compare) conds .| takeC c .| sinkList
  where
    conds = map (\a -> getAddrTxs a h db opts) addrs

addrUnspentMax ::
       MonadUnliftIO m
    => DB
    -> ReadOptions
    -> Int
    -> Maybe BlockHeight
    -> Address
    -> m [AddrOutput]
addrUnspentMax db opts c h a = addrsUnspentMax db opts c h [a]

addrsUnspentMax ::
       MonadUnliftIO m
    => DB
    -> ReadOptions
    -> Int
    -> Maybe BlockHeight
    -> [Address]
    -> m [AddrOutput]
addrsUnspentMax db opts c h addrs =
    runResourceT . runConduit $
    mergeSourcesBy (flip compare) conds .| takeC c .| sinkList
  where
    conds = map (\a -> getUnspent a h db opts) addrs

-- Snatched from:
-- https://github.com/cblp/conduit-merge/blob/master/src/Data/Conduit/Merge.hs
mergeSourcesBy ::
       (Foldable f, Monad m)
    => (a -> a -> Ordering)
    -> f (ConduitT () a m ())
    -> ConduitT i a m ()
mergeSourcesBy f = mergeSealed . fmap sealConduitT . toList
  where
    mergeSealed sources = do
        prefetchedSources <- lift $ traverse ($$++ await) sources
        go [(a, s) | (s, Just a) <- prefetchedSources]
    go [] = pure ()
    go sources = do
        let (a, src1):sources1 = sortBy (f `on` fst) sources
        yield a
        (src2, mb) <- lift $ src1 $$++ await
        let sources2 =
                case mb of
                    Nothing -> sources1
                    Just b  -> (b, src2) : sources1
        go sources2
