{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
module Network.Haskoin.Store.Common where

import           Conduit                   (ConduitT, dropC, mapC, takeC)
import           Control.Applicative       ((<|>))
import           Control.DeepSeq           (NFData)
import           Control.Exception         (Exception)
import           Control.Monad             (guard, mzero)
import           Control.Monad.Trans       (lift)
import           Control.Monad.Trans.Maybe (MaybeT (..), runMaybeT)
import           Data.Aeson                (Encoding, ToJSON (..), Value (..),
                                            object, pairs, (.=))
import qualified Data.Aeson                as A
import qualified Data.Aeson.Encoding       as A
import           Data.ByteString           (ByteString)
import qualified Data.ByteString           as B
import           Data.ByteString.Short     (ShortByteString)
import qualified Data.ByteString.Short     as B.Short
import           Data.Default              (Default (..))
import           Data.Function             (on)
import           Data.Hashable             (Hashable)
import qualified Data.IntMap               as I
import           Data.IntMap.Strict        (IntMap)
import           Data.List                 (nub, partition, sortBy)
import           Data.Maybe                (catMaybes, isJust, listToMaybe,
                                            mapMaybe)
import           Data.Serialize            (Get, Put, Putter, Serialize (..),
                                            getListOf, getShortByteString,
                                            getWord32be, getWord64be, getWord8,
                                            putListOf, putShortByteString,
                                            putWord32be, putWord64be, putWord8)
import qualified Data.Serialize            as S
import           Data.String.Conversions   (cs)
import qualified Data.Text.Encoding        as T
import           Data.Word                 (Word32, Word64)
import           Database.RocksDB          (DB, ReadOptions)
import           GHC.Generics              (Generic)
import           Haskoin                   (Address, Block, BlockHash,
                                            BlockHeader (..), BlockHeight,
                                            BlockNode, BlockWork, HostAddress,
                                            KeyIndex, Network (..),
                                            NetworkAddress (..), OutPoint (..),
                                            PubKeyI (..), RejectCode (..),
                                            Tx (..), TxHash (..), TxIn (..),
                                            TxOut (..), WitnessStack,
                                            XPubKey (..), addrToJSON,
                                            addrToString, deriveAddr,
                                            deriveCompatWitnessAddr,
                                            deriveWitnessAddr, eitherToMaybe,
                                            encodeHex, headerHash,
                                            hostToSockAddr, pubSubKey,
                                            scriptToAddressBS, stringToAddr,
                                            txHash, wrapPubKey, xPubAddr,
                                            xPubCompatWitnessAddr,
                                            xPubWitnessAddr)
import           Haskoin.Node              (Chain, HostPort, Manager, Peer)
import           Network.Socket            (SockAddr)
import           NQE                       (Listen, Mailbox)
import qualified Paths_haskoin_store       as P

data DeriveType
    = DeriveNormal
    | DeriveP2SH
    | DeriveP2WPKH
    deriving (Show, Eq, Generic, NFData, Serialize)

data XPubSpec =
    XPubSpec
        { xPubSpecKey    :: !XPubKey
        , xPubDeriveType :: !DeriveType
        } deriving (Show, Eq, Generic, NFData)

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

-- | Mailbox for block store.
type BlockStore = Mailbox BlockMessage

-- | Store mailboxes.
data Store =
    Store
        { storeManager :: !Manager
      -- ^ peer manager mailbox
        , storeChain   :: !Chain
      -- ^ chain header process mailbox
        , storeBlock   :: !BlockStore
      -- ^ block storage mailbox
        }

-- | Configuration for a 'Store'.
data StoreConfig =
    StoreConfig
        { storeConfMaxPeers  :: !Int
      -- ^ max peers to connect to
        , storeConfInitPeers :: ![HostPort]
      -- ^ static set of peers to connect to
        , storeConfDiscover  :: !Bool
      -- ^ discover new peers?
        , storeConfDB        :: !BlockDB
      -- ^ RocksDB database handler
        , storeConfNetwork   :: !Network
      -- ^ network constants
        , storeConfListen    :: !(Listen StoreEvent)
      -- ^ listen to store events
        }

-- | Configuration for a block store.
data BlockConfig =
    BlockConfig
        { blockConfManager  :: !Manager
      -- ^ peer manager from running node
        , blockConfChain    :: !Chain
      -- ^ chain from a running node
        , blockConfListener :: !(Listen StoreEvent)
      -- ^ listener for store events
        , blockConfDB       :: !BlockDB
      -- ^ RocksDB database handle
        , blockConfNet      :: !Network
      -- ^ network constants
        }

data BlockDB =
    BlockDB
        { blockDB     :: !DB
        , blockDBopts :: !ReadOptions
        }

type UnixTime = Word64
type BlockPos = Word32

type Offset = Word32
type Limit = Word32

class Monad m =>
      StoreRead m
    where
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
        ext <-
            derive_until_gap
                0
                (deriveAddresses
                     (deriveFunction (xPubDeriveType xpub))
                     (pubSubKey (xPubSpecKey xpub) 0)
                     0)
        chg <-
            derive_until_gap
                1
                (deriveAddresses
                     (deriveFunction (xPubDeriveType xpub))
                     (pubSubKey (xPubSpecKey xpub) 1)
                     0)
        return (ext ++ chg)
      where
        xbalance m b n = XPubBal {xPubBalPath = [m, n], xPubBal = b}
        derive_until_gap _ [] = return []
        derive_until_gap m as = do
            let n = 32
            let (as1, as2) = splitAt n as
            bs <- getBalances (map snd as1)
            let xbs = zipWith (xbalance m) bs (map fst as1)
            if all nullBalance bs
                then return xbs
                else (xbs <>) <$> derive_until_gap m as2
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

xPubAddrFunction :: DeriveType -> XPubKey -> Address
xPubAddrFunction DeriveNormal = xPubAddr
xPubAddrFunction DeriveP2SH   = xPubCompatWitnessAddr
xPubAddrFunction DeriveP2WPKH = xPubWitnessAddr

encodeShort :: Serialize a => a -> ShortByteString
encodeShort = B.Short.toShort . S.encode

decodeShort :: Serialize a => ShortByteString -> a
decodeShort bs = case S.decode (B.Short.fromShort bs) of
    Left e  -> error e
    Right a -> a

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

class JsonSerial a where
    jsonSerial :: Network -> a -> Encoding
    jsonValue :: Network -> a -> Value

instance JsonSerial a => JsonSerial [a] where
    jsonSerial net = A.list (jsonSerial net)
    jsonValue net = toJSON . (jsonValue net)

instance JsonSerial TxHash where
    jsonSerial _ = toEncoding
    jsonValue _ = toJSON

instance BinSerial TxHash where
    binSerial _ = put
    binDeserial _  = get

instance BinSerial Address where
    binSerial net a =
        case addrToString net a of
            Nothing -> put B.empty
            Just x  -> put $ T.encodeUtf8 x

    binDeserial net = do
          bs <- get
          guard (not (B.null bs))
          t <- case T.decodeUtf8' bs of
            Left _  -> mzero
            Right v -> return v
          case stringToAddr net t of
            Nothing -> mzero
            Just x  -> return x

class BinSerial a where
    binSerial :: Network -> Putter a
    binDeserial :: Network -> Get a

instance BinSerial a => BinSerial [a] where
    binSerial net = putListOf (binSerial net)
    binDeserial net = getListOf (binDeserial net)

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

instance BinSerial BlockRef where
    binSerial _ BlockRef {blockRefHeight = h, blockRefPos = p} = do
        putWord8 0x00
        putWord32be h
        putWord32be p
    binSerial _ MemRef {memRefTime = t} = do
        putWord8 0x01
        putWord64be t

    binDeserial _ = getWord8 >>=
        \case
            0x00 -> BlockRef <$> getWord32be <*> getWord32be
            0x01 -> MemRef <$> getUnixTime
            _ -> fail "Expected fst byte to be 0x00 or 0x01"

-- | JSON serialization for 'BlockRef'.
blockRefPairs :: A.KeyValue kv => BlockRef -> [kv]
blockRefPairs BlockRef {blockRefHeight = h, blockRefPos = p} =
    ["height" .= h, "position" .= p]
blockRefPairs MemRef {memRefTime = t} = ["mempool" .= t]

confirmed :: BlockRef -> Bool
confirmed BlockRef {} = True
confirmed MemRef {}   = False

instance ToJSON BlockRef where
    toJSON = object . blockRefPairs
    toEncoding = pairs . mconcat . blockRefPairs

-- | Transaction in relation to an address.
data BlockTx = BlockTx
    { blockTxBlock :: !BlockRef
      -- ^ block information
    , blockTxHash  :: !TxHash
      -- ^ transaction hash
    } deriving (Show, Eq, Ord, Generic, Serialize, Hashable, NFData)

-- | JSON serialization for 'AddressTx'.
blockTxPairs :: A.KeyValue kv => BlockTx -> [kv]
blockTxPairs btx =
    [ "txid" .= blockTxHash btx
    , "block" .= blockTxBlock btx
    ]

instance ToJSON BlockTx where
    toJSON = object . blockTxPairs
    toEncoding = pairs . mconcat . blockTxPairs

instance JsonSerial BlockTx where
    jsonSerial _ = toEncoding
    jsonValue _ = toJSON

instance BinSerial BlockTx where
    binSerial net BlockTx { blockTxBlock = b, blockTxHash = h } = do
        binSerial net b
        binSerial net h

    binDeserial net = BlockTx <$> binDeserial net <*> binDeserial net

-- | Address balance information.
data Balance = Balance
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
    } deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable, NFData)

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

-- | JSON serialization for 'Balance'.
balancePairs :: A.KeyValue kv => Network -> Balance -> [kv]
balancePairs net ab =
    [ "address" .= addrToJSON net (balanceAddress ab)
    , "confirmed" .= balanceAmount ab
    , "unconfirmed" .= balanceZero ab
    , "utxo" .= balanceUnspentCount ab
    , "txs" .= balanceTxCount ab
    , "received" .= balanceTotalReceived ab
    ]

balanceToJSON :: Network -> Balance -> Value
balanceToJSON net = object . balancePairs net

balanceToEncoding :: Network -> Balance -> Encoding
balanceToEncoding net = pairs . mconcat . balancePairs net

instance JsonSerial Balance where
    jsonSerial = balanceToEncoding
    jsonValue = balanceToJSON

instance BinSerial Balance where
    binSerial net Balance { balanceAddress = a
                          , balanceAmount = v
                          , balanceZero = z
                          , balanceUnspentCount = u
                          , balanceTxCount = c
                          , balanceTotalReceived = t
                          } = do
        binSerial net a
        putWord64be v
        putWord64be z
        putWord64be u
        putWord64be c
        putWord64be t

    binDeserial net =
      Balance <$> binDeserial net
        <*> getWord64be
        <*> getWord64be
        <*> getWord64be
        <*> getWord64be
        <*> getWord64be


-- | Unspent output.
data Unspent = Unspent
    { unspentBlock  :: !BlockRef
      -- ^ block information for output
    , unspentPoint  :: !OutPoint
      -- ^ txid and index where output located
    , unspentAmount :: !Word64
      -- ^ value of output in satoshi
    , unspentScript :: !ShortByteString
      -- ^ pubkey (output) script
    } deriving (Show, Eq, Ord, Generic, Hashable, NFData)

instance Serialize Unspent where
    put u = do
        put $ unspentBlock u
        put $ unspentPoint u
        put $ unspentAmount u
        put $ B.Short.length (unspentScript u)
        putShortByteString $ unspentScript u
    get =
        Unspent <$> get <*> get <*> get <*> (getShortByteString =<< get)

unspentPairs :: A.KeyValue kv => Network -> Unspent -> [kv]
unspentPairs net u =
    [ "address" .=
      eitherToMaybe
          (addrToJSON net <$>
           scriptToAddressBS (B.Short.fromShort (unspentScript u)))
    , "block" .= unspentBlock u
    , "txid" .= outPointHash (unspentPoint u)
    , "index" .= outPointIndex (unspentPoint u)
    , "pkscript" .= String (encodeHex (B.Short.fromShort (unspentScript u)))
    , "value" .= unspentAmount u
    ]

unspentToJSON :: Network -> Unspent -> Value
unspentToJSON net = object . unspentPairs net

unspentToEncoding :: Network -> Unspent -> Encoding
unspentToEncoding net = pairs . mconcat . unspentPairs net

instance JsonSerial Unspent where
    jsonSerial = unspentToEncoding
    jsonValue = unspentToJSON

instance BinSerial Unspent where
    binSerial net Unspent { unspentBlock = b
                          , unspentPoint = p
                          , unspentAmount = v
                          , unspentScript = s
                          } = do
        binSerial net b
        put p
        putWord64be v
        put s

    binDeserial net =
      Unspent
      <$> binDeserial net
      <*> get
      <*> getWord64be
      <*> get

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

-- | JSON serialization for 'BlockData'.
blockDataPairs :: A.KeyValue kv => Network -> BlockData -> [kv]
blockDataPairs net bv =
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
    ] ++ ["weight" .= blockDataWeight bv | getSegWit net]

blockDataToJSON :: Network -> BlockData -> Value
blockDataToJSON net = object . blockDataPairs net

blockDataToEncoding :: Network -> BlockData -> Encoding
blockDataToEncoding net = pairs . mconcat . blockDataPairs net

instance JsonSerial BlockData where
    jsonSerial = blockDataToEncoding
    jsonValue = blockDataToJSON

instance BinSerial BlockData where
    binSerial _ BlockData { blockDataHeight = e
                          , blockDataMainChain = m
                          , blockDataWork = w
                          , blockDataHeader = h
                          , blockDataSize = z
                          , blockDataWeight = g
                          , blockDataTxs = t
                          , blockDataOutputs = o
                          , blockDataFees = f
                          , blockDataSubsidy = y
                          } = do
        put m
        putWord32be e
        put h
        put w
        putWord32be z
        putWord32be g
        putWord64be o
        putWord64be f
        putWord64be y
        put t

    binDeserial _ = do
      m <- get
      e <- getWord32be
      h <- get
      w <- get
      z <- getWord32be
      g <- getWord32be
      o <- getWord64be
      f <- getWord64be
      y <- getWord64be
      t <- get
      return $ BlockData e m w h z g t o f y

-- | Input information.
data StoreInput
    = StoreCoinbase { inputPoint     :: !OutPoint
                 -- ^ output being spent (should be null)
                    , inputSequence  :: !Word32
                 -- ^ sequence
                    , inputSigScript :: !ByteString
                 -- ^ input script data (not valid script)
                    , inputWitness   :: !(Maybe WitnessStack)
                 -- ^ witness data for this input (only segwit)
                     }
    -- ^ coinbase details
    | StoreInput { inputPoint     :: !OutPoint
              -- ^ output being spent
                 , inputSequence  :: !Word32
              -- ^ sequence
                 , inputSigScript :: !ByteString
              -- ^ signature (input) script
                 , inputPkScript  :: !ByteString
              -- ^ pubkey (output) script from previous tx
                 , inputAmount    :: !Word64
              -- ^ amount in satoshi being spent spent
                 , inputWitness   :: !(Maybe WitnessStack)
              -- ^ witness data for this input (only segwit)
                  }
    -- ^ input details
    deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable, NFData)

isCoinbase :: StoreInput -> Bool
isCoinbase StoreCoinbase {} = True
isCoinbase StoreInput {}    = False

inputPairs :: A.KeyValue kv => Network -> StoreInput -> [kv]
inputPairs net StoreInput { inputPoint = OutPoint oph opi
                          , inputSequence = sq
                          , inputSigScript = ss
                          , inputPkScript = ps
                          , inputAmount = val
                          , inputWitness = wit
                          } =
    [ "coinbase" .= False
    , "txid" .= oph
    , "output" .= opi
    , "sigscript" .= String (encodeHex ss)
    , "sequence" .= sq
    , "pkscript" .= String (encodeHex ps)
    , "value" .= val
    , "address" .= eitherToMaybe (addrToJSON net <$> scriptToAddressBS ps)
    ] ++
    ["witness" .= fmap (map encodeHex) wit | getSegWit net]

inputPairs net StoreCoinbase { inputPoint = OutPoint oph opi
                             , inputSequence = sq
                             , inputSigScript = ss
                             , inputWitness = wit
                             } =
    [ "coinbase" .= True
    , "txid" .= oph
    , "output" .= opi
    , "sigscript" .= String (encodeHex ss)
    , "sequence" .= sq
    , "pkscript" .= Null
    , "value" .= Null
    , "address" .= Null
    ] ++
    ["witness" .= fmap (map encodeHex) wit | getSegWit net]

inputToJSON :: Network -> StoreInput -> Value
inputToJSON net = object . inputPairs net

inputToEncoding :: Network -> StoreInput -> Encoding
inputToEncoding net = pairs . mconcat . inputPairs net

-- | Information about input spending output.
data Spender = Spender
    { spenderHash  :: !TxHash
      -- ^ input transaction hash
    , spenderIndex :: !Word32
      -- ^ input position in transaction
    } deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable, NFData)

-- | JSON serialization for 'Spender'.
spenderPairs :: A.KeyValue kv => Spender -> [kv]
spenderPairs n =
    ["txid" .= spenderHash n, "input" .= spenderIndex n]

instance ToJSON Spender where
    toJSON = object . spenderPairs
    toEncoding = pairs . mconcat . spenderPairs

-- | Output information.
data StoreOutput = StoreOutput
    { outputAmount  :: !Word64
      -- ^ amount in satoshi
    , outputScript  :: !ByteString
      -- ^ pubkey (output) script
    , outputSpender :: !(Maybe Spender)
      -- ^ input spending this transaction
    } deriving (Show, Read, Eq, Ord, Generic, Serialize, Hashable, NFData)

outputPairs :: A.KeyValue kv => Network -> StoreOutput -> [kv]
outputPairs net d =
    [ "address" .=
      eitherToMaybe (addrToJSON net <$> scriptToAddressBS (outputScript d))
    , "pkscript" .= String (encodeHex (outputScript d))
    , "value" .= outputAmount d
    , "spent" .= isJust (outputSpender d)
    ] ++
    ["spender" .= outputSpender d | isJust (outputSpender d)]

outputToJSON :: Network -> StoreOutput -> Value
outputToJSON net = object . outputPairs net

outputToEncoding :: Network -> StoreOutput -> Encoding
outputToEncoding net = pairs . mconcat . outputPairs net

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

instance BinSerial TxData where
  binSerial _ TxData
        { txDataBlock   = br
        , txData        = tx
        , txDataPrevs   = dp
        , txDataDeleted = dd
        , txDataRBF     = dr
        , txDataTime    = t
        } = do
      put br
      put tx
      put dp
      put dd
      put dr
      putWord64be t

  binDeserial _ = do br <- get
                     tx <- get
                     dp <- get
                     dd <- get
                     dr <- get
                     TxData br tx dp dd dr <$> getWord64be

instance Serialize a => BinSerial (IntMap a) where
  binSerial _ = put
  binDeserial _ = get

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

-- | JSON serialization for 'Transaction'.
transactionPairs :: A.KeyValue kv => Network -> Transaction -> [kv]
transactionPairs net dtx =
    [ "txid" .= txHash (transactionData dtx)
    , "size" .= B.length (S.encode (transactionData dtx))
    , "version" .= transactionVersion dtx
    , "locktime" .= transactionLockTime dtx
    , "fee" .=
      if all isCoinbase (transactionInputs dtx)
          then 0
          else sum (map inputAmount (transactionInputs dtx)) -
               sum (map outputAmount (transactionOutputs dtx))
    , "inputs" .= map (object . inputPairs net) (transactionInputs dtx)
    , "outputs" .= map (object . outputPairs net) (transactionOutputs dtx)
    , "block" .= transactionBlock dtx
    , "deleted" .= transactionDeleted dtx
    , "time" .= transactionTime dtx
    ] ++
    ["rbf" .= transactionRBF dtx | getReplaceByFee net] ++
    ["weight" .= w | getSegWit net]
  where
    w = let b = B.length $ S.encode (transactionData dtx) {txWitness = []}
            x = B.length $ S.encode (transactionData dtx)
        in b * 3 + x

transactionToJSON :: Network -> Transaction -> Value
transactionToJSON net = object . transactionPairs net

transactionToEncoding :: Network -> Transaction -> Encoding
transactionToEncoding net = pairs . mconcat . transactionPairs net

instance JsonSerial Transaction where
    jsonSerial = transactionToEncoding
    jsonValue = transactionToJSON

instance BinSerial Transaction where
    binSerial net tx = do
        let (txd, sp) = fromTransaction tx
        binSerial net txd
        binSerial net sp

    binDeserial net = do
      txd <- binDeserial net
      sp <- binDeserial net
      return $ toTransaction txd sp

instance JsonSerial Tx where
    jsonSerial _ = toEncoding
    jsonValue _ = toJSON

instance BinSerial Tx where
    binSerial _ = put
    binDeserial _ = get

instance JsonSerial Block where
    jsonSerial _ = toEncoding
    jsonValue _ = toJSON

instance BinSerial Block where
    binSerial _ = put
    binDeserial _ = get

-- | Information about a connected peer.
data PeerInformation
    = PeerInformation { peerUserAgent :: !ByteString
                        -- ^ user agent string
                      , peerAddress   :: !HostAddress
                        -- ^ network address
                      , peerVersion   :: !Word32
                        -- ^ version number
                      , peerServices  :: !Word64
                        -- ^ services field
                      , peerRelay     :: !Bool
                        -- ^ will relay transactions
                      }
    deriving (Show, Eq, Ord, Generic, NFData)

-- | JSON serialization for 'PeerInformation'.
peerInformationPairs :: A.KeyValue kv => PeerInformation -> [kv]
peerInformationPairs p =
    [ "useragent"   .= String (cs (peerUserAgent p))
    , "address"     .= String (cs (show (hostToSockAddr (peerAddress p))))
    , "version"     .= peerVersion p
    , "services"    .= String (encodeHex (S.encode (peerServices p)))
    , "relay"       .= peerRelay p
    ]

instance ToJSON PeerInformation where
    toJSON = object . peerInformationPairs
    toEncoding = pairs . mconcat . peerInformationPairs

instance JsonSerial PeerInformation where
    jsonSerial _ = toEncoding
    jsonValue _ = toJSON

instance BinSerial PeerInformation where
    binSerial _ PeerInformation { peerUserAgent = u
                                , peerAddress = a
                                , peerVersion = v
                                , peerServices = s
                                , peerRelay = b
                                } = do
        putWord32be v
        put b
        put u
        put $ NetworkAddress s a

    binDeserial _ = do
      v <- getWord32be
      b <- get
      u <- get
      NetworkAddress { naServices = s, naAddress = a } <- get
      return $ PeerInformation u a v s b

-- | Address balances for an extended public key.
data XPubBal = XPubBal
    { xPubBalPath :: ![KeyIndex]
    , xPubBal     :: !Balance
    } deriving (Show, Eq, Generic, NFData)

-- | JSON serialization for 'XPubBal'.
xPubBalPairs :: A.KeyValue kv => Network -> XPubBal -> [kv]
xPubBalPairs net XPubBal {xPubBalPath = p, xPubBal = b} =
    [ "path" .= p
    , "balance" .= balanceToJSON net b
    ]

xPubBalToJSON :: Network -> XPubBal -> Value
xPubBalToJSON net = object . xPubBalPairs net

xPubBalToEncoding :: Network -> XPubBal -> Encoding
xPubBalToEncoding net = pairs . mconcat . xPubBalPairs net

instance JsonSerial XPubBal where
    jsonSerial = xPubBalToEncoding
    jsonValue = xPubBalToJSON

instance BinSerial XPubBal where
    binSerial net XPubBal {xPubBalPath = p, xPubBal = b} = do
        put p
        binSerial net b
    binDeserial net  = do
      p <- get
      b <- binDeserial net
      return $ XPubBal p b

-- | Unspent transaction for extended public key.
data XPubUnspent = XPubUnspent
    { xPubUnspentPath :: ![KeyIndex]
    , xPubUnspent     :: !Unspent
    } deriving (Show, Eq, Generic, Serialize, NFData)

-- | JSON serialization for 'XPubUnspent'.
xPubUnspentPairs :: A.KeyValue kv => Network -> XPubUnspent -> [kv]
xPubUnspentPairs net XPubUnspent { xPubUnspentPath = p
                                 , xPubUnspent = u
                                 } =
    [ "path" .= p
    , "unspent" .= unspentToJSON net u
    ]

xPubUnspentToJSON :: Network -> XPubUnspent -> Value
xPubUnspentToJSON net = object . xPubUnspentPairs net

xPubUnspentToEncoding :: Network -> XPubUnspent -> Encoding
xPubUnspentToEncoding net = pairs . mconcat . xPubUnspentPairs net

instance JsonSerial XPubUnspent where
    jsonSerial = xPubUnspentToEncoding
    jsonValue = xPubUnspentToJSON

instance BinSerial XPubUnspent where
    binSerial net XPubUnspent {xPubUnspentPath = p, xPubUnspent = u} = do
        put p
        binSerial net u

    binDeserial net = do
      p <- get
      u <- binDeserial net
      return $ XPubUnspent p u

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

xPubSummaryPairs :: A.KeyValue kv => XPubSummary -> [kv]
xPubSummaryPairs XPubSummary { xPubSummaryConfirmed = c
                               , xPubSummaryZero = z
                               , xPubSummaryReceived = r
                               , xPubUnspentCount = u
                               , xPubExternalIndex = ext
                               , xPubChangeIndex = ch
                               } =
    [ "balance" .=
      object
          ["confirmed" .= c, "unconfirmed" .= z, "received" .= r, "utxo" .= u]
    , "indices" .= object ["change" .= ch, "external" .= ext]
    ]

xPubSummaryToJSON :: XPubSummary -> Value
xPubSummaryToJSON = object . xPubSummaryPairs

xPubSummaryToEncoding :: XPubSummary -> Encoding
xPubSummaryToEncoding = pairs . mconcat . xPubSummaryPairs

instance ToJSON XPubSummary where
    toJSON = xPubSummaryToJSON
    toEncoding = xPubSummaryToEncoding

instance JsonSerial XPubSummary where
    jsonSerial _ = xPubSummaryToEncoding
    jsonValue _ = xPubSummaryToJSON

instance BinSerial XPubSummary where
    binSerial _ = put
    binDeserial _ = get

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

healthCheckPairs :: A.KeyValue kv => HealthCheck -> [kv]
healthCheckPairs h =
    [ "headers" .=
      object ["hash" .= healthHeaderBest h, "height" .= healthHeaderHeight h]
    , "blocks" .=
      object ["hash" .= healthBlockBest h, "height" .= healthBlockHeight h]
    , "peers" .= healthPeers h
    , "net" .= healthNetwork h
    , "ok" .= healthOK h
    , "synced" .= healthSynced h
    , "version" .= P.version
    , "lastblock" .= healthLastBlock h
    , "lasttx" .= healthLastTx h
    ]

instance ToJSON HealthCheck where
    toJSON = object . healthCheckPairs
    toEncoding = pairs . mconcat . healthCheckPairs

instance JsonSerial HealthCheck where
    jsonSerial _ = toEncoding
    jsonValue _ = toJSON

instance BinSerial HealthCheck where
    binSerial _ HealthCheck { healthHeaderBest = hbest
                            , healthHeaderHeight = hheight
                            , healthBlockBest = bbest
                            , healthBlockHeight = bheight
                            , healthPeers = peers
                            , healthNetwork = net
                            , healthOK = ok
                            , healthSynced = synced
                            , healthLastBlock = lbk
                            , healthLastTx = ltx
                            } = do
        put hbest
        put hheight
        put bbest
        put bheight
        put peers
        put net
        put ok
        put synced
        put lbk
        put ltx
    binDeserial _ =
        HealthCheck <$> get <*> get <*> get <*> get <*> get <*> get <*> get <*>
        get <*>
        get <*>
        get

data Event
    = EventBlock BlockHash
    | EventTx TxHash
    deriving (Show, Eq, Generic)

instance ToJSON Event where
    toJSON (EventTx h)    = object ["type" .= String "tx", "id" .= h]
    toJSON (EventBlock h) = object ["type" .= String "block", "id" .= h]

instance JsonSerial Event where
    jsonSerial _ = toEncoding
    jsonValue _ = toJSON

instance BinSerial Event where
    binSerial _ (EventBlock bh) = putWord8 0x00 >> put bh
    binSerial _ (EventTx th)    = putWord8 0x01 >> put th

    binDeserial _ = getWord8 >>=
            \case
                0x00-> EventBlock <$> get
                0x01 -> EventTx <$> get
                _ -> fail "Expected fst byte to be 0x00 or 0x01"


newtype TxAfterHeight = TxAfterHeight
    { txAfterHeight :: Maybe Bool
    } deriving (Show, Eq, Generic, NFData)

instance ToJSON TxAfterHeight where
    toJSON (TxAfterHeight b) = object ["result" .= b]

instance JsonSerial TxAfterHeight where
    jsonSerial _ = toEncoding
    jsonValue _ = toJSON

instance BinSerial TxAfterHeight where
    binSerial _ TxAfterHeight {txAfterHeight = a} = put a
    binDeserial _ = TxAfterHeight <$> get

newtype TxId = TxId TxHash deriving (Show, Eq, Generic, NFData)

instance ToJSON TxId where
    toJSON (TxId h) = object ["txid" .= h]

instance JsonSerial TxId where
    jsonSerial _ = toEncoding
    jsonValue _ = toJSON

instance BinSerial TxId where
    binSerial _ (TxId th) = put th
    binDeserial _ = TxId <$> get

data BalVal = BalVal
    { balValAmount        :: !Word64
    , balValZero          :: !Word64
    , balValUnspentCount  :: !Word64
    , balValTxCount       :: !Word64
    , balValTotalReceived :: !Word64
    } deriving (Show, Read, Eq, Ord, Generic, Hashable, Serialize, NFData)

valToBalance :: Address -> BalVal -> Balance
valToBalance a BalVal { balValAmount = v
                      , balValZero = z
                      , balValUnspentCount = u
                      , balValTxCount = t
                      , balValTotalReceived = r
                      } =
    Balance
        { balanceAddress = a
        , balanceAmount = v
        , balanceZero = z
        , balanceUnspentCount = u
        , balanceTxCount = t
        , balanceTotalReceived = r
        }

balanceToVal :: Balance -> (Address, BalVal)
balanceToVal Balance { balanceAddress = a
                     , balanceAmount = v
                     , balanceZero = z
                     , balanceUnspentCount = u
                     , balanceTxCount = t
                     , balanceTotalReceived = r
                     } =
    ( a
    , BalVal
          { balValAmount = v
          , balValZero = z
          , balValUnspentCount = u
          , balValTxCount = t
          , balValTotalReceived = r
          })

-- | Default balance for an address.
instance Default BalVal where
    def =
        BalVal
            { balValAmount = 0
            , balValZero = 0
            , balValUnspentCount = 0
            , balValTxCount = 0
            , balValTotalReceived = 0
            }

data UnspentVal = UnspentVal
    { unspentValBlock  :: !BlockRef
    , unspentValAmount :: !Word64
    , unspentValScript :: !ShortByteString
    } deriving (Show, Read, Eq, Ord, Generic, Hashable, Serialize, NFData)

unspentToVal :: Unspent -> (OutPoint, UnspentVal)
unspentToVal Unspent { unspentBlock = b
                     , unspentPoint = p
                     , unspentAmount = v
                     , unspentScript = s
                     } =
    ( p
    , UnspentVal
          {unspentValBlock = b, unspentValAmount = v, unspentValScript = s})

valToUnspent :: OutPoint -> UnspentVal -> Unspent
valToUnspent p UnspentVal { unspentValBlock = b
                          , unspentValAmount = v
                          , unspentValScript = s
                          } =
    Unspent
        { unspentBlock = b
        , unspentPoint = p
        , unspentAmount = v
        , unspentScript = s
        }

-- | Messages that a 'BlockStore' can accept.
data BlockMessage
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
    deriving Eq

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
