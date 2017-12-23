{-# LANGUAGE CPP #-}
module Network.Haskoin.Wallet.PrettyJson
( encodePretty )
where

import           Data.Aeson               (ToJSON)
import           Data.Aeson.Encode.Pretty as Export (Config (..), Indent (..),
                                                     defConfig, encodePretty')
import qualified Data.ByteString.Lazy     as BL

encodePretty :: ToJSON a => a -> BL.ByteString
encodePretty = encodePretty' defConfig{ confIndent = Spaces 2 }

