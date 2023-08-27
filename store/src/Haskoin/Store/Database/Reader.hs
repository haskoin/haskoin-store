{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoFieldSelectors #-}

module Haskoin.Store.Database.Reader
  ( -- * RocksDB Database Access
    DatabaseReader (..),
    DatabaseReaderT,
    withDatabaseReader,
    addrTxCF,
    addrOutCF,
    txCF,
    unspentCF,
    blockCF,
    heightCF,
    balanceCF,
  )
where

import Conduit
  ( ConduitT,
    dropC,
    dropWhileC,
    lift,
    mapC,
    runConduit,
    sinkList,
    takeC,
    (.|),
  )
import Control.Monad.Except (runExceptT, throwError)
import Control.Monad.Reader (ReaderT, ask, asks, runReaderT)
import Control.Monad.Trans.Maybe (MaybeT (..), runMaybeT)
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.Default (def)
import Data.Function (on)
import Data.IntMap.Strict qualified as IntMap
import Data.List (sortOn)
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..))
import Data.Serialize (encode)
import Data.Word (Word32, Word64)
import Database.RocksDB
  ( ColumnFamily,
    Config (..),
    DB (..),
    Iterator,
    withDBCF,
    withIterCF,
  )
import Database.RocksDB.Query
  ( insert,
    matching,
    matchingAsListCF,
    matchingSkip,
    retrieve,
    retrieveCF,
  )
import Haskoin
  ( Address,
    BlockHash,
    BlockHeight,
    Ctx,
    Network,
    OutPoint (..),
    TxHash,
    pubSubKey,
    txHash,
  )
import Haskoin.Store.Common
import Haskoin.Store.Data
import Haskoin.Store.Database.Types
import System.Metrics qualified as Metrics
import System.Metrics.Counter (Counter)
import System.Metrics.Counter qualified as Counter
import UnliftIO (MonadIO, MonadUnliftIO, liftIO)

type DatabaseReaderT = ReaderT DatabaseReader

data DatabaseReader = DatabaseReader
  { db :: !DB,
    maxGap :: !Word32,
    initGap :: !Word32,
    net :: !Network,
    metrics :: !(Maybe DataMetrics),
    ctx :: !Ctx
  }

incrementCounter ::
  (MonadIO m) =>
  (DataMetrics -> Counter) ->
  Int ->
  ReaderT DatabaseReader m ()
incrementCounter f i =
  asks (.metrics) >>= \case
    Just s -> liftIO $ Counter.add (f s) (fromIntegral i)
    Nothing -> return ()

dataVersion :: Word32
dataVersion = 18

withDatabaseReader ::
  (MonadUnliftIO m) =>
  Network ->
  Ctx ->
  Word32 ->
  Word32 ->
  FilePath ->
  Maybe DataMetrics ->
  DatabaseReaderT m a ->
  m a
withDatabaseReader net ctx igap gap dir stats f =
  withDBCF dir cfg columnFamilyConfig $ \db -> do
    let bdb =
          DatabaseReader
            { db = db,
              maxGap = gap,
              net = net,
              initGap = igap,
              metrics = stats,
              ctx = ctx
            }
    initRocksDB bdb
    runReaderT f bdb
  where
    cfg = def {createIfMissing = True, maxFiles = Just (-1)}

columnFamilyConfig :: [(String, Config)]
columnFamilyConfig =
  [ ("addr-tx", def {prefixLength = Just 22, bloomFilter = False}),
    ("addr-out", def {prefixLength = Just 22, bloomFilter = False}),
    ("tx", def {prefixLength = Just 33, bloomFilter = False}),
    ("spender", def {prefixLength = Just 33, bloomFilter = False}), -- unused
    ("unspent", def {prefixLength = Just 37, bloomFilter = False}),
    ("block", def {prefixLength = Just 33, bloomFilter = False}),
    ("height", def {prefixLength = Nothing, bloomFilter = False}),
    ("balance", def {prefixLength = Just 22, bloomFilter = False})
  ]

addrTxCF :: DB -> ColumnFamily
addrTxCF = head . columnFamilies

addrOutCF :: DB -> ColumnFamily
addrOutCF db = columnFamilies db !! 1

txCF :: DB -> ColumnFamily
txCF db = columnFamilies db !! 2

unspentCF :: DB -> ColumnFamily
unspentCF db = columnFamilies db !! 4

blockCF :: DB -> ColumnFamily
blockCF db = columnFamilies db !! 5

heightCF :: DB -> ColumnFamily
heightCF db = columnFamilies db !! 6

balanceCF :: DB -> ColumnFamily
balanceCF db = columnFamilies db !! 7

initRocksDB :: (MonadIO m) => DatabaseReader -> m ()
initRocksDB DatabaseReader {db = db} = do
  e <-
    runExceptT $
      retrieve db VersionKey >>= \case
        Just v
          | v == dataVersion -> return ()
          | otherwise -> throwError "Incorrect RocksDB database version"
        Nothing -> setInitRocksDB db
  case e of
    Left s -> error s
    Right () -> return ()

setInitRocksDB :: (MonadIO m) => DB -> m ()
setInitRocksDB db = insert db VersionKey dataVersion

addressConduit ::
  (MonadUnliftIO m) =>
  Address ->
  Maybe Start ->
  Iterator ->
  ConduitT i TxRef (DatabaseReaderT m) ()
addressConduit a s it =
  x .| mapC (uncurry f)
  where
    f (AddrTxKey _ t) () = t
    f _ _ = undefined
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
          Just TxData {block = b@BlockRef {}} ->
            matchingSkip it (AddrTxKeyA a) (AddrTxKeyB a b)
          Just TxData {block = MemRef {}} ->
            let cond (AddrTxKey _a (TxRef MemRef {} th)) =
                  th /= txh
                cond (AddrTxKey _a (TxRef BlockRef {} _th)) =
                  False
             in matching it (AddrTxKeyA a)
                  .| (dropWhileC (cond . fst) >> mapC id)
          Nothing -> return ()

unspentConduit ::
  (MonadUnliftIO m) =>
  Ctx ->
  Address ->
  Maybe Start ->
  Iterator ->
  ConduitT i Unspent (DatabaseReaderT m) ()
unspentConduit ctx a s it =
  x .| mapC (uncurry (toUnspent ctx))
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
          Just TxData {block = b@BlockRef {}} ->
            matchingSkip it (AddrOutKeyA a) (AddrOutKeyB a b)
          Just TxData {block = MemRef {}} ->
            let cond (AddrOutKey _a MemRef {} p) =
                  p.hash /= txh
                cond (AddrOutKey _a BlockRef {} _p) =
                  False
             in matching it (AddrOutKeyA a)
                  .| (dropWhileC (cond . fst) >> mapC id)
          Nothing -> return ()

withManyIters ::
  (MonadUnliftIO m) =>
  DB ->
  ColumnFamily ->
  Int ->
  ([Iterator] -> m a) ->
  m a
withManyIters db cf i f = go [] i
  where
    go acc 0 = f acc
    go acc n = withIterCF db cf $ \it -> go (it : acc) (n - 1)

joinConduits ::
  (Monad m, Ord o) =>
  [ConduitT () o m ()] ->
  Limits ->
  m [o]
joinConduits cs l =
  runConduit $ joinDescStreams cs .| applyLimitsC l .| sinkList

instance (MonadIO m) => StoreReadBase (DatabaseReaderT m) where
  getCtx = asks (.ctx)
  getNetwork = asks (.net)

  getTxData th = do
    db <- asks (.db)
    retrieveCF db (txCF db) (TxKey th) >>= \case
      Nothing -> return Nothing
      Just t -> do
        incrementCounter (.dataTxCount) 1
        return (Just t)

  getSpender op = runMaybeT $ do
    td <- MaybeT $ getTxData op.hash
    let i = fromIntegral op.index
    MaybeT . return $ i `IntMap.lookup` td.spenders

  getUnspent p = do
    db <- asks (.db)
    ctx <- asks (.ctx)
    val <- retrieveCF db (unspentCF db) (UnspentKey p)
    case fmap (valToUnspent ctx p) val of
      Nothing -> return Nothing
      Just u -> do
        incrementCounter (.dataUnspentCount) 1
        return (Just u)

  getBalance a = do
    db <- asks (.db)
    incrementCounter (.dataBalanceCount) 1
    fmap (valToBalance a) <$> retrieveCF db (balanceCF db) (BalKey a)

  getMempool = do
    db <- asks (.db)
    incrementCounter (.dataMempoolCount) 1
    fromMaybe [] <$> retrieve db MemKey

  getBestBlock = do
    incrementCounter (.dataBestCount) 1
    asks (.db) >>= (`retrieve` BestKey)

  getBlocksAtHeight h = do
    db <- asks (.db)
    retrieveCF db (heightCF db) (HeightKey h) >>= \case
      Nothing -> return []
      Just ls -> do
        incrementCounter (.dataBlockCount) (length ls)
        return ls

  getBlock h = do
    db <- asks (.db)
    retrieveCF db (blockCF db) (BlockKey h) >>= \case
      Nothing -> return Nothing
      Just b -> do
        incrementCounter (.dataBlockCount) 1
        return (Just b)

instance (MonadUnliftIO m) => StoreReadExtra (DatabaseReaderT m) where
  getAddressesTxs addrs limits = do
    db <- asks (.db)
    withManyIters db (addrTxCF db) (length addrs) $ \its -> do
      txs <- joinConduits (cs its) limits
      incrementCounter (.dataAddrTxCount) (length txs)
      return txs
    where
      cs = zipWith c addrs
      c a = addressConduit a limits.start

  getAddressesUnspents addrs limits = do
    db <- asks (.db)
    ctx <- asks (.ctx)
    withManyIters db (addrOutCF db) (length addrs) $ \its -> do
      uns <- joinConduits (cs ctx its) limits
      incrementCounter (.dataUnspentCount) (length uns)
      return uns
    where
      cs ctx = zipWith (c ctx) addrs
      c ctx a = unspentConduit ctx a limits.start

  getAddressUnspents a limits = do
    db <- asks (.db)
    ctx <- asks (.ctx)
    us <- withIterCF db (addrOutCF db) $ \it ->
      runConduit $
        unspentConduit ctx a limits.start it
          .| applyLimitsC limits
          .| sinkList
    incrementCounter (.dataUnspentCount) (length us)
    return us

  getAddressTxs a limits = do
    db <- asks (.db)
    txs <- withIterCF db (addrTxCF db) $ \it ->
      runConduit $
        addressConduit a limits.start it
          .| applyLimitsC limits
          .| sinkList
    incrementCounter (.dataAddrTxCount) (length txs)
    return txs

  getMaxGap = asks (.maxGap)

  getInitialGap = asks (.initGap)

  getNumTxData i = do
    db <- asks (.db)
    let (sk, w) = decodeTxKey i
    ls <- liftIO $ matchingAsListCF db (txCF db) (TxKeyS sk)
    let f t =
          let bs = encode $ txHash t.tx
              b = BS.head (BS.drop 6 bs)
              w' = b .&. 0xf8
           in w == w'
        txs = filter f $ map snd ls
    incrementCounter (.dataTxCount) (length txs)
    return txs

  getBalances as = do
    zipWith f as <$> mapM getBalance as
    where
      f a Nothing = zeroBalance a
      f _ (Just b) = b

  xPubBals xpub = do
    ctx <- asks (.ctx)
    igap <- getInitialGap
    gap <- getMaxGap
    ext1 <- derive_until_gap gap 0 (take (fromIntegral igap) (aderiv ctx 0 0))
    if all (nullBalance . (.balance)) ext1
      then do
        incrementCounter (.dataXPubBals) (length ext1)
        return ext1
      else do
        ext2 <- derive_until_gap gap 0 (aderiv ctx 0 igap)
        chg <- derive_until_gap gap 1 (aderiv ctx 1 0)
        let bals = ext1 <> ext2 <> chg
        incrementCounter (.dataXPubBals) (length bals)
        return bals
    where
      aderiv ctx m =
        deriveAddresses
          (deriveFunction ctx xpub.deriv)
          (pubSubKey ctx xpub.key m)
      xbalance m b n = XPubBal {path = [m, n], balance = b}
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
    incrementCounter (.dataXPubUnspents) (length us)
    return . applyLimits limits $ sortOn Down us
    where
      l = deOffset limits
      cs = filter ((> 0) . (.balance.utxo)) xbals
      i b = getAddressUnspents b.balance.address l
      f b t = XPubUnspent {path = b.path, unspent = t}
      h b = map (f b) <$> i b

  xPubTxs _xspec xbals limits = do
    let as =
          map (.address) $
            filter (not . nullBalance) $
              map (.balance) xbals
    txs <- getAddressesTxs as limits
    incrementCounter (.dataXPubTxs) (length txs)
    return txs

  xPubTxCount xspec xbals = do
    incrementCounter (.dataXPubTxCount) 1
    fromIntegral . length <$> xPubTxs xspec xbals def
