{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
module Network.Haskoin.Store.Messages where

import           Data.ByteString  (ByteString)
import           Data.Word
import           Database.RocksDB (DB)
import           Haskoin
import           Haskoin.Node
import           Network.Socket
import           NQE

-- | Mailbox for block store.
type BlockStore = Mailbox BlockMessage

-- | Store mailboxes.
data Store = Store
    { storeManager :: !Manager
      -- ^ peer manager mailbox
    , storeChain   :: !Chain
      -- ^ chain header process mailbox
    , storeBlock   :: !BlockStore
      -- ^ block storage mailbox
    }

-- | Configuration for a 'Store'.
data StoreConfig = StoreConfig
    { storeConfMaxPeers  :: !Int
      -- ^ max peers to connect to
    , storeConfInitPeers :: ![HostPort]
      -- ^ static set of peers to connect to
    , storeConfDiscover  :: !Bool
      -- ^ discover new peers?
    , storeConfDB        :: !DB
      -- ^ RocksDB database handler
    , storeConfNetwork   :: !Network
      -- ^ network constants
    , storeConfListen    :: !(Listen StoreEvent)
    }

-- | Configuration for a block store.
data BlockConfig = BlockConfig
    { blockConfManager  :: !Manager
      -- ^ peer manager from running node
    , blockConfChain    :: !Chain
      -- ^ chain from a running node
    , blockConfListener :: !(Listen StoreEvent)
      -- ^ listener for store events
    , blockConfDB       :: !DB
      -- ^ RocksDB database handle
    , blockConfNet      :: !Network
      -- ^ network constants
    }

-- | Messages that a 'BlockStore' can accept.
data BlockMessage
    = BlockNewBest !BlockNode
      -- ^ new block header in chain
    | BlockPeerConnect !Peer
                       !SockAddr
      -- ^ new peer connected
    | BlockPeerDisconnect !Peer
                          !SockAddr
      -- ^ peer disconnected
    | BlockReceived !Peer
                    !Block
      -- ^ new block received from a peer
    | BlockNotFound !Peer
                    ![BlockHash]
      -- ^ block not found
    | BlockTxReceived !Peer
                      !Tx
      -- ^ transaction received from peer
    | BlockTxAvailable !Peer
                       ![TxHash]
      -- ^ peer has transactions available
    | BlockPing !(Listen ())
      -- ^ internal housekeeping ping
    | PurgeMempool
      -- ^ purge mempool transactions

-- | Events that the store can generate.
data StoreEvent
    = StoreBestBlock !BlockHash
      -- ^ new best block
    | StoreMempoolNew !TxHash
      -- ^ new mempool transaction
    | StorePeerConnected !Peer
                         !SockAddr
      -- ^ new peer connected
    | StorePeerDisconnected !Peer
                            !SockAddr
      -- ^ peer has disconnected
    | StorePeerPong !Peer
                    !Word64
      -- ^ peer responded 'Ping'
    | StoreTxAvailable !Peer
                       ![TxHash]
      -- ^ peer inv transactions
    | StoreTxReject !Peer
                    !TxHash
                    !RejectCode
                    !ByteString
      -- ^ peer rejected transaction
