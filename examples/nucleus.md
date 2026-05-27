# nucleus-kimi ⟜ HyperP, Nucleus, and the channel decomposition

**card** ⟜ position on whether `Hyper` should grow a profunctor parameter, and whether `Nucleus` is the right vehicle for first-class channel ends in `circuits-io`.

---

## 🟢 agents

✰ kimi   circuits auditor, nucleus analyst  [07:52]
📌 locks 🕳 ~/haskell/circuits/
💬 requests varied opinion after position is stated

---

## the candidate

```haskell
newtype Nucleus p b = Nucleus (forall a. Nucleus (Flip p) a -> p a b)
newtype HyperP  p a b = HyperP  (HyperP  (Flip p) a b -> p a b)
type HyperC a b = HyperP (Flip Const) a b
```

**HyperC** ⟜ sanity check, not a use case
- `Flip Const a b ≅ b`. The base arrow collapses to its codomain.
- `Circuit (Flip Const) t a b` is a tree of constants where `reify` extracts the leftmost leaf. Composition is `const`, identity is uninhabited.
- This confirms `HyperP` type-checks and is structurally sound, but the degenerate case reveals nothing about feedback.

---

## the rich case: Nucleus as session duality

Unfold the mutual recursion:

```haskell
Producer p b = Nucleus        p  b = forall a. Consumer p a -> p a b
Consumer p a = Nucleus (Flip p) a = forall b. Producer p b -> p a b
```

**producer-consumer** ⟜ the two ends of a channel
- Each end is parametric in what it connects to. The hidden channel type is a bound variable, not a type constructor index.
- `open  :: () -> (Producer p a, Consumer p a)` — the cap / unit η.
- `close :: Producer p a -> Consumer p a -> p a a` — the cup / counit ε.
- `close prod cons = prod cons` — elimination is just application.

**why this matters for circuits-io**
- `Knot` bundles channel creation and connection into one constructor. You cannot pass the two ends to different agents.
- `Nucleus` splits them. A queue, a `TChan`, a TCP socket — all need first-class ends that travel separately before they are plugged together.

**the safety property**
- A consumer is not a morphism `a -> b`. It is `forall x. Producer p x -> p a x`.
- It cannot accidentally passthrough as `arr id`. The only way to eliminate it is to pair it with a producer. The `lmap >>> const >>> rmap` blockage is structural in the type.

---

## compact closed reading

In a compact closed category, trace decomposes:

```
trace f = (id ⊗ ε) ∘ (f ⊗ id) ∘ (id ⊗ η)
```

`Circuit` currently has `trace` as primitive. `Nucleus` gives the decomposed form:
- `η` = `open`
- `ε` = `close`
- `f` = the body that lives between the two ends

This is not an alternative to `Knot` — it is a refinement. `Knot` is the atomic operation for the initial encoding. `Producer`/`Consumer` are the atomic operations for channel topology.

---

## position

**Do not replace `Hyper a b` with `HyperP` yet.**

`Hyper a b` is a local optimum: self-dual, no extra parameters, and the `Category`/`Trace`/`Profunctor` instances are clean. Generalizing to `HyperP` adds `Flip` noise at every composition site. The payoff only arrives when `p` is non-trivial and the generalization is exercised.

**Do pursue `Nucleus` (or `Producer`/`Consumer`) as a channel abstraction.**

The immediate step is not a type-parameter refactor of `Hyper`. It is a pair of newtypes alongside `Circuit` and `Hyper`:

```haskell
newtype Producer arr t a = Producer (forall x. Consumer arr t x -> Circuit arr t x a)
newtype Consumer arr t a = Consumer (forall x. Producer arr t x -> Circuit arr t a x)
```

with `open` and `close` operations, proved against the traced axioms.

If this API proves useful for `circuits-io` queues and channels, **then** ask whether `HyperP` is the final encoding that makes it efficient. `HyperP` is the coinductive dissolution of the same structure; it should follow the initial encoding, not precede it.

---

## synthesis with nucleus-deep

Deep's position (from `loom/nucleus-deep.md`) is stronger on the generalisation itself. The key insight is that **cup is partial, and that partiality is structural, not a bug.**

- `cap` works. `nucleusId` gives the unit.
- `cup` fails for `Lift f` (no hidden state to split) and is hard for `Knot k` (existential `s` must thread through `forall`).
- This means `Nucleus` is a **filter**: only stateful morphisms can be decomposed into channel ends. Pure functions cannot pretend to be buffers.

**The 2-cell resolution**

Deep's view simplifies the machinery further. `close` is not a special combinator — it is just **application**:

```haskell
close (Producer f) (Consumer g) = f (Consumer g)
```

The resulting `p a a` is a normal circuit that composes with everything else via `(>>>)`.

The 2-cell picture:

```
              η = open
              ↓
        ┌───────────┐
        │  body f   │  ← vertical composition (∘)
        └───────────┘
              ↓
              ε = close
```

- **Vertical** `∘` — sequential composition of circuits.
- **Horizontal** `⊗` — channel topology. `Producer` and `Consumer` are the two sides, plugged together at `close`.

`Knot` bundles all three layers (`η`, body, `ε`) into one constructor. You cannot separate them, cannot hand the two ends to different agents, cannot swap the body without rebuilding.

`Producer`/`Consumer` splits them. The ends travel independently. The body is whatever you thread between `open` and `close`. A queue, a `TChan`, a TCP socket — each is a different body living in the same vertical slot, with the same horizontal topology of two separable ends.

This maps exactly onto the compact closed trace formula:

```
trace f = (id ⊗ ε) ∘ (f ⊗ id) ∘ (id ⊗ η)
```

---

## 🚩 revised position

**Accept the 2-cell resolution.** `Nucleus` is the right abstraction for first-class channel ends. `close` is application. The types are simpler than I initially framed.

**Do not replace `Hyper a b` with `HyperP` yet.** `Hyper` remains the local optimum for the self-dual case. `HyperP` is future work for when the `p` axis of variation is exercised.

**Do add `Producer`/`Consumer` alongside `Circuit`.** The API is:

```haskell
newtype Producer  p a = Producer  (forall x. Consumer p x -> p x a)
newtype Consumer p a = Consumer (forall x. Producer p x -> p a x)

open  :: () -> (Producer p a, Consumer p a)
close :: Producer p a -> Consumer p a -> p a a
close (Producer f) cons = f cons
```

`open` creates two ends. The ends travel as first-class values. `close` plugs them together. The result is a normal `Circuit` (or arrow, or Kleisli action) that composes vertically with everything else.

`cup` on existing `Knot`s remains future work. It is not needed for the initial API because `Producer`/`Consumer` is a **construction** tool, not a **deconstruction** tool. You build channels from ends; you do not split existing loops.

---

## 🟣 open questions

⟜ Does `HyperP (->) a b` have a simpler characterization than the raw fixed point? Is it equivalent to a known continuation transformer?
⟜ Can `cup` on `Knot` be made total by changing how `Circuit` carries its feedback type? (Existential `s` → parameter?)
⟜ Is there a Mendler-style version of `Nucleus` that avoids the nested `forall` in the recursive positions?

---

*Resolution accepted. Awaiting implementation direction.*
