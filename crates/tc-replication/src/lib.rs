//! Opportunity-mesh replication for a small group of intermittently connected
//! devices. It deliberately implements no consensus, leader election, or
//! mutable-row synchronization.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use tc_crypto::{verify_signature, CryptoError, IdentityKeypair};
use tc_model::{
    DeliveryPolicy, EventEnvelope, EventId, GroupAudience, GroupId, HybridLogicalClock, PeerId,
    SyncDigest,
};
use tc_store::{EventStore, InsertOutcome, StoreError, StoredAck};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ReplicationError {
    #[error("event store operation failed: {0}")]
    Store(#[from] StoreError),
    #[error("event belongs to another group or epoch")]
    WrongGroupEpoch,
    #[error("sender does not have a registered verifying key")]
    UnknownSender,
    #[error("event signature failed verification: {0}")]
    Signature(#[from] CryptoError),
    #[error("event serialization failed: {0}")]
    Json(#[from] serde_json::Error),
    #[error("publication does not exist")]
    UnknownPublication,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Publication {
    pub event_id: EventId,
    pub sender_sequence: u64,
    pub persisted_locally: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IngestReceipt {
    pub event_id: EventId,
    pub holder: PeerId,
    pub inserted: bool,
    /// True only when `holder` is a frozen publication target. A relay receipt
    /// must never be interpreted as delivery.
    pub target_persisted: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum DeliveryPhase {
    PersistedLocally,
    ReplicatedToRelay,
    Delivered,
    Complete,
    Expired,
    PolicyEvicted,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeliveryState {
    pub phase: DeliveryPhase,
    pub relay_count: usize,
    pub delivered_members: BTreeSet<PeerId>,
    pub pending_members: BTreeSet<PeerId>,
}

pub struct ReplicationEngine {
    local_peer: PeerId,
    group_id: GroupId,
    group_epoch: u64,
    members: BTreeSet<PeerId>,
    identity: IdentityKeypair,
    verifying_keys: BTreeMap<PeerId, [u8; 32]>,
    clock: HybridLogicalClock,
    store: EventStore,
}

impl ReplicationEngine {
    pub fn in_memory(
        local_peer: PeerId,
        group_id: GroupId,
        group_epoch: u64,
        members: BTreeSet<PeerId>,
        identity: IdentityKeypair,
    ) -> Result<Self, ReplicationError> {
        Ok(Self::new(
            local_peer,
            group_id,
            group_epoch,
            members,
            identity,
            EventStore::in_memory()?,
        ))
    }

    #[must_use]
    pub fn new(
        local_peer: PeerId,
        group_id: GroupId,
        group_epoch: u64,
        members: BTreeSet<PeerId>,
        identity: IdentityKeypair,
        store: EventStore,
    ) -> Self {
        let mut verifying_keys = BTreeMap::new();
        verifying_keys.insert(local_peer.clone(), identity.public_key_bytes());
        Self {
            clock: HybridLogicalClock::new(local_peer.clone(), 0),
            local_peer,
            group_id,
            group_epoch,
            members,
            identity,
            verifying_keys,
            store,
        }
    }

    #[must_use]
    pub fn local_peer(&self) -> &PeerId {
        &self.local_peer
    }

    #[must_use]
    pub fn public_key(&self) -> [u8; 32] {
        self.identity.public_key_bytes()
    }

    pub fn register_peer_key(&mut self, peer: PeerId, public_key: [u8; 32]) {
        self.verifying_keys.insert(peer, public_key);
    }

    pub fn publish(
        &mut self,
        event_type: impl Into<String>,
        payload: serde_json::Value,
        audience: GroupAudience,
        policy: DeliveryPolicy,
        now_ms: i64,
    ) -> Result<Publication, ReplicationError> {
        let target_members = self.resolve_targets(&audience);
        let id = EventId::new();
        let logical_clock = self.clock.tick(now_ms);
        let sender = self.local_peer.clone();
        let group_id = self.group_id.clone();
        let group_epoch = self.group_epoch;
        let event_type = event_type.into();
        let identity = &self.identity;
        let event = self.store.publish_local(&sender, |sender_sequence| {
            let mut event = EventEnvelope {
                id,
                group_id,
                group_epoch,
                sender_id: sender.clone(),
                sender_sequence,
                logical_clock,
                audience,
                target_members,
                event_type,
                delivery_policy: policy,
                created_at_ms: now_ms,
                payload,
                signature: Vec::new(),
            };
            let bytes = event.signing_bytes()?;
            event.signature = identity.sign(&bytes);
            Ok(event)
        })?;
        Ok(Publication {
            event_id: event.id,
            sender_sequence: event.sender_sequence,
            persisted_locally: true,
        })
    }

    pub fn ingest(&mut self, event: &EventEnvelope) -> Result<IngestReceipt, ReplicationError> {
        if event.group_id != self.group_id || event.group_epoch != self.group_epoch {
            return Err(ReplicationError::WrongGroupEpoch);
        }
        let public_key = self
            .verifying_keys
            .get(&event.sender_id)
            .ok_or(ReplicationError::UnknownSender)?;
        verify_signature(public_key, &event.signing_bytes()?, &event.signature)?;
        self.clock
            .observe(&event.logical_clock, event.created_at_ms);
        let inserted = self.store.insert_remote(event)? == InsertOutcome::Inserted;
        let target_persisted = event.target_members.contains(&self.local_peer);
        if target_persisted {
            self.store.record_ack(&event.id, &self.local_peer)?;
        }
        Ok(IngestReceipt {
            event_id: event.id.clone(),
            holder: self.local_peer.clone(),
            inserted,
            target_persisted,
        })
    }

    pub fn apply_receipt(&mut self, receipt: &IngestReceipt) -> Result<(), ReplicationError> {
        self.store
            .record_replica(&receipt.event_id, &receipt.holder)?;
        if receipt.target_persisted {
            self.store.record_ack(&receipt.event_id, &receipt.holder)?;
        }
        Ok(())
    }

    pub fn apply_ack(&mut self, ack: &StoredAck) -> Result<(), ReplicationError> {
        self.store.record_ack(&ack.event_id, &ack.member_id)?;
        Ok(())
    }

    pub fn digest(&self) -> Result<SyncDigest, ReplicationError> {
        Ok(self.store.digest(self.group_epoch)?)
    }

    pub fn events_missing_from(
        &self,
        remote: &SyncDigest,
    ) -> Result<Vec<EventEnvelope>, ReplicationError> {
        if remote.group_epoch != self.group_epoch {
            return Err(ReplicationError::WrongGroupEpoch);
        }
        Ok(self.store.events_missing_from(remote)?)
    }

    pub fn all_acks(&self) -> Result<Vec<StoredAck>, ReplicationError> {
        Ok(self.store.all_acks()?)
    }

    pub fn all_events(&self) -> Result<Vec<EventEnvelope>, ReplicationError> {
        Ok(self.store.all_events()?)
    }

    pub fn event(&self, event_id: &EventId) -> Result<Option<EventEnvelope>, ReplicationError> {
        Ok(self.store.get(event_id)?)
    }

    pub fn event_count(&self) -> Result<usize, ReplicationError> {
        Ok(self.store.event_count()?)
    }

    pub fn delivery_state(
        &self,
        event_id: &EventId,
        now_ms: i64,
    ) -> Result<DeliveryState, ReplicationError> {
        let event = self
            .store
            .get(event_id)?
            .ok_or(ReplicationError::UnknownPublication)?;
        let info = self.store.delivery_info(event_id)?;
        let delivered_members = info
            .acknowledged_targets
            .intersection(&info.targets)
            .cloned()
            .collect::<BTreeSet<_>>();
        let pending_members = info
            .targets
            .difference(&delivered_members)
            .cloned()
            .collect::<BTreeSet<_>>();
        let relay_count = info
            .replica_holders
            .difference(&info.targets)
            .filter(|peer| *peer != &self.local_peer)
            .count();
        let phase = if pending_members.is_empty() {
            DeliveryPhase::Complete
        } else if event.is_expired_at(now_ms) {
            DeliveryPhase::Expired
        } else if !delivered_members.is_empty() {
            DeliveryPhase::Delivered
        } else if relay_count > 0 {
            DeliveryPhase::ReplicatedToRelay
        } else {
            DeliveryPhase::PersistedLocally
        };
        Ok(DeliveryState {
            phase,
            relay_count,
            delivered_members,
            pending_members,
        })
    }

    fn resolve_targets(&self, audience: &GroupAudience) -> BTreeSet<PeerId> {
        let mut targets = match audience {
            GroupAudience::Group => self.members.clone(),
            GroupAudience::Recipients { members } => members
                .intersection(&self.members)
                .cloned()
                .collect::<BTreeSet<_>>(),
        };
        targets.remove(&self.local_peer);
        targets
    }
}

/// Performs one symmetric anti-entropy exchange. The function intentionally
/// has no transport dependency and can be called after any reconnect.
pub fn anti_entropy_pair(
    left: &mut ReplicationEngine,
    right: &mut ReplicationEngine,
) -> Result<(), ReplicationError> {
    let left_digest = left.digest()?;
    let right_digest = right.digest()?;
    let left_to_right = left.events_missing_from(&right_digest)?;
    let right_to_left = right.events_missing_from(&left_digest)?;

    for event in left_to_right {
        let receipt = right.ingest(&event)?;
        left.apply_receipt(&receipt)?;
    }
    for event in right_to_left {
        let receipt = left.ingest(&event)?;
        right.apply_receipt(&receipt)?;
    }

    // Persisted target acknowledgements are themselves store-and-forward facts.
    let mut acknowledgements = left.all_acks()?;
    acknowledgements.extend(right.all_acks()?);
    for ack in &acknowledgements {
        left.apply_ack(ack)?;
        right.apply_ack(ack)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn engines() -> (ReplicationEngine, ReplicationEngine, ReplicationEngine) {
        let peers: BTreeSet<_> = ["a", "b", "c"].into_iter().map(PeerId::from).collect();
        let group = GroupId::from("trip");
        let mut a = ReplicationEngine::in_memory(
            PeerId::from("a"),
            group.clone(),
            1,
            peers.clone(),
            IdentityKeypair::generate(),
        )
        .unwrap();
        let mut b = ReplicationEngine::in_memory(
            PeerId::from("b"),
            group.clone(),
            1,
            peers.clone(),
            IdentityKeypair::generate(),
        )
        .unwrap();
        let mut c = ReplicationEngine::in_memory(
            PeerId::from("c"),
            group,
            1,
            peers,
            IdentityKeypair::generate(),
        )
        .unwrap();
        let keys = [
            (PeerId::from("a"), a.public_key()),
            (PeerId::from("b"), b.public_key()),
            (PeerId::from("c"), c.public_key()),
        ];
        for (peer, key) in &keys {
            a.register_peer_key(peer.clone(), *key);
            b.register_peer_key(peer.clone(), *key);
            c.register_peer_key(peer.clone(), *key);
        }
        (a, b, c)
    }

    #[test]
    fn relay_copy_is_not_target_delivery() {
        let (mut a, mut b, mut c) = engines();
        let publication = a
            .publish(
                "im.message.sent",
                json!({"text": "meet here"}),
                GroupAudience::Recipients {
                    members: [PeerId::from("c")].into_iter().collect(),
                },
                DeliveryPolicy::Durable,
                10,
            )
            .unwrap();

        anti_entropy_pair(&mut a, &mut b).unwrap();
        let relayed = a.delivery_state(&publication.event_id, 11).unwrap();
        assert_eq!(relayed.phase, DeliveryPhase::ReplicatedToRelay);
        assert_eq!(relayed.relay_count, 1);
        assert!(relayed.delivered_members.is_empty());

        // A and C are partitioned. B physically meets C, then later A.
        anti_entropy_pair(&mut b, &mut c).unwrap();
        anti_entropy_pair(&mut a, &mut b).unwrap();
        let delivered = a.delivery_state(&publication.event_id, 12).unwrap();
        assert_eq!(delivered.phase, DeliveryPhase::Complete);
        assert_eq!(
            delivered.delivered_members,
            [PeerId::from("c")].into_iter().collect()
        );
    }

    #[test]
    fn partition_heals_by_symmetric_digest_exchange() {
        let (mut a, mut b, _) = engines();
        a.publish(
            "place.created",
            json!({"id": "p1"}),
            GroupAudience::Group,
            DeliveryPolicy::Durable,
            1,
        )
        .unwrap();
        b.publish(
            "document.revision",
            json!({"id": "r1"}),
            GroupAudience::Group,
            DeliveryPolicy::Durable,
            2,
        )
        .unwrap();
        assert_eq!(a.event_count().unwrap(), 1);
        assert_eq!(b.event_count().unwrap(), 1);
        anti_entropy_pair(&mut a, &mut b).unwrap();
        assert_eq!(a.event_count().unwrap(), 2);
        assert_eq!(b.event_count().unwrap(), 2);
        anti_entropy_pair(&mut a, &mut b).unwrap();
        assert_eq!(a.event_count().unwrap(), 2, "reconnect remains idempotent");
    }

    #[test]
    fn precise_digest_requests_an_event_below_max_seen_gap() {
        let (mut a, mut b, _) = engines();
        for index in 0..3 {
            a.publish(
                "test",
                json!({"index": index}),
                GroupAudience::Group,
                DeliveryPolicy::Durable,
                index,
            )
            .unwrap();
        }
        let events = a.all_events().unwrap();
        b.ingest(&events[0]).unwrap();
        b.ingest(&events[2]).unwrap();
        let missing = a.events_missing_from(&b.digest().unwrap()).unwrap();
        assert_eq!(missing.len(), 1);
        assert_eq!(missing[0].sender_sequence, 2);
    }
}
