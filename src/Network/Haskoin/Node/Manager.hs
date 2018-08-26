{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
module Network.Haskoin.Node.Manager
    ( manager
    ) where

import           Control.Applicative
import           Control.Concurrent.NQE
import           Control.Concurrent.Unique
import           Control.Monad
import           Control.Monad.Except
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Data.Bits
import           Data.ByteString             (ByteString)
import qualified Data.ByteString             as BS
import           Data.Conduit
import qualified Data.Conduit.Combinators    as CC
import           Data.Function
import           Data.List
import           Data.Maybe
import           Data.Serialize              (Get, Put, Serialize, get, put)
import qualified Data.Serialize              as S
import           Data.String
import           Data.String.Conversions
import           Data.Time.Clock
import           Data.Word
import           Database.RocksDB            (DB)
import           Database.RocksDB.Query
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Network
import           Network.Haskoin.Node.Common
import           Network.Haskoin.Node.Peer
import           Network.Socket              (SockAddr (..))
import           System.Random
import           UnliftIO
import           UnliftIO.Concurrent
import           UnliftIO.Resource

type MonadManager n m
     = ( MonadUnliftIO n
       , MonadLoggerIO n
       , MonadUnliftIO m
       , MonadLoggerIO m
       , MonadReader (ManagerReader n) m)

data OnlinePeer = OnlinePeer
    { onlinePeerAddress     :: !SockAddr
    , onlinePeerConnected   :: !Bool
    , onlinePeerVersion     :: !Word32
    , onlinePeerServices    :: !Word64
    , onlinePeerRemoteNonce :: !Word64
    , onlinePeerUserAgent   :: !ByteString
    , onlinePeerRelay       :: !Bool
    , onlinePeerBestBlock   :: !BlockNode
    , onlinePeerAsync       :: !(Async ())
    , onlinePeerMailbox     :: !Peer
    , onlinePeerNonce       :: !Word64
    , onlinePeerPings       :: ![NominalDiffTime]
    }

data ManagerReader n = ManagerReader
    { mySelf           :: !Manager
    , myChain          :: !Chain
    , myConfig         :: !(ManagerConfig n)
    , myPeerDB         :: !DB
    , myPeerSupervisor :: !(PeerSupervisor n)
    , onlinePeers      :: !(TVar [OnlinePeer])
    , myBloomFilter    :: !(TVar (Maybe BloomFilter))
    , myBestBlock      :: !(TVar BlockNode)
    }

data Priority
    = PriorityNetwork
    | PrioritySeed
    | PriorityManual
    deriving (Eq, Show, Ord)

data PeerAddress
    = PeerAddress { getPeerAddress :: SockAddr }
    | PeerAddressBase
    deriving (Eq, Show)

instance Serialize Priority where
    get =
        S.getWord8 >>= \case
            0x00 -> return PriorityManual
            0x01 -> return PrioritySeed
            0x02 -> return PriorityNetwork
            _ -> mzero
    put PriorityManual  = S.putWord8 0x00
    put PrioritySeed    = S.putWord8 0x01
    put PriorityNetwork = S.putWord8 0x02

instance Serialize PeerAddress where
    get = do
        guard . (== 0x81) =<< S.getWord8
        record <|> return PeerAddressBase
      where
        record = do
            getPeerAddress <- decodeSockAddr
            return PeerAddress {..}
    put PeerAddress {..} = do
        S.putWord8 0x81
        encodeSockAddr getPeerAddress
    put PeerAddressBase = S.putWord8 0x81

data PeerTimeAddress
    = PeerTimeAddress { getPeerPrio        :: !Priority
                      , getPeerBanned      :: !Word32
                      , getPeerLastConnect :: !Word32
                      , getPeerNextConnect :: !Word32
                      , getPeerTimeAddress :: !PeerAddress }
    | PeerTimeAddressBase
    deriving (Eq, Show)

instance Key PeerTimeAddress
instance KeyValue PeerAddress PeerTimeAddress
instance KeyValue PeerTimeAddress PeerAddress

instance Serialize PeerTimeAddress where
    get = do
        guard . (== 0x80) =<< S.getWord8
        record <|> return PeerTimeAddressBase
      where
        record = do
            getPeerPrio <- S.get
            getPeerBanned <- S.get
            getPeerLastConnect <- (maxBound -) <$> S.get
            getPeerNextConnect <- S.get
            getPeerTimeAddress <- S.get
            return PeerTimeAddress {..}
    put PeerTimeAddress {..} = do
        S.putWord8 0x80
        S.put getPeerPrio
        S.put getPeerBanned
        S.put (maxBound - getPeerLastConnect)
        S.put getPeerNextConnect
        S.put getPeerTimeAddress
    put PeerTimeAddressBase = S.putWord8 0x80

manager :: (MonadUnliftIO m, MonadLoggerIO m) => ManagerConfig m -> m ()
manager cfg = do
    bb <- chainGetBest $ mgrConfChain cfg
    opb <- newTVarIO []
    bfb <- newTVarIO Nothing
    bbb <- newTVarIO bb
    withConnectLoop (mgrConfManager cfg) $ do
        let rd =
                ManagerReader
                { mySelf = mgrConfManager cfg
                , myChain = mgrConfChain cfg
                , myConfig = cfg
                , myPeerDB = mgrConfDB cfg
                , myPeerSupervisor = mgrConfPeerSupervisor cfg
                , onlinePeers = opb
                , myBloomFilter = bfb
                , myBestBlock = bbb
                }
        run `runReaderT` rd
  where
    run = do
        connectNewPeers
        managerLoop

resolvePeers :: (MonadUnliftIO m, MonadManager n m) => m [(SockAddr, Priority)]
resolvePeers = do
    cfg <- asks myConfig
    confPeers <-
        fmap
            (map (, PriorityManual) . concat)
            (mapM toSockAddr (mgrConfPeers cfg))
    if mgrConfDiscover cfg
        then do
            seedPeers <-
                fmap
                    (map (, PrioritySeed) . concat)
                    (mapM (toSockAddr . (, defaultPort)) seeds)
            return (confPeers ++ seedPeers)
        else return confPeers

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

connectPeer :: MonadManager n m => SockAddr -> m ()
connectPeer sa = do
    db <- asks myPeerDB
    let k = PeerAddress sa
    retrieve db Nothing k >>= \case
        Nothing -> error "Could not find peer to mark connected"
        Just v -> do
            now <- computeTime
            let v' = v {getPeerLastConnect = now}
            writeBatch
                db
                [deleteOp v, insertOp v' k, insertOp k v']

storePeer :: MonadManager n m => SockAddr -> Priority -> m ()
storePeer sa prio = do
    db <- asks myPeerDB
    let k = PeerAddress sa
    retrieve db Nothing k >>= \case
        Nothing -> do
            let v =
                    PeerTimeAddress
                    { getPeerPrio = prio
                    , getPeerBanned = 0
                    , getPeerLastConnect = 0
                    , getPeerNextConnect = 0
                    , getPeerTimeAddress = k
                    }
            writeBatch
                db
                [insertOp v k, insertOp k v]
        Just v@PeerTimeAddress {..} ->
            when (getPeerPrio < prio) $ do
                let v' = v {getPeerPrio = prio}
                writeBatch
                    db
                    [deleteOp v, insertOp v' k, insertOp k v']
        Just PeerTimeAddressBase ->
            error "Key for peer is corrupted"

banPeer :: MonadManager n m => SockAddr -> m ()
banPeer sa = do
    db <- asks myPeerDB
    let k = PeerAddress sa
    retrieve db Nothing k >>= \case
        Nothing -> error "Cannot find peer to be banned"
        Just v -> do
            now <- computeTime
            let v' =
                    v
                    { getPeerBanned = now
                    , getPeerNextConnect = now + 6 * 60 * 60
                    }
            when (getPeerPrio v == PriorityNetwork) $ do
                $(logWarn) $ logMe <> "Banning peer " <> cs (show sa)
                writeBatch
                    db
                    [deleteOp v, insertOp k v', insertOp v' k]

backoffPeer :: MonadManager n m => SockAddr -> m ()
backoffPeer sa = do
    db <- asks myPeerDB
    onlinePeers <- map onlinePeerAddress <$> getOnlinePeers
    let k = PeerAddress sa
    retrieve db Nothing k >>= \case
        Nothing -> error "Cannot find peer to backoff in database"
        Just v -> do
            now <- computeTime
            r <-
                liftIO . randomRIO $
                if null onlinePeers
                    then (90, 300) -- Don't backoff so much if possibly offline
                    else (900, 1800)
            let t = max (now + r) (getPeerNextConnect v)
                v' = v {getPeerNextConnect = t}
            when (getPeerPrio v == PriorityNetwork) $ do
                $(logWarn) $
                    logMe <> "Backing off peer " <> cs (show sa) <> " for " <>
                    cs (show r) <>
                    " seconds"
                writeBatch db [deleteOp v, insertOp k v', insertOp v' k]

getNewPeer :: (MonadUnliftIO m, MonadManager n m) => m (Maybe SockAddr)
getNewPeer = do
    ManagerConfig {..} <- asks myConfig
    online_peers <- map onlinePeerAddress <$> getOnlinePeers
    config_peers <- concat <$> mapM toSockAddr mgrConfPeers
    if mgrConfDiscover
        then do
            db <- asks myPeerDB
            now <- computeTime
            runResourceT . runConduit $
                matching db Nothing PeerTimeAddressBase .|
                CC.filter ((<= now) . getPeerNextConnect . fst) .|
                CC.map (getPeerAddress . snd) .|
                CC.find (not . (`elem` online_peers))
        else return $ find (not . (`elem` online_peers)) config_peers

getConnectedPeers :: MonadManager n m => m [OnlinePeer]
getConnectedPeers = filter onlinePeerConnected <$> getOnlinePeers

withConnectLoop :: (MonadUnliftIO m, MonadLoggerIO m) => Manager -> m a -> m a
withConnectLoop mgr f = withAsync go $ const f
  where
    go =
        forever $ do
            ManagerPing `send` mgr
            i <- liftIO (randomRIO (30, 90))
            threadDelay (i * 1000 * 1000)

managerLoop :: (MonadUnliftIO m, MonadManager n m) => m ()
managerLoop =
    forever $ do
        mgr <- asks mySelf
        msg <- receive mgr
        processManagerMessage msg

processManagerMessage ::
       (MonadUnliftIO m, MonadManager n m) => ManagerMessage -> m ()

processManagerMessage (ManagerSetFilter bf) = setFilter bf

processManagerMessage (ManagerSetBest bb) =
    asks myBestBlock >>= atomically . (`writeTVar` bb)

processManagerMessage ManagerPing = connectNewPeers

processManagerMessage (ManagerGetAddr p) = do
    pn <- peerString p
    $(logWarn) $ logMe <> "Ignoring address request from peer " <> fromString pn

processManagerMessage (ManagerNewPeers p as) =
    asks myConfig >>= \case
        ManagerConfig {..}
            | not mgrConfDiscover -> return ()
            | otherwise -> do
                pn <- peerString p
                $(logInfo) $
                    logMe <> "Received " <> cs (show (length as)) <>
                    " peers from " <>
                    fromString pn
                forM_ as $ \(_, na) ->
                    let sa = naAddress na
                    in storePeer sa PriorityNetwork

processManagerMessage (ManagerKill e p) =
    findPeer p >>= \case
        Nothing -> return ()
        Just op -> do
            $(logError) $
                logMe <> "Killing peer " <> cs (show (onlinePeerAddress op))
            banPeer $ onlinePeerAddress op
            onlinePeerAsync op `cancelWith` e

processManagerMessage (ManagerSetPeerBest p bn) = modifyPeer f p
  where
    f op = op {onlinePeerBestBlock = bn}

processManagerMessage (ManagerGetPeerBest p reply) =
    findPeer p >>= \op -> atomically (reply (fmap onlinePeerBestBlock op))

processManagerMessage (ManagerSetPeerVersion p v) =
    modifyPeer f p >> findPeer p >>= \case
        Nothing -> return ()
        Just op ->
            runExceptT testVersion >>= \case
                Left ex -> do
                    banPeer (onlinePeerAddress op)
                    onlinePeerAsync op `cancelWith` ex
                Right () -> do
                    loadFilter
                    askForPeers
                    connectPeer (onlinePeerAddress op)
                    announcePeer
  where
    f op =
        op
        { onlinePeerVersion = version v
        , onlinePeerServices = services v
        , onlinePeerRemoteNonce = verNonce v
        , onlinePeerUserAgent = getVarString (userAgent v)
        , onlinePeerRelay = relay v
        }
    testVersion = do
        when (services v .&. nodeNetwork == 0) $ throwError NotNetworkPeer
        bfb <- asks myBloomFilter
        bf <- readTVarIO bfb
        when (isJust bf && services v .&. nodeBloom == 0) $
            throwError BloomFiltersNotSupported
        myself <-
            any ((verNonce v ==) . onlinePeerNonce) <$> lift getOnlinePeers
        when myself $ throwError PeerIsMyself
    loadFilter = do
        bfb <- asks myBloomFilter
        bf <- readTVarIO bfb
        case bf of
            Nothing -> return ()
            Just b  -> b `peerSetFilter` p
    askForPeers =
        mgrConfDiscover <$> asks myConfig >>= \discover ->
            when discover (MGetAddr `sendMessage` p)
    announcePeer =
        findPeer p >>= \case
            Nothing -> return ()
            Just op
                | onlinePeerConnected op -> return ()
                | otherwise -> do
                    $(logInfo) $
                        logMe <> "Connected to " <>
                        cs (show (onlinePeerAddress op))
                    l <- mgrConfMgrListener <$> asks myConfig
                    atomically (l (ManagerConnect p))
                    ch <- asks myChain
                    chainNewPeer p ch
                    setPeerAnnounced p

processManagerMessage (ManagerGetPeerVersion p reply) =
    fmap onlinePeerVersion <$> findPeer p >>= atomically . reply

processManagerMessage (ManagerGetPeers reply) =
    getPeers >>= atomically . reply

processManagerMessage (ManagerPeerPing p i) =
    modifyPeer (\x -> x {onlinePeerPings = take 11 $ i : onlinePeerPings x}) p

processManagerMessage (PeerStopped (p, _ex)) = do
    opb <- asks onlinePeers
    m <- atomically $ do
        m <- findPeerAsync p opb
        when (isJust m) $ removePeer p opb
        return m
    case m of
        Just op -> do
            backoffPeer (onlinePeerAddress op)
            processPeerOffline op
        Nothing -> return ()

processPeerOffline :: MonadManager n m => OnlinePeer -> m ()
processPeerOffline op
    | onlinePeerConnected op = do
        let p = onlinePeerMailbox op
        $(logWarn) $
            logMe <> "Disconnected peer " <> cs (show (onlinePeerAddress op))
        asks myChain >>= chainRemovePeer p
        l <- mgrConfMgrListener <$> asks myConfig
        atomically (l (ManagerDisconnect p))
    | otherwise =
        $(logWarn) $
        logMe <> "Could not connect to peer " <> cs (show (onlinePeerAddress op))

getPeers :: MonadManager n m => m [Peer]
getPeers = do
    ps <- getConnectedPeers
    return . map onlinePeerMailbox $
        sortBy (compare `on` median . onlinePeerPings) ps

connectNewPeers :: MonadManager n m => m ()
connectNewPeers = do
    mo <- mgrConfMaxPeers <$> asks myConfig
    ps <- getOnlinePeers
    let n = mo - length ps
    case ps of
        [] -> do
            $(logWarn) $ logMe <> "No peers connected"
            ps' <- resolvePeers
            mapM_ (uncurry storePeer) ps'
        _ ->
            $(logInfo) $
            logMe <> "Peers connected: " <> cs (show (length ps)) <> "/" <>
            cs (show mo)
    go n
  where
    go 0 = return ()
    go n =
        getNewPeer >>= \case
            Nothing -> return ()
            Just sa -> conn sa >> go (n - 1)
    conn sa = do
        ad <- mgrConfNetAddr <$> asks myConfig
        mgr <- asks mySelf
        ch <- asks myChain
        pl <- mgrConfPeerListener <$> asks myConfig
        $(logInfo) $ logMe <> "Connecting to peer " <> cs (show sa)
        bbb <- asks myBestBlock
        bb <- readTVarIO bbb
        nonce <- liftIO randomIO
        let pc =
                PeerConfig
                { peerConfConnect = NetworkAddress srv sa
                , peerConfInitBest = bb
                , peerConfLocal = ad
                , peerConfManager = mgr
                , peerConfChain = ch
                , peerConfListener = pl
                , peerConfNonce = nonce
                }
        psup <- asks myPeerSupervisor
        pmbox <- newTBQueueIO 100
        uid <- liftIO newUnique
        let p = UniqueInbox {uniqueInbox = Inbox pmbox, uniqueId = uid}
        a <- psup `addChild` peer pc p
        newPeerConnection sa nonce p a
    srv
        | segWit = 8
        | otherwise = 0

newPeerConnection ::
       MonadManager n m => SockAddr -> Word64 -> Peer -> Async () -> m ()
newPeerConnection sa nonce p a =
    addPeer
        OnlinePeer
        { onlinePeerAddress = sa
        , onlinePeerConnected = False
        , onlinePeerVersion = 0
        , onlinePeerServices = 0
        , onlinePeerRemoteNonce = 0
        , onlinePeerUserAgent = BS.empty
        , onlinePeerRelay = False
        , onlinePeerBestBlock = genesisNode
        , onlinePeerAsync = a
        , onlinePeerMailbox = p
        , onlinePeerNonce = nonce
        , onlinePeerPings = []
        }

peerString :: MonadManager n m => Peer -> m String
peerString p = maybe "unknown" (show . onlinePeerAddress) <$> findPeer p

setPeerAnnounced :: MonadManager n m => Peer -> m ()
setPeerAnnounced = modifyPeer (\x -> x {onlinePeerConnected = True})

setFilter :: MonadManager n m => BloomFilter -> m ()
setFilter bl = do
    bfb <- asks myBloomFilter
    atomically . writeTVar bfb $ Just bl
    ops <- getOnlinePeers
    forM_ ops $ \op ->
        when (onlinePeerConnected op) $
        if acceptsFilters $ onlinePeerServices op
            then bl `peerSetFilter` onlinePeerMailbox op
            else do
                $(logError) $
                    logMe <> "Peer " <> cs (show (onlinePeerAddress op)) <>
                    "does not support bloom filters"
                banPeer (onlinePeerAddress op)
                onlinePeerAsync op `cancelWith` BloomFiltersNotSupported

logMe :: IsString a => a
logMe = "[Manager] "

findPeer :: MonadManager n m => Peer -> m (Maybe OnlinePeer)
findPeer p = find ((== p) . onlinePeerMailbox) <$> getOnlinePeers

findPeerAsync :: Async () -> TVar [OnlinePeer] -> STM (Maybe OnlinePeer)
findPeerAsync a t = find ((== a) . onlinePeerAsync) <$> readTVar t

modifyPeer :: MonadManager n m => (OnlinePeer -> OnlinePeer) -> Peer -> m ()
modifyPeer f p = modifyOnlinePeers $ map upd
  where
    upd op =
        if onlinePeerMailbox op == p
            then f op
            else op

addPeer :: MonadManager n m => OnlinePeer -> m ()
addPeer op = modifyOnlinePeers $ nubBy f . (op :)
  where
    f = (==) `on` onlinePeerMailbox

removePeer :: Async () -> TVar [OnlinePeer] -> STM ()
removePeer a t = modifyTVar t $ filter ((/= a) . onlinePeerAsync)

getOnlinePeers :: MonadManager n m => m [OnlinePeer]
getOnlinePeers = asks onlinePeers >>= atomically . readTVar

modifyOnlinePeers :: MonadManager n m => ([OnlinePeer] -> [OnlinePeer]) -> m ()
modifyOnlinePeers f = asks onlinePeers >>= atomically . (`modifyTVar` f)

median :: Fractional a => [a] -> Maybe a
median ls
    | null ls = Nothing
    | length ls `mod` 2 == 0 =
        Just . (/ 2) . sum . take 2 $ drop (length ls `div` 2 - 1) ls
    | otherwise = Just . head $ drop (length ls `div` 2) ls
