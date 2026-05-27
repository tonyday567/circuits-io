{-# LANGUAGE RankNTypes #-}

-- | First-class channel ends — the companion and conjoint of the identity
-- functor in the proarrow equipment over 'Circuit'.
--
-- = Background
--
-- In a proarrow equipment (Bartosz Milewski, 2026), every vertical arrow
-- @f@ has a /companion/ @B(f,1)@ and a /conjoint/ @B(1,f)@, which are
-- horizontal arrows (profunctors) going in opposite directions.  For the
-- identity functor @id@, these specialise to:
--
-- @
--   Companion(id)(x, a) = p(x, a)      -- 'Producer'
--   Conjoint(id)(a, x)  = p(a, x)      -- 'Consumer'
-- @
--
-- where @p@ is the hom-profunctor ('Circuit' @arr@ @t@).
--
-- The companion and conjoint form an adjunction @Conjoint ⊣ Companion@.
-- The unit @η@ is 'open'; the counit @ε@ is 'close'.  The yanking identity
-- @close prod cons = prod cons@ is the defining characteristic.
--
-- = Intrinsic vs extrinsic
--
-- When the /channel/ is structural (pure 'Circuit's with 'Knot' feedback),
-- 'Producer' and 'Consumer' are genuinely different roles — the 'forall x'
-- forces mutual recursion.  This is the /intrinsic/ case.
--
-- When the channel is a runtime object (an 'IORef', 'TChan', socket), both
-- ends collapse to the same handle on the mutable cell.  That is the
-- /extrinsic/ case, served by 'Circuit.Queue.makeQueue'.
--
-- = Relationship to 'Knot'
--
-- By the spider lemma of proarrow equipment, any 'Knot' can be rewritten as:
--
-- @
--   Knot body  =  open >>> body' >>> close
-- @
--
-- and conversely.  'Producer'/'Consumer' is not a replacement for 'Knot' —
-- it is a refinement that lets the two channel ends travel independently
-- before being plugged together with 'close'.
module Circuit.Ends
  ( -- * Channel ends
    Producer (..),
    Consumer (..),

    -- * Unit and counit
    close,
    open,
  )
where

import Circuit (Circuit (..))
import Prelude hiding (id, (.))

-- | A 'Producer' is the companion of the identity functor.
--
-- Given a 'Consumer' (the other end of the channel), produce a circuit
-- from any type @x@ to @a@.  The @x@ is universally quantified — the
-- producer does not know what it is and must either return a constant
-- or call the consumer to proceed.
newtype Producer arr t a = Producer
  { -- | Run the producer, supplying the other end of the channel.
    runProducer :: forall x. Consumer arr t x -> Circuit arr t x a
  }

-- | A 'Consumer' is the conjoint of the identity functor.
--
-- Given a 'Producer' (the other end of the channel), produce a circuit
-- from @a@ to any type @x@.  The @x@ is universally quantified — the
-- consumer must call the producer to determine what to return.
newtype Consumer arr t a = Consumer
  { -- | Run the consumer, supplying the other end of the channel.
    runConsumer :: forall x. Producer arr t x -> Circuit arr t a x
  }

-- | @ε@ — the counit of the companion/conjoint adjunction.
--
-- Plug two channel ends together, producing a circuit from @a@ to @a@.
-- This is the yanking identity: eliminating the channel recovers the
-- underlying profunctor on the diagonal.
--
-- >>> import Circuit (reify)
-- >>> let (p, c) = open (42 :: Int)
-- >>> reify (close p c) 99
-- 42

{- HLINT ignore close "Eta reduce" -}
close :: Producer arr t a -> Consumer arr t a -> Circuit arr t a a
close p c = runProducer p c

-- | @η@ — the unit of the companion/conjoint adjunction (pure case).
--
-- Create two channel ends from a seed value.  The seed becomes the
-- channel's initial state.  The producer always returns the seed;
-- the consumer calls the producer back, which returns the seed —
-- the mutual recursion bottoms out because the producer returns first.
--
-- >>> import Circuit (reify)
-- >>> let (p, c) = open (42 :: Int)
-- >>> reify (close p c) 99
-- 42
open :: a -> (Producer (->) (,) a, Consumer (->) (,) a)
open seed = (producer, consumer)
  where
    producer = Producer $ \_c -> Lift (const seed)
    consumer = Consumer $ \p -> runProducer p consumer
