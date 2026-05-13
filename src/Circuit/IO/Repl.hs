-- | Dumb FIFO-based REPL primitives.
--
-- Four operations on a 'Repl':
--
-- > replOpen   :: ReplConfig -> IO Repl
-- > replClose  :: Repl -> IO ()
-- > replCommit :: Repl -> Text -> IO ()
-- > replEmit   :: Repl -> IO [Text]
--
-- No callbacks, no listeners, no async machinery.  Just IO.
-- Line-oriented text.  Cursor-based emission (no duplicate reads).
module Circuit.IO.Repl
  ( -- * Configuration
    ReplConfig (..),
    defaultReplConfig,

    -- * Repl handle
    Repl,
    replOpen,
    replClose,

    -- * Primitives
    replCommit,
    replEmit,
  )
where

import Control.Monad (unless)
import Data.IORef
import Data.Text (Text)
import qualified Data.Text.IO as TIO
import Prelude
import System.Directory (doesFileExist)
import System.IO
import System.Process

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

-- | Configuration for a FIFO-backed REPL session.
data ReplConfig = ReplConfig
  { -- | Command to run (e.g., "cabal")
    replCommand :: String,
    -- | Arguments (e.g., ["repl"])
    replArgs :: [String],
    -- | Path to stdin FIFO
    replStdinPath :: FilePath,
    -- | Path to stdout log file
    replStdoutPath :: FilePath,
    -- | Path to stderr log file
    replStderrPath :: FilePath,
    -- | Working directory
    replWorkingDir :: FilePath
  }
  deriving (Show, Eq)

-- | Sensible defaults for a library REPL in the current directory.
defaultReplConfig :: ReplConfig
defaultReplConfig =
  ReplConfig
    { replCommand = "cabal",
      replArgs = ["repl"],
      replStdinPath = "/tmp/repl-stdin",
      replStdoutPath = "/tmp/repl-stdout.md",
      replStderrPath = "/tmp/repl-stderr.md",
      replWorkingDir = "."
    }

-- ---------------------------------------------------------------------------
-- Repl handle
-- ---------------------------------------------------------------------------

-- | A live REPL session.
--
-- Internally tracks a line cursor so 'replEmit' only returns output
-- that has arrived since the last call.
data Repl = Repl
  { replConfig :: ReplConfig,
    replProcessHandle :: ProcessHandle,
    replCursor :: IORef Int
  }

-- | Ensure a FIFO exists, creating it if necessary.
ensureFifo :: FilePath -> IO ()
ensureFifo path = do
  exists <- doesFileExist path
  unless exists $ do
    callProcess "mkfifo" [path]

-- | Open a REPL session.
--
-- 1. Creates the stdin FIFO if missing.
-- 2. Opens the stdout/stderr files for appending.
-- 3. Spawns the process with stdin connected to the FIFO and
--    stdout/stderr redirected to the log files.
-- 4. Returns a 'Repl' handle with the cursor at 0.
replOpen :: ReplConfig -> IO Repl
replOpen cfg = do
  ensureFifo (replStdinPath cfg)

  -- Open log files for appending (no buffering for immediacy).
  stdoutH <- openFile (replStdoutPath cfg) AppendMode
  stderrH <- openFile (replStderrPath cfg) AppendMode
  hSetBuffering stdoutH NoBuffering
  hSetBuffering stderrH NoBuffering

  -- Open the FIFO read end for the child.
  stdinH <- openFile (replStdinPath cfg) ReadMode

  -- Spawn the process.
  let procSpec =
        (proc (replCommand cfg) (replArgs cfg))
          { cwd = Just (replWorkingDir cfg),
            std_in = UseHandle stdinH,
            std_out = UseHandle stdoutH,
            std_err = UseHandle stderrH
          }
  (_, _, _, ph) <- createProcess procSpec

  -- Close parent's copies of the handles (child owns them now).
  hClose stdinH
  hClose stdoutH
  hClose stderrH

  cursor <- newIORef 0
  pure $ Repl cfg ph cursor

-- | Close a REPL session.
--
-- Sends SIGTERM to the process.  The FIFO and log files are left
-- in place for inspection.
replClose :: Repl -> IO ()
replClose = terminateProcess . replProcessHandle

-- ---------------------------------------------------------------------------
-- Primitives
-- ---------------------------------------------------------------------------

-- | Send one line to the REPL.
--
-- Opens the FIFO write-end, writes the line + newline, flushes, and
-- closes.  This avoids holding the write-end open (which would block
-- if the child exits).
replCommit :: Repl -> Text -> IO ()
replCommit r t =
  withFile (replStdinPath (replConfig r)) WriteMode $ \h -> do
    TIO.hPutStrLn h t
    hFlush h

-- | Receive all new lines from the REPL's stdout.
--
-- Reads the entire stdout file, drops lines already consumed
-- (tracked by cursor), returns the rest, and advances the cursor.
replEmit :: Repl -> IO [Text]
replEmit r = do
  cursor <- readIORef (replCursor r)
  ls <- readLines (replStdoutPath (replConfig r))
  let newLines = drop cursor ls
  writeIORef (replCursor r) (length ls)
  pure newLines

-- | Read all lines from a file.
readLines :: FilePath -> IO [Text]
readLines fp = withFile fp ReadMode $ \h ->
  let go acc = do
        done <- hIsEOF h
        if done
          then pure (reverse acc)
          else do
            line <- TIO.hGetLine h
            go (line : acc)
   in go []
