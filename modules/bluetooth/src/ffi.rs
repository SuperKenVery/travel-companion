//! Raw packet-oriented UniFFI contract implemented by platform and fake BLE
//! backends. Product control messages and the BLE wire protocol stay in Rust.

use std::sync::Arc;
use thiserror::Error;

#[derive(Debug, Error, uniffi::Error)]
pub enum BluetoothBackendError {
    #[error("backend rejected operation: {message}")]
    Backend { message: String },
    #[error("Bluetooth protocol rejected operation: {message}")]
    Protocol { message: String },
    #[error("unexpected UniFFI callback failure: {message}")]
    Callback { message: String },
}

impl From<uniffi::UnexpectedUniFFICallbackError> for BluetoothBackendError {
    fn from(error: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Callback {
            message: error.to_string(),
        }
    }
}

#[derive(uniffi::Object)]
pub struct BluetoothEventSink {
    handler: Arc<dyn Fn(crate::BluetoothBackendEvent) + Send + Sync + 'static>,
}

impl BluetoothEventSink {
    #[must_use]
    pub fn new(
        handler: Arc<dyn Fn(crate::BluetoothBackendEvent) + Send + Sync + 'static>,
    ) -> Arc<Self> {
        Arc::new(Self { handler })
    }

    pub(crate) fn emit(&self, event: crate::BluetoothBackendEvent) {
        (self.handler)(event);
    }
}

#[uniffi::export]
impl BluetoothEventSink {
    pub fn started(&self, request_id: String) {
        self.emit(crate::BluetoothBackendEvent::Started {
            request_id: model::RequestId::from_string(request_id),
        });
    }

    pub fn stopped(&self, request_id: String) {
        self.emit(crate::BluetoothBackendEvent::Stopped {
            request_id: model::RequestId::from_string(request_id),
        });
    }

    pub fn peer_discovered(&self, peer_id: String, handle: u64) {
        self.emit(crate::BluetoothBackendEvent::PeerDiscovered {
            peer_id: model::PeerId::from_string(peer_id),
            handle: crate::PeerHandle(handle),
        });
    }

    pub fn connected(&self, request_id: String, handle: u64, max_packet_bytes: u32) {
        self.emit(crate::BluetoothBackendEvent::Connected {
            request_id: model::RequestId::from_string(request_id),
            handle: crate::PeerHandle(handle),
            max_packet_bytes,
        });
    }

    pub fn disconnected(&self, handle: u64, reason: String) {
        self.emit(crate::BluetoothBackendEvent::Disconnected {
            handle: crate::PeerHandle(handle),
            reason,
        });
    }

    pub fn packet_received(&self, handle: u64, packet: Vec<u8>) {
        self.emit(crate::BluetoothBackendEvent::PacketReceived {
            handle: crate::PeerHandle(handle),
            packet,
        });
    }

    pub fn packet_sent(&self, request_id: String) {
        self.emit(crate::BluetoothBackendEvent::PacketSent {
            request_id: model::RequestId::from_string(request_id),
        });
    }

    pub fn failed(
        &self,
        request_id: Option<String>,
        code: String,
        message: String,
        retryable: bool,
    ) {
        self.emit(crate::BluetoothBackendEvent::Failed {
            request_id: request_id.map(model::RequestId::from_string),
            code,
            message,
            retryable,
        });
    }
}

#[uniffi::export(foreign)]
pub trait BluetoothBackend: Send + Sync {
    fn capabilities(&self) -> Result<crate::BluetoothCapabilities, BluetoothBackendError>;

    fn attach_event_sink(
        &self,
        event_sink: Arc<BluetoothEventSink>,
    ) -> Result<(), BluetoothBackendError>;

    fn start(&self, request_id: String) -> Result<(), BluetoothBackendError>;

    fn stop(&self, request_id: String) -> Result<(), BluetoothBackendError>;

    fn connect(&self, request_id: String, handle: u64) -> Result<(), BluetoothBackendError>;

    fn disconnect(&self, request_id: String, handle: u64) -> Result<(), BluetoothBackendError>;

    fn send_packet(
        &self,
        request_id: String,
        handle: u64,
        packet: Vec<u8>,
    ) -> Result<(), BluetoothBackendError>;

    fn shutdown(&self) -> Result<(), BluetoothBackendError>;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    #[test]
    fn event_sink_constructs_raw_packet_events() {
        let received = Arc::new(Mutex::new(Vec::new()));
        let received_by_handler = Arc::clone(&received);
        let sink = BluetoothEventSink::new(Arc::new(move |event| {
            received_by_handler.lock().unwrap().push(event);
        }));

        sink.packet_received(9, vec![1, 2, 3]);

        assert_eq!(
            *received.lock().unwrap(),
            [crate::BluetoothBackendEvent::PacketReceived {
                handle: crate::PeerHandle(9),
                packet: vec![1, 2, 3],
            }]
        );
    }
}
