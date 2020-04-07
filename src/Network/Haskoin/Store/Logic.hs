{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
module Network.Haskoin.Store.Logic where

import           Control.Monad                 (forM, forM_, unless, void, when,
                                                zipWithM_)
import           Control.Monad.Except          (MonadError, catchError,
                                                throwError)
import           Control.Monad.Logger          (MonadLogger, logErrorS,
                                                logWarnS)
import qualified Data.ByteString               as B
import qualified Data.ByteString.Short         as B.Short
import           Data.Either                   (rights)
import qualified Data.IntMap.Strict            as I
import           Data.List                     (nub, sort)
import           Data.Maybe                    (fromMaybe, isNothing, mapMaybe)
import           Data.Serialize                (encode)
import           Data.String                   (fromString)
import           Data.String.Conversions       (cs)
import           Data.Text                     (Text)
import           Data.Word                     (Word32, Word64)
import           Haskoin                       (Address, Block (..), BlockHash,
                                                BlockHeader (..),
                                                BlockNode (..), Network (..),
                                                OutPoint (..), Tx (..), TxHash,
                                                TxIn (..), TxOut (..),
                                                addrToString, blockHashToHex,
                                                genesisBlock, genesisNode,
                                                headerHash, isGenesis,
                                                nullOutPoint, scriptToAddressBS,
                                                txHash, txHashToHex)
import           Network.Haskoin.Block.Headers (computeSubsidy)
import           Network.Haskoin.Store.Common  (Balance (..), BlockData (..),
                                                BlockRef (..), BlockTx (..),
                                                Prev (..), Spender (..),
                                                StoreInput (..),
                                                StoreOutput (..),
                                                StoreRead (..), StoreWrite (..),
                                                Transaction (..), TxData (..),
                                                UnixTime, Unspent (..),
                                                confirmed, fromTransaction,
                                                isCoinbase, nullBalance,
                                                sortTxs, toTransaction,
                                                transactionData)
import           UnliftIO                      (Exception)

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
    | DuplicatePrevOutput !Text
    deriving (Show, Read, Eq, Ord, Exception)

initBest ::
       ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => Network
    -> m ()
initBest net = do
    m <- getBestBlock
    when
        (isNothing m)
        (void (importBlock net (genesisBlock net) (genesisNode net)))

getOldOrphans :: StoreRead m => UnixTime -> m [TxHash]
getOldOrphans now =
    map (txHash . snd) . filter ((< now - 600) . fst) <$> getOrphans

getOldMempool :: StoreRead m => UnixTime -> m [TxHash]
getOldMempool now =
    map blockTxHash . filter ((< now - 3600 * 72) . memRefTime . blockTxBlock) <$>
    getMempool

importOrphan ::
       ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => Network
    -> UnixTime
    -> Tx
    -> m (Maybe [TxHash]) -- ^ deleted transactions or nothing if import failed
importOrphan net t tx = do
    go `catchError` ex
  where
    go = do
        maybetxids <-
            newMempoolTx net tx t >>= \case
                Just ths -> return (Just ths)
                Nothing -> return Nothing
        deleteOrphanTx (txHash tx)
        return maybetxids
    ex (OrphanTx _) = do
        return Nothing
    ex _ = do
        $(logWarnS) "Block" $
            "Deleted bad orphan tx: " <> txHashToHex (txHash tx)
        deleteOrphanTx (txHash tx)
        return Nothing

newMempoolTx ::
       ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => Network
    -> Tx
    -> UnixTime
    -> m (Maybe [TxHash]) -- ^ deleted transactions or nothing if import failed
newMempoolTx net tx w =
    getTxData (txHash tx) >>= \case
        Just x
            | not (txDataDeleted x) -> return Nothing
        _ -> go
  where
    go = do
        orp <-
            any isNothing <$>
            mapM (getTxData . outPointHash . prevOutput) (txIn tx)
        if orp
            then do
                $(logWarnS) "Block" $ "Orphan tx: " <> txHashToHex (txHash tx)
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
                ths <- importTx net (MemRef w) w tx
                return (Just ths)
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
        $(logWarnS) "Block" $ "Replace by fee tx: " <> txHashToHex (txHash tx)
        ths <- concat <$> forM ds (deleteTx net True)
        dts <- importTx net (MemRef w) w tx
        return (Just (nub (ths <> dts)))
    n = do
        $(logWarnS) "Block" $ "Conflicting tx: " <> txHashToHex (txHash tx)
        insertDeletedMempoolTx tx w
        return Nothing
    isrbf th = transactionRBF <$> getImportTx th

revertBlock ::
       ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => Network
    -> BlockHash
    -> m [TxHash]
revertBlock net bh = do
    bd <-
        getBestBlock >>= \case
            Nothing -> do
                $(logErrorS) "Block" "Best block unknown"
                throwError BestBlockUnknown
            Just h ->
                getBlock h >>= \case
                    Nothing -> do
                        $(logErrorS) "Block" "Best block not found"
                        throwError (BestBlockNotFound (blockHashToHex h))
                    Just b
                        | h == bh -> return b
                        | otherwise -> do
                            $(logErrorS) "Block" $
                                "Cannot delete block that is not head: " <>
                                blockHashToHex h
                            throwError (BlockNotBest (blockHashToHex bh))
    txs <- mapM (fmap transactionData . getImportTx) (blockDataTxs bd)
    ths <-
        nub . concat <$>
        mapM (deleteTx net False . txHash . snd) (reverse (sortTxs txs))
    setBest (prevBlock (blockDataHeader bd))
    insertBlock bd {blockDataMainChain = False}
    return ths

importBlock ::
       ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => Network
    -> Block
    -> BlockNode
    -> m [TxHash] -- ^ deleted transactions
importBlock net b n = do
    mp <- filter (`elem` bths) . map blockTxHash <$> getMempool
    getBestBlock >>= \case
        Nothing
            | isGenesis n -> return ()
            | otherwise -> do
                $(logErrorS) "Block" $
                    "Cannot import non-genesis block at this point: " <>
                    blockHashToHex (headerHash (blockHeader b))
                throwError BestBlockUnknown
        Just h
            | prevBlock (blockHeader b) == h -> return ()
            | otherwise -> do
                $(logErrorS) "Block" $
                    "Block does not build on head: " <>
                    blockHashToHex (headerHash (blockHeader b))
                throwError $
                    PrevBlockNotBest (blockHashToHex (prevBlock (nodeHeader n)))
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
    bs <- getBlocksAtHeight (nodeHeight n)
    setBlocksAtHeight (nub (headerHash (nodeHeader n) : bs)) (nodeHeight n)
    setBest (headerHash (nodeHeader n))
    ths <-
        nub . concat <$>
        mapM (uncurry (import_or_confirm mp)) (sortTxs (blockTxns b))
    return ths
  where
    bths = map txHash (blockTxns b)
    import_or_confirm mp x tx =
        if txHash tx `elem` mp
            then getTxData (txHash tx) >>= \case
                     Just td -> confirmTx net td (br x) tx >> return []
                     Nothing -> do
                         $(logErrorS) "Block" $
                             "Cannot get data for mempool tx: " <>
                             txHashToHex (txHash tx)
                         throwError $ TxNotFound (txHashToHex (txHash tx))
            else importTx
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

importTx ::
       ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => Network
    -> BlockRef
    -> Word64 -- ^ unix time
    -> Tx
    -> m [TxHash] -- ^ deleted transactions
importTx net br tt tx = do
    when (length (nub (map prevOutput (txIn tx))) < length (txIn tx)) $ do
        $(logErrorS) "Block" $
            "Transaction spends same output twice: " <> txHashToHex (txHash tx)
        throwError (DuplicatePrevOutput (txHashToHex (txHash tx)))
    when (iscb && not (confirmed br)) $ do
        $(logErrorS) "Block" $
            "Coinbase cannot be imported into mempool: " <>
            txHashToHex (txHash tx)
        throwError (UnconfirmedCoinbase (txHashToHex (txHash tx)))
    us' <-
        if iscb
            then return []
            else forM (txIn tx) $ \TxIn {prevOutput = op} -> uns op
    let us = map fst us'
        ths = nub (concatMap snd us')
    when
        (not (confirmed br) &&
         sum (map unspentAmount us) < sum (map outValue (txOut tx))) $ do
        $(logErrorS) "Block" $
            "Insufficient funds for tx: " <> txHashToHex (txHash tx)
        throwError (InsufficientFunds (txHashToHex th))
    zipWithM_ (spendOutput net br (txHash tx)) [0 ..] us
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
    unless (confirmed br) $ insertIntoMempool (txHash tx) (memRefTime br)
    return ths
  where
    uns op =
        getUnspent op >>= \case
            Just u -> return (u, [])
            Nothing -> do
                $(logWarnS) "Block" $
                    "Unspent output not found: " <>
                    txHashToHex (outPointHash op) <>
                    " " <>
                    fromString (show (outPointIndex op))
                getSpender op >>= \case
                    Nothing -> do
                        $(logErrorS) "Block" $
                            "Output not found: " <>
                            txHashToHex (outPointHash op) <>
                            " " <>
                            fromString (show (outPointIndex op))
                        throwError (NoUnspent (cs (show op)))
                    Just Spender {spenderHash = s} -> do
                        ths <- deleteTx net True s
                        getUnspent op >>= \case
                            Nothing -> do
                                $(logErrorS) "Block" $
                                    "Cannot unspend output: " <>
                                    txHashToHex (outPointHash op) <>
                                    " " <>
                                    fromString (show (outPointIndex op))
                                throwError (NoUnspent (cs (show op)))
                            Just u -> return (u, ths)
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
                deleteAddrTx
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
            deleteUnspent op
            insertUnspent
                Unspent
                    { unspentBlock = br
                    , unspentPoint = op
                    , unspentAmount = outValue o
                    , unspentScript = B.Short.toShort (scriptOutput o)
                    }
        case scriptToAddressBS (scriptOutput o) of
            Left _ -> return ()
            Right a -> do
                deleteAddrTx
                    a
                    BlockTx
                        {blockTxBlock = txDataBlock t, blockTxHash = txHash tx}
                insertAddrTx
                    a
                    BlockTx {blockTxBlock = br, blockTxHash = txHash tx}
                when (isNothing s) $ do
                    deleteAddrUnspent
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
    deleteFromMempool (txHash tx)

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

deleteFromMempool :: (Monad m, StoreRead m, StoreWrite m) => TxHash -> m ()
deleteFromMempool th = do
    mp <- getMempool
    setMempool $ filter ((/= th) . blockTxHash) mp

insertIntoMempool :: (Monad m, StoreRead m, StoreWrite m) => TxHash -> UnixTime -> m ()
insertIntoMempool th unixtime = do
    mp <- getMempool
    setMempool . reverse . sort $
        BlockTx {blockTxBlock = MemRef unixtime, blockTxHash = th} : mp

deleteTx ::
       ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => Network
    -> Bool -- ^ only delete transaction if unconfirmed
    -> TxHash
    -> m [TxHash] -- ^ deleted transactions
deleteTx net mo h = do
    getTxData h >>= \case
        Nothing -> do
            $(logErrorS) "Block" $ "Cannot find tx to delete: " <> txHashToHex h
            throwError (TxNotFound (txHashToHex h))
        Just t
            | txDataDeleted t -> do
                $(logWarnS) "Block" $ "Already deleted tx: " <> txHashToHex h
                return []
            | mo && confirmed (txDataBlock t) -> do
                $(logErrorS) "Block" $
                    "Will not delete confirmed tx: " <> txHashToHex h
                throwError (TxConfirmed (txHashToHex h))
            | otherwise -> go t
  where
    go t = do
        ss <- nub . map spenderHash . I.elems <$> getSpenders h
        ths <- concat <$> mapM (deleteTx net True) ss
        forM_ (take (length (txOut (txData t))) [0 ..]) $ \n ->
            delOutput net (OutPoint h n)
        let ps = filter (/= nullOutPoint) (map prevOutput (txIn (txData t)))
        mapM_ (unspendOutput net) ps
        unless (confirmed (txDataBlock t)) $ deleteFromMempool h
        insertTx t {txDataDeleted = True}
        updateAddressCounts net (txDataAddresses t) (subtract 1)
        return $ nub (h : ths)

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
            getImportTx (outPointHash op) >>= getTxOutput (outPointIndex op)
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
                            $(logErrorS) "Block" $
                                "Tx not found: " <> txHashToHex h
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
       , MonadLogger m
       )
    => Network
    -> BlockRef
    -> OutPoint
    -> TxOut
    -> m ()
newOutput _ br op to = do
    insertUnspent u
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
       , MonadLogger m
       , MonadError ImportException m
       )
    => Network
    -> OutPoint
    -> m ()
delOutput net op = do
    t <- getImportTx (outPointHash op)
    u <- getTxOutput (outPointIndex op) t
    deleteUnspent op
    case scriptToAddressBS (outputScript u) of
        Left _ -> return ()
        Right a -> do
            deleteAddrUnspent
                a
                Unspent
                    { unspentScript = B.Short.toShort (outputScript u)
                    , unspentBlock = transactionBlock t
                    , unspentPoint = op
                    , unspentAmount = outputAmount u
                    }
            deleteAddrTx
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
            $(logErrorS) "Block" $ "Tx not found: " <> txHashToHex th
            throwError $ TxNotFound (txHashToHex th)
        Just d
            | txDataDeleted d -> do
                $(logErrorS) "Block" $ "Tx deleted: " <> txHashToHex th
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
        $(logErrorS) "Block" $
            "Output out of range: " <> txHashToHex (txHash (transactionData tx)) <>
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
            deleteAddrUnspent a u
            insertAddrTx a BlockTx {blockTxHash = th, blockTxBlock = br}
    deleteUnspent (unspentPoint u)

unspendOutput ::
       ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => Network
    -> OutPoint
    -> m ()
unspendOutput _ op = do
    t <- getImportTx (outPointHash op)
    o <- getTxOutput (outPointIndex op) t
    s <-
        case outputSpender o of
            Nothing -> do
                $(logErrorS) "Block" $
                    "Output already unspent: " <> txHashToHex (outPointHash op) <>
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
    insertUnspent u
    case scriptToAddressBS (outputScript o) of
        Left _ -> return ()
        Right a -> do
            insertAddrUnspent a u
            deleteAddrTx
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
       , MonadLogger m
       , MonadError ImportException m
       )
    => Network
    -> Bool -- ^ spend or delete confirmed output
    -> Bool -- ^ reduce total received
    -> Address
    -> Word64
    -> m ()
reduceBalance net c t a v =
    getBalance a >>= \b ->
        if nullBalance b
            then do
                $(logErrorS) "Block" $
                    "Address balance not found: " <> addrText net a
                throwError (BalanceNotFound (addrText net a))
            else do
                when (v > amnt b) $ do
                    $(logErrorS) "Block" $
                        "Insufficient " <> conf <> " balance: " <>
                        addrText net a <>
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

increaseBalance ::
       ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       )
    => Bool -- ^ add confirmed output
    -> Bool -- ^ increase total received
    -> Address
    -> Word64
    -> m ()
increaseBalance c t a v = do
    b <- getBalance a
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

updateAddressCounts ::
       (StoreWrite m, StoreRead m, Monad m, MonadError ImportException m)
    => Network
    -> [Address]
    -> (Word64 -> Word64)
    -> m ()
updateAddressCounts net as f =
    forM_ as $ \a -> do
        b <-
            getBalance a >>= \b -> if nullBalance b
                then throwError (BalanceNotFound (addrText net a))
                else return b
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
