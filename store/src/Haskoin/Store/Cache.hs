{-# LANGUAGE ApplicativeDo        #-}
{-# LANGUAGE DeriveAnyClass       #-}
{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE TupleSections        #-}
{-# LANGUAGE TypeSynonymInstances #-}
module Haskoin.Store.Cache
    ( CacheConfig(..)
    , CacheT
    , CacheError(..)
    , withCache
    , connectRedis
    , blockRefScore
    , scoreBlockRef
    , CacheWriter
    , CacheWriterInbox
    , cacheNewBlock
    , cacheNewTx
    , cacheWriter
    , isXPubCached
    , delXPubKeys
    ) where

import           Control.DeepSeq           (NFData)
import           Control.Monad             (forM, forM_, forever, unless, void)
import           Control.Monad.Logger      (MonadLoggerIO, logDebugS, logErrorS,
                                            logInfoS, logWarnS)
import           Control.Monad.Reader      (ReaderT (..), asks)
import           Control.Monad.Trans       (lift)
import           Control.Monad.Trans.Maybe (MaybeT (..), runMaybeT)
import           Data.Bits                 (shift, (.&.), (.|.))
import           Data.ByteString           (ByteString)
import qualified Data.ByteString.Short     as BSS
import           Data.Either               (lefts, rights)
import           Data.HashMap.Strict       (HashMap)
import qualified Data.HashMap.Strict       as HashMap
import qualified Data.HashSet              as HashSet
import qualified Data.IntMap.Strict        as I
import           Data.List                 (sort)
import qualified Data.Map.Strict           as Map
import           Data.Maybe                (catMaybes, mapMaybe)
import           Data.Serialize            (decode, encode)
import           Data.Serialize            (Serialize)
import           Data.String.Conversions   (cs)
import           Data.Text                 (Text)
import           Data.Time.Clock.System    (getSystemTime, systemSeconds)
import           Data.Word                 (Word32, Word64)
import           Database.Redis            (Connection, Redis, RedisCtx, Reply,
                                            checkedConnect, defaultConnectInfo,
                                            hgetall, parseConnectInfo, zadd,
                                            zrangeWithscores,
                                            zrangebyscoreWithscoresLimit, zrem)
import qualified Database.Redis            as Redis
import           GHC.Generics              (Generic)
import           Haskoin                   (Address, BlockHash,
                                            BlockHeader (..), BlockNode (..),
                                            DerivPathI (..), KeyIndex,
                                            OutPoint (..), Tx (..), TxHash,
                                            TxIn (..), TxOut (..), XPubKey,
                                            blockHashToHex, derivePubPath,
                                            eitherToMaybe, headerHash,
                                            pathToList, scriptToAddressBS,
                                            txHash, txHashToHex, xPubAddr,
                                            xPubCompatWitnessAddr, xPubExport,
                                            xPubWitnessAddr)
import           Haskoin.Node              (Chain, chainBlockMain,
                                            chainGetAncestor, chainGetBlock)
import           Haskoin.Store.Common      (Limit, Offset, StoreRead (..),
                                            sortTxs, xPubBals, xPubBalsTxs,
                                            xPubBalsUnspents, xPubTxs)
import           Haskoin.Store.Data        (Balance (..), BlockData (..),
                                            BlockRef (..), BlockTx (..),
                                            DeriveType (..), Prev (..),
                                            TxData (..), Unspent (..),
                                            XPubBal (..), XPubSpec (..),
                                            XPubUnspent (..), nullBalance)
import           NQE                       (Inbox, Mailbox, receive, send)
import           System.Random             (randomIO, randomRIO)
import           UnliftIO                  (Exception, MonadIO, MonadUnliftIO,
                                            bracket, liftIO, throwIO)
import           UnliftIO.Concurrent       (threadDelay)

runRedis :: MonadLoggerIO m => Redis (Either Reply a) -> CacheT m a
runRedis action =
    asks cacheConn >>= \conn ->
        liftIO (Redis.runRedis conn action) >>= \case
            Right x -> return x
            Left e -> do
                $(logErrorS) "Cache" $ "Got error from Redis: " <> cs (show e)
                throwIO (RedisError e)

data CacheConfig =
    CacheConfig
        { cacheConn  :: !Connection
        , cacheMin   :: !Int
        , cacheMax   :: !Integer
        , cacheChain :: !Chain
        }

type CacheT = ReaderT CacheConfig

data CacheError
    = RedisError Reply
    | RedisTxError !String
    | LogicError !String
    deriving (Show, Eq, Generic, NFData, Exception)

connectRedis :: MonadIO m => String -> m Connection
connectRedis redisurl = do
    conninfo <-
        if null redisurl
            then return defaultConnectInfo
            else case parseConnectInfo redisurl of
                     Left e  -> error e
                     Right r -> return r
    liftIO (checkedConnect conninfo)

instance (MonadUnliftIO m, MonadLoggerIO m, StoreRead m) =>
         StoreRead (CacheT m) where
    getNetwork = lift getNetwork
    getBestBlock = lift getBestBlock
    getBlocksAtHeight = lift . getBlocksAtHeight
    getBlock = lift . getBlock
    getTxData = lift . getTxData
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
    getMaxGap = lift getMaxGap
    getInitialGap = lift getInitialGap

withCache :: StoreRead m => CacheConfig -> CacheT m a -> m a
withCache s f = runReaderT f s

balancesPfx :: ByteString
balancesPfx = "b"

txSetPfx :: ByteString
txSetPfx = "t"

utxoPfx :: ByteString
utxoPfx = "u"

getXPubTxs ::
       (MonadUnliftIO m, MonadLoggerIO m, StoreRead m)
    => XPubSpec
    -> Maybe BlockRef
    -> Offset
    -> Maybe Limit
    -> CacheT m [BlockTx]
getXPubTxs xpub start offset limit = do
    xpubtxt <- xpubText xpub
    $(logDebugS) "Cache" $ "Getting xpub txs for " <> xpubtxt
    isXPubCached xpub >>= \case
        True -> do
            txs <- cacheGetXPubTxs xpub start offset limit
            $(logDebugS) "Cache" $
                "Returning " <> cs (show (length txs)) <>
                " transactions for cached xpub: " <>
                xpubtxt
            return txs
        False -> do
            $(logDebugS) "Cache" $ "Caching new xpub " <> xpubtxt
            newXPubC xpub >>= \(bals, t) ->
                if t
                    then do
                        $(logDebugS) "Cache" $
                            "Successfully cached xpub " <> xpubtxt
                        cacheGetXPubTxs xpub start offset limit
                    else do
                        $(logDebugS) "Cache" $
                            "Using DB to return txs for xpub " <> xpubtxt
                        xPubBalsTxs bals start offset limit

getXPubUnspents ::
       (MonadUnliftIO m, MonadLoggerIO m, StoreRead m)
    => XPubSpec
    -> Maybe BlockRef
    -> Offset
    -> Maybe Limit
    -> CacheT m [XPubUnspent]
getXPubUnspents xpub start offset limit = do
    xpubtxt <- xpubText xpub
    $(logDebugS) "Cache" $ "Getting utxo for xpub " <> xpubtxt
    isXPubCached xpub >>= \case
        True -> do
            bals <- cacheGetXPubBalances xpub
            process bals
        False -> do
            newXPubC xpub >>= \(bals, t) ->
                if t
                    then do
                        $(logDebugS) "Cache" $
                            "Successfully cached xpub " <> xpubtxt
                        process bals
                    else do
                        $(logDebugS) "Cache" $
                            "Using DB to return utxo for xpub " <> xpubtxt
                        xPubBalsUnspents bals start offset limit
  where
    process bals = do
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
                    (\(a, u) -> (\p -> XPubUnspent p u) <$> Map.lookup a addrmap)
                    addrutxo
        xpubtxt <- xpubText xpub
        $(logDebugS) "Cache" $
            "Returning " <> cs (show (length xpubutxo)) <>
            " utxos for cached xpub: " <>
            xpubtxt
        return xpubutxo

getXPubBalances ::
       (MonadUnliftIO m, MonadLoggerIO m, StoreRead m)
    => XPubSpec
    -> CacheT m [XPubBal]
getXPubBalances xpub = do
    xpubtxt <- xpubText xpub
    $(logDebugS) "Cache" $ "Getting balances for xpub " <> xpubtxt
    isXPubCached xpub >>= \case
        True -> do
            bals <- cacheGetXPubBalances xpub
            $(logDebugS) "Cache" $
                "Returning " <> cs (show (length bals)) <> " balances for xpub " <>
                xpubtxt
            return bals
        False -> do
            $(logDebugS) "Cache" $ "Caching balances for xpub " <> xpubtxt
            fst <$> newXPubC xpub

isXPubCached :: MonadLoggerIO m => XPubSpec -> CacheT m Bool
isXPubCached = runRedis . redisIsXPubCached

redisIsXPubCached :: RedisCtx m f => XPubSpec -> m (f Bool)
redisIsXPubCached xpub = Redis.exists (balancesPfx <> encode xpub)

cacheGetXPubBalances :: MonadLoggerIO m => XPubSpec -> CacheT m [XPubBal]
cacheGetXPubBalances xpub = do
    bals <- runRedis $ redisGetXPubBalances xpub
    touchKeys [xpub]
    return bals

cacheGetXPubTxs ::
       MonadLoggerIO m
    => XPubSpec
    -> Maybe BlockRef
    -> Offset
    -> Maybe Limit
    -> CacheT m [BlockTx]
cacheGetXPubTxs xpub start offset limit = do
    txs <- runRedis $ redisGetXPubTxs xpub start offset limit
    touchKeys [xpub]
    return txs

cacheGetXPubUnspents ::
       MonadLoggerIO m
    => XPubSpec
    -> Maybe BlockRef
    -> Offset
    -> Maybe Limit
    -> CacheT m [(BlockRef, OutPoint)]
cacheGetXPubUnspents xpub start offset limit = do
    uns <- runRedis $ redisGetXPubUnspents xpub start offset limit
    touchKeys [xpub]
    return uns

redisGetXPubBalances :: (Functor f, RedisCtx m f) => XPubSpec -> m (f [XPubBal])
redisGetXPubBalances xpub =
    getAllFromMap (balancesPfx <> encode xpub) >>=
    return . fmap (sort . map (uncurry f))
  where
    f p b = XPubBal {xPubBalPath = p, xPubBal = b}

redisGetXPubTxs ::
       (Applicative f, RedisCtx m f)
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
    return $ map (uncurry f) <$> xs
  where
    f t s = BlockTx {blockTxHash = t, blockTxBlock = scoreBlockRef s}

redisGetXPubUnspents ::
       (Applicative f, RedisCtx m f)
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
    return $ map (uncurry f) <$> xs
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
       (Applicative f, RedisCtx m f, Serialize a)
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
getFromSortedSet key Nothing offset (Just count)
    | count <= 0 = return (pure [])
    | otherwise = do
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
       (Functor f, RedisCtx m f, Serialize k, Serialize v)
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

data CacheWriterMessage
    = CacheNewBlock
    | CacheNewTx !TxHash

type CacheWriterInbox = Inbox CacheWriterMessage
type CacheWriter = Mailbox CacheWriterMessage

data AddressXPub =
    AddressXPub
        { addressXPubSpec :: !XPubSpec
        , addressXPubPath :: ![KeyIndex]
        } deriving (Show, Eq, Generic, NFData, Serialize)

mempoolSetKey :: ByteString
mempoolSetKey = "mempool"

lockKey :: ByteString
lockKey = "xpub"

importLockKey :: ByteString
importLockKey = "import"

addrPfx :: ByteString
addrPfx = "a"

bestBlockKey :: ByteString
bestBlockKey = "head"

maxKey :: ByteString
maxKey = "max"

isAnythingCached :: MonadLoggerIO m => CacheT m Bool
isAnythingCached = runRedis $ Redis.exists maxKey

xPubAddrFunction :: DeriveType -> XPubKey -> Address
xPubAddrFunction DeriveNormal = xPubAddr
xPubAddrFunction DeriveP2SH   = xPubCompatWitnessAddr
xPubAddrFunction DeriveP2WPKH = xPubWitnessAddr

cacheWriter ::
       (MonadUnliftIO m, MonadLoggerIO m, StoreRead m)
    => CacheConfig
    -> CacheWriterInbox
    -> m ()
cacheWriter cfg inbox = runReaderT go cfg
  where
    go = do
        newBlockC
        forever $ do
            pruneDB
            x <- receive inbox
            cacheWriterReact x

lockIt :: MonadLoggerIO m => ByteString -> CacheT m (Maybe Word32)
lockIt k = do
    rnd <- liftIO randomIO
    go rnd >>= \case
        Right Redis.Ok -> do
            $(logDebugS) "Cache" $
                "Acquired " <> cs k <> " lock with value " <> cs (show rnd)
            return (Just rnd)
        Right Redis.Pong -> do
            $(logErrorS) "Cache" $
                "Unexpected pong when acquiring " <> cs k <> " lock"
            return Nothing
        Right (Redis.Status s) -> do
            $(logErrorS) "Cache" $
                "Unexpected status acquiring " <> cs k <> " lock: " <> cs s
            return Nothing
        Left (Redis.Bulk Nothing) -> return Nothing
        Left e -> do
            $(logErrorS) "Cache" $
                "Error when trying to acquire " <> cs k <> " lock"
            throwIO (RedisError e)
  where
    go rnd = do
        conn <- asks cacheConn
        liftIO . Redis.runRedis conn $ do
            let opts =
                    Redis.SetOpts
                        { Redis.setSeconds = Just 30
                        , Redis.setMilliseconds = Nothing
                        , Redis.setCondition = Just Redis.Nx
                        }
            Redis.setOpts k (cs (show rnd)) opts


unlockIt :: MonadLoggerIO m => ByteString -> Maybe Word32 -> CacheT m ()
unlockIt _ Nothing = return ()
unlockIt k (Just i) =
    runRedis (Redis.get k) >>= \case
        Nothing ->
            $(logErrorS) "Cache" $
            "Not releasing " <> cs k <> " lock with value " <> cs (show i) <>
            ": not locked"
        Just bs ->
            if read (cs bs) == i
                then do
                    runRedis (Redis.del [k]) >> return ()
                    $(logDebugS) "Cache" $
                        "Released " <> cs k <> " lock with value " <>
                        cs (show i)
                else do
                    $(logErrorS) "Cache" $
                        "Could not release " <> cs k <> " lock: value is not " <>
                        cs (show i)

withLock ::
       (MonadLoggerIO m, MonadUnliftIO m)
    => ByteString
    -> CacheT m a
    -> CacheT m (Maybe a)
withLock k f =
    bracket (lockIt k) (unlockIt k) $ \case
        Just _ -> Just <$> f
        Nothing -> return Nothing

withLockWait ::
       (MonadLoggerIO m, MonadUnliftIO m)
    => ByteString
    -> CacheT m a
    -> CacheT m a
withLockWait k f = do
    $(logDebugS) "Cache" $ "Acquiring " <> cs k <> " lock…"
    go
  where
    go =
        withLock k f >>= \case
            Just x -> return x
            Nothing -> do
                r <- liftIO $ randomRIO (500, 10000)
                threadDelay r
                go

pruneDB :: (MonadUnliftIO m, MonadLoggerIO m, StoreRead m) => CacheT m Integer
pruneDB = do
    isAnythingCached >>= \case
        True -> do
            x <- asks cacheMax
            s <- runRedis Redis.dbsize
            if s > x
                then flush (s - x)
                else return 0
        False -> return 0
  where
    flush n = do
        case min 1000 (n `div` 64) of
            0 -> return 0
            x ->
                withLockWait lockKey $ do
                    ks <-
                        fmap (map fst) . runRedis $
                        getFromSortedSet maxKey Nothing 0 (Just x)
                    $(logDebugS) "Cache" $
                        "Pruning " <> cs (show (length ks)) <> " old xpubs"
                    delXPubKeys ks

touchKeys :: MonadLoggerIO m => [XPubSpec] -> CacheT m ()
touchKeys xpubs = do
    now <- systemSeconds <$> liftIO getSystemTime
    runRedis $ redisTouchKeys now xpubs

redisTouchKeys :: (Monad f, RedisCtx m f, Real a) => a -> [XPubSpec] -> m (f ())
redisTouchKeys _ [] = return $ return ()
redisTouchKeys now xpubs =
    void <$> Redis.zadd maxKey (map ((realToFrac now, ) . encode) xpubs)

cacheWriterReact ::
       (MonadUnliftIO m, MonadLoggerIO m, StoreRead m)
    => CacheWriterMessage
    -> CacheT m ()
cacheWriterReact CacheNewBlock = newBlockC
cacheWriterReact (CacheNewTx th) =
    withLockWait importLockKey $ do
        runRedis (Redis.zscore mempoolSetKey (encode th)) >>= \case
            Nothing ->
                lift (getTxData th) >>= \case
                    Just td -> do
                        $(logDebugS) "Cache" $
                            "Updating cache with tx: " <> txHashToHex th
                        importMultiTxC [td]
                    Nothing ->
                        $(logErrorS) "Cache" $
                        "Tx not found in db: " <> txHashToHex th
            Just _ ->
                $(logDebugS) "Cache" $ "Tx already in cache: " <> txHashToHex th

lenNotNull :: [XPubBal] -> Int
lenNotNull bals = length $ filter (not . nullBalance . xPubBal) bals

newXPubC ::
       (MonadUnliftIO m, MonadLoggerIO m, StoreRead m)
    => XPubSpec
    -> CacheT m ([XPubBal], Bool)
newXPubC xpub =
    cachePrime >> do
        bals <- lift $ xPubBals xpub
        x <- asks cacheMin
        xpubtxt <- xpubText xpub
        let n = lenNotNull bals
        if x <= n
            then do
                go bals
                return (bals, True)
            else do
                $(logDebugS) "Cache" $
                    "Not caching xpub with " <> cs (show n) <>
                    " used addresses: " <>
                    xpubtxt
                return (bals, False)
  where
    op XPubUnspent {xPubUnspent = u} = (unspentPoint u, unspentBlock u)
    go bals = do
        xpubtxt <- xpubText xpub
        $(logDebugS) "Cache" $
            "Caching xpub with " <> cs (show (length bals)) <>
            " addresses (used: " <>
            cs (show (lenNotNull bals)) <>
            "): " <>
            xpubtxt
        utxo <- lift $ xPubUnspents xpub Nothing 0 Nothing
        $(logDebugS) "Cache" $
            "Caching xpub with " <> cs (show (length utxo)) <> " utxos: " <>
            xpubtxt
        xtxs <- lift $ xPubTxs xpub Nothing 0 Nothing
        $(logDebugS) "Cache" $
            "Caching xpub with " <> cs (show (length xtxs)) <> " txs: " <>
            xpubtxt
        now <- systemSeconds <$> liftIO getSystemTime
        withLockWait lockKey . runRedis $ do
            b <- redisTouchKeys now [xpub]
            c <- redisAddXPubBalances xpub bals
            d <- redisAddXPubUnspents xpub (map op utxo)
            e <- redisAddXPubTxs xpub xtxs
            return $ b >> c >> d >> e >> return ()

newBlockC :: (MonadUnliftIO m, MonadLoggerIO m, StoreRead m) => CacheT m ()
newBlockC = withLockWait importLockKey f
  where
    f =
        isAnythingCached >>= \case
            False ->
                $(logDebugS) "Cache" "Not syncing blocks because cache is empty"
            True ->
                cachePrime >>= \case
                    Nothing -> return ()
                    Just cachehead ->
                        lift getBestBlock >>= \case
                            Nothing -> return ()
                            Just newhead -> go newhead cachehead
    go newhead cachehead
        | cachehead == newhead = do
            $(logDebugS) "Cache" $
                "Blocks in sync: " <> blockHashToHex cachehead
            syncMempoolC
        | otherwise =
            asks cacheChain >>= \ch ->
                chainBlockMain newhead ch >>= \case
                    False ->
                        $(logErrorS) "Cache" $
                        "New head not in main chain: " <> blockHashToHex newhead
                    True ->
                        chainGetBlock cachehead ch >>= \case
                            Nothing ->
                                $(logErrorS) "Cache" $
                                "Cache head block node not found: " <>
                                blockHashToHex cachehead
                            Just cacheheadnode ->
                                chainBlockMain cachehead ch >>= \case
                                    False -> do
                                        $(logWarnS) "Cache" $
                                            "Reverting cache head not in main chain: " <>
                                            blockHashToHex cachehead
                                        removeHeadC >> f
                                    True ->
                                        chainGetBlock newhead ch >>= \case
                                            Nothing -> do
                                                $(logErrorS) "Cache" $
                                                    "Cache head node not found: " <>
                                                    blockHashToHex newhead
                                                throwIO $
                                                    LogicError $
                                                    "Cache head node not found: " <>
                                                    cs (blockHashToHex newhead)
                                            Just newheadnode ->
                                                next newheadnode cacheheadnode
    next newheadnode cacheheadnode =
        asks cacheChain >>= \ch ->
            chainGetAncestor (nodeHeight cacheheadnode + 1) newheadnode ch >>= \case
                Nothing -> do
                    $(logErrorS) "Cache" $
                        "Ancestor not found at height " <>
                        cs (show (nodeHeight cacheheadnode + 1)) <>
                        " for block: " <>
                        blockHashToHex (headerHash (nodeHeader newheadnode))
                Just newcachenode ->
                    importBlockC (headerHash (nodeHeader newcachenode)) >> f

importBlockC :: (MonadUnliftIO m, StoreRead m, MonadLoggerIO m) => BlockHash -> CacheT m ()
importBlockC bh =
    lift (getBlock bh) >>= \case
        Nothing -> do
            $(logErrorS) "Cache" $ "Could not get block: " <> blockHashToHex bh
            throwIO . LogicError . cs $
                "Could not get block: " <> blockHashToHex bh
        Just bd -> do
            go bd
  where
    go bd = do
        let ths = blockDataTxs bd
        tds <- sortTxData . catMaybes <$> mapM (lift . getTxData) ths
        $(logDebugS) "Cache" $
            "Importing " <> cs (show (length tds)) <>
            " transactions from block " <>
            blockHashToHex bh
        importMultiTxC tds
        $(logInfoS) "Cache" $
            "Done importing " <> cs (show (length tds)) <>
            " transactions from block " <>
            blockHashToHex bh
        cacheSetHead bh

removeHeadC :: (StoreRead m, MonadUnliftIO m, MonadLoggerIO m) => CacheT m ()
removeHeadC =
    void . runMaybeT $ do
        bh <- MaybeT cacheGetHead
        bd <- MaybeT (lift (getBlock bh))
        lift $ do
            tds <-
                sortTxData . catMaybes <$>
                mapM (lift . getTxData) (blockDataTxs bd)
            $(logDebugS) "Cache" $ "Reverting head: " <> blockHashToHex bh
            importMultiTxC tds
            $(logWarnS) "Cache" $
                "Reverted block head " <> blockHashToHex bh <> " to parent " <>
                blockHashToHex (prevBlock (blockDataHeader bd))
            cacheSetHead (prevBlock (blockDataHeader bd))

importMultiTxC ::
       (MonadUnliftIO m, StoreRead m, MonadLoggerIO m)
    => [TxData]
    -> CacheT m ()
importMultiTxC txs = do
    $(logDebugS) "Cache" $ "Processing " <> cs (show (length txs)) <> " txs…"
    $(logDebugS) "Cache" $
        "Getting address information for " <> cs (show (length alladdrs)) <>
        " addresses…"
    addrmap <- getaddrmap
    let addrs = HashMap.keys addrmap
    $(logDebugS) "Cache" $
        "Getting balances for " <> cs (show (HashMap.size addrmap)) <>
        " addresses…"
    balmap <- getbalances addrs
    $(logDebugS) "Cache" $
        "Getting unspent data for " <> cs (show (length allops)) <> " outputs…"
    unspentmap <- getunspents
    gap <- getMaxGap
    now <- systemSeconds <$> liftIO getSystemTime
    let xpubs = allxpubsls addrmap
    forM_ (zip [(1 :: Int) ..] xpubs) $ \(i, xpub) -> do
        xpubtxt <- xpubText xpub
        $(logDebugS) "Cache" $
            "Affected xpub " <> cs (show i) <> "/" <> cs (show (length xpubs)) <>
            ": " <>
            xpubtxt
    addrs' <-
        withLockWait lockKey $ do
            $(logDebugS) "Cache" $
                "Getting xpub balances for " <> cs (show (length xpubs)) <>
                " xpubs…"
            xmap <- getxbals xpubs
            let addrmap' = faddrmap (HashMap.keysSet xmap) addrmap
            $(logDebugS) "Cache" $ "Starting Redis import pipeline…"
            runRedis $ do
                x <- redisImportMultiTx addrmap' unspentmap txs
                y <- redisUpdateBalances addrmap' balmap
                z <- redisTouchKeys now (HashMap.keys xmap)
                return $ x >> y >> z >> return ()
            $(logDebugS) "Cache" $ "Completed Redis pipeline"
            return $ getNewAddrs gap xmap (HashMap.elems addrmap')
    cacheAddAddresses addrs'
  where
    alladdrsls = HashSet.toList alladdrs
    faddrmap xmap = HashMap.filter (\a -> addressXPubSpec a `elem` xmap)
    getaddrmap =
        HashMap.fromList . catMaybes . zipWith (\a -> fmap (a, )) alladdrsls <$>
        cacheGetAddrsInfo alladdrsls
    getunspents =
        HashMap.fromList . catMaybes . zipWith (\p -> fmap (p, )) allops <$>
        lift (mapM getUnspent allops)
    getbalances addrs =
        HashMap.fromList . zipWith (,) addrs <$> mapM (lift . getBalance) addrs
    getxbals xpubs = do
        bals <-
            runRedis . fmap sequence . forM xpubs $ \xpub -> do
                bs <- redisGetXPubBalances xpub
                return $ (xpub, ) <$> bs
        return $ HashMap.filter (not . null) (HashMap.fromList bals)
    allops = map snd $ concatMap txInputs txs <> concatMap txOutputs txs
    alladdrs =
        HashSet.fromList . map fst $
        concatMap txInputs txs <> concatMap txOutputs txs
    allxpubsls addrmap = HashSet.toList (allxpubs addrmap)
    allxpubs addrmap =
        HashSet.fromList . map addressXPubSpec $ HashMap.elems addrmap

redisImportMultiTx ::
       (Monad f, RedisCtx m f)
    => HashMap Address AddressXPub
    -> HashMap OutPoint Unspent
    -> [TxData]
    -> m (f ())
redisImportMultiTx addrmap unspentmap txs = do
    xs <- mapM importtxentries txs
    return $ sequence xs >> return ()
  where
    uns p i =
        case HashMap.lookup p unspentmap of
            Just u ->
                redisAddXPubUnspents (addressXPubSpec i) [(p, unspentBlock u)]
            Nothing -> redisRemXPubUnspents (addressXPubSpec i) [p]
    addtx tx a p =
        case HashMap.lookup a addrmap of
            Just i -> do
                x <-
                    redisAddXPubTxs
                        (addressXPubSpec i)
                        [ BlockTx
                              { blockTxHash = txHash (txData tx)
                              , blockTxBlock = txDataBlock tx
                              }
                        ]
                y <- uns p i
                return $ x >> y >> return ()
            Nothing -> return (pure ())
    remtx tx a p =
        case HashMap.lookup a addrmap of
            Just i -> do
                x <- redisRemXPubTxs (addressXPubSpec i) [txHash (txData tx)]
                y <- uns p i
                return $ x >> y >> return ()
            Nothing -> return (pure ())
    importtxentries tx =
        if txDataDeleted tx
            then do
                x <- mapM (uncurry (remtx tx)) (txaddrops tx)
                y <- redisRemFromMempool [txHash (txData tx)]
                return $ sequence x >> y >> return ()
            else do
                a <- sequence <$> mapM (uncurry (addtx tx)) (txaddrops tx)
                b <-
                    case txDataBlock tx of
                        b@MemRef {} ->
                            redisAddToMempool $
                            (: [])
                                BlockTx
                                    { blockTxHash = txHash (txData tx)
                                    , blockTxBlock = b
                                    }
                        _ -> redisRemFromMempool [txHash (txData tx)]
                return $ a >> b >> return ()
    txaddrops td = spnts td <> utxos td
    spnts td = txInputs td
    utxos td = txOutputs td

redisUpdateBalances ::
       (Monad f, RedisCtx m f)
    => HashMap Address AddressXPub
    -> HashMap Address Balance
    -> m (f ())
redisUpdateBalances addrmap balmap =
    fmap (fmap mconcat . sequence) . forM (HashMap.keys addrmap) $ \a ->
        case (HashMap.lookup a addrmap, HashMap.lookup a balmap) of
            (Just ainfo, Just bal) ->
                redisAddXPubBalances (addressXPubSpec ainfo) [xpubbal ainfo bal]
            _ -> return (pure ())
  where
    xpubbal ainfo bal =
        XPubBal {xPubBalPath = addressXPubPath ainfo, xPubBal = bal}

cacheAddAddresses ::
       (StoreRead m, MonadUnliftIO m, MonadLoggerIO m)
    => [(Address, AddressXPub)]
    -> CacheT m ()
cacheAddAddresses [] = $(logDebugS) "Cache" "No further addresses to add"
cacheAddAddresses addrs = do
    $(logDebugS) "Cache" $
        "Adding " <> cs (show (length addrs)) <> " new generated addresses"
    $(logDebugS) "Cache" $ "Getting balances…"
    balmap <- HashMap.fromListWith (<>) <$> mapM (uncurry getbal) addrs
    $(logDebugS) "Cache" $ "Getting unspent outputs…"
    utxomap <- HashMap.fromListWith (<>) <$> mapM (uncurry getutxo) addrs
    $(logDebugS) "Cache" $ "Getting transactions…"
    txmap <- HashMap.fromListWith (<>) <$> mapM (uncurry gettxmap) addrs
    withLockWait lockKey $ do
        $(logDebugS) "Cache" $ "Running Redis pipeline…"
        runRedis $ do
            a <- forM (HashMap.toList balmap) (uncurry redisAddXPubBalances)
            b <- forM (HashMap.toList utxomap) (uncurry redisAddXPubUnspents)
            c <- forM (HashMap.toList txmap) (uncurry redisAddXPubTxs)
            return $ sequence a >> sequence b >> sequence c >> return ()
        $(logDebugS) "Cache" $ "Completed Redis pipeline"
    let xpubs = HashSet.toList . HashSet.fromList . map addressXPubSpec $ Map.elems amap
    $(logDebugS) "Cache" $ "Getting xpub balances…"
    xmap <- getbals xpubs
    gap <- getMaxGap
    let notnulls = getnotnull balmap
        addrs' = getNewAddrs gap xmap notnulls
    cacheAddAddresses addrs'
  where
    getbals xpubs =
        runRedis $ do
            bs <- sequence <$> forM xpubs redisGetXPubBalances
            return $
                HashMap.filter (not . null) . HashMap.fromList . zip xpubs <$>
                bs
    amap = Map.fromList addrs
    getnotnull =
        let f xpub =
                map $ \bal ->
                    AddressXPub
                        { addressXPubSpec = xpub
                        , addressXPubPath = xPubBalPath bal
                        }
            g = filter (not . nullBalance . xPubBal)
         in concatMap (uncurry f) . HashMap.toList . HashMap.map g
    getbal a i =
        let f b =
                ( addressXPubSpec i
                , [XPubBal {xPubBal = b, xPubBalPath = addressXPubPath i}])
         in f <$> lift (getBalance a)
    getutxo a i =
        let f us =
                ( addressXPubSpec i
                , map (\u -> (unspentPoint u, unspentBlock u)) us)
         in f <$> lift (getAddressUnspents a Nothing Nothing)
    gettxmap a i =
        let f ts = (addressXPubSpec i, ts)
         in f <$> lift (getAddressTxs a Nothing Nothing)


getNewAddrs ::
       KeyIndex
    -> HashMap XPubSpec [XPubBal]
    -> [AddressXPub]
    -> [(Address, AddressXPub)]
getNewAddrs gap xpubs = concatMap f
  where
    f a =
        case HashMap.lookup (addressXPubSpec a) xpubs of
            Nothing   -> []
            Just bals -> addrsToAdd gap bals a

syncMempoolC :: (MonadUnliftIO m, MonadLoggerIO m, StoreRead m) => CacheT m ()
syncMempoolC = do
    nodepool <- (HashSet.fromList . map blockTxHash) <$> lift getMempool
    cachepool <- (HashSet.fromList . map blockTxHash) <$> cacheGetMempool
    txs <-
        mapM getit . HashSet.toList $
        mappend
            (HashSet.difference nodepool cachepool)
            (HashSet.difference cachepool nodepool)
    unless (null txs) $ do
        $(logDebugS) "Cache" $
            "Importing " <> cs (show (length txs)) <> " mempool transactions"
        importMultiTxC (rights txs)
        forM_ (zip [(1 :: Int) ..] (lefts txs)) $ \(i, h) ->
            $(logDebugS) "Cache" $
            "Ignoring cache mempool tx " <> cs (show i) <> "/" <>
            cs (show (length txs)) <>
            ": " <>
            txHashToHex h
  where
    getit th =
        lift (getTxData th) >>= \case
            Nothing -> return (Left th)
            Just tx -> return (Right tx)

cacheGetMempool :: MonadLoggerIO m => CacheT m [BlockTx]
cacheGetMempool = runRedis redisGetMempool

cacheGetHead :: MonadLoggerIO m => CacheT m (Maybe BlockHash)
cacheGetHead = runRedis redisGetHead

cachePrime ::
       (StoreRead m, MonadUnliftIO m, MonadLoggerIO m)
    => CacheT m (Maybe BlockHash)
cachePrime =
    cacheGetHead >>= \case
        Nothing -> do
            $(logInfoS) "Cache" "Cache has no best block set"
            lift getBestBlock >>= \case
                Nothing -> do
                    $(logInfoS) "Cache" "Best block not set yet"
                    return Nothing
                Just newhead -> do
                    mem <- lift getMempool
                    withLockWait lockKey . runRedis $ do
                        a <- redisAddToMempool mem
                        b <- redisSetHead newhead
                        return $ a >> b >> return (Just newhead)
        Just cachehead -> return $ Just cachehead

cacheSetHead :: (MonadLoggerIO m, StoreRead m) => BlockHash -> CacheT m ()
cacheSetHead bh = do
    $(logDebugS) "Cache" $ "Cache head set to: " <> blockHashToHex bh
    runRedis (redisSetHead bh) >> return ()

cacheGetAddrsInfo ::
       MonadLoggerIO m => [Address] -> CacheT m [Maybe AddressXPub]
cacheGetAddrsInfo as = runRedis (redisGetAddrsInfo as)

redisAddToMempool :: (Applicative f, RedisCtx m f) => [BlockTx] -> m (f Integer)
redisAddToMempool [] = return (pure 0)
redisAddToMempool btxs =
    zadd mempoolSetKey $
    map (\btx -> (blockRefScore (blockTxBlock btx), encode (blockTxHash btx)))
        btxs

redisRemFromMempool ::
       (Applicative f, RedisCtx m f) => [TxHash] -> m (f Integer)
redisRemFromMempool [] = return (pure 0)
redisRemFromMempool xs = zrem mempoolSetKey $ map encode xs

redisSetAddrInfo ::
       (Functor f, RedisCtx m f) => Address -> AddressXPub -> m (f ())
redisSetAddrInfo a i = void <$> Redis.set (addrPfx <> encode a) (encode i)

delXPubKeys ::
       (MonadUnliftIO m, MonadLoggerIO m, StoreRead m)
    => [XPubSpec]
    -> CacheT m Integer
delXPubKeys [] = return 0
delXPubKeys xpubs = do
    forM_ xpubs $ \x -> do
        xtxt <- xpubText x
        $(logDebugS) "Cache" $ "Deleting xpub: " <> xtxt
    xbals <-
        runRedis . fmap sequence . forM xpubs $ \xpub -> do
            bs <- redisGetXPubBalances xpub
            return $ (xpub, ) <$> bs
    runRedis $ fmap sum . sequence <$> forM xbals (uncurry redisDelXPubKeys)

redisDelXPubKeys ::
       (Monad f, RedisCtx m f) => XPubSpec -> [XPubBal] -> m (f Integer)
redisDelXPubKeys xpub bals = go (map (balanceAddress . xPubBal) bals)
  where
    go addrs = do
        addrcount <-
            case addrs of
                [] -> return (pure 0)
                _  -> Redis.del (map ((addrPfx <>) . encode) addrs)
        txsetcount <- Redis.del [txSetPfx <> encode xpub]
        utxocount <- Redis.del [utxoPfx <> encode xpub]
        balcount <- Redis.del [balancesPfx <> encode xpub]
        x <- Redis.zrem maxKey [encode xpub]
        return $ do
            _ <- x
            addrs' <- addrcount
            txset' <- txsetcount
            utxo' <- utxocount
            bal' <- balcount
            return $ addrs' + txset' + utxo' + bal'

redisAddXPubTxs ::
       (Applicative f, RedisCtx m f) => XPubSpec -> [BlockTx] -> m (f Integer)
redisAddXPubTxs _ [] = return (pure 0)
redisAddXPubTxs xpub btxs =
    zadd (txSetPfx <> encode xpub) $
    map (\t -> (blockRefScore (blockTxBlock t), encode (blockTxHash t))) btxs

redisRemXPubTxs ::
       (Applicative f, RedisCtx m f) => XPubSpec -> [TxHash] -> m (f Integer)
redisRemXPubTxs _ []      = return (pure 0)
redisRemXPubTxs xpub txhs = zrem (txSetPfx <> encode xpub) (map encode txhs)

redisAddXPubUnspents ::
       (Applicative f, RedisCtx m f)
    => XPubSpec
    -> [(OutPoint, BlockRef)]
    -> m (f Integer)
redisAddXPubUnspents _ [] = return (pure 0)
redisAddXPubUnspents xpub utxo =
    zadd (utxoPfx <> encode xpub) $
    map (\(p, r) -> (blockRefScore r, encode p)) utxo

redisRemXPubUnspents ::
       (Applicative f, RedisCtx m f) => XPubSpec -> [OutPoint] -> m (f Integer)
redisRemXPubUnspents _ []     = return (pure 0)
redisRemXPubUnspents xpub ops = zrem (utxoPfx <> encode xpub) (map encode ops)

redisAddXPubBalances ::
       (Monad f, RedisCtx m f) => XPubSpec -> [XPubBal] -> m (f ())
redisAddXPubBalances _ [] = return (pure ())
redisAddXPubBalances xpub bals = do
    xs <- mapM (uncurry (Redis.hset (balancesPfx <> encode xpub))) entries
    ys <-
        forM bals $ \b ->
            redisSetAddrInfo
                (balanceAddress (xPubBal b))
                AddressXPub
                    {addressXPubSpec = xpub, addressXPubPath = xPubBalPath b}
    return $ sequence xs >> sequence ys >> return ()
  where
    entries = map (\b -> (encode (xPubBalPath b), encode (xPubBal b))) bals

redisSetHead :: RedisCtx m f => BlockHash -> m (f Redis.Status)
redisSetHead bh = Redis.set bestBlockKey (encode bh)

redisGetAddrsInfo ::
       (Monad f, RedisCtx m f) => [Address] -> m (f [Maybe AddressXPub])
redisGetAddrsInfo [] = return (pure [])
redisGetAddrsInfo as = do
    is <- mapM (\a -> Redis.get (addrPfx <> encode a)) as
    return $ do
        is' <- sequence is
        return $ map (eitherToMaybe . decode =<<) is'

addrsToAdd :: KeyIndex -> [XPubBal] -> AddressXPub -> [(Address, AddressXPub)]
addrsToAdd gap xbals addrinfo
    | null fbals = []
    | otherwise = zipWith f addrs list
  where
    f a p = (a, AddressXPub {addressXPubSpec = xpub, addressXPubPath = p})
    dchain = head (addressXPubPath addrinfo)
    fbals = filter ((== dchain) . head . xPubBalPath) xbals
    maxidx = maximum (map (head . tail . xPubBalPath) fbals)
    xpub = addressXPubSpec addrinfo
    aidx = (head . tail) (addressXPubPath addrinfo)
    ixs =
        if gap > maxidx - aidx
            then [maxidx + 1 .. aidx + gap]
            else []
    paths = map (Deriv :/ dchain :/) ixs
    keys = map (\p -> derivePubPath p (xPubSpecKey xpub)) paths
    list = map pathToList paths
    xpubf = xPubAddrFunction (xPubDeriveType xpub)
    addrs = map xpubf keys

sortTxData :: [TxData] -> [TxData]
sortTxData tds =
    let txm = Map.fromList (map (\d -> (txHash (txData d), d)) tds)
        ths = map (txHash . snd) (sortTxs (map txData tds))
     in mapMaybe (\h -> Map.lookup h txm) ths

txInputs :: TxData -> [(Address, OutPoint)]
txInputs td =
    let is = txIn (txData td)
        ps = I.toAscList (txDataPrevs td)
        as = map (scriptToAddressBS . prevScript . snd) ps
        f (Right a) i = Just (a, prevOutput i)
        f (Left _) _  = Nothing
     in catMaybes (zipWith f as is)

txOutputs :: TxData -> [(Address, OutPoint)]
txOutputs td =
    let ps =
            zipWith
                (\i _ ->
                     OutPoint
                         {outPointHash = txHash (txData td), outPointIndex = i})
                [0 ..]
                (txOut (txData td))
        as = map (scriptToAddressBS . scriptOutput) (txOut (txData td))
        f (Right a) p = Just (a, p)
        f (Left _) _  = Nothing
     in catMaybes (zipWith f as ps)

redisGetHead :: (Functor f, RedisCtx m f) => m (f (Maybe BlockHash))
redisGetHead = do
    x <- Redis.get bestBlockKey
    return $ (eitherToMaybe . decode =<<) <$> x

redisGetMempool :: (Applicative f, RedisCtx m f) => m (f [BlockTx])
redisGetMempool = do
    xs <- getFromSortedSet mempoolSetKey Nothing 0 Nothing
    return $ do
        ys <- xs
        return $ map (uncurry f) ys
  where
    f t s = BlockTx {blockTxBlock = scoreBlockRef s, blockTxHash = t}

xpubText :: (MonadUnliftIO m, MonadLoggerIO m, StoreRead m) => XPubSpec -> CacheT m Text
xpubText xpub = do
    net <- getNetwork
    return . cs $ xPubExport net (xPubSpecKey xpub)

cacheNewBlock :: MonadIO m => CacheWriter -> m ()
cacheNewBlock = send CacheNewBlock

cacheNewTx :: MonadIO m => TxHash -> CacheWriter -> m ()
cacheNewTx th = send (CacheNewTx th)
