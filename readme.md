# circuits-io

Channel decomposition and buffered IO for the circuits library.

Five modules, three entry points:

1. **Build a circuit with feedback** → `Circuit.Ends` (Co, Contra, close, open)
2. **Add a buffer to a pipeline** → `Circuit.Queue` (endsQueue, closeQueue, endsSTM)
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

`Circuit.Ends` provides first-class channel ends — the companion and conjoint of the identity functor in proarrow equipment, now re-exported from the core `Circuit` library (see `Circuit.Circuit`):

```haskell
newtype Co arr t a     = Co     { runContra :: forall x. Contra arr t x -> Circuit arr t x a }
newtype Contra arr t a = Contra { runCo     :: forall x. Co arr t x     -> Circuit arr t a x }

close :: Contra arr t a -> Co arr t a -> Circuit arr t a a
close contra = runCo contra

open :: a -> (Co (->) (,) a, Contra (->) (,) a)
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

## Cabal REPL / GHCi support (recommended replacement for grepl)

`Circuit.Repl` plus the GHCi conveniences (`ghciCommand`, `isGuff`, `startCabalRepl`, `replAttach`) give you a clean way to drive `cabal repl` (or plain ghci) without the usual startup ceremony and prompt-chasing boilerplate.

See `examples/cabal-repl.hs` for a self-contained demo (it uses the internal `mock-repl` so it runs anywhere; swap the config for a real project).

Typical interactive workflow (type chasing a new library or building a pipeline):

```haskell
r <- startCabalRepl "."
ty <- ghciCommand r ":t someFunction"
info <- ghciCommand r ":i SomeType"
```

**grepl is deprecated** for new development. The FIFO technique it pioneered is now provided in a more compositional form here (with proper cursor tracking, sync, Circuit lifting, and attach for shared sessions).

## Sharing one REPL (multiple agents or you + agent)

```haskell
-- Agent A
r1 <- replOpen myCabalConfig
...
-- Agent B (or you in another process)
r2 <- replAttach myCabalConfig
-- Both can now issue ghciCommand / commits. Writes are serialized;
-- each sees output via its own cursor on the shared log.
```

This satisfies the "both use it at the same time" requirement for collaborative type trails or pipeline building.

## Bidirectional Multi-Round Agent Comms (Status & Open Thread)

We have solid building blocks for agents to drive REPLs and share them:
- Clean filtered command/response via `ghciCommand` / `replSync` (startup guff and prompt searching handled).
- Shared sessions via `replAttach` (multiple agents write to one FIFO; each maintains its own cursor on the shared log).
- The mock-repl + tests in `test/` let us develop this deterministically.

**Current limitation (the thread to pick up):** We have not yet demonstrated true *bidirectional multi-round comms* in an automated way. That is, a loop where:
- Agent A posts a message/task into the shared REPL (as state or "inbox").
- Agent B (in another process/thread, using its own Repl handle) detects/consumes it, performs computation, posts a reply.
- Agent A reacts to the reply, and so on, over several turns, with the log serving as the canonical transcript.

See the end of `examples/cabal-repl.hs` for a *simulated* version of this pattern (two attached handles taking turns on the blackboard). The open work is to lift this into a higher-level abstraction (e.g. a `ReplBus` or protocol on top of `Repl` + the log) so real agents (Grok, Hermes, etc.) can do multi-round back-and-forth without the driver script doing all the orchestration.

All of this remains safely in `circuits-io`. The main `circuits` package can continue to focus on the abstract traced monoidal machinery; `circuits-io` owns the concrete "honest seams" for external process/agent comms.

When side-activity on `circuits` settles, resume here by:
- Enhancing the mock-repl with better "message bus" simulation (e.g. a list of pending messages).
- Building the bus abstraction + a real multi-round test/demo.
- Wiring it to actual external agents (pi, hermes profiles, etc.) using the same ReplConfig + attach pattern.
