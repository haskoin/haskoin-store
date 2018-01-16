{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE TemplateHaskell            #-}
module Network.Haskoin.Store.Block
( BlockConfig(..)
, BlockStore
, BlockEvent(..)
, BlockMessage(..)
, BlockValue(..)
, DetailedTx(..)
, SpentKey(..)
, SpentValue(..)
, TxValue(..)
, blockGetBest
, blockGetHeight
, blockGet
, blockGetTx
, blockStore
) where

import           Control.Applicative
import           Control.Concurrent.NQE
import           Control.Monad.Base
import           Control.Monad.Catch
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.Trans.Control
import           Control.Monad.Trans.Maybe
import           Data.Aeson
import           Data.ByteString              (ByteString)
import qualified Data.ByteString              as BS
import           Data.Conduit                 (($$))
import           Data.Conduit.List            (consume)
import           Data.Default
import           Data.Function
import           Data.List
import           Data.Map.Strict              (Map)
import qualified Data.Map.Strict              as M
import           Data.Maybe
import           Data.Monoid
import           Data.Serialize               as S
import           Data.String.Conversions
import           Data.Text                    (Text)
import           Data.Word
import           Database.LevelDB             (DB, MonadResource, runResourceT)
import qualified Database.LevelDB             as LevelDB
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Crypto
import           Network.Haskoin.Node
import           Network.Haskoin.Script
import           Network.Haskoin.Store.Common
import           Network.Haskoin.Transaction
import           Network.Haskoin.Util
import           System.Random

data BlockConfig = BlockConfig
    { blockConfDir      :: !FilePath
    , blockConfMailbox  :: !BlockStore
    , blockConfManager  :: !Manager
    , blockConfChain    :: !Chain
    , blockConfListener :: !(Listen BlockEvent)
    }

newtype BlockEvent = BestBlock BlockHash

data BlockMessage
    = BlockChainNew !BlockNode
    | BlockGetBest !(Reply BlockValue)
    | BlockGetHeight !BlockHeight !(Reply (Maybe BlockValue))
    | BlockPeerAvailable !Peer
    | BlockPeerConnect !Peer
    | BlockPeerDisconnect !Peer
    | BlockReceived !Peer !Block
    | BlockNotReceived !Peer !BlockHash
    | BlockGet !BlockHash
               (Reply (Maybe BlockValue))
    | BlockGetTx !TxHash !(Reply (Maybe DetailedTx))

type BlockStore = Inbox BlockMessage

type UnspentCache = (Map OutputKey OutputValue, Map BlockHeight [OutputKey])

data IndexOutKey = IndexOutKey
    { indexOutHash   :: !Hash256
    , indexOutHeight :: !BlockHeight
    , indexOutPoint  :: !OutPoint
    } deriving (Eq, Show)

data IndexOutValue = IndexOutValue
    { indexOutValue :: !Word64
    , indexOutSpent :: !SpentValue
    } deriving (Eq, Show)

data BlockRead = BlockRead
    { myBlockDB      :: !DB
    , mySelf         :: !BlockStore
    , myDir          :: !FilePath
    , myChain        :: !Chain
    , myManager      :: !Manager
    , myListener     :: !(Listen BlockEvent)
    , myPending      :: !(TVar [BlockHash])
    , myDownloaded   :: !(TVar [Block])
    , myPeer         :: !(TVar (Maybe Peer))
    , myUnspentCache :: !(TVar UnspentCache)
    }

data BlockValue = BlockValue
    { blockValueHeight    :: !BlockHeight
    , blockValueWork      :: !BlockWork
    , blockValueHeader    :: !BlockHeader
    , blockValueMainChain :: !Bool
    , blockValueTxs       :: ![TxHash]
    } deriving (Show, Eq)

data BlockRef = BlockRef
    { blockRefHash      :: !BlockHash
    , blockRefHeight    :: !BlockHeight
    , blockRefMainChain :: !Bool
    } deriving (Show, Eq)

data DetailedTx = DetailedTx
    { detailedTx      :: !Tx
    , detailedTxBlock :: !BlockRef
    , detailedTxSpent :: ![(SpentKey, SpentValue)]
    , detailedTxOuts  :: ![(OutPoint, OutputValue)]
    } deriving (Show, Eq)

data TxValue = TxValue
    { txValueBlock :: !BlockRef
    , txValue      :: !Tx
    , txValueOuts  :: [(OutPoint, OutputValue)]
    } deriving (Show, Eq)

newtype OutputKey = OutputKey
    { outPoint :: OutPoint
    } deriving (Show, Eq)

data OutputValue = OutputValue
    { outValue' :: !Word64
    , outBlock  :: !BlockRef
    , outScript :: !ByteString
    } deriving (Show, Eq)

newtype SpentKey = SpentKey
    { spentOutPoint :: OutPoint
    } deriving (Show, Eq)

data SpentValue = SpentValue
    { spentInHash  :: !TxHash
    , spentInIndex :: !Word32
    , spentInBlock :: !BlockRef
    } deriving (Show, Eq)

newtype BaseTxKey =
    BaseTxKey TxHash
    deriving (Show, Eq)

data MultiTxKey
    = MultiTxKey !TxKey
    | MultiTxKeyOutput !OutputKey
    | MultiTxKeySpent !SpentKey
    deriving (Show, Eq)

data MultiTxValue
    = MultiTx !TxValue
    | MultiTxOut !OutputValue
    | MultiTxSpent !SpentValue
    deriving (Show, Eq)

newtype TxKey =
    TxKey TxHash
    deriving (Show, Eq)

newtype BlockKey =
    BlockKey BlockHash
    deriving (Show, Eq)

newtype HeightKey =
    HeightKey BlockHeight
    deriving (Show, Eq)

data BestBlockKey = BestBlockKey deriving (Show, Eq)

instance Record BlockKey BlockValue
instance Record TxKey TxValue
instance Record HeightKey BlockHash
instance Record BestBlockKey BlockHash
instance Record OutputKey OutputValue
instance Record SpentKey SpentValue
instance Record MultiTxKey MultiTxValue
instance MultiRecord BaseTxKey MultiTxKey MultiTxValue

instance Ord OutputKey where
    compare = compare `on` f
      where
        f (OutputKey (OutPoint hash index)) = (hash, index)

instance Serialize MultiTxKey where
    put (MultiTxKey k)       = put k
    put (MultiTxKeyOutput k) = put k
    put (MultiTxKeySpent k)  = put k
    get =
        (MultiTxKey <$> get) <|> (MultiTxKeyOutput <$> get) <|>
        (MultiTxKeySpent <$> get)

instance Serialize MultiTxValue where
    put (MultiTx v)      = put v
    put (MultiTxOut v)   = put v
    put (MultiTxSpent v) = put v
    get = (MultiTx <$> get) <|> (MultiTxOut <$> get) <|> (MultiTxSpent <$> get)

instance Serialize BaseTxKey where
    put (BaseTxKey k) = do
        putWord8 0x02
        put k
    get = do
        guard . (== 0x02) =<< getWord8
        k <- get
        return (BaseTxKey k)

instance Serialize SpentKey where
    put SpentKey {..} = do
        putWord8 0x02
        put (outPointHash spentOutPoint)
        putWord8 0x01
        put (outPointIndex spentOutPoint)
        putWord8 0x01
    get = do
        guard . (== 0x02) =<< getWord8
        h <- get
        guard . (== 0x01) =<< getWord8
        i <- get
        guard . (== 0x01) =<< getWord8
        return (SpentKey (OutPoint h i))

instance Serialize SpentValue where
    put SpentValue {..} = do
        putWord8 0x02
        put spentInHash
        put spentInIndex
        put spentInBlock
    get = do
        guard . (== 0x02) =<< getWord8
        spentInHash <- get
        spentInIndex <- get
        spentInBlock <- get
        return SpentValue {..}

instance Serialize OutputKey where
    put OutputKey {..} = do
        putWord8 0x02
        put (outPointHash outPoint)
        putWord8 0x01
        put (outPointIndex outPoint)
        putWord8 0x00
    get = do
        guard . (== 0x02) =<< getWord8
        hash <- get
        guard . (== 0x01) =<< getWord8
        index <- get
        guard . (== 0x00) =<< getWord8
        let outPoint = OutPoint hash index
        return OutputKey {..}

instance Serialize OutputValue where
    put OutputValue {..} = do
        putWord8 0x01
        put outValue'
        put outBlock
        put outScript
    get = do
        guard . (== 0x01) =<< getWord8
        outValue' <- get
        outBlock <- get
        outScript <- get
        return OutputValue {..}

instance Serialize BlockRef where
    put (BlockRef hash height main) = do
        put hash
        put height
        put main
    get = do
        hash <- get
        height <- get
        main <- get
        return (BlockRef hash height main)

instance Serialize TxValue where
    put TxValue {..} = do
        putWord8 0x00
        put txValueBlock
        put txValue
        put txValueOuts
    get = do
        guard . (== 0x00) =<< getWord8
        txValueBlock <- get
        txValue <- get
        txValueOuts <- get
        return TxValue {..}

instance Serialize BestBlockKey where
    put BestBlockKey = put (BS.replicate 32 0x00)
    get = do
        guard . (== BS.replicate 32 0x00) =<< getBytes 32
        return BestBlockKey

instance Serialize BlockValue where
    put BlockValue {..} = do
        put blockValueHeight
        put blockValueWork
        put blockValueHeader
        put blockValueMainChain
        put blockValueTxs
    get = BlockValue <$> get <*> get <*> get <*> get <*> get

blockValuePairs :: KeyValue kv => BlockValue -> [kv]
blockValuePairs BlockValue {..} =
    [ "hash" .= headerHash blockValueHeader
    , "height" .= blockValueHeight
    , "mainchain" .= blockValueMainChain
    , "previous" .= prevBlock blockValueHeader
    , "timestamp" .= blockTimestamp blockValueHeader
    , "version" .= blockVersion blockValueHeader
    , "bits" .= blockBits blockValueHeader
    , "nonce" .= bhNonce blockValueHeader
    , "transactions" .= blockValueTxs
    ]

instance ToJSON BlockValue where
    toJSON = object . blockValuePairs
    toEncoding = pairs . mconcat . blockValuePairs

spentValuePairs :: KeyValue kv => SpentValue -> [kv]
spentValuePairs SpentValue {..} =
    [ "txid" .= spentInHash
    , "vin" .= spentInIndex
    , "block" .= spentInBlock
    ]

instance ToJSON SpentValue where
    toJSON = object . spentValuePairs
    toEncoding = pairs . mconcat . spentValuePairs

blockRefPairs :: KeyValue kv => BlockRef -> [kv]
blockRefPairs BlockRef {..} =
    [ "hash" .= blockRefHash
    , "height" .= blockRefHeight
    , "mainchain" .= blockRefMainChain
    ]

detailedTxPairs :: KeyValue kv => DetailedTx -> [kv]
detailedTxPairs DetailedTx {..} =
    [ "txid" .= hash
    , "block" .= detailedTxBlock
    , "size" .= BS.length (S.encode detailedTx)
    , "version" .= txVersion detailedTx
    , "locktime" .= txLockTime detailedTx
    , "vin" .= map input (txIn detailedTx)
    , "vout" .= zipWith output (txOut detailedTx) [0 ..]
    , "hex" .= detailedTx
    ]
  where
    hash = txHash detailedTx
    input TxIn {..} =
        object $
        [ "txid" .= outPointHash prevOutput
        , "vout" .= outPointIndex prevOutput
        , "coinbase" .= (outPointHash prevOutput == zero)
        , "sequence" .= txInSequence
        ] ++
        outInfo prevOutput
    output TxOut {..} i =
        object $
        [ "value" .= ((fromIntegral outValue :: Double) / 1e8)
        , "pkscript" .= String (cs (encodeHex scriptOutput))
        , "address" .=
          eitherToMaybe (decodeOutputBS scriptOutput >>= outputAddress)
        , "spent" .= isJust (spent i)
        ] ++
        ["input" .= s | s <- maybeToList (spent i)]
    zero = "0000000000000000000000000000000000000000000000000000000000000000"
    spent i = lookup (SpentKey (OutPoint hash i)) detailedTxSpent
    outInfo op@OutPoint {..} =
        concat
            [ x
            | OutputValue {..} <- maybeToList (op `lookup` detailedTxOuts)
            , let x =
                      [ "value" .= ((fromIntegral outValue' :: Double) / 1e8)
                      , "pkscript" .= String (cs (encodeHex outScript))
                      , "address" .=
                        eitherToMaybe
                            (decodeOutputBS outScript >>= outputAddress)
                      , "block" .= outBlock
                      ]
            ]

instance ToJSON DetailedTx where
    toJSON = object . detailedTxPairs
    toEncoding = pairs . mconcat . detailedTxPairs

instance ToJSON BlockRef where
    toJSON = object . blockRefPairs
    toEncoding = pairs . mconcat . blockRefPairs

instance Serialize HeightKey where
    put (HeightKey height) = do
        putWord8 0x03
        put (maxBound - height)
        put height
    get = do
        guard . (== 0x03) =<< getWord8
        iheight <- get
        return (HeightKey (maxBound - iheight))

instance Serialize BlockKey where
    put (BlockKey hash) = do
        putWord8 0x01
        put hash
    get = do
        guard . (== 0x01) =<< getWord8
        hash <- get
        return (BlockKey hash)

instance Serialize TxKey where
    put (TxKey hash) = do
        putWord8 0x02
        put hash
        putWord8 0x00
    get = do
        guard . (== 0x02) =<< getWord8
        hash <- get
        guard . (== 0x00) =<< getWord8
        return (TxKey hash)

type MonadBlock m
     = ( MonadBase IO m
       , MonadThrow m
       , MonadBaseControl IO m
       , MonadLoggerIO m
       , MonadReader BlockRead m
       , MonadResource m)

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
blockStore cfg =
    runResourceT $ do
        let opts = def {LevelDB.createIfMissing = True}
        db <- LevelDB.open (blockConfDir cfg) opts
        $(logDebug) $ logMe <> "Database opened"
        pbox <- liftIO $ newTVarIO []
        dbox <- liftIO $ newTVarIO []
        ubox <- liftIO $ newTVarIO (M.empty, M.empty)
        peerbox <- liftIO $ newTVarIO Nothing
        runReaderT
            (syncBlocks >> run)
            BlockRead
            { mySelf = blockConfMailbox cfg
            , myBlockDB = db
            , myDir = blockConfDir cfg
            , myChain = blockConfChain cfg
            , myManager = blockConfManager cfg
            , myListener = blockConfListener cfg
            , myPending = pbox
            , myDownloaded = dbox
            , myPeer = peerbox
            , myUnspentCache = ubox
            }
  where
    run =
        forever $ do
            $(logDebug) $ logMe <> "Awaiting message"
            msg <- receive $ blockConfMailbox cfg
            processBlockMessage msg

getBestBlockHash :: MonadBlock m => m BlockHash
getBestBlockHash = do
    $(logDebug) $ logMe <> "Processing best block request from database"
    db <- asks myBlockDB
    BestBlockKey `retrieveValue` db >>= \case
        Nothing -> do
            importBlock genesisBlock
            $(logDebug) $ logMe <> "Stored genesis"
            return (headerHash genesisHeader)
        Just bb -> return bb

getBlockAtHeight :: MonadBlock m => BlockHeight -> m (Maybe BlockValue)
getBlockAtHeight height = do
    $(logDebug) $
        logMe <> "Processing block request at height: " <> cs (show height)
    db <- asks myBlockDB
    runMaybeT $ do
        h <- MaybeT $ HeightKey height `retrieveValue` db
        MaybeT $ BlockKey h `retrieveValue` db

getBlockValue :: MonadBlock m => BlockHash -> m (Maybe BlockValue)
getBlockValue bh = do
    db <- asks myBlockDB
    BlockKey bh `retrieveValue` db

getStoredTx :: MonadBlock m => TxHash -> m (Maybe DetailedTx)
getStoredTx th =
    runMaybeT $ do
        db <- asks myBlockDB
        xs <- valuesForKey (BaseTxKey th) db $$ consume
        TxValue {..} <- MaybeT (return (findTx xs))
        let ss = filterSpents xs
        return (DetailedTx txValue txValueBlock ss txValueOuts)
  where
    findTx xs =
        listToMaybe
            [ v
            | (f, s) <- xs
            , case f of
                  MultiTxKey {} -> True
                  _             -> False
            , let MultiTx v = s
            ]
    filterSpents xs =
        [ (k, v)
        | (f, s) <- xs
        , case f of
              MultiTxKeySpent {} -> True
              _                  -> False
        , let MultiTxKeySpent k = f
        , let MultiTxSpent v = s
        ]

revertBestBlock :: MonadBlock m => m ()
revertBestBlock =
    void . runMaybeT $ do
        best <- getBestBlockHash
        guard (best /= headerHash genesisHeader)
        $(logDebug) $ logMe <> "Reverting block " <> logShow best
        ch <- asks myChain
        bn <-
            chainGetBlock best ch >>= \case
                Just bn -> return bn
                Nothing -> do
                    $(logError) $
                        logMe <> "Could not obtain best block from chain"
                    error "BUG: Could not obtain best block from chain"
        BlockValue {..} <-
            getBlockValue best >>= \case
                Just b -> return b
                Nothing -> do
                    $(logError) $ logMe <> "Could not retrieve best block"
                    error "BUG: Could not retrieve best block"
        txs <- mapMaybe (fmap txValue) <$> getBlockTxs blockValueTxs
        db <- asks myBlockDB
        let block = Block blockValueHeader txs
        blockOps <- blockBatchOps block (nodeHeight bn) (nodeWork bn) False
        LevelDB.write db def blockOps

syncBlocks :: MonadBlock m => m ()
syncBlocks = do
    mgr <- asks myManager
    peerbox <- asks myPeer
    pbox <- asks myPending
    ch <- asks myChain
    chainBest <- chainGetBest ch
    let bestHash = headerHash (nodeHeader chainBest)
    myBestHash <- getBestBlockHash
    void . runMaybeT $ do
        guard (myBestHash /= bestHash)
        liftIO (readTVarIO pbox) >>= guard . null
        myBest <- MaybeT (chainGetBlock myBestHash ch)
        splitBlock <- chainGetSplitBlock chainBest myBest ch
        let splitHash = headerHash (nodeHeader splitBlock)
        $(logDebug) $ logMe <> "Split block: " <> logShow splitHash
        revertUntil myBest splitBlock
        let chainHeight = nodeHeight chainBest
            splitHeight = nodeHeight splitBlock
            topHeight = min chainHeight (splitHeight + 501)
        targetBlock <-
            MaybeT $
            if topHeight == chainHeight
                then return (Just chainBest)
                else chainGetAncestor topHeight chainBest ch
        requestBlocks <-
            (++ [chainBest | targetBlock == chainBest]) <$>
            chainGetParents (splitHeight + 1) targetBlock ch
        p <-
            MaybeT (liftIO (readTVarIO peerbox)) <|>
            MaybeT (managerTakeAny False mgr)
        liftIO . atomically $ writeTVar peerbox (Just p)
        downloadBlocks p (map (headerHash . nodeHeader) requestBlocks)
  where
    revertUntil myBest splitBlock
        | myBest == splitBlock = return ()
        | otherwise = do
            revertBestBlock
            newBestHash <- getBestBlockHash
            $(logDebug) $ logMe <> "Reverted to block " <> logShow newBestHash
            ch <- asks myChain
            newBest <- MaybeT (chainGetBlock newBestHash ch)
            revertUntil newBest splitBlock
    downloadBlocks p bhs = do
        $(logDebug) $
            logMe <> "Downloading " <> logShow (length bhs) <> " blocks"
        getBlocks p bhs
        pbox <- asks myPending
        liftIO . atomically $ writeTVar pbox bhs

importBlocks :: MonadBlock m => m ()
importBlocks = do
    dbox <- asks myDownloaded
    best <- getBestBlockHash
    m <- liftIO . atomically $ do
        ds <- readTVar dbox
        case find ((== best) . prevBlock . blockHeader) ds of
            Nothing -> return Nothing
            Just b -> do
                modifyTVar dbox (filter (/= b))
                return (Just b)
    case m of
        Just block -> importBlock block >> importBlocks
        Nothing    -> syncBlocks

importBlock :: MonadBlock m => Block -> m ()
importBlock block@Block {..} = do
    $(logDebug) $ logMe <> "Importing block " <> logShow blockHash
    ch <- asks myChain
    bn <-
        chainGetBlock blockHash ch >>= \case
            Just bn -> return bn
            Nothing -> do
                $(logError) $ logMe <> "Could not obtain best block from chain"
                error "BUG: Could not obtain best block from chain"
    blockOps <- blockBatchOps block (nodeHeight bn) (nodeWork bn) True
    db <- asks myBlockDB
    LevelDB.write db def blockOps
    $(logDebug) $ logMe <> "Stored block " <> logShow (nodeHeight bn)
    l <- asks myListener
    liftIO . atomically . l $ BestBlock blockHash
  where
    blockHash = headerHash blockHeader

getBlockTxs :: MonadBlock m => [TxHash] -> m [Maybe TxValue]
getBlockTxs hs = do
    db <- asks myBlockDB
    forM hs (\h -> retrieveValue (TxKey h) db)

blockBatchOps :: MonadBlock m =>
       Block -> BlockHeight -> BlockWork -> Bool -> m [LevelDB.BatchOp]
blockBatchOps Block {..} height work main = do
    outputOps <- concat <$> mapM (outputBatchOps blockRef) blockTxns
    spentOps <- concat <$> mapM (spentBatchOps blockRef) blockTxns
    txOps <- mapM (txBatchOp blockRef blockTxns) blockTxns
    ubox <- asks myUnspentCache
    (cache, heights) <- liftIO (readTVarIO ubox)
    let del =
            concat . M.elems $
            M.filterWithKey
                (\k _ -> height > cacheNo && k <= height - cacheNo)
                heights
        heights' =
            M.filterWithKey
                (\k _ -> height < cacheNo || k > height - cacheNo)
                heights
        cache' = foldl' (flip M.delete) cache del
    liftIO . atomically $ writeTVar ubox (cache', heights')
    $(logDebug) $
        logMe <> "Deleted " <> cs (show (length del)) <> " entries from cache"
    return (blockOp : bestOp ++ heightOp ++ txOps ++ outputOps ++ spentOps)
  where
    cacheNo = 2500
    blockHash = headerHash blockHeader
    blockKey = BlockKey blockHash
    txHashes = map txHash blockTxns
    blockValue = BlockValue height work blockHeader main txHashes
    blockRef = BlockRef blockHash height main
    blockOp = insertOp blockKey blockValue
    bestOp = [insertOp BestBlockKey blockHash | main]
    heightKey = HeightKey height
    heightOp = [insertOp heightKey blockHash | main]

txBatchOp ::
       MonadBlock m
    => BlockRef
    -> [Tx]
    -> Tx
    -> m LevelDB.BatchOp
txBatchOp block txs tx = do
    os <-
        fmap catMaybes . forM (txIn tx) $ \TxIn {..} ->
            runMaybeT $ do
                guard (outPointHash prevOutput /= zero)
                val <-
                    fromCache prevOutput <|> fromDB prevOutput <|>
                    fromThisBlock prevOutput
                return (prevOutput, val)
    return $ insertOp (TxKey (txHash tx)) (TxValue block tx os)
  where
    fromCache op = do
        ubox <- asks myUnspentCache
        (cache, heights) <- liftIO $ readTVarIO ubox
        m <- MaybeT . return $ M.lookup (OutputKey op) cache
        $(logDebug) $
            logMe <> "Cache hit for output " <> cs (show (outPointHash op)) <>
            " " <>
            cs (show (outPointIndex op))
        liftIO . atomically $
            writeTVar ubox (M.delete (OutputKey op) cache, heights)
        return m
    fromDB op = do
        db <- asks myBlockDB
        $(logDebug) $
            logMe <> "Cache miss for output " <> cs (show (outPointHash op)) <>
            " " <>
            cs (show (outPointIndex op))
        MaybeT $ OutputKey op `retrieveValue` db
    fromThisBlock op = do
        tx' <- MaybeT . return $ find ((== outPointHash op) . txHash) txs
        let i = fromIntegral (outPointIndex op)
            TxOut {..} = txOut tx' !! i
            val = OutputValue outValue block scriptOutput
        return val
    zero = "0000000000000000000000000000000000000000000000000000000000000000"

outputBatchOps :: MonadBlock m => BlockRef -> Tx -> m [LevelDB.BatchOp]
outputBatchOps block tx = do
    let kvs = zipWith f (txOut tx) [0 ..]
    ubox <- asks myUnspentCache
    (cache, heights) <- liftIO (readTVarIO ubox)
    let cache' = foldl' (\c (k, v) -> M.insert k v c) cache kvs
        heights' =
            foldl'
                (\c (k, _) -> M.insertWith (++) (blockRefHeight block) [k] c)
                heights
                kvs
    liftIO . atomically $ writeTVar ubox (cache', heights')
    return $ map (uncurry insertOp) kvs
  where
    f TxOut {..} index =
        let key = OutputKey (OutPoint (txHash tx) index)
            value = OutputValue outValue block scriptOutput
        in (key, value)

spentBatchOps :: MonadBlock m => BlockRef -> Tx -> m [LevelDB.BatchOp]
spentBatchOps block tx =
    return $ zipWith f (txIn tx) [0..]
  where
    f TxIn {..} index = insertOp
        (SpentKey prevOutput) (SpentValue (txHash tx) index block)

processBlockMessage :: MonadBlock m => BlockMessage -> m ()

processBlockMessage (BlockChainNew bn) = do
    $(logDebug) $
        logMe <> "Got new block from chain actor: " <> logShow blockHash <>
        " at " <>
        logShow blockHeight
    syncBlocks
  where
    blockHash = headerHash $ nodeHeader bn
    blockHeight = nodeHeight bn

processBlockMessage (BlockGetHeight height reply) = do
    $(logDebug) $ logMe <> "Get new block at height " <> cs (show height)
    getBlockAtHeight height >>= liftIO . atomically . reply

processBlockMessage (BlockGetBest reply) = do
    $(logDebug) $ logMe <> "Got request for best block"
    h <- getBestBlockHash
    b <- fromMaybe e <$> getBlockValue h
    liftIO . atomically $ reply b
  where
    e = error "Could not get best block from database"

processBlockMessage (BlockPeerAvailable _) = do
    $(logDebug) $ logMe <> "A peer became available, syncing blocks"
    syncBlocks

processBlockMessage (BlockPeerConnect _) = do
    $(logDebug) $ logMe <> "A peer just connected, syncing blocks"
    syncBlocks

processBlockMessage (BlockGet bh reply) = do
    $(logDebug) $ logMe <> "Request to get block information"
    m <- getBlockValue bh
    liftIO . atomically $ reply m

processBlockMessage (BlockGetTx th reply) = do
    $(logDebug) $ logMe <> "Request to get transaction: " <> cs (txHashToHex th)
    m <- getStoredTx th
    liftIO . atomically $ reply m

processBlockMessage (BlockReceived _p b) = do
    $(logDebug) $ logMe <> "Received a block"
    pbox <- asks myPending
    dbox <- asks myDownloaded
    let hash = headerHash (blockHeader b)
    liftIO . atomically $ do
        ps <- readTVar pbox
        when (hash `elem` ps) $ do
            modifyTVar dbox (b :)
            modifyTVar pbox (filter (/= hash))
    importBlocks

processBlockMessage (BlockPeerDisconnect p) = do
    $(logDebug) $ logMe <> "A peer disconnected"
    purgePeer p

processBlockMessage (BlockNotReceived p h) = do
    $(logDebug) $ logMe <> "Block not found: " <> cs (show h)
    purgePeer p

purgePeer :: MonadBlock m => Peer -> m ()
purgePeer p = do
    peerbox <- asks myPeer
    pbox <- asks myPending
    dbox <- asks myDownloaded
    mgr <- asks myManager
    purge <-
        liftIO . atomically $ do
            p' <- readTVar peerbox
            if Just p == p'
                then do
                    writeTVar peerbox Nothing
                    writeTVar dbox []
                    writeTVar pbox []
                    return True
                else return False
    when purge $
        managerKill (PeerMisbehaving "Peer purged from block store") p mgr
    syncBlocks

blockGetBest :: (MonadBase IO m, MonadIO m) => BlockStore -> m BlockValue
blockGetBest b = BlockGetBest `query` b

blockGetTx :: (MonadBase IO m, MonadIO m) => TxHash -> BlockStore -> m (Maybe DetailedTx)
blockGetTx h b = BlockGetTx h `query` b

blockGet :: (MonadBase IO m, MonadIO m) => BlockHash -> BlockStore -> m (Maybe BlockValue)
blockGet h b = BlockGet h `query` b

blockGetHeight ::
       (MonadBase IO m, MonadIO m)
    => BlockHeight
    -> BlockStore
    -> m (Maybe BlockValue)
blockGetHeight h b = BlockGetHeight h `query` b

logMe :: Text
logMe = "[Block] "
