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
import           Data.Default
import           Data.Either
import           Data.Maybe
import           Data.Serialize
import           Data.String.Conversions
import qualified Database.RocksDB               as RocksDB
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Crypto
import           Network.Haskoin.Network
import           Network.Haskoin.Node
import           Network.Haskoin.Transaction
import           Network.Socket                 (SockAddr (..))
import           System.IO.Temp
import           System.Random
import           Test.Framework
import           Test.Framework.Providers.HUnit (testCase)
import           Test.HUnit                     hiding (Node, Test)

main :: IO ()
main = do
    setTestnet3Network
    defaultMain
        [ testCase "Connect to a peer" connectToPeer
        , testCase "Get a block" getTestBlocks
        , testCase "Download Merkle blocks" getTestMerkleBlocks
        , testCase "Connect to peers" connectToPeers
        , testCase "Connect and sync some headers" nodeConnectSync
        , testCase "Download a block" downloadBlock
        , testCase "Try to download inexistent things" downloadSomeFailures
        , testCase "Get parents" getParentsTest
        ]

getParentsTest :: Assertion
getParentsTest =
    runNoLoggingT . withTestNode "parents" $ \(_mgr, ch, mbox) -> do
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
    runNoLoggingT . withTestNode "connect-sync" $ \(_mgr, ch, mbox) -> do
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
    runNoLoggingT . withTestNode "connect-peers" $ \(mgr, _ch, mbox) -> do
        replicateM_ 3 $ do
            pc <- receive mbox
            case pc of
                ManagerEvent (ManagerDisconnect _) ->
                    liftIO $ assertFailure "Received peer disconnection"
                _ -> return ()
        ps <- managerGetPeers mgr
        liftIO $ assertBool "Not even two peers connected" $ length ps >= 2

downloadBlock :: Assertion
downloadBlock =
    runNoLoggingT . withTestNode "download-block" $ \(_mgr, _ch, mbox) -> do
        p <-
            receiveMatch mbox $ \case
                ManagerEvent (ManagerConnect p) -> Just p
                _ -> Nothing
        $(logInfo) "Getting block"
        peerGetBlocks p [h]
        $(logInfo) "Got block"
        b <-
            receiveMatch mbox $ \case
                PeerEvent (p', GotBlock b)
                    | p == p' -> Just b
                _ -> Nothing
        liftIO $
            assertEqual "Block hash incorrect" h (headerHash $ blockHeader b)
  where
    h = "000000009ec921df4bb16aedd11567e27ede3c0b63835b257475d64a059f102b"

downloadSomeFailures :: Assertion
downloadSomeFailures =
    runNoLoggingT . withTestNode "download-fail" $ \(_mgr, _ch, mbox) -> do
        p <-
            receiveMatch mbox $ \case
                ManagerEvent (ManagerConnect p) -> Just p
                _ -> Nothing
        peerGetTxs p [h]
        n <-
            receiveMatch mbox $ \case
                PeerEvent (p', TxNotFound n)
                    | p == p' -> Just n
                _ -> Nothing
        liftIO $ assertEqual "Managed to download inexistent transaction" h n
  where
    h =
        TxHash . fromRight (error "Could not decode dummy hash") . decode $
        BS.replicate 32 0xaa

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
    runNoLoggingT . withTestNode "connect-one-peer" $ \(mgr, _ch, mbox) -> do
        p <-
            receiveMatch mbox $ \case
                ManagerEvent (ManagerConnect p) -> Just p
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
    runNoLoggingT . withTestNode "get-blocks" $ \(_mgr, _ch, mbox) -> do
        $(logDebug) $ "[Test] Waiting for a peer"
        p <-
            receiveMatch mbox $ \case
                ManagerEvent (ManagerConnect p) -> Just p
                _ -> Nothing
        peerGetBlocks p hs
        b1 <-
            receiveMatch mbox $ \case
                PeerEvent (p', GotBlock b)
                    | p == p' -> Just b
                _ -> Nothing
        b2 <-
            receiveMatch mbox $ \case
                PeerEvent (p', GotBlock b)
                    | p == p' -> Just b
                _ -> Nothing
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
    runNoLoggingT . withTestNode "get-merkle-blocks" $ \(mgr, _ch, mbox) -> do
        n <- liftIO randomIO
        let f0 = bloomCreate 2 0.001 n BloomUpdateAll
            f1 = bloomInsert f0 $ encode k
            f2 = bloomInsert f1 $ encode $ getAddrHash a
        f2 `setManagerFilter` mgr
        p <-
            receiveMatch mbox $ \case
                ManagerEvent (ManagerConnect p) -> Just p
                _ -> Nothing
        getMerkleBlocks p bhs
        b1 <-
            receiveMatch mbox $ \case
                PeerEvent (p', GotMerkleBlock b)
                    | p == p' -> Just b
                _ -> Nothing
        b2 <-
            receiveMatch mbox $ \case
                PeerEvent (p', GotMerkleBlock b)
                    | p == p' -> Just b
                _ -> Nothing
        liftIO $ do
            assertEqual
                "Address does not match key"
                a
                (pubKeyAddr (k :: PubKeyC))
            assertBool "First Merkle root invalid" $ testMerkleRoot b1
            assertBool "Second Merkle root invalid" $ testMerkleRoot b2
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
    => String
    -> ((Manager, Chain, Inbox NodeEvent) -> m ())
    -> m ()
withTestNode t f = do
    $(logDebug) "[Test] Setting up test directory"
    withSystemTempDirectory ("haskoin-node-test-" <> t <> "-") $ \w -> do
        $(logDebug) $ "[Test] Test directory created at " <> cs w
        events <- Inbox <$> liftIO newTQueueIO
        ch <- Inbox <$> liftIO newTQueueIO
        ns <- Inbox <$> liftIO newTQueueIO
        mgr <- Inbox <$> liftIO newTQueueIO
        db <-
            RocksDB.open
                w
                def
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
                }
        withAsync (node cfg) $ \nd -> do
            link nd
            $(logDebug) "[Test] Node running. Launching tests..."
            f (mgr, ch, events)
            $(logDebug) "[Test] Test finished"
            stopSupervisor ns
            wait nd
    $(logDebug) "[Test] Directory is no more. Returning..."
