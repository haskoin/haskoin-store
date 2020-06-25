{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Haskoin.Store.DataSpec
    ( spec
    ) where

import           Control.Monad           (forM_)
import           Data.Aeson              (FromJSON (..))
import qualified Data.ByteString.Short   as BSS
import           Data.String.Conversions (cs)
import           Haskoin
import           Haskoin.Store.Data
import           Haskoin.Util.Arbitrary
import           Test.Hspec              (Spec, describe)
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
             , arbitraryTransactionNet)
    ]

spec :: Spec
spec = do
    describe "Data.Serialize Encoding" $
        forM_ serialVals $ \(SerialBox g) -> testSerial g
    describe "Data.Aeson Encoding" $
        forM_ jsonVals $ \(JsonBox g) -> testJson g
    describe "Data.Aeson Encoding with Network" $
        forM_ netVals $ \(NetBox (j,e,p,g)) -> testNetJson j e p g

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
                <*> arbitraryMaybe (listOf arbitraryBS1)
            , StoreInput
                <$> arbitraryOutPoint
                <*> arbitrary
                <*> arbitraryBS1
                <*> arbitraryBS1
                <*> arbitrary
                <*> arbitraryMaybe (listOf arbitraryBS1)
                <*> arbitraryMaybe arbitraryAddress
            ]

arbitraryStoreInputNet :: Gen (Network, StoreInput)
arbitraryStoreInputNet = do
    net <- arbitraryNetwork
    store <- arbitrary
    let res | getSegWit net = store
            | otherwise = store{ inputWitness = Nothing }
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
    f i = i {inputWitness = Nothing}

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
