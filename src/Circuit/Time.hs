-- | Time primitives for circuits — sleep, timestamp, gaps.
--
-- Simple IO wrappers.  For 'Out'/'In' timing patterns,
-- compose with 'Circuit.Perf' primitives.
module Circuit.Time
  ( -- * Sleep
    sleep,

    -- * Timestamp
    stampNow,
    stampIO,

    -- * Gaps
    measureGap,
    withGaps,
  )
where

import Control.Concurrent
import Data.Time

-- $setup
-- >>> import Circuit.Time
-- >>> import Data.Time (getCurrentTime)

-- ---------------------------------------------------------------------------
-- Sleep
-- ---------------------------------------------------------------------------

-- | Sleep for the given number of seconds.
--
-- >>> sleep 0.001
sleep :: Double -> IO ()
sleep s = threadDelay (floor (s * 1e6))

-- ---------------------------------------------------------------------------
-- Timestamp
-- ---------------------------------------------------------------------------

-- | Attach the current UTC time to a value.
--
-- >>> (t, x) <- stampNow "hello"
-- >>> x
-- "hello"
stampNow :: a -> IO (UTCTime, a)
stampNow a = do
  t <- getCurrentTime
  pure (t, a)

-- | Measure how long an IO action takes, returning (seconds, result).
--
-- >>> (dt, x) <- stampIO (sleep 0.001 >> pure 42)
-- >>> x
-- 42
stampIO :: IO a -> IO (Double, a)
stampIO action = do
  t0 <- getCurrentTime
  result <- action
  t1 <- getCurrentTime
  let dt = realToFrac (diffUTCTime t1 t0) :: Double
  pure (dt, result)

-- ---------------------------------------------------------------------------
-- Gaps
-- ---------------------------------------------------------------------------

-- | Measure the time gap between two IO actions.
-- Returns the time between the first and second action in seconds.
--
-- >>> dt <- measureGap (sleep 0.01) (pure ())
-- >>> dt > 0
-- True
measureGap :: IO a -> IO b -> IO Double
measureGap before after = do
  t0 <- getCurrentTime
  _ <- before
  t1 <- getCurrentTime
  _ <- after
  pure (realToFrac (diffUTCTime t1 t0) :: Double)

-- | Run an action repeatedly, recording the time gap between each run.
-- Returns the list of (gap, result) pairs.
--
-- >>> results <- withGaps 3 (sleep 0.001 >> pure "x")
-- >>> length results
-- 3
-- >>> all (\(dt, x) -> dt > 0 && x == "x") results
-- True
withGaps :: Int -> IO a -> IO [(Double, a)]
withGaps 0 _ = pure []
withGaps n action = do
  (dt, result) <- stampIO action
  rest <- withGaps (n - 1) action
  pure ((dt, result) : rest)
