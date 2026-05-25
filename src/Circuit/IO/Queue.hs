-- | STM-backed queue strategies with cap/cup (compact closed) interface.
--
-- Ported from box/Box.Queue, recast for circuits-io.  Provides
-- buffered communication primitives with selectable backpressure
-- and overflow policies.
--
-- Compose with 'Circuit.Channel' 'Producer'/'Consumer' at the call
-- site, or use 'feedQueue'/'drainQueue' directly in IO.
module Circuit.IO.Queue
  ( -- * Queue strategies
    Queue (..),
    queueEnds,

    -- * Cap & cup (compact closed)
    makeQueue,
    glueC,

    -- * Feed / drain
    feedQueue,
    drainQueue,

    -- * Concurrent execution
    runConcurrently,
  )
where

import Circuit (Circuit (..))
import Control.Arrow (Kleisli (..))
import Control.Applicative
import Control.Concurrent.Async (concurrently)
import Control.Concurrent.STM
import Prelude

-- $setup
-- >>> :set -XOverloadedStrings
-- >>> import Circuit (Circuit(..), reify)
-- >>> import Circuit.IO.Queue
-- >>> import Control.Arrow (Kleisli(..), runKleisli)
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
  | -- | Single-slot buffer (overwrites on write, blocks on read).
    Single
  | -- | Always holds the latest value (overwrites, never blocks).
    Latest a
  | -- | Like 'Bounded' but drops oldest when full.
    Newest Int
  | -- | Single-slot, only delivers new values (drop pending).
    New
  deriving (Show, Eq)

-- | Create a queue, returning @(write, read)@ ends in STM.
--
-- The read end blocks until a value is available.
--
-- Unbounded FIFO:
--
-- >>> (write, read) <- atomically (queueEnds Unbounded :: STM (Int -> STM (), STM Int))
-- >>> atomically $ write 1 >> write 2
-- >>> atomically read
-- 1
--
-- Bounded with backpressure:
--
-- >>> (write, read) <- atomically (queueEnds (Bounded 2) :: STM (Int -> STM (), STM Int))
-- >>> atomically $ write 1 >> write 2
-- >>> atomically read
-- 1
--
-- Single-slot overwrite:
--
-- >>> (write, read) <- atomically (queueEnds Single :: STM (Int -> STM (), STM Int))
-- >>> atomically $ write 42
-- >>> atomically read
-- 42
--
-- Latest value (always overwrites):
--
-- >>> (write, read) <- atomically (queueEnds (Latest 0) :: STM (Int -> STM (), STM Int))
-- >>> atomically $ write 1 >> write 2
-- >>> atomically read
-- 2
--
-- New-only (drops pending, delivers latest):
--
-- >>> (write, read) <- atomically (queueEnds New :: STM (Int -> STM (), STM Int))
-- >>> atomically $ write 1 >> write 2
-- >>> atomically read
-- 2
--
-- Newest N (drops oldest when full):
--
-- >>> (write, read) <- atomically (queueEnds (Newest 2) :: STM (Int -> STM (), STM Int))
-- >>> atomically $ write 1 >> write 2 >> write 3
-- >>> atomically read
-- 2
queueEnds :: Queue a -> STM (a -> STM (), STM a)
queueEnds qu =
  case qu of
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
    New -> do
      m <- newEmptyTMVar
      pure (\x -> tryTakeTMVar m *> putTMVar m x, takeTMVar m)
    Newest n -> do
      q <- newTBQueue (fromIntegral n)
      let write x = writeTBQueue q x <|> (tryReadTBQueue q *> write x)
      pure (write, readTBQueue q)

-- ---------------------------------------------------------------------------
-- Cap & cup (compact closed)
-- ---------------------------------------------------------------------------

-- | Create a dual pair: push end and pop end sharing a single STM channel.
--
-- This is the cap @η : I → A* ⊗ A@ from compact closed categories:
-- the two ends are duals connected through the same underlying channel.
-- The queue strategy parameterises what \"connected\" means —
-- unbounded, bounded (backpressure), single-slot (overwrite), etc.
--
-- >>> (pushA, popA) <- makeQueue Unbounded :: IO (Circuit (Kleisli IO) (,) Int (), Circuit (Kleisli IO) (,) () Int)
-- >>> runKleisli (reify pushA) 42
-- ()
-- >>> runKleisli (reify popA) ()
-- 42
makeQueue :: Queue a -> IO (Circuit (Kleisli IO) (,) a (), Circuit (Kleisli IO) (,) () a)
makeQueue q = do
  (write, read') <- atomically (queueEnds q)
  let push' = Lift $ Kleisli $ \a -> atomically (write a)
      pop'  = Lift $ Kleisli $ \() -> atomically read'
  pure (push', pop')

-- | Connect a pop end to a push end.
--
-- This is the cup @ε : A* ⊗ A → I@. The pop end produces a value,
-- the push end consumes it. They can be from different channels —
-- this feeds values from one queue into another.
--
-- @glueC popA pushB = popA >>> pushB@
--
-- >>> (pushA, popA) <- makeQueue Unbounded :: IO (Circuit (Kleisli IO) (,) Int (), Circuit (Kleisli IO) (,) () Int)
-- >>> (pushB, popB) <- makeQueue (Bounded 2) :: IO (Circuit (Kleisli IO) (,) Int (), Circuit (Kleisli IO) (,) () Int)
-- >>> runKleisli (reify pushA) 1  -- feed value into queue A
-- >>> runKleisli (reify (glueC popA pushB)) ()  -- move from A to B
-- >>> runKleisli (reify popB) ()
-- 1
glueC :: Circuit (Kleisli IO) (,) () a -> Circuit (Kleisli IO) (,) a () -> Circuit (Kleisli IO) (,) () ()
glueC popC pushC = Compose pushC popC

-- ---------------------------------------------------------------------------
-- Feed / drain
-- ---------------------------------------------------------------------------

-- | Write a list of values into a 'TQueue'.
--
-- >>> q <- newTQueueIO :: IO (TQueue Int)
-- >>> feedQueue q [1, 2, 3]
-- >>> atomically (readTQueue q)
-- 1
feedQueue :: TQueue a -> [a] -> IO ()
feedQueue q = mapM_ (atomically . writeTQueue q)

-- | Read up to @n@ values from a 'TQueue'.  Blocks on each read.
--
-- >>> q <- newTQueueIO :: IO (TQueue Int)
-- >>> feedQueue q [1, 2, 3]
-- >>> drainQueue q 2
-- [1,2]
drainQueue :: TQueue a -> Int -> IO [a]
drainQueue q n = go n []
  where
    go 0 acc = pure (reverse acc)
    go k acc = do
      x <- atomically (readTQueue q)
      go (k - 1) (x : acc)

-- ---------------------------------------------------------------------------
-- Concurrent execution
-- ---------------------------------------------------------------------------

-- | Run two IO actions concurrently, returning both results.
--
-- >>> runConcurrently (pure 1) (pure 2)
-- (1,2)
runConcurrently :: IO a -> IO b -> IO (a, b)
runConcurrently = concurrently
