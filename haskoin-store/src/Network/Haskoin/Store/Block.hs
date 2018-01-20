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
, AddrSpentValue(..)
, AddrUnspentValue(..)
, blockGetBest
, blockGetHeight
, blockGet
, blockGetTx
, blockGetAddrTxs
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
import           Data.Int
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

data BlockConfig = BlockConfig
    { blockConfDir      :: !FilePath
    , blockConfMailbox  :: !BlockStore
    , blockConfManager  :: !Manager
    , blockConfChain    :: !Chain
    , blockConfListener :: !(Listen BlockEvent)
    , blockConfCacheNo  :: !Word32
    , blockConfBlockNo  :: !Word32
    }

newtype BlockEvent = BestBlock BlockHash

data BlockMessage
    = BlockChainNew !BlockNode
    | BlockGetBest !(Reply BlockValue)
    | BlockGetHeight !BlockHeight
                     !(Reply (Maybe BlockValue))
    | BlockPeerAvailable !Peer
    | BlockPeerConnect !Peer
    | BlockPeerDisconnect !Peer
    | BlockReceived !Peer
                    !Block
    | BlockNotReceived !Peer
                       !BlockHash
    | BlockGet !BlockHash
               !(Reply (Maybe BlockValue))
    | BlockGetTx !TxHash
                 !(Reply (Maybe DetailedTx))
    | BlockGetAddrSpent !Address
                        !(Reply [(AddrSpentKey, AddrSpentValue)])
    | BlockGetAddrUnspent !Address
                          !(Reply [(AddrUnspentKey, AddrUnspentValue)])
    | BlockProcess

type BlockStore = Inbox BlockMessage

data UnspentCache = UnspentCache
    { unspentCache       :: !(Map OutputKey OutputValue)
    , unspentCacheBlocks :: !(Map BlockHeight [OutputKey])
    , unspentCacheCount  :: !Int
    }

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
    , myCacheNo      :: !Word32
    , myBlockNo      :: !Word32
    }

newtype MultiAddrSpentKey =
    MultiAddrSpentKey Address
    deriving (Show, Eq)

newtype MultiAddrUnspentKey =
    MultiAddrUnspentKey Address
    deriving (Show, Eq)

data AddrUnspentKey = AddrUnspentKey
    { addrUnspentKey      :: !Address
    , addrUnspentHeight   :: !BlockHeight
    , addrUnspentOutPoint :: !OutputKey
    } deriving (Show, Eq)

data AddrUnspentValue = AddrUnspentValue
    { addrUnspentOutput :: !OutputValue
    , addrUnspentPos    :: !Word32
    } deriving (Show, Eq)

data AddrSpentKey = AddrSpentKey
    { addrSpentKey      :: !Address
    , addrSpentHeight   :: !BlockHeight
    , addrSpentOutPoint :: !OutputKey
    } deriving (Show, Eq)

data AddrSpentValue = AddrSpentValue
    { addrSpentValue  :: !SpentValue
    , addrSpentOutput :: !OutputValue
    , addrSpentPos    :: !Word32
    } deriving (Show, Eq)

data BlockValue = BlockValue
    { blockValueHeight    :: !BlockHeight
    , blockValueWork      :: !BlockWork
    , blockValueHeader    :: !BlockHeader
    , blockValueSize      :: !Word32
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
    , detailedTxOuts  :: ![(OutputKey, OutputValue)]
    } deriving (Show, Eq)

data TxValue = TxValue
    { txValueBlock :: !BlockRef
    , txValue      :: !Tx
    , txValueOuts  :: [(OutputKey, OutputValue)]
    } deriving (Show, Eq)

newtype OutputKey = OutputKey
    { outPoint :: OutPoint
    } deriving (Show, Eq)

data OutputValue = OutputValue
    { outputValue :: !Word64
    , outBlock    :: !BlockRef
    , outScript   :: !ByteString
    } deriving (Show, Eq)

newtype SpentKey = SpentKey
    { spentOutPoint :: OutPoint
    } deriving (Show, Eq)

data SpentValue = SpentValue
    { spentInHash  :: !TxHash
    , spentInIndex :: !Word32
    , spentInBlock :: !BlockRef
    , spentInPos   :: !Word32
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

data AddressTx = AddressTx
    { addressTxAddress :: !Address
    , addressTxId      :: !TxHash
    , addressTxAmount  :: !Int64
    , addressTxBlock   :: !BlockRef
    , addressTxPos     :: !Word32
    } deriving (Eq, Show)

instance Record BlockKey BlockValue
instance Record TxKey TxValue
instance Record HeightKey BlockHash
instance Record BestBlockKey BlockHash
instance Record OutputKey OutputValue
instance Record SpentKey SpentValue
instance Record MultiTxKey MultiTxValue
instance Record AddrSpentKey AddrSpentValue
instance Record AddrUnspentKey AddrUnspentValue
instance MultiRecord MultiAddrSpentKey AddrSpentKey AddrSpentValue
instance MultiRecord MultiAddrUnspentKey AddrUnspentKey AddrUnspentValue
instance MultiRecord BaseTxKey MultiTxKey MultiTxValue

instance Ord OutputKey where
    compare = compare `on` f
      where
        f (OutputKey (OutPoint hash index)) = (hash, index)

instance Serialize AddrSpentKey where
    put AddrSpentKey {..} = do
        putWord8 0x03
        put addrSpentKey
        put (maxBound - addrSpentHeight)
        put addrSpentOutPoint
    get = do
        guard . (== 0x03) =<< getWord8
        addrSpentKey <- get
        addrSpentHeight <- (maxBound -) <$> get
        addrSpentOutPoint <- get
        return AddrSpentKey {..}

instance Serialize AddrUnspentKey where
    put AddrUnspentKey {..} = do
        putWord8 0x05
        put addrUnspentKey
        put (maxBound - addrUnspentHeight)
        put addrUnspentOutPoint
    get = do
        guard . (== 0x05) =<< getWord8
        addrUnspentKey <- get
        addrUnspentHeight <- (maxBound -) <$> get
        addrUnspentOutPoint <- get
        return AddrUnspentKey {..}

instance Serialize MultiAddrSpentKey where
    put (MultiAddrSpentKey h) = do
        putWord8 0x03
        put h
    get = do
        guard . (== 0x03) =<< getWord8
        h <- get
        return (MultiAddrSpentKey h)

instance Serialize MultiAddrUnspentKey where
    put (MultiAddrUnspentKey h) = do
        putWord8 0x05
        put h
    get = do
        guard . (== 0x05) =<< getWord8
        h <- get
        return (MultiAddrUnspentKey h)

instance Serialize AddrSpentValue where
    put AddrSpentValue {..} = do
        put addrSpentValue
        put addrSpentOutput
        put addrSpentPos
    get = do
        addrSpentValue <- get
        addrSpentOutput <- get
        addrSpentPos <- get
        return AddrSpentValue {..}

instance Serialize AddrUnspentValue where
    put AddrUnspentValue {..} = do
        put addrUnspentOutput
        put addrUnspentPos
    get = do
        addrUnspentOutput <- get
        addrUnspentPos <- get
        return AddrUnspentValue {..}

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
        put spentInPos
    get = do
        guard . (== 0x02) =<< getWord8
        spentInHash <- get
        spentInIndex <- get
        spentInBlock <- get
        spentInPos <- get
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
        put outputValue
        put outBlock
        put outScript
    get = do
        guard . (== 0x01) =<< getWord8
        outputValue <- get
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
        put blockValueSize
        put blockValueMainChain
        put blockValueTxs
    get = do
        blockValueHeight <- get
        blockValueWork <- get
        blockValueHeader <- get
        blockValueSize <- get
        blockValueMainChain <- get
        blockValueTxs <- get
        return BlockValue {..}

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
    , "size" .= blockValueSize
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
    , "fee" .= fee
    , "vin" .= map input (txIn detailedTx)
    , "vout" .= zipWith output (txOut detailedTx) [0 ..]
    , "hex" .= detailedTx
    ]
  where
    hash = txHash detailedTx
    fee =
        if any ((== zero) . outPointHash . prevOutput) (txIn detailedTx)
            then 0
            else sum (map (outputValue . snd) detailedTxOuts) -
                 sum (map outValue (txOut detailedTx))
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
        [ "value" .= outValue
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
            | OutputValue {..} <-
                  maybeToList (OutputKey op `lookup` detailedTxOuts)
            , let x =
                      [ "value" .= outputValue
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

addrTxPairs :: KeyValue kv => AddressTx -> [kv]
addrTxPairs AddressTx {..} =
    [ "address" .= addressTxAddress
    , "txid" .= addressTxId
    , "amount" .= addressTxAmount
    , "block" .= addressTxBlock
    , "position" .= addressTxPos
    ]

instance ToJSON AddressTx where
    toJSON = object . addrTxPairs
    toEncoding = pairs . mconcat . addrTxPairs

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
blockStore BlockConfig {..} =
    runResourceT $ do
        let opts =
                def
                { LevelDB.createIfMissing = True
                , LevelDB.cacheSize = 512 ^ (20 :: Int)
                }
        db <- LevelDB.open blockConfDir opts
        $(logDebug) $ logMe <> "Database opened"
        pbox <- liftIO $ newTVarIO []
        dbox <- liftIO $ newTVarIO []
        ubox <-
            liftIO $
            newTVarIO
                UnspentCache
                { unspentCache = M.empty
                , unspentCacheBlocks = M.empty
                , unspentCacheCount = 0
                }
        peerbox <- liftIO $ newTVarIO Nothing
        runReaderT
            (syncBlocks >> run)
            BlockRead
            { mySelf = blockConfMailbox
            , myBlockDB = db
            , myDir = blockConfDir
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
    run =
        forever $ do
            $(logDebug) $ logMe <> "Awaiting message"
            msg <- receive blockConfMailbox
            processBlockMessage msg

spendAddr ::
       AddrUnspentKey
    -> AddrUnspentValue
    -> SpentValue
    -> (AddrSpentKey, AddrSpentValue)
spendAddr uk uv s = (sk, sv)
  where
    sk =
        AddrSpentKey
        { addrSpentKey = addrUnspentKey uk
        , addrSpentHeight = addrUnspentHeight uk
        , addrSpentOutPoint = addrUnspentOutPoint uk
        }
    sv =
        AddrSpentValue
        { addrSpentValue = s
        , addrSpentOutput = addrUnspentOutput uv
        , addrSpentPos = addrUnspentPos uv
        }

unspendAddr :: AddrSpentKey -> AddrSpentValue -> (AddrUnspentKey, AddrUnspentValue)
unspendAddr sk sv = (uk, uv)
  where
    uk = AddrUnspentKey
         { addrUnspentKey = addrSpentKey sk
         , addrUnspentHeight = addrSpentHeight sk
         , addrUnspentOutPoint = addrSpentOutPoint sk
         }
    uv = AddrUnspentValue
         { addrUnspentOutput = addrSpentOutput sv
         , addrUnspentPos = addrSpentPos sv
         }


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

getAddrSpent :: MonadBlock m => Address -> m [(AddrSpentKey, AddrSpentValue)]
getAddrSpent addr = do
    db <- asks myBlockDB
    MultiAddrSpentKey addr `valuesForKey` db $$ consume

getAddrUnspent ::
       MonadBlock m => Address -> m [(AddrUnspentKey, AddrUnspentValue)]
getAddrUnspent addr = do
    db <- asks myBlockDB
    MultiAddrUnspentKey addr `valuesForKey` db $$ consume

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
        blockNo <- asks myBlockNo
        let chainHeight = nodeHeight chainBest
            splitHeight = nodeHeight splitBlock
            topHeight = min chainHeight (splitHeight + blockNo + 1)
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
        Just block -> do
            importBlock block
            mbox <- asks mySelf
            BlockProcess `send` mbox
        Nothing    -> syncBlocks

importBlock :: MonadBlock m => Block -> m ()
importBlock block@Block {..} = do
    $(logDebug) $ logMe <> "Importing block " <> logShow blockHash
    ch <- asks myChain
    bn <-
        chainGetBlock blockHash ch >>= \case
            Just bn -> return bn
            Nothing -> do
                $(logError) $ logMe <> "Could not obtain block from chain"
                error "BUG: Could not obtain block from chain"
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
blockBatchOps block@Block {..} height work main = do
    outputOps <- concat <$> mapM (outputBatchOps blockRef) blockTxns
    spent <- concat <$> zipWithM (spentOutputs blockRef) blockTxns [0 ..]
    spentOps <- concat <$> zipWithM (spentBatchOps blockRef) blockTxns [0 ..]
    txOps <- forM blockTxns (txBatchOp blockRef spent)
    addrOps <-
        concat <$> zipWithM (addrBatchOps blockRef spent) blockTxns [0 ..]
    unspentCachePrune
    return $
        concat
            [[blockOp], bestOp, heightOp, txOps, outputOps, spentOps, addrOps]
  where
    blockHash = headerHash blockHeader
    blockKey = BlockKey blockHash
    txHashes = map txHash blockTxns
    size = fromIntegral (BS.length (S.encode block))
    blockValue = BlockValue height work blockHeader size main txHashes
    blockRef = BlockRef blockHash height main
    blockOp = insertOp blockKey blockValue
    bestOp = [insertOp BestBlockKey blockHash | main]
    heightKey = HeightKey height
    heightOp = [insertOp heightKey blockHash | main]

getOutput ::
       MonadBlock m
    => OutputKey
    -> m (Maybe OutputValue)
getOutput key = runMaybeT (fromCache <|> fromDB)
  where
    hash = outPointHash (outPoint key)
    index = outPointIndex (outPoint key)
    fromDB = do
        db <- asks myBlockDB
        $(logDebug) $
            logMe <> "Cache miss for output " <> cs (show hash) <> "/" <>
            cs (show index)
        MaybeT $ key `retrieveValue` db
    fromCache = do
        ubox <- asks myUnspentCache
        cache@UnspentCache {..} <- liftIO $ readTVarIO ubox
        m <- MaybeT . return $ M.lookup key unspentCache
        $(logDebug) $
            logMe <> "Cache hit for output " <> cs (show hash) <> " " <>
            cs (show index)
        liftIO . atomically $
            writeTVar
                ubox
                cache
                { unspentCache = M.delete key unspentCache
                , unspentCacheCount = unspentCacheCount - 1
                }
        return m


unspentCachePrune :: MonadBlock m => m ()
unspentCachePrune = do
    n <- asks myCacheNo
    ubox <- asks myUnspentCache
    cache <- liftIO (readTVarIO ubox)
    let new = clear (fromIntegral n) cache
        del = unspentCacheCount cache - unspentCacheCount new
    liftIO . atomically $ writeTVar ubox new
    $(logDebug) $
        logMe <> "Deleted " <> cs (show del) <> " of " <>
        cs (show (unspentCacheCount cache)) <>
        " entries from UTXO cache"
  where
    clear n c@UnspentCache {..}
        | unspentCacheCount < n = c
        | otherwise =
            let (del, keep) = M.splitAt 1 unspentCacheBlocks
                ks =
                    [ k
                    | keys <- M.elems del
                    , k <- keys
                    , isJust (M.lookup k unspentCache)
                    ]
                count = unspentCacheCount - length ks
                cache = foldl' (flip M.delete) unspentCache ks
            in clear
                   n
                   UnspentCache
                   { unspentCache = cache
                   , unspentCacheBlocks = keep
                   , unspentCacheCount = count
                   }

spentOutputs ::
       MonadBlock m
    => BlockRef
    -> Tx
    -> Word32 -- ^ position in block
    -> m [(OutputKey, (OutputValue, SpentValue))]
spentOutputs block tx pos =
    fmap catMaybes . forM (zip [0 ..] (txIn tx)) $ \(i, TxIn {..}) ->
        if outPointHash prevOutput == zero
            then return Nothing
            else do
                let key = OutputKey prevOutput
                val <- fromMaybe e <$> getOutput key
                let spent = SpentValue (txHash tx) i block pos
                return $ Just (key, (val, spent))
  where
    zero = "0000000000000000000000000000000000000000000000000000000000000000"
    e = error "Colud not retrieve information for output being spent"

addrBatchOps ::
       MonadBlock m
    => BlockRef
    -> [(OutputKey, (OutputValue, SpentValue))]
    -> Tx
    -> Word32
    -> m [LevelDB.BatchOp]
addrBatchOps block spent tx pos = do
    ins <-
        fmap concat . forM (txIn tx) $ \ti@TxIn {..} ->
            if outPointHash prevOutput == zero
                then return []
                else if mainchain
                         then spend ti
                         else unspend ti
    let outs = concat . catMaybes $ zipWith output (txOut tx) [0 ..]
    return $ ins ++ outs
  where
    height = blockRefHeight block
    mainchain = blockRefMainChain block
    output TxOut {..} i =
        let ok = OutputKey (OutPoint (txHash tx) i)
            ov =
                OutputValue
                { outputValue = outValue
                , outBlock = block
                , outScript = scriptOutput
                }
            m = ok `lookup` spent
        in case scriptToAddressBS scriptOutput of
               Just addr ->
                   if mainchain
                       then Just (insertOutput ok addr ov m)
                       else Just (deleteOutput ok addr)
               Nothing -> Nothing
    deleteOutput ok addr =
        [ deleteOp
              AddrSpentKey
              { addrSpentKey = addr
              , addrSpentHeight = height
              , addrSpentOutPoint = ok
              }
        , deleteOp
              AddrUnspentKey
              { addrUnspentKey = addr
              , addrUnspentHeight = height
              , addrUnspentOutPoint = ok
              }
        ]
    insertOutput ok hash ov =
        \case
            Nothing ->
                let uk =
                        AddrUnspentKey
                        { addrUnspentKey = hash
                        , addrUnspentHeight = height
                        , addrUnspentOutPoint = ok
                        }
                    uv =
                        AddrUnspentValue
                        {addrUnspentOutput = ov, addrUnspentPos = pos}
                in [insertOp uk uv]
            Just (_, s) ->
                let sk =
                        AddrSpentKey
                        { addrSpentKey = hash
                        , addrSpentHeight = height
                        , addrSpentOutPoint = ok
                        }
                    sv =
                        AddrSpentValue
                        { addrSpentValue = s
                        , addrSpentOutput = ov
                        , addrSpentPos = pos
                        }
                in [insertOp sk sv]
    zero = "0000000000000000000000000000000000000000000000000000000000000000"
    eo = error "Colud not find spent output"
    spend TxIn {..} =
        fmap (concat . maybeToList) . runMaybeT $ do
            let (ok, s, maddr, height') = getSpent prevOutput
            addr <- MaybeT $ return maddr
            db <- asks myBlockDB
            let uk =
                    AddrUnspentKey
                    { addrUnspentKey = addr
                    , addrUnspentHeight = height'
                    , addrUnspentOutPoint = ok
                    }
            uv <- MaybeT $ uk `retrieveValue` db
            let (sk, sv) = spendAddr uk uv s
            return [deleteOp uk, insertOp sk sv]
    unspend TxIn {..} =
        fmap (concat . maybeToList) . runMaybeT $ do
            let (ok, _s, maddr, height') = getSpent prevOutput
            addr <- MaybeT $ return maddr
            db <- asks myBlockDB
            let sk =
                    AddrSpentKey
                    { addrSpentKey = addr
                    , addrSpentHeight = height'
                    , addrSpentOutPoint = ok
                    }
            sv <- MaybeT $ sk `retrieveValue` db
            let (uk, uv) = unspendAddr sk sv
            return [deleteOp sk, insertOp uk uv]
    getSpent po =
        let ok = OutputKey po
            (ov, s) = fromMaybe eo $ ok `lookup` spent
            maddr = scriptToAddressBS (outScript ov)
            height' = blockRefHeight (outBlock ov)
        in (ok, s, maddr, height')

txBatchOp ::
       MonadBlock m
    => BlockRef
    -> [(OutputKey, (OutputValue, SpentValue))]
    -> Tx
    -> m LevelDB.BatchOp
txBatchOp block spent tx =
    return $ insertOp (TxKey (txHash tx)) (TxValue block tx vs)
  where
    zero = "0000000000000000000000000000000000000000000000000000000000000000"
    e = error "Could not find spent output information"
    vs =
        [ (k, v)
        | ti <- txIn tx
        , let output = prevOutput ti
        , outPointHash output /= zero
        , let k = OutputKey output
        , let (v, _) = fromMaybe e (k `lookup` spent)
        ]


addToCache :: MonadBlock m => BlockRef -> [(OutputKey, OutputValue)] -> m ()
addToCache BlockRef {..} xs = do
    ubox <- asks myUnspentCache
    UnspentCache {..} <- liftIO (readTVarIO ubox)
    let cache = foldl' (\c (k, v) -> M.insert k v c) unspentCache xs
        keys = map fst xs
        blocks = M.insertWith (++) blockRefHeight keys unspentCacheBlocks
        count = unspentCacheCount + length xs
    liftIO . atomically $
        writeTVar
            ubox
            UnspentCache
            { unspentCache = cache
            , unspentCacheBlocks = blocks
            , unspentCacheCount = count
            }

outputBatchOps :: MonadBlock m => BlockRef -> Tx -> m [LevelDB.BatchOp]
outputBatchOps block@BlockRef {..} tx = do
    let os = zipWith f (txOut tx) [0 ..]
    addToCache block os
    return $ map (uncurry insertOp) os
  where
    f TxOut {..} i =
        let key = OutputKey {outPoint = OutPoint (txHash tx) i}
            value =
                OutputValue
                { outputValue = outValue
                , outBlock = block
                , outScript = scriptOutput
                }
        in (key, value)

spentBatchOps ::
       MonadBlock m
    => BlockRef
    -> Tx
    -> Word32 -- ^ position in block
    -> m [LevelDB.BatchOp]
spentBatchOps block tx pos = return . catMaybes $ zipWith f (txIn tx) [0 ..]
  where
    zero = "0000000000000000000000000000000000000000000000000000000000000000"
    f TxIn {..} index =
        if outPointHash prevOutput == zero
            then Nothing
            else Just $
                 insertOp
                     (SpentKey prevOutput)
                     (SpentValue (txHash tx) index block pos)

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

processBlockMessage (BlockGetAddrSpent addr reply) = do
    $(logDebug) $ logMe <> "Get outputs for address " <> cs (show addr)
    os <- getAddrSpent addr
    liftIO . atomically $ reply os

processBlockMessage (BlockGetAddrUnspent addr reply) = do
    $(logDebug) $ logMe <> "Get outputs for address " <> cs (show addr)
    os <- getAddrUnspent addr
    liftIO . atomically $ reply os

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
    mbox <- asks mySelf
    best <- getBestBlockHash
    -- Only send BlockProcess message if download box has a block to process
    when (prevBlock (blockHeader b) == best) (BlockProcess `send` mbox)

processBlockMessage BlockProcess = do
    $(logDebug) $ logMe <> "Processing downloaded block"
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

blockGetAddrTxs ::
       (MonadBase IO m, MonadIO m) => Address -> BlockStore -> m [AddressTx]
blockGetAddrTxs addr b = do
    us <- BlockGetAddrUnspent addr `query` b
    ss <- BlockGetAddrSpent addr `query` b
    let utx =
            [ AddressTx
            { addressTxAddress = addr
            , addressTxId = outPointHash (outPoint (addrUnspentOutPoint k))
            , addressTxAmount = fromIntegral (outputValue (addrUnspentOutput v))
            , addressTxBlock = outBlock (addrUnspentOutput v)
            , addressTxPos = addrUnspentPos v
            }
            | (k, v) <- us
            ]
        stx =
            [ AddressTx
            { addressTxAddress = addr
            , addressTxId = outPointHash (outPoint (addrSpentOutPoint k))
            , addressTxAmount = fromIntegral (outputValue (addrSpentOutput v))
            , addressTxBlock = outBlock (addrSpentOutput v)
            , addressTxPos = addrSpentPos v
            }
            | (k, v) <- ss
            ]
        itx =
            [ AddressTx
            { addressTxAddress = addr
            , addressTxId = spentInHash s
            , addressTxAmount = -fromIntegral (outputValue (addrSpentOutput v))
            , addressTxBlock = spentInBlock s
            , addressTxPos = spentInPos s
            }
            | (_, v) <- ss
            , let s = addrSpentValue v
            ]
        zs =
            [ atx {addressTxAmount = amount}
            | ts@(atx:_) <- groupBy ((==) `on` addressTxId) (itx ++ stx ++ utx)
            , let amount = sum (map addressTxAmount ts)
            ]
    return $ sortBy (flip compare `on` f) zs
  where
    f AddressTx {..} = (blockRefHeight addressTxBlock, addressTxPos)

logMe :: Text
logMe = "[Block] "
