{-# LANGUAGE DeriveAnyClass   #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase       #-}
module Network.Haskoin.Store.Logic where

import           Conduit
import           Control.Monad
import           Control.Monad.Except
import qualified Data.ByteString                     as B
import qualified Data.ByteString.Short               as B.Short
import           Data.Function
import qualified Data.HashMap.Strict                 as M
import qualified Data.IntMap.Strict                  as I
import           Data.List
import           Data.Maybe
import           Data.Serialize
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
    | TxDeleted !TxHash
    | TxDoubleSpend !TxHash
    | TxConfirmed !TxHash
    | OutputOutOfRange !OutPoint
    | InsufficientBalance !Address
    | InsufficientOutputs !Address
    | InsufficientFunds !TxHash
    | InitException !InitException
    | DuplicatePrevOutput !TxHash
    deriving (Show, Read, Eq, Ord, Exception)

initDB ::
       (MonadIO m, MonadError ImportException m)
    => Network
    -> DB
    -> TVar UnspentMap
    -> m ()
initDB net db um =
    runImportDB db um $ \i ->
        isInitialized i >>= \case
            Left e -> throwError (InitException e)
            Right True -> return ()
            Right False -> do
                importBlock net i (genesisBlock net) (genesisNode net)
                setInit i

newMempoolTx ::
       ( MonadError ImportException m
       , StoreRead i m
       , StoreWrite i m
       , UnspentStore i m
       )
    => Network
    -> i
    -> Tx
    -> PreciseUnixTime
    -> m ()
newMempoolTx net i tx now =
    getTransaction i (txHash tx) >>= \case
        Just x | not (transactionDeleted x) -> return ()
        _ -> go
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
            then importTx i (MemRef now) tx
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
        forM_ ds (deleteTx i False)
        importTx i (MemRef now) tx
    n = insertDeletedMempoolTx i tx now
    isrbf th = transactionRBF <$> getImportTx i th

newBlock ::
       (MonadError ImportException m, MonadIO m)
    => Network
    -> DB
    -> TVar UnspentMap
    -> Block
    -> BlockNode
    -> m ()
newBlock net db um b n = runImportDB db um $ \i -> importBlock net i b n

revertBlock ::
       ( MonadError ImportException m
       , StoreRead i m
       , StoreWrite i m
       , UnspentStore i m
       )
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
       (MonadError ImportException m, StoreRead i m, StoreWrite i m, UnspentStore i m)
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
    zipWithM_ (\x t -> importTx i (br x) t) [0 ..] (blockTxns b)
    forM_ txs $ \tr -> do
        let tx = transactionData tr
            th = txHash tx
        when (th `notElem` hs) $
            case transactionBlock tr of
                MemRef t -> newMempoolTx net i tx t
                BlockRef {} -> throwError (TxConfirmed (txHash tx))
  where
    hs = map txHash (blockTxns b)
    br pos = BlockRef {blockRefHeight = nodeHeight n, blockRefPos = pos}

importTx ::
       ( MonadError ImportException m
       , StoreRead i m
       , StoreWrite i m
       , UnspentStore i m
       )
    => i
    -> BlockRef
    -> Tx
    -> m ()
importTx i br tx = do
    when (length (nub (map prevOutput (txIn tx))) < length (txIn tx)) $
        throwError (DuplicatePrevOutput (txHash tx))
    us <-
        if iscb
            then return []
            else forM (txIn tx) $ \TxIn {prevOutput = op} ->
                     getUnspent i op >>= \case
                         Nothing
                             | confirmed br ->
                                 getOutput i op >>= \case
                                     Nothing ->
                                         throwError (OrphanTx (txHash tx))
                                     Just Output {outputSpender = Just s} -> do
                                         deleteTx i False (spenderHash s)
                                         getUnspent i op >>= \case
                                             Nothing ->
                                                 throwError
                                                     (TxDoubleSpend (txHash tx))
                                             Just u -> return u
                                     Just Output {outputSpender = Nothing} ->
                                         throwError (TxDoubleSpend (txHash tx))
                             | otherwise -> throwError (NoUnspent op)
                         Just u -> return u
    when (iscb && not (confirmed br)) $
        throwError (UnconfirmedCoinbase (txHash tx))
    unless iscb $ do
        when (sum (map unspentAmount us) < sum (map outValue (txOut tx))) $
            throwError (InsufficientFunds th)
        zipWithM_
            (spendOutput i br (txHash tx))
            [0 ..]
            us
    zipWithM_ (newOutput i br (txHash tx)) [0 ..] (txOut tx)
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
  where
    th = txHash tx
    iscb = all (== nullOutPoint) (map prevOutput (txIn tx))
    fee us =
        if iscb
            then 0
            else sum (map unspentAmount us) - sum (map outValue (txOut tx))
    ws = map Just (txWitness tx) <> repeat Nothing
    getrbf
        | iscb = return False
        | any ((< 0xffffffff - 1) . txInSequence) (txIn tx) = return True
        | confirmed br = return False
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

deleteTx ::
       ( MonadError ImportException m
       , StoreRead i m
       , StoreWrite i m
       , UnspentStore i m
       )
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
            | otherwise -> return ()
  where
    go t = do
        forM_ (mapMaybe outputSpender (transactionOutputs t)) $ \s ->
            deleteTx i False (spenderHash s)
        forM_ (take (length (transactionOutputs t)) [0 ..]) $ \n ->
            delOutput i (OutPoint h n)
        let ps = filter (/= nullOutPoint) (map inputPoint (transactionInputs t))
        forM_ ps $ \op -> unspendOutput i op (transactionBlock t)
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

newOutput ::
       ( MonadError ImportException m
       , StoreRead i m
       , StoreWrite i m
       , UnspentStore i m
       )
    => i
    -> BlockRef
    -> TxHash
    -> Word32
    -> TxOut
    -> m ()
newOutput i tb th ix to = do
    addUnspent i u
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
            , unspentScript = B.Short.toShort (scriptOutput to)
            , unspentPoint = OutPoint th ix
            }

delOutput ::
       ( MonadError ImportException m
       , StoreRead i m
       , StoreWrite i m
       , UnspentStore i m
       )
    => i
    -> OutPoint
    -> m ()
delOutput i op = do
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
       ( MonadError ImportException m
       , StoreRead i m
       , StoreWrite i m
       , UnspentStore i m
       )
    => i
    -> BlockRef
    -> TxHash
    -> Word32
    -> Unspent
    -> m ()
spendOutput i tb th ix u = do
    insertOutput
        i
        (unspentPoint u)
        Output
            { outputAmount = unspentAmount u
            , outputScript = B.Short.fromShort (unspentScript u)
            , outputSpender = Just Spender {spenderHash = th, spenderIndex = ix}
            }
    delUnspent i (unspentPoint u)
    case scriptToAddressBS (B.Short.fromShort (unspentScript u)) of
        Left _ -> return ()
        Right a -> do
            removeAddrUnspent i a u
            reduceBalance i (confirmed tb) a (unspentAmount u)
            insertAddrTx
                i
                AddressTx
                    { addressTxAddress = a
                    , addressTxHash = th
                    , addressTxBlock = tb
                    }

unspendOutput ::
       ( MonadError ImportException m
       , StoreRead i m
       , StoreWrite i m
       , UnspentStore i m
       )
    => i
    -> OutPoint
    -> BlockRef
    -> m ()
unspendOutput i op br = do
    tx <- getImportTx i (outPointHash op)
    out <- getTxOutput (outPointIndex op) tx
    when (isJust (outputSpender out)) $ do
        insertTx
            i
            tx {transactionOutputs = zipWith f [0 ..] (transactionOutputs tx)}
        let u =
                Unspent
                    { unspentAmount = outputAmount out
                    , unspentBlock = transactionBlock tx
                    , unspentScript = B.Short.toShort (outputScript out)
                    , unspentPoint = op
                    }
        addUnspent i u
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

pruneUnspentMap :: UnspentMap -> UnspentMap
pruneUnspentMap um
    | M.size um > 2000 * 1000 =
        let f is = unspentBlock (head (I.elems is))
            ls =
                sortBy
                    (compare `on` (f . snd))
                    (filter (not . I.null . snd) (M.toList um))
         in M.fromList (drop (1000 * 1000) ls)
    | otherwise = um
