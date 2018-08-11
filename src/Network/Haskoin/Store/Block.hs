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
import           Control.Monad.Trans.Maybe
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

data TxStatus
    = TxValid
    | TxOrphan
    | TxLowFunds
    | TxInputSpent
    deriving (Eq, Show, Ord)

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
                , addressBalUnconfirmed = balanceUnconfirmed
                , addressOutputCount = balanceOutputCount
                , addressSpentCount = balanceSpentCount
                }
        Nothing ->
            return
                AddressBalance
                { addressBalAddress = addr
                , addressBalConfirmed = 0
                , addressBalUnconfirmed = 0
                , addressOutputCount = 0
                , addressSpentCount = 0
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

getOutPoints :: MonadIO m => OutputMap -> [OutPoint] -> DB -> Maybe Snapshot -> m OutputMap
getOutPoints om os db s = foldM f om os
  where
    f om' op =
        g om' op >>= \case
            Nothing -> return om'
            Just o -> return $ M.insert op o om'
    g om' op =
        case M.lookup op om' of
            Nothing -> retrieveValue (OutputKey op) db s
            Just o  -> return (Just o)

txOutputMap ::
       MonadIO m => OutputMap -> Tx -> Maybe BlockRef -> DB -> Maybe Snapshot -> m OutputMap
txOutputMap om tx mb db s = do
    let is = filter (/= nullOutPoint) (map prevOutput (txIn tx))
    om' <- getOutPoints om is db s
    return $ foldl f om' (zip [0..] (txOut tx))
  where
    f om' (i, o) =
        M.insert
            OutPoint {outPointHash = txHash tx, outPointIndex = i}
            Output
            { outputValue = outValue o
            , outBlock = mb
            , outScript = scriptOutput o
            , outSpender = Nothing
            }
            om'

addrBalance :: MonadIO m => Address -> DB -> Maybe Snapshot -> m (Maybe Balance)
addrBalance = retrieveValue . BalanceKey

addrBalances ::
       MonadIO m
    => Set Address
    -> DB
    -> Maybe Snapshot
    -> m AddressMap
addrBalances as db s =
    fmap (M.fromList . catMaybes) . forM (S.toList as) $ \a ->
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
    -> m (OutputMap, AddressMap, Set TxHash)
    -- ^ updated maps and sets of transactions to delete
deleteTransaction om am th db s = execStateT go (om, am, S.empty)
  where
    getTx = retrieveValue (TxKey th) db s
    getOutput op = do
        (omap, _, _) <- get
        mo <-
            case M.lookup op omap of
                Nothing -> retrieveValue (OutputKey op) db s
                Just o  -> return (Just o)
        case mo of
            Nothing -> do
                $(logError) $ "Output not found: " <> logShow op
                error $ "Output not found: " <> show op
            Just o -> return o
    getBalance a = do
        (_, amap, _) <- get
        bm <-
            case M.lookup a amap of
                Just b  -> return $ Just b
                Nothing -> retrieveValue (BalanceKey a) db s
        case bm of
            Nothing -> do
                $(logError) $ "Balance not found: " <> logShow a
                error $ "Balance not found: " <> show a
            Just b -> return b
    putOutput op o =
        modify $ \(omap, amap, ts) -> (M.insert op o omap, amap, ts)
    putBalance a b =
        modify $ \(omap, amap, ts) -> (omap, M.insert a b amap, ts)
    delTx = modify $ \(omap, amap, ts) -> (omap, amap, S.insert th ts)
    delSpender spender = do
        (omap, amap, ts) <- get
        let th = spenderHash spender
        (omap', amap', ts') <- deleteTransaction omap amap th db s
        put (omap', amap', ts <> ts')
    unspendOutput o = o {outSpender = Nothing}
    unspendBalance conf o b =
        if isJust (outBlock o) && conf
            then b
                 { balanceValue = balanceValue b + outputValue o
                 , balanceSpentCount = balanceSpentCount b - 1
                 }
            else b
                 { balanceUnconfirmed =
                       balanceUnconfirmed b + fromIntegral (outputValue o)
                 , balanceMempoolTxs = delete th (balanceMempoolTxs b)
                 }
    removeOutput o b =
        case outBlock o of
            Nothing ->
                b
                { balanceUnconfirmed =
                      balanceUnconfirmed b - fromIntegral (outputValue o)
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
                            getBalance a >>=
                            putBalance a . unspendBalance conf o
                forM_ (zip [0 ..] (txOut txValue)) $ \(i, to) -> do
                    let op = OutPoint th i
                    o <- getOutput op
                    case outSpender o of
                        Nothing      -> return ()
                        Just spender -> delSpender spender
                    case scriptToAddressBS (outScript o) of
                        Nothing -> return ()
                        Just a -> getBalance a >>= putBalance a . removeOutput o
                delTx

blockOutBal ::
       MonadLoggerIO m
    => BlockHash
    -> DB
    -> Maybe Snapshot
    -> m (Maybe (OutputMap, AddressMap))
blockOutBal bh db s =
    getBlock bh db s >>= \case
        Nothing -> return Nothing
        Just BlockValue {..} -> do
            txs <- getTxs blockValueTxs db s
            let om = M.fromList (concatMap f txs ++ concatMap h txs)
                as =
                    S.fromList
                        (mapMaybe (scriptToAddressBS . outScript) (M.elems om))
            bm <- M.fromList <$> mapM l (S.toList as)
            return (Just (om, bm))
  where
    f dtx@DetailedTx {..} = zipWith (g dtx) [0 ..] detailedTxOutputs
    g DetailedTx {..} i DetailedOutput {..} =
        let x =
                OutPoint
                {outPointHash = txHash detailedTxData, outPointIndex = i}
            y =
                Output
                { outputValue = detOutValue
                , outBlock = detailedTxBlock
                , outScript = detOutScript
                , outSpender = detOutSpender
                }
        in (x, y)
    h dtx@DetailedTx {..} =
        map
            (uncurry (j dtx))
            (filter (not . isCoinbase . snd) (zip [0 ..] detailedTxInputs))
    j DetailedTx {..} i DetailedInput {..} =
        let x = detInOutPoint
            y =
                Output
                { outputValue = detInValue
                , outBlock = detInBlock
                , outScript = detInPkScript
                , outSpender =
                      Just
                          Spender
                          { spenderHash = txHash detailedTxData
                          , spenderIndex = i
                          , spenderBlock = detailedTxBlock
                          }
                }
        in (x, y)
    l a =
        retrieveValue (BalanceKey a) db s >>= \case
            Nothing -> do
                $(logError) $ "Balance not found: " <> logShow a
                error $ "Balance not found: " <> show a
            Just b -> return (a, b)

updateTxBalances ::
       OutputMap
    -> AddressMap
    -> Maybe BlockRef
    -> Tx
    -> (OutputMap, AddressMap)
updateTxBalances om am bl tx = execState go (om, am)
  where
    fi i TxIn {..} = do
        o@Output {..} <- g prevOutput
        when (isJust outSpender) $
            error "You are in a maze of twisty little passages, all alike"
        upout
            prevOutput
            o
            { outSpender =
                  Just
                      Spender
                      { spenderHash = txHash tx
                      , spenderIndex = i
                      , spenderBlock = bl
                      }
            }
        case scriptToAddressBS outScript of
            Nothing -> return ()
            Just a -> do
                c@Balance {..} <- b a
                case bl of
                    Nothing -> do
                        upbal
                            a
                            c
                            { balanceUnconfirmed =
                                  balanceUnconfirmed - fromIntegral outputValue
                            , balanceMempoolTxs = txHash tx : balanceMempoolTxs
                            }
                    Just _ -> do
                        when
                            (outputValue > balanceValue)
                            (error "Waste not, want not")
                        upbal
                            a
                            c
                            { balanceValue = balanceValue - outputValue
                            , balanceSpentCount = balanceSpentCount + 1
                            }
    fo i TxOut {..} = do
        o@Output {..} <-
            g OutPoint {outPointIndex = i, outPointHash = txHash tx}
        when (isJust outSpender) $
            error "I jumped off the aircraft with no parachute"
        case scriptToAddressBS outScript of
            Nothing -> return ()
            Just a -> do
                b@Balance {..} <- b a
                case bl of
                    Nothing -> do
                        upbal
                            a
                            b
                            { balanceUnconfirmed =
                                  balanceUnconfirmed + fromIntegral outputValue
                            , balanceMempoolTxs = txHash tx : balanceMempoolTxs
                            }
                    Just _ -> do
                        upbal
                            a
                            b
                            { balanceValue = balanceValue + outputValue
                            , balanceOutputCount = balanceOutputCount + 1
                            }
    go = do
        forM_ ins (uncurry fi)
        forM_ outs (uncurry fo)
    outs = zip [0 ..] (txOut tx)
    ins = filter ((/= nullOutPoint) . prevOutput . snd) (zip [0 ..] (txIn tx))
    g op =
        fromMaybe (error "Don't feed the dwarves anything but coal") <$>
        gets (M.lookup op . fst)
    b a =
        gets (M.lookup a . snd) >>= \case
            Nothing ->
                return
                    Balance
                    { balanceValue = 0
                    , balanceUnconfirmed = 0
                    , balanceOutputCount = 0
                    , balanceSpentCount = 0
                    , balanceMempoolTxs = []
                    }
            Just b -> return b
    upout p o = modify . first $ M.insert p o
    upbal a b = modify . second $ M.insert a b

addNewBlock :: MonadBlock m => Block -> m ()
addNewBlock Block {..} = addNewTxs (Just blockHeader) blockTxns

addNewTxs ::
       MonadBlock m => Maybe BlockHeader -> [Tx] -> m ()
addNewTxs mbh txs =
    flip evalStateT (M.empty, M.empty, S.empty) $ do
        hm <- getHeight
        initOutputs hm
        initBalances
        unspendOutputs
        updateBalances hm
        updateDatabase
  where
    bref mh i = do
        bh <- mbh
        h <- mh
        return
            BlockRef
            { blockRefHash = headerHash bh
            , blockRefHeight = h
            , blockRefMainChain = True
            , blockRefPos = i
            }
    getHeight = do
        mh <-
            runMaybeT $ do
                bh <- MaybeT (return mbh)
                db <- asks myBlockDB
                BlockValue {..} <- MaybeT (getBestBlock db Nothing)
                guard (headerHash blockValueHeader == prevBlock bh)
                return (blockValueHeight + 1)
        if isJust mbh && isNothing mh && mbh /= Just genesisHeader
            then error "I find your lack of faith disturbing"
            else return mh
    initOutputs hm = do
        db <- asks myBlockDB
        let f om' (i, t) = txOutputMap om' t (bref hm i) db Nothing
        (om, am, ts) <- get
        om' <- foldM f om (zip [0 ..] txs)
        put (om', am, ts)
    initBalances = do
        db <- asks myBlockDB
        (om, _, ts) <- get
        let as =
                S.fromList . catMaybes $
                map (scriptToAddressBS . outScript) (M.elems om)
        am <- addrBalances as db Nothing
        put (om, am, ts)
    unspendOutputs = do
        (om, _, _) <- get
        db <- asks myBlockDB
        let findSpender op = do
                o <- M.lookup op om
                s <- outSpender o
                return (spenderHash s)
            prevOutputs Tx {..} = map prevOutput txIn
            deleteTxs =
                S.fromList $ mapMaybe findSpender (concatMap prevOutputs txs)
        forM_ (S.toList deleteTxs) $ \t -> do
            (o1, a1, ts) <- get
            (o1', a1', ts') <- deleteTransaction o1 a1 t db Nothing
            put (o1', a1', ts <> ts')
    updateBalances hm =
        forM_ (zip [0 ..] txs) $ \(i, t) -> do
            (om, am, ts) <- get
            let (om', am') = updateTxBalances om am (bref hm i) t
            put (om', am', ts)
    updateDatabase = do
        mbn <-
            runMaybeT $ do
                bh <- MaybeT (return mbh)
                ch <- asks myChain
                MaybeT (chainGetBlock (headerHash bh) ch)
        when
            (isJust mbh && isNothing mbn)
            (error "A block was provided but could not be found in chain")
        (om, am, ts) <- get
        ds <- catMaybes <$> mapM gtx (S.toList ts)
        let ops =
                concatMap (\tx -> getTxOps om True tx Nothing) ds <>
                getBalanceOps am <>
                case mbn of
                    Just bn ->
                        getBlockOps
                            om
                            False
                            (nodeHeader bn)
                            (nodeWork bn)
                            (nodeHeight bn)
                            txs
                    Nothing ->
                        concatMap (\tx -> getTxOps om False tx Nothing) txs
        db <- asks myBlockDB
        RocksDB.write db def ops
    gtx h =
        runMaybeT $ do
            db <- asks myBlockDB
            TxRecord {..} <- MaybeT (retrieveValue (TxKey h) db Nothing)
            return txValue

getBlockOps ::
       OutputMap
    -> Bool
    -> BlockHeader
    -> BlockWork
    -> BlockHeight
    -> [Tx]
    -> [RocksDB.BatchOp]
getBlockOps om del bh bw bg txs = hop : gop : bop : tops
  where
    b = Block {blockHeader = bh, blockTxns = txs}
    hop =
        let k = BlockKey (headerHash bh)
            v =
                BlockValue
                { blockValueHeight = bg
                , blockValueWork = bw
                , blockValueHeader = bh
                , blockValueSize = fromIntegral (BS.length (encode b))
                , blockValueMainChain = True
                , blockValueTxs = map txHash txs
                }
        in if del
               then deleteOp k
               else insertOp k v
    gop =
        let k = HeightKey bg
            v = headerHash bh
        in if del
               then deleteOp k
               else insertOp k v
    bop =
        let k = BestBlockKey
            v = headerHash bh
            p = prevBlock bh
        in if del
               then insertOp k p
               else insertOp k v
    r i =
        Just $
        BlockRef
        { blockRefHash = headerHash bh
        , blockRefHeight = bg
        , blockRefMainChain = True
        , blockRefPos = i
        }
    tops = concat $ zipWith (\i tx -> getTxOps om del tx (r i)) [0 ..] txs

getTxOps :: OutputMap -> Bool -> Tx -> Maybe BlockRef -> [RocksDB.BatchOp]
getTxOps om del tx br = tops <> pops <> oops <> aiops <> aoops
  where
    is = filter ((/= nullOutPoint) . prevOutput) (txIn tx)
    g p =
        fromMaybe
            (error "Transaction output expected but not provided")
            (M.lookup p om)
    prev Output {..} =
        PrevOut
        { prevOutValue = outputValue
        , prevOutBlock = outBlock
        , prevOutScript = BSS.toShort outScript
        }
    ps = map (\TxIn {..} -> (prevOutput, prev (g prevOutput))) is
    fo n =
        let p =
                OutPoint
                {outPointHash = txHash tx, outPointIndex = fromIntegral n}
            k = OutputKey {outPoint = p}
            v = g p
        in if del
               then deleteOp k
               else insertOp k v
    fp TxIn {prevOutput = p} =
        if del
            then deleteOp (OutputKey p)
            else insertOp (OutputKey p) (g p)
    tops =
        let k = TxKey (txHash tx)
            v = TxRecord {txValueBlock = br, txValue = tx, txValuePrevOuts = ps}
            mk = MempoolTx (txHash tx)
        in if isJust br
           then if del
                then [deleteOp k]
                else [insertOp k v]
           else if del
                then [deleteOp mk, deleteOp k]
                else [insertOp mk tx, insertOp k v]
    pops = map fp is
    oops = map fo [0 .. length (txOut tx) - 1]
    bh = blockRefHeight <$> br
    ai TxIn {prevOutput = p} =
        let k a =
                AddrOutputKey
                { addrOutputSpent = isJust (outSpender (g p))
                , addrOutputAddress = a
                , addrOutputHeight = blockRefHeight <$> outBlock (g p)
                , addrOutPoint = p
                }
        in case scriptToAddressBS (outScript (g p)) of
               Nothing -> []
               Just a ->
                   if del
                       then [ deleteOp
                                  (k a)
                                  { addrOutputSpent =
                                        not (addrOutputSpent (k a))
                                  }
                            , deleteOp (k a)
                            ]
                       else [ deleteOp
                                  (k a)
                                  { addrOutputSpent =
                                        not (addrOutputSpent (k a))
                                  }
                            , insertOp (k a) (g p)
                            ]
    ao n =
        let p =
                OutPoint
                {outPointHash = txHash tx, outPointIndex = fromIntegral n}
            k a =
                AddrOutputKey
                { addrOutputSpent = isJust (outSpender (g p))
                , addrOutputAddress = a
                , addrOutputHeight = bh
                , addrOutPoint = p
                }
        in case scriptToAddressBS (outScript (g p)) of
               Nothing -> []
               Just a ->
                   if del
                       then [ deleteOp
                                  (k a)
                                  { addrOutputSpent =
                                        not (addrOutputSpent (k a))
                                  }
                            , deleteOp (k a)
                            ]
                       else [ deleteOp
                                  (k a)
                                  { addrOutputSpent =
                                        not (addrOutputSpent (k a))
                                  }
                            , insertOp (k a) (g p)
                            ]
    aiops = concatMap ai (filter ((/= nullOutPoint) . prevOutput) (txIn tx))
    aoops = concatMap ao [0 .. length (txOut tx) - 1]

getBalanceOps :: AddressMap -> [RocksDB.BatchOp]
getBalanceOps am = map (\(a, b) -> insertOp (BalanceKey a) b) (M.toAscList am)

revertBestBlock :: MonadBlock m => m ()
revertBestBlock = do
    db <- asks myBlockDB
    best <-
        fromMaybe (error "Holographic universe meltdown") <$>
        getBestBlockHash db Nothing
    when (best == headerHash genesisHeader) $
        error "Attempted to revert genesis block"
    $(logWarn) $ logMe <> "Reverting block " <> logShow best
    BlockValue {..} <-
        fromMaybe (error "Bad robot") <$> getBlock best db Nothing
    txs <- catMaybes <$> mapM gtx blockValueTxs
    flip evalStateT (M.empty, M.empty, S.empty) $ do
        deleteTxs blockValueTxs
        updateDatabase blockValueHeader blockValueWork blockValueHeight txs
  where
    gtx h =
        runMaybeT $ do
            db <- asks myBlockDB
            TxRecord {..} <- MaybeT (retrieveValue (TxKey h) db Nothing)
            return txValue
    deleteTxs ths =
        forM_ ths $ \t -> do
            db <- asks myBlockDB
            (om, am, ts) <- get
            (om', am', ts') <- deleteTransaction om am t db Nothing
            put (om', am', ts <> ts')
    updateDatabase bh bw bg txs = do
        (om, am, ts) <- get
        db <- asks myBlockDB
        let mhs = S.difference ts (S.fromList (map txHash txs))
        mts <- catMaybes <$> mapM gtx (S.toList mhs)
        let ops =
                concatMap (\tx -> getTxOps om True tx Nothing) mts <>
                getBlockOps om True bh bw bg txs <>
                getBalanceOps am
        RocksDB.write db def ops
        importMempool txs

-- TODO: do something about orphan transactions
importMempool :: MonadBlock m => [Tx] -> m ()
importMempool txs' = do
    db <- asks myBlockDB
    om <- foldM (\m t -> txOutputMap m t Nothing db Nothing) M.empty txs
    let tvs = map (\tx -> (tx, vtx om tx)) txs
        os = map fst $ filter ((== TxOrphan) . snd) tvs
        vs = map fst $ filter ((== TxValid) . snd) tvs
    addNewTxs Nothing vs
  where
    txs = fo (S.fromList txs')
    vtx om tx = maximum [inputSpent om tx, fundsLow om tx]
    inputSpent om tx =
        let t = maybe True (\o -> isNothing (outSpender o))
            b = all (\i -> t (M.lookup (prevOutput i) om)) (ins tx)
        in if b
               then TxValid
               else TxInputSpent
    fundsLow om tx =
        let f a i = (+) <$> a <*> (outputValue <$> M.lookup (prevOutput i) om)
            i = foldl' f (Just 0) (ins tx)
            o = sum (map outValue (txOut tx))
        in case (>= o) <$> i of
               Nothing    -> TxOrphan
               Just True  -> TxValid
               Just False -> TxLowFunds
    ins tx = filter ((/= nullOutPoint) . prevOutput) (txIn tx)
    dep s t = any (flip S.member s . outPointHash . prevOutput) (txIn t)
    fo s | S.null s = []
         | otherwise =
           let (ds, ns) = S.partition (dep (S.map txHash s)) s
           in S.toList ns <> fo ds

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
            Nothing -> error "Could not obtain block from chain"
    $(logInfo) $ logMe <> "Importing block " <> logShow (nodeHeight bn)
    addNewBlock block
    l <- asks myListener
    liftIO . atomically . l $ BestBlock (headerHash blockHeader)

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
