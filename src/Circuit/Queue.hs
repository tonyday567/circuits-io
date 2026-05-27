-- | Queue strategies and ends for circuits — pure and STM.
--
-- The 'Queue' type describes buffering semantics (Unbounded, Bounded,
-- Single, Latest, Newest, New).  Two families of ends:
--
-- * 'endsSTM' — STM mutables, blocking reads, for IO pipelines via 'makeQueue'.
-- * 'endsPure' — pure @[a]@ state, 'Bool'/'Maybe' for partiality, for pure circuits.
--
-- Circuit lifters ('writeC', 'readC', 'pushC', 'popC', 'pushDrop', 'popMaybe')
-- convert the pure ends into 'Circuit's.  The bare FIFO 'push' and 'pop' operate
-- directly on @([a], payload)@ pairs.
module Circuit.Queue
  ( -- * Queue strategies
    Queue (..),

    -- * Queue ends
    endsSTM,
    endsPure,

    -- * Circuit ends (STM)
    makeQueue,
    closeQueue,

    -- * Circuit lifters (pure)
    writeC,
    readC,
    pushC,
    popC,
    pushDrop,
    popMaybe,

    -- * Bare FIFO
    push,
    pop,

    -- * Concurrent execution
    runConcurrently,
  )
where

import Circuit (Circuit (..))
import Control.Applicative
import Control.Arrow (Kleisli (..))
import Control.Concurrent.Async (concurrently)
import Control.Concurrent.STM
import Prelude

-- $setup
-- >>> :set -XOverloadedStrings
-- >>> import Circuit (Circuit(..), reify)
-- >>> import Circuit.Queue
-- >>> import Control.Arrow (Kleisli(..), runKleisli)
-- >>> import Control.Category ((>>>))
-- >>> import Control.Concurrent.STM (STM, TQueue, atomically, newTQueueIO, readTQueue, writeTQueue)

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
-- @
-- endsPure :: Queue a -> (a -> [a] -> ([a], Bool), [a] -> ([a], Maybe a))
-- @
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
-- Cap (compact closed) — STM
-- ---------------------------------------------------------------------------

-- | Create a dual pair: push end and pop end sharing a single STM channel.
--
-- The cap @η : I → A* ⊗ A@ from compact closed categories.
-- The queue strategy parameterises what "connected" means.
--
-- >>> (pushA, popA) <- makeQueue Unbounded :: IO (Circuit (Kleisli IO) (,) Int (), Circuit (Kleisli IO) (,) () Int)
-- >>> (pushB, popB) <- makeQueue Unbounded :: IO (Circuit (Kleisli IO) (,) Int (), Circuit (Kleisli IO) (,) () Int)
-- >>> let pipe = Lift (Kleisli $ \() -> pure (7 :: Int)) >>> pushA >>> popA >>> pushB >>> popB
-- >>> runKleisli (reify pipe) ()
-- 7
makeQueue :: Queue a -> IO (Circuit (Kleisli IO) (,) a (), Circuit (Kleisli IO) (,) () a)
makeQueue q = do
  (write, read') <- atomically (endsSTM q)
  let push' = Lift $ Kleisli $ \a -> atomically (write a)
      pop' = Lift $ Kleisli $ \() -> atomically read'
  pure (push', pop')

-- | Plug a push end and a pop end together into a single circuit.
--
-- This is the extrinsic analogue of 'Circuit.Ends.close': two ends
-- that share an STM channel are composed into @Circuit a a@.
closeQueue ::
  Circuit (Kleisli IO) (,) a () ->
  Circuit (Kleisli IO) (,) () a ->
  Circuit (Kleisli IO) (,) a a
closeQueue push' pop' = Compose pop' push'

-- ---------------------------------------------------------------------------
-- Circuit lifters (pure)
-- ---------------------------------------------------------------------------

-- | Write end as a Circuit.  'Bool' = write accepted?
writeC :: (s -> a -> (s, Bool)) -> Circuit (->) (,) (s, a) (s, Bool)
writeC f = Lift (uncurry f)

-- | Read end as a Circuit.  'Maybe' a = value available?
readC :: (s -> (s, Maybe a)) -> Circuit (->) (,) (s, ()) (s, Maybe a)
readC f = Lift (\(s, ()) -> f s)

-- | Write end that errors on rejection (Bounded-full, Single-occupied).
-- Collapses 'Bool' into @()@, matching the 'push' signature.
pushC :: (s -> a -> (s, Bool)) -> Circuit (->) (,) (s, a) (s, ())
pushC f = Lift $ \(s, a) -> case f s a of
  (s', True) -> (s', ())
  (_, False) -> error "pushC: rejected"

-- | Read end that errors on empty.
-- Collapses 'Maybe' a into a, matching the 'pop' signature.
popC :: (s -> (s, Maybe a)) -> Circuit (->) (,) (s, ()) (s, a)
popC f = Lift $ \(s, ()) -> case f s of
  (s', Just a) -> (s', a)
  (_, Nothing) -> error "popC: empty"

-- | Push that silently drops on rejection (Bounded-full → discard).
pushDrop :: (s -> a -> (s, Bool)) -> Circuit (->) (,) (s, a) (s, ())
pushDrop f = Lift $ \(s, a) -> case f s a of
  (s', True) -> (s', ())
  (s', False) -> (s', ())

-- | Pop that returns 'Nothing' on empty instead of erroring.
popMaybe :: (s -> (s, Maybe a)) -> Circuit (->) (,) (s, ()) (s, Maybe a)
popMaybe = readC

-- ---------------------------------------------------------------------------
-- Bare FIFO
-- ---------------------------------------------------------------------------

-- | Enqueue: push a value onto the buffer, return @()@.
--
-- >>> reify push ([], 1)
-- ([1],())
push :: Circuit (->) (,) ([a], a) ([a], ())
push = Lift $ \(buf, a) -> (buf ++ [a], ())

-- | Dequeue: pop a value from the buffer.
--
-- >>> reify pop ([1,2], ())
-- ([2],1)
pop :: Circuit (->) (,) ([a], ()) ([a], a)
pop = Lift $ \(buf, ()) -> case buf of
  [] -> error "pop: empty"
  x : xs -> (xs, x)

-- | Run two IO actions concurrently, returning both results.
runConcurrently :: IO a -> IO b -> IO (a, b)
runConcurrently = concurrently
