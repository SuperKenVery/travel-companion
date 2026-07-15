# SecureStorageApple

Private Keychain backend using generic-password items. It fixes accessibility to
`afterFirstUnlockThisDeviceOnly`, disables iCloud synchronization, and limits values to 64 KiB.
It does not claim Secure Enclave backing because this API stores opaque credential bytes rather
than private-key operation handles.

The public API exposes typed `put`, `get`, and `delete` methods and emits
`SecureStorageEvent.stored`, `.loaded`, `.deleted`, or `.failed`. `Data` crosses the boundary only
for the credential value itself; there is no JSON command/event schema. Rust keeps credential bytes
in `SecretValue` so owned buffers are zeroized on drop, and the Swift backend wipes its transient
mutable `put` copy after Security.framework consumes it.
