{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE NoImplicitPrelude #-}
module Network.Haskoin.Wallet.Arbitrary where

import           Foundation
import           Network.Haskoin.Test
import           Network.Haskoin.Wallet.AccountStore
import           Network.Haskoin.Wallet.Signing
import           Test.QuickCheck

instance Arbitrary TxSignData where
    arbitrary =
        TxSignData
            <$> arbitraryTx
            <*> (flip vectorOf arbitraryTx =<< choose (0, 5))
            <*> listOf arbitrarySoftPath
            <*> listOf arbitrarySoftPath

instance Arbitrary AccountStore where
    arbitrary =
        AccountStore
            <$> (snd <$> arbitraryXPubKey)
            <*> (fromIntegral <$> (arbitrary :: Gen Word64))
            <*> (fromIntegral <$> (arbitrary :: Gen Word64))
            <*> arbitraryHardPath

