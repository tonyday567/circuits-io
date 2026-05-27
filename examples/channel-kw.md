# channel-kw — Kidney & Wu stream processors

**card** ⟜ the K&W `Producer`/`Consumer` on `Hyper`, and how they differ from the equipment `Producer`/`Consumer` on `Circuit`.

---

## the types (from `Circuit.Channel`)

Kidney & Wu (POPL 2026) define stream processors on `Hyper`:

```haskell
type Emit   a = Hyper () a        -- produce a value
type Commit a = Hyper a ()        -- consume a value

type Producer a r = Hyper (a -> r) r
-- A Producer sends elements of type a, yielding a result r.
-- Unfolds: (a -> r) -> r — given a continuation, produce r.

type Consumer a r = Hyper r (a -> r)
-- A Consumer receives elements of type a, yielding a result r.
-- Unfolds: r -> (a -> r) — given a seed r, produce a continuation.

type Channel r i o = Hyper (o -> r) (i -> r)
-- A bidirectional pipe: consumes i, produces o, result carrier r.

prod :: a -> Producer a r -> Producer a r
prod a p = Hyper $ \c -> (c `invoke` p) a

cons :: (r -> a -> r) -> Consumer a r -> Consumer a r
cons f c = Hyper $ \p a -> f (p `invoke` c) a

layer :: Channel r a a -> Channel r a a
layer x = Hyper $ \anchor a -> (anchor `invoke` x) a
```

## what they do

Single-element-at-a-time streaming. `prod` pushes one value onto a Producer. `cons` adds one processing step to a Consumer. The accumulator `r` threads state through. No feedback loops — pure continuation plumbing. Think `foldl` expressed as coinductive push/pop.

## how they differ from `Circuit.Ends`

| | K&W (`Hyper`) | Equipment (`Circuit`) |
|---|---|---|
| base type | `Hyper a b` | `Circuit arr t a b` |
| Producer | `Hyper (a -> r) r` — single-value push | `forall x. Consumer x -> Circuit x a` — channel end |
| Consumer | `Hyper r (a -> r)` — single-value process | `forall x. Producer x -> Circuit a x` — channel end |
| composition | `invoke` (continuation application) | `close` (companion/conjoint adjunction) |
| feedback | none — external threading via `r` | structural — companion/conjoint mutual recursion |
| channel type | explicit in continuation arg | hidden in `forall x` quantification |
| use case | stream processing (fold, map) | channel topology (queues, sockets, buffers) |

The K&W Producer/Consumer are about **elements flowing through continuations**. The equipment Producer/Consumer are about **ends that travel independently and plug together**. They operate at different levels — element-at-a-time vs channel-topology.

## why they moved to examples

`Circuit` is the API surface for this library. Standardising on one base type (`Circuit` rather than `Hyper`) means the equipment `Producer`/`Consumer` is the library's vocabulary for channel ends. K&W stream processors are genuine infrastructure but the library doesn't exercise them — they're an alternative API surface that competes with `Circuit.Ends`. For publication, pick one.
