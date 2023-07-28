{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE NoFieldSelectors #-}

module Haskoin.Node.PeerMgr
  ( PeerMgrConfig (..),
    PeerEvent (..),
    OnlinePeer (..),
    PeerMgr,
    withPeerMgr,
    peerMgrBest,
    peerMgrVersion,
    peerMgrPing,
    peerMgrPong,
    peerMgrAddrs,
    peerMgrVerAck,
    peerMgrTickle,
    getPeers,
    getOnlinePeer,
    buildVersion,
    myVersion,
    toSockAddr,
    toHostService,
  )
where

import Control.Applicative ((<|>))
import Control.Arrow
import Control.Monad
  ( forM_,
    forever,
    guard,
    unless,
    void,
    when,
    (<=<),
  )
import Control.Monad.Except
  ( ExceptT (..),
    runExceptT,
    throwError,
  )
import Control.Monad.Logger
  ( MonadLogger,
    MonadLoggerIO,
    logDebugS,
    logErrorS,
    logInfoS,
    logWarnS,
  )
import Control.Monad.Reader
  ( MonadReader,
    ReaderT (ReaderT),
    ask,
    asks,
    runReaderT,
  )
import Control.Monad.Trans (lift)
import Control.Monad.Trans.Maybe (MaybeT (..), runMaybeT)
import Data.Bits ((.&.))
import Data.Function (on)
import Data.List (dropWhileEnd, elemIndex, find, nub, sort)
import Data.Maybe (fromMaybe, isJust)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.String.Conversions (cs)
import Data.Time.Clock
  ( NominalDiffTime,
    UTCTime,
    addUTCTime,
    diffUTCTime,
    getCurrentTime,
  )
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Word (Word32, Word64)
import Haskoin
  ( BlockHeight,
    Message (..),
    Network (..),
    NetworkAddress (..),
    Ping (..),
    Pong (..),
    VarString (..),
    Version (..),
    hostToSockAddr,
    nodeNetwork,
    sockToHostAddress,
  )
import Haskoin.Node.Peer
import NQE
  ( Child,
    Inbox,
    Mailbox,
    Publisher,
    Strategy (..),
    Supervisor,
    addChild,
    inboxToMailbox,
    newInbox,
    newMailbox,
    publish,
    receive,
    receiveMatch,
    send,
    sendSTM,
    withSupervisor,
  )
import Network.Socket
  ( AddrInfo (..),
    AddrInfoFlag (..),
    Family (..),
    SockAddr (..),
    SocketType (..),
    defaultHints,
    getAddrInfo,
  )
import System.Random (randomIO, randomRIO)
import UnliftIO
  ( Async,
    MonadIO,
    MonadUnliftIO,
    STM,
    SomeException,
    TVar,
    atomically,
    catch,
    liftIO,
    link,
    modifyTVar,
    newTVarIO,
    readTVar,
    readTVarIO,
    withAsync,
    withRunInIO,
    writeTVar,
  )
import UnliftIO.Concurrent (threadDelay)

type MonadManager m = (MonadIO m, MonadReader PeerMgr m)

data PeerMgrConfig = PeerMgrConfig
  { maxPeers :: !Int,
    peers :: ![String],
    discover :: !Bool,
    address :: !NetworkAddress,
    net :: !Network,
    pub :: !(Publisher PeerEvent),
    timeout :: !NominalDiffTime,
    maxPeerLife :: !NominalDiffTime,
    connect :: !(SockAddr -> WithConnection)
  }

data PeerMgr = PeerMgr
  { config :: !PeerMgrConfig,
    supervisor :: !Supervisor,
    mailbox :: !(Mailbox PeerMgrMessage),
    best :: !(TVar BlockHeight),
    addresses :: !(TVar (Set SockAddr)),
    peers :: !(TVar [OnlinePeer])
  }

data PeerMgrMessage
  = Connect !SockAddr
  | CheckPeer !Peer
  | PeerDied !Child !(Maybe SomeException)
  | ManagerBest !BlockHeight
  | PeerVerAck !Peer
  | PeerVersion !Peer !Version
  | PeerPing !Peer !Word64
  | PeerPong !Peer !Word64
  | PeerAddrs !Peer ![NetworkAddress]
  | PeerTickle !Peer

-- | Data structure representing an online peer.
data OnlinePeer = OnlinePeer
  { address :: !SockAddr,
    verack :: !Bool,
    online :: !Bool,
    version :: !(Maybe Version),
    async :: !(Async ()),
    mailbox :: !Peer,
    nonce :: !Word64,
    ping :: !(Maybe (UTCTime, Word64)),
    pings :: ![NominalDiffTime],
    connected :: !UTCTime,
    tickled :: !UTCTime
  }

instance Eq OnlinePeer where
  (==) = (==) `on` f
    where
      f OnlinePeer {mailbox = p} = p

instance Ord OnlinePeer where
  compare = compare `on` f
    where
      f OnlinePeer {pings = pings} = fromMaybe 60 (median pings)

withPeerMgr ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  PeerMgrConfig ->
  (PeerMgr -> m a) ->
  m a
withPeerMgr cfg action = do
  inbox <- newInbox
  let mgr = inboxToMailbox inbox
  withSupervisor (Notify (death mgr)) $ \sup -> do
    bb <- newTVarIO 0
    kp <- newTVarIO Set.empty
    ob <- newTVarIO []
    runReaderT
      (go inbox)
      PeerMgr
        { config = cfg,
          supervisor = sup,
          mailbox = mgr,
          best = bb,
          addresses = kp,
          peers = ob
        }
  where
    death mgr (a, ex) = PeerDied a ex `sendSTM` mgr
    go inbox =
      withAsync (peerManager inbox) $ \a ->
        withConnectLoop $
          link a >> ReaderT action

peerManager ::
  ( MonadUnliftIO m,
    MonadManager m,
    MonadLoggerIO m
  ) =>
  Inbox PeerMgrMessage ->
  m ()
peerManager inb = do
  $(logDebugS) "PeerMgr" "Awaiting best block"
  putBestBlock <=< receiveMatch inb $ \case
    ManagerBest b -> Just b
    _ -> Nothing
  $(logDebugS) "PeerMgr" "Starting peer manager actor"
  forever $ do
    $(logDebugS) "PeerMgr" "Awaiting event..."
    dispatch =<< receive inb

putBestBlock :: (MonadManager m) => BlockHeight -> m ()
putBestBlock bb = do
  b <- asks (.best)
  atomically $ writeTVar b bb

getBestBlock :: (MonadManager m) => m BlockHeight
getBestBlock =
  asks (.best) >>= readTVarIO

getNetwork :: (MonadManager m) => m Network
getNetwork =
  asks (.config.net)

loadPeers :: (MonadUnliftIO m, MonadManager m) => m ()
loadPeers = do
  loadStaticPeers
  loadNetSeeds

loadStaticPeers :: (MonadUnliftIO m, MonadManager m) => m ()
loadStaticPeers = do
  net <- asks (.config.net)
  xs <- asks (.config.peers)
  mapM_ newPeer . concat =<< mapM (toSockAddr net) xs

loadNetSeeds :: (MonadUnliftIO m, MonadManager m) => m ()
loadNetSeeds =
  asks (.config.discover) >>= \discover ->
    when discover $ do
      net <- getNetwork
      ss <- concat <$> mapM (toSockAddr net) net.seeds
      mapM_ newPeer ss

logConnectedPeers :: (MonadManager m, MonadLoggerIO m) => m ()
logConnectedPeers = do
  m <- asks (.config.maxPeers)
  l <- length <$> getConnectedPeers
  $(logInfoS) "PeerMgr" $
    "Peers connected: " <> cs (show l) <> "/" <> cs (show m)

getOnlinePeers :: (MonadManager m) => m [OnlinePeer]
getOnlinePeers =
  asks (.peers) >>= readTVarIO

getConnectedPeers :: (MonadManager m) => m [OnlinePeer]
getConnectedPeers =
  filter (.online) <$> getOnlinePeers

managerEvent :: (MonadManager m) => PeerEvent -> m ()
managerEvent e =
  publish e =<< asks (.config.pub)

dispatch ::
  ( MonadUnliftIO m,
    MonadManager m,
    MonadLoggerIO m
  ) =>
  PeerMgrMessage ->
  m ()
dispatch (PeerVersion p v) = do
  $(logDebugS) "PeerMgr" $
    "Received peer " <> p.label <> " version: " <> cs (show v)
  b <- asks (.peers)
  e <- runExceptT $ do
    o <- ExceptT . atomically $ setPeerVersion b p v
    when o.online $ announcePeer p
  case e of
    Right () -> do
      $(logDebugS) "PeerMgr" $
        "Sending version ack to peer: " <> p.label
      MVerAck `sendMessage` p
    Left x -> do
      $(logErrorS) "PeerMgr" $
        "Version rejected for peer "
          <> p.label
          <> ": "
          <> cs (show x)
      killPeer x p
dispatch (PeerVerAck p) = do
  b <- asks (.peers)
  atomically (setPeerVerAck b p) >>= \case
    Just o -> do
      $(logDebugS) "PeerMgr" $
        "Received version ack from peer: "
          <> p.label
      when o.online $
        announcePeer p
    Nothing -> do
      $(logErrorS) "PeerMgr" $
        "Received verack from unknown peer: "
          <> p.label
      killPeer UnknownPeer p
dispatch (PeerAddrs p nas) = do
  $(logDebugS) "PeerMgr" $
    "Received addresses from peer " <> p.label
  discover <- asks (.config.discover)
  when discover $ do
    let sas = map (hostToSockAddr . (.address)) nas
    forM_ (zip [(1 :: Int) ..] sas) $ \(i, a) -> do
      $(logDebugS) "PeerMgr" $
        "Got peer address "
          <> cs (show i)
          <> "/"
          <> cs (show (length sas))
          <> ": "
          <> cs (show a)
          <> " from peer "
          <> p.label
      newPeer a
dispatch (PeerPong p n) = do
  b <- asks (.peers)
  $(logDebugS) "PeerMgr" $
    "Received pong "
      <> cs (show n)
      <> " from: "
      <> p.label
  now <- liftIO getCurrentTime
  atomically (gotPong b n now p)
dispatch (PeerPing p n) = do
  $(logDebugS) "PeerMgr" $
    "Responding to ping "
      <> cs (show n)
      <> " from: "
      <> p.label
  MPong (Pong n) `sendMessage` p
dispatch (ManagerBest h) = do
  $(logDebugS) "PeerMgr" $
    "Setting best block to " <> cs (show h)
  putBestBlock h
dispatch (Connect sa) = do
  connectPeer sa
dispatch (PeerDied a e) = do
  processPeerOffline a e
dispatch (CheckPeer p) = do
  $(logDebugS) "PeerManager" $
    "Housekeeping for peer " <> p.label
  checkPeer p
dispatch (PeerTickle p) = do
  $(logDebugS) "PeerMgr" $
    "Tickled peer " <> p.label
  b <- asks (.peers)
  now <- liftIO getCurrentTime
  atomically $
    modifyPeer b p $ \o ->
      o {tickled = now}

checkPeer :: (MonadManager m, MonadLoggerIO m) => Peer -> m ()
checkPeer p = do
  busy <- getBusy p
  b <- asks (.peers)
  mp <- asks (.peers) >>= atomically . flip findPeer p
  case mp of
    Nothing -> return ()
    Just o ->
      liftIO getCurrentTime >>= \now -> do
        maxLife <- asks (.config.maxPeerLife)
        let disconnect = maxLife `addUTCTime` o.connected
        when (now > disconnect) $ do
          $(logErrorS) "PeerMgr" $
            "Disconnecting old peer "
              <> p.label
              <> " online since "
              <> cs (show o.connected)
          killPeer PeerTooOld p
        timeout <- asks (.config.timeout)
        let pingTime = timeout `addUTCTime` o.tickled
        when (now > pingTime) $
          case o.ping of
            Nothing ->
              sendPing p
            Just _ -> do
              $(logWarnS) "PeerMgr" $
                "Peer ping timeout: " <> p.label
              killPeer PeerTimeout p

sendPing :: (MonadManager m, MonadLoggerIO m) => Peer -> m ()
sendPing p = do
  b <- asks (.peers)
  atomically (findPeer b p) >>= \case
    Nothing ->
      $(logWarnS) "PeerMgr" $
        "Will not ping unknown peer: " <> p.label
    Just o
      | o.online -> do
          n <- liftIO randomIO
          now <- liftIO getCurrentTime
          atomically (setPeerPing b n now p)
          $(logDebugS) " PeerManager" $
            "Sending ping "
              <> cs (show n)
              <> " to: "
              <> p.label
          MPing (Ping n) `sendMessage` p
      | otherwise -> return ()

processPeerOffline ::
  (MonadManager m, MonadLoggerIO m) =>
  Child ->
  Maybe SomeException ->
  m ()
processPeerOffline a e = do
  b <- asks (.peers)
  atomically (findPeerAsync b a) >>= \case
    Nothing -> log_unknown e
    Just o -> do
      let p = o.mailbox
      if o.online
        then do
          log_disconnected p e
          managerEvent $ PeerDisconnected p
        else log_not_connect p e
      atomically $ removePeer b p
      logConnectedPeers
  where
    log_unknown Nothing =
      $(logErrorS)
        "PeerMgr"
        "Disconnected unknown peer"
    log_unknown (Just x) =
      $(logErrorS) "PeerMgr" $
        "Unknown peer died: " <> cs (show x)
    log_disconnected p Nothing =
      $(logWarnS) "PeerMgr" $
        "Disconnected peer: " <> p.label
    log_disconnected p (Just x) =
      $(logErrorS) "PeerMgr" $
        "Peer " <> p.label <> " died: " <> cs (show x)
    log_not_connect p Nothing =
      $(logWarnS) "PeerMgr" $
        "Could not connect to peer " <> p.label
    log_not_connect p (Just x) =
      $(logErrorS) "PeerMgr" $
        "Could not connect to peer "
          <> p.label
          <> ": "
          <> cs (show x)

announcePeer :: (MonadManager m, MonadLoggerIO m) => Peer -> m ()
announcePeer p = do
  b <- asks (.peers)
  atomically (findPeer b p) >>= \case
    Just OnlinePeer {online = True} -> do
      $(logInfoS) "PeerMgr" $
        "Connected to peer " <> p.label
      managerEvent $ PeerConnected p
      logConnectedPeers
    Just OnlinePeer {online = False} ->
      return ()
    Nothing ->
      $(logErrorS) "PeerMgr" $
        "Not announcing disconnected peer: "
          <> p.label

getNewPeer :: (MonadUnliftIO m, MonadManager m) => m (Maybe SockAddr)
getNewPeer =
  runMaybeT $ lift loadPeers >> go
  where
    go = do
      b <- asks (.addresses)
      ks <- readTVarIO b
      guard . not $ Set.null ks
      let xs = Set.toList ks
      a <- liftIO $ randomRIO (0, length xs - 1)
      let p = xs !! a
      o <- asks (.peers)
      m <- atomically $ do
        modifyTVar b $ Set.delete p
        findPeerAddress o p
      maybe (return p) (const go) m

connectPeer ::
  ( MonadUnliftIO m,
    MonadManager m,
    MonadLoggerIO m
  ) =>
  SockAddr ->
  m ()
connectPeer sa = do
  os <- asks (.peers)
  atomically (findPeerAddress os sa) >>= \case
    Just _ ->
      $(logErrorS) "PeerMgr" $
        "Attempted to connect to peer twice: " <> cs (show sa)
    Nothing -> do
      $(logInfoS) "PeerMgr" $ "Connecting to " <> cs (show sa)
      PeerMgrConfig
        { address = ad,
          net = net
        } <-
        asks (.config)
      sup <- asks (.supervisor)
      conn <- asks (.config.connect)
      pub <- asks (.config.pub)
      nonce <- liftIO randomIO
      bb <- getBestBlock
      now <- liftIO getCurrentTime
      let rmt = NetworkAddress (srv net) (sockToHostAddress sa)
          unix = floor (utcTimeToPOSIXSeconds now)
          ver = buildVersion net nonce bb ad rmt unix
          text = cs (show sa)
      (inbox, mailbox) <- newMailbox
      let pc =
            PeerConfig
              { pub = pub,
                net = net,
                label = text,
                connect = conn sa
              }
      busy <- newTVarIO False
      p <- wrapPeer pc busy mailbox
      a <- withRunInIO $ \io ->
        sup `addChild` io (launch pc busy inbox p)
      MVersion ver `sendMessage` p
      b <- asks (.peers)
      atomically $
        insertPeer
          b
          OnlinePeer
            { address = sa,
              verack = False,
              online = False,
              version = Nothing,
              async = a,
              mailbox = p,
              nonce = nonce,
              pings = [],
              ping = Nothing,
              connected = now,
              tickled = now
            }
  where
    srv net
      | net.segWit = 8
      | otherwise = 0
    launch pc busy inbox p =
      ask >>= \mgr ->
        withPeerLoop sa p mgr $ \a ->
          link a >> peer pc busy inbox

withPeerLoop ::
  (MonadUnliftIO m, MonadLogger m) =>
  SockAddr ->
  Peer ->
  PeerMgr ->
  (Async a -> m a) ->
  m a
withPeerLoop _ p mgr =
  withAsync . forever $ do
    let x = mgr.config.timeout
        y = floor (x * 1000000)
    r <- liftIO $ randomRIO (y * 3 `div` 4, y)
    threadDelay r
    managerCheck p mgr

withConnectLoop ::
  (MonadUnliftIO m, MonadManager m) =>
  m a ->
  m a
withConnectLoop act =
  withAsync go $ \a ->
    link a >> act
  where
    go = forever $ do
      l <- length <$> getOnlinePeers
      x <- asks (.config.maxPeers)
      when (l < x) $
        getNewPeer >>= mapM_ (\sa -> ask >>= managerConnect sa)
      delay <-
        liftIO $
          randomRIO
            ( 100 * 1000,
              10 * 500 * 1000
            )
      threadDelay delay

newPeer :: (MonadIO m, MonadManager m) => SockAddr -> m ()
newPeer sa = do
  b <- asks (.addresses)
  o <- asks (.peers)
  atomically $
    findPeerAddress o sa >>= \case
      Just _ -> return ()
      Nothing -> modifyTVar b $ Set.insert sa

gotPong :: TVar [OnlinePeer] -> Word64 -> UTCTime -> Peer -> STM ()
gotPong b nonce now p = void . runMaybeT $ do
  o <- MaybeT (findPeer b p)
  (time, old_nonce) <- MaybeT (return o.ping)
  guard $ nonce == old_nonce
  let diff = now `diffUTCTime` time
  lift $
    insertPeer
      b
      o
        { ping = Nothing,
          pings = sort $ take 11 $ diff : o.pings
        }

setPeerPing :: TVar [OnlinePeer] -> Word64 -> UTCTime -> Peer -> STM ()
setPeerPing b nonce now p =
  modifyPeer b p $ \o -> o {ping = Just (now, nonce)}

setPeerVersion ::
  TVar [OnlinePeer] ->
  Peer ->
  Version ->
  STM (Either PeerException OnlinePeer)
setPeerVersion b p v = runExceptT $ do
  when (v.services .&. nodeNetwork == 0) $
    throwError NotNetworkPeer
  ops <- lift $ readTVar b
  when (any ((v.nonce ==) . (.nonce)) ops) $
    throwError PeerIsMyself
  lift (findPeer b p) >>= \case
    Nothing -> throwError UnknownPeer
    Just o -> do
      let n =
            o
              { version = Just v,
                online = o.verack
              }
      lift $ insertPeer b n
      return n

setPeerVerAck :: TVar [OnlinePeer] -> Peer -> STM (Maybe OnlinePeer)
setPeerVerAck b p = runMaybeT $ do
  o <- MaybeT $ findPeer b p
  let n =
        o
          { verack = True,
            online = isJust o.version
          }
  lift $ insertPeer b n
  return n

findPeer :: TVar [OnlinePeer] -> Peer -> STM (Maybe OnlinePeer)
findPeer b p =
  find ((== p) . (.mailbox))
    <$> readTVar b

insertPeer :: TVar [OnlinePeer] -> OnlinePeer -> STM ()
insertPeer b o =
  modifyTVar b $ \x -> sort . nub $ o : x

modifyPeer ::
  TVar [OnlinePeer] ->
  Peer ->
  (OnlinePeer -> OnlinePeer) ->
  STM ()
modifyPeer b p f =
  findPeer b p >>= \case
    Nothing -> return ()
    Just o -> insertPeer b $ f o

removePeer :: TVar [OnlinePeer] -> Peer -> STM ()
removePeer b p =
  modifyTVar b $
    filter ((/= p) . (.mailbox))

findPeerAsync ::
  TVar [OnlinePeer] ->
  Async () ->
  STM (Maybe OnlinePeer)
findPeerAsync b a =
  find ((== a) . (.async))
    <$> readTVar b

findPeerAddress ::
  TVar [OnlinePeer] ->
  SockAddr ->
  STM (Maybe OnlinePeer)
findPeerAddress b a =
  find ((== a) . (.address))
    <$> readTVar b

getPeers :: (MonadIO m) => PeerMgr -> m [OnlinePeer]
getPeers = runReaderT getConnectedPeers

getOnlinePeer ::
  (MonadIO m) =>
  Peer ->
  PeerMgr ->
  m (Maybe OnlinePeer)
getOnlinePeer p =
  runReaderT $ asks (.peers) >>= atomically . (`findPeer` p)

managerCheck :: (MonadIO m) => Peer -> PeerMgr -> m ()
managerCheck p mgr =
  CheckPeer p `send` mgr.mailbox

managerConnect :: (MonadIO m) => SockAddr -> PeerMgr -> m ()
managerConnect sa mgr =
  Connect sa `send` mgr.mailbox

peerMgrBest :: (MonadIO m) => BlockHeight -> PeerMgr -> m ()
peerMgrBest bh mgr =
  ManagerBest bh `send` mgr.mailbox

peerMgrVerAck :: (MonadIO m) => Peer -> PeerMgr -> m ()
peerMgrVerAck p mgr =
  PeerVerAck p `send` mgr.mailbox

peerMgrVersion ::
  (MonadIO m) =>
  Peer ->
  Version ->
  PeerMgr ->
  m ()
peerMgrVersion p ver mgr =
  PeerVersion p ver `send` mgr.mailbox

peerMgrPing ::
  (MonadIO m) =>
  Peer ->
  Word64 ->
  PeerMgr ->
  m ()
peerMgrPing p nonce mgr =
  PeerPing p nonce `send` mgr.mailbox

peerMgrPong ::
  (MonadIO m) =>
  Peer ->
  Word64 ->
  PeerMgr ->
  m ()
peerMgrPong p nonce mgr =
  PeerPong p nonce `send` mgr.mailbox

peerMgrAddrs ::
  (MonadIO m) =>
  Peer ->
  [NetworkAddress] ->
  PeerMgr ->
  m ()
peerMgrAddrs p addrs mgr =
  PeerAddrs p addrs `send` mgr.mailbox

peerMgrTickle ::
  (MonadIO m) =>
  Peer ->
  PeerMgr ->
  m ()
peerMgrTickle p mgr =
  PeerTickle p `send` mgr.mailbox

toHostService :: String -> (Maybe String, Maybe String)
toHostService str =
  let host = case m6 of
        Just (x, _) -> Just x
        Nothing -> case takeWhile (/= ':') str of
          [] -> Nothing
          xs -> Just xs
      srv = case m6 of
        Just (_, y) -> s y
        Nothing -> s str
      s xs =
        case dropWhile (/= ':') xs of
          [] -> Nothing
          _ : ys -> Just ys
      m6 = case str of
        (x : xs)
          | x == '[' -> do
              i <- elemIndex ']' xs
              return $ second tail $ splitAt i xs
          | x == ':' -> do
              return (str, "")
        _ -> Nothing
   in (host, srv)

toSockAddr :: (MonadUnliftIO m) => Network -> String -> m [SockAddr]
toSockAddr net str =
  go `catch` e
  where
    go = fmap (map addrAddress) $ liftIO $ getAddrInfo Nothing host srv
    (host, srv) =
      second (<|> Just (show net.defaultPort)) $
        toHostService str
    e :: (Monad m) => SomeException -> m [SockAddr]
    e _ = return []

median :: (Ord a, Fractional a) => [a] -> Maybe a
median ls
  | null ls =
      Nothing
  | even (length ls) =
      Just . (/ 2) . sum . take 2 $
        drop (length ls `div` 2 - 1) ls'
  | otherwise =
      Just (ls' !! (length ls `div` 2))
  where
    ls' = sort ls

buildVersion ::
  Network ->
  Word64 ->
  BlockHeight ->
  NetworkAddress ->
  NetworkAddress ->
  Word64 ->
  Version
buildVersion net nonce height loc rmt time =
  Version
    { version = myVersion,
      services = loc.services,
      timestamp = time,
      addrRecv = rmt,
      addrSend = loc,
      nonce = nonce,
      userAgent = VarString net.userAgent,
      startHeight = height,
      relay = True
    }

myVersion :: Word32
myVersion = 70012
