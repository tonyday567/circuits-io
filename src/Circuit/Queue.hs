-- | Queue strategies and ends for circuits — pure and STM.
--
-- The 'Queue' type describes buffering semantics (Unbounded, Bounded,
-- Single, Latest, Newest).  Two families of ends:
--
-- * 'endsSTM' — STM mutables, blocking reads.
-- * 'endsPure' — pure @[a]@ state, 'Bool'/'Maybe' for partiality.
--
-- 'endsQueue' creates a dual pair of circuit ends sharing an STM channel.
-- 'push' and 'pop' lift pure ends into 'Circuit's with state threaded
-- through the tensor.  All four are polymorphic in the tensor @t@.
module Circuit.Queue
  ( -- * Queue strategies
    Queue (..),

    -- * Queue ends
    endsSTM,
    endsPure,

    -- * Circuit ends (STM)
    endsQueue,
    closeQueue,

    -- * Type aliases
    WireK,
    Emit,
    Commit,

    -- * State-threading lifters
    push,
    pop,
  )
where

import Circuit (Trace (..))
import Control.Applicative
import Control.Arrow (Kleisli (..))
import Control.Concurrent.STM
import Prelude

-- $setup
-- >>> :set -XOverloadedStrings
-- >>> import Circuit (Trace(..), realise)
-- >>> import Circuit.Queue
-- >>> import Control.Arrow (Kleisli(..), runKleisli)
-- >>> import Control.Category ((>>>))
-- >>> import Control.Concurrent.STM (STM, TQueue, atomically, newTQueueIO, readTQueue, writeTQueue)

-- ---------------------------------------------------------------------------
-- Type aliases
-- ---------------------------------------------------------------------------

-- | A wire over 'Kleisli' @m@ with the @(,)@ tensor, by convention.
-- 'endsQueue' and 'closeQueue' are polymorphic in the tensor; this alias
-- pins it for readability.
type WireK m = Trace (,) (Kleisli m)

-- | Emit elements of type @a@.
type Emit m a = WireK m () a

-- | Commit elements of type @a@.
type Commit m a = WireK m a ()

-- ---------------------------------------------------------------------------
-- Queue strategies
-- ---------------------------------------------------------------------------

-- | How messages are queued between producer and consumer.
data Queue a
  = -- | Unbounded FIFO queue.
    Unbounded
  | -- | Bounded FIFO with backpressure (write blocks when full).
    Bounded Int
  | -- | Single-slot buffer (write overwrites, read empties).
    Single
  | -- | Always holds the latest value (overwrites, never blocks).
    Latest a
  | -- | Like 'Bounded' but drops oldest when full.
    Newest Int
  deriving (Show, Eq)

-- ---------------------------------------------------------------------------
-- STM ends
-- ---------------------------------------------------------------------------

-- | Create STM write/read ends for a queue strategy.
--
-- @
-- endsSTM :: Queue a -> STM (a -> STM (), STM a)
-- @
--
-- The read end blocks until a value is available.
--
-- >>> (w, r) <- atomically (endsSTM Unbounded :: STM (Int -> STM (), STM Int))
-- >>> atomically $ w 1 >> w 2
-- >>> atomically r
-- 1
endsSTM :: Queue a -> STM (a -> STM (), STM a)
endsSTM = \case
  Bounded n -> do
    q <- newTBQueue (fromIntegral n)
    pure (writeTBQueue q, readTBQueue q)
  Unbounded -> do
    q <- newTQueue
    pure (writeTQueue q, readTQueue q)
  Single -> do
    m <- newEmptyTMVar
    pure (putTMVar m, takeTMVar m)
  Latest a -> do
    t <- newTVar a
    pure (writeTVar t, readTVar t)
  Newest n -> do
    q <- newTBQueue (fromIntegral n)
    let write x = writeTBQueue q x <|> (tryReadTBQueue q *> write x)
    pure (write, readTBQueue q)

-- ---------------------------------------------------------------------------
-- Pure ends
-- ---------------------------------------------------------------------------

-- | Create pure write/read ends for a queue strategy.
--
-- All strategies operate on a @[a]@ buffer.  'Bool' signals write
-- acceptance; 'Maybe' signals value availability.
--
-- >>> let (write, read) = endsPure Unbounded
-- >>> let (b1, _) = write 1 []
-- >>> let (b2, _) = write 2 b1
-- >>> read b2
-- ([2],Just 1)
endsPure :: Queue a -> (a -> [a] -> ([a], Bool), [a] -> ([a], Maybe a))
endsPure = \case
  Unbounded ->
    ( \x buf -> (buf ++ [x], True),
      \case [] -> ([], Nothing); x : xs -> (xs, Just x)
    )
  Bounded n ->
    ( \x buf -> if length buf < n then (buf ++ [x], True) else (buf, False),
      \case [] -> ([], Nothing); x : xs -> (xs, Just x)
    )
  Single ->
    ( \x _ -> ([x], True),
      \case [] -> ([], Nothing); x : _ -> ([], Just x)
    )
  Latest d ->
    ( \x _ -> ([x], True),
      \buf -> (buf, Just (case buf of x : _ -> x; [] -> d))
    )
  Newest n ->
    ( \x buf ->
        let buf' = buf ++ [x]
         in if length buf' <= n then (buf', True) else (drop 1 buf', True),
      \case [] -> ([], Nothing); x : xs -> (xs, Just x)
    )

-- ---------------------------------------------------------------------------
-- State-threading lifters
-- ---------------------------------------------------------------------------

-- | Push to state, returning 'Bool'.
-- 'False' signals rejection (e.g. bounded queue full).
--
-- Bare FIFO via 'endsPure' (note: 'flip' to match state-first order):
--
-- >>> let qpush = push (flip (fst (endsPure Unbounded)))
-- >>> realise (qpush :: Trace (,) (->) ([Int], Int) ([Int], Bool)) ([], 1)
-- ([1],True)
push :: (s -> a -> (s, Bool)) -> Trace t (->) (s, a) (s, Bool)
push f = Lift (uncurry f)

-- | Pop from state, returning 'Maybe' a.
-- 'Nothing' signals empty.
--
-- Bare FIFO via 'endsPure':
--
-- >>> let qpop = pop (snd (endsPure Unbounded))
-- >>> realise (qpop :: Trace (,) (->) ([Int], ()) ([Int], Maybe Int)) ([1,2,3], ())
-- ([2,3],Just 1)
-- >>> realise (qpop :: Trace (,) (->) ([Int], ()) ([Int], Maybe Int)) ([], ())
-- ([],Nothing)
pop :: (s -> (s, Maybe a)) -> Trace t (->) (s, ()) (s, Maybe a)
pop f = Lift (\(s, ()) -> f s)

-- ---------------------------------------------------------------------------
-- STM queue ends
-- ---------------------------------------------------------------------------

-- | Create a dual pair: push end and pop end sharing a single STM channel.
--
-- Use 'WireK' to pin the tensor for readability:
--
-- >>> (pushA, popA) <- atomically (endsQueue Unbounded :: STM (WireK IO Int (), WireK IO () Int))
-- >>> (pushB, popB) <- atomically (endsQueue Unbounded :: STM (WireK IO Int (), WireK IO () Int))
-- >>> let pipe = Lift (Kleisli $ \() -> pure (7 :: Int)) >>> pushA >>> popA >>> pushB >>> popB
-- >>> runKleisli (realise pipe) ()
-- 7
endsQueue :: Queue a -> STM (Trace t (Kleisli IO) a (), Trace t (Kleisli IO) () a)
endsQueue q = do
  (write, read') <- endsSTM q
  pure (Lift (Kleisli (atomically . write)), Lift (Kleisli (\() -> atomically read')))

-- | Plug a push end and a pop end together into a single circuit.
--
-- This is the extrinsic analogue of 'Circuit.Ends.close': two ends
-- that share an STM channel are composed into @Circuit a a@.
closeQueue ::
  Trace t (Kleisli IO) a () ->
  Trace t (Kleisli IO) () a ->
  Trace t (Kleisli IO) a a
closeQueue push' pop' = Compose pop' push'
