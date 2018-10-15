{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Network.Haskoin.Store.Data.RocksDB where

import           Conduit
import           Data.Maybe
import           Data.Word
import           Database.RocksDB                    (DB, ReadOptions)
import           Database.RocksDB.Query
import           Haskoin
import           Network.Haskoin.Store.Data
import           Network.Haskoin.Store.Data.KeyValue
import           UnliftIO

dataVersion :: Word32
dataVersion = 5

data ExceptRocksDB =
    MempoolTxNotFound
    deriving (Eq, Show, Read, Exception)

isInitializedDB :: MonadIO m => DB -> ReadOptions -> m (Either InitException Bool)
isInitializedDB db opts =
    retrieve db opts VersionKey >>= \case
        Just v
            | v == dataVersion -> return (Right True)
            | otherwise -> return (Left (IncorrectVersion v))
        Nothing -> return (Right False)

getBestBlockDB :: MonadIO m => DB -> ReadOptions -> m (Maybe BlockHash)
getBestBlockDB db opts = retrieve db opts BestKey

getBlocksAtHeightDB ::
       MonadIO m => DB -> ReadOptions -> BlockHeight -> m [BlockHash]
getBlocksAtHeightDB db opts h =
    retrieve db opts (HeightKey h) >>= \case
        Nothing -> return []
        Just ls -> return ls

getBlockDB :: MonadIO m => DB -> ReadOptions -> BlockHash -> m (Maybe BlockData)
getBlockDB db opts h = retrieve db opts (BlockKey h)

getTransactionDB ::
       MonadIO m => DB -> ReadOptions -> TxHash -> m (Maybe Transaction)
getTransactionDB db opts th = retrieve db opts (TxKey th)

getBalanceDB :: MonadIO m => DB -> ReadOptions -> Address -> m (Maybe Balance)
getBalanceDB db opts a = fmap f <$> retrieve db opts (BalKey a)
  where
    f BalVal {balValAmount = v, balValZero = z, balValCount = c} =
        Balance
            { balanceAddress = a
            , balanceAmount = v
            , balanceZero = z
            , balanceCount = c
            }

getMempoolDB ::
       (MonadIO m, MonadResource m)
    => DB
    -> ReadOptions
    -> ConduitT () (PreciseUnixTime, TxHash) m ()
getMempoolDB db opts = matching db opts MemKeyS .| mapC (uncurry f)
  where
    f (MemKey u t) () = (u, t)
    f _ _ = undefined

getAddressTxsDB ::
       (MonadIO m, MonadResource m)
    => DB
    -> ReadOptions
    -> Address
    -> ConduitT () AddressTx m ()
getAddressTxsDB db opts a =
    matching db opts (AddrTxKeyA a) .| mapC (uncurry f)
  where
    f AddrTxKey {addrTxKey = t} () = t
    f _ _                          = undefined

getAddressUnspentsDB ::
       (MonadIO m, MonadResource m)
    => DB
    -> ReadOptions
    -> Address
    -> ConduitT () Unspent m ()
getAddressUnspentsDB db opts a =
    matching db opts (AddrOutKeyA a) .| mapC (uncurry f)
  where
    f AddrOutKey { addrOutKeyB = b
                 , addrOutKeyP = p
                 }
        OutVal { outValAmount = v
               , outValScript = s
               } =
        Unspent
            { unspentBlock = b
            , unspentAmount = v
            , unspentScript = s
            , unspentPoint = p
            }
    f _ _ = undefined

instance MonadIO m => StoreRead (DB, ReadOptions) m where
    isInitialized (db, opts) = isInitializedDB db opts
    getBestBlock (db, opts) = getBestBlockDB db opts
    getBlocksAtHeight (db, opts) = getBlocksAtHeightDB db opts
    getBlock (db, opts) = getBlockDB db opts
    getTransaction (db, opts) = getTransactionDB db opts
    getBalance (db, opts) a = fromMaybe b <$> getBalanceDB db opts a
      where
        b =
            Balance
                { balanceAddress = a
                , balanceAmount = 0
                , balanceZero = 0
                , balanceCount = 0
                }

instance (MonadIO m, MonadResource m) => StoreStream (DB, ReadOptions) m where
    getMempool (db, opts) = getMempoolDB db opts
    getAddressTxs (db, opts) = getAddressTxsDB db opts
    getAddressUnspents (db, opts) = getAddressUnspentsDB db opts

setInitDB :: MonadIO m => DB -> m ()
setInitDB db = insert db VersionKey dataVersion
