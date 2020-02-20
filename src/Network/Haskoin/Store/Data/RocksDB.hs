{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Network.Haskoin.Store.Data.RocksDB where

import           Conduit                             (ConduitT, MonadResource,
                                                      mapC, runConduit,
                                                      runResourceT, sinkList,
                                                      (.|))
import           Control.Monad                       (forM_)
import           Control.Monad.Except                (runExceptT, throwError)
import           Control.Monad.Reader                (ReaderT, ask, runReaderT)
import           Data.Function                       (on)
import           Data.IntMap                         (IntMap)
import qualified Data.IntMap.Strict                  as I
import           Data.List                           (nub, sortBy)
import           Data.Maybe                          (fromMaybe)
import           Data.Word                           (Word32)
import           Database.RocksDB                    (Compression (..), DB,
                                                      Options (..),
                                                      defaultOptions,
                                                      defaultReadOptions, open)
import           Database.RocksDB.Query              (insert, matching,
                                                      matchingAsList,
                                                      matchingSkip, retrieve)
import           Haskoin                             (Address, BlockHash,
                                                      BlockHeight,
                                                      OutPoint (..), Tx, TxHash)
import           Network.Haskoin.Store.Data.KeyValue (AddrOutKey (..),
                                                      AddrTxKey (..),
                                                      BalKey (..), BestKey (..),
                                                      BlockKey (..),
                                                      HeightKey (..),
                                                      MemKey (..),
                                                      OldMemKey (..),
                                                      OrphanKey (..),
                                                      SpenderKey (..),
                                                      TxKey (..),
                                                      UnspentKey (..),
                                                      VersionKey (..),
                                                      toUnspent)
import           Network.Haskoin.Store.Data.Types    (Balance, BlockDB (..),
                                                      BlockData, BlockRef,
                                                      BlockTx (..), Limit,
                                                      Spender, StoreRead (..),
                                                      StoreStream (..), TxData,
                                                      UnixTime, Unspent (..),
                                                      UnspentVal (..),
                                                      applyLimit, valToBalance,
                                                      valToUnspent)
import           UnliftIO                            (MonadIO, liftIO)

dataVersion :: Word32
dataVersion = 16

connectRocksDB :: MonadIO m => FilePath -> m BlockDB
connectRocksDB dir = do
    bdb <- open
        dir
        defaultOptions
            { createIfMissing = True
            , compression = SnappyCompression
            , maxOpenFiles = -1
            , writeBufferSize = 2 ^ (30 :: Integer)
            } >>= \db ->
        return BlockDB {blockDBopts = defaultReadOptions, blockDB = db}
    initRocksDB bdb
    return bdb

withRocksDB :: MonadIO m => BlockDB -> ReaderT BlockDB m a -> m a
withRocksDB = flip runReaderT

initRocksDB :: MonadIO m => BlockDB -> m ()
initRocksDB bdb@BlockDB {blockDBopts = opts, blockDB = db} = do
    e <-
        runExceptT $
        retrieve db opts VersionKey >>= \case
            Just v
                | v == dataVersion -> return ()
                | v == 15 -> migrate15to16 bdb >> initRocksDB bdb
                | otherwise -> throwError "Incorrect RocksDB database version"
            Nothing -> setInitRocksDB db
    case e of
        Left s   -> error s
        Right () -> return ()

migrate15to16 :: MonadIO m => BlockDB -> m ()
migrate15to16 BlockDB {blockDBopts = opts, blockDB = db} = do
    xs <- liftIO $ matchingAsList db opts OldMemKeyS
    let ys = map (\(OldMemKey t h, ()) -> (t, h)) xs
    insert db MemKey ys
    insert db VersionKey (16 :: Word32)

setInitRocksDB :: MonadIO m => DB -> m ()
setInitRocksDB db = insert db VersionKey dataVersion

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
    fmap (valToBalance a) <$> retrieve db opts (BalKey a)

getMempoolDB :: MonadIO m => BlockDB -> m [(UnixTime, TxHash)]
getMempoolDB BlockDB {blockDBopts = opts, blockDB = db} =
    fromMaybe [] <$> retrieve db opts MemKey

getOrphansDB ::
       (MonadIO m, MonadResource m)
    => BlockDB
    -> ConduitT i (UnixTime, Tx) m ()
getOrphansDB BlockDB {blockDBopts = opts, blockDB = db} =
    matching db opts OrphanKeyS .| mapC snd

getOrphanTxDB :: MonadIO m => TxHash -> BlockDB -> m (Maybe (UnixTime, Tx))
getOrphanTxDB h BlockDB {blockDBopts = opts, blockDB = db} =
    retrieve db opts (OrphanKey h)

getAddressesTxsDB ::
       MonadIO m
    => [Address]
    -> Maybe BlockRef
    -> Maybe Limit
    -> BlockDB
    -> m [BlockTx]
getAddressesTxsDB addrs start limit db =
    liftIO . runResourceT $ do
        ts <-
            runConduit $
            forM_ addrs (\a -> getAddressTxsDB a start db .| applyLimit limit) .|
            sinkList
        let ts' = nub $ sortBy (flip compare `on` blockTxBlock) ts
        return $
            case limit of
                Just l  -> take (fromIntegral l) ts'
                Nothing -> ts'

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
    matching db opts BalKeyS .| mapC (\(BalKey a, b) -> valToBalance a b)

getUnspentsDB ::
       (MonadIO m, MonadResource m)
    => BlockDB
    -> ConduitT i Unspent m ()
getUnspentsDB BlockDB {blockDBopts = opts, blockDB = db} =
    matching db opts UnspentKeyB .|
    mapC (\(UnspentKey k, v) -> unspentFromDB k v)

getUnspentDB :: MonadIO m => OutPoint -> BlockDB -> m (Maybe Unspent)
getUnspentDB p BlockDB {blockDBopts = opts, blockDB = db} =
    fmap (valToUnspent p) <$> retrieve db opts (UnspentKey p)

getAddressesUnspentsDB ::
       MonadIO m
    => [Address]
    -> Maybe BlockRef
    -> Maybe Limit
    -> BlockDB
    -> m [Unspent]
getAddressesUnspentsDB addrs start limit bdb =
    liftIO . runResourceT $ do
        us <-
            runConduit $
            forM_
                addrs
                (\a -> getAddressUnspentsDB a start bdb .| applyLimit limit) .|
            sinkList
        let us' = nub $ sortBy (flip compare `on` unspentBlock) us
        return $
            case limit of
                Just l  -> take (fromIntegral l) us'
                Nothing -> us'

getAddressUnspentsDB ::
       (MonadIO m, MonadResource m)
    => Address
    -> Maybe BlockRef
    -> BlockDB
    -> ConduitT i Unspent m ()
getAddressUnspentsDB a mbr BlockDB {blockDBopts = opts, blockDB = db} =
    x .| mapC (uncurry toUnspent)
  where
    x =
        case mbr of
            Nothing -> matching db opts (AddrOutKeyA a)
            Just br -> matchingSkip db opts (AddrOutKeyA a) (AddrOutKeyB a br)

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

instance MonadIO m => StoreRead (ReaderT BlockDB m) where
    getBestBlock = ask >>= getBestBlockDB
    getBlocksAtHeight h = ask >>= getBlocksAtHeightDB h
    getBlock b = ask >>= getBlockDB b
    getTxData t = ask >>= getTxDataDB t
    getSpender p = ask >>= getSpenderDB p
    getSpenders t = ask >>= getSpendersDB t
    getOrphanTx h = ask >>= getOrphanTxDB h
    getUnspent a = ask >>= getUnspentDB a
    getBalance a = ask >>= getBalanceDB a
    getMempool = ask >>= getMempoolDB
    getAddressesTxs addrs start limit =
        ask >>= getAddressesTxsDB addrs start limit
    getAddressesUnspents addrs start limit =
        ask >>= getAddressesUnspentsDB addrs start limit

instance (MonadResource m, MonadIO m) => StoreStream (ReaderT BlockDB m) where
    getOrphans = ask >>= getOrphansDB
    getAddressUnspents a b = ask >>= getAddressUnspentsDB a b
    getAddressTxs a b = ask >>= getAddressTxsDB a b
    getAddressBalances = ask >>= getAddressBalancesDB
    getUnspents = ask >>= getUnspentsDB
