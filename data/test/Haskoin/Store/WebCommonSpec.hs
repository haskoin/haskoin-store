{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE RecordWildCards           #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Haskoin.Store.WebCommonSpec
    ( spec
    ) where

import           Control.Monad           (forM_)
import           Data.Proxy
import           Data.String.Conversions (cs)
import           Data.Word
import           Haskoin
import           Haskoin.Store.Data
import           Haskoin.Store.DataSpec  ()
import           Haskoin.Store.WebCommon
import           Haskoin.Util.Arbitrary
import           Test.Hspec
import           Test.Hspec.QuickCheck
import           Test.QuickCheck

data GenBox = forall p. (Show p, Eq p, Param p) => GenBox (Gen p)

params :: [GenBox]
params =
    [ GenBox arbitraryAddress
    , GenBox (listOf arbitraryAddress)
    , GenBox (arbitrary :: Gen StartParam)
    , GenBox (arbitrarySizedNatural :: Gen OffsetParam)
    , GenBox (arbitrarySizedNatural :: Gen LimitParam)
    , GenBox (arbitrarySizedNatural :: Gen HeightParam)
    , GenBox (arbitrary :: Gen HeightsParam)
    , GenBox (arbitrarySizedNatural :: Gen TimeParam)
    , GenBox (snd <$> arbitraryXPubKey :: Gen XPubKey)
    , GenBox (arbitrary :: Gen DeriveType)
    , GenBox (NoCache <$> arbitrary :: Gen NoCache)
    , GenBox (NoTx <$> arbitrary :: Gen NoTx)
    , GenBox arbitraryBlockHash
    , GenBox (listOf arbitraryBlockHash)
    , GenBox arbitraryTxHash
    , GenBox (listOf arbitraryTxHash)
    , GenBox (arbitrary :: Gen BinfoActiveParam)
    , GenBox (arbitrary :: Gen BinfoActiveP2SHparam)
    , GenBox (arbitrary :: Gen BinfoOnlyShowParam)
    , GenBox (arbitrary :: Gen BinfoSimpleParam)
    , GenBox (arbitrary :: Gen BinfoNoCompactParam)
    , GenBox (arbitrary :: Gen BinfoCountParam)
    , GenBox (arbitrary :: Gen BinfoOffsetParam)
    ]

spec :: Spec
spec =
    describe "Parameter encoding" $
        forM_ params $ \(GenBox g) -> testParam g

testParam :: (Eq a, Show a, Param a) => Gen a -> Spec
testParam pGen =
    prop ("encodeParam/parseParam identity for parameter " <> name) $
    forAll pGen $ \p ->
        case encodeParam btc p of
            Just txts -> parseParam btc txts `shouldBe` Just p
            _         -> expectationFailure "Param encoding failed"
  where
    name = cs $ proxyLabel $ proxy pGen
    proxy :: Gen a -> Proxy a
    proxy = const Proxy

instance Arbitrary StartParam where
    arbitrary =
        oneof
            [ StartParamHash <$> arbitraryHash256
            , StartParamHeight . fromIntegral <$>
              (choose (0, 1230768000) :: Gen Word64)
            , StartParamTime . fromIntegral <$>
              (choose (1230768000, maxBound) :: Gen Word64)
            ]

instance Arbitrary HeightsParam where
    arbitrary = HeightsParam <$> listOf arbitrarySizedNatural

---------------------------------------
-- Blockchain.info API compatibility --
---------------------------------------

instance Arbitrary BinfoAddressParam where
    arbitrary = oneof [a, x]
      where
        a = do
            getBinfoAddressParam <- arbitraryAddress
            return BinfoAddressParam {..}
        x = do
            getBinfoXPubKeyParam <- snd <$> arbitraryXPubKey
            return BinfoXPubKeyParam {..}

instance Arbitrary BinfoActiveParam where
    arbitrary = do
        getBinfoActiveParam <- arbitrary
        return BinfoActiveParam {..}

instance Arbitrary BinfoActiveP2SHparam where
    arbitrary = do
        getBinfoActiveP2SHparam <- arbitrary
        return BinfoActiveP2SHparam {..}

instance Arbitrary BinfoOnlyShowParam where
    arbitrary = do
        getBinfoOnlyShowParam <- arbitrary
        return BinfoOnlyShowParam {..}

instance Arbitrary BinfoSimpleParam where
    arbitrary = BinfoSimpleParam <$> arbitrary

instance Arbitrary BinfoNoCompactParam where
    arbitrary = BinfoNoCompactParam <$> arbitrary

instance Arbitrary BinfoCountParam where
    arbitrary = do
        w32 <- arbitrary :: Gen Word32
        return $ BinfoCountParam (fromIntegral w32)

instance Arbitrary BinfoOffsetParam where
    arbitrary = do
        w32 <- arbitrary :: Gen Word32
        return $ BinfoOffsetParam (fromIntegral w32)
