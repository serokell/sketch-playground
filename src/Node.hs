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

module Node (

      Node(..)
    , nodeEndPointAddress
    , NodeAction(..)
    , node

    , MessageName
    , Message (..)
    , messageName'

    , SendActions(sendTo, withConnectionTo)
    , ConversationActions(send, recv, peerData)
    , Worker
    , Listener
    , ListenerAction(..)

    , hoistListenerAction
    , hoistSendActions
    , hoistConversationActions
    , LL.NodeId(..)

    , nodeStatistics
    , LL.Statistics(..)
    , LL.PeerStatistics(..)

    ) where

import           Control.Exception          (SomeException)
import           Control.Monad              (when, unless)
import           Control.Monad.Fix          (MonadFix)
import qualified Data.Binary.Get            as Bin
import qualified Data.ByteString            as BS
import qualified Data.ByteString.Lazy       as LBS
import           Data.Map.Strict            (Map)
import qualified Data.Map.Strict            as M
import           Data.Proxy                 (Proxy (..))
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
import           Node.Internal              (ChannelIn, ChannelOut)
import qualified Node.Internal              as LL
import           Node.Message
import           System.Random              (StdGen)
import           System.Wlog                (WithLogger, logDebug, logError, logInfo)

data Node m = forall event . Node {
      nodeId         :: LL.NodeId
    , nodeEndPoint   :: NT.EndPoint m
    , nodeStatistics :: m (LL.Statistics m)
    }

nodeEndPointAddress :: Node m -> NT.EndPointAddress
nodeEndPointAddress (Node addr _ _) = LL.nodeEndPointAddress addr

data Input t = Input t | NoParse | End

type Worker packing peerData m = SendActions packing peerData m -> m ()

-- TODO: rename all `ListenerAction` -> `Listener`?
type Listener = ListenerAction

data ListenerAction packing peerData m where
  -- | A listener that handles a single isolated incoming message
  ListenerActionOneMsg
    :: ( Serializable packing msg, Message msg )
    => (peerData -> LL.NodeId -> SendActions packing peerData m -> msg -> m ())
    -> ListenerAction packing peerData m

  -- | A listener that handles an incoming bi-directional conversation.
  ListenerActionConversation
    :: ( Packable packing snd, Unpackable packing rcv, Message rcv )
    => (peerData -> LL.NodeId -> ConversationActions peerData snd rcv m -> m ())
    -> ListenerAction packing peerData m

hoistListenerAction
    :: (forall a. n a -> m a)
    -> (forall a. m a -> n a)
    -> ListenerAction packing peerData n
    -> ListenerAction packing peerData m
hoistListenerAction nat rnat (ListenerActionOneMsg f) = ListenerActionOneMsg $
    \peerData nId sendActions -> nat . f peerData nId (hoistSendActions rnat nat sendActions)
hoistListenerAction nat rnat (ListenerActionConversation f) = ListenerActionConversation $
    \peerData nId convActions -> nat $ f peerData nId (hoistConversationActions rnat convActions)

-- | Gets message type basing on type of incoming messages
listenerMessageName :: Listener packing peerData m -> MessageName
listenerMessageName (ListenerActionOneMsg (
        _ :: peerData -> LL.NodeId -> SendActions packing peerData m -> msg -> m ()
    )) = messageName (Proxy :: Proxy msg)

listenerMessageName (ListenerActionConversation (
        _ :: peerData -> LL.NodeId -> ConversationActions peerData snd rcv m -> m ()
    )) = messageName (Proxy :: Proxy rcv)

data SendActions packing peerData m = SendActions {
       -- | Send a isolated (sessionless) message to a node
       sendTo :: forall msg .
              ( Packable packing msg, Message msg )
              => LL.NodeId
              -> msg
              -> m (),

       -- | Establish a bi-direction conversation session with a node.
       withConnectionTo
           :: forall snd rcv t .
            ( Packable packing snd, Message snd, Unpackable packing rcv )
           => LL.NodeId
           -> (ConversationActions peerData snd rcv m -> m t)
           -> m t
     }

data ConversationActions peerData body rcv m = ConversationActions {
       -- | Send a message within the context of this conversation
       send     :: body -> m ()

       -- | Receive a message within the context of this conversation.
       --   'Nothing' means end of input (peer ended conversation).
     , recv     :: m (Maybe rcv)

       -- | The data associated with that peer (reported by the peer).
       --   It's in m because trying to take it may block (it may not be
       --   known yet!).
     , peerData :: m peerData
     }

hoistConversationActions
    :: (forall a. n a -> m a)
    -> ConversationActions peerData body rcv n
    -> ConversationActions peerData body rcv m
hoistConversationActions nat ConversationActions {..} =
  ConversationActions send' recv' peerData'
      where
        send' = nat . send
        recv' = nat recv
        peerData' = nat peerData

hoistSendActions
    :: (forall a. n a -> m a)
    -> (forall a. m a -> n a)
    -> SendActions packing peerData n
    -> SendActions packing peerData m
hoistSendActions nat rnat SendActions {..} = SendActions sendTo' withConnectionTo'
  where
    sendTo' nodeId msg = nat $ sendTo nodeId msg
    withConnectionTo' nodeId convActionsH =
        nat $ withConnectionTo nodeId  $ \convActions -> rnat $ convActionsH $ hoistConversationActions nat convActions

type ListenerIndex packing peerData m =
    Map MessageName (ListenerAction packing peerData m)

makeListenerIndex :: [Listener packing peerData m]
                  -> (ListenerIndex packing peerData m, [MessageName])
makeListenerIndex = foldr combine (M.empty, [])
    where
    combine action (dict, existing) =
        let name = listenerMessageName action
            (replaced, dict') = M.insertLookupWithKey (\_ _ _ -> action) name action dict
            overlapping = maybe [] (const [name]) replaced
        in  (dict', overlapping ++ existing)

-- | Send actions for a given 'LL.Node'.
nodeSendActions
    :: forall m packing peerData .
       ( Mockable Channel.Channel m, Mockable Throw m, Mockable Catch m
       , Mockable Bracket m, Mockable SharedAtomic m, Mockable SharedExclusive m
       , Mockable Async m, Ord (ThreadId m)
       , Mockable CurrentTime m, Mockable Metrics.Metrics m
       , WithLogger m, MonadFix m
       , Serializable packing peerData
       , Packable packing MessageName )
    => LL.Node packing peerData m
    -> packing
    -> SendActions packing peerData m
nodeSendActions nodeUnit packing =
    SendActions nodeSendTo nodeWithConnectionTo
  where

    nodeSendTo
        :: forall msg .
           ( Packable packing msg, Message msg )
        => LL.NodeId
        -> msg
        -> m ()
    nodeSendTo = \nodeId msg ->
        LL.withOutChannel nodeUnit nodeId $ \channelOut ->
            LL.writeChannel channelOut $ concatMap LBS.toChunks
                [ packMsg packing $ messageName' msg
                , packMsg packing msg
                ]

    nodeWithConnectionTo
        :: forall snd rcv t .
           ( Packable packing snd, Message snd, Unpackable packing rcv )
        => LL.NodeId
        -> (ConversationActions peerData snd rcv m -> m t)
        -> m t
    nodeWithConnectionTo = \nodeId f ->
        LL.withInOutChannel nodeUnit nodeId $ \peerDataVar inchan outchan -> do
            let msgName  = messageName (Proxy :: Proxy snd)
                cactions :: ConversationActions peerData snd rcv m
                cactions = nodeConversationActions nodeUnit nodeId packing (readSharedExclusive peerDataVar) inchan outchan
            LL.writeChannel outchan . LBS.toChunks $
                packMsg packing msgName
            f cactions

-- | Conversation actions for a given peer and in/out channels.
nodeConversationActions
    :: forall packing peerData snd rcv m .
       ( Mockable Throw m, Mockable Channel.Channel m, Mockable SharedExclusive m
       , WithLogger m
       , Packable packing snd
       , Unpackable packing rcv
       )
    => LL.Node packing peerData m
    -> LL.NodeId
    -> packing
    -> m peerData
    -> ChannelIn m
    -> ChannelOut m
    -> ConversationActions peerData snd rcv m
nodeConversationActions _ _ packing peerData inchan outchan =
    ConversationActions nodeSend nodeRecv peerData
    where

    nodeSend = \body -> do
        LL.writeChannel outchan . LBS.toChunks $ packMsg packing body

    nodeRecv = do
        next <- recvNext inchan packing
        case next of
            End     -> pure Nothing
            NoParse -> do
                logDebug "Unexpected end of conversation input"
                pure Nothing
            Input t -> pure (Just t)

data NodeAction packing peerData m t = NodeAction [Listener packing peerData m] (SendActions packing peerData m -> m t)

-- | Spin up a node. You must give a function to create listeners given the
--   'NodeId', and an action to do given the 'NodeId' and sending actions.
--   The node will stop and clean up once that action has completed. If at
--   this time there are any listeners running, they will be allowed to
--   finished.
node
    :: forall packing peerData m t .
       ( Mockable Fork m, Mockable Throw m, Mockable Channel.Channel m
       , Mockable SharedAtomic m, Mockable Bracket m, Mockable Catch m
       , Mockable Async m, Mockable Concurrently m
       , Ord (ThreadId m), Show (ThreadId m)
       , Mockable SharedExclusive m
       , Mockable CurrentTime m, Mockable Metrics.Metrics m
       , MonadFix m, Serializable packing MessageName, WithLogger m
       , Serializable packing peerData
       )
    => NT.Transport m
    -> StdGen
    -> packing
    -> peerData
    -> (Node m -> m (NodeAction packing peerData m t))
    -> m t
node transport prng packing peerData k = do
    rec { llnode <- LL.startNode packing peerData transport prng (handlerIn listenerIndex sendActions) (handlerInOut llnode listenerIndex)
        ; let nId = LL.nodeId llnode
        ; let endPoint = LL.nodeEndPoint llnode
        ; let nodeUnit = Node nId endPoint (LL.nodeStatistics llnode)
        ; NodeAction listeners act <- k nodeUnit
          -- Index the listeners by message name, for faster lookup.
        ; let listenerIndex :: ListenerIndex packing peerData m
              (listenerIndex, conflictingNames) = makeListenerIndex listeners
        ; let sendActions = nodeSendActions llnode packing
        }
    when (not $ null conflictingNames) $
        logError $ sformat ("Conflicting listeners registered: "%shown)
                   conflictingNames
    let unexceptional = do
            t <- act sendActions
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
    logException :: forall t . SomeException -> m t
    logException e = do
        logError $ sformat ("node stopped with exception " % shown) e
        throw e
    logNodeException :: forall t . SomeException -> m t
    logNodeException e = do
        logError $ sformat ("exception while stopping node " % shown) e
        throw e
    -- Handle incoming data from unidirectional connections: try to read the
    -- message name, use it to determine a listener, parse the body, then
    -- run the listener.
    handlerIn
        :: ListenerIndex packing peerData m
        -> SendActions packing peerData m
        -> peerData
        -> LL.NodeId
        -> ChannelIn m
        -> m ()
    handlerIn listenerIndex sendActions peerData peerId inchan = do
        input <- recvNext inchan packing
        case input of
            End -> logDebug "handerIn : unexpected end of input"
            -- TBD recurse and continue handling even after a no parse?
            NoParse -> logDebug "handlerIn : failed to parse message name"
            Input msgName -> do
                let listener = M.lookup msgName listenerIndex
                case listener of
                    Just (ListenerActionOneMsg action) -> do
                        input' <- recvNext inchan packing
                        case input' of
                            End -> logDebug "handerIn : unexpected end of input"
                            NoParse -> logDebug "handlerIn : failed to parse message body"
                            Input msgBody -> do
                                action peerData peerId sendActions msgBody
                    -- If it's a conversation listener, then that's an error, no?
                    Just (ListenerActionConversation _) -> logDebug $
                        sformat ("handlerIn : wrong listener type. Expected\
                        \unidirectional for "%shown) msgName
                    Nothing -> logDebug $
                        sformat ("handlerIn : no listener for "%shown) msgName

    -- Handle incoming data from a bidirectional connection: try to read the
    -- message name, then choose a listener and fork a thread to run it.
    handlerInOut
        :: LL.Node packing peerData m
        -> ListenerIndex packing peerData m
        -> peerData
        -> LL.NodeId
        -> ChannelIn m
        -> ChannelOut m
        -> m ()
    handlerInOut nodeUnit listenerIndex peerData peerId inchan outchan = do
        input <- recvNext inchan packing
        case input of
            End -> logDebug "handlerInOut : unexpected end of input"
            NoParse -> logDebug "handlerInOut : failed to parse message name"
            Input msgName -> do
                let listener = M.lookup msgName listenerIndex
                case listener of
                    Just (ListenerActionConversation action) ->
                        let cactions = nodeConversationActions nodeUnit peerId packing
                                (return peerData) inchan outchan
                        in  action peerData peerId cactions
                    Just (ListenerActionOneMsg _) ->  logDebug $
                        sformat ("handlerInOut : wrong listener type. Expected\
                        \bidirectional for "%shown) msgName
                    Nothing -> logDebug $
                        sformat ("handlerInOut : no listener for "%shown) msgName

recvNext
    :: ( Mockable Channel.Channel m, Unpackable packing thing )
    => ChannelIn m
    -> packing
    -> m (Input thing)
recvNext (LL.ChannelIn channel) packing = do
    mbs <- Channel.readChannel channel
    case mbs of
        Nothing -> return End
        Just bs -> do
            (trailing, outcome) <- go (Bin.pushChunk (unpackMsg packing) bs)
            unless (BS.null trailing) (Channel.unGetChannel channel (Just trailing))
            return outcome
    where
    go decoder = case decoder of
        Bin.Fail trailing _ err -> return (trailing, NoParse)
        Bin.Done trailing _ thing -> return (trailing, Input thing)
        Bin.Partial next -> do
            mbs <- Channel.readChannel channel
            case mbs of
                Nothing -> return (BS.empty, End)
                Just bs -> go (next (Just bs))
