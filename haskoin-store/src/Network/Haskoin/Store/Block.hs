{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
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
    , getOutput
    ) where

import           Control.Applicative
import           Control.Arrow
import           Control.Concurrent.NQE
import           Control.Monad.Base
import           Control.Monad.Catch
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.Trans.Control
import           Control.Monad.Trans.Maybe
import qualified Data.ByteString              as BS
import           Data.Default
import           Data.List
import           Data.Map                     (Map)
import qualified Data.Map.Strict              as M
import           Data.Maybe
import           Data.Monoid
import           Data.Serialize               (encode)
import           Data.String.Conversions
import           Data.Text                    (Text)
import           Data.Word
import           Database.RocksDB             (DB, Snapshot)
import qualified Database.RocksDB             as RocksDB
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Crypto
import           Network.Haskoin.Node
import           Network.Haskoin.Script
import           Network.Haskoin.Store.Common
import           Network.Haskoin.Store.Types
import           Network.Haskoin.Transaction

data UnspentCache = UnspentCache
    { unspentCache       :: !PrevOutMap
    , unspentCacheBlocks :: !(Map BlockHeight [OutPoint])
    }

data BlockRead = BlockRead
    { myBlockDB      :: !DB
    , mySelf         :: !BlockStore
    , myChain        :: !Chain
    , myManager      :: !Manager
    , myListener     :: !(Listen BlockEvent)
    , myPending      :: !(TVar [BlockHash])
    , myDownloaded   :: !(TVar [Block])
    , myPeer         :: !(TVar (Maybe Peer))
    , myUnspentCache :: !(TVar UnspentCache)
    , myCacheNo      :: !Word32
    , myBlockNo      :: !Word32
    }

type MonadBlock m
     = ( MonadBase IO m
       , MonadThrow m
       , MonadBaseControl IO m
       , MonadLoggerIO m
       , MonadReader BlockRead m)

data AddressDelta = AddressDelta
    { addressDeltaOutput      :: !OutputMap
    , addressDeltaBalance     :: !Word64
    , addressDeltaTxCount     :: !Word64
    , addressDeltaOutputCount :: !Word64
    , addressDeltaSpentCount  :: !Word64
    } deriving (Show, Eq)

instance Monoid AddressDelta where
    mempty =
        AddressDelta
        { addressDeltaOutput = M.empty
        , addressDeltaBalance = 0
        , addressDeltaTxCount = 0
        , addressDeltaOutputCount = 0
        , addressDeltaSpentCount = 0
        }
    a `mappend` b =
        AddressDelta
        { addressDeltaOutput =
              addressDeltaOutput b `M.union` addressDeltaOutput a
        , addressDeltaBalance = addressDeltaBalance a + addressDeltaBalance b
        , addressDeltaTxCount = addressDeltaTxCount a + addressDeltaTxCount b
        , addressDeltaOutputCount =
              addressDeltaOutputCount a + addressDeltaOutputCount b
        , addressDeltaSpentCount =
              addressDeltaSpentCount a + addressDeltaSpentCount b
        }

type PrevOutMap = Map OutPoint PrevOut
type OutputMap = Map OutPoint Output
type AddressMap = Map Address AddressDelta

data BlockData = BlockData
    { blockPrevOutMap :: !PrevOutMap
    , blockAddrMap    :: !AddressMap
    , blockNewOutMap  :: !OutputMap
    } deriving (Show, Eq)

instance Monoid BlockData where
    mempty =
        BlockData
        { blockPrevOutMap = M.empty
        , blockAddrMap = M.empty
        , blockNewOutMap = M.empty
        }
    a `mappend` b =
        BlockData
        { blockPrevOutMap = M.union (blockPrevOutMap b) (blockPrevOutMap a)
        , blockAddrMap = M.unionWith (<>) (blockAddrMap a) (blockAddrMap b)
        , blockNewOutMap = M.union (blockNewOutMap b) (blockNewOutMap a)
        }

blockStore ::
       ( MonadBase IO m
       , MonadBaseControl IO m
       , MonadThrow m
       , MonadLoggerIO m
       , MonadMask m
       , Forall (Pure m)
       )
    => BlockConfig
    -> m ()
blockStore BlockConfig {..} = do
    pbox <- liftIO $ newTVarIO []
    dbox <- liftIO $ newTVarIO []
    ubox <-
        liftIO $
        newTVarIO
            UnspentCache {unspentCache = M.empty, unspentCacheBlocks = M.empty}
    peerbox <- liftIO $ newTVarIO Nothing
    runReaderT
        (loadBest >> syncBlocks >> run)
        BlockRead
        { mySelf = blockConfMailbox
        , myBlockDB = blockConfDB
        , myChain = blockConfChain
        , myManager = blockConfManager
        , myListener = blockConfListener
        , myPending = pbox
        , myDownloaded = dbox
        , myPeer = peerbox
        , myUnspentCache = ubox
        , myCacheNo = blockConfCacheNo
        , myBlockNo = blockConfBlockNo
        }
  where
    run = forever (processBlockMessage =<< receive blockConfMailbox)
    loadBest =
        retrieveValue BestBlockKey blockConfDB Nothing >>= \case
            Nothing -> importBlock genesisBlock
            Just _ -> return ()

getBestBlockHash :: MonadIO m => DB -> Maybe Snapshot -> m (Maybe BlockHash)
getBestBlockHash = retrieveValue BestBlockKey

getBestBlock :: MonadIO m => DB -> Maybe Snapshot -> m (Maybe BlockValue)
getBestBlock db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' =
        runMaybeT $ do
            h <- MaybeT (getBestBlockHash db s')
            MaybeT (getBlock h db s')

getBlocksAtHeights ::
    MonadIO m => [BlockHeight] -> DB -> Maybe Snapshot -> m [BlockValue]
getBlocksAtHeights bhs db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' =
        fmap catMaybes . forM (nub bhs) $ \bh ->
            getBlockAtHeight bh db s'

getBlockAtHeight ::
       MonadIO m => BlockHeight -> DB -> Maybe Snapshot -> m (Maybe BlockValue)
getBlockAtHeight height db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' =
        runMaybeT $ do
            h <- MaybeT (retrieveValue (HeightKey height) db s')
            MaybeT (retrieveValue (BlockKey h) db s')

getBlocks :: MonadIO m => [BlockHash] -> DB -> Maybe Snapshot -> m [BlockValue]
getBlocks bids db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' =
        fmap catMaybes . forM (nub bids) $ \bid -> getBlock bid db s'

getBlock ::
       MonadIO m => BlockHash -> DB -> Maybe Snapshot -> m (Maybe BlockValue)
getBlock = retrieveValue . BlockKey

getAddrsSpent ::
       MonadIO m
    => [Address]
    -> DB
    -> Maybe Snapshot
    -> m [(AddrOutputKey, Output)]
getAddrsSpent as db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' = concat <$> mapM (\a -> getAddrSpent a db s') (nub as)

getAddrSpent ::
       MonadIO m
    => Address
    -> DB
    -> Maybe Snapshot
    -> m [(AddrOutputKey, Output)]
getAddrSpent = valuesForKey . MultiAddrOutputKey True

getAddrsUnspent ::
       MonadIO m
    => [Address]
    -> DB
    -> Maybe Snapshot
    -> m [(AddrOutputKey, Output)]
getAddrsUnspent as db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' = concat <$> mapM (\a -> getAddrUnspent a db s') (nub as)

getAddrUnspent ::
       MonadIO m
    => Address
    -> DB
    -> Maybe Snapshot
    -> m [(AddrOutputKey, Output)]
getAddrUnspent = valuesForKey . MultiAddrOutputKey False

getOutput ::
       MonadIO m
    => OutPoint
    -> DB
    -> Maybe Snapshot
    -> m (Maybe Output)
getOutput = retrieveValue . OutputKey

getBalances ::
    MonadIO m => [Address] -> DB -> Maybe Snapshot -> m [AddressBalance]
getBalances addrs db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' = forM (nub addrs) $ \a -> getBalance a db s'

getBalance ::
       MonadIO m => Address -> DB -> Maybe Snapshot -> m AddressBalance
getBalance addr db s =
    retrieveValue (BalanceKey addr) db s >>= \case
        Just Balance {..} ->
            return
                AddressBalance
                { addressBalAddress = addr
                , addressBalConfirmed = balanceValue
                , addressBalTxCount = balanceTxCount
                , addressBalUnspentCount =
                      balanceOutputCount - balanceSpentCount
                , addressBalSpentCount = balanceSpentCount
                }
        Nothing ->
            return
                AddressBalance
                { addressBalAddress = addr
                , addressBalConfirmed = 0
                , addressBalTxCount = 0
                , addressBalUnspentCount = 0
                , addressBalSpentCount = 0
                }

getTxs :: MonadIO m => [TxHash] -> DB -> Maybe Snapshot -> m [DetailedTx]
getTxs ths db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' = fmap catMaybes . forM (nub ths) $ \th -> getTx th db s'

getTx ::
       MonadIO m => TxHash -> DB -> Maybe Snapshot -> m (Maybe DetailedTx)
getTx th db s =
    runMaybeT $ do
        xs <- valuesForKey (BaseTxKey th) db s
        TxRecord {..} <- MaybeT (return (findTx xs))
        let os = map (uncurry output) (filterOutputs xs)
            is = map (input txValuePrevOuts) (txIn txValue)
        return
            DetailedTx
            { detailedTxData = txValue
            , detailedTxFee = fee is os
            , detailedTxBlock = txValueBlock
            , detailedTxInputs = is
            , detailedTxOutputs = os
            , detailedTxPos = txPos
            }
  where
    fee is os =
        if any isCoinbase is
            then 0
            else sum (map detOutValue os) - sum (map detInValue is)
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
                    , detInPkScript = prevOutScript
                    , detInValue = prevOutValue
                    , detInBlock = prevOutBlock
                    , detInPos = prevOutPos
                    }
    output OutPoint {..} Output {..} =
        DetailedOutput
        { detOutValue = outputValue
        , detOutScript = outScript
        , detOutSpender = outSpender
        }
    findTx xs =
        listToMaybe
            [ t
            | (k, v) <- xs
            , case k of
                  MultiTxKey {} -> True
                  _             -> False
            , let MultiTx t = v
            ]
    filterOutputs xs =
        [ (p, o)
        | (k, v) <- xs
        , case (k, v) of
              (MultiTxKeyOutput {}, MultiTxOutput {}) -> True
              _                                       -> False
        , let MultiTxKeyOutput (OutputKey p) = k
        , let MultiTxOutput o = v
        ]
    e = error "Colud not locate previous output from transaction record"

revertBestBlock :: MonadBlock m => m ()
revertBestBlock =
    void . runMaybeT $ do
        db <- asks myBlockDB
        best <-
            getBestBlockHash db Nothing >>= me "Could not retrieve best block"
        guard (best /= headerHash genesisHeader)
        $(logWarn) $ logMe <> "Reverting block " <> logShow best
        ch <- asks myChain
        bn <- chainGetBlock best ch >>= me "Could not retrieve block from chain"
        BlockValue {..} <-
            getBlock best db Nothing >>= me "Could not retrieve best block"
        txs <- mapMaybe (fmap txValue) <$> getBlockTxs blockValueTxs db Nothing
        let block = Block blockValueHeader txs
        blockOps <- blockBatchOps block (nodeHeight bn) (nodeWork bn) False
        RocksDB.write db def blockOps
  where
    me msg Nothing = do
        $(logError) $ logMe <> cs msg
        error msg
    me _ (Just x) = return x

syncBlocks :: MonadBlock m => m ()
syncBlocks = do
    mgr <- asks myManager
    peerbox <- asks myPeer
    ch <- asks myChain
    chainBest <- chainGetBest ch
    let bestHash = headerHash (nodeHeader chainBest)
    db <- asks myBlockDB
    blockNo <- asks myBlockNo
    myBestHash <-
        getBestBlockHash db Nothing >>= me "Could not get best block hash"
    void . runMaybeT $ do
        guard (myBestHash /= bestHash)
        guard . null =<< liftIO . readTVarIO =<< asks myPending
        guard . null =<< liftIO . readTVarIO =<< asks myDownloaded
        p <-
            do maybePeer <- liftIO (readTVarIO peerbox)
               case maybePeer of
                   Just p -> return p
                   Nothing -> do
                       managerPeers <- managerGetPeers mgr
                       case managerPeers of
                           [] -> do
                               $(logWarn) $
                                   logMe <> "Could not find peer to sync blocks"
                               mzero
                           p':_ -> return p'
        liftIO . atomically $ writeTVar peerbox (Just p)
        myBest <-
            me "Colud not get my best block from chain" =<<
            chainGetBlock myBestHash ch
        splitBlock <- chainGetSplitBlock chainBest myBest ch
        revertUntil myBest splitBlock
        let chainHeight = nodeHeight chainBest
            splitHeight = nodeHeight splitBlock
            topHeight = min chainHeight (splitHeight + blockNo)
        targetBlock <-
            me "Could not get target block from chain" =<<
            if topHeight == chainHeight
                then return (Just chainBest)
                else chainGetAncestor topHeight chainBest ch
        requestBlocks <-
            (++ [targetBlock]) <$>
            chainGetParents (splitHeight + 1) targetBlock ch
        downloadBlocks p (map (headerHash . nodeHeader) requestBlocks)
  where
    me msg Nothing = do
        $(logError) $ logMe <> cs msg
        error msg
    me _ (Just x) = return x
    revertUntil myBest splitBlock
        | myBest == splitBlock = return ()
        | otherwise = do
            revertBestBlock
            db <- asks myBlockDB
            newBestHash <-
                getBestBlockHash db Nothing >>=
                me "Could not get best block hash"
            $(logWarn) $ logMe <> "Reverted to block " <> logShow newBestHash
            ch <- asks myChain
            newBest <- MaybeT (chainGetBlock newBestHash ch)
            revertUntil newBest splitBlock
    downloadBlocks p bhs = do
        $(logInfo) $
            logMe <> "Downloading " <> logShow (length bhs) <> " blocks"
        peerGetBlocks p bhs
        pbox <- asks myPending
        liftIO . atomically $ writeTVar pbox bhs

importBlocks :: MonadBlock m => m ()
importBlocks = do
    dbox <- asks myDownloaded
    pbox <- asks myPending
    db <- asks myBlockDB
    best <- getBestBlockHash db Nothing >>= me "Could not get block hash"
    m <-
        liftIO . atomically $ do
            ds <- readTVar dbox
            let (xs, ys) = partition ((== best) . prevBlock . blockHeader) ds
            case xs of
                [] -> do
                    readTVar pbox >>= \ps -> when (null ps) (writeTVar dbox [])
                    return Nothing
                b:_ -> do
                    writeTVar dbox (nub ys)
                    return (Just b)
    case m of
        Just block -> do
            importBlock block
            mbox <- asks mySelf
            BlockProcess `send` mbox
        Nothing -> syncBlocks
  where
    me msg Nothing = do
        $(logError) $ logMe <> cs msg
        error msg
    me _ (Just x) = return x

importBlock :: MonadBlock m => Block -> m ()
importBlock block@Block {..} = do
    ch <- asks myChain
    bn <-
        chainGetBlock blockHash ch >>= \case
            Just bn -> return bn
            Nothing -> do
                let msg = "Could not obtain block from chain"
                $(logError) $ logMe <> cs msg
                error msg
    ops <- blockBatchOps block (nodeHeight bn) (nodeWork bn) True
    db <- asks myBlockDB
    RocksDB.write db def ops
    $(logInfo) $
        logMe <> "Imported block " <> logShow (nodeHeight bn) <> " (" <>
        logShow (length ops) <>
        " database write operations)"
    l <- asks myListener
    liftIO . atomically . l $ BestBlock blockHash
    unspentCachePrune
  where
    blockHash = headerHash blockHeader

getBlockTxs ::
       MonadIO m => [TxHash] -> DB -> Maybe Snapshot -> m [Maybe TxRecord]
getBlockTxs hs db s = forM hs (\h -> retrieveValue (TxKey h) db s)

addrOutputOps :: Bool -> OutPoint -> Output -> [RocksDB.BatchOp]
addrOutputOps main op@OutPoint {..} out@Output {..} =
    if main
        then let prevDelMaybe = fmap deleteOp maybePrevKey
                 newInsMaybe = fmap (`insertOp` out) maybeKey
             in maybeToList prevDelMaybe ++ maybeToList newInsMaybe
        else let newDelMaybe = fmap deleteOp maybeKey
                 prevInsMaybe = fmap (`insertOp` unspent) maybePrevKey
             in maybeToList newDelMaybe ++ maybeToList prevInsMaybe
  where
    spentInSameBlock =
        case outSpender of
            Nothing -> False
            Just spender ->
                blockRefHash (spenderBlock spender) == blockRefHash outBlock
    unspent = out {outSpender = Nothing}
    maybeKey = do
        addr <- scriptToAddressBS outScript
        return
            AddrOutputKey
            { addrOutputSpent = isJust outSpender
            , addrOutputAddress = addr
            , addrOutputHeight = blockRefHeight outBlock
            , addrOutPoint = op
            }
    maybePrevKey = do
        addr <- scriptToAddressBS outScript
        guard (isJust outSpender)
        guard (not spentInSameBlock)
        return
            AddrOutputKey
            { addrOutputSpent = False
            , addrOutputAddress = addr
            , addrOutputHeight = blockRefHeight outBlock
            , addrOutPoint = op
            }

outputOps :: Bool -> OutPoint -> Output -> RocksDB.BatchOp
outputOps main op@OutPoint {..} v@Output {..}
    | main = insertOp (OutputKey op) v
    | otherwise =
        if spentInSameBlock
            then deleteOp (OutputKey op)
            else insertOp (OutputKey op) v {outSpender = Nothing}
  where
    spentInSameBlock =
        case outSpender of
            Nothing -> False
            Just spender ->
                blockRefHash (spenderBlock spender) == blockRefHash outBlock

balanceOps :: MonadBlock m => Bool -> AddressMap -> m [RocksDB.BatchOp]
balanceOps main addrMap =
    fmap concat . forM (M.toList addrMap) $ \(addr, AddressDelta {..}) -> do
        db <- asks myBlockDB
        maybeExisting <- retrieveValue (BalanceKey addr) db Nothing
        let key = BalanceKey {balanceAddress = addr}
            balance =
                case maybeExisting of
                    Nothing ->
                        Balance
                        { balanceValue = addressDeltaBalance
                        , balanceTxCount = addressDeltaTxCount
                        , balanceOutputCount = addressDeltaOutputCount
                        , balanceSpentCount = addressDeltaSpentCount
                        }
                    Just Balance {..} ->
                        Balance
                        { balanceValue = balanceValue + addressDeltaBalance
                        , balanceTxCount = balanceTxCount + addressDeltaTxCount
                        , balanceOutputCount =
                              balanceOutputCount + addressDeltaOutputCount
                        , balanceSpentCount =
                              balanceSpentCount + addressDeltaSpentCount
                        }
            maybeOldBalance =
                case maybeExisting of
                    Nothing -> Nothing
                    Just Balance {..} ->
                        let oldBalance =
                                Balance
                                { balanceValue =
                                      balanceValue - addressDeltaBalance
                                , balanceTxCount =
                                      balanceTxCount - addressDeltaTxCount
                                , balanceOutputCount =
                                      balanceOutputCount -
                                      addressDeltaOutputCount
                                , balanceSpentCount =
                                      balanceSpentCount - addressDeltaSpentCount
                                }
                            zeroBalance =
                                Balance
                                { balanceValue = 0
                                , balanceTxCount = 0
                                , balanceOutputCount = 0
                                , balanceSpentCount = 0
                                }
                            isZero = oldBalance == zeroBalance
                        in if isZero
                               then Nothing
                               else Just oldBalance
            balOps =
                if main
                    then [insertOp key balance]
                    else case maybeOldBalance of
                             Nothing  -> [deleteOp key]
                             Just old -> [insertOp key old]
            outputs = M.toList addressDeltaOutput
            outOps = concatMap (uncurry (addrOutputOps main)) outputs
        return (balOps ++ outOps)

blockOp ::
       MonadBlock m
    => Block
    -> BlockHeight
    -> BlockWork
    -> Bool
    -> BlockData
    -> m [RocksDB.BatchOp]
blockOp block height work main BlockData {..} = do
    addrops <- addrOps
    cache
    return $
        [blockHashOp, blockHeightOp, bestOp] <> concat [txOps, outOps, addrops]
  where
    header = blockHeader block
    hash = headerHash header
    blockRef =
        BlockRef
        {blockRefHash = hash, blockRefHeight = height, blockRefMainChain = main}
    txs = blockTxns block
    cache = do
        let entries = M.toList blockNewOutMap
        addToCache blockRef (map (second outputToPrevOut) entries)
    blockHashOp =
        let key = BlockKey (headerHash header)
            value =
                BlockValue
                { blockValueHeight = height
                , blockValueWork = work
                , blockValueHeader = header
                , blockValueSize = fromIntegral (BS.length (encode block))
                , blockValueMainChain = main
                , blockValueTxs = map txHash txs
                }
        in if main
               then insertOp key value
               else deleteOp key
    blockHeightOp =
        if main
            then let key = HeightKey height
                 in insertOp key (headerHash header)
            else let key = HeightKey height
                 in deleteOp key
    bestOp =
        if main
            then insertOp BestBlockKey (headerHash header)
            else insertOp BestBlockKey (prevBlock header)
    txOps =
        let outs = mapMaybe (\op -> (op, ) <$> op `M.lookup` blockPrevOutMap)
            f pos tx =
                insertOp
                    (TxKey (txHash tx))
                    TxRecord
                    { txValueBlock = blockRef
                    , txPos = pos
                    , txValue = tx
                    , txValuePrevOuts = outs (map prevOutput (txIn tx))
                    }
        in zipWith f [0 ..] txs
    outOps = map (uncurry (outputOps main)) (M.toList blockNewOutMap)
    addrOps = balanceOps main blockAddrMap

blockBatchOps ::
       MonadBlock m
    => Block
    -> BlockHeight
    -> BlockWork
    -> Bool
    -> m [RocksDB.BatchOp]
blockBatchOps block@Block {..} height work main = do
    let start =
            BlockData
            { blockPrevOutMap = M.empty
            , blockAddrMap = M.empty
            , blockNewOutMap = M.empty
            }
    bd <- foldM f start (zip [0 ..] blockTxns)
    blockOp block height work main bd
  where
    blockRef =
        BlockRef
        { blockRefHash = headerHash blockHeader
        , blockRefHeight = height
        , blockRefMainChain = main
        }
    f blockData (pos, tx) = do
        prevOutMap <- getPrevOutputs tx (blockPrevOutMap blockData)
        let spentOutMap = getSpentOutputs blockRef pos prevOutMap tx
            newOutMap = getNewOutputs blockRef pos tx
            outMap = spentOutMap <> newOutMap
            addrMap = getAddrDelta outMap
            txData =
                BlockData
                { blockPrevOutMap =
                      prevOutMap <> M.map outputToPrevOut newOutMap
                , blockNewOutMap = outMap
                , blockAddrMap = addrMap
                }
        return (blockData <> txData)

getAddrDelta :: OutputMap -> AddressMap
getAddrDelta outMap =
    M.fromList (map (id &&& addrDelta) addrs)
  where
    addrDelta addr =
        let xm = fromMaybe M.empty (M.lookup addr addrOutMap)
            om = M.filter (isNothing . outSpender) xm
            sm = M.filter (isJust . outSpender) xm
            ob = sum (map outputValue (M.elems om))
            sb = sum (map outputValue (M.elems sm))
        in AddressDelta
           { addressDeltaOutput = xm
           , addressDeltaBalance = fromIntegral ob - fromIntegral sb
           , addressDeltaTxCount = 1
           , addressDeltaOutputCount = fromIntegral (M.size om)
           , addressDeltaSpentCount = fromIntegral (M.size sm)
           }
    addrs = nub (M.keys addrOutMap)
    addrOutMap =
        M.fromListWith (<>) (mapMaybe (uncurry out) (M.toList outMap))
    out outpoint output@Output {..} = do
        address <- scriptToAddressBS outScript
        return (address, M.singleton outpoint output)

getSpentOutputs :: BlockRef -> Word32 -> PrevOutMap -> Tx -> OutputMap
getSpentOutputs block pos prevMap tx =
    M.fromList (mapMaybe f (zip [0 ..] (txIn tx)))
  where
    f (i, TxIn {..}) =
        if outPointHash prevOutput == zero
            then Nothing
            else let prev = fromMaybe e (prevOutput `M.lookup` prevMap)
                     spender =
                         Spender
                         { spenderHash = txHash tx
                         , spenderIndex = i
                         , spenderBlock = block
                         , spenderPos = pos
                         }
                     unspent = prevOutToOutput prev
                     spent = unspent {outSpender = Just spender}
                 in Just (prevOutput, spent)
    e = error "Could not find expcted previous output"

getNewOutputs :: BlockRef -> Word32 -> Tx -> OutputMap
getNewOutputs block pos tx = foldl' f M.empty (zip [0 ..] (txOut tx))
  where
    f m (i, TxOut {..}) =
        let key = OutPoint (txHash tx) i
            val =
                Output
                { outputValue = outValue
                , outBlock = block
                , outScript = scriptOutput
                , outPos = pos
                , outSpender = Nothing
                }
        in M.insert key val m

getPrevOutputs :: MonadBlock m => Tx -> PrevOutMap -> m PrevOutMap
getPrevOutputs tx prevOutMap = foldM f M.empty (map prevOutput (txIn tx))
  where
    f m outpoint@OutPoint {..} = do
        let key = outpoint
        maybeOutput <-
            if outPointHash == zero
                then return Nothing
                else do
                    maybeOutput <- getOutPointData key prevOutMap
                    case maybeOutput of
                        Just output -> return (Just output)
                        Nothing -> do
                            let msg = "Could not get previous output"
                            $(logError) $ logMe <> cs msg
                            error msg
        case maybeOutput of
            Nothing     -> return m
            Just output -> return (M.insert key output m)

getOutPointData ::
       MonadBlock m
    => OutPoint
    -> PrevOutMap
    -> m (Maybe PrevOut)
getOutPointData key os = runMaybeT (fromMap <|> fromCache <|> fromDB)
  where
    fromMap = MaybeT (return (M.lookup key os))
    fromDB = do
        db <- asks myBlockDB
        outputToPrevOut <$> MaybeT (retrieveValue (OutputKey key) db Nothing)
    fromCache = do
        guard . (/= 0) =<< asks myCacheNo
        ubox <- asks myUnspentCache
        cache@UnspentCache {..} <- liftIO $ readTVarIO ubox
        m <- MaybeT . return $ M.lookup key unspentCache
        liftIO . atomically $
            writeTVar ubox cache {unspentCache = M.delete key unspentCache}
        return m


unspentCachePrune :: MonadBlock m => m ()
unspentCachePrune =
    void . runMaybeT $ do
        n <- asks myCacheNo
        guard (n /= 0)
        ubox <- asks myUnspentCache
        cache <- liftIO (readTVarIO ubox)
        let new = clear (fromIntegral n) cache
            del = M.size (unspentCache cache) - M.size (unspentCache new)
        liftIO . atomically $ writeTVar ubox new
        when (del > 0) $
            $(logDebug) $
            logMe <> "Deleted " <> cs (show del) <> "/" <>
            cs (show (M.size (unspentCache cache))) <>
            " from UTXO cache"
  where
    clear n c@UnspentCache {..}
        | M.size unspentCache < n = c
        | otherwise =
            let (del, keep) = M.splitAt 1 unspentCacheBlocks
                ks =
                    [ k
                    | keys <- M.elems del
                    , k <- keys
                    , isJust (M.lookup k unspentCache)
                    ]
                cache = foldl' (flip M.delete) unspentCache ks
            in clear
                   n
                   UnspentCache
                   {unspentCache = cache, unspentCacheBlocks = keep}

addToCache :: MonadBlock m => BlockRef -> [(OutPoint, PrevOut)] -> m ()
addToCache BlockRef {..} xs = void . runMaybeT $ do
    guard . (/= 0) =<< asks myCacheNo
    ubox <- asks myUnspentCache
    UnspentCache {..} <- liftIO (readTVarIO ubox)
    let cache = foldl' (\c (k, v) -> M.insert k v c) unspentCache xs
        keys = map fst xs
        blocks = M.insertWith (++) blockRefHeight keys unspentCacheBlocks
    liftIO . atomically $
        writeTVar
            ubox
            UnspentCache
            { unspentCache = cache
            , unspentCacheBlocks = blocks
            }

processBlockMessage :: MonadBlock m => BlockMessage -> m ()

processBlockMessage (BlockChainNew _) = syncBlocks

processBlockMessage (BlockPeerConnect _) = syncBlocks

processBlockMessage (BlockReceived _p b) = do
    pbox <- asks myPending
    dbox <- asks myDownloaded
    let hash = headerHash (blockHeader b)
    liftIO . atomically $ do
        ps <- readTVar pbox
        when (hash `elem` ps) $ do
            modifyTVar dbox (b :)
            modifyTVar pbox (filter (/= hash))
    mbox <- asks mySelf
    db <- asks myBlockDB
    best <- fromMaybe e <$> getBestBlockHash db Nothing
    when (prevBlock (blockHeader b) == best) (BlockProcess `send` mbox)
  where
    e = error "Could not get best block from database"

processBlockMessage BlockProcess = importBlocks

processBlockMessage (BlockPeerDisconnect p) = purgePeer p

processBlockMessage (BlockNotReceived p h) = do
    $(logError) $ logMe <> "Block not found: " <> cs (show h)
    purgePeer p

purgePeer :: MonadBlock m => Peer -> m ()
purgePeer p = do
    peerbox <- asks myPeer
    pbox <- asks myPending
    mgr <- asks myManager
    purge <-
        liftIO . atomically $ do
            p' <- readTVar peerbox
            if Just p == p'
                then do
                    writeTVar peerbox Nothing
                    writeTVar pbox []
                    return True
                else return False
    when purge $ do
        $(logError) $ logMe <> "Syncing peer has been disconnected"
        managerKill (PeerMisbehaving "Peer purged from block store") p mgr
    mbox <- asks mySelf
    BlockProcess `send` mbox

getAddrTxs :: MonadIO m => Address -> DB -> Maybe Snapshot -> m [AddressTx]
getAddrTxs addr = getAddrsTxs [addr]

getAddrsTxs :: MonadIO m => [Address] -> DB -> Maybe Snapshot -> m [AddressTx]
getAddrsTxs addrs db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ g . Just
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
                , addressTxPos = outPos
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
                , addressTxPos = outPos
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
                , addressTxPos = spenderPos
                , addressTxVin = spenderIndex
                }
                | (AddrOutputKey {..}, Output {..}) <- ss
                , let Spender {..} = fromMaybe e outSpender
                ]
        return $ sort (itx ++ stx ++ utx)
    e = error "Could not get spender from spent output"

getUnspents :: MonadIO m => [Address] -> DB -> Maybe Snapshot -> m [Unspent]
getUnspents addrs db s =
    case s of
        Nothing -> RocksDB.withSnapshot db $ f . Just
        Just _  -> f s
  where
    f s' = fmap (sort . concat) $ forM addrs $ \addr -> getUnspent addr db s'

getUnspent :: MonadIO m => Address -> DB -> Maybe Snapshot -> m [Unspent]
getUnspent addr db s = do
    xs <- getAddrUnspent addr db s
    return $ map (uncurry toUnspent) xs
  where
    toUnspent AddrOutputKey {..} Output {..} =
        Unspent
        { unspentAddress = addrOutputAddress
        , unspentPkScript = outScript
        , unspentTxId = outPointHash addrOutPoint
        , unspentIndex = outPointIndex addrOutPoint
        , unspentValue = outputValue
        , unspentBlock = outBlock
        , unspentPos = outPos
        }

logMe :: Text
logMe = "[Block] "

zero :: TxHash
zero = "0000000000000000000000000000000000000000000000000000000000000000"
