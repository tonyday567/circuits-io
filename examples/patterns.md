# patterns ⟜ two ways to structure programs

Hyper and Circuit offer two distinct patterns for structuring
programs. Both work. They do different things.

---

## 1. Hyper self-dual — Emit/Commit annihilation

An `Emit a = Hyper () a` produces a value. A `Commit a = Hyper a ()`
consumes a value. They are dual. Compose them and they annihilate.

### Counit — close a channel

```
emit a   :: Hyper () a      — produce a
forget   :: Hyper a ()      — consume a

counit   :: a -> Hyper () ()
counit a  = forget . emit a    — annihilate the pair

lower (counit a) () = ()     — the value flows through and is gone
```

With a processor between them:

```haskell
import Circuit.Hyper
import Circuit.Channel
import Control.Category
import Prelude hiding (id, (.))

-- 42 → show → discard
lower (forget . lift (show :: Int -> String) . emit 42) ()
-- ()
```

Every layer is a Hyper. The pipeline IS the program — build by
composing, run via `lower`. No dual pairs, no invoke threading.
Just `(.)` and `lower`.

### Unit — open a channel

Create two connected ends from a shared resource. The ends are
independent Hypers. They compose with other Hypers independently.
The resource IS the connection — not Category composition.

```haskell
import Data.IORef

-- Unit creates an Emit/Commit pair backed by an IORef.
--   reader :: Hyper () (IO Int)         — Emit end: read current value
--   writer :: Hyper Int (IO ())         — Commit end: write a new value
mkChannel :: IORef Int -> (Hyper () (IO Int), Hyper Int (IO ()))
mkChannel ref = (reader, writer)
  where
    reader = lift (\() -> readIORef ref)
    writer = lift (writeIORef ref)

-- Use the ends independently. They share state through the IORef.
ref <- newIORef 0
let (reader, writer) = mkChannel ref

lower writer 42                  -- write 42
val <- lower reader ()           -- read → 42

-- Compose each end with its own pipeline:
let formatter = lift (fmap (\n -> "counter: " ++ show n))
    printer   = lift (mapM_ putStrLn . fmap pure)
    pipeline  = printer . formatter . reader :: Hyper () (IO ())

lower pipeline ()                -- prints "counter: 42"
```

The unit pattern is: create open ends, compose pipelines, close
via composition. Each end is a Hyper — they can be composed with
`(.)`, stored, passed around. The resource (IORef) is shared state
between them, not structural coupling.

### Key properties

- **Composable** — layers are `Hyper a b`, composed with `(.)`
- **Open-ended** — you can have open Emit or Commit ends that
  persist across multiple invocations
- **Coinductive possible** — the structure supports infinite
  streams (see `hyper-stream.md`, `lazy-knot-tying.md`)

---

## 2. Circuit Loop — bracketed resource acquisition

A `Knot` wraps a loop body. The tensor's `trace` runs the entire
loop — acquire, use, release — in one atomic step. There is one
entry and one exit.

### The pattern

```haskell
-- The canonical form:
--   Knot $ \loop -> Lift acquire >>> loop >>> Lift release
--
-- The trace runs: acquire → loop → release → exit
-- The loop is the "use" phase, provided by the caller.

withCounter :: Circuit (,) Int Int Int
withCounter init = Knot $ \loop ->
  Lift (\x -> (x + init, x)) >>>   -- acquire: create pair
  loop >>>                           -- use: transform  
  Lift fst                           -- release: extract result
```

From `examples/resource-io.md` — the file reader pattern:

```haskell
-- A resource-aware file reader: acquires the handle, reads all lines,
-- closes, returns the contents. The loop body alternates between
-- reading (Left = continue) and closing (Right = exit).
fileReader :: FilePath -> Circuit (Kleisli IO) Either () Text
fileReader path = loopIO \case
  () -> do                                    -- acquire
    h <- openFile path ReadMode
    pure (Left (h, []))                       -- state: (handle, acc)
  (h, acc) -> do                              -- use + decide
    eof <- hIsEOF h
    if eof
      then hClose h >> pure (Right (Text.pack $ unlines $ reverse acc))  -- release → exit
      else do
        line <- hGetLine h
        pure (Left (h, line : acc))           -- continue
```

The type guarantees: every exit path (`Right`) must call `hClose`.
You cannot leave the loop without releasing the resource — the type
system enforces it.

### Key properties

- **Atomic** — trace runs acquire → use → release in one step
- **Bracketed** — guaranteed cleanup, enforced by the exit type
- **Either trace iterates** — `traceEither` feeds `Left` back until
  it hits `Right`, then returns. A while-loop. The `(,)` trace
  creates a lazy fixpoint — already coinductive (see Fibonacci in
  `lazy-knot-tying.md`).
- **Type-guaranteed** — the Either tensor's `Right` path is the
  only way out; that path must include the release logic

---

## Comparison

| | Hyper self-dual | Circuit Loop |
|---|---|---|
| Build | `forget . f . emit` | `Knot $ \l -> Lift a >>> l >>> Lift r` |
| Run | `lower pipeline ()` | `reify circuit input` |
| Composition | Open — `(.)` on Hypers | Closed — trace is the composition |
| Loop mechanism | None — `(.)` threads layers | `traceEither` iterates, `tracePair` fixpoints |
| Resource safety | Manual (IORef cleanup) | Type-guaranteed (exit = release) |
| Best for | Streaming, pipelines, open channels | Bracketed resources, state machines |

The Hyper pattern builds on `Emit`/`Commit` from `Circuit.Channel`
(K&W canon), composed with Category. The Circuit pattern builds on
`Lift`/`Compose`/`Knot` — different primitives, different structure.
The bridge is `toHyper`/`toHyperE`: Circuit structures convert to
Hypers, gaining open composition via `(.)` while retaining their
loop structure.

The Hyper pattern is the general case: open, composable, coinductive.
The Circuit Loop is the specialized case: closed, bracketed, safe.
Neither replaces the other. They handle different problems.

---

## References

- `Circuit.Channel` — Emit, Commit, prod, cons
- `examples/channel-refactor.md` — prod/cons ≅ Emit/Commit + Category
- `examples/resource-io.md` — Circuit Loop with Kleisli IO
- `examples/hyper-stream.md` — coinductive Hyper streams
- `examples/lazy-knot-tying.md` — (,) trace as lazy knot
- `04-hyper.md` — toHyper/toHyperE: Circuit → Hyper conversion
