//! Platform-neutral location sampling capability.

mod ffi;

pub use ffi::{LocationBackend, LocationBackendError, LocationEventSink, LocationSampleRecord};

use model::{LocationSample, RequestId};
use serde::{Deserialize, Serialize};
use std::sync::{Arc, Mutex};

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct LocationCapabilities {
    pub precise_location: bool,
    pub background_updates: bool,
    pub service_session: bool,
    pub background_activity_session: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize, uniffi::Enum)]
#[serde(rename_all = "camelCase")]
pub enum LocationAuthorization {
    NotDetermined,
    Denied,
    WhenInUse,
    Always,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub enum LocationCommand {
    StartTravelUpdates {
        request_id: RequestId,
        background: bool,
    },
    StopTravelUpdates {
        request_id: RequestId,
    },
    RequestSample {
        request_id: RequestId,
        desired_freshness_ms: i64,
        deadline_ms: i64,
    },
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub enum LocationEvent {
    Started {
        request_id: RequestId,
    },
    Stopped {
        request_id: RequestId,
    },
    AuthorizationChanged {
        status: LocationAuthorization,
    },
    Sample {
        request_id: Option<RequestId>,
        sample: LocationSample,
        from_cache: bool,
    },
    TimedOut {
        request_id: RequestId,
        stale_sample: Option<LocationSample>,
    },
    Failed {
        request_id: Option<RequestId>,
        code: String,
        message: String,
        retryable: bool,
    },
}

pub struct FakeLocationBackend {
    capabilities: LocationCapabilities,
    state: Mutex<FakeLocationState>,
}

#[derive(Default)]
struct FakeLocationState {
    commands: Vec<LocationCommand>,
    event_sink: Option<Arc<LocationEventSink>>,
    is_shutdown: bool,
}

impl Default for FakeLocationBackend {
    fn default() -> Self {
        Self {
            capabilities: LocationCapabilities {
                precise_location: true,
                background_updates: true,
                service_session: true,
                background_activity_session: true,
            },
            state: Mutex::new(FakeLocationState::default()),
        }
    }
}

impl FakeLocationBackend {
    pub fn inject(&self, event: LocationEvent) -> Result<(), LocationBackendError> {
        let event_sink = {
            let state = self.state.lock().expect("fake location state poisoned");
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

    fn record(&self, command: LocationCommand) -> Result<(), LocationBackendError> {
        let mut state = self.state.lock().expect("fake location state poisoned");
        if state.is_shutdown {
            return Err(backend_error("backend is shut down"));
        }
        state.commands.push(command);
        Ok(())
    }

    #[must_use]
    pub fn commands(&self) -> Vec<LocationCommand> {
        self.state
            .lock()
            .expect("fake location state poisoned")
            .commands
            .clone()
    }
}

impl LocationBackend for FakeLocationBackend {
    fn capabilities(&self) -> Result<LocationCapabilities, LocationBackendError> {
        Ok(self.capabilities.clone())
    }

    fn attach_event_sink(
        &self,
        event_sink: Arc<LocationEventSink>,
    ) -> Result<(), LocationBackendError> {
        let mut state = self.state.lock().expect("fake location state poisoned");
        if state.is_shutdown {
            return Err(backend_error("backend is shut down"));
        }
        state.event_sink = Some(event_sink);
        Ok(())
    }

    fn start_travel_updates(
        &self,
        request_id: String,
        background: bool,
    ) -> Result<(), LocationBackendError> {
        self.record(LocationCommand::StartTravelUpdates {
            request_id: RequestId::from_string(request_id),
            background,
        })
    }

    fn stop_travel_updates(&self, request_id: String) -> Result<(), LocationBackendError> {
        self.record(LocationCommand::StopTravelUpdates {
            request_id: RequestId::from_string(request_id),
        })
    }

    fn request_sample(
        &self,
        request_id: String,
        desired_freshness_ms: i64,
        deadline_ms: i64,
    ) -> Result<(), LocationBackendError> {
        self.record(LocationCommand::RequestSample {
            request_id: RequestId::from_string(request_id),
            desired_freshness_ms,
            deadline_ms,
        })
    }

    fn shutdown(&self) -> Result<(), LocationBackendError> {
        let mut state = self.state.lock().expect("fake location state poisoned");
        state.is_shutdown = true;
        state.event_sink = None;
        Ok(())
    }
}

fn backend_error(error: impl std::fmt::Display) -> LocationBackendError {
    LocationBackendError::Backend {
        message: error.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fake_backend_uses_the_foreign_push_contract() {
        let backend = FakeLocationBackend::default();
        assert!(
            LocationBackend::capabilities(&backend)
                .unwrap()
                .precise_location
        );
        let events = Arc::new(Mutex::new(Vec::new()));
        let received_events = Arc::clone(&events);
        backend
            .attach_event_sink(LocationEventSink::new(Arc::new(move |event| {
                received_events.lock().unwrap().push(event);
            })))
            .unwrap();

        let command = LocationCommand::StopTravelUpdates {
            request_id: RequestId::from("stop"),
        };
        backend.stop_travel_updates("stop".into()).unwrap();
        assert_eq!(backend.commands(), vec![command]);

        let event = LocationEvent::Stopped {
            request_id: RequestId::from("stop"),
        };
        backend.inject(event.clone()).unwrap();
        assert_eq!(*events.lock().unwrap(), vec![event]);
    }
}

uniffi::setup_scaffolding!();
