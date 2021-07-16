{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
module Haskoin.Store.Database.Reader
    ( -- * RocksDB Database Access
      DatabaseReader (..)
    , DatabaseReaderT
    , DatabaseStats(..)
    , createDatabaseStats
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

import           Conduit                      (ConduitT, dropWhileC, lift, mapC,
                                               runConduit, sinkList, (.|))
import           Control.Monad.Except         (runExceptT, throwError)
import           Control.Monad.Reader         (ReaderT, ask, asks, runReaderT)
import           Data.Bits                    ((.&.))
import qualified Data.ByteString              as BS
import           Data.Default                 (def)
import           Data.Function                (on)
import           Data.List                    (sortOn)
import           Data.Maybe                   (fromMaybe)
import           Data.Ord                     (Down (..))
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
import qualified System.Metrics               as Metrics
import           System.Metrics.Counter       (Counter)
import qualified System.Metrics.Counter       as Counter
import           UnliftIO                     (MonadIO, MonadUnliftIO, liftIO)

type DatabaseReaderT = ReaderT DatabaseReader

data DatabaseStats =
    DatabaseStats
        { databaseBlockCount   :: !Counter
        , databaseTxCount      :: !Counter
        , databaseBalanceCount :: !Counter
        , databaseUnspentCount :: !Counter
        , databaseTxRefCount   :: !Counter
        , databaseDerivations  :: !Counter
        }

data DatabaseReader =
    DatabaseReader
        { databaseHandle     :: !DB
        , databaseMaxGap     :: !Word32
        , databaseInitialGap :: !Word32
        , databaseNetwork    :: !Network
        , databaseStats      :: !(Maybe DatabaseStats)
        }

createDatabaseStats :: MonadIO m => Metrics.Store -> m DatabaseStats
createDatabaseStats s = liftIO $ do
    databaseBlockCount          <- Metrics.createCounter "database.blocks"    s
    databaseTxCount             <- Metrics.createCounter "database.txs"       s
    databaseBalanceCount        <- Metrics.createCounter "database.balances"  s
    databaseUnspentCount        <- Metrics.createCounter "database.unspents"  s
    databaseTxRefCount          <- Metrics.createCounter "database.txrefs"    s
    databaseDerivations         <- Metrics.createCounter "xpub_derivations"   s
    return DatabaseStats{..}

incrementCounter :: MonadIO m
                 => (DatabaseStats -> Counter)
                 -> Int
                 -> ReaderT DatabaseReader m ()
incrementCounter f i = do
    stats <- asks databaseStats
    case stats of
        Just s  -> liftIO $ Counter.add (f s) (fromIntegral i)
        Nothing -> return ()

dataVersion :: Word32
dataVersion = 17

withDatabaseReader :: MonadUnliftIO m
                   => Network
                   -> Word32
                   -> Word32
                   -> FilePath
                   -> Maybe DatabaseStats
                   -> DatabaseReaderT m a
                   -> m a
withDatabaseReader net igap gap dir stats f =
    withDBCF dir cfg columnFamilyConfig $ \db -> do
    let bdb =
            DatabaseReader
                { databaseHandle = db
                , databaseMaxGap = gap
                , databaseNetwork = net
                , databaseInitialGap = igap
                , databaseStats = stats
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

getBestDB :: MonadIO m
          => DatabaseReaderT m (Maybe BlockHash)
getBestDB =
    asks databaseHandle >>= (`retrieve` BestKey)

getBlocksAtHeightDB :: MonadIO m
                    => BlockHeight
                    -> DatabaseReaderT m [BlockHash]
getBlocksAtHeightDB h = do
    db <- asks databaseHandle
    retrieveCF db (heightCF db) (HeightKey h) >>= \case
        Nothing -> return []
        Just ls -> countBlocks (length ls) >> return ls

getDatabaseReader :: MonadIO m
                  => BlockHash
                  -> DatabaseReaderT m (Maybe BlockData)
getDatabaseReader h = do
    db <- asks databaseHandle
    retrieveCF db (blockCF db) (BlockKey h) >>= \case
        Nothing -> return Nothing
        Just b  -> countBlocks 1 >> return (Just b)

getTxDataDB :: MonadIO m
            => TxHash -> DatabaseReaderT m (Maybe TxData)
getTxDataDB th = do
    db <- asks databaseHandle
    retrieveCF db (txCF db) (TxKey th) >>= \case
        Nothing -> return Nothing
        Just t  -> countTxs 1 >> return (Just t)

getNumTxDataDB :: MonadIO m
               => Word64
               -> DatabaseReaderT m [TxData]
getNumTxDataDB i = do
    db <- asks databaseHandle
    let (sk, w) = decodeTxKey i
    ls <- liftIO $ matchingAsListCF db (txCF db) (TxKeyS sk)
    let f t = let bs = encode $ txHash (txData t)
                  b = BS.head (BS.drop 6 bs)
                  w' = b .&. 0xf8
              in w == w'
        txs = filter f $ map snd ls
    countTxs (length txs)
    return txs

getSpenderDB :: MonadIO m
             => OutPoint
             -> DatabaseReaderT m (Maybe Spender)
getSpenderDB op = do
    db <- asks databaseHandle
    retrieveCF db (spenderCF db) $ SpenderKey op

getBalanceDB :: MonadIO m
             => Address
             -> DatabaseReaderT m (Maybe Balance)
getBalanceDB a = do
    db <- asks databaseHandle
    fmap (valToBalance a) <$> retrieveCF db (balanceCF db) (BalKey a) >>= \case
        Nothing -> return Nothing
        Just b  -> countBalances 1 >> return (Just b)

getMempoolDB :: MonadIO m
             => DatabaseReaderT m [(UnixTime, TxHash)]
getMempoolDB = do
    db <- asks databaseHandle
    fromMaybe [] <$> retrieve db MemKey

getAddressesTxsDB :: MonadUnliftIO m
                  => [Address]
                  -> Limits
                  -> DatabaseReaderT m [TxRef]
getAddressesTxsDB addrs limits = do
    txs <- applyLimits limits . sortOn Down . concat <$> mapM f addrs
    countTxRefs (length txs)
    return txs
  where
    l = deOffset limits
    f a = do
        db <- asks databaseHandle
        withIterCF db (addrTxCF db) $ \it ->
            runConduit $
            addressConduit a (start l) it .|
            applyLimitC (limit l) .|
            sinkList

addressConduit :: MonadUnliftIO m
               => Address
               -> Maybe Start
               -> Iterator
               -> ConduitT i TxRef (DatabaseReaderT m) ()
addressConduit a s it  =
    x .| mapC (uncurry f)
  where
    f (AddrTxKey _ t) () = t
    f _ _                = undefined
    x = case s of
        Nothing ->
            matching it (AddrTxKeyA a)
        Just (AtBlock bh) ->
            matchingSkip
                it
                (AddrTxKeyA a)
                (AddrTxKeyB a (BlockRef bh maxBound))
        Just (AtTx txh) ->
            lift (getTxDataDB txh) >>= \case
                Just TxData {txDataBlock = b@BlockRef{}} ->
                    matchingSkip it (AddrTxKeyA a) (AddrTxKeyB a b)
                Just TxData {txDataBlock = MemRef{}} ->
                    let cond (AddrTxKey _a (TxRef MemRef{} th)) =
                            th /= txh
                        cond (AddrTxKey _a (TxRef BlockRef{} _th)) =
                            False
                    in matching it (AddrTxKeyA a) .|
                       (dropWhileC (cond . fst) >> mapC id)
                Nothing -> return ()

getAddressTxsDB :: MonadUnliftIO m
                => Address
                -> Limits
                -> DatabaseReaderT m [TxRef]
getAddressTxsDB a limits = do
    db <- asks databaseHandle
    txs <- withIterCF db (addrTxCF db) $ \it ->
        runConduit $
        addressConduit a (start limits) it .|
        applyLimitsC limits .|
        sinkList
    countTxRefs (length txs)
    return txs

getUnspentDB :: MonadIO m
             => OutPoint
             -> DatabaseReaderT m (Maybe Unspent)
getUnspentDB p = do
    db <- asks databaseHandle
    fmap (valToUnspent p) <$> retrieveCF db (unspentCF db) (UnspentKey p) >>= \case
        Nothing -> return Nothing
        Just u  -> countUnspents 1 >> return (Just u)

getAddressesUnspentsDB :: MonadUnliftIO m
                       => [Address]
                       -> Limits
                       -> DatabaseReaderT m [Unspent]
getAddressesUnspentsDB addrs limits = do
    us <- applyLimits limits . sortOn Down . concat <$> mapM f addrs
    countUnspents (length us)
    return us
  where
    l = deOffset limits
    f a = do
        db <- asks databaseHandle
        withIterCF db (addrOutCF db) $ \it ->
            runConduit $
            unspentConduit a (start l) it .|
            applyLimitC (limit l) .|
            sinkList

unspentConduit :: MonadUnliftIO m
               => Address
               -> Maybe Start
               -> Iterator
               -> ConduitT i Unspent (DatabaseReaderT m) ()
unspentConduit a s it =
    x .| mapC (uncurry toUnspent)
  where
    x = case s of
        Nothing ->
            matching it (AddrOutKeyA a)
        Just (AtBlock h) ->
            matchingSkip
                it
                (AddrOutKeyA a)
                (AddrOutKeyB a (BlockRef h maxBound))
        Just (AtTx txh) ->
            lift (getTxDataDB txh) >>= \case
                Just TxData {txDataBlock = b@BlockRef{}} ->
                    matchingSkip it (AddrOutKeyA a) (AddrOutKeyB a b)
                Just TxData {txDataBlock = MemRef{}} ->
                    let cond (AddrOutKey _a MemRef{} p) =
                            outPointHash p /= txh
                        cond (AddrOutKey _a BlockRef{} _p) =
                            False
                    in matching it (AddrOutKeyA a) .|
                       (dropWhileC (cond . fst) >> mapC id)
                Nothing -> return ()

getAddressUnspentsDB :: MonadUnliftIO m
                     => Address
                     -> Limits
                     -> DatabaseReaderT m [Unspent]
getAddressUnspentsDB a limits = do
    db <- asks databaseHandle
    us <- withIterCF db (addrOutCF db) $ \it -> runConduit $
        x it .| applyLimitsC limits .| mapC (uncurry toUnspent) .| sinkList
    countUnspents (length us)
    return us
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
            lift (getTxDataDB txh) >>= \case
                Just TxData {txDataBlock = b@BlockRef{}} ->
                    matchingSkip it (AddrOutKeyA a) (AddrOutKeyB a b)
                Just TxData {txDataBlock = MemRef{}} ->
                    let cond (AddrOutKey _a MemRef{} p) =
                            outPointHash p /= txh
                        cond (AddrOutKey _a BlockRef{} _p) =
                            False
                    in matching it (AddrOutKeyA a) .|
                       (dropWhileC (cond . fst) >> mapC id)
                _ -> matching it (AddrOutKeyA a)

instance MonadIO m => StoreReadBase (DatabaseReaderT m) where
    getNetwork = asks databaseNetwork
    getTxData t = getTxDataDB t
    getSpender p = getSpenderDB p
    getUnspent a = getUnspentDB a
    getBalance a = getBalanceDB a
    getMempool = getMempoolDB
    getBestBlock = getBestDB
    getBlocksAtHeight h = getBlocksAtHeightDB h
    getBlock b = getDatabaseReader b
    countBlocks = incrementCounter databaseBlockCount
    countTxs = incrementCounter databaseTxCount
    countBalances = incrementCounter databaseBalanceCount
    countUnspents = incrementCounter databaseUnspentCount

instance MonadUnliftIO m => StoreReadExtra (DatabaseReaderT m) where
    getAddressesTxs as limits = getAddressesTxsDB as limits
    getAddressesUnspents as limits = getAddressesUnspentsDB as limits
    getAddressUnspents a limits = getAddressUnspentsDB a limits
    getAddressTxs a limits = getAddressTxsDB a limits
    getMaxGap = asks databaseMaxGap
    getInitialGap = asks databaseInitialGap
    getNumTxData t = getNumTxDataDB t
    countTxRefs = incrementCounter databaseTxRefCount
    countXPubDerivations = incrementCounter databaseDerivations

