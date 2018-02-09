{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE NoImplicitPrelude         #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE TupleSections             #-}
module Network.Haskoin.Wallet.HTTP where

import           Control.Arrow                           ((&&&))
import           Control.Lens                            ((&), (.~), (<>~),
                                                          (^.), (^?))
import           Data.Aeson                              as Json
import           Data.ByteString.Lazy                    (ByteString)
import           Data.List                               (sortOn)
import           Data.Map.Strict                         (Map)
import qualified Data.Map.Strict                         as Map
import           Foundation
import           Foundation.Collection
import           Foundation.Compat.ByteString
import           Network.Haskoin.Block
import           Network.Haskoin.Crypto
import           Network.Haskoin.Script
import           Network.Haskoin.Transaction
import           Network.Haskoin.Wallet.Amounts
import           Network.Haskoin.Wallet.ConsolePrinter
import           Network.Haskoin.Wallet.FoundationCompat
import           Network.HTTP.Types.Status
import qualified Network.Wreq                            as HTTP
import           Network.Wreq.Types                      (ResponseChecker)

data BlockchainService = BlockchainService
    { httpBalance     :: [Address] -> IO Satoshi
    , httpUnspent     :: [Address] -> IO [(OutPoint, ScriptOutput, Satoshi)]
    , httpAddressTxs  :: Maybe ([Address] -> IO [AddressTx])
    , httpTxMovements :: Maybe ([Address] -> IO [TxSummary])
    , httpTx          :: TxHash -> IO Tx
    , httpBroadcast   :: Tx -> IO ()
    }

data AddressTx = AddressTx
    { addrTxAddress   :: !Address
    , addrTxTxHash    :: !TxHash
    , addrTxAmount    :: !Integer
    , addrTxHeight    :: Maybe Natural
    , addrTxBlockHash :: Maybe BlockHash
    }
    deriving (Eq, Show)

data TxSummary = TxSummary
    { txSummaryTxHash    :: Maybe TxHash
    , txSummaryTxSize    :: Maybe (CountOf (Element (UArray Word8)))
    , txSummaryOutbound  :: Map Address Satoshi
    , txSummaryNonStd    :: Satoshi
    , txSummaryInbound   :: Map Address (Satoshi, Maybe SoftPath)
    , txSummaryMyInputs  :: Map Address (Satoshi, Maybe SoftPath)
    , txSummaryFee       :: Maybe Satoshi
    , txSummaryHeight    :: Maybe Natural
    , txSummaryBlockHash :: Maybe BlockHash
    } deriving (Eq, Show)

httpJsonGet :: HTTP.Options -> LString -> IO Json.Value
httpJsonGet = httpJsonGen id

httpJsonGetCoerce :: HTTP.Options -> LString -> IO Json.Value
httpJsonGetCoerce = httpJsonGen setJSON
  where
    setJSON r
        | isNothing $ r ^? HTTP.responseHeader "Content-Type" =
            r & HTTP.responseHeaders <>~ [("Content-Type", "application/json")]
        | otherwise = r

httpJsonGen ::
       (HTTP.Response ByteString -> HTTP.Response ByteString)
    -> HTTP.Options
    -> LString
    -> IO Json.Value
httpJsonGen f opts url = do
    r <- HTTP.asValue . f =<< HTTP.getWith (addStatusCheck opts) url
    return $ r ^. HTTP.responseBody

httpBytesGet :: HTTP.Options -> LString -> IO (UArray Word8)
httpBytesGet opts url = do
    r <- HTTP.getWith (addStatusCheck opts) url
    return $ fromByteString $ toStrictBS $ r ^. HTTP.responseBody

mergeAddressTxs :: [AddressTx] -> [TxSummary]
mergeAddressTxs as =
    sortOn txSummaryHeight $ mapMaybe toMvt $ Map.assocs aMap
  where
    aMap :: Map TxHash [AddressTx]
    aMap = Map.fromListWith (<>) $ fmap (addrTxTxHash &&& (: [])) as
    toMvt :: (TxHash, [AddressTx]) -> Maybe TxSummary
    toMvt (tid, atxs) =
        case head <$> nonEmpty atxs of
            Just a ->
                let (os, is) = partition ((< 0) . addrTxAmount) atxs
                in Just TxSummary
                     { txSummaryTxHash = Just tid
                     , txSummaryTxSize = Nothing
                     , txSummaryOutbound = Map.empty
                     , txSummaryNonStd = 0
                     , txSummaryInbound = toAddrMap is
                     , txSummaryMyInputs = toAddrMap os
                     , txSummaryFee = Nothing
                     , txSummaryHeight = addrTxHeight a
                     , txSummaryBlockHash = addrTxBlockHash a
                     }
            _ -> Nothing
    toAddrMap :: [AddressTx] -> Map Address (Satoshi, Maybe SoftPath)
    toAddrMap = Map.map (,Nothing) . Map.fromListWith (+) . fmap toAddrVal
    toAddrVal :: AddressTx -> (Address, Satoshi)
    toAddrVal = addrTxAddress &&& fromIntegral . abs . addrTxAmount

checkStatus :: ResponseChecker
checkStatus _ r
    | statusIsSuccessful status = return ()
    | otherwise =
        consoleError $
        vcat
            [ formatError "Received an HTTP error response:"
            , nest 4 $
              vcat
                  [ formatKey (block 10 "Status:") <> formatError (show code)
                  , formatKey (block 10 "Message:") <>
                    formatStatic
                        (fromMaybe "Could not decode the message" $
                         bsToString message)
                  ]
            ]
  where
    code = r ^. HTTP.responseStatus . HTTP.statusCode
    message = r ^. HTTP.responseStatus . HTTP.statusMessage
    status = mkStatus code message

addStatusCheck :: HTTP.Options -> HTTP.Options
addStatusCheck opts = opts & HTTP.checkResponse .~ Just checkStatus

