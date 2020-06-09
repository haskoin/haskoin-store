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

import           Control.Monad             (forM, forM_, guard, unless, void,
                                            when, zipWithM_)
import           Control.Monad.Except      (MonadError (..))
import           Control.Monad.Logger      (MonadLogger, logDebugS, logErrorS,
                                            logWarnS)
import           Control.Monad.Trans       (lift)
import           Control.Monad.Trans.Maybe (MaybeT (MaybeT), runMaybeT)
import qualified Data.ByteString           as B
import qualified Data.ByteString.Short     as B.Short
import           Data.Either               (rights)
import qualified Data.IntMap.Strict        as I
import           Data.List                 (nub, sortOn)
import           Data.Maybe                (fromMaybe, isNothing)
import           Data.Ord                  (Down (Down))
import           Data.Serialize            (encode)
import           Data.String.Conversions   (cs)
import           Data.Text                 (Text)
import           Data.Word                 (Word32, Word64)
import           Haskoin                   (Address, Block (..), BlockHash,
                                            BlockHeader (..), BlockNode (..),
                                            Network (..), OutPoint (..),
                                            Tx (..), TxHash, TxIn (..),
                                            TxOut (..), blockHashToHex,
                                            computeSubsidy, eitherToMaybe,
                                            genesisBlock, genesisNode,
                                            headerHash, isGenesis, nullOutPoint,
                                            scriptToAddressBS, txHash,
                                            txHashToHex)
import           Haskoin.Store.Common      (StoreRead (..), StoreWrite (..),
                                            getActiveTxData, nub', sortTxs)
import           Haskoin.Store.Data        (Balance (..), BlockData (..),
                                            BlockRef (..), Prev (..),
                                            Spender (..), TxData (..),
                                            TxRef (..), UnixTime, Unspent (..),
                                            confirmed)
import           UnliftIO                  (Exception)

data ImportException = PrevBlockNotBest
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
    when (isNothing m) . void $
        importBlock (genesisBlock net) (genesisNode net)

getOldMempool :: StoreRead m => UnixTime -> m [TxHash]
getOldMempool now =
    map txRefHash
    . filter ((< now - 3600 * 72) . memRefTime . txRefBlock)
    <$> getMempool

newMempoolTx ::
       (StoreRead m, StoreWrite m, MonadLogger m, MonadError ImportException m)
    => Tx
    -> UnixTime
    -> m (Maybe [TxHash])
    -- ^ deleted transactions or nothing if already imported
newMempoolTx tx w =
    getActiveTxData (txHash tx) >>= \case
        Just _ -> do
            $(logDebugS) "BlockStore" $
                "Transaction already in store: " <>
                txHashToHex (txHash tx)
            return Nothing
        Nothing -> Just <$> importTx (MemRef w) w tx

bestBlockData
    :: ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => m BlockData
bestBlockData =
    getBestBlock >>= \case
        Nothing -> do
            $(logErrorS) "BlockStore" "Best block unknown"
            throwError BestBlockUnknown
        Just h ->
            getBlock h >>= \case
                Nothing -> do
                    $(logErrorS) "BlockStore" "Best block not found"
                    throwError BestBlockNotFound
                Just b -> return b

revertBlock
    :: ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => BlockHash
    -> m [TxHash]
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
    deleteTx False False (txHash (txData (head tds)))

checkNewBlock
    :: ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       , MonadError ImportException m
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

importOrConfirm
    :: ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => BlockNode
    -> [Tx]
    -> m [TxHash] -- ^ deleted transactions
importOrConfirm bn txs =
    fmap concat . forM (sortTxs txs) $ \(i, tx) ->
    getActiveTxData (txHash tx) >>= \case
        Just td
            | confirmed (txDataBlock td) -> do
                  $(logErrorS) "BlockStore" $
                      "Transaction already confirmed: " <>
                      txHashToHex (txHash tx)
                  throwError TxConfirmed
            | otherwise -> do
                  confirmTx td (br i)
                  return []
        Nothing ->
            importTx
            (br i)
            (fromIntegral (blockTimestamp (nodeHeader bn)))
            tx
  where
    br i = BlockRef {blockRefHeight = nodeHeight bn, blockRefPos = i}

importBlock
    :: ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => Block
    -> BlockNode
    -> m [TxHash] -- ^ deleted transactions
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
       , MonadLogger m
       , MonadError ImportException m
       )
    => Tx
    -> m ()
checkNewTx tx = do
    when (length (nub' (map prevOutput (txIn tx))) < length (txIn tx)) $ do
        $(logDebugS) "BlockStore" $
            "Transaction spends same output twice: " <>
            txHashToHex (txHash tx)
        throwError DuplicatePrevOutput
    when (isCoinbase tx) $ do
        $(logDebugS) "BlockStore" $
            "Coinbase cannot be imported into mempool: " <>
            txHashToHex (txHash tx)
        throwError UnexpectedCoinbase

getUnspentOutputs
    :: ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => Bool -- ^ only delete from mempool
    -> [OutPoint]
    -> m ([Unspent], [TxHash]) -- ^ unspents and transactions deleted
getUnspentOutputs mem ops = do
    uns_ths <- forM ops go
    let uns = map fst uns_ths
        ths = concatMap snd uns_ths
    return (uns, ths)
  where
    go op = getUnspent op >>= \case
        Nothing -> force_unspent op
        Just u -> return (u, [])
    force_unspent op = do
        $(logDebugS) "BlockStore" $
            "Trying to force output unspent: " <> showOutput op
        s <- getSpender op >>= \case
            Nothing -> do
                $(logDebugS) "BlockStore" $
                    "Output not found: " <> showOutput op
                throwError Orphan
            Just Spender {spenderHash = s} -> return s
        $(logDebugS) "BlockStore" $
            "Deleting to free output: " <> txHashToHex s
        ths <- deleteTx True mem s
        getUnspent op >>= \case
            Nothing -> do
                $(logWarnS) "BlockStore" $
                    "Double spend attempted of output: " <> showOutput op
                throwError DoubleSpend
            Just u -> return (u, ths)

checkFunds
    :: ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => [Unspent]
    -> Tx
    -> m ()
checkFunds us tx
    | sum (map unspentAmount us) < sum (map outValue (txOut tx)) = do
        $(logDebugS) "BlockStore" $
            "Insufficient funds for tx: " <> txHashToHex (txHash tx)
        throwError InsufficientFunds
    | otherwise = return ()

commitTx
    :: ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       )
    => BlockRef
    -> Word64 -- ^ unix time
    -> [Unspent]
    -> Tx
    -> m ()
commitTx br tt us tx = do
    rbf <- isRBF br tx
    zipWithM_
        (spendOutput (txHash tx))
        [0 ..]
        us
    zipWithM_
        (newOutput br . OutPoint (txHash tx))
        [0 ..]
        (txOut tx)
    let ps =
            I.fromList . zip [0 ..] $
            if isCoinbase tx
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
    let as = txDataAddresses d
    mapM_ (`insertAddrTx` TxRef br (txHash tx)) as
    updateAddressCounts as (+ 1)
    unless (confirmed br) $
        insertIntoMempool (txHash tx) (memRefTime br)
  where
    mkprv u = Prev (B.Short.fromShort (unspentScript u)) (unspentAmount u)

importTx
    :: ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => BlockRef
    -> Word64 -- ^ unix time
    -> Tx
    -> m [TxHash] -- ^ deleted transactions
importTx br tt tx = do
    $(logDebugS) "BlockStore" $
        "Importing transaction " <> txHashToHex (txHash tx)
    unless (confirmed br) $ checkNewTx tx
    (us, ths) <-
        if isCoinbase tx
        then return ([], [])
        else getUnspentOutputs (not (confirmed br)) (map prevOutput (txIn tx))
    unless (confirmed br) $ checkFunds us tx
    commitTx br tt us tx
    return ths

unConfirmTx
    :: ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       )
    => TxData
    -> m ()
unConfirmTx t = confTx t Nothing

confirmTx
    :: ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       )
    => TxData
    -> BlockRef
    -> m ()
confirmTx t br = confTx t (Just br)

replaceAddressTx
    :: ( StoreRead m
       , StoreWrite m
       , MonadLogger m
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

adjustAddressOutputs
    :: ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       )
    => OutPoint
    -> TxOut
    -> BlockRef
    -> BlockRef
    -> m ()
adjustAddressOutputs op o old new = do
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
        if confirmed old
            then decreaseConfirmedBalance a (outValue o)
            else decreaseMempoolBalance a (outValue o)
        if confirmed new
            then increaseConfirmedBalance a (outValue o)
            else increaseMempoolBalance a (outValue o)

confTx
    :: ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       )
    => TxData
    -> Maybe BlockRef
    -> m ()
confTx t mbr = do
    let new = fromMaybe (MemRef (txDataTime t)) mbr
        old = txDataBlock t
    replaceAddressTx t new
    forM_ (zip [0 ..] (txOut (txData t))) $ \(n, o) -> do
        let op = OutPoint (txHash (txData t)) n
        adjustAddressOutputs op o old new
    insertTx t {txDataBlock = new}
    when (confirmed new) $
        deleteFromMempool (txHash (txData t))

deleteFromMempool
    :: (Monad m, StoreRead m, StoreWrite m) => TxHash -> m ()
deleteFromMempool th = do
    mp <- getMempool
    setMempool $ filter ((/= th) . txRefHash) mp

insertIntoMempool
    :: ( Monad m
       , StoreRead m
       , StoreWrite m
       )
    => TxHash
    -> UnixTime
    -> m ()
insertIntoMempool th unixtime = do
    mp <- getMempool
    setMempool . sortOn Down $ TxRef (MemRef unixtime) th : mp

deleteTx
    :: ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       , MonadError ImportException m
       )
    => Bool -- ^ only delete transaction if unconfirmed
    -> Bool -- ^ do RBF check before deleting transaction
    -> TxHash
    -> m [TxHash] -- ^ deleted transactions
deleteTx memonly rbfcheck txhash =
    getActiveTxData txhash >>= \case
        Nothing -> do
            $(logDebugS) "BlockStore" $
                "Already deleted or not found: " <>
                txHashToHex txhash
            return []
        Just t
            | memonly && confirmed (txDataBlock t) -> do
                $(logDebugS) "BlockStore" $
                    "Will not delete confirmed tx: " <>
                    txHashToHex txhash
                throwError TxConfirmed
            | rbfcheck ->
                isRBF (txDataBlock t) (txData t) >>= \case
                    True -> go t
                    False -> do
                        $(logDebugS) "BlockStore" $
                            "Cannot delete non-RBF transaction: " <>
                            txHashToHex txhash
                        throwError DoubleSpend
            | otherwise -> go t
  where
    go t = do
        $(logDebugS) "BlockStore" $
            "Deleting tx: " <> txHashToHex txhash
        ss <- nub' . map spenderHash . I.elems <$>
            getSpenders txhash
        ths <-
            fmap concat $
            forM ss $ \s -> do
                $(logDebugS) "BlockStore" $
                    "Deleting tx " <> txHashToHex s <>
                    " to delete parent " <>
                    txHashToHex (txHash (txData t))
                deleteTx True rbfcheck s
        commitDeleteTx t
        return (txhash : ths)


commitDeleteTx
    :: ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       )
    => TxData
    -> m ()
commitDeleteTx t = do
    let as = txDataAddresses t
    forM_ as (`deleteAddrTx` TxRef (txDataBlock t) (txHash (txData t)))
    delOutputs t
    let ps = filter (/= nullOutPoint) (map prevOutput (txIn (txData t)))
    mapM_ unspendOutput ps
    updateAddressCounts (txDataAddresses t) (subtract 1)
    deleteFromMempool (txHash (txData t))
    insertTx t {txDataDeleted = True}

isRBF ::
       (StoreRead m, MonadLogger m)
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
        | any ((< 0xffffffff - 1) . txInSequence) (txIn tx) = return True
        | otherwise =
          let hs = nub' $ map (outPointHash . prevOutput) (txIn tx)
              ck [] = return False
              ck (h:hs') =
                  getActiveTxData h >>= \case
                  Nothing -> do
                      $(logWarnS) "BlockStore" $
                          "Transaction not found: " <> txHashToHex h
                      return False
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
    let ma = eitherToMaybe (scriptToAddressBS (scriptOutput to))
        u = Unspent
            { unspentBlock = br
            , unspentAmount = outValue to
            , unspentScript = B.Short.toShort (scriptOutput to)
            , unspentPoint = op
            , unspentAddress = ma
            }
    insertUnspent u
    case ma of
        Nothing -> return ()
        Just a -> do
            insertAddrUnspent a u
            if confirmed br
                then increaseConfirmedBalance a (outValue to)
                else increaseMempoolBalance a (outValue to)
            modifyTotalReceived a (+ outValue to)

delOutputs ::
       ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       )
    => TxData
    -> m ()
delOutputs td =
    forM_ (zip [0..] (txOut (txData td))) $ \(i, o) -> do
        deleteUnspent
            OutPoint
            { outPointHash = txHash (txData td)
            , outPointIndex = i
            }
        case scriptToAddressBS (scriptOutput o) of
            Left _  -> return ()
            Right a -> go i o a
  where
    go i o a = do
        deleteAddrUnspent
            a
            Unspent
            { unspentScript = B.Short.toShort (scriptOutput o)
            , unspentBlock = txDataBlock td
            , unspentPoint = OutPoint (txHash (txData td)) i
            , unspentAmount = outValue o
            , unspentAddress = Just a
            }
        if confirmed (txDataBlock td)
            then decreaseConfirmedBalance a (outValue o)
            else decreaseMempoolBalance a (outValue o)
        modifyTotalReceived a (subtract (outValue o))

getImportTxData ::
       (StoreRead m, MonadLogger m, MonadError ImportException m)
    => TxHash
    -> m TxData
getImportTxData th =
    getActiveTxData th >>= \case
        Nothing -> do
            $(logDebugS) "BlockStore" $ "Tx not found: " <> txHashToHex th
            throwError TxNotFound
        Just d -> return d

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
       )
    => TxHash
    -> Word32
    -> Unspent
    -> m ()
spendOutput th ix u = do
    insertSpender (unspentPoint u) (Spender th ix)
    let pk = B.Short.fromShort (unspentScript u)
        ea = scriptToAddressBS pk
    case ea of
        Left _ -> return ()
        Right a -> do
            if confirmed (unspentBlock u)
                then decreaseConfirmedBalance a (unspentAmount u)
                else decreaseMempoolBalance a (unspentAmount u)
            deleteAddrUnspent a u
    deleteUnspent (unspentPoint u)

unspendOutput ::
       ( StoreRead m
       , StoreWrite m
       , MonadLogger m
       )
    => OutPoint
    -> m ()
unspendOutput op = void . runMaybeT $ do
    t <- MaybeT $ getActiveTxData (outPointHash op)
    o <- MaybeT $ return $ getTxOut (outPointIndex op) (txData t)
    s <- MaybeT $ getSpender op
    x <- MaybeT $ getActiveTxData (spenderHash s)
    lift $ do
        deleteSpender op
        let m = eitherToMaybe (scriptToAddressBS (scriptOutput o))
            u =
                Unspent
                    { unspentAmount = outValue o
                    , unspentBlock = txDataBlock t
                    , unspentScript = B.Short.toShort (scriptOutput o)
                    , unspentPoint = op
                    , unspentAddress = m
                    }
        insertUnspent u
        forM_ m $ \a -> do
            insertAddrUnspent a u
            deleteAddrTx a (TxRef (txDataBlock x) (spenderHash s))
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
       (StoreWrite m, StoreRead m, Monad m)
    => [Address]
    -> (Word64 -> Word64)
    -> m ()
updateAddressCounts as f =
    forM_ as $ \a -> do
        b <- getBalance a
        setBalance b {balanceTxCount = f (balanceTxCount b)}

txDataAddresses :: TxData -> [Address]
txDataAddresses t =
    nub' . rights $
    map (scriptToAddressBS . prevScript) (I.elems (txDataPrevs t)) <>
    map (scriptToAddressBS . scriptOutput) (txOut (txData t))

isCoinbase :: Tx -> Bool
isCoinbase = all ((== nullOutPoint) . prevOutput) . txIn

showOutput :: OutPoint -> Text
showOutput OutPoint {outPointHash = h, outPointIndex = i} =
    txHashToHex h <> "/" <> cs (show i)
