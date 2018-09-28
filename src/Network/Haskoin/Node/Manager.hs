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

import           Conduit
import           Control.Applicative
import           Control.Monad
import           Control.Monad.Except
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.Trans.Maybe
import           Data.Bits
import qualified Data.ByteString             as BS
import           Data.Default
import           Data.Function
import           Data.Hashable
import           Data.List
import           Data.Maybe
import           Data.Serialize              (Get, Put, Serialize, get, put)
import qualified Data.Serialize              as S
import           Data.String
import           Data.String.Conversions
import           Data.Word
import           Database.RocksDB            (DB)
import           Database.RocksDB.Query      as R
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Network
import           Network.Haskoin.Node.Common
import           Network.Socket              (SockAddr (..))
import           NQE
import           System.Random
import           UnliftIO
import           UnliftIO.Concurrent
import           UnliftIO.Resource           as U

type MonadManager n m
     = ( MonadUnliftIO n
       , MonadLoggerIO n
       , MonadUnliftIO m
       , MonadLoggerIO m
       , MonadReader (ManagerReader n) m)

data ManagerReader m = ManagerReader
    { mySelf           :: !Manager
    , myChain          :: !Chain
    , myConfig         :: !ManagerConfig
    , myPeerDB         :: !DB
    , myPeerSupervisor :: !(Inbox (SupervisorMessage m))
    , onlinePeers      :: !(TVar [OnlinePeer])
    , myBloomFilter    :: !(TVar (Maybe BloomFilter))
    , myBestBlock      :: !(TVar BlockNode)
    , myPeerConnect    :: !(PeerConfig -> m ())
    }

data PeerAddress
    = PeerAddress { getPeerDirty   :: !Bool
                  , getPeerHash    :: !Int -- ^ randomize peer sort order a bit
                  , getPeerAddress :: !SockAddr }
    | PeerAddressBase
    deriving (Eq, Ord, Show)

instance Serialize PeerAddress where
    get = do
        guard . (== 0x81) =<< S.getWord8
        getPeerDirty <- get
        getPeerHash <- get
        getPeerAddress <- decodeSockAddr
        return PeerAddress {..}
    put PeerAddress {..} = do
        S.putWord8 0x81
        put getPeerDirty
        put getPeerHash
        encodeSockAddr getPeerAddress
    put PeerAddressBase = S.putWord8 0x81

data PeerAddressData = PeerAddressData
    { getPeerFailCount   :: !Word32
    , getPeerLastConnect :: !Word32
    , getPeerLastFail    :: !Word32
    } deriving (Eq, Show)

instance Ord PeerAddressData where
    compare = compare `on` f
      where
        f PeerAddressData {..} =
            (getPeerFailCount, maxBound - getPeerLastConnect, getPeerLastFail)

instance Key PeerAddress
instance KeyValue PeerAddress PeerAddressData

instance Serialize PeerAddressData where
    get = do
        guard . (== 0x80) =<< S.getWord8
        getPeerLastFail <- S.get
        getPeerFailCount <- S.get
        getPeerLastConnect <- S.get
        return PeerAddressData {..}
    put PeerAddressData {..} = do
        S.putWord8 0x80
        S.put getPeerLastFail
        S.put getPeerFailCount
        S.put getPeerLastConnect

manager ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => ManagerConfig
    -> (PeerConfig -> m ())
    -> m ()
manager cfg pconn = do
    psup <- newInbox =<< newTQueueIO
    withAsync (supervisor (Notify dead) psup []) $ \sup -> do
        link sup
        bb <- chainGetBest $ mgrConfChain cfg
        opb <- newTVarIO []
        bfb <- newTVarIO Nothing
        bbb <- newTVarIO bb
        withConnectLoop cfg $ do
            let rd =
                    ManagerReader
                        { mySelf = mgrConfManager cfg
                        , myChain = mgrConfChain cfg
                        , myConfig = cfg
                        , myPeerDB = mgrConfDB cfg
                        , myPeerSupervisor = psup
                        , onlinePeers = opb
                        , myBloomFilter = bfb
                        , myBestBlock = bbb
                        , myPeerConnect = pconn
                        }
            run `runReaderT` rd
  where
    dead ex = PeerStopped ex `sendSTM` mgrConfManager cfg
    run = managerLoop

initialPeers :: (MonadUnliftIO m, MonadManager n m) => m [SockAddr]
initialPeers = do
    cfg <- asks myConfig
    let net = mgrConfNetwork cfg
    confPeers <- concat <$> mapM toSockAddr (mgrConfPeers cfg)
    if mgrConfDiscover cfg
        then do
            seedPeers <-
                concat <$>
                mapM (toSockAddr . (, getDefaultPort net)) (getSeeds net)
            return $ confPeers <> seedPeers
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
    let k = PeerAddress False (hash (show sa)) sa
    getPeer sa >>= \case
        Nothing ->
            $(logErrorS) "Manager" $
                "Could not find peer to mark connected: " <> cs (show sa)
        Just v -> do
            now <- computeTime
            R.remove db k {getPeerDirty = True}
            R.insert
                db
                k
                v
                    { getPeerLastConnect = now
                    , getPeerFailCount = 0
                    , getPeerLastFail = 0
                    }
            logPeersConnected

getPeer :: MonadManager n m => SockAddr -> m (Maybe PeerAddressData)
getPeer sa =
    asks myPeerDB >>= \db ->
        runMaybeT $
        MaybeT (retrieve db def (PeerAddress False (hash (show sa)) sa)) <|>
        MaybeT (retrieve db def (PeerAddress True (hash (show sa)) sa))


logPeersConnected :: MonadManager n m => m ()
logPeersConnected = do
    mo <- mgrConfMaxPeers <$> asks myConfig
    ps <- getOnlinePeers
    $(logInfoS) "Manager" $
        "Peers connected: " <> cs (show (length ps)) <> "/" <> cs (show mo)

backOffPeer :: MonadManager n m => SockAddr -> m ()
backOffPeer sa = do
    db <- asks myPeerDB
    let k = PeerAddress True (hash (show sa)) sa
    now <- computeTime
    getPeer sa >>= \case
        Nothing -> do
            $(logErrorS) "Manager" $
                "Could not find peer to back off: " <> cs (show sa)
            let v =
                    PeerAddressData
                        { getPeerFailCount = 1
                        , getPeerLastConnect = 0
                        , getPeerLastFail = now
                        }
            R.insert db k v
        Just v -> do
            let v' =
                    v
                        { getPeerFailCount = getPeerFailCount v + 1
                        , getPeerLastFail = now
                        }
            R.remove db k {getPeerDirty = False}
            R.insert db k v'

storePeer :: MonadManager n m => Bool -> SockAddr -> m ()
storePeer override sa =
    if override
        then new_entry
        else getPeer sa >>= \case
                 Nothing -> new_entry
                 Just _ -> return ()
  where
    new_entry = do
        db <- asks myPeerDB
        let k = PeerAddress (not override) (hash (show sa)) sa
        let v =
                PeerAddressData
                    { getPeerFailCount = 0
                    , getPeerLastConnect = 0
                    , getPeerLastFail = 0
                    }
        R.remove db k {getPeerDirty = override}
        R.insert db k v


getNewPeer :: (MonadUnliftIO m, MonadManager n m) => m (Maybe SockAddr)
getNewPeer = do
    ManagerConfig {..} <- asks myConfig
    ops <- map onlinePeerAddress <$> getOnlinePeers
    now <- computeTime
    if mgrConfDiscover
        then do
            db <- asks myPeerDB
            U.runResourceT . runConduit $
                matching db def PeerAddressBase .| filterC (f now ops) .|
                mapC g .|
                headC
        else do
            config_peers <- concat <$> mapM toSockAddr mgrConfPeers
            return $ find (`notElem` ops) config_peers
  where
    f now online_peers (PeerAddress {..}, PeerAddressData {..}) =
        let is_not_connected = getPeerAddress `notElem` online_peers
            back_off = min getPeerFailCount 60 * 60
            post_back_off = getPeerLastFail + back_off < now
         in is_not_connected && post_back_off
    f _ _ _ = undefined
    g (PeerAddress {..}, PeerAddressData {}) = getPeerAddress
    g _                                      = undefined

getConnectedPeers :: MonadManager n m => m [OnlinePeer]
getConnectedPeers = filter onlinePeerConnected <$> getOnlinePeers

withConnectLoop ::
       (MonadUnliftIO m, MonadLoggerIO m) => ManagerConfig -> m a -> m a
withConnectLoop conf f = withAsync go $ \a -> link a >> f
  where
    go = do
        let i = mgrConfConnectInterval conf * 1000 * 1000 `div` 4
        forever $ do
            ManagerPing `send` mgrConfManager conf
            threadDelay =<< liftIO (randomRIO (i * 3, i * 5))

managerLoop :: (MonadUnliftIO m, MonadManager n m) => m ()
managerLoop = do
    mgr <- asks mySelf
    forever $ receive mgr >>= processManagerMessage

processManagerMessage ::
       (MonadUnliftIO m, MonadManager n m) => ManagerMessage -> m ()

processManagerMessage (ManagerSetFilter bf) = setFilter bf

processManagerMessage (ManagerSetBest bb) =
    asks myBestBlock >>= atomically . (`writeTVar` bb)

processManagerMessage ManagerPing = connectNewPeers

processManagerMessage (ManagerGetAddr p) = do
    pn <- peerString p
    -- TODO: send list of peers we know about
    $(logWarnS) "Manager" $ "Ignoring address request from peer " <> fromString pn

processManagerMessage (ManagerNewPeers p as) =
    asks myConfig >>= \case
        ManagerConfig {..}
            | not mgrConfDiscover -> return ()
            | otherwise -> do
                pn <- peerString p
                $(logInfoS) "Manager" $
                    "Received " <> cs (show (length as)) <>
                    " peers from " <>
                    fromString pn
                forM_ as $ \(_, na) ->
                    let sa = naAddress na
                    in storePeer False sa

processManagerMessage (ManagerKill e p) =
    findPeer p >>= \case
        Nothing -> return ()
        Just op -> do
            $(logErrorS) "Manager" $
                "Killing peer " <> cs (show (onlinePeerAddress op))
            onlinePeerAsync op `cancelWith` e

processManagerMessage (ManagerSetPeerVersion p v) =
    modifyPeer f p >> findPeer p >>= \case
        Nothing -> return ()
        Just op ->
            runExceptT testVersion >>= \case
                Left ex -> onlinePeerAsync op `cancelWith` ex
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
                    $(logInfoS) "Manager" $
                        "Connected to " <> cs (show (onlinePeerAddress op))
                    l <- mgrConfMgrListener <$> asks myConfig
                    atomically (l (ManagerConnect p))
                    ch <- asks myChain
                    chainNewPeer p ch
                    setPeerAnnounced p

processManagerMessage (ManagerGetPeerVersion p reply) =
    fmap onlinePeerVersion <$> findPeer p >>= atomically . reply

processManagerMessage (ManagerGetPeers reply) =
    getPeers >>= atomically . reply

processManagerMessage (ManagerGetOnlinePeer p reply) =
    getOnlinePeer p >>= atomically . reply

processManagerMessage (ManagerPeerPing p i) =
    modifyPeer (\x -> x {onlinePeerPings = take 11 $ i : onlinePeerPings x}) p

processManagerMessage (PeerStopped (p, _)) = do
    opb <- asks onlinePeers
    m <- atomically $ do
        m <- findPeerAsync p opb
        when (isJust m) $ removePeer p opb
        return m
    mapM_ processPeerOffline m

processPeerOffline ::
       MonadManager n m => OnlinePeer -> m ()
processPeerOffline op
    | onlinePeerConnected op = do
        let p = onlinePeerMailbox op
        $(logWarnS) "Manager" $
            "Disconnected peer " <> cs (show (onlinePeerAddress op))
        asks myChain >>= chainRemovePeer p
        l <- mgrConfMgrListener <$> asks myConfig
        atomically (l (ManagerDisconnect p))
        logPeersConnected
        backOffPeer (onlinePeerAddress op)
    | otherwise = do
        $(logWarnS) "Manager" $
            "Could not connect to peer " <> cs (show (onlinePeerAddress op))
        logPeersConnected
        backOffPeer (onlinePeerAddress op)

getPeers :: MonadManager n m => m [OnlinePeer]
getPeers = sortBy (compare `on` median . onlinePeerPings) <$> getConnectedPeers

getOnlinePeer :: MonadManager n m => Peer -> m (Maybe OnlinePeer)
getOnlinePeer p = find ((== p) . onlinePeerMailbox) <$> getConnectedPeers

connectNewPeers :: MonadManager n m => m ()
connectNewPeers = do
    mo <- mgrConfMaxPeers <$> asks myConfig
    os <- getOnlinePeers
    when (length os < mo) $
        getNewPeer >>= \case
            Nothing ->
                initialPeers >>= \ps -> do
                    mapM_ (storePeer True) ps
                    select_random ps os >>= \case
                        Nothing -> return ()
                        Just sa -> conn sa
            Just sa -> conn sa
  where
    select_random ps os = do
        let os' = map onlinePeerAddress os
            ps' = filter (`notElem` os') ps
        case ps' of
            [] -> return Nothing
            _  -> Just . (ps' !!) <$> liftIO (randomRIO (0, length ps' - 1))
    conn sa = do
        ad <- mgrConfNetAddr <$> asks myConfig
        stale <- mgrConfStale <$> asks myConfig
        mgr <- asks mySelf
        ch <- asks myChain
        pl <- mgrConfPeerListener <$> asks myConfig
        net <- mgrConfNetwork <$> asks myConfig
        $(logInfoS) "Manager" $ "Connecting to peer " <> cs (show sa)
        nonce <- liftIO randomIO
        bb <- chainGetBest ch
        let rmt = NetworkAddress (srv net) sa
        ver <- buildVersion net nonce (nodeHeight bb) ad rmt
        pmbox <- newTBQueueIO 100
        p <- newInbox pmbox
        let pc =
                PeerConfig
                    { peerConfManager = mgr
                    , peerConfChain = ch
                    , peerConfListener = pl
                    , peerConfNetwork = net
                    , peerConfName = cs $ show sa
                    , peerConfConnect = withConnection sa
                    , peerConfVersion = ver
                    , peerConfStale = stale
                    , peerConfMailbox = p
                    }
        psup <- asks myPeerSupervisor
        pconn <- asks myPeerConnect
        a <- psup `addChild` pconn pc
        newPeerConnection sa nonce p a
    srv net
        | getSegWit net = 8
        | otherwise = 0

newPeerConnection ::
       MonadManager n m
    => SockAddr
    -> Word64
    -> Peer
    -> Async ()
    -> m ()
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
        , onlinePeerAsync = a
        , onlinePeerMailbox = p
        , onlinePeerNonce = nonce
        , onlinePeerPings = []
        }

peerString :: MonadManager n m => Peer -> m String
peerString p = maybe "[unknown]" (show . onlinePeerAddress) <$> findPeer p

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
                $(logErrorS) "Manager" $
                    "Peer " <> cs (show (onlinePeerAddress op)) <>
                    "does not support bloom filters"
                onlinePeerAsync op `cancelWith` BloomFiltersNotSupported

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
getOnlinePeers = asks onlinePeers >>= readTVarIO

modifyOnlinePeers :: MonadManager n m => ([OnlinePeer] -> [OnlinePeer]) -> m ()
modifyOnlinePeers f = asks onlinePeers >>= atomically . (`modifyTVar` f)

median :: Fractional a => [a] -> Maybe a
median ls
    | null ls = Nothing
    | length ls `mod` 2 == 0 =
        Just . (/ 2) . sum . take 2 $ drop (length ls `div` 2 - 1) ls
    | otherwise = Just . head $ drop (length ls `div` 2) ls
