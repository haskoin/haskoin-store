{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
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
    , Healthy(..)
    , BlockHealth(..)
    , TimeHealth(..)
    , CountHealth(..)
    , MaxHealth(..)
    , HealthCheck(..)
    , Event(..)
    , Except(..)

     -- * Blockchain.info API
    , BinfoTxId(..)
    , encodeBinfoTxId
    , BinfoMultiAddr(..)
    , binfoMultiAddrToJSON
    , binfoMultiAddrToEncoding
    , binfoMultiAddrParseJSON
    , BinfoAddress(..)
    , toBinfoAddrs
    , binfoAddressToJSON
    , binfoAddressToEncoding
    , binfoAddressParseJSON
    , BinfoAddr(..)
    , parseBinfoAddr
    , BinfoWallet(..)
    , BinfoUnspent(..)
    , binfoUnspentToJSON
    , binfoUnspentToEncoding
    , binfoUnspentParseJSON
    , BinfoUnspents(..)
    , binfoUnspentsToJSON
    , binfoUnspentsToEncoding
    , binfoUnspentsParseJSON
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
import           Control.Monad           (guard, join, mzero, (<=<))
import           Data.Aeson              (Encoding, FromJSON (..),
                                          FromJSONKey (..), ToJSON (..),
                                          ToJSONKey (..), Value (..), object,
                                          pairs, withObject, (.!=), (.:), (.:?),
                                          (.=))
import qualified Data.Aeson              as A
import           Data.Aeson.Encoding     (list, null_, pair, text,
                                          unsafeToEncoding)
import           Data.Aeson.Types        (Parser)
import           Data.Bits               (setBit, shift, testBit, (.&.), (.|.))
import           Data.ByteString         (ByteString)
import qualified Data.ByteString         as B
import           Data.ByteString.Builder (char7, lazyByteStringHex)
import           Data.ByteString.Short   (ShortByteString)
import qualified Data.ByteString.Short   as BSS
import           Data.Default            (Default (..))
import           Data.Either             (fromRight, lefts, rights)
import           Data.Foldable           (toList)
import           Data.Function           (on)
import           Data.HashMap.Strict     (HashMap)
import qualified Data.HashMap.Strict     as HashMap
import           Data.HashSet            (HashSet)
import qualified Data.HashSet            as HashSet
import           Data.Hashable           (Hashable (..))
import           Data.Int                (Int64)
import qualified Data.IntMap             as IntMap
import           Data.IntMap.Strict      (IntMap)
import           Data.Map.Strict         (Map)
import           Data.Maybe              (catMaybes, fromMaybe, isJust,
                                          isNothing, mapMaybe, maybeToList)
import           Data.Serialize          (Get, Put, Serialize (..), getWord32be,
                                          getWord64be, getWord8, putWord32be,
                                          putWord64be, putWord8)
import qualified Data.Serialize          as S
import           Data.String.Conversions (cs)
import           Data.Text               (Text)
import qualified Data.Text               as T
import           Data.Text.Encoding      (decodeUtf8, encodeUtf8)
import qualified Data.Text.Lazy          as TL
import           Data.Word               (Word32, Word64)
import           GHC.Generics            (Generic)
import           Haskoin                 (Address, BlockHash, BlockHeader (..),
                                          BlockHeight, BlockWork, Coin (..),
                                          KeyIndex, Network (..), OutPoint (..),
                                          PubKeyI (..), SoftPath, Tx (..),
                                          TxHash (..), TxIn (..), TxOut (..),
                                          WitnessStack, XPubKey (..),
                                          addrFromJSON, addrToEncoding,
                                          addrToJSON, bch, blockHashToHex, btc,
                                          decodeHex, eitherToMaybe, encodeHex,
                                          headerHash, hexToTxHash,
                                          maybeToEither, parseSoft, pathToList,
                                          pathToStr, putVarInt,
                                          scriptToAddressBS, textToAddr, txHash,
                                          txHashToHex, wrapPubKey, xPubFromJSON,
                                          xPubImport, xPubToEncoding,
                                          xPubToJSON)
import           Text.Printf             (printf)
import           Text.Read               (readMaybe)
import           Web.Scotty.Trans        (Parsable (..), ScottyError (..))

data DeriveType = DeriveNormal
    | DeriveP2SH
    | DeriveP2WPKH
    deriving (Show, Eq, Generic, NFData, Serialize)

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
    deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable, NFData)

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
data Unspent =
    Unspent
        { unspentBlock   :: !BlockRef
        , unspentPoint   :: !OutPoint
        , unspentAmount  :: !Word64
        , unspentScript  :: !ShortByteString
        , unspentAddress :: !(Maybe Address)
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
    , "witness" .= map encodeHex wit
    ]
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
    , "witness" .= map encodeHex wit
    ]

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
        <> "witness" .= map encodeHex wit
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
        <> "witness" .= map encodeHex wit
        )

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
    deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable, NFData)

instance ToJSON Spender where
    toJSON n =
        object
        [ "txid" .= txHashToHex (spenderHash n)
        , "input" .= spenderIndex n
        ]
    toEncoding n =
        pairs $
          "txid" .= txHashToHex (spenderHash n) <>
          "input" .= spenderIndex n

instance FromJSON Spender where
    parseJSON =
        A.withObject "spender" $ \o -> Spender <$> o .: "txid" <*> o .: "input"

-- | Output information.
data StoreOutput =
    StoreOutput
        { outputAmount  :: !Word64
        , outputScript  :: !ByteString
        , outputSpender :: !(Maybe Spender)
        , outputAddress :: !(Maybe Address)
        }
    deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable, NFData)

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
            Just a  -> Just <$> addrFromJSON net a <|> return Nothing
        return
            StoreOutput
                { outputAmount = value
                , outputScript = pkscript
                , outputSpender = spender
                , outputAddress = addr
                }

data Prev =
    Prev
        { prevScript :: !ByteString
        , prevAmount :: !Word64
        }
    deriving (Show, Eq, Ord, Generic, Hashable, Serialize, NFData)

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
        , outputAddress = eitherToMaybe (scriptToAddressBS (scriptOutput o))
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
    deriving (Show, Eq, Ord, Generic, Serialize, NFData)

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
    deriving (Show, Eq, Ord, Generic, Hashable, Serialize, NFData)

transactionData :: Transaction -> Tx
transactionData t =
    Tx
        { txVersion = transactionVersion t
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
    , "rbf" .= transactionRBF dtx
    , "weight" .= transactionWeight dtx
    ]

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
        <> "rbf" .= transactionRBF dtx
        <> "weight" .= transactionWeight dtx
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
data XPubBal =
    XPubBal
        { xPubBalPath :: ![KeyIndex]
        , xPubBal     :: !Balance
        }
    deriving (Show, Ord, Eq, Generic, Serialize, NFData)

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
data XPubUnspent =
    XPubUnspent
        { xPubUnspentPath :: ![KeyIndex]
        , xPubUnspent     :: !Unspent
        }
    deriving (Show, Eq, Generic, Serialize, NFData)

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
        { xPubSummaryConfirmed :: !Word64
        , xPubSummaryZero      :: !Word64
        , xPubSummaryReceived  :: !Word64
        , xPubUnspentCount     :: !Word64
        , xPubExternalIndex    :: !Word32
        , xPubChangeIndex      :: !Word32
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

class Healthy a where
    isOK :: a -> Bool

data BlockHealth =
    BlockHealth
        { blockHealthHeaders :: !BlockHeight
        , blockHealthBlocks  :: !BlockHeight
        , blockHealthMaxDiff :: !Int
        }
    deriving (Show, Eq, Generic, NFData)

instance Serialize BlockHealth where
    put h@BlockHealth {..} = do
        put (isOK h)
        put blockHealthHeaders
        put blockHealthBlocks
        put blockHealthMaxDiff
    get = do
        k <- get
        blockHealthHeaders <- get
        blockHealthBlocks  <- get
        blockHealthMaxDiff <- get
        let h = BlockHealth {..}
        guard (k == isOK h)
        return h

instance Healthy BlockHealth where
    isOK BlockHealth {..} =
        h - b <= blockHealthMaxDiff
      where
        h = fromIntegral blockHealthHeaders
        b = fromIntegral blockHealthBlocks

instance ToJSON BlockHealth where
    toJSON h@BlockHealth {..} =
        object
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
        { timeHealthAge :: !Int
        , timeHealthMax :: !Int
        }
    deriving (Show, Eq, Generic, NFData)

instance Serialize TimeHealth where
    put h@TimeHealth {..} = do
        put (isOK h)
        put timeHealthAge
        put timeHealthMax
    get = do
        k <- get
        timeHealthAge <- get
        timeHealthMax <- get
        let t = TimeHealth {..}
        guard (k == isOK t)
        return t

instance Healthy TimeHealth where
    isOK TimeHealth {..} =
        timeHealthAge <= timeHealthMax

instance ToJSON TimeHealth where
    toJSON h@TimeHealth {..} =
        object
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
        { countHealthNum :: !Int
        , countHealthMin :: !Int
        }
    deriving (Show, Eq, Generic, NFData)

instance Serialize CountHealth where
    put h@CountHealth {..} = do
        put (isOK h)
        put countHealthNum
        put countHealthMin
    get = do
        k <- get
        countHealthNum <- get
        countHealthMin <- get
        let c = CountHealth {..}
        guard (k == isOK c)
        return c

instance Healthy CountHealth where
    isOK CountHealth {..} =
        countHealthMin <= countHealthNum

instance ToJSON CountHealth where
    toJSON h@CountHealth {..} =
        object
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
        { maxHealthNum :: !Int
        , maxHealthMax :: !Int
        }
    deriving (Show, Eq, Generic, NFData)

instance Serialize MaxHealth where
    put h@MaxHealth {..} = do
        put $ isOK h
        put maxHealthNum
        put maxHealthMax
    get = do
        k <- get
        maxHealthNum <- get
        maxHealthMax <- get
        let h = MaxHealth {..}
        guard (k == isOK h)
        return h

instance Healthy MaxHealth where
    isOK MaxHealth {..} = maxHealthNum <= maxHealthMax

instance ToJSON MaxHealth where
    toJSON h@MaxHealth {..} =
        object
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

instance Serialize HealthCheck where
    put h@HealthCheck {..} = do
        put (isOK h)
        put healthBlocks
        put healthLastBlock
        put healthLastTx
        put healthPendingTxs
        put healthPeers
        put healthNetwork
        put healthVersion
    get = do
        k <- get
        healthBlocks        <- get
        healthLastBlock     <- get
        healthLastTx        <- get
        healthPendingTxs    <- get
        healthPeers         <- get
        healthNetwork       <- get
        healthVersion       <- get
        let h = HealthCheck {..}
        guard (k == isOK h)
        return h

instance Healthy HealthCheck where
    isOK HealthCheck {..} =
        isOK healthBlocks &&
        isOK healthLastBlock &&
        isOK healthLastTx &&
        isOK healthPendingTxs &&
        isOK healthPeers

instance ToJSON HealthCheck where
    toJSON h@HealthCheck {..} =
        object
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
    deriving (Show, Eq, Generic, Serialize, NFData)

instance ToJSON Event where
    toJSON (EventTx h)    = object ["type" .= String "tx", "id" .= h]
    toJSON (EventBlock h) = object ["type" .= String "block", "id" .= h]
    toEncoding (EventTx h) =
        pairs ("type" `pair` text "tx" <> "id" `pair` text (txHashToHex h))
    toEncoding (EventBlock h) =
        pairs ("type" `pair` text "block" <> "id" `pair` text (blockHashToHex h))

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
    | UserError !String
    | StringError !String
    | BlockTooLarge
    deriving (Show, Eq, Ord, Serialize, Generic, NFData)

instance Exception Except

instance ScottyError Except where
    stringError = StringError
    showError = TL.pack . show

instance ToJSON Except where
    toJSON e =
        object $
        case e of
            ThingNotFound ->
                ["error" .= String "not-found"]
            ServerError ->
                ["error" .= String "server-error"]
            BadRequest ->
                ["error" .= String "bad-request"]
            UserError msg ->
                [ "error" .= String "user-error"
                , "message" .= String (cs msg)
                ]
            StringError msg ->
                [ "error" .= String "string-error"
                , "message" .= String (cs msg)
                ]
            BlockTooLarge ->
                ["error" .= String "block-too-large"]

instance FromJSON Except where
    parseJSON =
        A.withObject "Except" $ \o -> do
            ctr <- o .: "error"
            msg <- fromMaybe "" <$> o .:? "message"
            case ctr of
                String "not-found"       -> return ThingNotFound
                String "server-error"    -> return ServerError
                String "bad-request"     -> return BadRequest
                String "user-error"      -> return $ UserError msg
                String "string-error"    -> return $ StringError msg
                String "block-too-large" -> return BlockTooLarge
                _                        -> mzero

toIntTxId :: TxHash -> Word64
toIntTxId h =
    let bs = S.encode h
        Right w64 = S.runGet getWord64be bs
    in w64 `shift` (-11)

---------------------------------------
-- Blockchain.info API Compatibility --
---------------------------------------

data BinfoTxId
    = BinfoTxIdHash !TxHash
    | BinfoTxIdIndex !Word64
    deriving (Eq, Show, Read, Generic, Serialize, NFData)

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
                Just h -> Right $ BinfoTxIdHash h
        igr = BinfoTxIdIndex <$> parseParam t

instance ToJSON BinfoTxId where
    toJSON (BinfoTxIdHash h)  = toJSON h
    toJSON (BinfoTxIdIndex i) = toJSON i
    toEncoding (BinfoTxIdHash h)  = toEncoding h
    toEncoding (BinfoTxIdIndex i) = toEncoding i

instance FromJSON BinfoTxId where
    parseJSON v = BinfoTxIdHash <$> parseJSON v <|>
                  BinfoTxIdIndex <$> parseJSON v

data BinfoMultiAddr
    = BinfoMultiAddr
        { getBinfoMultiAddrAddresses    :: ![BinfoAddress]
        , getBinfoMultiAddrWallet       :: !BinfoWallet
        , getBinfoMultiAddrTxs          :: ![BinfoTx]
        , getBinfoMultiAddrInfo         :: !BinfoInfo
        , getBinfoMultiAddrRecommendFee :: !Bool
        , getBinfoMultiAddrCashAddr     :: !Bool
        }
    deriving (Eq, Show, Generic, NFData)

binfoMultiAddrToJSON :: Network -> BinfoMultiAddr -> Value
binfoMultiAddrToJSON net' BinfoMultiAddr {..} =
    object $
        [ "addresses" .= map (binfoAddressToJSON net) getBinfoMultiAddrAddresses
        , "wallet"    .= getBinfoMultiAddrWallet
        , "txs"       .= map (binfoTxToJSON net) getBinfoMultiAddrTxs
        , "info"      .= getBinfoMultiAddrInfo
        , "recommend_include_fee" .= getBinfoMultiAddrRecommendFee
        ] ++
        [ "cash_addr" .= True | getBinfoMultiAddrCashAddr ]
  where
    net = if not getBinfoMultiAddrCashAddr && net' == bch then btc else net'

binfoMultiAddrParseJSON :: Network -> Value -> Parser BinfoMultiAddr
binfoMultiAddrParseJSON net = withObject "multiaddr" $ \o -> do
    getBinfoMultiAddrAddresses <-
        mapM (binfoAddressParseJSON net) =<< o .: "addresses"
    getBinfoMultiAddrWallet <- o .: "wallet"
    getBinfoMultiAddrTxs <-
        mapM (binfoTxParseJSON net) =<< o .: "txs"
    getBinfoMultiAddrInfo <- o .: "info"
    getBinfoMultiAddrRecommendFee <- o .: "recommend_include_fee"
    getBinfoMultiAddrCashAddr <- o .:? "cash_addr" .!= False
    return BinfoMultiAddr {..}

binfoMultiAddrToEncoding :: Network -> BinfoMultiAddr -> Encoding
binfoMultiAddrToEncoding net' BinfoMultiAddr {..} =
    pairs
        (  "addresses" `pair` as
        <> "wallet"    .= getBinfoMultiAddrWallet
        <> "txs"       `pair` ts
        <> "info"      .= getBinfoMultiAddrInfo
        <> "recommend_include_fee" .= getBinfoMultiAddrRecommendFee
        <> if getBinfoMultiAddrCashAddr then "cash_addr" .= True else mempty
        )
  where
    as = list (binfoAddressToEncoding net) getBinfoMultiAddrAddresses
    ts = list (binfoTxToEncoding net) getBinfoMultiAddrTxs
    net = if not getBinfoMultiAddrCashAddr && net' == bch then btc else net'

data BinfoAddress
    = BinfoAddress
        { getBinfoAddress      :: !Address
        , getBinfoAddrTxCount  :: !Word64
        , getBinfoAddrReceived :: !Word64
        , getBinfoAddrSent     :: !Word64
        , getBinfoAddrBalance  :: !Word64
        }
    | BinfoXPubKey
        { getBinfoXPubKey          :: !XPubKey
        , getBinfoAddrTxCount      :: !Word64
        , getBinfoAddrReceived     :: !Word64
        , getBinfoAddrSent         :: !Word64
        , getBinfoAddrBalance      :: !Word64
        , getBinfoXPubAccountIndex :: !Word32
        , getBinfoXPubChangeIndex  :: !Word32
        }
    deriving (Eq, Show, Generic, Serialize, NFData)

binfoAddressToJSON :: Network -> BinfoAddress -> Value
binfoAddressToJSON net BinfoAddress {..} =
    object
        [ "address"        .= addrToJSON net getBinfoAddress
        , "final_balance"  .= getBinfoAddrBalance
        , "n_tx"           .= getBinfoAddrTxCount
        , "total_received" .= getBinfoAddrReceived
        , "total_sent"     .= getBinfoAddrSent
        ]
binfoAddressToJSON net BinfoXPubKey {..} =
    object
        [ "address"        .= xPubToJSON net getBinfoXPubKey
        , "change_index"   .= getBinfoXPubChangeIndex
        , "account_index"  .= getBinfoXPubAccountIndex
        , "final_balance"  .= getBinfoAddrBalance
        , "n_tx"           .= getBinfoAddrTxCount
        , "total_received" .= getBinfoAddrReceived
        , "total_sent"     .= getBinfoAddrSent
        ]

binfoAddressParseJSON :: Network -> Value -> Parser BinfoAddress
binfoAddressParseJSON net = withObject "address" $ \o -> x o <|> a o
  where
    x o = do
        getBinfoXPubKey <- xPubFromJSON net =<< o .: "address"
        getBinfoXPubChangeIndex <- o .: "change_index"
        getBinfoXPubAccountIndex <- o .: "account_index"
        getBinfoAddrBalance <- o .: "final_balance"
        getBinfoAddrTxCount <- o .: "n_tx"
        getBinfoAddrReceived <- o .: "total_received"
        getBinfoAddrSent <- o .: "total_sent"
        return BinfoXPubKey{..}
    a o = do
        getBinfoAddress <- addrFromJSON net =<< o .: "address"
        getBinfoAddrBalance <- o .: "final_balance"
        getBinfoAddrTxCount <- o .: "n_tx"
        getBinfoAddrReceived <- o .: "total_received"
        getBinfoAddrSent <- o .: "total_sent"
        return BinfoAddress{..}

binfoAddressToEncoding :: Network -> BinfoAddress -> Encoding
binfoAddressToEncoding net BinfoAddress {..} =
    pairs
        (  "address"         `pair` addrToEncoding net getBinfoAddress
        <> "final_balance"   .= getBinfoAddrBalance
        <> "n_tx"            .= getBinfoAddrTxCount
        <> "total_received"  .= getBinfoAddrReceived
        <> "total_sent"      .= getBinfoAddrSent
        )
binfoAddressToEncoding net BinfoXPubKey {..} =
    pairs
        (  "address"         `pair` xPubToEncoding net getBinfoXPubKey
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
    deriving (Eq, Show, Generic, Serialize, NFData)

instance ToJSON BinfoWallet where
    toJSON BinfoWallet {..} =
        object
            [ "final_balance"     .= getBinfoWalletBalance
            , "n_tx"              .= getBinfoWalletTxCount
            , "n_tx_filtered"     .= getBinfoWalletFilteredCount
            , "total_received"    .= getBinfoWalletTotalReceived
            , "total_sent"        .= getBinfoWalletTotalSent
            ]
    toEncoding BinfoWallet {..} =
        pairs
            (  "final_balance"    .= getBinfoWalletBalance
            <> "n_tx"             .= getBinfoWalletTxCount
            <> "n_tx_filtered"    .= getBinfoWalletFilteredCount
            <> "total_received"   .= getBinfoWalletTotalReceived
            <> "total_sent"       .= getBinfoWalletTotalSent
            )

instance FromJSON BinfoWallet where
    parseJSON = withObject "wallet" $ \o -> do
        getBinfoWalletBalance <- o .: "final_balance"
        getBinfoWalletTxCount <- o .: "n_tx"
        getBinfoWalletFilteredCount <- o .: "n_tx_filtered"
        getBinfoWalletTotalReceived <- o .: "total_received"
        getBinfoWalletTotalSent <- o .: "total_sent"
        return BinfoWallet {..}

data BinfoUnspent
    = BinfoUnspent
      { getBinfoUnspentHash          :: !TxHash
      , getBinfoUnspentOutputIndex   :: !Word32
      , getBinfoUnspentScript        :: !ByteString
      , getBinfoUnspentValue         :: !Word64
      , getBinfoUnspentConfirmations :: !Word32
      , getBinfoUnspentTxIndex       :: !BinfoTxId
      , getBinfoUnspentXPub          :: !(Maybe BinfoXPubPath)
      } deriving (Eq, Show, Generic, Serialize, NFData)

binfoUnspentToJSON :: Network -> BinfoUnspent -> Value
binfoUnspentToJSON net BinfoUnspent{..} =
        object $
        [ "tx_hash_big_endian" .= getBinfoUnspentHash
        , "tx_hash" .= encodeHex (S.encode (getTxHash getBinfoUnspentHash))
        , "tx_output_n" .= getBinfoUnspentOutputIndex
        , "script" .= encodeHex getBinfoUnspentScript
        , "value" .= getBinfoUnspentValue
        , "value_hex" .= (printf "%x" getBinfoUnspentValue :: String)
        , "confirmations" .= getBinfoUnspentConfirmations
        , "tx_index" .= getBinfoUnspentTxIndex
        ] <>
        [ "xpub" .= binfoXPubPathToJSON net x
        | x <- maybeToList getBinfoUnspentXPub
        ]

binfoUnspentToEncoding :: Network -> BinfoUnspent -> Encoding
binfoUnspentToEncoding net BinfoUnspent{..} =
        pairs $
        "tx_hash_big_endian" .= getBinfoUnspentHash <>
        "tx_hash" .= encodeHex (S.encode (getTxHash getBinfoUnspentHash)) <>
        "tx_output_n" .= getBinfoUnspentOutputIndex <>
        "script" .= encodeHex getBinfoUnspentScript <>
        "value" .= getBinfoUnspentValue <>
        "value_hex" .= (printf "%x" getBinfoUnspentValue :: String) <>
        "confirmations" .= getBinfoUnspentConfirmations <>
        "tx_index" .= getBinfoUnspentTxIndex <>
        maybe mempty (("xpub" `pair`) . binfoXPubPathToEncoding net) getBinfoUnspentXPub

binfoUnspentParseJSON :: Network -> Value -> Parser BinfoUnspent
binfoUnspentParseJSON net = withObject "unspent" $ \o -> do
        getBinfoUnspentHash <- o .: "tx_hash_big_endian"
        getBinfoUnspentOutputIndex <- o .: "tx_output_n"
        getBinfoUnspentScript <- maybe mzero return . decodeHex =<< o .: "script"
        getBinfoUnspentValue <- o .: "value"
        getBinfoUnspentConfirmations <- o .: "confirmations"
        getBinfoUnspentTxIndex <- o .: "tx_index"
        getBinfoUnspentXPub <- mapM (binfoXPubPathParseJSON net) =<< o .:? "xpub"
        return BinfoUnspent{..}

newtype BinfoUnspents = BinfoUnspents [BinfoUnspent]
    deriving (Eq, Show, Generic, Serialize, NFData)

binfoUnspentsToJSON :: Network -> BinfoUnspents -> Value
binfoUnspentsToJSON net (BinfoUnspents us) =
    object
    [ "notice" .= T.empty
    , "unspent_outputs" .= map (binfoUnspentToJSON net) us
    ]

binfoUnspentsToEncoding :: Network -> BinfoUnspents -> Encoding
binfoUnspentsToEncoding net (BinfoUnspents us) =
    pairs $
    "notice" .= T.empty <>
    "unspent_outputs" `pair` list (binfoUnspentToEncoding net) us

binfoUnspentsParseJSON :: Network -> Value -> Parser BinfoUnspents
binfoUnspentsParseJSON net = withObject "unspents" $ \o -> do
    us <- mapM (binfoUnspentParseJSON net) =<< o .: "unspent_outputs"
    return (BinfoUnspents us)

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
    deriving (Eq, Show, Generic, Serialize, NFData)

binfoTxToJSON :: Network -> BinfoTx -> Value
binfoTxToJSON net BinfoTx {..} =
    object $
        [ "hash" .= getBinfoTxHash
        , "ver" .= getBinfoTxVer
        , "vin_sz" .= getBinfoTxVinSz
        , "vout_sz" .= getBinfoTxVoutSz
        , "size" .= getBinfoTxSize
        , "weight" .= getBinfoTxWeight
        , "fee" .= getBinfoTxFee
        , "relayed_by" .= decodeUtf8 getBinfoTxRelayedBy
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
    pairs $
        "hash" .= getBinfoTxHash <>
        "ver" .= getBinfoTxVer <>
        "vin_sz" .= getBinfoTxVinSz <>
        "vout_sz" .= getBinfoTxVoutSz <>
        "size" .= getBinfoTxSize <>
        "weight" .= getBinfoTxWeight <>
        "fee" .= getBinfoTxFee <>
        "relayed_by" .= decodeUtf8 getBinfoTxRelayedBy <>
        "lock_time" .= getBinfoTxLockTime <>
        "tx_index" .= getBinfoTxIndex <>
        "double_spend" .= getBinfoTxDoubleSpend <>
        "time" .= getBinfoTxTime <>
        "block_index" .= getBinfoTxBlockIndex <>
        "block_height" .= getBinfoTxBlockHeight <>
        "inputs" `pair` list (binfoTxInputToEncoding net) getBinfoTxInputs <>
        "out" `pair` list (binfoTxOutputToEncoding net) getBinfoTxOutputs <>
        bal <> rbf
  where
    bal =
        case getBinfoTxResultBal of
            Nothing         -> mempty
            Just (res, bal) -> "result" .= res <> "balance" .= bal
    rbf = if getBinfoTxRBF then "rbf" .= True else mempty

binfoTxParseJSON :: Network -> Value -> Parser BinfoTx
binfoTxParseJSON net = withObject "tx" $ \o -> do
    getBinfoTxHash <- o .: "hash"
    getBinfoTxVer <- o .: "ver"
    getBinfoTxVinSz <- o .: "vin_sz"
    getBinfoTxVoutSz <- o .: "vout_sz"
    getBinfoTxSize <- o .: "size"
    getBinfoTxWeight <- o .: "weight"
    getBinfoTxFee <- o .: "fee"
    getBinfoTxRelayedBy <- encodeUtf8 <$> o .: "relayed_by"
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
    deriving (Eq, Show, Generic, Serialize, NFData)

binfoTxInputToJSON :: Network -> BinfoTxInput -> Value
binfoTxInputToJSON net BinfoTxInput {..} =
    object
        [ "sequence" .= getBinfoTxInputSeq
        , "witness"  .= encodeHex getBinfoTxInputWitness
        , "script"   .= encodeHex getBinfoTxInputScript
        , "index"    .= getBinfoTxInputIndex
        , "prev_out" .= (binfoTxOutputToJSON net <$> getBinfoTxInputPrevOut)
        ]

binfoTxInputToEncoding :: Network -> BinfoTxInput -> Encoding
binfoTxInputToEncoding net BinfoTxInput {..} =
    pairs
        (  "sequence" .= getBinfoTxInputSeq
        <> "witness"  .= encodeHex getBinfoTxInputWitness
        <> "script"   .= encodeHex getBinfoTxInputScript
        <> "index"    .= getBinfoTxInputIndex
        <> "prev_out" .= (binfoTxOutputToJSON net <$> getBinfoTxInputPrevOut)
        )

binfoTxInputParseJSON :: Network -> Value -> Parser BinfoTxInput
binfoTxInputParseJSON net = withObject "txin" $ \o -> do
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
    deriving (Eq, Show, Generic, Serialize, NFData)

binfoTxOutputToJSON :: Network -> BinfoTxOutput -> Value
binfoTxOutputToJSON net BinfoTxOutput {..} =
    object $
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
    pairs $ mconcat $
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
binfoTxOutputParseJSON net = withObject "txout" $ \o -> do
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
    deriving (Eq, Show, Generic, Serialize, NFData)

instance ToJSON BinfoSpender where
    toJSON BinfoSpender {..} =
        object
            [ "tx_index" .= getBinfoSpenderTxIndex
            , "n" .= getBinfoSpenderIndex
            ]
    toEncoding BinfoSpender {..} =
        pairs
            (  "tx_index" .= getBinfoSpenderTxIndex
            <> "n"        .= getBinfoSpenderIndex
            )

instance FromJSON BinfoSpender where
    parseJSON = withObject "spender" $ \o -> do
        getBinfoSpenderTxIndex <- o .: "tx_index"
        getBinfoSpenderIndex <- o .: "n"
        return BinfoSpender {..}

data BinfoXPubPath
    = BinfoXPubPath
        { getBinfoXPubPathKey   :: !XPubKey
        , getBinfoXPubPathDeriv :: !SoftPath
        }
    deriving (Eq, Show, Generic, Serialize, NFData)

binfoXPubPathToJSON :: Network -> BinfoXPubPath -> Value
binfoXPubPathToJSON net BinfoXPubPath {..} =
    object
        [ "m" .= xPubToJSON net getBinfoXPubPathKey
        , "path" .= ("M" ++ pathToStr getBinfoXPubPathDeriv)
        ]

binfoXPubPathToEncoding :: Network -> BinfoXPubPath -> Encoding
binfoXPubPathToEncoding net BinfoXPubPath {..} =
    pairs $
        "m" `pair` xPubToEncoding net getBinfoXPubPathKey <>
        "path" .= ("M" ++ pathToStr getBinfoXPubPathDeriv)

binfoXPubPathParseJSON :: Network -> Value -> Parser BinfoXPubPath
binfoXPubPathParseJSON net = withObject "xpub" $ \o -> do
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
        object
            [ "nconnected" .= getBinfoConnected
            , "conversion" .= getBinfoConversion
            , "symbol_local" .= getBinfoLocal
            , "symbol_btc" .= getBinfoBTC
            , "latest_block" .= getBinfoLatestBlock
            ]
    toEncoding BinfoInfo {..} =
        pairs
            (  "nconnected" .= getBinfoConnected
            <> "conversion" .= getBinfoConversion
            <> "symbol_local" .= getBinfoLocal
            <> "symbol_btc" .= getBinfoBTC
            <> "latest_block" .= getBinfoLatestBlock
            )

instance FromJSON BinfoInfo where
    parseJSON = withObject "info" $ \o -> do
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
    deriving (Eq, Show, Generic, Serialize, NFData)

instance ToJSON BinfoBlockInfo where
    toJSON BinfoBlockInfo {..} =
        object
            [ "hash" .= getBinfoBlockInfoHash
            , "height" .= getBinfoBlockInfoHeight
            , "time" .= getBinfoBlockInfoTime
            , "block_index" .= getBinfoBlockInfoIndex
            ]
    toEncoding BinfoBlockInfo {..} =
        pairs
            (  "hash" .= getBinfoBlockInfoHash
            <> "height" .= getBinfoBlockInfoHeight
            <> "time" .= getBinfoBlockInfoTime
            <> "block_index" .= getBinfoBlockInfoIndex
            )

instance FromJSON BinfoBlockInfo where
    parseJSON = withObject "block_info" $ \o -> do
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
        object
            [ "symbol" .= binfoTickerSymbol
            , "sell" .= binfoTickerSell
            , "buy" .= binfoTickerBuy
            , "last" .= binfoTickerLast
            , "15m" .= binfoTicker15m
            ]
    toEncoding BinfoTicker{..} =
        pairs $
        "symbol" .= binfoTickerSymbol <>
        "sell" .= binfoTickerSell <>
        "buy" .= binfoTickerBuy <>
        "last" .= binfoTickerLast <>
        "15m" .= binfoTicker15m

instance FromJSON BinfoTicker where
    parseJSON = withObject "ticker" $ \o -> do
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
        object
            [ "code" .= getBinfoSymbolCode
            , "symbol" .= getBinfoSymbolString
            , "name" .= getBinfoSymbolName
            , "conversion" .= getBinfoSymbolConversion
            , "symbolAppearsAfter" .= getBinfoSymbolAfter
            , "local" .= getBinfoSymbolLocal
            ]
    toEncoding BinfoSymbol {..} =
        pairs
            (  "code" .= getBinfoSymbolCode
            <> "symbol" .= getBinfoSymbolString
            <> "name" .= getBinfoSymbolName
            <> "conversion" .= getBinfoSymbolConversion
            <> "symbolAppearsAfter" .= getBinfoSymbolAfter
            <> "local" .= getBinfoSymbolLocal
            )

instance FromJSON BinfoSymbol where
    parseJSON = withObject "symbol" $ \o -> do
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
                    case outputAddress of
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
             -> [BinfoAddress]
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
        in BinfoXPubKey{ getBinfoXPubKey = k
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
                in BinfoAddress{ getBinfoAddress = addr
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
            [] -> B.empty
            ws -> S.runPut (put_witness ws)
    prev = inputToBinfoTxOutput numtxid abook t
    put_witness ws = do
        putVarInt (length ws)
        mapM_ put_item ws
    put_item bs = do
        putVarInt (B.length bs)
        S.putByteString bs

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
            case outputAddress of
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
        getBinfoTxOutputAddress = outputAddress
        getBinfoTxOutputXPub =
            outputAddress >>= join . (`HashMap.lookup` abook)
     in if prune && isNothing (outputAddress >>= (`HashMap.lookup` abook))
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
    deriving (Eq, Show, Generic, Serialize, Hashable, NFData)

parseBinfoAddr :: Network -> Text -> Maybe [BinfoAddr]
parseBinfoAddr _ "" = Just []
parseBinfoAddr net s =
    mapM f $ T.splitOn "|" s
  where
    f x = BinfoAddr <$> textToAddr net x <|> BinfoXpub <$> xPubImport net x
