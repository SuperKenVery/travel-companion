# TcCallSystemApple

Private CallKit/AVAudioSession backend for one-to-one calls. It owns the `CXProvider`, reports
system calls, configures voice-chat audio, emits mono PCM16 capture frames, plays received PCM16,
and reports audio route/interruption/reset state. Call signaling and network audio transport remain
owned by Rust call logic and `tc-peer-transport`; no socket exists here.

Commands use `type` and `requestID?`. `reportIncoming` takes UUID `callID`, `peerID`, and
`displayName?`; `startOutgoing` takes `callID`/`peerID`; `end` and `remoteAnswered` take `callID`;
`remoteEnded` adds `reason?`; `setMuted` adds `muted`; `playAudio` takes `callID`,
`pcm16Base64`, `sampleRate`, mono `channelCount`, `sequence`, and `timestampMillis`; `snapshot`
has no extra fields.

Every event has
`{"type":String,"requestID":String?,"callID":String?,"peerID":String?,`<br>
`"pcm16Base64":String?,"sampleRate":Double?,"channelCount":UInt32?,"sequence":UInt64?,`<br>
`"timestampMillis":UInt64?,"fields":{String:String}?,"error":String?}`. Stable types include
`incomingCallReported`, `incomingCallReportFailed`, `outgoingCallRequested`, `transactionFailed`,
`remoteAnswered`, `remoteEnded`, `startSignalingRequested`, `answerSignalingRequested`,
`endSignalingRequested`, `muteChanged`, `audioFrame`, `audioFrameQueued`, `audioFramesDropped`,
`audioFrameDropped`, `audioPrepared`, `audioActivated`, `audioDeactivated`, `audioRouteSnapshot`,
`audioRouteChanged`, `audioRouteReason`, `audioInterruption`, `audioFailed`, `mediaServicesReset`,
`providerReset`, `capabilitySnapshot`, and `commandFailed`.

The receive jitter buffer targets 3 frames, retains at most 12, reorders by sequence, skips a
missing range after 60 ms or window pressure, emits the exact dropped range, rejects late and
duplicate frames, and clears on call end.
