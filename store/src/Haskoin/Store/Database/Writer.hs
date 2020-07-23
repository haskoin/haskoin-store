{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
module Haskoin.Store.Database.Writer (WriterT , runWriter) where

import           Control.Applicative           ((<|>))
import           Control.DeepSeq               (NFData)
import           Control.Monad.Reader          (ReaderT (..))
import qualified Control.Monad.Reader          as R
import           Control.Monad.Trans.Maybe     (MaybeT (..), runMaybeT)
import qualified Data.ByteString.Short         as B.Short
import           Data.Hashable                 (Hashable)
import           Data.HashMap.Strict           (HashMap)
import qualified Data.HashMap.Strict           as M
import           Data.List                     (sortOn)
import           Data.Ord                      (Down (..))
import           Database.RocksDB              (BatchOp)
import           Database.RocksDB.Query        (deleteOp, insertOp, writeBatch)
import           GHC.Generics                  (Generic)
import           Haskoin                       (Address, BlockHash, BlockHeight,
                                                Network, OutPoint (..), TxHash,
                                                headerHash, txHash)
import           Haskoin.Store.Common
import           Haskoin.Store.Data
import           Haskoin.Store.Database.Reader
import           Haskoin.Store.Database.Types
import           UnliftIO                      (MonadIO, TVar, atomically,
                                                liftIO, modifyTVar, newTVarIO,
                                                readTVarIO)

data Dirty a = Modified a | Deleted
    deriving (Eq, Show, Generic, Hashable, NFData)

instance Functor Dirty where
    fmap _ Deleted      = Deleted
    fmap f (Modified a) = Modified (f a)

data Writer = Writer { getReader :: !DatabaseReader
                     , getState  :: !(TVar Memory) }

type WriterT = ReaderT Writer

instance MonadIO m => StoreReadBase (WriterT m) where
    getNetwork =
        R.ask >>= getNetworkI
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
    getUnspent a =
        R.ask >>= getUnspentI a
    getBalance a =
        R.ask >>= getBalanceI a
    getMempool =
        R.ask >>= getMempoolI

data Memory = Memory
    { hNet
      :: !Network
    , hBest
      :: !(Maybe BlockHash)
    , hBlock
      :: !(HashMap BlockHash BlockData)
    , hHeight
      :: !(HashMap BlockHeight [BlockHash])
    , hTx
      :: !(HashMap TxHash TxData)
    , hSpender
      :: !(HashMap OutPoint (Dirty Spender))
    , hUnspent
      :: !(HashMap OutPoint (Dirty UnspentVal))
    , hBalance
      :: !(HashMap Address BalVal)
    , hAddrTx
      :: !(HashMap (Address, TxRef) (Dirty ()))
    , hAddrOut
      :: !(HashMap (Address, BlockRef, OutPoint) (Dirty OutVal))
    , hMempool
      :: !(HashMap TxHash UnixTime)
    } deriving (Eq, Show)

instance MonadIO m => StoreWrite (WriterT m) where
    setBest h =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        setBestH h
    insertBlock b =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        insertBlockH b
    setBlocksAtHeight h g =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        setBlocksAtHeightH h g
    insertTx t =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        insertTxH t
    insertSpender p s' =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        insertSpenderH p s'
    deleteSpender p =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        deleteSpenderH p
    insertAddrTx a t =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        insertAddrTxH a t
    deleteAddrTx a t =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        deleteAddrTxH a t
    insertAddrUnspent a u =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        insertAddrUnspentH a u
    deleteAddrUnspent a u =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        deleteAddrUnspentH a u
    addToMempool x t =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
            addToMempoolH x t
    deleteFromMempool x =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
            deleteFromMempoolH x
    setBalance b =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        setBalanceH b
    insertUnspent h =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        insertUnspentH h
    deleteUnspent p =
        ReaderT $ \Writer { getState = s } ->
        liftIO . atomically . modifyTVar s $
        deleteUnspentH p

runWriter
    :: MonadIO m
    => DatabaseReader
    -> WriterT m a
    -> m a
runWriter bdb@DatabaseReader{ databaseHandle = db
                            , databaseNetwork = net } f = do
    (mem, best) <- runReaderT ((,) <$> getMempool <*> getBestBlock) bdb
    hm <- newTVarIO (emptyMemory net best mem)
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
    mempoolOp (hMempool db) <>
    unspentOps (hUnspent db)

bestBlockOp :: Maybe BlockHash -> [BatchOp]
bestBlockOp Nothing  = [deleteOp BestKey]
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

spenderOps :: HashMap OutPoint (Dirty Spender)
           -> [BatchOp]
spenderOps = map (uncurry f) . M.toList
  where
    f o (Modified s) =
        insertOp (SpenderKey o) s
    f o Deleted =
        deleteOp (SpenderKey o)

balOps :: HashMap Address BalVal -> [BatchOp]
balOps = map (uncurry f) . M.toList
  where
    f = insertOp . BalKey

addrTxOps :: HashMap (Address, TxRef) (Dirty ()) -> [BatchOp]
addrTxOps = map (uncurry f) . M.toList
  where
    f (a, t) (Modified ()) = insertOp (AddrTxKey a t) ()
    f (a, t) Deleted       = deleteOp (AddrTxKey a t)

addrOutOps
    :: HashMap (Address, BlockRef, OutPoint) (Dirty OutVal) -> [BatchOp]
addrOutOps = map (uncurry f) . M.toList
  where
    f (a, b, p) (Modified l) =
        insertOp
            (AddrOutKey { addrOutKeyA = a
                        , addrOutKeyB = b
                        , addrOutKeyP = p })
            l
    f (a, b, p) Deleted =
        deleteOp AddrOutKey { addrOutKeyA = a
                            , addrOutKeyB = b
                            , addrOutKeyP = p }

mempoolOp :: HashMap TxHash UnixTime -> [BatchOp]
mempoolOp = (: [])
          . insertOp MemKey
          . sortOn Down
          . map (\(h, t) -> (t, h))
          . M.toList

unspentOps :: HashMap OutPoint (Dirty UnspentVal)
           -> [BatchOp]
unspentOps = map (uncurry f) . M.toList
  where
    f p (Modified u) =
        insertOp (UnspentKey p) u
    f p Deleted =
        deleteOp (UnspentKey p)

getNetworkI :: MonadIO m => Writer -> m Network
getNetworkI Writer {getState = hm} =
    hNet <$> readTVarIO hm

getBestBlockI :: MonadIO m => Writer -> m (Maybe BlockHash)
getBestBlockI Writer {getState = hm} =
    getBestBlockH <$> readTVarIO hm

getBlocksAtHeightI :: MonadIO m
                   => BlockHeight
                   -> Writer
                   -> m [BlockHash]
getBlocksAtHeightI bh Writer {getState = hm, getReader = db} =
    getBlocksAtHeightH bh <$> readTVarIO hm >>= \case
        Just bs -> return bs
        Nothing -> runReaderT (getBlocksAtHeight bh) db

getBlockI :: MonadIO m
          => BlockHash
          -> Writer
          -> m (Maybe BlockData)
getBlockI bh Writer {getReader = db, getState = hm} =
    runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = getBlockH bh <$> readTVarIO hm
    g = runReaderT (getBlock bh) db

getTxDataI :: MonadIO m
           => TxHash
           -> Writer
           -> m (Maybe TxData)
getTxDataI th Writer {getReader = db, getState = hm} =
    runMaybeT $ MaybeT f <|> MaybeT g
  where
    f = getTxDataH th <$> readTVarIO hm
    g = runReaderT (getTxData th) db

getSpenderI :: MonadIO m => OutPoint -> Writer -> m (Maybe Spender)
getSpenderI op Writer {getReader = db, getState = hm} =
    getSpenderH op <$> readTVarIO hm >>= \case
        Just (Modified s) -> return (Just s)
        Just Deleted -> return Nothing
        Nothing -> runReaderT (getSpender op) db

getBalanceI :: MonadIO m => Address -> Writer -> m (Maybe Balance)
getBalanceI a Writer {getReader = db, getState = hm} =
    getBalanceH a <$> readTVarIO hm >>= \case
        Just b -> return $ Just (valToBalance a b)
        Nothing -> runReaderT (getBalance a) db

getUnspentI :: MonadIO m
            => OutPoint
            -> Writer
            -> m (Maybe Unspent)
getUnspentI op Writer {getReader = db, getState = hm} =
    getUnspentH op <$> readTVarIO hm >>= \case
        Just (Modified u) -> return (Just (valToUnspent op u))
        Just Deleted -> return Nothing
        Nothing -> runReaderT (getUnspent op) db

getMempoolI :: MonadIO m => Writer -> m [TxRef]
getMempoolI Writer {getState = hm} =
    getMempoolH <$> readTVarIO hm

emptyMemory :: Network -> Maybe BlockHash -> [TxRef] -> Memory
emptyMemory net best mem =
    Memory { hNet     = net
           , hBest    = best
           , hBlock   = M.empty
           , hHeight  = M.empty
           , hTx      = M.empty
           , hSpender = M.empty
           , hUnspent = M.empty
           , hBalance = M.empty
           , hAddrTx  = M.empty
           , hAddrOut = M.empty
           , hMempool = M.fromList $ map (\(TxRef (MemRef t) h) -> (h, t)) mem
           }

getBestBlockH :: Memory -> Maybe BlockHash
getBestBlockH = hBest

getBlocksAtHeightH :: BlockHeight -> Memory -> Maybe [BlockHash]
getBlocksAtHeightH h = M.lookup h . hHeight

getBlockH :: BlockHash -> Memory -> Maybe BlockData
getBlockH h = M.lookup h . hBlock

getTxDataH :: TxHash -> Memory -> Maybe TxData
getTxDataH t = M.lookup t . hTx

getSpenderH :: OutPoint -> Memory -> Maybe (Dirty Spender)
getSpenderH op db = M.lookup op (hSpender db)

getBalanceH :: Address -> Memory -> Maybe BalVal
getBalanceH a = M.lookup a . hBalance

getMempoolH :: Memory -> [TxRef]
getMempoolH = sortOn Down . map (\(h, t) -> TxRef (MemRef t) h) . M.toList . hMempool

setBestH :: BlockHash -> Memory -> Memory
setBestH h db = db {hBest = Just h}

insertBlockH :: BlockData -> Memory -> Memory
insertBlockH bd db =
    db { hBlock = M.insert
                  (headerHash (blockDataHeader bd))
                  bd
                  (hBlock db)
       }

setBlocksAtHeightH :: [BlockHash] -> BlockHeight -> Memory -> Memory
setBlocksAtHeightH hs g db =
    db {hHeight = M.insert g hs (hHeight db)}

insertTxH :: TxData -> Memory -> Memory
insertTxH tx db =
    db {hTx = M.insert (txHash (txData tx)) tx (hTx db)}

insertSpenderH :: OutPoint -> Spender -> Memory -> Memory
insertSpenderH op s db =
    db { hSpender = M.insert op (Modified s) (hSpender db) }

deleteSpenderH :: OutPoint -> Memory -> Memory
deleteSpenderH op db =
    db { hSpender = M.insert op Deleted (hSpender db) }

setBalanceH :: Balance -> Memory -> Memory
setBalanceH bal db =
    db {hBalance = M.insert (balanceAddress bal) b (hBalance db)}
  where
    b = balanceToVal bal

insertAddrTxH :: Address -> TxRef -> Memory -> Memory
insertAddrTxH a tr db =
    db { hAddrTx = M.insert (a, tr) (Modified ()) (hAddrTx db) }

deleteAddrTxH :: Address -> TxRef -> Memory -> Memory
deleteAddrTxH a tr db =
    db { hAddrTx = M.insert (a, tr) Deleted (hAddrTx db) }

insertAddrUnspentH :: Address -> Unspent -> Memory -> Memory
insertAddrUnspentH a u db =
    let k = (a, unspentBlock u, unspentPoint u)
        v = OutVal { outValAmount = unspentAmount u
                   , outValScript = B.Short.fromShort (unspentScript u) }
     in db { hAddrOut = M.insert k (Modified v) (hAddrOut db) }

deleteAddrUnspentH :: Address -> Unspent -> Memory -> Memory
deleteAddrUnspentH a u db =
    let k = (a, unspentBlock u, unspentPoint u)
     in db { hAddrOut = M.insert k Deleted (hAddrOut db) }

addToMempoolH :: TxHash -> UnixTime -> Memory -> Memory
addToMempoolH h t db =
    db { hMempool = M.insert h t (hMempool db) }

deleteFromMempoolH :: TxHash -> Memory -> Memory
deleteFromMempoolH h db =
    db { hMempool = M.delete h (hMempool db) }

getUnspentH :: OutPoint -> Memory -> Maybe (Dirty UnspentVal)
getUnspentH op db = M.lookup op (hUnspent db)

insertUnspentH :: Unspent -> Memory -> Memory
insertUnspentH u db =
    let (k, v) = unspentToVal u
     in db { hUnspent = M.insert k (Modified v) (hUnspent db) }

deleteUnspentH :: OutPoint -> Memory -> Memory
deleteUnspentH op db =
    db { hUnspent = M.insert op Deleted (hUnspent db) }
