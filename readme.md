# circuits-io

Agent and external-process IO for the [circuits](https://github.com/tonyday567/circuits) library.

Entry points:

1. **`Circuit.Repl`** — persistent process as free dual ends (commit / emit)
2. **`Circuit.Comm` / `Circuit.Session`** — multi-agent channels on the same dual
3. **`Circuit.Socket`** — TCP / WebSocket
4. **`Circuit.Time`** — sleep, timestamps, gap measurement

Channel ends and queue buffering live in core `circuits` (`Circuit.Ends`, `Circuit.Queue`).

---

## Repl = agent

A `Repl` is a persistent agent process: it reads input, evaluates, prints however
it likes, and loops when it likes. No request–response contract in the type.

```haskell
-- lifecycle
replOpen, replAttach, replClose, replOpenPty, replOpenInject

-- dual ends (independent; same object type — Queue dual)
replCommit :: Repl -> [Text] -> IO ()   -- write TO the agent
replEmit   :: Repl -> IO [Text]         -- read FROM the agent

endsRepl   :: Repl -> (Commit IO [Text], Emit IO [Text])
-- same shape as Circuit.Queue.endsQueue  (agent as [Text] → [Text])
```

Timeout and turn boundaries live only in **runner** circuits that *tie* the two
ends. They are not part of `Circuit.Repl`.

Backends: FIFO (child writes log), PTY (parent pumps log), inject (tests).

```haskell
r <- replOpen cfg
replCommit r [":t id"]
ls <- replEmit r          -- whatever is new; may be empty
let (w, e) = endsRepl r   -- free wires for composition
```

---

## Multi-agent channel

`Circuit.Comm` builds a shared FIFO + log bus (`cat`) on the same dual.
`channelSend` / `channelRecv` are free; `channelRecvBlocking` is a local tie
with a timeout.

`Circuit.Session` adds ask/answer framing on top.

---

## Examples

| example | what it shows |
|---------|----------------|
| **`dual-spike.hs`** | **best first spike:** free dual + one named turn (mock / python) |
| `cabal-repl.hs` | free dual on mock-repl; local `emitUntil` |
| `cabal-repl-real.hs` | free dual on real `cabal repl` |
| `agent-bridge.hs` | free commit/emit with hermes + channel |

```bash
cabal build
cabal test
cabal run dual-spike              # mock-repl FIFO
cabal run dual-spike -- python    # python3 -q PTY
```

---

## Packages

| library | role |
|---------|------|
| `circuits` | Trace, Hyper, Net, Queue duals, Ends |
| `circuits-io` | Repl dual, Comm, Session, Socket, Time |
| `circuits-parser` | parsing as circuit |
| `circuits-meter` | metering |
| `circuits-ad` | backpropagation as transpose |
