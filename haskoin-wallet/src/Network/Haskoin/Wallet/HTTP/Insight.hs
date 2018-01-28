{-# LANGUAGE OverloadedStrings #-}
module Network.Haskoin.Wallet.HTTP.Insight (insight) where

import           Control.Lens                          ((&), (<>~), (^.), (^..),
                                                        (^?))
import qualified Data.Aeson                            as J
import           Data.Aeson.Lens
import           Data.List
import           Data.Maybe
import           Data.Monoid                           ((<>))
import qualified Data.Serialize                        as S
import           Data.String.Conversions               (cs)
import           Data.Word
import           Network.Haskoin.Constants
import           Network.Haskoin.Crypto
import           Network.Haskoin.Script
import           Network.Haskoin.Transaction
import           Network.Haskoin.Util
import           Network.Haskoin.Wallet.ConsolePrinter
import           Network.Haskoin.Wallet.HTTP
import qualified Network.Wreq                          as HTTP

getURL :: String
getURL
    | getNetwork == bitcoinNetwork =
        "https://insight.bitpay.com/api"
    | getNetwork == bitcoinTestnet3Network =
        "https://test-insight.bitpay.com/api"
    | getNetwork == bitcoinCashNetwork =
        "https://bch-insight.bitpay.com/api"
    | getNetwork == bitcoinCashTestNetwork =
        "https://test-bch-insight.bitpay.com/api"
    | otherwise =
        consoleError $
        formatError $
        "insight does not support the network " <> networkName

insight :: BlockchainService
insight =
    BlockchainService
    { httpBalance = getBalance
    , httpUnspent = getUnspent
    , httpTx = getTx
    , httpBroadcast = broadcastTx
    }

getBalance :: [Address] -> IO Word64
getBalance addrs = do
    coins <- getUnspent addrs
    return $ sum $ map lst3 coins

getUnspent :: [Address] -> IO [(OutPoint, ScriptOutput, Word64)]
getUnspent addrs = do
    r <- HTTP.asValue . setJSON =<< HTTP.getWith HTTP.defaults url
    let v = r ^. HTTP.responseBody
        resM = mapM parseCoin $ v ^.. values
    maybe (consoleError $ formatError "Could not parse coin") return resM
  where
    setJSON r
        | isNothing $ r ^? HTTP.responseHeader "Content-Type" =
          r & HTTP.responseHeaders <>~ [("Content-Type", "application/json")]
        | otherwise = r
    url = getURL <> "/addrs/" <> aList <> "/utxo"
    aList = intercalate "," $ map (cs . addrToBase58) addrs
    parseCoin v = do
        tid <- hexToTxHash . cs =<< v ^? key "txid" . _String
        pos <- v ^? key "vout" . _Integral
        val <- v ^? key "satoshis" . _Integral
        scpHex <- v ^? key "scriptPubKey" . _String
        scp <- eitherToMaybe . decodeOutputBS =<< decodeHex (cs scpHex)
        return (OutPoint tid pos, scp, val)

getTx :: TxHash -> IO Tx
getTx tid = do
    r <- HTTP.asValue =<< HTTP.getWith HTTP.defaults url
    let v = r ^. HTTP.responseBody
        txHexM = v ^? key "rawtx" . _String
        txM = eitherToMaybe . S.decode =<< decodeHex . cs =<< txHexM
    maybe (consoleError $ formatError "Could not decode tx") return txM
  where
    url  = getURL <> "/rawtx/" <> cs (txHashToHex tid)

broadcastTx :: Tx -> IO ()
broadcastTx tx = do
    _ <- HTTP.post url val
    return ()
  where
    url = getURL <> "/tx/send"
    val = J.object [ "rawtx" J..= J.String (cs $ encodeHex $ S.encode tx)]

