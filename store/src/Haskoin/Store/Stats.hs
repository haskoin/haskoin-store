{-# LANGUAGE OverloadedStrings #-}
module Haskoin.Store.Stats
    ( StatDist
    , StatEntry(..)
    , withStats
    , createStatDist
    , addStatEntry
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
                                                  host, prefix)
import           UnliftIO                        (MonadIO, atomically, liftIO,
                                                  newTQueueIO, withAsync)
import           UnliftIO.Concurrent             (threadDelay)

withStats :: MonadIO m => Text -> Text -> (Store -> m a) -> m a
withStats h pfx go = do
    store <- liftIO newStore
    _statsd <- liftIO $
        forkStatsd
        defaultStatsdOptions
            { prefix = pfx
            , host = h
            , flushInterval = 10 * 1000 * 1000
            } store
    liftIO $ registerGcMetrics store
    go store

data StatEntry = StatEntry
    { statValue :: !Int64
    , statCount :: !Int64
    }
type StatDist = TQueue StatEntry

createStatDist :: MonadIO m => Text -> Store -> m StatDist
createStatDist t store = liftIO $ do
    q <- newTQueueIO
    let metrics = HashMap.fromList
            [ (t <> ".query_count",      Counter . fromIntegral . length)
            , (t <> ".item_count",       Counter . sum . map count)
            , (t <> ".per_query.mean",   Gauge . mean . map value)
            , (t <> ".per_query.avg",    Gauge . avg . map value)
            , (t <> ".per_query.max",    Gauge . maxi . map value)
            , (t <> ".per_query.min",    Gauge . mini . map value)
            , (t <> ".per_query.p90max", Gauge . p90max . map value)
            , (t <> ".per_query.90min",  Gauge . p90min . map value)
            , (t <> ".per_query.p90avg", Gauge . p90avg . map value)
            , (t <> ".per_query.var",    Gauge . var . map value)
            , (t <> ".per_item.mean",    Gauge . mean . normalize)
            , (t <> ".per_item.avg",     Gauge . avg . normalize)
            , (t <> ".per_item.max",     Gauge . maxi . normalize)
            , (t <> ".per_item.min",     Gauge . mini . normalize)
            , (t <> ".per_item.p90max",  Gauge . p90max . normalize)
            , (t <> ".per_item.p90min",  Gauge . p90min . normalize)
            , (t <> ".per_item.p90avg",  Gauge . p90avg . normalize)
            , (t <> ".per_item.var",     Gauge . var . normalize)
            ]
    registerGroup metrics (flush q) store
    return q
  where
    count = statCount
    value = statValue

toDouble :: Int64 -> Double
toDouble = fromIntegral

addStatEntry :: MonadIO m => StatDist -> StatEntry -> m ()
addStatEntry q = liftIO . atomically . writeTQueue q

flush :: MonadIO m => StatDist -> m [StatEntry]
flush = atomically . flushTQueue

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
    chopped = drop (length sorted * 9 `div` 10) sorted

p90min :: [Int64] -> Int64
p90min ls =
    case chopped of
        []  -> 0
        h:_ -> h
  where
    sorted = sort ls
    len = length sorted
    chopped = drop (length sorted * 9 `div` 10) sorted

p90avg :: [Int64] -> Int64
p90avg ls =
    avg chopped
  where
    sorted = sortBy (comparing Down) ls
    len = length sorted
    chopped = drop (length sorted * 9 `div` 10) sorted

normalize :: [StatEntry] -> [Int64]
normalize =
    concatMap $
    \(StatEntry x i) ->
        replicate (fromIntegral i) (round (toDouble x / toDouble i))

