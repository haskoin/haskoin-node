{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
{-|
Module      : Network.Haskoin.Node.Common
Copyright   : No rights reserved
License     : UNLICENSE
Maintainer  : xenog@protonmail.com
Stability   : experimental
Portability : POSIX

Common functions used by Haskoin Node.
-}
module Network.Haskoin.Node.Common where

import           Conduit
import           Control.Monad
import           Control.Monad.Trans.Maybe
import           Data.Conduit.Network
import           Data.Function
import           Data.List
import           Data.Maybe
import           Data.String.Conversions
import           Data.Time.Clock
import           Data.Time.Clock.POSIX
import           Data.Word
import           Database.RocksDB            (DB)
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Network
import           Network.Haskoin.Transaction
import           Network.Socket              hiding (send)
import           NQE
import           System.Random
import           Text.Read
import           UnliftIO

-- | Type alias for a combination of hostname and port.
type HostPort = (Host, Port)

-- | Type alias for a hostname.
type Host = String

-- | Type alias for a port number.
type Port = Int

-- | Data structure representing an online peer.
data OnlinePeer = OnlinePeer
    { onlinePeerAddress   :: !SockAddr
      -- ^ network address
    , onlinePeerVerAck    :: !Bool
      -- ^ got version acknowledgement from peer
    , onlinePeerConnected :: !Bool
      -- ^ peer is connected and ready
    , onlinePeerVersion   :: !(Maybe Version)
      -- ^ protocol version
    , onlinePeerAsync     :: !(Async ())
      -- ^ peer asynchronous process
    , onlinePeerMailbox   :: !Peer
      -- ^ peer mailbox
    , onlinePeerNonce     :: !Word64
      -- ^ random nonce sent during handshake
    , onlinePeerPing      :: !(Maybe (UTCTime, Word64))
      -- ^ last sent ping time and nonce
    , onlinePeerPings     :: ![NominalDiffTime]
      -- ^ last few ping rountrip duration
    }

instance Eq OnlinePeer where
    (==) = (==) `on` f
      where
        f OnlinePeer {onlinePeerMailbox = p} = p

instance Ord OnlinePeer where
    compare = compare `on` f
      where
        f OnlinePeer {onlinePeerPings = pings} = fromMaybe 60 (median pings)

-- | Mailbox for a peer.
type Peer = Mailbox PeerMessage

-- | Mailbox for chain header syncing process.
type Chain = Mailbox ChainMessage

-- | Mailbox for peer manager process.
type Manager = Mailbox ManagerMessage

-- | General node configuration.
data NodeConfig = NodeConfig
    { nodeConfMaxPeers :: !Int
      -- ^ maximum number of connected peers allowed
    , nodeConfDB       :: !DB
      -- ^ database handler
    , nodeConfPeers    :: ![HostPort]
      -- ^ static list of peers to connect to
    , nodeConfDiscover :: !Bool
      -- ^ activate peer discovery
    , nodeConfNetAddr  :: !NetworkAddress
      -- ^ network address for the local host
    , nodeConfNet      :: !Network
      -- ^ network constants
    , nodeConfEvents   :: !(Publisher NodeEvent)
      -- ^ node events are sent to this publisher
    , nodeConfTimeout  :: !Int
      -- ^ timeout in seconds
    }

-- | Peer manager configuration.
data ManagerConfig = ManagerConfig
    { mgrConfMaxPeers :: !Int
      -- ^ maximum number of peers to connect to
    , mgrConfDB       :: !DB
      -- ^ database handler to store peer information
    , mgrConfPeers    :: ![HostPort]
      -- ^ static list of peers to connect to
    , mgrConfDiscover :: !Bool
      -- ^ activate peer discovery
    , mgrConfNetAddr  :: !NetworkAddress
      -- ^ network address for the local host
    , mgrConfNetwork  :: !Network
      -- ^ network constants
    , mgrConfEvents   :: !(Listen PeerEvent)
      -- ^ send manager and peer messages to this mailbox
    , mgrConfTimeout  :: !Int
      -- ^ timeout in seconds
    }

-- | Messages that can be sent to the peer manager.
data ManagerMessage
    = ManagerConnect
      -- ^ try to connect to peers
    | ManagerGetPeers !(Listen [OnlinePeer])
      -- ^ get all connected peers
    | ManagerGetOnlinePeer !Peer !(Listen (Maybe OnlinePeer))
      -- ^ get a peer information
    | ManagerPurgePeers
      -- ^ delete all known peers
    | ManagerCheckPeer !Peer
      -- ^ check this peer
    | ManagerPeerMessage !Peer !Message
      -- ^ peer got a message that is forwarded to manager
    | ManagerPeerDied !Child !(Maybe SomeException)
      -- ^ child died
    | ManagerBestBlock !BlockHeight
      -- ^ set this as our best block

-- | Configuration for chain syncing process.
data ChainConfig = ChainConfig
    { chainConfDB      :: !DB
      -- ^ database handle
    , chainConfNetwork :: !Network
      -- ^ network constants
    , chainConfEvents  :: !(Listen ChainEvent)
      -- ^ send header chain events here
    , chainConfTimeout :: !Int
      -- ^ timeout in seconds
    }

-- | Messages that can be sent to the chain process.
data ChainMessage
    = ChainGetBest !(Listen BlockNode)
      -- ^ get best block known
    | ChainHeaders !Peer
                   ![BlockHeader]
    | ChainGetAncestor !BlockHeight
                       !BlockNode
                       !(Listen (Maybe BlockNode))
      -- ^ get ancestor for 'BlockNode' at 'BlockHeight'
    | ChainGetSplit !BlockNode
                    !BlockNode
                    !(Listen BlockNode)
      -- ^ get highest common node
    | ChainGetBlock !BlockHash
                    !(Listen (Maybe BlockNode))
      -- ^ get a block header
    | ChainIsSynced !(Listen Bool)
      -- ^ is chain in sync with network?
    | ChainPing
      -- ^ internal message for process housekeeping
    | ChainPeerConnected !Peer
                         !SockAddr
      -- ^ internal message to notify that a peer has connected
    | ChainPeerDisconnected !Peer
                            !SockAddr
      -- ^ internal message to notify that a peer has disconnected

-- | Events originating from chain syncing process.
data ChainEvent
    = ChainBestBlock !BlockNode
      -- ^ chain has new best block
    | ChainSynced !BlockNode
      -- ^ chain is in sync with the network
    deriving (Eq, Show)

-- | Chain and peer events generated by the node.
data NodeEvent
    = ChainEvent !ChainEvent
      -- ^ events from the chain syncing process
    | PeerEvent !PeerEvent
      -- ^ events from peers and peer manager
    deriving Eq

-- | Configuration for a particular peer.
data PeerConfig = PeerConfig
    { peerConfListen  :: !(Publisher Message)
      -- ^ Send peer messages to publisher
    , peerConfNetwork :: !Network
      -- ^ network constants
    , peerConfAddress :: !SockAddr
      -- ^ peer address
    }

-- | Reasons why a peer may stop working.
data PeerException
    = PeerMisbehaving !String
      -- ^ peer is being a naughty boy
    | DuplicateVersion
      -- ^ peer sent an extra version message
    | DecodeHeaderError
      -- ^ incoming message headers could not be decoded
    | CannotDecodePayload
      -- ^ incoming message payload could not be decoded
    | PeerIsMyself
      -- ^ nonce for peer matches ours
    | PayloadTooLarge !Word32
      -- ^ message payload too large
    | PeerAddressInvalid
      -- ^ peer address not valid
    | PeerSentBadHeaders
      -- ^ peer sent wrong headers
    | NotNetworkPeer
      -- ^ peer cannot serve block chain data
    | PeerNoSegWit
      -- ^ peer has no segwit support
    | PeerTimeout
      -- ^ request to peer timed out
    | PurgingPeer
      -- ^ peers are being purged
    | UnknownPeer
      -- ^ peer is unknown
    deriving (Eq, Show)

instance Exception PeerException

-- | Events originating from peers and the peer manager.
data PeerEvent
    = PeerConnected !Peer
                    !SockAddr
      -- ^ new peer connected
    | PeerDisconnected !Peer
                       !SockAddr
      -- ^ peer disconnected
    | PeerMessage !Peer
                  !Message
      -- ^ peer sent a message
    deriving Eq

-- | Incoming messages that a peer accepts.
data PeerMessage
    = GetPublisher !(Listen (Publisher Message))
    | KillPeer !PeerException
    | SendMessage !Message

-- | Resolve a host and port to a list of 'SockAddr'. May make use DNS resolver.
toSockAddr :: MonadUnliftIO m => HostPort -> m [SockAddr]
toSockAddr (host, port) = go `catch` e
  where
    go =
        fmap (map addrAddress) . liftIO $
        getAddrInfo
            (Just
                 defaultHints
                 { addrFlags = [AI_ADDRCONFIG]
                 , addrSocketType = Stream
                 , addrFamily = AF_INET
                 })
            (Just host)
            (Just (show port))
    e :: Monad m => SomeException -> m [SockAddr]
    e _ = return []

-- | Convert a 'SockAddr' to a a numeric host and port.
fromSockAddr ::
       (MonadUnliftIO m) => SockAddr -> m (Maybe HostPort)
fromSockAddr sa = go `catch` e
  where
    go = do
        (maybe_host, maybe_port) <- liftIO (getNameInfo flags True True sa)
        return $ (,) <$> maybe_host <*> (readMaybe =<< maybe_port)
    flags = [NI_NUMERICHOST, NI_NUMERICSERV]
    e :: Monad m => SomeException -> m (Maybe a)
    e _ = return Nothing

-- | Integer current time in seconds from 1970-01-01T00:00Z.
computeTime :: MonadIO m => m Word64
computeTime = round <$> liftIO getPOSIXTime

-- | Our protocol version.
myVersion :: Word32
myVersion = 70012

-- | Internal function used by peer to send a message to the peer manager.
managerPeerMessage :: MonadIO m => Peer -> Message -> Manager -> m ()
managerPeerMessage p msg mgr = ManagerPeerMessage p msg `send` mgr

-- | Get list of connected peers from manager.
managerGetPeers ::
       MonadIO m => Manager -> m [OnlinePeer]
managerGetPeers mgr = ManagerGetPeers `query` mgr

-- | Get information for an online peer from manager.
managerGetPeer :: MonadIO m => Peer -> Manager -> m (Maybe OnlinePeer)
managerGetPeer p mgr = ManagerGetOnlinePeer p `query` mgr

-- | Ask manager to kill a peer with the provided exception.
killPeer :: MonadIO m => PeerException -> Peer -> m ()
killPeer e p = KillPeer e `send` p

-- | Internal function used by manager to check peers periodically.
managerCheck :: MonadIO m => Peer -> Manager -> m ()
managerCheck p mgr = ManagerCheckPeer p `send` mgr

-- | Internal function used to ask manager to connect to a new peer.
managerConnect :: MonadIO m => Manager ->  m ()
managerConnect mgr = ManagerConnect `send` mgr

-- | Set the best block that the manager knows about.
managerSetBest :: MonadIO m => BlockHeight -> Manager -> m ()
managerSetBest bh mgr = ManagerBestBlock bh `send` mgr

-- | Send a network message to peer.
sendMessage :: MonadIO m => Message -> Peer -> m ()
sendMessage msg p = SendMessage msg `send` p

-- | Get a publisher associated to a peer. Must provide timeout as peer may
-- disconnect and become unresponsive.
peerGetPublisher ::
       MonadUnliftIO m => Int -> Peer -> m (Maybe (Publisher Message))
peerGetPublisher time = queryS time GetPublisher

-- | Request full blocks from peer. Will return 'Nothing' if the list of blocks
-- returned by the peer is incomplete, comes out of order, or a timeout is
-- reached.
peerGetBlocks ::
       MonadUnliftIO m
    => Network
    -> Int
    -> Peer
    -> [BlockHash]
    -> m (Maybe [Block])
peerGetBlocks net time p bhs =
    runMaybeT $ mapM f =<< MaybeT (peerGetData time p (GetData ivs))
  where
    f (Right b) = return b
    f (Left _)  = MaybeT $ return Nothing
    c
        | getSegWit net = InvWitnessBlock
        | otherwise = InvBlock
    ivs = map (InvVector c . getBlockHash) bhs

-- | Request transactions from peer. Will return 'Nothing' if the list of
-- transactions returned by the peer is incomplete, comes out of order, or a
-- timeout is reached.
peerGetTxs ::
       MonadUnliftIO m
    => Network
    -> Int
    -> Peer
    -> [TxHash]
    -> m (Maybe [Tx])
peerGetTxs net time p ths =
    runMaybeT $ mapM f =<< MaybeT (peerGetData time p (GetData ivs))
  where
    f (Right _) = MaybeT $ return Nothing
    f (Left t)  = return t
    c
        | getSegWit net = InvWitnessTx
        | otherwise = InvTx
    ivs = map (InvVector c . getTxHash) ths

-- | Request transactions and/or blocks from peer. Return maybe if any single
-- inventory fails to be retrieved, if they come out of order, or if timeout is
-- reached.
peerGetData ::
       MonadUnliftIO m => Int -> Peer -> GetData -> m (Maybe [Either Tx Block])
peerGetData time p gd@(GetData ivs) =
    runMaybeT $ do
        pub <- MaybeT $ queryS time GetPublisher p
        MaybeT $
            withSubscription pub $ \sub -> do
                MGetData gd `sendMessage` p
                r <- liftIO randomIO
                MPing (Ping r) `sendMessage` p
                join <$>
                    timeout
                        (time * 1000 * 1000)
                        (runMaybeT (get_thing sub r [] ivs))
  where
    get_thing _ _ acc [] = return $ reverse acc
    get_thing sub r acc hss@(InvVector t h:hs) =
        receive sub >>= \case
            MTx tx
                | is_tx t && getTxHash (txHash tx) == h ->
                    get_thing sub r (Left tx : acc) hs
            MBlock b@(Block bh _)
                | is_block t && getBlockHash (headerHash bh) == h ->
                    get_thing sub r (Right b : acc) hs
            MNotFound (NotFound nvs)
                | not (null (nvs `union` hs)) -> MaybeT $ return Nothing
            MPong (Pong r')
                | r == r' -> MaybeT $ return Nothing
            _
                | null acc -> get_thing sub r acc hss
                | otherwise -> MaybeT $ return Nothing
    is_tx InvWitnessTx = True
    is_tx InvTx        = True
    is_tx _            = False
    is_block InvWitnessBlock = True
    is_block InvBlock        = True
    is_block _               = False

-- | Ping a peer and await response. Return 'False' if response not received
-- before timeout.
peerPing :: MonadUnliftIO m => Int -> Peer -> m Bool
peerPing time p =
    fmap isJust . runMaybeT $ do
        pub <- MaybeT $ queryS time GetPublisher p
        MaybeT $
            withSubscription pub $ \sub -> do
                r <- liftIO randomIO
                MPing (Ping r) `sendMessage` p
                receiveMatchS time sub $ \case
                    MPong (Pong r')
                        | r == r' -> Just ()
                    _ -> Nothing

-- | Create version data structure.
buildVersion ::
       Network
    -> Word64
    -> BlockHeight
    -> NetworkAddress
    -> NetworkAddress
    -> Word64
    -> Version
buildVersion net nonce height loc rmt time =
    Version
        { version = myVersion
        , services = naServices loc
        , timestamp = time
        , addrRecv = rmt
        , addrSend = loc
        , verNonce = nonce
        , userAgent = VarString (getHaskoinUserAgent net)
        , startHeight = height
        , relay = True
        }

-- | Get a block header from 'Chain' process.
chainGetBlock :: MonadIO m => BlockHash -> Chain -> m (Maybe BlockNode)
chainGetBlock bh ch = ChainGetBlock bh `query` ch

-- | Get best block header from chain process.
chainGetBest :: MonadIO m => Chain -> m BlockNode
chainGetBest ch = ChainGetBest `query` ch

-- | Get ancestor of 'BlockNode' at 'BlockHeight' from chain process.
chainGetAncestor ::
       MonadIO m => BlockHeight -> BlockNode -> Chain -> m (Maybe BlockNode)
chainGetAncestor h n c = ChainGetAncestor h n `query` c

-- | Get parents of 'BlockNode' starting at 'BlockHeight' from chain process.
chainGetParents ::
       MonadIO m => BlockHeight -> BlockNode -> Chain -> m [BlockNode]
chainGetParents height top ch = go [] top
  where
    go acc b
        | height >= nodeHeight b = return acc
        | otherwise = do
            m <- chainGetBlock (prevBlock $ nodeHeader b) ch
            case m of
                Nothing -> return acc
                Just p  -> go (p : acc) p

-- | Get last common block from chain process.
chainGetSplitBlock ::
       MonadIO m => BlockNode -> BlockNode -> Chain -> m BlockNode
chainGetSplitBlock l r c = ChainGetSplit l r `query` c

-- | Notify chain that a new peer is connected.
chainPeerConnected :: MonadIO m => Peer -> SockAddr -> Chain -> m ()
chainPeerConnected p a ch = ChainPeerConnected p a `send` ch

-- | Notify chain that a peer has disconnected.
chainPeerDisconnected :: MonadIO m => Peer -> SockAddr -> Chain -> m ()
chainPeerDisconnected p a ch = ChainPeerDisconnected p a `send` ch

-- | Is given 'BlockHash' in the main chain?
chainBlockMain :: MonadIO m => BlockHash -> Chain -> m Bool
chainBlockMain bh ch =
    chainGetBest ch >>= \bb ->
        chainGetBlock bh ch >>= \case
            Nothing -> return False
            bm@(Just bn) -> (== bm) <$> chainGetAncestor (nodeHeight bn) bb ch

-- | Is chain in sync with network?
chainIsSynced :: MonadIO m => Chain -> m Bool
chainIsSynced ch = ChainIsSynced `query` ch

-- | Peer sends a bunch of headers to the chain process.
chainHeaders :: MonadIO m => Peer -> [BlockHeader] -> Chain -> m ()
chainHeaders p hs ch = ChainHeaders p hs `send` ch

-- | Connect to a socket via TCP.
withConnection ::
       MonadUnliftIO m => SockAddr -> (AppData -> m a) -> m a
withConnection na f =
    fromSockAddr na >>= \case
        Nothing -> throwIO PeerAddressInvalid
        Just (host, port) ->
            let cset = clientSettings port (cs host)
             in runGeneralTCPClient cset f

-- | Calculate the median value from a list. The list must not be empty.
median :: Fractional a => [a] -> Maybe a
median ls
    | null ls = Nothing
    | length ls `mod` 2 == 0 =
        Just . (/ 2) . sum . take 2 $ drop (length ls `div` 2 - 1) ls
    | otherwise = Just . head $ drop (length ls `div` 2) ls
