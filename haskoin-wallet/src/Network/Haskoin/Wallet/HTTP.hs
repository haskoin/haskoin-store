{-# LANGUAGE ExistentialQuantification #-}
module Network.Haskoin.Wallet.HTTP where

import           Control.Lens                          ((&), (.~), (^.))
import           Data.Monoid                           ((<>))
import           Data.String.Conversions               (cs)
import           Data.Word
import           Network.Haskoin.Crypto
import           Network.Haskoin.Script
import           Network.Haskoin.Transaction
import           Network.Haskoin.Wallet.ConsolePrinter
import           Network.HTTP.Types.Status
import qualified Network.Wreq                          as HTTP
import           Network.Wreq.Types                    (ResponseChecker)

data BlockchainService = BlockchainService
    { httpBalance   :: [Address] -> IO Word64
    , httpUnspent   :: [Address] -> IO [(OutPoint, ScriptOutput, Word64)]
    , httpTx        :: TxHash -> IO Tx
    , httpBroadcast :: Tx -> IO ()
    }

checkStatus :: ResponseChecker
checkStatus _ r
    | statusIsSuccessful status = return ()
    | otherwise =
        consoleError $
        vcat
            [ formatError "Received an HTTP error response:"
            , nest 4 $
              vcat
                  [ formatKey (block 10 "Status:") <> formatError (show code)
                  , formatKey (block 10 "Message:") <> formatStatic (cs message)
                  ]
            ]
  where
    code = r ^. HTTP.responseStatus . HTTP.statusCode
    message = r ^. HTTP.responseStatus . HTTP.statusMessage
    status = mkStatus code message

options :: HTTP.Options
options = HTTP.defaults & HTTP.checkResponse .~ Just checkStatus

