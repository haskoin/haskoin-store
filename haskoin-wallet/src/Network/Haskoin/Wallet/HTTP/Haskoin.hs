{-# LANGUAGE OverloadedStrings #-}
module Network.Haskoin.Wallet.HTTP.Haskoin (haskoinService) where

import           Control.Lens                          ((&), (.~), (^.), (^..),
                                                        (^?))
import qualified Data.Aeson                            as J
import           Data.Aeson.Lens
import           Data.List
import           Data.Maybe
import           Data.Monoid                           ((<>))
import qualified Data.Serialize                        as S
import           Data.String.Conversions               (cs)
import           Data.Word
import           Network.Haskoin.Block
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
    | getNetwork == testnet3Network = "http://nuc.haskoin.com:7053"
    | otherwise = consoleError $ formatError $
        "Haskoin does not support the network " <> networkName

haskoinService :: BlockchainService
haskoinService =
    BlockchainService
    { httpBalance = getBalance
    , httpUnspent = getUnspent
    , httpAddressTxs = getAddressTxs
    , httpTx = getTx
    , httpBroadcast = broadcastTx
    }

getBalance :: [Address] -> IO Word64
getBalance addrs = do
    r <- HTTP.asValue =<< HTTP.getWith opts url
    let v = r ^. HTTP.responseBody
    return $ fromIntegral $ sum $ v ^.. values . key "confirmed" . _Integer
  where
    url = getURL <> "/address/balances"
    opts = options & HTTP.param "addresses" .~ [cs aList]
    aList = intercalate "," $ map (cs . addrToBase58) addrs

getUnspent :: [Address] -> IO [(OutPoint, ScriptOutput, Word64)]
getUnspent addrs = do
    r <- HTTP.asValue =<< HTTP.getWith opts url
    let v = r ^. HTTP.responseBody
        resM = mapM parseCoin $ v ^.. values
    maybe (consoleError $ formatError "Could not parse coin") return resM
  where
    url = getURL <> "/address/unspent"
    opts = options & HTTP.param "addresses" .~ [cs aList]
    aList = intercalate "," $ map (cs . addrToBase58) addrs
    parseCoin v = do
        tid <- hexToTxHash . cs =<< v ^? key "txid" . _String
        pos <- v ^? key "vout" . _Integral
        val <- v ^? key "value" . _Integral
        scpHex <- v ^? key "pkscript" . _String
        scp <- eitherToMaybe . decodeOutputBS =<< decodeHex (cs scpHex)
        return (OutPoint tid pos, scp, val)

getAddressTxs :: [Address] -> IO [AddressTx]
getAddressTxs addrs = do
    r <- HTTP.asValue =<< HTTP.getWith opts url
    let v = r ^. HTTP.responseBody
        resM = mapM parseAddrTx $ v ^.. values
    maybe (consoleError $ formatError "Could not parse addrTx") return resM
  where
    url = getURL <> "/address/transactions"
    opts = options & HTTP.param "addresses" .~ [cs aList]
    aList = intercalate "," $ map (cs . addrToBase58) addrs
    parseAddrTx v = do
        tid <- hexToTxHash . cs =<< v ^? key "txid" . _String
        bid <- hexToBlockHash . cs =<< v ^? key "block" . _String
        addrB58 <- v ^? key "address" . _String
        addr <- base58ToAddr $ cs addrB58
        height <- v ^? key "height" . _Integer
        amnt <- v ^? key "amount" . _Integer
        return
            AddressTx
            { addrTxAddress = addr
            , addrTxTxHash = tid
            , addrTxBlock = bid
            , addrTxAmount = amnt
            , addrTxHeight = height
            }

getTx :: TxHash -> IO Tx
getTx tid = do
    r <- HTTP.asValue =<< HTTP.getWith options url
    let v = r ^. HTTP.responseBody
        s = fromMaybe errHex $ v ^? key "hex" . _String
    maybe errTx return $ eitherToMaybe . S.decode =<< decodeHex (cs s)
  where
    url  = getURL <> "/transaction/" <> cs (txHashToHex tid)
    errHex =
        consoleError $
        formatError
            "Invalid JSON response. Could not find the \"hex\" key"
    errTx =
        consoleError $
        formatError
            "Invalid \"hex\" value. Could not decode a transaction."

broadcastTx :: Tx -> IO ()
broadcastTx tx = do
    _ <- HTTP.postWith options url val
    return ()
  where
    url = getURL <> "/transaction"
    val = J.object [ "transaction" J..= J.String (cs $ encodeHex $ S.encode tx)]

