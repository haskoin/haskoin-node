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
    , NodeEvent(..)
    , ChainEvent(..)
    , PeerEvent(..)
    , PeerException(..)
    , withNode
    , managerGetPeers
    , managerGetPeer
    , managerKill
    , sendMessage
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
import           Haskoin
import           Network.Haskoin.Node.Chain
import           Network.Haskoin.Node.Common
import           Network.Haskoin.Node.Manager
import           NQE
import           UnliftIO

withNode ::
       (MonadLoggerIO m, MonadUnliftIO m)
    => NodeConfig
    -> ((Manager, Chain) -> m a)
    -> m a
withNode cfg f = do
    mgr_inbox <- newInbox
    ch_inbox <- newInbox
    withAsync (node cfg mgr_inbox ch_inbox) $ \a -> do
        link a
        f (inboxToMailbox mgr_inbox, inboxToMailbox ch_inbox)

node ::
       ( MonadLoggerIO m
       , MonadUnliftIO m
       )
    => NodeConfig
    -> Inbox ManagerMessage
    -> Inbox ChainMessage
    -> m ()
node NodeConfig {..} mgr_inbox ch_inbox = do
    let mgr_config =
            ManagerConfig
                { mgrConfMaxPeers = nodeConfMaxPeers
                , mgrConfDB = nodeConfDB
                , mgrConfPeers = nodeConfPeers
                , mgrConfDiscover = nodeConfDiscover
                , mgrConfNetAddr = nodeConfNetAddr
                , mgrConfNetwork = nodeConfNet
                , mgrConfEvents = mgr_events
                }
    withAsync (manager mgr_config mgr_inbox) $ \mgr_async -> do
        link mgr_async
        let chain_config =
                ChainConfig
                    { chainConfDB = nodeConfDB
                    , chainConfManager = mgr
                    , chainConfNetwork = nodeConfNet
                    , chainConfEvents = chain_events
                    }
        chain chain_config ch_inbox
  where
    ch = inboxToMailbox ch_inbox
    mgr = inboxToMailbox mgr_inbox
    mgr_events event =
        case event of
            PeerMessage p (MHeaders (Headers hcs)) ->
                ChainHeaders p (map fst hcs) `sendSTM` ch
            PeerConnected p -> do
                ChainPeerConnected p `sendSTM` ch
                nodeConfEvents $ PeerEvent event
            PeerDisconnected p -> do
                ChainPeerDisconnected p `sendSTM` ch
                nodeConfEvents $ PeerEvent event
            _ -> nodeConfEvents $ PeerEvent event
    chain_events event = do
        nodeConfEvents $ ChainEvent event
        case event of
            ChainBestBlock b -> ManagerBestBlock (nodeHeight b) `sendSTM` mgr
            _ -> return ()
