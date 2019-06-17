{-# LANGUAGE OverloadedStrings #-}

module Network.Haskoin.Store.DataSpec
    ( spec
    ) where

import           Control.Monad
import           Control.Monad.Logger
import           Control.Monad.Trans
import           Data.Either
import           Data.Maybe
import           Data.Serialize
import           Haskoin
import           Haskoin.Node
import           Haskoin.Store
import           NQE
import           Test.Hspec

spec :: Spec
spec = do
  let net = btc

  describe "Test TxHash serialization" $
    it "serializes tx" $ do
      let tx = TxHash "0666939fb16533c8e5ebaf6052bb8c90d27ee53fe6035bb763de5253e0b1cd44"
      testSerial net tx

  describe "Test Address serialization" $
    it "serialize address" $ do
      let addr = fromJust $ stringToAddr net "1DtDAYYTWRoiXvHRjARwVhjCUnNTk1XfXw"
      testSerial net addr

testSerial :: (Eq a, Show a, BinSerial a) => Network -> a -> Expectation
testSerial net input =
  let raw = runPut $ binSerial net input
      deser = runGet (binDeserial net) raw
  in deser `shouldBe` Right input
