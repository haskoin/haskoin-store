module Network.Haskoin.Wallet.ConsolePrinter where

import           Data.Monoid
import           System.Console.ANSI
import           System.Exit
import           System.IO.Unsafe

data ConsolePrinter
    = ConsoleConcat !ConsolePrinter !ConsolePrinter
    | ConsoleNewline !ConsolePrinter
    | ConsoleNest !Int !ConsolePrinter
    | ConsoleText !ConsoleFormat
    | ConsoleEmpty

instance Monoid ConsolePrinter where
    mempty = ConsoleEmpty
    mappend a ConsoleEmpty = a
    mappend ConsoleEmpty b = b
    mappend a b = ConsoleConcat a b

text :: ConsoleFormat -> ConsolePrinter
text = ConsoleText

(<+>) :: ConsolePrinter -> ConsolePrinter -> ConsolePrinter
p1 <+> p2 = p1 <> text (FormatStatic " ") <> p2

vcat :: [ConsolePrinter] -> ConsolePrinter
vcat [] = ConsoleEmpty
vcat (ConsoleEmpty:xs) = vcat xs
vcat (x:xs) = x <> ConsoleNewline (vcat xs)

nest :: Int -> ConsolePrinter -> ConsolePrinter
nest = ConsoleNest

block :: Int -> String -> String
block n str
    | missing <= 0 = str
    | otherwise = str <> replicate missing ' '
  where
    missing = n - length str

renderIO :: ConsolePrinter -> IO ()
renderIO cp = go 0 0 cp >> putStrLn ""
  where
    go :: Int -> Int -> ConsolePrinter -> IO Int
    go l n p =
        case p of
            ConsoleConcat p1 p2 -> do
                l2 <- go l n p1
                go l2 n p2
            ConsoleNewline ConsoleEmpty -> return l
            ConsoleNewline p1 -> do
                putStrLn ""
                putStr $ replicate n ' '
                go n n p1
            ConsoleNest i p1 -> do
                putStr $ replicate i ' '
                go (l + i) (n + i) p1
            ConsoleText f -> do
                printFormat f
                return $ l + length (getFormat f)
            ConsoleEmpty -> return l

data ConsoleFormat
    = FormatTitle { getFormat :: !String }
    | FormatStatic { getFormat :: !String }
    | FormatAccount { getFormat :: !String }
    | FormatPubKey { getFormat :: !String }
    | FormatFilePath { getFormat :: !String }
    | FormatKey { getFormat :: !String }
    | FormatDeriv { getFormat :: !String }
    | FormatMnemonic { getFormat :: !String }
    | FormatAddress { getFormat :: !String }
    | FormatTxHash { getFormat :: !String }
    | FormatPosBalance { getFormat :: !String }
    | FormatNegBalance { getFormat :: !String }
    | FormatTrue { getFormat :: !String }
    | FormatFalse { getFormat :: !String }
    | FormatWarn { getFormat :: !String }
    | FormatError { getFormat :: !String }

formatTitle :: String -> ConsolePrinter
formatTitle = text . FormatTitle

formatStatic :: String -> ConsolePrinter
formatStatic = text . FormatStatic

formatAccount :: String -> ConsolePrinter
formatAccount = text . FormatAccount

formatPubKey :: String -> ConsolePrinter
formatPubKey = text . FormatPubKey

formatFilePath :: String -> ConsolePrinter
formatFilePath = text . FormatFilePath

formatKey :: String -> ConsolePrinter
formatKey = text . FormatKey

formatDeriv :: String -> ConsolePrinter
formatDeriv = text . FormatDeriv

formatMnemonic :: String -> ConsolePrinter
formatMnemonic = text . FormatMnemonic

formatAddress :: String -> ConsolePrinter
formatAddress = text . FormatAddress

formatTxHash :: String -> ConsolePrinter
formatTxHash = text . FormatTxHash

formatPosBalance :: String -> ConsolePrinter
formatPosBalance = text . FormatPosBalance

formatNegBalance :: String -> ConsolePrinter
formatNegBalance = text . FormatNegBalance

formatTrue :: String -> ConsolePrinter
formatTrue = text . FormatTrue

formatFalse :: String -> ConsolePrinter
formatFalse = text . FormatFalse

formatWarn :: String -> ConsolePrinter
formatWarn = text . FormatWarn

formatError :: String -> ConsolePrinter
formatError = text . FormatError

formatSGR :: ConsoleFormat -> [SGR]
formatSGR frm = case frm of
    FormatTitle _      -> [ SetConsoleIntensity BoldIntensity ]
    FormatStatic _     -> []
    FormatAccount _    -> [ SetConsoleIntensity BoldIntensity
                          , SetColor Foreground Dull White
                          ]
    FormatPubKey _     -> [ SetColor Foreground Dull Magenta ]
    FormatFilePath _   -> [ SetItalicized True
                          , SetColor Foreground Dull White
                          ]
    FormatKey _        -> []
    FormatDeriv _      -> []
    FormatMnemonic _   -> [ SetConsoleIntensity BoldIntensity
                          , SetColor Foreground Dull Cyan
                          ]
    FormatAddress _    -> [ SetConsoleIntensity BoldIntensity
                          , SetColor Foreground Dull Blue
                          ]
    FormatTxHash _     -> [ SetColor Foreground Dull Magenta ]
    FormatPosBalance _ -> [ SetConsoleIntensity BoldIntensity
                          , SetColor Foreground Dull Green
                          ]
    FormatNegBalance _ -> [ SetConsoleIntensity BoldIntensity
                          , SetColor Foreground Dull Red
                          ]
    FormatTrue _       -> [ SetConsoleIntensity BoldIntensity
                          , SetColor Foreground Dull Green
                          ]
    FormatFalse _      -> [ SetConsoleIntensity BoldIntensity
                          , SetColor Foreground Dull Red
                          ]
    FormatWarn _       -> [ SetColor Foreground Dull Yellow ]
    FormatError _      -> [ SetColor Foreground Dull Red ]

printFormat :: ConsoleFormat -> IO ()
printFormat f = do
    setSGR $ formatSGR f
    putStr $ getFormat f
    setSGR []

consoleError :: ConsolePrinter -> a
consoleError prt = unsafePerformIO $ renderIO prt >> exitFailure

