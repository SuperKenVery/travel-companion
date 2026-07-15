//! Shared, platform-neutral value types used by every Travel Companion crate.

use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};
use std::fmt::{Display, Formatter};
use uuid::Uuid;

macro_rules! string_id {
    ($name:ident, $prefix:literal) => {
        #[derive(
            Clone, Debug, Default, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize,
        )]
        #[serde(transparent)]
        pub struct $name(pub String);

        impl $name {
            #[must_use]
            pub fn new() -> Self {
                Self(format!("{}{}", $prefix, Uuid::new_v4().simple()))
            }

            #[must_use]
            pub fn from_string(value: impl Into<String>) -> Self {
                Self(value.into())
            }

            #[must_use]
            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl From<&str> for $name {
            fn from(value: &str) -> Self {
                Self(value.to_owned())
            }
        }

        impl Display for $name {
            fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
                formatter.write_str(&self.0)
            }
        }
    };
}

string_id!(EventId, "evt_");
string_id!(GroupId, "grp_");
string_id!(EntityId, "entity_");
string_id!(ResourceId, "res_");
string_id!(RevisionId, "rev_");
string_id!(LeaseId, "lease_");
string_id!(CallId, "call_");
string_id!(RequestId, "req_");

/// Stable cross-platform device identity. Unlike the other opaque IDs this is
/// deliberately encoded as a canonical UUID because Apple Network/Nearby
/// Interaction APIs use UUIDs at their native boundary.
#[derive(Clone, Debug, Default, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(transparent)]
pub struct PeerId(pub String);

impl PeerId {
    #[must_use]
    pub fn new() -> Self {
        Self(Uuid::new_v4().hyphenated().to_string())
    }

    #[must_use]
    pub fn from_string(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl From<&str> for PeerId {
    fn from(value: &str) -> Self {
        Self(value.to_owned())
    }
}

impl Display for PeerId {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

/// A Hybrid Logical Clock timestamp. Ordering is deterministic even if two
/// devices have identical physical and logical components.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HlcTimestamp {
    pub physical_ms: i64,
    pub logical: u32,
    pub node: PeerId,
}

impl Ord for HlcTimestamp {
    fn cmp(&self, other: &Self) -> Ordering {
        (self.physical_ms, self.logical, &self.node).cmp(&(
            other.physical_ms,
            other.logical,
            &other.node,
        ))
    }
}

impl PartialOrd for HlcTimestamp {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HybridLogicalClock {
    last: HlcTimestamp,
}

impl HybridLogicalClock {
    #[must_use]
    pub fn new(node: PeerId, physical_ms: i64) -> Self {
        Self {
            last: HlcTimestamp {
                physical_ms,
                logical: 0,
                node,
            },
        }
    }

    #[must_use]
    pub fn last(&self) -> &HlcTimestamp {
        &self.last
    }

    pub fn tick(&mut self, wall_ms: i64) -> HlcTimestamp {
        if wall_ms > self.last.physical_ms {
            self.last.physical_ms = wall_ms;
            self.last.logical = 0;
        } else {
            self.last.logical = self.last.logical.saturating_add(1);
        }
        self.last.clone()
    }

    pub fn observe(&mut self, remote: &HlcTimestamp, wall_ms: i64) -> HlcTimestamp {
        let old_physical = self.last.physical_ms;
        let physical = wall_ms.max(old_physical).max(remote.physical_ms);
        let logical = if physical == old_physical && physical == remote.physical_ms {
            self.last.logical.max(remote.logical).saturating_add(1)
        } else if physical == old_physical {
            self.last.logical.saturating_add(1)
        } else if physical == remote.physical_ms {
            remote.logical.saturating_add(1)
        } else {
            0
        };
        self.last.physical_ms = physical;
        self.last.logical = logical;
        self.last.clone()
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum GroupAudience {
    Group,
    Recipients { members: BTreeSet<PeerId> },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum DeliveryPolicy {
    Durable,
    LatestValue { key: String, expires_at_ms: i64 },
    Transient { expires_at_ms: i64 },
}

impl DeliveryPolicy {
    #[must_use]
    pub fn expires_at_ms(&self) -> Option<i64> {
        match self {
            Self::Durable => None,
            Self::LatestValue { expires_at_ms, .. } | Self::Transient { expires_at_ms } => {
                Some(*expires_at_ms)
            }
        }
    }
}

/// Immutable synchronization fact. `target_members` is resolved against the
/// membership snapshot at publication time and is part of the signature.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EventEnvelope {
    pub id: EventId,
    pub group_id: GroupId,
    pub group_epoch: u64,
    pub sender_id: PeerId,
    pub sender_sequence: u64,
    pub logical_clock: HlcTimestamp,
    pub audience: GroupAudience,
    pub target_members: BTreeSet<PeerId>,
    pub event_type: String,
    pub delivery_policy: DeliveryPolicy,
    pub created_at_ms: i64,
    pub payload: serde_json::Value,
    #[serde(default)]
    pub signature: Vec<u8>,
}

impl EventEnvelope {
    /// Canonical enough for this protocol: structs have fixed field order and
    /// all unordered sets/maps are represented by BTree collections.
    pub fn signing_bytes(&self) -> Result<Vec<u8>, serde_json::Error> {
        let mut unsigned = self.clone();
        unsigned.signature.clear();
        serde_json::to_vec(&unsigned)
    }

    #[must_use]
    pub fn is_expired_at(&self, now_ms: i64) -> bool {
        self.delivery_policy
            .expires_at_ms()
            .is_some_and(|deadline| deadline <= now_ms)
    }
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SequenceSummary {
    /// Largest sequence for which every preceding event is present.
    pub contiguous_frontier: u64,
    /// Largest sequence observed, including events above a gap.
    pub max_seen: u64,
    /// Exact missing sequences between frontier and max_seen.
    pub gaps: BTreeSet<u64>,
}

impl SequenceSummary {
    #[must_use]
    pub fn contains(&self, sequence: u64) -> bool {
        sequence <= self.max_seen && !self.gaps.contains(&sequence)
    }
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncDigest {
    pub group_epoch: u64,
    pub senders: BTreeMap<PeerId, SequenceSummary>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocationSample {
    pub latitude: f64,
    pub longitude: f64,
    pub altitude_m: Option<f64>,
    pub horizontal_accuracy_m: f64,
    pub speed_mps: Option<f64>,
    pub course_degrees: Option<f64>,
    pub sampled_at_ms: i64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hlc_survives_clock_rollback_and_merges_remote_time() {
        let mut a = HybridLogicalClock::new(PeerId::from("a"), 1_000);
        assert_eq!(a.tick(900).logical, 1);
        assert_eq!(a.tick(800).logical, 2);

        let remote = HlcTimestamp {
            physical_ms: 1_200,
            logical: 4,
            node: PeerId::from("b"),
        };
        let merged = a.observe(&remote, 1_100);
        assert_eq!(merged.physical_ms, 1_200);
        assert_eq!(merged.logical, 5);
        assert!(merged > remote);
    }

    #[test]
    fn hlc_has_stable_cross_sender_tie_break() {
        let a = HlcTimestamp {
            physical_ms: 7,
            logical: 2,
            node: PeerId::from("a"),
        };
        let b = HlcTimestamp {
            node: PeerId::from("b"),
            ..a.clone()
        };
        assert!(a < b);
    }

    #[test]
    fn generated_peer_identity_is_a_native_uuid() {
        let peer = PeerId::new();
        assert_eq!(
            Uuid::parse_str(peer.as_str()).unwrap().to_string(),
            peer.as_str()
        );
    }
}
