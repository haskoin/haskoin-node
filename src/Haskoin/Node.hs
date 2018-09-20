{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
module Haskoin.Node
    ( Host, Port, HostPort
    , Peer, Chain, Manager
    , OnlinePeer(..)
    , NodeConfig(..)
    , NodeEvent(..)
    , ManagerEvent(..)
    , ChainEvent(..)
    , PeerEvent(..)
    , PeerException(..)
    , withNode
    , managerGetPeerVersion
    , managerGetPeers
    , managerGetPeer
    , managerKill
    , setManagerFilter
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
withNode cfg f = do
    c <- newInbox =<< newTQueueIO
    m <- newInbox =<< newTQueueIO
    withAsync (chain (chain_conf c m)) $ \ch ->
        withAsync (manager (manager_conf c m)) $ \mgr -> do
            link ch
            link mgr
            f (m, c)
  where
    chain_conf c m =
        ChainConfig
            { chainConfDB = database cfg
            , chainConfListener = nodeEvents cfg . ChainEvent
            , chainConfManager = m
            , chainConfChain = c
            , chainConfNetwork = nodeNet cfg
            }
    manager_conf c m =
        ManagerConfig
            { mgrConfMaxPeers = maxPeers cfg
            , mgrConfDB = database cfg
            , mgrConfDiscover = discover cfg
            , mgrConfMgrListener = nodeEvents cfg . ManagerEvent
            , mgrConfPeerListener = nodeEvents cfg . PeerEvent
            , mgrConfNetAddr = netAddress cfg
            , mgrConfPeers = initPeers cfg
            , mgrConfManager = m
            , mgrConfChain = c
            , mgrConfNetwork = nodeNet cfg
            , mgrConfConnectInterval = nodeConnectInterval cfg
            , mgrConfStale = nodeStale cfg
            }
