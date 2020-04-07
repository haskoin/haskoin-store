{-# LANGUAGE DeriveAnyClass       #-}
{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE TupleSections        #-}
{-# LANGUAGE TypeSynonymInstances #-}
module Network.Haskoin.Store.Data.Cache where

import           Control.DeepSeq              (NFData)
import           Control.Monad                (forM_, unless, void, when)
import           Control.Monad.Reader         (ReaderT (..), asks)
import           Control.Monad.Trans          (lift)
import           Control.Monad.Trans.Maybe    (MaybeT (..), runMaybeT)
import           Data.Bits                    (shift, (.&.), (.|.))
import           Data.ByteString              (ByteString)
import           Data.Either                  (rights)
import qualified Data.IntMap.Strict           as IntMap
import           Data.List                    (nub, partition, (\\))
import qualified Data.Map.Strict              as Map
import           Data.Maybe                   (catMaybes, mapMaybe)
import           Data.Serialize               (Serialize, decode, encode)
import           Data.Word                    (Word64)
import           Database.Redis               (Connection, RedisCtx, Reply,
                                               runRedis, zadd, zrangeWithscores,
                                               zrangebyscoreWithscoresLimit,
                                               zrem)
import qualified Database.Redis               as Redis
import           GHC.Generics                 (Generic)
import           Haskoin                      (Address, BlockHash,
                                               BlockHeader (..), BlockNode (..),
                                               DerivPathI (..), KeyIndex,
                                               OutPoint (..), Tx (..), TxHash,
                                               TxIn (..), TxOut (..),
                                               derivePubPath, headerHash,
                                               pathToList, scriptToAddressBS,
                                               txHash)
import           Haskoin.Node                 (Chain, chainGetAncestor,
                                               chainGetBlock,
                                               chainGetSplitBlock)
import           Network.Haskoin.Store.Common (BlockData (..), BlockRef (..),
                                               BlockTx (..), Limit, Offset,
                                               Prev (..), StoreEvent (..),
                                               StoreRead (..), TxData (..),
                                               Unspent (..), XPubBal (..),
                                               XPubSpec (..), XPubUnspent (..),
                                               sortTxs, xPubAddrFunction,
                                               xPubBals, xPubTxs, xPubUnspents)
import           UnliftIO                     (Exception, MonadIO,
                                               MonadUnliftIO, liftIO, throwIO)

----------
-- Data --
----------

data AddressXPub =
    AddressXPub
        { addressXPubSpec :: !XPubSpec
        , addressXPubPath :: ![KeyIndex]
        } deriving (Show, Eq, Generic, NFData, Serialize)

data CacheState =
    CacheState
        { cacheStateConn  :: !Connection
        , cacheStateGap   :: !KeyIndex
        , cacheStateChain :: !Chain
        }

type CacheT = ReaderT CacheState

data CacheError
    = RedisError Reply
    | LogicError String
    deriving (Show, Eq, Generic, NFData, Exception)

-- Version of the cache database
cacheVerKey :: ByteString
cacheVerKey = "version"

cacheVerCurrent :: ByteString
cacheVerCurrent = "1"

-- External max index
extIndexPfx :: ByteString
extIndexPfx = "e"

-- Change max index
chgIndexPfx :: ByteString
chgIndexPfx = "c"

-- Ordered set of transaction ids in mempool
mempoolSetKey :: ByteString
mempoolSetKey = "mempool"

-- Best block indexed
bestBlockKey :: ByteString
bestBlockKey = "head"

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


-----------
-- Actor --
-----------

react ::
       ( MonadUnliftIO m
       , StoreRead m
       )
    => StoreEvent
    -> CacheT m ()
react (StoreBestBlock _)    = newBlock
react (StoreMempoolNew txh) = newTx txh
react (StoreTxDeleted txh)  = removeTx txh
react _                     = return ()

-------------
-- Queries --
-------------

getXPubTxs ::
       (MonadUnliftIO m, StoreRead m)
    => XPubSpec
    -> Maybe BlockRef
    -> Offset
    -> Maybe Limit
    -> CacheT m [BlockTx]
getXPubTxs xpub start offset limit = do
    addXPub xpub
    cacheGetXPubTxs xpub start offset limit

getXPubUnspents ::
       (MonadUnliftIO m, StoreRead m)
    => XPubSpec
    -> Maybe BlockRef
    -> Offset
    -> Maybe Limit
    -> CacheT m [(BlockRef, OutPoint)]
getXPubUnspents xpub start offset limit = do
    addXPub xpub
    cacheGetXPubUnspents xpub start offset limit

getXPubBalances ::
       (MonadUnliftIO m, StoreRead m)
    => XPubSpec
    -> CacheT m [XPubBal]
getXPubBalances xpub = do
    addXPub xpub
    cacheGetXPubBalances xpub

----------------
-- High level --
----------------

syncMempool :: (MonadIO m, StoreRead m) => CacheT m ()
syncMempool = do
    nodepool <- map blockTxHash <$> lift getMempool
    cachepool <- map blockTxHash <$> cacheGetMempool
    let deltxs = cachepool \\ nodepool
    deltds <- reverse . sortTxData . catMaybes <$> mapM (lift . getTxData) deltxs
    forM_ deltds deleteTx
    let addtxs = nodepool \\ cachepool
    addtds <- sortTxData . catMaybes <$> mapM (lift . getTxData) addtxs
    forM_ addtds importTx

addXPub ::
       (MonadUnliftIO m, StoreRead m)
    => XPubSpec
    -> CacheT m ()
addXPub xpub = do
    present <- (> 0) <$> cacheGetXPubIndex xpub False
    unless present $ do
        bals <- lift $ xPubBals xpub
        unless (null bals) $ go bals
  where
    go bals = do
        utxo <- xPubUnspents xpub Nothing 0 Nothing
        xtxs <- xPubTxs xpub Nothing 0 Nothing
        let (external, change) =
                partition (\b -> head (xPubBalPath b) == 0) bals
            extindex =
                case external of
                    [] -> 0
                    _  -> last (xPubBalPath (last external))
            chgindex =
                case change of
                    [] -> 0
                    _  -> last (xPubBalPath (last change))
        cacheAddXPubBalances xpub bals
        cacheAddXPubUnspents
            xpub
            (map ((\u -> (unspentPoint u, unspentBlock u)) . xPubUnspent) utxo)
        cacheAddXPubTxs xpub xtxs
        cacheSetXPubIndex xpub False extindex
        cacheSetXPubIndex xpub True chgindex

newBlock :: (MonadIO m, StoreRead m) => CacheT m ()
newBlock =
    lift getBestBlock >>= \case
        Nothing -> return ()
        Just newhead ->
            cacheGetHead >>= \case
                Nothing -> importBlock newhead
                Just cachehead -> go newhead cachehead
  where
    go newhead cachehead
        | cachehead == newhead = return ()
        | otherwise = do
            ch <- asks cacheStateChain
            chainGetBlock newhead ch >>= \case
                Nothing -> return ()
                Just newheadnode ->
                    chainGetBlock cachehead ch >>= \case
                        Nothing -> return ()
                        Just cacheheadnode -> go2 newheadnode cacheheadnode
    go2 newheadnode cacheheadnode
        | nodeHeight cacheheadnode > nodeHeight newheadnode = return ()
        | otherwise = do
            ch <- asks cacheStateChain
            split <- chainGetSplitBlock cacheheadnode newheadnode ch
            if split == cacheheadnode
                then if prevBlock (nodeHeader newheadnode) ==
                        headerHash (nodeHeader cacheheadnode)
                         then importBlock (headerHash (nodeHeader newheadnode))
                         else go3 newheadnode cacheheadnode
                else removeHead >> newBlock
    go3 newheadnode cacheheadnode = do
        ch <- asks cacheStateChain
        ma <- chainGetAncestor (nodeHeight cacheheadnode + 1) newheadnode ch
        case ma of
            Nothing -> do
                throwIO (LogicError "Could not get expected ancestor block")
            Just a -> do
                importBlock (headerHash (nodeHeader a))
                newBlock

newTx :: (MonadIO m, StoreRead m) => TxHash -> CacheT m ()
newTx th =
    lift (getTxData th) >>= \case
        Just txd -> importTx txd
        Nothing -> return ()

removeTx :: (MonadIO m, StoreRead m) => TxHash -> CacheT m ()
removeTx th =
    lift (getTxData th) >>= \case
        Just txd -> deleteTx txd
        Nothing -> return ()

---------------
-- Low level --
---------------

txXPubAddrs :: Monad m => Tx -> m [(Address, AddressXPub)]
txXPubAddrs _txh = undefined

updateXPub :: Monad m => Address -> AddressXPub -> m ()
updateXPub _xa = undefined

addBlock :: Monad m => BlockHash -> m ()
addBlock _mh = undefined

blocksToRemove :: Monad m => BlockHash -> m [BlockHash]
blocksToRemove _bh = undefined

blocksToAdd :: Monad m => BlockHash -> m [BlockHash]
blocksToAdd _bh = undefined

cachedMempoolTxs :: Monad m => m [TxHash]
cachedMempoolTxs = undefined

----------------
-- Data Store --
----------------

cacheGetHead :: MonadIO m => CacheT m (Maybe BlockHash)
cacheGetHead = do
    conn <- asks cacheStateConn
    liftIO (runRedis conn redisGetHead) >>= \case
        Left e ->
            throwIO (RedisError e)
        Right h -> return h

cacheSetHead :: MonadIO m => BlockHash -> CacheT m ()
cacheSetHead bh = do
    conn <- asks cacheStateConn
    liftIO (runRedis conn (redisSetHead bh)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheGetMempool :: MonadIO m => CacheT m [BlockTx]
cacheGetMempool = do
    conn <- asks cacheStateConn
    liftIO (runRedis conn redisGetMempool) >>= \case
        Left e -> do
            throwIO (RedisError e)
        Right mem -> return mem

cacheAddToMempool :: MonadIO m => BlockTx -> CacheT m ()
cacheAddToMempool btx = do
    conn <- asks cacheStateConn
    liftIO (runRedis conn (redisAddToMempool btx)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheRemFromMempool :: MonadIO m => TxHash -> CacheT m ()
cacheRemFromMempool th = do
    conn <- asks cacheStateConn
    liftIO (runRedis conn (redisRemFromMempool th)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheGetAddrInfo :: MonadIO m => Address -> CacheT m (Maybe AddressXPub)
cacheGetAddrInfo a = do
    conn <- asks cacheStateConn
    liftIO (runRedis conn (redisGetAddrInfo a)) >>= \case
        Left e -> throwIO (RedisError e)
        Right i -> return i

cacheSetAddrInfo :: MonadIO m => Address -> AddressXPub -> CacheT m ()
cacheSetAddrInfo a i = do
    conn <- asks cacheStateConn
    liftIO (runRedis conn (redisSetAddrInfo a i)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheGetXPubBalances :: MonadIO m => XPubSpec -> CacheT m [XPubBal]
cacheGetXPubBalances xpub = do
    conn <- asks cacheStateConn
    liftIO (runRedis conn (redisGetXPubBalances xpub)) >>= \case
        Left e -> throwIO (RedisError e)
        Right bals -> return bals

cacheGetXPubTxs ::
       MonadIO m
    => XPubSpec
    -> Maybe BlockRef
    -> Offset
    -> Maybe Limit
    -> CacheT m [BlockTx]
cacheGetXPubTxs xpub start offset limit = do
    conn <- asks cacheStateConn
    liftIO (runRedis conn (redisGetXPubTxs xpub start offset limit)) >>= \case
        Left e -> throwIO (RedisError e)
        Right bts -> return bts

cacheGetXPubUnspents ::
       MonadIO m
    => XPubSpec
    -> Maybe BlockRef
    -> Offset
    -> Maybe Limit
    -> CacheT m [(BlockRef, OutPoint)]
cacheGetXPubUnspents xpub start offset limit = do
    conn <- asks cacheStateConn
    liftIO (runRedis conn (redisGetXPubUnspents xpub start offset limit)) >>= \case
        Left e -> throwIO (RedisError e)
        Right ops -> return ops

cacheAddXPubTxs :: MonadIO m => XPubSpec -> [BlockTx] -> CacheT m ()
cacheAddXPubTxs xpub txs = do
    conn <- asks cacheStateConn
    liftIO (runRedis conn (redisAddXPubTxs xpub txs)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheRemXPubTxs :: MonadIO m => XPubSpec -> [TxHash] -> CacheT m ()
cacheRemXPubTxs xpub ths = do
    conn <- asks cacheStateConn
    liftIO (runRedis conn (redisRemXPubTxs xpub ths)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheAddXPubUnspents ::
       MonadIO m => XPubSpec -> [(OutPoint, BlockRef)] -> CacheT m ()
cacheAddXPubUnspents xpub ops = do
    conn <- asks cacheStateConn
    liftIO (runRedis conn (redisAddXPubUnspents xpub ops)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheRemXPubUnspents :: MonadIO m => XPubSpec -> [OutPoint] -> CacheT m ()
cacheRemXPubUnspents xpub ops = do
    conn <- asks cacheStateConn
    liftIO (runRedis conn (redisRemXPubUnspents xpub ops)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheAddXPubBalances :: MonadIO m => XPubSpec -> [XPubBal] -> CacheT m ()
cacheAddXPubBalances xpub bals = do
    conn <- asks cacheStateConn
    liftIO (runRedis conn (redisAddXPubBalances xpub bals)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheGetXPubIndex :: MonadIO m => XPubSpec -> Bool -> CacheT m KeyIndex
cacheGetXPubIndex xpub change = do
    conn <- asks cacheStateConn
    liftIO (runRedis conn (redisGetXPubIndex xpub change)) >>= \case
        Left e -> throwIO (RedisError e)
        Right x -> return x

cacheSetXPubIndex ::
       MonadIO m => XPubSpec -> Bool -> KeyIndex -> CacheT m ()
cacheSetXPubIndex xpub change index = do
    conn <- asks cacheStateConn
    liftIO (runRedis conn (redisSetXPubIndex xpub change index)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

---------------
-- Importing --
---------------

importBlock :: (StoreRead m, MonadIO m) => BlockHash -> CacheT m ()
importBlock bh =
    lift (getBlock bh) >>= \case
        Nothing -> return ()
        Just bd -> go bd
  where
    go bd = do
        let ths = blockDataTxs bd
        tds <- sortTxData . catMaybes <$> mapM (lift . getTxData) ths
        forM_ tds importTx

removeHead :: (StoreRead m, MonadIO m) => CacheT m ()
removeHead =
    void . runMaybeT $ do
        bh <- MaybeT cacheGetHead
        bd <- MaybeT (lift (getBlock bh))
        lift $ do
            tds <-
                sortTxData . catMaybes <$>
                mapM (lift . getTxData) (blockDataTxs bd)
            forM_ (reverse (map (txHash . txData) tds)) removeTx
            cacheSetHead (prevBlock (blockDataHeader bd))
            syncMempool

importTx :: (StoreRead m, MonadIO m) => TxData -> CacheT m ()
importTx txd = do
    updateAddresses addrs
    is <- mapM cacheGetAddrInfo addrs
    let aim = Map.fromList (catMaybes (zipWith (\a i -> (a, ) <$> i) addrs is))
        dus = mapMaybe (\(a, p) -> (, p) <$> Map.lookup a aim) spnts
        ius = mapMaybe (\(a, p) -> (, p) <$> Map.lookup a aim) utxos
    forM_ aim $ \i -> do
        cacheAddXPubTxs
            (addressXPubSpec i)
            [ BlockTx
                  { blockTxHash = txHash (txData txd)
                  , blockTxBlock = txDataBlock txd
                  }
            ]
    forM_ dus $ \(i, p) -> do cacheRemXPubUnspents (addressXPubSpec i) [p]
    forM_ ius $ \(i, p) ->
        cacheAddXPubUnspents (addressXPubSpec i) [(p, txDataBlock txd)]
    case txDataBlock txd of
        b@MemRef {} ->
            cacheAddToMempool
                BlockTx {blockTxHash = txHash (txData txd), blockTxBlock = b}
        _ -> cacheRemFromMempool (txHash (txData txd))
  where
    spnts = txSpent txd
    utxos = txUnspent txd
    addrs = nub (map fst spnts <> map fst utxos)

deleteTx :: (StoreRead m, MonadIO m) => TxData -> CacheT m ()
deleteTx txd = do
    updateAddresses addrs
    is <- mapM cacheGetAddrInfo addrs
    let aim = Map.fromList (catMaybes (zipWith (\a i -> (a, ) <$> i) addrs is))
        dus = mapMaybe (\(a, p) -> (, p) <$> Map.lookup a aim) spnts
        ius = mapMaybe (\(a, p) -> (, p) <$> Map.lookup a aim) utxos
    forM_ aim $ \i -> do
        cacheRemXPubTxs (addressXPubSpec i) [txHash (txData txd)]
    forM_ dus $ \(i, p) ->
        lift (getUnspent p) >>= \case
            Just u -> do
                cacheAddXPubUnspents (addressXPubSpec i) [(p, unspentBlock u)]
            Nothing -> return ()
    forM_ ius $ \(i, p) -> cacheRemXPubUnspents (addressXPubSpec i) [p]
    case txDataBlock txd of
        MemRef {} -> cacheRemFromMempool (txHash (txData txd))
        _         -> return ()
  where
    spnts = txSpent txd
    utxos = txUnspent txd
    addrs = nub (map fst spnts <> map fst utxos)

updateAddresses ::
       (StoreRead m, MonadIO m) => [Address] -> CacheT m ()
updateAddresses as = do
    is <- mapM cacheGetAddrInfo as
    let ais = catMaybes (zipWith (\a i -> (a, ) <$> i) as is)
    forM_ (catMaybes is) $ \i -> updateAddrGap i
    let as' = as \\ map fst ais
    when (length as /= length as') (updateAddresses as')

updateAddrGap ::
       (StoreRead m, MonadIO m)
    => AddressXPub
    -> CacheT m ()
updateAddrGap i = do
    current <- cacheGetXPubIndex (addressXPubSpec i) change
    gap <- asks cacheStateGap
    let ns = addrsToAdd (addressXPubSpec i) change current new gap
    forM_ ns (uncurry updateBalance)
    case ns of
        [] -> return ()
        _ ->
            cacheSetXPubIndex
                (addressXPubSpec i)
                change
                (last (addressXPubPath (snd (last ns))))
  where
    change =
        case head (addressXPubPath i) of
            1 -> True
            0 -> False
            _ -> undefined
    new = last (addressXPubPath i)

updateBalance ::
       (StoreRead m, MonadIO m) => Address -> AddressXPub -> CacheT m ()
updateBalance a i = do
    cacheSetAddrInfo a i
    b <- lift (getBalance a)
    cacheAddXPubBalances
        (addressXPubSpec i)
        [XPubBal {xPubBalPath = addressXPubPath i, xPubBal = b}]

-----------
-- Redis --
-----------

redisGetHead :: (Monad m, Monad f, RedisCtx m f) => m (f (Maybe BlockHash))
redisGetHead = do
    f <- Redis.get bestBlockKey
    return $ do
        mbs <- f
        case mbs of
            Nothing -> return Nothing
            Just bs ->
                case decode bs of
                    Left e  -> error e
                    Right h -> return h

redisSetHead :: (Monad m, Monad f, RedisCtx m f) => BlockHash -> m (f ())
redisSetHead bh = do
    f <- Redis.set bestBlockKey (encode bh)
    return $ f >> return ()

redisGetMempool :: (Monad m, Monad f, RedisCtx m f) => m (f [BlockTx])
redisGetMempool = do
    f <- getFromSortedSet mempoolSetKey Nothing 0 Nothing
    return $ do
        bts <- f
        return
            (map (\(t, s) ->
                      BlockTx {blockTxBlock = scoreBlockRef s, blockTxHash = t})
                 bts)

redisAddToMempool :: (Monad m, Monad f, RedisCtx m f) => BlockTx -> m (f ())
redisAddToMempool btx = do
    f <-
        zadd
            mempoolSetKey
            [(blockRefScore (blockTxBlock btx), encode (blockTxHash btx))]
    return $ f >> return ()

redisRemFromMempool :: (Monad m, Monad f, RedisCtx m f) => TxHash -> m (f ())
redisRemFromMempool th = do
    f <- zrem mempoolSetKey [encode th]
    return $ f >> return ()

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

redisSetAddrInfo ::
       (Monad f, RedisCtx m f) => Address -> AddressXPub -> m (f ())
redisSetAddrInfo a i = do
    f <- Redis.set (addrPfx <> encode a) (encode i)
    return $ f >> return ()

redisGetXPubBalances :: (Monad f, RedisCtx m f) => XPubSpec -> m (f [XPubBal])
redisGetXPubBalances xpub = do
    xs <- getFromSortedSet (balancesPfx <> encode xpub) Nothing 0 Nothing
    return $ do
        xs' <- xs
        return (map (uncurry f) xs')
  where
    f b s = XPubBal {xPubBalPath = scorePath s, xPubBal = b}

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

redisAddXPubTxs :: (Monad f, RedisCtx m f) => XPubSpec -> [BlockTx] -> m (f ())
redisAddXPubTxs xpub btxs = do
    let entries =
            map
                (\t -> (blockRefScore (blockTxBlock t), encode (blockTxHash t)))
                btxs
    f <- zadd (txSetPfx <> encode xpub) entries
    return $ f >> return ()

redisRemXPubTxs :: (Monad f, RedisCtx m f) => XPubSpec -> [TxHash] -> m (f ())
redisRemXPubTxs xpub txhs = do
    f <- zrem (txSetPfx <> encode xpub) (map encode txhs)
    return $ f >> return ()

redisAddXPubUnspents ::
       (Monad f, RedisCtx m f) => XPubSpec -> [(OutPoint, BlockRef)] -> m (f ())
redisAddXPubUnspents xpub utxo = do
    let entries = map (\(p, r) -> (blockRefScore r, encode p)) utxo
    f <- zadd (utxoPfx <> encode xpub) entries
    return $ f >> return ()

redisRemXPubUnspents ::
       (Monad f, RedisCtx m f) => XPubSpec -> [OutPoint] -> m (f ())
redisRemXPubUnspents xpub ops = do
    f <- zrem (txSetPfx <> encode xpub) (map encode ops)
    return $ f >> return ()

redisAddXPubBalances ::
       (Monad f, RedisCtx m f) => XPubSpec -> [XPubBal] -> m (f ())
redisAddXPubBalances xpub bals = do
    let entries =
            map (\b -> (pathScore (xPubBalPath b), encode (xPubBal b))) bals
    f <- zadd (balancesPfx <> encode xpub) entries
    return $ f >> return ()

redisGetXPubIndex :: (Monad f, RedisCtx m f) => XPubSpec -> Bool -> m (f KeyIndex)
redisGetXPubIndex xpub change = do
    f <- Redis.get (pfx <> encode xpub)
    return $ f >>= \case
        Nothing -> return 0
        Just x -> case decode x of
            Left e  -> error e
            Right n -> return n
  where
    pfx =
        if change
            then chgIndexPfx
            else extIndexPfx

redisSetXPubIndex :: (Monad f, RedisCtx m f) => XPubSpec -> Bool -> KeyIndex -> m (f ())
redisSetXPubIndex xpub change index = do
    f <- Redis.set (pfx <> encode xpub) (encode index)
    return $ f >> return ()
  where
    pfx =
        if change
            then chgIndexPfx
            else extIndexPfx

----------------------
-- Helper Functions --
----------------------

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

pathScore :: [KeyIndex] -> Double
pathScore [m, n]
    | m == 0 || m == 1 = fromIntegral (toInteger n .|. toInteger m `shift` 32)
    | otherwise = undefined
pathScore _ = undefined

scorePath :: Double -> [KeyIndex]
scorePath s
    | s < 0 = undefined
    | s > 0x01ffffffff = undefined
    | otherwise =
        [ fromInteger (round s `shift` (-32))
        , fromInteger (round s .&. 0xffffffff)
        ]

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

txSpent :: TxData -> [(Address, OutPoint)]
txSpent td =
    let is = txIn (txData td)
        ps = IntMap.toAscList (txDataPrevs td)
        as = map (scriptToAddressBS . prevScript . snd) ps
        f (Right a) i = Just (a, prevOutput i)
        f (Left _) _  = Nothing
     in catMaybes (zipWith f as is)

txUnspent :: TxData -> [(Address, OutPoint)]
txUnspent td =
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

addrsToAdd ::
       XPubSpec
    -> Bool
    -> KeyIndex
    -> KeyIndex
    -> KeyIndex
    -> [(Address, AddressXPub)]
addrsToAdd xpub change current new gap
    | new <= current = []
    | otherwise =
        let top = new + gap
            indices = [current + 1 .. top]
            paths =
                map
                    (Deriv :/
                     (if change
                          then 1
                          else 0) :/)
                    indices
            keys = map (\p -> derivePubPath p (xPubSpecKey xpub)) paths
            list = map pathToList paths
            xpubf = xPubAddrFunction (xPubDeriveType xpub)
            addrs = map xpubf keys
         in zipWith
                (\a p ->
                     ( a
                     , AddressXPub {addressXPubSpec = xpub, addressXPubPath = p}))
                addrs
                list

sortTxData :: [TxData] -> [TxData]
sortTxData tds =
    let txm = Map.fromList (map (\d -> (txHash (txData d), d)) tds)
        ths = map (txHash . snd) (sortTxs (map txData tds))
     in mapMaybe (\h -> Map.lookup h txm) ths

instance (MonadIO m, StoreRead m) => StoreRead (CacheT m) where
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
    getMempool = cacheGetMempool
    xPubBals = undefined
    xPubSummary = lift . xPubSummary
    xPubUnspents = undefined
    xPubTxs = undefined
