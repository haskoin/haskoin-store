{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeFamilies          #-}
module Network.Haskoin.Node.Peer
( peer
) where

import           Control.Concurrent.NQE
import           Control.Exception.Lifted
import           Control.Monad
import           Control.Monad.Base
import           Control.Monad.IO.Class
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.Trans.Control
import           Data.ByteString             (ByteString)
import qualified Data.ByteString             as BS
import qualified Data.ByteString.Lazy        as BL
import           Data.Conduit
import qualified Data.Conduit.Binary         as CB
import           Data.Conduit.Network
import           Data.Maybe
import           Data.Serialize
import           Data.String.Conversions
import           Data.Text                   (Text)
import           Data.Time.Clock
import           Data.Word
import           Network.Haskoin.Block
import           Network.Haskoin.Network
import           Network.Haskoin.Node.Common
import           Network.Haskoin.Transaction
import           System.Random

type MonadPeer m = (MonadBase IO m, MonadLoggerIO m, MonadReader PeerReader m)

data Pending
    = PendingTx !TxHash
    | PendingBlock !BlockHash
    | PendingMerkle !BlockHash
    | PendingHeaders
    deriving (Show, Eq)

data PeerReader = PeerReader
    { mySelf     :: !Peer
    , myConfig   :: !PeerConfig
    , myHostPort :: !(Host, Port)
    , myPending  :: !(TVar [(Pending, Word32)])
    }

time :: Int
time = 15 * 1000 * 1000

logMsg :: Message -> Text
logMsg = cs . msgType

logPeer :: HostPort -> Text
logPeer (host, port) = "[" <> cs host <> ":" <> cs (show port) <> "] "

peer ::
       (MonadBaseControl IO m, MonadLoggerIO m, Forall (Pure m))
    => PeerConfig
    -> Peer
    -> m ()
peer pc p =
    fromSockAddr (naAddress $ peerConfConnect pc) >>= \case
        Nothing -> do
            $(logError) $ "[Peer] Address invalid"
            throwIO PeerAddressInvalid
        Just (host, port) -> do
            $(logInfo) $ logPeer (host, port) <> "Establishing TCP connection"
            let cset = clientSettings port (cs host)
            runGeneralTCPClient cset (peerSession (host, port))
  where
    go = handshake >> exchangePing >> peerLoop
    peerSession hp ad = do
        let src = appSource ad =$= inPeerConduit
            snk = outPeerConduit =$= appSink ad
        withSource src p . const $ do
            pbox <- liftIO $ newTVarIO []
            let rd =
                    PeerReader
                    { myConfig = pc
                    , mySelf = p
                    , myHostPort = hp
                    , myPending = pbox
                    }
            runReaderT (go $$ snk) rd

handshake :: MonadPeer m => Source m Message
handshake = do
    lp <- logMe
    $(logDebug) $ lp <> "Initiating handshake"
    p <- asks mySelf
    ch <- peerConfChain <$> asks myConfig
    rmt <- peerConfConnect <$> asks myConfig
    loc <- peerConfLocal <$> asks myConfig
    nonce <- peerConfNonce <$> asks myConfig
    bb <- chainGetBest ch
    ver <- buildVersion nonce (nodeHeight bb) loc rmt
    $(logDebug) $ lp <> "Sending our version"
    yield $ MVersion ver
    v <- liftIO $ remoteVer p
    $(logDebug) $
        lp <> "Got peer version: " <> logShow (getVarString (userAgent v))
    yield MVerAck
    $(logDebug) $ lp <> "Waiting for verack"
    remoteVerAck p
    mgr <- peerConfManager <$> asks myConfig
    $(logDebug) $ lp <> "Handshake complete"
    managerSetPeerVersion p v mgr
  where
    remoteVer p = do
        m <-
            timeout time . receiveMatch p $ \case
                PeerIncoming (MVersion v) -> Just v
                _ -> Nothing
        case m of
            Just v  -> return v
            Nothing -> throwIO PeerTimeout
    remoteVerAck p = do
        m <-
            liftIO . timeout time . receiveMatch p $ \case
                PeerIncoming MVerAck -> Just ()
                _ -> Nothing
        when (isNothing m) $ throwIO PeerTimeout

peerLoop :: MonadPeer m => Source m Message
peerLoop =
    forever $ do
        me <- asks mySelf
        lp <- logMe
        $(logDebug) $ lp <> "Awaiting message"
        m <- liftIO $ timeout (2 * 60 * 1000 * 1000) (receive me)
        case m of
            Nothing  -> exchangePing
            Just msg -> processMessage msg

exchangePing :: MonadPeer m => Source m Message
exchangePing = do
    lp <- logMe
    i <- liftIO randomIO
    $(logDebug) $ lp <> "Sending ping"
    yield $ MPing (Ping i)
    me <- asks mySelf
    mgr <- peerConfManager <$> asks myConfig
    t1 <- liftIO getCurrentTime
    $(logDebug) $ lp <> "Awaiting response"
    m <-
        liftIO . timeout time . receiveMatch me $ \case
            PeerIncoming (MPong (Pong j))
                | i == j -> Just ()
            _ -> Nothing
    case m of
        Nothing -> do
            $(logError) $ lp <> "Timeout while waiting for pong"
            throwIO PeerTimeout
        Just () -> do
            t2 <- liftIO getCurrentTime
            let d = t2 `diffUTCTime` t1
            $(logDebug) $
                lp <> "Roundtrip time: " <> logShow (d * 1000) <> " ms"
            ManagerPeerPing me d `send` mgr

checkStale :: MonadPeer m => ConduitM () Message m ()
checkStale = do
    lp <- logMe
    $(logDebug) $ lp <> "Checking if this peer is stale"
    pbox <- asks myPending
    ps <- liftIO $ readTVarIO pbox
    case ps of
        [] -> return ()
        (_, ts):_ -> do
            cur <- computeTime
            when (cur > ts + 30) $ throwIO PeerTimeout

registerOutgoing :: MonadPeer m => Message -> m ()
registerOutgoing (MGetData (GetData ivs)) = do
    pbox <- asks myPending
    cur <- computeTime
    ms <-
        fmap catMaybes . forM ivs $ \iv ->
            case toPending iv of
                Nothing -> return Nothing
                Just p  -> return $ Just (p, cur)
    liftIO . atomically $ modifyTVar pbox (++ ms)
  where
    toPending InvVector {invType = InvTx, invHash = hash} =
        Just (PendingTx (TxHash hash))
    toPending InvVector {invType = InvBlock, invHash = hash} =
        Just (PendingBlock (BlockHash hash))
    toPending InvVector {invType = InvMerkleBlock, invHash = hash} =
        Just (PendingMerkle (BlockHash hash))
    toPending _ = Nothing
registerOutgoing MGetHeaders {} = do
    pbox <- asks myPending
    cur <- computeTime
    liftIO . atomically $
        modifyTVar pbox (reverse . ((PendingHeaders, cur) :) . reverse)
registerOutgoing _ = return ()

registerIncoming :: MonadPeer m => Message -> m ()
registerIncoming (MNotFound (NotFound ivs)) = do
    pbox <- asks myPending
    liftIO . atomically $ modifyTVar pbox (filter (matchNotFound . fst))
  where
    matchNotFound (PendingTx (TxHash hash)) = InvVector InvTx hash `notElem` ivs
    matchNotFound (PendingBlock (BlockHash hash)) =
        InvVector InvBlock hash `notElem` ivs
    matchNotFound (PendingMerkle (BlockHash hash)) =
        InvVector InvBlock hash `notElem` ivs &&
        InvVector InvMerkleBlock hash `notElem` ivs
    matchNotFound _ = False
registerIncoming (MTx t) = do
    pbox <- asks myPending
    liftIO . atomically $
        modifyTVar pbox (filter ((/= PendingTx (txHash t)) . fst))
registerIncoming (MBlock b) = do
    pbox <- asks myPending
    liftIO . atomically $
        modifyTVar
            pbox
            (filter ((/= PendingBlock (headerHash (blockHeader b))) . fst))
registerIncoming (MMerkleBlock b) = do
    pbox <- asks myPending
    liftIO . atomically $
        modifyTVar
            pbox
            (filter ((/= PendingMerkle (headerHash (merkleHeader b))) . fst))
registerIncoming MHeaders {} = do
    pbox <- asks myPending
    liftIO . atomically $ modifyTVar pbox (filter ((/= PendingHeaders) . fst))
registerIncoming _ = return ()

processMessage :: MonadPeer m => PeerMessage -> ConduitM () Message m ()
processMessage m = do
    lp <- logMe
    checkStale
    case m of
        PeerOutgoing msg -> do
            $(logDebug) $ lp <> "Sending " <> logMsg msg
            registerOutgoing msg
            yield msg
        PeerIncoming msg -> do
            $(logDebug) $ lp <> "Received " <> logMsg msg
            registerIncoming msg
            incoming msg

logMe :: MonadPeer m => m Text
logMe = logPeer <$> asks myHostPort

incoming :: MonadPeer m => Message -> Source m Message
incoming m = do
    lp <- lift logMe
    p <- asks mySelf
    l <- peerConfListener <$> asks myConfig
    mgr <- peerConfManager <$> asks myConfig
    ch <- peerConfChain <$> asks myConfig
    case m of
        MVersion _ -> do
            $(logError) $ lp <> "Received duplicate " <> logMsg m
            yield $
                MReject
                    Reject
                    { rejectMessage = MCVersion
                    , rejectCode = RejectDuplicate
                    , rejectReason = VarString BS.empty
                    , rejectData = BS.empty
                    }
        MPing (Ping n) -> do
            $(logDebug) $ lp <> "Responding to " <> logMsg m
            yield $ MPong (Pong n)
        MSendHeaders {} -> do
            $(logDebug) $ lp <> "Relaying sendheaders to chain actor"
            ChainSendHeaders p `send` ch
        MAlert {} -> $(logInfo) $ lp <> "Deprecated " <> logMsg m
        MAddr (Addr as) -> do
            $(logDebug) $ lp <> "Sending addresses to peer manager"
            managerNewPeers p as mgr
        MInv (Inv is) -> do
            let ts = [TxHash (invHash i) | i <- is, invType i == InvTx]
            unless (null ts) $ do
                $(logDebug) $ lp <> "Relaying transaction inventory"
                liftIO . atomically . forM_ ts $ l . (,) p . TxAvail
        MTx tx -> do
            $(logDebug) $ lp <> "Relaying transaction " <> logShow (txHash tx)
            liftIO . atomically $ l (p, GotTx tx)
        MBlock b -> do
            $(logDebug) $
                lp <> "Relaying block " <> logShow (headerHash $ blockHeader b)
            liftIO . atomically $ l (p, GotBlock b)
        MMerkleBlock b -> do
            $(logDebug) $
                lp <> "Relaying Merkle block " <>
                logShow (headerHash $ merkleHeader b)
            liftIO . atomically $ l (p, GotMerkleBlock b)
        MHeaders (Headers hcs) -> do
            $(logDebug) $ lp <> "Sending new headers to chain actor"
            ChainNewHeaders p hcs `send` ch
        MGetData (GetData d) -> do
            $(logDebug) $ lp <> "Relaying getdata message"
            liftIO . atomically $ l (p, SendData d)
        MNotFound (NotFound ns) -> do
            $(logDebug) $ lp <> "Relaying notfound message"
            let f (InvVector InvTx hash) = Just (TxNotFound (TxHash hash))
                f (InvVector InvBlock hash) =
                    Just (BlockNotFound (BlockHash hash))
                f (InvVector InvMerkleBlock hash) =
                    Just (BlockNotFound (BlockHash hash))
                f _ = Nothing
                events = mapMaybe f ns
            liftIO . atomically $ mapM_ (l . (p, )) events
        MGetBlocks g -> do
            $(logDebug) $ lp <> "Relaying getblocks message"
            liftIO . atomically $ l (p, SendBlocks g)
        MGetHeaders h -> do
            $(logDebug) $ lp <> "Relaying getheaders message"
            liftIO . atomically $ l (p, SendHeaders h)
        MReject r -> do
            $(logDebug) $ lp <> "Relaying rejection message"
            liftIO . atomically $ l (p, Rejected r)
        MMempool -> do
            $(logDebug) $ lp <> "Relaying mempool message"
            liftIO . atomically $ l (p, WantMempool)
        MGetAddr -> do
            $(logDebug) $ lp <> "Asking manager for peers"
            managerGetAddr p mgr
        _ -> $(logInfo) $ lp <> "Ignoring received " <> logMsg m

inPeerConduit :: Monad m => Conduit ByteString m PeerMessage
inPeerConduit = do
    headerBytes <- CB.take 24
    when (BL.null headerBytes) $ throw MessageHeaderEmpty
    case decodeLazy headerBytes of
        Left e -> throw $ DecodeMessageError e
        Right (MessageHeader _ _cmd len _) -> do
            when (len > 32 * 2 ^ (20 :: Int)) . throw $ PayloadTooLarge len
            payloadBytes <- CB.take (fromIntegral len)
            case decodeLazy $ headerBytes `BL.append` payloadBytes of
                Left e    -> throw $ CannotDecodePayload e
                Right msg -> yield $ PeerIncoming msg
            inPeerConduit

outPeerConduit :: Monad m => Conduit Message m ByteString
outPeerConduit = awaitForever $ yield . encode

