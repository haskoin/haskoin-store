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

import           Control.Monad           (forM, forM_, guard, unless, void,
                                          when, zipWithM_)
import           Control.Monad.Logger    (MonadLoggerIO, logDebugS, logErrorS)
import qualified Data.ByteString         as B
import qualified Data.ByteString.Short   as B.Short
import           Data.Either             (rights)
import qualified Data.IntMap.Strict      as I
import           Data.List               (nub, sortOn)
import           Data.Maybe              (catMaybes, fromMaybe, isNothing)
import           Data.Ord                (Down (Down))
import           Data.Serialize          (encode)
import           Data.String.Conversions (cs)
import           Data.Text               (Text)
import           Data.Word               (Word32, Word64)
import           Haskoin                 (Address, Block (..), BlockHash,
                                          BlockHeader (..), BlockNode (..),
                                          Network (..), OutPoint (..), Tx (..),
                                          TxHash, TxIn (..), TxOut (..),
                                          blockHashToHex, computeSubsidy,
                                          eitherToMaybe, genesisBlock,
                                          genesisNode, headerHash, isGenesis,
                                          nullOutPoint, scriptToAddressBS,
                                          txHash, txHashToHex)
import           Haskoin.Store.Common    (StoreRead (..), StoreWrite (..),
                                          getActiveTxData, nub')
import           Haskoin.Store.Data      (Balance (..), BlockData (..),
                                          BlockRef (..), Prev (..),
                                          Spender (..), TxData (..), TxRef (..),
                                          UnixTime, Unspent (..), confirmed)
import           UnliftIO                (Exception, MonadIO, MonadUnliftIO,
                                          async, bracket_, handle, throwIO,
                                          wait)
import           UnliftIO.STM            (TVar, atomically, checkSTM, newTVarIO,
                                          readTVar, writeTVar)

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
    show OrphanLoop          = "Orphan loop"

withLock :: MonadUnliftIO m => TVar Bool -> m () -> m ()
withLock lockbox =
    bracket_ get_lock put_lock
  where
    get_lock = atomically $ do
        locked <- readTVar lockbox
        checkSTM (not locked)
        writeTVar lockbox True
    put_lock = atomically $
        writeTVar lockbox False

initBest ::
       ( StoreRead m
       , StoreWrite m
       , MonadLoggerIO m
       , MonadUnliftIO m
       )
    => m ()
initBest = do
    net <- getNetwork
    m <- getBestBlock
    when (isNothing m) . void $
        importBlock (genesisBlock net) (genesisNode net)

getOldMempool :: StoreRead m => UnixTime -> m [TxHash]
getOldMempool now =
    map txRefHash
    . filter ((< now - 3600 * 72) . memRefTime . txRefBlock)
    <$> getMempool

newMempoolTx ::
       ( StoreRead m
       , StoreWrite m
       , MonadLoggerIO m
       , MonadUnliftIO m
       )
    => Tx
    -> UnixTime
    -> m Bool
newMempoolTx tx w = getActiveTxData (txHash tx) >>= \case
    Just _ -> do
        $(logDebugS) "BlockStore" $
            "Transaction already in store: "
            <> txHashToHex (txHash tx)
        return False
    Nothing -> do
        importTx Nothing (MemRef w) w tx
        return True

bestBlockData
    :: ( StoreRead m
       , StoreWrite m
       , MonadLoggerIO m
       )
    => m BlockData
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

revertBlock
    :: ( StoreRead m
       , StoreWrite m
       , MonadLoggerIO m
       )
    => BlockHash
    -> m ()
revertBlock bh = do
    bd <- bestBlockData >>= \b ->
        if headerHash (blockDataHeader b) == bh
        then return b
        else do
            $(logErrorS) "BlockStore" $
                "Cannot revert non-head block: " <> blockHashToHex bh
            throwIO BlockNotBest
    tds <- mapM getImportTxData (blockDataTxs bd)
    setBest (prevBlock (blockDataHeader bd))
    insertBlock bd {blockDataMainChain = False}
    forM_ (tail tds) unConfirmTx
    deleteTx False False (txHash (txData (head tds)))

checkNewBlock
    :: ( StoreRead m
       , StoreWrite m
       , MonadLoggerIO m
       , MonadIO m
       )
    => Block
    -> BlockNode
    -> m ()
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

importOrConfirm
    :: ( StoreRead m
       , StoreWrite m
       , MonadLoggerIO m
       , MonadUnliftIO m
       )
    => BlockNode
    -> [Tx]
    -> m ()
importOrConfirm bn txs = do
    lockbox <- newTVarIO False
    go lockbox indexed_txs
  where
    go lockbox its = do
        asyncs <- forM its (async . action lockbox)
        orphans <- catMaybes <$> mapM wait asyncs
        when (length orphans == length its) loop_detected
        unless (null orphans) (go lockbox orphans)
    indexed_txs = zip [0..] txs
    br i = BlockRef {blockRefHeight = nodeHeight bn, blockRefPos = i}
    action lockbox (i, tx) =
        handle (handle_orphan (i, tx)) $ do
            importTx
                (Just lockbox)
                (br i)
                (fromIntegral (blockTimestamp (nodeHeader bn)))
                tx
            return Nothing
    loop_detected = do
        $(logErrorS) "BlockStore" "Orphan loop detected"
        throwIO OrphanLoop
    handle_orphan (i, tx) Orphan = do
        $(logDebugS) "BlockStore" $
            "Missing dependencies for tx: " <> txHashToHex (txHash tx)
        return (Just (i, tx))
    handle_orphan _ e = do
        $(logErrorS) "BlockStore" $
            "Transaction failed importing: " <> cs (show e)
        throwIO e

importBlock
    :: ( StoreRead m
       , StoreWrite m
       , MonadLoggerIO m
       , MonadUnliftIO m
       )
    => Block
    -> BlockNode
    -> m ()
importBlock b n = do
    checkNewBlock b n
    net <- getNetwork
    let subsidy = computeSubsidy net (nodeHeight n)
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
    bs <- getBlocksAtHeight (nodeHeight n)
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

checkNewTx
    :: ( StoreRead m
       , StoreWrite m
       , MonadLoggerIO m
       , MonadIO m
       )
    => Tx
    -> m ()
checkNewTx tx = do
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
 where
   unique_inputs = length (nub' (map prevOutput (txIn tx)))

getUnspentOutputs
    :: ( StoreRead m
       , StoreWrite m
       , MonadLoggerIO m
       , MonadUnliftIO m
       )
    => Maybe (TVar Bool)
    -> Bool -- ^ only delete from mempool
    -> [OutPoint]
    -> m [Unspent] -- ^ unspents and transactions deleted
getUnspentOutputs lockbox mem ops =
    forM ops go
  where
    go op = getUnspent op >>= \case
        Nothing -> force_unspent op
        Just u -> return u
    force_unspent op = do
        s <- getSpender op >>= \case
            Nothing -> do
                $(logDebugS) "BlockStore" $
                    "Output not found: " <> showOutput op
                throwIO Orphan
            Just Spender {spenderHash = s} -> return s
        $(logDebugS) "BlockStore" $
            "Deleting to free output: " <> txHashToHex s
        case lockbox of
            Nothing ->
                deleteTx True mem s
            Just lockbox' ->
                withLock lockbox' $ deleteTx True mem s
        getUnspent op >>= \case
            Nothing -> do
                $(logErrorS) "BlockStore" $
                    "Unexpected absent output: " <> showOutput op
                error $ "Unexpected absent output: " <> show op
            Just u -> return u

checkFunds
    :: ( StoreRead m
       , StoreWrite m
       , MonadLoggerIO m
       , MonadIO m
       )
    => [Unspent]
    -> Tx
    -> m ()
checkFunds us tx =
    when (outputs > unspents) $ do
        $(logDebugS) "BlockStore" $
            "Insufficient funds for tx: " <> txHashToHex (txHash tx)
        throwIO InsufficientFunds
  where
    unspents = sum (map unspentAmount us)
    outputs = sum (map outValue (txOut tx))

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
    :: ( StoreRead m
       , StoreWrite m
       , MonadLoggerIO m
       , MonadUnliftIO m
       )
    => Maybe (TVar Bool)
    -> BlockRef
    -> Word64 -- ^ unix time
    -> Tx
    -> m ()
importTx lockbox br tt tx = do
    $(logDebugS) "BlockStore" $
        "Importing transaction " <> txHashToHex (txHash tx)
    unless (confirmed br) $ checkNewTx tx
    us <-
        if isCoinbase tx
        then return []
        else getUnspentOutputs
             lockbox
             (not (confirmed br))
             (map prevOutput (txIn tx))
    unless (confirmed br) $ checkFunds us tx
    rbf <- isRBF br tx
    let td = prepareTxData rbf br tt us tx
    commitAddTx us td

unConfirmTx
    :: (StoreRead m, StoreWrite m, MonadLoggerIO m)
    => TxData
    -> m ()
unConfirmTx t = confTx t Nothing

replaceAddressTx
    :: ( StoreRead m
       , StoreWrite m
       , MonadLoggerIO m
       )
    => TxData
    -> BlockRef
    -> m ()
replaceAddressTx t new =
    forM_ (txDataAddresses t) $ \a -> do
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
    :: (StoreRead m, StoreWrite m, MonadLoggerIO m)
    => OutPoint
    -> TxOut
    -> BlockRef
    -> BlockRef
    -> m ()
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

confTx
    :: (StoreRead m, StoreWrite m, MonadLoggerIO m)
    => TxData
    -> Maybe BlockRef
    -> m ()
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
    td = t { txDataBlock = new }

deleteTx
    :: ( StoreRead m
       , StoreWrite m
       , MonadLoggerIO m
       )
    => Bool -- ^ only delete transaction if unconfirmed
    -> Bool -- ^ only delete RBF
    -> TxHash
    -> m () -- ^ deleted transactions
deleteTx memonly rbfcheck txhash =
    getActiveTxData txhash >>= \case
        Nothing ->
            $(logDebugS) "BlockStore" $
            "Already deleted or not found: "
            <> txHashToHex txhash
        Just td
            | memonly && confirmed (txDataBlock td) -> do
                $(logDebugS) "BlockStore" $
                    "Will not delete confirmed tx: "
                    <> txHashToHex txhash
                throwIO TxConfirmed
            | rbfcheck ->
                isRBF (txDataBlock td) (txData td) >>= \case
                    True -> go
                    False -> do
                        $(logDebugS) "BlockStore" $
                            "Will not delete non-RBF tx: "
                            <> txHashToHex txhash
                        throwIO DoubleSpend
            | otherwise -> go
  where
    go = do
        $(logDebugS) "BlockStore" $
            "Deleting tx: " <> txHashToHex txhash
        ss <- nub' . map spenderHash . I.elems <$>
              getSpenders txhash
        forM_ ss $ \s -> do
            $(logDebugS) "BlockStore" $
                "Need to delete child tx: " <> txHashToHex s
            deleteTx True rbfcheck s
        getActiveTxData txhash >>= \case
            Just td' -> commitDelTx td'
            Nothing -> return ()

commitDelTx
    :: (StoreRead m, StoreWrite m, MonadLoggerIO m)
    => TxData
    -> m ()
commitDelTx = commitModTx False []

commitAddTx
    :: (StoreRead m, StoreWrite m, MonadLoggerIO m)
    => [Unspent]
    -> TxData
    -> m ()
commitAddTx = commitModTx True

commitModTx
    :: (StoreRead m, StoreWrite m, MonadLoggerIO m)
    => Bool
    -> [Unspent]
    -> TxData
    -> m ()
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

updateMempool :: (StoreRead m, StoreWrite m) => TxData -> m ()
updateMempool td = do
    mp <- getMempool
    setMempool (f mp)
  where
    f mp | txDataDeleted td || confirmed (txDataBlock td) =
           filter ((/= txHash (txData td)) . txRefHash) mp
         | otherwise =
           sortOn Down $ TxRef (txDataBlock td) (txHash (txData td)) : mp

spendOutputs :: (StoreRead m, StoreWrite m) => [Unspent] -> TxData -> m ()
spendOutputs us td =
    zipWithM_ (spendOutput (txHash (txData td))) [0 ..] us

addOutputs :: (StoreRead m, StoreWrite m, MonadLoggerIO m) => TxData -> m ()
addOutputs td =
    zipWithM_
        (addOutput (txDataBlock td) . OutPoint (txHash (txData td)))
        [0 ..]
        (txOut (txData td))

isRBF
    :: (StoreRead m, MonadLoggerIO m)
    => BlockRef
    -> Tx
    -> m Bool
isRBF br tx
    | confirmed br = return False
    | otherwise =
        getNetwork >>= \net ->
            if getReplaceByFee net
                then go
                else return False
  where
    go | any ((< 0xffffffff - 1) . txInSequence) (txIn tx) = return True
       | otherwise =
         let hs = nub' $ map (outPointHash . prevOutput) (txIn tx)
             ck [] = return False
             ck (h:hs') =
                 getActiveTxData h >>= \case
                 Nothing -> do
                     $(logErrorS) "BlockStore" $
                         "Parent transaction not found: " <> txHashToHex h
                     error $ "Parent transaction not found: " <> show h
                 Just t
                     | confirmed (txDataBlock t) -> ck hs'
                     | txDataRBF t -> return True
                     | otherwise -> ck hs'
         in ck hs

addOutput
    :: (StoreRead m, StoreWrite m, MonadLoggerIO m)
    => BlockRef
    -> OutPoint
    -> TxOut
    -> m ()
addOutput = modOutput True

delOutput
    :: (StoreRead m, StoreWrite m)
    => BlockRef
    -> OutPoint
    -> TxOut
    -> m ()
delOutput = modOutput False

modOutput
    :: (StoreRead m, StoreWrite m)
    => Bool
    -> BlockRef
    -> OutPoint
    -> TxOut
    -> m ()
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

delOutputs :: (StoreRead m, StoreWrite m) => TxData -> m ()
delOutputs td =
    forM_ (zip [0..] outs) $ \(i, o) -> do
        let op = OutPoint (txHash (txData td)) i
        delOutput (txDataBlock td) op o
  where
    outs = txOut (txData td)

getImportTxData
    :: ( StoreRead m
       , MonadLoggerIO m
       )
    => TxHash
    -> m TxData
getImportTxData th =
    getActiveTxData th >>= \case
        Nothing -> do
            $(logDebugS) "BlockStore" $ "Tx not found: " <> txHashToHex th
            throwIO TxNotFound
        Just d -> return d

getTxOut
    :: Word32
    -> Tx
    -> Maybe TxOut
getTxOut i tx = do
    guard (fromIntegral i < length (txOut tx))
    return $ txOut tx !! fromIntegral i

spendOutput
    :: (StoreRead m, StoreWrite m)
    => TxHash
    -> Word32
    -> Unspent
    -> m ()
spendOutput th ix u = do
    insertSpender (unspentPoint u) (Spender th ix)
    let pk = B.Short.fromShort (unspentScript u)
    case scriptToAddressBS pk of
        Left _ -> return ()
        Right a -> do
            decreaseBalance (confirmed (unspentBlock u)) a (unspentAmount u)
            deleteAddrUnspent a u
    deleteUnspent (unspentPoint u)

unspendOutputs :: (StoreRead m, StoreWrite m, MonadLoggerIO m)
               => TxData -> m ()
unspendOutputs td = mapM_ unspendOutput (prevOuts (txData td))

unspendOutput :: (StoreRead m, StoreWrite m, MonadLoggerIO m)
              => OutPoint -> m ()
unspendOutput op = do
    t <- getActiveTxData (outPointHash op) >>= \case
        Nothing -> do
            $(logErrorS) "BlockStore" $
                "Could not find tx data: "
                <> txHashToHex (outPointHash op)
            error $
                "Could not find tx data: "
                <> show (outPointHash op)
        Just t -> return t
    o <- case getTxOut (outPointIndex op) (txData t) of
        Nothing -> do
            $(logErrorS) "BlockStore" $
                "Could not find output: " <> showOutput op
            error $ "Could not find output: " <> show op
        Just o -> return o
    deleteSpender op
    let m = eitherToMaybe (scriptToAddressBS (scriptOutput o))
        u = Unspent { unspentAmount = outValue o
                    , unspentBlock = txDataBlock t
                    , unspentScript = B.Short.toShort (scriptOutput o)
                    , unspentPoint = op
                    , unspentAddress = m
                    }
    insertUnspent u
    forM_ m $ \a -> do
        insertAddrUnspent a u
        increaseBalance (confirmed (unspentBlock u)) a (outValue o)

modifyReceived
    :: (StoreRead m, StoreWrite m)
    => Address
    -> (Word64 -> Word64)
    -> m ()
modifyReceived a f =
    getBalance a >>= \b ->
    setBalance b {balanceTotalReceived = f (balanceTotalReceived b)}

decreaseBalance
    :: (StoreRead m, StoreWrite m)
    => Bool
    -> Address
    -> Word64
    -> m ()
decreaseBalance conf = modBalance conf False

increaseBalance
    :: (StoreRead m, StoreWrite m)
    => Bool
    -> Address
    -> Word64
    -> m ()
increaseBalance conf = modBalance conf True

modBalance
    :: (StoreRead m, StoreWrite m)
    => Bool -- ^ confirmed
    -> Bool -- ^ add
    -> Address
    -> Word64
    -> m ()
modBalance conf add a val =
    getBalance a >>= \b -> setBalance ((g . f) b)
  where
    g b = b { balanceUnspentCount = m 1 (balanceUnspentCount b) }
    f b | conf = b { balanceAmount = m val (balanceAmount b) }
        | otherwise = b { balanceZero = m val (balanceZero b) }
    m | add = (+)
      | otherwise = subtract

modAddressCount :: (StoreRead m, StoreWrite m) => Bool -> Address -> m ()
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

showOutput :: OutPoint -> Text
showOutput OutPoint {outPointHash = h, outPointIndex = i} =
    txHashToHex h <> "/" <> cs (show i)

prevOuts :: Tx -> [OutPoint]
prevOuts tx = filter (/= nullOutPoint) (map prevOutput (txIn tx))
