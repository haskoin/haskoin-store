{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
module Haskoin.Store.Database.Reader
    ( -- * RocksDB Database Access
      DatabaseReader (..)
    , DatabaseReaderT
    , withDatabaseReader
    , addrTxCF
    , addrOutCF
    , txCF
    , spenderCF
    , unspentCF
    , blockCF
    , heightCF
    , balanceCF
    ) where

import           Conduit                      (ConduitT, lift, mapC, runConduit,
                                               sinkList, (.|))
import           Control.Monad.Except         (runExceptT, throwError)
import           Control.Monad.Reader         (ReaderT, ask, asks, runReaderT)
import           Data.Bits                    ((.&.))
import qualified Data.ByteString              as BS
import           Data.Default                 (def)
import           Data.Function                (on)
import           Data.List                    (sortBy)
import           Data.Maybe                   (fromMaybe)
import           Data.Serialize               (encode)
import           Data.Word                    (Word32, Word64)
import           Database.RocksDB             (ColumnFamily, Config (..),
                                               DB (..), Iterator, withDBCF,
                                               withIterCF)
import           Database.RocksDB.Query       (insert, matching,
                                               matchingAsListCF, matchingSkip,
                                               retrieve, retrieveCF)
import           Haskoin                      (Address, BlockHash, BlockHeight,
                                               Network, OutPoint (..), TxHash,
                                               txHash)
import           Haskoin.Store.Common
import           Haskoin.Store.Data
import           Haskoin.Store.Database.Types
import           Haskoin.Store.Logic          (joinDescStreams)
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
dataVersion = 17

withDatabaseReader :: MonadUnliftIO m
                   => Network
                   -> Word32
                   -> Word32
                   -> FilePath
                   -> DatabaseReaderT m a
                   -> m a
withDatabaseReader net igap gap dir f =
    withDBCF dir cfg columnFamilyConfig $ \db -> do
    let bdb =
            DatabaseReader
                { databaseHandle = db
                , databaseMaxGap = gap
                , databaseNetwork = net
                , databaseInitialGap = igap
                }
    initRocksDB bdb
    runReaderT f bdb
  where
    cfg = def{createIfMissing = True, maxFiles = Just (-1)}

columnFamilyConfig :: [(String, Config)]
columnFamilyConfig =
          [ ("addr-tx",     def{prefixLength = Just 22, bloomFilter = True})
          , ("addr-out",    def{prefixLength = Just 22, bloomFilter = True})
          , ("tx",          def{prefixLength = Just 33, bloomFilter = True})
          , ("spender",     def{prefixLength = Just 33, bloomFilter = True})
          , ("unspent",     def{prefixLength = Just 37, bloomFilter = True})
          , ("block",       def{prefixLength = Just 33, bloomFilter = True})
          , ("height",      def{prefixLength = Nothing, bloomFilter = True})
          , ("balance",     def{prefixLength = Just 22, bloomFilter = True})
          ]

addrTxCF :: DB -> ColumnFamily
addrTxCF = head . columnFamilies

addrOutCF :: DB -> ColumnFamily
addrOutCF db = columnFamilies db !! 1

txCF :: DB -> ColumnFamily
txCF db = columnFamilies db !! 2

spenderCF :: DB -> ColumnFamily
spenderCF db = columnFamilies db !! 3

unspentCF :: DB -> ColumnFamily
unspentCF db = columnFamilies db !! 4

blockCF :: DB -> ColumnFamily
blockCF db = columnFamilies db !! 5

heightCF :: DB -> ColumnFamily
heightCF db = columnFamilies db !! 6

balanceCF :: DB -> ColumnFamily
balanceCF db = columnFamilies db !! 7

initRocksDB :: MonadIO m => DatabaseReader -> m ()
initRocksDB DatabaseReader{databaseHandle = db} = do
    e <-
        runExceptT $
        retrieve db VersionKey >>= \case
            Just v
                | v == dataVersion -> return ()
                | otherwise -> throwError "Incorrect RocksDB database version"
            Nothing -> setInitRocksDB db
    case e of
        Left s   -> error s
        Right () -> return ()

setInitRocksDB :: MonadIO m => DB -> m ()
setInitRocksDB db = insert db VersionKey dataVersion

getBestDatabaseReader :: MonadIO m => DatabaseReader -> m (Maybe BlockHash)
getBestDatabaseReader DatabaseReader{databaseHandle = db} =
    retrieve db BestKey

getBlocksAtHeightDB :: MonadIO m => BlockHeight -> DatabaseReader -> m [BlockHash]
getBlocksAtHeightDB h DatabaseReader{databaseHandle = db} =
    retrieveCF db (heightCF db) (HeightKey h) >>= \case
        Nothing -> return []
        Just ls -> return ls

getDatabaseReader :: MonadIO m => BlockHash -> DatabaseReader -> m (Maybe BlockData)
getDatabaseReader h DatabaseReader{databaseHandle = db} =
    retrieveCF db (blockCF db) (BlockKey h)

getTxDataDB :: MonadIO m => TxHash -> DatabaseReader -> m (Maybe TxData)
getTxDataDB th DatabaseReader{databaseHandle = db} =
    retrieveCF db (txCF db) (TxKey th)

getNumTxDataDB :: MonadIO m => Word64 -> DatabaseReader -> m [TxData]
getNumTxDataDB i r@DatabaseReader{databaseHandle = db} = do
    let (sk, w) = decodeTxKey i
    ls <- liftIO $ matchingAsListCF db (txCF db) (TxKeyS sk)
    let f t = let bs = encode $ txHash (txData t)
                  b = BS.head (BS.drop 6 bs)
                  w' = b .&. 0xf8
              in w == w'
    return $ filter f $ map snd ls

getSpenderDB :: MonadIO m => OutPoint -> DatabaseReader -> m (Maybe Spender)
getSpenderDB op DatabaseReader{databaseHandle = db} =
    retrieveCF db (spenderCF db) $ SpenderKey op

getBalanceDB :: MonadIO m => Address -> DatabaseReader -> m (Maybe Balance)
getBalanceDB a DatabaseReader{databaseHandle = db} =
    fmap (valToBalance a) <$> retrieveCF db (balanceCF db) (BalKey a)

getMempoolDB :: MonadIO m => DatabaseReader -> m [(UnixTime, TxHash)]
getMempoolDB DatabaseReader{databaseHandle = db} =
    fromMaybe [] <$> retrieve db MemKey

getAddressesTxsDB ::
       MonadIO m
    => [Address]
    -> Limits
    -> DatabaseReader
    -> m [TxRef]
getAddressesTxsDB addrs limits bdb@DatabaseReader{databaseHandle = db} =
    liftIO $ iters addrs [] $ \cs ->
    runConduit $
    joinDescStreams cs .| applyLimitsC limits .| sinkList
  where
    iters [] acc f = f acc
    iters (a : as) acc f =
        withIterCF db (addrTxCF db) $ \it ->
        iters as (addressConduit a bdb (start limits) it : acc) f

addressConduit :: MonadUnliftIO m
               => Address
               -> DatabaseReader
               -> Maybe Start
               -> Iterator
               -> ConduitT i TxRef m ()
addressConduit a bdb s it  =
    x .| mapC (uncurry f)
  where
    f (AddrTxKey _ t) () = t
    f _ _                = undefined
    x = case s of
        Nothing -> matching it (AddrTxKeyA a)
        Just (AtTx txh) -> lift (getTxDataDB txh bdb) >>= \case
            Just TxData {txDataBlock = b@BlockRef{}} ->
                matchingSkip it (AddrTxKeyA a) (AddrTxKeyB a b)
            _ -> matching it (AddrTxKeyA a)
        Just (AtBlock bh) ->
            matchingSkip
            it
            (AddrTxKeyA a)
            (AddrTxKeyB a (BlockRef bh maxBound))

getAddressTxsDB ::
       MonadIO m
    => Address
    -> Limits
    -> DatabaseReader
    -> m [TxRef]
getAddressTxsDB a limits bdb@DatabaseReader{databaseHandle = db} =
    liftIO . withIterCF db (addrTxCF db) $ \it ->
    runConduit $
    addressConduit a bdb (start limits) it .|
    applyLimitsC limits .|
    sinkList

getUnspentDB :: MonadIO m => OutPoint -> DatabaseReader -> m (Maybe Unspent)
getUnspentDB p DatabaseReader{databaseHandle = db} =
    fmap (valToUnspent p) <$> retrieveCF db (unspentCF db) (UnspentKey p)

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
    liftIO $ withIterCF db (addrOutCF db) $ \it -> runConduit $
    x it .| applyLimitsC limits .| mapC (uncurry toUnspent) .| sinkList
  where
    x it = case start limits of
        Nothing ->
            matching it (AddrOutKeyA a)
        Just (AtBlock h) ->
            matchingSkip
                it
                (AddrOutKeyA a)
                (AddrOutKeyB a (BlockRef h maxBound))
        Just (AtTx txh) ->
            lift (getTxDataDB txh bdb) >>= \case
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
    getNumTxData t = ask >>= getNumTxDataDB t
