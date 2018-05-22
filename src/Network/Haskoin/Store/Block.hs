{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TupleSections              #-}
module Network.Haskoin.Store.Block
    ( blockStore
    , getBestBlock
    , getBlocksAtHeights
    , getBlockAtHeight
    , getBlock
    , getBlocks
    , getUnspent
    , getAddrTxs
    , getAddrsTxs
    , getBalance
    , getBalances
    , getTx
    , getTxs
    , getUnspents
    ) where

import           Control.Applicative
import           Control.Arrow
import           Control.Concurrent.NQE
import           Control.Monad.Catch
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.State.Strict
import qualified Data.ByteString              as BS
import qualified Data.ByteString.Short        as BSS
import           Data.Default
import           Data.List
import           Data.Map                     (Map)
import qualified Data.Map.Strict              as M
import           Data.Maybe
import           Data.Serialize               (encode)
import           Data.Set                     (Set)
import qualified Data.Set                     as S
import           Data.String.Conversions
import           Data.Text                    (Text)
import           Data.Word
import           Database.RocksDB             (DB, Snapshot)
import qualified Database.RocksDB             as RocksDB
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Crypto
import           Network.Haskoin.Node
import           Network.Haskoin.Script
import           Network.Haskoin.Store.Common
import           Network.Haskoin.Store.Types
import           Network.Haskoin.Transaction
import           UnliftIO

data BlockRead = BlockRead
    { myBlockDB    :: !DB
    , mySelf       :: !BlockStore
    , myChain      :: !Chain
    , myManager    :: !Manager
    , myListener   :: !(Listen BlockEvent)
    , myPending    :: !(TVar [BlockHash])
    , myDownloaded :: !(TVar [Block])
    , myPeer       :: !(TVar (Maybe Peer))
    }

type MonadBlock m
     = (MonadThrow m, MonadLoggerIO m, MonadReader BlockRead m)

type PrevOutMap = Map OutPoint PrevOut
type OutputMap = Map OutPoint Output
type AddressMap = Map Address Balance

blockStore ::
       ( MonadUnliftIO m
       , MonadThrow m
       , MonadLoggerIO m
       , MonadMask m
       )
    => BlockConfig
    -> m ()
blockStore BlockConfig {..} = do
    pbox <- liftIO $ newTVarIO []
    dbox <- liftIO $ newTVarIO []
    prb <- liftIO $ newTVarIO Nothing
    runReaderT
        (loadBest >> syncBlocks >> run)
        BlockRead
        { mySelf = blockConfMailbox
        , myBlockDB = blockConfDB
        , myChain = blockConfChain
        , myManager = blockConfManager
        , myListener = blockConfListener
        , myPending = pbox
        , myDownloaded = dbox
        , myPeer = prb
        }
  where
    run = forever (processBlockMessage =<< receive blockConfMailbox)
    loadBest =
        retrieveValue BestBlockKey blockConfDB Nothing >>= \case
            Nothing -> importBlock genesisBlock
            Just _ -> return ()

getBestBlockHash :: MonadIO m => DB -> Maybe Snapshot -> m (Maybe BlockHash)
getBestBlockHash = retrieveValue BestBlockKey

getBestBlock :: MonadIO m => DB -> Maybe Snapshot -> m (Maybe BlockValue)
getBestBlock db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' =
        runMaybeT $ do
            h <- MaybeT (getBestBlockHash db s')
            MaybeT (getBlock h db s')

getBlocksAtHeights ::
    MonadIO m => [BlockHeight] -> DB -> Maybe Snapshot -> m [BlockValue]
getBlocksAtHeights bhs db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' =
        fmap catMaybes . forM (nub bhs) $ \bh ->
            getBlockAtHeight bh db s'

getBlockAtHeight ::
       MonadIO m => BlockHeight -> DB -> Maybe Snapshot -> m (Maybe BlockValue)
getBlockAtHeight height db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' =
        runMaybeT $ do
            h <- MaybeT (retrieveValue (HeightKey height) db s')
            MaybeT (retrieveValue (BlockKey h) db s')

getBlocks :: MonadIO m => [BlockHash] -> DB -> Maybe Snapshot -> m [BlockValue]
getBlocks bids db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' =
        fmap catMaybes . forM (nub bids) $ \bid -> getBlock bid db s'

getBlock ::
       MonadIO m => BlockHash -> DB -> Maybe Snapshot -> m (Maybe BlockValue)
getBlock = retrieveValue . BlockKey

getAddrsSpent ::
       MonadIO m
    => [Address]
    -> DB
    -> Maybe Snapshot
    -> m [(AddrOutputKey, Output)]
getAddrsSpent as db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' = concat <$> mapM (\a -> getAddrSpent a db s') (nub as)

getAddrSpent ::
       MonadIO m
    => Address
    -> DB
    -> Maybe Snapshot
    -> m [(AddrOutputKey, Output)]
getAddrSpent = valuesForKey . MultiAddrOutputKey True

getAddrsUnspent ::
       MonadIO m
    => [Address]
    -> DB
    -> Maybe Snapshot
    -> m [(AddrOutputKey, Output)]
getAddrsUnspent as db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' = concat <$> mapM (\a -> getAddrUnspent a db s') (nub as)

getAddrUnspent ::
       MonadIO m
    => Address
    -> DB
    -> Maybe Snapshot
    -> m [(AddrOutputKey, Output)]
getAddrUnspent = valuesForKey . MultiAddrOutputKey False

getBalances ::
    MonadIO m => [Address] -> DB -> Maybe Snapshot -> m [AddressBalance]
getBalances addrs db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' = forM (nub addrs) $ \a -> getBalance a db s'

getBalance ::
       MonadIO m => Address -> DB -> Maybe Snapshot -> m AddressBalance
getBalance addr db s =
    retrieveValue (BalanceKey addr) db s >>= \case
        Just Balance {..} ->
            return
                AddressBalance
                { addressBalAddress = addr
                , addressBalConfirmed = balanceValue
                , addressBalTxCount = balanceTxCount
                , addressBalUnspentCount =
                      balanceOutputCount - balanceSpentCount
                , addressBalSpentCount = balanceSpentCount
                , addressBalUnconfirmed = balanceUnconfirmed
                }
        Nothing ->
            return
                AddressBalance
                { addressBalAddress = addr
                , addressBalConfirmed = 0
                , addressBalTxCount = 0
                , addressBalUnspentCount = 0
                , addressBalSpentCount = 0
                , addressBalUnconfirmed = 0
                }

getTxs :: MonadIO m => [TxHash] -> DB -> Maybe Snapshot -> m [DetailedTx]
getTxs ths db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' = fmap catMaybes . forM (nub ths) $ \th -> getTx th db s'

getTx ::
       MonadIO m => TxHash -> DB -> Maybe Snapshot -> m (Maybe DetailedTx)
getTx th db s =
    runMaybeT $ do
        xs <- valuesForKey (BaseTxKey th) db s
        TxRecord {..} <- MaybeT (return (findTx xs))
        let os = map (uncurry output) (filterOutputs xs)
            is = map (input txValuePrevOuts) (txIn txValue)
        return
            DetailedTx
            { detailedTxData = txValue
            , detailedTxFee = fee is os
            , detailedTxBlock = txValueBlock
            , detailedTxInputs = is
            , detailedTxOutputs = os
            }
  where
    fee is os =
        if any isCoinbase is
            then 0
            else sum (map detInValue is) - sum (map detOutValue os)
    input prevs TxIn {..} =
        if outPointHash prevOutput == zero
            then DetailedCoinbase
                 { detInOutPoint = prevOutput
                 , detInSequence = txInSequence
                 , detInSigScript = scriptInput
                 }
            else let PrevOut {..} = fromMaybe e (lookup prevOutput prevs)
                 in DetailedInput
                    { detInOutPoint = prevOutput
                    , detInSequence = txInSequence
                    , detInSigScript = scriptInput
                    , detInPkScript = BSS.fromShort prevOutScript
                    , detInValue = prevOutValue
                    , detInBlock = prevOutBlock
                    }
    output OutPoint {..} Output {..} =
        DetailedOutput
        { detOutValue = outputValue
        , detOutScript = outScript
        , detOutSpender = outSpender
        }
    findTx xs =
        listToMaybe
            [ t
            | (k, v) <- xs
            , case k of
                  MultiTxKey {} -> True
                  _             -> False
            , let MultiTx t = v
            ]
    filterOutputs xs =
        [ (p, o)
        | (k, v) <- xs
        , case (k, v) of
              (MultiTxKeyOutput {}, MultiTxOutput {}) -> True
              _                                       -> False
        , let MultiTxKeyOutput (OutputKey p) = k
        , let MultiTxOutput o = v
        ]
    e = error "Colud not locate previous output from transaction record"

getTxRecords ::
       MonadIO m => [TxHash] -> DB -> Maybe Snapshot -> m [Maybe TxRecord]
getTxRecords hs db s = forM hs (\h -> retrieveValue (TxKey h) db s)

getOutPoints :: MonadIO m => [OutPoint] -> DB -> Maybe Snapshot -> m OutputMap
getOutPoints os db s =
    fmap (M.fromList . catMaybes) $
    forM os $ \op -> do
        m <- retrieveValue (OutputKey op) db s
        case m of
            Nothing -> return Nothing
            Just v  -> return $ Just (op, v)

addOutput :: OutPoint -> Output -> OutputMap -> OutputMap
addOutput = M.insert

txOutputMap ::
       MonadIO m => Tx -> Maybe BlockRef -> DB -> Maybe Snapshot -> m OutputMap
txOutputMap tx mb db s = do
    let ops = filter ((== nullOutPoint)) (map prevOutput (txIn tx))
    om <- getOutPoints ops db s
    return $ foldl f om (zip [0 ..] (txOut tx))
  where
    f m (i, o) =
        addOutput
            OutPoint {outPointHash = txHash tx, outPointIndex = i}
            Output
            { outputValue = outValue o
            , outBlock = mb
            , outScript = scriptOutput o
            , outSpender = Nothing
            }
            m

addrBalance :: MonadIO m => Address -> DB -> Maybe Snapshot -> m (Maybe Balance)
addrBalance = retrieveValue . BalanceKey

addrBalances ::
       MonadIO m
    => [Address]
    -> DB
    -> Maybe Snapshot
    -> m AddressMap
addrBalances as db s =
    fmap (M.fromList . catMaybes) . forM as $ \a ->
        addrBalance a db s >>= \case
            Nothing -> return Nothing
            Just b -> return $ Just (a, b)

deleteTransaction ::
       MonadLoggerIO m
    => OutputMap
    -> AddressMap
    -> TxHash
    -> DB
    -> Maybe Snapshot
    -> m (OutputMap, AddressMap, Set OutPoint, Set TxHash)
deleteTransaction om am th db s = execStateT go (om, am, S.empty, S.empty)
  where
    getTx = retrieveValue (TxKey th) db s
    getOutput op = do
        (omap, _, _, _) <- get
        mo <-
            case M.lookup op omap of
                Nothing -> retrieveValue (OutputKey op) db s
                Just o -> return (Just o)
        case mo of
            Nothing -> do
                $(logError) $ "Output not found: " <> logShow op
                error $ "Output not found: " <> show op
            Just o -> return o
    getBalance a = do
        (_, amap, _, _) <- get
        bm <-
            case M.lookup a amap of
                Just b -> return $ Just b
                Nothing -> retrieveValue (BalanceKey a) db s
        case bm of
            Nothing -> do
                $(logError) $ "Balance not found: " <> logShow a
                error $ "Balance not found: " <> show a
            Just b -> return b
    putOutput op o =
        modify $ \(omap, amap, os, ts) -> (M.insert op o omap, amap, os, ts)
    putBalance a b =
        modify $ \(omap, amap, os, ts) -> (omap, M.insert a b amap, os, ts)
    delOutput op =
        modify $ \(omap, amap, os, ts) -> (omap, amap, S.insert op os, ts)
    delTx =
        modify $ \(omap, amap, os, ts) -> (omap, amap, os, S.insert th ts)
    delSpender spender = do
        (omap, amap, os, ts) <- get
        let th = spenderHash spender
        (omap', amap', os', ts') <- deleteTransaction omap amap th db s
        put (omap', amap', os <> os', ts <> ts')
    unspendOutput o = o {outSpender = Nothing}
    unspendBalance conf o b =
        if isJust (outBlock o) && conf
            then b
                 { balanceValue = balanceValue b + outputValue o
                 , balanceSpentCount = balanceSpentCount b - 1
                 }
            else b
                 { balanceUnconfirmed = balanceUnconfirmed b + outputValue o
                 , balanceMempoolTxs = delete th (balanceMempoolTxs b)
                 }
    removeOutput o b =
        case outBlock o of
            Nothing ->
                b
                { balanceUnconfirmed = balanceUnconfirmed b - outputValue o
                , balanceMempoolTxs = delete th (balanceMempoolTxs b)
                }
            Just _ ->
                b
                { balanceValue = balanceValue b - outputValue o
                , balanceOutputCount = balanceOutputCount b - 1
                }
    go =
        getTx >>= \case
            Nothing -> return ()
            Just TxRecord {..} -> do
                let pos =
                        filter (/= nullOutPoint) (map prevOutput (txIn txValue))
                    conf = isJust txValueBlock
                forM_ pos $ \op -> do
                    o <- getOutput op
                    putOutput op (unspendOutput o)
                    case scriptToAddressBS (outScript o) of
                        Nothing -> return ()
                        Just a ->
                            getBalance a >>= putBalance a . unspendBalance conf o
                forM_ (zip [0 ..] (txOut txValue)) $ \(i, to) -> do
                    let op = OutPoint th i
                    o <- getOutput op
                    case outSpender o of
                        Nothing -> return ()
                        Just spender -> delSpender spender
                    case scriptToAddressBS (outScript o) of
                        Nothing -> return ()
                        Just a -> getBalance a >>= putBalance a . removeOutput o
                delTx

blockOutBal ::
       MonadIO m => BlockHash -> DB -> Snapshot -> m (OutputMap, AddressMap)
blockOutBal bh db s = undefined

revertBestBlock :: MonadBlock m => m ()
revertBestBlock = do
    m <-
        runMaybeT $ do
            db <- asks myBlockDB
            best <- MaybeT (getBestBlockHash db Nothing)
            guard (best /= headerHash genesisHeader)
            $(logWarn) $ logMe <> "Reverting block " <> logShow best
            BlockValue {..} <- MaybeT (getBlock best db Nothing)
            txs <-
                mapMaybe (fmap txValue) <$> getTxRecords blockValueTxs db Nothing
            let block = Block blockValueHeader txs
            blockOps <- blockBatchOps block blockValueHeight blockValueWork False
            RocksDB.write db def blockOps
    when (isNothing m) $ do
        $(logError) $ logMe <> "Could not revert best block"
        error "Could not revert best block"

syncBlocks :: MonadBlock m => m ()
syncBlocks = do
    mgr <- asks myManager
    prb <- asks myPeer
    ch <- asks myChain
    _ <- runMaybeT revertUntilKnown
    cb <- chainGetBest ch
    let cbh = headerHash (nodeHeader cb)
    db <- asks myBlockDB
    m <-
        runMaybeT $ do
            mb <- MaybeT (getBestBlockHash db Nothing)
            guard (mb /= cbh) -- Already synced
            pbox <- asks myPending
            dbox <- asks myDownloaded
            (rd, th) <-
                liftIO . atomically $ do
                    pend <- readTVar pbox
                    down <- readTVar dbox
                    let th
                            | not (null pend) = last pend
                            | not (null down) =
                                headerHash (blockHeader (head down))
                                -- Last downloaded is head
                            | otherwise = mb
                        -- Avoid pending & downloaded blocks to be empty
                        rd = length pend + length down < 250
                    return (rd, th)
            -- Last pending/downloaded block is head
            guard (th /= cbh)
            -- Enough pending/dewnloaded blocks to process already
            guard rd
            -- Get a peer to download blocks
            p <-
                liftIO (readTVarIO prb) >>= \case
                    Just p -> return p
                    Nothing -> MaybeT (listToMaybe <$> managerGetPeers mgr)
            -- Set syncing peer
            liftIO (atomically (writeTVar prb (Just p)))
            -- Get my best block data
            bv <- MaybeT (getBlock mb db Nothing)
            -- Get top block (highest in block DB, pending, or downloaded)
            tn <- MaybeT (chainGetBlock th ch)
            -- Get last common block between block DB and chain
            sb <- chainGetSplitBlock cb tn ch
            -- Set best block in DB to last common
            when (nodeHeight sb < blockValueHeight bv) $ do
                -- Do not revert anything if the chain is not synced
                guard =<< chainIsSynced ch
                revertUntil (headerHash (nodeHeader sb))
            -- Download up to 500 blocks
            let h = min (nodeHeight cb) (nodeHeight sb + 500)
            tb <-
                if h == nodeHeight cb
                    then return cb
                    else MaybeT (chainGetAncestor h cb ch)
            -- Request up to target block
            rbs <- (++ [tb]) <$> chainGetParents (nodeHeight sb + 1) tb ch
            downloadBlocks p (map (headerHash . nodeHeader) rbs)
    case m of
        Nothing -> return ()
        Just _  -> return ()
    -- Revert best block until it is found in chain
  where
    revertUntilKnown = do
        ch <- asks myChain
        db <- asks myBlockDB
        y <- chainIsSynced ch
        b <- MaybeT (getBestBlockHash db Nothing)
        chainGetBlock b ch >>= \x ->
            when (isNothing x && y) $ do
                revertBestBlock
                revertUntilKnown
    revertUntil sb = do
        revertBestBlock
        db <- asks myBlockDB
        bb <- MaybeT (getBestBlockHash db Nothing)
        unless (bb == sb) (revertUntil sb)
    downloadBlocks p bhs = do
        peerGetBlocks p bhs
        pbox <- asks myPending
        liftIO (atomically (modifyTVar pbox (++ bhs)))

importBlocks :: MonadBlock m => m ()
importBlocks = do
    dbox <- asks myDownloaded
    m <-
        liftIO . atomically $
        readTVar dbox >>= \case
            [] -> return Nothing
            ds -> do
                writeTVar dbox (init ds)
                return (Just (last ds))
    case m of
        Just b -> do
            importBlock b
            mbox <- asks mySelf
            BlockProcess `send` mbox
        Nothing -> syncBlocks

importBlock :: MonadBlock m => Block -> m ()
importBlock block@Block {..} = do
    ch <- asks myChain
    bn <-
        chainGetBlock (headerHash blockHeader) ch >>= \case
            Just bn -> return bn
            Nothing -> do
                let msg = "Could not obtain block from chain"
                $(logError) $ logMe <> cs msg
                error msg
    ops <- blockBatchOps block (nodeHeight bn) (nodeWork bn) True
    $(logInfo) $
        logMe <> "Importing block " <> logShow (nodeHeight bn) <> " (" <>
        logShow (length ops) <>
        " database write operations)"
    db <- asks myBlockDB
    RocksDB.write db def ops
    l <- asks myListener
    liftIO . atomically . l $ BestBlock (headerHash blockHeader)

-- addrOutputOps :: Bool -> OutPoint -> Output -> [RocksDB.BatchOp]
-- addrOutputOps main op@OutPoint {..} out@Output {..} =
--     if main
--         then let prevDelMaybe = fmap deleteOp maybePrevKey
--                  newInsMaybe = fmap (`insertOp` out) maybeKey
--              in maybeToList prevDelMaybe ++ maybeToList newInsMaybe
--         else let newDelMaybe = fmap deleteOp maybeKey
--                  prevInsMaybe = fmap (`insertOp` unspent) maybePrevKey
--              in maybeToList newDelMaybe ++ maybeToList prevInsMaybe
--   where
--     spentInSameBlock = fromMaybe False $ do
--         spender <- outSpender
--         block <- spenderBlock spender
--         out <- outBlock
--         return (blockRefHash block == blockRefHash out)
--     unspent = out {outSpender = Nothing}
--     maybeKey = do
--         addr <- scriptToAddressBS outScript
--         return
--             AddrOutputKey
--             { addrOutputSpent = isJust outSpender
--             , addrOutputAddress = addr
--             , addrOutputHeight = blockRefHeight <$> outBlock
--             , addrOutPoint = op
--             }
--     maybePrevKey = do
--         addr <- scriptToAddressBS outScript
--         guard (isJust outSpender)
--         guard (not spentInSameBlock)
--         return
--             AddrOutputKey
--             { addrOutputSpent = False
--             , addrOutputAddress = addr
--             , addrOutputHeight = blockRefHeight <$> outBlock
--             , addrOutPoint = op
--             }

-- outputOps :: Bool -> OutPoint -> Output -> RocksDB.BatchOp
-- outputOps main op@OutPoint {..} v@Output {..}
--     | main = insertOp (OutputKey op) v
--     | otherwise =
--         if spentInSameBlock
--             then deleteOp (OutputKey op)
--             else insertOp (OutputKey op) v {outSpender = Nothing}
--   where
--     spentInSameBlock = fromMaybe False $ do
--         spender <- outSpender
--         block <- spenderBlock spender
--         out <- outBlock
--         return (blockRefHash block == blockRefHash out)

-- balanceOps ::
--        MonadBlock m => Bool -> AddressMap -> m [RocksDB.BatchOp]
-- balanceOps main addrMap =
--     fmap concat . forM (M.toList addrMap) $ \(addr, AddressDelta {..}) -> do
--         maybeExisting <- getBalanceData addr
--         let key = BalanceKey {balanceAddress = addr}
--             balance =
--                 case maybeExisting of
--                     Nothing ->
--                         Balance
--                         { balanceValue = addressDeltaBalance
--                         , balanceTxCount = addressDeltaTxCount
--                         , balanceOutputCount = addressDeltaOutputCount
--                         , balanceSpentCount = addressDeltaSpentCount
--                         , balanceUnconfirmed = addressDeltaUnconfirmed
--                         , balanceMempoolTxs = addressDeltaMempool
--                         }
--                     Just Balance {..} ->
--                         Balance
--                         { balanceValue = balanceValue + addressDeltaBalance
--                         , balanceTxCount = balanceTxCount + addressDeltaTxCount
--                         , balanceOutputCount =
--                               balanceOutputCount + addressDeltaOutputCount
--                         , balanceSpentCount =
--                               balanceSpentCount + addressDeltaSpentCount
--                         , balanceUnconfirmed = addressDeltaUnconfirmed
--                         , balanceMempoolTxs = addressDeltaMempool
--                         }
--             maybeOldBalance =
--                 case maybeExisting of
--                     Nothing -> Nothing
--                     Just Balance {..} ->
--                         let oldBalance =
--                                 Balance
--                                 { balanceValue =
--                                       balanceValue - addressDeltaBalance
--                                 , balanceTxCount =
--                                       balanceTxCount - addressDeltaTxCount
--                                 , balanceOutputCount =
--                                       balanceOutputCount -
--                                       addressDeltaOutputCount
--                                 , balanceSpentCount =
--                                       balanceSpentCount - addressDeltaSpentCount
--                                 , balanceUnconfirmed = balanceUnconfirmed
--                                 , balanceMempoolTxs = addressDeltaMempool
--                                 }
--                             zeroBalance =
--                                 Balance
--                                 { balanceValue = 0
--                                 , balanceTxCount = 0
--                                 , balanceOutputCount = 0
--                                 , balanceSpentCount = 0
--                                 , balanceUnconfirmed = balanceUnconfirmed
--                                 , balanceMempoolTxs = addressDeltaMempool
--                                 }
--                             isZero = oldBalance == zeroBalance
--                         in if isZero
--                                then Nothing
--                                else Just oldBalance
--             balOps =
--                 if main
--                     then [insertOp key balance]
--                     else case maybeOldBalance of
--                              Nothing  -> [deleteOp key]
--                              Just old -> [insertOp key old]
--             outputs = M.toList addressDeltaOutput
--             outOps = concatMap (uncurry (addrOutputOps main)) outputs
--         return (balOps ++ outOps)

-- blockOp ::
--        MonadBlock m
--     => Block
--     -> BlockHeight
--     -> BlockWork
--     -> Bool
--     -> BlockData
--     -> m [RocksDB.BatchOp]
-- blockOp block height work main BlockData {..} = do
--     aops <- balanceOps main blockAddrMap
--     return $ concat [[blockHashOp, blockHeightOp, bestOp], txOps, outOps, aops]
--   where
--     header = blockHeader block
--     hash = headerHash header
--     blockRef =
--         BlockRef
--         { blockRefHash = hash
--         , blockRefHeight = height
--         , blockRefMainChain = main
--         , blockRefPos = 0
--         }
--     txs = blockTxns block
--     blockHashOp =
--         let key = BlockKey (headerHash header)
--             value =
--                 BlockValue
--                 { blockValueHeight = height
--                 , blockValueWork = work
--                 , blockValueHeader = header
--                 , blockValueSize = fromIntegral (BS.length (encode block))
--                 , blockValueMainChain = main
--                 , blockValueTxs = map txHash txs
--                 }
--         in insertOp key value
--     blockHeightOp =
--         if main
--             then let key = HeightKey height
--                  in insertOp key (headerHash header)
--             else let key = HeightKey height
--                  in deleteOp key
--     bestOp =
--         if main
--             then insertOp BestBlockKey (headerHash header)
--             else insertOp BestBlockKey (prevBlock header)
--     txOps =
--         if main
--             then let outs =
--                          mapMaybe
--                              (\op -> (op, ) <$> op `M.lookup` blockPrevOutMap)
--                      f pos tx =
--                          insertOp
--                              (TxKey (txHash tx))
--                              TxRecord
--                              { txValueBlock = Just blockRef {blockRefPos = pos}
--                              , txValue = tx
--                              , txValuePrevOuts = outs (map prevOutput (txIn tx))
--                              }
--                  in zipWith f [0 ..] txs
--             else let outs =
--                          mapMaybe
--                              (\op -> (op, ) <$> op `M.lookup` blockPrevOutMap)
--                      f pos tx =
--                          insertOp
--                              (TxKey (txHash tx))
--                              TxRecord
--                              { txValueBlock = Nothing
--                              , txValue = tx
--                              , txValuePrevOuts = outs (map prevOutput (txIn tx))
--                              }
--                  in zipWith f [1 ..] txs
--     outOps = map (uncurry (outputOps main)) (M.toList blockNewOutMap)

-- blockBatchOps ::
--        MonadBlock m
--     => Block
--     -> BlockHeight
--     -> BlockWork
--     -> Bool
--     -> m [RocksDB.BatchOp]
-- blockBatchOps block@Block {..} height work main = do
--     let start =
--             BlockData
--             { blockPrevOutMap = M.empty
--             , blockAddrMap = M.empty
--             , blockNewOutMap = M.empty
--             }
--     bd <- foldM f start (zip [0 ..] blockTxns)
--     blockOp block height work main bd
--   where
--     blockRef =
--         BlockRef
--         { blockRefHash = headerHash blockHeader
--         , blockRefHeight = height
--         , blockRefMainChain = main
--         , blockRefPos = 0
--         }
--     f blockData (pos, tx) = do
--         prevOutMap <- getPrevOutputs tx (blockPrevOutMap blockData)
--         let spentOutMap = getSpentOutputs blockRef {blockRefPos = pos} prevOutMap tx
--             newOutMap = getNewOutputs blockRef {blockRefPos = pos} tx
--             outMap = M.union spentOutMap newOutMap
--             addrMap = getAddrDelta outMap
--             txData =
--                 BlockData
--                 { blockPrevOutMap =
--                       prevOutMap `M.union` M.map outputToPrevOut newOutMap
--                 , blockNewOutMap = outMap
--                 , blockAddrMap = addrMap
--                 }
--         return (blockData <> txData)

-- getAddrDelta :: OutputMap -> AddressMap
-- getAddrDelta outMap =
--     M.fromList (map (id &&& addrDelta) addrs)
--   where
--     addrDelta addr =
--         let xm = fromMaybe M.empty (M.lookup addr addrOutMap)
--             om = M.filter (isNothing . outSpender) xm
--             sm = M.filter (isJust . outSpender) xm
--             ob = sum (map outputValue (M.elems om))
--             sb = sum (map outputValue (M.elems sm))
--         in AddressDelta
--            { addressDeltaOutput = xm
--            , addressDeltaBalance = fromIntegral ob - fromIntegral sb
--            , addressDeltaTxCount = 1
--            , addressDeltaOutputCount = fromIntegral (M.size om)
--            , addressDeltaSpentCount = fromIntegral (M.size sm)
--            , addressDeltaUnconfirmed = 0
--            , addressDeltaMempool = []
--            }
--     addrs = nub (M.keys addrOutMap)
--     addrOutMap =
--         M.fromListWith M.union (mapMaybe (uncurry out) (M.toList outMap))
--     out outpoint output@Output {..} = do
--         address <- scriptToAddressBS outScript
--         return (address, M.singleton outpoint output)

getSpentOutputs :: BlockRef -> PrevOutMap -> Tx -> OutputMap
getSpentOutputs block prevMap tx =
    M.fromList (mapMaybe f (zip [0 ..] (txIn tx)))
  where
    f (i, TxIn {..}) =
        if outPointHash prevOutput == zero
            then Nothing
            else let prev = fromMaybe e (prevOutput `M.lookup` prevMap)
                     spender =
                         Spender
                         { spenderHash = txHash tx
                         , spenderIndex = i
                         , spenderBlock = Just block
                         }
                     unspent = prevOutToOutput prev
                     spent = unspent {outSpender = Just spender}
                 in Just (prevOutput, spent)
    e = error "Could not find expcted previous output"

getNewOutputs :: BlockRef -> Tx -> OutputMap
getNewOutputs block tx = foldl' f M.empty (zip [0 ..] (txOut tx))
  where
    f m (i, TxOut {..}) =
        let key = OutPoint (txHash tx) i
            val =
                Output
                { outputValue = outValue
                , outBlock = Just block
                , outScript = scriptOutput
                , outSpender = Nothing
                }
        in M.insert key val m

getPrevOutputs :: MonadBlock m => Tx -> PrevOutMap -> m PrevOutMap
getPrevOutputs tx prevOutMap = foldM f M.empty (map prevOutput (txIn tx))
  where
    f m outpoint@OutPoint {..} = do
        let key = outpoint
        maybeOutput <-
            if outPointHash == zero
                then return Nothing
                else do
                    maybeOutput <- getOutPointData key prevOutMap
                    case maybeOutput of
                        Just output -> return (Just output)
                        Nothing -> do
                            let msg = "Could not get previous output"
                            $(logError) $ logMe <> cs msg
                            error msg
        case maybeOutput of
            Nothing     -> return m
            Just output -> return (M.insert key output m)

getOutPointData ::
       MonadBlock m
    => OutPoint
    -> PrevOutMap
    -> m (Maybe PrevOut)
getOutPointData key os = runMaybeT (fromMap <|> fromDB)
  where
    fromMap = MaybeT (return (M.lookup key os))
    fromDB = do
        db <- asks myBlockDB
        outputToPrevOut <$> MaybeT (retrieveValue (OutputKey key) db Nothing)

processBlockMessage :: MonadBlock m => BlockMessage -> m ()

processBlockMessage (BlockChainNew _) = syncBlocks

processBlockMessage (BlockPeerConnect _) = syncBlocks

processBlockMessage (BlockReceived p b) = do
    pbox <- asks myPending
    dbox <- asks myDownloaded
    let hash = headerHash (blockHeader b)
    ok <-
        liftIO . atomically $
        readTVar pbox >>= \case
            [] -> return False
            x:xs ->
                if hash == x
                    then do
                        modifyTVar dbox (b :)
                        writeTVar pbox xs
                        return True
                    else return False
    if ok
        then do
            mbox <- asks mySelf
            BlockProcess `send` mbox
        else do
            mgr <- asks myManager
            managerKill (PeerMisbehaving "Peer sent unexpected block") p mgr

processBlockMessage BlockProcess = importBlocks

processBlockMessage (BlockPeerDisconnect p) = do
    prb <- asks myPeer
    pbox <- asks myPending
    liftIO . atomically $
        readTVar prb >>= \x ->
            when (Just p == x) $ do
                writeTVar prb Nothing
                writeTVar pbox []
    mbox <- asks mySelf
    BlockProcess `send` mbox

processBlockMessage (BlockNotReceived p h) = do
    $(logError) $ logMe <> "Block not found: " <> cs (show h)
    mgr <- asks myManager
    managerKill (PeerMisbehaving "Block not found") p mgr

getAddrTxs :: MonadIO m => Address -> DB -> Maybe Snapshot -> m [AddressTx]
getAddrTxs addr = getAddrsTxs [addr]

getAddrsTxs :: MonadIO m => [Address] -> DB -> Maybe Snapshot -> m [AddressTx]
getAddrsTxs addrs db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ g . Just
        Just _  -> g s
  where
    g s' = do
        us <- getAddrsUnspent addrs db s'
        ss <- getAddrsSpent addrs db s'
        let utx =
                [ AddressTxOut
                { addressTxAddress = addrOutputAddress
                , addressTxId = outPointHash addrOutPoint
                , addressTxAmount = fromIntegral outputValue
                , addressTxBlock = outBlock
                , addressTxVout = outPointIndex addrOutPoint
                }
                | (AddrOutputKey {..}, Output {..}) <- us
                ]
            stx =
                [ AddressTxOut
                { addressTxAddress = addrOutputAddress
                , addressTxId = outPointHash addrOutPoint
                , addressTxAmount = fromIntegral outputValue
                , addressTxBlock = outBlock
                , addressTxVout = outPointIndex addrOutPoint
                }
                | (AddrOutputKey {..}, Output {..}) <- ss
                ]
            itx =
                [ AddressTxIn
                { addressTxAddress = addrOutputAddress
                , addressTxId = spenderHash
                , addressTxAmount = -fromIntegral outputValue
                , addressTxBlock = spenderBlock
                , addressTxVin = spenderIndex
                }
                | (AddrOutputKey {..}, Output {..}) <- ss
                , let Spender {..} = fromMaybe e outSpender
                ]
        return $ sort (itx ++ stx ++ utx)
    e = error "Could not get spender from spent output"

getUnspents :: MonadIO m => [Address] -> DB -> Maybe Snapshot -> m [Unspent]
getUnspents addrs db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' = fmap (sort . concat) $ forM addrs $ \addr -> getUnspent addr db s'

getUnspent :: MonadIO m => Address -> DB -> Maybe Snapshot -> m [Unspent]
getUnspent addr db s = do
    xs <- getAddrUnspent addr db s
    return $ map (uncurry toUnspent) xs
  where
    toUnspent AddrOutputKey {..} Output {..} =
        Unspent
        { unspentAddress = Just addrOutputAddress
        , unspentPkScript = outScript
        , unspentTxId = outPointHash addrOutPoint
        , unspentIndex = outPointIndex addrOutPoint
        , unspentValue = outputValue
        , unspentBlock = outBlock
        }

logMe :: Text
logMe = "[Block] "

zero :: TxHash
zero = "0000000000000000000000000000000000000000000000000000000000000000"
