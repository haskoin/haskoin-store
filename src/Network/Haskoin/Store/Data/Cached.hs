{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
module Network.Haskoin.Store.Data.Cached where

import           Conduit
import           Control.Monad.Reader                (ReaderT)
import qualified Control.Monad.Reader                as R
import qualified Data.ByteString                     as B
import           Data.IntMap.Strict                  (IntMap)
import           Data.Serialize                      (Serialize, encode)
import           Database.RocksDB                    as R
import           Haskoin
import           Network.Haskoin.Store.Data
import           Network.Haskoin.Store.Data.KeyValue
import           Network.Haskoin.Store.Data.RocksDB
import           UnliftIO

newLayeredDB :: MonadUnliftIO m => BlockDB -> Maybe BlockDB -> m LayeredDB
newLayeredDB blocks Nothing =
    return LayeredDB {layeredDB = blocks, layeredCache = Nothing}
newLayeredDB blocks (Just cache) = do
    bulkCopy opts db cdb BalKeyS
    bulkCopy opts db cdb UnspentKeyB
    bulkCopy opts db cdb MemKey
    bulkCopy opts db cdb AddrTxKeyS
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
       (MonadResource m, MonadIO m) => LayeredDB -> ConduitT i Unspent m ()
getUnspentsC LayeredDB {layeredDB = db} = getUnspentsDB db

getMempoolC :: MonadIO m => LayeredDB -> m [(UnixTime, TxHash)]
getMempoolC LayeredDB {layeredCache = Just db} = getMempoolDB db
getMempoolC LayeredDB {layeredDB = db}         = getMempoolDB db

getOrphansC ::
       (MonadUnliftIO m, MonadResource m)
    => LayeredDB
    -> ConduitT i (UnixTime, Tx) m ()
getOrphansC LayeredDB {layeredDB = db} = getOrphansDB db

getAddressBalancesC ::
       (MonadUnliftIO m, MonadResource m)
    => LayeredDB
    -> ConduitT i Balance m ()
getAddressBalancesC LayeredDB {layeredDB = db} = getAddressBalancesDB db

getAddressUnspentsC ::
       (MonadUnliftIO m, MonadResource m)
    => Address
    -> Maybe BlockRef
    -> LayeredDB
    -> ConduitT i Unspent m ()
getAddressUnspentsC addr mbr LayeredDB {layeredDB = db} =
    getAddressUnspentsDB addr mbr db

getAddressTxsC ::
       (MonadUnliftIO m, MonadResource m)
    => Address
    -> Maybe BlockRef
    -> LayeredDB
    -> ConduitT i BlockTx m ()
getAddressTxsC addr mbr LayeredDB {layeredCache = Just db} =
    getAddressTxsDB addr mbr db
getAddressTxsC addr mbr LayeredDB {layeredDB = db} =
    getAddressTxsDB addr mbr db

bulkCopy ::
       (Serialize k, MonadUnliftIO m) => ReadOptions -> DB -> DB -> k -> m ()
bulkCopy opts db cdb b =
    runResourceT $ do
        ch <- newTBQueueIO 1000000
        withAsync (iter ch) $ \_ -> write_batch ch [] (0 :: Int)
  where
    iter ch =
        withIterator db opts $ \it -> do
            iterSeek it (encode b)
            recurse it ch
    write_batch ch acc l
        | l >= 10000 = do
            write cdb defaultWriteOptions acc
            write_batch ch [] 0
        | otherwise =
            atomically (readTBQueue ch) >>= \case
                Just (k, v) -> write_batch ch (Put k v : acc) (l + 1)
                Nothing -> write cdb defaultWriteOptions acc
    recurse it ch =
        iterEntry it >>= \case
            Nothing -> atomically $ writeTBQueue ch Nothing
            Just (k, v) ->
                let pfx = B.take (B.length (encode k)) k
                 in if pfx == encode k
                        then do
                            atomically . writeTBQueue ch $ Just (k, v)
                            iterNext it
                            recurse it ch
                        else atomically $ writeTBQueue ch Nothing

instance (MonadUnliftIO m, MonadResource m) =>
         StoreStream (ReaderT LayeredDB m) where
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
    getMempool = do
        c <- R.ask
        getMempoolC c
