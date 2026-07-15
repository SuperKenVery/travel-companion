//! System call UI and audio-session capability. Encoded realtime audio remains
//! a separate peer-transport stream.

mod ffi;

pub use ffi::{CallSystemBackend, CallSystemBackendError, CallSystemEventSink};

use model::{CallId, PeerId, RequestId};
use serde::{Deserialize, Serialize};
use std::sync::{Arc, Mutex};

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct CallSystemCapabilities {
    pub incoming_call_ui: bool,
    pub background_audio: bool,
    pub voice_processing: bool,
    pub bluetooth_routes: bool,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize, uniffi::Enum)]
#[serde(rename_all = "camelCase")]
pub enum AudioRoute {
    Receiver,
    Speaker,
    WiredHeadset,
    Bluetooth,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub enum CallSystemCommand {
    ReportIncoming {
        request_id: RequestId,
        call_id: CallId,
        peer_id: PeerId,
        display_name: String,
    },
    ReportOutgoing {
        request_id: RequestId,
        call_id: CallId,
        peer_id: PeerId,
        display_name: String,
    },
    ActivateAudio {
        request_id: RequestId,
        call_id: CallId,
    },
    DeactivateAudio {
        request_id: RequestId,
        call_id: CallId,
    },
    SetMuted {
        request_id: RequestId,
        call_id: CallId,
        muted: bool,
    },
    SetRoute {
        request_id: RequestId,
        route: AudioRoute,
    },
    PlayAudio {
        request_id: RequestId,
        call_id: CallId,
        pcm16: Vec<u8>,
        sample_rate: u32,
        channel_count: u32,
        sequence: u64,
        timestamp_ms: i64,
    },
    End {
        request_id: RequestId,
        call_id: CallId,
        reason: String,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub enum CallSystemEvent {
    IncomingReported {
        request_id: RequestId,
        call_id: CallId,
    },
    OutgoingReported {
        request_id: RequestId,
        call_id: CallId,
    },
    UserAnswered {
        call_id: CallId,
    },
    UserRejected {
        call_id: CallId,
    },
    UserEnded {
        call_id: CallId,
    },
    AudioActivated {
        call_id: CallId,
    },
    AudioDeactivated {
        call_id: CallId,
    },
    AudioInterrupted {
        call_id: CallId,
        should_resume: bool,
    },
    RouteChanged {
        route: AudioRoute,
    },
    AudioFrame {
        call_id: CallId,
        pcm16: Vec<u8>,
        sample_rate: u32,
        channel_count: u32,
        sequence: u64,
        timestamp_ms: i64,
    },
    MutedChanged {
        call_id: CallId,
        muted: bool,
    },
    Failed {
        request_id: Option<RequestId>,
        code: String,
        message: String,
    },
}

pub struct FakeCallSystemBackend {
    capabilities: CallSystemCapabilities,
    state: Mutex<FakeCallSystemState>,
}

#[derive(Default)]
struct FakeCallSystemState {
    commands: Vec<CallSystemCommand>,
    event_sink: Option<Arc<CallSystemEventSink>>,
    is_shutdown: bool,
}

impl Default for FakeCallSystemBackend {
    fn default() -> Self {
        Self {
            capabilities: CallSystemCapabilities {
                incoming_call_ui: true,
                background_audio: true,
                voice_processing: true,
                bluetooth_routes: true,
            },
            state: Mutex::new(FakeCallSystemState::default()),
        }
    }
}

impl FakeCallSystemBackend {
    /// Pushes a typed event through the same sink used by a platform backend.
    pub fn inject(&self, event: CallSystemEvent) -> Result<(), CallSystemBackendError> {
        let event_sink = {
            let state = self.state.lock().map_err(|_| backend_state_poisoned())?;
            if state.is_shutdown {
                return Err(backend_is_shutdown());
            }
            state
                .event_sink
                .clone()
                .ok_or_else(|| CallSystemBackendError::Backend {
                    message: "call-system event sink is not attached".to_owned(),
                })?
        };
        match event {
            CallSystemEvent::IncomingReported {
                request_id,
                call_id,
            } => event_sink.incoming_reported(request_id.to_string(), call_id.to_string()),
            CallSystemEvent::OutgoingReported {
                request_id,
                call_id,
            } => event_sink.outgoing_reported(request_id.to_string(), call_id.to_string()),
            CallSystemEvent::UserAnswered { call_id } => {
                event_sink.user_answered(call_id.to_string());
            }
            CallSystemEvent::UserRejected { call_id } => {
                event_sink.user_rejected(call_id.to_string());
            }
            CallSystemEvent::UserEnded { call_id } => {
                event_sink.user_ended(call_id.to_string());
            }
            CallSystemEvent::AudioActivated { call_id } => {
                event_sink.audio_activated(call_id.to_string());
            }
            CallSystemEvent::AudioDeactivated { call_id } => {
                event_sink.audio_deactivated(call_id.to_string());
            }
            CallSystemEvent::AudioInterrupted {
                call_id,
                should_resume,
            } => event_sink.audio_interrupted(call_id.to_string(), should_resume),
            CallSystemEvent::RouteChanged { route } => event_sink.route_changed(route),
            CallSystemEvent::AudioFrame {
                call_id,
                pcm16,
                sample_rate,
                channel_count,
                sequence,
                timestamp_ms,
            } => event_sink.audio_frame(
                call_id.to_string(),
                pcm16,
                sample_rate,
                channel_count,
                sequence,
                timestamp_ms,
            ),
            CallSystemEvent::MutedChanged { call_id, muted } => {
                event_sink.muted_changed(call_id.to_string(), muted);
            }
            CallSystemEvent::Failed {
                request_id,
                code,
                message,
            } => event_sink.failed(request_id.map(|id| id.to_string()), code, message),
        }
        Ok(())
    }

    #[must_use]
    pub fn commands(&self) -> Vec<CallSystemCommand> {
        self.state
            .lock()
            .expect("fake call-system state poisoned")
            .commands
            .clone()
    }

    fn record(&self, command: CallSystemCommand) -> Result<(), CallSystemBackendError> {
        let mut state = self.state.lock().map_err(|_| backend_state_poisoned())?;
        if state.is_shutdown {
            return Err(backend_is_shutdown());
        }
        state.commands.push(command);
        Ok(())
    }
}

impl CallSystemBackend for FakeCallSystemBackend {
    fn capabilities(&self) -> Result<CallSystemCapabilities, CallSystemBackendError> {
        Ok(self.capabilities.clone())
    }

    fn attach_event_sink(
        &self,
        event_sink: Arc<CallSystemEventSink>,
    ) -> Result<(), CallSystemBackendError> {
        let mut state = self.state.lock().map_err(|_| backend_state_poisoned())?;
        if state.is_shutdown {
            return Err(backend_is_shutdown());
        }
        state.event_sink = Some(event_sink);
        Ok(())
    }

    fn report_incoming(
        &self,
        request_id: String,
        call_id: String,
        peer_id: String,
        display_name: String,
    ) -> Result<(), CallSystemBackendError> {
        self.record(CallSystemCommand::ReportIncoming {
            request_id: RequestId::from_string(request_id),
            call_id: CallId::from_string(call_id),
            peer_id: PeerId::from_string(peer_id),
            display_name,
        })
    }

    fn report_outgoing(
        &self,
        request_id: String,
        call_id: String,
        peer_id: String,
        display_name: String,
    ) -> Result<(), CallSystemBackendError> {
        self.record(CallSystemCommand::ReportOutgoing {
            request_id: RequestId::from_string(request_id),
            call_id: CallId::from_string(call_id),
            peer_id: PeerId::from_string(peer_id),
            display_name,
        })
    }

    fn activate_audio(
        &self,
        request_id: String,
        call_id: String,
    ) -> Result<(), CallSystemBackendError> {
        self.record(CallSystemCommand::ActivateAudio {
            request_id: RequestId::from_string(request_id),
            call_id: CallId::from_string(call_id),
        })
    }

    fn deactivate_audio(
        &self,
        request_id: String,
        call_id: String,
    ) -> Result<(), CallSystemBackendError> {
        self.record(CallSystemCommand::DeactivateAudio {
            request_id: RequestId::from_string(request_id),
            call_id: CallId::from_string(call_id),
        })
    }

    fn set_muted(
        &self,
        request_id: String,
        call_id: String,
        muted: bool,
    ) -> Result<(), CallSystemBackendError> {
        self.record(CallSystemCommand::SetMuted {
            request_id: RequestId::from_string(request_id),
            call_id: CallId::from_string(call_id),
            muted,
        })
    }

    fn set_route(
        &self,
        request_id: String,
        route: AudioRoute,
    ) -> Result<(), CallSystemBackendError> {
        self.record(CallSystemCommand::SetRoute {
            request_id: RequestId::from_string(request_id),
            route,
        })
    }

    fn play_audio(
        &self,
        request_id: String,
        call_id: String,
        pcm16: Vec<u8>,
        sample_rate: u32,
        channel_count: u32,
        sequence: u64,
        timestamp_ms: i64,
    ) -> Result<(), CallSystemBackendError> {
        self.record(CallSystemCommand::PlayAudio {
            request_id: RequestId::from_string(request_id),
            call_id: CallId::from_string(call_id),
            pcm16,
            sample_rate,
            channel_count,
            sequence,
            timestamp_ms,
        })
    }

    fn end(
        &self,
        request_id: String,
        call_id: String,
        reason: String,
    ) -> Result<(), CallSystemBackendError> {
        self.record(CallSystemCommand::End {
            request_id: RequestId::from_string(request_id),
            call_id: CallId::from_string(call_id),
            reason,
        })
    }

    fn shutdown(&self) -> Result<(), CallSystemBackendError> {
        let mut state = self.state.lock().map_err(|_| backend_state_poisoned())?;
        state.is_shutdown = true;
        state.event_sink = None;
        Ok(())
    }
}

fn backend_state_poisoned() -> CallSystemBackendError {
    CallSystemBackendError::Backend {
        message: "fake call-system backend state is poisoned".to_owned(),
    }
}

fn backend_is_shutdown() -> CallSystemBackendError {
    CallSystemBackendError::Backend {
        message: "call-system backend is shut down".to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fake_uses_the_foreign_backend_push_contract() {
        let backend = FakeCallSystemBackend::default();
        let received = Arc::new(Mutex::new(Vec::new()));
        let received_by_sink = Arc::clone(&received);
        let sink = CallSystemEventSink::new(Arc::new(move |event| {
            received_by_sink.lock().unwrap().push(event);
        }));

        CallSystemBackend::attach_event_sink(&backend, sink).unwrap();
        assert_eq!(
            CallSystemBackend::capabilities(&backend).unwrap(),
            CallSystemCapabilities {
                incoming_call_ui: true,
                background_audio: true,
                voice_processing: true,
                bluetooth_routes: true,
            }
        );
        let command = CallSystemCommand::SetRoute {
            request_id: RequestId::from("req-route"),
            route: AudioRoute::Speaker,
        };
        CallSystemBackend::set_route(&backend, "req-route".to_owned(), AudioRoute::Speaker)
            .unwrap();
        assert_eq!(backend.commands(), [command]);

        let event = CallSystemEvent::RouteChanged {
            route: AudioRoute::Speaker,
        };
        backend.inject(event.clone()).unwrap();
        assert_eq!(received.lock().unwrap().pop().unwrap(), event);
    }
}

uniffi::setup_scaffolding!();
