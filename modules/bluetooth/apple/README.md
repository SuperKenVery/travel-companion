# BluetoothApple

Core Bluetooth packet backend for `bluetooth`. It owns central/peripheral roles, the fixed
service and characteristic UUIDs, restoration, negotiated MTU, write backpressure and stable
`UInt64` handles.

The UniFFI `BluetoothBackend` exposes `start`, `stop`, `connect`, `disconnect` and `sendPacket`.
Native events report discovery/connection state plus `packetReceived`, `packetSent` and failures.
Packets are opaque bytes capped by `maxPacketBytes`; CoreBluetooth objects never cross the module
boundary.

Product control types, envelope encoding, fragmentation/reassembly, TTL, duplicate suppression and
ACK correlation live in the Rust `BluetoothRuntime`/`protocol`. Swift therefore does not know
about invitation, join, group-control, location or call messages and contains no private semantic
JSON contract.
