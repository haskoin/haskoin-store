{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
module Network.Haskoin.Wallet.HTTP.Insight
( InsightService(..)
) where

import           Control.Lens                            ((^..), (^?))
import           Control.Monad                           (guard)
import qualified Data.Aeson                              as Json
import           Data.Aeson.Lens
import           Data.List                               (sum)
import qualified Data.Map.Strict                         as Map
import           Foundation
import           Foundation.Collection
import           Foundation.Numerical
import           Foundation.Compat.Text
import           Network.Haskoin.Constants
import           Network.Haskoin.Crypto                  hiding (addrToBase58,
                                                          base58ToAddr)
import           Network.Haskoin.Script
import           Network.Haskoin.Transaction             hiding (hexToTxHash,
                                                          txHashToHex)
import           Network.Haskoin.Util
import           Network.Haskoin.Wallet.Amounts
import           Network.Haskoin.Wallet.ConsolePrinter
import           Network.Haskoin.Wallet.FoundationCompat
import           Network.Haskoin.Wallet.HTTP
import           Network.Haskoin.Wallet.TxInformation
import qualified Network.Wreq                            as HTTP

data InsightService = InsightService

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

instance BlockchainService InsightService where
    httpBalance _ = getBalance
    httpUnspent _ = getUnspent
    httpTxInformation _ = getTxInformation
    httpTx _ = getTx
    httpBestHeight _ = getBestHeight
    httpBroadcast _ = broadcastTx

getBalance :: [Address] -> IO Satoshi
getBalance addrs = do
    coins <- getUnspent addrs
    return $ sum $ lst3 <$> coins

getUnspent :: [Address] -> IO [(OutPoint, ScriptOutput, Satoshi)]
getUnspent addrs = do
    v <- httpJsonGetCoerce HTTP.defaults url
    let resM = mapM parseCoin $ v ^.. values
    maybe (consoleError $ formatError "Could not parse coin") return resM
  where
    url = getURL <> "/addrs/" <> toLString aList <> "/utxo"
    aList = intercalate "," $ addrToBase58 <$> addrs
    parseCoin v = do
        tid <- hexToTxHash . fromText =<< v ^? key "txid" . _String
        pos <- v ^? key "vout" . _Integral
        val <- v ^? key "satoshis" . _Integral
        scpHex <- v ^? key "scriptPubKey" . _String
        scp <- eitherToMaybe . withBytes decodeOutputBS =<< decodeHexText scpHex
        return (OutPoint tid pos, scp, val)

getTxInformation :: [Address] -> IO [TxInformation]
getTxInformation addrs = do
    v <- httpJsonGet HTTP.defaults url
    let resM = mapM parseTxMovement $ v ^.. key "items" . values
    maybe (consoleError $ formatError "Could not parse addrTx") return resM
  where
    url = getURL <> "/addrs/" <> toLString aList <> "/txs"
    aList = intercalate "," $ addrToBase58 <$> addrs
    parseTxMovement v = do
        tid <- hexToTxHash . fromText =<< v ^? key "txid" . _String
        bytes <- fromIntegral <$> v ^? key "size" . _Integer
        feesDouble <- v ^? key "fees" . _Double
        let feeSat = roundDown (feesDouble * 100000000) :: Satoshi
            heightM = fromIntegral <$> v ^? key "blockheight" . _Integer
            bidM = hexToBlockHash . fromText =<< v ^? key "blockhash" . _String
            is =
                Map.fromListWith (+) $ mapMaybe parseVin $ v ^.. key "vin" .
                values
            os =
                Map.fromListWith (+) $ mapMaybe parseVout $ v ^.. key "vout" .
                values
        return
            TxInformation
            { txInformationTxHash = Just tid
            , txInformationTxSize = Just bytes
            , txInformationOutbound = Map.empty
            , txInformationNonStd = 0
            , txInformationInbound = Map.map (, Nothing) os
            , txInformationMyInputs = Map.map (, Nothing) is
            , txInformationFee = Just feeSat
            , txInformationHeight = heightM
            , txInformationBlockHash = bidM
            }
    parseVin v = do
        addr <- base58ToAddr . fromText =<< v ^? key "addr" . _String
        guard $ addr `elem` addrs
        amnt <- fromIntegral <$> v ^? key "valueSat" . _Integer
        return (addr, amnt)
    parseVout v = do
        let xs = v ^.. key "scriptPubKey" . key "addresses" . values . _String
        addr <- base58ToAddr . fromText . head =<< nonEmpty xs
        guard $ addr `elem` addrs
        amntStr <- fromText <$> v ^? key "value" . _String
        amnt <- readAmount UnitBitcoin amntStr
        return (addr, amnt)

getTx :: TxHash -> IO Tx
getTx tid = do
    v <- httpJsonGet HTTP.defaults url
    let txHexM = v ^? key "rawtx" . _String
    maybe err return $ decodeBytes =<< decodeHexText =<< txHexM
  where
    url = getURL <> "/rawtx/" <> toLString (txHashToHex tid)
    err = consoleError $ formatError "Could not decode tx"

broadcastTx :: Tx -> IO ()
broadcastTx tx = do
    _ <- HTTP.postWith (addStatusCheck HTTP.defaults) url val
    return ()
  where
    url = getURL <> "/tx/send"
    val =
        Json.object
            ["rawtx" Json..= Json.String (encodeHexText $ encodeBytes tx)]

getBestHeight :: IO Natural
getBestHeight = do
    v <- httpJsonGet HTTP.defaults url
    let resM = fromIntegral <$> v ^? key "info" . key "blocks" . _Integer
    maybe err return resM
  where
    url = getURL <> "/status"
    err = consoleError $ formatError "Could not get the best block height"
