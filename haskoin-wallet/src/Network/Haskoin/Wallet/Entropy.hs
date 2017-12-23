{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}
module Network.Haskoin.Wallet.Entropy where

import           Control.Monad
import           Data.Bits                             (xor)
import qualified Data.ByteString                       as BS
import qualified Data.ByteString.Char8                 as B8
import           Data.Maybe
import           Data.Monoid
import           Data.String.Conversions               (cs)
import           Network.Haskoin.Crypto                (Mnemonic, toMnemonic)
import           Network.Haskoin.Util
import           Network.Haskoin.Wallet.ConsolePrinter
import           Numeric                               (readInt)
import qualified System.Directory                      as D
import qualified System.Entropy                        as System
import qualified System.IO                             as IO

{- Base 6 decoding for dice entropy -}

b6Data :: BS.ByteString
b6Data = "612345"

b6 :: Int -> Char
b6 = B8.index b6Data

b6' :: Char -> Maybe Int
b6' = flip B8.elemIndex b6Data

decodeBase6 :: BS.ByteString -> Maybe BS.ByteString
decodeBase6 bs
    | BS.null bs = Just BS.empty
    | otherwise =
        case readInt 6 (isJust . b6') f $ cs bs of
            ((i, []):_) -> Just $ integerToBS i
            _ -> Nothing
  where
    f = fromMaybe (error "Could not decode base6") . b6'

-- Mix entropy of same length by xoring them
mixEntropy :: BS.ByteString
           -> BS.ByteString
           -> Either String BS.ByteString
mixEntropy ent1 ent2
    | BS.length ent1 == BS.length ent2 =
        Right $ BS.pack $ BS.zipWith xor ent1 ent2
    | otherwise = Left "Entropy is not of the same length"

diceToEntropy :: Int -> String -> Either String BS.ByteString
diceToEntropy ent rolls
    | length rolls /= requiredRolls ent =
        Left $ show (requiredRolls ent) <> " dice rolls are required"
    | otherwise = do
        bs <- maybeToEither "Could not decode base6" $ decodeBase6 $ cs rolls
        -- This check should probably never trigger
        when (BS.length bs > ent) $ Left "Invalid entropy length"
        let z = BS.replicate (ent - BS.length bs) 0x00
        return $ BS.append z bs

-- The number of dice rolls required to reach a given amount of entropy
-- Example: 32 bytes of entropy require 99 dice rolls (255.9 bits)
requiredRolls :: Int -> Int
requiredRolls ent = floor $ (fromIntegral ent :: Double) * 8 * log 2 / log 6

genMnemonic :: Int -> Maybe String -> IO (Either String (String, Mnemonic))
genMnemonic reqEnt rollsM
    | reqEnt `elem` [16,20 .. 32] = do
        (entOrig, sysEnt) <- systemEntropy reqEnt
        return $ do
            ent <-
                maybe
                    (Right sysEnt)
                    (mixEntropy sysEnt <=< diceToEntropy reqEnt)
                    rollsM
            when (BS.length ent /= reqEnt) $
                Left "Something went wrong with the entropy size"
            mnem <- toMnemonic ent
            return (entOrig, mnem)
    | otherwise = return $ Left "The entropy value can only be in [16,20..32]"

systemEntropy :: Int -> IO (String, BS.ByteString)
systemEntropy bytes
    | bytes <= 0 = consoleError $ formatError "Entropy bytes can not be <= 0"
    | otherwise = do
        exists <- D.doesFileExist "/dev/random"
        if exists
            then ("/dev/random", ) <$> devRandom bytes
            else ("System.Entropy.getEntropy", ) <$> System.getEntropy bytes

devRandom :: Int -> IO BS.ByteString
devRandom = IO.withBinaryFile "/dev/random" IO.ReadMode . flip BS.hGet

