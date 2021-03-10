{-# LANGUAGE OverloadedStrings #-}
module Haskoin.Store.Stats
    ( StatDist
    , withStats
    , createStatDist
    , addStatTime
    , addStatItems
    , addClientError
    , addServerError
    , addStatQuery
    ) where

import           Control.Concurrent.STM.TQueue   (TQueue, flushTQueue,
                                                  writeTQueue)
import qualified Control.Foldl                   as L
import           Control.Monad                   (forever)
import           Data.Function                   (on)
import           Data.HashMap.Strict             (HashMap)
import qualified Data.HashMap.Strict             as HashMap
import           Data.Int                        (Int64)
import           Data.List                       (sort, sortBy)
import           Data.Maybe                      (fromMaybe)
import           Data.Ord                        (Down (..), comparing)
import           Data.String.Conversions         (cs)
import           Data.Text                       (Text)
import           System.Metrics                  (Store, Value (..), newStore,
                                                  registerGcMetrics,
                                                  registerGroup, sampleAll)
import           System.Remote.Monitoring.Statsd (defaultStatsdOptions,
                                                  flushInterval, forkStatsd,
                                                  host, port, prefix)
import           UnliftIO                        (MonadIO, TVar, atomically,
                                                  liftIO, modifyTVar,
                                                  newTQueueIO, newTVarIO,
                                                  readTVar, withAsync)
import           UnliftIO.Concurrent             (threadDelay)

withStats :: MonadIO m => Text -> Int -> Text -> (Store -> m a) -> m a
withStats h p pfx go = do
    store <- liftIO newStore
    _statsd <- liftIO $
        forkStatsd
        defaultStatsdOptions
            { prefix = pfx
            , host = h
            , port = p
            } store
    liftIO $ registerGcMetrics store
    go store

data StatData =
    StatData
    {
        statTimes        :: ![Int64],
        statItems        :: !Int64,
        statQueries      :: !Int64,
        statClientErrors :: !Int64,
        statServerErrors :: !Int64
    }

data StatDist =
    StatDist
    {
        distQueue        :: !(TQueue Int64),
        distItems        :: !(TVar Int64),
        distQueries      :: !(TVar Int64),
        distClientErrors :: !(TVar Int64),
        distServerErrors :: !(TVar Int64)
    }

createStatDist :: MonadIO m => Text -> Store -> m StatDist
createStatDist t store = liftIO $ do
    q <- newTQueueIO
    items <- newTVarIO 0
    queries <- newTVarIO 0
    client_errors <- newTVarIO 0
    server_errors <- newTVarIO 0
    let metrics = HashMap.fromList
            [ (t <> ".query_count",   Counter . statQueries)
            , (t <> ".item_count",    Counter . statItems)
            , (t <> ".errors.client", Counter . statClientErrors)
            , (t <> ".errors.server", Counter . statServerErrors)
            , (t <> ".mean_ms",       Gauge . mean . statTimes)
            , (t <> ".avg_ms",        Gauge . avg . statTimes)
            , (t <> ".max_ms",        Gauge . maxi . statTimes)
            , (t <> ".min_ms",        Gauge . mini . statTimes)
            , (t <> ".p90max_ms",     Gauge . p90max . statTimes)
            , (t <> ".p90min_ms",     Gauge . p90min . statTimes)
            , (t <> ".p90avg_ms",     Gauge . p90avg . statTimes)
            , (t <> ".var_ms",        Gauge . var . statTimes)
            ]
    let sd = StatDist q items queries client_errors server_errors
    registerGroup metrics (flush sd) store
    return sd

toDouble :: Int64 -> Double
toDouble = fromIntegral

addStatTime :: MonadIO m => StatDist -> Int64 -> m ()
addStatTime q =
    liftIO . atomically . writeTQueue (distQueue q)

addStatItems :: MonadIO m => StatDist -> Int64 -> m ()
addStatItems q =
    liftIO . atomically . modifyTVar (distItems q) . (+)

addStatQuery :: MonadIO m => StatDist -> m ()
addStatQuery q =
    liftIO . atomically $ modifyTVar (distQueries q) (+1)

addClientError :: MonadIO m => StatDist -> m ()
addClientError q =
    liftIO . atomically $ modifyTVar (distClientErrors q) (+1)

addServerError :: MonadIO m => StatDist -> m ()
addServerError q =
    liftIO . atomically $ modifyTVar (distServerErrors q) (+1)

flush :: MonadIO m => StatDist -> m StatData
flush (StatDist q i n c s) = atomically $ do
    ts <- flushTQueue q
    is <- readTVar i
    qs <- readTVar n
    ce <- readTVar c
    se <- readTVar s
    return $ StatData ts is qs ce se

average :: Fractional a => L.Fold a a
average = (/) <$> L.sum <*> L.genericLength

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

p90max :: [Int64] -> Int64
p90max ls =
    case chopped of
        []  -> 0
        h:_ -> h
  where
    sorted = sortBy (comparing Down) ls
    len = length sorted
    chopped = drop (length sorted * 1 `div` 10) sorted

p90min :: [Int64] -> Int64
p90min ls =
    case chopped of
        []  -> 0
        h:_ -> h
  where
    sorted = sort ls
    len = length sorted
    chopped = drop (length sorted * 1 `div` 10) sorted

p90avg :: [Int64] -> Int64
p90avg ls =
    avg chopped
  where
    sorted = sortBy (comparing Down) ls
    len = length sorted
    chopped = drop (length sorted * 1 `div` 10) sorted
