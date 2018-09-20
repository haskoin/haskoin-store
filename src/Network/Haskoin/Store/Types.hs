{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
module Network.Haskoin.Store.Types where

import           Control.Applicative
import           Control.Exception
import           Control.Monad.Reader
import           Data.Aeson              as A
import           Data.ByteString         (ByteString)
import qualified Data.ByteString         as B
import           Data.Function
import           Data.Hashable
import           Data.Int
import           Data.Maybe
import           Data.Serialize          as S
import           Data.String.Conversions
import           Data.Word
import           Database.RocksDB        (DB)
import           Database.RocksDB.Query  as R
import           Haskoin
import           Haskoin.Node
import           Network.Socket
import           NQE

-- | Reasons why a transaction may not get imported.
data TxException
    = DoubleSpend
      -- ^ outputs already spent by another transaction
    | OverSpend
      -- ^ outputs larger than inputs
    | OrphanTx
      -- ^ inputs unknown
    | NonStandard
      -- ^ non-standard transaction rejected by peer
    | LowFee
      -- ^ pony up
    | Dust
      -- ^ an output is too small
    | NoPeers
      -- ^ no peers to send the transaction to
    | InvalidTx
      -- ^ transaction is invalid in some other way
    | CouldNotImport
      -- ^ could not import for an unknown reason
    | PeerIsGone
      -- ^ the peer that got the transaction disconnected
    | AlreadyImported
      -- ^ the transaction is already in the database
    | PublishTimeout
      -- ^ some timeout was reached while publishing
    | PeerRejectOther
      -- ^ peer rejected transaction for unknown reason
    | NotAtHeight
      -- ^ this node is not yet synchronized
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

-- | Wrapper for an transaction that can be deserialized from a JSON object.
newtype NewTx = NewTx
    { newTx :: Tx
    } deriving (Show, Eq, Ord)

-- | Configuration for a block store.
data BlockConfig = BlockConfig
    { blockConfMailbox   :: !BlockStore
      -- ^ block store mailbox
    , blockConfManager   :: !Manager
      -- ^ peer manager from running node
    , blockConfChain     :: !Chain
      -- ^ chain from a running node
    , blockConfListener  :: !(Listen StoreEvent)
      -- ^ listener for store events
    , blockConfDB        :: !DB
      -- ^ RocksDB database handle
    , blockConfUnspentDB :: !(Maybe DB)
      -- ^ database for unspent outputs & balances
    , blockConfNet       :: !Network
      -- ^ network constants
    }

-- | Event that the store can generate.
data StoreEvent
    = BestBlock !BlockHash
      -- ^ new best block
    | MempoolNew !TxHash
      -- ^ new mempool transaction
    | TxException !TxHash
                  !TxException
      -- ^ published tx could not be imported
    | PeerConnected !Peer
      -- ^ new peer connected
    | PeerDisconnected !Peer
      -- ^ peer has disconnected
    | PeerPong !Peer
               !Word64
      -- ^ peer responded 'Ping'

-- | Messages that a 'BlockStore' can accept.
data BlockMessage
    = BlockChainNew !BlockNode
      -- ^ new block header in chain
    | BlockPeerConnect !Peer
      -- ^ new peer connected
    | BlockPeerDisconnect !Peer
      -- ^ peer disconnected
    | BlockReceived !Peer
                    !Block
      -- ^ new block received from a peer
    | BlockNotReceived !Peer
                       !BlockHash
      -- ^ peer could not deliver a block
    | TxReceived !Peer
                 !Tx
      -- ^ transaction received from a peer
    | TxAvailable !Peer
                  ![TxHash]
      -- ^ peer has transactions available
    | TxPublished !Tx
      -- ^ transaction has been published successfully
    | PongReceived !Peer
                   !Word64
      -- ^ peer responded to a 'Ping'

-- | Mailbox for block store.
type BlockStore = Inbox BlockMessage

-- | Database key for an address transaction.
data AddrTxKey
    = AddrTxKey { addrTxKey    :: !Address
                , addrTxHeight :: !(Maybe BlockHeight)
                , addrTxPos    :: !(Maybe Word32)
                , addrTxHash   :: !TxHash }
      -- ^ key for a transaction affecting an address
    | ShortAddrTxKey { addrTxKey :: !Address }
    | ShortAddrTxKeyHeight { addrTxKey    :: !Address
                           , addrTxHeight :: !(Maybe BlockHeight) }
      -- ^ short key that matches all entries
    deriving (Show, Eq)

data AddrTx = AddrTx
    { getAddrTxAddr  :: !Address
    , getAddrTxHash  :: !TxHash
    , getAddrTxBlock :: !(Maybe BlockRef)
    } deriving (Eq, Show, Read)

instance Ord AddrTx where
    compare = compare `on` f
      where
        f a = case getAddrTxBlock a of
            Nothing -> (True, Nothing) -- Mempool transactions are "highest"
            Just b  -> (False, Just b)

-- | Database key for an address output.
data AddrOutKey
    = AddrOutKey { addrOutputAddress :: !Address
                 , addrOutputHeight  :: !(Maybe BlockHeight)
                 , addrOutputPos     :: !(Maybe Word32)
                 , addrOutPoint      :: !OutPoint }
      -- ^ full key
    | ShortAddrOutKey { addrOutputAddress :: !Address }
      -- ^ short key for all spent or unspent outputs
    | ShortAddrOutKeyHeight { addrOutputAddress :: !Address
                            , addrOutputHeight  :: !(Maybe BlockHeight) }
      -- ^ short key for all outputs at a given height
    deriving (Show, Eq)

instance Ord AddrOutKey where
    compare = compare `on` f
      where
        f AddrOutKey {..} =
            ( fromMaybe maxBound addrOutputHeight
            , fromMaybe maxBound addrOutputPos
            , outPointIndex addrOutPoint)
        f _ = undefined

-- | Database value for a block entry.
data BlockValue = BlockValue
    { blockValueHeight :: !BlockHeight
      -- ^ height of the block in the chain
    , blockValueWork   :: !BlockWork
      -- ^ accumulated work in that block
    , blockValueHeader :: !BlockHeader
      -- ^ block header
    , blockValueSize   :: !Word32
      -- ^ size of the block including witnesses
    , blockValueTxs    :: ![TxHash]
      -- ^ block transactions
    } deriving (Show, Eq, Ord)

-- | Reference to a block where a transaction is stored.
data BlockRef = BlockRef
    { blockRefHash   :: !BlockHash
      -- ^ block header hash
    , blockRefHeight :: !BlockHeight
      -- ^ block height in the chain
    , blockRefPos    :: !Word32
      -- ^ position of transaction within the block
    } deriving (Show, Read, Eq)

instance Ord BlockRef where
    compare = compare `on` f
      where
        f BlockRef {..} = (blockRefHeight, blockRefPos)

-- | Detailed transaction information.
data DetailedTx = DetailedTx
    { detailedTxData    :: !Tx
      -- ^ 'Tx' object
    , detailedTxFee     :: !Word64
      -- ^ transaction fees paid to miners in satoshi
    , detailedTxInputs  :: ![DetailedInput]
      -- ^ transaction inputs
    , detailedTxOutputs :: ![DetailedOutput]
      -- ^ transaction outputs
    , detailedTxBlock   :: !(Maybe BlockRef)
      -- ^ block information for this transaction
    } deriving (Show, Eq)

-- | Input information.
data DetailedInput
    = DetailedCoinbase { detInOutPoint  :: !OutPoint
                         -- ^ output being spent (should be zeroes)
                       , detInSequence  :: !Word32
                         -- ^ sequence
                       , detInSigScript :: !ByteString
                         -- ^ input script data (not valid script)
                       , detInNetwork   :: !Network
                         -- ^ network constants
                       }
    -- ^ coinbase input details
    | DetailedInput { detInOutPoint  :: !OutPoint
                      -- ^ output being spent
                    , detInSequence  :: !Word32
                      -- ^ sequence
                    , detInSigScript :: !ByteString
                      -- ^ signature (input) script
                    , detInPkScript  :: !ByteString
                      -- ^ pubkey (output) script from previous tx
                    , detInValue     :: !Word64
                      -- ^ amount in satoshi being spent spent
                    , detInBlock     :: !(Maybe BlockRef)
                      -- ^ block where this input is found
                    , detInNetwork   :: !Network
                      -- ^ network constants
                    }
    -- ^ regular input details
    deriving (Show, Eq)

data PeerInformation
    = PeerInformation { userAgent :: !ByteString
                      , address   :: !SockAddr
                      , version   :: !Word32
                      , services  :: !Word64
                      , relay     :: !Bool
                      }
    deriving (Show, Eq)

isCoinbase :: DetailedInput -> Bool
isCoinbase DetailedCoinbase {} = True
isCoinbase _                   = False

-- | Output information.
data DetailedOutput = DetailedOutput
    { detOutValue   :: !Word64
      -- ^ amount in satoshi
    , detOutScript  :: !ByteString
      -- ^ pubkey (output) script
    , detOutSpender :: !(Maybe Spender)
      -- ^ input spending this transaction
    , detOutNetwork :: !Network
      -- ^ network constants
    } deriving (Show, Eq)

-- | Address balance information.
data AddressBalance = AddressBalance
    { addressBalAddress     :: !Address
      -- ^ address balance
    , addressBalConfirmed   :: !Word64
      -- ^ confirmed balance
    , addressBalUnconfirmed :: !Int64
      -- ^ unconfirmed balance (can be negative)
    , addressUtxoCount      :: !Word64
      -- ^ number of unspent outputs
    } deriving (Show, Eq)

-- | Transaction record in database.
data TxRecord = TxRecord
    { txValueBlock    :: !(Maybe BlockRef)
      -- ^ block information
    , txValue         :: !Tx
      -- ^ transaction data
    , txValuePrevOuts :: [(OutPoint, PrevOut)]
      -- ^ previous output information
    } deriving (Show, Eq, Ord)

-- | Output key in database.
data OutputKey
    = OutputKey { outPoint :: !OutPoint }
    | ShortOutputKey
    deriving (Show, Eq, Ord)

instance Hashable OutputKey where
    hashWithSalt s (OutputKey (OutPoint h i)) = hashWithSalt s (h, i)
    hashWithSalt s ShortOutputKey             = hashWithSalt s ()

-- | All unspent outputs.
data UnspentKey
    = UnspentKey { unspentKey :: !OutPoint }
    | ShortUnspentKey
    deriving (Show, Eq, Ord)

-- | Previous output data.
data PrevOut = PrevOut
    { prevOutValue  :: !Word64
      -- ^ value of output in satoshi
    , prevOutBlock  :: !(Maybe BlockRef)
      -- ^ block information for spent output
    , prevOutScript :: !ByteString
      -- ^ pubkey (output) script
    } deriving (Show, Eq, Ord)

-- | Output data.
data Output = Output
    { outputValue :: !Word64
      -- ^ value of output in satoshi
    , outBlock    :: !(Maybe BlockRef)
      -- ^ block information for output
    , outScript   :: !ByteString
      -- ^ pubkey (output) script
    , outSpender  :: !(Maybe Spender)
      -- ^ input spending this output
    } deriving (Show, Eq, Ord)

-- | Prepare previous output.
outputToPrevOut :: Output -> PrevOut
outputToPrevOut Output {..} =
    PrevOut
    { prevOutValue = outputValue
    , prevOutBlock = outBlock
    , prevOutScript = outScript
    }

-- | Convert previous output to unspent output.
prevOutToOutput :: PrevOut -> Output
prevOutToOutput PrevOut {..} =
    Output
    { outputValue = prevOutValue
    , outBlock = prevOutBlock
    , outScript = prevOutScript
    , outSpender = Nothing
    }

-- | Information about input spending output.
data Spender = Spender
    { spenderHash  :: !TxHash
      -- ^ input transaction hash
    , spenderIndex :: !Word32
      -- ^ input position in transaction
    , spenderBlock :: !(Maybe BlockRef)
      -- ^ block information
    } deriving (Show, Eq, Ord)

-- | Aggregate key for transactions and outputs.
data MultiTxKey
    = MultiTxKey !TxKey
      -- ^ key for transaction
    | MultiTxOutKey !OutputKey
      -- ^ key for output
    | ShortMultiTxKey !TxHash
      -- ^ short key that matches all
    deriving (Show, Eq, Ord)

-- | Aggregate database key for transactions and outputs.
data MultiTxValue
    = MultiTx !TxRecord
      -- ^ transaction record
    | MultiTxOutput !Output
      -- ^ records for all outputs
    deriving (Show, Eq, Ord)

-- | Transaction database key.
newtype TxKey =
    TxKey TxHash
    deriving (Show, Eq, Ord)

-- | Mempool transaction database key.
data MempoolKey
    = MempoolKey TxHash
      -- ^ key for a mempool transaction
    | ShortMempoolKey
      -- ^ short key that matches all
    deriving (Show, Eq, Ord)

-- | Orphan transaction database key.
data OrphanKey
    = OrphanKey TxHash
      -- ^ key for an orphan transaction
    | ShortOrphanKey
      -- ^ short key that matches all
    deriving (Show, Eq, Ord)

-- | Block entry database key.
newtype BlockKey =
    BlockKey BlockHash
    deriving (Show, Eq, Ord)

-- | Block height database key.
newtype HeightKey =
    HeightKey BlockHeight
    deriving (Show, Eq, Ord)

-- | Address balance database key.
data BalanceKey
    = BalanceKey { balanceAddress :: !Address }
    | ShortBalanceKey
    deriving (Show, Eq)

instance Hashable BalanceKey where
    hashWithSalt s b = hashWithSalt s (S.encode b)

-- | Address balance database value.
data Balance = Balance
    { balanceValue       :: !Word64
      -- ^ balance in satoshi
    , balanceUnconfirmed :: !Int64
      -- ^ unconfirmed balance in satoshi (can be negative)
    , balanceUtxoCount   :: !Word64
      -- ^ number of unspent outputs
    } deriving (Show, Eq, Ord)

-- | Default balance for an address.
emptyBalance :: Balance
emptyBalance =
    Balance
    { balanceValue = 0
    , balanceUnconfirmed = 0
    , balanceUtxoCount = 0
    }

-- | Key for best block in database.
data BestBlockKey = BestBlockKey deriving (Show, Eq, Ord)

-- | Address output.
data AddrOutput = AddrOutput
    { addrOutputKey :: !AddrOutKey
    , addrOutput    :: !Output
    } deriving (Eq, Show)

instance Ord AddrOutput where
    compare = compare `on` addrOutputKey

-- | Serialization format for addresses in database.
newtype StoreAddress = StoreAddress Address
    deriving (Show, Eq)

instance Key BestBlockKey
         -- 0x00
instance Key BlockKey
         -- 0x01 · BlockHash
instance Key TxKey
         -- 0x02 · TxHash · 0x00
instance Key OutputKey
         -- 0x02 · TxHash · 0x01 · OutputIndex
         -- 0x02
instance Key MultiTxKey
         -- 0x02 · TxHash
         -- 0x02 · TxHash · 0x00
         -- 0x02 · TxHash · 0x01 · OutputIndex
instance Key HeightKey
         -- 0x03 · InvBlockHeight
instance Key BalanceKey
         -- 0x04 · Storeaddress
         -- 0x04
instance Key AddrTxKey
         -- 0x05 · StoreAddress · InvBlockHeight · InvBlockPos
         -- 0x05 · StoreAddress · InvBlockHeight
         -- 0x05 · StoreAddress
instance Key AddrOutKey
         -- 0x06 · StoreAddress · InvBlockHeight · InvBlockPos
         -- 0x06 · StoreAddress · InvBlockHeight
         -- 0x06 · StoreAddress
instance Key MempoolKey
         -- 0x07 · TxHash
         -- 0x07
instance Key OrphanKey
         -- 0x08 · TxHash
         -- 0x08
instance Key UnspentKey
         -- 0x09 · OutPoint
         -- 0x09

instance R.KeyValue   BestBlockKey    BlockHash
instance R.KeyValue   BlockKey        BlockValue
instance R.KeyValue   TxKey           TxRecord
instance R.KeyValue   AddrOutKey      Output
instance R.KeyValue   MultiTxKey      MultiTxValue
instance R.KeyValue   HeightKey       BlockHash
instance R.KeyValue   BalanceKey      Balance
instance R.KeyValue   AddrTxKey       (Maybe BlockHash)
instance R.KeyValue   OutputKey       Output
instance R.KeyValue   UnspentKey      Output
instance R.KeyValue   MempoolKey      ()
instance R.KeyValue   OrphanKey       Tx

instance Serialize MempoolKey where
    put (MempoolKey h) = do
        putWord8 0x07
        put h
    put ShortMempoolKey = putWord8 0x07
    get = do
        guard . (== 0x07) =<< getWord8
        MempoolKey <$> get

instance Serialize OrphanKey where
    put (OrphanKey h) = do
        putWord8 0x08
        put h
    put ShortOrphanKey = putWord8 0x08
    get = do
        guard . (== 0x08) =<< getWord8
        OrphanKey <$> get

instance Serialize BalanceKey where
    put BalanceKey {..} = do
        putWord8 0x04
        put (StoreAddress balanceAddress)
    put ShortBalanceKey = putWord8 0x04
    get = do
        guard . (== 0x04) =<< getWord8
        StoreAddress balanceAddress <- get
        return BalanceKey {..}

instance Serialize Balance where
    put Balance {..} = do
        put balanceValue
        put balanceUnconfirmed
        put balanceUtxoCount
    get = do
        balanceValue <- get
        balanceUnconfirmed <- get
        balanceUtxoCount <- get
        return Balance {..}

instance Serialize AddrTxKey where
    put AddrTxKey {..} = do
        putWord8 0x05
        put $ StoreAddress addrTxKey
        put (maybe 0 (maxBound -) addrTxHeight)
        put (maybe 0 (maxBound -) addrTxPos)
        put addrTxHash
    put ShortAddrTxKey {..} = do
        putWord8 0x05
        put $ StoreAddress addrTxKey
    put ShortAddrTxKeyHeight {..} = do
        putWord8 0x05
        put $ StoreAddress addrTxKey
        put (maybe 0 (maxBound -) addrTxHeight)
    get = do
        guard . (== 0x05) =<< getWord8
        StoreAddress addrTxKey <- get
        h <- (maxBound -) <$> get
        let addrTxHeight
                | h == 0 = Nothing
                | otherwise = Just h
        p <- (maxBound -) <$> get
        let addrTxPos
                | p == 0 = Nothing
                | otherwise = Just p
        addrTxHash <- get
        return AddrTxKey {..}

-- | Beginning of address output database key.
addrKeyStart :: Address -> Put
addrKeyStart a = put (StoreAddress a)

instance Serialize AddrOutKey where
    put AddrOutKey {..} = do
        putWord8 0x06
        put $ StoreAddress addrOutputAddress
        put (maybe 0 (maxBound -) addrOutputHeight)
        put (maybe 0 (maxBound -) addrOutputPos)
        put addrOutPoint
    put ShortAddrOutKey {..} = do
        putWord8 0x06
        put $ StoreAddress addrOutputAddress
    put ShortAddrOutKeyHeight {..} = do
        putWord8 0x06
        put $ StoreAddress addrOutputAddress
        put (maybe 0 (maxBound -) addrOutputHeight)
    get = do
        guard . (== 0x06) =<< getWord8
        StoreAddress addrOutputAddress <- get
        record addrOutputAddress
      where
        record addrOutputAddress = do
            h <- (maxBound -) <$> get
            let addrOutputHeight | h == 0 = Nothing
                                 | otherwise = Just h
            p <- (maxBound -) <$> get
            let addrOutputPos | p == 0 = Nothing
                              | otherwise = Just p
            addrOutPoint <- get
            return AddrOutKey {..}

instance Serialize MultiTxKey where
    put (MultiTxKey k)      = put k
    put (MultiTxOutKey k)   = put k
    put (ShortMultiTxKey k) = putWord8 0x02 >> put k
    get = MultiTxKey <$> get <|> MultiTxOutKey <$> get

instance Serialize MultiTxValue where
    put (MultiTx v)       = put v
    put (MultiTxOutput v) = put v
    get = MultiTx <$> get <|> MultiTxOutput <$> get

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
    put ShortOutputKey = putWord8 0x02
    get = do
        guard . (== 0x02) =<< getWord8
        outPointHash <- get
        guard . (== 0x01) =<< getWord8
        outPointIndex <- get
        let outPoint = OutPoint {..}
        return OutputKey {..}

instance Serialize UnspentKey where
    put UnspentKey {..} = do
        putWord8 0x09
        put unspentKey
    put ShortUnspentKey = putWord8 0x09
    get = do
        guard . (== 0x09) =<< getWord8
        UnspentKey <$> get

instance Serialize PrevOut where
    put PrevOut {..} = do
        put prevOutValue
        put prevOutBlock
        put (B.length prevOutScript)
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
    put BestBlockKey = put (B.replicate 32 0x00)
    get = do
        guard . (== B.replicate 32 0x00) =<< getBytes 32
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

-- | Byte identifying network for an address.
netByte :: Network -> Word8
netByte net | net == btc        = 0x00
            | net == btcTest    = 0x01
            | net == btcRegTest = 0x02
            | net == bch        = 0x04
            | net == bchTest    = 0x05
            | net == bchRegTest = 0x06
            | otherwise         = 0xff

-- | Network from its corresponding byte.
byteNet :: Word8 -> Maybe Network
byteNet 0x00 = Just btc
byteNet 0x01 = Just btcTest
byteNet 0x02 = Just btcRegTest
byteNet 0x04 = Just bch
byteNet 0x05 = Just bchTest
byteNet 0x06 = Just bchRegTest
byteNet _    = Nothing

-- | Deserializer for network byte.
getByteNet :: Get Network
getByteNet =
    byteNet <$> getWord8 >>= \case
        Nothing -> fail "Could not decode network byte"
        Just net -> return net

instance Serialize StoreAddress where
    put (StoreAddress addr)
        | isPubKeyAddress addr = do
            putWord8 0x01
            putWord8 (netByte (getAddrNet addr))
            put (getAddrHash160 addr)
        | isScriptAddress addr = do
            putWord8 0x02
            putWord8 (netByte (getAddrNet addr))
            put (getAddrHash160 addr)
        | isWitnessPubKeyAddress addr = do
            putWord8 0x03
            putWord8 (netByte (getAddrNet addr))
            put (getAddrHash160 addr)
        | isWitnessScriptAddress addr = do
            putWord8 0x04
            putWord8 (netByte (getAddrNet addr))
            put (getAddrHash256 addr)
        | otherwise = undefined
    get = fmap StoreAddress $ pk <|> sa <|> wa <|> ws
      where
        pk = do
            guard . (== 0x01) =<< getWord8
            net <- getByteNet
            p2pkhAddr net <$> get
        sa = do
            guard . (== 0x02) =<< getWord8
            net <- getByteNet
            p2shAddr net <$> get
        wa = do
            guard . (== 0x03) =<< getWord8
            net <- getByteNet
            h <- get
            maybe mzero return (p2wpkhAddr net h)
        ws = do
            guard . (== 0x04) =<< getWord8
            net <- getByteNet
            h <- get
            maybe mzero return (p2wshAddr net h)

-- | JSON serialization for 'BlockValue'.
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

-- | JSON serialization for 'BlockRef'.
blockRefPairs :: A.KeyValue kv => BlockRef -> [kv]
blockRefPairs BlockRef {..} =
    [ "hash" .= blockRefHash
    , "height" .= blockRefHeight
    , "position" .= blockRefPos
    ]

-- | JSON serialization for 'Spender'.
spenderPairs :: A.KeyValue kv => Spender -> [kv]
spenderPairs Spender {..} =
    ["txid" .= spenderHash, "input" .= spenderIndex, "block" .= spenderBlock]

-- | JSON serialization for a 'DetailedOutput'.
detailedOutputPairs :: A.KeyValue kv => DetailedOutput -> [kv]
detailedOutputPairs DetailedOutput {..} =
    [ "address" .= scriptToAddressBS detOutNetwork detOutScript
    , "pkscript" .= String (encodeHex detOutScript)
    , "value" .= detOutValue
    , "spent" .= isJust detOutSpender
    , "spender" .= detOutSpender
    ]

addrTxPairs :: A.KeyValue kv => AddrTx -> [kv]
addrTxPairs AddrTx {..} =
    [ "address" .= getAddrTxAddr
    , "txid" .= getAddrTxHash
    , "block" .= getAddrTxBlock
    ]

instance ToJSON AddrTx where
    toJSON = object . addrTxPairs
    toEncoding = pairs . mconcat . addrTxPairs

instance ToJSON DetailedOutput where
    toJSON = object . detailedOutputPairs
    toEncoding = pairs . mconcat . detailedOutputPairs

-- | JSON serialization for 'PeerInformation'.
peerInformationPairs :: A.KeyValue kv => PeerInformation -> [kv]
peerInformationPairs PeerInformation {..} =
    [ "useragent"   .= String (cs userAgent)
    , "address"     .= String (cs (show address))
    , "version"     .= version
    , "services"    .= services
    , "relay"       .= relay
    ]

instance ToJSON PeerInformation where
    toJSON = object . peerInformationPairs
    toEncoding = pairs . mconcat . peerInformationPairs


-- | JSON serialization for 'DetailedInput'.
detailedInputPairs :: A.KeyValue kv => DetailedInput -> [kv]
detailedInputPairs DetailedInput {..} =
    [ "txid" .= outPointHash detInOutPoint
    , "output" .= outPointIndex detInOutPoint
    , "coinbase" .= False
    , "sequence" .= detInSequence
    , "sigscript" .= String (encodeHex detInSigScript)
    , "pkscript" .= String (encodeHex detInPkScript)
    , "address" .= scriptToAddressBS detInNetwork detInPkScript
    , "value" .= detInValue
    , "block" .= detInBlock
    ]
detailedInputPairs DetailedCoinbase {..} =
    [ "txid" .= outPointHash detInOutPoint
    , "output" .= outPointIndex detInOutPoint
    , "coinbase" .= True
    , "sequence" .= detInSequence
    , "sigscript" .= String (encodeHex detInSigScript)
    , "pkscript" .= Null
    , "address" .= Null
    , "value" .= Null
    , "block" .= Null
    ]

instance ToJSON DetailedInput where
    toJSON = object . detailedInputPairs
    toEncoding = pairs . mconcat . detailedInputPairs

-- | JSON serialization for 'DetailedTx'.
detailedTxPairs :: A.KeyValue kv => DetailedTx -> [kv]
detailedTxPairs DetailedTx {..} =
    [ "txid" .= txHash detailedTxData
    , "size" .= B.length (S.encode detailedTxData)
    , "version" .= txVersion detailedTxData
    , "locktime" .= txLockTime detailedTxData
    , "fee" .= detailedTxFee
    , "inputs" .= detailedTxInputs
    , "outputs" .= detailedTxOutputs
    , "hex" .= String (encodeHex (S.encode detailedTxData))
    , "block" .= detailedTxBlock
    ]

instance ToJSON DetailedTx where
    toJSON = object . detailedTxPairs
    toEncoding = pairs . mconcat . detailedTxPairs

instance ToJSON BlockRef where
    toJSON = object . blockRefPairs
    toEncoding = pairs . mconcat . blockRefPairs

-- | JSON serialization for 'AddrOutput'.
addrOutputPairs :: A.KeyValue kv => AddrOutput -> [kv]
addrOutputPairs AddrOutput {..} =
    [ "address" .= addrOutputAddress
    , "txid" .= outPointHash addrOutPoint
    , "index" .= outPointIndex addrOutPoint
    , "block" .= outBlock
    , "output" .= dout
    ]
  where
    Output {..} = addrOutput
    AddrOutKey {..} = addrOutputKey
    dout =
        DetailedOutput
            { detOutValue = outputValue
            , detOutScript = outScript
            , detOutSpender = outSpender
            , detOutNetwork = getAddrNet addrOutputAddress
            }

instance ToJSON AddrOutput where
    toJSON = object . addrOutputPairs
    toEncoding = pairs . mconcat . addrOutputPairs

-- | JSON serialization for 'AddressBalance'.
addressBalancePairs :: A.KeyValue kv => AddressBalance -> [kv]
addressBalancePairs AddressBalance {..} =
    [ "address" .= addressBalAddress
    , "confirmed" .= addressBalConfirmed
    , "unconfirmed" .= addressBalUnconfirmed
    , "utxo" .= addressUtxoCount
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
    put (BlockKey h) = do
        putWord8 0x01
        put h
    get = do
        guard . (== 0x01) =<< getWord8
        BlockKey <$> get

instance Serialize TxKey where
    put (TxKey h) = do
        putWord8 0x02
        put h
        putWord8 0x00
    get = do
        guard . (== 0x02) =<< getWord8
        h <- get
        guard . (== 0x00) =<< getWord8
        return (TxKey h)

-- | Configuration for a 'Store'.
data StoreConfig = StoreConfig
    { storeConfMaxPeers  :: !Int
      -- ^ max peers to connect to
    , storeConfInitPeers :: ![HostPort]
      -- ^ static set of peers to connect to
    , storeConfDiscover  :: !Bool
      -- ^ discover new peers?
    , storeConfDB        :: !DB
      -- ^ RocksDB database handler
    , storeConfUnspentDB :: !(Maybe DB)
      -- ^ RocksDB memory database handler for unspent outputs
    , storeConfNetwork   :: !Network
      -- ^ network constants
    }

-- | Store mailboxes.
data Store = Store
    { storeManager   :: !Manager
      -- ^ peer manager mailbox
    , storeChain     :: !Chain
      -- ^ chain header process mailbox
    , storeBlock     :: !BlockStore
      -- ^ block storage mailbox
    , storePublisher :: !(Publisher StoreEvent)
      -- ^ store event publisher mailbox
    }
