{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections     #-}
module Network.Haskoin.Store.Data.Cached where

import           Conduit
import           Control.Applicative
import           Control.Monad.Except
import           Control.Monad.Logger
import           Control.Monad.Reader                (ReaderT)
import qualified Control.Monad.Reader                as R
import           Control.Monad.Trans.Maybe
import qualified Data.ByteString.Short               as B.Short
import           Data.HashMap.Strict                 (HashMap)
import qualified Data.HashMap.Strict                 as M
import           Data.IntMap.Strict                  (IntMap)
import qualified Data.IntMap.Strict                  as I
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
import           UnliftIO

data CachedDB =
    CachedDB
        { cachedDB :: !(ReadOptions, DB)
        , cachedUnspentMap :: !(TVar UnspentMap)
        , cachedBalanceMap :: !(TVar BalanceMap)
        }

withCachedDB ::
       ReadOptions
    -> DB
    -> TVar UnspentMap
    -> TVar BalanceMap
    -> ReaderT CachedDB m a
    -> m a
withCachedDB opts db um bm f =
    R.runReaderT
        f
        CachedDB
            { cachedDB = (opts, db)
            , cachedUnspentMap = um
            , cachedBalanceMap = bm
            }

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
getBalanceC a CachedDB {cachedDB = db, cachedBalanceMap = bm} =
    runMaybeT $ cachemap <|> database
  where
    cachemap = MaybeT . atomically $ withBalanceSTM bm (getBalance a)
    database = MaybeT . uncurry withBlockDB db $ getBalance a

getUnspentC :: MonadIO m => OutPoint -> CachedDB -> m (Maybe Unspent)
getUnspentC op CachedDB {cachedDB = db, cachedUnspentMap = um} =
    runMaybeT $ cachemap <|> database
  where
    cachemap = MaybeT . atomically $ withUnspentSTM um (getUnspent op)
    database = MaybeT $ uncurry withBlockDB db (getUnspent op)

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
