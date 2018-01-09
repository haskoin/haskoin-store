{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
module Network.Haskoin.Store.Common where

import           Control.Monad
import           Control.Monad.Trans
import           Control.Monad.Trans.Maybe
import           Data.ByteString           (ByteString)
import           Data.Conduit
import           Data.Default
import           Data.Serialize            (Serialize, decode, encode)
import           Database.LevelDB

class (Eq k, Eq v, Serialize k, Serialize v) =>
      Record k v | k -> v

class (Eq mk, Serialize mk, Record k v) =>
      MultiRecord mk k v | mk -> k

decodeMaybe :: Serialize a => ByteString -> Maybe a
decodeMaybe = either (const Nothing) Just . decode

retrieveValue :: (Record k v, MonadResource m) => k -> DB -> m (Maybe v)
retrieveValue k db = runMaybeT $ do
    bs <- MaybeT (get db def (encode k))
    MaybeT (return (decodeMaybe bs))

deleteKey :: (Record k v, MonadResource m) => k -> DB -> m ()
deleteKey k db = delete db def (encode k)

insertRecord :: (Record k v, MonadResource m) => k -> v -> DB -> m ()
insertRecord k v db = put db def (encode k) (encode v)

deleteOp :: Record k v => k -> BatchOp
deleteOp k = Del (encode k)

insertOp :: Record k v => k -> v -> BatchOp
insertOp k v = Put (encode k) (encode v)

valuesForKey ::
       (MultiRecord mk k v, MonadResource m)
    => mk
    -> DB
    -> Source m (k, v)
valuesForKey mk db =
    void . runMaybeT . withIterator db def $ \it -> do
        iterSeek it (encode mk)
        go it
  where
    go it = forever $ do
        kbs <- MaybeT (iterKey it)
        mk' <- MaybeT (return (decodeMaybe kbs))
        guard (mk == mk')
        k <- MaybeT (return (decodeMaybe kbs))
        bs <- MaybeT (iterValue it)
        v <- MaybeT (return (decodeMaybe bs))
        lift (yield (k, v))
        iterNext it
