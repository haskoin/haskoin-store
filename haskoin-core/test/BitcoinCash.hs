module Main where

import           Network.Haskoin.Constants
import qualified Network.Haskoin.Script.Spec (forkIdSpec)
import           Test.Hspec

main :: IO ()
main = do
    setBitcoinCashNetwork
    hspec Network.Haskoin.Script.Spec.forkIdSpec
