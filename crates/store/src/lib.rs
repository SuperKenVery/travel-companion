//! SQLite-backed immutable event log. SQLite access remains behind this crate;
//! feature crates never synchronize mutable rows directly.

use model::{EventEnvelope, EventId, PeerId, SequenceSummary, SignedEvent, SyncDigest};
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("SQLite operation failed: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("event serialization failed: {0}")]
    Json(#[from] serde_json::Error),
    #[error("event id or sender sequence conflicts with different immutable content")]
    ImmutableConflict,
    #[error("local event builder returned sender/sequence inconsistent with transaction")]
    InvalidLocalSequence,
    #[error("signed event metadata does not match its authenticated event bytes")]
    InvalidSignedEvent,
    #[error("integer value does not fit SQLite representation")]
    IntegerRange,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InsertOutcome {
    Inserted,
    Duplicate,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct StoredDeliveryInfo {
    pub targets: BTreeSet<PeerId>,
    pub acknowledged_targets: BTreeSet<PeerId>,
    pub replica_holders: BTreeSet<PeerId>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredAck {
    pub event_id: EventId,
    pub member_id: PeerId,
}

pub struct EventStore {
    connection: Connection,
}

impl EventStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, StoreError> {
        let connection = Connection::open(path)?;
        Self::from_connection(connection)
    }

    pub fn in_memory() -> Result<Self, StoreError> {
        Self::from_connection(Connection::open_in_memory()?)
    }

    fn from_connection(connection: Connection) -> Result<Self, StoreError> {
        let schema_version =
            connection.pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))?;
        if schema_version != 2 {
            connection.execute_batch(
                "DROP TABLE IF EXISTS event_targets;
                 DROP TABLE IF EXISTS persisted_acks;
                 DROP TABLE IF EXISTS replica_holders;
                 DROP TABLE IF EXISTS materialized_events;
                 DROP TABLE IF EXISTS events;
                 DROP TABLE IF EXISTS sender_sequences;",
            )?;
        }
        connection.execute_batch(
            "PRAGMA foreign_keys = ON;
             CREATE TABLE IF NOT EXISTS sender_sequences (
               sender_id TEXT PRIMARY KEY NOT NULL,
               next_sequence INTEGER NOT NULL
             );
             CREATE TABLE IF NOT EXISTS events (
               event_id TEXT PRIMARY KEY NOT NULL,
               group_id TEXT NOT NULL,
               group_epoch INTEGER NOT NULL,
               sender_id TEXT NOT NULL,
               sender_sequence INTEGER NOT NULL,
               logical_physical_ms INTEGER NOT NULL,
               logical_counter INTEGER NOT NULL,
               signed_event_json BLOB NOT NULL,
               UNIQUE(sender_id, sender_sequence)
             );
             CREATE INDEX IF NOT EXISTS events_group_sender_sequence
               ON events(group_id, group_epoch, sender_id, sender_sequence);
             CREATE TABLE IF NOT EXISTS event_targets (
               event_id TEXT NOT NULL REFERENCES events(event_id) ON DELETE CASCADE,
               member_id TEXT NOT NULL,
               PRIMARY KEY(event_id, member_id)
             );
             CREATE TABLE IF NOT EXISTS persisted_acks (
               event_id TEXT NOT NULL,
               member_id TEXT NOT NULL,
               PRIMARY KEY(event_id, member_id)
             );
             CREATE TABLE IF NOT EXISTS replica_holders (
               event_id TEXT NOT NULL,
               member_id TEXT NOT NULL,
               PRIMARY KEY(event_id, member_id)
             );
             CREATE TABLE IF NOT EXISTS materialized_events (
               projection TEXT NOT NULL,
               event_id TEXT NOT NULL,
               PRIMARY KEY(projection, event_id)
             );
             CREATE TABLE IF NOT EXISTS app_state (
               state_key TEXT PRIMARY KEY NOT NULL,
               state_json BLOB NOT NULL
             );
             PRAGMA user_version = 2;",
        )?;
        Ok(Self { connection })
    }

    /// Allocates a sender sequence and inserts the signed immutable event in
    /// one transaction. If building/inserting fails, the sequence is not spent.
    pub fn publish_local<F>(
        &mut self,
        sender: &PeerId,
        builder: F,
    ) -> Result<SignedEvent, StoreError>
    where
        F: FnOnce(u64) -> Result<(EventEnvelope, SignedEvent), StoreError>,
    {
        let transaction = self.connection.transaction()?;
        let sequence = transaction
            .query_row(
                "SELECT next_sequence FROM sender_sequences WHERE sender_id = ?1",
                params![sender.as_str()],
                |row| row.get::<_, i64>(0),
            )
            .optional()?
            .unwrap_or(1);
        let sequence = u64::try_from(sequence).map_err(|_| StoreError::IntegerRange)?;
        let (event, signed) = builder(sequence)?;
        if &event.sender_id != sender || event.sender_sequence != sequence {
            return Err(StoreError::InvalidLocalSequence);
        }
        insert_event_transaction(&transaction, &event, &signed)?;
        let next = sequence.checked_add(1).ok_or(StoreError::IntegerRange)?;
        transaction.execute(
            "INSERT INTO sender_sequences(sender_id, next_sequence) VALUES(?1, ?2)
             ON CONFLICT(sender_id) DO UPDATE SET next_sequence = excluded.next_sequence",
            params![sender.as_str(), to_i64(next)?],
        )?;
        transaction.commit()?;
        Ok(signed)
    }

    pub fn insert_remote(
        &mut self,
        event: &EventEnvelope,
        signed: &SignedEvent,
    ) -> Result<InsertOutcome, StoreError> {
        let transaction = self.connection.transaction()?;
        let outcome = insert_event_transaction(&transaction, event, signed)?;
        transaction.commit()?;
        Ok(outcome)
    }

    pub fn get(&self, event_id: &EventId) -> Result<Option<EventEnvelope>, StoreError> {
        self.get_signed(event_id)?
            .map(|signed| signed.decode_event().map_err(StoreError::from))
            .transpose()
    }

    pub fn get_signed(&self, event_id: &EventId) -> Result<Option<SignedEvent>, StoreError> {
        self.connection
            .query_row(
                "SELECT signed_event_json FROM events WHERE event_id = ?1",
                params![event_id.as_str()],
                |row| row.get::<_, Vec<u8>>(0),
            )
            .optional()?
            .map(|bytes| serde_json::from_slice(&bytes).map_err(StoreError::from))
            .transpose()
    }

    pub fn all_events(&self) -> Result<Vec<EventEnvelope>, StoreError> {
        self.all_signed_events()?
            .into_iter()
            .map(|signed| signed.decode_event().map_err(StoreError::from))
            .collect()
    }

    pub fn all_signed_events(&self) -> Result<Vec<SignedEvent>, StoreError> {
        let mut statement = self.connection.prepare(
            "SELECT signed_event_json FROM events
             ORDER BY logical_physical_ms, logical_counter, sender_id, sender_sequence",
        )?;
        let rows = statement.query_map([], |row| row.get::<_, Vec<u8>>(0))?;
        rows.map(|row| {
            let bytes = row?;
            serde_json::from_slice(&bytes).map_err(StoreError::from)
        })
        .collect()
    }

    pub fn event_count(&self) -> Result<usize, StoreError> {
        let count = self
            .connection
            .query_row("SELECT COUNT(*) FROM events", [], |row| {
                row.get::<_, i64>(0)
            })?;
        usize::try_from(count).map_err(|_| StoreError::IntegerRange)
    }

    pub fn load_state<T: serde::de::DeserializeOwned>(
        &self,
        key: &str,
    ) -> Result<Option<T>, StoreError> {
        self.connection
            .query_row(
                "SELECT state_json FROM app_state WHERE state_key = ?1",
                params![key],
                |row| row.get::<_, Vec<u8>>(0),
            )
            .optional()?
            .map(|bytes| serde_json::from_slice(&bytes).map_err(StoreError::from))
            .transpose()
    }

    pub fn save_state<T: serde::Serialize>(
        &mut self,
        key: &str,
        value: &T,
    ) -> Result<(), StoreError> {
        let bytes = serde_json::to_vec(value)?;
        self.connection.execute(
            "INSERT INTO app_state(state_key, state_json) VALUES(?1, ?2)
             ON CONFLICT(state_key) DO UPDATE SET state_json = excluded.state_json",
            params![key, bytes],
        )?;
        Ok(())
    }

    pub fn digest(&self, group_epoch: u64) -> Result<SyncDigest, StoreError> {
        let mut statement = self.connection.prepare(
            "SELECT sender_id, sender_sequence FROM events
             WHERE group_epoch = ?1 ORDER BY sender_id, sender_sequence",
        )?;
        let rows = statement.query_map(params![to_i64(group_epoch)?], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
        })?;
        let mut sequences: BTreeMap<PeerId, Vec<u64>> = BTreeMap::new();
        for row in rows {
            let (sender, sequence) = row?;
            sequences
                .entry(PeerId::from_string(sender))
                .or_default()
                .push(u64::try_from(sequence).map_err(|_| StoreError::IntegerRange)?);
        }
        let senders = sequences
            .into_iter()
            .map(|(sender, sequences)| (sender, summarize(&sequences)))
            .collect();
        Ok(SyncDigest {
            group_epoch,
            senders,
        })
    }

    pub fn events_missing_from(&self, remote: &SyncDigest) -> Result<Vec<SignedEvent>, StoreError> {
        let events = self.all_signed_events()?;
        events
            .into_iter()
            .map(|signed| {
                let event = signed.decode_event()?;
                Ok((event, signed))
            })
            .filter_map(|result: Result<_, StoreError>| match result {
                Ok((event, signed))
                    if event.group_epoch == remote.group_epoch
                        && !remote
                            .senders
                            .get(&event.sender_id)
                            .is_some_and(|summary| summary.contains(event.sender_sequence)) =>
                {
                    Some(Ok(signed))
                }
                Ok(_) => None,
                Err(error) => Some(Err(error)),
            })
            .collect()
    }

    pub fn mark_materialized(
        &mut self,
        projection: &str,
        event_id: &EventId,
    ) -> Result<bool, StoreError> {
        Ok(self.connection.execute(
            "INSERT OR IGNORE INTO materialized_events(projection, event_id) VALUES(?1, ?2)",
            params![projection, event_id.as_str()],
        )? == 1)
    }

    pub fn record_ack(&mut self, event_id: &EventId, member: &PeerId) -> Result<(), StoreError> {
        self.connection.execute(
            "INSERT OR IGNORE INTO persisted_acks(event_id, member_id) VALUES(?1, ?2)",
            params![event_id.as_str(), member.as_str()],
        )?;
        Ok(())
    }

    pub fn record_replica(
        &mut self,
        event_id: &EventId,
        member: &PeerId,
    ) -> Result<(), StoreError> {
        self.connection.execute(
            "INSERT OR IGNORE INTO replica_holders(event_id, member_id) VALUES(?1, ?2)",
            params![event_id.as_str(), member.as_str()],
        )?;
        Ok(())
    }

    pub fn all_acks(&self) -> Result<Vec<StoredAck>, StoreError> {
        let mut statement = self.connection.prepare(
            "SELECT event_id, member_id FROM persisted_acks ORDER BY event_id, member_id",
        )?;
        let acknowledgements = statement
            .query_map([], |row| {
                Ok(StoredAck {
                    event_id: EventId::from_string(row.get::<_, String>(0)?),
                    member_id: PeerId::from_string(row.get::<_, String>(1)?),
                })
            })?
            .collect::<Result<Vec<_>, _>>()
            .map_err(StoreError::from)?;
        Ok(acknowledgements)
    }

    pub fn delivery_info(&self, event_id: &EventId) -> Result<StoredDeliveryInfo, StoreError> {
        Ok(StoredDeliveryInfo {
            targets: query_peer_set(
                &self.connection,
                "SELECT member_id FROM event_targets WHERE event_id = ?1",
                event_id,
            )?,
            acknowledged_targets: query_peer_set(
                &self.connection,
                "SELECT member_id FROM persisted_acks WHERE event_id = ?1",
                event_id,
            )?,
            replica_holders: query_peer_set(
                &self.connection,
                "SELECT member_id FROM replica_holders WHERE event_id = ?1",
                event_id,
            )?,
        })
    }

    /// Removes group-synchronized application data while preserving the
    /// installation identity and other local-only state held by the caller.
    /// All related tables are cleared in one transaction so a crash cannot
    /// leave delivery metadata referring to events that no longer exist.
    pub fn clear_synchronized_data(&mut self) -> Result<(), StoreError> {
        let transaction = self.connection.transaction()?;
        transaction.execute("DELETE FROM persisted_acks", [])?;
        transaction.execute("DELETE FROM replica_holders", [])?;
        transaction.execute("DELETE FROM materialized_events", [])?;
        transaction.execute("DELETE FROM events", [])?;
        transaction.execute("DELETE FROM sender_sequences", [])?;
        transaction.commit()?;
        Ok(())
    }
}

fn insert_event_transaction(
    transaction: &Transaction<'_>,
    event: &EventEnvelope,
    signed: &SignedEvent,
) -> Result<InsertOutcome, StoreError> {
    let decoded = signed.decode_event()?;
    if signed.signer_id != event.sender_id
        || decoded.id != event.id
        || decoded.group_id != event.group_id
        || decoded.group_epoch != event.group_epoch
        || decoded.sender_id != event.sender_id
        || decoded.sender_sequence != event.sender_sequence
    {
        return Err(StoreError::InvalidSignedEvent);
    }
    let bytes = serde_json::to_vec(signed)?;
    let by_id = transaction
        .query_row(
            "SELECT signed_event_json FROM events WHERE event_id = ?1",
            params![event.id.as_str()],
            |row| row.get::<_, Vec<u8>>(0),
        )
        .optional()?;
    if let Some(existing) = by_id {
        return if existing == bytes {
            Ok(InsertOutcome::Duplicate)
        } else {
            Err(StoreError::ImmutableConflict)
        };
    }
    let by_sequence = transaction
        .query_row(
            "SELECT event_id FROM events WHERE sender_id = ?1 AND sender_sequence = ?2",
            params![event.sender_id.as_str(), to_i64(event.sender_sequence)?],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    if by_sequence.is_some() {
        return Err(StoreError::ImmutableConflict);
    }

    transaction.execute(
        "INSERT INTO events(
           event_id, group_id, group_epoch, sender_id, sender_sequence,
           logical_physical_ms, logical_counter, signed_event_json
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        params![
            event.id.as_str(),
            event.group_id.as_str(),
            to_i64(event.group_epoch)?,
            event.sender_id.as_str(),
            to_i64(event.sender_sequence)?,
            event.logical_clock.physical_ms,
            i64::from(event.logical_clock.logical),
            bytes,
        ],
    )?;
    for target in &event.target_members {
        transaction.execute(
            "INSERT INTO event_targets(event_id, member_id) VALUES(?1, ?2)",
            params![event.id.as_str(), target.as_str()],
        )?;
    }
    Ok(InsertOutcome::Inserted)
}

fn summarize(sequences: &[u64]) -> SequenceSummary {
    let max_seen = sequences.last().copied().unwrap_or(0);
    let present: BTreeSet<_> = sequences.iter().copied().collect();
    let contiguous_frontier = (1..=max_seen)
        .find(|sequence| !present.contains(sequence))
        .map_or(max_seen, |first_gap| first_gap.saturating_sub(1));
    let gaps = ((contiguous_frontier + 1)..=max_seen)
        .filter(|sequence| !present.contains(sequence))
        .collect();
    SequenceSummary {
        contiguous_frontier,
        max_seen,
        gaps,
    }
}

fn query_peer_set(
    connection: &Connection,
    sql: &str,
    event_id: &EventId,
) -> Result<BTreeSet<PeerId>, StoreError> {
    let mut statement = connection.prepare(sql)?;
    let peers = statement
        .query_map(params![event_id.as_str()], |row| row.get::<_, String>(0))?
        .map(|row| row.map(PeerId::from_string).map_err(StoreError::from))
        .collect::<Result<BTreeSet<_>, _>>()?;
    Ok(peers)
}

fn to_i64(value: u64) -> Result<i64, StoreError> {
    i64::try_from(value).map_err(|_| StoreError::IntegerRange)
}

#[cfg(test)]
mod tests {
    use super::*;
    use model::{DeliveryPolicy, EventId, GroupAudience, GroupId, HlcTimestamp};

    fn event(sender: &str, sequence: u64, id: &str) -> (EventEnvelope, SignedEvent) {
        let event = EventEnvelope {
            id: EventId::from(id),
            group_id: GroupId::from("g"),
            group_epoch: 1,
            sender_id: PeerId::from(sender),
            sender_sequence: sequence,
            logical_clock: HlcTimestamp {
                physical_ms: sequence as i64,
                logical: 0,
                node: PeerId::from(sender),
            },
            audience: GroupAudience::Group,
            target_members: [PeerId::from("target")].into_iter().collect(),
            event_type: "test".into(),
            delivery_policy: DeliveryPolicy::Durable,
            created_at_ms: 0,
            payload: serde_json::json!({"sequence": sequence}),
        };
        let signed = SignedEvent {
            signer_id: event.sender_id.clone(),
            event_bytes: serde_json::to_vec(&event).unwrap(),
            signature: vec![1],
        };
        (event, signed)
    }

    #[test]
    fn duplicate_is_idempotent_but_sequence_fork_is_rejected() {
        let mut store = EventStore::in_memory().unwrap();
        let first = event("a", 1, "one");
        assert_eq!(
            store.insert_remote(&first.0, &first.1).unwrap(),
            InsertOutcome::Inserted
        );
        assert_eq!(
            store.insert_remote(&first.0, &first.1).unwrap(),
            InsertOutcome::Duplicate
        );
        assert_eq!(store.event_count().unwrap(), 1);
        let fork = event("a", 1, "fork");
        assert!(matches!(
            store.insert_remote(&fork.0, &fork.1),
            Err(StoreError::ImmutableConflict)
        ));
    }

    #[test]
    fn digest_keeps_exact_sparse_gaps() {
        let mut store = EventStore::in_memory().unwrap();
        for candidate in [
            event("a", 1, "one"),
            event("a", 3, "three"),
            event("a", 5, "five"),
        ] {
            store.insert_remote(&candidate.0, &candidate.1).unwrap();
        }
        let summary = &store.digest(1).unwrap().senders[&PeerId::from("a")];
        assert_eq!(summary.contiguous_frontier, 1);
        assert_eq!(summary.max_seen, 5);
        assert_eq!(summary.gaps, [2, 4].into_iter().collect());
    }

    #[test]
    fn local_sequence_and_insert_are_atomic() {
        let mut store = EventStore::in_memory().unwrap();
        let sender = PeerId::from("a");
        let first = store
            .publish_local(&sender, |sequence| Ok(event("a", sequence, "one")))
            .unwrap();
        let second = store
            .publish_local(&sender, |sequence| Ok(event("a", sequence, "two")))
            .unwrap();
        assert_eq!(
            (
                first.decode_event().unwrap().sender_sequence,
                second.decode_event().unwrap().sender_sequence,
            ),
            (1, 2)
        );
    }

    #[test]
    fn clearing_synchronized_data_is_atomic_and_resets_sequences() {
        let mut store = EventStore::in_memory().unwrap();
        let sender = PeerId::from("a");
        let published = store
            .publish_local(&sender, |sequence| Ok(event("a", sequence, "one")))
            .unwrap();
        let published_event = published.decode_event().unwrap();
        store
            .record_ack(&published_event.id, &PeerId::from("target"))
            .unwrap();
        store
            .record_replica(&published_event.id, &PeerId::from("relay"))
            .unwrap();
        store.mark_materialized("im", &published_event.id).unwrap();

        store.clear_synchronized_data().unwrap();

        assert_eq!(store.event_count().unwrap(), 0);
        assert!(store.all_acks().unwrap().is_empty());
        let republished = store
            .publish_local(&sender, |sequence| Ok(event("a", sequence, "two")))
            .unwrap();
        assert_eq!(republished.decode_event().unwrap().sender_sequence, 1);
    }
}
