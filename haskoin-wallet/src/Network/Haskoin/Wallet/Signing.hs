{-# LANGUAGE TemplateHaskell #-}
module Network.Haskoin.Wallet.Signing where

import           Control.Arrow
import           Control.Monad
import           Data.Aeson.TH
import qualified Data.ByteString                     as BS
import           Data.Either
import           Data.List
import qualified Data.Map.Strict                     as M
import           Data.Maybe
import           Data.Monoid                         ((<>))
import qualified Data.Serialize                      as S
import           Data.Word
import           Network.Haskoin.Constants
import           Network.Haskoin.Crypto
import           Network.Haskoin.Network
import           Network.Haskoin.Script
import           Network.Haskoin.Transaction
import           Network.Haskoin.Util
import           Network.Haskoin.Wallet.AccountStore
import           Network.Haskoin.Wallet.HTTP

{- Building Transactions -}

data WalletCoin = WalletCoin
    { walletCoinOutPoint     :: !OutPoint
    , walletCoinScriptOutput :: !ScriptOutput
    , walletCoinValue        :: !Word64
    } deriving (Eq, Show)

instance Coin WalletCoin where
    coinValue = walletCoinValue

instance Ord WalletCoin where
    a `compare` b = walletCoinValue a `compare` walletCoinValue b

toWalletCoin :: (OutPoint, ScriptOutput, Word64) -> WalletCoin
toWalletCoin (op, so, v) = WalletCoin op so v

buildTxSignData :: BlockchainService
                -> AccountStore
                -> [(Address, Word64)]
                -> Word64
                -> Word64
                -> IO (Either String (TxSignData, AccountStore))
buildTxSignData service store rcps feeByte dust
    | null rcps = return $ Left "No recipients provided"
    | otherwise = do
        allCoins <-
            map toWalletCoin <$> httpUnspent service (map fst allAddrs)
        case buildWalletTx allAddrs allCoins change rcps feeByte dust of
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
    allAddrs = allExtAddresses store <> allIntAddresses store
    (change, store') = nextIntAddress store

buildWalletTx :: [(Address, SoftPath)] -- All account addresses
              -> [WalletCoin]
              -> (Address, SoftPath, KeyIndex) -- change
              -> [(Address, Word64)] -- recipients
              -> Word64 -- Fee per byte
              -> Word64 -- Dust
              -> Either String (Tx, [TxHash], [SoftPath], [SoftPath])
buildWalletTx allAddrs coins (change, changeDeriv, _) rcps feeByte dust = do
    (selectedCoins, changeAmnt) <- chooseCoins tot feeByte nRcps True descCoins
    let (allRcps, outDeriv)
            | changeAmnt <= dust = (rcps, [])
            | otherwise = (rcps <> [(change, changeAmnt)], [changeDeriv])
        ops = map walletCoinOutPoint selectedCoins
    tx <- buildAddrTx ops $ map toBase58 allRcps
    inDeriv <- mapM toInDeriv selectedCoins
    return ( tx
           , nub $ map outPointHash ops
           , nub inDeriv
           , nub $ outDeriv <> selfDeriv
           )
  where
    -- Add recipients that are in our own wallet
    selfDeriv = mapMaybe ((`M.lookup` aMap) . fst) rcps
    nRcps = length rcps + 1
    tot = sum $ map snd rcps
    descCoins = sortBy (flip compare) coins
    toBase58 (a, v) = (addrToBase58 a, v)
    aMap = M.fromList allAddrs
    toInDeriv = ((aMap M.!) <$>) . outputAddress . walletCoinScriptOutput

{- Signing Transactions -}

bip44Deriv :: KeyIndex -> HardPath
bip44Deriv a = Deriv :| 44 :| bip44Coin :| a

signingKey :: Passphrase -> Mnemonic -> KeyIndex -> Either String XPrvKey
signingKey pass mnem acc = do
    seed <- mnemonicToSeed pass mnem
    return $ derivePath (bip44Deriv acc) (makeXPrvKey seed)

data TxSignData = TxSignData
    { txSignDataTx          :: !Tx
    , txSignDataInputs      :: ![Tx]
    , txSignDataInputPaths  :: ![SoftPath]
    , txSignDataOutputPaths :: ![SoftPath]
    } deriving (Eq, Show)

$(deriveJSON (dropFieldLabel 10) ''TxSignData)

instance S.Serialize TxSignData where
    get = do
        t <- S.get
        (VarInt c) <- S.get
        ti <- replicateM (fromIntegral c) S.get
        TxSignData t ti <$> getPathLs <*> getPathLs
      where
        getPathLs = do
            (VarInt c) <- S.get
            replicateM (fromIntegral c) getPath
        getPath =
            S.get >>= \dM ->
                case toSoft (dM :: DerivPath) of
                    Just d -> return d
                    _      -> mzero
    put (TxSignData t ti is os) = do
        S.put t
        S.put $ VarInt $ fromIntegral $ length ti
        forM_ ti S.put
        putPath is
        putPath os
      where
        putPath ls = do
            S.put $ VarInt $ fromIntegral $ length ls
            forM_ ls $ S.put . toGeneric

data TxSummary = TxSummary
    { txSummaryTxHash   :: Maybe TxHash
    , txSummaryOutbound :: M.Map Address Word64
    , txSummaryNonStd   :: !Word64
    , txSummaryInbound  :: M.Map Address (Word64, SoftPath)
    , txSummaryMyInputs :: M.Map Address (Word64, SoftPath)
    , txSummaryAmount   :: !Integer
    , txSummaryFee      :: Maybe Word64
    , txSummaryFeeByte  :: Maybe Word64
    , txSummaryTxSize   :: Maybe Int
    , txSummaryIsSigned :: Maybe Bool
    } deriving (Eq, Show)

pubTxSummary :: TxSignData -> XPubKey -> Either String TxSummary
pubTxSummary tsd@(TxSignData tx _ inPaths outPaths) pubKey
    | length coins /= length (txIn tx) =
        Left "Referenced input transactions are missing"
    | length inPaths /= M.size myInputAddrs =
        Left "Tx is missing inputs from private keys"
    | length outPaths /= M.size inboundAddrs =
        Left "Tx is missing change outputs"
    | otherwise =
        return
            TxSummary
            { txSummaryTxHash = Nothing
            , txSummaryOutbound = outboundAddrs
            , txSummaryInbound = inboundAddrs
            , txSummaryNonStd = outNonStdValue
            , txSummaryMyInputs = myInputAddrs
            , txSummaryAmount = amount
            , txSummaryFee = Just fee
            , txSummaryFeeByte = Just $ fee `div` fromIntegral guessLen
            , txSummaryTxSize = Just guessLen
            , txSummaryIsSigned = Just False
            }
    -- Outputs
  where
    outAddrs = nub $ map (xPubAddr . (`derivePubPath` pubKey) &&& id) outPaths
    (outMap, outNonStdValue) = txOutputAddressValues $ txOut tx
    (outboundAddrs, inboundAddrs) =
        M.mapEitherWithKey (isMyAddr outAddrs) outMap
    isMyAddr xs a v =
        case M.lookup a (M.fromList xs) of
            Just p -> Right (v, p)
            _      -> Left v
    -- Inputs
    inAddrs = nub $ map (\p -> (xPubAddr $ derivePubPath p pubKey, p)) inPaths
    (coins, myCoins) = parseTxCoins tsd pubKey
    (myInputAddrs', _) = txOutputAddressValues $ map snd myCoins
    (_, myInputAddrs) = M.mapEitherWithKey (isMyAddr inAddrs) myInputAddrs'
    -- Amounts and Fees
    inSum = sum $ map (outValue . snd) coins
    outSum = sum $ map outValue $ txOut tx
    fee = inSum - outSum
    inboundSum = sum $ map fst $ M.elems inboundAddrs
    myCoinsSum = sum $ map (outValue . snd) myCoins
    amount = toInteger inboundSum - toInteger myCoinsSum
    -- Guess the signed transaction size
    guessLen = guessTxSize (length $ txIn tx) [] (length $ txOut tx) 0

signWalletTx :: TxSignData -> XPrvKey -> Either String (TxSummary, Tx)
signWalletTx tsd@(TxSignData tx _ inPaths _) signKey = do
    sigDat <- mapM g myCoins
    signedTx <- signTx tx (map f sigDat) prvKeys
    let byteSize = BS.length $ S.encode signedTx
        vDat = rights $ map g coins
        isSigned = noEmptyInputs signedTx && verifyStdTx signedTx vDat
    dat <- pubTxSummary tsd pubKey
    return
        ( dat
          { txSummaryFeeByte =
                (`div` fromIntegral byteSize) <$> txSummaryFee dat
          , txSummaryTxSize = Just byteSize
          , txSummaryTxHash = Just $ txHash signedTx
          , txSummaryIsSigned = Just isSigned
          }
        , signedTx)
  where
    pubKey = deriveXPubKey signKey
    (coins, myCoins) = parseTxCoins tsd pubKey
    prvKeys = map (toPrvKeyG . xPrvKey . (`derivePath` signKey)) inPaths
    f (so, val, op) = SigInput so val op (maybeSetForkId sigHashAll) Nothing
    g (op, to) =
        (,,) <$> decodeTxOutSO to <*> return (outValue to) <*> return op
    maybeSetForkId
        | isJust sigHashForkId = setForkIdFlag
        | otherwise = id

noEmptyInputs :: Tx -> Bool
noEmptyInputs = all (not . BS.null) . map scriptInput . txIn

txOutputAddressValues :: [TxOut] -> (M.Map Address Word64, Word64)
txOutputAddressValues txout =
    (M.fromListWith (+) rs, sum ls)
  where
    xs = map (decodeTxOutAddr &&& outValue) txout
    (ls, rs) = partitionEithers $ map partE xs
    partE (Right a, v) = Right (a, v)
    partE (Left _, v)  = Left v

decodeTxOutAddr :: TxOut -> Either String Address
decodeTxOutAddr = outputAddress <=< decodeTxOutSO

decodeTxOutSO :: TxOut -> Either String ScriptOutput
decodeTxOutSO = decodeOutputBS . scriptOutput

parseTxCoins :: TxSignData -> XPubKey
             -> ([(OutPoint, TxOut)],[(OutPoint, TxOut)])
parseTxCoins (TxSignData tx inTxs inPaths _) pubKey =
    (coins, myCoins)
  where
    inAddrs = nub $ map (xPubAddr . (`derivePubPath` pubKey)) inPaths
    coins = mapMaybe (findCoin inTxs . prevOutput) $ txIn tx
    myCoins = filter (isMyCoin . snd) coins
    isMyCoin to =
        case decodeTxOutAddr to of
            Right a -> a `elem` inAddrs
            _ -> False

findCoin :: [Tx] -> OutPoint -> Maybe (OutPoint, TxOut)
findCoin txs op@(OutPoint h i) = do
    matchTx <- listToMaybe $ filter ((== h) . txHash) txs
    to <- txOut matchTx `safeIndex` fromIntegral i
    return (op, to)
  where
    safeIndex xs n
        | n >= length xs = Nothing
        | otherwise = Just $ xs !! n
