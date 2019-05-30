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
        def = TxHash "1111111111"
    describe "Test BinDeserial" $
          it "serializes tx" $ do
            let tx = TxHash "0666939fb16533c8e5ebaf6052bb8c90d27ee53fe6035bb763de5253e0b1cd44"
                raw = runPut $ binSerial net tx
                deserial = runGet (binDeserial net) raw
            (fromRight def deserial) `shouldBe` tx

