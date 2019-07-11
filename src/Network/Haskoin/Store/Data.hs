{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}

module Network.Haskoin.Store.Data where

import           Conduit
import           Control.Applicative
import           Control.Arrow             (first)
import           Control.Monad
import           Control.Monad.Trans.Maybe
import           Data.Aeson                as A
import qualified Data.Aeson.Encoding       as A
import           Data.ByteString           (ByteString)
import qualified Data.ByteString           as B
import           Data.ByteString.Short     (ShortByteString)
import qualified Data.ByteString.Short     as B.Short
import           Data.Default
import           Data.Hashable
import           Data.HashMap.Strict       (HashMap)
import qualified Data.HashMap.Strict       as M
import           Data.Int
import qualified Data.IntMap               as I
import           Data.IntMap.Strict        (IntMap)
import           Data.Maybe
import           Data.Serialize            as S
import           Data.String.Conversions
import qualified Data.Text                 as T
import qualified Data.Text.Encoding        as T
import qualified Data.Text.Lazy            as T.Lazy
import           Data.Word
import           Database.RocksDB          (DB, ReadOptions)
import           GHC.Generics
import           Haskoin                   as H
import           Network.Socket            (SockAddr (SockAddrUnix))
import           Paths_haskoin_store       as P
import           UnliftIO
import           UnliftIO.Exception
import qualified Web.Scotty.Trans          as Scotty

encodeShort :: Serialize a => a -> ShortByteString
encodeShort = B.Short.toShort . S.encode

decodeShort :: Serialize a => ShortByteString -> a
decodeShort bs = case S.decode (B.Short.fromShort bs) of
    Left e  -> error e
    Right a -> a

data BlockDB =
    BlockDB
        { blockDB     :: !DB
        , blockDBopts :: !ReadOptions
        }

data LayeredDB =
    LayeredDB
        { layeredDB    :: !BlockDB
        , layeredCache :: !(Maybe BlockDB)
        }

type UnixTime = Word64
type BlockPos = Word32

newtype InitException = IncorrectVersion Word32
    deriving (Show, Read, Eq, Ord, Exception)

class StoreRead m where
    isInitialized :: m (Either InitException Bool)
    getBestBlock :: m (Maybe BlockHash)
    getBlocksAtHeight :: BlockHeight -> m [BlockHash]
    getBlock :: BlockHash -> m (Maybe BlockData)
    getTxData :: TxHash -> m (Maybe TxData)
    getOrphanTx :: TxHash -> m (Maybe (UnixTime, Tx))
    getSpenders :: TxHash -> m (IntMap Spender)
    getSpender :: OutPoint -> m (Maybe Spender)
    getBalance :: Address -> m (Maybe Balance)
    getUnspent :: OutPoint -> m (Maybe Unspent)

class StoreWrite m where
    setInit :: m ()
    setBest :: BlockHash -> m ()
    insertBlock :: BlockData -> m ()
    insertAtHeight :: BlockHash -> BlockHeight -> m ()
    insertTx :: TxData -> m ()
    insertSpender :: OutPoint -> Spender -> m ()
    deleteSpender :: OutPoint -> m ()
    insertAddrTx :: Address -> BlockTx -> m ()
    deleteAddrTx :: Address -> BlockTx -> m ()
    insertAddrUnspent :: Address -> Unspent -> m ()
    deleteAddrUnspent :: Address -> Unspent -> m ()
    insertMempoolTx :: TxHash -> UnixTime -> m ()
    deleteMempoolTx :: TxHash -> UnixTime -> m ()
    insertOrphanTx :: Tx -> UnixTime -> m ()
    deleteOrphanTx :: TxHash -> m ()
    setBalance :: Balance -> m ()
    insertUnspent :: Unspent -> m ()
    deleteUnspent :: OutPoint -> m ()

getTransaction ::
       (Monad m, StoreRead m) => TxHash -> m (Maybe Transaction)
getTransaction h = runMaybeT $ do
    d <- MaybeT $ getTxData h
    sm <- lift $ getSpenders h
    return $ toTransaction d sm

class StoreStream m where
    getMempool :: Maybe UnixTime -> ConduitT () (UnixTime, TxHash) m ()
    getOrphans :: ConduitT () (UnixTime, Tx) m ()
    getAddressUnspents :: Address -> Maybe BlockRef -> ConduitT () Unspent m ()
    getAddressTxs :: Address -> Maybe BlockRef -> ConduitT () BlockTx m ()
    getAddressBalances :: ConduitT () Balance m ()
    getUnspents :: ConduitT () Unspent m ()

-- | Serialize such that ordering is inverted.
putUnixTime w = putWord64be $ maxBound - w
getUnixTime = (maxBound -) <$> getWord64be

class JsonSerial a where
    jsonSerial :: Network -> a -> Encoding
    jsonValue :: Network -> a -> Value

instance JsonSerial a => JsonSerial [a] where
    jsonSerial net = A.list (jsonSerial net)
    jsonValue net = toJSON . map (jsonValue net)

instance JsonSerial TxHash where
    jsonSerial _ = toEncoding
    jsonValue _ = toJSON

instance BinSerial TxHash where
    binSerial _ = put
    binDeserial _  = get

instance BinSerial Address where
    binSerial net a =
        case addrToString net a of
            Nothing -> put B.empty
            Just x  -> put $ T.encodeUtf8 x

    binDeserial net = do
          bs <- get
          guard (not (B.null bs))
          t <- case T.decodeUtf8' bs of
            Left _  -> mzero
            Right v -> return v
          case stringToAddr net t of
            Nothing -> mzero
            Just x  -> return x

class BinSerial a where
    binSerial :: Network -> Putter a
    binDeserial :: Network -> Get a

instance BinSerial a => BinSerial [a] where
    binSerial net = putListOf (binSerial net)
    binDeserial net = getListOf (binDeserial net)

-- | Reference to a block where a transaction is stored.
data BlockRef
    = BlockRef { blockRefHeight :: !BlockHeight
      -- ^ block height in the chain
               , blockRefPos    :: !Word32
      -- ^ position of transaction within the block
                }
    | MemRef { memRefTime :: !UnixTime }
    deriving (Show, Read, Eq, Ord, Generic, Hashable)

-- | Serialized entities will sort in reverse order.
instance Serialize BlockRef where
    put MemRef {memRefTime = t} = do
        putWord8 0x00
        putUnixTime t
    put BlockRef {blockRefHeight = h, blockRefPos = p} = do
        putWord8 0x01
        putWord32be (maxBound - h)
        putWord32be (maxBound - p)
    get = getmemref <|> getblockref
      where
        getmemref = do
            guard . (== 0x00) =<< getWord8
            MemRef <$> getUnixTime
        getblockref = do
            guard . (== 0x01) =<< getWord8
            h <- (maxBound -) <$> getWord32be
            p <- (maxBound -) <$> getWord32be
            return BlockRef {blockRefHeight = h, blockRefPos = p}

instance BinSerial BlockRef where
    binSerial _ BlockRef {blockRefHeight = h, blockRefPos = p} = do
        putWord8 0x00
        putWord32be h
        putWord32be p
    binSerial _ MemRef {memRefTime = t} = do
        putWord8 0x01
        putWord64be t

    binDeserial _ = getWord8 >>=
        \case
            0x00 -> BlockRef <$> getWord32be <*> getWord32be
            0x01 -> MemRef <$> getUnixTime
            _ -> fail "Expected fst byte to be 0x00 or 0x01"

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
data BlockTx = BlockTx
    { blockTxBlock :: !BlockRef
      -- ^ block information
    , blockTxHash  :: !TxHash
      -- ^ transaction hash
    } deriving (Show, Eq, Ord, Generic, Serialize, Hashable)

-- | JSON serialization for 'AddressTx'.
blockTxPairs :: A.KeyValue kv => BlockTx -> [kv]
blockTxPairs btx =
    [ "txid" .= blockTxHash btx
    , "block" .= blockTxBlock btx
    ]

instance ToJSON BlockTx where
    toJSON = object . blockTxPairs
    toEncoding = pairs . mconcat . blockTxPairs

instance JsonSerial BlockTx where
    jsonSerial _ = toEncoding
    jsonValue _ = toJSON

instance BinSerial BlockTx where
    binSerial net BlockTx { blockTxBlock = b, blockTxHash = h } = do
        binSerial net b
        binSerial net h

    binDeserial net = BlockTx <$> binDeserial net <*> binDeserial net

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

instance JsonSerial Balance where
    jsonSerial = balanceToEncoding
    jsonValue = balanceToJSON

instance BinSerial Balance where
    binSerial net Balance { balanceAddress = a
                          , balanceAmount = v
                          , balanceZero = z
                          , balanceUnspentCount = u
                          , balanceTxCount = c
                          , balanceTotalReceived = t
                          } = do
        binSerial net a
        putWord64be v
        putWord64be z
        putWord64be u
        putWord64be c
        putWord64be t

    binDeserial net =
      Balance <$> binDeserial net
        <*> getWord64be
        <*> getWord64be
        <*> getWord64be
        <*> getWord64be
        <*> getWord64be


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

instance JsonSerial Unspent where
    jsonSerial = unspentToEncoding
    jsonValue = unspentToJSON

instance BinSerial Unspent where
    binSerial net Unspent { unspentBlock = b
                          , unspentPoint = p
                          , unspentAmount = v
                          , unspentScript = s
                          } = do
        binSerial net b
        put p
        putWord64be v
        put s

    binDeserial net =
      Unspent
      <$> binDeserial net
      <*> get
      <*> getWord64be
      <*> get

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

instance JsonSerial BlockData where
    jsonSerial = blockDataToEncoding
    jsonValue = blockDataToJSON

instance BinSerial BlockData where
    binSerial _ BlockData { blockDataHeight = e
                          , blockDataMainChain = m
                          , blockDataWork = w
                          , blockDataHeader = h
                          , blockDataSize = z
                          , blockDataWeight = g
                          , blockDataTxs = t
                          , blockDataOutputs = o
                          , blockDataFees = f
                          , blockDataSubsidy = y
                          } = do
        put m
        putWord32be e
        put h
        put w
        putWord32be z
        putWord32be g
        putWord64be o
        putWord64be f
        putWord64be y
        put t

    binDeserial _ = do
      m <- get
      e <- getWord32be
      h <- get
      w <- get
      z <- getWord32be
      g <- getWord32be
      o <- getWord64be
      f <- getWord64be
      y <- getWord64be
      t <- get
      return $ BlockData e m w h z g t o f y

-- | Input information.
data StoreInput
    = StoreCoinbase { inputPoint     :: !OutPoint
                 -- ^ output being spent (should be null)
                    , inputSequence  :: !Word32
                 -- ^ sequence
                    , inputSigScript :: !ByteString
                 -- ^ input script data (not valid script)
                    , inputWitness   :: !(Maybe WitnessStack)
                 -- ^ witness data for this input (only segwit)
                     }
    -- ^ coinbase details
    | StoreInput { inputPoint     :: !OutPoint
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

isCoinbase :: StoreInput -> Bool
isCoinbase StoreCoinbase {} = True
isCoinbase StoreInput {}    = False

inputPairs :: A.KeyValue kv => Network -> StoreInput -> [kv]
inputPairs net StoreInput { inputPoint = OutPoint oph opi
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

inputPairs net StoreCoinbase { inputPoint = OutPoint oph opi
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

inputToJSON :: Network -> StoreInput -> Value
inputToJSON net = object . inputPairs net

inputToEncoding :: Network -> StoreInput -> Encoding
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
data StoreOutput = StoreOutput
    { outputAmount  :: !Word64
      -- ^ amount in satoshi
    , outputScript  :: !ByteString
      -- ^ pubkey (output) script
    , outputSpender :: !(Maybe Spender)
      -- ^ input spending this transaction
    } deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable)

outputPairs :: A.KeyValue kv => Network -> StoreOutput -> [kv]
outputPairs net d =
    [ "address" .=
      eitherToMaybe (addrToJSON net <$> scriptToAddressBS (outputScript d))
    , "pkscript" .= String (encodeHex (outputScript d))
    , "value" .= outputAmount d
    , "spent" .= isJust (outputSpender d)
    ] ++
    ["spender" .= outputSpender d | isJust (outputSpender d)]

outputToJSON :: Network -> StoreOutput -> Value
outputToJSON net = object . outputPairs net

outputToEncoding :: Network -> StoreOutput -> Encoding
outputToEncoding net = pairs . mconcat . outputPairs net

data Prev = Prev
    { prevScript :: !ByteString
    , prevAmount :: !Word64
    } deriving (Show, Eq, Ord, Generic, Hashable, Serialize)

toInput :: TxIn -> Maybe Prev -> Maybe WitnessStack -> StoreInput
toInput i Nothing w =
    StoreCoinbase
        { inputPoint = prevOutput i
        , inputSequence = txInSequence i
        , inputSigScript = scriptInput i
        , inputWitness = w
        }
toInput i (Just p) w =
    StoreInput
        { inputPoint = prevOutput i
        , inputSequence = txInSequence i
        , inputSigScript = scriptInput i
        , inputPkScript = prevScript p
        , inputAmount = prevAmount p
        , inputWitness = w
        }

toOutput :: TxOut -> Maybe Spender -> StoreOutput
toOutput o s =
    StoreOutput
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

instance BinSerial TxData where
  binSerial _ TxData
        { txDataBlock   = br
        , txData        = tx
        , txDataPrevs   = dp
        , txDataDeleted = dd
        , txDataRBF     = dr
        , txDataTime    = t
        } = do
      put br
      put tx
      put dp
      put dd
      put dr
      putWord64be t

  binDeserial _ = do br <- get
                     tx <- get
                     dp <- get
                     dd <- get
                     dr <- get
                     TxData br tx dp dd dr <$> getWord64be

instance Serialize a => BinSerial (IntMap a) where
  binSerial _ = put
  binDeserial _ = get

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
    f _ StoreCoinbase {} = Nothing
    f n StoreInput {inputPkScript = s, inputAmount = v} =
        Just (n, Prev {prevScript = s, prevAmount = v})
    ps = I.fromList . catMaybes $ zipWith f [0 ..] (transactionInputs t)
    g _ StoreOutput {outputSpender = Nothing} = Nothing
    g n StoreOutput {outputSpender = Just s}  = Just (n, s)
    sm = I.fromList . catMaybes $ zipWith g [0 ..] (transactionOutputs t)

-- | Detailed transaction information.
data Transaction = Transaction
    { transactionBlock    :: !BlockRef
      -- ^ block information for this transaction
    , transactionVersion  :: !Word32
      -- ^ transaction version
    , transactionLockTime :: !Word32
      -- ^ lock time
    , transactionInputs   :: ![StoreInput]
      -- ^ transaction inputs
    , transactionOutputs  :: ![StoreOutput]
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
    i StoreCoinbase {inputPoint = p, inputSequence = q, inputSigScript = s} =
        TxIn {prevOutput = p, scriptInput = s, txInSequence = q}
    i StoreInput {inputPoint = p, inputSequence = q, inputSigScript = s} =
        TxIn {prevOutput = p, scriptInput = s, txInSequence = q}
    o StoreOutput {outputAmount = v, outputScript = s} =
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

instance JsonSerial Transaction where
    jsonSerial = transactionToEncoding
    jsonValue = transactionToJSON

instance BinSerial Transaction where
    binSerial net tx = do
        let (txd, sp) = fromTransaction tx
        binSerial net txd
        binSerial net sp

    binDeserial net = do
      txd <- binDeserial net
      sp <- binDeserial net
      return $ toTransaction txd sp

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
    , "services"    .= String (encodeHex (S.encode (peerServices p)))
    , "relay"       .= peerRelay p
    ]

instance ToJSON PeerInformation where
    toJSON = object . peerInformationPairs
    toEncoding = pairs . mconcat . peerInformationPairs

instance JsonSerial PeerInformation where
    jsonSerial _ = toEncoding
    jsonValue _ = toJSON

instance BinSerial PeerInformation where
    binSerial _ PeerInformation { peerUserAgent = u
                                , peerAddress = a
                                , peerVersion = v
                                , peerServices = s
                                , peerRelay = b
                                } = do
        putWord32be v
        put b
        put u
        put $ NetworkAddress s a

    binDeserial _ = do
      v <- getWord32be
      b <- get
      u <- get
      NetworkAddress { naServices = s, naAddress = a } <- get
      return $ PeerInformation u a v s b

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

instance JsonSerial XPubBal where
    jsonSerial = xPubBalToEncoding
    jsonValue = xPubBalToJSON

instance BinSerial XPubBal where
    binSerial net XPubBal {xPubBalPath = p, xPubBal = b} = do
        put p
        binSerial net b
    binDeserial net  = do
      p <- get
      b <- binDeserial net
      return $ XPubBal p b

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

instance JsonSerial XPubUnspent where
    jsonSerial = xPubUnspentToEncoding
    jsonValue = xPubUnspentToJSON

instance BinSerial XPubUnspent where
    binSerial net XPubUnspent {xPubUnspentPath = p, xPubUnspent = u} = do
        put p
        binSerial net u

    binDeserial net = do
      p <- get
      u <- binDeserial net
      return $ XPubUnspent p u

data XPubSummary =
    XPubSummary
        { xPubSummaryReceived  :: !Word64
        , xPubSummaryConfirmed :: !Word64
        , xPubSummaryZero      :: !Word64
        , xPubExternalIndex    :: !Word32
        , xPubChangeIndex      :: !Word32
        , xPubSummaryPaths     :: !(HashMap Address [KeyIndex])
        , xPubSummaryTxs       :: ![Transaction]
        }
    deriving (Eq, Show, Generic)

xPubSummaryPairs :: A.KeyValue kv => Network -> XPubSummary -> [kv]
xPubSummaryPairs net XPubSummary { xPubSummaryReceived = r
                                 , xPubSummaryConfirmed = c
                                 , xPubSummaryZero = z
                                 , xPubSummaryPaths = ps
                                 , xPubSummaryTxs = ts
                                 , xPubExternalIndex = ext
                                 , xPubChangeIndex = ch
                                 } =
    [ "balance" .=
      object ["received" .= r, "confirmed" .= c, "unconfirmed" .= z]
    , "indices" .= object ["change" .= ch, "external" .= ext]
    , "paths" .= object (mapMaybe (uncurry f) (M.toList ps))
    , "txs" .= map (transactionToJSON net) ts
    ]
  where
    f a p = (.= p) <$> addrToString net a

xPubSummaryToJSON :: Network -> XPubSummary -> Value
xPubSummaryToJSON net = object . xPubSummaryPairs net

xPubSummaryToEncoding :: Network -> XPubSummary -> Encoding
xPubSummaryToEncoding net = pairs . mconcat . xPubSummaryPairs net

instance JsonSerial XPubSummary where
    jsonSerial = xPubSummaryToEncoding
    jsonValue = xPubSummaryToJSON

instance BinSerial XPubSummary where
    binSerial net XPubSummary { xPubSummaryReceived = r
                              , xPubSummaryConfirmed = c
                              , xPubSummaryZero = z
                              , xPubExternalIndex = ext
                              , xPubChangeIndex = ch
                              , xPubSummaryPaths = ps
                              , xPubSummaryTxs = ts
                              } = do
        put r
        put c
        put z
        put ext
        put ch
        put (map (first (runPut . binSerial net)) (M.toList ps))
        put $ map (runPut . binSerial net) ts

    binDeserial net = do
      r <- get
      c <- get
      z <- get
      ext <- get
      ch <- get
      ps <- get
      let xs = map (first (runGet (binDeserial net))) ps
      ys <- forM xs $ \(k, v) -> case k of
        Right a -> return (a, v)
        Left _  -> mzero
      ts <- get
      let txs = map (runGet (binDeserial net)) ts
      tys <- forM txs $ \case
        Right a -> return a
        Left _ -> mzero
      return $ XPubSummary r c z ext ch (M.fromList ys) tys

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

instance JsonSerial HealthCheck where
    jsonSerial _ = toEncoding
    jsonValue _ = toJSON

instance BinSerial HealthCheck where
    binSerial _ HealthCheck { healthHeaderBest = hbest
                            , healthHeaderHeight = hheight
                            , healthBlockBest = bbest
                            , healthBlockHeight = bheight
                            , healthPeers = peers
                            , healthNetwork = net
                            , healthOK = ok
                            , healthSynced = synced
                            } = do
        put hbest
        put hheight
        put bbest
        put bheight
        put peers
        put net
        put ok
        put synced

    binDeserial _ = HealthCheck <$> get <*> get <*> get <*> get <*> get <*> get <*> get <*> get

data Event
    = EventBlock BlockHash
    | EventTx TxHash
    deriving (Show, Eq, Generic)

instance ToJSON Event where
    toJSON (EventTx h)    = object ["type" .= String "tx", "id" .= h]
    toJSON (EventBlock h) = object ["type" .= String "block", "id" .= h]

instance JsonSerial Event where
    jsonSerial _ = toEncoding
    jsonValue _ = toJSON

instance BinSerial Event where
    binSerial _ (EventBlock bh) = putWord8 0x00 >> put bh
    binSerial _ (EventTx th)    = putWord8 0x01 >> put th

    binDeserial _ = getWord8 >>=
            \case
                0x00-> EventBlock <$> get
                0x01 -> EventTx <$> get
                _ -> fail "Expected fst byte to be 0x00 or 0x01"


newtype TxAfterHeight = TxAfterHeight
    { txAfterHeight :: Maybe Bool
    } deriving (Show, Eq, Generic)

instance ToJSON TxAfterHeight where
    toJSON (TxAfterHeight b) = object ["result" .= b]

instance JsonSerial TxAfterHeight where
    jsonSerial _ = toEncoding
    jsonValue _ = toJSON

instance BinSerial TxAfterHeight where
    binSerial _ TxAfterHeight {txAfterHeight = a} = put a
    binDeserial _ = do
      m <- get
      case m of
        Nothing -> return $ TxAfterHeight Nothing
        Just x  -> return $ TxAfterHeight $ Just x

newtype TxId = TxId TxHash deriving (Show, Eq, Generic)

instance ToJSON TxId where
    toJSON (TxId h) = object ["txid" .= h]

instance JsonSerial TxId where
    jsonSerial _ = toEncoding
    jsonValue _ = toJSON

instance BinSerial TxId where
    binSerial _ (TxId th) = put th
    binDeserial _ = TxId <$> get

data StartFrom
    = StartBlock !BlockHeight !BlockPos
    | StartMem !UnixTime
    | StartOffset !Word32
    deriving (Show, Eq, Generic)

data BalVal = BalVal
    { balValAmount        :: !Word64
    , balValZero          :: !Word64
    , balValUnspentCount  :: !Word64
    , balValTxCount       :: !Word64
    , balValTotalReceived :: !Word64
    } deriving (Show, Read, Eq, Ord, Generic, Hashable, Serialize)

balValToBalance :: Address -> BalVal -> Balance
balValToBalance a BalVal { balValAmount = v
                         , balValZero = z
                         , balValUnspentCount = u
                         , balValTxCount = t
                         , balValTotalReceived = r
                         } =
    Balance
        { balanceAddress = a
        , balanceAmount = v
        , balanceZero = z
        , balanceUnspentCount = u
        , balanceTxCount = t
        , balanceTotalReceived = r
        }

balanceToBalVal :: Balance -> (Address, BalVal)
balanceToBalVal Balance { balanceAddress = a
                        , balanceAmount = v
                        , balanceZero = z
                        , balanceUnspentCount = u
                        , balanceTxCount = t
                        , balanceTotalReceived = r
                        } =
    ( a
    , BalVal
          { balValAmount = v
          , balValZero = z
          , balValUnspentCount = u
          , balValTxCount = t
          , balValTotalReceived = r
          })

-- | Default balance for an address.
instance Default BalVal where
    def =
        BalVal
            { balValAmount = 0
            , balValZero = 0
            , balValUnspentCount = 0
            , balValTxCount = 0
            , balValTotalReceived = 0
            }

data UnspentVal = UnspentVal
    { unspentValBlock  :: !BlockRef
    , unspentValAmount :: !Word64
    , unspentValScript :: !ShortByteString
    } deriving (Show, Read, Eq, Ord, Generic, Hashable, Serialize)

unspentToUnspentVal :: Unspent -> (OutPoint, UnspentVal)
unspentToUnspentVal Unspent { unspentBlock = b
                            , unspentPoint = p
                            , unspentAmount = v
                            , unspentScript = s
                            } =
    ( p
    , UnspentVal
          {unspentValBlock = b, unspentValAmount = v, unspentValScript = s})

unspentValToUnspent :: OutPoint -> UnspentVal -> Unspent
unspentValToUnspent p UnspentVal { unspentValBlock = b
                                 , unspentValAmount = v
                                 , unspentValScript = s
                                 } =
    Unspent
        { unspentBlock = b
        , unspentPoint = p
        , unspentAmount = v
        , unspentScript = s
        }
