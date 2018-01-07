{-# LANGUAGE DeriveGeneric   #-}
{-# LANGUAGE RecordWildCards #-}
module Network.Haskoin.Store.Json where

import           Data.Aeson
import           Data.Word                   (Word32)
import           GHC.Generics
import           Network.Haskoin.Block
import           Network.Haskoin.Transaction

data JsonBlock = JsonBlock
    { hash         :: !BlockHash
    , height       :: !BlockHeight
    , previous     :: !BlockHash
    , next         :: !(Maybe BlockHash)
    , timestamp    :: !Timestamp
    , version      :: !Word32
    , bits         :: !Word32
    , nonce        :: !Word32
    , transactions :: ![TxHash]
    } deriving (Generic, Show)

decodeJsonBlock :: JsonBlock -> (BlockHeader, [TxHash])
decodeJsonBlock JsonBlock {..} = (header, transactions)
  where
    header =
        BlockHeader
        { blockVersion = version
        , prevBlock = previous
        , merkleRoot = buildMerkleRoot transactions
        , blockTimestamp = timestamp
        , blockBits = bits
        , bhNonce = nonce
        }

encodeJsonBlock ::
       BlockHeader
    -> BlockHeight
    -> Maybe BlockHash -- ^ next block
    -> [TxHash]
    -> JsonBlock
encodeJsonBlock header@BlockHeader {..} height next txs =
    JsonBlock
    { hash = headerHash header
    , height = height
    , previous = prevBlock
    , next = next
    , timestamp = blockTimestamp
    , version = blockVersion
    , bits = blockBits
    , nonce = bhNonce
    , transactions = txs
    }

instance ToJSON JsonBlock where
    toEncoding = genericToEncoding defaultOptions

instance FromJSON JsonBlock
