{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Network.Haskoin.Store.Data.RocksDB where

import           Conduit
import           Control.Monad.Reader                (ReaderT)
import qualified Control.Monad.Reader                as R
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

type BlockDB = (ReadOptions, DB)

dataVersion :: Word32
dataVersion = 14

withBlockDB :: ReadOptions -> DB -> ReaderT BlockDB m a -> m a
withBlockDB opts db f = R.runReaderT f (opts, db)

data ExceptRocksDB =
    MempoolTxNotFound
    deriving (Eq, Show, Read, Exception)

isInitializedDB ::
       MonadIO m => ReadOptions -> DB -> m (Either InitException Bool)
isInitializedDB opts db =
    retrieve db opts VersionKey >>= \case
        Just v
            | v == dataVersion -> return (Right True)
            | otherwise -> return (Left (IncorrectVersion v))
        Nothing -> return (Right False)

getBestBlockDB :: MonadIO m => ReadOptions -> DB -> m (Maybe BlockHash)
getBestBlockDB opts db = retrieve db opts BestKey

getBlocksAtHeightDB ::
       MonadIO m => BlockHeight -> ReadOptions -> DB -> m [BlockHash]
getBlocksAtHeightDB h opts db =
    retrieve db opts (HeightKey h) >>= \case
        Nothing -> return []
        Just ls -> return ls

getBlockDB :: MonadIO m => BlockHash -> ReadOptions -> DB -> m (Maybe BlockData)
getBlockDB h opts db = retrieve db opts (BlockKey h)

getTxDataDB ::
       MonadIO m => TxHash -> ReadOptions -> DB -> m (Maybe TxData)
getTxDataDB th opts db = retrieve db opts (TxKey th)

getSpenderDB :: MonadIO m => OutPoint -> ReadOptions -> DB -> m (Maybe Spender)
getSpenderDB op opts db = retrieve db opts $ SpenderKey op

getSpendersDB :: MonadIO m => TxHash -> ReadOptions -> DB -> m (IntMap Spender)
getSpendersDB th opts db =
    I.fromList . map (uncurry f) <$>
    liftIO (matchingAsList db opts (SpenderKeyS th))
  where
    f (SpenderKey op) s = (fromIntegral (outPointIndex op), s)
    f _ _               = undefined

getBalanceDB :: MonadIO m => Address -> ReadOptions -> DB -> m (Maybe Balance)
getBalanceDB a opts db = fmap f <$> retrieve db opts (BalKey a)
  where
    f BalVal { balValAmount = v
             , balValZero = z
             , balValUnspentCount = c
             , balValTxCount = t
             , balValTotalReceived = r
             } =
        Balance
            { balanceAddress = a
            , balanceAmount = v
            , balanceZero = z
            , balanceUnspentCount = c
            , balanceTxCount = t
            , balanceTotalReceived = r
            }

getMempoolDB ::
       (MonadIO m, MonadResource m)
    => Maybe PreciseUnixTime
    -> ReadOptions
    -> DB
    -> ConduitT () (PreciseUnixTime, TxHash) m ()
getMempoolDB mpu opts db = x .| mapC (uncurry f)
  where
    x =
        case mpu of
            Nothing -> matching db opts MemKeyS
            Just pu -> matchingSkip db opts MemKeyS (MemKeyT pu)
    f (MemKey u t) () = (u, t)
    f _ _             = undefined

getAddressTxsDB ::
       (MonadIO m, MonadResource m)
    => Address
    -> Maybe BlockRef
    -> ReadOptions
    -> DB
    -> ConduitT () BlockTx m ()
getAddressTxsDB a mbr opts db = x .| mapC (uncurry f)
  where
    x =
        case mbr of
            Nothing -> matching db opts (AddrTxKeyA a)
            Just br -> matchingSkip db opts (AddrTxKeyA a) (AddrTxKeyB a br)
    f AddrTxKey {addrTxKeyT = t} () = t
    f _ _                           = undefined

getAddressUnspentsDB ::
       (MonadIO m, MonadResource m)
    => Address
    -> Maybe BlockRef
    -> ReadOptions
    -> DB
    -> ConduitT () Unspent m ()
getAddressUnspentsDB a mbr opts db = x .| mapC (uncurry f)
  where
    x =
        case mbr of
            Nothing -> matching db opts (AddrOutKeyA a)
            Just br -> matchingSkip db opts (AddrOutKeyA a) (AddrOutKeyB a br)
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

getUnspentDB :: MonadIO m => OutPoint -> ReadOptions -> DB -> m (Maybe Unspent)
getUnspentDB op opts db = fmap f <$> retrieve db opts (UnspentKey op)
  where
    f u =
        Unspent
            { unspentBlock = unspentValBlock u
            , unspentPoint = op
            , unspentAmount = unspentValAmount u
            , unspentScript = B.Short.toShort (unspentValScript u)
            }

setInitDB :: MonadIO m => DB -> m ()
setInitDB db = insert db VersionKey dataVersion

instance MonadIO m => StoreRead (ReaderT BlockDB m) where
    isInitialized = R.ask >>= uncurry isInitializedDB
    getBestBlock = R.ask >>= uncurry getBestBlockDB
    getBlocksAtHeight h = R.ask >>= uncurry (getBlocksAtHeightDB h)
    getBlock h = R.ask >>= uncurry (getBlockDB h)
    getTxData t = R.ask >>= uncurry (getTxDataDB t)
    getSpenders p = R.ask >>= uncurry (getSpendersDB p)
    getSpender p = R.ask >>= uncurry (getSpenderDB p)

instance (MonadIO m, MonadResource m) =>
         StoreStream (ReaderT BlockDB m) where
    getMempool p = lift R.ask >>= uncurry (getMempoolDB p)
    getAddressTxs a b = R.ask >>= uncurry (getAddressTxsDB a b)
    getAddressUnspents a b = R.ask >>= uncurry (getAddressUnspentsDB a b)

instance (MonadIO m) => BalanceRead (ReaderT BlockDB m) where
    getBalance a = R.ask >>= uncurry (getBalanceDB a)

instance (MonadIO m) => UnspentRead (ReaderT BlockDB m) where
    getUnspent p = R.ask >>= uncurry (getUnspentDB p)
