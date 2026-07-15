# TcSecureStorageApple

Private Keychain backend using generic-password items. It defaults to
`afterFirstUnlockThisDeviceOnly`, disables iCloud synchronization, supports an optional access
group, and limits module values to 64 KiB. It does not claim Secure Enclave backing because this
API stores opaque credential bytes rather than private-key operation handles.

Commands use `type` and `requestID?`: `configure` (`service`, `accessGroup?`); `set` (`key`,
`dataBase64`, optional `accessibility` = `afterFirstUnlockThisDeviceOnly|whenUnlockedThisDeviceOnly|`
`whenPasscodeSetThisDeviceOnly`); `get`, `delete`, and `contains` (`key`); `listKeys`; `snapshot`.

Every event has
`{"type":String,"requestID":String?,"key":String?,"dataBase64":String?,`<br>
`"keys":[String]?,"fields":{String:String}?,"error":String?,"osStatus":Int32?}`. Stable types are
`commandCompleted`, `commandFailed`, `valueStored`, `valueLoaded`, `valueMissing`, `valueDeleted`,
`containsResult`, `keysListed`, and `capabilitySnapshot`. Secret bytes appear only in the direct
`valueLoaded` response.
