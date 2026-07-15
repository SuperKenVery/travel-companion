//! PIN-authenticated group admission and epoch credentials.
//!
//! The one-time PIN feeds SPAKE2 and is never reused as a long-term group key.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use spake2::{Ed25519Group, Identity, Password, Spake2};
use std::collections::BTreeMap;
use tc_crypto::{derive_key, sha256, CryptoError, SecretKeyMaterial};
use tc_model::{GroupId, PeerId};
use thiserror::Error;
use zeroize::{Zeroize, Zeroizing};

#[derive(Debug, Error)]
pub enum GroupAuthError {
    #[error("PIN handshake failed")]
    HandshakeFailed,
    #[error("handshake was already completed")]
    AlreadyCompleted,
    #[error("transcript confirmation did not match")]
    TranscriptMismatch,
    #[error("only the group owner may change membership")]
    NotOwner,
    #[error("cryptographic operation failed: {0}")]
    Crypto(#[from] CryptoError),
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JoinHello {
    pub group_id: GroupId,
    pub epoch: u64,
    pub peer_id: PeerId,
    pub spake_message: Vec<u8>,
}

pub struct PinHandshake {
    state: Option<Spake2<Ed25519Group>>,
    local_message: Vec<u8>,
    group_id: GroupId,
    epoch: u64,
    local_peer: PeerId,
    remote_peer: PeerId,
}

impl PinHandshake {
    #[must_use]
    pub fn start_inviter(
        group_id: GroupId,
        epoch: u64,
        inviter: PeerId,
        joiner: PeerId,
        pin: &str,
    ) -> (Self, JoinHello) {
        Self::start(true, group_id, epoch, inviter, joiner, pin)
    }

    #[must_use]
    pub fn start_joiner(
        group_id: GroupId,
        epoch: u64,
        joiner: PeerId,
        inviter: PeerId,
        pin: &str,
    ) -> (Self, JoinHello) {
        Self::start(false, group_id, epoch, joiner, inviter, pin)
    }

    fn start(
        is_inviter: bool,
        group_id: GroupId,
        epoch: u64,
        local_peer: PeerId,
        remote_peer: PeerId,
        pin: &str,
    ) -> (Self, JoinHello) {
        let mut pin_bytes = Zeroizing::new(pin.as_bytes().to_vec());
        let password = Password::new(&pin_bytes);
        let inviter_id = if is_inviter {
            local_peer.as_str()
        } else {
            remote_peer.as_str()
        };
        let joiner_id = if is_inviter {
            remote_peer.as_str()
        } else {
            local_peer.as_str()
        };
        let inviter_identity = Identity::new(inviter_id.as_bytes());
        let joiner_identity = Identity::new(joiner_id.as_bytes());
        let (state, local_message) = if is_inviter {
            Spake2::<Ed25519Group>::start_a(&password, &inviter_identity, &joiner_identity)
        } else {
            Spake2::<Ed25519Group>::start_b(&password, &inviter_identity, &joiner_identity)
        };
        pin_bytes.zeroize();
        let hello = JoinHello {
            group_id: group_id.clone(),
            epoch,
            peer_id: local_peer.clone(),
            spake_message: local_message.clone(),
        };
        (
            Self {
                state: Some(state),
                local_message,
                group_id,
                epoch,
                local_peer,
                remote_peer,
            },
            hello,
        )
    }

    pub fn finish(mut self, remote: &JoinHello) -> Result<PinSession, GroupAuthError> {
        if remote.group_id != self.group_id
            || remote.epoch != self.epoch
            || remote.peer_id != self.remote_peer
        {
            return Err(GroupAuthError::TranscriptMismatch);
        }
        let state = self.state.take().ok_or(GroupAuthError::AlreadyCompleted)?;
        let shared = Zeroizing::new(
            state
                .finish(&remote.spake_message)
                .map_err(|_| GroupAuthError::HandshakeFailed)?,
        );
        let key = derive_key(
            &shared,
            self.group_id.as_str().as_bytes(),
            format!("tc/join/epoch/{}", self.epoch).as_bytes(),
        )?;
        let mut transcript = Vec::new();
        transcript.extend_from_slice(self.group_id.as_str().as_bytes());
        transcript.extend_from_slice(&self.epoch.to_be_bytes());
        let local_is_a = self.local_peer < self.remote_peer;
        if local_is_a {
            transcript.extend_from_slice(&self.local_message);
            transcript.extend_from_slice(&remote.spake_message);
        } else {
            transcript.extend_from_slice(&remote.spake_message);
            transcript.extend_from_slice(&self.local_message);
        }
        Ok(PinSession {
            key,
            transcript_hash: sha256(&transcript),
        })
    }
}

#[derive(Clone, Debug)]
pub struct PinSession {
    pub key: SecretKeyMaterial,
    pub transcript_hash: [u8; 32],
}

impl PinSession {
    #[must_use]
    pub fn confirmation(&self, label: &[u8]) -> [u8; 32] {
        let mut hasher = Sha256::new();
        hasher.update(self.key.0);
        hasher.update(self.transcript_hash);
        hasher.update(label);
        hasher.finalize().into()
    }

    #[must_use]
    pub fn confirms(&self, label: &[u8], expected: &[u8; 32]) -> bool {
        constant_time_eq(&self.confirmation(label), expected)
    }
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    left.len() == right.len()
        && left
            .iter()
            .zip(right)
            .fold(0_u8, |different, (a, b)| different | (a ^ b))
            == 0
}

#[derive(Clone, Debug)]
pub struct GroupCredential {
    pub group_id: GroupId,
    pub epoch: u64,
    pub member_id: PeerId,
    pub group_key: SecretKeyMaterial,
}

#[derive(Clone, Debug)]
pub struct GroupAuthority {
    pub group_id: GroupId,
    pub epoch: u64,
    pub owner_id: PeerId,
    pub group_key: SecretKeyMaterial,
    pub members: BTreeMap<PeerId, [u8; 32]>,
}

impl GroupAuthority {
    #[must_use]
    pub fn create(owner_id: PeerId, owner_public_key: [u8; 32]) -> Self {
        let mut members = BTreeMap::new();
        members.insert(owner_id.clone(), owner_public_key);
        Self {
            group_id: GroupId::new(),
            epoch: 1,
            owner_id,
            group_key: SecretKeyMaterial::random(),
            members,
        }
    }

    pub fn add_member(
        &mut self,
        actor: &PeerId,
        peer: PeerId,
        public_key: [u8; 32],
    ) -> Result<(), GroupAuthError> {
        self.require_owner(actor)?;
        self.members.insert(peer, public_key);
        Ok(())
    }

    pub fn remove_member(&mut self, actor: &PeerId, peer: &PeerId) -> Result<(), GroupAuthError> {
        self.require_owner(actor)?;
        self.members.remove(peer);
        self.epoch = self.epoch.saturating_add(1);
        self.group_key = SecretKeyMaterial::random();
        Ok(())
    }

    fn require_owner(&self, actor: &PeerId) -> Result<(), GroupAuthError> {
        if actor == &self.owner_id {
            Ok(())
        } else {
            Err(GroupAuthError::NotOwner)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn same_pin_derives_matching_confirmations() {
        let group = GroupId::from("trip");
        let inviter = PeerId::from("alice");
        let joiner = PeerId::from("bob");
        let (a, hello_a) = PinHandshake::start_inviter(
            group.clone(),
            1,
            inviter.clone(),
            joiner.clone(),
            "492817",
        );
        let (b, hello_b) = PinHandshake::start_joiner(group, 1, joiner, inviter, "492817");
        let session_a = a.finish(&hello_b).unwrap();
        let session_b = b.finish(&hello_a).unwrap();
        assert_eq!(
            session_a.confirmation(b"inviter"),
            session_b.confirmation(b"inviter")
        );
    }

    #[test]
    fn wrong_pin_cannot_confirm_transcript() {
        let group = GroupId::from("trip");
        let inviter = PeerId::from("alice");
        let joiner = PeerId::from("bob");
        let (a, hello_a) = PinHandshake::start_inviter(
            group.clone(),
            1,
            inviter.clone(),
            joiner.clone(),
            "111111",
        );
        let (b, hello_b) = PinHandshake::start_joiner(group, 1, joiner, inviter, "222222");
        let session_a = a.finish(&hello_b).unwrap();
        let session_b = b.finish(&hello_a).unwrap();
        assert_ne!(
            session_a.confirmation(b"inviter"),
            session_b.confirmation(b"inviter")
        );
    }
}
