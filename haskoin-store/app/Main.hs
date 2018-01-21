{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
import           Control.Concurrent.NQE
import           Control.Exception
import           Control.Monad.Logger
import           Control.Monad.Trans
import           Data.Aeson                  hiding (json)
import           Data.String.Conversions
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Crypto
import           Network.Haskoin.Store
import           Network.Haskoin.Transaction
import           Network.HTTP.Types
import           System.Environment
import           Web.Scotty.Trans

type StoreM = ActionT Except IO

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

defHandler :: Except -> StoreM ()
defHandler ServerError = json ServerError
defHandler NotFound    = status status404 >> json NotFound
defHandler e           = json e

maybeJSON :: ToJSON a => Maybe a -> StoreM ()
maybeJSON Nothing  = raise NotFound
maybeJSON (Just x) = json x

main :: IO ()
main = do
    setTestnet
    env <- getEnvironment
    let port = maybe 3000 read (lookup "PORT" env)
    b <- Inbox <$> liftIO newTQueueIO
    s <- Inbox <$> liftIO newTQueueIO
    supervisor KillAll s [runWeb port b, runStore b]
  where
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
    runStore b =
        runStderrLoggingT $ do
            s <- Inbox <$> liftIO newTQueueIO
            c <- Inbox <$> liftIO newTQueueIO
            let cfg =
                    StoreConfig
                    { storeConfDir = ".haskoin-store"
                    , storeConfBlocks = b
                    , storeConfSupervisor = s
                    , storeConfChain = c
                    , storeConfListener = const $ return ()
                    , storeConfMaxPeers = 1
                    , storeConfInitPeers = [("localhost", defaultPort)]
                    , storeConfNoNewPeers = True
                    , storeConfCacheNo = 1000000
                    , storeConfBlockNo = 500
                    }
            store cfg
