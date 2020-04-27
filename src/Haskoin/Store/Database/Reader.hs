{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
module Haskoin.Store.Database.Reader
    ( DatabaseReader (..)
    , DatabaseReaderT
    , connectRocksDB
    , withDatabaseReader
    ) where

import           Conduit                      (mapC, runConduit, runResourceT,
                                               sinkList, (.|))
import           Control.Monad.Except         (runExceptT, throwError)
import           Control.Monad.Reader         (ReaderT, ask, asks, runReaderT)
import           Data.Function                (on)
import           Data.IntMap                  (IntMap)
import qualified Data.IntMap.Strict           as I
import           Data.List                    (nub, sortBy)
import           Data.Maybe                   (fromMaybe)
import           Data.Word                    (Word32)
import           Database.RocksDB             (Compression (..), DB,
                                               Options (..), ReadOptions,
                                               defaultOptions,
                                               defaultReadOptions, open)
import           Database.RocksDB.Query       (insert, matching, matchingAsList,
                                               matchingSkip, retrieve)
import           Haskoin                      (Address, BlockHash, BlockHeight,
                                               Network, OutPoint (..), Tx,
                                               TxHash)
import           Haskoin.Store.Common         (Balance, BlockData,
                                               BlockRef (..), BlockTx (..),
                                               Limit, Spender, StoreRead (..),
                                               TxData, UnixTime, Unspent (..),
                                               applyLimit, applyLimitC,
                                               zeroBalance)
import           Haskoin.Store.Database.Types (AddrOutKey (..), AddrTxKey (..),
                                               BalKey (..), BestKey (..),
                                               BlockKey (..), HeightKey (..),
                                               MemKey (..), OldMemKey (..),
                                               OrphanKey (..), SpenderKey (..),
                                               TxKey (..), UnspentKey (..),
                                               VersionKey (..), toUnspent,
                                               valToBalance, valToUnspent)
import           UnliftIO                     (MonadIO, liftIO)

type DatabaseReaderT = ReaderT DatabaseReader

data DatabaseReader =
    DatabaseReader
        { databaseHandle      :: !DB
        , databaseReadOptions :: !ReadOptions
        , databaseMaxGap      :: !Word32
        , databaseInitialGap  :: !Word32
        , databaseNetwork     :: !Network
        }

dataVersion :: Word32
dataVersion = 16

connectRocksDB ::
       MonadIO m => Network -> Word32 -> Word32 -> FilePath -> m DatabaseReader
connectRocksDB net igap gap dir = do
    db <-
        open
            dir
            defaultOptions
                { createIfMissing = True
                , compression = SnappyCompression
                , maxOpenFiles = -1
                , writeBufferSize = 2 ^ (30 :: Integer)
                }
    let bdb =
            DatabaseReader
                { databaseReadOptions = defaultReadOptions
                , databaseHandle = db
                , databaseMaxGap = gap
                , databaseNetwork = net
                , databaseInitialGap = igap
                }
    initRocksDB bdb
    return bdb

withDatabaseReader :: MonadIO m => DatabaseReader -> DatabaseReaderT m a -> m a
withDatabaseReader = flip runReaderT

initRocksDB :: MonadIO m => DatabaseReader -> m ()
initRocksDB bdb@DatabaseReader {databaseReadOptions = opts, databaseHandle = db} = do
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

migrate15to16 :: MonadIO m => DatabaseReader -> m ()
migrate15to16 DatabaseReader {databaseReadOptions = opts, databaseHandle = db} = do
    xs <- liftIO $ matchingAsList db opts OldMemKeyS
    let ys = map (\(OldMemKey t h, ()) -> (t, h)) xs
    insert db MemKey ys
    insert db VersionKey (16 :: Word32)

setInitRocksDB :: MonadIO m => DB -> m ()
setInitRocksDB db = insert db VersionKey dataVersion

getBestDatabaseReader :: MonadIO m => DatabaseReader -> m (Maybe BlockHash)
getBestDatabaseReader DatabaseReader {databaseReadOptions = opts, databaseHandle = db} =
    retrieve db opts BestKey

getBlocksAtHeightDB :: MonadIO m => BlockHeight -> DatabaseReader -> m [BlockHash]
getBlocksAtHeightDB h DatabaseReader {databaseReadOptions = opts, databaseHandle = db} =
    retrieve db opts (HeightKey h) >>= \case
        Nothing -> return []
        Just ls -> return ls

getDatabaseReader :: MonadIO m => BlockHash -> DatabaseReader -> m (Maybe BlockData)
getDatabaseReader h DatabaseReader {databaseReadOptions = opts, databaseHandle = db} =
    retrieve db opts (BlockKey h)

getTxDataDB ::
       MonadIO m => TxHash -> DatabaseReader -> m (Maybe TxData)
getTxDataDB th DatabaseReader {databaseReadOptions = opts, databaseHandle = db} =
    retrieve db opts (TxKey th)

getSpenderDB :: MonadIO m => OutPoint -> DatabaseReader -> m (Maybe Spender)
getSpenderDB op DatabaseReader {databaseReadOptions = opts, databaseHandle = db} =
    retrieve db opts $ SpenderKey op

getSpendersDB :: MonadIO m => TxHash -> DatabaseReader -> m (IntMap Spender)
getSpendersDB th DatabaseReader {databaseReadOptions = opts, databaseHandle = db} =
    I.fromList . map (uncurry f) <$>
    liftIO (matchingAsList db opts (SpenderKeyS th))
  where
    f (SpenderKey op) s = (fromIntegral (outPointIndex op), s)
    f _ _               = undefined

getBalanceDB :: MonadIO m => Address -> DatabaseReader -> m Balance
getBalanceDB a DatabaseReader { databaseReadOptions = opts
                              , databaseHandle = db
                              } =
    fromMaybe (zeroBalance a) . fmap (valToBalance a) <$>
    retrieve db opts (BalKey a)

getMempoolDB :: MonadIO m => DatabaseReader -> m [BlockTx]
getMempoolDB DatabaseReader {databaseReadOptions = opts, databaseHandle = db} =
    fmap f . fromMaybe [] <$> retrieve db opts MemKey
  where
    f (t, h) = BlockTx {blockTxBlock = MemRef t, blockTxHash = h}

getOrphansDB ::
       MonadIO m
    => DatabaseReader
    -> m [(UnixTime, Tx)]
getOrphansDB DatabaseReader {databaseReadOptions = opts, databaseHandle = db} =
    liftIO . runResourceT . runConduit $
    matching db opts OrphanKeyS .| mapC snd .| sinkList

getOrphanTxDB :: MonadIO m => TxHash -> DatabaseReader -> m (Maybe (UnixTime, Tx))
getOrphanTxDB h DatabaseReader {databaseReadOptions = opts, databaseHandle = db} =
    retrieve db opts (OrphanKey h)

getAddressesTxsDB ::
       MonadIO m
    => [Address]
    -> Maybe BlockRef
    -> Maybe Limit
    -> DatabaseReader
    -> m [BlockTx]
getAddressesTxsDB addrs start limit db = do
    ts <- concat <$> mapM (\a -> getAddressTxsDB a start limit db) addrs
    let ts' = nub $ sortBy (flip compare `on` blockTxBlock) ts
    return $ applyLimit limit ts'

getAddressTxsDB ::
       MonadIO m
    => Address
    -> Maybe BlockRef
    -> Maybe Limit
    -> DatabaseReader
    -> m [BlockTx]
getAddressTxsDB a start limit DatabaseReader {databaseReadOptions = opts, databaseHandle = db} =
    liftIO . runResourceT . runConduit $
        x .| applyLimitC limit .| mapC (uncurry f) .| sinkList
  where
    x =
        case start of
            Nothing -> matching db opts (AddrTxKeyA a)
            Just br -> matchingSkip db opts (AddrTxKeyA a) (AddrTxKeyB a br)
    f AddrTxKey {addrTxKeyT = t} () = t
    f _ _                           = undefined

getUnspentDB :: MonadIO m => OutPoint -> DatabaseReader -> m (Maybe Unspent)
getUnspentDB p DatabaseReader { databaseReadOptions = opts
                              , databaseHandle = db
                              , databaseNetwork = net
                              } =
    fmap (valToUnspent net p) <$> retrieve db opts (UnspentKey p)

getAddressesUnspentsDB ::
       MonadIO m
    => [Address]
    -> Maybe BlockRef
    -> Maybe Limit
    -> DatabaseReader
    -> m [Unspent]
getAddressesUnspentsDB addrs start limit bdb = do
    us <- concat <$> mapM (\a -> getAddressUnspentsDB a start limit bdb) addrs
    let us' = nub $ sortBy (flip compare `on` unspentBlock) us
    return $ applyLimit limit us'

getAddressUnspentsDB ::
       MonadIO m
    => Address
    -> Maybe BlockRef
    -> Maybe Limit
    -> DatabaseReader
    -> m [Unspent]
getAddressUnspentsDB a start limit DatabaseReader { databaseReadOptions = opts
                                                  , databaseHandle = db
                                                  , databaseNetwork = net
                                                  } =
    liftIO . runResourceT . runConduit $
    x .| applyLimitC limit .| mapC (uncurry (toUnspent net)) .| sinkList
  where
    x =
        case start of
            Nothing -> matching db opts (AddrOutKeyA a)
            Just br -> matchingSkip db opts (AddrOutKeyA a) (AddrOutKeyB a br)

instance MonadIO m => StoreRead (DatabaseReaderT m) where
    getNetwork = asks databaseNetwork
    getBestBlock = ask >>= getBestDatabaseReader
    getBlocksAtHeight h = ask >>= getBlocksAtHeightDB h
    getBlock b = ask >>= getDatabaseReader b
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
    getOrphans = ask >>= getOrphansDB
    getAddressUnspents a b c = ask >>= getAddressUnspentsDB a b c
    getAddressTxs a b c = ask >>= getAddressTxsDB a b c
    getMaxGap = asks databaseMaxGap
    getInitialGap = asks databaseInitialGap
