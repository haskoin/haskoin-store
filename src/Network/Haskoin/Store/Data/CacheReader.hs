{-# LANGUAGE DeriveAnyClass       #-}
{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE TupleSections        #-}
{-# LANGUAGE TypeSynonymInstances #-}
module Network.Haskoin.Store.Data.CacheReader where

import           Control.DeepSeq              (NFData)
import           Control.Monad.Reader         (ReaderT (..), asks)
import           Control.Monad.Trans          (lift)
import           Data.Bits                    (shift, (.&.), (.|.))
import           Data.ByteString              (ByteString)
import qualified Data.ByteString.Short        as BSS
import           Data.Either                  (rights)
import           Data.List                    (sort)
import qualified Data.Map.Strict              as Map
import           Data.Maybe                   (catMaybes, mapMaybe)
import           Data.Serialize               (Serialize, decode, encode)
import           Data.Word                    (Word32, Word64)
import           Database.Redis               (Connection, RedisCtx, Reply,
                                               hgetall, runRedis,
                                               zrangeWithscores,
                                               zrangebyscoreWithscoresLimit)
import qualified Database.Redis               as Redis
import           GHC.Generics                 (Generic)
import           Haskoin                      (Address, KeyIndex, OutPoint (..),
                                               scriptToAddressBS)
import           Network.Haskoin.Store.Common (Balance (..), BlockRef (..),
                                               BlockTx (..), CacheWriter, Limit,
                                               Offset, StoreRead (..),
                                               Unspent (..), XPubBal (..),
                                               XPubSpec (..), XPubUnspent (..),
                                               cacheXPub)
import           UnliftIO                     (Exception, MonadIO, liftIO,
                                               throwIO)

data CacheReaderConfig =
    CacheReaderConfig
        { cacheReaderConn   :: !Connection
        , cacheReaderWriter :: !CacheWriter
        , cacheReaderGap    :: !Word32
        }


data AddressXPub =
    AddressXPub
        { addressXPubSpec :: !XPubSpec
        , addressXPubPath :: ![KeyIndex]
        } deriving (Show, Eq, Generic, NFData, Serialize)

type CacheReaderT = ReaderT CacheReaderConfig

data CacheError
    = RedisError Reply
    | LogicError String
    deriving (Show, Eq, Generic, NFData, Exception)

instance (MonadIO m, StoreRead m) => StoreRead (CacheReaderT m) where
    getBestBlock = lift getBestBlock
    getBlocksAtHeight = lift . getBlocksAtHeight
    getBlock = lift . getBlock
    getTxData = lift . getTxData
    getOrphanTx = lift . getOrphanTx
    getOrphans = lift getOrphans
    getSpenders = lift . getSpenders
    getSpender = lift . getSpender
    getBalance = lift . getBalance
    getBalances = lift . getBalances
    getAddressesTxs addrs start = lift . getAddressesTxs addrs start
    getAddressTxs addr start = lift . getAddressTxs addr start
    getUnspent = lift . getUnspent
    getAddressUnspents addr start = lift . getAddressUnspents addr start
    getAddressesUnspents addrs start = lift . getAddressesUnspents addrs start
    getMempool = lift getMempool
    xPubBals = getXPubBalances
    xPubUnspents = getXPubUnspents
    xPubTxs = getXPubTxs
    getMaxGap = asks cacheReaderGap

withCacheReader :: StoreRead m => CacheReaderConfig -> CacheReaderT m a -> m a
withCacheReader s f = runReaderT f s

-- Ordered set of balances for an extended public key
balancesPfx :: ByteString
balancesPfx = "b"

-- Ordered set of transactions for an extended public key
txSetPfx :: ByteString
txSetPfx = "t"

-- Ordered set of unspent outputs for an extended pulic key
utxoPfx :: ByteString
utxoPfx = "u"

-- Extended public key info for an address
addrPfx :: ByteString
addrPfx = "a"

getXPubTxs ::
       (MonadIO m, StoreRead m)
    => XPubSpec
    -> Maybe BlockRef
    -> Offset
    -> Maybe Limit
    -> CacheReaderT m [BlockTx]
getXPubTxs xpub start offset limit = do
    cacheGetXPubTxs xpub start offset limit >>= \case
        [] -> do
            cache <- asks cacheReaderWriter
            cacheXPub cache xpub
            lift (xPubTxs xpub start offset limit)
        txs -> return txs

getXPubUnspents ::
       (MonadIO m, StoreRead m)
    => XPubSpec
    -> Maybe BlockRef
    -> Offset
    -> Maybe Limit
    -> CacheReaderT m [XPubUnspent]
getXPubUnspents xpub start offset limit =
    getXPubBalances xpub >>= \case
        [] -> do
            cache <- asks cacheReaderWriter
            cacheXPub cache xpub
            lift (xPubUnspents xpub start offset limit)
        bals -> do
            ops <- map snd <$> cacheGetXPubUnspents xpub start offset limit
            uns <- catMaybes <$> mapM getUnspent ops
            let addrmap =
                    Map.fromList $
                    map (\b -> (balanceAddress (xPubBal b), xPubBalPath b)) bals
                addrutxo =
                    mapMaybe
                        (\u ->
                             either
                                 (const Nothing)
                                 (\a -> Just (a, u))
                                 (scriptToAddressBS
                                      (BSS.fromShort (unspentScript u))))
                        uns
                xpubutxo =
                    mapMaybe
                        (\(a, u) ->
                             (\p -> XPubUnspent p u) <$> Map.lookup a addrmap)
                        addrutxo
            return xpubutxo

getXPubBalances ::
       (MonadIO m, StoreRead m)
    => XPubSpec
    -> CacheReaderT m [XPubBal]
getXPubBalances xpub = do
    cacheGetXPubBalances xpub >>= \case
        [] -> do
            cache <- asks cacheReaderWriter
            cacheXPub cache xpub
            lift (xPubBals xpub)
        bals -> return bals

cacheGetXPubBalances :: MonadIO m => XPubSpec -> CacheReaderT m [XPubBal]
cacheGetXPubBalances xpub = do
    conn <- asks cacheReaderConn
    liftIO (runRedis conn (redisGetXPubBalances xpub)) >>= \case
        Left e -> throwIO (RedisError e)
        Right bals -> return bals

cacheGetXPubTxs ::
       MonadIO m
    => XPubSpec
    -> Maybe BlockRef
    -> Offset
    -> Maybe Limit
    -> CacheReaderT m [BlockTx]
cacheGetXPubTxs xpub start offset limit = do
    conn <- asks cacheReaderConn
    liftIO (runRedis conn (redisGetXPubTxs xpub start offset limit)) >>= \case
        Left e -> throwIO (RedisError e)
        Right bts -> return bts

cacheGetXPubUnspents ::
       MonadIO m
    => XPubSpec
    -> Maybe BlockRef
    -> Offset
    -> Maybe Limit
    -> CacheReaderT m [(BlockRef, OutPoint)]
cacheGetXPubUnspents xpub start offset limit = do
    conn <- asks cacheReaderConn
    liftIO (runRedis conn (redisGetXPubUnspents xpub start offset limit)) >>= \case
        Left e -> throwIO (RedisError e)
        Right ops -> return ops

redisGetAddrInfo :: (Monad f, RedisCtx m f) => Address -> m (f (Maybe AddressXPub))
redisGetAddrInfo a = do
    f <- Redis.get (addrPfx <> encode a)
    return $ do
        m <- f
        case m of
            Nothing -> return Nothing
            Just x -> case decode x of
                Left e  -> error e
                Right i -> return (Just i)

redisGetXPubBalances :: (Monad f, RedisCtx m f) => XPubSpec -> m (f [XPubBal])
redisGetXPubBalances xpub = do
    fxs <- getAllFromMap (balancesPfx <> encode xpub)
    return $ do
        xs <- fxs
        return (sort $ map (uncurry f) xs)
  where
    f p b = XPubBal {xPubBalPath = p, xPubBal = b}

redisGetXPubTxs ::
       (Monad f, RedisCtx m f)
    => XPubSpec
    -> Maybe BlockRef
    -> Offset
    -> Maybe Limit
    -> m (f [BlockTx])
redisGetXPubTxs xpub start offset limit = do
    xs <-
        getFromSortedSet
            (txSetPfx <> encode xpub)
            (blockRefScore <$> start)
            (fromIntegral offset)
            (fromIntegral <$> limit)
    return $ do
        xs' <- xs
        return (map (uncurry f) xs')
  where
    f t s = BlockTx {blockTxHash = t, blockTxBlock = scoreBlockRef s}

redisGetXPubUnspents ::
       (Monad f, RedisCtx m f)
    => XPubSpec
    -> Maybe BlockRef
    -> Offset
    -> Maybe Limit
    -> m (f [(BlockRef, OutPoint)])
redisGetXPubUnspents xpub start offset limit = do
    xs <-
        getFromSortedSet
            (utxoPfx <> encode xpub)
            (blockRefScore <$> start)
            (fromIntegral offset)
            (fromIntegral <$> limit)
    return $ do
        xs' <- xs
        return (map (uncurry f) xs')
  where
    f o s = (scoreBlockRef s, o)

blockRefScore :: BlockRef -> Double
blockRefScore BlockRef {blockRefHeight = h, blockRefPos = p} =
    fromIntegral (0x001fffffffffffff - (h' .|. p'))
  where
    h' = (fromIntegral h .&. 0x07ffffff) `shift` 26 :: Word64
    p' = (fromIntegral p .&. 0x03ffffff) :: Word64
blockRefScore MemRef {memRefTime = t} = 0 - t'
  where
    t' = fromIntegral (t .&. 0x001fffffffffffff)

scoreBlockRef :: Double -> BlockRef
scoreBlockRef s
    | s < 0 = MemRef {memRefTime = n}
    | otherwise = BlockRef {blockRefHeight = h, blockRefPos = p}
  where
    n = truncate (abs s) :: Word64
    m = 0x001fffffffffffff - n
    h = fromIntegral (m `shift` (-26))
    p = fromIntegral (m .&. 0x03ffffff)

getFromSortedSet ::
       (Monad f, RedisCtx m f, Serialize a)
    => ByteString
    -> Maybe Double
    -> Integer
    -> Maybe Integer
    -> m (f [(a, Double)])
getFromSortedSet key Nothing offset Nothing = do
    xs <- zrangeWithscores key offset (-1)
    return $ do
        ys <- map (\(x, s) -> (, s) <$> decode x) <$> xs
        return (rights ys)
getFromSortedSet key Nothing offset (Just count) = do
    xs <- zrangeWithscores key offset (offset + count - 1)
    return $ do
        ys <- map (\(x, s) -> (, s) <$> decode x) <$> xs
        return (rights ys)
getFromSortedSet key (Just score) offset Nothing = do
    xs <-
        zrangebyscoreWithscoresLimit
            key
            score
            (2 ^ (53 :: Integer) - 1)
            offset
            (-1)
    return $ do
        ys <- map (\(x, s) -> (, s) <$> decode x) <$> xs
        return (rights ys)
getFromSortedSet key (Just score) offset (Just count) = do
    xs <-
        zrangebyscoreWithscoresLimit
            key
            score
            (2 ^ (53 :: Integer) - 1)
            offset
            count
    return $ do
        ys <- map (\(x, s) -> (, s) <$> decode x) <$> xs
        return (rights ys)

getAllFromMap ::
       (Monad f, RedisCtx m f, Serialize k, Serialize v)
    => ByteString
    -> m (f [(k, v)])
getAllFromMap n = do
    fxs <- hgetall n
    return $ do
        xs <- fxs
        return
            [ (k, v)
            | (k', v') <- xs
            , let Right k = decode k'
            , let Right v = decode v'
            ]
