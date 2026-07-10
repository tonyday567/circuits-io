{-# LANGUAGE OverloadedStrings #-}

-- | Bridge a Hermes agent to a shared channel.
--
-- Reads from the channel log, sends prompts to a running Hermes
-- instance via the Repl primitives, and posts responses back.
--
-- Usage:
--   cabal run agent-bridge
--
-- Write to the agent via:
--   echo "[you] your message" > /tmp/channel-stdin
--
-- The agent's responses appear as [agent] lines in the log.
module Main where

import Circuit.Comm
import Circuit.Repl
import Control.Concurrent (threadDelay)
import Control.Monad (unless, when)
import Data.Foldable (forM_)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  hPutStrLn stderr "=== Agent bridge: connecting Hermes to channel ==="

  -- Start the Hermes agent via Repl primitives.
  hPutStrLn stderr "Starting Hermes agent (this takes ~10s)..."
  agent <- startAgent "."

  -- Open the channel for reading messages.
  let chCfg = defaultChannelConfig "agent-bridge"
  ch <- channelAttach chCfg

  hPutStrLn stderr "Agent ready. Reading channel..."
  loop agent ch 0

loop :: Repl -> Channel -> Int -> IO ()
loop agent ch cursor = do
  -- Read new channel messages.
  msgs <- channelRecv ch
  forM_ msgs $ \(sender, body) ->
    -- Only respond to messages NOT from ourselves.
    when (sender /= "agent") $ do
      hPutStrLn stderr $ "  ← [" <> T.unpack sender <> "] " <> T.unpack (T.take 80 body)
      -- Feed the message to Hermes.
      let prompt =
            "You are an AI agent named 'agent' on a shared channel. "
              <> "A user named '"
              <> sender
              <> "' sent: "
              <> body
              <> " "
              <> "Respond helpfully as [agent]. Keep it brief."
      resp <- hermesCommand agent prompt
      unless (null resp) $ do
        let clean = T.unlines resp
        channelSend ch ("[agent] " <> clean)
        hPutStrLn stderr $ "  → [agent] " <> T.unpack (T.take 80 clean)

  threadDelay 2_000_000 -- poll every 2 seconds
  loop agent ch cursor
