{-# LANGUAGE ConstraintKinds   #-}
{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections     #-}
module Haskoin.Store.Logic
    ( ImportException (..)
    , MonadImport
    , initBest
    , revertBlock
    , importBlock
    , newMempoolTx
    , deleteUnconfirmedTx
    , streamThings
    , joinStreams
    ) where

import           Conduit               (ConduitT, await, lift, sealConduitT,
                                        yield, ($$++))
import           Control.Monad         (forM, forM_, guard, unless, void, when,
                                        zipWithM_)
import           Control.Monad.Except  (MonadError, throwError)
import           Control.Monad.Logger  (MonadLoggerIO (..), logDebugS,
                                        logErrorS)
import qualified Data.ByteString       as B
import           Data.Either           (rights)
import           Data.Function         (on)
import qualified Data.IntMap.Strict    as I
import           Data.List             (nub, sortBy)
import           Data.Maybe            (catMaybes, fromMaybe, isJust, isNothing,
                                        mapMaybe)
import           Data.Serialize        (encode)
import           Data.Word             (Word32, Word64)
import           Haskoin               (Address, Block (..), BlockHash,
                                        BlockHeader (..), BlockNode (..),
                                        Network (..), OutPoint (..), Tx (..),
                                        TxHash, TxIn (..), TxOut (..),
                                        blockHashToHex, computeSubsidy,
                                        eitherToMaybe, genesisBlock,
                                        genesisNode, headerHash, isGenesis,
                                        nullOutPoint, scriptToAddressBS, txHash,
                                        txHashToHex)
import           Haskoin.Store.Common
import           Haskoin.Store.Data    (Balance (..), BlockData (..),
                                        BlockRef (..), Prev (..), Spender (..),
                                        TxData (..), TxRef (..), UnixTime,
                                        Unspent (..), confirmed)
import           UnliftIO              (Exception)

type MonadImport m =
    ( MonadError ImportException m
    , MonadLoggerIO m
    , StoreReadBase m
    , StoreWrite m
    )

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

initBest :: MonadImport m => m ()
initBest = do
    $(logDebugS) "BlockStore" "Initializing best block"
    net <- getNetwork
    m <- getBestBlock
    when (isNothing m) . void $ do
        $(logDebugS) "BlockStore" "Importing Genesis block"
        importBlock (genesisBlock net) (genesisNode net)

getOldMempool :: StoreReadBase m => UnixTime -> m [TxHash]
getOldMempool now =
    map snd . filter ((< now - 3600 * 72) . fst) <$> getMempool

newMempoolTx :: MonadImport m => Tx -> UnixTime -> m Bool
newMempoolTx tx w =
    getActiveTxData (txHash tx) >>= \case
        Just _ ->
            return False
        Nothing -> do
            freeOutputs True True tx
            rbf <- isRBF (MemRef w) tx
            checkNewTx tx
            importTx (MemRef w) w rbf tx
            return True

bestBlockData :: MonadImport m => m BlockData
bestBlockData = do
    h <- getBestBlock >>= \case
        Nothing -> do
            $(logErrorS) "BlockStore" "Best block unknown"
            throwError BestBlockNotFound
        Just h -> return h
    getBlock h >>= \case
        Nothing -> do
            $(logErrorS) "BlockStore" "Best block not found"
            throwError BestBlockNotFound
        Just b -> return b

revertBlock :: MonadImport m => BlockHash -> m ()
revertBlock bh = do
    bd <- bestBlockData >>= \b ->
        if headerHash (blockDataHeader b) == bh
        then return b
        else do
            $(logErrorS) "BlockStore" $
                "Cannot revert non-head block: " <> blockHashToHex bh
            throwError BlockNotBest
    tds <- mapM getImportTxData (blockDataTxs bd)
    setBest (prevBlock (blockDataHeader bd))
    insertBlock bd {blockDataMainChain = False}
    forM_ (tail tds) unConfirmTx
    deleteConfirmedTx (txHash (txData (head tds)))

checkNewBlock :: MonadImport m => Block -> BlockNode -> m ()
checkNewBlock b n =
    getBestBlock >>= \case
        Nothing
            | isGenesis n -> return ()
            | otherwise -> do
                $(logErrorS) "BlockStore" $
                    "Cannot import non-genesis block: "
                    <> blockHashToHex (headerHash (blockHeader b))
                throwError BestBlockNotFound
        Just h
            | prevBlock (blockHeader b) == h -> return ()
            | otherwise -> do
                $(logErrorS) "BlockStore" $
                    "Block does not build on head: "
                    <> blockHashToHex (headerHash (blockHeader b))
                throwError PrevBlockNotBest

importOrConfirm :: MonadImport m => BlockNode -> [Tx] -> m ()
importOrConfirm bn txns = do
    mapM_ (freeOutputs True False . snd) (reverse txs)
    mapM_ (uncurry action) txs
  where
    txs = sortTxs txns
    br i = BlockRef {blockRefHeight = nodeHeight bn, blockRefPos = i}
    bn_time = fromIntegral . blockTimestamp $ nodeHeader bn
    action i tx =
        testPresent tx >>= \case
            False -> import_it i tx
            True  -> confirm_it i tx
    confirm_it i tx =
        getActiveTxData (txHash tx) >>= \case
            Just t -> do
                $(logDebugS) "BlockStore" $
                    "Confirming tx: "
                    <> txHashToHex (txHash tx)
                confirmTx t (br i)
                return Nothing
            Nothing -> do
                $(logErrorS) "BlockStore" $
                    "Cannot find tx to confirm: "
                    <> txHashToHex (txHash tx)
                throwError TxNotFound
    import_it i tx = do
        $(logDebugS) "BlockStore" $
            "Importing tx: " <> txHashToHex (txHash tx)
        importTx (br i) bn_time False tx
        return Nothing

importBlock :: MonadImport m => Block -> BlockNode -> m ()
importBlock b n = do
    $(logDebugS) "BlockStore" $
        "Checking new block: "
        <> blockHashToHex (headerHash (nodeHeader n))
    checkNewBlock b n
    $(logDebugS) "BlockStore" "Passed check"
    net <- getNetwork
    let subsidy = computeSubsidy net (nodeHeight n)
    bs <- getBlocksAtHeight (nodeHeight n)
    $(logDebugS) "BlockStore" $
        "Inserting block entries for: "
        <> blockHashToHex (headerHash (nodeHeader n))
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
    $(logDebugS) "BlockStore" $
        "Finished importing transactions for: "
        <> blockHashToHex (headerHash (nodeHeader n))
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

checkNewTx :: MonadImport m => Tx -> m ()
checkNewTx tx = do
    when (unique_inputs < length (txIn tx)) $ do
        $(logErrorS) "BlockStore" $
            "Transaction spends same output twice: "
            <> txHashToHex (txHash tx)
        throwError DuplicatePrevOutput
    us <- getUnspentOutputs tx
    when (any isNothing us) $ do
        $(logErrorS) "BlockStore" $
            "Orphan: " <> txHashToHex (txHash tx)
        throwError Orphan
    when (isCoinbase tx) $ do
        $(logErrorS) "BlockStore" $
            "Coinbase cannot be imported into mempool: "
            <> txHashToHex (txHash tx)
        throwError UnexpectedCoinbase
    when (length (prevOuts tx) > length us) $ do
        $(logErrorS) "BlockStore" $
            "Orphan: " <> txHashToHex (txHash tx)
        throwError Orphan
    when (outputs > unspents us) $ do
        $(logErrorS) "BlockStore" $
            "Insufficient funds for tx: " <> txHashToHex (txHash tx)
        throwError InsufficientFunds
  where
    unspents = sum . map unspentAmount . catMaybes
    outputs = sum (map outValue (txOut tx))
    unique_inputs = length (nub' (map prevOutput (txIn tx)))

getUnspentOutputs :: StoreReadBase m => Tx -> m [Maybe Unspent]
getUnspentOutputs tx = mapM getUnspent (prevOuts tx)

prepareTxData :: Bool -> BlockRef -> Word64 -> Tx -> [Unspent] -> TxData
prepareTxData rbf br tt tx us =
    TxData { txDataBlock = br
           , txData = tx
           , txDataPrevs = ps
           , txDataDeleted = False
           , txDataRBF = rbf
           , txDataTime = tt
           }
  where
    mkprv u = Prev (unspentScript u) (unspentAmount u)
    ps = I.fromList $ zip [0 ..] $ map mkprv us

importTx
    :: MonadImport m
    => BlockRef
    -> Word64 -- ^ unix time
    -> Bool -- ^ RBF
    -> Tx
    -> m ()
importTx br tt rbf tx = do
    mus <- getUnspentOutputs tx
    us <- forM mus $ \case
        Nothing -> do
            $(logErrorS) "BlockStore" $
                "Attempted to import a tx missing UTXO: "
                <> txHashToHex (txHash tx)
            throwError Orphan
        Just u -> return u
    let td = prepareTxData rbf br tt tx us
    commitAddTx td

unConfirmTx :: MonadImport m => TxData -> m ()
unConfirmTx t = confTx t Nothing

confirmTx :: MonadImport m => TxData -> BlockRef -> m ()
confirmTx t br = confTx t (Just br)

replaceAddressTx :: MonadImport m => TxData -> BlockRef -> m ()
replaceAddressTx t new = forM_ (txDataAddresses t) $ \a -> do
    deleteAddrTx
        a
        TxRef { txRefBlock = txDataBlock t
              , txRefHash = txHash (txData t) }
    insertAddrTx
        a
        TxRef { txRefBlock = new
              , txRefHash = txHash (txData t) }

adjustAddressOutput :: MonadImport m
                    => OutPoint -> TxOut -> BlockRef -> BlockRef -> m ()
adjustAddressOutput op o old new = do
    let pk = scriptOutput o
    getUnspent op >>= \case
        Nothing -> return ()
        Just u -> do
            unless (unspentBlock u == old) $
                error $ "Existing unspent block bad for output: " <> show op
            replace_unspent pk
  where
    replace_unspent pk = do
        let ma = eitherToMaybe (scriptToAddressBS pk)
        deleteUnspent op
        insertUnspent
            Unspent
                { unspentBlock = new
                , unspentPoint = op
                , unspentAmount = outValue o
                , unspentScript = pk
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
                , unspentScript = pk
                , unspentAddress = Just a
                }
        insertAddrUnspent
            a
            Unspent
                { unspentBlock = new
                , unspentPoint = op
                , unspentAmount = outValue o
                , unspentScript = pk
                , unspentAddress = Just a
                }
        decreaseBalance (confirmed old) a (outValue o)
        increaseBalance (confirmed new) a (outValue o)

confTx :: MonadImport m => TxData -> Maybe BlockRef -> m ()
confTx t mbr = do
    replaceAddressTx t new
    forM_ (zip [0 ..] (txOut (txData t))) $ \(n, o) -> do
        let op = OutPoint (txHash (txData t)) n
        adjustAddressOutput op o old new
    rbf <- isRBF new (txData t)
    let td = t { txDataBlock = new, txDataRBF = rbf }
    insertTx td
    updateMempool td
  where
    new = fromMaybe (MemRef (txDataTime t)) mbr
    old = txDataBlock t

freeOutputs
    :: MonadImport m
    => Bool -- ^ only delete transaction if unconfirmed
    -> Bool -- ^ only delete RBF
    -> Tx
    -> m ()
freeOutputs memonly rbfcheck tx =
    forM_ (prevOuts tx) $ \op ->
    getUnspent op >>= \u -> when (isNothing u) $
    getSpender op >>= \p -> forM_ p $ \s ->
    unless (spenderHash s == txHash tx) $
    deleteTx memonly rbfcheck (spenderHash s)

deleteConfirmedTx :: MonadImport m => TxHash -> m ()
deleteConfirmedTx = deleteTx False False

deleteUnconfirmedTx :: MonadImport m => Bool -> TxHash -> m ()
deleteUnconfirmedTx rbfcheck th =
    getActiveTxData th >>= \case
        Just _ -> deleteTx True rbfcheck th
        Nothing -> $(logDebugS) "BlockStore" $
                   "Not found or already deleted: " <> txHashToHex th

deleteTx :: MonadImport m
         => Bool -- ^ only delete transaction if unconfirmed
         -> Bool -- ^ only delete RBF
         -> TxHash
         -> m ()
deleteTx memonly rbfcheck th =
    getChain memonly rbfcheck th >>=
    mapM_ (deleteSingleTx . txHash)

getChain :: MonadImport m
         => Bool -- ^ only delete transaction if unconfirmed
         -> Bool -- ^ only delete RBF
         -> TxHash
         -> m [Tx]
getChain memonly rbfcheck th =
    fmap sort_clean $
    getActiveTxData th >>= \case
        Nothing -> do
            $(logErrorS) "BlockStore" $
                "Transaction not found: " <> txHashToHex th
            throwError TxNotFound
        Just td
          | memonly && confirmed (txDataBlock td) -> do
            $(logErrorS) "BlockStore" $
                "Transaction already confirmed: "
                <> txHashToHex th
            throwError TxConfirmed
          | rbfcheck ->
            isRBF (txDataBlock td) (txData td) >>= \case
                True -> go td
                False -> do
                    $(logErrorS) "BlockStore" $
                        "Double-spending transaction: "
                        <> txHashToHex th
                    throwError DoubleSpend
          | otherwise -> go td
  where
    sort_clean = reverse . map snd . sortTxs . nub'
    go td = do
        let tx = txData td
        ss <- nub' . map spenderHash . I.elems <$> getSpenders th
        xs <- concat <$> mapM (getChain memonly rbfcheck) ss
        return $ tx : xs

deleteSingleTx :: MonadImport m => TxHash -> m ()
deleteSingleTx th =
    getActiveTxData th >>= \case
        Nothing -> do
            $(logErrorS) "BlockStore" $
                "Already deleted: " <> txHashToHex th
            throwError TxNotFound
        Just td -> do
            $(logDebugS) "BlockStore" $
                "Deleting tx: " <> txHashToHex th
            getSpenders th >>= \case
                m | I.null m -> commitDelTx td
                  | otherwise -> do
                        $(logErrorS) "BlockStore" $
                            "Tried to delete spent tx: "
                            <> txHashToHex th
                        throwError TxSpent

commitDelTx :: MonadImport m => TxData -> m ()
commitDelTx = commitModTx False

commitAddTx :: MonadImport m => TxData -> m ()
commitAddTx = commitModTx True

commitModTx :: MonadImport m => Bool -> TxData -> m ()
commitModTx add tx_data = do
    mapM_ mod_addr_tx (txDataAddresses td)
    mod_outputs
    mod_unspent
    insertTx td
    updateMempool td
  where
    tx = txData td
    br = txDataBlock td
    td = tx_data { txDataDeleted = not add }
    tx_ref = TxRef br (txHash tx)
    mod_addr_tx a
      | add = do
            insertAddrTx a tx_ref
            modAddressCount add a
      | otherwise = do
            deleteAddrTx a tx_ref
            modAddressCount add a
    mod_unspent
      | add = spendOutputs tx
      | otherwise = unspendOutputs tx
    mod_outputs
      | add = addOutputs br tx
      | otherwise = delOutputs br tx

updateMempool :: MonadImport m => TxData -> m ()
updateMempool td@TxData{txDataDeleted = True} =
    deleteFromMempool (txHash (txData td))
updateMempool td@TxData{txDataDeleted = False, txDataBlock = MemRef t} =
    addToMempool (txHash (txData td)) t
updateMempool td@TxData{txDataBlock = BlockRef{}} =
    deleteFromMempool (txHash (txData td))

spendOutputs :: MonadImport m => Tx -> m ()
spendOutputs tx =
    zipWithM_ (spendOutput (txHash tx)) [0 ..] (prevOuts tx)

addOutputs :: MonadImport m => BlockRef -> Tx -> m ()
addOutputs br tx =
    zipWithM_ (addOutput br . OutPoint (txHash tx)) [0 ..] (txOut tx)

isRBF :: StoreReadBase m
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
       | otherwise = carry_on
    carry_on =
        let hs = nub' $ map (outPointHash . prevOutput) (txIn tx)
            ck [] = return False
            ck (h : hs') =
                getActiveTxData h >>= \case
                    Nothing -> return False
                    Just t | confirmed (txDataBlock t) -> ck hs'
                           | txDataRBF t -> return True
                           | otherwise -> ck hs'
         in ck hs

addOutput :: MonadImport m => BlockRef -> OutPoint -> TxOut -> m ()
addOutput = modOutput True

delOutput :: MonadImport m => BlockRef -> OutPoint -> TxOut -> m ()
delOutput = modOutput False

modOutput :: MonadImport m => Bool -> BlockRef -> OutPoint -> TxOut -> m ()
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
    u = Unspent { unspentScript = scriptOutput o
                , unspentBlock = br
                , unspentPoint = op
                , unspentAmount = outValue o
                , unspentAddress = ma
                }
    mod_unspent | add = insertUnspent u
                | otherwise = deleteUnspent op
    mod_addr_unspent | add = insertAddrUnspent
                     | otherwise = deleteAddrUnspent

delOutputs :: MonadImport m => BlockRef -> Tx -> m ()
delOutputs br tx =
    forM_ (zip [0..] (txOut tx)) $ \(i, o) -> do
        let op = OutPoint (txHash tx) i
        delOutput br op o

getImportTxData :: MonadImport m => TxHash -> m TxData
getImportTxData th =
    getActiveTxData th >>= \case
        Nothing -> do
            $(logDebugS) "BlockStore" $ "Tx not found: " <> txHashToHex th
            throwError TxNotFound
        Just d -> return d

getTxOut :: Word32 -> Tx -> Maybe TxOut
getTxOut i tx = do
    guard (fromIntegral i < length (txOut tx))
    return $ txOut tx !! fromIntegral i

spendOutput :: MonadImport m => TxHash -> Word32 -> OutPoint -> m ()
spendOutput th ix op = do
    u <- getUnspent op >>= \case
        Just u  -> return u
        Nothing -> error $ "Could not find UTXO to spend: " <> show op
    deleteUnspent op
    insertSpender op (Spender th ix)
    let pk = unspentScript u
    forM_ (scriptToAddressBS pk) $ \a -> do
        decreaseBalance
            (confirmed (unspentBlock u))
            a
            (unspentAmount u)
        deleteAddrUnspent a u

unspendOutputs :: MonadImport m => Tx -> m ()
unspendOutputs = mapM_ unspendOutput . prevOuts

unspendOutput :: MonadImport m => OutPoint -> m ()
unspendOutput op = do
    t <- getActiveTxData (outPointHash op) >>= \case
        Nothing -> error $ "Could not find tx data: " <> show (outPointHash op)
        Just t  -> return t
    let o = fromMaybe
            (error ("Could not find output: " <> show op))
            (getTxOut (outPointIndex op) (txData t))
        m = eitherToMaybe (scriptToAddressBS (scriptOutput o))
        u = Unspent { unspentAmount = outValue o
                    , unspentBlock = txDataBlock t
                    , unspentScript = scriptOutput o
                    , unspentPoint = op
                    , unspentAddress = m
                    }
    deleteSpender op
    insertUnspent u
    forM_ m $ \a -> do
        insertAddrUnspent a u
        increaseBalance (confirmed (unspentBlock u)) a (outValue o)

modifyReceived :: MonadImport m => Address -> (Word64 -> Word64) -> m ()
modifyReceived a f = do
    b <- getDefaultBalance a
    setBalance b { balanceTotalReceived = f (balanceTotalReceived b) }

decreaseBalance :: MonadImport m => Bool -> Address -> Word64 -> m ()
decreaseBalance conf = modBalance conf False

increaseBalance :: MonadImport m => Bool -> Address -> Word64 -> m ()
increaseBalance conf = modBalance conf True

modBalance :: MonadImport m
           => Bool -- ^ confirmed
           -> Bool -- ^ add
           -> Address
           -> Word64
           -> m ()
modBalance conf add a val = do
    b <- getDefaultBalance a
    setBalance $ (g . f) b
  where
    g b = b { balanceUnspentCount = m 1 (balanceUnspentCount b) }
    f b | conf = b { balanceAmount = m val (balanceAmount b) }
        | otherwise = b { balanceZero = m val (balanceZero b) }
    m | add = (+)
      | otherwise = subtract

modAddressCount :: MonadImport m => Bool -> Address -> m ()
modAddressCount add a = do
    b <- getDefaultBalance a
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

testPresent :: StoreReadBase m => Tx -> m Bool
testPresent tx = isJust <$> getActiveTxData (txHash tx)

streamThings :: Monad m
             => (Limits -> m [a])
             -> (a -> TxHash)
             -> Limits
             -> ConduitT () a m ()
streamThings f g l =
    lift (f l{limit = 50}) >>= \case
    [] -> return ()
    ls -> do
        mapM yield ls
        go (last ls)
  where
    go x =
        lift (f (Limits 50 0 (Just (AtTx (g x))))) >>= \case
        [] -> return ()
        ls -> do
            case dropWhile ((== g x) . g) ls of
                [] -> return ()
                ls' -> do
                    mapM yield ls'
                    go (last ls')

joinStreams :: Monad m
            => (a -> a -> Ordering)
            -> [ConduitT () a m ()]
            -> ConduitT () a m ()
joinStreams c xs = do
    let ss = map sealConduitT xs
    ys <- mapMaybe j <$>
          lift (traverse ($$++ await) ss)
    go Nothing ys
  where
    j (x, y) = (,) x <$> y
    go m ys =
        case sortBy (c `on` snd) ys of
        [] -> return ()
        (i,x):ys' -> do
            case m of
                Nothing -> yield x
                Just x'
                  | c x x' == EQ -> return ()
                  | otherwise -> yield x
            j <$> lift (i $$++ await) >>= \case
                Nothing -> go (Just x) ys'
                Just y -> go (Just x) (y:ys')
