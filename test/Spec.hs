{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
import           Control.Monad
import           Control.Monad.Logger
import           Control.Monad.Trans
import           Data.Maybe
import           Database.RocksDB     (DB)
import           Database.RocksDB     as R
import           Haskoin
import           Haskoin.Node
import           Haskoin.Store
import           NQE
import           Test.Hspec
import           UnliftIO

data TestStore = TestStore
    { testStoreDB         :: !DB
    , testStoreBlockStore :: !BlockStore
    , testStoreChain      :: !Chain
    , testStoreEvents     :: !(Inbox StoreEvent)
    }

main :: IO ()
main = do
    let net = btcTest
    hspec . describe "Download" $ do
        it "gets 8 blocks" $
            withTestStore net "eight-blocks" $ \TestStore {..} -> do
                bs <-
                    replicateM 9 . receiveMatch testStoreEvents $ \case
                        BestBlock b -> Just b
                        _ -> Nothing
                let bestHash = last bs
                bestNodeM <- chainGetBlock bestHash testStoreChain
                bestNodeM `shouldSatisfy` isJust
                let bestNode = fromJust bestNodeM
                    bestHeight = nodeHeight bestNode
                bestHeight `shouldBe` 8
        it "get a block and its transactions" $
            withTestStore net "get-block-txs" $ \TestStore {..} -> do
                let get_the_block h =
                        receive testStoreEvents >>= \case
                            BestBlock b | h == 0 -> return b
                                        | otherwise -> get_the_block ((h :: Int) - 1)
                            _ -> get_the_block h
                bh <- get_the_block 381
                m <- withSnapshot testStoreDB $ getBlock bh testStoreDB
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
                t1 <- withSnapshot testStoreDB $ getTx net h1 testStoreDB
                t1 `shouldSatisfy` isJust
                txHash (detailedTxData (fromJust t1)) `shouldBe` h1
                t2 <- withSnapshot testStoreDB $ getTx net h2 testStoreDB
                t2 `shouldSatisfy` isJust
                txHash (detailedTxData (fromJust t2)) `shouldBe` h2

withTestStore ::
       MonadUnliftIO m => Network -> String -> (TestStore -> m a) -> m a
withTestStore net t f =
    withSystemTempDirectory ("haskoin-store-test-" <> t <> "-") $ \w ->
        runNoLoggingT $ do
            db <-
                open
                    w
                    defaultOptions
                        { createIfMissing = True
                        , compression = SnappyCompression
                        }
            let cfg =
                    StoreConfig
                        { storeConfMaxPeers = 20
                        , storeConfInitPeers = []
                        , storeConfDiscover = True
                        , storeConfDB = db
                        , storeConfNetwork = net
                        }
            withStore cfg $ \Store {..} ->
                withPubSub storePublisher newTQueueIO $ \sub ->
                    lift $
                    f
                        TestStore
                            { testStoreDB = db
                            , testStoreBlockStore = storeBlock
                            , testStoreChain = storeChain
                            , testStoreEvents = sub
                            }
