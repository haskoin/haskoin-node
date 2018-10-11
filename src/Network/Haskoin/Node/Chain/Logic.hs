{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE UndecidableInstances      #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-|
Module      : Network.Haskoin.Node.Chain.Logic
Copyright   : No rights reserved
License     : UNLICENSE
Maintainer  : xenog@protonmail.com
Stability   : experimental
Portability : POSIX

State and code for block header synchronization.
-}
module Network.Haskoin.Node.Chain.Logic where

import           Control.Arrow
import           Control.Monad
import           Control.Monad.Except
import           Control.Monad.Reader
import           Control.Monad.Trans.Maybe
import qualified Data.ByteString             as B
import           Data.Default
import           Data.List
import           Data.Maybe
import           Data.Serialize              as S
import           Data.Word
import           Database.RocksDB            (DB)
import qualified Database.RocksDB            as R
import           Database.RocksDB.Query      as R
import           Haskoin
import           Network.Haskoin.Node.Common
import           UnliftIO
import           UnliftIO.Resource

-- | Version of the database.
dataVersion :: Word32
dataVersion = 1

-- | Database key for version.
data ChainDataVersionKey = ChainDataVersionKey
    deriving (Eq, Ord, Show)

instance Key ChainDataVersionKey
instance KeyValue ChainDataVersionKey Word32

instance Serialize ChainDataVersionKey where
    get = do
        guard . (== 0x92) =<< S.getWord8
        return ChainDataVersionKey
    put ChainDataVersionKey = S.putWord8 0x92

-- | Mutable state for the header chain process.
data ChainState p = ChainState
    { syncingPeer :: !(Maybe (p, Timestamp))
      -- ^ peer to sync against and time of last received message
    , newPeers    :: ![p]
      -- ^ queue of peers to sync against
    , mySynced    :: !Bool
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
    when (ver /= Just dataVersion) purgeChainDB
    R.insert db ChainDataVersionKey dataVersion
    retrieve db def BestBlockKey >>= \b ->
        when (isNothing (b :: Maybe BlockNode)) $ do
            addBlockHeader (genesisNode net)
            setBestBlockHeader (genesisNode net)

-- | Purge database of elements having keys that may conflict with those used in
-- this module.
purgeChainDB :: (MonadChainLogic a p m, MonadUnliftIO m) => m ()
purgeChainDB = do
    db <- asks myChainDB
    runResourceT . R.withIterator db def $ \it -> do
        R.iterSeek it $ B.singleton 0x90
        recurse_delete it db
  where
    recurse_delete it db =
        R.iterKey it >>= \case
            Nothing -> return ()
            Just k
                | B.head k == 0x90 || B.head k == 0x91 -> do
                    R.delete db def k
                    R.iterNext it
                    recurse_delete it db
                | otherwise -> return ()

-- | Import a bunch of continuous headers. Returns 'True' if the number of
-- headers is 2000, which means that there are possibly more headers to sync
-- from whatever peer delivered these.
importHeaders ::
       (MonadIO m, BlockHeaders m)
    => Network
    -> Timestamp
    -> [BlockHeader]
    -> m (Either PeerException Bool)
importHeaders net now hs =
    runExceptT $
    lift (connectBlocks net now hs) >>= \case
        Right _ ->
            case length hs of
                2000 -> return False
                _ -> return True
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
            guard . isNothing $ syncingPeer s
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
        s {syncingPeer = Just (p, now), newPeers = delete p (newPeers s)}
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
        s {syncingPeer = second (const now) <$> syncingPeer s}

-- | Add a new peer to the queue of peers to sync against.
addPeer :: (Eq p, MonadIO m, MonadChainLogic a p m) => p -> m ()
addPeer p = do
    st <- asks chainState
    atomically . modifyTVar st $ \s -> s {newPeers = nub (p : newPeers s)}

-- | Get syncing peer if there is one.
getSyncingPeer :: (MonadChainLogic a p m, MonadIO m) => m (Maybe p)
getSyncingPeer = fmap fst . syncingPeer <$> (readTVarIO =<< asks chainState)

-- | Set syncing peer to the pone provided.
setSyncingPeer :: (MonadChainLogic a p m, MonadIO m) => Timestamp -> p -> m ()
setSyncingPeer now p =
    asks chainState >>= \v ->
        atomically . modifyTVar v $ \s -> s {syncingPeer = Just (p, now)}

-- | Return 'True' if the chain has ever been considered synced. it will always
-- return 'True', even if the chain gets out of sync for any reason.
isSynced :: (MonadChainLogic a p m, MonadIO m) => m Bool
isSynced = mySynced <$> (asks chainState >>= readTVarIO)

-- | Set chain as synced.
setSynced :: (MonadChainLogic a p m, MonadIO m) => m ()
setSynced =
    asks chainState >>= \v ->
        atomically . modifyTVar v $ \s -> s {mySynced = True}

-- | Remove a peer from the queue of peers to sync and unset the syncing peer if
-- it is set to the provided value.
finishPeer :: (Eq p, MonadIO m, MonadChainLogic a p m) => p -> m ()
finishPeer p =
    asks chainState >>= \st ->
        atomically . modifyTVar st $ \s ->
            s
                { newPeers = delete p (newPeers s)
                , syncingPeer =
                      case syncingPeer s of
                          Just (p', _)
                              | p == p' -> Nothing
                          _ -> syncingPeer s
                }

-- | Return the syncing peer and time of last communication received, if any.
lastMessage :: (MonadChainLogic a p m, MonadIO m) => m (Maybe (p, Timestamp))
lastMessage = syncingPeer <$> (readTVarIO =<< asks chainState)
