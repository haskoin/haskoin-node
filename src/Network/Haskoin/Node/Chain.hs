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
{-|
Module      : Network.Haskoin.Node.Chain
Copyright   : No rights reserved
License     : UNLICENSE
Maintainer  : xenog@protonmail.com
Stability   : experimental
Portability : POSIX

Block chain headers synchronizing process.
-}
module Network.Haskoin.Node.Chain
    ( chain
    ) where

import           Control.Monad.Except
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.Trans.Maybe
import qualified Data.ByteString                  as B
import           Data.Default
import           Data.List
import           Data.Maybe
import           Data.Serialize                   as S
import           Data.String.Conversions
import           Data.Time.Clock.POSIX
import           Data.Word
import           Database.RocksDB                 (DB)
import qualified Database.RocksDB                 as R
import           Database.RocksDB.Query           as R
import           Haskoin
import           Network.Haskoin.Node.Common
import           NQE
import           System.Random
import           UnliftIO
import           UnliftIO.Concurrent
import           UnliftIO.Resource

type MonadChain m
     = (MonadLoggerIO m, MonadChainLogic ChainConfig Peer m)

-- | Launch process to synchronize block headers in current thread.
chain ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => ChainConfig
    -> Inbox ChainMessage
    -> m ()
chain cfg inbox = do
    st <-
        newTVarIO
            ChainState
                { chainSyncing = Nothing
                , mySynced = False
                , newPeers = []
                }
    let rd = ChainReader {myReader = cfg, myChainDB = db, chainState = st}
    withSyncLoop ch $ run `runReaderT` rd
  where
    net = chainConfNetwork cfg
    db = chainConfDB cfg
    ch = inboxToMailbox inbox
    run = do
        $(logDebugS) "Chain" "Initializing..."
        initChainDB net
        getBestBlockHeader >>= chainEvent . ChainBestBlock
        $(logInfoS) "Chain" "Initialization complete"
        forever $ do
          $(logDebugS) "Chain" "Awaiting message..."
          receive inbox >>= chainMessage

chainEvent :: MonadChain m => ChainEvent -> m ()
chainEvent e = do
    l <- chainConfEvents <$> asks myReader
    case e of
        ChainBestBlock b ->
            $(logInfoS) "Chain" $
            "Best block header at height " <> cs (show (nodeHeight b))
        ChainSynced b ->
            $(logInfoS) "Chain" $
            "Headers now synced at height " <> cs (show (nodeHeight b))
    atomically $ l e

processHeaders ::
       MonadChain m => Peer -> [BlockHeader] -> m ()
processHeaders p hs =
    void . runMaybeT $ do
        net <- chainConfNetwork <$> asks myReader
        $(logDebugS) "Chain" $
            "Importing " <> cs (show (length hs)) <> " headers"
        now <- round <$> liftIO getPOSIXTime
        pbest <- getBestBlockHeader
        importHeaders net now hs >>= \case
            Left e -> do
                $(logErrorS) "Chain" "Could not connect received headers"
                e `killPeer` p
            Right done -> do
                setLastReceived now
                best <- getBestBlockHeader
                when (nodeHeader pbest /= nodeHeader best) . chainEvent $
                    ChainBestBlock best
                if done
                    then do
                        $(logDebugS)
                            "Chain"
                            "Finished importing headers from syncing peer"
                        MSendHeaders `sendMessage` p
                        finishPeer p
                        syncNewPeer
                        syncNotif
                    else do
                        $(logDebugS)
                            "Chain"
                            "Continuing importing headers from syncing peer"
                        syncPeer p

syncNewPeer :: MonadChain m => m ()
syncNewPeer =
    getSyncingPeer >>= \case
        Nothing -> do
            $(logDebugS) "Chain" "Getting next peer to sync from"
            nextPeer >>= \case
                Nothing ->
                    $(logInfoS) "Chain" "Finished syncing against all peers"
                Just p -> syncPeer p
        Just _ -> $(logDebugS) "Chain" "Already syncing against a peer"

syncNotif :: MonadChain m => m ()
syncNotif =
    round <$> liftIO getPOSIXTime >>= notifySynced >>= \x ->
        when x $ getBestBlockHeader >>= chainEvent . ChainSynced

syncPeer :: MonadChain m => Peer -> m ()
syncPeer p = do
    $(logInfoS) "Chain" "Syncing hedears against selected peer"
    bb <-
        chainSyncingPeer >>= \case
            Just ChainSync {chainSyncPeer = p', chainHighest = Just g}
                | p == p' -> return g
            _ -> getBestBlockHeader
    now <- round <$> liftIO getPOSIXTime
    gh <- syncHeaders now bb p
    $(logDebugS) "Chain" $
        "Requesting headers from syncing peer for chain head at height: " <>
        cs (show (nodeHeight bb))
    MGetHeaders gh `sendMessage` p

chainMessage :: MonadChain m => ChainMessage -> m ()
chainMessage (ChainGetBest reply) = do
    $(logDebugS) "Chain" "Responding to request for best block header"
    getBestBlockHeader >>= \bh -> do
        $(logDebugS) "Chain" $
            "Best block header: " <> blockHashToHex (headerHash (nodeHeader bh)) <>
            " at height " <>
            cs (show (nodeHeight bh))
        atomically $ reply bh
chainMessage (ChainHeaders p hs) = do
    $(logDebugS) "Chain" $ "Processing " <> cs (show (length hs)) <> " headers"
    processHeaders p hs
chainMessage (ChainPeerConnected p a) = do
    $(logDebugS) "Chain" $ "Adding new peer to sync queue: " <> cs (show a)
    addPeer p
    syncNewPeer
chainMessage (ChainPeerDisconnected p a) = do
    $(logWarnS) "Chain" $ "Removing a peer from sync queue: " <> cs (show a)
    finishPeer p
    syncNewPeer
chainMessage (ChainGetAncestor h n reply) = do
    $(logDebugS) "Chain" $
        "Responding to request for ancestor at height " <> cs (show h) <>
        " to block: " <>
        blockHashToHex (headerHash (nodeHeader n))
    a <- getAncestor h n
    atomically $ reply a
    case a of
        Just b ->
            $(logDebugS) "Chain" $
            "Ancestor is: " <> blockHashToHex (headerHash (nodeHeader b))
        Nothing -> $(logDebugS) "Chain" "Ancestor not found"
chainMessage (ChainGetSplit l r reply) = do
    $(logDebugS) "Chain" $
        "Responding to request for split point between blocks " <>
        blockHashToHex (headerHash (nodeHeader l)) <>
        " & " <>
        blockHashToHex (headerHash (nodeHeader r))
    s <- splitPoint l r
    atomically $ reply s
    $(logDebugS) "Chain" $
        "Split block is: " <> blockHashToHex (headerHash (nodeHeader s))
chainMessage (ChainGetBlock h reply) = do
    $(logDebugS) "Chain" $
        "Responding to request for block: " <> blockHashToHex h
    m <- getBlockHeader h
    atomically $ reply m
    case m of
        Nothing ->
            $(logDebugS) "Chain" $ "Block not found: " <> blockHashToHex h
        Just b ->
            $(logDebugS) "Chain" $
            "Block found at height " <> cs (show (nodeHeight b))
chainMessage (ChainIsSynced reply) = do
    s <- isSynced
    if s
        then $(logDebugS) "Chain" "Chain is in sync"
        else $(logDebugS) "Chain" "Chain is NOT in sync"
    atomically $ reply s
chainMessage ChainPing = do
    $(logDebugS) "Chain" "Housekeeping..."
    ChainConfig {chainConfTimeout = to} <- asks myReader
    now <- round <$> liftIO getPOSIXTime
    chainSyncingPeer >>= \case
        Nothing -> return ()
        Just ChainSync {chainSyncPeer = p, chainTimestamp = t}
            | now - t > fromIntegral to -> do
                $(logErrorS) "Chain" "Syncing peer timed out"
                PeerTimeout `killPeer` p
            | otherwise -> return ()

withSyncLoop :: (MonadUnliftIO m, MonadLoggerIO m) => Chain -> m a -> m a
withSyncLoop ch f = withAsync go $ \a -> link a >> f
  where
    go =
        forever $ do
            threadDelay =<<
                liftIO (randomRIO (2 * 1000 * 1000, 20 * 1000 * 1000))
            $(logDebugS)
                "ChainSyncLoop"
                "Ping chain for housekeeping"
            ChainPing `send` ch

-- | Version of the database.
dataVersion :: Word32
dataVersion = 1

-- | Database key for version.
data ChainDataVersionKey = ChainDataVersionKey
    deriving (Eq, Ord, Show)

instance R.Key ChainDataVersionKey
instance KeyValue ChainDataVersionKey Word32

instance Serialize ChainDataVersionKey where
    get = do
        guard . (== 0x92) =<< S.getWord8
        return ChainDataVersionKey
    put ChainDataVersionKey = S.putWord8 0x92

data ChainSync p = ChainSync
    { chainSyncPeer  :: !p
    , chainTimestamp :: !Timestamp
    , chainHighest   :: !(Maybe BlockNode)
    }

-- | Mutable state for the header chain process.
data ChainState p = ChainState
    { chainSyncing :: !(Maybe (ChainSync p))
      -- ^ peer to sync against and time of last received message
    , newPeers     :: ![p]
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

-- | Type alias for monad commonly used in this module.
type MonadChainLogic a p m
     = (BlockHeaders m, MonadReader (ChainReader a p) m)

-- | Reader for header synchronization code.
data ChainReader a p = ChainReader
    { myReader   :: !a
      -- ^ placeholder for upstream data
    , myChainDB  :: !DB
      -- ^ database handle
    , chainState :: !(TVar (ChainState p))
      -- ^ mutable state for header synchronization
    }

instance (Monad m, MonadIO m, MonadReader (ChainReader a p) m) =>
         BlockHeaders m where
    addBlockHeader bn = do
        db <- asks myChainDB
        R.insert db (BlockHeaderKey (headerHash (nodeHeader bn))) bn
    getBlockHeader bh = do
        db <- asks myChainDB
        retrieve db def (BlockHeaderKey bh)
    getBestBlockHeader = do
        db <- asks myChainDB
        retrieve db def BestBlockKey >>= \case
            Nothing -> error "Could not get best block from database"
            Just b -> return b
    setBestBlockHeader bn = do
        db <- asks myChainDB
        R.insert db BestBlockKey bn
    addBlockHeaders bns = do
        db <- asks myChainDB
        writeBatch db (map f bns)
      where
        f bn = insertOp (BlockHeaderKey (headerHash (nodeHeader bn))) bn

-- | Initialize header database. If version is different from current, the
-- database is purged of conflicting elements first.
initChainDB :: (MonadChainLogic a p m, MonadUnliftIO m) => Network -> m ()
initChainDB net = do
    db <- asks myChainDB
    ver <- retrieve db def ChainDataVersionKey
    when (ver /= Just dataVersion) $ purgeChainDB >>= writeBatch db
    R.insert db ChainDataVersionKey dataVersion
    retrieve db def BestBlockKey >>= \b ->
        when (isNothing (b :: Maybe BlockNode)) $ do
            addBlockHeader (genesisNode net)
            setBestBlockHeader (genesisNode net)

-- | Purge database of elements having keys that may conflict with those used in
-- this module.
purgeChainDB :: (MonadChainLogic a p m, MonadUnliftIO m) => m [R.BatchOp]
purgeChainDB = do
    db <- asks myChainDB
    runResourceT . R.withIterator db def $ \it -> do
        R.iterSeek it $ B.singleton 0x90
        recurse_delete it db
  where
    recurse_delete it db =
        R.iterKey it >>= \case
            Just k
                | B.head k == 0x90 || B.head k == 0x91 -> do
                    R.delete db def k
                    R.iterNext it
                    (R.Del k :) <$> recurse_delete it db
            _ -> return []

-- | Import a bunch of continuous headers. Returns 'True' if the number of
-- headers is 2000, which means that there are possibly more headers to sync
-- from whatever peer delivered these.
importHeaders ::
       (MonadIO m, BlockHeaders m, MonadChainLogic a p m)
    => Network
    -> Timestamp
    -> [BlockHeader]
    -> m (Either PeerException Bool)
importHeaders net now hs =
    runExceptT $
    lift (connectBlocks net now hs) >>= \case
        Right _ -> do
            case hs of
                [] -> return ()
                _ -> do
                    bb <- getBlockHeader (headerHash (last hs))
                    box <- asks chainState
                    atomically . modifyTVar box $ \s ->
                        s
                            { chainSyncing =
                                  (\x -> x {chainHighest = bb}) <$>
                                  chainSyncing s
                            }
            case length hs of
                2000 -> return False
                _    -> return True
        Left _ -> throwError PeerSentBadHeaders

-- | Check if best block header is in sync with the rest of the block chain by
-- comparing the best block with the current time, verifying that there are no
-- peers in the queue to be synced, and no peer is being synced at the moment.
-- This function will only return 'True' once. It should be used to decide
-- whether to notify other processes that the header chain has been synced. The
-- state of the chain will be flipped to synced when this function returns
-- 'True'.
notifySynced :: (MonadIO m, MonadChainLogic a p m) => Timestamp -> m Bool
notifySynced now =
    fmap isJust $
    runMaybeT $ do
        bb <- getBestBlockHeader
        guard (now - blockTimestamp (nodeHeader bb) < 2 * 60 * 60)
        st <- asks chainState
        MaybeT . atomically . runMaybeT $ do
            s <- lift $ readTVar st
            guard . isNothing $ chainSyncing s
            guard . null $ newPeers s
            guard . not $ mySynced s
            lift $ writeTVar st s {mySynced = True}
            return ()

-- | Get next peer to sync against from the queue.
nextPeer :: (MonadIO m, MonadChainLogic a p m) => m (Maybe p)
nextPeer = listToMaybe . newPeers <$> (asks chainState >>= readTVarIO)

-- | Set a syncing peer and generate a 'GetHeaders' data structure with a block
-- locator to send to that peer for syncing.
syncHeaders ::
       (Eq p, MonadChainLogic a p m, MonadIO m)
    => Timestamp
    -> BlockNode
    -> p
    -> m GetHeaders
syncHeaders now bb p = do
    st <- asks chainState
    atomically . modifyTVar st $ \s ->
        s
            { chainSyncing =
                  Just
                      ChainSync
                          { chainSyncPeer = p
                          , chainTimestamp = now
                          , chainHighest = Nothing
                          }
            , newPeers = delete p (newPeers s)
            }
    loc <- blockLocator bb
    return
        GetHeaders
            { getHeadersVersion = myVersion
            , getHeadersBL = loc
            , getHeadersHashStop =
                  "0000000000000000000000000000000000000000000000000000000000000000"
            }

-- | Set the time of last received data to now if a syncing peer is active.
setLastReceived :: (MonadChainLogic a p m, MonadIO m) => Timestamp -> m ()
setLastReceived now = do
    st <- asks chainState
    atomically . modifyTVar st $ \s ->
        s {chainSyncing = (\p -> p {chainTimestamp = now}) <$> chainSyncing s}

-- | Add a new peer to the queue of peers to sync against.
addPeer :: (Eq p, MonadIO m, MonadChainLogic a p m) => p -> m ()
addPeer p = do
    st <- asks chainState
    atomically . modifyTVar st $ \s -> s {newPeers = nub (p : newPeers s)}

-- | Get syncing peer if there is one.
getSyncingPeer :: (MonadChainLogic a p m, MonadIO m) => m (Maybe p)
getSyncingPeer = fmap chainSyncPeer . chainSyncing <$> (readTVarIO =<< asks chainState)

-- | Return 'True' if the chain has ever been considered synced. it will always
-- return 'True', even if the chain gets out of sync for any reason.
isSynced :: (MonadChainLogic a p m, MonadIO m) => m Bool
isSynced = mySynced <$> (asks chainState >>= readTVarIO)

-- | Remove a peer from the queue of peers to sync and unset the syncing peer if
-- it is set to the provided value.
finishPeer :: (Eq p, MonadIO m, MonadChainLogic a p m) => p -> m ()
finishPeer p =
    asks chainState >>= \st ->
        atomically . modifyTVar st $ \s ->
            s
                { newPeers = delete p (newPeers s)
                , chainSyncing =
                      case chainSyncing s of
                          Just ChainSync { chainSyncPeer = p'
                                         , chainTimestamp = _
                                         , chainHighest = _
                                         }
                              | p == p' -> Nothing
                          _ -> chainSyncing s
                }

-- | Return syncing peer data.
chainSyncingPeer :: (MonadChainLogic a p m, MonadIO m) => m (Maybe (ChainSync p))
chainSyncingPeer = chainSyncing <$> (readTVarIO =<< asks chainState)
