{-# OPTIONS_GHC -fno-warn-orphans #-}
module Network.Haskoin.Wallet.Arbitrary where

import           Network.Haskoin.Test
import           Network.Haskoin.Wallet.Signing
import           Test.QuickCheck

instance Arbitrary TxSignData where
    arbitrary =
        TxSignData
            <$> arbitraryTx
            <*> (flip vectorOf arbitraryTx =<< choose (0, 5))
            <*> listOf arbitrarySoftPath
            <*> listOf arbitrarySoftPath

