{-# LANGUAGE ConstraintKinds  #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase       #-}
{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE TupleSections    #-}
module Network.Haskoin.Store.Mempool where

import           Control.Applicative
import           Control.Concurrent.NQE
import           Control.Monad
import           Control.Monad.Base
import           Control.Monad.Catch
import           Control.Monad.Except
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.Trans.Control
import           Control.Monad.Trans.Maybe
import           Data.List
import           Data.Map.Strict             (Map)
import qualified Data.Map.Strict             as Map
import           Data.Maybe
import           Data.Word
import           Database.RocksDB            (DB)
import           Network.Haskoin.Crypto
import           Network.Haskoin.Node
import           Network.Haskoin.Script
import           Network.Haskoin.Store.Block
import           Network.Haskoin.Store.Types
import           Network.Haskoin.Transaction

data Mempool = Mempool
    { getMempoolTxMap      :: !(Map TxHash DetailedTx)
    , getMempoolAddressMap :: !(Map Address [DetailedTx])
    , getMempoolSpentMap   :: !(Map OutPoint DetailedTx)
    , getOrphanTxs         :: ![Tx]
    }

data MempoolRead = MempoolRead
    { mempoolBox :: !(TVar Mempool)
    , blockDB    :: !DB
    , myManager    :: !Manager
    }

type MonadMempool m
     = ( MonadBase IO m
       , MonadThrow m
       , MonadBaseControl IO m
       , MonadLoggerIO m
       , MonadReader MempoolRead m)

getUnspentOut ::
       MonadMempool m
    => OutPoint
    -> ExceptT MempoolException m (Maybe Unspent)
getUnspentOut op =
    getUnspentFromMempool op >>= maybe (getUnspentFromDB op) (return . Just)

getUnspentFromTx ::
       Monad m
    => OutPoint
    -> DetailedTx
    -> ExceptT MempoolException m (Maybe Unspent)
getUnspentFromTx OutPoint {..} DetailedTx {..} = do
    unless
        (length detailedTxOutputs > fromIntegral outPointIndex)
        (throwError OutputNotFound)
    let DetailedOutput {..} = detailedTxOutputs !! fromIntegral outPointIndex
    when (isJust detOutSpender) (throwError DoubleSpend)
    return $
        Just
            Unspent
            { unspentAddress = scriptToAddressBS detOutScript
            , unspentPkScript = detOutScript
            , unspentTxId = outPointHash
            , unspentIndex = outPointIndex
            , unspentValue = detOutValue
            , unspentBlock = detailedTxBlock
            , unspentPos = detailedTxPos
            }

getUnspentFromMempool ::
       MonadMempool m => OutPoint -> ExceptT MempoolException m (Maybe Unspent)
getUnspentFromMempool op@OutPoint {..} = do
    mem <- asks mempoolBox >>= liftIO . readTVarIO
    let sm = getMempoolSpentMap mem
    when (isJust (Map.lookup op sm)) (throwError DoubleSpend)
    let tm = getMempoolTxMap mem
        mtx = Map.lookup outPointHash tm
    maybe (return Nothing) (getUnspentFromTx op) mtx

getUnspentFromDB ::
       MonadMempool m => OutPoint -> ExceptT MempoolException m (Maybe Unspent)
getUnspentFromDB op@OutPoint {..} = do
    db <- asks blockDB
    mtx <- getTx outPointHash db Nothing
    maybe (return Nothing) (getUnspentFromTx op) mtx

importTx :: MonadMempool m => Tx -> ExceptT MempoolException m ()
importTx tx = do
    mem <- asks mempoolBox >>= liftIO . readTVarIO
    let inmem = isJust (Map.lookup (txHash tx) (getMempoolTxMap mem))
    db <- asks blockDB
    indb <- isJust <$> getTx (txHash tx) db Nothing
    when (not inmem && not indb) $ do
        prevs <- catMaybes <$> mapM (getUnspentOut . prevOutput) (txIn tx)
        if length prevs < length (txIn tx)
            then importOrphan tx
            else go prevs
  where
    go prevs = do
        let funds = sum (map unspentValue prevs)
            expenses = sum (map outValue (txOut tx))
        when (expenses > funds) (throwError OverSpend)
        broadcastTx tx

importOrphan :: MonadMempool m => Tx -> m ()
importOrphan tx =
    asks mempoolBox >>= \mbox ->
        liftIO . atomically . modifyTVar mbox $ \m ->
            m {getOrphanTxs = nub (tx : getOrphanTxs m)}

broadcastTx tx :: MonadMempool m => Tx -> m ()
broadcastTx tx = do
    
