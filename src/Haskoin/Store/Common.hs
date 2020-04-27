{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
module Haskoin.Store.Common
    ( BlockStoreMessage(..)
    , DeriveType(..)
    , Limit
    , Offset
    , BlockStore
    , UnixTime
    , getUnixTime
    , putUnixTime
    , BlockPos
    , NetWrap(..)
    , XPubSpec(..)
    , StoreRead(..)
    , StoreWrite(..)
    , BlockRef(..)
    , BlockTx(..)
    , confirmed
    , Balance(..)
    , BlockData(..)
    , StoreInput(..)
    , isCoinbase
    , Spender(..)
    , StoreOutput(..)
    , Prev(..)
    , TxData(..)
    , Unspent(..)
    , Transaction(..)
    , transactionData
    , fromTransaction
    , toTransaction
    , TxAfterHeight(..)
    , TxId(..)
    , PeerInformation(..)
    , XPubBal(..)
    , xPubBalsTxs
    , XPubUnspent(..)
    , xPubBalsUnspents
    , XPubSummary(..)
    , HealthCheck(..)
    , Event(..)
    , StoreEvent(..)
    , PubExcept(..)
    , zeroBalance
    , nullBalance
    , getTransaction
    , blockAtOrBefore
    , applyOffset
    , applyLimit
    , applyOffsetLimit
    , applyOffsetC
    , applyLimitC
    , applyOffsetLimitC
    , sortTxs
    , scriptToStringAddr
    ) where

import           Conduit                   (ConduitT, dropC, mapC, takeC)
import           Control.Applicative       ((<|>))
import           Control.DeepSeq           (NFData)
import           Control.Exception         (Exception)
import           Control.Monad             (guard, join, mzero)
import           Control.Monad.Trans       (lift)
import           Control.Monad.Trans.Maybe (MaybeT (..), runMaybeT)
import           Data.Aeson                (FromJSON (..), ToJSON (..),
                                            Value (..), object, (.!=), (.:),
                                            (.:?), (.=))
import qualified Data.Aeson                as A
import           Data.Aeson.Types          (Parser)
import           Data.ByteString           (ByteString)
import qualified Data.ByteString           as B
import           Data.ByteString.Short     (ShortByteString)
import qualified Data.ByteString.Short     as BSS
import           Data.Function             (on)
import           Data.Hashable             (Hashable (..))
import qualified Data.IntMap               as I
import           Data.IntMap.Strict        (IntMap)
import           Data.List                 (nub, partition, sortBy)
import           Data.Maybe                (catMaybes, isJust, listToMaybe,
                                            mapMaybe)
import           Data.Serialize            (Get, Put, Serialize (..),
                                            getWord32be, getWord64be, getWord8,
                                            putWord32be, putWord64be, putWord8)
import qualified Data.Serialize            as S
import           Data.String.Conversions   (cs)
import           Data.Text                 (Text)
import           Data.Word                 (Word32, Word64)
import           GHC.Generics              (Generic)
import           Haskoin                   (Address, Block, BlockHash,
                                            BlockHeader (..), BlockHeight,
                                            BlockNode, BlockWork, KeyIndex,
                                            Network (..), OutPoint (..),
                                            PubKeyI (..), RejectCode (..),
                                            Tx (..), TxHash (..), TxIn (..),
                                            TxOut (..), WitnessStack,
                                            XPubKey (..), addrToString,
                                            decodeHex, deriveAddr,
                                            deriveCompatWitnessAddr,
                                            deriveWitnessAddr, eitherToMaybe,
                                            encodeHex, headerHash, pubSubKey,
                                            scriptToAddressBS, stringToAddr,
                                            txHash, wrapPubKey)
import           Haskoin.Node              (Peer)
import           Network.Socket            (SockAddr)
import           NQE                       (Listen, Mailbox)
import qualified Paths_haskoin_store       as P

data DeriveType
    = DeriveNormal
    | DeriveP2SH
    | DeriveP2WPKH
    deriving (Show, Eq, Generic, NFData, Serialize)

-- | Messages for block store actor.
data BlockStoreMessage
    = BlockNewBest !BlockNode
      -- ^ new block header in chain
    | BlockPeerConnect !Peer !SockAddr
      -- ^ new peer connected
    | BlockPeerDisconnect !Peer !SockAddr
      -- ^ peer disconnected
    | BlockReceived !Peer !Block
      -- ^ new block received from a peer
    | BlockNotFound !Peer ![BlockHash]
      -- ^ block not found
    | BlockTxReceived !Peer !Tx
      -- ^ transaction received from peer
    | BlockTxAvailable !Peer ![TxHash]
      -- ^ peer has transactions available
    | BlockPing !(Listen ())
      -- ^ internal housekeeping ping

-- | Mailbox for block store.
type BlockStore = Mailbox BlockStoreMessage

data XPubSpec =
    XPubSpec
        { xPubSpecKey    :: !XPubKey
        , xPubDeriveType :: !DeriveType
        } deriving (Show, Eq, Generic, NFData)

instance Hashable XPubSpec where
    hashWithSalt i XPubSpec {xPubSpecKey = XPubKey {xPubKey = pubkey}} =
        hashWithSalt i pubkey

instance Serialize XPubSpec where
    put XPubSpec {xPubSpecKey = k, xPubDeriveType = t} = do
        put (xPubDepth k)
        put (xPubParent k)
        put (xPubIndex k)
        put (xPubChain k)
        put (wrapPubKey True (xPubKey k))
        put t
    get = do
        d <- get
        p <- get
        i <- get
        c <- get
        k <- get
        t <- get
        let x =
                XPubKey
                    { xPubDepth = d
                    , xPubParent = p
                    , xPubIndex = i
                    , xPubChain = c
                    , xPubKey = pubKeyPoint k
                    }
        return XPubSpec {xPubSpecKey = x, xPubDeriveType = t}

type DeriveAddr = XPubKey -> KeyIndex -> Address

type UnixTime = Word64
type BlockPos = Word32

type Offset = Word32
type Limit = Word32

data NetWrap a = NetWrap Network a

instance ToJSON (NetWrap a) => ToJSON (NetWrap [a]) where
    toJSON (NetWrap net xs) = toJSON $ map (toJSON . NetWrap net) xs

class Monad m =>
      StoreRead m
    where
    getNetwork :: m Network
    getBestBlock :: m (Maybe BlockHash)
    getBlocksAtHeight :: BlockHeight -> m [BlockHash]
    getBlock :: BlockHash -> m (Maybe BlockData)
    getTxData :: TxHash -> m (Maybe TxData)
    getOrphanTx :: TxHash -> m (Maybe (UnixTime, Tx))
    getOrphans :: m [(UnixTime, Tx)]
    getSpenders :: TxHash -> m (IntMap Spender)
    getSpender :: OutPoint -> m (Maybe Spender)
    getBalance :: Address -> m Balance
    getBalance a = head <$> getBalances [a]
    getBalances :: [Address] -> m [Balance]
    getBalances as = mapM getBalance as
    getAddressesTxs :: [Address] -> Maybe BlockRef -> Maybe Limit -> m [BlockTx]
    getAddressTxs :: Address -> Maybe BlockRef -> Maybe Limit -> m [BlockTx]
    getAddressTxs a = getAddressesTxs [a]
    getUnspent :: OutPoint -> m (Maybe Unspent)
    getAddressUnspents ::
           Address -> Maybe BlockRef -> Maybe Limit -> m [Unspent]
    getAddressUnspents a = getAddressesUnspents [a]
    getAddressesUnspents ::
           [Address] -> Maybe BlockRef -> Maybe Limit -> m [Unspent]
    getMempool :: m [BlockTx]
    xPubBals :: XPubSpec -> m [XPubBal]
    xPubBals xpub = do
        gap <- getMaxGap
        ext <-
            derive_until_gap
                gap
                0
                (deriveAddresses
                     (deriveFunction (xPubDeriveType xpub))
                     (pubSubKey (xPubSpecKey xpub) 0)
                     0)
        chg <-
            derive_until_gap
                gap
                1
                (deriveAddresses
                     (deriveFunction (xPubDeriveType xpub))
                     (pubSubKey (xPubSpecKey xpub) 1)
                     0)
        return (ext ++ chg)
      where
        xbalance m b n = XPubBal {xPubBalPath = [m, n], xPubBal = b}
        derive_until_gap _ _ [] = return []
        derive_until_gap gap m as = do
            let (as1, as2) = splitAt (fromIntegral gap) as
            bs <- getBalances (map snd as1)
            let xbs = zipWith (xbalance m) bs (map fst as1)
            if all nullBalance bs
                then return xbs
                else (xbs <>) <$> derive_until_gap gap m as2
    xPubSummary :: XPubSpec -> m XPubSummary
    xPubSummary xpub = do
        bs <- filter (not . nullBalance . xPubBal) <$> xPubBals xpub
        let ex = foldl max 0 [i | XPubBal {xPubBalPath = [0, i]} <- bs]
            ch = foldl max 0 [i | XPubBal {xPubBalPath = [1, i]} <- bs]
            uc =
                sum
                    [ c
                    | XPubBal {xPubBal = Balance {balanceUnspentCount = c}} <-
                          bs
                    ]
            xt = [b | b@XPubBal {xPubBalPath = [0, _]} <- bs]
            rx =
                sum
                    [ r
                    | XPubBal {xPubBal = Balance {balanceTotalReceived = r}} <-
                          xt
                    ]
        return
            XPubSummary
                { xPubSummaryConfirmed = sum (map (balanceAmount . xPubBal) bs)
                , xPubSummaryZero = sum (map (balanceZero . xPubBal) bs)
                , xPubSummaryReceived = rx
                , xPubUnspentCount = uc
                , xPubChangeIndex = ch
                , xPubExternalIndex = ex
                }
    xPubUnspents ::
           XPubSpec
        -> Maybe BlockRef
        -> Offset
        -> Maybe Limit
        -> m [XPubUnspent]
    xPubUnspents xpub start offset limit = do
        xs <- filter positive <$> xPubBals xpub
        applyOffsetLimit offset limit <$> go xs
      where
        positive XPubBal {xPubBal = Balance {balanceUnspentCount = c}} = c > 0
        go [] = return []
        go (XPubBal {xPubBalPath = p, xPubBal = Balance {balanceAddress = a}}:xs) = do
            uns <- getAddressUnspents a start limit
            let xuns =
                    map
                        (\t ->
                             XPubUnspent {xPubUnspentPath = p, xPubUnspent = t})
                        uns
            (xuns <>) <$> go xs
    xPubTxs ::
           XPubSpec -> Maybe BlockRef -> Offset -> Maybe Limit -> m [BlockTx]
    xPubTxs xpub start offset limit = do
        bs <- xPubBals xpub
        let as = map (balanceAddress . xPubBal) bs
        ts <- concat <$> mapM (\a -> getAddressTxs a start limit) as
        let ts' = nub $ sortBy (flip compare `on` blockTxBlock) ts
        return $ applyOffsetLimit offset limit ts'
    getMaxGap :: m Word32
    getMaxGap = return 32

class StoreWrite m where
    setBest :: BlockHash -> m ()
    insertBlock :: BlockData -> m ()
    setBlocksAtHeight :: [BlockHash] -> BlockHeight -> m ()
    insertTx :: TxData -> m ()
    insertSpender :: OutPoint -> Spender -> m ()
    deleteSpender :: OutPoint -> m ()
    insertAddrTx :: Address -> BlockTx -> m ()
    deleteAddrTx :: Address -> BlockTx -> m ()
    insertAddrUnspent :: Address -> Unspent -> m ()
    deleteAddrUnspent :: Address -> Unspent -> m ()
    setMempool :: [BlockTx] -> m ()
    insertOrphanTx :: Tx -> UnixTime -> m ()
    deleteOrphanTx :: TxHash -> m ()
    setBalance :: Balance -> m ()
    insertUnspent :: Unspent -> m ()
    deleteUnspent :: OutPoint -> m ()

deriveAddresses :: DeriveAddr -> XPubKey -> Word32 -> [(Word32, Address)]
deriveAddresses derive xpub start = map (\i -> (i, derive xpub i)) [start ..]

deriveFunction :: DeriveType -> DeriveAddr
deriveFunction DeriveNormal i = fst . deriveAddr i
deriveFunction DeriveP2SH i   = fst . deriveCompatWitnessAddr i
deriveFunction DeriveP2WPKH i = fst . deriveWitnessAddr i

xPubBalsUnspents ::
       StoreRead m
    => [XPubBal]
    -> Maybe BlockRef
    -> Offset
    -> Maybe Limit
    -> m [XPubUnspent]
xPubBalsUnspents bals start offset limit = do
    let xs = filter positive bals
    applyOffsetLimit offset limit <$> go xs
  where
    positive XPubBal {xPubBal = Balance {balanceUnspentCount = c}} = c > 0
    go [] = return []
    go (XPubBal {xPubBalPath = p, xPubBal = Balance {balanceAddress = a}}:xs) = do
        uns <- getAddressUnspents a start limit
        let xuns =
                map
                    (\t -> XPubUnspent {xPubUnspentPath = p, xPubUnspent = t})
                    uns
        (xuns <>) <$> go xs

xPubBalsTxs ::
       StoreRead m
    => [XPubBal]
    -> Maybe BlockRef
    -> Offset
    -> Maybe Limit
    -> m [BlockTx]
xPubBalsTxs bals start offset limit = do
    let as = map balanceAddress . filter (not . nullBalance) $ map xPubBal bals
    ts <- concat <$> mapM (\a -> getAddressTxs a start limit) as
    let ts' = nub $ sortBy (flip compare `on` blockTxBlock) ts
    return $ applyOffsetLimit offset limit ts'

getTransaction ::
       (Monad m, StoreRead m) => TxHash -> m (Maybe Transaction)
getTransaction h = runMaybeT $ do
    d <- MaybeT $ getTxData h
    sm <- lift $ getSpenders h
    return $ toTransaction d sm

blockAtOrBefore :: (Monad m, StoreRead m) => UnixTime -> m (Maybe BlockData)
blockAtOrBefore q = runMaybeT $ do
    a <- g 0
    b <- MaybeT getBestBlock >>= MaybeT . getBlock
    f a b
  where
    f a b
        | t b <= q = return b
        | t a > q = mzero
        | h b - h a == 1 = return a
        | otherwise = do
              let x = h a + (h b - h a) `div` 2
              m <- g x
              if t m > q then f a m else f m b
    g x = MaybeT (listToMaybe <$> getBlocksAtHeight x) >>= MaybeT . getBlock
    h = blockDataHeight
    t = fromIntegral . blockTimestamp . blockDataHeader

-- | Serialize such that ordering is inverted.
putUnixTime :: Word64 -> Put
putUnixTime w = putWord64be $ maxBound - w

getUnixTime :: Get Word64
getUnixTime = (maxBound -) <$> getWord64be

-- | Reference to a block where a transaction is stored.
data BlockRef
    = BlockRef
          { blockRefHeight :: !BlockHeight
      -- ^ block height in the chain
          , blockRefPos    :: !Word32
      -- ^ position of transaction within the block
          }
    | MemRef
          { memRefTime :: !UnixTime
          }
    deriving (Show, Read, Eq, Ord, Generic, Hashable, NFData)

-- | Serialized entities will sort in reverse order.
instance Serialize BlockRef where
    put MemRef {memRefTime = t} = do
        putWord8 0x00
        putUnixTime t
    put BlockRef {blockRefHeight = h, blockRefPos = p} = do
        putWord8 0x01
        putWord32be (maxBound - h)
        putWord32be (maxBound - p)
    get = getmemref <|> getblockref
      where
        getmemref = do
            guard . (== 0x00) =<< getWord8
            MemRef <$> getUnixTime
        getblockref = do
            guard . (== 0x01) =<< getWord8
            h <- (maxBound -) <$> getWord32be
            p <- (maxBound -) <$> getWord32be
            return BlockRef {blockRefHeight = h, blockRefPos = p}

confirmed :: BlockRef -> Bool
confirmed BlockRef {} = True
confirmed MemRef {}   = False

instance ToJSON BlockRef where
    toJSON BlockRef {blockRefHeight = h, blockRefPos = p} =
        object ["height" .= h, "position" .= p]
    toJSON MemRef {memRefTime = t} = object ["mempool" .= t]

instance FromJSON BlockRef where
    parseJSON = A.withObject "blockref" $ \o -> b o <|> m o
      where
        b o = do
            height <- o .: "height"
            position <- o .: "position"
            return BlockRef {blockRefHeight = height, blockRefPos = position}
        m o = do
            mempool <- o .: "mempool"
            return MemRef {memRefTime = mempool}

-- | Transaction in relation to an address.
data BlockTx = BlockTx
    { blockTxBlock :: !BlockRef
      -- ^ block information
    , blockTxHash  :: !TxHash
      -- ^ transaction hash
    } deriving (Show, Eq, Ord, Generic, Serialize, Hashable, NFData)

instance ToJSON BlockTx where
    toJSON btx = object ["txid" .= blockTxHash btx, "block" .= blockTxBlock btx]

instance FromJSON BlockTx where
    parseJSON =
        A.withObject "blocktx" $ \o -> do
            txid <- o .: "txid"
            block <- o .: "block"
            return BlockTx {blockTxBlock = block, blockTxHash = txid}

-- | Address balance information.
data Balance =
    Balance
        { balanceAddress       :: !Address
      -- ^ address balance
        , balanceAmount        :: !Word64
      -- ^ confirmed balance
        , balanceZero          :: !Word64
      -- ^ unconfirmed balance
        , balanceUnspentCount  :: !Word64
      -- ^ number of unspent outputs
        , balanceTxCount       :: !Word64
      -- ^ number of transactions
        , balanceTotalReceived :: !Word64
      -- ^ total amount from all outputs in this address
        }
    deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable, NFData)

zeroBalance :: Address -> Balance
zeroBalance a =
    Balance
        { balanceAddress = a
        , balanceAmount = 0
        , balanceUnspentCount = 0
        , balanceZero = 0
        , balanceTxCount = 0
        , balanceTotalReceived = 0
        }

nullBalance :: Balance -> Bool
nullBalance Balance { balanceAmount = 0
                    , balanceUnspentCount = 0
                    , balanceZero = 0
                    , balanceTxCount = 0
                    , balanceTotalReceived = 0
                    } = True
nullBalance _ = False

instance ToJSON (NetWrap Balance) where
    toJSON (NetWrap net b) =
        object $
        [ "address" .= addrToString net (balanceAddress b)
        , "confirmed" .= balanceAmount b
        , "unconfirmed" .= balanceZero b
        , "utxo" .= balanceUnspentCount b
        , "txs" .= balanceTxCount b
        , "received" .= balanceTotalReceived b
        ]

instance FromJSON (Network -> Maybe Balance) where
    parseJSON =
        A.withObject "balance" $ \o -> do
            amount <- o .: "confirmed"
            unconfirmed <- o .: "unconfirmed"
            utxo <- o .: "utxo"
            txs <- o .: "txs"
            received <- o .: "received"
            address <- o .: "address"
            return $ \net ->
                stringToAddr net address >>= \a ->
                    return
                        Balance
                            { balanceAddress = a
                            , balanceAmount = amount
                            , balanceUnspentCount = utxo
                            , balanceZero = unconfirmed
                            , balanceTxCount = txs
                            , balanceTotalReceived = received
                            }

-- | Unspent output.
data Unspent = Unspent
    { unspentBlock   :: !BlockRef
    , unspentPoint   :: !OutPoint
    , unspentAmount  :: !Word64
    , unspentScript  :: !ShortByteString
    , unspentAddress :: !(Maybe String)
    } deriving (Show, Eq, Ord, Generic, Hashable, Serialize, NFData)

instance ToJSON Unspent where
    toJSON u =
        object $
        [ "address" .= unspentAddress u
        , "block" .= unspentBlock u
        , "txid" .= outPointHash (unspentPoint u)
        , "index" .= outPointIndex (unspentPoint u)
        , "pkscript" .= script
        , "value" .= unspentAmount u
        ]
      where
        bsscript = BSS.fromShort (unspentScript u)
        script = String (encodeHex bsscript)

instance FromJSON Unspent where
    parseJSON =
        A.withObject "unspent" $ \o -> do
            block <- o .: "block"
            txid <- o .: "txid"
            index <- o .: "index"
            value <- o .: "value"
            script <- BSS.toShort <$> (o .: "pkscript" >>= jsonHex)
            address <- o .: "address"
            return
                Unspent
                    { unspentBlock = block
                    , unspentPoint = OutPoint txid index
                    , unspentAmount = value
                    , unspentScript = script
                    , unspentAddress = address
                    }

-- | Database value for a block entry.
data BlockData = BlockData
    { blockDataHeight    :: !BlockHeight
      -- ^ height of the block in the chain
    , blockDataMainChain :: !Bool
      -- ^ is this block in the main chain?
    , blockDataWork      :: !BlockWork
      -- ^ accumulated work in that block
    , blockDataHeader    :: !BlockHeader
      -- ^ block header
    , blockDataSize      :: !Word32
      -- ^ size of the block including witnesses
    , blockDataWeight    :: !Word32
      -- ^ weight of this block (for segwit networks)
    , blockDataTxs       :: ![TxHash]
      -- ^ block transactions
    , blockDataOutputs   :: !Word64
      -- ^ sum of all transaction outputs
    , blockDataFees      :: !Word64
      -- ^ sum of all transaction fees
    , blockDataSubsidy   :: !Word64
      -- ^ block subsidy
    } deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable, NFData)

instance ToJSON BlockData where
    toJSON bv =
        object
            [ "hash" .= headerHash (blockDataHeader bv)
            , "height" .= blockDataHeight bv
            , "mainchain" .= blockDataMainChain bv
            , "previous" .= prevBlock (blockDataHeader bv)
            , "time" .= blockTimestamp (blockDataHeader bv)
            , "version" .= blockVersion (blockDataHeader bv)
            , "bits" .= blockBits (blockDataHeader bv)
            , "nonce" .= bhNonce (blockDataHeader bv)
            , "size" .= blockDataSize bv
            , "tx" .= blockDataTxs bv
            , "merkle" .= TxHash (merkleRoot (blockDataHeader bv))
            , "subsidy" .= blockDataSubsidy bv
            , "fees" .= blockDataFees bv
            , "outputs" .= blockDataOutputs bv
            , "work" .= String (cs (show (blockDataWork bv)))
            , "weight" .= blockDataWeight bv
            ]

instance FromJSON BlockData where
    parseJSON =
        A.withObject "blockdata" $ \o -> do
            height <- o .: "height"
            mainchain <- o .: "mainchain"
            previous <- o .: "previous"
            time <- o .: "time"
            version <- o .: "version"
            bits <- o .: "bits"
            nonce <- o .: "nonce"
            size <- o .: "size"
            tx <- o .: "tx"
            TxHash merkle <- o .: "merkle"
            subsidy <- o .: "subsidy"
            fees <- o .: "fees"
            outputs <- o .: "outputs"
            work <- o .: "work"
            weight <- o .: "weight"
            return
                BlockData
                    { blockDataHeader =
                          BlockHeader
                              { prevBlock = previous
                              , blockTimestamp = time
                              , blockVersion = version
                              , blockBits = bits
                              , bhNonce = nonce
                              , merkleRoot = merkle
                              }
                    , blockDataMainChain = mainchain
                    , blockDataWork = read work
                    , blockDataSize = size
                    , blockDataWeight = weight
                    , blockDataTxs = tx
                    , blockDataOutputs = outputs
                    , blockDataFees = fees
                    , blockDataHeight = height
                    , blockDataSubsidy = subsidy
                    }

data StoreInput
    = StoreCoinbase { inputPoint     :: !OutPoint
                    , inputSequence  :: !Word32
                    , inputSigScript :: !ByteString
                    , inputWitness   :: !(Maybe WitnessStack)
                     }
    | StoreInput { inputPoint     :: !OutPoint
                 , inputSequence  :: !Word32
                 , inputSigScript :: !ByteString
                 , inputPkScript  :: !ByteString
                 , inputAmount    :: !Word64
                 , inputWitness   :: !(Maybe WitnessStack)
                  }
    deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable, NFData)

isCoinbase :: StoreInput -> Bool
isCoinbase StoreCoinbase {} = True
isCoinbase StoreInput {}    = False

instance ToJSON (NetWrap StoreInput) where
    toJSON (NetWrap net StoreInput { inputPoint = OutPoint oph opi
                                   , inputSequence = sq
                                   , inputSigScript = ss
                                   , inputPkScript = ps
                                   , inputAmount = val
                                   , inputWitness = wit
                                   }) =
        object
            [ "coinbase" .= False
            , "txid" .= oph
            , "output" .= opi
            , "sigscript" .= String (encodeHex ss)
            , "sequence" .= sq
            , "pkscript" .= String (encodeHex ps)
            , "value" .= val
            , "address" .= scriptToStringAddr net ps
            , "witness" .= fmap (map encodeHex) wit
            ]
    toJSON (NetWrap _ StoreCoinbase { inputPoint = OutPoint oph opi
                                    , inputSequence = sq
                                    , inputSigScript = ss
                                    , inputWitness = wit
                                    }) =
        object
            [ "coinbase" .= True
            , "txid" .= oph
            , "output" .= opi
            , "sigscript" .= String (encodeHex ss)
            , "sequence" .= sq
            , "pkscript" .= Null
            , "value" .= Null
            , "address" .= Null
            , "witness" .= fmap (map encodeHex) wit
            ]

instance FromJSON StoreInput where
    parseJSON =
        A.withObject "storeinput" $ \o -> do
            coinbase <- o .: "coinbase"
            outpoint <- OutPoint <$> o .: "txid" <*> o .: "output"
            sequ <- o .: "sequence"
            witness <-
                o .:? "witness" >>= \mmxs ->
                    case join mmxs of
                        Nothing -> return Nothing
                        Just xs -> Just <$> mapM jsonHex xs
            sigscript <- o .: "sigscript" >>= jsonHex
            if coinbase
                then return
                        StoreCoinbase
                            { inputPoint = outpoint
                            , inputSequence = sequ
                            , inputSigScript = sigscript
                            , inputWitness = witness
                            }
                else do
                    pkscript <- o .: "pkscript" >>= jsonHex
                    value <- o .: "value"
                    return
                        StoreInput
                            { inputPoint = outpoint
                            , inputSequence = sequ
                            , inputSigScript = sigscript
                            , inputPkScript = pkscript
                            , inputAmount = value
                            , inputWitness = witness
                            }

jsonHex :: Text -> Parser ByteString
jsonHex s =
    case decodeHex s of
        Nothing -> fail "Could not decode hex"
        Just b  -> return b

-- | Information about input spending output.
data Spender = Spender
    { spenderHash  :: !TxHash
      -- ^ input transaction hash
    , spenderIndex :: !Word32
      -- ^ input position in transaction
    } deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable, NFData)

instance ToJSON Spender where
    toJSON n = object ["txid" .= spenderHash n, "input" .= spenderIndex n]

instance FromJSON Spender where
    parseJSON =
        A.withObject "spender" $ \o -> Spender <$> o .: "txid" <*> o .: "input"

-- | Output information.
data StoreOutput = StoreOutput
    { outputAmount  :: !Word64
    , outputScript  :: !ByteString
    , outputSpender :: !(Maybe Spender)
    } deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable, NFData)

instance ToJSON (NetWrap StoreOutput) where
    toJSON (NetWrap net d) =
        object
            [ "address" .= scriptToStringAddr net (outputScript d)
            , "pkscript" .= String (encodeHex (outputScript d))
            , "value" .= outputAmount d
            , "spent" .= isJust (outputSpender d)
            , "spender" .= outputSpender d
            ]

instance FromJSON StoreOutput where
    parseJSON =
        A.withObject "storeoutput" $ \o -> do
            value <- o .: "value"
            pkscript <- o .: "pkscript" >>= jsonHex
            spender <- o .: "spender"
            return
                StoreOutput
                    { outputAmount = value
                    , outputScript = pkscript
                    , outputSpender = spender
                    }

data Prev = Prev
    { prevScript :: !ByteString
    , prevAmount :: !Word64
    } deriving (Show, Eq, Ord, Generic, Hashable, Serialize, NFData)

toInput :: TxIn -> Maybe Prev -> Maybe WitnessStack -> StoreInput
toInput i Nothing w =
    StoreCoinbase
        { inputPoint = prevOutput i
        , inputSequence = txInSequence i
        , inputSigScript = scriptInput i
        , inputWitness = w
        }
toInput i (Just p) w =
    StoreInput
        { inputPoint = prevOutput i
        , inputSequence = txInSequence i
        , inputSigScript = scriptInput i
        , inputPkScript = prevScript p
        , inputAmount = prevAmount p
        , inputWitness = w
        }

toOutput :: TxOut -> Maybe Spender -> StoreOutput
toOutput o s =
    StoreOutput
        { outputAmount = outValue o
        , outputScript = scriptOutput o
        , outputSpender = s
        }

data TxData = TxData
    { txDataBlock   :: !BlockRef
    , txData        :: !Tx
    , txDataPrevs   :: !(IntMap Prev)
    , txDataDeleted :: !Bool
    , txDataRBF     :: !Bool
    , txDataTime    :: !Word64
    } deriving (Show, Eq, Ord, Generic, Serialize, NFData)

toTransaction :: TxData -> IntMap Spender -> Transaction
toTransaction t sm =
    Transaction
        { transactionBlock = txDataBlock t
        , transactionVersion = txVersion (txData t)
        , transactionLockTime = txLockTime (txData t)
        , transactionInputs = ins
        , transactionOutputs = outs
        , transactionDeleted = txDataDeleted t
        , transactionRBF = txDataRBF t
        , transactionTime = txDataTime t
        }
  where
    ws =
        take (length (txIn (txData t))) $
        map Just (txWitness (txData t)) <> repeat Nothing
    f n i = toInput i (I.lookup n (txDataPrevs t)) (ws !! n)
    ins = zipWith f [0 ..] (txIn (txData t))
    g n o = toOutput o (I.lookup n sm)
    outs = zipWith g [0 ..] (txOut (txData t))

fromTransaction :: Transaction -> (TxData, IntMap Spender)
fromTransaction t = (d, sm)
  where
    d =
        TxData
            { txDataBlock = transactionBlock t
            , txData = transactionData t
            , txDataPrevs = ps
            , txDataDeleted = transactionDeleted t
            , txDataRBF = transactionRBF t
            , txDataTime = transactionTime t
            }
    f _ StoreCoinbase {} = Nothing
    f n StoreInput {inputPkScript = s, inputAmount = v} =
        Just (n, Prev {prevScript = s, prevAmount = v})
    ps = I.fromList . catMaybes $ zipWith f [0 ..] (transactionInputs t)
    g _ StoreOutput {outputSpender = Nothing} = Nothing
    g n StoreOutput {outputSpender = Just s}  = Just (n, s)
    sm = I.fromList . catMaybes $ zipWith g [0 ..] (transactionOutputs t)

-- | Detailed transaction information.
data Transaction = Transaction
    { transactionBlock    :: !BlockRef
      -- ^ block information for this transaction
    , transactionVersion  :: !Word32
      -- ^ transaction version
    , transactionLockTime :: !Word32
      -- ^ lock time
    , transactionInputs   :: ![StoreInput]
      -- ^ transaction inputs
    , transactionOutputs  :: ![StoreOutput]
      -- ^ transaction outputs
    , transactionDeleted  :: !Bool
      -- ^ this transaction has been deleted and is no longer valid
    , transactionRBF      :: !Bool
      -- ^ this transaction can be replaced in the mempool
    , transactionTime     :: !Word64
      -- ^ time the transaction was first seen or time of block
    } deriving (Show, Eq, Ord, Generic, Hashable, Serialize, NFData)

transactionData :: Transaction -> Tx
transactionData t =
    Tx
        { txVersion = transactionVersion t
        , txIn = map i (transactionInputs t)
        , txOut = map o (transactionOutputs t)
        , txWitness = mapMaybe inputWitness (transactionInputs t)
        , txLockTime = transactionLockTime t
        }
  where
    i StoreCoinbase {inputPoint = p, inputSequence = q, inputSigScript = s} =
        TxIn {prevOutput = p, scriptInput = s, txInSequence = q}
    i StoreInput {inputPoint = p, inputSequence = q, inputSigScript = s} =
        TxIn {prevOutput = p, scriptInput = s, txInSequence = q}
    o StoreOutput {outputAmount = v, outputScript = s} =
        TxOut {outValue = v, scriptOutput = s}

instance ToJSON (NetWrap Transaction) where
    toJSON (NetWrap net dtx) =
        object
            [ "txid" .= txHash (transactionData dtx)
            , "size" .= B.length (S.encode (transactionData dtx))
            , "version" .= transactionVersion dtx
            , "locktime" .= transactionLockTime dtx
            , "fee" .=
              if any isCoinbase (transactionInputs dtx)
                  then 0
                  else inv - outv
            , "inputs" .= map (NetWrap net) (transactionInputs dtx)
            , "outputs" .= map (NetWrap net) (transactionOutputs dtx)
            , "block" .= transactionBlock dtx
            , "deleted" .= transactionDeleted dtx
            , "time" .= transactionTime dtx
            , "rbf" .= transactionRBF dtx
            , "weight" .= w
            ]
      where
        inv = sum (map inputAmount (transactionInputs dtx))
        outv = sum (map outputAmount (transactionOutputs dtx))
        w =
            let b = B.length $ S.encode (transactionData dtx) {txWitness = []}
                x = B.length $ S.encode (transactionData dtx)
             in b * 3 + x

instance FromJSON Transaction where
    parseJSON =
        A.withObject "transaction" $ \o -> do
            version <- o .: "version"
            locktime <- o .: "locktime"
            inputs <- o .: "inputs"
            outputs <- o .: "outputs"
            block <- o .: "block"
            deleted <- o .: "deleted"
            time <- o .: "time"
            rbf <- o .:? "rbf" .!= False
            return
                Transaction
                    { transactionBlock = block
                    , transactionVersion = version
                    , transactionLockTime = locktime
                    , transactionInputs = inputs
                    , transactionOutputs = outputs
                    , transactionDeleted = deleted
                    , transactionTime = time
                    , transactionRBF = rbf
                    }

-- | Information about a connected peer.
data PeerInformation
    = PeerInformation { peerUserAgent :: !ByteString
                        -- ^ user agent string
                      , peerAddress   :: !String
                        -- ^ network address
                      , peerVersion   :: !Word32
                        -- ^ version number
                      , peerServices  :: !Word64
                        -- ^ services field
                      , peerRelay     :: !Bool
                        -- ^ will relay transactions
                      }
    deriving (Show, Eq, Ord, Generic, NFData, Serialize)

instance ToJSON PeerInformation where
    toJSON p = object
        [ "useragent"   .= String (cs (peerUserAgent p))
        , "address"     .= peerAddress p
        , "version"     .= peerVersion p
        , "services"    .= String (encodeHex (S.encode (peerServices p)))
        , "relay"       .= peerRelay p
        ]

instance FromJSON PeerInformation where
    parseJSON =
        A.withObject "peerinformation" $ \o -> do
            String useragent <- o .: "useragent"
            address <- o .: "address"
            version <- o .: "version"
            services <-
                o .: "services" >>= jsonHex >>= \b ->
                    case S.decode b of
                        Left e  -> fail $ "Could not decode services: " <> e
                        Right s -> return s
            relay <- o .: "relay"
            return
                PeerInformation
                    { peerUserAgent = cs useragent
                    , peerAddress = address
                    , peerVersion = version
                    , peerServices = services
                    , peerRelay = relay
                    }

-- | Address balances for an extended public key.
data XPubBal = XPubBal
    { xPubBalPath :: ![KeyIndex]
    , xPubBal     :: !Balance
    } deriving (Show, Ord, Eq, Generic, Serialize, NFData)

instance ToJSON (NetWrap XPubBal) where
    toJSON (NetWrap net XPubBal {xPubBalPath = p, xPubBal = b}) =
        object ["path" .= p, "balance" .= toJSON (NetWrap net b)]

-- | Unspent transaction for extended public key.
data XPubUnspent = XPubUnspent
    { xPubUnspentPath :: ![KeyIndex]
    , xPubUnspent     :: !Unspent
    } deriving (Show, Eq, Generic, Serialize, NFData)

instance ToJSON XPubUnspent where
    toJSON XPubUnspent {xPubUnspentPath = p, xPubUnspent = u} =
        object ["path" .= p, "unspent" .= toJSON u]

data XPubSummary =
    XPubSummary
        { xPubSummaryConfirmed :: !Word64
        , xPubSummaryZero      :: !Word64
        , xPubSummaryReceived  :: !Word64
        , xPubUnspentCount     :: !Word64
        , xPubExternalIndex    :: !Word32
        , xPubChangeIndex      :: !Word32
        }
    deriving (Eq, Show, Generic, Serialize, NFData)

instance ToJSON XPubSummary where
    toJSON XPubSummary { xPubSummaryConfirmed = c
                       , xPubSummaryZero = z
                       , xPubSummaryReceived = r
                       , xPubUnspentCount = u
                       , xPubExternalIndex = ext
                       , xPubChangeIndex = ch
                       } =
        object
            [ "balance" .=
              object
                  [ "confirmed" .= c
                  , "unconfirmed" .= z
                  , "received" .= r
                  , "utxo" .= u
                  ]
            , "indices" .= object ["change" .= ch, "external" .= ext]
            ]

instance FromJSON XPubSummary where
    parseJSON =
        A.withObject "xpubsummary" $ \o -> do
            b <- o .: "balance"
            i <- o .: "indices"
            conf <- b .: "confirmed"
            unconfirmed <- b .: "unconfirmed"
            received <- b .: "received"
            utxo <- b .: "utxo"
            change <- i .: "change"
            external <- i .: "external"
            return
                XPubSummary
                    { xPubSummaryConfirmed = conf
                    , xPubSummaryZero = unconfirmed
                    , xPubSummaryReceived = received
                    , xPubUnspentCount = utxo
                    , xPubExternalIndex = external
                    , xPubChangeIndex = change
                    }

data HealthCheck =
    HealthCheck
        { healthHeaderBest   :: !(Maybe BlockHash)
        , healthHeaderHeight :: !(Maybe BlockHeight)
        , healthBlockBest    :: !(Maybe BlockHash)
        , healthBlockHeight  :: !(Maybe BlockHeight)
        , healthPeers        :: !(Maybe Int)
        , healthNetwork      :: !String
        , healthOK           :: !Bool
        , healthSynced       :: !Bool
        , healthLastBlock    :: !(Maybe Word64)
        , healthLastTx       :: !(Maybe Word64)
        }
    deriving (Show, Eq, Generic, Serialize, NFData)

instance ToJSON HealthCheck where
    toJSON h =
        object
            [ "headers" .=
              object
                  [ "hash" .= healthHeaderBest h
                  , "height" .= healthHeaderHeight h
                  ]
            , "blocks" .=
              object
                  ["hash" .= healthBlockBest h, "height" .= healthBlockHeight h]
            , "peers" .= healthPeers h
            , "net" .= healthNetwork h
            , "ok" .= healthOK h
            , "synced" .= healthSynced h
            , "version" .= P.version
            , "lastblock" .= healthLastBlock h
            , "lasttx" .= healthLastTx h
            ]

instance FromJSON HealthCheck where
    parseJSON =
        A.withObject "healthcheck" $ \o -> do
            headers <- o .: "headers"
            headers_hash <- headers .: "hash"
            headers_height <- headers .: "height"
            blocks <- o .: "blocks"
            blocks_hash <- blocks .: "hash"
            blocks_height <- blocks .: "height"
            peers <- o .: "peers"
            net <- o .: "net"
            ok <- o .: "ok"
            synced <- o .: "synced"
            lastblock <- o .: "lastblock"
            lasttx <- o .: "lasttx"
            return
                HealthCheck
                    { healthHeaderBest = headers_hash
                    , healthHeaderHeight = headers_height
                    , healthBlockBest = blocks_hash
                    , healthBlockHeight = blocks_height
                    , healthPeers = peers
                    , healthNetwork = net
                    , healthOK = ok
                    , healthSynced = synced
                    , healthLastBlock = lastblock
                    , healthLastTx = lasttx
                    }

data Event
    = EventBlock BlockHash
    | EventTx TxHash
    deriving (Show, Eq, Generic, Serialize, NFData)

instance ToJSON Event where
    toJSON (EventTx h)    = object ["type" .= String "tx", "id" .= h]
    toJSON (EventBlock h) = object ["type" .= String "block", "id" .= h]

instance FromJSON Event where
    parseJSON =
        A.withObject "event" $ \o -> do
            t <- o .: "type"
            case t of
                "tx" -> do
                    i <- o .: "id"
                    return $ EventTx i
                "block" -> do
                    i <- o .: "id"
                    return $ EventBlock i
                _ -> fail $ "Could not recognize event type: " <> t

newtype TxAfterHeight = TxAfterHeight
    { txAfterHeight :: Maybe Bool
    } deriving (Show, Eq, Generic, Serialize, NFData)

instance ToJSON TxAfterHeight where
    toJSON (TxAfterHeight b) = object ["result" .= b]

instance FromJSON TxAfterHeight where
    parseJSON =
        A.withObject "txafterheight" $ \o -> TxAfterHeight <$> o .: "result"

newtype TxId =
    TxId TxHash
    deriving (Show, Eq, Generic, Serialize, NFData)

instance ToJSON TxId where
    toJSON (TxId h) = object ["txid" .= h]

instance FromJSON TxId where
    parseJSON = A.withObject "txid" $ \o -> TxId <$> o .: "txid"

-- | Events that the store can generate.
data StoreEvent
    = StoreBestBlock !BlockHash
      -- ^ new best block
    | StoreMempoolNew !TxHash
      -- ^ new mempool transaction
    | StorePeerConnected !Peer !SockAddr
      -- ^ new peer connected
    | StorePeerDisconnected !Peer !SockAddr
      -- ^ peer has disconnected
    | StorePeerPong !Peer !Word64
      -- ^ peer responded 'Ping'
    | StoreTxAvailable !Peer ![TxHash]
      -- ^ peer inv transactions
    | StoreTxReject !Peer !TxHash !RejectCode !ByteString
      -- ^ peer rejected transaction
    | StoreTxDeleted !TxHash
      -- ^ transaction deleted from store
    | StoreBlockReverted !BlockHash
      -- ^ block no longer head of main chain

data PubExcept
    = PubNoPeers
    | PubReject RejectCode
    | PubTimeout
    | PubPeerDisconnected
    deriving (Eq, NFData, Generic, Serialize)

instance Show PubExcept where
    show PubNoPeers = "no peers"
    show (PubReject c) =
        "rejected: " <>
        case c of
            RejectMalformed       -> "malformed"
            RejectInvalid         -> "invalid"
            RejectObsolete        -> "obsolete"
            RejectDuplicate       -> "duplicate"
            RejectNonStandard     -> "not standard"
            RejectDust            -> "dust"
            RejectInsufficientFee -> "insufficient fee"
            RejectCheckpoint      -> "checkpoint"
    show PubTimeout = "peer timeout or silent rejection"
    show PubPeerDisconnected = "peer disconnected"

instance Exception PubExcept

applyOffsetLimit :: Offset -> Maybe Limit -> [a] -> [a]
applyOffsetLimit offset limit = applyLimit limit . applyOffset offset

applyOffset :: Offset -> [a] -> [a]
applyOffset = drop . fromIntegral

applyLimit :: Maybe Limit -> [a] -> [a]
applyLimit Nothing  = id
applyLimit (Just l) = take (fromIntegral l)

applyOffsetLimitC :: Monad m => Offset -> Maybe Limit -> ConduitT i i m ()
applyOffsetLimitC offset limit = applyOffsetC offset >> applyLimitC limit

applyOffsetC :: Monad m => Offset -> ConduitT i i m ()
applyOffsetC = dropC . fromIntegral

applyLimitC :: Monad m => Maybe Limit -> ConduitT i i m ()
applyLimitC Nothing  = mapC id
applyLimitC (Just l) = takeC (fromIntegral l)

sortTxs :: [Tx] -> [(Word32, Tx)]
sortTxs txs = go $ zip [0 ..] txs
  where
    go [] = []
    go ts =
        let (is, ds) =
                partition
                    (all ((`notElem` map (txHash . snd) ts) .
                          outPointHash . prevOutput) .
                     txIn . snd)
                    ts
         in is <> go ds

scriptToStringAddr :: Network -> ByteString -> Maybe String
scriptToStringAddr net bs =
    cs <$> (addrToString net =<< eitherToMaybe (scriptToAddressBS bs))
