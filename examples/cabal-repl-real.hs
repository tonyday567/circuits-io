{-# LANGUAGE OverloadedStrings #-}

-- | Real cabal-repl oracle for Circuit.Repl A+B+C.
--
-- Opens @cabal repl@ on @~/haskell/cursor@ via 'withCabalRepl', runs
-- @:t id@ and @1+1@ through 'replEval', then attaches a second client and
-- shows write-token claim rejection while the first holds the token.
--
-- State under @$HOME/mg/logs/process-harness/cursor-io-real/@.
--
-- @
--   cabal run cabal-repl-real
-- @
module Main (main) where

import Circuit.Repl
import Control.Monad (unless, when)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Environment (getEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  home <- getEnv "HOME"
  let project = home </> "haskell" </> "cursor"
      session = "cursor-io-real"

  hPutStrLn stderr "=== circuits-io cabal-repl-real (cursor project) ==="
  hPutStrLn stderr $ "project=" <> project
  hPutStrLn stderr $ "session=" <> session

  withCabalRepl project session $ \owner -> do
    hPutStrLn stderr "-- eval :t id (alice) --"
    mType <- replEval owner "alice" ":t id"
    case mType of
      Nothing -> failMsg "eval :t id failed (claim or timeout)"
      Just ls -> do
        mapM_ TIO.putStrLn ls
        unless (any ("id ::" `T.isInfixOf`) ls) $
          failMsg "expected 'id ::' in :t id response"

    hPutStrLn stderr "-- eval 1+1 (alice) --"
    mSum <- replEval owner "alice" "1+1"
    case mSum of
      Nothing -> failMsg "eval 1+1 failed"
      Just ls -> do
        mapM_ TIO.putStrLn ls
        unless (any ("2" ==) (map T.strip ls) || any ("2" `T.isInfixOf`) ls) $
          failMsg "expected '2' in 1+1 response"

    hPutStrLn stderr "-- attach bob + claim conflict --"
    let cfg = replGetConfig owner
    bob <- replAttach cfg
    okAlice <- replClaim owner "alice"
    unless okAlice $ failMsg "alice should claim"
    okBob <- replClaim bob "bob"
    when okBob $ failMsg "bob should be rejected while alice holds token"
    hPutStrLn stderr "bob claim rejected (good)"

    replRelease owner "alice"
    okBob2 <- replClaim bob "bob"
    unless okBob2 $ failMsg "bob should claim after alice release"
    hPutStrLn stderr "bob claim after release (good)"
    replRelease bob "bob"

    hPutStrLn stderr "=== all checks passed ==="

failMsg :: String -> IO a
failMsg msg = do
  hPutStrLn stderr $ "FAIL: " <> msg
  exitFailure
