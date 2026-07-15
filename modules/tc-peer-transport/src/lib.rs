//! Local-only peer transport capability.
//!
//! Bonjour, TLS and Network.framework objects remain native. Group
//! authentication, connection admission and all application framing remain in
//! Rust; the native backend only opens scoped connections and moves opaque TLV
//! frames on integer handles.

mod ffi;

pub use ffi::{PeerTransportBackend, PeerTransportBackendError, PeerTransportEventSink};

use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, Weak};
use tc_model::{GroupId, PeerId, RequestId};
use uuid::Uuid;

const HELLO_MAGIC: &[u8; 4] = b"TCPH";
const HELLO_TAG_BYTES: usize = 32;
const DISCOVERY_SCOPE_LABEL: &[u8] = b"tc-peer-discovery-v1";

type HmacSha256 = Hmac<Sha256>;

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(transparent)]
pub struct ConnectionHandle(pub u64);

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct TransportCapabilities {
    pub local_only: bool,
    pub peer_to_peer: bool,
    pub authenticated_streams: bool,
    pub bulk_streams: bool,
    pub realtime_streams: bool,
    pub max_data_frame_bytes: u32,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize, uniffi::Enum)]
#[serde(rename_all = "camelCase")]
pub enum TrafficClass {
    EnergyEfficient,
    Bulk,
    RealtimeVoice,
}

/// Opaque TLV channel selected by Rust and implemented by the native
/// Network.framework backend.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize, uniffi::Enum)]
#[serde(rename_all = "camelCase")]
pub enum TransportChannel {
    Control,
    Event,
    Chunk,
    Audio,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize, uniffi::Enum)]
#[serde(rename_all = "camelCase")]
pub enum TransportConnectionSource {
    Inbound,
    Outbound,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub enum TransportCommand {
    StartDiscovery {
        request_id: RequestId,
        local_peer_id: PeerId,
        group_id: GroupId,
        display_name: String,
        protocol_version: u16,
        group_key: Vec<u8>,
        certificate_der: Vec<u8>,
        private_key_pkcs8: Vec<u8>,
    },
    StopDiscovery {
        request_id: RequestId,
    },
    Connect {
        request_id: RequestId,
        peer_id: PeerId,
    },
    Disconnect {
        request_id: RequestId,
        connection: ConnectionHandle,
    },
    SendData {
        request_id: RequestId,
        connection: ConnectionHandle,
        bytes: Vec<u8>,
        traffic_class: TrafficClass,
    },
    SetRealtime {
        request_id: RequestId,
        realtime: bool,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub enum TransportEvent {
    DiscoveryStarted {
        request_id: RequestId,
    },
    DiscoveryStopped {
        request_id: RequestId,
    },
    PeerFound {
        peer_id: PeerId,
    },
    Authenticated {
        connection: ConnectionHandle,
        peer_id: PeerId,
    },
    Disconnected {
        connection: ConnectionHandle,
        reason: String,
    },
    DataReceived {
        connection: ConnectionHandle,
        bytes: Vec<u8>,
    },
    Sent {
        request_id: RequestId,
    },
    Failed {
        request_id: Option<RequestId>,
        code: String,
        message: String,
        retryable: bool,
    },
}

/// Commands visible to the native backend and its fake. The discovery scope
/// is an opaque HMAC-derived token, never the product group ID or group key.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TransportBackendCommand {
    StartDiscovery {
        request_id: RequestId,
        local_peer_id: PeerId,
        discovery_scope: String,
        display_name: String,
        protocol_version: u16,
        certificate_der: Vec<u8>,
        private_key_pkcs8: Vec<u8>,
    },
    StopDiscovery {
        request_id: RequestId,
    },
    Connect {
        request_id: RequestId,
        peer_id: PeerId,
    },
    Disconnect {
        request_id: RequestId,
        connection: ConnectionHandle,
    },
    SendFrame {
        request_id: RequestId,
        connection: ConnectionHandle,
        channel: TransportChannel,
        bytes: Vec<u8>,
    },
    SetRealtime {
        request_id: RequestId,
        realtime: bool,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TransportBackendEvent {
    DiscoveryStarted {
        request_id: RequestId,
    },
    DiscoveryStopped {
        request_id: RequestId,
    },
    PeerFound {
        peer_id: PeerId,
    },
    ConnectionOpened {
        connection: ConnectionHandle,
        source: TransportConnectionSource,
        expected_peer_id: Option<PeerId>,
    },
    Disconnected {
        connection: ConnectionHandle,
        reason: String,
    },
    FrameReceived {
        connection: ConnectionHandle,
        channel: TransportChannel,
        bytes: Vec<u8>,
    },
    Sent {
        request_id: RequestId,
    },
    Failed {
        request_id: Option<RequestId>,
        code: String,
        message: String,
        retryable: bool,
    },
}

pub struct FakePeerTransportBackend {
    capabilities: TransportCapabilities,
    state: Mutex<FakePeerTransportState>,
}

#[derive(Default)]
struct FakePeerTransportState {
    commands: Vec<TransportBackendCommand>,
    event_sink: Option<Arc<PeerTransportEventSink>>,
    is_shutdown: bool,
}

impl Default for FakePeerTransportBackend {
    fn default() -> Self {
        Self {
            capabilities: TransportCapabilities {
                local_only: true,
                peer_to_peer: true,
                authenticated_streams: true,
                bulk_streams: true,
                realtime_streams: true,
                max_data_frame_bytes: 8 * 1024 * 1024,
            },
            state: Mutex::new(FakePeerTransportState::default()),
        }
    }
}

impl FakePeerTransportBackend {
    pub fn inject(&self, event: TransportBackendEvent) -> Result<(), PeerTransportBackendError> {
        let sink = {
            let state = self.state.lock().map_err(|_| backend_state_poisoned())?;
            if state.is_shutdown {
                return Err(backend_is_shutdown());
            }
            state
                .event_sink
                .clone()
                .ok_or_else(|| backend_error("peer transport event sink is not attached"))?
        };
        sink.emit(event);
        Ok(())
    }

    fn record(&self, command: TransportBackendCommand) -> Result<(), PeerTransportBackendError> {
        let mut state = self.state.lock().map_err(|_| backend_state_poisoned())?;
        if state.is_shutdown {
            return Err(backend_is_shutdown());
        }
        state.commands.push(command);
        Ok(())
    }

    #[must_use]
    pub fn commands(&self) -> Vec<TransportBackendCommand> {
        self.state
            .lock()
            .expect("fake peer transport state poisoned")
            .commands
            .clone()
    }
}

impl PeerTransportBackend for FakePeerTransportBackend {
    fn capabilities(&self) -> Result<TransportCapabilities, PeerTransportBackendError> {
        Ok(self.capabilities.clone())
    }

    fn attach_event_sink(
        &self,
        event_sink: Arc<PeerTransportEventSink>,
    ) -> Result<(), PeerTransportBackendError> {
        let mut state = self.state.lock().map_err(|_| backend_state_poisoned())?;
        if state.is_shutdown {
            return Err(backend_is_shutdown());
        }
        state.event_sink = Some(event_sink);
        Ok(())
    }

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
    ) -> Result<(), PeerTransportBackendError> {
        self.record(TransportBackendCommand::StartDiscovery {
            request_id: RequestId::from_string(request_id),
            local_peer_id: PeerId::from_string(local_peer_id),
            discovery_scope,
            display_name,
            protocol_version,
            certificate_der,
            private_key_pkcs8,
        })
    }

    fn stop_discovery(&self, request_id: String) -> Result<(), PeerTransportBackendError> {
        self.record(TransportBackendCommand::StopDiscovery {
            request_id: RequestId::from_string(request_id),
        })
    }

    fn connect(
        &self,
        request_id: String,
        peer_id: String,
    ) -> Result<(), PeerTransportBackendError> {
        self.record(TransportBackendCommand::Connect {
            request_id: RequestId::from_string(request_id),
            peer_id: PeerId::from_string(peer_id),
        })
    }

    fn disconnect(
        &self,
        request_id: String,
        connection: u64,
    ) -> Result<(), PeerTransportBackendError> {
        self.record(TransportBackendCommand::Disconnect {
            request_id: RequestId::from_string(request_id),
            connection: ConnectionHandle(connection),
        })
    }

    fn send_frame(
        &self,
        request_id: String,
        connection: u64,
        channel: TransportChannel,
        bytes: Vec<u8>,
    ) -> Result<(), PeerTransportBackendError> {
        self.record(TransportBackendCommand::SendFrame {
            request_id: RequestId::from_string(request_id),
            connection: ConnectionHandle(connection),
            channel,
            bytes,
        })
    }

    fn set_realtime(
        &self,
        request_id: String,
        realtime: bool,
    ) -> Result<(), PeerTransportBackendError> {
        self.record(TransportBackendCommand::SetRealtime {
            request_id: RequestId::from_string(request_id),
            realtime,
        })
    }

    fn shutdown(&self) -> Result<(), PeerTransportBackendError> {
        let mut state = self.state.lock().map_err(|_| backend_state_poisoned())?;
        state.is_shutdown = true;
        state.event_sink = None;
        Ok(())
    }
}

#[derive(Clone)]
struct TransportConfiguration {
    local_peer_id: PeerId,
    group_id: GroupId,
    display_name: String,
    protocol_version: u16,
    group_key: Vec<u8>,
}

struct PeerSession {
    source: TransportConnectionSource,
    expected_peer_id: Option<PeerId>,
    authenticated_peer_id: Option<PeerId>,
}

type TransportHandler = Arc<dyn Fn(TransportEvent) + Send + Sync + 'static>;

#[derive(Default)]
struct PeerTransportRuntimeState {
    configuration: Option<TransportConfiguration>,
    sessions: HashMap<ConnectionHandle, PeerSession>,
    connections_by_peer: HashMap<PeerId, ConnectionHandle>,
    internal_requests: HashSet<RequestId>,
    handler: Option<TransportHandler>,
}

/// Rust-side runtime between semantic transport commands and the raw native
/// frame backend. It terminates the group-authenticated hello protocol.
pub struct PeerTransportRuntime {
    backend: Arc<dyn PeerTransportBackend>,
    state: Mutex<PeerTransportRuntimeState>,
}

impl PeerTransportRuntime {
    #[must_use]
    pub fn new(backend: Arc<dyn PeerTransportBackend>) -> Arc<Self> {
        Arc::new(Self {
            backend,
            state: Mutex::new(PeerTransportRuntimeState::default()),
        })
    }

    pub fn attach_event_handler(
        self: &Arc<Self>,
        handler: TransportHandler,
    ) -> Result<(), PeerTransportBackendError> {
        self.state
            .lock()
            .map_err(|_| backend_state_poisoned())?
            .handler = Some(handler);
        let weak = Arc::downgrade(self);
        self.backend
            .attach_event_sink(PeerTransportEventSink::new(Arc::new(move |event| {
                if let Some(runtime) = Weak::upgrade(&weak) {
                    runtime.handle_backend_event(event);
                }
            })))
    }

    pub fn dispatch(&self, command: TransportCommand) -> Result<(), PeerTransportBackendError> {
        match command {
            TransportCommand::StartDiscovery {
                request_id,
                local_peer_id,
                group_id,
                display_name,
                protocol_version,
                group_key,
                certificate_der,
                private_key_pkcs8,
            } => {
                validate_configuration(&display_name, &group_key)?;
                let discovery_scope = discovery_scope(&group_key)?;
                self.state
                    .lock()
                    .map_err(|_| backend_state_poisoned())?
                    .reset_for_configuration(TransportConfiguration {
                        local_peer_id: local_peer_id.clone(),
                        group_id,
                        display_name: display_name.clone(),
                        protocol_version,
                        group_key,
                    });
                self.backend.start_discovery(
                    request_id.to_string(),
                    local_peer_id.to_string(),
                    discovery_scope,
                    display_name,
                    protocol_version,
                    certificate_der,
                    private_key_pkcs8,
                )
            }
            TransportCommand::StopDiscovery { request_id } => {
                self.backend.stop_discovery(request_id.to_string())
            }
            TransportCommand::Connect {
                request_id,
                peer_id,
            } => self
                .backend
                .connect(request_id.to_string(), peer_id.to_string()),
            TransportCommand::Disconnect {
                request_id,
                connection,
            } => self
                .backend
                .disconnect(request_id.to_string(), connection.0),
            TransportCommand::SendData {
                request_id,
                connection,
                bytes,
                traffic_class,
            } => self.backend.send_frame(
                request_id.to_string(),
                connection.0,
                channel_for_traffic(traffic_class),
                bytes,
            ),
            TransportCommand::SetRealtime {
                request_id,
                realtime,
            } => self.backend.set_realtime(request_id.to_string(), realtime),
        }
    }

    pub fn shutdown(&self) -> Result<(), PeerTransportBackendError> {
        if let Ok(mut state) = self.state.lock() {
            state.configuration = None;
            state.sessions.clear();
            state.connections_by_peer.clear();
            state.internal_requests.clear();
            state.handler = None;
        }
        self.backend.shutdown()
    }

    fn handle_backend_event(&self, event: TransportBackendEvent) {
        match event {
            TransportBackendEvent::DiscoveryStarted { request_id } => {
                self.emit(TransportEvent::DiscoveryStarted { request_id });
            }
            TransportBackendEvent::DiscoveryStopped { request_id } => {
                if let Ok(mut state) = self.state.lock() {
                    state.configuration = None;
                    state.sessions.clear();
                    state.connections_by_peer.clear();
                    state.internal_requests.clear();
                }
                self.emit(TransportEvent::DiscoveryStopped { request_id });
            }
            TransportBackendEvent::PeerFound { peer_id } => {
                self.emit(TransportEvent::PeerFound { peer_id });
            }
            TransportBackendEvent::ConnectionOpened {
                connection,
                source,
                expected_peer_id,
            } => self.open_connection(connection, source, expected_peer_id),
            TransportBackendEvent::Disconnected { connection, reason } => {
                let was_current_authenticated_connection = self
                    .state
                    .lock()
                    .is_ok_and(|mut state| state.remove_connection(connection));
                if was_current_authenticated_connection {
                    self.emit(TransportEvent::Disconnected { connection, reason });
                }
            }
            TransportBackendEvent::FrameReceived {
                connection,
                channel,
                bytes,
            } => self.receive_frame(connection, channel, bytes),
            TransportBackendEvent::Sent { request_id } => {
                let internal = self
                    .state
                    .lock()
                    .is_ok_and(|mut state| state.internal_requests.remove(&request_id));
                if !internal {
                    self.emit(TransportEvent::Sent { request_id });
                }
            }
            TransportBackendEvent::Failed {
                request_id,
                code,
                message,
                retryable,
            } => {
                let request_id = request_id.and_then(|request_id| {
                    let internal = self
                        .state
                        .lock()
                        .is_ok_and(|mut state| state.internal_requests.remove(&request_id));
                    (!internal).then_some(request_id)
                });
                self.emit(TransportEvent::Failed {
                    request_id,
                    code,
                    message,
                    retryable,
                });
            }
        }
    }

    fn open_connection(
        &self,
        connection: ConnectionHandle,
        source: TransportConnectionSource,
        expected_peer_id: Option<PeerId>,
    ) {
        let hello = match self
            .state
            .lock()
            .map_err(|_| backend_state_poisoned())
            .and_then(|mut state| {
                let config = state
                    .configuration
                    .as_ref()
                    .ok_or_else(|| {
                        protocol_error("connection opened before discovery configuration")
                    })?
                    .clone();
                let hello = encode_hello(&config)?;
                state.sessions.insert(
                    connection,
                    PeerSession {
                        source,
                        expected_peer_id,
                        authenticated_peer_id: None,
                    },
                );
                Ok(hello)
            }) {
            Ok(hello) => hello,
            Err(error) => {
                self.reject_connection(connection, "authenticationFailed", error.to_string());
                return;
            }
        };
        if let Err(error) = self.send_internal_frame(connection, TransportChannel::Control, hello) {
            self.reject_connection(connection, "authenticationFailed", error.to_string());
        }
    }

    fn receive_frame(
        &self,
        connection: ConnectionHandle,
        channel: TransportChannel,
        bytes: Vec<u8>,
    ) {
        enum Outcome {
            Authenticated {
                peer_id: PeerId,
                replaced: Option<ConnectionHandle>,
            },
            Data,
        }

        let outcome = self
            .state
            .lock()
            .map_err(|_| backend_state_poisoned())
            .and_then(|mut state| {
                let configuration = state
                    .configuration
                    .as_ref()
                    .ok_or_else(|| protocol_error("frame arrived without transport configuration"))?
                    .clone();
                let session = state
                    .sessions
                    .get_mut(&connection)
                    .ok_or_else(|| protocol_error("frame arrived on an unknown connection"))?;
                if session.authenticated_peer_id.is_some() {
                    if channel == TransportChannel::Control {
                        return Err(protocol_error("control frame arrived after authentication"));
                    }
                    return Ok(Outcome::Data);
                }
                if channel != TransportChannel::Control {
                    return Err(protocol_error(
                        "business frame arrived before authentication",
                    ));
                }
                let hello = decode_and_validate_hello(&bytes, &configuration)?;
                if session
                    .expected_peer_id
                    .as_ref()
                    .is_some_and(|expected| expected != &hello.peer_id)
                {
                    return Err(protocol_error(
                        "authenticated peer does not match the discovered endpoint",
                    ));
                }
                let expected_source = if configuration.local_peer_id < hello.peer_id {
                    TransportConnectionSource::Outbound
                } else {
                    TransportConnectionSource::Inbound
                };
                if session.source != expected_source {
                    return Err(protocol_error(
                        "connection violates stable peer-ID dial direction",
                    ));
                }
                session.authenticated_peer_id = Some(hello.peer_id.clone());
                let replaced = state
                    .connections_by_peer
                    .insert(hello.peer_id.clone(), connection)
                    .filter(|old| *old != connection);
                Ok(Outcome::Authenticated {
                    peer_id: hello.peer_id,
                    replaced,
                })
            });

        match outcome {
            Ok(Outcome::Authenticated { peer_id, replaced }) => {
                if let Some(replaced) = replaced {
                    let _ = self.disconnect_internal(replaced);
                }
                self.emit(TransportEvent::Authenticated {
                    connection,
                    peer_id,
                });
            }
            Ok(Outcome::Data) => {
                self.emit(TransportEvent::DataReceived { connection, bytes });
            }
            Err(error) => {
                self.reject_connection(connection, "authenticationFailed", error.to_string());
            }
        }
    }

    fn send_internal_frame(
        &self,
        connection: ConnectionHandle,
        channel: TransportChannel,
        bytes: Vec<u8>,
    ) -> Result<(), PeerTransportBackendError> {
        let request_id = RequestId::new();
        self.state
            .lock()
            .map_err(|_| backend_state_poisoned())?
            .internal_requests
            .insert(request_id.clone());
        if let Err(error) =
            self.backend
                .send_frame(request_id.to_string(), connection.0, channel, bytes)
        {
            if let Ok(mut state) = self.state.lock() {
                state.internal_requests.remove(&request_id);
            }
            return Err(error);
        }
        Ok(())
    }

    fn disconnect_internal(
        &self,
        connection: ConnectionHandle,
    ) -> Result<(), PeerTransportBackendError> {
        let request_id = RequestId::new();
        self.state
            .lock()
            .map_err(|_| backend_state_poisoned())?
            .internal_requests
            .insert(request_id.clone());
        if let Err(error) = self
            .backend
            .disconnect(request_id.to_string(), connection.0)
        {
            if let Ok(mut state) = self.state.lock() {
                state.internal_requests.remove(&request_id);
            }
            return Err(error);
        }
        Ok(())
    }

    fn reject_connection(&self, connection: ConnectionHandle, code: &str, message: String) {
        if let Ok(mut state) = self.state.lock() {
            state.remove_connection(connection);
        }
        let _ = self.disconnect_internal(connection);
        self.emit(TransportEvent::Failed {
            request_id: None,
            code: code.to_owned(),
            message,
            retryable: false,
        });
    }

    fn emit(&self, event: TransportEvent) {
        let handler = self
            .state
            .lock()
            .ok()
            .and_then(|state| state.handler.clone());
        if let Some(handler) = handler {
            handler(event);
        }
    }
}

impl PeerTransportRuntimeState {
    fn reset_for_configuration(&mut self, configuration: TransportConfiguration) {
        self.configuration = Some(configuration);
        self.sessions.clear();
        self.connections_by_peer.clear();
        self.internal_requests.clear();
    }

    fn remove_connection(&mut self, connection: ConnectionHandle) -> bool {
        if let Some(session) = self.sessions.remove(&connection) {
            if let Some(peer_id) = session.authenticated_peer_id {
                if self.connections_by_peer.get(&peer_id) == Some(&connection) {
                    self.connections_by_peer.remove(&peer_id);
                    return true;
                }
            }
        }
        false
    }
}

struct PeerHello {
    peer_id: PeerId,
}

fn validate_configuration(
    display_name: &str,
    group_key: &[u8],
) -> Result<(), PeerTransportBackendError> {
    if display_name.is_empty() {
        return Err(protocol_error("display name is required"));
    }
    if group_key.len() < 32 {
        return Err(protocol_error("group key must contain at least 32 bytes"));
    }
    Ok(())
}

fn discovery_scope(group_key: &[u8]) -> Result<String, PeerTransportBackendError> {
    let mut mac = HmacSha256::new_from_slice(group_key)
        .map_err(|_| protocol_error("group key cannot initialize HMAC"))?;
    mac.update(DISCOVERY_SCOPE_LABEL);
    Ok(mac
        .finalize()
        .into_bytes()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

fn encode_hello(config: &TransportConfiguration) -> Result<Vec<u8>, PeerTransportBackendError> {
    let peer = config.local_peer_id.as_str().as_bytes();
    let group = config.group_id.as_str().as_bytes();
    let display = config.display_name.as_bytes();
    let peer_len = u16::try_from(peer.len()).map_err(|_| protocol_error("peer ID is too long"))?;
    let group_len =
        u16::try_from(group.len()).map_err(|_| protocol_error("group ID is too long"))?;
    let display_len =
        u16::try_from(display.len()).map_err(|_| protocol_error("display name is too long"))?;
    let nonce = Uuid::new_v4();
    let mut bytes = Vec::with_capacity(
        4 + 2 + 2 + 2 + 2 + 16 + peer.len() + group.len() + display.len() + HELLO_TAG_BYTES,
    );
    bytes.extend_from_slice(HELLO_MAGIC);
    bytes.extend_from_slice(&config.protocol_version.to_be_bytes());
    bytes.extend_from_slice(&peer_len.to_be_bytes());
    bytes.extend_from_slice(&group_len.to_be_bytes());
    bytes.extend_from_slice(&display_len.to_be_bytes());
    bytes.extend_from_slice(nonce.as_bytes());
    bytes.extend_from_slice(peer);
    bytes.extend_from_slice(group);
    bytes.extend_from_slice(display);
    let mut mac = HmacSha256::new_from_slice(&config.group_key)
        .map_err(|_| protocol_error("group key cannot initialize HMAC"))?;
    mac.update(&bytes);
    bytes.extend_from_slice(&mac.finalize().into_bytes());
    Ok(bytes)
}

fn decode_and_validate_hello(
    bytes: &[u8],
    config: &TransportConfiguration,
) -> Result<PeerHello, PeerTransportBackendError> {
    const FIXED_BYTES: usize = 4 + 2 + 2 + 2 + 2 + 16;
    if bytes.len() < FIXED_BYTES + HELLO_TAG_BYTES || &bytes[..4] != HELLO_MAGIC {
        return Err(protocol_error("peer hello is malformed"));
    }
    let protocol_version = u16::from_be_bytes([bytes[4], bytes[5]]);
    if protocol_version != config.protocol_version {
        return Err(protocol_error("peer protocol version does not match"));
    }
    let peer_len = u16::from_be_bytes([bytes[6], bytes[7]]) as usize;
    let group_len = u16::from_be_bytes([bytes[8], bytes[9]]) as usize;
    let display_len = u16::from_be_bytes([bytes[10], bytes[11]]) as usize;
    let body_end = FIXED_BYTES
        .checked_add(peer_len)
        .and_then(|value| value.checked_add(group_len))
        .and_then(|value| value.checked_add(display_len))
        .ok_or_else(|| protocol_error("peer hello length overflow"))?;
    if bytes.len() != body_end + HELLO_TAG_BYTES {
        return Err(protocol_error(
            "peer hello length does not match its header",
        ));
    }
    let mut mac = HmacSha256::new_from_slice(&config.group_key)
        .map_err(|_| protocol_error("group key cannot initialize HMAC"))?;
    mac.update(&bytes[..body_end]);
    mac.verify_slice(&bytes[body_end..])
        .map_err(|_| protocol_error("peer group authentication failed"))?;
    let peer_start = FIXED_BYTES;
    let group_start = peer_start + peer_len;
    let display_start = group_start + group_len;
    let peer_id = std::str::from_utf8(&bytes[peer_start..group_start])
        .map_err(|_| protocol_error("peer ID is not UTF-8"))?;
    let group_id = std::str::from_utf8(&bytes[group_start..display_start])
        .map_err(|_| protocol_error("group ID is not UTF-8"))?;
    let _display_name = std::str::from_utf8(&bytes[display_start..body_end])
        .map_err(|_| protocol_error("display name is not UTF-8"))?;
    if group_id != config.group_id.as_str() {
        return Err(protocol_error("peer belongs to a different group"));
    }
    let peer_id = PeerId::from(peer_id);
    if peer_id == config.local_peer_id {
        return Err(protocol_error("peer hello repeats the local identity"));
    }
    Ok(PeerHello { peer_id })
}

fn channel_for_traffic(traffic_class: TrafficClass) -> TransportChannel {
    match traffic_class {
        TrafficClass::EnergyEfficient => TransportChannel::Event,
        TrafficClass::Bulk => TransportChannel::Chunk,
        TrafficClass::RealtimeVoice => TransportChannel::Audio,
    }
}

fn backend_state_poisoned() -> PeerTransportBackendError {
    backend_error("peer transport runtime state is poisoned")
}

fn backend_is_shutdown() -> PeerTransportBackendError {
    backend_error("peer transport backend is shut down")
}

fn backend_error(message: impl Into<String>) -> PeerTransportBackendError {
    PeerTransportBackendError::Backend {
        message: message.into(),
    }
}

fn protocol_error(message: impl Into<String>) -> PeerTransportBackendError {
    PeerTransportBackendError::Protocol {
        message: message.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn start_command(local_peer_id: &str) -> TransportCommand {
        TransportCommand::StartDiscovery {
            request_id: RequestId::new(),
            local_peer_id: PeerId::from(local_peer_id),
            group_id: GroupId::from("group-one"),
            display_name: "Traveller".into(),
            protocol_version: 1,
            group_key: vec![7; 32],
            certificate_der: vec![1],
            private_key_pkcs8: vec![2],
        }
    }

    fn last_hello(backend: &FakePeerTransportBackend) -> Vec<u8> {
        backend
            .commands()
            .into_iter()
            .rev()
            .find_map(|command| match command {
                TransportBackendCommand::SendFrame {
                    channel: TransportChannel::Control,
                    bytes,
                    ..
                } => Some(bytes),
                _ => None,
            })
            .expect("runtime sent a hello")
    }

    #[test]
    fn native_start_receives_only_an_opaque_discovery_scope() {
        let backend = Arc::new(FakePeerTransportBackend::default());
        let runtime = PeerTransportRuntime::new(backend.clone());
        runtime.dispatch(start_command("peer-a")).unwrap();

        let TransportBackendCommand::StartDiscovery {
            discovery_scope,
            local_peer_id,
            ..
        } = &backend.commands()[0]
        else {
            panic!("expected start discovery");
        };
        assert_eq!(local_peer_id, &PeerId::from("peer-a"));
        assert_eq!(discovery_scope.len(), 64);
        assert_ne!(discovery_scope, "group-one");
    }

    #[test]
    fn runtime_authenticates_hello_and_delivers_opaque_data_in_rust() {
        let alice_backend = Arc::new(FakePeerTransportBackend::default());
        let bob_backend = Arc::new(FakePeerTransportBackend::default());
        let alice = PeerTransportRuntime::new(alice_backend.clone());
        let bob = PeerTransportRuntime::new(bob_backend.clone());
        let alice_events = Arc::new(Mutex::new(Vec::new()));
        let bob_events = Arc::new(Mutex::new(Vec::new()));
        let alice_received = alice_events.clone();
        alice
            .attach_event_handler(Arc::new(move |event| {
                alice_received.lock().unwrap().push(event);
            }))
            .unwrap();
        let bob_received = bob_events.clone();
        bob.attach_event_handler(Arc::new(move |event| {
            bob_received.lock().unwrap().push(event);
        }))
        .unwrap();
        alice.dispatch(start_command("peer-a")).unwrap();
        bob.dispatch(start_command("peer-b")).unwrap();

        alice_backend
            .inject(TransportBackendEvent::ConnectionOpened {
                connection: ConnectionHandle(11),
                source: TransportConnectionSource::Outbound,
                expected_peer_id: Some(PeerId::from("peer-b")),
            })
            .unwrap();
        bob_backend
            .inject(TransportBackendEvent::ConnectionOpened {
                connection: ConnectionHandle(22),
                source: TransportConnectionSource::Inbound,
                expected_peer_id: None,
            })
            .unwrap();
        let alice_hello = last_hello(&alice_backend);
        let bob_hello = last_hello(&bob_backend);
        alice_backend
            .inject(TransportBackendEvent::FrameReceived {
                connection: ConnectionHandle(11),
                channel: TransportChannel::Control,
                bytes: bob_hello,
            })
            .unwrap();
        bob_backend
            .inject(TransportBackendEvent::FrameReceived {
                connection: ConnectionHandle(22),
                channel: TransportChannel::Control,
                bytes: alice_hello,
            })
            .unwrap();

        assert!(alice_events
            .lock()
            .unwrap()
            .contains(&TransportEvent::Authenticated {
                connection: ConnectionHandle(11),
                peer_id: PeerId::from("peer-b"),
            }));
        assert!(bob_events
            .lock()
            .unwrap()
            .contains(&TransportEvent::Authenticated {
                connection: ConnectionHandle(22),
                peer_id: PeerId::from("peer-a"),
            }));

        bob_backend
            .inject(TransportBackendEvent::FrameReceived {
                connection: ConnectionHandle(22),
                channel: TransportChannel::Audio,
                bytes: vec![3, 4, 5],
            })
            .unwrap();
        assert!(bob_events
            .lock()
            .unwrap()
            .contains(&TransportEvent::DataReceived {
                connection: ConnectionHandle(22),
                bytes: vec![3, 4, 5],
            }));

        alice_events.lock().unwrap().clear();
        alice_backend
            .inject(TransportBackendEvent::ConnectionOpened {
                connection: ConnectionHandle(12),
                source: TransportConnectionSource::Outbound,
                expected_peer_id: Some(PeerId::from("peer-b")),
            })
            .unwrap();
        alice_backend
            .inject(TransportBackendEvent::FrameReceived {
                connection: ConnectionHandle(12),
                channel: TransportChannel::Control,
                bytes: last_hello(&bob_backend),
            })
            .unwrap();
        alice_backend
            .inject(TransportBackendEvent::Disconnected {
                connection: ConnectionHandle(11),
                reason: "superseded".into(),
            })
            .unwrap();
        let events = alice_events.lock().unwrap();
        assert!(events.contains(&TransportEvent::Authenticated {
            connection: ConnectionHandle(12),
            peer_id: PeerId::from("peer-b"),
        }));
        assert!(!events.contains(&TransportEvent::Disconnected {
            connection: ConnectionHandle(11),
            reason: "superseded".into(),
        }));
    }
}

uniffi::setup_scaffolding!();
