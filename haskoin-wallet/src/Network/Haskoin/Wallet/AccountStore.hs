{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE OverloadedStrings #-}
module Network.Haskoin.Wallet.AccountStore where

import           Control.Monad
import qualified Data.Aeson                            as J
import           Data.Aeson.TH
import qualified Data.ByteString                       as BS
import           Data.ByteString.Base16                as B16
import qualified Data.ByteString.Lazy                  as BL
import qualified Data.Map.Strict                       as M
import           Data.Monoid                           ((<>))
import qualified Data.Serialize                        as S
import           Data.String.Conversions               (cs)
import           Data.Text                             (Text)
import           Network.Haskoin.Constants
import           Network.Haskoin.Crypto
import           Network.Haskoin.Util
import           Network.Haskoin.Wallet.ConsolePrinter
import qualified Network.Haskoin.Wallet.PrettyJson     as Pretty
import qualified System.Directory                      as D

type AccountsFile = M.Map Text AccountStore

data AccountStore = AccountStore
    { accountStoreXPubKey  :: !XPubKey
    , accountStoreExternal :: !KeyIndex
    , accountStoreInternal :: !KeyIndex
    , accountStoreDeriv    :: !HardPath
    }
    deriving (Eq, Show)

$(deriveJSON (dropFieldLabel 12) ''AccountStore)

extDeriv, intDeriv :: SoftPath
extDeriv = Deriv :/ 0
intDeriv = Deriv :/ 1

accountsFile :: IO FilePath
accountsFile = do
    hwDir <- D.getAppUserDataDirectory "hw"
    let dir = hwDir <> "/" <> networkName
    D.createDirectoryIfMissing True dir
    return $ dir <> "/accounts.json"

readAccountsFile :: IO AccountsFile
readAccountsFile = do
    file <- accountsFile
    exists <- D.doesFileExist file
    unless exists $ writeAccountsFile M.empty
    bs <- BL.readFile file
    maybe err return $ J.decode bs
  where
    err = consoleError $ formatError "Could not decode accounts file"

writeAccountsFile :: AccountsFile -> IO ()
writeAccountsFile dat = do
    file <- accountsFile
    BL.writeFile file $ Pretty.encodePretty dat <> "\n"

newAccountStore :: AccountStore -> IO Text
newAccountStore store = do
    accMap <- readAccountsFile
    let xpubs = map accountStoreXPubKey $ M.elems accMap
        key | M.null accMap = "main"
            | otherwise     = cs $ xPubChecksum $ accountStoreXPubKey store
    when (accountStoreXPubKey store `elem` xpubs) $
        consoleError $ formatError "This public key is already being watched"
    let f Nothing = Just store
        f _       = consoleError $ formatError "The account name already exists"
    writeAccountsFile $ M.alter f key accMap
    return key

getAccountStore :: Text -> IO (Maybe AccountStore)
getAccountStore key = M.lookup key <$> readAccountsFile

updateAccountStore :: Text -> (AccountStore -> AccountStore) -> IO ()
updateAccountStore key f = do
    accMap <- readAccountsFile
    let g Nothing  = consoleError $ formatError $
            "The account " <> cs key <> " does not exist"
        g (Just s) = Just $ f s
    writeAccountsFile $ M.alter g key accMap

renameAccountStore :: Text -> Text -> IO ()
renameAccountStore oldName newName
    | oldName == newName =
        consoleError $ formatError "Both old and new names are the same"
    | otherwise = do
        accMap <- readAccountsFile
        case M.lookup oldName accMap of
            Just store -> do
                when (M.member newName accMap) $
                    consoleError $ formatError "New account name already exists"
                writeAccountsFile $
                    M.insert newName store $ M.delete oldName accMap
            _ -> consoleError $ formatError "Old account does not exist"

xPubChecksum :: XPubKey -> BS.ByteString
xPubChecksum = B16.encode . S.encode . xPubFP

nextExtAddress :: AccountStore -> ((Address, SoftPath, KeyIndex), AccountStore)
nextExtAddress store =
    ( ( fst $ derivePathAddr (accountStoreXPubKey store) extDeriv idx
      , extDeriv :/ idx
      , idx
      )
    , store{ accountStoreExternal = idx + 1 }
    )
  where
    idx = accountStoreExternal store

nextIntAddress :: AccountStore -> ((Address, SoftPath, KeyIndex), AccountStore)
nextIntAddress store =
    ( ( fst $ derivePathAddr (accountStoreXPubKey store) intDeriv idx
      , intDeriv :/ idx
      , idx
      )
    , store{ accountStoreInternal = idx + 1 }
    )
  where
    idx  = accountStoreInternal store

allExtAddresses :: AccountStore -> [(Address, SoftPath)]
allExtAddresses store =
    map (\(a,_,i) -> (a, extDeriv :/ i)) extAddrs
  where
    xpub     = accountStoreXPubKey store
    extI     = fromIntegral $ accountStoreExternal store
    extAddrs = take extI $ derivePathAddrs xpub extDeriv 0

allIntAddresses :: AccountStore -> [(Address, SoftPath)]
allIntAddresses store = 
    map (\(a,_,i) -> (a, intDeriv :/ i)) intAddrs
  where
    xpub     = accountStoreXPubKey store
    intI     = fromIntegral $ accountStoreInternal store
    intAddrs = take intI $ derivePathAddrs xpub intDeriv 0

