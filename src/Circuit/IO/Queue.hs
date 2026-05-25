-- | Re-exports from 'Circuit.Queue' for backwards compatibility.
--
-- Prefer 'Circuit.Queue' directly.  This module exists so existing
-- imports of 'Circuit.IO.Queue' continue to work.
module Circuit.IO.Queue
  ( module Circuit.Queue,
  )
where

import Circuit.Queue
