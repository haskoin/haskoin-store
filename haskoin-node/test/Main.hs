{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}
import           Control.Concurrent.NQE
import           Control.Monad
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Control.Monad.Logger
import           Control.Monad.Trans.Control
import qualified Data.ByteString                as BS
import           Data.Maybe
import           Data.Serialize
import           Data.String.Conversions
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Crypto
import           Network.Haskoin.Network
import           Network.Haskoin.Node
import           Network.Haskoin.Transaction
import           Network.Haskoin.Util
import           Network.Socket                 (SockAddr (..))
import           System.IO.Temp
import           System.Random
import           Test.Framework
import           Test.Framework.Providers.HUnit (testCase)
import           Test.HUnit                     hiding (Node, Test)

main :: IO ()
main = do
    setTestnet
    defaultMain
        [ testCase "Connect to a peer" connectToPeer
        , testCase "Get a block" getTestBlocks
        , testCase "Download Merkle blocks" getTestMerkleBlocks
        , testCase "Connect to peers" connectToPeers
        , testCase "Connect and sync some headers" nodeConnectSync
        , testCase "Download a block" downloadBlock
        , testCase "Try to download inexistent things" downloadSomeFailures
        , testCase "Get parents" getParents
        ]

getParents :: Assertion
getParents =
    runNoLoggingT . withTestNode $ \(_mgr, ch, mbox) -> do
        $(logDebug) "[Test] Preparing to receive from mailbox"
        bn <-
            receiveMatch mbox $ \case
                ChainEvent (ChainNewBest bn) -> Just bn
                _ -> Nothing
        $(logDebug) "[Test] Got new best block"
        liftIO $ assertEqual "Not at height 2000" 2000 (nodeHeight bn)
        ps <- chainGetParents 1997 bn ch
        liftIO $ assertEqual "Wrong block count" 3 (length ps)
        forM_ (zip ps hs) $ \(p, h) ->
            liftIO $
            assertEqual
                "Unexpected parent block downloaded"
                h
                (headerHash $ nodeHeader p)
  where
    hs =
        [ "00000000c74a24e1b1f2c04923c514ed88fc785cf68f52ed0ccffd3c6fe3fbd9"
        , "000000007e5c5f40e495186ac4122f2e4ee25788cc36984a5760c55ecb376cb1"
        , "00000000a6299059b2bff3479bc569019792e75f3c0f39b10a0bc85eac1b1615"
        ]

nodeConnectSync :: Assertion
nodeConnectSync =
    runNoLoggingT . withTestNode $ \(_mgr, ch, mbox) -> do
        bns <-
            replicateM 3 . receiveMatch mbox $ \case
                ChainEvent (ChainNewBest bn) -> Just bn
                _ -> Nothing
        bb <- chainGetBest ch
        m <- chainGetAncestor 2357 (last bns) ch
        when (isNothing m) $ liftIO $ assertFailure "No ancestor found"
        let an = fromJust m
        liftIO $ testSyncedHeaders bns bb an

connectToPeers :: Assertion
connectToPeers =
    runNoLoggingT . withTestNode $ \(mgr, _ch, mbox) -> do
        replicateM_ 3 $ do
            pc <- receive mbox
            case pc of
                ManagerEvent (ManagerDisconnect _) ->
                    liftIO $ assertFailure "Received peer disconnection"
                _ -> return ()
        ps <- managerGetAllPeers mgr
        liftIO $ assertBool "Not even two peers connected" $ length ps >= 2

downloadBlock :: Assertion
downloadBlock =
    runNoLoggingT . withTestNode $ \(_mgr, _ch, mbox) -> do
        p <-
            receiveMatch mbox $ \case
                ManagerEvent (ManagerConnect p) -> Just p
                _ -> Nothing
        c <- getBlocks p [h]
        bM <- liftIO $ atomically c
        let b = fromJust bM
        liftIO $ do
            assertBool "Did not download block" $ isJust bM
            assertEqual "Block hash incorrect" h (headerHash $ blockHeader b)
  where
    h = "000000009ec921df4bb16aedd11567e27ede3c0b63835b257475d64a059f102b"

downloadSomeFailures :: Assertion
downloadSomeFailures =
    runNoLoggingT . withTestNode $ \(_mgr, _ch, mbox) -> do
        p <-
            receiveMatch mbox $ \case
                ManagerEvent (ManagerConnect p) -> Just p
                _ -> Nothing
        m <- getTx p h
        liftIO $
            assertBool "Managed to download inexistent transaction" $
            isNothing m
  where
    h = TxHash $ fromJust $ bsToHash256 $ BS.replicate 32 0xaa

testSyncedHeaders ::
       [BlockNode] -- blocks 2000, 4000, and 6000
    -> BlockNode -- best block
    -> BlockNode -- block 2357
    -> Assertion
testSyncedHeaders bns bb an = do
    assertEqual "Block hashes incorrect" hs (map (headerHash . nodeHeader) bns)
    assertBool "Best block height not equal or greater than 6000" $
        nodeHeight bb >= 6000
    assertEqual "Block 2357 has wrong hash" h $ headerHash (nodeHeader an)
  where
    h = "000000009ec921df4bb16aedd11567e27ede3c0b63835b257475d64a059f102b"
    hs =
        [ "0000000005bdbddb59a3cd33b69db94fa67669c41d9d32751512b5d7b68c71cf"
        , "00000000185b36fa6e406626a722793bea80531515e0b2a99ff05b73738901f1"
        , "000000001ab69b12b73ccdf46c9fbb4489e144b54f1565e42e481c8405077bdd"
        ]

connectToPeer :: Assertion
connectToPeer =
    runNoLoggingT . withTestNode $ \(mgr, _ch, mbox) -> do
        p <-
            receiveMatch mbox $ \case
                ManagerEvent (ManagerConnect (_a, p)) -> Just p
                _ -> Nothing
        $(logDebug) "[Test] Connected to a peer, retrieving version..."
        v <- fromMaybe (error "No version") <$> managerGetPeerVersion p mgr
        $(logDebug) $ "[Test] Got version " <> logShow v
        $(logDebug) $ "[Test] Getting best block..."
        bbM <- managerGetPeerBest p mgr
        $(logDebug) $ "[Test] Performing assertions..."
        liftIO $ do
            assertBool "Version greater or equal than 70002" $ v >= 70002
            assertEqual "Peer best is not genesis" (Just genesisNode) bbM
        $(logDebug) $ "[Test] Finished computing assertions"

getTestBlocks :: Assertion
getTestBlocks =
    runNoLoggingT . withTestNode $ \(_mgr, _ch, mbox) -> do
        $(logDebug) $ "[Test] Waiting for a peer"
        p <-
            receiveMatch mbox $ \case
                ManagerEvent (ManagerConnect p) -> Just p
                _ -> Nothing
        c <- getBlocks p hs
        b1M <- liftIO $ atomically c
        liftIO $ assertBool "First block not downloaded" $ isJust b1M
        let b1 = fromJust b1M
        b2M <- liftIO $ atomically c
        liftIO $ assertBool "Second block not downloaded" $ isJust b2M
        let b2 = fromJust b2M
        $(logDebug) $ "[Test] Got two blocks, computing assertions..."
        liftIO $ do
            "Block 1 hash incorrect" `assertBool`
                (headerHash (blockHeader b1) `elem` hs)
            "Block 2 hash incorrect" `assertBool`
                (headerHash (blockHeader b2) `elem` hs)
            forM_ [b1, b2] $ \b ->
                assertEqual
                    "Block Merkle root incorrect"
                    (merkleRoot (blockHeader b))
                    (buildMerkleRoot (map txHash (blockTxns b)))
        $(logDebug) $ "[Test] Finished computing assertions"
  where
    hs = [h1, h2]
    h1 = "000000000babf10e26f6cba54d9c282983f1d1ce7061f7e875b58f8ca47db932"
    h2 = "00000000851f278a8b2c466717184aae859af5b83c6f850666afbc349cf61577"

getTestMerkleBlocks :: Assertion
getTestMerkleBlocks =
    runNoLoggingT . withTestNode $ \(mgr, _ch, mbox) -> do
        n <- liftIO randomIO
        let f0 = bloomCreate 2 0.001 n BloomUpdateAll
            f1 = bloomInsert f0 $ encode k
            f2 = bloomInsert f1 $ encode $ getAddrHash a
        f2 `setManagerFilter` mgr
        p <-
            receiveMatch mbox $ \case
                ManagerEvent (ManagerConnect p) -> Just p
                _ -> Nothing
        c <- getMerkleBlocks p bhs
        b1M <- liftIO $ atomically c
        liftIO $ assertBool "Could not get first Merkle block" $ isJust b1M
        let (b1, txs1) = fromJust b1M
        b2M <- liftIO $ atomically c
        liftIO $ assertBool "Could not get second Merkle block" $ isJust b2M
        let (b2, txs2) = fromJust b2M
            e1@(Right ths1) = merkleBlockTxs b1
            ts1 = map txHash txs1
            e2@(Right ths2) = merkleBlockTxs b2
            ts2 = map txHash txs2
            h1' = headerHash $ merkleHeader b1
            h2' = headerHash $ merkleHeader b2
            txc1 = merkleTotalTxns b1
            txc2 = merkleTotalTxns b2
        endM <- liftIO $ atomically c
        liftIO $ do
            assertBool "Did not finish after second block" $ isNothing endM
            assertEqual
                "Address does not match key"
                a
                (pubKeyAddr (k :: PubKeyC))
            assertBool "Issues decoding first Merkle block" $ isRight e1
            assertBool "Issues decoding second Merkle block" $ isRight e2
            assertEqual "First hash incorrect" h1 h1'
            assertEqual "Second hash incorrect" h2 h2'
            assertEqual "First tx count incorrect" 42 txc1
            assertEqual "Second tx count incorrect" 8 txc2
            assertBool "First Merkle root invalid" $ testMerkleRoot b1
            assertBool "Second Merkle root invalid" $ testMerkleRoot b2
            assertEqual "Incorrect tx list length 1" (length ths1) $ length txs1
            assertEqual "Incorrect tx list length 2" (length ths2) $ length txs2
            assertBool "Tx hash 1 incorrect" $ all (`elem` ths1) ts1
            assertBool "Tx hash 2 incorrect" $ all (`elem` ths2) ts2
  where
    a = "mgpS4Zis8iwNhriKMro1QSGDAbY6pqzRtA"
    k = "02c3cface1777c70251cb206f7c80cabeae195dfbeeff0767cbd2a58d22be383da"
    h1 = "000000006cf9d53d65522002a01d8c7091c78d644106832bc3da0b7644f94d36"
    h2 = "000000000babf10e26f6cba54d9c282983f1d1ce7061f7e875b58f8ca47db932"
    bhs = [h1, h2]

withTestNode ::
       ( MonadIO m
       , MonadMask m
       , MonadBaseControl IO m
       , MonadLoggerIO m
       , Forall (Pure m)
       )
    => ((Manager, Chain, Inbox NodeEvent) -> m ())
    -> m ()
withTestNode f = do
    $(logDebug) "[Test] Setting up test directory"
    withSystemTempDirectory "haskoin-node-test-manager-" $ \w -> do
        $(logDebug) $ "[Test] Test directory created at " <> cs w
        events <- Inbox <$> liftIO newTQueueIO
        ch <- Inbox <$> liftIO newTQueueIO
        ns <- Inbox <$> liftIO newTQueueIO
        mgr <- Inbox <$> liftIO newTQueueIO
        let cfg =
                NodeConfig
                { maxPeers = 20
                , directory = w
                , initPeers = []
                , noNewPeers = False
                , nodeEvents = (`sendSTM` events)
                , netAddress = NetworkAddress 0 (SockAddrInet 0 0)
                , nodeSupervisor = ns
                , nodeChain = ch
                , nodeManager = mgr
                }
        withAsync (node cfg) $ \nd -> do
            link nd
            $(logDebug) "[Test] Node running. Launching tests..."
            f (mgr, ch, events)
            $(logDebug) "[Test] Test finished"
            stopSupervisor ns
            wait nd
    $(logDebug) "[Test] Directory is no more. Returning..."
