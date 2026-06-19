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
-- The implementation is developed and tested against the controllable
-- mock-repl in test/mock-repl (see the test suite). This lets us reproduce
-- the awkward attributes of real REPLs (noisy startup, hanging prompts without
-- trailing \n, incremental output, extra chatter, state) in a deterministic way
-- before wiring to real targets like cabal repl or agent processes (pi, hermes, flip etc.).
--
-- Parking note (as of this session): side-activity has moved to the main
-- `circuits` package. All REPL/agent-comm primitives, the mock, the ghci
-- helpers, attach for sharing, and the bidirectional multi-round comms thread
-- are safely contained here in circuits-io. See the TODO near startCabalRepl
-- and the dedicated section in readme.md. We have the primitives but have not
-- yet exercised true automated multi-round agent-to-agent back-and-forth.
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
    replAttach,

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

    -- * GHCi / Cabal REPL conveniences

    -- | These filter startup "guff" (build profiles, configuring, Ok modules loaded, etc.)
    -- and provide clean command wrappers for interactive type chasing and pipeline
    -- exploration. See the cabal-repl example.
    ghciCommand,
    isGuff,
    startCabalRepl,
  )
where

import Circuit (Trace (..))
import Control.Arrow (Kleisli (..))
import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Data.Char (isSpace)
import Data.Foldable (for_)
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
    replProcessHandle :: Maybe ProcessHandle,
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
  pure $ Repl cfg (Just ph) cursor

-- | Attach to an already-running REPL (e.g. one started by another agent or
-- manually with the same FIFO paths). Does not spawn or manage the process
-- lifetime. The cursor is initialized to the current end of the stdout log
-- so subsequent 'replEmit' only sees new output.
--
-- This enables multiple clients (agents or humans) to share one REPL session:
-- they all write to the same stdin FIFO (serialized by the OS), see the
-- combined output in the log, and each maintains its own read cursor.
--
-- Use 'replClose' on an attached Repl is a no-op.
replAttach :: ReplConfig -> IO Repl
replAttach cfg = do
  -- Do not create FIFO or spawn; assume caller has set up the process
  -- reading the FIFO and logging output.
  ls <- readLines (replStdoutPath cfg)
  cursor <- newIORef (length ls)
  pure $ Repl cfg Nothing cursor

-- | Close a REPL session.
--
-- Sends SIGTERM to the process (if this Repl owns it, i.e. was created via
-- 'replOpen'). The FIFO and log files are left in place for inspection.
-- For 'replAttach' sessions, this is a no-op.
replClose :: Repl -> IO ()
replClose r = for_ (replProcessHandle r) terminateProcess

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

-- | Read all lines from a file, including a possible partial last line
-- (common when REPLs print a prompt with putStr and no trailing newline).
-- This is important for prompt detection on the hanging prompt line.
readLines :: FilePath -> IO [Text]
readLines fp = do
  content <- TIO.readFile fp
  let parts = T.splitOn "\n" content
  -- If the file ends with \n, the last part is empty; drop it for "full lines".
  -- But we *keep* a non-empty last part even without \n (the partial/prompt line).
  pure $
    if not (T.null content) && T.isSuffixOf "\n" content
      then filter (not . T.null) parts -- or keep empties if wanted; here we drop trailing empty
      else parts

-- ---------------------------------------------------------------------------
-- Circuit views
-- ---------------------------------------------------------------------------

-- | Read all new lines from the REPL as a 'Circuit'.
--
-- Composes with other 'Circuit (Kleisli IO)' fragments via '(>>>)'.
replRead :: Repl -> Trace t (Kleisli IO) () [Text]
replRead r = Lift $ Kleisli $ \() -> replEmit r

-- | Write one line to the REPL as a 'Trace'.
replWrite :: Repl -> Trace t (Kleisli IO) Text ()
replWrite r = Lift $ Kleisli $ replCommit r

-- | Write multiple lines to the REPL as a 'Trace'.
replWriteLines :: Repl -> Trace t (Kleisli IO) [Text] ()
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

-- ---------------------------------------------------------------------------
-- GHCi / Cabal REPL helpers (filter guff, clean interactive use)
-- ---------------------------------------------------------------------------

-- | Send a line to the REPL and return the output produced up to (and not
-- including) the next prompt. Common GHCi/cabal-repl "guff" (build profiles,
-- configuring messages, "Ok, modules loaded.", etc.) is filtered.
--
-- This is the core primitive for the "interactive type trail" use case.
ghciCommand :: Repl -> Text -> IO [Text]
ghciCommand r cmd = do
  replCommit r cmd
  mLines <- replSync r
  pure $ case mLines of
    Nothing -> []
    Just ls -> filter (not . isGuff) (takeWhile (not . defaultPrompt) ls)

-- | Heuristic for lines that are just startup/build ceremony from cabal repl / ghci.
-- These are the "usual guff" users want filtered when using the REPL as an
-- interactive tool for type chasing and pipeline construction.
isGuff :: Text -> Bool
isGuff t =
  or
    [ "Build profile:" `T.isPrefixOf` t,
      "In order, the following will be built" `T.isPrefixOf` t,
      "Configuring library for" `T.isPrefixOf` t,
      "Preprocessing library for" `T.isPrefixOf` t,
      "Building library for" `T.isPrefixOf` t,
      "GHCi, version" `T.isPrefixOf` t,
      "Loaded GHCi configuration" `T.isPrefixOf` t,
      "[1 of " `T.isPrefixOf` t && "] Compiling " `T.isInfixOf` t,
      t == "Ok, modules loaded.",
      "Leaving GHCi." `T.isPrefixOf` t,
      T.all isSpace t
    ]

-- | Convenience: start a cabal repl in the given directory (or "."), wait
-- for the initial prompt (discarding startup guff), and return a handle
-- ready for 'ghciCommand'.
startCabalRepl :: FilePath -> IO Repl
startCabalRepl dir = do
  let cfg =
        defaultReplConfig
          { replCommand = "cabal",
            replArgs = ["repl"],
            replWorkingDir = dir
          }
  r <- replOpen cfg
  -- consume the initial prompt / guff
  _ <- replSync r
  pure r

-- TODO (open thread for bidirectional multi-round agent comms):
-- We have replAttach + shared FIFO/logs for multiple clients.
-- We have clean ghciCommand for filtered request/response.
-- What we have *not* yet built is a higher-level "bus" or protocol that lets
-- two (or more) agents do automated back-and-forth over multiple rounds
-- (AgentA posts -> AgentB consumes/replies -> AgentA reacts ...), using the
-- REPL log as the transcript, without the caller script doing the turn-taking.
-- See examples/cabal-repl.hs (the simulation section) and readme.md for the
-- current status and what to pick up when resuming work in circuits-io.
