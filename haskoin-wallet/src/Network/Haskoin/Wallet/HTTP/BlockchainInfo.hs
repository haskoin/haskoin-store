{-# LANGUAGE OverloadedStrings #-}
module Network.Haskoin.Wallet.HTTP.BlockchainInfo (blockchainInfo) where

import           Control.Lens                          ((&), (.~), (^.), (^..),
                                                        (^?))
import           Data.Aeson.Lens
import qualified Data.ByteString                       as BS
import           Data.List
import           Data.Monoid                           ((<>))
import qualified Data.Serialize                        as S
import           Data.String.Conversions               (cs)
import           Data.Word
import           Network.Haskoin.Crypto
import           Network.Haskoin.Script
import           Network.Haskoin.Transaction
import           Network.Haskoin.Util
import           Network.Haskoin.Wallet.ConsolePrinter
import           Network.Haskoin.Wallet.HTTP
import qualified Network.Wreq                          as HTTP

toURL :: HTTPNet -> String
toURL HTTPProdnet = "https://blockchain.info"
toURL HTTPTestnet = "https://testnet.blockchain.info"

blockchainInfo :: BlockchainService
blockchainInfo =
    BlockchainService
    { httpBalance = getBalance
    , httpUnspent = getUnspent
    , httpTx = getTx
    , httpBroadcast = broadcastTx
    }

getBalance :: HTTPNet -> [Address] -> IO Word64
getBalance net addrs = do
    r <- HTTP.asValue =<< HTTP.getWith opts url
    let v = r ^. HTTP.responseBody
    return $ fromIntegral $ sum $ v ^.. members . key "final_balance" . _Integer
  where
    url = toURL net <> "/balance"
    opts = HTTP.defaults & HTTP.param "active" .~ [cs aList]
    aList = intercalate "|" $ map (cs . addrToBase58) addrs

getUnspent :: HTTPNet -> [Address] -> IO [(OutPoint, ScriptOutput, Word64)]
getUnspent net addrs = do
    r <- HTTP.asValue =<< HTTP.getWith opts url
    let v = r ^. HTTP.responseBody
        resM = mapM parseCoin $ v ^.. key "unspent_outputs" . values
    maybe (consoleError $ formatError "Could not parse coin") return resM
  where
    url = toURL net <> "/unspent"
    opts =
        HTTP.defaults & HTTP.param "active" .~ [cs aList] &
        HTTP.param "confirmations" .~
        ["1"]
    aList = intercalate "|" $ map (cs . addrToBase58) addrs
    parseCoin v = do
        tid <- hexToTxHash' . cs =<< v ^? key "tx_hash" . _String
        pos <- v ^? key "tx_output_n" . _Integral
        val <- v ^? key "value" . _Integral
        scpHex <- v ^? key "script" . _String
        scp <- eitherToMaybe . decodeOutputBS =<< decodeHex (cs scpHex)
        return (OutPoint tid pos, scp, val)

getTx :: HTTPNet -> TxHash -> IO Tx
getTx net tid = do
    r <- HTTP.getWith opts url
    let bsM = decodeHex . cs $ r ^. HTTP.responseBody
    maybe (consoleError $ formatError "Could not decode tx") return $
        eitherToMaybe . S.decode =<< bsM
  where
    url  = toURL net <> "/rawtx/" <> cs (txHashToHex tid)
    opts = HTTP.defaults & HTTP.param "format" .~ ["hex"]

broadcastTx :: HTTPNet -> Tx -> IO ()
broadcastTx net tx = do
    _ <- HTTP.post url $ HTTP.partBS "tx" dat
    return ()
  where
    url = toURL net <> "/pushtx"
    dat = encodeHex $ S.encode tx

hexToTxHash' :: BS.ByteString -> Maybe TxHash
hexToTxHash' hex = do
    bs <- decodeHex hex
    h <- either (const Nothing) Just (S.decode bs)
    return $ TxHash h
