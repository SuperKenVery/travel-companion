# TcRangingApple

Nearby Interaction implementation of the typed `tc-ranging` contract. Each command is a public
method and events are `TcRangingEvent` cases. Discovery tokens cross as `Data`; no `NISession`,
`NIDiscoveryToken`, or private Apple schema crosses the module boundary.

Accepted commands are `createDiscoveryToken`, `start`, and `cancel`. Emitted events are
`discoveryToken`, `started`, `measurement`, `suspended`, `ended`, and `failed`, with the same fields
as `RangingCommand` and `RangingEvent`.

The backend owns one `NISession` per stable peer UUID and invalidates every session when the app
backgrounds. Distance and direction remain independently optional. Nearby Interaction supplies no
measurement timestamp, so Swift emits `observedAtMs: 0`; Rust ingestion replaces that sentinel with
the callback receive time before materializing state.

There is no module-specific C ABI or public header. Swift constructs the main-actor backend and
forwards typed events through the supplied event sink.
