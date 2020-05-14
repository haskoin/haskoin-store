{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}
module Haskoin.Store.Logic
    ( ImportException (..)
    , initBest
    , getOldMempool
    , revertBlock
    , importBlock
    , newMempoolTx
    , delTx
    ) where

import           Control.Monad           (forM, forM_, guard, unless, void,
                                          when, zipWithM_)
import           Control.Monad.Logger    (MonadLoggerIO, logDebugS, logErrorS,
                                          logWarnS)
import qualified Data.ByteString         as B
import qualified Data.ByteString.Short   as B.Short
import           Data.Either             (rights)
import           Data.HashMap.Strict     (HashMap)
import qualified Data.HashMap.Strict     as HashMap
import qualified Data.HashSet            as HashSet
import qualified Data.IntMap.Strict      as I
import           Data.List               (nub, sort)
import           Data.Maybe              (catMaybes, fromMaybe, isNothing)
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
                                          computeSubsidy, eitherToMaybe,
                                          genesisBlock, genesisNode, headerHash,
                                          isGenesis, nullOutPoint,
                                          scriptToAddressBS, txHash,
                                          txHashToHex)
import           Haskoin.Store.Common    (StoreRead (..), StoreWrite (..), nub',
                                          sortTxs)
import           Haskoin.Store.Data      (Balance (..), BlockData (..),
                                          BlockRef (..), Prev (..),
                                          Spender (..), TxData (..), TxRef (..),
                                          UnixTime, Unspent (..), confirmed,
                                          nullBalance)
import           UnliftIO                (Async, Exception, MonadUnliftIO, TVar,
                                          async, atomically, modifyTVar,
                                          newTVarIO, readTVarIO, throwIO, wait)

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

data BlockAccel =
    BlockAccel
        { utxas :: !(TVar (HashMap OutPoint (Async (Maybe Unspent))))
        , balas :: !(TVar (HashMap Address (Async Balance)))
        }

accelTxs :: (MonadUnliftIO m, StoreRead m) => [Tx] -> m BlockAccel
accelTxs txs = do
    utxas' <-
        fmap HashMap.fromList $
        forM inops $ \op -> do
            a <- async (getUnspent op)
            return (op, a)
    let f tx = map g (txOut tx)
        g to =
            case scriptToAddressBS (scriptOutput to) of
                Left _ -> Nothing
                Right a -> Just a
        oaddrs = catMaybes (concatMap f txs)
    balas' <-
        fmap HashMap.fromList $
        forM oaddrs $ \a -> do
            a' <- async (getBalance a)
            return (a, a')
    utxas <- newTVarIO utxas'
    balas <- newTVarIO balas'
    return BlockAccel {..}
  where
    newops = HashSet.fromList (map txHash txs)
    inops =
        filter
            (not . (`HashSet.member` newops) . outPointHash)
            (concatMap
                 (filter (not . (== nullOutPoint)) . map prevOutput . txIn)
                 txs)

getAccelBalance ::
       (MonadUnliftIO m, StoreRead m) => BlockAccel -> Address -> m Balance
getAccelBalance BlockAccel {..} a = do
    balas' <- readTVarIO balas
    case HashMap.lookup a balas' of
        Nothing -> getBalance a
        Just a' -> wait a'

delAccelBalance :: (MonadUnliftIO m) => BlockAccel -> Address -> m ()
delAccelBalance BlockAccel {..} a =
    atomically $ modifyTVar balas (HashMap.delete a)

getAccelUnspent ::
       (MonadUnliftIO m, StoreRead m)
    => BlockAccel
    -> OutPoint
    -> m (Maybe Unspent)
getAccelUnspent BlockAccel {..} op = do
    utxas' <- readTVarIO utxas
    case HashMap.lookup op utxas' of
        Nothing -> getUnspent op
        Just a -> wait a

delAccelUnspent :: (MonadUnliftIO m) => BlockAccel -> OutPoint -> m ()
delAccelUnspent BlockAccel {..} op =
    atomically $ modifyTVar utxas (HashMap.delete op)

initBest ::
       ( StoreRead m
       , StoreWrite m
       , MonadLoggerIO m
       , MonadUnliftIO m
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
       ( StoreRead m
       , StoreWrite m
       , MonadLoggerIO m
       , MonadUnliftIO m
       )
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
        _ -> do
            accel <- accelTxs [tx]
            Just <$> importTx accel (MemRef w) w tx

revertBlock ::
       ( StoreRead m
       , StoreWrite m
       , MonadLoggerIO m
       , MonadUnliftIO m
       )
    => BlockHash
    -> m [TxHash]
revertBlock bh = do
    bd <-
        getBestBlock >>= \case
            Nothing -> do
                $(logErrorS) "BlockStore" "Best block unknown"
                throwIO BestBlockUnknown
            Just h ->
                getBlock h >>= \case
                    Nothing -> do
                        $(logErrorS) "BlockStore" "Best block not found"
                        throwIO (BestBlockNotFound (blockHashToHex h))
                    Just b
                        | h == bh -> return b
                        | otherwise -> do
                            $(logErrorS) "BlockStore" $
                                "Cannot delete block that is not head: " <>
                                blockHashToHex h
                            throwIO (BlockNotBest (blockHashToHex bh))
    txs <- mapM (fmap txData . getImportTxData) (blockDataTxs bd)
    accel <- accelTxs txs
    ths <-
        nub' . concat <$>
        mapM (deleteTx accel False False . txHash . snd) (reverse (sortTxs txs))
    setBest (prevBlock (blockDataHeader bd))
    insertBlock bd {blockDataMainChain = False}
    return ths

importBlock ::
       ( StoreRead m
       , StoreWrite m
       , MonadLoggerIO m
       , MonadUnliftIO m
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
                throwIO BestBlockUnknown
        Just h
            | prevBlock (blockHeader b) == h -> return ()
            | otherwise -> do
                $(logErrorS) "BlockStore" $
                    "Block does not build on head: " <>
                    blockHashToHex (headerHash (blockHeader b))
                throwIO $
                    PrevBlockNotBest (blockHashToHex (prevBlock (nodeHeader n)))
    net <- getNetwork
    accel <- accelTxs (blockTxns b)
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
        mapM (uncurry (import_or_confirm accel mp)) (sortTxs (blockTxns b))
    return ths
  where
    bths = map txHash (blockTxns b)
    import_or_confirm accel mp x tx =
        if txHash tx `elem` mp
            then getTxData (txHash tx) >>= \case
                     Just td -> confirmTx accel td (br x) tx >> return []
                     Nothing -> do
                         $(logErrorS) "BlockStore" $
                             "Cannot get data for mempool tx: " <>
                             txHashToHex (txHash tx)
                         throwIO $ TxNotFound (txHashToHex (txHash tx))
            else importTx
                     accel
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
       , MonadLoggerIO m
       , MonadUnliftIO m
       )
    => BlockAccel
    -> BlockRef
    -> Word64 -- ^ unix time
    -> Tx
    -> m [TxHash] -- ^ deleted transactions
importTx accel br tt tx = do
    unless (confirmed br) $ do
        $(logDebugS) "BlockStore" $
            "Importing transaction " <> txHashToHex (txHash tx)
        when (length (nub' (map prevOutput (txIn tx))) < length (txIn tx)) $ do
            $(logErrorS) "BlockStore" $
                "Transaction spends same output twice: " <>
                txHashToHex (txHash tx)
            throwIO (DuplicatePrevOutput (txHashToHex (txHash tx)))
        when iscb $ do
            $(logErrorS) "BlockStore" $
                "Coinbase cannot be imported into mempool: " <>
                txHashToHex (txHash tx)
            throwIO (UnconfirmedCoinbase (txHashToHex (txHash tx)))
    us' <-
        if iscb
            then return []
            else forM (txIn tx) $ \TxIn {prevOutput = op} -> uns op
    let us = map fst us'
        ths = nub' (concatMap snd us')
    when
        (not (confirmed br) &&
         sum (map unspentAmount us) < sum (map outValue (txOut tx))) $ do
        $(logErrorS) "BlockStore" $
            "Insufficient funds for tx: " <> txHashToHex (txHash tx)
        throwIO (InsufficientFunds (txHashToHex th))
    rbf <- isRBF br tx
    commit rbf us
    return ths
  where
    commit rbf us = do
        zipWithM_ (spendOutput accel br (txHash tx)) [0 ..] us
        zipWithM_
            (\i o -> newOutput accel br (OutPoint (txHash tx) i) o)
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
        updateAddressCounts accel (txDataAddresses d) (+ 1)
        unless (confirmed br) $ insertIntoMempool (txHash tx) (memRefTime br)
    uns op =
        getAccelUnspent accel op >>= \case
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
                        throwIO (TxOrphan (txHashToHex (txHash tx)))
                    Just Spender {spenderHash = s} -> do
                        $(logWarnS) "BlockStore" $
                            "Deleting transaction " <> txHashToHex s <>
                            " because it conflicts with " <>
                            txHashToHex (txHash tx)
                        ths <- deleteTx accel True (not (confirmed br)) s
                        getUnspent op >>= \case
                            Nothing -> do
                                $(logErrorS) "BlockStore" $
                                    "Cannot unspend output: " <>
                                    txHashToHex (outPointHash op) <>
                                    " " <>
                                    fromString (show (outPointIndex op))
                                throwIO (OutputSpent (cs (show op)))
                            Just u -> return (u, ths)
    th = txHash tx
    iscb = all (== nullOutPoint) (map prevOutput (txIn tx))
    mkprv u = Prev (B.Short.fromShort (unspentScript u)) (unspentAmount u)

confirmTx ::
       ( StoreRead m
       , StoreWrite m
       , MonadLoggerIO m
       , MonadUnliftIO m
       )
    => BlockAccel
    -> TxData
    -> BlockRef
    -> Tx
    -> m ()
confirmTx accel t br tx = do
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
            delAccelUnspent accel op
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
                    reduceBalance accel False False a (outValue o)
                    increaseBalance accel True False a (outValue o)
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

delTx ::
       ( StoreRead m
       , StoreWrite m
       , MonadLoggerIO m
       , MonadUnliftIO m
       )
    => TxHash
    -> m [TxHash] -- ^ deleted transactions
delTx th =
    getTxData th >>= \case
        Nothing -> do
            $(logErrorS) "BlockStore" $
                "Cannot find tx to delete: " <> txHashToHex th
            throwIO (TxNotFound (txHashToHex th))
        Just t
            | txDataDeleted t -> do
                $(logWarnS) "BlockStore" $
                    "Already deleted tx: " <> txHashToHex th
                return []
            | otherwise -> do
                accel <- accelTxs [txData t]
                deleteTx accel True False th

deleteTx ::
       ( StoreRead m
       , StoreWrite m
       , MonadLoggerIO m
       , MonadUnliftIO m
       )
    => BlockAccel
    -> Bool -- ^ only delete transaction if unconfirmed
    -> Bool -- ^ do RBF check before deleting transaction
    -> TxHash
    -> m [TxHash] -- ^ deleted transactions
deleteTx accel memonly rbfcheck txhash = do
    getTxData txhash >>= \case
        Nothing -> do
            $(logErrorS) "BlockStore" $
                "Cannot find tx to delete: " <> txHashToHex txhash
            throwIO (TxNotFound (txHashToHex txhash))
        Just t
            | txDataDeleted t -> do
                $(logWarnS) "BlockStore" $
                    "Already deleted tx: " <> txHashToHex txhash
                return []
            | memonly && confirmed (txDataBlock t) -> do
                $(logErrorS) "BlockStore" $
                    "Will not delete confirmed tx: " <> txHashToHex txhash
                throwIO (TxConfirmed (txHashToHex txhash))
            | rbfcheck ->
                isRBF (txDataBlock t) (txData t) >>= \case
                    True -> go t
                    False -> do
                        $(logErrorS) "BlockStore" $
                            "Delete non-RBF transaction attempted: " <>
                            txHashToHex txhash
                        throwIO $ CannotDeleteNonRBF (txHashToHex txhash)
            | otherwise -> go t
  where
    go t = do
        $(logWarnS) "BlockStore" $
            "Deleting transaction: " <> txHashToHex txhash
        ss <- nub' . map spenderHash . I.elems <$> getSpenders txhash
        ths <-
            fmap concat $
            forM ss $ \s -> do
                $(logWarnS) "BlockStore" $
                    "Deleting descendant " <> txHashToHex s <>
                    " to delete parent " <>
                    txHashToHex txhash
                deleteTx accel True rbfcheck s
        forM_ (take (length (txOut (txData t))) [0 ..]) $ \n ->
            delOutput accel (OutPoint txhash n)
        let ps = filter (/= nullOutPoint) (map prevOutput (txIn (txData t)))
        mapM_ (unspendOutput accel) ps
        unless (confirmed (txDataBlock t)) $ deleteFromMempool txhash
        insertTx t {txDataDeleted = True}
        updateAddressCounts accel (txDataAddresses t) (subtract 1)
        return $ nub' (txhash : ths)


isRBF ::
       (StoreRead m, MonadLoggerIO m)
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
                            $(logErrorS) "BlockStore" $
                                "Transaction not found: " <> txHashToHex h
                            throwIO (TxNotFound (txHashToHex h))
                        Just t
                            | confirmed (txDataBlock t) -> ck hs'
                            | txDataRBF t -> return True
                            | otherwise -> ck hs'
             in ck hs

newOutput ::
       ( StoreRead m
       , StoreWrite m
       , MonadLoggerIO m
       , MonadUnliftIO m
       )
    => BlockAccel
    -> BlockRef
    -> OutPoint
    -> TxOut
    -> m ()
newOutput accel br op to = do
    delAccelUnspent accel op
    insertUnspent u
    case scriptToAddressBS (scriptOutput to) of
        Left _ -> return ()
        Right a -> do
            insertAddrUnspent a u
            insertAddrTx
                a
                TxRef {txRefHash = outPointHash op, txRefBlock = br}
            increaseBalance accel (confirmed br) True a (outValue to)
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
       , MonadLoggerIO m
       , MonadUnliftIO m
       )
    => BlockAccel
    -> OutPoint
    -> m ()
delOutput accel op = do
    t <- getImportTxData (outPointHash op)
    u <-
        case getTxOut (outPointIndex op) (txData t) of
            Just u -> return u
            Nothing -> do
                $(logErrorS) "BlockStore" $
                    "Output out of range: " <> txHashToHex (txHash (txData t)) <>
                    " " <>
                    fromString (show (outPointIndex op))
                throwIO . OutputOutOfRange . cs $ show op
    delAccelUnspent accel op
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
                TxRef
                    { txRefHash = outPointHash op
                    , txRefBlock = txDataBlock t
                    }
            reduceBalance accel (confirmed (txDataBlock t)) True a (outValue u)

getImportTxData ::
       (StoreRead m, MonadLoggerIO m)
    => TxHash
    -> m TxData
getImportTxData th =
    getTxData th >>= \case
        Nothing -> do
            $(logErrorS) "BlockStore" $ "Tx not found: " <> txHashToHex th
            throwIO $ TxNotFound (txHashToHex th)
        Just d
            | txDataDeleted d -> do
                $(logErrorS) "BlockStore" $ "Tx deleted: " <> txHashToHex th
                throwIO $ TxDeleted (txHashToHex th)
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
       , MonadLoggerIO m
       , MonadUnliftIO m
       )
    => BlockAccel
    -> BlockRef
    -> TxHash
    -> Word32
    -> Unspent
    -> m ()
spendOutput accel br th ix u = do
    insertSpender (unspentPoint u) Spender {spenderHash = th, spenderIndex = ix}
    case scriptToAddressBS (B.Short.fromShort (unspentScript u)) of
        Left _ -> return ()
        Right a -> do
            reduceBalance
                accel
                (confirmed (unspentBlock u))
                False
                a
                (unspentAmount u)
            deleteAddrUnspent a u
            insertAddrTx a TxRef {txRefHash = th, txRefBlock = br}
    delAccelUnspent accel (unspentPoint u)
    deleteUnspent (unspentPoint u)

unspendOutput ::
       ( StoreRead m
       , StoreWrite m
       , MonadLoggerIO m
       , MonadUnliftIO m
       )
    => BlockAccel
    -> OutPoint
    -> m ()
unspendOutput accel op = do
    t <- getImportTxData (outPointHash op)
    o <-
        case getTxOut (outPointIndex op) (txData t) of
            Nothing -> do
                $(logErrorS) "BlockStore" $
                    "Output out of range: " <> cs (show op)
                throwIO (OutputOutOfRange (cs (show op)))
            Just o -> return o
    s <-
        getSpender op >>= \case
            Nothing -> do
                $(logErrorS) "BlockStore" $
                    "Output already unspent: " <> txHashToHex (outPointHash op) <>
                    " " <>
                    fromString (show (outPointIndex op))
                throwIO (AlreadyUnspent (cs (show op)))
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
    delAccelUnspent accel op
    insertUnspent u
    case m of
        Nothing -> return ()
        Just a -> do
            insertAddrUnspent a u
            deleteAddrTx
                a
                TxRef
                    {txRefHash = spenderHash s, txRefBlock = txDataBlock x}
            increaseBalance
                accel
                (confirmed (unspentBlock u))
                False
                a
                (outValue o)

reduceBalance ::
       ( StoreRead m
       , StoreWrite m
       , MonadLoggerIO m
       , MonadUnliftIO m
       )
    => BlockAccel
    -> Bool -- ^ spend or delete confirmed output
    -> Bool -- ^ reduce total received
    -> Address
    -> Word64
    -> m ()
reduceBalance accel c t a v = do
    net <- getNetwork
    b <- getAccelBalance accel a
    if nullBalance b
        then do
            $(logErrorS) "BlockStore" $
                "Address balance not found: " <> addrText net a
            throwIO (BalanceNotFound (addrText net a))
        else do
            when (v > amnt b) $ do
                $(logErrorS) "BlockStore" $
                    "Insufficient " <> conf <> " balance: " <> addrText net a <>
                    " (needs: " <>
                    cs (show v) <>
                    ", has: " <>
                    cs (show (amnt b)) <>
                    ")"
                throwIO $
                    if c
                        then InsufficientBalance (addrText net a)
                        else InsufficientZeroBalance (addrText net a)
            delAccelBalance accel a
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
       , MonadLoggerIO m
       , MonadUnliftIO m
       )
    => BlockAccel
    -> Bool -- ^ add confirmed output
    -> Bool -- ^ increase total received
    -> Address
    -> Word64
    -> m ()
increaseBalance accel c t a v = do
    b <- getAccelBalance accel a
    delAccelBalance accel a
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
       ( StoreWrite m
       , StoreRead m
       , MonadUnliftIO m
       )
    => BlockAccel
    -> [Address]
    -> (Word64 -> Word64)
    -> m ()
updateAddressCounts accel as f =
    forM_ as $ \a -> do
        b <-
            do net <- getNetwork
               b <- getAccelBalance accel a
               if nullBalance b
                   then throwIO (BalanceNotFound (addrText net a))
                   else return b
        delAccelBalance accel a
        setBalance b {balanceTxCount = f (balanceTxCount b)}

txDataAddresses :: TxData -> [Address]
txDataAddresses t =
    nub' . rights $
    map (scriptToAddressBS . prevScript) (I.elems (txDataPrevs t)) <>
    map (scriptToAddressBS . scriptOutput) (txOut (txData t))

addrText :: Network -> Address -> Text
addrText net a = fromMaybe "???" $ addrToString net a
