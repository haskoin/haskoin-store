{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
module Haskoin.Store.Web
    ( -- * Web
      WebConfig (..)
    , Except (..)
    , WebLimits (..)
    , WebTimeouts (..)
    , runWeb
    ) where

import           Conduit                       ()
import           Control.Applicative           ((<|>))
import           Control.Monad                 (forever, when, (<=<))
import           Control.Monad.Logger
import           Control.Monad.Reader          (ReaderT, asks, local,
                                                runReaderT)
import           Control.Monad.Trans           (lift)
import           Control.Monad.Trans.Maybe     (MaybeT (..), runMaybeT)
import           Data.Aeson                    (Encoding, ToJSON (..))
import           Data.Aeson.Encoding           (encodingToLazyByteString, list)
import           Data.ByteString.Builder       (lazyByteString)
import qualified Data.ByteString.Lazy          as L
import qualified Data.ByteString.Lazy.Char8    as C
import           Data.Char                     (isSpace)
import           Data.Default                  (Default (..))
import           Data.Function                 ((&))
import           Data.List                     (nub)
import           Data.Maybe                    (catMaybes, fromMaybe, isJust,
                                                listToMaybe, mapMaybe)
import           Data.Proxy                    (Proxy (..))
import           Data.Serialize                as Serialize
import           Data.String.Conversions       (cs)
import           Data.Text                     (Text)
import qualified Data.Text.Encoding            as T
import           Data.Time.Clock               (NominalDiffTime, diffUTCTime,
                                                getCurrentTime)
import           Data.Time.Clock.System        (getSystemTime, systemSeconds)
import           Data.Version                  (showVersion)
import           Data.Word                     (Word32, Word64)
import           Database.RocksDB              (Property (..), getProperty)
import qualified Haskoin.Block                 as H
import           Haskoin.Constants
import           Haskoin.Network
import           Haskoin.Node                  (Chain, OnlinePeer (..),
                                                PeerManager, chainGetBest,
                                                managerGetPeers, sendMessage)
import           Haskoin.Store.Cache           (CacheT, evictFromCache,
                                                withCache)
import           Haskoin.Store.Common          (Limits (..), PubExcept (..),
                                                Start (..), StoreEvent (..),
                                                StoreRead (..), blockAtOrBefore,
                                                getTransaction)
import           Haskoin.Store.Data
import           Haskoin.Store.Database.Reader (DatabaseReader (..),
                                                DatabaseReaderT,
                                                withDatabaseReader)
import           Haskoin.Store.Manager         (Store (..))
import           Haskoin.Store.WebCommon
import           Haskoin.Transaction
import           Haskoin.Util
import           Network.HTTP.Types            (Status (..), status400,
                                                status403, status404, status500,
                                                status503)
import           Network.Wai                   (Middleware, Request (..),
                                                responseStatus)
import           NQE                           (Inbox, Publisher, receive,
                                                withSubscription)
import qualified Paths_haskoin_store           as P (version)
import           Text.Printf                   (printf)
import           UnliftIO                      (MonadIO, MonadUnliftIO,
                                                askRunInIO, liftIO, timeout)
import           Web.Scotty.Internal.Types     (ActionT)
import qualified Web.Scotty.Trans              as S

type WebT m = ActionT Except (ReaderT WebConfig m)

data WebLimits = WebLimits
    { maxLimitCount      :: !Word32
    , maxLimitFull       :: !Word32
    , maxLimitOffset     :: !Word32
    , maxLimitDefault    :: !Word32
    , maxLimitGap        :: !Word32
    , maxLimitInitialGap :: !Word32
    }
    deriving (Eq, Show)

instance Default WebLimits where
    def =
        WebLimits
            { maxLimitCount = 20000
            , maxLimitFull = 5000
            , maxLimitOffset = 50000
            , maxLimitDefault = 100
            , maxLimitGap = 32
            , maxLimitInitialGap = 20
            }

data WebConfig = WebConfig
    { webPort        :: !Int
    , webStore       :: !Store
    , webMaxLimits   :: !WebLimits
    , webReqLog      :: !Bool
    , webWebTimeouts :: !WebTimeouts
    }

data WebTimeouts = WebTimeouts
    { txTimeout    :: !Word64
    , blockTimeout :: !Word64
    }
    deriving (Eq, Show)

instance Default WebTimeouts where
    def = WebTimeouts {txTimeout = 300, blockTimeout = 7200}

instance (MonadUnliftIO m, MonadLoggerIO m) =>
         StoreRead (ReaderT WebConfig m) where
    getMaxGap = runInWebReader getMaxGap
    getInitialGap = runInWebReader getInitialGap
    getNetwork = runInWebReader getNetwork
    getBestBlock = runInWebReader getBestBlock
    getBlocksAtHeight height = runInWebReader (getBlocksAtHeight height)
    getBlock bh = runInWebReader (getBlock bh)
    getTxData th = runInWebReader (getTxData th)
    getSpender op = runInWebReader (getSpender op)
    getSpenders th = runInWebReader (getSpenders th)
    getUnspent op = runInWebReader (getUnspent op)
    getBalance a = runInWebReader (getBalance a)
    getBalances as = runInWebReader (getBalances as)
    getMempool = runInWebReader getMempool
    getAddressesTxs as = runInWebReader . getAddressesTxs as
    getAddressesUnspents as = runInWebReader . getAddressesUnspents as
    xPubBals = runInWebReader . xPubBals
    xPubSummary = runInWebReader . xPubSummary
    xPubUnspents xpub = runInWebReader . xPubUnspents xpub
    xPubTxs xpub = runInWebReader . xPubTxs xpub

instance (MonadUnliftIO m, MonadLoggerIO m) => StoreRead (WebT m) where
    getNetwork = lift getNetwork
    getBestBlock = lift getBestBlock
    getBlocksAtHeight = lift . getBlocksAtHeight
    getBlock = lift . getBlock
    getTxData = lift . getTxData
    getSpender = lift . getSpender
    getSpenders = lift . getSpenders
    getUnspent = lift . getUnspent
    getBalance = lift . getBalance
    getBalances = lift . getBalances
    getMempool = lift getMempool
    getAddressesTxs as = lift . getAddressesTxs as
    getAddressesUnspents as = lift . getAddressesUnspents as
    xPubBals = lift . xPubBals
    xPubSummary = lift . xPubSummary
    xPubUnspents xpub = lift . xPubUnspents xpub
    xPubTxs xpub = lift . xPubTxs xpub
    getMaxGap = lift getMaxGap
    getInitialGap = lift getInitialGap

-------------------
-- Path Handlers --
-------------------

runWeb :: (MonadUnliftIO m , MonadLoggerIO m) => WebConfig -> m ()
runWeb cfg@WebConfig {webPort = port, webReqLog = reqlog} = do
    reqLogger <- logIt
    runner <- askRunInIO
    S.scottyT port (runner . (`runReaderT` cfg)) $ do
        when reqlog $ S.middleware reqLogger
        S.defaultHandler defHandler
        handlePaths
        S.notFound $ S.raise ThingNotFound

defHandler :: Monad m => Except -> WebT m ()
defHandler e = do
    proto <- setupContentType
    case e of
        ThingNotFound -> S.status status404
        BadRequest    -> S.status status400
        UserError _   -> S.status status400
        StringError _ -> S.status status400
        ServerError   -> S.status status500
        BlockTooLarge -> S.status status403
    S.raw $ protoSerial proto toEncoding e

handlePaths ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => S.ScottyT Except (ReaderT WebConfig m) ()
handlePaths = do
    -- Block Paths
    path (GetBlock <$> paramLazy <*> paramDef) scottyBlock blockDataToEncoding
    path (GetBlocks <$> param <*> paramDef) scottyBlocks (list . blockDataToEncoding)
    path (GetBlockRaw <$> paramLazy) scottyBlockRaw (const toEncoding)
    path (GetBlockBest <$> paramDef) scottyBlockBest blockDataToEncoding
    path (GetBlockBestRaw & return) scottyBlockBestRaw (const toEncoding)
    path (GetBlockLatest <$> paramDef) scottyBlockLatest (list . blockDataToEncoding)
    path (GetBlockHeight <$> paramLazy <*> paramDef)
         scottyBlockHeight (list . blockDataToEncoding)
    path (GetBlockHeights <$> param <*> paramDef)
         scottyBlockHeights (list . blockDataToEncoding)
    path (GetBlockHeightRaw <$> paramLazy) scottyBlockHeightRaw (const toEncoding)
    path (GetBlockTime <$> paramLazy <*> paramDef) scottyBlockTime blockDataToEncoding
    path (GetBlockTimeRaw <$> paramLazy) scottyBlockTimeRaw (const toEncoding)
    -- Transaction Paths
    path (GetTx <$> paramLazy) scottyTx transactionToEncoding
    path (GetTxs <$> param) scottyTxs (list . transactionToEncoding)
    path (GetTxRaw <$> paramLazy) scottyTxRaw (const toEncoding)
    path (GetTxsRaw <$> param) scottyTxsRaw (const toEncoding)
    path (GetTxsBlock <$> paramLazy) scottyTxsBlock (list . transactionToEncoding)
    path (GetTxsBlockRaw <$> paramLazy) scottyTxsBlockRaw (const toEncoding)
    path (GetTxAfter <$> paramLazy <*> paramLazy) scottyTxAfter (const toEncoding)
    path (PostTx <$> parseBody) scottyPostTx (const toEncoding)
    path (GetMempool <$> paramOptional <*> parseOffset) scottyMempool (const toEncoding)
    -- Address Paths
    path (GetAddrTxs <$> paramLazy <*> parseLimits) scottyAddrTxs (const toEncoding)
    path (GetAddrsTxs <$> param <*> parseLimits) scottyAddrsTxs (const toEncoding)
    path (GetAddrTxsFull <$> paramLazy <*> parseLimits)
         scottyAddrTxsFull (list . transactionToEncoding)
    path (GetAddrsTxsFull <$> param <*> parseLimits)
         scottyAddrsTxsFull (list . transactionToEncoding)
    path (GetAddrBalance <$> paramLazy) scottyAddrBalance balanceToEncoding
    path (GetAddrsBalance <$> param) scottyAddrsBalance (list . balanceToEncoding)
    path (GetAddrUnspent <$> paramLazy <*> parseLimits)
         scottyAddrUnspent (list . unspentToEncoding)
    path (GetAddrsUnspent <$> param <*> parseLimits)
         scottyAddrsUnspent (list . unspentToEncoding)
    -- XPubs
    path (GetXPub <$> paramLazy <*> paramDef <*> paramDef)
         scottyXPub (const toEncoding)
    path (GetXPubTxs <$> paramLazy <*> paramDef <*> parseLimits <*> paramDef)
         scottyXPubTxs (const toEncoding)
    path (GetXPubTxsFull <$> paramLazy <*> paramDef <*> parseLimits <*> paramDef)
         scottyXPubTxsFull (list . transactionToEncoding)
    path (GetXPubBalances <$> paramLazy <*> paramDef <*> paramDef)
         scottyXPubBalances (list . xPubBalToEncoding)
    path (GetXPubUnspent <$> paramLazy <*> paramDef <*> parseLimits <*> paramDef)
         scottyXPubUnspent (list . xPubUnspentToEncoding)
    path (GetXPubEvict <$> paramLazy <*> paramDef)
         scottyXPubEvict (const toEncoding)
    -- Network
    path (GetPeers & return) scottyPeers (const toEncoding)
    path (GetHealth & return) scottyHealth (const toEncoding)
    S.get "/events" scottyEvents
    S.get "/dbstats" scottyDbStats

path ::
       (ApiResource a b, MonadIO m)
    => WebT m a
    -> (a -> WebT m b)
    -> (Network -> b -> Encoding)
    -> S.ScottyT Except (ReaderT WebConfig m) ()
path parser action encJson =
    S.addroute (resourceMethod proxy) (capturePath proxy) $ do
        setHeaders
        proto <- setupContentType
        net <- lift $ asks (storeNetwork . webStore)
        apiRes <- parser
        res <- action apiRes
        S.raw $ protoSerial proto (encJson net) res
  where
    toProxy :: WebT m a -> Proxy a
    toProxy = const Proxy
    proxy = toProxy parser

protoSerial :: Serialize a => Bool -> (a -> Encoding) -> a -> L.ByteString
protoSerial True _  = runPutLazy . put
protoSerial False f = encodingToLazyByteString . f

setHeaders :: (Monad m, S.ScottyError e) => ActionT e m ()
setHeaders = S.setHeader "Access-Control-Allow-Origin" "*"

setupContentType :: Monad m => ActionT Except m Bool
setupContentType = maybe goJson setType =<< S.header "accept"
  where
    setType "application/octet-stream" = goBinary
    setType _                          = goJson
    goBinary = do
        S.setHeader "Content-Type" "application/octet-stream"
        return True
    goJson = do
        S.setHeader "Content-Type" "application/json"
        return False

-- GET Block / GET Blocks --

scottyBlock ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetBlock -> WebT m BlockData
scottyBlock (GetBlock h (NoTx noTx)) =
    maybe (S.raise ThingNotFound) (return . pruneTx noTx) =<< getBlock h

scottyBlocks ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetBlocks -> WebT m [BlockData]
scottyBlocks (GetBlocks hs (NoTx noTx)) =
    (pruneTx noTx <$>) . catMaybes <$> mapM getBlock (nub hs)

pruneTx :: Bool -> BlockData -> BlockData
pruneTx False b = b
pruneTx True b  = b {blockDataTxs = take 1 (blockDataTxs b)}

-- GET BlockRaw --

scottyBlockRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockRaw
    -> WebT m (RawResult H.Block)
scottyBlockRaw (GetBlockRaw h) = RawResult <$> getRawBlock h

getRawBlock ::
       (MonadUnliftIO m, MonadLoggerIO m) => H.BlockHash -> WebT m H.Block
getRawBlock h = do
    b <- maybe (S.raise ThingNotFound) return =<< getBlock h
    refuseLargeBlock b
    toRawBlock b

toRawBlock :: (Monad m, StoreRead m) => BlockData -> m H.Block
toRawBlock b = do
    let ths = blockDataTxs b
    txs <- map transactionData . catMaybes <$> mapM getTransaction ths
    return H.Block {H.blockHeader = blockDataHeader b, H.blockTxns = txs}

refuseLargeBlock :: Monad m => BlockData -> WebT m ()
refuseLargeBlock BlockData {blockDataTxs = txs} = do
    WebLimits {maxLimitFull = f} <- lift $ asks webMaxLimits
    when (length txs > fromIntegral f) $ S.raise BlockTooLarge

-- GET BlockBest / BlockBestRaw --

scottyBlockBest ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetBlockBest -> WebT m BlockData
scottyBlockBest (GetBlockBest noTx) = do
    bestM <- getBestBlock
    maybe (S.raise ThingNotFound) (scottyBlock . (`GetBlock` noTx)) bestM

scottyBlockBestRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockBestRaw
    -> WebT m (RawResult H.Block)
scottyBlockBestRaw _ =
    RawResult <$> (maybe (S.raise ThingNotFound) getRawBlock =<< getBestBlock)

-- GET BlockLatest --

scottyBlockLatest ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockLatest
    -> WebT m [BlockData]
scottyBlockLatest (GetBlockLatest (NoTx noTx)) =
    maybe (S.raise ThingNotFound) (go [] <=< getBlock) =<< getBestBlock
  where
    go acc Nothing = return acc
    go acc (Just b)
        | blockDataHeight b <= 0 = return acc
        | length acc == 99 = return (b:acc)
        | otherwise = do
            let prev = H.prevBlock (blockDataHeader b)
            go (pruneTx noTx b : acc) =<< getBlock prev

-- GET BlockHeight / BlockHeights / BlockHeightRaw --

scottyBlockHeight ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetBlockHeight -> WebT m [BlockData]
scottyBlockHeight (GetBlockHeight h noTx) =
    scottyBlocks . (`GetBlocks` noTx) =<< getBlocksAtHeight (fromIntegral h)

scottyBlockHeights ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockHeights
    -> WebT m [BlockData]
scottyBlockHeights (GetBlockHeights (HeightsParam heights) noTx) = do
    bhs <- concat <$> mapM getBlocksAtHeight (fromIntegral <$> heights)
    scottyBlocks (GetBlocks bhs noTx)

scottyBlockHeightRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockHeightRaw
    -> WebT m (RawResultList H.Block)
scottyBlockHeightRaw (GetBlockHeightRaw h) =
    RawResultList <$> (mapM getRawBlock =<< getBlocksAtHeight (fromIntegral h))

-- GET BlockTime / BlockTimeRaw --

scottyBlockTime ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetBlockTime -> WebT m BlockData
scottyBlockTime (GetBlockTime (TimeParam t) (NoTx noTx)) =
    maybe (S.raise ThingNotFound) (return . pruneTx noTx) =<< blockAtOrBefore t

scottyBlockTimeRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockTimeRaw
    -> WebT m (RawResult H.Block)
scottyBlockTimeRaw (GetBlockTimeRaw (TimeParam t)) = do
    b <- maybe (S.raise ThingNotFound) return =<< blockAtOrBefore t
    refuseLargeBlock b
    RawResult <$> toRawBlock b

-- GET Transactions --

scottyTx :: (MonadUnliftIO m, MonadLoggerIO m) => GetTx -> WebT m Transaction
scottyTx (GetTx txid) =
    maybe (S.raise ThingNotFound) return =<< getTransaction txid

scottyTxs ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetTxs -> WebT m [Transaction]
scottyTxs (GetTxs txids) = catMaybes <$> mapM getTransaction (nub txids)

scottyTxRaw ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetTxRaw -> WebT m (RawResult Tx)
scottyTxRaw (GetTxRaw txid) = do
    tx <- maybe (S.raise ThingNotFound) return =<< getTransaction txid
    return $ RawResult $ transactionData tx

scottyTxsRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetTxsRaw
    -> WebT m (RawResultList Tx)
scottyTxsRaw (GetTxsRaw txids) = do
    txs <- catMaybes <$> mapM getTransaction (nub txids)
    return $ RawResultList $ transactionData <$> txs

scottyTxsBlock ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetTxsBlock -> WebT m [Transaction]
scottyTxsBlock (GetTxsBlock h) = do
    b <- maybe (S.raise ThingNotFound) return =<< getBlock h
    refuseLargeBlock b
    catMaybes <$> mapM getTransaction (blockDataTxs b)

scottyTxsBlockRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetTxsBlockRaw
    -> WebT m (RawResultList Tx)
scottyTxsBlockRaw (GetTxsBlockRaw h) =
    RawResultList . fmap transactionData <$> scottyTxsBlock (GetTxsBlock h)

-- GET TransactionAfterHeight --

scottyTxAfter ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetTxAfter
    -> WebT m (GenericResult (Maybe Bool))
scottyTxAfter (GetTxAfter txid height) =
    GenericResult <$> cbAfterHeight (fromIntegral height) txid

-- | Check if any of the ancestors of this transaction is a coinbase after the
-- specified height. Returns 'Nothing' if answer cannot be computed before
-- hitting limits.
cbAfterHeight ::
       (MonadIO m, StoreRead m)
    => H.BlockHeight
    -> TxHash
    -> m (Maybe Bool)
cbAfterHeight height begin =
    go (10000 :: Int) [begin] -- Depth first search
  where
    go 0 _ = return Nothing -- We searched too far. Return Nothing.
    go _ [] = return $ Just False -- Nothing left to search.
    go i (txid:xs) =
        getTransaction txid >>= \case
            Nothing -> return Nothing -- Error. Bail out.
            Just tx
                | cbCheck tx -> return $ Just True -- Stop everything. Return.
                | heightCheck tx -> go i xs -- Continue search sideways
                | otherwise -> do
                    let is = outPointHash . inputPoint <$> transactionInputs tx
                    -- We have to search down and search sideways
                    go (i - 1) is `returnOr` go i xs
    cbCheck tx =
        any isCoinbase (transactionInputs tx) &&
        blockRefHeight (transactionBlock tx) > height
    heightCheck tx =
        case transactionBlock tx of
            BlockRef thisHeight _ -> thisHeight <= height
            _                     -> False
    returnOr a b =
        a >>= \case
            Just True -> return $ Just True -- Bubble up this result
            _ -> b

-- POST Transaction --

scottyPostTx :: (MonadUnliftIO m, MonadLoggerIO m) => PostTx -> WebT m TxId
scottyPostTx (PostTx tx) = do
    net <- lift $ asks (storeNetwork . webStore)
    pub <- lift $ asks (storePublisher . webStore)
    mgr <- lift $ asks (storeManager . webStore)
    lift (publishTx net pub mgr tx) >>= \case
        Right () -> return $ TxId (txHash tx)
        Left e@(PubReject _) -> S.raise $ UserError $ show e
        _ -> S.raise ServerError

-- | Publish a new transaction to the network.
publishTx ::
       (MonadUnliftIO m, StoreRead m)
    => Network
    -> Publisher StoreEvent
    -> PeerManager
    -> Tx
    -> m (Either PubExcept ())
publishTx net pub mgr tx =
    withSubscription pub $ \s ->
        getTransaction (txHash tx) >>= \case
            Just _ -> return $ Right ()
            Nothing -> go s
  where
    go s =
        managerGetPeers mgr >>= \case
            [] -> return $ Left PubNoPeers
            OnlinePeer {onlinePeerMailbox = p}:_ -> do
                MTx tx `sendMessage` p
                let v =
                        if getSegWit net
                            then InvWitnessTx
                            else InvTx
                sendMessage
                    (MGetData (GetData [InvVector v (getTxHash (txHash tx))]))
                    p
                f p s
    t = 5 * 1000 * 1000
    f p s =
        liftIO (timeout t (g p s)) >>= \case
            Nothing -> return $ Left PubTimeout
            Just (Left e) -> return $ Left e
            Just (Right ()) -> return $ Right ()
    g p s =
        receive s >>= \case
            StoreTxReject p' h' c _
                | p == p' && h' == txHash tx -> return . Left $ PubReject c
            StorePeerDisconnected p' _
                | p == p' -> return $ Left PubPeerDisconnected
            StoreMempoolNew h'
                | h' == txHash tx -> return $ Right ()
            _ -> g p s

-- GET Mempool / Events --

scottyMempool ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetMempool -> WebT m [TxHash]
scottyMempool (GetMempool limitM (OffsetParam o)) = do
    wl <- lift $ asks webMaxLimits
    let l = validateLimit wl False limitM
    take (fromIntegral l) . drop (fromIntegral o) . map txRefHash <$> getMempool

scottyEvents :: MonadLoggerIO m => WebT m ()
scottyEvents = do
    setHeaders
    proto <- setupContentType
    pub <- lift $ asks (storePublisher . webStore)
    S.stream $ \io flush' ->
        withSubscription pub $ \sub ->
            forever $
            flush' >> receiveEvent sub >>= maybe (return ()) (io . serial proto)
  where
    serial proto e =
        lazyByteString $ protoSerial proto toEncoding e <> newLine proto
    newLine True  = mempty
    newLine False = "\n"

receiveEvent :: Inbox StoreEvent -> IO (Maybe Event)
receiveEvent sub = do
    se <- receive sub
    return $
        case se of
            StoreBestBlock b     -> Just (EventBlock b)
            StoreMempoolNew t    -> Just (EventTx t)
            StoreTxDeleted t     -> Just (EventTx t)
            StoreBlockReverted b -> Just (EventBlock b)
            _                    -> Nothing

-- GET Address Transactions --

scottyAddrTxs ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrTxs -> WebT m [TxRef]
scottyAddrTxs (GetAddrTxs addr pLimits) =
    getAddressTxs addr =<< paramToLimits False pLimits

scottyAddrsTxs ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrsTxs -> WebT m [TxRef]
scottyAddrsTxs (GetAddrsTxs addrs pLimits) = 
    getAddressesTxs addrs =<< paramToLimits False pLimits

scottyAddrTxsFull ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetAddrTxsFull
    -> WebT m [Transaction]
scottyAddrTxsFull (GetAddrTxsFull addr pLimits) = do
    txs <- getAddressTxs addr =<< paramToLimits True pLimits
    catMaybes <$> mapM (getTransaction . txRefHash) txs

scottyAddrsTxsFull ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrsTxsFull -> WebT m [Transaction]
scottyAddrsTxsFull (GetAddrsTxsFull addrs pLimits) = do
    txs <- getAddressesTxs addrs =<< paramToLimits True pLimits
    catMaybes <$> mapM (getTransaction . txRefHash) txs

scottyAddrBalance ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrBalance -> WebT m Balance
scottyAddrBalance (GetAddrBalance addr) = getBalance addr

scottyAddrsBalance ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrsBalance -> WebT m [Balance]
scottyAddrsBalance (GetAddrsBalance addrs) = getBalances addrs

scottyAddrUnspent ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrUnspent -> WebT m [Unspent]
scottyAddrUnspent (GetAddrUnspent addr pLimits) =
    getAddressUnspents addr =<< paramToLimits False pLimits

scottyAddrsUnspent ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrsUnspent -> WebT m [Unspent]
scottyAddrsUnspent (GetAddrsUnspent addrs pLimits) =
    getAddressesUnspents addrs =<< paramToLimits False pLimits

-- GET XPubs --

scottyXPub ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetXPub -> WebT m XPubSummary
scottyXPub (GetXPub xpub deriv (NoCache noCache)) =
    lift . runNoCache noCache $ xPubSummary $ XPubSpec xpub deriv

scottyXPubTxs ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetXPubTxs -> WebT m [TxRef]
scottyXPubTxs (GetXPubTxs xpub deriv pLimits (NoCache noCache)) = do
    limits <- paramToLimits False pLimits
    lift . runNoCache noCache $ xPubTxs (XPubSpec xpub deriv) limits

scottyXPubTxsFull ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetXPubTxsFull
    -> WebT m [Transaction]
scottyXPubTxsFull (GetXPubTxsFull xpub deriv pLimits n@(NoCache noCache)) = do
    refs <- scottyXPubTxs (GetXPubTxs xpub deriv pLimits n)
    txs <- lift . runNoCache noCache $ mapM (getTransaction . txRefHash) refs
    return $ catMaybes txs

scottyXPubBalances ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetXPubBalances -> WebT m [XPubBal]
scottyXPubBalances (GetXPubBalances xpub deriv (NoCache noCache)) =
    filter f <$> lift (runNoCache noCache (xPubBals spec))
  where
    spec = XPubSpec xpub deriv
    f = not . nullBalance . xPubBal

scottyXPubUnspent ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetXPubUnspent
    -> WebT m [XPubUnspent]
scottyXPubUnspent (GetXPubUnspent xpub deriv pLimits (NoCache noCache)) = do
    limits <- paramToLimits False pLimits
    lift . runNoCache noCache $ xPubUnspents (XPubSpec xpub deriv) limits

scottyXPubEvict ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetXPubEvict
    -> WebT m (GenericResult Bool)
scottyXPubEvict (GetXPubEvict xpub deriv) = do
    cache <- lift $ asks (storeCache . webStore)
    lift . withCache cache $ evictFromCache [XPubSpec xpub deriv]
    return $ GenericResult True

-- GET Network Information --

scottyPeers :: MonadLoggerIO m => GetPeers -> WebT m [PeerInformation]
scottyPeers _ = getPeersInformation =<< lift (asks (storeManager . webStore))

-- | Obtain information about connected peers from peer manager process.
getPeersInformation :: MonadIO m => PeerManager -> m [PeerInformation]
getPeersInformation mgr = mapMaybe toInfo <$> managerGetPeers mgr
  where
    toInfo op = do
        ver <- onlinePeerVersion op
        let as = onlinePeerAddress op
            ua = getVarString $ userAgent ver
            vs = version ver
            sv = services ver
            rl = relay ver
        return
            PeerInformation
                { peerUserAgent = ua
                , peerAddress = show as
                , peerVersion = vs
                , peerServices = sv
                , peerRelay = rl
                }

scottyHealth ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetHealth -> WebT m HealthCheck
scottyHealth _ = do
    net <- lift $ asks (storeNetwork . webStore)
    mgr <- lift $ asks (storeManager . webStore)
    chn <- lift $ asks (storeChain . webStore)
    tos <- lift $ asks webWebTimeouts
    h <- lift $ healthCheck net mgr chn tos
    when (not (healthOK h) || not (healthSynced h)) $ S.status status503
    return h

healthCheck ::
       (MonadUnliftIO m, StoreRead m)
    => Network
    -> PeerManager
    -> Chain
    -> WebTimeouts
    -> m HealthCheck
healthCheck net mgr ch tos = do
    cb <- chain_best
    bb <- block_best
    pc <- peer_count
    tm <- get_current_time
    ml <- get_mempool_last
    let ck = block_ok cb
        bk = block_ok bb
        pk = peer_count_ok pc
        bd = block_time_delta tm cb
        td = tx_time_delta tm bd ml
        lk = timeout_ok (blockTimeout tos) bd
        tk = timeout_ok (txTimeout tos) td
        sy = in_sync bb cb
        ok = ck && bk && pk && lk && (tk || not sy)
    return
        HealthCheck
            { healthBlockBest = block_hash <$> bb
            , healthBlockHeight = block_height <$> bb
            , healthHeaderBest = node_hash <$> cb
            , healthHeaderHeight = node_height <$> cb
            , healthPeers = pc
            , healthNetwork = getNetworkName net
            , healthOK = ok
            , healthSynced = sy
            , healthLastBlock = bd
            , healthLastTx = td
            , healthVersion = showVersion P.version
            }
  where
    block_hash = H.headerHash . blockDataHeader
    block_height = blockDataHeight
    node_hash = H.headerHash . H.nodeHeader
    node_height = H.nodeHeight
    get_mempool_last = listToMaybe <$> getMempool
    get_current_time = fromIntegral . systemSeconds <$> liftIO getSystemTime
    peer_count_ok pc = fromMaybe 0 pc > 0
    block_ok = isJust
    node_timestamp = fromIntegral . H.blockTimestamp . H.nodeHeader
    in_sync bb cb = fromMaybe False $ do
        bh <- blockDataHeight <$> bb
        nh <- H.nodeHeight <$> cb
        return $ compute_delta bh nh <= 1
    block_time_delta tm cb = do
        bt <- node_timestamp <$> cb
        return $ compute_delta bt tm
    tx_time_delta tm bd ml = do
        bd' <- bd
        tt <- memRefTime . txRefBlock <$> ml <|> bd
        return $ min (compute_delta tt tm) bd'
    timeout_ok to td = fromMaybe False $ do
        td' <- td
        return $
          getAllowMinDifficultyBlocks net ||
          to == 0 ||
          td' <= to
    peer_count = fmap length <$> timeout 10000000 (managerGetPeers mgr)
    block_best = runMaybeT $ do
        h <- MaybeT getBestBlock
        MaybeT $ getBlock h
    chain_best = timeout 10000000 $ chainGetBest ch
    compute_delta a b = if b > a then b - a else 0

scottyDbStats :: MonadLoggerIO m => WebT m ()
scottyDbStats = do
    setHeaders
    db <- lift $ asks (databaseHandle . storeDB . webStore)
    statsM <- lift (getProperty db Stats)
    S.text $ maybe "Could not get stats" cs statsM

-----------------------
-- Parameter Parsing --
-----------------------

-- | Returns @Nothing@ if the parameter is not supplied. Raises an exception on
-- parse failure.
paramOptional :: (Param a, Monad m) => WebT m (Maybe a)
paramOptional = go Proxy
  where
    go :: (Param a, Monad m) => Proxy a -> WebT m (Maybe a)
    go proxy = do
        net <- lift $ asks (storeNetwork . webStore)
        tsM :: Maybe [Text] <- p `S.rescue` const (return Nothing)
        case tsM of
            Nothing -> return Nothing -- Parameter was not supplied
            Just ts -> maybe (S.raise err) (return . Just) $ parseParam net ts
      where
        l = proxyLabel proxy
        p = Just <$> S.param (cs l)
        err = UserError $ "Unable to parse param " <> cs l

-- | Raises an exception if the parameter is not supplied
param :: (Param a, Monad m) => WebT m a
param = go Proxy
  where
    go :: (Param a, Monad m) => Proxy a -> WebT m a
    go proxy = do
        resM <- paramOptional
        case resM of
            Just res -> return res
            _ ->
                S.raise . UserError $
                "The param " <> cs (proxyLabel proxy) <> " was not defined"

-- | Returns the default value of a parameter if it is not supplied. Raises an
-- exception on parse failure.
paramDef :: (Default a, Param a, Monad m) => WebT m a
paramDef = fromMaybe def <$> paramOptional

-- | Does not raise exceptions. Will call @Scotty.next@ if the parameter is
-- not supplied or if parsing fails.
paramLazy :: (Param a, Monad m) => WebT m a
paramLazy = do
    resM <- paramOptional `S.rescue` const (return Nothing)
    maybe S.next return resM

parseBody :: (MonadIO m, Serialize a) => WebT m a
parseBody = do
    b <- S.body
    case hex b <|> bin (L.toStrict b) of
        Nothing -> S.raise $ UserError "Failed to parse request body"
        Just x  -> return x
  where
    bin = eitherToMaybe . Serialize.decode
    hex = bin <=< decodeHex . cs . C.filter (not . isSpace)

parseOffset :: Monad m => WebT m OffsetParam
parseOffset = do
    res@(OffsetParam o) <- paramDef
    limits <- lift $ asks webMaxLimits
    when (maxLimitOffset limits > 0 && fromIntegral o > maxLimitOffset limits) $
        S.raise . UserError $
        "offset exceeded: " <> show o <> " > " <> show (maxLimitOffset limits)
    return res

parseStart ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Maybe StartParam
    -> WebT m (Maybe Start)
parseStart Nothing = return Nothing
parseStart (Just s) =
    runMaybeT $
    case s of
        StartParamHash {startParamHash = h}     -> start_tx h <|> start_block h
        StartParamHeight {startParamHeight = h} -> start_height h
        StartParamTime {startParamTime = q}     -> start_time q
  where
    start_height h = return $ AtBlock $ fromIntegral h
    start_block h = do
        b <- MaybeT $ getBlock (H.BlockHash h)
        return $ AtBlock (blockDataHeight b)
    start_tx h = do
        _ <- MaybeT $ getTxData (TxHash h)
        return $ AtTx (TxHash h)
    start_time q = do
        b <- MaybeT $ blockAtOrBefore q
        let g = blockDataHeight b
        return $ AtBlock g

parseLimits :: Monad m => WebT m LimitsParam
parseLimits = LimitsParam <$> paramOptional <*> parseOffset <*> paramOptional

paramToLimits ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Bool
    -> LimitsParam
    -> WebT m Limits
paramToLimits full (LimitsParam limitM o startM) = do
    wl <- lift $ asks webMaxLimits
    Limits (validateLimit wl full limitM) (fromIntegral o) <$> parseStart startM

validateLimit :: WebLimits -> Bool -> Maybe LimitParam -> Word32
validateLimit wl full limitM =
    f m $ maybe d (fromIntegral . getLimitParam) limitM
  where
    m | full && maxLimitFull wl > 0 = maxLimitFull wl
      | otherwise = maxLimitCount wl
    d = maxLimitDefault wl
    f a 0 = a
    f 0 b = b
    f a b = min a b

---------------
-- Utilities --
---------------

runInWebReader ::
       MonadIO m
    => CacheT (DatabaseReaderT m) a
    -> ReaderT WebConfig m a
runInWebReader f = do
    bdb <- asks (storeDB . webStore)
    mc <- asks (storeCache . webStore)
    lift $ withDatabaseReader bdb (withCache mc f)

runNoCache :: MonadIO m => Bool -> ReaderT WebConfig m a -> ReaderT WebConfig m a
runNoCache False f = f
runNoCache True f =
    local (\s -> s {webStore = (webStore s) {storeCache = Nothing}}) f

logIt :: (MonadUnliftIO m, MonadLoggerIO m) => m Middleware
logIt = do
    runner <- askRunInIO
    return $ \app req respond -> do
        t1 <- getCurrentTime
        app req $ \res -> do
            t2 <- getCurrentTime
            let d = diffUTCTime t2 t1
                s = responseStatus res
            runner $
                $(logInfoS) "Web" $
                fmtReq req <> " [" <> fmtStatus s <> " / " <> fmtDiff d <> "]"
            respond res

fmtReq :: Request -> Text
fmtReq req =
    let m = requestMethod req
        v = httpVersion req
        p = rawPathInfo req
        q = rawQueryString req
     in T.decodeUtf8 $ m <> " " <> p <> q <> " " <> cs (show v)

fmtDiff :: NominalDiffTime -> Text
fmtDiff d =
    cs (printf "%0.3f" (realToFrac (d * 1000) :: Double) :: String) <> " ms"

fmtStatus :: Status -> Text
fmtStatus s = cs (show (statusCode s)) <> " " <> cs (statusMessage s)

