{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
module Network.Haskoin.Store.Common where

import           Control.Monad
import           Control.Monad.Reader
import           Control.Monad.Trans.Maybe
import           Data.ByteString           (ByteString)
import           Data.Default
import           Data.Serialize            (Serialize, decode, encode)
import           Database.RocksDB

class (Eq k, Eq v, Serialize k, Serialize v) =>
      Record k v | k -> v

class (Eq mk, Serialize mk, Record k v) =>
      MultiRecord mk k v | mk -> k

decodeMaybe :: Serialize a => ByteString -> Maybe a
decodeMaybe = either (const Nothing) Just . decode

retrieveValue ::
       (Record k v, MonadIO m) => k -> DB -> Maybe Snapshot -> m (Maybe v)
retrieveValue k db s = runMaybeT $ do
    bs <- MaybeT (get db def {useSnapshot = s} (encode k))
    MaybeT (return (decodeMaybe bs))

deleteKey :: (Record k v, MonadIO m) => k -> DB -> m ()
deleteKey k db = delete db def (encode k)

insertRecord :: (Record k v, MonadIO m) => k -> v -> DB -> m ()
insertRecord k v db = put db def (encode k) (encode v)

deleteOp :: Record k v => k -> BatchOp
deleteOp k = Del (encode k)

insertOp :: Record k v => k -> v -> BatchOp
insertOp k v = Put (encode k) (encode v)

valueFromIter ::
       (MultiRecord mk k v, MonadIO m)
    => mk
    -> Iterator
    -> m (Maybe (k, v))
valueFromIter mk it =
    runMaybeT $ do
        kbs <- MaybeT (iterKey it)
        mk' <- MaybeT (return (decodeMaybe kbs))
        guard (mk == mk')
        k <- MaybeT (return (decodeMaybe kbs))
        bs <- MaybeT (iterValue it)
        v <- MaybeT (return (decodeMaybe bs))
        return (k, v)

firstValue ::
       (MultiRecord mk k v, MonadIO m)
    => mk
    -> DB
    -> Maybe Snapshot
    -> m (Maybe (k, v))
firstValue mk db s =
    withIter db def {useSnapshot = s} $ \it -> do
        iterSeek it (encode mk)
        valueFromIter mk it

valuesForKey ::
       (MultiRecord mk k v, MonadIO m)
    => mk
    -> DB
    -> Maybe Snapshot
    -> m [(k, v)]
valuesForKey mk db s =
    withIter db def {useSnapshot = s} $ \it -> do
        iterSeek it (encode mk)
        reverse <$> go [] it
  where
    go acc it = do
        m <- valueFromIter mk it
        case m of
            Nothing -> return acc
            Just kv -> do
                iterNext it
                go (kv : acc) it
