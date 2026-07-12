{-# LANGUAGE OverloadedStrings #-}

module Main where

import Circuit.Comm
import Circuit.Repl
import Circuit.Session
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Monad (forM_, when)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesFileExist, removeFile)
import System.IO (hPutStrLn, stderr)
import System.Process (terminateProcess)
import Test.Tasty
import Test.Tasty.HUnit

main :: IO ()
main =
  defaultMain $
    testGroup
      "circuits-io"
      [ replTests,
        channelTests,
        sessionTests
      ]

-- ---------------------------------------------------------------------------
-- Repl pipeline tests (mock)
-- ---------------------------------------------------------------------------

replTests :: TestTree
replTests =
  testGroup
    "Repl pipeline (mock)"
    [ testCase "mock repl starts and responds to a simple query (no extra noise)" $ do
        let cfg =
              (baseCfg ["--prompt=mock> ", "--delay=20", "--no-extra-noise"])
                { replStdinPath = "/tmp/circuits-io-mock-in-1",
                  replStdoutPath = "/tmp/circuits-io-mock-out-1.md",
                  replStderrPath = "/tmp/circuits-io-mock-err-1.md",
                  replTokenPath = "/tmp/circuits-io-mock-out-1.md.token"
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
                  replStderrPath = "/tmp/circuits-io-mock-err-2.md",
                  replTokenPath = "/tmp/circuits-io-mock-out-2.md.token"
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
                  replStderrPath = "/tmp/circuits-io-mock-err-3.md",
                  replTokenPath = "/tmp/circuits-io-mock-out-3.md.token"
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
            assertBool "response captured even with hanging prompt" ("echo: hello" `T.isInfixOf` combined),
      testCase "write token: second claim rejected until release" $ do
        let cfg =
              (baseCfg ["--prompt=mock> ", "--delay=10", "--no-extra-noise"])
                { replStdinPath = "/tmp/circuits-io-mock-in-claim",
                  replStdoutPath = "/tmp/circuits-io-mock-out-claim.md",
                  replStderrPath = "/tmp/circuits-io-mock-err-claim.md",
                  replTokenPath = "/tmp/circuits-io-mock-out-claim.md.token"
                }
        cleanLogs cfg
        owner <- replOpen cfg
        threadDelay 400_000
        _ <- replSyncWith (T.isSuffixOf "mock> ") 5_000_000 owner
        attacher <-
          replAttach
            cfg
              { replStdinPath = replStdinPath cfg -- same session paths
              }

        okA <- replClaim owner "alice"
        assertBool "alice claims" okA
        okB <- replClaim attacher "bob"
        assertBool "bob rejected while alice holds" (not okB)

        m <- replEval owner "alice" "hello"
        case m of
          Nothing -> assertFailure "alice eval failed"
          Just ls -> assertBool "eval echo" ("echo: hello" `T.isInfixOf` T.unlines ls)

        -- after eval, token released
        okB2 <- replClaim attacher "bob"
        assertBool "bob claims after alice eval" okB2
        replRelease attacher "bob"

        replClose owner
        threadDelay 100_000
    ]
  where
    baseCfg args =
      ReplConfig
        { replCommand = "./dist-newstyle/build/aarch64-osx/ghc-9.14.1/circuits-io-0.1.0.0/x/mock-repl/build/mock-repl/mock-repl",
          replArgs = args,
          replStdinPath = "/tmp/circuits-io-mock-in",
          replStdoutPath = "/tmp/circuits-io-mock-out.md",
          replStderrPath = "/tmp/circuits-io-mock-err.md",
          replWorkingDir = ".",
          replTokenPath = "/tmp/circuits-io-mock-out.md.token"
        }

    cleanLogs cfg =
      mapM_
        (\p -> whenM (doesFileExist p) (removeFile p))
        [ replStdinPath cfg,
          replStdoutPath cfg,
          replStderrPath cfg,
          replStdoutPath cfg <> ".cursor",
          replTokenPath cfg
        ]

-- ---------------------------------------------------------------------------
-- Channel tests (multi-agent comms using cat bus)
-- ---------------------------------------------------------------------------

channelTests :: TestTree
channelTests =
  testGroup
    "Channel (multi-agent comms)"
    [ testCase "framing roundtrip" $ do
        let name = "test-agent"
        let body = "hello world"
        assertEqual
          "roundtrip"
          (Just (name, body))
          (parseMessage (frameMessage name body)),
      testCase "parseMessage rejects unframed text" $ do
        assertBool "unframed" (isNothing (parseMessage "hello world")),
      testCase "parseMessage rejects empty sender" $ do
        assertBool "empty sender" (isNothing (parseMessage "[] body")),
      testCase "parseMessage rejects empty body after bracket" $ do
        assertBool "empty body" (isNothing (parseMessage "[agent] ")),
      testCase "parseMessage handles bracket in body" $ do
        assertEqual
          "bracket in body"
          (Just ("agent", "[nested] text"))
          (parseMessage "[agent] [nested] text"),
      testCase "single-agent send and recv with cat bus" $ do
        let cfg = mkChCfg "agent-a" "ch-test-1"
        cleanChLogs cfg

        ch <- channelOpen cfg
        threadDelay 200_000

        channelSend ch "hello from agent-a"
        threadDelay 100_000

        msgs <- channelRecv ch
        channelClose ch
        threadDelay 100_000

        assertBool "should have at least one message" (not (null msgs))
        let (sender, body) = head msgs
        assertEqual "sender" "agent-a" sender
        assertEqual "body" "hello from agent-a" body,
      testCase "multi-agent: attach sees messages from opener" $ do
        let cfgA = mkChCfg "agent-a" "ch-test-2"
            cfgB = mkChCfg "agent-b" "ch-test-2"
        cleanChLogs cfgA

        chA <- channelOpen cfgA
        threadDelay 200_000

        chB <- channelAttach cfgB

        channelSend chA "message from A"

        mMsgs <- channelRecvBlocking chB 5_000_000
        channelClose chA
        threadDelay 100_000

        case mMsgs of
          Nothing -> assertFailure "agent B timed out waiting for A's message"
          Just msgsB -> do
            assertBool "agent B should see A's message" (not (null msgsB))
            let (sender, body) = head msgsB
            assertEqual "sender seen by B" "agent-a" sender
            assertEqual "body seen by B" "message from A" body,
      testCase "multi-agent: both can send and see each other" $ do
        let cfgA = mkChCfg "agent-a" "ch-test-3"
            cfgB = mkChCfg "agent-b" "ch-test-3"
        cleanChLogs cfgA

        chA <- channelOpen cfgA
        threadDelay 200_000

        chB <- channelAttach cfgB

        channelSend chA "ping from A"
        channelSend chB "pong from B"

        mMsgsA <- channelRecvBlocking chA 5_000_000
        mMsgsB <- channelRecvBlocking chB 5_000_000
        channelClose chA
        threadDelay 100_000

        case (mMsgsA, mMsgsB) of
          (Nothing, _) -> assertFailure "agent A timed out"
          (_, Nothing) -> assertFailure "agent B timed out"
          (Just msgsA, Just msgsB) -> do
            let sendersA = map fst msgsA
                sendersB = map fst msgsB
            assertBool "A sees B" ("agent-b" `elem` sendersA)
            assertBool "A sees itself" ("agent-a" `elem` sendersA)
            assertBool "B sees A" ("agent-a" `elem` sendersB)
            assertBool "B sees itself" ("agent-b" `elem` sendersB),
      testCase "blocking recv times out when no messages" $ do
        let cfg = mkChCfg "agent-x" "ch-test-4"
        cleanChLogs cfg

        ch <- channelOpen cfg
        threadDelay 200_000

        mMsgs <- channelRecvBlocking ch 1_000_000
        channelClose ch
        threadDelay 100_000

        assertBool "should time out with Nothing" (isNothing mMsgs),
      testCase "blocking recv returns messages when they arrive" $ do
        let cfg = mkChCfg "agent-sender" "ch-test-5"
        cleanChLogs cfg

        ch <- channelOpen cfg
        threadDelay 200_000

        channelSend ch "arriving message"
        threadDelay 100_000

        mMsgs <- channelRecvBlocking ch 5_000_000
        channelClose ch
        threadDelay 100_000

        case mMsgs of
          Nothing -> assertFailure "expected messages but timed out"
          Just msgs -> do
            assertBool "should have messages" (not (null msgs))
            let (sender, body) = head msgs
            assertEqual "sender" "agent-sender" sender
            assertEqual "body" "arriving message" body
    ]
  where
    mkChCfg name suffix =
      ChannelConfig
        { chStdinPath = "/tmp/ch-test-stdin-" <> suffix,
          chStdoutPath = "/tmp/ch-test-stdout-" <> suffix <> ".md",
          chStderrPath = "/tmp/ch-test-stderr-" <> suffix <> ".md",
          chName = name,
          chWorkingDir = "."
        }

    cleanChLogs cfg = do
      mapM_
        (\p -> whenM (doesFileExist p) (removeFile p))
        [chStdinPath cfg, chStdoutPath cfg, chStderrPath cfg]
      whenM (doesFileExist (chStdinPath cfg)) (removeFile (chStdinPath cfg))

-- ---------------------------------------------------------------------------
-- Session tests (protocol: ask/answer, tell/recv)
-- ---------------------------------------------------------------------------

sessionTests :: TestTree
sessionTests =
  testGroup
    "Session (ask/answer protocol)"
    [ testCase "parseMsg broadcast" $ do
        assertEqual
          "broadcast"
          (Just (Broadcast "sender" "hello world"))
          (parseMsg "sender" "hello world"),
      testCase "parseMsg question" $ do
        assertEqual
          "question"
          (Just (Question "agent" "agent.0" "should I refactor?"))
          (parseMsg "agent" "? agent.0 should I refactor?"),
      testCase "parseMsg answer" $ do
        assertEqual
          "answer"
          (Just (Answer "agent" "agent.0" "yes go ahead"))
          (parseMsg "agent" "! agent.0 yes go ahead"),
      testCase "parseMsg rejects malformed question (no id)" $ do
        assertBool "no id" (isNothing (parseMsg "agent" "? ")),
      testCase "parseMsg rejects malformed question (no body)" $ do
        assertBool "no body" (isNothing (parseMsg "agent" "? x ")),
      testCase "tell and recv" $ do
        let cfgA = mkSessCfg "agent-a" "sess-bcast"
        cleanSessLogs cfgA

        sessA <- sessionOpen cfgA
        threadDelay 200_000

        tell sessA "hello from session A"
        threadDelay 500_000

        msgs <- recv sessA
        sessionClose sessA
        threadDelay 100_000

        assertBool "should have at least one message" (not (null msgs))
        case head msgs of
          Broadcast sender body -> do
            assertEqual "sender" "agent-a" sender
            assertEqual "body" "hello from session A" body
          _ -> assertFailure "expected Broadcast",
      testCase "ask and answer across two sessions" $ do
        let cfgA = mkSessCfg "agent-a" "sess-ask"
            cfgB = mkSessCfg "agent-b" "sess-ask"
        cleanSessLogs cfgA

        sessA <- sessionOpen cfgA
        threadDelay 200_000

        sessB <- sessionAttach cfgB sessA
        threadDelay 200_000

        -- A asks in a separate thread (it blocks until answered)
        resultMVar <- newEmptyMVar
        _ <- forkIO $ do
          reply <- ask sessA "should I refactor Baz.hs?"
          putMVar resultMVar reply

        -- B waits for the question, then answers it
        qMsgs <- waitForMessages sessB 5_000_000
        case qMsgs of
          Nothing -> assertFailure "B timed out waiting for question"
          Just msgs -> do
            assertBool "B should see a question" (any isQuestion msgs)
            case findQuestion msgs of
              Nothing -> assertFailure "no Question in messages"
              Just (Question _sender qid _body) -> do
                answer sessB qid "yes, definitely refactor"

        -- Now A's ask should unblock
        reply <- takeMVar resultMVar
        assertEqual "answer body" "yes, definitely refactor" reply

        sessionClose sessA
        threadDelay 100_000,
      testCase "two questions, interleaved answers" $ do
        let cfgA = mkSessCfg "agent-a" "sess-multi"
            cfgB = mkSessCfg "agent-b" "sess-multi"
        cleanSessLogs cfgA

        sessA <- sessionOpen cfgA
        threadDelay 200_000

        sessB <- sessionAttach cfgB sessA
        threadDelay 200_000

        -- Send two questions from A (use tell with manual framing
        -- to avoid threading complexity of concurrent blocking ask)
        rawSend sessA "? a.q1 question one"
        rawSend sessA "? a.q2 question two"
        threadDelay 300_000

        -- B polls until it sees at least 2 questions
        bMsgs <- waitForMessagesN sessB 2 5_000_000
        case bMsgs of
          Nothing -> assertFailure "B timed out waiting for questions"
          Just msgs -> do
            let qs = filter isQuestion msgs
            assertBool "should see at least two questions" (length qs >= 2)
            -- Answer both
            forM_ qs $ \case
              Question _ qid _ -> answer sessB qid "done"
              _ -> pure ()

        -- A should see the answers in its buffer
        threadDelay 300_000
        aMsgs <- recv sessA
        let answers = filter isAnswer aMsgs
        assertBool "A should see at least two answers" (length answers >= 2)

        sessionClose sessA
        threadDelay 100_000
    ]
  where
    mkSessCfg name suffix =
      SessionConfig
        { sessChannel =
            ChannelConfig
              { chStdinPath = "/tmp/sess-test-stdin-" <> suffix,
                chStdoutPath = "/tmp/sess-test-stdout-" <> suffix <> ".md",
                chStderrPath = "/tmp/sess-test-stderr-" <> suffix <> ".md",
                chName = name,
                chWorkingDir = "."
              },
          sessName = name
        }

    cleanSessLogs cfg = do
      let ch = sessChannel cfg
      mapM_
        (\p -> whenM (doesFileExist p) (removeFile p))
        [chStdinPath ch, chStdoutPath ch, chStderrPath ch]
      whenM (doesFileExist (chStdinPath ch)) (removeFile (chStdinPath ch))

    isQuestion :: Msg -> Bool
    isQuestion Question {} = True
    isQuestion _ = False

    isAnswer :: Msg -> Bool
    isAnswer Answer {} = True
    isAnswer _ = False

    findQuestion :: [Msg] -> Maybe Msg
    findQuestion = foldr (\m acc -> if isQuestion m then Just m else acc) Nothing

    -- Poll recv until messages arrive or timeout
    waitForMessages :: Session -> Int -> IO (Maybe [Msg])
    waitForMessages sess timeoutUs = go 0 10000
      where
        go elapsed delay = do
          msgs <- recv sess
          if not (null msgs)
            then pure (Just msgs)
            else do
              let elapsed' = elapsed + delay
              if elapsed' >= timeoutUs
                then pure Nothing
                else do
                  threadDelay delay
                  let delay' = min 500000 (floor (fromIntegral delay * 1.5 :: Double))
                  go elapsed' delay'

    -- Poll recv until at least N messages accumulate, or timeout
    waitForMessagesN :: Session -> Int -> Int -> IO (Maybe [Msg])
    waitForMessagesN sess n timeoutUs = go 0 10000 []
      where
        go elapsed delay acc = do
          msgs <- recv sess
          let acc' = acc ++ msgs
          if length acc' >= n
            then pure (Just acc')
            else do
              let elapsed' = elapsed + delay
              if elapsed' >= timeoutUs
                then pure Nothing
                else do
                  threadDelay delay
                  let delay' = min 500000 (floor (fromIntegral delay * 1.5 :: Double))
                  go elapsed' delay' acc'

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

whenM :: (Monad m) => m Bool -> m () -> m ()
whenM mb action = do
  b <- mb
  when b action
