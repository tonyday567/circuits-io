-- | IO combinators for circuits.
--
-- Re-exports the practical IO modules built on Circuit.Channel.
module Circuit.IO
  ( module Circuit.IO.File,
    module Circuit.IO.Queue,
    module Circuit.IO.Repl,
    module Circuit.IO.Time,
  )
where

import Circuit.IO.File
import Circuit.IO.Queue
import Circuit.IO.Repl
import Circuit.IO.Time
