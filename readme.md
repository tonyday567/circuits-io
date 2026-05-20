# circuits-io

IO combinators for the circuits library.

Built on `Circuit.Channel`'s Producer/Consumer framework. Provides
batteries-included IO operations: file I/O, IORef, socket, server,
timing, and async.

Absorbs and deprecates:
- `box` (Emitter/Committer pattern → Circuit.Channel)
- `web-rep` (HTTP combinators)
- `box-socket` (socket operations)

## Packages

- `circuits` — core: Circuit GADT, Hyper, Loop, Trace, Channel
- `circuits-io` — IO layer: fileIO, socket, server, timing, async
- `circuits-parser` — parsing: Parser, Uncons on These
- `circuits-perf` — benchmarking: once/times/warmup

---

## The claim: Hyper beats IntC

`circuits-io` is built on a categorical gamble. We claim that for
**programming** bidirectional communication, `Hyper` is a better model
than the Int construction — and that the Kidney-Wu Communicator
(POPL 2026) proves it.

### The Int construction is bureaucratic

Given a traced monoidal category C, the Int construction builds a
compact closed category Int(C). The price:

- Every object becomes a **pair** `(A⁺, A⁻)`
- Every morphism tracks **four** types: `f: (A⁺, A⁻) → (B⁺, B⁻)` is
  `f: A⁺ ⊗ B⁻ → B⁺ ⊗ A⁻` in C
- Composition traces over the intermediate's feedback channel
- Cup and cap are external structural isomorphisms

For programming, this is painful. You don't want to write `(A⁺, A⁻)`
every time you mean `A`. You don't want to thread four type parameters
through every composition.

### Hyper internalizes the duality

`Hyper a b` is the domain-theoretic solution to the equation:

```
X ≅ (X ⇒ A) ⇒ B
```

This is a **mutual fixed point**: `Hyper a b` refers to `Hyper b a`,
which refers back. The duality is not external (as a pair of objects).
It is **structural recursion in the type itself**.

Kidney & Wu show that this type, equipped with appropriate operations,
forms a fully-abstract model of CCS — the Calculus of Communicating
Systems. No compact closed category needed. No cup/cap. No zig-zag
proof. Just `invoke`.

### What `invoke` is

```haskell
invoke :: Hyper a b -> Hyper b a -> b
```

This is the **counit** of the compact closed story, but it doesn't need
cups or caps. It takes a morphism and its dual continuation and
produces a result. In `circuits-io`, this is how producers talk to
consumers, how agents negotiate, how channels close.

The Communicator model from the paper:

```haskell
type Communicator n r = (Message n -> r) ↬ (Message n -> r)
```

is exactly `Channel r (Message n) (Message n)` in our vocabulary — a
self-dual hyperfunction on message-passing functions.

### The circuits-io types

`Circuit.Channel` provides the atomic vocabulary:

| Type | Meaning | K&W name |
|------|---------|----------|
| `Emit a = () ↬ a` | Produce a value | — |
| `Commit a = a ↬ ()` | Consume a value | — |
| `Channel r i o` | `(o → r) ↬ (i → r)` | `Channel` |
| `Producer a r` | `(a → r) ↬ r` | `Producer` |
| `Consumer a r` | `r ↬ (a → r)` | `Consumer` |

`prod` and `cons` are the Kidney-Wu constructors. `layer` is the
self-dual core. All three thread the inner hyperfunction through the
continuation, placing the element on the right.

### Why this wins

| | Int construction | Hyper |
|--|------------------|-------|
| Object | Pair `(A⁺, A⁻)` | Single type `A` |
| Morphism | 4-parameter `A⁺ ⊗ B⁻ → B⁺ ⊗ A⁻` | 2-parameter `Hyper a b` |
| Duality | External object `A* = (A⁻, A⁺)` | Internal continuation `Hyper b a` |
| Composition | Trace over intermediate channel | Direct `invoke` |
| Cup/cap | Required structural isomorphisms | Not needed — fixed point IS the channel |
| Programming | Bureaucratic | Ergonomic |

The compact closed category is the **denotational** answer: "how do we
give semantics to processes with feedback?" Hyper is the
**operational** answer: "processes are self-dual continuations that
communicate via `invoke`." Kidney-Wu proved this is enough for full
abstraction.

### The frontier

`circuits-io` pushes this into effectful territory: `Kleisli IO`
channels, STM queues, delimited continuations, async. The core insight
remains: a `Channel r i o` is not a pair of endpoints. It is a single
hyperfunction that carries both directions in its recursive structure.

Two agents:

```haskell
agentA :: Hyper Request Response
agentB :: Hyper Response Request
```

talk to each other with `invoke`. No explicit channel allocation. No
cup. No cap. The self-referential fixed point IS the channel.

This is the circuits-io thesis.
