# circuits-io

Channel decomposition and buffered IO for the circuits library.

Five modules, three entry points:

1. **Build a circuit with feedback** → `Circuit.Ends` (Producer, Consumer, open, close)
2. **Add a buffer to a pipeline** → `Circuit.Queue` (makeQueue, closeQueue, endsSTM)
3. **Talk to external processes** → `Circuit.Repl`, `Circuit.Socket`

Also: `Circuit.Time` — sleep, timestamps, gap measurement.

Absorbs and deprecates:
- `box` (Emitter/Committer pattern → Circuit)
- `web-rep` (HTTP combinators)
- `box-socket` (socket operations)

## Packages

- `circuits` — core: Circuit GADT, Hyper, Loop, Trace
- `circuits-io` — IO layer: channel ends, queue buffering, REPL, socket, timing
- `circuits-parser` — parsing: Parser, Uncons on These
- `circuits-perf` — benchmarking: once/times/warmup

---

## The circuits-io types

`Circuit.Ends` provides first-class channel ends — the companion and conjoint of the identity functor in proarrow equipment:

```haskell
newtype Producer arr t a = Producer (forall x. Consumer arr t x -> Circuit arr t x a)
newtype Consumer arr t a = Consumer (forall x. Producer arr t x -> Circuit arr t a x)

close :: Producer arr t a -> Consumer arr t a -> Circuit arr t a a
close p c = runProducer p c
```

`Circuit.Queue` provides STM-backed and pure queue strategies:

```haskell
data Queue a = Unbounded | Bounded Int | Single | Latest a | Newest Int

makeQueue :: Queue a -> IO (Circuit (Kleisli IO) (,) a (), Circuit (Kleisli IO) (,) () a)
```

`Circuit.Socket` provides bracketed TCP and WebSocket connections:

```haskell
withTCPClient :: TCPConfig -> ((Socket, SockAddr) -> IO r) -> IO r
withTCPServer :: TCPConfig -> ((Socket, SockAddr) -> IO ()) -> IO ()

tcpDuplex :: Socket -> Int -> TQueue ByteString -> TQueue ByteString -> IO ()
wsDuplex  :: Connection -> TQueue a -> TQueue a -> IO ()
```

The channel is the queue. The socket is just a pipe into it.
