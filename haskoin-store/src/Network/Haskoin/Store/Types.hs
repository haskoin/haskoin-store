{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
module Network.Haskoin.Store.Types where

import           Control.Applicative
import           Control.Concurrent.NQE
import           Control.Exception
import           Control.Monad.Reader
import           Data.Aeson
import           Data.ByteString              (ByteString)
import qualified Data.ByteString              as BS
import           Data.Function
import           Data.Int
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

data BroadcastExcept
    = BadSignature
    | NonStandard
    | InputSpent
    | InputNotFound
    | NotEnoughCoins
    | NoPeers
    deriving (Show, Eq, Ord)

instance Exception BroadcastExcept

data CacheStats = CacheStats
    { unspentCacheHits      :: !Int
    , unspentCacheMisses    :: !Int
    , addressCacheHits      :: !Int
    , existingAddressMisses :: !Int
    , newAddressMisses      :: !Int
    , addressCacheSize      :: !Int
    , unspentCacheSize      :: !Int
    }

instance ToJSON CacheStats where
    toJSON CacheStats {..} =
        object
            [ "utxo-hits" .= unspentCacheHits
            , "utxo-misses" .= unspentCacheMisses
            , "address-hits" .= addressCacheHits
            , "address-misses" .= existingAddressMisses
            , "new-address-misses" .= newAddressMisses
            , "address-cache-size" .= addressCacheSize
            , "utxo-cache-size" .= unspentCacheSize
            ]

newtype NewTx = NewTx
    { newTx :: Tx
    } deriving (Show, Eq, Ord)

newtype SentTx = SentTx
    { sentTx :: TxHash
    } deriving (Show, Eq, Ord)

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
    | BlockCacheStats !(Reply CacheStats)

type BlockStore = Inbox BlockMessage

data MultiAddrOutputKey = MultiAddrOutputKey
    { multiAddrOutputSpent   :: !Bool
    , multiAddrOutputAddress :: !Address
    } deriving (Show, Eq, Ord)

data AddrOutputKey = AddrOutputKey
    { addrOutputSpent   :: !Bool
    , addrOutputAddress :: !Address
    , addrOutputHeight  :: !BlockHeight
    , addrOutPoint      :: !OutPoint
    } deriving (Show, Eq, Ord)

data BlockValue = BlockValue
    { blockValueHeight    :: !BlockHeight
    , blockValueWork      :: !BlockWork
    , blockValueHeader    :: !BlockHeader
    , blockValueSize      :: !Word32
    , blockValueMainChain :: !Bool
    , blockValueTxs       :: ![TxHash]
    } deriving (Show, Eq, Ord)

data BlockRef = BlockRef
    { blockRefHash      :: !BlockHash
    , blockRefHeight    :: !BlockHeight
    , blockRefMainChain :: !Bool
    } deriving (Show, Eq, Ord)

data DetailedTx = DetailedTx
    { detailedTxData    :: !Tx
    , detailedTxFee     :: !Word64
    , detailedTxInputs  :: ![DetailedInput]
    , detailedTxOutputs :: ![DetailedOutput]
    , detailedTxBlock   :: !BlockRef
    , detailedTxPos     :: !Word32
    } deriving (Show, Eq, Ord)

data DetailedInput
    = DetailedCoinbase { detInOutPoint  :: !OutPoint
                       , detInSequence  :: !Word32
                       , detInSigScript :: !ByteString }
    | DetailedInput { detInOutPoint  :: !OutPoint
                    , detInSequence  :: !Word32
                    , detInSigScript :: !ByteString
                    , detInPkScript  :: !ByteString
                    , detInValue     :: !Word64
                    , detInBlock     :: !BlockRef
                    , detInPos       :: !Word32 }
    deriving (Show, Eq, Ord)

isCoinbase :: DetailedInput -> Bool
isCoinbase DetailedCoinbase {} = True
isCoinbase _                   = False

data DetailedOutput = DetailedOutput
    { detOutValue   :: !Word64
    , detOutScript  :: !ByteString
    , detOutSpender :: !(Maybe Spender)
    } deriving (Show, Eq, Ord)

data AddressBalance = AddressBalance
    { addressBalAddress      :: !Address
    , addressBalConfirmed    :: !Word64
    , addressBalTxCount      :: !Word64
    , addressBalUnspentCount :: !Word64
    , addressBalSpentCount   :: !Word64
    } deriving (Show, Eq, Ord)

data TxRecord = TxRecord
    { txValueBlock    :: !BlockRef
    , txPos           :: !Word32
    , txValue         :: !Tx
    , txValuePrevOuts :: [(OutPoint, PrevOut)]
    } deriving (Show, Eq, Ord)

newtype OutputKey = OutputKey
    { outPoint :: OutPoint
    } deriving (Show, Eq, Ord)

data PrevOut = PrevOut
    { prevOutValue  :: !Word64
    , prevOutBlock  :: !BlockRef
    , prevOutPos    :: !Word32
    , prevOutScript :: !ByteString
    } deriving (Show, Eq, Ord)

data Output = Output
    { outputValue :: !Word64
    , outBlock    :: !BlockRef
    , outPos      :: !Word32
    , outScript   :: !ByteString
    , outSpender  :: !(Maybe Spender)
    } deriving (Show, Eq, Ord)

outputToPrevOut :: Output -> PrevOut
outputToPrevOut Output {..} =
    PrevOut
    { prevOutValue = outputValue
    , prevOutBlock = outBlock
    , prevOutPos = outPos
    , prevOutScript = outScript
    }

prevOutToOutput :: PrevOut -> Output
prevOutToOutput PrevOut {..} =
    Output
    { outputValue = prevOutValue
    , outBlock = prevOutBlock
    , outPos = prevOutPos
    , outScript = prevOutScript
    , outSpender = Nothing
    }

data Spender = Spender
    { spenderHash  :: !TxHash
    , spenderIndex :: !Word32
    , spenderBlock :: !BlockRef
    , spenderPos   :: !Word32
    } deriving (Show, Eq, Ord)

newtype BaseTxKey =
    BaseTxKey TxHash
    deriving (Show, Eq, Ord)

data MultiTxKey
    = MultiTxKey !TxKey
    | MultiTxKeyOutput !OutputKey
    deriving (Show, Eq, Ord)

data MultiTxValue
    = MultiTx !TxRecord
    | MultiTxOutput !Output
    deriving (Show, Eq, Ord)

newtype TxKey =
    TxKey TxHash
    deriving (Show, Eq, Ord)

newtype BlockKey =
    BlockKey BlockHash
    deriving (Show, Eq, Ord)

newtype HeightKey =
    HeightKey BlockHeight
    deriving (Show, Eq, Ord)

newtype BalanceKey = BalanceKey
    { balanceAddress :: Address
    } deriving (Show, Eq, Ord)

data Balance = Balance
    { balanceValue       :: !Word64
    , balanceTxCount     :: !Word64
    , balanceOutputCount :: !Word64
    , balanceSpentCount  :: !Word64
    } deriving (Show, Eq, Ord)

data BestBlockKey = BestBlockKey deriving (Show, Eq, Ord)

data AddressTx
    = AddressTxIn { addressTxAddress :: !Address
                  , addressTxId      :: !TxHash
                  , addressTxAmount  :: !Int64
                  , addressTxBlock   :: !BlockRef
                  , addressTxPos     :: !Word32
                  , addressTxVin     :: !Word32 }
    | AddressTxOut { addressTxAddress :: !Address
                   , addressTxId      :: !TxHash
                   , addressTxAmount  :: !Int64
                   , addressTxBlock   :: !BlockRef
                   , addressTxPos     :: !Word32
                   , addressTxVout    :: !Word32 }
    deriving (Eq, Show)

instance Ord AddressTx where
    compare = compare `on` f
      where
        f AddressTxIn {..}  = (blockRefHeight addressTxBlock, addressTxPos, False)
        f AddressTxOut {..} = (blockRefHeight addressTxBlock, addressTxPos, True)

data Unspent = Unspent
    { unspentAddress  :: !Address
    , unspentPkScript :: !ByteString
    , unspentTxId     :: !TxHash
    , unspentIndex    :: !Word32
    , unspentValue    :: !Word64
    , unspentBlock    :: !BlockRef
    , unspentPos      :: !Word32
    } deriving (Eq, Show)

instance Ord Unspent where
    compare = compare `on` f
      where
        f Unspent {..} = (blockRefHeight unspentBlock, unspentPos, unspentIndex)

instance Record BlockKey BlockValue
instance Record TxKey TxRecord
instance Record HeightKey BlockHash
instance Record BestBlockKey BlockHash
instance Record OutputKey Output
instance Record MultiTxKey MultiTxValue
instance Record AddrOutputKey Output
instance Record BalanceKey Balance
instance MultiRecord MultiAddrOutputKey AddrOutputKey Output
instance MultiRecord BaseTxKey MultiTxKey MultiTxValue

instance Serialize BalanceKey where
    put BalanceKey {..} = do
        putWord8 0x04
        put balanceAddress
    get = do
        guard . (== 0x04) =<< getWord8
        balanceAddress <- get
        return BalanceKey {..}

instance Serialize Balance where
    put Balance {..} = do
        put balanceValue
        put balanceTxCount
        put balanceOutputCount
        put balanceSpentCount
    get = do
        balanceValue <- get
        balanceTxCount <- get
        balanceOutputCount <- get
        balanceSpentCount <- get
        return Balance {..}

instance Serialize AddrOutputKey where
    put AddrOutputKey {..} = do
        if addrOutputSpent
            then putWord8 0x03
            else putWord8 0x05
        put addrOutputAddress
        put (maxBound - addrOutputHeight)
        put addrOutPoint
    get = do
        addrOutputSpent <-
            getWord8 >>= \case
                0x03 -> return True
                0x05 -> return False
                _ -> mzero
        addrOutputAddress <- get
        addrOutputHeight <- (maxBound -) <$> get
        addrOutPoint <- get
        return AddrOutputKey {..}

instance Serialize MultiAddrOutputKey where
    put MultiAddrOutputKey {..} = do
        if multiAddrOutputSpent
            then putWord8 0x03
            else putWord8 0x05
        put multiAddrOutputAddress
    get = do
        multiAddrOutputSpent <-
            getWord8 >>= \case
                0x03 -> return True
                0x05 -> return False
                _ -> mzero
        multiAddrOutputAddress <- get
        return MultiAddrOutputKey {..}

instance Serialize MultiTxKey where
    put (MultiTxKey k)       = put k
    put (MultiTxKeyOutput k) = put k
    get = (MultiTxKey <$> get) <|> (MultiTxKeyOutput <$> get)

instance Serialize MultiTxValue where
    put (MultiTx v)       = put v
    put (MultiTxOutput v) = put v
    get = (MultiTx <$> get) <|> (MultiTxOutput <$> get)

instance Serialize BaseTxKey where
    put (BaseTxKey k) = do
        putWord8 0x02
        put k
    get = do
        guard . (== 0x02) =<< getWord8
        k <- get
        return (BaseTxKey k)

instance Serialize Spender where
    put Spender {..} = do
        put spenderHash
        put spenderIndex
        put spenderBlock
        put spenderPos
    get = do
        spenderHash <- get
        spenderIndex <- get
        spenderBlock <- get
        spenderPos <- get
        return Spender {..}

instance Serialize OutputKey where
    put OutputKey {..} = do
        putWord8 0x02
        put (outPointHash outPoint)
        putWord8 0x01
        put (outPointIndex outPoint)
    get = do
        guard . (== 0x02) =<< getWord8
        outPointHash <- get
        guard . (== 0x01) =<< getWord8
        outPointIndex <- get
        let outPoint = OutPoint {..}
        return OutputKey {..}

instance Serialize PrevOut where
    put PrevOut {..} = do
        put prevOutValue
        put prevOutBlock
        put prevOutPos
        put prevOutScript
    get = do
        prevOutValue <- get
        prevOutBlock <- get
        prevOutPos <- get
        prevOutScript <- get
        return PrevOut {..}

instance Serialize Output where
    put Output {..} = do
        putWord8 0x01
        put outputValue
        put outBlock
        put outPos
        put outScript
        put outSpender
    get = do
        guard . (== 0x01) =<< getWord8
        outputValue <- get
        outBlock <- get
        outPos <- get
        outScript <- get
        outSpender <- get
        return Output {..}

instance Serialize BlockRef where
    put BlockRef {..} = do
        put blockRefHash
        put blockRefHeight
        put blockRefMainChain
    get = do
        blockRefHash <- get
        blockRefHeight <- get
        blockRefMainChain <- get
        return BlockRef {..}

instance Serialize TxRecord where
    put TxRecord {..} = do
        putWord8 0x00
        put txValueBlock
        put txPos
        put txValue
        put txValuePrevOuts
    get = do
        guard . (== 0x00) =<< getWord8
        txValueBlock <- get
        txPos <- get
        txValue <- get
        txValuePrevOuts <- get
        return TxRecord {..}

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

instance ToJSON Spender where
    toJSON = object . spenderPairs
    toEncoding = pairs . mconcat . spenderPairs

blockRefPairs :: KeyValue kv => BlockRef -> [kv]
blockRefPairs BlockRef {..} =
    if blockRefMainChain
        then ["block" .= blockRefHash, "height" .= blockRefHeight]
        else []

spenderPairs :: KeyValue kv => Spender -> [kv]
spenderPairs Spender {..} =
    ["txid" .= spenderHash, "vin" .= spenderIndex, "pos" .= spenderPos] ++
    blockRefPairs spenderBlock

scriptAddress :: KeyValue kv => ByteString -> [kv]
scriptAddress bs =
    case scriptToAddressBS bs of
        Nothing   -> []
        Just addr -> ["address" .= addr]

detailedOutputPairs :: KeyValue kv => DetailedOutput -> [kv]
detailedOutputPairs DetailedOutput {..} =
    [ "value" .= detOutValue
    , "pkscript" .= String (cs (encodeHex detOutScript))
    , "spent" .= isJust detOutSpender
    ] ++
    scriptAddress detOutScript ++
    case detOutSpender of
        Nothing      -> []
        Just spender -> spenderPairs spender

instance ToJSON DetailedOutput where
    toJSON = object . detailedOutputPairs
    toEncoding = pairs . mconcat . detailedOutputPairs

detailedInputPairs :: KeyValue kv => DetailedInput -> [kv]
detailedInputPairs DetailedInput {..} =
    [ "txid" .= outPointHash detInOutPoint
    , "vout" .= outPointIndex detInOutPoint
    , "coinbase" .= False
    , "sequence" .= detInSequence
    , "sigscript" .= String (cs (encodeHex detInSigScript))
    , "pkscript" .= String (cs (encodeHex detInPkScript))
    , "value" .= detInValue
    , "pos" .= detInPos
    ] ++
    scriptAddress detInPkScript ++ blockRefPairs detInBlock
detailedInputPairs DetailedCoinbase {..} =
    [ "txid" .= outPointHash detInOutPoint
    , "vout" .= outPointIndex detInOutPoint
    , "coinbase" .= True
    , "sequence" .= detInSequence
    , "sigscript" .= String (cs (encodeHex detInSigScript))
    ]

instance ToJSON DetailedInput where
    toJSON = object . detailedInputPairs
    toEncoding = pairs . mconcat . detailedInputPairs

detailedTxPairs :: KeyValue kv => DetailedTx -> [kv]
detailedTxPairs DetailedTx {..} =
    [ "txid" .= txHash detailedTxData
    , "size" .= BS.length (S.encode detailedTxData)
    , "version" .= txVersion detailedTxData
    , "locktime" .= txLockTime detailedTxData
    , "fee" .= detailedTxFee
    , "vin" .= detailedTxInputs
    , "vout" .= detailedTxOutputs
    , "hex" .= String (cs (encodeHex (S.encode detailedTxData)))
    , "pos" .= detailedTxPos
    ] ++ blockRefPairs detailedTxBlock

instance ToJSON DetailedTx where
    toJSON = object . detailedTxPairs
    toEncoding = pairs . mconcat . detailedTxPairs

instance ToJSON BlockRef where
    toJSON = object . blockRefPairs
    toEncoding = pairs . mconcat . blockRefPairs

addrTxPairs :: KeyValue kv => AddressTx -> [kv]
addrTxPairs AddressTxIn {..} =
    [ "address" .= addressTxAddress
    , "txid" .= addressTxId
    , "amount" .= addressTxAmount
    , "vin" .= addressTxVin
    , "pos" .= addressTxPos
    ] ++
    blockRefPairs addressTxBlock
addrTxPairs AddressTxOut {..} =
    [ "address" .= addressTxAddress
    , "txid" .= addressTxId
    , "amount" .= addressTxAmount
    , "vout" .= addressTxVout
    , "pos" .= addressTxPos
    ] ++
    blockRefPairs addressTxBlock

instance ToJSON AddressTx where
    toJSON = object . addrTxPairs
    toEncoding = pairs . mconcat . addrTxPairs

unspentPairs :: KeyValue kv => Unspent -> [kv]
unspentPairs Unspent {..} =
    [ "address" .= unspentAddress
    , "pkscript" .= String (cs (encodeHex unspentPkScript))
    , "txid" .= unspentTxId
    , "vout" .= unspentIndex
    , "value" .= unspentValue
    , "pos" .= unspentPos
    ] ++
    blockRefPairs unspentBlock

instance ToJSON Unspent where
    toJSON = object . unspentPairs
    toEncoding = pairs . mconcat . unspentPairs

addressBalancePairs :: KeyValue kv => AddressBalance -> [kv]
addressBalancePairs AddressBalance {..} =
    [ "address" .= addressBalAddress
    , "confirmed" .= addressBalConfirmed
    , "transactions" .= addressBalTxCount
    , "unspent" .= addressBalUnspentCount
    , "spent" .= addressBalSpentCount
    ]

instance FromJSON NewTx where
    parseJSON = withObject "Transaction" $ \v -> NewTx <$> v .: "transaction"

instance ToJSON SentTx where
    toJSON (SentTx txid) = object ["txid" .= txid]
    toEncoding (SentTx txid) = pairs ("txid" .= txid)

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
    , storeConfManager    :: !Manager
    , storeConfChain      :: !Chain
    , storeConfListener   :: !(Listen StoreEvent)
    , storeConfMaxPeers   :: !Int
    , storeConfInitPeers  :: ![HostPort]
    , storeConfDiscover   :: !Bool
    , storeConfCacheNo    :: !Word32
    , storeConfBlockNo    :: !Word32
    , storeConfDB         :: !DB
    }
