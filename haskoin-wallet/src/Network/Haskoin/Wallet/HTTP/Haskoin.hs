{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Network.Haskoin.Wallet.HTTP.Haskoin (haskoinService) where

import           Control.Lens                            ((&), (.~), (^..),
                                                          (^?))
import qualified Data.Aeson                              as J
import           Data.Aeson.Lens
import           Data.List                               (sum)
import           Foundation
import           Foundation.Collection
import           Foundation.Compat.Text
import           Network.Haskoin.Constants
import           Network.Haskoin.Crypto                  hiding (addrToBase58,
                                                          base58ToAddr)
import           Network.Haskoin.Script
import           Network.Haskoin.Transaction             hiding (hexToTxHash,
                                                          txHashToHex)
import           Network.Haskoin.Util                    (eitherToMaybe)
import           Network.Haskoin.Wallet.Amounts
import           Network.Haskoin.Wallet.ConsolePrinter
import           Network.Haskoin.Wallet.FoundationCompat
import           Network.Haskoin.Wallet.HTTP
import qualified Network.Wreq                            as HTTP

getURL :: LString
getURL
    | getNetwork == testnet3Network = "https://testnet3.haskoin.com/api"
    | getNetwork == cashTestNetwork = "https://cashtest.haskoin.com/api"
    | getNetwork == bitcoinCashNetwork = "https://bitcoincash.haskoin.com/api"
    | otherwise =
        consoleError $
        formatError $
        "Haskoin does not support the network " <> fromLString networkName

haskoinService :: BlockchainService
haskoinService =
    BlockchainService
    { httpBalance = getBalance
    , httpUnspent = getUnspent
    , httpAddressTxs = Just getAddressTxs
    , httpTxMovements = Nothing
    , httpTx = getTx
    , httpBroadcast = broadcastTx
    }

getBalance :: [Address] -> IO Satoshi
getBalance addrs = do
    v <- httpJsonGet opts url
    return $ fromIntegral $ sum $ v ^.. values . key "confirmed" . _Integer
  where
    url = getURL <> "/address/balances"
    opts = HTTP.defaults & HTTP.param "addresses" .~ [toText aList]
    aList = intercalate "," $ addrToBase58 <$> addrs

getUnspent :: [Address] -> IO [(OutPoint, ScriptOutput, Satoshi)]
getUnspent addrs = do
    v <- httpJsonGet opts url
    let resM = mapM parseCoin $ v ^.. values
    maybe (consoleError $ formatError "Could not parse coin") return resM
  where
    url = getURL <> "/address/unspent"
    opts = HTTP.defaults & HTTP.param "addresses" .~ [toText aList]
    aList = intercalate "," $ addrToBase58 <$> addrs
    parseCoin v = do
        tid <- hexToTxHash . fromText =<< v ^? key "txid" . _String
        pos <- v ^? key "vout" . _Integral
        val <- v ^? key "value" . _Integral
        scpHex <- v ^? key "pkscript" . _String
        scp <- eitherToMaybe . withBytes decodeOutputBS =<< decodeHexText scpHex
        return (OutPoint tid pos, scp, val)

getAddressTxs :: [Address] -> IO [AddressTx]
getAddressTxs addrs = do
    v <- httpJsonGet opts url
    let resM = mapM parseAddrTx $ v ^.. values
    maybe (consoleError $ formatError "Could not parse addrTx") return resM
  where
    url = getURL <> "/address/transactions"
    opts = HTTP.defaults & HTTP.param "addresses" .~ [toText aList]
    aList = intercalate "," $ addrToBase58 <$> addrs
    parseAddrTx v = do
        tid <- hexToTxHash . fromText =<< v ^? key "txid" . _String
        addrB58 <- v ^? key "address" . _String
        addr <- base58ToAddr $ fromText addrB58
        amnt <- v ^? key "amount" . _Integer
        let heightM = fromIntegral <$> v ^? key "height" . _Integer
            blockM = hexToBlockHash . fromText =<< v ^? key "block" . _String
        return
            AddressTx
            { addrTxAddress = addr
            , addrTxTxHash = tid
            , addrTxAmount = amnt
            , addrTxHeight = heightM
            , addrTxBlockHash = blockM
            }

getTx :: TxHash -> IO Tx
getTx tid = do
    v <- httpJsonGet HTTP.defaults url
    let resM = v ^? key "hex" . _String
    maybe err return $ decodeBytes =<< decodeHexText =<< resM
  where
    url = getURL <> "/transaction/" <> toLString (txHashToHex tid)
    err = consoleError $ formatError "Could not decode the transaction."

broadcastTx :: Tx -> IO ()
broadcastTx tx = do
    _ <- HTTP.postWith (addStatusCheck HTTP.defaults) url val
    return ()
  where
    url = getURL <> "/transaction"
    val =
        J.object ["transaction" J..= J.String (encodeHexText $ encodeBytes tx)]
