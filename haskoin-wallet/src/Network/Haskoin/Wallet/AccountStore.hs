{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
module Network.Haskoin.Wallet.AccountStore where

import           Control.Monad                           (unless, when)
import           Data.Aeson.TH
import           Data.Map.Strict                         (Map)
import qualified Data.Map.Strict                         as Map
import           Data.Text                               (Text)
import           Foundation
import           Foundation.Compat.Text
import           Foundation.IO
import           Foundation.VFS
import           Network.Haskoin.Constants
import           Network.Haskoin.Crypto
import           Network.Haskoin.Util
import           Network.Haskoin.Wallet.ConsolePrinter
import           Network.Haskoin.Wallet.FoundationCompat
import qualified System.Directory                        as D

data AccountStore = AccountStore
    { accountStoreXPubKey  :: !XPubKey
    , accountStoreExternal :: !Natural
    , accountStoreInternal :: !Natural
    , accountStoreDeriv    :: !HardPath
    }
    deriving (Eq, Show)

$(deriveJSON (dropFieldLabel 12) ''AccountStore)

type AccountsFile = Map Text AccountStore

extDeriv, intDeriv :: SoftPath
extDeriv = Deriv :/ 0
intDeriv = Deriv :/ 1

accountsFile :: IO FilePath
accountsFile = do
    hwDir <- fromString <$> D.getAppUserDataDirectory "hw"
    let dir = hwDir </> fromString networkName
    D.createDirectoryIfMissing True $ filePathToLString dir
    return $ dir </> "accounts.json"

readAccountsFile :: IO AccountsFile
readAccountsFile = do
    file <- accountsFile
    exists <- D.doesFileExist $ filePathToLString file
    unless exists $ writeAccountsFile Map.empty
    bytes <- readFile file
    maybe err return $ decodeJson bytes
  where
    err = consoleError $ formatError "Could not decode accounts file"

writeAccountsFile :: AccountsFile -> IO ()
writeAccountsFile dat = do
    file <- accountsFile
    withFile file WriteMode $ \h ->
        hPut h $ encodeJsonPretty dat <> stringToBytes "\n"

newAccountStore :: AccountStore -> IO String
newAccountStore store = do
    accMap <- readAccountsFile
    let xpubs = accountStoreXPubKey <$> Map.elems accMap
        key
            | Map.null accMap = "main"
            | otherwise = xPubChecksum $ accountStoreXPubKey store
    when (accountStoreXPubKey store `elem` xpubs) $
        consoleError $ formatError "This public key is already being watched"
    let f Nothing = Just store
        f _ = consoleError $ formatError "The account name already exists"
    writeAccountsFile $ Map.alter f (toText key) accMap
    return key

getAccountStore :: String -> IO (Maybe AccountStore)
getAccountStore key = Map.lookup (toText key) <$> readAccountsFile

updateAccountStore :: String -> (AccountStore -> AccountStore) -> IO ()
updateAccountStore key f = do
    accMap <- readAccountsFile
    let g Nothing  = consoleError $ formatError $
            "The account " <> key <> " does not exist"
        g (Just s) = Just $ f s
    writeAccountsFile $ Map.alter g (toText key) accMap

renameAccountStore :: String -> String -> IO ()
renameAccountStore oldName newName
    | oldName == newName =
        consoleError $ formatError "Both old and new names are the same"
    | otherwise = do
        accMap <- readAccountsFile
        case Map.lookup (toText oldName) accMap of
            Just store -> do
                when (Map.member (toText newName) accMap) $
                    consoleError $ formatError "New account name already exists"
                writeAccountsFile $
                    Map.insert (toText newName) store $
                    Map.delete (toText oldName) accMap
            _ -> consoleError $ formatError "Old account does not exist"

xPubChecksum :: XPubKey -> String
xPubChecksum = encodeHexStr . encodeBytes . xPubFP

nextExtAddress :: AccountStore -> ((Address, SoftPath, Natural), AccountStore)
nextExtAddress store =
    ( ( fst $ derivePathAddr (accountStoreXPubKey store) extDeriv idx
      , extDeriv :/ idx
      , nat
      )
    , store{ accountStoreExternal = nat + 1 }
    )
  where
    nat = accountStoreExternal store
    idx = fromIntegral nat

nextIntAddress :: AccountStore -> ((Address, SoftPath, Natural), AccountStore)
nextIntAddress store =
    ( ( fst $ derivePathAddr (accountStoreXPubKey store) intDeriv idx
      , intDeriv :/ idx
      , nat
      )
    , store{ accountStoreInternal = nat + 1 }
    )
  where
    nat = accountStoreInternal store
    idx = fromIntegral nat

allExtAddresses :: AccountStore -> [(Address, SoftPath)]
allExtAddresses store =
    fmap (\(a,_,i) -> (a, extDeriv :/ i)) extAddrs
  where
    xpub     = accountStoreXPubKey store
    extI     = fromIntegral $ accountStoreExternal store
    extAddrs = take extI $ derivePathAddrs xpub extDeriv 0

allIntAddresses :: AccountStore -> [(Address, SoftPath)]
allIntAddresses store =
    fmap (\(a,_,i) -> (a, intDeriv :/ i)) intAddrs
  where
    xpub     = accountStoreXPubKey store
    intI     = fromIntegral $ accountStoreInternal store
    intAddrs = take intI $ derivePathAddrs xpub intDeriv 0

