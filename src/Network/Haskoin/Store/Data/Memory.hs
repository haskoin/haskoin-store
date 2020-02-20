{-# LANGUAGE FlexibleInstances #-}
module Network.Haskoin.Store.Data.Memory where

import           Conduit                             (ConduitT, mapC, yieldMany,
                                                      (.|))
import           Control.Monad                       (join)
import           Control.Monad.Reader                (ReaderT)
import qualified Control.Monad.Reader                as R
import qualified Data.ByteString.Short               as B.Short
import           Data.Function                       (on)
import           Data.HashMap.Strict                 (HashMap)
import qualified Data.HashMap.Strict                 as M
import           Data.IntMap.Strict                  (IntMap)
import qualified Data.IntMap.Strict                  as I
import           Data.List                           (nub, sortBy)
import           Data.Maybe                          (catMaybes, fromJust,
                                                      fromMaybe, isJust,
                                                      maybeToList)
import           Haskoin                             (Address, BlockHash,
                                                      BlockHeight,
                                                      OutPoint (..), Tx, TxHash,
                                                      headerHash, txHash)
import           Network.Haskoin.Store.Data.KeyValue (OutVal (..))
import           Network.Haskoin.Store.Data.Types    (BalVal, Balance,
                                                      BlockData (..), BlockRef,
                                                      BlockTx (..), Limit,
                                                      Spender, StoreRead (..),
                                                      StoreStream (..),
                                                      StoreWrite (..),
                                                      TxData (..), UnixTime,
                                                      Unspent (..), UnspentVal,
                                                      balanceToVal,
                                                      unspentToVal,
                                                      valToBalance,
                                                      valToUnspent)
import           UnliftIO

withBlockMem :: MonadIO m => TVar BlockMem -> ReaderT (TVar BlockMem) m a -> m a
withBlockMem = flip R.runReaderT

data BlockMem = BlockMem
    { hBest :: !(Maybe BlockHash)
    , hBlock :: !(HashMap BlockHash BlockData)
    , hHeight :: !(HashMap BlockHeight [BlockHash])
    , hTx :: !(HashMap TxHash TxData)
    , hSpender :: !(HashMap TxHash (IntMap (Maybe Spender)))
    , hUnspent :: !(HashMap TxHash (IntMap (Maybe UnspentVal)))
    , hBalance :: !(HashMap Address BalVal)
    , hAddrTx :: !(HashMap Address (HashMap BlockRef (HashMap TxHash Bool)))
    , hAddrOut :: !(HashMap Address (HashMap BlockRef (HashMap OutPoint (Maybe OutVal))))
    , hMempool :: !(Maybe [(UnixTime, TxHash)])
    , hOrphans :: !(HashMap TxHash (Maybe (UnixTime, Tx)))
    } deriving (Eq, Show)

emptyBlockMem :: BlockMem
emptyBlockMem =
    BlockMem
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
        , hOrphans = M.empty
        }

getBestBlockH :: BlockMem -> Maybe BlockHash
getBestBlockH = hBest

getBlocksAtHeightH :: BlockHeight -> BlockMem -> [BlockHash]
getBlocksAtHeightH h = M.lookupDefault [] h . hHeight

getBlockH :: BlockHash -> BlockMem -> Maybe BlockData
getBlockH h = M.lookup h . hBlock

getTxDataH :: TxHash -> BlockMem -> Maybe TxData
getTxDataH t = M.lookup t . hTx

getSpenderH :: OutPoint -> BlockMem -> Maybe (Maybe Spender)
getSpenderH op db = do
    m <- M.lookup (outPointHash op) (hSpender db)
    I.lookup (fromIntegral (outPointIndex op)) m

getSpendersH :: TxHash -> BlockMem -> IntMap (Maybe Spender)
getSpendersH t = M.lookupDefault I.empty t . hSpender

getBalanceH :: Address -> BlockMem -> Maybe Balance
getBalanceH a = fmap (valToBalance a) . M.lookup a . hBalance

getMempoolH :: BlockMem -> Maybe [(UnixTime, TxHash)]
getMempoolH = hMempool

getOrphansH :: Monad m => BlockMem -> ConduitT i (UnixTime, Tx) m ()
getOrphansH = yieldMany . catMaybes . M.elems . hOrphans

getOrphanTxH :: TxHash -> BlockMem -> Maybe (Maybe (UnixTime, Tx))
getOrphanTxH h = M.lookup h . hOrphans

getUnspentsH :: Monad m => BlockMem -> ConduitT i Unspent m ()
getUnspentsH BlockMem {hUnspent = us} =
    yieldMany
        [ u
        | (h, m) <- M.toList us
        , (i, mv) <- I.toList m
        , v <- maybeToList mv
        , let p = OutPoint h (fromIntegral i)
        , let u = valToUnspent p v
        ]

getAddressesTxsH ::
       [Address] -> Maybe BlockRef -> Maybe Limit -> BlockMem -> [BlockTx]
getAddressesTxsH addrs start limit db =
    case limit of
        Nothing -> g
        Just l  -> take (fromIntegral l) g
  where
    g =
        nub . sortBy (flip compare `on` blockTxBlock) . concat $
        map (\a -> getAddressTxsH a start db) addrs

getAddressTxsH :: Address -> Maybe BlockRef -> BlockMem -> [BlockTx]
getAddressTxsH a mbr db =
    dropWhile h .
    sortBy (flip compare) . catMaybes . concatMap (uncurry f) . M.toList $
    M.lookupDefault M.empty a (hAddrTx db)
  where
    f b hm = map (uncurry (g b)) $ M.toList hm
    g b h' True =
        Just
            BlockTx
                {blockTxBlock = b, blockTxHash = h'}
    g _ _ False = Nothing
    h BlockTx {blockTxBlock = b} =
        case mbr of
            Nothing -> False
            Just br -> b > br

getAddressBalancesH :: Monad m => BlockMem -> ConduitT i Balance m ()
getAddressBalancesH BlockMem {hBalance = bm} =
    yieldMany (M.toList bm) .| mapC (uncurry valToBalance)

getAddressesUnspentsH ::
       [Address] -> Maybe BlockRef -> Maybe Limit -> BlockMem -> [Unspent]
getAddressesUnspentsH addrs start limit db =
    case limit of
        Nothing -> g
        Just l  -> take (fromIntegral l) g
  where
    g =
        nub . sortBy (flip compare `on` unspentBlock) . concat $
        map (\a -> getAddressUnspentsH a start db) addrs

getAddressUnspentsH ::
       Address -> Maybe BlockRef -> BlockMem -> [Unspent]
getAddressUnspentsH a mbr db =
    dropWhile h .
    sortBy (flip compare) . catMaybes . concatMap (uncurry f) . M.toList $
    M.lookupDefault M.empty a (hAddrOut db)
  where
    f b hm = map (uncurry (g b)) $ M.toList hm
    g b p (Just u) =
        Just
            Unspent
                { unspentBlock = b
                , unspentAmount = outValAmount u
                , unspentScript = B.Short.toShort (outValScript u)
                , unspentPoint = p
                }
    g _ _ Nothing = Nothing
    h Unspent {unspentBlock = b} =
        case mbr of
            Nothing -> False
            Just br -> b > br

setBestH :: BlockHash -> BlockMem -> BlockMem
setBestH h db = db {hBest = Just h}

insertBlockH :: BlockData -> BlockMem -> BlockMem
insertBlockH bd db =
    db {hBlock = M.insert (headerHash (blockDataHeader bd)) bd (hBlock db)}

setBlocksAtHeightH :: [BlockHash] -> BlockHeight -> BlockMem -> BlockMem
setBlocksAtHeightH hs g db = db {hHeight = M.insert g hs (hHeight db)}

insertTxH :: TxData -> BlockMem -> BlockMem
insertTxH tx db = db {hTx = M.insert (txHash (txData tx)) tx (hTx db)}

insertSpenderH :: OutPoint -> Spender -> BlockMem -> BlockMem
insertSpenderH op s db =
    db
        { hSpender =
              M.insertWith
                  (<>)
                  (outPointHash op)
                  (I.singleton (fromIntegral (outPointIndex op)) (Just s))
                  (hSpender db)
        }

deleteSpenderH :: OutPoint -> BlockMem -> BlockMem
deleteSpenderH op db =
    db
        { hSpender =
              M.insertWith
                  (<>)
                  (outPointHash op)
                  (I.singleton (fromIntegral (outPointIndex op)) Nothing)
                  (hSpender db)
        }

setBalanceH :: Balance -> BlockMem -> BlockMem
setBalanceH bal db = db {hBalance = M.insert a b (hBalance db)}
  where
    (a, b) = balanceToVal bal

insertAddrTxH :: Address -> BlockTx -> BlockMem -> BlockMem
insertAddrTxH a btx db =
    let s =
            M.singleton
                a
                (M.singleton
                     (blockTxBlock btx)
                     (M.singleton (blockTxHash btx) True))
     in db {hAddrTx = M.unionWith (M.unionWith M.union) s (hAddrTx db)}

deleteAddrTxH :: Address -> BlockTx -> BlockMem -> BlockMem
deleteAddrTxH a btx db =
    let s =
            M.singleton
                a
                (M.singleton
                     (blockTxBlock btx)
                     (M.singleton (blockTxHash btx) False))
     in db {hAddrTx = M.unionWith (M.unionWith M.union) s (hAddrTx db)}

insertAddrUnspentH :: Address -> Unspent -> BlockMem -> BlockMem
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

deleteAddrUnspentH :: Address -> Unspent -> BlockMem -> BlockMem
deleteAddrUnspentH a u db =
    let s =
            M.singleton
                a
                (M.singleton
                     (unspentBlock u)
                     (M.singleton (unspentPoint u) Nothing))
     in db {hAddrOut = M.unionWith (M.unionWith M.union) s (hAddrOut db)}

setMempoolH :: [(UnixTime, TxHash)] -> BlockMem -> BlockMem
setMempoolH xs db = db {hMempool = Just xs}

insertOrphanTxH :: Tx -> UnixTime -> BlockMem -> BlockMem
insertOrphanTxH tx u db =
    db {hOrphans = M.insert (txHash tx) (Just (u, tx)) (hOrphans db)}

deleteOrphanTxH :: TxHash -> BlockMem -> BlockMem
deleteOrphanTxH h db = db {hOrphans = M.insert h Nothing (hOrphans db)}

getUnspentH :: OutPoint -> BlockMem -> Maybe (Maybe Unspent)
getUnspentH op db = do
    m <- M.lookup (outPointHash op) (hUnspent db)
    fmap (valToUnspent op) <$> I.lookup (fromIntegral (outPointIndex op)) m

insertUnspentH :: Unspent -> BlockMem -> BlockMem
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

deleteUnspentH :: OutPoint -> BlockMem -> BlockMem
deleteUnspentH op db =
    db
        { hUnspent =
              M.insertWith
                  (<>)
                  (outPointHash op)
                  (I.singleton (fromIntegral (outPointIndex op)) Nothing)
                  (hUnspent db)
        }

instance MonadIO m => StoreRead (ReaderT (TVar BlockMem) m) where
    getBestBlock = do
        v <- R.ask >>= readTVarIO
        return $ getBestBlockH v
    getBlocksAtHeight h = do
        v <- R.ask >>= readTVarIO
        return $ getBlocksAtHeightH h v
    getBlock b = do
        v <- R.ask >>= readTVarIO
        return $ getBlockH b v
    getTxData t = do
        v <- R.ask >>= readTVarIO
        return $ getTxDataH t v
    getSpender t = do
        v <- R.ask >>= readTVarIO
        return . join $ getSpenderH t v
    getSpenders t = do
        v <- R.ask >>= readTVarIO
        return . I.map fromJust . I.filter isJust $ getSpendersH t v
    getOrphanTx h = do
        v <- R.ask >>= readTVarIO
        return . join $ getOrphanTxH h v
    getUnspent p = do
        v <- R.ask >>= readTVarIO
        return . join $ getUnspentH p v
    getBalance a = do
        v <- R.ask >>= readTVarIO
        return $ getBalanceH a v
    getMempool = do
        v <- R.ask >>= readTVarIO
        return . fromMaybe [] $ getMempoolH v
    getAddressesTxs addr start limit = do
        v <- R.ask >>= readTVarIO
        return $ getAddressesTxsH addr start limit v
    getAddressesUnspents addr start limit = do
        v <- R.ask >>= readTVarIO
        return $ getAddressesUnspentsH addr start limit v

instance MonadIO m => StoreStream (ReaderT (TVar BlockMem) m) where
    getOrphans = do
        v <- R.ask >>= readTVarIO
        getOrphansH v
    getAddressTxs a m = do
        v <- R.ask >>= readTVarIO
        yieldMany $ getAddressTxsH a m v
    getAddressUnspents a m = do
        v <- R.ask >>= readTVarIO
        yieldMany $ getAddressUnspentsH a m v
    getAddressBalances = do
        v <- R.ask >>= readTVarIO
        getAddressBalancesH v
    getUnspents = do
        v <- R.ask >>= readTVarIO
        getUnspentsH v

instance (MonadIO m) => StoreWrite (ReaderT (TVar BlockMem) m) where
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
    insertOrphanTx t u = do
        v <- R.ask
        atomically $ modifyTVar v (insertOrphanTxH t u)
    deleteOrphanTx h = do
        v <- R.ask
        atomically $ modifyTVar v (deleteOrphanTxH h)
    setBalance b = do
        v <- R.ask
        atomically $ modifyTVar v (setBalanceH b)
    insertUnspent h = do
        v <- R.ask
        atomically $ modifyTVar v (insertUnspentH h)
    deleteUnspent p = do
        v <- R.ask
        atomically $ modifyTVar v (deleteUnspentH p)
