//! Typed UniFFI contract implemented by platform and fake backends.
//!
//! Platform framework objects remain behind the foreign backend and never
//! cross this boundary.

use std::sync::Arc;
use thiserror::Error;

#[derive(Debug, Error, uniffi::Error)]
pub enum RangingBackendError {
    #[error("backend rejected operation: {message}")]
    Backend { message: String },
    #[error("unexpected UniFFI callback failure: {message}")]
    Callback { message: String },
}

impl From<uniffi::UnexpectedUniFFICallbackError> for RangingBackendError {
    fn from(error: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Callback {
            message: error.to_string(),
        }
    }
}

#[derive(uniffi::Object)]
pub struct RangingEventSink {
    handler: Arc<dyn Fn(crate::RangingEvent) + Send + Sync + 'static>,
}

impl RangingEventSink {
    /// Constructs the Rust-owned event sink. This constructor is
    /// intentionally not exported through UniFFI.
    #[must_use]
    pub fn new(handler: Arc<dyn Fn(crate::RangingEvent) + Send + Sync + 'static>) -> Arc<Self> {
        Arc::new(Self { handler })
    }

    pub(crate) fn emit(&self, event: crate::RangingEvent) {
        (self.handler)(event);
    }
}

#[uniffi::export]
impl RangingEventSink {
    pub fn discovery_token(&self, request_id: String, token: Vec<u8>) {
        self.emit(crate::RangingEvent::DiscoveryToken {
            request_id: model::RequestId::from_string(request_id),
            token,
        });
    }

    pub fn started(&self, request_id: String, peer_id: String) {
        self.emit(crate::RangingEvent::Started {
            request_id: model::RequestId::from_string(request_id),
            peer_id: model::PeerId::from_string(peer_id),
        });
    }

    pub fn measurement(
        &self,
        peer_id: String,
        distance_m: Option<f64>,
        direction_radians: Option<f64>,
        observed_at_ms: i64,
    ) {
        self.emit(crate::RangingEvent::Measurement {
            peer_id: model::PeerId::from_string(peer_id),
            distance_m,
            direction_radians,
            observed_at_ms,
        });
    }

    pub fn suspended(&self, peer_id: String, reason: String) {
        self.emit(crate::RangingEvent::Suspended {
            peer_id: model::PeerId::from_string(peer_id),
            reason,
        });
    }

    pub fn ended(&self, peer_id: String, reason: String) {
        self.emit(crate::RangingEvent::Ended {
            peer_id: model::PeerId::from_string(peer_id),
            reason,
        });
    }

    pub fn failed(
        &self,
        request_id: Option<String>,
        code: String,
        message: String,
        retryable: bool,
    ) {
        self.emit(crate::RangingEvent::Failed {
            request_id: request_id.map(model::RequestId::from_string),
            code,
            message,
            retryable,
        });
    }
}

#[uniffi::export(foreign)]
pub trait RangingBackend: Send + Sync {
    fn capabilities(&self) -> Result<crate::RangingCapabilities, RangingBackendError>;

    fn attach_event_sink(
        &self,
        event_sink: Arc<RangingEventSink>,
    ) -> Result<(), RangingBackendError>;

    fn create_discovery_token(
        &self,
        request_id: String,
        peer_id: String,
    ) -> Result<(), RangingBackendError>;

    fn start(
        &self,
        request_id: String,
        peer_id: String,
        remote_discovery_token: Vec<u8>,
    ) -> Result<(), RangingBackendError>;

    fn cancel(
        &self,
        request_id: String,
        peer_id: String,
        reason: String,
    ) -> Result<(), RangingBackendError>;

    fn shutdown(&self) -> Result<(), RangingBackendError>;
}

#[cfg(test)]
mod tests {
    use super::*;
    use model::PeerId;
    use std::sync::Mutex;

    #[test]
    fn event_sink_constructs_typed_events() {
        let received = Arc::new(Mutex::new(Vec::new()));
        let received_by_handler = Arc::clone(&received);
        let sink = RangingEventSink::new(Arc::new(move |event| {
            received_by_handler.lock().unwrap().push(event);
        }));

        sink.measurement("peer".into(), Some(2.4), None, 10);

        assert_eq!(
            *received.lock().unwrap(),
            [crate::RangingEvent::Measurement {
                peer_id: PeerId::from("peer"),
                distance_m: Some(2.4),
                direction_radians: None,
                observed_at_ms: 10,
            }]
        );
    }
}
