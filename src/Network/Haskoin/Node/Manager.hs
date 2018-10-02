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
dataVersion = 3

type MonadManager m
     = (MonadUnliftIO m, MonadLoggerIO m, MonadReader ManagerReader m)

type Score = Word8

data ManagerReader = ManagerReader
    { myConfig       :: !ManagerConfig
    , mySupervisor   :: !Supervisor
    , onlinePeers    :: !(TVar (HashMap Peer OnlinePeer))
    , onlineChildren :: !(TVar (HashMap Child Peer))
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

data PeerData = PeerData !Score !Timestamp
    deriving (Eq, Show, Ord)

instance Serialize PeerData where
    put (PeerData s t) = put s >> put t
    get = PeerData <$> get <*> get

instance Key PeerAddress
instance KeyValue PeerAddress PeerData

updatePeer :: MonadIO m => DB -> SockAddr -> Score -> Timestamp -> m ()
updatePeer db sa score timestamp =
    retrieve db def (PeerAddress sa) >>= \case
        Nothing ->
            writeBatch
                db
                [ insertOp (PeerAddress sa) (PeerData score 0)
                , insertOp (PeerScore score sa) ()
                ]
        Just (PeerData score' _) ->
            writeBatch
                db
                [ deleteOp (PeerScore score' sa)
                , insertOp (PeerAddress sa) (PeerData score timestamp)
                , insertOp (PeerScore score sa) ()
                ]

newPeer :: MonadIO m => DB -> SockAddr -> Score -> m ()
newPeer db sa score =
    retrieve db def (PeerAddress sa) >>= \case
        Just PeerData {} -> return ()
        Nothing ->
            writeBatch
                db
                [ insertOp (PeerAddress sa) (PeerData score 0)
                , insertOp (PeerScore score sa) ()
                ]

manager ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => ManagerConfig
    -> m ()
manager cfg@ManagerConfig {..} = do
    psup <- newInbox =<< newTQueueIO
    ver :: Word32 <- fromMaybe 0 <$> retrieve mgrConfDB def PeerDataVersionKey
    when (ver < dataVersion || not mgrConfDiscover) $ purgeDB mgrConfDB
    R.insert mgrConfDB PeerDataVersionKey dataVersion
    withAsync (liftIO $ supervisor (Notify dead) psup []) $ \a -> do
        link a
        opb <- newTVarIO H.empty
        oab <- newTVarIO H.empty
        let w = do
                o <- readTVar opb
                checkSTM $ H.size o < mgrConfMaxPeers
        withConnectLoop mgrConfMailbox w $
            let rd =
                    ManagerReader
                        { myConfig = cfg
                        , mySupervisor = psup
                        , onlinePeers = opb
                        , onlineChildren = oab
                        }
             in withPubSub Nothing mgrConfPub $ \sub ->
                    managerLoop sub `runReaderT` rd
  where
    dead x = PeerStopped (fst x) `sendSTM` mgrConfMailbox

populatePeers :: MonadManager m => m ()
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
    ps <- getOnlinePeers
    $(logInfoS) "Manager" $
        "Peers connected: " <> cs (show (length ps)) <> "/" <> cs (show mo)

downgradePeer :: MonadManager m => SockAddr -> m ()
downgradePeer sa = do
    db <- mgrConfDB <$> asks myConfig
    now <- computeTime
    getPeer sa >>= \case
        Nothing ->
            $(logErrorS) "Manager" $
            "Could not find peer to downgrade: " <> cs (show sa)
        Just (PeerData score _) ->
            updatePeer
                db
                sa
                (if score == maxBound
                     then score
                     else score + 1)
                now

getNewPeer :: MonadManager m => m (Maybe SockAddr)
getNewPeer = do
    ManagerConfig {..} <- asks myConfig
    oas <- map onlinePeerAddress <$> getOnlinePeers
    now <- computeTime
    let db = mgrConfDB
    U.runResourceT . runConduit $
        matching db def PeerScoreBase .| filterMC (f now oas) .| mapC g .| headC
  where
    f now oas (PeerScore _ addr, ())
        | addr `elem` oas = return False
        | otherwise =
            getPeer addr >>= \case
                Nothing -> r
                Just (PeerData score timestamp) ->
                    return $ now > timestamp + fromIntegral score * 30
    f _ _ _ = r
    g (PeerScore _ addr, ()) = addr
    g _                      = undefined
    r = do
        $(logErrorS) "Manager" "Recovering from corrupted peer database..."
        purgePeers
        return False

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

withConnectLoop :: MonadUnliftIO m => Manager -> STM () -> m () -> m ()
withConnectLoop mgr w f = withAsync go $ \a -> link a >> f
  where
    go = do
        let i = 250 * 1000 `div` 4
        forever $ do
            atomically w
            ConnectToPeers `send` mgr
            threadDelay =<< liftIO (randomRIO (i * 3, i * 5))

managerLoop :: MonadManager m => Inbox (Peer, PeerEvent) -> m ()
managerLoop sub = do
    ManagerConfig {..} <- asks myConfig
    let mgr = mgrConfMailbox
    forever $
        recv mgr >>= \case
            Left event -> uncurry processEvent event
            Right msg -> processMessage msg
  where
    recv mgr =
        atomically $ Right <$> receiveSTM mgr <|> Left <$> receiveSTM sub

purgePeers :: MonadManager m => m ()
purgePeers = do
    ops <- readTVarIO =<< asks onlinePeers
    forM_ ops $ \op -> onlinePeerAsync op `cancelWith` PurgingPeer
    asks myConfig >>= purgeDB . mgrConfDB

processEvent :: MonadManager m => Peer -> PeerEvent -> m ()
processEvent p (PeerMessage (MVersion ver)) = setPeerVersion p ver
processEvent p (PeerMessage (MAddr (Addr nats))) =
    newNetworkPeers p (map (naAddress . snd) nats)
processEvent p (PeerMessage MVerAck) = do
    modifyPeer p $ \s -> s {onlinePeerVerAck = True}
    announcePeer p
processEvent _ _ = return ()

processMessage :: MonadManager m => ManagerMessage -> m ()
processMessage ConnectToPeers = connectNewPeers
processMessage (ManagerKill e p) =
    findPeer p >>= \case
        Nothing -> return ()
        Just op -> do
            $(logErrorS) "Manager" $
                "Killing peer " <> cs (show (onlinePeerAddress op))
            onlinePeerAsync op `cancelWith` e
processMessage PurgePeers = purgePeers
processMessage (ManagerGetPeers reply) =
    getPeers >>= atomically . reply
processMessage (ManagerGetOnlinePeer p reply) =
    getOnlinePeer p >>= atomically . reply
processMessage (PeerStopped a) = processPeerOffline a
processMessage (PeerRoundTrip p t) = samplePing p t

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

processPeerOffline :: MonadManager m => Child -> m ()
processPeerOffline a = do
    findChild a >>= \case
        Just OnlinePeer {..} -> do
            if onlinePeerConnected
                then do
                    $(logWarnS) "Manager" $
                        "Disconnected peer " <> cs (show onlinePeerAddress)
                    pub <- mgrConfPub <$> asks myConfig
                    let p = onlinePeerMailbox
                    Event (p, PeerDisconnected) `send` pub
                else $(logWarnS) "Manager" $
                     "Could not connect to peer " <> cs (show onlinePeerAddress)
            logPeersConnected
            downgradePeer onlinePeerAddress
        Nothing -> $(logErrorS) "Manager" "Could not find dead peer"
    removePeer a

setPeerVersion :: MonadManager m => Peer -> Version -> m ()
setPeerVersion p v =
    findPeer p >>= \case
        Nothing -> $(logErrorS) "Manager" "Could not find peer to set version"
        Just OnlinePeer {..}
            | isJust onlinePeerVersion ->
                onlinePeerAsync `cancelWith` DuplicateVersion
            | otherwise -> do
                modifyPeer p $ \s -> s {onlinePeerVersion = Just v}
                runExceptT testVersion >>= \case
                    Left ex -> onlinePeerAsync `cancelWith` ex
                    Right () -> do
                        MVerAck `send` p
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
                $(logInfoS) "Manager" $
                    "Connected to " <> cs (show onlinePeerAddress)
                pub <- mgrConfPub <$> asks myConfig
                unless onlinePeerConnected $ do
                    Event (p, PeerConnected) `send` pub
                    setPeerAnnounced p
            | otherwise -> return ()

getPeers :: MonadManager m => m [OnlinePeer]
getPeers = sortBy (compare `on` f) <$> getConnectedPeers
  where
    f OnlinePeer {..} = fromMaybe 60 (median onlinePeerPings)

getOnlinePeer :: MonadManager m => Peer -> m (Maybe OnlinePeer)
getOnlinePeer p = find ((== p) . onlinePeerMailbox) <$> getConnectedPeers

connectNewPeers :: MonadManager m => m ()
connectNewPeers = do
    ManagerConfig {..} <- asks myConfig
    let mo = mgrConfMaxPeers
    os <- getOnlinePeers
    when (length os < mo) $
        getNewPeer >>= \case
            Nothing ->
                populatePeers >> getNewPeer >>= \case
                    Just sa -> conn sa
                    Nothing -> return ()
            Just sa -> conn sa
  where
    conn sa = do
        ManagerConfig {..} <- asks myConfig
        let ad = mgrConfNetAddr
            ch = mgrConfChain
            pub = mgrConfPub
            net = mgrConfNetwork
            mgr = mgrConfMailbox
        $(logInfoS) "Manager" $ "Connecting to peer " <> cs (show sa)
        nonce <- liftIO randomIO
        bb <- nodeHeight <$> chainGetBest ch
        let rmt = NetworkAddress (srv net) sa
        ver <- buildVersion net nonce bb ad rmt
        p <- newInbox =<< newTQueueIO
        let pc =
                PeerConfig
                    { peerConfPub = pub
                    , peerConfNetwork = net
                    , peerConfAddress = sa
                    , peerConfMailbox = p
                    }
        sup <- asks mySupervisor
        a <- withRunInIO $ \io -> sup `addChild` (io . connectAndWatch mgr) pc
        MVersion ver `send` p
        newPeerConnection sa nonce p a
    srv net
        | getSegWit net = 8
        | otherwise = 0

connectAndWatch ::
       (MonadLoggerIO m, MonadUnliftIO m)
    => Manager
    -> PeerConfig
    -> m ()
connectAndWatch mgr cfg@PeerConfig {..} =
    withAsync peer_pinger $ \a -> do
        link a
        peer cfg
  where
    p = peerConfMailbox
    peer_pinger =
        withPubSub Nothing peerConfPub $ \sub -> do
            get_connect sub
            forever $ do
                r <- liftIO randomIO
                t1 <- liftIO getCurrentTime
                MPing (Ping r) `send` peerConfMailbox
                timeout (30 * 1000000) (get_pong sub r) >>= \case
                    Nothing -> ManagerKill PeerTimeout p `send` mgr
                    Just () -> do
                        t2 <- liftIO getCurrentTime
                        PeerRoundTrip p (t2 `diffUTCTime` t1) `send` mgr
                        w <- liftIO $ randomRIO (30 * 1000000, 90 * 1000000)
                        threadDelay w
    get_connect sub =
        receive sub >>= \case
            (p', PeerConnected)
                | p' == p -> return ()
            _ -> get_connect sub
    get_pong sub r =
        receive sub >>= \case
            (p', PeerMessage (MPong (Pong r')))
                | p' == p && r' == r -> return ()
            _ -> get_pong sub r

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
