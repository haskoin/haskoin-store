{-# LANGUAGE BangPatterns, DeriveDataTypeable, DeriveGeneric, FlexibleInstances, MultiParamTypeClasses, OverloadedStrings #-}
{-# OPTIONS_GHC  -w #-}
module Network.Haskoin.Store.ProtocolBuffers.Transaction (Transaction(..)) where
import Prelude ((+), (/), (++), (.))
import qualified Prelude as Prelude'
import qualified Data.Typeable as Prelude'
import qualified GHC.Generics as Prelude'
import qualified Data.Data as Prelude'
import qualified Text.ProtocolBuffers.Header as P'
import qualified Network.Haskoin.Store.ProtocolBuffers.BlockRef as ProtocolBuffers (BlockRef)
import qualified Network.Haskoin.Store.ProtocolBuffers.Input as ProtocolBuffers (Input)
import qualified Network.Haskoin.Store.ProtocolBuffers.Output as ProtocolBuffers (Output)
import qualified Network.Haskoin.Store.ProtocolBuffers.TxId as ProtocolBuffers (TxId)

data Transaction = Transaction{txid :: !(ProtocolBuffers.TxId), size :: !(P'.Word32), version :: !(P'.Word32),
                               locktime :: !(P'.Word32), block :: !(ProtocolBuffers.BlockRef), deleted :: !(P'.Bool),
                               fee :: !(P'.Word64), time :: !(P'.Word64), rbf :: !(P'.Bool),
                               inputs :: !(P'.Seq ProtocolBuffers.Input), outputs :: !(P'.Seq ProtocolBuffers.Output),
                               weight :: !(P'.Maybe P'.Word32)}
                   deriving (Prelude'.Show, Prelude'.Eq, Prelude'.Ord, Prelude'.Typeable, Prelude'.Data, Prelude'.Generic)

instance P'.Mergeable Transaction where
  mergeAppend (Transaction x'1 x'2 x'3 x'4 x'5 x'6 x'7 x'8 x'9 x'10 x'11 x'12)
   (Transaction y'1 y'2 y'3 y'4 y'5 y'6 y'7 y'8 y'9 y'10 y'11 y'12)
   = Transaction (P'.mergeAppend x'1 y'1) (P'.mergeAppend x'2 y'2) (P'.mergeAppend x'3 y'3) (P'.mergeAppend x'4 y'4)
      (P'.mergeAppend x'5 y'5)
      (P'.mergeAppend x'6 y'6)
      (P'.mergeAppend x'7 y'7)
      (P'.mergeAppend x'8 y'8)
      (P'.mergeAppend x'9 y'9)
      (P'.mergeAppend x'10 y'10)
      (P'.mergeAppend x'11 y'11)
      (P'.mergeAppend x'12 y'12)

instance P'.Default Transaction where
  defaultValue
   = Transaction P'.defaultValue P'.defaultValue P'.defaultValue P'.defaultValue P'.defaultValue P'.defaultValue P'.defaultValue
      P'.defaultValue
      P'.defaultValue
      P'.defaultValue
      P'.defaultValue
      P'.defaultValue

instance P'.Wire Transaction where
  wireSize ft' self'@(Transaction x'1 x'2 x'3 x'4 x'5 x'6 x'7 x'8 x'9 x'10 x'11 x'12)
   = case ft' of
       10 -> calc'Size
       11 -> P'.prependMessageSize calc'Size
       _ -> P'.wireSizeErr ft' self'
    where
        calc'Size
         = (P'.wireSizeReq 1 11 x'1 + P'.wireSizeReq 1 13 x'2 + P'.wireSizeReq 1 13 x'3 + P'.wireSizeReq 1 13 x'4 +
             P'.wireSizeReq 1 11 x'5
             + P'.wireSizeReq 1 8 x'6
             + P'.wireSizeReq 1 4 x'7
             + P'.wireSizeReq 1 4 x'8
             + P'.wireSizeReq 1 8 x'9
             + P'.wireSizeRep 1 11 x'10
             + P'.wireSizeRep 1 11 x'11
             + P'.wireSizeOpt 1 13 x'12)
  wirePutWithSize ft' self'@(Transaction x'1 x'2 x'3 x'4 x'5 x'6 x'7 x'8 x'9 x'10 x'11 x'12)
   = case ft' of
       10 -> put'Fields
       11 -> put'FieldsSized
       _ -> P'.wirePutErr ft' self'
    where
        put'Fields
         = P'.sequencePutWithSize
            [P'.wirePutReqWithSize 2 11 x'1, P'.wirePutReqWithSize 8 13 x'2, P'.wirePutReqWithSize 16 13 x'3,
             P'.wirePutReqWithSize 24 13 x'4, P'.wirePutReqWithSize 34 11 x'5, P'.wirePutReqWithSize 40 8 x'6,
             P'.wirePutReqWithSize 48 4 x'7, P'.wirePutReqWithSize 56 4 x'8, P'.wirePutReqWithSize 64 8 x'9,
             P'.wirePutRepWithSize 74 11 x'10, P'.wirePutRepWithSize 82 11 x'11, P'.wirePutOptWithSize 88 13 x'12]
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
             2 -> Prelude'.fmap (\ !new'Field -> old'Self{txid = P'.mergeAppend (txid old'Self) (new'Field)}) (P'.wireGet 11)
             8 -> Prelude'.fmap (\ !new'Field -> old'Self{size = new'Field}) (P'.wireGet 13)
             16 -> Prelude'.fmap (\ !new'Field -> old'Self{version = new'Field}) (P'.wireGet 13)
             24 -> Prelude'.fmap (\ !new'Field -> old'Self{locktime = new'Field}) (P'.wireGet 13)
             34 -> Prelude'.fmap (\ !new'Field -> old'Self{block = P'.mergeAppend (block old'Self) (new'Field)}) (P'.wireGet 11)
             40 -> Prelude'.fmap (\ !new'Field -> old'Self{deleted = new'Field}) (P'.wireGet 8)
             48 -> Prelude'.fmap (\ !new'Field -> old'Self{fee = new'Field}) (P'.wireGet 4)
             56 -> Prelude'.fmap (\ !new'Field -> old'Self{time = new'Field}) (P'.wireGet 4)
             64 -> Prelude'.fmap (\ !new'Field -> old'Self{rbf = new'Field}) (P'.wireGet 8)
             74 -> Prelude'.fmap (\ !new'Field -> old'Self{inputs = P'.append (inputs old'Self) new'Field}) (P'.wireGet 11)
             82 -> Prelude'.fmap (\ !new'Field -> old'Self{outputs = P'.append (outputs old'Self) new'Field}) (P'.wireGet 11)
             88 -> Prelude'.fmap (\ !new'Field -> old'Self{weight = Prelude'.Just new'Field}) (P'.wireGet 13)
             _ -> let (field'Number, wire'Type) = P'.splitWireTag wire'Tag in P'.unknown field'Number wire'Type old'Self

instance P'.MessageAPI msg' (msg' -> Transaction) Transaction where
  getVal m' f' = f' m'

instance P'.GPB Transaction

instance P'.ReflectDescriptor Transaction where
  getMessageInfo _
   = P'.GetMessageInfo (P'.fromDistinctAscList [2, 8, 16, 24, 34, 40, 48, 56, 64])
      (P'.fromDistinctAscList [2, 8, 16, 24, 34, 40, 48, 56, 64, 74, 82, 88])
  reflectDescriptorInfo _
   = Prelude'.read
      "DescriptorInfo {descName = ProtoName {protobufName = FIName \".ProtocolBuffers.Transaction\", haskellPrefix = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule = [MName \"ProtocolBuffers\"], baseName = MName \"Transaction\"}, descFilePath = [\"Network\",\"Haskoin\",\"Store\",\"ProtocolBuffers\",\"Transaction.hs\"], isGroup = False, fields = fromList [FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.Transaction.txid\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"Transaction\"], baseName' = FName \"txid\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 0}, wireTag = WireTag {getWireTag = 2}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 11}, typeName = Just (ProtoName {protobufName = FIName \".ProtocolBuffers.TxId\", haskellPrefix = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule = [MName \"ProtocolBuffers\"], baseName = MName \"TxId\"}), hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.Transaction.size\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"Transaction\"], baseName' = FName \"size\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 1}, wireTag = WireTag {getWireTag = 8}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 13}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.Transaction.version\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"Transaction\"], baseName' = FName \"version\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 2}, wireTag = WireTag {getWireTag = 16}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 13}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.Transaction.locktime\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"Transaction\"], baseName' = FName \"locktime\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 3}, wireTag = WireTag {getWireTag = 24}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 13}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.Transaction.block\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"Transaction\"], baseName' = FName \"block\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 4}, wireTag = WireTag {getWireTag = 34}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 11}, typeName = Just (ProtoName {protobufName = FIName \".ProtocolBuffers.BlockRef\", haskellPrefix = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule = [MName \"ProtocolBuffers\"], baseName = MName \"BlockRef\"}), hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.Transaction.deleted\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"Transaction\"], baseName' = FName \"deleted\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 5}, wireTag = WireTag {getWireTag = 40}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 8}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.Transaction.fee\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"Transaction\"], baseName' = FName \"fee\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 6}, wireTag = WireTag {getWireTag = 48}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 4}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.Transaction.time\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"Transaction\"], baseName' = FName \"time\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 7}, wireTag = WireTag {getWireTag = 56}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 4}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.Transaction.rbf\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"Transaction\"], baseName' = FName \"rbf\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 8}, wireTag = WireTag {getWireTag = 64}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 8}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.Transaction.inputs\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"Transaction\"], baseName' = FName \"inputs\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 9}, wireTag = WireTag {getWireTag = 74}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = False, canRepeat = True, mightPack = False, typeCode = FieldType {getFieldType = 11}, typeName = Just (ProtoName {protobufName = FIName \".ProtocolBuffers.Input\", haskellPrefix = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule = [MName \"ProtocolBuffers\"], baseName = MName \"Input\"}), hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.Transaction.outputs\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"Transaction\"], baseName' = FName \"outputs\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 10}, wireTag = WireTag {getWireTag = 82}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = False, canRepeat = True, mightPack = False, typeCode = FieldType {getFieldType = 11}, typeName = Just (ProtoName {protobufName = FIName \".ProtocolBuffers.Output\", haskellPrefix = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule = [MName \"ProtocolBuffers\"], baseName = MName \"Output\"}), hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.Transaction.weight\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"Transaction\"], baseName' = FName \"weight\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 11}, wireTag = WireTag {getWireTag = 88}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = False, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 13}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing}], descOneofs = fromList [], keys = fromList [], extRanges = [], knownKeys = fromList [], storeUnknown = False, lazyFields = False, makeLenses = False, jsonInstances = False}"

instance P'.TextType Transaction where
  tellT = P'.tellSubMessage
  getT = P'.getSubMessage

instance P'.TextMsg Transaction where
  textPut msg
   = do
       P'.tellT "txid" (txid msg)
       P'.tellT "size" (size msg)
       P'.tellT "version" (version msg)
       P'.tellT "locktime" (locktime msg)
       P'.tellT "block" (block msg)
       P'.tellT "deleted" (deleted msg)
       P'.tellT "fee" (fee msg)
       P'.tellT "time" (time msg)
       P'.tellT "rbf" (rbf msg)
       P'.tellT "inputs" (inputs msg)
       P'.tellT "outputs" (outputs msg)
       P'.tellT "weight" (weight msg)
  textGet
   = do
       mods <- P'.sepEndBy
                (P'.choice
                  [parse'txid, parse'size, parse'version, parse'locktime, parse'block, parse'deleted, parse'fee, parse'time,
                   parse'rbf, parse'inputs, parse'outputs, parse'weight])
                P'.spaces
       Prelude'.return (Prelude'.foldl (\ v f -> f v) P'.defaultValue mods)
    where
        parse'txid
         = P'.try
            (do
               v <- P'.getT "txid"
               Prelude'.return (\ o -> o{txid = v}))
        parse'size
         = P'.try
            (do
               v <- P'.getT "size"
               Prelude'.return (\ o -> o{size = v}))
        parse'version
         = P'.try
            (do
               v <- P'.getT "version"
               Prelude'.return (\ o -> o{version = v}))
        parse'locktime
         = P'.try
            (do
               v <- P'.getT "locktime"
               Prelude'.return (\ o -> o{locktime = v}))
        parse'block
         = P'.try
            (do
               v <- P'.getT "block"
               Prelude'.return (\ o -> o{block = v}))
        parse'deleted
         = P'.try
            (do
               v <- P'.getT "deleted"
               Prelude'.return (\ o -> o{deleted = v}))
        parse'fee
         = P'.try
            (do
               v <- P'.getT "fee"
               Prelude'.return (\ o -> o{fee = v}))
        parse'time
         = P'.try
            (do
               v <- P'.getT "time"
               Prelude'.return (\ o -> o{time = v}))
        parse'rbf
         = P'.try
            (do
               v <- P'.getT "rbf"
               Prelude'.return (\ o -> o{rbf = v}))
        parse'inputs
         = P'.try
            (do
               v <- P'.getT "inputs"
               Prelude'.return (\ o -> o{inputs = P'.append (inputs o) v}))
        parse'outputs
         = P'.try
            (do
               v <- P'.getT "outputs"
               Prelude'.return (\ o -> o{outputs = P'.append (outputs o) v}))
        parse'weight
         = P'.try
            (do
               v <- P'.getT "weight"
               Prelude'.return (\ o -> o{weight = v}))