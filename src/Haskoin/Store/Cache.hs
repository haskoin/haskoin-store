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
import           Data.Either               (rights)
import qualified Data.HashMap.Strict       as HashMap
import qualified Data.IntMap.Strict        as IntMap
import           Data.List                 (nub, sort)
import           Data.Map.Strict           (Map)
import qualified Data.Map.Strict           as Map
import           Data.Maybe                (catMaybes, fromJust, mapMaybe)
import           Data.Serialize            (decode, encode)
import           Data.Serialize            (Serialize)
import           Data.String.Conversions   (cs)
import           Data.Time.Clock.System    (getSystemTime, systemSeconds)
import           Data.Word                 (Word32, Word64)
import           Database.Redis            (Connection, Redis, Reply,
                                            checkedConnect, defaultConnectInfo,
                                            hgetall, parseConnectInfo, runRedis,
                                            runRedis, zadd, zrangeWithscores,
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
                                            xPubCompatWitnessAddr,
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
import           UnliftIO                  (Exception, MonadIO, MonadUnliftIO,
                                            liftIO, throwIO)

type RedisReply a = Redis (Either Reply a)

runRedisReply :: MonadIO m => RedisReply a -> CacheT m a
runRedisReply action =
    asks cacheConn >>= \conn ->
        liftIO (runRedis conn action) >>= \case
            Left e -> throwIO (RedisError e)
            Right x -> return x

data CacheConfig =
    CacheConfig
        { cacheConn  :: !Connection
        , cacheGap   :: !Word32
        , cacheMin   :: !Int
        , cacheMax   :: !Integer
        , cacheChain :: !Chain
        }

type CacheT = ReaderT CacheConfig

data CacheError
    = RedisError Reply
    | LogicError String
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

instance (MonadLoggerIO m, StoreRead m) => StoreRead (CacheT m) where
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
    getMaxGap = asks cacheGap

withCache :: StoreRead m => CacheConfig -> CacheT m a -> m a
withCache s f = runReaderT f s

balancesPfx :: ByteString
balancesPfx = "b"

txSetPfx :: ByteString
txSetPfx = "t"

utxoPfx :: ByteString
utxoPfx = "u"

getXPubTxs ::
       (MonadLoggerIO m, StoreRead m)
    => XPubSpec
    -> Maybe BlockRef
    -> Offset
    -> Maybe Limit
    -> CacheT m [BlockTx]
getXPubTxs xpub start offset limit =
    isXPubCached xpub >>= \case
        True -> do
            txs <- cacheGetXPubTxs xpub start offset limit
            $(logDebugS) "Cache" $
                "Cache hit for " <> cs (show (length txs)) <> " xpub txs"
            return txs
        False -> do
            $(logDebugS) "Cache" $ "Cache miss for xpub txs request"
            newXPubC xpub >>= \(bals, t) ->
                if t
                    then cacheGetXPubTxs xpub start offset limit
                    else xPubBalsTxs bals start offset limit

getXPubUnspents ::
       (MonadLoggerIO m, StoreRead m)
    => XPubSpec
    -> Maybe BlockRef
    -> Offset
    -> Maybe Limit
    -> CacheT m [XPubUnspent]
getXPubUnspents xpub start offset limit =
    isXPubCached xpub >>= \case
        True -> do
            bals <- cacheGetXPubBalances xpub
            $(logDebugS) "Cache" $
                "Cache hit for unspents on an xpub with " <>
                cs (show (length bals)) <>
                " balances"
            process bals
        False -> do
            $(logDebugS) "Cache" $ "Cache miss for xpub unspents request"
            newXPubC xpub >>= \(bals, t) ->
                if t
                    then process bals
                    else xPubBalsUnspents bals start offset limit
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
        return xpubutxo

getXPubBalances ::
       (MonadLoggerIO m, StoreRead m)
    => XPubSpec
    -> CacheT m [XPubBal]
getXPubBalances xpub =
    isXPubCached xpub >>= \case
        True -> do
            bals <- cacheGetXPubBalances xpub
            $(logDebugS) "Cache" $
                "Cache hit for " <> cs (show (length bals)) <> " xpub balances"
            return bals
        False -> do
            $(logDebugS) "Cache" "Cache miss for xpub balances request"
            fst <$> newXPubC xpub

isXPubCached :: MonadIO m => XPubSpec -> CacheT m Bool
isXPubCached = runRedisReply . redisIsXPubCached

redisIsXPubCached :: XPubSpec -> RedisReply Bool
redisIsXPubCached xpub = Redis.exists (balancesPfx <> encode xpub)

cacheGetXPubBalances :: MonadIO m => XPubSpec -> CacheT m [XPubBal]
cacheGetXPubBalances xpub = do
    now <- systemSeconds <$> liftIO getSystemTime
    runRedisReply $ do
        bals <- redisGetXPubBalances xpub
        x <-
            case bals of
                Right (_:_) -> touchKeys now [xpub]
                _           -> return (pure 0)
        return $ x >> bals

cacheGetXPubTxs ::
       MonadIO m
    => XPubSpec
    -> Maybe BlockRef
    -> Offset
    -> Maybe Limit
    -> CacheT m [BlockTx]
cacheGetXPubTxs xpub start offset limit = do
    now <- systemSeconds <$> liftIO getSystemTime
    runRedisReply $ do
        txs <- redisGetXPubTxs xpub start offset limit
        x <-
            case txs of
                Right (_:_) -> touchKeys now [xpub]
                _           -> return (pure 0)
        return $ x >> txs

cacheGetXPubUnspents ::
       MonadIO m
    => XPubSpec
    -> Maybe BlockRef
    -> Offset
    -> Maybe Limit
    -> CacheT m [(BlockRef, OutPoint)]
cacheGetXPubUnspents xpub start offset limit = do
    now <- systemSeconds <$> liftIO getSystemTime
    runRedisReply $ do
        x <- touchKeys now [xpub]
        uns <- redisGetXPubUnspents xpub start offset limit
        return $ x >> uns

redisGetXPubBalances :: XPubSpec -> RedisReply [XPubBal]
redisGetXPubBalances xpub =
    getAllFromMap (balancesPfx <> encode xpub) >>=
    return . fmap (sort . map (uncurry f))
  where
    f p b = XPubBal {xPubBalPath = p, xPubBal = b}

redisGetXPubTxs ::
       XPubSpec
    -> Maybe BlockRef
    -> Offset
    -> Maybe Limit
    -> RedisReply [BlockTx]
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
       XPubSpec
    -> Maybe BlockRef
    -> Offset
    -> Maybe Limit
    -> RedisReply [(BlockRef, OutPoint)]
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
       Serialize a
    => ByteString
    -> Maybe Double
    -> Integer
    -> Maybe Integer
    -> RedisReply [(a, Double)]
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

getAllFromMap :: (Serialize k, Serialize v) => ByteString -> RedisReply [(k, v)]
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
cacheWriter cfg inbox =
    runReaderT
        (newBlockC >> forever (pruneDB >> receive inbox >>= cacheWriterReact))
        cfg

pruneDB :: (MonadLoggerIO m, StoreRead m) => CacheT m Integer
pruneDB = do
    x <- asks cacheMax
    s <- runRedisReply Redis.dbsize
    if s > x
        then do
            n <- flush (s - x)
            $(logDebugS) "Cache" $ "Pruned " <> cs (show n) <> " keys"
            return n
        else return 0
  where
    flush n =
        runRedisReply $ do
            let x = min 1000 (n `div` 64)
            eks <- getFromSortedSet maxKey Nothing 0 (Just x)
            case eks of
                Right ks -> do
                    xs <- sequence <$> forM (map fst ks) redisDelXPubKeys
                    return $ xs >>= return . sum
                Left _ -> return $ eks >> return 0

touchKeys :: Real a => a -> [XPubSpec] -> RedisReply Integer
touchKeys _ [] = return (pure 0)
touchKeys now xpubs =
    Redis.zadd maxKey $ map ((realToFrac now, ) . encode) xpubs

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
       (MonadLoggerIO m, StoreRead m)
    => XPubSpec
    -> CacheT m ([XPubBal], Bool)
newXPubC xpub = do
    bals <- lift $ xPubBals xpub
    x <- asks cacheMin
    let n = lenNotNull bals
    if x <= n
        then do
            $(logDebugS) "Cache" $
                "Caching xpub with " <> cs (show n) <> " used addresses"
            go bals
            return (bals, True)
        else do
            $(logDebugS) "Cache" $
                "Not caching xpub with " <> cs (show n) <> " used addresses"
            return (bals, False)
  where
    go bals = do
        utxo <- lift $ xPubUnspents xpub Nothing 0 Nothing
        xtxs <- lift $ xPubTxs xpub Nothing 0 Nothing
        now <- systemSeconds <$> liftIO getSystemTime
        runRedisReply $ do
            x <- redisAddXPubBalances xpub bals
            y <-
                redisAddXPubUnspents
                    xpub
                    (map ((\u -> (unspentPoint u, unspentBlock u)) . xPubUnspent)
                         utxo)
            z <- redisAddXPubTxs xpub xtxs
            a <- touchKeys now [xpub]
            return $ x >> y >> z >> a >> return ()

newBlockC :: (MonadLoggerIO m, StoreRead m) => CacheT m ()
newBlockC =
    lift getBestBlock >>= \case
        Nothing -> $(logErrorS) "Cache" "Best block not set yet"
        Just newhead -> do
            cacheGetHead >>= \case
                Nothing -> do
                    $(logInfoS) "Cache" "Cache has no best block set"
                    importBlockC newhead
                Just cachehead -> go newhead cachehead
  where
    go newhead cachehead
        | cachehead == newhead = return ()
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
                         then importBlockC (headerHash (nodeHeader newheadnode))
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

newTxC :: (MonadLoggerIO m, StoreRead m) => TxHash -> CacheT m ()
newTxC th =
    lift (getTxData th) >>= \case
        Just txd -> importMultiTxC [txd]
        Nothing ->
            $(logErrorS) "Cache" $ "Transaction not found: " <> txHashToHex th

importBlockC :: (StoreRead m, MonadLoggerIO m) => BlockHash -> CacheT m ()
importBlockC bh =
    lift (getBlock bh) >>= \case
        Nothing -> do
            $(logErrorS) "Cache" $ "Could not get block: " <> blockHashToHex bh
            throwIO . LogicError . cs $
                "Could not get block: " <> blockHashToHex bh
        Just bd -> do
            $(logInfoS) "Cache" $ "Importing block: " <> blockHashToHex bh
            go bd
  where
    go bd = do
        let ths = blockDataTxs bd
        tds <- sortTxData . catMaybes <$> mapM (lift . getTxData) ths
        importMultiTxC tds
        cacheSetHead bh

removeHeadC :: (StoreRead m, MonadLoggerIO m) => CacheT m ()
removeHeadC =
    void . runMaybeT $ do
        bh <- MaybeT cacheGetHead
        bd <- MaybeT (lift (getBlock bh))
        lift $ do
            tds <-
                sortTxData . catMaybes <$>
                mapM (lift . getTxData) (blockDataTxs bd)
            $(logWarnS) "Cache" $ "Reverting head: " <> blockHashToHex bh
            forM_ (reverse (map (txHash . txData) tds)) newTxC
            cacheSetHead (prevBlock (blockDataHeader bd))
            syncMempoolC

importMultiTxC :: (StoreRead m, MonadLoggerIO m) => [TxData] -> CacheT m ()
importMultiTxC txs = do
    addrmap <-
        Map.fromList . catMaybes . zipWith (\a -> fmap (a, )) alladdrs <$>
        cacheGetAddrsInfo alladdrs
    balmap <-
        Map.fromList . zipWith (,) alladdrs <$>
        mapM (lift . getBalance) alladdrs
    unspentmap <-
        Map.fromList . catMaybes . zipWith (\p -> fmap (p, )) allops <$>
        lift (mapM getUnspent allops)
    gap <- getMaxGap
    now <- systemSeconds <$> liftIO getSystemTime
    newaddrs <-
        runRedisReply $ do
            x <- redisImportMultiTx addrmap unspentmap txs
            y <- redisUpdateBalances addrmap balmap
            z <- touchKeys now (allxpubs addrmap)
            newaddrs <- redisGetNewAddrs gap addrmap
            return $ x >> y >> z >> newaddrs
    unless (Map.null newaddrs) $ cacheAddAddresses newaddrs
  where
    allops = map snd $ concatMap txInputs txs <> concatMap txOutputs txs
    alladdrs = nub . map fst $ concatMap txInputs txs <> concatMap txOutputs txs
    allxpubs addrmap = nub . map addressXPubSpec $ Map.elems addrmap

redisImportMultiTx ::
       Map Address AddressXPub
    -> Map OutPoint Unspent
    -> [TxData]
    -> RedisReply ()
redisImportMultiTx addrmap unspentmap txs = do
    xs <- mapM importtxentries txs
    return $ sequence xs >> return ()
  where
    uns p i =
        case Map.lookup p unspentmap of
            Just u ->
                redisAddXPubUnspents (addressXPubSpec i) [(p, unspentBlock u)]
            Nothing -> redisRemXPubUnspents (addressXPubSpec i) [p]
    addtx tx a p =
        case Map.lookup a addrmap of
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
        case Map.lookup a addrmap of
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
                tops <- mapM (uncurry (addtx tx)) (txaddrops tx)
                mem <-
                    case txDataBlock tx of
                        b@MemRef {} ->
                            redisAddToMempool
                                BlockTx
                                    { blockTxHash = txHash (txData tx)
                                    , blockTxBlock = b
                                    }
                        _ -> redisRemFromMempool (txHash (txData tx))
                return $ sequence tops >> mem >> return ()
    txaddrops td = spnts td <> utxos td
    spnts td = txInputs td
    utxos td = txOutputs td

redisUpdateBalances ::
       Map Address AddressXPub -> Map Address Balance -> RedisReply ()
redisUpdateBalances addrmap balmap = do
    bs <-
        forM (Map.keys addrmap) $ \a ->
            let ainfo = fromJust (Map.lookup a addrmap)
                bal = fromJust (Map.lookup a balmap)
             in redisAddXPubBalances (addressXPubSpec ainfo) [xpubbal ainfo bal]
    return $ sequence bs >> return ()
  where
    xpubbal ainfo bal =
        XPubBal {xPubBalPath = addressXPubPath ainfo, xPubBal = bal}

cacheAddAddresses ::
       (StoreRead m, MonadLoggerIO m)
    => Map Address AddressXPub
    -> CacheT m ()
cacheAddAddresses addrmap = do
    gap <- getMaxGap
    newmap <- runRedisReply (redisGetNewAddrs gap addrmap)
    balmap <- Map.fromList <$> mapM getbal (Map.keys newmap)
    utxomap <- Map.fromList <$> mapM getutxo (Map.keys newmap)
    txmap <- Map.fromList <$> mapM gettxmap (Map.keys newmap)
    let notnulls = getnotnull newmap balmap
        xpubbals = getxpubbals newmap balmap
        unspents = getunspents newmap utxomap
        txs = gettxs newmap txmap
    newaddrs <-
        runRedisReply $ do
            x' <-
                forM (HashMap.toList xpubbals) $ \(x, bs) ->
                    redisAddXPubBalances x bs
            y' <-
                forM (HashMap.toList unspents) $ \(x, us) ->
                    redisAddXPubUnspents x (map uns us)
            z' <- forM (HashMap.toList txs) $ \(x, ts) -> redisAddXPubTxs x ts
            newaddrs <- redisGetNewAddrs gap notnulls
            return $ do
                _ <- sequence x'
                _ <- sequence y'
                _ <- sequence z'
                newaddrs
    unless (null newaddrs) $ cacheAddAddresses newaddrs
  where
    uns u = (unspentPoint u, unspentBlock u)
    gettxs newmap txmap =
        let f a ts =
                let i = fromJust (Map.lookup a newmap)
                 in (addressXPubSpec i, ts)
            g m (x, ts) = HashMap.insertWith (<>) x ts m
         in foldl g HashMap.empty (map (uncurry f) (Map.toList txmap))
    getunspents newmap utxomap =
        let f a us =
                let i = fromJust (Map.lookup a newmap)
                 in (addressXPubSpec i, us)
            g m (x, us) = HashMap.insertWith (<>) x us m
         in foldl g HashMap.empty (map (uncurry f) (Map.toList utxomap))
    getxpubbals newmap balmap =
        let f a b =
                let i = fromJust (Map.lookup a newmap)
                 in ( addressXPubSpec i
                    , XPubBal {xPubBal = b, xPubBalPath = addressXPubPath i})
            g m (x, b) = HashMap.insertWith (<>) x [b] m
         in foldl g HashMap.empty (map (uncurry f) (Map.toList balmap))
    getnotnull newmap balmap =
        let f a _ =
                let i = fromJust (Map.lookup a newmap)
                 in (a, i)
         in Map.fromList . map (uncurry f) . Map.toList $
            Map.filter (not . nullBalance) balmap
    getbal a = (a, ) <$> lift (getBalance a)
    getutxo a = (a, ) <$> lift (getAddressUnspents a Nothing Nothing)
    gettxmap a = (a, ) <$> lift (getAddressTxs a Nothing Nothing)

redisGetNewAddrs ::
       KeyIndex
    -> Map Address AddressXPub
    -> RedisReply (Map Address AddressXPub)
redisGetNewAddrs gap addrmap =
    xbalmap >>= \xbalmap' ->
        return $ do
            xbmap' <- xbalmap'
            return . Map.fromList $
                concatMap (uncurry newaddrs) (HashMap.toList xbmap')
  where
    xbalmap = do
        xbs <-
            forM xpubs $ \xpub -> do
                bals <- redisGetXPubBalances xpub
                return $ bals >>= return . (xpub, )
        return $ do
            xbs' <- sequence xbs
            return $ HashMap.fromList xbs'
    newaddrs xpub bals =
        let paths = HashMap.lookupDefault [] xpub xpubmap
            ext = maximum . (0 :) . map (head . tail) $ filter ((== 0) . head) paths
            chg = maximum . (0 :) . map (head . tail) $ filter ((== 1) . head) paths
            extnew =
                addrsToAdd
                    bals
                    gap
                    AddressXPub
                        {addressXPubSpec = xpub, addressXPubPath = [0, ext]}
            intnew =
                addrsToAdd
                    bals
                    gap
                    AddressXPub
                        {addressXPubSpec = xpub, addressXPubPath = [1, chg]}
         in extnew <> intnew
    xpubs = HashMap.keys xpubmap
    xpubmap =
        let f xmap ainfo =
                let xpub = addressXPubSpec ainfo
                    path = addressXPubPath ainfo
                 in HashMap.insertWith (<>) xpub [path] xmap
         in foldl f HashMap.empty (Map.elems addrmap)

syncMempoolC :: (MonadLoggerIO m, StoreRead m) => CacheT m ()
syncMempoolC = do
    nodepool <- map blockTxHash <$> lift getMempool
    cachepool <- map blockTxHash <$> cacheGetMempool
    txs <- catMaybes <$> mapM (lift . getTxData) (nodepool <> cachepool)
    importMultiTxC txs

cacheGetMempool :: MonadIO m => CacheT m [BlockTx]
cacheGetMempool = runRedisReply redisGetMempool

cacheGetHead :: MonadIO m => CacheT m (Maybe BlockHash)
cacheGetHead = runRedisReply redisGetHead

cacheSetHead :: MonadIO m => BlockHash -> CacheT m ()
cacheSetHead bh = runRedisReply (redisSetHead bh) >> return ()

cacheGetAddrsInfo ::
       MonadIO m => [Address] -> CacheT m [Maybe AddressXPub]
cacheGetAddrsInfo as = runRedisReply (redisGetAddrsInfo as)

redisAddToMempool :: BlockTx -> Redis (Either Reply Integer)
redisAddToMempool btx =
    zadd
        mempoolSetKey
        [(blockRefScore (blockTxBlock btx), encode (blockTxHash btx))]

redisRemFromMempool :: TxHash -> RedisReply Integer
redisRemFromMempool th = zrem mempoolSetKey [encode th]

redisSetAddrInfo :: Address -> AddressXPub -> RedisReply Redis.Status
redisSetAddrInfo a i = Redis.set (addrPfx <> encode a) (encode i)

redisDelXPubKeys :: XPubSpec -> RedisReply Integer
redisDelXPubKeys xpub = do
    ebals <- redisGetXPubBalances xpub
    case ebals of
        Right bals -> go (map (balanceAddress . xPubBal) bals)
        Left _     -> return $ ebals >> return 0
  where
    go addrs = do
        addrcount <-
            if null addrs
                then return (pure 0)
                else Redis.del (map ((addrPfx <>) . encode) addrs)
        txsetcount <- Redis.del [txSetPfx <> encode xpub]
        utxocount <- Redis.del [utxoPfx <> encode xpub]
        balcount <- Redis.del [balancesPfx <> encode xpub]
        return $ do
            addrs' <- addrcount
            txset' <- txsetcount
            utxo' <- utxocount
            bal' <- balcount
            return $ addrs' + txset' + utxo' + bal'

redisAddXPubTxs :: XPubSpec -> [BlockTx] -> RedisReply Integer
redisAddXPubTxs _ [] = return (Right 0)
redisAddXPubTxs xpub btxs =
    zadd (txSetPfx <> encode xpub) $
    map (\t -> (blockRefScore (blockTxBlock t), encode (blockTxHash t))) btxs

redisRemXPubTxs :: XPubSpec -> [TxHash] -> RedisReply Integer
redisRemXPubTxs xpub txhs = zrem (txSetPfx <> encode xpub) (map encode txhs)

redisAddXPubUnspents :: XPubSpec -> [(OutPoint, BlockRef)] -> RedisReply Integer
redisAddXPubUnspents _ [] = return (Right 0)
redisAddXPubUnspents xpub utxo =
    zadd (utxoPfx <> encode xpub) $
    map (\(p, r) -> (blockRefScore r, encode p)) utxo

redisRemXPubUnspents ::
       XPubSpec -> [OutPoint] -> RedisReply Integer
redisRemXPubUnspents _ []     = return (Right 0)
redisRemXPubUnspents xpub ops = zrem (utxoPfx <> encode xpub) (map encode ops)

redisAddXPubBalances :: XPubSpec -> [XPubBal] -> RedisReply ()
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

redisSetHead :: BlockHash -> RedisReply Redis.Status
redisSetHead bh = Redis.set bestBlockKey (encode bh)

redisGetAddrsInfo ::  [Address] -> RedisReply [Maybe AddressXPub]
redisGetAddrsInfo [] = return (Right [])
redisGetAddrsInfo as = do
    is <- mapM (\a -> Redis.get (addrPfx <> encode a)) as
    return $ do
        is' <- sequence is
        return $ map (eitherToMaybe . decode =<<) is'

addrsToAdd ::
       [XPubBal]
    -> KeyIndex
    -> AddressXPub
    -> [(Address, AddressXPub)]
addrsToAdd xbals gap addrinfo =
    let headi = head (addressXPubPath addrinfo)
        maxi =
            maximum $
            map (head . tail . xPubBalPath) $
            filter ((== headi) . head . xPubBalPath) xbals
        xpub = addressXPubSpec addrinfo
        newi = head (tail (addressXPubPath addrinfo))
        genixs =
            if maxi - newi < gap
                then [maxi + 1 .. newi + gap]
                else []
        paths = map (Deriv :/ headi :/) genixs
        keys = map (\p -> derivePubPath p (xPubSpecKey xpub)) paths
        list = map pathToList paths
        xpubf = xPubAddrFunction (xPubDeriveType xpub)
        addrs = map xpubf keys
     in zipWith
            (\a p ->
                 (a, AddressXPub {addressXPubSpec = xpub, addressXPubPath = p}))
            addrs
            list

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

redisGetHead :: RedisReply (Maybe BlockHash)
redisGetHead = do
    x <- Redis.get bestBlockKey
    return $ (eitherToMaybe . decode =<<) <$> x

redisGetMempool :: RedisReply [BlockTx]
redisGetMempool = do
    xs <- getFromSortedSet mempoolSetKey Nothing 0 Nothing
    return $ do
        ys <- xs
        return $ map (uncurry f) ys
  where
    f t s = BlockTx {blockTxBlock = scoreBlockRef s, blockTxHash = t}
