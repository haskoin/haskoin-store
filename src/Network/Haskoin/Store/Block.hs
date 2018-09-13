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
      , getBlockAtHeight
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
import           Control.Monad.State.Strict
import           Control.Monad.Trans.Maybe
import qualified Data.ByteString             as B
import           Data.List
import           Data.Map                    (Map)
import qualified Data.Map.Strict             as M
import           Data.Maybe
import           Data.Serialize              (encode)
import           Data.Set                    (Set)
import qualified Data.Set                    as S
import           Data.String
import           Data.String.Conversions
import           Data.Text                   (Text)
import           Data.Time.Clock.POSIX
import           Database.RocksDB            (BatchOp, DB, Snapshot)
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

-- | Map of outputs for importing transactions.
type OutputMap = Map OutPoint Output

-- | Map of address balances for importing transactions.
type AddressMap = Map Address Balance

-- | Map of transactions for importing.
type TxMap = Map TxHash ImportTx

-- | Status of a transaction being verified for importing.
data TxStatus
    = TxValid
    | TxOrphan
    | TxLowFunds
    | TxInputSpent
    deriving (Eq, Show, Ord)

-- | Transaction to import.
data ImportTx = ImportTx
    { importTx      :: !Tx
    , importTxBlock :: !(Maybe BlockRef)
    }

-- | State for importing or removing blocks and transactions.
data ImportState = ImportState
    { outputMap   :: !OutputMap
    , addressMap  :: !AddressMap
    , deleteTxs   :: !(Set TxHash)
    , newTxs      :: !TxMap
    , blockAction :: !(Maybe BlockAction)
    }

-- | Context for importing or removing blocks and transactions.
type MonadImport m = MonadState ImportState m

-- | Whether to import or remove a block.
data BlockAction = RevertBlock | ImportBlock !Block

-- | Run within 'MonadImport' context. Execute updates to database and
-- notification to subscribers when finished.
runMonadImport ::
       MonadBlock m => StateT ImportState m a -> m a
runMonadImport f =
    evalStateT
        (f >>= \a -> update_database >> return a)
        ImportState
            { outputMap = M.empty
            , addressMap = M.empty
            , deleteTxs = S.empty
            , newTxs = M.empty
            , blockAction = Nothing
            }
  where
    update_database = do
        net <- asks myNetwork
        ops <-
            concat <$>
            sequence
                [ getBlockOps
                , getBalanceOps
                , getDeleteTxOps net
                , getInsertTxOps
                , purgeOrphanOps
                ]
        db <- asks myBlockDB
        writeBatch db ops
        l <- asks myListener
        gets blockAction >>= \case
            Just (ImportBlock Block {..}) ->
                atomically (l (BestBlock (headerHash blockHeader)))
            Just RevertBlock -> $(logWarnS) "Block" "Reverted best block"
            _ -> return ()
        gets newTxs >>= \ths ->
            forM_ (M.keys ths) $ \tx -> atomically (l (MempoolNew tx))

-- | Run block store process.
blockStore :: (MonadUnliftIO m, MonadLoggerIO m) => BlockConfig -> m ()
blockStore BlockConfig {..} = do
    base_height_box <- newTVarIO 0
    peer_box <- newTVarIO Nothing
    runReaderT
        (init_db >> syncBlocks >> run)
        BlockRead
            { mySelf = blockConfMailbox
            , myBlockDB = blockConfDB
            , myChain = blockConfChain
            , myManager = blockConfManager
            , myListener = blockConfListener
            , myBaseHeight = base_height_box
            , myPeer = peer_box
            , myNetwork = blockConfNet
            }
  where
    run =
        forever $ do
            msg <- receive blockConfMailbox
            processBlockMessage msg
    init_db =
        runResourceT $ do
            runConduit $
                matching blockConfDB Nothing ShortOrphanKey .|
                mapM_C (\(k, Tx {}) -> remove blockConfDB k)
            retrieve blockConfDB Nothing BestBlockKey >>= \case
                Nothing -> addNewBlock (genesisBlock blockConfNet)
                Just (_ :: BlockHash) -> do
                    BlockValue {..} <-
                        withSnapshot blockConfDB $ getBestBlock blockConfDB
                    base_height_box <- asks myBaseHeight
                    atomically $ writeTVar base_height_box blockValueHeight

-- | Get best block hash.
getBestBlockHash :: MonadIO m => DB -> Snapshot -> m BlockHash
getBestBlockHash db s =
    retrieve db (Just s) BestBlockKey >>= \case
        Nothing -> throwString "Best block hash not available"
        Just bh -> return bh

-- | Get best block.
getBestBlock :: MonadIO m => DB -> Snapshot -> m BlockValue
getBestBlock db s =
    getBestBlockHash db s >>= \bh ->
        getBlock bh db s >>= \case
            Nothing ->
                throwString $
                "Best block not available at hash: " <> cs (blockHashToHex bh)
            Just b -> return b

-- | Get one block at specified height.
getBlockAtHeight ::
       MonadIO m => BlockHeight -> DB -> Snapshot -> m (Maybe BlockValue)
getBlockAtHeight height db s =
    retrieve db (Just s) (HeightKey height) >>= \case
        Nothing -> return Nothing
        Just h -> retrieve db (Just s) (BlockKey h)

-- | Get blocks for specific hashes.
getBlocks :: MonadIO m => [BlockHash] -> DB -> Snapshot -> m [BlockValue]
getBlocks bids db s =
    fmap catMaybes . forM (nub bids) $ \bid -> getBlock bid db s

-- | Get a block.
getBlock ::
       MonadIO m => BlockHash -> DB -> Snapshot -> m (Maybe BlockValue)
getBlock bh db s = retrieve db (Just s) (BlockKey bh)

-- | Get unspent outputs for an address.
getAddrUnspent ::
       (MonadUnliftIO m, MonadResource m)
    => Address
    -> Maybe BlockHeight
    -> DB
    -> Snapshot
    -> ConduitT () (AddrOutKey, Output) m ()
getAddrUnspent addr h db s =
    matchingSkip
        db
        (Just s)
        (ShortAddrOutKey addr)
        (ShortAddrOutKeyHeight addr h)

-- | Get balance for an address.
getBalance ::
       MonadIO m => Address -> DB -> Snapshot -> m AddressBalance
getBalance addr db s =
    retrieve db (Just s) (BalanceKey addr) >>= \case
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
getMempool :: MonadUnliftIO m => DB -> Snapshot -> m [TxHash]
getMempool db s = get_hashes <$> matchingAsList db (Just s) ShortMempoolKey
  where
    get_hashes mempool_txs = [tx_hash | (MempoolKey tx_hash, ()) <- mempool_txs]

-- | Get single transaction.
getTx ::
       MonadUnliftIO m
    => Network
    -> TxHash
    -> DB
    -> Snapshot
    -> m (Maybe DetailedTx)
getTx net th db s = do
    xs <- matchingAsList db (Just s) (ShortMultiTxKey th)
    case find_tx xs of
        Just TxRecord {..} ->
            let os = map (uncurry output) (filter_outputs xs)
                is = map (input txValuePrevOuts) (txIn txValue)
             in return $
                Just
                    DetailedTx
                        { detailedTxData = txValue
                        , detailedTxFee = fee is os
                        , detailedTxBlock = txValueBlock
                        , detailedTxInputs = is
                        , detailedTxOutputs = os
                        }
        Nothing -> return Nothing
  where
    fee is os =
        if any isCoinbase is
            then 0
            else sum (map detInValue is) - sum (map detOutValue os)
    input prevs TxIn {..} =
        if outPointHash prevOutput == zero
            then DetailedCoinbase
                     { detInOutPoint = prevOutput
                     , detInSequence = txInSequence
                     , detInSigScript = scriptInput
                     , detInNetwork = net
                     }
            else let PrevOut {..} =
                         fromMaybe
                             (error
                                  ("Could not locate outpoint: " <>
                                   showOutPoint prevOutput))
                             (lookup prevOutput prevs)
                  in DetailedInput
                         { detInOutPoint = prevOutput
                         , detInSequence = txInSequence
                         , detInSigScript = scriptInput
                         , detInPkScript = prevOutScript
                         , detInValue = prevOutValue
                         , detInBlock = prevOutBlock
                         , detInNetwork = net
                         }
    output OutPoint {..} Output {..} =
        DetailedOutput
            { detOutValue = outputValue
            , detOutScript = outScript
            , detOutSpender = outSpender
            , detOutNetwork = net
            }
    find_tx xs =
        listToMaybe
            [ t
            | (k, v) <- xs
            , case k of
                  MultiTxKey {} -> True
                  _             -> False
            , let MultiTx t = v
            ]
    filter_outputs xs =
        [ (p, o)
        | (k, v) <- xs
        , case (k, v) of
              (MultiTxOutKey {}, MultiTxOutput {}) -> True
              _                                    -> False
        , let MultiTxOutKey (OutputKey p) = k
        , let MultiTxOutput o = v
        ]

-- | Get transaction output for importing transaction.
getOutput :: (MonadBlock m, MonadImport m) => OutPoint -> m (Maybe Output)
getOutput out_point = runMaybeT $ MaybeT map_lookup <|> MaybeT db_lookup
  where
    map_lookup = M.lookup out_point <$> gets outputMap
    db_key = OutputKey out_point
    db_lookup = asks myBlockDB >>= \db -> retrieve db Nothing db_key

-- | Get address balance for importing transaction.
getAddress :: (MonadBlock m, MonadImport m) => Address -> m Balance
getAddress address =
    fromMaybe emptyBalance <$>
    runMaybeT (MaybeT map_lookup <|> MaybeT db_lookup)
  where
    map_lookup = M.lookup address <$> gets addressMap
    db_key = BalanceKey address
    db_lookup = asks myBlockDB >>= \db -> retrieve db Nothing db_key

-- | Get transactions to delete.
getDeleteTxs :: MonadImport m => m (Set TxHash)
getDeleteTxs = gets deleteTxs

-- | Should this transaction be deleted already?
shouldDelete :: MonadImport m => TxHash -> m Bool
shouldDelete tx_hash = S.member tx_hash <$> getDeleteTxs

-- | Add a new block.
addBlock :: MonadImport m => Block -> m ()
addBlock block = modify $ \s -> s {blockAction = Just (ImportBlock block)}

-- | Revert best block.
revertBlock :: MonadImport m => m ()
revertBlock = modify $ \s -> s {blockAction = Just RevertBlock}

-- | Delete a transaction.
deleteTx :: MonadImport m => TxHash -> m ()
deleteTx tx_hash =
    modify $ \s -> s {deleteTxs = S.insert tx_hash (deleteTxs s)}

-- | Insert a transaction.
insertTx :: MonadImport m => Tx -> Maybe BlockRef -> m ()
insertTx tx maybe_block_ref =
    modify $ \s -> s {newTxs = M.insert (txHash tx) import_tx (newTxs s)}
  where
    import_tx = ImportTx {importTx = tx, importTxBlock = maybe_block_ref}

-- | Insert or update a transaction output.
updateOutput :: MonadImport m => OutPoint -> Output -> m ()
updateOutput out_point output =
    modify $ \s -> s {outputMap = M.insert out_point output (outputMap s)}

-- | Insert or update an address balance.
updateAddress :: MonadImport m => Address -> Balance -> m ()
updateAddress address balance =
    modify $ \s -> s {addressMap = M.insert address balance (addressMap s)}

-- | Spend an output.
spendOutput :: (MonadBlock m, MonadImport m) => OutPoint -> Spender -> m ()
spendOutput out_point spender@Spender {..} =
    void . runMaybeT $ do
        net <- asks myNetwork
        guard (out_point /= nullOutPoint)
        output@Output {..} <-
            getOutput out_point >>= \case
                Nothing ->
                    throwString $
                    "Could not get output to spend at outpoint: " <>
                    showOutPoint out_point
                Just output -> return output
        when (isJust outSpender) . throwString $
            "Output to spend already spent at outpoint: " <> showOutPoint out_point
        updateOutput out_point output {outSpender = Just spender}
        address <- MaybeT (return (scriptToAddressBS net outScript))
        balance@Balance {..} <- getAddress address
        updateAddress address $
            if isJust spenderBlock
                then balance
                     { balanceValue = balanceValue - outputValue
                     , balanceUtxoCount = balanceUtxoCount - 1
                     }
                else balance
                     { balanceUnconfirmed =
                           balanceUnconfirmed - fromIntegral outputValue
                     , balanceUtxoCount = balanceUtxoCount - 1
                     }

-- | Make an output unspent.
unspendOutput :: (MonadBlock m, MonadImport m) => OutPoint -> m ()
unspendOutput out_point =
    void . runMaybeT $ do
        net <- asks myNetwork
        guard (out_point /= nullOutPoint)
        output@Output {..} <-
            getOutput out_point >>= \case
                Nothing ->
                    throwString $
                    "Could not get output to unspend at outpoint: " <>
                    showOutPoint out_point
                Just output -> return output
        Spender {..} <- MaybeT (return outSpender)
        updateOutput out_point output {outSpender = Nothing}
        address <- MaybeT (return (scriptToAddressBS net outScript))
        balance@Balance {..} <- getAddress address
        updateAddress address $
            if isJust spenderBlock
                then balance
                     { balanceValue = balanceValue + outputValue
                     , balanceUtxoCount = balanceUtxoCount + 1
                     }
                else balance
                     { balanceUnconfirmed =
                           balanceUnconfirmed + fromIntegral outputValue
                     , balanceUtxoCount = balanceUtxoCount + 1
                     }

-- | Remove unspent output.
removeOutput :: (MonadBlock m, MonadImport m) => OutPoint -> m ()
removeOutput out_point@OutPoint {..} = do
    net <- asks myNetwork
    Output {..} <-
        getOutput out_point >>= \case
            Nothing ->
                throwString $
                "Could not get output to remove at outpoint: " <> show out_point
            Just o -> return o
    when (isJust outSpender) . throwString $
        "Cannot delete because spent outpoint: " <> show out_point
    case scriptToAddressBS net outScript of
        Nothing -> return ()
        Just address -> do
            balance@Balance {..} <- getAddress address
            updateAddress address $
                if isJust outBlock
                    then balance
                             { balanceValue = balanceValue - outputValue
                             , balanceUtxoCount = balanceUtxoCount - 1
                             }
                    else balance
                             { balanceUnconfirmed =
                                   balanceUnconfirmed - fromIntegral outputValue
                             , balanceUtxoCount = balanceUtxoCount - 1
                             }

-- | Add a new unspent output.
addOutput :: (MonadBlock m, MonadImport m) => OutPoint -> Output -> m ()
addOutput out_point@OutPoint {..} output@Output {..} = do
    net <- asks myNetwork
    updateOutput out_point output
    case scriptToAddressBS net outScript of
        Nothing -> return ()
        Just address -> do
            balance@Balance {..} <- getAddress address
            updateAddress address $
                if isJust outBlock
                    then balance
                             { balanceValue = balanceValue + outputValue
                             , balanceUtxoCount = balanceUtxoCount + 1
                             }
                    else balance
                             { balanceUnconfirmed =
                                   balanceUnconfirmed + fromIntegral outputValue
                             , balanceUtxoCount = balanceUtxoCount + 1
                             }

-- | Get transaction.
getTxRecord :: MonadBlock m => TxHash -> m (Maybe TxRecord)
getTxRecord tx_hash =
    asks myBlockDB >>= \db -> retrieve db Nothing (TxKey tx_hash)

-- | Delete a transaction.
deleteTransaction ::
       (MonadBlock m, MonadImport m)
    => TxHash
    -> m ()
deleteTransaction tx_hash = shouldDelete tx_hash >>= \d -> unless d delete_it
  where
    delete_it = do
        TxRecord {..} <-
            getTxRecord tx_hash >>= \case
                Nothing ->
                    throwString $
                    "Could not get tx to delete at hash: " <>
                    cs (txHashToHex tx_hash)
                Just r -> return r
        let n_out = length (txOut txValue)
            prevs = map prevOutput (txIn txValue)
        remove_spenders n_out
        remove_outputs n_out
        unspend_inputs prevs
        deleteTx tx_hash
    remove_spenders n_out =
        forM_ (take n_out [0 ..]) $ \i ->
            let out_point = OutPoint tx_hash i
             in getOutput out_point >>= \case
                    Nothing ->
                        throwString $
                        "Could not get spent outpoint: " <> show out_point
                    Just Output {outSpender = Just Spender {..}} ->
                        deleteTransaction spenderHash
                    Just _ -> return ()
    remove_outputs n_out =
        mapM_ (removeOutput . OutPoint tx_hash) (take n_out [0 ..])
    unspend_inputs = mapM_ unspendOutput

-- | Add new block.
addNewBlock :: MonadBlock m => Block -> m ()
addNewBlock block@Block {..} =
    runMonadImport $ do
        new_height <- get_new_height
        $(logInfoS) "Block" $ "Importing block height: " <> cs (show new_height)
        import_txs new_height
        addBlock block
  where
    import_txs new_height =
        mapM_
            (uncurry (import_tx (BlockRef new_hash new_height)))
            (zip [0 ..] blockTxns)
    import_tx block_ref i tx = importTransaction tx (Just (block_ref i))
    new_hash = headerHash blockHeader
    prev_block = prevBlock blockHeader
    get_new_height = do
        net <- asks myNetwork
        if blockHeader == getGenesisHeader net
            then return 0
            else do
                best <-
                    asks myBlockDB >>= \db -> withSnapshot db $ getBestBlock db
                when (prev_block /= headerHash (blockValueHeader best)) .
                    throwString $
                    "Block does not build on best at hash: " <> show new_hash
                return $ blockValueHeight best + 1

-- | Get write ops for importing or removing a block.
getBlockOps :: (MonadBlock m, MonadImport m) => m [BatchOp]
getBlockOps =
    gets blockAction >>= \case
        Nothing -> return []
        Just RevertBlock -> get_block_remove_ops
        Just (ImportBlock block) -> get_block_insert_ops block
  where
    get_block_insert_ops block@Block {..} = do
        let block_hash = headerHash blockHeader
        ch <- asks myChain
        bn <-
            chainGetBlock block_hash ch >>= \case
                Just bn -> return bn
                Nothing ->
                    throwString $
                    "Could not get block header for hash: " <>
                    cs (blockHashToHex block_hash)
        let block_value =
                BlockValue
                    { blockValueHeight = nodeHeight bn
                    , blockValueWork = nodeWork bn
                    , blockValueHeader = nodeHeader bn
                    , blockValueSize = fromIntegral (B.length (encode block))
                    , blockValueTxs = map txHash blockTxns
                    }
        return
            [ insertOp (BlockKey block_hash) block_value
            , insertOp (HeightKey (nodeHeight bn)) block_hash
            , insertOp BestBlockKey block_hash
            ]
    get_block_remove_ops = do
        db <- asks myBlockDB
        BlockValue {..} <- withSnapshot db $ getBestBlock db
        let block_hash = headerHash blockValueHeader
            block_key = BlockKey block_hash
            height_key = HeightKey blockValueHeight
            prev_block = prevBlock blockValueHeader
        return
            [ deleteOp block_key
            , deleteOp height_key
            , insertOp BestBlockKey prev_block
            ]

-- | Get output ops for importing or removing transactions.
outputOps :: (MonadBlock m, MonadImport m) => OutPoint -> m [BatchOp]
outputOps out_point@OutPoint {..}
    | out_point == nullOutPoint = return []
    | otherwise = do
        net <- asks myNetwork
        output@Output {..} <-
            getOutput out_point >>= \case
                Nothing ->
                    throwString $
                    "Could not get output to unspend at outpoint: " <>
                    show out_point
                Just o -> return o
        let output_op = insertOp (OutputKey out_point) output
            addr_ops = addressOutOps net out_point output False
        return $ output_op : addr_ops

-- | Get address output ops when importing or removing transactions.
addressOutOps :: Network -> OutPoint -> Output -> Bool -> [BatchOp]
addressOutOps net out_point output@Output {..} del =
    case scriptToAddressBS net outScript of
        Nothing -> []
        Just a
            | del -> out_ops a
            | otherwise -> tx_op a : spender_ops a <> out_ops a
  where
    out_ops a =
        let key =
                AddrOutKey
                    { addrOutputAddress = a
                    , addrOutputHeight = blockRefHeight <$> outBlock
                    , addrOutputPos = blockRefPos <$> outBlock
                    , addrOutPoint = out_point
                    }
            mem = key {addrOutputHeight = Nothing, addrOutputPos = Nothing}
         in if isJust outSpender || del
                then [deleteOp mem, deleteOp key]
                else [deleteOp mem, insertOp key output]
    tx_op a =
        let tx_key =
                AddrTxKey
                    { addrTxKey = a
                    , addrTxHeight = blockRefHeight <$> outBlock
                    , addrTxPos = blockRefPos <$> outBlock
                    , addrTxHash = outPointHash out_point
                    }
         in insertOp tx_key ()
    spender_ops a =
        case outSpender of
            Nothing -> []
            Just Spender {..} ->
                let spender_key =
                        AddrTxKey
                            { addrTxKey = a
                            , addrTxHeight = blockRefHeight <$> spenderBlock
                            , addrTxPos = blockRefPos <$> spenderBlock
                            , addrTxHash = spenderHash
                            }
                 in [insertOp spender_key ()]


-- | Get ops for outputs to delete.
deleteOutOps :: (MonadBlock m, MonadImport m) => OutPoint -> m [BatchOp]
deleteOutOps out_point@OutPoint {..} = do
    net <- asks myNetwork
    output@Output {..} <-
        getOutput out_point >>= \case
            Nothing ->
                throwString $
                "Could not get output to delete at outpoint: " <> show out_point
            Just o -> return o
    let output_op = deleteOp (OutputKey out_point)
        addr_ops = addressOutOps net out_point output True
    return $ output_op : addr_ops

-- | Get ops for transactions to delete.
deleteTxOps :: TxHash -> [BatchOp]
deleteTxOps tx_hash =
    [ deleteOp (TxKey tx_hash)
    , deleteOp (MempoolKey tx_hash)
    , deleteOp (OrphanKey tx_hash)
    ]

-- | Purge all orphan transactions.
purgeOrphanOps :: (MonadBlock m, MonadImport m) => m [BatchOp]
purgeOrphanOps =
    fmap (fromMaybe []) . runMaybeT $ do
        db <- asks myBlockDB
        guard . isJust =<< gets blockAction
        liftIO . runResourceT . runConduit $
            matching db Nothing ShortOrphanKey .|
            mapC (\(k, Tx {}) -> deleteOp k) .|
            sinkList

-- | Get a transaction record from database.
getSimpleTx :: MonadBlock m => TxHash -> m TxRecord
getSimpleTx tx_hash =
    getTxRecord tx_hash >>= \case
        Nothing -> throwString $ "Cannot find tx hash: " <> show tx_hash
        Just r -> return r

-- | Get outpoints for a transaction.
getTxOutPoints :: Tx -> [OutPoint]
getTxOutPoints tx@Tx {..} =
    let tx_hash = txHash tx
    in [OutPoint tx_hash i | i <- take (length txOut) [0 ..]]

-- | Get previous outpoints from a transaction.
getPrevOutPoints :: Tx -> [OutPoint]
getPrevOutPoints Tx {..} = map prevOutput txIn

deleteAddrTxOps :: Network -> TxRecord -> [BatchOp]
deleteAddrTxOps net TxRecord {..} =
    let ias =
            mapMaybe
                (scriptToAddressBS net . prevOutScript . snd)
                txValuePrevOuts
        oas = mapMaybe (scriptToAddressBS net . scriptOutput) (txOut txValue)
     in map del_addr_tx (ias <> oas)
  where
    del_addr_tx a =
        deleteOp $
        AddrTxKey
            { addrTxKey = a
            , addrTxHeight = blockRefHeight <$> txValueBlock
            , addrTxPos = blockRefPos <$> txValueBlock
            , addrTxHash = txHash txValue
            }

-- | Get ops do delete transactions.
getDeleteTxOps :: (MonadBlock m, MonadImport m) => Network -> m [BatchOp]
getDeleteTxOps net = do
    del_txs <- S.toList <$> getDeleteTxs
    trs <- mapM getSimpleTx del_txs
    let txs = map txValue trs
    let prev_outs = concatMap getPrevOutPoints txs
        tx_outs = concatMap getTxOutPoints txs
        tx_ops = concatMap deleteTxOps del_txs
        addr_tx_ops = concatMap (deleteAddrTxOps net) trs
    prev_out_ops <- concat <$> mapM outputOps prev_outs
    tx_out_ops <- concat <$> mapM deleteOutOps tx_outs
    return $ prev_out_ops <> tx_out_ops <> tx_ops <> addr_tx_ops

-- | Get ops to insert transactions.
insertTxOps :: (MonadBlock m, MonadImport m) => ImportTx -> m [BatchOp]
insertTxOps ImportTx {..} = do
    prev_outputs <- get_prev_outputs
    let key = TxKey (txHash importTx)
        mempool_key = MempoolKey (txHash importTx)
        orphan_key = OrphanKey (txHash importTx)
        value =
            TxRecord
                { txValueBlock = importTxBlock
                , txValue = importTx
                , txValuePrevOuts = prev_outputs
                }
    case importTxBlock of
        Nothing ->
            return
                [ insertOp key value
                , insertOp mempool_key ()
                , deleteOp orphan_key
                ]
        Just _ ->
            return
                [insertOp key value, deleteOp mempool_key, deleteOp orphan_key]
  where
    get_prev_outputs =
        let real_inputs =
                filter ((/= nullOutPoint) . prevOutput) (txIn importTx)
         in forM real_inputs $ \TxIn {..} -> do
                Output {..} <-
                    getOutput prevOutput >>= \case
                        Nothing ->
                            throwString $
                            "While importing tx hash: " <>
                            cs (txHashToHex (txHash importTx)) <>
                            "could not get outpoint: " <>
                            showOutPoint prevOutput
                        Just out -> return out
                return
                    ( prevOutput
                    , PrevOut
                          { prevOutValue = outputValue
                          , prevOutBlock = outBlock
                          , prevOutScript = outScript
                          })

-- | Aggregate all transaction insert ops.
getInsertTxOps :: (MonadBlock m, MonadImport m) => m [BatchOp]
getInsertTxOps = do
    new_txs <- M.elems <$> gets newTxs
    let txs = map importTx new_txs
    let prev_outs = concatMap getPrevOutPoints txs
        tx_outs = concatMap getTxOutPoints txs
    prev_out_ops <- concat <$> mapM outputOps prev_outs
    tx_out_ops <- concat <$> mapM outputOps tx_outs
    tx_ops <- concat <$> mapM insertTxOps new_txs
    return $ prev_out_ops <> tx_out_ops <> tx_ops

-- | Aggregate all balance update ops.
getBalanceOps :: MonadImport m => m [BatchOp]
getBalanceOps = do
    address_map <- gets addressMap
    return $ map (uncurry (insertOp . BalanceKey)) (M.toList address_map)

-- | Revert best block.
revertBestBlock :: MonadBlock m => m ()
revertBestBlock = do
    net <- asks myNetwork
    db <- asks myBlockDB
    BlockValue {..} <- withSnapshot db $ getBestBlock db
    when (blockValueHeader == getGenesisHeader net) . throwString $
        "Attempted to revert genesis block"
    import_txs <- map txValue <$> mapM getSimpleTx (tail blockValueTxs)
    runMonadImport $ do
        mapM_ deleteTransaction blockValueTxs
        revertBlock
    reset_peer (blockValueHeight - 1)
    runMonadImport $ mapM_ (`importTransaction` Nothing) import_txs
  where
    reset_peer height = do
        base_height_box <- asks myBaseHeight
        peer_box <- asks myPeer
        atomically $ do
            writeTVar base_height_box height
            writeTVar peer_box Nothing

-- | Validate a transaction without script evaluation.
validateTx :: Monad m => OutputMap -> Tx -> ExceptT TxException m ()
validateTx outputs tx = do
    prev_outs <-
        forM (txIn tx) $ \TxIn {..} ->
            case M.lookup prevOutput outputs of
                Nothing -> throwError OrphanTx
                Just o  -> return o
    when (any (isJust . outSpender) prev_outs) (throwError DoubleSpend)
    let sum_inputs = sum (map outputValue prev_outs)
        sum_outputs = sum (map outValue (txOut tx))
    when (sum_outputs > sum_inputs) (throwError OverSpend)

-- | Import a transaction.
importTransaction ::
       (MonadBlock m, MonadImport m) => Tx -> Maybe BlockRef -> m Bool
importTransaction tx maybe_block_ref =
    runExceptT validate_tx >>= \case
        Left e -> do
            ret <-
                case e of
                    AlreadyImported ->
                        return True
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
            delete_spenders
            spend_inputs
            insert_outputs
            insertTx tx maybe_block_ref
            return True
  where
    import_orphan = do
        $(logInfoS) "BlockStore " $
            "Got orphan tx hash: " <> cs (txHashToHex (txHash tx))
        db <- asks myBlockDB
        R.insert db (OrphanKey (txHash tx)) tx
    validate_tx
        | isJust maybe_block_ref = return () -- only validate unconfirmed
        | otherwise = do
            getTxRecord (txHash tx) >>= \maybe_tx ->
                when (isJust maybe_tx) (throwError AlreadyImported)
            prev_outs <-
                fmap (M.fromList . catMaybes) . forM (txIn tx) $ \TxIn {..} ->
                    getOutput prevOutput >>= \case
                        Nothing -> return Nothing
                        Just o -> return $ Just (prevOutput, o)
            validateTx prev_outs tx
    delete_spenders =
        forM_ (txIn tx) $ \TxIn {..} ->
            getOutput prevOutput >>= \case
                Nothing ->
                    unless (prevOutput == nullOutPoint) . throwString $
                    "Could not get output spent by tx hash: " <>
                    show (txHash tx)
                Just Output {outSpender = Just Spender {..}} ->
                    deleteTransaction spenderHash
                _ -> return ()
    spend_inputs =
        forM_ (zip [0 ..] (txIn tx)) $ \(i, TxIn {..}) ->
            spendOutput
                prevOutput
                Spender
                    { spenderHash = txHash tx
                    , spenderIndex = i
                    , spenderBlock = maybe_block_ref
                    }
    insert_outputs =
        forM_ (zip [0 ..] (txOut tx)) $ \(i, TxOut {..}) ->
            addOutput
                OutPoint {outPointHash = txHash tx, outPointIndex = i}
                Output
                    { outputValue = outValue
                    , outBlock = maybe_block_ref
                    , outScript = scriptOutput
                    , outSpender = Nothing
                    }

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
        best_block <- withSnapshot db $ getBestBlock db
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
        best <- withSnapshot db $ getBestBlock db
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
                withSnapshot db (getBestBlock db)
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
    best <- asks myBlockDB >>= \db -> withSnapshot db $ getBestBlock db
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
                "Could not import from peer" <> pstr <> " block hash:" <>
                cs (blockHashToHex hash) <>
                " error: " <>
                fromString e
        Right () -> importOrphans >> syncBlocks >> syncMempool p

processBlockMessage (TxReceived _ tx) =
    isAtHeight >>= \x ->
        when x $ do
            _ <- runMonadImport $ importTransaction tx Nothing
            importOrphans

processBlockMessage (TxPublished tx) =
    void . runMonadImport $ importTransaction tx Nothing

processBlockMessage (BlockPeerDisconnect p) = do
    peer_box <- asks myPeer
    base_height_box <- asks myBaseHeight
    db <- asks myBlockDB
    best <- withSnapshot db $ getBestBlock db
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
        "Peer " <> pstr <> " unable to serve block hash: " <> cs (show h)
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
                            retrieve db Nothing (MempoolKey t) >>= \case
                                Nothing -> return Nothing
                                Just () -> return (Just t)
                        orp =
                            retrieve db Nothing (OrphanKey t) >>= \case
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
        "Pong received with nonce " <> cs (show n) <> " from peer " <> pstr
    asks myListener >>= atomically . ($ PeerPong p n)

-- | Import orphan transactions that can be imported.
importOrphans :: (MonadUnliftIO m, MonadBlock m) => m ()
importOrphans = do
    db <- asks myBlockDB
    ret <-
        runResourceT . runConduit $
        matching db Nothing ShortOrphanKey .| mapMC (import_tx . snd) .| anyC id
    when ret importOrphans
  where
    import_tx tx' = runMonadImport $ importTransaction tx' Nothing

getAddrTxs ::
       (MonadResource m, MonadUnliftIO m)
    => Network
    -> Address
    -> Maybe BlockHeight
    -> DB
    -> Snapshot
    -> ConduitT () DetailedTx m ()
getAddrTxs net a h db s =
    matchingSkip db (Just s) (ShortAddrTxKey a) (ShortAddrTxKeyHeight a h) .|
    concatMapMC f
  where
    f (AddrTxKey {..}, ()) = getTx net addrTxHash db s
    f _                    = throwString "Nonsense! This ship in unsinkable!"

-- | Get unspent outputs for an address.
getUnspent ::
       (MonadResource m, MonadUnliftIO m)
    => Address
    -> Maybe BlockHeight
    -> DB
    -> Snapshot
    -> ConduitT () AddrOutput m ()
getUnspent a h db s =
    getAddrUnspent a h db s .| mapC (uncurry AddrOutput)

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
    bb <- withSnapshot db $ getBestBlockHash db
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
