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
import           Control.Monad.Trans.Maybe
import           Data.List
import           Data.Maybe
import           Data.String.Conversions
import           Data.Text                        (Text)
import           Data.Time.Clock.POSIX
import           Network.Haskoin.Block
import           Network.Haskoin.Network
import           Network.Haskoin.Node.Chain.Logic
import           Network.Haskoin.Node.Common
import           Network.Socket                   (SockAddr)
import           NQE
import           System.Random
import           UnliftIO
import           UnliftIO.Concurrent

type MonadChain m
     = (MonadLoggerIO m, MonadChainLogic ChainConfig (Peer, SockAddr) m)

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
                { chainSyncing = Nothing
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
processHeaders p hs =
    void . runMaybeT $ do
        a <- peerAddr p
        let s = peerString a
        net <- chainConfNetwork <$> asks myReader
        $(logDebugS) "Chain" $
            "Importing " <> cs (show (length hs)) <> " headers from peer " <> s
        now <- round <$> liftIO getPOSIXTime
        importHeaders net now hs >>= \case
            Left e -> do
                $(logErrorS) "Chain" $
                    "Could not connect headers sent by peer " <> s <> ": " <>
                    cs (show e)
                e `killPeer` p
            Right done -> do
                setLastReceived now
                best <- getBestBlockHeader
                chainEvent $ ChainBestBlock best
                if done
                    then do
                        $(logDebugS) "Chain" $
                            "Finished importing headers from peer: " <> s
                        MSendHeaders `sendMessage` p
                        case a of
                            Just x -> finishPeer (p, x)
                            Nothing -> return ()
                        syncNewPeer
                        syncNotif
                    else forM_ a (syncPeer p)

syncNewPeer :: MonadChain m => m ()
syncNewPeer = do
    $(logDebugS) "Chain" "Attempting to sync against a new peer"
    getSyncingPeer >>= \case
        Nothing -> do
            $(logDebugS) "Chain" "Getting next peer to sync from"
            nextPeer >>= \case
                Nothing ->
                    $(logInfoS) "Chain" "Finished syncing against all peers"
                Just (p, a) -> syncPeer p a
        Just (_, a) ->
            $(logDebugS) "Chain" $
            "Already syncing against peer " <> peerString (Just a)

syncNotif :: MonadChain m => m ()
syncNotif =
    round <$> liftIO getPOSIXTime >>= notifySynced >>= \x ->
        when x $ getBestBlockHeader >>= chainEvent . ChainSynced

syncPeer :: MonadChain m => Peer -> SockAddr -> m ()
syncPeer p a = do
    $(logInfoS) "Chain" $ "Syncing against peer " <> peerString (Just a)
    bb <- chainSyncingPeer >>= \case
        Just ChainSync {chainSyncPeer = (p', _), chainHighest = Just g}
            | p == p' -> return g
        _ -> getBestBlockHeader
    now <- round <$> liftIO getPOSIXTime
    gh <- syncHeaders now bb (p, a)
    MGetHeaders gh `sendMessage` p

chainMessage :: MonadChain m => ChainMessage -> m ()
chainMessage (ChainGetBest reply) =
    getBestBlockHeader >>= atomically . reply
chainMessage (ChainHeaders p hs) = do
    s <- peerString <$> peerAddr p
    $(logDebugS) "Chain" $
        "Processing " <> cs (show (length hs)) <> " headers from peer " <> s
    processHeaders p hs
chainMessage (ChainPeerConnected p a) = do
    let s = peerString (Just a)
    $(logDebugS) "Chain" $ "Adding new peer to sync queue: " <> s
    addPeer (p, a)
    syncNewPeer
chainMessage (ChainPeerDisconnected p a) = do
    let s = peerString (Just a)
    $(logWarnS) "Chain" $ "Removing a peer from sync queue: " <> s
    finishPeer (p, a)
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
    ChainConfig {chainConfTimeout = to} <- asks myReader
    now <- round <$> liftIO getPOSIXTime
    chainSyncingPeer >>= \case
        Nothing -> return ()
        Just ChainSync {chainSyncPeer = (p, a), chainTimestamp = t}
            | now - t > fromIntegral to -> do
                let s = peerString (Just a)
                $(logErrorS) "Chain" $ "Syncing peer timed out: " <> s
                PeerTimeout `killPeer` p
            | otherwise -> return ()

withSyncLoop :: (MonadUnliftIO m, MonadLoggerIO m) => Chain -> m a -> m a
withSyncLoop ch f = withAsync go $ \a -> link a >> f
  where
    go =
        forever $ do
            threadDelay =<<
                liftIO (randomRIO (250 * 1000, 1000 * 1000))
            ChainPing `send` ch

peerAddr :: MonadChain m => Peer -> m (Maybe SockAddr)
peerAddr p =
    asks chainState >>= readTVarIO >>= \s ->
        let ps = newPeers s <> maybeToList (chainSyncPeer <$> chainSyncing s)
         in return $ snd <$> find ((== p) . fst) ps

peerString :: Maybe SockAddr -> Text
peerString Nothing  = "[unknown]"
peerString (Just a) = cs $ show a
