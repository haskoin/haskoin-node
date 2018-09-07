{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
import           Control.Concurrent.NQE
import           Control.Monad
import           Control.Monad.Logger
import           Control.Monad.Trans
import qualified Data.ByteString             as BS
import           Data.Either
import           Data.Maybe
import           Data.Serialize
import qualified Database.RocksDB            as RocksDB
import           Network.Haskoin.Address
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Keys
import           Network.Haskoin.Network
import           Network.Haskoin.Node
import           Network.Haskoin.Transaction
import           Network.Socket              (SockAddr (..))
import           System.Random
import           Test.Hspec
import           UnliftIO

data TestNode = TestNode
    { testMgr    :: Manager
    , testChain  :: Chain
    , testEvents :: Inbox NodeEvent
    }

main :: IO ()
main = do
    let net = btcTest
    hspec . describe "peer-to-peer client" $ do
        it "connects to a peer" $
            withTestNode net "connect-one-peer" $ \TestNode {..} -> do
                p <-
                    receiveMatch testEvents $ \case
                        ManagerEvent (ManagerConnect p) -> Just p
                        _ -> Nothing
                v <-
                    fromMaybe (error "No version") <$>
                    managerGetPeerVersion p testMgr
                v `shouldSatisfy` (>= 70002)
                bb <-
                    fromMaybe (error "No best block") <$>
                    managerGetPeerBest p testMgr
                bb `shouldBe` genesisNode net
        it "downloads some blocks" $
            withTestNode net "get-blocks" $ \TestNode {..} -> do
                let hs = [h1, h2]
                    h1 =
                        "000000000babf10e26f6cba54d9c282983f1d1ce7061f7e875b58f8ca47db932"
                    h2 =
                        "00000000851f278a8b2c466717184aae859af5b83c6f850666afbc349cf61577"
                p <-
                    receiveMatch testEvents $ \case
                        ManagerEvent (ManagerConnect p) -> Just p
                        _ -> Nothing
                peerGetBlocks net p hs
                b1 <-
                    receiveMatch testEvents $ \case
                        PeerEvent (p', GotBlock b)
                            | p == p' -> Just b
                        _ -> Nothing
                b2 <-
                    receiveMatch testEvents $ \case
                        PeerEvent (p', GotBlock b)
                            | p == p' -> Just b
                        _ -> Nothing
                headerHash (blockHeader b1) `shouldSatisfy` (`elem` hs)
                headerHash (blockHeader b2) `shouldSatisfy` (`elem` hs)
                let testMerkle b =
                        merkleRoot (blockHeader b) `shouldBe`
                        buildMerkleRoot (map txHash (blockTxns b))
                testMerkle b1
                testMerkle b2
        it "downloads some merkle blocks" $
            withTestNode net "get-merkle-blocks" $ \TestNode {..} -> do
                let a =
                        fromJust $
                        stringToAddr net "mgpS4Zis8iwNhriKMro1QSGDAbY6pqzRtA"
                    k :: PubKey
                    k =
                        "02c3cface1777c70251cb206f7c80cabeae195dfbeeff0767cbd2a58d22be383da"
                    h1 =
                        "000000006cf9d53d65522002a01d8c7091c78d644106832bc3da0b7644f94d36"
                    h2 =
                        "000000000babf10e26f6cba54d9c282983f1d1ce7061f7e875b58f8ca47db932"
                    bhs = [h1, h2]
                n <- randomIO
                let f0 = bloomCreate 2 0.001 n BloomUpdateAll
                    f1 = bloomInsert f0 $ exportPubKey True k
                    f2 = bloomInsert f1 $ encode $ getAddrHash160 a
                f2 `setManagerFilter` testMgr
                p <-
                    receiveMatch testEvents $ \case
                        ManagerEvent (ManagerConnect p) -> Just p
                        _ -> Nothing
                getMerkleBlocks p bhs
                b1 <-
                    receiveMatch testEvents $ \case
                        PeerEvent (p', GotMerkleBlock b)
                            | p == p' -> Just b
                        _ -> Nothing
                b2 <-
                    receiveMatch testEvents $ \case
                        PeerEvent (p', GotMerkleBlock b)
                            | p == p' -> Just b
                        _ -> Nothing
                liftIO $ do
                    a `shouldBe` pubKeyAddr net (wrapPubKey True k)
                    b1 `shouldSatisfy` testMerkleRoot net
                    b2 `shouldSatisfy` testMerkleRoot net
        it "connects to multiple peers" $
            withTestNode net "connect-peers" $ \TestNode {..} -> do
                replicateM_ 3 $ do
                    pc <- receive testEvents
                    case pc of
                        ManagerEvent (ManagerDisconnect _) ->
                            expectationFailure "Received peer disconnection"
                        _ -> return ()
                ps <- managerGetPeers testMgr
                length ps `shouldSatisfy` (>= 2)
        it "connects and syncs some headers" $
            withTestNode net "connect-sync" $ \TestNode {..} -> do
                let h =
                        "000000009ec921df4bb16aedd11567e27ede3c0b63835b257475d64a059f102b"
                    hs =
                        [ "0000000005bdbddb59a3cd33b69db94fa67669c41d9d32751512b5d7b68c71cf"
                        , "00000000185b36fa6e406626a722793bea80531515e0b2a99ff05b73738901f1"
                        , "000000001ab69b12b73ccdf46c9fbb4489e144b54f1565e42e481c8405077bdd"
                        ]
                bns <-
                    replicateM 3 . receiveMatch testEvents $ \case
                        ChainEvent (ChainNewBest bn) -> Just bn
                        _ -> Nothing
                bb <- chainGetBest testChain
                an <-
                    fromMaybe (error "No ancestor found") <$>
                    chainGetAncestor 2357 (last bns) testChain
                map (headerHash . nodeHeader) bns `shouldBe` hs
                nodeHeight bb `shouldSatisfy` (>= 6000)
                headerHash (nodeHeader an) `shouldBe` h
        it "downloads a single block" $
            withTestNode net "download-block" $ \TestNode {..} -> do
                let h =
                        "000000009ec921df4bb16aedd11567e27ede3c0b63835b257475d64a059f102b"
                p <-
                    receiveMatch testEvents $ \case
                        ManagerEvent (ManagerConnect p) -> Just p
                        _ -> Nothing
                peerGetBlocks net p [h]
                b <-
                    receiveMatch testEvents $ \case
                        PeerEvent (p', GotBlock b)
                            | p == p' -> Just b
                        _ -> Nothing
                headerHash (blockHeader b) `shouldBe` h
        it "attempts to get inexistent things" $
            withTestNode net "download-fail" $ \TestNode {..} -> do
                let h =
                        TxHash .
                        fromRight (error "We will, we will rock you!") . decode $
                        BS.replicate 32 0xaa
                p <-
                    receiveMatch testEvents $ \case
                        ManagerEvent (ManagerConnect p) -> Just p
                        _ -> Nothing
                peerGetTxs net p [h]
                n <-
                    receiveMatch testEvents $ \case
                        PeerEvent (p', TxNotFound n)
                            | p == p' -> Just n
                        _ -> Nothing
                n `shouldBe` h
        it "downloads some block parents" $
            withTestNode net "parents" $ \TestNode {..} -> do
                let hs =
                        [ "00000000c74a24e1b1f2c04923c514ed88fc785cf68f52ed0ccffd3c6fe3fbd9"
                        , "000000007e5c5f40e495186ac4122f2e4ee25788cc36984a5760c55ecb376cb1"
                        , "00000000a6299059b2bff3479bc569019792e75f3c0f39b10a0bc85eac1b1615"
                        ]
                bn <-
                    receiveMatch testEvents $ \case
                        ChainEvent (ChainNewBest bn) -> Just bn
                        _ -> Nothing
                nodeHeight bn `shouldBe` 2000
                ps <- chainGetParents 1997 bn testChain
                length ps `shouldBe` 3
                forM_ (zip ps hs) $ \(p, h) ->
                    headerHash (nodeHeader p) `shouldBe` h

withTestNode ::
       (MonadUnliftIO m)
    => Network
    -> String
    -> (TestNode -> m ())
    -> m ()
withTestNode net t f =
    runNoLoggingT . withSystemTempDirectory ("haskoin-node-test-" <> t <> "-") $ \w -> do
        events <- Inbox <$> liftIO newTQueueIO
        ch <- Inbox <$> liftIO newTQueueIO
        ns <- Inbox <$> liftIO newTQueueIO
        mgr <- Inbox <$> liftIO newTQueueIO
        db <-
            RocksDB.open
                w
                RocksDB.defaultOptions
                { RocksDB.createIfMissing = True
                , RocksDB.compression = RocksDB.SnappyCompression
                }
        let cfg =
                NodeConfig
                { maxPeers = 20
                , database = db
                , initPeers = []
                , discover = True
                , nodeEvents = (`sendSTM` events)
                , netAddress = NetworkAddress 0 (SockAddrInet 0 0)
                , nodeSupervisor = ns
                , nodeChain = ch
                , nodeManager = mgr
                , nodeNet = net
                }
        withAsync (node cfg) $ \nd -> do
            link nd
            lift $
                f TestNode {testMgr = mgr, testChain = ch, testEvents = events}
            stopSupervisor ns
            wait nd
