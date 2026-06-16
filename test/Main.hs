{-# LANGUAGE OverloadedStrings #-}

module Main where

import Circuit.Repl
import Control.Concurrent (threadDelay)
import Control.Monad (when)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesFileExist, removeFile)
import System.IO (hPutStrLn, stderr)
import System.Process (terminateProcess)
import Test.Tasty
import Test.Tasty.HUnit

-- | Very basic smoke test that the Repl module can drive our mock.
-- This is the starting point for proper pipeline tests.
main :: IO ()
main =
  defaultMain $
    testGroup
      "circuits-io Repl pipeline (mock)"
      [ testCase "mock repl starts and responds to a simple query (no extra noise)" $ do
          let cfg =
                (baseCfg ["--prompt=mock> ", "--delay=20", "--no-extra-noise"])
                  { replStdinPath = "/tmp/circuits-io-mock-in-1",
                    replStdoutPath = "/tmp/circuits-io-mock-out-1.md",
                    replStderrPath = "/tmp/circuits-io-mock-err-1.md"
                  }

          cleanLogs cfg

          repl <- replOpen cfg
          threadDelay 500_000

          _ <- replSyncWith (T.isSuffixOf "mock> ") 5_000_000 repl -- consume welcome
          replCommit repl "hello"
          mResp <- replSyncWith (T.isSuffixOf "mock> ") 10_000_000 repl

          -- After consuming via sync, emit should see nothing new (tests the cursor logic)
          extra <- replEmit repl
          assertBool "emit after sync should be empty until next output" (null extra)

          replClose repl
          threadDelay 100_000

          case mResp of
            Nothing -> assertFailure "Timed out waiting for prompt from mock"
            Just lines -> do
              let combined = T.unlines lines
              assertBool "should contain our input echo" ("received: hello" `T.isInfixOf` combined)
              assertBool "should contain a response line" ("echo: hello" `T.isInfixOf` combined),
        testCase "multiple commands with extra noise still sync correctly" $ do
          let cfg =
                (baseCfg ["--prompt=mock> ", "--delay=15"])
                  { replStdinPath = "/tmp/circuits-io-mock-in-2",
                    replStdoutPath = "/tmp/circuits-io-mock-out-2.md",
                    replStderrPath = "/tmp/circuits-io-mock-err-2.md"
                  }

          cleanLogs cfg

          repl <- replOpen cfg
          threadDelay 500_000

          _ <- replSyncWith (T.isSuffixOf "mock> ") 5_000_000 repl

          -- first command
          replCommit repl "add 3"
          m1 <- replSyncWith (T.isSuffixOf "mock> ") 10_000_000 repl
          case m1 of
            Nothing -> assertFailure "timeout on first command"
            Just ls -> assertBool "first result has 3" ("result: 3" `T.isInfixOf` T.unlines ls)

          -- second command, using state
          replCommit repl "get"
          m2 <- replSyncWith (T.isSuffixOf "mock> ") 10_000_000 repl
          case m2 of
            Nothing -> assertFailure "timeout on second command"
            Just ls -> do
              let combined = T.unlines ls
              assertBool "second should see updated counter" ("counter: 1" `T.isInfixOf` combined || "counter: 2" `T.isInfixOf` combined) -- depending on counting
          replClose repl
          threadDelay 100_000,
        testCase "hanging prompt (no trailing newline) is still detected via improved readLines" $ do
          let cfg =
                (baseCfg ["--prompt=mock-hang> ", "--delay=10", "--hanging-prompt", "--no-extra-noise"])
                  { replStdinPath = "/tmp/circuits-io-mock-in-3",
                    replStdoutPath = "/tmp/circuits-io-mock-out-3.md",
                    replStderrPath = "/tmp/circuits-io-mock-err-3.md"
                  }

          cleanLogs cfg

          repl <- replOpen cfg
          threadDelay 500_000

          _ <- replSyncWith (T.isInfixOf "mock-hang>") 5_000_000 repl -- use infix because hanging may append
          replCommit repl "hello"
          mResp <- replSyncWith (T.isInfixOf "mock-hang>") 10_000_000 repl

          replClose repl
          threadDelay 100_000

          case mResp of
            Nothing -> assertFailure "timeout on hanging prompt test"
            Just lines -> do
              let combined = T.unlines lines
              assertBool "response captured even with hanging prompt" ("echo: hello" `T.isInfixOf` combined)
      ]
  where
    baseCfg args =
      ReplConfig
        { replCommand = "./dist-newstyle/build/aarch64-osx/ghc-9.14.1/circuits-io-0.1.0.0/x/mock-repl/build/mock-repl/mock-repl",
          replArgs = args,
          replStdinPath = "/tmp/circuits-io-mock-in",
          replStdoutPath = "/tmp/circuits-io-mock-out.md",
          replStderrPath = "/tmp/circuits-io-mock-err.md",
          replWorkingDir = "."
        }

    cleanLogs cfg =
      mapM_
        (\p -> whenM (doesFileExist p) (removeFile p))
        [replStdinPath cfg, replStdoutPath cfg, replStderrPath cfg]
        -- also remove the fifo itself so mkfifo in next test doesn't fail
        >> whenM (doesFileExist (replStdinPath cfg)) (removeFile (replStdinPath cfg))

whenM :: (Monad m) => m Bool -> m () -> m ()
whenM mb action = do
  b <- mb
  when b action
