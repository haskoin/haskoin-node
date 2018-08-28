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
module Network.Haskoin.Node.Chain
( chain
) where

import           Control.Concurrent.NQE
import           Control.Monad
import           Control.Monad.Logger
import           Control.Monad.Reader
import qualified Data.ByteString             as BS
import           Data.Either
import           Data.List                   (delete, nub)
import           Data.Maybe
import           Data.Serialize
import           Data.String
import           Data.String.Conversions
import           Database.RocksDB            (DB)
import qualified Database.RocksDB            as RocksDB
import           Database.RocksDB.Query
import           Network.Haskoin.Block
import           Network.Haskoin.Network
import           Network.Haskoin.Node.Common
import           UnliftIO

type MonadChain m
     = ( BlockHeaders m
       , MonadLoggerIO m
       , MonadReader ChainReader m)

data ChainState = ChainState
    { syncingPeer :: !(Maybe Peer)
    , newPeers    :: ![Peer]
    , mySynced    :: !Bool
    }

data ChainReader = ChainReader
    { headerDB   :: !DB
    , myConfig   :: !ChainConfig
    , chainState :: !(TVar ChainState)
    }

newtype BlockHeaderKey = BlockHeaderKey BlockHash deriving (Eq, Show)

instance Serialize BlockHeaderKey where
    get = do
        guard . (== 0x90) =<< getWord8
        bh <- get
        return (BlockHeaderKey bh)
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
        db <- asks headerDB
        insert db (BlockHeaderKey (headerHash (nodeHeader bn))) bn
    getBlockHeader bh = do
        db <- asks headerDB
        retrieve db Nothing (BlockHeaderKey bh)
    getBestBlockHeader = do
        db <- asks headerDB
        retrieve db Nothing BestBlockKey >>= \case
            Nothing -> error "Could not get best block from database"
            Just b -> return b
    setBestBlockHeader bn = do
        db <- asks headerDB
        insert db BestBlockKey bn
    addBlockHeaders bns = do
        db <- asks headerDB
        writeBatch db (map f bns)
      where
        f bn = insertOp (BlockHeaderKey (headerHash (nodeHeader bn))) bn

chain ::
       ( MonadUnliftIO m
       , MonadLoggerIO m
       )
    => ChainConfig
    -> m ()
chain cfg = do
    st <-
        newTVarIO
            ChainState {syncingPeer = Nothing, mySynced = False, newPeers = []}
    let rd =
            ChainReader
            {myConfig = cfg, headerDB = chainConfDB cfg, chainState = st}
    run `runReaderT` rd
  where
    net = chainConfNetwork cfg
    run = do
        let gs = encode (genesisNode net)
        db <- asks headerDB
        m <- RocksDB.get db RocksDB.defaultReadOptions (BS.singleton 0x91)
        when (isNothing m) $ do
            addBlockHeader (genesisNode net)
            RocksDB.put db RocksDB.defaultWriteOptions (BS.singleton 0x91) gs
        forever $ do
            msg <- receive $ chainConfChain cfg
            processChainMessage msg

processChainMessage :: MonadChain m => ChainMessage -> m ()
processChainMessage (ChainNewHeaders p hcs) = do
    stb <- asks chainState
    st <- readTVarIO stb
    net <- chainConfNetwork <$> asks myConfig
    let spM = syncingPeer st
    t <- computeTime
    bb <- getBestBlockHeader
    bhsE <- connectBlocks net t (map fst hcs)
    case bhsE of
        Right bhs -> conn bb bhs spM
        Left e -> do
            $(logWarn) $ logMe <> "Could not connect headers: " <> cs e
            case spM of
                Nothing -> do
                    bb' <- getBestBlockHeader
                    atomically . modifyTVar stb $ \s ->
                        s {newPeers = nub $ p : newPeers s}
                    syncHeaders bb' p
                Just sp
                    | sp == p -> do
                        $(logError) $ logMe <> "Syncing peer sent bad headers"
                        mgr <- chainConfManager <$> asks myConfig
                        managerKill PeerSentBadHeaders p mgr
                        atomically . modifyTVar stb $ \s ->
                            s {syncingPeer = Nothing}
                        processSyncQueue
                    | otherwise ->
                        atomically . modifyTVar stb $ \s ->
                            s {newPeers = nub $ p : newPeers s}
  where
    synced bb = do
        $(logInfo) $
            logMe <> "Headers synced to height " <> cs (show (nodeHeight bb))
        st <- asks chainState
        atomically . modifyTVar st $ \s -> s {syncingPeer = Nothing}
        MSendHeaders `sendMessage` p
        processSyncQueue
    upeer bb = do
        mgr <- chainConfManager <$> asks myConfig
        managerSetPeerBest p bb mgr
    conn bb bhs spM = do
        bb' <- getBestBlockHeader
        when (bb /= bb') $ do
            $(logInfo) $
                logMe <> "Best header at height " <> cs (show (nodeHeight bb'))
            mgr <- chainConfManager <$> asks myConfig
            managerSetBest bb' mgr
            l <- chainConfListener <$> asks myConfig
            atomically . l $ ChainNewBest bb'
        case length hcs of
            0 -> synced bb'
            2000 ->
                case spM of
                    Just sp
                        | sp == p -> do
                            upeer $ head bhs
                            syncHeaders (head bhs) p
                    _ -> do
                        st <- asks chainState
                        atomically . modifyTVar st $ \s ->
                            s {newPeers = nub $ p : newPeers s}
            _ -> do
                upeer $ head bhs
                synced bb'

processChainMessage (ChainNewPeer p) = do
    st <- asks chainState
    sp <-
        atomically $ do
            modifyTVar st $ \s -> s {newPeers = nub $ p : newPeers s}
            syncingPeer <$> readTVar st
    case sp of
        Nothing -> processSyncQueue
        Just _  -> return ()

-- Getting a new block should trigger an action equivalent to getting a new peer
processChainMessage (ChainNewBlocks p _) = processChainMessage (ChainNewPeer p)

processChainMessage (ChainRemovePeer p) = do
    st <- asks chainState
    sp <-
        atomically $ do
            modifyTVar st $ \s -> s {newPeers = delete p (newPeers s)}
            syncingPeer <$> readTVar st
    case sp of
        Just p' ->
            when (p == p') $ do
                atomically . modifyTVar st $ \s ->
                    s {syncingPeer = Nothing}
                processSyncQueue
        Nothing -> return ()

processChainMessage (ChainGetBest reply) =
    getBestBlockHeader >>= atomically . reply

processChainMessage (ChainGetAncestor h n reply) = do
    getAncestor h n >>= atomically . reply

processChainMessage (ChainGetSplit r l reply) = do
    splitPoint r l >>= atomically . reply

processChainMessage (ChainGetBlock h reply) = do
    getBlockHeader h >>= atomically . reply

processChainMessage (ChainSendHeaders _) = return ()

processChainMessage (ChainIsSynced reply) = do
    st <- asks chainState
    s <- mySynced <$> readTVarIO st
    atomically (reply s)

processSyncQueue :: MonadChain m => m ()
processSyncQueue = do
    s <- asks chainState >>= readTVarIO
    when (isNothing (syncingPeer s)) $ getBestBlockHeader >>= go s
  where
    go s bb =
        case newPeers s of
            [] -> do
                t <- computeTime
                let h2 = t - 2 * 60 * 60
                    tg = blockTimestamp (nodeHeader bb) > h2
                if tg
                    then unless (mySynced s) $ do
                             l <- chainConfListener <$> asks myConfig
                             st <- asks chainState
                             atomically $ do
                                 l (ChainSynced bb)
                                 writeTVar st s {mySynced = True}
                    else do
                        l <- chainConfListener <$> asks myConfig
                        st <- asks chainState
                        atomically $ do
                            l (ChainNotSynced bb)
                            writeTVar st s {mySynced = False}
            p:_ -> syncHeaders bb p

syncHeaders :: MonadChain m => BlockNode -> Peer -> m ()
syncHeaders bb p = do
    st <- asks chainState
    s <- readTVarIO st
    atomically . writeTVar st $
        s {syncingPeer = Just p, newPeers = delete p (newPeers s)}
    loc <- blockLocator bb
    let m =
            MGetHeaders
                GetHeaders
                { getHeadersVersion = myVersion
                , getHeadersBL = loc
                , getHeadersHashStop =
                      fromRight (error "Could not decode zero hash") . decode $
                      BS.replicate 32 0
                }
    PeerOutgoing m `send` p

logMe :: IsString a => a
logMe = "[Chain] "
