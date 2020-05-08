{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Haskoin.Store.DataSpec
    ( spec
    ) where

import           Data.Aeson              (Encoding, FromJSON (..), ToJSON (..),
                                          Value)
import qualified Data.Aeson              as A
import           Data.Aeson.Encoding     (encodingToLazyByteString)
import           Data.Aeson.Parser       (decodeWith, json)
import           Data.Aeson.Types        (Parser, parse)
import           Data.ByteString         (pack)
import qualified Data.ByteString.Short   as BSS
import           Data.Serialize          (Serialize (..), decode, encode)
import           Data.String.Conversions (cs)
import           Haskoin                 (Address (..), BlockHash (..),
                                          BlockHeader (..), Hash160 (..),
                                          Hash256 (..), Network (..),
                                          OutPoint (..), RejectCode (..),
                                          Tx (..), TxHash (..), TxIn (..),
                                          TxOut (..), XPubKey (..), bch,
                                          bchRegTest, bchTest, btc, btcRegTest,
                                          btcTest, ripemd160, sha256)
import           Haskoin.Store.Data      (Balance (..), BlockData (..),
                                          BlockRef (..), BlockTx (..),
                                          DeriveType (..), Event (..),
                                          HealthCheck (..),
                                          PeerInformation (..), Prev (..),
                                          Spender (..), StoreInput (..),
                                          StoreOutput (..), Transaction (..),
                                          TxData (..), TxId (..), Unspent (..),
                                          XPubBal (..), XPubSpec (..),
                                          XPubSummary (..), XPubUnspent (..),
                                          balanceParseJSON, balanceToEncoding,
                                          balanceToJSON, blockDataToEncoding,
                                          blockDataToJSON, transactionParseJSON,
                                          transactionToEncoding,
                                          transactionToJSON, unspentParseJSON,
                                          unspentToEncoding, unspentToJSON,
                                          xPubUnspentParseJSON,
                                          xPubUnspentToEncoding,
                                          xPubUnspentToJSON)
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
        prop "identity for txid" $ \x -> testSerial (x :: TxId)
        prop "identity for peer info" $ \x -> testSerial (x :: PeerInformation)
    describe "JSON serialization" $ do
        prop "identity for balance" . forAll arbitraryNetData $ \(net, x) ->
            testNetJSON
                (balanceParseJSON net)
                (balanceToJSON net)
                (balanceToEncoding net)
                x
        prop "identity for block tx" $ \x -> testJSON (x :: BlockTx)
        prop "identity for block ref" $ \x -> testJSON (x :: BlockRef)
        prop "identity for unspent" . forAll arbitraryNetData $ \(net, x) ->
            testNetJSON
                (unspentParseJSON net)
                (unspentToJSON net)
                (unspentToEncoding net)
                x
        prop "identity for block data" . forAll arbitraryNetData $ \(net, x) ->
            let x' =
                    if getSegWit net
                        then x
                        else x {blockDataWeight = 0}
             in testNetJSON
                    parseJSON
                    (blockDataToJSON net)
                    (blockDataToEncoding net)
                    x'
        prop "identity for spender" $ \x -> testJSON (x :: Spender)
        prop "identity for transaction" . forAll arbitraryNetData $ \(net, x) ->
            let f i = i {inputWitness = Nothing}
                x' =
                    if getSegWit net
                        then x
                        else x
                                 { transactionInputs =
                                       map f (transactionInputs x)
                                 , transactionWeight = 0
                                 }
                x'' =
                    if getReplaceByFee net
                        then x'
                        else x' {transactionRBF = False}
             in testNetJSON
                    (transactionParseJSON net)
                    (transactionToJSON net)
                    (transactionToEncoding net)
                    x''
        prop "identity for xpub summary" $ \x -> testJSON (x :: XPubSummary)
        prop "identity for xpub unspent" . forAll arbitraryNetData $ \(net, x) ->
            testNetJSON
                (xPubUnspentParseJSON net)
                (xPubUnspentToJSON net)
                (xPubUnspentToEncoding net)
                x
        prop "identity for health check" $ \x -> testJSON (x :: HealthCheck)
        prop "identity for event" $ \x -> testJSON (x :: Event)
        prop "identity for txid" $ \x -> testJSON (x :: TxId)
        prop "identity for peer information" $ \x ->
            testJSON (x :: PeerInformation)

testJSON :: (Eq a, Show a, ToJSON a, FromJSON a) => a -> Expectation
testJSON input = (A.decode . A.encode) input `shouldBe` Just input

testNetJSON ::
       (Eq a, Show a)
    => (Value -> Parser a)
    -> (a -> Value)
    -> (a -> Encoding)
    -> a
    -> Expectation
testNetJSON parsejson tojson toenc x =
    let encval = A.encode (tojson x)
        encenc = encodingToLazyByteString (toenc x)
        decval = decodeWith json (parse parsejson) encval
        decenc = decodeWith json (parse parsejson) encenc
     in do
        decval `shouldBe` Just x
        decenc `shouldBe` Just x

testSerial :: (Eq a, Show a, Serialize a) => a -> Expectation
testSerial input = (decode . encode) input `shouldBe` Right input

arbitraryNetwork :: Gen Network
arbitraryNetwork = elements [bch, btc, bchTest, btcTest, bchRegTest, btcRegTest]

arbitraryNetData :: Arbitrary a => Gen (Network, a)
arbitraryNetData = do
    net <- arbitraryNetwork
    x <- arbitrary
    return (net, x)

instance Arbitrary BlockRef where
    arbitrary =
        oneof [BlockRef <$> arbitrary <*> arbitrary, MemRef <$> arbitrary]

instance Arbitrary Hash256 where
    arbitrary = sha256 . pack <$> listOf1 arbitrary

instance Arbitrary TxHash where
    arbitrary = TxHash <$> arbitrary

instance Arbitrary OutPoint where
    arbitrary = OutPoint <$> arbitrary <*> arbitrary

instance Arbitrary TxIn where
    arbitrary =
        TxIn <$> arbitrary <*> (pack <$> listOf1 arbitrary) <*>
        arbitrary

instance Arbitrary TxOut where
    arbitrary = TxOut <$> arbitrary <*> (pack <$> listOf1 arbitrary)

instance Arbitrary Tx where
    arbitrary = do
        ver <- arbitrary
        txin <- listOf1 arbitrary
        txout <- listOf1 arbitrary
        txlock <- arbitrary
        return
            Tx
                { txVersion = ver
                , txIn = txin
                , txOut = txout
                , txWitness = []
                , txLockTime = txlock
                }

instance Arbitrary Prev where
    arbitrary = Prev <$> (pack <$> listOf1 arbitrary) <*> arbitrary

instance Arbitrary TxData where
    arbitrary =
        TxData
            <$> arbitrary
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary

instance Arbitrary StoreInput where
    arbitrary =
        oneof
            [ StoreCoinbase <$> arbitrary <*> arbitrary <*>
              (pack <$> listOf1 arbitrary) <*>
              (oneof
                   [ Just <$> (listOf $ pack <$> listOf1 arbitrary)
                   , return Nothing
                   ])
            , StoreInput <$> arbitrary <*> arbitrary <*>
              (pack <$> listOf1 arbitrary) <*>
              (pack <$> listOf1 arbitrary) <*>
              arbitrary <*>
              (oneof
                   [ Just <$> (listOf $ pack <$> listOf1 arbitrary)
                   , return Nothing
                   ]) <*>
              arbitrary
            ]

instance Arbitrary Spender where
    arbitrary = Spender <$> arbitrary <*> arbitrary

instance Arbitrary StoreOutput where
    arbitrary =
        StoreOutput <$> arbitrary <*> (pack <$> listOf1 arbitrary) <*> arbitrary <*>
        arbitrary

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

instance Arbitrary BlockHash where
    arbitrary = BlockHash <$> arbitrary

instance Arbitrary HealthCheck where
    arbitrary = do
        bh <- arbitrary
        hh <- arbitrary
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

instance Arbitrary XPubKey where
    arbitrary =
        XPubKey <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*>
        arbitrary

instance Arbitrary XPubSpec where
    arbitrary = XPubSpec <$> arbitrary <*> arbitrary

instance Arbitrary DeriveType where
    arbitrary = elements [DeriveNormal, DeriveP2SH, DeriveP2WPKH]

instance Arbitrary TxId where
    arbitrary = TxId <$> arbitrary

instance Arbitrary BlockTx where
    arbitrary = BlockTx <$> arbitrary <*> arbitrary

instance Arbitrary Hash160 where
    arbitrary = ripemd160 . pack <$> listOf1 arbitrary

instance Arbitrary Address where
    arbitrary =
        oneof
            [ PubKeyAddress <$> arbitrary
            , ScriptAddress <$> arbitrary
            ]

instance Arbitrary Balance where
    arbitrary =
        Balance
            <$> arbitrary
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary
            <*> arbitrary

instance Arbitrary Unspent where
    arbitrary =
        Unspent <$> arbitrary <*> arbitrary <*> arbitrary <*>
        (BSS.toShort . pack <$> listOf1 arbitrary) <*> arbitrary

instance Arbitrary BlockHeader where
    arbitrary =
        BlockHeader <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*>
        arbitrary <*>
        arbitrary

instance Arbitrary BlockData where
    arbitrary =
        BlockData
        <$> arbitrary
        <*> arbitrary
        <*> arbitrary
        <*> arbitrary
        <*> arbitrary
        <*> arbitrary
        <*> listOf1 arbitrary
        <*> arbitrary
        <*> arbitrary
        <*> arbitrary

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
        oneof [EventBlock <$> arbitrary, EventTx <$> arbitrary]
