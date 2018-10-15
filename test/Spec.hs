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
                    replicateM 8 . receiveMatch testStoreEvents $ \case
                        StoreBestBlock b -> Just b
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
                            StoreBestBlock b
                                | h == 0 -> return b
                                | otherwise -> get_the_block ((h :: Int) - 1)
                            _ -> get_the_block h
                bh <- get_the_block 380
                m <- getBlock (testStoreDB, defaultReadOptions) bh
                let bd = fromMaybe (error "Could not get block") m
                blockDataHeight bd `shouldBe` 381
                length (blockDataTxs bd) `shouldBe` 2
                let h1 =
                        "e8588129e146eeb0aa7abdc3590f8c5920cc5ff42daf05c23b29d4ae5b51fc22"
                    h2 =
                        "7e621eeb02874ab039a8566fd36f4591e65eca65313875221842c53de6907d6c"
                head (blockDataTxs bd) `shouldBe` h1
                last (blockDataTxs bd) `shouldBe` h2
                t1 <- getTransaction (testStoreDB, defaultReadOptions) h1
                t1 `shouldSatisfy` isJust
                txHash (transactionData (fromJust t1)) `shouldBe` h1
                t2 <- getTransaction (testStoreDB, defaultReadOptions) h2
                t2 `shouldSatisfy` isJust
                txHash (transactionData (fromJust t2)) `shouldBe` h2

withTestStore ::
       MonadUnliftIO m => Network -> String -> (TestStore -> m a) -> m a
withTestStore net t f =
    withSystemTempDirectory ("haskoin-store-test-" <> t <> "-") $ \w -> do
        x <- newInbox
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
                        , storeConfListen = (`sendSTM` x)
                        }
            withStore cfg $ \Store {..} ->
                lift $
                f
                    TestStore
                        { testStoreDB = db
                        , testStoreBlockStore = storeBlock
                        , testStoreChain = storeChain
                        , testStoreEvents = x
                        }
