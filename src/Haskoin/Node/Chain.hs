{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE UndecidableInstances      #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Haskoin.Node.Chain
    ( ChainConfig (..)
    , ChainEvent (..)
    , Chain
    , withChain
    , chainGetBlock
    , chainGetBest
    , chainGetAncestor
    , chainGetParents
    , chainGetSplitBlock
    , chainPeerConnected
    , chainPeerDisconnected
    , chainIsSynced
    , chainBlockMain
    , chainHeaders
    ) where

import           Control.Monad             (forM_, forever, guard, when)
import           Control.Monad.Except      (runExceptT, throwError)
import           Control.Monad.Logger      (MonadLoggerIO, logDebugS, logErrorS,
                                            logInfoS)
import           Control.Monad.Reader      (MonadReader, ReaderT, ask, asks,
                                            runReaderT)
import           Control.Monad.Trans       (lift)
import           Control.Monad.Trans.Maybe (MaybeT (..), runMaybeT)
import qualified Data.ByteString           as B
import           Data.Default              (def)
import           Data.Function             (on)
import           Data.List                 (delete, nub)
import           Data.Maybe                (isJust, isNothing)
import           Data.Serialize            (Serialize, get, getWord8, put,
                                            putWord8)
import           Data.String.Conversions   (cs)
import           Data.Time.Clock           (NominalDiffTime, UTCTime,
                                            diffUTCTime, getCurrentTime)
import           Data.Time.Clock.POSIX     (posixSecondsToUTCTime,
                                            utcTimeToPOSIXSeconds)
import           Data.Word                 (Word32)
import           Database.RocksDB          (DB)
import qualified Database.RocksDB          as R
import           Database.RocksDB.Query    (Key, KeyValue, insert, insertOp,
                                            retrieve, writeBatch)
import           Haskoin                   (BlockHash, BlockHeader (..),
                                            BlockHeaders (..), BlockHeight,
                                            BlockNode (..), GetHeaders (..),
                                            Message (..), Network, blockLocator,
                                            connectBlocks, genesisNode,
                                            getAncestor, headerHash, splitPoint)
import           Haskoin.Node.Manager      (myVersion)
import           Haskoin.Node.Peer
import           NQE                       (Mailbox, Publisher, newMailbox,
                                            publish, receive, send)
import           System.Random             (randomRIO)
import           UnliftIO                  (MonadIO, MonadUnliftIO, TVar,
                                            atomically, liftIO, link,
                                            modifyTVar, newTVarIO, readTVar,
                                            readTVarIO, withAsync, writeTVar)
import           UnliftIO.Concurrent       (threadDelay)

-- | Mailbox for chain header syncing process.
data Chain = Chain { chainMailbox :: !(Mailbox ChainMessage)
                   , chainReader  :: !ChainReader
                   }

instance Eq Chain where
    (==) = (==) `on` chainMailbox

-- | Configuration for chain syncing process.
data ChainConfig =
    ChainConfig
        { chainConfDB      :: !DB
          -- ^ database handle
        , chainConfNetwork :: !Network
          -- ^ network constants
        , chainConfEvents  :: !(Publisher ChainEvent)
          -- ^ send header chain events here
        , chainConfTimeout :: !NominalDiffTime
          -- ^ timeout in seconds
        }

data ChainMessage
    = ChainHeaders !Peer ![BlockHeader]
    | ChainPeerConnected !Peer
    | ChainPeerDisconnected !Peer
    | ChainPing

-- | Events originating from chain syncing process.
data ChainEvent
    = ChainBestBlock !BlockNode
      -- ^ chain has new best block
    | ChainSynced !BlockNode
      -- ^ chain is in sync with the network
    deriving (Eq, Show)

type MonadChain m =
    ( MonadLoggerIO m
    , MonadUnliftIO m
    , MonadReader ChainReader m )

-- | Reader for header synchronization code.
data ChainReader = ChainReader
    { myConfig   :: !ChainConfig
      -- ^ placeholder for upstream data
    , chainState :: !(TVar ChainState)
      -- ^ mutable state for header synchronization
    }

-- | Database key for version.
data ChainDataVersionKey = ChainDataVersionKey
    deriving (Eq, Ord, Show)

instance Key ChainDataVersionKey
instance KeyValue ChainDataVersionKey Word32

instance Serialize ChainDataVersionKey where
    get = do
        guard . (== 0x92) =<< getWord8
        return ChainDataVersionKey
    put ChainDataVersionKey = putWord8 0x92

data ChainSync = ChainSync
    { chainSyncPeer  :: !Peer
    , chainTimestamp :: !UTCTime
    , chainHighest   :: !(Maybe BlockNode)
    }

-- | Mutable state for the header chain process.
data ChainState = ChainState
    { chainSyncing :: !(Maybe ChainSync)
      -- ^ peer to sync against and time of last received message
    , newPeers     :: ![Peer]
      -- ^ queue of peers to sync against
    , mySynced     :: !Bool
      -- ^ has the header chain ever been considered synced?
    }

-- | Key for block header in database.
newtype BlockHeaderKey = BlockHeaderKey BlockHash deriving (Eq, Show)

instance Serialize BlockHeaderKey where
    get = do
        guard . (== 0x90) =<< getWord8
        BlockHeaderKey <$> get
    put (BlockHeaderKey bh) = do
        putWord8 0x90
        put bh

-- | Key for best block in database.
data BestBlockKey = BestBlockKey deriving (Eq, Show)

instance KeyValue BlockHeaderKey BlockNode
instance KeyValue BestBlockKey BlockNode

instance Serialize BestBlockKey where
    get = do
        guard . (== 0x91) =<< getWord8
        return BestBlockKey
    put BestBlockKey = putWord8 0x91

instance (Monad m, MonadIO m, MonadReader DB m) =>
         BlockHeaders m where
    addBlockHeader bn = do
        db <- ask
        insert db (BlockHeaderKey h) bn
      where
        h = headerHash (nodeHeader bn)
    getBlockHeader bh = do
        db <- ask
        retrieve db def (BlockHeaderKey bh)
    getBestBlockHeader = do
        db <- ask
        retrieve db def BestBlockKey >>= \case
            Nothing -> error "Could not get best block from database"
            Just b -> return b
    setBestBlockHeader bn = do
        db <- ask
        insert db BestBlockKey bn
    addBlockHeaders bns = do
        db <- ask
        writeBatch db (map f bns)
      where
        h bn = headerHash (nodeHeader bn)
        f bn = insertOp (BlockHeaderKey (h bn)) bn

withBlockHeaders :: MonadChain m => ReaderT DB m a -> m a
withBlockHeaders f = do
    db <- asks (chainConfDB . myConfig)
    runReaderT f db

-- | Launch process to synchronize block headers in current thread.
withChain ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => ChainConfig
    -> (Chain -> m a)
    -> m a
withChain cfg action = do
    (inbox, mailbox) <- newMailbox
    $(logDebugS) "Chain" "Starting chain actor"
    st <- newTVarIO ChainState { chainSyncing = Nothing
                               , mySynced = False
                               , newPeers = []
                               }
    let rd = ChainReader { myConfig = cfg
                         , chainState = st
                         }
        ch = Chain { chainReader = rd
                   , chainMailbox = mailbox
                   }
    withAsync (main_loop ch rd inbox) $ \a ->
        link a >> action ch
  where
    main_loop ch rd inbox = withSyncLoop ch $
        run inbox `runReaderT` rd
    run inbox = do
        initChainDB
        withBlockHeaders getBestBlockHeader >>=
            chainEvent . ChainBestBlock
        forever $ do
            msg <- receive inbox
            chainMessage msg

chainEvent :: MonadChain m => ChainEvent -> m ()
chainEvent e = do
    pub <- asks (chainConfEvents . myConfig)
    case e of
        ChainBestBlock b ->
            $(logInfoS) "Chain" $
            "Best block header at height: "
            <> cs (show (nodeHeight b))
        ChainSynced b ->
            $(logInfoS) "Chain" $
            "Headers in sync at height: "
            <> cs (show (nodeHeight b))
    publish e pub

processHeaders :: MonadChain m => Peer -> [BlockHeader] -> m ()
processHeaders p hs = do
    $(logDebugS) "Chain" $
        "Processing " <> cs (show (length hs))
        <> " headers from peer: " <> peerText p
    net <- asks (chainConfNetwork . myConfig)
    now <- liftIO getCurrentTime
    pbest <- withBlockHeaders getBestBlockHeader
    importHeaders net now hs >>= \case
        Left e -> do
            $(logErrorS) "Chain" $
                "Could not connect headers from peer: "
                <> peerText p
            e `killPeer` p
        Right done -> do
            setLastReceived
            best <- withBlockHeaders getBestBlockHeader
            when (nodeHeader pbest /= nodeHeader best) $
                chainEvent (ChainBestBlock best)
            if done
                then do
                    MSendHeaders `sendMessage` p
                    finishPeer p
                    syncNewPeer
                    syncNotif
                else syncPeer p

syncNewPeer :: MonadChain m => m ()
syncNewPeer = getSyncingPeer >>= \case
    Just _  -> return ()
    Nothing -> nextPeer >>= \case
        Nothing -> return ()
        Just p -> do
            $(logDebugS) "Chain" $
                "Syncing against peer: " <> peerText p
            syncPeer p

syncNotif :: MonadChain m => m ()
syncNotif =
    notifySynced >>= \case
        False -> return ()
        True  -> withBlockHeaders getBestBlockHeader >>=
                 chainEvent . ChainSynced

syncPeer :: MonadChain m => Peer -> m ()
syncPeer p = do
    t <- liftIO getCurrentTime
    m <- chainSyncingPeer >>= \case
        Just ChainSync { chainSyncPeer = s
                       , chainHighest = m
                       }
            | p == s -> syncing_me t m
            | otherwise -> return Nothing
        Nothing -> syncing_new t
    forM_ m $ \g -> do
        $(logDebugS) "Chain" $
            "Requesting headers from peer: "
            <> peerText p
        MGetHeaders g `sendMessage` p
  where
    syncing_new t =
        setSyncingPeer p >>= \case
            False -> return Nothing
            True -> do
                $(logDebugS) "Chain" $
                    "Locked peer: " <> peerText p
                h <- withBlockHeaders getBestBlockHeader
                Just <$> syncHeaders t h p
    syncing_me t m = do
        h <- case m of
                 Nothing -> withBlockHeaders getBestBlockHeader
                 Just h  -> return h
        Just <$> syncHeaders t h p

chainMessage :: MonadChain m => ChainMessage -> m ()

chainMessage (ChainHeaders p hs) =
    processHeaders p hs

chainMessage (ChainPeerConnected p) = do
    $(logDebugS) "Chain" $ "Peer connected: " <> peerText p
    addPeer p
    syncNewPeer

chainMessage (ChainPeerDisconnected p) = do
    $(logDebugS) "Chain" $ "Peer disconnected: " <> peerText p
    finishPeer p
    syncNewPeer

chainMessage ChainPing = do
    to <- asks (chainConfTimeout . myConfig)
    now <- liftIO getCurrentTime
    chainSyncingPeer >>= \case
        Just ChainSync {chainSyncPeer = p, chainTimestamp = t}
            | now `diffUTCTime` t > to -> do
                $(logErrorS) "Chain" $
                    "Syncing peer timed out: " <> peerText p
                PeerTimeout `killPeer` p
            | otherwise -> return ()
        Nothing -> syncNewPeer

withSyncLoop :: (MonadUnliftIO m, MonadLoggerIO m)
             => Chain -> m a -> m a
withSyncLoop ch f =
    withAsync go $ \a ->
    link a >> f
  where
    go = forever $ do
        delay <- liftIO $
            randomRIO (  2 * 1000 * 1000
                      , 20 * 1000 * 1000 )
        threadDelay delay
        ChainPing `send` chainMailbox ch

-- | Version of the database.
dataVersion :: Word32
dataVersion = 1

-- | Initialize header database. If version is different from current, the
-- database is purged of conflicting elements first.
initChainDB :: MonadChain m => m ()
initChainDB = do
    db <- asks (chainConfDB . myConfig)
    net <- asks (chainConfNetwork . myConfig)
    ver <- retrieve db def ChainDataVersionKey
    when (ver /= Just dataVersion) $ purgeChainDB >>= writeBatch db
    insert db ChainDataVersionKey dataVersion
    retrieve db def BestBlockKey >>= \b ->
        when (isNothing (b :: Maybe BlockNode)) $
        withBlockHeaders $ do
            addBlockHeader (genesisNode net)
            setBestBlockHeader (genesisNode net)

-- | Purge database of elements having keys that may conflict with those used in
-- this module.
purgeChainDB :: MonadChain m => m [R.BatchOp]
purgeChainDB = do
    db <- asks (chainConfDB . myConfig)
    it <- R.createIter db def
    R.iterSeek it $ B.singleton 0x90
    recurse_delete it db
  where
    recurse_delete it db =
        R.iterKey it >>= \case
            Just k
                | B.head k == 0x90 || B.head k == 0x91 -> do
                    R.delete db k
                    R.iterNext it
                    (R.Del k :) <$> recurse_delete it db
            _ -> return []

-- | Import a bunch of continuous headers. Returns 'True' if the number of
-- headers is 2000, which means that there are possibly more headers to sync
-- from whatever peer delivered these.
importHeaders :: MonadChain m
              => Network
              -> UTCTime
              -> [BlockHeader]
              -> m (Either PeerException Bool)
importHeaders net now hs =
    runExceptT $
    lift connect >>= \case
        Right _ -> do
            case hs of
                [] -> return ()
                _ -> do
                    bb <- lift get_last
                    box <- asks chainState
                    atomically . modifyTVar box $ \s ->
                        s { chainSyncing =
                            (\x -> x {chainHighest = bb})
                            <$> chainSyncing s
                          }
            case length hs of
                2000 -> return False
                _    -> return True
        Left _ -> throwError PeerSentBadHeaders
  where
    timestamp = floor (utcTimeToPOSIXSeconds now)
    connect = withBlockHeaders $ connectBlocks net timestamp hs
    get_last = withBlockHeaders . getBlockHeader . headerHash $ last hs

-- | Check if best block header is in sync with the rest of the block chain by
-- comparing the best block with the current time, verifying that there are no
-- peers in the queue to be synced, and no peer is being synced at the moment.
-- This function will only return 'True' once. It should be used to decide
-- whether to notify other processes that the header chain has been synced. The
-- state of the chain will be flipped to synced when this function returns
-- 'True'.
notifySynced :: MonadChain m => m Bool
notifySynced =
    fmap isJust $
    runMaybeT $ do
        bb <- lift $ withBlockHeaders getBestBlockHeader
        now <- liftIO getCurrentTime
        guard $ now `diffUTCTime` block_time bb > 7200
        st <- asks chainState
        MaybeT . atomically . runMaybeT $ do
            s <- lift $ readTVar st
            guard . isNothing $ chainSyncing s
            guard . null $ newPeers s
            guard . not $ mySynced s
            lift $ writeTVar st s {mySynced = True}
            return ()
  where
    block_time =
        posixSecondsToUTCTime . fromIntegral . blockTimestamp . nodeHeader

-- | Get next peer to sync against from the queue.
nextPeer :: MonadChain m => m (Maybe Peer)
nextPeer = do
    ps <- newPeers <$> (readTVarIO =<< asks chainState)
    go ps
  where
    go [] = return Nothing
    go (p:ps) =
        setSyncingPeer p >>= \case
            True -> return (Just p)
            False -> go ps

-- | Set a syncing peer and generate a 'GetHeaders' data structure with a block
-- locator to send to that peer for syncing.
syncHeaders ::
       MonadChain m
    => UTCTime
    -> BlockNode
    -> Peer
    -> m GetHeaders
syncHeaders now bb p = do
    st <- asks chainState
    atomically $
        modifyTVar st $ \s ->
            s { chainSyncing =
                    Just
                        ChainSync
                            { chainSyncPeer = p
                            , chainTimestamp = now
                            , chainHighest = Nothing
                            }
              , newPeers = delete p (newPeers s)
              }
    loc <- withBlockHeaders $ blockLocator bb
    return
        GetHeaders
            { getHeadersVersion = myVersion
            , getHeadersBL = loc
            , getHeadersHashStop = z
            }
  where
    z = "0000000000000000000000000000000000000000000000000000000000000000"

-- | Set the time of last received data to now if a syncing peer is active.
setLastReceived :: MonadChain m => m ()
setLastReceived = do
    now <- liftIO getCurrentTime
    st <- asks chainState
    let f p = p { chainTimestamp = now }
    atomically . modifyTVar st $ \s ->
        s { chainSyncing = f <$> chainSyncing s }

-- | Add a new peer to the queue of peers to sync against.
addPeer :: MonadChain m => Peer -> m ()
addPeer p = do
    st <- asks chainState
    atomically . modifyTVar st $ \s -> s {newPeers = nub (p : newPeers s)}

-- | Get syncing peer if there is one.
getSyncingPeer :: MonadChain m => m (Maybe Peer)
getSyncingPeer =
    fmap chainSyncPeer . chainSyncing <$> (readTVarIO =<< asks chainState)

setSyncingPeer :: MonadChain m => Peer -> m Bool
setSyncingPeer p =
    setBusy p >>= \case
        False -> do
            $(logDebugS) "Chain" $
                "Could not lock peer: " <> peerText p
            return False
        True  -> do
            $(logDebugS) "Chain" $
                "Locked peer: " <> peerText p
            set_it
            return True
  where
    set_it = do
        now <- liftIO getCurrentTime
        box <- asks chainState
        atomically $ modifyTVar box $ \s ->
            s { chainSyncing =
                      Just ChainSync { chainSyncPeer = p
                                     , chainTimestamp = now
                                     , chainHighest = Nothing
                                     }
              }


-- | Remove a peer from the queue of peers to sync and unset the syncing peer if
-- it is set to the provided peer.
finishPeer :: MonadChain m => Peer -> m ()
finishPeer p =
    asks chainState >>= remove_peer >>= \case
        False ->
            $(logDebugS) "Chain" $
                "Removed peer from queue: " <> peerText p
        True -> do
            $(logDebugS) "Chain" $
                "Releasing syncing peer: " <> peerText p
            setFree p
  where
    remove_peer st = atomically $
        readTVar st >>= \s -> case chainSyncing s of
            Just ChainSync { chainSyncPeer = p' }
                | p == p' -> do
                      unset_syncing st
                      return True
            _ -> do
                remove_from_queue st
                return False
    unset_syncing st =
        modifyTVar st $ \x ->
            x { chainSyncing = Nothing }
    remove_from_queue st =
        modifyTVar st $ \x ->
            x { newPeers = delete p (newPeers x) }

-- | Return syncing peer data.
chainSyncingPeer :: MonadChain m => m (Maybe ChainSync)
chainSyncingPeer =
    chainSyncing <$> (readTVarIO =<< asks chainState)

-- | Get a block header from 'Chain' process.
chainGetBlock :: MonadIO m
              => BlockHash -> Chain -> m (Maybe BlockNode)
chainGetBlock bh ch =
    runReaderT (getBlockHeader bh) (chainConfDB (myConfig (chainReader ch)))

-- | Get best block header from chain process.
chainGetBest :: MonadIO m => Chain -> m BlockNode
chainGetBest ch =
    runReaderT getBestBlockHeader (chainConfDB (myConfig (chainReader ch)))

-- | Get ancestor of 'BlockNode' at 'BlockHeight' from chain process.
chainGetAncestor :: MonadIO m
                 => BlockHeight
                 -> BlockNode
                 -> Chain
                 -> m (Maybe BlockNode)
chainGetAncestor h bn ch =
    runReaderT (getAncestor h bn) (chainConfDB (myConfig (chainReader ch)))

-- | Get parents of 'BlockNode' starting at 'BlockHeight' from chain process.
chainGetParents :: MonadIO m
                => BlockHeight
                -> BlockNode
                -> Chain
                -> m [BlockNode]
chainGetParents height top ch =
    go [] top
  where
    go acc b
        | height >= nodeHeight b = return acc
        | otherwise = do
            m <- chainGetBlock (prevBlock $ nodeHeader b) ch
            case m of
                Nothing -> return acc
                Just p  -> go (p : acc) p

-- | Get last common block from chain process.
chainGetSplitBlock :: MonadIO m
                   => BlockNode
                   -> BlockNode
                   -> Chain
                   -> m BlockNode
chainGetSplitBlock l r ch =
    runReaderT (splitPoint l r) (chainConfDB (myConfig (chainReader ch)))

-- | Notify chain that a new peer is connected.
chainPeerConnected :: MonadIO m
                   => Peer
                   -> Chain
                   -> m ()
chainPeerConnected p ch =
    ChainPeerConnected p `send` chainMailbox ch

-- | Notify chain that a peer has disconnected.
chainPeerDisconnected :: MonadIO m
                      => Peer
                      -> Chain
                      -> m ()
chainPeerDisconnected p ch =
    ChainPeerDisconnected p `send` chainMailbox ch

-- | Is given 'BlockHash' in the main chain?
chainBlockMain :: MonadIO m
               => BlockHash
               -> Chain
               -> m Bool
chainBlockMain bh ch =
    chainGetBest ch >>= \bb ->
    chainGetBlock bh ch >>= \case
        Nothing ->
            return False
        bm@(Just bn) ->
            (== bm) <$> chainGetAncestor (nodeHeight bn) bb ch

-- | Is chain in sync with network?
chainIsSynced :: MonadIO m => Chain -> m Bool
chainIsSynced ch =
    mySynced <$> readTVarIO (chainState (chainReader ch))

-- | Peer sends a bunch of headers to the chain process.
chainHeaders :: MonadIO m
             => Peer -> [BlockHeader] -> Chain -> m ()
chainHeaders p hs ch =
    ChainHeaders p hs `send` chainMailbox ch
