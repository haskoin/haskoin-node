{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
module Haskoin.NodeSpec
    ( spec
    ) where

import           Conduit                (awaitForever, concatMapC, foldC, mapMC,
                                         runConduit, takeCE, yield, (.|))
import           Control.Monad          (forM_, forever, replicateM)
import           Control.Monad.Logger   (runNoLoggingT)
import           Control.Monad.Trans    (lift)
import           Data.ByteString        (ByteString)
import qualified Data.ByteString        as B
import           Data.ByteString.Base64 (decodeBase64Lenient)
import           Data.Either            (fromRight)
import           Data.List              (find)
import           Data.Maybe             (isJust, mapMaybe)
import           Data.Serialize         (decode, get, runGet, runPut)
import           Data.Time.Clock.POSIX  (getPOSIXTime)
import qualified Database.RocksDB       as R
import           Haskoin                (Block (..), BlockHash (..),
                                         BlockHeader (..), BlockNode (..),
                                         GetData (..), GetHeaders (..),
                                         Headers (..), InvType (..),
                                         InvVector (..), Message (..),
                                         MessageHeader (..), Network (..),
                                         NetworkAddress (..), Ping (..),
                                         Pong (..), VarInt (..), Version (..),
                                         bchRegTest, buildMerkleRoot,
                                         getMessage, headerHash, nodeNetwork,
                                         putMessage, sockToHostAddress, txHash)
import           Haskoin.Node
import           Network.Socket         (SockAddr (..))
import           NQE                    (Inbox, Mailbox, inboxToMailbox,
                                         newInbox, receive, receiveMatch, send,
                                         withPublisher, withSubscription)
import           System.Random          (randomIO)
import           Test.Hspec             (Spec, describe, it, shouldBe,
                                         shouldSatisfy)
import           UnliftIO               (MonadIO, MonadUnliftIO, liftIO,
                                         throwString, withAsync,
                                         withSystemTempDirectory)

data TestNode = TestNode
    { testMgr    :: PeerManager
    , testChain  :: Chain
    , nodeEvents :: Inbox NodeEvent
    }

dummyPeerConnect :: Network
                 -> NetworkAddress
                 -> SockAddr
                 -> WithConnection
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
    outc = mapMC $ \msg -> return $ runPut (putMessage net msg)
    inc =
        forever $ do
            x <- takeCE 24 .| foldC
            case decode x of
                Left _ -> error "Dummy peer not decode message header"
                Right (MessageHeader _ _ len _) -> do
                    y <- takeCE (fromIntegral len) .| foldC
                    case runGet (getMessage net) $ x `B.append` y of
                        Left e ->
                            error $
                            "Dummy peer could not decode payload: " <> show e
                        Right msg -> yield msg

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


spec :: Spec
spec = do
    let net = bchRegTest
    describe "peer manager on test network" $ do
        it "connects to a peer" $
            withTestNode net "connect-one-peer" $ \TestNode {..} -> do
                p <- waitForPeer nodeEvents
                Just OnlinePeer {onlinePeerVersion = Just Version {version = ver}} <-
                    getOnlinePeer p testMgr
                ver `shouldSatisfy` (>= 70002)
        it "downloads some blocks" $
            withTestNode net "get-blocks" $ \TestNode {..} -> do
                let h1 =
                        "3094ed3592a06f3d8e099eed2d9c1192329944f5df4a48acb29e08f12cfbb660"
                    h2 =
                        "0c89955fc5c9f98ecc71954f167b938138c90c6a094c4737f2e901669d26763f"
                p <- waitForPeer nodeEvents
                pbs <- getBlocks net 10 p [h1, h2]
                pbs `shouldSatisfy` isJust
                let Just [b1, b2] = pbs
                headerHash (blockHeader b1) `shouldBe` h1
                headerHash (blockHeader b2) `shouldBe` h2
                let testMerkle b =
                        merkleRoot (blockHeader b) `shouldBe`
                        buildMerkleRoot (map txHash (blockTxns b))
                testMerkle b1
                testMerkle b2
    describe "chain on test network" $ do
        it "syncs some headers" $
            withTestNode net "connect-sync" $ \TestNode {..} -> do
                let bh =
                        "3bfa0c6da615fc45aa44ddea6854ac19d16f3ca167e0e21ac2cc262a49c9b002"
                    ah =
                        "7dc835a78a55fa76f9184dc4f6663a73e418c7afec789c5ae25e432fd7fc8467"
                bn <-
                    receiveMatch nodeEvents $ \case
                        ChainEvent (ChainBestBlock bn)
                            | nodeHeight bn > 0 -> Just bn
                        _ -> Nothing
                bb <- chainGetBest testChain
                nodeHeight bb `shouldSatisfy` (== 15)
                an <-
                    maybe (throwString "No ancestor found") return =<<
                    chainGetAncestor 10 bn testChain
                headerHash (nodeHeader bn) `shouldBe` bh
                headerHash (nodeHeader an) `shouldBe` ah
        it "downloads some block parents" $
            withTestNode net "parents" $ \TestNode {..} -> do
                let hs =
                        [ "52e886df7b166d961ac2d3d2d561d806325d51a609dc0a5d9d5fcb65d47906d7"
                        , "2537a081b9e2b24d217fac2886f387758cb3aa4e4956b3be7ed229bafbb71b0f"
                        , "7c72f306215a296f9714320a497b1f2cb5f9b99f162d7e04333c243fac9a54d8"
                        ]
                [_, bn] <-
                    replicateM 2 $
                    receiveMatch nodeEvents $ \case
                        ChainEvent (ChainBestBlock bn) -> Just bn
                        _ -> Nothing
                nodeHeight bn `shouldBe` 15
                ps <- chainGetParents 12 bn testChain
                length ps `shouldBe` 3
                forM_ (zip ps hs) $ \(p, h) ->
                    headerHash (nodeHeader p) `shouldBe` h

waitForPeer :: MonadIO m => Inbox NodeEvent -> m Peer
waitForPeer inbox =
    receiveMatch inbox $ \case
        PeerEvent (PeerConnected p) -> Just p
        _ -> Nothing

withTestNode ::
       MonadUnliftIO m
    => Network
    -> String
    -> (TestNode -> m a)
    -> m a
withTestNode net str f =
    runNoLoggingT $
    withSystemTempDirectory ("haskoin-node-test-" <> str <> "-") $ \w ->
    withPublisher $ \pub -> do
        db <-
            R.open
                w
                R.defaultOptions
                    { R.createIfMissing = True
                    , R.errorIfExists = True
                    , R.compression = R.SnappyCompression
                    }
        let ad = NetworkAddress
                 nodeNetwork
                 (sockToHostAddress (SockAddrInet 0 0))
            na = NetworkAddress
                 0
                 (sockToHostAddress (SockAddrInet 0 0))
            sa = SockAddrInet 0 0
            cfg = NodeConfig
                  { nodeConfMaxPeers = 20
                  , nodeConfDB = db
                  , nodeConfPeers = [("127.0.0.1", 17486)]
                  , nodeConfDiscover = False
                  , nodeConfNetAddr = na
                  , nodeConfNet = net
                  , nodeConfEvents = pub
                  , nodeConfTimeout = 120
                  , nodeConfPeerOld = 48 * 3600
                  , nodeConfConnect = dummyPeerConnect net ad sa
                  }
        withNode cfg $ \(Node mgr ch) ->
            withSubscription pub $ \sub ->
            lift $
            f TestNode { testMgr = mgr
                       , testChain = ch
                       , nodeEvents = sub
                       }

allBlocks :: [Block]
allBlocks =
    fromRight (error "Could not decode blocks") $
    runGet f (decodeBase64Lenient allBlocksBase64)
  where
    f = mapM (const get) [(1 :: Int) .. 15]

allBlocksBase64 :: ByteString
allBlocksBase64 =
    "AAAAIAYibkYRGgtZyq8SYEPrW78ow086XjMqH8eytzzxiJEPakRJalmWTFwdvzNuH8fHLZEjn+4N\
    \FNMANdB7ez2M4a3TFbNe//9/IAMAAAABAgAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\
    \AAAAAP////8MUQEBCC9FQjMyLjAv/////wEA8gUqAQAAACMhAwTspkCjMezKs47BPpafou1jjsHf\
    \1OHjgkqxnwEYkK9zrAAAAAAAAAAge0RDjOrqVayGUoQsbNTJcTXUM+psaHpmuiFy6hwo2T8yn0CL\
    \7WDJw9hxl1kf5c4JySq3WJF8OPsoguzF7mXH3tQVs17//38gAAAAAAECAAAAAQAAAAAAAAAAAAAA\
    \AAAAAAAAAAAAAAAAAAAAAAAAAAAA/////wxSAQEIL0VCMzIuMC//////AQDyBSoBAAAAIyEDBOym\
    \QKMx7MqzjsE+lp+i7WOOwd/U4eOCSrGfARiQr3OsAAAAAAAAACCKlhzDaFkrsmO2FhmeQS9ONS8D\
    \QsU4H97yNxVhyIXYJuG3a9cyQpdeETjCQ6JybgkwI0OOfa4eYazf7WWI5UAk1BWzXv//fyAEAAAA\
    \AQIAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD/////DFMBAQgvRUIzMi4wL///\
    \//8BAPIFKgEAAAAjIQME7KZAozHsyrOOwT6Wn6LtY47B39Th44JKsZ8BGJCvc6wAAAAAAAAAIP/S\
    \XiIJZqvUyBY90z72dv6+/GG50R3vc3UAK8AHP89wChmkVP6nefjOt+sNyhbKk9zia47F08oTNtC0\
    \OG1zyuXVFbNe//9/IAEAAAABAgAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAP//\
    \//8MVAEBCC9FQjMyLjAv/////wEA8gUqAQAAACMhAwTspkCjMezKs47BPpafou1jjsHf1OHjgkqx\
    \nwEYkK9zrAAAAAAAAAAgeQtE1s3YV/uS2jUouo3S9DJAVf5OGk+Nyx+No1mPH24b5JCkr/tSP0E/\
    \NYVkVcE0ZHxbO/fu5wOd+8VolvPQYtUVs17//38gAAAAAAECAAAAAQAAAAAAAAAAAAAAAAAAAAAA\
    \AAAAAAAAAAAAAAAAAAAA/////wxVAQEIL0VCMzIuMC//////AQDyBSoBAAAAIyEDBOymQKMx7Mqz\
    \jsE+lp+i7WOOwd/U4eOCSrGfARiQr3OsAAAAAAAAACBgtvss8QiesqxISt/1RJkykhGcLe2eCY49\
    \b6CSNe2UMOVYGZ++uRCKvaJ2+jo7akr7XsdXCYSAmuw6DwSO8lvF1RWzXv//fyAAAAAAAQIAAAAB\
    \AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD/////DFYBAQgvRUIzMi4wL/////8BAPIF\
    \KgEAAAAjIQME7KZAozHsyrOOwT6Wn6LtY47B39Th44JKsZ8BGJCvc6wAAAAAAAAAID92Jp1mAeny\
    \N0dMCWoMyTiBk3sWT5VxzI75ycVflYkMCnXLFhuwrMdBbZmXJinAJBUpN7BV0XvlM2PRmb7HQebV\
    \FbNe//9/IAEAAAABAgAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAP////8MVwEB\
    \CC9FQjMyLjAv/////wEA8gUqAQAAACMhAwTspkCjMezKs47BPpafou1jjsHf1OHjgkqxnwEYkK9z\
    \rAAAAAAAAAAgxEgEkhjf5p+ql8dETmdSCdCdk+vB26+V2SGLEuE1+kA1acGCdQoQBqec8P/knItJ\
    \M213OIrDX6U5IB6fgIas7dYVs17//38gAQAAAAECAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\
    \AAAAAAAAAAAA/////wxYAQEIL0VCMzIuMC//////AQDyBSoBAAAAIyEDBOymQKMx7MqzjsE+lp+i\
    \7WOOwd/U4eOCSrGfARiQr3OsAAAAAAAAACDku4EB5X7htWpHg+aMzzW1AABttpNQTew7K3Aj2fh/\
    \OuOCPhJApmcXq5o42tkksFSuhYvcfqaSHCuuFgjo6ohz1hWzXv//fyAAAAAAAQIAAAABAAAAAAAA\
    \AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD/////DFkBAQgvRUIzMi4wL/////8BAPIFKgEAAAAj\
    \IQME7KZAozHsyrOOwT6Wn6LtY47B39Th44JKsZ8BGJCvc6wAAAAAAAAAIKWpAhOWbkEN9vWf1uCu\
    \eXtVOZIE9V1OE87iC+H9atBRtY4LPgaWUSVMNh9SeZK1NViIFMklbjsfqYiC4eA/VuLWFbNe//9/\
    \IAAAAAABAgAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAP////8MWgEBCC9FQjMy\
    \LjAv/////wEA8gUqAQAAACMhAwTspkCjMezKs47BPpafou1jjsHf1OHjgkqxnwEYkK9zrAAAAAAA\
    \AAAgZ4T81y9DXuJanHjsr8cY5HM6ZvbETRj5dvpViqc1yH0oN9OOruaO5mjdITJwweVCzjSQ5Wsl\
    \vSOKaKvEX5j9l9YVs17//38gAAAAAAECAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\
    \AAAA/////wxbAQEIL0VCMzIuMC//////AQDyBSoBAAAAIyEDBOymQKMx7MqzjsE+lp+i7WOOwd/U\
    \4eOCSrGfARiQr3OsAAAAAAAAACCV3J2A3qneSJ7Q/RuF8OPd8O1izIXvKElR/xg/+InGNEafu0Ul\
    \3VYJR93zbAQuns9hUfAhA8MTBPk8bbDabDfo1hWzXv//fyAAAAAAAQIAAAABAAAAAAAAAAAAAAAA\
    \AAAAAAAAAAAAAAAAAAAAAAAAAAD/////DFwBAQgvRUIzMi4wL/////8BAPIFKgEAAAAjIQME7KZA\
    \ozHsyrOOwT6Wn6LtY47B39Th44JKsZ8BGJCvc6wAAAAAAAAAINcGedRly1+dXQrcCaZRXTIG2GHV\
    \0tPCGpZtFnvfhuhSx8d3Azdv/MXRJgsb56qqmD5gsXiWUdi7ia7wsBZVylvWFbNe//9/IAEAAAAB\
    \AgAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAP////8MXQEBCC9FQjMyLjAv////\
    \/wEA8gUqAQAAACMhAwTspkCjMezKs47BPpafou1jjsHf1OHjgkqxnwEYkK9zrAAAAAAAAAAgDxu3\
    \+7op0n6+s1ZJTqqzjHWH84YorH8hTbLiuYGgNyWIkhaj0zR7Vc+fSRm4UYUaPsefRhq3fUt8glyS\
    \D8P/5tcVs17//38gAwAAAAECAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA////\
    \/wxeAQEIL0VCMzIuMC//////AQDyBSoBAAAAIyEDBOymQKMx7MqzjsE+lp+i7WOOwd/U4eOCSrGf\
    \ARiQr3OsAAAAAAAAACDYVJqsPyQ8MwR+LRafufm1LB97SQoyFJdvKVohBvNyfD4/FxT2i0rlYQcS\
    \TQAvTnehousK2P8T9c0qx4Yj72lT1xWzXv//fyAAAAAAAQIAAAABAAAAAAAAAAAAAAAAAAAAAAAA\
    \AAAAAAAAAAAAAAAAAAD/////DF8BAQgvRUIzMi4wL/////8BAPIFKgEAAAAjIQME7KZAozHsyrOO\
    \wT6Wn6LtY47B39Th44JKsZ8BGJCvc6wAAAAA"
