{-# LANGUAGE BangPatterns, DeriveDataTypeable, DeriveGeneric, FlexibleInstances, MultiParamTypeClasses, OverloadedStrings #-}
{-# OPTIONS_GHC  -w #-}
module Network.Haskoin.Store.ProtocolBuffers.XPubUnspent (XPubUnspent(..)) where
import Prelude ((+), (/), (++), (.))
import qualified Prelude as Prelude'
import qualified Data.Typeable as Prelude'
import qualified GHC.Generics as Prelude'
import qualified Data.Data as Prelude'
import qualified Text.ProtocolBuffers.Header as P'
import qualified Network.Haskoin.Store.ProtocolBuffers.Unspent as ProtocolBuffers (Unspent)

data XPubUnspent = XPubUnspent{path :: !(P'.Seq P'.Word32), unspent :: !(ProtocolBuffers.Unspent)}
                   deriving (Prelude'.Show, Prelude'.Eq, Prelude'.Ord, Prelude'.Typeable, Prelude'.Data, Prelude'.Generic)

instance P'.Mergeable XPubUnspent where
  mergeAppend (XPubUnspent x'1 x'2) (XPubUnspent y'1 y'2) = XPubUnspent (P'.mergeAppend x'1 y'1) (P'.mergeAppend x'2 y'2)

instance P'.Default XPubUnspent where
  defaultValue = XPubUnspent P'.defaultValue P'.defaultValue

instance P'.Wire XPubUnspent where
  wireSize ft' self'@(XPubUnspent x'1 x'2)
   = case ft' of
       10 -> calc'Size
       11 -> P'.prependMessageSize calc'Size
       _ -> P'.wireSizeErr ft' self'
    where
        calc'Size = (P'.wireSizePacked 1 13 x'1 + P'.wireSizeReq 1 11 x'2)
  wirePutWithSize ft' self'@(XPubUnspent x'1 x'2)
   = case ft' of
       10 -> put'Fields
       11 -> put'FieldsSized
       _ -> P'.wirePutErr ft' self'
    where
        put'Fields = P'.sequencePutWithSize [P'.wirePutPackedWithSize 2 13 x'1, P'.wirePutReqWithSize 10 11 x'2]
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
             0 -> Prelude'.fmap (\ !new'Field -> old'Self{path = P'.append (path old'Self) new'Field}) (P'.wireGet 13)
             2 -> Prelude'.fmap (\ !new'Field -> old'Self{path = P'.mergeAppend (path old'Self) new'Field}) (P'.wireGetPacked 13)
             10 -> Prelude'.fmap (\ !new'Field -> old'Self{unspent = P'.mergeAppend (unspent old'Self) (new'Field)}) (P'.wireGet 11)
             _ -> let (field'Number, wire'Type) = P'.splitWireTag wire'Tag in P'.unknown field'Number wire'Type old'Self

instance P'.MessageAPI msg' (msg' -> XPubUnspent) XPubUnspent where
  getVal m' f' = f' m'

instance P'.GPB XPubUnspent

instance P'.ReflectDescriptor XPubUnspent where
  getMessageInfo _ = P'.GetMessageInfo (P'.fromDistinctAscList [10]) (P'.fromDistinctAscList [0, 2, 10])
  reflectDescriptorInfo _
   = Prelude'.read
      "DescriptorInfo {descName = ProtoName {protobufName = FIName \".ProtocolBuffers.XPubUnspent\", haskellPrefix = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule = [MName \"ProtocolBuffers\"], baseName = MName \"XPubUnspent\"}, descFilePath = [\"Network\",\"Haskoin\",\"Store\",\"ProtocolBuffers\",\"XPubUnspent.hs\"], isGroup = False, fields = fromList [FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.XPubUnspent.path\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"XPubUnspent\"], baseName' = FName \"path\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 0}, wireTag = WireTag {getWireTag = 2}, packedTag = Just (WireTag {getWireTag = 0},WireTag {getWireTag = 2}), wireTagLength = 1, isPacked = True, isRequired = False, canRepeat = True, mightPack = True, typeCode = FieldType {getFieldType = 13}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.XPubUnspent.unspent\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"XPubUnspent\"], baseName' = FName \"unspent\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 1}, wireTag = WireTag {getWireTag = 10}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 11}, typeName = Just (ProtoName {protobufName = FIName \".ProtocolBuffers.Unspent\", haskellPrefix = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule = [MName \"ProtocolBuffers\"], baseName = MName \"Unspent\"}), hsRawDefault = Nothing, hsDefault = Nothing}], descOneofs = fromList [], keys = fromList [], extRanges = [], knownKeys = fromList [], storeUnknown = False, lazyFields = False, makeLenses = False, jsonInstances = False}"

instance P'.TextType XPubUnspent where
  tellT = P'.tellSubMessage
  getT = P'.getSubMessage

instance P'.TextMsg XPubUnspent where
  textPut msg
   = do
       P'.tellT "path" (path msg)
       P'.tellT "unspent" (unspent msg)
  textGet
   = do
       mods <- P'.sepEndBy (P'.choice [parse'path, parse'unspent]) P'.spaces
       Prelude'.return (Prelude'.foldl (\ v f -> f v) P'.defaultValue mods)
    where
        parse'path
         = P'.try
            (do
               v <- P'.getT "path"
               Prelude'.return (\ o -> o{path = P'.append (path o) v}))
        parse'unspent
         = P'.try
            (do
               v <- P'.getT "unspent"
               Prelude'.return (\ o -> o{unspent = v}))