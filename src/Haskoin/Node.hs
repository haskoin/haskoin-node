{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-|
Module      : Haskoin.Node
Copyright   : No rights reserved
License     : UNLICENSE
Maintainer  : xenog@protonmail.com
Stability   : experimental
Portability : POSIX

Integrates peers, manager, and block header synchronization processes.

Messages from peers that aren't consumed by the peer manager or chain are
forwarded to the listen action provided in the node configuration.
-}
module Haskoin.Node
    ( Host
    , Port
    , HostPort
    , Peer
    , Chain
    , Manager
    , ChainMessage
    , ManagerMessage
    , OnlinePeer(..)
    , NodeConfig(..)
    , NodeEvent(..)
    , ChainEvent(..)
    , PeerEvent(..)
    , PeerException(..)
    , withNode
    , node
    , managerGetPeers
    , managerGetPeer
    , killPeer
    , sendMessage
    , peerGetPublisher
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

-- | Launch a node in the background. Pass a 'Manager' and 'Chain' to a
-- function. Node will stop once the function ends.
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

-- | Launch node process in the foreground.
node ::
       ( MonadLoggerIO m
       , MonadUnliftIO m
       )
    => NodeConfig
    -> Inbox ManagerMessage
    -> Inbox ChainMessage
    -> m ()
node cfg mgr_inbox ch_inbox = do
    let mgr_config =
            ManagerConfig
                { mgrConfMaxPeers = nodeConfMaxPeers cfg
                , mgrConfDB = nodeConfDB cfg
                , mgrConfPeers = nodeConfPeers cfg
                , mgrConfDiscover = nodeConfDiscover cfg
                , mgrConfNetAddr = nodeConfNetAddr cfg
                , mgrConfNetwork = nodeConfNet cfg
                , mgrConfEvents = mgr_events
                , mgrConfTimeout = nodeConfTimeout cfg
                }
    withAsync (manager mgr_config mgr_inbox) $ \mgr_async -> do
        link mgr_async
        let chain_config =
                ChainConfig
                    { chainConfDB = nodeConfDB cfg
                    , chainConfNetwork = nodeConfNet cfg
                    , chainConfEvents = chain_events
                    , chainConfTimeout = nodeConfTimeout cfg
                    }
        chain chain_config ch_inbox
  where
    ch = inboxToMailbox ch_inbox
    mgr = inboxToMailbox mgr_inbox
    mgr_events event =
        case event of
            PeerMessage p (MHeaders (Headers hcs)) ->
                ChainHeaders p (map fst hcs) `sendSTM` ch
            PeerConnected p a -> do
                ChainPeerConnected p a `sendSTM` ch
                Event (PeerEvent event) `sendSTM` nodeConfEvents cfg
            PeerDisconnected p a -> do
                ChainPeerDisconnected p a `sendSTM` ch
                Event (PeerEvent event) `sendSTM` nodeConfEvents cfg
            _ -> Event (PeerEvent event) `sendSTM` nodeConfEvents cfg
    chain_events event = do
        Event (ChainEvent event) `sendSTM` nodeConfEvents cfg
        case event of
            ChainBestBlock b -> ManagerBestBlock (nodeHeight b) `sendSTM` mgr
            _ -> return ()
