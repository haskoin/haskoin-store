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
      , getBlocksAtHeights
      , getBlockAtHeight
      , getBlock
      , getBlocks
      , getUnspent
      , getAddrOutputs
      , getAddrsOutputs
      , getBalance
      , getBalances
      , getTx
      , getTxs
      , getUnspents
      , getMempool
      ) where

import           Conduit
import           Control.Applicative
import           Control.Concurrent.NQE
import           Control.Monad.Except
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.State.Strict
import           Control.Monad.Trans.Maybe
import qualified Data.ByteString             as B
import           Data.Foldable
import           Data.Function
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
import qualified Database.RocksDB            as R
import           Database.RocksDB.Query      as R
import           Haskoin
import           Network.Haskoin.Node
import           Network.Haskoin.Store.Types
import           UnliftIO

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

type MonadBlock m
     = (MonadLoggerIO m, MonadReader BlockRead m)

type OutputMap = Map OutPoint Output
type AddressMap = Map Address Balance
type TxMap = Map TxHash ImportTx

data TxStatus
    = TxValid
    | TxOrphan
    | TxLowFunds
    | TxInputSpent
    deriving (Eq, Show, Ord)

data ImportTx = ImportTx
    { importTx      :: !Tx
    , importTxBlock :: !(Maybe BlockRef)
    }

data ImportState = ImportState
    { outputMap   :: !OutputMap
    , addressMap  :: !AddressMap
    , deleteTxs   :: !(Set TxHash)
    , newTxs      :: !TxMap
    , blockAction :: !(Maybe BlockAction)
    }

type MonadImport m = MonadState ImportState m

data BlockAction = RevertBlock | ImportBlock !Block

runMonadImport :: MonadBlock m => StateT ImportState m a -> m a
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
        ops <-
            concat <$> sequence
                [getBlockOps, getBalanceOps, getDeleteTxOps, getInsertTxOps]
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
            -- runConduit $
            --     matching blockConfDB Nothing OrphanKey .|
            --     mapM_C (\(k, Tx {}) -> remove blockConfDB k)
            retrieve blockConfDB Nothing BestBlockKey >>= \case
                Nothing -> addNewBlock (genesisBlock blockConfNet)
                Just (_ :: BlockHash) ->
                    getBestBlock blockConfDB Nothing >>= \BlockValue {..} -> do
                        base_height_box <- asks myBaseHeight
                        atomically $ writeTVar base_height_box blockValueHeight

getBestBlockHash :: MonadIO m => DB -> Maybe Snapshot -> m BlockHash
getBestBlockHash db snapshot =
    retrieve db snapshot BestBlockKey >>= \case
        Nothing -> throwString "Best block hash not available"
        Just bh -> return bh

getBestBlock :: MonadIO m => DB -> Maybe Snapshot -> m BlockValue
getBestBlock db s =
    case s of
        Nothing -> R.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' =
        getBestBlockHash db s' >>= \bh ->
            getBlock bh db s' >>= \case
                Nothing ->
                    throwString $
                    "Best block not available at hash: " <>
                    cs (blockHashToHex bh)
                Just b -> return b

getBlocksAtHeights ::
    MonadIO m => [BlockHeight] -> DB -> Maybe Snapshot -> m [BlockValue]
getBlocksAtHeights bhs db s =
    case s of
        Nothing -> R.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' =
        fmap catMaybes . forM (nub bhs) $ \bh ->
            getBlockAtHeight bh db s'

getBlockAtHeight ::
       MonadIO m => BlockHeight -> DB -> Maybe Snapshot -> m (Maybe BlockValue)
getBlockAtHeight height db s =
    case s of
        Nothing -> R.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' = retrieve db s' (HeightKey height) >>= \case
        Nothing -> return Nothing
        Just h -> retrieve db s' (BlockKey h)

getBlocks :: MonadIO m => [BlockHash] -> DB -> Maybe Snapshot -> m [BlockValue]
getBlocks bids db s =
    case s of
        Nothing -> R.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' =
        fmap catMaybes . forM (nub bids) $ \bid -> getBlock bid db s'

getBlock ::
       MonadIO m => BlockHash -> DB -> Maybe Snapshot -> m (Maybe BlockValue)
getBlock bh db snapshot = retrieve db snapshot (BlockKey bh)

getAddrSpent ::
       (MonadResource m, MonadUnliftIO m)
    => Address
    -> Maybe BlockHeight
    -> DB
    -> Maybe Snapshot
    -> ConduitT () (AddrOutputKey, Output) m ()
getAddrSpent addr h db snapshot =
    matchingSkip
        db
        snapshot
        (MultiAddrOutputKey True addr)
        (MultiAddrHeightKey True addr h)

getAddrUnspent ::
       (MonadUnliftIO m, MonadResource m)
    => Address
    -> Maybe BlockHeight
    -> DB
    -> Maybe Snapshot
    -> ConduitT () (AddrOutputKey, Output) m ()
getAddrUnspent addr h db snapshot =
    matchingSkip
        db
        snapshot
        (MultiAddrOutputKey False addr)
        (MultiAddrHeightKey False addr h)

getBalances ::
    MonadIO m => [Address] -> DB -> Maybe Snapshot -> m [AddressBalance]
getBalances addrs db s =
    case s of
        Nothing -> R.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' = forM (nub addrs) $ \a -> getBalance a db s'

getBalance ::
       MonadIO m => Address -> DB -> Maybe Snapshot -> m AddressBalance
getBalance addr db s =
    retrieve db s (BalanceKey addr) >>= \case
        Just Balance {..} ->
            return
                AddressBalance
                { addressBalAddress = addr
                , addressBalConfirmed = balanceValue
                , addressBalUnconfirmed = balanceUnconfirmed
                , addressOutputCount = balanceOutputCount
                , addressSpentCount = balanceSpentCount
                }
        Nothing ->
            return
                AddressBalance
                { addressBalAddress = addr
                , addressBalConfirmed = 0
                , addressBalUnconfirmed = 0
                , addressOutputCount = 0
                , addressSpentCount = 0
                }

getMempool :: MonadUnliftIO m => DB -> Maybe Snapshot -> m [TxHash]
getMempool db snapshot = get_hashes <$> matchingAsList db snapshot MempoolKey
  where
    get_hashes mempool_txs = [tx_hash | (MempoolTx tx_hash, ()) <- mempool_txs]

getTxs :: MonadUnliftIO m => Network -> [TxHash] -> DB -> Maybe Snapshot -> m [DetailedTx]
getTxs net ths db s =
    case s of
        Nothing -> R.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' = fmap catMaybes . forM (nub ths) $ \th -> getTx net th db s'

getTx ::
       MonadUnliftIO m => Network -> TxHash -> DB -> Maybe Snapshot -> m (Maybe DetailedTx)
getTx net th db s = do
    xs <- matchingAsList db s (BaseTxKey th)
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
              (MultiTxKeyOutput {}, MultiTxOutput {}) -> True
              _                                       -> False
        , let MultiTxKeyOutput (OutputKey p) = k
        , let MultiTxOutput o = v
        ]

getOutput :: (MonadBlock m, MonadImport m) => OutPoint -> m (Maybe Output)
getOutput out_point = runMaybeT $ MaybeT map_lookup <|> MaybeT db_lookup
  where
    map_lookup = M.lookup out_point <$> gets outputMap
    db_key = OutputKey out_point
    db_lookup = asks myBlockDB >>= \db -> retrieve db Nothing db_key

getAddress :: (MonadBlock m, MonadImport m) => Address -> m Balance
getAddress address =
    fromMaybe emptyBalance <$>
    runMaybeT (MaybeT map_lookup <|> MaybeT db_lookup)
  where
    map_lookup = M.lookup address <$> gets addressMap
    db_key = BalanceKey address
    db_lookup = asks myBlockDB >>= \db -> retrieve db Nothing db_key

getDeleteTxs :: MonadImport m => m (Set TxHash)
getDeleteTxs = gets deleteTxs

shouldDelete :: MonadImport m => TxHash -> m Bool
shouldDelete tx_hash = S.member tx_hash <$> getDeleteTxs

addBlock :: MonadImport m => Block -> m ()
addBlock block = modify $ \s -> s {blockAction = Just (ImportBlock block)}

revertBlock :: MonadImport m => m ()
revertBlock = modify $ \s -> s {blockAction = Just RevertBlock}

deleteTx :: MonadImport m => TxHash -> m ()
deleteTx tx_hash =
    modify $ \s -> s {deleteTxs = S.insert tx_hash (deleteTxs s)}

insertTx :: MonadImport m => Tx -> Maybe BlockRef -> m ()
insertTx tx maybe_block_ref =
    modify $ \s -> s {newTxs = M.insert (txHash tx) import_tx (newTxs s)}
  where
    import_tx = ImportTx {importTx = tx, importTxBlock = maybe_block_ref}

updateOutput :: MonadImport m => OutPoint -> Output -> m ()
updateOutput out_point output =
    modify $ \s -> s {outputMap = M.insert out_point output (outputMap s)}

updateAddress :: MonadImport m => Address -> Balance -> m ()
updateAddress address balance =
    modify $ \s -> s {addressMap = M.insert address balance (addressMap s)}

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
                     , balanceSpentCount = balanceSpentCount + 1
                     }
                else balance
                     { balanceUnconfirmed =
                           balanceUnconfirmed - fromIntegral outputValue
                     , balanceSpentCount = balanceSpentCount + 1
                     }

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
                     , balanceSpentCount = balanceSpentCount - 1
                     }
                else balance
                     { balanceUnconfirmed =
                           balanceUnconfirmed + fromIntegral outputValue
                     , balanceSpentCount = balanceSpentCount - 1
                     }

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
                             , balanceOutputCount = balanceOutputCount - 1
                             }
                    else balance
                             { balanceUnconfirmed =
                                   balanceUnconfirmed - fromIntegral outputValue
                             , balanceOutputCount = balanceOutputCount - 1
                             }

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
                             , balanceOutputCount = balanceOutputCount + 1
                             }
                    else balance
                             { balanceUnconfirmed =
                                   balanceUnconfirmed + fromIntegral outputValue
                             , balanceOutputCount = balanceOutputCount + 1
                             }

getTxRecord :: MonadBlock m => TxHash -> m (Maybe TxRecord)
getTxRecord tx_hash =
    asks myBlockDB >>= \db -> retrieve db Nothing (TxKey tx_hash)

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

addNewBlock :: MonadBlock m => Block -> m ()
addNewBlock block@Block {..} =
    runMonadImport $ do
        new_height <- get_new_height
        $(logInfoS) "Block" $
            "Importing block height: " <> cs (show new_height)
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
                best <- asks myBlockDB >>= \db -> getBestBlock db Nothing
                when (prev_block /= headerHash (blockValueHeader best)) .
                    throwString $
                    "Block does not build on best at hash: " <> show new_hash
                return $ blockValueHeight best + 1

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
        BlockValue {..} <- getBestBlock db Nothing
        let block_hash = headerHash blockValueHeader
            block_key = BlockKey block_hash
            height_key = HeightKey blockValueHeight
            prev_block = prevBlock blockValueHeader
        return
            [ deleteOp block_key
            , deleteOp height_key
            , insertOp BestBlockKey prev_block
            ]

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

addressOutOps :: Network -> OutPoint -> Output -> Bool -> [BatchOp]
addressOutOps net out_point output@Output {..} del =
    case scriptToAddressBS net outScript of
        Nothing -> []
        Just address ->
            let key =
                    AddrOutputKey
                    { addrOutputSpent = isJust outSpender
                    , addrOutputAddress = address
                    , addrOutputHeight = blockRefHeight <$> outBlock
                    , addrOutputPos = blockRefPos <$> outBlock
                    , addrOutPoint = out_point
                    }
                key_mempool = key {addrOutputHeight = Nothing}
                key_delete = key {addrOutputSpent = isNothing outSpender}
                key_delete_mempool = key_delete {addrOutputHeight = Nothing}
                op =
                    if del
                        then deleteOp key
                        else insertOp key output
            in if isJust outBlock
                   then [ op
                        , deleteOp key_delete
                        , deleteOp key_mempool
                        , deleteOp key_delete_mempool
                        ]
                   else [op, deleteOp key_delete]

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

deleteTxOps :: TxHash -> [BatchOp]
deleteTxOps tx_hash =
    [ deleteOp (TxKey tx_hash)
    , deleteOp (MempoolTx tx_hash)
    , deleteOp (OrphanTxKey tx_hash)
    ]

purgeOrphanOps :: (MonadBlock m, MonadImport m) => m [BatchOp]
purgeOrphanOps =
    fmap (fromMaybe []) . runMaybeT $ do
        db <- asks myBlockDB
        guard . isJust =<< gets blockAction
        liftIO . runResourceT . runConduit $
            matching db Nothing OrphanKey .| mapC (\(k, Tx {}) -> deleteOp k) .|
            sinkList


getSimpleTx :: MonadBlock m => TxHash -> m Tx
getSimpleTx tx_hash =
    getTxRecord tx_hash >>= \case
        Nothing -> throwString $ "Cannot find tx hash: " <> show tx_hash
        Just TxRecord {..} -> return txValue

getTxOutPoints :: Tx -> [OutPoint]
getTxOutPoints tx@Tx {..} =
    let tx_hash = txHash tx
    in [OutPoint tx_hash i | i <- take (length txOut) [0 ..]]

getPrevOutPoints :: Tx -> [OutPoint]
getPrevOutPoints Tx {..} = map prevOutput txIn

getDeleteTxOps :: (MonadBlock m, MonadImport m) => m [BatchOp]
getDeleteTxOps = do
    del_txs <- S.toList <$> getDeleteTxs
    txs <- mapM getSimpleTx del_txs
    let prev_outs = concatMap getPrevOutPoints txs
        tx_outs = concatMap getTxOutPoints txs
        tx_ops = concatMap deleteTxOps del_txs
    prev_out_ops <- concat <$> mapM outputOps prev_outs
    tx_out_ops <- concat <$> mapM deleteOutOps tx_outs
    return $ prev_out_ops <> tx_out_ops <> tx_ops

insertTxOps :: (MonadBlock m, MonadImport m) => ImportTx -> m [BatchOp]
insertTxOps ImportTx {..} = do
    prev_outputs <- get_prev_outputs
    let key = TxKey (txHash importTx)
        mempool_key = MempoolTx (txHash importTx)
        orphan_key = OrphanTxKey (txHash importTx)
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

getBalanceOps :: MonadImport m => m [BatchOp]
getBalanceOps = do
    address_map <- gets addressMap
    return $ map (uncurry (insertOp . BalanceKey)) (M.toList address_map)

revertBestBlock :: MonadBlock m => m ()
revertBestBlock = do
    net <- asks myNetwork
    db <- asks myBlockDB
    BlockValue {..} <- getBestBlock db Nothing
    when (blockValueHeader == getGenesisHeader net) . throwString $
        "Attempted to revert genesis block"
    import_txs <- mapM getSimpleTx (tail blockValueTxs)
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
        R.insert db (OrphanTxKey (txHash tx)) tx
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

syncBlocks :: MonadBlock m => m ()
syncBlocks =
    void . runMaybeT $ do
        net <- asks myNetwork
        chain_best <- asks myChain >>= chainGetBest
        revert_if_needed chain_best
        let chain_height = nodeHeight chain_best
        base_height_box <- asks myBaseHeight
        db <- asks myBlockDB
        best_block <- getBestBlock db Nothing
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
        best <- getBestBlock db Nothing
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
                headerHash . blockValueHeader <$> getBestBlock db Nothing
        when (best_hash /= split) $ do
            revertBestBlock
            revert_until split

importBlock :: (MonadError String m, MonadBlock m) => Block -> m ()
importBlock block@Block {..} = do
    bn <- asks myChain >>= chainGetBlock (headerHash blockHeader)
    when (isNothing bn) $
        throwString $
        "Not in chain: block hash" <>
        cs (blockHashToHex (headerHash blockHeader))
    best <- asks myBlockDB >>= \db -> getBestBlock db Nothing
    let best_hash = headerHash (blockValueHeader best)
        prev_hash = prevBlock blockHeader
    when (prev_hash /= best_hash) (throwError "does not build on best")
    addNewBlock block

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
    best <- getBestBlock db Nothing
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
                            retrieve db Nothing (MempoolTx t) >>= \case
                                Nothing -> return Nothing
                                Just () -> return (Just t)
                        orp =
                            retrieve db Nothing (OrphanTxKey t) >>= \case
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

importOrphans :: (MonadUnliftIO m, MonadBlock m) => m ()
importOrphans = do
    db <- asks myBlockDB
    ret <-
        runResourceT . runConduit $
        matching db Nothing OrphanKey .| mapMC (import_tx . snd) .| anyC id
    when ret importOrphans
  where
    import_tx tx' = runMonadImport $ importTransaction tx' Nothing

getAddrOutputs ::
       (MonadResource m, MonadUnliftIO m)
    => Address
    -> Maybe BlockHeight
    -> DB
    -> Maybe Snapshot
    -> ConduitT () AddrOutput m ()
getAddrOutputs a h db s =
    case s of
        Nothing -> R.withSnapshotBracket db $ f . Just
        Just _  -> f s
  where
    f s' = mergeSourcesBy (flip compare) [p s', u s']
    u s' = getAddrUnspent a h db s' .| mapC (uncurry AddrOutput)
    p s' = getAddrSpent a h db s' .| mapC (uncurry AddrOutput)


getAddrsOutputs ::
       (MonadResource m, MonadUnliftIO m)
    => [Address]
    -> Maybe BlockHeight
    -> DB
    -> Maybe Snapshot
    -> ConduitT () AddrOutput m ()
getAddrsOutputs as h db s =
    if isJust s
        then f s
        else R.withSnapshotBracket db $ \s' -> f (Just s')
  where
    f s' = forM_ as $ \a -> getAddrOutputs a h db s'

getUnspents ::
       (MonadResource m, MonadUnliftIO m)
    => [Address]
    -> Maybe BlockHeight
    -> DB
    -> Maybe Snapshot
    -> ConduitT () AddrOutput m ()
getUnspents as h db s =
    case s of
        Nothing -> R.withSnapshotBracket db $ f . Just
        Just _  -> f s
  where
    f s' = forM_ as $ \a -> getUnspent a h db s'

getUnspent ::
       (MonadResource m, MonadUnliftIO m)
    => Address
    -> Maybe BlockHeight
    -> DB
    -> Maybe Snapshot
    -> ConduitT () AddrOutput m ()
getUnspent addr h db s =
    getAddrUnspent addr h db s .| mapC (uncurry AddrOutput)

syncMempool :: MonadBlock m => Peer -> m ()
syncMempool p =
    void . runMaybeT $ do
        guard =<< isAtHeight
        $(logInfoS) "Block" "Syncing mempool..."
        MMempool `sendMessage` p

isAtHeight :: MonadBlock m => m Bool
isAtHeight = do
    db <- asks myBlockDB
    bb <- getBestBlockHash db Nothing
    ch <- asks myChain
    cb <- chainGetBest ch
    time <- liftIO getPOSIXTime
    let recent = floor time - blockTimestamp (nodeHeader cb) < 60 * 60 * 4
    return (recent && headerHash (nodeHeader cb) == bb)

zero :: TxHash
zero = "0000000000000000000000000000000000000000000000000000000000000000"

showOutPoint :: (IsString a, ConvertibleStrings Text a) => OutPoint -> a
showOutPoint OutPoint {..} =
    cs $ txHashToHex outPointHash <> ":" <> cs (show outPointIndex)

peerString :: (MonadBlock m, IsString a) => Peer -> m a
peerString p = do
    mgr <- asks myManager
    managerGetPeer mgr p >>= \case
        Nothing -> return "[unknown]"
        Just o -> return $ fromString $ show $ onlinePeerAddress o

-- | Merge multiple sorted sources into one sorted producer using specified
-- sorting function. Adapted from: <https://github.com/cblp/conduit-merge>
mergeSourcesBy ::
       (Foldable f, Monad m)
    => (a -> a -> Ordering)
    -> f (ConduitT () a m ())
    -> ConduitT i a m ()
mergeSourcesBy f = mergeSealed . fmap sealConduitT . toList
  where
    mergeSealed sources = do
        prefetchedSources <- lift $ traverse ($$++ await) sources
        go [(a, s) | (s, Just a) <- prefetchedSources]
    go [] = pure ()
    go sources = do
        let (a, src1):sources1 = sortBy (f `on` fst) sources
        yield a
        (src2, mb) <- lift $ src1 $$++ await
        let sources2 =
                case mb of
                    Nothing -> sources1
                    Just b  -> (b, src2) : sources1
        go sources2
