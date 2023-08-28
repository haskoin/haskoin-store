{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NoFieldSelectors #-}

module Haskoin.Store.Stats
  ( StatDist,
    withStats,
    createStatDist,
    addStatTime,
    addClientError,
    addServerError,
  )
where

import Control.Concurrent.STM.TQueue
  ( TQueue,
    flushTQueue,
    writeTQueue,
  )
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
    createCounter,
    createDistribution,
    newStore,
    registerGcMetrics,
  )
import System.Metrics.Counter (Counter)
import System.Metrics.Counter qualified as Counter
import System.Metrics.Distribution (Distribution)
import System.Metrics.Distribution qualified as Distribution
import System.Remote.Monitoring.Statsd
  ( defaultStatsdOptions,
    flushInterval,
    forkStatsd,
    host,
    port,
    prefix,
  )
import UnliftIO (MonadIO, liftIO)

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

data StatDist = StatDist
  { dist :: Distribution,
    clientErrors :: !Counter,
    serverErrors :: !Counter
  }

createStatDist :: (MonadIO m) => Text -> Store -> m StatDist
createStatDist t store = liftIO $ do
  dist <- createDistribution (t <> "_ms") store
  clientErrors <- createCounter (t <> "_client_errors") store
  serverErrors <- createCounter (t <> "_server_errors") store
  return StatDist {..}

addStatTime :: (MonadIO m) => StatDist -> Double -> m ()
addStatTime d = liftIO . Distribution.add d.dist

addClientError :: (MonadIO m) => StatDist -> m ()
addClientError = liftIO . Counter.inc . (.clientErrors)

addServerError :: (MonadIO m) => StatDist -> m ()
addServerError = liftIO . Counter.inc . (.serverErrors)