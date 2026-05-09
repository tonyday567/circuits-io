# circuits-io

IO combinators for the circuits library.

Built on `Circuit.Channel`'s Producer/Consumer framework. Provides
batteries-included IO operations: file I/O, IORef, socket, server,
timing, and async.

Absorbs and deprecates:
- `box` (Emitter/Committer pattern → Circuit.Channel)
- `web-rep` (HTTP combinators)
- `box-socket` (socket operations)

## Packages

- `circuits` — core: Circuit GADT, Hyper, Loop, Trace, Channel
- `circuits-io` — IO layer: fileIO, socket, server, timing, async
- `circuits-parser` — parsing: Parser, Uncons on These
- `circuits-perf` — benchmarking: once/times/warmup
