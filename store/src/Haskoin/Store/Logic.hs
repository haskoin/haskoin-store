{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
module Haskoin.Store.Logic
    ( ImportException (..)
    , initBest
    , getOldMempool
    , revertBlock
    , importBlock
    , newMempoolTx
    , deleteTx
    ) where

import           Control.Monad           (forM, forM_, unless, void, when,
                                          zipWithM_)
import           Control.Monad.Except    (MonadError (..))
import           Control.Monad.Logger    (MonadLogger, logDebugS, logErrorS,
                                          logWarnS)
import qualified Data.ByteString         as B
import qualified Data.ByteString.Short   as B.Short
import           Data.Either             (rights)
import qualified Data.IntMap.Strict      as I
import           Data.List               (nub, sort)
import           Data.Maybe              (fromMaybe, isNothing)
import           Data.Serialize          (encode)
import           Data.String             (fromString)
import           Data.String.Conversions (cs)
import           Data.Text               (Text)
import           Data.Word               (Word32, Word64)
import           Haskoin                 (Address, Block (..), BlockHash,
                                          BlockHeader (..), BlockNode (..),
                                          Network (..), OutPoint (..), Tx (..),
                                          TxHash, TxIn (..), TxOut (..),
                                          addrToString, blockHashToHex,
                                          computeSubsidy, genesisBlock,
                                          genesisNode, headerHash, isGenesis,
                                          nullOutPoint, scriptToAddressBS,
                                          txHash, txHashToHex)
import           Haskoin.Store.Common    (StoreRead (..), StoreWrite (..),
                                          sortTxs)
import           Haskoin.Store.Data      (Balance (..), BlockData (..),
                                          BlockRef (..), BlockTx (..),
                                          Prev (..), Spender (..),
                                          StoreInput (..), StoreOutput (..),
                                          Transaction (..), TxData (..),
                                          UnixTime, Unspent (..), confirmed,
                                          fromTransaction, isCoinbase,
                                          nullBalance, toTransaction,
                                          transactionData)
import           UnliftIO                (Exception)

data ImportException
    = PrevBlockNotBest !Text
    | TxOrphan !Text
    | UnconfirmedCoinbase !Text
    | BestBlockUnknown
    | BestBlockNotFound !Text
    | BlockNotBest !Text
    | TxNotFound !Text
    | OutputSpent !Text
    | CannotDeleteNonRBF !Text
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
    => m ()
initBest = do
    net <- getNetwork
    m <- getBestBlock
    when
        (isNothing m)
        (void (importBlock (genesisBlock net) (genesisNode net)))

getOldMempool :: StoreRead m => UnixTime -> m [TxHash]
getOldMempool now =
    map blockTxHash . filter ((< now - 3600 * 72) . memRefTime . blockTxBlock) <$>
    getMempool

newMempoolTx ::
       (StoreRead m, StoreWrite m, MonadLogger m, MonadError ImportException m)
    => Tx
    -> UnixTime
    -> m (Maybe [TxHash])
    -- ^ deleted transactions or nothing if already imported
newMempoolTx tx w =
    getTxData (txHash tx) >>= \case
        Just x
            | not (txDataDeleted x) -> do
                $(logDebugS) "BlockStore" $
                    "Transaction already in store: " <> txHashToHex (txHash tx)
                return Nothing
        _ -> Just <$> importTx (MemRef w) w tx

revertBlock ::
       ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => BlockHash
    -> m [TxHash]
revertBlock bh = do
    bd <-
        getBestBlock >>= \case
            Nothing -> do
                $(logErrorS) "BlockStore" "Best block unknown"
                throwError BestBlockUnknown
            Just h ->
                getBlock h >>= \case
                    Nothing -> do
                        $(logErrorS) "BlockStore" "Best block not found"
                        throwError (BestBlockNotFound (blockHashToHex h))
                    Just b
                        | h == bh -> return b
                        | otherwise -> do
                            $(logErrorS) "BlockStore" $
                                "Cannot delete block that is not head: " <>
                                blockHashToHex h
                            throwError (BlockNotBest (blockHashToHex bh))
    txs <- mapM (fmap transactionData . getImportTx) (blockDataTxs bd)
    ths <-
        nub . concat <$>
        mapM (deleteTx False False . txHash . snd) (reverse (sortTxs txs))
    setBest (prevBlock (blockDataHeader bd))
    insertBlock bd {blockDataMainChain = False}
    return ths

importBlock ::
       ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => Block
    -> BlockNode
    -> m [TxHash] -- ^ deleted transactions
importBlock b n = do
    mp <- filter (`elem` bths) . map blockTxHash <$> getMempool
    getBestBlock >>= \case
        Nothing
            | isGenesis n -> return ()
            | otherwise -> do
                $(logErrorS) "BlockStore" $
                    "Cannot import non-genesis block at this point: " <>
                    blockHashToHex (headerHash (blockHeader b))
                throwError BestBlockUnknown
        Just h
            | prevBlock (blockHeader b) == h -> return ()
            | otherwise -> do
                $(logErrorS) "BlockStore" $
                    "Block does not build on head: " <>
                    blockHashToHex (headerHash (blockHeader b))
                throwError $
                    PrevBlockNotBest (blockHashToHex (prevBlock (nodeHeader n)))
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
            , blockDataWeight = fromIntegral w
            , blockDataSubsidy = subsidy
            , blockDataFees = cb_out_val - subsidy
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
                     Just td -> confirmTx td (br x) tx >> return []
                     Nothing -> do
                         $(logErrorS) "BlockStore" $
                             "Cannot get data for mempool tx: " <>
                             txHashToHex (txHash tx)
                         throwError $ TxNotFound (txHashToHex (txHash tx))
            else importTx
                     (br x)
                     (fromIntegral (blockTimestamp (nodeHeader n)))
                     tx
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
    => BlockRef
    -> Word64 -- ^ unix time
    -> Tx
    -> m [TxHash] -- ^ deleted transactions
importTx br tt tx = do
    unless (confirmed br) $
        $(logDebugS) "BlockStore" $
        "Importing transaction " <> txHashToHex (txHash tx)
    when (length (nub (map prevOutput (txIn tx))) < length (txIn tx)) $ do
        $(logErrorS) "BlockStore" $
            "Transaction spends same output twice: " <> txHashToHex (txHash tx)
        throwError (DuplicatePrevOutput (txHashToHex (txHash tx)))
    when (iscb && not (confirmed br)) $ do
        $(logErrorS) "BlockStore" $
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
        $(logErrorS) "BlockStore" $
            "Insufficient funds for tx: " <> txHashToHex (txHash tx)
        throwError (InsufficientFunds (txHashToHex th))
    rbf <- isRBF br tx
    commit rbf us
    return ths
  where
    commit rbf us = do
        zipWithM_ (spendOutput br (txHash tx)) [0 ..] us
        zipWithM_
            (\i o -> newOutput br (OutPoint (txHash tx) i) o)
            [0 ..]
            (txOut tx)
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
        updateAddressCounts (txAddresses t) (+ 1)
        unless (confirmed br) $ insertIntoMempool (txHash tx) (memRefTime br)
    uns op =
        getUnspent op >>= \case
            Just u -> return (u, [])
            Nothing -> do
                $(logWarnS) "BlockStore" $
                    "Unspent output not found: " <>
                    txHashToHex (outPointHash op) <>
                    " " <>
                    fromString (show (outPointIndex op))
                getSpender op >>= \case
                    Nothing -> do
                        $(logErrorS) "BlockStore" $
                            "Output not found: " <>
                            txHashToHex (outPointHash op) <>
                            " " <>
                            fromString (show (outPointIndex op))
                        $(logErrorS) "BlockStore" $
                            "Orphan tx: " <> txHashToHex (txHash tx)
                        throwError (TxOrphan (txHashToHex (txHash tx)))
                    Just Spender {spenderHash = s} -> do
                        $(logWarnS) "BlockStore" $
                            "Deleting transaction " <> txHashToHex s <>
                            " because it conflicts with " <>
                            txHashToHex (txHash tx)
                        ths <- deleteTx True (not (confirmed br)) s
                        getUnspent op >>= \case
                            Nothing -> do
                                $(logErrorS) "BlockStore" $
                                    "Cannot unspend output: " <>
                                    txHashToHex (outPointHash op) <>
                                    " " <>
                                    fromString (show (outPointIndex op))
                                throwError (OutputSpent (cs (show op)))
                            Just u -> return (u, ths)
    th = txHash tx
    iscb = all (== nullOutPoint) (map prevOutput (txIn tx))
    ws = map Just (txWitness tx) <> repeat Nothing
    mkcb ip w =
        StoreCoinbase
            { inputPoint = prevOutput ip
            , inputSequence = txInSequence ip
            , inputSigScript = scriptInput ip
            , inputWitness = w
            }
    mkin u ip w =
        let script = B.Short.fromShort (unspentScript u)
         in StoreInput
                { inputPoint = prevOutput ip
                , inputSequence = txInSequence ip
                , inputSigScript = scriptInput ip
                , inputPkScript = script
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
    => TxData
    -> BlockRef
    -> Tx
    -> m ()
confirmTx t br tx = do
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
                    reduceBalance False False a (outValue o)
                    increaseBalance True False a (outValue o)
    insertTx t {txDataBlock = br}
    deleteFromMempool (txHash tx)

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
    => Bool -- ^ only delete transaction if unconfirmed
    -> Bool -- ^ do RBF check before deleting transaction
    -> TxHash
    -> m [TxHash] -- ^ deleted transactions
deleteTx memonly rbfcheck txhash = do
    getTxData txhash >>= \case
        Nothing -> do
            $(logErrorS) "BlockStore" $
                "Cannot find tx to delete: " <> txHashToHex txhash
            throwError (TxNotFound (txHashToHex txhash))
        Just t
            | txDataDeleted t -> do
                $(logWarnS) "BlockStore" $
                    "Already deleted tx: " <> txHashToHex txhash
                return []
            | memonly && confirmed (txDataBlock t) -> do
                $(logErrorS) "BlockStore" $
                    "Will not delete confirmed tx: " <> txHashToHex txhash
                throwError (TxConfirmed (txHashToHex txhash))
            | rbfcheck ->
                isRBF (txDataBlock t) (txData t) >>= \case
                    True -> go t
                    False -> do
                        $(logErrorS) "BlockStore" $
                            "Delete non-RBF transaction attempted: " <>
                            txHashToHex txhash
                        throwError $ CannotDeleteNonRBF (txHashToHex txhash)
            | otherwise -> go t
  where
    go t = do
        $(logWarnS) "BlockStore" $
            "Deleting transaction: " <> txHashToHex txhash
        ss <- nub . map spenderHash . I.elems <$> getSpenders txhash
        ths <-
            fmap concat $
            forM ss $ \s -> do
                $(logWarnS) "BlockStore" $
                    "Deleting descendant " <> txHashToHex s <>
                    " to delete parent " <>
                    txHashToHex txhash
                deleteTx True rbfcheck s
        forM_ (take (length (txOut (txData t))) [0 ..]) $ \n ->
            delOutput (OutPoint txhash n)
        let ps = filter (/= nullOutPoint) (map prevOutput (txIn (txData t)))
        mapM_ unspendOutput ps
        unless (confirmed (txDataBlock t)) $ deleteFromMempool txhash
        insertTx t {txDataDeleted = True}
        updateAddressCounts (txDataAddresses t) (subtract 1)
        return $ nub (txhash : ths)


isRBF ::
       (StoreRead m, MonadLogger m, MonadError ImportException m)
    => BlockRef
    -> Tx
    -> m Bool
isRBF br tx =
    getNetwork >>= \net ->
        if getReplaceByFee net
            then go
            else return False
  where
    go
        | all (== nullOutPoint) (map prevOutput (txIn tx)) = return False
        | any ((< 0xffffffff - 1) . txInSequence) (txIn tx) = return True
        | confirmed br = return False
        | otherwise =
            let hs = nub $ map (outPointHash . prevOutput) (txIn tx)
                ck [] = return False
                ck (h:hs') =
                    getTxData h >>= \case
                        Nothing -> do
                            $(logErrorS) "BlockStore" $
                                "Transaction not found: " <> txHashToHex h
                            throwError (TxNotFound (txHashToHex h))
                        Just t
                            | confirmed (txDataBlock t) -> ck hs'
                            | txDataRBF t -> return True
                            | otherwise -> ck hs'
             in ck hs

newOutput ::
       ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       )
    => BlockRef
    -> OutPoint
    -> TxOut
    -> m ()
newOutput br op to = do
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
    => OutPoint
    -> m ()
delOutput op = do
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
            $(logErrorS) "BlockStore" $ "Tx not found: " <> txHashToHex th
            throwError $ TxNotFound (txHashToHex th)
        Just d
            | txDataDeleted d -> do
                $(logErrorS) "BlockStore" $ "Tx deleted: " <> txHashToHex th
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
        $(logErrorS) "BlockStore" $
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
    => BlockRef
    -> TxHash
    -> Word32
    -> Unspent
    -> m ()
spendOutput br th ix u = do
    insertSpender (unspentPoint u) Spender {spenderHash = th, spenderIndex = ix}
    case scriptToAddressBS (B.Short.fromShort (unspentScript u)) of
        Left _ -> return ()
        Right a -> do
            reduceBalance
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
    => OutPoint
    -> m ()
unspendOutput op = do
    t <- getImportTx (outPointHash op)
    o <- getTxOutput (outPointIndex op) t
    s <-
        case outputSpender o of
            Nothing -> do
                $(logErrorS) "BlockStore" $
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
    => Bool -- ^ spend or delete confirmed output
    -> Bool -- ^ reduce total received
    -> Address
    -> Word64
    -> m ()
reduceBalance c t a v = do
    net <- getNetwork
    b <- getBalance a
    if nullBalance b
        then do
            $(logErrorS) "BlockStore" $
                "Address balance not found: " <> addrText net a
            throwError (BalanceNotFound (addrText net a))
        else do
            when (v > amnt b) $ do
                $(logErrorS) "BlockStore" $
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
    => [Address]
    -> (Word64 -> Word64)
    -> m ()
updateAddressCounts as f =
    forM_ as $ \a -> do
        b <-
            do net <- getNetwork
               b <- getBalance a
               if nullBalance b
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
