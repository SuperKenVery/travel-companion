//! IM command/event model and idempotent local projection.

use model::{EntityId, EventId, PeerId, ResourceId};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use thiserror::Error;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Conversation {
    Group,
    Direct { peer_id: PeerId },
}

impl Conversation {
    #[must_use]
    pub fn stable_id(&self) -> String {
        match self {
            Self::Group => "group".into(),
            Self::Direct { peer_id } => format!("direct:{peer_id}"),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum MessageContent {
    Text {
        text: String,
    },
    Image {
        original: ResourceId,
        thumbnail: ResourceId,
        mime_type: String,
    },
    Voice {
        resource: ResourceId,
        duration_ms: u64,
        mime_type: String,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum MessageEvent {
    Sent {
        event_id: EventId,
        message_id: EntityId,
        conversation: Conversation,
        author_id: PeerId,
        content: MessageContent,
        sent_at_ms: i64,
    },
    Edited {
        event_id: EventId,
        message_id: EntityId,
        author_id: PeerId,
        text: String,
        edited_at_ms: i64,
    },
    Withdrawn {
        event_id: EventId,
        message_id: EntityId,
        actor_id: PeerId,
        withdrawn_at_ms: i64,
    },
}

impl MessageEvent {
    #[must_use]
    pub fn event_id(&self) -> &EventId {
        match self {
            Self::Sent { event_id, .. }
            | Self::Edited { event_id, .. }
            | Self::Withdrawn { event_id, .. } => event_id,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageView {
    pub message_id: EntityId,
    pub conversation: Conversation,
    pub author_id: PeerId,
    pub content: MessageContent,
    pub sent_at_ms: i64,
    pub edited_at_ms: Option<i64>,
    pub withdrawn: bool,
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum ImError {
    #[error("message does not exist")]
    UnknownMessage,
    #[error("only the author may edit the message")]
    NotAuthor,
    #[error("only text messages can be edited")]
    NotText,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageProjection {
    messages: BTreeMap<EntityId, MessageView>,
    seen_events: BTreeSet<EventId>,
}

impl MessageProjection {
    pub fn apply(&mut self, event: &MessageEvent) -> Result<bool, ImError> {
        if !self.seen_events.insert(event.event_id().clone()) {
            return Ok(false);
        }
        match event {
            MessageEvent::Sent {
                message_id,
                conversation,
                author_id,
                content,
                sent_at_ms,
                ..
            } => {
                self.messages
                    .entry(message_id.clone())
                    .or_insert(MessageView {
                        message_id: message_id.clone(),
                        conversation: conversation.clone(),
                        author_id: author_id.clone(),
                        content: content.clone(),
                        sent_at_ms: *sent_at_ms,
                        edited_at_ms: None,
                        withdrawn: false,
                    });
            }
            MessageEvent::Edited {
                message_id,
                author_id,
                text,
                edited_at_ms,
                ..
            } => {
                let message = self
                    .messages
                    .get_mut(message_id)
                    .ok_or(ImError::UnknownMessage)?;
                if &message.author_id != author_id {
                    return Err(ImError::NotAuthor);
                }
                if !matches!(message.content, MessageContent::Text { .. }) {
                    return Err(ImError::NotText);
                }
                message.content = MessageContent::Text { text: text.clone() };
                message.edited_at_ms = Some(*edited_at_ms);
            }
            MessageEvent::Withdrawn { message_id, .. } => {
                self.messages
                    .get_mut(message_id)
                    .ok_or(ImError::UnknownMessage)?
                    .withdrawn = true;
            }
        }
        Ok(true)
    }

    #[must_use]
    pub fn messages(&self) -> Vec<MessageView> {
        let mut messages = self.messages.values().cloned().collect::<Vec<_>>();
        messages.sort_by_key(|message| (message.sent_at_ms, message.message_id.clone()));
        messages
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn duplicate_network_event_materializes_once() {
        let event = MessageEvent::Sent {
            event_id: EventId::from("event"),
            message_id: EntityId::from("message"),
            conversation: Conversation::Group,
            author_id: PeerId::from("a"),
            content: MessageContent::Text { text: "hi".into() },
            sent_at_ms: 1,
        };
        let mut projection = MessageProjection::default();
        assert!(projection.apply(&event).unwrap());
        assert!(!projection.apply(&event).unwrap());
        assert_eq!(projection.messages().len(), 1);
    }
}
