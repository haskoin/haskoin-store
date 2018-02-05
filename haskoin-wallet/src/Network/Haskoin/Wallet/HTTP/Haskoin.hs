{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Network.Haskoin.Wallet.HTTP.Haskoin (haskoinService) where

import           Control.Lens                            ((&), (.~), (^.),
                                                          (^..), (^?))
import           Control.Monad                           (guard)
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
    | getNetwork == testnet3Network = "https://api.haskoin.com/testnet3"
    | getNetwork == cashTestNetwork = "https://api.haskoin.com/cashtest"
    | getNetwork == bitcoinCashNetwork = "https://api.haskoin.com/bitcoincash"
    | otherwise =
        consoleError $
        formatError $
        "Haskoin does not support the network " <> fromLString networkName

haskoinService :: BlockchainService
haskoinService =
    BlockchainService
    { httpBalance = getBalance
    , httpUnspent = getUnspent
    , httpAddressTxs = getAddressTxs
    , httpTx = getTx
    , httpBroadcast = broadcastTx
    }

getBalance :: [Address] -> IO Satoshi
getBalance addrs = do
    r <- HTTP.asValue =<< HTTP.getWith opts url
    let v = r ^. HTTP.responseBody
    return $ fromIntegral $ sum $ v ^.. values . key "confirmed" . _Integer
  where
    url = getURL <> "/address/balances"
    opts = options & HTTP.param "addresses" .~ [toText aList]
    aList = intercalate "," $ addrToBase58 <$> addrs

getUnspent :: [Address] -> IO [(OutPoint, ScriptOutput, Satoshi)]
getUnspent addrs = do
    r <- HTTP.asValue =<< HTTP.getWith opts url
    let v = r ^. HTTP.responseBody
        resM = mapM parseCoin $ v ^.. values
    maybe (consoleError $ formatError "Could not parse coin") return resM
  where
    url = getURL <> "/address/unspent"
    opts = options & HTTP.param "addresses" .~ [toText aList]
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
    r <- HTTP.asValue =<< HTTP.getWith opts url
    let v = r ^. HTTP.responseBody
        resM = mapM parseAddrTx $ v ^.. values
    maybe (consoleError $ formatError "Could not parse addrTx") return resM
  where
    url = getURL <> "/address/transactions"
    opts = options & HTTP.param "addresses" .~ [toText aList]
    aList = intercalate "," $ addrToBase58 <$> addrs
    parseAddrTx v = do
        tid <- hexToTxHash . fromText =<< v ^? key "txid" . _String
        addrB58 <- v ^? key "address" . _String
        addr <- base58ToAddr $ fromText addrB58
        height <- v ^? key "height" . _Integer
        amnt <- v ^? key "amount" . _Integer
        guard $ height >= 0
        return
            AddressTx
            { addrTxAddress = addr
            , addrTxTxHash = tid
            , addrTxAmount = amnt
            , addrTxHeight = fromIntegral $ abs height
            }

getTx :: TxHash -> IO Tx
getTx tid = do
    r <- HTTP.asValue =<< HTTP.getWith options url
    let v = r ^. HTTP.responseBody
        s = fromMaybe errHex $ v ^? key "hex" . _String
    maybe errTx return $ decodeBytes =<< decodeHexText s
  where
    url = getURL <> "/transaction/" <> toLString (txHashToHex tid)
    errHex =
        consoleError $
        formatError "Invalid JSON response. Could not find the \"hex\" key"
    errTx =
        consoleError $
        formatError "Invalid \"hex\" value. Could not decode a transaction."

broadcastTx :: Tx -> IO ()
broadcastTx tx = do
    _ <- HTTP.postWith options url val
    return ()
  where
    url = getURL <> "/transaction"
    val =
        J.object ["transaction" J..= J.String (encodeHexText $ encodeBytes tx)]
