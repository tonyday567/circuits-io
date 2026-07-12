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
--
-- Read position uses the standalone @cursor@ package ('Cursor.newFile') so
-- attach points survive process restart and share the same type as muster.
module Circuit.Repl
  ( -- * Configuration
    ReplConfig (..),
    defaultReplConfig,

    -- * Repl handle
    Repl,
    replGetConfig,
    replOpen,
    replClose,
    replAttach,

    -- * Primitives
    replCommit,
    replEmit,

    -- * Write claim (multi-agent exclusive eval)
    replClaim,
    replRelease,
    replEval,

    -- * Cabal-repl session helpers
    cabalReplConfig,
    withCabalRepl,

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

    -- * Hermes agent conveniences
    startAgent,
    hermesPrompt,
    hermesCommand,
  )
where

import Circuit (Trace (..))
import Control.Arrow (Kleisli (..))
import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Control.Monad (unless, when)
import Cursor qualified as Cur
import Data.Char (isSpace)
import Data.Foldable (for_)
import Data.IORef
import Data.List (find)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.Environment (getEnv)
import System.FilePath ((</>))
import System.IO
import System.Posix.Process (getProcessID)
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
    replWorkingDir :: FilePath,
    -- | Write-token path for multi-agent exclusive claim.
    --   Default: @replStdoutPath <> \".token\"@.
    replTokenPath :: FilePath
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
      replWorkingDir = ".",
      replTokenPath = "/tmp/repl-stdout.md.token"
    }

-- ---------------------------------------------------------------------------
-- Repl handle
-- ---------------------------------------------------------------------------

-- | A live REPL session.
--
-- Internally tracks a line cursor ('Cur.Cursor', file-backed) so 'replEmit'
-- only returns output that has arrived since the last call.  File backing
-- means attach cursors survive restarts and match muster/process-harness.
data Repl = Repl
  { replConfig :: ReplConfig,
    replProcessHandle :: Maybe ProcessHandle,
    replCursor :: Cur.Cursor,
    -- | Last trailing partial line we already surfaced (hanging prompt).
    --   Used so idle polls do not re-emit the same @ghci> @ forever, while
    --   still re-surfacing it after complete output (answer + new prompt).
    replLastPartial :: IORef (Maybe Text)
  }

-- | Config used to open / attach this handle.
replGetConfig :: Repl -> ReplConfig
replGetConfig = replConfig

-- | Cursor file beside the stdout log.  Owner uses @.cursor@; attach uses
-- @.cursor-attach-<pid>@ so concurrent readers do not share position.
ownerCursorPath :: ReplConfig -> FilePath
ownerCursorPath cfg = replStdoutPath cfg <> ".cursor"

attachCursorPath :: ReplConfig -> IO FilePath
attachCursorPath cfg = do
  pid <- getProcessID
  pure (replStdoutPath cfg <> ".cursor-attach-" <> show pid)

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

  cursor <- Cur.newFile (ownerCursorPath cfg)
  Cur.set cursor 0
  lastP <- newIORef Nothing
  pure $ Repl cfg (Just ph) cursor lastP

-- | Attach to an already-running REPL (e.g. one started by another agent or
-- manually with the same FIFO paths). Does not spawn or manage the process
-- lifetime. The cursor is initialized to the current end of the stdout log
-- so subsequent 'replEmit' only sees new output.
--
-- This enables multiple clients (agents or humans) to share one REPL session:
-- they all write to the same stdin FIFO (serialized by the OS), see the
-- combined output in the log, and each maintains its own read cursor
-- (file-backed via the @cursor@ package).
--
-- Use 'replClose' on an attached Repl is a no-op.
replAttach :: ReplConfig -> IO Repl
replAttach cfg = do
  -- Do not create FIFO or spawn; assume caller has set up the process
  -- reading the FIFO and logging output.
  content <- readLogContent (replStdoutPath cfg)
  let (complete, _) = splitComplete content
  path <- attachCursorPath cfg
  cursor <- Cur.newFile path
  Cur.seekEnd cursor complete
  lastP <- newIORef Nothing
  pure $ Repl cfg Nothing cursor lastP

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
-- Advances the cursor only over /complete/ (newline-terminated) lines, and
-- always surfaces a trailing partial line (GHCi's hanging @ghci> @).  This
-- avoids the partial-line trap: if a partial prompt is counted as a full
-- line, GHCi appending a type answer onto it makes @drop@ skip the answer.
replEmit :: Repl -> IO [Text]
replEmit r = do
  content <- readLogContent (replStdoutPath (replConfig r))
  let (complete, mPartial) = splitComplete content
  news <- Cur.pollLines (replCursor r) complete
  prev <- readIORef (replLastPartial r)
  writeIORef (replLastPartial r) mPartial
  let partialNews = case (news, prev, mPartial) of
        (_, _, Nothing) -> []
        -- After complete lines arrive, re-surface current partial (new prompt).
        (_ : _, _, Just p) -> [p]
        -- Idle: only emit partial if it is new or changed.
        ([], Just old, Just p) | old == p -> []
        ([], _, Just p) -> [p]
  pure (news <> partialNews)

-- ---------------------------------------------------------------------------
-- Write claim — exclusive multi-agent eval
-- ---------------------------------------------------------------------------

-- | Try to take the write token.  Returns 'True' if acquired (or already
-- held by the same name).  Returns 'False' if another holder has it.
replClaim :: Repl -> String -> IO Bool
replClaim r name = do
  let path = replTokenPath (replConfig r)
  exists <- doesFileExist path
  if not exists
    then do
      writeFile path (name <> "\n")
      pure True
    else do
      holder <- filter (not . isSpace) <$> readFile path
      pure (holder == name)

-- | Release the write token if held by @name@.  No-op if free or held by other.
replRelease :: Repl -> String -> IO ()
replRelease r name = do
  let path = replTokenPath (replConfig r)
  exists <- doesFileExist path
  when exists $ do
    holder <- filter (not . isSpace) <$> readFile path
    when (holder == name) $ removeFile path

-- | Claim → commit → sync to prompt → release.
--
-- Returns 'Nothing' if the claim failed (token held by another) or if
-- 'replSync' timed out.  On success returns the response lines (prompt
-- line included, as with 'replSync').
replEval :: Repl -> String -> Text -> IO (Maybe [Text])
replEval r name cmd = do
  ok <- replClaim r name
  if not ok
    then pure Nothing
    else do
      -- Drain pending so the response window starts clean.
      _ <- replEmit r
      replCommit r cmd
      -- Settle + drain: type answers can land fused onto a hanging prompt.
      threadDelay 100_000
      m <- replSync r
      threadDelay 100_000
      extra <- replEmit r
      replRelease r name
      pure $ case m of
        Nothing -> Nothing
        Just ls ->
          Just $
            map stripGhciPrefix $
              filter (\t -> not (T.null (T.strip t))) (ls <> extra)

-- ---------------------------------------------------------------------------
-- Cabal-repl session helpers (direct process, no cat-bus)
-- ---------------------------------------------------------------------------

-- | Build a 'ReplConfig' for @cabal repl@ in @projectDir@, with session
-- state under @$HOME/mg/logs/process-harness/<session>/@.
--
-- Paths:
--
--   * @stdin.fifo@ — FIFO
--   * @stdout.md@ / @stderr.md@ — append-only logs
--   * @write.token@ — multi-agent claim file
--
-- Creates the session directory if missing.
cabalReplConfig :: FilePath -> String -> IO ReplConfig
cabalReplConfig projectDir session = do
  home <- getEnv "HOME"
  let dir = home </> "mg" </> "logs" </> "process-harness" </> session
  createDirectoryIfMissing True dir
  pure
    defaultReplConfig
      { replCommand = "cabal",
        replArgs = ["repl"],
        replWorkingDir = projectDir,
        replStdinPath = dir </> "stdin.fifo",
        replStdoutPath = dir </> "stdout.md",
        replStderrPath = dir </> "stderr.md",
        replTokenPath = dir </> "write.token"
      }

-- | Open a cabal repl, wait for the initial prompt (discarding startup guff),
-- run the action, then 'replClose'.  Long initial sync timeout (3 min) so
-- cold builds of the target package can finish.
withCabalRepl :: FilePath -> String -> (Repl -> IO a) -> IO a
withCabalRepl projectDir session action = do
  cfg <- cabalReplConfig projectDir session
  bracket (replOpen cfg) replClose $ \r -> do
    -- Cold cabal repl can take a while (configure + load).
    m <- replSyncWith defaultPrompt 180_000_000 r
    case m of
      Nothing ->
        fail $
          "withCabalRepl: timed out waiting for initial prompt in "
            <> projectDir
            <> " (session "
            <> session
            <> ")"
      Just _ -> action r

-- | Read raw log content (empty if missing).
readLogContent :: FilePath -> IO Text
readLogContent fp = do
  exists <- doesFileExist fp
  if not exists
    then pure ""
    else TIO.readFile fp

-- | Split into complete (newline-terminated) lines and optional trailing partial.
splitComplete :: Text -> ([Text], Maybe Text)
splitComplete content
  | T.null content = ([], Nothing)
  | T.isSuffixOf "\n" content = (T.lines content, Nothing)
  | otherwise =
      let parts = T.splitOn "\n" content
       in case parts of
            [] -> ([], Nothing)
            _ -> (init parts, Just (last parts))

-- | Strip a leading @ghci> @ decoration fused onto an answer line.
stripGhciPrefix :: Text -> Text
stripGhciPrefix t
  | "ghci> " `T.isPrefixOf` t = T.drop 6 t
  | otherwise = t

-- ---------------------------------------------------------------------------
-- Circuit views
-- ---------------------------------------------------------------------------

-- | Read all new lines from the REPL as a 'Circuit'.
--
-- Composes with other 'Circuit (Kleisli IO)' fragments via '(>>>)'.
replRead :: Repl -> Trace t (Kleisli IO) () [Text]
replRead r = Arr $ Kleisli $ \() -> replEmit r

-- | Write one line to the REPL as a 'Trace'.
replWrite :: Repl -> Trace t (Kleisli IO) Text ()
replWrite r = Arr $ Kleisli $ replCommit r

-- | Write multiple lines to the REPL as a 'Trace'.
replWriteLines :: Repl -> Trace t (Kleisli IO) [Text] ()
replWriteLines r = Arr $ Kleisli $ mapM_ (replCommit r)

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
            replWorkingDir = dir,
            replTokenPath = "/tmp/repl-stdout.md.token"
          }
  r <- replOpen cfg
  -- consume the initial prompt / guff
  _ <- replSync r
  pure r

-- ---------------------------------------------------------------------------
-- Hermes agent helpers
-- ---------------------------------------------------------------------------

-- | Hermes prompt: the leading @❯@ character.
hermesPrompt :: Text -> Bool
hermesPrompt t = "❯" `T.isPrefixOf` T.stripStart t

-- | Send a prompt to a Hermes agent and return the clean response.
--
-- Commits the line, waits for the next @❯@ prompt, and filters
-- out ANSI escape sequences, status bars, and other guff.
hermesCommand :: Repl -> Text -> IO [Text]
hermesCommand r cmd = do
  replCommit r cmd
  mLines <- replSyncWith hermesPrompt 120000000 r -- 2 minute timeout
  pure $ case mLines of
    Nothing -> []
    Just ls -> filter (not . isHermesGuff) (takeWhile (not . hermesPrompt) ls)

-- | Heuristic for Hermes UI lines that aren't actual response content.
isHermesGuff :: Text -> Bool
isHermesGuff t =
  or
    [ "Warning:" `T.isPrefixOf` t,
      "╭─" `T.isPrefixOf` t,
      "╰─" `T.isPrefixOf` t,
      "│" `T.isPrefixOf` t,
      "Available Tools" `T.isInfixOf` t,
      "Available Skills" `T.isInfixOf` t,
      "Session:" `T.isPrefixOf` t,
      "Resume this session" `T.isPrefixOf` t,
      "⚕" `T.isPrefixOf` T.stripStart t,
      "✦ Tip:" `T.isPrefixOf` t,
      T.all isSpace t,
      T.null t
    ]

-- | Start a Hermes agent connected to a FIFO.
--
-- Spawns @hermes chat --quiet@, waits for it to finish printing
-- the startup banner and first prompt, and returns a 'Repl' handle
-- ready for 'hermesCommand'.
startAgent :: FilePath -> IO Repl
startAgent workDir = do
  let cfg =
        defaultReplConfig
          { replCommand = "hermes",
            replArgs = ["chat", "--quiet", "--max-turns", "50"],
            replWorkingDir = workDir,
            replStdinPath = "/tmp/agent-stdin",
            replStdoutPath = "/tmp/agent-stdout.md",
            replStderrPath = "/tmp/agent-stderr.md",
            replTokenPath = "/tmp/agent-stdout.md.token"
          }
  r <- replOpen cfg
  -- Consume startup guff: banner, tool list, welcome message, first prompt.
  _ <- replSyncWith hermesPrompt 60000000 r -- 60 second timeout
  pure r

-- TODO (open thread for Circuit.Agent integration):
-- We now have:
--   * Circuit.Repl  — FIFO-based process communication primitives
--   * Circuit.Comm  — multi-agent channel (shared FIFO+log, cursors)
--   * Circuit.Session — ask/answer protocol with blocking replies
--
-- What remains: integrate with the coinductive Agent pattern
-- (loom/circuit-agent.md).  An Agent is @Path -> (Text, Agent)@ —
-- a self-updating closure consuming an append-only log.  Session
-- provides the operational layer; Agent provides the structure for
-- agents that update their behavior based on conversation history.
--
-- The natural bridge: a 'sessionAgent' function that lifts a Session
-- into the Agent coinductive form, enabling agents that can engage
-- in multi-turn dialogue while maintaining internal state.
