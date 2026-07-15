//! Auditable cryptographic primitives. Protocol crates compose these; they do
//! not invent feature-specific cryptography.

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use hkdf::Hkdf;
use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use zeroize::{Zeroize, ZeroizeOnDrop};

pub const KEY_LEN: usize = 32;

#[derive(Debug, Error)]
pub enum CryptoError {
    #[error("signature is malformed or invalid")]
    InvalidSignature,
    #[error("public key is malformed")]
    InvalidPublicKey,
    #[error("authenticated decryption failed")]
    DecryptionFailed,
    #[error("key derivation failed")]
    KeyDerivationFailed,
    #[error("sequence is a duplicate")]
    Replay,
    #[error("sequence is older than the replay window")]
    TooOld,
}

#[derive(Clone, Debug, Zeroize, ZeroizeOnDrop)]
pub struct SecretKeyMaterial(pub [u8; KEY_LEN]);

impl SecretKeyMaterial {
    #[must_use]
    pub fn random() -> Self {
        let mut bytes = [0_u8; KEY_LEN];
        OsRng.fill_bytes(&mut bytes);
        Self(bytes)
    }
}

pub struct IdentityKeypair {
    signing: SigningKey,
}

impl IdentityKeypair {
    #[must_use]
    pub fn generate() -> Self {
        Self {
            signing: SigningKey::generate(&mut OsRng),
        }
    }

    #[must_use]
    pub fn from_secret_bytes(bytes: &[u8; KEY_LEN]) -> Self {
        Self {
            signing: SigningKey::from_bytes(bytes),
        }
    }

    #[must_use]
    pub fn secret_bytes(&self) -> [u8; KEY_LEN] {
        self.signing.to_bytes()
    }

    #[must_use]
    pub fn public_key_bytes(&self) -> [u8; KEY_LEN] {
        self.signing.verifying_key().to_bytes()
    }

    #[must_use]
    pub fn sign(&self, message: &[u8]) -> Vec<u8> {
        self.signing.sign(message).to_bytes().to_vec()
    }
}

pub fn verify_signature(
    public_key: &[u8; KEY_LEN],
    message: &[u8],
    signature: &[u8],
) -> Result<(), CryptoError> {
    let verifying =
        VerifyingKey::from_bytes(public_key).map_err(|_| CryptoError::InvalidPublicKey)?;
    let signature = Signature::from_slice(signature).map_err(|_| CryptoError::InvalidSignature)?;
    verifying
        .verify(message, &signature)
        .map_err(|_| CryptoError::InvalidSignature)
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SealedMessage {
    pub nonce: [u8; 24],
    pub ciphertext: Vec<u8>,
}

pub fn seal(key: &SecretKeyMaterial, plaintext: &[u8], associated_data: &[u8]) -> SealedMessage {
    let cipher = XChaCha20Poly1305::new((&key.0).into());
    let mut nonce = [0_u8; 24];
    OsRng.fill_bytes(&mut nonce);
    let ciphertext = cipher
        .encrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: plaintext,
                aad: associated_data,
            },
        )
        .expect("XChaCha20-Poly1305 accepts every plaintext length representable in memory");
    SealedMessage { nonce, ciphertext }
}

pub fn open(
    key: &SecretKeyMaterial,
    sealed: &SealedMessage,
    associated_data: &[u8],
) -> Result<Vec<u8>, CryptoError> {
    XChaCha20Poly1305::new((&key.0).into())
        .decrypt(
            XNonce::from_slice(&sealed.nonce),
            Payload {
                msg: &sealed.ciphertext,
                aad: associated_data,
            },
        )
        .map_err(|_| CryptoError::DecryptionFailed)
}

pub fn derive_key(
    input_key_material: &[u8],
    salt: &[u8],
    context: &[u8],
) -> Result<SecretKeyMaterial, CryptoError> {
    let mut output = [0_u8; KEY_LEN];
    Hkdf::<Sha256>::new(Some(salt), input_key_material)
        .expand(context, &mut output)
        .map_err(|_| CryptoError::KeyDerivationFailed)?;
    Ok(SecretKeyMaterial(output))
}

#[must_use]
pub fn sha256(data: &[u8]) -> [u8; 32] {
    Sha256::digest(data).into()
}

/// Sliding, bounded anti-replay window for one authenticated sender/channel.
#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReplayWindow {
    highest: Option<u64>,
    bitmap: u128,
}

impl ReplayWindow {
    pub fn accept(&mut self, sequence: u64) -> Result<(), CryptoError> {
        let Some(highest) = self.highest else {
            self.highest = Some(sequence);
            self.bitmap = 1;
            return Ok(());
        };

        if sequence > highest {
            let distance = sequence - highest;
            self.bitmap = if distance >= 128 {
                1
            } else {
                (self.bitmap << distance) | 1
            };
            self.highest = Some(sequence);
            return Ok(());
        }

        let distance = highest - sequence;
        if distance >= 128 {
            return Err(CryptoError::TooOld);
        }
        let bit = 1_u128 << distance;
        if self.bitmap & bit != 0 {
            return Err(CryptoError::Replay);
        }
        self.bitmap |= bit;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signatures_and_aead_reject_tampering() {
        let identity = IdentityKeypair::generate();
        let message = b"immutable event";
        let signature = identity.sign(message);
        verify_signature(&identity.public_key_bytes(), message, &signature).unwrap();
        assert!(verify_signature(&identity.public_key_bytes(), b"changed", &signature).is_err());

        let key = SecretKeyMaterial::random();
        let sealed = seal(&key, message, b"group/epoch/7");
        assert_eq!(open(&key, &sealed, b"group/epoch/7").unwrap(), message);
        assert!(open(&key, &sealed, b"group/epoch/8").is_err());
    }

    #[test]
    fn replay_window_accepts_reordering_once() {
        let mut window = ReplayWindow::default();
        window.accept(10).unwrap();
        window.accept(12).unwrap();
        window.accept(11).unwrap();
        assert!(matches!(window.accept(11), Err(CryptoError::Replay)));
        window.accept(200).unwrap();
        assert!(matches!(window.accept(10), Err(CryptoError::TooOld)));
    }
}
