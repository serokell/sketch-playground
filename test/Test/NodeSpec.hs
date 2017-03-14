{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving  #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE BangPatterns        #-}

module Test.NodeSpec
       ( spec
       ) where

import           Control.Monad               (forM_, when)
import           Control.Monad.IO.Class      (liftIO)
import           Control.Concurrent.STM.TVar (TVar, newTVarIO)
import           Control.Lens                (sans, (%=), (&~), (.=))
import           Control.Exception           (AsyncException(..))
import           Data.Foldable               (for_)
import qualified Data.Set                    as S
import           Data.Time.Units             (Microsecond)
import           Test.Hspec                  (Spec, describe, runIO, afterAll_)
import           Test.Hspec.QuickCheck       (prop)
import           Test.QuickCheck             (Property, ioProperty)
import           Test.QuickCheck.Modifiers   (NonEmptyList(..), getNonEmpty)
import           Test.Util                   (HeavyParcel (..), Parcel (..),
                                              TalkStyle (..), TestState, deliveryTest,
                                              expected, mkTestState, modifyTestState,
                                              newWork, receiveAll, sendAll,
                                              makeTCPTransport, makeInMemoryTransport,
                                              Payload(..), timeout)
import           System.Random               (newStdGen)
import qualified Network.RateLimiting        as RL
import qualified Network.Transport           as NT (Transport)
import qualified Network.Transport.Abstract  as NT
                                             (closeTransport, newEndPoint,
                                              closeEndPoint, address, receive)
import           Network.Transport.TCP       (simpleOnePlaceQDisc)
import           Network.QDisc.Fair          (fairQDisc)
import           Network.Transport.Concrete  (concrete)
import           Mockable.Class              (Mockable)
import           Mockable.SharedExclusive    (newSharedExclusive, readSharedExclusive,
                                              putSharedExclusive, takeSharedExclusive,
                                              tryPutSharedExclusive, SharedExclusive)
import           Mockable.Concurrent         (withAsync, wait, Async, Delay, delay)
import           Mockable.Exception          (catch, throw)
import           Mockable.Production         (Production, runProduction)
import           Node.Message                (BinaryP(..))
import           Node

spec :: Spec
spec = describe "Node" $ do

    let mkTransportAndRateLimiting n mkRl = runIO $ do
            rateLimiting <- runProduction mkRl
            transport <- makeTCPTransport "0.0.0.0" "127.0.0.1" n (RL.rlQDisc rateLimiting)
            return (transport, rateLimiting)
    let tcpTransportOnePlace = runIO $ makeTCPTransport "0.0.0.0" "127.0.0.1" "10342" simpleOnePlaceQDisc
    let tcpTransportFair = mkTransportAndRateLimiting "10343" (return RL.noRateLimitingFair) -- runIO $ makeTCPTransport "0.0.0.0" "127.0.0.1" "10343" (fairQDisc (const (return Nothing)))
    let memoryTransport = runIO makeInMemoryTransport
    let blockingTransport n = mkTransportAndRateLimiting "10344" (RL.rateLimitingBlocking runProduction n)
    let transports =
            [ ("In-memory", (,RL.noRateLimitingUnbounded) <$> memoryTransport)
            , ("TCP", (,RL.noRateLimitingUnbounded) <$> tcpTransportOnePlace)
            , ("TCP fair queueing", tcpTransportFair)
            , ("TCP blocking rate-limiting", blockingTransport (1024*1024))
            ]

    forM_ transports $ \(name, mkTransport) -> do

        (transport_, rateLimiting) <- mkTransport
        let transport = concrete transport_

        describe ("Using transport: " ++ name) $ afterAll_ (runProduction (NT.closeTransport transport)) $ do

            prop "peer data" $ ioProperty . runProduction $ do
                clientGen <- liftIO newStdGen
                serverGen <- liftIO newStdGen
                serverAddressVar <- newSharedExclusive
                clientFinished <- newSharedExclusive
                serverFinished <- newSharedExclusive
                let attempts = 1

                let listener = ListenerActionConversation $ \pd _ cactions -> do
                        True <- return $ pd == ("client", 24)
                        initial <- timeout "server waiting for request" 30000000 (recv cactions)
                        case initial of
                            Nothing -> error "got no initial message"
                            Just (Parcel i (Payload _)) -> do
                                _ <- timeout "server sending response" 30000000 (send cactions (Parcel i (Payload 32)))
                                return ()

                let server = node transport serverGen rateLimiting BinaryP ("server" :: String, 42 :: Int) defaultNodeEnvironment $ \_node ->
                        NodeAction [listener] $ \sendActions -> do
                            putSharedExclusive serverAddressVar (nodeId _node)
                            takeSharedExclusive clientFinished
                            putSharedExclusive serverFinished ()

                let client = node transport clientGen rateLimiting BinaryP ("client" :: String, 24 :: Int) defaultNodeEnvironment $ \_node ->
                        NodeAction [listener] $ \sendActions -> do
                            serverAddress <- readSharedExclusive serverAddressVar
                            forM_ [1..attempts] $ \i -> withConnectionTo sendActions serverAddress $ \peerData cactions -> do
                                pd <- timeout "client waiting for peer data" 30000000 peerData
                                True <- return $ pd == ("server", 42)
                                _ <- timeout "client sending" 30000000 (send cactions (Parcel i (Payload 32)))
                                response <- timeout "client waiting for response" 30000000 (recv cactions)
                                case response of
                                    Nothing -> error "got no response"
                                    Just (Parcel j (Payload _)) -> do
                                        when (j /= i) (error "parcel number mismatch")
                                        return ()
                            putSharedExclusive clientFinished ()
                            takeSharedExclusive serverFinished

                withAsync server $ \serverPromise -> do
                    withAsync client $ \clientPromise -> do
                        wait clientPromise
                        wait serverPromise

                return True

            -- Test where a node converses with itself. Fails only if an exception is
            -- thrown.
            prop "self connection" $ ioProperty . runProduction $ do
                gen <- liftIO newStdGen
                -- Self-connections don't make TCP sockets so we can do an absurd amount
                -- of attempts without taking too much time.
                let attempts = 100

                let listener = ListenerActionConversation $ \pd _ cactions -> do
                        True <- return $ pd == ("some string", 42)
                        initial <- recv cactions
                        case initial of
                            Nothing -> error "got no initial message"
                            Just (Parcel i (Payload _)) -> do
                                _ <- send cactions (Parcel i (Payload 32))
                                return ()

                node transport gen rateLimiting BinaryP ("some string" :: String, 42 :: Int) defaultNodeEnvironment $ \_node ->
                    NodeAction [listener] $ \sendActions -> do
                        forM_ [1..attempts] $ \i -> withConnectionTo sendActions (nodeId _node) $ \peerData cactions -> do
                            pd <- timeout "client waiting for peer data" 30000000 peerData
                            True <- return $ pd == ("some string", 42)
                            _ <- send cactions (Parcel i (Payload 32))
                            response <- recv cactions
                            case response of
                                Nothing -> error "got no response"
                                Just (Parcel j (Payload _)) -> do
                                    when (j /= i) (error "parcel number mismatch")
                                    return ()
                return True

            prop "ack timeout" $ ioProperty . runProduction $ do
                gen <- liftIO newStdGen
                let env = defaultNodeEnvironment {
                          -- 1/10 second.
                          nodeAckTimeout = 100000
                        }
                -- An endpoint to which the node will connect. It will never
                -- respond to the node's SYN.
                Right ep <- NT.newEndPoint transport
                let peerAddr = NodeId (NT.address ep)
                -- Must clear the endpoint's receive queue so that it's
                -- never blocked on enqueue.
                withAsync (let loop = NT.receive ep >> loop in loop) $ \clearQueue -> do
                    -- We want withConnectionTo to get a Timeout exception, as
                    -- delivered by withConnectionTo in case of an ACK timeout.
                    -- A ThreadKilled would come from the outer 'timeout', the
                    -- testing utility.
                    let handleThreadKilled :: Timeout -> Production ()
                        handleThreadKilled Timeout = do
                            --liftIO . putStrLn $ "Thread killed successfully!"
                            return ()
                    node transport gen rateLimiting BinaryP () env $ \_node ->
                        NodeAction [] $ \sendActions -> do
                            timeout "client waiting for ACK" 5000000 $
                                flip catch handleThreadKilled $ withConnectionTo sendActions peerAddr $ \peerData cactions -> do
                                    _ :: Maybe Parcel <- recv cactions
                                    send cactions (Parcel 0 (Payload 32))
                                    return ()
                    --liftIO . putStrLn $ "Closing end point"
                    NT.closeEndPoint ep
                --liftIO . putStrLn $ "Closed end point"
                return True

            -- one sender, one receiver
            describe "delivery" $ do
                for_ [SingleMessageStyle, ConversationStyle] $ \talkStyle ->
                    describe (show talkStyle) $ do
                        prop "plain" $
                            plainDeliveryTest transport_ talkStyle
                        prop "heavy messages sent nicely" $
                            withHeavyParcels $ plainDeliveryTest transport_ talkStyle

prepareDeliveryTestState :: [Parcel] -> IO (TVar TestState)
prepareDeliveryTestState expectedParcels =
    newTVarIO $ mkTestState &~
        expected .= S.fromList expectedParcels

plainDeliveryTest
    :: NT.Transport
    -> TalkStyle
    -> NonEmptyList Parcel
    -> Property
plainDeliveryTest transport_ talkStyle neparcels = ioProperty $ do
    let parcels = getNonEmpty neparcels
    testState <- prepareDeliveryTestState parcels

    let worker peerId sendActions = newWork testState "client" $
            sendAll talkStyle sendActions peerId parcels

        listener = receiveAll talkStyle $
            \parcel -> modifyTestState testState $ expected %= sans parcel

    deliveryTest transport_ testState [worker] [listener]

withHeavyParcels :: (NonEmptyList Parcel -> Property) -> NonEmptyList HeavyParcel -> Property
withHeavyParcels testCase (NonEmpty megaParcels) = testCase (NonEmpty (getHeavyParcel <$> megaParcels))
