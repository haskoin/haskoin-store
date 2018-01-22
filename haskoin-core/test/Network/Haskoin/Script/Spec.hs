{-# LANGUAGE OverloadedStrings #-}
module Network.Haskoin.Script.Spec where

import           Control.Monad
import qualified Data.Aeson             as J
import qualified Data.ByteString.Lazy   as BL
import           Data.Either
import           Data.List
import           Data.Maybe
import           Data.Monoid            ((<>))
import           Data.Serialize
import           Network.Haskoin.Script
import           Network.Haskoin.Test
import           Network.Haskoin.Util
import           Data.String.Conversions     (cs)
import           Test.Hspec
import           Test.QuickCheck

spec :: Spec
spec = do
    parserSpec
    canonicalSigSpec

parserSpec :: Spec
parserSpec =
    describe "Network.Haskoin.Script.Parser" $ do
        it "has intToScriptOp . scriptOpToInt identity" $
            property $
            forAll arbitraryIntScriptOp $ \i ->
                intToScriptOp <$> scriptOpToInt i `shouldBe` Right i
        it "has decodeOutput . encodeOutput identity" $
            property $
            forAll arbitraryScriptOutput $ \so ->
                decodeOutput (encodeOutput so) `shouldBe` Right so
        it "has decodeInput . encodeOutput identity" $
            property $
            forAll arbitraryScriptInput $ \si ->
                decodeInput (encodeInput si) `shouldBe` Right si
        it "can sort multisig scripts" $
            forAll arbitraryMSOutput $ \out ->
                map encode (getOutputMulSigKeys (sortMulSig out))
                `shouldSatisfy`
                \xs -> xs == sort xs

canonicalSigSpec :: Spec
canonicalSigSpec =
    describe "Network.Haskoin.Script" $ do
        it "can decode canonical signatures" $ do
            xs <- readTestFile "sig_canonical"
            let vectors = mapMaybe (decodeHex . cs) (xs :: [String])
            length vectors `shouldBe` 5
            forM_ vectors $ \sig ->
                decodeCanonicalSig sig `shouldSatisfy` isRight
        it "can detect non-canonical signatures" $ do
            xs <- readTestFile "sig_noncanonical"
            let vectors = mapMaybe (decodeHex . cs) (xs :: [String])
            length vectors `shouldBe` 15
            forM_ vectors $ \sig ->
                decodeCanonicalSig sig `shouldSatisfy` isLeft

{-- Test Utilities --}

readTestFile :: J.FromJSON a => FilePath -> IO a
readTestFile fp = do
    bs <- BL.readFile $ "test/data/" <> fp <> ".json"
    maybe (error $ "Could not read test file " <> fp) return $ J.decode bs
