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
Maintainer  : xenog@protonmail.com
Stability   : experimental
Portability : POSIX

Network peer process. Represents a network peer connection locally.
-}
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
import           Data.String.Conversions
import           Data.Text                   (Text)
import           Network.Haskoin.Constants
import           Network.Haskoin.Network
import           Network.Haskoin.Node.Common
import           Network.Socket              (SockAddr)
import           NQE
import           UnliftIO

-- | Run peer process in current thread.
peer ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => PeerConfig
    -> Inbox PeerMessage
    -> m ()
peer pc inbox = withConnection a $ \ad -> runReaderT (peer_session ad) pc
  where
    a = peerConfAddress pc
    go = forever $ receive inbox >>= dispatchMessage pc
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
dispatchMessage cfg (SendMessage msg) = do
    $(logDebugS) (peerString (peerConfAddress cfg)) $
        "Outgoing: " <> cs (commandToString (msgType msg))
    yield msg
dispatchMessage cfg (GetPublisher reply) =
    atomically $ reply (peerConfListen cfg)
dispatchMessage _ (KillPeer e) =
    throwIO e

-- | Internal conduit to parse messages coming from peer.
inPeerConduit ::
       MonadLoggerIO m
    => Network
    -> SockAddr
    -> ConduitT ByteString Message m ()
inPeerConduit net a = forever $ do
    x <- takeCE 24 .| foldC
    case decode x of
        Left _ -> do
            $(logErrorS)
                (peerString a)
                "Could not decode incoming message header"
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
                Right msg -> do
                    $(logDebugS) (peerString a) $
                        "Incoming: " <> cs (commandToString (msgType msg))
                    yield msg

-- | Outgoing peer conduit to serialize and send messages.
outPeerConduit :: Monad m => Network -> ConduitT Message ByteString m ()
outPeerConduit net = awaitForever $ yield . runPut . putMessage net

-- | Peer string for logging
peerString :: SockAddr -> Text
peerString a = "Peer{" <> cs (show a) <> "}"
