{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
module Haskoin.Store.Database.Types
    ( AddrTxKey(..)
    , AddrOutKey(..)
    , BestKey(..)
    , BlockKey(..)
    , BalKey(..)
    , HeightKey(..)
    , MemKey(..)
    , SpenderKey(..)
    , TxKey(..)
    , decodeTxKey
    , UnspentKey(..)
    , VersionKey(..)
    , BalVal(..)
    , valToBalance
    , balanceToVal
    , UnspentVal(..)
    , toUnspent
    , unspentToVal
    , valToUnspent
    , OutVal(..)
    ) where

import           Control.DeepSeq        (NFData)
import           Control.Monad          (guard)
import           Data.Bits              (Bits, shift, shiftL, shiftR, (.&.),
                                         (.|.))
import           Data.ByteString        (ByteString)
import qualified Data.ByteString        as BS
import           Data.ByteString.Short  (ShortByteString)
import qualified Data.ByteString.Short  as BSS
import           Data.Default           (Default (..))
import           Data.Either            (fromRight)
import           Data.Hashable          (Hashable)
import           Data.Serialize         (Serialize (..), decode, encode,
                                         getBytes, getWord16be, getWord32be,
                                         getWord8, putWord32be, putWord64be,
                                         putWord8, runGet, runPut)
import           Data.Word              (Word16, Word32, Word64, Word8)
import           Database.RocksDB.Query (Key, KeyValue)
import           GHC.Generics           (Generic)
import           Haskoin                (Address, BlockHash, BlockHeight,
                                         OutPoint (..), TxHash, eitherToMaybe,
                                         scriptToAddressBS)
import           Haskoin.Store.Data     (Balance (..), BlockData, BlockRef,
                                         Spender, TxData, TxRef (..), UnixTime,
                                         Unspent (..))

-- | Database key for an address transaction.
data AddrTxKey
    = AddrTxKey { addrTxKeyA :: !Address
                , addrTxKeyT :: !TxRef
                }
      -- ^ key for a transaction affecting an address
    | AddrTxKeyA { addrTxKeyA :: !Address }
      -- ^ short key that matches all entries
    | AddrTxKeyB { addrTxKeyA :: !Address
                 , addrTxKeyB :: !BlockRef
                 }
    | AddrTxKeyS
    deriving (Show, Eq, Ord, Generic, Hashable)

instance Serialize AddrTxKey
    -- 0x05 · Address · BlockRef · TxHash
                                          where
    put AddrTxKey { addrTxKeyA = a
                  , addrTxKeyT = TxRef {txRefBlock = b, txRefHash = t}
                  } = do
        put AddrTxKeyB {addrTxKeyA = a, addrTxKeyB = b}
        put t
    -- 0x05 · Address
    put AddrTxKeyA {addrTxKeyA = a} = do
        put AddrTxKeyS
        put a
    -- 0x05 · Address · BlockRef
    put AddrTxKeyB {addrTxKeyA = a, addrTxKeyB = b} = do
        put AddrTxKeyA {addrTxKeyA = a}
        put b
    -- 0x05
    put AddrTxKeyS = putWord8 0x05
    get = do
        guard . (== 0x05) =<< getWord8
        a <- get
        b <- get
        t <- get
        return
            AddrTxKey
                { addrTxKeyA = a
                , addrTxKeyT = TxRef {txRefBlock = b, txRefHash = t}
                }

instance Key AddrTxKey
instance KeyValue AddrTxKey ()

-- | Database key for an address output.
data AddrOutKey
    = AddrOutKey { addrOutKeyA :: !Address
                 , addrOutKeyB :: !BlockRef
                 , addrOutKeyP :: !OutPoint }
      -- ^ full key
    | AddrOutKeyA { addrOutKeyA :: !Address }
      -- ^ short key for all spent or unspent outputs
    | AddrOutKeyB { addrOutKeyA :: !Address
                  , addrOutKeyB :: !BlockRef
                  }
    | AddrOutKeyS
    deriving (Show, Read, Eq, Ord, Generic, Hashable)

instance Serialize AddrOutKey
    -- 0x06 · StoreAddr · BlockRef · OutPoint
                                              where
    put AddrOutKey {addrOutKeyA = a, addrOutKeyB = b, addrOutKeyP = p} = do
        put AddrOutKeyB {addrOutKeyA = a, addrOutKeyB = b}
        put p
    -- 0x06 · StoreAddr · BlockRef
    put AddrOutKeyB {addrOutKeyA = a, addrOutKeyB = b} = do
        put AddrOutKeyA {addrOutKeyA = a}
        put b
    -- 0x06 · StoreAddr
    put AddrOutKeyA {addrOutKeyA = a} = do
        put AddrOutKeyS
        put a
    -- 0x06
    put AddrOutKeyS = putWord8 0x06
    get = do
        guard . (== 0x06) =<< getWord8
        AddrOutKey <$> get <*> get <*> get

instance Key AddrOutKey

data OutVal = OutVal
    { outValAmount :: !Word64
    , outValScript :: !ByteString
    } deriving (Show, Read, Eq, Ord, Generic, Hashable, Serialize)

instance KeyValue AddrOutKey OutVal

-- | Transaction database key.
data TxKey = TxKey { txKey :: TxHash }
           | TxKeyS { txKeyShort :: (Word32, Word16) }
    deriving (Show, Read, Eq, Ord, Generic, Hashable)

instance Serialize TxKey where
    -- 0x02 · TxHash
    put (TxKey h) = do
        putWord8 0x02
        put h
    put (TxKeyS h) = do
        putWord8 0x02
        put h
    get = do
        guard . (== 0x02) =<< getWord8
        TxKey <$> get

decodeTxKey :: Word64 -> ((Word32, Word16), Word8)
decodeTxKey i =
    let masked = i .&. 0x001fffffffffffff
        wb = masked `shift` 11
        bs = runPut (putWord64be wb)
        g = do
            w1 <- getWord32be
            w2 <- getWord16be
            w3 <- getWord8
            return (w1, w2, w3)
        Right (w1, w2, w3) = runGet g bs
    in ((w1, w2), w3)

instance Key TxKey
instance KeyValue TxKey TxData

data SpenderKey
    = SpenderKey { outputPoint :: !OutPoint }
    | SpenderKeyS { outputKeyS :: !TxHash }
    deriving (Show, Read, Eq, Ord, Generic, Hashable)

instance Serialize SpenderKey where
    -- 0x10 · TxHash · Index
    put (SpenderKey OutPoint {outPointHash = h, outPointIndex = i}) = do
        put (SpenderKeyS h)
        put i
    -- 0x10 · TxHash
    put (SpenderKeyS h) = do
        putWord8 0x10
        put h
    get = do
        guard . (== 0x10) =<< getWord8
        op <- OutPoint <$> get <*> get
        return $ SpenderKey op

instance Key SpenderKey
instance KeyValue SpenderKey Spender

-- | Unspent output database key.
data UnspentKey
    = UnspentKey { unspentKey :: !OutPoint }
    | UnspentKeyS { unspentKeyS :: !TxHash }
    | UnspentKeyB
    deriving (Show, Read, Eq, Ord, Generic, Hashable)

instance Serialize UnspentKey where
    -- 0x09 · TxHash · Index
    put UnspentKey {unspentKey = OutPoint {outPointHash = h, outPointIndex = i}} = do
        putWord8 0x09
        put h
        put i
    -- 0x09 · TxHash
    put UnspentKeyS {unspentKeyS = t} = do
        putWord8 0x09
        put t
    -- 0x09
    put UnspentKeyB = putWord8 0x09
    get = do
        guard . (== 0x09) =<< getWord8
        h <- get
        i <- get
        return $ UnspentKey OutPoint {outPointHash = h, outPointIndex = i}

instance Key UnspentKey
instance KeyValue UnspentKey UnspentVal

toUnspent :: AddrOutKey -> OutVal -> Unspent
toUnspent b v =
    Unspent
        { unspentBlock = addrOutKeyB b
        , unspentAmount = outValAmount v
        , unspentScript = BSS.toShort (outValScript v)
        , unspentPoint = addrOutKeyP b
        , unspentAddress = eitherToMaybe (scriptToAddressBS (outValScript v))
        }

-- | Mempool transaction database key.
data MemKey =
    MemKey
    deriving (Show, Read)

instance Serialize MemKey where
    -- 0x07
    put MemKey = putWord8 0x07
    get = do
        guard . (== 0x07) =<< getWord8
        return MemKey

instance Key MemKey
instance KeyValue MemKey [(UnixTime, TxHash)]

-- | Block entry database key.
newtype BlockKey = BlockKey
    { blockKey :: BlockHash
    } deriving (Show, Read, Eq, Ord, Generic, Hashable)

instance Serialize BlockKey where
    -- 0x01 · BlockHash
    put (BlockKey h) = do
        putWord8 0x01
        put h
    get = do
        guard . (== 0x01) =<< getWord8
        BlockKey <$> get

instance Key BlockKey
instance KeyValue BlockKey BlockData

-- | Block height database key.
newtype HeightKey = HeightKey
    { heightKey :: BlockHeight
    } deriving (Show, Read, Eq, Ord, Generic, Hashable)

instance Serialize HeightKey where
    -- 0x03 · BlockHeight
    put (HeightKey height) = do
        putWord8 0x03
        put height
    get = do
        guard . (== 0x03) =<< getWord8
        HeightKey <$> get

instance Key HeightKey
instance KeyValue HeightKey [BlockHash]

-- | Address balance database key.
data BalKey
    = BalKey
          { balanceKey :: !Address
          }
    | BalKeyS
    deriving (Show, Read, Eq, Ord, Generic, Hashable)

instance Serialize BalKey where
    -- 0x04 · Address
    put BalKey {balanceKey = a} = do
        putWord8 0x04
        put a
    -- 0x04
    put BalKeyS = putWord8 0x04
    get = do
        guard . (== 0x04) =<< getWord8
        BalKey <$> get

instance Key BalKey
instance KeyValue BalKey BalVal

-- | Key for best block in database.
data BestKey =
    BestKey
    deriving (Show, Read, Eq, Ord, Generic, Hashable)

instance Serialize BestKey where
    -- 0x00 × 32
    put BestKey = put (BS.replicate 32 0x00)
    get = do
        guard . (== BS.replicate 32 0x00) =<< getBytes 32
        return BestKey

instance Key BestKey
instance KeyValue BestKey BlockHash

-- | Key for database version.
data VersionKey =
    VersionKey
    deriving (Eq, Show, Read, Ord, Generic, Hashable)

instance Serialize VersionKey where
    -- 0x0a
    put VersionKey = putWord8 0x0a
    get = do
        guard . (== 0x0a) =<< getWord8
        return VersionKey

instance Key VersionKey
instance KeyValue VersionKey Word32

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

balanceToVal :: Balance -> BalVal
balanceToVal Balance { balanceAmount = v
                     , balanceZero = z
                     , balanceUnspentCount = u
                     , balanceTxCount = t
                     , balanceTotalReceived = r
                     } =
    BalVal
        { balValAmount = v
        , balValZero = z
        , balValUnspentCount = u
        , balValTxCount = t
        , balValTotalReceived = r
        }

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
        , unspentAddress = eitherToMaybe (scriptToAddressBS (BSS.fromShort s))
        }
