module Haskoin.Store.CacheSpec (spec) where

import Data.List (sort)
import Haskoin.Store.Cache (blockRefScore, scoreBlockRef)
import Haskoin.Store.Data (BlockRef (..))
import Test.Hspec (Spec, describe)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, choose, forAll, listOf, oneof)

spec :: Spec
spec = do
  describe "Score for block reference" $ do
    prop "sorts correctly" $
      forAll arbitraryBlockRefs $ \ts ->
        let scores = map blockRefScore (sort ts)
         in sort scores == reverse scores
    prop "respects identity" $
      forAll arbitraryBlockRef $ \b ->
        let score = blockRefScore b
            ref = scoreBlockRef score
         in ref == b

arbitraryBlockRefs :: Gen [BlockRef]
arbitraryBlockRefs = listOf arbitraryBlockRef

arbitraryBlockRef :: Gen BlockRef
arbitraryBlockRef = oneof [b, m]
  where
    b = do
      h <- choose (0, 0x07ffffff)
      p <- choose (0, 0x03ffffff)
      return BlockRef {height = h, position = p}
    m = do
      t <- choose (0, 0x001fffffffffffff)
      return MemRef {timestamp = t}
