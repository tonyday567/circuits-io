{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE PostfixOperators #-}

-- | Atomic communication primitives on 'Hyper', plus the
--   @prod@/@cons@ constructors with sane lettering.
--
-- Kidney & Wu (POPL 2026) start with two atomic types:
--
-- @
--   Emit   a = () ↬ a   — produce a value
--   Commit a = a ↬ ()   — consume a value
-- @
--
-- These carry no internal state — they're pure value sources and sinks.
-- State is threaded externally via composition. 'lift' bridges to effects:
--
-- @
--   lift putStrLn        :: Hyper String (IO ())  — IO sink
--   lift (const readLn)  :: Hyper () (IO String)  — IO source
-- @
--
-- = prod and cons
--
-- The original K\&W constructors, with consistent lettering:
--
-- @
--                         anchor↙            inner↙    element↙
--   prod a p = Hyper $    \\c          ->   (c  `invoke`  p)  a
--   cons f c = Hyper $    \\p     a    ->   f (p `invoke`  c) a
--                         producer anchor   element       accumulator
-- @
--
-- Both thread the inner Hyper through the continuation (anchor) and
-- place the element on the right. In 'prod' the element is captured at
-- construction time; in 'cons' it arrives at invocation time.
--
-- Without @f@, @cons (\\r a -> r a)@ has the same body as 'prod' but
-- operates on self-dual 'Channel' types (see 'layer').
module Circuit.Channel
  ( -- * Atomic types
    Emit,
    Commit,

    -- * Channel
    Channel,

    -- * Producer / Consumer
    Producer,
    Consumer,

    -- * Construction
    emit,
    commit,
    forget,
    prod,
    cons,
    layer,
  )
where

import Circuit.Hyper

-- $setup
-- >>> :set -XBlockArguments
-- >>> import Circuit.Hyper (run, lift, (⇸), invoke, Hyper(..))

-- ---------------------------------------------------------------------------
-- Atomic types
-- ---------------------------------------------------------------------------

-- | An atomic value producer. @() ↬ a@ — produces @a@ when invoked.
--
-- >>> invoke (emit 42) commit
-- 42
type Emit a = Hyper () a

-- | An atomic value consumer. @a ↬ ()@ — accepts @a@, returns ().
--
-- >>> emit 42 `invoke` commit
-- 42
type Commit a = Hyper a ()

-- ---------------------------------------------------------------------------
-- Channel
-- ---------------------------------------------------------------------------

-- | A bidirectional pipe: consumes @i@, produces @o@, result carrier @r@.
--
--   @Channel r i o = (o → r) ↬ (i → r)@
type Channel r i o = Hyper (o -> r) (i -> r)

-- ---------------------------------------------------------------------------
-- Producer / Consumer
-- ---------------------------------------------------------------------------

-- | A Producer sends elements of type @a@, yielding a result @r@.
--
--   @Producer a r = (a → r) ↬ r@
type Producer a r = Hyper (a -> r) r

-- | A Consumer receives elements of type @a@, yielding a result @r@.
--
--   @Consumer a r = r ↬ (a → r)@
type Consumer a r = Hyper r (a -> r)

-- ---------------------------------------------------------------------------
-- Construction — atomic
-- ---------------------------------------------------------------------------

-- | Wrap a value into an 'Emit'.
--
-- >>> emit 42 `invoke` commit
-- 42
emit :: a -> Emit a
emit a = Hyper $ \_ -> a

-- | A 'Commit' that ignores its input. Alias for 'forget'.
--
-- >>> emit 42 `invoke` commit
-- 42
commit :: Commit a
commit = forget

-- | A 'Commit' that ignores its input.
--
-- >>> emit 42 `invoke` forget
-- 42
forget :: Commit a
forget = Hyper $ \_ -> ()

-- ---------------------------------------------------------------------------
-- Construction — prod / cons (Kidney & Wu)
-- ---------------------------------------------------------------------------

-- | Add an element to a Producer.
--
--   @a@ is captured at construction time.  The continuation @c@ receives
--   the inner Producer @p@ and the element, threaded through 'invoke'.
--
-- >>> prod 42 (Hyper $ \_ -> 0) `invoke` cons (\_ x -> x) (Hyper $ \_ _ -> 0)
-- 42
--
-- Equivalent forms:
--
-- @
--   prod a p = Hyper $ \\c -> (c `invoke` p) a
--   prod a p = layer (Lift (\\c _ -> c a)) . p   -- @a@ supplied now
-- @
prod :: a -> Producer a r -> Producer a r
prod a p = Hyper $ \c -> (c `invoke` p) a

-- | Add a step to a Consumer.
--
--   @a@ arrives at invocation time. The step @f@ receives the accumulator
--   (from the inner Consumer) and the element.
--
-- >>> prod 42 (Hyper $ \_ -> 0) `invoke` cons (\_ x -> x) (Hyper $ \_ _ -> 0)
-- 42
--
-- Equivalent forms:
--
-- @
--   cons f c = Hyper $ \\p a -> f (p `invoke` c) a
--   cons f c = layer @r . f  -- @f@ wraps the result
-- @
cons :: (r -> a -> r) -> Consumer a r -> Consumer a r
cons f c = Hyper $ \p a -> f (p `invoke` c) a

-- ---------------------------------------------------------------------------
-- Construction — layer (self-dual core)
-- ---------------------------------------------------------------------------

-- | The core combinator on the Channel diagonal.
--
-- @
--   layer :: Channel r a a -> Channel r a a
--   layer x = Hyper $ \\anchor a -> (anchor `invoke` x) a
-- @
--
-- Takes a self-dual Hyper and wraps it one layer deeper.  The element @a@
-- arrives at invocation time.  This is the uniform operation that 'prod'
-- and 'cons' specialize:
--
-- @
--   prod a p = layer (Channel r a a)  ...   -- not type-identical, but
--   cons f c = layer (Channel r a a)  ...   -- structurally the same body
-- @
--
-- >>> run (layer (lift (\f x -> (x :: Int)))) (42 :: Int)
-- 42
layer :: Channel r a a -> Channel r a a
layer x = Hyper $ \anchor a -> (anchor `invoke` x) a
