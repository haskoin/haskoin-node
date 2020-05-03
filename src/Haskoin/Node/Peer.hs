{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
{-|
Module      : Network.Haskoin.Node.Peer
Copyright   : No rights reserved
License     : UNLICENSE
Maintainer  : jprupp@protonmail.ch
Stability   : experimental
Portability : POSIX

Network peer process. Represents a network peer connection locally.
-}
module Haskoin.Node.Peer
    ( peer
    ) where

import           Conduit                 (ConduitT, awaitForever, foldC, mapM_C,
                                          runConduit, takeCE, yield, (.|))
import           Control.Monad           (forever, when)
import           Control.Monad.Logger    (MonadLoggerIO, logErrorS)
import           Control.Monad.Reader    (runReaderT)
import           Data.ByteString         (ByteString)
import qualified Data.ByteString         as B
import           Data.Conduit.Network    (appSink, appSource)
import           Data.Serialize          (decode, runGet, runPut)
import           Data.String.Conversions (cs)
import           Haskoin                 (Message, MessageHeader (..), Network,
                                          getMessage, putMessage)
import           Haskoin.Node.Common     (PeerConfig (..), PeerException (..),
                                          PeerMessage (..), peerString,
                                          withConnection)
import           Network.Socket          (SockAddr)
import           NQE                     (Inbox, PublisherMessage (..), receive,
                                          send)
import           UnliftIO                (MonadUnliftIO, atomically, link,
                                          throwIO, withAsync)

-- | Run peer process in current thread.
peer ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => PeerConfig
    -> Inbox PeerMessage
    -> m ()
peer pc inbox = withConnection a $ \ad -> runReaderT (peer_session ad) pc
  where
    a = peerConfAddress pc
    go = forever $ do
      receive inbox >>= dispatchMessage pc
    net = peerConfNetwork pc
    peer_session ad =
        let ins = appSource ad
            ons = appSink ad
            src = runConduit $ ins .| inPeerConduit net a .| mapM_C send_msg
            snk = outPeerConduit net .| ons
         in withAsync src $ \as -> do
                link as
                runConduit (go .| snk)
    send_msg = (`send` peerConfListen pc) . Event

-- | Internal function to dispatch peer messages.
dispatchMessage ::
       MonadLoggerIO m => PeerConfig -> PeerMessage -> ConduitT i Message m ()
dispatchMessage _ (SendMessage msg) = yield msg
dispatchMessage cfg (GetPublisher reply) =
    atomically (reply (peerConfListen cfg))
dispatchMessage _ (KillPeer e) = throwIO e

-- | Internal conduit to parse messages coming from peer.
inPeerConduit ::
       MonadLoggerIO m
    => Network
    -> SockAddr
    -> ConduitT ByteString Message m ()
inPeerConduit net a =
    forever $ do
        x <- takeCE 24 .| foldC
        case decode x of
            Left e -> do
                $(logErrorS) (peerString a) $
                    "Could not decode incoming message header: " <> cs e
                throwIO DecodeHeaderError
            Right (MessageHeader _ _ len _) -> do
                when (len > 32 * 2 ^ (20 :: Int)) $ do
                    $(logErrorS) (peerString a) "Payload too large"
                    throwIO $ PayloadTooLarge len
                y <- takeCE (fromIntegral len) .| foldC
                case runGet (getMessage net) $ x `B.append` y of
                    Left e -> do
                        $(logErrorS) (peerString a) $
                            "Cannot decode payload: " <> cs (show e)
                        throwIO CannotDecodePayload
                    Right msg -> yield msg

-- | Outgoing peer conduit to serialize and send messages.
outPeerConduit :: Monad m => Network -> ConduitT Message ByteString m ()
outPeerConduit net = awaitForever $ yield . runPut . putMessage net
