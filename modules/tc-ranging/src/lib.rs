//! Foreground precise-ranging capability. Distance and direction are distinct
//! optional fields by contract.

use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use tc_model::{PeerId, RequestId};

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RangingCapabilities {
    pub distance: bool,
    pub direction: bool,
    pub foreground_only: bool,
    pub max_concurrent_sessions: u32,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub enum RangingCommand {
    CreateDiscoveryToken {
        request_id: RequestId,
        peer_id: PeerId,
    },
    Start {
        request_id: RequestId,
        peer_id: PeerId,
        remote_discovery_token: Vec<u8>,
    },
    Cancel {
        request_id: RequestId,
        peer_id: PeerId,
        reason: String,
    },
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub enum RangingEvent {
    DiscoveryToken {
        request_id: RequestId,
        token: Vec<u8>,
    },
    Started {
        request_id: RequestId,
        peer_id: PeerId,
    },
    Measurement {
        peer_id: PeerId,
        distance_m: Option<f64>,
        direction_radians: Option<f64>,
        observed_at_ms: i64,
    },
    Suspended {
        peer_id: PeerId,
        reason: String,
    },
    Ended {
        peer_id: PeerId,
        reason: String,
    },
    Failed {
        request_id: Option<RequestId>,
        code: String,
        message: String,
        retryable: bool,
    },
}

pub trait RangingBackend: Send {
    fn capabilities(&self) -> RangingCapabilities;
    fn submit(&mut self, command: RangingCommand);
    fn poll_event(&mut self) -> Option<RangingEvent>;
}

pub struct Ranging<B: RangingBackend> {
    backend: B,
}

impl<B: RangingBackend> Ranging<B> {
    #[must_use]
    pub fn new(backend: B) -> Self {
        Self { backend }
    }

    #[must_use]
    pub fn capabilities(&self) -> RangingCapabilities {
        self.backend.capabilities()
    }

    pub fn submit(&mut self, command: RangingCommand) {
        self.backend.submit(command);
    }

    pub fn poll_event(&mut self) -> Option<RangingEvent> {
        self.backend.poll_event()
    }
}

#[derive(Clone, Debug)]
pub struct FakeRangingBackend {
    capabilities: RangingCapabilities,
    commands: Vec<RangingCommand>,
    events: VecDeque<RangingEvent>,
}

impl Default for FakeRangingBackend {
    fn default() -> Self {
        Self {
            capabilities: RangingCapabilities {
                distance: true,
                direction: true,
                foreground_only: true,
                max_concurrent_sessions: 4,
            },
            commands: Vec::new(),
            events: VecDeque::new(),
        }
    }
}

impl FakeRangingBackend {
    pub fn inject(&mut self, event: RangingEvent) {
        self.events.push_back(event);
    }

    #[must_use]
    pub fn commands(&self) -> &[RangingCommand] {
        &self.commands
    }
}

impl RangingBackend for FakeRangingBackend {
    fn capabilities(&self) -> RangingCapabilities {
        self.capabilities.clone()
    }

    fn submit(&mut self, command: RangingCommand) {
        self.commands.push(command);
    }

    fn poll_event(&mut self) -> Option<RangingEvent> {
        self.events.pop_front()
    }
}

/// Adapter for the private JSON contract implemented by `TcRangingApple`.
pub mod apple_wire {
    use super::{RangingCommand, RangingEvent};
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
        #[serde(rename = "peerID")]
        peer_id: Option<String>,
        token_base64: Option<String>,
        distance_meters: Option<f64>,
        direction: Option<Direction>,
        #[serde(default)]
        fields: BTreeMap<String, String>,
        error: Option<String>,
    }

    #[derive(Deserialize)]
    struct Direction {
        x: f64,
        #[allow(dead_code)]
        y: f64,
        z: f64,
    }

    /// Converts a semantic Nearby Interaction command to Apple's private wire value.
    pub fn command_to_value(command: &RangingCommand) -> Result<Value, AppleWireError> {
        let value = match command {
            RangingCommand::CreateDiscoveryToken {
                request_id,
                peer_id,
            } => json!({
                "type": "begin",
                "requestID": request_to_apple(request_id)?,
                "peerID": canonical_uuid(peer_id.as_str())?,
            }),
            RangingCommand::Start {
                request_id,
                peer_id,
                remote_discovery_token,
            } => json!({
                "type": "receiveToken",
                "requestID": request_to_apple(request_id)?,
                "peerID": canonical_uuid(peer_id.as_str())?,
                "tokenBase64": encode(remote_discovery_token),
            }),
            RangingCommand::Cancel {
                request_id,
                peer_id,
                reason,
            } => json!({
                "type": "cancel",
                "requestID": request_to_apple(request_id)?,
                "peerID": canonical_uuid(peer_id.as_str())?,
                "reason": reason,
            }),
        };
        Ok(value)
    }

    /// Converts a private NI callback to a semantic event using arrival time for
    /// measurements because Nearby Interaction does not expose a sample timestamp.
    pub fn event_from_value(value: Value) -> Result<Option<RangingEvent>, AppleWireError> {
        event_from_value_at(value, unix_time_millis())
    }

    /// Clock-injectable form for deterministic materialization and tests.
    pub fn event_from_value_at(
        value: Value,
        observed_at_ms: i64,
    ) -> Result<Option<RangingEvent>, AppleWireError> {
        let event: AppleEvent = serde_json::from_value(value).map_err(|error| {
            AppleWireError::new(format!("invalid Ranging Apple event: {error}"))
        })?;
        let request_id = event
            .request_id
            .as_deref()
            .map(request_from_apple)
            .transpose()?;
        let peer_id = event.peer_id.map(PeerId::from_string);
        let result = match event.event_type.as_str() {
            "localToken" => Some(RangingEvent::DiscoveryToken {
                request_id: required(request_id, "requestID")?,
                token: decode(&required(event.token_base64, "tokenBase64")?)?,
            }),
            "rangingStarted" | "rangingResumed" => Some(RangingEvent::Started {
                request_id: required(request_id, "requestID")?,
                peer_id: required(peer_id, "peerID")?,
            }),
            "measurement" => Some(RangingEvent::Measurement {
                peer_id: required(peer_id, "peerID")?,
                distance_m: event.distance_meters,
                direction_radians: event.direction.and_then(direction_radians),
                observed_at_ms,
            }),
            "measurementUnavailable" => Some(RangingEvent::Measurement {
                peer_id: required(peer_id, "peerID")?,
                distance_m: None,
                direction_radians: None,
                observed_at_ms,
            }),
            "rangingSuspended" => Some(RangingEvent::Suspended {
                peer_id: required(peer_id, "peerID")?,
                reason: event
                    .fields
                    .get("reason")
                    .cloned()
                    .unwrap_or_else(|| "suspended".into()),
            }),
            "rangingStopped" => Some(RangingEvent::Ended {
                peer_id: required(peer_id, "peerID")?,
                reason: event
                    .fields
                    .get("reason")
                    .cloned()
                    .unwrap_or_else(|| "stopped".into()),
            }),
            "commandFailed" | "rangingFailed" => Some(RangingEvent::Failed {
                request_id,
                code: event.event_type.clone(),
                message: event.error.unwrap_or_else(|| event.event_type.clone()),
                retryable: event.event_type != "commandFailed",
            }),
            // Capability, foreground, and whole-module stop acknowledgements
            // do not identify one semantic ranging session.
            _ => None,
        };
        Ok(result)
    }

    fn direction_radians(direction: Direction) -> Option<f64> {
        let magnitude = direction.x.hypot(direction.z);
        (magnitude > f64::EPSILON).then(|| direction.x.atan2(direction.z))
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

    #[test]
    fn contract_preserves_distance_when_direction_is_unavailable() {
        let event = RangingEvent::Measurement {
            peer_id: PeerId::from("b"),
            distance_m: Some(2.4),
            direction_radians: None,
            observed_at_ms: 10,
        };
        let json = serde_json::to_value(&event).unwrap();
        assert_eq!(json["distanceM"], 2.4);
        assert!(json["directionRadians"].is_null());
    }

    #[test]
    fn apple_command_contract_uses_begin_and_padded_token_base64() {
        let begin = RangingCommand::CreateDiscoveryToken {
            request_id: RequestId::from("req_00112233445566778899aabbccddeeff"),
            peer_id: PeerId::from("01234567-89ab-cdef-0123-456789abcdef"),
        };
        let value = apple_wire::command_to_value(&begin).expect("valid begin");
        assert_eq!(value["type"], "begin");
        assert_eq!(value["requestID"], "00112233-4455-6677-8899-aabbccddeeff");
        assert!(value.get("kind").is_none());

        let start = RangingCommand::Start {
            request_id: RequestId::from("req_00112233445566778899aabbccddeeff"),
            peer_id: PeerId::from("01234567-89ab-cdef-0123-456789abcdef"),
            remote_discovery_token: vec![1, 2],
        };
        let value = apple_wire::command_to_value(&start).expect("valid token");
        assert_eq!(value["type"], "receiveToken");
        assert_eq!(value["tokenBase64"], "AQI=");
    }

    #[test]
    fn apple_event_contract_keeps_distance_without_direction_and_maps_failure() {
        let event = apple_wire::event_from_value_at(
            serde_json::json!({
                "type": "measurement",
                "requestID": "00112233-4455-6677-8899-aabbccddeeff",
                "peerID": "01234567-89ab-cdef-0123-456789abcdef",
                "distanceMeters": 2.5
            }),
            42,
        )
        .expect("valid event");
        assert!(matches!(
            event,
            Some(RangingEvent::Measurement {
                distance_m: Some(2.5),
                direction_radians: None,
                observed_at_ms: 42,
                ..
            })
        ));

        let failure = apple_wire::event_from_value(serde_json::json!({
            "type": "commandFailed",
            "error": "background"
        }))
        .expect("valid failure");
        assert!(
            matches!(failure, Some(RangingEvent::Failed { code, .. }) if code == "commandFailed")
        );
    }
}
