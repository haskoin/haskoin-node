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
import qualified Data.ByteString      as BS
import           Data.Either
import           Data.Maybe
import           Data.Serialize
import qualified Database.RocksDB     as R
import           Haskoin
import           Haskoin.Node
import           Network.Socket       (SockAddr (..))
import           NQE
import           System.Random
import           Test.Hspec
import           UnliftIO

data TestNode = TestNode
    { testMgr    :: Manager
    , testChain  :: Chain
    , nodeEvents :: Inbox NodeEvent
    }

spec :: Spec
spec = do
    let net = btcTest
    describe "peer manager on test network" $ do
        it "connects to at a couple of peers" $
            withTestNode net "connect-one-peer" $ \TestNode {..} -> do
                ver <- onlinePeerVersion <$> waitForPeer testMgr nodeEvents
                ver `shouldSatisfy` maybe False ((>= 70002) . version)
        it "downloads some blocks" $
            withTestNode net "get-blocks" $ \TestNode {..} -> do
                let hs = [h1, h2]
                    h1 =
                        "000000000babf10e26f6cba54d9c282983f1d1ce7061f7e875b58f8ca47db932"
                    h2 =
                        "00000000851f278a8b2c466717184aae859af5b83c6f850666afbc349cf61577"
                let get_blocks =
                        waitForPeer testMgr nodeEvents >>= \op -> do
                            let p = onlinePeerMailbox op
                            peerGetBlocks net p hs
                            bs <-
                                fmap catMaybes .
                                replicateM 2 . receiveMatchS 30 nodeEvents $ \case
                                    PeerEvent (PeerMessage p' (MBlock b))
                                        | p == p' -> Just b
                                    _ -> Nothing
                            case length bs of
                                2 -> return bs
                                _ -> get_blocks
                [b1, b2] <- get_blocks
                headerHash (blockHeader b1) `shouldSatisfy` (`elem` hs)
                headerHash (blockHeader b2) `shouldSatisfy` (`elem` hs)
                let testMerkle b =
                        merkleRoot (blockHeader b) `shouldBe`
                        buildMerkleRoot (map txHash (blockTxns b))
                testMerkle b1
                testMerkle b2
        it "connects to two peers" $
            withTestNode net "connect-peers" $ \TestNode {..} ->
                replicateM_ 2 (waitForPeer testMgr nodeEvents) `shouldReturn` ()
        it "attempts to get inexistent things" $
            withTestNode net "download-fail" $ \TestNode {..} -> do
                let h =
                        TxHash .
                        fromRight (error "We will, we will rock you!") . decode $
                        BS.replicate 32 0xaa
                let get_tx = do
                        p <-
                            onlinePeerMailbox <$> waitForPeer testMgr nodeEvents
                        peerGetTxs net p [h]
                        r <- liftIO randomIO
                        MPing (Ping r) `send` p
                        m <-
                            timeout (5 * 1000 * 1000) $
                            receiveMatch nodeEvents $ \case
                                PeerEvent (PeerMessage p' (MNotFound (NotFound (InvVector _ h':_))))
                                    | p == p' -> Just (Right h')
                                PeerEvent (PeerMessage p' (MPong (Pong r')))
                                    | p == p' -> Just (Left r')
                                _ -> Nothing
                        case m of
                            Nothing ->
                                throwString "Timeout getting inexistent tx"
                            Just (Right n) -> return n
                            Just (Left r') ->
                                if r == r'
                                    then get_tx
                                    else throwString
                                             "Wrong pong after inexistent tx request"
                get_tx `shouldReturn` getTxHash h
    describe "chain on test network" $ do
        it "syncs some headers" $
            withTestNode net "connect-sync" $ \TestNode {..} -> do
                let h =
                        "000000009ec921df4bb16aedd11567e27ede3c0b63835b257475d64a059f102b"
                    hs =
                        [ headerHash (getGenesisHeader net)
                        , "0000000005bdbddb59a3cd33b69db94fa67669c41d9d32751512b5d7b68c71cf"
                        , "00000000185b36fa6e406626a722793bea80531515e0b2a99ff05b73738901f1"
                        , "000000001ab69b12b73ccdf46c9fbb4489e144b54f1565e42e481c8405077bdd"
                        ]
                bns <-
                    replicateM 4 . receiveMatch nodeEvents $ \case
                        ChainEvent (ChainBestBlock bn) -> Just bn
                        _ -> Nothing
                bb <- chainGetBest testChain
                nodeHeight bb `shouldSatisfy` (>= 6000)
                an <-
                    maybe (throwString "No ancestor found") return =<<
                    chainGetAncestor 2357 (last bns) testChain
                map (headerHash . nodeHeader) bns `shouldBe` hs
                headerHash (nodeHeader an) `shouldBe` h
        it "downloads some block parents" $
            withTestNode net "parents" $ \TestNode {..} -> do
                let hs =
                        [ "00000000c74a24e1b1f2c04923c514ed88fc785cf68f52ed0ccffd3c6fe3fbd9"
                        , "000000007e5c5f40e495186ac4122f2e4ee25788cc36984a5760c55ecb376cb1"
                        , "00000000a6299059b2bff3479bc569019792e75f3c0f39b10a0bc85eac1b1615"
                        ]
                [_, bn] <-
                    replicateM 2 $
                    receiveMatch nodeEvents $ \case
                        ChainEvent (ChainBestBlock bn) -> Just bn
                        _ -> Nothing
                nodeHeight bn `shouldBe` 2000
                ps <- chainGetParents 1997 bn testChain
                length ps `shouldBe` 3
                forM_ (zip ps hs) $ \(p, h) ->
                    headerHash (nodeHeader p) `shouldBe` h

waitForPeer :: MonadIO m => Manager -> Inbox NodeEvent -> m OnlinePeer
waitForPeer mgr mailbox = do
    p <-
        receiveMatch mailbox $ \case
            PeerEvent (PeerConnected p) -> return p
            _ -> Nothing
    managerGetPeer p mgr >>= \case
        Just op -> return op
        Nothing ->
            throwString "Got a peer connected event but could not get peer data"

withTestNode ::
       MonadUnliftIO m
    => Network
    -> String
    -> (TestNode -> m a)
    -> m a
withTestNode net str f =
    runNoLoggingT . withSystemTempDirectory ("haskoin-node-test-" <> str <> "-") $ \w -> do
        node_inbox <- newInbox
        db <-
            R.open
                w
                R.defaultOptions
                    { R.createIfMissing = True
                    , R.compression = R.SnappyCompression
                    }
        let cfg =
                NodeConfig
                    { nodeConfMaxPeers = 20
                    , nodeConfDB = db
                    , nodeConfPeers = []
                    , nodeConfDiscover = True
                    , nodeConfNetAddr = NetworkAddress 0 (SockAddrInet 0 0)
                    , nodeConfNet = net
                    , nodeConfEvents = (`sendSTM` node_inbox)
                    }
        withNode cfg $ \(mgr, ch) ->
            lift $
            f TestNode {testMgr = mgr, testChain = ch, nodeEvents = node_inbox}
