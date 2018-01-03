{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}
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
import           Data.List
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

data PeerReader = PeerReader
    { mySelf     :: !Peer
    , myConfig   :: !PeerConfig
    , myHostPort :: !(Host, Port)
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
        withSource src p . const $
            let rd = PeerReader {myConfig = pc, mySelf = p, myHostPort = hp}
            in runReaderT (go $$ snk) rd

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
    $(logDebug) $ lp <> "Waiting for peer version acknowledgement"
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
            $(logError) $ lp <> "Timeout while awaiting for pong"
            throwIO PeerTimeout
        Just () -> do
            t2 <- liftIO getCurrentTime
            let d = diffUTCTime t1 t2
            $(logDebug) $
                lp <> "Roundtrip time (milliseconds): " <> logShow (d * 1000)
            ManagerPeerPing me d `send` mgr

processMessage :: MonadPeer m => PeerMessage -> ConduitM () Message m ()
processMessage m = do
    lp <- logMe
    case m of
        PeerOutgoing msg -> do
            $(logDebug) $ lp <> "Sending " <> logMsg msg
            yield msg
        PeerIncoming msg -> do
            $(logDebug) $ lp <> "Received " <> logMsg msg
            incoming msg
        PeerMerkleBlocks bhs l -> do
            $(logDebug) $ lp <> "Downloading Merkle blocks"
            downloadMerkleBlocks bhs l
        PeerBlocks bhs l -> do
            $(logDebug) $ lp <> "Downloading blocks"
            downloadBlocks bhs l
        PeerTxs ths l -> do
            $(logDebug) $ lp <> "Downloading transactions"
            downloadTxs ths l

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
                liftIO . atomically . l $ ReceivedInvTxs p ts
        MTx t -> do
            $(logDebug) $ lp <> "Relaying transaction " <> logShow (txHash t)
            liftIO . atomically . l $ ReceivedTx p t
        MHeaders (Headers hcs) -> do
            $(logDebug) $ lp <> "Sending new headers to chain actor"
            ChainNewHeaders p hcs `send` ch
        MGetData (GetData d) -> do
            $(logDebug) $ lp <> "Relaying getdata message"
            liftIO . atomically . l $ ReceivedGetData p d
        MGetBlocks g -> do
            $(logDebug) $ lp <> "Relaying getblocks message"
            liftIO . atomically . l $ ReceivedGetBlocks p g
        MGetHeaders h -> do
            $(logDebug) $ lp <> "Relaying getheaders message"
            liftIO . atomically . l $ ReceivedGetHeaders p h
        MReject r -> do
            $(logDebug) $ lp <> "Relaying rejection message"
            liftIO . atomically . l $ ReceivedReject p r
        MMempool -> do
            $(logDebug) $ lp <> "Relaying mempool message"
            liftIO . atomically . l $ ReceivedMempool p
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

downloadTxs ::
       MonadPeer m
    => [TxHash]
    -> Listen (Maybe (Either TxHash Tx))
    -> Source m Message
downloadTxs ths l = do
    lp <- logMe
    let ivs = map (InvVector InvTx . getTxHash) ths
        msg = MGetData (GetData ivs)
    $(logDebug) $ lp <> "Sending getdata for transactions"
    yield msg
    lift $ do
        receiveTxs ths l
        liftIO . atomically $ l Nothing

receiveTxs ::
       MonadPeer m => [TxHash] -> Listen (Maybe (Either TxHash Tx)) -> m ()
receiveTxs ths l = go ths
  where
    go [] = return ()
    go hs = do
        lp <- logMe
        $(logDebug) $ lp <> "Waiting to receive a transaction"
        p <- asks mySelf
        eM <-
            liftIO . timeout time . receiveMatch p $ \case
                PeerIncoming (MTx tx) -> do
                    let th = txHash tx
                    guard (th `elem` hs)
                    return $ Right tx
                PeerIncoming (MNotFound (NotFound nf)) -> do
                    let ths' =
                            [ th
                            | x <- nf
                            , invType x == InvTx
                            , let th = TxHash (invHash x)
                            , th `elem` hs
                            ]
                    guard (not (null ths'))
                    return $ Left ths'
                _ -> Nothing
        case eM of
            Just (Right tx) -> do
                let hs' = txHash tx `delete` hs
                liftIO . atomically . l . Just $ Right tx
                go hs'
            Just (Left ths') -> do
                let hs' = hs \\ ths'
                forM_ ths $ liftIO . atomically . l . Just . Left
                go hs'
            Nothing -> throwIO PeerTimeout

downloadBlocks ::
       MonadPeer m => [BlockHash] -> Listen (Maybe Block) -> Source m Message
downloadBlocks bhs l = do
    lp <- logMe
    let ivs = map (InvVector InvBlock . getBlockHash) bhs
        msg = MGetData (GetData ivs)
    $(logDebug) $ lp <> "Sending getdata for blocks"
    yield msg
    lift $ do
        receiveBlocks bhs l
        liftIO . atomically $ l Nothing

receiveBlocks :: MonadPeer m => [BlockHash] -> Listen (Maybe Block) -> m ()
receiveBlocks bhs l = go bhs
  where
    go [] = return ()
    go (h:hs) = do
        lp <- logMe
        $(logDebug) $ lp <> "Waiting to receive a block"
        p <- asks mySelf
        mm <-
            liftIO . timeout time . receiveMatch p $ \case
                PeerIncoming (MBlock b) -> do
                    let bh = headerHash $ blockHeader b
                    guard (bh == h)
                    return $ Just b
                PeerIncoming (MNotFound (NotFound nf)) -> do
                    guard . not . null $
                        [ BlockHash (invHash x)
                        | x <- nf
                        , let t = invType x
                        , t == InvBlock || t == InvMerkleBlock
                        , invHash x == getBlockHash h
                        ]
                    return Nothing
                _ -> Nothing
        case mm of
            Just m ->
                when (isJust m) $ do
                    liftIO . atomically $ l m
                    go hs
            Nothing -> throwIO PeerTimeout

downloadMerkleBlocks ::
       MonadPeer m
    => [BlockHash]
    -> Listen (Maybe (MerkleBlock, [Tx]))
    -> Source m Message
downloadMerkleBlocks bhs l = do
    lp <- logMe
    let ivs = map (InvVector InvMerkleBlock . getBlockHash) bhs
        msg = MGetData (GetData ivs)
    $(logDebug) $ lp <> "Sending getdata for merkle blocks"
    yield msg
    n <- liftIO randomIO
    $(logDebug) $ lp <> "Sending ping with nonce " <> logShow n
    yield $ MPing (Ping n)
    lift $ do
        receiveMerkles n bhs l
        liftIO . atomically $ l Nothing

receiveMerkles ::
       MonadPeer m
    => Word64 -- ^ sent ping nonce
    -> [BlockHash]
    -> Listen (Maybe (MerkleBlock, [Tx]))
    -> m ()
receiveMerkles n bhs l = go Nothing bhs
  where
    go cur hs = do
        lp <- logMe
        $(logDebug) $ lp <> "Waiting to receive a Merkle block"
        p <- asks mySelf
        f p cur hs >>= \case
            Nothing -> throwIO PeerTimeout
            Just m ->
                case m of
                    Just (b, txs) -> g cur hs b txs
                    Nothing       -> h cur hs
    f p cur hs =
        liftIO . timeout time . receiveMatch p $ \case
            PeerIncoming (MMerkleBlock b) -> do
                let bh = headerHash $ merkleHeader b
                case hs of
                    [] -> Nothing
                    h':_ -> do
                        guard (bh == h')
                        return $ Just (b, [])
            PeerIncoming (MTx tx) -> do
                (b, txs) <- cur
                if testTx b tx
                    then return $ Just (b, nub (tx : txs))
                    else return Nothing
            PeerIncoming (MNotFound (NotFound nf)) ->
                case hs of
                    [] -> Nothing
                    h':_ -> do
                        guard . not . null $
                            [ BlockHash (invHash x)
                            | x <- nf
                            , let t = invType x
                            , t == InvBlock || t == InvMerkleBlock
                            , invHash x == getBlockHash h'
                            ]
                        return Nothing
            PeerIncoming (MPong (Pong n'))
                | n' == n -> return Nothing
            _ -> Nothing
    g cur hs b txs = do
        lp <- logMe
        let m = Just (b, txs)
        case cur of
            Just (b', txs') ->
                if b == b'
                    then do
                        $(logDebug) $ lp <> "Got Merkle block transaction"
                        go m hs
                    else do
                        $(logDebug) $ lp <> "Got new Merkle block"
                        liftIO . atomically . l $ Just (b', reverse txs')
                        go m (tail hs)
            Nothing -> do
                $(logDebug) $ lp <> "Received a new Merkle block"
                go m (tail hs)
    h cur hs = do
        lp <- logMe
        case cur of
            Just (b, txs) -> do
                $(logDebug) $ lp <> "Sending merkle block to listener"
                liftIO . atomically . l $ Just (b, reverse txs)
            Nothing -> return ()
        if null hs
            then $(logDebug) $ lp <> "All Merkle block data received"
            else $(logError) $
                 lp <> "Closing incoming Merkle block channel early"

testTx :: MerkleBlock -> Tx -> Bool
testTx mb tx =
    let e = merkleBlockTxs mb
        txh = txHash tx
    in case e of
        Left _    -> False
        Right ths -> txh `elem` ths
