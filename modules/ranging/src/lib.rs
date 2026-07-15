//! Foreground precise-ranging capability. Distance and direction are distinct
//! optional fields by contract.

mod ffi;

pub use ffi::{RangingBackend, RangingBackendError, RangingEventSink};

use model::{PeerId, RequestId};
use serde::{Deserialize, Serialize};
use std::sync::{Arc, Mutex};

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct RangingCapabilities {
    pub distance: bool,
    pub direction: bool,
    pub foreground_only: bool,
    pub max_concurrent_sessions: u32,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub enum RangingCommand {
    CreateDiscoveryToken {
        request_id: RequestId,
        peer_id: PeerId,
    },
    Start {
        request_id: RequestId,
        peer_id: PeerId,
        remote_discovery_token: Vec<u8>,
    },
    Cancel {
        request_id: RequestId,
        peer_id: PeerId,
        reason: String,
    },
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub enum RangingEvent {
    DiscoveryToken {
        request_id: RequestId,
        token: Vec<u8>,
    },
    Started {
        request_id: RequestId,
        peer_id: PeerId,
    },
    Measurement {
        peer_id: PeerId,
        distance_m: Option<f64>,
        direction_radians: Option<f64>,
        observed_at_ms: i64,
    },
    Suspended {
        peer_id: PeerId,
        reason: String,
    },
    Ended {
        peer_id: PeerId,
        reason: String,
    },
    Failed {
        request_id: Option<RequestId>,
        code: String,
        message: String,
        retryable: bool,
    },
}

pub struct FakeRangingBackend {
    capabilities: RangingCapabilities,
    state: Mutex<FakeRangingState>,
}

#[derive(Default)]
struct FakeRangingState {
    commands: Vec<RangingCommand>,
    event_sink: Option<Arc<RangingEventSink>>,
    is_shutdown: bool,
}

impl Default for FakeRangingBackend {
    fn default() -> Self {
        Self {
            capabilities: RangingCapabilities {
                distance: true,
                direction: true,
                foreground_only: true,
                max_concurrent_sessions: 4,
            },
            state: Mutex::new(FakeRangingState::default()),
        }
    }
}

impl FakeRangingBackend {
    pub fn inject(&self, event: RangingEvent) -> Result<(), RangingBackendError> {
        let event_sink = {
            let state = self.state.lock().expect("fake ranging state poisoned");
            if state.is_shutdown {
                return Err(backend_error("backend is shut down"));
            }
            state.event_sink.clone().ok_or_else(|| {
                backend_error("cannot inject an event before attaching an event sink")
            })?
        };
        event_sink.emit(event);
        Ok(())
    }

    fn record(&self, command: RangingCommand) -> Result<(), RangingBackendError> {
        let mut state = self.state.lock().expect("fake ranging state poisoned");
        if state.is_shutdown {
            return Err(backend_error("backend is shut down"));
        }
        state.commands.push(command);
        Ok(())
    }

    #[must_use]
    pub fn commands(&self) -> Vec<RangingCommand> {
        self.state
            .lock()
            .expect("fake ranging state poisoned")
            .commands
            .clone()
    }
}

impl RangingBackend for FakeRangingBackend {
    fn capabilities(&self) -> Result<RangingCapabilities, RangingBackendError> {
        Ok(self.capabilities.clone())
    }

    fn attach_event_sink(
        &self,
        event_sink: Arc<RangingEventSink>,
    ) -> Result<(), RangingBackendError> {
        let mut state = self.state.lock().expect("fake ranging state poisoned");
        if state.is_shutdown {
            return Err(backend_error("backend is shut down"));
        }
        state.event_sink = Some(event_sink);
        Ok(())
    }

    fn create_discovery_token(
        &self,
        request_id: String,
        peer_id: String,
    ) -> Result<(), RangingBackendError> {
        self.record(RangingCommand::CreateDiscoveryToken {
            request_id: RequestId::from_string(request_id),
            peer_id: PeerId::from_string(peer_id),
        })
    }

    fn start(
        &self,
        request_id: String,
        peer_id: String,
        remote_discovery_token: Vec<u8>,
    ) -> Result<(), RangingBackendError> {
        self.record(RangingCommand::Start {
            request_id: RequestId::from_string(request_id),
            peer_id: PeerId::from_string(peer_id),
            remote_discovery_token,
        })
    }

    fn cancel(
        &self,
        request_id: String,
        peer_id: String,
        reason: String,
    ) -> Result<(), RangingBackendError> {
        self.record(RangingCommand::Cancel {
            request_id: RequestId::from_string(request_id),
            peer_id: PeerId::from_string(peer_id),
            reason,
        })
    }

    fn shutdown(&self) -> Result<(), RangingBackendError> {
        let mut state = self.state.lock().expect("fake ranging state poisoned");
        state.is_shutdown = true;
        state.event_sink = None;
        Ok(())
    }
}

fn backend_error(error: impl std::fmt::Display) -> RangingBackendError {
    RangingBackendError::Backend {
        message: error.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn contract_preserves_distance_when_direction_is_unavailable() {
        let event = RangingEvent::Measurement {
            peer_id: PeerId::from("b"),
            distance_m: Some(2.4),
            direction_radians: None,
            observed_at_ms: 10,
        };
        let RangingEvent::Measurement {
            distance_m,
            direction_radians,
            ..
        } = event
        else {
            unreachable!();
        };
        assert_eq!(distance_m, Some(2.4));
        assert_eq!(direction_radians, None);
    }

    #[test]
    fn fake_backend_uses_the_foreign_push_contract() {
        let backend = FakeRangingBackend::default();
        assert!(RangingBackend::capabilities(&backend).unwrap().distance);
        let events = Arc::new(Mutex::new(Vec::new()));
        let received_events = Arc::clone(&events);
        backend
            .attach_event_sink(RangingEventSink::new(Arc::new(move |event| {
                received_events.lock().unwrap().push(event);
            })))
            .unwrap();

        let command = RangingCommand::Cancel {
            request_id: RequestId::from("cancel"),
            peer_id: PeerId::from("peer"),
            reason: "background".into(),
        };
        backend
            .cancel("cancel".into(), "peer".into(), "background".into())
            .unwrap();
        assert_eq!(backend.commands(), vec![command]);

        let event = RangingEvent::Ended {
            peer_id: PeerId::from("peer"),
            reason: "background".into(),
        };
        backend.inject(event.clone()).unwrap();
        assert_eq!(*events.lock().unwrap(), vec![event]);
    }
}

uniffi::setup_scaffolding!();
