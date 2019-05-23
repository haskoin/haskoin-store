{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE MultiWayIf        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
module Network.Haskoin.Store.Logic where

import           Conduit
import           Control.Monad
import           Control.Monad.Except
import           Control.Monad.Logger
import qualified Data.ByteString                     as B
import qualified Data.ByteString.Short               as B.Short
import           Data.Either                         (rights)
import qualified Data.IntMap.Strict                  as I
import           Data.List
import           Data.Maybe
import           Data.Serialize
import           Data.String
import           Data.String.Conversions             (cs)
import           Data.Text                           (Text)
import           Data.Word
import           Database.RocksDB
import           Haskoin
import           Network.Haskoin.Block.Headers       (computeSubsidy)
import           Network.Haskoin.Store.Data
import           Network.Haskoin.Store.Data.ImportDB
import           Network.Haskoin.Store.Data.STM
import           UnliftIO

data ImportException
    = PrevBlockNotBest !Text
    | UnconfirmedCoinbase !Text
    | BestBlockUnknown
    | BestBlockNotFound !Text
    | BlockNotBest !Text
    | OrphanTx !Text
    | TxNotFound !Text
    | NoUnspent !Text
    | TxInvalidOp !Text
    | TxDeleted !Text
    | TxDoubleSpend !Text
    | AlreadyUnspent !Text
    | TxConfirmed !Text
    | OutputOutOfRange !Text
    | BalanceNotFound !Text
    | InsufficientBalance !Text
    | InsufficientZeroBalance !Text
    | InsufficientOutputs !Text
    | InsufficientFunds !Text
    | InitException !InitException
    | DuplicatePrevOutput !Text
    deriving (Show, Read, Eq, Ord, Exception)

initDB ::
       ( StoreRead m
       , StoreWrite m
       , UnspentRead m
       , UnspentWrite m
       , BalanceRead m
       , BalanceWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => Network
    -> m ()
initDB net =
    isInitialized >>= \case
        Left e -> do
            $(logErrorS) "BlockLogic" $
                "Initialization exception: " <> fromString (show e)
            throwError (InitException e)
        Right True -> do
            $(logDebugS) "BlockLogic" "Database is already initialized"
            return ()
        Right False -> do
            $(logDebugS)
                "BlockLogic"
                "Initializing database by importing genesis block"
            importBlock net (genesisBlock net) (genesisNode net)
            setInit

getOldOrphans ::
       (StoreStream m, MonadResource m)
    => UnixTime
    -> ConduitT () TxHash m ()
getOldOrphans now =
    getOrphans .| filterC ((< now - 600) . fst) .| mapC (txHash . snd)

importOrphan ::
       ( StoreRead m
       , StoreWrite m
       , BalanceRead m
       , BalanceWrite m
       , UnspentRead m
       , UnspentWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => Network
    -> UnixTime
    -> Tx
    -> m ()
importOrphan net t tx = do
    $(logDebugS) "Block" $
        "Attempting to import orphan tx " <> txHashToHex (txHash tx)
    go `catchError` ex
  where
    go = do
        newMempoolTx net tx t >>= \case
            True ->
                $(logDebugS) "BlockLogic" $
                "Succesfully imported orphan transaction: " <>
                txHashToHex (txHash tx)
            False ->
                $(logDebugS) "BlockLogic" $
                "Orphan transaction already imported: " <>
                txHashToHex (txHash tx)
        deleteOrphanTx (txHash tx)
    ex (OrphanTx _) = do
        $(logDebugS) "BlockLogic" $
            "Transaction still orphan: " <> txHashToHex (txHash tx)
    ex e = do
        $(logErrorS) "BlockLogic" $
            "Error importing orphan tx: " <> txHashToHex (txHash tx) <> ": " <>
            cs (show e)
        deleteOrphanTx (txHash tx)

newMempoolTx ::
       ( StoreRead m
       , StoreWrite m
       , UnspentRead m
       , UnspentWrite m
       , BalanceRead m
       , BalanceWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => Network
    -> Tx
    -> UnixTime
    -> m Bool
newMempoolTx net tx w = do
        $(logInfoS) "BlockLogic" $
            "Adding transaction to mempool: " <> txHashToHex (txHash tx)
        getTxData (txHash tx) >>= \case
            Just x
                | not (txDataDeleted x) -> do
                    $(logWarnS) "BlockLogic" $
                        "Transaction already exists: " <>
                        txHashToHex (txHash tx)
                    return False
            _ -> go
  where
    go = do
        orp <-
            any isNothing <$>
            mapM (getTxData . outPointHash . prevOutput) (txIn tx)
        if orp
            then do
                $(logWarnS) "BlockLogic" $
                    "Transaction is orphan: " <> txHashToHex (txHash tx)
                insertOrphanTx tx w
                throwError $ OrphanTx (txHashToHex (txHash tx))
            else f
    f = do
        us <-
            forM (txIn tx) $ \TxIn {prevOutput = op} -> do
                t <- getImportTx (outPointHash op)
                getTxOutput (outPointIndex op) t
        let ds = map spenderHash (mapMaybe outputSpender us)
        if null ds
            then do
                importTx net (MemRef w) w tx
                return True
            else g ds
    g ds = do
        $(logWarnS) "BlockLogic" $
            "Transaction inputs already spent: " <> txHashToHex (txHash tx)
        rbf <-
            if getReplaceByFee net
                then and <$> mapM isrbf ds
                else return False
        if rbf
            then r ds
            else n
    r ds = do
        $(logWarnS) "BlockLogic" $
            "Replacting RBF transaction with: " <> txHashToHex (txHash tx)
        forM_ ds (deleteTx net True)
        importTx net (MemRef w) w tx
        return True
    n = do
        $(logWarnS) "BlockLogic" $
            "Inserting transaction with deleted flag: " <>
            txHashToHex (txHash tx)
        insertDeletedMempoolTx tx w
        return False
    isrbf th = transactionRBF <$> getImportTx th

revertBlock ::
       ( StoreRead m
       , StoreWrite m
       , UnspentRead m
       , UnspentWrite m
       , BalanceRead m
       , BalanceWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => Network
    -> BlockHash
    -> m ()
revertBlock net bh = do
        bd <-
            getBestBlock >>= \case
                Nothing -> do
                    $(logErrorS) "BlockLogic" "Best block unknown"
                    throwError BestBlockUnknown
                Just h ->
                    getBlock h >>= \case
                        Nothing -> do
                            $(logErrorS) "BlockLogic" "Best block not found"
                            throwError (BestBlockNotFound (blockHashToHex h))
                        Just b
                            | h == bh -> return b
                            | otherwise -> do
                                $(logErrorS) "BlockLogic" $
                                    "Attempted to delete block that isn't best: " <>
                                    blockHashToHex h
                                throwError (BlockNotBest (blockHashToHex bh))
        txs <-
            mapM (fmap transactionData . getImportTx) (blockDataTxs bd)
        mapM_
            (deleteTx net False . txHash . snd)
            (reverse (sortTxs txs))
        setBest (prevBlock (blockDataHeader bd))
        insertBlock bd {blockDataMainChain = False}

importBlock ::
       ( StoreRead m
       , StoreWrite m
       , UnspentRead m
       , UnspentWrite m
       , BalanceRead m
       , BalanceWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => Network
    -> Block
    -> BlockNode
    -> m ()
importBlock net b n = do
        getBestBlock >>= \case
            Nothing
                | isGenesis n -> do
                    $(logInfoS) "BlockLogic" $
                        "Importing genesis block: " <>
                        blockHashToHex (headerHash (nodeHeader n))
                    return ()
                | otherwise -> do
                    $(logErrorS) "BlockLogic" $
                        "Importing non-genesis block when best block unknown: " <>
                        blockHashToHex (headerHash (blockHeader b))
                    throwError BestBlockUnknown
            Just h
                | prevBlock (blockHeader b) == h -> return ()
                | otherwise -> do
                    $(logErrorS) "BlockLogic" $
                        "Block " <> blockHashToHex (headerHash (blockHeader b)) <>
                        " does not build on current best " <>
                        blockHashToHex h
                    throwError
                        (PrevBlockNotBest
                             (blockHashToHex (prevBlock (nodeHeader n))))
        insertBlock
            BlockData
                { blockDataHeight = nodeHeight n
                , blockDataMainChain = True
                , blockDataWork = nodeWork n
                , blockDataHeader = nodeHeader n
                , blockDataSize = fromIntegral (B.length (encode b))
                , blockDataTxs = map txHash (blockTxns b)
                , blockDataWeight = fromIntegral w
                , blockDataSubsidy = subsidy (nodeHeight n)
                , blockDataFees = cb_out_val - subsidy (nodeHeight n)
                , blockDataOutputs = ts_out_val
                }
        insertAtHeight (headerHash (nodeHeader n)) (nodeHeight n)
        setBest (headerHash (nodeHeader n))
        $(logDebugS) "Block" $ "Importing or confirming block transactions..."
        mapM_ (uncurry import_or_confirm) (sortTxs (blockTxns b))
        $(logDebugS) "Block" $
            "Done importing transactions for block " <>
            blockHashToHex (headerHash (nodeHeader n))
  where
    import_or_confirm x tx =
        getTxData (txHash tx) >>= \case
            Just t
                | x > 0 && not (txDataDeleted t) -> do confirmTx net t (br x) tx
            _ -> do
                importTx
                    net
                    (br x)
                    (fromIntegral (blockTimestamp (nodeHeader n)))
                    tx
    subsidy = computeSubsidy net
    cb_out_val = sum (map outValue (txOut (head (blockTxns b))))
    ts_out_val = sum (map (sum . map outValue . txOut) (tail (blockTxns b)))
    br pos = BlockRef {blockRefHeight = nodeHeight n, blockRefPos = pos}
    w =
        let s =
                B.length
                    (encode
                         b
                             { blockTxns =
                                   map (\t -> t {txWitness = []}) (blockTxns b)
                             })
            x = B.length (encode b)
         in s * 3 + x

sortTxs :: [Tx] -> [(Word32, Tx)]
sortTxs txs = go $ zip [0 ..] txs
  where
    go [] = []
    go ts =
        let (is, ds) =
                partition
                    (all ((`notElem` map (txHash . snd) ts) .
                          outPointHash . prevOutput) .
                     txIn . snd)
                    ts
         in is <> go ds

importTx ::
       ( StoreRead m
       , StoreWrite m
       , UnspentRead m
       , UnspentWrite m
       , BalanceRead m
       , BalanceWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => Network
    -> BlockRef
    -> Word64 -- ^ unix time
    -> Tx
    -> m ()
importTx net br tt tx = do
        when (length (nub (map prevOutput (txIn tx))) < length (txIn tx)) $ do
            $(logErrorS) "BlockLogic" $
                "Transaction spends same output twice: " <>
                txHashToHex (txHash tx)
            throwError (DuplicatePrevOutput (txHashToHex (txHash tx)))
        when (iscb && not (confirmed br)) $ do
            $(logErrorS) "BlockLogic" $
                "Attempting to import coinbase to the mempool: " <>
                txHashToHex (txHash tx)
            throwError (UnconfirmedCoinbase (txHashToHex (txHash tx)))
        us <-
            if iscb
                then return []
                else forM (txIn tx) $ \TxIn {prevOutput = op} -> uns op
        when
            (not (confirmed br) &&
             sum (map unspentAmount us) < sum (map outValue (txOut tx))) $ do
            $(logErrorS) "BlockLogic" $
                "Insufficient funds: " <> txHashToHex (txHash tx)
            throwError (InsufficientFunds (txHashToHex th))
        zipWithM_
            (\i u -> spendOutput net br (txHash tx) i u)
            [0 ..]
            us
        zipWithM_
            (\i o -> newOutput net br (OutPoint (txHash tx) i) o)
            [0 ..]
            (txOut tx)
        rbf <- getrbf
        let t =
                Transaction
                    { transactionBlock = br
                    , transactionVersion = txVersion tx
                    , transactionLockTime = txLockTime tx
                    , transactionInputs =
                          if iscb
                              then zipWith mkcb (txIn tx) ws
                              else zipWith3 mkin us (txIn tx) ws
                    , transactionOutputs = map mkout (txOut tx)
                    , transactionDeleted = False
                    , transactionRBF = rbf
                    , transactionTime = tt
                    }
        let (d, _) = fromTransaction t
        insertTx d
        updateAddressCounts net (txAddresses t) (+ 1)
        unless (confirmed br) $
            insertMempoolTx (txHash tx) (memRefTime br)
  where
    uns op =
        getUnspent op >>= \case
            Just u -> return u
            Nothing -> do
                $(logWarnS) "BlockLogic" $
                    "No unspent output: " <> txHashToHex (outPointHash op) <>
                    " " <>
                    fromString (show (outPointIndex op))
                getSpender op >>= \case
                    Nothing -> do
                        $(logErrorS) "BlockLogic" $
                            "No spent or unspent output: " <>
                            txHashToHex (outPointHash op) <>
                            " " <>
                            fromString (show (outPointIndex op))
                        throwError (NoUnspent (cs (show op)))
                    Just Spender {spenderHash = s} -> do
                        deleteTx net True s
                        getUnspent op >>= \case
                            Nothing -> do
                                $(logErrorS) "BlockLogic" $
                                    "Could not unspend output: " <>
                                    txHashToHex (outPointHash op) <>
                                    " " <>
                                    fromString (show (outPointIndex op))
                                throwError (NoUnspent (cs (show op)))
                            Just u -> return u
    th = txHash tx
    iscb = all (== nullOutPoint) (map prevOutput (txIn tx))
    ws = map Just (txWitness tx) <> repeat Nothing
    getrbf
        | iscb = return False
        | any ((< 0xffffffff - 1) . txInSequence) (txIn tx) = return True
        | confirmed br = return False
        | otherwise =
            let hs = nub $ map (outPointHash . prevOutput) (txIn tx)
             in fmap or . forM hs $ \h ->
                    getTxData h >>= \case
                        Nothing -> throwError (TxNotFound (txHashToHex h))
                        Just t
                            | confirmed (txDataBlock t) -> return False
                            | txDataRBF t -> return True
                            | otherwise -> return False
    mkcb ip w =
        StoreCoinbase
            { inputPoint = prevOutput ip
            , inputSequence = txInSequence ip
            , inputSigScript = scriptInput ip
            , inputWitness = w
            }
    mkin u ip w =
        StoreInput
            { inputPoint = prevOutput ip
            , inputSequence = txInSequence ip
            , inputSigScript = scriptInput ip
            , inputPkScript = B.Short.fromShort (unspentScript u)
            , inputAmount = unspentAmount u
            , inputWitness = w
            }
    mkout o =
        StoreOutput
            { outputAmount = outValue o
            , outputScript = scriptOutput o
            , outputSpender = Nothing
            }

confirmTx ::
       ( StoreRead m
       , StoreWrite m
       , BalanceRead m
       , BalanceWrite m
       , UnspentRead m
       , UnspentWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => Network
    -> TxData
    -> BlockRef
    -> Tx
    -> m ()
confirmTx net t br tx = do
    forM_ (txDataPrevs t) $ \p ->
        case scriptToAddressBS (prevScript p) of
            Left _ -> return ()
            Right a -> do
                removeAddrTx
                    a
                    BlockTx
                        {blockTxBlock = txDataBlock t, blockTxHash = txHash tx}
                insertAddrTx
                    a
                    BlockTx {blockTxBlock = br, blockTxHash = txHash tx}
    forM_ (zip [0 ..] (txOut tx)) $ \(n, o) -> do
        let op = OutPoint (txHash tx) n
        s <- getSpender (OutPoint (txHash tx) n)
        when (isNothing s) $ do
            delUnspent op
            addUnspent
                Unspent
                    { unspentBlock = br
                    , unspentPoint = op
                    , unspentAmount = outValue o
                    , unspentScript = B.Short.toShort (scriptOutput o)
                    }
        case scriptToAddressBS (scriptOutput o) of
            Left _ -> return ()
            Right a -> do
                removeAddrTx
                    a
                    BlockTx
                        {blockTxBlock = txDataBlock t, blockTxHash = txHash tx}
                insertAddrTx
                    a
                    BlockTx {blockTxBlock = br, blockTxHash = txHash tx}
                when (isNothing s) $ do
                    removeAddrUnspent
                        a
                        Unspent
                            { unspentBlock = txDataBlock t
                            , unspentPoint = op
                            , unspentAmount = outValue o
                            , unspentScript = B.Short.toShort (scriptOutput o)
                            }
                    insertAddrUnspent
                        a
                        Unspent
                            { unspentBlock = br
                            , unspentPoint = op
                            , unspentAmount = outValue o
                            , unspentScript = B.Short.toShort (scriptOutput o)
                            }
                    reduceBalance net False False a (outValue o)
                    increaseBalance True False a (outValue o)
    insertTx t {txDataBlock = br}
    deleteMempoolTx (txHash tx) (memRefTime (txDataBlock t))

getRecursiveTx ::
       (Monad m, StoreRead m, MonadLogger m) => TxHash -> m [Transaction]
getRecursiveTx th =
    getTxData th >>= \case
        Nothing -> return []
        Just d -> do
            sm <- getSpenders th
            let t = toTransaction d sm
            fmap (t :) $ do
                let ss = nub . map spenderHash $ I.elems sm
                concat <$> mapM getRecursiveTx ss

deleteTx ::
       ( StoreRead m
       , StoreWrite m
       , UnspentRead m
       , UnspentWrite m
       , BalanceRead m
       , BalanceWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => Network
    -> Bool -- ^ only delete transaction if unconfirmed
    -> TxHash
    -> m ()
deleteTx net mo h = do
    $(logDebugS) "BlockLogic" $ "Deleting transaction: " <> txHashToHex h
    getTxData h >>= \case
        Nothing -> do
            $(logErrorS) "BlockLogic" $
                "Transaciton not found: " <> txHashToHex h
            throwError (TxNotFound (txHashToHex h))
        Just t
            | txDataDeleted t -> do
                $(logWarnS) "BlockLogic" $
                    "Transaction already deleted: " <> txHashToHex h
                return ()
            | mo && confirmed (txDataBlock t) -> do
                $(logErrorS) "BlockLogic" $
                    "Will not delete confirmed transaction: " <> txHashToHex h
                throwError (TxConfirmed (txHashToHex h))
            | otherwise -> go t
  where
    go t = do
        ss <- nub . map spenderHash . I.elems <$> getSpenders h
        mapM_ (deleteTx net True) ss
        forM_ (take (length (txOut (txData t))) [0 ..]) $ \n ->
            delOutput net (OutPoint h n)
        let ps = filter (/= nullOutPoint) (map prevOutput (txIn (txData t)))
        mapM_ (unspendOutput net) ps
        unless (confirmed (txDataBlock t)) $
            deleteMempoolTx h (memRefTime (txDataBlock t))
        insertTx t {txDataDeleted = True}
        updateAddressCounts net (txDataAddresses t) (subtract 1)

insertDeletedMempoolTx ::
       ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => Tx
    -> UnixTime
    -> m ()
insertDeletedMempoolTx tx w = do
        us <-
            forM (txIn tx) $ \TxIn {prevOutput = op} ->
                getImportTx (outPointHash op) >>=
                getTxOutput (outPointIndex op)
        rbf <- getrbf
        let (d, _) =
                fromTransaction
                    Transaction
                        { transactionBlock = MemRef w
                        , transactionVersion = txVersion tx
                        , transactionLockTime = txLockTime tx
                        , transactionInputs = zipWith3 mkin us (txIn tx) ws
                        , transactionOutputs = map mkout (txOut tx)
                        , transactionDeleted = True
                        , transactionRBF = rbf
                        , transactionTime = w
                        }
        $(logWarnS) "BlockLogic" $
            "Inserting deleted mempool transaction: " <> txHashToHex (txHash tx)
        insertTx d
  where
    ws = map Just (txWitness tx) <> repeat Nothing
    getrbf
        | any ((< 0xffffffff - 1) . txInSequence) (txIn tx) = return True
        | otherwise =
            let hs = nub $ map (outPointHash . prevOutput) (txIn tx)
             in fmap or . forM hs $ \h ->
                    getTxData h >>= \case
                        Nothing -> do
                            $(logErrorS) "BlockLogic" $
                                "Transaction not found: " <> txHashToHex h
                            throwError (TxNotFound (txHashToHex h))
                        Just t
                            | confirmed (txDataBlock t) -> return False
                            | txDataRBF t -> return True
                            | otherwise -> return False
    mkin u ip wit =
        StoreInput
            { inputPoint = prevOutput ip
            , inputSequence = txInSequence ip
            , inputSigScript = scriptInput ip
            , inputPkScript = outputScript u
            , inputAmount = outputAmount u
            , inputWitness = wit
            }
    mkout o =
        StoreOutput
            { outputAmount = outValue o
            , outputScript = scriptOutput o
            , outputSpender = Nothing
            }

newOutput ::
       ( StoreRead m
       , StoreWrite m
       , UnspentRead m
       , UnspentWrite m
       , BalanceRead m
       , BalanceWrite m
       , MonadLogger m
       )
    => Network
    -> BlockRef
    -> OutPoint
    -> TxOut
    -> m ()
newOutput net br op to = do
    addUnspent u
    case scriptToAddressBS (scriptOutput to) of
        Left _ -> return ()
        Right a -> do
            insertAddrUnspent a u
            insertAddrTx
                a
                BlockTx {blockTxHash = outPointHash op, blockTxBlock = br}
            increaseBalance (confirmed br) True a (outValue to)
  where
    u =
        Unspent
            { unspentBlock = br
            , unspentAmount = outValue to
            , unspentScript = B.Short.toShort (scriptOutput to)
            , unspentPoint = op
            }

delOutput ::
       ( StoreRead m
       , StoreWrite m
       , UnspentRead m
       , UnspentWrite m
       , BalanceRead m
       , BalanceWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => Network
    -> OutPoint
    -> m ()
delOutput net op = do
    t <- getImportTx (outPointHash op)
    u <- getTxOutput (outPointIndex op) t
    delUnspent op
    case scriptToAddressBS (outputScript u) of
        Left _ -> return ()
        Right a -> do
            removeAddrUnspent
                a
                Unspent
                    { unspentScript = B.Short.toShort (outputScript u)
                    , unspentBlock = transactionBlock t
                    , unspentPoint = op
                    , unspentAmount = outputAmount u
                    }
            removeAddrTx
                a
                BlockTx
                    { blockTxHash = outPointHash op
                    , blockTxBlock = transactionBlock t
                    }
            reduceBalance
                net
                (confirmed (transactionBlock t))
                True
                a
                (outputAmount u)

getImportTx ::
       (StoreRead m, MonadLogger m, MonadError ImportException m)
    => TxHash
    -> m Transaction
getImportTx th =
    getTxData th >>= \case
        Nothing -> do
            $(logErrorS) "BlockLogic" $
                "Tranasction not found: " <> txHashToHex th
            throwError $ TxNotFound (txHashToHex th)
        Just d
            | txDataDeleted d -> do
                $(logErrorS) "BlockLogic" $
                    "Transaction deleted: " <> txHashToHex th
                throwError $ TxDeleted (txHashToHex th)
            | otherwise -> do
                sm <- getSpenders th
                return $ toTransaction d sm

getTxOutput ::
       (MonadLogger m, MonadError ImportException m)
    => Word32
    -> Transaction
    -> m StoreOutput
getTxOutput i tx = do
    unless (fromIntegral i < length (transactionOutputs tx)) $ do
        $(logErrorS) "BlockLogic" $
            "Output out of range " <> txHashToHex (txHash (transactionData tx)) <>
            " " <>
            fromString (show i)
        throwError . OutputOutOfRange . cs $
            show
                OutPoint
                    { outPointHash = txHash (transactionData tx)
                    , outPointIndex = i
                    }
    return $ transactionOutputs tx !! fromIntegral i

spendOutput ::
       ( StoreRead m
       , StoreWrite m
       , UnspentRead m
       , UnspentWrite m
       , BalanceRead m
       , BalanceWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => Network
    -> BlockRef
    -> TxHash
    -> Word32
    -> Unspent
    -> m ()
spendOutput net br th ix u = do
    insertSpender (unspentPoint u) Spender {spenderHash = th, spenderIndex = ix}
    case scriptToAddressBS (B.Short.fromShort (unspentScript u)) of
        Left _ -> return ()
        Right a -> do
            reduceBalance
                net
                (confirmed (unspentBlock u))
                False
                a
                (unspentAmount u)
            removeAddrUnspent a u
            insertAddrTx a BlockTx {blockTxHash = th, blockTxBlock = br}
    delUnspent (unspentPoint u)

unspendOutput ::
       ( StoreRead m
       , StoreWrite m
       , UnspentRead m
       , UnspentWrite m
       , BalanceRead m
       , BalanceWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => Network
    -> OutPoint
    -> m ()
unspendOutput net op = do
        t <- getImportTx (outPointHash op)
        o <- getTxOutput (outPointIndex op) t
        s <-
            case outputSpender o of
                Nothing -> do
                    $(logErrorS) "BlockLogic" $
                        "Output already unspent: " <>
                        txHashToHex (outPointHash op) <>
                        " " <>
                        fromString (show (outPointIndex op))
                    throwError (AlreadyUnspent (cs (show op)))
                Just s -> return s
        x <- getImportTx (spenderHash s)
        deleteSpender op
        let u =
                Unspent
                    { unspentAmount = outputAmount o
                    , unspentBlock = transactionBlock t
                    , unspentScript = B.Short.toShort (outputScript o)
                    , unspentPoint = op
                    }
        addUnspent u
        case scriptToAddressBS (outputScript o) of
            Left _ -> return ()
            Right a -> do
                insertAddrUnspent a u
                removeAddrTx
                    a
                    BlockTx
                        { blockTxHash = spenderHash s
                        , blockTxBlock = transactionBlock x
                        }
                increaseBalance
                    (confirmed (unspentBlock u))
                    False
                    a
                    (outputAmount o)

reduceBalance ::
       ( StoreRead m
       , StoreWrite m
       , BalanceRead m
       , BalanceWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => Network
    -> Bool -- ^ spend or delete confirmed output
    -> Bool -- ^ reduce total received
    -> Address
    -> Word64
    -> m ()
reduceBalance net c t a v = do
    getBalance a >>= \case
        Nothing -> do
            $(logErrorS) "BlockLogic" $
                "Balance not found for address " <> addrText net a
            throwError (BalanceNotFound (addrText net a))
        Just b -> do
            when (v > amnt b) $ do
                $(logErrorS) "BlockLogic" $
                    "Insufficient " <> conf <> " balance: " <> addrText net a <>
                    " (needs: " <>
                    cs (show v) <>
                    ", has: " <>
                    cs (show (amnt b)) <>
                    ")"
                throwError $
                    if c
                        then InsufficientBalance (addrText net a)
                        else InsufficientZeroBalance (addrText net a)
            setBalance
                b
                    { balanceAmount =
                          balanceAmount b -
                          if c
                              then v
                              else 0
                    , balanceZero =
                          balanceZero b -
                          if c
                              then 0
                              else v
                    , balanceUnspentCount = balanceUnspentCount b - 1
                    , balanceTotalReceived =
                          balanceTotalReceived b -
                          if t
                              then v
                              else 0
                    }
  where
    amnt =
        if c
            then balanceAmount
            else balanceZero
    conf =
        if c
            then "confirmed"
            else "unconfirmed"
    addr =
        case addrToString net a of
            Nothing -> "???"
            Just x  -> x

increaseBalance ::
       ( StoreRead m
       , StoreWrite m
       , BalanceRead m
       , BalanceWrite m
       , MonadLogger m
       )
    => Bool -- ^ add confirmed output
    -> Bool -- ^ increase total received
    -> Address
    -> Word64
    -> m ()
increaseBalance c t a v = do
    b <-
        getBalance a >>= \case
            Nothing ->
                return
                    Balance
                        { balanceAddress = a
                        , balanceAmount = 0
                        , balanceZero = 0
                        , balanceUnspentCount = 0
                        , balanceTxCount = 0
                        , balanceTotalReceived = 0
                        }
            Just b -> return b
    setBalance
        b
            { balanceAmount =
                  balanceAmount b +
                  if c
                      then v
                      else 0
            , balanceZero =
                  balanceZero b +
                  if c
                      then 0
                      else v
            , balanceUnspentCount = balanceUnspentCount b + 1
            , balanceTotalReceived =
                  balanceTotalReceived b +
                  if t
                      then v
                      else 0
            }
  where
    conf =
        if c
            then "confirmed"
            else "unconfirmed"

updateAddressCounts ::
       (BalanceWrite m, BalanceRead m, Monad m, MonadError ImportException m)
    => Network
    -> [Address]
    -> (Word64 -> Word64)
    -> m ()
updateAddressCounts net as f =
    forM_ as $ \a -> do
        b <-
            getBalance a >>= \case
                Nothing -> throwError (BalanceNotFound (addrText net a))
                Just b -> return b
        setBalance b {balanceTxCount = f (balanceTxCount b)}

txAddresses :: Transaction -> [Address]
txAddresses t =
    nub . rights $
    map (scriptToAddressBS . inputPkScript)
        (filter (not . isCoinbase) (transactionInputs t)) <>
    map (scriptToAddressBS . outputScript) (transactionOutputs t)

txDataAddresses :: TxData -> [Address]
txDataAddresses t =
    nub . rights $
    map (scriptToAddressBS . prevScript) (I.elems (txDataPrevs t)) <>
    map (scriptToAddressBS . scriptOutput) (txOut (txData t))

addrText :: Network -> Address -> Text
addrText net a = fromMaybe "???" $ addrToString net a
