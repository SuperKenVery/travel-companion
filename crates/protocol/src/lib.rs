//! Versioned peer wire messages and an incremental length-delimited codec.

use model::{EventId, GroupId, PeerId, RequestId, SignedEvent, SyncDigest};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use thiserror::Error;
use uuid::Uuid;

pub const PROTOCOL_VERSION: u16 = 2;
pub const DEFAULT_MAX_FRAME_BYTES: usize = 8 * 1024 * 1024;
pub const BLUETOOTH_PROTOCOL_VERSION: u8 = 1;
pub const BLUETOOTH_MAX_CONTROL_PAYLOAD_BYTES: usize = 4_096;
pub const BLUETOOTH_DEFAULT_PACKET_BYTES: usize = 180;

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum WireMessage {
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
        events: Vec<SignedEvent>,
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
            Self::SyncDigest {
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

/// Application control messages carried over the BLE control plane.
///
/// These names intentionally live in Rust. A Core Bluetooth backend only
/// transports opaque protocol packets and never needs to know which product
/// operation they contain.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "kind"
)]
pub enum BluetoothControlMessage {
    InvitationInfo { payload: Vec<u8> },
    JoinHello { payload: Vec<u8> },
    JoinResponse { payload: Vec<u8> },
    JoinConfirmation { payload: Vec<u8> },
    GroupControl { payload: Vec<u8> },
}

impl BluetoothControlMessage {
    #[must_use]
    pub fn payload(&self) -> &[u8] {
        match self {
            Self::InvitationInfo { payload }
            | Self::JoinHello { payload }
            | Self::JoinResponse { payload }
            | Self::JoinConfirmation { payload }
            | Self::GroupControl { payload } => payload,
        }
    }

    fn kind_byte(&self) -> u8 {
        match self {
            Self::InvitationInfo { .. } => 1,
            Self::JoinHello { .. } => 2,
            Self::JoinResponse { .. } => 3,
            Self::JoinConfirmation { .. } => 4,
            Self::GroupControl { .. } => 5,
        }
    }

    fn from_kind_and_payload(kind: u8, payload: Vec<u8>) -> Result<Self, BluetoothProtocolError> {
        match kind {
            1 => Ok(Self::InvitationInfo { payload }),
            2 => Ok(Self::JoinHello { payload }),
            3 => Ok(Self::JoinResponse { payload }),
            4 => Ok(Self::JoinConfirmation { payload }),
            5 => Ok(Self::GroupControl { payload }),
            other => Err(BluetoothProtocolError::UnknownControlKind(other)),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BluetoothControlAction {
    ControlReceived {
        peer_handle: u64,
        message: BluetoothControlMessage,
    },
    SendPacket {
        peer_handle: u64,
        packet: Vec<u8>,
    },
    ControlAcknowledged {
        request_id: RequestId,
    },
    Expired {
        peer_handle: u64,
        message_id: Uuid,
    },
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum BluetoothProtocolError {
    #[error("request ID is not a UUID-backed Travel Companion request ID")]
    InvalidRequestId,
    #[error("BLE control payload of {size} bytes exceeds limit {limit}")]
    ControlPayloadTooLarge { size: usize, limit: usize },
    #[error("BLE packet size {size} cannot hold the {header} byte fragment header")]
    PacketSizeTooSmall { size: usize, header: usize },
    #[error("BLE control message expiry must be later than creation time")]
    InvalidExpiry,
    #[error("BLE packet has an invalid fragment header")]
    InvalidFragment,
    #[error("BLE fragments disagree about their total count")]
    FragmentCountMismatch,
    #[error("BLE control envelope is malformed")]
    InvalidEnvelope,
    #[error("unsupported BLE control protocol version {0}")]
    UnsupportedVersion(u8),
    #[error("unknown BLE control kind {0}")]
    UnknownControlKind(u8),
}

const BLUETOOTH_FRAGMENT_HEADER_BYTES: usize = 23;
const BLUETOOTH_ENVELOPE_HEADER_BYTES: usize = 51;
const BLUETOOTH_ASSEMBLY_TTL_MS: i64 = 30_000;
const BLUETOOTH_ACK_TTL_MS: i64 = 15_000;
const BLUETOOTH_SEEN_CAPACITY: usize = 1_024;
const BLUETOOTH_SEEN_EVICTION_BATCH: usize = 256;

#[derive(Clone, Debug)]
struct BluetoothFragmentAssembly {
    first_observed_at_ms: i64,
    total: u16,
    pieces: BTreeMap<u16, Vec<u8>>,
}

#[derive(Clone, Debug)]
struct BluetoothEnvelope {
    kind: BluetoothEnvelopeKind,
    message_id: Uuid,
    sequence: u64,
    created_at_ms: i64,
    expires_at_ms: i64,
    requires_ack: bool,
    message: Option<BluetoothControlMessage>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum BluetoothEnvelopeKind {
    Data,
    Ack,
}

/// Stateful BLE control codec. It owns wire framing, reassembly, TTL, ACK
/// correlation, and duplicate suppression; native backends only move packets.
#[derive(Clone, Debug, Default)]
pub struct BluetoothControlCodec {
    assemblies: HashMap<(u64, Uuid), BluetoothFragmentAssembly>,
    seen: HashSet<Uuid>,
    seen_order: VecDeque<Uuid>,
    pending: HashMap<Uuid, RequestId>,
}

impl BluetoothControlCodec {
    pub fn encode_control(
        &mut self,
        request_id: RequestId,
        message: BluetoothControlMessage,
        created_at_ms: i64,
        expires_at_ms: i64,
        maximum_packet_bytes: usize,
    ) -> Result<Vec<Vec<u8>>, BluetoothProtocolError> {
        if message.payload().len() > BLUETOOTH_MAX_CONTROL_PAYLOAD_BYTES {
            return Err(BluetoothProtocolError::ControlPayloadTooLarge {
                size: message.payload().len(),
                limit: BLUETOOTH_MAX_CONTROL_PAYLOAD_BYTES,
            });
        }
        if expires_at_ms <= created_at_ms {
            return Err(BluetoothProtocolError::InvalidExpiry);
        }
        let message_id = request_uuid(&request_id)?;
        let envelope = BluetoothEnvelope {
            kind: BluetoothEnvelopeKind::Data,
            message_id,
            sequence: stable_sequence(request_id.as_str()),
            created_at_ms,
            expires_at_ms,
            requires_ack: true,
            message: Some(message),
        };
        let packets = fragment_bluetooth_envelope(&envelope, maximum_packet_bytes)?;
        self.pending.insert(message_id, request_id);
        Ok(packets)
    }

    pub fn ingest_packet(
        &mut self,
        peer_handle: u64,
        packet: &[u8],
        observed_at_ms: i64,
        maximum_packet_bytes: usize,
    ) -> Result<Vec<BluetoothControlAction>, BluetoothProtocolError> {
        self.purge_assemblies(observed_at_ms);
        let fragment = parse_bluetooth_fragment(packet)?;
        let key = (peer_handle, fragment.message_id);
        let assembly = self
            .assemblies
            .entry(key)
            .or_insert_with(|| BluetoothFragmentAssembly {
                first_observed_at_ms: observed_at_ms,
                total: fragment.total,
                pieces: BTreeMap::new(),
            });
        if assembly.total != fragment.total {
            return Err(BluetoothProtocolError::FragmentCountMismatch);
        }
        assembly.pieces.insert(fragment.index, fragment.payload);
        if assembly.pieces.len() != usize::from(assembly.total) {
            return Ok(Vec::new());
        }

        let assembly = self
            .assemblies
            .remove(&key)
            .expect("completed Bluetooth assembly exists");
        let mut encoded = Vec::new();
        for index in 0..assembly.total {
            let piece = assembly
                .pieces
                .get(&index)
                .ok_or(BluetoothProtocolError::InvalidFragment)?;
            encoded.extend_from_slice(piece);
        }
        let envelope = decode_bluetooth_envelope(&encoded)?;
        if envelope.message_id != fragment.message_id {
            return Err(BluetoothProtocolError::InvalidEnvelope);
        }
        if envelope.expires_at_ms <= envelope.created_at_ms
            || observed_at_ms > envelope.expires_at_ms
        {
            return Ok(vec![BluetoothControlAction::Expired {
                peer_handle,
                message_id: envelope.message_id,
            }]);
        }

        match envelope.kind {
            BluetoothEnvelopeKind::Ack => Ok(self
                .pending
                .remove(&envelope.message_id)
                .map(|request_id| BluetoothControlAction::ControlAcknowledged { request_id })
                .into_iter()
                .collect()),
            BluetoothEnvelopeKind::Data => {
                let duplicate = self.seen.contains(&envelope.message_id);
                self.remember(envelope.message_id);
                let mut actions = Vec::with_capacity(2);
                if !duplicate {
                    actions.push(BluetoothControlAction::ControlReceived {
                        peer_handle,
                        message: envelope
                            .message
                            .ok_or(BluetoothProtocolError::InvalidEnvelope)?,
                    });
                }
                if envelope.requires_ack {
                    let ack = BluetoothEnvelope {
                        kind: BluetoothEnvelopeKind::Ack,
                        message_id: envelope.message_id,
                        sequence: envelope.sequence,
                        created_at_ms: observed_at_ms,
                        expires_at_ms: observed_at_ms.saturating_add(BLUETOOTH_ACK_TTL_MS),
                        requires_ack: false,
                        message: None,
                    };
                    for packet in fragment_bluetooth_envelope(&ack, maximum_packet_bytes)? {
                        actions.push(BluetoothControlAction::SendPacket {
                            peer_handle,
                            packet,
                        });
                    }
                }
                Ok(actions)
            }
        }
    }

    pub fn cancel(&mut self, request_id: &RequestId) {
        if let Ok(message_id) = request_uuid(request_id) {
            self.pending.remove(&message_id);
        }
    }

    pub fn remove_peer(&mut self, peer_handle: u64) {
        self.assemblies
            .retain(|(candidate, _), _| *candidate != peer_handle);
    }

    fn remember(&mut self, message_id: Uuid) {
        if !self.seen.insert(message_id) {
            return;
        }
        self.seen_order.push_back(message_id);
        if self.seen_order.len() > BLUETOOTH_SEEN_CAPACITY {
            for _ in 0..BLUETOOTH_SEEN_EVICTION_BATCH {
                if let Some(old) = self.seen_order.pop_front() {
                    self.seen.remove(&old);
                }
            }
        }
    }

    fn purge_assemblies(&mut self, observed_at_ms: i64) {
        let cutoff = observed_at_ms.saturating_sub(BLUETOOTH_ASSEMBLY_TTL_MS);
        self.assemblies
            .retain(|_, assembly| assembly.first_observed_at_ms >= cutoff);
    }
}

struct BluetoothFragment {
    message_id: Uuid,
    index: u16,
    total: u16,
    payload: Vec<u8>,
}

fn request_uuid(request_id: &RequestId) -> Result<Uuid, BluetoothProtocolError> {
    let value = request_id
        .as_str()
        .strip_prefix("req_")
        .unwrap_or(request_id.as_str());
    Uuid::parse_str(value).map_err(|_| BluetoothProtocolError::InvalidRequestId)
}

fn stable_sequence(request_id: &str) -> u64 {
    request_id
        .bytes()
        .fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
            (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
        })
}

fn encode_bluetooth_envelope(envelope: &BluetoothEnvelope) -> Vec<u8> {
    let (message_tag, payload) = envelope.message.as_ref().map_or((0, &[][..]), |message| {
        (message.kind_byte(), message.payload())
    });
    let mut encoded = Vec::with_capacity(BLUETOOTH_ENVELOPE_HEADER_BYTES + payload.len());
    encoded.extend_from_slice(b"TCB");
    encoded.push(BLUETOOTH_PROTOCOL_VERSION);
    encoded.push(match envelope.kind {
        BluetoothEnvelopeKind::Data => 1,
        BluetoothEnvelopeKind::Ack => 2,
    });
    encoded.extend_from_slice(envelope.message_id.as_bytes());
    encoded.extend_from_slice(&envelope.sequence.to_be_bytes());
    encoded.extend_from_slice(&envelope.created_at_ms.to_be_bytes());
    encoded.extend_from_slice(&envelope.expires_at_ms.to_be_bytes());
    encoded.push(u8::from(envelope.requires_ack));
    encoded.push(message_tag);
    encoded.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    encoded.extend_from_slice(payload);
    encoded
}

fn decode_bluetooth_envelope(encoded: &[u8]) -> Result<BluetoothEnvelope, BluetoothProtocolError> {
    if encoded.len() < BLUETOOTH_ENVELOPE_HEADER_BYTES || &encoded[..3] != b"TCB" {
        return Err(BluetoothProtocolError::InvalidEnvelope);
    }
    if encoded[3] != BLUETOOTH_PROTOCOL_VERSION {
        return Err(BluetoothProtocolError::UnsupportedVersion(encoded[3]));
    }
    let kind = match encoded[4] {
        1 => BluetoothEnvelopeKind::Data,
        2 => BluetoothEnvelopeKind::Ack,
        _ => return Err(BluetoothProtocolError::InvalidEnvelope),
    };
    let message_id =
        Uuid::from_slice(&encoded[5..21]).map_err(|_| BluetoothProtocolError::InvalidEnvelope)?;
    let sequence = u64::from_be_bytes(
        encoded[21..29]
            .try_into()
            .map_err(|_| BluetoothProtocolError::InvalidEnvelope)?,
    );
    let created_at_ms = i64::from_be_bytes(
        encoded[29..37]
            .try_into()
            .map_err(|_| BluetoothProtocolError::InvalidEnvelope)?,
    );
    let expires_at_ms = i64::from_be_bytes(
        encoded[37..45]
            .try_into()
            .map_err(|_| BluetoothProtocolError::InvalidEnvelope)?,
    );
    let requires_ack = encoded[45] != 0;
    let message_tag = encoded[46];
    let payload_size = u32::from_be_bytes(
        encoded[47..51]
            .try_into()
            .map_err(|_| BluetoothProtocolError::InvalidEnvelope)?,
    ) as usize;
    if encoded.len() != BLUETOOTH_ENVELOPE_HEADER_BYTES + payload_size {
        return Err(BluetoothProtocolError::InvalidEnvelope);
    }
    let payload = encoded[BLUETOOTH_ENVELOPE_HEADER_BYTES..].to_vec();
    let message = match kind {
        BluetoothEnvelopeKind::Data => Some(BluetoothControlMessage::from_kind_and_payload(
            message_tag,
            payload,
        )?),
        BluetoothEnvelopeKind::Ack => {
            if message_tag != 0 || !payload.is_empty() || requires_ack {
                return Err(BluetoothProtocolError::InvalidEnvelope);
            }
            None
        }
    };
    Ok(BluetoothEnvelope {
        kind,
        message_id,
        sequence,
        created_at_ms,
        expires_at_ms,
        requires_ack,
        message,
    })
}

fn fragment_bluetooth_envelope(
    envelope: &BluetoothEnvelope,
    maximum_packet_bytes: usize,
) -> Result<Vec<Vec<u8>>, BluetoothProtocolError> {
    if maximum_packet_bytes <= BLUETOOTH_FRAGMENT_HEADER_BYTES {
        return Err(BluetoothProtocolError::PacketSizeTooSmall {
            size: maximum_packet_bytes,
            header: BLUETOOTH_FRAGMENT_HEADER_BYTES,
        });
    }
    let encoded = encode_bluetooth_envelope(envelope);
    let payload_bytes = maximum_packet_bytes - BLUETOOTH_FRAGMENT_HEADER_BYTES;
    let count = encoded.len().div_ceil(payload_bytes).max(1);
    let total =
        u16::try_from(count).map_err(|_| BluetoothProtocolError::ControlPayloadTooLarge {
            size: encoded.len(),
            limit: usize::from(u16::MAX) * payload_bytes,
        })?;
    Ok((0..total)
        .map(|index| {
            let start = usize::from(index) * payload_bytes;
            let end = (start + payload_bytes).min(encoded.len());
            let mut packet = Vec::with_capacity(BLUETOOTH_FRAGMENT_HEADER_BYTES + end - start);
            packet.extend_from_slice(b"TC");
            packet.push(BLUETOOTH_PROTOCOL_VERSION);
            packet.extend_from_slice(envelope.message_id.as_bytes());
            packet.extend_from_slice(&index.to_be_bytes());
            packet.extend_from_slice(&total.to_be_bytes());
            packet.extend_from_slice(&encoded[start..end]);
            packet
        })
        .collect())
}

fn parse_bluetooth_fragment(packet: &[u8]) -> Result<BluetoothFragment, BluetoothProtocolError> {
    if packet.len() < BLUETOOTH_FRAGMENT_HEADER_BYTES
        || &packet[..2] != b"TC"
        || packet[2] != BLUETOOTH_PROTOCOL_VERSION
    {
        return Err(BluetoothProtocolError::InvalidFragment);
    }
    let message_id =
        Uuid::from_slice(&packet[3..19]).map_err(|_| BluetoothProtocolError::InvalidFragment)?;
    let index = u16::from_be_bytes(
        packet[19..21]
            .try_into()
            .map_err(|_| BluetoothProtocolError::InvalidFragment)?,
    );
    let total = u16::from_be_bytes(
        packet[21..23]
            .try_into()
            .map_err(|_| BluetoothProtocolError::InvalidFragment)?,
    );
    if total == 0 || index >= total {
        return Err(BluetoothProtocolError::InvalidFragment);
    }
    Ok(BluetoothFragment {
        message_id,
        index,
        total,
        payload: packet[BLUETOOTH_FRAGMENT_HEADER_BYTES..].to_vec(),
    })
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

    #[test]
    fn event_batch_preserves_authenticated_event_bytes_exactly() {
        let signed = SignedEvent {
            signer_id: PeerId::from("a"),
            event_bytes: br#"{"payload":{"longitude":113.89049500316887}}"#.to_vec(),
            signature: vec![7; 64],
        };
        let message = WireMessage::EventBatch {
            protocol_version: PROTOCOL_VERSION,
            request_id: RequestId::from("events"),
            events: vec![signed],
        };

        let decoded = FrameDecoder::default()
            .push(&encode_frame(&message).unwrap())
            .unwrap();

        assert_eq!(decoded, vec![message]);
    }

    #[test]
    fn bluetooth_codec_owns_fragmentation_ack_and_duplicate_suppression() {
        let request_id = RequestId::new();
        let message = BluetoothControlMessage::GroupControl {
            payload: vec![7; 400],
        };
        let mut sender = BluetoothControlCodec::default();
        let packets = sender
            .encode_control(request_id.clone(), message.clone(), 1_000, 5_000, 80)
            .unwrap();
        assert!(packets.len() > 1);
        assert!(packets.iter().all(|packet| packet.len() <= 80));

        let mut receiver = BluetoothControlCodec::default();
        let mut receive_actions = Vec::new();
        for packet in &packets {
            receive_actions.extend(receiver.ingest_packet(42, packet, 2_000, 80).unwrap());
        }
        assert!(
            receive_actions.contains(&BluetoothControlAction::ControlReceived {
                peer_handle: 42,
                message: message.clone(),
            })
        );
        let ack_packets: Vec<_> = receive_actions
            .iter()
            .filter_map(|action| match action {
                BluetoothControlAction::SendPacket { packet, .. } => Some(packet.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(ack_packets.len(), 1);

        let acknowledged = sender
            .ingest_packet(42, &ack_packets[0], 2_100, 80)
            .unwrap();
        assert_eq!(
            acknowledged,
            [BluetoothControlAction::ControlAcknowledged {
                request_id: request_id.clone(),
            }]
        );

        let mut duplicate_actions = Vec::new();
        for packet in &packets {
            duplicate_actions.extend(receiver.ingest_packet(42, packet, 2_200, 80).unwrap());
        }
        assert!(!duplicate_actions
            .iter()
            .any(|action| matches!(action, BluetoothControlAction::ControlReceived { .. })));
        assert!(duplicate_actions
            .iter()
            .any(|action| matches!(action, BluetoothControlAction::SendPacket { .. })));
    }

    #[test]
    fn bluetooth_codec_drops_expired_control_before_materialization() {
        let mut sender = BluetoothControlCodec::default();
        let request_id = RequestId::new();
        let packets = sender
            .encode_control(
                request_id,
                BluetoothControlMessage::InvitationInfo {
                    payload: vec![1, 2, 3],
                },
                1_000,
                1_500,
                BLUETOOTH_DEFAULT_PACKET_BYTES,
            )
            .unwrap();
        let mut receiver = BluetoothControlCodec::default();
        let actions = receiver
            .ingest_packet(7, &packets[0], 2_000, BLUETOOTH_DEFAULT_PACKET_BYTES)
            .unwrap();
        assert!(matches!(
            actions.as_slice(),
            [BluetoothControlAction::Expired { peer_handle: 7, .. }]
        ));
    }
}
