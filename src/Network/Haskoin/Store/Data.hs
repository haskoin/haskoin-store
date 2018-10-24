{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
module Network.Haskoin.Store.Data where

import           Conduit
import           Data.Aeson              as A
import           Data.ByteString         (ByteString)
import qualified Data.ByteString         as B
import           Data.Hashable
import           Data.Int
import           Data.Maybe
import           Data.Serialize          as S
import           Data.String.Conversions
import           Data.Time.Clock.System
import           Data.Word
import           GHC.Generics
import           Haskoin
import           Network.Socket          (SockAddr)
import           UnliftIO.Exception

type UnixTime = Int64

newtype InitException = IncorrectVersion Word32
    deriving (Show, Read, Eq, Ord, Exception)

class StoreRead r m where
    isInitialized :: r -> m (Either InitException Bool)
    getBestBlock :: r -> m (Maybe BlockHash)
    getBlocksAtHeight :: r -> BlockHeight -> m [BlockHash]
    getBlock :: r -> BlockHash -> m (Maybe BlockData)
    getTransaction :: r -> TxHash -> m (Maybe Transaction)
    getBalance :: r -> Address -> m Balance

class StoreStream r m where
    getMempool :: r -> ConduitT () (PreciseUnixTime, TxHash) m ()
    getAddressUnspents :: r -> Address -> ConduitT () Unspent m ()
    getAddressTxs :: r -> Address -> ConduitT () AddressTx m ()

class StoreWrite w m where
    setInit :: w -> m ()
    setBest :: w -> BlockHash -> m ()
    insertBlock :: w -> BlockData -> m ()
    insertAtHeight :: w -> BlockHash -> BlockHeight -> m ()
    insertTx :: w -> Transaction -> m ()
    setBalance :: w -> Balance -> m ()
    insertAddrTx :: w -> AddressTx -> m ()
    removeAddrTx :: w -> AddressTx -> m ()
    insertAddrUnspent :: w -> Address -> Unspent -> m ()
    removeAddrUnspent :: w -> Address -> Unspent -> m ()
    insertMempoolTx :: w -> TxHash -> PreciseUnixTime -> m ()
    deleteMempoolTx :: w -> TxHash -> PreciseUnixTime -> m ()

-- | Unix time with nanosecond precision for mempool transactions
newtype PreciseUnixTime = PreciseUnixTime Word64
    deriving (Show, Eq, Read, Generic, Ord, Hashable, Serialize)

preciseUnixTime :: SystemTime -> PreciseUnixTime
preciseUnixTime s =
    PreciseUnixTime . fromIntegral $
    (systemSeconds s * 1000) +
    (fromIntegral (systemNanoseconds s) `div` (1000 * 1000))

instance ToJSON PreciseUnixTime where
    toJSON (PreciseUnixTime w) = toJSON w
    toEncoding (PreciseUnixTime w) = toEncoding w

-- | Reference to a block where a transaction is stored.
data BlockRef
    = BlockRef { blockRefHeight :: !BlockHeight
      -- ^ block height in the chain
               , blockRefPos    :: !Word32
      -- ^ position of transaction within the block
                }
    | MemRef { memRefTime :: !PreciseUnixTime }
    deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable)

-- | JSON serialization for 'BlockRef'.
blockRefPairs :: A.KeyValue kv => BlockRef -> [kv]
blockRefPairs BlockRef {blockRefHeight = h, blockRefPos = p} =
    ["height" .= h, "position" .= p]
blockRefPairs MemRef {memRefTime = t} = ["mempool" .= t]

confirmed :: BlockRef -> Bool
confirmed BlockRef {} = True
confirmed MemRef {}   = False

instance ToJSON BlockRef where
    toJSON = object . blockRefPairs
    toEncoding = pairs . mconcat . blockRefPairs

-- | Transaction in relation to an address.
data AddressTx = AddressTx
    { addressTxAddress :: !Address
      -- ^ transaction address
    , addressTxBlock   :: !BlockRef
      -- ^ block information
    , addressTxHash    :: !TxHash
      -- ^ transaction hash
    } deriving (Show, Eq, Ord, Generic, Serialize, Hashable)

-- | JSON serialization for 'AddressTx'.
addressTxPairs :: A.KeyValue kv => Network -> AddressTx -> [kv]
addressTxPairs net atx =
    [ "address" .= addrToJSON net (addressTxAddress atx)
    , "txid" .= addressTxHash atx
    , "block" .= addressTxBlock atx
    ]

addressTxToJSON :: Network -> AddressTx -> Value
addressTxToJSON net = object . addressTxPairs net

addressTxToEncoding :: Network -> AddressTx -> Encoding
addressTxToEncoding net = pairs . mconcat . addressTxPairs net

-- | Address balance information.
data Balance = Balance
    { balanceAddress :: !Address
      -- ^ address balance
    , balanceAmount  :: !Word64
      -- ^ confirmed balance
    , balanceZero    :: !Int64
      -- ^ unconfirmed balance (can be negative)
    , balanceCount   :: !Word64
      -- ^ number of unspent outputs
    } deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable)

-- | JSON serialization for 'Balance'.
balancePairs :: A.KeyValue kv => Network -> Balance -> [kv]
balancePairs net ab =
    [ "address" .= addrToJSON net (balanceAddress ab)
    , "confirmed" .= balanceAmount ab
    , "unconfirmed" .= balanceZero ab
    , "utxo" .= balanceCount ab
    ]

balanceToJSON :: Network -> Balance -> Value
balanceToJSON net = object . balancePairs net

balanceToEncoding :: Network -> Balance -> Encoding
balanceToEncoding net = pairs . mconcat . balancePairs net

-- | Unspent output.
data Unspent = Unspent
    { unspentBlock  :: !BlockRef
      -- ^ block information for output
    , unspentAmount :: !Word64
      -- ^ value of output in satoshi
    , unspentScript :: !ByteString
      -- ^ pubkey (output) script
    , unspentPoint  :: !OutPoint
      -- ^ txid and index where output located
    } deriving (Show, Eq, Ord, Generic, Serialize, Hashable)

unspentPairs :: A.KeyValue kv => Network -> Unspent -> [kv]
unspentPairs net u =
    [ "address" .=
      eitherToMaybe (addrToJSON net <$> scriptToAddressBS (unspentScript u))
    , "block" .= unspentBlock u
    , "txid" .= outPointHash (unspentPoint u)
    , "index" .= outPointIndex (unspentPoint u)
    , "pkscript" .= String (encodeHex (unspentScript u))
    , "value" .= unspentAmount u
    ]

unspentToJSON :: Network -> Unspent -> Value
unspentToJSON net = object . unspentPairs net

unspentToEncoding :: Network -> Unspent -> Encoding
unspentToEncoding net = pairs . mconcat . unspentPairs net

-- | Database value for a block entry.
data BlockData = BlockData
    { blockDataHeight    :: !BlockHeight
      -- ^ height of the block in the chain
    , blockDataMainChain :: !Bool
      -- ^ is this block in the main chain?
    , blockDataWork      :: !BlockWork
      -- ^ accumulated work in that block
    , blockDataHeader    :: !BlockHeader
      -- ^ block header
    , blockDataSize      :: !Word32
      -- ^ size of the block including witnesses
    , blockDataTxs       :: ![TxHash]
      -- ^ block transactions
    } deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable)

-- | JSON serialization for 'BlockData'.
blockDataPairs :: A.KeyValue kv => BlockData -> [kv]
blockDataPairs bv =
    [ "hash" .= headerHash (blockDataHeader bv)
    , "height" .= blockDataHeight bv
    , "mainchain" .= blockDataMainChain bv
    , "previous" .= prevBlock (blockDataHeader bv)
    , "time" .= blockTimestamp (blockDataHeader bv)
    , "version" .= blockVersion (blockDataHeader bv)
    , "bits" .= blockBits (blockDataHeader bv)
    , "nonce" .= bhNonce (blockDataHeader bv)
    , "size" .= blockDataSize bv
    , "tx" .= blockDataTxs bv
    ]

instance ToJSON BlockData where
    toJSON = object . blockDataPairs
    toEncoding = pairs . mconcat . blockDataPairs

-- | Input information.
data Input
    = Coinbase { inputPoint     :: !OutPoint
                 -- ^ output being spent (should be null)
               , inputSequence  :: !Word32
                 -- ^ sequence
               , inputSigScript :: !ByteString
                 -- ^ input script data (not valid script)
               , inputWitness   :: !(Maybe WitnessStack)
                 -- ^ witness data for this input (only segwit)
                }
    -- ^ coinbase details
    | Input { inputPoint     :: !OutPoint
              -- ^ output being spent
            , inputSequence  :: !Word32
              -- ^ sequence
            , inputSigScript :: !ByteString
              -- ^ signature (input) script
            , inputPkScript  :: !ByteString
              -- ^ pubkey (output) script from previous tx
            , inputAmount    :: !Word64
              -- ^ amount in satoshi being spent spent
            , inputWitness   :: !(Maybe WitnessStack)
              -- ^ witness data for this input (only segwit)
             }
    -- ^ input details
    deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable)

-- | Is 'Input' a Coinbase?
isCoinbase :: Input -> Bool
isCoinbase Coinbase {} = True
isCoinbase Input {}    = False

-- | JSON serialization for 'Input'.
inputPairs :: A.KeyValue kv => Network -> Input -> [kv]
inputPairs net Input { inputPoint = OutPoint oph opi
                     , inputSequence = sq
                     , inputSigScript = ss
                     , inputPkScript = ps
                     , inputAmount = val
                     , inputWitness = wit
                     } =
    [ "coinbase" .= False
    , "txid" .= oph
    , "output" .= opi
    , "sigscript" .= String (encodeHex ss)
    , "sequence" .= sq
    , "pkscript" .= String (encodeHex ps)
    , "value" .= val
    , "address" .= eitherToMaybe (addrToJSON net <$> scriptToAddressBS ps)
    ] ++
    ["witness" .= fmap (map encodeHex) wit | getSegWit net]
inputPairs net Coinbase { inputPoint = OutPoint oph opi
                        , inputSequence = sq
                        , inputSigScript = ss
                        , inputWitness = wit
                        } =
    [ "coinbase" .= False
    , "txid" .= oph
    , "output" .= opi
    , "sigscript" .= String (encodeHex ss)
    , "sequence" .= sq
    , "pkscript" .= Null
    , "value" .= Null
    , "address" .= Null
    ] ++
    ["witness" .= fmap (map encodeHex) wit | getSegWit net]

inputToJSON :: Network -> Input -> Value
inputToJSON net = object . inputPairs net

inputToEncoding :: Network -> Input -> Encoding
inputToEncoding net = pairs . mconcat . inputPairs net

-- | Information about input spending output.
data Spender = Spender
    { spenderHash  :: !TxHash
      -- ^ input transaction hash
    , spenderIndex :: !Word32
      -- ^ input position in transaction
    } deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable)

-- | JSON serialization for 'Spender'.
spenderPairs :: A.KeyValue kv => Spender -> [kv]
spenderPairs n =
    ["txid" .= spenderHash n, "input" .= spenderIndex n]

instance ToJSON Spender where
    toJSON = object . spenderPairs
    toEncoding = pairs . mconcat . spenderPairs

-- | Output information.
data Output = Output
    { outputAmount  :: !Word64
      -- ^ amount in satoshi
    , outputScript  :: !ByteString
      -- ^ pubkey (output) script
    , outputSpender :: !(Maybe Spender)
      -- ^ input spending this transaction
    } deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable)

-- | JSON serialization for 'Output'.
outputPairs :: A.KeyValue kv => Network -> Output -> [kv]
outputPairs net d =
    [ "address" .=
      eitherToMaybe (addrToJSON net <$> scriptToAddressBS (outputScript d))
    , "pkscript" .= String (encodeHex (outputScript d))
    , "value" .= outputAmount d
    , "spent" .= isJust (outputSpender d)
    ] ++
    ["spender" .= outputSpender d | isJust (outputSpender d)]

outputToJSON :: Network -> Output -> Value
outputToJSON net = object . outputPairs net

outputToEncoding :: Network -> Output -> Encoding
outputToEncoding net = pairs . mconcat . outputPairs net

-- | Detailed transaction information.
data Transaction = Transaction
    { transactionBlock     :: !BlockRef
      -- ^ block information for this transaction
    , transactionVersion   :: !Word32
      -- ^ transaction version
    , transactionLockTime  :: !Word32
      -- ^ lock time
    , transactionFee       :: !Word64
      -- ^ transaction fees paid to miners in satoshi
    , transactionInputs    :: ![Input]
      -- ^ transaction inputs
    , transactionOutputs   :: ![Output]
      -- ^ transaction outputs
    , transactionDeleted   :: !Bool
      -- ^ this transaction has been deleted and is no longer valid
    , transactionRBF       :: !Bool
      -- ^ this transaction can be replaced in the mempool
    } deriving (Show, Eq, Ord, Generic, Hashable, Serialize)

transactionData :: Transaction -> Tx
transactionData t =
    Tx
        { txVersion = transactionVersion t
        , txIn = map i (transactionInputs t)
        , txOut = map o (transactionOutputs t)
        , txWitness = mapMaybe inputWitness (transactionInputs t)
        , txLockTime = transactionLockTime t
        }
  where
    i Coinbase {inputPoint = p, inputSequence = q, inputSigScript = s} =
        TxIn {prevOutput = p, scriptInput = s, txInSequence = q}
    i Input {inputPoint = p, inputSequence = q, inputSigScript = s} =
        TxIn {prevOutput = p, scriptInput = s, txInSequence = q}
    o Output {outputAmount = v, outputScript = s} =
        TxOut {outValue = v, scriptOutput = s}

-- | JSON serialization for 'Transaction'.
transactionPairs :: A.KeyValue kv => Network -> Transaction -> [kv]
transactionPairs net dtx =
    [ "txid" .= txHash (transactionData dtx)
    , "size" .= B.length (S.encode (transactionData dtx))
    , "version" .= transactionVersion dtx
    , "locktime" .= transactionLockTime dtx
    , "fee" .= transactionFee dtx
    , "inputs" .= map (object . inputPairs net) (transactionInputs dtx)
    , "outputs" .= map (object . outputPairs net) (transactionOutputs dtx)
    , "block" .= transactionBlock dtx
    , "deleted" .= transactionDeleted dtx
    ] ++
    ["rbf" .= transactionRBF dtx | getReplaceByFee net]

transactionToJSON :: Network -> Transaction -> Value
transactionToJSON net = object . transactionPairs net

transactionToEncoding :: Network -> Transaction -> Encoding
transactionToEncoding net = pairs . mconcat . transactionPairs net

-- | Information about a connected peer.
data PeerInformation
    = PeerInformation { peerUserAgent :: !ByteString
                        -- ^ user agent string
                      , peerAddress   :: !SockAddr
                        -- ^ network address
                      , peerVersion   :: !Word32
                        -- ^ version number
                      , peerServices  :: !Word64
                        -- ^ services field
                      , peerRelay     :: !Bool
                        -- ^ will relay transactions
                      }
    deriving (Show, Eq, Ord, Generic)

-- | JSON serialization for 'PeerInformation'.
peerInformationPairs :: A.KeyValue kv => PeerInformation -> [kv]
peerInformationPairs p =
    [ "useragent"   .= String (cs (peerUserAgent p))
    , "address"     .= String (cs (show (peerAddress p)))
    , "version"     .= peerVersion p
    , "services"    .= peerServices p
    , "relay"       .= peerRelay p
    ]

instance ToJSON PeerInformation where
    toJSON = object . peerInformationPairs
    toEncoding = pairs . mconcat . peerInformationPairs
