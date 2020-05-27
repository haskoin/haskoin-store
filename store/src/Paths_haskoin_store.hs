module Paths_haskoin_store where

import           Data.Version                 (Version, parseVersion)
import           Text.ParserCombinators.ReadP (readP_to_S)


version :: Version
version = fst (head (readP_to_S parseVersion "0.0.0"))
