{-# LANGUAGE ApplicativeDo        #-}
{-# LANGUAGE DeriveAnyClass       #-}
{-# LANGUAGE DeriveGeneric        #-}
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
    , CacheWriterMessage (..)
    , cacheWriter
    , isXPubCached
    , delXPubKeys
    ) where

import           Control.DeepSeq           (NFData)
import           Control.Monad             (forM, forM_, forever, void)
import           Control.Monad.Logger      (MonadLoggerIO, logDebugS, logErrorS,
                                            logInfoS, logWarnS)
import           Control.Monad.Reader      (ReaderT (..), asks)
import           Control.Monad.Trans       (lift)
import           Control.Monad.Trans.Maybe (MaybeT (..), runMaybeT)
import           Data.Bits                 (shift, (.&.), (.|.))
import           Data.ByteString           (ByteString)
import qualified Data.ByteString.Short     as BSS
import           Data.Either               (rights)
import           Data.HashMap.Strict       (HashMap)
import qualified Data.HashMap.Strict       as HashMap
import qualified Data.IntMap.Strict        as IntMap
import           Data.List                 (nub, sort, (\\))
import qualified Data.Map.Strict           as Map
import           Data.Maybe                (catMaybes, mapMaybe)
import           Data.Serialize            (decode, encode)
import           Data.Serialize            (Serialize)
import           Data.String.Conversions   (cs)
import           Data.Text                 (Text)
import           Data.Time.Clock.System    (getSystemTime, systemSeconds)
import           Data.Word                 (Word64)
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
import           Haskoin.Node              (Chain, chainGetAncestor,
                                            chainGetBlock, chainGetSplitBlock)
import           Haskoin.Store.Common      (Balance (..), BlockData (..),
                                            BlockRef (..), BlockTx (..),
                                            DeriveType (..), Limit, Offset,
                                            Prev (..), StoreRead (..),
                                            StoreRead (..), TxData (..),
                                            Unspent (..), XPubBal (..),
                                            XPubSpec (..), XPubUnspent (..),
                                            nullBalance, sortTxs, xPubBals,
                                            xPubBalsTxs, xPubBalsUnspents,
                                            xPubTxs)
import           NQE                       (Inbox, Mailbox, receive)
import           System.Random             (randomRIO)
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
    = CacheNewTx !TxHash
    | CacheDelTx !TxHash
    | CacheNewBlock
    deriving (Show, Eq, Generic, NFData)

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
lockKey = "lock"

addrPfx :: ByteString
addrPfx = "a"

bestBlockKey :: ByteString
bestBlockKey = "head"

maxKey :: ByteString
maxKey = "max"

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

lockIt :: MonadLoggerIO m => CacheT m Bool
lockIt = do
    go >>= \case
        Right Redis.Ok -> return True
        Right Redis.Pong -> do
            $(logErrorS) "Cache" $ "Got unexpected Pong from Redis"
            return False
        Right (Redis.Status s) -> do
            $(logErrorS) "Cache" $ "Got unexpected status from Redis: " <> cs s
            return False
        Left (Redis.Bulk Nothing) -> return False
        Left e -> do
            $(logErrorS) "Cache" $ "Error when trying to acquire lock"
            throwIO (RedisError e)
  where
    go = do
        conn <- asks cacheConn
        liftIO . Redis.runRedis conn $ do
            let opts =
                    Redis.SetOpts
                        { Redis.setSeconds = Just 30
                        , Redis.setMilliseconds = Nothing
                        , Redis.setCondition = Just Redis.Nx
                        }
            Redis.setOpts lockKey "l" opts


unlockIt :: MonadLoggerIO m => CacheT m ()
unlockIt = runRedis (Redis.del [lockKey]) >> return ()

withLock ::
       (MonadLoggerIO m, MonadUnliftIO m) => CacheT m a -> CacheT m (Maybe a)
withLock f =
    bracket lockIt (const unlockIt) $ \case
        True -> Just <$> f
        False -> return Nothing

withLockWait :: (MonadLoggerIO m, MonadUnliftIO m) => CacheT m a -> CacheT m a
withLockWait f =
    withLock f >>= \case
        Just x -> return x
        Nothing -> do
            r <- liftIO $ randomRIO (500, 10000)
            threadDelay r
            withLockWait f

pruneDB :: (MonadUnliftIO m, MonadLoggerIO m, StoreRead m) => CacheT m Integer
pruneDB =
    withLock go >>= \case
        Nothing -> return 0
        Just n -> return n
  where
    go = do
        x <- asks cacheMax
        s <- runRedis Redis.dbsize
        if s > x
            then flush (s - x)
            else return 0
    flush n = do
        case min 1000 (n `div` 64) of
            0 -> return 0
            x -> do
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
cacheWriterReact CacheNewBlock    = newBlockC
cacheWriterReact (CacheNewTx txh) = newTxC txh
cacheWriterReact (CacheDelTx txh) = newTxC txh

lenNotNull :: [XPubBal] -> Int
lenNotNull bals = length $ filter (not . nullBalance . xPubBal) bals

newXPubC ::
       (MonadUnliftIO m, MonadLoggerIO m, StoreRead m)
    => XPubSpec
    -> CacheT m ([XPubBal], Bool)
newXPubC xpub =
    withLockWait $ do
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
        runRedis $ do
            b <- redisTouchKeys now [xpub]
            c <- redisAddXPubBalances xpub bals
            d <- redisAddXPubUnspents xpub (map op utxo)
            e <- redisAddXPubTxs xpub xtxs
            return $ b >> c >> d >> e >> return ()

newBlockC :: (MonadUnliftIO m, MonadLoggerIO m, StoreRead m) => CacheT m ()
newBlockC =
    withLockWait $
    lift getBestBlock >>= \case
        Nothing -> $(logErrorS) "Cache" "Best block not set yet"
        Just newhead -> do
            cacheGetHead >>= \case
                Nothing -> do
                    $(logInfoS) "Cache" "Cache has no best block set"
                    importBlockC newhead
                    newBlockC
                Just cachehead -> go newhead cachehead
  where
    go newhead cachehead
        | cachehead == newhead = syncMempoolC
        | otherwise = do
            ch <- asks cacheChain
            chainGetBlock newhead ch >>= \case
                Nothing -> do
                    $(logErrorS) "Cache" $
                        "No header for new head: " <> blockHashToHex newhead
                    throwIO . LogicError . cs $
                        "No header for new head: " <> blockHashToHex newhead
                Just newheadnode ->
                    chainGetBlock cachehead ch >>= \case
                        Nothing -> do
                            $(logErrorS) "Cache" $
                                "No header for cache head: " <>
                                blockHashToHex cachehead
                        Just cacheheadnode -> go2 newheadnode cacheheadnode
    go2 newheadnode cacheheadnode
        | nodeHeight cacheheadnode > nodeHeight newheadnode = do
            $(logErrorS) "Cache" $
                "Cache head is above new best block: " <>
                blockHashToHex (headerHash (nodeHeader newheadnode))
        | otherwise = do
            ch <- asks cacheChain
            split <- chainGetSplitBlock cacheheadnode newheadnode ch
            if split == cacheheadnode
                then if prevBlock (nodeHeader newheadnode) ==
                        headerHash (nodeHeader cacheheadnode)
                         then do
                             importBlockC (headerHash (nodeHeader newheadnode))
                             newBlockC
                         else go3 newheadnode cacheheadnode
                else removeHeadC >> newBlockC
    go3 newheadnode cacheheadnode = do
        ch <- asks cacheChain
        chainGetAncestor (nodeHeight cacheheadnode + 1) newheadnode ch >>= \case
            Nothing -> do
                $(logErrorS) "Cache" $
                    "Could not get expected ancestor block at height " <>
                    cs (show (nodeHeight cacheheadnode + 1)) <>
                    " for: " <>
                    blockHashToHex (headerHash (nodeHeader newheadnode))
                throwIO $ LogicError "Could not get expected ancestor block"
            Just a -> do
                importBlockC (headerHash (nodeHeader a))
                newBlockC

newTxC :: (MonadUnliftIO m, MonadLoggerIO m, StoreRead m) => TxHash -> CacheT m ()
newTxC th =
    withLockWait $
    lift (getTxData th) >>= \case
        Just txd -> do
            $(logDebugS) "Cache" $ "Importing transaction: " <> txHashToHex th
            importMultiTxC [txd]
        Nothing ->
            $(logErrorS) "Cache" $ "Transaction not found: " <> txHashToHex th

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
        $(logInfoS) "Cache" $
            "Importing " <> cs (show (length tds)) <>
            " transactions from block " <>
            blockHashToHex bh
        importMultiTxC tds
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
            $(logWarnS) "Cache" $ "Reverting head: " <> blockHashToHex bh
            importMultiTxC tds
            cacheSetHead (prevBlock (blockDataHeader bd))

importMultiTxC ::
       (MonadUnliftIO m, StoreRead m, MonadLoggerIO m)
    => [TxData]
    -> CacheT m ()
importMultiTxC txs = do
    forM_ (zip [(1 :: Int) ..] txs) $ \(i, tx) ->
        $(logDebugS) "Cache" $
        "Import tx " <> cs (show i) <> "/" <> cs (show (length txs)) <> ": " <>
        txHashToHex (txHash (txData tx))
    addrmap <- getaddrmap
    let addrs = HashMap.keys addrmap
    balmap <- getbalances addrs
    unspentmap <- getunspents
    gap <- getMaxGap
    now <- systemSeconds <$> liftIO getSystemTime
    let xpubs = allxpubs addrmap
    forM_ (zip [(1 :: Int) ..] xpubs) $ \(i, xpub) -> do
        xpubtxt <- xpubText xpub
        $(logDebugS) "Cache" $
            "Affected xpub " <> cs (show i) <> "/" <> cs (show (length xpubs)) <>
            ": " <>
            xpubtxt
    bals <- getxbals xpubs
    let xmap = HashMap.filter (not . null) (HashMap.fromList bals)
        addrs' = getNewAddrs gap xmap (HashMap.elems addrmap)
    runRedis $
        if not (HashMap.null xmap)
            then do
                x <- redisImportMultiTx addrmap unspentmap txs
                y <- redisUpdateBalances addrmap balmap
                z <- redisTouchKeys now xpubs
                return $ x >> y >> z >> return ()
            else return (return ())
    cacheAddAddresses addrs'
  where
    getaddrmap =
        HashMap.fromList . catMaybes . zipWith (\a -> fmap (a, )) alladdrs <$>
        cacheGetAddrsInfo alladdrs
    getunspents =
        HashMap.fromList . catMaybes . zipWith (\p -> fmap (p, )) allops <$>
        lift (mapM getUnspent allops)
    getbalances addrs =
        HashMap.fromList . zipWith (,) addrs <$> mapM (lift . getBalance) addrs
    getxbals xpubs =
        runRedis . fmap sequence . forM xpubs $ \xpub -> do
            bs <- redisGetXPubBalances xpub
            return $ (xpub, ) <$> bs
    allops = map snd $ concatMap txInputs txs <> concatMap txOutputs txs
    alladdrs = nub . map fst $ concatMap txInputs txs <> concatMap txOutputs txs
    allxpubs addrmap = nub . map addressXPubSpec $ HashMap.elems addrmap

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
                y <- redisRemFromMempool (txHash (txData tx))
                return $ sequence x >> y >> return ()
            else do
                a <- sequence <$> mapM (uncurry (addtx tx)) (txaddrops tx)
                b <-
                    case txDataBlock tx of
                        b@MemRef {} ->
                            redisAddToMempool
                                BlockTx
                                    { blockTxHash = txHash (txData tx)
                                    , blockTxBlock = b
                                    }
                        _ -> redisRemFromMempool (txHash (txData tx))
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
cacheAddAddresses [] = return ()
cacheAddAddresses addrs = do
    $(logDebugS) "Cache" $
        "Adding " <> cs (show (length addrs)) <> " new generated addresses"
    balmap <- HashMap.fromListWith (<>) <$> mapM (uncurry getbal) addrs
    utxomap <- HashMap.fromListWith (<>) <$> mapM (uncurry getutxo) addrs
    txmap <- HashMap.fromListWith (<>) <$> mapM (uncurry gettxmap) addrs
    runRedis $ do
        a <- forM (HashMap.toList balmap) (uncurry redisAddXPubBalances)
        b <- forM (HashMap.toList utxomap) (uncurry redisAddXPubUnspents)
        c <- forM (HashMap.toList txmap) (uncurry redisAddXPubTxs)
        return $ sequence a >> sequence b >> sequence c >> return ()
    let xpubs = nub (map addressXPubSpec (Map.elems amap))
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
    nodepool <- map blockTxHash <$> lift getMempool
    cachepool <- map blockTxHash <$> cacheGetMempool
    txs <- catMaybes <$> mapM (lift . getTxData) (nodepool \\ cachepool)
    if null txs
        then $(logDebugS) "Cache" "Cache mempool in sync"
        else do
            $(logDebugS) "Cache" $
                "Importing " <> cs (show (length txs)) <> " mempool transactions"
            importMultiTxC txs

cacheGetMempool :: MonadLoggerIO m => CacheT m [BlockTx]
cacheGetMempool = runRedis redisGetMempool

cacheGetHead :: MonadLoggerIO m => CacheT m (Maybe BlockHash)
cacheGetHead = runRedis redisGetHead

cacheSetHead :: (MonadLoggerIO m, StoreRead m) => BlockHash -> CacheT m ()
cacheSetHead bh = do
    $(logDebugS) "Cache" $ "Cache head set to: " <> blockHashToHex bh
    runRedis (redisSetHead bh) >> return ()

cacheGetAddrsInfo ::
       MonadLoggerIO m => [Address] -> CacheT m [Maybe AddressXPub]
cacheGetAddrsInfo as = runRedis (redisGetAddrsInfo as)

redisAddToMempool :: RedisCtx m f => BlockTx -> m (f Integer)
redisAddToMempool btx =
    zadd
        mempoolSetKey
        [(blockRefScore (blockTxBlock btx), encode (blockTxHash btx))]

redisRemFromMempool :: RedisCtx m f => TxHash -> m (f Integer)
redisRemFromMempool th = zrem mempoolSetKey [encode th]

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

redisRemXPubTxs :: RedisCtx m f => XPubSpec -> [TxHash] -> m (f Integer)
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
        ps = IntMap.toAscList (txDataPrevs td)
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
