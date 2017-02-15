{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

import           Control.Monad (unless)
import           GHC.Generics (Generic)
import           Control.Monad.IO.Class (liftIO)
import           Data.String (fromString)
import           Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import           Data.Binary (Binary)
import           Network.Transport.Abstract
import           Network.Transport.Concrete
import qualified Network.Transport.TCP as TCP
import qualified Network.Transport.Concrete.TCP as TCP
import           Node
import           Node.Message
import           System.Environment (getArgs)
import           System.Random (mkStdGen)
import           Data.Time.Units
import           Mockable.Concurrent (delay, async, wait, cancel)
import           Mockable.SharedAtomic
import qualified Mockable.Metrics as Metrics
import           Mockable.Production
import qualified System.Remote.Monitoring as Monitoring
import qualified System.Metrics as Monitoring
import qualified System.Metrics.Distribution as Monitoring.Distribution

-- |
-- = Abuse demonstration number 1.
--
-- The client will ping some server as fast as possible with rather large
-- payloads (circa 16 megabytes).
--
-- The client will handle these with single-message listeners that delay for
-- 5 seconds and then update the total number of bytes received so far.
--
-- The 5 second delay isn't really necessary. as the dispatcher always tries
-- to start parsing the message immediately. However the delay does somewhat
-- simulate a real world situation, where the data is not discarded right
-- away.
--
-- |
-- = Single-message listeners
--
-- For a single-message listener, the node's handler will try to parse it all
-- and then hand it off to the application's handler. This just makes perfect
-- sense: the single-message handler surely wants to know about the whole
-- message. However, this means that the application's handler really doesn't
-- get a say in backpressure. The node's handler will always try to churn
-- through the message as fast as possible, without regard for how efficiently
-- the application's handlers are dealing with it. Imposing some backpressure
-- here could be done by a mutable queueing policy as a function of some
-- dispatcher statistics. For example, if there are an extermely high number of
-- handlers running, we could shrink the input buffer bounds until that
-- number subsides.
--
-- |
-- = Ingress buffer size versus thread pool
--
-- Another option is a thread pool. If we limit the number of handlers which
-- can run at a given time, then eventually we'll stop reading input because the
-- pool is full, and if the ingress buffer is bounded then there's a limit at
-- which the client will feel the pressure.
--
-- On the other hand, suppose we set the ingress buffer size to 0. This means
-- we won't take any more input. It essentially limits the thread pool to the
-- number of currently running threads. 
--
-- In either case, we need bounds on the ingress buffer. But these bounds are
-- enough to impose a bound on a thread pool, so it's not necessary to
-- explicitly pool any threads!
--
-- |
-- = Conversation listeners
--
-- These listeners are given a 'recv' function which, with the backpressure
-- implementation, directly corresponds to reading from the socket to the peer.
-- These listeners *do* have a say in backpressure. The node's handler will
-- only parse the message name, and leave it to the application's handler to
-- determine when to pull in more data. If a client spams a conversation
-- listener, and that listener doesn't read fast enough, the client will
-- eventually slow down as its TCP egress buffers fill up.

data Ping = Ping ByteString
deriving instance Generic Ping
instance Binary Ping
instance Message Ping where
    messageName _ = fromString "Ping"
    formatMessage _ = fromString "Ping"

-- ~16mb
payloadSize :: Integral a => a
payloadSize = 2^24

payload :: ByteString
payload = fromString (take payloadSize (repeat '0'))

main :: IO ()
main = do

    choice : rest <- getArgs

    case choice of
        "server" -> case rest of
            [serverPort] -> runProduction $ server serverPort
            _ -> error "Second argument for a server must be a port"
        "client" -> case rest of
            [serverPort, clientPort] -> runProduction $ client serverPort clientPort
            _ -> error "Arguments for a client must be the server port followed by client port"
        _ -> error "First argument must be server or client"

setupMonitor :: Node Production -> Production Monitoring.Server
setupMonitor node = do
    store <- liftIO Monitoring.newStore
    liftIO $ flip (Monitoring.registerGauge "Remotely-initated handlers") store $ runProduction $ do
        stats <- nodeStatistics node
        Metrics.readGauge (stRunningHandlersRemote stats)
    liftIO $ flip (Monitoring.registerGauge "Locally-initated handlers") store $ runProduction $ do
        stats <- nodeStatistics node
        Metrics.readGauge (stRunningHandlersLocal stats)
    liftIO $ flip (Monitoring.registerDistribution "Handler elapsed time (normal)") store $ runProduction $ do
        stats <- nodeStatistics node
        liftIO $ Monitoring.Distribution.read (stHandlersFinishedNormally stats)
    liftIO $ flip (Monitoring.registerDistribution "Handler elapsed time (exceptional)") store $ runProduction $ do
        stats <- nodeStatistics node
        liftIO $ Monitoring.Distribution.read (stHandlersFinishedExceptionally stats)
    liftIO $ Monitoring.registerGcMetrics store
    server <- liftIO $ Monitoring.forkServerWith store "127.0.0.1" 8000
    liftIO $ putStrLn "Forked EKG server on port 8000"
    return server

server :: String -> Production ()
server port = do

    Right (transport_, internals) <-
        liftIO $ TCP.createTransportExposeInternals "0.0.0.0" "127.0.0.1" port TCP.defaultTCPParameters
    let transport = TCP.concrete runProduction (transport_, internals)
    --let transport = concrete transport_
    let prng = mkStdGen 0
    totalBytes <- newSharedAtomic 0

    liftIO . putStrLn $ "Starting server on port " ++ show port

    node transport prng BinaryP $ \node -> do
        -- Set up the EKG monitor.
        setupMonitor node
        pure $ NodeAction [listener totalBytes] $ \saction -> do
            -- Just wait for user interrupt
            liftIO . putStrLn $ "Server running. Press any key to stop."
            liftIO getChar

    closeTransport transport

    total <- modifySharedAtomic totalBytes $ \bs -> return (bs, bs)

    liftIO . putStrLn $ "Server processed " ++ show total ++ " bytes"

    where

    -- The server listener just forces the whole bytestring then discards.
    listener :: SharedAtomicT Production Integer -> ListenerAction BinaryP Production
    listener totalBytes = ListenerActionOneMsg $ \peer sactions (Ping body) -> do
        -- Retain the body for a few seconds.
        delay (5000000 :: Microsecond)
        let len = BS.length body
        modifySharedAtomic totalBytes $ \total ->
            let !newTotal = fromIntegral len + total
            in  return (newTotal, ())
        --liftIO . putStrLn $ "Server heard message of length " ++ show (BS.length body)

client :: String -> String -> Production ()
client serverPort clientPort = do

    Right (transport_, internals) <-
        liftIO $ TCP.createTransportExposeInternals "0.0.0.0" "127.0.0.1" clientPort TCP.defaultTCPParameters
    let transport = TCP.concrete runProduction (transport_, internals)
    --let transport = concrete transport_
    let prng = mkStdGen 1
    -- Assume the server's end point identifier is 0. It always will be.
    let serverAddress = NodeId (TCP.encodeEndPointAddress "127.0.0.1" serverPort 0)

    liftIO . putStrLn $ "Starting client on port " ++ show clientPort

    totalBytes <- node transport prng BinaryP $ \node ->
        pure $ NodeAction [] $ \saction -> do
            -- Track total bytes sent, and a bool indicating whether we should
            -- stop, so that we don't have to resort to cancelling the threads
            -- (which may leave some bytes missing from the total).
            totalBytes <- newSharedAtomic (0, False)
            -- 4 threads will spam.
            spammer1 <- async $ spamServer serverAddress totalBytes saction
            spammer2 <- async $ spamServer serverAddress totalBytes saction
            spammer3 <- async $ spamServer serverAddress totalBytes saction
            spammer4 <- async $ spamServer serverAddress totalBytes saction
            liftIO . putStrLn $ "Client is spamming the server. Press any key to stop."
            liftIO getChar
            -- Signal the threads to not try another send.
            -- They'll eventually stop.
            _ <- modifySharedAtomic totalBytes $ \(bs, _) -> return ((bs, True), ())
            wait spammer1
            wait spammer2
            wait spammer3
            wait spammer4
            modifySharedAtomic totalBytes $ \total -> return (total, total)
            
    closeTransport transport

    liftIO . putStrLn $ "Client sent " ++ show totalBytes ++ " bytes"

spamServer :: NodeId -> SharedAtomicT Production (Integer, Bool) -> SendActions BinaryP Production -> Production ()
spamServer server totalBytes sactions = do
    sendTo sactions server (Ping payload)
    stop <- modifySharedAtomic totalBytes $ \(total, stop) ->
        let !newTotal = total + payloadSize
        in  return ((newTotal, stop), stop)
    unless stop (spamServer server totalBytes sactions)
