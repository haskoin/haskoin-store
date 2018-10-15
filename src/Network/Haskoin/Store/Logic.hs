{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
module Network.Haskoin.Store.Logic where

import           Control.Monad
import           Control.Monad.Except
import qualified Data.ByteString                     as B
import           Data.List
import           Data.Maybe
import           Data.Serialize
import           Data.Word
import           Database.RocksDB
import           Haskoin
import           Network.Haskoin.Store.Data
import           Network.Haskoin.Store.Data.ImportDB
import           UnliftIO

data ImportException
    = PrevBlockNotBest !BlockHash
    | BestBlockUnknown
    | BestBlockNotFound !BlockHash
    | BlockNotBest !BlockHash
    | TxNotFound !TxHash
    | DuplicateTx !TxHash
    | TxDeleted !TxHash
    | TxDoubleSpend !TxHash
    | TxOutputsSpent !TxHash
    | TxConfirmed !TxHash
    | OutputOutOfRange !OutPoint
    | OutputAlreadyUnspent !OutPoint
    | OutputAlreadySpent !OutPoint
    | OutputDoesNotExist !OutPoint
    | BalanceNotFound !Address
    | InsufficientBalance !Address
    | InsufficientOutputs !Address
    | InsufficientFunds !TxHash
    | InitException !InitException
    | DuplicatePrevOutput !TxHash
    deriving (Show, Read, Eq, Ord, Exception)

initDB :: (MonadIO m, MonadError ImportException m) => Network -> DB -> m ()
initDB net db =
    runImportDB db $ \i ->
        isInitialized i >>= \case
            Left e -> throwError (InitException e)
            Right True -> return ()
            Right False -> do
                importBlock net i (genesisBlock net) (genesisNode net)
                setInit i

newMempoolTx ::
       (MonadError ImportException m, StoreRead i m, StoreWrite i m)
    => Network
    -> i
    -> Tx
    -> PreciseUnixTime
    -> m ()
newMempoolTx net i tx now =
    getTransaction i (txHash tx) >>= \case
        Just _ -> throwError (DuplicateTx (txHash tx))
        Nothing -> go
  where
    go = do
        orp <-
            any isNothing <$>
            mapM (getTransaction i . outPointHash . prevOutput) (txIn tx)
        unless orp f
    f = do
        us <-
            forM (txIn tx) $ \TxIn {prevOutput = op} -> do
                t <- getImportTx i (outPointHash op)
                getTxOutput (outPointIndex op) t
        let ds = map spenderHash (mapMaybe outputSpender us)
        if null ds
            then importTx net i (MemRef now) tx
            else g ds
    g ds = do
        rbf <-
            if getReplaceByFee net
                then and <$> mapM isrbf ds
                else return False
        if rbf
            then r ds
            else n
    r ds = do
        forM_ ds (recursiveDeleteTx net i)
        importTx net i (MemRef now) tx
    n = insertDeletedMempoolTx i tx now
    isrbf th = transactionRBF <$> getImportTx i th

newBlock ::
       (MonadError ImportException m, MonadIO m)
    => Network
    -> DB
    -> Block
    -> BlockNode
    -> m ()
newBlock net db b n = runImportDB db $ \i -> importBlock net i b n

revertBlock ::
       (MonadError ImportException m, StoreRead i m, StoreWrite i m)
    => i
    -> BlockHash
    -> m ()
revertBlock i bh = do
    bd <-
        getBestBlock i >>= \case
            Nothing -> throwError BestBlockUnknown
            Just h ->
                getBlock i h >>= \case
                    Nothing -> throwError (BestBlockNotFound h)
                    Just b
                        | h == bh -> return b
                        | otherwise -> throwError (BlockNotBest bh)
    forM_ (blockDataTxs bd) $ deleteTx i False
    setBest i (prevBlock (blockDataHeader bd))
    insertBlock i bd {blockDataMainChain = False}

importBlock ::
       (MonadError ImportException m, StoreRead i m, StoreWrite i m)
    => Network
    -> i
    -> Block
    -> BlockNode
    -> m ()
importBlock net i b n = do
    getBestBlock i >>= \case
        Nothing
            | isGenesis n -> return ()
            | otherwise -> throwError BestBlockUnknown
        Just h
            | prevBlock (blockHeader b) == h -> return ()
            | otherwise ->
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
            }
    insertAtHeight i (headerHash (nodeHeader n)) (nodeHeight n)
    setBest i (headerHash (nodeHeader n))
    txs <- concat <$> mapM (getRecursiveTx i . txHash) (tail (blockTxns b))
    mapM_ (deleteTx i False . txHash . transactionData) (reverse txs)
    zipWithM_ (\x t -> importTx net i (br x) t) [0 ..] (blockTxns b)
    forM_ txs $ \tr -> do
        let tx = transactionData tr
        when (tx `notElem` blockTxns b) $
            case transactionBlock tr of
                MemRef t -> newMempoolTx net i tx t
                BlockRef {} -> throwError (TxConfirmed (txHash tx))
  where
    br pos = BlockRef {blockRefHeight = nodeHeight n, blockRefPos = pos}

importTx ::
       ( MonadError ImportException m
       , StoreRead i m
       , StoreWrite i m
       )
    => Network
    -> i
    -> BlockRef
    -> Tx
    -> m ()
importTx net i br tx =
    getTransaction i th >>= \case
        Just t
            | not (transactionDeleted t) -> throwError (DuplicateTx th)
            | otherwise -> go
        Nothing -> go
  where
    th = txHash tx
    go = do
        when (length (nub (map prevOutput (txIn tx))) < length (txIn tx)) $
            throwError (DuplicatePrevOutput (txHash tx))
        us <-
            if iscb
                then return []
                else forM (txIn tx) $ \TxIn {prevOutput = op} ->
                         getImportTx i (outPointHash op) >>=
                         getTxOutput (outPointIndex op)
        unless iscb $ do
            when (sum (map outputAmount us) < sum (map outValue (txOut tx))) $
                throwError (InsufficientFunds th)
            when (confirmed br && any (isJust . outputSpender) us) $ do
                let ds = map spenderHash (mapMaybe outputSpender us)
                mapM_ (recursiveDeleteTx net i) ds
            when (not (confirmed br) && any (isJust . outputSpender) us) $
                throwError (TxDoubleSpend th)
            zipWithM_
                (spendOutput i br (txHash tx))
                [0 ..]
                (map prevOutput (txIn tx))
        zipWithM_ (insertOutput i br (txHash tx)) [0 ..] (txOut tx)
        rbf <- getrbf
        insertTx
            i
            Transaction
                { transactionBlock = br
                , transactionVersion = txVersion tx
                , transactionLockTime = txLockTime tx
                , transactionFee = fee us
                , transactionInputs =
                      if iscb
                          then zipWith mkcb (txIn tx) ws
                          else zipWith3 mkin us (txIn tx) ws
                , transactionOutputs = map mkout (txOut tx)
                , transactionDeleted = False
                , transactionRBF = rbf
                }
        unless (confirmed br) $ insertMempoolTx i (txHash tx) (memRefTime br)
    iscb = all (== nullOutPoint) (map prevOutput (txIn tx))
    fee us =
        if iscb
            then 0
            else sum (map outputAmount us) - sum (map outValue (txOut tx))
    ws = map Just (txWitness tx) <> repeat Nothing
    getrbf
        | iscb = return False
        | any ((< 0xffffffff - 1) . txInSequence) (txIn tx) = return True
        | otherwise =
            let hs = nub $ map (outPointHash . prevOutput) (txIn tx)
             in fmap or . forM hs $ \h ->
                    getTransaction i h >>= \case
                        Nothing -> throwError (TxNotFound h)
                        Just t
                            | confirmed (transactionBlock t) -> return False
                            | transactionRBF t -> return True
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
            , inputPkScript = outputScript u
            , inputAmount = outputAmount u
            , inputWitness = w
            }
    mkout o =
        Output
            { outputAmount = outValue o
            , outputScript = scriptOutput o
            , outputSpender = Nothing
            }

getRecursiveTx :: (Monad m, StoreRead i m) => i -> TxHash -> m [Transaction]
getRecursiveTx i th =
    getTransaction i th >>= \case
        Nothing -> return []
        Just t ->
            fmap (t :) $ do
                let ss =
                        nub
                            (map spenderHash
                                 (mapMaybe outputSpender (transactionOutputs t)))
                concat <$> mapM (getRecursiveTx i) ss


recursiveDeleteTx ::
       (MonadError ImportException m, StoreRead i m, StoreWrite i m)
    => Network
    -> i
    -> TxHash
    -> m ()
recursiveDeleteTx net i th =
    getTransaction i th >>= \case
        Nothing -> throwError (TxNotFound th)
        Just tx
            | not (transactionDeleted tx) -> do
                let ss =
                        map
                            spenderHash
                            (mapMaybe outputSpender (transactionOutputs tx))
                forM_ ss (recursiveDeleteTx net i)
                deleteTx i True th
            | otherwise -> throwError (TxDeleted th)

deleteTx ::
       (MonadError ImportException m, StoreRead i m, StoreWrite i m)
    => i
    -> Bool -- ^ only delete transaction if unconfirmed
    -> TxHash
    -> m ()
deleteTx i mo h =
    getTransaction i h >>= \case
        Nothing -> throwError (TxNotFound h)
        Just t
            | not (transactionDeleted t) ->
                if mo && confirmed (transactionBlock t)
                    then throwError (TxConfirmed h)
                    else go t
            | otherwise -> throwError (TxDeleted h)
  where
    go t = do
        when (any (isJust . outputSpender) (transactionOutputs t)) $
            throwError (TxOutputsSpent h)
        forM_ (take (length (transactionOutputs t)) [0 ..]) $ \n ->
            deleteOutput i (OutPoint h n)
        forM_ (map inputPoint (transactionInputs t)) $ \op ->
            unspendOutput i op (transactionBlock t)
        unless (confirmed (transactionBlock t)) $
            deleteMempoolTx i h (memRefTime (transactionBlock t))
        insertTx i t {transactionDeleted = True}

insertDeletedMempoolTx ::
       (MonadError ImportException m, StoreRead i m, StoreWrite i m)
    => i
    -> Tx
    -> PreciseUnixTime
    -> m ()
insertDeletedMempoolTx i tx now = do
    us <-
        forM (txIn tx) $ \TxIn {prevOutput = op} ->
            getImportTx i (outPointHash op) >>= getTxOutput (outPointIndex op)
    rbf <- getrbf
    insertTx
        i
        Transaction
            { transactionBlock = MemRef now
            , transactionVersion = txVersion tx
            , transactionLockTime = txLockTime tx
            , transactionFee = fee us
            , transactionInputs = zipWith3 mkin us (txIn tx) ws
            , transactionOutputs = map mkout (txOut tx)
            , transactionDeleted = True
            , transactionRBF = rbf
            }
  where
    ws = map Just (txWitness tx) <> repeat Nothing
    getrbf
        | any ((< 0xffffffff - 1) . txInSequence) (txIn tx) = return True
        | otherwise =
            let hs = nub $ map (outPointHash . prevOutput) (txIn tx)
             in fmap or . forM hs $ \h ->
                    getTransaction i h >>= \case
                        Nothing -> throwError (TxNotFound h)
                        Just t
                            | confirmed (transactionBlock t) -> return False
                            | transactionRBF t -> return True
                            | otherwise -> return False
    fee us = sum (map outputAmount us) - sum (map outValue (txOut tx))
    mkin u ip w =
        Input
            { inputPoint = prevOutput ip
            , inputSequence = txInSequence ip
            , inputSigScript = scriptInput ip
            , inputPkScript = outputScript u
            , inputAmount = outputAmount u
            , inputWitness = w
            }
    mkout o =
        Output
            { outputAmount = outValue o
            , outputScript = scriptOutput o
            , outputSpender = Nothing
            }

insertOutput ::
       (MonadError ImportException m, StoreRead i m, StoreWrite i m)
    => i
    -> BlockRef
    -> TxHash
    -> Word32
    -> TxOut
    -> m ()
insertOutput i tb th ix to =
    case scriptToAddressBS (scriptOutput to) of
        Left _ -> return ()
        Right a -> do
            insertAddrUnspent i a u
            insertAddrTx
                i
                AddressTx
                    { addressTxAddress = a
                    , addressTxHash = th
                    , addressTxBlock = tb
                    }
            increaseBalance i (confirmed tb) a (outValue to)
  where
    u =
        Unspent
            { unspentBlock = tb
            , unspentAmount = outValue to
            , unspentScript = scriptOutput to
            , unspentPoint = OutPoint th ix
            }

deleteOutput ::
       (MonadError ImportException m, StoreRead i m, StoreWrite i m)
    => i
    -> OutPoint
    -> m ()
deleteOutput i op = do
    t <- getImportTx i (outPointHash op)
    u <- getTxOutput (outPointIndex op) t
    case scriptToAddressBS (outputScript u) of
        Left _ -> return ()
        Right a -> do
            removeAddrUnspent
                i
                a
                Unspent
                    { unspentScript = outputScript u
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
                i
                (confirmed (transactionBlock t))
                a
                (outputAmount u)

getImportTx ::
       (MonadError ImportException m, StoreRead i m)
    => i
    -> TxHash
    -> m Transaction
getImportTx i th =
    getTransaction i th >>= \case
        Nothing -> throwError $ TxNotFound th
        Just t
            | transactionDeleted t -> throwError $ TxDeleted th
            | otherwise -> return t

getTxOutput ::
       (MonadError ImportException m) => Word32 -> Transaction -> m Output
getTxOutput i tx = do
    unless (fromIntegral i < length (transactionOutputs tx)) $
        throwError $
        OutputOutOfRange
            OutPoint
                {outPointHash = txHash (transactionData tx), outPointIndex = i}
    return $ transactionOutputs tx !! fromIntegral i

spendOutput ::
       (MonadError ImportException m, StoreRead i m, StoreWrite i m)
    => i
    -> BlockRef
    -> TxHash
    -> Word32
    -> OutPoint
    -> m ()
spendOutput i tb th ix op = do
    tx <- getImportTx i (outPointHash op)
    out <- getTxOutput (outPointIndex op) tx
    when (isJust (outputSpender out)) $ throwError (OutputAlreadySpent op)
    insertTx
        i
        tx {transactionOutputs = zipWith f [0 ..] (transactionOutputs tx)}
    case scriptToAddressBS (outputScript out) of
        Left _ -> return ()
        Right a -> do
            removeAddrUnspent
                i
                a
                Unspent
                    { unspentScript = outputScript out
                    , unspentAmount = outputAmount out
                    , unspentBlock = transactionBlock tx
                    , unspentPoint = op
                    }
            reduceBalance i (confirmed tb) a (outputAmount out)
            insertAddrTx
                i
                AddressTx
                    { addressTxAddress = a
                    , addressTxHash = th
                    , addressTxBlock = tb
                    }
  where
    f n o
        | n == outPointIndex op = o {outputSpender = Just (Spender th ix)}
        | otherwise = o

unspendOutput ::
       (MonadError ImportException m, StoreRead i m, StoreWrite i m)
    => i
    -> OutPoint
    -> BlockRef
    -> m ()
unspendOutput i op br = do
    tx <- getImportTx i (outPointHash op)
    out <- getTxOutput (outPointIndex op) tx
    when (isNothing (outputSpender out)) $ throwError (OutputAlreadyUnspent op)
    insertTx
        i
        tx {transactionOutputs = zipWith f [0 ..] (transactionOutputs tx)}
    let u =
            Unspent
                { unspentAmount = outputAmount out
                , unspentBlock = transactionBlock tx
                , unspentScript = outputScript out
                , unspentPoint = op
                }
    case scriptToAddressBS (outputScript out) of
        Left _ -> return ()
        Right a -> do
            insertAddrUnspent i a u
            increaseBalance i (confirmed br) a (outputAmount out)
  where
    f n o
        | n == outPointIndex op = o {outputSpender = Nothing}
        | otherwise = o

reduceBalance ::
       (MonadError ImportException m, StoreRead i m, StoreWrite i m)
    => i
    -> Bool -- ^ confirmed
    -> Address
    -> Word64
    -> m ()
reduceBalance i c a v = do
    b <- getBalance i a
    setBalance i =<<
        if c
            then do
                unless (v <= balanceAmount b) $
                    throwError (InsufficientBalance a)
                unless (balanceCount b > 0) $ throwError (InsufficientOutputs a)
                return
                    b
                        { balanceAmount = balanceAmount b - v
                        , balanceCount = balanceCount b - 1
                        }
            else do
                unless
                    (fromIntegral v <=
                     fromIntegral (balanceAmount b) + balanceZero b) $
                    throwError (InsufficientBalance a)
                unless (balanceCount b > 0) $ throwError (InsufficientOutputs a)
                return
                    b
                        { balanceZero = balanceZero b - fromIntegral v
                        , balanceCount = balanceCount b - 1
                        }

increaseBalance ::
       (MonadError ImportException m, StoreRead i m, StoreWrite i m)
    => i
    -> Bool -- ^ confirmed
    -> Address
    -> Word64
    -> m ()
increaseBalance i c a v = do
    b <- getBalance i a
    setBalance i $
        if c
            then b
                     { balanceAmount = balanceAmount b + v
                     , balanceCount = balanceCount b + 1
                     }
            else b
                     { balanceZero = balanceZero b + fromIntegral v
                     , balanceCount = balanceCount b + 1
                     }
