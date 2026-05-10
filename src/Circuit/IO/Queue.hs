-- | STM-backed queues as Producer/Consumer pairs.
--
-- Build a 'Producer' that reads from a 'TQueue' with IO effects
-- embedded in the 'Hyper' body via lazy 'unsafeInterleaveIO'.
-- Use 'glue' with any 'Consumer' to drain it.
module Circuit.IO.Queue
  ( -- * Queue-backed Producer
    queueProducer,
  )
where

import Circuit.Channel
  ( Consumer,
    Producer,
    cons,
    glue,
    prod,
    yield,
  )
import Circuit.Hyper (Hyper (..), invoke)
import Control.Concurrent.STM (TQueue, atomically, readTQueue)
import Prelude hiding (id, (.))
import System.IO.Unsafe (unsafeInterleaveIO, unsafePerformIO)

-- $setup
-- >>> :set -XBlockArguments
-- >>> import Circuit.Channel
-- >>> import Circuit.IO.File (collectAll)
-- >>> import Circuit.IO.Queue
-- >>> import Control.Concurrent.STM (TQueue, atomically, newTQueue, newTQueueIO, readTQueue, writeTQueue)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Collect all 'Just' values from a producer into a list.
collectAll :: Consumer (Maybe a) [a]
collectAll = go
  where
    go = cons step go
    step mx acc = case mx of
      Just x  -> x : acc
      Nothing -> acc

-- | Build a finite list producer. Each element becomes @Just x@,
-- terminated by @Nothing@.
listSource :: [a] -> Producer (Maybe a) [a]
listSource = foldr (\x p -> prod (Just x) p) (prod Nothing (yield []))

-- ---------------------------------------------------------------------------
-- Queue-backed Producer
-- ---------------------------------------------------------------------------

-- | A 'Producer' that reads values from a 'TQueue'.
--
-- Each 'invoke' reads one value from the queue via 'unsafeInterleaveIO',
-- lazily threading the STM effect through the 'Hyper' body.  Produces
-- @Just x@ for each value read.
--
-- >>> q <- newTQueueIO :: IO (TQueue Int)
-- >>> atomically (writeTQueue q 1)
-- >>> atomically (writeTQueue q 2)
-- >>> let p = queueProducer q
-- >>> glue collectAll p
-- [1,2]
queueProducer :: TQueue a -> Producer (Maybe a) [a]
queueProducer q = Hyper $ \consumer ->
  unsafePerformIO $ unsafeInterleaveIO $ do
    x <- atomically (readTQueue q)
    pure $! x : invoke consumer (queueProducer q) (Just x)
{-# NOINLINE queueProducer #-}
