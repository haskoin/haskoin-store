{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections     #-}
module Network.Haskoin.Store.CacheWriter where

import           Control.Monad                          (forM, forM_, forever,
                                                         void, when)
import           Control.Monad.Logger                   (MonadLoggerIO,
                                                         logErrorS, logInfoS,
                                                         logWarnS)
import           Control.Monad.Reader                   (ReaderT (..), asks)
import           Control.Monad.Trans                    (lift)
import           Control.Monad.Trans.Maybe              (MaybeT (..), runMaybeT)
import           Data.ByteString                        (ByteString)
import qualified Data.IntMap.Strict                     as IntMap
import           Data.List                              (nub, (\\))
import qualified Data.Map.Strict                        as Map
import           Data.Maybe                             (catMaybes, mapMaybe)
import           Data.Serialize                         (decode, encode)
import           Data.String.Conversions                (cs)
import           Database.Redis                         (RedisCtx, hmset,
                                                         runRedis, zadd, zrem)
import qualified Database.Redis                         as Redis
import           Haskoin                                (Address, BlockHash,
                                                         BlockHeader (..),
                                                         BlockNode (..),
                                                         DerivPathI (..),
                                                         KeyIndex, Network,
                                                         OutPoint (..), Tx (..),
                                                         TxHash, TxIn (..),
                                                         TxOut (..),
                                                         blockHashToHex,
                                                         derivePubPath,
                                                         eitherToMaybe,
                                                         headerHash, pathToList,
                                                         scriptToAddressBS,
                                                         txHash, txHashToHex)
import           Haskoin.Node                           (Chain,
                                                         chainGetAncestor,
                                                         chainGetBlock,
                                                         chainGetSplitBlock)
import           Network.Haskoin.Store.Common           (Balance (..),
                                                         BlockData (..),
                                                         BlockRef (..),
                                                         BlockTx (..),
                                                         CacheWriterMessage (..),
                                                         Prev (..),
                                                         StoreRead (..),
                                                         TxData (..),
                                                         Unspent (..),
                                                         XPubBal (..),
                                                         XPubSpec (..),
                                                         XPubUnspent (..),
                                                         sortTxs,
                                                         xPubAddrFunction,
                                                         xPubBals, xPubTxs,
                                                         xPubUnspents)
import           Network.Haskoin.Store.Data.CacheReader (AddressXPub (..),
                                                         CacheError (..),
                                                         CacheReaderConfig (..),
                                                         CacheReaderT, addrPfx,
                                                         balancesPfx,
                                                         blockRefScore,
                                                         cacheGetXPubBalances,
                                                         getFromSortedSet,
                                                         redisGetAddrInfo,
                                                         scoreBlockRef,
                                                         txSetPfx, utxoPfx,
                                                         withCacheReader)
import           NQE                                    (Inbox, receive)
import           UnliftIO                               (MonadIO, MonadUnliftIO,
                                                         liftIO, throwIO)
type CacheWriterInbox = Inbox CacheWriterMessage

data CacheWriterConfig =
    CacheWriterConfig
        { cacheWriterReader  :: !CacheReaderConfig
        , cacheWriterChain   :: !Chain
        , cacheWriterMailbox :: !CacheWriterInbox
        , cacheWriterNetwork :: !Network
        }

type CacheWriterT = ReaderT CacheWriterConfig

instance (MonadLoggerIO m, StoreRead m) => StoreRead (CacheWriterT m) where
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
    xPubBals = runCacheReaderT . xPubBals
    xPubSummary = runCacheReaderT . xPubSummary
    xPubUnspents xpub start offset limit =
        runCacheReaderT (xPubUnspents xpub start offset limit)
    xPubTxs xpub start offset limit =
        runCacheReaderT (xPubTxs xpub start offset limit)
    getMaxGap = asks (cacheReaderGap . cacheWriterReader)

-- Ordered set of transaction ids in mempool
mempoolSetKey :: ByteString
mempoolSetKey = "mempool"

-- Best block indexed
bestBlockKey :: ByteString
bestBlockKey = "head"

runCacheReaderT :: StoreRead m => CacheReaderT m a -> CacheWriterT m a
runCacheReaderT f =
    ReaderT (\CacheWriterConfig {cacheWriterReader = r} -> withCacheReader r f)

cacheWriter ::
       (MonadUnliftIO m, MonadLoggerIO m, StoreRead m)
    => CacheWriterConfig
    -> m ()
cacheWriter cfg@CacheWriterConfig {cacheWriterMailbox = inbox} =
    runReaderT (newBlockC >> forever (receive inbox >>= cacheWriterReact)) cfg

cacheWriterReact ::
       (MonadUnliftIO m, MonadLoggerIO m, StoreRead m)
    => CacheWriterMessage
    -> CacheWriterT m ()
cacheWriterReact CacheNewBlock    = newBlockC
cacheWriterReact (CacheXPub xpub) = newXPubC xpub
cacheWriterReact (CacheNewTx txh) = newTxC txh
cacheWriterReact (CacheDelTx txh) = removeTxC txh

newXPubC ::
       (MonadLoggerIO m, MonadUnliftIO m, StoreRead m)
    => XPubSpec
    -> CacheWriterT m ()
newXPubC xpub = do
    empty <- null <$> runCacheReaderT (cacheGetXPubBalances xpub)
    when empty $ do
        bals <- lift $ xPubBals xpub
        go bals
  where
    go bals = do
        utxo <- lift $ xPubUnspents xpub Nothing 0 Nothing
        xtxs <- lift $ xPubTxs xpub Nothing 0 Nothing
        cacheAddXPubBalances xpub bals
        cacheAddXPubUnspents
            xpub
            (map ((\u -> (unspentPoint u, unspentBlock u)) . xPubUnspent) utxo)
        cacheAddXPubTxs xpub xtxs

newBlockC :: (MonadLoggerIO m, StoreRead m) => CacheWriterT m ()
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
            ch <- asks cacheWriterChain
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
                            error . cs $
                                "No header for cache head: " <>
                                blockHashToHex cachehead
                        Just cacheheadnode -> go2 newheadnode cacheheadnode
    go2 newheadnode cacheheadnode
        | nodeHeight cacheheadnode > nodeHeight newheadnode = do
            $(logErrorS) "Cache" $
                "Cache head is above new best block: " <>
                blockHashToHex (headerHash (nodeHeader newheadnode))
            throwIO . LogicError . cs $
                "Cache head is above new best block: " <>
                blockHashToHex (headerHash (nodeHeader newheadnode))
        | otherwise = do
            ch <- asks cacheWriterChain
            split <- chainGetSplitBlock cacheheadnode newheadnode ch
            if split == cacheheadnode
                then if prevBlock (nodeHeader newheadnode) ==
                        headerHash (nodeHeader cacheheadnode)
                         then importBlockC (headerHash (nodeHeader newheadnode))
                         else go3 newheadnode cacheheadnode
                else removeHeadC >> newBlockC
    go3 newheadnode cacheheadnode = do
        ch <- asks cacheWriterChain
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

newTxC :: (MonadLoggerIO m, StoreRead m) => TxHash -> CacheWriterT m ()
newTxC th =
    lift (getTxData th) >>= \case
        Just txd -> importTxC txd
        Nothing ->
            $(logErrorS) "Cache" $ "Transaction not found: " <> txHashToHex th

removeTxC :: (MonadLoggerIO m, StoreRead m) => TxHash -> CacheWriterT m ()
removeTxC th =
    lift (getTxData th) >>= \case
        Just txd -> deleteTxC txd
        Nothing ->
            $(logWarnS) "Cache" $ "Transaction not found: " <> txHashToHex th

---------------
-- Importing --
---------------

importBlockC :: (StoreRead m, MonadLoggerIO m) => BlockHash -> CacheWriterT m ()
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
        forM_ tds importTxC
        cacheSetHead bh

removeHeadC :: (StoreRead m, MonadLoggerIO m) => CacheWriterT m ()
removeHeadC =
    void . runMaybeT $ do
        bh <- MaybeT cacheGetHead
        bd <- MaybeT (lift (getBlock bh))
        lift $ do
            tds <-
                sortTxData . catMaybes <$>
                mapM (lift . getTxData) (blockDataTxs bd)
            $(logWarnS) "Cache" $ "Reverting head: " <> blockHashToHex bh
            forM_ (reverse (map (txHash . txData) tds)) removeTxC
            cacheSetHead (prevBlock (blockDataHeader bd))
            syncMempoolC

importTxC :: (StoreRead m, MonadLoggerIO m) => TxData -> CacheWriterT m ()
importTxC txd = do
    updateAddressesC addrs
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

deleteTxC :: (StoreRead m, MonadLoggerIO m) => TxData -> CacheWriterT m ()
deleteTxC txd = do
    $(logWarnS) "Cache" $
        "Deleting transaction: " <> txHashToHex (txHash (txData txd))
    updateAddressesC addrs
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

updateAddressesC ::
       (StoreRead m, MonadLoggerIO m) => [Address] -> CacheWriterT m ()
updateAddressesC as = do
    is <- mapM cacheGetAddrInfo as
    let ais = catMaybes (zipWith (\a i -> (a, ) <$> i) as is)
    forM_ ais $ \(a, i) -> do
        updateBalanceC a i
        updateAddressGapC i
    let as' = as \\ map fst ais
    when (length as /= length as') (updateAddressesC as')

updateAddressGapC ::
       (StoreRead m, MonadLoggerIO m)
    => AddressXPub
    -> CacheWriterT m ()
updateAddressGapC i = do
    bals <- runCacheReaderT (cacheGetXPubBalances (addressXPubSpec i))
    gap <- getMaxGap
    let ns = addrsToAddC gap i bals
    mapM_ (uncurry updateBalanceC) ns

updateBalanceC ::
       (StoreRead m, MonadLoggerIO m)
    => Address
    -> AddressXPub
    -> CacheWriterT m ()
updateBalanceC a i = do
    b <- lift (getBalance a)
    cacheAddXPubBalances
        (addressXPubSpec i)
        [XPubBal {xPubBalPath = addressXPubPath i, xPubBal = b}]

syncMempoolC :: (MonadLoggerIO m, StoreRead m) => CacheWriterT m ()
syncMempoolC = do
    nodepool <- map blockTxHash <$> lift getMempool
    cachepool <- map blockTxHash <$> cacheGetMempool
    let deltxs = cachepool \\ nodepool
    deltds <- reverse . sortTxData . catMaybes <$> mapM (lift . getTxData) deltxs
    forM_ deltds deleteTxC
    let addtxs = nodepool \\ cachepool
    addtds <- sortTxData . catMaybes <$> mapM (lift . getTxData) addtxs
    forM_ addtds importTxC

cacheAddXPubTxs :: MonadIO m => XPubSpec -> [BlockTx] -> CacheWriterT m ()
cacheAddXPubTxs xpub txs = do
    conn <- asks (cacheReaderConn . cacheWriterReader)
    liftIO (runRedis conn (redisAddXPubTxs xpub txs)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheRemXPubTxs :: MonadIO m => XPubSpec -> [TxHash] -> CacheWriterT m ()
cacheRemXPubTxs xpub ths = do
    conn <- asks (cacheReaderConn . cacheWriterReader)
    liftIO (runRedis conn (redisRemXPubTxs xpub ths)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheAddXPubUnspents ::
       MonadIO m => XPubSpec -> [(OutPoint, BlockRef)] -> CacheWriterT m ()
cacheAddXPubUnspents xpub ops = do
    conn <- asks (cacheReaderConn . cacheWriterReader)
    liftIO (runRedis conn (redisAddXPubUnspents xpub ops)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheRemXPubUnspents :: MonadIO m => XPubSpec -> [OutPoint] -> CacheWriterT m ()
cacheRemXPubUnspents xpub ops = do
    conn <- asks (cacheReaderConn . cacheWriterReader)
    liftIO (runRedis conn (redisRemXPubUnspents xpub ops)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheAddXPubBalances :: MonadIO m => XPubSpec -> [XPubBal] -> CacheWriterT m ()
cacheAddXPubBalances xpub bals = do
    conn <- asks (cacheReaderConn . cacheWriterReader)
    liftIO (runRedis conn (redisAddXPubBalances xpub bals)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheGetMempool :: MonadIO m => CacheWriterT m [BlockTx]
cacheGetMempool = do
    conn <- asks (cacheReaderConn . cacheWriterReader)
    liftIO (runRedis conn redisGetMempool) >>= \case
        Left e -> do
            throwIO (RedisError e)
        Right mem -> return mem

cacheGetHead :: MonadIO m => CacheWriterT m (Maybe BlockHash)
cacheGetHead = do
    conn <- asks (cacheReaderConn . cacheWriterReader)
    liftIO (runRedis conn redisGetHead) >>= \case
        Left e ->
            throwIO (RedisError e)
        Right h -> return h

cacheSetHead :: MonadIO m => BlockHash -> CacheWriterT m ()
cacheSetHead bh = do
    conn <- asks (cacheReaderConn . cacheWriterReader)
    liftIO (runRedis conn (redisSetHead bh)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheAddToMempool :: MonadIO m => BlockTx -> CacheWriterT m ()
cacheAddToMempool btx = do
    conn <- asks (cacheReaderConn . cacheWriterReader)
    liftIO (runRedis conn (redisAddToMempool btx)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheRemFromMempool :: MonadIO m => TxHash -> CacheWriterT m ()
cacheRemFromMempool th = do
    conn <- asks (cacheReaderConn . cacheWriterReader)
    liftIO (runRedis conn (redisRemFromMempool th)) >>= \case
        Left e -> throwIO (RedisError e)
        Right () -> return ()

cacheGetAddrInfo :: MonadIO m => Address -> CacheWriterT m (Maybe AddressXPub)
cacheGetAddrInfo a = do
    conn <- asks (cacheReaderConn . cacheWriterReader)
    liftIO (runRedis conn (redisGetAddrInfo a)) >>= \case
        Left e -> throwIO (RedisError e)
        Right i -> return i

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
    if null entries
        then return (return ())
        else do
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
    if null entries
        then return (return ())
        else do
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
            map (\b -> (encode (xPubBalPath b), encode (xPubBal b))) bals
    if null entries
        then return (return ())
        else do
            f <- hmset (balancesPfx <> encode xpub) entries
            gs <-
                forM bals $ \b ->
                    redisSetAddrInfo
                        (balanceAddress (xPubBal b))
                        AddressXPub
                            { addressXPubSpec = xpub
                            , addressXPubPath = xPubBalPath b
                            }
            return $ f >> sequence gs >> return ()

redisSetHead :: (Monad m, Monad f, RedisCtx m f) => BlockHash -> m (f ())
redisSetHead bh = do
    f <- Redis.set bestBlockKey (encode bh)
    return $ f >> return ()

addrsToAddC ::
       KeyIndex
    -> AddressXPub
    -> [XPubBal]
    -> [(Address, AddressXPub)]
addrsToAddC gap i bals =
    let headi = head (addressXPubPath i)
        maxi =
            maximum $
            map (head . tail . xPubBalPath) $
            filter ((== headi) . head . xPubBalPath) bals
        xpub = addressXPubSpec i
        newi = head (tail (addressXPubPath i))
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

redisGetHead :: (Monad m, Monad f, RedisCtx m f) => m (f (Maybe BlockHash))
redisGetHead = do
    f <- Redis.get bestBlockKey
    return $ (eitherToMaybe . decode =<<) <$> f

redisGetMempool :: (Monad m, Monad f, RedisCtx m f) => m (f [BlockTx])
redisGetMempool = do
    f <- getFromSortedSet mempoolSetKey Nothing 0 Nothing
    return $ do
        bts <- f
        return
            (map (\(t, s) ->
                      BlockTx {blockTxBlock = scoreBlockRef s, blockTxHash = t})
                 bts)
