{-# LANGUAGE OverloadedStrings #-}

-- | Example: driving a cabal repl (or ghci) as a clean, interactive tool
-- from Haskell code / agents.
--
-- This is the recommended replacement for the older grepl package
-- (now considered deprecated for new work).
--
-- Parking note: development of the REPL machinery and agent comms is parked
-- here in circuits-io while side-activity happens on the main `circuits`
-- package. Everything needed to pick up the thread (including the open
-- bidirectional multi-round comms work) is self-contained. See the simulation
-- at the end of this file and the "Bidirectional Multi-Round..." section in
-- readme.md.
--
-- Key features demonstrated:
-- * Startup "guff" (build profiles, configuring, "Ok, modules loaded") is filtered.
-- * Prompt-based synchronization so you get clean response blocks.
-- * Simple helpers for the common interactive workflow: :t, :i, :k, eval.
-- * The underlying FIFO mechanism means one REPL process can be shared
--   by multiple clients (agents or you + an agent) via 'replAttach'.
--
-- Typical use: following a type trail while exploring a new library or
-- composing a pipeline of functions.
--
-- Run with the mock for a self-contained demo:
--   cabal run --builddir=dist-newstyle cabal-repl-example
--
-- Or point it at a real project by changing the config.
module Main where

import Control.Concurrent (threadDelay)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.IO (hPutStrLn, stderr)

import Circuit.Repl

main :: IO ()
main = do
  hPutStrLn stderr "=== circuits-io Cabal REPL example (using mock for demo) ==="
  hPutStrLn stderr "This shows filtering of startup ceremony and clean command responses."

  -- Use the built mock-repl as a stand-in that produces GHCi-like output
  -- including startup guff. In real use, point at "cabal" "repl" in a project dir.
  let cfg = defaultReplConfig
        { replCommand = "./dist-newstyle/build/aarch64-osx/ghc-9.14.1/circuits-io-0.1.0.0/x/mock-repl/build/mock-repl/mock-repl"
        , replArgs = ["--prompt=ghci> ", "--delay=10"]
        , replWorkingDir = "."
        }

  -- Start (or attach to) the REPL.
  -- For shared use by two agents at the same time, one does replOpen,
  -- the others do replAttach with the *same* config paths.
  r <- replOpen cfg
  threadDelay 300000  -- let startup guff be written

  -- Consume the initial prompt (this discards the build guff via sync).
  _ <- replSync r

  -- Now use the clean ghciCommand helper.
  -- It sends the command, waits for the next prompt, and filters guff.
  typeOfId <- ghciCommand r ":t id"
  TIO.putStrLn "=== :t id ==="
  mapM_ TIO.putStrLn typeOfId

  kindOfMaybe <- ghciCommand r ":k Maybe"
  TIO.putStrLn "\n=== :k Maybe ==="
  mapM_ TIO.putStrLn kindOfMaybe

  -- Simulate exploring a "new library" by loading something and querying.
  -- (With real cabal repl in a project with libraries, this becomes powerful.)
  _ <- ghciCommand r "import Data.Maybe"
  infoJust <- ghciCommand r ":i fromJust"
  TIO.putStrLn "\n=== :i fromJust (after import) ==="
  mapM_ TIO.putStrLn infoJust

  -- Pipeline building example: evaluate a small expression.
  evalExample <- ghciCommand r "Just 42 >>= \\x -> return (x + 1)"
  TIO.putStrLn "\n=== eval a small pipeline ==="
  mapM_ TIO.putStrLn evalExample

  -- Demonstrate attach for "both use it at the same time".
  -- In a real scenario, another agent/process can do:
  --   r2 <- replAttach cfg
  --   ... use r2 for its own queries ...
  -- Both see the shared output log; writes are serialized.
  -- Here we just show attach works and sees subsequent output.
  r2 <- replAttach cfg
  -- Give a command from the "second client"
  _ <- ghciCommand r2 "length [1,2,3]"
  TIO.putStrLn "\n=== second client (via attach) got a response ==="
  -- We can emit from either to see new stuff
  newFromR1 <- replEmit r
  mapM_ TIO.putStrLn newFromR1

  -- === Bidirectional multi-round comms simulation ===
  -- This is the current state of the "thread": we have shared REPL sessions
  -- (multiple Repl handles via replAttach on the same FIFO+log), clean
  -- command/response, and the ability for agents to take turns.
  -- However, we have not yet demonstrated a full automated bidirectional
  -- multi-round loop (AgentA posts message/task -> AgentB consumes, computes,
  -- replies -> AgentA reacts, etc.) without the driver (this main) doing the
  -- orchestration. That is the open thread to pick up later (e.g. build a
  -- higher-level ReplBus or AgentChannel abstraction that provides send/receive
  -- with proper sync on top of Repl + the log as transcript).
  --
  -- Below is a *simulation* of two agents using the shared REPL as blackboard
  -- for multi-round exchange. In a real setup each "agent" would be in its own
  -- thread/process polling/attaching.

  TIO.putStrLn "\n=== Bidirectional multi-round agent comms simulation (shared REPL blackboard) ==="

  rA <- replAttach cfg
  rB <- replAttach cfg

  -- Round 1: Agent A posts a task into the shared REPL state
  _ <- ghciCommand rA "let taskFromA = \"sum 1 to 10\""
  TIO.putStrLn "Agent A posted task"

  -- Round 2: Agent B "wakes", inspects the task, computes reply
  _ <- ghciCommand rB "taskFromA"
  _ <- ghciCommand rB "let replyFromB = 55"  -- pretend computation of sum [1..10]
  TIO.putStrLn "Agent B read task and posted reply"

  -- Round 3: Agent A checks the reply and "acknowledges"
  _ <- ghciCommand rA "replyFromB"
  _ <- ghciCommand rA "let ackFromA = \"got it\""
  TIO.putStrLn "Agent A retrieved reply and posted ack"

  -- One more round for good measure
  _ <- ghciCommand rB "ackFromA"
  TIO.putStrLn "Agent B saw ack"

  TIO.putStrLn "=== End of simulated multi-round comms ==="

  -- Clean up (only the owner needs to close the process).
  replClose r

  hPutStrLn stderr "\n=== done. The same pattern works with a real 'cabal repl' ==="
  hPutStrLn stderr "by using startCabalRepl \".\" or a custom ReplConfig."
  hPutStrLn stderr "See the implementation of ghciCommand and isGuff for how the"
  hPutStrLn stderr "startup ceremony and prompt searching are handled."
