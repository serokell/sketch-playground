{-------------------------------------------------------------------------------
  Outbound message queue

  Intended for qualified import

  > import Network.Broadcast.OutboundQ (OutboundQ)
  > import qualified Network.Broadcast.OutboundQ as OutQ
  > import Network.Broadcast.OutboundQueue.Classification

  References:
  * https://issues.serokell.io/issue/CSL-1272
  * IERs_V2.md
-------------------------------------------------------------------------------}

{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE MultiWayIf          #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TupleSections       #-}

module Network.Broadcast.OutboundQueue (
    OutboundQ -- opaque
    -- * Initialization
  , new
  , asOutboundQueue
    -- ** Enqueueing policy
  , Precedence(..)
  , MaxAhead(..)
  , Enqueue(..)
  , EnqueuePolicy
  , defaultEnqueuePolicy
    -- ** Dequeueing policy
  , RateLimit(..)
  , MaxInFlight(..)
  , Dequeue(..)
  , DequeuePolicy
  , defaultDequeuePolicy
    -- ** Failure policy
  , FailurePolicy
  , ReconsiderAfter(..)
  , defaultFailurePolicy
    -- * Enqueueing
  , Origin(..)
    -- ** Using subscribers
  , enqueue
  , enqueueSync'
  , enqueueSync
  , enqueueCherished
    -- ** To specified peers
  , enqueueTo
  , enqueueSyncTo'
  , enqueueSyncTo
  , enqueueCherishedTo
    -- * Dequeuing
  , SendMsg
  , dequeueThread
    -- ** Controlling the dequeuer
  , flush
  , waitShutdown
    -- * Peers
  , Peers(..)
  , AllOf
  , Alts
  , simplePeers
  , subscribe
  , unsubscribe

  , ClassifiedConversation
  ) where

import Control.Concurrent
import Control.Exception
import Control.Lens
import Control.Monad
import Control.Monad.IO.Class
import Data.Either (rights)
import Data.Maybe (maybeToList)
import Data.Map.Strict (Map)
import Data.Monoid ((<>))
import Data.Set (Set)
import Data.Text (Text)
import Data.Time
import Formatting (sformat, (%), shown, string)
import System.Wlog.CanLog
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set

import Network.Broadcast.OutboundQueue.Classification
import Network.Broadcast.OutboundQueue.ConcurrentMultiQueue (MultiQueue)
import qualified Network.Broadcast.OutboundQueue.ConcurrentMultiQueue as MQ
import qualified Mockable as M

import Node.Internal (NodeId)
import Node.Conversation (Conversation, Converse)
import Node.OutboundQueue (OutboundQueue (..))

{-------------------------------------------------------------------------------
  Precedence levels
-------------------------------------------------------------------------------}

-- | Precedence levels
--
-- These precedence levels are not given meaningful names because the same kind
-- of message might be given different precedence levels on different kinds of
-- nodes. Meaning is given to these levels in the enqueueing policy.
data Precedence = PLowest | PLow | PMedium | PHigh | PHighest
  deriving (Show, Eq, Ord, Enum, Bounded)

enumPrecLowestFirst :: [Precedence]
enumPrecLowestFirst = [minBound .. maxBound]

enumPrecHighestFirst :: [Precedence]
enumPrecHighestFirst = reverse enumPrecLowestFirst

{-------------------------------------------------------------------------------
  Known peers
-------------------------------------------------------------------------------}

-- | All known peers, split per node type, in order of preference
data Peers nid = Peers {
      _peersCore  :: AllOf (Alts nid)
    , _peersRelay :: AllOf (Alts nid)
    , _peersEdge  :: AllOf (Alts nid)
    }
  deriving (Show)

-- | List of forwarding sets
--
-- Each of these need to be contacted (in arbitrary order)
type AllOf a = [a]

-- | Single forwarding set
--
-- Non-empty list of alternatives (in order of preference)
type Alts a = [a]

makeLenses ''Peers

peersOfType :: NodeType -> Lens' (Peers nid) (AllOf (Alts nid))
peersOfType NodeCore  = peersCore
peersOfType NodeRelay = peersRelay
peersOfType NodeEdge  = peersEdge

-- | Construct 'Peers' from a list of node IDs
--
-- This effective means that all of these peers will be sent all (relevant)
-- messages.
simplePeers :: forall nid. [(NodeType, nid)] -> Peers nid
simplePeers = go mempty
  where
    go :: Peers nid -> [(NodeType, nid)] -> Peers nid
    go acc []            = acc
    go acc ((typ, n):ns) = go (acc & peersOfType typ %~ ([n] :)) ns

instance Monoid (Peers nid) where
  mempty      = Peers [] [] []
  mappend a b = Peers {
                    _peersCore  = comb _peersCore
                  , _peersRelay = comb _peersRelay
                  , _peersEdge  = comb _peersEdge
                  }
    where
      comb :: Monoid a => (Peers nid -> a) -> a
      comb f = f a `mappend` f b

removePeer :: forall nid. Ord nid => nid -> Peers nid -> Peers nid
removePeer toRemove peers =
    peers & peersCore  %~ remove
          & peersRelay %~ remove
          & peersEdge  %~ remove
  where
    remove :: AllOf (Alts nid) -> AllOf (Alts nid)
    remove = map $ filter (/= toRemove)

{-------------------------------------------------------------------------------
  Enqueueing policy

  The enquing policy is intended to guarantee that at the point of enqueing
  we can be reasonably sure that the message will get to where it needs to be
  within the maximum time bounds.
-------------------------------------------------------------------------------}

-- | Maximum number of messages allowed "ahead" of the message to be enqueued
--
-- This is the total number of messages currently in-flight or in-queue, with a
-- precedence at or above the message to be enqueued.
--
-- We can think of this as "all messages that will be handled before the new
-- message", although that is not /quite/ right: messages currently already
-- in-flight with a precedence lower than the new message are not included even
-- though they are also handled before the new message. We make this exception
-- because the presence of low precedence in-flight messages should not affect
-- the enqueueing policy for higher precedence messages.
--
-- If we cannot find any alternative that doesn't match requirements we simply
-- give up on forwarding set.
newtype MaxAhead = MaxAhead Int

-- | Enqueueing instruction
data Enqueue =
    -- | For /all/ forwarding sets of the specified node type, chose /one/
    -- alternative to send the message to
    EnqueueAll {
        enqNodeType   :: NodeType
      , enqMaxAhead   :: MaxAhead
      , enqPrecedence :: Precedence
      }

    -- | Choose /one/ alternative of /one/ forwarding set of any of the
    -- specified node types (listed in order of preference)
  | EnqueueOne {
        enqNodeTypes  :: [NodeType]
      , enqMaxAhead   :: MaxAhead
      , enqPrecedence :: Precedence
      }

-- | The enqueuing policy
--
-- The enqueueing policy decides what kind of peer to send each message to,
-- how to pick alternatives, and which precedence level to assign to the
-- message. However, it does NOT decide _how many_ alternatives to pick; we
-- pick one from _each_ of the lists that we are given. It is the responsiblity
-- of the next layer up to configure these peers as desired.
--
-- TODO: Sanity check the number of forwarding sets and number of alternatives.
-- TODO: Verify the max queue sizes against the updated policy.
type EnqueuePolicy nid =
           MsgType      -- ^ Type of the message we want to send
        -> Origin nid   -- ^ Where did this message originate?
        -> [Enqueue]

-- TODO: Verify the policy for data requests
defaultEnqueuePolicy :: NodeType           -- ^ Type of this node
                     -> EnqueuePolicy nid
defaultEnqueuePolicy NodeCore = go
  where
    -- Enqueue policy for core nodes
    go :: EnqueuePolicy nid
    go MsgAnnounceBlockHeader _ = [
        EnqueueAll NodeCore  (MaxAhead 0) PHighest
      , EnqueueAll NodeRelay (MaxAhead 0) PMedium
      ]
    go MsgRequestBlockHeaders _ = [
        EnqueueAll NodeCore  (MaxAhead 20) PLowest
      , EnqueueAll NodeRelay (MaxAhead 20) PLowest
      ]
    go MsgRequestBlock _ = [
        -- We never ask for data from edge nodes
        EnqueueOne [NodeRelay, NodeCore] (MaxAhead 20) PLowest
      ]
    go MsgMPC _ = [
        EnqueueAll NodeCore (MaxAhead 1) PHigh
        -- not sent to relay nodes
      ]
    go MsgTransaction _ = [
        EnqueueAll NodeCore (MaxAhead 20) PLow
        -- not sent to relay nodes
      ]
defaultEnqueuePolicy NodeRelay = go
  where
    -- Enqueue policy for relay nodes
    go :: EnqueuePolicy nid
    go MsgAnnounceBlockHeader _ = [
        EnqueueAll NodeRelay (MaxAhead 0) PHighest
      , EnqueueAll NodeCore  (MaxAhead 0) PHigh
      , EnqueueAll NodeEdge  (MaxAhead 0) PMedium
      ]
    go MsgRequestBlockHeaders _ = [
        EnqueueAll NodeCore  (MaxAhead 20) PLowest
      , EnqueueAll NodeRelay (MaxAhead 20) PLowest
      ]
    go MsgRequestBlock _ = [
        -- We never ask for data from edge nodes
        EnqueueOne [NodeRelay, NodeCore] (MaxAhead 20) PLowest
      ]
    go MsgTransaction _ = [
        EnqueueAll NodeCore  (MaxAhead 20) PLow
      , EnqueueAll NodeRelay (MaxAhead 20) PLowest
        -- transactions not forwarded to edge nodes
      ]
    go MsgMPC _ = [
        -- Relay nodes never sent any MPC messages to anyone
      ]
defaultEnqueuePolicy NodeEdge = go
  where
    -- Enqueue policy for edge nodes
    go :: EnqueuePolicy nid
    go MsgTransaction OriginSender = [
        EnqueueAll NodeRelay (MaxAhead 0) PHighest
      ]
    go MsgTransaction (OriginForward _) = [
        -- don't forward transactions that weren't created at this node
      ]
    go MsgAnnounceBlockHeader _ = [
        -- not forwarded
      ]
    go MsgRequestBlockHeaders _ = [
        EnqueueAll NodeRelay (MaxAhead 20) PLowest
      ]
    go MsgRequestBlock _ = [
        -- Edge nodes can only talk to relay nodes
        EnqueueOne [NodeRelay] (MaxAhead 20) PLowest
      ]
    go MsgMPC _ = [
        -- not relevant
      ]

{-------------------------------------------------------------------------------
  Dequeue policy
-------------------------------------------------------------------------------}

data Dequeue = Dequeue {
      -- | Delay before sending the next message (to this node)
      deqRateLimit :: RateLimit

      -- | Maximum number of in-flight messages (to this node node)
    , deqMaxInFlight :: MaxInFlight
    }

-- | Rate limiting
data RateLimit = NoRateLimiting | MaxMsgPerSec Int

-- | Maximum number of in-flight messages (for latency hiding)
newtype MaxInFlight = MaxInFlight Int

-- | Dequeue policy
--
-- The dequeue policy epends only on the type of the node we're sending to,
-- not the same of the message we're sending.
type DequeuePolicy = NodeType -> Dequeue

defaultDequeuePolicy :: NodeType -- ^ Our node type
                     -> DequeuePolicy
defaultDequeuePolicy NodeCore = go
  where
    -- Dequeueing policy for core nodes
    go :: DequeuePolicy
    go NodeCore  = Dequeue NoRateLimiting (MaxInFlight 2)
    go NodeRelay = Dequeue NoRateLimiting (MaxInFlight 1)
    go NodeEdge  = error "defaultDequeuePolicy: core to edge not applicable"
defaultDequeuePolicy NodeRelay = go
  where
    -- Dequeueing policy for relay nodes
    go :: DequeuePolicy
    go NodeCore  = Dequeue (MaxMsgPerSec 1) (MaxInFlight 1)
    go NodeRelay = Dequeue (MaxMsgPerSec 3) (MaxInFlight 2)
    go NodeEdge  = Dequeue (MaxMsgPerSec 1) (MaxInFlight 1)
defaultDequeuePolicy NodeEdge = go
  where
    -- Dequeueing policy for edge nodes
    go :: DequeuePolicy
    go NodeCore  = error "defaultDequeuePolicy: edge to core not applicable"
    go NodeRelay = Dequeue (MaxMsgPerSec 1) (MaxInFlight 1)
    go NodeEdge  = error "defaultDequeuePolicy: edge to edge not applicable"

{-------------------------------------------------------------------------------
  Failure policy
-------------------------------------------------------------------------------}

-- | The failure policy determines what happens when a failure occurs as we send
-- a message to a particular node: how long (in sec) should we wait until we
-- consider this node to be a viable alternative again?
type FailurePolicy = NodeType -> MsgType -> SomeException -> ReconsiderAfter

-- | How long (in sec) after a failure should we reconsider this node again for
-- new messages?
newtype ReconsiderAfter = ReconsiderAfter Int

-- | Default failure policy
--
-- TODO: Implement proper policy
defaultFailurePolicy :: NodeType -- ^ Our node type
                     -> FailurePolicy
defaultFailurePolicy _ourType _theirType _msgType _err = ReconsiderAfter 200

{-------------------------------------------------------------------------------
  Thin wrapper around ConcurrentMultiQueue
-------------------------------------------------------------------------------}

-- | The values we store in the multiqueue
data Packet msg nid a = Packet {
    -- | The actual payload of the message
    packetPayload :: msg a

    -- | Type of the message
  , packetMsgType :: MsgType

    -- | Type of the node the packet needs to be sent to
  , packetDestType :: NodeType

    -- | Node to send it to
  , packetDestId :: nid

    -- | Precedence of the message
  , packetPrec :: Precedence

    -- | MVar filled with the result of the sent action
    --
    -- (empty when enqueued)
  , packetSent :: MVar (Either SomeException a)
  }

-- | Hide the 'a' type parameter
data EnqPacket msg nid = forall a. EnqPacket (Packet msg nid a)

-- | Lift functions on 'Packet' to 'EnqPacket'
liftEnq :: (forall a. Packet msg nid a -> b) -> EnqPacket msg nid -> b
liftEnq f (EnqPacket p) = f p

-- | The keys we use to index the multiqueue
data Key nid =
    -- | All messages with a certain precedence
    --
    -- Used when dequeuing to determine the next message to send
    KeyByPrec Precedence

    -- | All messages to a certain destination
    --
    -- Used when dequeing to determine max in-flight to a particular destination
    -- (for latency hiding)
  | KeyByDest nid

    -- | All messages with a certain precedence to a particular destination
    --
    -- Used when enqueuing to determine routing (enqueuing policy)
  | KeyByDestPrec nid Precedence
  deriving (Show, Eq, Ord)

-- | MultiQueue instantiated at the types we need
type MQ msg nid = MultiQueue (Key nid) (EnqPacket msg nid)

mqEnqueue :: (MonadIO m, Ord nid)
          => MQ msg nid -> EnqPacket msg nid -> m ()
mqEnqueue qs p = liftIO $
  MQ.enqueue qs [ KeyByDest     (liftEnq packetDestId p)
                , KeyByDestPrec (liftEnq packetDestId p) (liftEnq packetPrec p)
                , KeyByPrec                              (liftEnq packetPrec p)
                ]
                p

-- | Check whether a node is not currently busy
--
-- (i.e., number of in-flight messages is less than the max)
type NotBusy nid = NodeType -> nid -> Bool

mqDequeue :: forall m msg nid. (MonadIO m, Ord nid)
          => MQ msg nid -> NotBusy nid -> m (Maybe (EnqPacket msg nid))
mqDequeue qs notBusy =
    orElseM [
        liftIO $ MQ.dequeue (KeyByPrec prec) notBusy' qs
      | prec <- enumPrecHighestFirst
      ]
  where
    notBusy' :: EnqPacket msg nid -> Bool
    notBusy' (EnqPacket Packet{..}) = notBusy packetDestType packetDestId

{-------------------------------------------------------------------------------
  State Initialization
-------------------------------------------------------------------------------}

-- | How many messages are in-flight to each destination?
type InFlight nid = Map nid (Map Precedence Int)

-- | Which nodes suffered from a recent communication failure?
type Failures nid = Set nid

inFlightTo :: Ord nid => nid -> Lens' (InFlight nid) (Map Precedence Int)
inFlightTo nid = at nid . anon Map.empty Map.null

inFlightWithPrec :: Ord nid => nid -> Precedence -> Lens' (InFlight nid) Int
inFlightWithPrec nid prec = inFlightTo nid . at prec . anon 0 (== 0)

-- | The outbound queue (opaque data structure)
data OutboundQ msg nid = forall self .
                         ( FormatMsg msg
                         , Ord nid
                         , Show nid
                         , Show self
                         ) => OutQ {
      -- | Node ID of the current node (primarily for debugging purposes)
      qSelf :: self

      -- | Enqueuing policy
    , qEnqueuePolicy :: EnqueuePolicy nid

      -- | Dequeueing policy
    , qDequeuePolicy :: DequeuePolicy

      -- | Failure policy
    , qFailurePolicy :: FailurePolicy

      -- | Messages sent but not yet acknowledged
    , qInFlight :: MVar (InFlight nid)

      -- | Messages scheduled but not yet sent
    , qScheduled :: MQ msg nid

      -- | Known peers
    , qPeers :: MVar (Peers nid)

      -- | Recent communication failures
    , qFailures :: MVar (Failures nid)

      -- | Used to send control messages to the main thread
    , qCtrlMsg :: MVar CtrlMsg

      -- | Signal we use to wake up blocked threads
    , qSignal :: Signal CtrlMsg
    }

-- | Initialize the outbound queue
--
-- NOTE: The dequeuing thread must be started separately. See 'dequeueThread'.
new :: ( MonadIO m
       , FormatMsg msg
       , Ord nid
       , Show nid
       , Show self
       )
    => self -- ^ Showable identifier of this node, for logging purposes.
    -> EnqueuePolicy nid
    -> DequeuePolicy
    -> FailurePolicy
    -> m (OutboundQ msg nid)
new qSelf qEnqueuePolicy qDequeuePolicy qFailurePolicy = liftIO $ do
    qInFlight  <- newMVar Map.empty
    qScheduled <- MQ.new
    qPeers     <- newMVar mempty
    qCtrlMsg   <- newEmptyMVar
    qFailures  <- newMVar Set.empty

    -- Only look for control messages when the queue is empty
    let checkCtrlMsg :: IO (Maybe CtrlMsg)
        checkCtrlMsg = do
          qSize <- MQ.size qScheduled
          if qSize == 0
            then tryTakeMVar qCtrlMsg
            else return Nothing

    qSignal <- newSignal checkCtrlMsg
    return OutQ{..}

{-------------------------------------------------------------------------------
  Interpreter for the enqueing policy
-------------------------------------------------------------------------------}

intEnqueue :: forall m msg nid a. (MonadIO m, WithLogger m)
           => OutboundQ msg nid
           -> MsgType
           -> msg a
           -> Origin nid
           -> Peers nid
           -> m [Packet msg nid a]
intEnqueue outQ@OutQ{..} msgType msg origin peers = fmap concat $
    forM (qEnqueuePolicy msgType origin) $ \case

      EnqueueAll{..} -> do
        let fwdSets :: AllOf (Alts nid)
            fwdSets = removeOrigin $ peers ^. peersOfType enqNodeType

            sendAll :: [Packet msg nid a]
                    -> AllOf (Alts nid)
                    -> m [Packet msg nid a]
            sendAll acc []           = return acc
            sendAll acc (alts:altss) = do
              mPacket <- sendFwdSet (map packetDestId acc)
                                    enqMaxAhead
                                    enqPrecedence
                                    (enqNodeType, alts)
              case mPacket of
                Nothing -> sendAll    acc  altss
                Just p  -> sendAll (p:acc) altss

        enqueued <- sendAll [] fwdSets

        -- Log an error if we didn't manage to send the message to any peer
        -- at all (provided that we were configured to send it to some)
        if | null fwdSets ->
               logDebug $ msgNotSent enqNodeType -- This isn't an error
           | null enqueued ->
               logError $ msgLost fwdSets
           | otherwise ->
               logDebug $ msgEnqueued enqueued

        return enqueued

      EnqueueOne{..} -> do
        let fwdSets :: [(NodeType, Alts nid)]
            fwdSets = concatMap
                        (\t -> map (t,) $ removeOrigin $ peers ^. peersOfType t)
                        enqNodeTypes

            sendOne :: [(NodeType, Alts nid)] -> m [Packet msg nid a]
            sendOne = fmap maybeToList
                    . orElseM
                    . map (sendFwdSet [] enqMaxAhead enqPrecedence)

        enqueued <- sendOne fwdSets
        when (null enqueued) $
          logError $ msgLost fwdSets
        return enqueued
  where
    -- Attempt to send the message to a single forwarding set
    sendFwdSet :: [nid]                -- ^ Nodes we already sent something to
               -> MaxAhead             -- ^ Max allowed number of msgs ahead
               -> Precedence           -- ^ Precedence of the message
               -> (NodeType, Alts nid) -- ^ Alternatives to choose from
               -> m (Maybe (Packet msg nid a))
    sendFwdSet alreadyPicked maxAhead prec (nodeType, alts) = do
      mAlt <- pickAlt outQ maxAhead prec $ filter (`notElem` alreadyPicked) alts
      case mAlt of
        Nothing -> do
          logWarning $ msgNoAlt alts
          return Nothing
        Just alt -> liftIO $ do
          sentVar <- newEmptyMVar
          let packet = Packet {
                           packetPayload  = msg
                         , packetDestId   = alt
                         , packetMsgType  = msgType
                         , packetDestType = nodeType
                         , packetPrec     = prec
                         , packetSent     = sentVar
                         }
          mqEnqueue qScheduled (EnqPacket packet)
          poke qSignal
          return $ Just packet

    -- Don't forward a message back to the node that sent it originally
    -- (We assume that a node does not appear in its own list of peers)
    removeOrigin :: AllOf (Alts nid) -> AllOf (Alts nid)
    removeOrigin =
      case origin of
        OriginSender    -> id
        OriginForward n -> filter (not . null) . map (filter (/= n))

    msgNotSent :: NodeType -> Text
    msgNotSent nodeType = sformat
      ( shown
      % ": message "
      % formatMsg
      % " not sent to any nodes of type "
      % shown
      % " since no such (relevant) peers listed in "
      % shown
      )
      qSelf
      msg
      nodeType
      peers

    msgEnqueued :: [Packet msg nid a] -> Text
    msgEnqueued enqueued =
      sformat (shown % ": message " % formatMsg % " enqueued to " % shown)
              qSelf msg (map packetDestId enqueued)

    msgNoAlt :: [nid] -> Text
    msgNoAlt alts =
      sformat (shown % ": could not choose suitable alternative from " % shown)
              qSelf alts

    msgLost :: Show fwdSets => fwdSets -> Text
    msgLost fwdSets =
      sformat ( shown
              % ": failed to enqueue message " % formatMsg
              % " with origin " % shown
              % " to forwarding sets " % shown
              )
              qSelf msg origin fwdSets

pickAlt :: (MonadIO m, WithLogger m)
        => OutboundQ msg nid
        -> MaxAhead
        -> Precedence
        -> Alts nid
        -> m (Maybe nid)
pickAlt outQ (MaxAhead maxAhead) prec alts =
    orElseM [ do
        failure <- hasRecentFailure outQ alt
        ahead   <- countAhead outQ alt prec
        return $ if not failure && ahead <= maxAhead
                   then Just alt
                   else Nothing
      | alt <- alts
      ]

-- | Check how many messages are currently ahead
--
-- NOTE: This is of course a highly dynamic value; by the time we get to
-- actually enqueue the message the value might be slightly different. Bounds
-- are thus somewhat fuzzy.
countAhead :: forall m msg nid. (MonadIO m, WithLogger m)
           => OutboundQ msg nid -> nid -> Precedence -> m Int
countAhead OutQ{..} nid prec = do
    logDebug . msgInFlight =<< liftIO (readMVar qInFlight)
    (inFlight, inQueue) <- liftIO $ (,)
      <$> forM [prec .. maxBound] (\prec' ->
            view (inFlightWithPrec nid prec') <$> readMVar qInFlight)
      <*> forM [prec .. maxBound] (\prec' ->
            MQ.sizeBy (KeyByDestPrec nid prec') qScheduled)
    return $ sum inFlight + sum inQueue
  where
    msgInFlight :: InFlight nid -> Text
    msgInFlight = sformat (shown % ": inFlight = " % shown) qSelf

{-------------------------------------------------------------------------------
  Interpreter for the dequeueing policy
-------------------------------------------------------------------------------}

checkMaxInFlight :: Ord nid => DequeuePolicy -> InFlight nid -> NotBusy nid
checkMaxInFlight dequeuePolicy inFlight nodeType nid =
    sum (Map.elems (inFlight ^. inFlightTo nid)) < n
  where
    MaxInFlight n = deqMaxInFlight (dequeuePolicy nodeType)

applyRateLimit :: MonadIO m
               => DequeuePolicy
               -> NodeType
               -> ExecutionTime -- ^ Time of the send
               -> m ()
applyRateLimit dequeuePolicy nodeType sendExecTime = liftIO $
    case deqRateLimit (dequeuePolicy nodeType) of
      NoRateLimiting -> return ()
      MaxMsgPerSec n -> threadDelay (1000000 `div` n - sendExecTime)

intDequeue :: forall m msg nid. WithLogger m
           => OutboundQ msg nid
           -> ThreadRegistry m
           -> SendMsg m msg nid
           -> m (Maybe CtrlMsg)
intDequeue outQ@OutQ{..} threadRegistry@TR{} sendMsg = do
    mPacket <- getPacket
    case mPacket of
      Left ctrlMsg -> return $ Just ctrlMsg
      Right packet -> sendPacket packet >> return Nothing
  where
    getPacket :: m (Either CtrlMsg (EnqPacket msg nid))
    getPacket = retryIfNothing qSignal $ do
      inFlight <- liftIO $ readMVar qInFlight
      mqDequeue qScheduled (checkMaxInFlight qDequeuePolicy inFlight)

    -- Send the packet we just dequeued
    --
    -- At this point we have dequeued the message but not yet recorded it as
    -- in-flight. That's okay though: the only function whose behaviour is
    -- affected by 'rsInFlight' is 'intDequeue', the main thread (this thread) is
    -- the only thread calling 'intDequeue', and we will update 'rsInFlight'
    -- before dequeueing the next message.
    --
    -- We start a new thread to handle the conversation. This is a bit of a
    -- subtle design decision. We could instead start the conversation here in
    -- the main thread, and fork a thread only to wait for the acknowledgement.
    -- The problem with doing that is that if that conversation gets blocked or
    -- delayed for any reason, it will block or delay the whole outbound queue.
    -- The downside of the /current/ solution is that it makes priorities
    -- somewhat less meaningful: although the priorities dictate in which order
    -- we fork threads to handle conversations, after that those threads all
    -- compete with each other (amongst other things, for use of the network
    -- device), with no real way to prioritize any one thread over the other. We
    -- will be able to solve this conumdrum properly once we move away from TCP
    -- and use the RINA network architecture instead.
    sendPacket :: EnqPacket msg nid -> m ()
    sendPacket (EnqPacket p) = do
      applyMVar_ qInFlight $
        inFlightWithPrec (packetDestId p) (packetPrec p) %~ (\n -> n + 1)
      forkThread threadRegistry $ \unmask -> do
        logDebug $ msgSending p
        (ma, sendExecTime) <- timed $ M.try $ unmask $
                                sendMsg (packetPayload p) (packetDestId p)
        -- TODO: Do we want to acknowledge the send here? Or after we have
        -- reduced qInFlight? The latter is safer (means the next enqueue is
        -- less likely to be rejected because there are no peers available with
        -- a small enough number of messages " ahead ") but it would mean we
        -- can only acknowledge the send after the delay, which seems
        -- undesirable.
        liftIO $ putMVar (packetSent p) ma
        unmask $ applyRateLimit qDequeuePolicy (packetDestType p) sendExecTime
        case ma of
          Left err -> do
            logWarning $ msgSendFailed p err
            intFailure outQ threadRegistry p sendExecTime err
          Right _  ->
            return ()
        applyMVar_ qInFlight $
          inFlightWithPrec (packetDestId p) (packetPrec p) %~ (\n -> n - 1)
        logDebug $ msgSent p
        liftIO $ poke qSignal

    msgSending :: Packet msg nid a -> Text
    msgSending Packet{..} =
      sformat (shown % ": sending " % formatMsg % " to " % shown)
              qSelf packetPayload packetDestId

    msgSent :: Packet msg nid a -> Text
    msgSent Packet{..} =
      sformat (shown % ": sent " % formatMsg % " to " % shown)
              qSelf packetPayload packetDestId

    msgSendFailed :: Packet msg nid a -> SomeException -> Text
    msgSendFailed Packet{..} err =
      sformat ( shown % ": sending " % formatMsg % " to " % shown
              % " failed with " % string )
              qSelf packetPayload packetDestId (displayException err)

{-------------------------------------------------------------------------------
  Interpreter for failure policy
-------------------------------------------------------------------------------}

-- | What do we know when sending a message fails?
--
-- NOTE: Since we don't send messages to nodes listed in failures, we can
-- assume that there isn't an existing failure here.
intFailure :: forall m msg nid a.
              OutboundQ msg nid
           -> ThreadRegistry m
           -> Packet msg nid a  -- ^ Packet we failed to send
           -> ExecutionTime     -- ^ How long did the send take?
           -> SomeException     -- ^ The exception thrown by the send action
           -> m ()
intFailure OutQ{..} threadRegistry@TR{} p sendExecTime err = do
    applyMVar_ qFailures $ Set.insert (packetDestId p)
    forkThread threadRegistry $ \unmask -> do
      -- Negative delay is interpreted as no delay
      unmask $ liftIO $ threadDelay (delay * 1000000 - sendExecTime)
      applyMVar_ qFailures $ Set.delete (packetDestId p)
  where
    delay :: Int
    ReconsiderAfter delay =
      qFailurePolicy (packetDestType p)
                     (packetMsgType  p)
                     err

hasRecentFailure :: MonadIO m => OutboundQ msg nid -> nid -> m Bool
hasRecentFailure OutQ{..} nid = liftIO $ Set.member nid <$> readMVar qFailures

{-------------------------------------------------------------------------------
  Public interface to enqueing
-------------------------------------------------------------------------------}

-- | Where did the message we're sending originate?
--
-- We need this because, for example, edge nodes will want to send /their/
-- transactions to relay nodes, but not any transactions that they /received/
-- from relay nodes.
data Origin nid =
    -- | It originated at the node who's sending it
    --
    -- For instance, for a transaction this means it was created on this (edge)
    -- node; for a block it would mean it was constructed on this (core) node.
    OriginSender

    -- | It originated elsewhere; we're just forwarding it
    --
    -- We record on behalf of whom we're forwarding so that we can avoid
    -- sending it straight back to them.
  | OriginForward nid
  deriving (Show)

-- | Queue a message to be send to all peers, but don't wait (asynchronous API)
--
-- The message will be sent to the specified peers as well as any subscribers.
-- The results of the send action are ignored.
--
-- TODO: Ultimately we want to move to a model where we /only/ have
-- subscription; after all, it's no problem for statically configured nodes to
-- also subscribe when they are created. We don't use such a model just yet to
-- make integration easier.
enqueue :: (MonadIO m, WithLogger m)
        => OutboundQ msg nid
        -> MsgType    -- ^ Type of the message being sent
        -> msg a      -- ^ Message to send
        -> Origin nid -- ^ Origin of this message
        -> Peers nid  -- ^ Additional peers (along with subscribers)
        -> m [(nid, m (Either SomeException a))]
enqueue outQ msgType msg origin peers' = do
    waitAsync <$> intEnqueueTo outQ msgType msg origin (EnqToSubscr peers')

-- | Queue a message and wait for it to have been sent
--
-- Returns for each node that the message got enqueued the result of the
-- send action (or an exception if it failed).
enqueueSync' :: (MonadIO m, WithLogger m)
             => OutboundQ msg nid
             -> MsgType    -- ^ Type of the message being sent
             -> msg a      -- ^ Message to send
             -> Origin nid -- ^ Origin of this message
             -> Peers nid  -- ^ Additional peers (along with subscribers)
             -> m [(nid, Either SomeException a)]
enqueueSync' outQ msgType msg origin peers' = do
    promises <- enqueue outQ msgType msg origin peers'
    traverse (\(nid, wait) -> (,) nid <$> wait) promises

-- | Queue a message and wait for it to have been sent
--
-- We wait for the message to have been sent (successfully or unsuccessfully)
-- to all the peers it got enqueued to. Like in the asynchronous API,
-- warnings will be logged when individual sends fail. Additionally, we will
-- log an error when /all/ sends failed (this doesn't currently happen in the
-- asynchronous API).
enqueueSync :: forall m msg nid a. (MonadIO m, WithLogger m)
            => OutboundQ msg nid
            -> MsgType    -- ^ Type of the message being sent
            -> msg a      -- ^ Message to send
            -> Origin nid -- ^ Origin of this message
            -> Peers nid  -- ^ Additional peers (along with subscribers)
            -> m ()
enqueueSync outQ msgType msg origin peers =
    warnIfNotOneSuccess outQ msg $
      enqueueSync' outQ msgType msg origin peers

-- | Enqueue a message which really should not get lost
--
-- Returns 'True' if the message was successfully sent.
enqueueCherished :: forall m msg nid a. (MonadIO m, WithLogger m)
                 => OutboundQ msg nid
                 -> MsgType   -- ^ Type of the message being sent
                 -> msg a     -- ^ Message to send
                 -> Peers nid -- ^ Additional peers (along with subscribers)
                 -> m Bool
enqueueCherished outQ msgType msg peers =
    cherish outQ $
      enqueueSync' outQ msgType msg OriginSender peers

{-------------------------------------------------------------------------------
  Variations that take a specific set of peers
-------------------------------------------------------------------------------}

-- | 'enqueueTo' variation which allows the caller to decide for each peer
-- whether to wait on the result or not.
enqueueTo :: (MonadIO m, WithLogger m)
          => OutboundQ msg nid
          -> MsgType    -- ^ Type of the message being sent
          -> msg a      -- ^ Message to send
          -> Origin nid -- ^ Origin of this message
          -> Peers nid  -- ^ Who to send to (modulo policy)?
          -> m [(nid, m (Either SomeException a))]
enqueueTo outQ msgType msg origin peers' = do
    waitAsync <$> intEnqueueTo outQ msgType msg origin (EnqToPeers peers')

-- | Variation on 'enqueueSync'' using given peers instead of subscribers
enqueueSyncTo' :: (MonadIO m, WithLogger m)
               => OutboundQ msg nid
               -> MsgType    -- ^ Type of the message being sent
               -> msg a      -- ^ Message to send
               -> Origin nid -- ^ Origin of this message
               -> Peers nid  -- ^ Who to send to (modulo policy)?
               -> m [(nid, Either SomeException a)]
enqueueSyncTo' outQ msgType msg origin peers' = do
    promises <- enqueueTo outQ msgType msg origin peers'
    traverse (\(nid, wait) -> (,) nid <$> wait) promises

-- | Variation on 'enqueueSync' using given peers instead of subscribers
enqueueSyncTo :: forall m msg nid a. (MonadIO m, WithLogger m)
              => OutboundQ msg nid
              -> MsgType    -- ^ Type of the message being sent
              -> msg a      -- ^ Message to send
              -> Origin nid -- ^ Origin of this message
              -> Peers nid  -- ^ Who to send to (modulo policy)?
              -> m ()
enqueueSyncTo outQ msgType msg origin peers =
    warnIfNotOneSuccess outQ msg $
      enqueueSyncTo' outQ msgType msg origin peers

-- | Variation on 'enqueueCherished' using given peers instead of subscribers
enqueueCherishedTo :: forall m msg nid a. (MonadIO m, WithLogger m)
                   => OutboundQ msg nid
                   -> MsgType   -- ^ Type of the message being sent
                   -> msg a     -- ^ Message to send
                   -> Peers nid -- ^ Who to send to (modulo policy)?
                   -> m Bool
enqueueCherishedTo outQ msgType msg peers =
    cherish outQ $
      enqueueSyncTo' outQ msgType msg OriginSender peers

{-------------------------------------------------------------------------------
  Internal generalization of the enqueueing API
-------------------------------------------------------------------------------}

data EnqueueTo nid =
    -- | Enqueue to all subscribers and some additional peers
    --
    -- The additional peers argument will eventually be removed
    EnqToSubscr (Peers nid)

    -- | Enqueue to a specific set of peers, ignoring subscribers
  | EnqToPeers (Peers nid)

-- | Enqueue message to the specified set of peers
intEnqueueTo :: (MonadIO m, WithLogger m)
             => OutboundQ msg nid
             -> MsgType
             -> msg a
             -> Origin nid
             -> EnqueueTo nid
             -> m [Packet msg nid a]
intEnqueueTo outQ@OutQ{..} msgType msg origin (EnqToSubscr peers') = do
    peers <- liftIO $ readMVar qPeers
    intEnqueue outQ msgType msg origin (peers <> peers')
intEnqueueTo outQ@OutQ{..} msgType msg origin (EnqToPeers peers') = do
    intEnqueue outQ msgType msg origin (peers')

waitAsync :: MonadIO m
          => [Packet msg nid a] -> [(nid, m (Either SomeException a))]
waitAsync = map $ \Packet{..} -> (packetDestId, liftIO $ readMVar packetSent)

-- | Make sure a synchronous send succeeds to at least one peer
warnIfNotOneSuccess :: forall m msg nid a. (MonadIO m, WithLogger m)
                    => OutboundQ msg nid
                    -> msg a
                    -> m [(nid, Either SomeException a)]
                    -> m ()
warnIfNotOneSuccess OutQ{qSelf} msg act = do
    attempts <- act
    -- If the attempts is null, we would already have logged an error that
    -- we couldn't enqueue at all
    when (not (null attempts) && null (successes attempts)) $
      logError $ msgNotSent (map fst attempts)
  where
    msgNotSent :: [nid] ->Text
    msgNotSent nids =
      sformat ( shown % ": message " % formatMsg
              % " got enqueued to " % shown
              % " but all sends failed"
              )
              qSelf msg nids

-- | Repeatedly run an action until at least one send succeeds, we run out of
-- options, or we reach a predetermined maximum number of iterations.
cherish :: forall m msg nid a. (MonadIO m, WithLogger m)
        => OutboundQ msg nid
        -> m [(nid, Either SomeException a)]
        -> m Bool
cherish OutQ{qSelf} act =
    go maxNumIterations
  where
    go :: Int -> m Bool
    go 0 = do
      logError $ msgLoop
      return False
    go n = do
      attempts <- act
      if | not (null (successes attempts)) ->
             -- We managed to successfully send it to at least one peer
             -- Consider it a job well done
             return True
         | null attempts ->
             -- We couldn't find anyone to send to. Give up in despair.
             return False
         | otherwise -> -- not (null attemts) && null succs
             -- We tried to send it to some nodes but they all failed
             -- In this case, we simply try again, hoping that we'll manage to
             -- pick some different alternative nodes to send to (since the
             -- failures will have been recorded in qFailures)
             go (n - 1)

    -- If we didn't have an upper bound on the number of iterations, we could
    -- in principle loop indefinitely, if the timeouts on sends are close to
    -- the time-to-reset-error-state defined by the failure policy.
    -- (Thus, the latter should be significantly larger than send timeouts.)
    maxNumIterations :: Int
    maxNumIterations = 4

    msgLoop :: Text
    msgLoop =
      sformat (shown % ": enqueueCherished loop? This a policy failure.")
              qSelf

successes :: [(nid, Either SomeException a)] -> [a]
successes = rights . map snd

{-------------------------------------------------------------------------------
  Dequeue thread
-------------------------------------------------------------------------------}

-- | Action to send a message
--
-- The action should block until the message has been acknowledged by the peer.
--
-- NOTE:
--
-- * The IO action will be run in a separate thread.
-- * No additional timeout is applied to the 'SendMsg', so if one is
--   needed it must be provided externally.
type SendMsg m msg nid = forall a. msg a -> nid -> m a

-- | The dequeue thread
--
-- It is the responsibility of the next layer up to fork this thread; this
-- function does not return unless told to terminate using 'waitShutdown'.
dequeueThread :: forall m msg nid. (
                   MonadIO              m
                 , M.Mockable M.Bracket m
                 , M.Mockable M.Catch   m
                 , M.Mockable M.Async   m
                 , M.Mockable M.Fork    m
                 , Ord (M.ThreadId      m)
                 , WithLogger           m
                 )
              => OutboundQ msg nid -> SendMsg m msg nid -> m ()
dequeueThread outQ@OutQ{..} sendMsg = withThreadRegistry $ \threadRegistry ->
    let loop :: m ()
        loop = do
          mCtrlMsg <- intDequeue outQ threadRegistry sendMsg
          case mCtrlMsg of
            Nothing      -> loop
            Just ctrlMsg -> do
              waitAllThreads threadRegistry
              case ctrlMsg of
                Shutdown ack -> do liftIO $ putMVar ack ()
                Flush    ack -> do liftIO $ putMVar ack ()
                                   loop

    in loop

{-------------------------------------------------------------------------------
  Controlling the dequeue thread
-------------------------------------------------------------------------------}

-- | Control messages sent to the main thread
--
-- NOTE: These are given lower precedence than non-control messages.
data CtrlMsg =
    Shutdown (MVar ())
  | Flush    (MVar ())

-- | Gracefully shutdown the relayer
waitShutdown :: MonadIO m => OutboundQ msg nid -> m ()
waitShutdown OutQ{..} = liftIO $ do
    ack <- newEmptyMVar
    putMVar qCtrlMsg $ Shutdown ack
    poke qSignal
    takeMVar ack

-- | Wait for all messages currently enqueued to have been sent
flush :: MonadIO m => OutboundQ msg nid -> m ()
flush OutQ{..} = liftIO $ do
    ack <- newEmptyMVar
    putMVar qCtrlMsg $ Flush ack
    poke qSignal
    takeMVar ack

{-------------------------------------------------------------------------------
  Subscription
-------------------------------------------------------------------------------}

-- | Subscribe to the outbound queue
--
-- NOTE: Behind NAT nodes: Edge nodes behind NAT can contact a relay node to ask
-- to be notified of messages. The listener on the relay node should call
-- 'subscribe' on its outbound queue to subscribe the edge node that contacted
-- it. Then the  conversation should remain open, so that the (heavy-weight) TCP
-- connection between the edge node and the relay node is kept open. When the
-- edge node disappears the listener thread on the relay node should call
-- 'unsubscribe' to remove the edge node from its outbound queue again.
subscribe :: MonadIO m => OutboundQ msg nid -> Peers nid -> m ()
subscribe OutQ{..} peers' = applyMVar_ qPeers (<> peers')

-- | Unsubscribe some nodes
--
-- See 'subscribe'.
--
-- NOTE: Any messages to this peer will be deleted from the queue.
-- It is assumed that the node will not appear in the "additional peers"
-- argument to 'enqueue'.
unsubscribe :: MonadIO m => Ord nid => OutboundQ msg nid -> nid -> m ()
unsubscribe OutQ{..} nid = do
    applyMVar_ qPeers    $ removePeer nid
    applyMVar_ qInFlight $ at nid .~ Nothing
    applyMVar_ qFailures $ Set.delete nid
    liftIO $ MQ.removeAllIn (KeyByDest nid) qScheduled

{-------------------------------------------------------------------------------
  Auxiliary: starting and registering threads
-------------------------------------------------------------------------------}

data ThreadRegistry m =
       ( MonadIO              m
       , M.Mockable M.Async   m
       , M.Mockable M.Bracket m
       , M.Mockable M.Fork    m
       , M.Mockable M.Catch   m
       , Ord (M.ThreadId      m)
       )
    => TR (MVar (Map (M.ThreadId m) (M.Promise m ())))

-- | Create a new thread registry, killing all threads when the action
-- terminates.
withThreadRegistry :: ( MonadIO              m
                      , M.Mockable M.Bracket m
                      , M.Mockable M.Async   m
                      , M.Mockable M.Fork    m
                      , M.Mockable M.Catch   m
                      , Ord (M.ThreadId      m)
                      )
                   => (ThreadRegistry m -> m ()) -> m ()
withThreadRegistry k = do
    threadRegistry <- liftIO $ TR <$> newMVar Map.empty
    k threadRegistry `M.finally` killAllThreads threadRegistry

killAllThreads :: ThreadRegistry m -> m ()
killAllThreads (TR reg) = do
    threads <- applyMVar reg $ \threads -> (Map.empty, Map.elems threads)
    mapM_ M.cancel threads

waitAllThreads :: ThreadRegistry m -> m ()
waitAllThreads (TR reg) = do
    threads <- applyMVar reg $ \threads -> (Map.empty, Map.elems threads)
    mapM_ M.wait threads

type Unmask m = forall a. m a -> m a

-- | Fork a new thread, taking care of registration and unregistration
forkThread :: ThreadRegistry m -> (Unmask m -> m ()) -> m ()
forkThread (TR reg) threadBody = M.mask_ $ do
    barrier <- liftIO $ newEmptyMVar
    thread  <- M.asyncWithUnmask $ \unmask -> do
                 tid <- M.myThreadId
                 liftIO $ takeMVar barrier
                 threadBody unmask `M.finally`
                   applyMVar_ reg (at tid .~ Nothing)
    tid     <- M.asyncThreadId thread
    applyMVar_ reg (at tid .~ Just thread)
    liftIO $ putMVar barrier ()

{-------------------------------------------------------------------------------
  Auxiliary: Signalling

  A signal is used to detect whether " something " changed between two points in
  time, and block a thread otherwise. Only a single thread should be calling
  'retryIfNothing'; other threads should call 'poke' to indicate when
  something changed and the blocked action can be retried. A signal is _not_ a
  counter: we don't keep track of how often 'poke' is called.
-------------------------------------------------------------------------------}

data Signal b = Signal {
    -- | Used to wake up the blocked thread
    signalPokeVar :: MVar ()

    -- | Check to see if there is an out-of-bound control message available
  , signalCtrlMsg :: IO (Maybe b)
  }

newSignal :: IO (Maybe b) -> IO (Signal b)
newSignal signalCtrlMsg = do
    signalPokeVar <- newEmptyMVar
    return Signal{..}

poke :: Signal b -> IO ()
poke Signal{..} = void $ tryPutMVar signalPokeVar ()

-- | Keep retrying an action until it succeeds, blocking between attempts.
retryIfNothing :: forall m a b. MonadIO m
               => Signal b -> m (Maybe a) -> m (Either b a)
retryIfNothing Signal{..} act = go
  where
    go :: m (Either b a)
    go = do
      ma <- act
      case ma of
        Just a  -> return (Right a)
        Nothing -> do
          -- If the action did not return a value, wait for a concurrent thread
          -- to signal that something has changed (may already have happened as
          -- the action was running, of course, in which case we try again
          -- immediately).
          --
          -- If there were multiple changes, then the signal will only remember
          -- that there /was/ a change, not how many of them. This is ok,
          -- however: we run the action again in this new state, no matter how
          -- many changes took place. If in that new state the action still
          -- fails, then we will wait for further changes on the next iteration.
          mCtrlMsg <- liftIO $ signalCtrlMsg
          case mCtrlMsg of
            Just ctrlMsg ->
              return (Left ctrlMsg)
            Nothing -> do
              liftIO $ takeMVar signalPokeVar
              go

{-------------------------------------------------------------------------------
  Auxiliary
-------------------------------------------------------------------------------}

orElseM :: forall m a. Monad m => [m (Maybe a)] -> m (Maybe a)
orElseM = foldr aux (return Nothing)
  where
    aux :: m (Maybe a) -> m (Maybe a) -> m (Maybe a)
    aux f g = f >>= maybe g (return . Just)

applyMVar :: MonadIO m => MVar a -> (a -> (a, b)) -> m b
applyMVar mv f = liftIO $ modifyMVar mv $ \a -> return $! f a

applyMVar_ :: MonadIO m => MVar a -> (a -> a) -> m ()
applyMVar_ mv f = liftIO $ modifyMVar_ mv $ \a -> return $! f a

-- | Execution time of an action in microseconds
type ExecutionTime = Int

timed :: MonadIO m => m a -> m (a, ExecutionTime)
timed act = do
    before <- liftIO $ getCurrentTime
    a      <- act
    after  <- liftIO $ getCurrentTime
    return (a, conv (after `diffUTCTime` before))
  where
    conv :: NominalDiffTime -> ExecutionTime
    conv t = round (realToFrac t * 1000000 :: Double)

{-------------------------------------------------------------------------------
  Wrapper for use as an OutboundQueue
-------------------------------------------------------------------------------}

newtype ClassifiedConversation peerData packingType peer m t =
    ClassifiedConversation (peer -> peerData -> Conversation packingType m t)

instance FormatMsg (ClassifiedConversation peerData packingType peer m) where
  formatMsg = flip fmap shown $ \k -> \(ClassifiedConversation _) -> k ("<<conversation>>" :: String)

-- | Use an OutboundQ as an OutboundQueue.
asOutboundQueue
    :: forall packingType peerData msg nid m .
       ( MonadIO              m
       , M.Mockable M.Async   m
       , M.Mockable M.Bracket m
       , M.Mockable M.Throw   m
       , M.Mockable M.Catch   m
       , M.Mockable M.Fork    m
       , Ord (M.ThreadId      m)
       , WithLogger           m
       , Ord nid
       )
    => OutboundQ (ClassifiedConversation peerData packingType nid m) nid
    -> (nid -> NodeId)
    -> (nid -> NodeType)
    -> (msg -> MsgType)
    -> (msg -> Origin nid)
    -> Converse packingType peerData m
    -> m (OutboundQueue packingType peerData nid msg m)
asOutboundQueue oq mkNodeId mkNodeType mkMsgType mkOrigin converse = do
    thread <- M.async $ dequeueThread oq sendMsg
    return $ OutboundQueue { oqEnqueue = enqueueIt, oqClose = M.cancel thread }
  where
    sendMsg :: SendMsg m (ClassifiedConversation peerData packingType nid m) nid
    sendMsg (ClassifiedConversation k) nid =
        converse (mkNodeId nid) (k nid)
    enqueueIt
        :: forall t .
           Set nid
        -> msg
        -> (nid -> peerData -> Conversation packingType m t)
        -> m (Map nid (m t))
    enqueueIt peers msg conversation = do
        let peers' = simplePeers ((\nid -> (mkNodeType nid, nid)) <$> Set.toList peers)
            cc = ClassifiedConversation conversation
        tlist <- enqueue oq (mkMsgType msg) cc (mkOrigin msg) peers'
        let tmap = Map.fromList tlist
        return $ fmap (>>= either M.throw return) tmap
