{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Haskoin.Store.CommonSpec
    ( spec
    ) where

import           Control.Monad           (join)
import           Data.Aeson              (FromJSON, ToJSON)
import qualified Data.Aeson              as A
import qualified Data.ByteString.Short   as BSS
import           Data.Serialize          (Serialize (..), decode, encode)
import           Data.String.Conversions (cs)
import           Haskoin                 (Network, bch, bchRegTest, bchTest,
                                          btc, btcRegTest, btcTest)
import           Haskoin.Store.Common    (Balance (..), BlockData (..),
                                          BlockRef (..), BlockTx (..),
                                          DeriveType (..), Event (..),
                                          HealthCheck (..), NetWrap (..),
                                          PeerInformation (..), Prev (..),
                                          PubExcept (..), Spender (..),
                                          StoreInput (..), StoreOutput (..),
                                          Transaction (..), TxAfterHeight (..),
                                          TxData (..), TxId (..), Unspent (..),
                                          XPubBal (..), XPubSpec (..),
                                          XPubSummary (..), XPubUnspent (..))
import           Network.Haskoin.Test    (arbitraryAddress, arbitraryBlockHash,
                                          arbitraryBlockHeader,
                                          arbitraryOutPoint,
                                          arbitraryRejectCode, arbitraryScript,
                                          arbitraryTx, arbitraryTxHash,
                                          arbitraryXPubKey)
import           NQE                     ()
import           Test.Hspec              (Expectation, Spec, describe, shouldBe)
import           Test.Hspec.QuickCheck   (prop)
import           Test.QuickCheck         (Arbitrary (..), Gen,
                                          arbitraryPrintableChar,
                                          arbitraryUnicodeChar, elements,
                                          forAll, listOf, listOf1, oneof)

spec :: Spec
spec = do
    describe "Binary serialization" $ do
        prop "identity for derivation type" $ \x -> testSerial (x :: DeriveType)
        prop "identity for xpub spec" $ \x -> testSerial (x :: XPubSpec)
        prop "identity for block ref" $ \x -> testSerial (x :: BlockRef)
        prop "identity for block tx" $ \x -> testSerial (x :: BlockTx)
        prop "identity for balance" $ \x -> testSerial (x :: Balance)
        prop "identity for unspent" $ \x -> testSerial (x :: Unspent)
        prop "identity for block data" $ \x -> testSerial (x :: BlockData)
        prop "identity for input" $ \x -> testSerial (x :: StoreInput)
        prop "identity for spender" $ \x -> testSerial (x :: Spender)
        prop "identity for output" $ \x -> testSerial (x :: StoreOutput)
        prop "identity for previous output" $ \x -> testSerial (x :: Prev)
        prop "identity for tx data" $ \x -> testSerial (x :: TxData)
        prop "identity for transaction" $ \x -> testSerial (x :: Transaction)
        prop "identity for xpub balance" $ \x -> testSerial (x :: XPubBal)
        prop "identity for xpub unspent" $ \x -> testSerial (x :: XPubUnspent)
        prop "identity for xpub summary" $ \x -> testSerial (x :: XPubSummary)
        prop "identity for health check" $ \x -> testSerial (x :: HealthCheck)
        prop "identity for event" $ \x -> testSerial (x :: Event)
        prop "identity for tx after height" $ \x ->
            testSerial (x :: TxAfterHeight)
        prop "identity for txid" $ \x -> testSerial (x :: TxId)
        prop "identity for publish exception" $ \x ->
            testSerial (x :: PubExcept)
        prop "identity for peer info" $ \x -> testSerial (x :: PeerInformation)
    describe "JSON serialization" $ do
        prop "identity for balance" . forAll arbitraryNetData $ \(net, x) ->
            testNetJSON2 net (x :: Balance)
        prop "identity for block tx" $ \x -> testJSON (x :: BlockTx)
        prop "identity for block ref" $ \x -> testJSON (x :: BlockRef)
        prop "identity for unspent" $ \x -> testJSON (x :: Unspent)
        prop "identity for block data" $ \x -> testJSON (x :: BlockData)
        prop "identity for spender" $ \x -> testJSON (x :: Spender)
        prop "identity for transaction" . forAll arbitraryNetData $ \(net, x) ->
            testNetJSON1 net (x :: Transaction)
        prop "identity for xpub summary" $ \x -> testJSON (x :: XPubSummary)
        prop "identity for health check" $ \x -> testJSON (x :: HealthCheck)
        prop "identity for event" $ \x -> testJSON (x :: Event)
        prop "identity for txid" $ \x -> testJSON (x :: TxId)
        prop "identity for tx after height" $ \x ->
            testJSON (x :: TxAfterHeight)
        prop "identity for peer information" $ \x ->
            testJSON (x :: PeerInformation)

arbitraryNetData :: Arbitrary a => Gen (Network, a)
arbitraryNetData = do
    net <- arbitraryNetwork
    x <- arbitrary
    return (net, x)

testJSON :: (Eq a, Show a, ToJSON a, FromJSON a) => a -> Expectation
testJSON input = (A.decode . A.encode) input `shouldBe` Just input

testNetJSON1 ::
       (Eq a, Show a, ToJSON (NetWrap a), FromJSON a) => Network -> a -> Expectation
testNetJSON1 net x =
    let encoded = A.encode (NetWrap net x)
        decoded = A.decode encoded
     in decoded `shouldBe` Just x

testNetJSON2 ::
       (Eq a, Show a, ToJSON (NetWrap a), FromJSON (Network -> Maybe a))
    => Network
    -> a
    -> Expectation
testNetJSON2 net x =
    let encoded = A.encode (NetWrap net x)
        decoder = A.decode encoded
     in join (($ net) <$> decoder) `shouldBe` Just x

testSerial :: (Eq a, Show a, Serialize a) => a -> Expectation
testSerial input = (decode . encode) input `shouldBe` Right input

instance Arbitrary TxAfterHeight where
    arbitrary = TxAfterHeight <$> arbitrary

instance Arbitrary DeriveType where
    arbitrary = elements [DeriveNormal, DeriveP2SH, DeriveP2WPKH]

instance Arbitrary XPubSpec where
    arbitrary = do
        (_, k) <- arbitraryXPubKey
        t <- arbitrary
        return XPubSpec {xPubSpecKey = k, xPubDeriveType = t}

instance Arbitrary XPubBal where
    arbitrary = XPubBal <$> arbitrary <*> arbitrary

instance Arbitrary XPubUnspent where
    arbitrary = XPubUnspent <$> arbitrary <*> arbitrary

instance Arbitrary Event where
    arbitrary =
        oneof [EventBlock <$> arbitraryBlockHash, EventTx <$> arbitraryTxHash]

instance Arbitrary XPubSummary where
    arbitrary =
        XPubSummary
        <$> arbitrary
        <*> arbitrary
        <*> arbitrary
        <*> arbitrary
        <*> arbitrary
        <*> arbitrary

instance Arbitrary BlockRef where
    arbitrary = oneof [br, mr]
      where
        br = BlockRef <$> arbitrary <*> arbitrary
        mr = MemRef <$> arbitrary

instance Arbitrary BlockTx where
    arbitrary = do
        br <- arbitrary
        th <- arbitraryTxHash
        return BlockTx { blockTxBlock = br, blockTxHash = th}

arbitraryNetwork :: Gen Network
arbitraryNetwork = elements [bch, btc, bchTest, btcTest, bchRegTest, btcRegTest]

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
        <*> (BSS.toShort . encode <$> arbitraryScript)
        <*> arbitrary

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

instance Arbitrary StoreInput where
    arbitrary = oneof [cb, si]
      where
        cb = do
            st <- map encode <$> listOf arbitraryScript
            ws <- elements [Just st, Nothing]
            StoreCoinbase
                <$> arbitraryOutPoint
                <*> arbitrary
                <*> (encode <$> arbitraryScript)
                <*> pure ws
        si = do
            st <- map encode <$> listOf arbitraryScript
            ws <- elements [Just st, Nothing]
            StoreInput
                <$> arbitraryOutPoint
                <*> arbitrary
                <*> (encode <$> arbitraryScript)
                <*> (encode <$> arbitraryScript)
                <*> arbitrary
                <*> pure ws

instance Arbitrary Spender where
    arbitrary = Spender <$> arbitraryTxHash <*> arbitrary

instance Arbitrary Prev where
    arbitrary = Prev <$> (encode <$> arbitraryScript) <*> arbitrary

instance Arbitrary StoreOutput where
    arbitrary =
        StoreOutput
            <$> arbitrary
            <*> (encode <$> arbitraryScript)
            <*> arbitrary

instance Arbitrary TxData where
    arbitrary =
        TxData
            <$> arbitrary
            <*> (arbitraryTx =<< arbitraryNetwork)
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary

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

instance Arbitrary PeerInformation where
    arbitrary = do
        PeerInformation
            <$> (cs <$> listOf arbitraryUnicodeChar)
            <*> listOf arbitraryPrintableChar
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary

instance Arbitrary HealthCheck where
    arbitrary = do
        bh <- arbitraryBlockHash
        hh <- arbitraryBlockHash
        let mb = elements [Nothing, Just bh]
            mh = elements [Nothing, Just hh]
        HealthCheck
            <$> mb
            <*> arbitrary
            <*> mh
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary

instance Arbitrary PubExcept where
    arbitrary =
        oneof
            [ pure PubNoPeers
            , PubReject <$> arbitraryRejectCode
            , pure PubTimeout
            , pure PubPeerDisconnected
            ]

instance Arbitrary TxId where
    arbitrary = TxId <$> arbitraryTxHash
