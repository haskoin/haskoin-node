{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
{-|
Module      : Network.Haskoin.Node.Manager
Copyright   : No rights reserved
License     : UNLICENSE
Maintainer  : xenog@protonmail.com
Stability   : experimental
Portability : POSIX

Peer manager process.
-}
module Network.Haskoin.Node.Manager
    ( manager
    ) where

import           Conduit
import           Control.Applicative
import           Control.Monad
import           Control.Monad.Except
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.Trans.Maybe
import           Data.String.Conversions
import           Data.Time.Clock
import           Data.Time.Clock.POSIX
import           Database.RocksDB                   (DB)
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Network
import           Network.Haskoin.Node.Common
import           Network.Haskoin.Node.Manager.Logic
import           Network.Haskoin.Node.Peer
import           Network.Socket                     (SockAddr (..))
import           NQE
import           System.Random
import           UnliftIO
import           UnliftIO.Concurrent

-- | Monad used by most functions in this module.
type MonadManager m = (MonadLoggerIO m, MonadReader ManagerReader m)

-- | Reader for peer configuration and state.
data ManagerReader = ManagerReader
    { myConfig     :: !ManagerConfig
    , mySupervisor :: !Supervisor
    , myMailbox    :: !Manager
    , myBestBlock  :: !(TVar BlockHeight)
    , onlinePeers  :: !(TVar [OnlinePeer])
    }

-- | Peer Manager process. In order to fully start it needs to receive a
-- 'ManageBestBlock' event.
manager ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => ManagerConfig
    -> Inbox ManagerMessage
    -> m ()
manager cfg inbox =
    withSupervisor (Notify f) $ \sup -> do
        bb <- newTVarIO 0
        ob <- newTVarIO []
        let rd =
                ManagerReader
                    { myConfig = cfg
                    , mySupervisor = sup
                    , myMailbox = mgr
                    , myBestBlock = bb
                    , onlinePeers = ob
                    }
        go `runReaderT` rd
  where
    mgr = inboxToMailbox inbox
    discover = mgrConfDiscover cfg
    go = do
        db <- getManagerDB
        $(logDebugS) "Manager" "Initializing..."
        initPeerDB db discover
        putBestBlock <=< receiveMatch inbox $ \case
            ManagerBestBlock b -> Just b
            _ -> Nothing
        $(logDebugS) "Manager" "Initialization complete"
        withConnectLoop mgr $ \a -> do
            link a
            forever $ receive inbox >>= managerMessage
    f (a, mex) = ManagerPeerDied a mex `sendSTM` mgr

putBestBlock :: MonadManager m => BlockHeight -> m ()
putBestBlock bb = asks myBestBlock >>= \b -> atomically $ writeTVar b bb

getBestBlock :: MonadManager m => m BlockHeight
getBestBlock = asks myBestBlock >>= readTVarIO

getNetwork :: MonadManager m => m Network
getNetwork = mgrConfNetwork <$> asks myConfig

populatePeerDB :: (MonadUnliftIO m, MonadManager m) => m ()
populatePeerDB = do
    ManagerConfig { mgrConfPeers = statics
                  , mgrConfDB = db
                  , mgrConfDiscover = discover
                  } <- asks myConfig
    cfg_peers <- concat <$> mapM toSockAddr statics
    forM_ cfg_peers $ newPeerDB db staticPeerScore
    when discover $ do
        net <- getNetwork
        net_seeds <- concat <$> mapM toSockAddr (networkSeeds net)
        forM_ net_seeds $ newPeerDB db netSeedScore

logConnectedPeers :: MonadManager m => m ()
logConnectedPeers = do
    m <- mgrConfMaxPeers <$> asks myConfig
    l <- length <$> getConnectedPeers
    $(logInfoS) "Manager" $
        "Peers connected: " <> cs (show l) <> "/" <> cs (show m)

getManagerDB :: MonadManager m => m DB
getManagerDB = mgrConfDB <$> asks myConfig

getOnlinePeers :: MonadManager m => m [OnlinePeer]
getOnlinePeers = asks onlinePeers >>= readTVarIO

getConnectedPeers :: MonadManager m => m [OnlinePeer]
getConnectedPeers = filter onlinePeerConnected <$> getOnlinePeers

purgePeers :: (MonadUnliftIO m, MonadManager m) => m ()
purgePeers = do
    db <- getManagerDB
    ops <- getOnlinePeers
    forM_ ops $ \OnlinePeer {onlinePeerMailbox = p} -> killPeer PurgingPeer p
    purgePeerDB db

forwardMessage :: MonadManager m => Peer -> Message -> m ()
forwardMessage p msg = managerEvent $ PeerMessage p msg

managerEvent :: MonadManager m => PeerEvent -> m ()
managerEvent e = mgrConfEvents <$> asks myConfig >>= \l -> atomically $ l e

managerMessage :: (MonadUnliftIO m, MonadManager m) => ManagerMessage -> m ()
managerMessage (ManagerPeerMessage p (MVersion v)) = do
    b <- asks onlinePeers
    s <- atomically $ peerString b p
    e <-
        runExceptT $ do
            let ua = getVarString $ userAgent v
            $(logDebugS) "Manager" $
                "Got version from peer " <> s <> ": " <> cs ua
            o <- ExceptT . atomically $ setPeerVersion b p v
            when (onlinePeerConnected o) $ announcePeer p
    case e of
        Right () -> do
            $(logDebugS) "Manager" $ "Version accepted for peer " <> s
            MVerAck `sendMessage` p
        Left x -> do
            $(logErrorS) "Manager" $
                "Version rejected for peer " <> s <> ": " <> cs (show x)
            killPeer x p
managerMessage (ManagerPeerMessage p MVerAck) = do
    b <- asks onlinePeers
    s <- atomically $ peerString b p
    atomically (setPeerVerAck b p) >>= \case
        Just o -> do
            $(logDebugS) "Manager" $ "Received verack from peer: " <> s
            when (onlinePeerConnected o) $ announcePeer p
        Nothing -> do
            $(logErrorS) "Manager" $ "Received verack from unknown peer: " <> s
            killPeer UnknownPeer p
managerMessage (ManagerPeerMessage p (MAddr (Addr nas))) = do
    db <- getManagerDB
    b <- asks onlinePeers
    s <- atomically $ peerString b p
    $(logInfoS) "Manager" $
        "Received " <> cs (show (length nas)) <> " peers from " <> s
    let sas = map (naAddress . snd) nas
    forM_ sas $ newPeerDB db netPeerScore
managerMessage (ManagerPeerMessage p msg@(MPong (Pong n))) = do
    now <- liftIO getCurrentTime
    b <- asks onlinePeers
    s <- atomically $ peerString b p
    atomically (gotPong b n now p) >>= \case
        Nothing -> do
            $(logDebugS) "Manager" $
                "Forwarding pong " <> cs (show n) <> " from " <> s
            forwardMessage p msg
        Just d -> do
            let ms = fromRational . toRational $ d * 1000 :: Double
            $(logDebugS) "Manager" $
                "Ping roundtrip to " <> s <> " took " <>
                cs (show ms) <> " ms"
managerMessage (ManagerPeerMessage p (MPing (Ping n))) = do
    b <- asks onlinePeers
    s <- atomically $ peerString b p
    $(logDebugS) "Manager" $
        "Responding to ping " <> cs (show n) <> " from " <> s
    MPong (Pong n) `sendMessage` p
managerMessage (ManagerPeerMessage p msg) = do
    b <- asks onlinePeers
    s <- atomically $ peerString b p
    let cmd = commandToString $ msgType msg
    $(logDebugS) "Manager" $
        "Forwarding message " <> cs cmd <> " from peer " <> s
    forwardMessage p msg
managerMessage (ManagerBestBlock h) = putBestBlock h
managerMessage ManagerConnect = do
    l <- length <$> getConnectedPeers
    x <- mgrConfMaxPeers <$> asks myConfig
    when (l < x) $
        getNewPeer >>= \case
            Nothing -> return ()
            Just sa -> connectPeer sa
managerMessage (ManagerPeerDied a e) = processPeerOffline a e
managerMessage ManagerPurgePeers = do
    $(logWarnS) "Manager" "Purging connected peers and peer database"
    purgePeers
managerMessage (ManagerGetPeers reply) =
    getConnectedPeers >>= atomically . reply
managerMessage (ManagerGetOnlinePeer p reply) = do
    b <- asks onlinePeers
    atomically $ findPeer b p >>= reply
managerMessage (ManagerCheckPeer p) = checkPeer p

checkPeer :: MonadManager m => Peer -> m ()
checkPeer p = do
    ManagerConfig {mgrConfTimeout = to} <- asks myConfig
    b <- asks onlinePeers
    s <- atomically $ peerString b p
    atomically (lastPing b p) >>= \case
        Nothing -> pingPeer p
        Just t -> do
            now <- liftIO getCurrentTime
            if diffUTCTime now t > fromIntegral to
                then do
                    $(logErrorS) "Manager" $
                        "Peer " <> s <> " did not respond ping on time"
                    killPeer PeerTimeout p
                else $(logDebugS) "Manager" $ "peer " <> s <> " awaiting pong"

pingPeer :: MonadManager m => Peer -> m ()
pingPeer p = do
    b <- asks onlinePeers
    s <- atomically $ peerString b p
    atomically (findPeer b p) >>= \case
        Nothing -> $(logErrorS) "Manager" $ "Will not ping unknown peer " <> s
        Just o
            | onlinePeerConnected o -> do
                n <- liftIO randomIO
                now <- liftIO getCurrentTime
                atomically (setPeerPing b n now p)
                $(logDebugS) "Manager" $
                    "Sending ping " <> cs (show n) <> " to peer " <> s
                MPing (Ping n) `sendMessage` p
            | otherwise ->
                $(logWarnS) "Manager" $
                "Will not ping peer " <> s <> " until handshake complete"

processPeerOffline :: MonadManager m => Child -> Maybe SomeException -> m ()
processPeerOffline a e = do
    b <- asks onlinePeers
    atomically (findPeerAsync b a) >>= \case
        Nothing -> log_unknown e
        Just o -> do
            let p = onlinePeerMailbox o
                d = onlinePeerAddress o
            s <- atomically $ peerString b p
            if onlinePeerConnected o
                then do
                    log_disconnected s e
                    managerEvent $ PeerDisconnected p d
                else log_not_connect s e
            atomically $ removePeer b p
            db <- getManagerDB
            demotePeerDB db (onlinePeerAddress o)
            logConnectedPeers
  where
    log_unknown Nothing = $(logErrorS) "Manager" "Disconnected unknown peer"
    log_unknown (Just x) =
        $(logErrorS) "Manager" $ "Unknown peer died: " <> cs (show x)
    log_disconnected s Nothing =
        $(logWarnS) "Manager" $ "Disconnected peer: " <> s
    log_disconnected s (Just x) =
        $(logErrorS) "Manager" $ "Peer " <> s <> " died: " <> cs (show x)
    log_not_connect s Nothing =
        $(logWarnS) "Manager" $ "Could not connect to peer " <> s
    log_not_connect s (Just x) =
        $(logErrorS) "Manager" $
        "Could not connect to peer " <> s <> ": " <> cs (show x)

announcePeer :: MonadManager m => Peer -> m ()
announcePeer p = do
    b <- asks onlinePeers
    s <- atomically $ peerString b p
    mgr <- asks myMailbox
    atomically (findPeer b p) >>= \case
        Just OnlinePeer {onlinePeerAddress = a, onlinePeerConnected = True} -> do
            $(logInfoS) "Manager" $ "Handshake completed for peer " <> s
            managerEvent $ PeerConnected p a
            logConnectedPeers
            managerCheck p mgr
            db <- getManagerDB
            promotePeerDB db a
        Just OnlinePeer {onlinePeerConnected = False} ->
            $(logErrorS) "Manager" $
            "Not announcing because not handshaken: " <> s
        Nothing -> $(logErrorS) "Manager" "Will not announce unknown peer"

getNewPeer :: (MonadUnliftIO m, MonadManager m) => m (Maybe SockAddr)
getNewPeer = do
    ManagerConfig {mgrConfDB = db} <- asks myConfig
    exclude <- map onlinePeerAddress <$> getOnlinePeers
    m <-
        runMaybeT $
        MaybeT (getNewPeerDB db exclude) <|>
        MaybeT (populatePeerDB >> getNewPeerDB db exclude)
    case m of
        Just a -> return $ Just a
        Nothing -> return Nothing

connectPeer :: (MonadUnliftIO m, MonadManager m) => SockAddr -> m ()
connectPeer sa = do
    $(logInfoS) "Manager" $ "Connecting to peer: " <> cs (show sa)
    ManagerConfig {mgrConfNetAddr = ad, mgrConfNetwork = net} <- asks myConfig
    mgr <- asks myMailbox
    sup <- asks mySupervisor
    nonce <- liftIO randomIO
    bb <- getBestBlock
    now <- round <$> liftIO getPOSIXTime
    let rmt = NetworkAddress (srv net) sa
        ver = buildVersion net nonce bb ad rmt now
    (inbox, p) <- newMailbox
    let pc pub =
            PeerConfig
                { peerConfListen = pub
                , peerConfNetwork = net
                , peerConfAddress = sa
                }
    a <- withRunInIO $ \io -> sup `addChild` io (launch mgr pc inbox p)
    MVersion ver `sendMessage` p
    b <- asks onlinePeers
    _ <- atomically $ newOnlinePeer b sa nonce p a
    return ()
  where
    l mgr p m = ManagerPeerMessage p m `sendSTM` mgr
    srv net
        | getSegWit net = 8
        | otherwise = 0
    launch mgr pc inbox p =
        withPublisher $ \pub ->
            bracket (subscribe pub (l mgr p)) (unsubscribe pub) $ \_ ->
                withPeerLoop p mgr $ \a -> do
                    link a
                    peer (pc pub) inbox

withPeerLoop :: MonadUnliftIO m => Peer -> Manager -> (Async a -> m a) -> m a
withPeerLoop p mgr = withAsync go
  where
    go = forever $ do
        threadDelay =<< liftIO (randomRIO (30 * 1000 * 1000, 90 * 1000 * 1000))
        ManagerCheckPeer p `send` mgr

withConnectLoop :: MonadUnliftIO m => Manager -> (Async a -> m a) -> m a
withConnectLoop mgr = withAsync go
  where
    go = forever $ do
        ManagerConnect `send` mgr
        threadDelay =<< liftIO (randomRIO (250 * 1000, 1000 * 1000))
