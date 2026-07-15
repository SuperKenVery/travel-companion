use crate::{
    digest_hex, validate_manifest, AcceptOutcome, ChunkDescriptor, ResourceError, ResourceManifest,
};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::fs::{self, File, OpenOptions};
use std::io::{BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use tc_model::ResourceId;

const MANIFEST_FILE: &str = "manifest.json";
const TRANSFERS_DIR: &str = "transfers";
const OBJECTS_DIR: &str = "objects";
const CHUNKS_DIR: &str = "chunks";
const OBJECT_SUFFIX: &str = ".resource";
const TEMP_PREFIX: &str = ".tc-tmp-";

static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// Counts deterministic cleanup actions. Invalid manifests are reported but
/// deliberately retained so a caller can explicitly restart those transfers.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct CleanupReport {
    pub temporary_files: usize,
    pub corrupted_chunks: usize,
    pub orphaned_objects: usize,
    pub invalid_transfers: usize,
}

impl CleanupReport {
    fn add_assign(&mut self, other: Self) {
        self.temporary_files += other.temporary_files;
        self.corrupted_chunks += other.corrupted_chunks;
        self.orphaned_objects += other.orphaned_objects;
        self.invalid_transfers += other.invalid_transfers;
    }
}

/// Content-addressed resource storage rooted in an application-controlled
/// directory (normally `Application Support/Resources`).
///
/// The type intentionally provides no internal locking: the owning Rust actor
/// serializes calls. Atomic file replacement still makes crash recovery safe.
#[derive(Clone, Debug)]
pub struct DiskResourceStore {
    root: PathBuf,
}

impl DiskResourceStore {
    /// Opens or creates a resource store and removes abandoned atomic-write
    /// temporary files. Persisted manifests and chunks are otherwise retained.
    pub fn open(root: impl AsRef<Path>) -> Result<Self, ResourceError> {
        let root = root.as_ref().to_path_buf();
        create_dir_all(&root)?;
        create_dir_all(&root.join(TRANSFERS_DIR))?;
        create_dir_all(&root.join(OBJECTS_DIR))?;
        let store = Self { root };
        store.cleanup_temporary_files()?;
        Ok(store)
    }

    #[must_use]
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Starts a transfer or resumes the exact same manifest. Reusing a resource
    /// ID for different content requires the explicit [`Self::restart`] API.
    pub fn begin(&self, manifest: ResourceManifest) -> Result<DiskResourceTransfer, ResourceError> {
        validate_manifest(&manifest)?;
        if let Some(existing) = self.resume(&manifest.resource_id)? {
            if existing.manifest == manifest {
                return Ok(existing);
            }
            return Err(ResourceError::ManifestConflict(manifest.resource_id));
        }

        let transfer_dir = self.transfer_dir(&manifest.resource_id);
        create_dir_all(&transfer_dir)?;
        create_dir_all(&transfer_dir.join(CHUNKS_DIR))?;
        let metadata = serde_json::to_vec_pretty(&manifest)
            .map_err(|error| ResourceError::Metadata(error.to_string()))?;
        atomic_write(&transfer_dir.join(MANIFEST_FILE), &metadata)?;
        sync_directory(&transfer_dir)?;
        self.resume(&manifest.resource_id)?
            .ok_or_else(|| ResourceError::UnknownResource(manifest.resource_id.clone()))
    }

    /// Reopens a persisted transfer and verifies every chunk already on disk.
    /// Corrupt or truncated chunks are discarded and returned as missing.
    pub fn resume(
        &self,
        resource_id: &ResourceId,
    ) -> Result<Option<DiskResourceTransfer>, ResourceError> {
        let transfer_dir = self.transfer_dir(resource_id);
        let manifest_path = transfer_dir.join(MANIFEST_FILE);
        if !manifest_path
            .try_exists()
            .map_err(|error| io_error("check manifest existence", &manifest_path, error))?
        {
            return Ok(None);
        }
        let metadata = read_all(&manifest_path)?;
        let manifest: ResourceManifest = serde_json::from_slice(&metadata)
            .map_err(|error| ResourceError::Metadata(error.to_string()))?;
        validate_manifest(&manifest)?;
        if &manifest.resource_id != resource_id {
            return Err(ResourceError::InvalidManifest(
                "resource ID does not match its persisted directory".to_owned(),
            ));
        }
        create_dir_all(&transfer_dir.join(CHUNKS_DIR))?;
        let mut transfer = DiskResourceTransfer {
            transfer_dir,
            objects_dir: self.root.join(OBJECTS_DIR),
            manifest,
            completed: false,
            verified_chunks: BTreeSet::new(),
        };
        transfer.recover()?;
        Ok(Some(transfer))
    }

    /// Re-verifies a failed/incomplete transfer while preserving every valid
    /// chunk. This is the normal user-facing "retry" operation.
    pub fn retry(&self, resource_id: &ResourceId) -> Result<DiskResourceTransfer, ResourceError> {
        self.resume(resource_id)?
            .ok_or_else(|| ResourceError::UnknownResource(resource_id.clone()))
    }

    /// Discards partial state and starts the supplied manifest from zero. The
    /// completed content object remains deduplicated until garbage collection.
    pub fn restart(
        &self,
        manifest: ResourceManifest,
    ) -> Result<DiskResourceTransfer, ResourceError> {
        self.cancel(&manifest.resource_id)?;
        self.begin(manifest)
    }

    /// Cancels a transfer by deleting its manifest and partial chunks. Shared
    /// completed content is not removed until [`Self::cleanup`] proves orphaned.
    pub fn cancel(&self, resource_id: &ResourceId) -> Result<bool, ResourceError> {
        let transfer_dir = self.transfer_dir(resource_id);
        if !transfer_dir
            .try_exists()
            .map_err(|error| io_error("check transfer existence", &transfer_dir, error))?
        {
            return Ok(false);
        }
        remove_dir_all(&transfer_dir)?;
        sync_directory(&self.root.join(TRANSFERS_DIR))?;
        Ok(true)
    }

    /// Verifies persisted transfers, removes abandoned temporary files, and
    /// deletes content objects no longer referenced by any valid manifest.
    pub fn cleanup(&self) -> Result<CleanupReport, ResourceError> {
        let mut report = self.cleanup_temporary_files()?;
        let mut referenced_objects = BTreeSet::new();
        let transfers_dir = self.root.join(TRANSFERS_DIR);

        for entry in read_dir(&transfers_dir)? {
            let entry =
                entry.map_err(|error| io_error("read transfer entry", &transfers_dir, error))?;
            let file_type = entry
                .file_type()
                .map_err(|error| io_error("read transfer entry type", &entry.path(), error))?;
            if !file_type.is_dir() {
                continue;
            }
            let manifest_path = entry.path().join(MANIFEST_FILE);
            let Ok(metadata) = read_all(&manifest_path) else {
                report.invalid_transfers += 1;
                continue;
            };
            let Ok(manifest) = serde_json::from_slice::<ResourceManifest>(&metadata) else {
                report.invalid_transfers += 1;
                continue;
            };
            if validate_manifest(&manifest).is_err()
                || self.transfer_dir(&manifest.resource_id) != entry.path()
            {
                report.invalid_transfers += 1;
                continue;
            }
            referenced_objects.insert(manifest.content_sha256.clone());
            let mut transfer = DiskResourceTransfer {
                transfer_dir: entry.path(),
                objects_dir: self.root.join(OBJECTS_DIR),
                manifest,
                completed: false,
                verified_chunks: BTreeSet::new(),
            };
            report.add_assign(transfer.recover()?);
        }

        let objects_dir = self.root.join(OBJECTS_DIR);
        for entry in read_dir(&objects_dir)? {
            let entry =
                entry.map_err(|error| io_error("read object entry", &objects_dir, error))?;
            let file_type = entry
                .file_type()
                .map_err(|error| io_error("read object entry type", &entry.path(), error))?;
            if !file_type.is_file() {
                continue;
            }
            let name = entry.file_name();
            let name = name.to_string_lossy();
            let Some(hash) = name.strip_suffix(OBJECT_SUFFIX) else {
                continue;
            };
            if !referenced_objects.contains(hash) {
                remove_file(&entry.path())?;
                report.orphaned_objects += 1;
            }
        }
        sync_directory(&objects_dir)?;
        Ok(report)
    }

    fn transfer_dir(&self, resource_id: &ResourceId) -> PathBuf {
        self.root
            .join(TRANSFERS_DIR)
            .join(digest_hex(resource_id.as_str().as_bytes()))
    }

    fn cleanup_temporary_files(&self) -> Result<CleanupReport, ResourceError> {
        let mut report = CleanupReport::default();
        cleanup_temp_files_in(&self.root.join(OBJECTS_DIR), &mut report)?;
        let transfers_dir = self.root.join(TRANSFERS_DIR);
        cleanup_temp_files_in(&transfers_dir, &mut report)?;
        for entry in read_dir(&transfers_dir)? {
            let entry =
                entry.map_err(|error| io_error("read transfer entry", &transfers_dir, error))?;
            if entry
                .file_type()
                .map_err(|error| io_error("read transfer entry type", &entry.path(), error))?
                .is_dir()
            {
                cleanup_temp_files_in(&entry.path(), &mut report)?;
                cleanup_temp_files_in(&entry.path().join(CHUNKS_DIR), &mut report)?;
            }
        }
        Ok(report)
    }
}

/// A single persisted transfer. Dropping the value never cancels it; reopening
/// the store and calling `resume` reconstructs progress from verified chunks.
#[derive(Debug)]
pub struct DiskResourceTransfer {
    transfer_dir: PathBuf,
    objects_dir: PathBuf,
    manifest: ResourceManifest,
    completed: bool,
    verified_chunks: BTreeSet<u32>,
}

impl DiskResourceTransfer {
    #[must_use]
    pub fn manifest(&self) -> &ResourceManifest {
        &self.manifest
    }

    #[must_use]
    pub fn is_complete(&self) -> bool {
        self.completed
    }

    pub fn accept_chunk(
        &mut self,
        index: u32,
        bytes: &[u8],
    ) -> Result<AcceptOutcome, ResourceError> {
        let descriptor = self.descriptor(index)?.clone();
        verify_chunk(&descriptor, bytes)?;
        if self.completed {
            return Ok(AcceptOutcome::Duplicate);
        }

        let chunk_path = self.chunk_path(index);
        if chunk_path
            .try_exists()
            .map_err(|error| io_error("check chunk existence", &chunk_path, error))?
        {
            if verify_file(&chunk_path, u64::from(descriptor.size), &descriptor.sha256)? {
                self.verified_chunks.insert(index);
                return Ok(AcceptOutcome::Duplicate);
            }
            remove_path(&chunk_path)?;
            self.verified_chunks.remove(&index);
        }
        atomic_write(&chunk_path, bytes)?;
        self.verified_chunks.insert(index);
        Ok(AcceptOutcome::Stored)
    }

    pub fn missing_chunks(&self) -> Result<BTreeSet<u32>, ResourceError> {
        if self.completed {
            return Ok(BTreeSet::new());
        }
        Ok(self
            .manifest
            .chunks
            .iter()
            .map(|descriptor| descriptor.index)
            .filter(|index| !self.verified_chunks.contains(index))
            .collect())
    }

    pub fn progress(&self) -> Result<(u64, u64), ResourceError> {
        if self.completed {
            return Ok((self.manifest.byte_size, self.manifest.byte_size));
        }
        let mut received = 0_u64;
        for descriptor in self
            .manifest
            .chunks
            .iter()
            .filter(|descriptor| self.verified_chunks.contains(&descriptor.index))
        {
            received = received
                .checked_add(u64::from(descriptor.size))
                .ok_or(ResourceError::TooLarge)?;
        }
        Ok((received, self.manifest.byte_size))
    }

    /// Streams verified chunks into the content-addressed object, fsyncs it,
    /// verifies the complete hash, and only then atomically publishes it.
    pub fn finalize(&mut self) -> Result<PathBuf, ResourceError> {
        if !self.missing_chunks()?.is_empty() {
            return Err(ResourceError::Incomplete);
        }

        let object_path = self.object_path();
        if object_path
            .try_exists()
            .map_err(|error| io_error("check object existence", &object_path, error))?
        {
            if verify_file(
                &object_path,
                self.manifest.byte_size,
                &self.manifest.content_sha256,
            )? {
                self.completed = true;
                self.remove_partial_chunks()?;
                return Ok(object_path);
            }
            remove_file(&object_path)?;
        }

        let (temporary_path, mut output) = create_temporary_file(&self.objects_dir)?;
        let assembly = self.write_assembled_object(&mut output);
        if let Err(error) = assembly {
            drop(output);
            let _ = fs::remove_file(&temporary_path);
            return Err(error);
        }
        sync_file(&output, &temporary_path)?;
        drop(output);
        rename(&temporary_path, &object_path)?;
        sync_directory(&self.objects_dir)?;
        self.completed = true;
        self.remove_partial_chunks()?;
        Ok(object_path)
    }

    /// Returns the completed content path only after re-verifying it.
    pub fn completed_path(&mut self) -> Result<Option<PathBuf>, ResourceError> {
        let path = self.object_path();
        if !path
            .try_exists()
            .map_err(|error| io_error("check object existence", &path, error))?
        {
            self.completed = false;
            return Ok(None);
        }
        if verify_file(
            &path,
            self.manifest.byte_size,
            &self.manifest.content_sha256,
        )? {
            self.completed = true;
            return Ok(Some(path));
        }
        remove_file(&path)?;
        sync_directory(&self.objects_dir)?;
        self.completed = false;
        Ok(None)
    }

    /// Reads and re-verifies one chunk from a completed content object. This is
    /// used by any authenticated peer that is acting as a store-and-forward
    /// relay; callers never need to retain the original import path.
    pub fn read_chunk(&mut self, index: u32) -> Result<Vec<u8>, ResourceError> {
        let descriptor = self.descriptor(index)?.clone();
        let path = if self.completed {
            self.object_path()
        } else {
            self.completed_path()?.ok_or(ResourceError::Incomplete)?
        };
        let mut file = File::open(&path).map_err(|error| io_error("open object", &path, error))?;
        file.seek(SeekFrom::Start(descriptor.offset))
            .map_err(|error| io_error("seek object", &path, error))?;
        let size = usize::try_from(descriptor.size).map_err(|_| ResourceError::TooLarge)?;
        let mut bytes = vec![0_u8; size];
        file.read_exact(&mut bytes)
            .map_err(|error| io_error("read object chunk", &path, error))?;
        verify_chunk(&descriptor, &bytes)?;
        Ok(bytes)
    }

    fn recover(&mut self) -> Result<CleanupReport, ResourceError> {
        let mut report = CleanupReport::default();
        self.verified_chunks.clear();
        cleanup_temp_files_in(&self.transfer_dir, &mut report)?;
        cleanup_temp_files_in(&self.transfer_dir.join(CHUNKS_DIR), &mut report)?;

        if self.completed_path()?.is_some() {
            self.remove_partial_chunks()?;
            return Ok(report);
        }

        let chunks_dir = self.transfer_dir.join(CHUNKS_DIR);
        let expected_paths: BTreeSet<_> = self
            .manifest
            .chunks
            .iter()
            .map(|descriptor| self.chunk_path(descriptor.index))
            .collect();
        for descriptor in &self.manifest.chunks {
            let path = self.chunk_path(descriptor.index);
            match fs::symlink_metadata(&path) {
                Ok(metadata)
                    if metadata.file_type().is_file()
                        && verify_file(&path, u64::from(descriptor.size), &descriptor.sha256)? =>
                {
                    self.verified_chunks.insert(descriptor.index);
                }
                Ok(_) => {
                    remove_path(&path)?;
                    report.corrupted_chunks += 1;
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(io_error("inspect chunk", &path, error)),
            }
        }
        for entry in read_dir(&chunks_dir)? {
            let entry = entry.map_err(|error| io_error("read chunk entry", &chunks_dir, error))?;
            if !expected_paths.contains(&entry.path()) {
                remove_path(&entry.path())?;
                report.corrupted_chunks += 1;
            }
        }
        if report.corrupted_chunks > 0 {
            sync_directory(&chunks_dir)?;
        }
        Ok(report)
    }

    fn write_assembled_object(&self, output: &mut File) -> Result<(), ResourceError> {
        let mut hasher = Sha256::new();
        let mut written = 0_u64;
        for descriptor in &self.manifest.chunks {
            let path = self.chunk_path(descriptor.index);
            let input = File::open(&path).map_err(|error| io_error("open chunk", &path, error))?;
            let mut input = BufReader::new(input);
            let mut buffer = [0_u8; 64 * 1024];
            loop {
                let count = input
                    .read(&mut buffer)
                    .map_err(|error| io_error("read chunk", &path, error))?;
                if count == 0 {
                    break;
                }
                output.write_all(&buffer[..count]).map_err(|error| {
                    io_error("write assembled object", &self.objects_dir, error)
                })?;
                hasher.update(&buffer[..count]);
                written = written
                    .checked_add(u64::try_from(count).map_err(|_| ResourceError::TooLarge)?)
                    .ok_or(ResourceError::TooLarge)?;
            }
        }
        if written != self.manifest.byte_size
            || hex::encode(hasher.finalize()) != self.manifest.content_sha256
        {
            return Err(ResourceError::ResourceHashMismatch);
        }
        Ok(())
    }

    fn remove_partial_chunks(&self) -> Result<(), ResourceError> {
        let chunks_dir = self.transfer_dir.join(CHUNKS_DIR);
        if chunks_dir
            .try_exists()
            .map_err(|error| io_error("check chunks directory existence", &chunks_dir, error))?
        {
            remove_dir_all(&chunks_dir)?;
        }
        create_dir_all(&chunks_dir)?;
        sync_directory(&self.transfer_dir)?;
        Ok(())
    }

    fn descriptor(&self, index: u32) -> Result<&ChunkDescriptor, ResourceError> {
        self.manifest
            .chunks
            .iter()
            .find(|descriptor| descriptor.index == index)
            .ok_or(ResourceError::UnknownChunk(index))
    }

    fn chunk_path(&self, index: u32) -> PathBuf {
        self.transfer_dir
            .join(CHUNKS_DIR)
            .join(format!("{index:08}.chunk"))
    }

    fn object_path(&self) -> PathBuf {
        self.objects_dir
            .join(format!("{}{OBJECT_SUFFIX}", self.manifest.content_sha256))
    }
}

fn verify_chunk(descriptor: &ChunkDescriptor, bytes: &[u8]) -> Result<(), ResourceError> {
    if bytes.len() != descriptor.size as usize {
        return Err(ResourceError::SizeMismatch {
            index: descriptor.index,
            expected: descriptor.size as usize,
            actual: bytes.len(),
        });
    }
    if digest_hex(bytes) != descriptor.sha256 {
        return Err(ResourceError::ChunkHashMismatch(descriptor.index));
    }
    Ok(())
}

fn verify_file(
    path: &Path,
    expected_size: u64,
    expected_hash: &str,
) -> Result<bool, ResourceError> {
    let file = File::open(path).map_err(|error| io_error("open file", path, error))?;
    let metadata = file
        .metadata()
        .map_err(|error| io_error("read file metadata", path, error))?;
    if metadata.len() != expected_size {
        return Ok(false);
    }
    let mut reader = BufReader::new(file);
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let count = reader
            .read(&mut buffer)
            .map_err(|error| io_error("read file", path, error))?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(hex::encode(hasher.finalize()) == expected_hash)
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), ResourceError> {
    let parent = path.parent().ok_or_else(|| {
        ResourceError::InvalidManifest("atomic-write path has no parent".to_owned())
    })?;
    create_dir_all(parent)?;
    let (temporary_path, mut output) = create_temporary_file(parent)?;
    let write_result = output
        .write_all(bytes)
        .map_err(|error| io_error("write temporary file", &temporary_path, error))
        .and_then(|()| sync_file(&output, &temporary_path));
    drop(output);
    if let Err(error) = write_result {
        let _ = fs::remove_file(&temporary_path);
        return Err(error);
    }
    if let Err(error) = rename(&temporary_path, path) {
        let _ = fs::remove_file(&temporary_path);
        return Err(error);
    }
    sync_directory(parent)
}

fn create_temporary_file(directory: &Path) -> Result<(PathBuf, File), ResourceError> {
    for _ in 0..128 {
        let sequence = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let path = directory.join(format!("{TEMP_PREFIX}{}-{sequence}", std::process::id()));
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(file) => return Ok((path, file)),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(io_error("create temporary file", &path, error)),
        }
    }
    Err(ResourceError::Io {
        operation: "create temporary file",
        path: directory.to_path_buf(),
        message: "exhausted collision retries".to_owned(),
    })
}

fn cleanup_temp_files_in(
    directory: &Path,
    report: &mut CleanupReport,
) -> Result<(), ResourceError> {
    if !directory
        .try_exists()
        .map_err(|error| io_error("check directory existence", directory, error))?
    {
        return Ok(());
    }
    let removed_before = report.temporary_files;
    for entry in read_dir(directory)? {
        let entry = entry.map_err(|error| io_error("read directory entry", directory, error))?;
        let file_type = entry
            .file_type()
            .map_err(|error| io_error("read directory entry type", &entry.path(), error))?;
        if file_type.is_file() && entry.file_name().to_string_lossy().starts_with(TEMP_PREFIX) {
            remove_file(&entry.path())?;
            report.temporary_files += 1;
        }
    }
    if report.temporary_files > removed_before {
        sync_directory(directory)?;
    }
    Ok(())
}

fn read_all(path: &Path) -> Result<Vec<u8>, ResourceError> {
    fs::read(path).map_err(|error| io_error("read file", path, error))
}

fn create_dir_all(path: &Path) -> Result<(), ResourceError> {
    fs::create_dir_all(path).map_err(|error| io_error("create directory", path, error))
}

fn read_dir(path: &Path) -> Result<fs::ReadDir, ResourceError> {
    fs::read_dir(path).map_err(|error| io_error("read directory", path, error))
}

fn remove_file(path: &Path) -> Result<(), ResourceError> {
    fs::remove_file(path).map_err(|error| io_error("remove file", path, error))
}

fn remove_dir_all(path: &Path) -> Result<(), ResourceError> {
    fs::remove_dir_all(path).map_err(|error| io_error("remove directory", path, error))
}

fn remove_path(path: &Path) -> Result<(), ResourceError> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| io_error("inspect filesystem entry", path, error))?;
    if metadata.file_type().is_dir() {
        remove_dir_all(path)
    } else {
        remove_file(path)
    }
}

fn rename(from: &Path, to: &Path) -> Result<(), ResourceError> {
    fs::rename(from, to).map_err(|error| io_error("rename file", to, error))
}

fn sync_file(file: &File, path: &Path) -> Result<(), ResourceError> {
    file.sync_all()
        .map_err(|error| io_error("synchronize file", path, error))
}

fn sync_directory(path: &Path) -> Result<(), ResourceError> {
    let directory = File::open(path).map_err(|error| io_error("open directory", path, error))?;
    directory
        .sync_all()
        .map_err(|error| io_error("synchronize directory", path, error))
}

fn io_error(operation: &'static str, path: &Path, error: std::io::Error) -> ResourceError {
    ResourceError::Io {
        operation,
        path: path.to_path_buf(),
        message: error.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn manifest(id: &str, data: &[u8]) -> ResourceManifest {
        crate::build_manifest(ResourceId::from(id), "application/test", data, 4).unwrap()
    }

    #[test]
    fn progress_survives_restart_and_finalization_is_atomic() {
        let directory = tempdir().unwrap();
        let data = b"abcdefghijkl";
        let manifest = manifest("photo", data);
        let store = DiskResourceStore::open(directory.path()).unwrap();
        let mut transfer = store.begin(manifest.clone()).unwrap();
        transfer.accept_chunk(0, b"abcd").unwrap();
        transfer.accept_chunk(2, b"ijkl").unwrap();
        assert_eq!(transfer.progress().unwrap(), (8, 12));
        drop(transfer);
        drop(store);

        let store = DiskResourceStore::open(directory.path()).unwrap();
        let mut transfer = store.resume(&manifest.resource_id).unwrap().unwrap();
        assert_eq!(
            transfer.missing_chunks().unwrap(),
            [1].into_iter().collect()
        );
        assert_eq!(transfer.progress().unwrap(), (8, 12));
        transfer.accept_chunk(1, b"efgh").unwrap();
        let completed = transfer.finalize().unwrap();
        assert_eq!(fs::read(&completed).unwrap(), data);
        assert!(transfer.is_complete());
        assert_eq!(transfer.progress().unwrap(), (12, 12));
        assert!(transfer.missing_chunks().unwrap().is_empty());
        assert!(fs::read_dir(completed.parent().unwrap())
            .unwrap()
            .all(|entry| !entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(TEMP_PREFIX)));
    }

    #[test]
    fn retry_discards_corruption_but_preserves_verified_chunks() {
        let directory = tempdir().unwrap();
        let data = b"abcdefgh";
        let manifest = manifest("voice", data);
        let store = DiskResourceStore::open(directory.path()).unwrap();
        let mut transfer = store.begin(manifest.clone()).unwrap();
        transfer.accept_chunk(0, b"abcd").unwrap();
        transfer.accept_chunk(1, b"efgh").unwrap();
        fs::write(transfer.chunk_path(1), b"bad!").unwrap();
        drop(transfer);

        let mut retry = store.retry(&manifest.resource_id).unwrap();
        assert_eq!(retry.missing_chunks().unwrap(), [1].into_iter().collect());
        assert_eq!(retry.progress().unwrap(), (4, 8));
        retry.accept_chunk(1, b"efgh").unwrap();
        assert_eq!(fs::read(retry.finalize().unwrap()).unwrap(), data);
    }

    #[test]
    fn invalid_chunk_never_replaces_a_verified_chunk() {
        let directory = tempdir().unwrap();
        let manifest = manifest("photo", b"abcdefgh");
        let store = DiskResourceStore::open(directory.path()).unwrap();
        let mut transfer = store.begin(manifest).unwrap();
        transfer.accept_chunk(0, b"abcd").unwrap();
        assert_eq!(
            transfer.accept_chunk(0, b"abXd"),
            Err(ResourceError::ChunkHashMismatch(0))
        );
        assert_eq!(fs::read(transfer.chunk_path(0)).unwrap(), b"abcd");
    }

    #[test]
    fn manifest_conflict_requires_explicit_restart() {
        let directory = tempdir().unwrap();
        let store = DiskResourceStore::open(directory.path()).unwrap();
        let first = manifest("same-id", b"first");
        let second = manifest("same-id", b"second");
        store.begin(first).unwrap();
        assert_eq!(
            store.begin(second.clone()).unwrap_err(),
            ResourceError::ManifestConflict(ResourceId::from("same-id"))
        );
        let restarted = store.restart(second.clone()).unwrap();
        assert_eq!(restarted.manifest(), &second);
        assert_eq!(restarted.progress().unwrap(), (0, second.byte_size));
    }

    #[test]
    fn completed_content_is_deduplicated_and_only_collected_when_orphaned() {
        let directory = tempdir().unwrap();
        let store = DiskResourceStore::open(directory.path()).unwrap();
        let data = b"same content";
        let first_manifest = manifest("first", data);
        let second_manifest = manifest("second", data);

        let mut first = store.begin(first_manifest.clone()).unwrap();
        for (chunk, bytes) in [b"same".as_slice(), b" con", b"tent"]
            .into_iter()
            .enumerate()
        {
            first.accept_chunk(chunk as u32, bytes).unwrap();
        }
        let object = first.finalize().unwrap();

        let mut second = store.begin(second_manifest.clone()).unwrap();
        assert!(second.is_complete());
        assert_eq!(second.finalize().unwrap(), object);
        store.cancel(&first_manifest.resource_id).unwrap();
        assert_eq!(store.cleanup().unwrap().orphaned_objects, 0);
        assert!(object.exists());
        store.cancel(&second_manifest.resource_id).unwrap();
        assert_eq!(store.cleanup().unwrap().orphaned_objects, 1);
        assert!(!object.exists());
    }

    #[test]
    fn completed_chunks_can_be_served_by_a_relay_without_the_source_file() {
        let directory = tempdir().unwrap();
        let store = DiskResourceStore::open(directory.path()).unwrap();
        let manifest = manifest("relay", b"abcdefghijkl");
        let mut transfer = store.begin(manifest.clone()).unwrap();
        for (index, bytes) in [b"abcd".as_slice(), b"efgh", b"ijkl"]
            .into_iter()
            .enumerate()
        {
            transfer.accept_chunk(index as u32, bytes).unwrap();
        }
        transfer.finalize().unwrap();
        drop(transfer);

        let mut resumed = store.resume(&manifest.resource_id).unwrap().unwrap();
        assert_eq!(resumed.read_chunk(1).unwrap(), b"efgh");
    }

    #[test]
    fn cancellation_removes_resume_state_and_is_idempotent() {
        let directory = tempdir().unwrap();
        let store = DiskResourceStore::open(directory.path()).unwrap();
        let manifest = manifest("cancel", b"abcdefgh");
        let mut transfer = store.begin(manifest.clone()).unwrap();
        transfer.accept_chunk(0, b"abcd").unwrap();
        drop(transfer);
        assert!(store.cancel(&manifest.resource_id).unwrap());
        assert!(!store.cancel(&manifest.resource_id).unwrap());
        assert!(store.resume(&manifest.resource_id).unwrap().is_none());
    }

    #[test]
    fn empty_resources_finalize_and_resume_as_complete() {
        let directory = tempdir().unwrap();
        let store = DiskResourceStore::open(directory.path()).unwrap();
        let manifest = manifest("empty", b"");
        let mut transfer = store.begin(manifest.clone()).unwrap();
        let object = transfer.finalize().unwrap();
        assert_eq!(fs::read(object).unwrap(), b"");
        drop(transfer);
        assert!(store
            .resume(&manifest.resource_id)
            .unwrap()
            .unwrap()
            .is_complete());
    }

    #[test]
    fn corrupted_completed_object_reverts_to_missing_chunks() {
        let directory = tempdir().unwrap();
        let store = DiskResourceStore::open(directory.path()).unwrap();
        let manifest = manifest("corrupted-object", b"abcdefgh");
        let mut transfer = store.begin(manifest.clone()).unwrap();
        transfer.accept_chunk(0, b"abcd").unwrap();
        transfer.accept_chunk(1, b"efgh").unwrap();
        let object = transfer.finalize().unwrap();
        fs::write(&object, b"bad-data").unwrap();
        drop(transfer);

        let retry = store.resume(&manifest.resource_id).unwrap().unwrap();
        assert!(!retry.is_complete());
        assert_eq!(
            retry.missing_chunks().unwrap(),
            [0, 1].into_iter().collect()
        );
        assert!(!object.exists());
    }

    #[test]
    fn unsafe_resource_ids_cannot_escape_the_store_root() {
        let directory = tempdir().unwrap();
        let store = DiskResourceStore::open(directory.path()).unwrap();
        let manifest = manifest("../../outside", b"safe");
        let transfer = store.begin(manifest).unwrap();
        assert!(transfer.transfer_dir.starts_with(directory.path()));
        assert!(!directory.path().parent().unwrap().join("outside").exists());
    }

    #[test]
    fn cleanup_removes_abandoned_temporary_files() {
        let directory = tempdir().unwrap();
        let store = DiskResourceStore::open(directory.path()).unwrap();
        let abandoned = store.root.join(OBJECTS_DIR).join(".tc-tmp-crash");
        fs::write(&abandoned, b"partial").unwrap();
        let report = store.cleanup().unwrap();
        assert_eq!(report.temporary_files, 1);
        assert!(!abandoned.exists());
    }
}
