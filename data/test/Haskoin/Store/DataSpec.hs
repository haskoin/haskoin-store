{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE RecordWildCards           #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Haskoin.Store.DataSpec
    ( spec
    ) where

import           Control.Monad           (forM_, replicateM)
import           Data.Aeson              (FromJSON (..))
import qualified Data.ByteString         as B
import qualified Data.ByteString.Short   as BSS
import qualified Data.Map.Strict         as Map
import qualified Data.Serialize          as S
import           Data.String.Conversions (cs)
import           Haskoin
import           Haskoin.Store.Data
import           Haskoin.Util.Arbitrary
import           Test.Hspec              (Spec, describe, it)
import           Test.Hspec.QuickCheck   (prop)
import           Test.QuickCheck

serialVals :: [SerialBox]
serialVals =
    [ SerialBox (arbitrary :: Gen DeriveType)
    , SerialBox (arbitrary :: Gen XPubSpec)
    , SerialBox (arbitrary :: Gen BlockRef)
    , SerialBox (arbitrary :: Gen TxRef)
    , SerialBox (arbitrary :: Gen Balance)
    , SerialBox (arbitrary :: Gen Unspent)
    , SerialBox (arbitrary :: Gen BlockData)
    , SerialBox (arbitrary :: Gen StoreInput)
    , SerialBox (arbitrary :: Gen Spender)
    , SerialBox (arbitrary :: Gen StoreOutput)
    , SerialBox (arbitrary :: Gen Prev)
    , SerialBox (arbitrary :: Gen TxData)
    , SerialBox (arbitrary :: Gen Transaction)
    , SerialBox (arbitrary :: Gen XPubBal)
    , SerialBox (arbitrary :: Gen XPubUnspent)
    , SerialBox (arbitrary :: Gen XPubSummary)
    , SerialBox (arbitrary :: Gen HealthCheck)
    , SerialBox (arbitrary :: Gen Event)
    , SerialBox (arbitrary :: Gen TxId)
    , SerialBox (arbitrary :: Gen PeerInformation)
    , SerialBox (arbitrary :: Gen (GenericResult BlockData))
    , SerialBox (arbitrary :: Gen (RawResult BlockData))
    , SerialBox (arbitrary :: Gen (RawResultList BlockData))
    , SerialBox (arbitrary :: Gen Except)
    , SerialBox (arbitrary :: Gen BinfoWallet)
    , SerialBox (arbitrary :: Gen BinfoAddress)
    , SerialBox (arbitrary :: Gen BinfoBlockInfo)
    , SerialBox (arbitrary :: Gen BinfoXPubPath)
    , SerialBox (arbitrary :: Gen BinfoSpender)
    , SerialBox (arbitrary :: Gen BinfoTxOutput)
    , SerialBox (arbitrary :: Gen BinfoTxInput)
    , SerialBox (arbitrary :: Gen BinfoTx)
    ]

jsonVals :: [JsonBox]
jsonVals =
    [ JsonBox (arbitrary :: Gen TxRef)
    , JsonBox (arbitrary :: Gen BlockRef)
    , JsonBox (arbitrary :: Gen Spender)
    , JsonBox (arbitrary :: Gen XPubSummary)
    , JsonBox (arbitrary :: Gen HealthCheck)
    , JsonBox (arbitrary :: Gen Event)
    , JsonBox (arbitrary :: Gen TxId)
    , JsonBox (arbitrary :: Gen PeerInformation)
    , JsonBox (arbitrary :: Gen (GenericResult XPubSummary))
    , JsonBox (arbitrary :: Gen (RawResult BlockData))
    , JsonBox (arbitrary :: Gen (RawResultList BlockData))
    , JsonBox (arbitrary :: Gen Except)
    , JsonBox (arbitrary :: Gen BinfoWallet)
    , JsonBox (arbitrary :: Gen BinfoSymbol)
    , JsonBox (arbitrary :: Gen BinfoBlockInfo)
    , JsonBox (arbitrary :: Gen BinfoInfo)
    , JsonBox (arbitrary :: Gen BinfoSpender)
    , JsonBox (arbitrary :: Gen BinfoTicker)
    ]

netVals :: [NetBox]
netVals =
    [ NetBox ( balanceToJSON
             , balanceToEncoding
             , balanceParseJSON
             , arbitraryNetData)
    , NetBox ( storeOutputToJSON
             , storeOutputToEncoding
             , storeOutputParseJSON
             , arbitraryNetData)
    , NetBox ( unspentToJSON
             , unspentToEncoding
             , unspentParseJSON
             , arbitraryNetData)
    , NetBox ( xPubBalToJSON
             , xPubBalToEncoding
             , xPubBalParseJSON
             , arbitraryNetData)
    , NetBox ( xPubUnspentToJSON
             , xPubUnspentToEncoding
             , xPubUnspentParseJSON
             , arbitraryNetData)
    , NetBox ( storeInputToJSON
             , storeInputToEncoding
             , storeInputParseJSON
             , arbitraryStoreInputNet)
    , NetBox ( blockDataToJSON
             , blockDataToEncoding
             , const parseJSON
             , arbitraryBlockDataNet)
    , NetBox ( transactionToJSON
             , transactionToEncoding
             , transactionParseJSON
             , arbitraryNetData)
    , NetBox ( binfoMultiAddrToJSON
             , binfoMultiAddrToEncoding
             , binfoMultiAddrParseJSON
             , arbitraryNetData)
    , NetBox ( binfoAddressToJSON
             , binfoAddressToEncoding
             , binfoAddressParseJSON
             , arbitraryNetData)
    , NetBox ( binfoTxToJSON
             , binfoTxToEncoding
             , binfoTxParseJSON
             , arbitraryNetData)
    , NetBox ( binfoTxInputToJSON
             , binfoTxInputToEncoding
             , binfoTxInputParseJSON
             , arbitraryNetData)
    , NetBox ( binfoTxOutputToJSON
             , binfoTxOutputToEncoding
             , binfoTxOutputParseJSON
             , arbitraryNetData)
    , NetBox ( binfoXPubPathToJSON
             , binfoXPubPathToEncoding
             , binfoXPubPathParseJSON
             , arbitraryNetData)
    ]

spec :: Spec
spec = do
    describe "Data.Serialize Encoding" $
        forM_ serialVals $ \(SerialBox g) -> testSerial g
    describe "Data.Aeson Encoding" $
        forM_ jsonVals $ \(JsonBox g) -> testJson g
    describe "Data.Aeson Encoding with Network" $
        forM_ netVals $ \(NetBox (j,e,p,g)) -> testNetJson j e p g
    describe "Blockchain.info API" $ do
        it "compresses txids correctly" $
            forAll arbitraryTxHash $ \h ->
            matchBinfoTxHash (hashToBinfoTxIndex h) h
        prop "compresses blockchain locations correctly" $
            let x = choose (0, 2 ^ 24 - 1)
             in forAll ((,) <$> x <*> x) $ \(b, p) ->
                let i = blockToBinfoTxIndex b p
                    Just (b', p') = binfoTxIndexBlock i
                 in b == b' && p == p'


instance Arbitrary BlockRef where
    arbitrary =
        oneof [BlockRef <$> arbitrary <*> arbitrary, MemRef <$> arbitrary]

instance Arbitrary Prev where
    arbitrary = Prev <$> arbitraryBS1 <*> arbitrary

instance Arbitrary TxData where
    arbitrary =
        TxData
            <$> arbitrary
            <*> arbitraryTx btc
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary

instance Arbitrary StoreInput where
    arbitrary =
        oneof
            [ StoreCoinbase
                <$> arbitraryOutPoint
                <*> arbitrary
                <*> arbitraryBS1
                <*> listOf arbitraryBS1
            , StoreInput
                <$> arbitraryOutPoint
                <*> arbitrary
                <*> arbitraryBS1
                <*> arbitraryBS1
                <*> arbitrary
                <*> listOf arbitraryBS1
                <*> arbitraryMaybe arbitraryAddress
            ]

arbitraryStoreInputNet :: Gen (Network, StoreInput)
arbitraryStoreInputNet = do
    net <- arbitraryNetwork
    store <- arbitrary
    let res | getSegWit net = store
            | otherwise = store{ inputWitness = [] }
    return (net, res)

instance Arbitrary Spender where
    arbitrary = Spender <$> arbitraryTxHash <*> arbitrary

instance Arbitrary StoreOutput where
    arbitrary =
        StoreOutput
          <$> arbitrary
          <*> arbitraryBS1
          <*> arbitrary
          <*> arbitraryMaybe arbitraryAddress

instance Arbitrary Transaction where
    arbitrary =
        Transaction
            <$> arbitrary
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary
            <*> arbitraryTxHash
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary

arbitraryTransactionNet :: Gen (Network, Transaction)
arbitraryTransactionNet = do
    net <- arbitraryNetwork
    val <- arbitrary
    let val1 | getSegWit net = val
             | otherwise = val{ transactionInputs = f <$> transactionInputs val
                              , transactionWeight = 0
                              }
        res | getReplaceByFee net = val1
            | otherwise = val1{ transactionRBF = False }
    return (net, res)
  where
    f i = i {inputWitness = []}

instance Arbitrary PeerInformation where
    arbitrary =
        PeerInformation
            <$> (cs <$> listOf arbitraryUnicodeChar)
            <*> listOf arbitraryPrintableChar
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary

instance Arbitrary BlockHealth where
    arbitrary =
        BlockHealth
            <$> arbitrary
            <*> arbitrary
            <*> arbitrary

instance Arbitrary TimeHealth where
    arbitrary =
        TimeHealth
            <$> arbitrary
            <*> arbitrary

instance Arbitrary CountHealth where
    arbitrary =
        CountHealth
            <$> arbitrary
            <*> arbitrary

instance Arbitrary MaxHealth where
    arbitrary =
        MaxHealth
            <$> arbitrary
            <*> arbitrary

instance Arbitrary HealthCheck where
    arbitrary =
        HealthCheck
            <$> arbitrary
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary

instance Arbitrary RejectCode where
    arbitrary =
        elements
            [ RejectMalformed
            , RejectInvalid
            , RejectObsolete
            , RejectDuplicate
            , RejectNonStandard
            , RejectDust
            , RejectInsufficientFee
            , RejectCheckpoint
            ]

instance Arbitrary XPubSpec where
    arbitrary = XPubSpec <$> (snd <$> arbitraryXPubKey) <*> arbitrary

instance Arbitrary DeriveType where
    arbitrary = elements [DeriveNormal, DeriveP2SH, DeriveP2WPKH]

instance Arbitrary TxId where
    arbitrary = TxId <$> arbitraryTxHash

instance Arbitrary TxRef where
    arbitrary = TxRef <$> arbitrary <*> arbitraryTxHash

instance Arbitrary Balance where
    arbitrary =
        Balance
            <$> arbitraryAddress
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary

instance Arbitrary Unspent where
    arbitrary =
        Unspent
            <$> arbitrary
            <*> arbitraryOutPoint
            <*> arbitrary
            <*> (BSS.toShort <$> arbitraryBS1)
            <*> arbitraryMaybe arbitraryAddress

instance Arbitrary BlockData where
    arbitrary =
        BlockData
        <$> arbitrary
        <*> arbitrary
        <*> arbitrary
        <*> arbitraryBlockHeader
        <*> arbitrary
        <*> arbitrary
        <*> listOf1 arbitraryTxHash
        <*> arbitrary
        <*> arbitrary
        <*> arbitrary

arbitraryBlockDataNet :: Gen (Network, BlockData)
arbitraryBlockDataNet = do
    net <- arbitraryNetwork
    dat <- arbitrary
    let res | getSegWit net = dat
            | otherwise = dat{ blockDataWeight = 0}
    return (net, res)

instance Arbitrary a => Arbitrary (GenericResult a) where
    arbitrary = GenericResult <$> arbitrary

instance Arbitrary a => Arbitrary (RawResult a) where
    arbitrary = RawResult <$> arbitrary

instance Arbitrary a => Arbitrary (RawResultList a) where
    arbitrary = RawResultList <$> arbitrary

instance Arbitrary XPubBal where
    arbitrary = XPubBal <$> arbitrary <*> arbitrary

instance Arbitrary XPubUnspent where
    arbitrary = XPubUnspent <$> arbitrary <*> arbitrary

instance Arbitrary XPubSummary where
    arbitrary =
        XPubSummary
        <$> arbitrary
        <*> arbitrary
        <*> arbitrary
        <*> arbitrary
        <*> arbitrary
        <*> arbitrary

instance Arbitrary Event where
    arbitrary =
        oneof
        [ EventBlock <$> arbitraryBlockHash
        , EventTx <$> arbitraryTxHash
        ]

instance Arbitrary Except where
    arbitrary =
        oneof
        [ return ThingNotFound
        , return ServerError
        , return BadRequest
        , UserError <$> arbitrary
        , StringError <$> arbitrary
        , return BlockTooLarge
        ]

---------------------------------------
-- Blockchain.info API Compatibility --
---------------------------------------

instance Arbitrary BinfoMultiAddr where
    arbitrary = do
        getBinfoMultiAddrAddresses <- arbitrary
        getBinfoMultiAddrWallet <- arbitrary
        getBinfoMultiAddrTxs <- arbitrary
        getBinfoMultiAddrInfo <- arbitrary
        getBinfoMultiAddrRecommendFee <- arbitrary
        getBinfoMultiAddrCashAddr <- arbitrary
        return BinfoMultiAddr {..}

instance Arbitrary BinfoAddress where
    arbitrary = do
        getBinfoAddress <- arbitraryAddress
        getBinfoAddrTxCount <- arbitrary
        getBinfoAddrReceived <- arbitrary
        getBinfoAddrSent <- arbitrary
        getBinfoAddrBalance <- arbitrary
        getBinfoXPubKey <- snd <$> arbitraryXPubKey
        getBinfoXPubAccountIndex <- arbitrary
        getBinfoXPubChangeIndex <- arbitrary
        elements [BinfoAddress {..}, BinfoXPubKey {..}]

instance Arbitrary BinfoWallet where
    arbitrary = do
        getBinfoWalletBalance <- arbitrary
        getBinfoWalletTxCount <- arbitrary
        getBinfoWalletFilteredCount <- arbitrary
        getBinfoWalletTotalReceived <- arbitrary
        getBinfoWalletTotalSent <- arbitrary
        return BinfoWallet {..}

instance Arbitrary BinfoTx where
    arbitrary = do
        getBinfoTxHash <- arbitraryTxHash
        getBinfoTxVer <- arbitrary
        getBinfoTxInputs <- resize 10 $ listOf1 arbitrary
        getBinfoTxOutputs <- resize 10 $ listOf1 arbitrary
        let getBinfoTxVinSz = fromIntegral (length getBinfoTxInputs)
            getBinfoTxVoutSz = fromIntegral (length getBinfoTxOutputs)
        getBinfoTxSize <- arbitrary
        getBinfoTxWeight <- arbitrary
        getBinfoTxFee <- arbitrary
        getBinfoTxRelayedBy <- cs <$> listOf arbitraryUnicodeChar
        getBinfoTxLockTime <- arbitrary
        getBinfoTxIndex <- arbitrary
        getBinfoTxDoubleSpend <- arbitrary
        getBinfoTxResult <- arbitrary
        getBinfoTxBalance <- arbitrary
        getBinfoTxTime <- arbitrary
        getBinfoTxBlockIndex <- arbitrary
        getBinfoTxBlockHeight <- arbitrary
        return BinfoTx {..}

instance Arbitrary BinfoTxInput where
    arbitrary = do
        getBinfoTxInputSeq <- arbitrary
        getBinfoTxInputWitness <- B.pack <$> listOf arbitrary
        getBinfoTxInputScript <- B.pack <$> listOf arbitrary
        getBinfoTxInputIndex <- arbitrary
        getBinfoTxInputPrevOut <- arbitrary
        return BinfoTxInput {..}

instance Arbitrary BinfoTxOutput where
    arbitrary = do
        getBinfoTxOutputType <- arbitrary
        getBinfoTxOutputSpent <- arbitrary
        getBinfoTxOutputValue <- arbitrary
        getBinfoTxOutputIndex <- arbitrary
        getBinfoTxOutputTxIndex <- arbitrary
        getBinfoTxOutputScript <- B.pack <$> listOf arbitrary
        getBinfoTxOutputSpenders <- arbitrary
        getBinfoTxOutputAddress <-
            oneof [return Nothing, Just <$> arbitraryAddress]
        getBinfoTxOutputXPub <- arbitrary
        return BinfoTxOutput {..}

instance Arbitrary BinfoSpender where
    arbitrary = do
        getBinfoSpenderTxIndex <- arbitrary
        getBinfoSpenderIndex <- arbitrary
        return BinfoSpender {..}

instance Arbitrary BinfoXPubPath where
    arbitrary = do
        getBinfoXPubPathKey <- snd <$> arbitraryXPubKey
        getBinfoXPubPathDeriv <- arbitrarySoftPath
        return BinfoXPubPath {..}

instance Arbitrary BinfoInfo where
    arbitrary = do
        getBinfoConnected <- arbitrary
        getBinfoConversion <- arbitrary
        getBinfoLocal <- arbitrary
        getBinfoBTC <- arbitrary
        getBinfoLatestBlock <- arbitrary
        return BinfoInfo {..}

instance Arbitrary BinfoBlockInfo where
    arbitrary = do
        getBinfoBlockInfoHash <- arbitraryBlockHash
        getBinfoBlockInfoHeight <- arbitrary
        getBinfoBlockInfoTime <- arbitrary
        getBinfoBlockInfoIndex <- arbitrary
        return BinfoBlockInfo {..}

instance Arbitrary BinfoSymbol where
    arbitrary = do
        getBinfoSymbolCode <- cs <$> listOf1 arbitraryUnicodeChar
        getBinfoSymbolString <- cs <$> listOf1 arbitraryUnicodeChar
        getBinfoSymbolName <- cs <$> listOf1 arbitraryUnicodeChar
        getBinfoSymbolConversion <- arbitrary
        getBinfoSymbolAfter <- arbitrary
        getBinfoSymbolLocal <- arbitrary
        return BinfoSymbol {..}

instance Arbitrary BinfoTicker where
    arbitrary = do
        binfoTickerSymbol <- cs <$> listOf1 arbitraryUnicodeChar
        binfoTickerPrice24h <- arbitrary
        binfoTickerVol24h <- arbitrary
        binfoTickerLastPrice <- arbitrary
        return BinfoTicker{..}
