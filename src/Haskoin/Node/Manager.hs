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
Maintainer  : jprupp@protonmail.ch
Stability   : experimental
Portability : POSIX

Peer manager process.
-}
module Haskoin.Node.Manager
    ( peerManager
    ) where

import           Control.Monad             (forM_, forever, guard, when, (<=<))
import           Control.Monad.Except      (ExceptT (..), runExceptT,
                                            throwError)
import           Control.Monad.Logger      (MonadLogger, MonadLoggerIO,
                                            logDebugS, logErrorS, logInfoS,
                                            logWarnS)
import           Control.Monad.Reader      (MonadReader, asks, runReaderT)
import           Control.Monad.Trans       (lift)
import           Control.Monad.Trans.Maybe (MaybeT (..), runMaybeT)
import           Data.Bits                 ((.&.))
import           Data.List                 (find, nub, sort)
import           Data.Maybe                (isJust, isNothing)
import           Data.Set                  (Set)
import qualified Data.Set                  as Set
import           Data.String.Conversions   (cs)
import           Data.Text                 (Text)
import           Data.Time.Clock           (NominalDiffTime, UTCTime,
                                            diffUTCTime)
import           Data.Time.Clock.POSIX     (getCurrentTime, getPOSIXTime)
import           Data.Word                 (Word64)
import           Haskoin                   (Addr (..), BlockHeight,
                                            Message (..), Network (..),
                                            NetworkAddress (..), Ping (..),
                                            Pong (..), Version (..),
                                            hostToSockAddr, nodeNetwork,
                                            sockToHostAddress)
import           Haskoin.Node.Common       (HostPort, OnlinePeer (..), Peer,
                                            PeerConfig (..), PeerEvent (..),
                                            PeerException (..), PeerManager,
                                            PeerManagerConfig (..),
                                            PeerManagerMessage (..),
                                            buildVersion, killPeer,
                                            managerCheck, sendMessage,
                                            toSockAddr)
import           Haskoin.Node.Peer         (peer)
import           Network.Socket            (SockAddr (..))
import           NQE                       (Child, Inbox, Strategy (..),
                                            Supervisor, addChild,
                                            inboxToMailbox, newMailbox, receive,
                                            receiveMatch, send, sendSTM,
                                            subscribe, unsubscribe,
                                            withPublisher, withSupervisor)
import           System.Random             (randomIO, randomRIO)
import           UnliftIO                  (Async, MonadIO, MonadUnliftIO, STM,
                                            SomeException, TVar, atomically,
                                            bracket, liftIO, link, modifyTVar,
                                            newTVarIO, readTVar, readTVarIO,
                                            withAsync, withRunInIO, writeTVar)
import           UnliftIO.Concurrent       (threadDelay)

-- | Monad used by most functions in this module.
type MonadManager m = (MonadLoggerIO m, MonadReader ManagerReader m)

-- | Reader for peer configuration and state.
data ManagerReader = ManagerReader
    { myConfig     :: !PeerManagerConfig
    , mySupervisor :: !Supervisor
    , myMailbox    :: !PeerManager
    , myBestBlock  :: !(TVar BlockHeight)
    , knownPeers   :: !(TVar (Set SockAddr))
    , onlinePeers  :: !(TVar [OnlinePeer])
    }

-- | Peer Manager process. In order to fully start it needs to receive a
-- 'ManageBestBlock' event.
peerManager ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => PeerManagerConfig
    -> Inbox PeerManagerMessage
    -> m ()
peerManager cfg inbox =
    withSupervisor (Notify f) $ \sup -> do
        bb <- newTVarIO 0
        kp <- newTVarIO Set.empty
        ob <- newTVarIO []
        let rd =
                ManagerReader
                    { myConfig = cfg
                    , mySupervisor = sup
                    , myMailbox = mgr
                    , myBestBlock = bb
                    , knownPeers = kp
                    , onlinePeers = ob
                    }
        go `runReaderT` rd
  where
    mgr = inboxToMailbox inbox
    go = do
        putBestBlock <=< receiveMatch inbox $ \case
            PeerManagerBestBlock b -> Just b
            _ -> Nothing
        withConnectLoop mgr $
            forever $ do
                m <- receive inbox
                case m of
                    PeerManagerPeerMessage p _ -> do
                        now <- round <$> liftIO getPOSIXTime
                        o <- asks onlinePeers
                        atomically $ setLastMessage o now p
                    _ -> return ()
                managerMessage m
    f (a, mex) = PeerManagerPeerDied a mex `sendSTM` mgr

putBestBlock :: MonadManager m => BlockHeight -> m ()
putBestBlock bb = asks myBestBlock >>= \b -> atomically $ writeTVar b bb

getBestBlock :: MonadManager m => m BlockHeight
getBestBlock = asks myBestBlock >>= readTVarIO

getNetwork :: MonadManager m => m Network
getNetwork = asks (peerManagerNetwork . myConfig)

loadPeers :: (MonadUnliftIO m, MonadManager m) => m ()
loadPeers = do
    loadStaticPeers
    loadNetSeeds

loadStaticPeers :: (MonadUnliftIO m, MonadManager m) => m ()
loadStaticPeers = do
    xs <- asks (peerManagerPeers . myConfig)
    mapM_ newPeer =<< concat <$> mapM toSockAddr xs

loadNetSeeds :: (MonadUnliftIO m, MonadManager m) => m ()
loadNetSeeds =
    asks (peerManagerDiscover . myConfig) >>= \discover ->
        when discover $ do
            net <- getNetwork
            ss <- concat <$> mapM toSockAddr (networkSeeds net)
            mapM_ newPeer ss

logConnectedPeers :: MonadManager m => m ()
logConnectedPeers = do
    m <- asks (peerManagerMaxPeers . myConfig)
    l <- length <$> getConnectedPeers
    $(logInfoS) "PeerManager" $
        "Peers connected: " <> cs (show l) <> "/" <> cs (show m)

getOnlinePeers :: MonadManager m => m [OnlinePeer]
getOnlinePeers = asks onlinePeers >>= readTVarIO

getConnectedPeers :: MonadManager m => m [OnlinePeer]
getConnectedPeers = filter onlinePeerConnected <$> getOnlinePeers

forwardMessage :: MonadManager m => Peer -> Message -> m ()
forwardMessage p = managerEvent . PeerMessage p

managerEvent :: MonadManager m => PeerEvent -> m ()
managerEvent e = asks (peerManagerEvents . myConfig) >>= \l -> atomically $ l e

managerMessage :: (MonadUnliftIO m, MonadManager m) => PeerManagerMessage -> m ()
managerMessage (PeerManagerPeerMessage p (MVersion v)) = do
    b <- asks onlinePeers
    s <- atomically $ peerString b p
    e <-
        runExceptT $ do
            o <- ExceptT . atomically $ setPeerVersion b p v
            when (onlinePeerConnected o) $ announcePeer p
    case e of
        Right () ->
            MVerAck `sendMessage` p
        Left x -> do
            $(logErrorS) "PeerManager" $
                "Version rejected for peer " <> s <> ": " <> cs (show x)
            killPeer x p

managerMessage (PeerManagerPeerMessage p MVerAck) = do
    b <- asks onlinePeers
    s <- atomically $ peerString b p
    atomically (setPeerVerAck b p) >>= \case
        Just o -> when (onlinePeerConnected o) $ announcePeer p
        Nothing -> do
            $(logErrorS) "PeerManager" $ "Received verack from unknown peer: " <> s
            killPeer UnknownPeer p

managerMessage (PeerManagerPeerMessage p (MAddr (Addr nas))) =
    asks (peerManagerDiscover . myConfig) >>= \discover ->
        when discover $ do
            let sas = map (hostToSockAddr . naAddress . snd) nas
            b <- asks onlinePeers
            s <- atomically $ peerString b p
            forM_ (zip [(1 :: Int) ..] sas) $ \(i, a) -> do
                $(logDebugS) "PeerManager" $
                    "Received peer address " <> cs (show i) <> "/" <>
                    cs (show (length sas)) <>
                    ": " <>
                    cs (show a) <>
                    " from peer " <>
                    s
                newPeer a

managerMessage (PeerManagerPeerMessage p m@(MPong (Pong n))) = do
    now <- liftIO getCurrentTime
    b <- asks onlinePeers
    atomically (gotPong b n now p) >>= \case
        Nothing -> forwardMessage p m
        Just _ -> return ()

managerMessage (PeerManagerPeerMessage p (MPing (Ping n))) =
    MPong (Pong n) `sendMessage` p

managerMessage (PeerManagerPeerMessage p m) = forwardMessage p m

managerMessage (PeerManagerBestBlock h) = putBestBlock h

managerMessage PeerManagerConnect = do
    l <- length <$> getConnectedPeers
    x <- asks (peerManagerMaxPeers . myConfig)
    when (l < x) $
        getNewPeer >>= \case
            Nothing -> return ()
            Just sa -> connectPeer sa

managerMessage (PeerManagerPeerDied a e) = processPeerOffline a e

managerMessage (PeerManagerGetPeers reply) = do
    ps <- getConnectedPeers
    atomically $ reply ps

managerMessage (PeerManagerGetOnlinePeer p reply) = do
    b <- asks onlinePeers
    atomically $ findPeer b p >>= reply

managerMessage (PeerManagerCheckPeer p) = checkPeer p

checkPeer :: MonadManager m => Peer -> m ()
checkPeer p = do
    PeerManagerConfig {peerManagerTimeout = to, peerManagerTooOld = old} <-
        asks myConfig
    b <- asks onlinePeers
    s <- atomically $ peerString b p
    atomically (findPeer b p) >>= \case
        Nothing -> return ()
        Just o -> do
            now <- round <$> liftIO getPOSIXTime
            when
                (onlinePeerConnectTime o < now - fromIntegral old)
                (killPeer PeerTooOld p)
    atomically (lastMessage b p) >>= \case
        Nothing -> pingPeer p
        Just t -> do
            now <- round <$> liftIO getPOSIXTime
            when (now - t > fromIntegral to) $ do
                $(logErrorS) "PeerManager" $
                    "Peer " <> s <> " did not respond ping on time"
                killPeer PeerTimeout p

pingPeer :: MonadManager m => Peer -> m ()
pingPeer p = do
    b <- asks onlinePeers
    atomically (findPeer b p) >>= \case
        Nothing -> $(logDebugS) "PeerManager" $ "Will not ping unknown peer"
        Just o
            | onlinePeerConnected o -> do
                n <- liftIO randomIO
                now <- liftIO getCurrentTime
                atomically (setPeerPing b n now p)
                MPing (Ping n) `sendMessage` p
            | otherwise -> return ()

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
            logConnectedPeers
  where
    log_unknown Nothing = $(logErrorS) "PeerManager" "Disconnected unknown peer"
    log_unknown (Just x) =
        $(logErrorS) "PeerManager" $ "Unknown peer died: " <> cs (show x)
    log_disconnected s Nothing =
        $(logWarnS) "PeerManager" $ "Disconnected peer: " <> s
    log_disconnected s (Just x) =
        $(logErrorS) "PeerManager" $ "Peer " <> s <> " died: " <> cs (show x)
    log_not_connect s Nothing =
        $(logWarnS) "PeerManager" $ "Could not connect to peer " <> s
    log_not_connect s (Just x) =
        $(logErrorS) "PeerManager" $
        "Could not connect to peer " <> s <> ": " <> cs (show x)

announcePeer :: MonadManager m => Peer -> m ()
announcePeer p = do
    b <- asks onlinePeers
    s <- atomically $ peerString b p
    mgr <- asks myMailbox
    atomically (findPeer b p) >>= \case
        Just OnlinePeer {onlinePeerAddress = a, onlinePeerConnected = True} -> do
            $(logInfoS) "PeerManager" $ "Connected to peer " <> s
            managerEvent $ PeerConnected p a
            logConnectedPeers
            managerCheck p mgr
        Just OnlinePeer {onlinePeerConnected = False} -> return ()
        Nothing -> $(logErrorS) "PeerManager" "Not announcing disconnected peer"

getNewPeer :: (MonadUnliftIO m, MonadManager m) => m (Maybe SockAddr)
getNewPeer = runMaybeT $ lift loadPeers >> go
  where
    go = do
        b <- asks knownPeers
        ks <- readTVarIO b
        guard . not $ Set.null ks
        let xs = Set.toList ks
        a <- liftIO $ randomRIO (0, length xs - 1)
        let p = xs !! a
        atomically . modifyTVar b $ Set.delete p
        o <- asks onlinePeers
        atomically (findPeerAddress o p) >>= \case
            Nothing -> return p
            Just _ -> go


connectPeer :: (MonadUnliftIO m, MonadManager m) => SockAddr -> m ()
connectPeer sa = do
    os <- asks onlinePeers
    atomically (findPeerAddress os sa) >>= \case
        Just _ ->
            $(logErrorS) "PeerManager" $
            "Attempted to connect to peer twice: " <> cs (show sa)
        Nothing -> do
            $(logInfoS) "PeerManager" $ "Connecting to " <> cs (show sa)
            PeerManagerConfig { peerManagerNetAddr = ad
                              , peerManagerNetwork = net
                              } <- asks myConfig
            mgr <- asks myMailbox
            sup <- asks mySupervisor
            conn <- asks (peerManagerConnect . myConfig)
            nonce <- liftIO randomIO
            bb <- getBestBlock
            now <- round <$> liftIO getPOSIXTime
            let rmt = NetworkAddress (srv net) (sockToHostAddress sa)
                ver = buildVersion net nonce bb ad rmt now
            (inbox, p) <- newMailbox
            let pc pub =
                    PeerConfig
                        { peerConfListen = pub
                        , peerConfNetwork = net
                        , peerConfAddress = sa
                        , peerConfConnect = conn
                        }
            a <- withRunInIO $ \io -> sup `addChild` io (launch mgr pc inbox p)
            MVersion ver `sendMessage` p
            b <- asks onlinePeers
            _ <- atomically $ newOnlinePeer b sa nonce p a now
            return ()
  where
    l mgr p m = PeerManagerPeerMessage p m `sendSTM` mgr
    srv net
        | getSegWit net = 8
        | otherwise = 0
    launch mgr pc inbox p =
        withPublisher $ \pub ->
            bracket (subscribe pub (l mgr p)) (unsubscribe pub) $ \_ ->
                withPeerLoop sa p mgr $ \a -> do
                    link a
                    peer (pc pub) inbox

withPeerLoop ::
       (MonadUnliftIO m, MonadLogger m)
    => SockAddr
    -> Peer
    -> PeerManager
    -> (Async a -> m a)
    -> m a
withPeerLoop _ p mgr = withAsync go
  where
    go =
        forever $ do
            threadDelay =<<
                liftIO (randomRIO (30 * 1000 * 1000, 90 * 1000 * 1000))
            PeerManagerCheckPeer p `send` mgr

withConnectLoop :: (MonadLogger m, MonadUnliftIO m) => PeerManager -> m a -> m a
withConnectLoop mgr act = withAsync go (\a -> link a >> act)
  where
    go =
        forever $ do
            PeerManagerConnect `send` mgr
            threadDelay =<<
                liftIO (randomRIO (100 * 1000, 10 * 500 * 1000))

-- | Add a peer.
newPeer :: (MonadIO m, MonadManager m) => SockAddr -> m ()
newPeer sa = do
    b <- asks knownPeers
    o <- asks onlinePeers
    i <- atomically $ findPeerAddress o sa
    when (isNothing i) $ atomically . modifyTVar b $ Set.insert sa

-- | Get static network seeds.
networkSeeds :: Network -> [HostPort]
networkSeeds net = map (, getDefaultPort net) (getSeeds net)

-- | Report receiving a pong from a connected peer. Will store ping roundtrip
-- time in a window of latest eleven. Peers are returned by the manager in order
-- of median roundtrip time.
gotPong ::
       TVar [OnlinePeer]
    -> Word64
    -> UTCTime
    -> Peer
    -> STM (Maybe NominalDiffTime)
gotPong b nonce now p =
    runMaybeT $ do
        o <- MaybeT $ findPeer b p
        (time, old_nonce) <- MaybeT . return $ onlinePeerPing o
        guard $ nonce == old_nonce
        let diff = now `diffUTCTime` time
        lift $
            insertPeer
                b
                o
                    { onlinePeerPing = Nothing
                    , onlinePeerPings = take 11 $ diff : onlinePeerPings o
                    }
        return diff

setLastMessage :: TVar [OnlinePeer] -> Word64 -> Peer -> STM ()
setLastMessage b t p = modifyPeer b p $ \o -> o {onlinePeerLastMessage = t}

-- | Return time of last ping sent to peer, if any.
lastMessage :: TVar [OnlinePeer] -> Peer -> STM (Maybe Word64)
lastMessage b p = fmap onlinePeerLastMessage <$> findPeer b p

-- | Set nonce and time of last ping sent to peer.
setPeerPing :: TVar [OnlinePeer] -> Word64 -> UTCTime -> Peer -> STM ()
setPeerPing b nonce now p =
    modifyPeer b p $ \o -> o {onlinePeerPing = Just (now, nonce)}

-- | Set version for online peer. Will set the peer connected status to 'True'
-- if a verack message has already been registered for that peer.
setPeerVersion ::
       TVar [OnlinePeer]
    -> Peer
    -> Version
    -> STM (Either PeerException OnlinePeer)
setPeerVersion b p v =
    runExceptT $ do
        when (services v .&. nodeNetwork == 0) $ throwError NotNetworkPeer
        ops <- lift $ readTVar b
        when (any ((verNonce v ==) . onlinePeerNonce) ops) $
            throwError PeerIsMyself
        lift (findPeer b p) >>= \case
            Nothing -> throwError UnknownPeer
            Just o -> do
                let n =
                        o
                            { onlinePeerVersion = Just v
                            , onlinePeerConnected = onlinePeerVerAck o
                            }
                lift $ insertPeer b n
                return n

-- | Register that a verack message was received from a peer.
setPeerVerAck :: TVar [OnlinePeer] -> Peer -> STM (Maybe OnlinePeer)
setPeerVerAck b p =
    runMaybeT $ do
        o <- MaybeT $ findPeer b p
        let n =
                o
                    { onlinePeerVerAck = True
                    , onlinePeerConnected = isJust (onlinePeerVersion o)
                    }
        lift $ insertPeer b n
        return n

-- | Create 'OnlinePeer' data structure.
newOnlinePeer ::
       TVar [OnlinePeer]
    -> SockAddr
       -- ^ peer address
    -> Word64
       -- ^ nonce sent to peer
    -> Peer
       -- ^ peer mailbox
    -> Async ()
       -- ^ peer asynchronous handle
    -> Word64
       -- ^ when connection was established
    -> STM OnlinePeer
newOnlinePeer b sa n p a t = do
    let op =
            OnlinePeer
                { onlinePeerAddress = sa
                , onlinePeerVerAck = False
                , onlinePeerConnected = False
                , onlinePeerVersion = Nothing
                , onlinePeerAsync = a
                , onlinePeerMailbox = p
                , onlinePeerNonce = n
                , onlinePeerPings = []
                , onlinePeerPing = Nothing
                , onlinePeerConnectTime = t
                , onlinePeerLastMessage = t
                }
    insertPeer b op
    return op

-- | Get a human-readable string for the peer address.
peerString :: TVar [OnlinePeer] -> Peer -> STM Text
peerString b p =
    maybe "[unknown]" (cs . show . onlinePeerAddress) <$> findPeer b p

-- | Find a connected peer.
findPeer :: TVar [OnlinePeer] -> Peer -> STM (Maybe OnlinePeer)
findPeer b p = find ((== p) . onlinePeerMailbox) <$> readTVar b

-- | Insert or replace a connected peer.
insertPeer :: TVar [OnlinePeer] -> OnlinePeer -> STM ()
insertPeer b o = modifyTVar b $ \x -> sort . nub $ o : x

-- | Modify an online peer.
modifyPeer :: TVar [OnlinePeer] -> Peer -> (OnlinePeer -> OnlinePeer) -> STM ()
modifyPeer b p f =
    findPeer b p >>= \case
        Nothing -> return ()
        Just o -> insertPeer b $ f o

-- | Remove an online peer.
removePeer :: TVar [OnlinePeer] -> Peer -> STM ()
removePeer b p = modifyTVar b $ \x -> filter ((/= p) . onlinePeerMailbox) x

-- | Find online peer by asynchronous handle.
findPeerAsync :: TVar [OnlinePeer] -> Async () -> STM (Maybe OnlinePeer)
findPeerAsync b a = find ((== a) . onlinePeerAsync) <$> readTVar b

findPeerAddress :: TVar [OnlinePeer] -> SockAddr -> STM (Maybe OnlinePeer)
findPeerAddress b a = find ((== a) . onlinePeerAddress) <$> readTVar b
