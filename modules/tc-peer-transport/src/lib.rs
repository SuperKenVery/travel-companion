//! Local-only peer data/realtime transport capability. Bonjour, AWDL and
//! Network.framework endpoints never cross this Rust boundary.

use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use tc_model::{GroupId, PeerId, RequestId};

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(transparent)]
pub struct ConnectionHandle(pub u64);

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TransportCapabilities {
    pub local_only: bool,
    pub peer_to_peer: bool,
    pub authenticated_streams: bool,
    pub bulk_streams: bool,
    pub realtime_streams: bool,
    pub max_data_frame_bytes: u32,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum TrafficClass {
    EnergyEfficient,
    Bulk,
    RealtimeVoice,
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
    SendRealtime {
        request_id: RequestId,
        connection: ConnectionHandle,
        stream_id: String,
        sequence: u64,
        timestamp_ms: i64,
        bytes: Vec<u8>,
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
    Connected {
        request_id: RequestId,
        peer_id: PeerId,
        connection: ConnectionHandle,
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
    RealtimeReceived {
        connection: ConnectionHandle,
        stream_id: String,
        sequence: u64,
        timestamp_ms: i64,
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

pub trait PeerTransportBackend: Send {
    fn capabilities(&self) -> TransportCapabilities;
    fn submit(&mut self, command: TransportCommand);
    fn poll_event(&mut self) -> Option<TransportEvent>;
}

pub struct PeerTransport<B: PeerTransportBackend> {
    backend: B,
}

impl<B: PeerTransportBackend> PeerTransport<B> {
    #[must_use]
    pub fn new(backend: B) -> Self {
        Self { backend }
    }

    #[must_use]
    pub fn capabilities(&self) -> TransportCapabilities {
        self.backend.capabilities()
    }

    pub fn submit(&mut self, command: TransportCommand) {
        self.backend.submit(command);
    }

    pub fn poll_event(&mut self) -> Option<TransportEvent> {
        self.backend.poll_event()
    }
}

#[derive(Clone, Debug)]
pub struct FakePeerTransportBackend {
    capabilities: TransportCapabilities,
    commands: Vec<TransportCommand>,
    events: VecDeque<TransportEvent>,
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
            commands: Vec::new(),
            events: VecDeque::new(),
        }
    }
}

impl FakePeerTransportBackend {
    pub fn inject(&mut self, event: TransportEvent) {
        self.events.push_back(event);
    }

    #[must_use]
    pub fn commands(&self) -> &[TransportCommand] {
        &self.commands
    }
}

impl PeerTransportBackend for FakePeerTransportBackend {
    fn capabilities(&self) -> TransportCapabilities {
        self.capabilities.clone()
    }

    fn submit(&mut self, command: TransportCommand) {
        self.commands.push(command);
    }

    fn poll_event(&mut self) -> Option<TransportEvent> {
        self.events.pop_front()
    }
}

/// Adapter for the private JSON contract implemented by `TcPeerTransportApple`.
pub mod apple_wire {
    use super::{ConnectionHandle, TrafficClass, TransportCommand, TransportEvent};
    use base64::Engine as _;
    use serde::{Deserialize, Serialize};
    use serde_json::{json, Value};
    use std::collections::BTreeMap;
    use std::fmt::{Display, Formatter};
    use tc_model::{PeerId, RequestId};

    #[derive(Clone, Debug, Eq, PartialEq)]
    pub struct AppleWireError(String);

    impl AppleWireError {
        fn new(message: impl Into<String>) -> Self {
            Self(message.into())
        }
    }

    impl Display for AppleWireError {
        fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
            formatter.write_str(&self.0)
        }
    }

    impl std::error::Error for AppleWireError {}

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct AppleEvent {
        #[serde(rename = "type")]
        event_type: String,
        #[serde(rename = "requestID")]
        request_id: Option<String>,
        peer_handle: Option<u64>,
        #[serde(rename = "peerID")]
        peer_id: Option<String>,
        channel: Option<String>,
        payload_base64: Option<String>,
        #[serde(default)]
        fields: BTreeMap<String, String>,
        error: Option<String>,
    }

    #[derive(Deserialize, Serialize)]
    #[serde(rename_all = "camelCase")]
    struct RealtimePayload {
        #[serde(rename = "streamID")]
        stream_id: String,
        sequence: u64,
        timestamp_millis: i64,
        payload_base64: String,
    }

    /// Converts a semantic transport command to the complete Apple private
    /// command, including the per-installation DER TLS identity on start.
    pub fn command_to_value(command: &TransportCommand) -> Result<Value, AppleWireError> {
        let value = match command {
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
                if group_key.len() < 32 {
                    return Err(AppleWireError::new(
                        "group_key must contain at least 32 bytes",
                    ));
                }
                if certificate_der.is_empty() || private_key_pkcs8.is_empty() {
                    return Err(AppleWireError::new(
                        "a unique certificate DER and PKCS#8 private key are required",
                    ));
                }
                json!({
                    "type": "start",
                    "requestID": request_to_apple(request_id)?,
                    "localPeerID": canonical_uuid(local_peer_id.as_str())?,
                    "groupID": group_id.as_str(),
                    "displayName": display_name,
                    "protocolVersion": protocol_version,
                    "groupKeyBase64": encode(group_key),
                    "certificateDERBase64": encode(certificate_der),
                    "privateKeyPKCS8Base64": encode(private_key_pkcs8),
                })
            }
            TransportCommand::StopDiscovery { request_id } => json!({
                "type": "stop",
                "requestID": request_to_apple(request_id)?,
            }),
            // Discovery/start automatically chooses the sole connection direction
            // from stable UUID ordering. There is no imperative Apple connect.
            TransportCommand::Connect { request_id, .. } => json!({
                "type": "snapshot",
                "requestID": request_to_apple(request_id)?,
            }),
            TransportCommand::Disconnect { .. } => {
                return Err(AppleWireError::new(
                    "TcPeerTransportApple owns connection lifetime; per-peer disconnect is unsupported",
                ));
            }
            TransportCommand::SendData {
                request_id,
                connection,
                bytes,
                traffic_class,
            } => json!({
                "type": "send",
                "requestID": request_to_apple(request_id)?,
                "peerHandle": connection.0,
                "channel": match traffic_class {
                    TrafficClass::EnergyEfficient => "event",
                    TrafficClass::Bulk => "chunk",
                    TrafficClass::RealtimeVoice => "audio",
                },
                "payloadBase64": encode(bytes),
            }),
            TransportCommand::SendRealtime {
                request_id,
                connection,
                stream_id,
                sequence,
                timestamp_ms,
                bytes,
            } => {
                let envelope = RealtimePayload {
                    stream_id: stream_id.clone(),
                    sequence: *sequence,
                    timestamp_millis: *timestamp_ms,
                    payload_base64: encode(bytes),
                };
                let envelope = serde_json::to_vec(&envelope)
                    .map_err(|error| AppleWireError::new(error.to_string()))?;
                json!({
                    "type": "send",
                    "requestID": request_to_apple(request_id)?,
                    "peerHandle": connection.0,
                    "channel": "audio",
                    "payloadBase64": encode(&envelope),
                })
            }
            TransportCommand::SetRealtime {
                request_id,
                realtime,
            } => json!({
                "type": "setRealtime",
                "requestID": request_to_apple(request_id)?,
                "realtime": realtime,
            }),
        };
        Ok(value)
    }

    /// Converts private Network.framework callbacks to semantic transport events.
    pub fn event_from_value(value: Value) -> Result<Option<TransportEvent>, AppleWireError> {
        let event: AppleEvent = serde_json::from_value(value).map_err(|error| {
            AppleWireError::new(format!("invalid PeerTransport Apple event: {error}"))
        })?;
        let request_id = event
            .request_id
            .as_deref()
            .map(request_from_apple)
            .transpose()?;
        let result = match event.event_type.as_str() {
            "commandCompleted" => match event.fields.get("command").map(String::as_str) {
                Some("start") => Some(TransportEvent::DiscoveryStarted {
                    request_id: required(request_id, "requestID")?,
                }),
                Some("stop") => Some(TransportEvent::DiscoveryStopped {
                    request_id: required(request_id, "requestID")?,
                }),
                _ => None,
            },
            "dialStarted" => event.peer_id.map(|peer| TransportEvent::PeerFound {
                peer_id: PeerId::from_string(peer),
            }),
            // peerConnected is emitted only after the TLS link's group-HMAC
            // hello succeeds, so Authenticated is the precise semantic event.
            "peerConnected" => Some(TransportEvent::Authenticated {
                connection: ConnectionHandle(required(event.peer_handle, "peerHandle")?),
                peer_id: PeerId::from_string(required(event.peer_id, "peerID")?),
            }),
            "peerDisconnected" => Some(TransportEvent::Disconnected {
                connection: ConnectionHandle(required(event.peer_handle, "peerHandle")?),
                reason: event.error.unwrap_or_else(|| "disconnected".into()),
            }),
            "frameReceived" => {
                let channel = required(event.channel, "channel")?;
                let bytes = decode(&required(event.payload_base64, "payloadBase64")?)?;
                if channel == "audio" {
                    let realtime: RealtimePayload =
                        serde_json::from_slice(&bytes).map_err(|error| {
                            AppleWireError::new(format!("invalid realtime audio envelope: {error}"))
                        })?;
                    Some(TransportEvent::RealtimeReceived {
                        connection: ConnectionHandle(required(event.peer_handle, "peerHandle")?),
                        stream_id: realtime.stream_id,
                        sequence: realtime.sequence,
                        timestamp_ms: realtime.timestamp_millis,
                        bytes: decode(&realtime.payload_base64)?,
                    })
                } else {
                    Some(TransportEvent::DataReceived {
                        connection: ConnectionHandle(required(event.peer_handle, "peerHandle")?),
                        bytes,
                    })
                }
            }
            "frameSent" => Some(TransportEvent::Sent {
                request_id: required(request_id, "requestID")?,
            }),
            "trafficClassChanged" => Some(TransportEvent::Sent {
                request_id: required(request_id, "requestID")?,
            }),
            "commandFailed" | "capabilityBlocked" | "connectionFailed" | "transportFailed" => {
                Some(TransportEvent::Failed {
                    request_id,
                    code: event
                        .fields
                        .get("reason")
                        .cloned()
                        .unwrap_or_else(|| event.event_type.clone()),
                    message: event.error.unwrap_or_else(|| event.event_type.clone()),
                    retryable: event.event_type != "capabilityBlocked",
                })
            }
            // Browser/listener/path state and traffic-class changes are diagnostics.
            _ => None,
        };
        Ok(result)
    }

    fn encode(bytes: &[u8]) -> String {
        base64::engine::general_purpose::STANDARD.encode(bytes)
    }

    fn decode(value: &str) -> Result<Vec<u8>, AppleWireError> {
        base64::engine::general_purpose::STANDARD
            .decode(value)
            .map_err(|error| {
                AppleWireError::new(format!("invalid padded RFC 4648 base64: {error}"))
            })
    }

    fn required<T>(value: Option<T>, field: &str) -> Result<T, AppleWireError> {
        value.ok_or_else(|| AppleWireError::new(format!("missing {field}")))
    }

    fn request_to_apple(value: &RequestId) -> Result<String, AppleWireError> {
        prefixed_id_to_uuid(value.as_str(), "req_")
    }

    fn request_from_apple(value: &str) -> Result<RequestId, AppleWireError> {
        uuid_to_prefixed_id(value, "req_").map(RequestId::from_string)
    }

    fn canonical_uuid(value: &str) -> Result<String, AppleWireError> {
        let simple = value.replace('-', "").to_ascii_lowercase();
        if simple.len() != 32 || !simple.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(AppleWireError::new(format!("{value} is not a UUID")));
        }
        Ok(format!(
            "{}-{}-{}-{}-{}",
            &simple[0..8],
            &simple[8..12],
            &simple[12..16],
            &simple[16..20],
            &simple[20..32]
        ))
    }

    fn prefixed_id_to_uuid(value: &str, prefix: &str) -> Result<String, AppleWireError> {
        let simple = value.strip_prefix(prefix).unwrap_or(value).replace('-', "");
        if simple.len() != 32 || !simple.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(AppleWireError::new(format!(
                "{value} is not a UUID-compatible ID"
            )));
        }
        Ok(format!(
            "{}-{}-{}-{}-{}",
            &simple[0..8],
            &simple[8..12],
            &simple[12..16],
            &simple[16..20],
            &simple[20..32]
        ))
    }

    fn uuid_to_prefixed_id(value: &str, prefix: &str) -> Result<String, AppleWireError> {
        let simple = value.replace('-', "").to_ascii_lowercase();
        if simple.len() != 32 || !simple.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(AppleWireError::new(format!("{value} is not a UUID")));
        }
        Ok(format!("{prefix}{simple}"))
    }
}

#[cfg(test)]
mod apple_wire_tests {
    use super::*;
    use base64::Engine as _;

    #[test]
    fn start_contract_contains_group_key_and_der_identity() {
        let command = TransportCommand::StartDiscovery {
            request_id: RequestId::from("req_00112233445566778899aabbccddeeff"),
            local_peer_id: PeerId::from("01234567-89ab-cdef-0123-456789abcdef"),
            group_id: GroupId::from("trip"),
            display_name: "Ken".into(),
            protocol_version: 1,
            group_key: vec![7; 32],
            certificate_der: vec![1, 2, 3],
            private_key_pkcs8: vec![4, 5, 6],
        };
        let value = apple_wire::command_to_value(&command).expect("valid start");
        assert_eq!(value["type"], "start");
        assert_eq!(value["localPeerID"], "01234567-89ab-cdef-0123-456789abcdef");
        assert_eq!(
            value["groupKeyBase64"],
            base64::engine::general_purpose::STANDARD.encode([7; 32])
        );
        assert_eq!(value["certificateDERBase64"], "AQID");
        assert_eq!(value["privateKeyPKCS8Base64"], "BAUG");
        assert!(value.get("identityPKCS12Base64").is_none());
        assert!(value.get("kind").is_none());
    }

    #[test]
    fn frame_and_blocker_contracts_map_to_semantic_events() {
        let envelope = serde_json::json!({
            "streamID": "call-1",
            "sequence": 3,
            "timestampMillis": 42,
            "payloadBase64": "AQI="
        });
        let payload = base64::engine::general_purpose::STANDARD
            .encode(serde_json::to_vec(&envelope).expect("envelope"));
        let received = apple_wire::event_from_value(serde_json::json!({
            "type": "frameReceived",
            "peerHandle": 4,
            "channel": "audio",
            "payloadBase64": payload
        }))
        .expect("valid frame");
        assert!(
            matches!(received, Some(TransportEvent::RealtimeReceived { sequence: 3, bytes, .. }) if bytes == [1, 2])
        );

        let blocked = apple_wire::event_from_value(serde_json::json!({
            "type": "capabilityBlocked",
            "requestID": "00112233-4455-6677-8899-aabbccddeeff",
            "fields": {"reason": "tlsIdentityUnavailable"},
            "error": "missing identity"
        }))
        .expect("valid blocker");
        assert!(
            matches!(blocked, Some(TransportEvent::Failed { code, retryable: false, .. }) if code == "tlsIdentityUnavailable")
        );
    }
}
