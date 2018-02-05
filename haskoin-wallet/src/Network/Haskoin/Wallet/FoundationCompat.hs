{-# LANGUAGE NoImplicitPrelude #-}
module Network.Haskoin.Wallet.FoundationCompat where

import           Control.Monad                (guard)
import qualified Data.Aeson                   as JSON
import qualified Data.Aeson.Encode.Pretty     as Pretty
import qualified Data.ByteString              as BS
import qualified Data.ByteString.Base16       as B16
import qualified Data.ByteString.Lazy         as BL
import qualified Data.Serialize               as Cereal
import           Data.Text                    (Text)
import           Foundation
import           Foundation.Compat.ByteString
import           Foundation.Compat.Text
import           Foundation.String
import qualified Network.Haskoin.Block        as Block
import qualified Network.Haskoin.Crypto       as Crypto
import qualified Network.Haskoin.Transaction  as Transaction
import           Network.Haskoin.Util         (eitherToMaybe)

{- Data.Aeson Compatibility -}

encodeJsonPretty :: JSON.ToJSON a => a -> UArray Word8
encodeJsonPretty =
    fromByteString .
    BL.toStrict .
    Pretty.encodePretty' Pretty.defConfig {Pretty.confIndent = Pretty.Spaces 2}

encodeJson :: JSON.ToJSON a => a -> UArray Word8
encodeJson = fromByteString . BL.toStrict . JSON.encode

decodeJson :: JSON.FromJSON a => UArray Word8 -> Maybe a
decodeJson = JSON.decode . BL.fromStrict . toByteString

{- Data.Serialize Compatibility -}

encodeBytes :: Cereal.Serialize a => a -> UArray Word8
encodeBytes = fromByteString . Cereal.encode

decodeBytes :: Cereal.Serialize a => UArray Word8 -> Maybe a
decodeBytes = eitherToMaybe . Cereal.decode . toByteString

{- LString, Text and ByteString Compatibility -}

toLString :: String -> LString
toLString = toList

fromLString :: LString -> String
fromLString = fromList

bsToString :: BS.ByteString -> Maybe String
bsToString = bytesToString . fromByteString

bsToString_ :: BS.ByteString -> String
bsToString_ = bytesToString_ . fromByteString

stringToBS :: String -> BS.ByteString
stringToBS = toByteString . toBytes UTF8

textToBytes :: Text -> UArray Word8
textToBytes = stringToBytes . fromText

bytesToText :: UArray Word8 -> Maybe Text
bytesToText = fmap toText . bytesToString

eitherString :: Either LString a -> Either String a
eitherString e =
    case e of
        Right res -> Right res
        Left str  -> Left $ fromList str

withBytes :: (BS.ByteString -> a) -> UArray Word8 -> a
withBytes f = f . toByteString

asBytes :: (a -> BS.ByteString) -> a -> UArray Word8
asBytes f = fromByteString . f

{- Helper functions -}

bytesToString :: UArray Word8 -> Maybe String
bytesToString a8 = do
    guard $ isNothing valM
    return str
  where
    (str,valM,_) = fromBytes UTF8 a8

bytesToString_ :: UArray Word8 -> String
bytesToString_ = fst . fromBytesLenient

stringToBytes :: String -> UArray Word8
stringToBytes = toBytes UTF8

encodeHex :: UArray Word8 -> UArray Word8
encodeHex = fromByteString . B16.encode .  toByteString

decodeHex :: UArray Word8 -> Maybe (UArray Word8)
decodeHex bytes = do
    guard (BS.null rest)
    return $ fromByteString res
  where
    (res, rest) = B16.decode $ toByteString bytes

encodeHexStr :: UArray Word8 -> String
encodeHexStr = fst . fromBytesLenient . encodeHex

encodeHexText :: UArray Word8 -> Text
encodeHexText = toText . fst . fromBytesLenient . encodeHex

decodeHexStr :: String -> Maybe (UArray Word8)
decodeHexStr = decodeHex . toBytes UTF8

decodeHexText :: Text -> Maybe (UArray Word8)
decodeHexText = decodeHex . toBytes UTF8 . fromText

toStrictBS :: BL.ByteString -> BS.ByteString
toStrictBS = BL.toStrict

{- Haskoin helper functions -}

-- TODO: Remove those when Network.Haskoin is ported to Foundation

txHashToHex :: Transaction.TxHash -> String
txHashToHex = fst . fromBytesLenient . asBytes Transaction.txHashToHex

hexToTxHash :: String -> Maybe Transaction.TxHash
hexToTxHash = Transaction.hexToTxHash . stringToBS

blockHashToHex :: Block.BlockHash -> String
blockHashToHex = fst . fromBytesLenient . asBytes Block.blockHashToHex

hexToBlockHash :: String -> Maybe Block.BlockHash
hexToBlockHash = Block.hexToBlockHash . stringToBS

addrToBase58 :: Crypto.Address -> String
addrToBase58 = fst . fromBytesLenient . asBytes Crypto.addrToBase58

base58ToAddr :: String -> Maybe Crypto.Address
base58ToAddr = Crypto.base58ToAddr . stringToBS

xPubExport :: Crypto.XPubKey -> String
xPubExport = fst . fromBytesLenient . asBytes Crypto.xPubExport

