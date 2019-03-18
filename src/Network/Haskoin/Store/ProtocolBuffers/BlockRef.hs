{-# LANGUAGE BangPatterns, DeriveDataTypeable, DeriveGeneric, FlexibleInstances, MultiParamTypeClasses, OverloadedStrings #-}
{-# OPTIONS_GHC  -w #-}
module Network.Haskoin.Store.ProtocolBuffers.BlockRef (BlockRef(..)) where
import Prelude ((+), (/), (++), (.))
import qualified Prelude as Prelude'
import qualified Data.Typeable as Prelude'
import qualified GHC.Generics as Prelude'
import qualified Data.Data as Prelude'
import qualified Text.ProtocolBuffers.Header as P'
import qualified Network.Haskoin.Store.ProtocolBuffers.BlockRef.Block_ref as ProtocolBuffers.BlockRef (Block_ref)
import qualified Network.Haskoin.Store.ProtocolBuffers.BlockRef.Block_ref as ProtocolBuffers.BlockRef.Block_ref
       (Block_ref(..), get'block, get'mempool)

data BlockRef = BlockRef{block_ref :: P'.Maybe (ProtocolBuffers.BlockRef.Block_ref)}
                deriving (Prelude'.Show, Prelude'.Eq, Prelude'.Ord, Prelude'.Typeable, Prelude'.Data, Prelude'.Generic)

instance P'.Mergeable BlockRef where
  mergeAppend (BlockRef x'1) (BlockRef y'1) = BlockRef (P'.mergeAppend x'1 y'1)

instance P'.Default BlockRef where
  defaultValue = BlockRef P'.defaultValue

instance P'.Wire BlockRef where
  wireSize ft' self'@(BlockRef x'1)
   = case ft' of
       10 -> calc'Size
       11 -> P'.prependMessageSize calc'Size
       _ -> P'.wireSizeErr ft' self'
    where
        calc'Size
         = (P'.wireSizeOpt 1 11 (ProtocolBuffers.BlockRef.Block_ref.get'block Prelude'.=<< x'1) +
             P'.wireSizeOpt 1 11 (ProtocolBuffers.BlockRef.Block_ref.get'mempool Prelude'.=<< x'1))
  wirePutWithSize ft' self'@(BlockRef x'1)
   = case ft' of
       10 -> put'Fields
       11 -> put'FieldsSized
       _ -> P'.wirePutErr ft' self'
    where
        put'Fields
         = P'.sequencePutWithSize
            [P'.wirePutOptWithSize 2 11 (ProtocolBuffers.BlockRef.Block_ref.get'block Prelude'.=<< x'1),
             P'.wirePutOptWithSize 10 11 (ProtocolBuffers.BlockRef.Block_ref.get'mempool Prelude'.=<< x'1)]
        put'FieldsSized
         = let size' = Prelude'.fst (P'.runPutM put'Fields)
               put'Size
                = do
                    P'.putSize size'
                    Prelude'.return (P'.size'WireSize size')
            in P'.sequencePutWithSize [put'Size, put'Fields]
  wireGet ft'
   = case ft' of
       10 -> P'.getBareMessageWith (P'.catch'Unknown' P'.discardUnknown update'Self)
       11 -> P'.getMessageWith (P'.catch'Unknown' P'.discardUnknown update'Self)
       _ -> P'.wireGetErr ft'
    where
        update'Self wire'Tag old'Self
         = case wire'Tag of
             2 -> Prelude'.fmap
                   (\ !new'Field ->
                     old'Self{block_ref =
                               P'.mergeAppend (block_ref old'Self)
                                (Prelude'.Just (ProtocolBuffers.BlockRef.Block_ref.Block new'Field))})
                   (P'.wireGet 11)
             10 -> Prelude'.fmap
                    (\ !new'Field ->
                      old'Self{block_ref =
                                P'.mergeAppend (block_ref old'Self)
                                 (Prelude'.Just (ProtocolBuffers.BlockRef.Block_ref.Mempool new'Field))})
                    (P'.wireGet 11)
             _ -> let (field'Number, wire'Type) = P'.splitWireTag wire'Tag in P'.unknown field'Number wire'Type old'Self

instance P'.MessageAPI msg' (msg' -> BlockRef) BlockRef where
  getVal m' f' = f' m'

instance P'.GPB BlockRef

instance P'.ReflectDescriptor BlockRef where
  getMessageInfo _ = P'.GetMessageInfo (P'.fromDistinctAscList []) (P'.fromDistinctAscList [])
  reflectDescriptorInfo _
   = Prelude'.read
      "DescriptorInfo {descName = ProtoName {protobufName = FIName \".ProtocolBuffers.BlockRef\", haskellPrefix = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule = [MName \"ProtocolBuffers\"], baseName = MName \"BlockRef\"}, descFilePath = [\"Network\",\"Haskoin\",\"Store\",\"ProtocolBuffers\",\"BlockRef.hs\"], isGroup = False, fields = fromList [], descOneofs = fromList [OneofInfo {oneofName = ProtoName {protobufName = FIName \".ProtocolBuffers.BlockRef.block_ref\", haskellPrefix = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule = [MName \"ProtocolBuffers\",MName \"BlockRef\"], baseName = MName \"Block_ref\"}, oneofFName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.BlockRef.block_ref\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"BlockRef\"], baseName' = FName \"block_ref\", baseNamePrefix' = \"\"}, oneofFilePath = [\"Network\",\"Haskoin\",\"Store\",\"ProtocolBuffers\",\"BlockRef\",\"Block_ref.hs\"], oneofFields = fromList [(ProtoName {protobufName = FIName \".ProtocolBuffers.BlockRef.block_ref.block\", haskellPrefix = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule = [MName \"ProtocolBuffers\",MName \"BlockRef\",MName \"Block_ref\"], baseName = MName \"Block\"},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.BlockRef.block_ref.block\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"BlockRef\",MName \"Block_ref\"], baseName' = FName \"block\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 0}, wireTag = WireTag {getWireTag = 2}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = False, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 11}, typeName = Just (ProtoName {protobufName = FIName \".ProtocolBuffers.BlockRef.Block\", haskellPrefix = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule = [MName \"ProtocolBuffers\",MName \"BlockRef\"], baseName = MName \"Block\"}), hsRawDefault = Nothing, hsDefault = Nothing}),(ProtoName {protobufName = FIName \".ProtocolBuffers.BlockRef.block_ref.mempool\", haskellPrefix = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule = [MName \"ProtocolBuffers\",MName \"BlockRef\",MName \"Block_ref\"], baseName = MName \"Mempool\"},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.BlockRef.block_ref.mempool\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"BlockRef\",MName \"Block_ref\"], baseName' = FName \"mempool\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 1}, wireTag = WireTag {getWireTag = 10}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = False, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 11}, typeName = Just (ProtoName {protobufName = FIName \".ProtocolBuffers.BlockRef.Mempool\", haskellPrefix = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule = [MName \"ProtocolBuffers\",MName \"BlockRef\"], baseName = MName \"Mempool\"}), hsRawDefault = Nothing, hsDefault = Nothing})], oneofMakeLenses = False}], keys = fromList [], extRanges = [], knownKeys = fromList [], storeUnknown = False, lazyFields = False, makeLenses = False, jsonInstances = False}"

instance P'.TextType BlockRef where
  tellT = P'.tellSubMessage
  getT = P'.getSubMessage

instance P'.TextMsg BlockRef where
  textPut msg
   = do
       case (block_ref msg) of
         Prelude'.Just (ProtocolBuffers.BlockRef.Block_ref.Block block) -> P'.tellT "block" block
         Prelude'.Just (ProtocolBuffers.BlockRef.Block_ref.Mempool mempool) -> P'.tellT "mempool" mempool
         Prelude'.Nothing -> Prelude'.return ()
  textGet
   = do
       mods <- P'.sepEndBy (P'.choice [parse'block_ref]) P'.spaces
       Prelude'.return (Prelude'.foldl (\ v f -> f v) P'.defaultValue mods)
    where
        parse'block_ref = P'.try (P'.choice [parse'block, parse'mempool])
          where
              parse'block
               = P'.try
                  (do
                     v <- P'.getT "block"
                     Prelude'.return (\ s -> s{block_ref = Prelude'.Just (ProtocolBuffers.BlockRef.Block_ref.Block v)}))
              parse'mempool
               = P'.try
                  (do
                     v <- P'.getT "mempool"
                     Prelude'.return (\ s -> s{block_ref = Prelude'.Just (ProtocolBuffers.BlockRef.Block_ref.Mempool v)}))