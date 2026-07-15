//! Platform-neutral BLE control-plane capability.
//!
//! Product control messages and their BLE wire protocol stay in Rust. Native
//! backends only own Core Bluetooth objects and move opaque, MTU-bounded
//! packets between stable integer handles.

mod ffi;

pub use ffi::{BluetoothBackend, BluetoothBackendError, BluetoothEventSink};
pub use protocol::BluetoothControlMessage;

use model::{PeerId, RequestId};
use protocol::{
    BluetoothControlAction, BluetoothControlCodec, BLUETOOTH_DEFAULT_PACKET_BYTES,
    BLUETOOTH_MAX_CONTROL_PAYLOAD_BYTES,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, Weak};
use tracing::{debug, debug_span, error, warn, Span};

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(transparent)]
pub struct PeerHandle(pub u64);

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct BluetoothCapabilities {
    pub central: bool,
    pub peripheral: bool,
    pub state_restoration: bool,
    pub background_control: bool,
    /// Conservative maximum size of one packet accepted by the native
    /// backend. Rust performs fragmentation before crossing UniFFI.
    pub max_packet_bytes: u32,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub enum BluetoothCommand {
    Start {
        request_id: RequestId,
    },
    Stop {
        request_id: RequestId,
    },
    Connect {
        request_id: RequestId,
        peer_id: PeerId,
        handle: PeerHandle,
    },
    Disconnect {
        request_id: RequestId,
        handle: PeerHandle,
    },
    SendControl {
        request_id: RequestId,
        handle: PeerHandle,
        message: BluetoothControlMessage,
        expires_at_ms: i64,
    },
}

impl BluetoothCommand {
    #[must_use]
    pub fn request_id(&self) -> &RequestId {
        match self {
            Self::Start { request_id }
            | Self::Stop { request_id }
            | Self::Connect { request_id, .. }
            | Self::Disconnect { request_id, .. }
            | Self::SendControl { request_id, .. } => request_id,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub enum BluetoothEvent {
    Started {
        request_id: RequestId,
    },
    Stopped {
        request_id: RequestId,
    },
    PeerDiscovered {
        peer_id: PeerId,
        handle: PeerHandle,
    },
    Connected {
        request_id: RequestId,
        handle: PeerHandle,
        max_packet_bytes: u32,
    },
    Disconnected {
        handle: PeerHandle,
        reason: String,
    },
    ControlReceived {
        handle: PeerHandle,
        message: BluetoothControlMessage,
    },
    /// The remote Rust codec acknowledged the logical control message.
    ControlSent {
        request_id: RequestId,
    },
    Failed {
        request_id: Option<RequestId>,
        code: String,
        message: String,
        retryable: bool,
    },
}

/// Commands visible to a platform BLE backend and to its fake. There are no
/// product control kinds here: `SendPacket` carries an already framed packet.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BluetoothBackendCommand {
    Start {
        request_id: RequestId,
    },
    Stop {
        request_id: RequestId,
    },
    Connect {
        request_id: RequestId,
        handle: PeerHandle,
    },
    Disconnect {
        request_id: RequestId,
        handle: PeerHandle,
    },
    SendPacket {
        request_id: RequestId,
        handle: PeerHandle,
        packet: Vec<u8>,
    },
}

/// Events produced by a platform BLE backend before the Rust wire codec.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BluetoothBackendEvent {
    Started {
        request_id: RequestId,
    },
    Stopped {
        request_id: RequestId,
    },
    PeerDiscovered {
        peer_id: PeerId,
        handle: PeerHandle,
    },
    Connected {
        request_id: RequestId,
        handle: PeerHandle,
        max_packet_bytes: u32,
    },
    Disconnected {
        handle: PeerHandle,
        reason: String,
    },
    PacketReceived {
        handle: PeerHandle,
        packet: Vec<u8>,
    },
    PacketSent {
        request_id: RequestId,
    },
    Failed {
        request_id: Option<RequestId>,
        code: String,
        message: String,
        retryable: bool,
    },
}

pub struct FakeBluetoothBackend {
    capabilities: BluetoothCapabilities,
    state: Mutex<FakeBluetoothState>,
}

#[derive(Default)]
struct FakeBluetoothState {
    commands: Vec<BluetoothBackendCommand>,
    event_sink: Option<Arc<BluetoothEventSink>>,
    is_shutdown: bool,
}

impl Default for FakeBluetoothBackend {
    fn default() -> Self {
        Self {
            capabilities: BluetoothCapabilities {
                central: true,
                peripheral: true,
                state_restoration: true,
                background_control: true,
                max_packet_bytes: BLUETOOTH_DEFAULT_PACKET_BYTES as u32,
            },
            state: Mutex::new(FakeBluetoothState::default()),
        }
    }
}

impl FakeBluetoothBackend {
    pub fn inject(&self, event: BluetoothBackendEvent) -> Result<(), BluetoothBackendError> {
        let event_sink = {
            let state = self.state.lock().expect("fake Bluetooth state poisoned");
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

    fn record(&self, command: BluetoothBackendCommand) -> Result<(), BluetoothBackendError> {
        let mut state = self.state.lock().expect("fake Bluetooth state poisoned");
        if state.is_shutdown {
            return Err(backend_error("backend is shut down"));
        }
        state.commands.push(command);
        Ok(())
    }

    #[must_use]
    pub fn commands(&self) -> Vec<BluetoothBackendCommand> {
        self.state
            .lock()
            .expect("fake Bluetooth state poisoned")
            .commands
            .clone()
    }
}

impl BluetoothBackend for FakeBluetoothBackend {
    fn capabilities(&self) -> Result<BluetoothCapabilities, BluetoothBackendError> {
        Ok(self.capabilities.clone())
    }

    fn attach_event_sink(
        &self,
        event_sink: Arc<BluetoothEventSink>,
    ) -> Result<(), BluetoothBackendError> {
        let mut state = self.state.lock().expect("fake Bluetooth state poisoned");
        if state.is_shutdown {
            return Err(backend_error("backend is shut down"));
        }
        state.event_sink = Some(event_sink);
        Ok(())
    }

    fn start(&self, request_id: String) -> Result<(), BluetoothBackendError> {
        self.record(BluetoothBackendCommand::Start {
            request_id: RequestId::from_string(request_id),
        })
    }

    fn stop(&self, request_id: String) -> Result<(), BluetoothBackendError> {
        self.record(BluetoothBackendCommand::Stop {
            request_id: RequestId::from_string(request_id),
        })
    }

    fn connect(&self, request_id: String, handle: u64) -> Result<(), BluetoothBackendError> {
        self.record(BluetoothBackendCommand::Connect {
            request_id: RequestId::from_string(request_id),
            handle: PeerHandle(handle),
        })
    }

    fn disconnect(&self, request_id: String, handle: u64) -> Result<(), BluetoothBackendError> {
        self.record(BluetoothBackendCommand::Disconnect {
            request_id: RequestId::from_string(request_id),
            handle: PeerHandle(handle),
        })
    }

    fn send_packet(
        &self,
        request_id: String,
        handle: u64,
        packet: Vec<u8>,
    ) -> Result<(), BluetoothBackendError> {
        self.record(BluetoothBackendCommand::SendPacket {
            request_id: RequestId::from_string(request_id),
            handle: PeerHandle(handle),
            packet,
        })
    }

    fn shutdown(&self) -> Result<(), BluetoothBackendError> {
        let mut state = self.state.lock().expect("fake Bluetooth state poisoned");
        state.is_shutdown = true;
        state.event_sink = None;
        Ok(())
    }
}

type BluetoothHandler = Arc<dyn Fn(BluetoothEvent) + Send + Sync + 'static>;

#[derive(Default)]
struct BluetoothRuntimeState {
    codec: BluetoothControlCodec,
    handler: Option<BluetoothHandler>,
    /// Per-link packet limit reported after Core Bluetooth negotiates ATT MTU.
    packet_bytes_by_handle: HashMap<PeerHandle, usize>,
    /// Keeps the logical control span alive until a remote ACK or terminal
    /// backend failure arrives.
    control_spans: HashMap<RequestId, Span>,
    /// Maps native packet request IDs back to both their logical control
    /// request and tracing context. `None` represents an internally generated
    /// ACK packet.
    packet_requests: HashMap<RequestId, PendingPacketRequest>,
}

struct PendingPacketRequest {
    logical_request: Option<RequestId>,
    span: Span,
}

/// Rust-side module runtime between domain commands and the raw native BLE
/// backend. This is where the BLE control wire protocol terminates.
pub struct BluetoothRuntime {
    backend: Arc<dyn BluetoothBackend>,
    state: Mutex<BluetoothRuntimeState>,
}

impl BluetoothRuntime {
    #[must_use]
    pub fn new(backend: Arc<dyn BluetoothBackend>) -> Arc<Self> {
        Arc::new(Self {
            backend,
            state: Mutex::new(BluetoothRuntimeState::default()),
        })
    }

    pub fn attach_event_handler(
        self: &Arc<Self>,
        handler: BluetoothHandler,
    ) -> Result<(), BluetoothBackendError> {
        self.state
            .lock()
            .map_err(|_| backend_error("Bluetooth runtime state is poisoned"))?
            .handler = Some(handler);
        let weak = Arc::downgrade(self);
        self.backend
            .attach_event_sink(BluetoothEventSink::new(Arc::new(move |event| {
                if let Some(runtime) = Weak::upgrade(&weak) {
                    runtime.handle_backend_event(event);
                }
            })))
    }

    pub fn dispatch(
        &self,
        command: BluetoothCommand,
        now_ms: i64,
    ) -> Result<(), BluetoothBackendError> {
        match command {
            BluetoothCommand::Start { request_id } => self.backend.start(request_id.to_string()),
            BluetoothCommand::Stop { request_id } => self.backend.stop(request_id.to_string()),
            BluetoothCommand::Connect {
                request_id, handle, ..
            } => self.backend.connect(request_id.to_string(), handle.0),
            BluetoothCommand::Disconnect { request_id, handle } => {
                self.backend.disconnect(request_id.to_string(), handle.0)
            }
            BluetoothCommand::SendControl {
                request_id,
                handle,
                message,
                expires_at_ms,
            } => {
                let kind = control_kind(&message);
                let payload_bytes = message.payload().len();
                let control_span = debug_span!(
                    "bluetooth.control",
                    subsystem = "bluetooth",
                    direction = "outbound",
                    request_id = %request_id,
                    handle = handle.0,
                    kind,
                    payload_bytes,
                    payload_limit_bytes = BLUETOOTH_MAX_CONTROL_PAYLOAD_BYTES,
                );
                let _entered = control_span.enter();
                let maximum_packet_bytes = match self.maximum_packet_bytes(handle) {
                    Ok(value) => value,
                    Err(error) => {
                        error!(%error, "failed to determine BLE packet limit");
                        return Err(error);
                    }
                };
                debug!(maximum_packet_bytes, "encoding BLE control message");
                let packets = match self
                    .state
                    .lock()
                    .map_err(|_| backend_error("Bluetooth runtime state is poisoned"))?
                    .codec
                    .encode_control(
                        request_id.clone(),
                        message,
                        now_ms,
                        expires_at_ms,
                        maximum_packet_bytes,
                    ) {
                    Ok(packets) => packets,
                    Err(error) => {
                        error!(%error, "failed to encode BLE control message");
                        return Err(protocol_error(error));
                    }
                };
                debug!(
                    packet_count = packets.len(),
                    maximum_packet_bytes, "encoded BLE control message"
                );
                self.state
                    .lock()
                    .map_err(|_| backend_error("Bluetooth runtime state is poisoned"))?
                    .control_spans
                    .insert(request_id.clone(), control_span.clone());
                if let Err(error) = self.send_packets(handle, packets, Some(request_id.clone())) {
                    if let Ok(mut state) = self.state.lock() {
                        state.codec.cancel(&request_id);
                        state.control_spans.remove(&request_id);
                    }
                    error!(%error, "failed to dispatch BLE control packets");
                    return Err(error);
                }
                Ok(())
            }
        }
    }

    pub fn shutdown(&self) -> Result<(), BluetoothBackendError> {
        if let Ok(mut state) = self.state.lock() {
            state.handler = None;
            state.control_spans.clear();
            state.packet_requests.clear();
            state.packet_bytes_by_handle.clear();
        }
        self.backend.shutdown()
    }

    fn maximum_packet_bytes(&self, handle: PeerHandle) -> Result<usize, BluetoothBackendError> {
        let advertised = self.backend.capabilities()?.max_packet_bytes as usize;
        if advertised == 0 {
            return Err(backend_error(
                "Bluetooth backend advertised a zero packet size",
            ));
        }
        let negotiated = self
            .state
            .lock()
            .map_err(|_| backend_error("Bluetooth runtime state is poisoned"))?
            .packet_bytes_by_handle
            .get(&handle)
            .copied()
            .unwrap_or(advertised);
        Ok(negotiated
            .min(advertised)
            .min(BLUETOOTH_DEFAULT_PACKET_BYTES))
    }

    fn send_packets(
        &self,
        handle: PeerHandle,
        packets: Vec<Vec<u8>>,
        logical_request: Option<RequestId>,
    ) -> Result<(), BluetoothBackendError> {
        let packet_count = packets.len();
        for (packet_index, packet) in packets.into_iter().enumerate() {
            let packet_request = RequestId::new();
            let packet_bytes = packet.len();
            let parent_span = logical_request.as_ref().and_then(|request_id| {
                self.state
                    .lock()
                    .ok()
                    .and_then(|state| state.control_spans.get(request_id).cloned())
            });
            let packet_span = if let Some(parent_span) = parent_span {
                debug_span!(
                    parent: &parent_span,
                    "bluetooth.packet",
                    subsystem = "bluetooth",
                    direction = "outbound",
                    request_id = %packet_request,
                    packet_index,
                    packet_count,
                    packet_bytes,
                )
            } else {
                debug_span!(
                    "bluetooth.packet",
                    subsystem = "bluetooth",
                    direction = "outbound",
                    request_id = %packet_request,
                    packet_index,
                    packet_count,
                    packet_bytes,
                )
            };
            self.state
                .lock()
                .map_err(|_| backend_error("Bluetooth runtime state is poisoned"))?
                .packet_requests
                .insert(
                    packet_request.clone(),
                    PendingPacketRequest {
                        logical_request: logical_request.clone(),
                        span: packet_span.clone(),
                    },
                );
            let result = packet_span.in_scope(|| {
                debug!(
                    handle = handle.0,
                    "dispatching BLE packet to native backend"
                );
                self.backend
                    .send_packet(packet_request.to_string(), handle.0, packet)
            });
            if let Err(error) = result {
                if let Ok(mut state) = self.state.lock() {
                    state.packet_requests.remove(&packet_request);
                }
                packet_span.in_scope(|| {
                    error!(%error, "native BLE backend rejected packet");
                });
                return Err(error);
            }
        }
        Ok(())
    }

    fn handle_backend_event(&self, event: BluetoothBackendEvent) {
        match event {
            BluetoothBackendEvent::Started { request_id } => {
                self.emit(BluetoothEvent::Started { request_id });
            }
            BluetoothBackendEvent::Stopped { request_id } => {
                self.emit(BluetoothEvent::Stopped { request_id });
            }
            BluetoothBackendEvent::PeerDiscovered { peer_id, handle } => {
                self.emit(BluetoothEvent::PeerDiscovered { peer_id, handle });
            }
            BluetoothBackendEvent::Connected {
                request_id,
                handle,
                max_packet_bytes,
            } => {
                if let Ok(mut state) = self.state.lock() {
                    state
                        .packet_bytes_by_handle
                        .insert(handle, max_packet_bytes as usize);
                }
                self.emit(BluetoothEvent::Connected {
                    request_id,
                    handle,
                    max_packet_bytes,
                });
            }
            BluetoothBackendEvent::Disconnected { handle, reason } => {
                if let Ok(mut state) = self.state.lock() {
                    state.codec.remove_peer(handle.0);
                    state.packet_bytes_by_handle.remove(&handle);
                }
                self.emit(BluetoothEvent::Disconnected { handle, reason });
            }
            BluetoothBackendEvent::PacketReceived { handle, packet } => {
                self.handle_packet(handle, packet);
            }
            BluetoothBackendEvent::PacketSent { request_id } => {
                let pending = self
                    .state
                    .lock()
                    .ok()
                    .and_then(|mut state| state.packet_requests.remove(&request_id));
                if let Some(pending) = pending {
                    pending.span.in_scope(|| {
                        debug!("native BLE backend accepted packet");
                    });
                } else {
                    warn!(%request_id, "received completion for unknown BLE packet request");
                }
            }
            BluetoothBackendEvent::Failed {
                request_id,
                code,
                message,
                retryable,
            } => {
                let mut packet_span = None;
                let mut control_span = None;
                let request_id = request_id.and_then(|request_id| {
                    let mapped = self.state.lock().ok().and_then(|mut state| {
                        state.packet_requests.remove(&request_id).map(|pending| {
                            packet_span = Some(pending.span);
                            if let Some(logical_request) = pending.logical_request.as_ref() {
                                control_span = state.control_spans.remove(logical_request);
                            }
                            pending.logical_request
                        })
                    });
                    match mapped {
                        Some(logical) => logical,
                        None => Some(request_id),
                    }
                });
                if let Some(span) = packet_span {
                    span.in_scope(|| {
                        error!(
                            %code,
                            %message,
                            retryable,
                            "native BLE backend reported packet failure"
                        );
                    });
                }
                if let Some(span) = control_span {
                    span.in_scope(|| {
                        error!(
                            %code,
                            %message,
                            retryable,
                            "BLE control failed in native backend"
                        );
                    });
                } else {
                    error!(
                        request_id = ?request_id,
                        %code,
                        %message,
                        retryable,
                        "Bluetooth backend reported failure"
                    );
                }
                self.emit(BluetoothEvent::Failed {
                    request_id,
                    code,
                    message,
                    retryable,
                });
            }
        }
    }

    fn handle_packet(&self, handle: PeerHandle, packet: Vec<u8>) {
        let maximum_packet_bytes = match self.maximum_packet_bytes(handle) {
            Ok(value) => value,
            Err(error) => {
                self.emit_failure(None, "capabilityError", error.to_string(), false);
                return;
            }
        };
        let now_ms = unix_now_ms();
        let actions = match self
            .state
            .lock()
            .map_err(|_| backend_error("Bluetooth runtime state is poisoned"))
            .and_then(|mut state| {
                state
                    .codec
                    .ingest_packet(handle.0, &packet, now_ms, maximum_packet_bytes)
                    .map_err(protocol_error)
            }) {
            Ok(actions) => actions,
            Err(error) => {
                let prefix = packet
                    .iter()
                    .take(3)
                    .map(|byte| format!("{byte:02x}"))
                    .collect::<Vec<_>>()
                    .join("");
                self.emit_failure(
                    None,
                    "transportError",
                    format!("{error}; packetBytes={}, prefix={prefix}", packet.len()),
                    true,
                );
                return;
            }
        };
        for action in actions {
            match action {
                BluetoothControlAction::ControlReceived {
                    peer_handle,
                    message,
                } => self.emit(BluetoothEvent::ControlReceived {
                    handle: PeerHandle(peer_handle),
                    message,
                }),
                BluetoothControlAction::SendPacket {
                    peer_handle,
                    packet,
                } => {
                    if let Err(error) =
                        self.send_packets(PeerHandle(peer_handle), vec![packet], None)
                    {
                        self.emit_failure(None, "ackFailed", error.to_string(), true);
                    }
                }
                BluetoothControlAction::ControlAcknowledged { request_id } => {
                    let span = self
                        .state
                        .lock()
                        .ok()
                        .and_then(|mut state| state.control_spans.remove(&request_id));
                    if let Some(span) = span {
                        span.in_scope(|| {
                            debug!("remote peer acknowledged BLE control message");
                        });
                    } else {
                        debug!(%request_id, "remote peer acknowledged BLE control message");
                    }
                    self.emit(BluetoothEvent::ControlSent { request_id });
                }
                BluetoothControlAction::Expired { message_id, .. } => self.emit_failure(
                    None,
                    "controlExpired",
                    format!("BLE control message {message_id} expired"),
                    false,
                ),
            }
        }
    }

    fn emit(&self, event: BluetoothEvent) {
        let handler = self
            .state
            .lock()
            .ok()
            .and_then(|state| state.handler.clone());
        if let Some(handler) = handler {
            handler(event);
        }
    }

    fn emit_failure(
        &self,
        request_id: Option<RequestId>,
        code: impl Into<String>,
        message: impl Into<String>,
        retryable: bool,
    ) {
        self.emit(BluetoothEvent::Failed {
            request_id,
            code: code.into(),
            message: message.into(),
            retryable,
        });
    }
}

fn control_kind(message: &BluetoothControlMessage) -> &'static str {
    match message {
        BluetoothControlMessage::InvitationInfo { .. } => "invitationInfo",
        BluetoothControlMessage::JoinHello { .. } => "joinHello",
        BluetoothControlMessage::JoinResponse { .. } => "joinResponse",
        BluetoothControlMessage::JoinConfirmation { .. } => "joinConfirmation",
        BluetoothControlMessage::GroupControl { .. } => "groupControl",
    }
}

fn unix_now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};

    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| {
            i64::try_from(duration.as_millis()).unwrap_or(i64::MAX)
        })
}

fn protocol_error(error: impl std::fmt::Display) -> BluetoothBackendError {
    BluetoothBackendError::Protocol {
        message: error.to_string(),
    }
}

fn backend_error(error: impl std::fmt::Display) -> BluetoothBackendError {
    BluetoothBackendError::Backend {
        message: error.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fake_backend_records_only_platform_packet_operations() {
        let backend = FakeBluetoothBackend::default();
        let sink = BluetoothEventSink::new(Arc::new(|_| {}));
        backend.attach_event_sink(sink).unwrap();
        backend
            .send_packet("packet-one".into(), 4, vec![1, 2, 3])
            .unwrap();
        assert_eq!(
            backend.commands(),
            [BluetoothBackendCommand::SendPacket {
                request_id: RequestId::from("packet-one"),
                handle: PeerHandle(4),
                packet: vec![1, 2, 3],
            }]
        );
    }

    #[test]
    fn runtime_materializes_control_and_ack_entirely_in_rust() {
        let sender_backend = Arc::new(FakeBluetoothBackend::default());
        let receiver_backend = Arc::new(FakeBluetoothBackend::default());
        let sender = BluetoothRuntime::new(sender_backend.clone());
        let receiver = BluetoothRuntime::new(receiver_backend.clone());
        let sender_events = Arc::new(Mutex::new(Vec::new()));
        let receiver_events = Arc::new(Mutex::new(Vec::new()));
        let sender_events_for_handler = sender_events.clone();
        sender
            .attach_event_handler(Arc::new(move |event| {
                sender_events_for_handler.lock().unwrap().push(event);
            }))
            .unwrap();
        let receiver_events_for_handler = receiver_events.clone();
        receiver
            .attach_event_handler(Arc::new(move |event| {
                receiver_events_for_handler.lock().unwrap().push(event);
            }))
            .unwrap();

        let logical_request = RequestId::new();
        let message = BluetoothControlMessage::JoinHello {
            payload: vec![9; 500],
        };
        let now_ms = unix_now_ms();
        sender
            .dispatch(
                BluetoothCommand::SendControl {
                    request_id: logical_request.clone(),
                    handle: PeerHandle(8),
                    message: message.clone(),
                    expires_at_ms: now_ms.saturating_add(10_000),
                },
                now_ms,
            )
            .unwrap();
        assert!(sender
            .state
            .lock()
            .unwrap()
            .control_spans
            .contains_key(&logical_request));

        let packets: Vec<_> = sender_backend
            .commands()
            .into_iter()
            .filter_map(|command| match command {
                BluetoothBackendCommand::SendPacket { packet, .. } => Some(packet),
                _ => None,
            })
            .collect();
        assert!(packets.len() > 1);
        for packet in packets {
            receiver_backend
                .inject(BluetoothBackendEvent::PacketReceived {
                    handle: PeerHandle(8),
                    packet,
                })
                .unwrap();
        }
        assert!(receiver_events
            .lock()
            .unwrap()
            .contains(&BluetoothEvent::ControlReceived {
                handle: PeerHandle(8),
                message,
            }));

        let ack = receiver_backend
            .commands()
            .into_iter()
            .find_map(|command| match command {
                BluetoothBackendCommand::SendPacket { packet, .. } => Some(packet),
                _ => None,
            })
            .expect("receiver generated ACK packet");
        sender_backend
            .inject(BluetoothBackendEvent::PacketReceived {
                handle: PeerHandle(8),
                packet: ack,
            })
            .unwrap();
        assert!(sender_events
            .lock()
            .unwrap()
            .contains(&BluetoothEvent::ControlSent {
                request_id: logical_request.clone(),
            }));
        assert!(!sender
            .state
            .lock()
            .unwrap()
            .control_spans
            .contains_key(&logical_request));
    }

    #[test]
    fn packet_completion_restores_and_releases_its_span() {
        let backend = Arc::new(FakeBluetoothBackend::default());
        let runtime = BluetoothRuntime::new(backend.clone());
        runtime.attach_event_handler(Arc::new(|_| {})).unwrap();
        let logical_request = RequestId::new();
        let now_ms = unix_now_ms();
        runtime
            .dispatch(
                BluetoothCommand::SendControl {
                    request_id: logical_request.clone(),
                    handle: PeerHandle(9),
                    message: BluetoothControlMessage::JoinConfirmation {
                        payload: vec![1, 2, 3],
                    },
                    expires_at_ms: now_ms.saturating_add(10_000),
                },
                now_ms,
            )
            .unwrap();

        let packet_request = backend
            .commands()
            .into_iter()
            .find_map(|command| match command {
                BluetoothBackendCommand::SendPacket { request_id, .. } => Some(request_id),
                _ => None,
            })
            .expect("control message generated a packet");
        {
            let state = runtime.state.lock().unwrap();
            assert!(state.packet_requests.contains_key(&packet_request));
            assert!(state.control_spans.contains_key(&logical_request));
        }

        backend
            .inject(BluetoothBackendEvent::PacketSent {
                request_id: packet_request.clone(),
            })
            .unwrap();

        let state = runtime.state.lock().unwrap();
        assert!(!state.packet_requests.contains_key(&packet_request));
        assert!(state.control_spans.contains_key(&logical_request));
    }

    #[test]
    fn oversized_control_is_rejected_before_retaining_spans_or_dispatching_packets() {
        let backend = Arc::new(FakeBluetoothBackend::default());
        let runtime = BluetoothRuntime::new(backend.clone());
        runtime.attach_event_handler(Arc::new(|_| {})).unwrap();
        let logical_request = RequestId::new();
        let now_ms = unix_now_ms();

        let error = runtime
            .dispatch(
                BluetoothCommand::SendControl {
                    request_id: logical_request.clone(),
                    handle: PeerHandle(10),
                    message: BluetoothControlMessage::JoinResponse {
                        payload: vec![0; BLUETOOTH_MAX_CONTROL_PAYLOAD_BYTES + 1],
                    },
                    expires_at_ms: now_ms.saturating_add(10_000),
                },
                now_ms,
            )
            .unwrap_err();

        assert!(matches!(error, BluetoothBackendError::Protocol { .. }));
        let state = runtime.state.lock().unwrap();
        assert!(!state.control_spans.contains_key(&logical_request));
        assert!(state.packet_requests.is_empty());
        assert!(backend.commands().is_empty());
    }

    #[test]
    fn runtime_fragments_using_the_negotiated_peer_packet_limit() {
        let backend = Arc::new(FakeBluetoothBackend::default());
        let runtime = BluetoothRuntime::new(backend.clone());
        runtime.attach_event_handler(Arc::new(|_| {})).unwrap();
        let connection_request = RequestId::new();
        backend
            .inject(BluetoothBackendEvent::Connected {
                request_id: connection_request,
                handle: PeerHandle(12),
                max_packet_bytes: 64,
            })
            .unwrap();

        let now_ms = unix_now_ms();
        runtime
            .dispatch(
                BluetoothCommand::SendControl {
                    request_id: RequestId::new(),
                    handle: PeerHandle(12),
                    message: BluetoothControlMessage::JoinHello {
                        payload: vec![7; 300],
                    },
                    expires_at_ms: now_ms.saturating_add(10_000),
                },
                now_ms,
            )
            .unwrap();

        let packets = backend
            .commands()
            .into_iter()
            .filter_map(|command| match command {
                BluetoothBackendCommand::SendPacket { packet, .. } => Some(packet),
                _ => None,
            });
        assert!(packets.count() > 1);
        assert!(backend.commands().into_iter().all(|command| match command {
            BluetoothBackendCommand::SendPacket { packet, .. } => packet.len() <= 64,
            _ => true,
        }));
    }
}

uniffi::setup_scaffolding!();
