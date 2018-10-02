{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TypeFamilies          #-}
module Network.Haskoin.Node.Peer
    ( peer
    ) where

import           Conduit
import           Control.Monad
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Data.ByteString             (ByteString)
import qualified Data.ByteString             as B
import           Data.Conduit.Network
import           Data.Serialize
import           Network.Haskoin.Constants
import           Network.Haskoin.Network
import           Network.Haskoin.Node.Common
import           NQE
import           UnliftIO

peer :: (MonadUnliftIO m, MonadLoggerIO m) => PeerConfig -> m ()
peer pc@PeerConfig {..} =
    withConnection peerConfAddress $ \ad -> runReaderT (peer_session ad) pc
  where
    go = forever $ receive peerConfMailbox >>= yield
    peer_session ad = do
        let ins = appSource ad
            ons = appSink ad
            src =
                runConduit $
                ins .| inPeerConduit peerConfNetwork .|
                mapC (\msg -> Event (peerConfMailbox, PeerMessage msg)) .|
                conduitMailbox peerConfPub
            snk = outPeerConduit peerConfNetwork .| ons
        withAsync src $ \as -> do
            link as
            runConduit (go .| snk)

inPeerConduit ::
       MonadIO m
    => Network
    -> ConduitT ByteString Message m ()
inPeerConduit net = do
    x <- takeCE 24 .| foldC
    case decode x of
        Left e -> throwIO $ DecodeMessageError e
        Right (MessageHeader _ _cmd len _) -> do
            when (len > 32 * 2 ^ (20 :: Int)) . throwIO $ PayloadTooLarge len
            y <- takeCE (fromIntegral len) .| foldC
            case runGet (getMessage net) $ x `B.append` y of
                Left e -> throwIO $ CannotDecodePayload e
                Right msg -> do
                    yield msg
                    inPeerConduit net

outPeerConduit :: Monad m => Network -> ConduitT Message ByteString m ()
outPeerConduit net = awaitForever $ yield . runPut . putMessage net
