{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
import           Control.Concurrent.NQE
import           Control.Monad
import           Control.Monad.Logger
import           Data.Maybe
import           Database.RocksDB            (DB)
import qualified Database.RocksDB            as RocksDB
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Node
import           Network.Haskoin.Store
import           Network.Haskoin.Transaction
import           Test.Hspec
import           UnliftIO

data TestStore = TestStore
    { testStoreDB :: !DB
    , testStoreBlockStore :: !BlockStore
    , testStoreChain :: !Chain
    , testStoreEvents :: !(Inbox StoreEvent)
    }

main :: IO ()
main = do
    setBTCtest
    hspec . describe "Download" $ do
        it "gets 8 blocks" $
            withTestStore "eight-blocks" $ \TestStore {..} -> do
                bs <-
                    replicateM 9 . receiveMatch testStoreEvents $ \case
                        BestBlock b -> Just b
                        _ -> Nothing
                withAsync (dummyEventHandler testStoreEvents) $ \_ -> do
                    let bestHash = last bs
                    bestNodeM <- chainGetBlock bestHash testStoreChain
                    bestNodeM `shouldSatisfy` isJust
                    let bestNode = fromJust bestNodeM
                        bestHeight = nodeHeight bestNode
                    bestHeight `shouldBe` 8
        it "get a block and its transactions" $
            withTestStore "get-block-txs" $ \TestStore {..} -> do
                bs <-
                    replicateM 382 $
                    receiveMatch testStoreEvents $ \case
                        BestBlock b -> Just b
                        _ -> Nothing
                withAsync (dummyEventHandler testStoreEvents) $ \_ -> do
                    let blockHash = last bs
                    m <- getBlock blockHash testStoreDB Nothing
                    let BlockValue {..} =
                            fromMaybe (error "Could not get block") m
                    blockValueHeight `shouldBe` 381
                    length blockValueTxs `shouldBe` 2
                    let h1 =
                            "e8588129e146eeb0aa7abdc3590f8c5920cc5ff42daf05c23b29d4ae5b51fc22"
                        h2 =
                            "7e621eeb02874ab039a8566fd36f4591e65eca65313875221842c53de6907d6c"
                    head blockValueTxs `shouldBe` h1
                    last blockValueTxs `shouldBe` h2
                    t1 <- getTx h1 testStoreDB Nothing
                    t1 `shouldSatisfy` isJust
                    txHash (detailedTxData (fromJust t1)) `shouldBe` h1
                    t2 <- getTx h2 testStoreDB Nothing
                    t2 `shouldSatisfy` isJust
                    txHash (detailedTxData (fromJust t2)) `shouldBe` h2

dummyEventHandler :: (MonadIO m, Mailbox b) => b a -> m ()
dummyEventHandler = forever . void . receive

withTestStore ::
       String -> (TestStore -> IO ()) -> IO ()
withTestStore t f =
    withSystemTempDirectory ("haskoin-store-test-" <> t <> "-") $ \w ->
        runNoLoggingT $ do
            s <- Inbox <$> liftIO newTQueueIO
            c <- Inbox <$> liftIO newTQueueIO
            b <- Inbox <$> liftIO newTQueueIO
            m <- Inbox <$> liftIO newTQueueIO
            p <- Inbox <$> liftIO newTQueueIO
            db <-
                RocksDB.open
                    w
                    RocksDB.defaultOptions
                    { RocksDB.createIfMissing = True
                    , RocksDB.compression = RocksDB.SnappyCompression
                    }
            let cfg =
                    StoreConfig
                    { storeConfBlocks = b
                    , storeConfSupervisor = s
                    , storeConfChain = c
                    , storeConfPublisher = p
                    , storeConfMaxPeers = 20
                    , storeConfInitPeers = []
                    , storeConfDiscover = True
                    , storeConfDB = db
                    , storeConfManager = m
                    }
            withAsync (store cfg) $ \a ->
                withPubSub p $ \sub -> do
                    link a
                    x <-
                        liftIO $
                        f
                            TestStore
                            { testStoreDB = db
                            , testStoreBlockStore = b
                            , testStoreChain = c
                            , testStoreEvents = sub
                            }
                    stopSupervisor s
                    wait a
                    return x
