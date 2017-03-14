{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RankNTypes #-}

-- | Network Transport
module Network.Transport.Abstract
  ( -- * Types
    Transport(..)
  , EndPoint(..)
  , Connection(..)
  , Event(..)
  , QDisc(..)
  , NT.ConnectionId
  , NT.ConnectionBundle
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
  , NT.EventErrorCode(..)
  , EventError(..)
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
    newEndPoint :: m (Either (NT.TransportError NT.NewEndPointErrorCode) (EndPoint m))
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
  , connect
      :: NT.EndPointAddress
      -> NT.Reliability
      -> NT.ConnectHints
      -> m (Either (NT.TransportError NT.ConnectErrorCode) (Connection m))
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
  , bundle :: NT.ConnectionBundle
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
  | ErrorEvent (NT.TransportError EventError)
  deriving (Show, Eq, Generic)

instance Binary Event

data EventError = UnsupportedEvent | EventErrorCode NT.EventErrorCode
  deriving (Show, Eq, Generic, Typeable)

instance Binary EventError

-- | A queueing discipline.
data QDisc m t = QDisc {
      qdiscDequeue :: m t
    , qdiscEnqueue :: NT.EndPointAddress -> Event -> t -> m ()
    }
