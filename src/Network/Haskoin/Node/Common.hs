{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
module Network.Haskoin.Node.Common where

import           Control.Concurrent.NQE
import           Control.Concurrent.Unique
import           Data.ByteString             (ByteString)
import           Data.Hashable
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
import           Text.Read
import           UnliftIO

type HostPort = (Host, Port)
type Host = String
type Port = Int

data OnlinePeer = OnlinePeer
    { onlinePeerAddress     :: !SockAddr
    , onlinePeerConnected   :: !Bool
    , onlinePeerVersion     :: !Word32
    , onlinePeerServices    :: !Word64
    , onlinePeerRemoteNonce :: !Word64
    , onlinePeerUserAgent   :: !ByteString
    , onlinePeerRelay       :: !Bool
    , onlinePeerBestBlock   :: !BlockNode
    , onlinePeerAsync       :: !(Async ())
    , onlinePeerMailbox     :: !Peer
    , onlinePeerNonce       :: !Word64
    , onlinePeerPings       :: ![NominalDiffTime]
    }

data UniqueInbox a = UniqueInbox
    { uniqueInbox :: Inbox a
    , uniqueId    :: Unique
    }

type PeerSupervisor m = Inbox (SupervisorMessage m)
type NodeSupervisor m = Inbox (SupervisorMessage m)

type Peer = UniqueInbox PeerMessage
type Chain = Inbox ChainMessage
type Manager = Inbox ManagerMessage

instance Eq (UniqueInbox a) where
    UniqueInbox {uniqueId = a} == UniqueInbox {uniqueId = b} = a == b

instance Hashable (UniqueInbox a) where
    hashWithSalt n UniqueInbox {uniqueId = i} = hashWithSalt n i
    hash UniqueInbox {uniqueId = i} = hash i

instance Mailbox UniqueInbox where
    mailboxEmptySTM UniqueInbox {uniqueInbox = mbox} = mailboxEmptySTM mbox
    sendSTM msg UniqueInbox {uniqueInbox = mbox} = msg `sendSTM` mbox
    receiveSTM UniqueInbox {uniqueInbox = mbox} = receiveSTM mbox
    requeueMsg msg UniqueInbox {uniqueInbox = mbox} = msg `requeueMsg` mbox

data NodeConfig m = NodeConfig
    { maxPeers       :: !Int
    , database       :: !DB
    , initPeers      :: ![HostPort]
    , discover       :: !Bool
    , nodeEvents     :: !(Listen NodeEvent)
    , netAddress     :: !NetworkAddress
    , nodeSupervisor :: !(NodeSupervisor m)
    , nodeChain      :: !Chain
    , nodeManager    :: !Manager
    , nodeNet        :: !Network
    }

data ManagerConfig m = ManagerConfig
    { mgrConfMaxPeers       :: !Int
    , mgrConfDB             :: !DB
    , mgrConfPeers          :: ![HostPort]
    , mgrConfDiscover       :: !Bool
    , mgrConfMgrListener    :: !(Listen ManagerEvent)
    , mgrConfPeerListener   :: !(Listen (Peer, PeerEvent))
    , mgrConfNetAddr        :: !NetworkAddress
    , mgrConfManager        :: !Manager
    , mgrConfChain          :: !Chain
    , mgrConfPeerSupervisor :: !(PeerSupervisor m)
    , mgrConfNetwork        :: !Network
    }

data NodeEvent
    = ManagerEvent !ManagerEvent
    | ChainEvent !ChainEvent
    | PeerEvent !(Peer, PeerEvent)

data ManagerEvent
    = ManagerConnect !Peer
    | ManagerDisconnect !Peer

data ManagerMessage
    = ManagerSetFilter !BloomFilter
    | ManagerSetBest !BlockNode
    | ManagerPing
    | ManagerGetAddr !Peer
    | ManagerNewPeers !Peer
                      ![NetworkAddressTime]
    | ManagerKill !PeerException
                  !Peer
    | ManagerSetPeerBest !Peer
                         !BlockNode
    | ManagerGetPeerBest !Peer
                         !(Reply (Maybe BlockNode))
    | ManagerSetPeerVersion !Peer
                            !Version
    | ManagerGetPeerVersion !Peer
                            !(Reply (Maybe Word32))
    | ManagerGetPeers !(Reply [OnlinePeer])
    | ManagerGetOnlinePeer !Peer !(Reply (Maybe OnlinePeer))
    | ManagerPeerPing !Peer
                      !NominalDiffTime
    | PeerStopped !(Async (), Either SomeException ())

data ChainConfig = ChainConfig
    { chainConfDB       :: !DB
    , chainConfListener :: !(Listen ChainEvent)
    , chainConfManager  :: !Manager
    , chainConfChain    :: !Chain
    , chainConfNetwork  :: !Network
    }

data ChainMessage
    = ChainNewHeaders !Peer
                      ![BlockHeaderCount]
    | ChainNewPeer !Peer
    | ChainRemovePeer !Peer
    | ChainGetBest !(BlockNode -> STM ())
    | ChainGetAncestor !BlockHeight
                       !BlockNode
                       !(Reply (Maybe BlockNode))
    | ChainGetSplit !BlockNode
                    !BlockNode
                    !(Reply BlockNode)
    | ChainGetBlock !BlockHash
                    !(Reply (Maybe BlockNode))
    | ChainNewBlocks !Peer ![BlockHash]
    | ChainSendHeaders !Peer
    | ChainIsSynced !(Reply Bool)

data ChainEvent
    = ChainNewBest !BlockNode
    | ChainSynced !BlockNode
    | ChainNotSynced !BlockNode
    deriving (Eq, Show)

data PeerConfig = PeerConfig
    { peerConfConnect  :: !NetworkAddress
    , peerConfInitBest :: !BlockNode
    , peerConfLocal    :: !NetworkAddress
    , peerConfManager  :: !Manager
    , peerConfChain    :: !Chain
    , peerConfListener :: !(Listen (Peer, PeerEvent))
    , peerConfNonce    :: !Word64
    , peerConfNetwork  :: !Network
    }

data PeerException
    = PeerMisbehaving !String
    | DecodeMessageError !String
    | CannotDecodePayload !String
    | MessageHeaderEmpty
    | PeerIsMyself
    | PayloadTooLarge !Word32
    | PeerAddressInvalid
    | BloomFiltersNotSupported
    | PeerSentBadHeaders
    | NotNetworkPeer
    | PeerNoSegWit
    | PeerTimeout
    deriving (Eq, Show)

instance Exception PeerException

data PeerEvent
    = TxAvail ![TxHash]
    | GotBlock !Block
    | GotMerkleBlock !MerkleBlock
    | GotTx !Tx
    | GotPong !Word64
    | SendBlocks !GetBlocks
    | SendHeaders !GetHeaders
    | SendData ![InvVector]
    | TxNotFound !TxHash
    | BlockNotFound !BlockHash
    | WantMempool
    | Rejected !Reject

data PeerMessage
    = PeerOutgoing !Message
    | PeerIncoming !Message

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

computeTime :: MonadIO m => m Word32
computeTime = round <$> liftIO getPOSIXTime

myVersion :: Word32
myVersion = 70012

managerSetBest :: MonadIO m => BlockNode -> Manager -> m ()
managerSetBest bn mgr = ManagerSetBest bn `send` mgr

managerSetPeerVersion :: MonadIO m => Peer -> Version -> Manager -> m ()
managerSetPeerVersion p v mgr = ManagerSetPeerVersion p v `send` mgr

managerGetPeerVersion :: MonadIO m => Peer -> Manager -> m (Maybe Word32)
managerGetPeerVersion p mgr = ManagerGetPeerVersion p `query` mgr

managerGetPeerBest :: MonadIO m => Peer -> Manager -> m (Maybe BlockNode)
managerGetPeerBest p mgr = ManagerGetPeerBest p `query` mgr

managerSetPeerBest :: MonadIO m => Peer -> BlockNode -> Manager -> m ()
managerSetPeerBest p bn mgr = ManagerSetPeerBest p bn `send` mgr

managerGetPeers :: MonadIO m => Manager -> m [OnlinePeer]
managerGetPeers mgr = ManagerGetPeers `query` mgr

managerGetPeer :: MonadIO m => Manager -> Peer -> m (Maybe OnlinePeer)
managerGetPeer mgr p = ManagerGetOnlinePeer p `query` mgr

managerGetAddr :: MonadIO m => Peer -> Manager -> m ()
managerGetAddr p mgr = ManagerGetAddr p `send` mgr

managerKill :: MonadIO m => PeerException -> Peer -> Manager -> m ()
managerKill e p mgr = ManagerKill e p `send` mgr

managerNewPeers ::
       MonadIO m => Peer -> [NetworkAddressTime] -> Manager -> m ()
managerNewPeers p as mgr = ManagerNewPeers p as `send` mgr

setManagerFilter :: MonadIO m => BloomFilter -> Manager -> m ()
setManagerFilter bf mgr = ManagerSetFilter bf `send` mgr

sendMessage :: MonadIO m => Message -> Peer -> m ()
sendMessage msg p = PeerOutgoing msg `send` p

peerSetFilter :: MonadIO m => BloomFilter -> Peer -> m ()
peerSetFilter f p = MFilterLoad (FilterLoad f) `sendMessage` p

getMerkleBlocks ::
       (MonadIO m)
    => Peer
    -> [BlockHash]
    -> m ()
getMerkleBlocks p bhs = PeerOutgoing (MGetData (GetData ivs)) `send` p
  where
    ivs = map (InvVector InvMerkleBlock . getBlockHash) bhs

peerGetBlocks ::
       MonadIO m => Network -> Peer -> [BlockHash] -> m ()
peerGetBlocks net p bhs = PeerOutgoing (MGetData (GetData ivs)) `send` p
  where
    con
        | getSegWit net = InvWitnessBlock
        | otherwise = InvBlock
    ivs = map (InvVector con . getBlockHash) bhs

peerGetTxs :: MonadIO m => Network -> Peer -> [TxHash] -> m ()
peerGetTxs net p ths = PeerOutgoing (MGetData (GetData ivs)) `send` p
  where
    con
        | getSegWit net = InvWitnessTx
        | otherwise = InvTx
    ivs = map (InvVector con . getTxHash) ths

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

chainNewPeer :: MonadIO m => Peer -> Chain -> m ()
chainNewPeer p ch = ChainNewPeer p `send` ch

chainRemovePeer :: MonadIO m => Peer -> Chain -> m ()
chainRemovePeer p ch = ChainRemovePeer p `send` ch

chainGetBlock :: MonadIO m => BlockHash -> Chain -> m (Maybe BlockNode)
chainGetBlock bh ch = ChainGetBlock bh `query` ch

chainGetBest :: MonadIO m => Chain -> m BlockNode
chainGetBest ch = ChainGetBest `query` ch

chainGetAncestor ::
       MonadIO m => BlockHeight -> BlockNode -> Chain -> m (Maybe BlockNode)
chainGetAncestor h n c = ChainGetAncestor h n `query` c

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

chainGetSplitBlock ::
       MonadIO m => BlockNode -> BlockNode -> Chain -> m BlockNode
chainGetSplitBlock l r c = ChainGetSplit l r `query` c

chainBlockMain :: MonadIO m => BlockHash -> Chain -> m Bool
chainBlockMain bh ch =
    chainGetBest ch >>= \bb ->
        chainGetBlock bh ch >>= \case
            Nothing -> return False
            bm@(Just bn) -> (== bm) <$> chainGetAncestor (nodeHeight bn) bb ch

chainIsSynced :: MonadIO m => Chain -> m Bool
chainIsSynced ch = ChainIsSynced `query` ch
