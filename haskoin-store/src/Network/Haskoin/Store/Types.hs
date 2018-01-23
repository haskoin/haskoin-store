{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
module Network.Haskoin.Store.Types where

import           Control.Applicative
import           Control.Concurrent.NQE
import           Control.Monad.Reader
import           Data.Aeson
import           Data.ByteString              (ByteString)
import qualified Data.ByteString              as BS
import           Data.Function
import           Data.Int
import           Data.Map.Strict              (Map)
import           Data.Maybe
import           Data.Serialize               as S
import           Data.String.Conversions
import           Data.Word
import           Database.RocksDB             (DB)
import           Network.Haskoin.Block
import           Network.Haskoin.Crypto
import           Network.Haskoin.Node
import           Network.Haskoin.Script
import           Network.Haskoin.Store.Common
import           Network.Haskoin.Transaction
import           Network.Haskoin.Util

data BlockConfig = BlockConfig
    { blockConfMailbox  :: !BlockStore
    , blockConfManager  :: !Manager
    , blockConfChain    :: !Chain
    , blockConfListener :: !(Listen BlockEvent)
    , blockConfCacheNo  :: !Word32
    , blockConfBlockNo  :: !Word32
    , blockConfDB       :: !DB
    }

newtype BlockEvent = BestBlock BlockHash

data BlockMessage
    = BlockChainNew !BlockNode
    | BlockPeerConnect !Peer
    | BlockPeerDisconnect !Peer
    | BlockReceived !Peer
                    !Block
    | BlockNotReceived !Peer
                       !BlockHash
    | BlockProcess

type BlockStore = Inbox BlockMessage

data UnspentCache = UnspentCache
    { unspentCache       :: !(Map OutputKey OutputValue)
    , unspentCacheBlocks :: !(Map BlockHeight [OutputKey])
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
    } deriving (Show, Eq, Ord)

data DetailedTx = DetailedTx
    { detailedTx      :: !Tx
    , detailedTxBlock :: !BlockRef
    , detailedTxSpent :: ![(SpentKey, SpentValue)]
    , detailedTxOuts  :: ![(OutputKey, OutputValue)]
    } deriving (Show, Eq)

data AddressBalance = AddressBalance
    { addressBalAddress      :: !Address
    , addressBalConfirmed    :: !Word64
    , addressBalUnconfirmed  :: !Word64
    , addressBalImmature     :: !Word64
    , addressBalBlock        :: !BlockRef
    , addressBalTxCount      :: !Word64
    , addressBalUnspentCount :: !Word64
    , addressBalSpentCount   :: !Word64
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

data Immature = Immature
    { immatureBlock :: !BlockRef
    , immatureValue :: !Word64
    } deriving (Show, Eq)

data BalanceKey = BalanceKey
    { balanceAddress :: !Address
    , balanceBlock   :: !BlockRef
    } deriving (Show, Eq, Ord)

data BalanceValue = BalanceValue
    { balanceValue        :: !Word64
    , balanceImmature     :: ![Immature]
    , balanceTxCount      :: !Word64
    , balanceUnspentCount :: !Word64
    , balanceSpentCount   :: Word64
    } deriving (Show, Eq)

newtype MultiBalance = MultiBalance
    { multiAddress :: Address
    } deriving (Show, Eq)

data BestBlockKey = BestBlockKey deriving (Show, Eq)

data AddressTx = AddressTx
    { addressTxAddress :: !Address
    , addressTxId      :: !TxHash
    , addressTxAmount  :: !Int64
    , addressTxBlock   :: !BlockRef
    , addressTxPos     :: !Word32
    } deriving (Eq, Show)

data Unspent = Unspent
    { unspentTxId  :: !TxHash
    , unspentIndex :: !Word32
    , unspentValue :: !Word64
    , unspentBlock :: !BlockRef
    , unspentPos   :: !Word32
    }

instance Record BlockKey BlockValue
instance Record TxKey TxValue
instance Record HeightKey BlockHash
instance Record BestBlockKey BlockHash
instance Record OutputKey OutputValue
instance Record SpentKey SpentValue
instance Record MultiTxKey MultiTxValue
instance Record AddrSpentKey AddrSpentValue
instance Record AddrUnspentKey AddrUnspentValue
instance Record BalanceKey BalanceValue
instance MultiRecord MultiBalance BalanceKey BalanceValue
instance MultiRecord MultiAddrSpentKey AddrSpentKey AddrSpentValue
instance MultiRecord MultiAddrUnspentKey AddrUnspentKey AddrUnspentValue
instance MultiRecord BaseTxKey MultiTxKey MultiTxValue

instance Ord OutputKey where
    compare = compare `on` f
      where
        f (OutputKey (OutPoint hash index)) = (hash, index)

instance Serialize MultiBalance where
    put MultiBalance {..} = do
        putWord8 0x04
        put multiAddress
    get = do
        guard . (== 0x04) =<< getWord8
        multiAddress <- get
        return MultiBalance {..}

instance Serialize BalanceKey where
    put BalanceKey {..} = do
        putWord8 0x04
        put balanceAddress
        put (maxBound - blockRefHeight balanceBlock)
        put (blockRefHash balanceBlock)
    get = do
        guard . (== 0x04) =<< getWord8
        balanceAddress <- get
        blockRefHeight <- (maxBound -) <$> get
        blockRefHash <- get
        let blockRefMainChain = True
            balanceBlock = BlockRef {..}
        return BalanceKey {..}

instance Serialize BalanceValue where
    put BalanceValue {..} = do
        put balanceValue
        put balanceImmature
        put balanceTxCount
        put balanceUnspentCount
        put balanceSpentCount
    get = do
        balanceValue <- get
        balanceImmature <- get
        balanceTxCount <- get
        balanceUnspentCount <- get
        balanceSpentCount <- get
        return BalanceValue {..}

instance Serialize Immature where
    put Immature {..} =
        put (immatureBlock, immatureValue)
    get = do
        (immatureBlock, immatureValue) <- get
        return Immature {..}

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

unspentPairs :: KeyValue kv => Unspent -> [kv]
unspentPairs Unspent {..} =
    [ "txid" .= unspentTxId
    , "vout" .= unspentIndex
    , "value" .= unspentValue
    , "block" .= unspentBlock
    , "position" .= unspentPos
    ]

instance ToJSON Unspent where
    toJSON = object . unspentPairs
    toEncoding = pairs . mconcat . unspentPairs

addressBalancePairs :: KeyValue kv => AddressBalance -> [kv]
addressBalancePairs AddressBalance {..} =
    [ "address" .= addressBalAddress
    , "block" .= addressBalBlock
    , "confirmed" .= addressBalConfirmed
    , "unconfirmed" .= addressBalUnconfirmed
    , "immature" .= addressBalImmature
    , "transactions" .= addressBalTxCount
    , "unspent" .= addressBalUnspentCount
    , "spent" .= addressBalSpentCount
    ]

instance ToJSON AddressBalance where
    toJSON = object . addressBalancePairs
    toEncoding = pairs . mconcat . addressBalancePairs

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

newtype StoreEvent =
    BlockEvent BlockEvent

type StoreSupervisor = Inbox SupervisorMessage

data StoreConfig = StoreConfig
    { storeConfDir        :: !FilePath
    , storeConfBlocks     :: !BlockStore
    , storeConfSupervisor :: !StoreSupervisor
    , storeConfChain      :: !Chain
    , storeConfListener   :: !(Listen StoreEvent)
    , storeConfMaxPeers   :: !Int
    , storeConfInitPeers  :: ![HostPort]
    , storeConfNoNewPeers :: !Bool
    , storeConfCacheNo    :: !Word32
    , storeConfBlockNo    :: !Word32
    , storeConfDB         :: !DB
    }
