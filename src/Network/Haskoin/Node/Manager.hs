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
import           Control.Monad
import           Control.Monad.Except
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.Trans.Maybe
import           Data.Bits
import qualified Data.ByteString             as B
import           Data.Default
import           Data.List
import           Data.Maybe
import           Data.Serialize              (Get, Put, Serialize)
import           Data.Serialize              as S
import           Data.Set                    (Set)
import qualified Data.Set                    as Set
import           Data.String.Conversions
import           Data.Text                   (Text)
import           Data.Time.Clock
import           Data.Time.Clock.POSIX
import           Data.Word
import           Database.RocksDB            (DB)
import qualified Database.RocksDB            as R
import           Database.RocksDB.Query      as R
import           Haskoin
import           Network.Haskoin.Node.Common
import           Network.Haskoin.Node.Peer
import           Network.Socket              (SockAddr (..))
import           NQE
import           System.Random
import           UnliftIO
import           UnliftIO.Concurrent
import           UnliftIO.Resource           as U

-- | Monad used by most functions in this module.
type MonadManager m = (MonadLoggerIO m, MonadReader ManagerReader m)

-- | Reader for peer configuration and state.
data ManagerReader = ManagerReader
    { myConfig     :: !ManagerConfig
    , mySupervisor :: !Supervisor
    , myMailbox    :: !Manager
    , myBestBlock  :: !(TVar BlockHeight)
    , knownPeers   :: !(TVar (Set SockAddr))
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
        (go `finally` storePeersInDB) `runReaderT` rd
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
        withConnectLoop mgr $
            forever $ do
                $(logDebugS) "Manager" "Awaiting message..."
                m <- receive inbox
                $(logDebugS) "Manager" "Processing message.."
                managerMessage m
    f (a, mex) = ManagerPeerDied a mex `sendSTM` mgr

putBestBlock :: MonadManager m => BlockHeight -> m ()
putBestBlock bb = do
    $(logDebugS) "Manager" $ "Best block at height " <> cs (show bb)
    asks myBestBlock >>= \b -> atomically $ writeTVar b bb

getBestBlock :: MonadManager m => m BlockHeight
getBestBlock = asks myBestBlock >>= readTVarIO

getNetwork :: MonadManager m => m Network
getNetwork = mgrConfNetwork <$> asks myConfig

loadPeers :: (MonadUnliftIO m, MonadManager m) => m ()
loadPeers = do
    os <- readTVarIO =<< asks onlinePeers
    ks <- readTVarIO =<< asks knownPeers
    if null os && Set.null ks
        then do
            loadStaticPeers
            d <- mgrConfDiscover <$> asks myConfig
            when d $ loadPeersFromDB >> loadNetSeeds
        else $(logDebugS) "Manager" "Peers already available, not initialising"

loadStaticPeers :: (MonadUnliftIO m, MonadManager m) => m ()
loadStaticPeers = do
    $(logDebugS) "Manager" "Loading static peers"
    xs <- mgrConfPeers <$> asks myConfig
    mapM_ newPeer =<< concat <$> mapM toSockAddr xs

loadPeersFromDB :: (MonadUnliftIO m, MonadManager m) => m ()
loadPeersFromDB = do
    $(logDebugS) "Manager" "Loading peers from database"
    db <- getManagerDB
    xs <- matchingAsList db R.defaultReadOptions PeerAddressBase
    let f (PeerAddress x, ()) = x
        f _ = undefined
        ys = map f xs
    $(logInfoS) "Manager" $
        "Loaded " <> cs (show (length ys)) <> " peers from database"
    mapM_ newPeer ys

storePeersInDB :: (MonadUnliftIO m, MonadManager m) => m ()
storePeersInDB = do
    db <- getManagerDB
    os <- readTVarIO =<< asks onlinePeers
    ks <- readTVarIO =<< asks knownPeers
    let ps = map onlinePeerAddress os <> Set.toList ks
        xs = map ((`insertOp` ()) . PeerAddress) ps
    unless (null xs) $ do
        $(logInfoS) "Manager" $
            "Storing " <> cs (show (length xs)) <> " peers in database"
        writeBatch db =<< (++ xs) <$> purgePeerDB db

loadNetSeeds :: (MonadUnliftIO m, MonadManager m) => m ()
loadNetSeeds = do
    net <- getNetwork
    $(logDebugS) "Manager" "Loading network seeds"
    ss <- concat <$> mapM toSockAddr (networkSeeds net)
    $(logDebugS) "Manager" $ "Adding " <> cs (show (length ss)) <> " seed peers"
    mapM_ newPeer ss

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
    writeBatch db =<< purgePeerDB db

forwardMessage :: MonadManager m => Peer -> Message -> m ()
forwardMessage p = managerEvent . PeerMessage p

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
    b <- asks onlinePeers
    s <- atomically $ peerString b p
    let n = length nas
    $(logDebugS) "Manager" $
        "Received " <> cs (show n) <> " addresses from peer " <> s
    mgrConfDiscover <$> asks myConfig >>= \case
        True -> do
            let sas = map (naAddress . snd) nas
            forM_ sas newPeer
        False ->
            $(logDebugS)
                "Manager"
                "Ignoring received peers (discovery disabled)"

managerMessage (ManagerPeerMessage p m@(MPong (Pong n))) = do
    now <- liftIO getCurrentTime
    b <- asks onlinePeers
    s <- atomically $ peerString b p
    atomically (gotPong b n now p) >>= \case
        Nothing -> do
            $(logDebugS) "Manager" $
                "Forwarding pong " <> cs (show n) <> " from " <> s
            forwardMessage p m
        Just d -> do
            let ms = fromRational . toRational $ d * 1000 :: Double
            $(logDebugS) "Manager" $
                "Ping roundtrip to " <> s <> ": " <> cs (show ms) <> " ms"

managerMessage (ManagerPeerMessage p (MPing (Ping n))) = do
    b <- asks onlinePeers
    s <- atomically $ peerString b p
    $(logDebugS) "Manager" $
        "Responding to ping " <> cs (show n) <> " from " <> s
    MPong (Pong n) `sendMessage` p

managerMessage (ManagerPeerMessage p m) = do
    b <- asks onlinePeers
    s <- atomically $ peerString b p
    let cmd = commandToString $ msgType m
    $(logDebugS) "Manager" $
        "Forwarding message " <> cs cmd <> " from peer " <> s
    forwardMessage p m

managerMessage (ManagerBestBlock h) = putBestBlock h

managerMessage ManagerConnect = do
    l <- length <$> getConnectedPeers
    x <- mgrConfMaxPeers <$> asks myConfig
    if l < x
        then getNewPeer >>= \case
                 Nothing ->
                     $(logDebugS) "Manager" "No peers available to connect"
                 Just sa -> connectPeer sa
        else $(logDebugS) "Manager" "Enough peers connected."

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
    $(logDebugS) "Manager" $ "Checking on peer " <> s
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
        Just OnlinePeer {onlinePeerConnected = False} ->
            $(logErrorS) "Manager" $
            "Not announcing because not handshaken: " <> s
        Nothing -> $(logErrorS) "Manager" "Will not announce unknown peer"

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
            $(logErrorS) "Manager" $
            "Attempted to connect to peer twice: " <> cs (show sa)
        Nothing -> do
            $(logInfoS) "Manager" $ "Connecting to " <> cs (show sa)
            ManagerConfig {mgrConfNetAddr = ad, mgrConfNetwork = net} <-
                asks myConfig
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
                withPeerLoop sa p mgr $ \a -> do
                    link a
                    peer (pc pub) inbox

withPeerLoop ::
       (MonadUnliftIO m, MonadLogger m)
    => SockAddr
    -> Peer
    -> Manager
    -> (Async a -> m a)
    -> m a
withPeerLoop sa p mgr = withAsync go
  where
    go =
        forever $ do
            threadDelay =<<
                liftIO (randomRIO (30 * 1000 * 1000, 90 * 1000 * 1000))
            $(logDebugS) "ManagerPeerLoop" $
                "Ping manager about peer: " <> cs (show sa)
            ManagerCheckPeer p `send` mgr

withConnectLoop :: (MonadLogger m, MonadUnliftIO m) => Manager -> m a -> m a
withConnectLoop mgr act = withAsync go (\a -> link a >> act)
  where
    go =
        forever $ do
            $(logDebugS)
                "ManagerConnectLoop"
                "Ping manager for housekeeping"
            ManagerConnect `send` mgr
            threadDelay =<< liftIO (randomRIO (2 * 1000 * 1000, 10 * 1000 * 1000))

-- | Database version.
versionPeerDB :: Word32
versionPeerDB = 5

-- | Peer address key in database.
data PeerAddress
    = PeerAddress {
        getPeerAddress :: !SockAddr
        -- ^ peer network address and port
        }
    | PeerAddressBase
    deriving (Eq, Ord, Show)

-- | Database version key.
data PeerDataVersionKey = PeerDataVersionKey
    deriving (Eq, Ord, Show)

instance Serialize PeerDataVersionKey where
    get = do
        guard . (== 0x82) =<< S.getWord8
        return PeerDataVersionKey
    put PeerDataVersionKey = S.putWord8 0x82

instance R.Key PeerDataVersionKey
instance KeyValue PeerDataVersionKey Word32

instance Serialize PeerAddress where
    get = do
        guard . (== 0x81) =<< S.getWord8
        PeerAddress <$> decodeSockAddr
    put PeerAddress {getPeerAddress = a} = do
        S.putWord8 0x81
        encodeSockAddr a
    put PeerAddressBase = S.putWord8 0x81

instance R.Key PeerAddress
instance KeyValue PeerAddress ()

-- | Add a peer.
newPeer :: (MonadIO m, MonadManager m) => SockAddr -> m ()
newPeer sa = do
    b <- asks knownPeers
    o <- asks onlinePeers
    i <- atomically $ findPeerAddress o sa
    when (isNothing i) $ atomically . modifyTVar b $ Set.insert sa

-- | Initialize peer database, purging it of conflicting records if version
-- doesn't match current one, or if peer discovery is disabled.
initPeerDB :: MonadUnliftIO m => DB -> Bool -> m ()
initPeerDB db discover = do
    ver <- retrieve db def PeerDataVersionKey
    when (ver /= Just versionPeerDB || not discover) $
        writeBatch db =<< purgePeerDB db
    R.insert db PeerDataVersionKey versionPeerDB

-- | Purge peer records from database.
purgePeerDB :: MonadUnliftIO m => DB -> m [R.BatchOp]
purgePeerDB db = (++) <$> purge_byte 0x81 <*> purge_byte 0x83
  where
    purge_byte byte =
        U.runResourceT . R.withIterator db def $ \it -> do
            R.iterSeek it $ B.singleton byte
            recurse_delete it byte
    recurse_delete it byte =
        R.iterKey it >>= \case
            Just k
                | B.head k == byte -> do
                    R.iterNext it
                    (R.Del k :) <$> recurse_delete it byte
            _ -> return []

-- | Get static network seeds.
networkSeeds :: Network -> [HostPort]
networkSeeds net = map (, getDefaultPort net) (getSeeds net)

-- | Serialize a network address/port.
encodeSockAddr :: SockAddr -> Put
encodeSockAddr (SockAddrInet6 p _ (a, b, c, d) _) = do
    S.putWord32be a
    S.putWord32be b
    S.putWord32be c
    S.putWord32be d
    S.putWord16be (fromIntegral p)
encodeSockAddr (SockAddrInet p a) = do
    S.putWord32be 0x00000000
    S.putWord32be 0x00000000
    S.putWord32be 0x0000ffff
    S.putWord32host a
    S.putWord16be (fromIntegral p)
encodeSockAddr x = error $ "Could not encode address: " <> show x

-- | Deserialize a network address/port.
decodeSockAddr :: Get SockAddr
decodeSockAddr = do
    a <- S.getWord32be
    b <- S.getWord32be
    c <- S.getWord32be
    if a == 0x00000000 && b == 0x00000000 && c == 0x0000ffff
        then do
            d <- S.getWord32host
            p <- S.getWord16be
            return $ SockAddrInet (fromIntegral p) d
        else do
            d <- S.getWord32be
            p <- S.getWord16be
            return $ SockAddrInet6 (fromIntegral p) 0 (a, b, c, d) 0

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

-- | Return time of last ping sent to peer, if any.
lastPing :: TVar [OnlinePeer] -> Peer -> STM (Maybe UTCTime)
lastPing b p =
    findPeer b p >>= \case
        Just OnlinePeer {onlinePeerPing = Just (time, _)} -> return (Just time)
        _ -> return Nothing

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
    -> STM OnlinePeer
newOnlinePeer b sa n p a = do
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
