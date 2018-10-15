{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Network.Haskoin.Store.Data.HashMap where

import           Conduit
import           Data.HashMap.Strict                 (HashMap)
import qualified Data.HashMap.Strict                 as M
import           Data.List
import           Data.Maybe
import           Haskoin
import           Network.Haskoin.Store.Data
import           Network.Haskoin.Store.Data.KeyValue
import           UnliftIO

data HashMapDB = HashMapDB
    { hBest :: !(Maybe BlockHash)
    , hBlock :: !(HashMap BlockHash BlockData)
    , hHeight :: !(HashMap BlockHeight [BlockHash])
    , hTx :: !(HashMap TxHash Transaction)
    , hBalance :: !(HashMap Address (Maybe BalVal))
    , hAddrTx :: !(HashMap Address (HashMap BlockRef (HashMap TxHash Bool)))
    , hAddrOut :: !(HashMap Address (HashMap BlockRef (HashMap OutPoint (Maybe OutVal))))
    , hMempool :: !(HashMap PreciseUnixTime (HashMap TxHash Bool))
    , hInit :: !Bool
    } deriving (Eq, Show)

emptyHashMapDB :: HashMapDB
emptyHashMapDB =
    HashMapDB
        { hBest = Nothing
        , hBlock = M.empty
        , hHeight = M.empty
        , hTx = M.empty
        , hBalance = M.empty
        , hAddrTx = M.empty
        , hAddrOut = M.empty
        , hMempool = M.empty
        , hInit = False
        }

isInitializedH :: HashMapDB -> Either InitException Bool
isInitializedH = Right . hInit

getBestBlockH :: HashMapDB -> Maybe BlockHash
getBestBlockH = hBest

getBlocksAtHeightH ::
       HashMapDB -> BlockHeight -> [BlockHash]
getBlocksAtHeightH db h = M.lookupDefault [] h (hHeight db)

getBlockH :: HashMapDB -> BlockHash -> Maybe BlockData
getBlockH db h = M.lookup h (hBlock db)

getTransactionH :: HashMapDB -> TxHash -> Maybe Transaction
getTransactionH db t = M.lookup t (hTx db)

getBalanceH :: HashMapDB -> Address -> Maybe Balance
getBalanceH db a =
    case M.lookup a (hBalance db) of
        Nothing -> Nothing
        Just Nothing ->
            Just
                Balance
                    { balanceAddress = a
                    , balanceAmount = 0
                    , balanceZero = 0
                    , balanceCount = 0
                    }
        Just (Just b) ->
            Just
                Balance
                    { balanceAddress = a
                    , balanceAmount = balValAmount b
                    , balanceZero = balValZero b
                    , balanceCount = balValCount b
                    }

getMempoolH :: HashMapDB -> HashMap PreciseUnixTime (HashMap TxHash Bool)
getMempoolH = hMempool

getAddressTxsH :: HashMapDB -> Address -> [Maybe AddressTx]
getAddressTxsH db a =
    concatMap (uncurry f) . M.toList $ M.lookupDefault M.empty a (hAddrTx db)
  where
    f b hm = map (uncurry (g b)) $ M.toList hm
    g b h True =
        Just
            AddressTx
                {addressTxAddress = a, addressTxBlock = b, addressTxHash = h}
    g _ _ False = Nothing

getAddressUnspentsH ::
       HashMapDB -> Address -> [Maybe Unspent]
getAddressUnspentsH db a =
    concatMap (uncurry f) . M.toList $ M.lookupDefault M.empty a (hAddrOut db)
  where
    f b hm = map (uncurry (g b)) $ M.toList hm
    g b p (Just u) =
        Just
            Unspent
                { unspentBlock = b
                , unspentAmount = outValAmount u
                , unspentScript = outValScript u
                , unspentPoint = p
                }
    g _ _ Nothing = Nothing

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

insertTxH :: Transaction -> HashMapDB -> HashMapDB
insertTxH tx db = db {hTx = M.insert (txHash (transactionData tx)) tx (hTx db)}

setBalanceH :: Balance -> HashMapDB -> HashMapDB
setBalanceH b db = db {hBalance = M.insert (balanceAddress b) x (hBalance db)}
  where
    x =
        case b of
            Balance {balanceAmount = 0, balanceZero = 0, balanceCount = 0} ->
                Nothing
            Balance {balanceAmount = v, balanceZero = z, balanceCount = c} ->
                Just BalVal {balValAmount = v, balValZero = z, balValCount = c}

insertAddrTxH :: AddressTx -> HashMapDB -> HashMapDB
insertAddrTxH a db =
    let s =
            M.singleton
                (addressTxAddress a)
                (M.singleton
                     (addressTxBlock a)
                     (M.singleton (addressTxHash a) True))
     in db {hAddrTx = M.unionWith (M.unionWith M.union) s (hAddrTx db)}

removeAddrTxH :: AddressTx -> HashMapDB -> HashMapDB
removeAddrTxH a db =
    let s =
            M.singleton
                (addressTxAddress a)
                (M.singleton
                     (addressTxBlock a)
                     (M.singleton (addressTxHash a) False))
     in db {hAddrTx = M.unionWith (M.unionWith M.union) s (hAddrTx db)}

insertAddrUnspentH :: Address -> Unspent -> HashMapDB -> HashMapDB
insertAddrUnspentH a u db =
    let uns =
            OutVal
                { outValAmount = unspentAmount u
                , outValScript = unspentScript u
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

insertMempoolTxH :: TxHash -> PreciseUnixTime -> HashMapDB -> HashMapDB
insertMempoolTxH h u db =
    let s = M.singleton u (M.singleton h True)
     in db {hMempool = M.unionWith M.union s (hMempool db)}

deleteMempoolTxH :: TxHash -> PreciseUnixTime -> HashMapDB -> HashMapDB
deleteMempoolTxH h u db =
    let s = M.singleton u (M.singleton h False)
     in db {hMempool = M.unionWith M.union s (hMempool db)}

instance Applicative m => StoreRead HashMapDB m where
    isInitialized = pure . isInitializedH
    getBestBlock = pure . getBestBlockH
    getBlocksAtHeight db = pure . getBlocksAtHeightH db
    getBlock db = pure . getBlockH db
    getTransaction db = pure . getTransactionH db
    getBalance db a = pure . fromMaybe b $ getBalanceH db a
      where
        b = Balance { balanceAddress = a
                    , balanceAmount = 0
                    , balanceZero = 0
                    , balanceCount = 0
                    }

instance Monad m => StoreStream HashMapDB m where
    getMempool db =
        let ls = M.toList . M.map (M.keys . M.filter id) $ getMempoolH db
         in yieldMany [(u, h) | (u, hs) <- ls, h <- hs]
    getAddressTxs db = yieldMany . sort . catMaybes . getAddressTxsH db
    getAddressUnspents db =
        yieldMany . sort . catMaybes . getAddressUnspentsH db

instance MonadIO m => StoreRead (TVar HashMapDB) m where
    isInitialized v = atomically $ readTVar v >>= isInitialized
    getBestBlock v = atomically $ readTVar v >>= getBestBlock
    getBlocksAtHeight v h =
        atomically $ readTVar v >>= \db -> getBlocksAtHeight db h
    getBlock v b = atomically $ readTVar v >>= \db -> getBlock db b
    getTransaction v t = atomically $ readTVar v >>= \db -> getTransaction db t
    getBalance v t = atomically $ readTVar v >>= \db -> getBalance db t

instance MonadIO m => StoreStream (TVar HashMapDB) m where
    getMempool v = readTVarIO v >>= getMempool
    getAddressTxs v a = readTVarIO v >>= \db -> getAddressTxs db a
    getAddressUnspents v a = readTVarIO v >>= \db -> getAddressUnspents db a

instance StoreWrite ((HashMapDB -> HashMapDB) -> m ()) m where
    setInit f = f setInitH
    setBest f = f . setBestH
    insertBlock f = f . insertBlockH
    insertAtHeight f h = f . insertAtHeightH h
    insertTx f = f . insertTxH
    setBalance f = f . setBalanceH
    insertAddrTx f = f . insertAddrTxH
    removeAddrTx f = f . removeAddrTxH
    insertAddrUnspent f a = f . insertAddrUnspentH a
    removeAddrUnspent f a = f . removeAddrUnspentH a
    insertMempoolTx f h = f . insertMempoolTxH h
    deleteMempoolTx f h = f . deleteMempoolTxH h

instance MonadIO m => StoreWrite (TVar HashMapDB) m where
    setInit v = atomically $ setInit (modifyTVar v)
    setBest v = atomically . setBest (modifyTVar v)
    insertBlock v = atomically . insertBlock (modifyTVar v)
    insertAtHeight v h = atomically . insertAtHeight (modifyTVar v) h
    insertTx v = atomically . insertTx (modifyTVar v)
    setBalance v = atomically . setBalance (modifyTVar v)
    insertAddrTx v = atomically . insertAddrTx (modifyTVar v)
    removeAddrTx v = atomically . removeAddrTx (modifyTVar v)
    insertAddrUnspent v a = atomically . insertAddrUnspent (modifyTVar v) a
    removeAddrUnspent v a = atomically . removeAddrUnspent (modifyTVar v) a
    insertMempoolTx v h = atomically . insertMempoolTx (modifyTVar v) h
    deleteMempoolTx v h = atomically . deleteMempoolTx (modifyTVar v) h
