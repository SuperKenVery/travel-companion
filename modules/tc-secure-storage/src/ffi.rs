//! Typed UniFFI contract implemented by platform and fake backends.
//!
//! Security.framework objects remain behind the foreign backend. Only domain
//! identifiers and the credential bytes requested by the core cross this boundary.

use std::sync::Arc;
use thiserror::Error;

#[derive(Debug, Error, uniffi::Error)]
pub enum SecureStorageBackendError {
    #[error("backend rejected operation: {message}")]
    Backend { message: String },
    #[error("unexpected UniFFI callback failure: {message}")]
    Callback { message: String },
}

impl From<uniffi::UnexpectedUniFFICallbackError> for SecureStorageBackendError {
    fn from(error: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Callback {
            message: error.to_string(),
        }
    }
}

#[derive(uniffi::Object)]
pub struct SecureStorageEventSink {
    handler: Arc<dyn Fn(crate::SecureStorageEvent) + Send + Sync + 'static>,
}

impl SecureStorageEventSink {
    /// Constructs the Rust-owned event sink. This constructor is
    /// intentionally not exported through UniFFI.
    #[must_use]
    pub fn new(
        handler: Arc<dyn Fn(crate::SecureStorageEvent) + Send + Sync + 'static>,
    ) -> Arc<Self> {
        Arc::new(Self { handler })
    }
}

#[uniffi::export]
impl SecureStorageEventSink {
    pub fn stored(&self, request_id: String, key: String) {
        (self.handler)(crate::SecureStorageEvent::Stored {
            request_id: tc_model::RequestId::from_string(request_id),
            key,
        });
    }

    pub fn loaded(&self, request_id: String, key: String, value: Option<Vec<u8>>) {
        (self.handler)(crate::SecureStorageEvent::Loaded {
            request_id: tc_model::RequestId::from_string(request_id),
            key,
            value: value.map(crate::SecretValue),
        });
    }

    pub fn deleted(&self, request_id: String, key: String) {
        (self.handler)(crate::SecureStorageEvent::Deleted {
            request_id: tc_model::RequestId::from_string(request_id),
            key,
        });
    }

    pub fn failed(&self, request_id: Option<String>, code: String, message: String) {
        (self.handler)(crate::SecureStorageEvent::Failed {
            request_id: request_id.map(tc_model::RequestId::from_string),
            code,
            message,
        });
    }
}

#[uniffi::export(foreign)]
pub trait SecureStorageBackend: Send + Sync {
    fn capabilities(&self) -> Result<crate::SecureStorageCapabilities, SecureStorageBackendError>;

    fn attach_event_sink(
        &self,
        event_sink: Arc<SecureStorageEventSink>,
    ) -> Result<(), SecureStorageBackendError>;

    fn put(
        &self,
        request_id: String,
        key: String,
        value: Vec<u8>,
    ) -> Result<(), SecureStorageBackendError>;

    fn get(&self, request_id: String, key: String) -> Result<(), SecureStorageBackendError>;

    fn delete(&self, request_id: String, key: String) -> Result<(), SecureStorageBackendError>;

    fn shutdown(&self) -> Result<(), SecureStorageBackendError>;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    #[test]
    fn event_sink_constructs_typed_events() {
        let received = Arc::new(Mutex::new(Vec::new()));
        let received_by_handler = Arc::clone(&received);
        let sink = SecureStorageEventSink::new(Arc::new(move |event| {
            received_by_handler.lock().unwrap().push(event);
        }));

        sink.loaded(
            "load-one".to_owned(),
            "identity".to_owned(),
            Some(vec![1, 2, 3]),
        );

        assert_eq!(
            *received.lock().unwrap(),
            [crate::SecureStorageEvent::Loaded {
                request_id: "load-one".into(),
                key: "identity".to_owned(),
                value: Some(crate::SecretValue(vec![1, 2, 3])),
            }]
        );
    }
}
