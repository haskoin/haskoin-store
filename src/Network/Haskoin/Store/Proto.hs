{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
module Network.Haskoin.Store.Proto where

import           Data.ByteString                                          (ByteString)
import qualified Data.ByteString                                          as B
import qualified Data.ByteString.Lazy                                     as L
import qualified Data.ByteString.Lazy.Char8                               as L8
import qualified Data.ByteString.Short                                    as S
import qualified Data.Sequence                                            as Seq
import           Data.Serialize
import qualified Data.Text                                                as T
import qualified Data.Text.Encoding                                       as E
import           Data.Version
import           Haskoin
import           Network.Haskoin.Store.Data
import qualified Network.Haskoin.Store.ProtocolBuffers.Balance            as P.Balance
import qualified Network.Haskoin.Store.ProtocolBuffers.BalanceList        as P.BalanceList
import qualified Network.Haskoin.Store.ProtocolBuffers.BlockData          as P.BlockData
import qualified Network.Haskoin.Store.ProtocolBuffers.BlockDataList      as P.BlockDataList
import qualified Network.Haskoin.Store.ProtocolBuffers.BlockRef           as P.BlockRef
import qualified Network.Haskoin.Store.ProtocolBuffers.BlockRef.Block     as P.BlockRef.Block
import qualified Network.Haskoin.Store.ProtocolBuffers.BlockRef.Block_ref as P.BlockRef.Block_ref
import qualified Network.Haskoin.Store.ProtocolBuffers.BlockRef.Mempool   as P.BlockRef.Mempool
import qualified Network.Haskoin.Store.ProtocolBuffers.BlockTx            as P.BlockTx
import qualified Network.Haskoin.Store.ProtocolBuffers.BlockTxList        as P.BlockTxList
import qualified Network.Haskoin.Store.ProtocolBuffers.Error              as P.Error
import qualified Network.Haskoin.Store.ProtocolBuffers.Event              as P.Event
import qualified Network.Haskoin.Store.ProtocolBuffers.Event.Type         as P.Event.Type
import qualified Network.Haskoin.Store.ProtocolBuffers.EventList          as P.EventList
import qualified Network.Haskoin.Store.ProtocolBuffers.HealthCheck        as P.HealthCheck
import qualified Network.Haskoin.Store.ProtocolBuffers.Input              as P.Input
import qualified Network.Haskoin.Store.ProtocolBuffers.Output             as P.Output
import qualified Network.Haskoin.Store.ProtocolBuffers.Peer               as P.Peer
import qualified Network.Haskoin.Store.ProtocolBuffers.PeerList           as P.PeerList
import qualified Network.Haskoin.Store.ProtocolBuffers.Spender            as P.Spender
import qualified Network.Haskoin.Store.ProtocolBuffers.Transaction        as P.Transaction
import qualified Network.Haskoin.Store.ProtocolBuffers.TransactionList    as P.TransactionList
import qualified Network.Haskoin.Store.ProtocolBuffers.TxAfterHeight      as P.TxAfterHeight
import qualified Network.Haskoin.Store.ProtocolBuffers.TxId               as P.TxId
import qualified Network.Haskoin.Store.ProtocolBuffers.TxIdList           as P.TxIdList
import qualified Network.Haskoin.Store.ProtocolBuffers.Unspent            as P.Unspent
import qualified Network.Haskoin.Store.ProtocolBuffers.UnspentList        as P.UnspentList
import qualified Network.Haskoin.Store.ProtocolBuffers.XPubBalance        as P.XPubBalance
import qualified Network.Haskoin.Store.ProtocolBuffers.XPubBalanceList    as P.XPubBalanceList
import qualified Network.Haskoin.Store.ProtocolBuffers.XPubUnspent        as P.XPubUnspent
import qualified Network.Haskoin.Store.ProtocolBuffers.XPubUnspentList    as P.XPubUnspentList
import           Paths_haskoin_store                                      as Paths
import           Text.ProtocolBuffers

class ProtoSerial a where
    protoSerial :: Network -> a -> L.ByteString

protoAddress :: Network -> Address -> Utf8
protoAddress net = Utf8 . L.fromStrict . E.encodeUtf8 . addrToString net

protoPkScriptAddr :: Network -> ByteString -> Maybe Utf8
protoPkScriptAddr net pks =
    Utf8 . L.fromStrict . E.encodeUtf8 . addrToString net <$>
    eitherToMaybe (scriptToAddressBS pks)

protoBalance :: Network -> Balance -> P.Balance.Balance
protoBalance net Balance { balanceAddress = a
                         , balanceAmount = v
                         , balanceZero = z
                         , balanceUnspentCount = u
                         , balanceTxCount = c
                         , balanceTotalReceived = t
                         } =
    P.Balance.Balance
        { P.Balance.address = protoAddress net a
        , P.Balance.confirmed = v
        , P.Balance.unconfirmed = z
        , P.Balance.utxo = u
        , P.Balance.received = t
        , P.Balance.txs = c
        }

instance ProtoSerial Balance where
    protoSerial net = messagePut . protoBalance net

protoBalanceList :: Network -> [Balance] -> P.BalanceList.BalanceList
protoBalanceList net bs =
    P.BalanceList.BalanceList
        {P.BalanceList.balance = Seq.fromList (map (protoBalance net) bs)}

instance ProtoSerial [Balance] where
    protoSerial net = messagePut . protoBalanceList net

protoBlockRef :: BlockRef -> P.BlockRef.BlockRef
protoBlockRef BlockRef {blockRefHeight = h, blockRefPos = p} =
    P.BlockRef.BlockRef
        { P.BlockRef.block_ref =
              Just
                  (P.BlockRef.Block_ref.Block
                       { P.BlockRef.Block_ref.block =
                             P.BlockRef.Block.Block
                                 { P.BlockRef.Block.height = h
                                 , P.BlockRef.Block.position = p
                                 }
                       })
        }
protoBlockRef MemRef {memRefTime = PreciseUnixTime t} =
    P.BlockRef.BlockRef
        { P.BlockRef.block_ref =
              Just
                  (P.BlockRef.Block_ref.Mempool
                       { P.BlockRef.Block_ref.mempool =
                             P.BlockRef.Mempool.Mempool
                                 {P.BlockRef.Mempool.mempool = t}
                       })
        }

instance ProtoSerial BlockRef where
    protoSerial _ = messagePut . protoBlockRef

protoBlockTx :: BlockTx -> P.BlockTx.BlockTx
protoBlockTx BlockTx {blockTxBlock = b, blockTxHash = t} =
    P.BlockTx.BlockTx
        { P.BlockTx.block = protoBlockRef b
        , P.BlockTx.txid = protoTxId t
        }

instance ProtoSerial BlockTx where
    protoSerial _ = messagePut . protoBlockTx

protoBlockTxList :: [BlockTx] -> P.BlockTxList.BlockTxList
protoBlockTxList bs =
    P.BlockTxList.BlockTxList
        {P.BlockTxList.blocktx = Seq.fromList (map protoBlockTx bs)}

instance ProtoSerial [BlockTx] where
    protoSerial _ = messagePut . protoBlockTxList

protoUnspent :: Network -> Unspent -> P.Unspent.Unspent
protoUnspent net Unspent { unspentBlock = b
                         , unspentPoint = OutPoint { outPointHash = t
                                                   , outPointIndex = i
                                                   }
                         , unspentAmount = v
                         , unspentScript = s
                         } =
    P.Unspent.Unspent
        { P.Unspent.txid = protoTxId t
        , P.Unspent.index = i
        , P.Unspent.pkscript = L.fromStrict (S.fromShort s)
        , P.Unspent.value = v
        , P.Unspent.block = protoBlockRef b
        , P.Unspent.address = protoPkScriptAddr net (S.fromShort s)
        }

instance ProtoSerial Unspent where
    protoSerial net = messagePut . protoUnspent net

protoUnspentList :: Network -> [Unspent] -> P.UnspentList.UnspentList
protoUnspentList net us =
    P.UnspentList.UnspentList
        {P.UnspentList.unspent = Seq.fromList (map (protoUnspent net) us)}

instance ProtoSerial [Unspent] where
    protoSerial net = messagePut . protoUnspentList net

protoBlockData :: BlockData -> P.BlockData.BlockData
protoBlockData BlockData { blockDataHeight = g
                         , blockDataMainChain = m
                         , blockDataHeader = h
                         , blockDataSize = s
                         , blockDataWeight = e
                         , blockDataTxs = t
                         , blockDataOutputs = o
                         , blockDataFees = f
                         , blockDataSubsidy = y
                         } =
    P.BlockData.BlockData
        { P.BlockData.hash = encodeLazy (headerHash h)
        , P.BlockData.size = s
        , P.BlockData.height = g
        , P.BlockData.mainchain = m
        , P.BlockData.previous = encodeLazy (prevBlock h)
        , P.BlockData.time = blockTimestamp h
        , P.BlockData.version = blockVersion h
        , P.BlockData.bits = blockBits h
        , P.BlockData.nonce = bhNonce h
        , P.BlockData.tx = encodeLazy <$> Seq.fromList t
        , P.BlockData.merkle = encodeLazy (merkleRoot h)
        , P.BlockData.fees = f
        , P.BlockData.outputs = o
        , P.BlockData.subsidy = y
        , P.BlockData.weight = e
        }

instance ProtoSerial BlockData where
    protoSerial _ = messagePut . protoBlockData

protoBlockDataList :: [BlockData] -> P.BlockDataList.BlockDataList
protoBlockDataList bs =
    P.BlockDataList.BlockDataList
        {P.BlockDataList.blockdata = Seq.fromList (map protoBlockData bs)}

instance ProtoSerial [BlockData] where
    protoSerial _ = messagePut . protoBlockDataList

protoInput :: Network -> Input -> P.Input.Input
protoInput _ Coinbase { inputPoint = OutPoint { outPointHash = h
                                              , outPointIndex = i
                                              }
                      , inputSequence = q
                      , inputSigScript = s
                      , inputWitness = w
                      } =
    P.Input.Input
        { P.Input.coinbase = True
        , P.Input.txid = protoTxId h
        , P.Input.output = i
        , P.Input.sigscript = L.fromStrict s
        , P.Input.sequence = q
        , P.Input.witness = Seq.fromList (maybe [] (map L.fromStrict) w)
        , P.Input.value = Nothing
        , P.Input.pkscript = Nothing
        , P.Input.address = Nothing
        }
protoInput net Input { inputPoint = OutPoint { outPointHash = h
                                             , outPointIndex = i
                                             }
                     , inputSequence = q
                     , inputSigScript = s
                     , inputPkScript = k
                     , inputAmount = v
                     , inputWitness = w
                     } =
    P.Input.Input
        { P.Input.coinbase = False
        , P.Input.txid = protoTxId h
        , P.Input.output = i
        , P.Input.sigscript = L.fromStrict s
        , P.Input.sequence = q
        , P.Input.witness = Seq.fromList (maybe [] (map L.fromStrict) w)
        , P.Input.value = Just v
        , P.Input.pkscript = Just (L.fromStrict k)
        , P.Input.address = protoPkScriptAddr net k
        }

protoSpender :: Spender -> P.Spender.Spender
protoSpender Spender {spenderHash = h, spenderIndex = i} =
    P.Spender.Spender {P.Spender.txid = protoTxId h, P.Spender.input = i}

protoOutput :: Network -> Output -> P.Output.Output
protoOutput net Output {outputAmount = v, outputScript = k, outputSpender = s} =
    P.Output.Output
        { P.Output.pkscript = L.fromStrict k
        , P.Output.value = v
        , P.Output.address = protoPkScriptAddr net k
        , P.Output.spender = protoSpender <$> s
        }

protoTransaction :: Network -> Transaction -> P.Transaction.Transaction
protoTransaction net tx@Transaction { transactionBlock = b
                                    , transactionVersion = v
                                    , transactionLockTime = l
                                    , transactionInputs = i
                                    , transactionOutputs = o
                                    , transactionDeleted = d
                                    , transactionRBF = r
                                    , transactionTime = t
                                    } =
    P.Transaction.Transaction
        { P.Transaction.txid = protoTxId (txHash (transactionData tx))
        , P.Transaction.size =
              fromIntegral (B.length (encode (transactionData tx)))
        , P.Transaction.version = v
        , P.Transaction.locktime = l
        , P.Transaction.block = protoBlockRef b
        , P.Transaction.deleted = d
        , P.Transaction.fee =
              if all isCoinbase i
                  then 0
                  else sum (map inputAmount i) - sum (map outputAmount o)
        , P.Transaction.rbf = r
        , P.Transaction.time = t
        , P.Transaction.inputs = Seq.fromList (map (protoInput net) i)
        , P.Transaction.outputs = Seq.fromList (map (protoOutput net) o)
        , P.Transaction.weight =
              if getSegWit net
                  then Just w
                  else Nothing
        }
  where
    w =
        let base = B.length $ encode (transactionData tx) {txWitness = []}
            wit = B.length $ encode (transactionData tx)
         in fromIntegral $ base * 3 + wit

instance ProtoSerial Transaction where
    protoSerial net = messagePut . protoTransaction net

protoTransactionList :: Network -> [Transaction] -> P.TransactionList.TransactionList
protoTransactionList net ts =
    P.TransactionList.TransactionList
        { P.TransactionList.transaction =
              Seq.fromList (map (protoTransaction net) ts)
        }

instance ProtoSerial [Transaction] where
    protoSerial net = messagePut . protoTransactionList net

protoTxId :: TxHash -> P.TxId.TxId
protoTxId t = P.TxId.TxId {P.TxId.txid = encodeLazy t}

protoTxIdList :: [TxHash] -> P.TxIdList.TxIdList
protoTxIdList ts =
    P.TxIdList.TxIdList {P.TxIdList.txid = Seq.fromList (map protoTxId ts)}

instance ProtoSerial [TxHash] where
    protoSerial _ = messagePut . protoTxIdList

protoPeer :: PeerInformation -> P.Peer.Peer
protoPeer PeerInformation { peerUserAgent = u
                          , peerAddress = a
                          , peerVersion = v
                          , peerServices = s
                          , peerRelay = r
                          } =
    P.Peer.Peer
        { P.Peer.useragent =
              either (const (Utf8 L.empty)) id (toUtf8 (L.fromStrict u))
        , P.Peer.address = Utf8 (L8.pack (show a))
        , P.Peer.version = v
        , P.Peer.services = s
        , P.Peer.relay = r
        }

instance ProtoSerial PeerInformation where
    protoSerial _ = messagePut . protoPeer

protoPeerList :: [PeerInformation] -> P.PeerList.PeerList
protoPeerList ps =
    P.PeerList.PeerList {P.PeerList.peer = Seq.fromList (map protoPeer ps)}

instance ProtoSerial [PeerInformation] where
    protoSerial _ = messagePut . protoPeerList

protoXPubBalance :: Network -> XPubBal -> P.XPubBalance.XPubBalance
protoXPubBalance net XPubBal {xPubBalPath = p, xPubBal = b} =
    P.XPubBalance.XPubBalance
        { P.XPubBalance.path = Seq.fromList p
        , P.XPubBalance.balance = protoBalance net b
        }

instance ProtoSerial XPubBal where
    protoSerial net = messagePut . protoXPubBalance net

protoXPubBalanceList :: Network -> [XPubBal] -> P.XPubBalanceList.XPubBalanceList
protoXPubBalanceList net bs =
    P.XPubBalanceList.XPubBalanceList
        { P.XPubBalanceList.xpubbalance =
              Seq.fromList (map (protoXPubBalance net) bs)
        }

instance ProtoSerial [XPubBal] where
    protoSerial net = messagePut . protoXPubBalanceList net

protoXPubUnspent :: Network -> XPubUnspent -> P.XPubUnspent.XPubUnspent
protoXPubUnspent net XPubUnspent {xPubUnspentPath = p, xPubUnspent = u} =
    P.XPubUnspent.XPubUnspent
        { P.XPubUnspent.path = Seq.fromList p
        , P.XPubUnspent.unspent = protoUnspent net u
        }

instance ProtoSerial XPubUnspent where
    protoSerial net = messagePut . protoXPubUnspent net

protoXPubUnspentList :: Network -> [XPubUnspent] -> P.XPubUnspentList.XPubUnspentList
protoXPubUnspentList net us =
    P.XPubUnspentList.XPubUnspentList
        { P.XPubUnspentList.xpubunspent =
              Seq.fromList (map (protoXPubUnspent net) us)
        }

instance ProtoSerial [XPubUnspent] where
    protoSerial net = messagePut . protoXPubUnspentList net

protoEvent :: Event -> P.Event.Event
protoEvent (EventTx h) =
    P.Event.Event {P.Event.type' = P.Event.Type.TX, P.Event.id = encodeLazy h}
protoEvent (EventBlock h) =
    P.Event.Event
        {P.Event.type' = P.Event.Type.BLOCK, P.Event.id = encodeLazy h}

instance ProtoSerial Event where
    protoSerial _ = messagePut . protoEvent

protoEventList :: [Event] -> P.EventList.EventList
protoEventList es =
    P.EventList.EventList {P.EventList.event = Seq.fromList (map protoEvent es)}

instance ProtoSerial [Event] where
    protoSerial _ = messagePut . protoEventList

protoHealthCheck :: HealthCheck -> P.HealthCheck.HealthCheck
protoHealthCheck HealthCheck { healthHeaderBest = maybe_header_hash
                             , healthHeaderHeight = maybe_header_height
                             , healthBlockBest = maybe_block_hash
                             , healthBlockHeight = maybe_block_height
                             , healthPeers = maybe_peer_count
                             , healthNetwork = network_name
                             , healthOK = ok
                             , healthSynced = synced
                             } =
    P.HealthCheck.HealthCheck
        { P.HealthCheck.ok = ok
        , P.HealthCheck.synced = synced
        , P.HealthCheck.version = Utf8 (L8.pack (showVersion Paths.version))
        , P.HealthCheck.net = Utf8 (L8.pack network_name)
        , P.HealthCheck.peers = fromIntegral <$> maybe_peer_count
        , P.HealthCheck.headers_hash = encodeLazy <$> maybe_header_hash
        , P.HealthCheck.headers_height = maybe_header_height
        , P.HealthCheck.blocks_hash = encodeLazy <$> maybe_block_hash
        , P.HealthCheck.blocks_height = maybe_block_height
        }

instance ProtoSerial HealthCheck where
    protoSerial _ = messagePut . protoHealthCheck

protoTxAfterHeight :: TxAfterHeight -> P.TxAfterHeight.TxAfterHeight
protoTxAfterHeight (TxAfterHeight b) = P.TxAfterHeight.TxAfterHeight b

instance ProtoSerial TxAfterHeight where
    protoSerial _ = messagePut . protoTxAfterHeight

protoExcept :: Except -> P.Error.Error
protoExcept = P.Error.Error . Utf8 . L.fromStrict . E.encodeUtf8 . T.pack . show

instance ProtoSerial Except where
    protoSerial _ = messagePut . protoExcept

instance ProtoSerial TxId where
    protoSerial _ (TxId h) = messagePut (protoTxId h)
