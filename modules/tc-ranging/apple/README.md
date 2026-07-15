# TcRangingApple

Private Nearby Interaction backend. It owns one `NISession` per stable peer UUID, archives only
discovery-token bytes across the boundary, and invalidates every session when the app backgrounds.
Distance and direction are independent optional JSON fields: a missing direction never preserves
an older UWB arrow.

Commands use `type` plus: `capability` (`requestID?`); `begin` (UUID `peerID` and UUID
`requestID`); `receiveToken` (the same IDs and `tokenBase64`); `cancel` (`requestID?`, `peerID`,
`reason?`); `setForeground` (`requestID?`, `foreground`); and `stopAll` (`requestID?`, `reason?`).

Every event has
`{"type":String,"requestID":String?,"peerID":String?,"tokenBase64":String?,`<br>
`"distanceMeters":Float?,"direction":{"x":Float,"y":Float,"z":Float}?,`<br>
`"fields":{String:String}?,"error":String?}`. Stable types are `commandCompleted`,
`commandFailed`, `capabilitySnapshot`, `localToken`, `rangingStarted`, `measurement`,
`measurementUnavailable`, `rangingSuspended`, `rangingResumed`, `rangingStopped`,
`allRangingStopped`, `foregroundStateChanged`, and `rangingFailed`. A measurement may have
distance, direction, both, or neither.
