{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE KindSignatures        #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE UndecidableInstances  #-}

module Mockable.Concurrent (

    ThreadId
  , Fork(..)
  , fork
  , myThreadId
  , killThread

  , Delay(..)
  , RelativeToNow
  , delay
  , for
  , sleepForever

  , RunInUnboundThread(..)
  , runInUnboundThread

  , Promise
  , Async(..)
  , async
  , link
  , wait
  , cancel
  , waitAny
  , waitAnyNonFail
  , waitAnyUnexceptional

  , Concurrently(..)
  , concurrently
  , mapConcurrently
  , forConcurrently

  ) where

import           Data.Time.Units    (Microsecond)
import           Mockable.Class
import           Mockable.Exception (Catch, catchAll)

type family ThreadId (m :: * -> *) :: *

-- | Fork mock to add ability for threads manipulation.
data Fork m t where
    Fork       :: m () -> Fork m (ThreadId m)
    MyThreadId :: Fork m (ThreadId m)
    KillThread :: ThreadId m -> Fork m ()

instance (ThreadId n ~ ThreadId m) => MFunctor' Fork m n where
    hoist' nat (Fork action)  = Fork $ nat action
    hoist' _ MyThreadId       = MyThreadId
    hoist' _ (KillThread tid) = KillThread tid

----------------------------------------------------------------------------
-- Fork mock helper functions
----------------------------------------------------------------------------

fork :: ( Mockable Fork m ) => m () -> m (ThreadId m)
fork term = liftMockable $ Fork term

myThreadId :: ( Mockable Fork m ) => m (ThreadId m)
myThreadId = liftMockable MyThreadId

killThread :: ( Mockable Fork m ) => ThreadId m -> m ()
killThread tid = liftMockable $ KillThread tid

type RelativeToNow = Microsecond -> Microsecond

data Delay (m :: * -> *) (t :: *) where
    Delay :: RelativeToNow -> Delay m ()    -- Finite delay.
    SleepForever :: Delay m ()              -- Infinite delay.

instance MFunctor' Delay m n where
    hoist' _ (Delay i)    = Delay i
    hoist' _ SleepForever = SleepForever

delay :: ( Mockable Delay m ) => RelativeToNow -> m ()
delay relativeToNow = liftMockable $ Delay relativeToNow

for :: Microsecond -> RelativeToNow
for = (+)

sleepForever :: ( Mockable Delay m ) => m ()
sleepForever = liftMockable SleepForever

data RunInUnboundThread m t where
    RunInUnboundThread :: m t -> RunInUnboundThread m t

instance MFunctor' RunInUnboundThread m n where
    hoist' nat (RunInUnboundThread action) = RunInUnboundThread $ nat action

runInUnboundThread :: ( Mockable RunInUnboundThread m ) => m t -> m t
runInUnboundThread m = liftMockable $ RunInUnboundThread m

type family Promise (m :: * -> *) :: * -> *

data Async m t where
    Async :: m t -> Async m (Promise m t)
    Link :: Promise m t -> Async m ()
    Wait :: Promise m t -> Async m t
    WaitAny :: [Promise m t] -> Async m (Promise m t, t)
    Cancel :: Promise m t -> Async m ()

async :: ( Mockable Async m ) => m t -> m (Promise m t)
async m = liftMockable $ Async m

link :: ( Mockable Async m ) => Promise m t -> m ()
link promise = liftMockable $ Link promise

wait :: ( Mockable Async m ) => Promise m t -> m t
wait promise = liftMockable $ Wait promise

waitAny :: ( Mockable Async m ) => [Promise m t] -> m (Promise m t, t)
waitAny promises = liftMockable $ WaitAny promises

cancel :: ( Mockable Async m ) => Promise m t -> m ()
cancel promise = liftMockable $ Cancel promise

instance (Promise n ~ Promise m) => MFunctor' Async m n where
    hoist' nat (Async act) = Async $ nat act
    hoist' _ (Link p)      = Link p
    hoist' _ (Wait p)      = Wait p
    hoist' _ (WaitAny p)   = WaitAny p
    hoist' _ (Cancel p)    = Cancel p

data Concurrently m t where
    Concurrently :: m a -> m b -> Concurrently m (a, b)

instance MFunctor' Concurrently m n where
    hoist' nat (Concurrently a b) = Concurrently (nat a) (nat b)

concurrently :: ( Mockable Concurrently m ) => m a -> m b -> m (a, b)
concurrently a b = liftMockable $ Concurrently a b

newtype ConcurrentlyA m t = ConcurrentlyA {
      runConcurrentlyA :: m t
    }

instance ( Functor m ) => Functor (ConcurrentlyA m) where
    fmap f = ConcurrentlyA . fmap f . runConcurrentlyA

instance ( Mockable Concurrently m ) => Applicative (ConcurrentlyA m) where
    pure = ConcurrentlyA . pure
    cf <*> cx = ConcurrentlyA $ do
        (f, x) <- concurrently (runConcurrentlyA cf) (runConcurrentlyA cx)
        pure $ f x

mapConcurrently
    :: ( Traversable f, Mockable Concurrently m )
    => (s -> m t)
    -> f s
    -> m (f t)
mapConcurrently g = runConcurrentlyA . traverse (ConcurrentlyA . g)

forConcurrently
    :: ( Traversable f, Mockable Concurrently m )
    => f s
    -> (s -> m t)
    -> m (f t)
forConcurrently = flip mapConcurrently

waitAnyNonFail
    :: ( Mockable Async m, Eq (Promise m (Maybe a)) )
    => [ Promise m (Maybe a) ] -> m (Maybe (Promise m (Maybe a), a))
waitAnyNonFail promises = waitAny promises >>= handleRes
  where
    handleRes (p, Just res) = pure $ Just (p, res)
    handleRes (p, _)        = waitAnyNonFail (filter (/= p) promises)

waitAnyUnexceptional
    :: ( Mockable Async m, Mockable Catch m, Eq (Promise m (Maybe a)) )
    => [m a] -> m (Maybe a)
waitAnyUnexceptional acts = impl
  where
    impl = (fmap . fmap) snd $ waitAnyNonFail =<< mapM toAsync acts
    toAsync :: ( Mockable Async m, Mockable Catch m ) => m a -> m (Promise m (Maybe a))
    toAsync = async . forPromise
    forPromise :: ( Mockable Async m, Mockable Catch m ) => m a -> m (Maybe a)
    forPromise a = (Just <$> a) `catchAll` (const $ pure Nothing)
