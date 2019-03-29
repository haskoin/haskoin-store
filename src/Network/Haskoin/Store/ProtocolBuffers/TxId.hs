{-# LANGUAGE BangPatterns, DeriveDataTypeable, DeriveGeneric, FlexibleInstances, MultiParamTypeClasses, OverloadedStrings #-}
{-# OPTIONS_GHC  -w #-}
module Network.Haskoin.Store.ProtocolBuffers.TxId (TxId(..)) where
import Prelude ((+), (/), (++), (.))
import qualified Prelude as Prelude'
import qualified Data.Typeable as Prelude'
import qualified GHC.Generics as Prelude'
import qualified Data.Data as Prelude'
import qualified Text.ProtocolBuffers.Header as P'

data TxId = TxId{txid :: !(P'.ByteString)}
            deriving (Prelude'.Show, Prelude'.Eq, Prelude'.Ord, Prelude'.Typeable, Prelude'.Data, Prelude'.Generic)

instance P'.Mergeable TxId where
  mergeAppend (TxId x'1) (TxId y'1) = TxId (P'.mergeAppend x'1 y'1)

instance P'.Default TxId where
  defaultValue = TxId P'.defaultValue

instance P'.Wire TxId where
  wireSize ft' self'@(TxId x'1)
   = case ft' of
       10 -> calc'Size
       11 -> P'.prependMessageSize calc'Size
       _ -> P'.wireSizeErr ft' self'
    where
        calc'Size = (P'.wireSizeReq 1 12 x'1)
  wirePutWithSize ft' self'@(TxId x'1)
   = case ft' of
       10 -> put'Fields
       11 -> put'FieldsSized
       _ -> P'.wirePutErr ft' self'
    where
        put'Fields = P'.sequencePutWithSize [P'.wirePutReqWithSize 2 12 x'1]
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
             2 -> Prelude'.fmap (\ !new'Field -> old'Self{txid = new'Field}) (P'.wireGet 12)
             _ -> let (field'Number, wire'Type) = P'.splitWireTag wire'Tag in P'.unknown field'Number wire'Type old'Self

instance P'.MessageAPI msg' (msg' -> TxId) TxId where
  getVal m' f' = f' m'

instance P'.GPB TxId

instance P'.ReflectDescriptor TxId where
  getMessageInfo _ = P'.GetMessageInfo (P'.fromDistinctAscList [2]) (P'.fromDistinctAscList [2])
  reflectDescriptorInfo _
   = Prelude'.read
      "DescriptorInfo {descName = ProtoName {protobufName = FIName \".ProtocolBuffers.TxId\", haskellPrefix = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule = [MName \"ProtocolBuffers\"], baseName = MName \"TxId\"}, descFilePath = [\"Network\",\"Haskoin\",\"Store\",\"ProtocolBuffers\",\"TxId.hs\"], isGroup = False, fields = fromList [FieldInfo {fieldName = ProtoFName {protobufName' = FIName \".ProtocolBuffers.TxId.txid\", haskellPrefix' = [MName \"Network\",MName \"Haskoin\",MName \"Store\"], parentModule' = [MName \"ProtocolBuffers\",MName \"TxId\"], baseName' = FName \"txid\", baseNamePrefix' = \"\"}, fieldNumber = FieldId {getFieldId = 0}, wireTag = WireTag {getWireTag = 2}, packedTag = Nothing, wireTagLength = 1, isPacked = False, isRequired = True, canRepeat = False, mightPack = False, typeCode = FieldType {getFieldType = 12}, typeName = Nothing, hsRawDefault = Nothing, hsDefault = Nothing}], descOneofs = fromList [], keys = fromList [], extRanges = [], knownKeys = fromList [], storeUnknown = False, lazyFields = False, makeLenses = False, jsonInstances = False}"

instance P'.TextType TxId where
  tellT = P'.tellSubMessage
  getT = P'.getSubMessage

instance P'.TextMsg TxId where
  textPut msg
   = do
       P'.tellT "txid" (txid msg)
  textGet
   = do
       mods <- P'.sepEndBy (P'.choice [parse'txid]) P'.spaces
       Prelude'.return (Prelude'.foldl (\ v f -> f v) P'.defaultValue mods)
    where
        parse'txid
         = P'.try
            (do
               v <- P'.getT "txid"
               Prelude'.return (\ o -> o{txid = v}))