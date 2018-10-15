{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
module Network.Haskoin.Store.Data.ImportDB where

import           Conduit
import           Control.Applicative
import           Control.Monad.Except
import           Control.Monad.Trans.Maybe
import           Data.HashMap.Strict                 (HashMap)
import qualified Data.HashMap.Strict                 as M
import           Data.List
import           Database.RocksDB                    as R
import           Database.RocksDB.Query              as R
import           Haskoin
import           Network.Haskoin.Store.Data
import           Network.Haskoin.Store.Data.HashMap
import           Network.Haskoin.Store.Data.KeyValue
import           Network.Haskoin.Store.Data.RocksDB
import           UnliftIO

data ImportDB = ImportDB
    { importRocksDB :: !(DB, ReadOptions)
    , importHashMap :: !(TVar HashMapDB)
    }

runImportDB ::
       (MonadError e m, MonadIO m)
    => DB
    -> (ImportDB -> m a)
    -> m a
runImportDB db f = do
    hm <- newTVarIO emptyHashMapDB
    x <- f ImportDB {importRocksDB = d, importHashMap = hm}
    ops <- hashMapOps <$> readTVarIO hm
    writeBatch db ops
    return x
  where
    d = (db, defaultReadOptions)

hashMapOps :: HashMapDB -> [BatchOp]
hashMapOps db =
    bestBlockOp (hBest db) <>
    blockHashOps (hBlock db) <>
    blockHeightOps (hHeight db) <>
    txOps (hTx db) <>
    balOps (hBalance db) <>
    addrTxOps (hAddrTx db) <>
    addrOutOps (hAddrOut db) <>
    mempoolOps (hMempool db)

bestBlockOp :: Maybe BlockHash -> [BatchOp]
bestBlockOp Nothing  = []
bestBlockOp (Just b) = [insertOp BestKey b]

blockHashOps :: HashMap BlockHash BlockData -> [BatchOp]
blockHashOps = map f . M.toList
  where
    f (h, d) = insertOp (BlockKey h) d

blockHeightOps :: HashMap BlockHeight [BlockHash] -> [BatchOp]
blockHeightOps = map f . M.toList
  where
    f (g, ls) = insertOp (HeightKey g) ls

txOps :: HashMap TxHash Transaction -> [BatchOp]
txOps = map f . M.toList
  where
    f (h, t) = insertOp (TxKey h) t

balOps :: HashMap Address (Maybe BalVal) -> [BatchOp]
balOps = map (uncurry f) . M.toList
  where
    f a (Just b) = insertOp (BalKey a) b
    f a Nothing  = deleteOp (BalKey a)

addrTxOps ::
       HashMap Address (HashMap BlockRef (HashMap TxHash Bool)) -> [BatchOp]
addrTxOps = concat . concatMap (uncurry f) . M.toList
  where
    f a = map (uncurry (g a)) . M.toList
    g a b = map (uncurry (h a b)) . M.toList
    h a b t True =
        insertOp
            (AddrTxKey
                 { addrTxKey =
                       AddressTx
                           { addressTxAddress = a
                           , addressTxBlock = b
                           , addressTxHash = t
                           }
                 })
            ()
    h a b t False =
        deleteOp
            AddrTxKey
                { addrTxKey =
                      AddressTx
                          { addressTxAddress = a
                          , addressTxBlock = b
                          , addressTxHash = t
                          }
                }

addrOutOps ::
       HashMap Address (HashMap BlockRef (HashMap OutPoint (Maybe OutVal)))
    -> [BatchOp]
addrOutOps = concat . concatMap (uncurry f) . M.toList
  where
    f a = map (uncurry (g a)) . M.toList
    g a b = map (uncurry (h a b)) . M.toList
    h a b p (Just l) =
        insertOp
            (AddrOutKey {addrOutKeyA = a, addrOutKeyB = b, addrOutKeyP = p})
            l
    h a b p Nothing =
        deleteOp AddrOutKey {addrOutKeyA = a, addrOutKeyB = b, addrOutKeyP = p}

mempoolOps ::
       HashMap PreciseUnixTime (HashMap TxHash Bool) -> [BatchOp]
mempoolOps = concatMap (uncurry f) . M.toList
  where
    f u = map (uncurry (g u)) . M.toList
    g u t True = insertOp (MemKey u t) ()
    g u t False = deleteOp (MemKey u t)

unspentOps :: HashMap OutPoint (Maybe OutVal) -> [BatchOp]
unspentOps = map (uncurry f) . M.toList
  where
    f p (Just o) = insertOp (UnspentKey p) o
    f p Nothing  = deleteOp (UnspentKey p)

isInitializedI :: MonadIO m => ImportDB -> m (Either InitException Bool)
isInitializedI ImportDB {importRocksDB = db}= isInitialized db

getBestBlockI :: MonadIO m => ImportDB -> m (Maybe BlockHash)
getBestBlockI ImportDB {importHashMap = hm, importRocksDB = db} =
    runMaybeT $ MaybeT (getBestBlock hm) <|> MaybeT (getBestBlock db)

getBlocksAtHeightI :: MonadIO m => ImportDB -> BlockHeight -> m [BlockHash]
getBlocksAtHeightI ImportDB {importHashMap = hm, importRocksDB = db} bh = do
    xs <- getBlocksAtHeight hm bh
    ys <- getBlocksAtHeight db bh
    return . nub $ xs <> ys

getBlockI :: MonadIO m => ImportDB -> BlockHash -> m (Maybe BlockData)
getBlockI ImportDB {importRocksDB = db, importHashMap = hm} bh =
    runMaybeT $ MaybeT (getBlock hm bh) <|> MaybeT (getBlock db bh)

getTransactionI ::
       MonadIO m => ImportDB -> TxHash -> m (Maybe Transaction)
getTransactionI ImportDB {importRocksDB = db, importHashMap = hm} th =
    runMaybeT $ MaybeT (getTransaction hm th) <|> MaybeT (getTransaction db th)

getBalanceI :: MonadIO m => ImportDB -> Address -> m Balance
getBalanceI ImportDB {importRocksDB = db, importHashMap = hm} a =
    getBalanceH <$> readTVarIO hm <*> pure a >>= \case
        Just b -> return b
        Nothing -> getBalance db a

instance MonadIO m => StoreRead ImportDB m where
    isInitialized = isInitializedI
    getBestBlock = getBestBlockI
    getBlocksAtHeight = getBlocksAtHeightI
    getBlock = getBlockI
    getTransaction = getTransactionI
    getBalance = getBalanceI

instance MonadIO m => StoreWrite ImportDB m where
    setInit ImportDB {importHashMap = hm, importRocksDB = (db, _)} =
        setInit hm >> setInitDB db
    setBest ImportDB {importHashMap = hm} = setBest hm
    insertBlock ImportDB {importHashMap = hm} = insertBlock hm
    insertAtHeight ImportDB {importHashMap = hm} = insertAtHeight hm
    insertTx ImportDB {importHashMap = hm} = insertTx hm
    setBalance ImportDB {importHashMap = hm} = setBalance hm
    insertAddrTx ImportDB {importHashMap = hm} = insertAddrTx hm
    removeAddrTx ImportDB {importHashMap = hm} = removeAddrTx hm
    insertAddrUnspent ImportDB {importHashMap = hm} = insertAddrUnspent hm
    removeAddrUnspent ImportDB {importHashMap = hm} = removeAddrUnspent hm
    insertMempoolTx ImportDB {importHashMap = hm} = insertMempoolTx hm
    deleteMempoolTx ImportDB {importHashMap = hm} = deleteMempoolTx hm
