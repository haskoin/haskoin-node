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
import           Control.Monad
import           Control.Monad.Except
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.Trans.Maybe
import           Data.Bits
import qualified Data.ByteString             as B
import           Data.Default
import           Data.Function
import           Data.HashMap.Strict         (HashMap)
import qualified Data.HashMap.Strict         as H
import           Data.List
import           Data.Maybe
import           Data.Serialize              (Get, Put, Serialize)
import           Data.Serialize              as S
import           Data.String.Conversions
import           Data.Time.Clock
import           Data.Word
import           Database.RocksDB            (DB)
import qualified Database.RocksDB            as R
import           Database.RocksDB.Query      as R
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Network
import           Network.Haskoin.Node.Common
import           Network.Haskoin.Node.Peer
import           Network.Socket              (SockAddr (..))
import           NQE
import           System.Random
import           UnliftIO
import           UnliftIO.Concurrent
import           UnliftIO.Resource           as U

dataVersion :: Word32
dataVersion = 4

type MonadManager m
     = (MonadLoggerIO m, MonadReader ManagerReader m)

type Score = Word8

data ManagerReader = ManagerReader
    { myConfig       :: !ManagerConfig
    , mySupervisor   :: !Supervisor
    , myMailbox      :: !Manager
    , onlinePeers    :: !(TVar (HashMap Peer OnlinePeer))
    , onlineChildren :: !(TVar (HashMap Child Peer))
    , myBestBlock    :: !(TVar BlockHeight)
    }

data PeerAddress
    = PeerAddress { getPeerAddress :: !SockAddr }
    | PeerAddressBase
    deriving (Eq, Ord, Show)

data PeerScore
    = PeerScore !Score !SockAddr
    | PeerScoreBase
    deriving (Eq, Ord, Show)

instance Serialize PeerScore where
    put (PeerScore s sa) = do
        putWord8 0x83
        put s
        encodeSockAddr sa
    put PeerScoreBase = S.putWord8 0x83
    get = do
        guard . (== 0x83) =<< S.getWord8
        PeerScore <$> get <*> decodeSockAddr

instance Key PeerScore
instance KeyValue PeerScore ()

data PeerDataVersionKey = PeerDataVersionKey
    deriving (Eq, Ord, Show)

instance Serialize PeerDataVersionKey where
    get = do
        guard . (== 0x82) =<< S.getWord8
        return PeerDataVersionKey
    put PeerDataVersionKey = S.putWord8 0x82

instance Key PeerDataVersionKey
instance KeyValue PeerDataVersionKey Word32

instance Serialize PeerAddress where
    get = do
        guard . (== 0x81) =<< S.getWord8
        PeerAddress <$> decodeSockAddr
    put PeerAddress {..} = do
        S.putWord8 0x81
        encodeSockAddr getPeerAddress
    put PeerAddressBase = S.putWord8 0x81

data PeerData = PeerData !Score !Bool
    deriving (Eq, Show, Ord)

instance Serialize PeerData where
    put (PeerData s p) = put s >> put p
    get = PeerData <$> get <*> get

instance Key PeerAddress
instance KeyValue PeerAddress PeerData

updatePeer :: MonadIO m => DB -> SockAddr -> Score -> Bool -> m ()
updatePeer db sa score pass =
    retrieve db def (PeerAddress sa) >>= \case
        Nothing ->
            writeBatch
                db
                [ insertOp (PeerAddress sa) (PeerData score pass)
                , insertOp (PeerScore score sa) ()
                ]
        Just (PeerData score' _) ->
            writeBatch
                db
                [ deleteOp (PeerScore score' sa)
                , insertOp (PeerAddress sa) (PeerData score pass)
                , insertOp (PeerScore score sa) ()
                ]

newPeer :: MonadIO m => DB -> SockAddr -> Score -> m ()
newPeer db sa score =
    retrieve db def (PeerAddress sa) >>= \case
        Just PeerData {} -> return ()
        Nothing ->
            writeBatch
                db
                [ insertOp (PeerAddress sa) (PeerData score False)
                , insertOp (PeerScore score sa) ()
                ]

-- | Peer Manager process. In order to start it needs to receive one
-- 'ManageBestBlock' event.
manager ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => ManagerConfig
    -> Inbox ManagerMessage
    -> m ()
manager cfg@ManagerConfig {..} inbox = do
    ver :: Word32 <- fromMaybe 0 <$> retrieve mgrConfDB def PeerDataVersionKey
    when (ver < dataVersion || not mgrConfDiscover) $ purgeDB mgrConfDB
    R.insert mgrConfDB PeerDataVersionKey dataVersion
    withSupervisor (Notify f) $ \sup -> do
        opb <- newTVarIO H.empty
        oab <- newTVarIO H.empty
        bbb <- newTVarIO 0
        let rd =
                ManagerReader
                    { myConfig = cfg
                    , mySupervisor = sup
                    , myMailbox = mgr
                    , onlinePeers = opb
                    , onlineChildren = oab
                    , myBestBlock = bbb
                    }
        go `runReaderT` rd
  where
    mgr = inboxToMailbox inbox
    go = do
        connectNewPeers
        best <-
            receiveMatch inbox $ \case
                ManagerBestBlock b -> Just b
                _ -> Nothing
        asks myBestBlock >>= \b -> atomically $ writeTVar b best
        withConnectLoop mgr $ \a -> do
            link a
            forever $ receive inbox >>= managerMessage
    f (a, mex) = ManagerPeerDied a mex `sendSTM` mgr

populatePeers :: (MonadUnliftIO m, MonadManager m) => m ()
populatePeers = do
    ManagerConfig {..} <- asks myConfig
    add mgrConfDB mgrConfPeers 4
    when mgrConfDiscover $
        let ss = getSeeds mgrConfNetwork
            p = getDefaultPort mgrConfNetwork
            hs = map (, p) ss
         in add mgrConfDB hs 2
  where
    add db hs x =
        forM_ hs $ toSockAddr >=> mapM_ (\a -> newPeer db a (maxBound `div` x))


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

encodeSockAddr x = error $ "Colud not encode address: " <> show x

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

getPeer :: MonadManager m => SockAddr -> m (Maybe PeerData)
getPeer sa = mgrConfDB <$> asks myConfig >>= \db -> retrieve db def (PeerAddress sa)


logPeersConnected :: MonadManager m => m ()
logPeersConnected = do
    mo <- mgrConfMaxPeers <$> asks myConfig
    ps <- filter onlinePeerConnected <$> getOnlinePeers
    $(logInfoS) "Manager" $
        "Peers connected: " <> cs (show (length ps)) <> "/" <> cs (show mo)

downgradePeer :: MonadManager m => SockAddr -> m ()
downgradePeer sa = do
    db <- mgrConfDB <$> asks myConfig
    getPeer sa >>= \case
        Nothing ->
            $(logErrorS) "Manager" $
            "Could not find peer to downgrade: " <> cs (show sa)
        Just (PeerData score pass) ->
            updatePeer
                db
                sa
                (if score == maxBound
                     then score
                     else score + 1)
                pass

getNewPeer :: (MonadUnliftIO m, MonadManager m) => m (Maybe SockAddr)
getNewPeer = go >>= maybe (reset_pass >> go) (return . Just)
  where
    go = do
        oas <- map onlinePeerAddress <$> getOnlinePeers
        db <- mgrConfDB <$> asks myConfig
        U.runResourceT . runConduit $
            matching db def PeerScoreBase .| filterMC filter_not_pass .|
            mapC get_address .|
            filterC (`notElem` oas) .|
            headC
    reset_pass = do
        db <- mgrConfDB <$> asks myConfig
        U.runResourceT . runConduit $
            matching db def PeerAddressBase .| mapM_C reset_peer_pass
    reset_peer_pass (PeerAddress addr, PeerData score pass) = do
        db <- mgrConfDB <$> asks myConfig
        updatePeer db addr score pass
    reset_peer_pass _ = return ()
    filter_not_pass (PeerScore _ addr, ()) = do
        db <- mgrConfDB <$> asks myConfig
        retrieve db def (PeerAddress addr) >>= \case
            Nothing -> return False
            Just (PeerData _ p) -> return $ not p
    filter_not_pass _ = return False
    get_address (PeerScore _ addr, ()) = addr
    get_address _ = error "Peer was eaten by a lazershark"

purgeDB :: MonadUnliftIO m => DB -> m ()
purgeDB db = purge_byte 0x81 >> purge_byte 0x83
  where
    purge_byte byte =
        U.runResourceT . R.withIterator db def $ \it -> do
            R.iterSeek it $ B.singleton byte
            recurse_delete it byte
    recurse_delete it byte =
        R.iterKey it >>= \case
            Nothing -> return ()
            Just k
                | B.head k == byte -> do
                    R.delete db def k
                    R.iterNext it
                    recurse_delete it byte
                | otherwise -> return ()

getConnectedPeers :: MonadManager m => m [OnlinePeer]
getConnectedPeers = filter onlinePeerConnected <$> getOnlinePeers

purgePeers :: (MonadUnliftIO m, MonadManager m) => m ()
purgePeers = do
    ops <- readTVarIO =<< asks onlinePeers
    forM_ ops $ \OnlinePeer {..} -> killPeer PurgingPeer onlinePeerMailbox
    asks myConfig >>= purgeDB . mgrConfDB

managerMessage :: (MonadUnliftIO m, MonadManager m) => ManagerMessage -> m ()

managerMessage (ManagerPeerMessage p (MVersion ver)) = setPeerVersion p ver

managerMessage (ManagerPeerMessage p (MAddr (Addr nats))) =
    newNetworkPeers p (map (naAddress . snd) nats)

managerMessage (ManagerPeerMessage p MVerAck) = do
    modifyPeer p $ \s -> s {onlinePeerVerAck = True}
    announcePeer p

managerMessage (ManagerPeerMessage p msg@(MPong (Pong n))) =
    go >>= \case
        Nothing -> fwd
        Just t -> do
            samplePing p t
            modifyPeer p $ \x ->
                x {onlinePeerPingTime = Nothing, onlinePeerPingNonce = Nothing}
  where
    fwd =
        mgrConfEvents <$> asks myConfig >>= \listen ->
            atomically . listen $ PeerMessage p msg
    go =
        runMaybeT $ do
            OnlinePeer {..} <- MaybeT $ findPeer p
            nonce <- MaybeT $ return onlinePeerPingNonce
            guard $ nonce == n
            time <- MaybeT $ return onlinePeerPingTime
            now <- liftIO getCurrentTime
            return $ now `diffUTCTime` time

managerMessage (ManagerPeerMessage p (MPing (Ping n))) =
    MPong (Pong n) `sendMessage` p

managerMessage (ManagerPeerMessage p msg) =
    mgrConfEvents <$> asks myConfig >>= \listen ->
        atomically . listen $ PeerMessage p msg

managerMessage (ManagerBestBlock h) =
    asks myBestBlock >>= \b -> atomically $ writeTVar b h

managerMessage ManagerConnect = connectNewPeers

managerMessage (ManagerKill e p) = killPeer e p

managerMessage (ManagerPeerDied a e) = processPeerOffline a e

managerMessage ManagerPurgePeers = purgePeers

managerMessage (ManagerGetPeers reply) =
    getPeers >>= atomically . reply

managerMessage (ManagerGetOnlinePeer p reply) =
    getOnlinePeer p >>= atomically . reply

managerMessage (ManagerCheckPeer p) =
    findPeer p >>= \case
        Just OnlinePeer {..} | onlinePeerConnected ->
            case onlinePeerPingTime of
                Nothing -> ping_peer
                Just time -> do
                    now <- liftIO getCurrentTime
                    if now `diffUTCTime` time > 30
                        then asks myMailbox >>= managerKill PeerTimeout p
                        else ping_peer
        _ -> return ()
  where
    ping_peer = do
        n <- liftIO randomIO
        now <- liftIO getCurrentTime
        modifyPeer p $ \x ->
            x {onlinePeerPingTime = Just now, onlinePeerPingNonce = Just n}
        MPing (Ping n) `sendMessage` p

killPeer :: MonadManager m => PeerException -> Peer -> m ()
killPeer e p =
    findPeer p >>= \case
        Nothing -> return ()
        Just op -> do
            $(logErrorS) "Manager" $
                "Killing peer " <> cs (show (onlinePeerAddress op)) <> ": " <>
                cs (show e)
            onlinePeerAsync op `cancelWith` e

samplePing :: MonadManager m => Peer -> NominalDiffTime -> m ()
samplePing p n =
    modifyPeer p $ \x -> x {onlinePeerPings = take 11 $ n : onlinePeerPings x}

newNetworkPeers :: MonadManager m => Peer -> [SockAddr] -> m ()
newNetworkPeers p as =
    void . runMaybeT $ do
        ManagerConfig {..} <- asks myConfig
        guard (not mgrConfDiscover)
        pn <- lift $ peerString p
        $(logInfoS) "Manager" $
            "Received " <> cs (show (length as)) <> " peers from " <> cs pn
        forM_ as $ \a -> newPeer mgrConfDB a ((maxBound `div` 4) * 3)

processPeerOffline :: MonadManager m => Child -> Maybe SomeException -> m ()
processPeerOffline a e =
    findChild a >>= \case
        Nothing ->
            case e of
                Nothing -> $(logErrorS) "Manager" "Unknown peer died"
                Just x ->
                    $(logErrorS) "Manager" $
                    "Unknown peer died: " <> cs (show x)
        Just OnlinePeer {..} -> do
            if onlinePeerConnected
                then do
                    case e of
                        Nothing ->
                            $(logWarnS) "Manager" $
                            "Disconnected peer " <> cs (show onlinePeerAddress)
                        Just x ->
                            $(logErrorS) "Manager" $
                            "Peer " <> cs (show onlinePeerAddress) <> " died: " <>
                            cs (show x)
                    listen <- mgrConfEvents <$> asks myConfig
                    atomically . listen $ PeerDisconnected onlinePeerMailbox
                else case e of
                         Nothing ->
                             $(logWarnS) "Manager" $
                             "Could not connect to peer " <>
                             cs (show onlinePeerAddress)
                         Just x ->
                             $(logErrorS) "Manager" $
                             "Could not connect to peer " <>
                             cs (show onlinePeerAddress) <>
                             ": " <>
                             cs (show x)
            removePeer a
            downgradePeer onlinePeerAddress
            logPeersConnected

setPeerVersion :: MonadManager m => Peer -> Version -> m ()
setPeerVersion p v =
    findPeer p >>= \case
        Nothing -> $(logErrorS) "Manager" "Could not find peer to set version"
        Just OnlinePeer {..}
            | isJust onlinePeerVersion ->
                killPeer DuplicateVersion onlinePeerMailbox
            | otherwise ->
                runExceptT testVersion >>= \case
                    Left ex -> killPeer ex p
                    Right () -> do
                        modifyPeer p $ \s -> s {onlinePeerVersion = Just v}
                        MVerAck `sendMessage` p
                        askForPeers
                        announcePeer p
  where
    testVersion = do
        when (services v .&. nodeNetwork == 0) $ throwError NotNetworkPeer
        is_me <- any ((verNonce v ==) . onlinePeerNonce) <$> lift getOnlinePeers
        when is_me $ throwError PeerIsMyself
    askForPeers =
        mgrConfDiscover <$> asks myConfig >>= \discover ->
            when discover (MGetAddr `sendMessage` p)

announcePeer :: MonadManager m => Peer -> m ()
announcePeer p =
    findPeer p >>= \case
        Nothing -> return ()
        Just OnlinePeer {..}
            | isJust onlinePeerVersion && onlinePeerVerAck -> do
                listen <- mgrConfEvents <$> asks myConfig
                unless onlinePeerConnected $ do
                    atomically . listen $ PeerConnected p
                    setPeerAnnounced p
                    getPeer onlinePeerAddress >>= \case
                        Nothing ->
                            $(logErrorS) "Manager" $
                            "Could not find peer to upgrade: " <>
                            cs (show onlinePeerAddress)
                        Just (PeerData score pass) -> do
                            db <- mgrConfDB <$> asks myConfig
                            updatePeer
                                db
                                onlinePeerAddress
                                (if score == 0
                                     then 0
                                     else score - 1)
                                pass
                    $(logInfoS) "Manager" $
                        "Connected to " <> cs (show onlinePeerAddress)
                    logPeersConnected
            | otherwise -> return ()

getPeers :: MonadManager m => m [OnlinePeer]
getPeers = sortBy (compare `on` f) <$> getConnectedPeers
  where
    f OnlinePeer {..} = fromMaybe 60 (median onlinePeerPings)

getOnlinePeer :: MonadManager m => Peer -> m (Maybe OnlinePeer)
getOnlinePeer p = find ((== p) . onlinePeerMailbox) <$> getConnectedPeers

connectNewPeers :: (MonadUnliftIO m, MonadManager m) => m ()
connectNewPeers = do
    ManagerConfig {..} <- asks myConfig
    os <- getOnlinePeers
    when (length os < mgrConfMaxPeers) $
        getNewPeer >>= \case
            Nothing ->
                populatePeers >> getNewPeer >>= \case
                    Just sa -> conn sa
                    Nothing -> return ()
            Just sa -> conn sa
  where
    conn sa = do
        ManagerConfig {..} <- asks myConfig
        mgr <- asks myMailbox
        let ad = mgrConfNetAddr
            net = mgrConfNetwork
        $(logInfoS) "Manager" $ "Connecting to peer " <> cs (show sa)
        nonce <- liftIO randomIO
        bb <- asks myBestBlock >>= readTVarIO
        let rmt = NetworkAddress (srv net) sa
        ver <- buildVersion net nonce bb ad rmt
        (inbox, p) <- newMailbox
        let pc =
                PeerConfig
                    { peerConfListen = l mgr
                    , peerConfNetwork = net
                    , peerConfAddress = sa
                    }
        sup <- asks mySupervisor
        a <- withRunInIO $ \io -> sup `addChild` io (launch mgr pc inbox)
        managerCheck p mgr
        MVersion ver `sendMessage` p
        newPeerConnection sa nonce p a
    l mgr (p, m) = ManagerPeerMessage p m `sendSTM` mgr
    srv net
        | getSegWit net = 8
        | otherwise = 0
    launch mgr pc inbox =
        withPeerLoop (inboxToMailbox inbox) mgr $ \a -> do
            link a
            peer pc inbox

newPeerConnection ::
       MonadManager m
    => SockAddr
    -> Word64
    -> Peer
    -> Child
    -> m ()
newPeerConnection sa nonce p a =
    addPeer
        OnlinePeer
        { onlinePeerAddress = sa
        , onlinePeerVerAck = False
        , onlinePeerConnected = False
        , onlinePeerVersion = Nothing
        , onlinePeerAsync = a
        , onlinePeerMailbox = p
        , onlinePeerNonce = nonce
        , onlinePeerPings = []
        , onlinePeerPingNonce = Nothing
        , onlinePeerPingTime = Nothing
        }

peerString :: MonadManager m => Peer -> m String
peerString p = maybe "[unknown]" (show . onlinePeerAddress) <$> findPeer p

setPeerAnnounced :: MonadManager m => Peer -> m ()
setPeerAnnounced p = modifyPeer p $ \x -> x {onlinePeerConnected = True}

findPeer :: MonadManager m => Peer -> m (Maybe OnlinePeer)
findPeer p = do
    opb <- asks onlinePeers
    H.lookup p <$> readTVarIO opb

modifyPeer :: MonadManager m => Peer -> (OnlinePeer -> OnlinePeer) -> m ()
modifyPeer p f = do
    opb <- asks onlinePeers
    atomically . modifyTVar opb $ H.adjust f p

addPeer :: MonadManager m => OnlinePeer -> m ()
addPeer op@OnlinePeer {..} = do
    opb <- asks onlinePeers
    oab <- asks onlineChildren
    atomically $ do
        modifyTVar opb $ H.insert onlinePeerMailbox op
        modifyTVar oab $ H.insert onlinePeerAsync onlinePeerMailbox

findChild :: MonadManager m => Child -> m (Maybe OnlinePeer)
findChild a =
    runMaybeT $ do
        oab <- asks onlineChildren
        opb <- asks onlinePeers
        p <- MaybeT $ H.lookup a <$> readTVarIO oab
        MaybeT $ H.lookup p <$> readTVarIO opb

removePeer :: MonadManager m => Child -> m ()
removePeer a = do
    opb <- asks onlinePeers
    oab <- asks onlineChildren
    atomically $
        H.lookup a <$> readTVar oab >>= \case
            Nothing -> return ()
            Just p -> do
                modifyTVar opb $ H.delete p
                modifyTVar oab $ H.delete a

getOnlinePeers :: MonadManager m => m [OnlinePeer]
getOnlinePeers = H.elems <$> (readTVarIO =<< asks onlinePeers)

median :: Fractional a => [a] -> Maybe a
median ls
    | null ls = Nothing
    | length ls `mod` 2 == 0 =
        Just . (/ 2) . sum . take 2 $ drop (length ls `div` 2 - 1) ls
    | otherwise = Just . head $ drop (length ls `div` 2) ls

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
