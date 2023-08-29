{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}

module Haskoin.Store.Stats (withStats) where

import Data.Text (Text)
import System.Metrics
  ( Store,
    newStore,
    registerGcMetrics,
  )
import System.Remote.Monitoring.Statsd
  ( defaultStatsdOptions,
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