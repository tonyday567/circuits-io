# io-producer ⟜ IO effects in a Producer via Hyper body

Proves that `Producer` from `Circuit.Channel` can embed IO effects.
The `Hyper` constructor body wraps `unsafePerformIO`/`unsafeInterleaveIO`
to lazily thread STM reads through the message chain.

This is an exploration card — the pattern works but `unsafeInterleaveIO`
in library code needs justification.  See `Circuit.IO.Queue` for the
safe, pure primitives.

## the pattern

```haskell
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE ScopedTypeVariables #-}
import Circuit.Channel (Consumer, Producer, cons, glue, prod, yield)
import Circuit.Hyper (Hyper(..), invoke)
import Control.Concurrent.STM (TQueue, atomically, newTQueueIO, readTQueue, writeTQueue)
import System.IO.Unsafe (unsafeInterleaveIO, unsafePerformIO)
import Prelude hiding (id, (.))

-- | A Producer that lazily reads from a TQueue.
--   Each invoke reads one element via unsafeInterleaveIO.
queueProducer :: forall a. TQueue a -> Producer (Maybe a) [a]
queueProducer q = Hyper $ \consumer ->
  unsafePerformIO $ unsafeInterleaveIO $ do
    x <- atomically (readTQueue q)
    pure $! x : invoke consumer (queueProducer q) (Just x)
{-# NOINLINE queueProducer #-}
```

## test it

```haskell
-- | Collect Just values, stop on Nothing.
collectAll :: Consumer (Maybe a) [a]
collectAll = go
  where
    go = cons step go
    step mx acc = case mx of
      Just x  -> x : acc
      Nothing -> acc

-- Write some values, then drain with collectAll:
-- >>> q <- newTQueueIO :: IO (TQueue Int)
-- >>> atomically (writeTQueue q 1)
-- >>> atomically (writeTQueue q 2)
-- >>> glue collectAll (queueProducer q)
-- [1,2]
```

## what's happening

1. `Hyper $ \consumer -> ...` — the consumer is the dual Hyper
2. `unsafePerformIO $ unsafeInterleaveIO $ do ...` — defers the STM read
   until the list tail is forced
3. `x : invoke consumer (queueProducer q) (Just x)` — produces one message,
   tail triggers next read
4. When glued with a Consumer, each `invoke` processes one message through
   the consumer chain, and the next queue read only happens when the list
   tail is demanded

The `unsafeInterleaveIO` is necessary because `Hyper`'s body must be pure.
Without it, `unsafePerformIO` would force the entire IO action immediately
instead of lazily threading reads.

## why not in the library

`unsafeInterleaveIO` breaks referential transparency — the order of side
effects depends on evaluation order.  The safe approach in `Circuit.IO.Queue`
uses plain `IO` primitives (`feedQueue`/`drainQueue`) and leaves the
Producer/Consumer composition to the caller.

This card exists to prove that effects CAN be embedded.  Whether they
SHOULD be is a design choice.

## benchmark

Future: compare throughput of `queueProducer` + `collectAll` vs bare
`feedQueue`/`drainQueue` via `circuits-perf`.  Hypothesis: the
unsafeInterleaveIO overhead is negligible (one STM transaction per element)
but the lazy list construction may cause space leaks under heavy load.
