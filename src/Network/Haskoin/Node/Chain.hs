{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE UndecidableInstances      #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Network.Haskoin.Node.Chain
( chain
) where

import           Control.Applicative
import           Control.Monad
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.Trans.Maybe
import qualified Data.ByteString             as B
import           Data.Default
import           Data.Either
import           Data.List                   (delete, nub)
import           Data.Maybe
import           Data.Serialize              as S
import           Data.String
import           Data.String.Conversions
import           Data.Time.Clock
import           Data.Word
import           Database.RocksDB            (DB)
import qualified Database.RocksDB            as R
import           Database.RocksDB.Query      as R
import           Network.Haskoin.Block
import           Network.Haskoin.Network
import           Network.Haskoin.Node.Common
import           NQE
import           System.Random
import           UnliftIO
import           UnliftIO.Concurrent
import           UnliftIO.Resource

dataVersion :: Word32
dataVersion = 1

type MonadChain m
     = ( BlockHeaders m
       , MonadLoggerIO m
       , MonadReader ChainReader m)

data ChainDataVersionKey = ChainDataVersionKey
    deriving (Eq, Ord, Show)

instance Key ChainDataVersionKey
instance KeyValue ChainDataVersionKey Word32

instance Serialize ChainDataVersionKey where
    get = do
        guard . (== 0x92) =<< S.getWord8
        return ChainDataVersionKey
    put ChainDataVersionKey = S.putWord8 0x92

data ChainState = ChainState
    { syncingPeer  :: !(Maybe Peer)
    , newPeers     :: ![Peer]
    , mySynced     :: !Bool
    , lastReceived :: !UTCTime
    }

data ChainReader = ChainReader
    { myConfig   :: !ChainConfig
    , chainState :: !(TVar ChainState)
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

instance (Monad m, MonadLoggerIO m, MonadReader ChainReader m) =>
         BlockHeaders m where
    addBlockHeader bn = do
        db <- chainConfDB <$> asks myConfig
        insert db (BlockHeaderKey (headerHash (nodeHeader bn))) bn
    getBlockHeader bh = do
        db <- chainConfDB <$> asks myConfig
        retrieve db def (BlockHeaderKey bh)
    getBestBlockHeader = do
        db <- chainConfDB <$> asks myConfig
        retrieve db def BestBlockKey >>= \case
            Nothing -> error "Could not get best block from database"
            Just b -> return b
    setBestBlockHeader bn = do
        db <- chainConfDB <$> asks myConfig
        insert db BestBlockKey bn
    addBlockHeaders bns = do
        db <- chainConfDB <$> asks myConfig
        writeBatch db (map f bns)
      where
        f bn = insertOp (BlockHeaderKey (headerHash (nodeHeader bn))) bn

chain :: (MonadUnliftIO m, MonadLoggerIO m) => ChainConfig -> m ()
chain cfg@ChainConfig {..} = do
    now <- liftIO getCurrentTime
    st <-
        newTVarIO
            ChainState
                { syncingPeer = Nothing
                , mySynced = False
                , newPeers = []
                , lastReceived = now
                }
    let rd = ChainReader {myConfig = cfg, chainState = st}
    run `runReaderT` rd
  where
    net = chainConfNetwork
    db = chainConfDB
    ch = chainConfMailbox
    ppub = chainConfPeerPub
    run = do
        ver <- fromMaybe 1 <$> retrieve db def ChainDataVersionKey
        when (ver < dataVersion) $ purgeDB db
        insert db ChainDataVersionKey dataVersion
        b <- retrieve db def BestBlockKey
        when (isNothing (b :: Maybe BlockNode)) $ do
            addBlockHeader (genesisNode net)
            insert db BestBlockKey (genesisNode net)
        withPubSub Nothing ppub $ \sub ->
            withSyncLoop ch . forever $
            recv sub >>= \case
                Left event -> uncurry processEvent event
                Right msg -> processMessage msg
    recv sub = atomically $ Right <$> receiveSTM ch <|> Left <$> receiveSTM sub

purgeDB :: MonadUnliftIO m => DB -> m ()
purgeDB db = runResourceT . R.withIterator db def $ \it -> do
    R.iterSeek it $ B.singleton 0x90
    recurse_delete it
  where
    recurse_delete it = R.iterKey it >>= \case
        Nothing -> return ()
        Just k | B.head k == 0x90 || B.head k == 0x91 -> do
                 R.delete db def k
                 R.iterNext it
                 recurse_delete it
               | otherwise -> return ()

processEvent :: MonadChain m => Peer -> PeerEvent -> m ()
processEvent p (PeerMessage (MHeaders (Headers hcs))) =
    processHeaders p (map fst hcs)
processEvent p PeerConnected = do
    asks chainState >>= \b ->
        atomically . modifyTVar b $ \s -> s {newPeers = nub $ p : newPeers s}
    processSyncQueue
processEvent p PeerDisconnected = do
    mp <-
        asks chainState >>= \b ->
            atomically $ do
                s <- readTVar b
                writeTVar
                    b
                    s
                        { newPeers = delete p (newPeers s)
                        , syncingPeer =
                              if syncingPeer s == Just p
                                  then Nothing
                                  else syncingPeer s
                        }
                return (syncingPeer s)
    when (mp == Just p) processSyncQueue
processEvent _ _ = return ()

processHeaders :: MonadChain m => Peer -> [BlockHeader] -> m ()
processHeaders p hs =
    void . runMaybeT $ do
        ChainConfig {..} <- asks myConfig
        let net = chainConfNetwork
            mgr = chainConfManager
        ChainState {..} <- readTVarIO =<< asks chainState
        guard (syncingPeer == Just p)
        setLastReceived
        now <- computeTime
        cur_best <- getBestBlockHeader
        connectBlocks net now hs >>= \case
            Right block_nodes -> conn cur_best block_nodes
            Left e -> do
                $(logWarnS) "Chain" $ "Could not connect headers: " <> cs e
                pstr <- peerString p
                $(logErrorS) "Chain" $
                    "Syncing peer " <> pstr <> " sent bad headers"
                managerKill PeerSentBadHeaders p mgr
  where
    synced = do
        asks chainState >>= \b ->
            atomically . modifyTVar b $ \s -> s {syncingPeer = Nothing}
        MSendHeaders `sendMessage` p
        processSyncQueue
    conn cur_best block_nodes = do
        ChainConfig {..} <- asks myConfig
        let pub = chainConfPub
        new_best <- getBestBlockHeader
        when (cur_best /= new_best) $ do
            $(logInfoS) "Chain" $
                "New best block header at height " <>
                cs (show (nodeHeight new_best))
            Event (ChainBestBlock new_best) `send` pub
        case length hs of
            2000 -> syncHeaders (head block_nodes) p
            _    -> synced

processMessage :: MonadChain m => ChainMessage -> m ()
processMessage (ChainGetBest reply) =
    getBestBlockHeader >>= atomically . reply

processMessage (ChainGetAncestor h n reply) =
    getAncestor h n >>= atomically . reply

processMessage (ChainGetSplit r l reply) =
    splitPoint r l >>= atomically . reply

processMessage (ChainGetBlock h reply) =
    getBlockHeader h >>= atomically . reply

processMessage (ChainIsSynced reply) = do
    st <- asks chainState
    s <- mySynced <$> readTVarIO st
    atomically (reply s)

processMessage ChainPing = do
    ChainConfig {..} <- asks myConfig
    let mgr = chainConfManager
    b <- asks chainState
    readTVarIO b >>= \s ->
        case syncingPeer s of
            Just p -> do
                now <- liftIO getCurrentTime
                when ((now `diffUTCTime` lastReceived s) > 60) $
                    ManagerKill PeerTimeout p `send` mgr
            Nothing
                | null (newPeers s) -> do
                    ps <- map onlinePeerMailbox <$> managerGetPeers mgr
                    atomically . modifyTVar b $ \x -> x {newPeers = ps}
                    processSyncQueue
                | otherwise -> return ()

processSyncQueue :: MonadChain m => m ()
processSyncQueue = do
    s <- asks chainState >>= readTVarIO
    when (isNothing (syncingPeer s)) $ getBestBlockHeader >>= go s
  where
    go s bb =
        case newPeers s of
            [] ->
                unless (mySynced s) $ do
                    pub <- chainConfPub <$> asks myConfig
                    b <- asks chainState
                    atomically $ do
                        Event (ChainSynced bb) `sendSTM` pub
                        writeTVar b s {mySynced = True}
            p:_ -> syncHeaders bb p

syncHeaders :: MonadChain m => BlockNode -> Peer -> m ()
syncHeaders bb p = do
    asks chainState >>= \b ->
        atomically . modifyTVar b $ \s ->
            s {syncingPeer = Just p, newPeers = delete p (newPeers s)}
    loc <- blockLocator bb
    let msg =
            MGetHeaders
                GetHeaders
                    { getHeadersVersion = myVersion
                    , getHeadersBL = loc
                    , getHeadersHashStop = z
                    }
    msg `send` p
  where
    z =
        fromRight (error "Could not decode zero hash") . decode $
        B.replicate 32 0x00

peerString :: (MonadChain m, IsString a) => Peer -> m a
peerString p = do
    mgr <- chainConfManager <$> asks myConfig
    managerGetPeer mgr p >>= \case
        Nothing -> return "[unknown]"
        Just o -> return $ fromString $ show (onlinePeerAddress o)

withSyncLoop :: (MonadUnliftIO m, MonadLoggerIO m) => Chain -> m a -> m a
withSyncLoop ch f = withAsync go $ \a -> link a >> f
  where
    go =
        forever $ do
            threadDelay =<<
                liftIO (randomRIO (40 * 1000 * 1000, 60 * 1000 * 1000))
            ChainPing `send` ch

setLastReceived :: MonadChain m => m ()
setLastReceived = do
    now <- liftIO getCurrentTime
    asks chainState >>= \b ->
        atomically . modifyTVar b $ \s -> s {lastReceived = now}
