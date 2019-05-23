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
import qualified Data.ByteString.Short               as B.Short
import qualified Data.HashTable.IO                   as H
import           Data.IntMap.Strict                  (IntMap)
import           Data.List
import           Data.Maybe
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
        , cachedCache :: !Cache
        }

newCache :: MonadUnliftIO m => ReadOptions -> DB -> m Cache
newCache opts db = do
    bm <- liftIO H.new
    um <- liftIO H.new
    let cache = Cache {cacheBalance = bm, cacheUnspent = um}
    runResourceT . withBlockDB opts db $ do
        runConduit $ getAddressBalances .| mapMC (bal cache) .| sinkNull
        runConduit $ getUnspents .| mapMC (uns cache) .| sinkNull
    return cache
  where
    bal cache = withCachedDB opts db cache . setBalance
    uns cache = withCachedDB opts db cache . addUnspent

withCachedDB ::
       ReadOptions
    -> DB
    -> Cache
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
getBalanceC a CachedDB {cachedCache = Cache {cacheBalance = bm}} =
    liftIO (H.lookup bm (encodeShort a)) >>= \case
        Just b -> return . Just $ balValToBalance a (decodeShort b)
        Nothing -> return Nothing

setBalanceC :: MonadIO m => Balance -> CachedDB -> m ()
setBalanceC bal CachedDB {cachedCache = Cache {cacheBalance = bm}} =
    liftIO $ H.insert bm (encodeShort a) (encodeShort b)
  where
    (a, b) = balanceToBalVal bal

getUnspentC :: MonadIO m => OutPoint -> CachedDB -> m (Maybe Unspent)
getUnspentC op CachedDB {cachedDB = db, cachedCache = Cache {cacheUnspent = um}} =
    liftIO (H.lookup um (encodeShort op)) >>= \case
        Just u -> return . Just $ unspentValToUnspent op (decodeShort u)
        Nothing -> return Nothing


getUnspentsC :: (MonadResource m, MonadIO m) => CachedDB -> ConduitT () Unspent m ()
getUnspentsC CachedDB {cachedDB = db} = do
    uncurry getUnspentsDB db

addUnspentC :: MonadIO m => Unspent -> CachedDB -> m ()
addUnspentC u CachedDB {cachedCache = Cache {cacheUnspent = um}} =
    liftIO $ H.insert um (encodeShort a) (encodeShort b)
  where
    (a, b) = unspentToUnspentVal u

delUnspentC :: MonadIO m => OutPoint -> CachedDB -> m ()
delUnspentC op CachedDB {cachedCache = Cache {cacheUnspent = um}} =
    liftIO $ H.delete um (encodeShort op)

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

instance MonadIO m => UnspentRead (ReaderT CachedDB m) where
    getUnspent a = R.ask >>= getUnspentC a

instance MonadIO m => BalanceRead (ReaderT CachedDB m) where
    getBalance a = R.ask >>= getBalanceC a

instance MonadIO m => UnspentWrite (ReaderT CachedDB m) where
    addUnspent u = R.ask >>= addUnspentC u
    delUnspent p = R.ask >>= delUnspentC p

instance MonadIO m => BalanceWrite (ReaderT CachedDB m) where
    setBalance b = R.ask >>= setBalanceC b
