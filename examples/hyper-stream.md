# hyper-stream ⟜ streaming a list through Hyper

A producer that walks a list one element at a time, plus consumers
that collect or take the first N elements. Pure Hyper — no Circuit GADT,
no Trace class. Just `invoke`.

Paste each block into `cabal repl`.

## qList — emit list elements one at a time

Each invoke returns `Nothing` (done) or `Just (remaining, current)`.

```haskell
{-# LANGUAGE LambdaCase #-}
import Circuit.Hyper (Hyper(..), invoke)

qList :: [Int] -> Hyper () (Maybe ([Int], Int))
qList xs = Hyper $ \_ -> case xs of
  []      -> Nothing
  (x:xs') -> Just (xs', x)
```

## collect — drain a producer into a list

```haskell
collect :: Hyper () (Maybe ([Int], Int)) -> [Int]
collect h = case invoke h undefined of
  Nothing      -> []
  Just (xs', x) -> x : collect (qList xs')

-- >>> collect (qList [1,2,3])
-- [1,2,3]
-- >>> collect (qList [])
-- []
```

## takeE — take the first N elements

```haskell
takeE :: Int -> Hyper () (Maybe ([Int], Int)) -> [Int]
takeE 0 _ = []
takeE n p = case invoke p undefined of
  Nothing      -> []
  Just (xs', x) -> x : takeE (n-1) (qList xs')

-- >>> takeE 2 (qList [1,2,3,4,5])
-- [1,2]
-- >>> takeE 0 (qList [1,2,3])
-- []
```

## what's happening

Each call to `invoke p undefined` peels off one element and returns the
*rest-of-list producer* (`qList xs'`). This is the Hyper pattern: a
producer that, when invoked, returns a value and its own continuation.

Compare with `examples/pair-loops.md` (same idea, Circuit GADT with
Knot) and `examples/two-loops.md` (separate Knots, fused version).

## reference

- `Circuit.Hyper` — the module
- `examples/pair-loops.md` — fused qList+takeE via Circuit Knot
- `examples/two-loops.md` — separate Knots + fused comparison
