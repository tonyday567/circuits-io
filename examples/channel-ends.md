# channel-ends — companion, conjoint, and the buffer

**card** ⟜ using `Circuit.Ends` to create first-class channel ends and compose them into buffers.

---

## pure: open and close

```haskell
import Circuit.Ends
import Circuit (reify)

(p, c) = open (42 :: Int)

-- close plugs the ends together into a Wire Int Int
buf = close p c

-- reify buf 99 = 42 regardless of input
```

The channel's "state" is the seed. The producer always returns the seed; the consumer calls the producer back — mutual recursion that bottoms out because the producer returns first.

---

## stm: makeQueue and closeQueue

```haskell
import Circuit.Queue
import Circuit (Circuit(..), reify)
import Control.Arrow (Kleisli(..), runKleisli)
import Control.Category ((>>>))
import Prelude hiding (id, (.))

main = do
  (push', pop') <- makeQueue Unbounded  -- IO (push a (), pop () a)
  let buf = closeQueue push' pop'       -- Circuit (Kleisli IO) (,) a a
  let pipe = Lift (Kleisli (\() -> pure (7 :: Int))) >>> buf
  print =<< runKleisli (reify pipe) ()  -- 7
```

`closeQueue` is the extrinsic analogue of `close` — it composes the two STM-backed ends into a single circuit.

---

## two queues chained

```haskell
(pA, cA) = open (1 :: Int)
(pB, cB) = open (2 :: Int)
bufA = close pA cA
bufB = close pB cB
pipe = Lift (const ()) >>> bufA >>> bufB
-- reify pipe () = 1 (bufA returns seed, bufB returns its seed)
```

The ends are values — create them in one scope, pair them differently, compose serially.

---

## relationship

- `open` / `close` — pure intrinsic case (Wire), equipment unit/counit
- `makeQueue` / `closeQueue` — STM extrinsic case, same pattern on runtime channels
- `Companion` = `Producer` = `Nucleus p`, `Conjoint` = `Consumer` = `Nucleus (Flip p)`
- `close prod cons = prod cons` — the yanking identity
