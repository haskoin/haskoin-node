{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeFamilies          #-}
module Network.Haskoin.Node.Peer
( peer
) where

import           Control.Concurrent.NQE
import           Control.Monad
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Data.Bits
import           Data.ByteString             (ByteString)
import qualified Data.ByteString             as BS
import qualified Data.ByteString.Char8       as C8
import qualified Data.ByteString.Lazy        as BL
import           Data.Conduit
import qualified Data.Conduit.Binary         as CB
import           Data.Conduit.Network
import           Data.Maybe
import           Data.Serialize
import           Data.String
import           Data.String.Conversions
import           Data.Time.Clock
import           Data.Word
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Network
import           Network.Haskoin.Node.Common
import           Network.Haskoin.Transaction
import           Network.Socket              (SockAddr)
import           System.Random
import           UnliftIO

type MonadPeer m = (MonadUnliftIO m, MonadLoggerIO m, MonadReader PeerReader m)

data Pending
    = PendingTx !TxHash
    | PendingBlock !BlockHash
    | PendingMerkle !BlockHash
    | PendingHeaders
    deriving (Show, Eq)

data PeerReader = PeerReader
    { mySelf     :: !Peer
    , myConfig   :: !PeerConfig
    , mySockAddr :: !SockAddr
    , myHostPort :: !(Host, Port)
    , myPending  :: !(TVar [(Pending, Word32)])
    }

time :: Int
time = 15 * 1000 * 1000

logMsg :: IsString a => Message -> a
logMsg = fromString . cs . commandToString . msgType

logPeer ::
       (ConvertibleStrings String a, Semigroup a, IsString a) => SockAddr -> a
logPeer sa = "[Peer " <> cs (show sa) <> "] "

peer :: (MonadUnliftIO m, MonadLoggerIO m) => PeerConfig -> Peer -> m ()
peer pc p =
    fromSockAddr na >>= \case
        Nothing -> do
            $(logError) $ logPeer na <> "Invalid network address"
            throwIO PeerAddressInvalid
        Just (host, port) -> do
            let cset = clientSettings port (C8.pack host)
            runGeneralTCPClient cset (peerSession (host, port))
  where
    na = naAddress (peerConfConnect pc)
    go = handshake >> exchangePing >> peerLoop
    net = peerConfNetwork pc
    peerSession hp ad = do
        let src = appSource ad .| inPeerConduit net
            snk = outPeerConduit net .| appSink ad
        withSource src p . const $ do
            pbox <- newTVarIO []
            let rd =
                    PeerReader
                    { myConfig = pc
                    , mySelf = p
                    , myHostPort = hp
                    , mySockAddr = na
                    , myPending = pbox
                    }
            runReaderT (runConduit (go .| snk)) rd

handshake :: MonadPeer m => ConduitT () Message m ()
handshake = do
    p <- asks mySelf
    ch <- peerConfChain <$> asks myConfig
    rmt <- peerConfConnect <$> asks myConfig
    loc <- peerConfLocal <$> asks myConfig
    net <- peerConfNetwork <$> asks myConfig
    nonce <- peerConfNonce <$> asks myConfig
    bb <- chainGetBest ch
    ver <- buildVersion net nonce (nodeHeight bb) loc rmt
    yield $ MVersion ver
    lift (remoteVer p) >>= \case
        v
            | testSegWit net v -> do
                yield MVerAck
                lift (remoteVerAck p)
                mgr <- peerConfManager <$> asks myConfig
                managerSetPeerVersion p v mgr
            | otherwise -> do
                yield . MReject $
                    reject MCVersion RejectObsolete "No SegWit support"
                throwIO PeerNoSegWit
  where
    testSegWit net v
        | getSegWit net = services v `testBit` 3
        | otherwise = True
    remoteVer p = do
        m <-
            timeout time . receiveMatch p $ \case
                PeerIncoming (MVersion v) -> Just v
                _ -> Nothing
        case m of
            Just v  -> return v
            Nothing -> throwIO PeerTimeout
    remoteVerAck p = do
        m <-
            timeout time . receiveMatch p $ \case
                PeerIncoming MVerAck -> Just ()
                _ -> Nothing
        when (isNothing m) $ throwIO PeerTimeout

peerLoop :: MonadPeer m => ConduitT () Message m ()
peerLoop =
    forever $ do
        me <- asks mySelf
        m <- lift $ timeout (2 * 60 * 1000 * 1000) (receive me)
        case m of
            Nothing  -> exchangePing
            Just msg -> processMessage msg

exchangePing :: MonadPeer m => ConduitT () Message m ()
exchangePing = do
    lp <- logMe
    i <- liftIO randomIO
    yield $ MPing (Ping i)
    me <- asks mySelf
    mgr <- peerConfManager <$> asks myConfig
    t1 <- liftIO getCurrentTime
    m <-
        lift . timeout time . receiveMatch me $ \case
            PeerIncoming (MPong (Pong j))
                | i == j -> Just ()
            _ -> Nothing
    case m of
        Nothing -> do
            $(logError) $ lp <> "Timeout while waiting for pong"
            throwIO PeerTimeout
        Just () -> do
            t2 <- liftIO getCurrentTime
            let d = t2 `diffUTCTime` t1
            $(logDebug) $
                lp <> "Roundtrip: " <> cs (show (d * 1000)) <> " ms"
            ManagerPeerPing me d `send` mgr

checkStale :: MonadPeer m => ConduitM () Message m ()
checkStale = do
    pbox <- asks myPending
    ps <- readTVarIO pbox
    case ps of
        [] -> return ()
        (_, ts):_ -> do
            cur <- computeTime
            when (cur > ts + 30) $ throwIO PeerTimeout

registerOutgoing :: MonadPeer m => Message -> m ()
registerOutgoing (MGetData (GetData ivs)) = do
    pbox <- asks myPending
    cur <- computeTime
    ms <-
        fmap catMaybes . forM ivs $ \iv ->
            case toPending iv of
                Nothing -> return Nothing
                Just p  -> return $ Just (p, cur)
    atomically (modifyTVar pbox (++ ms))
  where
    toPending InvVector {invType = InvTx, invHash = hash} =
        Just (PendingTx (TxHash hash))
    toPending InvVector {invType = InvWitnessTx, invHash = hash} =
        Just (PendingTx (TxHash hash))
    toPending InvVector {invType = InvBlock, invHash = hash} =
        Just (PendingBlock (BlockHash hash))
    toPending InvVector {invType = InvWitnessBlock, invHash = hash} =
        Just (PendingBlock (BlockHash hash))
    toPending InvVector {invType = InvMerkleBlock, invHash = hash} =
        Just (PendingMerkle (BlockHash hash))
    toPending InvVector {invType = InvWitnessMerkleBlock, invHash = hash} =
        Just (PendingMerkle (BlockHash hash))
    toPending _ = Nothing
registerOutgoing MGetHeaders {} = do
    pbox <- asks myPending
    cur <- computeTime
    atomically (modifyTVar pbox (reverse . ((PendingHeaders, cur) :) . reverse))
registerOutgoing _ = return ()

registerIncoming :: MonadPeer m => Message -> m ()
registerIncoming (MNotFound (NotFound ivs)) =
    asks myPending >>= \pbox ->
        atomically (modifyTVar pbox (filter (matchNotFound . fst)))
  where
    matchNotFound (PendingTx (TxHash hash)) =
        InvVector InvTx hash `notElem` ivs &&
        InvVector InvWitnessTx hash `notElem` ivs
    matchNotFound (PendingBlock (BlockHash hash)) =
        InvVector InvBlock hash `notElem` ivs &&
        InvVector InvWitnessBlock hash `notElem` ivs
    matchNotFound (PendingMerkle (BlockHash hash)) =
        InvVector InvBlock hash `notElem` ivs &&
        InvVector InvMerkleBlock hash `notElem` ivs &&
        InvVector InvWitnessMerkleBlock hash `notElem` ivs
    matchNotFound _ = False
registerIncoming (MTx t) =
    asks myPending >>= \pbox ->
        atomically (modifyTVar pbox (filter ((/= PendingTx (txHash t)) . fst)))
registerIncoming (MBlock b) =
    asks myPending >>= \pbox ->
        atomically $
        modifyTVar
            pbox
            (filter ((/= PendingBlock (headerHash (blockHeader b))) . fst))
registerIncoming (MMerkleBlock b) =
    asks myPending >>= \pbox ->
        atomically $
        modifyTVar
            pbox
            (filter ((/= PendingMerkle (headerHash (merkleHeader b))) . fst))
registerIncoming MHeaders {} =
    asks myPending >>= \pbox ->
        atomically $ modifyTVar pbox (filter ((/= PendingHeaders) . fst))
registerIncoming _ = return ()

processMessage :: MonadPeer m => PeerMessage -> ConduitM () Message m ()
processMessage m = do
    checkStale
    case m of
        PeerOutgoing msg -> do
            lift (registerOutgoing msg)
            yield msg
        PeerIncoming msg -> do
            lift (registerIncoming msg)
            incoming msg

logMe ::
       ( ConvertibleStrings String a
       , Semigroup a
       , IsString a
       , MonadReader PeerReader m
       )
    => m a
logMe = logPeer <$> asks mySockAddr

incoming :: MonadPeer m => Message -> ConduitT () Message m ()
incoming m = do
    lp <- lift logMe
    p <- asks mySelf
    l <- peerConfListener <$> asks myConfig
    mgr <- peerConfManager <$> asks myConfig
    ch <- peerConfChain <$> asks myConfig
    case m of
        MVersion _ -> do
            $(logError) $ lp <> "Received duplicate " <> logMsg m
            yield $
                MReject
                    Reject
                    { rejectMessage = MCVersion
                    , rejectCode = RejectDuplicate
                    , rejectReason = VarString BS.empty
                    , rejectData = BS.empty
                    }
        MPing (Ping n) -> yield $ MPong (Pong n)
        MPong (Pong n) -> atomically (l (p, GotPong n))
        MSendHeaders {} -> ChainSendHeaders p `send` ch
        MAlert {} -> $(logWarn) $ lp <> "Deprecated " <> logMsg m
        MAddr (Addr as) -> managerNewPeers p as mgr
        MInv (Inv is) -> do
            let ts = [TxHash (invHash i) | i <- is, invType i == InvTx]
                bs =
                    [ BlockHash (invHash i)
                    | i <- is
                    , invType i == InvBlock || invType i == InvMerkleBlock
                    ]
            unless (null ts) $ atomically $ l (p, TxAvail ts)
            unless (null bs) $ ChainNewBlocks p bs `send` ch
        MTx tx -> atomically (l (p, GotTx tx))
        MBlock b -> atomically (l (p, GotBlock b))
        MMerkleBlock b -> atomically (l (p, GotMerkleBlock b))
        MHeaders (Headers hcs) -> ChainNewHeaders p hcs `send` ch
        MGetData (GetData d) -> atomically (l (p, SendData d))
        MNotFound (NotFound ns) -> do
            let f (InvVector InvTx hash) = Just (TxNotFound (TxHash hash))
                f (InvVector InvWitnessTx hash) =
                    Just (TxNotFound (TxHash hash))
                f (InvVector InvBlock hash) =
                    Just (BlockNotFound (BlockHash hash))
                f (InvVector InvWitnessBlock hash) =
                    Just (BlockNotFound (BlockHash hash))
                f (InvVector InvMerkleBlock hash) =
                    Just (BlockNotFound (BlockHash hash))
                f (InvVector InvWitnessMerkleBlock hash) =
                    Just (BlockNotFound (BlockHash hash))
                f _ = Nothing
                events = mapMaybe f ns
            atomically (mapM_ (l . (p, )) events)
        MGetBlocks g -> atomically (l (p, SendBlocks g))
        MGetHeaders h -> atomically (l (p, SendHeaders h))
        MReject r -> atomically (l (p, Rejected r))
        MMempool -> atomically (l (p, WantMempool))
        MGetAddr -> managerGetAddr p mgr
        _ -> $(logWarn) $ lp <> "Ignoring message: " <> logMsg m

inPeerConduit :: MonadIO m => Network -> ConduitT ByteString PeerMessage m ()
inPeerConduit net = do
    headerBytes <- CB.take 24
    when (BL.null headerBytes) $ throwIO MessageHeaderEmpty
    case decodeLazy headerBytes of
        Left e -> throwIO $ DecodeMessageError e
        Right (MessageHeader _ _cmd len _) -> do
            when (len > 32 * 2 ^ (20 :: Int)) . throwIO $ PayloadTooLarge len
            payloadBytes <- CB.take (fromIntegral len)
            case runGetLazy (getMessage net) $ headerBytes `BL.append` payloadBytes of
                Left e    -> throwIO $ CannotDecodePayload e
                Right msg -> yield $ PeerIncoming msg
            inPeerConduit net

outPeerConduit :: Monad m => Network -> ConduitT Message ByteString m ()
outPeerConduit net = awaitForever $ yield . runPut . putMessage net
