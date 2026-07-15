# TcPeerTransportApple

Private iOS 26 backend for `tc-peer-transport`. It publishes and browses `_tc-travel._tcp`, sets
`peerToPeerIncluded(true)` and `localOnly(true)` on listeners/connections, and sets the matching
flags on the browser. The lexicographically smaller stable UUID is the sole dialer. TLS encrypts
the connection; the first TLV is an HMAC-authenticated group hello and business TLVs are rejected
until it succeeds.

TLV uses an unsigned 8-bit type and unsigned 32-bit length: `1=control`, `2=event`, `3=chunk`,
`4=audio`. `setRealtime` rebuilds links with `interactiveVoice`; ending realtime returns them to
`bestEffort`.

Optional members are omitted. Apple JSON uses `type`; the Rust adapter maps this private tag to
the semantic module's `kind` tag. All base64 fields use RFC 4648 with padding.

Commands:

- `start`: `requestID?`, UUID `localPeerID`, `groupID`, `displayName`, `protocolVersion`, a
  >=32-byte `groupKeyBase64`, and exactly one TLS identity representation:
  `identityPKCS12Base64` plus `identityPassword?`, or `certificateDERBase64` plus
  `privateKeyPKCS8Base64`. The DER path derives key type/size from the certificate public key,
  imports the private key with `SecKeyCreateWithData`, and creates a matched `SecIdentity`;
- `send`: `requestID?`, `peerHandle`, `channel` (`control|event|chunk|audio`), `payloadBase64`;
- `setRealtime`: `requestID?`, `realtime`; `snapshot`/`stop`: `requestID?` only.

Every event has schema
`{"type":String,"requestID":String?,"peerHandle":UInt64?,"peerID":String?,`<br>
`"channel":String?,"payloadBase64":String?,"fields":{String:String}?,"error":String?}`.
Stable types are `commandCompleted`, `commandFailed`, `capabilitySnapshot`,
`listenerStateChanged`, `browserStateChanged`, `discoveryUpdated`, `dialStarted`,
`connectionStateChanged`, `pathChanged`, `peerConnected`, `peerDisconnected`, `connectionFailed`,
`transportFailed`, `capabilityBlocked`, `frameSent`, `frameReceived`, and `trafficClassChanged`.
Missing or invalid P12/DER identity input emits `capabilityBlocked` with reason
`tlsIdentityUnavailable`;
there is deliberately no fixed M0/release identity fallback. The audio TLV payload
is passed byte-for-byte; the Rust call adapter's payload envelope contains `sequence`,
`timestampMillis`, PCM format, and PCM bytes. Identity inputs are ordinary bytes; production code
should generate a unique identity per installation and persist it with `tc-secure-storage`.
