{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE ApplicativeDo #-}

module Haskoin.Store.Stats
  ( StatDist,
    withStats,
    createStatDist,
    addStatTime,
    addClientError,
    addServerError,
    addStatQuery,
    addStatItems,
  )
where

import Control.Concurrent.STM.TQueue
  ( TQueue,
    flushTQueue,
    writeTQueue,
  )
import Control.Foldl qualified as L
import Control.Monad (forever)
import Data.Function (on)
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HashMap
import Data.Int (Int64)
import Data.List (sort, sortBy, sortOn)
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..), comparing)
import Data.String.Conversions (cs)
import Data.Text (Text)
import System.Metrics
  ( Store,
    Value (..),
    newStore,
    registerGcMetrics,
    registerGroup,
    sampleAll,
  )
import System.Remote.Monitoring.Statsd
  ( defaultStatsdOptions,
    flushInterval,
    forkStatsd,
    host,
    port,
    prefix,
  )
import UnliftIO
  ( MonadIO,
    TVar,
    atomically,
    liftIO,
    modifyTVar,
    newTQueueIO,
    newTVarIO,
    readTVar,
    withAsync,
  )
import UnliftIO.Concurrent (threadDelay)

withStats :: (MonadIO m) => Text -> Int -> Text -> (Store -> m a) -> m a
withStats h p pfx go = do
  store <- liftIO newStore
  _statsd <-
    liftIO $
      forkStatsd
        defaultStatsdOptions
          { prefix = pfx,
            host = h,
            port = p
          }
        store
  liftIO $ registerGcMetrics store
  go store

data StatData = StatData
  { times :: ![Int64],
    queries :: !Int64,
    items :: !Int64,
    clientErrors :: !Int64,
    serverErrors :: !Int64
  }

data StatDist = StatDist
  { queue :: !(TQueue Int64),
    queries :: !(TVar Int64),
    items :: !(TVar Int64),
    clientErrors :: !(TVar Int64),
    serverErrors :: !(TVar Int64)
  }

createStatDist :: (MonadIO m) => Text -> Store -> m StatDist
createStatDist t store = liftIO $ do
  queue <- newTQueueIO
  queries <- newTVarIO 0
  items <- newTVarIO 0
  clientErrors <- newTVarIO 0
  serverErrors <- newTVarIO 0
  let metrics =
        HashMap.fromList
          [ ( t <> ".request_count",
              Counter . (.queries)
            ),
            ( t <> ".item_count",
              Counter . (.items)
            ),
            ( t <> ".client_errors",
              Counter . (.clientErrors)
            ),
            ( t <> ".server_errors",
              Counter . (.serverErrors)
            ),
            ( t <> ".mean_ms",
              Gauge . mean . (.times)
            ),
            ( t <> ".avg_ms",
              Gauge . avg . (.times)
            ),
            ( t <> ".max_ms",
              Gauge . maxi . (.times)
            ),
            ( t <> ".min_ms",
              Gauge . mini . (.times)
            ),
            ( t <> ".var_ms",
              Gauge . var . (.times)
            )
          ]
  let sd = StatDist {..}
  registerGroup metrics (flush sd) store
  return sd

toDouble :: Int64 -> Double
toDouble = fromIntegral

addStatTime :: (MonadIO m) => StatDist -> Int64 -> m ()
addStatTime q =
  liftIO . atomically . writeTQueue q.queue

addStatQuery :: (MonadIO m) => StatDist -> m ()
addStatQuery q =
  liftIO . atomically $ modifyTVar q.queries (+ 1)

addStatItems :: (MonadIO m) => StatDist -> Int64 -> m ()
addStatItems q =
  liftIO . atomically . modifyTVar q.items . (+)

addClientError :: (MonadIO m) => StatDist -> m ()
addClientError q =
  liftIO . atomically $ modifyTVar q.clientErrors (+ 1)

addServerError :: (MonadIO m) => StatDist -> m ()
addServerError q =
  liftIO . atomically $ modifyTVar q.serverErrors (+ 1)

flush :: (MonadIO m) => StatDist -> m StatData
flush StatDist {..} = atomically $ do
  times <- flushTQueue queue
  queries <- readTVar queries
  items <- readTVar items
  clientErrors <- readTVar clientErrors
  serverErrors <- readTVar serverErrors
  return $ StatData {..}

average :: (Fractional a) => L.Fold a a
average = do
  s <- L.sum
  l <- L.genericLength
  return $ if l > 0 then s / fromIntegral l else 0

avg :: [Int64] -> Int64
avg = round . L.fold average . map toDouble

mean :: [Int64] -> Int64
mean = round . L.fold L.mean . map toDouble

maxi :: [Int64] -> Int64
maxi = fromMaybe 0 . L.fold L.maximum

mini :: [Int64] -> Int64
mini = fromMaybe 0 . L.fold L.minimum

var :: [Int64] -> Int64
var = round . L.fold L.variance . map toDouble