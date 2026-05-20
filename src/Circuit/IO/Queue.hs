-- | STM-backed queue strategies.
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

    -- * Feed / drain
    feedQueue,
    drainQueue,

    -- * Concurrent execution
    runConcurrently,
  )
where

import Control.Applicative
import Control.Concurrent.Async (concurrently)
import Control.Concurrent.STM
import Prelude

-- $setup
-- >>> :set -XOverloadedStrings
-- >>> import Circuit.IO.Queue
-- >>> import Control.Concurrent.STM (STM, atomically, newTQueueIO, readTQueue, writeTQueue, TQueue)

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
