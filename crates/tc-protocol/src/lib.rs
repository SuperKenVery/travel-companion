//! Versioned peer wire messages and an incremental length-delimited codec.

use serde::{Deserialize, Serialize};
use tc_model::{EventEnvelope, EventId, GroupId, PeerId, RequestId, SyncDigest};
use thiserror::Error;

pub const PROTOCOL_VERSION: u16 = 1;
pub const DEFAULT_MAX_FRAME_BYTES: usize = 8 * 1024 * 1024;

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum WireMessage {
    Authenticate {
        protocol_version: u16,
        group_id: GroupId,
        group_epoch: u64,
        peer_id: PeerId,
        nonce: Vec<u8>,
        authentication_tag: Vec<u8>,
    },
    SyncDigest {
        protocol_version: u16,
        digest: SyncDigest,
    },
    RequestEvents {
        protocol_version: u16,
        request_id: RequestId,
        event_ids: Vec<EventId>,
    },
    EventBatch {
        protocol_version: u16,
        request_id: RequestId,
        events: Vec<EventEnvelope>,
    },
    PersistedAck {
        protocol_version: u16,
        receiver_id: PeerId,
        event_ids: Vec<EventId>,
    },
    ResourceRequest {
        protocol_version: u16,
        request_id: RequestId,
        resource_id: String,
        chunk_indices: Vec<u32>,
    },
    ResourceChunk {
        protocol_version: u16,
        request_id: RequestId,
        resource_id: String,
        chunk_index: u32,
        bytes: Vec<u8>,
    },
    RealtimeFrame {
        protocol_version: u16,
        stream_id: String,
        sequence: u64,
        timestamp_ms: i64,
        bytes: Vec<u8>,
    },
}

impl WireMessage {
    #[must_use]
    pub fn protocol_version(&self) -> u16 {
        match self {
            Self::Authenticate {
                protocol_version, ..
            }
            | Self::SyncDigest {
                protocol_version, ..
            }
            | Self::RequestEvents {
                protocol_version, ..
            }
            | Self::EventBatch {
                protocol_version, ..
            }
            | Self::PersistedAck {
                protocol_version, ..
            }
            | Self::ResourceRequest {
                protocol_version, ..
            }
            | Self::ResourceChunk {
                protocol_version, ..
            }
            | Self::RealtimeFrame {
                protocol_version, ..
            } => *protocol_version,
        }
    }
}

#[derive(Debug, Error)]
pub enum ProtocolError {
    #[error("unsupported protocol version {0}")]
    UnsupportedVersion(u16),
    #[error("frame of {size} bytes exceeds limit {limit}")]
    FrameTooLarge { size: usize, limit: usize },
    #[error("message encoding failed: {0}")]
    Encode(#[from] serde_json::Error),
}

pub fn encode_frame(message: &WireMessage) -> Result<Vec<u8>, ProtocolError> {
    if message.protocol_version() != PROTOCOL_VERSION {
        return Err(ProtocolError::UnsupportedVersion(
            message.protocol_version(),
        ));
    }
    let body = serde_json::to_vec(message)?;
    if body.len() > u32::MAX as usize {
        return Err(ProtocolError::FrameTooLarge {
            size: body.len(),
            limit: u32::MAX as usize,
        });
    }
    let mut frame = Vec::with_capacity(4 + body.len());
    frame.extend_from_slice(&(body.len() as u32).to_be_bytes());
    frame.extend_from_slice(&body);
    Ok(frame)
}

#[derive(Clone, Debug)]
pub struct FrameDecoder {
    buffer: Vec<u8>,
    max_frame_bytes: usize,
}

impl Default for FrameDecoder {
    fn default() -> Self {
        Self::new(DEFAULT_MAX_FRAME_BYTES)
    }
}

impl FrameDecoder {
    #[must_use]
    pub fn new(max_frame_bytes: usize) -> Self {
        Self {
            buffer: Vec::new(),
            max_frame_bytes,
        }
    }

    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<WireMessage>, ProtocolError> {
        self.buffer.extend_from_slice(bytes);
        let mut messages = Vec::new();
        loop {
            if self.buffer.len() < 4 {
                break;
            }
            let size =
                u32::from_be_bytes(self.buffer[..4].try_into().expect("four bytes")) as usize;
            if size > self.max_frame_bytes {
                self.buffer.clear();
                return Err(ProtocolError::FrameTooLarge {
                    size,
                    limit: self.max_frame_bytes,
                });
            }
            if self.buffer.len() < 4 + size {
                break;
            }
            let body = self.buffer[4..4 + size].to_vec();
            self.buffer.drain(..4 + size);
            let message: WireMessage = serde_json::from_slice(&body)?;
            if message.protocol_version() != PROTOCOL_VERSION {
                return Err(ProtocolError::UnsupportedVersion(
                    message.protocol_version(),
                ));
            }
            messages.push(message);
        }
        Ok(messages)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DataAvailableHint {
    pub protocol_version: u16,
    pub group_id: GroupId,
    pub sender_peer_id: PeerId,
    pub sync_generation: u64,
    pub frontier_digest: Vec<u8>,
    pub content_kinds: Vec<String>,
    pub request_id: RequestId,
    pub expires_at_ms: i64,
    pub authentication_tag: Vec<u8>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decoder_handles_fragmented_and_coalesced_frames() {
        let first = WireMessage::SyncDigest {
            protocol_version: PROTOCOL_VERSION,
            digest: SyncDigest::default(),
        };
        let second = WireMessage::PersistedAck {
            protocol_version: PROTOCOL_VERSION,
            receiver_id: PeerId::from("b"),
            event_ids: vec![],
        };
        let mut bytes = encode_frame(&first).unwrap();
        bytes.extend(encode_frame(&second).unwrap());
        let split = bytes.len() / 3;
        let mut decoder = FrameDecoder::default();
        assert!(decoder.push(&bytes[..split]).unwrap().is_empty());
        assert_eq!(decoder.push(&bytes[split..]).unwrap(), vec![first, second]);
    }

    #[test]
    fn resource_gap_request_and_chunk_round_trip_through_versioned_frames() {
        let request = WireMessage::ResourceRequest {
            protocol_version: PROTOCOL_VERSION,
            request_id: RequestId::from("resource-request"),
            resource_id: "photo-1".into(),
            chunk_indices: vec![1, 4, 9],
        };
        let chunk = WireMessage::ResourceChunk {
            protocol_version: PROTOCOL_VERSION,
            request_id: RequestId::from("resource-request"),
            resource_id: "photo-1".into(),
            chunk_index: 4,
            bytes: b"verified chunk".to_vec(),
        };
        let mut bytes = encode_frame(&request).unwrap();
        bytes.extend(encode_frame(&chunk).unwrap());
        assert_eq!(
            FrameDecoder::default().push(&bytes).unwrap(),
            vec![request, chunk]
        );
    }
}
