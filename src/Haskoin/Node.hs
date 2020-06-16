{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
module Haskoin.Node
    ( module Haskoin.Node.Peer
    , module Haskoin.Node.Manager
    , module Haskoin.Node.Chain
    , NodeConfig (..)
    , NodeEvent (..)
    , Node (..)
    , withNode
    , withConnection
    ) where

import           Control.Monad           (forever)
import           Control.Monad.Logger    (MonadLoggerIO)
import           Data.Conduit.Network    (appSink, appSource, clientSettings,
                                          runTCPClient)
import           Data.String.Conversions (cs)
import           Data.Time.Clock         (NominalDiffTime)
import           Database.RocksDB        (DB)
import           Haskoin                 (Addr (..), BlockNode (..),
                                          Headers (..), Message (..), Network,
                                          NetworkAddress, Ping (..), Pong (..))
import           Haskoin.Node.Chain
import           Haskoin.Node.Manager
import           Haskoin.Node.Peer
import           Network.Socket          (NameInfoFlag (..), SockAddr,
                                          getNameInfo)
import           NQE                     (Inbox, Publisher, publish, receive,
                                          withPublisher, withSubscription)
import           Text.Read               (readMaybe)
import           UnliftIO                (MonadUnliftIO, SomeException, catch,
                                          liftIO, link, throwIO, withAsync)

-- | General node configuration.
data NodeConfig = NodeConfig
    { nodeConfMaxPeers    :: !Int
      -- ^ maximum number of connected peers allowed
    , nodeConfDB          :: !DB
      -- ^ database handler
    , nodeConfPeers       :: ![HostPort]
      -- ^ static list of peers to connect to
    , nodeConfDiscover    :: !Bool
      -- ^ activate peer discovery
    , nodeConfNetAddr     :: !NetworkAddress
      -- ^ network address for the local host
    , nodeConfNet         :: !Network
      -- ^ network constants
    , nodeConfEvents      :: !(Publisher NodeEvent)
      -- ^ node events are sent to this publisher
    , nodeConfTimeout     :: !NominalDiffTime
      -- ^ timeout in seconds
    , nodeConfPeerMaxLife :: !NominalDiffTime
      -- ^ peer disconnect after seconds
    , nodeConfConnect     :: !(SockAddr -> WithConnection)
    }

data Node = Node { nodeManager :: !PeerManager
                 , nodeChain   :: !Chain
                 }

data NodeEvent
    = ChainEvent !ChainEvent
    | PeerEvent !PeerEvent
    | PeerMessage !Peer !Message
    deriving Eq

withConnection :: SockAddr -> WithConnection
withConnection na f =
    fromSockAddr na >>= \case
        Nothing -> throwIO PeerAddressInvalid
        Just (host, port) -> do
            let cset = clientSettings port (cs host)
            runTCPClient cset $ \ad ->
                f (Conduits (appSource ad) (appSink ad))

fromSockAddr ::
       (MonadUnliftIO m) => SockAddr -> m (Maybe HostPort)
fromSockAddr sa = go `catch` e
  where
    go = do
        (maybe_host, maybe_port) <- liftIO (getNameInfo flags True True sa)
        return $ (,) <$> maybe_host <*> (readMaybe =<< maybe_port)
    flags = [NI_NUMERICHOST, NI_NUMERICSERV]
    e :: Monad m => SomeException -> m (Maybe a)
    e _ = return Nothing

chainForwarder :: MonadLoggerIO m
               => PeerManager
               -> Publisher NodeEvent
               -> Inbox ChainEvent
               -> m ()
chainForwarder mgr pub inbox =
    forever $ receive inbox >>= \event -> do
        case event of
            ChainBestBlock bb ->
                managerBest (nodeHeight bb) mgr
            _ -> return ()
        publish (ChainEvent event) pub

managerForwarder :: MonadLoggerIO m
                 => Chain
                 -> Publisher NodeEvent
                 -> Inbox PeerEvent
                 -> m ()
managerForwarder ch pub inbox =
    forever $ receive inbox >>= \event -> do
        case event of
            PeerConnected p ->
                chainPeerConnected p ch
            PeerDisconnected p ->
                chainPeerDisconnected p ch
        publish (PeerEvent event) pub

peerForwarder :: MonadLoggerIO m
              => Chain
              -> PeerManager
              -> Publisher NodeEvent
              -> Inbox (Peer, Message)
              -> m ()
peerForwarder ch mgr pub inbox =
    forever $ receive inbox >>= \(p, msg) -> do
        case msg of
            MVersion v ->
                managerVersion p v mgr
            MVerAck ->
                managerVerAck p mgr
            MPing (Ping n) ->
                managerPing p n mgr
            MPong (Pong n) ->
                managerPong p n mgr
            MAddr (Addr ns) ->
                managerAddrs p (map snd ns) mgr
            MHeaders (Headers hs) ->
                chainHeaders p (map fst hs) ch
            _ -> return ()
        publish (PeerMessage p msg) pub

-- | Launch node process in the foreground.
withNode ::
       ( MonadLoggerIO m
       , MonadUnliftIO m
       )
    => NodeConfig
    -> (Node -> m a)
    -> m a
withNode cfg action =
    withPublisher $ \peer_pub ->
    withPublisher $ \mgr_pub ->
    withPublisher $ \ch_pub ->
    withSubscription peer_pub $ \peer_inbox ->
    withSubscription mgr_pub $ \mgr_inbox ->
    withSubscription ch_pub $ \ch_inbox ->
    withPeerManager (mgr_config mgr_pub peer_pub) $ \mgr ->
    withChain (chain_config ch_pub) $ \ch ->
    withAsync (peerForwarder ch mgr pub peer_inbox) $ \a ->
    withAsync (managerForwarder ch pub mgr_inbox) $ \b ->
    withAsync (chainForwarder mgr pub ch_inbox) $ \c ->
    link a >> link b >> link c >>
    action Node { nodeManager = mgr, nodeChain = ch }
  where
    pub = nodeConfEvents cfg
    chain_config ch_pub =
        ChainConfig
            { chainConfDB = nodeConfDB cfg
            , chainConfNetwork = nodeConfNet cfg
            , chainConfEvents = ch_pub
            , chainConfTimeout = nodeConfTimeout cfg
            }
    mgr_config mgr_pub peer_pub =
        PeerManagerConfig
            { peerManagerMaxPeers = nodeConfMaxPeers cfg
            , peerManagerPeers = nodeConfPeers cfg
            , peerManagerDiscover = nodeConfDiscover cfg
            , peerManagerNetAddr = nodeConfNetAddr cfg
            , peerManagerNetwork = nodeConfNet cfg
            , peerManagerEvents = mgr_pub
            , peerManagerMaxLife = nodeConfPeerMaxLife cfg
            , peerManagerConnect = nodeConfConnect cfg
            , peerManagerPub = peer_pub
            }
