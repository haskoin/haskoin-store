{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
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
                                               pubSubKey, txHash)
import           Haskoin.Store.Common
import           Haskoin.Store.Data
import           Haskoin.Store.Database.Types
import qualified System.Metrics               as Metrics
import           System.Metrics.Counter       (Counter)
import qualified System.Metrics.Counter       as Counter
import           UnliftIO                     (MonadIO, MonadUnliftIO, liftIO)

type DatabaseReaderT = ReaderT DatabaseReader

data DatabaseReader =
    DatabaseReader
        { databaseHandle     :: !DB
        , databaseMaxGap     :: !Word32
        , databaseInitialGap :: !Word32
        , databaseNetwork    :: !Network
        , databaseMetrics    :: !(Maybe DataMetrics)
        }

incrementCounter :: MonadIO m
                 => (DataMetrics -> Counter)
                 -> Int
                 -> ReaderT DatabaseReader m ()
incrementCounter f i =
    asks databaseMetrics >>= \case
        Just s  -> liftIO $ Counter.add (f s) (fromIntegral i)
        Nothing -> return ()

dataVersion :: Word32
dataVersion = 17

withDatabaseReader :: MonadUnliftIO m
                   => Network
                   -> Word32
                   -> Word32
                   -> FilePath
                   -> Maybe DataMetrics
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
                , databaseMetrics = stats
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
            lift (getTxData txh) >>= \case
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
            lift (getTxData txh) >>= \case
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

instance MonadIO m => StoreReadBase (DatabaseReaderT m) where
    getNetwork = asks databaseNetwork

    getTxData th = do
        db <- asks databaseHandle
        retrieveCF db (txCF db) (TxKey th) >>= \case
            Nothing -> return Nothing
            Just t  -> do
              incrementCounter dataTxCount 1
              return (Just t)

    getSpender op = do
        db <- asks databaseHandle
        retrieveCF db (spenderCF db) (SpenderKey op) >>= \case
            Nothing -> return Nothing
            Just s -> do
                incrementCounter dataSpenderCount 1
                return (Just s)

    getUnspent p = do
        db <- asks databaseHandle
        fmap (valToUnspent p) <$> retrieveCF db (unspentCF db) (UnspentKey p) >>= \case
            Nothing -> return Nothing
            Just u  -> do
                incrementCounter dataUnspentCount 1
                return (Just u)

    getBalance a = do
        db <- asks databaseHandle
        incrementCounter dataBalanceCount 1
        fmap (valToBalance a) <$> retrieveCF db (balanceCF db) (BalKey a)

    getMempool = do
        db <- asks databaseHandle
        incrementCounter dataMempoolCount 1
        fromMaybe [] <$> retrieve db MemKey

    getBestBlock = do
        incrementCounter dataBestCount 1
        asks databaseHandle >>= (`retrieve` BestKey)

    getBlocksAtHeight h = do
        db <- asks databaseHandle
        retrieveCF db (heightCF db) (HeightKey h) >>= \case
            Nothing -> return []
            Just ls -> do
              incrementCounter dataBlockCount (length ls)
              return ls

    getBlock h = do
        db <- asks databaseHandle
        retrieveCF db (blockCF db) (BlockKey h) >>= \case
            Nothing -> return Nothing
            Just b  -> do
              incrementCounter dataBlockCount 1
              return (Just b)

instance MonadUnliftIO m => StoreReadExtra (DatabaseReaderT m) where
    getAddressesTxs addrs limits = do
        txs <- applyLimits limits . sortOn Down . concat <$> mapM f addrs
        incrementCounter dataAddrTxCount (length txs)
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

    getAddressesUnspents addrs limits = do
        us <- applyLimits limits . sortOn Down . concat <$> mapM f addrs
        incrementCounter dataUnspentCount (length us)
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

    getAddressUnspents a limits = do
          db <- asks databaseHandle
          us <- withIterCF db (addrOutCF db) $ \it -> runConduit $
              x it .| applyLimitsC limits .| mapC (uncurry toUnspent) .| sinkList
          incrementCounter dataUnspentCount (length us)
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
                  lift (getTxData txh) >>= \case
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

    getAddressTxs a limits = do
        db <- asks databaseHandle
        txs <- withIterCF db (addrTxCF db) $ \it ->
            runConduit $
            addressConduit a (start limits) it .|
            applyLimitsC limits .|
            sinkList
        incrementCounter dataAddrTxCount (length txs)
        return txs

    getMaxGap = asks databaseMaxGap

    getInitialGap = asks databaseInitialGap

    getNumTxData i = do
        db <- asks databaseHandle
        let (sk, w) = decodeTxKey i
        ls <- liftIO $ matchingAsListCF db (txCF db) (TxKeyS sk)
        let f t = let bs = encode $ txHash (txData t)
                      b = BS.head (BS.drop 6 bs)
                      w' = b .&. 0xf8
                  in w == w'
            txs = filter f $ map snd ls
        incrementCounter dataTxCount (length txs)
        return txs

    getBalances as = do
        zipWith f as <$> mapM getBalance as
      where
        f a Nothing  = zeroBalance a
        f _ (Just b) = b

    xPubBals xpub = do
        igap <- getInitialGap
        gap <- getMaxGap
        ext1 <- derive_until_gap gap 0 (take (fromIntegral igap) (aderiv 0 0))
        if all (nullBalance . xPubBal) ext1
            then do
                incrementCounter dataXPubBals (length ext1)
                return ext1
            else do
                ext2 <- derive_until_gap gap 0 (aderiv 0 igap)
                chg <- derive_until_gap gap 1 (aderiv 1 0)
                let bals = ext1 <> ext2 <> chg
                incrementCounter dataXPubBals (length bals)
                return bals
      where
        aderiv m =
            deriveAddresses
                (deriveFunction (xPubDeriveType xpub))
                (pubSubKey (xPubSpecKey xpub) m)
        xbalance m b n = XPubBal {xPubBalPath = [m, n], xPubBal = b}
        derive_until_gap _ _ [] = return []
        derive_until_gap gap m as = do
            let (as1, as2) = splitAt (fromIntegral gap) as
            bs <- getBalances (map snd as1)
            let xbs = zipWith (xbalance m) bs (map fst as1)
            if all nullBalance bs
                then return xbs
                else (xbs <>) <$> derive_until_gap gap m as2

    xPubUnspents _xspec xbals limits = do
        us <- concat <$> mapM h cs
        incrementCounter dataXPubUnspents (length us)
        return . applyLimits limits $ sortOn Down us
      where
        l = deOffset limits
        cs = filter ((> 0) . balanceUnspentCount . xPubBal) xbals
        i b = do
            us <- getAddressUnspents (balanceAddress (xPubBal b)) l
            return us
        f b t = XPubUnspent {xPubUnspentPath = xPubBalPath b, xPubUnspent = t}
        h b = map (f b) <$> i b

    xPubTxs _xspec xbals limits = do
        let as = map balanceAddress $
                 filter (not . nullBalance) $
                 map xPubBal xbals
        txs <- getAddressesTxs as limits
        incrementCounter dataXPubTxs (length txs)
        return txs

    xPubTxCount xspec xbals = do
        incrementCounter dataXPubTxCount 1
        fromIntegral . length <$> xPubTxs xspec xbals def
