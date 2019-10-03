{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase     #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Network.Haskoin.Store.Data.RocksDB where

import           Conduit
import           Control.Monad.Reader                (MonadReader, ReaderT)
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

dataVersion :: Word32
dataVersion = 15

isInitializedDB :: MonadIO m => BlockDB -> m (Either InitException Bool)
isInitializedDB BlockDB {blockDBopts = opts, blockDB = db} =
    retrieve db opts VersionKey >>= \case
        Just v
            | v == dataVersion -> return (Right True)
            | otherwise -> return (Left (IncorrectVersion v))
        Nothing -> return (Right False)

setInitDB :: MonadIO m => DB -> m ()
setInitDB db = insert db VersionKey dataVersion

getBestBlockDB :: MonadIO m => BlockDB -> m (Maybe BlockHash)
getBestBlockDB BlockDB {blockDBopts = opts, blockDB = db} =
    retrieve db opts BestKey

getBlocksAtHeightDB :: MonadIO m => BlockHeight -> BlockDB -> m [BlockHash]
getBlocksAtHeightDB h BlockDB {blockDBopts = opts, blockDB = db} =
    retrieve db opts (HeightKey h) >>= \case
        Nothing -> return []
        Just ls -> return ls

getBlockDB :: MonadIO m => BlockHash -> BlockDB -> m (Maybe BlockData)
getBlockDB h BlockDB {blockDBopts = opts, blockDB = db} =
    retrieve db opts (BlockKey h)

getTxDataDB ::
       MonadIO m => TxHash -> BlockDB -> m (Maybe TxData)
getTxDataDB th BlockDB {blockDBopts = opts, blockDB = db} =
    retrieve db opts (TxKey th)

getSpenderDB :: MonadIO m => OutPoint -> BlockDB -> m (Maybe Spender)
getSpenderDB op BlockDB {blockDBopts = opts, blockDB = db} =
    retrieve db opts $ SpenderKey op

getSpendersDB :: MonadIO m => TxHash -> BlockDB -> m (IntMap Spender)
getSpendersDB th BlockDB {blockDBopts = opts, blockDB = db} =
    I.fromList . map (uncurry f) <$>
    liftIO (matchingAsList db opts (SpenderKeyS th))
  where
    f (SpenderKey op) s = (fromIntegral (outPointIndex op), s)
    f _ _               = undefined

getBalanceDB :: MonadIO m => Address -> BlockDB -> m (Maybe Balance)
getBalanceDB a BlockDB {blockDBopts = opts, blockDB = db} =
    fmap (balValToBalance a) <$> retrieve db opts (BalKey a)

getMempoolDB ::
       (MonadIO m, MonadResource m)
    => BlockDB
    -> ConduitT i (UnixTime, TxHash) m ()
getMempoolDB BlockDB {blockDBopts = opts, blockDB = db} =
    x .| mapC (uncurry f)
  where
    x = matching db opts MemKeyS
    f (MemKey u t) () = (u, t)
    f _ _             = undefined

getOrphansDB ::
       (MonadIO m, MonadResource m)
    => BlockDB
    -> ConduitT i (UnixTime, Tx) m ()
getOrphansDB BlockDB {blockDBopts = opts, blockDB = db} =
    matching db opts OrphanKeyS .| mapC snd

getOrphanTxDB :: MonadIO m => TxHash -> BlockDB -> m (Maybe (UnixTime, Tx))
getOrphanTxDB h BlockDB {blockDBopts = opts, blockDB = db} =
    retrieve db opts (OrphanKey h)

getAddressTxsDB ::
       (MonadIO m, MonadResource m)
    => Address
    -> Maybe BlockRef
    -> BlockDB
    -> ConduitT i BlockTx m ()
getAddressTxsDB a mbr BlockDB {blockDBopts = opts, blockDB = db} =
    x .| mapC (uncurry f)
  where
    x =
        case mbr of
            Nothing -> matching db opts (AddrTxKeyA a)
            Just br -> matchingSkip db opts (AddrTxKeyA a) (AddrTxKeyB a br)
    f AddrTxKey {addrTxKeyT = t} () = t
    f _ _                           = undefined

getAddressBalancesDB ::
       (MonadIO m, MonadResource m)
    => BlockDB
    -> ConduitT i Balance m ()
getAddressBalancesDB BlockDB {blockDBopts = opts, blockDB = db} =
    matching db opts BalKeyS .| mapC (\(BalKey a, b) -> balValToBalance a b)

getUnspentsDB ::
       (MonadIO m, MonadResource m)
    => BlockDB
    -> ConduitT i Unspent m ()
getUnspentsDB BlockDB {blockDBopts = opts, blockDB = db} =
    matching db opts UnspentKeyB .|
    mapC (\(UnspentKey k, v) -> unspentFromDB k v)

getUnspentDB :: MonadIO m => OutPoint -> BlockDB -> m (Maybe Unspent)
getUnspentDB p BlockDB {blockDBopts = opts, blockDB = db} =
    fmap (unspentValToUnspent p) <$> retrieve db opts (UnspentKey p)

getAddressUnspentsDB ::
       (MonadIO m, MonadResource m)
    => Address
    -> Maybe BlockRef
    -> BlockDB
    -> ConduitT i Unspent m ()
getAddressUnspentsDB a mbr BlockDB {blockDBopts = opts, blockDB = db} =
    x .| mapC (uncurry f)
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

unspentFromDB :: OutPoint -> UnspentVal -> Unspent
unspentFromDB p UnspentVal { unspentValBlock = b
                           , unspentValAmount = v
                           , unspentValScript = s
                           } =
    Unspent
        { unspentBlock = b
        , unspentAmount = v
        , unspentPoint = p
        , unspentScript = s
        }
