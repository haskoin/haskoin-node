{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TemplateHaskell       #-}
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
import           Data.String.Conversions
import           Data.Text                   (Text)
import           Network.Haskoin.Constants
import           Network.Haskoin.Network
import           Network.Haskoin.Node.Common
import           Network.Socket              (SockAddr)
import           NQE
import           UnliftIO

peer :: (MonadUnliftIO m, MonadLoggerIO m) => PeerConfig -> Inbox Message -> m ()
peer pc inbox = withConnection a $ \ad -> runReaderT (peer_session ad) pc
  where
    a = peerConfAddress pc
    go =
        forever $
        receive inbox >>= \msg -> do
            $(logDebugS) (peerString a) $
                "Outgoing: " <> cs (commandToString (msgType msg))
            yield msg
    net = peerConfNetwork pc
    p = inboxToMailbox inbox
    peer_session ad = do
        let ins = appSource ad
            ons = appSink ad
            src = runConduit $ ins .| inPeerConduit net a .| mapM_C send_msg
            snk = outPeerConduit net .| ons
        withAsync src $ \as -> do
            link as
            runConduit (go .| snk)
    l = peerConfListen pc
    send_msg msg = atomically . l $ (p, msg)

inPeerConduit ::
       MonadLoggerIO m
    => Network
    -> SockAddr
    -> ConduitT ByteString Message m ()
inPeerConduit net a = do
    x <- takeCE 24 .| foldC
    case decode x of
        Left _ -> do
            $(logErrorS)
                (peerString a)
                "Could not decode incoming message header"
            throwIO DecodeHeaderError
        Right (MessageHeader _ _cmd len _) -> do
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
                    inPeerConduit net a

outPeerConduit :: Monad m => Network -> ConduitT Message ByteString m ()
outPeerConduit net = awaitForever $ yield . runPut . putMessage net

peerString :: SockAddr -> Text
peerString a = "Peer{" <> cs (show a) <> "}"
