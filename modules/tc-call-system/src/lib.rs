//! System call UI and audio-session capability. Encoded realtime audio remains
//! a separate peer-transport stream.

use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use tc_model::{CallId, PeerId, RequestId};

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CallSystemCapabilities {
    pub incoming_call_ui: bool,
    pub background_audio: bool,
    pub voice_processing: bool,
    pub bluetooth_routes: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum AudioRoute {
    Receiver,
    Speaker,
    WiredHeadset,
    Bluetooth,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub enum CallSystemCommand {
    ReportIncoming {
        request_id: RequestId,
        call_id: CallId,
        peer_id: PeerId,
        display_name: String,
    },
    ReportOutgoing {
        request_id: RequestId,
        call_id: CallId,
        peer_id: PeerId,
        display_name: String,
    },
    ActivateAudio {
        request_id: RequestId,
        call_id: CallId,
    },
    DeactivateAudio {
        request_id: RequestId,
        call_id: CallId,
    },
    SetMuted {
        request_id: RequestId,
        call_id: CallId,
        muted: bool,
    },
    SetRoute {
        request_id: RequestId,
        route: AudioRoute,
    },
    PlayAudio {
        request_id: RequestId,
        call_id: CallId,
        pcm16: Vec<u8>,
        sample_rate: u32,
        channel_count: u32,
        sequence: u64,
        timestamp_ms: i64,
    },
    End {
        request_id: RequestId,
        call_id: CallId,
        reason: String,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub enum CallSystemEvent {
    IncomingReported {
        request_id: RequestId,
        call_id: CallId,
    },
    OutgoingReported {
        request_id: RequestId,
        call_id: CallId,
    },
    UserAnswered {
        call_id: CallId,
    },
    UserRejected {
        call_id: CallId,
    },
    UserEnded {
        call_id: CallId,
    },
    AudioActivated {
        call_id: CallId,
    },
    AudioDeactivated {
        call_id: CallId,
    },
    AudioInterrupted {
        call_id: CallId,
        should_resume: bool,
    },
    RouteChanged {
        route: AudioRoute,
    },
    AudioFrame {
        call_id: CallId,
        pcm16: Vec<u8>,
        sample_rate: u32,
        channel_count: u32,
        sequence: u64,
        timestamp_ms: i64,
    },
    MutedChanged {
        call_id: CallId,
        muted: bool,
    },
    Failed {
        request_id: Option<RequestId>,
        code: String,
        message: String,
    },
}

pub trait CallSystemBackend: Send {
    fn capabilities(&self) -> CallSystemCapabilities;
    fn submit(&mut self, command: CallSystemCommand);
    fn poll_event(&mut self) -> Option<CallSystemEvent>;
}

pub struct CallSystem<B: CallSystemBackend> {
    backend: B,
}

impl<B: CallSystemBackend> CallSystem<B> {
    #[must_use]
    pub fn new(backend: B) -> Self {
        Self { backend }
    }

    #[must_use]
    pub fn capabilities(&self) -> CallSystemCapabilities {
        self.backend.capabilities()
    }

    pub fn submit(&mut self, command: CallSystemCommand) {
        self.backend.submit(command);
    }

    pub fn poll_event(&mut self) -> Option<CallSystemEvent> {
        self.backend.poll_event()
    }
}

#[derive(Clone, Debug)]
pub struct FakeCallSystemBackend {
    capabilities: CallSystemCapabilities,
    commands: Vec<CallSystemCommand>,
    events: VecDeque<CallSystemEvent>,
}

impl Default for FakeCallSystemBackend {
    fn default() -> Self {
        Self {
            capabilities: CallSystemCapabilities {
                incoming_call_ui: true,
                background_audio: true,
                voice_processing: true,
                bluetooth_routes: true,
            },
            commands: Vec::new(),
            events: VecDeque::new(),
        }
    }
}

impl FakeCallSystemBackend {
    pub fn inject(&mut self, event: CallSystemEvent) {
        self.events.push_back(event);
    }

    #[must_use]
    pub fn commands(&self) -> &[CallSystemCommand] {
        &self.commands
    }
}

impl CallSystemBackend for FakeCallSystemBackend {
    fn capabilities(&self) -> CallSystemCapabilities {
        self.capabilities.clone()
    }

    fn submit(&mut self, command: CallSystemCommand) {
        self.commands.push(command);
    }

    fn poll_event(&mut self) -> Option<CallSystemEvent> {
        self.events.pop_front()
    }
}

/// Adapter for the private JSON contract implemented by `TcCallSystemApple`.
pub mod apple_wire {
    use super::{AudioRoute, CallSystemCommand, CallSystemEvent};
    use base64::Engine as _;
    use serde::Deserialize;
    use serde_json::{json, Value};
    use std::collections::BTreeMap;
    use std::fmt::{Display, Formatter};
    use tc_model::{CallId, RequestId};

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
        #[serde(rename = "callID")]
        call_id: Option<String>,
        pcm16_base64: Option<String>,
        sample_rate: Option<f64>,
        channel_count: Option<u32>,
        sequence: Option<u64>,
        timestamp_millis: Option<u64>,
        #[serde(default)]
        fields: BTreeMap<String, String>,
        error: Option<String>,
    }

    /// Converts a semantic call/audio command to Apple CallKit's private wire value.
    pub fn command_to_value(command: &CallSystemCommand) -> Result<Value, AppleWireError> {
        let value = match command {
            CallSystemCommand::ReportIncoming {
                request_id,
                call_id,
                peer_id,
                display_name,
            } => json!({
                "type": "reportIncoming",
                "requestID": request_to_apple(request_id)?,
                "callID": call_to_apple(call_id)?,
                "peerID": peer_id.as_str(),
                "displayName": display_name,
            }),
            CallSystemCommand::ReportOutgoing {
                request_id,
                call_id,
                peer_id,
                display_name,
            } => json!({
                "type": "startOutgoing",
                "requestID": request_to_apple(request_id)?,
                "callID": call_to_apple(call_id)?,
                "peerID": peer_id.as_str(),
                "displayName": display_name,
            }),
            // Remote answer is the Apple backend operation that prepares the
            // audio session for an already-reported call.
            CallSystemCommand::ActivateAudio {
                request_id,
                call_id,
            } => json!({
                "type": "remoteAnswered",
                "requestID": request_to_apple(request_id)?,
                "callID": call_to_apple(call_id)?,
            }),
            CallSystemCommand::DeactivateAudio {
                request_id,
                call_id,
            } => json!({
                "type": "remoteEnded",
                "requestID": request_to_apple(request_id)?,
                "callID": call_to_apple(call_id)?,
                "reason": "audioDeactivated",
            }),
            CallSystemCommand::SetMuted {
                request_id,
                call_id,
                muted,
            } => json!({
                "type": "setMuted",
                "requestID": request_to_apple(request_id)?,
                "callID": call_to_apple(call_id)?,
                "muted": muted,
            }),
            CallSystemCommand::SetRoute { .. } => {
                return Err(AppleWireError::new(
                    "TcCallSystemApple intentionally lets AVAudioSession/system UI own routing",
                ));
            }
            CallSystemCommand::PlayAudio {
                request_id,
                call_id,
                pcm16,
                sample_rate,
                channel_count,
                sequence,
                timestamp_ms,
            } => json!({
                "type": "playAudio",
                "requestID": request_to_apple(request_id)?,
                "callID": call_to_apple(call_id)?,
                "pcm16Base64": encode(pcm16),
                "sampleRate": sample_rate,
                "channelCount": channel_count,
                "sequence": sequence,
                "timestampMillis": nonnegative(*timestamp_ms, "timestampMillis")?,
            }),
            CallSystemCommand::End {
                request_id,
                call_id,
                reason,
            } => json!({
                "type": "end",
                "requestID": request_to_apple(request_id)?,
                "callID": call_to_apple(call_id)?,
                "reason": reason,
            }),
        };
        Ok(value)
    }

    /// Converts Apple callbacks to semantic call/audio events. Buffer telemetry
    /// and capability snapshots are intentionally treated as diagnostics.
    pub fn event_from_value(value: Value) -> Result<Option<CallSystemEvent>, AppleWireError> {
        let event: AppleEvent = serde_json::from_value(value).map_err(|error| {
            AppleWireError::new(format!("invalid CallSystem Apple event: {error}"))
        })?;
        let request_id = event
            .request_id
            .as_deref()
            .map(request_from_apple)
            .transpose()?;
        let call_id = event.call_id.as_deref().map(call_from_apple).transpose()?;
        let result = match event.event_type.as_str() {
            "incomingCallReported" => Some(CallSystemEvent::IncomingReported {
                request_id: required(request_id, "requestID")?,
                call_id: required(call_id, "callID")?,
            }),
            "outgoingCallRequested" => Some(CallSystemEvent::OutgoingReported {
                request_id: required(request_id, "requestID")?,
                call_id: required(call_id, "callID")?,
            }),
            "answerSignalingRequested" => Some(CallSystemEvent::UserAnswered {
                call_id: required(call_id, "callID")?,
            }),
            "endSignalingRequested" | "remoteEnded" => Some(CallSystemEvent::UserEnded {
                call_id: required(call_id, "callID")?,
            }),
            "audioActivated" | "remoteAnswered" => Some(CallSystemEvent::AudioActivated {
                call_id: required(call_id, "callID")?,
            }),
            "audioDeactivated" => Some(CallSystemEvent::AudioDeactivated {
                call_id: required(call_id, "callID")?,
            }),
            "audioInterruption" => Some(CallSystemEvent::AudioInterrupted {
                call_id: required(call_id, "callID")?,
                should_resume: event
                    .fields
                    .get("phase")
                    .is_some_and(|phase| phase.to_ascii_lowercase().contains("ended")),
            }),
            "audioRouteChanged" | "audioRouteSnapshot" => Some(CallSystemEvent::RouteChanged {
                route: route_from_fields(&event.fields),
            }),
            "audioFrame" => Some(CallSystemEvent::AudioFrame {
                call_id: required(call_id, "callID")?,
                pcm16: decode(&required(event.pcm16_base64, "pcm16Base64")?)?,
                sample_rate: sample_rate(required(event.sample_rate, "sampleRate")?)?,
                channel_count: required(event.channel_count, "channelCount")?,
                sequence: required(event.sequence, "sequence")?,
                timestamp_ms: i64::try_from(required(event.timestamp_millis, "timestampMillis")?)
                    .map_err(|_| AppleWireError::new("timestampMillis exceeds i64"))?,
            }),
            "muteChanged" => Some(CallSystemEvent::MutedChanged {
                call_id: required(call_id, "callID")?,
                muted: event
                    .fields
                    .get("muted")
                    .is_some_and(|value| value.eq_ignore_ascii_case("true")),
            }),
            "incomingCallReportFailed"
            | "transactionFailed"
            | "audioFailed"
            | "commandFailed"
            | "providerReset"
            | "mediaServicesReset" => Some(CallSystemEvent::Failed {
                request_id,
                code: event.event_type.clone(),
                message: event.error.unwrap_or_else(|| event.event_type.clone()),
            }),
            // Signaling kickoff, route details, jitter statistics, and command
            // acknowledgements are diagnostics at this module boundary.
            _ => None,
        };
        Ok(result)
    }

    fn route_from_fields(fields: &BTreeMap<String, String>) -> AudioRoute {
        let route = fields
            .get("outputs")
            .or_else(|| fields.get("inputs"))
            .map_or("", String::as_str)
            .to_ascii_lowercase();
        if route.contains("bluetooth") {
            AudioRoute::Bluetooth
        } else if route.contains("headphone") || route.contains("headset") || route.contains("usb")
        {
            AudioRoute::WiredHeadset
        } else if route.contains("speaker") {
            AudioRoute::Speaker
        } else {
            AudioRoute::Receiver
        }
    }

    fn sample_rate(value: f64) -> Result<u32, AppleWireError> {
        if !value.is_finite() || value <= 0.0 || value > f64::from(u32::MAX) {
            return Err(AppleWireError::new("sampleRate is out of range"));
        }
        Ok(value.round() as u32)
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

    fn nonnegative(value: i64, field: &str) -> Result<u64, AppleWireError> {
        u64::try_from(value)
            .map_err(|_| AppleWireError::new(format!("{field} must be nonnegative")))
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

    fn call_to_apple(value: &CallId) -> Result<String, AppleWireError> {
        prefixed_id_to_uuid(value.as_str(), "call_")
    }

    fn call_from_apple(value: &str) -> Result<CallId, AppleWireError> {
        uuid_to_prefixed_id(value, "call_").map(CallId::from_string)
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

    #[test]
    fn command_contract_uses_callkit_names_and_padded_base64() {
        let command = CallSystemCommand::PlayAudio {
            request_id: RequestId::from("req_00112233445566778899aabbccddeeff"),
            call_id: CallId::from("call_ffeeddccbbaa99887766554433221100"),
            pcm16: vec![1, 2],
            sample_rate: 48_000,
            channel_count: 1,
            sequence: 9,
            timestamp_ms: 42,
        };
        let value = apple_wire::command_to_value(&command).expect("valid command");
        assert_eq!(value["type"], "playAudio");
        assert_eq!(value["callID"], "ffeeddcc-bbaa-9988-7766-554433221100");
        assert_eq!(value["pcm16Base64"], "AQI=");
        assert!(value.get("kind").is_none());
    }

    #[test]
    fn event_contract_decodes_pcm_and_command_failure() {
        let frame = apple_wire::event_from_value(serde_json::json!({
            "type": "audioFrame",
            "callID": "ffeeddcc-bbaa-9988-7766-554433221100",
            "pcm16Base64": "AQI=",
            "sampleRate": 48000.0,
            "channelCount": 1,
            "sequence": 9,
            "timestampMillis": 42
        }))
        .expect("valid event")
        .expect("semantic frame");
        assert!(matches!(
            frame,
            CallSystemEvent::AudioFrame { pcm16, sequence: 9, .. } if pcm16 == [1, 2]
        ));

        let failure = apple_wire::event_from_value(serde_json::json!({
            "type": "commandFailed",
            "error": "bad"
        }))
        .expect("valid failure");
        assert!(
            matches!(failure, Some(CallSystemEvent::Failed { code, .. }) if code == "commandFailed")
        );
    }
}
