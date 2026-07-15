//! Local-notification capability; it cannot represent remote/APNs delivery.

mod ffi;

pub use ffi::{NotificationsBackend, NotificationsBackendError, NotificationsEventSink};

use serde::{Deserialize, Serialize};
use std::sync::{Arc, Mutex};
use tc_model::RequestId;

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct NotificationCapabilities {
    pub local_notifications: bool,
    pub actions: bool,
    pub time_sensitive: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize, uniffi::Enum)]
#[serde(rename_all = "camelCase")]
pub enum NotificationAuthorization {
    NotDetermined,
    Denied,
    Authorized,
    Provisional,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub enum NotificationCommand {
    RequestAuthorization {
        request_id: RequestId,
    },
    Schedule {
        request_id: RequestId,
        identifier: String,
        title: String,
        body: String,
        deep_link: Option<String>,
        merge_key: Option<String>,
        time_sensitive: bool,
    },
    Cancel {
        request_id: RequestId,
        identifier: String,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub enum NotificationEvent {
    AuthorizationChanged {
        status: NotificationAuthorization,
    },
    Scheduled {
        request_id: RequestId,
        identifier: String,
    },
    Cancelled {
        request_id: RequestId,
        identifier: String,
    },
    Opened {
        identifier: String,
        deep_link: Option<String>,
        action: Option<String>,
    },
    Failed {
        request_id: Option<RequestId>,
        code: String,
        message: String,
    },
}

pub struct FakeNotificationsBackend {
    capabilities: NotificationCapabilities,
    state: Mutex<FakeNotificationsState>,
}

#[derive(Default)]
struct FakeNotificationsState {
    commands: Vec<NotificationCommand>,
    event_sink: Option<Arc<NotificationsEventSink>>,
    is_shutdown: bool,
}

impl Default for FakeNotificationsBackend {
    fn default() -> Self {
        Self {
            capabilities: NotificationCapabilities {
                local_notifications: true,
                actions: true,
                time_sensitive: true,
            },
            state: Mutex::new(FakeNotificationsState::default()),
        }
    }
}

impl FakeNotificationsBackend {
    /// Pushes a typed event through the same sink used by a platform backend.
    pub fn inject(&self, event: NotificationEvent) -> Result<(), NotificationsBackendError> {
        let event_sink = {
            let state = self.state.lock().map_err(|_| backend_state_poisoned())?;
            if state.is_shutdown {
                return Err(backend_is_shutdown());
            }
            state
                .event_sink
                .clone()
                .ok_or_else(|| NotificationsBackendError::Backend {
                    message: "notifications event sink is not attached".to_owned(),
                })?
        };
        event_sink.emit(event);
        Ok(())
    }

    fn record(&self, command: NotificationCommand) -> Result<(), NotificationsBackendError> {
        let mut state = self.state.lock().map_err(|_| backend_state_poisoned())?;
        if state.is_shutdown {
            return Err(backend_is_shutdown());
        }
        state.commands.push(command);
        Ok(())
    }

    #[must_use]
    pub fn commands(&self) -> Vec<NotificationCommand> {
        self.state
            .lock()
            .expect("fake notifications state poisoned")
            .commands
            .clone()
    }
}

impl NotificationsBackend for FakeNotificationsBackend {
    fn capabilities(&self) -> Result<NotificationCapabilities, NotificationsBackendError> {
        Ok(self.capabilities.clone())
    }

    fn attach_event_sink(
        &self,
        event_sink: Arc<NotificationsEventSink>,
    ) -> Result<(), NotificationsBackendError> {
        let mut state = self.state.lock().map_err(|_| backend_state_poisoned())?;
        if state.is_shutdown {
            return Err(backend_is_shutdown());
        }
        state.event_sink = Some(event_sink);
        Ok(())
    }

    fn request_authorization(&self, request_id: String) -> Result<(), NotificationsBackendError> {
        self.record(NotificationCommand::RequestAuthorization {
            request_id: RequestId::from(request_id.as_str()),
        })
    }

    #[allow(clippy::too_many_arguments)]
    fn schedule(
        &self,
        request_id: String,
        identifier: String,
        title: String,
        body: String,
        deep_link: Option<String>,
        merge_key: Option<String>,
        time_sensitive: bool,
    ) -> Result<(), NotificationsBackendError> {
        self.record(NotificationCommand::Schedule {
            request_id: RequestId::from(request_id.as_str()),
            identifier,
            title,
            body,
            deep_link,
            merge_key,
            time_sensitive,
        })
    }

    fn cancel(
        &self,
        request_id: String,
        identifier: String,
    ) -> Result<(), NotificationsBackendError> {
        self.record(NotificationCommand::Cancel {
            request_id: RequestId::from(request_id.as_str()),
            identifier,
        })
    }

    fn shutdown(&self) -> Result<(), NotificationsBackendError> {
        let mut state = self.state.lock().map_err(|_| backend_state_poisoned())?;
        state.is_shutdown = true;
        state.event_sink = None;
        Ok(())
    }
}

fn backend_state_poisoned() -> NotificationsBackendError {
    NotificationsBackendError::Backend {
        message: "fake notifications backend state is poisoned".to_owned(),
    }
}

fn backend_is_shutdown() -> NotificationsBackendError {
    NotificationsBackendError::Backend {
        message: "notifications backend is shut down".to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fake_uses_the_foreign_backend_push_contract() {
        let backend = FakeNotificationsBackend::default();
        let received = Arc::new(Mutex::new(Vec::new()));
        let received_by_sink = Arc::clone(&received);
        let sink = NotificationsEventSink::new(Arc::new(move |event| {
            received_by_sink.lock().unwrap().push(event);
        }));

        NotificationsBackend::attach_event_sink(&backend, sink).unwrap();
        assert_eq!(
            NotificationsBackend::capabilities(&backend).unwrap(),
            NotificationCapabilities {
                local_notifications: true,
                actions: true,
                time_sensitive: true,
            }
        );
        let command = NotificationCommand::Cancel {
            request_id: RequestId::from("req-cancel"),
            identifier: "trip-reminder".to_owned(),
        };
        NotificationsBackend::cancel(
            &backend,
            "req-cancel".to_owned(),
            "trip-reminder".to_owned(),
        )
        .unwrap();
        assert_eq!(backend.commands(), [command]);

        let event = NotificationEvent::Cancelled {
            request_id: RequestId::from("req-cancel"),
            identifier: "trip-reminder".to_owned(),
        };
        backend.inject(event.clone()).unwrap();
        assert_eq!(received.lock().unwrap().pop().unwrap(), event);
    }
}

uniffi::setup_scaffolding!();
