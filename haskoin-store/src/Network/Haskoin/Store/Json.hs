{-# LANGUAGE DeriveGeneric   #-}
{-# LANGUAGE RecordWildCards #-}
module Network.Haskoin.Store.Json where

import           Data.Aeson
import           Data.Word                   (Word32)
import           GHC.Generics
import           Network.Haskoin.Block
import           Network.Haskoin.Transaction

data JsonTx = JsonTx
    { txid :: !TxHash
    , tx   :: !Tx
    } deriving (Generic, Eq, Show)

instance ToJSON JsonTx where
    toEncoding = genericToEncoding defaultOptions

instance FromJSON JsonTx

data JsonBlock = JsonBlock
    { hash         :: !BlockHash
    , height       :: !BlockHeight
    , previous     :: !BlockHash
    , timestamp    :: !Timestamp
    , version      :: !Word32
    , bits         :: !Word32
    , nonce        :: !Word32
    , transactions :: ![JsonTx]
    } deriving (Generic, Eq, Show)

instance ToJSON JsonBlock where
    toEncoding = genericToEncoding defaultOptions

instance FromJSON JsonBlock

decodeJsonBlock :: JsonBlock -> (BlockHeader, [Tx])
decodeJsonBlock JsonBlock {..} = (header, map tx transactions)
  where
    header =
        BlockHeader
        { blockVersion = version
        , prevBlock = previous
        , merkleRoot = buildMerkleRoot $ map (txHash . tx) transactions
        , blockTimestamp = timestamp
        , blockBits = bits
        , bhNonce = nonce
        }

encodeJsonBlock ::
       BlockHeader
    -> BlockHeight
    -> [Tx]
    -> JsonBlock
encodeJsonBlock header@BlockHeader {..} height txs =
    JsonBlock
    { hash = headerHash header
    , height = height
    , previous = prevBlock
    , timestamp = blockTimestamp
    , version = blockVersion
    , bits = blockBits
    , nonce = bhNonce
    , transactions = map encodeJsonTx txs
    }

decodeJsonTx :: JsonTx -> Tx
decodeJsonTx = tx

encodeJsonTx :: Tx -> JsonTx
encodeJsonTx t = JsonTx (txHash t) t
