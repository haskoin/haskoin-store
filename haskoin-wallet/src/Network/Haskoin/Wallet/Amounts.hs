{-# LANGUAGE OverloadedStrings #-}
module Network.Haskoin.Wallet.Amounts where

import           Control.Monad
import           Data.List
import           Data.Monoid                           ((<>))
import           Data.Word
import           Network.Haskoin.Wallet.ConsolePrinter
import           Text.Read

data AmountUnit
    = UnitBitcoin
    | UnitBit
    | UnitSatoshi
    deriving (Eq)

instance Show AmountUnit where
    show unit = case unit of
        UnitBitcoin -> "bitcoin"
        UnitBit     -> "bit"
        UnitSatoshi -> "satoshi"

formatAmount :: AmountUnit -> Word64 -> ConsolePrinter
formatAmount unit = formatIntegerAmount unit . fromIntegral

formatIntegerAmount :: AmountUnit -> Integer -> ConsolePrinter
formatIntegerAmount unit amnt =
    f (showIntegerAmount unit amnt) <+> formatStatic (showUnit unit amnt)
  where
    f
        | amnt >= 0 = formatPosBalance
        | otherwise = formatNegBalance

showUnit :: AmountUnit -> Integer -> String
showUnit unit amnt
    | unit == UnitSatoshi = show unit -- satoshi is always singular
    | abs amnt == 1 = show unit
    | otherwise = show unit <> "s" -- plural form bitcoins and bits

-- | Like 'showAmount' but will display a minus sign for negative amounts
showIntegerAmount :: AmountUnit -> Integer -> String
showIntegerAmount unit i
    | i < 0 = "-" <> showAmount unit (fromIntegral $ abs i)
    | otherwise = showAmount unit $ fromIntegral i


-- | Like 'readAmount' but can parse a negative amount
readIntegerAmount :: AmountUnit -> String -> Maybe Integer
readIntegerAmount unit s =
    case s of
        ('-':str) -> ((-1) *) . fromIntegral <$> readAmount unit str
        str       -> fromIntegral <$> readAmount unit str

showAmount :: AmountUnit -> Word64 -> String
showAmount unit amnt =
    case unit of
        UnitBitcoin ->
            let (q, r) = amnt `quotRem` 100000000
            in addSep (show q) <> "." <> stripEnd (padWith 8 '0' (<> show r))
        UnitBit ->
            let (q, r) = amnt `quotRem` 100
            in addSep (show q) <> "." <> padWith 2 '0' (<> show r)
        UnitSatoshi -> addSep (show amnt)
  where
    stripEnd = dropPatternEnd "0000" . dropPatternEnd "000000"
    addSep = intercalate "'" . groupEnd 3

readAmount :: AmountUnit -> String -> Maybe Word64
readAmount unit str' =
    case unit of
        UnitBitcoin -> do
            guard $ length r <= 8
            a <- readMaybe q
            b <- readMaybe $ padWith 8 '0' (r <>)
            return $ a * 100000000 + b
        UnitBit -> do
            guard $ length r <= 2
            a <- readMaybe q
            b <- readMaybe $ padWith 2 '0' (r <>)
            return $ a * 100 + b
        UnitSatoshi -> readMaybe str
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

