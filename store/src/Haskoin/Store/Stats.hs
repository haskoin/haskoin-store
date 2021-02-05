module Haskoin.Store.Stats where

import           System.Metrics                  (Store, newStore)
import           System.Remote.Monitoring.Statsd (defaultStatsdOptions,
                                                  forkStatsd)
import           UnliftIO                        (MonadIO, liftIO)

withStats :: MonadIO m => (Store -> m a) -> m a
withStats go = do
    store <- liftIO newStore
    _statsd <- liftIO $ forkStatsd defaultStatsdOptions store
    go store
