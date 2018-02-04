{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies      #-}
module Network.Haskoin.Wallet.Amounts where

import           Control.Monad
import           Foundation
import           Foundation.Collection
import           Foundation.String.Read
import           Network.Haskoin.Wallet.ConsolePrinter

type Satoshi = Natural

data AmountUnit
    = UnitBitcoin
    | UnitBit
    | UnitSatoshi
    deriving (Eq)

{- ConsolePrinter functions -}

formatAmount :: AmountUnit -> Satoshi -> ConsolePrinter
formatAmount unit = formatIntegerAmount unit . fromIntegral

formatIntegerAmount :: AmountUnit -> Integer -> ConsolePrinter
formatIntegerAmount unit amnt
    | amnt >= 0 = formatIntegerAmountWith formatPosAmount unit amnt
    | otherwise = formatIntegerAmountWith formatNegAmount unit amnt

formatIntegerAmountWith ::
       (String -> ConsolePrinter) -> AmountUnit -> Integer -> ConsolePrinter
formatIntegerAmountWith f unit amnt =
    f (showIntegerAmount unit amnt) <+> formatUnit unit amnt

formatUnit :: AmountUnit -> Integer -> ConsolePrinter
formatUnit unit = formatStatic . showUnit unit

showUnit :: AmountUnit -> Integer -> String
showUnit unit amnt
    | unit == UnitSatoshi = strUnit -- satoshi is always singular
    | abs amnt == 1 = strUnit
    | otherwise = strUnit <> "s" -- plural form bitcoins and bits
  where
    strUnit =
        case unit of
            UnitBitcoin -> "bitcoin"
            UnitBit     -> "bit"
            UnitSatoshi -> "satoshi"

{- Amount Parsing -}

showAmount :: AmountUnit -> Satoshi -> String
showAmount unit amnt =
    case unit of
        UnitBitcoin ->
            let (q, r) = amnt `divMod` 100000000
            in addSep (show q) <> "." <>
               stripEnd (padWith 8 '0' (<> show r))
        UnitBit ->
            let (q, r) = amnt `divMod` 100
            in addSep (show q) <> "." <> padWith 2 '0' (<> show r)
        UnitSatoshi -> addSep (show amnt)
  where
    stripEnd = dropPatternEnd "0000" . dropPatternEnd "000000"
    addSep = intercalate "'" . groupEnd 3

readAmount :: AmountUnit -> String -> Maybe Satoshi
readAmount unit amntStr =
    case unit of
        UnitBitcoin -> do
            guard $ length r <= 8
            a <- readNatural q
            b <- readNatural $ padWith 8 '0' (r <>)
            return $ a * 100000000 + b
        UnitBit -> do
            guard $ length r <= 2
            a <- readNatural q
            b <- readNatural $ padWith 2 '0' (r <>)
            return $ a * 100 + b
        UnitSatoshi -> readNatural str
  where
    str = dropAmountSep amntStr
    (q, r) = second (drop 1) $ breakElem '.' str

dropAmountSep :: String -> String
dropAmountSep = filter (`notElem` [' ', '_', '\''])

-- | Like 'showAmount' but will display a minus sign for negative amounts
showIntegerAmount :: AmountUnit -> Integer -> String
showIntegerAmount unit i
    | i < 0 = "-" <> showAmount unit (fromIntegral $ abs i)
    | otherwise = showAmount unit $ fromIntegral i


-- | Like 'readAmount' but can parse a negative amount
readIntegerAmount :: AmountUnit -> String -> Maybe Integer
readIntegerAmount unit str =
    case uncons str of
        Just ('-', rest) -> negate . toInteger <$> readAmount unit rest
        _ -> toInteger <$> readAmount unit str

padWith :: Sequential c => CountOf (Element c) -> Element c -> (c -> c) -> c
padWith n p f =
    case n - length xs of
        Just r -> f $ replicate r p
        _      -> xs
  where
    xs = f mempty

dropPatternEnd :: (Eq (Element c), Sequential c) => c -> c -> c
dropPatternEnd p xs
    | p `isSuffixOf` xs =
        case length xs - length p of
            Just n -> take n xs
            _      -> xs
    | otherwise = xs

groupEnd :: Sequential c => CountOf (Element c) -> c -> [c]
groupEnd n xs =
    case length xs - n of
        Nothing -> [xs]
        Just 0 -> [xs]
        Just r ->
            let (a, b) = splitAt r xs
            in groupEnd n a <> [b]
