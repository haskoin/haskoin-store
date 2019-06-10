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
import qualified Data.Text            as T
import           Haskoin
import           Haskoin.Node
import           Haskoin.Store
import           NQE
import           Test.Hspec

spec :: Spec
spec = do
  let net = btc
      def = TxHash "75ad09e40a8246beed18646c393b8687f084a23f1336179349f6891b6028e974"
      defAddr = fromJust $ stringToAddr net "1Mfn26ABTDBexhSUbsE3MxKBLSHfHQj9Z7"
  describe "Test TxHash serialization" $
    it "serializes tx" $ do
      let tx = TxHash "0666939fb16533c8e5ebaf6052bb8c90d27ee53fe6035bb763de5253e0b1cd44"
          raw = runPut $ binSerial net tx
          deserial = runGet (binDeserial net) raw
      fromRight def deserial `shouldBe` tx
  describe "Test Address serialization" $
    it "serialize address" $ do
      let addr = fromJust $ stringToAddr net "1DtDAYYTWRoiXvHRjARwVhjCUnNTk1XfXw"
          raw = runPut $ binSerial net addr
          deserial = runGet (binDeserial net) raw
      fromRight defAddr deserial `shouldBe` addr

  describe "Test serialization of a list of addresses" $
    it "serialize addresses" $ do
      let addr1 = fromJust $ stringToAddr net "1DtDAYYTWRoiXvHRjARwVhjCUnNTk1XfXw"
          addr2 = fromJust $ stringToAddr net "1GhnssnwRZwWKbHQXJRFpQfkfvE6hDG2KF"
          expected = toAddrList net ["1DtDAYYTWRoiXvHRjARwVhjCUnNTk1XfXw", "1GhnssnwRZwWKbHQXJRFpQfkfvE6hDG2KF"]
          raw = runPut $ binSerial net expected
          deserial = runGet (binDeserial net) raw
      fromRight [] deserial `shouldBe` expected


toAddrList :: Network -> [T.Text] -> [Address]
toAddrList net = map (fromJust . stringToAddr net)
