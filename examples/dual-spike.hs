{-# LANGUAGE OverloadedStrings #-}

-- | Spike: free dual ends, then one explicit turn.
--
-- Proves the clean 'Circuit.Repl' surface is enough:
--
--   1. emit-only  — harvest without committing
--   2. commit-only — inject without reading
--   3. free emit after (2) — independence (no request–response in the type)
--   4. turn        — local circuit that /ties/ commit to emit-until-boundary
--                    (timeout lives only here)
--   5. attach      — second cursor, free fan-out read
--
-- Targets (argv):
--
--   dual-spike              mock-repl over FIFO  (default, deterministic)
--   dual-spike python       python3 -q over PTY  (real process, clear >>>)
--
-- Not hermes yet: chrome is noisy; prove the dual first, then swap Config.
--
-- @
--   cabal run dual-spike
--   cabal run dual-spike -- python
-- @
module Main (main) where

import Circuit.Repl
import Control.Concurrent (threadDelay)
import Control.Monad (unless, when)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.Environment (getArgs, getEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (hFlush, hPutStrLn, stderr)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["python"] -> runPython
    [] -> runMock
    _ -> do
      hPutStrLn stderr "usage: dual-spike | dual-spike python"
      exitFailure

-- ---------------------------------------------------------------------------
-- Target: mock-repl (FIFO)
-- ---------------------------------------------------------------------------

runMock :: IO ()
runMock = do
  hPutStrLn stderr "=== dual-spike: mock-repl (FIFO) ==="
  let mockBin =
        "./dist-newstyle/build/aarch64-osx/ghc-9.14.1/circuits-io-0.1.0.0/x/mock-repl/build/mock-repl/mock-repl"
  ok <- doesFileExist mockBin
  unless ok $ failMsg $ "mock-repl not built; cabal build exe:mock-repl first\n  looked for: " <> mockBin

  let cfg =
        defaultReplConfig
          { replCommand = mockBin,
            replArgs = ["--prompt=mock> ", "--delay=15", "--no-extra-noise"],
            replStdinPath = "/tmp/dual-spike-mock-in",
            replStdoutPath = "/tmp/dual-spike-mock-out.md",
            replStderrPath = "/tmp/dual-spike-mock-err.md",
            replWorkingDir = "."
          }
  mapM_ removeIfExists
    [ replStdinPath cfg,
      replStdoutPath cfg,
      replStderrPath cfg,
      replStdoutPath cfg <> ".cursor"
    ]

  r <- replOpen cfg
  threadDelay 300_000
  spike
    r
    cfg
    (T.isSuffixOf "mock> ")
    [ ("hello", "echo: hello"),
      ("get", "counter:") -- stateful; free dual doesn't care
    ]
  replClose r
  hPutStrLn stderr "=== mock PASS ==="

-- ---------------------------------------------------------------------------
-- Target: python3 -q (PTY)
-- ---------------------------------------------------------------------------

runPython :: IO ()
runPython = do
  hPutStrLn stderr "=== dual-spike: python3 -q (PTY) ==="
  home <- getEnv "HOME"
  let dir = home </> "mg" </> "logs" </> "process-harness" </> "dual-spike-python"
  createDirectoryIfMissing True dir
  let cfg =
        defaultReplConfig
          { replCommand = "python3",
            replArgs = ["-q"],
            replWorkingDir = ".",
            replStdinPath = dir </> "stdin.fifo",
            replStdoutPath = dir </> "stdout.md",
            replStderrPath = dir </> "stderr.md"
          }
  writeFile (replStdoutPath cfg) ""

  r <- replOpenPty cfg
  spike
    r
    cfg
    (\t -> ">>>" `T.isSuffixOf` T.stripEnd t)
    [ ("1+1", "2"),
      ("print('ok')", "ok")
    ]
  replClose r
  hPutStrLn stderr "=== python PASS ==="

-- ---------------------------------------------------------------------------
-- Spike body (same for every target)
-- ---------------------------------------------------------------------------

spike :: Repl -> ReplConfig -> (Text -> Bool) -> [(Text, Text)] -> IO ()
spike r cfg isBoundary cmds = do
  let (_write, _emit) = endsRepl r
  step "0 endsRepl" "Commit + Emit wires in hand (Queue dual shape)"

  -- 1. free emit only — no commit
  step "1 emit-only" "harvest whatever the agent already printed"
  startup <- emitUntil isBoundary 15_000_000 r
  case startup of
    Nothing -> failMsg "phase 1: timed out waiting for initial boundary (local tie)"
    Just ls -> do
      showLines "startup" ls
      pass "emit-only saw a boundary without committing"

  -- 2. free commit only — no read
  let (cmd1, expect1) = head cmds
  step "2 commit-only" $ "inject " <> T.unpack (T.pack (show cmd1)) <> " without reading"
  replCommit r cmd1
  pass "commit returned immediately (no wait baked into Repl)"

  -- 3. free emit after — proves independence via the shared log
  step "3 free emit after commit" "poll until boundary; timeout only on this runner circuit"
  m1 <- emitUntil isBoundary 15_000_000 r
  case m1 of
    Nothing -> failMsg "phase 3: timed out (runner tie failed)"
    Just ls -> do
      showLines "after-commit" ls
      unless (any (expect1 `T.isInfixOf`) ls) $
        failMsg $ "phase 3: expected substring " <> T.unpack expect1
      pass "emit harvested commit result without Repl knowing about turns"

  -- 4. explicit turn — same as 2+3, named as the tied circuit
  when (length cmds >= 2) $ do
    let (cmd2, expect2) = cmds !! 1
    step "4 turn" "local turn = commit ; emitUntil boundary timeout"
    m2 <- turn isBoundary 15_000_000 r cmd2
    case m2 of
      Nothing -> failMsg "phase 4: turn timed out"
      Just ls -> do
        showLines "turn" ls
        unless (any (expect2 `T.isInfixOf`) ls) $
          failMsg $ "phase 4: expected substring " <> T.unpack expect2
        pass "turn is a named runner circuit; clock is visible"

  -- 5. attach — second free reader (own cursor on the same log)
  step "5 attach" "second cursor; free fan-out emit"
  bob <- replAttach cfg
  -- Attach seeks past complete lines. A hanging partial prompt may still
  -- surface once (emit's partial-line rule) — drain it; that is not history.
  drain <- replEmit bob
  when (not (null drain)) $
    showLines "attach-drain-partial" drain
  let (cmdFan, expectFan) = head cmds
  replCommit r cmdFan
  mBob <- emitUntil isBoundary 15_000_000 bob
  case mBob of
    Nothing -> failMsg "phase 5: attach reader never saw boundary"
    Just ls -> do
      showLines "attach" ls
      unless (any (expectFan `T.isInfixOf`) ls) $
        failMsg "phase 5: attach missed response"
      pass "attach is free multi-reader emit; no second process"

  pure ()

-- | Local tied circuit: commit then emit until boundary or timeout (µs).
-- Lives in the spike, not in Circuit.Repl.
turn :: (Text -> Bool) -> Int -> Repl -> Text -> IO (Maybe [Text])
turn isBoundary timeoutUs r cmd = do
  replCommit r cmd
  emitUntil isBoundary timeoutUs r

-- | Poll free emit until a line satisfies the boundary, or timeout (µs).
emitUntil :: (Text -> Bool) -> Int -> Repl -> IO (Maybe [Text])
emitUntil isBoundary timeoutUs r = go 0 [] 10000
  where
    go elapsed acc delay = do
      news <- replEmit r
      let acc' = acc <> news
      if any isBoundary news
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
-- Reporting
-- ---------------------------------------------------------------------------

step :: String -> String -> IO ()
step tag msg = do
  hPutStrLn stderr $ "-- " <> tag <> ": " <> msg
  hFlush stderr

pass :: String -> IO ()
pass msg = hPutStrLn stderr $ "   OK  " <> msg

showLines :: String -> [Text] -> IO ()
showLines label ls = do
  hPutStrLn stderr $ "   [" <> label <> "] " <> show (length ls) <> " lines"
  mapM_ (\t -> TIO.hPutStrLn stderr ("      | " <> t)) (take 12 ls)
  when (length ls > 12) $ hPutStrLn stderr "      | ..."

failMsg :: String -> IO a
failMsg msg = do
  hPutStrLn stderr $ "FAIL: " <> msg
  exitFailure

removeIfExists :: FilePath -> IO ()
removeIfExists p = do
  e <- doesFileExist p
  when e (removeFile p)
