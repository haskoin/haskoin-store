{-# LANGUAGE FlexibleInstances #-}
module Haskoin.Store.Database.Memory
    ( MemoryState(..)
    , MemoryDatabase(..)
    , withMemoryDatabase
    , emptyMemoryDatabase
    , getMempoolH
    , getSpenderH
    , getSpendersH
    , getUnspentH
    ) where

import           Control.Monad                (join)
import           Control.Monad.Reader         (ReaderT)
import qualified Control.Monad.Reader         as R
import qualified Data.ByteString.Short        as B.Short
import           Data.Function                (on)
import           Data.HashMap.Strict          (HashMap)
import qualified Data.HashMap.Strict          as M
import           Data.IntMap.Strict           (IntMap)
import qualified Data.IntMap.Strict           as I
import           Data.List                    (sortBy)
import           Data.Maybe                   (catMaybes, fromJust, fromMaybe,
                                               isJust)
import           Data.Word                    (Word32)
import           Haskoin                      (Address, BlockHash, BlockHeight,
                                               Network, OutPoint (..), TxHash,
                                               eitherToMaybe, headerHash,
                                               scriptToAddressBS, txHash)
import           Haskoin.Store.Common         (Limit, StoreRead (..),
                                               StoreWrite (..), applyLimit,
                                               nub')
import           Haskoin.Store.Data           (Balance (..), BlockData (..),
                                               BlockRef, BlockTx (..), Spender,
                                               TxData (..), Unspent (..),
                                               zeroBalance)
import           Haskoin.Store.Database.Types (BalVal, OutVal (..), UnspentVal,
                                               balanceToVal, unspentToVal,
                                               valToBalance, valToUnspent)
import           UnliftIO

data MemoryState =
    MemoryState
        { memoryDatabase   :: !(TVar MemoryDatabase)
        , memoryMaxGap     :: !Word32
        , memoryInitialGap :: !Word32
        , memoryNetwork    :: !Network
        }

withMemoryDatabase ::
       MonadIO m
    => MemoryState
    -> ReaderT MemoryState m a
    -> m a
withMemoryDatabase = flip R.runReaderT

data MemoryDatabase = MemoryDatabase
    { hBest :: !(Maybe BlockHash)
    , hBlock :: !(HashMap BlockHash BlockData)
    , hHeight :: !(HashMap BlockHeight [BlockHash])
    , hTx :: !(HashMap TxHash TxData)
    , hSpender :: !(HashMap TxHash (IntMap (Maybe Spender)))
    , hUnspent :: !(HashMap TxHash (IntMap (Maybe UnspentVal)))
    , hBalance :: !(HashMap Address BalVal)
    , hAddrTx :: !(HashMap Address (HashMap BlockRef (HashMap TxHash Bool)))
    , hAddrOut :: !(HashMap Address (HashMap BlockRef (HashMap OutPoint (Maybe OutVal))))
    , hMempool :: !(Maybe [BlockTx])
    } deriving (Eq, Show)

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

getBlocksAtHeightH :: BlockHeight -> MemoryDatabase -> [BlockHash]
getBlocksAtHeightH h = M.lookupDefault [] h . hHeight

getBlockH :: BlockHash -> MemoryDatabase -> Maybe BlockData
getBlockH h = M.lookup h . hBlock

getTxDataH :: TxHash -> MemoryDatabase -> Maybe TxData
getTxDataH t = M.lookup t . hTx

getSpenderH :: OutPoint -> MemoryDatabase -> Maybe (Maybe Spender)
getSpenderH op db = do
    m <- M.lookup (outPointHash op) (hSpender db)
    I.lookup (fromIntegral (outPointIndex op)) m

getSpendersH :: TxHash -> MemoryDatabase -> IntMap (Maybe Spender)
getSpendersH t = M.lookupDefault I.empty t . hSpender

getBalanceH :: Address -> MemoryDatabase -> Balance
getBalanceH a mem =
    fromMaybe (zeroBalance a) . fmap (valToBalance a) . M.lookup a $
    hBalance mem

getMempoolH :: MemoryDatabase -> Maybe [BlockTx]
getMempoolH = hMempool

getAddressesTxsH ::
       [Address] -> Maybe BlockRef -> Maybe Limit -> MemoryDatabase -> [BlockTx]
getAddressesTxsH addrs start limit db = applyLimit limit xs
  where
    xs =
        sortBy (flip compare `on` blockTxBlock) . nub' . concat $
        map (\a -> getAddressTxsH a start limit db) addrs

getAddressTxsH ::
       Address -> Maybe BlockRef -> Maybe Limit -> MemoryDatabase -> [BlockTx]
getAddressTxsH addr start limit db =
    applyLimit limit .
    dropWhile h .
    sortBy (flip compare) . catMaybes . concatMap (uncurry f) . M.toList $
    M.lookupDefault M.empty addr (hAddrTx db)
  where
    f b hm = map (uncurry (g b)) $ M.toList hm
    g b h' True = Just BlockTx {blockTxBlock = b, blockTxHash = h'}
    g _ _ False = Nothing
    h BlockTx {blockTxBlock = b} =
        case start of
            Nothing -> False
            Just br -> b > br

getAddressesUnspentsH ::
       [Address] -> Maybe BlockRef -> Maybe Limit -> MemoryDatabase -> [Unspent]
getAddressesUnspentsH addrs start limit db = applyLimit limit xs
  where
    xs =
        sortBy (flip compare `on` unspentBlock) . nub' . concat $
        map (\a -> getAddressUnspentsH a start limit db) addrs

getAddressUnspentsH ::
       Address -> Maybe BlockRef -> Maybe Limit -> MemoryDatabase -> [Unspent]
getAddressUnspentsH addr start limit db =
    applyLimit limit .
    dropWhile h .
    sortBy (flip compare) . catMaybes . concatMap (uncurry f) . M.toList $
    M.lookupDefault M.empty addr (hAddrOut db)
  where
    f b hm = map (uncurry (g b)) $ M.toList hm
    g b p (Just u) =
        Just
            Unspent
                { unspentBlock = b
                , unspentAmount = outValAmount u
                , unspentScript = B.Short.toShort (outValScript u)
                , unspentPoint = p
                , unspentAddress =
                      eitherToMaybe (scriptToAddressBS (outValScript u))
                }
    g _ _ Nothing = Nothing
    h Unspent {unspentBlock = b} =
        case start of
            Nothing -> False
            Just br -> b > br

setBestH :: BlockHash -> MemoryDatabase -> MemoryDatabase
setBestH h db = db {hBest = Just h}

insertBlockH :: BlockData -> MemoryDatabase -> MemoryDatabase
insertBlockH bd db =
    db {hBlock = M.insert (headerHash (blockDataHeader bd)) bd (hBlock db)}

setBlocksAtHeightH :: [BlockHash] -> BlockHeight -> MemoryDatabase -> MemoryDatabase
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
                  (I.singleton (fromIntegral (outPointIndex op)) (Just s))
                  (hSpender db)
        }

deleteSpenderH :: OutPoint -> MemoryDatabase -> MemoryDatabase
deleteSpenderH op db =
    db
        { hSpender =
              M.insertWith
                  (<>)
                  (outPointHash op)
                  (I.singleton (fromIntegral (outPointIndex op)) Nothing)
                  (hSpender db)
        }

setBalanceH :: Balance -> MemoryDatabase -> MemoryDatabase
setBalanceH bal db =
    db {hBalance = M.insert (balanceAddress bal) b (hBalance db)}
  where
    b = balanceToVal bal

insertAddrTxH :: Address -> BlockTx -> MemoryDatabase -> MemoryDatabase
insertAddrTxH a btx db =
    let s =
            M.singleton
                a
                (M.singleton
                     (blockTxBlock btx)
                     (M.singleton (blockTxHash btx) True))
     in db {hAddrTx = M.unionWith (M.unionWith M.union) s (hAddrTx db)}

deleteAddrTxH :: Address -> BlockTx -> MemoryDatabase -> MemoryDatabase
deleteAddrTxH a btx db =
    let s =
            M.singleton
                a
                (M.singleton
                     (blockTxBlock btx)
                     (M.singleton (blockTxHash btx) False))
     in db {hAddrTx = M.unionWith (M.unionWith M.union) s (hAddrTx db)}

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
                     (M.singleton (unspentPoint u) (Just uns)))
     in db {hAddrOut = M.unionWith (M.unionWith M.union) s (hAddrOut db)}

deleteAddrUnspentH :: Address -> Unspent -> MemoryDatabase -> MemoryDatabase
deleteAddrUnspentH a u db =
    let s =
            M.singleton
                a
                (M.singleton
                     (unspentBlock u)
                     (M.singleton (unspentPoint u) Nothing))
     in db {hAddrOut = M.unionWith (M.unionWith M.union) s (hAddrOut db)}

setMempoolH :: [BlockTx] -> MemoryDatabase -> MemoryDatabase
setMempoolH xs db = db {hMempool = Just xs}

getUnspentH :: OutPoint -> MemoryDatabase -> Maybe (Maybe Unspent)
getUnspentH op db = do
    m <- M.lookup (outPointHash op) (hUnspent db)
    fmap (valToUnspent op) <$> I.lookup (fromIntegral (outPointIndex op)) m

insertUnspentH :: Unspent -> MemoryDatabase -> MemoryDatabase
insertUnspentH u db =
    db
        { hUnspent =
              M.insertWith
                  (<>)
                  (outPointHash (unspentPoint u))
                  (I.singleton
                       (fromIntegral (outPointIndex (unspentPoint u)))
                       (Just (snd (unspentToVal u))))
                  (hUnspent db)
        }

deleteUnspentH :: OutPoint -> MemoryDatabase -> MemoryDatabase
deleteUnspentH op db =
    db
        { hUnspent =
              M.insertWith
                  (<>)
                  (outPointHash op)
                  (I.singleton (fromIntegral (outPointIndex op)) Nothing)
                  (hUnspent db)
        }

instance MonadIO m => StoreRead (ReaderT MemoryState m) where
    getBestBlock = do
        v <- R.asks memoryDatabase >>= readTVarIO
        return $ getBestBlockH v
    getBlocksAtHeight h = do
        v <- R.asks memoryDatabase >>= readTVarIO
        return $ getBlocksAtHeightH h v
    getBlock b = do
        v <- R.asks memoryDatabase >>= readTVarIO
        return $ getBlockH b v
    getTxData t = do
        v <- R.asks memoryDatabase >>= readTVarIO
        return $ getTxDataH t v
    getSpender t = do
        v <- R.asks memoryDatabase >>= readTVarIO
        return . join $ getSpenderH t v
    getSpenders t = do
        v <- R.asks memoryDatabase >>= readTVarIO
        return . I.map fromJust . I.filter isJust $ getSpendersH t v
    getUnspent p = do
        v <- R.asks memoryDatabase >>= readTVarIO
        return . join $ getUnspentH p v
    getBalance a = do
        v <- R.asks memoryDatabase >>= readTVarIO
        return $ getBalanceH a v
    getMempool = do
        v <- R.asks memoryDatabase >>= readTVarIO
        return . fromMaybe [] $ getMempoolH v
    getAddressesTxs addr start limit = do
        v <- R.asks memoryDatabase >>= readTVarIO
        return $ getAddressesTxsH addr start limit v
    getAddressesUnspents addr start limit = do
        v <- R.asks memoryDatabase >>= readTVarIO
        return $ getAddressesUnspentsH addr start limit v
    getAddressTxs addr start limit = do
        v <- R.asks memoryDatabase >>= readTVarIO
        return $ getAddressTxsH addr start limit v
    getAddressUnspents addr start limit = do
        v <- R.asks memoryDatabase >>= readTVarIO
        return $ getAddressUnspentsH addr start limit v
    getMaxGap = R.asks memoryMaxGap
    getInitialGap = R.asks memoryInitialGap
    getNetwork = R.asks memoryNetwork

instance MonadIO m => StoreWrite (ReaderT MemoryState m) where
    setBest h = do
        v <- R.asks memoryDatabase
        atomically $ modifyTVar v (setBestH h)
    insertBlock b = do
        v <- R.asks memoryDatabase
        atomically $ modifyTVar v (insertBlockH b)
    setBlocksAtHeight h g = do
        v <- R.asks memoryDatabase
        atomically $ modifyTVar v (setBlocksAtHeightH h g)
    insertTx t = do
        v <- R.asks memoryDatabase
        atomically $ modifyTVar v (insertTxH t)
    insertSpender p s = do
        v <- R.asks memoryDatabase
        atomically $ modifyTVar v (insertSpenderH p s)
    deleteSpender p = do
        v <- R.asks memoryDatabase
        atomically $ modifyTVar v (deleteSpenderH p)
    insertAddrTx a t = do
        v <- R.asks memoryDatabase
        atomically $ modifyTVar v (insertAddrTxH a t)
    deleteAddrTx a t = do
        v <- R.asks memoryDatabase
        atomically $ modifyTVar v (deleteAddrTxH a t)
    insertAddrUnspent a u = do
        v <- R.asks memoryDatabase
        atomically $ modifyTVar v (insertAddrUnspentH a u)
    deleteAddrUnspent a u = do
        v <- R.asks memoryDatabase
        atomically $ modifyTVar v (deleteAddrUnspentH a u)
    setMempool xs = do
        v <- R.asks memoryDatabase
        atomically $ modifyTVar v (setMempoolH xs)
    setBalance b = do
        v <- R.asks memoryDatabase
        atomically $ modifyTVar v (setBalanceH b)
    insertUnspent h = do
        v <- R.asks memoryDatabase
        atomically $ modifyTVar v (insertUnspentH h)
    deleteUnspent p = do
        v <- R.asks memoryDatabase
        atomically $ modifyTVar v (deleteUnspentH p)
