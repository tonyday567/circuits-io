{-# LANGUAGE RankNTypes #-}

-- | 'Circuit.Ends' now re-exports 'Co' and 'Contra' from the core 'Circuit'
-- library, and provides 'open' for the pure @(->) (,)@ case.
--
-- = Background
--
-- In a proarrow equipment (Bartosz Milewski, 2026), every vertical arrow
-- @f@ has a /companion/ @B(f,1)@ and a /conjoint/ @B(1,f)@, which are
-- horizontal arrows (profunctors) going in opposite directions.  For the
-- identity functor @id@, these specialise to:
--
-- @
--   Companion(id)(x, a) = p(x, a)      -- 'Co'
--   Conjoint(id)(a, x)  = p(a, x)      -- 'Contra'
-- @
--
-- where @p@ is the hom-profunctor ('Circuit' @arr@ @t@).
--
-- The companion and conjoint form an adjunction @Contra ⊣ Co@.
-- The unit @η@ is 'open'; the counit @ε@ is 'close'.  The yanking identity
-- @close contra co = runCo contra co@ is the defining characteristic.
--
-- = Intrinsic vs extrinsic
--
-- When the channel is structural (pure 'Circuit's with 'Knot' feedback),
-- 'Co' and 'Contra' are genuinely different roles — the 'forall x'
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
-- and conversely.  'Co'/'Contra' is not a replacement for 'Knot' —
-- it is a refinement that lets the two channel ends travel independently
-- before being plugged together with 'close'.
module Circuit.Ends
  ( -- * Channel ends (re-exported from 'Circuit')
    Co (..),
    Contra (..),
    close,

    -- * Unit
    open,

    -- * Runtime unit
    openSTM,
  )
where

import Circuit (Co (..), Contra (..), Trace (..), close, run)
import Control.Arrow (Kleisli (..))
import Control.Concurrent.STM
import Prelude hiding (id, (.))

-- | @η@ — the unit of the companion/conjoint adjunction (pure case).
--
-- Create two channel ends from a seed value.  The seed becomes the
-- channel's initial state.  The companion always returns the seed;
-- the conjoint calls the companion back, which returns the seed —
-- the mutual recursion bottoms out because the companion returns first.
--
-- >>> import Circuit (run)
-- >>> let (co, contra) = open (42 :: Int)
-- >>> run (close contra co) 99
-- 42
open :: a -> (Co (->) (,) a, Contra (->) (,) a)
open seed = (co, contra)
  where
    co = Co $ \_ -> Arr (const seed)
    contra = Contra $ \c -> runContra c contra

-- | Runtime unit for an STM 'TVar' cell.
--
-- The companion reads the cell; the conjoint writes its input and then reads
-- the cell back through the companion.  This gives 'close' a duplex
-- (write-then-read) meaning over a shared mutable cell.
--
-- >>> import Circuit (run)
-- >>> import Control.Arrow (Kleisli (..), runKleisli)
-- >>> import Control.Concurrent.STM
-- >>> t <- newTVarIO "before"
-- >>> (co, contra) <- openSTM t
-- >>> runKleisli (run (close contra co)) "after"
-- "after"
openSTM :: TVar a -> IO (Co (Kleisli IO) (,) a, Contra (Kleisli IO) (,) a)
openSTM tvar = pure (co, contra)
  where
    co = Co $ \_ -> Arr (Kleisli $ \_ -> atomically (readTVar tvar))
    contra = Contra $ \co' -> Arr (Kleisli $ \a -> do
      atomically (writeTVar tvar a)
      runKleisli (run (runContra co' contra)) a)
