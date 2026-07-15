//! Platform-neutral BLE control-plane capability.

use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use tc_model::{PeerId, RequestId};

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(transparent)]
pub struct PeerHandle(pub u64);

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BluetoothCapabilities {
    pub central: bool,
    pub peripheral: bool,
    pub state_restoration: bool,
    pub background_control: bool,
    pub max_control_payload_bytes: u32,
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
        control_kind: String,
        payload: Vec<u8>,
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
    },
    Disconnected {
        handle: PeerHandle,
        reason: String,
    },
    ControlReceived {
        handle: PeerHandle,
        control_kind: String,
        payload: Vec<u8>,
    },
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

pub trait BluetoothBackend: Send {
    fn capabilities(&self) -> BluetoothCapabilities;
    /// Must return immediately. Completion arrives through `poll_event`.
    fn submit(&mut self, command: BluetoothCommand);
    fn poll_event(&mut self) -> Option<BluetoothEvent>;
}

pub struct Bluetooth<B: BluetoothBackend> {
    backend: B,
}

impl<B: BluetoothBackend> Bluetooth<B> {
    #[must_use]
    pub fn new(backend: B) -> Self {
        Self { backend }
    }

    #[must_use]
    pub fn capabilities(&self) -> BluetoothCapabilities {
        self.backend.capabilities()
    }

    pub fn submit(&mut self, command: BluetoothCommand) {
        self.backend.submit(command);
    }

    pub fn poll_event(&mut self) -> Option<BluetoothEvent> {
        self.backend.poll_event()
    }
}

#[derive(Clone, Debug)]
pub struct FakeBluetoothBackend {
    capabilities: BluetoothCapabilities,
    commands: Vec<BluetoothCommand>,
    events: VecDeque<BluetoothEvent>,
}

impl Default for FakeBluetoothBackend {
    fn default() -> Self {
        Self {
            capabilities: BluetoothCapabilities {
                central: true,
                peripheral: true,
                state_restoration: true,
                background_control: true,
                max_control_payload_bytes: 256,
            },
            commands: Vec::new(),
            events: VecDeque::new(),
        }
    }
}

impl FakeBluetoothBackend {
    pub fn inject(&mut self, event: BluetoothEvent) {
        self.events.push_back(event);
    }

    #[must_use]
    pub fn commands(&self) -> &[BluetoothCommand] {
        &self.commands
    }
}

impl BluetoothBackend for FakeBluetoothBackend {
    fn capabilities(&self) -> BluetoothCapabilities {
        self.capabilities.clone()
    }

    fn submit(&mut self, command: BluetoothCommand) {
        self.commands.push(command);
    }

    fn poll_event(&mut self) -> Option<BluetoothEvent> {
        self.events.pop_front()
    }
}

/// Adapter for the private JSON contract implemented by `TcBluetoothApple`.
///
/// The semantic API deliberately keeps CoreBluetooth objects and its private
/// `type`-tagged schema out of the rest of the Rust core.
pub mod apple_wire {
    use super::{BluetoothCommand, BluetoothEvent, PeerHandle};
    use base64::Engine as _;
    use serde::Deserialize;
    use serde_json::{json, Value};
    use std::collections::BTreeMap;
    use std::fmt::{Display, Formatter};
    use std::time::{SystemTime, UNIX_EPOCH};
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
        #[serde(rename = "messageID")]
        message_id: Option<String>,
        payload_base64: Option<String>,
        #[serde(default)]
        fields: BTreeMap<String, String>,
        error: Option<String>,
    }

    #[derive(serde::Serialize, Deserialize)]
    struct ControlPayload {
        kind: String,
        #[serde(rename = "payloadBase64")]
        payload_base64: String,
    }

    /// Converts a semantic command to the private Apple JSON value.
    pub fn command_to_value(command: &BluetoothCommand) -> Result<Value, AppleWireError> {
        command_to_value_at(command, unix_time_millis())
    }

    /// Clock-injectable form used by deterministic callers and contract tests.
    pub fn command_to_value_at(
        command: &BluetoothCommand,
        now_ms: i64,
    ) -> Result<Value, AppleWireError> {
        let value = match command {
            BluetoothCommand::Start { request_id } => {
                json!({"type": "start", "requestID": request_to_apple(request_id)?})
            }
            BluetoothCommand::Stop { request_id } => {
                json!({"type": "stop", "requestID": request_to_apple(request_id)?})
            }
            // The Apple backend connects every discovered peripheral itself.
            // Snapshot is an accepted, side-effect-free acknowledgement while
            // the eventual peerConnected event remains the source of truth.
            BluetoothCommand::Connect { request_id, .. } => {
                json!({"type": "snapshot", "requestID": request_to_apple(request_id)?})
            }
            BluetoothCommand::Disconnect { request_id, handle } => json!({
                "type": "disconnect",
                "requestID": request_to_apple(request_id)?,
                "peerHandle": handle.0,
            }),
            BluetoothCommand::SendControl {
                request_id,
                handle,
                control_kind,
                payload,
                expires_at_ms,
            } => {
                let envelope = ControlPayload {
                    kind: control_kind.clone(),
                    payload_base64: encode(payload),
                };
                let payload = serde_json::to_vec(&envelope)
                    .map_err(|error| AppleWireError::new(error.to_string()))?;
                let request = request_to_apple(request_id)?;
                json!({
                    "type": "sendControl",
                    "requestID": request,
                    "peerHandle": handle.0,
                    "messageID": request_to_apple(request_id)?,
                    "sequence": stable_sequence(request_id.as_str()),
                    "ttlMillis": expires_at_ms.saturating_sub(now_ms).max(1) as u64,
                    "requiresAck": true,
                    "payloadBase64": encode(&payload),
                })
            }
        };
        Ok(value)
    }

    /// Converts one private Apple event to the semantic event model. Apple
    /// diagnostics and acknowledgement-only events intentionally return `None`.
    pub fn event_from_value(value: Value) -> Result<Option<BluetoothEvent>, AppleWireError> {
        let event: AppleEvent = serde_json::from_value(value).map_err(|error| {
            AppleWireError::new(format!("invalid Bluetooth Apple event: {error}"))
        })?;
        let request_id = event
            .request_id
            .as_deref()
            .map(request_from_apple)
            .transpose()?;
        let result = match event.event_type.as_str() {
            "commandCompleted" => match event.fields.get("command").map(String::as_str) {
                Some("start") => Some(BluetoothEvent::Started {
                    request_id: required(request_id, "requestID")?,
                }),
                Some("stop") => Some(BluetoothEvent::Stopped {
                    request_id: required(request_id, "requestID")?,
                }),
                _ => None,
            },
            "peerDiscovered" => Some(BluetoothEvent::PeerDiscovered {
                peer_id: PeerId::from_string(required(
                    event.fields.get("platformID").cloned(),
                    "fields.platformID",
                )?),
                handle: PeerHandle(required(event.peer_handle, "peerHandle")?),
            }),
            "peerConnected" | "peerReady" => {
                let handle = required(event.peer_handle, "peerHandle")?;
                Some(BluetoothEvent::Connected {
                    request_id: request_id.unwrap_or_else(|| {
                        RequestId::from_string(format!("apple_bluetooth_connected_{handle}"))
                    }),
                    handle: PeerHandle(handle),
                })
            }
            "peerDisconnected" => Some(BluetoothEvent::Disconnected {
                handle: PeerHandle(required(event.peer_handle, "peerHandle")?),
                reason: event
                    .error
                    .or_else(|| event.fields.get("role").cloned())
                    .unwrap_or_else(|| "disconnected".to_owned()),
            }),
            "controlReceived" => {
                let bytes = decode(required(event.payload_base64, "payloadBase64")?.as_str())?;
                let control: ControlPayload = serde_json::from_slice(&bytes).map_err(|error| {
                    AppleWireError::new(format!("invalid BLE control payload: {error}"))
                })?;
                Some(BluetoothEvent::ControlReceived {
                    handle: PeerHandle(required(event.peer_handle, "peerHandle")?),
                    control_kind: control.kind,
                    payload: decode(&control.payload_base64)?,
                })
            }
            "controlQueued" => Some(BluetoothEvent::ControlSent {
                request_id: required(request_id, "requestID")?,
            }),
            "commandFailed"
            | "peerConnectionFailed"
            | "gattError"
            | "transportError"
            | "controlExpired" => Some(BluetoothEvent::Failed {
                request_id,
                code: event.event_type.clone(),
                message: event.error.unwrap_or_else(|| {
                    event.message_id.map_or_else(
                        || event.event_type.clone(),
                        |id| format!("message {id} expired"),
                    )
                }),
                retryable: event.event_type != "commandFailed"
                    && event.event_type != "controlExpired",
            }),
            // State, advertisements, snapshots and ACK telemetry are diagnostics.
            _ => None,
        };
        Ok(result)
    }

    fn encode(bytes: &[u8]) -> String {
        base64::engine::general_purpose::STANDARD.encode(bytes)
    }

    fn decode(text: &str) -> Result<Vec<u8>, AppleWireError> {
        base64::engine::general_purpose::STANDARD
            .decode(text)
            .map_err(|error| {
                AppleWireError::new(format!("invalid padded RFC 4648 base64: {error}"))
            })
    }

    fn required<T>(value: Option<T>, field: &str) -> Result<T, AppleWireError> {
        value.ok_or_else(|| AppleWireError::new(format!("missing {field}")))
    }

    fn request_to_apple(request: &RequestId) -> Result<String, AppleWireError> {
        prefixed_id_to_uuid(request.as_str(), "req_")
    }

    fn request_from_apple(value: &str) -> Result<RequestId, AppleWireError> {
        uuid_to_prefixed_id(value, "req_").map(RequestId::from_string)
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

    fn stable_sequence(value: &str) -> u64 {
        value.bytes().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
            (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
        })
    }

    fn unix_time_millis() -> i64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |duration| {
                i64::try_from(duration.as_millis()).unwrap_or(i64::MAX)
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine as _;

    #[test]
    fn fake_backend_keeps_submission_asynchronous() {
        let mut backend = FakeBluetoothBackend::default();
        let command = BluetoothCommand::Start {
            request_id: RequestId::from("start"),
        };
        backend.submit(command.clone());
        assert_eq!(backend.commands(), &[command]);
        assert!(backend.poll_event().is_none());
        backend.inject(BluetoothEvent::Started {
            request_id: RequestId::from("start"),
        });
        assert!(matches!(
            backend.poll_event(),
            Some(BluetoothEvent::Started { .. })
        ));
    }

    #[test]
    fn apple_wire_contract_wraps_control_payload_and_uses_type_tag() {
        let command = BluetoothCommand::SendControl {
            request_id: RequestId::from("req_00112233445566778899aabbccddeeff"),
            handle: PeerHandle(7),
            control_kind: "precisionRequest".into(),
            payload: vec![1, 2, 3],
            expires_at_ms: 31_000,
        };
        let json = apple_wire::command_to_value_at(&command, 1_000).expect("valid command");
        assert_eq!(json["type"], "sendControl");
        assert_eq!(json["requestID"], "00112233-4455-6677-8899-aabbccddeeff");
        assert_eq!(json["ttlMillis"], 30_000);
        assert_eq!(json["peerHandle"], 7);
        assert!(json.get("kind").is_none());

        let private_payload = base64::engine::general_purpose::STANDARD
            .decode(json["payloadBase64"].as_str().expect("base64 text"))
            .expect("padded base64");
        let private_payload: serde_json::Value =
            serde_json::from_slice(&private_payload).expect("control envelope");
        assert_eq!(private_payload["kind"], "precisionRequest");
        assert_eq!(private_payload["payloadBase64"], "AQID");
    }

    #[test]
    fn apple_wire_contract_decodes_control_and_failure() {
        let inner = serde_json::json!({
            "kind": "hello",
            "payloadBase64": "AQI="
        });
        let encoded = base64::engine::general_purpose::STANDARD
            .encode(serde_json::to_vec(&inner).expect("inner JSON"));
        let event = apple_wire::event_from_value(serde_json::json!({
            "type": "controlReceived",
            "peerHandle": 2,
            "payloadBase64": encoded
        }))
        .expect("valid event")
        .expect("semantic event");
        assert!(matches!(
            event,
            BluetoothEvent::ControlReceived { control_kind, payload, .. }
                if control_kind == "hello" && payload == [1, 2]
        ));

        let failed = apple_wire::event_from_value(serde_json::json!({
            "type": "commandFailed",
            "requestID": "00112233-4455-6677-8899-aabbccddeeff",
            "error": "bad"
        }))
        .expect("valid failure");
        assert!(
            matches!(failed, Some(BluetoothEvent::Failed { code, .. }) if code == "commandFailed")
        );
    }
}
