{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
module Network.Haskoin.Wallet.TxInformation where

import           Control.Arrow                           ((&&&))
import           Data.Decimal
import           Data.List                               (sortOn, sum)
import           Data.Map.Strict                         (Map)
import qualified Data.Map.Strict                         as Map
import           Foundation
import           Foundation.Collection
import           Network.Haskoin.Block                   hiding (blockHashToHex)
import           Network.Haskoin.Crypto                  hiding (addrToBase58)
import           Network.Haskoin.Script
import           Network.Haskoin.Transaction             hiding (txHashToHex)
import           Network.Haskoin.Wallet.Amounts
import           Network.Haskoin.Wallet.ConsolePrinter
import           Network.Haskoin.Wallet.FoundationCompat
import qualified Prelude

data TxInformation = TxInformation
    { txInformationTxHash    :: Maybe TxHash
    , txInformationTxSize    :: Maybe (CountOf (Element (UArray Word8)))
    , txInformationOutbound  :: Map Address Satoshi
    , txInformationNonStd    :: Satoshi
    , txInformationInbound   :: Map Address (Satoshi, Maybe SoftPath)
    , txInformationMyInputs  :: Map Address (Satoshi, Maybe SoftPath)
    , txInformationFee       :: Maybe Satoshi
    , txInformationHeight    :: Maybe Natural
    , txInformationBlockHash :: Maybe BlockHash
    } deriving (Eq, Show)

txInformationAmount :: TxInformation -> Integer
txInformationAmount TxInformation {..} =
    toInteger inboundSum - toInteger myCoinsSum
  where
    inboundSum = sum $ fmap fst $ Map.elems txInformationInbound :: Satoshi
    myCoinsSum = sum $ fmap fst $ Map.elems txInformationMyInputs :: Satoshi

txInformationFeeByte :: TxInformation -> Maybe Decimal
txInformationFeeByte TxInformation {..} = do
    sat <- feeDecimalM
    bytes <- sizeDecimalM
    return $ roundTo 2 $ sat Prelude./ bytes
  where
    feeDecimalM = fromIntegral <$> txInformationFee :: Maybe Decimal
    sizeDecimalM =
        fromIntegral . fromCount <$> txInformationTxSize :: Maybe Decimal

txInformationTxType :: TxInformation -> String
txInformationTxType s
    | amnt > 0 = "Inbound"
    | Just (fromIntegral $ abs amnt) == txInformationFee s = "Self"
    | otherwise = "Outbound"
  where
    amnt = txInformationAmount s

txInformationFillPath :: Map Address SoftPath -> TxInformation -> TxInformation
txInformationFillPath addrMap txInformation =
    txInformation
    { txInformationInbound = mergeSoftPath (txInformationInbound txInformation)
    , txInformationMyInputs =
          mergeSoftPath (txInformationMyInputs txInformation)
    }
  where
    mergeSoftPath = Map.intersectionWith f addrMap
    f path (amnt, _) = (amnt, Just path)

txInformationFillTx :: Tx -> TxInformation -> TxInformation
txInformationFillTx tx txInformation =
    txInformation
    { txInformationOutbound = outbound
    , txInformationNonStd = nonStd
    , txInformationTxHash = Just $ txHash tx
    , txInformationTxSize = Just $ length $ encodeBytes tx
    , txInformationFee = txInformationFee txInformation <|> feeM
    }
  where
    (outAddrMap, nonStd) = txOutAddressMap $ txOut tx
    outbound = Map.difference outAddrMap (txInformationInbound txInformation)
    outSum = sum $ (toNatural . outValue) <$> txOut tx :: Natural
    inSum =
        sum $ fst <$> Map.elems (txInformationMyInputs txInformation) :: Natural
    feeM = inSum - outSum :: Maybe Natural

txOutAddressMap :: [TxOut] -> (Map Address Satoshi, Satoshi)
txOutAddressMap txout =
    (Map.fromListWith (+) rs, sum ls)
  where
    xs = fmap (decodeTxOutAddr &&& toNatural . outValue) txout
    (ls, rs) = partitionEithers $ fmap partE xs
    partE (Right a, v) = Right (a, v)
    partE (Left _, v)  = Left v

decodeTxOutAddr :: TxOut -> Either String Address
decodeTxOutAddr = decodeTxOutSO >=> eitherString . outputAddress

decodeTxOutSO :: TxOut -> Either String ScriptOutput
decodeTxOutSO = eitherString . decodeOutputBS . scriptOutput

isExternal :: SoftPath -> Bool
isExternal (Deriv :/ 0 :/ _) = True
isExternal _                 = False

txInformationFormatCompact ::
       HardPath
    -> AmountUnit
    -> Maybe Bool
    -> Maybe Natural
    -> TxInformation
    -> ConsolePrinter
txInformationFormatCompact _ unit _ heightM s@TxInformation {..} =
    vcat [title <+> confs, nest 4 $ vcat [txid, outbound, self, inbound]]
  where
    title =
        case txInformationTxType s of
            "Outbound" -> formatTitle "Outbound Payment"
            "Inbound"  -> formatTitle "Inbound Payment"
            "Self"     -> formatTitle "Payment To Yourself"
            _          -> consoleError $ formatError "Invalid tx type"
    confs =
        case heightM of
            Just currHeight ->
                case (currHeight -) =<< txInformationHeight of
                    Just conf ->
                        formatStatic $
                        "(" <> show (conf + 1) <> " confirmations)"
                    _ -> formatStatic "(Pending)"
            _ -> mempty
    txid = maybe mempty (formatTxHash . txHashToHex) txInformationTxHash
    outbound
        | txInformationTxType s /= "Outbound" = mempty
        | txInformationNonStd == 0 && Map.null txInformationOutbound = mempty
        | otherwise =
            vcat $
            [feeKey] <>
            fmap (addrFormat negate) (Map.assocs txInformationOutbound) <>
            [nonStdRcp]
    nonStdRcp
        | txInformationNonStd == 0 = mempty
        | otherwise =
            formatStatic "Non-standard recipients:" <+>
            formatIntegerAmount unit (fromIntegral txInformationNonStd)
    feeKey =
        case txInformationFee of
            Just fee ->
                formatKey "Fees:" <+>
                formatIntegerAmountWith
                    formatFee
                    unit
                    (fromIntegral fee)
            _ -> mempty
    self
        | txInformationTxType s /= "Self" = mempty
        | otherwise = feeKey
    inbound
        | txInformationTxType s /= "Inbound" = mempty
        | Map.null txInformationInbound = mempty
        | otherwise =
            vcat $
            [ if Map.size txInformationInbound > 1
                  then formatKey "Total amount:" <+>
                       formatIntegerAmount unit (txInformationAmount s)
                  else mempty
            ] <>
            fmap (addrFormat id) (Map.assocs $ Map.map fst txInformationInbound)
    addrFormat f (a, v) =
        formatAddress (addrToBase58 a) <> formatStatic ":" <+>
        formatIntegerAmount unit (f $ fromIntegral v)

txInformationFormat ::
       HardPath
    -> AmountUnit
    -> Maybe Bool
    -> Maybe Natural
    -> TxInformation
    -> ConsolePrinter
txInformationFormat accDeriv unit txSignedM heightM s@TxInformation {..} =
    vcat [information, nest 2 $ vcat [outbound, inbound, myInputs]]
  where
    information =
        vcat
            [ formatTitle "Tx Information"
            , nest 4 $
              vcat
                  [ formatKey (block 15 "Tx Type:") <>
                    formatStatic (txInformationTxType s)
                  , case txInformationTxHash of
                        Just tid ->
                            formatKey (block 15 "Tx hash:") <>
                            formatTxHash (txHashToHex tid)
                        _ -> mempty
                  , formatKey (block 15 "Amount:") <>
                    formatIntegerAmount unit (txInformationAmount s)
                  , case txInformationFee of
                        Just fee ->
                            formatKey (block 15 "Fees:") <>
                            formatIntegerAmountWith
                                formatFee
                                unit
                                (fromIntegral fee)
                        _ -> mempty
                  , case txInformationFeeByte s of
                        Just feeByte ->
                            formatKey (block 15 "Fee/byte:") <>
                            formatFeeBytes feeByte
                        _ -> mempty
                  , case txInformationTxSize of
                        Just bytes ->
                            formatKey (block 15 "Tx size:") <>
                            formatStatic (show (fromCount bytes) <> " bytes")
                        _ -> mempty
                  , case txInformationHeight of
                        Just height ->
                            formatKey (block 15 "Block Height:") <>
                            formatStatic (show height)
                        _ -> mempty
                  , case txInformationBlockHash of
                        Just bh ->
                            formatKey (block 15 "Block Hash:") <>
                            formatBlockHash (blockHashToHex bh)
                        _ -> mempty
                  , case heightM of
                        Just currHeight ->
                            formatKey (block 15 "Confirmations:") <>
                            case (currHeight -) =<< txInformationHeight of
                                Just conf -> formatStatic $ show $ conf + 1
                                _         -> formatStatic "Pending"
                        _ -> mempty
                  , case txSignedM of
                        Just signed ->
                            formatKey (block 15 "Signed:") <>
                            if signed
                                then formatTrue "Yes"
                                else formatFalse "No"
                        _ -> mempty
                  ]
            ]
    outbound
        | txInformationTxType s /= "Outbound" = mempty
        | txInformationNonStd == 0 && Map.null txInformationOutbound = mempty
        | otherwise =
            vcat
                [ formatTitle "Outbound"
                , nest 2 $
                  vcat $
                  fmap addrFormatOutbound (Map.assocs txInformationOutbound) <>
                  [nonStdRcp]
                ]
    nonStdRcp
        | txInformationNonStd == 0 = mempty
        | otherwise =
            formatAddrVal
                unit
                accDeriv
                (formatStatic "Non-standard recipients")
                Nothing
                (negate $ fromIntegral txInformationNonStd)
    inbound
        | Map.null txInformationInbound = mempty
        | otherwise =
            vcat
                [ formatTitle "Inbound"
                , nest 2 $
                  vcat $
                  fmap addrFormatInbound $
                  sortOn (((not . isExternal) <$>) . snd . snd) $
                  Map.assocs txInformationInbound
                ]
    myInputs
        | Map.null txInformationMyInputs = mempty
        | otherwise =
            vcat
                [ formatTitle "Spent Coins"
                , nest 2 $
                  vcat $
                  fmap addrFormatMyInputs (Map.assocs txInformationMyInputs)
                ]
    addrFormatInbound (a, (v, pM)) =
        formatAddrVal
            unit
            accDeriv
            ((if maybe False isExternal pM
                  then formatAddress
                  else formatInternalAddress) $
             addrToBase58 a)
            pM
            (fromIntegral v)
    addrFormatMyInputs (a, (v, pM)) =
        formatAddrVal
            unit
            accDeriv
            (formatInternalAddress $ addrToBase58 a)
            pM
            (negate $ fromIntegral v)
    addrFormatOutbound (a, v) =
        formatAddrVal
            unit
            accDeriv
            (formatAddress $ addrToBase58 a)
            Nothing
            (negate $ fromIntegral v)

formatAddrVal ::
       AmountUnit
    -> HardPath
    -> ConsolePrinter
    -> Maybe SoftPath
    -> Integer
    -> ConsolePrinter
formatAddrVal unit accDeriv title pathM amnt =
    vcat
        [ title
        , nest 4 $
          vcat
              [ formatKey (block 8 "Amount:") <> formatIntegerAmount unit amnt
              , case pathM of
                    Just p ->
                        mconcat
                            [ formatKey $ block 8 "Deriv:"
                            , formatDeriv $
                              show $ ParsedPrv $ toGeneric $ accDeriv ++/ p
                            ]
                    _ -> mempty
              ]
        ]
