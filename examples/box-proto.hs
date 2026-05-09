{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Box prototype: Emitter/Committer as Circuit (Kleisli Identity) Either.
--   Uses instances from circuits proper (Profunctor, Trace).

module BoxProto where

import Circuit.Circuit (Circuit(..), reify)
import Control.Arrow (Kleisli(..))
import Control.Category ((.), id)
import Data.Functor.Identity (Identity(..), runIdentity)
import Data.Profunctor (Profunctor(..))
import Data.Profunctor.Unsafe () -- Profunctor (Kleisli m)
import Prelude hiding (id, (.))

-- Types
type Emitter a  = Circuit (Kleisli Identity) Either () a
type Committer a = Circuit (Kleisli Identity) Either a ()

-- Lower helpers
lowerE :: Emitter a -> () -> a
lowerE e = runIdentity . runKleisli (reify e)

lowerC :: Committer a -> a -> ()
lowerC c = runIdentity . runKleisli (reify c)

-- Unit: create a matched pair
unit :: a -> (Emitter a, Committer a)
unit a = (Lift (Kleisli (const (Identity a))), Lift (Kleisli (const (Identity ()))))

-- Counit: compose and lower
counit :: Committer a -> Emitter a -> () -> ()
counit c e = runIdentity . runKleisli (reify (Compose c e))

demo :: IO ()
demo = do
  let (emit, commit) = unit (42 :: Int)
  putStrLn $ "emit ():      " <> show (lowerE emit ())
  putStrLn $ "commit 42:    " <> show (lowerC commit 42)
  putStrLn $ "counit ():    " <> show (counit commit emit ())
