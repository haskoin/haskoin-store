{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
module Network.Haskoin.Store.Data.ImportDB where

import           Conduit
import           Control.Applicative
import           Control.Monad.Except
import           Control.Monad.Trans.Maybe
import qualified Data.ByteString.Short               as B.Short
import           Data.HashMap.Strict                 (HashMap)
import qualified Data.HashMap.Strict                 as M
import           Data.IntMap.Strict                  (IntMap)
import qualified Data.IntMap.Strict                  as I
import           Data.List
import           Data.Maybe
import           Database.RocksDB                    as R
import           Database.RocksDB.Query              as R
import           Haskoin
import           Network.Haskoin.Store.Data
import           Network.Haskoin.Store.Data.HashMap
import           Network.Haskoin.Store.Data.KeyValue
import           Network.Haskoin.Store.Data.RocksDB
import           UnliftIO

data ImportDB = ImportDB
    { importRocksDB    :: !(DB, ReadOptions)
    , importHashMap    :: !(TVar HashMapDB)
    , importUnspentMap :: !(TVar UnspentMap)
    , importBalanceMap :: !(TVar BalanceMap)
    }

runImportDB ::
       (MonadError e m, MonadIO m)
    => DB
    -> TVar UnspentMap
    -> TVar BalanceMap
    -> (ImportDB -> m a)
    -> m a
runImportDB db um bm f = do
    hm <- newTVarIO emptyHashMapDB
    x <-
        f
            ImportDB
                { importRocksDB = d
                , importHashMap = hm
                , importUnspentMap = um
                , importBalanceMap = bm
                }
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
    spenderOps (hSpender db) <>
    balOps (hBalance db) <>
    addrTxOps (hAddrTx db) <>
    addrOutOps (hAddrOut db) <>
    mempoolOps (hMempool db) <>
    unspentOps (hUnspent db)

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

txOps :: HashMap TxHash TxData -> [BatchOp]
txOps = map f . M.toList
  where
    f (h, t) = insertOp (TxKey h) t

spenderOps :: HashMap TxHash (IntMap (Maybe Spender)) -> [BatchOp]
spenderOps = concatMap (uncurry f) . M.toList
  where
    f h = map (uncurry (g h)) . I.toList
    g h i (Just s) = insertOp (SpenderKey (OutPoint h (fromIntegral i))) s
    g h i Nothing  = deleteOp (SpenderKey (OutPoint h (fromIntegral i)))

balOps :: HashMap Address (Maybe BalVal) -> [BatchOp]
balOps = map (uncurry f) . M.toList
  where
    f a Nothing  = deleteOp (BalKey a)
    f a (Just b) = insertOp (BalKey a) b

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
    g u t True  = insertOp (MemKey u t) ()
    g u t False = deleteOp (MemKey u t)

unspentOps :: HashMap TxHash (IntMap (Maybe Unspent)) -> [BatchOp]
unspentOps = concatMap (uncurry f) . M.toList
  where
    f h = map (uncurry (g h)) . I.toList
    g h i (Just u) =
        insertOp
            (UnspentKey (OutPoint h (fromIntegral i)))
            UnspentVal
                { unspentValAmount = unspentAmount u
                , unspentValBlock = unspentBlock u
                , unspentValScript = B.Short.fromShort (unspentScript u)
                }
    g h i Nothing = deleteOp (UnspentKey (OutPoint h (fromIntegral i)))

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

getTxDataI ::
       MonadIO m => ImportDB -> TxHash -> m (Maybe TxData)
getTxDataI ImportDB {importRocksDB = db, importHashMap = hm} th =
    runMaybeT $ MaybeT (getTxData hm th) <|> MaybeT (getTxData db th)

getSpenderI :: MonadIO m => ImportDB -> OutPoint -> m (Maybe Spender)
getSpenderI ImportDB {importRocksDB = db, importHashMap = hm} op =
    getSpenderH <$> readTVarIO hm <*> pure op >>= \case
        Just s -> return s
        Nothing -> getSpender db op

getSpendersI :: MonadIO m => ImportDB -> TxHash -> m (IntMap Spender)
getSpendersI ImportDB {importRocksDB = db, importHashMap = hm} t = do
    hsm <- getSpendersH <$> readTVarIO hm <*> pure t
    dsm <- I.map Just <$> getSpenders db t
    return . I.map fromJust . I.filter isJust $ hsm <> dsm

getBalanceI :: MonadIO m => ImportDB -> Address -> m (Maybe Balance)
getBalanceI ImportDB { importRocksDB = db
                     , importHashMap = hm
                     , importBalanceMap = bm
                     } a =
    getBalance bm a >>= \case
        Just b -> return (Just b)
        Nothing ->
            getBalanceH <$> readTVarIO hm <*> pure a >>= \case
                Just x -> return x
                Nothing -> getBalance db a

getUnspentI :: MonadIO m => ImportDB -> OutPoint -> m (Maybe Unspent)
getUnspentI ImportDB { importRocksDB = db
                     , importHashMap = hm
                     , importUnspentMap = um
                     } op =
    getUnspent um op >>= \case
        Just b -> return (Just b)
        Nothing ->
            getUnspentH <$> readTVarIO hm <*> pure op >>= \case
                Just x -> return x
                Nothing -> getUnspent db op

instance MonadIO m => StoreRead ImportDB m where
    isInitialized = isInitializedI
    getBestBlock = getBestBlockI
    getBlocksAtHeight = getBlocksAtHeightI
    getBlock = getBlockI
    getTxData = getTxDataI
    getSpender = getSpenderI
    getSpenders = getSpendersI

instance MonadIO m => StoreWrite ImportDB m where
    setInit ImportDB {importHashMap = hm, importRocksDB = (db, _)} =
        setInit hm >> setInitDB db
    setBest ImportDB {importHashMap = hm} = setBest hm
    insertBlock ImportDB {importHashMap = hm} = insertBlock hm
    insertAtHeight ImportDB {importHashMap = hm} = insertAtHeight hm
    insertTx ImportDB {importHashMap = hm} = insertTx hm
    insertSpender ImportDB {importHashMap = hm} = insertSpender hm
    deleteSpender ImportDB {importHashMap = hm} = deleteSpender hm
    insertAddrTx ImportDB {importHashMap = hm} = insertAddrTx hm
    removeAddrTx ImportDB {importHashMap = hm} = removeAddrTx hm
    insertAddrUnspent ImportDB {importHashMap = hm} = insertAddrUnspent hm
    removeAddrUnspent ImportDB {importHashMap = hm} = removeAddrUnspent hm
    insertMempoolTx ImportDB {importHashMap = hm} = insertMempoolTx hm
    deleteMempoolTx ImportDB {importHashMap = hm} = deleteMempoolTx hm

instance MonadIO m => UnspentRead ImportDB m where
    getUnspent = getUnspentI

instance MonadIO m => UnspentWrite ImportDB m where
    addUnspent ImportDB {importHashMap = hm, importUnspentMap = um} u =
        addUnspent hm u >> addUnspent um u
    delUnspent ImportDB {importHashMap = hm, importUnspentMap = um} op =
        delUnspent um op >> delUnspent hm op

instance MonadIO m => BalanceRead ImportDB m where
    getBalance = getBalanceI

instance MonadIO m => BalanceWrite ImportDB m where
    setBalance ImportDB {importHashMap = hm, importBalanceMap = bm} b =
        setBalance hm b >> setBalance bm b
