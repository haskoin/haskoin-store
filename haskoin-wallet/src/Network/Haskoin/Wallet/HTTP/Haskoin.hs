{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}
module Network.Haskoin.Wallet.HTTP.Haskoin
( HaskoinService(..)
, AddressTx(..)
, mergeAddressTxs
) where

import           Control.Arrow                           ((&&&))
import           Control.Lens                            ((&), (.~), (^..),
                                                          (^?))
import qualified Data.Aeson                              as J
import           Data.Aeson.Lens
import           Data.List                               (nub, sortOn, sum)
import           Data.Map                                (Map)
import qualified Data.Map                                as Map
import           Foundation
import           Foundation.Collection
import           Foundation.Compat.Text
import           Network.Haskoin.Block                   hiding (hexToBlockHash)
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
import           Network.Haskoin.Wallet.TxInformation
import qualified Network.Wreq                            as HTTP

data HaskoinService = HaskoinService

data AddressTx = AddressTx
    { addrTxAddress   :: !Address
    , addrTxTxHash    :: !TxHash
    , addrTxAmount    :: !Integer
    , addrTxHeight    :: Maybe Natural
    , addrTxBlockHash :: Maybe BlockHash
    }
    deriving (Eq, Show)

getURL :: LString
getURL
    | getNetwork == testnet3Network = "https://testnet3.haskoin.com/api"
    | getNetwork == cashTestNetwork = "https://cashtest.haskoin.com/api"
    | getNetwork == bitcoinCashNetwork = "https://bitcoincash.haskoin.com/api"
    | otherwise =
        consoleError $
        formatError $
        "Haskoin does not support the network " <> fromLString networkName

instance BlockchainService HaskoinService where
    httpBalance _ = getBalance
    httpUnspent _ = getUnspent
    httpTxInformation _ = getTxInformation
    httpTxs _ tids = (fst <$>) <$> getTxs tids
    httpBroadcast _ = broadcastTx
    httpBestHeight _ = getBestHeight

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

getTxInformation :: [Address] -> IO [TxInformation]
getTxInformation addrs = do
    txInfs <- mergeAddressTxs <$> getAddressTxs addrs
    let tids = nub $ mapMaybe txInformationTxHash txInfs
    txs <- getTxs tids
    return $ fmap (mergeWith txs) txInfs
  where
    findTx :: [(Tx, Natural)] -> TxInformation -> Maybe (Tx, Natural)
    findTx txs txInf = do
        tid <- txInformationTxHash txInf
        find ((== tid) . txHash . fst) txs
    mergeWith :: [(Tx, Natural)] -> TxInformation -> TxInformation
    mergeWith txs txInf = maybe txInf (`addData` txInf) $ findTx txs txInf
    addData :: (Tx, Natural) -> TxInformation -> TxInformation
    addData (tx, fee) txInf =
        txInformationFillTx tx txInf
        { txInformationFee = Just fee
        }

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

mergeAddressTxs :: [AddressTx] -> [TxInformation]
mergeAddressTxs as =
    sortOn txInformationHeight $ mapMaybe toMvt $ Map.assocs aMap
  where
    aMap :: Map TxHash [AddressTx]
    aMap = Map.fromListWith (<>) $ fmap (addrTxTxHash &&& (: [])) as
    toMvt :: (TxHash, [AddressTx]) -> Maybe TxInformation
    toMvt (tid, atxs) =
        case head <$> nonEmpty atxs of
            Just a ->
                let (os, is) = partition ((< 0) . addrTxAmount) atxs
                in Just
                       TxInformation
                       { txInformationTxHash = Just tid
                       , txInformationTxSize = Nothing
                       , txInformationOutbound = Map.empty
                       , txInformationNonStd = 0
                       , txInformationInbound = toAddrMap is
                       , txInformationMyInputs = toAddrMap os
                       , txInformationFee = Nothing
                       , txInformationHeight = addrTxHeight a
                       , txInformationBlockHash = addrTxBlockHash a
                       }
            _ -> Nothing
    toAddrMap :: [AddressTx] -> Map Address (Satoshi, Maybe SoftPath)
    toAddrMap = Map.map (, Nothing) . Map.fromListWith (+) . fmap toAddrVal
    toAddrVal :: AddressTx -> (Address, Satoshi)
    toAddrVal = addrTxAddress &&& fromIntegral . abs . addrTxAmount

getTxs :: [TxHash] -> IO [(Tx, Natural)]
getTxs tids = do
    v <- httpJsonGet opts url
    let xs = mapM parseTx $ v ^.. values
    maybe
        (consoleError $ formatError "Could not decode the transaction")
        return
        xs
  where
    url = getURL <> "/transactions"
    opts = HTTP.defaults & HTTP.param "txids" .~ [toText tList]
    tList = intercalate "," $ txHashToHex <$> tids
    parseTx v = do
        tx <- decodeBytes =<< decodeHexText =<< v ^? key "hex" . _String
        fee <- fromIntegral <$> v ^? key "fee" . _Integer
        return (tx, fee)

broadcastTx :: Tx -> IO ()
broadcastTx tx = do
    _ <- HTTP.postWith (addStatusCheck HTTP.defaults) url val
    return ()
  where
    url = getURL <> "/transaction"
    val =
        J.object ["transaction" J..= J.String (encodeHexText $ encodeBytes tx)]

getBestHeight :: IO Natural
getBestHeight = do
    v <- httpJsonGet HTTP.defaults url
    let resM = fromIntegral <$> v ^? key "height" . _Integer
    maybe err return resM
  where
    url = getURL <> "/block/best"
    err = consoleError $ formatError "Could not get the best block height"

