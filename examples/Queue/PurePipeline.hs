{-# LANGUAGE LambdaCase #-}

-- | Pure queue test — mirror of the STM makeQueue pipeline.
--
-- Two Unbounded queues (A and B), combined state threaded through.
-- Pipeline: produce 7 → pushA → popA → pushB → popB → 7.
module Main where

import Circuit (Circuit (..), reify)
import Circuit.Queue
import Control.Category ((>>>))

-- Two queues share combined state: (bufA, bufB)
type Q2 = ([Int], [Int])

main :: IO ()
main = print $ reify pipeline (([], []), ())
  where
    (writeA, readA) = endsPure Unbounded
    (writeB, readB) = endsPure Unbounded

    pipeline = source >>> pushA >>> popA >>> pushB >>> popB
      :: Circuit (->) (,) (Q2, ()) (Q2, Int)

    source = Lift $ \(qs, ()) -> (qs, 7)
    pushA  = Lift $ \((bufA, bufB), x) -> let (bufA', _) = writeA x bufA in ((bufA', bufB), ())
    popA   = Lift $ \((bufA, bufB), ()) -> let (bufA', Just x) = readA bufA in ((bufA', bufB), x)
    pushB  = Lift $ \((bufA, bufB), x) -> let (bufB', _) = writeB x bufB in ((bufA, bufB'), ())
    popB   = Lift $ \((bufA, bufB), ()) -> let (bufB', Just x) = readB bufB in ((bufA, bufB'), x)
