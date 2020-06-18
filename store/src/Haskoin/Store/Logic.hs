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
    , getOldMempool
    , revertBlock
    , importBlock
    , newMempoolTx
    , deleteUnconfirmedTx
    ) where

import           Control.Monad                 (forM, forM_, guard, void, when,
                                                zipWithM_, (<=<), (>=>))
import           Control.Monad.Except          (ExceptT (..), MonadError,
                                                runExceptT, throwError)
import           Control.Monad.Logger          (LoggingT (..),
                                                MonadLoggerIO (..), logDebugS,
                                                logErrorS)
import           Control.Monad.Reader          (ReaderT (ReaderT), runReaderT)
import           Control.Monad.Trans           (lift)
import qualified Data.ByteString               as B
import qualified Data.ByteString.Short         as B.Short
import           Data.Either                   (rights)
import qualified Data.IntMap.Strict            as I
import           Data.List                     (nub, sortOn)
import           Data.Maybe                    (catMaybes, fromMaybe, isJust,
                                                isNothing, mapMaybe)
import           Data.Ord                      (Down (Down))
import           Data.Serialize                (encode)
import           Data.Word                     (Word32, Word64)
import           Haskoin                       (Address, Block (..), BlockHash,
                                                BlockHeader (..),
                                                BlockNode (..), Network (..),
                                                OutPoint (..), Tx (..), TxHash,
                                                TxIn (..), TxOut (..),
                                                blockHashToHex, computeSubsidy,
                                                eitherToMaybe, genesisBlock,
                                                genesisNode, headerHash,
                                                isGenesis, nullOutPoint,
                                                scriptToAddressBS, txHash,
                                                txHashToHex)
import           Haskoin.Store.Common          (StoreRead (..), StoreWrite (..),
                                                getActiveTxData, nub', sortTxs)
import           Haskoin.Store.Data            (Balance (..), BlockData (..),
                                                BlockRef (..), Prev (..),
                                                Spender (..), TxData (..),
                                                TxRef (..), UnixTime,
                                                Unspent (..), confirmed)
import           Haskoin.Store.Database.Writer (MemoryTx, WriterT, runTx)
import           UnliftIO                      (Exception, MonadIO, async,
                                                liftIO, wait)

type MonadImport m =
    ( MonadError ImportException m
    , MonadLoggerIO m
    )

type MonadMemory = ExceptT ImportException MemoryTx

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

runMonadMemory :: MonadImport m => MonadMemory a -> WriterT m a
runMonadMemory f =
    runTx (runExceptT f) >>= \case
        Left e -> throwError e
        Right x -> return x

initBest :: MonadImport m => WriterT m ()
initBest = do
    $(logDebugS) "BlockStore" "Initializing best block"
    net <- getNetwork
    m <- getBestBlock
    when (isNothing m) . void $ do
        $(logDebugS) "BlockStore" "Importing Genesis block"
        importBlock (genesisBlock net) (genesisNode net)

getOldMempool :: StoreRead m => UnixTime -> m [TxHash]
getOldMempool now =
    map txRefHash . filter f <$> getMempool
  where
    f = (< now - 3600 * 72) . memRefTime . txRefBlock

newMempoolTx :: MonadImport m => Tx -> UnixTime -> WriterT m Bool
newMempoolTx tx w =
    getActiveTxData (txHash tx) >>= \case
        Just _ -> return False
        Nothing -> do
            freeOutputs True True [tx]
            preLoadMemory [tx]
            rbf <- isRBF (MemRef w) tx
            checkNewTx tx
            runMonadMemory $ importTx (MemRef w) w rbf tx
            return True

preLoadMemory :: MonadLoggerIO m => [Tx] -> WriterT m ()
preLoadMemory txs = do
    $(logDebugS) "BlockStore" "Pre-loading memory"
    ReaderT $ liftIO . runReaderT go
  where
    go = do
        prev_asyncs <- mapM (async . loadPrevOutputs) txs
        out_asyncs <- mapM (async . loadOutputBalances) txs
        mapM_ wait $ prev_asyncs <> out_asyncs
        runTx . setMempool =<< getMempool

bestBlockData :: MonadImport m => WriterT m BlockData
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

revertBlock :: MonadImport m => BlockHash -> WriterT m ()
revertBlock bh = do
    bd <- bestBlockData >>= \b ->
        if headerHash (blockDataHeader b) == bh
        then return b
        else do
            $(logErrorS) "BlockStore" $
                "Cannot revert non-head block: " <> blockHashToHex bh
            throwError BlockNotBest
    tds <- mapM getImportTxData (blockDataTxs bd)
    preLoadMemory $ map txData tds
    runTx $ do
        setBest (prevBlock (blockDataHeader bd))
        insertBlock bd {blockDataMainChain = False}
        forM_ (tail tds) unConfirmTx
    deleteConfirmedTx (txHash (txData (head tds)))

checkNewBlock :: MonadImport m => Block -> BlockNode -> WriterT m ()
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

importOrConfirm :: MonadImport m => BlockNode -> [Tx] -> WriterT m ()
importOrConfirm bn txs = do
    freeOutputs True False txs
    preLoadMemory txs
    mapM_ (uncurry action) (sortTxs txs)
  where
    br i = BlockRef {blockRefHeight = nodeHeight bn, blockRefPos = i}
    bn_time = fromIntegral . blockTimestamp $ nodeHeader bn
    action i tx =
        testPresent tx >>= \case
            False -> import_it i tx
            True -> confirm_it i tx
    confirm_it i tx =
        getActiveTxData (txHash tx) >>= \case
            Just t -> do
                $(logDebugS) "BlockStore" $
                    "Confirming tx: "
                    <> txHashToHex (txHash tx)
                runTx $ confTx t (Just (br i))
                return Nothing
            Nothing -> do
                $(logErrorS) "BlockStore" $
                    "Cannot find tx to confirm: "
                    <> txHashToHex (txHash tx)
                throwError TxNotFound
    import_it i tx = do
        $(logDebugS) "BlockStore" $
            "Importing tx: " <> txHashToHex (txHash tx)
        runMonadMemory $ importTx (br i) bn_time False tx
        return Nothing

importBlock :: MonadImport m => Block -> BlockNode -> WriterT m ()
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

checkNewTx :: MonadImport m => Tx -> WriterT m ()
checkNewTx tx = do
    us <- runTx $ getUnspentOutputs tx
    when (unique_inputs < length (txIn tx)) $ do
        $(logErrorS) "BlockStore" $
            "Transaction spends same output twice: "
            <> txHashToHex (txHash tx)
        throwError DuplicatePrevOutput
    when (isCoinbase tx) $ do
        $(logErrorS) "BlockStore" $
            "Coinbase cannot be imported into mempool: "
            <> txHashToHex (txHash tx)
        throwError UnexpectedCoinbase
    when (orphanTest us tx) $ do
        $(logErrorS) "BlockStore" $
            "Orphan: " <> txHashToHex (txHash tx)
        throwError Orphan
    when (outputs > unspents us) $ do
        $(logErrorS) "BlockStore" $
            "Insufficient funds for tx: " <> txHashToHex (txHash tx)
        throwError InsufficientFunds
  where
    unspents = sum . map unspentAmount
    outputs = sum (map outValue (txOut tx))
    unique_inputs = length (nub' (map prevOutput (txIn tx)))

orphanTest :: [Unspent] -> Tx -> Bool
orphanTest us tx = length (prevOuts tx) > length us

getUnspentOutputs :: StoreRead m => Tx -> m [Unspent]
getUnspentOutputs tx = catMaybes <$> mapM getUnspent (prevOuts tx)

loadPrevOutputs :: MonadIO m => Tx -> WriterT m ()
loadPrevOutputs tx =
    mapM_ go ops
  where
    ops = prevOuts tx
    go op =
        getUnspent op >>= \case
            Just u -> insert_unspent u
            Nothing -> do
                insert_tx (outPointHash op)
                insert_spender op
    insert_tx h = do
        mt <- getActiveTxData h
        forM_ mt $ \t -> do
            let addrs = get_addrs (txData t)
            bals <- mapM getBalance addrs
            runTx $ do
                insertTx t
                mapM_ setBalance bals
    get_addrs tx' =
        let f i o =
                if OutPoint (txHash tx') i `elem` ops
                then eitherToMaybe . scriptToAddressBS $ scriptOutput o
                else Nothing
        in catMaybes $ zipWith f [0..] (txOut tx')
    insert_spender op =
        getSpender op >>= runTx . mapM_ (insertSpender op)
    insert_unspent u = do
        mbal <- mapM getBalance (unspentAddress u)
        runTx $ do
            insertUnspent u
            mapM_ setBalance mbal

loadOutputBalances :: MonadIO m => Tx -> WriterT m ()
loadOutputBalances tx = do
    let f = eitherToMaybe . scriptToAddressBS . scriptOutput
    let addrs = mapMaybe f (txOut tx)
    forM_ addrs $ runTx . setBalance <=< getBalance

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
    -> MonadMemory ()
importTx br tt rbf tx = do
    us <- lift $ getUnspentOutputs tx
    let td = prepareTxData rbf br tt us tx
    lift $ commitAddTx us td

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

adjustAddressOutput :: OutPoint -> TxOut -> BlockRef -> BlockRef -> MemoryTx ()
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
    :: MonadImport m
    => Bool -- ^ only delete transaction if unconfirmed
    -> Bool -- ^ only delete RBF
    -> [Tx]
    -> WriterT m ()
freeOutputs memonly rbfcheck txs = do
    as <- mapM async_get txs
    txs' <- map_asyncs as
    mapM_ (deleteSingleTx . txHash) txs'
  where
    map_asyncs as =
        sequence <$> mapM wait as >>= \case
            Right txs' ->
                return $ reverse
                       $ map snd
                       $ sortTxs
                       $ nub'
                       $ concat txs'
            Left e -> throwError e
    async_get tx = do
        g <- askLoggerIO
        ReaderT $ \r ->
            liftIO $ async $
            runLoggingT (runReaderT (get_chain tx) r) g
    get_chain tx =
        fmap (fmap concat . sequence) $
        forM (nub' (prevOuts tx)) $
        getSpender >=> \case
            Nothing ->
                return (Right [])
            Just Spender {spenderHash = s} ->
                map_chain tx <$> getChain memonly rbfcheck s
    map_chain tx = \case
        Right (tx' : _)
            | tx == tx' -> Right []
        Right ts -> Right ts
        Left e -> Left e

deleteConfirmedTx :: MonadImport m => TxHash -> WriterT m ()
deleteConfirmedTx = deleteTx False False

deleteUnconfirmedTx :: MonadImport m => Bool -> TxHash -> WriterT m ()
deleteUnconfirmedTx = deleteTx True

deleteTx
    :: MonadImport m
    => Bool -- ^ only delete transaction if unconfirmed
    -> Bool -- ^ only delete RBF
    -> TxHash
    -> WriterT m ()
deleteTx memonly rbfcheck txhash =
    getChain memonly rbfcheck txhash >>= \case
        Left e    -> throwError e
        Right txs -> mapM_ (deleteSingleTx . txHash) txs

getChain
    :: (MonadLoggerIO m, StoreRead m)
    => Bool -- ^ only delete transaction if unconfirmed
    -> Bool -- ^ only delete RBF
    -> TxHash
    -> m (Either ImportException [Tx])
getChain memonly rbfcheck txhash =
    runExceptT (go txhash)
  where
    go th =
        fmap (reverse . map snd . sortTxs . nub') $
        lift (getActiveTxData th) >>= \case
            Nothing ->
                return []
            Just td
                | memonly && confirmed (txDataBlock td) -> do
                      $(logErrorS) "BlockStore" $
                          "Transaction already confirmed: "
                          <> txHashToHex th
                      throwError TxConfirmed
                | rbfcheck ->
                    lift (isRBF (txDataBlock td) (txData td)) >>= \case
                        True -> get_it td
                        False -> do
                            $(logErrorS) "BlockStore" $
                                "Double-spending transaction: "
                                <> txHashToHex th
                            throwError DoubleSpend
                | otherwise -> get_it td
    get_it td = do
        let th = txHash (txData td)
        spenders <-
            nub' . map spenderHash . I.elems
            <$> lift (getSpenders th)
        chains <- concat <$> mapM go spenders
        return $ txData td : chains

deleteSingleTx :: MonadImport m => TxHash -> WriterT m ()
deleteSingleTx th =
    getActiveTxData th >>= \case
        Nothing ->
            $(logDebugS) "BlockStore" $
                "Already deleted: " <> txHashToHex th
        Just td -> do
            $(logDebugS) "BlockStore" $
                "Deleting tx: " <> txHashToHex th
            preload td
            runTx $ commitDelTx td
  where
    preload td = do
        let ths = nub' $ map outPointHash (prevOuts (txData td))
        tds <- forM ths $ \h ->
            getActiveTxData h >>= \case
                Nothing -> do
                    $(logDebugS) "BlockStore" $
                        "Could not get prev tx: " <> txHashToHex h
                    throwError TxNotFound
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

isRBF :: StoreRead m
      => BlockRef
      -> Tx
      -> m Bool
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
             carry_on
    carry_on =
        let hs = nub' $ map (outPointHash . prevOutput) (txIn tx)
            ck [] = return False
            ck (h : hs') =
                getActiveTxData h >>= \case
                    Nothing -> return False
                    Just t
                        | confirmed (txDataBlock t) -> ck hs'
                        | txDataRBF t -> return True
                        | otherwise -> ck hs'
         in ck hs

addOutput :: BlockRef -> OutPoint -> TxOut -> MemoryTx ()
addOutput = modOutput True

delOutput :: BlockRef -> OutPoint -> TxOut -> MemoryTx ()
delOutput = modOutput False

modOutput :: Bool -> BlockRef -> OutPoint -> TxOut -> MemoryTx ()
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

getImportTxData :: MonadImport m => TxHash -> WriterT m TxData
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

decreaseBalance :: Bool -> Address -> Word64 -> MemoryTx ()
decreaseBalance conf = modBalance conf False

increaseBalance :: Bool -> Address -> Word64 -> MemoryTx ()
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

testPresent :: StoreRead m => Tx -> m Bool
testPresent tx =
    case prevOuts tx of
        [] -> isJust <$> getActiveTxData (txHash tx)
        op : _ -> getSpender op >>= \case
            Nothing ->
                return False
            Just Spender { spenderHash = s } ->
                return $ s == txHash tx
