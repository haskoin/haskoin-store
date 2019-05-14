{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
module Network.Haskoin.Store.Data.KeyValue where

import           Control.Monad.Reader
import           Data.ByteString            (ByteString)
import qualified Data.ByteString            as B
import           Data.Default
import           Data.Hashable
import           Data.Serialize             as S
import           Data.Word
import qualified Database.RocksDB.Query     as R
import           GHC.Generics
import           Haskoin
import           Network.Haskoin.Store.Data

-- | Database key for an address transaction.
data AddrTxKey
    = AddrTxKey { addrTxKeyA :: !Address
                , addrTxKeyT :: !BlockTx
                }
      -- ^ key for a transaction affecting an address
    | AddrTxKeyA { addrTxKeyA :: !Address }
      -- ^ short key that matches all entries
    | AddrTxKeyB { addrTxKeyA :: !Address
                 , addrTxKeyB :: !BlockRef
                 }
    deriving (Show, Eq, Ord, Generic, Hashable)

instance Serialize AddrTxKey
    -- 0x05 · Address · BlockRef · TxHash
                                                               where
    put AddrTxKey { addrTxKeyA = a
                  , addrTxKeyT = BlockTx { blockTxBlock = b
                                         , blockTxHash = t
                                         }
                  } = do
        putWord8 0x05
        put a
        put b
        put t
    -- 0x05 · Address
    put AddrTxKeyA {addrTxKeyA = a} = do
        putWord8 0x05
        put a
    -- 0x05 · Address · BlockRef
    put AddrTxKeyB {addrTxKeyA = a, addrTxKeyB = b} = do
        putWord8 0x05
        put a
        put b
    get = do
        guard . (== 0x05) =<< getWord8
        a <- get
        b <- get
        t <- get
        return
            AddrTxKey
                { addrTxKeyA = a
                , addrTxKeyT =
                      BlockTx
                          { blockTxBlock = b
                          , blockTxHash = t
                          }
                }

instance R.Key AddrTxKey

instance R.KeyValue AddrTxKey ()

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
    deriving (Show, Read, Eq, Ord, Generic, Hashable)

instance Serialize AddrOutKey
    -- 0x06 · StoreAddr · BlockRef · OutPoint
                                              where
    put AddrOutKey {addrOutKeyA = a, addrOutKeyB = b, addrOutKeyP = p} = do
        putWord8 0x06
        put a
        put b
        put p
    -- 0x06 · StoreAddr
    put AddrOutKeyA {addrOutKeyA = a} = do
        putWord8 0x06
        put a
    -- 0x06 · StoreAddr · BlockRef
    put AddrOutKeyB {addrOutKeyA = a, addrOutKeyB = b} = do
        putWord8 0x06
        put a
        put b
    get = do
        guard . (== 0x06) =<< getWord8
        AddrOutKey <$> get <*> get <*> get

instance R.Key AddrOutKey

data OutVal = OutVal
    { outValAmount :: !Word64
    , outValScript :: !ByteString
    } deriving (Show, Read, Eq, Ord, Generic, Hashable, Serialize)

instance R.KeyValue AddrOutKey OutVal

-- | Transaction database key.
newtype TxKey = TxKey
    { txKey :: TxHash
    } deriving (Show, Read, Eq, Ord, Generic, Hashable)

instance Serialize TxKey where
    -- 0x02 · TxHash
    put (TxKey h) = do
        putWord8 0x02
        put h
    get = do
        guard . (== 0x02) =<< getWord8
        TxKey <$> get

instance R.Key TxKey

instance R.KeyValue TxKey TxData

data SpenderKey
    = SpenderKey { outputPoint :: !OutPoint }
    | SpenderKeyS { outputKeyS :: !TxHash }
    deriving (Show, Read, Eq, Ord, Generic, Hashable)

instance Serialize SpenderKey where
    -- 0x10 · TxHash · Index
    put (SpenderKey OutPoint {outPointHash = h, outPointIndex = i}) = do
        putWord8 0x10
        put h
        put i
    put (SpenderKeyS h) = do
        putWord8 0x10
        put h
    get = do
        guard . (== 0x10) =<< getWord8
        op <- OutPoint <$> get <*> get
        return $ SpenderKey op

instance R.Key SpenderKey

instance R.KeyValue SpenderKey Spender

-- | Unspent output database key.
data UnspentKey
    = UnspentKey { unspentKey :: !OutPoint }
    | UnspentKeyS { unspentKeyS :: !TxHash }
    deriving (Show, Read, Eq, Ord, Generic, Hashable)

instance Serialize UnspentKey where
    -- 0x09 · TxHash · Index
    put UnspentKey {unspentKey = OutPoint {outPointHash = h, outPointIndex = i}} = do
        putWord8 0x09
        put h
        put i
    put UnspentKeyS {unspentKeyS = t} = do
        putWord8 0x09
        put t
    get = do
        guard . (== 0x09) =<< getWord8
        h <- get
        i <- get
        return $ UnspentKey OutPoint {outPointHash = h, outPointIndex = i}

data UnspentVal = UnspentVal
    { unspentValBlock  :: !BlockRef
    , unspentValAmount :: !Word64
    , unspentValScript :: !ByteString
    } deriving (Show, Read, Eq, Ord, Generic, Hashable, Serialize)

instance R.Key UnspentKey

instance R.KeyValue UnspentKey UnspentVal

-- | Mempool transaction database key.
data MemKey
    = MemKey { memTime :: !UnixTime
             , memKey  :: !TxHash }
    | MemKeyT { memTime :: !UnixTime }
    | MemKeyS
    deriving (Show, Read, Eq, Ord, Generic, Hashable)

instance Serialize MemKey where
    -- 0x07 · TxHash
    put (MemKey t h) = do
        putWord8 0x07
        putUnixTime t
        put h
    put (MemKeyT t) = do
        putWord8 0x07
        putUnixTime t
    -- 0x07
    put MemKeyS = putWord8 0x07
    get = do
        guard . (== 0x07) =<< getWord8
        MemKey <$> getUnixTime <*> get

instance R.Key MemKey
instance R.KeyValue MemKey ()

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

instance R.KeyValue BlockKey BlockData

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

instance R.Key HeightKey

instance R.KeyValue HeightKey [BlockHash]

-- | Address balance database key.
newtype BalKey
    = BalKey { balanceKey :: Address }
    deriving (Show, Read, Eq, Ord, Generic, Hashable)

instance Serialize BalKey where
    -- 0x04 · Address
    put BalKey {balanceKey = a} = do
        putWord8 0x04
        put a
    get = do
        guard . (== 0x04) =<< getWord8
        BalKey <$> get

instance R.Key BalKey

-- | Address balance database value.
data BalVal = BalVal
    { balValAmount        :: !Word64
      -- ^ balance in satoshi
    , balValZero          :: !Word64
      -- ^ unconfirmed balance in satoshi
    , balValUnspentCount  :: !Word64
      -- ^ number of unspent outputs
    , balValTxCount       :: !Word64
      -- ^ number of transactions
    , balValTotalReceived :: !Word64
      -- ^ total amount received by this address
    } deriving (Show, Read, Eq, Ord, Generic, Hashable, Serialize)

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

instance R.KeyValue BalKey BalVal

-- | Key for best block in database.
data BestKey =
    BestKey
    deriving (Show, Read, Eq, Ord, Generic, Hashable)

instance Serialize BestKey where
    -- 0x00 × 32
    put BestKey = put (B.replicate 32 0x00)
    get = do
        guard . (== B.replicate 32 0x00) =<< getBytes 32
        return BestKey

instance R.Key BestKey

instance R.KeyValue BestKey BlockHash

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

instance R.Key VersionKey

instance R.KeyValue VersionKey Word32
