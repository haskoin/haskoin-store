{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Network.Haskoin.Wallet.HTTP.BlockchainInfo
( blockchainInfoService
) where

import           Control.Lens                            ((&), (.~), (^.),
                                                          (^..), (^?))
import           Data.Aeson.Lens
import           Data.List                               (sum)
import           Foundation
import           Foundation.Collection
import           Foundation.Compat.ByteString
import           Foundation.Compat.Text
import           Network.Haskoin.Constants
import           Network.Haskoin.Crypto                  hiding (addrToBase58)
import           Network.Haskoin.Script
import           Network.Haskoin.Transaction             hiding (txHashToHex)
import           Network.Haskoin.Util                    (eitherToMaybe)
import           Network.Haskoin.Wallet.Amounts
import           Network.Haskoin.Wallet.ConsolePrinter
import           Network.Haskoin.Wallet.FoundationCompat
import           Network.Haskoin.Wallet.HTTP
import qualified Network.Wreq                            as HTTP

getURL :: LString
getURL
    | getNetwork == bitcoinNetwork = "https://blockchain.info"
    | getNetwork == testnet3Network = "https://testnet.blockchain.info"
    | otherwise =
        consoleError $
        formatError $
        "blockchain.info does not support the network " <>
        fromLString networkName

blockchainInfoService :: BlockchainService
blockchainInfoService =
    BlockchainService
    { httpBalance = getBalance
    , httpUnspent = getUnspent
    , httpTx = getTx
    , httpBroadcast = broadcastTx
    , httpAddressTxs = consoleError $ formatError "Not implemented"
    }

getBalance :: [Address] -> IO Satoshi
getBalance addrs = do
    r <- HTTP.asValue =<< HTTP.getWith opts url
    let v = r ^. HTTP.responseBody
    return $ fromIntegral $ sum $ v ^.. members . key "final_balance" . _Integer
  where
    url = getURL <> "/balance"
    opts = options & HTTP.param "active" .~ [toText aList]
    aList = intercalate "|" $ addrToBase58 <$> addrs

getUnspent :: [Address] -> IO [(OutPoint, ScriptOutput, Satoshi)]
getUnspent addrs = do
    r <- HTTP.asValue =<< HTTP.getWith opts url
    let v = r ^. HTTP.responseBody
        resM = mapM parseCoin $ v ^.. key "unspent_outputs" . values
    maybe (consoleError $ formatError "Could not parse coin") return resM
  where
    url = getURL <> "/unspent"
    opts =
        options & HTTP.param "active" .~ [toText aList] &
        HTTP.param "confirmations" .~
        ["1"]
    aList = intercalate "|" $ addrToBase58 <$> addrs
    parseCoin v = do
        tid <- hexToTxHash' . fromText =<< v ^? key "tx_hash" . _String
        pos <- v ^? key "tx_output_n" . _Integral
        val <- v ^? key "value" . _Integral
        scpHex <- v ^? key "script" . _String
        scp <- eitherToMaybe . withBytes decodeOutputBS =<< decodeHexText scpHex
        return (OutPoint tid pos, scp, val)

getTx :: TxHash -> IO Tx
getTx tid = do
    r <- HTTP.getWith opts url
    let bytes = fromByteString . toStrictBS $ r ^. HTTP.responseBody
    maybe err return $ decodeBytes =<< decodeHex bytes
  where
    url = getURL <> "/rawtx/" <> toLString (txHashToHex tid)
    opts = options & HTTP.param "format" .~ ["hex"]
    err = consoleError $ formatError "Could not decode tx"

broadcastTx :: Tx -> IO ()
broadcastTx tx = do
    _ <- HTTP.postWith options url $ HTTP.partBS "tx" dat
    return ()
  where
    url = getURL <> "/pushtx"
    dat = toByteString $ encodeHex $ encodeBytes tx

hexToTxHash' :: String -> Maybe TxHash
hexToTxHash' = decodeHexStr >=> decodeBytes >=> return . TxHash

