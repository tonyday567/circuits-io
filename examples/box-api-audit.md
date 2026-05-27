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
| `Committer` (newtype) | 🔄 REWRITE | Becomes `type Committer m a = Circuit (Kleisli m) Either a ()`. Or keep a newtype wrapper for Haddock discoverability. |
| `commit` | 🔄 REWRITE | `runKleisli . reify` on a `Circuit (Kleisli m) Either a ()`. The `Bool` success signal becomes `Right ()` / `Left a` in the Either loop. |
| `CoCommitter` | ❌ DROP | `Codensity m (Committer m a)` was for resource bracketing. Use direct `bracket` or `with...` at the call site. |
| `witherC` | 🔄 REWRITE | Filtering/preprocessing on the input side. In `Circuit` terms this is just `lmap` (precomposition) with a Kleisli arrow that returns `Maybe`. |
| `listC` | 🔄 REWRITE | Turn a single-item committer into a list committer. `traverse` + `or`. Easy helper. |
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
| `filterE` | 🔄 REWRITE | Like `witherE` but skips `Nothing` and keeps pulling. Kleisli arrow loop inside the circuit. |
| `readE` | 🔄 REWRITE | Parse `Text` to `Read` values. Just `fmap` + `reads`. |
| `unlistE` | 🔄 REWRITE | Flatten `Emitter m [a]` to `Emitter (StateT [a] m) a`. In `Circuit` terms: `unfold` state carried through `ambient`. |
| `takeE` | 🔄 REWRITE | Counted take. Easy with a `StateT Int` Kleisli wrapper, or with `Circuit` knot + counter. |
| `dropE` | 🔄 REWRITE | Skip first N. In circuits-io: `replicateM_ n emit >> pure circuit`. |
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
| `Box` (data) | 🔄 REWRITE | `Box m c e` is `Circuit (Kleisli m) Either c e` — the pair is already the profunctor. |
| `CoBox` | ❌ DROP | `Codensity m (Box m a b)`. Not needed — resource management is explicit. |
| `CoBoxM` | ❌ DROP | `newtype` wrapper for `Semigroupoid` on `CoBox`. Not needed. |
| `bmap` | 🔄 REWRITE | `dimap` + filtering. In `Circuit`: `dimap (Kleisli filterIn) (Kleisli filterOut)`. |
| `foistb` | ❌ DROP | Covered by `Circuit` parametricity. |
| `glue` | 🔄 REWRITE | `runKleisli . reify` on composed circuit. See rewrite detail. |
| `glue'` | 🔄 REWRITE | Same, returning closure reason. The `Either` loop already distinguishes continue/exit. |
| `glueN` | 🔄 REWRITE | Take N then stop. Compose with take combinator. |
| `glueES` | 🔄 REWRITE | Stateful emitter + plain committer. Use `StateT` inside `Kleisli`. |
| `glueS` | 🔄 REWRITE | Both sides stateful. Same pattern. |
| `fuse` | 🔄 REWRITE | `dimap` + `reify`. |
| `Divap` | ❌ DROP | Exotic wiring. Reconstruct from `dimap` + `race` + queues if ever needed. |
| `DecAlt` | ❌ DROP | Same reasoning. |
| `cobox` | ❌ DROP | Codensity constructor. Not needed without `Codensity`. |
| `seqBox` | 🔄 REWRITE | State-based `Box` over `Seq`. Example-level helper. |
| `dotco` | ❌ DROP | CPS composition of `CoBox`. Not needed. |

**`Box` rewrite detail:**

```haskell
-- OLD
data Box m c e = Box { committer :: Committer m c, emitter :: Emitter m e }

-- NEW — Box is just Circuit!
type Box m c e = Circuit (Kleisli m) Either c e

-- The constructor is not needed; profunctor combinators replace it.
-- dimap f g (box :: Box m c e) = Box (contramap f committer) (fmap g emitter)
```

**`glue` rewrite detail:**

```haskell
-- OLD
glue :: Monad m => Committer m a -> Emitter m a -> m ()
glue c e = fix $ \rec -> emit e >>= maybe (pure False) (commit c) >>= bool (pure ()) rec

-- NEW
glue :: Monad m => Committer m a -> Emitter m a -> m ()
glue c e = runKleisli (reify (Compose c e)) ()
```

In `Circuit (Kleisli m) Either`, sequential composition `.` (Compose) is the pipe. For a simple emitter → committer loop where the committer always accepts, `Compose c e` is the entire circuit. `reify` collapses it to `Kleisli () ()`, and `runKleisli` with `()` input runs the loop.

If the committer can reject (`Left a` feedback), a `Knot` is needed to recycle rejected values back to the emitter. In practice, `Either` loop circuits with rejection are built with `Knot` explicitly; simple always-accept pipelines use `Compose` directly.

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
| `qList` | 🔄 REWRITE | Queue-backed emitter from a list. `feedQueue` + `drainQueue` in circuits-io. |
| `qListWith` | 🔄 REWRITE | Same with explicit queue strategy. |
| `popList` | 🔄 REWRITE | Feed a list directly to a committer. `forM_ xs (commit c)` with `bracket`. |
| `pushList` | 🔄 REWRITE | Collect emitter into a list. `toListM` equivalent. |
| `pushListN` | 🔄 REWRITE | Collect N elements. `takeM` equivalent. |
| `sink` | 🔄 REWRITE | Create a finite committer queue. `queueEnds` + `feedQueue` in circuits-io. |
| `sinkWith` | 🔄 REWRITE | Same with explicit queue. |
| `source` | 🔄 REWRITE | Create a finite emitter queue. `queueEnds` + `drainQueue`. |
| `sourceWith` | 🔄 REWRITE | Same with explicit queue. |
| `forkEmit` | 🔄 REWRITE | Tee an emitter to a committer, passing values through. Pure combinator. |
| `bufferCommitter` | 🔄 REWRITE | Wrap a committer in a queue. `queueEnds` + `race`. |
| `bufferEmitter` | 🔄 REWRITE | Wrap an emitter in a queue. Same pattern. |
| `concurrentE` | 🔄 REWRITE | Race two emitters into a queue. `queueEnds` + `race (glue e1) (glue e2)` + drain. |
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
  (\_ -> pure ())
  (\(write, read) -> do
    withAsync (forM_ xs (atomically . write)) $\_ ->
      action (Emitter $ atomically read >>= pure . Just))
```

**`forkEmit` rewrite detail:**

```haskell
-- OLD
forkEmit :: Emitter IO a -> Committer IO a -> Emitter IO a
forkEmit e c = Emitter $ do
  a <- emit e
  maybe (pure ()) (void <$> commit c) a
  pure a

-- NEW — tee pattern
forkEmit :: Emitter IO a -> Committer IO a -> Emitter IO a
forkEmit e c = Emitter $ do
  a <- emit e
  case a of
    Nothing -> pure Nothing
    Just a' -> do
      _ <- commit c a'
      pure (Just a')
```

---

## Box.Queue

| Symbol | Verdict | Notes |
|--------|---------|-------|
| `Queue` (data) | ✅ KEEP | Already ported to `Circuit.Queue`. Same 6 constructors. |
| `queueL` | 🔄 REWRITE | Create queue, run committer action, return left result. `queueEnds` + `race`/`concurrently` + `withAsync`. |
| `queueR` | 🔄 REWRITE | Same but return right result. |
| `queue` | 🔄 REWRITE | Return both results. `concurrently` in circuits-io. |
| `fromAction` | ❌ DROP | Turn a box action into a box continuation. Not needed without `Codensity`/`CoBox`. |
| `fromActionWith` | ❌ DROP | Same with explicit queues. |
| `emitQ` | 🔄 REWRITE | Hook committer action to queue, creating emitter continuation. `bracket` + `queueEnds` + `concurrently`. |
| `commitQ` | 🔄 REWRITE | Same but for committer. |
| `toBoxM` | 🔄 REWRITE | Turn queue into `Box IO a a` + seal. Could expose `toBoxSTM` + `atomically` lift, but `Box` itself is being removed. |
| `toBoxSTM` | 🔄 REWRITE | Same but in STM. Useful for testing. |
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

**Sealing / graceful shutdown:** The old `Box.Queue` used a `TVar Bool` "seal" so that `readCheck` could return `Nothing` when the queue was closed. The new `Circuit.Queue` uses raw `TQueue`/`TBQueue` without sealing.

- **Without sealing:** The reader blocks on empty queue. When the writer async is cancelled, the reader async is also cancelled (via `concurrently`/`race`). This is fine for most use cases.
- **With sealing:** The reader can drain remaining values and then see `Nothing`. This is needed for `toListM` and similar "collect everything" patterns.

**Recommendation:** Add optional sealing to `queueEnds` or provide a separate `queueEndsSealed` that returns `(a -> STM Bool, STM (Maybe a), STM ())`.

---

## Box.IO

| Symbol | Verdict | Notes |
|--------|---------|-------|
| `fromStdin` | 🔄 REWRITE | `Emitter IO Text` from stdin. `Emitter (Text.getLine >>= pure . Just)`. |
| `toStdout` | 🔄 REWRITE | `Committer IO Text` to stdout. `Committer (\t -> Text.putStrLn t >> pure True)`. |
| `stdBox` | 🔄 REWRITE | `Box IO Text Text` with escape phrase. Could be a `Box` alias or just a pair of `Emitter`/`Committer`. |
| `fromStdinN` | 🔄 REWRITE | Finite stdin emitter. `takeE n fromStdin`. |
| `toStdoutN` | 🔄 REWRITE | Finite stdout committer. `sink n Text.putStrLn`. |
| `readStdin` | 🔄 REWRITE | Parse stdin. `witherE` + `readE`. |
| `showStdout` | 🔄 REWRITE | Show to stdout. `contramap (pack . show) toStdout`. |
| `handleE` | 🔄 REWRITE | Emit from handle. `Emitter` wrapper over `try` + `hGetLine`. |
| `handleC` | 🔄 REWRITE | Commit to handle. `Committer` wrapper over `hPutStrLn`. |
| `fileE` | 🔄 REWRITE | File emitter with `Codensity` bracket. Direct `withFile` + `handleE`. |
| `fileC` | 🔄 REWRITE | File committer with `Codensity` bracket. Direct `withFile` + `handleC`. |
| `fileEText` | 🔄 REWRITE | Convenience over `fileE`. Keep as thin wrapper. |
| `fileEBS` | 🔄 REWRITE | Convenience over `fileE`. Keep. |
| `fileCText` | 🔄 REWRITE | Convenience over `fileC`. Keep. |
| `fileCBS` | 🔄 REWRITE | Convenience over `fileC`. Keep. |
| `toLineBox` | ❌ DROP | ByteString box → Text line box. Specific to `web-rep` protocol. Not needed unless `web-rep` is ported. |
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
| `sleep` | ✅ KEEP | `threadDelay` wrapper. Already in `Circuit.Time`? If not, trivial to add. |
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

The old `Box.Queue` used a `TVar Bool` "seal" so that `readCheck` could return `Nothing` when the queue was closed. The new `Circuit.Queue` uses raw `TQueue`/`TBQueue` without sealing.

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
