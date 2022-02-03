{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Haskoin.Store.Database.Writer (WriterT, runWriter) where

import Control.Monad (join)
import Control.Monad.Reader (ReaderT (..))
import qualified Control.Monad.Reader as R
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as M
import qualified Data.HashTable.IO as H
import qualified Data.IntMap.Strict as IntMap
import Data.List (sortOn)
import Data.Ord (Down (..))
import Data.Tuple (swap)
import Database.RocksDB (BatchOp, DB)
import Database.RocksDB.Query
  ( deleteOp,
    deleteOpCF,
    insertOp,
    insertOpCF,
    writeBatch,
  )
import Haskoin
  ( Address,
    BlockHash,
    BlockHeight,
    Network,
    OutPoint (..),
    TxHash,
    headerHash,
    txHash,
  )
import Haskoin.Store.Common
import Haskoin.Store.Data
import Haskoin.Store.Database.Reader
import Haskoin.Store.Database.Types
import UnliftIO
  ( IORef,
    MonadIO,
    TVar,
    atomically,
    liftIO,
    modifyIORef,
    modifyTVar,
    newIORef,
    newTVarIO,
    readIORef,
    readTVarIO,
    writeIORef,
  )

data Writer = Writer
  { getReader :: !DatabaseReader,
    getState :: !Memory
  }

type WriterT = ReaderT Writer

instance MonadIO m => StoreReadBase (WriterT m) where
  getNetwork = getNetworkI
  getBestBlock = getBestBlockI
  getBlocksAtHeight = getBlocksAtHeightI
  getBlock = getBlockI
  getTxData = getTxDataI
  getSpender = getSpenderI
  getUnspent = getUnspentI
  getBalance = getBalanceI
  getMempool = getMempoolI

type NetRef = IORef (Maybe Network)

type BestRef = IORef (Maybe (Maybe BlockHash))

type BlockTable = H.CuckooHashTable BlockHash (Maybe BlockData)

type HeightTable = H.CuckooHashTable BlockHeight [BlockHash]

type TxTable = H.CuckooHashTable TxHash (Maybe TxData)

type UnspentTable = H.CuckooHashTable OutPoint (Maybe Unspent)

type BalanceTable = H.CuckooHashTable Address (Maybe Balance)

type AddrTxTable = H.CuckooHashTable (Address, TxRef) (Maybe ())

type AddrOutTable = H.CuckooHashTable (Address, BlockRef, OutPoint) (Maybe OutVal)

type MempoolTable = H.CuckooHashTable TxHash UnixTime

data Memory = Memory
  { hNet :: !NetRef,
    hBest :: !BestRef,
    hBlock :: !BlockTable,
    hHeight :: !HeightTable,
    hTx :: !TxTable,
    hUnspent :: !UnspentTable,
    hBalance :: !BalanceTable,
    hAddrTx :: !AddrTxTable,
    hAddrOut :: !AddrOutTable,
    hMempool :: !MempoolTable
  }

instance MonadIO m => StoreWrite (WriterT m) where
  setBest h =
    ReaderT $ \Writer {getState = s} ->
      liftIO $ writeIORef (hBest s) (Just (Just h))
  insertBlock b =
    ReaderT $ \Writer {getState = s} ->
      liftIO $ H.insert (hBlock s) (headerHash (blockDataHeader b)) (Just b)
  setBlocksAtHeight h g =
    ReaderT $ \Writer {getState = s} ->
      liftIO $ H.insert (hHeight s) g h
  insertTx t =
    ReaderT $ \Writer {getState = s} ->
      liftIO $ H.insert (hTx s) (txHash (txData t)) (Just t)
  insertAddrTx a t =
    ReaderT $ \Writer {getState = s} ->
      liftIO $ H.insert (hAddrTx s) (a, t) (Just ())
  deleteAddrTx a t =
    ReaderT $ \Writer {getState = s} ->
      liftIO $ H.insert (hAddrTx s) (a, t) Nothing
  insertAddrUnspent a u =
    ReaderT $ \Writer {getState = s} ->
      liftIO $ H.insert (hAddrOut s) k (Just v)
    where
      k = (a, unspentBlock u, unspentPoint u)
      v = OutVal {outValAmount = unspentAmount u, outValScript = unspentScript u}
  deleteAddrUnspent a u =
    ReaderT $ \Writer {getState = s} ->
      liftIO $ H.insert (hAddrOut s) k Nothing
    where
      k = (a, unspentBlock u, unspentPoint u)
  addToMempool x t =
    ReaderT $ \Writer {getState = s} ->
      liftIO $ H.insert (hMempool s) x t
  deleteFromMempool x =
    ReaderT $ \Writer {getState = s} ->
      liftIO $ H.delete (hMempool s) x
  setBalance b =
    ReaderT $ \Writer {getState = s} ->
      liftIO $ H.insert (hBalance s) (balanceAddress b) (Just b)
  insertUnspent u =
    ReaderT $ \Writer {getState = s} ->
      liftIO $ H.insert (hUnspent s) (fst (unspentToVal u)) (Just u)
  deleteUnspent p =
    ReaderT $ \Writer {getState = s} ->
      liftIO $ H.insert (hUnspent s) p Nothing

getLayered ::
  MonadIO m =>
  (Memory -> IO (Maybe a)) ->
  DatabaseReaderT m a ->
  WriterT m a
getLayered f g =
  ReaderT $ \Writer {getReader = db, getState = s} ->
    liftIO (f s) >>= \case
      Just x -> return x
      Nothing -> runReaderT g db

runWriter ::
  MonadIO m =>
  DatabaseReader ->
  WriterT m a ->
  m a
runWriter bdb@DatabaseReader {databaseHandle = db} f = do
  mempool <- runReaderT getMempool bdb
  hm <- newMemory mempool
  x <- R.runReaderT f Writer {getReader = bdb, getState = hm}
  ops <- hashMapOps db hm
  writeBatch db ops
  return x

hashMapOps :: MonadIO m => DB -> Memory -> m [BatchOp]
hashMapOps db mem =
  mconcat
    <$> sequence
      [ bestBlockOp (hBest mem),
        blockHashOps db (hBlock mem),
        blockHeightOps db (hHeight mem),
        txOps db (hTx mem),
        balOps db (hBalance mem),
        addrTxOps db (hAddrTx mem),
        addrOutOps db (hAddrOut mem),
        mempoolOp (hMempool mem),
        unspentOps db (hUnspent mem)
      ]

bestBlockOp :: MonadIO m => BestRef -> m [BatchOp]
bestBlockOp r =
  readIORef r >>= \case
    Nothing -> return []
    Just Nothing -> return [deleteOp BestKey]
    Just (Just b) -> return [insertOp BestKey b]

blockHashOps :: MonadIO m => DB -> BlockTable -> m [BatchOp]
blockHashOps db t = map (uncurry f) <$> liftIO (H.toList t)
  where
    f k (Just d) = insertOpCF (blockCF db) (BlockKey k) d
    f k Nothing = deleteOpCF (blockCF db) (BlockKey k)

blockHeightOps :: MonadIO m => DB -> HeightTable -> m [BatchOp]
blockHeightOps db t = map (uncurry f) <$> liftIO (H.toList t)
  where
    f = insertOpCF (heightCF db) . HeightKey

txOps :: MonadIO m => DB -> TxTable -> m [BatchOp]
txOps db t = map (uncurry f) <$> liftIO (H.toList t)
  where
    f k (Just t) = insertOpCF (txCF db) (TxKey k) t
    f k Nothing = deleteOpCF (txCF db) (TxKey k)

balOps :: MonadIO m => DB -> BalanceTable -> m [BatchOp]
balOps db t = map (uncurry f) <$> liftIO (H.toList t)
  where
    f a (Just b) = insertOpCF (balanceCF db) (BalKey a) (balanceToVal b)
    f a Nothing = deleteOpCF (balanceCF db) (BalKey a)

addrTxOps :: MonadIO m => DB -> AddrTxTable -> m [BatchOp]
addrTxOps db t = map (uncurry f) <$> liftIO (H.toList t)
  where
    f (a, t) (Just ()) = insertOpCF (addrTxCF db) (AddrTxKey a t) ()
    f (a, t) Nothing = deleteOpCF (addrTxCF db) (AddrTxKey a t)

addrOutOps :: MonadIO m => DB -> AddrOutTable -> m [BatchOp]
addrOutOps db t = map (uncurry f) <$> liftIO (H.toList t)
  where
    f (a, b, p) (Just l) =
      insertOpCF
        (addrOutCF db)
        ( AddrOutKey
            { addrOutKeyA = a,
              addrOutKeyB = b,
              addrOutKeyP = p
            }
        )
        l
    f (a, b, p) Nothing =
      deleteOpCF
        (addrOutCF db)
        AddrOutKey
          { addrOutKeyA = a,
            addrOutKeyB = b,
            addrOutKeyP = p
          }

mempoolOp :: MonadIO m => MempoolTable -> m [BatchOp]
mempoolOp t =
  return . insertOp MemKey . sortOn Down . map swap <$> liftIO (H.toList t)

unspentOps :: MonadIO m => DB -> UnspentTable -> m [BatchOp]
unspentOps db t = map (uncurry f) <$> liftIO (H.toList t)
  where
    f p (Just u) =
      insertOpCF (unspentCF db) (UnspentKey p) (snd (unspentToVal u))
    f p Nothing =
      deleteOpCF (unspentCF db) (UnspentKey p)

getNetworkI :: MonadIO m => WriterT m Network
getNetworkI = getLayered (liftIO . readIORef . hNet) getNetwork

getBestBlockI :: MonadIO m => WriterT m (Maybe BlockHash)
getBestBlockI = getLayered getBestBlockH getBestBlock

getBlocksAtHeightI :: MonadIO m => BlockHeight -> WriterT m [BlockHash]
getBlocksAtHeightI bh =
  getLayered (getBlocksAtHeightH bh) (getBlocksAtHeight bh)

getBlockI :: MonadIO m => BlockHash -> WriterT m (Maybe BlockData)
getBlockI bh = getLayered (getBlockH bh) (getBlock bh)

getTxDataI :: MonadIO m => TxHash -> WriterT m (Maybe TxData)
getTxDataI th = getLayered (getTxDataH th) (getTxData th)

getSpenderI :: MonadIO m => OutPoint -> WriterT m (Maybe Spender)
getSpenderI op = getLayered (getSpenderH op) (getSpender op)

getBalanceI :: MonadIO m => Address -> WriterT m (Maybe Balance)
getBalanceI a = getLayered (getBalanceH a) (getBalance a)

getUnspentI :: MonadIO m => OutPoint -> WriterT m (Maybe Unspent)
getUnspentI op = getLayered (getUnspentH op) (getUnspent op)

getMempoolI :: MonadIO m => WriterT m [(UnixTime, TxHash)]
getMempoolI =
  ReaderT $ \Writer {getState = s} ->
    liftIO $ map swap <$> H.toList (hMempool s)

newMemory :: MonadIO m => [(UnixTime, TxHash)] -> m Memory
newMemory mempool = do
  hNet <- newIORef Nothing
  hBest <- newIORef Nothing
  hBlock <- liftIO H.new
  hHeight <- liftIO H.new
  hTx <- liftIO H.new
  hUnspent <- liftIO H.new
  hBalance <- liftIO H.new
  hAddrTx <- liftIO H.new
  hAddrOut <- liftIO H.new
  hMempool <- liftIO $ H.fromList (map swap mempool)
  return Memory {..}

getBestBlockH :: Memory -> IO (Maybe (Maybe BlockHash))
getBestBlockH = readIORef . hBest

getBlocksAtHeightH :: BlockHeight -> Memory -> IO (Maybe [BlockHash])
getBlocksAtHeightH h s = H.lookup (hHeight s) h

getBlockH :: BlockHash -> Memory -> IO (Maybe (Maybe BlockData))
getBlockH h s = H.lookup (hBlock s) h

getTxDataH :: TxHash -> Memory -> IO (Maybe (Maybe TxData))
getTxDataH t s = H.lookup (hTx s) t

getSpenderH :: OutPoint -> Memory -> IO (Maybe (Maybe Spender))
getSpenderH op s = do
  fmap (join . fmap f) <$> getTxDataH (outPointHash op) s
  where
    f = IntMap.lookup (fromIntegral (outPointIndex op)) . txDataSpenders

getBalanceH :: Address -> Memory -> IO (Maybe (Maybe Balance))
getBalanceH a s = H.lookup (hBalance s) a

getMempoolH :: Memory -> IO [(UnixTime, TxHash)]
getMempoolH s = sortOn Down . map swap <$> H.toList (hMempool s)

getUnspentH :: OutPoint -> Memory -> IO (Maybe (Maybe Unspent))
getUnspentH p s = H.lookup (hUnspent s) p
