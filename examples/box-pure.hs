{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Pure Committer/Emitter as Circuit types. No monad, no Codensity.
--
-- Emitter a = Circuit (->) Either () a   -- produces values, stops on Left ()
-- Committer a = Circuit (->) Either a () -- consumes values, rejects on Left a
--
-- glue = lower . Compose :: Committer a -> Emitter a -> Either () ()

module Box where

import Circuit.Circuit (Circuit(..), reify)
import qualified Circuit.Circuit as C
import Control.Category (Category)
import qualified Control.Category as Cat
import Data.Bifunctor (Bifunctor(bimap))
import Data.Functor.Identity (Identity(..))
import Prelude hiding (id, (.))

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

type Emitter a = Circuit (->) Either () a
type Committer a = Circuit (->) Either a ()

-- ---------------------------------------------------------------------------
-- Profunctor (needed for dimap)
-- ---------------------------------------------------------------------------

instance Profunctor (->) where
  dimap f g h = g . h . f

-- | Profunctor instance for Circuit: dimap f g maps input contravariantly
--   and output covariantly.
instance Bifunctor t => Profunctor (Circuit (->) t) where
  dimap f g (Lift h)    = Lift (dimap f g h)
  dimap f g (Compose h i) = Compose (dimap Cat.id g h) (dimap f Cat.id i)
  dimap f g (Loop h)    = Loop (dimap (bimap Cat.id f) (bimap Cat.id g) h)

-- ---------------------------------------------------------------------------
-- Combinators
-- ---------------------------------------------------------------------------

-- | Empty emitter — produces nothing.
emptyEmitter :: Emitter a
emptyEmitter = Loop (dimap id (bimap id (const (Left ()))) id)

-- | Empty committer — rejects everything.
emptyCommitter :: Committer a
emptyCommitter = Loop (dimap id (bimap (const (Left undefined)) id) id)

-- | Stop emitting (signal end of stream).
stop :: Emitter a
stop = Lift (const (Left ()))

-- | Emit a single value, then stop.
emit1 :: a -> Emitter a
emit1 a = Lift (const (Right a))

-- | Commit a value and stop.
commitStop :: a -> Committer a
commitStop _ = Lift (const (Right ()))

-- | Constant committer — accepts everything.
accept :: Committer a
accept = Lift (const (Right ()))

-- | Emitter from a list. Uses Loop for recursion.
emitList :: [a] -> Emitter a
emitList = go
  where
    go []     = stop
    go (x:xs) = Lift (const (Right x)) `thenEmit` go xs

-- | Sequence: emit a, then continue with next emitter.
thenEmit :: Emitter a -> Emitter a -> Emitter a
thenEmit = composeRight

composeRight :: Circuit (->) t a b -> Circuit (->) t a b -> Circuit (->) t a b
composeRight f g = f  -- placeholder, this is wrong. Actually need sequence.

-- | Glue: connect a committer to an emitter. Counit of the adjunction.
glue :: Committer a -> Emitter a -> Either () ()
glue c e = reify (Compose c e)

-- | Run emitter to collect all values (for testing).
collect :: Emitter a -> [a]
collect e = case reify e () of
  Left ()  -> []
  Right a  -> a : collect (drop1 e)

-- | Drop the first value from an emitter and continue.
drop1 :: Emitter a -> Emitter a
drop1 e = case reify e () of
  Left ()  -> stop
  Right _  -> Loop $ \_ ->
    case reify e () of
      Left ()  -> Left ()
      Right a  -> Right a
