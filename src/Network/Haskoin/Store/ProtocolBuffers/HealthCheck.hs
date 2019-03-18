{-# LANGUAGE BangPatterns, DeriveDataTypeable, DeriveGeneric, FlexibleInstances, MultiParamTypeClasses, OverloadedStrings #-}
{-# OPTIONS_GHC  -w #-}
module Network.Haskoin.Store.ProtocolBuffers.HealthCheck (HealthCheck(..)) where
import Prelude ((+), (/), (++), (.))
import qualified Prelude as Prelude'
import qualified Data.Typeable as Prelude'
import qualified GHC.Generics as Prelude'
import qualified Data.Data as Prelude'
import qualified Text.ProtocolBuffers.Header as P'

data HealthCheck = HealthCheck{ok :: !(P'.Bool), synced :: !(P'.Bool), version :: !(P'.Utf8), net :: !(P'.Utf8),
                               peers :: !(P'.Maybe P'.Word32), headers_hash :: !(P'.Maybe P'.ByteString),
                               headers_height :: !(P'.Maybe P'.Word32), blocks_hash :: !(P'.Maybe P'.ByteString),
                               blocks_height :: !(P'.Maybe P'.Word32)}
                   deriving (Prelude'.Show, Prelude'.Eq, Prelude'.Ord, Prelude'.Typeable, Prelude'.Data, Prelude'.Generic)

instance P'.Mergeable HealthCheck where
  mergeAppend (HealthCheck x'1 x'2 x'3 x'4 x'5 x'6 x'7 x'8 x'9) (HealthCheck y'1 y'2 y'3 y'4 y'5 y'6 y'7 y'8 y'9)
   = HealthCheck (P'.mergeAppend x'1 y'1) (P'.mergeAppend x'2 y'2) (P'.mergeAppend x'3 y'3) (P'.mergeAppend x'4 y'4)
      (P'.mergeAppend x'5 y'5)
      (P'.mergeAppend x'6 y'6)
      (P'.mergeAppend x'7 y'7)
      (P'.mergeAppend x'8 y'8)
      (P'.mergeAppend x'9 y'9)

instance P'.Default HealthCheck where
  defaultValue
   = HealthCheck P'.defaultValue P'.defaultValue P'.defaultValue P'.defaultValue P'.defaultValue P'.defaultValue P'.defaultValue
      P'.defaultValue
      P'.defaultValue

instance P'.Wire HealthCheck where
  wireSize ft' self'@(HealthCheck x'1 x'2 x'3 x'4 x'5 x'6 x'7 x'8 x'9)
   = case ft' of
       10 -> calc'Size
       11 -> P'.prependMessageSize calc'Size
       _ -> P'.wireSizeErr ft' self'
    where
        calc'Size
         = (P'.wireSizeReq 1 8 x'1 + P'.wireSizeReq 1 8 x'2 + P'.wireSizeReq 1 9 x'3 + P'.wireSizeReq 1 9 x'4 +
             P'.wireSizeOpt 1 13 x'5
             + P'.wireSizeOpt 1 12 x'6
             + P'.wireSizeOpt 1 13 x'7
             + P'.wireSizeOpt 1 12 x'8
             + P'.wireSizeOpt 1 13 x'9)
  wirePutWithSize ft' self'@(HealthCheck x'1 x'2 x'3 x'4 x'5 x'6 x'7 x'8 x'9)
   = case ft' of
       10 -> put'Fields
       11 -> put'FieldsSized
       _ -> P'.wirePutErr ft' self'
    where
        put'Fields
         = P'.sequencePutWithSize
            [P'.wirePutReqWithSize 0 8 x'1, P'.wirePutReqWithSize 8 8 x'2, P'.wirePutReqWithSize 18 9 x'3,
             P'.wirePutReqWithSize 26 9 x'4, P'.wirePutOptWithSize 32 13 x'5, P'.wirePutOptWithSize 42 12 x'6,
             P'.wirePutOptWithSize 48 13 x'7, P'.wirePutOptWithSize 58 12 x'8, P'.wirePutOptWithSize 64 13 x'9]
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
             0 -> Prelude'.fmap (\ !new'Field -> old'Self{ok = new'Field}) (P'.wireGet 8)
             8 -> Prelude'.fmap (\ !new'Field -> old'Self{synced = new'Field}) (P'.wireGet 8)
             18 -> Prelude'.fmap (\ !new'Field -> old'Self{version = new'Field}) (P'.wireGet 9)
             26 -> Prelude'.fmap (\ !new'Field -> old'Self{net = new'Field}) (P'.wireGet 9)
             32 -> Prelude'.fmap (\ !new'Field -> old'Self{peers = Prelude'.Just new'Field}) (P'.wireGet 13)
             42 -> Prelude'.fmap (\ !new'Field -> old'Self{headers_hash = Prelude'.Just new'Field}) (P'.wireGet 12)
             48 -> Prelude'.fmap (\ !new'Field -> old'Self{headers_height = Prelude'.Just new'Field}) (P'.wireGet 13)
             58 -> Prelude'.fmap (\ !new'Field -> old'Self{blocks_hash = Prelude'.Just new'Field}) (P'.wireGet 12)
             64 -> Prelude'.fmap (\ !new'Field -> old'Self{blocks_height = Prelude'.Just new'Field}) (P'.wireGet 13)
             _ -> let (field'Number, wire'Type) = P'.splitWireTag wire'Tag in P'.unknown field'Number wire'Type old'Self

instance P'.MessageAPI msg' (msg' -> HealthCheck) HealthCheck where
  getVal m' f' = f' m'

instance P'.GPB HealthCheck

instance P'.ReflectDescriptor HealthCheck where
  getMessageInfo _
   = P'.GetMessageInfo (P'.fromDistinctAscList [0, 8, 18, 26]) (P'.fromDistinctAscList [0, 8, 18, 26, 32, 42, 48, 58, 64])
  reflectDescriptorInfo _
   = Prelude'.read
      "DescriptorInfo {descName = ProtoName {protobufName = FIName \".ProtocolBuffers.HealthCheck\", haskellPrefix = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule = [MName \"ProtocolBuffers\"], baseName = MName \"HealthCheck\"}, descFilePath = [\"Network\",\"Haskoin\",\"Store\",\"ProtocolBuffers\",\"HealthCheck.hs\"], isGroup = False, fields = fromList [FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.HealthCheck.ok\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"HealthCheck\"], baseName' = FName \"ok\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 0}, wireTag = WireTag {getWireTag = 0}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 8}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.HealthCheck.synced\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"HealthCheck\"], baseName' = FName \"synced\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 1}, wireTag = WireTag {getWireTag = 8}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 8}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.HealthCheck.version\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"HealthCheck\"], baseName' = FName \"version\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 2}, wireTag = WireTag {getWireTag = 18}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 9}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.HealthCheck.net\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"HealthCheck\"], baseName' = FName \"net\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 3}, wireTag = WireTag {getWireTag = 26}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 9}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.HealthCheck.peers\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"HealthCheck\"], baseName' = FName \"peers\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 4}, wireTag = WireTag {getWireTag = 32}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = False, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 13}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.HealthCheck.headers_hash\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"HealthCheck\"], baseName' = FName \"headers_hash\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 5}, wireTag = WireTag {getWireTag = 42}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = False, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 12}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.HealthCheck.headers_height\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"HealthCheck\"], baseName' = FName \"headers_height\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 6}, wireTag = WireTag {getWireTag = 48}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = False, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 13}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.HealthCheck.blocks_hash\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"HealthCheck\"], baseName' = FName \"blocks_hash\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 7}, wireTag = WireTag {getWireTag = 58}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = False, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 12}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.HealthCheck.blocks_height\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"HealthCheck\"], baseName' = FName \"blocks_height\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 8}, wireTag = WireTag {getWireTag = 64}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = False, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 13}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing}], descOneofs = fromList [], keys = fromList [], extRanges = [], knownKeys = fromList [], storeUnknown = False, lazyFields = False, makeLenses = False, jsonInstances = False}"

instance P'.TextType HealthCheck where
  tellT = P'.tellSubMessage
  getT = P'.getSubMessage

instance P'.TextMsg HealthCheck where
  textPut msg
   = do
       P'.tellT "ok" (ok msg)
       P'.tellT "synced" (synced msg)
       P'.tellT "version" (version msg)
       P'.tellT "net" (net msg)
       P'.tellT "peers" (peers msg)
       P'.tellT "headers_hash" (headers_hash msg)
       P'.tellT "headers_height" (headers_height msg)
       P'.tellT "blocks_hash" (blocks_hash msg)
       P'.tellT "blocks_height" (blocks_height msg)
  textGet
   = do
       mods <- P'.sepEndBy
                (P'.choice
                  [parse'ok, parse'synced, parse'version, parse'net, parse'peers, parse'headers_hash, parse'headers_height,
                   parse'blocks_hash, parse'blocks_height])
                P'.spaces
       Prelude'.return (Prelude'.foldl (\ v f -> f v) P'.defaultValue mods)
    where
        parse'ok
         = P'.try
            (do
               v <- P'.getT "ok"
               Prelude'.return (\ o -> o{ok = v}))
        parse'synced
         = P'.try
            (do
               v <- P'.getT "synced"
               Prelude'.return (\ o -> o{synced = v}))
        parse'version
         = P'.try
            (do
               v <- P'.getT "version"
               Prelude'.return (\ o -> o{version = v}))
        parse'net
         = P'.try
            (do
               v <- P'.getT "net"
               Prelude'.return (\ o -> o{net = v}))
        parse'peers
         = P'.try
            (do
               v <- P'.getT "peers"
               Prelude'.return (\ o -> o{peers = v}))
        parse'headers_hash
         = P'.try
            (do
               v <- P'.getT "headers_hash"
               Prelude'.return (\ o -> o{headers_hash = v}))
        parse'headers_height
         = P'.try
            (do
               v <- P'.getT "headers_height"
               Prelude'.return (\ o -> o{headers_height = v}))
        parse'blocks_hash
         = P'.try
            (do
               v <- P'.getT "blocks_hash"
               Prelude'.return (\ o -> o{blocks_hash = v}))
        parse'blocks_height
         = P'.try
            (do
               v <- P'.getT "blocks_height"
               Prelude'.return (\ o -> o{blocks_height = v}))