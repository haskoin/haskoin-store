{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Haskoin.Store.DataSpec (spec) where

import Control.Arrow (second)
import Control.Monad (forM_)
import Data.Aeson (FromJSON (..))
import Data.ByteString qualified as B
import Data.String.Conversions (cs)
import Haskoin
import Haskoin.Store.Data
import Haskoin.Util
import Haskoin.Util.Arbitrary
import Test.Hspec
import Test.QuickCheck

serialVals :: Ctx -> [SerialBox]
serialVals ctx =
  [ SerialBox (arbitrary :: Gen DeriveType),
    SerialBox (arbitraryXPubSpec ctx :: Gen XPubSpec),
    SerialBox (arbitrary :: Gen BlockRef),
    SerialBox (arbitrary :: Gen TxRef),
    SerialBox (arbitrary :: Gen Balance),
    SerialBox (arbitrary :: Gen Unspent),
    SerialBox (arbitrary :: Gen BlockData),
    SerialBox (arbitrary :: Gen StoreInput),
    SerialBox (arbitrary :: Gen Spender),
    SerialBox (arbitrary :: Gen StoreOutput),
    SerialBox (arbitrary :: Gen Prev),
    SerialBox (arbitraryTxData ctx :: Gen TxData),
    SerialBox (arbitrary :: Gen Transaction),
    SerialBox (arbitrary :: Gen XPubBal),
    SerialBox (arbitrary :: Gen XPubUnspent),
    SerialBox (arbitrary :: Gen XPubSummary),
    SerialBox (arbitrary :: Gen HealthCheck),
    SerialBox (arbitrary :: Gen Event),
    SerialBox (arbitrary :: Gen TxId),
    SerialBox (arbitrary :: Gen PeerInfo),
    SerialBox (arbitrary :: Gen (GenericResult BlockData)),
    SerialBox (arbitrary :: Gen (RawResult BlockData)),
    SerialBox (arbitrary :: Gen (RawResultList BlockData))
  ]

jsonVals :: [JsonBox]
jsonVals =
  [ JsonBox (arbitrary :: Gen TxRef),
    JsonBox (arbitrary :: Gen BlockRef),
    JsonBox (arbitrary :: Gen Spender),
    JsonBox (arbitrary :: Gen XPubSummary),
    JsonBox (arbitrary :: Gen HealthCheck),
    JsonBox (arbitrary :: Gen Event),
    JsonBox (arbitrary :: Gen TxId),
    JsonBox (arbitrary :: Gen PeerInfo),
    JsonBox (arbitrary :: Gen (GenericResult XPubSummary)),
    JsonBox (arbitrary :: Gen (RawResult BlockData)),
    JsonBox (arbitrary :: Gen (RawResultList BlockData)),
    JsonBox (arbitrary :: Gen Except),
    JsonBox (arbitrary :: Gen BinfoWallet),
    JsonBox (arbitrary :: Gen BinfoSymbol),
    JsonBox (arbitrary :: Gen BinfoBlockInfo),
    JsonBox (arbitrary :: Gen BinfoInfo),
    JsonBox (arbitrary :: Gen BinfoSpender),
    JsonBox (arbitrary :: Gen BinfoRate),
    JsonBox (arbitrary :: Gen BinfoTicker),
    JsonBox (arbitrary :: Gen BinfoTxId),
    JsonBox (arbitrary :: Gen BinfoShortBal),
    JsonBox (arbitrary :: Gen BinfoHistory),
    JsonBox (arbitrary :: Gen BinfoHeader),
    JsonBox (arbitrary :: Gen BinfoBlockInfos)
  ]

netVals :: Ctx -> [NetBox]
netVals ctx =
  [ NetBox
      ( marshalValue,
        marshalEncoding,
        unmarshalValue,
        arbitraryNetData :: Gen (Network, Balance)
      ),
    NetBox
      ( marshalValue,
        marshalEncoding,
        unmarshalValue,
        arbitraryNetData :: Gen (Network, StoreOutput)
      ),
    NetBox
      ( marshalValue,
        marshalEncoding,
        unmarshalValue,
        arbitraryNetData :: Gen (Network, Unspent)
      ),
    NetBox
      ( marshalValue,
        marshalEncoding,
        unmarshalValue,
        arbitraryNetData :: Gen (Network, XPubBal)
      ),
    NetBox
      ( marshalValue,
        marshalEncoding,
        unmarshalValue,
        arbitraryNetData :: Gen (Network, XPubUnspent)
      ),
    NetBox
      ( marshalValue,
        marshalEncoding,
        unmarshalValue,
        arbitraryStoreInputNet
      ),
    NetBox
      ( marshalValue,
        marshalEncoding,
        unmarshalValue,
        arbitraryBlockDataNet
      ),
    NetBox
      ( marshalValue,
        marshalEncoding,
        unmarshalValue,
        arbitraryNetData :: Gen (Network, Transaction)
      ),
    NetBox
      ( marshalValue . (,ctx),
        marshalEncoding . (,ctx),
        unmarshalValue . (,ctx),
        genNetData (arbitraryBinfoMultiAddr ctx)
      ),
    NetBox
      ( marshalValue . (,ctx),
        marshalEncoding . (,ctx),
        unmarshalValue . (,ctx),
        genNetData (arbitraryBinfoBalance ctx)
      ),
    NetBox
      ( marshalValue . (,ctx),
        marshalEncoding . (,ctx),
        unmarshalValue . (,ctx),
        genNetData (arbitraryBinfoBlock ctx)
      ),
    NetBox
      ( marshalValue . (,ctx),
        marshalEncoding . (,ctx),
        unmarshalValue . (,ctx),
        genNetData (arbitraryBinfoTx ctx)
      ),
    NetBox
      ( marshalValue . (,ctx),
        marshalEncoding . (,ctx),
        unmarshalValue . (,ctx),
        genNetData (arbitraryBinfoTxInput ctx)
      ),
    NetBox
      ( marshalValue . (,ctx),
        marshalEncoding . (,ctx),
        unmarshalValue . (,ctx),
        genNetData (arbitraryBinfoTxOutput ctx)
      ),
    NetBox
      ( marshalValue . (,ctx),
        marshalEncoding . (,ctx),
        unmarshalValue . (,ctx),
        genNetData (arbitraryBinfoXPubPath ctx)
      ),
    NetBox
      ( marshalValue . (,ctx),
        marshalEncoding . (,ctx),
        unmarshalValue . (,ctx),
        genNetData (arbitraryBinfoUnspent ctx)
      ),
    NetBox
      ( marshalValue . (,ctx),
        marshalEncoding . (,ctx),
        unmarshalValue . (,ctx),
        genNetData (listOf (arbitraryBinfoBlock ctx))
      ),
    NetBox
      ( marshalValue . (,ctx),
        marshalEncoding . (,ctx),
        unmarshalValue . (,ctx),
        genNetData (arbitraryBinfoRawAddr ctx)
      ),
    NetBox
      ( marshalValue . (,ctx),
        marshalEncoding . (,ctx),
        unmarshalValue . (,ctx),
        genNetData (arbitraryBinfoMempool ctx)
      )
  ]

spec :: Spec
spec = prepareContext $ \ctx -> do
  describe "Binary Encoding" $
    forM_ (serialVals ctx) $
      \(SerialBox g) -> testSerial g
  describe "JSON Encoding" $
    forM_ jsonVals $
      \(JsonBox g) -> testJson g
  describe "JSON Encoding with Network" $
    forM_ (netVals ctx) $
      \(NetBox (j, e, p, g)) -> testNetJson j e p g

instance Arbitrary BlockRef where
  arbitrary =
    oneof [BlockRef <$> arbitrary <*> arbitrary, MemRef <$> arbitrary]

instance Arbitrary Prev where
  arbitrary = Prev <$> arbitraryBS1 <*> arbitrary

arbitraryTxData :: Ctx -> Gen TxData
arbitraryTxData ctx =
  TxData
    <$> arbitrary
    <*> arbitraryTx btc ctx
    <*> arbitrary
    <*> arbitrary
    <*> arbitrary
    <*> arbitrary
    <*> arbitrary

instance Arbitrary StoreInput where
  arbitrary =
    oneof
      [ StoreCoinbase
          <$> arbitraryOutPoint
          <*> arbitrary
          <*> arbitraryBS1
          <*> listOf arbitraryBS1,
        StoreInput
          <$> arbitraryOutPoint
          <*> arbitrary
          <*> arbitraryBS1
          <*> arbitraryBS1
          <*> arbitrary
          <*> listOf arbitraryBS1
          <*> arbitraryMaybe arbitraryAddress
      ]

arbitraryStoreInputNet :: Gen (Network, StoreInput)
arbitraryStoreInputNet = do
  net <- arbitraryNetwork
  store <- arbitrary
  let res
        | net.segWit = store
        | otherwise = witless store
  return (net, res)
  where
    witless StoreInput {..} = StoreInput {witness = [], ..}
    witless StoreCoinbase {..} = StoreCoinbase {witness = [], ..}

instance Arbitrary Spender where
  arbitrary = Spender <$> arbitraryTxHash <*> arbitrary

instance Arbitrary StoreOutput where
  arbitrary =
    StoreOutput
      <$> arbitrary
      <*> arbitraryBS1
      <*> arbitrary
      <*> arbitraryMaybe arbitraryAddress

instance Arbitrary Transaction where
  arbitrary =
    Transaction
      <$> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitraryTxHash
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary

instance Arbitrary PeerInfo where
  arbitrary =
    PeerInfo
      <$> (cs <$> listOf arbitraryUnicodeChar)
      <*> listOf arbitraryPrintableChar
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary

instance Arbitrary BlockHealth where
  arbitrary =
    BlockHealth
      <$> arbitrary
      <*> arbitrary
      <*> arbitrary

instance Arbitrary TimeHealth where
  arbitrary =
    TimeHealth
      <$> arbitrary
      <*> arbitrary

instance Arbitrary CountHealth where
  arbitrary =
    CountHealth
      <$> arbitrary
      <*> arbitrary

instance Arbitrary MaxHealth where
  arbitrary =
    MaxHealth
      <$> arbitrary
      <*> arbitrary

instance Arbitrary HealthCheck where
  arbitrary =
    HealthCheck
      <$> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary

instance Arbitrary RejectCode where
  arbitrary =
    elements
      [ RejectMalformed,
        RejectInvalid,
        RejectObsolete,
        RejectDuplicate,
        RejectNonStandard,
        RejectDust,
        RejectInsufficientFee,
        RejectCheckpoint
      ]

arbitraryXPubSpec :: Ctx -> Gen XPubSpec
arbitraryXPubSpec ctx = XPubSpec <$> (snd <$> arbitraryXPubKey ctx) <*> arbitrary

instance Arbitrary DeriveType where
  arbitrary = elements [DeriveNormal, DeriveP2SH, DeriveP2WPKH]

instance Arbitrary TxId where
  arbitrary = TxId <$> arbitraryTxHash

instance Arbitrary TxRef where
  arbitrary = TxRef <$> arbitrary <*> arbitraryTxHash

instance Arbitrary Balance where
  arbitrary =
    Balance
      <$> arbitraryAddress
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary

instance Arbitrary Unspent where
  arbitrary =
    Unspent
      <$> arbitrary
      <*> arbitraryOutPoint
      <*> arbitrary
      <*> arbitraryBS1
      <*> arbitraryMaybe arbitraryAddress

instance Arbitrary BlockData where
  arbitrary =
    BlockData
      <$> arbitrary
      <*> arbitrary
      <*> (fromInteger <$> suchThat arbitrary (0 <=))
      <*> arbitraryBlockHeader
      <*> arbitrary
      <*> arbitrary
      <*> listOf1 arbitraryTxHash
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary

arbitraryBlockDataNet :: Gen (Network, BlockData)
arbitraryBlockDataNet = do
  net <- arbitraryNetwork
  dat@BlockData {..} <- arbitrary
  let res
        | net.segWit = dat
        | otherwise = BlockData {weight = 0, ..}
  return (net, res)

instance (Arbitrary a) => Arbitrary (GenericResult a) where
  arbitrary = GenericResult <$> arbitrary

instance (Arbitrary a) => Arbitrary (RawResult a) where
  arbitrary = RawResult <$> arbitrary

instance (Arbitrary a) => Arbitrary (RawResultList a) where
  arbitrary = RawResultList <$> arbitrary

instance Arbitrary XPubBal where
  arbitrary = XPubBal <$> arbitrary <*> arbitrary

instance Arbitrary XPubUnspent where
  arbitrary = XPubUnspent <$> arbitrary <*> arbitrary

instance Arbitrary XPubSummary where
  arbitrary =
    XPubSummary
      <$> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary

instance Arbitrary Event where
  arbitrary =
    oneof
      [ EventBlock <$> arbitraryBlockHash,
        EventTx <$> arbitraryTxHash
      ]

instance Arbitrary Except where
  arbitrary =
    oneof
      [ return ThingNotFound,
        return ServerError,
        return BadRequest,
        UserError <$> arbitrary,
        StringError <$> arbitrary,
        TxIndexConflict <$> listOf1 arbitraryTxHash,
        return ServerTimeout
      ]

---------------------------------------
-- Blockchain.info API Compatibility --
---------------------------------------

instance Arbitrary BinfoTxId where
  arbitrary =
    oneof
      [ BinfoTxIdHash <$> arbitraryTxHash,
        BinfoTxIdIndex <$> arbitrary
      ]

arbitraryBinfoMultiAddr :: Ctx -> Gen BinfoMultiAddr
arbitraryBinfoMultiAddr ctx = do
  addresses <- listOf1 $ arbitraryBinfoBalance ctx
  wallet <- arbitrary
  txs <- listOf $ arbitraryBinfoTx ctx
  info <- arbitrary
  recommendFee <- arbitrary
  cashAddr <- arbitrary
  return BinfoMultiAddr {..}

arbitraryBinfoRawAddr :: Ctx -> Gen BinfoRawAddr
arbitraryBinfoRawAddr ctx = do
  address <-
    oneof
      [ BinfoAddr <$> arbitraryAddress,
        BinfoXpub . snd <$> arbitraryXPubKey ctx
      ]
  balance <- arbitrary
  ntx <- arbitrary
  utxo <- arbitrary
  received <- arbitrary
  sent <- arbitrary
  txs <- listOf $ arbitraryBinfoTx ctx
  return $ BinfoRawAddr {..}

instance Arbitrary BinfoShortBal where
  arbitrary = BinfoShortBal <$> arbitrary <*> arbitrary <*> arbitrary

arbitraryBinfoBalance :: Ctx -> Gen BinfoBalance
arbitraryBinfoBalance ctx = do
  address <- arbitraryAddress
  txs <- arbitrary
  received <- arbitrary
  sent <- arbitrary
  balance <- arbitrary
  xpub <- snd <$> arbitraryXPubKey ctx
  external <- arbitrary
  change <- arbitrary
  elements [BinfoAddrBalance {..}, BinfoXPubBalance {..}]

instance Arbitrary BinfoWallet where
  arbitrary = do
    balance <- arbitrary
    txs <- arbitrary
    filtered <- arbitrary
    received <- arbitrary
    sent <- arbitrary
    return BinfoWallet {..}

arbitraryBinfoBlock :: Ctx -> Gen BinfoBlock
arbitraryBinfoBlock ctx = do
  hash <- arbitraryBlockHash
  version <- arbitrary
  prev <- arbitraryBlockHash
  merkle <- (.get) <$> arbitraryTxHash
  timestamp <- arbitrary
  bits <- arbitrary
  next <- listOf arbitraryBlockHash
  ntx <- arbitrary
  fee <- arbitrary
  nonce <- arbitrary
  size <- arbitrary
  index <- arbitrary
  main <- arbitrary
  height <- arbitrary
  weight <- arbitrary
  txs <- resize 5 $ listOf $ arbitraryBinfoTx ctx
  return BinfoBlock {..}

arbitraryBinfoTx :: Ctx -> Gen BinfoTx
arbitraryBinfoTx ctx = do
  txid <- arbitraryTxHash
  version <- arbitrary
  inputs <- resize 5 $ listOf1 $ arbitraryBinfoTxInput ctx
  outputs <- resize 5 $ listOf1 $ arbitraryBinfoTxOutput ctx
  let inputCount = fromIntegral $ length inputs
      outputCount = fromIntegral $ length outputs
  size <- arbitrary
  weight <- arbitrary
  fee <- arbitrary
  relayed <- cs <$> listOf arbitraryUnicodeChar
  locktime <- arbitrary
  index <- arbitrary
  doubleSpend <- arbitrary
  rbf <- arbitrary
  timestamp <- arbitrary
  blockIndex <- arbitrary
  blockHeight <- arbitrary
  balance <- arbitrary
  return BinfoTx {..}

arbitraryBinfoTxInput :: Ctx -> Gen BinfoTxInput
arbitraryBinfoTxInput ctx = do
  sequence <- arbitrary
  witness <- B.pack <$> listOf arbitrary
  script <- B.pack <$> listOf arbitrary
  index <- arbitrary
  output <- arbitraryBinfoTxOutput ctx
  return BinfoTxInput {..}

arbitraryBinfoTxOutput :: Ctx -> Gen BinfoTxOutput
arbitraryBinfoTxOutput ctx = do
  typ <- arbitrary
  spent <- arbitrary
  value <- arbitrary
  index <- arbitrary
  txidx <- arbitrary
  script <- B.pack <$> listOf arbitrary
  spenders <- arbitrary
  address <- arbitraryMaybe arbitraryAddress
  xpub <- arbitraryMaybe $ arbitraryBinfoXPubPath ctx
  return BinfoTxOutput {..}

instance Arbitrary BinfoSpender where
  arbitrary = do
    txidx <- arbitrary
    input <- arbitrary
    return BinfoSpender {..}

arbitraryBinfoXPubPath :: Ctx -> Gen BinfoXPubPath
arbitraryBinfoXPubPath ctx = do
  key <- snd <$> arbitraryXPubKey ctx
  deriv <- arbitrarySoftPath
  return BinfoXPubPath {..}

instance Arbitrary BinfoInfo where
  arbitrary = do
    connected <- arbitrary
    conversion <- arbitrary
    fiat <- arbitrary
    crypto <- arbitrary
    head <- arbitrary
    return BinfoInfo {..}

instance Arbitrary BinfoBlockInfo where
  arbitrary = do
    hash <- arbitraryBlockHash
    height <- arbitrary
    timestamp <- arbitrary
    index <- arbitrary
    return BinfoBlockInfo {..}

instance Arbitrary BinfoSymbol where
  arbitrary = do
    code <- cs <$> listOf1 arbitraryUnicodeChar
    symbol <- cs <$> listOf1 arbitraryUnicodeChar
    name <- cs <$> listOf1 arbitraryUnicodeChar
    conversion <- arbitrary
    after <- arbitrary
    local <- arbitrary
    return BinfoSymbol {..}

instance Arbitrary BinfoRate where
  arbitrary = BinfoRate <$> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary BinfoTicker where
  arbitrary = do
    fifteen <- arbitrary
    sell <- arbitrary
    buy <- arbitrary
    last <- arbitrary
    symbol <- cs <$> listOf1 arbitraryUnicodeChar
    return BinfoTicker {..}

instance Arbitrary BinfoHistory where
  arbitrary = do
    date <- cs <$> listOf1 arbitraryUnicodeChar
    time <- cs <$> listOf1 arbitraryUnicodeChar
    typ <- cs <$> listOf1 arbitraryUnicodeChar
    amount <- arbitrary
    valueThen <- arbitrary
    valueNow <- arbitrary
    rateThen <- arbitrary
    txid <- arbitraryTxHash
    fee <- arbitrary
    return BinfoHistory {..}

arbitraryBinfoUnspent :: Ctx -> Gen BinfoUnspent
arbitraryBinfoUnspent ctx = do
  txid <- arbitraryTxHash
  index <- arbitrary
  script <- B.pack <$> listOf arbitrary
  value <- arbitrary
  confirmations <- arbitrary
  txidx <- arbitrary
  xpub <- arbitraryMaybe $ arbitraryBinfoXPubPath ctx
  return BinfoUnspent {..}

arbitraryBinfoUnspents :: Ctx -> Gen BinfoUnspents
arbitraryBinfoUnspents ctx =
  fmap BinfoUnspents $ listOf $ arbitraryBinfoUnspent ctx

instance Arbitrary BinfoHeader where
  arbitrary =
    BinfoHeader
      <$> arbitraryBlockHash
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary

arbitraryBinfoMempool :: Ctx -> Gen BinfoMempool
arbitraryBinfoMempool ctx =
  fmap BinfoMempool $ listOf $ arbitraryBinfoTx ctx

instance Arbitrary BinfoBlockInfos where
  arbitrary = BinfoBlockInfos <$> arbitrary
