{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Haskoin.Node.Chain
  ( ChainConfig (..),
    ChainEvent (..),
    Chain,
    withChain,
    chainGetBlock,
    chainGetBest,
    chainGetAncestor,
    chainGetParents,
    chainGetSplitBlock,
    chainPeerConnected,
    chainPeerDisconnected,
    chainIsSynced,
    chainBlockMain,
    chainHeaders,
  )
where

import Control.Monad (forM_, forever, guard, when)
import Control.Monad.Except (runExceptT, throwError)
import Control.Monad.Logger
  ( MonadLoggerIO,
    logDebugS,
    logErrorS,
    logInfoS,
  )
import Control.Monad.Reader
  ( MonadReader,
    ReaderT (..),
    asks,
    runReaderT,
  )
import Control.Monad.Trans (lift)
import Control.Monad.Trans.Maybe (MaybeT (..), runMaybeT)
import qualified Data.ByteString as B
import Data.Function (on)
import Data.List (delete, nub)
import Data.Maybe (isJust, isNothing)
import Data.Serialize
  ( Serialize,
    get,
    getWord8,
    put,
    putWord8,
  )
import Data.String.Conversions (cs)
import Data.Time.Clock
  ( NominalDiffTime,
    UTCTime,
    diffUTCTime,
    getCurrentTime,
  )
import Data.Time.Clock.POSIX
  ( posixSecondsToUTCTime,
    utcTimeToPOSIXSeconds,
  )
import Data.Word (Word32)
import Database.RocksDB (ColumnFamily, DB)
import qualified Database.RocksDB as R
import Database.RocksDB.Query
  ( Key,
    KeyValue,
    insert,
    insertCF,
    insertOp,
    insertOpCF,
    retrieveCommon,
    writeBatch,
  )
import Haskoin
  ( BlockHash,
    BlockHeader (..),
    BlockHeaders (..),
    BlockHeight,
    BlockNode (..),
    GetHeaders (..),
    Message (..),
    Network,
    blockLocator,
    connectBlocks,
    genesisNode,
    getAncestor,
    headerHash,
    splitPoint,
  )
import Haskoin.Node.Peer
import Haskoin.Node.PeerMgr (myVersion)
import NQE
  ( Mailbox,
    Publisher,
    newMailbox,
    publish,
    receive,
    send,
  )
import System.Random (randomRIO)
import UnliftIO
  ( MonadIO,
    MonadUnliftIO,
    TVar,
    atomically,
    liftIO,
    link,
    modifyTVar,
    newTVarIO,
    readTVar,
    readTVarIO,
    withAsync,
    writeTVar,
  )
import UnliftIO.Concurrent (threadDelay)

-- | Mailbox for chain header syncing process.
data Chain = Chain
  { mailbox :: !(Mailbox ChainMessage),
    reader :: !ChainReader
  }

instance Eq Chain where
  (==) = (==) `on` (.mailbox)

-- | Configuration for chain syncing process.
data ChainConfig = ChainConfig
  { -- | database handle
    db :: !DB,
    -- | column family
    cf :: !(Maybe ColumnFamily),
    -- | network constants
    net :: !Network,
    -- | send header chain events here
    pub :: !(Publisher ChainEvent),
    -- | timeout in seconds
    timeout :: !NominalDiffTime
  }

data ChainMessage
  = ChainHeaders !Peer ![BlockHeader]
  | ChainPeerConnected !Peer
  | ChainPeerDisconnected !Peer
  | ChainPing

-- | Events originating from chain syncing process.
data ChainEvent
  = -- | chain has new best block
    ChainBestBlock !BlockNode
  | -- | chain is in sync with the network
    ChainSynced !BlockNode
  deriving (Eq, Show)

type MonadChain m =
  ( MonadLoggerIO m,
    MonadUnliftIO m,
    MonadReader ChainReader m
  )

-- | State and configuration.
data ChainReader = ChainReader
  { -- | placeholder for upstream data
    config :: !ChainConfig,
    -- | mutable state for header synchronization
    state :: !(TVar ChainState)
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
  { peer :: !Peer,
    timestamp :: !UTCTime,
    best :: !(Maybe BlockNode)
  }

-- | Mutable state for the header chain process.
data ChainState = ChainState
  { -- | peer to sync against and time of last received message
    syncing :: !(Maybe ChainSync),
    -- | queue of peers to sync against
    peers :: ![Peer],
    -- | has the header chain ever been considered synced?
    beenInSync :: !Bool
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

instance (MonadIO m) => BlockHeaders (ReaderT ChainConfig m) where
  addBlockHeader bn = do
    db <- asks (.db)
    asks (.cf) >>= \case
      Nothing -> insert db (BlockHeaderKey h) bn
      Just cf -> insertCF db cf (BlockHeaderKey h) bn
    where
      h = headerHash bn.header
  getBlockHeader bh = do
    db <- asks (.db)
    mcf <- asks (.cf)
    retrieveCommon db mcf (BlockHeaderKey bh)
  getBestBlockHeader = do
    db <- asks (.db)
    mcf <- asks (.cf)
    retrieveCommon db mcf BestBlockKey >>= \case
      Nothing -> error "Could not get best block from database"
      Just b -> return b
  setBestBlockHeader bn = do
    db <- asks (.db)
    asks (.cf) >>= \case
      Nothing -> insert db BestBlockKey bn
      Just cf -> insertCF db cf BestBlockKey bn
  addBlockHeaders bns = do
    db <- asks (.db)
    mcf <- asks (.cf)
    writeBatch db (map (f mcf) bns)
    where
      h bn = headerHash bn.header
      f Nothing bn = insertOp (BlockHeaderKey (h bn)) bn
      f (Just cf) bn = insertOpCF cf (BlockHeaderKey (h bn)) bn

instance (MonadIO m) => BlockHeaders (ReaderT Chain m) where
  getBlockHeader bh = ReaderT $ chainGetBlock bh
  getBestBlockHeader = ReaderT chainGetBest
  addBlockHeader _ = undefined
  setBestBlockHeader _ = undefined
  addBlockHeaders _ = undefined

withBlockHeaders :: (MonadChain m) => ReaderT ChainConfig m a -> m a
withBlockHeaders f = do
  cfg <- asks (.config)
  runReaderT f cfg

withChain ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  ChainConfig ->
  (Chain -> m a) ->
  m a
withChain cfg action = do
  (inbox, mailbox) <- newMailbox
  $(logDebugS) "Chain" "Starting chain actor"
  st <-
    newTVarIO
      ChainState
        { syncing = Nothing,
          beenInSync = False,
          peers = []
        }
  let rd = ChainReader {config = cfg, state = st}
      ch = Chain {reader = rd, mailbox = mailbox}
  runReaderT initChainDB rd
  withAsync (main_loop ch rd inbox) $ \a ->
    link a >> action ch
  where
    main_loop ch rd inbox =
      withSyncLoop ch $
        runReaderT (run inbox) rd
    run inbox = do
      withBlockHeaders getBestBlockHeader
        >>= chainEvent . ChainBestBlock
      forever $ do
        $(logDebugS) "Chain" "Awaiting event..."
        msg <- receive inbox
        chainMessage msg

chainEvent :: (MonadChain m) => ChainEvent -> m ()
chainEvent e = do
  pub <- asks (.config.pub)
  case e of
    ChainBestBlock b ->
      $(logInfoS) "Chain" $
        "Best block header at height: "
          <> cs (show b.height)
    ChainSynced b ->
      $(logInfoS) "Chain" $
        "Headers in sync at height: "
          <> cs (show b.height)
  publish e pub

processHeaders :: (MonadChain m) => Peer -> [BlockHeader] -> m ()
processHeaders p hs = do
  $(logDebugS) "Chain" $
    "Processing "
      <> cs (show (length hs))
      <> " headers from peer: "
      <> p.label
  net <- asks (.config.net)
  now <- liftIO getCurrentTime
  pbest <- withBlockHeaders getBestBlockHeader
  importHeaders net now hs >>= \case
    Left e -> do
      $(logErrorS) "Chain" $
        "Could not connect headers from peer: "
          <> p.label
      e `killPeer` p
    Right done -> do
      setLastReceived
      best <- withBlockHeaders getBestBlockHeader
      when (pbest.header /= best.header) $
        chainEvent (ChainBestBlock best)
      if done
        then do
          MSendHeaders `sendMessage` p
          finishPeer p
          syncNewPeer
          syncNotif
        else syncPeer p

syncNewPeer :: (MonadChain m) => m ()
syncNewPeer =
  getSyncingPeer >>= \case
    Just _ -> return ()
    Nothing ->
      nextPeer >>= \case
        Nothing -> return ()
        Just p -> do
          $(logDebugS) "Chain" $
            "Syncing against peer: " <> p.label
          syncPeer p

syncNotif :: (MonadChain m) => m ()
syncNotif =
  notifySynced >>= \case
    False -> return ()
    True ->
      withBlockHeaders getBestBlockHeader
        >>= chainEvent . ChainSynced

syncPeer :: (MonadChain m) => Peer -> m ()
syncPeer p = do
  t <- liftIO getCurrentTime
  m <-
    chainSyncingPeer >>= \case
      Just
        ChainSync
          { peer = s,
            best = m
          }
          | p == s -> syncing_me t m
          | otherwise -> return Nothing
      Nothing -> syncing_new t
  forM_ m $ \g -> do
    $(logDebugS) "Chain" $
      "Requesting headers from peer: "
        <> p.label
    MGetHeaders g `sendMessage` p
  where
    syncing_new t =
      setSyncingPeer p >>= \case
        False -> return Nothing
        True -> do
          $(logDebugS) "Chain" $
            "Locked peer: " <> p.label
          h <- withBlockHeaders getBestBlockHeader
          Just <$> syncHeaders t h p
    syncing_me t m = do
      h <- case m of
        Nothing -> withBlockHeaders getBestBlockHeader
        Just h -> return h
      Just <$> syncHeaders t h p

chainMessage :: (MonadChain m) => ChainMessage -> m ()
chainMessage (ChainHeaders p hs) =
  processHeaders p hs
chainMessage (ChainPeerConnected p) = do
  $(logDebugS) "Chain" $ "Peer connected: " <> p.label
  addPeer p
  syncNewPeer
chainMessage (ChainPeerDisconnected p) = do
  $(logDebugS) "Chain" $ "Peer disconnected: " <> p.label
  finishPeer p
  syncNewPeer
chainMessage ChainPing = do
  $(logDebugS) "Chain" "Internal clock event"
  to <- asks (.config.timeout)
  now <- liftIO getCurrentTime
  chainSyncingPeer >>= \case
    Just ChainSync {peer = p, timestamp = t}
      | now `diffUTCTime` t > to -> do
          $(logErrorS) "Chain" $
            "Syncing peer timed out: " <> p.label
          PeerTimeout `killPeer` p
      | otherwise -> return ()
    Nothing -> syncNewPeer

withSyncLoop ::
  (MonadUnliftIO m, MonadLoggerIO m) =>
  Chain ->
  m a ->
  m a
withSyncLoop ch f =
  withAsync go $ \a ->
    link a >> f
  where
    go = forever $ do
      delay <-
        liftIO $
          randomRIO
            ( 2 * 1000 * 1000,
              20 * 1000 * 1000
            )
      threadDelay delay
      ChainPing `send` ch.mailbox

-- | Version of the database.
dataVersion :: Word32
dataVersion = 1

-- | Initialize header database. If version is different from current, the
-- database is purged of conflicting elements first.
initChainDB :: (MonadChain m) => m ()
initChainDB = do
  db <- asks (.config.db)
  mcf <- asks (.config.cf)
  net <- asks (.config.net)
  ver <- retrieveCommon db mcf ChainDataVersionKey
  when (ver /= Just dataVersion) $ purgeChainDB >>= writeBatch db
  case mcf of
    Nothing -> insert db ChainDataVersionKey dataVersion
    Just cf -> insertCF db cf ChainDataVersionKey dataVersion
  retrieveCommon db mcf BestBlockKey >>= \b ->
    when (isNothing (b :: Maybe BlockNode)) $
      withBlockHeaders $ do
        addBlockHeader (genesisNode net)
        setBestBlockHeader (genesisNode net)

-- | Purge database of elements having keys that may conflict with those used in
-- this module.
purgeChainDB :: (MonadChain m) => m [R.BatchOp]
purgeChainDB = do
  db <- asks (.config.db)
  mcf <- asks (.config.cf)
  f db mcf $ \it -> do
    R.iterSeek it $ B.singleton 0x90
    recurse_delete it db mcf
  where
    f db Nothing = R.withIter db
    f db (Just cf) = R.withIterCF db cf
    recurse_delete it db mcf =
      R.iterKey it >>= \case
        Just k
          | B.head k == 0x90 || B.head k == 0x91 -> do
              case mcf of
                Nothing -> R.delete db k
                Just cf -> R.deleteCF db cf k
              R.iterNext it
              (R.Del k :) <$> recurse_delete it db mcf
        _ -> return []

-- | Import a bunch of continuous headers. Returns 'True' if the number of
-- headers is 2000, which means that there are possibly more headers to sync
-- from whatever peer delivered these.
importHeaders ::
  (MonadChain m) =>
  Network ->
  UTCTime ->
  [BlockHeader] ->
  m (Either PeerException Bool)
importHeaders net now hs =
  runExceptT $
    lift connect >>= \case
      Right _ -> do
        case hs of
          [] -> return ()
          _ -> do
            bb <- lift get_last
            box <- asks (.state)
            atomically . modifyTVar box $ \s ->
              s {syncing = (\x -> x {best = bb}) <$> s.syncing}
        case length hs of
          2000 -> return False
          _ -> return True
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
notifySynced :: (MonadChain m) => m Bool
notifySynced =
  fmap isJust $
    runMaybeT $ do
      bb <- lift $ withBlockHeaders getBestBlockHeader
      now <- liftIO getCurrentTime
      guard $ now `diffUTCTime` block_time bb > 7200
      st <- asks (.state)
      MaybeT . atomically . runMaybeT $ do
        s <- lift $ readTVar st
        guard $ isNothing s.syncing
        guard $ null s.peers
        guard $ not s.beenInSync
        lift $ writeTVar st s {beenInSync = True}
        return ()
  where
    block_time =
      posixSecondsToUTCTime . fromIntegral . (.header.timestamp)

-- | Get next peer to sync against from the queue.
nextPeer :: (MonadChain m) => m (Maybe Peer)
nextPeer = do
  ps <- (.peers) <$> (readTVarIO =<< asks (.state))
  go ps
  where
    go [] = return Nothing
    go (p : ps) =
      setSyncingPeer p >>= \case
        True -> return (Just p)
        False -> go ps

-- | Set a syncing peer and generate a 'GetHeaders' data structure with a block
-- locator to send to that peer for syncing.
syncHeaders ::
  (MonadChain m) =>
  UTCTime ->
  BlockNode ->
  Peer ->
  m GetHeaders
syncHeaders now bb p = do
  st <- asks (.state)
  atomically $
    modifyTVar st $ \s ->
      s
        { syncing =
            Just
              ChainSync
                { peer = p,
                  timestamp = now,
                  best = Nothing
                },
          peers = delete p s.peers
        }
  loc <- withBlockHeaders $ blockLocator bb
  return
    GetHeaders
      { version = myVersion,
        locator = loc,
        stop = z
      }
  where
    z = "0000000000000000000000000000000000000000000000000000000000000000"

-- | Set the time of last received data to now if a syncing peer is active.
setLastReceived :: (MonadChain m) => m ()
setLastReceived = do
  now <- liftIO getCurrentTime
  st <- asks (.state)
  let f ChainSync {..} = ChainSync {timestamp = now, ..}
  atomically . modifyTVar st $ \s ->
    s {syncing = f <$> s.syncing}

-- | Add a new peer to the queue of peers to sync against.
addPeer :: (MonadChain m) => Peer -> m ()
addPeer p = do
  st <- asks (.state)
  atomically . modifyTVar st $ \s -> s {peers = nub (p : s.peers)}

-- | Get syncing peer if there is one.
getSyncingPeer :: (MonadChain m) => m (Maybe Peer)
getSyncingPeer =
  fmap (.peer) . (.syncing)
    <$> (readTVarIO =<< asks (.state))

setSyncingPeer :: (MonadChain m) => Peer -> m Bool
setSyncingPeer p =
  setBusy p >>= \case
    False -> do
      $(logDebugS) "Chain" $
        "Could not lock peer: " <> p.label
      return False
    True -> do
      $(logDebugS) "Chain" $
        "Locked peer: " <> p.label
      set_it
      return True
  where
    set_it = do
      now <- liftIO getCurrentTime
      box <- asks (.state)
      atomically $ modifyTVar box $ \s ->
        s
          { syncing =
              Just
                ChainSync
                  { peer = p,
                    timestamp = now,
                    best = Nothing
                  }
          }

-- | Remove a peer from the queue of peers to sync and unset the syncing peer if
-- it is set to the provided peer.
finishPeer :: (MonadChain m) => Peer -> m ()
finishPeer p =
  asks (.state) >>= remove_peer >>= \case
    False ->
      $(logDebugS) "Chain" $
        "Removed peer from queue: " <> p.label
    True -> do
      $(logDebugS) "Chain" $
        "Releasing syncing peer: " <> p.label
      setFree p
  where
    remove_peer st =
      atomically $
        readTVar st >>= \s -> case s.syncing of
          Just ChainSync {peer = p'}
            | p == p' -> do
                unset_syncing st
                return True
          _ -> do
            remove_from_queue st
            return False
    unset_syncing st =
      modifyTVar st $ \x ->
        x {syncing = Nothing}
    remove_from_queue st =
      modifyTVar st $ \x ->
        x {peers = delete p x.peers}

-- | Return syncing peer data.
chainSyncingPeer :: (MonadChain m) => m (Maybe ChainSync)
chainSyncingPeer =
  (.syncing) <$> (readTVarIO =<< asks (.state))

-- | Get a block header from 'Chain' process.
chainGetBlock ::
  (MonadIO m) =>
  BlockHash ->
  Chain ->
  m (Maybe BlockNode)
chainGetBlock bh ch =
  runReaderT (getBlockHeader bh) (ch.reader.config)

-- | Get best block header from chain process.
chainGetBest :: (MonadIO m) => Chain -> m BlockNode
chainGetBest ch =
  runReaderT getBestBlockHeader ch.reader.config

-- | Get ancestor of 'BlockNode' at 'BlockHeight' from chain process.
chainGetAncestor ::
  (MonadIO m) =>
  BlockHeight ->
  BlockNode ->
  Chain ->
  m (Maybe BlockNode)
chainGetAncestor h bn ch =
  runReaderT (getAncestor h bn) ch.reader.config

-- | Get parents of 'BlockNode' starting at 'BlockHeight' from chain process.
chainGetParents ::
  (MonadIO m) =>
  BlockHeight ->
  BlockNode ->
  Chain ->
  m [BlockNode]
chainGetParents height top ch =
  go [] top
  where
    go acc b
      | height >= b.height = return acc
      | otherwise = do
          m <- chainGetBlock b.header.prev ch
          case m of
            Nothing -> return acc
            Just p -> go (p : acc) p

-- | Get last common block from chain process.
chainGetSplitBlock ::
  (MonadIO m) =>
  BlockNode ->
  BlockNode ->
  Chain ->
  m BlockNode
chainGetSplitBlock l r ch =
  runReaderT (splitPoint l r) ch.reader.config

-- | Notify chain that a new peer is connected.
chainPeerConnected ::
  (MonadIO m) =>
  Peer ->
  Chain ->
  m ()
chainPeerConnected p ch =
  ChainPeerConnected p `send` ch.mailbox

-- | Notify chain that a peer has disconnected.
chainPeerDisconnected ::
  (MonadIO m) =>
  Peer ->
  Chain ->
  m ()
chainPeerDisconnected p ch =
  ChainPeerDisconnected p `send` ch.mailbox

-- | Is given 'BlockHash' in the main chain?
chainBlockMain ::
  (MonadIO m) =>
  BlockHash ->
  Chain ->
  m Bool
chainBlockMain bh ch =
  chainGetBest ch >>= \bb ->
    chainGetBlock bh ch >>= \case
      Nothing ->
        return False
      bm@(Just bn) ->
        (== bm) <$> chainGetAncestor bn.height bb ch

-- | Is chain in sync with network?
chainIsSynced :: (MonadIO m) => Chain -> m Bool
chainIsSynced ch =
  (.beenInSync) <$> readTVarIO (ch.reader.state)

-- | Peer sends a bunch of headers to the chain process.
chainHeaders ::
  (MonadIO m) =>
  Peer ->
  [BlockHeader] ->
  Chain ->
  m ()
chainHeaders p hs ch =
  ChainHeaders p hs `send` ch.mailbox
