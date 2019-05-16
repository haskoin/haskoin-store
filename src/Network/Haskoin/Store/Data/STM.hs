{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TupleSections     #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Network.Haskoin.Store.Data.STM where

import           Conduit
import           Control.Monad
import           Control.Monad.Reader                (ReaderT)
import qualified Control.Monad.Reader                as R
import qualified Data.ByteString.Short               as B.Short
import           Data.Function
import           Data.HashMap.Strict                 (HashMap)
import qualified Data.HashMap.Strict                 as M
import           Data.IntMap.Strict                  (IntMap)
import qualified Data.IntMap.Strict                  as I
import           Data.List
import           Data.Maybe
import           Haskoin
import           Network.Haskoin.Store.Data
import           Network.Haskoin.Store.Data.KeyValue
import           UnliftIO

type BlockSTM = ReaderT (TVar HashMapDB) STM
type UnspentSTM = ReaderT (TVar UnspentMap) STM
type BalanceSTM = ReaderT (TVar BalanceMap) STM
type UnspentMap = HashMap TxHash (IntMap Unspent)
type BalanceMap = (HashMap Address Balance, [Address])

withBlockSTM :: TVar HashMapDB -> ReaderT (TVar HashMapDB) STM a -> STM a
withBlockSTM = flip R.runReaderT

withUnspentSTM :: TVar UnspentMap -> ReaderT (TVar UnspentMap) STM a -> STM a
withUnspentSTM = flip R.runReaderT

withBalanceSTM :: TVar BalanceMap -> ReaderT (TVar BalanceMap) STM a -> STM a
withBalanceSTM = flip R.runReaderT

data HashMapDB = HashMapDB
    { hBest :: !(Maybe BlockHash)
    , hBlock :: !(HashMap BlockHash BlockData)
    , hHeight :: !(HashMap BlockHeight [BlockHash])
    , hTx :: !(HashMap TxHash TxData)
    , hSpender :: !(HashMap TxHash (IntMap (Maybe Spender)))
    , hUnspent :: !(HashMap TxHash (IntMap (Maybe Unspent)))
    , hBalance :: !(HashMap Address BalVal)
    , hAddrTx :: !(HashMap Address (HashMap BlockRef (HashMap TxHash Bool)))
    , hAddrOut :: !(HashMap Address (HashMap BlockRef (HashMap OutPoint (Maybe OutVal))))
    , hMempool :: !(HashMap UnixTime (HashMap TxHash Bool))
    , hOrphans :: !(HashMap TxHash (Maybe (UnixTime, Tx)))
    , hInit :: !Bool
    } deriving (Eq, Show)

emptyHashMapDB :: HashMapDB
emptyHashMapDB =
    HashMapDB
        { hBest = Nothing
        , hBlock = M.empty
        , hHeight = M.empty
        , hTx = M.empty
        , hSpender = M.empty
        , hUnspent = M.empty
        , hBalance = M.empty
        , hAddrTx = M.empty
        , hAddrOut = M.empty
        , hMempool = M.empty
        , hOrphans = M.empty
        , hInit = False
        }

isInitializedH :: HashMapDB -> Either InitException Bool
isInitializedH = Right . hInit

getBestBlockH :: HashMapDB -> Maybe BlockHash
getBestBlockH = hBest

getBlocksAtHeightH ::
       BlockHeight -> HashMapDB -> [BlockHash]
getBlocksAtHeightH h = M.lookupDefault [] h . hHeight

getBlockH :: BlockHash -> HashMapDB -> Maybe BlockData
getBlockH h = M.lookup h . hBlock

getTxDataH :: TxHash -> HashMapDB -> Maybe TxData
getTxDataH t = M.lookup t . hTx

getSpenderH :: OutPoint -> HashMapDB -> Maybe (Maybe Spender)
getSpenderH op db = do
    m <- M.lookup (outPointHash op) (hSpender db)
    I.lookup (fromIntegral (outPointIndex op)) m

getSpendersH :: TxHash -> HashMapDB -> IntMap (Maybe Spender)
getSpendersH t = M.lookupDefault I.empty t . hSpender

getBalanceH :: Address -> HashMapDB -> Maybe Balance
getBalanceH a = fmap f . M.lookup a . hBalance
  where
    f b =
        Balance
            { balanceAddress = a
            , balanceAmount = balValAmount b
            , balanceZero = balValZero b
            , balanceUnspentCount = balValUnspentCount b
            , balanceTxCount = balValTxCount b
            , balanceTotalReceived = balValTotalReceived b
            }

getMempoolH ::
       Monad m
    => Maybe UnixTime
    -> HashMapDB
    -> ConduitT () (UnixTime, TxHash) m ()
getMempoolH mpu db =
    let f ts =
            case mpu of
                Nothing -> False
                Just pu -> ts > pu
        ls =
            dropWhile (f . fst) .
            sortBy (flip compare) . M.toList . M.map (M.keys . M.filter id) $
            hMempool db
     in yieldMany [(u, h) | (u, hs) <- ls, h <- hs]

getOrphansH :: Monad m => HashMapDB -> ConduitT () (UnixTime, Tx) m ()
getOrphansH = yieldMany . catMaybes . M.elems . hOrphans

getOrphanTxH :: TxHash -> HashMapDB -> Maybe (Maybe (UnixTime, Tx))
getOrphanTxH h = M.lookup h . hOrphans

getAddressTxsH :: Address -> Maybe BlockRef -> HashMapDB -> [BlockTx]
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

getAddressUnspentsH ::
       Address -> Maybe BlockRef -> HashMapDB -> [Unspent]
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

setInitH :: HashMapDB -> HashMapDB
setInitH db = db {hInit = True}

setBestH :: BlockHash -> HashMapDB -> HashMapDB
setBestH h db = db {hBest = Just h}

insertBlockH :: BlockData -> HashMapDB -> HashMapDB
insertBlockH bd db =
    db {hBlock = M.insert (headerHash (blockDataHeader bd)) bd (hBlock db)}

insertAtHeightH :: BlockHash -> BlockHeight -> HashMapDB -> HashMapDB
insertAtHeightH h g db = db {hHeight = M.insertWith f g [h] (hHeight db)}
  where
    f xs ys = nub $ xs <> ys

insertTxH :: TxData -> HashMapDB -> HashMapDB
insertTxH tx db = db {hTx = M.insert (txHash (txData tx)) tx (hTx db)}

insertSpenderH :: OutPoint -> Spender -> HashMapDB -> HashMapDB
insertSpenderH op s db =
    db
        { hSpender =
              M.insertWith
                  (<>)
                  (outPointHash op)
                  (I.singleton (fromIntegral (outPointIndex op)) (Just s))
                  (hSpender db)
        }

deleteSpenderH :: OutPoint -> HashMapDB -> HashMapDB
deleteSpenderH op db =
    db
        { hSpender =
              M.insertWith
                  (<>)
                  (outPointHash op)
                  (I.singleton (fromIntegral (outPointIndex op)) Nothing)
                  (hSpender db)
        }

setBalanceH :: Balance -> HashMapDB -> HashMapDB
setBalanceH b db = db {hBalance = M.insert (balanceAddress b) x (hBalance db)}
  where
    x =
                BalVal
                    { balValAmount = balanceAmount b
                    , balValZero = balanceZero b
                    , balValUnspentCount = balanceUnspentCount b
                    , balValTxCount = balanceTxCount b
                    , balValTotalReceived = balanceTotalReceived b
                    }

insertAddrTxH :: Address -> BlockTx -> HashMapDB -> HashMapDB
insertAddrTxH a btx db =
    let s =
            M.singleton
                a
                (M.singleton
                     (blockTxBlock btx)
                     (M.singleton (blockTxHash btx) True))
     in db {hAddrTx = M.unionWith (M.unionWith M.union) s (hAddrTx db)}

removeAddrTxH :: Address -> BlockTx -> HashMapDB -> HashMapDB
removeAddrTxH a btx db =
    let s =
            M.singleton
                a
                (M.singleton
                     (blockTxBlock btx)
                     (M.singleton (blockTxHash btx) False))
     in db {hAddrTx = M.unionWith (M.unionWith M.union) s (hAddrTx db)}

insertAddrUnspentH :: Address -> Unspent -> HashMapDB -> HashMapDB
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

removeAddrUnspentH :: Address -> Unspent -> HashMapDB -> HashMapDB
removeAddrUnspentH a u db =
    let s =
            M.singleton
                a
                (M.singleton
                     (unspentBlock u)
                     (M.singleton (unspentPoint u) Nothing))
     in db {hAddrOut = M.unionWith (M.unionWith M.union) s (hAddrOut db)}

insertMempoolTxH :: TxHash -> UnixTime -> HashMapDB -> HashMapDB
insertMempoolTxH h u db =
    let s = M.singleton u (M.singleton h True)
     in db {hMempool = M.unionWith M.union s (hMempool db)}

deleteMempoolTxH :: TxHash -> UnixTime -> HashMapDB -> HashMapDB
deleteMempoolTxH h u db =
    let s = M.singleton u (M.singleton h False)
     in db {hMempool = M.unionWith M.union s (hMempool db)}

insertOrphanTxH :: Tx -> UnixTime -> HashMapDB -> HashMapDB
insertOrphanTxH tx u db =
    db {hOrphans = M.insert (txHash tx) (Just (u, tx)) (hOrphans db)}

deleteOrphanTxH :: TxHash -> HashMapDB -> HashMapDB
deleteOrphanTxH h db = db {hOrphans = M.insert h Nothing (hOrphans db)}

getUnspentH :: OutPoint -> HashMapDB -> Maybe (Maybe Unspent)
getUnspentH op db = do
    m <- M.lookup (outPointHash op) (hUnspent db)
    I.lookup (fromIntegral (outPointIndex op)) m

addUnspentH :: Unspent -> HashMapDB -> HashMapDB
addUnspentH u db =
    db
        { hUnspent =
              M.insertWith
                  (<>)
                  (outPointHash (unspentPoint u))
                  (I.singleton
                       (fromIntegral (outPointIndex (unspentPoint u)))
                       (Just u))
                  (hUnspent db)
        }

delUnspentH :: OutPoint -> HashMapDB -> HashMapDB
delUnspentH op db =
    db
        { hUnspent =
              M.insertWith
                  (<>)
                  (outPointHash op)
                  (I.singleton (fromIntegral (outPointIndex op)) Nothing)
                  (hUnspent db)
        }

instance StoreRead BlockSTM where
    isInitialized = fmap isInitializedH . lift . readTVar =<< R.ask
    getBestBlock = fmap getBestBlockH . lift . readTVar =<< R.ask
    getBlocksAtHeight h =
        fmap (getBlocksAtHeightH h) . lift . readTVar =<< R.ask
    getBlock b = fmap (getBlockH b) . lift . readTVar =<< R.ask
    getTxData t = fmap (getTxDataH t) . lift . readTVar =<< R.ask
    getSpender t = fmap (join . getSpenderH t) . lift . readTVar =<< R.ask
    getSpenders t =
        fmap (I.map fromJust . I.filter isJust . getSpendersH t) .
        lift . readTVar =<<
        R.ask
    getOrphanTx h = fmap (join . getOrphanTxH h) . lift . readTVar =<< R.ask

instance BalanceRead BlockSTM where
    getBalance a = fmap (getBalanceH a) . lift . readTVar =<< R.ask

instance UnspentRead BlockSTM where
    getUnspent op = fmap (join . getUnspentH op) . lift . readTVar =<< R.ask

instance BalanceWrite BlockSTM where
    setBalance b = lift . (`modifyTVar` setBalanceH b) =<< R.ask
    pruneBalance = return ()

instance StoreStream BlockSTM where
    getMempool m = getMempoolH m =<< lift . lift . readTVar =<< lift R.ask
    getOrphans = getOrphansH =<< lift . lift . readTVar =<< lift R.ask
    getAddressTxs a m =
        yieldMany . getAddressTxsH a m =<< lift . lift . readTVar =<< lift R.ask
    getAddressUnspents a m =
        yieldMany . getAddressUnspentsH a m =<<
        lift . lift . readTVar =<< lift R.ask

instance StoreWrite BlockSTM where
    setInit = lift . (`modifyTVar` setInitH) =<< R.ask
    setBest h = lift . (`modifyTVar` setBestH h) =<< R.ask
    insertBlock b = lift . (`modifyTVar` insertBlockH b) =<< R.ask
    insertAtHeight h g = lift . (`modifyTVar` insertAtHeightH h g) =<< R.ask
    insertTx t = lift . (`modifyTVar` insertTxH t) =<< R.ask
    insertSpender p s = lift . (`modifyTVar` insertSpenderH p s) =<< R.ask
    deleteSpender p = lift . (`modifyTVar` deleteSpenderH p) =<< R.ask
    insertAddrTx a t = lift . (`modifyTVar` insertAddrTxH a t) =<< R.ask
    removeAddrTx a t = lift . (`modifyTVar` removeAddrTxH a t) =<< R.ask
    insertAddrUnspent a u =
        lift . (`modifyTVar` insertAddrUnspentH a u) =<< R.ask
    removeAddrUnspent a u =
        lift . (`modifyTVar` removeAddrUnspentH a u) =<< R.ask
    insertMempoolTx h t = lift . (`modifyTVar` insertMempoolTxH h t) =<< R.ask
    deleteMempoolTx h t = lift . (`modifyTVar` deleteMempoolTxH h t) =<< R.ask
    deleteOrphanTx h = lift . (`modifyTVar` deleteOrphanTxH h) =<< R.ask
    insertOrphanTx t u = lift . (`modifyTVar` insertOrphanTxH t u) =<< R.ask

instance UnspentWrite BlockSTM where
    addUnspent h = lift . (`modifyTVar` addUnspentH h) =<< R.ask
    delUnspent p = lift . (`modifyTVar` delUnspentH p) =<< R.ask
    pruneUnspent = return ()

instance UnspentRead UnspentSTM where
    getUnspent op = do
        um <- lift . readTVar =<< R.ask
        return $ do
            m <- M.lookup (outPointHash op) um
            I.lookup (fromIntegral (outPointIndex op)) m

instance UnspentWrite UnspentSTM where
    addUnspent u = do
        v <- R.ask
        lift . modifyTVar v $
            M.insertWith
                (<>)
                (outPointHash (unspentPoint u))
                (I.singleton (fromIntegral (outPointIndex (unspentPoint u))) u)
    delUnspent op = lift . (`modifyTVar` M.update g (outPointHash op)) =<< R.ask
      where
        g m =
            let n = I.delete (fromIntegral (outPointIndex op)) m
             in if I.null n
                    then Nothing
                    else Just n
    pruneUnspent = do
        v <- R.ask
        lift . modifyTVar v $ \um ->
            if M.size um > 2 ^ (21 :: Int)
                then let g is = unspentBlock (head (I.elems is))
                         ls =
                             sortBy
                                 (compare `on` (g . snd))
                                 (filter (not . I.null . snd) (M.toList um))
                      in M.fromList (drop (2 ^ (20 :: Int)) ls)
                else um

instance BalanceRead BalanceSTM where
    getBalance a = do
        b <- fmap fst $ lift . readTVar =<< R.ask
        return $ M.lookup a b

instance BalanceWrite BalanceSTM where
    setBalance b = do
        v <- R.ask
        lift . modifyTVar v $ \(m, s) ->
            let m' = M.insert (balanceAddress b) b m
                s' = balanceAddress b : s
             in (m', s')
    pruneBalance = do
        v <- R.ask
        lift . modifyTVar v $ \(m, s) ->
            if length s > 2 ^ (21 :: Int)
                then let s' = take (2 ^ (20 :: Int)) s
                         m' = M.fromList (mapMaybe (g m) s')
                      in (m', s')
                else (m, s)
      where
        g m a = (a, ) <$> M.lookup a m
