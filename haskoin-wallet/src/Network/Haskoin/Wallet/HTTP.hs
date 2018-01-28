{-# LANGUAGE ExistentialQuantification #-}
module Network.Haskoin.Wallet.HTTP where

import           Data.Word
import           Network.Haskoin.Crypto
import           Network.Haskoin.Script
import           Network.Haskoin.Transaction

data BlockchainService = BlockchainService
    { httpBalance   :: [Address] -> IO Word64
    , httpUnspent   :: [Address] -> IO [(OutPoint, ScriptOutput, Word64)]
    , httpTx        :: TxHash -> IO Tx
    , httpBroadcast :: Tx -> IO ()
    }

