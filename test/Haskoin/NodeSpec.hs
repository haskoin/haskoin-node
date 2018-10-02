{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
module Haskoin.NodeSpec
    ( spec
    ) where

import           Control.Monad
import           Control.Monad.Logger
import           Control.Monad.Trans
import qualified Data.ByteString         as BS
import           Data.Either
import           Data.Maybe
import           Data.Serialize
import qualified Database.RocksDB        as RocksDB
import           Haskoin
import           Haskoin.Node
import           Network.Socket          (SockAddr (..))
import           NQE
import           System.Random
import           Test.Hspec
import           UnliftIO

data TestNode = TestNode
    { testMgr   :: Manager
    , testChain :: Chain
    , chainSub  :: Inbox ChainEvent
    , peerSub   :: Inbox (Peer, PeerEvent)
    }

spec :: Spec
spec = do
    let net = btcTest
    describe "node on test network" $ do
        it "connects to a peer" $
            withTestNode net "connect-one-peer" $ \TestNode {..} -> do
                p <- waitForPeer peerSub
                v <-
                    maybe (error "No online peer") onlinePeerVersion <$>
                    managerGetPeer testMgr p
                v `shouldSatisfy` maybe False ((>= 70002) . version)
        it "downloads some blocks" $
            withTestNode net "get-blocks" $ \TestNode {..} -> do
                let hs = [h1, h2]
                    h1 =
                        "000000000babf10e26f6cba54d9c282983f1d1ce7061f7e875b58f8ca47db932"
                    h2 =
                        "00000000851f278a8b2c466717184aae859af5b83c6f850666afbc349cf61577"
                p <- waitForPeer peerSub
                peerGetBlocks net p hs
                [b1, b2] <-
                    replicateM 2 . receiveMatch peerSub $ \case
                        (p', PeerMessage (MBlock b))
                            | p == p' -> Just b
                        _ -> Nothing
                headerHash (blockHeader b1) `shouldSatisfy` (`elem` hs)
                headerHash (blockHeader b2) `shouldSatisfy` (`elem` hs)
                let testMerkle b =
                        merkleRoot (blockHeader b) `shouldBe`
                        buildMerkleRoot (map txHash (blockTxns b))
                testMerkle b1
                testMerkle b2
        it "connects to multiple peers" $
            withTestNode net "connect-peers" $ \TestNode {..} -> do
                replicateM_ 2 $ waitForPeer peerSub
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
                    replicateM 3 . receiveMatch chainSub $ \case
                        ChainBestBlock bn -> Just bn
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
                p <- waitForPeer peerSub
                peerGetBlocks net p [h]
                b <-
                    receiveMatch peerSub $ \case
                        (p', PeerMessage (MBlock (Block b _)))
                            | p == p' -> Just b
                        _ -> Nothing
                headerHash b `shouldBe` h
        it "attempts to get inexistent things" $
            withTestNode net "download-fail" $ \TestNode {..} -> do
                let h =
                        TxHash .
                        fromRight (error "We will, we will rock you!") . decode $
                        BS.replicate 32 0xaa
                p <-
                    receiveMatch peerSub $ \case
                        (p, PeerConnected) -> Just p
                        _ -> Nothing
                peerGetTxs net p [h]
                r <- liftIO randomIO
                MPing (Ping r) `send` p
                m <-
                    receiveMatch peerSub $ \case
                        (p', PeerMessage m@MNotFound {})
                            | p == p' -> Just m
                        (p', PeerMessage m@(MPong (Pong r')))
                            | p == p' && r == r' -> Just m
                        _ -> Nothing
                m `shouldBe`
                    MNotFound (NotFound [InvVector InvWitnessTx (getTxHash h)])
        it "downloads some block parents" $
            withTestNode net "parents" $ \TestNode {..} -> do
                let hs =
                        [ "00000000c74a24e1b1f2c04923c514ed88fc785cf68f52ed0ccffd3c6fe3fbd9"
                        , "000000007e5c5f40e495186ac4122f2e4ee25788cc36984a5760c55ecb376cb1"
                        , "00000000a6299059b2bff3479bc569019792e75f3c0f39b10a0bc85eac1b1615"
                        ]
                bn <-
                    receiveMatch chainSub $ \case
                        ChainBestBlock bn -> Just bn
                        _ -> Nothing
                nodeHeight bn `shouldBe` 2000
                ps <- chainGetParents 1997 bn testChain
                length ps `shouldBe` 3
                forM_ (zip ps hs) $ \(p, h) ->
                    headerHash (nodeHeader p) `shouldBe` h

waitForPeer :: MonadIO m => Inbox (Peer, PeerEvent) -> m Peer
waitForPeer mailbox =
    receiveMatch mailbox $ \case
        (p, PeerConnected) -> Just p
        _ -> Nothing

withTestNode ::
       MonadUnliftIO m
    => Network
    -> String
    -> (TestNode -> m a)
    -> m a
withTestNode net str f =
    runNoLoggingT . withSystemTempDirectory ("haskoin-node-test-" <> str <> "-") $ \w -> do
        peer_pub <- newInbox =<< newTQueueIO
        chain_pub <- newInbox =<< newTQueueIO
        withAsync (publisher peer_pub) $ \a -> do
            link a
            withAsync (publisher chain_pub) $ \b -> do
                link b
                db <-
                    RocksDB.open
                        w
                        RocksDB.defaultOptions
                            { RocksDB.createIfMissing = True
                            , RocksDB.compression = RocksDB.SnappyCompression
                            }
                let cfg =
                        NodeConfig
                            { nodeConfMaxPeers = 20
                            , nodeConfDB = db
                            , nodeConfPeers = []
                            , nodeConfDiscover = True
                            , nodeConfNetAddr =
                                  NetworkAddress 0 (SockAddrInet 0 0)
                            , nodeConfNet = net
                            , nodeConfChainPub = chain_pub
                            , nodeConfPeerPub = peer_pub
                            }
                withPubSub Nothing peer_pub $ \peer_sub ->
                    withPubSub Nothing chain_pub $ \chain_sub ->
                        withNode cfg $ \(mgr, ch) ->
                            lift $
                            f
                                TestNode
                                    { testMgr = mgr
                                    , testChain = ch
                                    , peerSub = peer_sub
                                    , chainSub = chain_sub
                                    }
