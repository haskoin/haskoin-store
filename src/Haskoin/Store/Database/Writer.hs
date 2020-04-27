{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
module Haskoin.Store.Database.Writer
    ( DatabaseWriter
    , runDatabaseWriter
    ) where

import           Control.Applicative           ((<|>))
import           Control.Monad                 (join)
import           Control.Monad.Except          (MonadError)
import           Control.Monad.Reader          (ReaderT)
import qualified Control.Monad.Reader          as R
import           Control.Monad.Trans.Maybe     (MaybeT (..), runMaybeT)
import           Data.HashMap.Strict           (HashMap)
import qualified Data.HashMap.Strict           as M
import           Data.IntMap.Strict            (IntMap)
import qualified Data.IntMap.Strict            as I
import           Data.List                     (nub)
import           Data.Maybe                    (fromJust, fromMaybe, isJust,
                                                maybeToList)
import           Database.RocksDB              (BatchOp)
import           Database.RocksDB.Query        (deleteOp, insertOp, writeBatch)
import           Haskoin                       (Address, BlockHash, BlockHeight,
                                                OutPoint (..), Tx, TxHash)
import           Haskoin.Store.Common          (Balance, BlockData,
                                                BlockRef (..), BlockTx (..),
                                                Spender, StoreRead (..),
                                                StoreWrite (..), TxData,
                                                UnixTime, Unspent, nullBalance,
                                                zeroBalance)
import           Haskoin.Store.Database.Memory (MemoryDatabase (..),
                                                MemoryState (..),
                                                emptyMemoryDatabase,
                                                getMempoolH, getOrphanTxH,
                                                getSpenderH, getSpendersH,
                                                getUnspentH, withMemoryDatabase)
import           Haskoin.Store.Database.Reader (DatabaseReader (..),
                                                withDatabaseReader)
import           Haskoin.Store.Database.Types  (AddrOutKey (..), AddrTxKey (..),
                                                BalKey (..), BalVal (..),
                                                BestKey (..), BlockKey (..),
                                                HeightKey (..), MemKey (..),
                                                OrphanKey (..), OutVal,
                                                SpenderKey (..), TxKey (..),
                                                UnspentKey (..),
                                                UnspentVal (..))
import           UnliftIO                      (MonadIO, newTVarIO, readTVarIO)

data DatabaseWriter = DatabaseWriter
    { databaseWriterReader :: !DatabaseReader
    , databaseWriterState  :: !MemoryState
    }

runDatabaseWriter ::
       (MonadIO m, MonadError e m)
    => DatabaseReader
    -> ReaderT DatabaseWriter m a
    -> m a
runDatabaseWriter bdb@DatabaseReader { databaseHandle = db
                                     , databaseMaxGap = gap
                                     , databaseNetwork = net
                                     } f = do
    hm <- newTVarIO (emptyMemoryDatabase net)
    let ms = MemoryState {memoryDatabase = hm, memoryMaxGap = gap}
    x <-
        R.runReaderT
            f
            DatabaseWriter
                {databaseWriterReader = bdb, databaseWriterState = ms}
    ops <- hashMapOps <$> readTVarIO hm
    writeBatch db ops
    return x

hashMapOps :: MemoryDatabase -> [BatchOp]
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

mempoolOp :: [BlockTx] -> BatchOp
mempoolOp =
    insertOp MemKey .
    map (\BlockTx {blockTxBlock = MemRef t, blockTxHash = h} -> (t, h))

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

setBestI :: MonadIO m => BlockHash -> DatabaseWriter -> m ()
setBestI bh DatabaseWriter {databaseWriterState = hm} =
    withMemoryDatabase hm $ setBest bh

insertBlockI :: MonadIO m => BlockData -> DatabaseWriter -> m ()
insertBlockI b DatabaseWriter {databaseWriterState = hm} =
    withMemoryDatabase hm $ insertBlock b

setBlocksAtHeightI :: MonadIO m => [BlockHash] -> BlockHeight -> DatabaseWriter -> m ()
setBlocksAtHeightI hs g DatabaseWriter {databaseWriterState = hm} =
    withMemoryDatabase hm $ setBlocksAtHeight hs g

insertTxI :: MonadIO m => TxData -> DatabaseWriter -> m ()
insertTxI t DatabaseWriter {databaseWriterState = hm} =
    withMemoryDatabase hm $ insertTx t

insertSpenderI :: MonadIO m => OutPoint -> Spender -> DatabaseWriter -> m ()
insertSpenderI p s DatabaseWriter {databaseWriterState = hm} =
    withMemoryDatabase hm $ insertSpender p s

deleteSpenderI :: MonadIO m => OutPoint -> DatabaseWriter -> m ()
deleteSpenderI p DatabaseWriter {databaseWriterState = hm} =
    withMemoryDatabase hm $ deleteSpender p

insertAddrTxI :: MonadIO m => Address -> BlockTx -> DatabaseWriter -> m ()
insertAddrTxI a t DatabaseWriter {databaseWriterState = hm} =
    withMemoryDatabase hm $ insertAddrTx a t

deleteAddrTxI :: MonadIO m => Address -> BlockTx -> DatabaseWriter -> m ()
deleteAddrTxI a t DatabaseWriter {databaseWriterState = hm} =
    withMemoryDatabase hm $ deleteAddrTx a t

insertAddrUnspentI :: MonadIO m => Address -> Unspent -> DatabaseWriter -> m ()
insertAddrUnspentI a u DatabaseWriter {databaseWriterState = hm} =
    withMemoryDatabase hm $ insertAddrUnspent a u

deleteAddrUnspentI :: MonadIO m => Address -> Unspent -> DatabaseWriter -> m ()
deleteAddrUnspentI a u DatabaseWriter {databaseWriterState = hm} =
    withMemoryDatabase hm $ deleteAddrUnspent a u

setMempoolI :: MonadIO m => [BlockTx] -> DatabaseWriter -> m ()
setMempoolI xs DatabaseWriter {databaseWriterState = hm} = withMemoryDatabase hm $ setMempool xs

insertOrphanTxI :: MonadIO m => Tx -> UnixTime -> DatabaseWriter -> m ()
insertOrphanTxI t p DatabaseWriter {databaseWriterState = hm} =
    withMemoryDatabase hm $ insertOrphanTx t p

deleteOrphanTxI :: MonadIO m => TxHash -> DatabaseWriter -> m ()
deleteOrphanTxI t DatabaseWriter {databaseWriterState = hm} =
    withMemoryDatabase hm $ deleteOrphanTx t

getBestBlockI :: MonadIO m => DatabaseWriter -> m (Maybe BlockHash)
getBestBlockI DatabaseWriter {databaseWriterState = hm, databaseWriterReader = db} =
    runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = withMemoryDatabase hm getBestBlock
    g = withDatabaseReader db getBestBlock

getBlocksAtHeightI :: MonadIO m => BlockHeight -> DatabaseWriter -> m [BlockHash]
getBlocksAtHeightI bh DatabaseWriter {databaseWriterState = hm, databaseWriterReader = db} = do
    xs <- withMemoryDatabase hm $ getBlocksAtHeight bh
    ys <- withDatabaseReader db $ getBlocksAtHeight bh
    return . nub $ xs <> ys

getBlockI :: MonadIO m => BlockHash -> DatabaseWriter -> m (Maybe BlockData)
getBlockI bh DatabaseWriter {databaseWriterReader = db, databaseWriterState = hm} =
    runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = withMemoryDatabase hm $ getBlock bh
    g = withDatabaseReader db $ getBlock bh

getTxDataI ::
       MonadIO m => TxHash -> DatabaseWriter -> m (Maybe TxData)
getTxDataI th DatabaseWriter {databaseWriterReader = db, databaseWriterState = hm} =
    runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = withMemoryDatabase hm $ getTxData th
    g = withDatabaseReader db $ getTxData th

getOrphanTxI :: MonadIO m => TxHash -> DatabaseWriter -> m (Maybe (UnixTime, Tx))
getOrphanTxI h DatabaseWriter {databaseWriterReader = db, databaseWriterState = hm} =
    fmap join . runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = getOrphanTxH h <$> readTVarIO (memoryDatabase hm)
    g = Just <$> withDatabaseReader db (getOrphanTx h)

getSpenderI :: MonadIO m => OutPoint -> DatabaseWriter -> m (Maybe Spender)
getSpenderI op DatabaseWriter {databaseWriterReader = db, databaseWriterState = hm} =
    fmap join . runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = getSpenderH op <$> readTVarIO (memoryDatabase hm)
    g = Just <$> withDatabaseReader db (getSpender op)

getSpendersI :: MonadIO m => TxHash -> DatabaseWriter -> m (IntMap Spender)
getSpendersI t DatabaseWriter {databaseWriterReader = db, databaseWriterState = hm} = do
    hsm <- getSpendersH t <$> readTVarIO (memoryDatabase hm)
    dsm <- I.map Just <$> withDatabaseReader db (getSpenders t)
    return . I.map fromJust . I.filter isJust $ hsm <> dsm

getBalanceI :: MonadIO m => Address -> DatabaseWriter -> m Balance
getBalanceI a DatabaseWriter { databaseWriterReader = db
                             , databaseWriterState = hm
                             } =
    fromMaybe (zeroBalance a) <$> runMaybeT (MaybeT f <|> MaybeT g)
  where
    f =
        withMemoryDatabase hm $
        getBalance a >>= \b ->
            return $
            if nullBalance b
                then Nothing
                else Just b
    g =
        withDatabaseReader db $
        getBalance a >>= \b ->
            return $
            if nullBalance b
                then Nothing
                else Just b

setBalanceI :: MonadIO m => Balance -> DatabaseWriter -> m ()
setBalanceI b DatabaseWriter {databaseWriterState = hm} =
    withMemoryDatabase hm $ setBalance b

getUnspentI :: MonadIO m => OutPoint -> DatabaseWriter -> m (Maybe Unspent)
getUnspentI op DatabaseWriter {databaseWriterReader = db, databaseWriterState = hm} =
    fmap join . runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = getUnspentH op <$> readTVarIO (memoryDatabase hm)
    g = Just <$> withDatabaseReader db (getUnspent op)

insertUnspentI :: MonadIO m => Unspent -> DatabaseWriter -> m ()
insertUnspentI u DatabaseWriter {databaseWriterState = hm} =
    withMemoryDatabase hm $ insertUnspent u

deleteUnspentI :: MonadIO m => OutPoint -> DatabaseWriter -> m ()
deleteUnspentI p DatabaseWriter {databaseWriterState = hm} =
    withMemoryDatabase hm $ deleteUnspent p

getMempoolI ::
       MonadIO m
    => DatabaseWriter
    -> m [BlockTx]
getMempoolI DatabaseWriter {databaseWriterState = hm, databaseWriterReader = db} =
    getMempoolH <$> readTVarIO (memoryDatabase hm) >>= \case
        Just xs -> return xs
        Nothing -> withDatabaseReader db getMempool

instance MonadIO m => StoreRead (ReaderT DatabaseWriter m) where
    getNetwork = R.asks (databaseNetwork . databaseWriterReader)
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
    getAddressesTxs = undefined
    getAddressesUnspents = undefined
    getOrphans = undefined
    getMaxGap = R.asks (databaseMaxGap . databaseWriterReader)

instance MonadIO m => StoreWrite (ReaderT DatabaseWriter m) where
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
