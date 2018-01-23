{-# LANGUAGE OverloadedStrings #-}
module Network.Haskoin.Script.Spec where

import           Control.Monad
import qualified Crypto.Secp256k1            as EC
import qualified Data.Aeson                  as J
import qualified Data.ByteString             as BS
import qualified Data.ByteString.Lazy        as BL
import           Data.Either
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
import           Text.Read

spec :: Spec
spec = do
    standardSpec
    canonicalSigSpec
    scriptSpec
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

scriptSpec :: Spec
scriptSpec =
    describe "Network.Haskoin.Script Verifier" $
        it "Can verify standard scripts" $ do
            xs <- readTestFile "script_tests"
            let vectors = filter ((== 5) . length) (xs :: [[String]])
            length vectors `shouldBe` 85
            forM_ vectors $ \[siStr, soStr, flags, res, _]
                -- We can disable specific tests by adding a DISABLED flag in the data
             ->
                unless ("DISABLED" `isInfixOf` flags) $ do
                    let strict =
                            "DERSIG" `isInfixOf` flags ||
                            "STRICTENC" `isInfixOf` flags ||
                            "NULLDUMMY" `isInfixOf` flags
                        scriptSig = parseScript siStr
                        scriptPubKey = parseScript soStr
                        decodedOutput =
                            fromRight
                                (error $ "Could not decode output: " <> soStr) $
                            decodeOutputBS scriptPubKey
                        ver =
                            verifyStdInput
                                strict
                                (spendTx scriptPubKey scriptSig)
                                0
                                decodedOutput
                                0
                    case res of
                        "OK" -> ver `shouldBe` True
                        _    -> ver `shouldBe` False

creditTx :: BS.ByteString -> Tx
creditTx scriptPubKey =
    Tx 1 [txI] [txO] 0
  where
    txO = TxOut {outValue = 0, scriptOutput = scriptPubKey}
    txI =
        TxIn
        { prevOutput = nullOutPoint
        , scriptInput = encode $ Script [OP_0, OP_0]
        , txInSequence = maxBound
        }

spendTx :: BS.ByteString -> BS.ByteString -> Tx
spendTx scriptPubKey scriptSig =
    Tx 1 [txI] [txO] 0
  where
    txO = TxOut {outValue = 0, scriptOutput = BS.empty}
    txI =
        TxIn
        { prevOutput = OutPoint (txHash $ creditTx scriptPubKey) 0
        , scriptInput = scriptSig
        , txInSequence = maxBound
        }

parseScript :: String -> BS.ByteString
parseScript str =
    BS.concat $ fromMaybe err $ mapM f $ words str
  where
    f = decodeHex . cs . dropHex . replaceToken
    dropHex ('0':'x':xs) = xs
    dropHex xs           = xs
    err = error $ "Could not decode script: " <> str

replaceToken :: String -> String
replaceToken str = case readMaybe $ "OP_" <> str of
    Just opcode -> "0x" <> cs (encodeHex $ encode (opcode :: ScriptOp))
    _           -> str

canonicalSigSpec :: Spec
canonicalSigSpec =
    describe "Network.Haskoin.Script Canonical" $ do
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
sigHashSpec =
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
