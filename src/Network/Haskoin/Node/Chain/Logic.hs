{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE UndecidableInstances      #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
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
import           Data.Time.Clock
import           Data.Time.Clock.POSIX
import           Data.Word
import           Database.RocksDB            (DB)
import qualified Database.RocksDB            as R
import           Database.RocksDB.Query      as R
import           Haskoin
import           Network.Haskoin.Node.Common
import           UnliftIO
import           UnliftIO.Resource

dataVersion :: Word32
dataVersion = 1

data ChainDataVersionKey = ChainDataVersionKey
    deriving (Eq, Ord, Show)

instance Key ChainDataVersionKey
instance KeyValue ChainDataVersionKey Word32

instance Serialize ChainDataVersionKey where
    get = do
        guard . (== 0x92) =<< S.getWord8
        return ChainDataVersionKey
    put ChainDataVersionKey = S.putWord8 0x92

data ChainState p = ChainState
    { syncingPeer :: !(Maybe (p, UTCTime))
    , newPeers    :: ![p]
    , mySynced    :: !Bool
    }

newtype BlockHeaderKey = BlockHeaderKey BlockHash deriving (Eq, Show)

instance Serialize BlockHeaderKey where
    get = do
        guard . (== 0x90) =<< getWord8
        BlockHeaderKey <$> get
    put (BlockHeaderKey bh) = do
        putWord8 0x90
        put bh

data BestBlockKey = BestBlockKey deriving (Eq, Show)

instance KeyValue BlockHeaderKey BlockNode
instance KeyValue BestBlockKey BlockNode

instance Serialize BestBlockKey where
    get = do
        guard . (== 0x91) =<< getWord8
        return BestBlockKey
    put BestBlockKey = putWord8 0x91

type MonadChainLogic a p m
     = (BlockHeaders m, MonadReader (ChainReader a p) m)

data ChainReader a p = ChainReader
    { myReader   :: !a
    , myChainDB  :: !DB
    , chainState :: !(TVar (ChainState p))
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

importHeaders ::
       (MonadIO m, BlockHeaders m)
    => Network
    -> [BlockHeader]
    -> m (Either PeerException Bool)
importHeaders net hs =
    runExceptT $ do
        now <- fromIntegral <$> computeTime
        lift (connectBlocks net now hs) >>= \case
            Right _ ->
                case length hs of
                    2000 -> return False
                    _    -> return True
            Left _ ->
                throwError PeerSentBadHeaders

notifySynced :: (MonadIO m, MonadChainLogic a p m) => m Bool
notifySynced =
    fmap isJust $
    runMaybeT $ do
        bb <- getBestBlockHeader
        now <- liftIO getCurrentTime
        let bt =
                posixSecondsToUTCTime . realToFrac . blockTimestamp $
                nodeHeader bb
        guard (diffUTCTime now bt < 2 * 60 * 60)
        st <- asks chainState
        MaybeT . atomically . runMaybeT $ do
            s <- lift $ readTVar st
            guard . isNothing $ syncingPeer s
            guard . null $ newPeers s
            guard . not $ mySynced s
            lift $ writeTVar st s {mySynced = True}
            return ()

nextPeer :: (MonadIO m, MonadChainLogic a p m) => m (Maybe p)
nextPeer = listToMaybe . newPeers <$> (asks chainState >>= readTVarIO)

syncHeaders ::
       (Eq p, MonadChainLogic a p m, MonadIO m)
    => BlockNode
    -> p
    -> m GetHeaders
syncHeaders bb p = do
    st <- asks chainState
    now <- liftIO getCurrentTime
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

setLastReceived :: (MonadChainLogic a p m, MonadIO m) => m ()
setLastReceived = do
    st <- asks chainState
    now <- liftIO getCurrentTime
    atomically . modifyTVar st $ \s ->
        s {syncingPeer = second (const now) <$> syncingPeer s}

addPeer :: (Eq p, MonadIO m, MonadChainLogic a p m) => p -> m ()
addPeer p = do
    st <- asks chainState
    atomically . modifyTVar st $ \s -> s {newPeers = nub (p : newPeers s)}

getSyncingPeer :: (MonadChainLogic a p m, MonadIO m) => m (Maybe p)
getSyncingPeer = fmap fst . syncingPeer <$> (readTVarIO =<< asks chainState)

setSyncingPeer :: (MonadChainLogic a p m, MonadIO m) => p -> m ()
setSyncingPeer p = do
    now <- liftIO getCurrentTime
    asks chainState >>= \v ->
        atomically . modifyTVar v $ \s -> s {syncingPeer = Just (p, now)}

isSynced :: (MonadChainLogic a p m, MonadIO m) => m Bool
isSynced = mySynced <$> (asks chainState >>= readTVarIO)

setSynced :: (MonadChainLogic a p m, MonadIO m) => m ()
setSynced =
    asks chainState >>= \v ->
        atomically . modifyTVar v $ \s -> s {mySynced = True}

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

lastMessage :: (MonadChainLogic a p m, MonadIO m) => m (Maybe (p, UTCTime))
lastMessage = syncingPeer <$> (readTVarIO =<< asks chainState)
