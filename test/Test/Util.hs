{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecursiveDo           #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}

module Test.Util
       ( Parcel (..)
       , Payload (..)
       , HeavyParcel (..)

       , TestState (..)
       , mkTestState
       , expected
       , fails
       , modifyTestState
       , addFail
       , newWork

       , throwLeft

       , TalkStyle (..)
       , sendAll
       , receiveAll

       , deliveryTest
       ) where

import           Control.Concurrent.STM      (STM, atomically, check)
import           Control.Concurrent.STM.TVar (TVar, newTVarIO, readTVar, writeTVar)
import           Control.Exception           (Exception, SomeException (..))
import           Control.Lens                (makeLenses, (%=))
import           Control.Monad               (forM_, void)
import           Control.Monad.IO.Class      (MonadIO (..))
import           Control.Monad.State         (StateT)
import           Data.Binary                 (Binary (..))
import qualified Data.ByteString             as LBS
import           Data.Foldable               (for_)
import qualified Data.List                   as L
import qualified Data.Set                    as S
import           Data.Void                   (Void)
import           GHC.Generics                (Generic)
import           Mockable.Concurrent         (delay, fork, for, forConcurrently)
import           Mockable.Exception          (catch, throw)
import           Mockable.Production         (Production (..))
import           Network.Transport.Abstract  (closeTransport)
import           Network.Transport.Concrete.TCP (concreteTCP)
import qualified Network.Transport.TCP       as TCP
import           Serokell.Util.Concurrent    (modifyTVarS)
import           System.Random               (mkStdGen)
import           Test.QuickCheck             (Property)
import           Test.QuickCheck.Arbitrary   (Arbitrary (..))
import           Test.QuickCheck.Gen         (choose)
import           Test.QuickCheck.Modifiers   (getLarge)
import           Test.QuickCheck.Property    (Testable (..), failed, reason, succeeded)

import           Node                        (ConversationActions (..), Listener,
                                             ListenerAction (..), Message (..),
                                             NodeId, SendActions (..),
                                             Worker, nodeId, node, NodeAction(..))
import           Message.Message             (BinaryP (..))
import           Data.Time.Units              (fromMicroseconds)


-- * Parcel

data Payload = Payload Int
    deriving (Eq, Ord, Show)

instance Binary Payload where
    put (Payload size) = put $ LBS.replicate size 7
    get = Payload . LBS.length <$> get

data Parcel = Parcel
    { parcelNo  :: Int
    , payload   :: Payload
    } deriving (Eq, Ord, Show, Generic)

instance Binary Parcel
instance Message Parcel where
    messageName _ = "Parcel"
    formatMessage _ = "Parcel"

instance Arbitrary Parcel where
    arbitrary = Parcel
            <$> (getLarge <$> arbitrary)
            <*> pure (Payload 0)

newtype HeavyParcel = HeavyParcel
    { getHeavyParcel :: Parcel
    } deriving (Eq, Ord, Show, Binary)

instance Arbitrary HeavyParcel where
    arbitrary = mkHeavy <$> arbitrary <*> choose (0, 99000)
      where
        mkHeavy parcel size = HeavyParcel parcel { payload = Payload size }


-- * TestState

data TestState = TestState
    { _fails         :: [String]
    , _expected      :: S.Set Parcel
    }

mkTestState :: TestState
mkTestState = TestState
    { _fails         = []
    , _expected      = S.empty
    }

makeLenses ''TestState

instance Testable TestState where
    property TestState{..}
        | not $ null _fails      = property failed
            { reason = "Fails: \n" ++ L.intercalate "\n" (("\t" ++) <$> _fails) }

        | not $ S.null _expected = property failed
            { reason = "Missed messages: " ++ show _expected }

        | otherwise              = property succeeded

modifyTestState :: MonadIO m => TVar TestState -> StateT TestState STM () -> m ()
modifyTestState ts how = liftIO . atomically $ modifyTVarS ts how

addFail :: MonadIO m => TVar TestState -> String -> m ()
addFail testState desc = modifyTestState testState $ fails %= (desc :)

reportingFail :: TVar TestState -> String -> Production () -> Production ()
reportingFail testState actionName act = do
    act `catch` \(SomeException e) ->
        addFail testState $ "Error thrown in " ++ actionName ++ ": " ++ show e

newWork :: TVar TestState -> String -> Production () -> Production ()
newWork testState workerName act = do
    reportingFail testState workerName act


-- * Misc

-- I guess, errors in network-transport wasn't supposed to be processed in such way ^^
throwLeft :: Exception e => Production (Either e a) -> Production a
throwLeft = (>>= f)
  where
    f (Left e)  = throw e
    f (Right a) = return a

-- | Await for predicate to become True, with timeout
awaitSTM :: Int -> STM Bool -> Production ()
awaitSTM time predicate = do
    tvar <- liftIO $ newTVarIO False
    void . fork $ do
        delay $ for (fromMicroseconds . fromIntegral $ time)
        liftIO . atomically $ writeTVar tvar True
    liftIO . atomically $
        check =<< (||) <$> predicate <*> readTVar tvar


-- * Talk style

-- | Way to send pack of messages
data TalkStyle
    = SingleMessageStyle
    -- ^ corresponds to `sendTo` and `ListenerActionOneMsg` usage
    | ConversationStyle
    -- ^ corresponds to `withConnectionTo` and `ListenerActionConversation` usage

instance Show TalkStyle where
    show SingleMessageStyle = "single-message style"
    show ConversationStyle  = "conversation style"

sendAll
    :: ( Binary msg, Message msg, MonadIO m )
    => TalkStyle
    -> SendActions BinaryP m
    -> NodeId
    -> [msg]
    -> m ()
sendAll SingleMessageStyle sendActions peerId msgs =
    forM_ msgs $ sendTo sendActions peerId

sendAll ConversationStyle sendActions peerId msgs =
    withConnectionTo sendActions @_ @Bool peerId $ \cactions -> forM_ msgs $ \msg -> do
        send cactions msg
        recv cactions
        pure ()

receiveAll
    :: ( Binary msg, Message msg, MonadIO m )
    => TalkStyle
    -> (msg -> m ())
    -> ListenerAction BinaryP m
receiveAll SingleMessageStyle handler =
    ListenerActionOneMsg $ \_ _ -> handler
-- For conversation style, we send a response for every message received.
-- The sender awaits a response for each message. This ensures that the
-- sender doesn't finish before the conversation SYN/ACK completes.
receiveAll ConversationStyle  handler =
    ListenerActionConversation @_ @_ @Bool $ \_ cactions ->
        let loop = do mmsg <- recv cactions
                      case mmsg of
                          Nothing -> pure ()
                          Just msg -> do
                              handler msg
                              send cactions True
                              loop
        in  loop


-- * Test template

deliveryTest :: TVar TestState
             -> [NodeId -> Worker BinaryP Production]
             -> [Listener BinaryP Production]
             -> IO Property
deliveryTest testState workers listeners = runProduction $ do
    let tcpParams = TCP.defaultTCPParameters {
              TCP.tcpReuseServerAddr = True
            , TCP.tcpReuseClientAddr = True
            }
    tcpTransport <-
        throwLeft $ liftIO $ TCP.createTransportExposeInternals "127.0.0.1" "10342" tcpParams
    let transport = concreteTCP runProduction tcpTransport

    let prng1 = mkStdGen 0
    let prng2 = mkStdGen 1

    -- launch nodes
    node transport prng1 BinaryP $ \serverNode -> do
        -- Server EndPoint is up.
        pure $ NodeAction listeners $ \_ -> do
            --liftIO . putStrLn $ "Server started"
            node transport prng2 BinaryP $ \_ -> do
                -- Client EndPoint is up.
                pure $ NodeAction [] $ \clientSendActions -> do
                    --liftIO . putStrLn $ "Client started"
                    void . forConcurrently workers $ \worker ->
                        worker (nodeId serverNode) clientSendActions
                    -- Client EndPoint closes here
                    --liftIO . putStrLn $ "Client closing"
                    awaitSTM 5000000 $ S.null . _expected <$> readTVar testState
            -- Must not let the server EndPoint close too soon. It's possible
            -- that the client (which has just closed) will still have data
            -- in-flight, which we expect the server to pick up.
            -- So we wait for receiver to get everything, but not for too long.
            --liftIO . putStrLn $ "Client closed"
            --liftIO . putStrLn $ "Server closing"
            -- Server EndPoint closes here
    --liftIO . putStrLn $ "Server closed"

    closeTransport transport

    -- wait till port gets free
    delay $ for 20000

    -- form test results
    liftIO . atomically $
        property <$> readTVar testState
