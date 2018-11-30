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
import           Data.Either
import qualified Data.IntMap.Strict                  as I
import           Data.List
import           Data.Maybe
import           Data.Serialize
import           Data.String
import           Data.Word
import           Database.RocksDB
import           Haskoin
import           Network.Haskoin.Store.Data
import           Network.Haskoin.Store.Data.HashMap
import           Network.Haskoin.Store.Data.ImportDB
import           UnliftIO

data ImportException
    = PrevBlockNotBest !BlockHash
    | UnconfirmedCoinbase !TxHash
    | BestBlockUnknown
    | BestBlockNotFound !BlockHash
    | BlockNotBest !BlockHash
    | OrphanTx !TxHash
    | TxNotFound !TxHash
    | NoUnspent !OutPoint
    | TxInvalidOp !TxHash
    | TxDeleted !TxHash
    | TxDoubleSpend !TxHash
    | AlreadyUnspent !OutPoint
    | TxConfirmed !TxHash
    | OutputOutOfRange !OutPoint
    | BalanceNotFound !Address
    | InsufficientBalance !Address
    | InsufficientZeroBalance !Address
    | InsufficientOutputs !Address
    | InsufficientFunds !TxHash
    | InitException !InitException
    | DuplicatePrevOutput !TxHash
    deriving (Show, Read, Eq, Ord, Exception)

initDB ::
       (MonadIO m, MonadError ImportException m, MonadLoggerIO m)
    => Network
    -> DB
    -> TVar UnspentMap
    -> TVar BalanceMap
    -> m ()
initDB net db um bm =
    runImportDB db um bm $ \i ->
        isInitialized i >>= \case
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
                importBlock net i (genesisBlock net) (genesisNode net)
                setInit i

newMempoolTx ::
       ( MonadError ImportException m
       , StoreRead i m
       , StoreWrite i m
       , UnspentRead i m
       , UnspentWrite i m
       , BalanceRead i m
       , BalanceWrite i m
       , MonadLogger m
       )
    => Network
    -> i
    -> Tx
    -> PreciseUnixTime
    -> m ()
newMempoolTx net i tx now@(PreciseUnixTime w) = do
    $(logInfoS) "BlockLogic" $
        "Adding transaction to mempool: " <> txHashToHex (txHash tx)
    getTxData i (txHash tx) >>= \case
        Just x
            | not (txDataDeleted x) -> do
                $(logWarnS) "BlockLogic" $
                    "Transaction already exists: " <> txHashToHex (txHash tx)
                return ()
        _ -> go
  where
    go = do
        orp <-
            any isNothing <$>
            mapM (getTxData i . outPointHash . prevOutput) (txIn tx)
        if orp
            then do
                $(logErrorS) "BlockLogic" $ "Transaction is orphan: " <> txHashToHex (txHash tx)
                throwError $ OrphanTx (txHash tx)
            else f
    f = do
        us <-
            forM (txIn tx) $ \TxIn {prevOutput = op} -> do
                t <- getImportTx i (outPointHash op)
                getTxOutput (outPointIndex op) t
        let ds = map spenderHash (mapMaybe outputSpender us)
        if null ds
            then importTx net i (MemRef now) (w `div` 1000) tx
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
        forM_ ds (deleteTx net i True)
        importTx net i (MemRef now) (w `div` 1000) tx
    n = do
        $(logWarnS) "BlockLogic" $
            "Inserting transaction with deleted flag: " <>
            txHashToHex (txHash tx)
        insertDeletedMempoolTx i tx now
    isrbf th = transactionRBF <$> getImportTx i th

newBlock ::
       (MonadError ImportException m, MonadIO m, MonadLogger m)
    => Network
    -> DB
    -> TVar UnspentMap
    -> TVar BalanceMap
    -> Block
    -> BlockNode
    -> m ()
newBlock net db um bm b n = runImportDB db um bm $ \i -> importBlock net i b n

revertBlock ::
       ( MonadError ImportException m
       , StoreRead i m
       , StoreWrite i m
       , UnspentRead i m
       , UnspentWrite i m
       , BalanceRead i m
       , BalanceWrite i m
       , MonadLogger m
       )
    => Network
    -> i
    -> BlockHash
    -> m ()
revertBlock net i bh = do
    bd <-
        getBestBlock i >>= \case
            Nothing -> do
                $(logErrorS) "BlockLogic" "Best block unknown"
                throwError BestBlockUnknown
            Just h ->
                getBlock i h >>= \case
                    Nothing -> do
                        $(logErrorS) "BlockLogic" "Best block not found"
                        throwError (BestBlockNotFound h)
                    Just b
                        | h == bh -> return b
                        | otherwise -> do
                            $(logErrorS) "BlockLogic" $
                                "Attempted to delete block that isn't best: " <>
                                blockHashToHex h
                            throwError (BlockNotBest bh)
    txs <- mapM (fmap transactionData . getImportTx i) (blockDataTxs bd)
    mapM_ (deleteTx net i False . txHash) (reverse (sortTxs txs))
    setBest i (prevBlock (blockDataHeader bd))
    insertBlock i bd {blockDataMainChain = False}

importBlock ::
       ( MonadError ImportException m
       , StoreRead i m
       , StoreWrite i m
       , UnspentRead i m
       , UnspentWrite i m
       , BalanceRead i m
       , BalanceWrite i m
       , MonadLogger m
       )
    => Network
    -> i
    -> Block
    -> BlockNode
    -> m ()
importBlock net i b n = do
    getBestBlock i >>= \case
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
                throwError (PrevBlockNotBest (prevBlock (nodeHeader n)))
    insertBlock
        i
        BlockData
            { blockDataHeight = nodeHeight n
            , blockDataMainChain = True
            , blockDataWork = nodeWork n
            , blockDataHeader = nodeHeader n
            , blockDataSize = fromIntegral (B.length (encode b))
            , blockDataTxs = map txHash (blockTxns b)
            , blockDataWeight = fromIntegral w
            }
    insertAtHeight i (headerHash (nodeHeader n)) (nodeHeight n)
    setBest i (headerHash (nodeHeader n))
    zipWithM_
        (\x t ->
             importTx
                 net
                 i
                 (br x)
                 (fromIntegral (blockTimestamp (nodeHeader n)))
                 t)
        [0 ..]
        (sortTxs (blockTxns b))
  where
    br pos = BlockRef {blockRefHeight = nodeHeight n, blockRefPos = pos}
    w = let s = B.length (encode b {blockTxns = map (\t -> t {txWitness = []}) (blockTxns b)})
            x = B.length (encode b)
            d = x - s
        in s * 4 + d

sortTxs :: [Tx] -> [Tx]
sortTxs [] = []
sortTxs txs = is <> sortTxs ds
  where
    (is, ds) =
        partition
            (all ((`notElem` map txHash txs) . outPointHash . prevOutput) . txIn)
            txs

importTx ::
       ( MonadError ImportException m
       , StoreRead i m
       , StoreWrite i m
       , UnspentRead i m
       , UnspentWrite i m
       , BalanceRead i m
       , BalanceWrite i m
       , MonadLogger m
       )
    => Network
    -> i
    -> BlockRef
    -> Word64 -- ^ unix time
    -> Tx
    -> m ()
importTx net i br tt tx = do
    when (length (nub (map prevOutput (txIn tx))) < length (txIn tx)) $ do
        $(logErrorS) "BlockLogic" $
            "Transaction spends same output twice: " <> txHashToHex (txHash tx)
        throwError (DuplicatePrevOutput (txHash tx))
    when (iscb && not (confirmed br)) $ do
        $(logErrorS) "BlockLogic" $
            "Attempting to import coinbase to the mempool: " <>
            txHashToHex (txHash tx)
        throwError (UnconfirmedCoinbase (txHash tx))
    -- If unspent is nothing this transaction exists already
    us <-
        fromMaybe [] . sequence <$>
        if iscb
            then return []
            else forM (txIn tx) $ \TxIn {prevOutput = op} -> uns op
    when
        (not (confirmed br) &&
         sum (map unspentAmount us) < sum (map outValue (txOut tx))) $ do
        $(logErrorS) "BlockLogic" $
            "Insufficient funds: " <> txHashToHex (txHash tx)
        throwError (InsufficientFunds th)
    zipWithM_ (spendOutput net i br (txHash tx)) [0 ..] us
    if | iscb || not (null us) ->
           do zipWithM_
                  (newOutput i br . OutPoint (txHash tx))
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
              insertTx i d
              updateAddressCounts i (txAddresses t) (+1)
              unless (confirmed br) $
                  insertMempoolTx i (txHash tx) (memRefTime br)
       | null us && confirmed br -> confirmTx net i br tx
       | otherwise ->
           do $(logErrorS) "BlockLogic" $
                  "Invalid operation required for transaction: " <>
                  txHashToHex (txHash tx)
              throwError (TxInvalidOp (txHash tx))
  where
    uns op =
        getUnspent i op >>= \case
            Nothing
                | confirmed br -> do
                    $(logWarnS) "BlockLogic" $
                        "Could not find unspent output: " <>
                        txHashToHex (outPointHash op) <>
                        " " <>
                        fromString (show (outPointIndex op))
                    getSpender i op >>= \case
                        Nothing -> do
                            $(logErrorS) "BlockLogic" $
                                "Could not find output: " <>
                                txHashToHex (outPointHash op) <>
                                " " <>
                                fromString (show (outPointIndex op))
                            throwError (OrphanTx (txHash tx))
                        Just s
                            | spenderHash s == txHash tx -> return Nothing
                            | otherwise -> do
                                $(logWarnS) "BlockLogic" $
                                    "Deleting conflicting transaction: " <>
                                    txHashToHex (spenderHash s)
                                deleteTx net i True (spenderHash s)
                                getUnspent i op >>= \case
                                    Nothing -> do
                                        $(logErrorS) "BlockLogic" $
                                            "Transaction double-spend detected: " <>
                                            txHashToHex (txHash tx)
                                        throwError (TxDoubleSpend (txHash tx))
                                    Just u -> return $ Just u
                | otherwise -> do
                    $(logErrorS) "BlockLogic" $
                        "No unspent output: " <> txHashToHex (outPointHash op) <>
                        " " <>
                        fromString (show (outPointIndex op))
                    throwError (NoUnspent op)
            Just u -> return $ Just u
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
                    getTxData i h >>= \case
                        Nothing -> throwError (TxNotFound h)
                        Just t
                            | confirmed (txDataBlock t) -> return False
                            | txDataRBF t -> return True
                            | otherwise -> return False
    mkcb ip w =
        Coinbase
            { inputPoint = prevOutput ip
            , inputSequence = txInSequence ip
            , inputSigScript = scriptInput ip
            , inputWitness = w
            }
    mkin u ip w =
        Input
            { inputPoint = prevOutput ip
            , inputSequence = txInSequence ip
            , inputSigScript = scriptInput ip
            , inputPkScript = B.Short.fromShort (unspentScript u)
            , inputAmount = unspentAmount u
            , inputWitness = w
            }
    mkout o =
        Output
            { outputAmount = outValue o
            , outputScript = scriptOutput o
            , outputSpender = Nothing
            }

confirmTx ::
       ( MonadError ImportException m
       , StoreRead i m
       , StoreWrite i m
       , BalanceRead i m
       , BalanceWrite i m
       , UnspentRead i m
       , UnspentWrite i m
       , MonadLogger m
       )
    => Network
    -> i
    -> BlockRef
    -> Tx
    -> m ()
confirmTx net i br tx =
    getTxData i (txHash tx) >>= \case
        Nothing -> do
            $(logErrorS) "BlockLogic" $
                "Transaction not found: " <> txHashToHex (txHash tx)
            throwError (TxNotFound (txHash tx))
        Just t -> do
            forM_ (txDataPrevs t) $ \p ->
                case scriptToAddressBS (prevScript p) of
                    Left _ -> return ()
                    Right a -> do
                        removeAddrTx
                            i
                            AddressTx
                                { addressTxAddress = a
                                , addressTxBlock = txDataBlock t
                                , addressTxHash = txHash tx
                                }
                        insertAddrTx
                            i
                            AddressTx
                                { addressTxAddress = a
                                , addressTxBlock = br
                                , addressTxHash = txHash tx
                                }
            forM_ (zip [0 ..] (txOut tx)) $ \(n, o) -> do
                let op = OutPoint (txHash tx) n
                s <- getSpender i (OutPoint (txHash tx) n)
                when (isNothing s) $ do
                    delUnspent i op
                    addUnspent
                        i
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
                            i
                            AddressTx
                                { addressTxAddress = a
                                , addressTxBlock = txDataBlock t
                                , addressTxHash = txHash tx
                                }
                        insertAddrTx
                            i
                            AddressTx
                                { addressTxAddress = a
                                , addressTxBlock = br
                                , addressTxHash = txHash tx
                                }
                        when (isNothing s) $ do
                            removeAddrUnspent
                                i
                                a
                                Unspent
                                    { unspentBlock = txDataBlock t
                                    , unspentPoint = op
                                    , unspentAmount = outValue o
                                    , unspentScript =
                                          B.Short.toShort (scriptOutput o)
                                    }
                            insertAddrUnspent
                                i
                                a
                                Unspent
                                    { unspentBlock = br
                                    , unspentPoint = op
                                    , unspentAmount = outValue o
                                    , unspentScript =
                                          B.Short.toShort (scriptOutput o)
                                    }
                            reduceBalance net i False False a (outValue o)
                            increaseBalance i True False a (outValue o)
            insertTx i t {txDataBlock = br}
            deleteMempoolTx i (txHash tx) (memRefTime (txDataBlock t))

getRecursiveTx ::
       (Monad m, StoreRead i m, MonadLogger m) => i -> TxHash -> m [Transaction]
getRecursiveTx i th =
    getTxData i th >>= \case
        Nothing -> return []
        Just d -> do
            sm <- getSpenders i th
            let t = toTransaction d sm
            fmap (t :) $ do
                let ss = nub . map spenderHash $ I.elems sm
                concat <$> mapM (getRecursiveTx i) ss

deleteTx ::
       ( MonadError ImportException m
       , StoreRead i m
       , StoreWrite i m
       , UnspentRead i m
       , UnspentWrite i m
       , BalanceRead i m
       , BalanceWrite i m
       , MonadLogger m
       )
    => Network
    -> i
    -> Bool -- ^ only delete transaction if unconfirmed
    -> TxHash
    -> m ()
deleteTx net i mo h = do
    $(logDebugS) "BlockLogic" $ "Deleting transaction: " <> txHashToHex h
    getTxData i h >>= \case
        Nothing -> do
            $(logErrorS) "BlockLogic" $
                "Transaciton not found: " <> txHashToHex h
            throwError (TxNotFound h)
        Just t
            | txDataDeleted t -> do
                $(logWarnS) "BlockLogic" $
                    "Transaction already deleted: " <> txHashToHex h
                return ()
            | mo && confirmed (txDataBlock t) -> do
                $(logErrorS) "BlockLogic" $
                    "Will not delete confirmed transaction: " <> txHashToHex h
                throwError (TxConfirmed h)
            | otherwise -> go t
  where
    go t = do
        ss <- nub . map spenderHash . I.elems <$> getSpenders i h
        mapM_ (deleteTx net i True) ss
        forM_ (take (length (txOut (txData t))) [0 ..]) $ \n ->
            delOutput net i (OutPoint h n)
        let ps = filter (/= nullOutPoint) (map prevOutput (txIn (txData t)))
        mapM_ (unspendOutput i) ps
        unless (confirmed (txDataBlock t)) $
            deleteMempoolTx i h (memRefTime (txDataBlock t))
        insertTx i t {txDataDeleted = True}
        updateAddressCounts i (txDataAddresses t) (subtract 1)

insertDeletedMempoolTx ::
       ( MonadError ImportException m
       , StoreRead i m
       , StoreWrite i m
       , MonadLogger m
       )
    => i
    -> Tx
    -> PreciseUnixTime
    -> m ()
insertDeletedMempoolTx i tx now@(PreciseUnixTime w) = do
    us <-
        forM (txIn tx) $ \TxIn {prevOutput = op} ->
            getImportTx i (outPointHash op) >>= getTxOutput (outPointIndex op)
    rbf <- getrbf
    let (d, _) =
            fromTransaction
                Transaction
                    { transactionBlock = MemRef now
                    , transactionVersion = txVersion tx
                    , transactionLockTime = txLockTime tx
                    , transactionInputs = zipWith3 mkin us (txIn tx) ws
                    , transactionOutputs = map mkout (txOut tx)
                    , transactionDeleted = True
                    , transactionRBF = rbf
                    , transactionTime = w `div` 1000
                    }
    $(logWarnS) "BlockLogic" $
        "Inserting deleted mempool transaction: " <> txHashToHex (txHash tx)
    insertTx i d
  where
    ws = map Just (txWitness tx) <> repeat Nothing
    getrbf
        | any ((< 0xffffffff - 1) . txInSequence) (txIn tx) = return True
        | otherwise =
            let hs = nub $ map (outPointHash . prevOutput) (txIn tx)
             in fmap or . forM hs $ \h ->
                    getTxData i h >>= \case
                        Nothing -> do
                            $(logErrorS) "BlockLogic" $
                                "Transaction not found: " <> txHashToHex h
                            throwError (TxNotFound h)
                        Just t
                            | confirmed (txDataBlock t) -> return False
                            | txDataRBF t -> return True
                            | otherwise -> return False
    mkin u ip wit =
        Input
            { inputPoint = prevOutput ip
            , inputSequence = txInSequence ip
            , inputSigScript = scriptInput ip
            , inputPkScript = outputScript u
            , inputAmount = outputAmount u
            , inputWitness = wit
            }
    mkout o =
        Output
            { outputAmount = outValue o
            , outputScript = scriptOutput o
            , outputSpender = Nothing
            }

newOutput ::
       ( MonadError ImportException m
       , StoreRead i m
       , StoreWrite i m
       , UnspentRead i m
       , UnspentWrite i m
       , BalanceRead i m
       , BalanceWrite i m
       , MonadLogger m
       )
    => i
    -> BlockRef
    -> OutPoint
    -> TxOut
    -> m ()
newOutput i br op to = do
    addUnspent i u
    case scriptToAddressBS (scriptOutput to) of
        Left _ -> return ()
        Right a -> do
            insertAddrUnspent i a u
            insertAddrTx
                i
                AddressTx
                    { addressTxAddress = a
                    , addressTxHash = outPointHash op
                    , addressTxBlock = br
                    }
            increaseBalance i (confirmed br) True a (outValue to)
  where
    u =
        Unspent
            { unspentBlock = br
            , unspentAmount = outValue to
            , unspentScript = B.Short.toShort (scriptOutput to)
            , unspentPoint = op
            }

delOutput ::
       ( MonadError ImportException m
       , StoreRead i m
       , StoreWrite i m
       , UnspentRead i m
       , UnspentWrite i m
       , BalanceRead i m
       , BalanceWrite i m
       , MonadLogger m
       )
    => Network
    -> i
    -> OutPoint
    -> m ()
delOutput net i op = do
    t <- getImportTx i (outPointHash op)
    u <- getTxOutput (outPointIndex op) t
    delUnspent i op
    case scriptToAddressBS (outputScript u) of
        Left _ -> return ()
        Right a -> do
            removeAddrUnspent
                i
                a
                Unspent
                    { unspentScript = B.Short.toShort (outputScript u)
                    , unspentBlock = transactionBlock t
                    , unspentPoint = op
                    , unspentAmount = outputAmount u
                    }
            removeAddrTx
                i
                AddressTx
                    { addressTxAddress = a
                    , addressTxHash = outPointHash op
                    , addressTxBlock = transactionBlock t
                    }
            reduceBalance
                net
                i
                (confirmed (transactionBlock t))
                True
                a
                (outputAmount u)

getImportTx ::
       (MonadError ImportException m, StoreRead i m, MonadLogger m)
    => i
    -> TxHash
    -> m Transaction
getImportTx i th =
    getTxData i th >>= \case
        Nothing -> do
            $(logErrorS) "BlockLogic" $
                "Tranasction not found: " <> txHashToHex th
            throwError $ TxNotFound th
        Just d
            | txDataDeleted d -> do
                $(logErrorS) "BlockLogic" $
                    "Transaction deleted: " <> txHashToHex th
                throwError $ TxDeleted th
            | otherwise -> do
                sm <- getSpenders i th
                return $ toTransaction d sm

getTxOutput ::
       (MonadError ImportException m, MonadLogger m)
    => Word32
    -> Transaction
    -> m Output
getTxOutput i tx = do
    unless (fromIntegral i < length (transactionOutputs tx)) $ do
        $(logErrorS) "BlockLogic" $
            "Output out of range " <> txHashToHex (txHash (transactionData tx)) <>
            " " <>
            fromString (show i)
        throwError $
            OutputOutOfRange
                OutPoint
                    { outPointHash = txHash (transactionData tx)
                    , outPointIndex = i
                    }
    return $ transactionOutputs tx !! fromIntegral i

spendOutput ::
       ( MonadError ImportException m
       , StoreRead i m
       , StoreWrite i m
       , UnspentRead i m
       , UnspentWrite i m
       , BalanceRead i m
       , BalanceWrite i m
       , MonadLogger m
       )
    => Network
    -> i
    -> BlockRef
    -> TxHash
    -> Word32
    -> Unspent
    -> m ()
spendOutput net i br th ix u = do
    insertSpender
        i
        (unspentPoint u)
        Spender {spenderHash = th, spenderIndex = ix}
    case scriptToAddressBS (B.Short.fromShort (unspentScript u)) of
        Left _ -> return ()
        Right a -> do
            reduceBalance
                net
                i
                (confirmed (unspentBlock u))
                False
                a
                (unspentAmount u)
            removeAddrUnspent i a u
            insertAddrTx
                i
                AddressTx
                    { addressTxAddress = a
                    , addressTxHash = th
                    , addressTxBlock = br
                    }
    delUnspent i (unspentPoint u)

unspendOutput ::
       ( MonadError ImportException m
       , StoreRead i m
       , StoreWrite i m
       , UnspentRead i m
       , UnspentWrite i m
       , BalanceRead i m
       , BalanceWrite i m
       , MonadLogger m
       )
    => i
    -> OutPoint
    -> m ()
unspendOutput i op = do
    t <- getImportTx i (outPointHash op)
    o <- getTxOutput (outPointIndex op) t
    s <-
        case outputSpender o of
            Nothing -> do
                $(logErrorS) "BlockLogic" $
                    "Output already unspent: " <> txHashToHex (outPointHash op) <>
                    " " <>
                    fromString (show (outPointIndex op))
                throwError (AlreadyUnspent op)
            Just s -> return s
    x <- getImportTx i (spenderHash s)
    deleteSpender i op
    let u =
            Unspent
                { unspentAmount = outputAmount o
                , unspentBlock = transactionBlock t
                , unspentScript = B.Short.toShort (outputScript o)
                , unspentPoint = op
                }
    addUnspent i u
    case scriptToAddressBS (outputScript o) of
        Left _ -> return ()
        Right a -> do
            insertAddrUnspent i a u
            removeAddrTx
                i
                AddressTx
                    { addressTxAddress = a
                    , addressTxHash = spenderHash s
                    , addressTxBlock = transactionBlock x
                    }
            increaseBalance
                i
                (confirmed (unspentBlock u))
                False
                a
                (outputAmount o)

reduceBalance ::
       ( MonadError ImportException m
       , StoreRead i m
       , StoreWrite i m
       , BalanceRead i m
       , BalanceWrite i m
       , MonadLogger m
       )
    => Network
    -> i
    -> Bool -- ^ spend or delete confirmed output
    -> Bool -- ^ reduce total received
    -> Address
    -> Word64
    -> m ()
reduceBalance net i c t a v =
    getBalance i a >>= \case
        Nothing -> do
            $(logErrorS) "BlockLogic" $
                "Balance not found: " <> addrToString net a
            throwError (BalanceNotFound a)
        Just b -> do
            when
                (v >
                 if c
                     then balanceAmount b
                     else balanceZero b) $ do
                $(logErrorS) "BlockLogic" $
                    "Insufficient " <>
                    (if c
                         then "confirmed "
                         else "unconfirmed ") <>
                    "balance: " <>
                    addrToString net a
                throwError $
                    if c
                        then InsufficientBalance a
                        else InsufficientZeroBalance a
            setBalance i $
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

increaseBalance ::
       ( MonadError ImportException m
       , StoreRead i m
       , StoreWrite i m
       , BalanceRead i m
       , BalanceWrite i m
       , MonadLogger m
       )
    => i
    -> Bool -- ^ add confirmed output
    -> Bool -- ^ increase total received
    -> Address
    -> Word64
    -> m ()
increaseBalance i c t a v = do
    b <-
        getBalance i a >>= \case
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
    setBalance i $
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

updateAddressCounts ::
       (MonadError ImportException m, BalanceWrite i m, BalanceRead i m)
    => i
    -> [Address]
    -> (Word64 -> Word64)
    -> m ()
updateAddressCounts i as f =
    forM_ as $ \a -> do
        b <-
            getBalance i a >>= \case
                Nothing -> throwError (BalanceNotFound a)
                Just b -> return b
        setBalance i b {balanceTxCount = f (balanceTxCount b)}

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
