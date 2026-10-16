use super::{CommandError, CommandResult};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};
use tempfile::Builder;

const LOG_DIRECTORY: &str = "operation-log";
const LOG_FILE: &str = "operation-log.json";
const SCHEMA_VERSION: u32 = 1;
const MAX_ENTRIES: usize = 500;
const MAX_LOG_BYTES: u64 = 1024 * 1024;
const MAX_DURATION_MS: u64 = 86_400_000;
const MAX_SEQUENCE: u64 = 9_007_199_254_740_991;
const MEMORY_ONLY_WARNING: &str = "操作日志仅保存在当前会话中，无法安全读取本地日志。";
const WRITE_FAILED_WARNING: &str = "操作日志无法写入本地存储，后续记录仅保留在当前会话中。";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub enum OperationKind {
    SaveDocument,
    MetadataBatch,
    CreateDocument,
    RenameDocument,
    DeleteDocument,
    RestoreDraftVersion,
    RestoreRecycledDraft,
    DeleteRecycledDraft,
    SaveGeneralDraft,
    TransferGeneralDraft,
    UndoGeneralDraftTransfer,
    ImportWritingImage,
    GitIndexUpdate,
    GitOperation,
    RemoteReview,
    KnowledgeImport,
    KnowledgeExport,
    KnowledgeArchiveExport,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub enum OperationOutcome {
    Succeeded,
    Failed,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OperationLogEntry {
    pub sequence: u64,
    pub occurred_at_epoch_ms: u64,
    pub kind: OperationKind,
    pub outcome: OperationOutcome,
    pub repository_key: Option<String>,
    pub duration_ms: u64,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct OperationLogSnapshot {
    pub entries: Vec<OperationLogEntry>,
    pub latest_sequence: u64,
    pub persistent: bool,
    pub warning: Option<String>,
    pub current_repository_key: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PersistedLog {
    schema_version: u32,
    entries: Vec<OperationLogEntry>,
    latest_sequence: u64,
}

impl Default for PersistedLog {
    fn default() -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            entries: Vec::new(),
            latest_sequence: 0,
        }
    }
}

struct StoragePaths {
    directory: PathBuf,
    log_file: PathBuf,
    expected_digest: Option<[u8; 32]>,
}

struct OperationLogState {
    log: PersistedLog,
    storage: Option<StoragePaths>,
    warning: Option<String>,
}

pub struct OperationLogStore {
    state: Mutex<OperationLogState>,
}

impl Default for OperationLogStore {
    fn default() -> Self {
        Self {
            state: Mutex::new(OperationLogState {
                log: PersistedLog::default(),
                storage: None,
                warning: None,
            }),
        }
    }
}

impl OperationLogStore {
    /// Failure to initialize this optional audit trail must never prevent app startup.
    pub fn new(app_data_dir: PathBuf) -> Self {
        match prepare_storage(&app_data_dir).and_then(|mut storage| {
            let (log, digest) = load_log(&storage)?;
            storage.expected_digest = digest;
            Ok((log, storage))
        }) {
            Ok((log, storage)) => Self {
                state: Mutex::new(OperationLogState {
                    log,
                    storage: Some(storage),
                    warning: None,
                }),
            },
            Err(_) => Self {
                state: Mutex::new(OperationLogState {
                    log: PersistedLog::default(),
                    storage: None,
                    warning: Some(MEMORY_ONLY_WARNING.to_string()),
                }),
            },
        }
    }

    /// Records only fixed enum values and a repository digest; persistence failure is non-fatal.
    pub fn record(
        &self,
        kind: OperationKind,
        outcome: OperationOutcome,
        repository_key: Option<String>,
        duration_ms: u64,
    ) {
        let Ok(mut state) = self.state.lock() else {
            return;
        };
        if state.log.latest_sequence >= MAX_SEQUENCE {
            state.warning = Some(WRITE_FAILED_WARNING.to_string());
            return;
        }
        let entry = OperationLogEntry {
            sequence: state.log.latest_sequence + 1,
            occurred_at_epoch_ms: now_epoch_ms(),
            kind,
            outcome,
            repository_key: repository_key.filter(|value| valid_repository_key(value)),
            duration_ms: duration_ms.min(MAX_DURATION_MS),
        };
        state.log.latest_sequence = entry.sequence;
        state.log.entries.push(entry);
        if state.log.entries.len() > MAX_ENTRIES {
            let excess = state.log.entries.len() - MAX_ENTRIES;
            state.log.entries.drain(..excess);
        }
        persist_or_fallback(&mut state);
    }

    pub fn snapshot(&self) -> CommandResult<OperationLogSnapshot> {
        let state = self.state.lock().map_err(|_| unavailable())?;
        Ok(snapshot_from_state(&state))
    }

    pub fn clear_through(&self, through_sequence: u64) -> CommandResult<OperationLogSnapshot> {
        let mut state = self.state.lock().map_err(|_| unavailable())?;
        if through_sequence > state.log.latest_sequence {
            return Err(CommandError::new(
                "operation_log_future_sequence",
                "The requested operation-log sequence has not been recorded.",
            ));
        }
        let mut candidate = state.log.clone();
        candidate
            .entries
            .retain(|entry| entry.sequence > through_sequence);
        if let Some(storage) = state.storage.as_mut() {
            if write_log(storage, &candidate).is_err() {
                state.storage = None;
                state.warning = Some(WRITE_FAILED_WARNING.to_string());
                return Err(CommandError::new(
                    "operation_log_persist_failed",
                    "Unable to safely update the operation log.",
                ));
            }
        }
        state.log = candidate;
        Ok(snapshot_from_state(&state))
    }
}

pub fn operation_repository_key(root: &Path) -> String {
    format!("{:x}", Sha256::digest(root.as_os_str().as_encoded_bytes()))
}

fn snapshot_from_state(state: &OperationLogState) -> OperationLogSnapshot {
    let mut entries = state.log.entries.clone();
    entries.reverse();
    OperationLogSnapshot {
        entries,
        latest_sequence: state.log.latest_sequence,
        persistent: state.storage.is_some(),
        warning: state.warning.clone(),
        current_repository_key: None,
    }
}

fn persist_or_fallback(state: &mut OperationLogState) {
    let Some(storage) = state.storage.as_mut() else {
        return;
    };
    if write_log(storage, &state.log).is_err() {
        state.storage = None;
        state.warning = Some(WRITE_FAILED_WARNING.to_string());
    }
}

fn prepare_storage(app_data_dir: &Path) -> CommandResult<StoragePaths> {
    fs::create_dir_all(app_data_dir).map_err(|_| storage_error())?;
    let directory = app_data_dir.join(LOG_DIRECTORY);
    match fs::symlink_metadata(&directory) {
        Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => {}
        Ok(_) => return Err(storage_error()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            fs::create_dir(&directory).map_err(|_| storage_error())?;
        }
        Err(_) => return Err(storage_error()),
    }
    set_private_directory_permissions(&directory)?;
    validate_storage_directory(&directory)?;
    Ok(StoragePaths {
        log_file: directory.join(LOG_FILE),
        directory,
        expected_digest: None,
    })
}

fn load_log(storage: &StoragePaths) -> CommandResult<(PersistedLog, Option<[u8; 32]>)> {
    validate_storage_directory(&storage.directory)?;
    let metadata = match fs::symlink_metadata(&storage.log_file) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok((PersistedLog::default(), None));
        }
        Err(_) => return Err(storage_error()),
    };
    validate_private_log_file(&metadata)?;
    if metadata.len() > MAX_LOG_BYTES {
        return Err(storage_error());
    }
    let bytes = read_log_file(&storage.log_file)?;
    if bytes.len() as u64 > MAX_LOG_BYTES {
        return Err(storage_error());
    }
    let log = serde_json::from_slice::<PersistedLog>(&bytes).map_err(|_| storage_error())?;
    validate_log(&log)?;
    Ok((log, Some(Sha256::digest(&bytes).into())))
}

fn write_log(storage: &mut StoragePaths, log: &PersistedLog) -> CommandResult<()> {
    validate_log(log)?;
    validate_storage_directory(&storage.directory)?;
    let encoded = serde_json::to_vec(log).map_err(|_| storage_error())?;
    if encoded.len() as u64 > MAX_LOG_BYTES {
        return Err(storage_error());
    }
    verify_store_unchanged(storage)?;
    let mut temporary = Builder::new()
        .prefix(".operation-log-")
        .tempfile_in(&storage.directory)
        .map_err(|_| storage_error())?;
    set_private_file_permissions(temporary.path())?;
    temporary
        .as_file_mut()
        .write_all(&encoded)
        .map_err(|_| storage_error())?;
    temporary
        .as_file_mut()
        .sync_all()
        .map_err(|_| storage_error())?;
    // Recheck immediately before resolving the destination path. This catches a
    // storage directory moved and replaced by a symlink after startup.
    validate_storage_directory(&storage.directory)?;
    temporary
        .persist(&storage.log_file)
        .map_err(|_| storage_error())?;
    set_private_file_permissions(&storage.log_file)?;
    sync_directory(&storage.directory)?;
    storage.expected_digest = Some(Sha256::digest(&encoded).into());
    Ok(())
}

fn verify_store_unchanged(storage: &StoragePaths) -> CommandResult<()> {
    validate_storage_directory(&storage.directory)?;
    let metadata = match fs::symlink_metadata(&storage.log_file) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return if storage.expected_digest.is_none() {
                Ok(())
            } else {
                Err(storage_error())
            };
        }
        Err(_) => return Err(storage_error()),
    };
    validate_private_log_file(&metadata)?;
    if metadata.len() > MAX_LOG_BYTES {
        return Err(storage_error());
    }
    let bytes = read_log_file(&storage.log_file)?;
    if bytes.len() as u64 > MAX_LOG_BYTES {
        return Err(storage_error());
    }
    let digest: [u8; 32] = Sha256::digest(&bytes).into();
    if storage.expected_digest != Some(digest) {
        return Err(storage_error());
    }
    Ok(())
}

fn read_log_file(path: &Path) -> CommandResult<Vec<u8>> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // O_NONBLOCK ensures an attacker-replaced FIFO cannot make startup or
        // record handling block before its file type is rejected below.
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let mut file = options.open(path).map_err(|_| storage_error())?;
    let metadata = file.metadata().map_err(|_| storage_error())?;
    validate_private_log_file(&metadata)?;
    if metadata.len() > MAX_LOG_BYTES {
        return Err(storage_error());
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    Read::by_ref(&mut file)
        .take(MAX_LOG_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| storage_error())?;
    Ok(bytes)
}

fn validate_log(log: &PersistedLog) -> CommandResult<()> {
    if log.schema_version != SCHEMA_VERSION
        || log.entries.len() > MAX_ENTRIES
        || log.latest_sequence > MAX_SEQUENCE
    {
        return Err(storage_error());
    }
    let mut previous = 0;
    for entry in &log.entries {
        if entry.sequence == 0
            || entry.sequence > MAX_SEQUENCE
            || entry.sequence <= previous
            || entry.sequence > log.latest_sequence
            || entry.duration_ms > MAX_DURATION_MS
            || entry
                .repository_key
                .as_deref()
                .is_some_and(|value| !valid_repository_key(value))
        {
            return Err(storage_error());
        }
        previous = entry.sequence;
    }
    Ok(())
}

fn valid_repository_key(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

fn now_epoch_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u128::from(u64::MAX)) as u64
}

fn unavailable() -> CommandError {
    CommandError::new(
        "operation_log_unavailable",
        "Operation log is temporarily unavailable.",
    )
}

fn storage_error() -> CommandError {
    CommandError::new(
        "operation_log_storage_unsafe",
        "Operation log storage is unavailable.",
    )
}

fn validate_private_log_file(metadata: &fs::Metadata) -> CommandResult<()> {
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(storage_error());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.mode() & 0o777 != 0o600 {
            return Err(storage_error());
        }
    }
    Ok(())
}

fn validate_storage_directory(path: &Path) -> CommandResult<()> {
    let metadata = fs::symlink_metadata(path).map_err(|_| storage_error())?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(storage_error());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.mode() & 0o777 != 0o700 {
            return Err(storage_error());
        }
    }
    Ok(())
}

#[cfg(unix)]
fn set_private_directory_permissions(path: &Path) -> CommandResult<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(|_| storage_error())
}

#[cfg(not(unix))]
fn set_private_directory_permissions(_path: &Path) -> CommandResult<()> {
    Ok(())
}

#[cfg(unix)]
fn set_private_file_permissions(path: &Path) -> CommandResult<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(|_| storage_error())
}

#[cfg(not(unix))]
fn set_private_file_permissions(_path: &Path) -> CommandResult<()> {
    Ok(())
}

#[cfg(unix)]
fn sync_directory(path: &Path) -> CommandResult<()> {
    File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(|_| storage_error())
}

#[cfg(not(unix))]
fn sync_directory(_path: &Path) -> CommandResult<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::thread;

    fn key() -> String {
        operation_repository_key(Path::new("/private/repository"))
    }

    fn record(store: &OperationLogStore) {
        store.record(
            OperationKind::SaveDocument,
            OperationOutcome::Succeeded,
            Some(key()),
            4,
        );
    }

    fn persistent_store() -> (tempfile::TempDir, OperationLogStore) {
        let directory = tempfile::tempdir().unwrap();
        let store = OperationLogStore::new(directory.path().to_path_buf());
        assert!(store.snapshot().unwrap().persistent);
        (directory, store)
    }

    #[test]
    fn persists_across_restart_and_returns_descending_sequence() {
        let (directory, store) = persistent_store();
        record(&store);
        record(&store);
        drop(store);
        let restored = OperationLogStore::new(directory.path().to_path_buf());
        let snapshot = restored.snapshot().unwrap();
        assert!(snapshot.persistent);
        assert_eq!(snapshot.latest_sequence, 2);
        assert_eq!(
            snapshot
                .entries
                .iter()
                .map(|entry| entry.sequence)
                .collect::<Vec<_>>(),
            vec![2, 1]
        );
        assert_eq!(snapshot.current_repository_key, None);
    }

    #[test]
    fn keeps_only_five_hundred_entries_and_sequence_never_reuses_after_clear() {
        let (_directory, store) = persistent_store();
        for _ in 0..503 {
            record(&store);
        }
        let snapshot = store.snapshot().unwrap();
        assert_eq!(snapshot.entries.len(), MAX_ENTRIES);
        assert_eq!(snapshot.entries[0].sequence, 503);
        assert_eq!(snapshot.entries[MAX_ENTRIES - 1].sequence, 4);
        store.clear_through(503).unwrap();
        record(&store);
        let snapshot = store.snapshot().unwrap();
        assert_eq!(snapshot.latest_sequence, 504);
        assert_eq!(snapshot.entries[0].sequence, 504);
    }

    #[test]
    fn clear_preserves_later_records_and_rejects_future_sequence() {
        let (_directory, store) = persistent_store();
        record(&store);
        record(&store);
        record(&store);
        let snapshot = store.clear_through(2).unwrap();
        assert_eq!(
            snapshot
                .entries
                .iter()
                .map(|entry| entry.sequence)
                .collect::<Vec<_>>(),
            vec![3]
        );
        let error = store.clear_through(4).unwrap_err();
        assert_eq!(error.code, "operation_log_future_sequence");
        assert_eq!(store.snapshot().unwrap().latest_sequence, 3);
    }

    #[test]
    fn serialized_log_contains_no_root_or_arbitrary_text() {
        let (directory, store) = persistent_store();
        store.record(
            OperationKind::GitOperation,
            OperationOutcome::Failed,
            Some(operation_repository_key(Path::new("/secret/work/path"))),
            MAX_DURATION_MS + 1,
        );
        let bytes = fs::read(directory.path().join(LOG_DIRECTORY).join(LOG_FILE)).unwrap();
        let text = String::from_utf8(bytes).unwrap();
        assert!(!text.contains("/secret/work/path"));
        assert!(!text.contains("token"));
        let value: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(value["entries"][0]["durationMs"], MAX_DURATION_MS);
        assert!(
            value["entries"][0]
                .get("repositoryKey")
                .unwrap()
                .as_str()
                .unwrap()
                .len()
                == 64
        );
    }

    #[test]
    fn corrupt_oversized_and_unknown_field_logs_fall_back_without_overwriting_them() {
        for content in [
            b"not json".as_slice(),
            br#"{"schemaVersion":1,"entries":[],"latestSequence":0,"extra":true}"#,
        ] {
            let directory = tempfile::tempdir().unwrap();
            let log_directory = directory.path().join(LOG_DIRECTORY);
            fs::create_dir(&log_directory).unwrap();
            set_private_directory_permissions(&log_directory).unwrap();
            let file = log_directory.join(LOG_FILE);
            fs::write(&file, content).unwrap();
            set_private_file_permissions(&file).unwrap();
            let store = OperationLogStore::new(directory.path().to_path_buf());
            assert!(!store.snapshot().unwrap().persistent);
            record(&store);
            assert_eq!(fs::read(&file).unwrap(), content);
        }
        let directory = tempfile::tempdir().unwrap();
        let log_directory = directory.path().join(LOG_DIRECTORY);
        fs::create_dir(&log_directory).unwrap();
        set_private_directory_permissions(&log_directory).unwrap();
        let file = log_directory.join(LOG_FILE);
        fs::write(&file, vec![b'x'; MAX_LOG_BYTES as usize + 1]).unwrap();
        set_private_file_permissions(&file).unwrap();
        assert!(
            !OperationLogStore::new(directory.path().to_path_buf())
                .snapshot()
                .unwrap()
                .persistent
        );
    }

    #[test]
    fn invalid_enum_hash_duplicate_and_unordered_sequences_are_rejected() {
        let invalid_logs = [
            (
                br#"{"schemaVersion":1,"entries":[{"sequence":1,"occurredAtEpochMs":1,"kind":"arbitraryText","outcome":"succeeded","repositoryKey":null,"durationMs":0}],"latestSequence":1}"#
                    .as_slice(),
                true,
            ),
            (
                br#"{"schemaVersion":1,"entries":[{"sequence":1,"occurredAtEpochMs":1,"kind":"saveDocument","outcome":"succeeded","repositoryKey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","durationMs":0}],"latestSequence":1}"#,
                false,
            ),
            (
                br#"{"schemaVersion":1,"entries":[{"sequence":2,"occurredAtEpochMs":1,"kind":"saveDocument","outcome":"succeeded","repositoryKey":null,"durationMs":0},{"sequence":2,"occurredAtEpochMs":2,"kind":"saveDocument","outcome":"succeeded","repositoryKey":null,"durationMs":0}],"latestSequence":2}"#,
                false,
            ),
            (
                br#"{"schemaVersion":1,"entries":[{"sequence":2,"occurredAtEpochMs":1,"kind":"saveDocument","outcome":"succeeded","repositoryKey":null,"durationMs":0},{"sequence":1,"occurredAtEpochMs":2,"kind":"saveDocument","outcome":"succeeded","repositoryKey":null,"durationMs":0}],"latestSequence":2}"#,
                false,
            ),
        ];
        for (content, rejects_deserialization) in invalid_logs {
            let parsed = serde_json::from_slice::<PersistedLog>(content);
            if rejects_deserialization {
                assert!(parsed.is_err());
            } else {
                assert!(validate_log(&parsed.unwrap()).is_err());
            }
            let directory = tempfile::tempdir().unwrap();
            let log_directory = directory.path().join(LOG_DIRECTORY);
            fs::create_dir(&log_directory).unwrap();
            set_private_directory_permissions(&log_directory).unwrap();
            let file = log_directory.join(LOG_FILE);
            fs::write(&file, content).unwrap();
            set_private_file_permissions(&file).unwrap();
            let store = OperationLogStore::new(directory.path().to_path_buf());
            assert!(!store.snapshot().unwrap().persistent);
        }
    }

    #[cfg(unix)]
    #[test]
    fn symlink_is_rejected_and_created_storage_is_private() {
        use std::os::unix::fs::{symlink, MetadataExt};
        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("target");
        fs::write(&target, b"{}").unwrap();
        let log_directory = directory.path().join(LOG_DIRECTORY);
        fs::create_dir(&log_directory).unwrap();
        set_private_directory_permissions(&log_directory).unwrap();
        symlink(&target, log_directory.join(LOG_FILE)).unwrap();
        assert!(
            !OperationLogStore::new(directory.path().to_path_buf())
                .snapshot()
                .unwrap()
                .persistent
        );

        let clean = tempfile::tempdir().unwrap();
        let store = OperationLogStore::new(clean.path().to_path_buf());
        record(&store);
        let directory_metadata = fs::metadata(clean.path().join(LOG_DIRECTORY)).unwrap();
        let file_metadata = fs::metadata(clean.path().join(LOG_DIRECTORY).join(LOG_FILE)).unwrap();
        assert_eq!(directory_metadata.mode() & 0o777, 0o700);
        assert_eq!(file_metadata.mode() & 0o777, 0o600);
    }

    #[cfg(unix)]
    #[test]
    fn fifo_and_replaced_storage_directory_never_receive_log_writes() {
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;
        use std::os::unix::fs::symlink;

        let fifo_root = tempfile::tempdir().unwrap();
        let fifo_directory = fifo_root.path().join(LOG_DIRECTORY);
        fs::create_dir(&fifo_directory).unwrap();
        set_private_directory_permissions(&fifo_directory).unwrap();
        let fifo = fifo_directory.join(LOG_FILE);
        let fifo_path = CString::new(fifo.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo_path.as_ptr(), 0o600) }, 0);
        // If O_NONBLOCK were absent this direct open could wait forever for a writer.
        assert!(read_log_file(&fifo).is_err());
        assert!(
            !OperationLogStore::new(fifo_root.path().to_path_buf())
                .snapshot()
                .unwrap()
                .persistent
        );

        let (directory, store) = persistent_store();
        record(&store);
        let log_directory = directory.path().join(LOG_DIRECTORY);
        let moved_directory = directory.path().join("operation-log-moved");
        let replacement_directory = directory.path().join("outside");
        fs::rename(&log_directory, &moved_directory).unwrap();
        fs::create_dir(&replacement_directory).unwrap();
        set_private_directory_permissions(&replacement_directory).unwrap();
        symlink(&replacement_directory, &log_directory).unwrap();
        record(&store);
        assert!(!store.snapshot().unwrap().persistent);
        assert!(!replacement_directory.join(LOG_FILE).exists());
    }

    #[test]
    fn persistence_drift_falls_back_without_panicking() {
        let (directory, store) = persistent_store();
        record(&store);
        let file = directory.path().join(LOG_DIRECTORY).join(LOG_FILE);
        fs::remove_file(&file).unwrap();
        fs::create_dir(&file).unwrap();
        record(&store);
        let snapshot = store.snapshot().unwrap();
        assert!(!snapshot.persistent);
        assert_eq!(snapshot.warning.as_deref(), Some(WRITE_FAILED_WARNING));
        assert_eq!(snapshot.latest_sequence, 2);
    }

    #[test]
    fn clear_persistence_failure_retains_the_original_memory_entries() {
        let (directory, store) = persistent_store();
        record(&store);
        record(&store);
        let file = directory.path().join(LOG_DIRECTORY).join(LOG_FILE);
        fs::remove_file(&file).unwrap();
        fs::create_dir(&file).unwrap();
        let error = store.clear_through(1).unwrap_err();
        assert_eq!(error.code, "operation_log_persist_failed");
        let snapshot = store.snapshot().unwrap();
        assert_eq!(
            snapshot
                .entries
                .iter()
                .map(|entry| entry.sequence)
                .collect::<Vec<_>>(),
            vec![2, 1]
        );
        assert!(!snapshot.persistent);
    }

    #[test]
    fn concurrent_recording_keeps_all_sequences_before_bound() {
        let (_directory, store) = persistent_store();
        let store = Arc::new(store);
        let mut handles = Vec::new();
        for _ in 0..8 {
            let store = Arc::clone(&store);
            handles.push(thread::spawn(move || {
                for _ in 0..75 {
                    record(&store);
                }
            }));
        }
        for handle in handles {
            handle.join().unwrap();
        }
        let snapshot = store.snapshot().unwrap();
        assert_eq!(snapshot.latest_sequence, 600);
        assert_eq!(snapshot.entries.len(), MAX_ENTRIES);
        assert_eq!(snapshot.entries[0].sequence, 600);
        assert_eq!(snapshot.entries[MAX_ENTRIES - 1].sequence, 101);
    }

    #[test]
    fn repository_keys_are_distinct_fixed_sha256_values() {
        let one = operation_repository_key(Path::new("/one"));
        let two = operation_repository_key(Path::new("/two"));
        assert_ne!(one, two);
        assert!(valid_repository_key(&one));
        assert_eq!(one.len(), 64);
    }

    #[test]
    fn invalid_repository_key_is_not_retained() {
        let (_directory, store) = persistent_store();
        store.record(
            OperationKind::KnowledgeImport,
            OperationOutcome::Succeeded,
            Some("secret text".to_string()),
            0,
        );
        assert_eq!(store.snapshot().unwrap().entries[0].repository_key, None);
    }
}
