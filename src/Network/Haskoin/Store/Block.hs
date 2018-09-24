{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TupleSections              #-}
module Network.Haskoin.Store.Block
      ( blockStore
      , getBestBlock
      , getBestBlockHash
      , getBlocksAtHeight
      , getBlock
      , getBlocks
      , getAddrTxs
      , getUnspent
      , getBalance
      , getTx
      , getMempool
      ) where

import           Conduit
import           Control.Applicative
import           Control.Monad.Except
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.State.Strict  as State
import           Control.Monad.Trans.Maybe
import qualified Data.ByteString             as B
import qualified Data.ByteString.Short       as B.Short
import           Data.Default
import           Data.Function
import           Data.HashMap.Strict         (HashMap)
import qualified Data.HashMap.Strict         as H
import           Data.List
import           Data.Maybe
import           Data.Serialize              (Serialize, encode)
import           Data.String
import           Data.String.Conversions
import           Data.Text                   (Text)
import           Data.Time.Clock.POSIX
import           Data.Word
import           Database.RocksDB            as R
import           Database.RocksDB.Query      as R
import           Haskoin
import           Haskoin.Node
import           Network.Haskoin.Store.Types
import           NQE
import           UnliftIO

-- | Block store process state.
data BlockRead = BlockRead
    { myBlockDB    :: !DB
    , myUnspentDB  :: !(Maybe DB)
    , mySelf       :: !BlockStore
    , myChain      :: !Chain
    , myManager    :: !Manager
    , myListener   :: !(Listen StoreEvent)
    , myBaseHeight :: !(TVar BlockHeight)
    , myPeer       :: !(TVar (Maybe Peer))
    , myNetwork    :: !Network
    }

-- | Block store context.
type MonadBlock m
     = (MonadLoggerIO m, MonadReader BlockRead m)

-- | Status of a transaction being verified for importing.
data TxStatus
    = TxValid
    | TxOrphan
    | TxLowFunds
    | TxInputSpent
    deriving (Eq, Show, Ord)

-- | State for importing or removing blocks and transactions.
data ImportState = ImportState
    { importBestBlock  :: !(HashMap BestBlockKey BlockHash)
    , importBlockValue :: !(HashMap BlockKey BlockValue)
    , importTxRecord   :: !(HashMap TxKey TxRecord)
    , importAddrOutput :: !(HashMap AddrOutKey (Maybe Output))
    , importHeight     :: !(HashMap HeightKey [BlockHash])
    , importBalance    :: !(HashMap BalanceKey (Maybe Balance))
    , importAddrTx     :: !(HashMap AddrTxKey (Maybe ()))
    , importOutput     :: !(HashMap OutputKey Output)
    , importUnspent    :: !(HashMap UnspentKey (Maybe Output))
    , importOrphan     :: !(HashMap OrphanKey (Maybe Tx))
    , importMempool    :: !(HashMap MempoolKey (Maybe ()))
    , importEvents     :: ![StoreEvent]
    }

-- | Context for importing or removing blocks and transactions.
type MonadImport m = MonadState ImportState m

-- | Run block store process.
blockStore :: (MonadUnliftIO m, MonadLoggerIO m) => BlockConfig -> m ()
blockStore BlockConfig {..} = do
    base_height_box <- newTVarIO 0
    peer_box <- newTVarIO Nothing
    runReaderT
        (init_db >> loadUTXO >> syncBlocks >> run)
        BlockRead
            { mySelf = blockConfMailbox
            , myBlockDB = blockConfDB
            , myChain = blockConfChain
            , myManager = blockConfManager
            , myListener = blockConfListener
            , myBaseHeight = base_height_box
            , myPeer = peer_box
            , myNetwork = blockConfNet
            , myUnspentDB = blockConfUnspentDB
            }
  where
    run =
        forever $ do
            msg <- receive blockConfMailbox
            processBlockMessage msg
    init_db =
        runResourceT $ do
            runConduit $
                matching blockConfDB def ShortOrphanKey .|
                mapM_C (\(k, Tx {}) -> remove blockConfDB k)
            retrieve blockConfDB def BestBlockKey >>= \case
                Nothing -> addNewBlock (genesisBlock blockConfNet)
                Just (_ :: BlockHash) -> return ()
            BlockValue {..} <-
                getBestBlock blockConfDB def
            base_height_box <- asks myBaseHeight
            atomically $ writeTVar base_height_box blockValueHeight

-- | Run within 'MonadImport' context. Execute updates to database and
-- notification to subscribers when finished.
runMonadImport ::
       MonadBlock m => StateT ImportState m a -> m a
runMonadImport f =
    evalStateT
        (f >>= \a -> update_memory >> update_database >> return a)
        ImportState
            { importBestBlock = H.empty
            , importBlockValue = H.empty
            , importTxRecord = H.empty
            , importAddrOutput = H.empty
            , importHeight = H.empty
            , importBalance = H.empty
            , importAddrTx = H.empty
            , importOutput = H.empty
            , importUnspent = H.empty
            , importOrphan = H.empty
            , importMempool = H.empty
            , importEvents = []
            }
  where
    update_memory =
        void . runMaybeT $ do
            mudb <- asks myUnspentDB
            udb <-
                case mudb of
                    Nothing -> fail "No in-memory database"
                    Just x -> return x
            ImportState {..} <- State.get
            writeBatch udb $
                hashMapMaybeOps importUnspent <> hashMapMaybeOps importBalance
    update_database = do
        db <- asks myBlockDB
        ImportState {..} <- State.get
        writeBatch db $
            hashMapOps importBestBlock <> hashMapOps importBlockValue <>
            hashMapOps importTxRecord <>
            hashMapMaybeOps importAddrOutput <>
            hashMapOps importHeight <>
            hashMapMaybeOps importBalance <>
            hashMapMaybeOps importAddrTx <>
            hashMapOps importOutput <>
            hashMapMaybeOps importUnspent <>
            hashMapMaybeOps importOrphan <>
            hashMapMaybeOps importMempool
        l <- asks myListener
        atomically $ mapM_ l importEvents

hashMapOps ::
       (Serialize k, Serialize v, KeyValue k v) => HashMap k v -> [BatchOp]
hashMapOps = H.foldlWithKey' f []
  where
    f xs k v = insertOp k v : xs

hashMapMaybeOps ::
       (Key k, Serialize k, Serialize v, KeyValue k v)
    => HashMap k (Maybe v)
    -> [BatchOp]
hashMapMaybeOps = H.foldlWithKey' f []
  where
    f xs k (Just v) = insertOp k v : xs
    f xs k Nothing  = deleteOp k : xs

-- | Get transaction output for importing transaction.
importGetOutput :: (MonadBlock m, MonadImport m) => OutPoint -> m (Maybe Output)
importGetOutput out_point = runMaybeT $ do
    o <- map_lookup <|> mem_lookup <|> db_lookup
    guard (not (outDeleted o))
    return o
  where
    map_lookup = MaybeT $ H.lookup (OutputKey out_point) <$> gets importOutput
    mem_lookup = do
        udb <- MaybeT (asks myUnspentDB)
        MaybeT $ retrieve udb def (OutputKey out_point)
    db_lookup = do
        db <- asks myBlockDB
        MaybeT $ retrieve db def (OutputKey out_point)

-- | Get address balance for importing transaction.
importGetBalance :: (MonadBlock m, MonadImport m) => Address -> m Balance
importGetBalance a =
    fmap (fromMaybe emptyBalance) . runMaybeT $
    map_lookup >>= \case
        Just Nothing -> MaybeT $ return Nothing
        Just (Just b) -> return b
        Nothing -> mem_lookup <|> db_lookup
  where
    map_lookup = H.lookup (BalanceKey a) <$> gets importBalance
    mem_lookup = do
        udb <- MaybeT (asks myUnspentDB)
        MaybeT $ retrieve udb def (BalanceKey a)
    db_lookup = do
        guard . isNothing =<< asks myUnspentDB
        db <- asks myBlockDB
        MaybeT $ retrieve db def (BalanceKey a)

-- | Get transaction for importing.
importGetTxRecord ::
       (MonadBlock m, MonadImport m) => TxHash -> m (Maybe TxRecord)
importGetTxRecord tx_hash = runMaybeT $ do
    tr <- map_lookup <|> db_lookup
    guard (not (txValueDeleted tr))
    return tr
  where
    map_lookup = MaybeT $ H.lookup (TxKey tx_hash) <$> gets importTxRecord
    db_lookup = do
        db <- asks myBlockDB
        MaybeT $ retrieve db def (TxKey tx_hash)

-- | Get best block for importing.
importGetBest :: (MonadBlock m, MonadImport m) => m BlockHash
importGetBest = runMaybeT (map_lookup <|> db_lookup) >>= \case
    Nothing -> throwString "Could not get best block hash for importing"
    Just x -> return x
  where
    map_lookup = MaybeT $ H.lookup BestBlockKey <$> gets importBestBlock
    db_lookup = do
        db <- asks myBlockDB
        MaybeT $ retrieve db def BestBlockKey

-- | Get block for importing.
importGetBlock :: (MonadBlock m, MonadImport m) => BlockHash -> m (Maybe BlockValue)
importGetBlock bh = runMaybeT $ do
    bv <- map_lookup <|> db_lookup
    guard (blockValueMainChain bv)
    return bv
  where
    map_lookup = MaybeT $ H.lookup (BlockKey bh) <$> gets importBlockValue
    db_lookup = do
        db <- asks myBlockDB
        MaybeT $ retrieve db def (BlockKey bh)

importGetHeight :: (MonadBlock m, MonadImport m) => BlockHeight -> m [BlockHash]
importGetHeight bh = fmap (fromMaybe []) . runMaybeT $ map_lookup <|> db_lookup
  where
    map_lookup = MaybeT $ H.lookup (HeightKey bh) <$> gets importHeight
    db_lookup = do
        db <- asks myBlockDB
        MaybeT $ retrieve db def (HeightKey bh)

-- | Entry point to dispatch importing any transaction.
importInsertTx ::
       (MonadBlock m, MonadImport m) => Maybe BlockRef -> Tx -> m ()
importInsertTx mb tx = do
    prev_outs <- catMaybes <$> mapM (importGetOutput . prevOutput) (txIn tx)
    when (not is_coinbase && length prev_outs /= length (txIn tx)) . throwString $
        "Could not get all previous outputs for tx " <> cs (txHashToHex tx_hash)
    go prev_outs
    modify $ \s ->
        s {importOrphan = H.insert (OrphanKey tx_hash) Nothing (importOrphan s)}
  where
    is_coinbase = all ((== nullOutPoint) . prevOutput) (txIn tx)
    tx_hash = txHash tx
    all_unspent outs = is_coinbase || all (isNothing . outSpender) outs
    spent_by_me = all ((== Just tx_hash) . fmap spenderHash . outSpender)
    spenders = nub . map spenderHash . mapMaybe outSpender
    go prev_outs
        | all_unspent prev_outs = importNewTx mb prev_outs tx
        | spent_by_me prev_outs = importUpdateTx mb (txHash tx)
        | otherwise = do
            mapM_ importDeleteTx (spenders prev_outs)
            importNewTx mb prev_outs tx

-- | Only for importing a new transaction. Also works for a deleted transaction.
importNewTx ::
       (MonadBlock m, MonadImport m)
    => Maybe BlockRef
    -> [Output]
    -> Tx
    -> m ()
importNewTx mb prev_outs tx = do
    mapM_ spend_output (zip3 [0 ..] prev_outpoints prev_outs)
    mapM_ insert_output (zip [0 ..] (txOut tx))
    when (isNothing mb) $
        modify $ \s ->
            s
                { importMempool =
                      H.insert (MempoolKey tx_hash) (Just ()) (importMempool s)
                }
    modify $ \s ->
        let txr =
                TxRecord
                    { txValueBlock = mb
                    , txValue = tx
                    , txValuePrevOuts =
                          map
                              (\o ->
                                   ( outputValue o
                                   , B.Short.fromShort (outScript o)))
                              prev_outs
                    , txValueDeleted = False
                    }
         in s {importTxRecord = H.insert (TxKey tx_hash) txr (importTxRecord s)}
  where
    prev_outpoints = map prevOutput (txIn tx)
    tx_hash = txHash tx
    spend_output (i, op, out) = do
        importSpendOutput mb op out tx_hash i
        importSpendAddress mb op out tx_hash
    insert_output (i, tx_out) = do
        let op = OutPoint tx_hash i
            out =
                Output
                    { outputValue = outValue tx_out
                    , outBlock = mb
                    , outScript = B.Short.toShort (scriptOutput tx_out)
                    , outSpender = Nothing
                    , outDeleted = False
                    }
        importUnspentOutput op out
        importUnspentAddress mb op out

-- | Undo insertion of unspent output.
importUndoUnspentAddress ::
       (MonadBlock m, MonadImport m)
    => Maybe BlockRef
    -> OutPoint
    -> Output
    -> m ()
importUndoUnspentAddress mb op out = do
    net <- asks myNetwork
    case scriptToAddressBS net (B.Short.fromShort (outScript out)) of
        Nothing -> return ()
        Just a -> do
            balance <- importGetBalance a
            let addr_out_key =
                    AddrOutKey
                        { addrOutputAddress = a
                        , addrOutputHeight = blockRefHeight <$> mb
                        , addrOutputPos = blockRefPos <$> mb
                        , addrOutPoint = op
                        }
                addr_tx_key =
                    AddrTxKey
                        { addrTxKey = a
                        , addrTxHeight = blockRefHeight <$> mb
                        , addrTxPos = blockRefPos <$> mb
                        , addrTxHash = outPointHash op
                        }
                balance_value
                    | isJust mb =
                        balance
                            { balanceValue =
                                  balanceValue balance - outputValue out
                            , balanceUtxoCount = balanceUtxoCount balance - 1
                            }
                    | otherwise =
                        balance
                            { balanceUnconfirmed =
                                  balanceUnconfirmed balance -
                                  fromIntegral (outputValue out)
                            , balanceUtxoCount = balanceUtxoCount balance - 1
                            }
                maybe_balance
                    | balanceUtxoCount balance == 0 = Nothing
                    | otherwise = Just balance_value
            modify $ \s ->
                s
                    { importAddrOutput =
                          H.insert addr_out_key Nothing (importAddrOutput s)
                    , importAddrTx =
                          H.insert addr_tx_key Nothing (importAddrTx s)
                    , importBalance =
                          H.insert
                              (BalanceKey a)
                              maybe_balance
                              (importBalance s)
                    }


-- | Insert unspent output if it has address:
--
--     * Insert address output
--     * Insert address transaction
--     * If transaction confirmed increase confirmed balance
--     * Else increase unconfirmed balance
--
importUnspentAddress ::
       (MonadBlock m, MonadImport m)
    => Maybe BlockRef
    -> OutPoint
    -> Output
    -> m ()
importUnspentAddress mb op out = do
    net <- asks myNetwork
    case scriptToAddressBS net (B.Short.fromShort (outScript out)) of
        Nothing -> return ()
        Just a -> do
            balance <- importGetBalance a
            let addr_out_key =
                    AddrOutKey
                        { addrOutputAddress = a
                        , addrOutputHeight = blockRefHeight <$> mb
                        , addrOutputPos = blockRefPos <$> mb
                        , addrOutPoint = op
                        }
                addr_tx_key =
                    AddrTxKey
                        { addrTxKey = a
                        , addrTxHeight = blockRefHeight <$> mb
                        , addrTxPos = blockRefPos <$> mb
                        , addrTxHash = outPointHash op
                        }
                balance_value
                    | isJust mb =
                        balance
                            { balanceValue =
                                  balanceValue balance + outputValue out
                            , balanceUtxoCount = balanceUtxoCount balance + 1
                            }
                    | otherwise =
                        balance
                            { balanceUnconfirmed =
                                  balanceUnconfirmed balance +
                                  fromIntegral (outputValue out)
                            , balanceUtxoCount = balanceUtxoCount balance + 1
                            }
            modify $ \s ->
                s
                    { importAddrOutput =
                          H.insert addr_out_key (Just out) (importAddrOutput s)
                    , importAddrTx =
                          H.insert addr_tx_key (Just ()) (importAddrTx s)
                    , importBalance =
                          H.insert
                              (BalanceKey a)
                              (Just balance_value)
                              (importBalance s)
                    }

-- | Import unspent output:
--
--      * Insert unspent output entry
--      * Insert output entry
--
importUnspentOutput ::
       (MonadBlock m, MonadImport m)
    => OutPoint
    -> Output
    -> m ()
importUnspentOutput op out =
    modify $ \s ->
        s
            { importOutput = H.insert (OutputKey op) out (importOutput s)
            , importUnspent =
                  H.insert (UnspentKey op) (Just out) (importUnspent s)
            }

-- | Undo Import unspent output.
importUndoUnspentOutput ::
       (MonadBlock m, MonadImport m)
    => OutPoint
    -> Output
    -> m ()
importUndoUnspentOutput op out =
    modify $ \s ->
        s
            { importOutput = H.insert (OutputKey op) out (importOutput s)
            , importUnspent =
                  H.insert (UnspentKey op) Nothing (importUnspent s)
            }

-- | Spend an output if it has an address:
--
--     * Remove address output
--     * Insert address transaction
--     * If block provided, decrease confirmed balance by output value
--     * Else decrease unconfirmed balance by output value
--
importSpendAddress ::
       (MonadImport m, MonadBlock m)
    => Maybe BlockRef
    -> OutPoint
    -> Output
    -> TxHash
    -> m ()
importSpendAddress mb op out tx_hash = do
    net <- asks myNetwork
    case scriptToAddressBS net (B.Short.fromShort (outScript out)) of
        Nothing -> return ()
        Just a -> do
            balance <- importGetBalance a
            let addr_out_key =
                    AddrOutKey
                        { addrOutputAddress = a
                        , addrOutputHeight = blockRefHeight <$> outBlock out
                        , addrOutputPos = blockRefPos <$> outBlock out
                        , addrOutPoint = op
                        }
                addr_tx_key =
                    AddrTxKey
                        { addrTxKey = a
                        , addrTxHeight = blockRefHeight <$> mb
                        , addrTxPos = blockRefPos <$> mb
                        , addrTxHash = tx_hash
                        }
                balance_value
                    | isJust mb =
                        balance
                            { balanceValue =
                                  balanceValue balance - outputValue out
                            , balanceUtxoCount = balanceUtxoCount balance - 1
                            }
                    | otherwise =
                        balance
                            { balanceUnconfirmed =
                                  balanceUnconfirmed balance -
                                  fromIntegral (outputValue out)
                            , balanceUtxoCount = balanceUtxoCount balance - 1
                            }
                maybe_balance
                    | balanceUtxoCount balance_value == 0 = Nothing
                    | otherwise = Just balance_value
            modify $ \s ->
                s
                    { importAddrOutput =
                          H.insert addr_out_key Nothing (importAddrOutput s)
                    , importAddrTx =
                          H.insert addr_tx_key (Just ()) (importAddrTx s)
                    , importBalance =
                          H.insert
                              (BalanceKey a)
                              maybe_balance
                              (importBalance s)
                    }

importUndoSpendAddress ::
    (MonadImport m, MonadBlock m)
    => Maybe BlockRef
    -> OutPoint
    -> Output
    -> TxHash
    -> m ()
importUndoSpendAddress mb op out tx_hash = do
    net <- asks myNetwork
    case scriptToAddressBS net (B.Short.fromShort (outScript out)) of
        Nothing -> return ()
        Just a -> do
            balance <- importGetBalance a
            let addr_out_key =
                    AddrOutKey
                        { addrOutputAddress = a
                        , addrOutputHeight = blockRefHeight <$> outBlock out
                        , addrOutputPos = blockRefPos <$> outBlock out
                        , addrOutPoint = op
                        }
                addr_tx_key =
                    AddrTxKey
                        { addrTxKey = a
                        , addrTxHeight = blockRefHeight <$> mb
                        , addrTxPos = blockRefPos <$> mb
                        , addrTxHash = tx_hash
                        }
                balance_value
                    | isJust mb =
                        balance
                            { balanceValue =
                                  balanceValue balance + outputValue out
                            , balanceUtxoCount = balanceUtxoCount balance + 1
                            }
                    | otherwise =
                        balance
                            { balanceUnconfirmed =
                                  balanceUnconfirmed balance +
                                  fromIntegral (outputValue out)
                            , balanceUtxoCount = balanceUtxoCount balance + 1
                            }
                out' = out {outSpender = Nothing}
            modify $ \s ->
                s
                    { importAddrOutput =
                          H.insert addr_out_key (Just out') (importAddrOutput s)
                    , importAddrTx =
                          H.insert addr_tx_key Nothing (importAddrTx s)
                    , importBalance =
                          H.insert
                              (BalanceKey a)
                              (Just balance_value)
                              (importBalance s)
                    }

-- | Spend an output:
--
--     * Remove unspent output
--     * Update output to spent by provided input
--
importSpendOutput ::
       (MonadImport m)
    => Maybe BlockRef
    -> OutPoint
    -> Output
    -> TxHash
    -> Word32
    -> m ()
importSpendOutput mb op out tx_hash i = do
    let spender =
            Spender {spenderHash = tx_hash, spenderIndex = i, spenderBlock = mb}
        out' = out {outSpender = Just spender}
    modify $ \s ->
        s
            { importUnspent = H.insert (UnspentKey op) Nothing (importUnspent s)
            , importOutput = H.insert (OutputKey op) out' (importOutput s)
            }

-- | Undo spending an output.
importUndoSpendOutput :: (MonadImport m) => OutPoint -> Output -> m ()
importUndoSpendOutput op out = do
    let out' = out {outSpender = Nothing}
    modify $ \s ->
        s
            { importUnspent = H.insert (UnspentKey op) (Just out') (importUnspent s)
            , importOutput = H.insert (OutputKey op) out' (importOutput s)
            }

-- | Update a transaction without deleting it.
importUpdateTx :: (MonadBlock m, MonadImport m) => Maybe BlockRef -> TxHash -> m ()
importUpdateTx mb tx_hash = do
    etr <-
        importGetTxRecord tx_hash >>= \case
            Nothing ->
                throwString $
                "Could not get tx record: " <> cs (txHashToHex tx_hash)
            Just x -> return x
    let ops = map prevOutput . txIn $ txValue etr
        etx = txValue etr
        eb = txValueBlock etr
    prevs <-
        forM ops $ \op ->
            importGetOutput op >>= \case
                Nothing ->
                    throwString $
                    "Could not get previous output: " <> showOutPoint op
                Just x -> return x
    mapM_ (update_input eb) $ zip3 [0 ..] ops prevs
    outs <-
        forM (take (length (txOut etx)) [0 ..]) $ \i -> do
        let op = OutPoint tx_hash i
        importGetOutput op >>= \case
            Nothing -> throwString $ "Could not get output: " <> showOutPoint op
            Just x -> return x
    mapM_ (update_output eb) $ zip [0 ..] outs
    when (isNothing eb && isJust mb) $
        modify $ \s ->
            s
                { importMempool =
                      H.insert (MempoolKey tx_hash) Nothing (importMempool s)
                }
    when (isJust eb && isNothing mb) $
        modify $ \s ->
            s
                { importMempool =
                      H.insert (MempoolKey tx_hash) (Just ()) (importMempool s)
                }
    let ntr = etr {txValueBlock = mb}
    modify $ \s ->
        s {importTxRecord = H.insert (TxKey tx_hash) ntr (importTxRecord s)}
  where
    update_input eb (i, op, out) = do
        importSpendOutput mb op out tx_hash i
        importUndoSpendAddress eb op out tx_hash
        importSpendAddress mb op out tx_hash
    update_output eb (i, out) = do
        let op = OutPoint tx_hash i
            out' = out { outBlock = mb }
        importUnspentOutput op out'
        importUndoUnspentAddress eb op out'
        importUnspentAddress mb op out'

importDeleteTx :: (MonadBlock m, MonadImport m) => TxHash -> m ()
importDeleteTx tx_hash =
    void . runMaybeT $ do
        etr <-
            importGetTxRecord tx_hash >>= \case
                Nothing -> fail "Transaction already deleted"
                Just x -> return x
        let ops = map prevOutput . txIn $ txValue etr
            etx = txValue etr
            eb = txValueBlock etr
        outs <-
            forM (take (length (txOut etx)) [0 ..]) $ \i -> do
                let op = OutPoint tx_hash i
                importGetOutput op >>= \case
                    Nothing ->
                        throwString $
                        "Could not get output: " <> showOutPoint op
                    Just x -> return x
        mapM_ importDeleteTx . nub $
            mapMaybe (fmap spenderHash . outSpender) outs
        prevs <-
            forM ops $ \op ->
                importGetOutput op >>= \case
                    Nothing ->
                        throwString $
                        "Could not get previous output: " <> showOutPoint op
                    Just x -> return x
        mapM_ (delete_input eb) $ zip ops prevs
        mapM_ (delete_output eb) $ zip [0 ..] outs
        modify $ \s ->
            s
                { importMempool =
                      H.insert (MempoolKey tx_hash) Nothing (importMempool s)
                }
        let ntr = etr {txValueBlock = no_main <$> eb, txValueDeleted = True}
        modify $ \s ->
            s {importTxRecord = H.insert (TxKey tx_hash) ntr (importTxRecord s)}
  where
    no_main b = b {blockRefMainChain = False}
    delete_input eb (op, out) = do
        importUndoSpendOutput op out
        importUndoSpendAddress eb op out tx_hash
    delete_output eb (i, out) = do
        let op = OutPoint tx_hash i
            out' = out {outDeleted = True, outBlock = no_main <$> eb}
        importUndoUnspentOutput op out'
        importUndoUnspentAddress eb op out'

importNewBlock :: (MonadImport m, MonadBlock m) => Block -> m ()
importNewBlock b@Block {..} = do
    net <- asks myNetwork
    block_value <-
        if block_hash == headerHash (getGenesisHeader net)
        then return BlockValue
                        { blockValueHeight = 0
                        , blockValueMainChain = True
                        , blockValueWork = nodeWork (genesisNode net)
                        , blockValueHeader = blockHeader
                        , blockValueSize = fromIntegral (B.length (encode b))
                        , blockValueTxs = map txHash blockTxns
                        }
        else do
            best <-
                importGetBest >>= importGetBlock >>= \case
                    Nothing -> throwString "Could not get best block"
                    Just x -> return x
            let new_height = blockValueHeight best + 1
            BlockNode {..} <-
                asks myChain >>= chainGetBlock block_hash >>= \case
                    Nothing ->
                        throwString "Could not get block to import from chain"
                    Just x -> return x
            return
                    BlockValue
                        { blockValueHeight = new_height
                        , blockValueMainChain = True
                        , blockValueWork = nodeWork
                        , blockValueHeader = blockHeader
                        , blockValueSize = fromIntegral (B.length (encode b))
                        , blockValueTxs = map txHash blockTxns
                        }
    let new_height = blockValueHeight block_value
        height_key = HeightKey new_height
        block_ref i =
            BlockRef
                { blockRefHeight = new_height
                , blockRefHash = block_hash
                , blockRefPos = i
                , blockRefMainChain = True
                }
    height_value <- (block_hash :) <$> importGetHeight new_height
    modify $ \s ->
        s
            { importBestBlock =
                  H.insert BestBlockKey block_hash (importBestBlock s)
            , importHeight =
                  H.insert height_key height_value (importHeight s)
            , importBlockValue =
                  H.insert block_key block_value (importBlockValue s)
            , importEvents = BestBlock block_hash : importEvents s
            }
    mapM_
        (\(i, tx) -> importInsertTx (Just (block_ref i)) tx)
        (zip [0 ..] blockTxns)
  where
    block_hash = headerHash blockHeader
    block_key = BlockKey block_hash

importRevertBlock :: (MonadBlock m, MonadImport m) => m ()
importRevertBlock = do
    best <-
        importGetBest >>= importGetBlock >>= \case
            Nothing -> throwString "Could not get best block"
            Just x -> return x
    let block_hash = headerHash (blockValueHeader best)
        block_key = BlockKey block_hash
        block_value = best {blockValueMainChain = False}
    modify $ \s ->
        s
            { importBestBlock =
                  H.insert
                      BestBlockKey
                      (prevBlock (blockValueHeader best))
                      (importBestBlock s)
            , importBlockValue =
                  H.insert block_key block_value (importBlockValue s)
            }
    importDeleteTx (head (blockValueTxs best))
    mapM_ (importUpdateTx Nothing) (tail (blockValueTxs best))

-- | Add new block.
addNewBlock :: MonadBlock m => Block -> m ()
addNewBlock block@Block {..} =
    runMonadImport $ do
        new_height <- get_new_height
        $(logInfoS) "Block" $ "Importing block height: " <> cs (show new_height)
        importNewBlock block
  where
    new_hash = headerHash blockHeader
    prev_block = prevBlock blockHeader
    get_new_height = do
        net <- asks myNetwork
        if blockHeader == getGenesisHeader net
            then return 0
            else do
                best <-
                    asks myBlockDB >>= \db -> getBestBlock db def
                when (prev_block /= headerHash (blockValueHeader best)) .
                    throwString $
                    "Block does not build on best: " <> show new_hash
                return $ blockValueHeight best + 1

-- | Revert best block.
revertBestBlock :: MonadBlock m => m ()
revertBestBlock = do
    net <- asks myNetwork
    db <- asks myBlockDB
    BlockValue {..} <- getBestBlock db def
    when (blockValueHeader == getGenesisHeader net) . throwString $
        "Attempted to revert genesis block"
    runMonadImport $ do
        $(logInfoS) "Block" $
            "Reverting best block: " <> cs (show blockValueHeight)
        importRevertBlock
    reset_peer (blockValueHeight - 1)
  where
    reset_peer height = do
        base_height_box <- asks myBaseHeight
        peer_box <- asks myPeer
        atomically $ do
            writeTVar base_height_box height
            writeTVar peer_box Nothing

-- | Validate a transaction without script evaluation.
validateTx :: (MonadBlock m, MonadImport m) => Tx -> ExceptT TxException m ()
validateTx tx = do
    when double_input $ throwError DoubleSpend
    prev_outs <-
        forM (txIn tx) $ \TxIn {..} ->
            importGetOutput prevOutput >>= \case
                Just o
                    | isNothing (outSpender o) -> return o
                    | otherwise -> throwError DoubleSpend
                Nothing -> throwError OrphanTx
    let sum_inputs = sum (map outputValue prev_outs)
        sum_outputs = sum (map outValue (txOut tx))
    when (sum_outputs > sum_inputs) (throwError OverSpend)
  where
    double_input =
        (/=)
            (length (txIn tx))
            (length (nubBy ((==) `on` prevOutput) (txIn tx)))

-- | Import a transaction.
importMempoolTx ::
       (MonadBlock m, MonadImport m) => Tx -> m Bool
importMempoolTx tx =
    runExceptT validate_tx >>= \case
        Left e -> do
            ret <-
                case e of
                    AlreadyImported -> return True
                    OrphanTx -> do
                        import_orphan
                        return False
                    _ -> do
                        $(logErrorS) "Block" $
                            "Could not import tx hash: " <>
                            cs (txHashToHex (txHash tx)) <>
                            " reason: " <>
                            cs (show e)
                        return False
            asks myListener >>= \l -> atomically (l (TxException (txHash tx) e))
            return ret
        Right () -> do
            importInsertTx Nothing tx
            modify $ \s ->
                s {importEvents = MempoolNew tx_hash : importEvents s}
            return True
  where
    tx_hash = txHash tx
    import_orphan = do
        $(logInfoS) "Block " $
            "Got orphan tx hash: " <> cs (txHashToHex (txHash tx))
        db <- asks myBlockDB
        R.insert db (OrphanKey (txHash tx)) tx
    validate_tx = do
        importGetTxRecord (txHash tx) >>= \x ->
            when (maybe False txValueDeleted x) (throwError AlreadyImported)
        validateTx tx

-- | Attempt to synchronize blocks.
syncBlocks :: MonadBlock m => m ()
syncBlocks =
    void . runMaybeT $ do
        net <- asks myNetwork
        chain_best <- asks myChain >>= chainGetBest
        revert_if_needed chain_best
        let chain_height = nodeHeight chain_best
        base_height_box <- asks myBaseHeight
        db <- asks myBlockDB
        best_block <- getBestBlock db def
        let best_height = blockValueHeight best_block
        when (best_height == chain_height) $ do
            reset_peer best_height
            empty
        base_height <- readTVarIO base_height_box
        p <- get_peer
        when (base_height > best_height + 500) empty
        when (base_height >= chain_height) empty
        ch <- asks myChain
        let sync_lowest = min chain_height (base_height + 1)
            sync_highest = min chain_height (base_height + 501)
        sync_top <-
            if sync_highest == chain_height
                then return chain_best
                else chainGetAncestor sync_highest chain_best ch >>= \case
                         Nothing ->
                             throwString
                                 "Could not get syncing header from chain"
                         Just b -> return b
        sync_blocks <-
            (++ [sync_top]) <$>
            if sync_lowest == chain_height
                then return []
                else chainGetParents sync_lowest sync_top ch
        update_peer sync_highest (Just p)
        peerGetBlocks net p (map (headerHash . nodeHeader) sync_blocks)
  where
    get_peer =
        asks myPeer >>= readTVarIO >>= \case
            Just p -> return p
            Nothing ->
                asks myManager >>= managerGetPeers >>= \case
                    [] -> empty
                    p:_ -> return (onlinePeerMailbox p)
    reset_peer best_height = update_peer best_height Nothing
    update_peer height mp = do
        base_height_box <- asks myBaseHeight
        peer_box <- asks myPeer
        atomically $ do
            writeTVar base_height_box height
            writeTVar peer_box mp
    revert_if_needed chain_best = do
        db <- asks myBlockDB
        ch <- asks myChain
        best <- getBestBlock db def
        let best_hash = headerHash (blockValueHeader best)
            chain_hash = headerHash (nodeHeader chain_best)
        when (best_hash /= chain_hash) $
            chainGetBlock best_hash ch >>= \case
                Nothing -> do
                    revertBestBlock
                    revert_if_needed chain_best
                Just best_node -> do
                    split_hash <-
                        headerHash . nodeHeader <$>
                        chainGetSplitBlock chain_best best_node ch
                    revert_until split_hash
    revert_until split = do
        best_hash <-
            asks myBlockDB >>= \db ->
                headerHash . blockValueHeader <$>
                getBestBlock db def
        when (best_hash /= split) $ do
            revertBestBlock
            revert_until split

-- | Import a block.
importBlock ::
       (MonadError String m, MonadBlock m) => Block -> m ()
importBlock block@Block {..} = do
    bn <- asks myChain >>= chainGetBlock (headerHash blockHeader)
    when (isNothing bn) $
        throwString $
        "Not in chain: block hash" <>
        cs (blockHashToHex (headerHash blockHeader))
    best <- asks myBlockDB >>= \db -> getBestBlock db def
    let best_hash = headerHash (blockValueHeader best)
        prev_hash = prevBlock blockHeader
    when (prev_hash /= best_hash) (throwError "does not build on best")
    addNewBlock block

-- | Process incoming messages to the 'BlockStore' mailbox.
processBlockMessage :: (MonadUnliftIO m, MonadBlock m) => BlockMessage -> m ()

processBlockMessage (BlockChainNew _) = syncBlocks

processBlockMessage (BlockPeerConnect p) = syncBlocks >> syncMempool p

processBlockMessage (BlockReceived p b) =
    runExceptT (importBlock b) >>= \case
        Left e -> do
            pstr <- peerString p
            let hash = headerHash (blockHeader b)
            $(logErrorS) "Block" $
                "Error importing block " <> cs (blockHashToHex hash) <>
                " from peer " <>
                pstr <>
                ": " <>
                fromString e
            mgr <- asks myManager
            managerKill (PeerMisbehaving (fromString e)) p mgr
        Right () -> importOrphans >> syncBlocks >> syncMempool p

processBlockMessage (TxReceived _ tx) =
    isAtHeight >>= \x ->
        when x $ do
            _ <- runMonadImport $ importMempoolTx tx
            importOrphans

processBlockMessage (TxPublished tx) =
    void . runMonadImport $ importMempoolTx tx

processBlockMessage (BlockPeerDisconnect p) = do
    peer_box <- asks myPeer
    base_height_box <- asks myBaseHeight
    db <- asks myBlockDB
    best <- getBestBlock db def
    is_my_peer <-
        atomically $
        readTVar peer_box >>= \x ->
            if x == Just p
                then do
                    writeTVar peer_box Nothing
                    writeTVar base_height_box (blockValueHeight best)
                    return True
                else return False
    when is_my_peer syncBlocks

processBlockMessage (BlockNotReceived p h) = do
    pstr <- peerString p
    $(logErrorS) "Block" $
        "Peer " <> pstr <> " unable to serve block " <> cs (show h)
    mgr <- asks myManager
    managerKill (PeerMisbehaving "Block not found") p mgr

processBlockMessage (TxAvailable p ts) =
    isAtHeight >>= \h ->
        when h $ do
            pstr <- peerString p
            $(logDebugS) "Block" $
                "Received " <> cs (show (length ts)) <>
                " tx inventory from peer " <>
                pstr
            net <- asks myNetwork
            db <- asks myBlockDB
            has <-
                fmap catMaybes . forM ts $ \t ->
                    let mem =
                            retrieve db def (MempoolKey t) >>= \case
                                Nothing -> return Nothing
                                Just () -> return (Just t)
                        orp =
                            retrieve db def (OrphanKey t) >>= \case
                                Nothing -> return Nothing
                                Just Tx {} -> return (Just t)
                     in runMaybeT $ MaybeT mem <|> MaybeT orp
            let new = ts \\ has
            unless (null new) $ do
                $(logDebugS) "Block" $
                    "Requesting " <> cs (show (length new)) <>
                    " new txs from peer " <>
                    pstr
                peerGetTxs net p new

processBlockMessage (PongReceived p n) = do
    pstr <- peerString p
    $(logDebugS) "Block" $
        "Pong nonce " <> cs (show n) <> " from peer " <> pstr
    asks myListener >>= atomically . ($ PeerPong p n)

-- | Import orphan transactions that can be imported.
importOrphans :: (MonadUnliftIO m, MonadBlock m) => m ()
importOrphans = do
    db <- asks myBlockDB
    ret <-
        runResourceT . runConduit $
        matching db def ShortOrphanKey .| mapMC (import_tx . snd) .| anyC id
    when ret importOrphans
  where
    import_tx tx' = runMonadImport $ importMempoolTx tx'

getAddrTxs ::
       (MonadResource m, MonadUnliftIO m)
    => Address
    -> Maybe BlockHeight
    -> DB
    -> ReadOptions
    -> ConduitT () AddrTx m ()
getAddrTxs a h db opts =
    matchingSkip db opts (ShortAddrTxKey a) (ShortAddrTxKeyHeight a h) .| mapC f
  where
    f (AddrTxKey {..}, ()) =
        AddrTx
            { getAddrTxAddr = addrTxKey
            , getAddrTxHash = addrTxHash
            , getAddrTxHeight = addrTxHeight
            , getAddrTxPos = addrTxPos
            }
    f _ = error "Nonsense! This ship in unsinkable!"

-- | Get unspent outputs for an address.
getUnspent ::
       (MonadResource m, MonadUnliftIO m)
    => Address
    -> Maybe BlockHeight
    -> DB
    -> ReadOptions
    -> ConduitT () AddrOutput m ()
getUnspent a h db opts =
    getAddrUnspent a h db opts .| mapC (uncurry AddrOutput)

-- | Synchronize mempool against a peer.
syncMempool :: MonadBlock m => Peer -> m ()
syncMempool p =
    void . runMaybeT $ do
        guard =<< lift isAtHeight
        $(logInfoS) "Block" "Syncing mempool..."
        MMempool `sendMessage` p

-- | Is the block store synchronized?
isAtHeight :: MonadBlock m => m Bool
isAtHeight = do
    db <- asks myBlockDB
    bb <- getBestBlockHash db def
    ch <- asks myChain
    cb <- chainGetBest ch
    time <- liftIO getPOSIXTime
    let recent = floor time - blockTimestamp (nodeHeader cb) < 60 * 60 * 4
    return (recent && headerHash (nodeHeader cb) == bb)

zero :: TxHash
zero = "0000000000000000000000000000000000000000000000000000000000000000"

-- | Show outpoint in log.
showOutPoint :: (IsString a, ConvertibleStrings Text a) => OutPoint -> a
showOutPoint OutPoint {..} =
    cs $ txHashToHex outPointHash <> ":" <> cs (show outPointIndex)

-- | Show peer data in log.
peerString :: (MonadBlock m, IsString a) => Peer -> m a
peerString p = do
    mgr <- asks myManager
    managerGetPeer mgr p >>= \case
        Nothing -> return "[unknown]"
        Just o -> return $ fromString $ show $ onlinePeerAddress o

-- | Load all UTXO in unspent database.
loadUTXO :: (MonadUnliftIO m, MonadBlock m) => m ()
loadUTXO =
    asks myUnspentDB >>= \case
        Nothing -> return ()
        Just udb -> do
            $(logInfoS) "BlockStore" "Loading UTXO in memory..."
            db <- asks myBlockDB
            delete_all udb
            runResourceT . runConduit $
                matching db def ShortUnspentKey .| mapM_C (uncurry (f udb))
  where
    delete_all udb = do
        bops <-
            runResourceT . runConduit $
            matching udb def ShortBalanceKey .| mapC (uncurry del_bal) .|
            sinkList
        oops <-
            runResourceT . runConduit $
            matching udb def ShortOutputKey .| mapC (uncurry del_out) .|
            sinkList
        R.writeBatch udb $ bops <> oops
    del_bal k Balance {} = R.deleteOp k
    del_out k Output {} = R.deleteOp k
    f udb UnspentKey {..} o@Output {..} = do
        net <- asks myNetwork
        R.insert udb (OutputKey unspentKey) o
        case scriptToAddressBS net (B.Short.fromShort outScript) of
            Nothing -> return ()
            Just a -> do
                let b =
                        if isJust outBlock
                            then Balance
                                     { balanceValue = outputValue
                                     , balanceUnconfirmed = 0
                                     , balanceUtxoCount = 1
                                     }
                            else Balance
                                     { balanceValue = 0
                                     , balanceUnconfirmed =
                                           fromIntegral outputValue
                                     , balanceUtxoCount = 1
                                     }
                bm <- R.retrieve udb def (BalanceKey a)
                let b' =
                        case bm of
                            Nothing -> b
                            Just x  -> g x b
                R.insert udb (BalanceKey a) b'
    f _ _ _ = undefined
    g a b =
        Balance
            { balanceValue = balanceValue a + balanceValue b
            , balanceUnconfirmed = balanceUnconfirmed a + balanceUnconfirmed b
            , balanceUtxoCount = balanceUtxoCount a + balanceUtxoCount b
            }

--
-- Query Functions
--

-- | Get best block hash.
getBestBlockHash :: MonadIO m => DB -> ReadOptions -> m BlockHash
getBestBlockHash db opts =
    retrieve db opts BestBlockKey >>= \case
        Nothing -> throwString "Best block hash not available"
        Just bh -> return bh

-- | Get best block.
getBestBlock :: MonadIO m => DB -> ReadOptions -> m BlockValue
getBestBlock db opts =
    getBestBlockHash db opts >>= \bh ->
        getBlock bh db opts >>= \case
            Nothing ->
                throwString $
                "Best block not available at hash: " <> cs (blockHashToHex bh)
            Just b -> return b

-- | Get one block at specified height.
getBlocksAtHeight ::
       MonadIO m => BlockHeight -> DB -> ReadOptions -> m [BlockHash]
getBlocksAtHeight height db opts =
    fromMaybe [] <$> retrieve db opts (HeightKey height)

-- | Get blocks for specific hashes.
getBlocks :: MonadIO m => [BlockHash] -> DB -> ReadOptions -> m [BlockValue]
getBlocks bids db opts =
    fmap catMaybes . forM (nub bids) $ \bid -> getBlock bid db opts

-- | Get a block.
getBlock ::
       MonadIO m => BlockHash -> DB -> ReadOptions -> m (Maybe BlockValue)
getBlock bh db opts = retrieve db opts (BlockKey bh)

-- | Get unspent outputs for an address.
getAddrUnspent ::
       (MonadUnliftIO m, MonadResource m)
    => Address
    -> Maybe BlockHeight
    -> DB
    -> ReadOptions
    -> ConduitT () (AddrOutKey, Output) m ()
getAddrUnspent addr h db opts =
    matchingSkip
        db
        opts
        (ShortAddrOutKey addr)
        (ShortAddrOutKeyHeight addr h)

-- | Get balance for an address.
getBalance ::
       MonadIO m => Address -> DB -> ReadOptions -> m AddressBalance
getBalance addr db opts =
    retrieve db opts (BalanceKey addr) >>= \case
        Just Balance {..} ->
            return
                AddressBalance
                { addressBalAddress = addr
                , addressBalConfirmed = balanceValue
                , addressBalUnconfirmed = balanceUnconfirmed
                , addressUtxoCount = balanceUtxoCount
                }
        Nothing ->
            return
                AddressBalance
                { addressBalAddress = addr
                , addressBalConfirmed = 0
                , addressBalUnconfirmed = 0
                , addressUtxoCount = 0
                }

-- | Get list of transactions in mempool.
getMempool :: MonadUnliftIO m => DB -> ReadOptions -> m [TxHash]
getMempool db opts = get_hashes <$> matchingAsList db opts ShortMempoolKey
  where
    get_hashes mempool_txs = [tx_hash | (MempoolKey tx_hash, ()) <- mempool_txs]

-- | Get single transaction.
getTx ::
       MonadUnliftIO m
    => Network
    -> TxHash
    -> DB
    -> ReadOptions
    -> m (Maybe DetailedTx)
getTx net th db opts = do
    xs <- matchingAsList db opts (ShortMultiTxKey th)
    case find_tx xs of
        Just TxRecord {..} ->
            let os = map (uncurry output) (filter_outputs xs)
                is =
                    zipWith
                        input
                        (txValuePrevOuts <> repeat (0, B.empty))
                        (txIn txValue)
             in return $
                Just
                    DetailedTx
                        { detailedTxData = txValue
                        , detailedTxFee = fee is os
                        , detailedTxBlock = txValueBlock
                        , detailedTxInputs = is
                        , detailedTxOutputs = os
                        , detailedTxDeleted = txValueDeleted
                        }
        Nothing -> return Nothing
  where
    fee is os =
        if any isCoinbase is
            then 0
            else sum (map detInValue is) - sum (map detOutValue os)
    input (val, scr) TxIn {..} =
        if outPointHash prevOutput == zero
            then DetailedCoinbase
                     { detInOutPoint = prevOutput
                     , detInSequence = txInSequence
                     , detInSigScript = scriptInput
                     , detInNetwork = net
                     }
            else DetailedInput
                     { detInOutPoint = prevOutput
                     , detInSequence = txInSequence
                     , detInSigScript = scriptInput
                     , detInPkScript = scr
                     , detInValue = val
                     , detInNetwork = net
                     }
    output OutPoint {..} Output {..} =
        DetailedOutput
            { detOutValue = outputValue
            , detOutScript = outScript
            , detOutSpender = outSpender
            , detOutNetwork = net
            , detOutDeleted = outDeleted
            }
    find_tx xs =
        listToMaybe
            [ t
            | (k, v) <- xs
            , case k of
                  MultiTxKey {} -> True
                  _ -> False
            , let MultiTx t = v
            ]
    filter_outputs xs =
        [ (p, o)
        | (k, v) <- xs
        , case (k, v) of
              (MultiTxOutKey {}, MultiTxOutput {}) -> True
              _ -> False
        , let MultiTxOutKey (OutputKey p) = k
        , let MultiTxOutput o = v
        ]
