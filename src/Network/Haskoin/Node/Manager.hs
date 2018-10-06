{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
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

type MonadManager m = (MonadLoggerIO m, MonadReader ManagerReader m)

data ManagerReader = ManagerReader
    { myConfig     :: !ManagerConfig
    , mySupervisor :: !Supervisor
    , myMailbox    :: !Manager
    , myBestBlock  :: !(TVar BlockHeight)
    , onlinePeers  :: !(TVar [OnlinePeer])
    }

-- | Peer Manager process. In order to start it needs to receive one
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
        initPeerDB db discover
        getNewPeer >>= \case
            Nothing -> return ()
            Just a -> connectPeer a
        putBestBlock <=< receiveMatch inbox $ \case
            ManagerBestBlock b -> Just b
            _ -> Nothing
        $(logInfoS) "Manager" "Initialization complete"
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

logPeersConnected :: MonadManager m => m ()
logPeersConnected = do
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
forwardMessage p msg =
    managerEvent $ PeerMessage p msg

managerEvent :: MonadManager m => PeerEvent -> m ()
managerEvent e = mgrConfEvents <$> asks myConfig >>= \l -> atomically $ l e

managerMessage :: (MonadUnliftIO m, MonadManager m) => ManagerMessage -> m ()
managerMessage (ManagerPeerMessage p (MVersion v)) =
    either (`killPeer` p) (\_ -> return ()) <=< runExceptT $ do
        b <- asks onlinePeers
        o <- ExceptT . atomically $ setPeerVersion b p v
        when (onlinePeerConnected o) $ announcePeer p
managerMessage (ManagerPeerMessage p MVerAck) = do
    b <- asks onlinePeers
    atomically (setPeerVerAck b p) >>= \case
        Just o -> when (onlinePeerConnected o) $ announcePeer p
        Nothing -> killPeer UnknownPeer p
managerMessage (ManagerPeerMessage _ (MAddr (Addr nas))) = do
    db <- getManagerDB
    let sas = map (naAddress . snd) nas
    forM_ sas $ newPeerDB db netPeerScore
managerMessage (ManagerPeerMessage p msg@(MPong (Pong n))) = do
    now <- liftIO getCurrentTime
    b <- asks onlinePeers
    atomically (gotPong b n now p) >>= \x -> unless x $ forwardMessage p msg
managerMessage (ManagerPeerMessage p (MPing (Ping n))) =
    MPong (Pong n) `sendMessage` p
managerMessage (ManagerPeerMessage p msg) = forwardMessage p msg
managerMessage (ManagerBestBlock h) = putBestBlock h
managerMessage ManagerConnect = do
    l <- length <$> getConnectedPeers
    x <- mgrConfMaxPeers <$> asks myConfig
    when (l < x) $
        getNewPeer >>= \case
            Nothing -> $(logErrorS) "Manager" "No candidate peers to connect"
            Just sa -> connectPeer sa
managerMessage (ManagerKill e p) = killPeer e p
managerMessage (ManagerPeerDied a e) = processPeerOffline a e
managerMessage ManagerPurgePeers = purgePeers
managerMessage (ManagerGetPeers reply) =
    getConnectedPeers >>= atomically . reply
managerMessage (ManagerGetOnlinePeer p reply) = do
    b <- asks onlinePeers
    atomically $ findPeer b p >>= reply
managerMessage (ManagerCheckPeer p) = checkPeer p

checkPeer :: MonadManager m => Peer -> m ()
checkPeer p = do
    b <- asks onlinePeers
    atomically (lastPing b p) >>= \case
        Nothing -> pingPeer p
        Just t -> do
            now <- liftIO getCurrentTime
            when (diffUTCTime now t > 30) $ killPeer PeerTimeout p

pingPeer :: MonadManager m => Peer -> m ()
pingPeer p = do
    n <- liftIO randomIO
    now <- liftIO getCurrentTime
    b <- asks onlinePeers
    atomically (setPeerPing b n now p)
    MPing (Ping n) `sendMessage` p

killPeer :: MonadManager m => PeerException -> Peer -> m ()
killPeer e p = void . runMaybeT $ do
    b <- asks onlinePeers
    o <- MaybeT . atomically $ findPeer b p
    s <- atomically $ peerString b p
    $(logErrorS) "Manager" $ "Killing peer " <> s <> ": " <> cs (show e)
    onlinePeerAsync o `cancelWith` e

processPeerOffline :: MonadManager m => Child -> Maybe SomeException -> m ()
processPeerOffline a e = do
    b <- asks onlinePeers
    atomically (findPeerAsync b a) >>= \case
        Nothing -> log_unknown e
        Just o -> do
            let p = onlinePeerMailbox o
            s <- atomically $ peerString b p
            if onlinePeerConnected o
                then do
                    log_disconnected s e
                    managerEvent $ PeerDisconnected p
                else log_not_connect s e
            atomically $ removePeer b p
            db <- getManagerDB
            demotePeerDB db (onlinePeerAddress o)
            logPeersConnected
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
    atomically (findPeer b p) >>= \case
        Just OnlinePeer {onlinePeerAddress = a, onlinePeerConnected = True} -> do
            managerEvent $ PeerConnected p
            db <- getManagerDB
            promotePeerDB db a
        _ -> return ()

getNewPeer :: (MonadUnliftIO m, MonadManager m) => m (Maybe SockAddr)
getNewPeer = do
    ManagerConfig {mgrConfDB = db} <- asks myConfig
    online_peers <- getOnlinePeers
    let exclude = map onlinePeerAddress online_peers
    runMaybeT $
        MaybeT (getNewPeerDB db exclude) <|>
        MaybeT (populatePeerDB >> getNewPeerDB db exclude)

connectPeer :: (MonadUnliftIO m, MonadManager m) => SockAddr -> m ()
connectPeer sa = do
    $(logInfoS) "Manager" $ "Connecting to peer: " <> cs (show sa)
    ManagerConfig {mgrConfNetAddr = ad, mgrConfNetwork = net} <- asks myConfig
    mgr <- asks myMailbox
    sup <- asks mySupervisor
    nonce <- liftIO randomIO
    bb <- getBestBlock
    let rmt = NetworkAddress (srv net) sa
    ver <- buildVersion net nonce bb ad rmt
    (inbox, p) <- newMailbox
    let pc =
            PeerConfig
                { peerConfListen = l mgr
                , peerConfNetwork = net
                , peerConfAddress = sa
                }
    a <- withRunInIO $ \io -> sup `addChild` io (launch mgr pc inbox p)
    managerCheck p mgr
    MVersion ver `sendMessage` p
    b <- asks onlinePeers
    _ <- atomically $ newOnlinePeer b sa nonce p a
    return ()
  where
    l mgr (p, m) = ManagerPeerMessage p m `sendSTM` mgr
    srv net
        | getSegWit net = 8
        | otherwise = 0
    launch mgr pc inbox p =
        withPeerLoop p mgr $ \a -> do
            link a
            peer pc inbox

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
        threadDelay =<< liftIO (randomRIO (5 * 1000 * 1000, 10 * 1000 * 1000))
        ManagerConnect `send` mgr
