//! Small credential/key storage capability. Platform objects (Keychain,
//! Keystore) remain owned by the registered native backend.

use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use tc_model::RequestId;
use zeroize::{Zeroize, ZeroizeOnDrop};

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SecureStorageCapabilities {
    pub hardware_backed_when_available: bool,
    pub device_only_accessibility: bool,
    pub biometric_policy: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize, Zeroize, ZeroizeOnDrop)]
#[serde(transparent)]
pub struct SecretValue(pub Vec<u8>);

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub enum SecureStorageCommand {
    Put {
        request_id: RequestId,
        key: String,
        value: SecretValue,
    },
    Get {
        request_id: RequestId,
        key: String,
    },
    Delete {
        request_id: RequestId,
        key: String,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub enum SecureStorageEvent {
    Stored {
        request_id: RequestId,
        key: String,
    },
    Loaded {
        request_id: RequestId,
        key: String,
        value: Option<SecretValue>,
    },
    Deleted {
        request_id: RequestId,
        key: String,
    },
    Failed {
        request_id: Option<RequestId>,
        code: String,
        message: String,
    },
}

pub trait SecureStorageBackend: Send {
    fn capabilities(&self) -> SecureStorageCapabilities;
    fn submit(&mut self, command: SecureStorageCommand);
    fn poll_event(&mut self) -> Option<SecureStorageEvent>;
}

pub struct SecureStorage<B: SecureStorageBackend> {
    backend: B,
}

impl<B: SecureStorageBackend> SecureStorage<B> {
    #[must_use]
    pub fn new(backend: B) -> Self {
        Self { backend }
    }

    #[must_use]
    pub fn capabilities(&self) -> SecureStorageCapabilities {
        self.backend.capabilities()
    }

    pub fn submit(&mut self, command: SecureStorageCommand) {
        self.backend.submit(command);
    }

    pub fn poll_event(&mut self) -> Option<SecureStorageEvent> {
        self.backend.poll_event()
    }
}

#[derive(Clone, Debug)]
pub struct FakeSecureStorageBackend {
    capabilities: SecureStorageCapabilities,
    commands: Vec<SecureStorageCommand>,
    events: VecDeque<SecureStorageEvent>,
}

impl Default for FakeSecureStorageBackend {
    fn default() -> Self {
        Self {
            capabilities: SecureStorageCapabilities {
                hardware_backed_when_available: true,
                device_only_accessibility: true,
                biometric_policy: true,
            },
            commands: Vec::new(),
            events: VecDeque::new(),
        }
    }
}

impl FakeSecureStorageBackend {
    pub fn inject(&mut self, event: SecureStorageEvent) {
        self.events.push_back(event);
    }

    #[must_use]
    pub fn commands(&self) -> &[SecureStorageCommand] {
        &self.commands
    }
}

impl SecureStorageBackend for FakeSecureStorageBackend {
    fn capabilities(&self) -> SecureStorageCapabilities {
        self.capabilities.clone()
    }

    fn submit(&mut self, command: SecureStorageCommand) {
        self.commands.push(command);
    }

    fn poll_event(&mut self) -> Option<SecureStorageEvent> {
        self.events.pop_front()
    }
}

/// Adapter for the private JSON contract implemented by `TcSecureStorageApple`.
pub mod apple_wire {
    use super::{SecretValue, SecureStorageCommand, SecureStorageEvent};
    use base64::Engine as _;
    use serde::Deserialize;
    use serde_json::{json, Value};
    use std::fmt::{Display, Formatter};
    use tc_model::RequestId;

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
        key: Option<String>,
        data_base64: Option<String>,
        error: Option<String>,
        os_status: Option<i32>,
    }

    /// Converts a semantic credential operation to Keychain's private wire value.
    pub fn command_to_value(command: &SecureStorageCommand) -> Result<Value, AppleWireError> {
        let value = match command {
            SecureStorageCommand::Put {
                request_id,
                key,
                value,
            } => json!({
                "type": "set",
                "requestID": request_to_apple(request_id)?,
                "key": key,
                "dataBase64": encode(&value.0),
                "accessibility": "afterFirstUnlockThisDeviceOnly",
            }),
            SecureStorageCommand::Get { request_id, key } => json!({
                "type": "get",
                "requestID": request_to_apple(request_id)?,
                "key": key,
            }),
            SecureStorageCommand::Delete { request_id, key } => json!({
                "type": "delete",
                "requestID": request_to_apple(request_id)?,
                "key": key,
            }),
        };
        Ok(value)
    }

    /// Converts direct Keychain responses to semantic storage events. List,
    /// contains, configure, and snapshot callbacks are module diagnostics.
    pub fn event_from_value(value: Value) -> Result<Option<SecureStorageEvent>, AppleWireError> {
        let event: AppleEvent = serde_json::from_value(value).map_err(|error| {
            AppleWireError::new(format!("invalid SecureStorage Apple event: {error}"))
        })?;
        let request_id = event
            .request_id
            .as_deref()
            .map(request_from_apple)
            .transpose()?;
        let result = match event.event_type.as_str() {
            "valueStored" => Some(SecureStorageEvent::Stored {
                request_id: required(request_id, "requestID")?,
                key: required(event.key, "key")?,
            }),
            "valueLoaded" => Some(SecureStorageEvent::Loaded {
                request_id: required(request_id, "requestID")?,
                key: required(event.key, "key")?,
                value: Some(SecretValue(decode(&required(
                    event.data_base64,
                    "dataBase64",
                )?)?)),
            }),
            "valueMissing" => Some(SecureStorageEvent::Loaded {
                request_id: required(request_id, "requestID")?,
                key: required(event.key, "key")?,
                value: None,
            }),
            "valueDeleted" => Some(SecureStorageEvent::Deleted {
                request_id: required(request_id, "requestID")?,
                key: required(event.key, "key")?,
            }),
            "commandFailed" => Some(SecureStorageEvent::Failed {
                request_id,
                code: event.os_status.map_or_else(
                    || "commandFailed".into(),
                    |status| format!("osStatus:{status}"),
                ),
                message: event
                    .error
                    .unwrap_or_else(|| "Keychain command failed".into()),
            }),
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
    fn set_contract_uses_keychain_field_names_and_padded_base64() {
        let command = SecureStorageCommand::Put {
            request_id: RequestId::from("req_00112233445566778899aabbccddeeff"),
            key: "group-key".into(),
            value: SecretValue(vec![1, 2]),
        };
        let value = apple_wire::command_to_value(&command).expect("valid command");
        assert_eq!(value["type"], "set");
        assert_eq!(value["dataBase64"], "AQI=");
        assert_eq!(value["accessibility"], "afterFirstUnlockThisDeviceOnly");
        assert!(value.get("kind").is_none());
    }

    #[test]
    fn loaded_missing_and_failure_contracts_are_semantic() {
        let loaded = apple_wire::event_from_value(serde_json::json!({
            "type": "valueLoaded",
            "requestID": "00112233-4455-6677-8899-aabbccddeeff",
            "key": "group-key",
            "dataBase64": "AQI="
        }))
        .expect("valid loaded event");
        assert!(
            matches!(loaded, Some(SecureStorageEvent::Loaded { value: Some(secret), .. }) if secret.0 == [1, 2])
        );

        let missing = apple_wire::event_from_value(serde_json::json!({
            "type": "valueMissing",
            "requestID": "00112233-4455-6677-8899-aabbccddeeff",
            "key": "missing"
        }))
        .expect("valid missing event");
        assert!(matches!(
            missing,
            Some(SecureStorageEvent::Loaded { value: None, .. })
        ));

        let failure = apple_wire::event_from_value(serde_json::json!({
            "type": "commandFailed",
            "error": "denied",
            "osStatus": -25293
        }))
        .expect("valid failure");
        assert!(
            matches!(failure, Some(SecureStorageEvent::Failed { code, .. }) if code == "osStatus:-25293")
        );
    }
}
