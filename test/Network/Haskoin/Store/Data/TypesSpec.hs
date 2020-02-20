{-# LANGUAGE OverloadedStrings #-}
module Network.Haskoin.Store.Data.TypesSpec
    ( spec
    ) where

import           Data.Serialize                   (runGet, runPut)
import           Data.Text                        (Text)
import qualified Data.Text                        as T ()
import           Haskoin                          (Address, Network,
                                                   TxHash (TxHash), btc,
                                                   stringToAddr)
import           Network.Haskoin.Store.Data.Types (BinSerial (..))
import           NQE                              ()
import           Test.Hspec                       (Expectation, Spec, describe,
                                                   it, shouldBe)

spec :: Spec
spec = do
    let net = btc
    describe "Transaction hash serialisation" $ do
        it "tx hash serialisation identity" $
            let tx =
                    TxHash
                        "0666939fb16533c8e5ebaf6052bb8c90d27ee53fe6035bb763de5253e0b1cd44"
             in testSerial net tx
    describe "Address serialisation" $ do
        it "address serialisation identity" $
            let Just addr =
                    stringToAddr net "1DtDAYYTWRoiXvHRjARwVhjCUnNTk1XfXw"
             in testSerial net addr
        it "address list serialisation identity" $
            let expected =
                    toAddrList
                        net
                        [ "1DtDAYYTWRoiXvHRjARwVhjCUnNTk1XfXw"
                        , "1GhnssnwRZwWKbHQXJRFpQfkfvE6hDG2KF"
                        ]
             in testSerial net expected

toAddrList :: Network -> [Text] -> [Address]
toAddrList net = map (\t -> let Just a = stringToAddr net t in a)

testSerial :: (Eq a, Show a, BinSerial a) => Network -> a -> Expectation
testSerial net input =
    let raw = runPut $ binSerial net input
        deser = runGet (binDeserial net) raw
     in deser `shouldBe` Right input
