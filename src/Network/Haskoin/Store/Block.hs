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
    , getBlocksAtHeights
    , getBlockAtHeight
    , getBlock
    , getBlocks
    , getUnspent
    , getAddrTxs
    , getAddrsTxs
    , getBalance
    , getBalances
    , getTx
    , getTxs
    , getUnspents
    ) where

import           Control.Concurrent.NQE
import           Control.Monad.Except
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.State.Strict
import qualified Data.ByteString             as BS
import qualified Data.ByteString.Short       as BSS
import           Data.List
import           Data.Map                    (Map)
import qualified Data.Map.Strict             as M
import           Data.Maybe
import           Data.Serialize              (encode)
import           Data.Set                    (Set)
import qualified Data.Set                    as S
import           Data.String
import           Data.String.Conversions
import           Data.Word
import           Database.RocksDB            (DB, Snapshot)
import qualified Database.RocksDB            as R
import           Database.RocksDB.Query
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Crypto
import           Network.Haskoin.Node
import           Network.Haskoin.Script
import           Network.Haskoin.Store.Types
import           Network.Haskoin.Transaction
import           UnliftIO

data BlockRead = BlockRead
    { myBlockDB  :: !DB
    , mySelf     :: !BlockStore
    , myChain    :: !Chain
    , myManager  :: !Manager
    , myListener :: !(Listen BlockEvent)
    , myPending  :: !(TVar BlockHeight)
    , myPeer     :: !(TVar (Maybe Peer))
    }

type MonadBlock m
     = (MonadLoggerIO m, MonadReader BlockRead m)

type OutputMap = Map OutPoint Output
type AddressMap = Map Address Balance

data TxStatus
    = TxValid
    | TxOrphan
    | TxLowFunds
    | TxInputSpent
    deriving (Eq, Show, Ord)

data ImportState = ImportState { outputMap  :: !OutputMap
                               , addressMap :: !AddressMap
                               , deleteTxs  :: !(Set TxHash) }

type MonadImport m = MonadState ImportState m

runMonadImport :: Monad m => StateT ImportState m a -> m a
runMonadImport f =
    evalStateT
        f
        ImportState
        {outputMap = M.empty, addressMap = M.empty, deleteTxs = S.empty}

blockStore :: (MonadUnliftIO m, MonadLoggerIO m) => BlockConfig -> m ()
blockStore BlockConfig {..} = do
    pending_box <- liftIO (newTVarIO 0)
    peer_box <- liftIO (newTVarIO Nothing)
    runReaderT
        (load_best >> syncBlocks >> run)
        BlockRead
        { mySelf = blockConfMailbox
        , myBlockDB = blockConfDB
        , myChain = blockConfChain
        , myManager = blockConfManager
        , myListener = blockConfListener
        , myPending = pending_box
        , myPeer = peer_box
        }
  where
    run = forever (processBlockMessage =<< receive blockConfMailbox)
    load_best =
        retrieve blockConfDB Nothing BestBlockKey >>= \case
            Nothing -> addNewBlock genesisBlock
            Just (_ :: BlockHash) -> return ()

getBestBlockHash :: MonadIO m => DB -> Maybe Snapshot -> m BlockHash
getBestBlockHash db snapshot =
    retrieve db snapshot BestBlockKey >>= \case
        Nothing -> throwString "Best block hash should always be available"
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
                    throwString "Best block hash should always be availbale"
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

getAddrsSpent ::
       MonadUnliftIO m
    => [Address]
    -> DB
    -> Maybe Snapshot
    -> m [(AddrOutputKey, Output)]
getAddrsSpent as db s =
    case s of
        Nothing -> R.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' = concat <$> mapM (\a -> getAddrSpent a db s') (nub as)

getAddrSpent ::
       MonadUnliftIO m
    => Address
    -> DB
    -> Maybe Snapshot
    -> m [(AddrOutputKey, Output)]
getAddrSpent addr db snapshot =
    matchingAsList db snapshot (MultiAddrOutputKey True addr)

getAddrsUnspent ::
       MonadUnliftIO m
    => [Address]
    -> DB
    -> Maybe Snapshot
    -> m [(AddrOutputKey, Output)]
getAddrsUnspent as db s =
    case s of
        Nothing -> R.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' = concat <$> mapM (\a -> getAddrUnspent a db s') (nub as)

getAddrUnspent ::
       MonadUnliftIO m
    => Address
    -> DB
    -> Maybe Snapshot
    -> m [(AddrOutputKey, Output)]
getAddrUnspent addr db snapshot =
    matchingAsList db snapshot (MultiAddrOutputKey False addr)

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

getTxs :: MonadUnliftIO m => [TxHash] -> DB -> Maybe Snapshot -> m [DetailedTx]
getTxs ths db s =
    case s of
        Nothing -> R.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' = fmap catMaybes . forM (nub ths) $ \th -> getTx th db s'

getTx ::
       MonadUnliftIO m => TxHash -> DB -> Maybe Snapshot -> m (Maybe DetailedTx)
getTx th db s = do
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
                 }
            else let PrevOut {..} = fromMaybe e (lookup prevOutput prevs)
                 in DetailedInput
                    { detInOutPoint = prevOutput
                    , detInSequence = txInSequence
                    , detInSigScript = scriptInput
                    , detInPkScript = BSS.fromShort prevOutScript
                    , detInValue = prevOutValue
                    , detInBlock = prevOutBlock
                    }
    output OutPoint {..} Output {..} =
        DetailedOutput
        { detOutValue = outputValue
        , detOutScript = outScript
        , detOutSpender = outSpender
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
    e = error "Colud not locate previous output from transaction record"

txOutputMap ::
       MonadIO m => OutputMap -> Tx -> Maybe BlockRef -> DB -> Maybe Snapshot -> m OutputMap
txOutputMap om tx mb db s = do
    let is = filter (/= nullOutPoint) (map prevOutput (txIn tx))
    om' <- get_outpoints is
    return $ foldl f om' (zip [0 ..] (txOut tx))
  where
    f om' (i, o) =
        M.insert
            OutPoint {outPointHash = txHash tx, outPointIndex = i}
            Output
            { outputValue = outValue o
            , outBlock = mb
            , outScript = scriptOutput o
            , outSpender = Nothing
            }
            om'
    get_outpoints =
        let h om' op =
                g om' op >>= \case
                    Nothing -> return om'
                    Just o -> return $ M.insert op o om'
            g om' op =
                case M.lookup op om' of
                    Nothing -> retrieve db s (OutputKey op)
                    Just o  -> return (Just o)
        in foldM h om

addrBalance :: MonadIO m => Address -> DB -> Maybe Snapshot -> m (Maybe Balance)
addrBalance addr db snapshot = retrieve db snapshot (BalanceKey addr)

addrBalances ::
       MonadIO m
    => Set Address
    -> DB
    -> Maybe Snapshot
    -> m AddressMap
addrBalances as db s =
    fmap (M.fromList . catMaybes) . forM (S.toList as) $ \a ->
        addrBalance a db s >>= \case
            Nothing -> return Nothing
            Just b -> return $ Just (a, b)

deleteTransaction ::
       (MonadImport m, MonadLoggerIO m)
    => TxHash
    -> DB
    -> Maybe Snapshot
    -> m ()
    -- ^ updated maps and sets of transactions to delete
deleteTransaction th db snapshot =
    get_tx >>= \case
        Nothing -> return ()
        Just TxRecord {..} -> do
            let pos = filter (/= nullOutPoint) (map prevOutput (txIn txValue))
                conf = isJust txValueBlock
            forM_ pos $ \op -> do
                o <- get_output op
                put_output op (unspend_output o)
                case scriptToAddressBS (outScript o) of
                    Nothing -> return ()
                    Just a ->
                        get_balance a >>= put_balance a . unspend_balance conf o
            forM_ (zip [0 ..] (txOut txValue)) $ \(i, _) -> do
                let op = OutPoint th i
                o <- get_output op
                forM_ (outSpender o) delete_spender
                case scriptToAddressBS (outScript o) of
                    Nothing -> return ()
                    Just a -> get_balance a >>= put_balance a . remove_output o
            delete_tx
  where
    get_tx = retrieve db snapshot (TxKey th)
    get_output op = do
        ImportState {..} <- get
        mo <-
            case M.lookup op outputMap of
                Nothing -> retrieve db snapshot (OutputKey op)
                Just o  -> return (Just o)
        case mo of
            Nothing -> do
                $(logError) $ "Output not found: " <> logShow op
                error $ "Output not found: " <> show op
            Just o -> return o
    get_balance a = do
        ImportState {..} <- get
        bm <-
            case M.lookup a addressMap of
                Just b  -> return $ Just b
                Nothing -> retrieve db snapshot (BalanceKey a)
        case bm of
            Nothing -> do
                $(logError) $ "Balance not found: " <> logShow a
                error $ "Balance not found: " <> show a
            Just b -> return b
    put_output op o = modify $ \s -> s {outputMap = M.insert op o (outputMap s)}
    put_balance a b =
        modify $ \s -> s {addressMap = M.insert a b (addressMap s)}
    delete_tx = modify $ \s -> s {deleteTxs = S.insert th (deleteTxs s)}
    delete_spender spender = deleteTransaction (spenderHash spender) db snapshot
    unspend_output o = o {outSpender = Nothing}
    unspend_balance conf o b =
        if isJust (outBlock o) && conf
            then b
                 { balanceValue = balanceValue b + outputValue o
                 , balanceSpentCount = balanceSpentCount b - 1
                 }
            else b
                 { balanceUnconfirmed =
                       balanceUnconfirmed b + fromIntegral (outputValue o)
                 , balanceMempoolTxs = delete th (balanceMempoolTxs b)
                 }
    remove_output o b =
        case outBlock o of
            Nothing ->
                b
                { balanceUnconfirmed =
                      balanceUnconfirmed b - fromIntegral (outputValue o)
                , balanceMempoolTxs = delete th (balanceMempoolTxs b)
                }
            Just _ ->
                b
                { balanceValue = balanceValue b - outputValue o
                , balanceOutputCount = balanceOutputCount b - 1
                }

injectTransaction :: MonadImport m => Maybe BlockRef -> Tx -> m ()
injectTransaction br tx = do
    forM_ ins (uncurry fi)
    forM_ outs (uncurry fo)
  where
    fi i TxIn {..} = do
        o@Output {..} <- g prevOutput
        when
            (isJust outSpender)
            (error "You are in a maze of twisty little passages, all alike")
        upout
            prevOutput
            o
            { outSpender =
                  Just
                      Spender
                      { spenderHash = txHash tx
                      , spenderIndex = i
                      , spenderBlock = br
                      }
            }
        case scriptToAddressBS outScript of
            Nothing -> return ()
            Just a -> do
                c@Balance {..} <- b a
                case br of
                    Nothing ->
                        upbal
                            a
                            c
                            { balanceUnconfirmed =
                                  balanceUnconfirmed - fromIntegral outputValue
                            , balanceMempoolTxs = txHash tx : balanceMempoolTxs
                            }
                    Just _ -> do
                        when
                            (outputValue > balanceValue)
                            (error "Waste not, want not")
                        upbal
                            a
                            c
                            { balanceValue = balanceValue - outputValue
                            , balanceSpentCount = balanceSpentCount + 1
                            }
    fo i TxOut {..} = do
        Output {..} <- g OutPoint {outPointIndex = i, outPointHash = txHash tx}
        when (isJust outSpender) $
            error "I jumped off the aircraft with no parachute"
        case scriptToAddressBS outScript of
            Nothing -> return ()
            Just a -> do
                b'@Balance {..} <- b a
                case br of
                    Nothing ->
                        upbal
                            a
                            b'
                            { balanceUnconfirmed =
                                  balanceUnconfirmed + fromIntegral outputValue
                            , balanceMempoolTxs = txHash tx : balanceMempoolTxs
                            }
                    Just _ ->
                        upbal
                            a
                            b'
                            { balanceValue = balanceValue + outputValue
                            , balanceOutputCount = balanceOutputCount + 1
                            }
    outs = zip [0 ..] (txOut tx)
    ins = filter ((/= nullOutPoint) . prevOutput . snd) (zip [0 ..] (txIn tx))
    g op =
        fromMaybe (error "Don't feed the dwarves anything but coal") <$>
        gets (M.lookup op . outputMap)
    b a =
        gets (M.lookup a . addressMap) >>= \case
            Nothing ->
                return
                    Balance
                    { balanceValue = 0
                    , balanceUnconfirmed = 0
                    , balanceOutputCount = 0
                    , balanceSpentCount = 0
                    , balanceMempoolTxs = []
                    }
            Just b' -> return b'
    upout p o = modify $ \s -> s {outputMap = M.insert p o (outputMap s)}
    upbal a b' = modify $ \s -> s {addressMap = M.insert a b' (addressMap s)}

addNewBlock :: MonadBlock m => Block -> m ()
addNewBlock Block {..} = addNewTxs (Just blockHeader) blockTxns

addNewTxs ::
       MonadBlock m => Maybe BlockHeader -> [Tx] -> m ()
addNewTxs mbh txs =
    runMonadImport $ do
        mh <- get_height
        initOutputBalances ((,) <$> mbh <*> mh) txs
        unspend_outputs
        update_balances mh
        update_database
  where
    bref mh i = do
        bh <- mbh
        h <- mh
        return
            BlockRef
            { blockRefHash = headerHash bh
            , blockRefHeight = h
            , blockRefMainChain = True
            , blockRefPos = i
            }
    get_height =
        case mbh of
            Nothing -> return Nothing
            Just bh
                | bh == genesisHeader -> return (Just 0)
                | otherwise -> do
                    db <- asks myBlockDB
                    BlockValue {..} <- getBestBlock db Nothing
                    when
                        (headerHash blockValueHeader /= prevBlock bh)
                        (throwString "New block doesn't build on best")
                    return (Just (blockValueHeight + 1))
    unspend_outputs = do
        ImportState {..} <- get
        db <- asks myBlockDB
        let find_spender op = do
                o <- M.lookup op outputMap
                s <- outSpender o
                return (spenderHash s)
            prev_outputs Tx {..} = map prevOutput txIn
            delete_txs =
                S.fromList $ mapMaybe find_spender (concatMap prev_outputs txs)
        forM_ (S.toList delete_txs) $ \t -> deleteTransaction t db Nothing
    update_balances hm =
        forM_ (zip [0 ..] txs) $ \(i, t) -> injectTransaction (bref hm i) t
    update_database = do
        mbn <-
            case mbh of
                Nothing -> return Nothing
                Just bh -> do
                    ch <- asks myChain
                    chainGetBlock (headerHash bh) ch >>= \case
                        Nothing ->
                            throwString
                                "Block not found while importing transaction"
                        Just b -> return (Just b)
        ImportState{..} <- get
        ds <- catMaybes <$> mapM gtx (S.toList deleteTxs)
        let ops =
                concatMap (\tx -> getTxOps outputMap True tx Nothing) ds <>
                getBalanceOps addressMap <>
                case mbn of
                    Just bn ->
                        getBlockOps
                            outputMap
                            False
                            (nodeHeader bn)
                            (nodeWork bn)
                            (nodeHeight bn)
                            txs
                    Nothing ->
                        concatMap (\tx -> getTxOps outputMap False tx Nothing) txs
        db <- asks myBlockDB
        writeBatch db ops
    gtx h = do
        db <- asks myBlockDB
        fmap txValue <$> retrieve db Nothing (TxKey h)

getBlockOps ::
       OutputMap
    -> Bool
    -> BlockHeader
    -> BlockWork
    -> BlockHeight
    -> [Tx]
    -> [R.BatchOp]
getBlockOps om del bh bw bg txs = hop : gop : bop : tops
  where
    b = Block {blockHeader = bh, blockTxns = txs}
    hop =
        let k = BlockKey (headerHash bh)
            v =
                BlockValue
                { blockValueHeight = bg
                , blockValueWork = bw
                , blockValueHeader = bh
                , blockValueSize = fromIntegral (BS.length (encode b))
                , blockValueMainChain = True
                , blockValueTxs = map txHash txs
                }
        in if del
               then deleteOp k
               else insertOp k v
    gop =
        let k = HeightKey bg
            v = headerHash bh
        in if del
               then deleteOp k
               else insertOp k v
    bop =
        let k = BestBlockKey
            v = headerHash bh
            p = prevBlock bh
        in if del
               then insertOp k p
               else insertOp k v
    r i =
        Just
        BlockRef
        { blockRefHash = headerHash bh
        , blockRefHeight = bg
        , blockRefMainChain = True
        , blockRefPos = i
        }
    tops = concat $ zipWith (\i tx -> getTxOps om del tx (r i)) [0 ..] txs

getTxOps :: OutputMap -> Bool -> Tx -> Maybe BlockRef -> [R.BatchOp]
getTxOps om del tx br = tops <> pops <> oops <> aiops <> aoops
  where
    is = filter ((/= nullOutPoint) . prevOutput) (txIn tx)
    g p =
        fromMaybe
            (error "Transaction output expected but not provided")
            (M.lookup p om)
    prev Output {..} =
        PrevOut
        { prevOutValue = outputValue
        , prevOutBlock = outBlock
        , prevOutScript = BSS.toShort outScript
        }
    ps = map (\TxIn {..} -> (prevOutput, prev (g prevOutput))) is
    fo n =
        let p =
                OutPoint
                {outPointHash = txHash tx, outPointIndex = fromIntegral n}
            k = OutputKey {outPoint = p}
            v = g p
        in if del
               then deleteOp k
               else insertOp k v
    fp TxIn {prevOutput = p} =
        if del
            then deleteOp (OutputKey p)
            else insertOp (OutputKey p) (g p)
    tops =
        let k = TxKey (txHash tx)
            v = TxRecord {txValueBlock = br, txValue = tx, txValuePrevOuts = ps}
            mk = MempoolTx (txHash tx)
        in if isJust br
           then if del
                then [deleteOp k]
                else [insertOp k v]
           else if del
                then [deleteOp mk, deleteOp k]
                else [insertOp mk tx, insertOp k v]
    pops = map fp is
    oops = map fo [0 .. length (txOut tx) - 1]
    bh = blockRefHeight <$> br
    ai TxIn {prevOutput = p} =
        let k a =
                AddrOutputKey
                { addrOutputSpent = isJust (outSpender (g p))
                , addrOutputAddress = a
                , addrOutputHeight = blockRefHeight <$> outBlock (g p)
                , addrOutPoint = p
                }
        in case scriptToAddressBS (outScript (g p)) of
               Nothing -> []
               Just a ->
                   if del
                       then [ deleteOp
                                  (k a)
                                  { addrOutputSpent =
                                        not (addrOutputSpent (k a))
                                  }
                            , deleteOp (k a)
                            ]
                       else [ deleteOp
                                  (k a)
                                  { addrOutputSpent =
                                        not (addrOutputSpent (k a))
                                  }
                            , insertOp (k a) (g p)
                            ]
    ao n =
        let p =
                OutPoint
                {outPointHash = txHash tx, outPointIndex = fromIntegral n}
            k a =
                AddrOutputKey
                { addrOutputSpent = isJust (outSpender (g p))
                , addrOutputAddress = a
                , addrOutputHeight = bh
                , addrOutPoint = p
                }
        in case scriptToAddressBS (outScript (g p)) of
               Nothing -> []
               Just a ->
                   if del
                       then [ deleteOp
                                  (k a)
                                  { addrOutputSpent =
                                        not (addrOutputSpent (k a))
                                  }
                            , deleteOp (k a)
                            ]
                       else [ deleteOp
                                  (k a)
                                  { addrOutputSpent =
                                        not (addrOutputSpent (k a))
                                  }
                            , insertOp (k a) (g p)
                            ]
    aiops = concatMap ai (filter ((/= nullOutPoint) . prevOutput) (txIn tx))
    aoops = concatMap ao [0 .. length (txOut tx) - 1]

getBalanceOps :: AddressMap -> [R.BatchOp]
getBalanceOps am = map (\(a, b) -> insertOp (BalanceKey a) b) (M.toAscList am)

blockRef :: BlockHeader -> BlockHeight -> Word32 -> BlockRef
blockRef b h i =
    BlockRef
    { blockRefHash = headerHash b
    , blockRefHeight = h
    , blockRefMainChain = True
    , blockRefPos = i
    }

initOutputBalances ::
       (MonadImport m, MonadBlock m)
    => Maybe (BlockHeader, BlockHeight)
    -> [Tx]
    -> m ()
initOutputBalances mbh txs = do
    init_outputs
    init_balances
  where
    bref i = uncurry blockRef <$> mbh <*> pure i
    init_outputs = do
        db <- asks myBlockDB
        let f om' (i, t) = txOutputMap om' t (bref i) db Nothing
        s@ImportState {..} <- get
        om' <- foldM f outputMap (zip [0 ..] txs)
        put s {outputMap = om'}
    init_balances = do
        db <- asks myBlockDB
        s@ImportState {..} <- get
        let as =
                S.fromList . catMaybes $
                map (scriptToAddressBS . outScript) (M.elems outputMap)
        am <- addrBalances as db Nothing
        put s {addressMap = am}

revertBestBlock :: MonadBlock m => m ()
revertBestBlock = do
    db <- asks myBlockDB
    BlockValue {..} <- getBestBlock db Nothing
    when
        (blockValueHeader == genesisHeader)
        (error "Attempted to revert genesis block")
    $(logWarn) $ logMe <> "Reverting block " <> logShow blockValueHeight
    txs <- mapM gtx blockValueTxs
    runMonadImport $ do
        initOutputBalances (Just (blockValueHeader, blockValueHeight)) txs
        delete_txs blockValueTxs
        update_database blockValueHeader blockValueWork blockValueHeight txs
  where
    gtx h = do
        db <- asks myBlockDB
        retrieve db Nothing (TxKey h) >>= \case
            Nothing ->
                throwString "Colud not find transacion in block to revert"
            Just TxRecord {..} -> return txValue
    delete_txs ths =
        forM_ ths $ \t -> do
            db <- asks myBlockDB
            deleteTransaction t db Nothing
    update_database bh bw bg txs = do
        ImportState {..} <- get
        db <- asks myBlockDB
        let mhs = S.difference deleteTxs (S.fromList (map txHash txs))
        mts <- mapM gtx (S.toList mhs)
        let ops =
                concatMap (\tx -> getTxOps outputMap True tx Nothing) mts <>
                getBlockOps outputMap True bh bw bg txs <>
                getBalanceOps addressMap
        writeBatch db ops
        importMempool txs

-- TODO: do something about orphan transactions
importMempool :: MonadBlock m => [Tx] -> m ()
importMempool txs' = do
    db <- asks myBlockDB
    om <- foldM (\m t -> txOutputMap m t Nothing db Nothing) M.empty txs
    let tvs = map (\tx -> (tx, vtx om tx)) txs
        _os = map fst $ filter ((== TxOrphan) . snd) tvs
        vs = map fst $ filter ((== TxValid) . snd) tvs
    addNewTxs Nothing vs
  where
    txs = fo (S.fromList txs')
    vtx om tx = maximum [input_spent om tx, funds_low om tx]
    input_spent om tx =
        let t = maybe True (isNothing . outSpender)
            b = all (\i -> t (M.lookup (prevOutput i) om)) (ins tx)
        in if b
               then TxValid
               else TxInputSpent
    funds_low om tx =
        let f a i' = (+) <$> a <*> (outputValue <$> M.lookup (prevOutput i') om)
            i = foldl' f (Just 0) (ins tx)
            o = sum (map outValue (txOut tx))
        in case (>= o) <$> i of
               Nothing    -> TxOrphan
               Just True  -> TxValid
               Just False -> TxLowFunds
    ins tx = filter ((/= nullOutPoint) . prevOutput) (txIn tx)
    dep s t = any (flip S.member s . outPointHash . prevOutput) (txIn t)
    fo s | S.null s = []
         | otherwise =
           let (ds, ns) = S.partition (dep (S.map txHash s)) s
           in S.toList ns <> fo ds

syncBlocks :: MonadBlock m => m ()
syncBlocks =
    runExceptT sync >>= \case
        Left (Just l) -> $(logError) l
        _ -> return ()
  where
    sync = do
        ch <- asks myChain
        revert_until_in_chain
        chain_best <- chainGetBest ch
        best <- asks myBlockDB >>= \db -> getBestBlock db Nothing
        let best_hash = headerHash (blockValueHeader best)
            chain_hash = headerHash (nodeHeader chain_best)
        when (best_hash == chain_hash) (throwError Nothing) -- all done
        p <- get_peer (blockValueHeight best)
        pending <- asks myPending >>= readTVarIO
        sync_with_peer pending chain_best best p
    sync_with_peer pending chain_best best p = do
        ch <- asks myChain
        highest <-
            chainGetAncestor pending chain_best ch >>= \case
                Nothing ->
                    throwError
                        (Just "Could not get pending highest header from chain")
                Just b -> return b
        split <- chainGetSplitBlock chain_best highest ch
        when
            (nodeHeight split < blockValueHeight best)
            (revert_until (headerHash (nodeHeader split)))
        let sync_height = min (nodeHeight chain_best) (nodeHeight split + 500)
        pending_box <- asks myPending
        peer_box <- asks myPeer
        atomically $ do
            writeTVar pending_box sync_height
            writeTVar peer_box (Just p)
        target <-
            if sync_height == nodeHeight chain_best
                then return chain_best
                else chainGetAncestor sync_height chain_best ch >>= \case
                         Nothing ->
                             throwString
                                 "Could not get block ancestor from chain"
                         Just b -> return b
        pars <- chainGetParents (nodeHeight split + 1) target ch
        let blocks_to_get = map (headerHash . nodeHeader) (pars ++ [target])
        peerGetBlocks p blocks_to_get
    get_peer best_height = do
        peer_box <- asks myPeer
        pending <- asks myPending >>= readTVarIO
        when (best_height >= pending) (atomically (writeTVar peer_box Nothing))
        readTVarIO peer_box >>= \case
            Just p
                | pending >= best_height + 200 ->
                    (throwError Nothing) -- at least 200 blocks still pending
                | otherwise -> return p
            Nothing ->
                asks myManager >>= managerGetPeers >>= \case
                    [] -> throwError (Just "Could not get a peer to sync")
                    p:_ -> return p
    revert_until_in_chain = do
        best <- asks myBlockDB >>= \db -> getBestBlockHash db Nothing
        asks myChain >>= chainGetBlock best >>= \mb ->
            when (isNothing mb) $ do
                revertBestBlock
                revert_until_in_chain
    revert_until sb = do
        revertBestBlock
        bb <- asks myBlockDB >>= (`getBestBlockHash` Nothing)
        unless (bb == sb) (revert_until sb)

importBlock :: (MonadError String m, MonadBlock m) => Block -> m ()
importBlock block@Block {..} = do
    bn <-
        asks myChain >>= chainGetBlock (headerHash blockHeader) >>= \case
            Just bn -> return bn
            Nothing -> throwError "Could not obtain block from chain"
    best <- asks myBlockDB >>= (`getBestBlock` Nothing)
    let best_hash = headerHash (blockValueHeader best)
        prev_hash = prevBlock blockHeader
    unless
        (prev_hash == best_hash)
        (throwError "Block does not build on best")
    $(logInfo) $ logMe <> "Importing block " <> logShow (nodeHeight bn)
    addNewBlock block
    asks myListener >>= atomically . ($ BestBlock (headerHash blockHeader))

processBlockMessage :: MonadBlock m => BlockMessage -> m ()

processBlockMessage (BlockChainNew _) = syncBlocks

processBlockMessage (BlockPeerConnect _) = syncBlocks

processBlockMessage (BlockReceived p b) = do
    runExceptT (importBlock b) >>= \case
        Left e -> do
            let hash = headerHash (blockHeader b)
            $(logError) ("Could not import block " <> logShow hash)
            $(logError) (fromString e)
            asks myManager >>= managerKill (PeerMisbehaving e) p
        Right () -> return ()
    syncBlocks

processBlockMessage (BlockPeerDisconnect p) = do
    peer_box <- asks myPeer
    pending_box <- asks myPending
    best <- asks myBlockDB >>= (`getBestBlock` Nothing)
    atomically $
        readTVar peer_box >>= \x ->
            when (x == Just p) $ do
                writeTVar peer_box Nothing
                writeTVar pending_box (blockValueHeight best)
    syncBlocks

processBlockMessage (BlockNotReceived p h) = do
    $(logError) $ logMe <> "Block not found: " <> cs (show h)
    mgr <- asks myManager
    managerKill (PeerMisbehaving "Block not found") p mgr

processBlockMessage _ = return ()

getAddrTxs :: MonadUnliftIO m => Address -> DB -> Maybe Snapshot -> m [AddressTx]
getAddrTxs addr = getAddrsTxs [addr]

getAddrsTxs :: MonadUnliftIO m => [Address] -> DB -> Maybe Snapshot -> m [AddressTx]
getAddrsTxs addrs db s =
    case s of
        Nothing -> R.withSnapshot db $ g . Just
        Just _  -> g s
  where
    g s' = do
        us <- getAddrsUnspent addrs db s'
        ss <- getAddrsSpent addrs db s'
        let utx =
                [ AddressTxOut
                { addressTxAddress = addrOutputAddress
                , addressTxId = outPointHash addrOutPoint
                , addressTxAmount = fromIntegral outputValue
                , addressTxBlock = outBlock
                , addressTxVout = outPointIndex addrOutPoint
                }
                | (AddrOutputKey {..}, Output {..}) <- us
                ]
            stx =
                [ AddressTxOut
                { addressTxAddress = addrOutputAddress
                , addressTxId = outPointHash addrOutPoint
                , addressTxAmount = fromIntegral outputValue
                , addressTxBlock = outBlock
                , addressTxVout = outPointIndex addrOutPoint
                }
                | (AddrOutputKey {..}, Output {..}) <- ss
                ]
            itx =
                [ AddressTxIn
                { addressTxAddress = addrOutputAddress
                , addressTxId = spenderHash
                , addressTxAmount = -fromIntegral outputValue
                , addressTxBlock = spenderBlock
                , addressTxVin = spenderIndex
                }
                | (AddrOutputKey {..}, Output {..}) <- ss
                , let Spender {..} = fromMaybe e outSpender
                ]
        return $ sort (itx ++ stx ++ utx)
    e = error "Could not get spender from spent output"

getUnspents :: MonadUnliftIO m => [Address] -> DB -> Maybe Snapshot -> m [Unspent]
getUnspents addrs db s =
    case s of
        Nothing -> R.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' = fmap (sort . concat) $ forM addrs $ \addr -> getUnspent addr db s'

getUnspent :: MonadUnliftIO m => Address -> DB -> Maybe Snapshot -> m [Unspent]
getUnspent addr db s = do
    xs <- getAddrUnspent addr db s
    return $ map (uncurry to_unspent) xs
  where
    to_unspent AddrOutputKey {..} Output {..} =
        Unspent
        { unspentAddress = Just addrOutputAddress
        , unspentPkScript = outScript
        , unspentTxId = outPointHash addrOutPoint
        , unspentIndex = outPointIndex addrOutPoint
        , unspentValue = outputValue
        , unspentBlock = outBlock
        }
    to_unspent _ _ = error "Error decoding AddrOutputKey data structure"

logMe :: IsString a => a
logMe = "[Block] "

zero :: TxHash
zero = "0000000000000000000000000000000000000000000000000000000000000000"
