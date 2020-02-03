{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Haskoin.StoreSpec (spec) where

import           Control.Monad
import           Control.Monad.Logger
import           Control.Monad.Trans
import           Data.Maybe
import           Database.RocksDB
import           Haskoin
import           Haskoin.Node
import           Haskoin.Store
import           NQE
import           Test.Hspec
import           UnliftIO

data TestStore = TestStore
    { testStoreDB         :: !BlockDB
    , testStoreBlockStore :: !BlockStore
    , testStoreChain      :: !Chain
    , testStoreEvents     :: !(Inbox StoreEvent)
    }

spec :: Spec
spec = do
    let net = btcTest
    describe "Download" $ do
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
            withTestStore net "get-block-txs" $ \TestStore {..} ->
                withRocksDB testStoreDB $ do
                    let h1 =
                            "e8588129e146eeb0aa7abdc3590f8c5920cc5ff42daf05c23b29d4ae5b51fc22"
                        h2 =
                            "7e621eeb02874ab039a8566fd36f4591e65eca65313875221842c53de6907d6c"
                        get_the_block h =
                            receive testStoreEvents >>= \case
                                StoreBestBlock b
                                    | h == 0 -> return b
                                    | otherwise ->
                                        get_the_block ((h :: Int) - 1)
                                _ -> get_the_block h
                    bh <- get_the_block 380
                    m <- getBlock bh
                    let bd = fromMaybe (error "Could not get block") m
                    t1 <- getTransaction h1
                    t2 <- getTransaction h2
                    lift $ do
                        blockDataHeight bd `shouldBe` 381
                        length (blockDataTxs bd) `shouldBe` 2
                        head (blockDataTxs bd) `shouldBe` h1
                        last (blockDataTxs bd) `shouldBe` h2
                        t1 `shouldSatisfy` isJust
                        txHash (transactionData (fromJust t1)) `shouldBe` h1
                        t2 `shouldSatisfy` isJust
                        txHash (transactionData (fromJust t2)) `shouldBe` h2

withTestStore ::
       MonadUnliftIO m => Network -> String -> (TestStore -> m a) -> m a
withTestStore net t f =
    withSystemTempDirectory ("haskoin-store-test-" <> t <> "-") $ \w ->
        runNoLoggingT $ do
            x <- newInbox
            db <-
                open
                    w
                    defaultOptions
                        { createIfMissing = True
                        , errorIfExists = True
                        , compression = SnappyCompression
                        }
            let bdb = BlockDB {blockDB = db, blockDBopts = defaultReadOptions}
            let cfg =
                    StoreConfig
                        { storeConfMaxPeers = 20
                        , storeConfInitPeers = []
                        , storeConfDiscover = True
                        , storeConfDB = bdb
                        , storeConfNetwork = net
                        , storeConfListen = (`sendSTM` x)
                        }
            withStore cfg $ \Store {..} ->
                lift $
                f
                    TestStore
                        { testStoreDB = bdb
                        , testStoreBlockStore = storeBlock
                        , testStoreChain = storeChain
                        , testStoreEvents = x
                        }
