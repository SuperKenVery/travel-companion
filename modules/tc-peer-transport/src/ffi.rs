//! Raw frame-oriented UniFFI contract implemented by platform and fake
//! backends. Group authentication and application wire messages stay in Rust.

use std::sync::Arc;
use thiserror::Error;

#[derive(Debug, Error, uniffi::Error)]
pub enum PeerTransportBackendError {
    #[error("backend rejected operation: {message}")]
    Backend { message: String },
    #[error("peer transport protocol rejected operation: {message}")]
    Protocol { message: String },
    #[error("unexpected UniFFI callback failure: {message}")]
    Callback { message: String },
}

impl From<uniffi::UnexpectedUniFFICallbackError> for PeerTransportBackendError {
    fn from(error: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Callback {
            message: error.to_string(),
        }
    }
}

#[derive(uniffi::Object)]
pub struct PeerTransportEventSink {
    handler: Arc<dyn Fn(crate::TransportBackendEvent) + Send + Sync + 'static>,
}

impl PeerTransportEventSink {
    #[must_use]
    pub fn new(
        handler: Arc<dyn Fn(crate::TransportBackendEvent) + Send + Sync + 'static>,
    ) -> Arc<Self> {
        Arc::new(Self { handler })
    }

    pub(crate) fn emit(&self, event: crate::TransportBackendEvent) {
        (self.handler)(event);
    }
}

#[uniffi::export]
impl PeerTransportEventSink {
    pub fn discovery_started(&self, request_id: String) {
        self.emit(crate::TransportBackendEvent::DiscoveryStarted {
            request_id: tc_model::RequestId::from_string(request_id),
        });
    }

    pub fn discovery_stopped(&self, request_id: String) {
        self.emit(crate::TransportBackendEvent::DiscoveryStopped {
            request_id: tc_model::RequestId::from_string(request_id),
        });
    }

    pub fn peer_found(&self, peer_id: String) {
        self.emit(crate::TransportBackendEvent::PeerFound {
            peer_id: tc_model::PeerId::from_string(peer_id),
        });
    }

    pub fn connection_opened(
        &self,
        connection: u64,
        source: crate::TransportConnectionSource,
        expected_peer_id: Option<String>,
    ) {
        self.emit(crate::TransportBackendEvent::ConnectionOpened {
            connection: crate::ConnectionHandle(connection),
            source,
            expected_peer_id: expected_peer_id.map(tc_model::PeerId::from_string),
        });
    }

    pub fn disconnected(&self, connection: u64, reason: String) {
        self.emit(crate::TransportBackendEvent::Disconnected {
            connection: crate::ConnectionHandle(connection),
            reason,
        });
    }

    pub fn frame_received(
        &self,
        connection: u64,
        channel: crate::TransportChannel,
        bytes: Vec<u8>,
    ) {
        self.emit(crate::TransportBackendEvent::FrameReceived {
            connection: crate::ConnectionHandle(connection),
            channel,
            bytes,
        });
    }

    pub fn sent(&self, request_id: String) {
        self.emit(crate::TransportBackendEvent::Sent {
            request_id: tc_model::RequestId::from_string(request_id),
        });
    }

    pub fn failed(
        &self,
        request_id: Option<String>,
        code: String,
        message: String,
        retryable: bool,
    ) {
        self.emit(crate::TransportBackendEvent::Failed {
            request_id: request_id.map(tc_model::RequestId::from_string),
            code,
            message,
            retryable,
        });
    }
}

#[uniffi::export(foreign)]
pub trait PeerTransportBackend: Send + Sync {
    fn capabilities(&self) -> Result<crate::TransportCapabilities, PeerTransportBackendError>;

    fn attach_event_sink(
        &self,
        event_sink: Arc<PeerTransportEventSink>,
    ) -> Result<(), PeerTransportBackendError>;

    #[allow(clippy::too_many_arguments)]
    fn start_discovery(
        &self,
        request_id: String,
        local_peer_id: String,
        discovery_scope: String,
        display_name: String,
        protocol_version: u16,
        certificate_der: Vec<u8>,
        private_key_pkcs8: Vec<u8>,
    ) -> Result<(), PeerTransportBackendError>;

    fn stop_discovery(&self, request_id: String) -> Result<(), PeerTransportBackendError>;

    fn connect(&self, request_id: String, peer_id: String)
        -> Result<(), PeerTransportBackendError>;

    fn disconnect(
        &self,
        request_id: String,
        connection: u64,
    ) -> Result<(), PeerTransportBackendError>;

    fn send_frame(
        &self,
        request_id: String,
        connection: u64,
        channel: crate::TransportChannel,
        bytes: Vec<u8>,
    ) -> Result<(), PeerTransportBackendError>;

    fn set_realtime(
        &self,
        request_id: String,
        realtime: bool,
    ) -> Result<(), PeerTransportBackendError>;

    fn shutdown(&self) -> Result<(), PeerTransportBackendError>;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    #[test]
    fn event_sink_constructs_raw_frame_events() {
        let received = Arc::new(Mutex::new(Vec::new()));
        let received_by_handler = Arc::clone(&received);
        let sink = PeerTransportEventSink::new(Arc::new(move |event| {
            received_by_handler.lock().unwrap().push(event);
        }));

        sink.frame_received(9, crate::TransportChannel::Audio, vec![1, 2, 3]);

        assert_eq!(
            *received.lock().unwrap(),
            [crate::TransportBackendEvent::FrameReceived {
                connection: crate::ConnectionHandle(9),
                channel: crate::TransportChannel::Audio,
                bytes: vec![1, 2, 3],
            }]
        );
    }
}
