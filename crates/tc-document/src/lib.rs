//! Immutable `Trip.md` revisions, best-effort editor leases, and deterministic
//! conflict preservation after a network partition.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use tc_model::{LeaseId, PeerId, RevisionId};
use thiserror::Error;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorLease {
    pub lease_id: LeaseId,
    pub holder_id: PeerId,
    pub issued_at_ms: i64,
    pub expires_at_ms: i64,
    pub released_at_ms: Option<i64>,
}

impl EditorLease {
    #[must_use]
    pub fn is_active_at(&self, now_ms: i64) -> bool {
        self.issued_at_ms <= now_ms
            && now_ms < self.expires_at_ms
            && self.released_at_ms.is_none_or(|released| released > now_ms)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum LeaseEvent {
    Acquired {
        lease: EditorLease,
    },
    Released {
        lease_id: LeaseId,
        holder_id: PeerId,
        released_at_ms: i64,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DocumentRevision {
    pub revision_id: RevisionId,
    pub parent_revision_id: Option<RevisionId>,
    pub author_id: PeerId,
    pub created_at_ms: i64,
    pub content_sha256: String,
    pub markdown: String,
}

impl DocumentRevision {
    #[must_use]
    pub fn new(
        revision_id: RevisionId,
        parent_revision_id: Option<RevisionId>,
        author_id: PeerId,
        created_at_ms: i64,
        markdown: String,
    ) -> Self {
        let content_sha256 = hex::encode(Sha256::digest(markdown.as_bytes()));
        Self {
            revision_id,
            parent_revision_id,
            author_id,
            created_at_ms,
            content_sha256,
            markdown,
        }
    }
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DocumentSnapshot {
    pub content: String,
    pub head_revision_id: Option<RevisionId>,
    pub active_lease: Option<EditorLease>,
    pub conflict_revisions: Vec<DocumentRevision>,
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum DocumentError {
    #[error("lease duration must be positive")]
    InvalidLeaseDuration,
    #[error("lease does not exist")]
    UnknownLease,
    #[error("only the lease holder may release it")]
    NotLeaseHolder,
    #[error("parent revision does not exist")]
    UnknownParent,
    #[error("revision id conflicts with different immutable content")]
    ImmutableConflict,
}

#[derive(Clone, Debug, Default)]
pub struct DocumentState {
    revisions: BTreeMap<RevisionId, DocumentRevision>,
    leases: BTreeMap<LeaseId, EditorLease>,
}

impl DocumentState {
    pub fn acquire_lease(
        &mut self,
        holder_id: PeerId,
        now_ms: i64,
        duration_ms: i64,
    ) -> Result<EditorLease, DocumentError> {
        if duration_ms <= 0 {
            return Err(DocumentError::InvalidLeaseDuration);
        }
        let lease = EditorLease {
            lease_id: LeaseId::new(),
            holder_id,
            issued_at_ms: now_ms,
            expires_at_ms: now_ms.saturating_add(duration_ms),
            released_at_ms: None,
        };
        self.apply_lease_event(&LeaseEvent::Acquired {
            lease: lease.clone(),
        })?;
        Ok(lease)
    }

    pub fn apply_lease_event(&mut self, event: &LeaseEvent) -> Result<(), DocumentError> {
        match event {
            LeaseEvent::Acquired { lease } => {
                if let Some(existing) = self.leases.get(&lease.lease_id) {
                    if existing != lease {
                        return Err(DocumentError::ImmutableConflict);
                    }
                } else {
                    self.leases.insert(lease.lease_id.clone(), lease.clone());
                }
            }
            LeaseEvent::Released {
                lease_id,
                holder_id,
                released_at_ms,
            } => {
                let lease = self
                    .leases
                    .get_mut(lease_id)
                    .ok_or(DocumentError::UnknownLease)?;
                if &lease.holder_id != holder_id {
                    return Err(DocumentError::NotLeaseHolder);
                }
                lease.released_at_ms = Some(
                    lease
                        .released_at_ms
                        .map_or(*released_at_ms, |old| old.min(*released_at_ms)),
                );
            }
        }
        Ok(())
    }

    pub fn release_lease(
        &mut self,
        lease_id: &LeaseId,
        holder_id: &PeerId,
        now_ms: i64,
    ) -> Result<LeaseEvent, DocumentError> {
        let event = LeaseEvent::Released {
            lease_id: lease_id.clone(),
            holder_id: holder_id.clone(),
            released_at_ms: now_ms,
        };
        self.apply_lease_event(&event)?;
        Ok(event)
    }

    /// If a partition creates overlapping leases, the earliest acquisition
    /// wins; exact ties use lease id then holder id. Every replica gets the same
    /// answer without pretending this is a strongly consistent lock.
    #[must_use]
    pub fn active_lease(&self, now_ms: i64) -> Option<EditorLease> {
        self.leases
            .values()
            .filter(|lease| lease.is_active_at(now_ms))
            .min_by_key(|lease| {
                (
                    lease.issued_at_ms,
                    lease.lease_id.clone(),
                    lease.holder_id.clone(),
                )
            })
            .cloned()
    }

    pub fn insert_revision(&mut self, revision: DocumentRevision) -> Result<bool, DocumentError> {
        if let Some(parent) = &revision.parent_revision_id {
            if !self.revisions.contains_key(parent) {
                return Err(DocumentError::UnknownParent);
            }
        }
        if let Some(existing) = self.revisions.get(&revision.revision_id) {
            return if existing == &revision {
                Ok(false)
            } else {
                Err(DocumentError::ImmutableConflict)
            };
        }
        self.revisions
            .insert(revision.revision_id.clone(), revision);
        Ok(true)
    }

    pub fn save(
        &mut self,
        author_id: PeerId,
        parent_revision_id: Option<RevisionId>,
        markdown: String,
        now_ms: i64,
    ) -> Result<DocumentRevision, DocumentError> {
        let revision = DocumentRevision::new(
            RevisionId::new(),
            parent_revision_id,
            author_id,
            now_ms,
            markdown,
        );
        self.insert_revision(revision.clone())?;
        Ok(revision)
    }

    #[must_use]
    pub fn snapshot(&self, now_ms: i64) -> DocumentSnapshot {
        let parent_ids = self
            .revisions
            .values()
            .filter_map(|revision| revision.parent_revision_id.clone())
            .collect::<BTreeSet<_>>();
        let mut tips = self
            .revisions
            .values()
            .filter(|revision| !parent_ids.contains(&revision.revision_id))
            .cloned()
            .collect::<Vec<_>>();
        tips.sort_by_key(|revision| {
            (
                revision.created_at_ms,
                revision.author_id.clone(),
                revision.revision_id.clone(),
            )
        });
        let head = tips.pop();
        DocumentSnapshot {
            content: head
                .as_ref()
                .map_or_else(String::new, |revision| revision.markdown.clone()),
            head_revision_id: head.as_ref().map(|revision| revision.revision_id.clone()),
            active_lease: self.active_lease(now_ms),
            conflict_revisions: tips,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn overlapping_partition_leases_resolve_identically() {
        let lease_a = EditorLease {
            lease_id: LeaseId::from("lease-a"),
            holder_id: PeerId::from("alice"),
            issued_at_ms: 10,
            expires_at_ms: 100,
            released_at_ms: None,
        };
        let lease_b = EditorLease {
            lease_id: LeaseId::from("lease-b"),
            holder_id: PeerId::from("bob"),
            issued_at_ms: 10,
            expires_at_ms: 100,
            released_at_ms: None,
        };
        let mut left = DocumentState::default();
        let mut right = DocumentState::default();
        left.apply_lease_event(&LeaseEvent::Acquired {
            lease: lease_a.clone(),
        })
        .unwrap();
        left.apply_lease_event(&LeaseEvent::Acquired {
            lease: lease_b.clone(),
        })
        .unwrap();
        right
            .apply_lease_event(&LeaseEvent::Acquired { lease: lease_b })
            .unwrap();
        right
            .apply_lease_event(&LeaseEvent::Acquired { lease: lease_a })
            .unwrap();
        assert_eq!(left.active_lease(50), right.active_lease(50));
        assert_eq!(
            left.active_lease(50).unwrap().holder_id,
            PeerId::from("alice")
        );
    }

    #[test]
    fn divergent_revisions_keep_losing_tip_as_conflict_copy() {
        let mut state = DocumentState::default();
        let root = DocumentRevision::new(
            RevisionId::from("root"),
            None,
            PeerId::from("alice"),
            1,
            "# Trip".into(),
        );
        state.insert_revision(root).unwrap();
        state
            .insert_revision(DocumentRevision::new(
                RevisionId::from("left"),
                Some(RevisionId::from("root")),
                PeerId::from("alice"),
                2,
                "left plan".into(),
            ))
            .unwrap();
        state
            .insert_revision(DocumentRevision::new(
                RevisionId::from("right"),
                Some(RevisionId::from("root")),
                PeerId::from("bob"),
                3,
                "right plan".into(),
            ))
            .unwrap();
        let snapshot = state.snapshot(4);
        assert_eq!(snapshot.content, "right plan");
        assert_eq!(snapshot.conflict_revisions.len(), 1);
        assert_eq!(snapshot.conflict_revisions[0].markdown, "left plan");
    }
}
