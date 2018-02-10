{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE NoImplicitPrelude         #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE TupleSections             #-}
module Network.Haskoin.Wallet.HTTP where

import           Control.Arrow                           ((&&&))
import           Control.Lens                            ((&), (.~), (<>~),
                                                          (^.), (^?))
import           Control.Monad                           (mapM)
import           Data.Aeson                              as Json
import           Data.ByteString.Lazy                    (ByteString)
import           Data.List                               (sortOn)
import           Data.Map.Strict                         (Map)
import qualified Data.Map.Strict                         as Map
import           Foundation
import           Foundation.Compat.ByteString
import           Network.Haskoin.Block
import           Network.Haskoin.Crypto
import           Network.Haskoin.Script
import           Network.Haskoin.Transaction
import           Network.Haskoin.Wallet.Amounts
import           Network.Haskoin.Wallet.ConsolePrinter
import           Network.Haskoin.Wallet.FoundationCompat
import           Network.Haskoin.Wallet.TxInformation
import           Network.HTTP.Types.Status
import qualified Network.Wreq                            as HTTP
import           Network.Wreq.Types                      (ResponseChecker)

data Service =
    forall service. (BlockchainService service) =>
    Service service

instance BlockchainService Service where
    httpBalance (Service s) = httpBalance s
    httpUnspent (Service s) = httpUnspent s
    httpAddressTxs (Service s) = httpAddressTxs s
    httpTxInformation (Service s) = httpTxInformation s
    httpTx (Service s) = httpTx s
    httpTxs (Service s) = httpTxs s
    httpBestHeight (Service s) = httpBestHeight s
    httpBroadcast (Service s) = httpBroadcast s

class BlockchainService s where
    httpBalance :: s -> [Address] -> IO Satoshi
    httpUnspent :: s -> [Address] -> IO [(OutPoint, ScriptOutput, Satoshi)]
    httpAddressTxs :: s -> [Address] -> IO [AddressTx]
    httpAddressTxs _ =
        consoleError $ formatError "httpAddressTxs is not defined"
    httpTxInformation :: s -> [Address] -> IO [TxInformation]
    httpTxInformation s = (mergeAddressTxs <$>) . httpAddressTxs s
    httpTx :: s -> TxHash -> IO Tx
    httpTx s tid = do
        res <- httpTxs s [tid]
        case res of
            (tx:_) -> return tx
            _ -> consoleError $ formatError "httpTxs did not return any txs"
    httpTxs :: s -> [TxHash] -> IO [Tx]
    httpTxs s = mapM (httpTx s)
    httpBestHeight :: s -> IO Natural
    httpBroadcast :: s -> Tx -> IO ()

mergeAddressTxs :: [AddressTx] -> [TxInformation]
mergeAddressTxs as =
    sortOn txInformationHeight $ mapMaybe toMvt $ Map.assocs aMap
  where
    aMap :: Map TxHash [AddressTx]
    aMap = Map.fromListWith (<>) $ fmap (addrTxTxHash &&& (: [])) as
    toMvt :: (TxHash, [AddressTx]) -> Maybe TxInformation
    toMvt (tid, atxs) =
        case head <$> nonEmpty atxs of
            Just a ->
                let (os, is) = partition ((< 0) . addrTxAmount) atxs
                in Just
                       TxInformation
                       { txInformationTxHash = Just tid
                       , txInformationTxSize = Nothing
                       , txInformationOutbound = Map.empty
                       , txInformationNonStd = 0
                       , txInformationInbound = toAddrMap is
                       , txInformationMyInputs = toAddrMap os
                       , txInformationFee = Nothing
                       , txInformationHeight = addrTxHeight a
                       , txInformationBlockHash = addrTxBlockHash a
                       }
            _ -> Nothing
    toAddrMap :: [AddressTx] -> Map Address (Satoshi, Maybe SoftPath)
    toAddrMap = Map.map (, Nothing) . Map.fromListWith (+) . fmap toAddrVal
    toAddrVal :: AddressTx -> (Address, Satoshi)
    toAddrVal = addrTxAddress &&& fromIntegral . abs . addrTxAmount

data AddressTx = AddressTx
    { addrTxAddress   :: !Address
    , addrTxTxHash    :: !TxHash
    , addrTxAmount    :: !Integer
    , addrTxHeight    :: Maybe Natural
    , addrTxBlockHash :: Maybe BlockHash
    }
    deriving (Eq, Show)

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

