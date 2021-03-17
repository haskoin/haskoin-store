{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Haskoin.Store.Data
    ( -- * Address Balances
      Balance(..)
    , balanceToJSON
    , balanceToEncoding
    , balanceParseJSON
    , zeroBalance
    , nullBalance

      -- * Block Data
    , BlockData(..)
    , blockDataToJSON
    , blockDataToEncoding
    , confirmed

      -- * Transactions
    , TxRef(..)
    , TxData(..)
    , Transaction(..)
    , transactionToJSON
    , transactionToEncoding
    , transactionParseJSON
    , transactionData
    , fromTransaction
    , toTransaction
    , StoreInput(..)
    , storeInputToJSON
    , storeInputToEncoding
    , storeInputParseJSON
    , isCoinbase
    , StoreOutput(..)
    , storeOutputToJSON
    , storeOutputToEncoding
    , storeOutputParseJSON
    , Prev(..)
    , Spender(..)
    , BlockRef(..)
    , UnixTime
    , getUnixTime
    , putUnixTime
    , BlockPos

      -- * Unspent Outputs
    , Unspent(..)
    , unspentToJSON
    , unspentToEncoding
    , unspentParseJSON

      -- * Extended Public Keys
    , XPubSpec(..)
    , XPubBal(..)
    , xPubBalToJSON
    , xPubBalToEncoding
    , xPubBalParseJSON
    , XPubUnspent(..)
    , xPubUnspentToJSON
    , xPubUnspentToEncoding
    , xPubUnspentParseJSON
    , XPubSummary(..)
    , DeriveType(..)

      -- * Other Data
    , TxId(..)
    , GenericResult(..)
    , SerialList(..)
    , RawResult(..)
    , RawResultList(..)
    , PeerInformation(..)
    , Healthy(..)
    , BlockHealth(..)
    , TimeHealth(..)
    , CountHealth(..)
    , MaxHealth(..)
    , HealthCheck(..)
    , Event(..)
    , Except(..)

     -- * Blockchain.info API
    , BinfoBlockId(..)
    , BinfoTxId(..)
    , encodeBinfoTxId
    , BinfoFilter(..)
    , BinfoMultiAddr(..)
    , binfoMultiAddrToJSON
    , binfoMultiAddrToEncoding
    , binfoMultiAddrParseJSON
    , BinfoShortBal(..)
    , BinfoBalance(..)
    , toBinfoAddrs
    , binfoBalanceToJSON
    , binfoBalanceToEncoding
    , binfoBalanceParseJSON
    , BinfoRawAddr(..)
    , binfoRawAddrToJSON
    , binfoRawAddrToEncoding
    , binfoRawAddrParseJSON
    , BinfoAddr(..)
    , parseBinfoAddr
    , BinfoWallet(..)
    , BinfoUnspent(..)
    , binfoUnspentToJSON
    , binfoUnspentToEncoding
    , binfoUnspentParseJSON
    , binfoHexValue
    , BinfoUnspents(..)
    , binfoUnspentsToJSON
    , binfoUnspentsToEncoding
    , binfoUnspentsParseJSON
    , BinfoBlock(..)
    , toBinfoBlock
    , binfoBlockToJSON
    , binfoBlockToEncoding
    , binfoBlockParseJSON
    , binfoBlocksToJSON
    , binfoBlocksToEncoding
    , binfoBlocksParseJSON
    , BinfoTx(..)
    , relevantTxs
    , toBinfoTx
    , toBinfoTxSimple
    , binfoTxToJSON
    , binfoTxToEncoding
    , binfoTxParseJSON
    , BinfoTxInput(..)
    , binfoTxInputToJSON
    , binfoTxInputToEncoding
    , binfoTxInputParseJSON
    , BinfoTxOutput(..)
    , binfoTxOutputToJSON
    , binfoTxOutputToEncoding
    , binfoTxOutputParseJSON
    , BinfoSpender(..)
    , BinfoXPubPath(..)
    , binfoXPubPathToJSON
    , binfoXPubPathToEncoding
    , binfoXPubPathParseJSON
    , BinfoInfo(..)
    , BinfoBlockInfo(..)
    , BinfoSymbol(..)
    , BinfoTicker(..)
    )

where

import           Control.Applicative     ((<|>))
import           Control.DeepSeq         (NFData)
import           Control.Exception       (Exception)
import           Control.Monad           (join, mzero, replicateM, unless,
                                          (<=<))
import           Data.Aeson              (Encoding, FromJSON (..),
                                          FromJSONKey (..), ToJSON (..),
                                          ToJSONKey (..), Value (..), (.!=),
                                          (.:), (.:?), (.=))
import qualified Data.Aeson              as A
import qualified Data.Aeson.Encoding     as AE
import           Data.Aeson.Types        (Parser)
import           Data.Binary             (Binary (get, put))
import           Data.Bits               (Bits (..))
import           Data.ByteString         (ByteString)
import qualified Data.ByteString         as BS
import qualified Data.ByteString.Builder as BSB
import           Data.Bytes.Get
import qualified Data.Bytes.Get          as Bytes.Get
import           Data.Bytes.Put
import qualified Data.Bytes.Put          as Bytes.Put
import           Data.Bytes.Serial
import           Data.Bytes.Serial       (Serial (..))
import           Data.Default            (Default (..))
import           Data.Either             (fromRight, lefts, rights)
import           Data.Foldable           (toList)
import           Data.Function           (on)
import           Data.HashMap.Strict     (HashMap)
import qualified Data.HashMap.Strict     as HashMap
import           Data.HashSet            (HashSet)
import qualified Data.HashSet            as HashSet
import           Data.Hashable           (Hashable (..))
import           Data.Int                (Int32, Int64)
import qualified Data.IntMap             as IntMap
import           Data.IntMap.Strict      (IntMap)
import           Data.List               (unfoldr)
import           Data.Map.Strict         (Map)
import           Data.Maybe              (catMaybes, fromMaybe, isJust,
                                          isNothing, mapMaybe, maybeToList)
import           Data.Serialize          (Serialize (..))
import           Data.String.Conversions (cs)
import           Data.Text               (Text)
import qualified Data.Text               as T
import qualified Data.Text.Encoding      as TE
import qualified Data.Text.Lazy          as TL
import qualified Data.Text.Lazy.Encoding as TLE
import           Data.Word               (Word32, Word64, Word8)
import           GHC.Generics            (Generic)
import           Haskoin
import           Numeric.Natural         (Natural)
import           Text.Printf             (printf)
import           Text.Read               (readMaybe)
import           Web.Scotty.Trans        (Parsable (..), ScottyError (..))

data DeriveType
    = DeriveNormal
    | DeriveP2SH
    | DeriveP2WPKH
    deriving (Show, Eq, Generic, NFData)

instance Serial DeriveType where
    serialize DeriveNormal = putWord8 0x00
    serialize DeriveP2SH   = putWord8 0x01
    serialize DeriveP2WPKH = putWord8 0x02

    deserialize = getWord8 >>= \case
        0x00 -> return DeriveNormal
        0x01 -> return DeriveP2SH
        0x02 -> return DeriveP2WPKH

instance Binary DeriveType where
    put = serialize
    get = deserialize

instance Serialize DeriveType where
    put = serialize
    get = deserialize

instance Default DeriveType where
    def = DeriveNormal

data XPubSpec =
    XPubSpec
        { xPubSpecKey    :: !XPubKey
        , xPubDeriveType :: !DeriveType
        }
    deriving (Show, Eq, Generic, NFData)

instance Hashable XPubSpec where
    hashWithSalt i XPubSpec {xPubSpecKey = XPubKey {xPubKey = pubkey}} =
        hashWithSalt i pubkey

instance Serial XPubSpec where
    serialize XPubSpec {xPubSpecKey = k, xPubDeriveType = t} = do
        putWord8 (xPubDepth k)
        putWord32be (xPubParent k)
        putWord32be (xPubIndex k)
        serialize (xPubChain k)
        serialize (wrapPubKey True (xPubKey k))
        serialize t
    deserialize = do
        d <- getWord8
        p <- getWord32be
        i <- getWord32be
        c <- deserialize
        k <- deserialize
        t <- deserialize
        let x = XPubKey
                { xPubDepth = d
                , xPubParent = p
                , xPubIndex = i
                , xPubChain = c
                , xPubKey = pubKeyPoint k
                }
        return XPubSpec {xPubSpecKey = x, xPubDeriveType = t}

instance Serialize XPubSpec where
    put = serialize
    get = deserialize

instance Binary XPubSpec where
    put = serialize
    get = deserialize

type UnixTime = Word64
type BlockPos = Word32

-- | Binary such that ordering is inverted.
putUnixTime :: MonadPut m => Word64 -> m ()
putUnixTime w = putWord64be $ maxBound - w

getUnixTime :: MonadGet m => m Word64
getUnixTime = (maxBound -) <$> getWord64be

-- | Reference to a block where a transaction is stored.
data BlockRef
    = BlockRef
          { blockRefHeight :: !BlockHeight
    -- ^ block height in the chain
          , blockRefPos    :: !Word32
    -- ^ position of transaction within the block
          }
    | MemRef
          { memRefTime :: !UnixTime
          }
    deriving (Show, Read, Eq, Ord, Generic, Hashable, NFData)

-- | Serial entities will sort in reverse order.
instance Serial BlockRef where
    serialize MemRef {memRefTime = t} = do
        putWord8 0x00
        putUnixTime t
    serialize BlockRef {blockRefHeight = h, blockRefPos = p} = do
        putWord8 0x01
        putWord32be (maxBound - h)
        putWord32be (maxBound - p)
    deserialize =
        getWord8 >>= \case
        0x00 -> getmemref
        0x01 -> getblockref
        _    -> fail "Cannot decode BlockRef"
      where
        getmemref = do
            MemRef <$> getUnixTime
        getblockref = do
            h <- (maxBound -) <$> getWord32be
            p <- (maxBound -) <$> getWord32be
            return BlockRef {blockRefHeight = h, blockRefPos = p}

instance Serialize BlockRef where
    put = serialize
    get = deserialize

instance Binary BlockRef where
    put = serialize
    get = deserialize

confirmed :: BlockRef -> Bool
confirmed BlockRef {} = True
confirmed MemRef {}   = False

instance ToJSON BlockRef where
    toJSON BlockRef {blockRefHeight = h, blockRefPos = p} =
        A.object ["height" .= h, "position" .= p]
    toJSON MemRef {memRefTime = t} = A.object ["mempool" .= t]
    toEncoding BlockRef {blockRefHeight = h, blockRefPos = p} =
        AE.pairs ("height" .= h <> "position" .= p)
    toEncoding MemRef {memRefTime = t} = AE.pairs ("mempool" .= t)

instance FromJSON BlockRef where
    parseJSON = A.withObject "blockref" $ \o -> b o <|> m o
      where
        b o = do
            height <- o .: "height"
            position <- o .: "position"
            return BlockRef{blockRefHeight = height, blockRefPos = position}
        m o = do
            mempool <- o .: "mempool"
            return MemRef{memRefTime = mempool}

-- | Transaction in relation to an address.
data TxRef =
    TxRef
        { txRefBlock :: !BlockRef
    -- ^ block information
        , txRefHash  :: !TxHash
    -- ^ transaction hash
        }
    deriving (Show, Eq, Ord, Generic, Hashable, NFData)

instance Serial TxRef where
    serialize (TxRef b h) = do
        serialize b
        serialize h

    deserialize =
        TxRef <$> deserialize <*> deserialize

instance Binary TxRef where
    put = serialize
    get = deserialize

instance Serialize TxRef where
    put = serialize
    get = deserialize

instance ToJSON TxRef where
    toJSON btx =
        A.object
            [ "txid" .= txRefHash btx
            , "block" .= txRefBlock btx
            ]
    toEncoding btx =
        AE.pairs $
            "txid" .= txRefHash btx <>
            "block" .= txRefBlock btx

instance FromJSON TxRef where
    parseJSON =
        A.withObject "blocktx" $ \o -> do
            txid <- o .: "txid"
            block <- o .: "block"
            return TxRef {txRefBlock = block, txRefHash = txid}

-- | Address balance information.
data Balance =
    Balance
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
        }
    deriving (Show, Read, Eq, Ord, Generic, Hashable, NFData)

instance Serial Balance where
    serialize Balance{..} = do
        serialize balanceAddress
        putWord64be balanceAmount
        putWord64be balanceZero
        putWord64be balanceUnspentCount
        putWord64be balanceTxCount
        putWord64be balanceTotalReceived

    deserialize = do
        balanceAddress       <- deserialize
        balanceAmount        <- getWord64be
        balanceZero          <- getWord64be
        balanceUnspentCount  <- getWord64be
        balanceTxCount       <- getWord64be
        balanceTotalReceived <- getWord64be
        return Balance{..}

instance Binary Balance where
    put = serialize
    get = deserialize

instance Serialize Balance where
    put = serialize
    get = deserialize

zeroBalance :: Address -> Balance
zeroBalance a =
    Balance
        { balanceAddress = a
        , balanceAmount = 0
        , balanceUnspentCount = 0
        , balanceZero = 0
        , balanceTxCount = 0
        , balanceTotalReceived = 0
        }

nullBalance :: Balance -> Bool
nullBalance
    Balance
    {
        balanceAmount = 0,
        balanceUnspentCount = 0,
        balanceZero = 0,
        balanceTxCount = 0,
        balanceTotalReceived = 0
    } = True
nullBalance _ = False

balanceToJSON :: Network -> Balance -> Value
balanceToJSON net b =
    A.object
        [ "address" .= addrToJSON net (balanceAddress b)
        , "confirmed" .= balanceAmount b
        , "unconfirmed" .= balanceZero b
        , "utxo" .= balanceUnspentCount b
        , "txs" .= balanceTxCount b
        , "received" .= balanceTotalReceived b
        ]

balanceToEncoding :: Network -> Balance -> Encoding
balanceToEncoding net b =
    AE.pairs $
    "address" `AE.pair` addrToEncoding net (balanceAddress b) <>
    "confirmed" .= balanceAmount b <>
    "unconfirmed" .= balanceZero b <>
    "utxo" .= balanceUnspentCount b <>
    "txs" .= balanceTxCount b <>
    "received" .= balanceTotalReceived b

balanceParseJSON :: Network -> Value -> Parser Balance
balanceParseJSON net =
    A.withObject "balance" $ \o -> do
        amount <- o .: "confirmed"
        unconfirmed <- o .: "unconfirmed"
        utxo <- o .: "utxo"
        txs <- o .: "txs"
        received <- o .: "received"
        address <- addrFromJSON net =<< o .: "address"
        return
            Balance
                { balanceAddress = address
                , balanceAmount = amount
                , balanceUnspentCount = utxo
                , balanceZero = unconfirmed
                , balanceTxCount = txs
                , balanceTotalReceived = received
                }

-- | Unspent output.
data Unspent =
    Unspent
        { unspentBlock   :: !BlockRef
        , unspentPoint   :: !OutPoint
        , unspentAmount  :: !Word64
        , unspentScript  :: !ByteString
        , unspentAddress :: !(Maybe Address)
        }
    deriving (Show, Eq, Ord, Generic, Hashable, NFData)

instance Serial Unspent where
    serialize Unspent{..} = do
        serialize unspentBlock
        serialize unspentPoint
        putWord64be unspentAmount
        putLengthBytes unspentScript
        putMaybe serialize unspentAddress

    deserialize = do
        unspentBlock <- deserialize
        unspentPoint <- deserialize
        unspentAmount <- getWord64be
        unspentScript <- getLengthBytes
        unspentAddress <- getMaybe deserialize
        return Unspent{..}

instance Binary Unspent where
    put = serialize
    get = deserialize

instance Serialize Unspent where
    put = serialize
    get = deserialize

instance Coin Unspent where
    coinValue = unspentAmount

unspentToJSON :: Network -> Unspent -> Value
unspentToJSON net u =
    A.object
        [ "address" .= (addrToJSON net <$> unspentAddress u)
        , "block" .= unspentBlock u
        , "txid" .= outPointHash (unspentPoint u)
        , "index" .= outPointIndex (unspentPoint u)
        , "pkscript" .= encodeHex (unspentScript u)
        , "value" .= unspentAmount u
        ]

unspentToEncoding :: Network -> Unspent -> Encoding
unspentToEncoding net u =
    AE.pairs $
    "address" `AE.pair` maybe AE.null_ (addrToEncoding net) (unspentAddress u) <>
    "block" .= unspentBlock u <>
    "txid" .= outPointHash (unspentPoint u) <>
    "index" .= outPointIndex (unspentPoint u) <>
    "pkscript" `AE.pair` AE.text (encodeHex (unspentScript u)) <>
    "value" .= unspentAmount u

unspentParseJSON :: Network -> Value -> Parser Unspent
unspentParseJSON net =
    A.withObject "unspent" $ \o -> do
        block <- o .: "block"
        txid <- o .: "txid"
        index <- o .: "index"
        value <- o .: "value"
        script <- o .: "pkscript" >>= jsonHex
        addr <- o .: "address" >>= \case
            Nothing -> return Nothing
            Just a  -> Just <$> addrFromJSON net a <|> return Nothing
        return
            Unspent
                { unspentBlock = block
                , unspentPoint = OutPoint txid index
                , unspentAmount = value
                , unspentScript = script
                , unspentAddress = addr
                }

-- | Database value for a block entry.
data BlockData =
    BlockData
        { blockDataHeight    :: !BlockHeight
        -- ^ height of the block in the chain
        , blockDataMainChain :: !Bool
        -- ^ is this block in the main chain?
        , blockDataWork      :: !Integer
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
        }
    deriving (Show, Read, Eq, Ord, Generic, Hashable, NFData)

instance Serial BlockData where
    serialize BlockData{..} = do
        putWord32be blockDataHeight
        serialize blockDataMainChain
        putInteger blockDataWork
        serialize blockDataHeader
        putWord32be blockDataSize
        putWord32be blockDataWeight
        putList serialize blockDataTxs
        putWord64be blockDataOutputs
        putWord64be blockDataFees
        putWord64be blockDataSubsidy

    deserialize = do
        blockDataHeight <- getWord32be
        blockDataMainChain <- deserialize
        blockDataWork <- getInteger
        blockDataHeader <- deserialize
        blockDataSize <- getWord32be
        blockDataWeight <- getWord32be
        blockDataTxs <- getList deserialize
        blockDataOutputs <- getWord64be
        blockDataFees <- getWord64be
        blockDataSubsidy <- getWord64be
        return BlockData{..}

instance Serialize BlockData where
    put = serialize
    get = deserialize

instance Binary BlockData where
    put = serialize
    get = deserialize

blockDataToJSON :: Network -> BlockData -> Value
blockDataToJSON net bv =
    A.object $
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
    , "work" .= blockDataWork bv
    ] <>
    ["weight" .= blockDataWeight bv | getSegWit net]

blockDataToEncoding :: Network -> BlockData -> Encoding
blockDataToEncoding net bv =
    AE.pairs $
    "hash" `AE.pair` AE.text
    (blockHashToHex (headerHash (blockDataHeader bv))) <>
    "height" .= blockDataHeight bv <>
    "mainchain" .= blockDataMainChain bv <>
    "previous" .= prevBlock (blockDataHeader bv) <>
    "time" .= blockTimestamp (blockDataHeader bv) <>
    "version" .= blockVersion (blockDataHeader bv) <>
    "bits" .= blockBits (blockDataHeader bv) <>
    "nonce" .= bhNonce (blockDataHeader bv) <>
    "size" .= blockDataSize bv <>
    "tx" .= blockDataTxs bv <>
    "merkle" `AE.pair` AE.text
    (txHashToHex (TxHash (merkleRoot (blockDataHeader bv)))) <>
    "subsidy" .= blockDataSubsidy bv <>
    "fees" .= blockDataFees bv <>
    "outputs" .= blockDataOutputs bv <>
    "work" .= blockDataWork bv <>
    (if getSegWit net then "weight" .= blockDataWeight bv else mempty)

instance FromJSON BlockData where
    parseJSON =
        A.withObject "blockdata" $ \o -> do
        height <- o .: "height"
        mainchain <- o .: "mainchain"
        previous <- o .: "previous"
        time <- o .: "time"
        version <- o .: "version"
        bits <- o .: "bits"
        nonce <- o .: "nonce"
        size <- o .: "size"
        tx <- o .: "tx"
        TxHash merkle <- o .: "merkle"
        subsidy <- o .: "subsidy"
        fees <- o .: "fees"
        outputs <- o .: "outputs"
        work <- o .: "work"
        weight <- o .:? "weight" .!= 0
        return
            BlockData
            { blockDataHeader =
                  BlockHeader
                  { prevBlock = previous
                  , blockTimestamp = time
                  , blockVersion = version
                  , blockBits = bits
                  , bhNonce = nonce
                  , merkleRoot = merkle
                  }
            , blockDataMainChain = mainchain
            , blockDataWork = work
            , blockDataSize = size
            , blockDataWeight = weight
            , blockDataTxs = tx
            , blockDataOutputs = outputs
            , blockDataFees = fees
            , blockDataHeight = height
            , blockDataSubsidy = subsidy
            }

data StoreInput
    = StoreCoinbase
          { inputPoint     :: !OutPoint
          , inputSequence  :: !Word32
          , inputSigScript :: !ByteString
          , inputWitness   :: !WitnessStack
          }
    | StoreInput
          { inputPoint     :: !OutPoint
          , inputSequence  :: !Word32
          , inputSigScript :: !ByteString
          , inputPkScript  :: !ByteString
          , inputAmount    :: !Word64
          , inputWitness   :: !WitnessStack
          , inputAddress   :: !(Maybe Address)
          }
    deriving (Show, Read, Eq, Ord, Generic, Hashable, NFData)

instance Serial StoreInput where
    serialize StoreCoinbase{..} = do
        putWord8 0x00
        serialize inputPoint
        putWord32be inputSequence
        putLengthBytes inputSigScript
        putList putLengthBytes inputWitness

    serialize StoreInput{..} = do
        putWord8 0x01
        serialize inputPoint
        putWord32be inputSequence
        putLengthBytes inputSigScript
        putLengthBytes inputPkScript
        putWord64be inputAmount
        putList putLengthBytes inputWitness
        putMaybe serialize inputAddress

    deserialize =
        getWord8 >>= \case
        0x00 -> do
            inputPoint <- deserialize
            inputSequence <- getWord32be
            inputSigScript <- getLengthBytes
            inputWitness <- getList getLengthBytes
            return StoreCoinbase{..}
        0x01 -> do
            inputPoint <- deserialize
            inputSequence <- getWord32be
            inputSigScript <- getLengthBytes
            inputPkScript <- getLengthBytes
            inputAmount <- getWord64be
            inputWitness <- getList getLengthBytes
            inputAddress <- getMaybe deserialize
            return StoreInput{..}

instance Serialize StoreInput where
    put = serialize
    get = deserialize

instance Binary StoreInput where
    put = serialize
    get = deserialize

isCoinbase :: StoreInput -> Bool
isCoinbase StoreCoinbase{} = True
isCoinbase StoreInput{}    = False

storeInputToJSON :: Network -> StoreInput -> Value
storeInputToJSON
    net
    StoreInput
    {
        inputPoint = OutPoint oph opi,
        inputSequence = sq,
        inputSigScript = ss,
        inputPkScript = ps,
        inputAmount = val,
        inputWitness = wit,
        inputAddress = a
    } =
    A.object $
    [ "coinbase" .= False
    , "txid" .= oph
    , "output" .= opi
    , "sigscript" .= String (encodeHex ss)
    , "sequence" .= sq
    , "pkscript" .= String (encodeHex ps)
    , "value" .= val
    , "address" .= (addrToJSON net <$> a)
    , "witness" .= map encodeHex wit
    ]

storeInputToJSON
    net
    StoreCoinbase
    {
        inputPoint = OutPoint oph opi,
        inputSequence = sq,
        inputSigScript = ss,
        inputWitness = wit
    } =
    A.object $
    [ "coinbase" .= True
    , "txid" .= oph
    , "output" .= opi
    , "sigscript" .= String (encodeHex ss)
    , "sequence" .= sq
    , "pkscript" .= Null
    , "value" .= Null
    , "address" .= Null
    , "witness" .= map encodeHex wit
    ]

storeInputToEncoding :: Network -> StoreInput -> Encoding
storeInputToEncoding
    net
    StoreInput
    {
        inputPoint = OutPoint oph opi,
        inputSequence = sq,
        inputSigScript = ss,
        inputPkScript = ps,
        inputAmount = val,
        inputWitness = wit,
        inputAddress = a
    } =
    AE.pairs $
    "coinbase" .= False <>
    "txid" .= oph <>
    "output" .= opi <>
    "sigscript" `AE.pair` AE.text (encodeHex ss) <>
    "sequence" .= sq <>
    "pkscript" `AE.pair` AE.text (encodeHex ps) <>
    "value" .= val <>
    "address" `AE.pair` maybe AE.null_ (addrToEncoding net) a <>
    "witness" .= map encodeHex wit

storeInputToEncoding
    net
    StoreCoinbase
    {
        inputPoint = OutPoint oph opi,
        inputSequence = sq,
        inputSigScript = ss,
        inputWitness = wit
    } =
    AE.pairs $
    "coinbase" .= True <>
    "txid" `AE.pair` AE.text (txHashToHex oph) <>
    "output" .= opi <>
    "sigscript" `AE.pair` AE.text (encodeHex ss) <>
    "sequence" .= sq <>
    "pkscript" `AE.pair` AE.null_ <>
    "value" `AE.pair` AE.null_ <>
    "address" `AE.pair` AE.null_ <>
    "witness" .= map encodeHex wit

storeInputParseJSON :: Network -> Value -> Parser StoreInput
storeInputParseJSON net =
    A.withObject "storeinput" $ \o -> do
    coinbase <- o .: "coinbase"
    outpoint <- OutPoint <$> o .: "txid" <*> o .: "output"
    sequ <- o .: "sequence"
    witness <- mapM jsonHex =<< o .:? "witness" .!= []
    sigscript <- o .: "sigscript" >>= jsonHex
    if coinbase
        then return
                StoreCoinbase
                    { inputPoint = outpoint
                    , inputSequence = sequ
                    , inputSigScript = sigscript
                    , inputWitness = witness
                    }
        else do
            pkscript <- o .: "pkscript" >>= jsonHex
            value <- o .: "value"
            addr <- o .: "address" >>= \case
                Nothing -> return Nothing
                Just a  -> Just <$> addrFromJSON net a <|> return Nothing
            return
                StoreInput
                    { inputPoint = outpoint
                    , inputSequence = sequ
                    , inputSigScript = sigscript
                    , inputPkScript = pkscript
                    , inputAmount = value
                    , inputWitness = witness
                    , inputAddress = addr
                    }

jsonHex :: Text -> Parser ByteString
jsonHex s =
    case decodeHex s of
        Nothing -> fail "Could not decode hex"
        Just b  -> return b

-- | Information about input spending output.
data Spender =
    Spender
        { spenderHash  :: !TxHash
        -- ^ input transaction hash
        , spenderIndex :: !Word32
        -- ^ input position in transaction
        }
    deriving (Show, Read, Eq, Ord, Generic, Hashable, NFData)

instance Serial Spender where
    serialize Spender{..} = do
        serialize spenderHash
        putWord32be spenderIndex
    deserialize = Spender <$> deserialize <*> getWord32be

instance Serialize Spender where
    put = serialize
    get = deserialize

instance Binary Spender where
    put = serialize
    get = deserialize

instance ToJSON Spender where
    toJSON n =
        A.object
        [ "txid" .= txHashToHex (spenderHash n)
        , "input" .= spenderIndex n
        ]
    toEncoding n =
        AE.pairs $
          "txid" .= txHashToHex (spenderHash n) <>
          "input" .= spenderIndex n

instance FromJSON Spender where
    parseJSON =
        A.withObject "spender" $ \o ->
        Spender <$> o .: "txid" <*> o .: "input"

-- | Output information.
data StoreOutput =
    StoreOutput
        { outputAmount  :: !Word64
        , outputScript  :: !ByteString
        , outputSpender :: !(Maybe Spender)
        , outputAddr    :: !(Maybe Address)
        }
    deriving (Show, Read, Eq, Ord, Generic, Hashable, NFData)

instance Serial StoreOutput where
    serialize StoreOutput{..} = do
        putWord64be outputAmount
        putLengthBytes outputScript
        putMaybe serialize outputSpender
        putMaybe serialize outputAddr
    deserialize = do
        outputAmount <- getWord64be
        outputScript <- getLengthBytes
        outputSpender <- getMaybe deserialize
        outputAddr <- getMaybe deserialize
        return StoreOutput{..}

instance Serialize StoreOutput where
    put = serialize
    get = deserialize

instance Binary StoreOutput where
    put = serialize
    get = deserialize

storeOutputToJSON :: Network -> StoreOutput -> Value
storeOutputToJSON net d =
    A.object
    [ "address" .= (addrToJSON net <$> outputAddr d)
    , "pkscript" .= encodeHex (outputScript d)
    , "value" .= outputAmount d
    , "spent" .= isJust (outputSpender d)
    , "spender" .= outputSpender d
    ]

storeOutputToEncoding :: Network -> StoreOutput -> Encoding
storeOutputToEncoding net d =
    AE.pairs $
    "address" `AE.pair` maybe AE.null_ (addrToEncoding net) (outputAddr d) <>
    "pkscript" `AE.pair` AE.text (encodeHex (outputScript d)) <>
    "value" .= outputAmount d <>
    "spent" .= isJust (outputSpender d) <>
    "spender" .= outputSpender d

storeOutputParseJSON :: Network -> Value -> Parser StoreOutput
storeOutputParseJSON net =
    A.withObject "storeoutput" $ \o -> do
    value <- o .: "value"
    pkscript <- o .: "pkscript" >>= jsonHex
    spender <- o .: "spender"
    addr <- o .: "address" >>= \case
        Nothing -> return Nothing
        Just a  -> Just <$> addrFromJSON net a <|> return Nothing
    return
        StoreOutput
            { outputAmount = value
            , outputScript = pkscript
            , outputSpender = spender
            , outputAddr = addr
            }

data Prev =
    Prev
        { prevScript :: !ByteString
        , prevAmount :: !Word64
        }
    deriving (Show, Eq, Ord, Generic, Hashable, NFData)

instance Serial Prev where
    serialize Prev{..} = do
        putLengthBytes prevScript
        putWord64be prevAmount
    deserialize = do
        prevScript <- getLengthBytes
        prevAmount <- getWord64be
        return Prev{..}

instance Binary Prev where
    put = serialize
    get = deserialize

instance Serialize Prev where
    put = serialize
    get = deserialize

toInput :: TxIn -> Maybe Prev -> WitnessStack -> StoreInput
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
        , inputAddress = eitherToMaybe (scriptToAddressBS (prevScript p))
        }

toOutput :: TxOut -> Maybe Spender -> StoreOutput
toOutput o s =
    StoreOutput
        { outputAmount = outValue o
        , outputScript = scriptOutput o
        , outputSpender = s
        , outputAddr = eitherToMaybe (scriptToAddressBS (scriptOutput o))
        }

data TxData =
    TxData
        { txDataBlock   :: !BlockRef
        , txData        :: !Tx
        , txDataPrevs   :: !(IntMap Prev)
        , txDataDeleted :: !Bool
        , txDataRBF     :: !Bool
        , txDataTime    :: !Word64
        }
    deriving (Show, Eq, Ord, Generic, NFData)

instance Serial TxData where
    serialize TxData{..} = do
        serialize txDataBlock
        serialize txData
        putIntMap (putWord64be . fromIntegral) serialize txDataPrevs
        serialize txDataDeleted
        serialize txDataRBF
        putWord64be txDataTime
    deserialize = do
        txDataBlock <- deserialize
        txData <- deserialize
        txDataPrevs <- getIntMap (fromIntegral <$> getWord64be) deserialize
        txDataDeleted <- deserialize
        txDataRBF <- deserialize
        txDataTime <- getWord64be
        return TxData{..}

instance Serialize TxData where
    put = serialize
    get = deserialize

instance Binary TxData where
    put = serialize
    get = deserialize

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
        , transactionId = txid
        , transactionSize = txsize
        , transactionWeight = txweight
        , transactionFees = fees
        }
  where
    txid = txHash (txData t)
    txsize = fromIntegral $ BS.length (runPutS (serialize (txData t)))
    txweight =
        let b = BS.length $ runPutS $ serialize (txData t) {txWitness = []}
            x = BS.length $ runPutS $ serialize (txData t)
         in fromIntegral $ b * 3 + x
    inv = sum (map inputAmount ins)
    outv = sum (map outputAmount outs)
    fees = if any isCoinbase ins then 0 else inv - outv
    ws = take (length (txIn (txData t))) $ txWitness (txData t) <> repeat []
    f n i = toInput i (IntMap.lookup n (txDataPrevs t)) (ws !! n)
    ins = zipWith f [0 ..] (txIn (txData t))
    g n o = toOutput o (IntMap.lookup n sm)
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
    ps = IntMap.fromList . catMaybes $ zipWith f [0 ..] (transactionInputs t)
    g _ StoreOutput {outputSpender = Nothing} = Nothing
    g n StoreOutput {outputSpender = Just s}  = Just (n, s)
    sm = IntMap.fromList . catMaybes $ zipWith g [0 ..] (transactionOutputs t)

-- | Detailed transaction information.
data Transaction =
    Transaction
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
        , transactionId       :: !TxHash
        -- ^ transaction id
        , transactionSize     :: !Word32
        -- ^ serialized transaction size (includes witness data)
        , transactionWeight   :: !Word32
        -- ^ transaction weight
        , transactionFees     :: !Word64
        -- ^ fees that this transaction pays (0 for coinbase)
        }
    deriving (Show, Eq, Ord, Generic, Hashable, NFData)

instance Serial Transaction where
    serialize Transaction{..} = do
        serialize transactionBlock
        putWord32be transactionVersion
        putWord32be transactionLockTime
        putList serialize transactionInputs
        putList serialize transactionOutputs
        serialize transactionDeleted
        serialize transactionRBF
        putWord64be transactionTime
        serialize transactionId
        putWord32be transactionSize
        putWord32be transactionWeight
        putWord64be transactionFees
    deserialize = do
        transactionBlock <- deserialize
        transactionVersion <- getWord32be
        transactionLockTime <- getWord32be
        transactionInputs <- getList deserialize
        transactionOutputs <- getList deserialize
        transactionDeleted <- deserialize
        transactionRBF <- deserialize
        transactionTime <- getWord64be
        transactionId <- deserialize
        transactionSize <- getWord32be
        transactionWeight <- getWord32be
        transactionFees <- getWord64be
        return Transaction{..}

instance Serialize Transaction where
    put = serialize
    get = deserialize

instance Binary Transaction where
    put = serialize
    get = deserialize

transactionData :: Transaction -> Tx
transactionData t =
    Tx { txVersion = transactionVersion t
       , txIn = map i (transactionInputs t)
       , txOut = map o (transactionOutputs t)
       , txWitness = w $ map inputWitness (transactionInputs t)
       , txLockTime = transactionLockTime t
       }
  where
    i StoreCoinbase {inputPoint = p, inputSequence = q, inputSigScript = s} =
        TxIn {prevOutput = p, scriptInput = s, txInSequence = q}
    i StoreInput {inputPoint = p, inputSequence = q, inputSigScript = s} =
        TxIn {prevOutput = p, scriptInput = s, txInSequence = q}
    o StoreOutput {outputAmount = v, outputScript = s} =
        TxOut {outValue = v, scriptOutput = s}
    w xs | all null xs = []
         | otherwise = xs

transactionToJSON :: Network -> Transaction -> Value
transactionToJSON net dtx =
    A.object
    [ "txid" .= transactionId dtx
    , "size" .= transactionSize dtx
    , "version" .= transactionVersion dtx
    , "locktime" .= transactionLockTime dtx
    , "fee" .= transactionFees dtx
    , "inputs" .= map (storeInputToJSON net) (transactionInputs dtx)
    , "outputs" .= map (storeOutputToJSON net) (transactionOutputs dtx)
    , "block" .= transactionBlock dtx
    , "deleted" .= transactionDeleted dtx
    , "time" .= transactionTime dtx
    , "rbf" .= transactionRBF dtx
    , "weight" .= transactionWeight dtx
    ]

transactionToEncoding :: Network -> Transaction -> Encoding
transactionToEncoding net dtx =
    AE.pairs $
    "txid" .= transactionId dtx <>
    "size" .= transactionSize dtx <>
    "version" .= transactionVersion dtx <>
    "locktime" .= transactionLockTime dtx <>
    "fee" .= transactionFees dtx <>
    "inputs" `AE.pair` AE.list
    (storeInputToEncoding net) (transactionInputs dtx) <>
    "outputs" `AE.pair` AE.list
    (storeOutputToEncoding net) (transactionOutputs dtx) <>
    "block" .= transactionBlock dtx <>
    "deleted" .= transactionDeleted dtx <>
    "time" .= transactionTime dtx <>
    "rbf" .= transactionRBF dtx <>
    "weight" .= transactionWeight dtx

transactionParseJSON :: Network -> Value -> Parser Transaction
transactionParseJSON net = A.withObject "transaction" $ \o -> do
    version <- o .: "version"
    locktime <- o .: "locktime"
    inputs <- o .: "inputs" >>= mapM (storeInputParseJSON net)
    outputs <- o .: "outputs" >>= mapM (storeOutputParseJSON net)
    block <- o .: "block"
    deleted <- o .: "deleted"
    time <- o .: "time"
    rbf <- o .:? "rbf" .!= False
    weight <- o .:? "weight" .!= 0
    size <- o .: "size"
    txid <- o .: "txid"
    fees <- o .: "fee"
    return
        Transaction
            { transactionBlock = block
            , transactionVersion = version
            , transactionLockTime = locktime
            , transactionInputs = inputs
            , transactionOutputs = outputs
            , transactionDeleted = deleted
            , transactionTime = time
            , transactionRBF = rbf
            , transactionWeight = weight
            , transactionSize = size
            , transactionId = txid
            , transactionFees = fees
            }

-- | Information about a connected peer.
data PeerInformation =
    PeerInformation
        { peerUserAgent :: !ByteString
                        -- ^ user agent string
        , peerAddress   :: !String
                        -- ^ network address
        , peerVersion   :: !Word32
                        -- ^ version number
        , peerServices  :: !Word64
                        -- ^ services field
        , peerRelay     :: !Bool
                        -- ^ will relay transactions
        }
    deriving (Show, Eq, Ord, Generic, NFData)

instance Serial PeerInformation where
    serialize PeerInformation{..} = do
        putLengthBytes peerUserAgent
        putLengthBytes (TE.encodeUtf8 (T.pack peerAddress))
        putWord32be peerVersion
        putWord64be peerServices
        serialize peerRelay
    deserialize = do
        peerUserAgent <- getLengthBytes
        peerAddress <- T.unpack . TE.decodeUtf8 <$> getLengthBytes
        peerVersion <- getWord32be
        peerServices <- getWord64be
        peerRelay <- deserialize
        return PeerInformation{..}

instance Serialize PeerInformation where
    put = serialize
    get = deserialize

instance Binary PeerInformation where
    put = serialize
    get = deserialize

instance ToJSON PeerInformation where
    toJSON p =
        A.object
        [ "useragent"   .= String (cs (peerUserAgent p))
        , "address"     .= peerAddress p
        , "version"     .= peerVersion p
        , "services"    .=
            String (encodeHex (runPutS (serialize (peerServices p))))
        , "relay"       .= peerRelay p
        ]
    toEncoding p =
        AE.pairs $
        "useragent" `AE.pair` AE.text (cs (peerUserAgent p)) <>
        "address"   .= peerAddress p <>
        "version"   .= peerVersion p <>
        "services"  `AE.pair` AE.text
        (encodeHex (runPutS (serialize (peerServices p)))) <>
        "relay"     .= peerRelay p

instance FromJSON PeerInformation where
    parseJSON =
        A.withObject "peerinformation" $ \o -> do
        String useragent <- o .: "useragent"
        address <- o .: "address"
        version <- o .: "version"
        services <-
            o .: "services" >>= jsonHex >>= \b ->
                case runGetS deserialize b of
                    Left e  -> fail $ "Could not decode services: " <> e
                    Right s -> return s
        relay <- o .: "relay"
        return
            PeerInformation
                { peerUserAgent = cs useragent
                , peerAddress = address
                , peerVersion = version
                , peerServices = services
                , peerRelay = relay
                }

-- | Address balances for an extended public key.
data XPubBal =
    XPubBal
        { xPubBalPath :: ![KeyIndex]
        , xPubBal     :: !Balance
        }
    deriving (Show, Ord, Eq, Generic, NFData)

instance Serial XPubBal where
    serialize XPubBal{..} = do
        putList putWord32be xPubBalPath
        serialize xPubBal
    deserialize = do
        xPubBalPath <- getList getWord32be
        xPubBal <- deserialize
        return XPubBal{..}

instance Serialize XPubBal where
    put = serialize
    get = deserialize

instance Binary XPubBal where
    put = serialize
    get = deserialize

xPubBalToJSON :: Network -> XPubBal -> Value
xPubBalToJSON net XPubBal {xPubBalPath = p, xPubBal = b} =
    A.object ["path" .= p, "balance" .= balanceToJSON net b]

xPubBalToEncoding :: Network -> XPubBal -> Encoding
xPubBalToEncoding net XPubBal {xPubBalPath = p, xPubBal = b} =
    AE.pairs ("path" .= p <> "balance" `AE.pair` balanceToEncoding net b)

xPubBalParseJSON :: Network -> Value -> Parser XPubBal
xPubBalParseJSON net =
    A.withObject "xpubbal" $ \o -> do
        path <- o .: "path"
        balance <- balanceParseJSON net =<< o .: "balance"
        return XPubBal {xPubBalPath = path, xPubBal = balance}

-- | Unspent transaction for extended public key.
data XPubUnspent =
    XPubUnspent
        { xPubUnspentPath :: ![KeyIndex]
        , xPubUnspent     :: !Unspent
        }
    deriving (Show, Eq, Generic, NFData)

instance Serial XPubUnspent where
    serialize XPubUnspent{..} = do
        putList putWord32be xPubUnspentPath
        serialize xPubUnspent
    deserialize = do
        xPubUnspentPath <- getList getWord32be
        xPubUnspent <- deserialize
        return XPubUnspent{..}

instance Serialize XPubUnspent where
    put = serialize
    get = deserialize

instance Binary XPubUnspent where
    put = serialize
    get = deserialize

xPubUnspentToJSON :: Network -> XPubUnspent -> Value
xPubUnspentToJSON
    net
    XPubUnspent
    {
        xPubUnspentPath = p,
        xPubUnspent = u
    } =
    A.object
    [ "path" .= p
    , "unspent" .= unspentToJSON net u
    ]

xPubUnspentToEncoding :: Network -> XPubUnspent -> Encoding
xPubUnspentToEncoding
    net
    XPubUnspent
    {
        xPubUnspentPath = p,
        xPubUnspent = u
    } =
    AE.pairs $
    "path" .= p <>
    "unspent" `AE.pair` unspentToEncoding net u

xPubUnspentParseJSON :: Network -> Value -> Parser XPubUnspent
xPubUnspentParseJSON net =
    A.withObject "xpubunspent" $ \o -> do
        p <- o .: "path"
        u <- o .: "unspent" >>= unspentParseJSON net
        return XPubUnspent {xPubUnspentPath = p, xPubUnspent = u}

data XPubSummary =
    XPubSummary
        { xPubSummaryConfirmed :: !Word64
        , xPubSummaryZero      :: !Word64
        , xPubSummaryReceived  :: !Word64
        , xPubUnspentCount     :: !Word64
        , xPubExternalIndex    :: !Word32
        , xPubChangeIndex      :: !Word32
        }
    deriving (Eq, Show, Generic, NFData)

instance Serial XPubSummary where
    serialize XPubSummary{..} = do
        putWord64be xPubSummaryConfirmed
        putWord64be xPubSummaryZero
        putWord64be xPubSummaryReceived
        putWord64be xPubUnspentCount
        putWord32be xPubExternalIndex
        putWord32be xPubChangeIndex
    deserialize = do
        xPubSummaryConfirmed <- getWord64be
        xPubSummaryZero      <- getWord64be
        xPubSummaryReceived  <- getWord64be
        xPubUnspentCount     <- getWord64be
        xPubExternalIndex    <- getWord32be
        xPubChangeIndex      <- getWord32be
        return XPubSummary{..}

instance Binary XPubSummary where
    put = serialize
    get = deserialize

instance Serialize XPubSummary where
    put = serialize
    get = deserialize

instance ToJSON XPubSummary where
    toJSON
        XPubSummary
        {
            xPubSummaryConfirmed = c,
            xPubSummaryZero = z,
            xPubSummaryReceived = r,
            xPubUnspentCount = u,
            xPubExternalIndex = ext,
            xPubChangeIndex = ch
        } =
        A.object
        [ "balance" .=
            A.object
            [ "confirmed" .= c
            , "unconfirmed" .= z
            , "received" .= r
            , "utxo" .= u
            ]
        , "indices" .=
            A.object
            [ "change" .= ch
            , "external" .= ext
            ]
        ]
    toEncoding
        XPubSummary
        {
            xPubSummaryConfirmed = c,
            xPubSummaryZero = z,
            xPubSummaryReceived = r,
            xPubUnspentCount = u,
            xPubExternalIndex = ext,
            xPubChangeIndex = ch
        } =
        AE.pairs $
            "balance" `AE.pair` AE.pairs
            (
                "confirmed" .= c <>
                "unconfirmed" .= z <>
                "received" .= r <>
                "utxo" .= u
            ) <>
            "indices" `AE.pair` AE.pairs
            (
                "change" .= ch <>
                "external" .= ext
            )

instance FromJSON XPubSummary where
    parseJSON =
        A.withObject "xpubsummary" $ \o -> do
            b <- o .: "balance"
            i <- o .: "indices"
            conf <- b .: "confirmed"
            unconfirmed <- b .: "unconfirmed"
            received <- b .: "received"
            utxo <- b .: "utxo"
            change <- i .: "change"
            external <- i .: "external"
            return
                XPubSummary
                    { xPubSummaryConfirmed = conf
                    , xPubSummaryZero = unconfirmed
                    , xPubSummaryReceived = received
                    , xPubUnspentCount = utxo
                    , xPubExternalIndex = external
                    , xPubChangeIndex = change
                    }

class Healthy a where
    isOK :: a -> Bool

data BlockHealth =
    BlockHealth
        { blockHealthHeaders :: !BlockHeight
        , blockHealthBlocks  :: !BlockHeight
        , blockHealthMaxDiff :: !Int32
        }
    deriving (Show, Eq, Generic, NFData)

instance Serial BlockHealth where
    serialize h@BlockHealth{..} = do
        serialize (isOK h)
        putWord32be blockHealthHeaders
        putWord32be blockHealthBlocks
        putInt32be blockHealthMaxDiff
    deserialize = do
        k                  <- deserialize
        blockHealthHeaders <- getWord32be
        blockHealthBlocks  <- getWord32be
        blockHealthMaxDiff <- getInt32be
        let h = BlockHealth{..}
        unless (k == isOK h) $ fail "Inconsistent health check"
        return h

instance Serialize BlockHealth where
    put = serialize
    get = deserialize

instance Binary BlockHealth where
    put = serialize
    get = deserialize

instance Healthy BlockHealth where
    isOK BlockHealth{..} =
        h - b <= blockHealthMaxDiff
      where
        h = fromIntegral blockHealthHeaders
        b = fromIntegral blockHealthBlocks

instance ToJSON BlockHealth where
    toJSON h@BlockHealth{..} =
        A.object
            [ "headers"  .= blockHealthHeaders
            , "blocks"   .= blockHealthBlocks
            , "diff"     .= diff
            , "max"      .= blockHealthMaxDiff
            , "ok"       .= isOK h
            ]
      where
        diff = blockHealthHeaders - blockHealthBlocks

instance FromJSON BlockHealth where
    parseJSON =
        A.withObject "BlockHealth" $ \o -> do
            blockHealthHeaders  <- o .: "headers"
            blockHealthBlocks   <- o .: "blocks"
            blockHealthMaxDiff  <- o .: "max"
            return BlockHealth {..}

data TimeHealth =
    TimeHealth
        { timeHealthAge :: !Int64
        , timeHealthMax :: !Int64
        }
    deriving (Show, Eq, Generic, NFData)

instance Serial TimeHealth where
    serialize h@TimeHealth{..} = do
        serialize (isOK h)
        putInt64be timeHealthAge
        putInt64be timeHealthMax
    deserialize = do
        k             <- deserialize
        timeHealthAge <- getInt64be
        timeHealthMax <- getInt64be
        let t = TimeHealth{..}
        unless (k == isOK t) $ fail "Inconsistent health check"
        return t

instance Binary TimeHealth where
    put = serialize
    get = deserialize

instance Serialize TimeHealth where
    put = serialize
    get = deserialize

instance Healthy TimeHealth where
    isOK TimeHealth{..} =
        timeHealthAge <= timeHealthMax

instance ToJSON TimeHealth where
    toJSON h@TimeHealth{..} =
        A.object
            [ "age"  .= timeHealthAge
            , "max"  .= timeHealthMax
            , "ok"   .= isOK h
            ]

instance FromJSON TimeHealth where
    parseJSON =
        A.withObject "TimeHealth" $ \o -> do
            timeHealthAge <- o .: "age"
            timeHealthMax <- o .: "max"
            return TimeHealth {..}

data CountHealth =
    CountHealth
        { countHealthNum :: !Int64
        , countHealthMin :: !Int64
        }
    deriving (Show, Eq, Generic, NFData)

instance Serial CountHealth where
    serialize h@CountHealth{..} = do
        serialize (isOK h)
        putInt64be countHealthNum
        putInt64be countHealthMin
    deserialize = do
        k              <- deserialize
        countHealthNum <- getInt64be
        countHealthMin <- getInt64be
        let c = CountHealth{..}
        unless (k == isOK c) $ fail "Inconsistent health check"
        return c

instance Serialize CountHealth where
    put = serialize
    get = deserialize

instance Binary CountHealth where
    put = serialize
    get = deserialize

instance Healthy CountHealth where
    isOK CountHealth {..} =
        countHealthMin <= countHealthNum

instance ToJSON CountHealth where
    toJSON h@CountHealth {..} =
        A.object
            [ "count"  .= countHealthNum
            , "min"    .= countHealthMin
            , "ok"     .= isOK h
            ]

instance FromJSON CountHealth where
    parseJSON =
        A.withObject "CountHealth" $ \o -> do
            countHealthNum <- o .: "count"
            countHealthMin <- o .: "min"
            return CountHealth {..}

data MaxHealth =
    MaxHealth
        { maxHealthNum :: !Int64
        , maxHealthMax :: !Int64
        }
    deriving (Show, Eq, Generic, NFData)

instance Serial MaxHealth where
    serialize h@MaxHealth {..} = do
        serialize $ isOK h
        putInt64be maxHealthNum
        putInt64be maxHealthMax
    deserialize = do
        k            <- deserialize
        maxHealthNum <- getInt64be
        maxHealthMax <- getInt64be
        let h = MaxHealth{..}
        unless (k == isOK h) $ fail "Inconsistent health check"
        return h

instance Binary MaxHealth where
    put = serialize
    get = deserialize

instance Serialize MaxHealth where
    put = serialize
    get = deserialize

instance Healthy MaxHealth where
    isOK MaxHealth {..} = maxHealthNum <= maxHealthMax

instance ToJSON MaxHealth where
    toJSON h@MaxHealth {..} =
        A.object
            [ "count" .= maxHealthNum
            , "max"   .= maxHealthMax
            , "ok"    .= isOK h
            ]

instance FromJSON MaxHealth where
    parseJSON =
        A.withObject "MaxHealth" $ \o -> do
            maxHealthNum <- o .: "count"
            maxHealthMax <- o .: "max"
            return MaxHealth {..}

data HealthCheck =
    HealthCheck
        { healthBlocks     :: !BlockHealth
        , healthLastBlock  :: !TimeHealth
        , healthLastTx     :: !TimeHealth
        , healthPendingTxs :: !MaxHealth
        , healthPeers      :: !CountHealth
        , healthNetwork    :: !String
        , healthVersion    :: !String
        }
    deriving (Show, Eq, Generic, NFData)

instance Serial HealthCheck where
    serialize h@HealthCheck {..} = do
        serialize (isOK h)
        serialize healthBlocks
        serialize healthLastBlock
        serialize healthLastTx
        serialize healthPendingTxs
        serialize healthPeers
        putLengthBytes ((TE.encodeUtf8 . T.pack) healthNetwork)
        putLengthBytes ((TE.encodeUtf8 . T.pack) healthVersion)
    deserialize = do
        k                   <- deserialize
        healthBlocks        <- deserialize
        healthLastBlock     <- deserialize
        healthLastTx        <- deserialize
        healthPendingTxs    <- deserialize
        healthPeers         <- deserialize
        healthNetwork       <- T.unpack . TE.decodeUtf8 <$> getLengthBytes
        healthVersion       <- T.unpack . TE.decodeUtf8 <$> getLengthBytes
        let h = HealthCheck {..}
        unless (k == isOK h) $ fail "Inconsistent health check"
        return h

instance Binary HealthCheck where
    put = serialize
    get = deserialize

instance Serialize HealthCheck where
    put = serialize
    get = deserialize

instance Healthy HealthCheck where
    isOK HealthCheck {..} =
        isOK healthBlocks &&
        isOK healthLastBlock &&
        isOK healthLastTx &&
        isOK healthPendingTxs &&
        isOK healthPeers

instance ToJSON HealthCheck where
    toJSON h@HealthCheck {..} =
        A.object
            [ "blocks"      .= healthBlocks
            , "last-block"  .= healthLastBlock
            , "last-tx"     .= healthLastTx
            , "pending-txs" .= healthPendingTxs
            , "peers"       .= healthPeers
            , "net"         .= healthNetwork
            , "version"     .= healthVersion
            , "ok"          .= isOK h
            ]

instance FromJSON HealthCheck where
    parseJSON =
        A.withObject "HealthCheck" $ \o -> do
            healthBlocks     <- o .: "blocks"
            healthLastBlock  <- o .: "last-block"
            healthLastTx     <- o .: "last-tx"
            healthPendingTxs <- o .: "pending-txs"
            healthPeers      <- o .: "peers"
            healthNetwork    <- o .: "net"
            healthVersion    <- o .: "version"
            return HealthCheck {..}

data Event
    = EventBlock !BlockHash
    | EventTx !TxHash
    deriving (Show, Eq, Generic, NFData)

instance Serial Event where
    serialize (EventBlock bh) = putWord8 0x00 >> serialize bh
    serialize (EventTx th)    = putWord8 0x01 >> serialize th
    deserialize =
        getWord8 >>= \case
        0x00 -> EventBlock <$> deserialize
        0x01 -> EventTx <$> deserialize
        _    -> fail "Not an Event"

instance Serialize Event where
    put = serialize
    get = deserialize

instance Binary Event where
    put = serialize
    get = deserialize

instance ToJSON Event where
    toJSON (EventTx h) =
        A.object
        [ "type" .= String "tx"
        , "id" .= h
        ]
    toJSON (EventBlock h) =
        A.object
        [ "type" .= String "block"
        , "id" .= h
        ]
    toEncoding (EventTx h) =
        AE.pairs $
        "type" `AE.pair` AE.text "tx" <>
        "id" `AE.pair` AE.text (txHashToHex h)
    toEncoding (EventBlock h) =
        AE.pairs $
        "type" `AE.pair` AE.text "block" <>
        "id" `AE.pair` AE.text (blockHashToHex h)

instance FromJSON Event where
    parseJSON =
        A.withObject "event" $ \o -> do
        t <- o .: "type"
        case t of
            "tx" -> do
                i <- o .: "id"
                return $ EventTx i
            "block" -> do
                i <- o .: "id"
                return $ EventBlock i
            _ -> fail $ "Could not recognize event type: " <> t

newtype GenericResult a =
    GenericResult
        { getResult :: a
        }
    deriving (Show, Eq, Generic, NFData)

instance Serial a => Serial (GenericResult a) where
    serialize (GenericResult x) = serialize x
    deserialize = GenericResult <$> deserialize

instance Serial a => Serialize (GenericResult a) where
    put = serialize
    get = deserialize

instance Serial a => Binary (GenericResult a) where
    put = serialize
    get = deserialize

instance ToJSON a => ToJSON (GenericResult a) where
    toJSON (GenericResult b) = A.object ["result" .= b]
    toEncoding (GenericResult b) = AE.pairs ("result" .= b)

instance FromJSON a => FromJSON (GenericResult a) where
    parseJSON =
        A.withObject "GenericResult" $ \o ->
        GenericResult <$> o .: "result"

newtype RawResult a =
    RawResult
        { getRawResult :: a
        }
    deriving (Show, Eq, Generic, NFData)

instance Serial a => Serial (RawResult a) where
    serialize (RawResult x) = serialize x
    deserialize = RawResult <$> deserialize

instance Serial a => Serialize (RawResult a) where
    put = serialize
    get = deserialize

instance Serial a => Binary (RawResult a) where
    put = serialize
    get = deserialize

instance Serial a => ToJSON (RawResult a) where
    toJSON (RawResult b) =
        A.object ["result" .= x b]
      where
        x = TLE.decodeUtf8 .
            BSB.toLazyByteString .
            BSB.lazyByteStringHex .
            runPutL . serialize
    toEncoding (RawResult b) =
        AE.pairs $ "result" `AE.pair` AE.unsafeToEncoding str
      where
        str = BSB.char7 '"' <>
              BSB.lazyByteStringHex (runPutL (serialize b)) <>
              BSB.char7 '"'

instance Serial a => FromJSON (RawResult a) where
    parseJSON =
        A.withObject "RawResult" $ \o -> do
            res <- o .: "result"
            let m = eitherToMaybe . Bytes.Get.runGetS deserialize =<<
                    decodeHex res
            maybe mzero (return . RawResult) m

newtype SerialList a = SerialList{ getSerialList :: [a] }
    deriving (Show, Eq, Generic, NFData)

instance Semigroup (SerialList a) where
    SerialList a <> SerialList b = SerialList (a <> b)

instance Monoid (SerialList a) where
    mempty = SerialList mempty

instance Serial a => Serial (SerialList a) where
    serialize (SerialList ls) = putList serialize ls
    deserialize = SerialList <$> getList deserialize

instance ToJSON a => ToJSON (SerialList a) where
    toJSON (SerialList ls) = toJSON ls
    toEncoding (SerialList ls) = toEncoding ls

instance FromJSON a => FromJSON (SerialList a) where
    parseJSON = fmap SerialList . parseJSON

newtype RawResultList a =
    RawResultList
        { getRawResultList :: [a]
        }
    deriving (Show, Eq, Generic, NFData)

instance Serial a => Serial (RawResultList a) where
    serialize (RawResultList xs) =
        mapM_ serialize xs
    deserialize = RawResultList <$> go
      where
        go = isEmpty >>= \case
            True  -> return []
            False -> (:) <$> deserialize <*> go

instance Serial a => Serialize (RawResultList a) where
    put = serialize
    get = deserialize

instance Serial a => Binary (RawResultList a) where
    put = serialize
    get = deserialize

instance Semigroup (RawResultList a) where
    (RawResultList a) <> (RawResultList b) = RawResultList $ a <> b

instance Monoid (RawResultList a) where
    mempty = RawResultList mempty

instance Serial a => ToJSON (RawResultList a) where
    toJSON (RawResultList xs) =
        toJSON $
        TLE.decodeUtf8 .
        BSB.toLazyByteString .
        BSB.lazyByteStringHex .
        runPutL .
        serialize <$> xs
    toEncoding (RawResultList xs) =
        AE.list (AE.unsafeToEncoding . str) xs
      where
        str x =
            BSB.char7 '"' <>
            BSB.lazyByteStringHex (runPutL (serialize x)) <>
            BSB.char7 '"'

instance Serial a => FromJSON (RawResultList a) where
    parseJSON =
        A.withArray "RawResultList" $ \vec ->
            RawResultList <$> mapM parseElem (toList vec)
      where
        parseElem = A.withText "RawResultListElem" $ maybe mzero return . f
        f = eitherToMaybe . Bytes.Get.runGetS deserialize <=< decodeHex

newtype TxId =
    TxId TxHash
    deriving (Show, Eq, Generic, NFData)

instance Serial TxId where
    serialize (TxId h) = serialize h
    deserialize = TxId <$> deserialize

instance Serialize TxId where
    put = serialize
    get = deserialize

instance Binary TxId where
    put = serialize
    get = deserialize

instance ToJSON TxId where
    toJSON (TxId h) = A.object ["txid" .= h]
    toEncoding (TxId h) = AE.pairs ("txid" `AE.pair` AE.text (txHashToHex h))

instance FromJSON TxId where
    parseJSON = A.withObject "txid" $ \o -> TxId <$> o .: "txid"

data Except
    = ThingNotFound
    | ServerError
    | BadRequest
    | UserError !String
    | StringError !String
    | TxIndexConflict ![TxHash]
    | ServerTimeout
    | RequestTooLarge
    deriving (Show, Eq, Ord, Generic, NFData)

instance Exception Except

instance ScottyError Except where
    stringError = StringError
    showError = TL.pack . show

instance ToJSON Except where
    toJSON e =
        A.object $
        case e of
            ThingNotFound ->
                [ "error" .= String "not-found-or-invalid-arg"
                , "message" .= String "Item not found or argument invalid"
                ]
            ServerError ->
                [ "error" .= String "server-error"
                , "message" .= String "Server error" ]
            BadRequest ->
                [ "error" .= String "bad-request"
                , "message" .= String "Invalid request" ]
            UserError msg ->
                [ "error" .= String "user-error"
                , "message" .= String (cs msg) ]
            StringError msg ->
                [ "error" .= String "string-error"
                , "message" .= String (cs msg) ]
            TxIndexConflict txids ->
                [ "error" .= String "multiple-tx-index"
                , "message" .= String "Many txs match that tx_index"
                , "txids" .= txids ]
            ServerTimeout ->
                [ "error" .= String "server-timeout"
                , "message" .= String "Request is taking too long" ]
            RequestTooLarge ->
                [ "error" .= String "request-too-large"
                , "message" .= String "Request body too large" ]

instance FromJSON Except where
    parseJSON =
        A.withObject "Except" $ \o -> do
            ctr <- o .: "error"
            msg <- o .:? "message" .!= ""
            case ctr of
                String "not-found-or-invalid-arg" ->
                    return ThingNotFound
                String "server-error" ->
                    return ServerError
                String "bad-request" ->
                    return BadRequest
                String "user-error" ->
                    return $ UserError msg
                String "string-error" ->
                    return $ StringError msg
                String "multiple-tx-index" -> do
                    txids <- o .: "txids"
                    return $ TxIndexConflict txids
                String "server-timeout" ->
                    return ServerTimeout
                String "request-too-large" ->
                    return RequestTooLarge
                _ -> mzero

toIntTxId :: TxHash -> Word64
toIntTxId h =
    let bs = runPutS (serialize h)
        Right w64 = runGetS getWord64be bs
    in w64 `shift` (-11)

---------------------------------------
-- Blockchain.info API Compatibility --
---------------------------------------

data BinfoBlockId
    = BinfoBlockHash !BlockHash
    | BinfoBlockIndex !Word32
    deriving (Eq, Show, Read, Generic, NFData)

instance Parsable BinfoBlockId where
    parseParam t =
        hex <> igr
      where
        hex =
            case hexToBlockHash (TL.toStrict t) of
                Nothing -> Left "could not decode txid"
                Just h  -> Right $ BinfoBlockHash h
        igr = BinfoBlockIndex <$> parseParam t

data BinfoTxId
    = BinfoTxIdHash !TxHash
    | BinfoTxIdIndex !Word64
    deriving (Eq, Show, Read, Generic, NFData)

encodeBinfoTxId :: Bool -> TxHash -> BinfoTxId
encodeBinfoTxId False = BinfoTxIdHash
encodeBinfoTxId True  = BinfoTxIdIndex . toIntTxId

instance Parsable BinfoTxId where
    parseParam t =
        hex <> igr
      where
        hex =
            case hexToTxHash (TL.toStrict t) of
                Nothing -> Left "could not decode txid"
                Just h  -> Right $ BinfoTxIdHash h
        igr = BinfoTxIdIndex <$> parseParam t

instance ToJSON BinfoTxId where
    toJSON (BinfoTxIdHash h)  = toJSON h
    toJSON (BinfoTxIdIndex i) = toJSON i
    toEncoding (BinfoTxIdHash h)  = toEncoding h
    toEncoding (BinfoTxIdIndex i) = toEncoding i

instance FromJSON BinfoTxId where
    parseJSON v = BinfoTxIdHash <$> parseJSON v <|>
                  BinfoTxIdIndex <$> parseJSON v

data BinfoFilter
    = BinfoFilterAll
    | BinfoFilterSent
    | BinfoFilterReceived
    | BinfoFilterMoved
    | BinfoFilterConfirmed
    | BinfoFilterMempool
    deriving (Eq, Show, Generic, NFData)

instance Parsable BinfoFilter where
    parseParam t =
        parseParam t >>= \case
        (0 :: Int) -> return BinfoFilterAll
        1          -> return BinfoFilterSent
        2          -> return BinfoFilterReceived
        3          -> return BinfoFilterMoved
        5          -> return BinfoFilterConfirmed
        6          -> return BinfoFilterAll
        7          -> return BinfoFilterMempool
        _          -> Left "could not parse filter parameter"

data BinfoMultiAddr
    = BinfoMultiAddr
        { getBinfoMultiAddrAddresses    :: ![BinfoBalance]
        , getBinfoMultiAddrWallet       :: !BinfoWallet
        , getBinfoMultiAddrTxs          :: ![BinfoTx]
        , getBinfoMultiAddrInfo         :: !BinfoInfo
        , getBinfoMultiAddrRecommendFee :: !Bool
        , getBinfoMultiAddrCashAddr     :: !Bool
        }
    deriving (Eq, Show, Generic, NFData)

binfoMultiAddrToJSON :: Network -> BinfoMultiAddr -> Value
binfoMultiAddrToJSON net' BinfoMultiAddr {..} =
    A.object $
        [ "addresses" .= map (binfoBalanceToJSON net) getBinfoMultiAddrAddresses
        , "wallet"    .= getBinfoMultiAddrWallet
        , "txs"       .= map (binfoTxToJSON net) getBinfoMultiAddrTxs
        , "info"      .= getBinfoMultiAddrInfo
        , "recommend_include_fee" .= getBinfoMultiAddrRecommendFee
        ] ++
        [ "cash_addr" .= True | getBinfoMultiAddrCashAddr ]
  where
    net = if not getBinfoMultiAddrCashAddr && net' == bch then btc else net'

binfoMultiAddrParseJSON :: Network -> Value -> Parser BinfoMultiAddr
binfoMultiAddrParseJSON net = A.withObject "multiaddr" $ \o -> do
    getBinfoMultiAddrAddresses <-
        mapM (binfoBalanceParseJSON net) =<< o .: "addresses"
    getBinfoMultiAddrWallet <- o .: "wallet"
    getBinfoMultiAddrTxs <-
        mapM (binfoTxParseJSON net) =<< o .: "txs"
    getBinfoMultiAddrInfo <- o .: "info"
    getBinfoMultiAddrRecommendFee <- o .: "recommend_include_fee"
    getBinfoMultiAddrCashAddr <- o .:? "cash_addr" .!= False
    return BinfoMultiAddr {..}

binfoMultiAddrToEncoding :: Network -> BinfoMultiAddr -> Encoding
binfoMultiAddrToEncoding net' BinfoMultiAddr {..} =
    AE.pairs
        (  "addresses" `AE.pair` as
        <> "wallet"    .= getBinfoMultiAddrWallet
        <> "txs"       `AE.pair` ts
        <> "info"      .= getBinfoMultiAddrInfo
        <> "recommend_include_fee" .= getBinfoMultiAddrRecommendFee
        <> if getBinfoMultiAddrCashAddr then "cash_addr" .= True else mempty
        )
  where
    as = AE.list (binfoBalanceToEncoding net) getBinfoMultiAddrAddresses
    ts = AE.list (binfoTxToEncoding net) getBinfoMultiAddrTxs
    net = if not getBinfoMultiAddrCashAddr && net' == bch then btc else net'

data BinfoRawAddr
    = BinfoRawAddr
      { getBinfoRawAddrBalance :: !Balance
      , getBinfoRawAddrTxs     :: ![BinfoTx]
      }
    deriving (Eq, Show, Generic, NFData)

binfoRawAddrToJSON :: Network -> BinfoRawAddr -> Value
binfoRawAddrToJSON net BinfoRawAddr{..} =
    A.object
    [
        "hash160"        .= (encodeHex . runPutS . serialize <$> h160),
        "address"        .= addrToJSON net balanceAddress,
        "n_tx"           .= balanceTxCount,
        "n_unredeemed"   .= balanceUnspentCount,
        "total_received" .= balanceTotalReceived,
        "total_sent"     .= (balanceTotalReceived - bal),
        "final_balance"  .= bal,
        "txs"            .= map (binfoTxToJSON net) getBinfoRawAddrTxs
    ]
  where
    Balance{..} = getBinfoRawAddrBalance
    bal = balanceAmount + balanceZero
    h160 = case balanceAddress of
               PubKeyAddress h        -> Just h
               ScriptAddress h        -> Just h
               WitnessPubKeyAddress h -> Just h
               _                      -> Nothing

binfoRawAddrToEncoding :: Network -> BinfoRawAddr -> Encoding
binfoRawAddrToEncoding net BinfoRawAddr{..} =
    AE.pairs $
    "hash160"        .= (encodeHex . runPutS . serialize <$> h160) <>
    "address" `AE.pair` addrToEncoding net balanceAddress <>
    "n_tx"           .= balanceTxCount <>
    "n_unredeemed"   .= balanceUnspentCount <>
    "total_received" .= balanceTotalReceived <>
    "total_sent"     .= (balanceTotalReceived - bal) <>
    "final_balance"  .= bal <>
    "txs"     `AE.pair` AE.list (binfoTxToEncoding net) getBinfoRawAddrTxs
  where
    Balance{..} = getBinfoRawAddrBalance
    bal = balanceAmount + balanceZero
    h160 = case balanceAddress of
               PubKeyAddress h        -> Just h
               ScriptAddress h        -> Just h
               WitnessPubKeyAddress h -> Just h
               _                      -> Nothing

binfoRawAddrParseJSON :: Network -> Value -> Parser BinfoRawAddr
binfoRawAddrParseJSON net = A.withObject "balancetxs" $ \o -> do
    balanceAddress <- addrFromJSON net =<< o .: "address"
    balanceAmount <- o .: "final_balance"
    let balanceZero = 0
    balanceUnspentCount <- o .: "n_unredeemed"
    balanceTxCount <- o .: "n_tx"
    balanceTotalReceived <- o .: "total_received"
    txs <- mapM (binfoTxParseJSON net) =<< o .: "txs"
    return
        BinfoRawAddr
        {
            getBinfoRawAddrBalance = Balance{..},
            getBinfoRawAddrTxs = txs
        }

data BinfoShortBal
    = BinfoShortBal
      { binfoShortBalFinal    :: !Word64
      , binfoShortBalTxCount  :: !Word64
      , binfoShortBalReceived :: !Word64
      }
    deriving (Eq, Show, Read, Generic, NFData)

instance ToJSON BinfoShortBal where
    toJSON BinfoShortBal{..} =
        A.object
        [
            "final_balance" .= binfoShortBalFinal,
            "n_tx" .= binfoShortBalTxCount,
            "total_received" .= binfoShortBalReceived
        ]
    toEncoding BinfoShortBal{..} =
        AE.pairs $
        "final_balance" .= binfoShortBalFinal <>
        "n_tx" .= binfoShortBalTxCount <>
        "total_received" .= binfoShortBalReceived

instance FromJSON BinfoShortBal where
    parseJSON = A.withObject "short_balance" $ \o -> do
        binfoShortBalFinal <- o .: "final_balance"
        binfoShortBalTxCount <- o .: "n_tx"
        binfoShortBalReceived <- o .: "total_received"
        return BinfoShortBal{..}

data BinfoBalance
    = BinfoAddrBalance
        { getBinfoAddress      :: !Address
        , getBinfoAddrTxCount  :: !Word64
        , getBinfoAddrReceived :: !Word64
        , getBinfoAddrSent     :: !Word64
        , getBinfoAddrBalance  :: !Word64
        }
    | BinfoXPubBalance
        { getBinfoXPubKey          :: !XPubKey
        , getBinfoAddrTxCount      :: !Word64
        , getBinfoAddrReceived     :: !Word64
        , getBinfoAddrSent         :: !Word64
        , getBinfoAddrBalance      :: !Word64
        , getBinfoXPubAccountIndex :: !Word32
        , getBinfoXPubChangeIndex  :: !Word32
        }
    deriving (Eq, Show, Generic, NFData)

binfoBalanceToJSON :: Network -> BinfoBalance -> Value
binfoBalanceToJSON net BinfoAddrBalance {..} =
    A.object
        [ "address"        .= addrToJSON net getBinfoAddress
        , "final_balance"  .= getBinfoAddrBalance
        , "n_tx"           .= getBinfoAddrTxCount
        , "total_received" .= getBinfoAddrReceived
        , "total_sent"     .= getBinfoAddrSent
        ]
binfoBalanceToJSON net BinfoXPubBalance {..} =
    A.object
        [ "address"        .= xPubToJSON net getBinfoXPubKey
        , "change_index"   .= getBinfoXPubChangeIndex
        , "account_index"  .= getBinfoXPubAccountIndex
        , "final_balance"  .= getBinfoAddrBalance
        , "n_tx"           .= getBinfoAddrTxCount
        , "total_received" .= getBinfoAddrReceived
        , "total_sent"     .= getBinfoAddrSent
        ]

binfoBalanceParseJSON :: Network -> Value -> Parser BinfoBalance
binfoBalanceParseJSON net = A.withObject "address" $ \o -> x o <|> a o
  where
    x o = do
        getBinfoXPubKey <- xPubFromJSON net =<< o .: "address"
        getBinfoXPubChangeIndex <- o .: "change_index"
        getBinfoXPubAccountIndex <- o .: "account_index"
        getBinfoAddrBalance <- o .: "final_balance"
        getBinfoAddrTxCount <- o .: "n_tx"
        getBinfoAddrReceived <- o .: "total_received"
        getBinfoAddrSent <- o .: "total_sent"
        return BinfoXPubBalance{..}
    a o = do
        getBinfoAddress <- addrFromJSON net =<< o .: "address"
        getBinfoAddrBalance <- o .: "final_balance"
        getBinfoAddrTxCount <- o .: "n_tx"
        getBinfoAddrReceived <- o .: "total_received"
        getBinfoAddrSent <- o .: "total_sent"
        return BinfoAddrBalance{..}

binfoBalanceToEncoding :: Network -> BinfoBalance -> Encoding
binfoBalanceToEncoding net BinfoAddrBalance {..} =
    AE.pairs
        (  "address"         `AE.pair` addrToEncoding net getBinfoAddress
        <> "final_balance"   .= getBinfoAddrBalance
        <> "n_tx"            .= getBinfoAddrTxCount
        <> "total_received"  .= getBinfoAddrReceived
        <> "total_sent"      .= getBinfoAddrSent
        )
binfoBalanceToEncoding net BinfoXPubBalance {..} =
    AE.pairs
        (  "address"         `AE.pair` xPubToEncoding net getBinfoXPubKey
        <> "change_index"    .= getBinfoXPubChangeIndex
        <> "account_index"   .= getBinfoXPubAccountIndex
        <> "final_balance"   .= getBinfoAddrBalance
        <> "n_tx"            .= getBinfoAddrTxCount
        <> "total_received"  .= getBinfoAddrReceived
        <> "total_sent"      .= getBinfoAddrSent
        )

data BinfoWallet
    = BinfoWallet
        { getBinfoWalletBalance       :: !Word64
        , getBinfoWalletTxCount       :: !Word64
        , getBinfoWalletFilteredCount :: !Word64
        , getBinfoWalletTotalReceived :: !Word64
        , getBinfoWalletTotalSent     :: !Word64
        }
    deriving (Eq, Show, Generic, NFData)

instance ToJSON BinfoWallet where
    toJSON BinfoWallet {..} =
        A.object
            [ "final_balance"     .= getBinfoWalletBalance
            , "n_tx"              .= getBinfoWalletTxCount
            , "n_tx_filtered"     .= getBinfoWalletFilteredCount
            , "total_received"    .= getBinfoWalletTotalReceived
            , "total_sent"        .= getBinfoWalletTotalSent
            ]
    toEncoding BinfoWallet {..} =
        AE.pairs
            (  "final_balance"    .= getBinfoWalletBalance
            <> "n_tx"             .= getBinfoWalletTxCount
            <> "n_tx_filtered"    .= getBinfoWalletFilteredCount
            <> "total_received"   .= getBinfoWalletTotalReceived
            <> "total_sent"       .= getBinfoWalletTotalSent
            )

instance FromJSON BinfoWallet where
    parseJSON = A.withObject "wallet" $ \o -> do
        getBinfoWalletBalance <- o .: "final_balance"
        getBinfoWalletTxCount <- o .: "n_tx"
        getBinfoWalletFilteredCount <- o .: "n_tx_filtered"
        getBinfoWalletTotalReceived <- o .: "total_received"
        getBinfoWalletTotalSent <- o .: "total_sent"
        return BinfoWallet {..}

binfoHexValue :: Word64 -> Text
binfoHexValue w64 =
    let bs = BS.dropWhile (== 0x00) (runPutS (serialize w64))
    in encodeHex $
       if BS.null bs || BS.head bs `testBit` 7
       then BS.cons 0x00 bs
       else bs

data BinfoUnspent
    = BinfoUnspent
      { getBinfoUnspentHash          :: !TxHash
      , getBinfoUnspentOutputIndex   :: !Word32
      , getBinfoUnspentScript        :: !ByteString
      , getBinfoUnspentValue         :: !Word64
      , getBinfoUnspentConfirmations :: !Int32
      , getBinfoUnspentTxIndex       :: !BinfoTxId
      , getBinfoUnspentXPub          :: !(Maybe BinfoXPubPath)
      } deriving (Eq, Show, Generic, NFData)

binfoUnspentToJSON :: Network -> BinfoUnspent -> Value
binfoUnspentToJSON net BinfoUnspent{..} =
    A.object $
    [ "tx_hash_big_endian" .= getBinfoUnspentHash
    , "tx_hash" .=
        encodeHex (runPutS (serialize (getTxHash getBinfoUnspentHash)))
    , "tx_output_n" .= getBinfoUnspentOutputIndex
    , "script" .= encodeHex getBinfoUnspentScript
    , "value" .= getBinfoUnspentValue
    , "value_hex" .= binfoHexValue getBinfoUnspentValue
    , "confirmations" .= getBinfoUnspentConfirmations
    , "tx_index" .= getBinfoUnspentTxIndex
    ] <>
    [ "xpub" .= binfoXPubPathToJSON net x
    | x <- maybeToList getBinfoUnspentXPub
    ]

binfoUnspentToEncoding :: Network -> BinfoUnspent -> Encoding
binfoUnspentToEncoding net BinfoUnspent{..} =
    AE.pairs $
    "tx_hash_big_endian" .= getBinfoUnspentHash <>
    "tx_hash" .=
    encodeHex (runPutS (serialize (getTxHash getBinfoUnspentHash))) <>
    "tx_output_n" .= getBinfoUnspentOutputIndex <>
    "script" .= encodeHex getBinfoUnspentScript <>
    "value" .= getBinfoUnspentValue <>
    "value_hex" .= binfoHexValue getBinfoUnspentValue <>
    "confirmations" .= getBinfoUnspentConfirmations <>
    "tx_index" .= getBinfoUnspentTxIndex <>
    maybe
    mempty
    (("xpub" `AE.pair`) . binfoXPubPathToEncoding net)
    getBinfoUnspentXPub

binfoUnspentParseJSON :: Network -> Value -> Parser BinfoUnspent
binfoUnspentParseJSON net = A.withObject "unspent" $ \o -> do
    getBinfoUnspentHash <- o .: "tx_hash_big_endian"
    getBinfoUnspentOutputIndex <- o .: "tx_output_n"
    getBinfoUnspentScript <- maybe mzero return . decodeHex =<< o .: "script"
    getBinfoUnspentValue <- o .: "value"
    getBinfoUnspentConfirmations <- o .: "confirmations"
    getBinfoUnspentTxIndex <- o .: "tx_index"
    getBinfoUnspentXPub <- mapM (binfoXPubPathParseJSON net) =<< o .:? "xpub"
    return BinfoUnspent{..}

newtype BinfoUnspents = BinfoUnspents [BinfoUnspent]
    deriving (Eq, Show, Generic, NFData)

binfoUnspentsToJSON :: Network -> BinfoUnspents -> Value
binfoUnspentsToJSON net (BinfoUnspents us) =
    A.object
    [ "notice" .= T.empty
    , "unspent_outputs" .= map (binfoUnspentToJSON net) us
    ]

binfoUnspentsToEncoding :: Network -> BinfoUnspents -> Encoding
binfoUnspentsToEncoding net (BinfoUnspents us) =
    AE.pairs $
    "notice" .= T.empty <>
    "unspent_outputs" `AE.pair` AE.list (binfoUnspentToEncoding net) us

binfoUnspentsParseJSON :: Network -> Value -> Parser BinfoUnspents
binfoUnspentsParseJSON net = A.withObject "unspents" $ \o -> do
    us <- mapM (binfoUnspentParseJSON net) =<< o .: "unspent_outputs"
    return (BinfoUnspents us)

binfoBlocksToJSON :: Network -> [BinfoBlock] -> Value
binfoBlocksToJSON net blocks =
    A.object [ "blocks" .= map (binfoBlockToJSON net) blocks ]

binfoBlocksToEncoding :: Network -> [BinfoBlock] -> Encoding
binfoBlocksToEncoding net blocks =
    AE.pairs $ "blocks" `AE.pair` AE.list (binfoBlockToEncoding net) blocks

binfoBlocksParseJSON :: Network -> Value -> Parser [BinfoBlock]
binfoBlocksParseJSON net =
    A.withObject "blocks" $ \o ->
    mapM (binfoBlockParseJSON net) =<< o .: "blocks"

toBinfoBlock :: BlockData -> [BinfoTx] -> [BlockHash] -> BinfoBlock
toBinfoBlock BlockData{..} txs next_blocks =
    BinfoBlock
        { getBinfoBlockHash = headerHash blockDataHeader
        , getBinfoBlockVer = blockVersion blockDataHeader
        , getBinfoPrevBlock = prevBlock blockDataHeader
        , getBinfoMerkleRoot = merkleRoot blockDataHeader
        , getBinfoBlockTime = blockTimestamp blockDataHeader
        , getBinfoBlockBits = blockBits blockDataHeader
        , getBinfoNextBlock = next_blocks
        , getBinfoBlockFee = blockDataFees
        , getBinfoBlockNonce = bhNonce blockDataHeader
        , getBinfoBlockTxCount = fromIntegral (length txs)
        , getBinfoBlockSize = blockDataSize
        , getBinfoBlockIndex = blockDataHeight
        , getBinfoBlockMain = blockDataMainChain
        , getBinfoBlockHeight = blockDataHeight
        , getBinfoBlockWeight = blockDataWeight
        , getBinfoBlockTx = txs
        }

data BinfoBlock
    = BinfoBlock
        { getBinfoBlockHash    :: !BlockHash
        , getBinfoBlockVer     :: !Word32
        , getBinfoPrevBlock    :: !BlockHash
        , getBinfoMerkleRoot   :: !Hash256
        , getBinfoBlockTime    :: !Word32
        , getBinfoBlockBits    :: !Word32
        , getBinfoNextBlock    :: ![BlockHash]
        , getBinfoBlockFee     :: !Word64
        , getBinfoBlockNonce   :: !Word32
        , getBinfoBlockTxCount :: !Word32
        , getBinfoBlockSize    :: !Word32
        , getBinfoBlockIndex   :: !Word32
        , getBinfoBlockMain    :: !Bool
        , getBinfoBlockHeight  :: !Word32
        , getBinfoBlockWeight  :: !Word32
        , getBinfoBlockTx      :: ![BinfoTx]
        }
    deriving (Eq, Show, Generic, NFData)

binfoBlockToJSON :: Network -> BinfoBlock -> Value
binfoBlockToJSON net BinfoBlock{..} =
    A.object $
    [ "hash" .= getBinfoBlockHash
    , "ver" .= getBinfoBlockVer
    , "prev_block" .= getBinfoPrevBlock
    , "mrkl_root" .= TxHash getBinfoMerkleRoot
    , "time" .= getBinfoBlockTime
    , "bits" .= getBinfoBlockBits
    , "next_block" .= getBinfoNextBlock
    , "fee" .= getBinfoBlockFee
    , "nonce" .= getBinfoBlockNonce
    , "n_tx" .= getBinfoBlockTxCount
    , "size" .= getBinfoBlockSize
    , "block_index" .= getBinfoBlockIndex
    , "main_chain" .= getBinfoBlockMain
    , "height" .= getBinfoBlockHeight
    , "weight" .= getBinfoBlockWeight
    , "tx" .= map (binfoTxToJSON net) getBinfoBlockTx
    ]

binfoBlockToEncoding :: Network -> BinfoBlock -> Encoding
binfoBlockToEncoding net BinfoBlock{..} =
    AE.pairs $
    "hash" .= getBinfoBlockHash <>
    "ver" .= getBinfoBlockVer <>
    "prev_block" .= getBinfoPrevBlock <>
    "mrkl_root" .= TxHash getBinfoMerkleRoot <>
    "time" .= getBinfoBlockTime <>
    "bits" .= getBinfoBlockBits <>
    "next_block" .= getBinfoNextBlock <>
    "fee" .= getBinfoBlockFee <>
    "nonce" .= getBinfoBlockNonce <>
    "n_tx" .= getBinfoBlockTxCount <>
    "size" .= getBinfoBlockSize <>
    "block_index" .= getBinfoBlockIndex <>
    "main_chain" .= getBinfoBlockMain <>
    "height" .= getBinfoBlockHeight <>
    "weight" .= getBinfoBlockWeight <>
    "tx" `AE.pair` AE.list (binfoTxToEncoding net) getBinfoBlockTx

binfoBlockParseJSON :: Network -> Value -> Parser BinfoBlock
binfoBlockParseJSON net = A.withObject "block" $ \o -> do
    getBinfoBlockHash <- o .: "hash"
    getBinfoBlockVer <- o .: "ver"
    getBinfoPrevBlock <- o .: "prev_block"
    getBinfoMerkleRoot <- getTxHash <$> o .: "mrkl_root"
    getBinfoBlockTime <- o .: "time"
    getBinfoBlockBits <- o .: "bits"
    getBinfoNextBlock <- o .: "next_block"
    getBinfoBlockFee <- o .: "fee"
    getBinfoBlockNonce <- o .: "nonce"
    getBinfoBlockTxCount <- o .: "n_tx"
    getBinfoBlockSize <- o .: "size"
    getBinfoBlockIndex <- o .: "block_index"
    getBinfoBlockMain <- o .: "main_chain"
    getBinfoBlockHeight <- o .: "height"
    getBinfoBlockWeight <- o .: "weight"
    getBinfoBlockTx <- o .: "tx" >>= mapM (binfoTxParseJSON net)
    return BinfoBlock{..}

data BinfoTx
    = BinfoTx
        { getBinfoTxHash        :: !TxHash
        , getBinfoTxVer         :: !Word32
        , getBinfoTxVinSz       :: !Word32
        , getBinfoTxVoutSz      :: !Word32
        , getBinfoTxSize        :: !Word32
        , getBinfoTxWeight      :: !Word32
        , getBinfoTxFee         :: !Word64
        , getBinfoTxRelayedBy   :: !ByteString
        , getBinfoTxLockTime    :: !Word32
        , getBinfoTxIndex       :: !BinfoTxId
        , getBinfoTxDoubleSpend :: !Bool
        , getBinfoTxRBF         :: !Bool
        , getBinfoTxResultBal   :: !(Maybe (Int64, Int64))
        , getBinfoTxTime        :: !Word64
        , getBinfoTxBlockIndex  :: !(Maybe Word32)
        , getBinfoTxBlockHeight :: !(Maybe Word32)
        , getBinfoTxInputs      :: [BinfoTxInput]
        , getBinfoTxOutputs     :: [BinfoTxOutput]
        }
    deriving (Eq, Show, Generic, NFData)

binfoTxToJSON :: Network -> BinfoTx -> Value
binfoTxToJSON net BinfoTx {..} =
    A.object $
        [ "hash" .= getBinfoTxHash
        , "ver" .= getBinfoTxVer
        , "vin_sz" .= getBinfoTxVinSz
        , "vout_sz" .= getBinfoTxVoutSz
        , "size" .= getBinfoTxSize
        , "weight" .= getBinfoTxWeight
        , "fee" .= getBinfoTxFee
        , "relayed_by" .= TE.decodeUtf8 getBinfoTxRelayedBy
        , "lock_time" .= getBinfoTxLockTime
        , "tx_index" .= getBinfoTxIndex
        , "double_spend" .= getBinfoTxDoubleSpend
        , "time" .= getBinfoTxTime
        , "block_index" .= getBinfoTxBlockIndex
        , "block_height" .= getBinfoTxBlockHeight
        , "inputs" .= map (binfoTxInputToJSON net) getBinfoTxInputs
        , "out" .= map (binfoTxOutputToJSON net) getBinfoTxOutputs
        ] ++ bal ++ rbf
  where
    bal =
        case getBinfoTxResultBal of
            Nothing         -> []
            Just (res, bal) -> ["result" .= res, "balance" .= bal]
    rbf = if getBinfoTxRBF then ["rbf" .= True] else []

binfoTxToEncoding :: Network -> BinfoTx -> Encoding
binfoTxToEncoding net BinfoTx {..} =
    AE.pairs $
        "hash" .= getBinfoTxHash <>
        "ver" .= getBinfoTxVer <>
        "vin_sz" .= getBinfoTxVinSz <>
        "vout_sz" .= getBinfoTxVoutSz <>
        "size" .= getBinfoTxSize <>
        "weight" .= getBinfoTxWeight <>
        "fee" .= getBinfoTxFee <>
        "relayed_by" .= TE.decodeUtf8 getBinfoTxRelayedBy <>
        "lock_time" .= getBinfoTxLockTime <>
        "tx_index" .= getBinfoTxIndex <>
        "double_spend" .= getBinfoTxDoubleSpend <>
        "time" .= getBinfoTxTime <>
        "block_index" .= getBinfoTxBlockIndex <>
        "block_height" .= getBinfoTxBlockHeight <>
        "inputs" `AE.pair` AE.list (binfoTxInputToEncoding net) getBinfoTxInputs <>
        "out" `AE.pair` AE.list (binfoTxOutputToEncoding net) getBinfoTxOutputs <>
        bal <> rbf
  where
    bal =
        case getBinfoTxResultBal of
            Nothing         -> mempty
            Just (res, bal) -> "result" .= res <> "balance" .= bal
    rbf = if getBinfoTxRBF then "rbf" .= True else mempty

binfoTxParseJSON :: Network -> Value -> Parser BinfoTx
binfoTxParseJSON net = A.withObject "tx" $ \o -> do
    getBinfoTxHash <- o .: "hash"
    getBinfoTxVer <- o .: "ver"
    getBinfoTxVinSz <- o .: "vin_sz"
    getBinfoTxVoutSz <- o .: "vout_sz"
    getBinfoTxSize <- o .: "size"
    getBinfoTxWeight <- o .: "weight"
    getBinfoTxFee <- o .: "fee"
    getBinfoTxRelayedBy <- TE.encodeUtf8 <$> o .: "relayed_by"
    getBinfoTxLockTime <- o .: "lock_time"
    getBinfoTxIndex <- o .: "tx_index"
    getBinfoTxDoubleSpend <- o .: "double_spend"
    getBinfoTxTime <- o .: "time"
    getBinfoTxBlockIndex <- o .: "block_index"
    getBinfoTxBlockHeight <- o .: "block_height"
    getBinfoTxInputs <- o .: "inputs" >>= mapM (binfoTxInputParseJSON net)
    getBinfoTxOutputs <- o .: "out" >>= mapM (binfoTxOutputParseJSON net)
    getBinfoTxRBF <- o .:? "rbf" .!= False
    res <- o .:? "result"
    bal <- o .:? "balance"
    let getBinfoTxResultBal = (,) <$> res <*> bal
    return BinfoTx {..}

data BinfoTxInput
    = BinfoTxInput
        { getBinfoTxInputSeq     :: !Word32
        , getBinfoTxInputWitness :: !ByteString
        , getBinfoTxInputScript  :: !ByteString
        , getBinfoTxInputIndex   :: !Word32
        , getBinfoTxInputPrevOut :: !(Maybe BinfoTxOutput)
        }
    deriving (Eq, Show, Generic, NFData)

binfoTxInputToJSON :: Network -> BinfoTxInput -> Value
binfoTxInputToJSON net BinfoTxInput {..} =
    A.object
        [ "sequence" .= getBinfoTxInputSeq
        , "witness"  .= encodeHex getBinfoTxInputWitness
        , "script"   .= encodeHex getBinfoTxInputScript
        , "index"    .= getBinfoTxInputIndex
        , "prev_out" .= (binfoTxOutputToJSON net <$> getBinfoTxInputPrevOut)
        ]

binfoTxInputToEncoding :: Network -> BinfoTxInput -> Encoding
binfoTxInputToEncoding net BinfoTxInput {..} =
    AE.pairs
        (  "sequence" .= getBinfoTxInputSeq
        <> "witness"  .= encodeHex getBinfoTxInputWitness
        <> "script"   .= encodeHex getBinfoTxInputScript
        <> "index"    .= getBinfoTxInputIndex
        <> "prev_out" .= (binfoTxOutputToJSON net <$> getBinfoTxInputPrevOut)
        )

binfoTxInputParseJSON :: Network -> Value -> Parser BinfoTxInput
binfoTxInputParseJSON net = A.withObject "txin" $ \o -> do
    getBinfoTxInputSeq <- o .: "sequence"
    getBinfoTxInputWitness <- maybe mzero return . decodeHex =<<
                              o .: "witness"
    getBinfoTxInputScript <- maybe mzero return . decodeHex =<<
                             o .: "script"
    getBinfoTxInputIndex <- o .: "index"
    getBinfoTxInputPrevOut <- o .:? "prev_out" >>=
                              mapM (binfoTxOutputParseJSON net)
    return BinfoTxInput {..}

data BinfoTxOutput
    = BinfoTxOutput
        { getBinfoTxOutputType     :: !Int
        , getBinfoTxOutputSpent    :: !Bool
        , getBinfoTxOutputValue    :: !Word64
        , getBinfoTxOutputIndex    :: !Word32
        , getBinfoTxOutputTxIndex  :: !BinfoTxId
        , getBinfoTxOutputScript   :: !ByteString
        , getBinfoTxOutputSpenders :: ![BinfoSpender]
        , getBinfoTxOutputAddress  :: !(Maybe Address)
        , getBinfoTxOutputXPub     :: !(Maybe BinfoXPubPath)
        }
    deriving (Eq, Show, Generic, NFData)

binfoTxOutputToJSON :: Network -> BinfoTxOutput -> Value
binfoTxOutputToJSON net BinfoTxOutput {..} =
    A.object $
        [ "type" .= getBinfoTxOutputType
        , "spent" .= getBinfoTxOutputSpent
        , "value" .= getBinfoTxOutputValue
        , "spending_outpoints" .= getBinfoTxOutputSpenders
        , "n" .= getBinfoTxOutputIndex
        , "tx_index" .= getBinfoTxOutputTxIndex
        , "script" .= encodeHex getBinfoTxOutputScript
        ] <>
        [ "addr" .= addrToJSON net a
        | a <- maybeToList getBinfoTxOutputAddress
        ] <>
        [ "xpub" .= binfoXPubPathToJSON net x
        | x <- maybeToList getBinfoTxOutputXPub
        ]

binfoTxOutputToEncoding :: Network -> BinfoTxOutput -> Encoding
binfoTxOutputToEncoding net BinfoTxOutput {..} =
    AE.pairs $ mconcat $
        [ "type" .= getBinfoTxOutputType
        , "spent" .= getBinfoTxOutputSpent
        , "value" .= getBinfoTxOutputValue
        , "spending_outpoints" .= getBinfoTxOutputSpenders
        , "n" .= getBinfoTxOutputIndex
        , "tx_index" .= getBinfoTxOutputTxIndex
        , "script" .= encodeHex getBinfoTxOutputScript
        ] <>
        [ "addr" .= addrToJSON net a
        | a <- maybeToList getBinfoTxOutputAddress
        ] <>
        [ "xpub" .= binfoXPubPathToJSON net x
        | x <- maybeToList getBinfoTxOutputXPub
        ]

binfoTxOutputParseJSON :: Network -> Value -> Parser BinfoTxOutput
binfoTxOutputParseJSON net = A.withObject "txout" $ \o -> do
    getBinfoTxOutputType <- o .: "type"
    getBinfoTxOutputSpent <- o .: "spent"
    getBinfoTxOutputValue <- o .: "value"
    getBinfoTxOutputSpenders <- o .: "spending_outpoints"
    getBinfoTxOutputIndex <- o .: "n"
    getBinfoTxOutputTxIndex <- o .: "tx_index"
    getBinfoTxOutputScript <- maybe mzero return . decodeHex =<< o .: "script"
    getBinfoTxOutputAddress <- o .:? "addr" >>= mapM (addrFromJSON net)
    getBinfoTxOutputXPub <- o .:? "xpub" >>= mapM (binfoXPubPathParseJSON net)
    return BinfoTxOutput {..}

data BinfoSpender
    = BinfoSpender
        { getBinfoSpenderTxIndex :: !BinfoTxId
        , getBinfoSpenderIndex   :: !Word32
        }
    deriving (Eq, Show, Generic, NFData)

instance ToJSON BinfoSpender where
    toJSON BinfoSpender {..} =
        A.object
            [ "tx_index" .= getBinfoSpenderTxIndex
            , "n" .= getBinfoSpenderIndex
            ]
    toEncoding BinfoSpender {..} =
        AE.pairs
            (  "tx_index" .= getBinfoSpenderTxIndex
            <> "n"        .= getBinfoSpenderIndex
            )

instance FromJSON BinfoSpender where
    parseJSON = A.withObject "spender" $ \o -> do
        getBinfoSpenderTxIndex <- o .: "tx_index"
        getBinfoSpenderIndex <- o .: "n"
        return BinfoSpender {..}

data BinfoXPubPath
    = BinfoXPubPath
        { getBinfoXPubPathKey   :: !XPubKey
        , getBinfoXPubPathDeriv :: !SoftPath
        }
    deriving (Eq, Show, Generic, NFData)

instance Ord BinfoXPubPath where
    compare = compare `on` f
       where
         f b = ( xPubParent (getBinfoXPubPathKey b)
               , getBinfoXPubPathDeriv b
               )

binfoXPubPathToJSON :: Network -> BinfoXPubPath -> Value
binfoXPubPathToJSON net BinfoXPubPath {..} =
    A.object
        [ "m" .= xPubToJSON net getBinfoXPubPathKey
        , "path" .= ("M" ++ pathToStr getBinfoXPubPathDeriv)
        ]

binfoXPubPathToEncoding :: Network -> BinfoXPubPath -> Encoding
binfoXPubPathToEncoding net BinfoXPubPath {..} =
    AE.pairs $
        "m" `AE.pair` xPubToEncoding net getBinfoXPubPathKey <>
        "path" .= ("M" ++ pathToStr getBinfoXPubPathDeriv)

binfoXPubPathParseJSON :: Network -> Value -> Parser BinfoXPubPath
binfoXPubPathParseJSON net = A.withObject "xpub" $ \o -> do
    getBinfoXPubPathKey <- o .: "m" >>= xPubFromJSON net
    getBinfoXPubPathDeriv <-
        fromMaybe "bad xpub path" . parseSoft <$> o .: "path"
    return BinfoXPubPath {..}

data BinfoInfo
    = BinfoInfo
        { getBinfoConnected   :: !Word32
        , getBinfoConversion  :: !Double
        , getBinfoLocal       :: !BinfoSymbol
        , getBinfoBTC         :: !BinfoSymbol
        , getBinfoLatestBlock :: !BinfoBlockInfo
        }
    deriving (Eq, Show, Generic, NFData)

instance ToJSON BinfoInfo where
    toJSON BinfoInfo {..} =
        A.object
            [ "nconnected" .= getBinfoConnected
            , "conversion" .= getBinfoConversion
            , "symbol_local" .= getBinfoLocal
            , "symbol_btc" .= getBinfoBTC
            , "latest_block" .= getBinfoLatestBlock
            ]
    toEncoding BinfoInfo {..} =
        AE.pairs
            (  "nconnected" .= getBinfoConnected
            <> "conversion" .= getBinfoConversion
            <> "symbol_local" .= getBinfoLocal
            <> "symbol_btc" .= getBinfoBTC
            <> "latest_block" .= getBinfoLatestBlock
            )

instance FromJSON BinfoInfo where
    parseJSON = A.withObject "info" $ \o -> do
        getBinfoConnected <- o .: "nconnected"
        getBinfoConversion <- o .: "conversion"
        getBinfoLocal <- o .: "symbol_local"
        getBinfoBTC <- o .: "symbol_btc"
        getBinfoLatestBlock <- o .: "latest_block"
        return BinfoInfo {..}

data BinfoBlockInfo
    = BinfoBlockInfo
        { getBinfoBlockInfoHash   :: !BlockHash
        , getBinfoBlockInfoHeight :: !BlockHeight
        , getBinfoBlockInfoTime   :: !Word32
        , getBinfoBlockInfoIndex  :: !BlockHeight
        }
    deriving (Eq, Show, Generic, NFData)

instance ToJSON BinfoBlockInfo where
    toJSON BinfoBlockInfo {..} =
        A.object
            [ "hash" .= getBinfoBlockInfoHash
            , "height" .= getBinfoBlockInfoHeight
            , "time" .= getBinfoBlockInfoTime
            , "block_index" .= getBinfoBlockInfoIndex
            ]
    toEncoding BinfoBlockInfo {..} =
        AE.pairs
            (  "hash" .= getBinfoBlockInfoHash
            <> "height" .= getBinfoBlockInfoHeight
            <> "time" .= getBinfoBlockInfoTime
            <> "block_index" .= getBinfoBlockInfoIndex
            )

instance FromJSON BinfoBlockInfo where
    parseJSON = A.withObject "block_info" $ \o -> do
        getBinfoBlockInfoHash <- o .: "hash"
        getBinfoBlockInfoHeight <- o .: "height"
        getBinfoBlockInfoTime <- o .: "time"
        getBinfoBlockInfoIndex <- o .: "block_index"
        return BinfoBlockInfo {..}

data BinfoTicker
    = BinfoTicker
        { binfoTicker15m    :: !Double
        , binfoTickerLast   :: !Double
        , binfoTickerBuy    :: !Double
        , binfoTickerSell   :: !Double
        , binfoTickerSymbol :: !Text
        }
    deriving (Eq, Show, Generic, NFData)

instance Default BinfoTicker where
    def = BinfoTicker{ binfoTickerSymbol = "XXX"
                     , binfoTicker15m = 0.0
                     , binfoTickerLast = 0.0
                     , binfoTickerBuy = 0.0
                     , binfoTickerSell = 0.0
                     }

instance ToJSON BinfoTicker where
    toJSON BinfoTicker{..} =
        A.object
            [ "symbol" .= binfoTickerSymbol
            , "sell" .= binfoTickerSell
            , "buy" .= binfoTickerBuy
            , "last" .= binfoTickerLast
            , "15m" .= binfoTicker15m
            ]
    toEncoding BinfoTicker{..} =
        AE.pairs $
        "symbol" .= binfoTickerSymbol <>
        "sell" .= binfoTickerSell <>
        "buy" .= binfoTickerBuy <>
        "last" .= binfoTickerLast <>
        "15m" .= binfoTicker15m

instance FromJSON BinfoTicker where
    parseJSON = A.withObject "ticker" $ \o -> do
        binfoTickerSymbol <- o .: "symbol"
        binfoTicker15m <- o .: "15m"
        binfoTickerSell <- o .: "sell"
        binfoTickerBuy <- o .: "buy"
        binfoTickerLast <- o .: "last"
        return BinfoTicker{..}

data BinfoSymbol
    = BinfoSymbol
        { getBinfoSymbolCode       :: !Text
        , getBinfoSymbolString     :: !Text
        , getBinfoSymbolName       :: !Text
        , getBinfoSymbolConversion :: !Double
        , getBinfoSymbolAfter      :: !Bool
        , getBinfoSymbolLocal      :: !Bool
        }
    deriving (Eq, Show, Generic, NFData)

instance Default BinfoSymbol where
    def = BinfoSymbol{ getBinfoSymbolCode = "XXX"
                     , getBinfoSymbolString = "¤"
                     , getBinfoSymbolName = "No currency"
                     , getBinfoSymbolConversion = 0.0
                     , getBinfoSymbolAfter = False
                     , getBinfoSymbolLocal = True
                     }

instance ToJSON BinfoSymbol where
    toJSON BinfoSymbol {..} =
        A.object
            [ "code" .= getBinfoSymbolCode
            , "symbol" .= getBinfoSymbolString
            , "name" .= getBinfoSymbolName
            , "conversion" .= getBinfoSymbolConversion
            , "symbolAppearsAfter" .= getBinfoSymbolAfter
            , "local" .= getBinfoSymbolLocal
            ]
    toEncoding BinfoSymbol {..} =
        AE.pairs
            (  "code" .= getBinfoSymbolCode
            <> "symbol" .= getBinfoSymbolString
            <> "name" .= getBinfoSymbolName
            <> "conversion" .= getBinfoSymbolConversion
            <> "symbolAppearsAfter" .= getBinfoSymbolAfter
            <> "local" .= getBinfoSymbolLocal
            )

instance FromJSON BinfoSymbol where
    parseJSON = A.withObject "symbol" $ \o -> do
        getBinfoSymbolCode <- o .: "code"
        getBinfoSymbolString <- o .: "symbol"
        getBinfoSymbolName <- o .: "name"
        getBinfoSymbolConversion <- o .: "conversion"
        getBinfoSymbolAfter <- o .: "symbolAppearsAfter"
        getBinfoSymbolLocal <- o .: "local"
        return BinfoSymbol {..}

relevantTxs :: HashSet Address
            -> Bool
            -> Transaction
            -> HashSet TxHash
relevantTxs addrs prune t@Transaction{..} =
    let p a = prune && getTxResult addrs t > 0 && not (HashSet.member a addrs)
        f StoreOutput{..} =
            case outputSpender of
                Nothing -> Nothing
                Just Spender{..} ->
                    case outputAddr of
                        Nothing -> Nothing
                        Just a | p a -> Nothing
                               | otherwise -> Just spenderHash
        outs = mapMaybe f transactionOutputs
        g StoreCoinbase{}                       = Nothing
        g StoreInput{inputPoint = OutPoint{..}} = Just outPointHash
        ins = mapMaybe g transactionInputs
      in HashSet.fromList $ ins <> outs

toBinfoAddrs :: HashMap Address Balance
             -> HashMap XPubKey [XPubBal]
             -> HashMap XPubKey Int
             -> [BinfoBalance]
toBinfoAddrs only_addrs only_xpubs xpub_txs =
    xpub_bals <> addr_bals
  where
    xpub_bal k xs =
        let f x = case xPubBalPath x of
                [0, _] -> balanceTotalReceived (xPubBal x)
                _      -> 0
            g x = balanceAmount (xPubBal x) + balanceZero (xPubBal x)
            i m x = case xPubBalPath x of
                [m', n] | m == m' -> n + 1
                _                 -> 0
            received = sum (map f xs)
            bal = fromIntegral (sum (map g xs))
            sent = if bal <= received then received - bal else 0
            count = case HashMap.lookup k xpub_txs of
                Nothing -> 0
                Just i  -> fromIntegral i
            ax = foldl max 0 (map (i 0) xs)
            cx = foldl max 0 (map (i 1) xs)
        in BinfoXPubBalance{ getBinfoXPubKey = k
                           , getBinfoAddrTxCount = count
                           , getBinfoAddrReceived = received
                           , getBinfoAddrSent = sent
                           , getBinfoAddrBalance = bal
                           , getBinfoXPubAccountIndex = ax
                           , getBinfoXPubChangeIndex = cx
                           }
    xpub_bals = map (uncurry xpub_bal) (HashMap.toList only_xpubs)
    addr_bals =
        let f Balance{..} =
                let addr = balanceAddress
                    sent = recv - bal
                    recv = balanceTotalReceived
                    tx_count = balanceTxCount
                    bal = balanceAmount + balanceZero
                in BinfoAddrBalance{ getBinfoAddress = addr
                                   , getBinfoAddrTxCount = tx_count
                                   , getBinfoAddrReceived = recv
                                   , getBinfoAddrSent = sent
                                   , getBinfoAddrBalance = bal
                                   }
         in map f $ HashMap.elems only_addrs

toBinfoTxSimple :: Bool
                -> Transaction
                -> BinfoTx
toBinfoTxSimple numtxid =
    toBinfoTx numtxid HashMap.empty False 0

toBinfoTxInputs :: Bool
                -> HashMap Address (Maybe BinfoXPubPath)
                -> Transaction
                -> [BinfoTxInput]
toBinfoTxInputs numtxid abook t =
    zipWith f [0..] (transactionInputs t)
  where
    f n i = BinfoTxInput{ getBinfoTxInputIndex = n
                        , getBinfoTxInputSeq = inputSequence i
                        , getBinfoTxInputScript = inputSigScript i
                        , getBinfoTxInputWitness = wit i
                        , getBinfoTxInputPrevOut = prev n i
                        }
    wit i =
        case inputWitness i of
            [] -> BS.empty
            ws -> runPutS (put_witness ws)
    prev = inputToBinfoTxOutput numtxid abook t
    put_witness ws = do
        putVarInt (length ws)
        mapM_ put_item ws
    put_item bs = do
        putVarInt (BS.length bs)
        putByteString bs

toBinfoBlockIndex :: Transaction -> Maybe BlockHeight
toBinfoBlockIndex Transaction{transactionDeleted = True}       = Nothing
toBinfoBlockIndex Transaction{transactionBlock = MemRef _}     = Nothing
toBinfoBlockIndex Transaction{transactionBlock = BlockRef h _} = Just h

toBinfoTx :: Bool
          -> HashMap Address (Maybe BinfoXPubPath)
          -> Bool
          -> Int64
          -> Transaction
          -> BinfoTx
toBinfoTx numtxid abook prune bal t@Transaction{..} =
    BinfoTx{ getBinfoTxHash = txHash (transactionData t)
           , getBinfoTxVer = transactionVersion
           , getBinfoTxVinSz = fromIntegral (length transactionInputs)
           , getBinfoTxVoutSz = fromIntegral (length transactionOutputs)
           , getBinfoTxSize = transactionSize
           , getBinfoTxWeight = transactionWeight
           , getBinfoTxFee = transactionFees
           , getBinfoTxRelayedBy = "0.0.0.0"
           , getBinfoTxLockTime = transactionLockTime
           , getBinfoTxIndex =
                   encodeBinfoTxId numtxid (txHash (transactionData t))
           , getBinfoTxDoubleSpend = transactionDeleted
           , getBinfoTxRBF = transactionRBF
           , getBinfoTxTime = transactionTime
           , getBinfoTxBlockIndex = toBinfoBlockIndex t
           , getBinfoTxBlockHeight = toBinfoBlockIndex t
           , getBinfoTxInputs = toBinfoTxInputs numtxid abook t
           , getBinfoTxOutputs = outs
           , getBinfoTxResultBal = resbal
           }
  where
    simple = HashMap.null abook && bal == 0
    resbal = if simple then Nothing else Just (getTxResult aset t, bal)
    aset = HashMap.keysSet abook
    outs =
        let p = prune && getTxResult aset t > 0
            f = toBinfoTxOutput numtxid abook p t
        in catMaybes $ zipWith f [0..] transactionOutputs

getTxResult :: HashSet Address -> Transaction -> Int64
getTxResult aset Transaction{..} =
    let input_sum = sum $ map input_value transactionInputs
        input_value StoreCoinbase{} = 0
        input_value StoreInput{..} =
            case inputAddress of
                Nothing -> 0
                Just a ->
                    if test_addr a
                    then negate $ fromIntegral inputAmount
                    else 0
        test_addr a = HashSet.member a aset
        output_sum = sum $ map out_value transactionOutputs
        out_value StoreOutput{..} =
            case outputAddr of
                Nothing -> 0
                Just a ->
                    if test_addr a
                    then fromIntegral outputAmount
                    else 0
     in input_sum + output_sum

toBinfoTxOutput :: Bool
                -> HashMap Address (Maybe BinfoXPubPath)
                -> Bool
                -> Transaction
                -> Word32
                -> StoreOutput
                -> Maybe BinfoTxOutput
toBinfoTxOutput numtxid abook prune t n StoreOutput{..} =
    let getBinfoTxOutputType = 0
        getBinfoTxOutputSpent = isJust outputSpender
        getBinfoTxOutputValue = outputAmount
        getBinfoTxOutputIndex = n
        getBinfoTxOutputTxIndex =
            encodeBinfoTxId numtxid (txHash (transactionData t))
        getBinfoTxOutputScript = outputScript
        getBinfoTxOutputSpenders =
            maybeToList $ toBinfoSpender numtxid <$> outputSpender
        getBinfoTxOutputAddress = outputAddr
        getBinfoTxOutputXPub =
            outputAddr >>= join . (`HashMap.lookup` abook)
     in if prune && isNothing (outputAddr >>= (`HashMap.lookup` abook))
        then Nothing
        else Just BinfoTxOutput{..}

toBinfoSpender :: Bool -> Spender -> BinfoSpender
toBinfoSpender numtxid Spender{..} =
    let getBinfoSpenderTxIndex = encodeBinfoTxId numtxid spenderHash
        getBinfoSpenderIndex = spenderIndex
     in BinfoSpender{..}

inputToBinfoTxOutput :: Bool
                     -> HashMap Address (Maybe BinfoXPubPath)
                     -> Transaction
                     -> Word32
                     -> StoreInput
                     -> Maybe BinfoTxOutput
inputToBinfoTxOutput _ _ _ _ StoreCoinbase{} = Nothing
inputToBinfoTxOutput numtxid abook t n StoreInput{..} =
    Just
    BinfoTxOutput
    { getBinfoTxOutputIndex = out_index
    , getBinfoTxOutputType = 0
    , getBinfoTxOutputSpent = True
    , getBinfoTxOutputValue = inputAmount
    , getBinfoTxOutputTxIndex = encodeBinfoTxId numtxid out_hash
    , getBinfoTxOutputScript = inputPkScript
    , getBinfoTxOutputSpenders = [spender]
    , getBinfoTxOutputAddress = inputAddress
    , getBinfoTxOutputXPub = xpub
    }
  where
    OutPoint out_hash out_index = inputPoint
    spender =
        BinfoSpender
        (encodeBinfoTxId numtxid (txHash (transactionData t)))
        n
    xpub = inputAddress >>= join . (`HashMap.lookup` abook)

data BinfoAddr
    = BinfoAddr !Address
    | BinfoXpub !XPubKey
    deriving (Eq, Show, Generic, Hashable, NFData)

parseBinfoAddr :: Network -> Text -> Maybe [BinfoAddr]
parseBinfoAddr _ "" = Just []
parseBinfoAddr net s =
    mapM f $ filter (not . T.null) $
    concatMap (T.splitOn ",") (T.splitOn "|" s)
  where
    f x = BinfoAddr <$> textToAddr net x <|> BinfoXpub <$> xPubImport net x
