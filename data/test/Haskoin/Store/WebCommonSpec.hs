{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Haskoin.Store.WebCommonSpec (spec) where

import Control.Monad (forM_)
import Data.Proxy
import Data.String.Conversions (cs)
import Data.Word
import Haskoin
import Haskoin.Store.Data
import Haskoin.Store.DataSpec ()
import Haskoin.Store.WebCommon
import Haskoin.Util
import Haskoin.Util.Arbitrary
import Test.Hspec
import Test.Hspec.QuickCheck
import Test.QuickCheck

data GenBox = forall p. (Show p, Eq p, Param p) => GenBox (Gen p)

params :: Ctx -> [GenBox]
params ctx =
  [ GenBox arbitraryAddress,
    GenBox (listOf arbitraryAddress),
    GenBox (arbitrary :: Gen StartParam),
    GenBox (arbitrarySizedNatural :: Gen OffsetParam),
    GenBox (arbitrarySizedNatural :: Gen LimitParam),
    GenBox (arbitrarySizedNatural :: Gen HeightParam),
    GenBox (arbitrary :: Gen HeightsParam),
    GenBox (arbitrarySizedNatural :: Gen TimeParam),
    GenBox (snd <$> arbitraryXPubKey ctx :: Gen XPubKey),
    GenBox (arbitrary :: Gen DeriveType),
    GenBox (NoCache <$> arbitrary :: Gen NoCache),
    GenBox (NoTx <$> arbitrary :: Gen NoTx),
    GenBox arbitraryBlockHash,
    GenBox (listOf arbitraryBlockHash),
    GenBox arbitraryTxHash,
    GenBox (listOf arbitraryTxHash)
  ]

spec :: Spec
spec = prepareContext $ \ctx ->
  describe "Parameter encoding" $
    forM_ (params ctx) $
      \(GenBox g) -> testParam ctx g

testParam :: (Eq a, Show a, Param a) => Ctx -> Gen a -> Spec
testParam ctx pGen =
  prop ("encodeParam/parseParam identity for parameter " <> name) $
    forAll pGen $ \p ->
      case encodeParam btc ctx p of
        Just txts -> parseParam btc ctx txts `shouldBe` Just p
        _ -> expectationFailure "Param encoding failed"
  where
    name = cs $ proxyLabel $ proxy pGen
    proxy :: Gen a -> Proxy a
    proxy = const Proxy

instance Arbitrary StartParam where
  arbitrary =
    oneof
      [ StartParamHash <$> arbitraryHash256,
        StartParamHeight . fromIntegral
          <$> (choose (0, 1230768000) :: Gen Word64),
        StartParamTime . fromIntegral
          <$> (choose (1230768000, maxBound) :: Gen Word64)
      ]

instance Arbitrary HeightsParam where
  arbitrary = HeightsParam <$> listOf arbitrarySizedNatural
