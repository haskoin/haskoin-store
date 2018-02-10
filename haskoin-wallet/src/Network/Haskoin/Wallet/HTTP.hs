{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE NoImplicitPrelude         #-}
{-# LANGUAGE OverloadedStrings         #-}
module Network.Haskoin.Wallet.HTTP where

import           Control.Lens                            ((&), (.~), (<>~),
                                                          (^.), (^?))
import           Control.Monad                           (mapM)
import           Data.Aeson                              as Json
import           Data.ByteString.Lazy                    (ByteString)
import           Foundation
import           Foundation.Compat.ByteString
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
    httpTxInformation (Service s) = httpTxInformation s
    httpTx (Service s) = httpTx s
    httpTxs (Service s) = httpTxs s
    httpBestHeight (Service s) = httpBestHeight s
    httpBroadcast (Service s) = httpBroadcast s

class BlockchainService s where
    httpBalance :: s -> [Address] -> IO Satoshi
    httpUnspent :: s -> [Address] -> IO [(OutPoint, ScriptOutput, Satoshi)]
    httpTxInformation :: s -> [Address] -> IO [TxInformation]
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

