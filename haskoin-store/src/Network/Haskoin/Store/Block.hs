{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}
module Network.Haskoin.Store.Block
( BlockConfig(..)
, BlockStore
, BlockEvent(..)
, BlockMessage(..)
, StoredBlock(..)
, blockGetBest
, blockGet
, blockGetTxs
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
import           Data.ByteString             (ByteString)
import qualified Data.ByteString             as BS
import           Data.Default
import           Data.List
import           Data.Monoid
import           Data.Serialize
import           Data.String.Conversions
import           Data.Text                   (Text)
import           Data.Word
import           Database.LevelDB            (DB, MonadResource, runResourceT)
import qualified Database.LevelDB            as LevelDB
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Node
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
                  !(Reply (Maybe (StoredBlock, [Tx])))
    | BlockGet !BlockHash
               (Reply (Maybe StoredBlock))

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

data StoredBlock = StoredBlock
    { storedBlockMain   :: !Bool
    , storedBlockHeight :: !BlockHeight
    , storedBlockWork   :: !BlockWork
    , storedBlockHeader :: !BlockHeader
    , storedBlockTxs    :: ![TxHash]
    } deriving (Show, Eq)

instance Serialize StoredBlock where
    put sb = do
        put $ storedBlockMain sb
        put $ storedBlockHeight sb
        put $ storedBlockWork sb
        put $ storedBlockHeader sb
        put $ storedBlockTxs sb
    get = StoredBlock <$> get <*> get <*> get <*> get <*> get

newtype BlockKey = BlockKey
    { blockKeyHash :: BlockHash
    }

data BlockHeightKey = BlockHeightKey
    { blockHeightKeyHeight :: !BlockHeight
    , blockHeightKeyHash   :: !BlockHash
    }

instance Serialize BlockHeightKey where
    put bh = do
        putWord8 0x03
        put $ maxBound - blockHeightKeyHeight bh
        put $ blockHeightKeyHash bh
    get = do
        k <- getWord8
        guard $ k == 0x03
        ih <- get
        bh <- get
        return
            BlockHeightKey
            {blockHeightKeyHeight = maxBound - ih, blockHeightKeyHash = bh}

instance Serialize BlockKey where
    put bk = do
        putWord8 0x01
        put $ blockKeyHash bk
    get = do
        getWord8 >>= guard . (== 0x01)
        bh <- get
        return BlockKey {blockKeyHash = bh}

data BlockTxKey = BlockTxKey
    { blockTxKeyHash :: !BlockHash
    , blockTxKeyPos  :: !Word32
    }

instance Serialize BlockTxKey where
    put bt = do
        putWord8 0x01
        put $ blockTxKeyHash bt
        put $ blockTxKeyPos bt
    get = do
        getWord8 >>= guard . (== 0x01)
        bh <- get
        pos <- get
        return BlockTxKey {blockTxKeyHash = bh, blockTxKeyPos = pos}

data TxBlockKey = TxBlockKey
    { txBlockKeyTxHash    :: !TxHash
    , txBlockKeyBlockHash :: !BlockHash
    }

instance Serialize TxBlockKey where
    put tb = do
        putWord8 0x02
        put $ txBlockKeyTxHash tb
        put $ txBlockKeyBlockHash tb
    get = do
        k <- getWord8
        guard $ k == 0x02
        th <- get
        bh <- get
        return TxBlockKey {txBlockKeyTxHash = th, txBlockKeyBlockHash = bh}

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
        $(logDebug) $ logMe <> "Block store actor running"
        let opts = def {LevelDB.createIfMissing = True}
        $(logDebug) $ logMe <> "Opening block store LevelDB database"
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

bestBlockKey :: ByteString
bestBlockKey = BS.replicate 32 0x00

getBestBlockHash :: MonadBlock m => m BlockHash
getBestBlockHash = do
    $(logDebug) $ logMe <> "Processing best block request from database"
    db <- asks myBlockDB
    bsM <- LevelDB.get db def bestBlockKey
    case bsM of
        Nothing -> do
            $(logDebug) $ logMe <> "Storing genesis block in database"
            importBlock genesisBlock
            $(logDebug) $ logMe <> "Stored genesis"
            return $ headerHash genesisHeader
        Just bs -> do
            $(logDebug) $ logMe <> "Decoding best block from database"
            case decode bs of
                Left e -> do
                    let str = "Could not decode best block: " <> e
                    $(logError) $ logMe <> cs str
                    error $ "BUG: " <> str
                Right bb -> do
                    $(logDebug) $
                        logMe <> "Successfully decoded best block " <>
                        logShow bb
                    return bb

getStoredBlock :: MonadBlock m => BlockHash -> m (Maybe StoredBlock)
getStoredBlock bh =
    runMaybeT $ do
        $(logDebug) $ logMe <> "Retrieving stored block " <> logShow bh
        db <- asks myBlockDB
        bs <- MaybeT $ LevelDB.get db def (encode $ BlockKey bh)
        MaybeT . return . either (const Nothing) Just $ decode bs

getBlockTxs :: MonadBlock m => BlockHash -> m (Maybe (StoredBlock, [Tx]))
getBlockTxs bh =
    runMaybeT $ do
        $(logDebug) $
            logMe <> "Retrieving block transactions for block " <> logShow bh
        db <- asks myBlockDB
        LevelDB.withIterator db def $ \it -> do
            $(logDebug) $ logMe <> "Retrieving block entry for " <> logShow bh
            LevelDB.iterSeek it (encode $ BlockKey bh)
            $(logDebug) $ logMe <> "Getting key for block " <> logShow bh
            kbs <- MaybeT $ LevelDB.iterKey it
            bk <- MaybeT . return . either (const Nothing) Just $ decode kbs
            guard $ blockKeyHash bk == bh
            $(logDebug) $
                logMe <> "Getting value for stored block " <> logShow bh
            bs <- MaybeT $ LevelDB.iterValue it
            sb <- MaybeT . return $ either (const Nothing) Just $ decode bs
            $(logDebug) $
                logMe <> "Getting transactions for block " <> logShow bh
            ts <- lift $ txs [] it
            return (sb, reverse ts)
  where
    txs acc it = do
        m <-
            runMaybeT $ do
                $(logDebug) $
                    logMe <> "Getting next transaction for block " <> logShow bh
                LevelDB.iterNext it
                guard =<< LevelDB.iterValid it
                $(logDebug) $
                    logMe <> "Retrieving key for transaction in block " <>
                    logShow bh
                kbs <- MaybeT $ LevelDB.iterKey it
                $(logDebug) $
                    logMe <> "Retrieved key for transaction in block " <>
                    logShow bh
                btk <-
                    MaybeT . return . either (const Nothing) Just $ decode kbs
                $(logDebug) $
                    logMe <> "Decoded key for transaction in block " <>
                    logShow bh
                guard $ blockTxKeyHash btk == bh
                $(logDebug) $
                    logMe <>
                    "Retreiving transaction data for transaction in block " <>
                    logShow bh
                bs <- MaybeT $ LevelDB.iterValue it
                MaybeT . return . either (const Nothing) Just $ decode bs
        case m of
            Just tx -> txs (tx : acc) it
            Nothing -> return acc

revertBestBlock :: MonadBlock m => m ()
revertBestBlock =
    void . runMaybeT $ do
        best <- getBestBlockHash
        $(logDebug) $ logMe <> "Reverting block " <> logShow best
        guard (best /= headerHash genesisHeader)
        $(logDebug) $ logMe <> "Getting stored block " <> logShow best
        sb <- getStoredBlock best >>= maybeStoredBlock
        db <- asks myBlockDB
        LevelDB.write
            db
            def
            [ LevelDB.Put
                  bestBlockKey
                  (encode . prevBlock $ storedBlockHeader sb)
            , LevelDB.Put
                  (encode $ BlockKey best)
                  (encode sb {storedBlockMain = False})
            , LevelDB.Put
                  (encode $ BlockHeightKey (storedBlockHeight sb) best)
                  (encode False)
            ]
  where
    maybeStoredBlock (Just b) = return b
    maybeStoredBlock Nothing = do
        let str = "Could not retrieve best block from database"
        $(logError) $ logMe <> cs str
        error $ "BUG: " <> str

syncBlocks :: MonadBlock m => m ()
syncBlocks = do
    mgr <- asks myManager
    peerbox <- asks myPeer
    pbox <- asks myPending
    ch <- asks myChain
    chainBest <- chainGetBest ch
    let bestHash = headerHash $ nodeHeader chainBest
    myBestHash <- getBestBlockHash
    void . runMaybeT $ do
        guard (myBestHash /= bestHash)
        liftIO (readTVarIO pbox) >>= guard . null
        myBest <- MaybeT (chainGetBlock myBestHash ch)
        splitBlock <- chainGetSplitBlock chainBest myBest ch
        let splitHash = headerHash $ nodeHeader splitBlock
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
        let len = length requestBlocks
        p <-
            MaybeT (liftIO (readTVarIO peerbox)) <|>
            MaybeT (managerTakeAny False mgr)
        liftIO . atomically $ writeTVar peerbox (Just p)
        $(logInfo) $ logMe <> "Downloading " <> logShow len <> " blocks"
        downloadBlocks p (map (headerHash . nodeHeader) requestBlocks)
  where
    revertUntil myBest splitBlock
        | myBest == splitBlock = return ()
        | otherwise = do
            $(logDebug) $ logMe <> "Reversing best block due to reorg"
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
        Nothing -> syncBlocks

importBlock :: MonadBlock m => Block -> m ()
importBlock block = do
    $(logDebug) $ logMe <> "Importing block " <> logShow blockHash
    when (blockHash /= headerHash genesisHeader) $ do
        $(logDebug) $
            logMe <> "Testing if block " <> logShow blockHash <>
            " builds on existing best block"
        best <- getBestBlockHash
        when (prevBlock (blockHeader block) /= best) errBest
    $(logDebug) $
        logMe <> "Block " <> logShow blockHash <> " builds on best block"
    ch <- asks myChain
    blockNode <- chainGetBlock blockHash ch >>= maybeErrBlock
    db <- asks myBlockDB
    let storedBlock =
            StoredBlock
            { storedBlockMain = True
            , storedBlockHeight = nodeHeight blockNode
            , storedBlockWork = nodeWork blockNode
            , storedBlockHeader = nodeHeader blockNode
            , storedBlockTxs = map txHash (blockTxns block)
            }
        blockKey = BlockKey blockHash
        blockPut = LevelDB.Put (encode blockKey) (encode storedBlock)
        blockHeightKey =
            BlockHeightKey
            { blockHeightKeyHeight = nodeHeight blockNode
            , blockHeightKeyHash = blockHash
            }
        blockHeightPut = LevelDB.Put (encode blockHeightKey) (encode True)
        bestBlockPut = LevelDB.Put bestBlockKey (encode blockHash)
        batch =
            blockPut :
            blockHeightPut : bestBlockPut : batchTxImport ++ batchTxBlockImport
    $(logDebug) $
        logMe <> "Storing database entries for block " <> logShow blockHash
    LevelDB.write db def batch
    $(logDebug) $ logMe <> "Stored block " <> logShow blockHash
    l <- asks myListener
    liftIO . atomically . l $ BestBlock blockHash
  where
    blockHash = headerHash $ blockHeader block
    errBest = do
        let str = "Attempted to import block not building on best"
        $(logError) $ logMe <> cs str
        error $ "BUG: " <> str
    maybeErrBlock (Just bn) = return bn
    maybeErrBlock Nothing = do
        let str = "Could not obtain best block from Chain actor"
        $(logError) $ logMe <> cs str
        error $ "BUG: " <> str
    blockTxKeys = map (BlockTxKey (headerHash $ blockHeader block)) [0 ..]
    batchTxImport =
        map
            (\(k, t) -> LevelDB.Put (encode k) (encode t))
            (zip blockTxKeys (blockTxns block))
    txBlockKeys = map (\t -> TxBlockKey (txHash t) blockHash) (blockTxns block)
    batchTxBlockImport =
        map
            (\(k, pos) -> LevelDB.Put (encode k) (encode (pos :: Word32)))
            (zip txBlockKeys [0 ..])


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
    m <- getStoredBlock bh
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
    -> m (Maybe (StoredBlock, [Tx]))
blockGetTxs h b = BlockGetTxs h `query` b

blockGet :: (MonadBase IO m, MonadIO m) => BlockHash -> BlockStore -> m (Maybe StoredBlock)
blockGet h b = BlockGet h `query` b

logMe :: Text
logMe = "[Block] "
