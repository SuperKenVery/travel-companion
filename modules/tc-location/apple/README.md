# TcLocationApple

Private Core Location backend. An active trip owns `CLServiceSession(.always)`,
`CLBackgroundActivitySession`, their diagnostic streams, and `CLLocationUpdate.liveUpdates`.
Every valid callback updates the cache; outbound updates are distance/time throttled, with a
longer interval while stationary. On-demand requests use a fresh cache or race a higher-accuracy
live update against the supplied deadline.

Commands:

- `start`: `requestID?`, optional `liveConfiguration` (`default|automotiveNavigation|` 
  `otherNavigation|fitness|airborne`), `minimumEmitIntervalMillis`, `minimumDistanceMeters`;
- `requestSample`: `requestID?`, `desiredFreshnessMillis`, `deadlineEpochMillis`;
- `setSharingPaused`: `requestID?`, `sharingPaused`; `setForeground`: `requestID?`, `foreground`;
- `snapshot` and `stop`: `requestID?` only.

Every event has
`{"type":String,"requestID":String?,"sample":Sample?,"status":String?,`<br>
`"fields":{String:String}?,"error":String?}`. `Sample` has `latitude`, `longitude`, `altitude`,
`horizontalAccuracy`, `verticalAccuracy`, `speed`, `speedAccuracy`, `course`, `courseAccuracy`,
`sampledAtEpochMillis`, `stationary`, `simulated?`, and `producedByAccessory?`.

Stable event types are `commandCompleted`, `commandFailed`, `capabilitySnapshot`,
`locationUpdated`, `sampleResponse` (`fresh|stale|timeout|sharingPaused`),
`sharingStateChanged`, `foregroundStateChanged`, `updateDiagnostic`, `serviceDiagnostic`,
`backgroundDiagnostic`, and their `*Failed` stream errors. `submit` never waits for a result.
