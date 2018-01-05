{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
import           Control.Concurrent.NQE
import           Control.Monad
import           Control.Monad.Logger
import           Control.Monad.Trans
import           Data.Maybe
import           Data.Monoid
import           Data.String.Conversions
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Node
import           Network.Haskoin.Store.Block
import           Network.Haskoin.Store.Master
import           Network.Haskoin.Transaction
import           System.IO.Temp
import           Test.Hspec

main :: IO ()
main = do
    setTestnet
    hspec $ do
        describe "bootstrap" $ do
            it "successfully starts actors and communicates" $
                withTestStore $ \(b, c, e) -> do
                    _ <- blockGetBest b
                    return ()
        describe "download" $ do
            it "gets 2149 blocks" $
                withTestStore $ \(b, c, e) -> do
                    bs <-
                        replicateM 2150 $ do
                            BlockEvent (BestBlock b) <- receive e
                            return b
                    withAsync (dummyEventHandler e) $ \_ -> do
                        let bestHash = last bs
                        bestNodeM <- chainGetBlock bestHash c
                        bestNodeM `shouldSatisfy` isJust
                        let bestNode = fromJust bestNodeM
                            bestHeight = nodeHeight bestNode
                        bestHeight `shouldBe` 2149
            it "get a block and its transactions" $
                withTestStore $ \(b, c, e) -> do
                    bs <-
                        replicateM 457 $ do
                            BlockEvent (BestBlock b) <- receive e
                            return b
                    withAsync (dummyEventHandler e) $ \_ -> do
                        let blockHash = last bs
                        m <- blockGetTxs blockHash b
                        let (sb, txs) =
                                fromMaybe (error "Could not get block") m
                        storedBlockHeight sb `shouldBe` 456
                        length txs `shouldBe` 21
                        let h1 =
                                "213c4b0958c4f72e45d670940aefca89de25d207d61fa66f50efa4f22b3b0a26"
                            h2 =
                                "e1952789b79852d417c3a0c5496cd74ed1c0ca72c1050c0bb5293f4289766408"
                        txHash (head txs) `shouldBe` h1
                        txHash (last txs) `shouldBe` h2

dummyEventHandler :: (MonadIO m, Mailbox b) => b a -> m ()
dummyEventHandler = forever . void . receive

withTestStore :: ((BlockStore, Chain, Inbox StoreEvent) -> IO ()) -> IO ()
withTestStore f =
    withSystemTempDirectory "haskoin-store-test-" $ \w -> runNoLoggingT $ do
        sup <- Inbox <$> liftIO newTQueueIO
        c <- Inbox <$> liftIO newTQueueIO
        b <- Inbox <$> liftIO newTQueueIO
        e <- Inbox <$> liftIO newTQueueIO
        let cfg =
                StoreConfig
                { storeConfDir = w
                , storeConfBlocks = b
                , storeConfSupervisor = sup
                , storeConfChain = c
                , storeConfListener = (`sendSTM` e)
                , storeConfMaxPeers = 20
                , storeConfInitPeers = []
                , storeConfNoNewPeers = False
                }
        withAsync (store cfg) $ \a -> do
            link a
            x <- liftIO $ f (b, c, e)
            stopSupervisor sup
            wait a
            return x
