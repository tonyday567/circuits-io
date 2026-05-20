# channel-refactor ⟜ tracing the prod/cons → Emit/Commit path

A thought-trail: prod and cons are not primitive. They decompose into Emit,
Commit, and plain Category composition on Hyper. This is the same structural
move as `push = lift . compose` in the five-marks axiom system — a compound
operation that factors into simpler parts.

If this holds, the Channel module collapses dramatically. If it doesn't,
the trail is here to walk back.

---

## 1. The K&W starting point — with cleaned-up lettering

Kidney & Wu (POPL 2026) define Producer and Consumer as dual pairs on Hyper:

```haskell
type Producer a r = Hyper (a -> r) r
type Consumer a r = Hyper r (a -> r)
```

With constructors. The original lettering is confusing — `p` means
Producer in `prod` but Consumer in `cons`, and `q` is an opaque
continuation. Cleaned up:

```haskell
--                    anchor↙          inner↙      element↙
prod a p = Hyper $   \c          ->   (c  ⇸  p)   a
cons f c = Hyper $   \p     a    ->   f (p ⇸  c)  a
--                  producer anchor   element       accumulator
```

With `f` flipped from the K&W original (`f r a` not `f a r`), the
column alignment shows the structural identity: both thread the
inner Hyper through the continuation and place the element on the
right.

Base cases:

```haskell
emit   a = Hyper $ \_ -> a          -- doneP / atomic producer
forget   = Hyper $ \_ -> ()         -- doneC / atomic consumer
```

---

## 2. Same shape

Both constructors follow the same pattern:

```haskell
prod:  Hyper $ \q   ->             invoke q p o
cons:  Hyper $ \q i -> f i (invoke q p)
```

Both introduce a Hyper by taking a continuation `q`, composing it with the
inner Hyper `p` via `invoke`, and threading something through.

⟜ prod: o goes on the **RIGHT** of invoke q p
⟜ cons: f i goes on the **LEFT** of invoke q p

They're the same constructor pattern, just dual orientations — one on
the covariant side, one on the contravariant side of Hyper.

---

## 3. Same shape as the axiom rewrites

From 01-stack-language.md, axiom 5:

```
(f ⊲ p) ⊙ (g ⊗ q)  =  (f . g) ⊲ (p ⊙ q)
```

And push decomposes: `f ⊲ p = η f ⊙ p`

Substituting: `(η f ⊙ p) ⊙ (η g ⊙ q) = η (f . g) ⊙ (p ⊙ q)`

Two compound things compose by **factoring**: the decorations collapse
through function composition, and the inner Hypers recombine independently.
prod and cons are the same kind of compound — they decorate invoke with
a value on one side or the other.

⟜ The axiom says compound operations factor. prod/cons are compound.
  ⟜ Ergo they factor.

---

## 4. Drop m — the pure case

The monad parameter `m` (from `Producer m r a`, `Consumer m r a`) is
a later addition. In the pure case `m = Identity` → `Identity r ≅ r`:

```haskell
type Producer o a = Hyper (o -> a) a    -- no m
type Consumer i a = Hyper a (i -> a)
```

The types are already pure hyperfunctions. The monad was noise for the
pure case — it obscured the shape.

---

## 5. Drop `a -> r -> r` — replace with `a -> r`

Cons takes a step function `(i -> a -> a)`. The accumulator `a` is threaded
through the chain by `foldr`-like composition. But that threading is exactly
what Category composition already provides:

```haskell
-- Old: cons adds a step that accumulates
cons f p = Hyper $ \q i -> f i (invoke q p)

-- The inner p already threads a through. The f i just wraps another layer.
-- Replace with pure transformation:
--   just Hyper a b — Category composition handles the threading
```

If the accumulator threading is just Category composition, the step function
simplifies from `(i -> a -> a)` to `(i -> a)`.

---

## 6. Extract the atomic endpoints

With `i -> a` instead of `i -> a -> a`, the two sides reveal their atoms:

```haskell
-- Producer side:
Hyper (o -> a) a  → normalize: Hyper () a   — an Emit
--   The (o -> a) is a function waiting for input.
--   At the atomic end, o = (), input is nothing — just produce a value.

-- Consumer side:
Hyper a (i -> a)  → normalize: Hyper a ()   — a Commit
--   The (i -> a) is a function outputting a.
--   At the atomic end, output is () — just consume a value.
```

**Emit a = Hyper () a** — atomic producer. Produces an `a` when invoked.

**Commit a = Hyper a ()** — atomic consumer. Accepts an `a`, returns nothing.

```haskell
emit :: a -> Emit a
emit a = Hyper $ \_ -> a

forget :: Commit a
forget = Hyper $ \_ -> ()
```

These carry no internal state. They're pure value sources and sinks.
State is threaded externally via Category composition.

---

## 7. Everything between is Category composition

With Emit and Commit as endpoints, the middle is just `Hyper a b`:

```haskell
processor :: Hyper a r     -- transform a value
feeder    :: Hyper r a     -- feed a value back

-- Producer chain (emit → process):
feeder . emit :: Hyper () r

-- Consumer chain (process → forget):
forget . processor :: Hyper a ()

-- Full pipeline:
forget . processor . emit :: Hyper () ()
```

The whole pipeline is `forget . processor . emit :: Hyper () ()`.

No prod. No cons. No `foldr`. No coinductive `h = cons step h`.
Just Category composition on Hyper.

---

## 8. Counit and unit

`forget . processor . emit :: Hyper () ()` is a **counit** — it annihilates
the dual pair (Emit/Commit) through the middle processor. Running it:

```haskell
run (forget . processor . emit) :: ()
```

The channel closes. Value flows emit → processor → forget, then disappears
into `()`.

The **unit** is constructing an open channel — any `Hyper a b` is a unit
that creates a dual pair:

```haskell
-- Open a channel from a to b:
open :: Hyper a b -> Hyper () ()
open h = forget . h . emit   -- close it into a loop
```

But the open channel is the interesting part — it's `Hyper a b` itself.

---

## 9. FRP / MVC analogy

```
emit  :: Hyper () a       — View  (outputs a value)
h     :: Hyper a b        — Model (transforms)
forget :: Hyper b ()      — Controller (receives a value)
```

`forget . h . emit :: Hyper () ()` is a closed-loop FRP system.
The Model doesn't know about View or Controller — it's just `Hyper a b`.
The endpoints wire it into the world.

This is NOT the same as `lower h :: a -> b`. A function `a -> b` assumes
every input produces a corresponding output — input is wired to output.
A Hyper `a ↬ b` doesn't make that assumption. The two ports are independent.

---

## 10. File example — why this matters

Consider opening a file for reading and writing:

```haskell
openFile :: FilePath -> Hyper (IO Text) Text
```

This isn't a function `IO Text -> Text`. It's a Hyper where:
- The contravariant side (`IO Text`) is what you write to the file
- The covariant side (`Text`) is what you read from the file
- **Input is NOT wired to output** → they're separate operations

Lowering this gives `IO Text -> Text` — which suggests every write
triggers a read, nonsense. The Hyper is honest: the two sides are
independent ports on the same resource.

```
          ┌──────────┐
  write   │          │  read
IO Text ─▶│  file    │──▶ Text
          │          │
          └──────────┘
```

This is the fundamental difference between a function and a hyperfunction.
A function is a directed pipe. A Hyper is an open channel — two independent
continuations that share a resource.

---

## 11. Isomorphism confirmed

The isomorphism holds. Both pipelines produce identical results:

```haskell
-- OLD: prod/cons chain (invoke-based threading)
oldPipeline :: [Int] -> [Int]
oldPipeline xs = withQ
  (foldr (\x p -> prod x p) (doneP []) xs)
  (fix (\self -> cons (\x acc -> x : acc) self))

-- NEW: Category composition (lift-based)
newPipeline :: [Int] -> [Int]
newPipeline xs = lower
  (foldr (\x acc -> lift (\rest -> x : rest) . acc)
         (lift $ const [])
         xs)
  ()

-- >>> oldPipeline [1,2,3] == newPipeline [1,2,3]
-- True
```

Both build O(n) Hyper layers. Both thread values through. But the
mechanism differs:

⟜ **Old**: `prod o p = Hyper $ \q -> invoke q p o`
   — uses `invoke` to thread the continuation and element together.
   The function `invoke q p :: o -> a` is constructed and applied to `o`.

⟜ **New**: `lift (\rest -> x : rest) . acc`
   — uses Category composition to chain layers. Each layer wraps
   the previous accumulator with a prepend operation.

The same structure, different encoding. prod/cons are a **derived
pattern** — built from Emit (value source) and Category composition
(continuation threading).

---

## 12. Echo channel test (IORef) — independent I/O confirmed

An echo channel: write a String, read back accumulated state.
The key property: input and output are INDEPENDENT.

```haskell
echoChan :: IORef [String] -> Hyper String (IO [String])
echoChan ref = lift $ \input -> do
  modifyIORef' ref (\xs -> xs ++ [input])
  readIORef ref
```

Test results:

```
After 4 writes, content: ["alpha","beta","gamma","delta"]
Writes persist, Read 1:   ["stays","forever","extra1"]
Writes persist, Read 2:   ["stays","forever","extra1","extra2"]
```

This is NOT a function `String -> IO [String]`. A function would
map each String independently — write-once-read-once. This channel
accumulates state across invocations through the shared IORef.

And it's just `lift` + Hyper — no prod/cons.

---

## 13. layer — the self-dual core

Stacking `prod` and `cons` side by side with column-aligned `anchor`:

```haskell
prod a p = Hyper $ \anchor   ->        (anchor ⇸ p) a
cons f c = Hyper $ \anchor a -> f a    (anchor ⇸ c)
```

The same body. The only difference: in `prod`, `a` is captured at
construction time; in `cons`, `a` arrives at invocation time. And
`f` wraps the result on the left side.

Remove the outer lambda capture difference. What's the core
operation on the self-dual diagonal?

```haskell
layer :: Channel r a a -> Channel r a a
layer x = Hyper $ \anchor a -> (anchor ⇸ x) a
```

```
       anchor         inner    element
layer = \x -> Hyper $ \a  a -> (a ⇸ x) a
```

This is `cons ($)` — the underlying structure without `f`. It takes
a self-dual Hyper (Channel on the diagonal) and wraps it one layer
deeper. The element arrives at invocation time.

**But `layer` is NOT `prod` or `cons`.** A quick type check:

```haskell
layer :: Channel r a a -> Channel r a a
     == Hyper (a -> r) (a -> r) -> Hyper (a -> r) (a -> r)

prod  :: a -> Producer a r -> Producer a r
     == a -> Hyper (a -> r) r -> Hyper (a -> r) r
```

`layer` is self-dual (`r` on both sides). `prod` is asymmetric
(`r` on one side, `a -> r` on the other). The bodies look the same
but the types diverge because of the extra lambda argument.

Narrative said: `cons ($) = prod`.
Types said: no, different types.

The lesson: lay out the column alignment, feel the symmetry, then
check with GHC. The symmetry is structural, not definitional.

---

## 14. Open questions

⧈ What does `Hyper () ()` mean as a terminal object? Is it truly trivial,
   or does it carry information (e.g., an FRP system's global state)?

⧈ If Hyper Text (IO Text) is the right model for an open file, what does
   running it produce? `run :: Hyper (IO Text) Text -> ???` — not well-typed.

⧈ The file suggests we might want `Hyper` over a base arrow `Kleisli IO`,
   not `(->)`. What does that do to the prod/cons decomposition?

⧈ prod/cons as syntactic sugar — do we keep them in the module for
   pedagogy, or strip them entirely? Current Channel.hs has already
   removed them. The examples haven't caught up.

---

## Reference

- Kidney & Wu, POPL 2026 — §2.4 (Producer/Consumer), §5.1 (Channel)
- `01-stack-language.md` — axiom 5, push decomposition
- `06-rwr.md` — Mendler = viewl, same factorization pattern
- `src/Circuit/Channel.hs` — current Emit/Commit primitives
- `src/Circuit/Hyper.hs` — Hyper definition, Category/Profunctor instances
- `examples/channel-basics.md` — old examples (needs update)
