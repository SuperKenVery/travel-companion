//! Small credential/key storage capability. Platform objects (Keychain,
//! Keystore) remain owned by the registered platform backend.

mod ffi;

pub use ffi::{SecureStorageBackend, SecureStorageBackendError, SecureStorageEventSink};

use model::RequestId;
use serde::{Deserialize, Serialize};
use std::sync::{Arc, Mutex};
use zeroize::{Zeroize, ZeroizeOnDrop};

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct SecureStorageCapabilities {
    pub hardware_backed_when_available: bool,
    pub device_only_accessibility: bool,
    pub biometric_policy: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize, Zeroize, ZeroizeOnDrop)]
#[serde(transparent)]
pub struct SecretValue(pub Vec<u8>);

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub enum SecureStorageCommand {
    Put {
        request_id: RequestId,
        key: String,
        value: SecretValue,
    },
    Get {
        request_id: RequestId,
        key: String,
    },
    Delete {
        request_id: RequestId,
        key: String,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub enum SecureStorageEvent {
    Stored {
        request_id: RequestId,
        key: String,
    },
    Loaded {
        request_id: RequestId,
        key: String,
        value: Option<SecretValue>,
    },
    Deleted {
        request_id: RequestId,
        key: String,
    },
    Failed {
        request_id: Option<RequestId>,
        code: String,
        message: String,
    },
}

pub struct FakeSecureStorageBackend {
    capabilities: SecureStorageCapabilities,
    state: Mutex<FakeSecureStorageState>,
}

#[derive(Default)]
struct FakeSecureStorageState {
    commands: Vec<SecureStorageCommand>,
    event_sink: Option<Arc<SecureStorageEventSink>>,
    is_shutdown: bool,
}

impl Default for FakeSecureStorageBackend {
    fn default() -> Self {
        Self {
            capabilities: SecureStorageCapabilities {
                hardware_backed_when_available: true,
                device_only_accessibility: true,
                biometric_policy: true,
            },
            state: Mutex::new(FakeSecureStorageState::default()),
        }
    }
}

impl FakeSecureStorageBackend {
    /// Pushes a typed event through the same sink used by a platform backend.
    pub fn inject(&self, event: SecureStorageEvent) -> Result<(), SecureStorageBackendError> {
        let event_sink = {
            let state = self.state.lock().map_err(|_| backend_state_poisoned())?;
            if state.is_shutdown {
                return Err(backend_is_shutdown());
            }
            state
                .event_sink
                .clone()
                .ok_or_else(|| SecureStorageBackendError::Backend {
                    message: "secure-storage event sink is not attached".to_owned(),
                })?
        };
        match event {
            SecureStorageEvent::Stored { request_id, key } => {
                event_sink.stored(request_id.to_string(), key);
            }
            SecureStorageEvent::Loaded {
                request_id,
                key,
                value,
            } => event_sink.loaded(
                request_id.to_string(),
                key,
                value.map(|mut secret| std::mem::take(&mut secret.0)),
            ),
            SecureStorageEvent::Deleted { request_id, key } => {
                event_sink.deleted(request_id.to_string(), key);
            }
            SecureStorageEvent::Failed {
                request_id,
                code,
                message,
            } => event_sink.failed(request_id.map(|id| id.to_string()), code, message),
        }
        Ok(())
    }

    #[must_use]
    pub fn commands(&self) -> Vec<SecureStorageCommand> {
        self.state
            .lock()
            .expect("fake secure-storage state poisoned")
            .commands
            .clone()
    }

    fn record(&self, command: SecureStorageCommand) -> Result<(), SecureStorageBackendError> {
        let mut state = self.state.lock().map_err(|_| backend_state_poisoned())?;
        if state.is_shutdown {
            return Err(backend_is_shutdown());
        }
        state.commands.push(command);
        Ok(())
    }
}

impl SecureStorageBackend for FakeSecureStorageBackend {
    fn capabilities(&self) -> Result<SecureStorageCapabilities, SecureStorageBackendError> {
        Ok(self.capabilities.clone())
    }

    fn attach_event_sink(
        &self,
        event_sink: Arc<SecureStorageEventSink>,
    ) -> Result<(), SecureStorageBackendError> {
        let mut state = self.state.lock().map_err(|_| backend_state_poisoned())?;
        if state.is_shutdown {
            return Err(backend_is_shutdown());
        }
        state.event_sink = Some(event_sink);
        Ok(())
    }

    fn put(
        &self,
        request_id: String,
        key: String,
        value: Vec<u8>,
    ) -> Result<(), SecureStorageBackendError> {
        self.record(SecureStorageCommand::Put {
            request_id: RequestId::from_string(request_id),
            key,
            value: SecretValue(value),
        })
    }

    fn get(&self, request_id: String, key: String) -> Result<(), SecureStorageBackendError> {
        self.record(SecureStorageCommand::Get {
            request_id: RequestId::from_string(request_id),
            key,
        })
    }

    fn delete(&self, request_id: String, key: String) -> Result<(), SecureStorageBackendError> {
        self.record(SecureStorageCommand::Delete {
            request_id: RequestId::from_string(request_id),
            key,
        })
    }

    fn shutdown(&self) -> Result<(), SecureStorageBackendError> {
        let mut state = self.state.lock().map_err(|_| backend_state_poisoned())?;
        state.is_shutdown = true;
        state.event_sink = None;
        Ok(())
    }
}

fn backend_state_poisoned() -> SecureStorageBackendError {
    SecureStorageBackendError::Backend {
        message: "fake secure-storage backend state is poisoned".to_owned(),
    }
}

fn backend_is_shutdown() -> SecureStorageBackendError {
    SecureStorageBackendError::Backend {
        message: "secure-storage backend is shut down".to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fake_uses_the_foreign_backend_push_contract() {
        let backend = FakeSecureStorageBackend::default();
        let received = Arc::new(Mutex::new(Vec::new()));
        let received_by_sink = Arc::clone(&received);
        let sink = SecureStorageEventSink::new(Arc::new(move |event| {
            received_by_sink.lock().unwrap().push(event);
        }));

        SecureStorageBackend::attach_event_sink(&backend, sink).unwrap();
        assert_eq!(
            SecureStorageBackend::capabilities(&backend).unwrap(),
            SecureStorageCapabilities {
                hardware_backed_when_available: true,
                device_only_accessibility: true,
                biometric_policy: true,
            }
        );
        let command = SecureStorageCommand::Delete {
            request_id: RequestId::from("req-delete"),
            key: "identity".to_owned(),
        };
        SecureStorageBackend::delete(&backend, "req-delete".to_owned(), "identity".to_owned())
            .unwrap();
        assert_eq!(backend.commands(), [command]);

        let event = SecureStorageEvent::Deleted {
            request_id: RequestId::from("req-delete"),
            key: "identity".to_owned(),
        };
        backend.inject(event.clone()).unwrap();
        assert_eq!(received.lock().unwrap().pop().unwrap(), event);
    }
}

uniffi::setup_scaffolding!();
