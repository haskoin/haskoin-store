{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}
module Network.Haskoin.Wallet.Entropy where

import           Control.Monad                           (when)
import           Foundation
import           Foundation.Bits
import           Foundation.Collection
import           Foundation.IO
import           Foundation.Numerical
import           Foundation.System.Entropy
import           Network.Haskoin.Crypto                  (Mnemonic, toMnemonic)
import           Network.Haskoin.Util
import           Network.Haskoin.Wallet.FoundationCompat
import           Numeric                                 (readInt)
import qualified System.Directory                        as D

{- Base 6 decoding for dice entropy -}

b6Data :: String
b6Data = "612345"

b6 :: Offset (Element String) -> Maybe (Element String)
b6 = (b6Data !)

b6' :: Element String -> Maybe (Offset (Element String))
b6' = (`findIndex` b6Data) . (==)

decodeBase6 :: String -> Maybe (UArray Word8)
decodeBase6 str
    | null str = Just mempty
    | otherwise =
        case readInt
                 6
                 (isJust . b6')
                 (fromInteger . toInteger . f)
                 (toLString str) of
            ((i, []):_) -> Just $ asBytes integerToBS i
            _           -> Nothing
  where
    f = fromMaybe (error "Could not decode base6") . b6'

-- Mix entropy of same length by xoring them
mixEntropy :: UArray Word8
           -> UArray Word8
           -> Either String (UArray Word8)
mixEntropy ent1 ent2
    | length ent1 == length ent2 =
        Right $ zipWith xor ent1 ent2
    | otherwise = Left "Entropy is not of the same length"

diceToEntropy :: CountOf Word8 -> String -> Either String (UArray Word8)
diceToEntropy ent rolls
    | length rolls /= requiredRolls ent =
        Left $ show (requiredRolls ent) <> " dice rolls are required"
    | otherwise = do
        bytes <- maybeToEither "Could not decode base6" $ decodeBase6 rolls
        case ent - length bytes of
            Just n -> return $ replicate n 0x00 <> bytes
            -- This should probably never happend
            _ -> Left "Invalid entropy length"

-- The number of dice rolls required to reach a given amount of entropy
-- Example: 32 bytes of entropy require 99 dice rolls (255.9 bits)
requiredRolls :: CountOf Word8 -> CountOf (Element String)
requiredRolls ent = roundDown $ fromIntegral (fromCount ent) * log2o6
  where
    log2o6 = 3.09482245788 :: Double -- 8 * log 2 / log 6

genMnemonic :: CountOf Word8 -> IO (Either String (String, Mnemonic))
genMnemonic reqEnt = genMnemonicGen reqEnt Nothing

genMnemonicDice :: CountOf Word8 -> String -> IO (Either String (String, Mnemonic))
genMnemonicDice reqEnt rolls = genMnemonicGen reqEnt (Just rolls)

genMnemonicGen ::
       CountOf Word8 -> Maybe String -> IO (Either String (String, Mnemonic))
genMnemonicGen reqEnt rollsM
    | reqEnt `elem` [16,20 .. 32] = do
        (entOrig, sysEnt) <- systemEntropy reqEnt
        return $ do
            ent <-
                maybe
                    (Right sysEnt)
                    (diceToEntropy reqEnt >=> mixEntropy sysEnt)
                    rollsM
            when (length ent /= reqEnt) $
                Left "Something went wrong with the entropy size"
            mnem <- eitherString $ withBytes toMnemonic ent
            return (entOrig, mnem)
    | otherwise = return $ Left "The entropy value can only be in [16,20..32]"

systemEntropy :: CountOf Word8 -> IO (String, UArray Word8)
systemEntropy bytes = do
    exists <- D.doesFileExist "/dev/random"
    if exists
        then ("/dev/random", ) <$> devRandom bytes
        else ("Foundation.System.Entropy.getEntropy", ) <$> getEntropy bytes

devRandom :: CountOf Word8 -> IO (UArray Word8)
devRandom bytes = withFile "/dev/random" ReadMode (`hGet` fromCount bytes)
