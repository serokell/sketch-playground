{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE DefaultSignatures     #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE UndecidableInstances  #-}

module Node.Message
    ( Packable (..)
    , Unpackable (..)
    , UnpackableCtx (..)
    , UnpackMsg
    , SimpleUnpackable (..)
    , Serializable
    , SimpleSerializable
    , Bin.Decoder(..)

    , Message (..)
    , messageName'

    , MessageName (..)
    , BinaryP (..)
    , runBinaryP
    , hoistUnpackMsg
    , needMoreInput
    ) where

import           Control.Monad.Free               (wrap)
import           Control.Monad.Trans              (lift)
import           Control.Monad.Trans.Either       (EitherT, left, mapEitherT)
import           Control.Monad.Trans.Free.Church  (hoistFT)
import qualified Control.Monad.Trans.State.Strict as St
import qualified Data.Binary                      as Bin
import qualified Data.Binary.Get                  as Bin
import qualified Data.Binary.Put                  as Bin
import qualified Data.ByteString                  as BS
import qualified Data.ByteString.Builder.Extra    as BS
import qualified Data.ByteString.Lazy             as LBS
import           Data.Data                        (Data, dataTypeName, dataTypeOf)
import           Data.Functor.Identity            (Identity, runIdentity)
import           Data.Hashable                    (Hashable)
import           Data.Proxy                       (Proxy (..), asProxyTypeOf)
import           Data.Store                       (Store)
import           Data.Store.Streaming             (PeekMessage)
import           Data.String                      (IsString, fromString)
import qualified Data.Text                        as T
import           Data.Text.Buildable              (Buildable)
import qualified Data.Text.Buildable              as B
import qualified Formatting                       as F
import           GHC.Generics                     (Generic)
import           Serokell.Util.Base16             (base16F)

-- * Message name

newtype MessageName = MessageName BS.ByteString
deriving instance Eq MessageName
deriving instance Ord MessageName
deriving instance Show MessageName
deriving instance Generic MessageName
deriving instance IsString MessageName
deriving instance Hashable MessageName
deriving instance Monoid MessageName
instance Bin.Binary MessageName
instance Store MessageName

instance Buildable MessageName where
    build (MessageName mn) = F.bprint base16F mn

-- | Defines type with it's own `MessageName`.
class Message m where
    -- | Uniquely identifies this type
    messageName :: Proxy m -> MessageName
    default messageName :: Data m => Proxy m -> MessageName
    messageName proxy =
         MessageName . fromString . dataTypeName . dataTypeOf $
            undefined `asProxyTypeOf` proxy

    -- | Description of message, for debug purposes
    formatMessage :: m -> T.Text
    default formatMessage :: F.Buildable m => m -> T.Text
    formatMessage = F.sformat F.build

-- | As `messageName`, but accepts message itself, may be more convinient is most cases.
messageName' :: Message m => m -> MessageName
messageName' = messageName . proxyOf
  where
    proxyOf :: a -> Proxy a
    proxyOf _ = Proxy

-- * Serialization strategy

-- | Defines a way to serialize object @r@ with given packing type @p@.
class Packable packing thing where
    -- | Way of packing data to raw bytes.
    -- TODO: use Data.ByteString.Builder?
    packMsg :: packing -> thing -> LBS.ByteString

type UnpackMsg unconsumed m thing =
      PeekMessage (Either (Maybe BS.ByteString) unconsumed)
                  (EitherT T.Text (St.StateT (Maybe unconsumed) m))
                  thing

hoistUnpackMsg :: (Monad n, Monad m)
               => (forall a . m a -> n a)
               -> UnpackMsg unconsumed m thing
               -> UnpackMsg unconsumed n thing
hoistUnpackMsg f = hoistFT $ mapEitherT $ St.mapStateT f

-- | Defines a way to deserealize data with given packing type @p@ and extract object @t@.
class SimpleUnpackable packing thing where
    unpackMsgSimple :: packing -> Bin.Decoder thing

class Monad (UnpackMonad packing) => UnpackableCtx packing where
    type UnpackMonad packing :: * -> *
    type Unconsumed packing :: *
    closeUnconsumed :: packing -> Unconsumed packing -> UnpackMonad packing ()

-- | Defines a way to deserealize data with given packing type @p@ and extract object @t@.
class UnpackableCtx packing => Unpackable packing thing where
    unpackMsg :: packing -> UnpackMsg (Unconsumed packing) (UnpackMonad packing) thing

type SimpleSerializable packing thing =
    ( Packable packing thing
    , SimpleUnpackable packing thing
    )

type Serializable packing thing =
    ( Packable packing thing
    , Unpackable packing thing
    )

bsNonEmptyJust :: BS.ByteString -> Maybe BS.ByteString
bsNonEmptyJust bs = if BS.null bs then Nothing else Just bs

fromBinDecoder :: Monad m => Bin.Decoder a -> UnpackMsg BS.ByteString m a
fromBinDecoder (Bin.Fail bs _ err) = lift $ lift (St.put $ bsNonEmptyJust bs) *> left (T.pack err)
fromBinDecoder (Bin.Done bs _ res) = lift $ lift (St.put $ bsNonEmptyJust bs) *> pure res
fromBinDecoder (Bin.Partial f)     = needMoreInput >>= fromBinDecoder . f . either id Just

needMoreInput :: PeekMessage i m i
needMoreInput = wrap return

-- * Default instances

data BinaryP = BinaryP

instance Bin.Binary t => Packable BinaryP t where
    packMsg _ t =
        BS.toLazyByteStringWith
            (BS.untrimmedStrategy 256 4096)
            LBS.empty
        . Bin.execPut
        $ Bin.put t

instance UnpackableCtx BinaryP where
    type (Unconsumed BinaryP) = BS.ByteString
    type (UnpackMonad BinaryP) = Identity
    closeUnconsumed _ _ = pure ()

instance Bin.Binary t => Unpackable BinaryP t where
    unpackMsg _ = fromBinDecoder $ Bin.runGetIncremental Bin.get

instance Bin.Binary t => SimpleUnpackable BinaryP t where
    unpackMsgSimple _ = Bin.runGetIncremental Bin.get

runBinaryP :: Applicative m => Identity a -> m a
runBinaryP = pure . runIdentity
