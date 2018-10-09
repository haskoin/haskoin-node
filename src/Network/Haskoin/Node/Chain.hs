{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE UndecidableInstances      #-}
{-|
Module      : Network.Haskoin.Node.Chain
Copyright   : No rights reserved
License     : UNLICENSE
Maintainer  : xenog@protonmail.com
Stability   : experimental
Portability : POSIX

Block chain headers synchronizing process.
-}
module Network.Haskoin.Node.Chain
    ( chain
    ) where

import           Control.Monad
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Data.String.Conversions
import           Data.Text                        (Text)
import           Data.Time.Clock
import           Network.Haskoin.Block
import           Network.Haskoin.Network
import           Network.Haskoin.Node.Chain.Logic
import           Network.Haskoin.Node.Common
import           NQE
import           System.Random
import           UnliftIO
import           UnliftIO.Concurrent

type MonadChain m
     = (MonadLoggerIO m, MonadChainLogic ChainConfig Peer m)

-- | Launch process to synchronize block headers in current thread.
chain ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => ChainConfig
    -> Inbox ChainMessage
    -> m ()
chain cfg inbox = do
    st <-
        newTVarIO
            ChainState
                { syncingPeer = Nothing
                , mySynced = False
                , newPeers = []
                }
    let rd = ChainReader {myReader = cfg, myChainDB = db, chainState = st}
    withSyncLoop ch $ run `runReaderT` rd
  where
    net = chainConfNetwork cfg
    db = chainConfDB cfg
    ch = inboxToMailbox inbox
    run = do
        $(logDebugS) "Chain" "Initializing..."
        initChainDB net
        getBestBlockHeader >>= chainEvent . ChainBestBlock
        $(logInfoS) "Chain" "Initialization complete"
        forever $ receive inbox >>= chainMessage

chainEvent :: MonadChain m => ChainEvent -> m ()
chainEvent e = do
    l <- chainConfEvents <$> asks myReader
    case e of
        ChainBestBlock b ->
            $(logInfoS) "Chain" $
            "Best block header at height " <> cs (show (nodeHeight b))
        ChainSynced b ->
            $(logInfoS) "Chain" $
            "Headers now synced at height " <> cs (show (nodeHeight b))
    atomically $ l e

processHeaders ::
       MonadChain m => Peer -> [BlockHeader] -> m ()
processHeaders p hs = do
    s <- peerString p
    net <- chainConfNetwork <$> asks myReader
    mgr <- chainConfManager <$> asks myReader
    $(logDebugS) "Chain" $
        "Importing " <> cs (show (length hs)) <> " headers from peer " <> s
    importHeaders net hs >>= \case
        Left e -> do
            $(logErrorS) "Chain" $
                "Could not connect headers sent by peer " <> s <> ": " <>
                cs (show e)
            managerKill e p mgr
        Right done -> do
            setLastReceived
            best <- getBestBlockHeader
            chainEvent $ ChainBestBlock best
            if done
                then do
                    $(logDebugS) "Chain" $
                        "Finished importing headers from peer: " <> s
                    MSendHeaders `sendMessage` p
                    finishPeer p
                    syncNewPeer
                    syncNotif
                else syncPeer p

syncNewPeer :: MonadChain m => m ()
syncNewPeer = do
    $(logDebugS) "Chain" "Attempting to sync against a new peer"
    getSyncingPeer >>= \case
        Nothing -> do
            $(logDebugS) "Chain" "Getting next peer to sync from"
            nextPeer >>= \case
                Nothing ->
                    $(logInfoS) "Chain" "Finished syncing against all peers"
                Just p -> syncPeer p
        Just p -> do
            s <- peerString p
            $(logDebugS) "Chain" $ "Already syncing against peer " <> s

syncNotif :: MonadChain m => m ()
syncNotif =
    notifySynced >>= \x ->
        when x $ getBestBlockHeader >>= chainEvent . ChainSynced

syncPeer :: MonadChain m => Peer -> m ()
syncPeer p = do
    s <- peerString p
    $(logInfoS) "Chain" $ "Syncing against peer " <> s
    bb <- getBestBlockHeader
    gh <- syncHeaders bb p
    MGetHeaders gh `sendMessage` p

chainMessage :: MonadChain m => ChainMessage -> m ()
chainMessage (ChainGetBest reply) =
    getBestBlockHeader >>= atomically . reply
chainMessage (ChainHeaders p hs) = do
    s <- peerString p
    $(logDebugS) "Chain" $
        "Processing " <> cs (show (length hs)) <> " headers from peer " <> s
    processHeaders p hs
chainMessage (ChainPeerConnected p a) = do
    $(logDebugS) "Chain" $ "Adding new peer to sync queue: " <> cs (show a)
    addPeer p
    syncNewPeer
chainMessage (ChainPeerDisconnected p a) = do
    $(logWarnS) "Chain" $ "Removing a peer from sync queue: " <> cs (show a)
    finishPeer p
    syncNewPeer
chainMessage (ChainGetAncestor h n reply) =
    getAncestor h n >>= atomically . reply
chainMessage (ChainGetSplit r l reply) =
    splitPoint r l >>= atomically . reply
chainMessage (ChainGetBlock h reply) =
    getBlockHeader h >>= atomically . reply
chainMessage (ChainIsSynced reply) =
    isSynced >>= atomically . reply
chainMessage ChainPing = do
    ChainConfig {chainConfManager = mgr, chainConfTimeout = to} <- asks myReader
    now <- liftIO getCurrentTime
    lastMessage >>= \case
        Nothing -> return ()
        Just (p, t)
            | diffUTCTime now t > fromIntegral to -> do
                s <- peerString p
                $(logErrorS) "Chain" $ "Syncing peer timed out: " <> s
                managerKill PeerTimeout p mgr
            | otherwise -> return ()

withSyncLoop :: (MonadUnliftIO m, MonadLoggerIO m) => Chain -> m a -> m a
withSyncLoop ch f = withAsync go $ \a -> link a >> f
  where
    go =
        forever $ do
            threadDelay =<<
                liftIO (randomRIO (250 * 1000, 1000 * 1000))
            ChainPing `send` ch

peerString :: MonadChain m => Peer -> m Text
peerString p = do
    ChainConfig {chainConfManager = mgr} <- asks myReader
    managerGetPeer p mgr >>= \case
        Nothing -> return "[unknown]"
        Just o -> return . cs . show $ onlinePeerAddress o
