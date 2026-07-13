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
    replOpenInject,
    replOpenPty,
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

    -- * Hermes / agent conveniences
    AgentConfig (..),
    defaultHermesConfig,
    agentReplConfig,
    startAgent,
    startAgentPty,
    startPythonPty,
    hermesPrompt,
    hermesCommand,
    hermesEval,

    -- * Hermes one-shot path (no PTY / no TUI)
    hermesOneShot,
    hermesEvalOneShot,
    hermesExtractResponse,
    hermesSessionId,
  )
where

import Circuit (Trace (..))
import Control.Arrow (Kleisli (..))
import Control.Concurrent (ThreadId, forkIO, killThread, threadDelay)
import Control.Exception (IOException, bracket, try)
import Control.Monad (forever, unless, void, when)
import Cursor qualified as Cur
import Data.ByteString qualified as BS
import Data.Char (isSpace)
import Data.Foldable (for_)
import Data.IORef
import Data.List (find)
import Data.Maybe (isJust, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Text.IO qualified as TIO
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.Environment (getEnv)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO
import System.Posix.Process (getProcessID)
import System.Posix.Pty
  ( Pty,
    closePty,
    spawnWithPty,
    tryReadPty,
    writePty,
  )
import System.Process
import System.Timeout (timeout)
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

-- | Transport backend.  Sum type (not a typeclass) until a third mode appears.
--
--   * 'BackendFifo' — child writes log via redirected fds; commit opens write-end.
--   * 'BackendPty'  — parent pumps master reads into log; commit uses 'writePty'.
--   * 'BackendInject' — tests / fakes: commit is a pure IO action (no OS process).
data Backend
  = BackendFifo
      { beFifo :: FilePath,
        beFifoPh :: Maybe ProcessHandle
      }
  | BackendPty
      { bePty :: Pty,
        bePtyPh :: ProcessHandle,
        bePump :: ThreadId
      }
  | BackendInject
      { beInject :: Text -> IO ()
      }

-- | A live REPL session.
--
-- Shared across backends: log paths (in 'ReplConfig'), 'Cur.Cursor', claim
-- token, prompt sync.  Transport is 'Backend' only.
data Repl = Repl
  { replConfig :: ReplConfig,
    replBackend :: Backend,
    replCursor :: Cur.Cursor,
    -- | Last trailing partial line we already surfaced (hanging prompt).
    replLastPartial :: IORef (Maybe Text)
  }

-- | Config used to open / attach this handle.
replGetConfig :: Repl -> ReplConfig
replGetConfig = replConfig

-- | Build a 'Repl' over an existing log + backend (shared constructor).
mkRepl :: ReplConfig -> Backend -> Cur.Cursor -> IO Repl
mkRepl cfg backend cursor = do
  lastP <- newIORef Nothing
  pure $ Repl cfg backend cursor lastP

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
  mkRepl cfg (BackendFifo (replStdinPath cfg) (Just ph)) cursor

-- | Attach to an already-running REPL (same FIFO/log paths). Does not own
-- process lifetime. Cursor starts at log tail. Commit still writes the FIFO.
replAttach :: ReplConfig -> IO Repl
replAttach cfg = do
  content <- readLogContent (replStdoutPath cfg)
  let (complete, _) = splitComplete content
  path <- attachCursorPath cfg
  cursor <- Cur.newFile path
  Cur.seekEnd cursor complete
  mkRepl cfg (BackendFifo (replStdinPath cfg) Nothing) cursor

-- | Open a log-only 'Repl' whose 'replCommit' is a pure inject action.
-- Used by dual-mode backend mocks (FakeFifo / FakePty) with no OS process.
replOpenInject :: ReplConfig -> (Text -> IO ()) -> IO Repl
replOpenInject cfg inject = do
  appendFile (replStdoutPath cfg) ""
  cursor <- Cur.newFile (ownerCursorPath cfg)
  Cur.set cursor 0
  mkRepl cfg (BackendInject inject) cursor

-- | Open a process connected via PTY. Parent pumps master → stdout log.
-- State files still follow 'ReplConfig' paths (session dir).
replOpenPty :: ReplConfig -> IO Repl
replOpenPty cfg = do
  createDirectoryIfMissing True (takeDirectory (replStdoutPath cfg))
  appendFile (replStdoutPath cfg) ""
  (pty, ph) <-
    spawnWithPty
      Nothing
      True
      (replCommand cfg)
      (replArgs cfg)
      (100, 30)
  pumpTid <- forkIO (pumpPtyToLog pty (replStdoutPath cfg))
  cursor <- Cur.newFile (ownerCursorPath cfg)
  Cur.set cursor 0
  mkRepl cfg (BackendPty pty ph pumpTid) cursor

-- | Pump PTY master reads into the append-only log (byte chunks).
pumpPtyToLog :: Pty -> FilePath -> IO ()
pumpPtyToLog pty logPath = go
  where
    go = do
      r <- try @IOException (tryReadPty pty)
      case r of
        Left _ -> pure ()
        Right (Left _) -> go
        Right (Right bs)
          | BS.null bs -> go
          | otherwise -> BS.appendFile logPath bs >> go

-- | Close a REPL session (backend-specific teardown; must not hang).
replClose :: Repl -> IO ()
replClose r = case replBackend r of
  BackendFifo {beFifoPh} -> for_ beFifoPh terminateProcess
  BackendPty {bePty, bePtyPh, bePump} -> do
    void $ try @IOException (terminateProcess bePtyPh)
    void $
      timeout 500_000 $ do
        void $ try @IOException (closePty bePty)
        killThread bePump
  BackendInject {} -> pure ()

-- ---------------------------------------------------------------------------
-- Primitives
-- ---------------------------------------------------------------------------

-- | Send one line to the REPL (backend-dispatched).
replCommit :: Repl -> Text -> IO ()
replCommit r t = case replBackend r of
  BackendFifo {beFifo} ->
    withFile beFifo WriteMode $ \h -> do
      TIO.hPutStrLn h t
      hFlush h
  BackendPty {bePty} ->
    writePty bePty (encodeUtf8 (t <> "\n"))
  BackendInject {beInject} ->
    beInject t

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

-- | Strip ANSI escape sequences and carriage returns from a line so
-- prompt/content detection works on Hermes/grok TUI output.
--
-- Handles CSI sequences (ESC [ ... final-byte), including cursor-shape
-- sequences such as @CSI 2 SP q@, plus standalone OSC / two-character
-- escapes.
stripAnsi :: Text -> Text
stripAnsi = T.pack . go . T.unpack
  where
    go [] = []
    go ('\ESC' : '[' : rest) = go (dropCsi rest)
    go ('\ESC' : ']' : rest) = go (dropOsc rest)
    go ('\ESC' : '(' : _ : rest) = go rest
    go ('\ESC' : ')' : _ : rest) = go rest
    go ('\ESC' : '*' : _ : rest) = go rest
    go ('\ESC' : '+' : _ : rest) = go rest
    go ('\ESC' : '-' : _ : rest) = go rest
    go ('\ESC' : '.' : _ : rest) = go rest
    go ('\ESC' : '/' : _ : rest) = go rest
    go ('\ESC' : _ : rest) = go rest
    go ('\r' : rest) = go rest
    go (c : rest) = c : go rest

    -- CSI: parameter bytes (0x30-0x3F), then intermediate bytes (0x20-0x2F),
    -- then final byte (0x40-0x7E).  Cursor shape @CSI Ps SP q@ is included
    -- because space is an intermediate byte and q is a final byte.
    dropCsi xs =
      let params = dropWhile isParam xs
          inters = dropWhile isInter params
       in case inters of
            [] -> []
            (_ : ys) -> ys
    isParam c = c >= '\x30' && c <= '\x3f'
    isInter c = c >= '\x20' && c <= '\x2f'

    -- OSC: BEL terminates; otherwise ST (ESC \\) terminates.
    dropOsc xs = case break (`elem` ['\x07', '\ESC']) xs of
      (_, '\x07' : ys) -> ys
      (_, '\ESC' : '\\' : ys) -> ys
      (_, '\ESC' : _ : ys) -> ys
      _ -> []

-- | Hermes prompt detection (classic @--cli@ REPL and residual TUI chrome).
--
-- After ANSI/CR strip, a prompt line is one that:
--
--   * starts with @❯@ (observed on @hermes chat --cli@ prompt_toolkit UI), or
--   * is a short line ending in @>@ (fallback classic REPL shapes).
hermesPrompt :: Text -> Bool
hermesPrompt t =
  let s = T.strip (stripAnsi t)
   in or
        [ "❯" `T.isPrefixOf` s
        , T.length s <= 8 && ">" `T.isSuffixOf` s && not ("->" `T.isInfixOf` s)
        ]

-- | Clean Hermes response lines: strip ANSI, drop trailing prompts, prefer
-- the last response box, else guff-filter.
--
-- Hermes --cli redraws the status bar continuously and may emit intermediate
-- prompt-shaped lines.  The actual response is always drawn inside the last
-- @╭─ ⚕ Hermes ... ╰─ ... ╯@ box before the final prompt, so we extract that
-- box rather than relying on prompt position.
cleanHermesResponse :: [Text] -> [Text]
cleanHermesResponse ls =
  let clean = map stripAnsi ls
      -- Drop trailing prompt lines so the response box (which precedes the
      -- prompt) remains at the end.
      noTrailingPrompt = reverse (dropWhile hermesPrompt (reverse clean))
      boxed = extractHermesBox noTrailingPrompt
   in if null boxed
        then filter (not . isHermesGuff) noTrailingPrompt
        else boxed

-- | Send a prompt to a Hermes agent and return the clean response (no claim).
--
-- Commits the line, waits for the next Hermes prompt, strips ANSI, and
-- extracts the content between response box markers when present.
hermesCommand :: Repl -> Text -> IO [Text]
hermesCommand r cmd = do
  _ <- replEmit r -- drain
  replCommit r cmd
  threadDelay 100_000
  mLines <- replSyncWith hermesPrompt 120_000_000 r -- 2 minute timeout
  extra <- replEmit r
  pure $ case mLines of
    Nothing -> []
    Just ls -> cleanHermesResponse (ls <> extra)

-- | Multi-turn Hermes eval with write-token claim (preferred agent path).
--
-- @
--   r <- startAgentPty (defaultHermesConfig "sess")
--   Just a <- hermesEval r "alice" "hello"
--   Just b <- hermesEval r "alice" "what did I just say?"
-- @
hermesEval :: Repl -> String -> Text -> IO (Maybe [Text])
hermesEval r name cmd = do
  ok <- replClaim r name
  if not ok
    then pure Nothing
    else do
      out <- hermesCommand r cmd
      replRelease r name
      pure (Just out)

-- | Extract the Hermes session id from program output.
--
-- Looks for the line @Session: <id>@ emitted at the end of a @hermes chat -q@
-- run.
hermesSessionId :: Text -> Maybe Text
hermesSessionId txt =
  listToMaybe
    [ sid
      | line <- T.lines txt,
        let s = T.stripStart line,
        "Session:" `T.isPrefixOf` s,
        let rest = T.drop 8 (T.stripStart s),
        let sid = T.stripStart rest,
        not (T.null sid)
    ]

-- | Extract response content from clean Hermes one-shot stdout.
--
-- Works on the plain-text box drawn by @hermes chat -q@ (no ANSI because no
-- PTY).  Returns the non-guff lines inside the last @╭─ ⚕ Hermes ... ╰─ ... ╯@
-- box.
hermesExtractResponse :: Text -> [Text]
hermesExtractResponse = extractHermesBox . T.lines . T.filter (/= '\r')

-- | Run Hermes in one-shot mode for a single query.
--
-- Spawns @hermes chat [--resume SESS] -q QUERY@, captures stdout/stderr, and
-- returns the response lines plus the new session id.  The session id can be
-- passed back in on the next turn to preserve conversation context.
--
-- This is the recommended agent path: no PTY, no TUI redraw, no ANSI parsing.
--
-- @
--   Right (resp1, sid1) <- hermesOneShot Nothing "remember banana"
--   Right (resp2, _  ) <- hermesOneShot (Just sid1) "what did I remember?"
-- @
hermesOneShot :: Maybe Text -> Text -> IO (Either Text ([Text], Text))
hermesOneShot mSession query = do
  let resumeArgs = maybe [] (\s -> ["--resume", T.unpack s]) mSession
      args = ["chat"] ++ resumeArgs ++ ["-q", T.unpack query]
  (ec, out, err) <- readProcessWithExitCode "hermes" args ""
  let output = T.pack out <> T.pack err
  case ec of
    ExitFailure _ -> pure (Left output)
    ExitSuccess ->
      case hermesSessionId output of
        Nothing -> pure (Left "hermesOneShot: no Session: line in output")
        Just sid -> pure (Right (hermesExtractResponse output, sid))

-- | Stateful wrapper around 'hermesOneShot' for multi-turn conversation.
--
-- Keeps the current Hermes session id in an 'IORef'.  Returns 'Nothing' on a
-- process or parsing failure.
hermesEvalOneShot :: IORef (Maybe Text) -> Text -> IO (Maybe [Text])
hermesEvalOneShot ref query = do
  mSession <- readIORef ref
  result <- hermesOneShot mSession query
  case result of
    Left err -> do
      TIO.hPutStrLn stderr ("hermesEvalOneShot failed: " <> err)
      pure Nothing
    Right (resp, sid) -> do
      writeIORef ref (Just sid)
      pure (Just resp)

-- | Extract lines inside the last Hermes response box.
--
-- Hermes draws responses as:
--
-- @
--   ╭─ ⚕ Hermes ── ...
--     response line 1
--     response line 2
--   ╰──────────────── ...
-- @
--
-- We take the /last/ such box in the output to survive intermediate redraws
-- and status bars.  Returns lines strictly between the markers, with leading
-- whitespace/box-drawing prefix stripped.
extractHermesBox :: [Text] -> [Text]
extractHermesBox ls =
  case findLastBox of
    Nothing -> []
    Just (start, end) ->
      filter (not . isHermesGuff) $
        map T.strip (take (end - start - 1) (drop (start + 1) ls))
  where
    indexed = zip [0 ..] ls
    -- Use infix matching because cursor-positioning ANSI fragments can leave
    -- box-drawing prefix characters before the marker after stripping.
    closes = [i | (i, x) <- indexed, "╰─" `T.isInfixOf` x]
    opens = [i | (i, x) <- indexed, "╭─ ⚕ Hermes" `T.isInfixOf` x]
    findLastBox =
      listToMaybe
        [ (open, close)
          | close <- reverse closes,
            open <- reverse opens,
            open < close
        ]

-- | Heuristic for Hermes UI lines that aren't actual response content.
-- Operates on ANSI-stripped text.
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
      "synthesizing..." `T.isInfixOf` t,
      "Initializing agent..." `T.isInfixOf` t,
      -- separator / spinner noise
      "─" `T.count` t >= 20,
      -- progress / status bars: contain box-drawing and timing symbols
      ("│" `T.isInfixOf` t && ("%" `T.isInfixOf` t || "⏱" `T.isInfixOf` t)),
      T.all isSpace t,
      T.null t
    ]

-- | Start a Hermes agent connected to a FIFO (legacy).
--
-- Prefer 'startAgentPty' with 'defaultHermesConfig' (@hermes chat --cli@).
startAgent :: FilePath -> IO Repl
startAgent workDir = do
  let cfg =
        defaultReplConfig
          { replCommand = "hermes",
            replArgs = ["chat", "--cli", "--max-turns", "50"],
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

-- | Agent-start proof path: @python3 -q@ over PTY (no ANSI filter yet).
-- Session files under @$HOME/mg/logs/process-harness/<session>/@.
startPythonPty :: String -> IO Repl
startPythonPty session = do
  home <- getEnv "HOME"
  let dir = home </> "mg" </> "logs" </> "process-harness" </> session
  createDirectoryIfMissing True dir
  let cfg =
        defaultReplConfig
          { replCommand = "python3",
            replArgs = ["-q"],
            replWorkingDir = ".",
            replStdinPath = dir </> "stdin.fifo", -- unused for PTY
            replStdoutPath = dir </> "stdout.md",
            replStderrPath = dir </> "stderr.md",
            replTokenPath = dir </> "write.token"
          }
  writeFile (replStdoutPath cfg) ""
  r <- replOpenPty cfg
  m <- replSyncWith (\t -> ">>>" `T.isSuffixOf` T.stripEnd t) 15_000_000 r
  case m of
    Nothing -> fail "startPythonPty: timed out waiting for >>>"
    Just _ -> pure r

-- ---------------------------------------------------------------------------
-- Agent configuration and PTY agent start
-- ---------------------------------------------------------------------------

-- | Configuration for spawning an agent CLI over PTY.
data AgentConfig = AgentConfig
  { -- | Executable name (e.g. @"hermes"@).
    agentCommand :: String,
    -- | Arguments (e.g. @["chat", "--quiet", "--max-turns", "50"]@).
    agentArgs :: [String],
    -- | Session name, used for state directory under
    -- @~/mg/logs/process-harness/<session>/@.
    agentSession :: String,
    -- | Working directory for the agent process.
    agentWorkingDir :: FilePath
  }
  deriving (Show, Eq)

-- | Sensible defaults for a Hermes agent session over classic @--cli@ REPL.
--
-- Spawns @hermes chat --cli@ (prompt_toolkit classic interface, real
-- stdin/stdout) — not TUI, not oneshot @-z@/@-q@.  The harness provides
-- the terminal via 'BackendPty'.
defaultHermesConfig :: String -> AgentConfig
defaultHermesConfig session =
  AgentConfig
    { agentCommand = "hermes",
      agentArgs = ["chat", "--cli", "--max-turns", "50"],
      agentSession = session,
      agentWorkingDir = "."
    }

-- | Build a 'ReplConfig' for an agent from 'AgentConfig'.
agentReplConfig :: AgentConfig -> IO ReplConfig
agentReplConfig cfg = do
  home <- getEnv "HOME"
  let dir = home </> "mg" </> "logs" </> "process-harness" </> agentSession cfg
  createDirectoryIfMissing True dir
  pure
    defaultReplConfig
      { replCommand = agentCommand cfg,
        replArgs = agentArgs cfg,
        replWorkingDir = agentWorkingDir cfg,
        replStdinPath = dir </> "stdin.fifo", -- unused for PTY
        replStdoutPath = dir </> "stdout.md",
        replStderrPath = dir </> "stderr.md",
        replTokenPath = dir </> "write.token"
      }

-- | Start an agent CLI connected via PTY (preferred multi-turn agent path).
--
-- Spawns the configured command on a pseudo-terminal, pumps output into
-- the session log, and waits for the agent's prompt.  For Hermes, use
-- 'defaultHermesConfig' (@hermes chat --cli@) and 'hermesEval' for
-- claim-scoped multi-turn turns.
startAgentPty :: AgentConfig -> IO Repl
startAgentPty cfg = do
  cfg' <- agentReplConfig cfg
  writeFile (replStdoutPath cfg') ""
  r <- replOpenPty cfg'
  m <- replSyncWith hermesPrompt 120_000_000 r -- 2 minute startup timeout
  case m of
    Nothing ->
      fail $
        "startAgentPty: timed out waiting for agent prompt (session "
          <> agentSession cfg
          <> "). Expected classic --cli prompt (❯). Check log: "
          <> replStdoutPath cfg'
    Just _ -> pure r

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
