{-# LANGUAGE BangPatterns, DeriveDataTypeable, DeriveGeneric, FlexibleInstances, MultiParamTypeClasses, OverloadedStrings #-}
{-# OPTIONS_GHC  -w #-}
module Network.Haskoin.Store.ProtocolBuffers.Event.Type (Type(..)) where
import Prelude ((+), (/), (.))
import qualified Prelude as Prelude'
import qualified Data.Typeable as Prelude'
import qualified GHC.Generics as Prelude'
import qualified Data.Data as Prelude'
import qualified Text.ProtocolBuffers.Header as P'

data Type = TX
          | BLOCK
            deriving (Prelude'.Read, Prelude'.Show, Prelude'.Eq, Prelude'.Ord, Prelude'.Typeable, Prelude'.Data, Prelude'.Generic)

instance P'.Mergeable Type

instance Prelude'.Bounded Type where
  minBound = TX
  maxBound = BLOCK

instance P'.Default Type where
  defaultValue = TX

toMaybe'Enum :: Prelude'.Int -> P'.Maybe Type
toMaybe'Enum 0 = Prelude'.Just TX
toMaybe'Enum 1 = Prelude'.Just BLOCK
toMaybe'Enum _ = Prelude'.Nothing

instance Prelude'.Enum Type where
  fromEnum TX = 0
  fromEnum BLOCK = 1
  toEnum
   = P'.fromMaybe
      (Prelude'.error "hprotoc generated code: toEnum failure for type Network.Haskoin.Store.ProtocolBuffers.Event.Type")
      . toMaybe'Enum
  succ TX = BLOCK
  succ _ = Prelude'.error "hprotoc generated code: succ failure for type Network.Haskoin.Store.ProtocolBuffers.Event.Type"
  pred BLOCK = TX
  pred _ = Prelude'.error "hprotoc generated code: pred failure for type Network.Haskoin.Store.ProtocolBuffers.Event.Type"

instance P'.Wire Type where
  wireSize ft' enum = P'.wireSize ft' (Prelude'.fromEnum enum)
  wirePut ft' enum = P'.wirePut ft' (Prelude'.fromEnum enum)
  wireGet 14 = P'.wireGetEnum toMaybe'Enum
  wireGet ft' = P'.wireGetErr ft'
  wireGetPacked 14 = P'.wireGetPackedEnum toMaybe'Enum
  wireGetPacked ft' = P'.wireGetErr ft'

instance P'.GPB Type

instance P'.MessageAPI msg' (msg' -> Type) Type where
  getVal m' f' = f' m'

instance P'.ReflectEnum Type where
  reflectEnum = [(0, "TX", TX), (1, "BLOCK", BLOCK)]
  reflectEnumInfo _
   = P'.EnumInfo
      (P'.makePNF (P'.pack ".ProtocolBuffers.Event.Type") ["Network", "Haskoin", "Store"] ["ProtocolBuffers", "Event"] "Type")
      ["Network", "Haskoin", "Store", "ProtocolBuffers", "Event", "Type.hs"]
      [(0, "TX"), (1, "BLOCK")]
      Prelude'.False

instance P'.TextType Type where
  tellT = P'.tellShow
  getT = P'.getRead