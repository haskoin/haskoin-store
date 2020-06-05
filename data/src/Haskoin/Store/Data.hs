{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Strict            #-}
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
    , RawResult(..)
    , RawResultList(..)
    , PeerInformation(..)
    , HealthCheck(..)
    , Event(..)
    , Except(..)
    )

where

import           Control.Applicative     ((<|>))
import           Control.DeepSeq         (NFData)
import           Control.Exception       (Exception)
import           Control.Monad           (guard, join, mzero, (<=<))
import           Data.Aeson              (Encoding, FromJSON (..), ToJSON (..),
                                          Value (..), object, pairs, (.!=),
                                          (.:), (.:?), (.=))
import qualified Data.Aeson              as A
import           Data.Aeson.Encoding     (list, null_, pair, text,
                                          unsafeToEncoding)
import           Data.Aeson.Types        (Parser)
import           Data.ByteString         (ByteString)
import qualified Data.ByteString         as B
import           Data.ByteString.Builder (char7, lazyByteStringHex)
import           Data.ByteString.Short   (ShortByteString)
import qualified Data.ByteString.Short   as BSS
import           Data.Default            (Default (..))
import           Data.Foldable           (toList)
import           Data.Hashable           (Hashable (..))
import qualified Data.IntMap             as I
import           Data.IntMap.Strict      (IntMap)
import           Data.Maybe              (catMaybes, isJust, mapMaybe)
import           Data.Serialize          (Get, Put, Serialize (..), getWord32be,
                                          getWord64be, getWord8, putWord32be,
                                          putWord64be, putWord8)
import qualified Data.Serialize          as S
import           Data.String.Conversions (cs)
import           Data.Text               (Text)
import qualified Data.Text.Lazy          as TL
import           Data.Word               (Word32, Word64)
import           GHC.Generics            (Generic)
import           Haskoin                 (Address, BlockHash, BlockHeader (..),
                                          BlockHeight, BlockWork, Coin (..),
                                          KeyIndex, Network (..), OutPoint (..),
                                          PubKeyI (..), Tx (..), TxHash (..),
                                          TxIn (..), TxOut (..), WitnessStack,
                                          XPubKey (..), addrFromJSON,
                                          addrToEncoding, addrToJSON,
                                          blockHashToHex, decodeHex,
                                          eitherToMaybe, encodeHex, headerHash,
                                          scriptToAddressBS, txHash,
                                          txHashToHex, wrapPubKey)
import           Web.Scotty.Trans        (ScottyError (..))

data DeriveType = DeriveNormal
    | DeriveP2SH
    | DeriveP2WPKH
    deriving (Show, Eq, Generic, NFData, Serialize)

instance Default DeriveType where
    def = DeriveNormal

data XPubSpec = XPubSpec
    { xPubSpecKey    :: XPubKey
    , xPubDeriveType :: DeriveType
    } deriving (Show, Eq, Generic, NFData)

instance Hashable XPubSpec where
    hashWithSalt i XPubSpec {xPubSpecKey = XPubKey {xPubKey = pubkey}} =
        hashWithSalt i pubkey

instance Serialize XPubSpec where
    put XPubSpec {xPubSpecKey = k, xPubDeriveType = t} = do
        put (xPubDepth k)
        put (xPubParent k)
        put (xPubIndex k)
        put (xPubChain k)
        put (wrapPubKey True (xPubKey k))
        put t
    get = do
        d <- get
        p <- get
        i <- get
        c <- get
        k <- get
        t <- get
        let x =
                XPubKey
                    { xPubDepth = d
                    , xPubParent = p
                    , xPubIndex = i
                    , xPubChain = c
                    , xPubKey = pubKeyPoint k
                    }
        return XPubSpec {xPubSpecKey = x, xPubDeriveType = t}

type UnixTime = Word64
type BlockPos = Word32

-- | Serialize such that ordering is inverted.
putUnixTime :: Word64 -> Put
putUnixTime w = putWord64be $ maxBound - w

getUnixTime :: Get Word64
getUnixTime = (maxBound -) <$> getWord64be

-- | Reference to a block where a transaction is stored.
data BlockRef = BlockRef
    { blockRefHeight :: BlockHeight
    -- ^ block height in the chain
    , blockRefPos    :: Word32
    -- ^ position of transaction within the block
    }
    | MemRef
    { memRefTime :: UnixTime
    }
    deriving (Show, Read, Eq, Ord, Generic, Hashable, NFData)

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

confirmed :: BlockRef -> Bool
confirmed BlockRef {} = True
confirmed MemRef {}   = False

instance ToJSON BlockRef where
    toJSON BlockRef {blockRefHeight = h, blockRefPos = p} =
        object ["height" .= h, "position" .= p]
    toJSON MemRef {memRefTime = t} = object ["mempool" .= t]
    toEncoding BlockRef {blockRefHeight = h, blockRefPos = p} =
        pairs ("height" .= h <> "position" .= p)
    toEncoding MemRef {memRefTime = t} = pairs ("mempool" .= t)

instance FromJSON BlockRef where
    parseJSON = A.withObject "blockref" $ \o -> b o <|> m o
      where
        b o = do
            height <- o .: "height"
            position <- o .: "position"
            return BlockRef {blockRefHeight = height, blockRefPos = position}
        m o = do
            mempool <- o .: "mempool"
            return MemRef {memRefTime = mempool}

-- | Transaction in relation to an address.
data TxRef = TxRef
    { txRefBlock :: BlockRef
    -- ^ block information
    , txRefHash  :: TxHash
    -- ^ transaction hash
    }
    deriving (Show, Eq, Ord, Generic, Serialize, Hashable, NFData)

instance ToJSON TxRef where
    toJSON btx = object ["txid" .= txRefHash btx, "block" .= txRefBlock btx]
    toEncoding btx =
        pairs
            (  "txid" .= txRefHash btx
            <> "block" .= txRefBlock btx
            )

instance FromJSON TxRef where
    parseJSON =
        A.withObject "blocktx" $ \o -> do
            txid <- o .: "txid"
            block <- o .: "block"
            return TxRef {txRefBlock = block, txRefHash = txid}

-- | Address balance information.
data Balance = Balance
    { balanceAddress       :: Address
    -- ^ address balance
    , balanceAmount        :: Word64
    -- ^ confirmed balance
    , balanceZero          :: Word64
    -- ^ unconfirmed balance
    , balanceUnspentCount  :: Word64
    -- ^ number of unspent outputs
    , balanceTxCount       :: Word64
    -- ^ number of transactions
    , balanceTotalReceived :: Word64
    -- ^ total amount from all outputs in this address
    }
    deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable,
          NFData)

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
nullBalance Balance { balanceAmount = 0
                    , balanceUnspentCount = 0
                    , balanceZero = 0
                    , balanceTxCount = 0
                    , balanceTotalReceived = 0
                    } = True
nullBalance _ = False

balanceToJSON :: Network -> Balance -> Value
balanceToJSON net b =
        object
        [ "address" .= addrToJSON net (balanceAddress b)
        , "confirmed" .= balanceAmount b
        , "unconfirmed" .= balanceZero b
        , "utxo" .= balanceUnspentCount b
        , "txs" .= balanceTxCount b
        , "received" .= balanceTotalReceived b
        ]

balanceToEncoding :: Network -> Balance -> Encoding
balanceToEncoding net b =
    pairs
        (  "address" `pair` addrToEncoding net (balanceAddress b)
        <> "confirmed" .= balanceAmount b
        <> "unconfirmed" .= balanceZero b
        <> "utxo" .= balanceUnspentCount b
        <> "txs" .= balanceTxCount b
        <> "received" .= balanceTotalReceived b
        )

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
data Unspent = Unspent
    { unspentBlock   :: BlockRef
    , unspentPoint   :: OutPoint
    , unspentAmount  :: Word64
    , unspentScript  :: ShortByteString
    , unspentAddress :: Maybe Address
    }
    deriving (Show, Eq, Ord, Generic, Hashable, Serialize, NFData)

instance Coin Unspent where
    coinValue = unspentAmount

unspentToJSON :: Network -> Unspent -> Value
unspentToJSON net u =
    object
        [ "address" .= (addrToJSON net <$> unspentAddress u)
        , "block" .= unspentBlock u
        , "txid" .= outPointHash (unspentPoint u)
        , "index" .= outPointIndex (unspentPoint u)
        , "pkscript" .= script
        , "value" .= unspentAmount u
        ]
  where
    bsscript = BSS.fromShort (unspentScript u)
    script = encodeHex bsscript

unspentToEncoding :: Network -> Unspent -> Encoding
unspentToEncoding net u =
    pairs
        (  "address" `pair` maybe null_ (addrToEncoding net) (unspentAddress u)
        <> "block" .= unspentBlock u
        <> "txid" .= outPointHash (unspentPoint u)
        <> "index" .= outPointIndex (unspentPoint u)
        <> "pkscript" `pair` text script
        <> "value" .= unspentAmount u
        )
  where
    bsscript = BSS.fromShort (unspentScript u)
    script = encodeHex bsscript

unspentParseJSON :: Network -> Value -> Parser Unspent
unspentParseJSON net =
    A.withObject "unspent" $ \o -> do
        block <- o .: "block"
        txid <- o .: "txid"
        index <- o .: "index"
        value <- o .: "value"
        script <- BSS.toShort <$> (o .: "pkscript" >>= jsonHex)
        addr <- o .: "address" >>= \case
            Nothing -> return Nothing
            Just a -> Just <$> addrFromJSON net a <|> return Nothing
        return
            Unspent
                { unspentBlock = block
                , unspentPoint = OutPoint txid index
                , unspentAmount = value
                , unspentScript = script
                , unspentAddress = addr
                }

-- | Database value for a block entry.
data BlockData = BlockData
    { blockDataHeight    :: BlockHeight
    -- ^ height of the block in the chain
    , blockDataMainChain :: Bool
    -- ^ is this block in the main chain?
    , blockDataWork      :: BlockWork
    -- ^ accumulated work in that block
    , blockDataHeader    :: BlockHeader
    -- ^ block header
    , blockDataSize      :: Word32
    -- ^ size of the block including witnesses
    , blockDataWeight    :: Word32
    -- ^ weight of this block (for segwit networks)
    , blockDataTxs       :: [TxHash]
    -- ^ block transactions
    , blockDataOutputs   :: Word64
    -- ^ sum of all transaction outputs
    , blockDataFees      :: Word64
    -- ^ sum of all transaction fees
    , blockDataSubsidy   :: Word64
    -- ^ block subsidy
    }
    deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable, NFData)

blockDataToJSON :: Network -> BlockData -> Value
blockDataToJSON net bv =
    object $
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
    pairs
        (  "hash" `pair` text (blockHashToHex (headerHash (blockDataHeader bv)))
        <> "height" .= blockDataHeight bv
        <> "mainchain" .= blockDataMainChain bv
        <> "previous" .= prevBlock (blockDataHeader bv)
        <> "time" .= blockTimestamp (blockDataHeader bv)
        <> "version" .= blockVersion (blockDataHeader bv)
        <> "bits" .= blockBits (blockDataHeader bv)
        <> "nonce" .= bhNonce (blockDataHeader bv)
        <> "size" .= blockDataSize bv
        <> "tx" .= blockDataTxs bv
        <> "merkle" `pair` text (txHashToHex (TxHash (merkleRoot (blockDataHeader bv))))
        <> "subsidy" .= blockDataSubsidy bv
        <> "fees" .= blockDataFees bv
        <> "outputs" .= blockDataOutputs bv
        <> "work" .= blockDataWork bv
        <> (if getSegWit net then "weight" .= blockDataWeight bv else mempty)
        )

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
          { inputPoint     :: OutPoint
          , inputSequence  :: Word32
          , inputSigScript :: ByteString
          , inputWitness   :: Maybe WitnessStack
          }
    | StoreInput
          { inputPoint     :: OutPoint
          , inputSequence  :: Word32
          , inputSigScript :: ByteString
          , inputPkScript  :: ByteString
          , inputAmount    :: Word64
          , inputWitness   :: Maybe WitnessStack
          , inputAddress   :: Maybe Address
          }
    deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable, NFData)

isCoinbase :: StoreInput -> Bool
isCoinbase StoreCoinbase {} = True
isCoinbase StoreInput {}    = False

storeInputToJSON :: Network -> StoreInput -> Value
storeInputToJSON net StoreInput { inputPoint = OutPoint oph opi
                                , inputSequence = sq
                                , inputSigScript = ss
                                , inputPkScript = ps
                                , inputAmount = val
                                , inputWitness = wit
                                , inputAddress = a
                                } =
    object $
    [ "coinbase" .= False
    , "txid" .= oph
    , "output" .= opi
    , "sigscript" .= String (encodeHex ss)
    , "sequence" .= sq
    , "pkscript" .= String (encodeHex ps)
    , "value" .= val
    , "address" .= (addrToJSON net <$> a)
    ] <>
    ["witness" .= fmap (map encodeHex) wit | getSegWit net]
storeInputToJSON net StoreCoinbase { inputPoint = OutPoint oph opi
                                   , inputSequence = sq
                                   , inputSigScript = ss
                                   , inputWitness = wit
                                   } =
    object $
    [ "coinbase" .= True
    , "txid" .= oph
    , "output" .= opi
    , "sigscript" .= String (encodeHex ss)
    , "sequence" .= sq
    , "pkscript" .= Null
    , "value" .= Null
    , "address" .= Null
    ] <>
    ["witness" .= fmap (map encodeHex) wit | getSegWit net]

storeInputToEncoding :: Network -> StoreInput -> Encoding
storeInputToEncoding net StoreInput { inputPoint = OutPoint oph opi
                                    , inputSequence = sq
                                    , inputSigScript = ss
                                    , inputPkScript = ps
                                    , inputAmount = val
                                    , inputWitness = wit
                                    , inputAddress = a
                                    } =
    pairs
        (  "coinbase" .= False
        <> "txid" .= oph
        <> "output" .= opi
        <> "sigscript" `pair` text (encodeHex ss)
        <> "sequence" .= sq
        <> "pkscript" `pair` text (encodeHex ps)
        <> "value" .= val
        <> "address" `pair` maybe null_ (addrToEncoding net) a
        <> (if getSegWit net
           then "witness" .= fmap (map encodeHex) wit
           else mempty)
        )

storeInputToEncoding net StoreCoinbase { inputPoint = OutPoint oph opi
                                     , inputSequence = sq
                                     , inputSigScript = ss
                                     , inputWitness = wit
                                     } =
    pairs
        (  "coinbase" .= True
        <> "txid" `pair` text (txHashToHex oph)
        <> "output" .= opi
        <> "sigscript" `pair` text (encodeHex ss)
        <> "sequence" .= sq
        <> "pkscript" `pair` null_
        <> "value" `pair` null_
        <> "address" `pair` null_
        <> (if getSegWit net
           then "witness" .= fmap (map encodeHex) wit
           else mempty)
        )

storeInputParseJSON :: Network -> Value -> Parser StoreInput
storeInputParseJSON net =
    A.withObject "storeinput" $ \o -> do
        coinbase <- o .: "coinbase"
        outpoint <- OutPoint <$> o .: "txid" <*> o .: "output"
        sequ <- o .: "sequence"
        witness <-
            o .:? "witness" >>= \mmxs ->
                case join mmxs of
                    Nothing -> return Nothing
                    Just xs -> Just <$> mapM jsonHex xs
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
                    Just a -> Just <$> addrFromJSON net a <|> return Nothing
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
data Spender = Spender
    { spenderHash  :: TxHash
      -- ^ input transaction hash
    , spenderIndex :: Word32
      -- ^ input position in transaction
    } deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable, NFData)

instance ToJSON Spender where
    toJSON n = object ["txid" .= txHashToHex (spenderHash n), "input" .= spenderIndex n]
    toEncoding n = pairs ("txid" .= txHashToHex (spenderHash n) <> "input" .= spenderIndex n)

instance FromJSON Spender where
    parseJSON =
        A.withObject "spender" $ \o -> Spender <$> o .: "txid" <*> o .: "input"

-- | Output information.
data StoreOutput = StoreOutput
    { outputAmount  :: Word64
    , outputScript  :: ByteString
    , outputSpender :: Maybe Spender
    , outputAddress :: Maybe Address
    } deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable, NFData)

storeOutputToJSON :: Network -> StoreOutput -> Value
storeOutputToJSON net d =
    object
        [ "address" .= (addrToJSON net <$> outputAddress d)
        , "pkscript" .= encodeHex (outputScript d)
        , "value" .= outputAmount d
        , "spent" .= isJust (outputSpender d)
        , "spender" .= outputSpender d
        ]

storeOutputToEncoding :: Network -> StoreOutput -> Encoding
storeOutputToEncoding net d =
    pairs
        (  "address" `pair` maybe null_ (addrToEncoding net) (outputAddress d)
        <> "pkscript" `pair` text (encodeHex (outputScript d))
        <> "value" .= outputAmount d
        <> "spent" .= isJust (outputSpender d)
        <> "spender" .= outputSpender d
        )

storeOutputParseJSON :: Network -> Value -> Parser StoreOutput
storeOutputParseJSON net =
    A.withObject "storeoutput" $ \o -> do
        value <- o .: "value"
        pkscript <- o .: "pkscript" >>= jsonHex
        spender <- o .: "spender"
        addr <- o .: "address" >>= \case
            Nothing -> return Nothing
            Just a -> Just <$> addrFromJSON net a <|> return Nothing
        return
            StoreOutput
                { outputAmount = value
                , outputScript = pkscript
                , outputSpender = spender
                , outputAddress = addr
                }

data Prev = Prev
    { prevScript :: ByteString
    , prevAmount :: Word64
    } deriving (Show, Eq, Ord, Generic, Hashable, Serialize, NFData)

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
        , inputAddress = eitherToMaybe (scriptToAddressBS (prevScript p))
        }

toOutput :: TxOut -> Maybe Spender -> StoreOutput
toOutput o s =
    StoreOutput
        { outputAmount = outValue o
        , outputScript = scriptOutput o
        , outputSpender = s
        , outputAddress = eitherToMaybe (scriptToAddressBS (scriptOutput o))
        }

data TxData = TxData
    { txDataBlock   :: BlockRef
    , txData        :: Tx
    , txDataPrevs   :: IntMap Prev
    , txDataDeleted :: Bool
    , txDataRBF     :: Bool
    , txDataTime    :: Word64
    } deriving (Show, Eq, Ord, Generic, Serialize, NFData)

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
    txsize = fromIntegral $ B.length (S.encode (txData t))
    txweight =
        let b = B.length $ S.encode (txData t) {txWitness = []}
            x = B.length $ S.encode (txData t)
         in fromIntegral $ b * 3 + x
    inv = sum (map inputAmount ins)
    outv = sum (map outputAmount outs)
    fees =
      if any isCoinbase ins
          then 0
          else inv - outv
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
    { transactionBlock    :: BlockRef
      -- ^ block information for this transaction
    , transactionVersion  :: Word32
      -- ^ transaction version
    , transactionLockTime :: Word32
      -- ^ lock time
    , transactionInputs   :: [StoreInput]
      -- ^ transaction inputs
    , transactionOutputs  :: [StoreOutput]
      -- ^ transaction outputs
    , transactionDeleted  :: Bool
      -- ^ this transaction has been deleted and is no longer valid
    , transactionRBF      :: Bool
      -- ^ this transaction can be replaced in the mempool
    , transactionTime     :: Word64
      -- ^ time the transaction was first seen or time of block
    , transactionId       :: TxHash
      -- ^ transaction id
    , transactionSize     :: Word32
      -- ^ serialized transaction size (includes witness data)
    , transactionWeight   :: Word32
      -- ^ transaction weight
    , transactionFees     :: Word64
      -- ^ fees that this transaction pays (0 for coinbase)
    } deriving (Show, Eq, Ord, Generic, Hashable, Serialize, NFData)

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

transactionToJSON :: Network -> Transaction -> Value
transactionToJSON net dtx =
    object $
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
    ] <>
    [ "rbf" .= transactionRBF dtx | getReplaceByFee net] <>
    [ "weight" .= transactionWeight dtx | getSegWit net]

transactionToEncoding :: Network -> Transaction -> Encoding
transactionToEncoding net dtx =
    pairs
        (  "txid" .= transactionId dtx
        <> "size" .= transactionSize dtx
        <> "version" .= transactionVersion dtx
        <> "locktime" .= transactionLockTime dtx
        <> "fee" .= transactionFees dtx
        <> "inputs" `pair` list (storeInputToEncoding net) (transactionInputs dtx)
        <> "outputs" `pair` list (storeOutputToEncoding net) (transactionOutputs dtx)
        <> "block" .= transactionBlock dtx
        <> "deleted" .= transactionDeleted dtx
        <> "time" .= transactionTime dtx
        <> (if getReplaceByFee net
            then "rbf" .= transactionRBF dtx
            else mempty)
        <> (if getSegWit net
           then "weight" .= transactionWeight dtx
           else mempty)
        )

transactionParseJSON :: Network -> Value -> Parser Transaction
transactionParseJSON net =
    A.withObject "transaction" $ \o -> do
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
data PeerInformation
    = PeerInformation { peerUserAgent :: ByteString
                        -- ^ user agent string
                      , peerAddress   :: String
                        -- ^ network address
                      , peerVersion   :: Word32
                        -- ^ version number
                      , peerServices  :: Word64
                        -- ^ services field
                      , peerRelay     :: Bool
                        -- ^ will relay transactions
                      }
    deriving (Show, Eq, Ord, Generic, NFData, Serialize)

instance ToJSON PeerInformation where
    toJSON p = object
        [ "useragent"   .= String (cs (peerUserAgent p))
        , "address"     .= peerAddress p
        , "version"     .= peerVersion p
        , "services"    .= String (encodeHex (S.encode (peerServices p)))
        , "relay"       .= peerRelay p
        ]
    toEncoding p = pairs
        (  "useragent"   `pair` text (cs (peerUserAgent p))
        <> "address"     .= peerAddress p
        <> "version"     .= peerVersion p
        <> "services"    `pair` text (encodeHex (S.encode (peerServices p)))
        <> "relay"       .= peerRelay p
        )

instance FromJSON PeerInformation where
    parseJSON =
        A.withObject "peerinformation" $ \o -> do
            String useragent <- o .: "useragent"
            address <- o .: "address"
            version <- o .: "version"
            services <-
                o .: "services" >>= jsonHex >>= \b ->
                    case S.decode b of
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
data XPubBal = XPubBal
    { xPubBalPath :: [KeyIndex]
    , xPubBal     :: Balance
    } deriving (Show, Ord, Eq, Generic, Serialize, NFData)

xPubBalToJSON :: Network -> XPubBal -> Value
xPubBalToJSON net XPubBal {xPubBalPath = p, xPubBal = b} =
    object ["path" .= p, "balance" .= balanceToJSON net b]

xPubBalToEncoding :: Network -> XPubBal -> Encoding
xPubBalToEncoding net XPubBal {xPubBalPath = p, xPubBal = b} =
    pairs ("path" .= p <> "balance" `pair` balanceToEncoding net b)

xPubBalParseJSON :: Network -> Value -> Parser XPubBal
xPubBalParseJSON net =
    A.withObject "xpubbal" $ \o -> do
        path <- o .: "path"
        balance <- balanceParseJSON net =<< o .: "balance"
        return XPubBal {xPubBalPath = path, xPubBal = balance}

-- | Unspent transaction for extended public key.
data XPubUnspent = XPubUnspent
    { xPubUnspentPath :: [KeyIndex]
    , xPubUnspent     :: Unspent
    } deriving (Show, Eq, Generic, Serialize, NFData)

xPubUnspentToJSON :: Network -> XPubUnspent -> Value
xPubUnspentToJSON net XPubUnspent {xPubUnspentPath = p, xPubUnspent = u} =
    object ["path" .= p, "unspent" .= unspentToJSON net u]

xPubUnspentToEncoding :: Network -> XPubUnspent -> Encoding
xPubUnspentToEncoding net XPubUnspent {xPubUnspentPath = p, xPubUnspent = u} =
    pairs ("path" .= p <> "unspent" `pair` unspentToEncoding net u)

xPubUnspentParseJSON :: Network -> Value -> Parser XPubUnspent
xPubUnspentParseJSON net =
    A.withObject "xpubunspent" $ \o -> do
        p <- o .: "path"
        u <- o .: "unspent" >>= unspentParseJSON net
        return XPubUnspent {xPubUnspentPath = p, xPubUnspent = u}

data XPubSummary =
    XPubSummary
        { xPubSummaryConfirmed :: Word64
        , xPubSummaryZero      :: Word64
        , xPubSummaryReceived  :: Word64
        , xPubUnspentCount     :: Word64
        , xPubExternalIndex    :: Word32
        , xPubChangeIndex      :: Word32
        }
    deriving (Eq, Show, Generic, Serialize, NFData)

instance ToJSON XPubSummary where
    toJSON XPubSummary { xPubSummaryConfirmed = c
                       , xPubSummaryZero = z
                       , xPubSummaryReceived = r
                       , xPubUnspentCount = u
                       , xPubExternalIndex = ext
                       , xPubChangeIndex = ch
                       } =
        object
            [ "balance" .=
              object
                  [ "confirmed" .= c
                  , "unconfirmed" .= z
                  , "received" .= r
                  , "utxo" .= u
                  ]
            , "indices" .= object ["change" .= ch, "external" .= ext]
            ]
    toEncoding XPubSummary { xPubSummaryConfirmed = c
                       , xPubSummaryZero = z
                       , xPubSummaryReceived = r
                       , xPubUnspentCount = u
                       , xPubExternalIndex = ext
                       , xPubChangeIndex = ch
                       } =
        pairs
            (  "balance" `pair` pairs
                (  "confirmed" .= c
                <> "unconfirmed" .= z
                <> "received" .= r
                <> "utxo" .= u
                )
            <> "indices" `pair` pairs
                (  "change" .= ch
                <> "external" .= ext
                )
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

data HealthCheck =
    HealthCheck
        { healthHeaderBest   :: Maybe BlockHash
        , healthHeaderHeight :: Maybe BlockHeight
        , healthBlockBest    :: Maybe BlockHash
        , healthBlockHeight  :: Maybe BlockHeight
        , healthPeers        :: Maybe Int
        , healthNetwork      :: String
        , healthOK           :: Bool
        , healthSynced       :: Bool
        , healthLastBlock    :: Maybe Word64
        , healthLastTx       :: Maybe Word64
        , healthVersion      :: String
        }
    deriving (Show, Eq, Generic, Serialize, NFData)

instance ToJSON HealthCheck where
    toJSON h =
        object
            [ "headers" .=
              object
                  [ "hash" .= healthHeaderBest h
                  , "height" .= healthHeaderHeight h
                  ]
            , "blocks" .=
              object
                  ["hash" .= healthBlockBest h, "height" .= healthBlockHeight h]
            , "peers" .= healthPeers h
            , "net" .= healthNetwork h
            , "ok" .= healthOK h
            , "synced" .= healthSynced h
            , "version" .= healthVersion h
            , "lastblock" .= healthLastBlock h
            , "lasttx" .= healthLastTx h
            ]
    toEncoding h =
        pairs
            (  "headers" `pair`
              pairs
                  (  "hash" .= healthHeaderBest h
                  <> "height" .= healthHeaderHeight h
                  )
            <> "blocks" `pair`
              pairs
                  (  "hash" .= healthBlockBest h
                  <> "height" .= healthBlockHeight h
                  )
            <> "peers" .= healthPeers h
            <> "net" .= healthNetwork h
            <> "ok" .= healthOK h
            <> "synced" .= healthSynced h
            <> "version" .= healthVersion h
            <> "lastblock" .= healthLastBlock h
            <> "lasttx" .= healthLastTx h
            )

instance FromJSON HealthCheck where
    parseJSON =
        A.withObject "healthcheck" $ \o -> do
            headers <- o .: "headers"
            headers_hash <- headers .: "hash"
            headers_height <- headers .: "height"
            blocks <- o .: "blocks"
            blocks_hash <- blocks .: "hash"
            blocks_height <- blocks .: "height"
            peers <- o .: "peers"
            net <- o .: "net"
            ok <- o .: "ok"
            synced <- o .: "synced"
            lastblock <- o .: "lastblock"
            lasttx <- o .: "lasttx"
            ver <- o .: "version"
            return
                HealthCheck
                    { healthHeaderBest = headers_hash
                    , healthHeaderHeight = headers_height
                    , healthBlockBest = blocks_hash
                    , healthBlockHeight = blocks_height
                    , healthPeers = peers
                    , healthNetwork = net
                    , healthOK = ok
                    , healthSynced = synced
                    , healthLastBlock = lastblock
                    , healthLastTx = lasttx
                    , healthVersion = ver
                    }

data Event
    = EventBlock BlockHash
    | EventTx TxHash
    deriving (Show, Eq, Generic, Serialize, NFData)

instance ToJSON Event where
    toJSON (EventTx h)    = object ["type" .= String "tx", "id" .= h]
    toJSON (EventBlock h) = object ["type" .= String "block", "id" .= h]
    toEncoding (EventTx h) =
        pairs ("type" `pair` text "tx" <> "id" `pair` text (txHashToHex h))
    toEncoding (EventBlock h) =
        pairs
            ("type" `pair` text "block" <> "id" `pair` text (blockHashToHex h))

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
    deriving (Show, Eq, Generic, Serialize, NFData)

instance ToJSON a => ToJSON (GenericResult a) where
    toJSON (GenericResult b) = object ["result" .= b]
    toEncoding (GenericResult b) = pairs ("result" .= b)

instance FromJSON a => FromJSON (GenericResult a) where
    parseJSON =
        A.withObject "GenericResult" $ \o -> GenericResult <$> o .: "result"

newtype RawResult a =
    RawResult
        { getRawResult :: a
        }
    deriving (Show, Eq, Generic, Serialize, NFData)

instance S.Serialize a => ToJSON (RawResult a) where
    toJSON (RawResult b) =
        object [ "result" .= A.String (encodeHex $ S.encode b)]
    toEncoding (RawResult b) =
        pairs $ "result" `pair` unsafeToEncoding str
      where
        str = char7 '"' <> lazyByteStringHex (S.runPutLazy $ put b) <> char7 '"'

instance S.Serialize a => FromJSON (RawResult a) where
    parseJSON =
        A.withObject "RawResult" $ \o -> do
            res <- o .: "result"
            let valM = eitherToMaybe . S.decode =<< decodeHex res
            maybe mzero (return . RawResult) valM

newtype RawResultList a =
    RawResultList
        { getRawResultList :: [a]
        }
    deriving (Show, Eq, Generic, Serialize, NFData)

instance Semigroup (RawResultList a) where
    (RawResultList a) <> (RawResultList b) = RawResultList $ a <> b

instance Monoid (RawResultList a) where
    mempty = RawResultList mempty

instance S.Serialize a => ToJSON (RawResultList a) where
    toJSON (RawResultList xs) =
        toJSON $ encodeHex . S.encode <$> xs
    toEncoding (RawResultList xs) =
        list (unsafeToEncoding . str) xs
      where
        str x =
            char7 '"' <> lazyByteStringHex (S.runPutLazy (put x)) <> char7 '"'

instance S.Serialize a => FromJSON (RawResultList a) where
    parseJSON =
        A.withArray "RawResultList" $ \vec ->
            RawResultList <$> mapM parseElem (toList vec)
      where
        parseElem = A.withText "RawResultListElem" $ maybe mzero return . f
        f = eitherToMaybe . S.decode <=< decodeHex

newtype TxId =
    TxId TxHash
    deriving (Show, Eq, Generic, Serialize, NFData)

instance ToJSON TxId where
    toJSON (TxId h) = object ["txid" .= h]
    toEncoding (TxId h) = pairs ("txid" `pair` text (txHashToHex h))

instance FromJSON TxId where
    parseJSON = A.withObject "txid" $ \o -> TxId <$> o .: "txid"

data Except
    = ThingNotFound
    | ServerError
    | BadRequest
    | UserError String
    | StringError String
    | BlockTooLarge
    deriving (Eq, Ord, Serialize, Generic, NFData)

instance Show Except where
    show ThingNotFound   = "not found"
    show ServerError     = "you made me kill a unicorn"
    show BadRequest      = "bad request"
    show (UserError s)   = s
    show (StringError _) = "you killed the dragon with your bare hands"
    show BlockTooLarge   = "block too large"

instance Exception Except

instance ScottyError Except where
    stringError = StringError
    showError = TL.pack . show

instance ToJSON Except where
    toJSON e = object ["error" .= TL.pack (show e)]
