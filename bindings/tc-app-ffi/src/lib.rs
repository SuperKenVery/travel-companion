//! Panic-safe UniFFI boundary used by the SwiftUI application.
//!
//! `tc-core` deliberately exposes platform-neutral domain models. This crate is
//! the GUI adapter: it accepts the compact command vocabulary emitted by Swift,
//! supplies runtime-only values (timestamps and generated resource identifiers),
//! and projects the domain snapshot into the stable schema consumed by the app.

uniffi::setup_scaffolding!();
tc_bluetooth::uniffi_reexport_scaffolding!();
tc_call_system::uniffi_reexport_scaffolding!();
tc_location::uniffi_reexport_scaffolding!();
tc_notifications::uniffi_reexport_scaffolding!();
tc_peer_transport::uniffi_reexport_scaffolding!();
tc_ranging::uniffi_reexport_scaffolding!();
tc_secure_storage::uniffi_reexport_scaffolding!();

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};
use tc_core::{AppCommand, CoreConfig, TravelCore};
use tc_location_logic::{
    relative_location, FusionPolicy, RelativeLocation, RelativeSource, UwbObservation,
};
use tc_model::LocationSample;

mod uniffi_api;
pub use uniffi_api::{CoreEventListener, TravelCoreBinding, TravelCoreBindingError};

const PROTOCOL_VERSION: u16 = 1;
const PRECISION_REQUEST_TTL_MS: i64 = 60_000;
const DOCUMENT_LEASE_DURATION_MS: i64 = 120_000;

static RESOURCE_SEQUENCE: AtomicU64 = AtomicU64::new(1);

struct BindingCore {
    core: TravelCore,
    revision: u64,
    resources: BTreeMap<String, LocalResource>,
}

#[derive(Clone, Debug)]
struct LocalResource {
    path: String,
    mime_type: String,
    byte_count: u64,
    state: String,
}

#[derive(Debug, Deserialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "type"
)]
enum GuiCommand {
    StartTravel,
    EndTravel,
    CreateGroup {
        name: String,
    },
    JoinGroup {
        pin: String,
    },
    LeaveGroup,
    SetLocationSharing {
        enabled: bool,
    },
    RequestPrecision {
        #[serde(rename = "peerID")]
        peer_id: String,
    },
    RespondPrecision {
        #[serde(rename = "requestID")]
        request_id: String,
        accept: bool,
    },
    SendText {
        #[serde(rename = "conversationID")]
        conversation_id: String,
        body: String,
    },
    RegisterMedia {
        kind: GuiMediaKind,
        path: String,
        #[serde(rename = "conversationID")]
        conversation_id: String,
    },
    CancelResource {
        id: String,
    },
    RetryResource {
        id: String,
    },
    CreatePlace {
        title: String,
        note: String,
        latitude: f64,
        longitude: f64,
    },
    UpdatePlace {
        id: String,
        title: String,
        note: String,
        latitude: f64,
        longitude: f64,
    },
    DeletePlace {
        id: String,
    },
    AcquireDocumentLease,
    SaveDocument {
        content: String,
        #[serde(rename = "parentRevisionID")]
        parent_revision_id: Option<String>,
    },
    ReleaseDocumentLease,
    StartCall {
        #[serde(rename = "peerID")]
        peer_id: String,
    },
    AnswerCall {
        #[serde(rename = "callID")]
        call_id: String,
    },
    RejectCall {
        #[serde(rename = "callID")]
        call_id: String,
    },
    EndCall {
        #[serde(rename = "callID")]
        call_id: String,
    },
    SetForeground {
        foreground: bool,
    },
    ClearTripData,
}

#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
enum GuiMediaKind {
    Image,
    Voice,
}

enum BindingEffect {
    None,
    InsertResource { id: String, resource: LocalResource },
    SetResourceState { id: String, state: String },
    ClearResources,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InternalSnapshot {
    lifecycle: InternalLifecycle,
    identity: InternalIdentity,
    group: Option<InternalGroup>,
    #[serde(default)]
    peers: Vec<InternalPeer>,
    #[serde(default)]
    conversations: Vec<InternalConversation>,
    #[serde(default)]
    resources: Vec<InternalResource>,
    #[serde(default)]
    places: Vec<InternalPlace>,
    document: InternalDocument,
    active_call: Option<Value>,
    #[serde(default)]
    pending_precision: Vec<InternalPrecisionRequest>,
    diagnostics: InternalDiagnostics,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InternalLifecycle {
    is_traveling: bool,
    sharing_paused: bool,
    is_foreground: bool,
    #[serde(default)]
    blockers: Vec<InternalBlocker>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InternalBlocker {
    code: String,
    message: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InternalIdentity {
    peer_id: String,
    display_name: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InternalGroup {
    id: String,
    name: String,
    epoch: u64,
    invite_pin: Option<String>,
    #[serde(default)]
    members: Vec<InternalMember>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InternalMember {
    peer_id: String,
    display_name: String,
    role: String,
    active: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InternalPeer {
    peer_id: String,
    display_name: String,
    connected: bool,
    last_location: Option<InternalLocation>,
    ranging: Option<InternalRanging>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InternalLocation {
    latitude: f64,
    longitude: f64,
    altitude_m: Option<f64>,
    horizontal_accuracy_m: f64,
    speed_mps: Option<f64>,
    course_degrees: Option<f64>,
    sampled_at_ms: i64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InternalRanging {
    distance_m: Option<f64>,
    direction_radians: Option<f64>,
    observed_at_ms: i64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InternalConversation {
    id: String,
    conversation: Value,
    #[serde(default)]
    messages: Vec<InternalMessage>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InternalMessage {
    message_id: String,
    sender_id: String,
    content: Value,
    sent_at_ms: i64,
    delivery: InternalDelivery,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InternalResource {
    manifest: InternalResourceManifest,
    local_path: Option<String>,
    transferred_bytes: u64,
    status: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InternalResourceManifest {
    resource_id: String,
    byte_size: u64,
    mime_type: String,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InternalDelivery {
    #[serde(default)]
    phase: String,
    #[serde(default)]
    relay_count: usize,
    #[serde(default)]
    delivered_members: BTreeSet<String>,
    #[serde(default)]
    pending_members: BTreeSet<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InternalPlace {
    id: String,
    title: String,
    note: String,
    latitude: f64,
    longitude: f64,
    author_id: String,
    created_at_ms: i64,
    updated_at_ms: i64,
    deleted: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InternalDocument {
    #[serde(default)]
    content: String,
    head: Option<String>,
    lease: Option<InternalLease>,
    #[serde(default)]
    conflicts: Vec<InternalRevision>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InternalLease {
    lease_id: String,
    holder_id: String,
    expires_at_ms: i64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InternalRevision {
    revision_id: String,
    author_id: String,
    created_at_ms: i64,
    markdown: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InternalPrecisionRequest {
    request_id: String,
    requester_id: String,
    target_id: String,
    created_at_ms: i64,
    expires_at_ms: i64,
    status: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InternalDiagnostics {
    #[serde(default)]
    entries: Vec<InternalDiagnosticEntry>,
    last_error: Option<String>,
    #[serde(default)]
    pending_module_commands: usize,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InternalDiagnosticEntry {
    timestamp_ms: i64,
    category: String,
    message: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GuiSnapshot {
    protocol_version: u16,
    revision: u64,
    lifecycle: GuiLifecycle,
    identity: GuiIdentity,
    group: Option<GuiGroup>,
    peers: Vec<GuiPeer>,
    conversations: Vec<GuiConversation>,
    places: Vec<GuiPlace>,
    document: GuiDocument,
    active_call: Option<GuiCall>,
    pending_precision_requests: Vec<GuiPrecisionRequest>,
    diagnostics: GuiDiagnostics,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GuiLifecycle {
    is_traveling: bool,
    is_foreground: bool,
    location_sharing_enabled: bool,
    phase: String,
    blockers: Vec<GuiBlocker>,
    last_error: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GuiBlocker {
    capability: String,
    reason: String,
    recovery_suggestion: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GuiIdentity {
    #[serde(rename = "peerID")]
    peer_id: String,
    display_name: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GuiGroup {
    id: String,
    name: String,
    epoch: u64,
    #[serde(rename = "ownerID")]
    owner_id: String,
    #[serde(rename = "invitePIN")]
    invite_pin: Option<String>,
    members: Vec<GuiMember>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GuiMember {
    id: String,
    display_name: String,
    role: String,
    is_reachable: bool,
    last_seen_at: Option<i64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GuiPeer {
    id: String,
    display_name: String,
    is_reachable: bool,
    last_seen_at: Option<i64>,
    location: Option<GuiLocation>,
    ranging: Option<GuiRanging>,
    location_sharing_paused: bool,
    precision_state: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GuiLocation {
    latitude: f64,
    longitude: f64,
    altitude_meters: Option<f64>,
    horizontal_accuracy_meters: f64,
    speed_meters_per_second: Option<f64>,
    course_degrees: Option<f64>,
    sampled_at: i64,
    received_at: i64,
    is_stale: bool,
    distance_meters: Option<f64>,
    bearing_degrees: Option<f64>,
    source: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GuiRanging {
    distance_meters: Option<f64>,
    direction_degrees: Option<f64>,
    distance_source: String,
    direction_source: String,
    updated_at: i64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GuiConversation {
    id: String,
    title: String,
    kind: String,
    #[serde(rename = "participantIDs")]
    participant_ids: Vec<String>,
    unread_count: usize,
    messages: Vec<GuiMessage>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GuiMessage {
    id: String,
    #[serde(rename = "senderID")]
    sender_id: String,
    sender_name: String,
    kind: String,
    text: Option<String>,
    resource: Option<GuiResource>,
    created_at: i64,
    is_outgoing: bool,
    delivery: GuiDelivery,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GuiResource {
    id: String,
    mime_type: String,
    local_path: Option<String>,
    byte_count: u64,
    transferred_bytes: u64,
    state: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GuiDelivery {
    phase: String,
    relay_count: usize,
    #[serde(rename = "deliveredMemberIDs")]
    delivered_member_ids: Vec<String>,
    #[serde(rename = "targetMemberIDs")]
    target_member_ids: Vec<String>,
    error: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GuiPlace {
    id: String,
    title: String,
    note: String,
    latitude: f64,
    longitude: f64,
    #[serde(rename = "authorID")]
    author_id: String,
    author_name: String,
    created_at: i64,
    updated_at: i64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GuiDocument {
    content: String,
    #[serde(rename = "revisionID")]
    revision_id: Option<String>,
    #[serde(rename = "parentRevisionID")]
    parent_revision_id: Option<String>,
    content_hash: Option<String>,
    updated_at: Option<i64>,
    lease: Option<GuiDocumentLease>,
    conflicts: Vec<GuiDocumentConflict>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GuiDocumentLease {
    id: String,
    #[serde(rename = "holderID")]
    holder_id: String,
    holder_name: String,
    expires_at: i64,
    is_held_by_local_peer: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GuiDocumentConflict {
    id: String,
    #[serde(rename = "revisionID")]
    revision_id: String,
    author_name: String,
    content: String,
    created_at: i64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GuiCall {
    id: String,
    #[serde(rename = "peerID")]
    peer_id: String,
    peer_name: String,
    direction: String,
    state: String,
    started_at: Option<i64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GuiPrecisionRequest {
    id: String,
    #[serde(rename = "requesterID")]
    requester_id: String,
    requester_name: String,
    created_at: i64,
    expires_at: i64,
    state: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GuiDiagnostics {
    ble_state: String,
    transport_state: String,
    location_state: String,
    ranging_state: String,
    event_count: u64,
    pending_replication_count: u64,
    connected_peer_count: usize,
    last_sync_at: Option<i64>,
    recent_events: Vec<GuiDiagnosticEvent>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GuiDiagnosticEvent {
    id: String,
    timestamp: i64,
    subsystem: String,
    level: String,
    message: String,
}

fn adapt_command(
    command: GuiCommand,
    context: &Value,
    now_ms: i64,
) -> Result<(AppCommand, BindingEffect), Value> {
    let (command, effect) = match command {
        GuiCommand::StartTravel => (
            json!({"kind": "startTravel", "now_ms": now_ms}),
            BindingEffect::None,
        ),
        GuiCommand::EndTravel => (
            json!({"kind": "endTravel", "now_ms": now_ms}),
            BindingEffect::None,
        ),
        GuiCommand::CreateGroup { name } => (
            json!({"kind": "createGroup", "name": name, "now_ms": now_ms}),
            BindingEffect::None,
        ),
        GuiCommand::JoinGroup { pin } => (
            json!({"kind": "joinWithPin", "pin": pin, "now_ms": now_ms}),
            BindingEffect::None,
        ),
        GuiCommand::LeaveGroup => (
            json!({"kind": "leaveGroup", "now_ms": now_ms}),
            BindingEffect::None,
        ),
        GuiCommand::SetLocationSharing { enabled } => (
            json!({"kind": "setSharingPaused", "paused": !enabled, "now_ms": now_ms}),
            BindingEffect::None,
        ),
        GuiCommand::RequestPrecision { peer_id } => (
            json!({
                "kind": "requestPrecision",
                "peer_id": peer_id,
                "ttl_ms": PRECISION_REQUEST_TTL_MS,
                "now_ms": now_ms
            }),
            BindingEffect::None,
        ),
        GuiCommand::RespondPrecision { request_id, accept } => (
            json!({
                "kind": "respondPrecision",
                "request_id": request_id,
                "accept": accept,
                "now_ms": now_ms
            }),
            BindingEffect::None,
        ),
        GuiCommand::SendText {
            conversation_id,
            body,
        } => (
            json!({
                "kind": "sendText",
                "conversation": conversation_value(&conversation_id)?,
                "text": body,
                "now_ms": now_ms
            }),
            BindingEffect::None,
        ),
        GuiCommand::RegisterMedia {
            kind,
            path,
            conversation_id,
        } => {
            let id = next_resource_id(now_ms);
            let mime_type = mime_type_for(kind, &path).to_owned();
            let byte_count = std::fs::metadata(&path).map_or(0, |metadata| metadata.len());
            let media_kind = match kind {
                GuiMediaKind::Image => "image",
                GuiMediaKind::Voice => "voice",
            };
            let thumbnail = matches!(kind, GuiMediaKind::Image).then(|| id.clone());
            let duration = matches!(kind, GuiMediaKind::Voice).then_some(0_u64);
            (
                json!({
                    "kind": "registerMedia",
                    "conversation": conversation_value(&conversation_id)?,
                    "media_kind": media_kind,
                    "resource_id": id,
                    "thumbnail_resource_id": thumbnail,
                    "mime_type": mime_type,
                    "duration_ms": duration,
                    "source_path": path,
                    "now_ms": now_ms
                }),
                BindingEffect::InsertResource {
                    id,
                    resource: LocalResource {
                        path,
                        mime_type,
                        byte_count,
                        state: "available".into(),
                    },
                },
            )
        }
        GuiCommand::CancelResource { id } => (
            json!({"kind": "cancelResource", "resource_id": id, "now_ms": now_ms}),
            BindingEffect::SetResourceState {
                id,
                state: "cancelled".into(),
            },
        ),
        GuiCommand::RetryResource { id } => (
            json!({"kind": "retryResource", "resource_id": id, "now_ms": now_ms}),
            BindingEffect::SetResourceState {
                id,
                state: "available".into(),
            },
        ),
        GuiCommand::CreatePlace {
            title,
            note,
            latitude,
            longitude,
        } => (
            json!({
                "kind": "createPlace",
                "title": title,
                "note": note,
                "latitude": latitude,
                "longitude": longitude,
                "now_ms": now_ms
            }),
            BindingEffect::None,
        ),
        GuiCommand::UpdatePlace {
            id,
            title,
            note,
            latitude,
            longitude,
        } => (
            json!({
                "kind": "updatePlace",
                "place_id": id,
                "title": title,
                "note": note,
                "latitude": latitude,
                "longitude": longitude,
                "now_ms": now_ms
            }),
            BindingEffect::None,
        ),
        GuiCommand::DeletePlace { id } => (
            json!({"kind": "deletePlace", "place_id": id, "now_ms": now_ms}),
            BindingEffect::None,
        ),
        GuiCommand::AcquireDocumentLease => (
            json!({
                "kind": "acquireDocumentLease",
                "duration_ms": DOCUMENT_LEASE_DURATION_MS,
                "now_ms": now_ms
            }),
            BindingEffect::None,
        ),
        GuiCommand::SaveDocument {
            content,
            parent_revision_id,
        } => (
            json!({
                "kind": "saveDocument",
                "markdown": content,
                "parent": parent_revision_id,
                "now_ms": now_ms
            }),
            BindingEffect::None,
        ),
        GuiCommand::ReleaseDocumentLease => {
            let lease_id = context
                .pointer("/document/lease/leaseId")
                .and_then(Value::as_str)
                .ok_or_else(|| ffi_error("unknownEntity", "no active document lease to release"))?;
            (
                json!({
                    "kind": "releaseDocumentLease",
                    "lease_id": lease_id,
                    "now_ms": now_ms
                }),
                BindingEffect::None,
            )
        }
        GuiCommand::StartCall { peer_id } => (
            json!({"kind": "startCall", "peer_id": peer_id, "now_ms": now_ms}),
            BindingEffect::None,
        ),
        GuiCommand::AnswerCall { call_id } => {
            validate_call_id(context, &call_id)?;
            (
                json!({"kind": "answerCall", "now_ms": now_ms}),
                BindingEffect::None,
            )
        }
        GuiCommand::RejectCall { call_id } => {
            validate_call_id(context, &call_id)?;
            (
                json!({"kind": "rejectCall", "now_ms": now_ms}),
                BindingEffect::None,
            )
        }
        GuiCommand::EndCall { call_id } => {
            validate_call_id(context, &call_id)?;
            (
                json!({"kind": "endCall", "now_ms": now_ms}),
                BindingEffect::None,
            )
        }
        GuiCommand::SetForeground { foreground } => (
            json!({"kind": "setForeground", "foreground": foreground, "now_ms": now_ms}),
            BindingEffect::None,
        ),
        GuiCommand::ClearTripData => (
            json!({"kind": "clearTripData", "now_ms": now_ms}),
            BindingEffect::ClearResources,
        ),
    };
    serde_json::from_value(command)
        .map(|command| (command, effect))
        .map_err(|error| {
            ffi_error(
                "commandAdapterFailed",
                format!("command could not be mapped to the domain core: {error}"),
            )
        })
}

fn adapt_snapshot(
    snapshot: tc_core::AppSnapshot,
    revision: u64,
    resources: &BTreeMap<String, LocalResource>,
    now_ms: i64,
) -> Result<GuiSnapshot, Value> {
    let snapshot = serde_json::to_value(snapshot)
        .and_then(serde_json::from_value::<InternalSnapshot>)
        .map_err(|error| {
            ffi_error(
                "snapshotAdapterFailed",
                format!("domain snapshot could not be mapped to the GUI: {error}"),
            )
        })?;

    let mut names = BTreeMap::from([(
        snapshot.identity.peer_id.clone(),
        snapshot.identity.display_name.clone(),
    )]);
    if let Some(group) = &snapshot.group {
        names.extend(
            group
                .members
                .iter()
                .map(|member| (member.peer_id.clone(), member.display_name.clone())),
        );
    }
    names.extend(
        snapshot
            .peers
            .iter()
            .map(|peer| (peer.peer_id.clone(), peer.display_name.clone())),
    );

    let peer_last_seen = snapshot
        .peers
        .iter()
        .filter_map(|peer| {
            peer.last_location
                .as_ref()
                .map(|location| (peer.peer_id.clone(), location.sampled_at_ms))
        })
        .collect::<BTreeMap<_, _>>();
    let connected_peers = snapshot
        .peers
        .iter()
        .filter(|peer| peer.connected)
        .map(|peer| peer.peer_id.clone())
        .collect::<BTreeSet<_>>();
    let local_location = snapshot
        .peers
        .iter()
        .find(|peer| peer.peer_id == snapshot.identity.peer_id)
        .and_then(|peer| peer.last_location.as_ref());

    let group = snapshot.group.as_ref().map(|group| {
        let owner_id = group
            .members
            .iter()
            .find(|member| member.role.eq_ignore_ascii_case("owner"))
            .map_or_else(
                || snapshot.identity.peer_id.clone(),
                |member| member.peer_id.clone(),
            );
        GuiGroup {
            id: group.id.clone(),
            name: group.name.clone(),
            epoch: group.epoch,
            owner_id,
            invite_pin: group.invite_pin.clone(),
            members: group
                .members
                .iter()
                .map(|member| GuiMember {
                    id: member.peer_id.clone(),
                    display_name: member.display_name.clone(),
                    role: member.role.clone(),
                    is_reachable: member.peer_id == snapshot.identity.peer_id
                        || (member.active && connected_peers.contains(&member.peer_id)),
                    last_seen_at: peer_last_seen.get(&member.peer_id).copied(),
                })
                .collect(),
        }
    });

    let peers = snapshot
        .peers
        .iter()
        .filter(|peer| peer.peer_id != snapshot.identity.peer_id)
        .map(|peer| {
            let gps_relative =
                relative_measurement(local_location, peer.last_location.as_ref(), None, now_ms);
            let fused_relative = relative_measurement(
                local_location,
                peer.last_location.as_ref(),
                peer.ranging.as_ref(),
                now_ms,
            );
            let location = peer.last_location.as_ref().map(|location| GuiLocation {
                latitude: location.latitude,
                longitude: location.longitude,
                altitude_meters: location.altitude_m,
                horizontal_accuracy_meters: location.horizontal_accuracy_m,
                speed_meters_per_second: location.speed_mps,
                course_degrees: location.course_degrees,
                sampled_at: location.sampled_at_ms,
                received_at: location.sampled_at_ms,
                is_stale: gps_relative.as_ref().map_or_else(
                    || now_ms.saturating_sub(location.sampled_at_ms) > 60_000,
                    |relative| relative.stale,
                ),
                distance_meters: gps_relative
                    .as_ref()
                    .map(|relative| relative.distance_m.value),
                bearing_degrees: gps_relative
                    .as_ref()
                    .map(|relative| normalized_degrees(relative.direction_radians.value)),
                source: "gps".into(),
            });
            let ranging = peer.ranging.as_ref().map(|raw_ranging| {
                fused_relative.as_ref().map_or_else(
                    || GuiRanging {
                        distance_meters: fresh_uwb_distance(
                            raw_ranging.distance_m,
                            raw_ranging.observed_at_ms,
                            now_ms,
                        ),
                        direction_degrees: fresh_uwb_value(
                            raw_ranging.direction_radians,
                            raw_ranging.observed_at_ms,
                            now_ms,
                        )
                        .map(normalized_degrees),
                        distance_source: fresh_uwb_distance(
                            raw_ranging.distance_m,
                            raw_ranging.observed_at_ms,
                            now_ms,
                        )
                        .map_or_else(|| "unavailable".into(), |_| "uwb".into()),
                        direction_source: fresh_uwb_value(
                            raw_ranging.direction_radians,
                            raw_ranging.observed_at_ms,
                            now_ms,
                        )
                        .map_or_else(|| "unavailable".into(), |_| "uwb".into()),
                        updated_at: raw_ranging.observed_at_ms,
                    },
                    |relative| GuiRanging {
                        distance_meters: Some(relative.distance_m.value),
                        direction_degrees: Some(normalized_degrees(
                            relative.direction_radians.value,
                        )),
                        distance_source: relative_source(relative.distance_m.source).into(),
                        direction_source: relative_source(relative.direction_radians.source).into(),
                        updated_at: relative
                            .distance_m
                            .observed_at_ms
                            .max(relative.direction_radians.observed_at_ms),
                    },
                )
            });
            let precision_state = snapshot
                .pending_precision
                .iter()
                .filter(|request| {
                    request.requester_id == peer.peer_id || request.target_id == peer.peer_id
                })
                .max_by_key(|request| request.created_at_ms)
                .map_or_else(|| "idle".into(), |request| request.status.clone());
            GuiPeer {
                id: peer.peer_id.clone(),
                display_name: peer.display_name.clone(),
                is_reachable: peer.connected,
                last_seen_at: peer
                    .last_location
                    .as_ref()
                    .map(|location| location.sampled_at_ms),
                location,
                ranging,
                location_sharing_paused: false,
                precision_state,
            }
        })
        .collect();

    let conversations = adapt_conversations(&snapshot, &names, resources);
    let places = snapshot
        .places
        .iter()
        .filter(|place| !place.deleted)
        .map(|place| GuiPlace {
            id: place.id.clone(),
            title: place.title.clone(),
            note: place.note.clone(),
            latitude: place.latitude,
            longitude: place.longitude,
            author_id: place.author_id.clone(),
            author_name: peer_name(&names, &place.author_id),
            created_at: place.created_at_ms,
            updated_at: place.updated_at_ms,
        })
        .collect();

    let document = GuiDocument {
        content: snapshot.document.content.clone(),
        revision_id: snapshot.document.head.clone(),
        parent_revision_id: None,
        content_hash: None,
        updated_at: None,
        lease: snapshot
            .document
            .lease
            .as_ref()
            .map(|lease| GuiDocumentLease {
                id: lease.lease_id.clone(),
                holder_id: lease.holder_id.clone(),
                holder_name: peer_name(&names, &lease.holder_id),
                expires_at: lease.expires_at_ms,
                is_held_by_local_peer: lease.holder_id == snapshot.identity.peer_id,
            }),
        conflicts: snapshot
            .document
            .conflicts
            .iter()
            .map(|conflict| GuiDocumentConflict {
                id: conflict.revision_id.clone(),
                revision_id: conflict.revision_id.clone(),
                author_name: peer_name(&names, &conflict.author_id),
                content: conflict.markdown.clone(),
                created_at: conflict.created_at_ms,
            })
            .collect(),
    };
    let active_call = snapshot
        .active_call
        .as_ref()
        .and_then(|call| adapt_call(call, &names));
    let pending_precision_requests = snapshot
        .pending_precision
        .iter()
        .filter(|request| {
            request.target_id == snapshot.identity.peer_id
                && request.status.eq_ignore_ascii_case("pending")
                && request.expires_at_ms > now_ms
        })
        .map(|request| GuiPrecisionRequest {
            id: request.request_id.clone(),
            requester_id: request.requester_id.clone(),
            requester_name: peer_name(&names, &request.requester_id),
            created_at: request.created_at_ms,
            expires_at: request.expires_at_ms,
            state: request.status.clone(),
        })
        .collect();

    let recent_events = snapshot
        .diagnostics
        .entries
        .iter()
        .enumerate()
        .map(|(index, entry)| GuiDiagnosticEvent {
            id: format!("diag-{}-{index}", entry.timestamp_ms),
            timestamp: entry.timestamp_ms,
            subsystem: entry.category.clone(),
            level: diagnostic_level(&entry.message).into(),
            message: entry.message.clone(),
        })
        .collect::<Vec<_>>();
    let module_state = if snapshot.lifecycle.is_traveling {
        "active"
    } else {
        "idle"
    };
    let diagnostics = GuiDiagnostics {
        ble_state: module_state.into(),
        transport_state: module_state.into(),
        location_state: if snapshot.lifecycle.sharing_paused {
            "paused".into()
        } else {
            module_state.into()
        },
        ranging_state: if snapshot.peers.iter().any(|peer| peer.ranging.is_some()) {
            "active".into()
        } else {
            "idle".into()
        },
        event_count: u64::try_from(snapshot.diagnostics.entries.len()).unwrap_or(u64::MAX),
        pending_replication_count: u64::try_from(snapshot.diagnostics.pending_module_commands)
            .unwrap_or(u64::MAX),
        connected_peer_count: snapshot
            .peers
            .iter()
            .filter(|peer| peer.connected && peer.peer_id != snapshot.identity.peer_id)
            .count(),
        last_sync_at: snapshot
            .diagnostics
            .entries
            .last()
            .map(|entry| entry.timestamp_ms),
        recent_events,
    };

    let phase = if !snapshot.lifecycle.blockers.is_empty() {
        "blocked"
    } else if snapshot.lifecycle.is_traveling {
        "traveling"
    } else if snapshot.group.is_some() {
        "ready"
    } else {
        "idle"
    };
    let blockers = snapshot
        .lifecycle
        .blockers
        .iter()
        .map(|blocker| GuiBlocker {
            capability: blocker.code.clone(),
            reason: blocker.message.clone(),
            recovery_suggestion: None,
        })
        .collect();

    Ok(GuiSnapshot {
        protocol_version: PROTOCOL_VERSION,
        revision,
        lifecycle: GuiLifecycle {
            is_traveling: snapshot.lifecycle.is_traveling,
            is_foreground: snapshot.lifecycle.is_foreground,
            location_sharing_enabled: !snapshot.lifecycle.sharing_paused,
            phase: phase.into(),
            blockers,
            last_error: snapshot.diagnostics.last_error,
        },
        identity: GuiIdentity {
            peer_id: snapshot.identity.peer_id,
            display_name: snapshot.identity.display_name,
        },
        group,
        peers,
        conversations,
        places,
        document,
        active_call,
        pending_precision_requests,
        diagnostics,
    })
}

fn adapt_conversations(
    snapshot: &InternalSnapshot,
    names: &BTreeMap<String, String>,
    resources: &BTreeMap<String, LocalResource>,
) -> Vec<GuiConversation> {
    let domain_resources = snapshot
        .resources
        .iter()
        .map(|resource| (resource.manifest.resource_id.as_str(), resource))
        .collect::<BTreeMap<_, _>>();
    let mut conversations = BTreeMap::new();
    if let Some(group) = &snapshot.group {
        conversations.insert(
            "group".to_owned(),
            GuiConversation {
                id: "group".into(),
                title: group.name.clone(),
                kind: "group".into(),
                participant_ids: group
                    .members
                    .iter()
                    .map(|member| member.peer_id.clone())
                    .collect(),
                unread_count: 0,
                messages: Vec::new(),
            },
        );
        for member in &group.members {
            if member.peer_id == snapshot.identity.peer_id {
                continue;
            }
            let id = format!("direct:{}", member.peer_id);
            conversations.insert(
                id.clone(),
                GuiConversation {
                    id,
                    title: member.display_name.clone(),
                    kind: "direct".into(),
                    participant_ids: vec![
                        snapshot.identity.peer_id.clone(),
                        member.peer_id.clone(),
                    ],
                    unread_count: 0,
                    messages: Vec::new(),
                },
            );
        }
    }

    for conversation in &snapshot.conversations {
        let kind = value_string(&conversation.conversation, "kind").unwrap_or("group");
        let direct_peer = value_string(&conversation.conversation, "peer_id");
        let id = if kind.eq_ignore_ascii_case("direct") {
            direct_peer.map_or_else(|| conversation.id.clone(), |peer| format!("direct:{peer}"))
        } else {
            "group".into()
        };
        let title = if kind.eq_ignore_ascii_case("direct") {
            direct_peer.map_or_else(|| "私聊".into(), |peer| peer_name(names, peer))
        } else {
            snapshot
                .group
                .as_ref()
                .map_or_else(|| "群聊".into(), |group| group.name.clone())
        };
        let participant_ids = if let Some(peer) = direct_peer {
            vec![snapshot.identity.peer_id.clone(), peer.to_owned()]
        } else {
            snapshot.group.as_ref().map_or_else(Vec::new, |group| {
                group
                    .members
                    .iter()
                    .map(|member| member.peer_id.clone())
                    .collect()
            })
        };
        let messages = conversation
            .messages
            .iter()
            .map(|message| adapt_message(message, snapshot, names, resources, &domain_resources))
            .collect();
        conversations.insert(
            id.clone(),
            GuiConversation {
                id,
                title,
                kind: kind.to_owned(),
                participant_ids,
                unread_count: 0,
                messages,
            },
        );
    }
    conversations.into_values().collect()
}

fn adapt_message(
    message: &InternalMessage,
    snapshot: &InternalSnapshot,
    names: &BTreeMap<String, String>,
    resources: &BTreeMap<String, LocalResource>,
    domain_resources: &BTreeMap<&str, &InternalResource>,
) -> GuiMessage {
    let kind = value_string(&message.content, "kind")
        .unwrap_or("text")
        .to_owned();
    let text = value_string(&message.content, "text").map(str::to_owned);
    let resource_id = match kind.as_str() {
        "image" => value_string(&message.content, "original"),
        "voice" => value_string(&message.content, "resource"),
        _ => None,
    };
    let resource = resource_id.map(|id| {
        let local = resources.get(id);
        let domain = domain_resources.get(id).copied();
        let mime_type = local.map_or_else(
            || {
                domain.map_or_else(
                    || {
                        value_string(&message.content, "mime_type")
                            .unwrap_or("application/octet-stream")
                            .to_owned()
                    },
                    |resource| resource.manifest.mime_type.clone(),
                )
            },
            |resource| resource.mime_type.clone(),
        );
        let byte_count = domain.map_or_else(
            || local.map_or(0, |resource| resource.byte_count),
            |resource| resource.manifest.byte_size,
        );
        let state = domain.map_or_else(
            || local.map_or_else(|| "pending".into(), |resource| resource.state.clone()),
            |resource| resource.status.clone(),
        );
        let transferred_bytes = domain.map_or_else(
            || if state == "available" { byte_count } else { 0 },
            |resource| resource.transferred_bytes,
        );
        GuiResource {
            id: id.to_owned(),
            mime_type,
            local_path: domain
                .and_then(|resource| resource.local_path.clone())
                .or_else(|| local.map(|resource| resource.path.clone())),
            byte_count,
            transferred_bytes,
            state,
        }
    });
    let mut target_members = message.delivery.delivered_members.clone();
    target_members.extend(message.delivery.pending_members.iter().cloned());
    let phase = match message.delivery.phase.as_str() {
        "persistedLocally" => "local",
        "replicatedToRelay" => "relay",
        other => other,
    };
    GuiMessage {
        id: message.message_id.clone(),
        sender_id: message.sender_id.clone(),
        sender_name: peer_name(names, &message.sender_id),
        kind,
        text,
        resource,
        created_at: message.sent_at_ms,
        is_outgoing: message.sender_id == snapshot.identity.peer_id,
        delivery: GuiDelivery {
            phase: phase.to_owned(),
            relay_count: message.delivery.relay_count,
            delivered_member_ids: message.delivery.delivered_members.iter().cloned().collect(),
            target_member_ids: target_members.into_iter().collect(),
            error: None,
        },
    }
}

fn adapt_call(call: &Value, names: &BTreeMap<String, String>) -> Option<GuiCall> {
    let phase = value_string(call, "phase")?;
    if phase.eq_ignore_ascii_case("idle") || phase.eq_ignore_ascii_case("ended") {
        return None;
    }
    let call_id = value_string(call, "call_id")?;
    let peer_id = value_string(call, "peer_id")?;
    let started_at = call
        .get("connected_at_ms")
        .or_else(|| call.get("offered_at_ms"))
        .and_then(Value::as_i64);
    Some(GuiCall {
        id: call_id.to_owned(),
        peer_id: peer_id.to_owned(),
        peer_name: peer_name(names, peer_id),
        direction: if phase.eq_ignore_ascii_case("incoming") {
            "incoming".into()
        } else {
            "outgoing".into()
        },
        state: phase.to_owned(),
        started_at,
    })
}

fn conversation_value(id: &str) -> Result<Value, Value> {
    if id == "group" {
        return Ok(json!({"kind": "group"}));
    }
    id.strip_prefix("direct:").map_or_else(
        || {
            Err(ffi_error(
                "invalidConversation",
                "unknown conversation identifier",
            ))
        },
        |peer_id| {
            if peer_id.is_empty() {
                Err(ffi_error(
                    "invalidConversation",
                    "direct conversation has no peer",
                ))
            } else {
                Ok(json!({"kind": "direct", "peer_id": peer_id}))
            }
        },
    )
}

fn validate_call_id(context: &Value, requested: &str) -> Result<(), Value> {
    let active = context
        .pointer("/activeCall/call_id")
        .and_then(Value::as_str)
        .ok_or_else(|| ffi_error("unknownEntity", "there is no active call"))?;
    if active == requested {
        Ok(())
    } else {
        Err(ffi_error("unknownEntity", "call identifier is not active"))
    }
}

fn apply_effect(resources: &mut BTreeMap<String, LocalResource>, effect: BindingEffect) {
    match effect {
        BindingEffect::None => {}
        BindingEffect::InsertResource { id, resource } => {
            resources.insert(id, resource);
        }
        BindingEffect::SetResourceState { id, state } => {
            if let Some(resource) = resources.get_mut(&id) {
                resource.state = state;
            }
        }
        BindingEffect::ClearResources => resources.clear(),
    }
}

fn next_resource_id(now_ms: i64) -> String {
    let sequence = RESOURCE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    format!("res_local_{now_ms}_{sequence}")
}

fn mime_type_for(kind: GuiMediaKind, path: &str) -> &'static str {
    let extension = Path::new(path)
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    match (kind, extension.as_str()) {
        (GuiMediaKind::Image, "heic" | "heif") => "image/heic",
        (GuiMediaKind::Image, "jpg" | "jpeg") => "image/jpeg",
        (GuiMediaKind::Image, "png") => "image/png",
        (GuiMediaKind::Image, "gif") => "image/gif",
        (GuiMediaKind::Image, _) => "image/*",
        (GuiMediaKind::Voice, "m4a" | "mp4") => "audio/mp4",
        (GuiMediaKind::Voice, "aac") => "audio/aac",
        (GuiMediaKind::Voice, "caf") => "audio/x-caf",
        (GuiMediaKind::Voice, _) => "audio/*",
    }
}

fn normalized_degrees(radians: f64) -> f64 {
    radians.to_degrees().rem_euclid(360.0)
}

fn relative_measurement(
    local: Option<&InternalLocation>,
    remote: Option<&InternalLocation>,
    ranging: Option<&InternalRanging>,
    now_ms: i64,
) -> Option<RelativeLocation> {
    let local = local.map(domain_location)?;
    let remote = remote.map(domain_location)?;
    let ranging = ranging.map(|sample| UwbObservation {
        distance_m: sample.distance_m,
        direction_radians: sample.direction_radians,
        observed_at_ms: sample.observed_at_ms,
    });
    Some(relative_location(
        &local,
        &remote,
        ranging.as_ref(),
        now_ms,
        FusionPolicy::default(),
    ))
}

fn domain_location(location: &InternalLocation) -> LocationSample {
    LocationSample {
        latitude: location.latitude,
        longitude: location.longitude,
        altitude_m: location.altitude_m,
        horizontal_accuracy_m: location.horizontal_accuracy_m,
        speed_mps: location.speed_mps,
        course_degrees: location.course_degrees,
        sampled_at_ms: location.sampled_at_ms,
    }
}

fn relative_source(source: RelativeSource) -> &'static str {
    match source {
        RelativeSource::Gps => "gps",
        RelativeSource::Uwb => "uwb",
    }
}

fn fresh_uwb_value(value: Option<f64>, observed_at_ms: i64, now_ms: i64) -> Option<f64> {
    let age = now_ms.saturating_sub(observed_at_ms);
    ((0..=FusionPolicy::default().uwb_stale_after_ms).contains(&age))
        .then_some(value)
        .flatten()
        .filter(|value| value.is_finite())
}

fn fresh_uwb_distance(value: Option<f64>, observed_at_ms: i64, now_ms: i64) -> Option<f64> {
    fresh_uwb_value(value, observed_at_ms, now_ms).filter(|value| *value >= 0.0)
}

fn diagnostic_level(message: &str) -> &'static str {
    let normalized = message.to_ascii_lowercase();
    if normalized.contains("failed") || normalized.contains("error") {
        "error"
    } else if normalized.contains("timeout") || normalized.contains("warning") {
        "warning"
    } else {
        "info"
    }
}

fn peer_name(names: &BTreeMap<String, String>, peer_id: &str) -> String {
    names
        .get(peer_id)
        .cloned()
        .unwrap_or_else(|| peer_id.to_owned())
}

fn value_string<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

fn unix_now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| {
            i64::try_from(duration.as_millis()).unwrap_or(i64::MAX)
        })
}

fn ffi_error(code: impl Into<String>, message: impl Into<String>) -> Value {
    json!({"code": code.into(), "message": message.into()})
}

fn panic_message(panic: Box<dyn std::any::Any + Send>) -> String {
    panic.downcast_ref::<&str>().map_or_else(
        || {
            panic
                .downcast_ref::<String>()
                .cloned()
                .unwrap_or_else(|| "Rust panic without a string payload".into())
        },
        |message| (*message).to_owned(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_swift_command_tags_deserialize_without_now_ms() {
        let commands = [
            r#"{"type":"startTravel"}"#,
            r#"{"type":"endTravel"}"#,
            r#"{"type":"createGroup","name":"Trip"}"#,
            r#"{"type":"joinGroup","pin":"123456"}"#,
            r#"{"type":"leaveGroup"}"#,
            r#"{"type":"setLocationSharing","enabled":true}"#,
            r#"{"type":"requestPrecision","peerID":"peer_b"}"#,
            r#"{"type":"respondPrecision","requestID":"req_a","accept":true}"#,
            r#"{"type":"sendText","conversationID":"group","body":"hello"}"#,
            r#"{"type":"registerMedia","kind":"image","path":"/tmp/a.jpg","conversationID":"group"}"#,
            r#"{"type":"cancelResource","id":"res_a"}"#,
            r#"{"type":"retryResource","id":"res_a"}"#,
            r#"{"type":"createPlace","title":"Gate","note":"N","latitude":1.0,"longitude":2.0}"#,
            r#"{"type":"updatePlace","id":"p","title":"Gate","note":"N","latitude":1.0,"longitude":2.0}"#,
            r#"{"type":"deletePlace","id":"p"}"#,
            r#"{"type":"acquireDocumentLease"}"#,
            r##"{"type":"saveDocument","content":"# Trip","parentRevisionID":null}"##,
            r#"{"type":"releaseDocumentLease"}"#,
            r#"{"type":"startCall","peerID":"peer_b"}"#,
            r#"{"type":"answerCall","callID":"call_a"}"#,
            r#"{"type":"rejectCall","callID":"call_a"}"#,
            r#"{"type":"endCall","callID":"call_a"}"#,
            r#"{"type":"setForeground","foreground":false}"#,
            r#"{"type":"clearTripData"}"#,
        ];
        for command in commands {
            serde_json::from_str::<GuiCommand>(command).unwrap_or_else(|error| {
                panic!("failed to decode {command}: {error}");
            });
        }
    }
}
