# TcBluetoothApple

Private Apple backend for `tc-bluetooth`. It owns both Core Bluetooth roles, uses the fixed
service/characteristic UUIDs in `TcBluetoothAppleBackend`, restores both managers, fragments
small opaque control envelopes, suppresses duplicates, enforces TTL, and emits/accepts ACKs.
Group identity and message authentication stay inside the opaque encrypted `payloadBase64`.

The C ABI is in `include/tc_bluetooth_apple.h`. `submit` only copies and queues JSON; completion
and framework callbacks arrive through the callback as UTF-8 JSON. Handles are backend-local
stable `uint64_t` values and no `CB*` object crosses the boundary. Optional JSON members are
omitted when nil. `type` is the private Apple wire discriminator; the Rust adapter maps it to the
semantic module's `kind` tag.

Commands (`type` plus optional `requestID`):

- `{"type":"start|stop|snapshot","requestID":"..."}`;
- `{"type":"disconnect","requestID":"...","peerHandle":1}`;
- `{"type":"sendControl","requestID":"...","peerHandle":1?,"messageID":"UUID",`<br>
  `"sequence":1,"ttlMillis":30000,"requiresAck":true,"payloadBase64":"..."}`. An
  omitted handle broadcasts to ready links. Payloads are capped at 4096 bytes.

Every event has schema
`{"type":String,"requestID":String?,"peerHandle":UInt64?,"messageID":String?,`<br>
`"sequence":UInt64?,"payloadBase64":String?,"fields":{String:String}?,"error":String?}`.
Stable event types are `commandCompleted`, `commandFailed`, `capabilitySnapshot`,
`centralStateChanged`, `peripheralStateChanged`, `stateRestored`, `advertisingStarted`,
`peerDiscovered`, `peerAdvertisement`, `peerConnected`, `peerConnectionFailed`, `peerReady`,
`peerDisconnected`, `gattError`, `transportError`, `controlQueued`, `controlReceived`,
`controlAcknowledged`, and `controlExpired`. `controlReceived` carries the original payload;
duplicates are ACKed again but not emitted twice.
