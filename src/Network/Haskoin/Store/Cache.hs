{-# LANGUAGE DeriveAnyClass       #-}
{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE TupleSections        #-}
{-# LANGUAGE TypeSynonymInstances #-}
module Network.Haskoin.Store.Cache where

import           Control.DeepSeq                  (NFData)
import           Control.Monad                    (forM_, forever, unless, void,
                                                   when)
import           Control.Monad.Reader             (ReaderT (..), asks)
import           Control.Monad.Trans              (lift)
import           Control.Monad.Trans.Maybe        (MaybeT (..), runMaybeT)
import           Data.Bits                        (shift, (.&.), (.|.))
import           Data.ByteString                  (ByteString)
import           Data.Either                      (rights)
import qualified Data.IntMap.Strict               as IntMap
import           Data.List                        (nub, partition, (\\))
import qualified Data.Map.Strict                  as Map
import           Data.Maybe                       (catMaybes, mapMaybe)
import           Data.Serialize                   (Serialize, decode, encode)
import           Data.Word                        (Word64)
import           Database.Redis                   (Connection, RedisCtx, Reply,
                                                   runRedis, zadd,
                                                   zrangeWithscores,
                                                   zrangebyscoreWithscoresLimit,
                                                   zrem)
import qualified Database.Redis                   as Redis
import           GHC.Generics                     (Generic)
import           Haskoin                          (Address, BlockHash,
                                                   BlockHeader (..),
                                                   BlockNode (..),
                                                   DerivPathI (..), KeyIndex,
                                                   OutPoint (..), Tx (..),
                                                   TxHash, TxIn (..),
                                                   TxOut (..), derivePubPath,
                                                   headerHash, pathToList,
                                                   scriptToAddressBS, txHash)
import           Haskoin.Node                     (Chain, chainGetAncestor,
                                                   chainGetBlock,
                                                   chainGetSplitBlock)
import           Network.Haskoin.Store.Common     (BlockData (..),
                                                   BlockRef (..), BlockTx (..),
                                                   Cache, CacheMessage (..),
                                                   Limit, Offset, Prev (..),
                                                   StoreEvent (..),
                                                   StoreRead (..), TxData (..),
                                                   Unspent (..), XPubBal (..),
                                                   XPubSpec (..),
                                                   XPubUnspent (..), cacheXPub,
                                                   sortTxs, xPubAddrFunction,
                                                   xPubBals, xPubTxs,
                                                   xPubUnspents)
import           Network.Haskoin.Store.Data.Cache
import           NQE                              (Inbox, receive)
import           UnliftIO                         (Exception, MonadIO,
                                                   MonadUnliftIO, liftIO,
                                                   throwIO)
-----------
-- Actor --
-----------

type CacheInbox = Inbox CacheMessage

data CacheConf =
    CacheConf
        { cacheConfState :: !CacheState
        , cacheConfChain :: !Chain
        , cacheConfInbox :: !CacheInbox
        }

type CacheActorT = ReaderT CacheConf

instance (MonadIO m, StoreRead m) => StoreRead (CacheActorT m) where
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
    xPubBals = runInCacheT . xPubBals
    xPubSummary = runInCacheT . xPubSummary
    xPubUnspents xpub start offset limit =
        runInCacheT (xPubUnspents xpub start offset limit)
    xPubTxs xpub start offset limit =
        runInCacheT (xPubTxs xpub start offset limit)

runInCacheT :: CacheT m a -> CacheActorT m a
runInCacheT f = ReaderT (runReaderT f . cacheConfState)

cacheActor :: (MonadUnliftIO m, StoreRead m) => CacheConf -> m ()
cacheActor cfg@CacheConf {cacheConfInbox = inbox} =
    runReaderT (forever (receive inbox >>= react)) cfg

react :: (MonadUnliftIO m, StoreRead m) => CacheMessage -> CacheActorT m ()
react CacheNewBlock    = newBlock
react (CacheXPub xpub) = newXPub xpub
react (CacheNewTx txh) = newTx txh
react (CacheDelTx txh) = removeTx txh

newXPub ::
       (MonadUnliftIO m, StoreRead m)
    => XPubSpec
    -> CacheActorT m ()
newXPub xpub = do
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

newBlock :: (MonadIO m, StoreRead m) => CacheActorT m ()
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
            ch <- asks cacheConfChain
            chainGetBlock newhead ch >>= \case
                Nothing -> return ()
                Just newheadnode ->
                    chainGetBlock cachehead ch >>= \case
                        Nothing -> return ()
                        Just cacheheadnode -> go2 newheadnode cacheheadnode
    go2 newheadnode cacheheadnode
        | nodeHeight cacheheadnode > nodeHeight newheadnode = return ()
        | otherwise = do
            ch <- asks cacheConfChain
            split <- chainGetSplitBlock cacheheadnode newheadnode ch
            if split == cacheheadnode
                then if prevBlock (nodeHeader newheadnode) ==
                        headerHash (nodeHeader cacheheadnode)
                         then importBlock (headerHash (nodeHeader newheadnode))
                         else go3 newheadnode cacheheadnode
                else removeHead >> newBlock
    go3 newheadnode cacheheadnode = do
        ch <- asks cacheConfChain
        ma <- chainGetAncestor (nodeHeight cacheheadnode + 1) newheadnode ch
        case ma of
            Nothing -> do
                throwIO (LogicError "Could not get expected ancestor block")
            Just a -> do
                importBlock (headerHash (nodeHeader a))
                newBlock

newTx :: (MonadIO m, StoreRead m) => TxHash -> CacheActorT m ()
newTx th =
    lift (getTxData th) >>= \case
        Just txd -> importTx txd
        Nothing -> return ()

removeTx :: (MonadIO m, StoreRead m) => TxHash -> CacheActorT m ()
removeTx th =
    lift (getTxData th) >>= \case
        Just txd -> deleteTx txd
        Nothing -> return ()

---------------
-- Importing --
---------------

importBlock :: (StoreRead m, MonadIO m) => BlockHash -> CacheActorT m ()
importBlock bh =
    lift (getBlock bh) >>= \case
        Nothing -> return ()
        Just bd -> go bd
  where
    go bd = do
        let ths = blockDataTxs bd
        tds <- sortTxData . catMaybes <$> mapM (lift . getTxData) ths
        forM_ tds importTx

removeHead :: (StoreRead m, MonadIO m) => CacheActorT m ()
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

importTx :: (StoreRead m, MonadIO m) => TxData -> CacheActorT m ()
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

deleteTx :: (StoreRead m, MonadIO m) => TxData -> CacheActorT m ()
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
       (StoreRead m, MonadIO m) => [Address] -> CacheActorT m ()
updateAddresses as = do
    is <- mapM cacheGetAddrInfo as
    let ais = catMaybes (zipWith (\a i -> (a, ) <$> i) as is)
    forM_ (catMaybes is) $ \i -> updateAddrGap i
    let as' = as \\ map fst ais
    when (length as /= length as') (updateAddresses as')

updateAddrGap ::
       (StoreRead m, MonadIO m)
    => AddressXPub
    -> CacheActorT m ()
updateAddrGap i = do
    current <- cacheGetXPubIndex (addressXPubSpec i) change
    gap <- asks (cacheStateGap . cacheConfState)
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
       (StoreRead m, MonadIO m) => Address -> AddressXPub -> CacheActorT m ()
updateBalance a i = do
    cacheSetAddrInfo a i
    b <- lift (getBalance a)
    cacheAddXPubBalances
        (addressXPubSpec i)
        [XPubBal {xPubBalPath = addressXPubPath i, xPubBal = b}]

syncMempool :: (MonadIO m, StoreRead m) => CacheActorT m ()
syncMempool = do
    nodepool <- map blockTxHash <$> lift getMempool
    cachepool <- map blockTxHash <$> cacheGetMempool
    let deltxs = cachepool \\ nodepool
    deltds <- reverse . sortTxData . catMaybes <$> mapM (lift . getTxData) deltxs
    forM_ deltds deleteTx
    let addtxs = nodepool \\ cachepool
    addtds <- sortTxData . catMaybes <$> mapM (lift . getTxData) addtxs
    forM_ addtds importTx

cacheAddXPubTxs :: MonadIO m => XPubSpec -> [BlockTx] -> CacheActorT m ()
cacheAddXPubTxs xpub txs = do
    conn <- asks (cacheStateConn . cacheConfState)
    liftIO (runRedis conn (redisAddXPubTxs xpub txs)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheRemXPubTxs :: MonadIO m => XPubSpec -> [TxHash] -> CacheActorT m ()
cacheRemXPubTxs xpub ths = do
    conn <- asks (cacheStateConn . cacheConfState)
    liftIO (runRedis conn (redisRemXPubTxs xpub ths)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheAddXPubUnspents ::
       MonadIO m => XPubSpec -> [(OutPoint, BlockRef)] -> CacheActorT m ()
cacheAddXPubUnspents xpub ops = do
    conn <- asks (cacheStateConn . cacheConfState)
    liftIO (runRedis conn (redisAddXPubUnspents xpub ops)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheRemXPubUnspents :: MonadIO m => XPubSpec -> [OutPoint] -> CacheActorT m ()
cacheRemXPubUnspents xpub ops = do
    conn <- asks (cacheStateConn . cacheConfState)
    liftIO (runRedis conn (redisRemXPubUnspents xpub ops)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheAddXPubBalances :: MonadIO m => XPubSpec -> [XPubBal] -> CacheActorT m ()
cacheAddXPubBalances xpub bals = do
    conn <- asks (cacheStateConn . cacheConfState)
    liftIO (runRedis conn (redisAddXPubBalances xpub bals)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheGetXPubIndex :: MonadIO m => XPubSpec -> Bool -> CacheActorT m KeyIndex
cacheGetXPubIndex xpub change = do
    conn <- asks (cacheStateConn . cacheConfState)
    liftIO (runRedis conn (redisGetXPubIndex xpub change)) >>= \case
        Left e -> throwIO (RedisError e)
        Right x -> return x

cacheSetXPubIndex ::
       MonadIO m => XPubSpec -> Bool -> KeyIndex -> CacheActorT m ()
cacheSetXPubIndex xpub change index = do
    conn <- asks (cacheStateConn . cacheConfState)
    liftIO (runRedis conn (redisSetXPubIndex xpub change index)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheGetMempool :: MonadIO m => CacheActorT m [BlockTx]
cacheGetMempool = do
    conn <- asks (cacheStateConn . cacheConfState)
    liftIO (runRedis conn redisGetMempool) >>= \case
        Left e -> do
            throwIO (RedisError e)
        Right mem -> return mem

cacheGetHead :: MonadIO m => CacheActorT m (Maybe BlockHash)
cacheGetHead = do
    conn <- asks (cacheStateConn . cacheConfState)
    liftIO (runRedis conn redisGetHead) >>= \case
        Left e ->
            throwIO (RedisError e)
        Right h -> return h

cacheSetHead :: MonadIO m => BlockHash -> CacheActorT m ()
cacheSetHead bh = do
    conn <- asks (cacheStateConn . cacheConfState)
    liftIO (runRedis conn (redisSetHead bh)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheAddToMempool :: MonadIO m => BlockTx -> CacheActorT m ()
cacheAddToMempool btx = do
    conn <- asks (cacheStateConn . cacheConfState)
    liftIO (runRedis conn (redisAddToMempool btx)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheRemFromMempool :: MonadIO m => TxHash -> CacheActorT m ()
cacheRemFromMempool th = do
    conn <- asks (cacheStateConn . cacheConfState)
    liftIO (runRedis conn (redisRemFromMempool th)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheGetAddrInfo :: MonadIO m => Address -> CacheActorT m (Maybe AddressXPub)
cacheGetAddrInfo a = do
    conn <- asks (cacheStateConn . cacheConfState)
    liftIO (runRedis conn (redisGetAddrInfo a)) >>= \case
        Left e -> throwIO (RedisError e)
        Right i -> return i

cacheSetAddrInfo :: MonadIO m => Address -> AddressXPub -> CacheActorT m ()
cacheSetAddrInfo a i = do
    conn <- asks (cacheStateConn . cacheConfState)
    liftIO (runRedis conn (redisSetAddrInfo a i)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

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

redisSetAddrInfo ::
       (Monad f, RedisCtx m f) => Address -> AddressXPub -> m (f ())
redisSetAddrInfo a i = do
    f <- Redis.set (addrPfx <> encode a) (encode i)
    return $ f >> return ()

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

redisSetXPubIndex :: (Monad f, RedisCtx m f) => XPubSpec -> Bool -> KeyIndex -> m (f ())
redisSetXPubIndex xpub change index = do
    f <- Redis.set (pfx <> encode xpub) (encode index)
    return $ f >> return ()
  where
    pfx =
        if change
            then chgIndexPfx
            else extIndexPfx

redisSetHead :: (Monad m, Monad f, RedisCtx m f) => BlockHash -> m (f ())
redisSetHead bh = do
    f <- Redis.set bestBlockKey (encode bh)
    return $ f >> return ()

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
