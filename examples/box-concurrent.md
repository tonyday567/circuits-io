# box-concurrent ⟜ race and concurrently for Circuits

`feedQueue`, `drainQueue`, and `runConcurrently` wimp out: they work
on raw `TQueue` and `IO`, never touching the `Circuit` structure.

The question: what do `race` and `concurrently` mean for two
`Circuit (Kleisli IO) Either` values?

## The honest answer

Concurrency is not a primitive of the `Circuit` algebra. `Circuit` gives
you `Lift`, `Compose`, `Knot`. Parallel execution lives at the
*interpretation* layer — after `reify` collapses the circuit to a
`Kleisli IO` arrow.

But we can wrap that interpretation cleanly so the API stays at the
circuit level.

## raceB / concurrentlyB

```haskell
{-# LANGUAGE BlockArguments #-}

import Circuit
import Control.Arrow (Kleisli(..), runKleisli)
import Control.Concurrent.Async
import Prelude hiding (id, (.))

-- | Race two circuits.  The first to finish wins.
raceB :: Circuit (Kleisli IO) Either () a
      -> Circuit (Kleisli IO) Either () b
      -> IO (Either a b)
raceB c1 c2 = race (runKleisli (reify c1) ()) (runKleisli (reify c2) ())

-- | Run two circuits concurrently, returning both results.
concurrentlyB :: Circuit (Kleisli IO) Either () a
              -> Circuit (Kleisli IO) Either () b
              -> IO (a, b)
concurrentlyB c1 c2 = concurrently (runKleisli (reify c1) ()) (runKleisli (reify c2) ())
```

These are not "wimping out" — they're the *natural* boundary between
algebra and execution. The circuit describes the stepwise protocol;
`async` schedules the steps.

## tcpDuplex with circuits

Instead of raw `IO` loops, each direction is a circuit:

```haskell
import Circuit.IO.Queue
import Control.Concurrent.STM
import Data.ByteString (ByteString)
import Network.Simple.TCP qualified as NS

receiverC :: NS.Socket -> Int -> TQueue ByteString -> Circuit (Kleisli IO) Either () ()
receiverC conn chunk q = Knot $ Kleisli $ \case
  Left () -> do
    msg <- NS.recv conn chunk
    case msg of
      Nothing -> pure $ Right ()          -- done
      Just bs -> atomically (writeTQueue q bs) >> pure (Left ())
  Right () -> pure $ Right ()             -- already done

senderC :: NS.Socket -> TQueue ByteString -> Circuit (Kleisli IO) Either () ()
senderC conn q = Knot $ Kleisli $ \case
  Left () -> do
    bs <- atomically (readTQueue q)
    NS.send conn bs
    pure $ Left ()                        -- continue
  Right () -> pure $ Right ()             -- already done
```

Then `duplex` is just `raceB`:

```haskell
tcpDuplex :: NS.Socket -> Int -> TQueue ByteString -> TQueue ByteString -> IO ()
tcpDuplex conn chunk inQ outQ =
  void $ raceB (receiverC conn chunk inQ) (senderC conn outQ)
```

## Why not the (,) tensor?

`Circuit (Kleisli IO) (,)` exists — `Trace (Kleisli IO) (,)` ties lazy
knots via `IORef` and `unsafeInterleaveIO`. But it's marked **UNSAFE**
in `Circuit.Traced` because strict effects break the knot silently.

The `Either` tensor with delimited continuations is safe. So we stay
in `Either` and use `raceB` / `concurrentlyB` for parallelism.

## What about feedQueue / drainQueue?

They're convenience wrappers for the common case "I have a list, I
have a queue, just move the data." Keep them, but don't pretend
they're circuit primitives. The primitive is `queueEnds` + `raceB`.
