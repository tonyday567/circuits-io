{-# LANGUAGE OverloadedStrings #-}

-- | TCP and WebSocket primitives for circuits.
--
-- Bracketed connections, send/receive helpers, and queue-backed duplex
-- loops.  No 'Box' dependency — the channel is a pair of 'TQueue's.
module Circuit.Socket
  ( -- * Shared types
    PostSend (..),
    SocketStatus (..),

    -- * TCP
    TCPConfig (..),
    defaultTCPConfig,
    withTCPClient,
    withTCPServer,
    tcpReceive,
    tcpSend,
    tcpDuplex,

    -- * WebSocket
    SocketConfig (..),
    defaultSocketConfig,
    withWSClient,
    withWSServer,
    wsReceive,
    wsSend,
    wsDuplex,
    wsServerApp,
  )
where

import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Data.ByteString (ByteString)
import Data.Text (Text, unpack)
import GHC.Generics (Generic)
import Network.Simple.TCP qualified as NS
import Network.WebSockets

-- $setup
-- >>> :set -XOverloadedStrings
-- >>> import Circuit.Socket

-- ---------------------------------------------------------------------------
-- Shared types
-- ---------------------------------------------------------------------------

-- | Whether to stay open after an emitter ends or send a close after a delay.
--
-- >>> StayOpen
-- StayOpen
-- >>> CloseAfter 0.5
-- CloseAfter 0.5
data PostSend = StayOpen | CloseAfter Double deriving (Generic, Eq, Show)

-- | Whether a socket remains open or closed after an action finishes.
--
-- >>> SocketOpen
-- SocketOpen
data SocketStatus = SocketOpen | SocketClosed | SocketBroken deriving (Generic, Eq, Show)

-- ---------------------------------------------------------------------------
-- TCP
-- ---------------------------------------------------------------------------

-- | TCP configuration.
data TCPConfig = TCPConfig
  { tcpHost :: Text,
    tcpPort :: Text,
    tcpChunk :: Int
  }
  deriving (Show, Eq, Generic)

-- | Sensible defaults.
--
-- >>> defaultTCPConfig
-- TCPConfig {tcpHost = "127.0.0.1", tcpPort = "3566", tcpChunk = 2048}
defaultTCPConfig :: TCPConfig
defaultTCPConfig = TCPConfig "127.0.0.1" "3566" 2048

-- | Bracketed TCP client.
withTCPClient :: TCPConfig -> ((NS.Socket, NS.SockAddr) -> IO r) -> IO r
withTCPClient cfg =
  NS.connect (unpack $ tcpHost cfg) (unpack $ tcpPort cfg)

-- | Bracketed TCP server.
withTCPServer :: TCPConfig -> ((NS.Socket, NS.SockAddr) -> IO ()) -> IO ()
withTCPServer cfg =
  NS.serve NS.HostAny (unpack $ tcpPort cfg)

-- | Read one chunk from a TCP socket.
-- 'Nothing' means the remote side closed the connection.
tcpReceive :: NS.Socket -> Int -> IO (Maybe ByteString)
tcpReceive = NS.recv

-- | Write one chunk to a TCP socket.
tcpSend :: NS.Socket -> ByteString -> IO ()
tcpSend = NS.send

-- | Run receiver and sender concurrently.
--
-- The receiver pushes incoming data to @inQ@.
-- The sender pops from @outQ@ and sends.
-- Returns when the socket closes or one loop exits.
tcpDuplex :: NS.Socket -> Int -> TQueue ByteString -> TQueue ByteString -> IO ()
tcpDuplex conn chunk inQ outQ = do
  let recvLoop = do
        msg <- NS.recv conn chunk
        case msg of
          Nothing -> pure ()
          Just bs -> atomically (writeTQueue inQ bs) >> recvLoop
      sendLoop = do
        bs <- atomically (readTQueue outQ)
        NS.send conn bs
        sendLoop
  void $ race recvLoop sendLoop

-- ---------------------------------------------------------------------------
-- WebSocket
-- ---------------------------------------------------------------------------

-- | WebSocket configuration.
data SocketConfig = SocketConfig
  { wsHost :: Text,
    wsPort :: Int,
    wsPath :: Text
  }
  deriving (Show, Eq, Generic)

-- | Sensible defaults.
--
-- >>> defaultSocketConfig
-- SocketConfig {wsHost = "127.0.0.1", wsPort = 9160, wsPath = "/"}
defaultSocketConfig :: SocketConfig
defaultSocketConfig = SocketConfig "127.0.0.1" 9160 "/"

-- | Bracketed WebSocket client.
withWSClient :: SocketConfig -> (Connection -> IO ()) -> IO ()
withWSClient cfg =
  runClient
    (unpack $ wsHost cfg)
    (wsPort cfg)
    (unpack $ wsPath cfg)

-- | Bracketed WebSocket server.
withWSServer :: SocketConfig -> (PendingConnection -> IO ()) -> IO ()
withWSServer cfg =
  runServerWithOptions
    (defaultServerOptions {serverHost = unpack (wsHost cfg), serverPort = wsPort cfg})

-- | Accept a pending connection and run an action.
wsServerApp :: (Connection -> IO ()) -> PendingConnection -> IO ()
wsServerApp action p =
  bracket (acceptRequest p) (\_ -> pure ()) action

-- | Receive one message.
-- 'Nothing' means the remote side sent a close frame.
wsReceive :: (WebSocketsData a) => Connection -> IO (Maybe a)
wsReceive conn = do
  msg <- try (receiveData conn)
  case msg of
    Left (CloseRequest _ _) -> pure Nothing
    Left err -> throwIO err
    Right msg' -> pure (Just msg')

-- | Send one message.
wsSend :: (WebSocketsData a) => Connection -> a -> IO ()
wsSend = sendTextData

-- | Run receiver and sender concurrently.
--
-- The receiver pushes incoming data to @inQ@.
-- The sender pops from @outQ@ and sends.
-- Returns when a close frame arrives or one loop exits.
wsDuplex :: (WebSocketsData a) => Connection -> TQueue a -> TQueue a -> IO ()
wsDuplex conn inQ outQ = do
  let recvLoop = do
        msg <- try (receiveData conn)
        case msg of
          Left (CloseRequest _ _) -> pure ()
          Left err -> throwIO err
          Right msg' -> atomically (writeTQueue inQ msg') >> recvLoop
      sendLoop = do
        msg <- atomically (readTQueue outQ)
        sendTextData conn msg
        sendLoop
  void $ race recvLoop sendLoop
