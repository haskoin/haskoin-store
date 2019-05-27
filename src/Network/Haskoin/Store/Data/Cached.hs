{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
module Network.Haskoin.Store.Data.Cached where

import           Conduit
import           Control.Applicative
import           Control.Monad.Except
import           Control.Monad.Logger
import           Control.Monad.Reader                (MonadReader, ReaderT)
import qualified Control.Monad.Reader                as R
import           Control.Monad.Trans.Maybe
import qualified Data.ByteString                     as B
import qualified Data.ByteString.Short               as B.Short
import           Data.IntMap.Strict                  (IntMap)
import           Data.List
import           Data.Maybe
import           Data.Serialize                      (Serialize, encode)
import           Data.String.Conversions             (cs)
import           Database.RocksDB                    as R
import           Database.RocksDB.Query              as R
import           Haskoin
import           Network.Haskoin.Store.Data
import           Network.Haskoin.Store.Data.KeyValue
import           Network.Haskoin.Store.Data.RocksDB
import           NQE                                 (query)
import           UnliftIO

newLayeredDB :: MonadUnliftIO m => BlockDB -> Maybe BlockDB -> m LayeredDB
newLayeredDB blocks Nothing =
    return LayeredDB {layeredDB = blocks, layeredCache = Nothing}
newLayeredDB blocks (Just cache) = do
    bulkCopy opts db cdb BalKeyS
    bulkCopy opts db cdb UnspentKeyB
    return LayeredDB {layeredDB = blocks, layeredCache = Just cache}
  where
    BlockDB {blockDBopts = opts, blockDB = db} = blocks
    BlockDB {blockDB = cdb} = cache

withLayeredDB :: LayeredDB -> ReaderT LayeredDB m a -> m a
withLayeredDB = flip R.runReaderT

isInitializedC :: MonadIO m => LayeredDB -> m (Either InitException Bool)
isInitializedC LayeredDB {layeredDB = db} = isInitializedDB db

getBestBlockC :: MonadIO m => LayeredDB -> m (Maybe BlockHash)
getBestBlockC LayeredDB {layeredDB = db} = getBestBlockDB db

getBlocksAtHeightC :: MonadIO m => BlockHeight -> LayeredDB -> m [BlockHash]
getBlocksAtHeightC h LayeredDB {layeredDB = db} = getBlocksAtHeightDB h db

getBlockC :: MonadIO m => BlockHash -> LayeredDB -> m (Maybe BlockData)
getBlockC bh LayeredDB {layeredDB = db} = getBlockDB bh db

getTxDataC :: MonadIO m => TxHash -> LayeredDB -> m (Maybe TxData)
getTxDataC th LayeredDB {layeredDB = db} = getTxDataDB th db

getOrphanTxC :: MonadIO m => TxHash -> LayeredDB -> m (Maybe (UnixTime, Tx))
getOrphanTxC h LayeredDB {layeredDB = db} = getOrphanTxDB h db

getSpenderC :: MonadIO m => OutPoint -> LayeredDB -> m (Maybe Spender)
getSpenderC p LayeredDB {layeredDB = db} = getSpenderDB p db

getSpendersC :: MonadIO m => TxHash -> LayeredDB -> m (IntMap Spender)
getSpendersC t LayeredDB {layeredDB = db} = getSpendersDB t db

getBalanceC :: MonadIO m => Address -> LayeredDB -> m (Maybe Balance)
getBalanceC a LayeredDB {layeredCache = Just db} = getBalanceDB a db
getBalanceC a LayeredDB {layeredDB = db}         = getBalanceDB a db

getUnspentC :: MonadIO m => OutPoint -> LayeredDB -> m (Maybe Unspent)
getUnspentC op LayeredDB {layeredCache = Just db} = getUnspentDB op db
getUnspentC op LayeredDB {layeredDB = db}         = getUnspentDB op db

getUnspentsC ::
       (MonadResource m, MonadIO m) => LayeredDB -> ConduitT () Unspent m ()
getUnspentsC LayeredDB {layeredDB = db} = getUnspentsDB db

getMempoolC ::
       (MonadResource m, MonadUnliftIO m)
    => Maybe UnixTime
    -> LayeredDB
    -> ConduitT () (UnixTime, TxHash) m ()
getMempoolC mpu LayeredDB {layeredDB = db} = getMempoolDB mpu db

getOrphansC ::
       (MonadUnliftIO m, MonadResource m)
    => LayeredDB
    -> ConduitT () (UnixTime, Tx) m ()
getOrphansC LayeredDB {layeredDB = db} = getOrphansDB db

getAddressBalancesC ::
       (MonadUnliftIO m, MonadResource m)
    => LayeredDB
    -> ConduitT () Balance m ()
getAddressBalancesC LayeredDB {layeredDB = db} = getAddressBalancesDB db

getAddressUnspentsC ::
       (MonadUnliftIO m, MonadResource m)
    => Address
    -> Maybe BlockRef
    -> LayeredDB
    -> ConduitT () Unspent m ()
getAddressUnspentsC addr mbr LayeredDB {layeredDB = db} =
    getAddressUnspentsDB addr mbr db

getAddressTxsC ::
       (MonadUnliftIO m, MonadResource m)
    => Address
    -> Maybe BlockRef
    -> LayeredDB
    -> ConduitT () BlockTx m ()
getAddressTxsC addr mbr LayeredDB {layeredDB = db} =
    getAddressTxsDB addr mbr db

bulkCopy ::
       (Serialize k, MonadUnliftIO m) => ReadOptions -> DB -> DB -> k -> m ()
bulkCopy opts db cdb k =
    runResourceT $ do
        ch <- newTBQueueIO 1000000
        withAsync (iterate ch) $ \a -> write_batch ch [] 0
  where
    iterate ch =
        withIterator db opts $ \it -> do
            iterSeek it (encode k)
            recurse it ch
    write_batch ch acc l
        | l >= 10000 = do
            write cdb defaultWriteOptions acc
            write_batch ch [] 0
        | otherwise =
            atomically (readTBQueue ch) >>= \case
                Just (key, val) -> write_batch ch (Put key val : acc) (l + 1)
                Nothing -> write cdb defaultWriteOptions acc
    recurse it ch =
        iterEntry it >>= \case
            Nothing -> atomically $ writeTBQueue ch Nothing
            Just (key, val) ->
                let pfx = B.take (B.length (encode k)) key
                 in if pfx == encode k
                        then do
                            atomically . writeTBQueue ch $ Just (key, val)
                            iterNext it
                            recurse it ch
                        else atomically $ writeTBQueue ch Nothing

instance (MonadUnliftIO m, MonadResource m) =>
         StoreStream (ReaderT LayeredDB m) where
    getMempool x = do
        c <- R.ask
        getMempoolC x c
    getOrphans = do
        c <- R.ask
        getOrphansC c
    getAddressUnspents a x = do
        c <- R.ask
        getAddressUnspentsC a x c
    getAddressTxs a x = do
        c <- R.ask
        getAddressTxsC a x c
    getAddressBalances = do
        c <- R.ask
        getAddressBalancesC c
    getUnspents = do
        c <- R.ask
        getUnspentsC c

instance MonadIO m => StoreRead (ReaderT LayeredDB m) where
    isInitialized = do
        c <- R.ask
        isInitializedC c
    getBestBlock = do
        c <- R.ask
        getBestBlockC c
    getBlocksAtHeight h = do
        c <- R.ask
        getBlocksAtHeightC h c
    getBlock b = do
        c <- R.ask
        getBlockC b c
    getTxData t = do
        c <- R.ask
        getTxDataC t c
    getSpender p = do
        c <- R.ask
        getSpenderC p c
    getSpenders t = do
        c <- R.ask
        getSpendersC t c
    getOrphanTx h = do
        c <- R.ask
        getOrphanTxC h c
    getUnspent a = do
        c <- R.ask
        getUnspentC a c
    getBalance a = do
        c <- R.ask
        getBalanceC a c
