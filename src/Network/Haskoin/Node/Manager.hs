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
import           Data.Bits
import qualified Data.ByteString             as BS
import           Data.Default
import           Data.Function
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
import           Network.Haskoin.Node.Peer
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
    }

data PeerAddress
    = PeerAddress { getPeerAddress :: SockAddr }
    | PeerAddressBase
    deriving (Eq, Show)

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

newtype PeerAddressData
    = PeerAddressData { getPeerLastConnect :: Word32 }
    deriving (Eq, Show)

instance KeyValue PeerAddress PeerAddressData

instance Serialize PeerAddressData where
    get = do
        guard . (== 0x80) =<< S.getWord8
        getPeerLastConnect <- (maxBound -) <$> S.get
        return PeerAddressData {..}
    put PeerAddressData {..} = do
        S.putWord8 0x80
        S.put (maxBound - getPeerLastConnect)

manager :: (MonadUnliftIO m, MonadLoggerIO m) => ManagerConfig -> m ()
manager cfg = do
    psup <- newInbox =<< newTQueueIO
    withAsync (supervisor (Notify dead) psup []) $ \sup -> do
        link sup
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
                        , myPeerSupervisor = psup
                        , onlinePeers = opb
                        , myBloomFilter = bfb
                        , myBestBlock = bbb
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
    let k = PeerAddress sa
    retrieve db def k >>= \case
        Nothing -> throwString "Could not find peer to mark connected"
        Just v -> do
            now <- computeTime
            R.insert db k v {getPeerLastConnect = now}
            logPeersConnected


logPeersConnected :: MonadManager n m => m ()
logPeersConnected = do
    mo <- mgrConfMaxPeers <$> asks myConfig
    ps <- getOnlinePeers
    $(logInfoS) "Manager" $
        "Peers connected: " <> cs (show (length ps)) <> "/" <> cs (show mo)

storePeer :: MonadManager n m => SockAddr -> m ()
storePeer sa = do
    db <- asks myPeerDB
    let k = PeerAddress sa
    retrieve db def k >>= \case
        Nothing -> do
            let v = PeerAddressData {getPeerLastConnect = 0}
            R.insert db k v
        Just PeerAddressData {} -> return ()

getNewPeer :: (MonadUnliftIO m, MonadManager n m) => m (Maybe SockAddr)
getNewPeer = do
    ManagerConfig {..} <- asks myConfig
    online_peers <- map onlinePeerAddress <$> getOnlinePeers
    config_peers <- concat <$> mapM toSockAddr mgrConfPeers
    if mgrConfDiscover
        then do
            db <- asks myPeerDB
            ps <-
                U.runResourceT . runConduit $
                matching db def PeerAddressBase .|
                filterC (not . (`elem` online_peers) . getPeerAddress . fst) .|
                sinkList
            case ps of
                [] -> return Nothing
                _ -> do
                    $(logDebugS) "Manager" $
                        "Selecting a peer out of " <> cs (show (length ps)) <>
                        " available"
                    i <- liftIO $ randomRIO (0, length ps - 1)
                    return . Just . getPeerAddress . fst $
                        (ps :: [(PeerAddress, PeerAddressData)]) !! i
        else return $ find (not . (`elem` online_peers)) config_peers

getConnectedPeers :: MonadManager n m => m [OnlinePeer]
getConnectedPeers = filter onlinePeerConnected <$> getOnlinePeers

withConnectLoop :: (MonadUnliftIO m, MonadLoggerIO m) => Manager -> m a -> m a
withConnectLoop mgr f = withAsync go $ const f
  where
    go =
        forever $ do
            ManagerPing `send` mgr
            i <- liftIO (randomRIO (100000, 900000))
            threadDelay i

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
                    in storePeer sa

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

processManagerMessage (PeerStopped (p, _ex)) = do
    opb <- asks onlinePeers
    m <- atomically $ do
        m <- findPeerAsync p opb
        when (isJust m) $ removePeer p opb
        return m
    forM_ m processPeerOffline

processPeerOffline :: MonadManager n m => OnlinePeer -> m ()
processPeerOffline op
    | onlinePeerConnected op = do
        let p = onlinePeerMailbox op
        $(logWarnS) "Manager" $
            "Disconnected peer " <> cs (show (onlinePeerAddress op))
        asks myChain >>= chainRemovePeer p
        l <- mgrConfMgrListener <$> asks myConfig
        atomically (l (ManagerDisconnect p))
        logPeersConnected
    | otherwise =
        $(logWarnS) "Manager" $
        "Could not connect to peer " <> cs (show (onlinePeerAddress op))

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
            Nothing -> do
                $(logInfoS) "Manager" "Populating empty peer list..."
                initialPeers >>= mapM_ storePeer
            Just sa -> conn sa
  where
    conn sa = do
        ad <- mgrConfNetAddr <$> asks myConfig
        mgr <- asks mySelf
        ch <- asks myChain
        pl <- mgrConfPeerListener <$> asks myConfig
        net <- mgrConfNetwork <$> asks myConfig
        $(logInfoS) "Manager" $ "Connecting to peer " <> cs (show sa)
        nonce <- liftIO randomIO
        bb <- chainGetBest ch
        let rmt = NetworkAddress (srv net) sa
        ver <- buildVersion net nonce (nodeHeight bb) ad rmt
        let pc =
                PeerConfig
                    { peerConfManager = mgr
                    , peerConfChain = ch
                    , peerConfListener = pl
                    , peerConfNetwork = net
                    , peerConfName = cs $ show sa
                    , peerConfConnect = withConnection sa
                    , peerConfVersion = ver
                    }
        psup <- asks myPeerSupervisor
        pmbox <- newTBQueueIO 100
        p <- newInbox pmbox
        a <- psup `addChild` peer pc p
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
