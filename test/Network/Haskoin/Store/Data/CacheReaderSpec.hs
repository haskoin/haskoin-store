module Network.Haskoin.Store.Data.CacheReaderSpec (spec) where

import           Data.List                              (sort)
import           Haskoin                                (KeyIndex)
import           Network.Haskoin.Store.Common           (BlockRef (..))
import           Network.Haskoin.Store.Data.CacheReader (blockRefScore,
                                                         pathScore,
                                                         scoreBlockRef,
                                                         scorePath)
import           Test.Hspec                             (Spec, describe)
import           Test.Hspec.QuickCheck                  (prop)
import           Test.QuickCheck                        (Gen, arbitrary, choose,
                                                         elements, forAll,
                                                         listOf, oneof)

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
    describe "Score for derivation path" $ do
        prop "sorts correctly" $
            forAll arbitraryDerivationPaths $ \ds ->
                let scores = map pathScore (sort ds)
                 in sort scores == scores
        prop "respects identity" $
            forAll arbitraryDerivationPath $ \d ->
                let score = pathScore d
                    d' = scorePath score
                 in d' == d

arbitraryDerivationPaths :: Gen [[KeyIndex]]
arbitraryDerivationPaths = listOf arbitraryDerivationPath

arbitraryDerivationPath :: Gen [KeyIndex]
arbitraryDerivationPath = do
    x <- elements [0, 1]
    y <- arbitrary
    return [x, y]

arbitraryBlockRefs :: Gen [BlockRef]
arbitraryBlockRefs = listOf arbitraryBlockRef

arbitraryBlockRef :: Gen BlockRef
arbitraryBlockRef = oneof [b, m]
  where
    b = do
        h <- choose (0, 0x07ffffff)
        p <- choose (0, 0x03ffffff)
        return BlockRef {blockRefHeight = h, blockRefPos = p}
    m = do
        t <- choose (0, 0x001fffffffffffff)
        return MemRef {memRefTime = t}
