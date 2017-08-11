{-------------------------------------------------------------------------------
  Outbound message queue

  Intended for qualified import

  > import Network.Broadcast.OutboundQ (OutboundQ)
  > import qualified Network.Broadcast.OutboundQ as OutQ
  > import Network.Broadcast.OutboundQueue.Types

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
{-# LANGUAGE TupleSections       #-}

module Network.Broadcast.OutboundQueue (
    OutboundQ -- opaque
    -- * Initialization
  , new
    -- ** Enqueueing policy
  , Precedence(..)
  , MaxAhead(..)
  , Enqueue(..)
  , EnqueuePolicy
  , defaultEnqueuePolicy
  , defaultEnqueuePolicyCore
  , defaultEnqueuePolicyRelay
  , defaultEnqueuePolicyEdgeBehindNat
  , defaultEnqueuePolicyEdgeExchange
  , defaultEnqueuePolicyEdgeP2P
    -- ** Dequeueing policy
  , RateLimit(..)
  , MaxInFlight(..)
  , Dequeue(..)
  , DequeuePolicy
  , defaultDequeuePolicy
  , defaultDequeuePolicyCore
  , defaultDequeuePolicyRelay
  , defaultDequeuePolicyEdgeBehindNat
  , defaultDequeuePolicyEdgeExchange
  , defaultDequeuePolicyEdgeP2P
    -- ** Failure policy
  , FailurePolicy
  , ReconsiderAfter(..)
  , defaultFailurePolicy
    -- * Enqueueing
  , Origin(..)
  , EnqueueTo (..)
  , enqueue
  , enqueueSync'
  , enqueueSync
  , enqueueCherished
  , clearRecentFailures
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
  , peersFromList
  , updatePeersBucket
    -- * Debugging
  , dumpState
  ) where

import Control.Concurrent
import Control.Exception
import Control.Lens
import Control.Monad
import Control.Monad.IO.Class
import Data.Either (rights)
import Data.Foldable (fold)
import Data.List (sortBy)
import Data.Map.Strict (Map)
import Data.Maybe (maybeToList)
import Data.Ord (comparing)
import Data.Text (Text)
import Data.Time
import Data.Typeable (typeOf)
import Formatting (Format, sformat, (%), shown, string)
import System.Wlog.CanLog
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set

import Network.Broadcast.OutboundQueue.Types
import Network.Broadcast.OutboundQueue.ConcurrentMultiQueue (MultiQueue)
import qualified Network.Broadcast.OutboundQueue.ConcurrentMultiQueue as MQ
import qualified Mockable as M

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
  deriving Show

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
  deriving (Show)

-- | The enqueuing policy
--
-- The enqueueing policy decides what kind of peer to send each message to,
-- how to pick alternatives, and which precedence level to assign to the
-- message. However, it does NOT decide _how many_ alternatives to pick; we
-- pick one from _each_ of the lists that we are given. It is the responsiblity
-- of the next layer up to configure these peers as desired.
--
-- TODO: Sanity check the number of forwarding sets and number of alternatives.
type EnqueuePolicy nid =
           MsgType nid  -- ^ Type of the message we want to send
        -> [Enqueue]

-- | Pick default policy given node type
--
-- NOTE: Assumes standard behind-NAT node in the case of edge nodes.
defaultEnqueuePolicy :: NodeType -> EnqueuePolicy nid
defaultEnqueuePolicy NodeCore  = defaultEnqueuePolicyCore
defaultEnqueuePolicy NodeRelay = defaultEnqueuePolicyRelay
defaultEnqueuePolicy NodeEdge  = defaultEnqueuePolicyEdgeBehindNat

-- | Default enqueue policy for core nodes
defaultEnqueuePolicyCore :: EnqueuePolicy nid
defaultEnqueuePolicyCore = go
  where
    go :: EnqueuePolicy nid
    go (MsgAnnounceBlockHeader _) = [
        EnqueueAll NodeCore  (MaxAhead 0) PHighest
      , EnqueueAll NodeRelay (MaxAhead 0) PHigh
      ]
    go MsgRequestBlockHeaders = [
        EnqueueAll NodeCore  (MaxAhead 1) PHigh
      , EnqueueAll NodeRelay (MaxAhead 1) PHigh
      ]
    go (MsgRequestBlocks _) = [
        -- We never ask for data from edge nodes
        EnqueueOne [NodeRelay, NodeCore] (MaxAhead 1) PHigh
      ]
    go (MsgMPC _) = [
        EnqueueAll NodeCore (MaxAhead 1) PMedium
        -- not sent to relay nodes
      ]
    go (MsgTransaction _) = [
        EnqueueAll NodeCore (MaxAhead 20) PLow
        -- not sent to relay nodes
      ]

-- | Default enqueue policy for relay nodes
defaultEnqueuePolicyRelay :: EnqueuePolicy nid
defaultEnqueuePolicyRelay = go
  where
    -- Enqueue policy for relay nodes
    go :: EnqueuePolicy nid
    go (MsgAnnounceBlockHeader _) = [
        EnqueueAll NodeRelay (MaxAhead 0) PHighest
      , EnqueueAll NodeCore  (MaxAhead 0) PHigh
      , EnqueueAll NodeEdge  (MaxAhead 0) PMedium
      ]
    go MsgRequestBlockHeaders = [
        EnqueueAll NodeCore  (MaxAhead 1) PHigh
      , EnqueueAll NodeRelay (MaxAhead 1) PHigh
      ]
    go (MsgRequestBlocks _) = [
        -- We never ask for blocks from edge nodes
        EnqueueOne [NodeRelay, NodeCore] (MaxAhead 1) PHigh
      ]
    go (MsgTransaction _) = [
        EnqueueAll NodeCore  (MaxAhead 20) PLow
      , EnqueueAll NodeRelay (MaxAhead 20) PLow
        -- transactions not forwarded to edge nodes
      ]
    go (MsgMPC _) = [
        -- Relay nodes never sent any MPC messages to anyone
      ]

-- | Default enqueue policy for standard behind-NAT edge nodes
defaultEnqueuePolicyEdgeBehindNat :: EnqueuePolicy nid
defaultEnqueuePolicyEdgeBehindNat = go
  where
    -- Enqueue policy for edge nodes
    go :: EnqueuePolicy nid
    go (MsgTransaction OriginSender) = [
        EnqueueAll NodeRelay (MaxAhead 1) PLow
      ]
    go (MsgTransaction (OriginForward _)) = [
        -- don't forward transactions that weren't created at this node
      ]
    go (MsgAnnounceBlockHeader _) = [
        -- not forwarded
      ]
    go MsgRequestBlockHeaders = [
        EnqueueAll NodeRelay (MaxAhead 0) PHigh
      ]
    go (MsgRequestBlocks _) = [
        -- Edge nodes can only talk to relay nodes
        EnqueueOne [NodeRelay] (MaxAhead 0) PHigh
      ]
    go (MsgMPC _) = [
        -- not relevant
      ]

-- | Default enqueue policy for exchange nodes
defaultEnqueuePolicyEdgeExchange :: EnqueuePolicy nid
defaultEnqueuePolicyEdgeExchange = go
  where
    -- Enqueue policy for edge nodes
    go :: EnqueuePolicy nid
    go (MsgTransaction OriginSender) = [
        EnqueueAll NodeRelay (MaxAhead 6) PLow
      ]
    go (MsgTransaction (OriginForward _)) = [
        -- don't forward transactions that weren't created at this node
      ]
    go (MsgAnnounceBlockHeader _) = [
        -- not forwarded
      ]
    go MsgRequestBlockHeaders = [
        EnqueueAll NodeRelay (MaxAhead 0) PHigh
      ]
    go (MsgRequestBlocks _) = [
        -- Edge nodes can only talk to relay nodes
        EnqueueOne [NodeRelay] (MaxAhead 0) PHigh
      ]
    go (MsgMPC _) = [
        -- not relevant
      ]

-- | Default enqueue policy for edge nodes using P2P
defaultEnqueuePolicyEdgeP2P :: EnqueuePolicy nid
defaultEnqueuePolicyEdgeP2P = go
  where
    -- Enqueue policy for edge nodes
    go :: EnqueuePolicy nid
    go (MsgTransaction _) = [
        EnqueueAll NodeRelay (MaxAhead 3) PLow
      ]
    go (MsgAnnounceBlockHeader _) = [
        EnqueueAll NodeRelay (MaxAhead 0) PHighest
      ]
    go MsgRequestBlockHeaders = [
        EnqueueAll NodeRelay (MaxAhead 1) PHigh
      ]
    go (MsgRequestBlocks _) = [
        -- Edge nodes can only talk to relay nodes
        EnqueueOne [NodeRelay] (MaxAhead 1) PHigh
      ]
    go (MsgMPC _) = [
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

-- | Pick default dequeue policy for a given node
--
-- NOTE: Assumes standard behind-NAT in the case of edge nodes.
defaultDequeuePolicy :: NodeType -> DequeuePolicy
defaultDequeuePolicy NodeCore  = defaultDequeuePolicyCore
defaultDequeuePolicy NodeRelay = defaultDequeuePolicyRelay
defaultDequeuePolicy NodeEdge  = defaultDequeuePolicyEdgeBehindNat

-- | Default dequeue policy for core nodes
defaultDequeuePolicyCore :: DequeuePolicy
defaultDequeuePolicyCore = go
  where
    go :: DequeuePolicy
    go NodeCore  = Dequeue NoRateLimiting (MaxInFlight 3)
    go NodeRelay = Dequeue NoRateLimiting (MaxInFlight 2)
    go NodeEdge  = error "defaultDequeuePolicy: core to edge not applicable"

-- | Dequeueing policy for relay nodes
defaultDequeuePolicyRelay :: DequeuePolicy
defaultDequeuePolicyRelay = go
  where
    go :: DequeuePolicy
    go NodeCore  = Dequeue (MaxMsgPerSec 1) (MaxInFlight 2)
    go NodeRelay = Dequeue (MaxMsgPerSec 3) (MaxInFlight 2)
    go NodeEdge  = Dequeue (MaxMsgPerSec 1) (MaxInFlight 2)

-- | Dequeueing policy for standard behind-NAT edge nodes
defaultDequeuePolicyEdgeBehindNat :: DequeuePolicy
defaultDequeuePolicyEdgeBehindNat = go
  where
    go :: DequeuePolicy
    go NodeCore  = error "defaultDequeuePolicy: edge to core not applicable"
    go NodeRelay = Dequeue (MaxMsgPerSec 1) (MaxInFlight 2)
    go NodeEdge  = error "defaultDequeuePolicy: edge to edge not applicable"

-- | Dequeueing policy for exchange edge nodes
defaultDequeuePolicyEdgeExchange :: DequeuePolicy
defaultDequeuePolicyEdgeExchange = go
  where
    go :: DequeuePolicy
    go NodeCore  = error "defaultDequeuePolicy: edge to core not applicable"
    go NodeRelay = Dequeue (MaxMsgPerSec 5) (MaxInFlight 3)
    go NodeEdge  = error "defaultDequeuePolicy: edge to edge not applicable"

-- | Dequeueing policy for P2P edge nodes
defaultDequeuePolicyEdgeP2P :: DequeuePolicy
defaultDequeuePolicyEdgeP2P = go
  where
    go :: DequeuePolicy
    go NodeCore  = error "defaultDequeuePolicy: edge to core not applicable"
    go NodeRelay = Dequeue (MaxMsgPerSec 1) (MaxInFlight 2)
    go NodeEdge  = error "defaultDequeuePolicy: edge to edge not applicable"

{-------------------------------------------------------------------------------
  Failure policy
-------------------------------------------------------------------------------}

-- | The failure policy determines what happens when a failure occurs as we send
-- a message to a particular node: how long (in sec) should we wait until we
-- consider this node to be a viable alternative again?
type FailurePolicy nid = NodeType -> MsgType nid -> SomeException -> ReconsiderAfter

-- | How long after a failure should we reconsider this node again?
newtype ReconsiderAfter = ReconsiderAfter NominalDiffTime

-- | Default failure policy
--
-- TODO: Implement proper policy
defaultFailurePolicy :: NodeType -- ^ Our node type
                     -> FailurePolicy nid
defaultFailurePolicy _ourType _theirType _msgType _err = ReconsiderAfter 200

{-------------------------------------------------------------------------------
  Thin wrapper around ConcurrentMultiQueue
-------------------------------------------------------------------------------}

-- | The values we store in the multiqueue
data Packet msg nid a = Packet {
    -- | The actual payload of the message
    packetPayload :: msg a

    -- | Type of the message
  , packetMsgType :: MsgType nid

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

-- | For each node, its most recent failure and how long we should wait before
-- trying again
type Failures nid = Map nid (UTCTime, ReconsiderAfter)

inFlightTo :: Ord nid => nid -> Lens' (InFlight nid) (Map Precedence Int)
inFlightTo nid = at nid . anon Map.empty Map.null

inFlightWithPrec :: Ord nid => nid -> Precedence -> Lens' (InFlight nid) Int
inFlightWithPrec nid prec = inFlightTo nid . at prec . anon 0 (== 0)

-- | The outbound queue (opaque data structure)
--
-- NOTE: The 'Ord' instance on the type of the buckets @buck@ determines the
-- final 'Peers' value that the queue gets every time it reads all buckets.
data OutboundQ msg nid buck = forall self .
                            ( FormatMsg msg
                            , Ord nid
                            , Show nid
                            , Show self
                            , Ord buck
                            ) => OutQ {
      -- | Node ID of the current node (primarily for debugging purposes)
      qSelf :: self

      -- | Enqueuing policy
    , qEnqueuePolicy :: EnqueuePolicy nid

      -- | Dequeueing policy
    , qDequeuePolicy :: DequeuePolicy

      -- | Failure policy
    , qFailurePolicy :: FailurePolicy nid

      -- | Messages sent but not yet acknowledged
    , qInFlight :: MVar (InFlight nid)

      -- | Messages scheduled but not yet sent
    , qScheduled :: MQ msg nid

      -- | Buckets with known peers
      --
      -- NOTE: When taking multiple MVars at the same time, qBuckets must be
      -- taken first (lock ordering).
    , qBuckets :: MVar (Map buck (Peers nid))

      -- | Recent communication failures
    , qFailures :: MVar (Failures nid)

      -- | Used to send control messages to the main thread
    , qCtrlMsg :: MVar CtrlMsg

      -- | Signal we use to wake up blocked threads
    , qSignal :: Signal CtrlMsg
    }

-- | Use a formatter to get a dump of the state.
-- Currently this just shows the known peers.
dumpState
    :: MonadIO m
    => OutboundQ msg nid buck
    -> (forall a . (Format r a) -> a)
    -> m r
dumpState outQ@OutQ{} formatter = do
    peers <- getAllPeers outQ
    let formatted = formatter format peers
    return formatted
  where
    format = "OutboundQ internal state '{"%shown%"}'"

-- | Initialize the outbound queue
--
-- NOTE: The dequeuing thread must be started separately. See 'dequeueThread'.
new :: forall m msg nid buck self.
       ( MonadIO m
       , FormatMsg msg
       , Ord nid
       , Show nid
       , Show self
       , Ord buck
       )
    => self -- ^ Showable identifier of this node, for logging purposes.
    -> EnqueuePolicy nid
    -> DequeuePolicy
    -> FailurePolicy nid
    -> m (OutboundQ msg nid buck)
new qSelf qEnqueuePolicy qDequeuePolicy qFailurePolicy = liftIO $ do
    qInFlight  <- newMVar Map.empty
    qScheduled <- MQ.new
    qBuckets   <- newMVar Map.empty
    qCtrlMsg   <- newEmptyMVar
    qFailures  <- newMVar Map.empty

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

intEnqueue :: forall m msg nid buck a. (MonadIO m, WithLogger m)
           => OutboundQ msg nid buck
           -> MsgType nid
           -> msg a
           -> Peers nid
           -> m [Packet msg nid a]
intEnqueue outQ@OutQ{..} msgType msg peers = fmap concat $
    forM (qEnqueuePolicy msgType) $ \case

      enq@EnqueueAll{..} -> do
        let fwdSets :: AllOf (Alts nid)
            fwdSets = removeOrigin (msgOrigin msgType) $
                        peers ^. peersOfType enqNodeType

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

        -- Log an error if we didn't manage to enqueue the message to any peer
        -- at all (provided that we were configured to send it to some)
        if | null fwdSets ->
               logDebug $ msgNotEnqueued enqNodeType -- This isn't an error
           | null enqueued ->
               logError $ msgEnqFailed enq fwdSets
           | otherwise ->
               logDebug $ msgEnqueued enqueued

        return enqueued

      enq@EnqueueOne{..} -> do
        let fwdSets :: [(NodeType, Alts nid)]
            fwdSets = concatMap
                        (\t -> map (t,) $ removeOrigin (msgOrigin msgType) $
                                            peers ^. peersOfType t)
                        enqNodeTypes

            sendOne :: [(NodeType, Alts nid)] -> m [Packet msg nid a]
            sendOne = fmap maybeToList
                    . orElseM
                    . map (sendFwdSet [] enqMaxAhead enqPrecedence)

        enqueued <- sendOne fwdSets

        -- Log an error if we didn't manage to enqueue the message
        if null enqueued
          then logError $ msgEnqFailed enq fwdSets
          else logDebug $ msgEnqueued enqueued

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
    removeOrigin :: Origin nid -> AllOf (Alts nid) -> AllOf (Alts nid)
    removeOrigin origin =
      case origin of
        OriginSender    -> id
        OriginForward n -> filter (not . null) . map (filter (/= n))

    msgNotEnqueued :: NodeType -> Text
    msgNotEnqueued nodeType = sformat
      ( shown
      % ": message "
      % formatMsg
      % " not enqueued to any nodes of type "
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

    msgEnqFailed :: Show fwdSets => Enqueue -> fwdSets -> Text
    msgEnqFailed enq fwdSets =
      sformat ( shown
              % ": enqueue instruction " % shown
              % " failed to enqueue message " % formatMsg
              % " to forwarding sets " % shown
              )
              qSelf enq msg fwdSets

-- | Node ID with current stats needed to pick a node from a list of alts
data NodeWithStats nid = NodeWithStats {
      nstatsId      :: nid  -- ^ Node ID
    , nstatsFailure :: Bool -- ^ Recent failure?
    , nstatsAhead   :: Int  -- ^ Number of messages ahead
    }

-- | Compute current node statistics
nodeWithStats :: (MonadIO m, WithLogger m)
              => OutboundQ msg nid buck
              -> Precedence -- ^ For determining number of messages ahead
              -> nid
              -> m (NodeWithStats nid)
nodeWithStats outQ prec nstatsId = do
    nstatsAhead   <- countAhead outQ nstatsId prec
    nstatsFailure <- hasRecentFailure outQ nstatsId
    return NodeWithStats{..}

-- | Choose an appropriate node from a list of alternatives
--
-- All alternatives are assumed to be of the same type; we prefer to pick
-- nodes with a smaller number of messages ahead.
pickAlt :: forall m msg nid buck. (MonadIO m, WithLogger m)
        => OutboundQ msg nid buck
        -> MaxAhead
        -> Precedence
        -> [nid]
        -> m (Maybe nid)
pickAlt outQ@OutQ{} maxAhead prec alts = do
    alts' <- mapM (nodeWithStats outQ prec) alts
    orElseM [
        if | nstatsFailure -> do
               logDebug $ msgFailure nstatsId
               return Nothing
           | MaxAhead n <- maxAhead, nstatsAhead > n -> do
               logDebug $ msgAhead nstatsId nstatsAhead n
               return Nothing
           | otherwise -> do
               return $ Just nstatsId
      | NodeWithStats{..} <- sortBy (comparing nstatsAhead) alts'
      ]
  where
    msgFailure :: nid -> Text
    msgFailure = sformat $
          "Rejected alternative " % shown
        % " as it has a recent failure"

    msgAhead :: nid -> Int -> Int -> Text
    msgAhead = sformat $
          "Rejected alternative " % shown
        % " as it has " % shown
        % " messages ahead, which is more than the maximum " % shown

-- | Check how many messages are currently ahead
--
-- NOTE: This is of course a highly dynamic value; by the time we get to
-- actually enqueue the message the value might be slightly different. Bounds
-- are thus somewhat fuzzy.
countAhead :: forall m msg nid buck. (MonadIO m, WithLogger m)
           => OutboundQ msg nid buck -> nid -> Precedence -> m Int
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

intDequeue :: forall m msg nid buck. WithLogger m
           => OutboundQ msg nid buck
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
        ta <- timed $ M.try $ unmask $
                sendMsg (packetPayload p) (packetDestId p)
        -- TODO: Do we want to acknowledge the send here? Or after we have
        -- reduced qInFlight? The latter is safer (means the next enqueue is
        -- less likely to be rejected because there are no peers available with
        -- a small enough number of messages " ahead ") but it would mean we
        -- can only acknowledge the send after the delay, which seems
        -- undesirable.
        liftIO $ putMVar (packetSent p) (timedResult ta)
        unmask $ applyRateLimit qDequeuePolicy (packetDestType p) (timedDuration ta)
        case timedResult ta of
          Left err -> do
            logWarning $ msgSendFailed p err
            intFailure outQ p (timedStart ta) err
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
    msgSendFailed Packet{..} (SomeException err) =
      sformat ( shown % ": sending " % formatMsg % " to " % shown
              % " failed with " % string % " :: " % shown)
              qSelf
              packetPayload
              packetDestId
              (displayException err)
              (typeOf err)

{-------------------------------------------------------------------------------
  Interpreter for failure policy
-------------------------------------------------------------------------------}

-- | What do we know when sending a message fails?
--
-- NOTE: Since we don't send messages to nodes listed in failures, we can
-- assume that there isn't an existing failure here.
intFailure :: forall m msg nid buck a. MonadIO m
           => OutboundQ msg nid buck
           -> Packet msg nid a  -- ^ Packet we failed to send
           -> UTCTime           -- ^ Time of the send
           -> SomeException     -- ^ The exception thrown by the send action
           -> m ()
intFailure OutQ{..} p sendStartTime err = do
    applyMVar_ qFailures $
      Map.insert (packetDestId p) (
          sendStartTime
        , qFailurePolicy (packetDestType p)
                         (packetMsgType  p)
                         err
        )

hasRecentFailure :: MonadIO m => OutboundQ msg nid buck -> nid -> m Bool
hasRecentFailure OutQ{..} nid = do
    mFailure <- liftIO $ Map.lookup nid <$> readMVar qFailures
    case mFailure of
      Nothing ->
        return False
      Just (timeOfFailure, ReconsiderAfter n) -> do
        now <- liftIO $ getCurrentTime
        return $ now < addUTCTime n timeOfFailure

-- | Reset internal statistics about failed nodes
--
-- This is useful when we know for external reasons that nodes may be reachable
-- again, allowing the outbound queue to enqueue messages to those nodes.
clearRecentFailures :: MonadIO m => OutboundQ msg nid buck -> m ()
clearRecentFailures OutQ{..} = applyMVar_ qFailures $ const Map.empty

{-------------------------------------------------------------------------------
  Public interface to enqueing
-------------------------------------------------------------------------------}

-- | Queue a message to be sent, but don't wait (asynchronous API)
enqueue :: (MonadIO m, WithLogger m)
        => OutboundQ msg nid buck
        -> MsgType nid -- ^ Type of the message being sent
        -> msg a       -- ^ Message to send
        -> m [(nid, m (Either SomeException a))]
enqueue outQ msgType msg = do
    waitAsync <$> intEnqueueTo outQ msgType msg (msgEnqueueTo msgType)

-- | Queue a message and wait for it to have been sent
--
-- Returns for each node that the message got enqueued the result of the
-- send action (or an exception if it failed).
enqueueSync' :: (MonadIO m, WithLogger m)
             => OutboundQ msg nid buck
             -> MsgType nid -- ^ Type of the message being sent
             -> msg a       -- ^ Message to send
             -> m [(nid, Either SomeException a)]
enqueueSync' outQ msgType msg = do
    promises <- enqueue outQ msgType msg
    traverse (\(nid, wait) -> (,) nid <$> wait) promises

-- | Queue a message and wait for it to have been sent
--
-- We wait for the message to have been sent (successfully or unsuccessfully)
-- to all the peers it got enqueued to. Like in the asynchronous API,
-- warnings will be logged when individual sends fail. Additionally, we will
-- log an error when /all/ sends failed (this doesn't currently happen in the
-- asynchronous API).
enqueueSync :: forall m msg nid buck a. (MonadIO m, WithLogger m)
            => OutboundQ msg nid buck
            -> MsgType nid -- ^ Type of the message being sent
            -> msg a       -- ^ Message to send
            -> m ()
enqueueSync outQ msgType msg =
    warnIfNotOneSuccess outQ msg $ enqueueSync' outQ msgType msg

-- | Enqueue a message which really should not get lost
--
-- Returns 'True' if the message was successfully sent.
enqueueCherished :: forall m msg nid buck a. (MonadIO m, WithLogger m)
                 => OutboundQ msg nid buck
                 -> MsgType nid -- ^ Type of the message being sent
                 -> msg a       -- ^ Message to send
                 -> m Bool
enqueueCherished outQ msgType msg =
    cherish outQ $ enqueueSync' outQ msgType msg

{-------------------------------------------------------------------------------
  Internal generalization of the enqueueing API
-------------------------------------------------------------------------------}

-- | Enqueue message to the specified set of peers
intEnqueueTo :: (MonadIO m, WithLogger m)
             => OutboundQ msg nid buck
             -> MsgType nid
             -> msg a
             -> EnqueueTo nid
             -> m [Packet msg nid a]
intEnqueueTo outQ@OutQ{} msgType msg enqTo = do
    peers <- getAllPeers outQ
    intEnqueue outQ msgType msg (restriction peers)
  where
    restriction = case enqTo of
      EnqueueToAll -> id
      EnqueueToSubset peers' -> restrictPeers peers'

waitAsync :: MonadIO m
          => [Packet msg nid a] -> [(nid, m (Either SomeException a))]
waitAsync = map $ \Packet{..} -> (packetDestId, liftIO $ readMVar packetSent)

-- | Make sure a synchronous send succeeds to at least one peer
warnIfNotOneSuccess :: forall m msg nid buck a. (MonadIO m, WithLogger m)
                    => OutboundQ msg nid buck
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
cherish :: forall m msg nid buck a. (MonadIO m, WithLogger m)
        => OutboundQ msg nid buck
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
dequeueThread :: forall m msg nid buck. (
                   MonadIO              m
                 , M.Mockable M.Bracket m
                 , M.Mockable M.Catch   m
                 , M.Mockable M.Async   m
                 , M.Mockable M.Fork    m
                 , Ord (M.ThreadId      m)
                 , WithLogger           m
                 )
              => OutboundQ msg nid buck -> SendMsg m msg nid -> m ()
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
waitShutdown :: MonadIO m => OutboundQ msg nid buck -> m ()
waitShutdown OutQ{..} = liftIO $ do
    ack <- newEmptyMVar
    putMVar qCtrlMsg $ Shutdown ack
    poke qSignal
    takeMVar ack

-- | Wait for all messages currently enqueued to have been sent
flush :: MonadIO m => OutboundQ msg nid buck -> m ()
flush OutQ{..} = liftIO $ do
    ack <- newEmptyMVar
    putMVar qCtrlMsg $ Flush ack
    poke qSignal
    takeMVar ack

{-------------------------------------------------------------------------------
  Buckets

  NOTE: Behind NAT nodes: Edge nodes behind NAT can contact a relay node to ask
  to be notified of messages. The listener on the relay node should call
  'addKnownPeers' on its outbound queue to effectively subscribe the edge node
  that contacted it. Then the conversation should remain open, so that the
  (heavy-weight) TCP connection between the edge node and the relay node is
  kept open. When the edge node disappears the listener thread on the relay
  node should call 'removeKnownPeer' to remove the edge node from its outbound
  queue again.
-------------------------------------------------------------------------------}

-- | Internal method: read all buckets of peers
getAllPeers :: MonadIO m => OutboundQ msg nid buck -> m (Peers nid)
getAllPeers OutQ{..} = liftIO $ fold <$> readMVar qBuckets

-- | Update a bucket of peers
--
-- Any messages to peers that no longer exist in _any_ bucket will be
-- removed from the queue.
--
-- It is assumed that every bucket is modified by exactly one thread.
-- Provided that assumption is true, then we guarantee the invariant that if
-- thread @T@ adds node @n@ to its (private) bucket and then enqueues a message,
-- that message will not be deleted because another thread happened to remove
-- node @n@ from _their_ bucket.
updatePeersBucket :: forall m msg nid buck. MonadIO m
                  => OutboundQ msg nid buck
                  -> buck
                  -> (Peers nid -> Peers nid)
                  -> m ()
updatePeersBucket OutQ{..} buck f = liftIO $
    modifyMVar_ qBuckets $ \buckets -> do
      let before   = fold buckets
          buckets' = Map.alter f' buck buckets
          after    = fold buckets'
          removed  = peersToSet before Set.\\ peersToSet after
      forM_ removed $ \nid -> do
        applyMVar_ qInFlight $ at nid .~ Nothing
        applyMVar_ qFailures $ Map.delete nid
        MQ.removeAllIn (KeyByDest nid) qScheduled
      return buckets'
  where
    f' :: Maybe (Peers nid) -> Maybe (Peers nid)
    f' Nothing      = Just $ f mempty
    f' (Just peers) = Just $ f peers

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

data Timed a = Timed {
      timedResult   :: a
    , timedStart    :: UTCTime
    , timedDuration :: ExecutionTime
    }

timed :: MonadIO m => m a -> m (Timed a)
timed act = do
    before <- liftIO $ getCurrentTime
    a      <- act
    after  <- liftIO $ getCurrentTime
    return Timed{
        timedResult   = a
      , timedStart    = before
      , timedDuration = conv (after `diffUTCTime` before)
      }
  where
    conv :: NominalDiffTime -> ExecutionTime
    conv t = round (realToFrac t * 1000000 :: Double)
