//! Application coordinator and the only Rust API consumed by the public GUI
//! binding. Native frameworks are driven through semantic queued module commands.

use base64::{engine::general_purpose::STANDARD_NO_PAD, Engine as _};
use bluetooth::{BluetoothCommand, BluetoothControlMessage, BluetoothEvent, PeerHandle};
use call::{CallMachine, CallSignal, CallState};
use call_system::{CallSystemCommand, CallSystemEvent};
use crypto::{open, seal, IdentityKeypair, SealedMessage, SecretKeyMaterial};
use document::{DocumentError, DocumentRevision, DocumentState, EditorLease, LeaseEvent};
use group_auth::{JoinHello, PinHandshake, PinSession};
use im::{Conversation, MessageContent};
use location::{LocationCommand, LocationEvent};
use location_logic::UwbObservation;
use model::{
    CallId, DeliveryPolicy, EntityId, EventId, GroupAudience, GroupId, LeaseId, LocationSample,
    PeerId, RequestId, ResourceId, RevisionId,
};
use notifications::{NotificationCommand, NotificationEvent};
use peer_transport::{ConnectionHandle, TrafficClass, TransportCommand, TransportEvent};
use protocol::{encode_frame, FrameDecoder, WireMessage, PROTOCOL_VERSION};
use ranging::{RangingCommand, RangingEvent};
use replication::{DeliveryState, IngestReceipt, ReplicationEngine, ReplicationError};
use resources::{build_manifest, DiskResourceStore, ResourceError, ResourceManifest};
use secure_storage::{SecretValue, SecureStorageCommand, SecureStorageEvent};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet, HashMap, VecDeque};

mod logging;
use store::{EventStore, StoreError};
use thiserror::Error;

const STATE_KEY: &str = "travel-core/v2";
const IDENTITY_KEY: &str = "tc.identity.ed25519.v1";
const GROUP_KEY: &str = "tc.group.current.v1";
const TRANSPORT_CERTIFICATE_KEY: &str = "tc.transport.certificate.der.v1";
const TRANSPORT_PRIVATE_KEY: &str = "tc.transport.private-key.pkcs8.v1";
const LOCATION_REQUEST_FRESHNESS_MS: i64 = 30_000;
const LOCATION_REQUEST_DEADLINE_MS: i64 = 15_000;
const PRECISION_REQUEST_COOLDOWN_MS: i64 = 30_000;
const RESOURCE_CHUNK_SIZE: usize = 64 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct CoreConfig {
    pub storage_path: String,
    pub resources_path: String,
    pub display_name: String,
}

impl Default for CoreConfig {
    fn default() -> Self {
        Self {
            storage_path: "TravelCompanion.sqlite3".into(),
            resources_path: "TravelCompanionResources".into(),
            display_name: "Traveler".into(),
        }
    }
}

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("persistent store failed: {0}")]
    Store(#[from] StoreError),
    #[error("replication failed: {0}")]
    Replication(#[from] ReplicationError),
    #[error("document operation failed: {0}")]
    Document(#[from] DocumentError),
    #[error("call operation failed: {0}")]
    Call(#[from] call::CallError),
    #[error("peer protocol failed: {0}")]
    Protocol(#[from] protocol::ProtocolError),
    #[error("command requires an active group")]
    NoActiveGroup,
    #[error("identity key has not been restored from secure storage")]
    IdentityUnavailable,
    #[error("group credential has not been restored from secure storage")]
    GroupCredentialUnavailable,
    #[error("requested peer is not a group member")]
    UnknownPeer,
    #[error("requested entity does not exist")]
    UnknownEntity,
    #[error("document is leased by another member")]
    LeaseHeldByAnother,
    #[error("a precision-location request for this member is already active")]
    PrecisionRateLimited,
    #[error("module event is invalid: {0}")]
    InvalidModuleEvent(String),
    #[error("JSON operation failed: {0}")]
    Json(#[from] serde_json::Error),
    #[error("transport identity generation failed: {0}")]
    TransportIdentity(String),
    #[error("PIN-authenticated admission failed: {0}")]
    GroupAuth(String),
    #[error("resource transfer failed: {0}")]
    Resource(#[from] ResourceError),
    #[error("resource source could not be read: {0}")]
    ResourceSource(String),
}

impl CoreError {
    #[must_use]
    pub fn code(&self) -> &'static str {
        match self {
            Self::Store(_) => "storeFailed",
            Self::Replication(_) => "replicationFailed",
            Self::Document(_) => "documentFailed",
            Self::Call(_) => "callStateInvalid",
            Self::Protocol(_) => "protocolFailed",
            Self::NoActiveGroup => "noActiveGroup",
            Self::IdentityUnavailable => "identityUnavailable",
            Self::GroupCredentialUnavailable => "groupCredentialUnavailable",
            Self::UnknownPeer => "unknownPeer",
            Self::UnknownEntity => "unknownEntity",
            Self::LeaseHeldByAnother => "leaseHeldByAnother",
            Self::PrecisionRateLimited => "precisionRateLimited",
            Self::InvalidModuleEvent(_) => "invalidModuleEvent",
            Self::Json(_) => "invalidJson",
            Self::TransportIdentity(_) => "transportIdentityUnavailable",
            Self::GroupAuth(_) => "groupAuthFailed",
            Self::Resource(_) => "resourceFailed",
            Self::ResourceSource(_) => "resourceSourceUnavailable",
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityBlocker {
    pub code: String,
    pub message: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LifecycleSnapshot {
    pub is_traveling: bool,
    pub sharing_paused: bool,
    pub is_foreground: bool,
    pub blockers: Vec<CapabilityBlocker>,
    pub last_error: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IdentitySnapshot {
    pub peer_id: PeerId,
    pub display_name: String,
    pub key_ready: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum MemberRole {
    Owner,
    Member,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MemberSnapshot {
    pub peer_id: PeerId,
    pub display_name: String,
    pub role: MemberRole,
    pub active: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GroupSnapshot {
    pub id: GroupId,
    pub name: String,
    pub epoch: u64,
    pub invite_pin: Option<String>,
    pub members: Vec<MemberSnapshot>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerSnapshot {
    pub peer_id: PeerId,
    pub display_name: String,
    pub connected: bool,
    pub last_location: Option<LocationSample>,
    pub ranging: Option<UwbObservation>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageSnapshot {
    pub message_id: EntityId,
    pub publication_event_id: EventId,
    pub sender_id: PeerId,
    pub content: MessageContent,
    pub sent_at_ms: i64,
    pub delivery: DeliveryState,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversationSnapshot {
    pub id: String,
    pub conversation: Conversation,
    pub messages: Vec<MessageSnapshot>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaceSnapshot {
    pub id: EntityId,
    pub title: String,
    pub note: String,
    pub latitude: f64,
    pub longitude: f64,
    pub author_id: PeerId,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
    pub deleted: bool,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DocumentAppSnapshot {
    pub content: String,
    pub head: Option<RevisionId>,
    pub lease: Option<EditorLease>,
    pub conflicts: Vec<DocumentRevision>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ResourceTransferStatus {
    Pending,
    Available,
    Cancelled,
    Failed,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResourceSnapshot {
    pub manifest: ResourceManifest,
    pub local_path: Option<String>,
    pub transferred_bytes: u64,
    pub status: ResourceTransferStatus,
    pub last_error: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum PrecisionStatus {
    Pending,
    Accepted,
    Rejected,
    Active,
    Expired,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PrecisionRequestSnapshot {
    pub request_id: RequestId,
    pub requester_id: PeerId,
    pub target_id: PeerId,
    pub created_at_ms: i64,
    pub expires_at_ms: i64,
    pub status: PrecisionStatus,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSnapshot {
    pub lifecycle: LifecycleSnapshot,
    pub identity: IdentitySnapshot,
    pub group: Option<GroupSnapshot>,
    pub peers: Vec<PeerSnapshot>,
    pub conversations: Vec<ConversationSnapshot>,
    pub resources: Vec<ResourceSnapshot>,
    pub places: Vec<PlaceSnapshot>,
    pub document: DocumentAppSnapshot,
    pub active_call: Option<CallState>,
    pub pending_precision: Vec<PrecisionRequestSnapshot>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum MediaKind {
    Image,
    Voice,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum AppCommand {
    StartTravel {
        now_ms: i64,
    },
    EndTravel {
        now_ms: i64,
    },
    CreateGroup {
        name: String,
        now_ms: i64,
    },
    JoinWithPin {
        pin: String,
        now_ms: i64,
    },
    LeaveGroup {
        now_ms: i64,
    },
    SetSharingPaused {
        paused: bool,
        now_ms: i64,
    },
    RequestPrecision {
        peer_id: PeerId,
        ttl_ms: i64,
        now_ms: i64,
    },
    RespondPrecision {
        request_id: RequestId,
        accept: bool,
        now_ms: i64,
    },
    SendText {
        conversation: Conversation,
        text: String,
        now_ms: i64,
    },
    RegisterMedia {
        conversation: Conversation,
        media_kind: MediaKind,
        resource_id: ResourceId,
        thumbnail_resource_id: Option<ResourceId>,
        mime_type: String,
        duration_ms: Option<u64>,
        #[serde(default)]
        source_path: Option<String>,
        now_ms: i64,
    },
    CancelResource {
        resource_id: ResourceId,
        now_ms: i64,
    },
    RetryResource {
        resource_id: ResourceId,
        now_ms: i64,
    },
    CreatePlace {
        title: String,
        note: String,
        latitude: f64,
        longitude: f64,
        now_ms: i64,
    },
    UpdatePlace {
        place_id: EntityId,
        title: Option<String>,
        note: Option<String>,
        latitude: Option<f64>,
        longitude: Option<f64>,
        now_ms: i64,
    },
    DeletePlace {
        place_id: EntityId,
        now_ms: i64,
    },
    AcquireDocumentLease {
        duration_ms: i64,
        now_ms: i64,
    },
    SaveDocument {
        markdown: String,
        parent: Option<RevisionId>,
        now_ms: i64,
    },
    ReleaseDocumentLease {
        lease_id: LeaseId,
        now_ms: i64,
    },
    StartCall {
        peer_id: PeerId,
        now_ms: i64,
    },
    AnswerCall {
        now_ms: i64,
    },
    RejectCall {
        now_ms: i64,
    },
    EndCall {
        now_ms: i64,
    },
    SetForeground {
        foreground: bool,
        now_ms: i64,
    },
    ClearTripData {
        now_ms: i64,
    },
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModuleCommandEnvelope {
    pub module: String,
    pub command: Value,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModuleEventEnvelope {
    pub module: String,
    pub event: Value,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct PersistedState {
    is_traveling: bool,
    sharing_paused: bool,
    is_foreground: bool,
    identity: IdentitySnapshot,
    identity_key_initialized: bool,
    #[serde(default)]
    member_public_keys: BTreeMap<PeerId, Vec<u8>>,
    group: Option<GroupSnapshot>,
    peers: Vec<PeerSnapshot>,
    conversations: Vec<ConversationSnapshot>,
    #[serde(default)]
    resources: Vec<ResourceSnapshot>,
    places: Vec<PlaceSnapshot>,
    document_revisions: Vec<DocumentRevision>,
    document_leases: Vec<EditorLease>,
    pending_precision: Vec<PrecisionRequestSnapshot>,
    #[serde(default)]
    processed_control_ids: BTreeSet<RequestId>,
}

impl PersistedState {
    fn fresh(display_name: String) -> Self {
        Self {
            is_traveling: false,
            sharing_paused: false,
            is_foreground: true,
            identity: IdentitySnapshot {
                peer_id: PeerId::new(),
                display_name,
                key_ready: true,
            },
            identity_key_initialized: false,
            member_public_keys: BTreeMap::new(),
            group: None,
            peers: Vec::new(),
            conversations: Vec::new(),
            resources: Vec::new(),
            places: Vec::new(),
            document_revisions: Vec::new(),
            document_leases: Vec::new(),
            pending_precision: Vec::new(),
            processed_control_ids: BTreeSet::new(),
        }
    }
}

#[derive(Clone, Debug)]
struct PendingControl {
    kind: String,
    payload: Vec<u8>,
    expires_at_ms: i64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct LocationRequestPayload {
    request_id: RequestId,
    requester_id: PeerId,
    created_at_ms: i64,
    desired_freshness_ms: i64,
    deadline_ms: i64,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
enum LocationResponseStatus {
    Fresh,
    Stale,
    Timeout,
    Paused,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct LocationResponsePayload {
    request_id: RequestId,
    responder_id: PeerId,
    status: LocationResponseStatus,
    sample: Option<LocationSample>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct GroupControlEnvelope {
    protocol_version: u16,
    created_at_ms: i64,
    expires_at_ms: i64,
    sealed: SealedMessage,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct GroupControlPayload {
    group_id: GroupId,
    group_epoch: u64,
    sender_id: PeerId,
    recipient_id: Option<PeerId>,
    control_id: RequestId,
    kind: String,
    payload: Vec<u8>,
}

#[derive(Clone, Debug)]
struct PendingLocationReply {
    peer_id: PeerId,
    deadline_ms: i64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct InvitationInfo {
    admission_id: GroupId,
    inviter_peer_id: PeerId,
    inviter_display_name: String,
    inviter_public_key: Vec<u8>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct JoinHelloPayload {
    hello: JoinHello,
    display_name: String,
    public_key: Vec<u8>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct AdmissionCredential {
    group: GroupSnapshot,
    member_public_keys: BTreeMap<PeerId, String>,
    group_key: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct MembershipSnapshotPayload {
    group: GroupSnapshot,
    member_public_keys: BTreeMap<PeerId, Vec<u8>>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct JoinResponsePayload {
    hello: JoinHello,
    confirmation: String,
    sealed_nonce: String,
    sealed_credential: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct JoinConfirmationPayload {
    peer_id: PeerId,
    confirmation: Vec<u8>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct RealtimeAudioPayload {
    pcm16: Vec<u8>,
    sample_rate: u32,
    channel_count: u32,
}

struct PendingInviterAdmission {
    session: PinSession,
    joiner_peer_id: PeerId,
    joiner_display_name: String,
    joiner_public_key: Vec<u8>,
}

pub struct TravelCore {
    config: CoreConfig,
    state_store: EventStore,
    state: PersistedState,
    identity_secret: Option<[u8; 32]>,
    group_key: Option<[u8; 32]>,
    transport_certificate_der: Option<Vec<u8>>,
    transport_private_key_pkcs8: Option<Vec<u8>>,
    replication: Option<ReplicationEngine>,
    resource_store: DiskResourceStore,
    document: DocumentState,
    call: CallMachine,
    module_commands: VecDeque<ModuleCommandEnvelope>,
    bluetooth_handles: BTreeMap<PeerId, PeerHandle>,
    pending_controls: BTreeMap<PeerId, Vec<PendingControl>>,
    pending_location_replies: BTreeMap<RequestId, PendingLocationReply>,
    precision_request_cooldowns: BTreeMap<PeerId, i64>,
    transport_connections: BTreeMap<PeerId, ConnectionHandle>,
    transport_peers: HashMap<ConnectionHandle, PeerId>,
    transport_decoders: HashMap<ConnectionHandle, FrameDecoder>,
    pending_join_pin: Option<String>,
    pending_invitations: HashMap<PeerHandle, GroupId>,
    pending_joiner_handshake: Option<PinHandshake>,
    pending_inviter_admissions: HashMap<PeerHandle, PendingInviterAdmission>,
    last_error: Option<String>,
    last_now_ms: i64,
}

impl TravelCore {
    pub fn new(config: CoreConfig) -> Result<Self, CoreError> {
        logging::initialize(&config.storage_path);
        let state_store = EventStore::open(&config.storage_path)?;
        let resource_store = DiskResourceStore::open(&config.resources_path)?;
        let loaded = state_store.load_state::<PersistedState>(STATE_KEY)?;
        let mut state =
            loaded.unwrap_or_else(|| PersistedState::fresh(config.display_name.clone()));
        let is_new_identity = !state.identity_key_initialized;
        let identity_secret = is_new_identity.then(|| IdentityKeypair::generate().secret_bytes());
        state.identity.key_ready = identity_secret.is_some();
        if is_new_identity {
            state.identity_key_initialized = true;
        }
        if let Some(secret) = identity_secret {
            state.member_public_keys.insert(
                state.identity.peer_id.clone(),
                IdentityKeypair::from_secret_bytes(&secret)
                    .public_key_bytes()
                    .to_vec(),
            );
        }
        let mut document = DocumentState::default();
        for revision in &state.document_revisions {
            document.insert_revision(revision.clone())?;
        }
        for lease in &state.document_leases {
            document.apply_lease_event(&LeaseEvent::Acquired {
                lease: lease.clone(),
            })?;
            if let Some(released_at_ms) = lease.released_at_ms {
                document.apply_lease_event(&LeaseEvent::Released {
                    lease_id: lease.lease_id.clone(),
                    holder_id: lease.holder_id.clone(),
                    released_at_ms,
                })?;
            }
        }
        let local_peer = state.identity.peer_id.clone();
        let mut core = Self {
            config,
            state_store,
            state,
            identity_secret,
            group_key: None,
            transport_certificate_der: None,
            transport_private_key_pkcs8: None,
            replication: None,
            resource_store,
            document,
            call: CallMachine::new(local_peer),
            module_commands: VecDeque::new(),
            bluetooth_handles: BTreeMap::new(),
            pending_controls: BTreeMap::new(),
            pending_location_replies: BTreeMap::new(),
            precision_request_cooldowns: BTreeMap::new(),
            transport_connections: BTreeMap::new(),
            transport_peers: HashMap::new(),
            transport_decoders: HashMap::new(),
            pending_join_pin: None,
            pending_invitations: HashMap::new(),
            pending_joiner_handshake: None,
            pending_inviter_admissions: HashMap::new(),
            last_error: None,
            last_now_ms: 0,
        };
        if let Some(secret) = core.identity_secret {
            core.queue(
                "secureStorage",
                &SecureStorageCommand::Put {
                    request_id: RequestId::new(),
                    key: IDENTITY_KEY.into(),
                    value: SecretValue(secret.to_vec()),
                },
            )?;
            core.rebuild_replication()?;
        } else {
            core.queue(
                "secureStorage",
                &SecureStorageCommand::Get {
                    request_id: RequestId::new(),
                    key: IDENTITY_KEY.into(),
                },
            )?;
        }
        if core.state.group.is_some() {
            core.queue(
                "secureStorage",
                &SecureStorageCommand::Get {
                    request_id: RequestId::new(),
                    key: GROUP_KEY.into(),
                },
            )?;
        }
        let should_restore_admission = core.state.group.as_ref().is_some_and(|group| {
            group.invite_pin.is_some()
                && group.members.iter().any(|member| {
                    member.peer_id == core.state.identity.peer_id
                        && member.active
                        && member.role == MemberRole::Owner
                })
        });
        if should_restore_admission {
            core.queue(
                "bluetooth",
                &BluetoothCommand::Start {
                    request_id: RequestId::new(),
                },
            )?;
            tracing::info!(
                subsystem = "groupAuth",
                "restored an active invitation and reopened the BLE admission channel"
            );
        }
        for key in [TRANSPORT_CERTIFICATE_KEY, TRANSPORT_PRIVATE_KEY] {
            core.queue(
                "secureStorage",
                &SecureStorageCommand::Get {
                    request_id: RequestId::new(),
                    key: key.into(),
                },
            )?;
        }
        core.recover_resources()?;
        core.persist()?;
        Ok(core)
    }

    pub fn dispatch(&mut self, command: AppCommand) -> Result<AppSnapshot, CoreError> {
        let result = self.apply_command(command);
        if let Err(error) = &result {
            self.last_error = Some(error.to_string());
            tracing::error!(subsystem = "core", %error, "command failed");
        }
        result?;
        self.expire_precision();
        self.persist()?;
        self.snapshot()
    }

    pub fn ingest_module_event(
        &mut self,
        envelope: ModuleEventEnvelope,
    ) -> Result<AppSnapshot, CoreError> {
        self.ingest_module_event_at(envelope, self.last_now_ms)
    }

    pub fn ingest_module_event_at(
        &mut self,
        envelope: ModuleEventEnvelope,
        received_at_ms: i64,
    ) -> Result<AppSnapshot, CoreError> {
        self.last_now_ms = self.last_now_ms.max(received_at_ms);
        let result = (|| {
            let module = envelope.module.as_str();
            match module {
                "bluetooth" => self.on_bluetooth(decode_module_event(module, envelope.event)?),
                "peerTransport" => self.on_transport(decode_module_event(module, envelope.event)?),
                "location" => self.on_location(decode_module_event(module, envelope.event)?),
                "ranging" => {
                    let mut event: RangingEvent = decode_module_event(module, envelope.event)?;
                    // Nearby Interaction does not timestamp measurements. Keep
                    // receipt time under the core's injected clock so tests and
                    // stale-state handling remain deterministic.
                    if let RangingEvent::Measurement { observed_at_ms, .. } = &mut event {
                        *observed_at_ms = self.last_now_ms;
                    }
                    self.on_ranging(event)
                }
                "notifications" => {
                    self.on_notification(decode_module_event(module, envelope.event)?)
                }
                "callSystem" => self.on_call_system(decode_module_event(module, envelope.event)?),
                "secureStorage" => {
                    self.on_secure_storage(decode_module_event(module, envelope.event)?)
                }
                other => Err(CoreError::InvalidModuleEvent(format!(
                    "unknown module {other}"
                ))),
            }
        })();
        if let Err(error) = &result {
            self.last_error = Some(error.to_string());
            tracing::error!(subsystem = "core", %error, "module event failed");
        }
        result?;
        self.expire_precision();
        self.persist()?;
        self.snapshot()
    }

    pub fn drain_module_commands(&mut self) -> Vec<ModuleCommandEnvelope> {
        self.module_commands.drain(..).collect()
    }

    pub fn snapshot(&self) -> Result<AppSnapshot, CoreError> {
        let mut conversations = self.state.conversations.clone();
        if let Some(replication) = &self.replication {
            for conversation in &mut conversations {
                for message in &mut conversation.messages {
                    if let Ok(delivery) =
                        replication.delivery_state(&message.publication_event_id, self.last_now_ms)
                    {
                        message.delivery = delivery;
                    }
                }
            }
        }
        let document = self.document.snapshot(self.last_now_ms);
        let mut peers = self.state.peers.clone();
        peers.sort_by_key(|peer| peer.peer_id.clone());
        let mut places = self.state.places.clone();
        places.sort_by_key(|place| (place.created_at_ms, place.id.clone()));
        let mut resources = self.state.resources.clone();
        resources.sort_by_key(|resource| resource.manifest.resource_id.clone());
        let mut precision = self.state.pending_precision.clone();
        precision.sort_by_key(|request| (request.created_at_ms, request.request_id.clone()));
        Ok(AppSnapshot {
            lifecycle: LifecycleSnapshot {
                is_traveling: self.state.is_traveling,
                sharing_paused: self.state.sharing_paused,
                is_foreground: self.state.is_foreground,
                blockers: self.blockers(),
                last_error: self.last_error.clone(),
            },
            identity: self.state.identity.clone(),
            group: self.state.group.clone(),
            peers,
            conversations,
            resources,
            places,
            document: DocumentAppSnapshot {
                content: document.content,
                head: document.head_revision_id,
                lease: document.active_lease,
                conflicts: document.conflict_revisions,
            },
            active_call: match self.call.state() {
                CallState::Idle | CallState::Ended { .. } => None,
                state => Some(state.clone()),
            },
            pending_precision: precision,
        })
    }

    fn apply_command(&mut self, command: AppCommand) -> Result<(), CoreError> {
        let now_ms = command_now(&command);
        self.last_now_ms = now_ms;
        self.call.tick(now_ms);
        match command {
            AppCommand::StartTravel { .. } => self.start_travel(),
            AppCommand::EndTravel { .. } => self.end_travel(),
            AppCommand::CreateGroup { name, .. } => self.create_group(name),
            AppCommand::JoinWithPin { pin, .. } => self.join_with_pin(pin),
            AppCommand::LeaveGroup { .. } => self.leave_group(),
            AppCommand::SetSharingPaused { paused, .. } => self.set_sharing_paused(paused),
            AppCommand::RequestPrecision {
                peer_id, ttl_ms, ..
            } => self.request_precision(peer_id, ttl_ms),
            AppCommand::RespondPrecision {
                request_id, accept, ..
            } => self.respond_precision(&request_id, accept),
            AppCommand::SendText {
                conversation, text, ..
            } => self.send_message(conversation, MessageContent::Text { text }),
            AppCommand::RegisterMedia {
                conversation,
                media_kind,
                resource_id,
                thumbnail_resource_id,
                mime_type,
                duration_ms,
                source_path,
                ..
            } => self.register_media(
                conversation,
                media_kind,
                resource_id,
                thumbnail_resource_id,
                mime_type,
                duration_ms,
                source_path.as_deref(),
            ),
            AppCommand::CancelResource { resource_id, .. } => self.cancel_resource(&resource_id),
            AppCommand::RetryResource { resource_id, .. } => self.retry_resource(&resource_id),
            AppCommand::CreatePlace {
                title,
                note,
                latitude,
                longitude,
                ..
            } => self.create_place(title, note, latitude, longitude),
            AppCommand::UpdatePlace {
                place_id,
                title,
                note,
                latitude,
                longitude,
                ..
            } => self.update_place(&place_id, title, note, latitude, longitude),
            AppCommand::DeletePlace { place_id, .. } => self.delete_place(&place_id),
            AppCommand::AcquireDocumentLease { duration_ms, .. } => {
                self.acquire_document_lease(duration_ms)
            }
            AppCommand::SaveDocument {
                markdown, parent, ..
            } => self.save_document(markdown, parent),
            AppCommand::ReleaseDocumentLease { lease_id, .. } => {
                self.release_document_lease(&lease_id)
            }
            AppCommand::StartCall { peer_id, .. } => self.start_call(peer_id),
            AppCommand::AnswerCall { .. } => self.answer_call(),
            AppCommand::RejectCall { .. } => self.reject_call(),
            AppCommand::EndCall { .. } => self.end_call(),
            AppCommand::SetForeground { foreground, .. } => self.set_foreground(foreground),
            AppCommand::ClearTripData { .. } => self.clear_trip_data(),
        }
    }

    fn start_travel(&mut self) -> Result<(), CoreError> {
        self.state.is_traveling = true;
        self.queue(
            "bluetooth",
            &BluetoothCommand::Start {
                request_id: RequestId::new(),
            },
        )?;
        self.start_transport_if_ready()?;
        if !self.state.sharing_paused {
            self.queue(
                "location",
                &LocationCommand::StartTravelUpdates {
                    request_id: RequestId::new(),
                    background: true,
                },
            )?;
        }
        Ok(())
    }

    fn end_travel(&mut self) -> Result<(), CoreError> {
        self.state.is_traveling = false;
        self.pending_location_replies.clear();
        self.queue(
            "location",
            &LocationCommand::StopTravelUpdates {
                request_id: RequestId::new(),
            },
        )?;
        self.queue(
            "peerTransport",
            &TransportCommand::StopDiscovery {
                request_id: RequestId::new(),
            },
        )?;
        self.transport_connections.clear();
        self.transport_peers.clear();
        self.transport_decoders.clear();
        self.queue(
            "bluetooth",
            &BluetoothCommand::Stop {
                request_id: RequestId::new(),
            },
        )?;
        for peer in self
            .state
            .peers
            .iter()
            .filter(|peer| peer.ranging.is_some())
            .map(|peer| peer.peer_id.clone())
            .collect::<Vec<_>>()
        {
            self.queue(
                "ranging",
                &RangingCommand::Cancel {
                    request_id: RequestId::new(),
                    peer_id: peer,
                    reason: "travelEnded".into(),
                },
            )?;
        }
        for peer in &mut self.state.peers {
            peer.ranging = None;
        }
        if !matches!(self.call.state(), CallState::Idle | CallState::Ended { .. }) {
            self.end_call()?;
        }
        Ok(())
    }

    fn create_group(&mut self, name: String) -> Result<(), CoreError> {
        self.require_identity()?;
        let local = self.state.identity.clone();
        let group = GroupSnapshot {
            id: GroupId::new(),
            name,
            epoch: 1,
            invite_pin: Some(make_pin()),
            members: vec![MemberSnapshot {
                peer_id: local.peer_id.clone(),
                display_name: local.display_name.clone(),
                role: MemberRole::Owner,
                active: true,
            }],
        };
        self.state.group = Some(group);
        self.state.processed_control_ids.clear();
        self.ensure_peer(local.peer_id, local.display_name);
        let group_key = SecretKeyMaterial::random();
        self.group_key = Some(group_key.0);
        self.queue(
            "secureStorage",
            &SecureStorageCommand::Put {
                request_id: RequestId::new(),
                key: GROUP_KEY.into(),
                value: SecretValue(group_key.0.to_vec()),
            },
        )?;
        self.rebuild_replication()?;
        // A newly created group must be discoverable immediately so another
        // nearby device can use the PIN shown by the UI. Admission is not a
        // travel-session-only capability.
        self.queue(
            "bluetooth",
            &BluetoothCommand::Start {
                request_id: RequestId::new(),
            },
        )?;
        tracing::info!(
            subsystem = "groupAuth",
            "created group and opened the BLE admission channel"
        );
        for handle in self.bluetooth_handles.values().copied().collect::<Vec<_>>() {
            self.send_group_presence(handle)?;
            self.send_invitation_info(handle)?;
        }
        if self.state.is_traveling {
            self.start_transport_if_ready()?;
        }
        Ok(())
    }

    fn join_with_pin(&mut self, pin: String) -> Result<(), CoreError> {
        if pin.len() != 6 || !pin.bytes().all(|byte| byte.is_ascii_digit()) {
            return Err(CoreError::InvalidModuleEvent(
                "join PIN must contain six digits".into(),
            ));
        }
        self.pending_join_pin = Some(pin);
        self.queue(
            "bluetooth",
            &BluetoothCommand::Start {
                request_id: RequestId::new(),
            },
        )?;
        tracing::info!(
            subsystem = "groupAuth",
            "join requested; started BLE and waiting for a nearby invitation"
        );
        Ok(())
    }

    fn leave_group(&mut self) -> Result<(), CoreError> {
        self.state.group = None;
        self.state.processed_control_ids.clear();
        self.group_key = None;
        self.replication = None;
        self.pending_controls.clear();
        self.pending_location_replies.clear();
        self.precision_request_cooldowns.clear();
        self.state.pending_precision.clear();
        self.queue(
            "secureStorage",
            &SecureStorageCommand::Delete {
                request_id: RequestId::new(),
                key: GROUP_KEY.into(),
            },
        )?;
        self.queue(
            "peerTransport",
            &TransportCommand::StopDiscovery {
                request_id: RequestId::new(),
            },
        )?;
        self.transport_connections.clear();
        self.transport_peers.clear();
        self.transport_decoders.clear();
        self.pending_join_pin = None;
        self.pending_invitations.clear();
        self.pending_joiner_handshake = None;
        self.pending_inviter_admissions.clear();
        Ok(())
    }

    fn set_sharing_paused(&mut self, paused: bool) -> Result<(), CoreError> {
        self.state.sharing_paused = paused;
        if paused {
            for (request_id, pending) in std::mem::take(&mut self.pending_location_replies) {
                self.send_location_response(
                    pending.peer_id,
                    request_id,
                    pending.deadline_ms,
                    LocationResponseStatus::Paused,
                    None,
                )?;
            }
            let mut rejected_precision = Vec::new();
            for request in &mut self.state.pending_precision {
                if request.target_id == self.state.identity.peer_id
                    && matches!(
                        request.status,
                        PrecisionStatus::Pending
                            | PrecisionStatus::Accepted
                            | PrecisionStatus::Active
                    )
                {
                    request.status = PrecisionStatus::Rejected;
                    rejected_precision.push((
                        request.requester_id.clone(),
                        request.request_id.clone(),
                        request.expires_at_ms,
                    ));
                }
            }
            for (peer_id, request_id, expires_at_ms) in rejected_precision {
                self.send_control(
                    peer_id,
                    "precisionLocateResponse",
                    serde_json::to_vec(&json!({
                        "requestId": request_id,
                        "accepted": false,
                    }))?,
                    expires_at_ms,
                )?;
            }
            for peer in self
                .state
                .peers
                .iter()
                .filter(|peer| peer.ranging.is_some())
                .map(|peer| peer.peer_id.clone())
                .collect::<Vec<_>>()
            {
                self.queue(
                    "ranging",
                    &RangingCommand::Cancel {
                        request_id: RequestId::new(),
                        peer_id: peer,
                        reason: "locationSharingPaused".into(),
                    },
                )?;
            }
            for peer in &mut self.state.peers {
                peer.ranging = None;
            }
            self.queue(
                "location",
                &LocationCommand::StopTravelUpdates {
                    request_id: RequestId::new(),
                },
            )?;
        } else if self.state.is_traveling {
            self.queue(
                "location",
                &LocationCommand::StartTravelUpdates {
                    request_id: RequestId::new(),
                    background: true,
                },
            )?;
        }
        Ok(())
    }

    fn request_precision(&mut self, peer_id: PeerId, ttl_ms: i64) -> Result<(), CoreError> {
        self.require_member(&peer_id)?;
        if self.state.pending_precision.iter().any(|request| {
            request.target_id == peer_id
                && self.last_now_ms < request.expires_at_ms
                && matches!(
                    request.status,
                    PrecisionStatus::Pending | PrecisionStatus::Accepted | PrecisionStatus::Active
                )
        }) {
            return Err(CoreError::PrecisionRateLimited);
        }
        let request = PrecisionRequestSnapshot {
            request_id: RequestId::new(),
            requester_id: self.state.identity.peer_id.clone(),
            target_id: peer_id.clone(),
            created_at_ms: self.last_now_ms,
            expires_at_ms: self.last_now_ms.saturating_add(ttl_ms.max(1)),
            status: PrecisionStatus::Pending,
        };
        self.publish(
            "location.precision.requested",
            serde_json::to_value(&request)?,
            recipients(&peer_id),
            DeliveryPolicy::Transient {
                expires_at_ms: request.expires_at_ms,
            },
        )?;
        self.state.pending_precision.push(request.clone());
        self.send_control(
            peer_id,
            "precisionLocateRequest",
            serde_json::to_vec(&request)?,
            request.expires_at_ms,
        )?;
        Ok(())
    }

    fn request_peer_location(&mut self, peer_id: PeerId) -> Result<(), CoreError> {
        self.require_member(&peer_id)?;
        let request = LocationRequestPayload {
            request_id: RequestId::new(),
            requester_id: self.state.identity.peer_id.clone(),
            created_at_ms: self.last_now_ms,
            desired_freshness_ms: LOCATION_REQUEST_FRESHNESS_MS,
            deadline_ms: self
                .last_now_ms
                .saturating_add(LOCATION_REQUEST_DEADLINE_MS),
        };
        self.send_control(
            peer_id,
            "locationRequest",
            serde_json::to_vec(&request)?,
            request.deadline_ms,
        )
    }

    fn handle_location_request(
        &mut self,
        sender: PeerId,
        request: LocationRequestPayload,
    ) -> Result<(), CoreError> {
        if request.requester_id != sender || !self.group_members().contains(&sender) {
            return Err(CoreError::InvalidModuleEvent(
                "location request identity does not match its authenticated BLE peer".into(),
            ));
        }
        if self.state.sharing_paused {
            return self.send_location_response(
                sender,
                request.request_id,
                request.deadline_ms,
                LocationResponseStatus::Paused,
                None,
            );
        }
        let cached = self
            .state
            .peers
            .iter()
            .find(|peer| peer.peer_id == self.state.identity.peer_id)
            .and_then(|peer| peer.last_location.clone());
        if let Some(sample) = cached.as_ref() {
            let age_at_request = request
                .created_at_ms
                .saturating_sub(sample.sampled_at_ms)
                .max(0);
            if age_at_request <= request.desired_freshness_ms.max(0) {
                return self.send_location_response(
                    sender,
                    request.request_id,
                    request.deadline_ms,
                    LocationResponseStatus::Fresh,
                    Some(sample.clone()),
                );
            }
        }
        if request.deadline_ms <= request.created_at_ms {
            return self.send_location_response(
                sender,
                request.request_id,
                request.deadline_ms,
                if cached.is_some() {
                    LocationResponseStatus::Stale
                } else {
                    LocationResponseStatus::Timeout
                },
                cached,
            );
        }
        self.pending_location_replies.insert(
            request.request_id.clone(),
            PendingLocationReply {
                peer_id: sender,
                deadline_ms: request.deadline_ms,
            },
        );
        self.queue(
            "location",
            &LocationCommand::RequestSample {
                request_id: request.request_id,
                desired_freshness_ms: request.desired_freshness_ms.max(0),
                deadline_ms: request.deadline_ms,
            },
        )
    }

    fn handle_location_response(
        &mut self,
        sender: PeerId,
        response: LocationResponsePayload,
    ) -> Result<(), CoreError> {
        if response.responder_id != sender || !self.group_members().contains(&sender) {
            return Err(CoreError::InvalidModuleEvent(
                "location response identity does not match its authenticated BLE peer".into(),
            ));
        }
        if let Some(sample) = response.sample {
            self.ensure_peer(sender.clone(), self.peer_name(&sender));
            if let Some(peer) = self
                .state
                .peers
                .iter_mut()
                .find(|peer| peer.peer_id == sender)
            {
                if peer
                    .last_location
                    .as_ref()
                    .is_none_or(|current| sample.sampled_at_ms >= current.sampled_at_ms)
                {
                    peer.last_location = Some(sample);
                }
            }
        }
        tracing::debug!(
            subsystem = "location",
            request_id = %response.request_id,
            status = ?response.status,
            "BLE location response"
        );
        Ok(())
    }

    fn send_location_response(
        &mut self,
        peer_id: PeerId,
        request_id: RequestId,
        deadline_ms: i64,
        status: LocationResponseStatus,
        sample: Option<LocationSample>,
    ) -> Result<(), CoreError> {
        let response = LocationResponsePayload {
            request_id,
            responder_id: self.state.identity.peer_id.clone(),
            status,
            sample,
        };
        self.send_control(
            peer_id,
            "locationResponse",
            serde_json::to_vec(&response)?,
            deadline_ms,
        )
    }

    fn respond_precision(&mut self, request_id: &RequestId, accept: bool) -> Result<(), CoreError> {
        let (peer, expires_at_ms) = {
            let request = self
                .state
                .pending_precision
                .iter_mut()
                .find(|request| &request.request_id == request_id)
                .ok_or(CoreError::UnknownEntity)?;
            if self.last_now_ms >= request.expires_at_ms {
                request.status = PrecisionStatus::Expired;
                return Ok(());
            }
            request.status = if accept {
                PrecisionStatus::Accepted
            } else {
                PrecisionStatus::Rejected
            };
            let peer = if request.requester_id == self.state.identity.peer_id {
                request.target_id.clone()
            } else {
                request.requester_id.clone()
            };
            (peer, request.expires_at_ms)
        };
        if accept {
            self.queue(
                "ranging",
                &RangingCommand::CreateDiscoveryToken {
                    request_id: request_id.clone(),
                    peer_id: peer.clone(),
                },
            )?;
        }
        let payload = json!({"requestId": request_id, "accepted": accept});
        self.send_control(
            peer,
            "precisionLocateResponse",
            serde_json::to_vec(&payload)?,
            expires_at_ms,
        )?;
        Ok(())
    }

    fn send_message(
        &mut self,
        conversation: Conversation,
        content: MessageContent,
    ) -> Result<(), CoreError> {
        let audience = self.conversation_audience(&conversation)?;
        let message_id = EntityId::new();
        let payload = json!({
            "messageId": message_id,
            "conversation": conversation,
            "content": content,
            "sentAtMs": self.last_now_ms,
        });
        let (event_id, delivery) = self.publish(
            "im.message.sent",
            payload,
            audience,
            DeliveryPolicy::Durable,
        )?;
        let id = conversation.stable_id();
        let conversation_snapshot = if let Some(existing) = self
            .state
            .conversations
            .iter_mut()
            .find(|entry| entry.id == id)
        {
            existing
        } else {
            self.state.conversations.push(ConversationSnapshot {
                id: id.clone(),
                conversation: conversation.clone(),
                messages: Vec::new(),
            });
            self.state.conversations.last_mut().expect("just inserted")
        };
        conversation_snapshot.messages.push(MessageSnapshot {
            message_id,
            publication_event_id: event_id,
            sender_id: self.state.identity.peer_id.clone(),
            content,
            sent_at_ms: self.last_now_ms,
            delivery,
        });
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    fn register_media(
        &mut self,
        conversation: Conversation,
        media_kind: MediaKind,
        resource_id: ResourceId,
        thumbnail_resource_id: Option<ResourceId>,
        mime_type: String,
        duration_ms: Option<u64>,
        source_path: Option<&str>,
    ) -> Result<(), CoreError> {
        let audience = self.conversation_audience(&conversation)?;
        let source_path = source_path.ok_or_else(|| {
            CoreError::ResourceSource("media registration requires a local source path".into())
        })?;
        let bytes = std::fs::read(source_path).map_err(|error| {
            CoreError::ResourceSource(format!("could not read {source_path}: {error}"))
        })?;
        let manifest = build_manifest(
            resource_id.clone(),
            mime_type.clone(),
            &bytes,
            RESOURCE_CHUNK_SIZE,
        )?;
        let mut transfer = self.resource_store.begin(manifest.clone())?;
        for descriptor in &manifest.chunks {
            let start = usize::try_from(descriptor.offset).map_err(|_| ResourceError::TooLarge)?;
            let size = usize::try_from(descriptor.size).map_err(|_| ResourceError::TooLarge)?;
            let end = start.checked_add(size).ok_or(ResourceError::TooLarge)?;
            transfer.accept_chunk(descriptor.index, &bytes[start..end])?;
        }
        let local_path = transfer.finalize()?.to_string_lossy().into_owned();
        self.publish(
            "resource.manifest",
            serde_json::to_value(&manifest)?,
            audience,
            DeliveryPolicy::Durable,
        )?;
        self.upsert_resource(ResourceSnapshot {
            manifest,
            local_path: Some(local_path),
            transferred_bytes: u64::try_from(bytes.len()).unwrap_or(u64::MAX),
            status: ResourceTransferStatus::Available,
            last_error: None,
        });

        let content = match media_kind {
            MediaKind::Image => MessageContent::Image {
                original: resource_id,
                thumbnail: thumbnail_resource_id.ok_or(CoreError::UnknownEntity)?,
                mime_type,
            },
            MediaKind::Voice => MessageContent::Voice {
                resource: resource_id,
                duration_ms: duration_ms.ok_or(CoreError::UnknownEntity)?,
                mime_type,
            },
        };
        self.send_message(conversation, content)
    }

    fn cancel_resource(&mut self, resource_id: &ResourceId) -> Result<(), CoreError> {
        if !self.resource_store.cancel(resource_id)? {
            return Err(CoreError::UnknownEntity);
        }
        if let Some(resource) = self
            .state
            .resources
            .iter_mut()
            .find(|resource| &resource.manifest.resource_id == resource_id)
        {
            resource.status = ResourceTransferStatus::Cancelled;
            resource.local_path = None;
            resource.transferred_bytes = 0;
            resource.last_error = None;
        }
        Ok(())
    }

    fn retry_resource(&mut self, resource_id: &ResourceId) -> Result<(), CoreError> {
        let manifest = self
            .state
            .resources
            .iter()
            .find(|resource| &resource.manifest.resource_id == resource_id)
            .map(|resource| resource.manifest.clone())
            .ok_or(CoreError::UnknownEntity)?;
        let mut transfer = match self.resource_store.retry(resource_id) {
            Ok(transfer) => transfer,
            Err(ResourceError::UnknownResource(_)) => self.resource_store.begin(manifest)?,
            Err(error) => return Err(error.into()),
        };
        let (transferred_bytes, _) = transfer.progress()?;
        let completed_path = transfer.completed_path()?;
        if let Some(resource) = self
            .state
            .resources
            .iter_mut()
            .find(|resource| &resource.manifest.resource_id == resource_id)
        {
            resource.transferred_bytes = transferred_bytes;
            resource.local_path = completed_path
                .as_ref()
                .map(|path| path.to_string_lossy().into_owned());
            resource.status = if completed_path.is_some() {
                ResourceTransferStatus::Available
            } else {
                ResourceTransferStatus::Pending
            };
            resource.last_error = None;
        }
        if completed_path.is_none() {
            for connection in self
                .transport_connections
                .values()
                .copied()
                .collect::<Vec<_>>()
            {
                self.request_resource(connection, resource_id)?;
            }
        }
        Ok(())
    }

    fn conversation_audience(
        &self,
        conversation: &Conversation,
    ) -> Result<GroupAudience, CoreError> {
        match conversation {
            Conversation::Group => Ok(GroupAudience::Group),
            Conversation::Direct { peer_id } => {
                self.require_member(peer_id)?;
                Ok(recipients(peer_id))
            }
        }
    }

    fn upsert_resource(&mut self, incoming: ResourceSnapshot) {
        if let Some(existing) = self
            .state
            .resources
            .iter_mut()
            .find(|resource| resource.manifest.resource_id == incoming.manifest.resource_id)
        {
            *existing = incoming;
        } else {
            self.state.resources.push(incoming);
        }
    }

    fn recover_resources(&mut self) -> Result<(), CoreError> {
        let manifests = self
            .state
            .resources
            .iter()
            .filter(|resource| resource.status != ResourceTransferStatus::Cancelled)
            .map(|resource| resource.manifest.clone())
            .collect::<Vec<_>>();
        for manifest in manifests {
            let result = self
                .resource_store
                .resume(&manifest.resource_id)
                .and_then(|transfer| match transfer {
                    Some(transfer) => Ok(transfer),
                    None => self.resource_store.begin(manifest.clone()),
                });
            match result {
                Ok(mut transfer) => {
                    let (transferred_bytes, _) = transfer.progress()?;
                    let completed_path = transfer.completed_path()?;
                    self.upsert_resource(ResourceSnapshot {
                        manifest,
                        local_path: completed_path
                            .as_ref()
                            .map(|path| path.to_string_lossy().into_owned()),
                        transferred_bytes,
                        status: if completed_path.is_some() {
                            ResourceTransferStatus::Available
                        } else {
                            ResourceTransferStatus::Pending
                        },
                        last_error: None,
                    });
                }
                Err(error) => {
                    self.upsert_resource(ResourceSnapshot {
                        manifest,
                        local_path: None,
                        transferred_bytes: 0,
                        status: ResourceTransferStatus::Failed,
                        last_error: Some(error.to_string()),
                    });
                }
            }
        }
        Ok(())
    }

    fn request_pending_resources(&mut self, connection: ConnectionHandle) -> Result<(), CoreError> {
        let resources = self
            .state
            .resources
            .iter()
            .filter(|resource| resource.status == ResourceTransferStatus::Pending)
            .map(|resource| resource.manifest.resource_id.clone())
            .collect::<Vec<_>>();
        for resource_id in resources {
            self.request_resource(connection, &resource_id)?;
        }
        Ok(())
    }

    fn request_resource(
        &mut self,
        connection: ConnectionHandle,
        resource_id: &ResourceId,
    ) -> Result<(), CoreError> {
        let Some(mut transfer) = self.resource_store.resume(resource_id)? else {
            return Ok(());
        };
        if let Some(path) = transfer.completed_path()? {
            if let Some(resource) = self
                .state
                .resources
                .iter_mut()
                .find(|resource| &resource.manifest.resource_id == resource_id)
            {
                resource.local_path = Some(path.to_string_lossy().into_owned());
                resource.transferred_bytes = resource.manifest.byte_size;
                resource.status = ResourceTransferStatus::Available;
                resource.last_error = None;
            }
            return Ok(());
        }
        let missing = transfer.missing_chunks()?.into_iter().collect::<Vec<_>>();
        for chunk_indices in missing.chunks(128) {
            self.send_wire(
                connection,
                &WireMessage::ResourceRequest {
                    protocol_version: PROTOCOL_VERSION,
                    request_id: RequestId::new(),
                    resource_id: resource_id.to_string(),
                    chunk_indices: chunk_indices.to_vec(),
                },
                TrafficClass::Bulk,
            )?;
        }
        Ok(())
    }

    fn send_resource_chunks(
        &mut self,
        connection: ConnectionHandle,
        request_id: RequestId,
        resource_id: ResourceId,
        chunk_indices: Vec<u32>,
    ) -> Result<(), CoreError> {
        if !self.transport_peers.contains_key(&connection) {
            return Err(CoreError::InvalidModuleEvent(
                "resource request arrived on an unauthenticated connection".into(),
            ));
        }
        let Some(mut transfer) = self.resource_store.resume(&resource_id)? else {
            return Ok(());
        };
        if transfer.completed_path()?.is_none() {
            return Ok(());
        }
        for chunk_index in chunk_indices {
            let bytes = transfer.read_chunk(chunk_index)?;
            self.send_wire(
                connection,
                &WireMessage::ResourceChunk {
                    protocol_version: PROTOCOL_VERSION,
                    request_id: request_id.clone(),
                    resource_id: resource_id.to_string(),
                    chunk_index,
                    bytes,
                },
                TrafficClass::Bulk,
            )?;
        }
        Ok(())
    }

    fn receive_resource_chunk(
        &mut self,
        resource_id: ResourceId,
        chunk_index: u32,
        bytes: &[u8],
    ) -> Result<(), CoreError> {
        let Some(mut transfer) = self.resource_store.resume(&resource_id)? else {
            return Ok(());
        };
        if let Err(error) = transfer.accept_chunk(chunk_index, bytes) {
            if let Some(resource) = self
                .state
                .resources
                .iter_mut()
                .find(|resource| resource.manifest.resource_id == resource_id)
            {
                resource.status = ResourceTransferStatus::Failed;
                resource.last_error = Some(error.to_string());
            }
            tracing::error!(subsystem = "resources", %error, "rejected resource chunk");
            return Ok(());
        }
        let (transferred_bytes, _) = transfer.progress()?;
        let completed_path = if transfer.missing_chunks()?.is_empty() {
            Some(transfer.finalize()?)
        } else {
            None
        };
        if let Some(resource) = self
            .state
            .resources
            .iter_mut()
            .find(|resource| resource.manifest.resource_id == resource_id)
        {
            resource.transferred_bytes = transferred_bytes;
            resource.local_path = completed_path
                .as_ref()
                .map(|path| path.to_string_lossy().into_owned());
            resource.status = if completed_path.is_some() {
                ResourceTransferStatus::Available
            } else {
                ResourceTransferStatus::Pending
            };
            resource.last_error = None;
        }
        Ok(())
    }

    fn create_place(
        &mut self,
        title: String,
        note: String,
        latitude: f64,
        longitude: f64,
    ) -> Result<(), CoreError> {
        let place = PlaceSnapshot {
            id: EntityId::new(),
            title,
            note,
            latitude,
            longitude,
            author_id: self.state.identity.peer_id.clone(),
            created_at_ms: self.last_now_ms,
            updated_at_ms: self.last_now_ms,
            deleted: false,
        };
        self.publish(
            "place.created",
            serde_json::to_value(&place)?,
            GroupAudience::Group,
            DeliveryPolicy::Durable,
        )?;
        self.state.places.push(place);
        Ok(())
    }

    fn update_place(
        &mut self,
        place_id: &EntityId,
        title: Option<String>,
        note: Option<String>,
        latitude: Option<f64>,
        longitude: Option<f64>,
    ) -> Result<(), CoreError> {
        let place = self
            .state
            .places
            .iter_mut()
            .find(|place| &place.id == place_id)
            .ok_or(CoreError::UnknownEntity)?;
        if let Some(title) = title {
            place.title = title;
        }
        if let Some(note) = note {
            place.note = note;
        }
        if let Some(latitude) = latitude {
            place.latitude = latitude;
        }
        if let Some(longitude) = longitude {
            place.longitude = longitude;
        }
        place.updated_at_ms = self.last_now_ms;
        let payload = serde_json::to_value(&*place)?;
        self.publish(
            "place.updated",
            payload,
            GroupAudience::Group,
            DeliveryPolicy::Durable,
        )?;
        Ok(())
    }

    fn delete_place(&mut self, place_id: &EntityId) -> Result<(), CoreError> {
        let place = self
            .state
            .places
            .iter_mut()
            .find(|place| &place.id == place_id)
            .ok_or(CoreError::UnknownEntity)?;
        place.deleted = true;
        place.updated_at_ms = self.last_now_ms;
        let payload = json!({"placeId": place_id, "deletedAtMs": self.last_now_ms});
        self.publish(
            "place.deleted",
            payload,
            GroupAudience::Group,
            DeliveryPolicy::Durable,
        )?;
        Ok(())
    }

    fn acquire_document_lease(&mut self, duration_ms: i64) -> Result<(), CoreError> {
        if let Some(active) = self.document.active_lease(self.last_now_ms) {
            if active.holder_id != self.state.identity.peer_id {
                return Err(CoreError::LeaseHeldByAnother);
            }
        }
        let lease = self.document.acquire_lease(
            self.state.identity.peer_id.clone(),
            self.last_now_ms,
            duration_ms,
        )?;
        self.publish(
            "document.lease.acquired",
            serde_json::to_value(&lease)?,
            GroupAudience::Group,
            DeliveryPolicy::Transient {
                expires_at_ms: lease.expires_at_ms,
            },
        )?;
        self.state.document_leases.push(lease);
        Ok(())
    }

    fn save_document(
        &mut self,
        markdown: String,
        parent: Option<RevisionId>,
    ) -> Result<(), CoreError> {
        if let Some(active) = self.document.active_lease(self.last_now_ms) {
            if active.holder_id != self.state.identity.peer_id {
                return Err(CoreError::LeaseHeldByAnother);
            }
        }
        let revision = self.document.save(
            self.state.identity.peer_id.clone(),
            parent,
            markdown,
            self.last_now_ms,
        )?;
        self.publish(
            "document.revision.saved",
            serde_json::to_value(&revision)?,
            GroupAudience::Group,
            DeliveryPolicy::Durable,
        )?;
        self.state.document_revisions.push(revision);
        Ok(())
    }

    fn release_document_lease(&mut self, lease_id: &LeaseId) -> Result<(), CoreError> {
        let event = self.document.release_lease(
            lease_id,
            &self.state.identity.peer_id,
            self.last_now_ms,
        )?;
        if let Some(lease) = self
            .state
            .document_leases
            .iter_mut()
            .find(|lease| &lease.lease_id == lease_id)
        {
            lease.released_at_ms = Some(self.last_now_ms);
        }
        self.publish(
            "document.lease.released",
            serde_json::to_value(event)?,
            GroupAudience::Group,
            DeliveryPolicy::Transient {
                expires_at_ms: self.last_now_ms.saturating_add(30_000),
            },
        )?;
        Ok(())
    }

    fn start_call(&mut self, peer_id: PeerId) -> Result<(), CoreError> {
        self.require_member(&peer_id)?;
        let signal = self.call.start(peer_id.clone(), self.last_now_ms, 30_000)?;
        self.publish_call_signal(&peer_id, &signal, 30_000)?;
        let CallSignal::Offer { call_id, .. } = &signal else {
            unreachable!()
        };
        self.queue(
            "callSystem",
            &CallSystemCommand::ReportOutgoing {
                request_id: RequestId::new(),
                call_id: call_id.clone(),
                peer_id: peer_id.clone(),
                display_name: self.peer_name(&peer_id),
            },
        )?;
        self.queue(
            "peerTransport",
            &TransportCommand::Connect {
                request_id: RequestId::new(),
                peer_id,
            },
        )?;
        self.queue(
            "peerTransport",
            &TransportCommand::SetRealtime {
                request_id: RequestId::new(),
                realtime: true,
            },
        )?;
        Ok(())
    }

    fn answer_call(&mut self) -> Result<(), CoreError> {
        let peer = call_peer(self.call.state()).ok_or(CoreError::UnknownEntity)?;
        let signal = self.call.answer(self.last_now_ms)?;
        let call_id = call_id_from_signal(&signal).clone();
        self.publish_call_signal(&peer, &signal, 30_000)?;
        self.queue(
            "callSystem",
            &CallSystemCommand::ActivateAudio {
                request_id: RequestId::new(),
                call_id,
            },
        )?;
        self.queue(
            "peerTransport",
            &TransportCommand::Connect {
                request_id: RequestId::new(),
                peer_id: peer,
            },
        )?;
        self.queue(
            "peerTransport",
            &TransportCommand::SetRealtime {
                request_id: RequestId::new(),
                realtime: true,
            },
        )?;
        Ok(())
    }

    fn reject_call(&mut self) -> Result<(), CoreError> {
        let peer = call_peer(self.call.state()).ok_or(CoreError::UnknownEntity)?;
        let signal = self.call.reject(self.last_now_ms)?;
        let call_id = call_id_from_signal(&signal).clone();
        self.publish_call_signal(&peer, &signal, 30_000)?;
        self.queue(
            "callSystem",
            &CallSystemCommand::End {
                request_id: RequestId::new(),
                call_id,
                reason: "localRejected".into(),
            },
        )?;
        self.queue(
            "peerTransport",
            &TransportCommand::SetRealtime {
                request_id: RequestId::new(),
                realtime: false,
            },
        )?;
        Ok(())
    }

    fn end_call(&mut self) -> Result<(), CoreError> {
        let peer = call_peer(self.call.state()).ok_or(CoreError::UnknownEntity)?;
        let signal = self.call.end(self.last_now_ms)?;
        let call_id = call_id_from_signal(&signal).clone();
        self.publish_call_signal(&peer, &signal, 30_000)?;
        self.queue(
            "callSystem",
            &CallSystemCommand::End {
                request_id: RequestId::new(),
                call_id,
                reason: "localEnded".into(),
            },
        )?;
        self.queue(
            "peerTransport",
            &TransportCommand::SetRealtime {
                request_id: RequestId::new(),
                realtime: false,
            },
        )?;
        Ok(())
    }

    fn set_foreground(&mut self, foreground: bool) -> Result<(), CoreError> {
        self.state.is_foreground = foreground;
        if !foreground {
            for peer in self
                .state
                .peers
                .iter()
                .filter(|peer| peer.ranging.is_some())
                .map(|peer| peer.peer_id.clone())
                .collect::<Vec<_>>()
            {
                self.queue(
                    "ranging",
                    &RangingCommand::Cancel {
                        request_id: RequestId::new(),
                        peer_id: peer,
                        reason: "appBackgrounded".into(),
                    },
                )?;
            }
            for peer in &mut self.state.peers {
                peer.ranging = None;
            }
            for request in &mut self.state.pending_precision {
                if matches!(request.status, PrecisionStatus::Active) {
                    request.status = PrecisionStatus::Accepted;
                }
            }
        }
        Ok(())
    }

    fn clear_trip_data(&mut self) -> Result<(), CoreError> {
        if self.state.is_traveling {
            self.end_travel()?;
        }
        self.state.group = None;
        self.state.processed_control_ids.clear();
        self.state.peers.clear();
        self.state.conversations.clear();
        for resource_id in self
            .state
            .resources
            .iter()
            .map(|resource| resource.manifest.resource_id.clone())
            .collect::<Vec<_>>()
        {
            self.resource_store.cancel(&resource_id)?;
        }
        self.state.resources.clear();
        self.resource_store.cleanup()?;
        self.state.places.clear();
        self.state.document_revisions.clear();
        self.state.document_leases.clear();
        self.state.pending_precision.clear();
        self.document = DocumentState::default();
        self.replication = None;
        self.group_key = None;
        self.transport_connections.clear();
        self.transport_peers.clear();
        self.transport_decoders.clear();
        self.pending_controls.clear();
        self.pending_location_replies.clear();
        self.precision_request_cooldowns.clear();
        self.pending_join_pin = None;
        self.pending_invitations.clear();
        self.pending_joiner_handshake = None;
        self.pending_inviter_admissions.clear();
        self.state_store.clear_synchronized_data()?;
        self.queue(
            "secureStorage",
            &SecureStorageCommand::Delete {
                request_id: RequestId::new(),
                key: GROUP_KEY.into(),
            },
        )?;
        Ok(())
    }

    fn on_bluetooth(&mut self, event: BluetoothEvent) -> Result<(), CoreError> {
        match event {
            BluetoothEvent::PeerDiscovered { peer_id, handle } => {
                tracing::debug!(subsystem = "groupAuth", ?handle, "BLE peer discovered");
                self.bluetooth_handles.insert(peer_id.clone(), handle);
                self.queue(
                    "bluetooth",
                    &BluetoothCommand::Connect {
                        request_id: RequestId::new(),
                        peer_id,
                        handle,
                    },
                )?;
            }
            BluetoothEvent::Connected { handle, .. } => {
                tracing::info!(
                    subsystem = "groupAuth",
                    ?handle,
                    "BLE admission channel ready"
                );
                self.send_group_presence(handle)?;
                self.send_invitation_info(handle)?;
            }
            BluetoothEvent::Disconnected { handle, .. } => {
                if let Some(peer) = self
                    .bluetooth_handles
                    .iter()
                    .find_map(|(peer, candidate)| (*candidate == handle).then(|| peer.clone()))
                {
                    self.set_peer_connected(&peer, false);
                }
            }
            BluetoothEvent::ControlReceived { handle, message } => {
                self.on_control_received(handle, message)?;
            }
            BluetoothEvent::Failed { message, .. } => {
                tracing::error!(subsystem = "bluetooth", %message, "Bluetooth backend failed");
            }
            BluetoothEvent::Started { .. }
            | BluetoothEvent::Stopped { .. }
            | BluetoothEvent::ControlSent { .. } => {}
        }
        Ok(())
    }

    fn on_control_received(
        &mut self,
        handle: PeerHandle,
        message: BluetoothControlMessage,
    ) -> Result<(), CoreError> {
        match message {
            BluetoothControlMessage::InvitationInfo { payload } => {
                self.on_invitation_info(handle, &payload)?;
            }
            BluetoothControlMessage::JoinHello { payload } => {
                self.on_join_hello(handle, &payload)?;
            }
            BluetoothControlMessage::JoinResponse { payload } => {
                self.on_join_response(handle, &payload)?;
            }
            BluetoothControlMessage::JoinConfirmation { payload } => {
                self.on_join_confirmation(handle, &payload)?;
            }
            BluetoothControlMessage::GroupControl { payload } => {
                self.on_group_control_received(handle, &payload)?;
            }
        }
        Ok(())
    }

    fn on_group_control_received(
        &mut self,
        handle: PeerHandle,
        payload: &[u8],
    ) -> Result<(), CoreError> {
        let envelope: GroupControlEnvelope = serde_json::from_slice(payload)?;
        if envelope.protocol_version != PROTOCOL_VERSION {
            return Err(CoreError::InvalidModuleEvent(format!(
                "unsupported BLE control protocol {}",
                envelope.protocol_version
            )));
        }
        if envelope.expires_at_ms <= envelope.created_at_ms
            || self.last_now_ms > envelope.expires_at_ms
            || envelope.created_at_ms > self.last_now_ms.saturating_add(300_000)
        {
            tracing::warn!(
                subsystem = "control",
                "discarded expired or future BLE group control"
            );
            return Ok(());
        }
        let Some(group) = self.state.group.clone() else {
            tracing::debug!(
                subsystem = "groupAuth",
                ?handle,
                "ignored BLE group control received before admission completed"
            );
            return Ok(());
        };
        let Some(group_key) = self.group_key else {
            tracing::debug!(
                subsystem = "groupAuth",
                ?handle,
                "ignored BLE group control while group credential is unavailable"
            );
            return Ok(());
        };
        let associated_data = group_control_associated_data(
            envelope.protocol_version,
            envelope.created_at_ms,
            envelope.expires_at_ms,
        );
        let plaintext = open(
            &SecretKeyMaterial(group_key),
            &envelope.sealed,
            &associated_data,
        )
        .map_err(|error| CoreError::GroupAuth(error.to_string()))?;
        let control: GroupControlPayload = serde_json::from_slice(&plaintext)?;
        if control.group_id != group.id
            || control.group_epoch != group.epoch
            || control
                .recipient_id
                .as_ref()
                .is_some_and(|recipient| recipient != &self.state.identity.peer_id)
        {
            return Err(CoreError::GroupAuth(
                "BLE group control belongs to another group, epoch, or recipient".into(),
            ));
        }
        let Some(member) = group
            .members
            .iter()
            .find(|member| member.active && member.peer_id == control.sender_id)
        else {
            return Err(CoreError::GroupAuth(
                "BLE group control sender is not an active member".into(),
            ));
        };
        if self
            .state
            .processed_control_ids
            .contains(&control.control_id)
        {
            return Ok(());
        }
        self.state
            .processed_control_ids
            .insert(control.control_id.clone());
        while self.state.processed_control_ids.len() > 2_048 {
            let Some(oldest) = self.state.processed_control_ids.iter().next().cloned() else {
                break;
            };
            self.state.processed_control_ids.remove(&oldest);
        }

        let sender = control.sender_id;
        let newly_authenticated = self.bluetooth_handles.get(&sender) != Some(&handle);
        let display_name = member.display_name.clone();
        self.bind_bluetooth_handle(handle, sender.clone());
        self.ensure_peer(sender.clone(), display_name);
        self.set_peer_connected(&sender, true);
        if newly_authenticated {
            for pending in self.pending_controls.remove(&sender).unwrap_or_default() {
                self.send_control(
                    sender.clone(),
                    pending.kind,
                    pending.payload,
                    pending.expires_at_ms,
                )?;
            }
            if self.state.is_traveling {
                self.request_peer_location(sender.clone())?;
            }
        }
        self.on_authenticated_control_received(sender, &control.kind, &control.payload)
    }

    fn on_authenticated_control_received(
        &mut self,
        sender: PeerId,
        kind: &str,
        payload: &[u8],
    ) -> Result<(), CoreError> {
        match kind {
            "presence" => {}
            "locationRequest" => {
                let request: LocationRequestPayload = serde_json::from_slice(payload)?;
                self.handle_location_request(sender.clone(), request)?;
            }
            "locationResponse" => {
                let response: LocationResponsePayload = serde_json::from_slice(payload)?;
                self.handle_location_response(sender.clone(), response)?;
            }
            "precisionLocateRequest" => {
                let mut request: PrecisionRequestSnapshot = serde_json::from_slice(payload)?;
                if self
                    .state
                    .pending_precision
                    .iter()
                    .any(|existing| existing.request_id == request.request_id)
                {
                    return Ok(());
                }
                if request.requester_id != sender
                    || !self.group_members().contains(&request.requester_id)
                    || request.target_id != self.state.identity.peer_id
                {
                    return Err(CoreError::InvalidModuleEvent(
                        "precision request identity does not match its authenticated BLE peer"
                            .into(),
                    ));
                }
                let previous = self
                    .precision_request_cooldowns
                    .get(&sender)
                    .copied()
                    .unwrap_or(i64::MIN);
                let rate_limited =
                    request.created_at_ms.saturating_sub(previous) < PRECISION_REQUEST_COOLDOWN_MS;
                self.precision_request_cooldowns
                    .insert(sender.clone(), request.created_at_ms);
                if self.state.sharing_paused || rate_limited {
                    request.status = PrecisionStatus::Rejected;
                    self.state.pending_precision.push(request.clone());
                    self.send_control(
                        sender,
                        "precisionLocateResponse",
                        serde_json::to_vec(&json!({
                            "requestId": request.request_id,
                            "accepted": false,
                        }))?,
                        request.expires_at_ms,
                    )?;
                    return Ok(());
                }
                self.state.pending_precision.push(request.clone());
                self.queue(
                    "notifications",
                    &NotificationCommand::Schedule {
                        request_id: RequestId::new(),
                        identifier: request.request_id.to_string(),
                        title: "Precision location requested".into(),
                        body: format!("{} is looking for you", self.peer_name(&sender)),
                        deep_link: Some(format!(
                            "travel-companion://precision/{}",
                            request.request_id
                        )),
                        merge_key: Some(format!("precision/{sender}")),
                        time_sensitive: true,
                    },
                )?;
            }
            "precisionLocateResponse" => {
                #[derive(Deserialize)]
                #[serde(rename_all = "camelCase")]
                struct Response {
                    request_id: RequestId,
                    accepted: bool,
                }
                let response: Response = serde_json::from_slice(payload)?;
                if let Some(request) = self
                    .state
                    .pending_precision
                    .iter_mut()
                    .find(|request| request.request_id == response.request_id)
                {
                    request.status = if response.accepted {
                        PrecisionStatus::Accepted
                    } else {
                        PrecisionStatus::Rejected
                    };
                }
                if response.accepted && self.state.is_foreground {
                    self.queue(
                        "ranging",
                        &RangingCommand::CreateDiscoveryToken {
                            request_id: response.request_id,
                            peer_id: sender.clone(),
                        },
                    )?;
                }
            }
            "precisionDiscoveryToken" => {
                #[derive(Deserialize)]
                #[serde(rename_all = "camelCase")]
                struct Token {
                    request_id: RequestId,
                    token: Vec<u8>,
                }
                let token: Token = serde_json::from_slice(payload)?;
                if self.state.is_foreground {
                    self.queue(
                        "ranging",
                        &RangingCommand::Start {
                            request_id: token.request_id,
                            peer_id: sender.clone(),
                            remote_discovery_token: token.token,
                        },
                    )?;
                }
            }
            "callOffer" => {
                let signal: CallSignal = serde_json::from_slice(payload)?;
                if let CallSignal::Offer {
                    call_id,
                    caller_id,
                    expires_at_ms,
                    ..
                } = signal
                {
                    let response = self.call.receive_offer(
                        call_id.clone(),
                        caller_id.clone(),
                        self.last_now_ms,
                        expires_at_ms,
                        self.last_now_ms,
                    )?;
                    if let Some(rejection) = response {
                        self.publish_call_signal(&caller_id, &rejection, 30_000)?;
                    } else {
                        self.queue(
                            "callSystem",
                            &CallSystemCommand::ReportIncoming {
                                request_id: RequestId::new(),
                                call_id,
                                peer_id: caller_id.clone(),
                                display_name: self.peer_name(&caller_id),
                            },
                        )?;
                    }
                }
            }
            "callAnswer" => {
                let signal: CallSignal = serde_json::from_slice(payload)?;
                if let CallSignal::Answer { call_id } = signal {
                    self.call.receive_answer(&call_id)?;
                    self.queue(
                        "callSystem",
                        &CallSystemCommand::ActivateAudio {
                            request_id: RequestId::new(),
                            call_id,
                        },
                    )?;
                    self.queue(
                        "peerTransport",
                        &TransportCommand::SetRealtime {
                            request_id: RequestId::new(),
                            realtime: true,
                        },
                    )?;
                }
            }
            "callEnd" | "callReject" => {
                let signal: CallSignal = serde_json::from_slice(payload)?;
                let call_id = call_id_from_signal(&signal).clone();
                self.call.receive_termination(&signal, self.last_now_ms)?;
                self.queue(
                    "callSystem",
                    &CallSystemCommand::End {
                        request_id: RequestId::new(),
                        call_id,
                        reason: "remoteEnded".into(),
                    },
                )?;
                self.queue(
                    "peerTransport",
                    &TransportCommand::SetRealtime {
                        request_id: RequestId::new(),
                        realtime: false,
                    },
                )?;
            }
            "dataAvailable" => {
                tracing::debug!(
                    subsystem = "control",
                    %kind,
                    %sender,
                    "received group control"
                );
                self.start_transport_if_ready()?;
                if let Some(connection) = self.transport_connections.get(&sender).copied() {
                    let digest = self
                        .replication
                        .as_ref()
                        .map(ReplicationEngine::digest)
                        .transpose()?;
                    if let Some(digest) = digest {
                        self.send_wire(
                            connection,
                            &WireMessage::SyncDigest {
                                protocol_version: PROTOCOL_VERSION,
                                digest,
                            },
                            TrafficClass::EnergyEfficient,
                        )?;
                    }
                }
            }
            _ => tracing::warn!(
                subsystem = "control",
                %kind,
                "ignored unknown control"
            ),
        }
        Ok(())
    }

    fn send_invitation_info(&mut self, handle: PeerHandle) -> Result<(), CoreError> {
        if self.group_key.is_none() {
            return Ok(());
        }
        let Some(group) = self.state.group.as_ref() else {
            return Ok(());
        };
        let is_owner = group.members.iter().any(|member| {
            member.peer_id == self.state.identity.peer_id
                && member.active
                && member.role == MemberRole::Owner
        });
        if !is_owner || group.invite_pin.is_none() {
            return Ok(());
        }
        let public_key = self
            .state
            .member_public_keys
            .get(&self.state.identity.peer_id)
            .cloned()
            .ok_or(CoreError::IdentityUnavailable)?;
        let admission_id = GroupId::new();
        self.pending_invitations
            .insert(handle, admission_id.clone());
        let invitation = InvitationInfo {
            admission_id,
            inviter_peer_id: self.state.identity.peer_id.clone(),
            inviter_display_name: self.state.identity.display_name.clone(),
            inviter_public_key: public_key,
        };
        self.send_control_handle(
            handle,
            BluetoothControlMessage::InvitationInfo {
                payload: serde_json::to_vec(&invitation)?,
            },
            self.last_now_ms.saturating_add(300_000),
        )
    }

    fn on_invitation_info(&mut self, handle: PeerHandle, payload: &[u8]) -> Result<(), CoreError> {
        if self.state.group.is_some() || self.pending_joiner_handshake.is_some() {
            return Ok(());
        }
        let Some(pin) = self.pending_join_pin.clone() else {
            return Ok(());
        };
        let invitation: InvitationInfo = serde_json::from_slice(payload)?;
        tracing::info!(
            subsystem = "groupAuth",
            ?handle,
            "received invitation; starting PIN handshake"
        );
        let _: [u8; 32] = invitation
            .inviter_public_key
            .as_slice()
            .try_into()
            .map_err(|_| CoreError::GroupAuth("inviter public key is malformed".into()))?;
        let (handshake, hello) = PinHandshake::start_joiner(
            invitation.admission_id,
            1,
            self.state.identity.peer_id.clone(),
            invitation.inviter_peer_id.clone(),
            &pin,
        );
        self.pending_joiner_handshake = Some(handshake);
        self.bind_bluetooth_handle(handle, invitation.inviter_peer_id.clone());
        self.ensure_peer(invitation.inviter_peer_id, invitation.inviter_display_name);
        let public_key = self
            .state
            .member_public_keys
            .get(&self.state.identity.peer_id)
            .cloned()
            .ok_or(CoreError::IdentityUnavailable)?;
        self.send_control_handle(
            handle,
            BluetoothControlMessage::JoinHello {
                payload: serde_json::to_vec(&JoinHelloPayload {
                    hello,
                    display_name: self.state.identity.display_name.clone(),
                    public_key,
                })?,
            },
            self.last_now_ms.saturating_add(120_000),
        )?;
        tracing::info!(
            subsystem = "groupAuth",
            ?handle,
            "sent authenticated join hello"
        );
        Ok(())
    }

    fn on_join_hello(&mut self, handle: PeerHandle, payload: &[u8]) -> Result<(), CoreError> {
        let request: JoinHelloPayload = serde_json::from_slice(payload)?;
        let group = self.state.group.clone().ok_or(CoreError::NoActiveGroup)?;
        let pin = group
            .invite_pin
            .as_deref()
            .ok_or_else(|| CoreError::GroupAuth("this device has no active invitation".into()))?;
        let admission_id = self
            .pending_invitations
            .get(&handle)
            .ok_or_else(|| CoreError::GroupAuth("join hello has no active invitation".into()))?;
        if &request.hello.group_id != admission_id || request.hello.epoch != 1 {
            return Err(CoreError::GroupAuth(
                "join hello belongs to another admission transcript".into(),
            ));
        }
        let _: [u8; 32] = request
            .public_key
            .as_slice()
            .try_into()
            .map_err(|_| CoreError::GroupAuth("joiner public key is malformed".into()))?;
        let group_key = self
            .group_key
            .ok_or(CoreError::GroupCredentialUnavailable)?;
        let (handshake, local_hello) = PinHandshake::start_inviter(
            admission_id.clone(),
            1,
            self.state.identity.peer_id.clone(),
            request.hello.peer_id.clone(),
            pin,
        );
        let session = handshake
            .finish(&request.hello)
            .map_err(|error| CoreError::GroupAuth(error.to_string()))?;

        let mut admitted_group = group;
        admitted_group.invite_pin = None;
        if !admitted_group
            .members
            .iter()
            .any(|member| member.peer_id == request.hello.peer_id)
        {
            admitted_group.members.push(MemberSnapshot {
                peer_id: request.hello.peer_id.clone(),
                display_name: request.display_name.clone(),
                role: MemberRole::Member,
                active: true,
            });
        }
        let mut member_public_keys = self.state.member_public_keys.clone();
        member_public_keys.insert(request.hello.peer_id.clone(), request.public_key.clone());
        let credential = AdmissionCredential {
            group: admitted_group,
            member_public_keys: member_public_keys
                .into_iter()
                .map(|(peer, key)| (peer, encode_binary(&key)))
                .collect(),
            group_key: encode_binary(&group_key),
        };
        let associated_data = admission_associated_data(
            &request.hello.group_id,
            request.hello.epoch,
            &request.hello.peer_id,
        );
        let sealed_credential = seal(
            &session.key,
            &serde_json::to_vec(&credential)?,
            &associated_data,
        );
        let response = JoinResponsePayload {
            hello: local_hello,
            confirmation: encode_binary(&session.confirmation(b"inviter")),
            sealed_nonce: encode_binary(&sealed_credential.nonce),
            sealed_credential: encode_binary(&sealed_credential.ciphertext),
        };
        self.bind_bluetooth_handle(handle, request.hello.peer_id.clone());
        self.pending_inviter_admissions.insert(
            handle,
            PendingInviterAdmission {
                session,
                joiner_peer_id: request.hello.peer_id,
                joiner_display_name: request.display_name,
                joiner_public_key: request.public_key,
            },
        );
        self.send_control_handle(
            handle,
            BluetoothControlMessage::JoinResponse {
                payload: serde_json::to_vec(&response)?,
            },
            self.last_now_ms.saturating_add(120_000),
        )
    }

    fn on_join_response(&mut self, handle: PeerHandle, payload: &[u8]) -> Result<(), CoreError> {
        tracing::info!(subsystem = "groupAuth", ?handle, "received join response");
        let response: JoinResponsePayload = serde_json::from_slice(payload)?;
        let handshake = self
            .pending_joiner_handshake
            .take()
            .ok_or_else(|| CoreError::GroupAuth("unexpected join response".into()))?;
        let session = handshake
            .finish(&response.hello)
            .map_err(|error| CoreError::GroupAuth(error.to_string()))?;
        let confirmation =
            decode_fixed_binary::<32>(&response.confirmation, "inviter confirmation is malformed")?;
        if !session.confirms(b"inviter", &confirmation) {
            return Err(CoreError::GroupAuth(
                "the PIN transcript did not authenticate the inviter".into(),
            ));
        }
        let associated_data = admission_associated_data(
            &response.hello.group_id,
            response.hello.epoch,
            &self.state.identity.peer_id,
        );
        let sealed_credential = SealedMessage {
            nonce: decode_fixed_binary::<24>(
                &response.sealed_nonce,
                "admission nonce is malformed",
            )?,
            ciphertext: decode_binary(
                &response.sealed_credential,
                "admission credential is malformed",
            )?,
        };
        let credential_bytes = open(&session.key, &sealed_credential, &associated_data)
            .map_err(|error| CoreError::GroupAuth(error.to_string()))?;
        let credential: AdmissionCredential = serde_json::from_slice(&credential_bytes)?;
        if credential.group.epoch == 0
            || !credential
                .group
                .members
                .iter()
                .any(|member| member.peer_id == self.state.identity.peer_id && member.active)
        {
            return Err(CoreError::GroupAuth(
                "admission credential does not include this device".into(),
            ));
        }
        let group_key =
            decode_fixed_binary::<32>(&credential.group_key, "group credential key is malformed")?;
        self.state.group = Some(credential.group);
        self.state.processed_control_ids.clear();
        self.state.member_public_keys = credential
            .member_public_keys
            .into_iter()
            .map(|(peer, key)| {
                decode_fixed_binary::<32>(&key, "member public key is malformed")
                    .map(|bytes| (peer, bytes.to_vec()))
            })
            .collect::<Result<_, _>>()?;
        self.group_key = Some(group_key);
        self.bind_bluetooth_handle(handle, response.hello.peer_id.clone());
        let members = self
            .state
            .group
            .as_ref()
            .map_or_else(Vec::new, |group| group.members.clone());
        for member in members {
            self.ensure_peer(member.peer_id, member.display_name);
        }
        self.queue(
            "secureStorage",
            &SecureStorageCommand::Put {
                request_id: RequestId::new(),
                key: GROUP_KEY.into(),
                value: SecretValue(group_key.to_vec()),
            },
        )?;
        self.rebuild_replication()?;
        self.pending_join_pin = None;
        tracing::info!(
            subsystem = "groupAuth",
            ?handle,
            "PIN-authenticated admission completed"
        );
        self.send_control_handle(
            handle,
            BluetoothControlMessage::JoinConfirmation {
                payload: serde_json::to_vec(&JoinConfirmationPayload {
                    peer_id: self.state.identity.peer_id.clone(),
                    confirmation: session.confirmation(b"joiner").to_vec(),
                })?,
            },
            self.last_now_ms.saturating_add(120_000),
        )?;
        self.send_group_presence(handle)?;
        if self.state.is_traveling {
            self.start_transport_if_ready()?;
        }
        Ok(())
    }

    fn on_join_confirmation(
        &mut self,
        handle: PeerHandle,
        payload: &[u8],
    ) -> Result<(), CoreError> {
        let confirmation: JoinConfirmationPayload = serde_json::from_slice(payload)?;
        self.pending_invitations.remove(&handle);
        let pending = self
            .pending_inviter_admissions
            .remove(&handle)
            .ok_or_else(|| CoreError::GroupAuth("unexpected join confirmation".into()))?;
        if confirmation.peer_id != pending.joiner_peer_id {
            return Err(CoreError::GroupAuth(
                "join confirmation has the wrong peer identity".into(),
            ));
        }
        let confirmation_bytes: [u8; 32] = confirmation
            .confirmation
            .as_slice()
            .try_into()
            .map_err(|_| CoreError::GroupAuth("joiner confirmation is malformed".into()))?;
        if !pending.session.confirms(b"joiner", &confirmation_bytes) {
            return Err(CoreError::GroupAuth(
                "the joiner did not confirm the PIN transcript".into(),
            ));
        }
        let group = self.state.group.as_mut().ok_or(CoreError::NoActiveGroup)?;
        if !group
            .members
            .iter()
            .any(|member| member.peer_id == pending.joiner_peer_id)
        {
            group.members.push(MemberSnapshot {
                peer_id: pending.joiner_peer_id.clone(),
                display_name: pending.joiner_display_name.clone(),
                role: MemberRole::Member,
                active: true,
            });
        }
        group.invite_pin = Some(make_pin());
        self.state
            .member_public_keys
            .insert(pending.joiner_peer_id.clone(), pending.joiner_public_key);
        self.bind_bluetooth_handle(handle, pending.joiner_peer_id.clone());
        self.ensure_peer(pending.joiner_peer_id.clone(), pending.joiner_display_name);
        self.rebuild_replication()?;
        let mut shared_group = self.state.group.clone().ok_or(CoreError::NoActiveGroup)?;
        shared_group.invite_pin = None;
        self.publish(
            "group.member.admitted",
            serde_json::to_value(MembershipSnapshotPayload {
                group: shared_group,
                member_public_keys: self.state.member_public_keys.clone(),
            })?,
            GroupAudience::Group,
            DeliveryPolicy::Durable,
        )?;
        self.send_group_presence(handle)?;
        if self.state.is_traveling {
            self.start_transport_if_ready()?;
        }
        Ok(())
    }

    fn bind_bluetooth_handle(&mut self, handle: PeerHandle, peer_id: PeerId) {
        self.bluetooth_handles
            .retain(|candidate, candidate_handle| {
                candidate == &peer_id || *candidate_handle != handle
            });
        self.bluetooth_handles.insert(peer_id, handle);
    }

    fn send_control_handle(
        &mut self,
        handle: PeerHandle,
        message: BluetoothControlMessage,
        expires_at_ms: i64,
    ) -> Result<(), CoreError> {
        self.queue(
            "bluetooth",
            &BluetoothCommand::SendControl {
                request_id: RequestId::new(),
                handle,
                message,
                expires_at_ms,
            },
        )
    }

    fn on_transport(&mut self, event: TransportEvent) -> Result<(), CoreError> {
        match event {
            TransportEvent::Authenticated {
                peer_id,
                connection,
            } => {
                self.transport_connections
                    .insert(peer_id.clone(), connection);
                self.transport_peers.insert(connection, peer_id.clone());
                self.transport_decoders.entry(connection).or_default();
                self.set_peer_connected(&peer_id, true);
                let digest = self
                    .replication
                    .as_ref()
                    .map(ReplicationEngine::digest)
                    .transpose()?;
                if let Some(digest) = digest {
                    self.send_wire(
                        connection,
                        &WireMessage::SyncDigest {
                            protocol_version: PROTOCOL_VERSION,
                            digest,
                        },
                        TrafficClass::EnergyEfficient,
                    )?;
                }
                self.request_pending_resources(connection)?;
                match self.call.state().clone() {
                    CallState::Connecting {
                        call_id,
                        peer_id: call_peer,
                    } if call_peer == peer_id => {
                        self.call.transport_connected(self.last_now_ms)?;
                        self.queue(
                            "callSystem",
                            &CallSystemCommand::ActivateAudio {
                                request_id: RequestId::new(),
                                call_id,
                            },
                        )?;
                    }
                    CallState::Reconnecting {
                        peer_id: call_peer, ..
                    } if call_peer == peer_id => {
                        self.call.reconnect(self.last_now_ms)?;
                    }
                    _ => {}
                }
            }
            TransportEvent::Disconnected { connection, reason } => {
                if let Some(peer) = self.transport_peers.remove(&connection) {
                    self.transport_connections.remove(&peer);
                    self.set_peer_connected(&peer, false);
                    if call_peer(self.call.state()).as_ref() == Some(&peer)
                        && matches!(
                            self.call.state(),
                            CallState::Connecting { .. } | CallState::Active { .. }
                        )
                    {
                        self.call
                            .transport_lost(self.last_now_ms.saturating_add(10_000))?;
                    }
                }
                self.transport_decoders.remove(&connection);
                tracing::warn!(
                    subsystem = "peerTransport",
                    ?connection,
                    %reason,
                    "peer transport disconnected"
                );
            }
            TransportEvent::DataReceived { connection, bytes } => {
                let messages = self
                    .transport_decoders
                    .entry(connection)
                    .or_default()
                    .push(&bytes)?;
                for message in messages {
                    self.handle_wire_message(connection, message)?;
                }
            }
            TransportEvent::Failed { message, .. } => {
                tracing::error!(
                    subsystem = "peerTransport",
                    %message,
                    "peer transport failed"
                );
            }
            TransportEvent::DiscoveryStarted { .. }
            | TransportEvent::DiscoveryStopped { .. }
            | TransportEvent::PeerFound { .. }
            | TransportEvent::Sent { .. } => {}
        }
        Ok(())
    }

    fn handle_wire_message(
        &mut self,
        connection: ConnectionHandle,
        message: WireMessage,
    ) -> Result<(), CoreError> {
        if !self.transport_peers.contains_key(&connection) {
            return Err(CoreError::InvalidModuleEvent(
                "data arrived before the peer transport authenticated the group member".into(),
            ));
        }
        match message {
            WireMessage::SyncDigest { digest, .. } => {
                let events = self
                    .replication
                    .as_ref()
                    .ok_or(CoreError::NoActiveGroup)?
                    .events_missing_from(&digest)?;
                if !events.is_empty() {
                    self.send_wire(
                        connection,
                        &WireMessage::EventBatch {
                            protocol_version: PROTOCOL_VERSION,
                            request_id: RequestId::new(),
                            events,
                        },
                        TrafficClass::EnergyEfficient,
                    )?;
                }
            }
            WireMessage::RequestEvents { event_ids, .. } => {
                let replication = self.replication.as_ref().ok_or(CoreError::NoActiveGroup)?;
                let events = event_ids
                    .iter()
                    .map(|event_id| replication.event(event_id))
                    .collect::<Result<Vec<_>, _>>()?
                    .into_iter()
                    .flatten()
                    .collect::<Vec<_>>();
                if !events.is_empty() {
                    self.send_wire(
                        connection,
                        &WireMessage::EventBatch {
                            protocol_version: PROTOCOL_VERSION,
                            request_id: RequestId::new(),
                            events,
                        },
                        TrafficClass::EnergyEfficient,
                    )?;
                }
            }
            WireMessage::EventBatch { events, .. } => {
                let mut persisted = Vec::new();
                for signed in events {
                    let ingested = match self
                        .replication
                        .as_mut()
                        .ok_or(CoreError::NoActiveGroup)?
                        .ingest(&signed)
                    {
                        Ok(ingested) => ingested,
                        Err(error) => {
                            let has_registered_key = self
                                .state
                                .member_public_keys
                                .get(&signed.signer_id)
                                .is_some_and(|key| key.len() == 32);
                            tracing::error!(
                                subsystem = "replication",
                                signer = %signed.signer_id,
                                event_bytes = signed.event_bytes.len(),
                                signature_bytes = signed.signature.len(),
                                registered_key = has_registered_key,
                                %error,
                                "rejected replicated event"
                            );
                            return Err(CoreError::Replication(error));
                        }
                    };
                    let receipt = ingested.receipt;
                    let event = ingested.event;
                    persisted.push(event.id.clone());
                    if receipt.inserted {
                        self.materialize_event(&event)?;
                    }
                }
                if !persisted.is_empty() {
                    self.send_wire(
                        connection,
                        &WireMessage::PersistedAck {
                            protocol_version: PROTOCOL_VERSION,
                            receiver_id: self.state.identity.peer_id.clone(),
                            event_ids: persisted,
                        },
                        TrafficClass::EnergyEfficient,
                    )?;
                }
                self.request_pending_resources(connection)?;
            }
            WireMessage::PersistedAck {
                receiver_id,
                event_ids,
                ..
            } => {
                let replication = self.replication.as_mut().ok_or(CoreError::NoActiveGroup)?;
                for event_id in event_ids {
                    let target_persisted = replication
                        .event_metadata(&event_id)?
                        .is_some_and(|event| event.target_members.contains(&receiver_id));
                    replication.apply_receipt(&IngestReceipt {
                        event_id,
                        holder: receiver_id.clone(),
                        inserted: false,
                        target_persisted,
                    })?;
                }
            }
            WireMessage::ResourceRequest {
                request_id,
                resource_id,
                chunk_indices,
                ..
            } => self.send_resource_chunks(
                connection,
                request_id,
                ResourceId::from_string(resource_id),
                chunk_indices,
            )?,
            WireMessage::ResourceChunk {
                resource_id,
                chunk_index,
                bytes,
                ..
            } => self.receive_resource_chunk(
                ResourceId::from_string(resource_id),
                chunk_index,
                &bytes,
            )?,
            WireMessage::RealtimeFrame {
                stream_id,
                sequence,
                timestamp_ms,
                bytes,
                ..
            } => {
                let Some(peer) = self.transport_peers.get(&connection) else {
                    return Err(CoreError::InvalidModuleEvent(
                        "realtime frame arrived on an unknown connection".into(),
                    ));
                };
                let Some((call_id, call_peer_id)) = call_identity(self.call.state()) else {
                    return Ok(());
                };
                if &call_peer_id != peer || stream_id != call_id.to_string() {
                    return Ok(());
                }
                let audio: RealtimeAudioPayload = serde_json::from_slice(&bytes)?;
                self.queue(
                    "callSystem",
                    &CallSystemCommand::PlayAudio {
                        request_id: RequestId::new(),
                        call_id,
                        pcm16: audio.pcm16,
                        sample_rate: audio.sample_rate,
                        channel_count: audio.channel_count,
                        sequence,
                        timestamp_ms,
                    },
                )?;
            }
        }
        Ok(())
    }

    fn materialize_event(&mut self, event: &model::EventEnvelope) -> Result<(), CoreError> {
        match event.event_type.as_str() {
            "resource.manifest" => {
                let manifest: ResourceManifest = serde_json::from_value(event.payload.clone())?;
                let mut transfer = self.resource_store.begin(manifest.clone())?;
                let (transferred_bytes, _) = transfer.progress()?;
                let completed_path = transfer.completed_path()?;
                self.upsert_resource(ResourceSnapshot {
                    manifest,
                    local_path: completed_path
                        .as_ref()
                        .map(|path| path.to_string_lossy().into_owned()),
                    transferred_bytes,
                    status: if completed_path.is_some() {
                        ResourceTransferStatus::Available
                    } else {
                        ResourceTransferStatus::Pending
                    },
                    last_error: None,
                });
            }
            "group.member.admitted" => {
                let payload: MembershipSnapshotPayload =
                    serde_json::from_value(event.payload.clone())?;
                let Some(current) = self.state.group.as_mut() else {
                    return Ok(());
                };
                if current.id != payload.group.id || current.epoch != payload.group.epoch {
                    return Ok(());
                }
                current.name = payload.group.name;
                current.members = payload.group.members;
                self.state
                    .member_public_keys
                    .extend(payload.member_public_keys);
                let members = current.members.clone();
                for member in members {
                    self.ensure_peer(member.peer_id, member.display_name);
                }
                self.rebuild_replication()?;
            }
            "im.message.sent" => {
                #[derive(Deserialize)]
                #[serde(rename_all = "camelCase")]
                struct Payload {
                    message_id: EntityId,
                    conversation: Conversation,
                    content: MessageContent,
                    sent_at_ms: i64,
                }
                let payload: Payload = serde_json::from_value(event.payload.clone())?;
                let conversation_id = payload.conversation.stable_id();
                let index = self
                    .state
                    .conversations
                    .iter()
                    .position(|conversation| conversation.id == conversation_id)
                    .unwrap_or_else(|| {
                        self.state.conversations.push(ConversationSnapshot {
                            id: conversation_id,
                            conversation: payload.conversation.clone(),
                            messages: Vec::new(),
                        });
                        self.state.conversations.len() - 1
                    });
                if !self.state.conversations[index]
                    .messages
                    .iter()
                    .any(|message| message.publication_event_id == event.id)
                {
                    let delivery = self
                        .replication
                        .as_ref()
                        .ok_or(CoreError::NoActiveGroup)?
                        .delivery_state(&event.id, self.last_now_ms)?;
                    self.state.conversations[index]
                        .messages
                        .push(MessageSnapshot {
                            message_id: payload.message_id,
                            publication_event_id: event.id.clone(),
                            sender_id: event.sender_id.clone(),
                            content: payload.content,
                            sent_at_ms: payload.sent_at_ms,
                            delivery,
                        });
                    if !self.state.is_foreground {
                        self.queue(
                            "notifications",
                            &NotificationCommand::Schedule {
                                request_id: RequestId::new(),
                                identifier: event.id.to_string(),
                                title: self.peer_name(&event.sender_id),
                                body: "New offline travel message".into(),
                                deep_link: Some(format!(
                                    "travel-companion://conversation/{}",
                                    self.state.conversations[index].id
                                )),
                                merge_key: Some(format!(
                                    "messages/{}",
                                    self.state.conversations[index].id
                                )),
                                time_sensitive: false,
                            },
                        )?;
                    }
                }
            }
            "place.created" | "place.updated" => {
                let incoming: PlaceSnapshot = serde_json::from_value(event.payload.clone())?;
                if let Some(existing) = self
                    .state
                    .places
                    .iter_mut()
                    .find(|place| place.id == incoming.id)
                {
                    if incoming.updated_at_ms >= existing.updated_at_ms {
                        *existing = incoming;
                    }
                } else {
                    self.state.places.push(incoming);
                }
            }
            "place.deleted" => {
                #[derive(Deserialize)]
                #[serde(rename_all = "camelCase")]
                struct Payload {
                    place_id: EntityId,
                    deleted_at_ms: i64,
                }
                let payload: Payload = serde_json::from_value(event.payload.clone())?;
                if let Some(place) = self
                    .state
                    .places
                    .iter_mut()
                    .find(|place| place.id == payload.place_id)
                {
                    if payload.deleted_at_ms >= place.updated_at_ms {
                        place.deleted = true;
                        place.updated_at_ms = payload.deleted_at_ms;
                    }
                }
            }
            "document.revision.saved" => {
                let revision: DocumentRevision = serde_json::from_value(event.payload.clone())?;
                if self.document.insert_revision(revision.clone())? {
                    self.state.document_revisions.push(revision);
                }
            }
            "document.lease.acquired" => {
                let lease: EditorLease = serde_json::from_value(event.payload.clone())?;
                if !self
                    .state
                    .document_leases
                    .iter()
                    .any(|candidate| candidate.lease_id == lease.lease_id)
                {
                    self.document.apply_lease_event(&LeaseEvent::Acquired {
                        lease: lease.clone(),
                    })?;
                    self.state.document_leases.push(lease);
                }
            }
            "document.lease.released" => {
                let lease_event: LeaseEvent = serde_json::from_value(event.payload.clone())?;
                self.document.apply_lease_event(&lease_event)?;
                if let LeaseEvent::Released {
                    lease_id,
                    released_at_ms,
                    ..
                } = lease_event
                {
                    if let Some(lease) = self
                        .state
                        .document_leases
                        .iter_mut()
                        .find(|lease| lease.lease_id == lease_id)
                    {
                        lease.released_at_ms = Some(released_at_ms);
                    }
                }
            }
            "location.sample" => {
                let sample: LocationSample = serde_json::from_value(event.payload.clone())?;
                self.ensure_peer(event.sender_id.clone(), self.peer_name(&event.sender_id));
                if let Some(peer) = self
                    .state
                    .peers
                    .iter_mut()
                    .find(|peer| peer.peer_id == event.sender_id)
                {
                    if peer
                        .last_location
                        .as_ref()
                        .is_none_or(|current| sample.sampled_at_ms >= current.sampled_at_ms)
                    {
                        peer.last_location = Some(sample);
                    }
                }
            }
            _ => {}
        }
        Ok(())
    }

    fn on_location(&mut self, event: LocationEvent) -> Result<(), CoreError> {
        match event {
            LocationEvent::Sample {
                request_id, sample, ..
            } => {
                let local = self.state.identity.clone();
                self.ensure_peer(local.peer_id.clone(), local.display_name);
                if let Some(peer) = self
                    .state
                    .peers
                    .iter_mut()
                    .find(|peer| peer.peer_id == local.peer_id)
                {
                    peer.last_location = Some(sample.clone());
                }
                if self.state.is_traveling
                    && !self.state.sharing_paused
                    && self.state.group.is_some()
                {
                    let expires_at_ms = sample.sampled_at_ms.saturating_add(120_000);
                    self.publish(
                        "location.sample",
                        serde_json::to_value(&sample)?,
                        GroupAudience::Group,
                        DeliveryPolicy::LatestValue {
                            key: format!("{}/location", self.state.identity.peer_id),
                            expires_at_ms,
                        },
                    )?;
                }
                if let Some(request_id) = request_id {
                    if let Some(pending) = self.pending_location_replies.remove(&request_id) {
                        self.send_location_response(
                            pending.peer_id,
                            request_id,
                            pending.deadline_ms,
                            LocationResponseStatus::Fresh,
                            (!self.state.sharing_paused).then_some(sample),
                        )?;
                    }
                }
            }
            LocationEvent::TimedOut {
                request_id,
                stale_sample,
            } => {
                if let Some(pending) = self.pending_location_replies.remove(&request_id) {
                    let stale_sample = (!self.state.sharing_paused)
                        .then_some(stale_sample)
                        .flatten();
                    self.send_location_response(
                        pending.peer_id,
                        request_id,
                        pending.deadline_ms,
                        if self.state.sharing_paused {
                            LocationResponseStatus::Paused
                        } else if stale_sample.is_some() {
                            LocationResponseStatus::Stale
                        } else {
                            LocationResponseStatus::Timeout
                        },
                        stale_sample,
                    )?;
                }
                tracing::warn!(subsystem = "location", "location request timed out");
            }
            LocationEvent::Failed {
                request_id,
                message,
                ..
            } => {
                if let Some(request_id) = request_id {
                    if let Some(pending) = self.pending_location_replies.remove(&request_id) {
                        self.send_location_response(
                            pending.peer_id,
                            request_id,
                            pending.deadline_ms,
                            LocationResponseStatus::Timeout,
                            None,
                        )?;
                    }
                }
                tracing::error!(subsystem = "location", %message, "location backend failed");
            }
            LocationEvent::Started { .. }
            | LocationEvent::Stopped { .. }
            | LocationEvent::AuthorizationChanged { .. } => {}
        }
        Ok(())
    }

    fn on_ranging(&mut self, event: RangingEvent) -> Result<(), CoreError> {
        match event {
            RangingEvent::DiscoveryToken { request_id, token } => {
                if let Some(request) = self
                    .state
                    .pending_precision
                    .iter()
                    .find(|request| request.request_id == request_id)
                    .cloned()
                {
                    let peer = if request.requester_id == self.state.identity.peer_id {
                        request.target_id
                    } else {
                        request.requester_id
                    };
                    self.send_control(
                        peer,
                        "precisionDiscoveryToken",
                        serde_json::to_vec(&json!({
                            "requestId": request_id,
                            "token": token,
                        }))?,
                        request.expires_at_ms,
                    )?;
                }
            }
            RangingEvent::Measurement {
                peer_id,
                distance_m,
                direction_radians,
                observed_at_ms,
            } => {
                self.ensure_peer(peer_id.clone(), self.peer_name(&peer_id));
                if let Some(peer) = self
                    .state
                    .peers
                    .iter_mut()
                    .find(|peer| peer.peer_id == peer_id)
                {
                    peer.ranging = Some(UwbObservation {
                        distance_m,
                        direction_radians,
                        observed_at_ms,
                    });
                }
                for request in &mut self.state.pending_precision {
                    if request.target_id == peer_id || request.requester_id == peer_id {
                        request.status = PrecisionStatus::Active;
                    }
                }
            }
            RangingEvent::Suspended { peer_id, .. } | RangingEvent::Ended { peer_id, .. } => {
                if let Some(peer) = self
                    .state
                    .peers
                    .iter_mut()
                    .find(|peer| peer.peer_id == peer_id)
                {
                    peer.ranging = None;
                }
            }
            RangingEvent::Failed { message, .. } => {
                tracing::error!(subsystem = "ranging", %message, "ranging backend failed");
            }
            RangingEvent::Started { .. } => {}
        }
        Ok(())
    }

    fn on_notification(&mut self, event: NotificationEvent) -> Result<(), CoreError> {
        match event {
            NotificationEvent::Opened { identifier, .. } => {
                tracing::debug!(
                    subsystem = "notifications",
                    %identifier,
                    "notification opened"
                );
            }
            NotificationEvent::Failed { message, .. } => {
                tracing::error!(
                    subsystem = "notifications",
                    %message,
                    "notification backend failed"
                );
            }
            _ => {}
        }
        Ok(())
    }

    fn on_call_system(&mut self, event: CallSystemEvent) -> Result<(), CoreError> {
        match event {
            CallSystemEvent::UserAnswered { .. } => self.answer_call()?,
            CallSystemEvent::UserRejected { .. } => self.reject_call()?,
            CallSystemEvent::UserEnded { .. } => self.end_call()?,
            CallSystemEvent::AudioInterrupted {
                should_resume: false,
                ..
            } => self.end_call()?,
            CallSystemEvent::AudioFrame {
                call_id,
                pcm16,
                sample_rate,
                channel_count,
                sequence,
                timestamp_ms,
            } => {
                let Some((active_call_id, peer_id)) = call_identity(self.call.state()) else {
                    return Ok(());
                };
                if active_call_id != call_id {
                    return Ok(());
                }
                if let Some(connection) = self.transport_connections.get(&peer_id).copied() {
                    self.send_wire(
                        connection,
                        &WireMessage::RealtimeFrame {
                            protocol_version: PROTOCOL_VERSION,
                            stream_id: call_id.to_string(),
                            sequence,
                            timestamp_ms,
                            bytes: serde_json::to_vec(&RealtimeAudioPayload {
                                pcm16,
                                sample_rate,
                                channel_count,
                            })?,
                        },
                        TrafficClass::RealtimeVoice,
                    )?;
                }
            }
            CallSystemEvent::Failed { message, .. } => {
                tracing::error!(subsystem = "callSystem", %message, "call system failed");
            }
            _ => {}
        }
        Ok(())
    }

    fn on_secure_storage(&mut self, event: SecureStorageEvent) -> Result<(), CoreError> {
        match event {
            SecureStorageEvent::Loaded { key, value, .. } if key == IDENTITY_KEY => {
                let Some(value) = value else {
                    let secret = IdentityKeypair::generate().secret_bytes();
                    self.identity_secret = Some(secret);
                    self.state.member_public_keys.insert(
                        self.state.identity.peer_id.clone(),
                        IdentityKeypair::from_secret_bytes(&secret)
                            .public_key_bytes()
                            .to_vec(),
                    );
                    self.queue(
                        "secureStorage",
                        &SecureStorageCommand::Put {
                            request_id: RequestId::new(),
                            key: IDENTITY_KEY.into(),
                            value: SecretValue(secret.to_vec()),
                        },
                    )?;
                    self.state.identity.key_ready = true;
                    self.rebuild_replication()?;
                    return Ok(());
                };
                let bytes: [u8; 32] = value.0.as_slice().try_into().map_err(|_| {
                    CoreError::InvalidModuleEvent("identity key must be 32 bytes".into())
                })?;
                self.identity_secret = Some(bytes);
                self.state.identity.key_ready = true;
                self.state.member_public_keys.insert(
                    self.state.identity.peer_id.clone(),
                    IdentityKeypair::from_secret_bytes(&bytes)
                        .public_key_bytes()
                        .to_vec(),
                );
                self.rebuild_replication()?;
            }
            SecureStorageEvent::Loaded { key, value, .. } if key == GROUP_KEY => {
                self.group_key = value
                    .map(|value| {
                        value.0.as_slice().try_into().map_err(|_| {
                            CoreError::InvalidModuleEvent("group key must be 32 bytes".into())
                        })
                    })
                    .transpose()?;
                self.announce_group_presence()?;
                for handle in self.bluetooth_handles.values().copied().collect::<Vec<_>>() {
                    self.send_invitation_info(handle)?;
                }
                if self.state.is_traveling {
                    self.start_transport_if_ready()?;
                }
            }
            SecureStorageEvent::Loaded { key, value, .. } if key == TRANSPORT_CERTIFICATE_KEY => {
                self.transport_certificate_der = value.map(|value| value.0.clone());
                if self.transport_certificate_der.is_none() {
                    self.ensure_transport_identity()?;
                }
                if self.state.is_traveling {
                    self.start_transport_if_ready()?;
                }
            }
            SecureStorageEvent::Loaded { key, value, .. } if key == TRANSPORT_PRIVATE_KEY => {
                self.transport_private_key_pkcs8 = value.map(|value| value.0.clone());
                if self.transport_private_key_pkcs8.is_none() {
                    self.ensure_transport_identity()?;
                }
                if self.state.is_traveling {
                    self.start_transport_if_ready()?;
                }
            }
            SecureStorageEvent::Failed { message, .. } => {
                tracing::error!(
                    subsystem = "secureStorage",
                    %message,
                    "secure storage failed"
                );
            }
            _ => {}
        }
        Ok(())
    }

    fn publish(
        &mut self,
        event_type: &str,
        payload: Value,
        audience: GroupAudience,
        policy: DeliveryPolicy,
    ) -> Result<(EventId, DeliveryState), CoreError> {
        let should_hint = !matches!(&policy, DeliveryPolicy::Transient { .. });
        if self.state.group.is_none() {
            return Err(CoreError::NoActiveGroup);
        }
        self.require_identity()?;
        if self.replication.is_none() {
            self.rebuild_replication()?;
        }
        let replication = self
            .replication
            .as_mut()
            .ok_or(CoreError::IdentityUnavailable)?;
        let publication =
            replication.publish(event_type, payload, audience, policy, self.last_now_ms)?;
        let delivery = replication.delivery_state(&publication.event_id, self.last_now_ms)?;
        let event = replication
            .event(&publication.event_id)?
            .ok_or(CoreError::UnknownEntity)?;
        let event_id = publication.event_id;
        self.broadcast_wire(
            &WireMessage::EventBatch {
                protocol_version: PROTOCOL_VERSION,
                request_id: RequestId::new(),
                events: vec![event],
            },
            TrafficClass::EnergyEfficient,
        )?;
        if should_hint {
            self.queue_data_available_hints()?;
        }
        Ok((event_id, delivery))
    }

    fn send_wire(
        &mut self,
        connection: ConnectionHandle,
        message: &WireMessage,
        traffic_class: TrafficClass,
    ) -> Result<(), CoreError> {
        self.queue(
            "peerTransport",
            &TransportCommand::SendData {
                request_id: RequestId::new(),
                connection,
                bytes: encode_frame(message)?,
                traffic_class,
            },
        )
    }

    fn broadcast_wire(
        &mut self,
        message: &WireMessage,
        traffic_class: TrafficClass,
    ) -> Result<(), CoreError> {
        let connections = self
            .transport_connections
            .values()
            .copied()
            .collect::<Vec<_>>();
        for connection in connections {
            self.send_wire(connection, message, traffic_class)?;
        }
        Ok(())
    }

    fn publish_call_signal(
        &mut self,
        peer: &PeerId,
        signal: &CallSignal,
        ttl_ms: i64,
    ) -> Result<(), CoreError> {
        let expires_at_ms = self.last_now_ms.saturating_add(ttl_ms);
        self.publish(
            "call.signal",
            serde_json::to_value(signal)?,
            recipients(peer),
            DeliveryPolicy::Transient { expires_at_ms },
        )?;
        let kind = match signal {
            CallSignal::Offer { .. } => "callOffer",
            CallSignal::Answer { .. } => "callAnswer",
            CallSignal::Reject { .. } => "callReject",
            CallSignal::End { .. } => "callEnd",
        };
        self.send_control(
            peer.clone(),
            kind,
            serde_json::to_vec(signal)?,
            expires_at_ms,
        )
    }

    fn send_control(
        &mut self,
        peer: PeerId,
        kind: impl Into<String>,
        payload: Vec<u8>,
        expires_at_ms: i64,
    ) -> Result<(), CoreError> {
        let kind = kind.into();
        self.require_member(&peer)?;
        if let Some(handle) = self.bluetooth_handles.get(&peer).copied() {
            self.send_group_control_handle(handle, Some(peer), kind, payload, expires_at_ms)?;
        } else {
            self.pending_controls
                .entry(peer)
                .or_default()
                .push(PendingControl {
                    kind,
                    payload,
                    expires_at_ms,
                });
        }
        Ok(())
    }

    fn send_group_presence(&mut self, handle: PeerHandle) -> Result<(), CoreError> {
        if self.state.group.is_none() || self.group_key.is_none() {
            return Ok(());
        }
        self.send_group_control_handle(
            handle,
            None,
            "presence".into(),
            serde_json::to_vec(&json!({
                "displayName": self.state.identity.display_name,
            }))?,
            self.last_now_ms.saturating_add(60_000),
        )
    }

    fn announce_group_presence(&mut self) -> Result<(), CoreError> {
        let mut handles = self.bluetooth_handles.values().copied().collect::<Vec<_>>();
        handles.sort_by_key(|handle| handle.0);
        handles.dedup();
        for handle in handles {
            self.send_group_presence(handle)?;
        }
        Ok(())
    }

    fn send_group_control_handle(
        &mut self,
        handle: PeerHandle,
        recipient_id: Option<PeerId>,
        kind: String,
        payload: Vec<u8>,
        expires_at_ms: i64,
    ) -> Result<(), CoreError> {
        let group = self.state.group.as_ref().ok_or(CoreError::NoActiveGroup)?;
        let group_key = self
            .group_key
            .ok_or(CoreError::GroupCredentialUnavailable)?;
        let created_at_ms = self.last_now_ms;
        if expires_at_ms <= created_at_ms {
            return Ok(());
        }
        let inner = GroupControlPayload {
            group_id: group.id.clone(),
            group_epoch: group.epoch,
            sender_id: self.state.identity.peer_id.clone(),
            recipient_id,
            control_id: RequestId::new(),
            kind,
            payload,
        };
        let associated_data =
            group_control_associated_data(PROTOCOL_VERSION, created_at_ms, expires_at_ms);
        let envelope = GroupControlEnvelope {
            protocol_version: PROTOCOL_VERSION,
            created_at_ms,
            expires_at_ms,
            sealed: seal(
                &SecretKeyMaterial(group_key),
                &serde_json::to_vec(&inner)?,
                &associated_data,
            ),
        };
        self.send_control_handle(
            handle,
            BluetoothControlMessage::GroupControl {
                payload: serde_json::to_vec(&envelope)?,
            },
            expires_at_ms,
        )
    }

    fn queue_data_available_hints(&mut self) -> Result<(), CoreError> {
        let peers = self
            .group_members()
            .into_iter()
            .filter(|peer| peer != &self.state.identity.peer_id)
            .collect::<Vec<_>>();
        for peer in peers {
            self.send_control(
                peer,
                "dataAvailable",
                serde_json::to_vec(&json!({"generation": self.last_now_ms}))?,
                self.last_now_ms.saturating_add(30_000),
            )?;
        }
        Ok(())
    }

    fn ensure_transport_identity(&mut self) -> Result<(), CoreError> {
        if self.transport_certificate_der.is_some() && self.transport_private_key_pkcs8.is_some() {
            return Ok(());
        }
        let key_pair = rcgen::KeyPair::generate()
            .map_err(|error| CoreError::TransportIdentity(error.to_string()))?;
        let subject = format!("{}.travel-companion.local", self.state.identity.peer_id);
        let parameters = rcgen::CertificateParams::new(vec![subject])
            .map_err(|error| CoreError::TransportIdentity(error.to_string()))?;
        let certificate = parameters
            .self_signed(&key_pair)
            .map_err(|error| CoreError::TransportIdentity(error.to_string()))?;
        let certificate_der = certificate.der().to_vec();
        let private_key_pkcs8 = key_pair.serialize_der();
        self.transport_certificate_der = Some(certificate_der.clone());
        self.transport_private_key_pkcs8 = Some(private_key_pkcs8.clone());
        self.queue(
            "secureStorage",
            &SecureStorageCommand::Put {
                request_id: RequestId::new(),
                key: TRANSPORT_CERTIFICATE_KEY.into(),
                value: SecretValue(certificate_der),
            },
        )?;
        self.queue(
            "secureStorage",
            &SecureStorageCommand::Put {
                request_id: RequestId::new(),
                key: TRANSPORT_PRIVATE_KEY.into(),
                value: SecretValue(private_key_pkcs8),
            },
        )?;
        Ok(())
    }

    fn start_transport_if_ready(&mut self) -> Result<(), CoreError> {
        let (Some(group), Some(group_key), Some(certificate_der), Some(private_key_pkcs8)) = (
            self.state.group.as_ref(),
            self.group_key,
            self.transport_certificate_der.as_ref(),
            self.transport_private_key_pkcs8.as_ref(),
        ) else {
            return Ok(());
        };
        self.queue(
            "peerTransport",
            &TransportCommand::StartDiscovery {
                request_id: RequestId::new(),
                local_peer_id: self.state.identity.peer_id.clone(),
                group_id: group.id.clone(),
                display_name: self.state.identity.display_name.clone(),
                protocol_version: PROTOCOL_VERSION,
                group_key: group_key.to_vec(),
                certificate_der: certificate_der.clone(),
                private_key_pkcs8: private_key_pkcs8.clone(),
            },
        )?;
        Ok(())
    }

    fn rebuild_replication(&mut self) -> Result<(), CoreError> {
        let (Some(group), Some(secret)) = (&self.state.group, self.identity_secret) else {
            self.replication = None;
            return Ok(());
        };
        let members = group
            .members
            .iter()
            .filter(|member| member.active)
            .map(|member| member.peer_id.clone())
            .collect();
        let mut replication = ReplicationEngine::new(
            self.state.identity.peer_id.clone(),
            group.id.clone(),
            group.epoch,
            members,
            IdentityKeypair::from_secret_bytes(&secret),
            EventStore::open(&self.config.storage_path)?,
        );
        for (peer, bytes) in &self.state.member_public_keys {
            if let Ok(public_key) = <[u8; 32]>::try_from(bytes.as_slice()) {
                replication.register_peer_key(peer.clone(), public_key);
            }
        }
        self.replication = Some(replication);
        Ok(())
    }

    fn require_identity(&self) -> Result<(), CoreError> {
        if self.identity_secret.is_some() {
            Ok(())
        } else {
            Err(CoreError::IdentityUnavailable)
        }
    }

    fn require_member(&self, peer: &PeerId) -> Result<(), CoreError> {
        if self.group_members().contains(peer) && peer != &self.state.identity.peer_id {
            Ok(())
        } else {
            Err(CoreError::UnknownPeer)
        }
    }

    fn group_members(&self) -> BTreeSet<PeerId> {
        self.state
            .group
            .as_ref()
            .map_or_else(BTreeSet::new, |group| {
                group
                    .members
                    .iter()
                    .filter(|member| member.active)
                    .map(|member| member.peer_id.clone())
                    .collect()
            })
    }

    fn ensure_peer(&mut self, peer_id: PeerId, display_name: String) {
        if !self.state.peers.iter().any(|peer| peer.peer_id == peer_id) {
            self.state.peers.push(PeerSnapshot {
                peer_id,
                display_name,
                connected: false,
                last_location: None,
                ranging: None,
            });
        }
    }

    fn set_peer_connected(&mut self, peer_id: &PeerId, connected: bool) {
        if let Some(peer) = self
            .state
            .peers
            .iter_mut()
            .find(|peer| &peer.peer_id == peer_id)
        {
            peer.connected = connected;
        }
    }

    fn peer_name(&self, peer_id: &PeerId) -> String {
        self.state
            .peers
            .iter()
            .find(|peer| &peer.peer_id == peer_id)
            .map_or_else(|| peer_id.to_string(), |peer| peer.display_name.clone())
    }

    fn blockers(&self) -> Vec<CapabilityBlocker> {
        let mut blockers = Vec::new();
        if self.identity_secret.is_none() {
            blockers.push(CapabilityBlocker {
                code: "identityKeyUnavailable".into(),
                message: "Waiting for the device identity key from secure storage".into(),
            });
        }
        if self.state.group.is_some() && self.group_key.is_none() {
            blockers.push(CapabilityBlocker {
                code: "groupCredentialUnavailable".into(),
                message: "Waiting for the active group credential from secure storage".into(),
            });
        }
        if self.transport_certificate_der.is_none() || self.transport_private_key_pkcs8.is_none() {
            blockers.push(CapabilityBlocker {
                code: "transportIdentityUnavailable".into(),
                message: "Preparing this installation's private peer-to-peer TLS identity".into(),
            });
        }
        if self.state.is_traveling && self.state.group.is_none() {
            blockers.push(CapabilityBlocker {
                code: "noActiveGroup".into(),
                message: "Create or join a travel group".into(),
            });
        }
        blockers
    }

    fn expire_precision(&mut self) {
        for request in &mut self.state.pending_precision {
            if self.last_now_ms >= request.expires_at_ms
                && matches!(
                    request.status,
                    PrecisionStatus::Pending | PrecisionStatus::Accepted
                )
            {
                request.status = PrecisionStatus::Expired;
            }
        }
    }

    fn queue<T: Serialize>(&mut self, module: &str, command: &T) -> Result<(), CoreError> {
        match module {
            "bluetooth" | "peerTransport" | "location" | "ranging" | "notifications"
            | "callSystem" | "secureStorage" => {}
            other => {
                return Err(CoreError::InvalidModuleEvent(format!(
                    "unknown module {other}"
                )))
            }
        }
        self.module_commands.push_back(ModuleCommandEnvelope {
            module: module.into(),
            command: serde_json::to_value(command)?,
        });
        Ok(())
    }

    fn persist(&mut self) -> Result<(), CoreError> {
        self.state_store.save_state(STATE_KEY, &self.state)?;
        Ok(())
    }
}

fn decode_module_event<T>(module: &str, value: Value) -> Result<T, CoreError>
where
    T: for<'de> Deserialize<'de>,
{
    serde_json::from_value(value).map_err(|error| {
        CoreError::InvalidModuleEvent(format!("{module} semantic event is invalid: {error}"))
    })
}

fn command_now(command: &AppCommand) -> i64 {
    match command {
        AppCommand::StartTravel { now_ms }
        | AppCommand::EndTravel { now_ms }
        | AppCommand::CreateGroup { now_ms, .. }
        | AppCommand::JoinWithPin { now_ms, .. }
        | AppCommand::LeaveGroup { now_ms }
        | AppCommand::SetSharingPaused { now_ms, .. }
        | AppCommand::RequestPrecision { now_ms, .. }
        | AppCommand::RespondPrecision { now_ms, .. }
        | AppCommand::SendText { now_ms, .. }
        | AppCommand::RegisterMedia { now_ms, .. }
        | AppCommand::CancelResource { now_ms, .. }
        | AppCommand::RetryResource { now_ms, .. }
        | AppCommand::CreatePlace { now_ms, .. }
        | AppCommand::UpdatePlace { now_ms, .. }
        | AppCommand::DeletePlace { now_ms, .. }
        | AppCommand::AcquireDocumentLease { now_ms, .. }
        | AppCommand::SaveDocument { now_ms, .. }
        | AppCommand::ReleaseDocumentLease { now_ms, .. }
        | AppCommand::StartCall { now_ms, .. }
        | AppCommand::AnswerCall { now_ms }
        | AppCommand::RejectCall { now_ms }
        | AppCommand::EndCall { now_ms }
        | AppCommand::SetForeground { now_ms, .. } => *now_ms,
        AppCommand::ClearTripData { now_ms } => *now_ms,
    }
}

fn recipients(peer: &PeerId) -> GroupAudience {
    GroupAudience::Recipients {
        members: [peer.clone()].into_iter().collect(),
    }
}

fn admission_associated_data(group_id: &GroupId, epoch: u64, joiner: &PeerId) -> Vec<u8> {
    format!("tc/admission/{group_id}/{epoch}/{joiner}").into_bytes()
}

fn encode_binary(bytes: &[u8]) -> String {
    STANDARD_NO_PAD.encode(bytes)
}

fn decode_binary(value: &str, malformed: &str) -> Result<Vec<u8>, CoreError> {
    STANDARD_NO_PAD
        .decode(value)
        .map_err(|_| CoreError::GroupAuth(malformed.into()))
}

fn decode_fixed_binary<const SIZE: usize>(
    value: &str,
    malformed: &str,
) -> Result<[u8; SIZE], CoreError> {
    decode_binary(value, malformed)?
        .try_into()
        .map_err(|_| CoreError::GroupAuth(malformed.into()))
}

fn group_control_associated_data(
    protocol_version: u16,
    created_at_ms: i64,
    expires_at_ms: i64,
) -> Vec<u8> {
    format!("tc/ble-control/{protocol_version}/{created_at_ms}/{expires_at_ms}").into_bytes()
}

fn make_pin() -> String {
    let id = RequestId::new();
    let number = id.as_str().bytes().fold(0_u32, |accumulator, byte| {
        accumulator.wrapping_mul(33).wrapping_add(u32::from(byte))
    }) % 1_000_000;
    format!("{number:06}")
}

fn call_peer(state: &CallState) -> Option<PeerId> {
    match state {
        CallState::Outgoing { peer_id, .. }
        | CallState::Incoming { peer_id, .. }
        | CallState::Connecting { peer_id, .. }
        | CallState::Active { peer_id, .. }
        | CallState::Reconnecting { peer_id, .. } => Some(peer_id.clone()),
        CallState::Idle | CallState::Ended { .. } => None,
    }
}

fn call_identity(state: &CallState) -> Option<(CallId, PeerId)> {
    match state {
        CallState::Outgoing {
            call_id, peer_id, ..
        }
        | CallState::Incoming {
            call_id, peer_id, ..
        }
        | CallState::Connecting { call_id, peer_id }
        | CallState::Active {
            call_id, peer_id, ..
        }
        | CallState::Reconnecting {
            call_id, peer_id, ..
        } => Some((call_id.clone(), peer_id.clone())),
        CallState::Idle | CallState::Ended { .. } => None,
    }
}

fn call_id_from_signal(signal: &CallSignal) -> &CallId {
    match signal {
        CallSignal::Offer { call_id, .. }
        | CallSignal::Answer { call_id }
        | CallSignal::Reject { call_id, .. }
        | CallSignal::End { call_id, .. } => call_id,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn core() -> TravelCore {
        let directory = tempdir().unwrap().keep();
        TravelCore::new(CoreConfig {
            storage_path: directory.join("core.sqlite3").display().to_string(),
            resources_path: directory.join("resources").display().to_string(),
            display_name: "Alice".into(),
        })
        .unwrap()
    }

    #[test]
    fn m1_to_m5_local_commands_close_the_loop() {
        let mut core = core();
        core.dispatch(AppCommand::CreateGroup {
            name: "Nanjing".into(),
            now_ms: 1,
        })
        .unwrap();
        core.dispatch(AppCommand::StartTravel { now_ms: 2 })
            .unwrap();
        core.dispatch(AppCommand::SendText {
            conversation: Conversation::Group,
            text: "meet at the gate".into(),
            now_ms: 3,
        })
        .unwrap();
        core.dispatch(AppCommand::CreatePlace {
            title: "Gate".into(),
            note: "North".into(),
            latitude: 32.0,
            longitude: 118.0,
            now_ms: 4,
        })
        .unwrap();
        core.dispatch(AppCommand::AcquireDocumentLease {
            duration_ms: 30_000,
            now_ms: 5,
        })
        .unwrap();
        core.dispatch(AppCommand::SaveDocument {
            markdown: "# Nanjing".into(),
            parent: None,
            now_ms: 6,
        })
        .unwrap();
        let snapshot = core.snapshot().unwrap();
        assert!(snapshot.lifecycle.is_traveling);
        assert_eq!(snapshot.conversations[0].messages.len(), 1);
        assert_eq!(snapshot.places.len(), 1);
        assert_eq!(snapshot.document.content, "# Nanjing");
        assert!(!core.drain_module_commands().is_empty());
    }

    #[test]
    fn snapshot_state_survives_core_restart_while_key_restores_async() {
        let directory = tempdir().unwrap();
        let config = CoreConfig {
            storage_path: directory.path().join("core.sqlite3").display().to_string(),
            resources_path: directory.path().join("resources").display().to_string(),
            display_name: "Alice".into(),
        };
        let peer_id = {
            let mut first = TravelCore::new(config.clone()).unwrap();
            first
                .dispatch(AppCommand::CreateGroup {
                    name: "Trip".into(),
                    now_ms: 1,
                })
                .unwrap();
            first.snapshot().unwrap().identity.peer_id
        };
        let mut second = TravelCore::new(config).unwrap();
        let snapshot = second.snapshot().unwrap();
        assert_eq!(snapshot.identity.peer_id, peer_id);
        assert_eq!(snapshot.group.unwrap().name, "Trip");
        assert!(!snapshot.identity.key_ready);
        assert!(second
            .blockers()
            .iter()
            .any(|blocker| blocker.code == "identityKeyUnavailable"));
        assert!(second.drain_module_commands().iter().any(|command| {
            command.module == "bluetooth"
                && command
                    .command
                    .get("kind")
                    .and_then(serde_json::Value::as_str)
                    == Some("start")
        }));
    }

    #[test]
    fn creating_group_immediately_opens_ble_admission() {
        let mut core = core();
        core.drain_module_commands();

        core.dispatch(AppCommand::CreateGroup {
            name: "Trip".into(),
            now_ms: 1,
        })
        .unwrap();

        let commands = core.drain_module_commands();
        assert!(commands.iter().any(|command| {
            command.module == "bluetooth"
                && command
                    .command
                    .get("kind")
                    .and_then(serde_json::Value::as_str)
                    == Some("start")
        }));
    }

    #[test]
    fn joining_device_ignores_group_control_received_before_admission() {
        let mut core = core();
        core.drain_module_commands();
        core.dispatch(AppCommand::JoinWithPin {
            pin: "123456".into(),
            now_ms: 1,
        })
        .unwrap();
        core.drain_module_commands();

        let handle = PeerHandle(1);
        let snapshot = core
            .ingest_module_event_at(
                ModuleEventEnvelope {
                    module: "bluetooth".into(),
                    event: serde_json::to_value(BluetoothEvent::Connected {
                        request_id: RequestId::new(),
                        handle,
                        max_packet_bytes: 180,
                    })
                    .unwrap(),
                },
                2,
            )
            .unwrap();
        assert!(snapshot.group.is_none());
        assert!(snapshot.lifecycle.last_error.is_none());

        let associated_data = group_control_associated_data(PROTOCOL_VERSION, 2, 60_000);
        let envelope = GroupControlEnvelope {
            protocol_version: PROTOCOL_VERSION,
            created_at_ms: 2,
            expires_at_ms: 60_000,
            sealed: seal(
                &SecretKeyMaterial::random(),
                b"control encrypted for an already admitted group",
                &associated_data,
            ),
        };
        let snapshot = core
            .ingest_module_event_at(
                ModuleEventEnvelope {
                    module: "bluetooth".into(),
                    event: serde_json::to_value(BluetoothEvent::ControlReceived {
                        handle,
                        message: BluetoothControlMessage::GroupControl {
                            payload: serde_json::to_vec(&envelope).unwrap(),
                        },
                    })
                    .unwrap(),
                },
                3,
            )
            .unwrap();

        assert!(snapshot.group.is_none());
        assert!(snapshot.lifecycle.last_error.is_none());
        assert_eq!(core.pending_join_pin.as_deref(), Some("123456"));
    }

    #[test]
    fn compact_admission_response_fits_ble_control_limit_for_eight_members() {
        let members = (0_u8..8)
            .map(|index| MemberSnapshot {
                peer_id: PeerId::new(),
                display_name: format!("Member {index}"),
                role: if index == 0 {
                    MemberRole::Owner
                } else {
                    MemberRole::Member
                },
                active: true,
            })
            .collect::<Vec<_>>();
        let member_public_keys = members
            .iter()
            .enumerate()
            .map(|(index, member)| {
                (
                    member.peer_id.clone(),
                    encode_binary(&[u8::try_from(index).unwrap(); 32]),
                )
            })
            .collect();
        let credential = AdmissionCredential {
            group: GroupSnapshot {
                id: GroupId::new(),
                name: "Eight person trip".into(),
                epoch: 1,
                invite_pin: None,
                members,
            },
            member_public_keys,
            group_key: encode_binary(&[9; 32]),
        };
        let sealed = seal(
            &SecretKeyMaterial::random(),
            &serde_json::to_vec(&credential).unwrap(),
            b"test admission",
        );
        let response = JoinResponsePayload {
            hello: JoinHello {
                group_id: GroupId::new(),
                epoch: 1,
                peer_id: PeerId::new(),
                spake_message: vec![3; 32],
            },
            confirmation: encode_binary(&[4; 32]),
            sealed_nonce: encode_binary(&sealed.nonce),
            sealed_credential: encode_binary(&sealed.ciphertext),
        };

        let encoded = serde_json::to_vec(&response).unwrap();
        assert!(
            encoded.len() <= protocol::BLUETOOTH_MAX_CONTROL_PAYLOAD_BYTES,
            "compact admission response is {} bytes",
            encoded.len()
        );
    }

    #[test]
    fn module_outbox_contains_only_semantic_commands() {
        let mut core = core();
        core.dispatch(AppCommand::StartTravel { now_ms: 10 })
            .unwrap();
        for envelope in core.drain_module_commands() {
            assert!(
                envelope.command.get("kind").is_some(),
                "{} emitted an invalid semantic command: {}",
                envelope.module,
                envelope.command
            );
            assert!(envelope.command.get("type").is_none());
        }
    }

    #[test]
    fn registered_media_is_content_addressed_and_recovers_after_restart() {
        let directory = tempdir().unwrap();
        let source = directory.path().join("voice.aac");
        std::fs::write(&source, b"offline voice payload").unwrap();
        let config = CoreConfig {
            storage_path: directory.path().join("core.sqlite3").display().to_string(),
            resources_path: directory.path().join("resources").display().to_string(),
            display_name: "Alice".into(),
        };
        let resource_id = ResourceId::from("voice-1");
        {
            let mut first = TravelCore::new(config.clone()).unwrap();
            first
                .dispatch(AppCommand::CreateGroup {
                    name: "Trip".into(),
                    now_ms: 1,
                })
                .unwrap();
            first
                .dispatch(AppCommand::RegisterMedia {
                    conversation: Conversation::Group,
                    media_kind: MediaKind::Voice,
                    resource_id: resource_id.clone(),
                    thumbnail_resource_id: None,
                    mime_type: "audio/aac".into(),
                    duration_ms: Some(900),
                    source_path: Some(source.display().to_string()),
                    now_ms: 2,
                })
                .unwrap();
            let snapshot = first.snapshot().unwrap();
            assert_eq!(snapshot.resources.len(), 1);
            assert_eq!(
                snapshot.resources[0].status,
                ResourceTransferStatus::Available
            );
            let stored = snapshot.resources[0].local_path.as_ref().unwrap();
            assert_ne!(stored, &source.display().to_string());
            assert_eq!(std::fs::read(stored).unwrap(), b"offline voice payload");
            assert_eq!(snapshot.conversations[0].messages.len(), 1);
        }

        let second = TravelCore::new(config).unwrap();
        let resource = second
            .snapshot()
            .unwrap()
            .resources
            .into_iter()
            .find(|resource| resource.manifest.resource_id == resource_id)
            .unwrap();
        assert_eq!(resource.status, ResourceTransferStatus::Available);
        assert_eq!(
            std::fs::read(resource.local_path.unwrap()).unwrap(),
            b"offline voice payload"
        );
    }

    #[test]
    fn fresh_ble_location_request_returns_cached_sample_without_new_gps_fix() {
        let mut core = core();
        core.dispatch(AppCommand::CreateGroup {
            name: "Trip".into(),
            now_ms: 1_000,
        })
        .unwrap();
        let peer = PeerId::new();
        core.state
            .group
            .as_mut()
            .unwrap()
            .members
            .push(MemberSnapshot {
                peer_id: peer.clone(),
                display_name: "Bob".into(),
                role: MemberRole::Member,
                active: true,
            });
        core.ensure_peer(peer.clone(), "Bob".into());
        core.bluetooth_handles.insert(peer.clone(), PeerHandle(7));
        let local = core.state.identity.clone();
        core.ensure_peer(local.peer_id.clone(), local.display_name);
        core.state
            .peers
            .iter_mut()
            .find(|candidate| candidate.peer_id == local.peer_id)
            .unwrap()
            .last_location = Some(LocationSample {
            latitude: 32.0,
            longitude: 118.0,
            altitude_m: None,
            horizontal_accuracy_m: 5.0,
            speed_mps: None,
            course_degrees: None,
            sampled_at_ms: 1_000,
        });
        core.drain_module_commands();

        core.handle_location_request(
            peer,
            LocationRequestPayload {
                request_id: RequestId::from("location-request"),
                requester_id: core
                    .state
                    .group
                    .as_ref()
                    .unwrap()
                    .members
                    .last()
                    .unwrap()
                    .peer_id
                    .clone(),
                created_at_ms: 1_100,
                desired_freshness_ms: 500,
                deadline_ms: 2_000,
            },
        )
        .unwrap();
        let commands = core.drain_module_commands();
        let command = commands
            .iter()
            .find(|command| command.module == "bluetooth")
            .unwrap();
        let command: BluetoothCommand = serde_json::from_value(command.command.clone()).unwrap();
        let BluetoothCommand::SendControl { message, .. } = command else {
            panic!("expected semantic send-control command")
        };
        let BluetoothControlMessage::GroupControl { payload } = message else {
            panic!("expected typed group-control message")
        };
        let envelope: GroupControlEnvelope = serde_json::from_slice(&payload).unwrap();
        let plaintext = open(
            &SecretKeyMaterial(core.group_key.unwrap()),
            &envelope.sealed,
            &group_control_associated_data(
                envelope.protocol_version,
                envelope.created_at_ms,
                envelope.expires_at_ms,
            ),
        )
        .unwrap();
        let control: GroupControlPayload = serde_json::from_slice(&plaintext).unwrap();
        assert_eq!(control.kind, "locationResponse");
        let response = control.payload;
        let response: LocationResponsePayload = serde_json::from_slice(&response).unwrap();
        assert!(matches!(response.status, LocationResponseStatus::Fresh));
        assert_eq!(response.sample.unwrap().sampled_at_ms, 1_000);
    }
}
