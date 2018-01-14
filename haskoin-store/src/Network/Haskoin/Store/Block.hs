{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TemplateHaskell       #-}
module Network.Haskoin.Store.Block
( BlockConfig(..)
, BlockStore
, BlockEvent(..)
, BlockMessage(..)
, BlockValue(..)
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
import qualified Data.ByteString              as BS
import           Data.Default
import           Data.List
import           Data.Maybe
import           Data.Monoid
import           Data.Serialize
import           Data.String.Conversions
import           Data.Text                    (Text)
import           Database.LevelDB             (DB, MonadResource, runResourceT)
import qualified Database.LevelDB             as LevelDB
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Node
import           Network.Haskoin.Store.Common
import           Network.Haskoin.Transaction

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
    | BlockGetTx !TxHash !(Reply (Maybe TxValue))

type BlockStore = Inbox BlockMessage

data BlockRead = BlockRead
    { myBlockDB    :: !DB
    , mySelf       :: !BlockStore
    , myDir        :: !FilePath
    , myChain      :: !Chain
    , myManager    :: !Manager
    , myListener   :: !(Listen BlockEvent)
    , myPending    :: !(TVar [BlockHash])
    , myDownloaded :: !(TVar [Block])
    , myPeer       :: !(TVar (Maybe Peer))
    }

data BlockValue = BlockValue
    { blockValueHeight :: !BlockHeight
    , blockValueWork   :: !BlockWork
    , blockValueHeader :: !BlockHeader
    , blockValueTxs    :: ![TxHash]
    } deriving (Show, Eq)

data TxValue = TxValue
    { txValueBlock :: !BlockHash
    , txValue      :: !Tx
    } deriving (Show, Eq)

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

instance Serialize TxValue where
    put (TxValue bhash tx) = do
        put bhash
        put tx
    get = do
        bhash <- get
        tx <- get
        return (TxValue bhash tx)

instance Serialize BestBlockKey where
    put BestBlockKey = put (BS.replicate 32 0x00)
    get = do
        bs <- getBytes 32
        guard (bs == BS.replicate 32 0x00)
        return BestBlockKey

instance Serialize BlockValue where
    put sb = do
        put (blockValueHeight sb)
        put (blockValueWork sb)
        put (blockValueHeader sb)
        put (blockValueTxs sb)
    get = BlockValue <$> get <*> get <*> get <*> get

blockValuePairs :: KeyValue kv => BlockValue -> [kv]
blockValuePairs BlockValue {..} =
    [ "hash" .= headerHash blockValueHeader
    , "height" .= blockValueHeight
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

txValuePairs :: KeyValue kv => TxValue -> [kv]
txValuePairs TxValue {..} =
    ["hash" .= txHash txValue, "tx" .= txValue, "block" .= txValueBlock]

instance ToJSON TxValue where
    toJSON = object . txValuePairs
    toEncoding = pairs . mconcat . txValuePairs

instance Serialize HeightKey where
    put (HeightKey height) = do
        putWord8 0x03
        put (maxBound - height)
        put height
    get = do
        k <- getWord8
        guard (k == 0x03)
        iheight <- get
        return (HeightKey (maxBound - iheight))

instance Serialize BlockKey where
    put (BlockKey hash) = do
        putWord8 0x01
        put hash
    get = do
        w <- getWord8
        guard (w == 0x01)
        hash <- get
        return (BlockKey hash)

instance Serialize TxKey where
    put (TxKey hash) = do
        putWord8 0x02
        put hash
    get = do
        w <- getWord8
        guard (w == 0x02)
        hash <- get
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

getStoredTx :: MonadBlock m => TxHash -> m (Maybe TxValue)
getStoredTx th = do
    db <- asks myBlockDB
    TxKey th `retrieveValue` db

revertBestBlock :: MonadBlock m => m ()
revertBestBlock =
    void . runMaybeT $ do
        best <- getBestBlockHash
        guard (best /= headerHash genesisHeader)
        $(logDebug) $ logMe <> "Reverting block " <> logShow best
        sb <-
            getBlockValue best >>= \case
                Just b -> return b
                Nothing -> do
                    $(logError) $ logMe <> "Could not retrieve best block"
                    error "BUG: Could not retrieve best block"
        db <- asks myBlockDB
        insertRecord BestBlockKey (prevBlock (blockValueHeader sb)) db

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
importBlock block = do
    $(logDebug) $ logMe <> "Importing block " <> logShow blockHash
    when (blockHash /= headerHash genesisHeader) $ do
        best <- getBestBlockHash
        when (prevBlock (blockHeader block) /= best) $ do
            $(logError) "Cannot import block not building on best"
            error "BUG: Cannot import block not building on best"
    ch <- asks myChain
    blockNode <-
        chainGetBlock blockHash ch >>= \case
            Just bn -> return bn
            Nothing -> do
                $(logError) "Could not obtain best block from chain"
                error "BUG: Could not obtain best block from chain"
    db <- asks myBlockDB
    let blockValue =
            BlockValue
            { blockValueHeight = nodeHeight blockNode
            , blockValueWork = nodeWork blockNode
            , blockValueHeader = nodeHeader blockNode
            , blockValueTxs = map txHash (blockTxns block)
            }
        blockKey = BlockKey blockHash
        blockOp = insertOp blockKey blockValue
        blockHeightKey = HeightKey (nodeHeight blockNode)
        blockHeightOp = insertOp blockHeightKey blockHash
        bestBlockOp = insertOp BestBlockKey blockHash
        batch = [blockOp, blockHeightOp, bestBlockOp] ++ txOps
    LevelDB.write db def batch
    $(logDebug) $ logMe <> "Stored block " <> logShow (nodeHeight blockNode)
    l <- asks myListener
    liftIO . atomically . l $ BestBlock blockHash
  where
    blockHash = headerHash $ blockHeader block
    txOps = zipWith insertOp txKeys txValues
    txKeys = map (TxKey . txHash) (blockTxns block)
    txValues = map (TxValue blockHash) (blockTxns block)

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

blockGetTx :: (MonadBase IO m, MonadIO m) => TxHash -> BlockStore -> m (Maybe TxValue)
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
