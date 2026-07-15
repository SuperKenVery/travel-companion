//! Local-notification capability; it cannot represent remote/APNs delivery.

use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use tc_model::RequestId;

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NotificationCapabilities {
    pub local_notifications: bool,
    pub actions: bool,
    pub time_sensitive: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum NotificationAuthorization {
    NotDetermined,
    Denied,
    Authorized,
    Provisional,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub enum NotificationCommand {
    RequestAuthorization {
        request_id: RequestId,
    },
    Schedule {
        request_id: RequestId,
        identifier: String,
        title: String,
        body: String,
        deep_link: Option<String>,
        merge_key: Option<String>,
        time_sensitive: bool,
    },
    Cancel {
        request_id: RequestId,
        identifier: String,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub enum NotificationEvent {
    AuthorizationChanged {
        status: NotificationAuthorization,
    },
    Scheduled {
        request_id: RequestId,
        identifier: String,
    },
    Cancelled {
        request_id: RequestId,
        identifier: String,
    },
    Opened {
        identifier: String,
        deep_link: Option<String>,
        action: Option<String>,
    },
    Failed {
        request_id: Option<RequestId>,
        code: String,
        message: String,
    },
}

pub trait NotificationsBackend: Send {
    fn capabilities(&self) -> NotificationCapabilities;
    fn submit(&mut self, command: NotificationCommand);
    fn poll_event(&mut self) -> Option<NotificationEvent>;
}

pub struct Notifications<B: NotificationsBackend> {
    backend: B,
}

impl<B: NotificationsBackend> Notifications<B> {
    #[must_use]
    pub fn new(backend: B) -> Self {
        Self { backend }
    }

    #[must_use]
    pub fn capabilities(&self) -> NotificationCapabilities {
        self.backend.capabilities()
    }

    pub fn submit(&mut self, command: NotificationCommand) {
        self.backend.submit(command);
    }

    pub fn poll_event(&mut self) -> Option<NotificationEvent> {
        self.backend.poll_event()
    }
}

#[derive(Clone, Debug)]
pub struct FakeNotificationsBackend {
    capabilities: NotificationCapabilities,
    commands: Vec<NotificationCommand>,
    events: VecDeque<NotificationEvent>,
}

impl Default for FakeNotificationsBackend {
    fn default() -> Self {
        Self {
            capabilities: NotificationCapabilities {
                local_notifications: true,
                actions: true,
                time_sensitive: true,
            },
            commands: Vec::new(),
            events: VecDeque::new(),
        }
    }
}

impl FakeNotificationsBackend {
    pub fn inject(&mut self, event: NotificationEvent) {
        self.events.push_back(event);
    }

    #[must_use]
    pub fn commands(&self) -> &[NotificationCommand] {
        &self.commands
    }
}

impl NotificationsBackend for FakeNotificationsBackend {
    fn capabilities(&self) -> NotificationCapabilities {
        self.capabilities.clone()
    }

    fn submit(&mut self, command: NotificationCommand) {
        self.commands.push(command);
    }

    fn poll_event(&mut self) -> Option<NotificationEvent> {
        self.events.pop_front()
    }
}

/// Adapter for the private JSON contract implemented by `TcNotificationsApple`.
pub mod apple_wire {
    use super::{NotificationAuthorization, NotificationCommand, NotificationEvent};
    use serde::Deserialize;
    use serde_json::{json, Map, Value};
    use std::collections::BTreeMap;
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
        identifier: Option<String>,
        action_identifier: Option<String>,
        #[serde(default)]
        user_info: BTreeMap<String, String>,
        #[serde(default)]
        fields: BTreeMap<String, String>,
        error: Option<String>,
    }

    /// Converts a semantic notification command to UserNotifications' private wire value.
    pub fn command_to_value(command: &NotificationCommand) -> Result<Value, AppleWireError> {
        let value = match command {
            NotificationCommand::RequestAuthorization { request_id } => json!({
                "type": "requestAuthorization",
                "requestID": request_to_apple(request_id)?,
            }),
            NotificationCommand::Schedule {
                request_id,
                identifier,
                title,
                body,
                deep_link,
                merge_key,
                time_sensitive,
            } => {
                let mut user_info = Map::new();
                user_info.insert(
                    "semanticIdentifier".into(),
                    Value::String(identifier.clone()),
                );
                if let Some(link) = deep_link {
                    user_info.insert("deepLink".into(), Value::String(link.clone()));
                }
                user_info.insert(
                    "timeSensitive".into(),
                    Value::String(time_sensitive.to_string()),
                );
                json!({
                    "type": "schedule",
                    "requestID": request_to_apple(request_id)?,
                    // Reusing an Apple identifier is the backend's coalescing primitive.
                    "identifier": merge_key.as_deref().unwrap_or(identifier),
                    "title": title,
                    "body": body,
                    "threadIdentifier": merge_key,
                    "sound": true,
                    "userInfo": user_info,
                })
            }
            NotificationCommand::Cancel {
                request_id,
                identifier,
            } => json!({
                "type": "remove",
                "requestID": request_to_apple(request_id)?,
                "identifier": identifier,
            }),
        };
        Ok(value)
    }

    /// Converts Apple notification callbacks to the semantic model.
    pub fn event_from_value(value: Value) -> Result<Option<NotificationEvent>, AppleWireError> {
        let event: AppleEvent = serde_json::from_value(value).map_err(|error| {
            AppleWireError::new(format!("invalid Notifications Apple event: {error}"))
        })?;
        let request_id = event
            .request_id
            .as_deref()
            .map(request_from_apple)
            .transpose()?;
        let result = match event.event_type.as_str() {
            "authorizationResult" => Some(NotificationEvent::AuthorizationChanged {
                status: if event
                    .fields
                    .get("granted")
                    .is_some_and(|value| value.eq_ignore_ascii_case("true"))
                {
                    NotificationAuthorization::Authorized
                } else {
                    NotificationAuthorization::Denied
                },
            }),
            "capabilitySnapshot" => event.fields.get("authorizationStatus").map(|status| {
                NotificationEvent::AuthorizationChanged {
                    status: authorization_from_apple(status),
                }
            }),
            "notificationScheduled" => Some(NotificationEvent::Scheduled {
                request_id: required(request_id, "requestID")?,
                identifier: required(event.identifier, "identifier")?,
            }),
            "notificationsRemoved" => Some(NotificationEvent::Cancelled {
                request_id: required(request_id, "requestID")?,
                // The Apple completion reports a count rather than echoing IDs.
                identifier: event.identifier.unwrap_or_else(|| "*".to_owned()),
            }),
            "notificationResponse" => Some(NotificationEvent::Opened {
                identifier: event
                    .user_info
                    .get("semanticIdentifier")
                    .cloned()
                    .or(event.identifier)
                    .ok_or_else(|| AppleWireError::new("missing identifier"))?,
                deep_link: event.user_info.get("deepLink").cloned(),
                action: event.action_identifier,
            }),
            "commandFailed" => Some(NotificationEvent::Failed {
                request_id,
                code: "commandFailed".into(),
                message: event
                    .error
                    .unwrap_or_else(|| "notification command failed".into()),
            }),
            // Presentation callbacks and start acknowledgements are diagnostics;
            // user interaction is represented by notificationResponse above.
            _ => None,
        };
        Ok(result)
    }

    fn authorization_from_apple(value: &str) -> NotificationAuthorization {
        let value = value.to_ascii_lowercase();
        if value.contains("provisional") {
            NotificationAuthorization::Provisional
        } else if value.contains("authorized") || value.contains("ephemeral") {
            NotificationAuthorization::Authorized
        } else if value.contains("denied") {
            NotificationAuthorization::Denied
        } else {
            NotificationAuthorization::NotDetermined
        }
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
    fn schedule_contract_coalesces_and_preserves_deep_link() {
        let command = NotificationCommand::Schedule {
            request_id: RequestId::from("req_00112233445566778899aabbccddeeff"),
            identifier: "message-7".into(),
            title: "Ken".into(),
            body: "Hello".into(),
            deep_link: Some("travel://chat/7".into()),
            merge_key: Some("chat-7".into()),
            time_sensitive: true,
        };
        let value = apple_wire::command_to_value(&command).expect("valid command");
        assert_eq!(value["type"], "schedule");
        assert_eq!(value["identifier"], "chat-7");
        assert_eq!(value["userInfo"]["deepLink"], "travel://chat/7");
        assert!(value.get("kind").is_none());
    }

    #[test]
    fn response_and_command_failure_have_semantic_events() {
        let opened = apple_wire::event_from_value(serde_json::json!({
            "type": "notificationResponse",
            "identifier": "chat-7",
            "actionIdentifier": "default",
            "userInfo": {
                "semanticIdentifier": "message-7",
                "deepLink": "travel://chat/7"
            }
        }))
        .expect("valid response");
        assert!(
            matches!(opened, Some(NotificationEvent::Opened { identifier, .. }) if identifier == "message-7")
        );

        let failure = apple_wire::event_from_value(serde_json::json!({
            "type": "commandFailed",
            "error": "denied"
        }))
        .expect("valid failure");
        assert!(
            matches!(failure, Some(NotificationEvent::Failed { code, .. }) if code == "commandFailed")
        );
    }
}
