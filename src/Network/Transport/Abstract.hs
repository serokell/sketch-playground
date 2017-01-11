{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | Network Transport
module Network.Transport.Abstract
  ( -- * Types
    Transport(..)
  , EndPoint(..)
  , Connection(..)
  , Event(..)
  , NT.ConnectionId
  , NT.Reliability(..)
  , NT.EndPointAddress(..)
    -- * Hints
  , NT.ConnectHints(..)
  , NT.defaultConnectHints
    -- * Error codes
  , NT.TransportError(..)
  , NT.NewEndPointErrorCode(..)
  , NT.ConnectErrorCode(..)
  , NT.SendErrorCode(..)
  , EventErrorCode(..)
  , Policy
  , PolicyDecision(..)
  , Decision(..)
  , alwaysAccept
  ) where

import Data.Typeable
import Data.ByteString (ByteString)
import Data.Binary (Binary(..))
import GHC.Generics (Generic)
import qualified Network.Transport as NT

--------------------------------------------------------------------------------
-- Main API                                                                   --
--------------------------------------------------------------------------------

-- | A network transport over some monad.
data Transport m = Transport {
    -- | Create a new end point (heavyweight operation)
    newEndPoint :: Policy m -> m (Either (NT.TransportError NT.NewEndPointErrorCode) (EndPoint m))
    -- | Shutdown the transport completely
  , closeTransport :: m ()
  }

-- | Network endpoint over some monad.
data EndPoint m = EndPoint {
    -- | Endpoints have a single shared receive queue.
    receive :: m Event
    -- | EndPointAddress of the endpoint.
  , address :: NT.EndPointAddress
    -- | Create a new lightweight connection.
    --
    -- 'connect' should be as asynchronous as possible; for instance, in
    -- Transport implementations based on some heavy-weight underlying network
    -- protocol (TCP, ssh), a call to 'connect' should be asynchronous when a
    -- heavyweight connection has already been established.
  , connect :: NT.EndPointAddress -> NT.Reliability -> NT.ConnectHints -> m (Either (NT.TransportError NT.ConnectErrorCode) (Connection m))
    -- | Close the endpoint
  , closeEndPoint :: m ()
  }

-- | Lightweight connection to an endpoint.
data Connection m = Connection {
    -- | Send a message on this connection.
    --
    -- 'send' provides vectored I/O, and allows multiple data segments to be
    -- sent using a single call (cf. 'Network.Socket.ByteString.sendMany').
    -- Note that this segment structure is entirely unrelated to the segment
    -- structure /returned/ by a 'Received' event.
    send :: [ByteString] -> m (Either (NT.TransportError NT.SendErrorCode) ())
    -- | Close the connection.
  , close :: m ()
  }

-- | Event on an endpoint.
data Event =
    -- | Received a message
    Received {-# UNPACK #-} !NT.ConnectionId [ByteString]
    -- | Connection closed
  | ConnectionClosed {-# UNPACK #-} !NT.ConnectionId
    -- | Connection opened
  | ConnectionOpened {-# UNPACK #-} !NT.ConnectionId NT.Reliability NT.EndPointAddress
    -- | Received multicast
    -- | The endpoint got closed (manually, by a call to closeEndPoint or closeTransport)
  | EndPointClosed
    -- | An error occurred
  | ErrorEvent (NT.TransportError EventErrorCode)
  deriving (Show, Eq, Generic)

instance Binary Event

data EventErrorCode = UnsupportedEvent | EventErrorCode NT.EventErrorCode
  deriving (Show, Eq, Generic, Typeable)

instance Binary EventErrorCode

type Policy m = NT.EndPointAddress -> PolicyDecision m

newtype PolicyDecision m = PolicyDecision {
      getPolicyDecision :: m (Decision m, PolicyDecision m)
    }

data Decision m = Accept | Block (m ())

alwaysAccept :: ( Applicative m ) => Policy m
alwaysAccept _ = acceptForever
    where
    acceptForever = PolicyDecision $ pure (Accept, acceptForever)
