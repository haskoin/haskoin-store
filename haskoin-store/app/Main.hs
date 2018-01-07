{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
import           Control.Concurrent.NQE
import           Control.Exception
import           Control.Monad.Logger
import           Control.Monad.Trans
import           Data.String.Conversions
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Store.Block
import           Network.Haskoin.Store.Json
import           Network.Haskoin.Store.Store
import           System.Environment
import           System.IO.Temp
import           Web.Scotty

instance Parsable BlockHash where
    parseParam =
        maybe (Left "Could not decode block hash") Right . hexToBlockHash . cs

main :: IO ()
main = do
    setTestnet
    env <- getEnvironment
    let port = maybe 3000 read (lookup "PORT" env)
    sup <- Inbox <$> liftIO newTQueueIO
    c <- Inbox <$> liftIO newTQueueIO
    b <- Inbox <$> liftIO newTQueueIO
    withAsync (run sup c b) $ \a ->
        (`finally` stopSupervisor sup) $ do
            link a
            scotty port $ do
                get "/block/hash/:block" $ do
                    hash <- param "block"
                    m <- hash `blockGet` b
                    case m of
                        Nothing -> undefined
                        Just StoredBlock {..} ->
                            json $
                            encodeJsonBlock
                                storedBlockHeader
                                storedBlockHeight
                                Nothing
                                storedBlockTxs
  where
    run sup c b =
        runStderrLoggingT $
        withSystemTempDirectory "haskoin-store-" $ \w ->
            runStderrLoggingT $ do
                let cfg =
                        StoreConfig
                        { storeConfDir = w
                        , storeConfBlocks = b
                        , storeConfSupervisor = sup
                        , storeConfChain = c
                        , storeConfListener = const $ return ()
                        , storeConfMaxPeers = 20
                        , storeConfInitPeers = []
                        , storeConfNoNewPeers = False
                        }
                store cfg
