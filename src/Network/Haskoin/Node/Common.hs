{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
module Network.Haskoin.Node.Common where

import           Conduit
import           Data.ByteString             (ByteString)
import           Data.Conduit.Network
import           Data.String.Conversions
import           Data.Text                   (Text)
import           Data.Time.Clock
import           Data.Time.Clock.POSIX
import           Data.Word
import           Database.RocksDB            (DB)
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Network
import           Network.Haskoin.Transaction
import           Network.Socket              (AddrInfo (..), AddrInfoFlag (..),
                                              Family (..), NameInfoFlag (..),
                                              SockAddr (..), SocketType (..),
                                              addrAddress, defaultHints,
                                              getAddrInfo, getNameInfo)
import           NQE
import           Text.Read
import           UnliftIO

type HostPort = (Host, Port)
type Host = String
type Port = Int

-- | Data structure representing an online peer.
data OnlinePeer = OnlinePeer
    { onlinePeerAddress     :: !SockAddr
      -- ^ network address
    , onlinePeerConnected   :: !Bool
      -- ^ has it finished handshake
    , onlinePeerVersion     :: !Word32
      -- ^ protocol version
    , onlinePeerServices    :: !Word64
      -- ^ services field
    , onlinePeerRemoteNonce :: !Word64
      -- ^ random nonce sent by peer
    , onlinePeerUserAgent   :: !ByteString
      -- ^ user agent string
    , onlinePeerRelay       :: !Bool
      -- ^ peer will relay transactions (BIP-37)
    , onlinePeerAsync       :: !(Async ())
      -- ^ peer asynchronous process
    , onlinePeerMailbox     :: !Peer
      -- ^ peer mailbox
    , onlinePeerNonce       :: !Word64
      -- ^ random nonce sent during handshake
    , onlinePeerPings       :: ![NominalDiffTime]
      -- ^ last few ping rountrip duration
    }

-- | Mailbox for a peer process.
type Peer = Inbox PeerMessage

-- | Mailbox for chain headers process.
type Chain = Inbox ChainMessage

-- | Mailbox for peer manager process.
type Manager = Inbox ManagerMessage

-- | Node configuration. Mailboxes for manager and chain processes must be
-- created before launching the node. The node will start those processes and
-- receive any messages sent to those mailboxes.
data NodeConfig = NodeConfig
    { maxPeers            :: !Int
      -- ^ maximum number of connected peers allowed
    , database            :: !DB
      -- ^ RocksDB database handler
    , initPeers           :: ![HostPort]
      -- ^ static list of peers to connect to
    , discover            :: !Bool
      -- ^ activate peer discovery
    , nodeEvents          :: !(Listen NodeEvent)
      -- ^ listener for events originated by the node
    , netAddress          :: !NetworkAddress
      -- ^ network address for the local host
    , nodeNet             :: !Network
      -- ^ network constants
    , nodeConnectInterval :: !Int
      -- ^ approximately how often to try to connect to peers in seconds
    , nodeStale           :: !Word32
      -- ^ how much to wait for results from a peer in seconds
    }

-- | Peer manager configuration. Mailbox must be created before starting the
-- process.
data ManagerConfig = ManagerConfig
    { mgrConfMaxPeers        :: !Int
      -- ^ maximum number of peers to connect to
    , mgrConfDB              :: !DB
      -- ^ RocksDB database handler to store peer information
    , mgrConfPeers           :: ![HostPort]
      -- ^ static list of peers to connect to
    , mgrConfDiscover        :: !Bool
      -- ^ activate peer discovery
    , mgrConfMgrListener     :: !(Listen ManagerEvent)
      -- ^ listener for events originating from peer manager
    , mgrConfPeerListener    :: !(Listen (Peer, PeerEvent))
      -- ^ listener for events originating from individual peers
    , mgrConfNetAddr         :: !NetworkAddress
      -- ^ network address for the local host
    , mgrConfManager         :: !Manager
      -- ^ peer manager mailbox
    , mgrConfChain           :: !Chain
      -- ^ chain process mailbox
    , mgrConfNetwork         :: !Network
      -- ^ network constants
    , mgrConfConnectInterval :: !Int
      -- ^ approximately how often to try to connect to peers in seconds
    , mgrConfStale           :: !Word32
      -- ^ how much to wait for results from a peer in seconds
    }

-- | Event originating from the node. Aggregates events from the peer manager,
-- chain, and any connected peers.
data NodeEvent
    = ManagerEvent !ManagerEvent
      -- ^ event originating from peer manager
    | ChainEvent !ChainEvent
      -- ^ event originating from chain process
    | PeerEvent !(Peer, PeerEvent)
      -- ^ event originating from a peer

-- | Peer manager event.
data ManagerEvent
    = ManagerConnect !Peer
      -- ^ a new peer connected and its handshake completed
    | ManagerDisconnect !Peer
      -- ^ a peer disconnected

-- | Messages that can be sent to the peer manager.
data ManagerMessage
    = ManagerSetFilter !BloomFilter
      -- ^ set a bloom filter in all peers
    | ManagerSetBest !BlockNode
      -- ^ set our best block
    | ManagerPing
      -- ^ internal timer signal that triggers housekeeping tasks
    | ManagerGetAddr !Peer
      -- ^ peer requests all peers we know about
    | ManagerNewPeers !Peer
                      ![NetworkAddressTime]
      -- ^ peer sent list of peers it knows about
    | ManagerKill !PeerException
                  !Peer
      -- ^ please kill this peer with supplied exception
    | ManagerSetPeerVersion !Peer
                            !Version
      -- ^ set version for this peer
    | ManagerGetPeerVersion !Peer
                            !(Reply (Maybe Word32))
      -- ^ get protocol version for this peer
    | ManagerGetPeers !(Reply [OnlinePeer])
      -- ^ get all connected peers
    | ManagerGetOnlinePeer !Peer !(Reply (Maybe OnlinePeer))
      -- ^ get a peer information
    | ManagerPeerPing !Peer
                      !NominalDiffTime
      -- ^ add a peer roundtrip time for this peer
    | PeerStopped !(Async (), Either SomeException ())
      -- ^ peer corresponding to 'Async' has stopped

-- | Configuration for the chain process.
data ChainConfig = ChainConfig
    { chainConfDB       :: !DB
      -- ^ RocksDB database handle
    , chainConfListener :: !(Listen ChainEvent)
      -- ^ listener for events originating from the chain process
    , chainConfManager  :: !Manager
      -- ^ peer manager mailbox
    , chainConfChain    :: !Chain
      -- ^ chain process mailbox
    , chainConfNetwork  :: !Network
      -- ^ network constants
    }

-- | Messages that can be sent to the chain process.
data ChainMessage
    = ChainNewHeaders !Peer
                      ![BlockHeaderCount]
      -- ^ peer sent some block headers
    | ChainNewPeer !Peer
      -- ^ a new peer connected
    | ChainRemovePeer !Peer
      -- ^ a peer disconnected
    | ChainGetBest !(Reply BlockNode)
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
    | ChainNewBlocks !Peer ![BlockHash]
      -- ^ peer sent block inventory
    | ChainSendHeaders !Peer
      -- ^ peer asks for our block headers in the future
    | ChainIsSynced !(Reply Bool)
      -- ^ is chain in sync with network?
    | ChainPing
      -- ^ internal for housekeeping within the chain process

-- | Events originating from chain process.
data ChainEvent
    = ChainNewBest !BlockNode
      -- ^ chain has new best block
    | ChainSynced !BlockNode
      -- ^ chain is in sync with the network
    deriving (Eq, Show)

-- | Configuration for a particular peer.
data PeerConfig = PeerConfig
    { peerConfManager  :: !Manager
      -- ^ peer manager mailbox
    , peerConfChain    :: !Chain
      -- ^ chain process mailbox
    , peerConfListener :: !(Listen (Peer, PeerEvent))
      -- ^ listener for peer events
    , peerConfNetwork  :: !Network
      -- ^ network constants
    , peerConfName     :: !Text
      -- ^ peer name
    , peerConfConnect  :: !((NetConduits IO -> IO ()) -> IO ())
      -- ^ peer connection
    , peerConfVersion  :: !Version
      -- ^ peer version
    , peerConfStale    :: !Word32
      -- ^ how long to wait for a peer to respond to requests in seconds
    , peerConfMailbox  :: !Peer
      -- ^ mailbox for this peer
    }

-- | Reasons why a peer may stop working.
data PeerException
    = PeerMisbehaving !String
      -- ^ peer was a naughty boy
    | DecodeMessageError !String
      -- ^ incoming message could not be decoded
    | CannotDecodePayload !String
      -- ^ incoming message payload could not be decoded
    | PeerIsMyself
      -- ^ nonce for peer matches ours
    | PayloadTooLarge !Word32
      -- ^ message payload too large
    | PeerAddressInvalid
      -- ^ peer address did not parse with 'fromSockAddr'
    | BloomFiltersNotSupported
      -- ^ peer does not support bloom filters
    | PeerSentBadHeaders
      -- ^ peer sent wrong headers
    | NotNetworkPeer
      -- ^ peer is SPV and cannot serve blockchain data
    | PeerNoSegWit
      -- ^ peer has no segwit support
    | PeerTimeout
      -- ^ request to peer timed out
    deriving (Eq, Show)

instance Exception PeerException

-- | Events originating from a peer.
data PeerEvent
    = TxAvail ![TxHash]
      -- ^ peer sent transaction inventory
    | GotBlock !Block
      -- ^ peer sent a 'Block'
    | GotMerkleBlock !MerkleBlock
      -- ^ peer sent a 'MerkleBlock'
    | GotTx !Tx
      -- ^ peer sent a 'Tx'
    | GotPong !Word64
      -- ^ peer responded to a 'Ping'
    | SendBlocks !GetBlocks
      -- ^ peer is requesting some blocks
    | SendHeaders !GetHeaders
      -- ^ peer is requesting some headers
    | SendData ![InvVector]
      -- ^ per is requesting an inventory
    | TxNotFound !TxHash
      -- ^ peer could not find transaction
    | BlockNotFound !BlockHash
      -- ^ peer could not find block
    | WantMempool
      -- ^ peer wants our mempool
    | Rejected !Reject
      -- ^ peer rejected something we sent

-- | Internal type for peer messages.
data PeerMessage
    = PeerOutgoing !Message
    | PeerIncoming !Message

data NetConduits m = NetConduits
  { getNetSource :: ConduitT () ByteString m ()
  , getNetSink   :: ConduitT ByteString Void m ()
  }

-- | Convert a host and port into a list of matching 'SockAddr'.
toSockAddr :: (MonadUnliftIO m) => HostPort -> m [SockAddr]
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
        (hostM, portM) <- liftIO (getNameInfo flags True True sa)
        return $ (,) <$> hostM <*> (readMaybe =<< portM)
    flags = [NI_NUMERICHOST, NI_NUMERICSERV]
    e :: Monad m => SomeException -> m (Maybe a)
    e _ = return Nothing

-- | Integer current time in seconds from 1970-01-01T00:00Z.
computeTime :: MonadIO m => m Word32
computeTime = round <$> liftIO getPOSIXTime

-- | Our protocol version.
myVersion :: Word32
myVersion = 70012

-- | Set best block in the manager.
managerSetBest :: MonadIO m => BlockNode -> Manager -> m ()
managerSetBest bn mgr = ManagerSetBest bn `send` mgr

-- | Set version of peer in manager.
managerSetPeerVersion :: MonadIO m => Peer -> Version -> Manager -> m ()
managerSetPeerVersion p v mgr = ManagerSetPeerVersion p v `send` mgr

-- | Get version of peer from manager.
managerGetPeerVersion :: MonadIO m => Peer -> Manager -> m (Maybe Word32)
managerGetPeerVersion p mgr = ManagerGetPeerVersion p `query` mgr

-- | Get list of peers from manager.
managerGetPeers :: MonadIO m => Manager -> m [OnlinePeer]
managerGetPeers mgr = ManagerGetPeers `query` mgr

-- | Get peer information for a peer from manager.
managerGetPeer :: MonadIO m => Manager -> Peer -> m (Maybe OnlinePeer)
managerGetPeer mgr p = ManagerGetOnlinePeer p `query` mgr

-- | Ask manager to send all known peers to a peer.
managerGetAddr :: MonadIO m => Peer -> Manager -> m ()
managerGetAddr p mgr = ManagerGetAddr p `send` mgr

-- | Ask manager to kill a peer with the provided exception.
managerKill :: MonadIO m => PeerException -> Peer -> Manager -> m ()
managerKill e p mgr = ManagerKill e p `send` mgr

-- | Peer sends manager list of known peers.
managerNewPeers ::
       MonadIO m => Peer -> [NetworkAddressTime] -> Manager -> m ()
managerNewPeers p as mgr = ManagerNewPeers p as `send` mgr

-- | Set bloom filters in peer manager.
setManagerFilter :: MonadIO m => BloomFilter -> Manager -> m ()
setManagerFilter bf mgr = ManagerSetFilter bf `send` mgr

-- | Send a network message to peer.
sendMessage :: MonadIO m => Message -> Peer -> m ()
sendMessage msg p = PeerOutgoing msg `send` p

-- | Upload bloom filter to remote peer.
peerSetFilter :: MonadIO m => BloomFilter -> Peer -> m ()
peerSetFilter f p = MFilterLoad (FilterLoad f) `sendMessage` p

-- | Request Merkle blocks from peer.
getMerkleBlocks ::
       (MonadIO m)
    => Peer
    -> [BlockHash]
    -> m ()
getMerkleBlocks p bhs = PeerOutgoing (MGetData (GetData ivs)) `send` p
  where
    ivs = map (InvVector InvMerkleBlock . getBlockHash) bhs

-- | Request full blocks from peer.
peerGetBlocks ::
       MonadIO m => Network -> Peer -> [BlockHash] -> m ()
peerGetBlocks net p bhs = PeerOutgoing (MGetData (GetData ivs)) `send` p
  where
    con
        | getSegWit net = InvWitnessBlock
        | otherwise = InvBlock
    ivs = map (InvVector con . getBlockHash) bhs

-- | Request transactions from peer.
peerGetTxs :: MonadIO m => Network -> Peer -> [TxHash] -> m ()
peerGetTxs net p ths = PeerOutgoing (MGetData (GetData ivs)) `send` p
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

-- | Notify chain of a new peer that connected.
chainNewPeer :: MonadIO m => Peer -> Chain -> m ()
chainNewPeer p ch = ChainNewPeer p `send` ch

-- | Notify chain that a peer has disconnected.
chainRemovePeer :: MonadIO m => Peer -> Chain -> m ()
chainRemovePeer p ch = ChainRemovePeer p `send` ch

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

-- | Connect to the network
withConnection :: (MonadUnliftIO m) => SockAddr -> (NetConduits m -> m a) -> m a
withConnection na f =
    fromSockAddr na >>= \case
        Nothing ->
            throwIO PeerAddressInvalid
        Just (host, port) ->
            let cset = clientSettings port (cs host)
            in runGeneralTCPClient cset $ \ad ->
              let nc = NetConduits (appSource ad) (appSink ad)
              in f nc
