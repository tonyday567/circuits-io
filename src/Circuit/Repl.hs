{-# LANGUAGE OverloadedStrings #-}

-- | Dumb FIFO-based REPL primitives.
--
-- Four raw operations on a 'Repl':
--
-- > replOpen   :: ReplConfig -> IO Repl
-- > replClose  :: Repl -> IO ()
-- > replCommit :: Repl -> Text -> IO ()
-- > replEmit   :: Repl -> IO [Text]
--
-- Plus two 'Circuit' views for composition with the rest of @circuits-io@:
--
-- > replRead  :: Repl -> Circuit (Kleisli IO) (,) () [Text]
-- > replWrite :: Repl -> Circuit (Kleisli IO) (,) Text ()
--
-- No callbacks, no listeners, no async machinery.  Just IO.
-- Line-oriented text.  Cursor-based emission (no duplicate reads).
module Circuit.Repl
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

    -- * Circuit views
    replRead,
    replWrite,
    replWriteLines,

    -- * Sync
    replSync,
    replSyncWith,
    defaultPrompt,
  )
where

import Circuit (Circuit (..))
import Control.Arrow (Kleisli (..))
import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Data.IORef
import Data.List (find)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist)
import System.IO
import System.Process
import Prelude

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

-- ---------------------------------------------------------------------------
-- Circuit views
-- ---------------------------------------------------------------------------

-- | Read all new lines from the REPL as a 'Circuit'.
--
-- Composes with other 'Circuit (Kleisli IO)' fragments via '(>>>)'.
replRead :: Repl -> Circuit (Kleisli IO) (,) () [Text]
replRead r = Lift $ Kleisli $ \() -> replEmit r

-- | Write one line to the REPL as a 'Circuit'.
replWrite :: Repl -> Circuit (Kleisli IO) (,) Text ()
replWrite r = Lift $ Kleisli $ replCommit r

-- | Write multiple lines to the REPL as a 'Circuit'.
replWriteLines :: Repl -> Circuit (Kleisli IO) (,) [Text] ()
replWriteLines r = Lift $ Kleisli $ mapM_ (replCommit r)

-- ---------------------------------------------------------------------------
-- Sync — poll with backoff until prompt
-- ---------------------------------------------------------------------------

-- | Default prompt detector for GHCi-style REPLs.
-- Matches @ghci> @, @λ> @, or any line ending in @> @.
defaultPrompt :: Text -> Bool
defaultPrompt t = "ghci> " `T.isSuffixOf` t || "λ> " `T.isSuffixOf` t || "> " `T.isSuffixOf` t

-- | Synchronously collect REPL output until a prompt is detected.
--
-- Polls with exponential backoff (10ms → 500ms cap).  Default timeout is
-- 30 seconds.  Returns 'Nothing' if the timeout fires before a prompt.
--
-- This is the primitive for request/response interaction: commit a
-- command, then 'replSync' to collect the response up to the next prompt.
replSync :: Repl -> IO (Maybe [Text])
replSync = replSyncWith defaultPrompt 30000000

-- | General sync with custom prompt detector and timeout.
--
-- The detector is applied to each line returned by 'replEmit'.  Output
-- is accumulated across polls.  When a matching line is found, the
-- function returns 'Just' everything up to and including that prompt line.
--
-- If the timeout (in microseconds) fires first, returns 'Nothing'.
replSyncWith :: (Text -> Bool) -> Int -> Repl -> IO (Maybe [Text])
replSyncWith isPrompt timeoutUs r = go 0 [] 10000
  where
    go elapsed acc delay = do
      newLines <- replEmit r
      let acc' = acc ++ newLines
          foundPrompt = isJust (find isPrompt newLines)
      if foundPrompt
        then pure (Just acc')
        else do
          let elapsed' = elapsed + delay
          if elapsed' >= timeoutUs
            then pure Nothing
            else do
              threadDelay delay
              let delay' = min 500000 (floor (fromIntegral delay * 1.5 :: Double))
              go elapsed' acc' delay'
