# CallSystemApple

Private CallKit/AVAudioSession backend for one-to-one calls. It owns the `CXProvider`, reports
system calls, configures voice-chat audio, emits mono PCM16 capture frames, plays received PCM16,
and reports audio route/interruption/reset state. Call signaling and network audio transport remain
owned by Rust call logic and `peer-transport`; no socket exists here.

The public API is typed: every Rust `CallSystemCommand` variant maps to a backend method and the
callback receives `CallSystemEvent`. `CallSystemAudioRoute` carries route values without string
tags. `Data` crosses the boundary only for actual PCM16 audio frames. The backend converts semantic
call IDs to CallKit UUIDs internally. Unsupported explicit route selection becomes a typed `failed`
event because AVAudioSession and system UI own route selection.

The receive jitter buffer targets 3 frames, retains at most 12, reorders by sequence, skips a
missing range after 60 ms or window pressure, rejects late and duplicate frames, and clears on call
end. Jitter diagnostics stay internal; only typed domain events cross the boundary.
