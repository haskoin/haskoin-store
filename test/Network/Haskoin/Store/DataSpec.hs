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
  let net = btcTest
      def = TxHash "75ad09e40a8246beed18646c393b8687f084a23f1336179349f6891b6028e974"
  describe "Test TxHash serialization" $
    it "serializes tx" $ do
      let tx = TxHash "0666939fb16533c8e5ebaf6052bb8c90d27ee53fe6035bb763de5253e0b1cd44"
          raw = runPut $ binSerial net tx
          deserial = runGet (binDeserial net) raw
      fromRight def deserial `shouldBe` tx
