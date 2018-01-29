{-# LANGUAGE ExistentialQuantification #-}
module Network.Haskoin.Wallet.HTTP where

import           Control.Arrow                         ((&&&))
import           Control.Lens                          ((&), (.~), (^.))
import           Data.List
import qualified Data.Map.Strict                       as M
import           Data.Monoid                           ((<>))
import           Data.String.Conversions               (cs)
import           Data.Word
import           Network.Haskoin.Block
import           Network.Haskoin.Crypto
import           Network.Haskoin.Script
import           Network.Haskoin.Transaction
import           Network.Haskoin.Wallet.ConsolePrinter
import           Network.HTTP.Types.Status
import qualified Network.Wreq                          as HTTP
import           Network.Wreq.Types                    (ResponseChecker)

data AddressTx = AddressTx
    { addrTxAddress :: !Address
    , addrTxTxHash  :: !TxHash
    , addrTxAmount  :: !Integer
    , addrTxBlock   :: !BlockHash
    , addrTxHeight  :: !Integer
    }
    deriving (Eq, Show)

data TxMovement = TxMovement
    { txMovementTxHash     :: !TxHash
    , txMovementInAddress  :: [(Address, Word64)]
    , txMovementOutAddress :: [(Address, Word64)]
    , txMovementAmount     :: !Integer
    , txMovementHeight     :: !Integer
    }
    deriving (Eq, Show)

mergeAddressTxs :: [AddressTx] -> [TxMovement]
mergeAddressTxs as =
    sortOn txMovementHeight $ map toMvt $ M.assocs aMap
  where
    aMap :: M.Map TxHash [AddressTx]
    aMap = M.fromListWith (<>) $ map (addrTxTxHash &&& (:[])) as
    toMvt :: (TxHash, [AddressTx]) -> TxMovement
    toMvt (tid, atxs) =
        let (is,os) = partition ((< 0) . addrTxAmount) atxs
         in TxMovement
            { txMovementTxHash = tid
            , txMovementInAddress = combineAddrs is
            , txMovementOutAddress = combineAddrs os
            , txMovementAmount = sum $ map addrTxAmount atxs
            , txMovementHeight = addrTxHeight $ head atxs
            }
    combineAddrs :: [AddressTx] -> [(Address, Word64)]
    combineAddrs = sortOn snd . M.assocs . M.fromListWith (+) . map toAddrVal
    toAddrVal :: AddressTx -> (Address, Word64)
    toAddrVal = addrTxAddress &&& fromIntegral . abs . addrTxAmount

data BlockchainService = BlockchainService
    { httpBalance    :: [Address] -> IO Word64
    , httpUnspent    :: [Address] -> IO [(OutPoint, ScriptOutput, Word64)]
    , httpAddressTxs :: [Address] -> IO [AddressTx]
    , httpTx         :: TxHash -> IO Tx
    , httpBroadcast  :: Tx -> IO ()
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

