{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections     #-}
module Haskoin.Store.Logic
    ( ImportException (..)
    , initBest
    , getOldMempool
    , revertBlock
    , importBlock
    , newMempoolTx
    , deleteTx
    ) where

import           Control.Monad                 (forM, forM_, guard, unless,
                                                void, when, zipWithM_, (>=>))
import           Control.Monad.Logger          (MonadLogger, MonadLoggerIO,
                                                logDebugS, logErrorS)
import qualified Data.ByteString               as B
import qualified Data.ByteString.Short         as B.Short
import           Data.Either                   (rights)
import           Data.Function                 (on)
import qualified Data.HashSet                  as HashSet
import qualified Data.IntMap.Strict            as I
import           Data.List                     (nub, nubBy, sortOn)
import           Data.Maybe                    (catMaybes, fromMaybe, isNothing)
import           Data.Ord                      (Down (Down))
import           Data.Serialize                (encode)
import           Data.Text                     (Text)
import           Data.Word                     (Word32, Word64)
import           Haskoin                       (Address, Block (..), BlockHash,
                                                BlockHeader (..),
                                                BlockNode (..), Network (..),
                                                OutPoint (..), Tx (..), TxHash,
                                                TxIn (..), TxOut (..),
                                                addrToString, blockHashToHex,
                                                computeSubsidy, eitherToMaybe,
                                                genesisBlock, genesisNode,
                                                headerHash, isGenesis,
                                                nullOutPoint, scriptToAddressBS,
                                                txHash, txHashToHex)
import           Haskoin.Store.Common          (StoreRead (..), StoreWrite (..),
                                                getActiveTxData, nub')
import           Haskoin.Store.Data            (Balance (..), BlockData (..),
                                                BlockRef (..), Prev (..),
                                                Spender (..), TxData (..),
                                                TxRef (..), UnixTime,
                                                Unspent (..), confirmed)
import           Haskoin.Store.Database.Writer (MemoryTx, WriterT, runTx)
import           UnliftIO                      (Exception, MonadIO,
                                                MonadUnliftIO, TVar, async,
                                                atomically, bracket_, newTVarIO,
                                                readTVar, retrySTM, throwIO,
                                                wait, writeTVar)

data ImportException
    = PrevBlockNotBest
    | Orphan
    | UnexpectedCoinbase
    | BestBlockNotFound
    | BlockNotBest
    | TxNotFound
    | DoubleSpend
    | TxConfirmed
    | InsufficientFunds
    | DuplicatePrevOutput
    | TxSpent
    | OrphanLoop
    deriving (Eq, Ord, Exception)

instance Show ImportException where
    show PrevBlockNotBest    = "Previous block not best"
    show Orphan              = "Orphan"
    show UnexpectedCoinbase  = "Unexpected coinbase"
    show BestBlockNotFound   = "Best block not found"
    show BlockNotBest        = "Block not best"
    show TxNotFound          = "Transaction not found"
    show DoubleSpend         = "Double spend"
    show TxConfirmed         = "Transaction confirmed"
    show InsufficientFunds   = "Insufficient funds"
    show DuplicatePrevOutput = "Duplicate previous output"
    show TxSpent             = "Transaction is spent"
    show OrphanLoop          = "Orphan loop"

type Lock = TVar Bool

initBest :: (MonadLoggerIO m, MonadUnliftIO m) => WriterT m ()
initBest = do
    net <- getNetwork
    m <- getBestBlock
    when (isNothing m) . void $
        importBlock (genesisBlock net) (genesisNode net)

getOldMempool :: MonadIO m => UnixTime -> WriterT m [TxHash]
getOldMempool now =
    map txRefHash . filter f <$> getMempool
  where
    f = (< now - 3600 * 72) . memRefTime . txRefBlock

newLock :: MonadIO m => m Lock
newLock = newTVarIO False

withLock :: MonadUnliftIO m => Lock -> m a -> m a
withLock lock = bracket_ take_lock put_lock
  where
    take_lock = atomically $
        readTVar lock >>= \t -> when t retrySTM
    put_lock = atomically $ writeTVar lock False

newMempoolTx :: (MonadLoggerIO m, MonadUnliftIO m)
             => Tx -> UnixTime -> WriterT m Bool
newMempoolTx tx w = getActiveTxData (txHash tx) >>= \case
    Just _ -> do
        $(logDebugS) "BlockStore" $
            "Transaction already in store: "
            <> txHashToHex (txHash tx)
        return False
    Nothing -> do
        freeOutputs True True [tx]
        preLoadMemory [tx]
        rbf <- isRBF (MemRef w) tx
        checkNewTx tx
        runTx $ importTx (MemRef w) w rbf tx
        return True

preLoadMemory :: (MonadLoggerIO m, MonadUnliftIO m)
              => [Tx]
              -> WriterT m ()
preLoadMemory txs = do
    $(logDebugS) "BlockStore" "Pre-loading memory"
    load_utxo
    preload_txs
    preload_mempool
  where
    preload_mempool = getMempool >>= runTx . setMempool
    get_balance a = do
        net <- getNetwork
        bal <- getBalance a
        $(logDebugS) "BlockStore" $
            "Pre-loading balance for address: " <> showAddr net a
        runTx $ setBalance bal
    load_utxo = do
        as <- mapM (async . loadUnspentOutputs) txs
        mapM_ wait as
    preload_txs = do
        as <- forM txs $ \tx -> async $ do
            getTxData (txHash tx) >>= mapM_ preload_tx
            forM_ (txOut tx) $
                  mapM_ get_balance . scriptToAddressBS . scriptOutput
        mapM_ wait as
    preload_tx td = do
        let th = txHash (txData td)
        $(logDebugS) "BlockStore" $
            "Preloading tx: " <> txHashToHex th
        spenders <- fix_spenders th <$> getSpenders th
        forM_ (txDataPrevs td) $
            mapM_ get_balance . scriptToAddressBS . prevScript
        runTx $ do
            mapM_ (uncurry insertSpender) spenders
            insertTx td
    fix_spenders th =
        let f i s = (OutPoint th (fromIntegral i), s)
         in map (uncurry f) . I.toList

bestBlockData :: MonadLoggerIO m => WriterT m BlockData
bestBlockData = do
    h <- getBestBlock >>= \case
        Nothing -> do
            $(logErrorS) "BlockStore" "Best block unknown"
            throwIO BestBlockNotFound
        Just h -> return h
    getBlock h >>= \case
        Nothing -> do
            $(logErrorS) "BlockStore" "Best block not found"
            throwIO BestBlockNotFound
        Just b -> return b

revertBlock :: (MonadLoggerIO m, MonadUnliftIO m)
            => BlockHash -> WriterT m ()
revertBlock bh = do
    bd <- bestBlockData >>= \b ->
        if headerHash (blockDataHeader b) == bh
        then return b
        else do
            $(logErrorS) "BlockStore" $
                "Cannot revert non-head block: " <> blockHashToHex bh
            throwIO BlockNotBest
    tds <- mapM getImportTxData (blockDataTxs bd)
    preLoadMemory $ map txData tds
    runTx $ do
        setBest (prevBlock (blockDataHeader bd))
        insertBlock bd {blockDataMainChain = False}
        forM_ (tail tds) unConfirmTx
    deleteTx False False (txHash (txData (head tds)))

checkNewBlock :: MonadLoggerIO m => Block -> BlockNode -> WriterT m ()
checkNewBlock b n =
    getBestBlock >>= \case
        Nothing
            | isGenesis n -> return ()
            | otherwise -> do
                $(logErrorS) "BlockStore" $
                    "Cannot import non-genesis block: "
                    <> blockHashToHex (headerHash (blockHeader b))
                throwIO BestBlockNotFound
        Just h
            | prevBlock (blockHeader b) == h -> return ()
            | otherwise -> do
                $(logErrorS) "BlockStore" $
                    "Block does not build on head: "
                    <> blockHashToHex (headerHash (blockHeader b))
                throwIO PrevBlockNotBest

importOrConfirm :: (MonadLoggerIO m, MonadUnliftIO m)
                => BlockNode -> [Tx] -> WriterT m ()
importOrConfirm bn txs = do
    freeOutputs True False txs
    preLoadMemory txs
    go (zip [0..] txs)
  where
    go itxs = do
        orphans <- catMaybes <$> forM itxs action
        unless (null orphans) $ do
            when (length orphans == length itxs) loop_detected
            go orphans
    br i = BlockRef {blockRefHeight = nodeHeight bn, blockRefPos = i}
    bn_time = fromIntegral . blockTimestamp $ nodeHeader bn
    action (i, tx) =
        getActiveTxData (txHash tx) >>= \case
            Nothing -> do
                $(logDebugS) "BlockStore" $
                    "Importing tx: " <> txHashToHex (txHash tx)
                import_it i tx
            Just t -> do
                $(logDebugS) "BlockStore" $
                    "Confirming tx: " <> txHashToHex (txHash tx)
                runTx $ confTx t (Just (br i))
                return Nothing
    import_it i tx = runTx $ do
        us <- getUnspentOutputs tx
        if orphanTest us tx
            then return $ Just (i, tx)
            else do importTx (br i) bn_time False tx
                    return Nothing
    loop_detected = do
        $(logErrorS) "BlockStore" "Orphan loop detected"
        throwIO OrphanLoop

importBlock :: (MonadLoggerIO m, MonadUnliftIO m)
            => Block -> BlockNode -> WriterT m ()
importBlock b n = do
    checkNewBlock b n
    net <- getNetwork
    let subsidy = computeSubsidy net (nodeHeight n)
    bs <- getBlocksAtHeight (nodeHeight n)
    runTx $ do
        insertBlock
            BlockData
                { blockDataHeight = nodeHeight n
                , blockDataMainChain = True
                , blockDataWork = nodeWork n
                , blockDataHeader = nodeHeader n
                , blockDataSize = fromIntegral (B.length (encode b))
                , blockDataTxs = map txHash (blockTxns b)
                , blockDataWeight = if getSegWit net then w else 0
                , blockDataSubsidy = subsidy
                , blockDataFees = cb_out_val - subsidy
                , blockDataOutputs = ts_out_val
                }
        setBlocksAtHeight
            (nub (headerHash (nodeHeader n) : bs))
            (nodeHeight n)
        setBest (headerHash (nodeHeader n))
    importOrConfirm n (blockTxns b)
  where
    cb_out_val =
        sum $ map outValue $ txOut $ head $ blockTxns b
    ts_out_val =
        sum $ map (sum . map outValue . txOut) $ tail $ blockTxns b
    w =
        let f t = t {txWitness = []}
            b' = b {blockTxns = map f (blockTxns b)}
            x = B.length (encode b)
            s = B.length (encode b')
         in fromIntegral $ s * 3 + x

checkNewTx :: MonadLoggerIO m => Tx -> WriterT m ()
checkNewTx tx = do
    us <- runTx $ getUnspentOutputs tx
    when (unique_inputs < length (txIn tx)) $ do
        $(logDebugS) "BlockStore" $
            "Transaction spends same output twice: "
            <> txHashToHex (txHash tx)
        throwIO DuplicatePrevOutput
    when (isCoinbase tx) $ do
        $(logDebugS) "BlockStore" $
            "Coinbase cannot be imported into mempool: "
            <> txHashToHex (txHash tx)
        throwIO UnexpectedCoinbase
    when (outputs > unspents us) $ do
        $(logDebugS) "BlockStore" $
            "Insufficient funds for tx: " <> txHashToHex (txHash tx)
        throwIO InsufficientFunds
    when (orphanTest us tx) $ do
        $(logDebugS) "BlockStore" $
            "Orphan: " <> txHashToHex (txHash tx)
        throwIO Orphan
  where
    unspents = sum . map unspentAmount
    outputs = sum (map outValue (txOut tx))
    unique_inputs = length (nub' (map prevOutput (txIn tx)))

orphanTest :: [Unspent] -> Tx -> Bool
orphanTest us tx = length (prevOuts tx) > length us

getUnspentOutputs :: Tx -> MemoryTx [Unspent]
getUnspentOutputs tx = catMaybes <$> mapM getUnspent (prevOuts tx)

loadUnspentOutputs :: (MonadLoggerIO m, MonadUnliftIO m)
                   => Tx -> WriterT m ()
loadUnspentOutputs tx =
    mapM_ go ops
  where
    ops = prevOuts tx
    go op = getUnspent op >>= mapM_ insert_unspent
    insert_unspent u = do
        bal <- mapM getBalance (unspentAddress u)
        runTx $ do
            insertUnspent u
            mapM_ setBalance bal

prepareTxData :: Bool -> BlockRef -> Word64 -> [Unspent] -> Tx -> TxData
prepareTxData rbf br tt us tx =
    TxData { txDataBlock = br
           , txData = tx
           , txDataPrevs = ps
           , txDataDeleted = False
           , txDataRBF = rbf
           , txDataTime = tt
           }
  where
    mkprv u = Prev (B.Short.fromShort (unspentScript u)) (unspentAmount u)
    ps = I.fromList $ zip [0 ..] $ if isCoinbase tx then [] else map mkprv us

importTx
    :: BlockRef
    -> Word64 -- ^ unix time
    -> Bool -- ^ RBF
    -> Tx
    -> MemoryTx ()
importTx br tt rbf tx = do
    us <- getUnspentOutputs tx
    let td = prepareTxData rbf br tt us tx
    commitAddTx us td

unConfirmTx :: TxData -> MemoryTx ()
unConfirmTx t = confTx t Nothing

replaceAddressTx :: TxData -> BlockRef -> MemoryTx ()
replaceAddressTx t new = forM_ (txDataAddresses t) $ \a -> do
    deleteAddrTx
        a
        TxRef
        { txRefBlock = txDataBlock t
        , txRefHash = txHash (txData t)
        }
    insertAddrTx
        a
        TxRef
        { txRefBlock = new
        , txRefHash = txHash (txData t)
        }

adjustAddressOutput
    :: OutPoint
    -> TxOut
    -> BlockRef
    -> BlockRef
    -> MemoryTx ()
adjustAddressOutput op o old new = do
    let pk = scriptOutput o
    s <- getSpender op
    when (isNothing s) $ replace_unspent pk
  where
    replace_unspent pk = do
        let ma = eitherToMaybe (scriptToAddressBS pk)
        deleteUnspent op
        insertUnspent
            Unspent
                { unspentBlock = new
                , unspentPoint = op
                , unspentAmount = outValue o
                , unspentScript = B.Short.toShort pk
                , unspentAddress = ma
                }
        forM_ ma $ replace_addr_unspent pk
    replace_addr_unspent pk a = do
        deleteAddrUnspent
            a
            Unspent
            { unspentBlock = old
            , unspentPoint = op
            , unspentAmount = outValue o
            , unspentScript = B.Short.toShort pk
            , unspentAddress = Just a
            }
        insertAddrUnspent
            a
            Unspent
            { unspentBlock = new
            , unspentPoint = op
            , unspentAmount = outValue o
            , unspentScript = B.Short.toShort pk
            , unspentAddress = Just a
            }
        decreaseBalance (confirmed old) a (outValue o)
        increaseBalance (confirmed new) a (outValue o)

confTx :: TxData -> Maybe BlockRef -> MemoryTx ()
confTx t mbr = do
    replaceAddressTx t new
    forM_ (zip [0 ..] (txOut (txData t))) $ \(n, o) -> do
        let op = OutPoint (txHash (txData t)) n
        adjustAddressOutput op o old new
    insertTx td
    updateMempool td
  where
    new = fromMaybe (MemRef (txDataTime t)) mbr
    old = txDataBlock t
    td = t {txDataBlock = new}

freeOutputs
    :: (MonadLoggerIO m, MonadUnliftIO m)
    => Bool -- ^ only delete transaction if unconfirmed
    -> Bool -- ^ only delete RBF
    -> [Tx]
    -> WriterT m ()
freeOutputs memonly rbfcheck txs = do
    as <- mapM (async . get_chain) txs
    chain <- concat <$> mapM wait as
    mapM_ deleteSingleTx (nub chain)
  where
    get_chain tx =
        fmap concat $
        forM (nub' (prevOuts tx)) $
        getSpender >=> \case
        Nothing -> return []
        Just Spender {spenderHash = s} ->
            getChain memonly rbfcheck s >>= \case
            td : _ | txHash tx == txHash (txData td) ->
                     return []
            ts -> return ts

deleteTx
    :: (MonadLoggerIO m, MonadUnliftIO m)
    => Bool -- ^ only delete transaction if unconfirmed
    -> Bool -- ^ only delete RBF
    -> TxHash
    -> WriterT m ()
deleteTx memonly rbfcheck txhash =
    getChain memonly rbfcheck txhash >>= mapM_ deleteSingleTx

getChain
    :: (MonadLoggerIO m, StoreRead m)
    => Bool -- ^ only delete transaction if unconfirmed
    -> Bool -- ^ only delete RBF
    -> TxHash
    -> m [TxData]
getChain memonly rbfcheck txhash =
    fmap (nub . reverse) $ getActiveTxData txhash >>= \case
        Nothing ->
            return []
        Just td
            | memonly && confirmed (txDataBlock td) ->
                throwIO TxConfirmed
            | rbfcheck ->
                isRBF (txDataBlock td) (txData td) >>= \case
                    True -> go td
                    False -> throwIO DoubleSpend
            | otherwise -> go td
  where
    go td = do
        spenders <- nub' . map spenderHash . I.elems <$> getSpenders txhash
        chains <- concat <$> mapM (getChain memonly rbfcheck) spenders
        return $ td : chains

deleteSingleTx :: (MonadLoggerIO m, MonadUnliftIO m)
               => TxData -> WriterT m ()
deleteSingleTx td = do
    $(logDebugS) "BlockStore" $
        "Deleting tx: " <> txHashToHex (txHash (txData td))
    preload
    runTx $ commitDelTx td
  where
    preload = do
        let ths = nub' $ map outPointHash (prevOuts (txData td))
        tds <- forM ths $ \th -> getActiveTxData th >>= \case
            Nothing -> do
                $(logDebugS) "BlockStore" $
                    "Could not get prev tx: " <> txHashToHex th
                throwIO TxNotFound
            Just d -> return d
        preLoadMemory $ txData td : map txData tds

commitDelTx :: TxData -> MemoryTx ()
commitDelTx = commitModTx False []

commitAddTx :: [Unspent] -> TxData -> MemoryTx ()
commitAddTx = commitModTx True

commitModTx :: Bool -> [Unspent] -> TxData -> MemoryTx ()
commitModTx add us td = do
    let as = txDataAddresses td
    forM_ as $ \a -> do
        mod_addr_tx a
        modAddressCount add a
    mod_outputs
    mod_unspent
    insertTx td'
    updateMempool td'
  where
    td' = td { txDataDeleted = not add }
    tx_ref = TxRef (txDataBlock td) (txHash (txData td))
    mod_addr_tx a | add = insertAddrTx a tx_ref
                  | otherwise = deleteAddrTx a tx_ref
    mod_unspent | add = spendOutputs us td
                | otherwise = unspendOutputs td
    mod_outputs | add = addOutputs td
                | otherwise = delOutputs td

updateMempool :: TxData -> MemoryTx ()
updateMempool td = do
    mp <- getMempool
    setMempool (f mp)
  where
    f mp | txDataDeleted td || confirmed (txDataBlock td) =
           filter ((/= txHash (txData td)) . txRefHash) mp
         | otherwise =
           sortOn Down $ TxRef (txDataBlock td) (txHash (txData td)) : mp

spendOutputs :: [Unspent] -> TxData -> MemoryTx ()
spendOutputs us td =
    zipWithM_ (spendOutput (txHash (txData td))) [0 ..] us

addOutputs :: TxData -> MemoryTx ()
addOutputs td =
    zipWithM_
        (addOutput (txDataBlock td) . OutPoint (txHash (txData td)))
        [0 ..]
        (txOut (txData td))

isRBF :: (MonadLogger m, StoreRead m) => BlockRef -> Tx -> m Bool
isRBF br tx
    | confirmed br =
      return False
    | otherwise =
      getNetwork >>= \net ->
          if getReplaceByFee net
          then go
          else return False
  where
    go | any ((< 0xffffffff - 1) . txInSequence) (txIn tx) =
         return True
       | otherwise =
         let hs = nub' $ map (outPointHash . prevOutput) (txIn tx)
             ck [] = return False
             ck (h:hs') =
                 getActiveTxData h >>= \case
                 Nothing -> do
                     $(logErrorS) "BlockStore" $
                         "Parent transaction not found: "
                         <> txHashToHex h
                     error $ "Parent transaction not found: " <> show h
                 Just t
                     | confirmed (txDataBlock t) -> ck hs'
                     | txDataRBF t -> return True
                     | otherwise -> ck hs'
         in ck hs

addOutput
    :: BlockRef
    -> OutPoint
    -> TxOut
    -> MemoryTx ()
addOutput = modOutput True

delOutput :: BlockRef
          -> OutPoint
          -> TxOut
          -> MemoryTx ()
delOutput = modOutput False

modOutput :: Bool
          -> BlockRef
          -> OutPoint
          -> TxOut
          -> MemoryTx ()
modOutput add br op o = do
    mod_unspent
    forM_ ma $ \a -> do
        mod_addr_unspent a u
        modBalance (confirmed br) add a (outValue o)
        modifyReceived a v
  where
    v | add = (+ outValue o)
      | otherwise = subtract (outValue o)
    ma = eitherToMaybe (scriptToAddressBS (scriptOutput o))
    u = Unspent { unspentScript = B.Short.toShort (scriptOutput o)
                , unspentBlock = br
                , unspentPoint = op
                , unspentAmount = outValue o
                , unspentAddress = ma
                }
    mod_unspent | add = insertUnspent u
                | otherwise = deleteUnspent op
    mod_addr_unspent | add = insertAddrUnspent
                     | otherwise = deleteAddrUnspent

delOutputs :: TxData -> MemoryTx ()
delOutputs td =
    forM_ (zip [0..] outs) $ \(i, o) -> do
        let op = OutPoint (txHash (txData td)) i
        delOutput (txDataBlock td) op o
  where
    outs = txOut (txData td)

getImportTxData :: MonadLoggerIO m => TxHash -> WriterT m TxData
getImportTxData th =
    getActiveTxData th >>= \case
        Nothing -> do
            $(logDebugS) "BlockStore" $ "Tx not found: " <> txHashToHex th
            throwIO TxNotFound
        Just d -> return d

getTxOut :: Word32 -> Tx -> Maybe TxOut
getTxOut i tx = do
    guard (fromIntegral i < length (txOut tx))
    return $ txOut tx !! fromIntegral i

spendOutput :: TxHash -> Word32 -> Unspent -> MemoryTx ()
spendOutput th ix u = do
    insertSpender (unspentPoint u) (Spender th ix)
    let pk = B.Short.fromShort (unspentScript u)
    case scriptToAddressBS pk of
        Left _ -> return ()
        Right a -> do
            decreaseBalance
                (confirmed (unspentBlock u))
                a
                (unspentAmount u)
            deleteAddrUnspent a u
    deleteUnspent (unspentPoint u)

unspendOutputs :: TxData -> MemoryTx ()
unspendOutputs td = mapM_ unspendOutput (prevOuts (txData td))

unspendOutput :: OutPoint -> MemoryTx ()
unspendOutput op = do
    t <- getActiveTxData (outPointHash op) >>= \case
        Nothing ->
            error $ "Could not find tx data: " <> show (outPointHash op)
        Just t -> return t
    o <- case getTxOut (outPointIndex op) (txData t) of
        Nothing ->
            error $ "Could not find output: " <> show op
        Just o -> return o
    let m = eitherToMaybe (scriptToAddressBS (scriptOutput o))
        u = Unspent { unspentAmount = outValue o
                    , unspentBlock = txDataBlock t
                    , unspentScript = B.Short.toShort (scriptOutput o)
                    , unspentPoint = op
                    , unspentAddress = m
                    }
    deleteSpender op
    insertUnspent u
    forM_ m $ \a -> do
        insertAddrUnspent a u
        increaseBalance (confirmed (unspentBlock u)) a (outValue o)

modifyReceived :: Address -> (Word64 -> Word64) -> MemoryTx ()
modifyReceived a f =
    getBalance a >>= \b ->
    setBalance b {balanceTotalReceived = f (balanceTotalReceived b)}

decreaseBalance
    :: Bool
    -> Address
    -> Word64
    -> MemoryTx ()
decreaseBalance conf = modBalance conf False

increaseBalance
    :: Bool
    -> Address
    -> Word64
    -> MemoryTx ()
increaseBalance conf = modBalance conf True

modBalance
    :: Bool -- ^ confirmed
    -> Bool -- ^ add
    -> Address
    -> Word64
    -> MemoryTx ()
modBalance conf add a val =
    getBalance a >>= \b -> setBalance ((g . f) b)
  where
    g b = b { balanceUnspentCount = m 1 (balanceUnspentCount b) }
    f b | conf = b { balanceAmount = m val (balanceAmount b) }
        | otherwise = b { balanceZero = m val (balanceZero b) }
    m | add = (+)
      | otherwise = subtract

modAddressCount :: Bool -> Address -> MemoryTx ()
modAddressCount add a =
    getBalance a >>= \b ->
    setBalance b {balanceTxCount = f (balanceTxCount b)}
  where
    f | add = (+ 1)
      | otherwise = subtract 1

txOutAddrs :: [TxOut] -> [Address]
txOutAddrs = nub' . rights . map (scriptToAddressBS . scriptOutput)

txInAddrs :: [Prev] -> [Address]
txInAddrs = nub' . rights . map (scriptToAddressBS . prevScript)

txDataAddresses :: TxData -> [Address]
txDataAddresses t =
    nub' $ txInAddrs prevs <> txOutAddrs outs
  where
    prevs = I.elems (txDataPrevs t)
    outs = txOut (txData t)

isCoinbase :: Tx -> Bool
isCoinbase = all ((== nullOutPoint) . prevOutput) . txIn

prevOuts :: Tx -> [OutPoint]
prevOuts tx = filter (/= nullOutPoint) (map prevOutput (txIn tx))

showAddr :: Network -> Address -> Text
showAddr net = fromMaybe "[unrepresentable]" . addrToString net
