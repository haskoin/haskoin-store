{-# LANGUAGE BangPatterns, DeriveDataTypeable, DeriveGeneric, FlexibleInstances, MultiParamTypeClasses, OverloadedStrings #-}
{-# OPTIONS_GHC  -w #-}
module Network.Haskoin.Store.ProtocolBuffers.Spender (Spender(..)) where
import Prelude ((+), (/), (++), (.))
import qualified Prelude as Prelude'
import qualified Data.Typeable as Prelude'
import qualified GHC.Generics as Prelude'
import qualified Data.Data as Prelude'
import qualified Text.ProtocolBuffers.Header as P'
import qualified Network.Haskoin.Store.ProtocolBuffers.TxId as ProtocolBuffers (TxId)

data Spender = Spender{txid :: !(ProtocolBuffers.TxId), input :: !(P'.Word32)}
               deriving (Prelude'.Show, Prelude'.Eq, Prelude'.Ord, Prelude'.Typeable, Prelude'.Data, Prelude'.Generic)

instance P'.Mergeable Spender where
  mergeAppend (Spender x'1 x'2) (Spender y'1 y'2) = Spender (P'.mergeAppend x'1 y'1) (P'.mergeAppend x'2 y'2)

instance P'.Default Spender where
  defaultValue = Spender P'.defaultValue P'.defaultValue

instance P'.Wire Spender where
  wireSize ft' self'@(Spender x'1 x'2)
   = case ft' of
       10 -> calc'Size
       11 -> P'.prependMessageSize calc'Size
       _ -> P'.wireSizeErr ft' self'
    where
        calc'Size = (P'.wireSizeReq 1 11 x'1 + P'.wireSizeReq 1 13 x'2)
  wirePutWithSize ft' self'@(Spender x'1 x'2)
   = case ft' of
       10 -> put'Fields
       11 -> put'FieldsSized
       _ -> P'.wirePutErr ft' self'
    where
        put'Fields = P'.sequencePutWithSize [P'.wirePutReqWithSize 2 11 x'1, P'.wirePutReqWithSize 8 13 x'2]
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
             8 -> Prelude'.fmap (\ !new'Field -> old'Self{input = new'Field}) (P'.wireGet 13)
             _ -> let (field'Number, wire'Type) = P'.splitWireTag wire'Tag in P'.unknown field'Number wire'Type old'Self

instance P'.MessageAPI msg' (msg' -> Spender) Spender where
  getVal m' f' = f' m'

instance P'.GPB Spender

instance P'.ReflectDescriptor Spender where
  getMessageInfo _ = P'.GetMessageInfo (P'.fromDistinctAscList [2, 8]) (P'.fromDistinctAscList [2, 8])
  reflectDescriptorInfo _
   = Prelude'.read
      "DescriptorInfo {descName = ProtoName {protobufName = FIName \".ProtocolBuffers.Spender\", haskellPrefix = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule = [MName \"ProtocolBuffers\"], baseName = MName \"Spender\"}, descFilePath = [\"Network\",\"Haskoin\",\"Store\",\"ProtocolBuffers\",\"Spender.hs\"], isGroup = False, fields = fromList [FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.Spender.txid\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"Spender\"], baseName' = FName \"txid\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 0}, wireTag = WireTag {getWireTag = 2}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 11}, typeName = Just (ProtoName {protobufName = FIName \".ProtocolBuffers.TxId\", haskellPrefix = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule = [MName \"ProtocolBuffers\"], baseName = MName \"TxId\"}), hsRawDefault = Nothing, hsDefault = Nothing},FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.Spender.input\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"Spender\"], baseName' = FName \"input\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 1}, wireTag = WireTag {getWireTag = 8}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 13}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing}], descOneofs = fromList [], keys = fromList [], extRanges = [], knownKeys = fromList [], storeUnknown = False, lazyFields = False, makeLenses = False, jsonInstances = False}"

instance P'.TextType Spender where
  tellT = P'.tellSubMessage
  getT = P'.getSubMessage

instance P'.TextMsg Spender where
  textPut msg
   = do
       P'.tellT "txid" (txid msg)
       P'.tellT "input" (input msg)
  textGet
   = do
       mods <- P'.sepEndBy (P'.choice [parse'txid, parse'input]) P'.spaces
       Prelude'.return (Prelude'.foldl (\ v f -> f v) P'.defaultValue mods)
    where
        parse'txid
         = P'.try
            (do
               v <- P'.getT "txid"
               Prelude'.return (\ o -> o{txid = v}))
        parse'input
         = P'.try
            (do
               v <- P'.getT "input"
               Prelude'.return (\ o -> o{input = v}))