{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
module Network.Haskoin.Node.Common where

import           Conduit
import           Data.Conduit.Network
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
import           Text.Read
import           UnliftIO

type HostPort = (Host, Port)
type Host = String
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
    , onlinePeerPingTime  :: !(Maybe UTCTime)
      -- ^ last ping time
    , onlinePeerPingNonce :: !(Maybe Word64)
      -- ^ last ping nonce
    , onlinePeerPings     :: ![NominalDiffTime]
      -- ^ last few ping rountrip duration
    }

-- | Peer process.
type Peer = Mailbox Message

-- | Mailbox for chain headers process.
type Chain = Mailbox ChainMessage

-- | Mailbox for peer manager process.
type Manager = Mailbox ManagerMessage

-- | Node configuration. Mailboxes for manager and chain processes must be
-- created before launching the node. The node will start those processes and
-- receive any messages sent to those mailboxes.
--
-- Node events generated include:
-- @
-- 'ChainEvent'
-- ('Peer', 'PeerEvent')
-- ('Peer', 'Message')
-- @
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
    , nodeConfEvents   :: !(Listen NodeEvent)
      -- ^ node events sent here
    }

-- | Peer manager configuration. Mailbox must be created before starting the
-- process.
data ManagerConfig = ManagerConfig
    { mgrConfMaxPeers :: !Int
      -- ^ maximum number of peers to connect to
    , mgrConfDB       :: !DB
      -- ^ RocksDB database handler to store peer information
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
    }

-- | Messages that can be sent to the peer manager.
data ManagerMessage
    = ManagerConnect
      -- ^ try to connect to peers
    | ManagerKill !PeerException
                  !Peer
      -- ^ kill this peer with supplied exception
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

-- | Configuration for the chain process.
data ChainConfig = ChainConfig
    { chainConfDB      :: !DB
      -- ^ RocksDB database handle
    , chainConfManager :: !Manager
      -- ^ peer manager mailbox
    , chainConfNetwork :: !Network
      -- ^ network constants
    , chainConfEvents  :: !(Listen ChainEvent)
      -- ^ send header chain events here
    }

-- | Messages that can be sent to the chain process.
data ChainMessage
    = ChainGetBest !(Listen BlockNode)
      -- ^ get best block known
    | ChainHeaders !Peer ![BlockHeader]
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
      -- ^ internal for housekeeping within the chain process
    | ChainPeerConnected !Peer
      -- ^ internal to notify that a peer has connected
    | ChainPeerDisconnected !Peer
      -- ^ internal to notify that a peer has disconnected

-- | Events originating from chain process.
data ChainEvent
    = ChainBestBlock !BlockNode
      -- ^ chain has new best block
    | ChainSynced !BlockNode
      -- ^ chain is in sync with the network
    deriving (Eq, Show)

data NodeEvent
    = ChainEvent !ChainEvent
    | PeerEvent !PeerEvent
    deriving Eq

-- | Configuration for a particular peer.
data PeerConfig = PeerConfig
    { peerConfListen  :: !(Listen (Peer, Message))
      -- ^ mailbox interested in peer events
    , peerConfNetwork :: !Network
      -- ^ network constants
    , peerConfAddress :: !SockAddr
      -- ^ peer name
    }

-- | Reasons why a peer may stop working.
data PeerException
    = PeerMisbehaving !String
      -- ^ peer was a naughty boy
    | DuplicateVersion
      -- ^ peer sent another version message
    | DecodeHeaderError
      -- ^ incoming message could not be decoded
    | CannotDecodePayload
      -- ^ incoming message payload could not be decoded
    | PeerIsMyself
      -- ^ nonce for peer matches ours
    | PayloadTooLarge !Word32
      -- ^ message payload too large
    | PeerAddressInvalid
      -- ^ peer address not valid
    | BloomFiltersNotSupported
      -- ^ peer does not support bloom filters
    | PeerSentBadHeaders
      -- ^ peer sent wrong headers
    | NotNetworkPeer
      -- ^ peer cannot serve blockchain data
    | PeerNoSegWit
      -- ^ peer has no segwit support
    | PeerTimeout
      -- ^ request to peer timed out
    | PurgingPeer
      -- ^ peers are being purged
    deriving (Eq, Show)

instance Exception PeerException

-- | Events concerning a peer.
data PeerEvent
    = PeerConnected !Peer
    | PeerDisconnected !Peer
    | PeerMessage !Peer
                  !Message
    deriving Eq

-- | Convert a host and port into a list of matching 'SockAddr'.
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

-- | Convert a 'SockAddr' into a host and port.
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
computeTime :: MonadIO m => m Word32
computeTime = round <$> liftIO getPOSIXTime

-- | Our protocol version.
myVersion :: Word32
myVersion = 70012

managerPeerMessage :: MonadIO m => Peer -> Message -> Manager -> m ()
managerPeerMessage p msg mgr = ManagerPeerMessage p msg `send` mgr

-- | Get list of peers from manager.
managerGetPeers ::
       MonadIO m => Manager -> m [OnlinePeer]
managerGetPeers mgr = ManagerGetPeers `query` mgr

-- | Get peer information for a peer from manager.
managerGetPeer :: MonadIO m => Peer -> Manager -> m (Maybe OnlinePeer)
managerGetPeer p mgr = ManagerGetOnlinePeer p `query` mgr

-- | Ask manager to kill a peer with the provided exception.
managerKill :: MonadIO m => PeerException -> Peer -> Manager -> m ()
managerKill e p mgr = ManagerKill e p `send` mgr

-- | Internal function used by manager to check peers periodically.
managerCheck :: MonadIO m => Peer -> Manager -> m ()
managerCheck p mgr = ManagerCheckPeer p `send` mgr

-- | Internal function used to request manager to connect to new peers.
managerConnect :: MonadIO m => Manager ->  m ()
managerConnect mgr = ManagerConnect `send` mgr

-- | Set the best block that the manager knows about.
managerSetBest :: MonadIO m => BlockHeight -> Manager -> m ()
managerSetBest bh mgr = ManagerBestBlock bh `send` mgr

-- | Send a network message to peer.
sendMessage :: MonadIO m => Message -> Peer -> m ()
sendMessage msg p = msg `send` p

-- | Request Merkle blocks from peer.
getMerkleBlocks ::
       (MonadIO m)
    => Peer
    -> [BlockHash]
    -> m ()
getMerkleBlocks p bhs = MGetData (GetData ivs) `send` p
  where
    ivs = map (InvVector InvMerkleBlock . getBlockHash) bhs

-- | Request full blocks from peer.
peerGetBlocks ::
       MonadIO m => Network -> Peer -> [BlockHash] -> m ()
peerGetBlocks net p bhs = MGetData (GetData ivs) `send` p
  where
    con
        | getSegWit net = InvWitnessBlock
        | otherwise = InvBlock
    ivs = map (InvVector con . getBlockHash) bhs

-- | Request transactions from peer.
peerGetTxs :: MonadIO m => Network -> Peer -> [TxHash] -> m ()
peerGetTxs net p ths = MGetData (GetData ivs) `send` p
  where
    con
        | getSegWit net = InvWitnessTx
        | otherwise = InvTx
    ivs = map (InvVector con . getTxHash) ths

-- | Build my version structure.
buildVersion ::
       MonadIO m
    => Network
    -> Word64
    -> BlockHeight
    -> NetworkAddress
    -> NetworkAddress
    -> m Version
buildVersion net nonce height loc rmt = do
    time <- fromIntegral <$> computeTime
    return
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

-- | Get a block header from chain process.
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
chainPeerConnected :: MonadIO m => Peer -> Chain -> m ()
chainPeerConnected p ch = ChainPeerConnected p `send` ch

-- | Notify chain that a peer has disconnected.
chainPeerDisconnected :: MonadIO m => Peer -> Chain -> m ()
chainPeerDisconnected p ch = ChainPeerDisconnected p `send` ch

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

chainHeaders :: MonadIO m => Peer -> [BlockHeader] -> Chain -> m ()
chainHeaders p hs ch = ChainHeaders p hs `send` ch

-- | Connect via TCP.
withConnection ::
       MonadUnliftIO m => SockAddr -> (AppData -> m a) -> m a
withConnection na f =
    fromSockAddr na >>= \case
        Nothing -> throwIO PeerAddressInvalid
        Just (host, port) ->
            let cset = clientSettings port (cs host)
             in runGeneralTCPClient cset f
