{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE UndecidableInstances      #-}
module Network.Haskoin.Node.Chain
    ( chain
    ) where

import           Control.Monad
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Data.Maybe
import           Data.String.Conversions
import           Data.Time.Clock
import           Network.Haskoin.Block
import           Network.Haskoin.Node.Chain.Logic
import           Network.Haskoin.Network
import           Network.Haskoin.Node.Common
import           NQE
import           System.Random
import           UnliftIO
import           UnliftIO.Concurrent

type MonadChain m = (MonadLoggerIO m, MonadChainLogic ChainConfig Peer m)

chain ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => ChainConfig
    -> Inbox ChainMessage
    -> m ()
chain cfg inbox = do
    now <- liftIO getCurrentTime
    st <-
        newTVarIO
            ChainState
                { syncingPeer = Nothing
                , mySynced = False
                , newPeers = []
                , lastReceived = now
                }
    let rd = ChainReader {myReader = cfg, myChainDB = db, chainState = st}
    withSyncLoop ch $ run `runReaderT` rd
  where
    net = chainConfNetwork cfg
    db = chainConfDB cfg
    ch = inboxToMailbox inbox
    run = do
        initChainDB net
        getBestBlockHeader >>= chainEvent . ChainBestBlock
        $(logInfoS) "Chain" "Initialization complete"
        forever $ receive inbox >>= chainMessage

chainEvent :: MonadChain m => ChainEvent -> m ()
chainEvent e = do
    l <- chainConfEvents <$> asks myReader
    atomically $ l e

processHeaders ::
       MonadChain m => Peer -> [BlockHeader] -> m ()
processHeaders p hs = do
    net <- chainConfNetwork <$> asks myReader
    mgr <- chainConfManager <$> asks myReader
    importHeaders net hs >>= \case
        Left e -> do
            $(logErrorS) "Chain" $ "Could not connect headers: " <> cs (show e)
            managerKill e p mgr
        Right done -> do
            setLastReceived
            best <- getBestBlockHeader
            let h = nodeHeight best
            $(logInfoS) "Chain" $ "New best block at height: " <> cs (show h)
            chainEvent $ ChainBestBlock best
            if done
                then do
                    MSendHeaders `sendMessage` p
                    finishPeer p
                    syncNewPeer
                    syncNotif
                else syncPeer p

syncNewPeer :: MonadChain m => m ()
syncNewPeer = do
    sp <- getSyncingPeer
    when (isNothing sp) $
        nextPeer >>= \case
            Nothing -> return ()
            Just p -> syncPeer p

syncNotif :: MonadChain m => m ()
syncNotif =
    notifySynced >>= \x ->
        when x $ getBestBlockHeader >>= chainEvent . ChainSynced

syncPeer :: MonadChain m => Peer -> m ()
syncPeer p = do
    bb <- getBestBlockHeader
    gh <- syncHeaders bb p
    MGetHeaders gh `sendMessage` p

chainMessage :: MonadChain m => ChainMessage -> m ()
chainMessage (ChainGetBest reply) =
    getBestBlockHeader >>= atomically . reply

chainMessage (ChainHeaders p hs) = processHeaders p hs

chainMessage (ChainPeerConnected p) = do
    addPeer p
    syncNewPeer

chainMessage (ChainPeerDisconnected p) = do
    finishPeer p
    syncNewPeer

chainMessage (ChainGetAncestor h n reply) =
    getAncestor h n >>= atomically . reply

chainMessage (ChainGetSplit r l reply) =
    splitPoint r l >>= atomically . reply

chainMessage (ChainGetBlock h reply) =
    getBlockHeader h >>= atomically . reply

chainMessage (ChainIsSynced reply) = isSynced >>= atomically . reply

chainMessage ChainPing = do
    ChainConfig {chainConfManager = mgr} <- asks myReader
    timeoutPeer >>= \case
        Nothing -> return ()
        Just p -> managerKill PeerTimeout p mgr

withSyncLoop :: (MonadUnliftIO m, MonadLoggerIO m) => Chain -> m a -> m a
withSyncLoop ch f = withAsync go $ \a -> link a >> f
  where
    go =
        forever $ do
            threadDelay =<<
                liftIO (randomRIO (5 * 1000 * 1000, 10 * 1000 * 1000))
            ChainPing `send` ch
