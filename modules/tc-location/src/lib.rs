//! Platform-neutral location sampling capability.

use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use tc_model::{LocationSample, RequestId};

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocationCapabilities {
    pub precise_location: bool,
    pub background_updates: bool,
    pub service_session: bool,
    pub background_activity_session: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum LocationAuthorization {
    NotDetermined,
    Denied,
    WhenInUse,
    Always,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub enum LocationCommand {
    StartTravelUpdates {
        request_id: RequestId,
        background: bool,
    },
    StopTravelUpdates {
        request_id: RequestId,
    },
    RequestSample {
        request_id: RequestId,
        desired_freshness_ms: i64,
        deadline_ms: i64,
    },
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub enum LocationEvent {
    Started {
        request_id: RequestId,
    },
    Stopped {
        request_id: RequestId,
    },
    AuthorizationChanged {
        status: LocationAuthorization,
    },
    Sample {
        request_id: Option<RequestId>,
        sample: LocationSample,
        from_cache: bool,
    },
    TimedOut {
        request_id: RequestId,
        stale_sample: Option<LocationSample>,
    },
    Failed {
        request_id: Option<RequestId>,
        code: String,
        message: String,
        retryable: bool,
    },
}

pub trait LocationBackend: Send {
    fn capabilities(&self) -> LocationCapabilities;
    fn submit(&mut self, command: LocationCommand);
    fn poll_event(&mut self) -> Option<LocationEvent>;
}

pub struct Location<B: LocationBackend> {
    backend: B,
}

impl<B: LocationBackend> Location<B> {
    #[must_use]
    pub fn new(backend: B) -> Self {
        Self { backend }
    }

    #[must_use]
    pub fn capabilities(&self) -> LocationCapabilities {
        self.backend.capabilities()
    }

    pub fn submit(&mut self, command: LocationCommand) {
        self.backend.submit(command);
    }

    pub fn poll_event(&mut self) -> Option<LocationEvent> {
        self.backend.poll_event()
    }
}

#[derive(Clone, Debug)]
pub struct FakeLocationBackend {
    capabilities: LocationCapabilities,
    commands: Vec<LocationCommand>,
    events: VecDeque<LocationEvent>,
}

impl Default for FakeLocationBackend {
    fn default() -> Self {
        Self {
            capabilities: LocationCapabilities {
                precise_location: true,
                background_updates: true,
                service_session: true,
                background_activity_session: true,
            },
            commands: Vec::new(),
            events: VecDeque::new(),
        }
    }
}

impl FakeLocationBackend {
    pub fn inject(&mut self, event: LocationEvent) {
        self.events.push_back(event);
    }

    #[must_use]
    pub fn commands(&self) -> &[LocationCommand] {
        &self.commands
    }
}

impl LocationBackend for FakeLocationBackend {
    fn capabilities(&self) -> LocationCapabilities {
        self.capabilities.clone()
    }

    fn submit(&mut self, command: LocationCommand) {
        self.commands.push(command);
    }

    fn poll_event(&mut self) -> Option<LocationEvent> {
        self.events.pop_front()
    }
}

/// Adapter for the private JSON contract implemented by `TcLocationApple`.
pub mod apple_wire {
    use super::{LocationCommand, LocationEvent};
    use serde::Deserialize;
    use serde_json::{json, Value};
    use std::collections::BTreeMap;
    use std::fmt::{Display, Formatter};
    use tc_model::{LocationSample, RequestId};

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
        sample: Option<AppleSample>,
        status: Option<String>,
        #[serde(default)]
        fields: BTreeMap<String, String>,
        error: Option<String>,
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct AppleSample {
        latitude: f64,
        longitude: f64,
        altitude: f64,
        horizontal_accuracy: f64,
        #[allow(dead_code)]
        vertical_accuracy: f64,
        speed: f64,
        #[allow(dead_code)]
        speed_accuracy: f64,
        course: f64,
        #[allow(dead_code)]
        course_accuracy: f64,
        sampled_at_epoch_millis: u64,
        #[allow(dead_code)]
        stationary: bool,
        #[allow(dead_code)]
        simulated: Option<bool>,
        #[allow(dead_code)]
        produced_by_accessory: Option<bool>,
    }

    /// Converts a semantic location command to Apple Core Location's wire value.
    pub fn command_to_value(command: &LocationCommand) -> Result<Value, AppleWireError> {
        let value = match command {
            LocationCommand::StartTravelUpdates {
                request_id,
                background,
            } => json!({
                "type": "start",
                "requestID": request_to_apple(request_id)?,
                "liveConfiguration": if *background { "otherNavigation" } else { "default" },
                "minimumEmitIntervalMillis": 10_000,
                "minimumDistanceMeters": 10.0,
            }),
            LocationCommand::StopTravelUpdates { request_id } => json!({
                "type": "stop",
                "requestID": request_to_apple(request_id)?,
            }),
            LocationCommand::RequestSample {
                request_id,
                desired_freshness_ms,
                deadline_ms,
            } => json!({
                "type": "requestSample",
                "requestID": request_to_apple(request_id)?,
                "desiredFreshnessMillis": nonnegative(*desired_freshness_ms, "desiredFreshnessMillis")?,
                "deadlineEpochMillis": nonnegative(*deadline_ms, "deadlineEpochMillis")?,
            }),
        };
        Ok(value)
    }

    /// Converts a private callback to a semantic sample/lifecycle event.
    pub fn event_from_value(value: Value) -> Result<Option<LocationEvent>, AppleWireError> {
        let event: AppleEvent = serde_json::from_value(value).map_err(|error| {
            AppleWireError::new(format!("invalid Location Apple event: {error}"))
        })?;
        let request_id = event
            .request_id
            .as_deref()
            .map(request_from_apple)
            .transpose()?;
        let result = match event.event_type.as_str() {
            "commandCompleted" => match event.fields.get("command").map(String::as_str) {
                Some("start") => Some(LocationEvent::Started {
                    request_id: required(request_id, "requestID")?,
                }),
                Some("stop") => Some(LocationEvent::Stopped {
                    request_id: required(request_id, "requestID")?,
                }),
                _ => None,
            },
            "locationUpdated" => Some(LocationEvent::Sample {
                request_id,
                sample: sample_from_apple(required(event.sample, "sample")?)?,
                from_cache: false,
            }),
            "sampleResponse" => match event.status.as_deref() {
                Some("fresh") => Some(LocationEvent::Sample {
                    request_id,
                    sample: sample_from_apple(required(event.sample, "sample")?)?,
                    from_cache: event
                        .fields
                        .get("source")
                        .is_some_and(|source| source == "cache"),
                }),
                Some("stale") | Some("timeout") | Some("sharingPaused") => {
                    Some(LocationEvent::TimedOut {
                        request_id: required(request_id, "requestID")?,
                        stale_sample: event.sample.map(sample_from_apple).transpose()?,
                    })
                }
                status => {
                    return Err(AppleWireError::new(format!(
                        "unknown sampleResponse status {status:?}"
                    )));
                }
            },
            event_type if event_type == "commandFailed" || event_type.ends_with("Failed") => {
                Some(LocationEvent::Failed {
                    request_id,
                    code: event.event_type.clone(),
                    message: event.error.unwrap_or_else(|| event.event_type.clone()),
                    retryable: event.event_type != "commandFailed",
                })
            }
            // Capability, sharing/foreground state, and CL diagnostic streams
            // do not alter the platform-neutral location sample model.
            _ => None,
        };
        Ok(result)
    }

    fn sample_from_apple(sample: AppleSample) -> Result<LocationSample, AppleWireError> {
        Ok(LocationSample {
            latitude: sample.latitude,
            longitude: sample.longitude,
            altitude_m: sample.altitude.is_finite().then_some(sample.altitude),
            horizontal_accuracy_m: sample.horizontal_accuracy,
            speed_mps: (sample.speed >= 0.0 && sample.speed.is_finite()).then_some(sample.speed),
            course_degrees: (sample.course >= 0.0 && sample.course.is_finite())
                .then_some(sample.course),
            sampled_at_ms: i64::try_from(sample.sampled_at_epoch_millis)
                .map_err(|_| AppleWireError::new("sampledAtEpochMillis exceeds i64"))?,
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
    fn command_contract_uses_private_type_and_deadline_names() {
        let command = LocationCommand::RequestSample {
            request_id: RequestId::from("req_00112233445566778899aabbccddeeff"),
            desired_freshness_ms: 5_000,
            deadline_ms: 123_000,
        };
        let value = apple_wire::command_to_value(&command).expect("valid command");
        assert_eq!(value["type"], "requestSample");
        assert_eq!(value["desiredFreshnessMillis"], 5_000);
        assert_eq!(value["deadlineEpochMillis"], 123_000);
        assert!(value.get("kind").is_none());
    }

    #[test]
    fn event_contract_converts_apple_sample_and_failure() {
        let event = apple_wire::event_from_value(serde_json::json!({
            "type": "locationUpdated",
            "sample": {
                "latitude": 32.0,
                "longitude": 118.0,
                "altitude": 20.0,
                "horizontalAccuracy": 4.0,
                "verticalAccuracy": 5.0,
                "speed": -1.0,
                "speedAccuracy": -1.0,
                "course": 90.0,
                "courseAccuracy": 3.0,
                "sampledAtEpochMillis": 42,
                "stationary": true
            }
        }))
        .expect("valid event")
        .expect("semantic sample");
        assert!(
            matches!(event, LocationEvent::Sample { sample, .. } if sample.speed_mps.is_none() && sample.course_degrees == Some(90.0))
        );

        let failure = apple_wire::event_from_value(serde_json::json!({
            "type": "commandFailed",
            "error": "denied"
        }))
        .expect("valid failure");
        assert!(
            matches!(failure, Some(LocationEvent::Failed { code, .. }) if code == "commandFailed")
        );
    }
}
