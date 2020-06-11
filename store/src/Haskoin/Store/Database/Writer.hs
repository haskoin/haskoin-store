{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
module Haskoin.Store.Database.Writer
    ( DatabaseWriter
    , runDatabaseWriter
    ) where

import           Control.Applicative           ((<|>))
import           Control.DeepSeq               (NFData)
import           Control.Monad.Except          (MonadError)
import           Control.Monad.Reader          (ReaderT)
import qualified Control.Monad.Reader          as R
import           Control.Monad.Trans.Maybe     (MaybeT (..), runMaybeT)
import qualified Data.ByteString.Short         as B.Short
import           Data.Hashable                 (Hashable)
import           Data.HashMap.Strict           (HashMap)
import qualified Data.HashMap.Strict           as M
import           Data.IntMap.Strict            (IntMap)
import qualified Data.IntMap.Strict            as I
import           Data.Maybe                    (fromJust, isJust, maybeToList)
import           Database.RocksDB              (BatchOp)
import           Database.RocksDB.Query        (deleteOp, insertOp, writeBatch)
import           GHC.Generics                  (Generic)
import           Haskoin                       (Address, BlockHash, BlockHeight,
                                                OutPoint (..), TxHash,
                                                headerHash, txHash)
import           Haskoin.Store.Common          (StoreRead (..), StoreWrite (..))
import           Haskoin.Store.Data            (Balance (..), BlockData (..),
                                                BlockRef (..), Spender,
                                                TxData (..), TxRef (..),
                                                Unspent (..))
import           Haskoin.Store.Database.Reader (DatabaseReader (..),
                                                withDatabaseReader)
import           Haskoin.Store.Database.Types  (AddrOutKey (..), AddrTxKey (..),
                                                BalKey (..), BalVal (..),
                                                BestKey (..), BlockKey (..),
                                                HeightKey (..), MemKey (..),
                                                OutVal (..), SpenderKey (..),
                                                TxKey (..), UnspentKey (..),
                                                UnspentVal (..), balanceToVal,
                                                unspentToVal, valToBalance,
                                                valToUnspent)
import           UnliftIO                      (MonadIO, TVar, atomically,
                                                modifyTVar, newTVarIO,
                                                readTVarIO)

data Dirty a = Modified a | Deleted
    deriving (Eq, Show, Generic, Hashable, NFData)

instance Functor Dirty where
    fmap _ Deleted      = Deleted
    fmap f (Modified a) = Modified (f a)

data DatabaseWriter = DatabaseWriter
    { databaseWriterReader :: !DatabaseReader
    , databaseWriterState  :: !(TVar MemoryDatabase)
    }

data MemoryDatabase = MemoryDatabase
    { hBest
      :: !(Maybe BlockHash)
    , hBlock
      :: !(HashMap BlockHash BlockData)
    , hHeight
      :: !(HashMap BlockHeight [BlockHash])
    , hTx
      :: !(HashMap TxHash TxData)
    , hSpender
      :: !(HashMap TxHash (IntMap (Dirty Spender)))
    , hUnspent
      :: !(HashMap TxHash (IntMap (Dirty UnspentVal)))
    , hBalance
      :: !(HashMap Address BalVal)
    , hAddrTx
      :: !(HashMap Address (HashMap TxRef (Dirty ())))
    , hAddrOut
      :: !(HashMap Address (HashMap BlockRef (HashMap OutPoint (Dirty OutVal))))
    , hMempool
      :: !(Maybe [TxRef])
    } deriving (Eq, Show)

instance MonadIO m => StoreWrite (ReaderT (TVar MemoryDatabase) m) where
    setBest h = do
        v <- R.ask
        atomically $ modifyTVar v (setBestH h)
    insertBlock b = do
        v <- R.ask
        atomically $ modifyTVar v (insertBlockH b)
    setBlocksAtHeight h g = do
        v <- R.ask
        atomically $ modifyTVar v (setBlocksAtHeightH h g)
    insertTx t = do
        v <- R.ask
        atomically $ modifyTVar v (insertTxH t)
    insertSpender p s = do
        v <- R.ask
        atomically $ modifyTVar v (insertSpenderH p s)
    deleteSpender p = do
        v <- R.ask
        atomically $ modifyTVar v (deleteSpenderH p)
    insertAddrTx a t = do
        v <- R.ask
        atomically $ modifyTVar v (insertAddrTxH a t)
    deleteAddrTx a t = do
        v <- R.ask
        atomically $ modifyTVar v (deleteAddrTxH a t)
    insertAddrUnspent a u = do
        v <- R.ask
        atomically $ modifyTVar v (insertAddrUnspentH a u)
    deleteAddrUnspent a u = do
        v <- R.ask
        atomically $ modifyTVar v (deleteAddrUnspentH a u)
    setMempool xs = do
        v <- R.ask
        atomically $ modifyTVar v (setMempoolH xs)
    setBalance b = do
        v <- R.ask
        atomically $ modifyTVar v (setBalanceH b)
    insertUnspent h = do
        v <- R.ask
        atomically $ modifyTVar v (insertUnspentH h)
    deleteUnspent p = do
        v <- R.ask
        atomically $ modifyTVar v (deleteUnspentH p)

runDatabaseWriter ::
       (MonadIO m, MonadError e m)
    => DatabaseReader
    -> ReaderT DatabaseWriter m a
    -> m a
runDatabaseWriter bdb@DatabaseReader{databaseHandle = db} f = do
    hm <- newTVarIO emptyMemoryDatabase
    x <-
        R.runReaderT
            f
            DatabaseWriter
                { databaseWriterReader = bdb
                , databaseWriterState = hm }
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

spenderOps :: HashMap TxHash (IntMap (Dirty Spender)) -> [BatchOp]
spenderOps = concatMap (uncurry f) . M.toList
  where
    f h = map (uncurry (g h)) . I.toList
    g h i (Modified s) = insertOp (SpenderKey (OutPoint h (fromIntegral i))) s
    g h i Deleted      = deleteOp (SpenderKey (OutPoint h (fromIntegral i)))

balOps :: HashMap Address BalVal -> [BatchOp]
balOps = map (uncurry f) . M.toList
  where
    f = insertOp . BalKey

addrTxOps ::
       HashMap Address (HashMap TxRef (Dirty ())) -> [BatchOp]
addrTxOps = concatMap (uncurry f) . M.toList
  where
    f a = map (uncurry (g a)) . M.toList
    g a t (Modified ()) = insertOp (AddrTxKey a t) ()
    g a t Deleted       = deleteOp (AddrTxKey a t)

addrOutOps ::
       HashMap Address (HashMap BlockRef (HashMap OutPoint (Dirty OutVal)))
    -> [BatchOp]
addrOutOps = concat . concatMap (uncurry f) . M.toList
  where
    f a = map (uncurry (g a)) . M.toList
    g a b = map (uncurry (h a b)) . M.toList
    h a b p (Modified l) =
        insertOp
            (AddrOutKey {addrOutKeyA = a, addrOutKeyB = b, addrOutKeyP = p})
            l
    h a b p Deleted =
        deleteOp AddrOutKey {addrOutKeyA = a, addrOutKeyB = b, addrOutKeyP = p}

mempoolOp :: [TxRef] -> BatchOp
mempoolOp =
    insertOp MemKey .
    map (\TxRef {txRefBlock = MemRef t, txRefHash = h} -> (t, h))

unspentOps :: HashMap TxHash (IntMap (Dirty UnspentVal)) -> [BatchOp]
unspentOps = concatMap (uncurry f) . M.toList
  where
    f h = map (uncurry (g h)) . I.toList
    g h i (Modified u) = insertOp (UnspentKey (OutPoint h (fromIntegral i))) u
    g h i Deleted      = deleteOp (UnspentKey (OutPoint h (fromIntegral i)))

setBestI :: MonadIO m => BlockHash -> DatabaseWriter -> m ()
setBestI bh DatabaseWriter {databaseWriterState = hm} =
    withMemoryDatabase hm $ setBest bh

insertBlockI :: MonadIO m => BlockData -> DatabaseWriter -> m ()
insertBlockI b DatabaseWriter {databaseWriterState = hm} =
    withMemoryDatabase hm $ insertBlock b

setBlocksAtHeightI
    :: MonadIO m => [BlockHash] -> BlockHeight -> DatabaseWriter -> m ()
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

insertAddrTxI :: MonadIO m => Address -> TxRef -> DatabaseWriter -> m ()
insertAddrTxI a t DatabaseWriter {databaseWriterState = hm} =
    withMemoryDatabase hm $ insertAddrTx a t

deleteAddrTxI :: MonadIO m => Address -> TxRef -> DatabaseWriter -> m ()
deleteAddrTxI a t DatabaseWriter {databaseWriterState = hm} =
    withMemoryDatabase hm $ deleteAddrTx a t

insertAddrUnspentI :: MonadIO m => Address -> Unspent -> DatabaseWriter -> m ()
insertAddrUnspentI a u DatabaseWriter {databaseWriterState = hm} =
    withMemoryDatabase hm $ insertAddrUnspent a u

deleteAddrUnspentI :: MonadIO m => Address -> Unspent -> DatabaseWriter -> m ()
deleteAddrUnspentI a u DatabaseWriter {databaseWriterState = hm} =
    withMemoryDatabase hm $ deleteAddrUnspent a u

setMempoolI :: MonadIO m => [TxRef] -> DatabaseWriter -> m ()
setMempoolI xs DatabaseWriter {databaseWriterState = hm} =
    withMemoryDatabase hm $ setMempool xs

getBestBlockI :: MonadIO m => DatabaseWriter -> m (Maybe BlockHash)
getBestBlockI
    DatabaseWriter {databaseWriterState = hm, databaseWriterReader = db} =
    runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = getBestBlockH <$> readTVarIO hm
    g = withDatabaseReader db getBestBlock

getBlocksAtHeightI :: MonadIO m => BlockHeight -> DatabaseWriter -> m [BlockHash]
getBlocksAtHeightI
    bh
    DatabaseWriter {databaseWriterState = hm, databaseWriterReader = db} =
    getBlocksAtHeightH bh <$> readTVarIO hm >>= \case
    Just bs -> return bs
    Nothing -> withDatabaseReader db $ getBlocksAtHeight bh

getBlockI :: MonadIO m => BlockHash -> DatabaseWriter -> m (Maybe BlockData)
getBlockI
    bh
    DatabaseWriter {databaseWriterReader = db, databaseWriterState = hm} =
    runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = getBlockH bh <$> readTVarIO hm
    g = withDatabaseReader db $ getBlock bh

getTxDataI ::
       MonadIO m => TxHash -> DatabaseWriter -> m (Maybe TxData)
getTxDataI
    th
    DatabaseWriter {databaseWriterReader = db, databaseWriterState = hm} =
    runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = getTxDataH th <$> readTVarIO hm
    g = withDatabaseReader db $ getTxData th

getSpenderI :: MonadIO m => OutPoint -> DatabaseWriter -> m (Maybe Spender)
getSpenderI
    op
    DatabaseWriter {databaseWriterReader = db, databaseWriterState = hm} =
    getSpenderH op <$> readTVarIO hm >>= \case
    Just (Modified s) -> return (Just s)
    Just Deleted -> return Nothing
    Nothing -> withDatabaseReader db (getSpender op)

getSpendersI :: MonadIO m => TxHash -> DatabaseWriter -> m (IntMap Spender)
getSpendersI
    t
    DatabaseWriter {databaseWriterReader = db, databaseWriterState = hm} = do
    hsm <- fmap to_maybe . getSpendersH t <$> readTVarIO hm
    dsm <- fmap Just <$> withDatabaseReader db (getSpenders t)
    return $ I.map fromJust $ I.filter isJust $ hsm <> dsm
  where
    to_maybe Deleted      = Nothing
    to_maybe (Modified x) = Just x

getBalanceI :: MonadIO m => Address -> DatabaseWriter -> m Balance
getBalanceI
    a
    DatabaseWriter { databaseWriterReader = db, databaseWriterState = hm} =
    getBalanceH a <$> readTVarIO hm >>= \case
    Just b -> return $ valToBalance a b
    Nothing -> withDatabaseReader db $ getBalance a

setBalanceI :: MonadIO m => Balance -> DatabaseWriter -> m ()
setBalanceI b DatabaseWriter {databaseWriterState = hm} =
    withMemoryDatabase hm $ setBalance b

getUnspentI :: MonadIO m => OutPoint -> DatabaseWriter -> m (Maybe Unspent)
getUnspentI
    op
    DatabaseWriter
    { databaseWriterReader = db
    , databaseWriterState = hm
    } = getUnspentH op <$> readTVarIO hm >>= \case
    Just Deleted -> return Nothing
    Just (Modified u) -> return (Just (valToUnspent op u))
    Nothing -> withDatabaseReader db (getUnspent op)

insertUnspentI :: MonadIO m => Unspent -> DatabaseWriter -> m ()
insertUnspentI u DatabaseWriter {databaseWriterState = hm} =
    withMemoryDatabase hm $ insertUnspent u

deleteUnspentI :: MonadIO m => OutPoint -> DatabaseWriter -> m ()
deleteUnspentI p DatabaseWriter {databaseWriterState = hm} =
    withMemoryDatabase hm $ deleteUnspent p

getMempoolI ::
       MonadIO m
    => DatabaseWriter
    -> m [TxRef]
getMempoolI DatabaseWriter {databaseWriterState = hm, databaseWriterReader = db} =
    getMempoolH <$> readTVarIO hm >>= \case
        Just xs -> return xs
        Nothing -> withDatabaseReader db getMempool

instance MonadIO m => StoreRead (ReaderT DatabaseWriter m) where
    getInitialGap = R.asks (databaseInitialGap . databaseWriterReader)
    getNetwork = R.asks (databaseNetwork . databaseWriterReader)
    getBestBlock = R.ask >>= getBestBlockI
    getBlocksAtHeight h = R.ask >>= getBlocksAtHeightI h
    getBlock b = R.ask >>= getBlockI b
    getTxData t = R.ask >>= getTxDataI t
    getSpender p = R.ask >>= getSpenderI p
    getSpenders t = R.ask >>= getSpendersI t
    getUnspent a = R.ask >>= getUnspentI a
    getBalance a = R.ask >>= getBalanceI a
    getMempool = R.ask >>= getMempoolI
    getAddressesTxs = undefined
    getAddressesUnspents = undefined
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
    insertUnspent u = R.ask >>= insertUnspentI u
    deleteUnspent p = R.ask >>= deleteUnspentI p
    setBalance b = R.ask >>= setBalanceI b

withMemoryDatabase ::
       MonadIO m
    => TVar MemoryDatabase
    -> ReaderT (TVar MemoryDatabase) m a
    -> m a
withMemoryDatabase = flip R.runReaderT

emptyMemoryDatabase :: MemoryDatabase
emptyMemoryDatabase =
    MemoryDatabase
        { hBest = Nothing
        , hBlock = M.empty
        , hHeight = M.empty
        , hTx = M.empty
        , hSpender = M.empty
        , hUnspent = M.empty
        , hBalance = M.empty
        , hAddrTx = M.empty
        , hAddrOut = M.empty
        , hMempool = Nothing
        }

getBestBlockH :: MemoryDatabase -> Maybe BlockHash
getBestBlockH = hBest

getBlocksAtHeightH :: BlockHeight -> MemoryDatabase -> Maybe [BlockHash]
getBlocksAtHeightH h = M.lookup h . hHeight

getBlockH :: BlockHash -> MemoryDatabase -> Maybe BlockData
getBlockH h = M.lookup h . hBlock

getTxDataH :: TxHash -> MemoryDatabase -> Maybe TxData
getTxDataH t = M.lookup t . hTx

getSpenderH :: OutPoint -> MemoryDatabase -> Maybe (Dirty Spender)
getSpenderH op db = do
    m <- M.lookup (outPointHash op) (hSpender db)
    I.lookup (fromIntegral (outPointIndex op)) m

getSpendersH :: TxHash -> MemoryDatabase -> IntMap (Dirty Spender)
getSpendersH t = M.lookupDefault I.empty t . hSpender

getBalanceH :: Address -> MemoryDatabase -> Maybe BalVal
getBalanceH a = M.lookup a . hBalance

getMempoolH :: MemoryDatabase -> Maybe [TxRef]
getMempoolH = hMempool

setBestH :: BlockHash -> MemoryDatabase -> MemoryDatabase
setBestH h db = db {hBest = Just h}

insertBlockH :: BlockData -> MemoryDatabase -> MemoryDatabase
insertBlockH bd db =
    db { hBlock = M.insert (headerHash (blockDataHeader bd)) bd (hBlock db) }

setBlocksAtHeightH
    :: [BlockHash] -> BlockHeight -> MemoryDatabase -> MemoryDatabase
setBlocksAtHeightH hs g db = db {hHeight = M.insert g hs (hHeight db)}

insertTxH :: TxData -> MemoryDatabase -> MemoryDatabase
insertTxH tx db = db {hTx = M.insert (txHash (txData tx)) tx (hTx db)}

insertSpenderH :: OutPoint -> Spender -> MemoryDatabase -> MemoryDatabase
insertSpenderH op s db =
    db
        { hSpender =
              M.insertWith
                  (<>)
                  (outPointHash op)
                  (I.singleton (fromIntegral (outPointIndex op)) (Modified s))
                  (hSpender db)
        }

deleteSpenderH :: OutPoint -> MemoryDatabase -> MemoryDatabase
deleteSpenderH op db =
    db
        { hSpender =
              M.insertWith
                  (<>)
                  (outPointHash op)
                  (I.singleton (fromIntegral (outPointIndex op)) Deleted)
                  (hSpender db)
        }

setBalanceH :: Balance -> MemoryDatabase -> MemoryDatabase
setBalanceH bal db =
    db {hBalance = M.insert (balanceAddress bal) b (hBalance db)}
  where
    b = balanceToVal bal

insertAddrTxH :: Address -> TxRef -> MemoryDatabase -> MemoryDatabase
insertAddrTxH a btx db =
    db
        { hAddrTx =
              M.insertWith
                  (<>)
                  a
                  (M.singleton btx (Modified ()))
                  (hAddrTx db)
        }

deleteAddrTxH :: Address -> TxRef -> MemoryDatabase -> MemoryDatabase
deleteAddrTxH a btx db =
    db
        { hAddrTx =
              M.insertWith
                  (<>)
                  a
                  (M.singleton btx Deleted)
                  (hAddrTx db)
        }

insertAddrUnspentH :: Address -> Unspent -> MemoryDatabase -> MemoryDatabase
insertAddrUnspentH a u db =
    let uns =
            OutVal
                { outValAmount = unspentAmount u
                , outValScript = B.Short.fromShort (unspentScript u)
                }
        s =
            M.singleton
                a
                (M.singleton
                     (unspentBlock u)
                     (M.singleton (unspentPoint u) (Modified uns)))
     in db {hAddrOut = M.unionWith (M.unionWith M.union) s (hAddrOut db)}

deleteAddrUnspentH :: Address -> Unspent -> MemoryDatabase -> MemoryDatabase
deleteAddrUnspentH a u db =
    let s =
            M.singleton
                a
                (M.singleton
                     (unspentBlock u)
                     (M.singleton (unspentPoint u) Deleted))
     in db {hAddrOut = M.unionWith (M.unionWith M.union) s (hAddrOut db)}

setMempoolH :: [TxRef] -> MemoryDatabase -> MemoryDatabase
setMempoolH xs db = db {hMempool = Just xs}

getUnspentH :: OutPoint -> MemoryDatabase -> Maybe (Dirty UnspentVal)
getUnspentH op db = do
    m <- M.lookup (outPointHash op) (hUnspent db)
    I.lookup (fromIntegral (outPointIndex op)) m

insertUnspentH :: Unspent -> MemoryDatabase -> MemoryDatabase
insertUnspentH u db =
    db
        { hUnspent =
              M.insertWith
                  (<>)
                  (outPointHash (unspentPoint u))
                  (I.singleton
                       (fromIntegral (outPointIndex (unspentPoint u)))
                       (Modified (snd (unspentToVal u))))
                  (hUnspent db)
        }

deleteUnspentH :: OutPoint -> MemoryDatabase -> MemoryDatabase
deleteUnspentH op db =
    db
        { hUnspent =
              M.insertWith
                  (<>)
                  (outPointHash op)
                  (I.singleton (fromIntegral (outPointIndex op)) Deleted)
                  (hUnspent db)
        }
