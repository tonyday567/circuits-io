-- | Box → circuits-io: socket code as migration guide.
--
-- The box-socket modules are a litmus test. They use the full
-- surface of Box: Committer, Emitter, Codensity, fuse, glue.
--
-- This card maps each primitive to its circuits-io equivalent,
-- using the TCP code as the running example.

{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE PostfixOperators #-}

import Circuit
import Circuit.Channel
import Circuit.IO.Queue
import Control.Arrow (Kleisli(..), runKleisli)
import Control.Concurrent.Async
import Control.Exception
import Control.Monad
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Network.Simple.TCP qualified as NS
import Network.WebSockets
import Prelude hiding (id, (.))

-- ============================================================
-- 1. The core type mapping
-- ============================================================
--
-- Box's Committer and Emitter are newtypes around Kleisli arrows.
-- circuits-io reifies them directly as Circuit (Kleisli IO) Either:
--
--   Box.Committer IO a  ~  Circuit (Kleisli IO) Either a ()
--   Box.Emitter IO a    ~  Circuit (Kleisli IO) Either () a
--
-- The Either tensor gives iteration for free: Knot + reify
-- collapses multi-step circuits via Trace (Kleisli IO) Either,
-- which uses GHC delimited continuations under the hood.
--
-- See examples/box-core.hs for the alias definitions and
-- runB / runE / runC helpers.

-- $setup
-- >>> :set -XBlockArguments -XPostfixOperators
-- >>> import Circuit
-- >>> import Control.Arrow (Kleisli(..), runKleisli)
-- >>> import Control.Concurrent.Async
-- >>> import Data.ByteString (ByteString)

-- ============================================================
-- 2. Single-step primitives
-- ============================================================
--
-- In Box, Committer and Emitter are opaque handles. In circuits-io,
-- a "single step" is just a Lift'd Kleisli arrow.

-- | Read one chunk from a TCP socket.
--
-- Old (Box):  Emitter IO ByteString with emit :: IO (Maybe ByteString)
-- New:        Circuit (Kleisli IO) Either () ByteString
--
-- The Nothing (socket closed) is handled at the call site, not in
-- the circuit type. This keeps the circuit clean: one step = one chunk.
tcpReceive :: NS.Socket -> Int -> Circuit (Kleisli IO) Either () ByteString
tcpReceive conn chunk = Lift $ Kleisli $ \() -> do
  msg <- NS.recv conn chunk
  case msg of
    Nothing -> pure $ Left ()   -- feedback: try again (or caller stops)
    Just bs -> pure $ Right bs  -- output: one chunk

-- | Write one chunk to a TCP socket.
--
-- Old (Box):  Committer IO ByteString with commit :: ByteString -> IO Bool
-- New:        Circuit (Kleisli IO) Either ByteString ()
tcpSend :: NS.Socket -> Circuit (Kleisli IO) Either ByteString ()
tcpSend conn = Lift $ Kleisli $ \bs -> do
  NS.send conn bs
  pure $ Right ()

-- ============================================================
-- 3. Reify: running a single step
-- ============================================================
--
-- Box uses emit/commit directly. circuits-io uses reify to collapse
-- the circuit to a plain Kleisli arrow, then runKleisli.
--
-- For single-step circuits this is trivial:

-- >>> :{
-- let e = tcpReceive undefined 2048
-- -- runKleisli (reify e) () would read from the socket
-- :}

-- For multi-step (looping) circuits, reify ties the Knot via
-- Trace (Kleisli IO) Either. See Circuit.Traced for the
-- delimited-continuation implementation.

-- ============================================================
-- 4. Replacing Codensity
-- ============================================================
--
-- Box uses Codensity for CPS bracketing:
--
--   connect :: TCPConfig -> Codensity IO TCPEnv
--   serve   :: TCPConfig -> Codensity IO TCPEnv
--
-- circuits-io drops Codensity in favour of direct bracketing:

-- | Bracketed TCP client.
withTCPClient :: NS.HostName -> NS.ServiceName -> (NS.Socket -> IO r) -> IO r
withTCPClient host port action =
  NS.connect host port (\(s, _) -> action s)

-- | Bracketed TCP server.
withTCPServer :: NS.HostPreference -> NS.ServiceName -> (NS.Socket -> IO r) -> IO r
withTCPServer host port action =
  NS.serve host port (\(s, _) -> action s)

-- The <$|> and <*|> operators (fmap-then-close Codensity) disappear.
-- You just call the bracketed function directly:
--
--   old:  clientBox cfg ps b . socket <$|> connect cfg
--   new:  withTCPClient host port $ \conn -> clientIO cfg ps b conn

-- ============================================================
-- 5. Replacing Box/Committer/Emitter in duplex
-- ============================================================
--
-- Old duplex races a sender (Emitter) and receiver (Committer):
--
--   duplex cfg ps (Box c e) conn =
--     race (sender e conn) (receiver cfg c conn)
--
-- New duplex uses queueEnds from Circuit.IO.Queue as the bridge.
-- This gives you (write, read) STM handles directly. No feedQueue
-- or drainQueue — those are convenience wrappers, not the primary API.

tcpDuplex :: NS.Socket -> Int -> TQueue ByteString -> TQueue ByteString -> IO ()
tcpDuplex conn chunk inQ outQ = do
  let
    -- receiver: socket → inQ
    recvLoop = do
      msg <- NS.recv conn chunk
      case msg of
        Nothing -> pure ()
        Just bs -> atomically (writeTQueue inQ bs) >> recvLoop
    -- sender: outQ → socket
    sendLoop = do
      bs <- atomically (readTQueue outQ)
      NS.send conn bs
      sendLoop
  void $ race recvLoop sendLoop

-- The Box is gone. The queues are the channel. The circuit consumer
-- and producer attach to the queues at the call site.

-- ============================================================
-- 6. Replacing Box examples
-- ============================================================
--
-- Old: senderExample ts = do
--         (c, r) <- refCommitter
--         a <- async (serverBox defaultTCPConfig ... <$|> qList ts)
--         ...
--
-- New: senderExample ts = do
--         inQ  <- newTQueueIO   -- socket → consumer
--         outQ <- newTQueueIO   -- producer → socket
--         mapM_ (atomically . writeTQueue outQ) ts   -- qList replacement
--         a <- async (withTCPServer ... $ \conn -> tcpDuplex conn 2048 inQ outQ)
--         replicateM (length ts) (atomically $ readTQueue inQ)

-- ============================================================
-- 7. Websocket mapping
-- ============================================================
--
-- The websocket code follows the same pattern. Key replacements:
--
--   Box.connect/serve (Codensity)  →  bracket / withClient / withServer
--   Box.receiver (Committer)       →  TQueue write + runC
--   Box.sender (Emitter)           →  TQueue read + runE
--   Box.duplex (Box)               →  race of two queue loops
--   Box.fuse (map over Box)        →  dimap on the queue, or mapM on drainQueue
--
-- The logging variants (receiver_, sender_, duplex_) are just the
-- same loops with an extra logging queue.

-- ============================================================
-- 8. Summary table
-- ============================================================
--
-- ┌────────────────────┬──────────────────────────────────────────┐
-- │ Box primitive      │ circuits-io replacement                │
-- ├────────────────────┼──────────────────────────────────────────┤
-- │ Committer m a      │ Circuit (Kleisli m) Either a ()        │
-- │ Emitter m a        │ Circuit (Kleisli m) Either () a        │
-- │ Box m c e          │ (Committer m c, Emitter m e) or Queue  │
-- │ Codensity          │ bracket / withX                        │
-- │ commit / emit      │ runKleisli . reify                     │
-- │ <$|> / <*|>        │ direct function application            │
-- │ fuse               │ dimap + glue, or mapM on queue drain   │
-- │ qList              │ feedQueue                              │
-- │ refCommitter       │ newTQueueIO + drainQueue               │
-- │ stdBox             │ getLine / putStrLn directly            │
-- │ fromLineBox        │ splitOn "\\n" + linesProducer          │
-- │ concurrentlyRight  │ race / concurrently                    │
-- │ glue               │ counit (Compose + reify) or queue pipe │
-- └────────────────────┴──────────────────────────────────────────┘
--
-- The queue layer (Circuit.IO.Queue) is the practical bridge.
-- The Circuit (Kleisli IO) Either types are the theoretical bedrock.
-- Both are already in the repo.
