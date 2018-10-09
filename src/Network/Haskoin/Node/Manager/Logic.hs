{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TupleSections         #-}
{-|
Module      : Network.Haskoin.Manager.Logic
Copyright   : No rights reserved
License     : UNLICENSE
Maintainer  : xenog@protonmail.com
Stability   : experimental
Portability : POSIX

Logic and data for peer manager.
-}
module Network.Haskoin.Node.Manager.Logic where

import           Conduit
import           Control.Monad
import           Control.Monad.Except
import           Control.Monad.Trans.Maybe
import           Data.Bits
import qualified Data.ByteString             as B
import           Data.Default
import           Data.List
import           Data.Maybe
import           Data.Serialize              (Get, Put, Serialize)
import           Data.Serialize              as S
import           Data.String.Conversions
import           Data.Text                   (Text)
import           Data.Time.Clock
import           Data.Word
import           Database.RocksDB            (DB)
import qualified Database.RocksDB            as R
import           Database.RocksDB.Query      as R
import           Haskoin
import           Network.Haskoin.Node.Common
import           Network.Socket              (SockAddr (..))
import           UnliftIO
import           UnliftIO.Resource           as U

-- | Database version.
versionPeerDB :: Word32
versionPeerDB = 4

-- | Peer score. Lower is better.
type Score = Word8

-- | Peer address key in database.
data PeerAddress
    = PeerAddress {
        getPeerAddress :: !SockAddr
        -- ^ peer network address and port
        }
    | PeerAddressBase
    deriving (Eq, Ord, Show)

-- | Peer score key in database.
data PeerScore
    = PeerScore !Score !SockAddr
    | PeerScoreBase
    deriving (Eq, Ord, Show)

instance Serialize PeerScore where
    put (PeerScore s sa) = do
        putWord8 0x83
        S.put s
        encodeSockAddr sa
    put PeerScoreBase = S.putWord8 0x83
    get = do
        guard . (== 0x83) =<< S.getWord8
        PeerScore <$> S.get <*> decodeSockAddr

instance Key PeerScore
instance KeyValue PeerScore ()

-- | Database version key.
data PeerDataVersionKey = PeerDataVersionKey
    deriving (Eq, Ord, Show)

instance Serialize PeerDataVersionKey where
    get = do
        guard . (== 0x82) =<< S.getWord8
        return PeerDataVersionKey
    put PeerDataVersionKey = S.putWord8 0x82

instance Key PeerDataVersionKey
instance KeyValue PeerDataVersionKey Word32

instance Serialize PeerAddress where
    get = do
        guard . (== 0x81) =<< S.getWord8
        PeerAddress <$> decodeSockAddr
    put PeerAddress {getPeerAddress = a} = do
        S.putWord8 0x81
        encodeSockAddr a
    put PeerAddressBase = S.putWord8 0x81

-- | Peer data.
data PeerData = PeerData !Score !Bool
    deriving (Eq, Show, Ord)

instance Serialize PeerData where
    put (PeerData s p) = S.put s >> S.put p
    get = PeerData <$> S.get <*> S.get

instance Key PeerAddress
instance KeyValue PeerAddress PeerData

-- | Update peer score and pass in database.
updatePeerDB :: MonadIO m => DB -> SockAddr -> Score -> Bool -> m ()
updatePeerDB db sa score pass =
    retrieve db def (PeerAddress sa) >>= \case
        Nothing ->
            writeBatch
                db
                [ insertOp (PeerAddress sa) (PeerData score pass)
                , insertOp (PeerScore score sa) ()
                ]
        Just (PeerData score' _) ->
            writeBatch
                db
                [ deleteOp (PeerScore score' sa)
                , insertOp (PeerAddress sa) (PeerData score pass)
                , insertOp (PeerScore score sa) ()
                ]

-- | Add a peer to database if it is not already there.
newPeerDB :: MonadIO m => DB -> Score -> SockAddr -> m ()
newPeerDB db score sa =
    retrieve db def (PeerAddress sa) >>= \case
        Just PeerData {} -> return ()
        Nothing ->
            writeBatch
                db
                [ insertOp (PeerAddress sa) (PeerData score False)
                , insertOp (PeerScore score sa) ()
                ]

-- | Initialize peer database, purging it of conflicting records if version
-- doesn't match current one.
initPeerDB :: MonadUnliftIO m => DB -> Bool -> m ()
initPeerDB db discover = do
    ver <- retrieve db def PeerDataVersionKey
    when (ver /= Just versionPeerDB || not discover) $ purgePeerDB db
    R.insert db PeerDataVersionKey versionPeerDB

-- | Purge conflicting records from database.
purgePeerDB :: MonadUnliftIO m => DB -> m ()
purgePeerDB db = purge_byte 0x81 >> purge_byte 0x83
  where
    purge_byte byte =
        U.runResourceT . R.withIterator db def $ \it -> do
            R.iterSeek it $ B.singleton byte
            recurse_delete it byte
    recurse_delete it byte =
        R.iterKey it >>= \case
            Nothing -> return ()
            Just k
                | B.head k == byte -> do
                    R.delete db def k
                    R.iterNext it
                    recurse_delete it byte
                | otherwise -> return ()

-- | Get static network seeds.
networkSeeds :: Network -> [HostPort]
networkSeeds net = map (, getDefaultPort net) (getSeeds net)

-- | Get default score for statically-defined peers.
staticPeerScore :: Score
staticPeerScore = maxBound `div` 4

-- | Get default score for network seeds.
netSeedScore :: Score
netSeedScore = maxBound `div` 2

-- | Get default score for discovered peers.
netPeerScore :: Score
netPeerScore = maxBound `div` 3 * 4

-- | Serialize a network address/port.
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
encodeSockAddr x = error $ "Could not encode address: " <> show x

-- | Deserialize a network address/port.
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

-- | Get database entry for provided peer address.
getPeerDB :: MonadIO m => DB -> SockAddr -> m (Maybe PeerData)
getPeerDB db sa = retrieve db def (PeerAddress sa)

-- | Promote a peer by improving its score (decreasing by one).
promotePeerDB :: MonadIO m => DB -> SockAddr -> m ()
promotePeerDB db sa =
    getPeerDB db sa >>= \case
        Nothing -> return ()
        Just (PeerData score pass) ->
            updatePeerDB
                db
                sa
                (if score == 0
                     then score
                     else score - 1)
                pass

-- | Demote a peer increasing its score by one.
demotePeerDB :: MonadIO m => DB -> SockAddr -> m ()
demotePeerDB db sa =
    getPeerDB db sa >>= \case
        Nothing -> return ()
        Just (PeerData score pass) ->
            updatePeerDB
                db
                sa
                (if score == maxBound
                     then score
                     else score + 1)
                pass

-- | Get a peer from database. Pass a list of addresses to exclude.
getNewPeerDB :: MonadUnliftIO m => DB -> [SockAddr] -> m (Maybe SockAddr)
getNewPeerDB db exclude = go >>= maybe (reset_pass >> go) (return . Just)
  where
    go =
        U.runResourceT . runConduit $
        matching db def PeerScoreBase .| filterMC filter_pass .|
        mapC get_address .|
        filterC (`notElem` exclude) .|
        headC
    reset_pass =
        U.runResourceT . runConduit $
            matching db def PeerAddressBase .| mapM_C reset_peer_pass
    reset_peer_pass (PeerAddress addr, PeerData score _) =
        updatePeerDB db addr score False
    reset_peer_pass _ = return ()
    filter_pass (PeerScore _ addr, ()) =
        retrieve db def (PeerAddress addr) >>= \case
            Just (PeerData score pass)
                | not pass -> do
                    updatePeerDB db addr score True
                    return True
            _ -> return False
    filter_pass _ = return False
    get_address (PeerScore _ addr, ()) = addr
    get_address _ = error "Something is wrong with peer database"

-- | Report receiving a pong from a connected peer. Will store ping roundtrip
-- time in a window of latest eleven. Peers are returned by the manager in order
-- of median roundtrip time.
gotPong ::
       TVar [OnlinePeer]
    -> Word64
    -> UTCTime
    -> Peer
    -> STM (Maybe NominalDiffTime)
gotPong b nonce now p =
    runMaybeT $ do
        o <- MaybeT $ findPeer b p
        (time, old_nonce) <- MaybeT . return $ onlinePeerPing o
        guard $ nonce == old_nonce
        let diff = now `diffUTCTime` time
        lift $
            insertPeer
                b
                o
                    { onlinePeerPing = Nothing
                    , onlinePeerPings = take 11 $ diff : onlinePeerPings o
                    }
        return diff

-- | Return time of last ping sent to peer, if any.
lastPing :: TVar [OnlinePeer] -> Peer -> STM (Maybe UTCTime)
lastPing b p =
    findPeer b p >>= \case
        Just OnlinePeer {onlinePeerPing = Just (time, _)} -> return (Just time)
        _ -> return Nothing

-- | Set nonce and time of last ping sent to peer.
setPeerPing :: TVar [OnlinePeer] -> Word64 -> UTCTime -> Peer -> STM ()
setPeerPing b nonce now p =
    modifyPeer b p $ \o -> o {onlinePeerPing = Just (now, nonce)}

-- | Set version for online peer. Will set the peer connected status to 'True'
-- if a verack message has already been registered for that peer.
setPeerVersion ::
       TVar [OnlinePeer]
    -> Peer
    -> Version
    -> STM (Either PeerException OnlinePeer)
setPeerVersion b p v =
    runExceptT $ do
        when (services v .&. nodeNetwork == 0) $ throwError NotNetworkPeer
        ops <- lift $ readTVar b
        when (any ((verNonce v ==) . onlinePeerNonce) ops) $
            throwError PeerIsMyself
        lift (findPeer b p) >>= \case
            Nothing -> throwError UnknownPeer
            Just o -> do
                let n =
                        o
                            { onlinePeerVersion = Just v
                            , onlinePeerConnected = onlinePeerVerAck o
                            }
                lift $ insertPeer b n
                return n

-- | Register that a verack message was received from a peer.
setPeerVerAck :: TVar [OnlinePeer] -> Peer -> STM (Maybe OnlinePeer)
setPeerVerAck b p =
    runMaybeT $ do
        o <- MaybeT $ findPeer b p
        let n =
                o
                    { onlinePeerVerAck = True
                    , onlinePeerConnected = isJust (onlinePeerVersion o)
                    }
        lift $ insertPeer b n
        return n

-- | Create 'OnlinePeer' data structure.
newOnlinePeer ::
       TVar [OnlinePeer]
    -> SockAddr
       -- ^ peer address
    -> Word64
       -- ^ nonce sent to peer
    -> Peer
       -- ^ peer mailbox
    -> Async ()
       -- ^ peer asynchronous handle
    -> STM OnlinePeer
newOnlinePeer b sa nonce peer peer_async = do
    let op =
            OnlinePeer
                { onlinePeerAddress = sa
                , onlinePeerVerAck = False
                , onlinePeerConnected = False
                , onlinePeerVersion = Nothing
                , onlinePeerAsync = peer_async
                , onlinePeerMailbox = peer
                , onlinePeerNonce = nonce
                , onlinePeerPings = []
                , onlinePeerPing = Nothing
                }
    insertPeer b op
    return op

-- | Get a human-readable string for the peer address.
peerString :: TVar [OnlinePeer] -> Peer -> STM Text
peerString b p =
    maybe "[unknown]" (cs . show . onlinePeerAddress) <$> findPeer b p

-- | Find a connected peer.
findPeer :: TVar [OnlinePeer] -> Peer -> STM (Maybe OnlinePeer)
findPeer b p = find ((== p) . onlinePeerMailbox) <$> readTVar b

-- | Insert or replace a connected peer.
insertPeer :: TVar [OnlinePeer] -> OnlinePeer -> STM ()
insertPeer b o = modifyTVar b $ \x -> sort . nub $ o : x

-- | Modify an online peer.
modifyPeer :: TVar [OnlinePeer] -> Peer -> (OnlinePeer -> OnlinePeer) -> STM ()
modifyPeer b p f =
    findPeer b p >>= \case
        Nothing -> return ()
        Just o -> insertPeer b $ f o

-- | Remove an online peer.
removePeer :: TVar [OnlinePeer] -> Peer -> STM ()
removePeer b p = modifyTVar b $ \x -> filter ((/= p) . onlinePeerMailbox) x

-- | Find online peer by asynchronous handle.
findPeerAsync :: TVar [OnlinePeer] -> Async () -> STM (Maybe OnlinePeer)
findPeerAsync b a = find ((== a) . onlinePeerAsync) <$> readTVar b

-- | Remove online peer by asynchronous handle.
removePeerAsync :: TVar [OnlinePeer] -> Async () -> STM ()
removePeerAsync b a = modifyTVar b $ \x -> filter ((/= a) . onlinePeerAsync) x
