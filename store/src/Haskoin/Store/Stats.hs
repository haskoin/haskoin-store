module Haskoin.Store.Stats where

import           Data.Text                       (Text)
import           System.Metrics                  (Store, newStore,
                                                  registerGcMetrics)
import           System.Remote.Monitoring.Statsd (defaultStatsdOptions,
                                                  forkStatsd, host, prefix)
import           UnliftIO                        (MonadIO, liftIO)

withStats :: MonadIO m => Text -> Text -> (Store -> m a) -> m a
withStats host pfx go = do
    store <- liftIO newStore
    _statsd <- liftIO $
        forkStatsd defaultStatsdOptions{ prefix = pfx
                                       , host = host
                                       } store
    liftIO $ registerGcMetrics store
    go store
