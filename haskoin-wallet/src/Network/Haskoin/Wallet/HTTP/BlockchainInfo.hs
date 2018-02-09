{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
module Network.Haskoin.Wallet.HTTP.BlockchainInfo
( blockchainInfoService
) where

import           Control.Lens                            ((&), (.~), (^..),
                                                          (^?))
import           Control.Monad                           (guard)
import           Data.Aeson.Lens
import           Data.List                               (sum)
import qualified Data.Map.Strict                         as Map
import           Foundation
import           Foundation.Collection
import           Foundation.Compat.ByteString
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
    , httpAddressTxs = Nothing
    , httpTxMovements = Just getTxMovements
    , httpTx = getTx
    , httpBroadcast = broadcastTx
    }

getBalance :: [Address] -> IO Satoshi
getBalance addrs = do
    v <- httpJsonGet opts url
    return $ fromIntegral $ sum $ v ^.. members . key "final_balance" . _Integer
  where
    url = getURL <> "/balance"
    opts = HTTP.defaults & HTTP.param "active" .~ [toText aList]
    aList = intercalate "|" $ addrToBase58 <$> addrs

getUnspent :: [Address] -> IO [(OutPoint, ScriptOutput, Satoshi)]
getUnspent addrs = do
    v <- httpJsonGet opts url
    let resM = mapM parseCoin $ v ^.. key "unspent_outputs" . values
    maybe (consoleError $ formatError "Could not parse coin") return resM
  where
    url = getURL <> "/unspent"
    opts =
        HTTP.defaults & HTTP.param "active" .~ [toText aList] &
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

getTxMovements :: [Address] -> IO [TxSummary]
getTxMovements addrs = do
    v <- httpJsonGet opts url
    let resM = mapM parseTxMovement $ v ^.. key "txs" . values
    maybe (consoleError $ formatError "Could not parse tx movement") return resM
  where
    url = getURL <> "/multiaddr"
    opts = HTTP.defaults & HTTP.param "active" .~ [toText aList]
    aList = intercalate "|" $ addrToBase58 <$> addrs
    parseTxMovement v = do
        tid <- hexToTxHash . fromText =<< v ^? key "hash" . _String
        size <- v ^? key "size" . _Integer
        fee <- v ^? key "fee" . _Integer
        let heightM = fromIntegral <$> v ^? key "block_height" . _Integer
            is =
                Map.fromList $ mapMaybe go $ v ^.. key "inputs" . values .
                key "prev_out"
            os = Map.fromList $ mapMaybe go $ v ^.. key "out" . values
        return
            TxSummary
            { txSummaryTxHash = Just tid
            , txSummaryTxSize = Just $ fromIntegral size
            , txSummaryOutbound = Map.empty
            , txSummaryNonStd = 0
            , txSummaryInbound = Map.map (,Nothing) os
            , txSummaryMyInputs = Map.map (,Nothing) is
            , txSummaryFee = Just $ fromIntegral fee
            , txSummaryHeight = heightM
            , txSummaryBlockHash = Nothing
            }
    go v = do
        addr <- base58ToAddr . fromText =<< v ^? key "addr" . _String
        guard $ addr `elem` addrs
        amnt <- fromIntegral <$> v ^? key "value" . _Integer
        return (addr, amnt)

getTx :: TxHash -> IO Tx
getTx tid = do
    bytes <- httpBytesGet opts url
    maybe err return $ decodeBytes =<< decodeHex bytes
  where
    url = getURL <> "/rawtx/" <> toLString (txHashToHex tid)
    opts = HTTP.defaults & HTTP.param "format" .~ ["hex"]
    err = consoleError $ formatError "Could not decode tx"

broadcastTx :: Tx -> IO ()
broadcastTx tx = do
    _ <- HTTP.postWith (addStatusCheck HTTP.defaults) url $ HTTP.partBS "tx" dat
    return ()
  where
    url = getURL <> "/pushtx"
    dat = toByteString $ encodeHex $ encodeBytes tx

hexToTxHash' :: String -> Maybe TxHash
hexToTxHash' = decodeHexStr >=> decodeBytes >=> return . TxHash

