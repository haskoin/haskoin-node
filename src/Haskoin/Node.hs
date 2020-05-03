{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-|
Module      : Haskoin.Node
Copyright   : No rights reserved
License     : UNLICENSE
Maintainer  : jprupp@protonmail.ch
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
    , PeerManager
    , ChainMessage(..)
    , PeerManagerMessage(..)
    , PeerMessage(..)
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
    , managerPeerText
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

import           Control.Monad.Logger (MonadLoggerIO)
import           Haskoin              (BlockNode (..), Headers (..),
                                       Message (..))
import           Haskoin.Node.Chain   (chain)
import           Haskoin.Node.Common  (Chain, ChainConfig (..), ChainEvent (..),
                                       ChainMessage (..), Host, HostPort,
                                       NodeConfig (..), NodeEvent (..),
                                       OnlinePeer (..), Peer, PeerEvent (..),
                                       PeerException (..), PeerManager,
                                       PeerManagerConfig (..),
                                       PeerManagerMessage (..),
                                       PeerMessage (..), Port, chainBlockMain,
                                       chainGetAncestor, chainGetBest,
                                       chainGetBlock, chainGetParents,
                                       chainGetSplitBlock, chainIsSynced,
                                       killPeer, managerGetPeer,
                                       managerGetPeers, managerPeerText,
                                       myVersion, peerGetBlocks,
                                       peerGetPublisher, peerGetTxs,
                                       sendMessage)
import           Haskoin.Node.Manager (peerManager)
import           NQE                  (Inbox, inboxToMailbox, newInbox, sendSTM)
import           UnliftIO             (MonadUnliftIO, link, withAsync)

-- | Launch a node in the background. Pass a 'Manager' and 'Chain' to a
-- function. Node will stop once the function ends.
withNode ::
       (MonadLoggerIO m, MonadUnliftIO m)
    => NodeConfig
    -> ((PeerManager, Chain) -> m a)
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
    -> Inbox PeerManagerMessage
    -> Inbox ChainMessage
    -> m ()
node cfg mgr_inbox ch_inbox = do
    let mgr_config =
            ManagerConfig
                { peerManagerMaxPeers = nodeConfMaxPeers cfg
                , peerManagerPeers = nodeConfPeers cfg
                , peerManagerDiscover = nodeConfDiscover cfg
                , peerManagerNetAddr = nodeConfNetAddr cfg
                , peerManagerNetwork = nodeConfNet cfg
                , peerManagerEvents = mgr_events
                , peerManagerTimeout = nodeConfTimeout cfg
                }
    withAsync (peerManager mgr_config mgr_inbox) $ \mgr_async -> do
        link mgr_async
        let chain_config =
                ChainConfig
                    { chainConfDB = nodeConfDB cfg
                    , chainConfNetwork = nodeConfNet cfg
                    , chainConfEvents = chain_events
                    , chainConfTimeout = nodeConfTimeout cfg
                    , chainConfManager = mgr
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
                nodeConfEvents cfg $ PeerEvent event
            PeerDisconnected p a -> do
                ChainPeerDisconnected p a `sendSTM` ch
                nodeConfEvents cfg $ PeerEvent event
            _ -> nodeConfEvents cfg $ PeerEvent event
    chain_events event = do
        nodeConfEvents cfg $ ChainEvent event
        case event of
            ChainBestBlock b ->
                PeerManagerBestBlock (nodeHeight b) `sendSTM` mgr
            _ -> return ()
