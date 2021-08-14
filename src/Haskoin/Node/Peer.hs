{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeFamilies          #-}
module Haskoin.Node.Peer
    ( PeerConfig(..)
    , Conduits(..)
    , PeerException(..)
    , WithConnection
    , Peer
    , peer
    , wrapPeer
    , peerPublisher
    , peerText
    , sendMessage
    , killPeer
    , getBlocks
    , getTxs
    , getData
    , pingPeer
    , getBusy
    , setBusy
    , setFree
    ) where

import           Conduit                   (ConduitT, Void, awaitForever, foldC,
                                            mapM_C, runConduit, takeCE,
                                            transPipe, yield, (.|))
import           Control.Monad             (forever, join, when)
import           Control.Monad.Logger      (MonadLoggerIO, logErrorS)
import           Control.Monad.Trans.Maybe (MaybeT (MaybeT), runMaybeT)
import           Data.ByteString           (ByteString)
import qualified Data.ByteString           as B
import           Data.Function             (on)
import           Data.List                 (union)
import           Data.Maybe                (isJust)
import           Data.Serialize            (decode, runGet, runPut)
import           Data.String.Conversions   (cs)
import           Data.Text                 (Text)
import           Data.Word                 (Word32)
import           Haskoin                   (Block (..), BlockHash (..),
                                            GetData (..), InvType (..),
                                            InvVector (..), Message (..),
                                            MessageCommand (..),
                                            MessageHeader (..), Network (..),
                                            NotFound (..), Ping (..), Pong (..),
                                            Tx, TxHash (..), commandToString,
                                            encodeHex, getMessage, headerHash,
                                            putMessage, txHash)
import           NQE                       (Inbox, Mailbox, Publisher,
                                            inboxToMailbox, publish, receive,
                                            receiveMatchS, send,
                                            withSubscription)
import           System.Random             (randomIO)
import           UnliftIO                  (Exception, MonadIO, MonadUnliftIO,
                                            TVar, atomically, liftIO, link,
                                            readTVar, readTVarIO, throwIO,
                                            timeout, withAsync, withRunInIO,
                                            writeTVar)

data Conduits =
    Conduits
        { inboundConduit  :: ConduitT () ByteString IO ()
        , outboundConduit :: ConduitT ByteString Void IO ()
        }

type WithConnection = (Conduits -> IO ()) -> IO ()

data PeerConfig = PeerConfig
    { peerConfPub     :: !(Publisher (Peer, Message))
    , peerConfNetwork :: !Network
    , peerConfText    :: !Text
    , peerConfConnect :: !WithConnection
    }

data PeerException
    = PeerMisbehaving !String
    | DuplicateVersion
    | DecodeHeaderError
    | CannotDecodePayload !MessageCommand
    | PeerIsMyself
    | PayloadTooLarge !Word32
    | PeerAddressInvalid
    | PeerSentBadHeaders
    | NotNetworkPeer
    | PeerNoSegWit
    | PeerTimeout
    | UnknownPeer
    | PeerTooOld
    deriving Eq

instance Show PeerException where
    show (PeerMisbehaving s)     = "Peer misbehaving: " <> s
    show DuplicateVersion        = "Duplicate version"
    show DecodeHeaderError       = "Error decoding header"
    show (CannotDecodePayload c) = "Cannot decode payload: " <>
                                   cs (commandToString c)
    show PeerIsMyself            = "Peer is myself"
    show (PayloadTooLarge s)     = "Payload too large: " <> show s
    show PeerAddressInvalid      = "Peer address invalid"
    show PeerSentBadHeaders      = "Peer sent bad headers"
    show NotNetworkPeer          = "Not network peer"
    show PeerNoSegWit            = "Segwit not supported by peer"
    show PeerTimeout             = "Peer timed out"
    show UnknownPeer             = "Unknown peer"
    show PeerTooOld              = "Peer too old"

instance Exception PeerException

-- | Mailbox for a peer.
data Peer = Peer { peerMailbox   :: !(Mailbox PeerMessage)
                 , peerPublisher :: !(Publisher (Peer, Message))
                 , peerText      :: !Text
                 , peerBusy      :: !(TVar Bool)
                 }

instance Eq Peer where
    (==) = (==) `on` peerMailbox

instance Show Peer where
    show = cs . peerText

-- | Incoming messages that a peer accepts.
data PeerMessage
    = KillPeer !PeerException
    | SendMessage !Message

wrapPeer :: MonadIO m
         => PeerConfig
         -> TVar Bool
         -> Mailbox PeerMessage
         -> m Peer
wrapPeer cfg busy mbox =
    return Peer { peerMailbox = mbox
                , peerPublisher = peerConfPub cfg
                , peerText = peerConfText cfg
                , peerBusy = busy
                }

-- | Run peer process in current thread.
peer :: (MonadUnliftIO m, MonadLoggerIO m)
     => PeerConfig
     -> TVar Bool
     -> Inbox PeerMessage
     -> m ()
peer cfg busy inbox = do
    p <- wrapPeer cfg busy (inboxToMailbox inbox)
    withRunInIO $ connect . (. peer_session p)
  where
    connect = peerConfConnect cfg
    go = forever $ receive inbox >>= dispatchMessage cfg
    net = peerConfNetwork cfg
    peer_session p ad =
        let ins = transPipe liftIO (inboundConduit ad)
            ons = transPipe liftIO (outboundConduit ad)
            src = runConduit $
                ins
                .| inPeerConduit net (peerConfText cfg)
                .| mapM_C (send_msg p)
            snk = outPeerConduit net .| ons
         in withAsync src $ \as -> do
                link as
                runConduit (go .| snk)
    send_msg p msg = publish (p, msg) (peerConfPub cfg)

-- | Internal function to dispatch peer messages.
dispatchMessage :: MonadLoggerIO m
                => PeerConfig
                -> PeerMessage
                -> ConduitT i Message m ()
dispatchMessage _ (SendMessage msg) = yield msg
dispatchMessage _ (KillPeer e)      = throwIO e

-- | Internal conduit to parse messages coming from peer.
inPeerConduit :: MonadLoggerIO m
              => Network
              -> Text
              -> ConduitT ByteString Message m ()
inPeerConduit net a =
    forever $ do
        x <- takeCE 24 .| foldC
        case decode x of
            Left e -> do
                $(logErrorS) (peerLog a) $
                    "Could not decode message header: " <>
                    encodeHex x
                $(logErrorS) (peerLog a) $
                    "Error: " <> cs e
                throwIO DecodeHeaderError
            Right (MessageHeader _ cmd len _) -> do
                when (len > 32 * 2 ^ (20 :: Int)) $ do
                    $(logErrorS) (peerLog a) "Payload too large"
                    throwIO $ PayloadTooLarge len
                y <- takeCE (fromIntegral len) .| foldC
                case runGet (getMessage net) $ x `B.append` y of
                    Left e -> do
                        $(logErrorS) (peerLog a) $
                            "Cannot decode payload (" <>
                            cs (commandToString cmd) <>
                            "): " <> cs (show e)
                        throwIO (CannotDecodePayload cmd)
                    Right msg -> yield msg

-- | Outgoing peer conduit to serialize and send messages.
outPeerConduit :: Monad m => Network -> ConduitT Message ByteString m ()
outPeerConduit net = awaitForever $ yield . runPut . putMessage net

-- | Kill a peer with the provided exception.
killPeer :: MonadIO m => PeerException -> Peer -> m ()
killPeer e p = KillPeer e `send` peerMailbox p

-- | Send a network message to peer.
sendMessage :: MonadIO m => Message -> Peer -> m ()
sendMessage msg p = SendMessage msg `send` peerMailbox p

getBusy :: MonadIO m => Peer -> m Bool
getBusy p = readTVarIO (peerBusy p)

setBusy :: MonadIO m => Peer -> m Bool
setBusy p =
    atomically $
        readTVar (peerBusy p) >>= \case
            True  -> return False
            False -> writeTVar (peerBusy p) True >>
                     return True

setFree :: MonadIO m => Peer -> m ()
setFree p = atomically $ writeTVar (peerBusy p) False

-- | Request full blocks from peer. Will return 'Nothing' if the list of blocks
-- returned by the peer is incomplete, comes out of order, or a timeout is
-- reached.
getBlocks :: MonadUnliftIO m
          => Network
          -> Int
          -> Peer
          -> [BlockHash]
          -> m (Maybe [Block])
getBlocks net time p bhs =
    runMaybeT $ mapM f =<< MaybeT (getData time p (GetData ivs))
  where
    f (Right b) = return b
    f (Left _)  = MaybeT $ return Nothing
    c
        | getSegWit net = InvWitnessBlock
        | otherwise = InvBlock
    ivs = map (InvVector c . getBlockHash) bhs

-- | Request transactions from peer. Will return 'Nothing' if the list of
-- transactions returned by the peer is incomplete, comes out of order, or a
-- timeout is reached.
getTxs :: MonadUnliftIO m
       => Network
       -> Int
       -> Peer
       -> [TxHash]
       -> m (Maybe [Tx])
getTxs net time p ths =
    runMaybeT $ mapM f =<< MaybeT (getData time p (GetData ivs))
  where
    f (Right _) = MaybeT $ return Nothing
    f (Left t)  = return t
    c
        | getSegWit net = InvWitnessTx
        | otherwise = InvTx
    ivs = map (InvVector c . getTxHash) ths

-- | Request transactions and/or blocks from peer. Return 'Nothing' if any
-- single inventory fails to be retrieved, if they come out of order, or if
-- timeout is reached.
getData :: MonadUnliftIO m
        => Int
        -> Peer
        -> GetData
        -> m (Maybe [Either Tx Block])
getData seconds p gd@(GetData ivs) =
    withSubscription (peerPublisher p) $ \inb -> do
    MGetData gd `sendMessage` p
    r <- liftIO randomIO
    MPing (Ping r) `sendMessage` p
    fmap join . timeout (seconds * 1000 * 1000) .
        runMaybeT $ get_thing inb r [] ivs
  where
    get_thing _inb _r acc [] =
        return $ reverse acc
    get_thing inb r acc hss@(InvVector t h : hs) =
        filterReceive p inb >>= \case
            MTx tx
                | is_tx t && getTxHash (txHash tx) == h ->
                      get_thing inb r (Left tx : acc) hs
            MBlock b@(Block bh _)
                | is_block t && getBlockHash (headerHash bh) == h ->
                      get_thing inb r (Right b : acc) hs
            MNotFound (NotFound nvs)
                | not (null (nvs `union` hs)) ->
                      MaybeT $ return Nothing
            MPong (Pong r')
                | r == r' ->
                      MaybeT $ return Nothing
            _
                | null acc ->
                      get_thing inb r acc hss
                | otherwise ->
                      MaybeT $ return Nothing
    is_tx InvWitnessTx = True
    is_tx InvTx        = True
    is_tx _            = False
    is_block InvWitnessBlock = True
    is_block InvBlock        = True
    is_block _               = False

-- | Ping a peer and await response. Return 'False' if response not received
-- before timeout.
pingPeer :: MonadUnliftIO m => Int -> Peer -> m Bool
pingPeer time p =
    fmap isJust . withSubscription (peerPublisher p) $ \sub -> do
        r <- liftIO randomIO
        MPing (Ping r) `sendMessage` p
        receiveMatchS time sub $ \case
            (p', MPong (Pong r'))
                | p == p' && r == r' -> Just ()
            _ -> Nothing

-- | Peer string for logging
peerLog :: Text -> Text
peerLog = mappend "Peer|"

filterReceive :: MonadIO m => Peer -> Inbox (Peer, Message) -> m Message
filterReceive p inb =
    receive inb >>= \case
        (p', msg) | p == p' -> return msg
        _                   -> filterReceive p inb
