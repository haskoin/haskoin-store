{-# LANGUAGE BangPatterns, DeriveDataTypeable, DeriveGeneric, FlexibleInstances, MultiParamTypeClasses, OverloadedStrings #-}
{-# OPTIONS_GHC  -w #-}
module Network.Haskoin.Store.ProtocolBuffers.BlockData (BlockData(..)) where
import Prelude ((+), (/), (++), (.))
import qualified Prelude as Prelude'
import qualified Data.Typeable as Prelude'
import qualified GHC.Generics as Prelude'
import qualified Data.Data as Prelude'
import qualified Text.ProtocolBuffers.Header as P'

data BlockData = BlockData{hash :: !(P'.ByteString), size :: !(P'.Word32), height :: !(P'.Word32), mainchain :: !(P'.Bool),
                           previous :: !(P'.ByteString), time :: !(P'.Word32), version :: !(P'.Word32), bits :: !(P'.Word32),
                           nonce :: !(P'.Word32), tx :: !(P'.Seq P'.ByteString), merkle :: !(P'.ByteString), fees :: !(P'.Word64),
                           outputs :: !(P'.Word64), subsidy :: !(P'.Word64), weight :: !(P'.Word32)}
                 deriving (Prelude'.Show, Prelude'.Eq, Prelude'.Ord, Prelude'.Typeable, Prelude'.Data, Prelude'.Generic)

instance P'.Mergeable BlockData where
  mergeAppend (BlockData x'1 x'2 x'3 x'4 x'5 x'6 x'7 x'8 x'9 x'10 x'11 x'12 x'13 x'14 x'15)
   (BlockData y'1 y'2 y'3 y'4 y'5 y'6 y'7 y'8 y'9 y'10 y'11 y'12 y'13 y'14 y'15)
   = BlockData (P'.mergeAppend x'1 y'1) (P'.mergeAppend x'2 y'2) (P'.mergeAppend x'3 y'3) (P'.mergeAppend x'4 y'4)
      (P'.mergeAppend x'5 y'5)
      (P'.mergeAppend x'6 y'6)
      (P'.mergeAppend x'7 y'7)
      (P'.mergeAppend x'8 y'8)
      (P'.mergeAppend x'9 y'9)
      (P'.mergeAppend x'10 y'10)
      (P'.mergeAppend x'11 y'11)
      (P'.mergeAppend x'12 y'12)
      (P'.mergeAppend x'13 y'13)
      (P'.mergeAppend x'14 y'14)
      (P'.mergeAppend x'15 y'15)

instance P'.Default BlockData where
  defaultValue
   = BlockData P'.defaultValue P'.defaultValue P'.defaultValue P'.defaultValue P'.defaultValue P'.defaultValue P'.defaultValue
      P'.defaultValue
      P'.defaultValue
      P'.defaultValue
      P'.defaultValue
      P'.defaultValue
      P'.defaultValue
      P'.defaultValue
      P'.defaultValue

instance P'.Wire BlockData where
  wireSize ft' self'@(BlockData x'1 x'2 x'3 x'4 x'5 x'6 x'7 x'8 x'9 x'10 x'11 x'12 x'13 x'14 x'15)
   = case ft' of
       10 -> calc'Size
       11 -> P'.prependMessageSize calc'Size
       _ -> P'.wireSizeErr ft' self'
    where
        calc'Size
         = (P'.wireSizeReq 1 12 x'1 + P'.wireSizeReq 1 13 x'2 + P'.wireSizeReq 1 13 x'3 + P'.wireSizeReq 1 8 x'4 +
             P'.wireSizeReq 1 12 x'5
             + P'.wireSizeReq 1 13 x'6
             + P'.wireSizeReq 1 13 x'7
             + P'.wireSizeReq 1 13 x'8
             + P'.wireSizeReq 1 13 x'9
             + P'.wireSizeRep 1 12 x'10
             + P'.wireSizeReq 1 12 x'11
             + P'.wireSizeReq 1 4 x'12
             + P'.wireSizeReq 1 4 x'13
             + P'.wireSizeReq 1 4 x'14
             + P'.wireSizeReq 1 13 x'15)
  wirePutWithSize ft' self'@(BlockData x'1 x'2 x'3 x'4 x'5 x'6 x'7 x'8 x'9 x'10 x'11 x'12 x'13 x'14 x'15)
   = case ft' of
       10 -> put'Fields
       11 -> put'FieldsSized
       _ -> P'.wirePutErr ft' self'
    where
        put'Fields
         = P'.sequencePutWithSize
            [P'.wirePutReqWithSize 2 12 x'1, P'.wirePutReqWithSize 8 13 x'2, P'.wirePutReqWithSize 16 13 x'3,
             P'.wirePutReqWithSize 24 8 x'4, P'.wirePutReqWithSize 34 12 x'5, P'.wirePutReqWithSize 40 13 x'6,
             P'.wirePutReqWithSize 48 13 x'7, P'.wirePutReqWithSize 56 13 x'8, P'.wirePutReqWithSize 64 13 x'9,
             P'.wirePutRepWithSize 74 12 x'10, P'.wirePutReqWithSize 82 12 x'11, P'.wirePutReqWithSize 88 4 x'12,
             P'.wirePutReqWithSize 96 4 x'13, P'.wirePutReqWithSize 104 4 x'14, P'.wirePutReqWithSize 112 13 x'15]
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
             2 -> Prelude'.fmap (\ !new'Field -> old'Self{hash = new'Field}) (P'.wireGet 12)
             8 -> Prelude'.fmap (\ !new'Field -> old'Self{size = new'Field}) (P'.wireGet 13)
             16 -> Prelude'.fmap (\ !new'Field -> old'Self{height = new'Field}) (P'.wireGet 13)
             24 -> Prelude'.fmap (\ !new'Field -> old'Self{mainchain = new'Field}) (P'.wireGet 8)
             34 -> Prelude'.fmap (\ !new'Field -> old'Self{previous = new'Field}) (P'.wireGet 12)
             40 -> Prelude'.fmap (\ !new'Field -> old'Self{time = new'Field}) (P'.wireGet 13)
             48 -> Prelude'.fmap (\ !new'Field -> old'Self{version = new'Field}) (P'.wireGet 13)
             56 -> Prelude'.fmap (\ !new'Field -> old'Self{bits = new'Field}) (P'.wireGet 13)
             64 -> Prelude'.fmap (\ !new'Field -> old'Self{nonce = new'Field}) (P'.wireGet 13)
             74 -> Prelude'.fmap (\ !new'Field -> old'Self{tx = P'.append (tx old'Self) new'Field}) (P'.wireGet 12)
             82 -> Prelude'.fmap (\ !new'Field -> old'Self{merkle = new'Field}) (P'.wireGet 12)
             88 -> Prelude'.fmap (\ !new'Field -> old'Self{fees = new'Field}) (P'.wireGet 4)
             96 -> Prelude'.fmap (\ !new'Field -> old'Self{outputs = new'Field}) (P'.wireGet 4)
             104 -> Prelude'.fmap (\ !new'Field -> old'Self{subsidy = new'Field}) (P'.wireGet 4)
             112 -> Prelude'.fmap (\ !new'Field -> old'Self{weight = new'Field}) (P'.wireGet 13)
             _ -> let (field'Number, wire'Type) = P'.splitWireTag wire'Tag in P'.unknown field'Number wire'Type old'Self

instance P'.MessageAPI msg' (msg' -> BlockData) BlockData where
  getVal m' f' = f' m'

instance P'.GPB BlockData

instance P'.ReflectDescriptor BlockData where
  getMessageInfo _
   = P'.GetMessageInfo (P'.fromDistinctAscList [2, 8, 16, 24, 34, 40, 48, 56, 64, 82, 88, 96, 104, 112])
      (P'.fromDistinctAscList [2, 8, 16, 24, 34, 40, 48, 56, 64, 74, 82, 88, 96, 104, 112])
  reflectDescriptorInfo _
   = Prelude'.read
      "DescriptorInfo {descName = ProtoName {protobufName = FIName \".ProtocolBuffers.BlockData\", haskellPrefix = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule = [MName \"ProtocolBuffers\"], baseName = MName \"BlockData\"}, descFilePath = [\"Network\",\"Haskoin\",\"Store\",\"ProtocolBuffers\",\"BlockData.hs\"], isGroup = False, fields = fromList [FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.BlockData.hash\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"BlockData\"], baseName' = FName \"hash\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 0}, wireTag = WireTag {getWireTag = 2}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 12}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.BlockData.size\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"BlockData\"], baseName' = FName \"size\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 1}, wireTag = WireTag {getWireTag = 8}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 13}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.BlockData.height\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"BlockData\"], baseName' = FName \"height\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 2}, wireTag = WireTag {getWireTag = 16}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 13}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.BlockData.mainchain\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"BlockData\"], baseName' = FName \"mainchain\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 3}, wireTag = WireTag {getWireTag = 24}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 8}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.BlockData.previous\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"BlockData\"], baseName' = FName \"previous\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 4}, wireTag = WireTag {getWireTag = 34}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 12}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.BlockData.time\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"BlockData\"], baseName' = FName \"time\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 5}, wireTag = WireTag {getWireTag = 40}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 13}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.BlockData.version\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"BlockData\"], baseName' = FName \"version\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 6}, wireTag = WireTag {getWireTag = 48}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 13}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.BlockData.bits\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"BlockData\"], baseName' = FName \"bits\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 7}, wireTag = WireTag {getWireTag = 56}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 13}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.BlockData.nonce\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"BlockData\"], baseName' = FName \"nonce\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 8}, wireTag = WireTag {getWireTag = 64}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 13}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.BlockData.tx\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"BlockData\"], baseName' = FName \"tx\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 9}, wireTag = WireTag {getWireTag = 74}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = False, canRepeat = True, mightPack = False, typeCode = FieldType {getFieldType = 12}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.BlockData.merkle\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"BlockData\"], baseName' = FName \"merkle\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 10}, wireTag = WireTag {getWireTag = 82}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 12}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.BlockData.fees\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"BlockData\"], baseName' = FName \"fees\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 11}, wireTag = WireTag {getWireTag = 88}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 4}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.BlockData.outputs\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"BlockData\"], baseName' = FName \"outputs\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 12}, wireTag = WireTag {getWireTag = 96}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 4}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.BlockData.subsidy\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"BlockData\"], baseName' = FName \"subsidy\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 13}, wireTag = WireTag {getWireTag = 104}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 4}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.BlockData.weight\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"BlockData\"], baseName' = FName \"weight\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 14}, wireTag = WireTag {getWireTag = 112}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 13}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing}], descOneofs = fromList [], keys = fromList [], extRanges = [], knownKeys = fromList [], storeUnknown = False, lazyFields = False, makeLenses = False, jsonInstances = False}"

instance P'.TextType BlockData where
  tellT = P'.tellSubMessage
  getT = P'.getSubMessage

instance P'.TextMsg BlockData where
  textPut msg
   = do
       P'.tellT "hash" (hash msg)
       P'.tellT "size" (size msg)
       P'.tellT "height" (height msg)
       P'.tellT "mainchain" (mainchain msg)
       P'.tellT "previous" (previous msg)
       P'.tellT "time" (time msg)
       P'.tellT "version" (version msg)
       P'.tellT "bits" (bits msg)
       P'.tellT "nonce" (nonce msg)
       P'.tellT "tx" (tx msg)
       P'.tellT "merkle" (merkle msg)
       P'.tellT "fees" (fees msg)
       P'.tellT "outputs" (outputs msg)
       P'.tellT "subsidy" (subsidy msg)
       P'.tellT "weight" (weight msg)
  textGet
   = do
       mods <- P'.sepEndBy
                (P'.choice
                  [parse'hash, parse'size, parse'height, parse'mainchain, parse'previous, parse'time, parse'version, parse'bits,
                   parse'nonce, parse'tx, parse'merkle, parse'fees, parse'outputs, parse'subsidy, parse'weight])
                P'.spaces
       Prelude'.return (Prelude'.foldl (\ v f -> f v) P'.defaultValue mods)
    where
        parse'hash
         = P'.try
            (do
               v <- P'.getT "hash"
               Prelude'.return (\ o -> o{hash = v}))
        parse'size
         = P'.try
            (do
               v <- P'.getT "size"
               Prelude'.return (\ o -> o{size = v}))
        parse'height
         = P'.try
            (do
               v <- P'.getT "height"
               Prelude'.return (\ o -> o{height = v}))
        parse'mainchain
         = P'.try
            (do
               v <- P'.getT "mainchain"
               Prelude'.return (\ o -> o{mainchain = v}))
        parse'previous
         = P'.try
            (do
               v <- P'.getT "previous"
               Prelude'.return (\ o -> o{previous = v}))
        parse'time
         = P'.try
            (do
               v <- P'.getT "time"
               Prelude'.return (\ o -> o{time = v}))
        parse'version
         = P'.try
            (do
               v <- P'.getT "version"
               Prelude'.return (\ o -> o{version = v}))
        parse'bits
         = P'.try
            (do
               v <- P'.getT "bits"
               Prelude'.return (\ o -> o{bits = v}))
        parse'nonce
         = P'.try
            (do
               v <- P'.getT "nonce"
               Prelude'.return (\ o -> o{nonce = v}))
        parse'tx
         = P'.try
            (do
               v <- P'.getT "tx"
               Prelude'.return (\ o -> o{tx = P'.append (tx o) v}))
        parse'merkle
         = P'.try
            (do
               v <- P'.getT "merkle"
               Prelude'.return (\ o -> o{merkle = v}))
        parse'fees
         = P'.try
            (do
               v <- P'.getT "fees"
               Prelude'.return (\ o -> o{fees = v}))
        parse'outputs
         = P'.try
            (do
               v <- P'.getT "outputs"
               Prelude'.return (\ o -> o{outputs = v}))
        parse'subsidy
         = P'.try
            (do
               v <- P'.getT "subsidy"
               Prelude'.return (\ o -> o{subsidy = v}))
        parse'weight
         = P'.try
            (do
               v <- P'.getT "weight"
               Prelude'.return (\ o -> o{weight = v}))