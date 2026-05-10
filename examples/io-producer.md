# io-producer ⟜ IO effects in a Producer via Hyper body (pre-monad-param)

Proves that `Producer` from `Circuit.Channel` can embed IO effects
even with the pure `Identity`-like types.  The `Hyper` constructor
body wraps `unsafePerformIO`/`unsafeInterleaveIO` to lazily thread
STM reads through the message chain.

This pattern predates the monad-parameter redesign.  With the new
`Producer m r a` types, IO effects are explicit in the monad and
`unsafePerformIO` is no longer needed.  This card is preserved as
a design witness.

## the pattern (old types)

With `Producer o a = Hyper (o -> a) a` (pre-monad-param):

```haskell
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE ScopedTypeVariables #-}
import Circuit.Channel (Consumer, Producer, cons, prod, yield)
import Circuit.Hyper (Hyper(..), invoke)
import Control.Concurrent.STM (TQueue, atomically, newTQueueIO, readTQueue, writeTQueue)
import System.IO.Unsafe (unsafeInterleaveIO, unsafePerformIO)
import Prelude hiding (id, (.))

queueProducer :: forall a. TQueue a -> Producer (Maybe a) [a]
queueProducer q = Hyper $ \consumer ->
  unsafePerformIO $ unsafeInterleaveIO $ do
    x <- atomically (readTQueue q)
    pure $! x : invoke consumer (queueProducer q) (Just x)
{-# NOINLINE queueProducer #-}
```

## the new way (monad parameter)

With `Producer m r a = Hyper (a -> m r) (m r)`:

```haskell
queueProducer :: TQueue a -> Producer IO [a] (Maybe a)
queueProducer q = Hyper $ \consumer ->
  unsafeInterleaveIO $ do
    x <- atomically (readTQueue q)
    invoke consumer (queueProducer q) (Just x)
```

No `unsafePerformIO` — the body returns `IO [a]` directly.
