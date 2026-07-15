//! Content-addressed resource manifests and resumable chunk assembly.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use tc_model::ResourceId;
use thiserror::Error;

mod disk;

pub use disk::{CleanupReport, DiskResourceStore, DiskResourceTransfer};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChunkDescriptor {
    pub index: u32,
    pub offset: u64,
    pub size: u32,
    pub sha256: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResourceManifest {
    pub resource_id: ResourceId,
    pub content_sha256: String,
    pub byte_size: u64,
    pub mime_type: String,
    pub chunks: Vec<ChunkDescriptor>,
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum ResourceError {
    #[error("chunk size must be greater than zero")]
    InvalidChunkSize,
    #[error("unknown chunk {0}")]
    UnknownChunk(u32),
    #[error("chunk {index} has size {actual}, expected {expected}")]
    SizeMismatch {
        index: u32,
        expected: usize,
        actual: usize,
    },
    #[error("chunk {0} failed SHA-256 verification")]
    ChunkHashMismatch(u32),
    #[error("resource is incomplete")]
    Incomplete,
    #[error("assembled resource failed SHA-256 verification")]
    ResourceHashMismatch,
    #[error("resource is too large for this address space")]
    TooLarge,
    #[error("invalid resource manifest: {0}")]
    InvalidManifest(String),
    #[error("resource {0} already has a different manifest; restart it explicitly")]
    ManifestConflict(ResourceId),
    #[error("resource {0} has no persisted transfer")]
    UnknownResource(ResourceId),
    #[error("resource metadata could not be decoded: {0}")]
    Metadata(String),
    #[error("{operation} failed for {path}: {message}")]
    Io {
        operation: &'static str,
        path: PathBuf,
        message: String,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AcceptOutcome {
    Stored,
    Duplicate,
}

pub fn build_manifest(
    resource_id: ResourceId,
    mime_type: impl Into<String>,
    bytes: &[u8],
    chunk_size: usize,
) -> Result<ResourceManifest, ResourceError> {
    if chunk_size == 0 {
        return Err(ResourceError::InvalidChunkSize);
    }
    let mut chunks = Vec::new();
    for (index, chunk) in bytes.chunks(chunk_size).enumerate() {
        let offset = index
            .checked_mul(chunk_size)
            .and_then(|value| u64::try_from(value).ok())
            .ok_or(ResourceError::TooLarge)?;
        chunks.push(ChunkDescriptor {
            index: u32::try_from(index).map_err(|_| ResourceError::TooLarge)?,
            offset,
            size: u32::try_from(chunk.len()).map_err(|_| ResourceError::TooLarge)?,
            sha256: digest_hex(chunk),
        });
    }
    Ok(ResourceManifest {
        resource_id,
        content_sha256: digest_hex(bytes),
        byte_size: u64::try_from(bytes.len()).map_err(|_| ResourceError::TooLarge)?,
        mime_type: mime_type.into(),
        chunks,
    })
}

/// Validates the invariants required for deterministic, sparse on-disk assembly.
///
/// Empty resources are valid and have no chunks. Non-empty manifests must contain
/// a contiguous, index-ordered partition of the resource bytes.
pub fn validate_manifest(manifest: &ResourceManifest) -> Result<(), ResourceError> {
    if !is_sha256_hex(&manifest.content_sha256) {
        return Err(ResourceError::InvalidManifest(
            "contentSha256 must be 64 lowercase hexadecimal characters".to_owned(),
        ));
    }

    let mut expected_offset = 0_u64;
    for (position, descriptor) in manifest.chunks.iter().enumerate() {
        let expected_index = u32::try_from(position).map_err(|_| ResourceError::TooLarge)?;
        if descriptor.index != expected_index {
            return Err(ResourceError::InvalidManifest(format!(
                "chunk index {} is out of order; expected {expected_index}",
                descriptor.index
            )));
        }
        if descriptor.offset != expected_offset {
            return Err(ResourceError::InvalidManifest(format!(
                "chunk {} starts at {}, expected {expected_offset}",
                descriptor.index, descriptor.offset
            )));
        }
        if descriptor.size == 0 {
            return Err(ResourceError::InvalidManifest(format!(
                "chunk {} is empty",
                descriptor.index
            )));
        }
        if !is_sha256_hex(&descriptor.sha256) {
            return Err(ResourceError::InvalidManifest(format!(
                "chunk {} has an invalid SHA-256 digest",
                descriptor.index
            )));
        }
        expected_offset = expected_offset
            .checked_add(u64::from(descriptor.size))
            .ok_or(ResourceError::TooLarge)?;
    }

    if expected_offset != manifest.byte_size {
        return Err(ResourceError::InvalidManifest(format!(
            "chunks cover {expected_offset} bytes, expected {}",
            manifest.byte_size
        )));
    }
    Ok(())
}

#[derive(Clone, Debug)]
pub struct ResourceReceiver {
    manifest: ResourceManifest,
    chunks: BTreeMap<u32, Vec<u8>>,
}

impl ResourceReceiver {
    #[must_use]
    pub fn new(manifest: ResourceManifest) -> Self {
        Self {
            manifest,
            chunks: BTreeMap::new(),
        }
    }

    pub fn accept_chunk(
        &mut self,
        index: u32,
        bytes: &[u8],
    ) -> Result<AcceptOutcome, ResourceError> {
        let descriptor = self
            .manifest
            .chunks
            .iter()
            .find(|chunk| chunk.index == index)
            .ok_or(ResourceError::UnknownChunk(index))?;
        if bytes.len() != descriptor.size as usize {
            return Err(ResourceError::SizeMismatch {
                index,
                expected: descriptor.size as usize,
                actual: bytes.len(),
            });
        }
        if digest_hex(bytes) != descriptor.sha256 {
            return Err(ResourceError::ChunkHashMismatch(index));
        }
        if self.chunks.contains_key(&index) {
            return Ok(AcceptOutcome::Duplicate);
        }
        self.chunks.insert(index, bytes.to_vec());
        Ok(AcceptOutcome::Stored)
    }

    #[must_use]
    pub fn missing_chunks(&self) -> BTreeSet<u32> {
        self.manifest
            .chunks
            .iter()
            .map(|chunk| chunk.index)
            .filter(|index| !self.chunks.contains_key(index))
            .collect()
    }

    #[must_use]
    pub fn progress(&self) -> (u64, u64) {
        let received = self.chunks.values().map(|chunk| chunk.len() as u64).sum();
        (received, self.manifest.byte_size)
    }

    pub fn assemble(&self) -> Result<Vec<u8>, ResourceError> {
        if !self.missing_chunks().is_empty() {
            return Err(ResourceError::Incomplete);
        }
        let capacity =
            usize::try_from(self.manifest.byte_size).map_err(|_| ResourceError::TooLarge)?;
        let mut output = Vec::with_capacity(capacity);
        for descriptor in &self.manifest.chunks {
            output.extend_from_slice(
                self.chunks
                    .get(&descriptor.index)
                    .ok_or(ResourceError::Incomplete)?,
            );
        }
        if output.len() as u64 != self.manifest.byte_size
            || digest_hex(&output) != self.manifest.content_sha256
        {
            return Err(ResourceError::ResourceHashMismatch);
        }
        Ok(output)
    }
}

fn digest_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn is_sha256_hex(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn duplicate_chunks_are_free_and_resume_lists_exact_gaps() {
        let data = b"abcdefghijkl";
        let manifest = build_manifest(ResourceId::from("r"), "image/jpeg", data, 4).unwrap();
        let mut receiver = ResourceReceiver::new(manifest);
        assert_eq!(
            receiver.accept_chunk(2, b"ijkl").unwrap(),
            AcceptOutcome::Stored
        );
        assert_eq!(
            receiver.accept_chunk(2, b"ijkl").unwrap(),
            AcceptOutcome::Duplicate
        );
        assert_eq!(receiver.missing_chunks(), [0, 1].into_iter().collect());
        receiver.accept_chunk(0, b"abcd").unwrap();
        receiver.accept_chunk(1, b"efgh").unwrap();
        assert_eq!(receiver.assemble().unwrap(), data);
    }

    #[test]
    fn corrupted_chunk_is_rejected_before_storage() {
        let manifest = build_manifest(ResourceId::from("r"), "audio/m4a", b"voice", 5).unwrap();
        let mut receiver = ResourceReceiver::new(manifest);
        assert_eq!(
            receiver.accept_chunk(0, b"v0ice"),
            Err(ResourceError::ChunkHashMismatch(0))
        );
        assert_eq!(receiver.progress().0, 0);
    }

    #[test]
    fn final_content_hash_catches_tampered_manifest_order() {
        let mut manifest = build_manifest(ResourceId::from("r"), "x/test", b"abcdefgh", 4).unwrap();
        manifest.chunks.swap(0, 1);
        let mut receiver = ResourceReceiver::new(manifest);
        receiver.accept_chunk(1, b"efgh").unwrap();
        receiver.accept_chunk(0, b"abcd").unwrap();
        assert_eq!(
            receiver.assemble(),
            Err(ResourceError::ResourceHashMismatch)
        );
    }

    #[test]
    fn manifest_validation_rejects_sparse_or_reordered_layouts() {
        let mut manifest = build_manifest(ResourceId::from("r"), "x/test", b"abcdefgh", 4).unwrap();
        manifest.chunks.swap(0, 1);
        assert!(matches!(
            validate_manifest(&manifest),
            Err(ResourceError::InvalidManifest(_))
        ));

        let empty = build_manifest(ResourceId::from("empty"), "x/test", b"", 4).unwrap();
        assert_eq!(validate_manifest(&empty), Ok(()));
    }
}
