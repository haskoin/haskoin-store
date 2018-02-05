{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE NoImplicitPrelude         #-}
{-# LANGUAGE OverloadedStrings         #-}
module Network.Haskoin.Wallet.HTTP where

import           Control.Arrow                           ((&&&))
import           Control.Lens                            ((&), (.~), (^.))
import           Data.List                               (sum)
import           Data.Map.Strict                         (Map)
import qualified Data.Map.Strict                         as Map
import           Foundation
import           Network.Haskoin.Crypto
import           Network.Haskoin.Script
import           Network.Haskoin.Transaction
import           Network.Haskoin.Wallet.Amounts
import           Network.Haskoin.Wallet.ConsolePrinter
import           Network.Haskoin.Wallet.FoundationCompat
import           Network.HTTP.Types.Status
import qualified Network.Wreq                            as HTTP
import           Network.Wreq.Types                      (ResponseChecker)

data AddressTx = AddressTx
    { addrTxAddress :: !Address
    , addrTxTxHash  :: !TxHash
    , addrTxAmount  :: !Integer
    , addrTxHeight  :: !Natural
    }
    deriving (Eq, Show)

data TxMovement = TxMovement
    { txMovementTxHash   :: !TxHash
    , txMovementInbound  :: Map Address Satoshi
    , txMovementMyInputs :: Map Address Satoshi
    , txMovementAmount   :: !Integer
    , txMovementHeight   :: !Natural
    }
    deriving (Eq, Show)

mergeAddressTxs :: [AddressTx] -> [TxMovement]
mergeAddressTxs as =
    sortBy (compare `on` txMovementHeight) $ mapMaybe toMvt $ Map.assocs aMap
  where
    aMap :: Map TxHash [AddressTx]
    aMap = Map.fromListWith (<>) $ fmap (addrTxTxHash &&& (: [])) as
    toMvt :: (TxHash, [AddressTx]) -> Maybe TxMovement
    toMvt (tid, atxs) =
        case head <$> nonEmpty atxs of
            Just a ->
                let (os, is) = partition ((< 0) . addrTxAmount) atxs
                in Just TxMovement
                     { txMovementTxHash = tid
                     , txMovementInbound = toAddrMap is
                     , txMovementMyInputs = toAddrMap os
                     , txMovementAmount = sum $ fmap addrTxAmount atxs
                     , txMovementHeight = addrTxHeight a
                     }
            _ -> Nothing
    toAddrMap :: [AddressTx] -> Map Address Satoshi
    toAddrMap = Map.fromListWith (+) . fmap toAddrVal
    toAddrVal :: AddressTx -> (Address, Satoshi)
    toAddrVal = addrTxAddress &&& fromIntegral . abs . addrTxAmount

data BlockchainService = BlockchainService
    { httpBalance    :: [Address] -> IO Satoshi
    , httpUnspent    :: [Address] -> IO [(OutPoint, ScriptOutput, Satoshi)]
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
                  , formatKey (block 10 "Message:") <>
                    formatStatic
                        (fromMaybe "Could not decode the message" $
                         bsToString message)
                  ]
            ]
  where
    code = r ^. HTTP.responseStatus . HTTP.statusCode
    message = r ^. HTTP.responseStatus . HTTP.statusMessage
    status = mkStatus code message

options :: HTTP.Options
options = HTTP.defaults & HTTP.checkResponse .~ Just checkStatus

