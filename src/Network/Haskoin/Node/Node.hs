{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}
module Network.Haskoin.Node.Node
    ( node
    ) where

import           Control.Concurrent.NQE
import           Control.Monad.Logger
import           Data.String
import           Network.Haskoin.Node.Chain
import           Network.Haskoin.Node.Common
import           Network.Haskoin.Node.Manager
import           UnliftIO

node ::
       ( MonadLoggerIO m
       , MonadUnliftIO m
       )
    => NodeConfig m
    -> m ()
node cfg = do
    psup <- Inbox <$> newTQueueIO
    $(logInfo) $ logMe <> "Starting node"
    supervisor
        KillAll
        (nodeSupervisor cfg)
        [chain chCfg, manager (mgrCfg psup), peerSup psup]
  where
    peerSup psup = supervisor (Notify deadPeer) psup []
    chCfg =
        ChainConfig
        { chainConfDB = database cfg
        , chainConfListener = nodeEvents cfg . ChainEvent
        , chainConfManager = nodeManager cfg
        , chainConfChain = nodeChain cfg
        , chainConfNetwork = nodeNet cfg
        }
    mgrCfg psup =
        ManagerConfig
        { mgrConfMaxPeers = maxPeers cfg
        , mgrConfDB = database cfg
        , mgrConfDiscover = discover cfg
        , mgrConfMgrListener = nodeEvents cfg . ManagerEvent
        , mgrConfPeerListener = nodeEvents cfg . PeerEvent
        , mgrConfNetAddr = netAddress cfg
        , mgrConfPeers = initPeers cfg
        , mgrConfManager = nodeManager cfg
        , mgrConfChain = nodeChain cfg
        , mgrConfPeerSupervisor = psup
        , mgrConfNetwork = nodeNet cfg
        }
    deadPeer ex = PeerStopped ex `sendSTM` nodeManager cfg

logMe :: IsString a => a
logMe = "[Node] "
