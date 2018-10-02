{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecordWildCards       #-}
module Haskoin.Node
    ( Host
    , Port
    , HostPort
    , Peer
    , Chain
    , Manager
    , OnlinePeer(..)
    , NodeConfig(..)
    , ChainEvent(..)
    , PeerEvent(..)
    , PeerException(..)
    , withNode
    , managerGetPeers
    , managerGetPeer
    , managerKill
    , sendMessage
    , getMerkleBlocks
    , peerGetBlocks
    , peerGetTxs
    , chainGetBlock
    , chainGetBest
    , chainGetAncestor
    , chainGetParents
    , chainGetSplitBlock
    , chainBlockMain
    , chainIsSynced
    , myVersion
    ) where

import           Control.Monad.Logger
import           Network.Haskoin.Node.Chain
import           Network.Haskoin.Node.Common
import           Network.Haskoin.Node.Manager
import           NQE
import           UnliftIO

withNode ::
       ( MonadLoggerIO m
       , MonadUnliftIO m
       )
    => NodeConfig
    -> ((Manager, Chain) -> m a)
    -> m a
withNode NodeConfig {..} f = do
    ch <- newInbox =<< newTQueueIO
    mgr <- newInbox =<< newTQueueIO
    let chain_config =
            ChainConfig
                { chainConfDB = db
                , chainConfManager = mgr
                , chainConfMailbox = ch
                , chainConfNetwork = net
                , chainConfPub = chain_pub
                , chainConfPeerPub = peer_pub
                }
        mgr_config =
            ManagerConfig
                { mgrConfMaxPeers = max_peers
                , mgrConfDB = db
                , mgrConfChain = ch
                , mgrConfPeers = peers
                , mgrConfDiscover = discover
                , mgrConfNetAddr = net_addr
                , mgrConfMailbox = mgr
                , mgrConfNetwork = net
                , mgrConfPub = peer_pub
                }
    withAsync (chain chain_config) $ \a -> do
        link a
        withAsync (manager mgr_config) $ \b -> do
            link b
            f (mgr, ch)
  where
    db = nodeConfDB
    net = nodeConfNet
    chain_pub = nodeConfChainPub
    peer_pub = nodeConfPeerPub
    peers = nodeConfPeers
    discover = nodeConfDiscover
    max_peers = nodeConfMaxPeers
    net_addr = nodeConfNetAddr
