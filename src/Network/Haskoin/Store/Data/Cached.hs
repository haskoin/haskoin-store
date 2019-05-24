{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
module Network.Haskoin.Store.Data.Cached where

import           Conduit
import           Control.Applicative
import           Control.Monad.Except
import           Control.Monad.Logger
import           Control.Monad.Reader                (ReaderT)
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
import           Network.Haskoin.Store.Data.STM
import           NQE                                 (query)
import           UnliftIO

data CachedDB =
    CachedDB
        { cachedDB    :: !(ReadOptions, DB)
        , cachedCache :: !(Maybe Cache)
        }

newCache :: MonadUnliftIO m => ReadOptions -> DB -> ReadOptions -> DB -> m Cache
newCache opts db copts cdb = do
    bulkCopy opts db cdb BalKeyS
    bulkCopy opts db cdb UnspentKeyB
    return (copts, cdb)

withCachedDB ::
       ReadOptions
    -> DB
    -> Maybe Cache
    -> ReaderT CachedDB m a
    -> m a
withCachedDB opts db cache f =
    R.runReaderT f CachedDB {cachedDB = (opts, db), cachedCache = cache}

isInitializedC :: MonadIO m => CachedDB -> m (Either InitException Bool)
isInitializedC CachedDB {cachedDB = db} = uncurry withBlockDB db isInitialized

getBestBlockC :: MonadIO m => CachedDB -> m (Maybe BlockHash)
getBestBlockC CachedDB {cachedDB = db} =
    uncurry withBlockDB db getBestBlock

getBlocksAtHeightC :: MonadIO m => BlockHeight -> CachedDB -> m [BlockHash]
getBlocksAtHeightC bh CachedDB {cachedDB = db} =
    uncurry withBlockDB db (getBlocksAtHeight bh)

getBlockC :: MonadIO m => BlockHash -> CachedDB -> m (Maybe BlockData)
getBlockC bh CachedDB {cachedDB = db} = uncurry withBlockDB db (getBlock bh)

getTxDataC :: MonadIO m => TxHash -> CachedDB -> m (Maybe TxData)
getTxDataC th CachedDB {cachedDB = db} = uncurry withBlockDB db (getTxData th)

getOrphanTxC :: MonadIO m => TxHash -> CachedDB -> m (Maybe (UnixTime, Tx))
getOrphanTxC h CachedDB {cachedDB = db} = uncurry withBlockDB db (getOrphanTx h)

getSpenderC :: MonadIO m => OutPoint -> CachedDB -> m (Maybe Spender)
getSpenderC op CachedDB {cachedDB = db} = uncurry withBlockDB db (getSpender op)

getSpendersC :: MonadIO m => TxHash -> CachedDB -> m (IntMap Spender)
getSpendersC t CachedDB {cachedDB = db} = uncurry withBlockDB db (getSpenders t)

getBalanceC :: MonadIO m => Address -> CachedDB -> m (Maybe Balance)
getBalanceC a CachedDB {cachedCache = Just cdb} =
    uncurry withBlockDB cdb (getBalance a)
getBalanceC a CachedDB {cachedDB = db} = uncurry withBlockDB db (getBalance a)

getUnspentC :: MonadIO m => OutPoint -> CachedDB -> m (Maybe Unspent)
getUnspentC op CachedDB {cachedDB = db, cachedCache = Just cdb} =
    uncurry withBlockDB cdb (getUnspent op)
getUnspentC op CachedDB {cachedDB = db} =
    uncurry withBlockDB db $ getUnspent op

getUnspentsC :: (MonadResource m, MonadIO m) => CachedDB -> ConduitT () Unspent m ()
getUnspentsC CachedDB {cachedDB = db} = do
    uncurry getUnspentsDB db

getMempoolC ::
       (MonadResource m, MonadUnliftIO m)
    => Maybe UnixTime
    -> CachedDB
    -> ConduitT () (UnixTime, TxHash) m ()
getMempoolC mpu CachedDB {cachedDB = db} = uncurry (getMempoolDB mpu) db

getOrphansC ::
       (MonadUnliftIO m, MonadResource m)
    => CachedDB
    -> ConduitT () (UnixTime, Tx) m ()
getOrphansC CachedDB {cachedDB = db} = uncurry getOrphansDB db

getAddressBalancesC ::
       (MonadUnliftIO m, MonadResource m)
    => CachedDB
    -> ConduitT () Balance m ()
getAddressBalancesC CachedDB {cachedDB = db} =
    uncurry getAddressBalancesDB db

getAddressUnspentsC ::
       (MonadUnliftIO m, MonadResource m)
    => Address
    -> Maybe BlockRef
    -> CachedDB
    -> ConduitT () Unspent m ()
getAddressUnspentsC addr mbr CachedDB {cachedDB = db} =
    uncurry (getAddressUnspentsDB addr mbr) db

getAddressTxsC ::
       (MonadUnliftIO m, MonadResource m)
    => Address
    -> Maybe BlockRef
    -> CachedDB
    -> ConduitT () BlockTx m ()
getAddressTxsC addr mbr CachedDB {cachedDB = db} =
    uncurry (getAddressTxsDB addr mbr) db

setInitC :: MonadIO m => CachedDB -> m ()
setInitC CachedDB {cachedCache = cdb} = onCachedDB cdb setInit

setBestC :: MonadIO m => BlockHash -> CachedDB -> m ()
setBestC bh CachedDB {cachedCache = cdb} = onCachedDB cdb $ setBest bh

insertBlockC :: MonadIO m => BlockData -> CachedDB -> m ()
insertBlockC bd CachedDB {cachedCache = cdb} = onCachedDB cdb $ insertBlock bd

insertAtHeightC :: MonadIO m => BlockHash -> BlockHeight -> CachedDB -> m ()
insertAtHeightC bh he CachedDB {cachedCache = cdb} =
    onCachedDB cdb $ insertAtHeight bh he

insertTxC :: MonadIO m => TxData -> CachedDB -> m ()
insertTxC td CachedDB {cachedCache = cdb} = onCachedDB cdb $ insertTx td

insertSpenderC :: MonadIO m => OutPoint -> Spender -> CachedDB -> m ()
insertSpenderC op sp CachedDB {cachedCache = cdb} =
    onCachedDB cdb $ insertSpender op sp

deleteSpenderC :: MonadIO m => OutPoint -> CachedDB -> m ()
deleteSpenderC op CachedDB {cachedCache = cdb} =
    onCachedDB cdb $ deleteSpender op

insertAddrTxC :: MonadIO m => Address -> BlockTx -> CachedDB -> m ()
insertAddrTxC ad bt CachedDB {cachedCache = cdb} =
    onCachedDB cdb $ insertAddrTx ad bt

deleteAddrTxC :: MonadIO m => Address -> BlockTx -> CachedDB -> m ()
deleteAddrTxC ad bt CachedDB {cachedCache = cdb} =
    onCachedDB cdb $ deleteAddrTx ad bt

insertAddrUnspentC :: MonadIO m => Address -> Unspent -> CachedDB -> m ()
insertAddrUnspentC ad u CachedDB {cachedCache = cdb} =
    onCachedDB cdb $ insertAddrUnspent ad u

deleteAddrUnspentC :: MonadIO m => Address -> Unspent -> CachedDB -> m ()
deleteAddrUnspentC ad u CachedDB {cachedCache = cdb} =
    onCachedDB cdb $ deleteAddrUnspent ad u

insertMempoolTxC :: MonadIO m => TxHash -> UnixTime -> CachedDB -> m ()
insertMempoolTxC h u CachedDB {cachedCache = cdb} =
    onCachedDB cdb $ insertMempoolTx h u

deleteMempoolTxC :: MonadIO m => TxHash -> UnixTime -> CachedDB -> m ()
deleteMempoolTxC h u CachedDB {cachedCache = cdb} =
    onCachedDB cdb $ deleteMempoolTx h u

insertOrphanTxC :: MonadIO m => Tx -> UnixTime -> CachedDB -> m ()
insertOrphanTxC t u CachedDB {cachedCache = cdb} =
    onCachedDB cdb $ insertOrphanTx t u

deleteOrphanTxC :: MonadIO m => TxHash -> CachedDB -> m ()
deleteOrphanTxC h CachedDB {cachedCache = cdb} =
    onCachedDB cdb $ deleteOrphanTx h

insertUnspentC :: MonadIO m => Unspent -> CachedDB -> m ()
insertUnspentC u CachedDB {cachedCache = cdb} = onCachedDB cdb $ insertUnspent u

deleteUnspentC :: MonadIO m => OutPoint -> CachedDB -> m ()
deleteUnspentC p CachedDB {cachedCache = cdb} = onCachedDB cdb $ deleteUnspent p

setBalanceC :: MonadIO m => Balance -> CachedDB -> m ()
setBalanceC b CachedDB {cachedCache = cdb} = onCachedDB cdb $ setBalance b

onCachedDB :: MonadIO m => Maybe Cache -> ReaderT BlockDB m () -> m ()
onCachedDB (Just cdb) action = uncurry withBlockDB cdb action
onCachedDB Nothing _         = return ()

bulkCopy ::
       (Serialize k, MonadUnliftIO m) => ReadOptions -> DB -> DB -> k -> m ()
bulkCopy opts db cdb k =
    runResourceT $ do
        ch <- newTBQueueIO 1000000
        withAsync (iterate ch) $ \a -> write_batch ch []
  where
    iterate ch =
        withIterator db opts $ \it -> do
            iterSeek it (encode k)
            recurse it ch
    write_batch ch acc
        | length acc >= 100000 = do
            write db defaultWriteOptions $ map (uncurry Put) acc
            write_batch ch []
        | otherwise =
            atomically (readTBQueue ch) >>= \case
                Just (key, val) -> write_batch ch ((key, val) : acc)
                Nothing -> write db defaultWriteOptions $ map (uncurry Put) acc
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
         StoreStream (ReaderT CachedDB m) where
    getMempool x = R.ask >>= getMempoolC x
    getOrphans = R.ask >>= getOrphansC
    getAddressUnspents a x = R.ask >>= getAddressUnspentsC a x
    getAddressTxs a x = R.ask >>= getAddressTxsC a x
    getAddressBalances = R.ask >>= getAddressBalancesC
    getUnspents = R.ask >>= getUnspentsC

instance MonadIO m => StoreRead (ReaderT CachedDB m) where
    isInitialized = R.ask >>= isInitializedC
    getBestBlock = R.ask >>= getBestBlockC
    getBlocksAtHeight h = R.ask >>= getBlocksAtHeightC h
    getBlock b = R.ask >>= getBlockC b
    getTxData t = R.ask >>= getTxDataC t
    getSpender p = R.ask >>= getSpenderC p
    getSpenders t = R.ask >>= getSpendersC t
    getOrphanTx h = R.ask >>= getOrphanTxC h
    getUnspent a = R.ask >>= getUnspentC a
    getBalance a = R.ask >>= getBalanceC a

instance MonadIO m => StoreWrite (ReaderT CachedDB m) where
    setInit = R.ask >>= setInitC
    setBest h = R.ask >>= setBestC h
    insertBlock b = R.ask >>= insertBlockC b
    insertAtHeight h g = R.ask >>= insertAtHeightC h g
    insertTx t = R.ask >>= insertTxC t
    insertSpender p s = R.ask >>= insertSpenderC p s
    deleteSpender p = R.ask >>= deleteSpenderC p
    insertAddrTx a t = R.ask >>= insertAddrTxC a t
    deleteAddrTx a t = R.ask >>= deleteAddrTxC a t
    insertAddrUnspent a u = R.ask >>= insertAddrUnspentC a u
    deleteAddrUnspent a u = R.ask >>= deleteAddrUnspentC a u
    insertMempoolTx h t = R.ask >>= insertMempoolTxC h t
    deleteMempoolTx h t = R.ask >>= deleteMempoolTxC h t
    insertOrphanTx t u = R.ask >>= insertOrphanTxC t u
    deleteOrphanTx h = R.ask >>= deleteOrphanTxC h
    setBalance b = R.ask >>= setBalanceC b
    insertUnspent u = R.ask >>= insertUnspentC u
    deleteUnspent p = R.ask >>= deleteUnspentC p
