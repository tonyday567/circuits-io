# channel-basics ⟜ stepwise communication

How to build producers and consumers that communicate one message
at a time, compose them into pipelines, and interpose channels that
transform the stream.

All of this lives in `Circuit.Channel`, the self-dual channel structure
on Hyper. Every producer has a dual consumer, and `⇸` annihilates
the pair. See `other/03-circuit.md` for the traced monoidal narrative
that leads here.

## producer → consumer (two components)

A producer sends messages; a consumer receives them.

```haskell
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PostfixOperators #-}

import Circuit.Channel
import Prelude hiding (id, (.))

-- emitSingles: produce each list element as a Just, then Nothing to stop.
emitSingles :: [a] -> Producer [a] (Maybe a)
emitSingles = foldr (\x p -> prod (Just x) p) (prod Nothing (yield []))

-- collectSingles: consume Just values, stop on Nothing.
-- Coinductive: h = cons step h — an infinite chain.
-- Processes as many messages as the producer sends.
collectSingles :: Consumer [a] (Maybe a)
collectSingles = h
  where
    h = cons step h
    step mx acc = case mx of
      Just x  -> x : acc
      Nothing -> acc

-- Run them together.
pipeline2 :: [a] -> [a]
pipeline2 xs = emitSingles xs ⇸ collectSingles

-- >>> pipeline2 [1,2,3]
-- [1,2,3]
-- >>> pipeline2 []
-- []
```

Each `cons` in the chain processes one message. The state is
distributed across the chain — no mutable cell, no explicit loop
counter. The `prod`/`cons` chain IS the state mechanism.

Compare with `Circuit`'s `Knot` + `Trace`: the protocol lives in the
tensor (`Either`/`(,)`). Here the protocol is in the message type
(`Maybe a` for stop signalling). Both achieve stepwise threading;
Channel is more direct but less parametric.

## interposing a channel (three components)

A `Channel` sits between producer and consumer. It consumes `i`,
produces `o`, result `r`. Category composition attaches it to the
consumer side:

```
Consumer r o . Channel r i o = Consumer r i
```

```haskell
-- takeChannel: pass through up to n messages, then stop.
type Channel r i o = (o -> r) ↬ (i -> r)  -- from Circuit.Channel

takeChannel :: Int -> Channel [a] (Maybe a) (Maybe a)
takeChannel n = go n
  where
    go 0 = Hyper \_ i -> case i of { Nothing -> []; Just _ -> [] }
    go k = Hyper \out i ->
      case i of
        Nothing -> []
        Just x  -> invoke out (go (k-1)) (Just x)

-- Compose: channel . consumer
pipelineChannel :: Int -> [a] -> [a]
pipelineChannel n xs = emitSingles xs ⇸ (takeChannel n . collectSingles)

-- >>> pipelineChannel 2 [1,2,3]
-- [1,2]
-- >>> pipelineChannel 5 [1,2,3]
-- [1,2,3]
```

The composition `takeChannel n . collectSingles` is a new Consumer
that delegates to `collectSingles` but with the channel's counting
logic interposed. Each message passes through the channel before
reaching the consumer.

## open and close

'⇸' has two directions:

```
c ⇸ p :: a → r   — open: Consumer-first, one-step unwind to an arrow
p ⇸ c :: r       — close: Producer-first, drive to completion
```

## the coinductive Consumer

The pattern `h = cons step h` is the key insight. A finite Consumer
(built from a known-length list via foldr) can't handle an
open-ended stream. The coinductive version can — it unwinds one
step at a time as messages arrive.

The termination protocol:
- Producer sends `Nothing` → consumer's `step Nothing acc = acc`
- Producer runs out of messages → `yield []` returns the accumulator
- The chain of `cons` calls unwinds, threading the accumulator
  backward through each `step` application

## turn-based vs concurrent

The pipeline above is **turn-based**: producer, then consumer,
then producer, etc. In the paper's stable marriage example
(§5.3), coroutines communicate concurrently — a woman's decision
to jilt wakes the jilted man's coroutine. Control jumps between
coroutines, not A→B→C.

See `examples/stable-marriage.md` for the pure state-machine version
and `examples/spec.md` for the paper's full Co monad with delimited
continuations.

## Kleisli (monadic) variants

For IO-bound or effectful pipelines, use the monadic suffixes:

```haskell
import Circuit.Channel
import Data.Functor.Identity (Identity(..), runIdentity)

-- >>> runIdentity $ (prodK 42 (yieldK 0)) ⇸ (consK (\a acc -> fmap (+ a) acc) (acceptK 0))
-- 42
```

The `K` suffix convention (e.g. `prodK`) distinguishes
the Kleisli/monadic versions from the pure ones. `⇸` works on both.

## reference

- `Circuit.Channel` — the module (self-dual channels on Hyper)
- `examples/coroutine-hyper.md` — Coro→Channel, Trace→Hyper, delimited continuity
- `other/03-circuit.md` — the traced monoidal narrative
- Kidney & Wu, POPL 2026 — §2.4 (Producer/Consumer), §5.1 (Channel), §5.3 (stable marriage)
