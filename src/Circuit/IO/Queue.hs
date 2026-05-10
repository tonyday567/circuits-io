-- | STM-backed queue primitives.
--
-- Feed a list into a 'TQueue', drain values from one, run two IO
-- actions concurrently.  Compose with 'Circuit.Channel' 'Producer'
-- and 'Consumer' types at the call site.
module Circuit.IO.Queue
  ( -- * Queue creation
    newTQueueIO,

    -- * Feed / drain
    feedQueue,
    drainQueue,

    -- * Concurrent execution
    runConcurrently,
  )
where

import Control.Concurrent.Async (concurrently)
import Control.Concurrent.STM (TQueue, atomically, newTQueueIO, readTQueue, writeTQueue)

-- $setup
-- >>> import Circuit.IO.Queue
-- >>> import Control.Concurrent.STM (TQueue, atomically, newTQueueIO, readTQueue, writeTQueue)

-- ---------------------------------------------------------------------------
-- Queue creation
-- ---------------------------------------------------------------------------

-- | Create a new unbounded 'TQueue' in IO.
--
-- >>> q <- newTQueueIO :: IO (TQueue Int)
-- >>> atomically (writeTQueue q 42)
-- >>> atomically (readTQueue q)
-- 42
--
-- (Re-exported from "Control.Concurrent.STM".)

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
-- >>> (a, b) <- runConcurrently (pure 1) (pure "hello")
-- >>> (a, b)
-- (1,"hello")
runConcurrently :: IO a -> IO b -> IO (a, b)
runConcurrently = concurrently
