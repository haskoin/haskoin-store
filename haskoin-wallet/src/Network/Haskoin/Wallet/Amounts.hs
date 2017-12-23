{-# LANGUAGE OverloadedStrings #-}
module Network.Haskoin.Wallet.Amounts where

import           Control.Monad
import           Data.List
import           Data.Monoid   ((<>))
import           Data.Word
import           Text.Read

data Precision = PrecisionSatoshi
               | PrecisionBits
               | PrecisionBitcoin

showPrecision :: Precision -> String
showPrecision PrecisionSatoshi = "satoshi"
showPrecision PrecisionBits = "bits"
showPrecision PrecisionBitcoin = "bitcoin"

showBalanceI :: Precision -> Integer -> String
showBalanceI pr i
    | i < 0 = "-" <> showBalance' pr (fromIntegral $ abs i)
    | otherwise = showBalance pr $ fromIntegral i

showBalanceI' :: Precision -> Integer -> String
showBalanceI' pr i = showBalanceI pr i <> " " <> showPrecision pr

readBalanceI :: Precision -> String -> Maybe Integer
readBalanceI pr ('-':str) = ((-1) *) . fromIntegral <$> readBalance pr str
readBalanceI pr str = fromIntegral <$> readBalance pr str

showBalance' :: Precision -> Word64 -> String
showBalance' pr val = showBalance pr val <> " " <> showPrecision pr

showBalance :: Precision -> Word64 -> String
showBalance pr val =
    case pr of
        PrecisionSatoshi -> addSep (show val)
        PrecisionBits ->
            let (q, r) = val `quotRem` 100
            in addSep (show q) <> "." <> padWith 2 '0' (<> show r)
        PrecisionBitcoin ->
            let (q, r) = val `quotRem` 100000000
            in addSep (show q) <> "." <> stripEnd (padWith 8 '0' (<> show r))
  where
    stripEnd = dropPatternEnd "0000" . dropPatternEnd "000000"
    addSep = intercalate "'" . groupEnd 3

readBalance :: Precision -> String -> Maybe Word64
readBalance pr str' =
    case pr of
        PrecisionSatoshi -> readMaybe str
        PrecisionBits -> do
            guard $ length r <= 2
            a <- readMaybe q
            b <- readMaybe $ padWith 2 '0' (r <>)
            return $ a * 100 + b
        PrecisionBitcoin -> do
            guard $ length r <= 8
            a <- readMaybe q
            b <- readMaybe $ padWith 8 '0' (r <>)
            return $ a * 100000000 + b
  where
    str = dropSep str'
    dropSep = filter (not . (`elem` (" _'" :: String)))
    r = delete '.' r'
    (q, r') = break (== '.') str

padWith :: Int -> a -> ([a] -> [a]) -> [a]
padWith n p f
    | length xs < n = f pad
    | otherwise = xs
  where
    pad = replicate (n - length xs) p
    xs = f []

dropPatternEnd :: Eq a => [a] -> [a] -> [a]
dropPatternEnd p xs
    | p `isSuffixOf` xs = take (length xs - length p) xs
    | otherwise = xs

groupEnd :: Int -> [a] -> [[a]]
groupEnd n xs
    | length xs <= n = [xs]
    | otherwise = groupEnd n a <> [b]
  where
    (a, b) = splitAt (length xs - n) xs

