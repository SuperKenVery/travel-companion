//! Typed UniFFI contract implemented by platform and fake backends.
//!
//! UserNotifications objects stay behind the backend; only platform-neutral
//! values cross this boundary.

use std::sync::Arc;
use thiserror::Error;

#[derive(Debug, Error, uniffi::Error)]
pub enum NotificationsBackendError {
    #[error("backend rejected operation: {message}")]
    Backend { message: String },
    #[error("unexpected UniFFI callback failure: {message}")]
    Callback { message: String },
}

impl From<uniffi::UnexpectedUniFFICallbackError> for NotificationsBackendError {
    fn from(error: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Callback {
            message: error.to_string(),
        }
    }
}

#[derive(uniffi::Object)]
pub struct NotificationsEventSink {
    handler: Arc<dyn Fn(crate::NotificationEvent) + Send + Sync + 'static>,
}

impl NotificationsEventSink {
    /// Constructs the Rust-owned event sink. This constructor is
    /// intentionally not exported through UniFFI.
    #[must_use]
    pub fn new(
        handler: Arc<dyn Fn(crate::NotificationEvent) + Send + Sync + 'static>,
    ) -> Arc<Self> {
        Arc::new(Self { handler })
    }

    pub(crate) fn emit(&self, event: crate::NotificationEvent) {
        (self.handler)(event);
    }
}

#[uniffi::export]
impl NotificationsEventSink {
    pub fn authorization_changed(&self, status: crate::NotificationAuthorization) {
        self.emit(crate::NotificationEvent::AuthorizationChanged { status });
    }

    pub fn scheduled(&self, request_id: String, identifier: String) {
        self.emit(crate::NotificationEvent::Scheduled {
            request_id: model::RequestId::from(request_id.as_str()),
            identifier,
        });
    }

    pub fn cancelled(&self, request_id: String, identifier: String) {
        self.emit(crate::NotificationEvent::Cancelled {
            request_id: model::RequestId::from(request_id.as_str()),
            identifier,
        });
    }

    pub fn opened(&self, identifier: String, deep_link: Option<String>, action: Option<String>) {
        self.emit(crate::NotificationEvent::Opened {
            identifier,
            deep_link,
            action,
        });
    }

    pub fn failed(&self, request_id: Option<String>, code: String, message: String) {
        self.emit(crate::NotificationEvent::Failed {
            request_id: request_id.as_deref().map(model::RequestId::from),
            code,
            message,
        });
    }
}

#[uniffi::export(foreign)]
pub trait NotificationsBackend: Send + Sync {
    fn capabilities(&self) -> Result<crate::NotificationCapabilities, NotificationsBackendError>;

    fn attach_event_sink(
        &self,
        event_sink: Arc<NotificationsEventSink>,
    ) -> Result<(), NotificationsBackendError>;

    fn request_authorization(&self, request_id: String) -> Result<(), NotificationsBackendError>;

    // A flat foreign method keeps every operation field visible to Swift.
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
    ) -> Result<(), NotificationsBackendError>;

    fn cancel(
        &self,
        request_id: String,
        identifier: String,
    ) -> Result<(), NotificationsBackendError>;

    fn shutdown(&self) -> Result<(), NotificationsBackendError>;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    #[test]
    fn event_sink_builds_typed_events() {
        let received = Arc::new(Mutex::new(Vec::new()));
        let received_by_handler = Arc::clone(&received);
        let sink = NotificationsEventSink::new(Arc::new(move |event| {
            received_by_handler.lock().unwrap().push(event);
        }));

        sink.authorization_changed(crate::NotificationAuthorization::Authorized);

        assert_eq!(
            *received.lock().unwrap(),
            [crate::NotificationEvent::AuthorizationChanged {
                status: crate::NotificationAuthorization::Authorized,
            }]
        );
    }
}
