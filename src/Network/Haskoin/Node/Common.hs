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
    , onlinePeerPings     :: ![NominalDiffTime]
      -- ^ last few ping rountrip duration
    }

-- | Mailbox for a peer process.
type Peer = Inbox Message

-- | Mailbox for chain headers process.
type Chain = Inbox ChainMessage

-- | Mailbox for peer manager process.
type Manager = Inbox ManagerMessage

-- | Node configuration. Mailboxes for manager and chain processes must be
-- created before launching the node. The node will start those processes and
-- receive any messages sent to those mailboxes.
data NodeConfig = NodeConfig
    { nodeConfMaxPeers :: !Int
      -- ^ maximum number of connected peers allowed
    , nodeConfDB       :: !DB
      -- ^ RocksDB database handler
    , nodeConfPeers    :: ![HostPort]
      -- ^ static list of peers to connect to
    , nodeConfDiscover :: !Bool
      -- ^ activate peer discovery
    , nodeConfNetAddr  :: !NetworkAddress
      -- ^ network address for the local host
    , nodeConfNet      :: !Network
     -- ^ network constants
    , nodeConfChainPub :: !(Publisher ChainEvent)
      -- ^ publisher for chain header events
    , nodeConfPeerPub  :: !(Publisher (Peer, PeerEvent))
    }

-- | Peer manager configuration. Mailbox must be created before starting the
-- process.
data ManagerConfig = ManagerConfig
    { mgrConfMaxPeers :: !Int
      -- ^ maximum number of peers to connect to
    , mgrConfDB       :: !DB
      -- ^ RocksDB database handler to store peer information
    , mgrConfChain    :: !Chain
      -- ^ manager needs to be able to figure out local best block
    , mgrConfPeers    :: ![HostPort]
      -- ^ static list of peers to connect to
    , mgrConfDiscover :: !Bool
      -- ^ activate peer discovery
    , mgrConfNetAddr  :: !NetworkAddress
      -- ^ network address for the local host
    , mgrConfMailbox  :: !Manager
      -- ^ peer manager mailbox
    , mgrConfNetwork  :: !Network
      -- ^ network constants
    , mgrConfPub      :: !(Publisher (Peer, PeerEvent))
      -- ^ publisher for peer-related messages
    }

-- | Messages that can be sent to the peer manager.
data ManagerMessage
    = ConnectToPeers
      -- ^ try to connect to peers
    | ManagerKill !PeerException
                  !Peer
      -- ^ kill this peer with supplied exception
    | ManagerGetPeers !(Reply [OnlinePeer])
      -- ^ get all connected peers
    | ManagerGetOnlinePeer !Peer !(Reply (Maybe OnlinePeer))
      -- ^ get a peer information
    | PurgePeers
      -- ^ delete all known peers
    | PeerStopped !(Async ())
      -- ^ the peer corresponding to this async died
    | PeerRoundTrip !Peer !NominalDiffTime
      -- ^ roundtrip from a peer ping

-- | Configuration for the chain process.
data ChainConfig = ChainConfig
    { chainConfDB      :: !DB
      -- ^ RocksDB database handle
    , chainConfManager :: !Manager
      -- ^ peer manager mailbox
    , chainConfMailbox :: !Chain
      -- ^ chain process mailbox
    , chainConfNetwork :: !Network
      -- ^ network constants
    , chainConfPub     :: !(Publisher ChainEvent)
      -- ^ publisher for header chain events
    , chainConfPeerPub :: !(Publisher (Peer, PeerEvent))
      -- ^ publisher for peer events
    }

-- | Messages that can be sent to the chain process.
data ChainMessage
    = ChainGetBest !(Reply BlockNode)
      -- ^ get best block known
    | ChainGetAncestor !BlockHeight
                       !BlockNode
                       !(Reply (Maybe BlockNode))
      -- ^ get ancestor for 'BlockNode' at 'BlockHeight'
    | ChainGetSplit !BlockNode
                    !BlockNode
                    !(Reply BlockNode)
      -- ^ get highest common node
    | ChainGetBlock !BlockHash
                    !(Reply (Maybe BlockNode))
      -- ^ get a block header
    | ChainIsSynced !(Reply Bool)
      -- ^ is chain in sync with network?
    | ChainPing
      -- ^ internal for housekeeping within the chain process

-- | Events originating from chain process.
data ChainEvent
    = ChainBestBlock !BlockNode
      -- ^ chain has new best block
    | ChainSynced !BlockNode
      -- ^ chain is in sync with the network
    deriving (Eq, Show)

-- | Configuration for a particular peer.
data PeerConfig = PeerConfig
    { peerConfPub     :: !(Publisher (Peer, PeerEvent))
      -- ^ publisher for peer events
    , peerConfNetwork :: !Network
      -- ^ network constants
    , peerConfAddress :: !SockAddr
      -- ^ peer name
    , peerConfMailbox :: !Peer
      -- ^ mailbox for this peer
    }

-- | Reasons why a peer may stop working.
data PeerException
    = PeerMisbehaving !String
      -- ^ peer was a naughty boy
    | DuplicateVersion
      -- ^ peer sent another version message
    | DecodeMessageError !String
      -- ^ incoming message could not be decoded
    | CannotDecodePayload !String
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
    = PeerMessage !Message
    | PeerConnected
    | PeerDisconnected

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

-- | Get list of peers from manager.
managerGetPeers :: MonadIO m => Manager -> m [OnlinePeer]
managerGetPeers mgr = ManagerGetPeers `query` mgr

-- | Get peer information for a peer from manager.
managerGetPeer :: MonadIO m => Manager -> Peer -> m (Maybe OnlinePeer)
managerGetPeer mgr p = ManagerGetOnlinePeer p `query` mgr

-- | Ask manager to kill a peer with the provided exception.
managerKill :: MonadIO m => PeerException -> Peer -> Manager -> m ()
managerKill e p mgr = ManagerKill e p `send` mgr

-- | Send a network message to peer.
sendMessage :: MonadIO m => Message -> Peer -> m ()
sendMessage msg p = msg `send` p

-- | Upload bloom filter to remote peer.
peerSetFilter :: MonadIO m => BloomFilter -> Peer -> m ()
peerSetFilter f p = MFilterLoad (FilterLoad f) `sendMessage` p

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

-- | Connect via TCP.
withConnection ::
       MonadUnliftIO m => SockAddr -> (AppData -> m a) -> m a
withConnection na f =
    fromSockAddr na >>= \case
        Nothing -> throwIO PeerAddressInvalid
        Just (host, port) ->
            let cset = clientSettings port (cs host)
             in runGeneralTCPClient cset f
