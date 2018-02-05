{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections     #-}
module Network.Haskoin.Wallet.Signing where

import           Control.Arrow                           ((&&&))
import           Data.Aeson.TH                           (deriveJSON)
import           Data.List                               (nub, sum)
import           Data.Map.Strict                         (Map)
import qualified Data.Map.Strict                         as Map
import           Data.Ord
import qualified Data.Set                                as Set
import           Foundation
import           Foundation.Collection
import           Network.Haskoin.Constants
import           Network.Haskoin.Crypto
import           Network.Haskoin.Script
import           Network.Haskoin.Transaction
import           Network.Haskoin.Util
import           Network.Haskoin.Wallet.AccountStore
import           Network.Haskoin.Wallet.Amounts
import           Network.Haskoin.Wallet.FoundationCompat hiding (addrToBase58)
import           Network.Haskoin.Wallet.HTTP

{- Building Transactions -}

data WalletCoin = WalletCoin
    { walletCoinOutPoint     :: !OutPoint
    , walletCoinScriptOutput :: !ScriptOutput
    , walletCoinValue        :: !Satoshi
    } deriving (Eq, Show)

instance Coin WalletCoin where
    coinValue = fromIntegral . walletCoinValue

instance Ord WalletCoin where
    compare = compare `on` walletCoinValue

toWalletCoin :: (OutPoint, ScriptOutput, Satoshi) -> WalletCoin
toWalletCoin (op, so, v) = WalletCoin op so v

buildTxSignData :: BlockchainService
                -> AccountStore
                -> Map Address Satoshi
                -> Satoshi
                -> Satoshi
                -> IO (Either String (TxSignData, AccountStore))
buildTxSignData service store rcpMap feeByte dust
    | Map.null rcpMap = return $ Left "No recipients provided"
    | otherwise = do
        allCoins <-
            fmap toWalletCoin <$> httpUnspent service (Map.keys walletAddrMap)
        case buildWalletTx
                 walletAddrMap
                 allCoins
                 (second fromIntegral change)
                 rcpMap
                 feeByte
                 dust of
            Right (tx, depTxHash, inDeriv, outDeriv) -> do
                depTxs <- mapM (httpTx service) depTxHash
                return $
                    Right
                        ( TxSignData
                          { txSignDataTx = tx
                          , txSignDataInputs = depTxs
                          , txSignDataInputPaths = inDeriv
                          , txSignDataOutputPaths = outDeriv
                          }
                        , if null outDeriv
                              then store
                              else store')
            Left err -> return $ Left err
  where
    walletAddrMap =
        Map.fromList $ allExtAddresses store <> allIntAddresses store
    (change, store') = nextIntAddress store

buildWalletTx :: Map Address SoftPath -- All account addresses
              -> [WalletCoin]
              -> (Address, SoftPath, Natural) -- change
              -> Map Address Satoshi -- recipients
              -> Satoshi -- Fee per byte
              -> Satoshi -- Dust
              -> Either String (Tx, [TxHash], [SoftPath], [SoftPath])
buildWalletTx walletAddrMap coins (change, changeDeriv, _) rcpMap feeByte dust = do
    (selectedCoins, changeAmnt) <-
        eitherString $
        second toNatural <$>
        chooseCoins
            (fromIntegral tot)
            (fromIntegral feeByte)
            nRcps
            True
            descCoins
    let (txRcpMap, outDeriv)
            | changeAmnt <= dust = (rcpMap, [])
            | otherwise = (Map.insert change changeAmnt rcpMap, [changeDeriv])
        ops = fmap walletCoinOutPoint selectedCoins
    tx <-
        eitherString $
        buildAddrTx ops $
        bimap addrToBase58 fromIntegral <$> Map.assocs txRcpMap
    inCoinAddrs <-
        eitherString $ mapM (outputAddress . walletCoinScriptOutput) selectedCoins
    let inDerivMap = Map.restrictKeys walletAddrMap $ Set.fromList inCoinAddrs
    return
        ( tx
        , nub $ fmap outPointHash ops
        , nub $ Map.elems inDerivMap
        , nub $ outDeriv <> myPaths)
    -- Add recipients that are in our own wallet
  where
    myPaths = Map.elems $ Map.intersection walletAddrMap rcpMap
    nRcps = Map.size rcpMap + 1
    tot = sum $ Map.elems rcpMap
    descCoins = sortBy (comparing Down) coins

{- Signing Transactions -}

bip44Deriv :: Natural -> HardPath
bip44Deriv a = Deriv :| 44 :| bip44Coin :| fromIntegral a

signingKey :: String -> String -> Natural -> Either String XPrvKey
signingKey pass mnem acc = do
    seed <- eitherString $ mnemonicToSeed (stringToBS pass) (stringToBS mnem)
    return $ derivePath (bip44Deriv acc) (makeXPrvKey seed)

data TxSignData = TxSignData
    { txSignDataTx          :: !Tx
    , txSignDataInputs      :: ![Tx]
    , txSignDataInputPaths  :: ![SoftPath]
    , txSignDataOutputPaths :: ![SoftPath]
    } deriving (Eq, Show)

$(deriveJSON (dropFieldLabel 10) ''TxSignData)

data TxSummary = TxSummary
    { txSummaryType     :: !String
    , txSummaryTxHash   :: Maybe TxHash
    , txSummaryOutbound :: Map Address Satoshi
    , txSummaryNonStd   :: !Satoshi
    , txSummaryInbound  :: Map Address (Satoshi, SoftPath)
    , txSummaryMyInputs :: Map Address (Satoshi, SoftPath)
    , txSummaryAmount   :: !Integer
    , txSummaryFee      :: Maybe Satoshi
    , txSummaryFeeByte  :: Maybe Satoshi
    , txSummaryTxSize   :: Maybe (CountOf (Element (UArray Word8)))
    , txSummaryIsSigned :: Maybe Bool
    } deriving (Eq, Show)

pubTxSummary :: TxSignData -> XPubKey -> Either String TxSummary
pubTxSummary tsd@(TxSignData tx _ inPaths outPaths) pubKey
    | fromCount (length coins) /= fromCount (length $ txIn tx) =
        Left "Referenced input transactions are missing"
    | length inPaths /= toCount (Map.size myInputAddrs) =
        Left "Tx is missing inputs from private keys"
    | length outPaths /= toCount (Map.size inboundAddrs) =
        Left "Tx is missing change outputs"
    | otherwise =
        return
            TxSummary
            { txSummaryType = getTxType feeM amount
            , txSummaryTxHash = Nothing
            , txSummaryOutbound = outboundAddrs
            , txSummaryInbound = inboundAddrs
            , txSummaryNonStd = outNonStdValue
            , txSummaryMyInputs = myInputAddrs
            , txSummaryAmount = amount
            , txSummaryFee = feeM
            , txSummaryFeeByte =
                  (`div` fromIntegral (toInteger guessLen)) <$> feeM
            , txSummaryTxSize = Just guessLen
            , txSummaryIsSigned = Just False
            }
    -- Outputs
  where
    outAddrMap :: Map Address SoftPath
    outAddrMap = Map.fromList $ fmap (pathToAddr pubKey &&& id) outPaths
    (outValMap, outNonStdValue) = txOutputAddressValues $ txOut tx
    inboundAddrs = Map.intersectionWith (,) outValMap outAddrMap
    outboundAddrs = Map.difference outValMap outAddrMap
    -- Inputs
    inAddrMap :: Map Address SoftPath
    inAddrMap = Map.fromList $ fmap (pathToAddr pubKey &&& id) inPaths
    (coins, myCoins) = parseTxCoins tsd pubKey
    inValMap = fst $ txOutputAddressValues $ fmap snd myCoins
    myInputAddrs = Map.intersectionWith (,) inValMap inAddrMap
    -- Amounts and Fees
    inSum = sum $ fmap (toNatural . outValue . snd) coins :: Satoshi
    outSum = sum $ toNatural . outValue <$> txOut tx :: Satoshi
    feeM = inSum - outSum :: Maybe Satoshi
    inboundSum = sum $ Map.elems $ Map.map fst inboundAddrs :: Satoshi
    myCoinsSum = sum $ fmap (toNatural . outValue . snd) myCoins :: Satoshi
    amount = toInteger inboundSum - toInteger myCoinsSum :: Integer
    -- Guess the signed transaction size
    guessLen :: CountOf (Element (UArray Word8))
    guessLen =
        fromIntegral $
        guessTxSize
            (fromCount $ length $ txIn tx)
            []
            (fromCount $ length $ txOut tx)
            0

getTxType :: Maybe Satoshi -> Integer -> String
getTxType feeM amnt
    | amnt > 0 = "Inbound"
    | Just (fromIntegral $ abs amnt) == feeM = "Self"
    | otherwise = "Outbound"

signWalletTx :: TxSignData -> XPrvKey -> Either String (TxSummary, Tx)
signWalletTx tsd@(TxSignData tx _ inPaths _) signKey = do
    sigDat <- mapM g myCoins
    signedTx <- eitherString $ signTx tx (fmap f sigDat) prvKeys
    let byteSize = length $ encodeBytes signedTx
        vDat = rights $ fmap g coins
        isSigned = noEmptyInputs signedTx && verifyStdTx signedTx vDat
    dat <- pubTxSummary tsd pubKey
    return
        ( dat
          { txSummaryFeeByte =
                if isSigned
                    then (`div` fromIntegral (toInteger byteSize)) <$>
                         txSummaryFee dat
                    else txSummaryFeeByte dat
          , txSummaryTxSize =
                if isSigned
                    then Just byteSize
                    else txSummaryTxSize dat
          , txSummaryTxHash = Just $ txHash signedTx
          , txSummaryIsSigned = Just isSigned
          }
        , signedTx)
  where
    pubKey = deriveXPubKey signKey
    (coins, myCoins) = parseTxCoins tsd pubKey
    prvKeys = fmap (toPrvKeyG . xPrvKey . (`derivePath` signKey)) inPaths
    f (so, val, op) = SigInput so val op (maybeSetForkId sigHashAll) Nothing
    g (op, to) = (, outValue to, op) <$> decodeTxOutSO to
    maybeSetForkId
        | isJust sigHashForkId = setForkIdFlag
        | otherwise = id

noEmptyInputs :: Tx -> Bool
noEmptyInputs = all (not . null) . fmap (asBytes scriptInput) . txIn

txOutputAddressValues :: [TxOut] -> (Map Address Satoshi, Satoshi)
txOutputAddressValues txout =
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

pathToAddr :: XPubKey -> SoftPath -> Address
pathToAddr pubKey = xPubAddr . (`derivePubPath` pubKey)

parseTxCoins :: TxSignData -> XPubKey
             -> ([(OutPoint, TxOut)],[(OutPoint, TxOut)])
parseTxCoins (TxSignData tx inTxs inPaths _) pubKey =
    (coins, myCoins)
  where
    inAddrs = nub $ fmap (pathToAddr pubKey) inPaths
    coins = mapMaybe (findCoin inTxs . prevOutput) $ txIn tx
    myCoins = filter (isMyCoin . snd) coins
    isMyCoin to =
        case decodeTxOutAddr to of
            Right a -> a `elem` inAddrs
            _       -> False

findCoin :: [Tx] -> OutPoint -> Maybe (OutPoint, TxOut)
findCoin txs op@(OutPoint h i) = do
    matchTx <- find ((== h) . txHash) txs
    to <- txOut matchTx ! fromIntegral i
    return (op, to)

