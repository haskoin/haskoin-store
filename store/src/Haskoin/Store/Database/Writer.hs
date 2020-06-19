{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
module Haskoin.Store.Database.Writer
    ( WriterT
    , MemoryTx
    , runWriter
    , runTx
    ) where

import           Control.Applicative           ((<|>))
import           Control.DeepSeq               (NFData)
import           Control.Monad.Reader          (ReaderT (..))
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
import           UnliftIO                      (MonadIO, STM, TVar, atomically,
                                                modifyTVar, newTVarIO, readTVar,
                                                readTVarIO)

data Dirty a = Modified a | Deleted
    deriving (Eq, Show, Generic, Hashable, NFData)

instance Functor Dirty where
    fmap _ Deleted      = Deleted
    fmap f (Modified a) = Modified (f a)

data Writer = Writer { getReader :: !DatabaseReader
                     , getState  :: !(TVar Memory) }

type MemoryTx = ReaderT (TVar Memory) STM
type WriterT = ReaderT Writer

instance MonadIO m => StoreRead (WriterT m) where
    getInitialGap =
        R.asks $ databaseInitialGap . getReader
    getNetwork =
        R.asks $ databaseNetwork . getReader
    getBestBlock =
        R.ask >>= getBestBlockI
    getBlocksAtHeight h =
        R.ask >>= getBlocksAtHeightI h
    getBlock b =
        R.ask >>= getBlockI b
    getTxData t =
        R.ask >>= getTxDataI t
    getSpender p =
        R.ask >>= getSpenderI p
    getSpenders t =
        R.ask >>= getSpendersI t
    getUnspent a =
        R.ask >>= getUnspentI a
    getBalance a =
        R.ask >>= getBalanceI a
    getMempool =
        R.ask >>= getMempoolI
    getAddressesTxs =
        undefined
    getAddressesUnspents =
        undefined
    getMaxGap =
        R.asks $ databaseMaxGap . getReader

data Memory = Memory
    { hBest
      :: !(Maybe BlockHash)
    , hBlock
      :: !(HashMap BlockHash BlockData)
    , hHeight
      :: !(HashMap BlockHeight [BlockHash])
    , hTx
      :: !(HashMap TxHash TxData)
    , hSpender
      :: !(HashMap TxHash
              (IntMap (Dirty Spender)))
    , hUnspent
      :: !(HashMap TxHash
              (IntMap (Dirty UnspentVal)))
    , hBalance
      :: !(HashMap Address BalVal)
    , hAddrTx
      :: !(HashMap Address
              (HashMap TxRef (Dirty ())))
    , hAddrOut
      :: !(HashMap Address
              (HashMap BlockRef
                  (HashMap OutPoint (Dirty OutVal))))
    , hMempool
      :: !(Maybe [TxRef])
    } deriving (Eq, Show)

instance StoreWrite MemoryTx where
    setBest h =
        ReaderT $ \v -> modifyTVar v $
        setBestH h
    insertBlock b =
        ReaderT $ \v -> modifyTVar v $
        insertBlockH b
    setBlocksAtHeight h g =
        ReaderT $ \v -> modifyTVar v $
        setBlocksAtHeightH h g
    insertTx t =
        ReaderT $ \v -> modifyTVar v $
        insertTxH t
    insertSpender p s =
        ReaderT $ \v -> modifyTVar v $
        insertSpenderH p s
    deleteSpender p =
        ReaderT $ \v -> modifyTVar v $
        deleteSpenderH p
    insertAddrTx a t =
        ReaderT $ \v -> modifyTVar v $
        insertAddrTxH a t
    deleteAddrTx a t =
        ReaderT $ \v -> modifyTVar v $
        deleteAddrTxH a t
    insertAddrUnspent a u =
        ReaderT $ \v -> modifyTVar v $
        insertAddrUnspentH a u
    deleteAddrUnspent a u =
        ReaderT $ \v -> modifyTVar v $
        deleteAddrUnspentH a u
    setMempool xs =
        ReaderT $ \v -> modifyTVar v $
        setMempoolH xs
    setBalance b =
        ReaderT $ \v -> modifyTVar v $
        setBalanceH b
    insertUnspent h =
        ReaderT $ \v -> modifyTVar v $
        insertUnspentH h
    deleteUnspent p =
        ReaderT $ \v -> modifyTVar v $
        deleteUnspentH p

instance StoreRead MemoryTx where
    getInitialGap =
        error "Cannot query initial gap in STM"
    getNetwork =
        error "Cannot query network in STM"
    getBestBlock =
        error "Cannot query best block in STM"
    getBlocksAtHeight _ =
        error "Cannot query block heights in STM"
    getBlock _ =
        error "Cannot query block in STM"
    getTxData t =
        ReaderT $ fmap (getTxDataH t) . readTVar
    getSpender op =
        ReaderT $ \v -> do
        m <- getSpenderH op <$> readTVar v
        case m of
            Just (Modified s) -> return (Just s)
            Just Deleted      -> return Nothing
            Nothing           -> return Nothing
    getSpenders _ =
        error "Cannot query spenders in STM"
    getUnspent op =
        ReaderT $ \v -> do
        m <- getUnspentH op <$> readTVar v
        case m of
            Just (Modified u) -> return (Just (valToUnspent op u))
            Just Deleted      -> return Nothing
            Nothing           -> return Nothing
    getBalance a =
        ReaderT $ \v -> do
        m <- getBalanceH a <$> readTVar v
        case m of
            Just b  -> return $ valToBalance a b
            Nothing -> error "Balance not pre-loaded"
    getMempool =
        ReaderT $ \v -> do
        m <- getMempoolH <$> readTVar v
        case m of
            Just mp -> return mp
            Nothing -> error "Mempool not pre-loaded"
    getAddressesTxs = undefined
    getAddressesUnspents = undefined
    getMaxGap = error "Cannot query max gap in STM"

runWriter
    :: MonadIO m
    => DatabaseReader
    -> WriterT m a
    -> m a
runWriter bdb@DatabaseReader{databaseHandle = db} f = do
    hm <- newTVarIO emptyMemory
    x <- R.runReaderT f Writer {getReader = bdb, getState = hm}
    ops <- hashMapOps <$> readTVarIO hm
    writeBatch db ops
    return x

hashMapOps :: Memory -> [BatchOp]
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

spenderOps :: HashMap TxHash (IntMap (Dirty Spender))
           -> [BatchOp]
spenderOps = concatMap (uncurry f) . M.toList
  where
    f h = map (uncurry (g h)) . I.toList
    g h i (Modified s) =
        insertOp (SpenderKey (OutPoint h (fromIntegral i))) s
    g h i Deleted =
        deleteOp (SpenderKey (OutPoint h (fromIntegral i)))

balOps :: HashMap Address BalVal -> [BatchOp]
balOps = map (uncurry f) . M.toList
  where
    f = insertOp . BalKey

addrTxOps :: HashMap Address (HashMap TxRef (Dirty ()))
          -> [BatchOp]
addrTxOps = concatMap (uncurry f) . M.toList
  where
    f a = map (uncurry (g a)) . M.toList
    g a t (Modified ()) = insertOp (AddrTxKey a t) ()
    g a t Deleted       = deleteOp (AddrTxKey a t)

addrOutOps
    :: HashMap Address
       (HashMap BlockRef
           (HashMap OutPoint (Dirty OutVal)))
    -> [BatchOp]
addrOutOps = concat . concatMap (uncurry f) . M.toList
  where
    f a = map (uncurry (g a)) . M.toList
    g a b = map (uncurry (h a b)) . M.toList
    h a b p (Modified l) =
        insertOp
            (AddrOutKey { addrOutKeyA = a
                        , addrOutKeyB = b
                        , addrOutKeyP = p })
            l
    h a b p Deleted =
        deleteOp AddrOutKey { addrOutKeyA = a
                            , addrOutKeyB = b
                            , addrOutKeyP = p }

mempoolOp :: [TxRef] -> BatchOp
mempoolOp =
    insertOp MemKey .
    map (\TxRef { txRefBlock = MemRef t
                , txRefHash = h } -> (t, h))

unspentOps :: HashMap TxHash (IntMap (Dirty UnspentVal))
           -> [BatchOp]
unspentOps = concatMap (uncurry f) . M.toList
  where
    f h = map (uncurry (g h)) . I.toList
    g h i (Modified u) =
        insertOp (UnspentKey (OutPoint h (fromIntegral i))) u
    g h i Deleted =
        deleteOp (UnspentKey (OutPoint h (fromIntegral i)))

getBestBlockI :: MonadIO m => Writer -> m (Maybe BlockHash)
getBestBlockI Writer {getState = hm, getReader = db} =
    runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = getBestBlockH <$> readTVarIO hm
    g = withDatabaseReader db getBestBlock

getBlocksAtHeightI :: MonadIO m
                   => BlockHeight
                   -> Writer
                   -> m [BlockHash]
getBlocksAtHeightI bh Writer {getState = hm, getReader = db} =
    getBlocksAtHeightH bh <$> readTVarIO hm >>= \case
    Just bs -> return bs
    Nothing -> withDatabaseReader db $ getBlocksAtHeight bh

getBlockI :: MonadIO m
          => BlockHash
          -> Writer
          -> m (Maybe BlockData)
getBlockI bh Writer {getReader = db, getState = hm} =
    runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = getBlockH bh <$> readTVarIO hm
    g = withDatabaseReader db $ getBlock bh

getTxDataI :: MonadIO m
           => TxHash
           -> Writer
           -> m (Maybe TxData)
getTxDataI th Writer {getReader = db, getState = hm} =
    runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = getTxDataH th <$> readTVarIO hm
    g = withDatabaseReader db $ getTxData th

getSpenderI :: MonadIO m => OutPoint -> Writer -> m (Maybe Spender)
getSpenderI op Writer {getReader = db, getState = hm} =
    getSpenderH op <$> readTVarIO hm >>= \case
        Just (Modified s) -> return (Just s)
        Just Deleted -> return Nothing
        Nothing -> withDatabaseReader db (getSpender op)

getSpendersI :: MonadIO m => TxHash -> Writer -> m (IntMap Spender)
getSpendersI t Writer {getReader = db, getState = hm} = do
    hsm <- fmap to_maybe . getSpendersH t <$> readTVarIO hm
    dsm <- fmap Just <$> withDatabaseReader db (getSpenders t)
    return $ I.map fromJust $ I.filter isJust $ hsm <> dsm
  where
    to_maybe Deleted      = Nothing
    to_maybe (Modified x) = Just x

getBalanceI :: MonadIO m => Address -> Writer -> m Balance
getBalanceI a Writer {getReader = db, getState = hm} =
    getBalanceH a <$> readTVarIO hm >>= \case
        Just b -> return $ valToBalance a b
        Nothing -> withDatabaseReader db $ getBalance a

getUnspentI :: MonadIO m
            => OutPoint
            -> Writer
            -> m (Maybe Unspent)
getUnspentI op Writer {getReader = db, getState = hm} =
    getUnspentH op <$> readTVarIO hm >>= \case
        Just Deleted -> return Nothing
        Just (Modified u) -> return (Just (valToUnspent op u))
        Nothing -> withDatabaseReader db (getUnspent op)

getMempoolI :: MonadIO m => Writer -> m [TxRef]
getMempoolI Writer {getState = hm, getReader = db} =
    getMempoolH <$> readTVarIO hm >>= \case
        Just xs -> return xs
        Nothing -> withDatabaseReader db getMempool

runTx :: MonadIO m => MemoryTx a -> WriterT m a
runTx f = ReaderT $ atomically . runReaderT f . getState

emptyMemory :: Memory
emptyMemory = Memory { hBest    = Nothing
                     , hBlock   = M.empty
                     , hHeight  = M.empty
                     , hTx      = M.empty
                     , hSpender = M.empty
                     , hUnspent = M.empty
                     , hBalance = M.empty
                     , hAddrTx  = M.empty
                     , hAddrOut = M.empty
                     , hMempool = Nothing }

getBestBlockH :: Memory -> Maybe BlockHash
getBestBlockH = hBest

getBlocksAtHeightH :: BlockHeight -> Memory -> Maybe [BlockHash]
getBlocksAtHeightH h = M.lookup h . hHeight

getBlockH :: BlockHash -> Memory -> Maybe BlockData
getBlockH h = M.lookup h . hBlock

getTxDataH :: TxHash -> Memory -> Maybe TxData
getTxDataH t = M.lookup t . hTx

getSpenderH :: OutPoint -> Memory -> Maybe (Dirty Spender)
getSpenderH op db = do
    m <- M.lookup (outPointHash op) (hSpender db)
    I.lookup (fromIntegral (outPointIndex op)) m

getSpendersH :: TxHash -> Memory -> IntMap (Dirty Spender)
getSpendersH t = M.lookupDefault I.empty t . hSpender

getBalanceH :: Address -> Memory -> Maybe BalVal
getBalanceH a = M.lookup a . hBalance

getMempoolH :: Memory -> Maybe [TxRef]
getMempoolH = hMempool

setBestH :: BlockHash -> Memory -> Memory
setBestH h db = db {hBest = Just h}

insertBlockH :: BlockData -> Memory -> Memory
insertBlockH bd db =
    db { hBlock =
             M.insert
                  (headerHash (blockDataHeader bd))
                  bd
                  (hBlock db)
       }

setBlocksAtHeightH :: [BlockHash] -> BlockHeight -> Memory -> Memory
setBlocksAtHeightH hs g db = db {hHeight = M.insert g hs (hHeight db)}

insertTxH :: TxData -> Memory -> Memory
insertTxH tx db = db {hTx = M.insert (txHash (txData tx)) tx (hTx db)}

insertSpenderH :: OutPoint -> Spender -> Memory -> Memory
insertSpenderH op s db =
    db
        { hSpender =
              M.insertWith
                  (<>)
                  (outPointHash op)
                  (I.singleton
                      (fromIntegral (outPointIndex op))
                      (Modified s))
                  (hSpender db)
        }

deleteSpenderH :: OutPoint -> Memory -> Memory
deleteSpenderH op db =
    db
        { hSpender =
              M.insertWith
                  (<>)
                  (outPointHash op)
                  (I.singleton
                      (fromIntegral (outPointIndex op))
                      Deleted)
                  (hSpender db)
        }

setBalanceH :: Balance -> Memory -> Memory
setBalanceH bal db =
    db {hBalance = M.insert (balanceAddress bal) b (hBalance db)}
  where
    b = balanceToVal bal

insertAddrTxH :: Address -> TxRef -> Memory -> Memory
insertAddrTxH a btx db =
    db
        { hAddrTx =
              M.insertWith
                  (<>)
                  a
                  (M.singleton btx (Modified ()))
                  (hAddrTx db)
        }

deleteAddrTxH :: Address -> TxRef -> Memory -> Memory
deleteAddrTxH a btx db =
    db
        { hAddrTx =
              M.insertWith
                  (<>)
                  a
                  (M.singleton btx Deleted)
                  (hAddrTx db)
        }

insertAddrUnspentH :: Address -> Unspent -> Memory -> Memory
insertAddrUnspentH a u db =
    let uns = OutVal { outValAmount = unspentAmount u
                     , outValScript = B.Short.fromShort (unspentScript u) }
        s = M.singleton
                a
                (M.singleton
                    (unspentBlock u)
                    (M.singleton (unspentPoint u) (Modified uns)))
     in db { hAddrOut =
                 M.unionWith
                     (M.unionWith M.union)
                     s
                     (hAddrOut db)
           }

deleteAddrUnspentH :: Address -> Unspent -> Memory -> Memory
deleteAddrUnspentH a u db =
    let s =
            M.singleton
                a
                (M.singleton
                    (unspentBlock u)
                    (M.singleton (unspentPoint u) Deleted))
     in db {hAddrOut = M.unionWith (M.unionWith M.union) s (hAddrOut db)}

setMempoolH :: [TxRef] -> Memory -> Memory
setMempoolH xs db = db {hMempool = Just xs}

getUnspentH :: OutPoint -> Memory -> Maybe (Dirty UnspentVal)
getUnspentH op db = do
    m <- M.lookup (outPointHash op) (hUnspent db)
    I.lookup (fromIntegral (outPointIndex op)) m

insertUnspentH :: Unspent -> Memory -> Memory
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

deleteUnspentH :: OutPoint -> Memory -> Memory
deleteUnspentH op db =
    db
        { hUnspent =
              M.insertWith
                  (<>)
                  (outPointHash op)
                  (I.singleton
                      (fromIntegral (outPointIndex op))
                      Deleted)
                  (hUnspent db)
        }
