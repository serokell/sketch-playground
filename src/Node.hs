{-# OPTIONS_GHC -fno-warn-name-shadowing #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GADTSyntax                 #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE RecursiveDo                #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE BangPatterns               #-}

module Node (

      Node(..)
    , LL.NodeId(..)
    , LL.NodeEnvironment(..)
    , LL.defaultNodeEnvironment
    , LL.ReceiveDelay
    , LL.noReceiveDelay
    , LL.constantReceiveDelay
    , nodeEndPointAddress
    , NodeAction(..)
    , node

    , LL.NodeEndPoint(..)
    , simpleNodeEndPoint
    , manualNodeEndPoint

    , LL.NodeState(..)

    , MessageName
    , Message (..)
    , messageName'

    , Conversation(..)
    , SendActions(withConnectionTo, enqueueConversation)
    , enqueueConversation'
    , waitForConversations
    , ConversationActions(send, recv)
    , Worker
    , Listener (..)
    , ListenerAction

    , hoistListenerAction
    , hoistListener
    , hoistSendActions
    , hoistConversationActions

    , LL.Statistics(..)
    , LL.PeerStatistics(..)

    , LL.Timeout(..)

    ) where

import           Control.Exception          (SomeException, Exception)
import           Control.Monad              (unless, when)
import           Control.Monad.Fix          (MonadFix)
import qualified Data.ByteString            as BS
import           Data.Map.Strict            (Map)
import qualified Data.Map.Strict            as M
import           Data.Set                   (Set)
import           Data.Proxy                 (Proxy (..))
import           Data.Typeable              (Typeable)
import           Data.Word                  (Word32)
import           Formatting                 (sformat, shown, (%))
import qualified Mockable.Channel           as Channel
import           Mockable.Class
import           Mockable.Concurrent
import           Mockable.CurrentTime
import           Mockable.Exception
import qualified Mockable.Metrics           as Metrics
import           Mockable.SharedAtomic
import           Mockable.SharedExclusive
import qualified Network.Transport.Abstract as NT
import           Node.Conversation
import           Node.OutboundQueue
import           Node.Internal              (ChannelIn, ChannelOut)
import qualified Node.Internal              as LL
import           Node.Message.Class         (Serializable (..), MessageName,
                                             Message (..), messageName',
                                             Packing, pack, unpack)
import           Node.Message.Decoder       (Decoder (..), DecoderStep (..), continueDecoding)
import           System.Random              (StdGen)
import           System.Wlog                (WithLogger, logDebug, logError, logInfo)

data Node m = Node {
      nodeId         :: LL.NodeId
    , nodeEndPoint   :: NT.EndPoint m
    , nodeStatistics :: m (LL.Statistics m)
    }

nodeEndPointAddress :: Node m -> NT.EndPointAddress
nodeEndPointAddress (Node addr _ _) = LL.nodeEndPointAddress addr

data Input t = Input t | End

data LimitExceeded = LimitExceeded
  deriving (Show, Typeable)

instance Exception LimitExceeded

data NoParse = NoParse
  deriving (Show, Typeable)

instance Exception NoParse

type Worker packing peerData peer msgClass m = SendActions packing peerData peer msgClass m -> m ()

-- | A ListenerAction with existential snd and rcv types and suitable
--   constraints on them.
data Listener packingType peerData peer msgClass m where
  Listener
    :: ( Serializable packingType snd, Serializable packingType rcv, Message rcv )
    => ListenerAction packingType peerData peer msgClass snd rcv m
    -> Listener packingType peerData peer msgClass m

-- | A listener that handles an incoming bi-directional conversation.
type ListenerAction packingType peerData peer msgClass snd rcv m =
       -- TODO do not take the peer data here, it's already in scope because
       -- the listeners are given as a function of the remote peer's
       -- peer data. This remains just because cardano-sl will need a big change
       -- to use it properly.
       peerData
    -> LL.NodeId
    -> SendActions packingType peerData peer msgClass m
    -> ConversationActions snd rcv m
    -> m ()

hoistListenerAction
    :: ( Functor n )
    => (forall a. n a -> m a)
    -> (forall a. m a -> n a)
    -> ListenerAction packingType peerData peer msgClass snd rcv n
    -> ListenerAction packingType peerData peer msgClass snd rcv m
hoistListenerAction nat rnat f =
    \peerData nId sendActions convActions ->
        nat $ f peerData nId (hoistSendActions rnat nat sendActions)
                             (hoistConversationActions rnat convActions)

hoistListener
    :: ( Functor n )
    => (forall a. n a -> m a)
    -> (forall a. m a -> n a)
    -> Listener packing peerData peer msgClass n
    -> Listener packing peerData peer msgClass m
hoistListener nat rnat (Listener la) = Listener $ hoistListenerAction nat rnat la

-- | Gets message type basing on type of incoming messages
listenerMessageName :: Listener packing peerData peer msgClass m -> MessageName
listenerMessageName (Listener (
        _ :: peerData -> LL.NodeId -> SendActions packing peerData peer msgClass m -> ConversationActions snd rcv m -> m ()
    )) = messageName (Proxy :: Proxy rcv)

data SendActions packing peerData peer msgClass m = SendActions {
       -- Skip the outbound queue and directly do a conversation with one
       -- peer.
       withConnectionTo :: forall t .
              LL.NodeId
           -> (peerData -> Conversation packing m t)
           -> m t

       -- Schedule a conversation with some peers. The choice of /which/ peers
       -- to converse with is primarily /not/ up to the caller, but is based on
       -- the policy that the queue was set up with. The policy chooses the
       -- peers to converse with based on the supplied message class (but also
       -- on separate routing information and dynamic network conditions).
       --
       -- The parameter with a set of peers simply provides additional peers
       -- that the policy can consider: they may or may not actually be used.
       --
       -- The action returns promptly, once the conversation has been placed in
       -- the outbound queue. The resulting 'Map' contains an entry for each
       -- peer that the conversation was actually enqueued for (i.e. the
       -- outcome of the routing policy). It is possible for this map to be
       -- empty, if no peer could be found to send to. This usually indicates a
       -- failure.
       --
       -- The result 'Map' values are each an action to wait for the
       -- conversation to be completed. They return the conversation result or
       -- throw an exception if the conversation itself failed.
       --
       -- This way, if you ignore the 'Map' result then the enqueue is
       -- asynchronous, but if you traverse the Map results then it is of
       -- course synchronous.
     , enqueueConversation :: forall t .
              Set peer
           -> msgClass
           -> (peer -> peerData -> Conversation packing m t)
           -> m (Map peer (m t))
     }

-- | Synchronous variant of enqueueConversation. Does not return until all of
-- the conversation are finished.
enqueueConversation'
    :: ( Monad m )
    => SendActions packing peerData peer msgClass m
    -> Set peer
    -> msgClass
    -> (peer -> peerData -> Conversation packing m t)
    -> m (Map peer t)
enqueueConversation' sendActions peers msgClass k =
    enqueueConversation sendActions peers msgClass k >>= waitForConversations

waitForConversations :: Applicative m => Map peer (m t) -> m (Map peer t)
waitForConversations = sequenceA

hoistSendActions
    :: forall packing peerData peer msgClass n m .
       ( Functor m )
    => (forall a. n a -> m a)
    -> (forall a. m a -> n a)
    -> SendActions packing peerData peer msgClass n
    -> SendActions packing peerData peer msgClass m
hoistSendActions nat rnat SendActions {..} = SendActions withConnectionTo' enqueueConversation'
  where
    withConnectionTo'
        :: forall t . LL.NodeId -> (peerData -> Conversation packing m t) -> m t
    withConnectionTo' nodeId k = nat $ withConnectionTo nodeId $ \peerData -> case k peerData of
        Conversation l -> Conversation $ \cactions -> rnat (l (hoistConversationActions nat cactions))

    enqueueConversation'
        :: forall t .
           Set peer
        -> msgClass
        -> (peer -> peerData -> Conversation packing m t)
        -> m (Map peer (m t))
    enqueueConversation' peers msgClass k = (fmap . fmap) nat $ nat $ enqueueConversation peers msgClass $
        \peer peerData -> case k peer peerData of
            Conversation l -> Conversation $ \cactions ->
                rnat (l (hoistConversationActions nat cactions))

type ListenerIndex packing peerData peer msgClass m =
    Map MessageName (Listener packing peerData peer msgClass m)

makeListenerIndex :: [Listener packing peerData peer msgClass m]
                  -> (ListenerIndex packing peerData peer msgClass m, [MessageName])
makeListenerIndex = foldr combine (M.empty, [])
    where
    combine action (dict, existing) =
        let name = listenerMessageName action
            (replaced, dict') = M.insertLookupWithKey (\_ _ _ -> action) name action dict
            overlapping = maybe [] (const [name]) replaced
        in  (dict', overlapping ++ existing)

nodeConverse
    :: forall m packing peerData .
       ( Mockable Channel.Channel m, Mockable Throw m, Mockable Catch m
       , Mockable Bracket m, Mockable SharedAtomic m, Mockable SharedExclusive m
       , Mockable Async m, Ord (ThreadId m)
       , Mockable CurrentTime m, Mockable Metrics.Metrics m
       , Mockable Delay m
       , WithLogger m, MonadFix m
       , Serializable packing peerData
       , Serializable packing MessageName )
    => LL.Node packing peerData m
    -> Packing packing m
    -> Converse packing peerData m
nodeConverse nodeUnit packing = nodeConverse
  where

    mtu = LL.nodeMtu (LL.nodeEnvironment nodeUnit)

    nodeConverse
        :: forall t .
           LL.NodeId
        -> (peerData -> Conversation packing m t)
        -> m t
    nodeConverse = \nodeId k ->
        LL.withInOutChannel nodeUnit nodeId $ \peerData inchan outchan -> case k peerData of
            Conversation (converse :: ConversationActions snd rcv m -> m t) -> do
                let msgName = messageName (Proxy :: Proxy snd)
                    cactions :: ConversationActions snd rcv m
                    cactions = nodeConversationActions nodeUnit nodeId packing inchan outchan
                pack packing msgName >>= LL.writeMany mtu outchan
                converse cactions


-- | Send actions for a given 'LL.Node'.
nodeSendActions
    :: forall m packing peerData peer msgClass .
       ( Mockable Channel.Channel m, Mockable Throw m, Mockable Catch m
       , Mockable Bracket m, Mockable SharedAtomic m, Mockable SharedExclusive m
       , Mockable Async m, Ord (ThreadId m)
       , Mockable CurrentTime m, Mockable Metrics.Metrics m
       , Mockable Delay m
       , WithLogger m, MonadFix m
       , Serializable packing peerData
       , Serializable packing MessageName )
    => Converse packing peerData m
    -> (forall t . Set peer -> msgClass -> (peer -> peerData -> Conversation packing m t) -> m (Map peer (m t)))
    -> SendActions packing peerData peer msgClass m
nodeSendActions converse enqueue =
    SendActions nodeWithConnectionTo nodeEnqueueConversation
  where

    nodeWithConnectionTo
        :: forall t .
           LL.NodeId
        -> (peerData -> Conversation packing m t)
        -> m t
    nodeWithConnectionTo = converse

    -- Implementing this will require access to some OutboundQueue.
    nodeEnqueueConversation
        :: forall t .
           Set peer
        -> msgClass
        -> (peer -> peerData -> Conversation packing m t)
        -> m (Map peer (m t))
    nodeEnqueueConversation = enqueue

-- | Conversation actions for a given peer and in/out channels.
nodeConversationActions
    :: forall packing peerData snd rcv m .
       ( Mockable Throw m, Mockable Channel.Channel m, Mockable SharedExclusive m
       , WithLogger m
       , Serializable packing snd
       , Serializable packing rcv
       )
    => LL.Node packing peerData m
    -> LL.NodeId
    -> Packing packing m
    -> ChannelIn m
    -> ChannelOut m
    -> ConversationActions snd rcv m
nodeConversationActions node _ packing inchan outchan =
    ConversationActions nodeSend nodeRecv
    where

    mtu = LL.nodeMtu (LL.nodeEnvironment node)

    nodeSend = \body ->
        pack packing body >>= LL.writeMany mtu outchan

    nodeRecv :: Word32 -> m (Maybe rcv)
    nodeRecv limit = do
        next <- recvNext packing (fromIntegral limit :: Int) inchan
        case next of
            End     -> pure Nothing
            Input t -> pure (Just t)

data NodeAction packing peerData peer msgClass m t =
    NodeAction (peerData -> [Listener packing peerData peer msgClass m])
               (SendActions packing peerData peer msgClass m -> m t)

simpleNodeEndPoint
    :: NT.Transport m
    -> m (LL.Statistics m)
    -> LL.NodeEndPoint m
simpleNodeEndPoint transport _ = LL.NodeEndPoint {
      newNodeEndPoint = NT.newEndPoint transport
    , closeNodeEndPoint = NT.closeEndPoint
    }

manualNodeEndPoint
    :: ( Applicative m )
    => NT.EndPoint m
    -> m (LL.Statistics m)
    -> LL.NodeEndPoint m
manualNodeEndPoint ep _ = LL.NodeEndPoint {
      newNodeEndPoint = pure $ Right ep
    , closeNodeEndPoint = NT.closeEndPoint
    }

-- | Spin up a node. You must give a function to create listeners given the
--   'NodeId', and an action to do given the 'NodeId' and sending actions.
--
--   The 'NodeAction' must be lazy in the components of the 'Node' passed to
--   it. Its 'NodeId', for instance, may be useful for the listeners, but is
--   not defined until after the node's end point is created, which cannot
--   happen until the listeners are defined--as soon as the end point is brought
--   up, traffic may come in and cause a listener to run, so they must be
--   defined first.
--
--   The node will stop and clean up once that action has completed. If at
--   this time there are any listeners running, they will be allowed to
--   finish.
node
    :: forall packing peerData peer msgClass m t .
       ( Mockable Fork m, Mockable Throw m, Mockable Channel.Channel m
       , Mockable SharedAtomic m, Mockable Bracket m, Mockable Catch m
       , Mockable Async m, Mockable Concurrently m
       , Ord (ThreadId m), Show (ThreadId m)
       , Mockable SharedExclusive m
       , Mockable Delay m
       , Mockable CurrentTime m, Mockable Metrics.Metrics m
       , MonadFix m, Serializable packing MessageName, WithLogger m
       , Serializable packing peerData
       )
    => (m (LL.Statistics m) -> LL.NodeEndPoint m)
    -> (m (LL.Statistics m) -> LL.ReceiveDelay m)
    -> (m (LL.Statistics m) -> LL.ReceiveDelay m)
    -> (Converse packing peerData m -> m (OutboundQueue packing peerData peer msgClass m))
    -- ^ How to enqueue and dequeue outbound conversations.
    -> StdGen
    -> Packing packing m
    -> peerData
    -> LL.NodeEnvironment m
    -> (Node m -> NodeAction packing peerData peer msgClass m t)
    -> m t
node mkEndPoint mkReceiveDelay mkConnectDelay mkOq prng packing peerData nodeEnv k = do
    rec { let nId = LL.nodeId llnode
        ; let endPoint = LL.nodeEndPoint llnode
        ; let nodeUnit = Node nId endPoint (LL.nodeStatistics llnode)
        ; let NodeAction mkListeners act = k nodeUnit
          -- Index the listeners by message name, for faster lookup.
          -- TODO: report conflicting names, or statically eliminate them using
          -- DataKinds and TypeFamilies.
        ; let listenerIndices :: peerData -> ListenerIndex packing peerData peer msgClass m
              listenerIndices = fmap (fst . makeListenerIndex) mkListeners
        ; let converse = nodeConverse llnode packing
        ; let sendActions = nodeSendActions converse (oqEnqueue oq)
        ; oq <- mkOq converse
        ; llnode <- LL.startNode
              packing
              peerData
              (mkEndPoint . LL.nodeStatistics)
              (mkReceiveDelay . LL.nodeStatistics)
              (mkConnectDelay . LL.nodeStatistics)
              prng
              nodeEnv
              (handlerInOut llnode listenerIndices sendActions)
        }
    let unexceptional = do
            t <- act sendActions `finally` oqClose oq
            logNormalShutdown
            (LL.stopNode llnode `catch` logNodeException)
            return t
    unexceptional
        `catch` logException
        `onException` (LL.stopNode llnode `catch` logNodeException)
  where
    logNormalShutdown :: m ()
    logNormalShutdown =
        logInfo $ sformat ("node stopping normally")
    logException :: forall s . SomeException -> m s
    logException e = do
        logError $ sformat ("node stopped with exception " % shown) e
        throw e
    logNodeException :: forall s . SomeException -> m s
    logNodeException e = do
        logError $ sformat ("exception while stopping node " % shown) e
        throw e
    -- Handle incoming data from a bidirectional connection: try to read the
    -- message name, then choose a listener and fork a thread to run it.
    handlerInOut
        :: LL.Node packing peerData m
        -> (peerData -> ListenerIndex packing peerData peer msgClass m)
        -> SendActions packing peerData peer msgClass m
        -> peerData
        -> LL.NodeId
        -> ChannelIn m
        -> ChannelOut m
        -> m ()
    handlerInOut nodeUnit listenerIndices sactions peerData peerId inchan outchan = do
        let listenerIndex = listenerIndices peerData
        input <- recvNext packing messageNameSizeLimit inchan
        case input of
            End -> logDebug "handlerInOut : unexpected end of input"
            Input msgName -> do
                let listener = M.lookup msgName listenerIndex
                case listener of
                    Just (Listener action) ->
                        let cactions = nodeConversationActions nodeUnit peerId packing inchan outchan
                        in  action peerData peerId sactions cactions
                    Nothing -> error ("handlerInOut : no listener for " ++ show msgName)
    -- Arbitrary limit on the message size...
    -- TODO make it configurable I guess.
    messageNameSizeLimit :: Int
    messageNameSizeLimit = 256

-- | Try to receive and parse the next message, subject to a limit on the
--   number of bytes which will be read.
recvNext
    :: ( Mockable Channel.Channel m
       , Mockable Throw m
       , Serializable packing thing
       )
    => Packing packing m
    -> Int
    -> ChannelIn m
    -> m (Input thing)
recvNext packing limit (LL.ChannelIn channel) = do
    -- Check whether the channel is depleted and End if so. Otherwise, push
    -- the bytes into the type's decoder and try to parse it before reaching
    -- the byte limit.
    mbs <- Channel.readChannel channel
    case mbs of
        Nothing -> return End
        Just bs -> do
            -- limit' is the number of bytes that 'go' is allowed to pull.
            -- It's assumed that reading from the channel will bring in at most
            -- some limited number of bytes, so 'go' may bring in at most this
            -- many more than the limit.
            let limit' = limit - BS.length bs
            decoderStep <- runDecoder (unpack packing)
            (trailing, outcome) <- continueDecoding decoderStep bs >>= go limit'
            unless (BS.null trailing) (Channel.unGetChannel channel (Just trailing))
            return outcome
  where
    go !remaining decoderStep = case decoderStep of
        -- TODO use the error message in the exception.
        Fail _ _ _ -> throw NoParse
        Done trailing _ thing -> return (trailing, Input thing)
        Partial next -> do
            when (remaining <= 0) (throw LimitExceeded)
            mbs <- Channel.readChannel channel
            case mbs of
                Nothing -> runDecoder (next Nothing) >>= go remaining
                Just bs ->
                    let remaining' = remaining - BS.length bs
                    in  runDecoder (next (Just bs)) >>= go remaining'
