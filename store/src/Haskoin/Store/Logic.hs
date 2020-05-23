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

import           Control.Monad           (forM, forM_, guard, unless, void,
                                          when, zipWithM_)
import           Control.Monad.Except    (MonadError (..))
import           Control.Monad.Logger    (MonadLogger, logDebugS, logErrorS)
import qualified Data.ByteString         as B
import qualified Data.ByteString.Short   as B.Short
import           Data.Either             (rights)
import qualified Data.IntMap.Strict      as I
import           Data.List               (nub, sort)
import           Data.Maybe              (isNothing)
import           Data.Serialize          (encode)
import           Data.String             (fromString)
import           Data.String.Conversions (cs)
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
import           Haskoin.Store.Common    (StoreRead (..), StoreWrite (..), nub',
                                          sortTxs)
import           Haskoin.Store.Data      (Balance (..), BlockData (..),
                                          BlockRef (..), Prev (..),
                                          Spender (..), TxData (..), TxRef (..),
                                          UnixTime, Unspent (..), confirmed,
                                          nullBalance)
import           UnliftIO                (Exception)

data ImportException
    = PrevBlockNotBest
    | Orphan
    | UnexpectedCoinbase
    | BestBlockUnknown
    | BestBlockNotFound
    | BlockNotBest
    | TxNotFound
    | DoubleSpend
    | TxDeleted
    | AlreadyUnspent
    | TxConfirmed
    | OutputOutOfRange
    | BalanceNotFound
    | InsufficientFunds
    | DuplicatePrevOutput
    deriving (Eq, Ord, Exception)

instance Show ImportException where
    show PrevBlockNotBest    = "previous block not best"
    show Orphan              = "orphan"
    show UnexpectedCoinbase  = "unexpected coinbase"
    show BestBlockUnknown    = "best block unknown"
    show BestBlockNotFound   = "best block not found"
    show BlockNotBest        = "block not best"
    show TxNotFound          = "transaction not found"
    show DoubleSpend         = "double spend"
    show TxDeleted           = "transaction deleted"
    show AlreadyUnspent      = "already unspent"
    show TxConfirmed         = "transaction confirmed"
    show OutputOutOfRange    = "output out of range"
    show BalanceNotFound     = "balance not found"
    show InsufficientFunds   = "insufficient funds"
    show DuplicatePrevOutput = "duplicate previous output"

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
    map txRefHash . filter ((< now - 3600 * 72) . memRefTime . txRefBlock) <$>
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
                        throwError BestBlockNotFound
                    Just b
                        | h == bh -> return b
                        | otherwise -> do
                            $(logErrorS) "BlockStore" $
                                "Cannot delete block that is not head: " <>
                                blockHashToHex h
                            throwError BlockNotBest
    txs <- mapM (fmap txData . getImportTxData) (blockDataTxs bd)
    ths <-
        nub' . concat <$>
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
    mp <- filter (`elem` bths) . map txRefHash <$> getMempool
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
                throwError PrevBlockNotBest
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
            , blockDataWeight =
                  if getSegWit net
                      then fromIntegral w
                      else 0
            , blockDataSubsidy = subsidy
            , blockDataFees = cb_out_val - subsidy
            , blockDataOutputs = ts_out_val
            }
    bs <- getBlocksAtHeight (nodeHeight n)
    setBlocksAtHeight (nub (headerHash (nodeHeader n) : bs)) (nodeHeight n)
    setBest (headerHash (nodeHeader n))
    ths <-
        nub' . concat <$>
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
                         throwError TxNotFound
            else importTx
                     (br x)
                     (fromIntegral (blockTimestamp (nodeHeader n)))
                     tx
    cb_out_val = sum (map outValue (txOut (head (blockTxns b))))
    ts_out_val = sum (map (sum . map outValue . txOut) (tail (blockTxns b)))
    br pos = BlockRef {blockRefHeight = nodeHeight n, blockRefPos = pos}
    w =
        let s =
                B.length $
                encode
                    b {blockTxns = map (\t -> t {txWitness = []}) (blockTxns b)}
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
    unless (confirmed br) $ do
        $(logDebugS) "BlockStore" $ "Importing transaction " <> txHashToHex th
        when (length (nub' (map prevOutput (txIn tx))) < length (txIn tx)) $ do
            $(logDebugS) "BlockStore" $
                "Transaction spends same output twice: " <>
                txHashToHex (txHash tx)
            throwError DuplicatePrevOutput
        when iscb $ do
            $(logDebugS) "BlockStore" $
                "Coinbase cannot be imported into mempool: " <>
                txHashToHex (txHash tx)
            throwError UnexpectedCoinbase
    us' <-
        if iscb
            then return []
            else forM (txIn tx) $ \TxIn {prevOutput = op} -> uns op
    let us = map fst us'
        ths = nub' (concatMap snd us')
    when
        (not (confirmed br) &&
         sum (map unspentAmount us) < sum (map outValue (txOut tx))) $ do
        $(logDebugS) "BlockStore" $
            "Insufficient funds for tx: " <> txHashToHex (txHash tx)
        throwError InsufficientFunds
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
        let ps =
                I.fromList . zip [0 ..] $
                if iscb
                    then []
                    else map mkprv us
            d =
                TxData
                    { txDataBlock = br
                    , txData = tx
                    , txDataPrevs = ps
                    , txDataDeleted = False
                    , txDataRBF = rbf
                    , txDataTime = tt
                    }
        insertTx d
        updateAddressCounts (txDataAddresses d) (+ 1)
        unless (confirmed br) $ insertIntoMempool (txHash tx) (memRefTime br)
    uns op =
        getUnspent op >>= \case
            Just u -> return (u, [])
            Nothing -> do
                $(logDebugS) "BlockStore" $
                    "Unspent output not found: " <>
                    txHashToHex (outPointHash op) <>
                    " " <>
                    fromString (show (outPointIndex op))
                getSpender op >>= \case
                    Nothing -> do
                        $(logDebugS) "BlockStore" $
                            "Output not found: " <>
                            txHashToHex (outPointHash op) <>
                            " " <>
                            fromString (show (outPointIndex op))
                        $(logDebugS) "BlockStore" $
                            "Orphan tx: " <> txHashToHex (txHash tx)
                        throwError Orphan
                    Just Spender {spenderHash = s} -> do
                        $(logDebugS) "BlockStore" $
                            "Deleting transaction " <> txHashToHex s <>
                            " because it conflicts with " <>
                            txHashToHex (txHash tx)
                        ths <- deleteTx True (not (confirmed br)) s
                        getUnspent op >>= \case
                            Nothing -> do
                                $(logDebugS) "BlockStore" $
                                    "Could not unspend output: " <>
                                    txHashToHex (outPointHash op) <>
                                    "/" <>
                                    fromString (show (outPointIndex op))
                                throwError DoubleSpend
                            Just u -> return (u, ths)
    th = txHash tx
    iscb = all (== nullOutPoint) (map prevOutput (txIn tx))
    mkprv u = Prev (B.Short.fromShort (unspentScript u)) (unspentAmount u)

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
                    TxRef
                        {txRefBlock = txDataBlock t, txRefHash = txHash tx}
                insertAddrTx
                    a
                    TxRef {txRefBlock = br, txRefHash = txHash tx}
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
                    , unspentAddress =
                          eitherToMaybe (scriptToAddressBS (scriptOutput o))
                    }
        case scriptToAddressBS (scriptOutput o) of
            Left _ -> return ()
            Right a -> do
                deleteAddrTx
                    a
                    TxRef
                        {txRefBlock = txDataBlock t, txRefHash = txHash tx}
                insertAddrTx
                    a
                    TxRef {txRefBlock = br, txRefHash = txHash tx}
                when (isNothing s) $ do
                    deleteAddrUnspent
                        a
                        Unspent
                            { unspentBlock = txDataBlock t
                            , unspentPoint = op
                            , unspentAmount = outValue o
                            , unspentScript = B.Short.toShort (scriptOutput o)
                            , unspentAddress =
                                  eitherToMaybe
                                      (scriptToAddressBS (scriptOutput o))
                            }
                    insertAddrUnspent
                        a
                        Unspent
                            { unspentBlock = br
                            , unspentPoint = op
                            , unspentAmount = outValue o
                            , unspentScript = B.Short.toShort (scriptOutput o)
                            , unspentAddress =
                                  eitherToMaybe
                                      (scriptToAddressBS (scriptOutput o))
                            }
                    decreaseMempoolBalance a (outValue o)
                    increaseConfirmedBalance a (outValue o)
    insertTx t {txDataBlock = br}
    deleteFromMempool (txHash tx)

deleteFromMempool :: (Monad m, StoreRead m, StoreWrite m) => TxHash -> m ()
deleteFromMempool th = do
    mp <- getMempool
    setMempool $ filter ((/= th) . txRefHash) mp

insertIntoMempool :: (Monad m, StoreRead m, StoreWrite m) => TxHash -> UnixTime -> m ()
insertIntoMempool th unixtime = do
    mp <- getMempool
    setMempool . reverse . sort $
        TxRef {txRefBlock = MemRef unixtime, txRefHash = th} : mp

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
            $(logDebugS) "BlockStore" $
                "Cannot find tx to delete: " <> txHashToHex txhash
            throwError TxNotFound
        Just t
            | txDataDeleted t -> do
                $(logDebugS) "BlockStore" $
                    "Already deleted tx: " <> txHashToHex txhash
                return []
            | memonly && confirmed (txDataBlock t) -> do
                $(logDebugS) "BlockStore" $
                    "Will not delete confirmed tx: " <> txHashToHex txhash
                throwError TxConfirmed
            | rbfcheck ->
                isRBF (txDataBlock t) (txData t) >>= \case
                    True -> go t
                    False -> do
                        $(logDebugS) "BlockStore" $
                            "Delete non-RBF transaction attempted: " <>
                            txHashToHex txhash
                        throwError DoubleSpend
            | otherwise -> go t
  where
    go t = do
        $(logDebugS) "BlockStore" $ "Deleting tx: " <> txHashToHex txhash
        ss <- nub' . map spenderHash . I.elems <$> getSpenders txhash
        ths <-
            fmap concat $
            forM ss $ \s -> do
                $(logDebugS) "BlockStore" $
                    "Deleting descendant tx " <> txHashToHex s <>
                    " to delete parent tx " <>
                    txHashToHex txhash
                deleteTx True rbfcheck s
        forM_ (take (length (txOut (txData t))) [0 ..]) $ \n ->
            delOutput (OutPoint txhash n)
        let ps = filter (/= nullOutPoint) (map prevOutput (txIn (txData t)))
        mapM_ unspendOutput ps
        unless (confirmed (txDataBlock t)) $ deleteFromMempool txhash
        insertTx t {txDataDeleted = True}
        updateAddressCounts (txDataAddresses t) (subtract 1)
        return $ nub' (txhash : ths)


isRBF ::
       (StoreRead m, MonadLogger m, MonadError ImportException m)
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
    go
        | all (== nullOutPoint) (map prevOutput (txIn tx)) = return False
        | any ((< 0xffffffff - 1) . txInSequence) (txIn tx) = return True
        | otherwise =
            let hs = nub' $ map (outPointHash . prevOutput) (txIn tx)
                ck [] = return False
                ck (h:hs') =
                    getTxData h >>= \case
                        Nothing -> do
                            $(logDebugS) "BlockStore" $
                                "Transaction not found: " <> txHashToHex h
                            throwError TxNotFound
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
            insertAddrTx a TxRef {txRefHash = outPointHash op, txRefBlock = br}
            if confirmed br
                then increaseConfirmedBalance a (outValue to)
                else increaseMempoolBalance a (outValue to)
            modifyTotalReceived a (+ outValue to)
  where
    u =
        Unspent
            { unspentBlock = br
            , unspentAmount = outValue to
            , unspentScript = B.Short.toShort (scriptOutput to)
            , unspentPoint = op
            , unspentAddress =
                  eitherToMaybe (scriptToAddressBS (scriptOutput to))
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
    t <- getImportTxData (outPointHash op)
    u <-
        case getTxOut (outPointIndex op) (txData t) of
            Just u -> return u
            Nothing -> do
                $(logDebugS) "BlockStore" $
                    "Output out of range: " <> txHashToHex (txHash (txData t)) <>
                    "/" <>
                    fromString (show (outPointIndex op))
                throwError OutputOutOfRange
    deleteUnspent op
    case scriptToAddressBS (scriptOutput u) of
        Left _ -> return ()
        Right a -> do
            deleteAddrUnspent
                a
                Unspent
                    { unspentScript = B.Short.toShort (scriptOutput u)
                    , unspentBlock = txDataBlock t
                    , unspentPoint = op
                    , unspentAmount = outValue u
                    , unspentAddress =
                          eitherToMaybe (scriptToAddressBS (scriptOutput u))
                    }
            deleteAddrTx
                a
                TxRef {txRefHash = outPointHash op, txRefBlock = txDataBlock t}
            if confirmed (txDataBlock t)
                then decreaseConfirmedBalance a (outValue u)
                else decreaseMempoolBalance a (outValue u)
            modifyTotalReceived a (subtract (outValue u))

getImportTxData ::
       (StoreRead m, MonadLogger m, MonadError ImportException m)
    => TxHash
    -> m TxData
getImportTxData th =
    getTxData th >>= \case
        Nothing -> do
            $(logDebugS) "BlockStore" $ "Tx not found: " <> txHashToHex th
            throwError TxNotFound
        Just d
            | txDataDeleted d -> do
                $(logDebugS) "BlockStore" $ "Tx deleted: " <> txHashToHex th
                throwError TxDeleted
            | otherwise -> return d

getTxOut
    :: Word32
    -> Tx
    -> Maybe TxOut
getTxOut i tx = do
    guard (fromIntegral i < length (txOut tx))
    return $ txOut tx !! fromIntegral i

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
            if confirmed (unspentBlock u)
                then decreaseConfirmedBalance a (unspentAmount u)
                else decreaseMempoolBalance a (unspentAmount u)
            deleteAddrUnspent a u
            insertAddrTx a TxRef {txRefHash = th, txRefBlock = br}
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
    t <- getImportTxData (outPointHash op)
    o <-
        case getTxOut (outPointIndex op) (txData t) of
            Nothing -> do
                $(logDebugS) "BlockStore" $
                    "Output out of range: " <> txHashToHex (outPointHash op) <>
                    "/" <>
                    cs (show (outPointIndex op))
                throwError OutputOutOfRange
            Just o -> return o
    s <-
        getSpender op >>= \case
            Nothing -> do
                $(logDebugS) "BlockStore" $
                    "Output already unspent: " <> txHashToHex (outPointHash op) <>
                    "/" <>
                    cs (show (outPointIndex op))
                throwError AlreadyUnspent
            Just s -> return s
    x <- getImportTxData (spenderHash s)
    deleteSpender op
    let m = eitherToMaybe (scriptToAddressBS (scriptOutput o))
    let u =
            Unspent
                { unspentAmount = outValue o
                , unspentBlock = txDataBlock t
                , unspentScript = B.Short.toShort (scriptOutput o)
                , unspentPoint = op
                , unspentAddress = m
                }
    insertUnspent u
    case m of
        Nothing -> return ()
        Just a -> do
            insertAddrUnspent a u
            deleteAddrTx
                a
                TxRef {txRefHash = spenderHash s, txRefBlock = txDataBlock x}
            if confirmed (unspentBlock u)
                then increaseConfirmedBalance a (outValue o)
                else increaseMempoolBalance a (outValue o)

modifyTotalReceived ::
    (StoreRead m, StoreWrite m, MonadLogger m)
    => Address -> (Word64 -> Word64) -> m ()
modifyTotalReceived addr f = do
    b <- getBalance addr
    setBalance b {balanceTotalReceived = f (balanceTotalReceived b)}

decreaseConfirmedBalance ::
       (StoreRead m, StoreWrite m, MonadLogger m)
    => Address
    -> Word64
    -> m ()
decreaseConfirmedBalance addr val = do
    b <- getBalance addr
    setBalance
        b
            { balanceAmount = balanceAmount b - val
            , balanceUnspentCount = balanceUnspentCount b - 1
            }

increaseConfirmedBalance ::
       (StoreRead m, StoreWrite m, MonadLogger m)
    => Address
    -> Word64
    -> m ()
increaseConfirmedBalance addr val = do
    b <- getBalance addr
    setBalance
        b
            { balanceAmount = balanceAmount b + val
            , balanceUnspentCount = balanceUnspentCount b + 1
            }

decreaseMempoolBalance ::
       (StoreRead m, StoreWrite m, MonadLogger m)
    => Address
    -> Word64
    -> m ()
decreaseMempoolBalance addr val = do
    b <- getBalance addr
    setBalance
        b
            { balanceZero = balanceZero b - val
            , balanceUnspentCount = balanceUnspentCount b - 1
            }

increaseMempoolBalance ::
       (StoreRead m, StoreWrite m, MonadLogger m)
    => Address
    -> Word64
    -> m ()
increaseMempoolBalance addr val = do
    b <- getBalance addr
    setBalance
        b
            { balanceZero = balanceZero b + val
            , balanceUnspentCount = balanceUnspentCount b + 1
            }

updateAddressCounts ::
       (StoreWrite m, StoreRead m, Monad m, MonadError ImportException m)
    => [Address]
    -> (Word64 -> Word64)
    -> m ()
updateAddressCounts as f =
    forM_ as $ \a -> do
        b <-
            do b <- getBalance a
               if nullBalance b
                   then throwError BalanceNotFound
                   else return b
        setBalance b {balanceTxCount = f (balanceTxCount b)}

txDataAddresses :: TxData -> [Address]
txDataAddresses t =
    nub' . rights $
    map (scriptToAddressBS . prevScript) (I.elems (txDataPrevs t)) <>
    map (scriptToAddressBS . scriptOutput) (txOut (txData t))
