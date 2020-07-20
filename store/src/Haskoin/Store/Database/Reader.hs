{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
module Haskoin.Store.Database.Reader
    ( -- * RocksDB Database Access
      DatabaseReader (..)
    , DatabaseReaderT
    , withDatabaseReader
    ) where

import           Conduit                      (mapC, runConduit, sinkList, (.|))
import           Control.Monad.Except         (runExceptT, throwError)
import           Control.Monad.Reader         (ReaderT, ask, asks, runReaderT)
import           Data.Default                 (def)
import           Data.Function                (on)
import           Data.List                    (sortBy)
import           Data.Maybe                   (fromMaybe)
import           Data.Word                    (Word32)
import           Database.RocksDB             (Config (..), DB, withDB,
                                               withIter)
import           Database.RocksDB.Query       (insert, matching, matchingAsList,
                                               matchingSkip, retrieve)
import           Haskoin                      (Address, BlockHash, BlockHeight,
                                               Network, OutPoint (..), TxHash)
import           Haskoin.Store.Common
import           Haskoin.Store.Data           (Balance, BlockData,
                                               BlockRef (..), Spender,
                                               TxData (..), TxRef (..),
                                               Unspent (..))
import           Haskoin.Store.Database.Types (AddrOutKey (..), AddrTxKey (..),
                                               BalKey (..), BestKey (..),
                                               BlockKey (..), HeightKey (..),
                                               MemKey (..), OldMemKey (..),
                                               SpenderKey (..), TxKey (..),
                                               UnspentKey (..), VersionKey (..),
                                               toUnspent, valToBalance,
                                               valToUnspent)
import           UnliftIO                     (MonadIO, MonadUnliftIO, liftIO)

type DatabaseReaderT = ReaderT DatabaseReader

data DatabaseReader =
    DatabaseReader
        { databaseHandle     :: !DB
        , databaseMaxGap     :: !Word32
        , databaseInitialGap :: !Word32
        , databaseNetwork    :: !Network
        }

dataVersion :: Word32
dataVersion = 16

withDatabaseReader :: MonadUnliftIO m
                   => Network
                   -> Word32
                   -> Word32
                   -> FilePath
                   -> DatabaseReaderT m a
                   -> m a
withDatabaseReader net igap gap dir f =
    withDB dir def{createIfMissing = True, maxFiles = Just (-1)} $ \db -> do
    let bdb =
            DatabaseReader
                { databaseHandle = db
                , databaseMaxGap = gap
                , databaseNetwork = net
                , databaseInitialGap = igap
                }
    initRocksDB bdb
    runReaderT f bdb

initRocksDB :: MonadIO m => DatabaseReader -> m ()
initRocksDB bdb@DatabaseReader{databaseHandle = db} = do
    e <-
        runExceptT $
        retrieve db VersionKey >>= \case
            Just v
                | v == dataVersion -> return ()
                | v == 15 -> migrate15to16 bdb >> initRocksDB bdb
                | otherwise -> throwError "Incorrect RocksDB database version"
            Nothing -> setInitRocksDB db
    case e of
        Left s   -> error s
        Right () -> return ()

migrate15to16 :: MonadIO m => DatabaseReader -> m ()
migrate15to16 DatabaseReader{databaseHandle = db} = do
    xs <- liftIO $ matchingAsList db OldMemKeyS
    let ys = map (\(OldMemKey t h, ()) -> (t, h)) xs
    insert db MemKey ys
    insert db VersionKey (16 :: Word32)

setInitRocksDB :: MonadIO m => DB -> m ()
setInitRocksDB db = insert db VersionKey dataVersion

getBestDatabaseReader :: MonadIO m => DatabaseReader -> m (Maybe BlockHash)
getBestDatabaseReader DatabaseReader{databaseHandle = db} =
    retrieve db BestKey

getBlocksAtHeightDB :: MonadIO m => BlockHeight -> DatabaseReader -> m [BlockHash]
getBlocksAtHeightDB h DatabaseReader{databaseHandle = db} =
    retrieve db (HeightKey h) >>= \case
        Nothing -> return []
        Just ls -> return ls

getDatabaseReader :: MonadIO m => BlockHash -> DatabaseReader -> m (Maybe BlockData)
getDatabaseReader h DatabaseReader{databaseHandle = db} =
    retrieve db (BlockKey h)

getTxDataDB ::
       MonadIO m => TxHash -> DatabaseReader -> m (Maybe TxData)
getTxDataDB th DatabaseReader{databaseHandle = db} =
    retrieve db (TxKey th)

getSpenderDB :: MonadIO m => OutPoint -> DatabaseReader -> m (Maybe Spender)
getSpenderDB op DatabaseReader{databaseHandle = db} =
    retrieve db $ SpenderKey op

getBalanceDB :: MonadIO m => Address -> DatabaseReader -> m (Maybe Balance)
getBalanceDB a DatabaseReader{databaseHandle = db} =
    fmap (valToBalance a) <$> retrieve db (BalKey a)

getMempoolDB :: MonadIO m => DatabaseReader -> m [TxRef]
getMempoolDB DatabaseReader{databaseHandle = db} =
    fmap f . fromMaybe [] <$> retrieve db MemKey
  where
    f (t, h) = TxRef {txRefBlock = MemRef t, txRefHash = h}

getAddressesTxsDB ::
       MonadIO m
    => [Address]
    -> Limits
    -> DatabaseReader
    -> m [TxRef]
getAddressesTxsDB addrs limits db = do
    ts <- concat <$> mapM (\a -> getAddressTxsDB a (deOffset limits) db) addrs
    let ts' = sortBy (flip compare `on` txRefBlock) (nub' ts)
    return $ applyLimits limits ts'

getAddressTxsDB ::
       MonadIO m
    => Address
    -> Limits
    -> DatabaseReader
    -> m [TxRef]
getAddressTxsDB a limits bdb@DatabaseReader{databaseHandle = db} =
    liftIO $ withIter db $ \it -> runConduit $
    x it .| applyLimitsC limits .| mapC (uncurry f) .| sinkList
  where
    x it =
        case start limits of
            Nothing -> matching it (AddrTxKeyA a)
            Just (AtTx txh) ->
                getTxDataDB txh bdb >>= \case
                    Just TxData {txDataBlock = b@BlockRef {}} ->
                        matchingSkip it (AddrTxKeyA a) (AddrTxKeyB a b)
                    _ -> matching it (AddrTxKeyA a)
            Just (AtBlock bh) ->
                matchingSkip
                    it
                    (AddrTxKeyA a)
                    (AddrTxKeyB a (BlockRef bh maxBound))
    f AddrTxKey {addrTxKeyT = t} () = t
    f _ _                           = undefined

getUnspentDB :: MonadIO m => OutPoint -> DatabaseReader -> m (Maybe Unspent)
getUnspentDB p DatabaseReader{databaseHandle = db} =
    fmap (valToUnspent p) <$> retrieve db (UnspentKey p)

getAddressesUnspentsDB ::
       MonadIO m
    => [Address]
    -> Limits
    -> DatabaseReader
    -> m [Unspent]
getAddressesUnspentsDB addrs limits bdb = do
    us <-
        concat <$>
        mapM (\a -> getAddressUnspentsDB a (deOffset limits) bdb) addrs
    let us' = sortBy (flip compare `on` unspentBlock) (nub' us)
    return $ applyLimits limits us'

getAddressUnspentsDB ::
       MonadIO m
    => Address
    -> Limits
    -> DatabaseReader
    -> m [Unspent]
getAddressUnspentsDB a limits bdb@DatabaseReader{databaseHandle = db} =
    liftIO $ withIter db $ \it -> runConduit $
    x it .| applyLimitsC limits .| mapC (uncurry toUnspent) .| sinkList
  where
    x it = case start limits of
        Nothing -> matching it (AddrOutKeyA a)
        Just (AtBlock h) ->
            matchingSkip
                it
                (AddrOutKeyA a)
                (AddrOutKeyB a (BlockRef h maxBound))
        Just (AtTx txh) ->
            getTxDataDB txh bdb >>= \case
                Just TxData {txDataBlock = b@BlockRef {}} ->
                    matchingSkip it (AddrOutKeyA a) (AddrOutKeyB a b)
                _ -> matching it (AddrOutKeyA a)

instance MonadIO m => StoreReadBase (DatabaseReaderT m) where
    getNetwork = asks databaseNetwork
    getTxData t = ask >>= getTxDataDB t
    getSpender p = ask >>= getSpenderDB p
    getUnspent a = ask >>= getUnspentDB a
    getBalance a = ask >>= getBalanceDB a
    getMempool = ask >>= getMempoolDB
    getBestBlock = ask >>= getBestDatabaseReader
    getBlocksAtHeight h = ask >>= getBlocksAtHeightDB h
    getBlock b = ask >>= getDatabaseReader b

instance MonadIO m => StoreReadExtra (DatabaseReaderT m) where
    getAddressesTxs as limits = ask >>= getAddressesTxsDB as limits
    getAddressesUnspents as limits = ask >>= getAddressesUnspentsDB as limits
    getAddressUnspents a limits = ask >>= getAddressUnspentsDB a limits
    getAddressTxs a limits = ask >>= getAddressTxsDB a limits
    getMaxGap = asks databaseMaxGap
    getInitialGap = asks databaseInitialGap
