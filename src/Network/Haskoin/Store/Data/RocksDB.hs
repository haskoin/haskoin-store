{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Network.Haskoin.Store.Data.RocksDB where

import           Conduit
import qualified Data.ByteString.Short               as B.Short
import           Data.IntMap                         (IntMap)
import qualified Data.IntMap.Strict                  as I
import           Data.Word
import           Database.RocksDB                    (DB, ReadOptions)
import           Database.RocksDB.Query
import           Haskoin
import           Network.Haskoin.Store.Data
import           Network.Haskoin.Store.Data.KeyValue
import           UnliftIO

dataVersion :: Word32
dataVersion = 11

data ExceptRocksDB =
    MempoolTxNotFound
    deriving (Eq, Show, Read, Exception)

isInitializedDB :: MonadIO m => DB -> ReadOptions -> m (Either InitException Bool)
isInitializedDB db opts =
    retrieve db opts VersionKey >>= \case
        Just v
            | v == dataVersion -> return (Right True)
            | otherwise -> return (Left (IncorrectVersion v))
        Nothing -> return (Right False)

getBestBlockDB :: MonadIO m => DB -> ReadOptions -> m (Maybe BlockHash)
getBestBlockDB db opts = retrieve db opts BestKey

getBlocksAtHeightDB ::
       MonadIO m => DB -> ReadOptions -> BlockHeight -> m [BlockHash]
getBlocksAtHeightDB db opts h =
    retrieve db opts (HeightKey h) >>= \case
        Nothing -> return []
        Just ls -> return ls

getBlockDB :: MonadIO m => DB -> ReadOptions -> BlockHash -> m (Maybe BlockData)
getBlockDB db opts h = retrieve db opts (BlockKey h)

getTxDataDB ::
       MonadIO m => DB -> ReadOptions -> TxHash -> m (Maybe TxData)
getTxDataDB db opts th = retrieve db opts (TxKey th)

getSpenderDB :: MonadIO m => DB -> ReadOptions -> OutPoint -> m (Maybe Spender)
getSpenderDB db opts = retrieve db opts . SpenderKey

getSpendersDB :: MonadIO m => DB -> ReadOptions -> TxHash -> m (IntMap Spender)
getSpendersDB db opts th =
    I.fromList . map (uncurry f) <$>
    liftIO (matchingAsList db opts (SpenderKeyS th))
  where
    f (SpenderKey op) s = (fromIntegral (outPointIndex op), s)
    f _ _ = undefined

getBalanceDB :: MonadIO m => DB -> ReadOptions -> Address -> m (Maybe Balance)
getBalanceDB db opts a = fmap f <$> retrieve db opts (BalKey a)
  where
    f BalVal { balValAmount = v
             , balValZero = z
             , balValUnspentCount = c
             , balValTotalReceived = r
             } =
        Balance
            { balanceAddress = a
            , balanceAmount = v
            , balanceZero = z
            , balanceUnspentCount = c
            , balanceTotalReceived = r
            }

getMempoolDB ::
       (MonadIO m, MonadResource m)
    => DB
    -> ReadOptions
    -> Maybe PreciseUnixTime
    -> ConduitT () (PreciseUnixTime, TxHash) m ()
getMempoolDB db opts mpu =
    matching db opts k .| mapC (uncurry f) .| filterC (g . fst)
  where
    k = case mpu of Nothing -> MemKeyS
                    Just pu -> MemKeyT pu
    f (MemKey u t) () = (u, t)
    f _ _ = undefined
    g u =
        case mpu of
            Nothing -> True
            Just pu -> pu > u

getAddressTxsDB ::
       (MonadIO m, MonadResource m)
    => DB
    -> ReadOptions
    -> Address
    -> Maybe BlockRef
    -> ConduitT () AddressTx m ()
getAddressTxsDB db opts a mbr =
    matching db opts k .| mapC (uncurry f) .| filterC g
  where
    k =
        case mbr of
            Nothing -> AddrTxKeyA a
            Just br -> AddrTxKeyB a br
    f AddrTxKey {addrTxKey = t} () = t
    f _ _ = undefined
    g AddressTx {addressTxBlock = b} =
        case mbr of
            Nothing -> True
            Just br -> br > b

getAddressUnspentsDB ::
       (MonadIO m, MonadResource m)
    => DB
    -> ReadOptions
    -> Address
    -> Maybe BlockRef
    -> ConduitT () Unspent m ()
getAddressUnspentsDB db opts a mbr =
    matching db opts k .| mapC (uncurry f) .| filterC g
  where
    k =
        case mbr of
            Nothing -> AddrOutKeyA a
            Just br -> AddrOutKeyB a br
    f AddrOutKey {addrOutKeyB = b, addrOutKeyP = p} OutVal { outValAmount = v
                                                           , outValScript = s
                                                           } =
        Unspent
            { unspentBlock = b
            , unspentAmount = v
            , unspentScript = B.Short.toShort s
            , unspentPoint = p
            }
    f _ _ = undefined
    g Unspent {unspentBlock = b} =
        case mbr of
            Nothing -> True
            Just br -> br > b

getUnspentDB :: MonadIO m => DB -> ReadOptions -> OutPoint -> m (Maybe Unspent)
getUnspentDB db opts op = fmap f <$> retrieve db opts (UnspentKey op)
  where
    f u =
        Unspent
            { unspentBlock = unspentValBlock u
            , unspentPoint = op
            , unspentAmount = unspentValAmount u
            , unspentScript = B.Short.toShort (unspentValScript u)
            }

instance MonadIO m => StoreRead (DB, ReadOptions) m where
    isInitialized (db, opts) = isInitializedDB db opts
    getBestBlock (db, opts) = getBestBlockDB db opts
    getBlocksAtHeight (db, opts) = getBlocksAtHeightDB db opts
    getBlock (db, opts) = getBlockDB db opts
    getTxData (db, opts) = getTxDataDB db opts
    getSpenders (db, opts) = getSpendersDB db opts
    getSpender (db, opts) = getSpenderDB db opts

instance (MonadIO m, MonadResource m) => StoreStream (DB, ReadOptions) m where
    getMempool (db, opts) = getMempoolDB db opts
    getAddressTxs (db, opts) = getAddressTxsDB db opts
    getAddressUnspents (db, opts) = getAddressUnspentsDB db opts

instance MonadIO m => BalanceRead (DB, ReadOptions) m where
    getBalance (db, opts) = getBalanceDB db opts

instance MonadIO m => UnspentRead (DB, ReadOptions) m where
    getUnspent (db, opts) = getUnspentDB db opts

setInitDB :: MonadIO m => DB -> m ()
setInitDB db = insert db VersionKey dataVersion
