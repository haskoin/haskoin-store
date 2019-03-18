{-# LANGUAGE BangPatterns, DeriveDataTypeable, DeriveGeneric, FlexibleInstances, MultiParamTypeClasses, OverloadedStrings #-}
{-# OPTIONS_GHC  -w #-}
module Network.Haskoin.Store.ProtocolBuffers.BlockRef.Block_ref where
import Prelude ((+), (/), (++), (.))
import qualified Prelude as Prelude'
import qualified Data.Typeable as Prelude'
import qualified GHC.Generics as Prelude'
import qualified Data.Data as Prelude'
import qualified Text.ProtocolBuffers.Header as P'
import qualified Network.Haskoin.Store.ProtocolBuffers.BlockRef.Block as ProtocolBuffers.BlockRef (Block)
import qualified Network.Haskoin.Store.ProtocolBuffers.BlockRef.Mempool as ProtocolBuffers.BlockRef (Mempool)

data Block_ref = Block{block :: (ProtocolBuffers.BlockRef.Block)}
               | Mempool{mempool :: (ProtocolBuffers.BlockRef.Mempool)}
                 deriving (Prelude'.Show, Prelude'.Eq, Prelude'.Ord, Prelude'.Typeable, Prelude'.Data, Prelude'.Generic)
get'block x
 = case x of
     Block block -> Prelude'.Just block
     _ -> Prelude'.Nothing
get'mempool x
 = case x of
     Mempool mempool -> Prelude'.Just mempool
     _ -> Prelude'.Nothing

instance P'.Default Block_ref where
  defaultValue = Block P'.defaultValue

instance P'.Mergeable Block_ref