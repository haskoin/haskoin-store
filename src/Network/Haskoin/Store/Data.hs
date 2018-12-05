{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
module Network.Haskoin.Store.Data where

import           Conduit
import           Control.Applicative
import           Control.Monad
import           Control.Monad.Trans.Maybe
import           Data.Aeson                as A
import           Data.ByteString           (ByteString)
import qualified Data.ByteString           as B
import           Data.ByteString.Short     (ShortByteString)
import qualified Data.ByteString.Short     as B.Short
import           Data.Hashable
import           Data.Int
import qualified Data.IntMap               as I
import           Data.IntMap.Strict        (IntMap)
import           Data.Maybe
import           Data.Serialize            as S
import           Data.String.Conversions
import           Data.Time.Clock.System
import           Data.Word
import           GHC.Generics
import           Haskoin
import           Network.Socket            (SockAddr)
import           Paths_haskoin_store       as P
import           UnliftIO.Exception

type UnixTime = Int64

newtype InitException = IncorrectVersion Word32
    deriving (Show, Read, Eq, Ord, Exception)

class Applicative m => UnspentWrite u m where
    addUnspent :: u -> Unspent -> m ()
    delUnspent :: u -> OutPoint -> m ()
    pruneUnspent :: u -> m ()
    pruneUnspent _ = pure ()

class UnspentRead u m where
    getUnspent :: u -> OutPoint -> m (Maybe Unspent)

class Applicative m => BalanceWrite b m where
    setBalance :: b -> Balance -> m ()
    pruneBalance :: b -> m ()
    pruneBalance _ = pure ()

class BalanceRead b m where
    getBalance :: b -> Address -> m (Maybe Balance)

class StoreRead r m where
    isInitialized :: r -> m (Either InitException Bool)
    getBestBlock :: r -> m (Maybe BlockHash)
    getBlocksAtHeight :: r -> BlockHeight -> m [BlockHash]
    getBlock :: r -> BlockHash -> m (Maybe BlockData)
    getTxData :: r -> TxHash -> m (Maybe TxData)
    getSpenders :: r -> TxHash -> m (IntMap Spender)
    getSpender :: r -> OutPoint -> m (Maybe Spender)

getTransaction ::
       (Monad m, StoreRead r m) => r -> TxHash -> m (Maybe Transaction)
getTransaction r h = runMaybeT $ do
    d <- MaybeT $ getTxData r h
    sm <- lift $ getSpenders r h
    return $ toTransaction d sm

class StoreStream r m where
    getMempool ::
           r
        -> Maybe PreciseUnixTime
        -> ConduitT () (PreciseUnixTime, TxHash) m ()
    getAddressUnspents ::
           r -> Address -> Maybe BlockRef -> ConduitT () Unspent m ()
    getAddressTxs ::
           r -> Address -> Maybe BlockRef -> ConduitT () AddressTx m ()

class StoreWrite w m where
    setInit :: w -> m ()
    setBest :: w -> BlockHash -> m ()
    insertBlock :: w -> BlockData -> m ()
    insertAtHeight :: w -> BlockHash -> BlockHeight -> m ()
    insertTx :: w -> TxData -> m ()
    insertSpender :: w -> OutPoint -> Spender -> m ()
    deleteSpender :: w -> OutPoint -> m ()
    insertAddrTx :: w -> AddressTx -> m ()
    removeAddrTx :: w -> AddressTx -> m ()
    insertAddrUnspent :: w -> Address -> Unspent -> m ()
    removeAddrUnspent :: w -> Address -> Unspent -> m ()
    insertMempoolTx :: w -> TxHash -> PreciseUnixTime -> m ()
    deleteMempoolTx :: w -> TxHash -> PreciseUnixTime -> m ()

-- | Unix time with nanosecond precision for mempool transactions.
newtype PreciseUnixTime = PreciseUnixTime Word64
    deriving (Show, Eq, Read, Generic, Ord, Hashable)

-- | Serialize such that ordering is inverted.
instance Serialize PreciseUnixTime where
    put (PreciseUnixTime w) = putWord64be $ maxBound - w
    get = PreciseUnixTime . (maxBound -) <$> getWord64be

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
    deriving (Show, Read, Eq, Ord, Generic, Hashable)

-- | Serialized entities will sort in reverse order.
instance Serialize BlockRef where
    put MemRef {memRefTime = t} = do
        putWord8 0x00
        put t
    put BlockRef {blockRefHeight = h, blockRefPos = p} = do
        putWord8 0x01
        putWord32be (maxBound - h)
        putWord32be (maxBound - p)
    get = getmemref <|> getblockref
      where
        getmemref = do
            guard . (== 0x00) =<< getWord8
            w <- (maxBound -) <$> getWord64be
            return MemRef {memRefTime = PreciseUnixTime w}
        getblockref = do
            guard . (== 0x01) =<< getWord8
            h <- (maxBound -) <$> getWord32be
            p <- (maxBound -) <$> getWord32be
            return BlockRef {blockRefHeight = h, blockRefPos = p}

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
    { balanceAddress       :: !Address
      -- ^ address balance
    , balanceAmount        :: !Word64
      -- ^ confirmed balance
    , balanceZero          :: !Word64
      -- ^ unconfirmed balance
    , balanceUnspentCount  :: !Word64
      -- ^ number of unspent outputs
    , balanceTxCount       :: !Word64
      -- ^ number of transactions
    , balanceTotalReceived :: !Word64
      -- ^ total amount from all outputs in this address
    } deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable)

-- | JSON serialization for 'Balance'.
balancePairs :: A.KeyValue kv => Network -> Balance -> [kv]
balancePairs net ab =
    [ "address" .= addrToJSON net (balanceAddress ab)
    , "confirmed" .= balanceAmount ab
    , "unconfirmed" .= balanceZero ab
    , "utxo" .= balanceUnspentCount ab
    , "txs" .= balanceTxCount ab
    , "received" .= balanceTotalReceived ab
    ]

balanceToJSON :: Network -> Balance -> Value
balanceToJSON net = object . balancePairs net

balanceToEncoding :: Network -> Balance -> Encoding
balanceToEncoding net = pairs . mconcat . balancePairs net

-- | Unspent output.
data Unspent = Unspent
    { unspentBlock  :: !BlockRef
      -- ^ block information for output
    , unspentPoint  :: !OutPoint
      -- ^ txid and index where output located
    , unspentAmount :: !Word64
      -- ^ value of output in satoshi
    , unspentScript :: !ShortByteString
      -- ^ pubkey (output) script
    } deriving (Show, Eq, Ord, Generic, Hashable)

instance Serialize Unspent where
    put u = do
        put $ unspentBlock u
        put $ unspentPoint u
        put $ unspentAmount u
        put $ B.Short.length (unspentScript u)
        putShortByteString $ unspentScript u
    get =
        Unspent <$> get <*> get <*> get <*> (getShortByteString =<< get)

unspentPairs :: A.KeyValue kv => Network -> Unspent -> [kv]
unspentPairs net u =
    [ "address" .=
      eitherToMaybe
          (addrToJSON net <$>
           scriptToAddressBS (B.Short.fromShort (unspentScript u)))
    , "block" .= unspentBlock u
    , "txid" .= outPointHash (unspentPoint u)
    , "index" .= outPointIndex (unspentPoint u)
    , "pkscript" .= String (encodeHex (B.Short.fromShort (unspentScript u)))
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
    , blockDataWeight    :: !Word32
      -- ^ weight of this block (for segwit networks)
    , blockDataTxs       :: ![TxHash]
      -- ^ block transactions
    , blockDataOutputs   :: !Word64
      -- ^ sum of all transaction outputs
    , blockDataFees      :: !Word64
      -- ^ sum of all transaction fees
    , blockDataSubsidy   :: !Word64
      -- ^ block subsidy
    } deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable)

-- | JSON serialization for 'BlockData'.
blockDataPairs :: A.KeyValue kv => Network -> BlockData -> [kv]
blockDataPairs net bv =
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
    , "merkle" .= TxHash (merkleRoot (blockDataHeader bv))
    , "subsidy" .= blockDataSubsidy bv
    , "fees" .= blockDataFees bv
    , "outputs" .= blockDataOutputs bv
    ] ++ ["weight" .= blockDataWeight bv | getSegWit net]

blockDataToJSON :: Network -> BlockData -> Value
blockDataToJSON net = object . blockDataPairs net

blockDataToEncoding :: Network -> BlockData -> Encoding
blockDataToEncoding net = pairs . mconcat . blockDataPairs net

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
    [ "coinbase" .= True
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

data Prev = Prev
    { prevScript :: !ByteString
    , prevAmount :: !Word64
    } deriving (Show, Eq, Ord, Generic, Hashable, Serialize)

toInput :: TxIn -> Maybe Prev -> Maybe WitnessStack -> Input
toInput i Nothing w =
    Coinbase
        { inputPoint = prevOutput i
        , inputSequence = txInSequence i
        , inputSigScript = scriptInput i
        , inputWitness = w
        }
toInput i (Just p) w =
    Input
        { inputPoint = prevOutput i
        , inputSequence = txInSequence i
        , inputSigScript = scriptInput i
        , inputPkScript = prevScript p
        , inputAmount = prevAmount p
        , inputWitness = w
        }

toOutput :: TxOut -> Maybe Spender -> Output
toOutput o s =
    Output
        { outputAmount = outValue o
        , outputScript = scriptOutput o
        , outputSpender = s
        }

data TxData = TxData
    { txDataBlock   :: !BlockRef
    , txData        :: !Tx
    , txDataPrevs   :: !(IntMap Prev)
    , txDataDeleted :: !Bool
    , txDataRBF     :: !Bool
    , txDataTime    :: !Word64
    } deriving (Show, Eq, Ord, Generic, Serialize)

toTransaction :: TxData -> IntMap Spender -> Transaction
toTransaction t sm =
    Transaction
        { transactionBlock = txDataBlock t
        , transactionVersion = txVersion (txData t)
        , transactionLockTime = txLockTime (txData t)
        , transactionInputs = ins
        , transactionOutputs = outs
        , transactionDeleted = txDataDeleted t
        , transactionRBF = txDataRBF t
        , transactionTime = txDataTime t
        }
  where
    ws =
        take (length (txIn (txData t))) $
        map Just (txWitness (txData t)) <> repeat Nothing
    f n i = toInput i (I.lookup n (txDataPrevs t)) (ws !! n)
    ins = zipWith f [0 ..] (txIn (txData t))
    g n o = toOutput o (I.lookup n sm)
    outs = zipWith g [0 ..] (txOut (txData t))

fromTransaction :: Transaction -> (TxData, IntMap Spender)
fromTransaction t = (d, sm)
  where
    d =
        TxData
            { txDataBlock = transactionBlock t
            , txData = transactionData t
            , txDataPrevs = ps
            , txDataDeleted = transactionDeleted t
            , txDataRBF = transactionRBF t
            , txDataTime = transactionTime t
            }
    f _ Coinbase {} = Nothing
    f n Input {inputPkScript = s, inputAmount = v} =
        Just (n, Prev {prevScript = s, prevAmount = v})
    ps = I.fromList . catMaybes $ zipWith f [0 ..] (transactionInputs t)
    g _ Output {outputSpender = Nothing} = Nothing
    g n Output {outputSpender = Just s}  = Just (n, s)
    sm = I.fromList . catMaybes $ zipWith g [0 ..] (transactionOutputs t)

-- | Detailed transaction information.
data Transaction = Transaction
    { transactionBlock    :: !BlockRef
      -- ^ block information for this transaction
    , transactionVersion  :: !Word32
      -- ^ transaction version
    , transactionLockTime :: !Word32
      -- ^ lock time
    , transactionInputs   :: ![Input]
      -- ^ transaction inputs
    , transactionOutputs  :: ![Output]
      -- ^ transaction outputs
    , transactionDeleted  :: !Bool
      -- ^ this transaction has been deleted and is no longer valid
    , transactionRBF      :: !Bool
      -- ^ this transaction can be replaced in the mempool
    , transactionTime     :: !Word64
      -- ^ time the transaction was first seen or time of block
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
    , "fee" .=
      if all isCoinbase (transactionInputs dtx)
          then 0
          else sum (map inputAmount (transactionInputs dtx)) -
               sum (map outputAmount (transactionOutputs dtx))
    , "inputs" .= map (object . inputPairs net) (transactionInputs dtx)
    , "outputs" .= map (object . outputPairs net) (transactionOutputs dtx)
    , "block" .= transactionBlock dtx
    , "deleted" .= transactionDeleted dtx
    , "time" .= transactionTime dtx
    ] ++
    ["rbf" .= transactionRBF dtx | getReplaceByFee net] ++
    ["weight" .= w | getSegWit net]
  where
    w = let b = B.length $ S.encode (transactionData dtx) {txWitness = []}
            x = B.length $ S.encode (transactionData dtx)
        in b * 3 + x

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

-- | Address transaction from an extended public key.
data XPubTx = XPubTx
    { xPubTxPath :: ![KeyIndex]
    , xPubTx     :: !AddressTx
    } deriving (Show, Eq, Generic)

-- | JSON serialization for 'XPubTx'.
xPubTxPairs :: A.KeyValue kv => Network -> XPubTx -> [kv]
xPubTxPairs net XPubTx {xPubTxPath = p, xPubTx = tx} =
    [ "path" .= p
    , "tx" .= addressTxToJSON net tx
    ]

xPubTxToJSON :: Network -> XPubTx -> Value
xPubTxToJSON net = object . xPubTxPairs net

xPubTxToEncoding :: Network -> XPubTx -> Encoding
xPubTxToEncoding net = pairs . mconcat . xPubTxPairs net

-- | Address balances for an extended public key.
data XPubBal = XPubBal
    { xPubBalPath :: ![KeyIndex]
    , xPubBal     :: !Balance
    } deriving (Show, Eq, Generic)

-- | JSON serialization for 'XPubBal'.
xPubBalPairs :: A.KeyValue kv => Network -> XPubBal -> [kv]
xPubBalPairs net XPubBal {xPubBalPath = p, xPubBal = b} =
    [ "path" .= p
    , "balance" .= balanceToJSON net b
    ]

xPubBalToJSON :: Network -> XPubBal -> Value
xPubBalToJSON net = object . xPubBalPairs net

xPubBalToEncoding :: Network -> XPubBal -> Encoding
xPubBalToEncoding net = pairs . mconcat . xPubBalPairs net

-- | Unspent transaction for extended public key.
data XPubUnspent = XPubUnspent
    { xPubUnspentPath :: ![KeyIndex]
    , xPubUnspent     :: !Unspent
    } deriving (Show, Eq, Generic)

-- | JSON serialization for 'XPubUnspent'.
xPubUnspentPairs :: A.KeyValue kv => Network -> XPubUnspent -> [kv]
xPubUnspentPairs net XPubUnspent { xPubUnspentPath = p
                                 , xPubUnspent = u
                                 } =
    [ "path" .= p
    , "unspent" .= unspentToJSON net u
    ]

xPubUnspentToJSON :: Network -> XPubUnspent -> Value
xPubUnspentToJSON net = object . xPubUnspentPairs net

xPubUnspentToEncoding :: Network -> XPubUnspent -> Encoding
xPubUnspentToEncoding net = pairs . mconcat . xPubUnspentPairs net

data HealthCheck = HealthCheck
    { healthHeaderBest   :: !(Maybe BlockHash)
    , healthHeaderHeight :: !(Maybe BlockHeight)
    , healthBlockBest    :: !(Maybe BlockHash)
    , healthBlockHeight  :: !(Maybe BlockHeight)
    , healthPeers        :: !(Maybe Int)
    , healthNetwork      :: !String
    , healthOK           :: !Bool
    , healthSynced       :: !Bool
    } deriving (Show, Eq, Generic, Serialize)

healthCheckPairs :: A.KeyValue kv => HealthCheck -> [kv]
healthCheckPairs h =
    [ "headers" .=
      object ["hash" .= healthHeaderBest h, "height" .= healthHeaderHeight h]
    , "blocks" .=
      object ["hash" .= healthBlockBest h, "height" .= healthBlockHeight h]
    , "peers" .= healthPeers h
    , "net" .= healthNetwork h
    , "ok" .= healthOK h
    , "synced" .= healthSynced h
    , "version" .= P.version
    ]

instance ToJSON HealthCheck where
    toJSON = object . healthCheckPairs
    toEncoding = pairs . mconcat . healthCheckPairs
