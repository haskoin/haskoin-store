{-# LANGUAGE ExistentialQuantification #-}
module Network.Haskoin.Wallet.HTTP where

import           Data.Word
import           Network.Haskoin.Crypto
import           Network.Haskoin.Script
import           Network.Haskoin.Transaction

data HTTPNet
    = HTTPProdnet
    | HTTPTestnet
    deriving (Eq)

data BlockchainService = BlockchainService
    { httpBalance   :: HTTPNet -> [Address] -> IO Word64
    , httpUnspent   :: HTTPNet -> [Address]
                    -> IO [(OutPoint, ScriptOutput, Word64)]
    , httpTx        :: HTTPNet -> TxHash -> IO Tx
    , httpBroadcast :: HTTPNet -> Tx -> IO ()
    }

