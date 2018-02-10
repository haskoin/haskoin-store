{-# LANGUAGE BangPatterns              #-}
{-# LANGUAGE NoImplicitPrelude         #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE TemplateHaskell           #-}
module Network.Haskoin.Wallet where

import           Control.Arrow                              (right, (&&&))
import           Control.Monad                              (unless, when)
import qualified Data.Aeson                                 as Json
import           Data.Aeson.TH
import           Data.List                                  (sortOn)
import qualified Data.Map.Strict                            as Map
import           Data.Text                                  (Text)
import           Foundation
import           Foundation.Collection
import           Foundation.Compat.Text
import           Foundation.IO
import           Foundation.String
import           Foundation.VFS
import           Network.Haskoin.Constants
import           Network.Haskoin.Crypto                     hiding
                                                             (addrToBase58,
                                                             base58ToAddr,
                                                             xPubExport)
import           Network.Haskoin.Transaction                hiding (txHashToHex)
import           Network.Haskoin.Util                       (dropFieldLabel)
import           Network.Haskoin.Wallet.AccountStore
import           Network.Haskoin.Wallet.Amounts
import           Network.Haskoin.Wallet.ConsolePrinter
import           Network.Haskoin.Wallet.Entropy
import           Network.Haskoin.Wallet.FoundationCompat
import           Network.Haskoin.Wallet.HTTP
import           Network.Haskoin.Wallet.HTTP.BlockchainInfo
import           Network.Haskoin.Wallet.HTTP.Haskoin
import           Network.Haskoin.Wallet.HTTP.Insight
import           Network.Haskoin.Wallet.Signing
import           Network.Haskoin.Wallet.TxInformation
import qualified System.Console.Argument                    as Argument
import           System.Console.Command
import qualified System.Console.Haskeline                   as Haskeline
import           System.Console.Program                     (showUsage, single)
import qualified System.Directory                           as D

data DocStructure a = DocStructure
    { docStructureNetwork :: !Text
    , docStructurePayload :: !a
    } deriving (Eq, Show)

$(deriveJSON (dropFieldLabel 12) ''DocStructure)

clientMain :: IO ()
clientMain = single hwCommands

hwCommands :: Commands IO
hwCommands =
    Node
        hw
        [ Node mnemonic []
        , Node pubkey []
        , Node watch []
        , Node rename []
        , Node receive []
        , Node addresses []
        , Node balance []
        , Node transactions []
        , Node send []
        , Node sign []
        , Node broadcast []
        , Node help []
        ]

hw :: Command IO
hw = command "hw" "bitcoin wallet management" $ io $ showUsage hwCommands

entOpt :: Argument.Option Natural
entOpt =
    Argument.option
        ['e']
        ["entropy"]
        (fromIntegral <$> Argument.natural)
        16
        "Entropy in bytes to generate the mnemonic [16,20..32]"

diceOpt :: Argument.Option Bool
diceOpt =
    Argument.option
        ['d']
        ["dice"]
        Argument.boolean
        False
        "Provide additional entropy from 6-sided dice rolls"

mnemonic :: Command IO
mnemonic =
    command "mnemonic" "Generate a mnemonic" $
    withOption entOpt $ \reqEnt ->
    withOption diceOpt $ \useDice ->
        io $ do
            let ent = fromIntegral reqEnt
            mnemE <-
                if useDice
                    then genMnemonicDice ent =<< askDiceRolls ent
                    else genMnemonic ent
            case right (second bsToString) mnemE of
                Right (orig, Just ms) ->
                    renderIO $
                    vcat
                        [ formatTitle "System Entropy Source"
                        , nest 4 $ formatFilePath orig
                        , formatTitle "Private Mnemonic"
                        , nest 4 $ mnemonicPrinter 4 (words ms)
                        ]
                Right _ ->
                    consoleError $
                    formatError "There was a problem generating the mnemonic"
                Left err -> consoleError $ formatError err
  where
    askDiceRolls reqEnt =
        askInputLine $
        "Enter your " <> show (requiredRolls reqEnt) <> " dice rolls: "

mnemonicPrinter :: CountOf (Natural, String) -> [String] -> ConsolePrinter
mnemonicPrinter n ws =
    vcat $
    fmap (mconcat . fmap formatWord) $ groupIn n $ zip ([1 ..] :: [Natural]) ws
  where
    formatWord (i, w) =
        mconcat
            [formatKey $ block 4 $ show i <> ".", formatMnemonic $ block 10 w]

derOpt :: Argument.Option Natural
derOpt =
    Argument.option
        ['d']
        ["deriv"]
        (fromIntegral <$> Argument.natural)
        0
        "Bip44 account derivation"

netOpt :: Argument.Option String
netOpt =
    Argument.option
        ['n']
        ["network"]
        (fromLString <$> Argument.string)
        "bitcoin"
        "Set the network (=bitcoin|testnet3|bitcoincash|cashtest)"

unitOpt :: Argument.Option String
unitOpt =
    Argument.option
        ['u']
        ["unit"]
        (fromLString <$> Argument.string)
        "bitcoin"
        "Set the units for amounts (=bitcoin|bit|satoshi)"

parseUnit :: String -> AmountUnit
parseUnit unit =
    case unit of
        "bitcoin" -> UnitBitcoin
        "bit" -> UnitBit
        "satoshi" -> UnitSatoshi
        _ ->
            consoleError $
            vcat
                [ formatError "Invalid unit value. Choose one of:"
                , nest 4 $
                  vcat $ fmap formatStatic ["bitcoin", "bit", "satoshi"]
                ]

setOptNet :: String -> IO ()
setOptNet name
    | name == fromLString (getNetworkName bitcoinNetwork) = do
        setBitcoinNetwork
        renderIO $ formatBitcoin "--- Bitcoin ---"
    | name == fromLString (getNetworkName bitcoinCashNetwork) = do
        setBitcoinCashNetwork
        renderIO $ formatCash "--- Bitcoin Cash ---"
    | name == fromLString (getNetworkName testnet3Network) = do
        setTestnet3Network
        renderIO $ formatTestnet "--- Testnet ---"
    | name == fromLString (getNetworkName cashTestNetwork) = do
        setCashTestNetwork
        renderIO $ formatTestnet "--- Bitcoin Cash Testnet ---"
    | otherwise =
        consoleError $
        vcat
            [ formatError "Invalid network name. Select one of the following:"
            , nest 4 $
              vcat $
              fmap
                  (formatStatic . fromLString)
                  [ getNetworkName bitcoinNetwork
                  , getNetworkName bitcoinCashNetwork
                  , getNetworkName testnet3Network
                  , getNetworkName cashTestNetwork
                  ]
            ]

serOpt :: Argument.Option String
serOpt =
    Argument.option
        ['s']
        ["service"]
        (fromLString <$> Argument.string)
        ""
        "Blockchain service (=haskoin|blockchain|insight)"

parseBlockchainService :: String -> Service
parseBlockchainService service =
    case service of
        "" -> defaultBlockchainService
        "haskoin" -> Service HaskoinService
        "blockchain" -> Service BlockchainInfoService
        "insight" -> Service InsightService
        _ ->
            consoleError $
            vcat
                [ formatError
                      "Invalid service name. Select one of the following:"
                , nest 4 $
                  vcat $ fmap formatStatic ["haskoin", "blockchain", "insight"]
                ]

defaultBlockchainService :: Service
defaultBlockchainService
    | getNetwork == bitcoinNetwork = Service BlockchainInfoService
    | getNetwork == testnet3Network = Service HaskoinService
    | getNetwork == bitcoinCashNetwork = Service HaskoinService
    | getNetwork == cashTestNetwork = Service HaskoinService
    | otherwise = consoleError $ formatError $
        "No blockchain service for network " <> fromLString networkName

pubkey :: Command IO
pubkey =
    command "pubkey" "Derive a public key from a mnemonic" $
    withOption derOpt $ \deriv ->
    withOption netOpt $ \network ->
        io $ do
            setOptNet network
            xpub <- deriveXPubKey <$> askSigningKey (fromIntegral deriv)
            let fname = fromString $ "key-" <> toLString (xPubChecksum xpub)
            path <- writeDoc fname $ toText $ xPubExport xpub
            renderIO $
                vcat
                    [ formatTitle "Public Key"
                    , nest 4 $ formatPubKey $ xPubExport xpub
                    , formatTitle "Derivation"
                    , nest 4 $
                      formatDeriv $
                      show $
                      ParsedPrv $
                      toGeneric $ bip44Deriv deriv
                    , formatTitle "Public Key File"
                    , nest 4 $ formatFilePath $ filePathToString path
                    ]

watch :: Command IO
watch =
    command "watch" "Create a new read-only account from an xpub file" $
    withOption netOpt $ \network ->
    withNonOption Argument.file $ \fp ->
        io $ do
            setOptNet network
            xpub <- readDoc $ fromString fp :: IO XPubKey
            let store =
                    AccountStore
                        xpub
                        0
                        0
                        (bip44Deriv $ fromIntegral $ xPubChild xpub)
            name <- newAccountStore store
            renderIO $
                vcat
                    [ formatTitle "New Account Created"
                    , nest 4 $
                      vcat
                          [ formatKey (block 13 "Name:") <>
                            formatAccount name
                          , formatKey (block 13 "Derivation:") <>
                            formatDeriv
                                (show $
                                  ParsedPrv $
                                  toGeneric $ accountStoreDeriv store)
                          ]
                    ]

rename :: Command IO
rename =
    command "rename" "Rename an account" $
    withOption netOpt $ \network ->
    withNonOption Argument.string $ \oldName ->
    withNonOption Argument.string $ \newName ->
        io $ do
            setOptNet network
            renameAccountStore
                (fromLString oldName)
                (fromLString newName)
            renderIO $
                formatStatic "Account" <+>
                formatAccount (fromLString oldName) <+>
                formatStatic "renamed to" <+>
                formatAccount (fromLString newName)

accOpt :: Argument.Option String
accOpt =
    Argument.option
        ['a']
        ["account"]
        (fromLString <$> Argument.string)
        ""
        "Account name"

receive :: Command IO
receive =
    command "receive" "Generate a new address to receive coins" $
    withOption accOpt $ \acc ->
    withOption netOpt $ \network ->
        io $ do
            setOptNet network
            withAccountStore acc $ \(k, store) -> do
                let (addr, store') = nextExtAddress store
                updateAccountStore k $ const store'
                renderIO $
                    addressFormat $ nonEmpty_ [(thd &&& fst) addr]

cntOpt :: Argument.Option Natural
cntOpt =
    Argument.option
        ['i']
        ["number"]
        (fromIntegral <$> Argument.natural)
        5
        "Number of addresses to display"

addresses :: Command IO
addresses =
    command "addresses" "Display historical addresses" $
    withOption accOpt $ \acc ->
    withOption cntOpt $ \cnt ->
    withOption netOpt $ \network ->
        io $ do
            setOptNet network
            withAccountStore acc $ \(_, store) -> do
                let xpub = accountStoreXPubKey store
                    idx = accountStoreExternal store
                    start = fromMaybe 0 (idx - cnt)
                    count = fromIntegral $ fromMaybe 0 (idx - start)
                let addrsM =
                        nonEmpty $
                        take count $
                        derivePathAddrs xpub extDeriv $
                        fromIntegral start
                case addrsM of
                    Just addrs ->
                        renderIO $
                        addressFormat $
                        nonEmptyFmap (fromIntegral . thd &&& fst) addrs
                    _ ->
                        consoleError $
                        formatError "No addresses have been generated"

addressFormat :: NonEmpty [(Natural, Address)] -> ConsolePrinter
addressFormat as = vcat $ getNonEmpty $ nonEmptyFmap toFormat as
  where
    toFormat :: (Natural, Address) -> ConsolePrinter
    toFormat (i, a) =
        mconcat
            [ formatKey $ block (n + 2) $ show i <> ":"
            , formatAddress $ addrToBase58 a
            ]
    n = length $ show $ maximum $ nonEmptyFmap fst as

feeOpt :: Argument.Option Satoshi
feeOpt =
    Argument.option
        ['f']
        ["fee"]
        (fromIntegral <$> Argument.natural)
        200
        "Fee per byte"

dustOpt :: Argument.Option Satoshi
dustOpt =
    Argument.option
        ['d']
        ["dust"]
        (fromIntegral <$> Argument.natural)
        5430
        "Do not create change outputs below this value"

send :: Command IO
send =
    command "send" "Send coins (hw send address amount [address amount..])" $
    withOption accOpt $ \acc ->
    withOption feeOpt $ \feeByte ->
    withOption dustOpt $ \dust ->
    withOption unitOpt $ \u ->
    withOption netOpt $ \network ->
    withOption serOpt $ \s ->
    withNonOptions Argument.string $ \as ->
        io $ do
            setOptNet network
            withAccountStore acc $ \(k, store) -> do
                let !unit = parseUnit u
                    !rcps =
                        Map.fromList $
                        fromMaybe rcptErr $ mapM (toRecipient unit) $
                        groupIn 2 $ fmap fromLString as
                    service = parseBlockchainService s
                resE <- buildTxSignData service store rcps feeByte dust
                let (!signDat, !store') =
                        either (consoleError . formatError) id resE
                    infoE = pubTxInformation signDat (accountStoreXPubKey store)
                    !info =
                        either (consoleError . formatError) id infoE
                when (store /= store') $ updateAccountStore k $ const store'
                let chsum = txChksum $ txSignDataTx signDat
                    fname =
                        fromString $ "tx-" <> toLString chsum <> "-unsigned"
                path <- writeDoc fname signDat
                renderIO $
                    vcat
                        [ txInformationFormat
                            (accountStoreDeriv store)
                            unit
                            (Just False)
                            Nothing
                            info
                        , formatTitle "Unsigned Tx Data File"
                        , nest 4 $ formatFilePath $ filePathToString path
                        ]
  where
    rcptErr = consoleError $ formatError "Could not parse the recipients"

txChksum :: Tx -> String
txChksum = take 16 . txHashToHex . nosigTxHash

groupIn :: Sequential c => CountOf (Element c) -> c -> [c]
groupIn n xs
    | length xs <= n = [xs]
    | otherwise = [take n xs] <> groupIn n (drop n xs)

toRecipient :: AmountUnit -> [String] -> Maybe (Address, Satoshi)
toRecipient unit [a, v] = (,) <$> base58ToAddr a <*> readAmount unit v
toRecipient _ _         = Nothing

sign :: Command IO
sign = command "sign" "Sign the output of the \"send\" command" $
    withOption derOpt $ \d ->
    withOption unitOpt $ \u ->
    withOption netOpt $ \network ->
    withNonOption Argument.file $ \fp ->
        io $ do
            setOptNet network
            let !unit = parseUnit u
            dat <- readDoc $ fromString fp :: IO TxSignData
            signKey <- askSigningKey $ fromIntegral d
            case signWalletTx dat signKey of
                Right (info, signedTx, isSigned) -> do
                    renderIO $
                        txInformationFormat
                            (bip44Deriv d)
                            unit
                            (Just isSigned)
                            Nothing
                            info
                    confirmAmount unit $ txInformationAmount info
                    let signedHex = encodeHexText $ encodeBytes signedTx
                        chsum = txChksum signedTx
                        fname =
                            fromString $
                            "tx-" <> toLString chsum <> "-signed"
                    path <- writeDoc fname signedHex
                    renderIO $ vcat
                        [ formatTitle "Signed Tx File"
                        , nest 4 $ formatFilePath $ filePathToString path
                        ]
                Left err -> consoleError $ formatError err
  where
    confirmAmount :: AmountUnit -> Integer -> IO ()
    confirmAmount unit txAmnt = do
        userAmnt <- askInputLine "Type the tx amount to continue signing: "
        when (readIntegerAmount unit userAmnt /= Just txAmnt) $ do
            renderIO $ formatError "Invalid tx amount"
            confirmAmount unit txAmnt

balance :: Command IO
balance =
    command "balance" "Display the account balance" $
    withOption accOpt $ \acc ->
    withOption unitOpt $ \u ->
    withOption netOpt $ \network ->
    withOption serOpt $ \s ->
        io $ do
            setOptNet network
            let !unit = parseUnit u
            withAccountStore acc $ \(_, store) -> do
                let service = parseBlockchainService s
                    addrs =
                        allExtAddresses store <>
                        allIntAddresses store
                bal <- httpBalance service $ fmap fst addrs
                renderIO $
                    vcat
                        [ formatTitle "Account Balance"
                        , nest 4 $ formatAmount unit bal
                        ]

verbOpt :: Argument.Option Bool
verbOpt =
    Argument.option
        ['v']
        ["verbose"]
        Argument.boolean
        False
        "Produce a more detailed output"

transactions :: Command IO
transactions = command "transactions" "Display the account transactions" $
    withOption accOpt $ \acc ->
    withOption unitOpt $ \u ->
    withOption netOpt $ \network ->
    withOption serOpt $ \s ->
    withOption verbOpt $ \verbose ->
        io $ do
            setOptNet network
            let !unit = parseUnit u
            withAccountStore acc $ \(_, store) -> do
                let service = parseBlockchainService s
                    walletAddrs = allExtAddresses store <> allIntAddresses store
                    walletAddrMap = Map.fromList walletAddrs
                mvts <- httpTxInformation service $ fmap fst walletAddrs
                currHeight <- httpBestHeight service
                forM_ (sortOn txInformationHeight mvts) $ \mvt -> do
                    let format =
                            if verbose
                                then txInformationFormat
                                else txInformationFormatCompact
                        mvtPath = txInformationFillPath walletAddrMap mvt
                        mvtTxF = flip txInformationFillTx mvtPath
                    mvtTx <-
                        maybe
                            (return mvtPath)
                            ((mvtTxF <$>) . httpTx service) $
                            txInformationTxHash mvtPath
                    renderIO $
                        format
                            (accountStoreDeriv store)
                            unit
                            Nothing
                            (Just currHeight)
                            mvtTx

broadcast :: Command IO
broadcast = command "broadcast" "broadcast a tx from a file in hex format" $
    withOption netOpt $ \network ->
    withOption serOpt $ \s ->
    withNonOption Argument.file $ \fp ->
        io $ do
            setOptNet network
            let !service = parseBlockchainService s
            tx <- readDoc $ fromString fp :: IO Tx
            httpBroadcast service tx
            renderIO $
                formatStatic "Tx" <+>
                formatTxHash (txHashToHex $ txHash tx) <+>
                formatStatic "has been broadcast"

help :: Command IO
help = command "help" "Show usage info" $ io $ showUsage hwCommands

{- Command Line Helpers -}

writeDoc :: Json.ToJSON a => FileName -> a -> IO FilePath
writeDoc fileName dat = do
    dir <- fromString <$> D.getUserDocumentsDirectory
    let path = dir </> (fromString networkName <> "-" <> fileName <> ".json")
        val = encodeJsonPretty $ DocStructure (fromString networkName) dat
    withFile path WriteMode (`hPut` (val <> stringToBytes "\n"))
    return path

readDoc :: Json.FromJSON a => FilePath -> IO a
readDoc fileName = do
    bytes <- readFile fileName
    case decodeJson bytes of
        Just (DocStructure net payload) ->
            if net == fromString networkName
                then return payload
                else badNet $ fromText net
        _ ->
            consoleError $
            formatError $ "Could not read file " <> filePathToString fileName
  where
    badNet net =
        consoleError $
        formatError $
        "Bad network. This file has to be used in the network " <> net

withAccountStore :: String -> ((String, AccountStore) -> IO ()) -> IO ()
withAccountStore name f
    | null name = do
        accMap <- readAccountsFile
        case Map.assocs accMap of
            [val] -> f (first fromText val)
            _ ->
                case Map.lookup "main" accMap of
                    Just val -> f ("main", val)
                    _        -> err $ fromText <$> Map.keys accMap
    | otherwise = do
        accM <- getAccountStore name
        case accM of
            Just acc -> f (name, acc)
            _        -> err . fmap fromText . Map.keys =<< readAccountsFile
  where
    err :: [String] -> IO ()
    err [] = consoleError $ formatError "No accounts have been created"
    err keys =
        consoleError $
        vcat
            [ formatError
                  "Select one of the following accounts with -a or --account"
            , nest 4 $ vcat $ fmap formatAccount keys
            ]

askInputLineHidden :: String -> IO String
askInputLineHidden msg = do
    inputM <-
        Haskeline.runInputT Haskeline.defaultSettings $
        Haskeline.getPassword (Just '*') (toLString msg)
    maybe
        (consoleError $ formatError "No action due to EOF")
        (return . fromLString)
        inputM

askInputLine :: String -> IO String
askInputLine msg = do
    inputM <-
        Haskeline.runInputT Haskeline.defaultSettings $
        Haskeline.getInputLine (toLString msg)
    maybe
        (consoleError $ formatError "No action due to EOF")
        (return . fromLString)
        inputM

askSigningKey :: Natural -> IO XPrvKey
askSigningKey acc = do
    str <- askInputLineHidden "Enter your private mnemonic: "
    case mnemonicToSeed "" (stringToBS str) of
        Right _ -> do
            passStr <- askPassword
            either (consoleError . formatError) return $
                signingKey passStr str acc
        Left err -> consoleError $ formatError $ fromLString err

askPassword :: IO String
askPassword = do
    pass <- askInputLineHidden "Mnemonic password or leave empty: "
    unless (null pass) $ do
        pass2 <- askInputLineHidden "Repeat your mnemonic password: "
        when (pass /= pass2) $
            consoleError $ formatError "The passwords did not match"
    return pass
