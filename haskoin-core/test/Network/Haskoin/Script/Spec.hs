{-# LANGUAGE OverloadedStrings #-}
module Network.Haskoin.Script.Spec where

import           Control.Monad
import qualified Crypto.Secp256k1            as EC
import qualified Data.Aeson                  as J
import qualified Data.ByteString             as BS
import qualified Data.ByteString.Lazy        as BL
import           Data.Either
import           Data.List
import           Data.List
import           Data.Maybe
import           Data.Monoid                 ((<>))
import           Data.Serialize
import           Data.String.Conversions     (cs)
import           Data.Word
import           Network.Haskoin.Crypto
import           Network.Haskoin.Script
import           Network.Haskoin.Test
import           Network.Haskoin.Transaction
import           Network.Haskoin.Util
import           Test.Hspec
import           Test.QuickCheck

spec :: Spec
spec = do
    standardSpec
    canonicalSigSpec
    sigHashSpec

standardSpec :: Spec
standardSpec =
    describe "Network.Haskoin.Script.Standard" $ do
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
        it "can decode inputs with empty signatures" $ do
            decodeInput (Script [OP_0]) `shouldBe`
                Right (RegularInput (SpendPK TxSignatureEmpty))
            decodeInput (Script [opPushData ""]) `shouldBe`
                Right (RegularInput (SpendPK TxSignatureEmpty))
            let pk =
                    derivePubKey $
                    makePrvKey $ fromJust $ EC.secKey $ BS.replicate 32 1
            decodeInput (Script [OP_0, opPushData $ encode pk]) `shouldBe`
                Right (RegularInput (SpendPKHash TxSignatureEmpty pk))
            decodeInput (Script [OP_0, OP_0]) `shouldBe`
                Right (RegularInput (SpendMulSig [TxSignatureEmpty]))
            decodeInput (Script [OP_0, OP_0, OP_0, OP_0]) `shouldBe`
                Right
                    (RegularInput (SpendMulSig $ replicate 3 TxSignatureEmpty))

canonicalSigSpec :: Spec
canonicalSigSpec =
    describe "Network.Haskoin.Script" $ do
        it "can decode canonical signatures" $ do
            xs <- readTestFile "sig_canonical"
            let vectors = mapMaybe (decodeHex . cs) (xs :: [String])
            length vectors `shouldBe` 5
            forM_ vectors $ \sig ->
                decodeTxStrictSig sig `shouldSatisfy` isRight
        it "can detect non-canonical signatures" $ do
            xs <- readTestFile "sig_noncanonical"
            let vectors = mapMaybe (decodeHex . cs) (xs :: [String])
            length vectors `shouldBe` 15
            forM_ vectors $ \sig ->
                decodeTxStrictSig sig `shouldSatisfy` isLeft

sigHashSpec :: Spec
sigHashSpec = do
    describe "Network.Haskoin.Script.SigHash" $ do
        it "can decode . encode a SigHash" $
            property $
            forAll arbitrarySigHash $ \sh ->
                decode (encode sh) `shouldBe` Right (sh :: SigHash)
        it "can decode some SigHash vectors" $ do
            decode (BS.singleton 0x00) `shouldBe`
                Right (SigHash (SigUnknown 0x00) False False)
            decode (BS.singleton 0x01) `shouldBe`
                Right (SigHash SigAll False False)
            decode (BS.singleton 0x02) `shouldBe`
                Right (SigHash SigNone False False)
            decode (BS.singleton 0x03) `shouldBe`
                Right (SigHash SigSingle False False)
            decode (BS.singleton 0x41) `shouldBe`
                Right (SigHash SigAll False True)
            decode (BS.singleton 0x81) `shouldBe`
                Right (SigHash SigAll True False)
            decode (BS.singleton 0xc1) `shouldBe`
                Right (SigHash SigAll True True)
            decode (BS.singleton 0xe1) `shouldBe`
                Right (SigHash SigAll True True)
            decode (BS.singleton 0xff) `shouldBe`
                Right (SigHash (SigUnknown 0x1f) True True)
        it "can decodeTxDerSig . encode a TxSignature" $
            property $
            forAll arbitraryTxSignature $ \(_, _, ts) ->
                decodeTxDerSig (encodeTxSig ts) `shouldBe` Right ts
        it "can decodeTxStrictSig . encode a TxSignature" $
            property $
            forAll arbitraryTxSignature $ \(_, _, ts@(TxSignature _ sh)) ->
                if isSigUnknown sh || forkIdFlag sh
                    then decodeTxStrictSig (encodeTxSig ts) `shouldSatisfy`
                         isLeft
                    else decodeTxStrictSig (encodeTxSig ts) `shouldBe` Right ts
        it "can produce the sighash one" $
            property $
            forAll arbitraryTx $ forAll arbitraryScript . testSigHashOne

testSigHashOne :: Tx -> Script -> Word64 -> Bool -> Property
testSigHashOne tx s val acp = not (null $ txIn tx) ==>
    if length (txIn tx) > length (txOut tx)
        then res `shouldBe` one
        else res `shouldNotBe` one
  where
    res = txSigHash tx s val (length (txIn tx) - 1) (SigHash SigSingle acp False)
    one = "0100000000000000000000000000000000000000000000000000000000000000"

{-- Test Utilities --}

readTestFile :: J.FromJSON a => FilePath -> IO a
readTestFile fp = do
    bs <- BL.readFile $ "test/data/" <> fp <> ".json"
    maybe (error $ "Could not read test file " <> fp) return $ J.decode bs
