{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
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
dataVersion = 15

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
getBalanceDB a opts db =
    fmap (balValToBalance a) <$> retrieve db opts (BalKey a)

getMempoolDB ::
       (MonadIO m, MonadResource m)
    => Maybe UnixTime
    -> ReadOptions
    -> DB
    -> ConduitT () (UnixTime, TxHash) m ()
getMempoolDB mpu opts db = x .| mapC (uncurry f)
  where
    x =
        case mpu of
            Nothing -> matching db opts MemKeyS
            Just pu -> matchingSkip db opts MemKeyS (MemKeyT pu)
    f (MemKey u t) () = (u, t)
    f _ _             = undefined

getOrphansDB ::
       (MonadIO m, MonadResource m)
    => ReadOptions
    -> DB
    -> ConduitT () (UnixTime, Tx) m ()
getOrphansDB opts db = matching db opts OrphanKeyS .| mapC snd

getOrphanTxDB ::
       MonadIO m => TxHash -> ReadOptions -> DB -> m (Maybe (UnixTime, Tx))
getOrphanTxDB h opts db = retrieve db opts (OrphanKey h)

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

getAddressBalancesDB ::
       (MonadIO m, MonadResource m)
    => ReadOptions
    -> DB
    -> ConduitT () Balance m ()
getAddressBalancesDB opts db =
    matching db opts BalKeyS .| mapC (\(BalKey a, b) -> balValToBalance a b)

getUnspentsDB ::
       (MonadIO m, MonadResource m)
    => ReadOptions
    -> DB
    -> ConduitT () Unspent m ()
getUnspentsDB opts db =
    matching db opts UnspentKeyB .|
    mapC (\(UnspentKey k, v) -> unspentFromDB k v)

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

getUnspentDB :: MonadIO m => OutPoint -> ReadOptions -> DB -> m (Maybe Unspent)
getUnspentDB op opts db =
    fmap (unspentFromDB op) <$> retrieve db opts (UnspentKey op)

setInitDB :: MonadIO m => DB -> m ()
setInitDB db = insert db VersionKey dataVersion

setBalanceDB :: MonadIO m => Balance -> DB -> m ()
setBalanceDB bal db = insert db (BalKey a) b
  where
    (a, b) = balanceToBalVal bal

insertUnspentDB :: MonadIO m => Unspent -> DB -> m ()
insertUnspentDB uns db = insert db (UnspentKey p) u
  where
    (p, u) = unspentToUnspentVal uns

deleteUnspentDB :: MonadIO m => OutPoint -> DB -> m ()
deleteUnspentDB op db = remove db (UnspentKey op)

setBestDB :: MonadIO m => BlockHash -> DB -> m ()
setBestDB h db = insert db BestKey h

insertBlockDB :: MonadIO m => BlockData -> DB -> m ()
insertBlockDB b db = insert db (BlockKey (headerHash (blockDataHeader b))) b

insertAtHeightDB ::
       MonadIO m => BlockHash -> BlockHeight -> ReadOptions -> DB -> m ()
insertAtHeightDB bh he opts db = do
    bs <- getBlocksAtHeightDB he opts db
    insert db (HeightKey he) (bh : bs)

insertTxDB :: MonadIO m => TxData -> DB -> m ()
insertTxDB t db = insert db (TxKey (txHash (txData t))) t

insertSpenderDB :: MonadIO m => OutPoint -> Spender -> DB -> m ()
insertSpenderDB op s db = insert db (SpenderKey op) s

deleteSpenderDB :: MonadIO m => OutPoint -> DB -> m ()
deleteSpenderDB op db = remove db (SpenderKey op)

insertAddrTxDB :: MonadIO m => Address -> BlockTx -> DB -> m ()
insertAddrTxDB a t db = insert db (AddrTxKey a t) ()

deleteAddrTxDB :: MonadIO m => Address -> BlockTx -> DB -> m ()
deleteAddrTxDB a t db = remove db (AddrTxKey a t)

insertAddrUnspentDB :: MonadIO m => Address -> Unspent -> DB -> m ()
insertAddrUnspentDB a Unspent { unspentBlock = b
                              , unspentPoint = p
                              , unspentAmount = v
                              , unspentScript = s
                              } db =
    insert
        db
        AddrOutKey {addrOutKeyA = a, addrOutKeyB = b, addrOutKeyP = p}
        OutVal {outValAmount = v, outValScript = B.Short.fromShort s}

deleteAddrUnspentDB :: MonadIO m => Address -> Unspent -> DB -> m ()
deleteAddrUnspentDB a Unspent {unspentBlock = b, unspentPoint = p} db =
    remove db AddrOutKey {addrOutKeyA = a, addrOutKeyB = b, addrOutKeyP = p}

insertMempoolTxDB :: MonadIO m => TxHash -> UnixTime -> DB -> m ()
insertMempoolTxDB h t db = insert db MemKey {memTime = t, memKey = h} ()

deleteMempoolTxDB :: MonadIO m => TxHash -> UnixTime -> DB -> m ()
deleteMempoolTxDB h t db = remove db MemKey {memTime = t, memKey = h}

insertOrphanTxDB :: MonadIO m => Tx -> UnixTime -> DB -> m ()
insertOrphanTxDB t u db = insert db (OrphanKey (txHash t)) (u, t)

deleteOrphanTxDB :: MonadIO m => TxHash -> DB -> m ()
deleteOrphanTxDB h db = remove db (OrphanKey h)

instance MonadIO m => StoreRead (ReaderT BlockDB m) where
    isInitialized = R.ask >>= uncurry isInitializedDB
    getBestBlock = R.ask >>= uncurry getBestBlockDB
    getBlocksAtHeight h = R.ask >>= uncurry (getBlocksAtHeightDB h)
    getBlock h = R.ask >>= uncurry (getBlockDB h)
    getTxData t = R.ask >>= uncurry (getTxDataDB t)
    getSpenders p = R.ask >>= uncurry (getSpendersDB p)
    getSpender p = R.ask >>= uncurry (getSpenderDB p)
    getOrphanTx h = R.ask >>= uncurry (getOrphanTxDB h)
    getBalance a = R.ask >>= uncurry (getBalanceDB a)
    getUnspent p = R.ask >>= uncurry (getUnspentDB p)

instance (MonadIO m, MonadResource m) =>
         StoreStream (ReaderT BlockDB m) where
    getMempool p = lift R.ask >>= uncurry (getMempoolDB p)
    getOrphans = lift R.ask >>= uncurry getOrphansDB
    getAddressTxs a b = R.ask >>= uncurry (getAddressTxsDB a b)
    getAddressUnspents a b = R.ask >>= uncurry (getAddressUnspentsDB a b)
    getAddressBalances = R.ask >>= uncurry getAddressBalancesDB
    getUnspents = R.ask >>= uncurry getUnspentsDB

instance MonadIO m => StoreWrite (ReaderT BlockDB m) where
    setInit = R.ask >>= setInitDB . snd
    setBest h = R.ask >>= setBestDB h . snd
    insertBlock b = R.ask >>= insertBlockDB b . snd
    insertAtHeight h g = R.ask >>= uncurry (insertAtHeightDB h g)
    insertTx t = R.ask >>= insertTxDB t . snd
    insertSpender p s = R.ask >>= insertSpenderDB p s . snd
    deleteSpender p = R.ask >>= deleteSpenderDB p . snd
    insertAddrTx a t = R.ask >>= insertAddrTxDB a t . snd
    deleteAddrTx a t = R.ask >>= deleteAddrTxDB a t . snd
    insertAddrUnspent a u = R.ask >>= insertAddrUnspentDB a u . snd
    deleteAddrUnspent a u = R.ask >>= deleteAddrUnspentDB a u . snd
    insertMempoolTx h t = R.ask >>= insertMempoolTxDB h t . snd
    deleteMempoolTx h t = R.ask >>= deleteMempoolTxDB h t . snd
    insertOrphanTx t u = R.ask >>= insertOrphanTxDB t u . snd
    deleteOrphanTx h = R.ask >>= deleteOrphanTxDB h . snd
    setBalance b = R.ask >>= setBalanceDB b . snd
    insertUnspent u = R.ask >>= insertUnspentDB u . snd
    deleteUnspent p = R.ask >>= deleteUnspentDB p . snd
