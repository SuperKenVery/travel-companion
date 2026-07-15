# PeerTransportApple

Network.framework packet backend for `peer-transport`. It publishes and browses
`_travel._tcp`, enables peer-to-peer/local-only networking, owns TLS identity import and
Network.framework connection lifetimes, and applies service class/backpressure to opaque TLV
frames.

The UniFFI `PeerTransportBackend` receives an HMAC-derived opaque discovery scope rather than a
group ID/key. It reports provisional inbound/outbound connection handles and moves bytes through
`sendFrame`/`frameReceived` on four transport channels (`control`, `event`, `chunk`, `audio`). It
does not encode or inspect application payloads.

The Rust `PeerTransportRuntime` creates and validates the group-authenticated hello, enforces the
stable dial direction and admits a connection before emitting the semantic `Authenticated` event.
`protocol`/`travel-core` encode sync, resource and realtime frames. Consequently Swift contains no
group HMAC implementation, realtime JSON/base64 envelope, message kind or application protocol
decoder. TLS still encrypts the connection; Rust authenticates group membership above it.
