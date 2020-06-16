{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Haskoin.StoreSpec (spec) where

import           Conduit
import           Control.Monad
import           Control.Monad.Logger
import           Data.ByteString        (ByteString)
import qualified Data.ByteString        as B
import           Data.ByteString.Base64
import           Data.Either
import           Data.List
import           Data.Maybe
import           Data.Serialize
import           Data.Time.Clock.POSIX
import           Data.Word
import           Haskoin
import           Haskoin.Node
import           Haskoin.Store
import           Network.Socket
import           NQE
import           System.Random
import           Test.Hspec
import           UnliftIO

data TestStore = TestStore
    { testStoreDB         :: !DatabaseReader
    , testStoreBlockStore :: !BlockStore
    , testStoreChain      :: !Chain
    , testStoreEvents     :: !(Inbox StoreEvent)
    }

spec :: Spec
spec = describe "Download" $ do
    it "gets 8 blocks" $
        withTestStore bchRegTest "eight-blocks" $ \TestStore {..} -> do
        bs <- replicateM 8 . receiveMatch testStoreEvents $ \case
            StoreBestBlock b -> Just b
            _ -> Nothing
        let bestHash = last bs
        bestNodeM <- chainGetBlock bestHash testStoreChain
        bestNodeM `shouldSatisfy` isJust
        let bestNode = fromJust bestNodeM
            bestHeight = nodeHeight bestNode
        bestHeight `shouldBe` 8
    it "get a block and its transactions" $
        withTestStore bchRegTest "get-block-txs" $ \TestStore {..} ->
        withDatabaseReader testStoreDB $ do
        let h1 = "5369ef2386c72acdf513ffd80aeba2a1774e2f004d120761e54a8bf614173f3e"
            get_the_block h =
                receive testStoreEvents >>= \case
                    StoreBestBlock b
                        | h <= 1 -> return b
                        | otherwise ->
                            get_the_block ((h :: Int) - 1)
                    _ -> get_the_block h
        bh <- get_the_block 15
        m <- getBlock bh
        let bd = fromMaybe (error "Could not get block") m
        t1 <- getTransaction h1
        lift $ do
            blockDataHeight bd `shouldBe` 15
            length (blockDataTxs bd) `shouldBe` 1
            head (blockDataTxs bd) `shouldBe` h1
            t1 `shouldSatisfy` isJust
            txHash (transactionData (fromJust t1)) `shouldBe` h1

withTestStore ::
       MonadUnliftIO m => Network -> String -> (TestStore -> m a) -> m a
withTestStore net t f =
    withSystemTempDirectory ("haskoin-store-test-" <> t <> "-") $ \w ->
    runNoLoggingT $ do
    let ad = NetworkAddress
             nodeNetwork
             (sockToHostAddress (SockAddrInet 0 0))
        cfg = StoreConfig
              { storeConfMaxPeers = 20
              , storeConfInitPeers = []
              , storeConfDiscover = True
              , storeConfDB = w
              , storeConfNetwork = net
              , storeConfCache = Nothing
              , storeConfGap = gap
              , storeConfInitialGap = 20
              , storeConfCacheMin = 100
              , storeConfMaxKeys = 100 * 1000 * 1000
              , storeConfWipeMempool = False
              , storeConfPeerTimeout = 60
              , storeConfPeerMaxLife = 48 * 3600
              , storeConfConnect = dummyPeerConnect net ad
              }
    withStore cfg $ \Store {..} ->
        withSubscription storePublisher $ \sub ->
        lift $ f TestStore { testStoreDB = storeDB
                           , testStoreBlockStore = storeBlock
                           , testStoreChain = storeChain
                           , testStoreEvents = sub
                           }

gap :: Word32
gap = 32

allBlocks :: [Block]
allBlocks =
    fromRight (error "Could not decode blocks") $
    runGet f (decodeBase64Lenient allBlocksBase64)
  where
    f = mapM (const get) [(1 :: Int) .. 15]

allBlocksBase64 :: ByteString
allBlocksBase64 =
    "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\
    \wT6Wn6LtY47B39Th44JKsZ8BGJCvc6wAAAAA"

dummyPeerConnect :: Network -> NetworkAddress -> SockAddr -> WithConnection
dummyPeerConnect net ad sa f = do
    r <- newInbox
    s <- newInbox
    let s' = inboxToMailbox s
    withAsync (go r s') $ \_ -> do
        let o = awaitForever (`send` r)
            i = forever (receive s >>= yield)
        f (Conduits i o) :: IO ()
  where
    go :: Inbox ByteString -> Mailbox ByteString -> IO ()
    go r s = do
        nonce <- randomIO
        now <- round <$> liftIO getPOSIXTime
        let rmt = NetworkAddress 0 (sockToHostAddress sa)
            ver = buildVersion net nonce 0 ad rmt now
        runPut (putMessage net (MVersion ver)) `send` s
        runConduit $
            forever (receive r >>= yield) .| inc .| concatMapC mockPeerReact .|
            outc .|
            awaitForever (`send` s)
    outc = mapMC $ \msg' -> return $ runPut (putMessage net msg')
    inc = forever $ do
        x <- takeCE 24 .| foldC
        case decode x of
            Left _ ->
                error "Dummy peer not decode message header"
            Right (MessageHeader _ _ len _) -> do
                y <- takeCE (fromIntegral len) .| foldC
                case runGet (getMessage net) $ x `B.append` y of
                    Right msg' -> yield msg'
                    Left e -> error $
                        "Dummy peer could not decode payload: " <> show e

mockPeerReact :: Message -> [Message]
mockPeerReact (MPing (Ping n)) = [MPong (Pong n)]
mockPeerReact (MVersion _) = [MVerAck]
mockPeerReact (MGetHeaders (GetHeaders _ _hs _)) = [MHeaders (Headers hs')]
  where
    f b = (blockHeader b, VarInt (fromIntegral (length (blockTxns b))))
    hs' = map f allBlocks
mockPeerReact (MGetData (GetData ivs)) = mapMaybe f ivs
  where
    f (InvVector InvBlock h) = MBlock <$> find (l h) allBlocks
    f _                      = Nothing
    l h b = headerHash (blockHeader b) == BlockHash h
mockPeerReact _ = []
