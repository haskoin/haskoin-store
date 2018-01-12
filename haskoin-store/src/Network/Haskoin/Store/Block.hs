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
, blockGetBest
, blockGet
, blockGetTxs
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
import           Data.Conduit
import           Data.Conduit.List            (consume)
import           Data.Default
import           Data.List
import           Data.Monoid
import           Data.Serialize
import           Data.String.Conversions
import           Data.Text                    (Text)
import           Data.Time.Clock.POSIX
import           Data.Word
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
    | BlockGetBest !(Reply BlockHash)
    | BlockPeerAvailable !Peer
    | BlockPeerConnect !Peer
    | BlockPeerDisconnect !Peer
    | BlockReceived !Peer !Block
    | BlockNotReceived !Peer !BlockHash
    | BlockGetTxs !BlockHash
                  !(Reply (Maybe (BlockValue, [Tx])))
    | BlockGet !BlockHash
               (Reply (Maybe BlockValue))
    | BlockGetTx !TxHash !(Reply (Maybe Tx))

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

newtype TxKey =
    TxKey TxHash
    deriving (Show, Eq)

newtype BlockKey =
    BlockKey BlockHash
    deriving (Show, Eq)

newtype BlockHeightKey =
    BlockHeightKey BlockHeight
    deriving (Show, Eq)

newtype BlockTxMultiKey =
    BlockTxMultiKey BlockHash
    deriving (Show, Eq)

data BlockTxKey =
    BlockTxKey !BlockHash
               !Word32
    deriving (Show, Eq)

data BestBlockKey = BestBlockKey deriving (Show, Eq)

instance Record BlockKey BlockValue
instance Record TxKey BlockTxKey
instance Record BlockTxKey Tx
instance Record BlockHeightKey BlockHash
instance Record BestBlockKey BlockHash
instance MultiRecord BlockTxMultiKey BlockTxKey Tx

instance Serialize BlockTxMultiKey where
    put (BlockTxMultiKey hash) = do
        putWord8 0x04
        put hash
    get = do
        w <- getWord8
        guard (w == 0x04)
        hash <- get
        return (BlockTxMultiKey hash)

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

instance Serialize BlockHeightKey where
    put (BlockHeightKey height) = do
        putWord8 0x03
        put (maxBound - height)
        put height
    get = do
        k <- getWord8
        guard (k == 0x03)
        iheight <- get
        return (BlockHeightKey (maxBound - iheight))

instance Serialize BlockKey where
    put (BlockKey hash) = do
        putWord8 0x01
        put hash
    get = do
        w <- getWord8
        guard (w == 0x01)
        hash <- get
        return (BlockKey hash)

instance Serialize BlockTxKey where
    put (BlockTxKey hash pos) = do
        putWord8 0x04
        put hash
        put pos
    get = do
        getWord8 >>= guard . (== 0x04)
        bh <- get
        pos <- get
        return (BlockTxKey bh pos)

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

getBlockValue :: MonadBlock m => BlockHash -> m (Maybe BlockValue)
getBlockValue bh = do
    db <- asks myBlockDB
    BlockKey bh `retrieveValue` db

getStoredTx :: MonadBlock m => TxHash -> m (Maybe Tx)
getStoredTx th =
    runMaybeT $ do
        db <- asks myBlockDB
        k <- MaybeT (TxKey th `retrieveValue` db)
        MaybeT (k `retrieveValue` db)

getBlockTxs :: MonadBlock m => BlockHash -> m (Maybe (BlockValue, [Tx]))
getBlockTxs hash =
    runMaybeT $ do
        db <- asks myBlockDB
        b <- MaybeT (BlockKey hash `retrieveValue` db)
        $(logDebug) $
            logMe <> "Retrieving block transactions for block " <>
            logShow (blockValueHeight b)
        ts <- BlockTxMultiKey hash `valuesForKey` db $$ consume
        return (b, map snd ts)

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
        blockHeightKey = BlockHeightKey (nodeHeight blockNode)
        blockHeightOp = insertOp blockHeightKey blockHash
        bestBlockOp = insertOp BestBlockKey blockHash
        batch = [blockOp, blockHeightOp, bestBlockOp] ++ txOps ++ txBlockOps
    LevelDB.write db def batch
    $(logDebug) $ logMe <> "Stored block " <> logShow (nodeHeight blockNode)
    l <- asks myListener
    liftIO . atomically . l $ BestBlock blockHash
  where
    blockHash = headerHash $ blockHeader block
    blockTxKeys = map (BlockTxKey blockHash) [0 ..]
    txOps = zipWith insertOp blockTxKeys (blockTxns block)
    txBlockKeys = map (TxKey . txHash) (blockTxns block)
    txBlockOps = zipWith insertOp txBlockKeys blockTxKeys

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

processBlockMessage (BlockGetBest reply) = do
    $(logDebug) $ logMe <> "Got request for best block"
    getBestBlockHash >>= liftIO . atomically . reply

processBlockMessage (BlockPeerAvailable _) = do
    $(logDebug) $ logMe <> "A peer became available, syncing blocks"
    syncBlocks

processBlockMessage (BlockPeerConnect _) = do
    $(logDebug) $ logMe <> "A peer just connected, syncing blocks"
    syncBlocks

processBlockMessage (BlockGetTxs bh reply) = do
    $(logDebug) $ logMe <> "Request to get transactions for a block"
    m <- getBlockTxs bh
    liftIO . atomically $ reply m

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

blockGetBest :: (MonadBase IO m, MonadIO m) => BlockStore -> m BlockHash
blockGetBest b = BlockGetBest `query` b

blockGetTxs ::
       (MonadBase IO m, MonadIO m)
    => BlockHash
    -> BlockStore
    -> m (Maybe (BlockValue, [Tx]))
blockGetTxs h b = BlockGetTxs h `query` b

blockGetTx :: (MonadBase IO m, MonadIO m) => TxHash -> BlockStore -> m (Maybe Tx)
blockGetTx h b = BlockGetTx h `query` b

blockGet :: (MonadBase IO m, MonadIO m) => BlockHash -> BlockStore -> m (Maybe BlockValue)
blockGet h b = BlockGet h `query` b

logMe :: Text
logMe = "[Block] "
