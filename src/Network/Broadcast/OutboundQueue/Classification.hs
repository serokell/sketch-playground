{-# LANGUAGE RankNTypes #-}

-- | Classification of nodes and messages
module Network.Broadcast.OutboundQueue.Classification (
    MsgType(..)
  , NodeType(..)
  , FormatMsg(..)
  ) where

import Formatting

{-------------------------------------------------------------------------------
  Classification of messages and destinations
-------------------------------------------------------------------------------}

-- | Message types
data MsgType =
    -- | Announcement of a new block
    --
    -- This is a block header, not the actual value of the block.
    MsgBlockHeader

    -- | New transaction
  | MsgTransaction

    -- | MPC messages
  | MsgMPC

    -- | Request information (from peers known to have it)
  | MsgRequestData
  deriving (Show, Eq, Ord)

-- | Node types
data NodeType =
    -- | Core node
    --
    -- Core nodes:
    --
    -- * can become slot leader
    -- * never create currency transactions
    NodeCore

    -- | Edge node
    --
    -- Edge nodes:
    --
    -- * cannot become slot leader
    -- * creates currency transactions,
    -- * cannot communicate with core nodes
    -- * may or may not be behind NAT/firewalls
  | NodeEdge

    -- | Relay node
    --
    -- Relay nodes:
    --
    -- * cannot become slot leader
    -- * never create currency transactions
    -- * can communicate with core nodes
  | NodeRelay
  deriving (Show, Eq, Ord)

class FormatMsg msg where
  formatMsg :: forall r a. Format r (msg a -> r)
