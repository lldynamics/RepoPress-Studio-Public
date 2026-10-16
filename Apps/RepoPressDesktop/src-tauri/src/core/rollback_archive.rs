//! Confirmation-bound, private, no-clobber local copy of frozen rollback evidence.
use super::{CommandError, CommandResult, RollbackRecord, RollbackTransactionStore};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

const LIFETIME: Duration = Duration::from_secs(300);
const MAX_PLANS: usize = 8;
const MAX_BYTES: usize = 8 * 1024 * 1024;
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RollbackArchivePlan {
    pub plan_id: String,
    pub session_id: String,
    pub repository_path: String,
    pub destination_path: String,
    pub schema_version: u8,
    pub record_count: usize,
    pub unresolved_count: usize,
    pub historical_observation_count: usize,
    pub byte_size: usize,
    pub sha256: String,
    pub created_at_epoch_ms: u64,
    pub expires_at_epoch_ms: u64,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RollbackArchiveResult {
    pub plan_id: String,
    pub session_id: String,
    pub destination_path: String,
    pub record_count: usize,
    pub byte_size: usize,
    pub sha256: String,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Archive<'a> {
    format: &'static str,
    schema_version: u8,
    captured_at_epoch_ms: u64,
    repository_path: &'a str,
    records: &'a [RollbackRecord],
}
pub(super) struct Destination {
    path: PathBuf,
    directory: File,
    max_bytes: usize,
}
struct Binding {
    root: PathBuf,
    destination: Destination,
    records: Vec<RollbackRecord>,
    bytes: Vec<u8>,
    preview: RollbackArchivePlan,
    created: Instant,
}
#[derive(Default)]
pub struct RollbackArchiveStore {
    plans: Mutex<HashMap<String, Binding>>,
}
fn invalid() -> CommandError {
    CommandError::new("rollback_archive_invalid", "Archive preview, evidence or destination changed. Choose a new destination and review again; no existing file will be overwritten.")
}
fn failed() -> CommandError {
    CommandError::new("rollback_archive_failed", "Archive could not be confirmed. A private file may already exist at the selected destination; inspect it before choosing a new filename. The ledger was retained.")
}
fn now() -> CommandResult<u64> {
    let value = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| invalid())?
        .as_millis();
    if value == 0 || value > 8_639_999_999_700_000 {
        return Err(invalid());
    }
    Ok(value as u64)
}
impl RollbackArchiveStore {
    pub fn plan(
        &self,
        session: &str,
        root: &Path,
        destination: &Path,
        transactions: &RollbackTransactionStore,
    ) -> CommandResult<RollbackArchivePlan> {
        // A new preview attempt invalidates old consent even when preparation fails.
        let mut plans = self.plans.lock().map_err(|_| invalid())?;
        plans.retain(|_, b| b.created.elapsed() < LIFETIME && b.preview.session_id != session);
        if session.is_empty()
            || session.len() > 160
            || plans.len() >= MAX_PLANS
            || !root.is_absolute()
        {
            return Err(invalid());
        }
        let destination = Destination::new(destination, root)?;
        let records = transactions.list(root)?;
        if records.is_empty() {
            return Err(CommandError::new(
                "rollback_archive_empty",
                "This repository has no rollback evidence to archive.",
            ));
        }
        let created_at_epoch_ms = now()?;
        let repository_path = root.to_str().ok_or_else(invalid)?.to_owned();
        let bytes = serde_json::to_vec(&Archive {
            format: "repopress-rollback-evidence",
            schema_version: 1,
            captured_at_epoch_ms: created_at_epoch_ms,
            repository_path: &repository_path,
            records: &records,
        })
        .map_err(|_| invalid())?;
        if bytes.len() > MAX_BYTES {
            return Err(invalid());
        }
        let historical_observation_count = records
            .iter()
            .filter(|r| r.candidate_observed_at_epoch_ms.is_some())
            .count();
        let preview = RollbackArchivePlan {
            plan_id: Uuid::new_v4().to_string(),
            session_id: session.into(),
            repository_path,
            destination_path: destination.path.to_str().ok_or_else(invalid)?.to_owned(),
            schema_version: 1,
            record_count: records.len(),
            unresolved_count: records.len() - historical_observation_count,
            historical_observation_count,
            byte_size: bytes.len(),
            sha256: format!("{:x}", Sha256::digest(&bytes)),
            created_at_epoch_ms,
            expires_at_epoch_ms: created_at_epoch_ms + 300_000,
        };
        plans.insert(
            preview.plan_id.clone(),
            Binding {
                root: root.into(),
                destination,
                records,
                bytes,
                preview: preview.clone(),
                created: Instant::now(),
            },
        );
        Ok(preview)
    }
    pub fn discard(&self, session: &str, id: &str) -> CommandResult<()> {
        let mut plans = self.plans.lock().map_err(|_| invalid())?;
        if plans
            .get(id)
            .is_some_and(|b| b.preview.session_id == session)
        {
            plans.remove(id);
        }
        Ok(())
    }
    pub fn execute(
        &self,
        session: &str,
        root: &Path,
        id: &str,
        transactions: &RollbackTransactionStore,
        mut check_session: impl FnMut() -> CommandResult<()>,
    ) -> CommandResult<RollbackArchiveResult> {
        // Burn before every check, including a wrong session/root or failed destination.
        let binding = self
            .plans
            .lock()
            .map_err(|_| invalid())?
            .remove(id)
            .ok_or_else(invalid)?;
        if binding.preview.session_id != session
            || binding.root != root
            || binding.created.elapsed() >= LIFETIME
            || now()? >= binding.preview.expires_at_epoch_ms
        {
            return Err(invalid());
        }
        check_session()?;
        transactions.with_archive_snapshot(root, &binding.records, || {
            binding
                .destination
                .write(&binding.bytes, &mut check_session)
        })?;
        check_session()?;
        Ok(RollbackArchiveResult {
            plan_id: binding.preview.plan_id,
            session_id: binding.preview.session_id,
            destination_path: binding.preview.destination_path,
            record_count: binding.preview.record_count,
            byte_size: binding.preview.byte_size,
            sha256: binding.preview.sha256,
        })
    }
}

pub(super) fn directory(path: &Path) -> CommandResult<File> {
    if !cfg!(target_os = "linux")
        || !path.is_absolute()
        || path
            .components()
            .any(|c| matches!(c, Component::ParentDir | Component::CurDir))
    {
        return Err(invalid());
    }
    // Traverse one descriptor-relative component at a time. A concurrent rename
    // or symlink substitution cannot redirect this walk through an alias.
    #[cfg(unix)]
    let file = {
        use std::ffi::CString;
        use std::os::fd::{AsRawFd, FromRawFd};
        use std::os::unix::ffi::OsStrExt;
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_DIRECTORY | libc::O_CLOEXEC)
            .open("/")
            .map_err(|_| invalid())?;
        for component in path.components() {
            if let Component::Normal(name) = component {
                let name = CString::new(name.as_bytes()).map_err(|_| invalid())?;
                let fd = unsafe {
                    libc::openat(
                        file.as_raw_fd(),
                        name.as_ptr(),
                        libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_DIRECTORY | libc::O_CLOEXEC,
                    )
                };
                if fd < 0 {
                    return Err(invalid());
                }
                file = unsafe { File::from_raw_fd(fd) };
            }
        }
        file
    };
    #[cfg(not(unix))]
    let file = File::open(path).map_err(|_| invalid())?;
    let m = file.metadata().map_err(|_| invalid())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if m.uid() != unsafe { libc::geteuid() } || m.mode() & 0o022 != 0 {
            return Err(invalid());
        }
    }
    // Compare the opened directory to its current pathname identity.
    let current = fs::symlink_metadata(path).map_err(|_| invalid())?;
    if !same_identity(&m, &current) || current.file_type().is_symlink() {
        return Err(invalid());
    }
    Ok(file)
}
fn same_identity(a: &fs::Metadata, b: &fs::Metadata) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        a.dev() == b.dev() && a.ino() == b.ino()
    }
    #[cfg(not(unix))]
    {
        let _ = (a, b);
        false
    }
}
fn anchor(file: &File) -> PathBuf {
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        PathBuf::from(format!("/proc/self/fd/{}", file.as_raw_fd()))
    }
    #[cfg(not(unix))]
    {
        let _ = file;
        PathBuf::new()
    }
}
impl Destination {
    pub(super) fn new(path: &Path, root: &Path) -> CommandResult<Self> {
        Self::with_limit(path, root, "json", MAX_BYTES)
    }
    pub(super) fn sqlite_snapshot(path: &Path, root: &Path) -> CommandResult<Self> {
        Self::with_limit(path, root, "sqlite", 32 * 1024 * 1024)
    }
    pub(super) fn knowledge_package(path: &Path, root: &Path) -> CommandResult<Self> {
        Self::with_limit(path, root, "json", super::knowledge_backup::PACKAGE_BYTES)
    }
    fn with_limit(
        path: &Path,
        root: &Path,
        extension: &str,
        max_bytes: usize,
    ) -> CommandResult<Self> {
        if !path.is_absolute()
            || path.starts_with(root)
            || path
                .components()
                .any(|c| matches!(c, Component::ParentDir | Component::CurDir))
            || path.extension().and_then(|s| s.to_str()) != Some(extension)
            || path.as_os_str().len() > 4096
        {
            return Err(invalid());
        }
        let directory = directory(path.parent().ok_or_else(invalid)?)?;
        let result = Self {
            path: path.to_owned(),
            directory,
            max_bytes,
        };
        result.validate()?;
        Ok(result)
    }
    fn validate(&self) -> CommandResult<()> {
        let parent = directory(self.path.parent().ok_or_else(invalid)?)?;
        if !same_identity(
            &parent.metadata().map_err(|_| invalid())?,
            &self.directory.metadata().map_err(|_| invalid())?,
        ) {
            return Err(invalid());
        }
        match fs::symlink_metadata(
            anchor(&self.directory).join(self.path.file_name().ok_or_else(invalid)?),
        ) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            _ => Err(invalid()),
        }
    }
    pub(super) fn write(
        &self,
        bytes: &[u8],
        check: &mut impl FnMut() -> CommandResult<()>,
    ) -> CommandResult<()> {
        if bytes.is_empty() || bytes.len() > self.max_bytes {
            return Err(invalid());
        }
        self.validate()?;
        let anchored = anchor(&self.directory);
        let mut temp = tempfile::Builder::new()
            .prefix(".repopress-rollback-")
            .tempfile_in(&anchored)
            .map_err(|_| failed())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            temp.as_file()
                .set_permissions(fs::Permissions::from_mode(0o600))
                .map_err(|_| failed())?;
        }
        temp.write_all(bytes).map_err(|_| failed())?;
        temp.as_file().sync_all().map_err(|_| failed())?;
        verify_file(temp.as_file_mut(), bytes, self.max_bytes)?;
        check()?;
        self.validate()?;
        let target = anchored.join(self.path.file_name().ok_or_else(invalid)?);
        let persisted = temp.persist_noclobber(&target).map_err(|_| failed())?;
        self.directory.sync_all().map_err(|_| failed())?;
        let mut options = OpenOptions::new();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC);
        }
        let mut confirmed = options.open(&target).map_err(|_| failed())?;
        if !same_identity(
            &persisted.metadata().map_err(|_| failed())?,
            &confirmed.metadata().map_err(|_| failed())?,
        ) {
            return Err(failed());
        }
        verify_file(&mut confirmed, bytes, self.max_bytes)?;
        let current = directory(self.path.parent().ok_or_else(failed)?).map_err(|_| failed())?;
        if !same_identity(
            &current.metadata().map_err(|_| failed())?,
            &self.directory.metadata().map_err(|_| failed())?,
        ) {
            return Err(failed());
        }
        Ok(())
    }
}
fn verify_file(file: &mut File, expected: &[u8], max_bytes: usize) -> CommandResult<()> {
    let m = file.metadata().map_err(|_| failed())?;
    if !m.is_file() || m.len() as usize != expected.len() || expected.len() > max_bytes {
        return Err(failed());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if m.mode() & 0o777 != 0o600 || m.nlink() != 1 || m.uid() != unsafe { libc::geteuid() } {
            return Err(failed());
        }
    }
    file.seek(SeekFrom::Start(0)).map_err(|_| failed())?;
    let mut bytes = Vec::new();
    file.take((max_bytes + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| failed())?;
    if bytes != expected {
        return Err(failed());
    }
    Ok(())
}
#[cfg(test)]
#[path = "rollback_archive_tests.rs"]
mod tests;
