{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections     #-}
module Network.Haskoin.Store.Data.ImportDB where

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
import           Network.Haskoin.Store.Data.Cached
import           Network.Haskoin.Store.Data.KeyValue
import           Network.Haskoin.Store.Data.RocksDB
import           Network.Haskoin.Store.Data.STM
import           UnliftIO

data ImportDB = ImportDB
    { importRocksDB :: !(ReadOptions, DB)
    , importHashMap :: !(TVar HashMapDB)
    , importCache   :: !Cache
    }

importToCached :: ImportDB -> CachedDB
importToCached ImportDB {importRocksDB = db, importCache = cache} =
    CachedDB {cachedDB = db, cachedCache = cache}

runImportDB ::
       (MonadError e m, MonadLoggerIO m)
    => DB
    -> Cache
    -> ReaderT ImportDB m a
    -> m a
runImportDB db cache f = do
    hm <- newTVarIO emptyHashMapDB
    x <-
        R.runReaderT
            f
            ImportDB
                { importRocksDB = (defaultReadOptions, db)
                , importHashMap = hm
                , importCache = cache
                }
    ops <- hashMapOps <$> readTVarIO hm
    $(logDebugS) "ImportDB" "Committing changes to database and cache..."
    writeBatch db ops
    updateCache hm cache
    $(logDebugS) "ImportDB" "Finished committing changes to database and cache"
    return x

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
    orphanOps (hOrphans db) <>
    unspentOps (hUnspent db)

bestBlockOp :: Maybe BlockHash -> [BatchOp]
bestBlockOp Nothing  = []
bestBlockOp (Just b) = [insertOp BestKey b]

blockHashOps :: HashMap BlockHash BlockData -> [BatchOp]
blockHashOps = map (uncurry f) . M.toList
  where
    f = insertOp . BlockKey

blockHeightOps :: HashMap BlockHeight [BlockHash] -> [BatchOp]
blockHeightOps = map (uncurry f) . M.toList
  where
    f = insertOp . HeightKey

txOps :: HashMap TxHash TxData -> [BatchOp]
txOps = map (uncurry f) . M.toList
  where
    f = insertOp . TxKey

spenderOps :: HashMap TxHash (IntMap (Maybe Spender)) -> [BatchOp]
spenderOps = concatMap (uncurry f) . M.toList
  where
    f h = map (uncurry (g h)) . I.toList
    g h i (Just s) = insertOp (SpenderKey (OutPoint h (fromIntegral i))) s
    g h i Nothing  = deleteOp (SpenderKey (OutPoint h (fromIntegral i)))

balOps :: HashMap Address BalVal -> [BatchOp]
balOps = map (uncurry f) . M.toList
  where
    f = insertOp . BalKey

addrTxOps ::
       HashMap Address (HashMap BlockRef (HashMap TxHash Bool)) -> [BatchOp]
addrTxOps = concat . concatMap (uncurry f) . M.toList
  where
    f a = map (uncurry (g a)) . M.toList
    g a b = map (uncurry (h a b)) . M.toList
    h a b t True =
        insertOp
            (AddrTxKey
                 { addrTxKeyA = a
                 , addrTxKeyT =
                       BlockTx
                           { blockTxBlock = b
                           , blockTxHash = t
                           }
                 })
            ()
    h a b t False =
        deleteOp
            AddrTxKey
                { addrTxKeyA = a
                , addrTxKeyT =
                      BlockTx
                          { blockTxBlock = b
                          , blockTxHash = t
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
       HashMap UnixTime (HashMap TxHash Bool) -> [BatchOp]
mempoolOps = concatMap (uncurry f) . M.toList
  where
    f u = map (uncurry (g u)) . M.toList
    g u t True  = insertOp (MemKey u t) ()
    g u t False = deleteOp (MemKey u t)

orphanOps :: HashMap TxHash (Maybe (UnixTime, Tx)) -> [BatchOp]
orphanOps = map (uncurry f) . M.toList
  where
    f h (Just x) = insertOp (OrphanKey h) x
    f h Nothing  = deleteOp (OrphanKey h)

unspentOps :: HashMap TxHash (IntMap (Maybe UnspentVal)) -> [BatchOp]
unspentOps = concatMap (uncurry f) . M.toList
  where
    f h = map (uncurry (g h)) . I.toList
    g h i (Just u) = insertOp (UnspentKey (OutPoint h (fromIntegral i))) u
    g h i Nothing = deleteOp (UnspentKey (OutPoint h (fromIntegral i)))

updateCache :: MonadIO m => TVar HashMapDB -> Cache -> m ()
updateCache ht (ut, bt) = do
    HashMapDB {hUnspent = u, hBalance = b} <- readTVarIO ht
    um <- readTVarIO ut
    bm <- readTVarIO bt
    let um' = updateUnspentCache u um
        bm' = updateBalanceCache b bm
    atomically $ do
        writeTVar ut um'
        writeTVar bt bm'

updateUnspentCache ::
       HashMap TxHash (IntMap (Maybe UnspentVal)) -> UnspentMap -> UnspentMap
updateUnspentCache hm um =
    foldl' (flip ($)) um (concatMap (uncurry f) (M.toList hm))
  where
    f h = map (uncurry (g h)) . I.toList
    g h i (Just u) = M.insert (OutPoint h (fromIntegral i)) u
    g h i Nothing = M.delete (OutPoint h (fromIntegral i))

updateBalanceCache ::
       HashMap Address BalVal -> BalanceMap -> BalanceMap
updateBalanceCache hm bm =
    foldl' (flip ($)) bm (map (uncurry M.insert) (M.toList hm))

isInitializedI :: MonadIO m => ImportDB -> m (Either InitException Bool)
isInitializedI = isInitializedC . importToCached

setInitI :: MonadIO m => ImportDB -> m ()
setInitI ImportDB {importRocksDB = (_, db), importHashMap = hm} = do
    atomically $ withBlockSTM hm setInit
    setInitDB db

setBestI :: MonadIO m => BlockHash -> ImportDB -> m ()
setBestI bh ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ setBest bh

insertBlockI :: MonadIO m => BlockData -> ImportDB -> m ()
insertBlockI b ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ insertBlock b

insertAtHeightI :: MonadIO m => BlockHash -> BlockHeight -> ImportDB -> m ()
insertAtHeightI b h ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ insertAtHeight b h

insertTxI :: MonadIO m => TxData -> ImportDB -> m ()
insertTxI t ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ insertTx t

insertSpenderI :: MonadIO m => OutPoint -> Spender -> ImportDB -> m ()
insertSpenderI p s ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ insertSpender p s

deleteSpenderI :: MonadIO m => OutPoint -> ImportDB -> m ()
deleteSpenderI p ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ deleteSpender p

insertAddrTxI :: MonadIO m => Address -> BlockTx -> ImportDB -> m ()
insertAddrTxI a t ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ insertAddrTx a t

removeAddrTxI :: MonadIO m => Address -> BlockTx -> ImportDB -> m ()
removeAddrTxI a t ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ removeAddrTx a t

insertAddrUnspentI :: MonadIO m => Address -> Unspent -> ImportDB -> m ()
insertAddrUnspentI a u ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ insertAddrUnspent a u

removeAddrUnspentI :: MonadIO m => Address -> Unspent -> ImportDB -> m ()
removeAddrUnspentI a u ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ removeAddrUnspent a u

insertMempoolTxI :: MonadIO m => TxHash -> UnixTime -> ImportDB -> m ()
insertMempoolTxI t p ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ insertMempoolTx t p

deleteMempoolTxI :: MonadIO m => TxHash -> UnixTime -> ImportDB -> m ()
deleteMempoolTxI t p ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ deleteMempoolTx t p

insertOrphanTxI :: MonadIO m => Tx -> UnixTime -> ImportDB -> m ()
insertOrphanTxI t p ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ insertOrphanTx t p

deleteOrphanTxI :: MonadIO m => TxHash -> ImportDB -> m ()
deleteOrphanTxI t ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ deleteOrphanTx t

getBestBlockI :: MonadIO m => ImportDB -> m (Maybe BlockHash)
getBestBlockI ImportDB {importHashMap = hm, importRocksDB = db} =
    runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = atomically $ withBlockSTM hm getBestBlock
    g = uncurry withBlockDB db getBestBlock

getBlocksAtHeightI :: MonadIO m => BlockHeight -> ImportDB -> m [BlockHash]
getBlocksAtHeightI bh ImportDB {importHashMap = hm, importRocksDB = db} = do
    xs <- atomically . withBlockSTM hm $ getBlocksAtHeight bh
    ys <- uncurry withBlockDB db $ getBlocksAtHeight bh
    return . nub $ xs <> ys

getBlockI :: MonadIO m => BlockHash -> ImportDB -> m (Maybe BlockData)
getBlockI bh ImportDB {importRocksDB = db, importHashMap = hm} =
    runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = atomically . withBlockSTM hm $ getBlock bh
    g = uncurry withBlockDB db $ getBlock bh

getTxDataI ::
       MonadIO m => TxHash -> ImportDB -> m (Maybe TxData)
getTxDataI th ImportDB {importRocksDB = db, importHashMap = hm} =
    runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = atomically . withBlockSTM hm $ getTxData th
    g = uncurry withBlockDB db $ getTxData th

getOrphanTxI :: MonadIO m => TxHash -> ImportDB -> m (Maybe (UnixTime, Tx))
getOrphanTxI h ImportDB {importRocksDB = db, importHashMap = hm} =
    fmap join . runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = getOrphanTxH h <$> readTVarIO hm
    g = Just <$> uncurry withBlockDB db (getOrphanTx h)

getSpenderI :: MonadIO m => OutPoint -> ImportDB -> m (Maybe Spender)
getSpenderI op ImportDB {importRocksDB = db, importHashMap = hm} =
    getSpenderH op <$> readTVarIO hm >>= \case
        Just s -> return s
        Nothing -> uncurry withBlockDB db $ getSpender op

getSpendersI :: MonadIO m => TxHash -> ImportDB -> m (IntMap Spender)
getSpendersI t ImportDB {importRocksDB = db, importHashMap = hm} = do
    hsm <- getSpendersH t <$> readTVarIO hm
    dsm <- I.map Just <$> uncurry withBlockDB db (getSpenders t)
    return . I.map fromJust . I.filter isJust $ hsm <> dsm

getBalanceI :: MonadIO m => Address -> ImportDB -> m (Maybe Balance)
getBalanceI a ImportDB {importCache = (_, bm), importHashMap = hm} =
    atomically (runMaybeT (MaybeT hashmap <|> MaybeT cached))
  where
    hashmap = withBlockSTM hm (getBalance a)
    cached = withBalanceSTM bm (getBalance a)

setBalanceI :: MonadIO m => Balance -> ImportDB -> m ()
setBalanceI b ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ setBalance b

getUnspentI :: MonadIO m => OutPoint -> ImportDB -> m (Maybe Unspent)
getUnspentI op ImportDB {importCache = (um, _), importHashMap = hm} =
    join <$> atomically (runMaybeT (MaybeT hashmap <|> MaybeT cached))
  where
    hashmap = getUnspentH op <$> readTVar hm
    cached = Just <$> withUnspentSTM um (getUnspent op)

addUnspentI :: MonadIO m => Unspent -> ImportDB -> m ()
addUnspentI u ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ addUnspent u

delUnspentI :: MonadIO m => OutPoint -> ImportDB -> m ()
delUnspentI p ImportDB {importHashMap = hm} =
    atomically . withBlockSTM hm $ delUnspent p

getMempoolI ::
       MonadUnliftIO m
    => Maybe UnixTime
    -> ImportDB
    -> ConduitT () (UnixTime, TxHash) m ()
getMempoolI mpu ImportDB {importHashMap = hm, importRocksDB = db} = do
    h <- hMempool <$> readTVarIO hm
    let hmap =
            M.fromList . filter tfilter $
            concatMap
                (\(u, l) -> map (\(t, b) -> ((u, t), b)) (M.toList l))
                (M.toList h)
    dmap <-
        lift .
        fmap M.fromList . runResourceT . uncurry withBlockDB db . runConduit $
        getMempool mpu .| mapC (, True) .| sinkList
    let rmap = M.filter id (M.union hmap dmap)
    yieldMany $ sortBy (flip compare) (M.keys rmap)
  where
    tfilter =
        case mpu of
            Just x  -> (<= x) . fst . fst
            Nothing -> const True

instance MonadIO m => StoreRead (ReaderT ImportDB m) where
    isInitialized = R.ask >>= isInitializedI
    getBestBlock = R.ask >>= getBestBlockI
    getBlocksAtHeight h = R.ask >>= getBlocksAtHeightI h
    getBlock b = R.ask >>= getBlockI b
    getTxData t = R.ask >>= getTxDataI t
    getSpender p = R.ask >>= getSpenderI p
    getSpenders t = R.ask >>= getSpendersI t
    getOrphanTx h = R.ask >>= getOrphanTxI h

instance MonadIO m => StoreWrite (ReaderT ImportDB m) where
    setInit = R.ask >>= setInitI
    setBest h = R.ask >>= setBestI h
    insertBlock b = R.ask >>= insertBlockI b
    insertAtHeight b h = R.ask >>= insertAtHeightI b h
    insertTx t = R.ask >>= insertTxI t
    insertSpender p s = R.ask >>= insertSpenderI p s
    deleteSpender p = R.ask >>= deleteSpenderI p
    insertAddrTx a t = R.ask >>= insertAddrTxI a t
    removeAddrTx a t = R.ask >>= removeAddrTxI a t
    insertAddrUnspent a u = R.ask >>= insertAddrUnspentI a u
    removeAddrUnspent a u = R.ask >>= removeAddrUnspentI a u
    insertMempoolTx t p = R.ask >>= insertMempoolTxI t p
    deleteMempoolTx t p = R.ask >>= deleteMempoolTxI t p
    insertOrphanTx t p = R.ask >>= insertOrphanTxI t p
    deleteOrphanTx t = R.ask >>= deleteOrphanTxI t

instance MonadIO m => UnspentRead (ReaderT ImportDB m) where
    getUnspent a = R.ask >>= getUnspentI a

instance MonadIO m => UnspentWrite (ReaderT ImportDB m) where
    addUnspent u = R.ask >>= addUnspentI u
    delUnspent p = R.ask >>= delUnspentI p

instance MonadIO m => BalanceRead (ReaderT ImportDB m) where
    getBalance a = R.ask >>= getBalanceI a

instance MonadIO m => BalanceWrite (ReaderT ImportDB m) where
    setBalance b = R.ask >>= setBalanceI b
