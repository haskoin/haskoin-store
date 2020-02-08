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
import           Data.HashMap.Strict                 (HashMap)
import qualified Data.HashMap.Strict                 as M
import           Data.IntMap.Strict                  (IntMap)
import qualified Data.IntMap.Strict                  as I
import           Data.List
import           Data.Maybe
import           Database.RocksDB                    (BatchOp)
import           Database.RocksDB.Query
import           Haskoin
import           Network.Haskoin.Store.Data.KeyValue
import           Network.Haskoin.Store.Data.Memory
import           Network.Haskoin.Store.Data.RocksDB
import           Network.Haskoin.Store.Data.Types
import           UnliftIO

data ImportDB = ImportDB
    { importDB      :: !BlockDB
    , importHashMap :: !(TVar BlockMem)
    }

runImportDB ::
       (MonadError e m, MonadLoggerIO m)
    => BlockDB
    -> ReaderT ImportDB m a
    -> m a
runImportDB bdb@BlockDB {blockDB = db} f = do
    hm <- newTVarIO emptyBlockMem
    x <- R.runReaderT f ImportDB {importDB = bdb, importHashMap = hm}
    ops <- hashMapOps <$> readTVarIO hm
    $(logDebugS) "ImportDB" "Committing changes to database"
    writeBatch db ops
    $(logDebugS) "ImportDB" "Finished committing changes to database"
    return x

hashMapOps :: BlockMem -> [BatchOp]
hashMapOps db =
    bestBlockOp (hBest db) <>
    blockHashOps (hBlock db) <>
    blockHeightOps (hHeight db) <>
    txOps (hTx db) <>
    spenderOps (hSpender db) <>
    balOps (hBalance db) <>
    addrTxOps (hAddrTx db) <>
    addrOutOps (hAddrOut db) <>
    maybeToList (mempoolOp <$> hMempool db) <>
    orphanOps (hOrphans db) <>
    unspentOps (hUnspent db)

cacheMapOps :: BlockMem -> [BatchOp]
cacheMapOps db =
    balOps (hBalance db) <> maybeToList (mempoolOp <$> hMempool db) <>
    addrTxOps (hAddrTx db) <>
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

mempoolOp :: [(UnixTime, TxHash)] -> BatchOp
mempoolOp = insertOp MemKey

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
    g h i Nothing  = deleteOp (UnspentKey (OutPoint h (fromIntegral i)))

isInitializedI :: MonadIO m => ImportDB -> m (Either InitException Bool)
isInitializedI ImportDB {importDB = db} =
    withRocksDB db isInitialized

setInitI :: MonadIO m => ImportDB -> m ()
setInitI ImportDB {importDB = BlockDB {blockDB = db}, importHashMap = hm} = do
    withBlockMem hm setInit
    setInitDB db

setBestI :: MonadIO m => BlockHash -> ImportDB -> m ()
setBestI bh ImportDB {importHashMap = hm} =
    withBlockMem hm $ setBest bh

insertBlockI :: MonadIO m => BlockData -> ImportDB -> m ()
insertBlockI b ImportDB {importHashMap = hm} =
    withBlockMem hm $ insertBlock b

setBlocksAtHeightI :: MonadIO m => [BlockHash] -> BlockHeight -> ImportDB -> m ()
setBlocksAtHeightI hs g ImportDB {importHashMap = hm} =
    withBlockMem hm $ setBlocksAtHeight hs g

insertTxI :: MonadIO m => TxData -> ImportDB -> m ()
insertTxI t ImportDB {importHashMap = hm} =
    withBlockMem hm $ insertTx t

insertSpenderI :: MonadIO m => OutPoint -> Spender -> ImportDB -> m ()
insertSpenderI p s ImportDB {importHashMap = hm} =
    withBlockMem hm $ insertSpender p s

deleteSpenderI :: MonadIO m => OutPoint -> ImportDB -> m ()
deleteSpenderI p ImportDB {importHashMap = hm} =
    withBlockMem hm $ deleteSpender p

insertAddrTxI :: MonadIO m => Address -> BlockTx -> ImportDB -> m ()
insertAddrTxI a t ImportDB {importHashMap = hm} =
    withBlockMem hm $ insertAddrTx a t

deleteAddrTxI :: MonadIO m => Address -> BlockTx -> ImportDB -> m ()
deleteAddrTxI a t ImportDB {importHashMap = hm} =
    withBlockMem hm $ deleteAddrTx a t

insertAddrUnspentI :: MonadIO m => Address -> Unspent -> ImportDB -> m ()
insertAddrUnspentI a u ImportDB {importHashMap = hm} =
    withBlockMem hm $ insertAddrUnspent a u

deleteAddrUnspentI :: MonadIO m => Address -> Unspent -> ImportDB -> m ()
deleteAddrUnspentI a u ImportDB {importHashMap = hm} =
    withBlockMem hm $ deleteAddrUnspent a u

setMempoolI :: MonadIO m => [(UnixTime, TxHash)] -> ImportDB -> m ()
setMempoolI xs ImportDB {importHashMap = hm} = withBlockMem hm $ setMempool xs

insertOrphanTxI :: MonadIO m => Tx -> UnixTime -> ImportDB -> m ()
insertOrphanTxI t p ImportDB {importHashMap = hm} =
    withBlockMem hm $ insertOrphanTx t p

deleteOrphanTxI :: MonadIO m => TxHash -> ImportDB -> m ()
deleteOrphanTxI t ImportDB {importHashMap = hm} =
    withBlockMem hm $ deleteOrphanTx t

getBestBlockI :: MonadIO m => ImportDB -> m (Maybe BlockHash)
getBestBlockI ImportDB {importHashMap = hm, importDB = db} =
    runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = withBlockMem hm getBestBlock
    g = withRocksDB db getBestBlock

getBlocksAtHeightI :: MonadIO m => BlockHeight -> ImportDB -> m [BlockHash]
getBlocksAtHeightI bh ImportDB {importHashMap = hm, importDB = db} = do
    xs <- withBlockMem hm $ getBlocksAtHeight bh
    ys <- withRocksDB db $ getBlocksAtHeight bh
    return . nub $ xs <> ys

getBlockI :: MonadIO m => BlockHash -> ImportDB -> m (Maybe BlockData)
getBlockI bh ImportDB {importDB = db, importHashMap = hm} =
    runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = withBlockMem hm $ getBlock bh
    g = withRocksDB db $ getBlock bh

getTxDataI ::
       MonadIO m => TxHash -> ImportDB -> m (Maybe TxData)
getTxDataI th ImportDB {importDB = db, importHashMap = hm} =
    runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = withBlockMem hm $ getTxData th
    g = withRocksDB db $ getTxData th

getOrphanTxI :: MonadIO m => TxHash -> ImportDB -> m (Maybe (UnixTime, Tx))
getOrphanTxI h ImportDB {importDB = db, importHashMap = hm} =
    fmap join . runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = getOrphanTxH h <$> readTVarIO hm
    g = Just <$> withRocksDB db (getOrphanTx h)

getSpenderI :: MonadIO m => OutPoint -> ImportDB -> m (Maybe Spender)
getSpenderI op ImportDB {importDB = db, importHashMap = hm} =
    fmap join . runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = getSpenderH op <$> readTVarIO hm
    g = Just <$> withRocksDB db (getSpender op)

getSpendersI :: MonadIO m => TxHash -> ImportDB -> m (IntMap Spender)
getSpendersI t ImportDB {importDB = db, importHashMap = hm} = do
    hsm <- getSpendersH t <$> readTVarIO hm
    dsm <- I.map Just <$> withRocksDB db (getSpenders t)
    return . I.map fromJust . I.filter isJust $ hsm <> dsm

getBalanceI :: MonadIO m => Address -> ImportDB -> m (Maybe Balance)
getBalanceI a ImportDB {importDB = db, importHashMap = hm} =
    runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = withBlockMem hm $ getBalance a
    g = withRocksDB db $ getBalance a

setBalanceI :: MonadIO m => Balance -> ImportDB -> m ()
setBalanceI b ImportDB {importHashMap = hm} =
    withBlockMem hm $ setBalance b

getUnspentI :: MonadIO m => OutPoint -> ImportDB -> m (Maybe Unspent)
getUnspentI op ImportDB {importDB = db, importHashMap = hm} =
    fmap join . runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = getUnspentH op <$> readTVarIO hm
    g = Just <$> withRocksDB db (getUnspent op)

insertUnspentI :: MonadIO m => Unspent -> ImportDB -> m ()
insertUnspentI u ImportDB {importHashMap = hm} =
    withBlockMem hm $ insertUnspent u

deleteUnspentI :: MonadIO m => OutPoint -> ImportDB -> m ()
deleteUnspentI p ImportDB {importHashMap = hm} =
    withBlockMem hm $ deleteUnspent p

getMempoolI ::
       MonadIO m
    => ImportDB
    -> m [(UnixTime, TxHash)]
getMempoolI ImportDB {importHashMap = hm, importDB = db} =
    getMempoolH <$> readTVarIO hm >>= \case
        Just xs -> return xs
        Nothing -> withRocksDB db getMempool

instance MonadIO m => StoreRead (ReaderT ImportDB m) where
    isInitialized = R.ask >>= isInitializedI
    getBestBlock = R.ask >>= getBestBlockI
    getBlocksAtHeight h = R.ask >>= getBlocksAtHeightI h
    getBlock b = R.ask >>= getBlockI b
    getTxData t = R.ask >>= getTxDataI t
    getSpender p = R.ask >>= getSpenderI p
    getSpenders t = R.ask >>= getSpendersI t
    getOrphanTx h = R.ask >>= getOrphanTxI h
    getUnspent a = R.ask >>= getUnspentI a
    getBalance a = R.ask >>= getBalanceI a
    getMempool = R.ask >>= getMempoolI

instance MonadIO m => StoreWrite (ReaderT ImportDB m) where
    setInit = R.ask >>= setInitI
    setBest h = R.ask >>= setBestI h
    insertBlock b = R.ask >>= insertBlockI b
    setBlocksAtHeight hs g = R.ask >>= setBlocksAtHeightI hs g
    insertTx t = R.ask >>= insertTxI t
    insertSpender p s = R.ask >>= insertSpenderI p s
    deleteSpender p = R.ask >>= deleteSpenderI p
    insertAddrTx a t = R.ask >>= insertAddrTxI a t
    deleteAddrTx a t = R.ask >>= deleteAddrTxI a t
    insertAddrUnspent a u = R.ask >>= insertAddrUnspentI a u
    deleteAddrUnspent a u = R.ask >>= deleteAddrUnspentI a u
    setMempool xs = R.ask >>= setMempoolI xs
    insertOrphanTx t p = R.ask >>= insertOrphanTxI t p
    deleteOrphanTx t = R.ask >>= deleteOrphanTxI t
    insertUnspent u = R.ask >>= insertUnspentI u
    deleteUnspent p = R.ask >>= deleteUnspentI p
    setBalance b = R.ask >>= setBalanceI b

instance MonadIO m => StoreStream (ReaderT ImportDB m) where
    getOrphans = undefined
    getAddressUnspents _ _ = undefined
    getAddressTxs _ _ = undefined
    getAddressBalances = undefined
    getUnspents = undefined
