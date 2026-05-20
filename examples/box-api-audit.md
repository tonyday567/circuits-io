# Box API Audit — Mapping to circuits-io

Systematic walkthrough of every exported symbol in `box-0.9.4.0`, with a verdict:

| Verdict | Meaning |
|---------|---------|
| ✅ **KEEP** | Port directly to circuits-io |
| 🔄 **REWRITE** | Needed, but shape changes (document how) |
| ❌ **DROP** | Not needed — superseded by `Circuit`/`Hyper` primitives or not useful |
| ❓ **UNCLEAR** | Needs design decision |

The target algebra is `Circuit (Kleisli IO) Either` (step circuits with IO effects) and `Hyper` (final encoding) from the `circuits` package. The key mapping:

```
Box m c e        ~  Circuit (Kleisli m) Either c e
Emitter m a      ~  Circuit (Kleisli m) Either () a   (source)
Committer m a    ~  Circuit (Kleisli m) Either a ()   (sink)
Codensity m a    ~  bracket / withFile / direct IO
```

Concurrency (`race`, `concurrently`) stays at the IO interpretation layer, *outside* the circuit algebra.

---

## Box.Functor

| Symbol | Verdict | Notes |
|--------|---------|-------|
| `FFunctor` | ❌ DROP | Only used for `foist`/`foistb` (monad morphism lifting). `Circuit` is already parametric in `m`; no need for a separate class. |
| `foist` | ❌ DROP | `Circuit (Kleisli m) Either` → `Circuit (Kleisli n) Either` is just `fmap` over the `Kleisli` if you have `m a -> n a`. Not a user-facing concern. |
| `FoldableM` | ❌ DROP | Only used for `toListM` on `Emitter`. We can write `toListM` directly without a type class. |
| `foldrM` | ❌ DROP | Same as above. |

**Rationale:** These are type-class abstractions that box needed because `Box`/`Emitter`/`Committer` are defined as newtypes. In the `Circuit` world, folding and functor lifting are either free (parametricity) or not needed as a class.

---

## Box.Committer

| Symbol | Verdict | Notes |
|--------|---------|-------|
| `Committer` (newtype) | 🔄 REWRITE | Becomes `type Committer m a = Circuit (Kleisli m) Either a ()`. Or we keep the newtype wrapper for Haddock discoverability. |
| `commit` | 🔄 REWRITE | `runKleisli . reify` on a `Circuit (Kleisli m) Either a ()`. The `Bool` success signal becomes `Right ()` / `Left a` in the Either loop. |
| `CoCommitter` | ❌ DROP | `Codensity m (Committer m a)` was for resource bracketing. Use direct `bracket` or `with...` at the call site. |
| `witherC` | 🔄 REWRITE | Filtering/preprocessing on the input side. In `Circuit` terms this is just `lmap` (precomposition) with a Kleisli arrow that returns `Maybe`. |
| `listC` | 🔄 REWRITE | Turn a single-item committer into a list committer. This is `traverse` + `or`. Easy helper. |
| `push` | 🔄 REWRITE | State-based committer to `Seq`. Could live in a `circuits-io-extras` or examples module. |

**`Committer` rewrite detail:**

```haskell
-- OLD
newtype Committer m a = Committer { commit :: a -> m Bool }

-- NEW (option A: direct alias)
type Committer m a = Circuit (Kleisli m) Either a ()

-- NEW (option B: newtype wrapper for docs)
newtype Committer m a = Committer { unCommitter :: Circuit (Kleisli m) Either a () }
-- with commit = runKleisli . reify . unCommitter
```

The `Bool` return was "did I successfully consume this?" In an Either-loop circuit, `Right ()` means "consumed, continue" and `Left a` means "rejected, feed back the same `a`". This is a richer signal.

---

## Box.Emitter

| Symbol | Verdict | Notes |
|--------|---------|-------|
| `Emitter` (newtype) | 🔄 REWRITE | Becomes `type Emitter m a = Circuit (Kleisli m) Either () a`. Or newtype wrapper. |
| `emit` | 🔄 REWRITE | `runKleisli . reify` on `Circuit (Kleisli m) Either () a`. `Maybe` becomes `Either () a`. |
| `CoEmitter` | ❌ DROP | Same reasoning as `CoCommitter`. Bracketing is explicit `with...` in IO. |
| `toListM` | 🔄 REWRITE | Collect all `Right` values from a `Circuit (Kleisli m) Either () a` until `Left ()`. |
| `witherE` | 🔄 REWRITE | Filtering on the output side. In `Circuit` this is `rmap` (postcomposition) with a Kleisli `a -> m (Maybe b)`. |
| `filterE` | 🔄 REWRITE | Like `witherE` but skips `Nothing` and keeps pulling. This is a Kleisli arrow loop inside the circuit. |
| `readE` | 🔄 REWRITE | Parse `Text` to `Read` values. Just `fmap` + `reads`. |
| `unlistE` | 🔄 REWRITE | Flatten `Emitter m [a]` to `Emitter (StateT [a] m) a`. In `Circuit` terms this is `unfold` state carried through `ambient`. |
| `takeE` | 🔄 REWRITE | Counted take. Easy with a `StateT Int` Kleisli wrapper, or with `Circuit` knot + counter. |
| `dropE` | 🔄 REWRITE | Skip first N. `Codensity` version runs the emitter N times then hands it off. In circuits-io: `replicateM_ n emit >> pure circuit`. |
| `takeUntilE` | 🔄 REWRITE | Stop when predicate holds. One-shot Kleisli wrapper. |
| `pop` | 🔄 REWRITE | State-based emitter from `Seq`. Like `push`, could be an example/extras helper. |

**`Emitter` rewrite detail:**

```haskell
-- OLD
newtype Emitter m a = Emitter { emit :: m (Maybe a) }

-- NEW
newtype Emitter m a = Emitter { unEmitter :: Circuit (Kleisli m) Either () a }

emit :: Emitter IO a -> IO (Maybe a)
emit e = runKleisli (reify (unEmitter e)) () >>= \case
  Left ()  -> pure Nothing
  Right a  -> pure (Just a)
```

The `Alternative`/`Monad` instances on `Emitter` are interesting — they do left-biased choice and sequencing. In `Circuit` terms:
- `pure a` = `Lift (Kleisli (\() -> pure (Right a)))`
- `>>=` = sequential composition via `Compose` + Kleisli bind
- `<|>` = left-biased choice. This is **not** a primitive in `Circuit`. We'd need an explicit combinator at the interpretation layer, or wrap the circuit in a newtype that provides `Alternative`.

**Key question:** Do we need `Emitter` to be `Alternative`? The left-biased `<|>` is used for things like "try this source, if empty try that source". This can be done at the IO layer with `race` or `concurrently` + a queue, or with an explicit `chooseE` combinator.

---

## Box.Box

| Symbol | Verdict | Notes |
|--------|---------|-------|
| `Box` (data) | 🔄 REWRITE | `data Box m c e = Box (Committer m c) (Emitter m e)`. In Circuit terms this is just `Circuit (Kleisli m) Either c e` — the pair is already the profunctor. |
| `CoBox` | ❌ DROP | `Codensity m (Box m a b)`. Not needed — resource management is explicit. |
| `CoBoxM` | ❌ DROP | `newtype` wrapper for `Semigroupoid` on `CoBox`. Not needed. |
| `bmap` | 🔄 REWRITE | `dimap` + filtering. In `Circuit` this is `dimap (Kleisli filterIn) (Kleisli filterOut)`. |
| `foistb` | ❌ DROP | Covered by `Circuit` parametricity. |
| `glue` | 🔄 REWRITE | The fundamental "connect emitter to committer" loop. In `Circuit` this is literally `reify` + `runKleisli` on a composed circuit! |
| `glue'` | 🔄 REWRITE | Same as `glue` but returns closure reason. The `Either` loop already distinguishes `Left` (feedback/continue) from `Right` (exit). |
| `glueN` | 🔄 REWRITE | Take N then stop. This is `takeE` on the emitter + `glue`. |
| `glueES` | 🔄 REWRITE | Stateful emitter + plain committer. In `Circuit` this is `reify` with `StateT` inside the `Kleisli`, or `ambient` to thread state. |
| `glueS` | 🔄 REWRITE | Both sides stateful. Same pattern. |
| `fuse` | 🔄 REWRITE | Apply a transformation inside the box then glue. In `Circuit` this is `dimap` + `reify`. |
| `Divap` | ❌ DROP | Combines `Divisible` + `Applicative` for `Box`. `Circuit` already has `Profunctor` + `Category` — this combination is not a standard abstraction and was only used for exotic wiring. |
| `DecAlt` | ❌ DROP | Combines `Decidable` + `Alternative` for `Box`. Same reasoning. |
| `cobox` | ❌ DROP | `Box <$> c <*> e` in `Codensity`. Not needed. |
| `seqBox` | 🔄 REWRITE | State-based `Box` over `Seq`. Example-level helper. |
| `dotco` | ❌ DROP | CPS composition of `CoBox`. Not needed without `Codensity`. |

**`Box` rewrite detail:**

```haskell
-- OLD
data Box m c e = Box { committer :: Committer m c, emitter :: Emitter m e }

-- NEW — Box is just Circuit!
type Box m c e = Circuit (Kleisli m) Either c e

-- The constructor is not needed; profunctor combinators replace it.
-- dimap f g (box :: Box m c e)  =  Box (contramap f committer) (fmap g emitter)
```

**`glue` rewrite detail:**

```haskell
-- OLD
glue :: Monad m => Committer m a -> Emitter m a -> m ()
glue c e = fix $ \rec -> emit e >>= maybe (pure False) (commit c) >>= bool (pure ()) rec

-- NEW — if Committer and Emitter are Circuit aliases:
glue :: Monad m => Committer m a -> Emitter m a -> m ()
glue c e = runKleisli (reify (c . e)) ()
-- where c :: Circuit (Kleisli m) Either a ()
--       e :: Circuit (Kleisli m) Either () a
--       c . e :: Circuit (Kleisli m) Either () ()
--       reify gives Kleisli () (Either () ())
--       runKleisli with () input runs the loop
```

Wait — this is the key insight! In `Circuit (Kleisli m) Either`, sequential composition `.` (Compose) already IS glue. The `Knot` ties feedback, but for a simple pipe from `()` to `()` through `a`, it's just `c . e` or `e >>> c`.

Actually let me be careful. `Circuit (Kleisli m) Either () ()` with `Compose c e` means:
- Start with `()`
- Run `e`: produces `Either () a`
- If `Left ()`, stop (first Nothing from emitter)
- If `Right a`, pass `a` to `c`
- Run `c`: produces `Either a ()`
- If `Left a`, feedback (committer rejected, try again... but with what?)
- If `Right ()`, continue

Hmm, this doesn't quite match. The `Box.glue` semantics are:
1. `emit` produces `Maybe a`
2. If `Nothing`, stop
3. If `Just a`, `commit a` produces `Bool`
4. If `False`, stop
5. If `True`, loop

In the `Circuit` loop:
- `Emitter` step: `() -> m (Either () a)` — `Left ()` means "no more values" (Nothing)
- `Committer` step: `a -> m (Either a ())` — `Left a` means "rejected, here's the value back" (False), `Right ()` means "accepted, continue"

But wait — if committer returns `Left a`, what happens? The `Either` trace loops, feeding `Left a` back... but to what? The circuit structure is `c . e`, so the feedback goes to the *input* of `c`, not back to `e`. We'd need a `Knot` to recycle rejected values.

Actually for the simple case where committer never rejects (`Bool` is always `True`), `c . e` works fine: emitter produces `Right a`, committer consumes and returns `Right ()`, and the trace loops because `trace` on `Kleisli IO` Either uses delimited continuations to restart from the prompt.

Let me re-examine. `trace` for `Kleisli IO Either`:
```haskell
trace (Kleisli body) = Kleisli $ \initial -> do
  tag <- newPromptTag
  let go x = prompt tag $ body x >>= \case
               Right c -> pure c
               Left a  -> control0 tag (\k -> k (go (Left a)))
  go (Right initial)
```

For `c . e :: Circuit (Kleisli IO) Either () ()`:
- `reify` on `Compose c e` = `reify c . reify e` (when neither is Knot)
- `reify c :: Kleisli IO (Either a ()) (Either a ())` ... wait no.

Let me re-read `reify`:
```haskell
reify (Lift f) = f
reify (Compose (Knot f) g) = trace (f . untrace (reify g))
reify (Compose f g) = reify f . reify g
reify (Knot k) = trace k
```

For `Compose c e` where neither is `Knot`:
`reify (Compose c e) = reify c . reify e`

If `e = Lift (Kleisli emitStep)` and `c = Lift (Kleisli commitStep)`:
`reify (Compose c e) = Kleisli commitStep . Kleisli emitStep = Kleisli (\() -> emitStep () >>= commitStep)`

Wait, Kleisli composition is `(f . g) x = g x >>= f`. So:
`runKleisli (reify (Compose c e)) () = emitStep () >>= commitStep`

But `emitStep () :: IO (Either () a)` and `commitStep :: a -> IO (Either a ())`. So the types don't match for Kleisli composition! `emitStep` returns `IO (Either () a)`, and `commitStep` expects `a`, not `Either () a`.

Ah! The issue is that `Circuit (Kleisli m) Either () a` doesn't mean `Kleisli m () (Either () a)`. It means a *circuit* where the base arrow is `Kleisli m` and the tensor is `Either`. The `reify` function turns the whole circuit into a `Kleisli m () (Either () a)` — no, wait.

Let me re-read `Circuit` more carefully:
```haskell
data Circuit arr t a b where
  Lift :: arr a b -> Circuit arr t a b
  Compose :: Circuit arr t b c -> Circuit arr t a b -> Circuit arr t a c
  Knot :: arr (t a b) (t a c) -> Circuit arr t b c
```

So `Circuit (Kleisli IO) Either () a` has kind... it's `Circuit arr t a b` where `a = ()` and `b = a` (the element type). So `reify` gives `Kleisli IO () a`? No, `reify :: Circuit arr t x y -> arr x y`. So `reify` gives `Kleisli IO () a`.

But that's not right either because the circuit can loop. The `trace` for `Kleisli IO Either` gives `Kleisli IO b c` from `Kleisli IO (Either a b) (Either a c)`. So `reify` on a `Knot` gives `Kleisli IO b c` — it consumes `b` and produces `c`, with internal looping.

For `Lift (Kleisli f) :: Circuit (Kleisli IO) Either () a`, `reify` gives `Kleisli IO () a`, which is `() -> IO a`.

OK so the type of `reify` on `Circuit (Kleisli IO) Either () a` is `Kleisli IO () a`, not `Kleisli IO () (Either () a)`. The `Either` is internal to the circuit structure, not part of the observable input/output.

But how does `Lift` embed a Kleisli arrow into an Either circuit? `Lift :: arr a b -> Circuit arr t a b`. So `Lift (Kleisli (\() -> pure (Right 1))) :: Circuit (Kleisli IO) Either () Int`. And `reify` on this gives `Kleisli (\() -> pure (Right 1)) :: Kleisli IO () Int`.

Wait, that's `Kleisli IO () (Either () Int)`, not `Kleisli IO () Int`. Because the Kleisli arrow is `() -> IO (Either () Int)`.

Hmm, but `reify (Lift f) = f`. So `reify (Lift (Kleisli (\() -> pure (Right 1)))) = Kleisli (\() -> pure (Right 1))`. The type of this is `Kleisli IO () (Either () Int)`. But `arr a b` is `Kleisli IO () Int` if `a = ()` and `b = Int`... no wait.

`Kleisli m a b` is `newtype Kleisli m a b = Kleisli { runKleisli :: a -> m b }`. So `Kleisli IO () (Either () Int)` is `Kleisli IO () (Either () Int)`. If `a = ()` and `b = Either () Int`.

But `Circuit (Kleisli IO) Either () Int` means the circuit goes from `()` to `Int`. And `reify` gives `Kleisli IO () Int`. But `Lift` takes `arr a b = Kleisli IO () Int`. So `Lift (Kleisli (\() -> pure (Right 1)))` would have type `Circuit (Kleisli IO) Either () (Either () Int)`, not `Circuit (Kleisli IO) Either () Int`.

This is confusing. Let me think about it differently.

For `Box`, the `Emitter m a` is `m (Maybe a)` and `Committer m a` is `a -> m Bool`. In `Circuit` terms:
- A producer of `a` values that can end is a loop: start with `()`, produce `a`, loop. When done, exit.
- In `Circuit (Kleisli IO) Either () a`, we'd need a `Knot` to loop. The `Knot` takes `Kleisli IO (Either () ()) (Either () a)`... no.

`Knot :: arr (t a b) (t a c) -> Circuit arr t b c`

For `Either` tensor: `Knot :: Kleisli IO (Either a b) (Either a c) -> Circuit (Kleisli IO) Either b c`

So to make an emitter that loops and produces `a`s:
`Knot (Kleisli (\case Right () -> produceA; Left () -> pure (Left ()))) :: Circuit (Kleisli IO) Either () a`

Wait, `b = ()` and `c = a`. So `Knot :: Kleisli IO (Either a ()) (Either a a) -> Circuit (Kleisli IO) Either () a`. That doesn't make sense.

Let me re-read the types more carefully.

`Knot :: arr (t x b) (t x c) -> Circuit arr t b c`

For `Either`: `Knot :: Kleisli IO (Either x b) (Either x c) -> Circuit (Kleisli IO) Either b c`

If we want `Circuit (Kleisli IO) Either () a` (a circuit from `()` to `a`):
`b = ()`, `c = a`. So `Knot :: Kleisli IO (Either x ()) (Either x a) -> Circuit (Kleisli IO) Either () a`.

The `x` is the feedback channel type — it's existential in a sense, chosen by the knot.

For an emitter: we want to start with `()`, produce an `a`, and either loop (continue) or exit (stop). The feedback channel could be `()` for "continue".

```haskell
emitterStep :: IO a -> Circuit (Kleisli IO) Either () a
emitterStep ioa = Knot $ Kleisli $ \case
  Right () -> do
    a <- ioa
    pure (Right a)  -- produce a, but how do we loop?
  Left () -> pure (Left ())  -- feedback = continue
```

Hmm, but `Knot` only runs once through `trace`. The `trace` on `Kleisli IO Either` loops internally:
```haskell
trace (Kleisli body) = Kleisli $ \initial -> do
  tag <- newPromptTag
  let go x = prompt tag $ body x >>= \case
               Right c -> pure c
               Left a  -> control0 tag (\k -> k (go (Left a)))
  go (Right initial)
```

So `body` gets called repeatedly. On `Right ()` it does the IO, on `Left ()` it... but `Left` only comes from feedback, and feedback is only produced by `body` itself.

For an emitter that keeps producing values:
```haskell
emitterFromList :: [a] -> Circuit (Kleisli IO) Either () a
emitterFromList xs = Knot $ Kleisli $ \case
  Right () -> pure (Left xs)  -- initial state: the list
  Left [] -> pure (Right ())  -- done: exit with ()
  Left (x:xs') -> pure (Right x)  -- produce x and... wait, how do we pass xs'?
```

The issue is that `Left a` feeds back `a`, but the output on `Right` is `c`, not a pair of (new state, output). This is where `ambient` comes in — it threads state through.

Actually, looking at `Circuit.Traced.trace` for `(,)`:
```haskell
trace f b = let (a, c) = f (a, b) in c
```

For `(,)`, the feedback and output are simultaneous — the function returns both. For `Either`, it's sequential:
```haskell
trace f b = go (Right b)
  where go x = case f x of Right c -> c; Left a -> go (Left a)
```

The `Left a` is fed back to `f` as input. So `f :: Either a b -> Either a c`.

For a list emitter with state:
`f :: Either [a] () -> Either [a] a`
- `Right ()` — start, initial state `xs`. But where does `xs` come from?
- `Left xs` — feedback state
- Output: `Right x` means "produced x, but what about remaining xs'?"

The problem is that `Either` only has one value — you can't return both the new state and the output. You'd need nested Eithers or the `(,)` tensor.

Wait! That's exactly why `ambient` exists. `ambient` threads state alongside:
```haskell
ambient :: (Profunctor arr, Trace arr t) => (forall x y z. t x (t y z) -> t y (t x z)) -> Circuit arr t a b -> Circuit arr t (t s a) (t s b)
```

For `(,)`: `ambient braid c :: Circuit arr (,) (s, a) (s, b)` threads state `s` through circuit `c`.

For `Either`... `ambient` for `Either` would need a braid `Either x (Either y z) -> Either y (Either x z)`. Is that possible?

```haskell
braidEither :: Either x (Either y z) -> Either y (Either x z)
braidEither (Left x) = Right (Left x)
braidEither (Right (Left y)) = Left y
braidEither (Right (Right z)) = Right (Right z)
```

Yes! So `ambient braidEither` threads state through an `Either`-loop circuit.

But this is getting complex. Maybe for `circuits-io`, we should keep `Emitter` and `Committer` as newtypes over `IO (Maybe a)` and `a -> IO Bool` respectively, but implement them in terms of `Circuit` under the hood. Or maybe we keep them as-is and just drop the `Box` dependency by redefining them locally.

Actually, the user's goal is to *drop the `box` dependency*. The simplest way to do this while keeping the socket code working is:
1. Redefine `Committer`, `Emitter`, `Box` locally in `circuits-io`
2. Port the socket code to use these local definitions
3. Over time, refactor to use `Circuit` primitives

But the user said "step through and, for each api element in box, we say ok, that's something we need, or that's not a thing, or how do we do that". So they want a full audit to decide what to port.

Let me continue the audit but be more practical. I'll note where things map cleanly to `Circuit`, where they need wrappers, and where they're just convenience functions.

Actually, maybe I should simplify the mapping. The `Box` package's core abstraction is:
- `Committer m a` = consumer
- `Emitter m a` = producer  
- `Box m c e` = pair of consumer + producer
- `glue` = run them in a loop

In `circuits`:
- `Circuit (Kleisli m) Either` is a general arrow with feedback
- `Hyper` is the final encoding
- `Producer a r`, `Consumer a r` from `Circuit.Channel` are `Hyper`-based

The current `circuits-io` uses `Circuit.Channel` (Producer/Consumer/Hyper), not `Circuit` directly. So maybe the migration path is:
1. `Box` → `Circuit.Channel` types (Producer/Consumer)
2. `glue` → `invoke` / `run` on `Hyper`
3. `Emitter` → `Producer (Maybe a) r`
4. `Committer` → `Consumer (Maybe a) r`

Wait, let me re-read `Circuit.Channel`:
```haskell
data Producer a r = Hyper (a -> r) r   -- emits a, returns r when done
data Consumer a r = Hyper r (a -> r)   -- consumes a, returns r when done
```

Actually `Producer a r` is `Hyper (a -> r) r`, which means it takes a continuation `a -> r` and produces `r`. This is like a producer that feeds values to a callback.

And `Consumer a r` is `Hyper r (a -> r)`, which takes an initial `r` and returns `a -> r` — a function that consumes `a` and returns `r`.

So `glue` in this world would be... `invoke`?
```haskell
prod a p = Hyper $ \c -> (c `invoke` p) a
cons f c = Hyper $ \p a -> f (p `invoke` c) a
layer x = Hyper $ \anchor a -> (anchor `invoke` x) a
```

Hmm, these are a bit cryptic. The `Producer` emits `a` by invoking the callback `c` with `a` and then using the result. The `Consumer` takes a `a` and passes it to the producer callback.

OK, I think I need to be pragmatic. Let me write the audit document with what we know, and flag the `Circuit` mapping as something that needs deeper design work. The user asked to "step through and say ok, that's something we need, or that's not a thing, or how do we do that". I'll do exactly that.

For now, let me note that the `circuits-io` project *already* has `Circuit.Channel` with `Producer`/`Consumer`/`Hyper`. The box-socket code was merged in but still uses `Box` types. The migration could go two ways:

A. Keep `Emitter`/`Committer` as local newtypes, rewrite socket code to use them (minimal change)
B. Migrate everything to `Circuit (Kleisli IO) Either` or `Circuit.Channel` (deeper change)

The user seems to want to understand the full picture before deciding. Let me provide that.

---

## Box.Codensity

| Symbol | Verdict | Notes |
|--------|---------|-------|
| `close` | ❌ DROP | `runCodensity x id`. In circuits-io we don't use Codensity for resource management; use `bracket` directly. |
| `process` | ❌ DROP | `runCodensity k f`. Same reasoning. |
| `<$|>` | ❌ DROP | `fmap then close`. Was a convenience for `Box` examples. Not needed without Codensity. |
| `<*|>` | ❌ DROP | `apply then close`. Same reasoning. |
| `Codensity` (re-export) | ❌ DROP | The entire `Codensity` pattern is a bracket-encoding trick. In IO we have `bracket`, `withFile`, `withConnect`, etc. |

**Rationale:** `Codensity` in `box` was used to delay IO actions so they could be composed before running. In practice this meant writing `glue <$> pure showStdout <*|> qList [1..3]` instead of `withQueue $ \e -> glue showStdout e`. The latter is clearer and doesn't require understanding Kan extensions. For socket code, `withConnect cfg $ \sock -> ...` is standard Haskell.

---

## Box.Connectors

| Symbol | Verdict | Notes |
|--------|---------|-------|
| `qList` | 🔄 REWRITE | Queue-backed emitter from a list. In circuits-io this is `feedQueue Unbounded xs` + `drainQueue`. |
| `qListWith` | 🔄 REWRITE | Same with explicit queue strategy. `feedQueue q xs` + `drainQueue q`. |
| `popList` | 🔄 REWRITE | Feed a list directly to a committer via state. `forM_ xs (commit c)` with `bracket`. |
| `pushList` | 🔄 REWRITE | Collect emitter into a list. `toListM` equivalent. |
| `pushListN` | 🔄 REWRITE | Collect N elements. `takeM` equivalent. |
| `sink` | 🔄 REWRITE | Create a finite committer queue. This is `commitQ` from Box.Queue, or `queueEnds` + `feedQueue` in circuits-io. |
| `sinkWith` | 🔄 REWRITE | Same with explicit queue. |
| `source` | 🔄 REWRITE | Create a finite emitter queue. `queueEnds` + `drainQueue`. |
| `sourceWith` | 🔄 REWRITE | Same with explicit queue. |
| `forkEmit` | 🔄 REWRITE | Tee an emitter to a committer, passing values through. This is `liftA2 (\a _ -> a) e (commit c <$> e)` in applicative terms, or a queue + concurrent read in IO. |
| `bufferCommitter` | 🔄 REWRITE | Wrap a committer in a queue. `queueL Unbounded (glue c)` in old terms. In circuits-io: `queueEnds` + `race`. |
| `bufferEmitter` | 🔄 REWRITE | Wrap an emitter in a queue. `queueR Unbounded (glue e)` in old terms. |
| `concurrentE` | 🔄 REWRITE | Race two emitters into a queue. In circuits-io: `queueEnds q` + `race (glue e1) (glue e2)` + drain. |
| `concurrentC` | 🔄 REWRITE | Race two committers from a queue. Same pattern. |
| `takeQ` | 🔄 REWRITE | Take N from emitter into a queue. `takeE n` + queue. |
| `evalEmitter` | 🔄 REWRITE | Run stateful emitter via queue. `evalStateT` + queue. |
| `evalEmitterWith` | 🔄 REWRITE | Same with explicit queue. |

**`qList` rewrite detail:**

```haskell
-- OLD
qList :: [a] -> CoEmitter IO a
qList xs = qListWith Unbounded xs

-- NEW — no Codensity, direct IO with bracket
qList :: [a] -> (Emitter IO a -> IO r) -> IO r
qList xs action = bracket
  (atomically $ queueEnds Unbounded)
  (\_ -> pure ())  -- no seal needed with TQueue
  (\(write, read) -> do
    -- feed the list in a background thread
    withAsync (forM_ xs (atomically . write)) $ \_ ->
      -- expose an emitter that reads from the queue
      action (Emitter $ atomically read >>= pure . Just))
```

Actually, in circuits-io we already have `feedQueue` and `drainQueue`:
```haskell
feedQueue :: Queue a -> [a] -> IO (a -> IO ())
drainQueue :: Queue a -> IO (IO (Maybe a))
```

So `qList` becomes:
```haskell
qList :: [a] -> (Emitter IO a -> IO r) -> IO r
qList xs action = do
  feed <- feedQueue Unbounded xs
  drain <- drainQueue Unbounded
  withAsync (forM_ xs feed) $ \_ -> action (Emitter drain)
```

Wait, `feedQueue` returns `a -> IO ()` and `drainQueue` returns `IO (Maybe a)`. But `feedQueue` already writes the list? Let me check the actual API in circuits-io...

From the context earlier:
```haskell
feedQueue :: Queue a -> [a] -> IO ()
drainQueue :: Queue a -> IO (IO (Maybe a))
```

Or maybe:
```haskell
feedQueue :: Queue a -> IO (a -> IO ())
drainQueue :: Queue a -> IO (IO a)
```

I need to check the actual code. But regardless, the pattern is clear: `qList` goes from `Codensity` to direct `bracket/withAsync`.

**`forkEmit` rewrite detail:**

```haskell
-- OLD
forkEmit :: Emitter IO a -> Committer IO a -> Emitter IO a
forkEmit e c = Emitter $ do
  a <- emit e
  maybe (pure ()) (void <$> commit c) a
  pure a

-- NEW — tee pattern with queue
forkEmit :: Emitter IO a -> Committer IO a -> Emitter IO a
forkEmit e c = Emitter $ do
  a <- emit e
  case a of
    Nothing -> pure Nothing
    Just a' -> do
      _ <- commit c a'
      pure (Just a')
```

Actually the old code is almost the same as the new code. `forkEmit` is a pure combinator — it doesn't need `Codensity`. It could just be a function on `Emitter`/`Committer`.

---

## Box.Queue

| Symbol | Verdict | Notes |
|--------|---------|-------|
| `Queue` (data) | ✅ KEEP | Already ported to `Circuit.IO.Queue`. Same 6 constructors. |
| `queueL` | 🔄 REWRITE | Create queue, run committer action, return left result. In circuits-io: `queueEnds` + `race`/`concurrently` + `withAsync`. |
| `queueR` | 🔄 REWRITE | Same but return right result. |
| `queue` | 🔄 REWRITE | Return both results. `concurrently` in circuits-io. |
| `fromAction` | ❌ DROP | Turn a box action into a box continuation. Not needed without `Codensity`/`CoBox`. |
| `fromActionWith` | ❌ DROP | Same with explicit queues. |
| `emitQ` | 🔄 REWRITE | Hook committer action to queue, creating emitter continuation. In circuits-io this is `bracket` + `queueEnds` + `concurrently`. |
| `commitQ` | 🔄 REWRITE | Same but for committer. |
| `toBoxM` | 🔄 REWRITE | Turn queue into `Box IO a a` + seal. In circuits-io we could expose `toBoxSTM` + `atomically` lift, but `Box` itself is being removed. |
| `toBoxSTM` | 🔄 REWRITE | Same but in STM. Useful for testing. Could be `queueEndsSTM` in circuits-io. |
| `concurrentlyLeft` | ✅ KEEP | Already available via `async` package's `concurrently` + `fst`. Could be a thin wrapper. |
| `concurrentlyRight` | ✅ KEEP | Same. Thin wrapper around `concurrently` + `snd`. |

**`queue` family rewrite detail:**

```haskell
-- OLD
queue :: Queue a -> (Committer IO a -> IO l) -> (Emitter IO a -> IO r) -> IO (l, r)
queue q cm em = withQ q toBoxM cm em

-- NEW — using circuits-io primitives
queue :: Queue a -> (Committer IO a -> IO l) -> (Emitter IO a -> IO r) -> IO (l, r)
queue q cm em = do
  (write, read) <- atomically $ queueEnds q
  concurrently
    (cm (Committer $ \a -> atomically (write a) >> pure True))
    (em (Emitter $ atomically (Just <$> read)))
```

Wait, `queueEnds` returns `STM (a -> STM (), STM a)` in circuits-io. So:
```haskell
queue :: Queue a -> ((a -> IO ()) -> IO l) -> (IO (Maybe a) -> IO r) -> IO (l, r)
queue q cm em = do
  (write, read) <- atomically $ queueEnds q
  concurrently
    (cm (atomically . write))
    (em (atomically (Just <$> read)))
```

But `cm` and `em` would need to accept raw functions, not `Committer`/`Emitter`. If we keep `Committer`/`Emitter` as newtypes:
```haskell
queue :: Queue a -> (Committer IO a -> IO l) -> (Emitter IO a -> IO r) -> IO (l, r)
queue q cm em = do
  (write, read) <- atomically $ queueEnds q
  concurrently
    (cm (Committer $ \a -> atomically (write a) >> pure True))
    (em (Emitter $ atomically (Just <$> read)))
```

This is actually simpler than the old `Box.Queue` code which had `sealed` TVars, `writeCheck`, `readCheck`, and `bracket` with sealing. The `TQueue`/`TBQueue` family in STM doesn't need explicit sealing — the queue itself lives as long as the references to it. When all threads finish, the queue is garbage collected.

But wait — the old `Box.Queue` had explicit sealing because `Box` wanted to support "close the emitter" as a signal. In `TQueue`, `readTQueue` blocks until something is available. If the writer thread dies, the reader blocks forever. The old sealing mechanism used a `TVar Bool` so the reader could detect "no more writers" and return `Nothing`.

This is actually important! `Emitter` returns `Maybe a` where `Nothing` means "closed, no more values". If we use raw `TQueue`, the reader can't distinguish "queue empty but writer still alive" from "writer dead". We need either:
1. Keep the sealing mechanism
2. Use `TMVar` for closure signaling
3. Accept that closure is signaled by the async finishing

In the `async` pattern, if the writer finishes, `concurrently` returns and the reader is killed. But if we want the reader to keep running and process all queued values, we need the writer to signal completion.

The old `Box.Queue` pattern with `sealed` was:
```haskell
writeCheck sealed i a = do
  b <- readTVar sealed
  if b then pure False else i a >> pure True

readCheck sealed o = (Just <$> o) <|> (readTVar sealed >>= check >> pure Nothing)
```

This is elegant. Should we keep it? In circuits-io, we could have:
```haskell
queueEnds :: Queue a -> STM (a -> STM (), STM (Maybe a))
queueEnds qu = do
  (write, read) <- ends qu
  sealed <- newTVar False
  let write' a = do
        b <- readTVar sealed
        if b then pure False else write a >> pure True
      read' = (Just <$> read) <|> (readTVar sealed >>= check >> pure Nothing)
  pure (write', read', writeTVar sealed True)
```

But this changes `queueEnds` to return a seal. Currently it doesn't. Let me check the current `Circuit.IO.Queue`...

From the context earlier:
```haskell
queueEnds :: Queue a -> STM (a -> STM (), STM a)
```

It returns raw STM actions without sealing. This is fine for `Bounded`/`Unbounded` queues where you manage lifetime via `bracket`/`withAsync`, but for `Single`/`Latest` etc. you might want sealing.

I should flag this as a design decision in the audit.

---

## Box.IO

| Symbol | Verdict | Notes |
|--------|---------|-------|
| `fromStdin` | 🔄 REWRITE | `Emitter IO Text` from stdin. In circuits-io: `Emitter (Text.getLine >>= pure . Just)`. |
| `toStdout` | 🔄 REWRITE | `Committer IO Text` to stdout. `Committer (\t -> Text.putStrLn t >> pure True)`. |
| `stdBox` | 🔄 REWRITE | `Box IO Text Text` with escape phrase. In circuits-io this could be a `Box` alias or just a pair of `Emitter`/`Committer`. |
| `fromStdinN` | 🔄 REWRITE | Finite stdin emitter. `takeE n fromStdin`. |
| `toStdoutN` | 🔄 REWRITE | Finite stdout committer. `sink n Text.putStrLn`. |
| `readStdin` | 🔄 REWRITE | Parse stdin. `witherE` + `readE`. |
| `showStdout` | 🔄 REWRITE | Show to stdout. `contramap (pack . show) toStdout`. |
| `handleE` | 🔄 REWRITE | Emit from handle. `Emitter` wrapper over `try` + `hGetLine`. |
| `handleC` | 🔄 REWRITE | Commit to handle. `Committer` wrapper over `hPutStrLn`. |
| `fileE` | 🔄 REWRITE | File emitter with `Codensity` bracket. In circuits-io: direct `withFile` + `handleE`. |
| `fileC` | 🔄 REWRITE | File committer with `Codensity` bracket. Direct `withFile` + `handleC`. |
| `fileEText` | 🔄 REWRITE | Convenience over `fileE`. Keep as thin wrapper. |
| `fileEBS` | 🔄 REWRITE | Convenience over `fileE`. Keep. |
| `fileCText` | 🔄 REWRITE | Convenience over `fileC`. Keep. |
| `fileCBS` | 🔄 REWRITE | Convenience over `fileC`. Keep. |
| `toLineBox` | ❌ DROP | ByteString box → Text line box. This is a very specific conversion that was needed for the `web-rep` protocol. Unless we port `web-rep`, this is not needed. |
| `fromLineBox` | ❌ DROP | Reverse of above. Same reasoning. |
| `refCommitter` | 🔄 REWRITE | `IORef`-based committer for testing. Useful helper. |
| `refEmitter` | 🔄 REWRITE | `IORef`-based emitter for testing. Useful helper. |
| `logConsoleE` | 🔄 REWRITE | Debug logging on emitter. `Emitter` wrapper with `putStrLn`. |
| `logConsoleC` | 🔄 REWRITE | Debug logging on committer. `Committer` wrapper with `putStrLn`. |
| `pauser` | 🔄 REWRITE | Pause emitter based on Bool emitter. `Emitter` combinator. |
| `changer` | 🔄 REWRITE | Detect changes. Stateful emitter with `evalEmitter`. |
| `quit` | 🔄 REWRITE | Race emitter against IO. `race (checkE flag) io`. |
| `restart` | 🔄 REWRITE | Restart IO on flag. `fix` + `quit`. |

**Rationale:** `Box.IO` is mostly convenience wrappers around stdin/stdout/files. All of these are thin and can be ported directly. The `toLineBox`/`fromLineBox` pair is the exception — it's specific to `web-rep` binary protocol framing.

---

## Box.Time

| Symbol | Verdict | Notes |
|--------|---------|-------|
| `sleep` | ✅ KEEP | `threadDelay` wrapper. Already in `Circuit.IO.Time`? If not, trivial to add. |
| `stampNow` | 🔄 REWRITE | Add timestamp. `getCurrentTime` + `utcToLocalTime`. |
| `stampE` | 🔄 REWRITE | Timestamp emitter. `witherE` wrapper. |
| `Gap` | 🔄 REWRITE | Type alias for seconds. Keep. |
| `gaps` | 🔄 REWRITE | Compute time gaps between emits. Stateful emitter. |
| `fromGaps` | 🔄 REWRITE | Convert gaps to timestamps. Stateful emitter. |
| `fromGapsNow` | 🔄 REWRITE | Same but start from now. |
| `gapEffect` | 🔄 REWRITE | Add delays based on gaps. `Emitter` combinator with `sleep`. |
| `speedEffect` | 🔄 REWRITE | Speed up/slow down gaps. `Emitter` combinator. |
| `gapSkipEffect` | 🔄 REWRITE | Skip first N gaps. `evalEmitter` + state. |
| `speedSkipEffect` | 🔄 REWRITE | Skip + speed combined. `evalEmitter` + state. |
| `skip` | 🔄 REWRITE | Skip first N gaps (set to 0). `evalEmitter` + state. |
| `replay` | 🔄 REWRITE | Replay with speed adjustment. Composition of `gaps` + `skip` + `gapEffect`. |

**Rationale:** All timing effects are useful and port cleanly. They are all `Emitter` combinators or stateful wrappers. No `Codensity` dependency.

---

## Cross-cutting concerns

### 1. Sealing / graceful shutdown

The old `Box.Queue` used a `TVar Bool` "seal" so that `readCheck` could return `Nothing` when the queue was closed. The new `Circuit.IO.Queue` uses raw `TQueue`/`TBQueue` without sealing.

**Decision needed:** Do we add sealing back? Or do we rely on `withAsync` + `race` for lifetime management?

- **Without sealing:** The reader blocks on empty queue. When the writer async is cancelled, the reader async is also cancelled (via `concurrently`/`race`). This is fine for most use cases.
- **With sealing:** The reader can drain remaining values and then see `Nothing`. This is needed for `toListM` and similar "collect everything" patterns.

**Recommendation:** Add optional sealing to `queueEnds` or provide a separate `queueEndsSealed` that returns `(a -> STM Bool, STM (Maybe a), STM ())`.

### 2. `Alternative` / `MonadPlus` for `Emitter`

The old `Emitter` had `Alternative` and `MonadPlus` instances for left-biased choice (`<|>`). This is used in `concurrentE` and in some examples.

In `Circuit` terms, `<|>` on `Emitter` means "try left, if it returns `Nothing`, try right". This is not a primitive of `Circuit`. We have two options:

- **Option A:** Keep `Emitter` as a newtype and provide `Alternative` instance. This requires `Alternative IO` which is `IOPlus` from `extra` or `MaybeT` semantics.
- **Option B:** Drop `<|>` on `Emitter`. Use explicit `race` + queue for concurrency, and explicit `if`-`then`-`else` for choice.

**Recommendation:** Drop the `Alternative` instance. It's a footgun (`<|>` on IO is `catch` in some definitions, `race` in others). Explicit is better. The `concurrentE` combinator can be rewritten as `race (glue e1 q) (glue e2 q)` with a queue.

### 3. `Monoid` / `Semigroup` for `Committer` and `Box`

Old semantics:
- `Committer <> Committer` = try both, return True if either succeeds (||)
- `Box <> Box` = combine committers and emitters separately

In `Circuit` terms, there's no natural `Monoid` on `Circuit (Kleisli IO) Either a b` because composition is `Category` (`.`), not `Monoid` (`<>`).

**Recommendation:** Drop `Semigroup`/`Monoid` instances. They were used for "broadcast to multiple committers" or "try multiple sources". These are better expressed with explicit queue fan-out or `race`.

### 4. `Divisible` / `Decidable` for `Committer`

These are contravariant combinators (divide, conquer, choose, lose). They were used for splitting/joining values at the committer.

**Recommendation:** Drop. `Committer` is a consumer — splitting the input is the caller's job. If needed, users can `contramap` + tuple handling.

### 5. `Divap` / `DecAlt` for `Box`

These combined `Divisible`+`Applicative` and `Decidable`+`Alternative` for `Box`. They were exotic combinators for parallel wiring.

**Recommendation:** Drop. They were barely used and can be reconstructed from `dimap` + `race` + queues if ever needed.

---

## Summary table by module

| Module | KEEP | REWRITE | DROP | UNCLEAR |
|--------|------|---------|------|---------|
| Box.Functor | 0 | 0 | 4 | 0 |
| Box.Committer | 0 | 4 | 2 | 0 |
| Box.Emitter | 0 | 11 | 2 | 0 |
| Box.Box | 0 | 7 | 9 | 0 |
| Box.Codensity | 0 | 0 | 5 | 0 |
| Box.Connectors | 0 | 16 | 0 | 0 |
| Box.Queue | 2 | 8 | 2 | 0 |
| Box.IO | 0 | 22 | 2 | 0 |
| Box.Time | 1 | 11 | 0 | 0 |
| **Total** | **3** | **79** | **26** | **0** |

Out of ~108 exported symbols:
- **3** trivial KEEP (`concurrentlyLeft`, `concurrentlyRight`, `sleep`)
- **79** need rewriting (mostly thin wrappers, but shape changes)
- **26** can be DROPped (mostly type-class plumbing and Codensity)

The heavy lifting is in `Box.Queue` (queue lifetime / sealing semantics) and `Box.Box` (replacing `glue` with `reify`+`runKleisli`). The rest is mechanical.
