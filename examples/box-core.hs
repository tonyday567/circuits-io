{-# LANGUAGE FlexibleInstances #-}

-- | Box: profunctor streaming with Circuit (Kleisli m) Either.
--
--   Types:
--     Box m c e      = Circuit (Kleisli m) Either c e
--     Emitter m a    = Box m () a      — produces one a per step
--     Committer m a  = Box m a ()      — consumes one a per step
--
--   The lowered form is a single step: c -> m e.
--   Multi-step (streaming) is circuit composition, not function call.
--
--   Unit creates a matched pair. Counit annihilates: lower . Compose.

module Box where

import Circuit.Circuit (Circuit(..), reify)
import Control.Arrow (Kleisli(..), runKleisli)
import Control.Category ((.))
import Data.Profunctor (Profunctor(dimap))
import Prelude hiding (id, (.))

-- Core types
type Box m c e      = Circuit (Kleisli m) Either c e
type Emitter m a    = Box m () a
type Committer m a  = Box m a ()

-- Lower: interpret to a monadic function (single step)
runB :: Monad m => Box m c e -> c -> m e
runB = runKleisli . reify

runE :: Monad m => Emitter m a -> m a
runE e = runB e ()

runC :: Monad m => Committer m a -> a -> m ()
runC c a = runB c a

-- Unit: create a bidirectional channel from a value.
--   The Emitter produces a, the Committer consumes a.
unit :: Monad m => a -> (Emitter m a, Committer m a)
unit a = (Lift (Kleisli (const (pure a))), Lift (Kleisli (const (pure ()))))

-- Counit: compose and run — the annihilator.
counit :: Monad m => Committer m a -> Emitter m a -> m ()
counit c e = runB (Compose c e) ()

-- Glue: convenience alias for counit
glue :: Monad m => Committer m a -> Emitter m a -> m ()
glue = counit

-- ---------------------------------------------------------------------------
-- Emitter combinators
-- ---------------------------------------------------------------------------

-- | Emit a single value and stop.
yield :: Monad m => a -> Emitter m a
yield = Lift . Kleisli . const . pure

-- ---------------------------------------------------------------------------
-- Committer combinators
-- ---------------------------------------------------------------------------

-- | Consume a value with an effect.
consume :: Monad m => (a -> m ()) -> Committer m a
consume f = Lift (Kleisli (\a -> f a >> pure ()))

-- | Always accept.
accept :: Monad m => Committer m a
accept = Lift (Kleisli (const (pure ())))
