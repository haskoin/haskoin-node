{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NoFieldSelectors #-}

module Haskoin.Node
  ( module Haskoin.Node.Peer,
    module Haskoin.Node.PeerMgr,
    module Haskoin.Node.Chain,
    NodeConfig (..),
    NodeEvent (..),
    Node (..),
    withNode,
    withConnection,
  )
where

import Control.Monad (forever)
import Control.Monad.Cont (ContT (..), MonadCont (callCC), cont, lift, runCont, runContT)
import Control.Monad.Logger (MonadLoggerIO)
import Data.Conduit.Network
  ( ClientSettings,
    appSink,
    appSource,
    clientSettings,
    runTCPClient,
  )
import Data.String.Conversions (cs)
import Data.Time.Clock (NominalDiffTime)
import Database.RocksDB (ColumnFamily, DB)
import Haskoin
  ( Addr (..),
    BlockNode (..),
    Headers (..),
    Message (..),
    Network,
    NetworkAddress,
    Ping (..),
    Pong (..),
  )
import Haskoin.Node.Chain
import Haskoin.Node.Peer
import Haskoin.Node.PeerMgr
import NQE
  ( Inbox,
    Publisher,
    publish,
    receive,
    withPublisher,
    withSubscription,
  )
import Network.Socket
  ( NameInfoFlag (..),
    SockAddr,
    getNameInfo,
  )
import Text.Read (readMaybe)
import UnliftIO
  ( MonadUnliftIO,
    SomeException,
    catch,
    liftIO,
    link,
    throwIO,
    withAsync,
  )

-- | General node configuration.
data NodeConfig = NodeConfig
  { -- | maximum number of connected peers allowed
    maxPeers :: !Int,
    -- | database handler
    db :: !DB,
    -- | database column family
    cf :: !(Maybe ColumnFamily),
    -- | static list of peers to connect to
    peers :: ![String],
    -- | activate peer discovery
    discover :: !Bool,
    -- | network address for the local host
    address :: !NetworkAddress,
    -- | network constants
    net :: !Network,
    -- | node events are sent to this publisher
    pub :: !(Publisher NodeEvent),
    -- | timeout in seconds
    timeout :: !NominalDiffTime,
    -- | peer disconnect after seconds
    maxPeerLife :: !NominalDiffTime,
    connect :: !(SockAddr -> WithConnection)
  }

data Node = Node
  { peerMgr :: !PeerMgr,
    chain :: !Chain
  }

data NodeEvent
  = ChainEvent !ChainEvent
  | PeerEvent !PeerEvent
  deriving (Eq)

withConnection :: SockAddr -> WithConnection
withConnection na f =
  fromSockAddr na >>= \case
    Nothing -> throwIO PeerAddressInvalid
    Just cset ->
      runTCPClient cset $ \ad ->
        f (Conduits (appSource ad) (appSink ad))

fromSockAddr ::
  (MonadUnliftIO m) => SockAddr -> m (Maybe ClientSettings)
fromSockAddr sa = go `catch` e
  where
    go = do
      (maybe_host, maybe_port) <- liftIO (getNameInfo flags True True sa)
      return $
        clientSettings
          <$> (readMaybe =<< maybe_port)
          <*> (cs <$> maybe_host)
    flags = [NI_NUMERICHOST, NI_NUMERICSERV]
    e :: (Monad m) => SomeException -> m (Maybe a)
    e _ = return Nothing

chainEvents ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  PeerMgr ->
  Inbox ChainEvent ->
  Publisher NodeEvent ->
  m ()
chainEvents mgr input output = forever $ do
  event <- receive input
  case event of
    ChainBestBlock bb ->
      peerMgrBest bb.height mgr
    _ -> return ()
  publish (ChainEvent event) output

peerEvents ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  Chain ->
  PeerMgr ->
  Inbox PeerEvent ->
  Publisher NodeEvent ->
  m ()
peerEvents ch mgr input output = forever $ do
  event <- receive input
  case event of
    PeerConnected p ->
      chainPeerConnected p ch
    PeerDisconnected p ->
      chainPeerDisconnected p ch
    PeerMessage p msg -> do
      case msg of
        MVersion v ->
          peerMgrVersion p v mgr
        MVerAck ->
          peerMgrVerAck p mgr
        MPing (Ping n) ->
          peerMgrPing p n mgr
        MPong (Pong n) ->
          peerMgrPong p n mgr
        MAddr (Addr ns) ->
          peerMgrAddrs p (map snd ns) mgr
        MHeaders (Headers hs) ->
          chainHeaders p (map fst hs) ch
        _ -> return ()
      peerMgrTickle p mgr
  publish (PeerEvent event) output

-- | Launch node process in the foreground.
withNode ::
  (MonadLoggerIO m, MonadUnliftIO m) =>
  NodeConfig ->
  (Node -> m a) ->
  m a
withNode NodeConfig {..} action = flip runContT return $ do
  peerPub <- ContT withPublisher
  peerSub <- ContT (withSubscription peerPub)
  chainPub <- ContT withPublisher
  chainSub <- ContT (withSubscription chainPub)
  let peerMgrCfg = PeerMgrConfig {pub = peerPub, ..}
  let chainCfg = ChainConfig {pub = chainPub, ..}
  chain <- ContT (withChain chainCfg)
  peerMgr <- ContT $ withPeerMgr peerMgrCfg
  lift . link =<< ContT (withAsync $ chainEvents peerMgr chainSub pub)
  lift . link =<< ContT (withAsync $ peerEvents chain peerMgr peerSub pub)
  lift $ action Node {..}
