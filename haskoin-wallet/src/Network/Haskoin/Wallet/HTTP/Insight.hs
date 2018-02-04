{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Network.Haskoin.Wallet.HTTP.Insight (insightService) where

import           Control.Lens                            ((&), (<>~), (^.),
                                                          (^..), (^?))
import qualified Data.Aeson                              as Json
import           Data.Aeson.Lens
import           Data.List                               (sum)
import           Foundation
import           Foundation.Compat.Text
import           Foundation.Collection
import           Network.Haskoin.Constants
import           Network.Haskoin.Crypto                  hiding (addrToBase58)
import           Network.Haskoin.Script
import           Network.Haskoin.Transaction             hiding (hexToTxHash,
                                                          txHashToHex)
import           Network.Haskoin.Util
import           Network.Haskoin.Wallet.Amounts
import           Network.Haskoin.Wallet.ConsolePrinter
import           Network.Haskoin.Wallet.FoundationCompat
import           Network.Haskoin.Wallet.HTTP
import qualified Network.Wreq                            as HTTP

getURL :: LString
getURL
    | getNetwork == bitcoinNetwork =
        "https://btc.blockdozer.com/insight-api/"
    | getNetwork == testnet3Network =
        "https://tbtc.blockdozer.com/insight-api/"
    | getNetwork == bitcoinCashNetwork =
        "https://bch.blockdozer.com/insight-api/"
    | getNetwork == cashTestNetwork =
        "https://tbch.blockdozer.com/insight-api/"
    | otherwise =
        consoleError $
        formatError $
        "insight does not support the network " <> fromLString networkName

insightService :: BlockchainService
insightService =
    BlockchainService
    { httpBalance = getBalance
    , httpUnspent = getUnspent
    , httpTx = getTx
    , httpBroadcast = broadcastTx
    , httpAddressTxs = consoleError $ formatError "Not implemented"
    }

getBalance :: [Address] -> IO Satoshi
getBalance addrs = do
    coins <- getUnspent addrs
    return $ sum $ lst3 <$> coins

getUnspent :: [Address] -> IO [(OutPoint, ScriptOutput, Satoshi)]
getUnspent addrs = do
    r <- HTTP.asValue . setJSON =<< HTTP.getWith options url
    let v = r ^. HTTP.responseBody
        resM = mapM parseCoin $ v ^.. values
    maybe (consoleError $ formatError "Could not parse coin") return resM
  where
    setJSON r
        | isNothing $ r ^? HTTP.responseHeader "Content-Type" =
            r & HTTP.responseHeaders <>~ [("Content-Type", "application/json")]
        | otherwise = r
    url = getURL <> "/addrs/" <> toLString aList <> "/utxo"
    aList = intercalate "," $ addrToBase58 <$> addrs
    parseCoin v = do
        tid <- hexToTxHash . fromText =<< v ^? key "txid" . _String
        pos <- v ^? key "vout" . _Integral
        val <- v ^? key "satoshis" . _Integral
        scpHex <- v ^? key "scriptPubKey" . _String
        scp <- eitherToMaybe . withBytes decodeOutputBS =<< decodeHexText scpHex
        return (OutPoint tid pos, scp, val)

getTx :: TxHash -> IO Tx
getTx tid = do
    r <- HTTP.asValue =<< HTTP.getWith options url
    let v = r ^. HTTP.responseBody
        txHexM = v ^? key "rawtx" . _String
    maybe err return $ decodeBytes =<< decodeHexText =<< txHexM
  where
    url = getURL <> "/rawtx/" <> toLString (txHashToHex tid)
    err = consoleError $ formatError "Could not decode tx"

broadcastTx :: Tx -> IO ()
broadcastTx tx = do
    _ <- HTTP.postWith options url val
    return ()
  where
    url = getURL <> "/tx/send"
    val =
        Json.object
            ["rawtx" Json..= Json.String (encodeHexText $ encodeBytes tx)]
