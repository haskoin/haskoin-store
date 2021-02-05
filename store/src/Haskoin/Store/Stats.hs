module Haskoin.Store.Stats where

import           Data.Text                       (Text)
import           System.Metrics                  (Store, newStore)
import           System.Remote.Monitoring.Statsd (defaultStatsdOptions,
                                                  forkStatsd, prefix)
import           UnliftIO                        (MonadIO, liftIO)

withStats :: MonadIO m => Text -> (Store -> m a) -> m a
withStats pfx go = do
    store <- liftIO newStore
    _statsd <- liftIO $ forkStatsd defaultStatsdOptions{prefix = pfx} store
    go store
