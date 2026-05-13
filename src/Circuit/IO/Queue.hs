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
-- >>> import Control.Concurrent.STM (atomically, newTQueueIO)

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
feedQueue :: TQueue a -> [a] -> IO ()
feedQueue q = mapM_ (atomically . writeTQueue q)

-- | Read up to @n@ values from a 'TQueue'.  Blocks on each read.
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
runConcurrently :: IO a -> IO b -> IO (a, b)
runConcurrently = concurrently
