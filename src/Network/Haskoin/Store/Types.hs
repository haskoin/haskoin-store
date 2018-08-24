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
import           Data.Aeson                  as A
import           Data.ByteString             (ByteString)
import qualified Data.ByteString             as BS
import           Data.Function
import           Data.Int
import           Data.Maybe
import           Data.Serialize              as S
import           Data.String.Conversions
import           Data.Word
import           Database.RocksDB            (DB)
import           Database.RocksDB.Query      as R
import           Network.Haskoin.Block
import           Network.Haskoin.Crypto
import           Network.Haskoin.Node
import           Network.Haskoin.Script
import           Network.Haskoin.Transaction
import           Network.Haskoin.Util

data TxException
    = DoubleSpend
    | OverSpend
    | OrphanTx
    | NonStandard
    | LowFee
    | Dust
    | NoPeers
    | InvalidTx
    | CouldNotImport
    | PeerIsGone
    | AlreadyImported
    | PublishTimeout
    | PeerRejectOther
    | NotAtHeight
    deriving (Eq)

instance Show TxException where
    show InvalidTx       = "invalid"
    show DoubleSpend     = "double-spend"
    show OverSpend       = "not enough funds"
    show OrphanTx        = "orphan"
    show AlreadyImported = "already imported"
    show NoPeers         = "no peers"
    show NonStandard     = "non-standard"
    show LowFee          = "low fee"
    show Dust            = "dust"
    show PeerIsGone      = "peer disconnected"
    show CouldNotImport  = "could not import"
    show PublishTimeout  = "publish timeout"
    show PeerRejectOther = "peer rejected for unknown reason"
    show NotAtHeight     = "not at height"

instance Exception TxException

newtype NewTx = NewTx
    { newTx :: Tx
    } deriving (Show, Eq, Ord)

data BlockConfig = BlockConfig
    { blockConfMailbox  :: !BlockStore
    , blockConfManager  :: !Manager
    , blockConfChain    :: !Chain
    , blockConfListener :: !(Listen StoreEvent)
    , blockConfDB       :: !DB
    }

data StoreEvent
    = BestBlock !BlockHash
    | MempoolNew !TxHash
    | TxException !TxHash
                  !TxException
    | PeerConnected !Peer
    | PeerDisconnected !Peer

data BlockMessage
    = BlockChainNew !BlockNode
    | BlockPeerConnect !Peer
    | BlockPeerDisconnect !Peer
    | BlockReceived !Peer
                    !Block
    | BlockNotReceived !Peer
                       !BlockHash
    | TxReceived !Peer
                 !Tx
    | TxAvailable !Peer
                  ![TxHash]
    | PongReceived !Peer
                   !Word64

type BlockStore = Inbox BlockMessage

data AddrOutputKey
    = AddrOutputKey { addrOutputSpent   :: !Bool
                    , addrOutputAddress :: !Address
                    , addrOutputHeight  :: !(Maybe BlockHeight)
                    , addrOutPoint      :: !OutPoint }
    | MultiAddrOutputKey { addrOutputSpent   :: !Bool
                         , addrOutputAddress :: !Address }
    deriving (Show, Eq, Ord)

data BlockValue = BlockValue
    { blockValueHeight :: !BlockHeight
    , blockValueWork   :: !BlockWork
    , blockValueHeader :: !BlockHeader
    , blockValueSize   :: !Word32
    , blockValueTxs    :: ![TxHash]
    } deriving (Show, Eq, Ord)

data BlockRef = BlockRef
    { blockRefHash   :: !BlockHash
    , blockRefHeight :: !BlockHeight
    , blockRefPos    :: !Word32
    } deriving (Show, Eq)

instance Ord BlockRef where
    compare = compare `on` f
      where
        f BlockRef {..} = (blockRefHeight, blockRefPos)

data DetailedTx = DetailedTx
    { detailedTxData    :: !Tx
    , detailedTxFee     :: !Word64
    , detailedTxInputs  :: ![DetailedInput]
    , detailedTxOutputs :: ![DetailedOutput]
    , detailedTxBlock   :: !(Maybe BlockRef)
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
                    , detInBlock     :: !(Maybe BlockRef) }
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
    { addressBalAddress     :: !Address
    , addressBalConfirmed   :: !Word64
    , addressBalUnconfirmed :: !Int64
    , addressOutputCount    :: !Word64
    , addressSpentCount     :: !Word64
    } deriving (Show, Eq, Ord)

data TxRecord = TxRecord
    { txValueBlock    :: !(Maybe BlockRef)
    , txValue         :: !Tx
    , txValuePrevOuts :: [(OutPoint, PrevOut)]
    } deriving (Show, Eq, Ord)

newtype OutputKey = OutputKey
    { outPoint :: OutPoint
    } deriving (Show, Eq, Ord)

data PrevOut = PrevOut
    { prevOutValue  :: !Word64
    , prevOutBlock  :: !(Maybe BlockRef)
    , prevOutScript :: !ByteString
    } deriving (Show, Eq, Ord)

data Output = Output
    { outputValue :: !Word64
    , outBlock    :: !(Maybe BlockRef)
    , outScript   :: !ByteString
    , outSpender  :: !(Maybe Spender)
    } deriving (Show, Eq, Ord)

outputToPrevOut :: Output -> PrevOut
outputToPrevOut Output {..} =
    PrevOut
    { prevOutValue = outputValue
    , prevOutBlock = outBlock
    , prevOutScript = outScript
    }

prevOutToOutput :: PrevOut -> Output
prevOutToOutput PrevOut {..} =
    Output
    { outputValue = prevOutValue
    , outBlock = prevOutBlock
    , outScript = prevOutScript
    , outSpender = Nothing
    }

data Spender = Spender
    { spenderHash  :: !TxHash
    , spenderIndex :: !Word32
    , spenderBlock :: !(Maybe BlockRef)
    } deriving (Show, Eq, Ord)

data MultiTxKey
    = MultiTxKey !TxKey
    | MultiTxKeyOutput !OutputKey
    | BaseTxKey !TxHash
    deriving (Show, Eq, Ord)

data MultiTxValue
    = MultiTx !TxRecord
    | MultiTxOutput !Output
    deriving (Show, Eq, Ord)

newtype TxKey =
    TxKey TxHash
    deriving (Show, Eq, Ord)

data MempoolTx
    = MempoolTx TxHash
    | MempoolKey
    deriving (Show, Eq, Ord)

data OrphanTx
    = OrphanTxKey TxHash
    | OrphanKey
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
    , balanceUnconfirmed :: !Int64
    , balanceOutputCount :: !Word64
    , balanceSpentCount  :: !Word64
    } deriving (Show, Eq, Ord)

emptyBalance :: Balance
emptyBalance =
    Balance
    { balanceValue = 0
    , balanceUnconfirmed = 0
    , balanceOutputCount = 0
    , balanceSpentCount = 0
    }

data BestBlockKey = BestBlockKey deriving (Show, Eq, Ord)

data AddressTx
    = AddressTxIn { addressTxPkScript :: !ByteString
                  , addressTxId       :: !TxHash
                  , addressTxAmount   :: !Int64
                  , addressTxBlock    :: !(Maybe BlockRef)
                  , addressTxVin      :: !Word32 }
    | AddressTxOut { addressTxPkScript :: !ByteString
                   , addressTxId       :: !TxHash
                   , addressTxAmount   :: !Int64
                   , addressTxBlock    :: !(Maybe BlockRef)
                   , addressTxVout     :: !Word32 }
    deriving (Eq, Show)

instance Ord AddressTx where
    compare = compare `on` f
        -- Transactions in mempool should be greater than those in a block.
        -- Outputs must be greater than inputs.
      where
        f AddressTxIn {..} = (isNothing addressTxBlock, addressTxBlock, False)
        f AddressTxOut {..} = (isNothing addressTxBlock, addressTxBlock, True)

data Unspent = Unspent
    { unspentPkScript :: !ByteString
    , unspentTxId     :: !TxHash
    , unspentIndex    :: !Word32
    , unspentValue    :: !Word64
    , unspentBlock    :: !(Maybe BlockRef)
    } deriving (Eq, Show)

instance Ord Unspent where
    compare = compare `on` f
        -- Transactions in mempool should be greater than those in a block
      where
        f Unspent {..} = (isNothing unspentBlock, unspentBlock, unspentIndex)

instance Key BlockKey
instance Key HeightKey
instance Key OutputKey
instance Key TxKey
instance Key MempoolTx
instance Key AddrOutputKey
instance R.KeyValue BlockKey BlockValue
instance R.KeyValue TxKey TxRecord
instance R.KeyValue HeightKey BlockHash
instance R.KeyValue BestBlockKey BlockHash
instance R.KeyValue OutputKey Output
instance R.KeyValue MultiTxKey MultiTxValue
instance R.KeyValue AddrOutputKey Output
instance R.KeyValue BalanceKey Balance
instance R.KeyValue MempoolTx ()
instance R.KeyValue OrphanTx Tx

instance Serialize MempoolTx where
    put (MempoolTx h) = do
        putWord8 0x07
        put h
    put MempoolKey = putWord8 0x07
    get = do
        guard . (== 0x07) =<< getWord8
        record <|> return MempoolKey
      where
        record = do
            h <- get
            return (MempoolTx h)

instance Serialize OrphanTx where
    put (OrphanTxKey h) = do
        putWord8 0x08
        put h
    put OrphanKey = putWord8 0x08
    get = do
        guard . (== 0x08) =<< getWord8
        record <|> return OrphanKey
      where
        record = do
            h <- get
            return (OrphanTxKey h)

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
        put balanceUnconfirmed
        put balanceOutputCount
        put balanceSpentCount
    get = do
        balanceValue <- get
        balanceUnconfirmed <- get
        balanceOutputCount <- get
        balanceSpentCount <- get
        return Balance {..}

instance Serialize AddrOutputKey where
    put AddrOutputKey {..} = do
        if addrOutputSpent
            then putWord8 0x03
            else putWord8 0x05
        put addrOutputAddress
        put (maxBound - fromMaybe 0 addrOutputHeight)
        put addrOutPoint
    put MultiAddrOutputKey {..} = do
        if addrOutputSpent
            then putWord8 0x03
            else putWord8 0x05
        put addrOutputAddress
    get = do
        addrOutputSpent <-
            getWord8 >>= \case
                0x03 -> return True
                0x05 -> return False
                _ -> mzero
        addrOutputAddress <- get
        record addrOutputSpent addrOutputAddress <|>
            return MultiAddrOutputKey {..}
      where
        record addrOutputSpent addrOutputAddress = do
            h <- (maxBound -) <$> get
            let addrOutputHeight =
                    if h == maxBound
                        then Nothing
                        else Just h
            addrOutPoint <- get
            return AddrOutputKey {..}

instance Serialize MultiTxKey where
    put (MultiTxKey k)       = put k
    put (MultiTxKeyOutput k) = put k
    put (BaseTxKey k)        = putWord8 0x02 >> put k
    get = MultiTxKey <$> get <|> MultiTxKeyOutput <$> get <|> base
      where
        base = do
            guard . (== 0x02) =<< getWord8
            k <- get
            return (BaseTxKey k)

instance Serialize MultiTxValue where
    put (MultiTx v)       = put v
    put (MultiTxOutput v) = put v
    get = (MultiTx <$> get) <|> (MultiTxOutput <$> get)

instance Serialize Spender where
    put Spender {..} = do
        put spenderHash
        put spenderIndex
        put spenderBlock
    get = do
        spenderHash <- get
        spenderIndex <- get
        spenderBlock <- get
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
        put (BS.length prevOutScript)
        putByteString prevOutScript
    get = do
        prevOutValue <- get
        prevOutBlock <- get
        prevOutScript <- getByteString =<< get
        return PrevOut {..}

instance Serialize Output where
    put Output {..} = do
        putWord8 0x01
        put outputValue
        put outBlock
        put outScript
        put outSpender
    get = do
        guard . (== 0x01) =<< getWord8
        outputValue <- get
        outBlock <- get
        outScript <- get
        outSpender <- get
        return Output {..}

instance Serialize BlockRef where
    put BlockRef {..} = do
        put blockRefHash
        put blockRefHeight
        put blockRefPos
    get = do
        blockRefHash <- get
        blockRefHeight <- get
        blockRefPos <- get
        return BlockRef {..}

instance Serialize TxRecord where
    put TxRecord {..} = do
        putWord8 0x00
        put txValueBlock
        put txValue
        put txValuePrevOuts
    get = do
        guard . (== 0x00) =<< getWord8
        txValueBlock <- get
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
        put blockValueTxs
    get = do
        blockValueHeight <- get
        blockValueWork <- get
        blockValueHeader <- get
        blockValueSize <- get
        blockValueTxs <- get
        return BlockValue {..}

blockValuePairs :: A.KeyValue kv => BlockValue -> [kv]
blockValuePairs BlockValue {..} =
    [ "hash" .= headerHash blockValueHeader
    , "height" .= blockValueHeight
    , "previous" .= prevBlock blockValueHeader
    , "time" .= blockTimestamp blockValueHeader
    , "version" .= blockVersion blockValueHeader
    , "bits" .= blockBits blockValueHeader
    , "nonce" .= bhNonce blockValueHeader
    , "size" .= blockValueSize
    , "tx" .= blockValueTxs
    ]

instance ToJSON BlockValue where
    toJSON = object . blockValuePairs
    toEncoding = pairs . mconcat . blockValuePairs

instance ToJSON Spender where
    toJSON = object . spenderPairs
    toEncoding = pairs . mconcat . spenderPairs

blockRefPairs :: A.KeyValue kv => BlockRef -> [kv]
blockRefPairs BlockRef {..} =
    [ "hash" .= blockRefHash
    , "height" .= blockRefHeight
    , "position" .= blockRefPos
    ]

spenderPairs :: A.KeyValue kv => Spender -> [kv]
spenderPairs Spender {..} =
    ["txid" .= spenderHash, "input" .= spenderIndex, "block" .= spenderBlock]

detailedOutputPairs :: A.KeyValue kv => DetailedOutput -> [kv]
detailedOutputPairs DetailedOutput {..} =
    [ "address" .= scriptToAddressBS detOutScript
    , "pkscript" .= String (cs (encodeHex detOutScript))
    , "value" .= detOutValue
    , "spent" .= isJust detOutSpender
    , "spender" .= detOutSpender
    ]

instance ToJSON DetailedOutput where
    toJSON = object . detailedOutputPairs
    toEncoding = pairs . mconcat . detailedOutputPairs

detailedInputPairs :: A.KeyValue kv => DetailedInput -> [kv]
detailedInputPairs DetailedInput {..} =
    [ "txid" .= outPointHash detInOutPoint
    , "output" .= outPointIndex detInOutPoint
    , "coinbase" .= False
    , "sequence" .= detInSequence
    , "sigscript" .= String (cs (encodeHex detInSigScript))
    , "pkscript" .= String (cs (encodeHex detInPkScript))
    , "address" .= scriptToAddressBS detInPkScript
    , "value" .= detInValue
    , "block" .= detInBlock
    ]
detailedInputPairs DetailedCoinbase {..} =
    [ "txid" .= outPointHash detInOutPoint
    , "output" .= outPointIndex detInOutPoint
    , "coinbase" .= True
    , "sequence" .= detInSequence
    , "sigscript" .= String (cs (encodeHex detInSigScript))
    , "pkscript" .= Null
    , "address" .= Null
    , "value" .= Null
    , "block" .= Null
    ]

instance ToJSON DetailedInput where
    toJSON = object . detailedInputPairs
    toEncoding = pairs . mconcat . detailedInputPairs

detailedTxPairs :: A.KeyValue kv => DetailedTx -> [kv]
detailedTxPairs DetailedTx {..} =
    [ "txid" .= txHash detailedTxData
    , "size" .= BS.length (S.encode detailedTxData)
    , "version" .= txVersion detailedTxData
    , "locktime" .= txLockTime detailedTxData
    , "fee" .= detailedTxFee
    , "inputs" .= detailedTxInputs
    , "outputs" .= detailedTxOutputs
    , "hex" .= String (cs (encodeHex (S.encode detailedTxData)))
    , "block" .= detailedTxBlock
    ]

instance ToJSON DetailedTx where
    toJSON = object . detailedTxPairs
    toEncoding = pairs . mconcat . detailedTxPairs

instance ToJSON BlockRef where
    toJSON = object . blockRefPairs
    toEncoding = pairs . mconcat . blockRefPairs

addrTxPairs :: A.KeyValue kv => AddressTx -> [kv]
addrTxPairs AddressTxIn {..} =
    [ "address" .= scriptToAddressBS addressTxPkScript
    , "pkscript" .= String (cs (encodeHex addressTxPkScript))
    , "txid" .= addressTxId
    , "input" .= addressTxVin
    , "amount" .= addressTxAmount
    , "block" .= addressTxBlock
    ]
addrTxPairs AddressTxOut {..} =
    [ "address" .= scriptToAddressBS addressTxPkScript
    , "pkscript" .= String (cs (encodeHex addressTxPkScript))
    , "txid" .= addressTxId
    , "output" .= addressTxVout
    , "amount" .= addressTxAmount
    , "block" .= addressTxBlock
    ]

instance ToJSON AddressTx where
    toJSON = object . addrTxPairs
    toEncoding = pairs . mconcat . addrTxPairs

unspentPairs :: A.KeyValue kv => Unspent -> [kv]
unspentPairs Unspent {..} =
    [ "address" .= scriptToAddressBS unspentPkScript
    , "pkscript" .= String (cs (encodeHex unspentPkScript))
    , "txid" .= unspentTxId
    , "output" .= unspentIndex
    , "value" .= unspentValue
    , "block" .= unspentBlock
    ]

instance ToJSON Unspent where
    toJSON = object . unspentPairs
    toEncoding = pairs . mconcat . unspentPairs

addressBalancePairs :: A.KeyValue kv => AddressBalance -> [kv]
addressBalancePairs AddressBalance {..} =
    [ "address" .= addressBalAddress
    , "confirmed" .= addressBalConfirmed
    , "unconfirmed" .= addressBalUnconfirmed
    , "outputs" .= addressOutputCount
    , "utxo" .= (addressOutputCount - addressSpentCount)
    ]

instance FromJSON NewTx where
    parseJSON = withObject "transaction" $ \v -> NewTx <$> v .: "transaction"

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

type StoreSupervisor n = Inbox (SupervisorMessage n)

data StoreConfig n = StoreConfig
    { storeConfBlocks     :: !BlockStore
    , storeConfSupervisor :: !(StoreSupervisor n)
    , storeConfManager    :: !Manager
    , storeConfChain      :: !Chain
    , storeConfPublisher  :: !(Publisher Inbox StoreEvent)
    , storeConfMaxPeers   :: !Int
    , storeConfInitPeers  :: ![HostPort]
    , storeConfDiscover   :: !Bool
    , storeConfDB         :: !DB
    }
