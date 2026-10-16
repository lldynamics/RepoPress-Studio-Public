//! Read-only allowlisted file metadata. Never opens SQLite or reads payloads.
use super::{CommandError, CommandResult};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeSet, HashMap};
use std::fs::{self, File, Metadata};
use std::path::{Component, Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

const TTL: Duration = Duration::from_secs(300);
const MAX_REPORTS: usize = 8;
const MAX_ENTRIES: usize = 2048;
const MAX_GLOBAL_ENTRIES: usize = 8192;
const MAX_BYTES: u64 = 8 * 1024 * 1024 * 1024;
const MAX_FILE_BYTES: u64 = 512 * 1024 * 1024;
const SCAN_TIME: Duration = Duration::from_secs(5);
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum BackupSource {
    Knowledge,
    Rss,
    GeneralDrafts,
    DraftHistory,
    Workspace,
    SiteProfiles,
    AiProfiles,
}
impl BackupSource {
    fn location(self) -> (&'static str, &'static str) {
        match self {
            Self::Knowledge => ("knowledge-v1", "manifest.json"),
            Self::Rss => ("RSSReader", "reader.sqlite"),
            Self::GeneralDrafts => ("GeneralDrafts", "general-drafts.sqlite"),
            Self::DraftHistory => ("DraftHistory", "history.sqlite"),
            Self::Workspace => ("workspace", "workspace-state.json"),
            Self::SiteProfiles => ("site-profiles", "registry.json"),
            Self::AiProfiles => ("ai-provider-profiles-v1", "profiles.json"),
        }
    }
    fn database(self) -> bool {
        matches!(self, Self::Rss | Self::GeneralDrafts | Self::DraftHistory)
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum InventoryStatus {
    MetadataOnly,
    NotFound,
    Unavailable,
    Limited,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum InventoryIssue {
    UnsafeEntry,
    ReadFailed,
    EntryLimit,
    ByteLimit,
    TimeLimit,
    UnknownEntries,
    PrimaryMissing,
    ChangedDuringRead,
    StorageUnavailable,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BackupSourceInventory {
    pub source: BackupSource,
    pub status: InventoryStatus,
    pub file_count: Option<usize>,
    pub byte_count: Option<u64>,
    pub omitted_entries: Option<usize>,
    pub issues: Vec<InventoryIssue>,
    pub requires_database_snapshot: bool,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceBackupReport {
    pub report_id: String,
    pub schema_version: u8,
    pub scope: &'static str,
    pub checked_at_epoch_ms: u64,
    pub expires_at_epoch_ms: u64,
    pub selected_sources: Vec<BackupSource>,
    pub sources: Vec<BackupSourceInventory>,
    pub exclusions: Vec<&'static str>,
    pub content_verified: bool,
    pub consistent_snapshot: bool,
}
#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum BackupComparison {
    Unchanged,
    Changed,
    Inconclusive,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceBackupRecheck {
    pub report: WorkspaceBackupReport,
    pub comparison: BackupComparison,
}
const EXCLUSIONS: [&str; 8] = [
    "credentials",
    "encryptedChat",
    "releaseLedgers",
    "operationLogs",
    "repositoryFiles",
    "externalAttachments",
    "runtimeState",
    "unknownLocations",
];
#[derive(Clone, Debug, Eq, PartialEq)]
struct Stamp {
    dev: u64,
    ino: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    links: u64,
    size: u64,
    modified: (i64, i64),
    changed: (i64, i64),
}
#[cfg(unix)]
fn stamp(m: &Metadata) -> Stamp {
    use std::os::unix::fs::MetadataExt;
    Stamp {
        dev: m.dev(),
        ino: m.ino(),
        mode: m.mode(),
        uid: m.uid(),
        gid: m.gid(),
        links: m.nlink(),
        size: m.len(),
        modified: (m.mtime(), m.mtime_nsec()),
        changed: (m.ctime(), m.ctime_nsec()),
    }
}
#[cfg(not(unix))]
fn stamp(_: &Metadata) -> Stamp {
    Stamp {
        dev: 0,
        ino: 0,
        mode: 0,
        uid: 0,
        gid: 0,
        links: 0,
        size: 0,
        modified: (0, 0),
        changed: (0, 0),
    }
}
#[derive(Clone, Debug, Eq, PartialEq)]
struct Witness {
    path: PathBuf,
    stamp: Stamp,
    directory: bool,
}
struct Root {
    path: PathBuf,
    handle: File,
    identity: (u64, u64, u32, u32),
}
struct Binding {
    report: WorkspaceBackupReport,
    witnesses: Vec<Witness>,
    created: Instant,
}
#[derive(Default)]
pub struct WorkspaceBackupStore {
    root: Option<Root>,
    reports: Mutex<HashMap<String, Binding>>,
}
fn invalid() -> CommandError {
    CommandError::new("workspace_backup_invalid", "Backup metadata report is unavailable, expired or changed. Inspect the selected scope again; no backup or restore was performed.")
}
fn time() -> CommandResult<u64> {
    let value = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| invalid())?
        .as_millis();
    if value == 0 || value > 8_639_999_999_700_000 {
        return Err(invalid());
    }
    Ok(value as u64)
}
#[cfg(unix)]
fn owned(m: &Metadata, private: bool) -> bool {
    use std::os::unix::fs::MetadataExt;
    m.uid() == unsafe { libc::geteuid() } && m.mode() & if private { 0o077 } else { 0o022 } == 0
}
#[cfg(not(unix))]
fn owned(_: &Metadata, _: bool) -> bool {
    false
}
// O_PATH obtains metadata without opening file contents, FIFO devices or the database engine.
#[cfg(target_os = "linux")]
pub(super) fn walk(base: &File, relative: &Path, directory: bool) -> std::io::Result<File> {
    use std::ffi::CString;
    use std::os::fd::{AsRawFd, FromRawFd};
    use std::os::unix::ffi::OsStrExt;
    let mut current = base.try_clone()?;
    let components: Vec<_> = relative.components().collect();
    for (index, part) in components.iter().enumerate() {
        let Component::Normal(name) = part else {
            return Err(std::io::Error::from(std::io::ErrorKind::InvalidInput));
        };
        let name = CString::new(name.as_bytes()).map_err(|_| std::io::ErrorKind::InvalidInput)?;
        let is_dir = index + 1 < components.len() || directory;
        let flags = libc::O_PATH
            | libc::O_NOFOLLOW
            | libc::O_CLOEXEC
            | if is_dir { libc::O_DIRECTORY } else { 0 };
        let fd = unsafe { libc::openat(current.as_raw_fd(), name.as_ptr(), flags) };
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        current = unsafe { File::from_raw_fd(fd) };
    }
    Ok(current)
}
#[cfg(not(target_os = "linux"))]
pub(super) fn walk(_: &File, _: &Path, _: bool) -> std::io::Result<File> {
    Err(std::io::ErrorKind::Unsupported.into())
}
pub(super) fn root_handle(path: &Path) -> CommandResult<File> {
    if !cfg!(target_os = "linux")
        || !path.is_absolute()
        || path
            .components()
            .any(|c| matches!(c, Component::CurDir | Component::ParentDir))
    {
        return Err(invalid());
    }
    let base = File::open("/").map_err(|_| invalid())?;
    let relative = path.strip_prefix("/").map_err(|_| invalid())?;
    let handle = walk(&base, relative, true).map_err(|_| invalid())?;
    if !owned(&handle.metadata().map_err(|_| invalid())?, false) {
        return Err(invalid());
    }
    Ok(handle)
}
fn root_identity(file: &File) -> CommandResult<(u64, u64, u32, u32)> {
    let s = stamp(&file.metadata().map_err(|_| invalid())?);
    Ok((s.dev, s.ino, s.mode, s.uid))
}
impl WorkspaceBackupStore {
    pub fn new(path: PathBuf) -> Self {
        let root = root_handle(&path).ok().and_then(|handle| {
            root_identity(&handle).ok().map(|identity| Root {
                path,
                handle,
                identity,
            })
        });
        Self {
            root,
            reports: Mutex::new(HashMap::new()),
        }
    }
    pub fn inspect(&self, mut sources: Vec<BackupSource>) -> CommandResult<WorkspaceBackupReport> {
        if sources.is_empty()
            || sources.len() > 7
            || sources.iter().copied().collect::<BTreeSet<_>>().len() != sources.len()
        {
            return Err(invalid());
        }
        sources.sort();
        self.capture(sources).map(|(report, _)| report)
    }
    pub fn discard(&self, id: &str) -> CommandResult<()> {
        self.reports.lock().map_err(|_| invalid())?.remove(id);
        Ok(())
    }
    pub fn recheck(&self, id: &str) -> CommandResult<WorkspaceBackupRecheck> {
        let previous = self
            .reports
            .lock()
            .map_err(|_| invalid())?
            .remove(id)
            .ok_or_else(invalid)?;
        if previous.created.elapsed() >= TTL || time()? >= previous.report.expires_at_epoch_ms {
            return Err(invalid());
        }
        let (report, witnesses) = self.capture(previous.report.selected_sources.clone())?;
        let complete = |r: &WorkspaceBackupReport| {
            r.sources.iter().all(|s| {
                matches!(
                    s.status,
                    InventoryStatus::MetadataOnly | InventoryStatus::NotFound
                )
            })
        };
        let comparison = if !complete(&previous.report) || !complete(&report) {
            BackupComparison::Inconclusive
        } else if previous.report.sources == report.sources && previous.witnesses == witnesses {
            BackupComparison::Unchanged
        } else {
            BackupComparison::Changed
        };
        Ok(WorkspaceBackupRecheck { report, comparison })
    }
    fn root_valid(&self) -> bool {
        self.root.as_ref().is_some_and(|r| {
            root_handle(&r.path).and_then(|f| root_identity(&f)).ok() == Some(r.identity)
        })
    }
    fn capture(
        &self,
        sources: Vec<BackupSource>,
    ) -> CommandResult<(WorkspaceBackupReport, Vec<Witness>)> {
        let mut budget = Budget {
            entries: 0,
            bytes: 0,
            started: Instant::now(),
        };
        let mut witnesses = Vec::new();
        let valid = self.root_valid();
        let mut rows = Vec::new();
        for source in &sources {
            if valid {
                let (row, proof) = scan_source(
                    &self.root.as_ref().expect("checked").handle,
                    *source,
                    &mut budget,
                );
                rows.push(row);
                witnesses.extend(proof);
            } else {
                rows.push(unavailable(*source, InventoryIssue::StorageUnavailable));
            }
        }
        if !self.root_valid() {
            rows = sources
                .iter()
                .map(|s| unavailable(*s, InventoryIssue::StorageUnavailable))
                .collect();
            witnesses.clear();
        }
        witnesses.sort_by(|a, b| a.path.cmp(&b.path));
        let checked_at_epoch_ms = time()?;
        let report = WorkspaceBackupReport {
            report_id: Uuid::new_v4().to_string(),
            schema_version: 1,
            scope: "applicationPrivateData",
            checked_at_epoch_ms,
            expires_at_epoch_ms: checked_at_epoch_ms + 300_000,
            selected_sources: sources,
            sources: rows,
            exclusions: EXCLUSIONS.to_vec(),
            content_verified: false,
            consistent_snapshot: false,
        };
        let mut reports = self.reports.lock().map_err(|_| invalid())?;
        reports.retain(|_, b| b.created.elapsed() < TTL);
        if reports.len() >= MAX_REPORTS {
            return Err(invalid());
        }
        reports.insert(
            report.report_id.clone(),
            Binding {
                report: report.clone(),
                witnesses: witnesses.clone(),
                created: Instant::now(),
            },
        );
        Ok((report, witnesses))
    }
}
fn unavailable(source: BackupSource, issue: InventoryIssue) -> BackupSourceInventory {
    BackupSourceInventory {
        source,
        status: InventoryStatus::Unavailable,
        file_count: None,
        byte_count: None,
        omitted_entries: None,
        issues: vec![issue],
        requires_database_snapshot: source.database(),
    }
}
struct Budget {
    entries: usize,
    bytes: u64,
    started: Instant,
}
struct Scan {
    source: BackupSource,
    entries: usize,
    files: usize,
    bytes: u64,
    omitted: usize,
    primary: bool,
    issues: BTreeSet<InventoryIssue>,
    witnesses: Vec<Witness>,
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
fn scan_source(
    root: &File,
    source: BackupSource,
    budget: &mut Budget,
) -> (BackupSourceInventory, Vec<Witness>) {
    scan_source_checked(root, source, budget, || {})
}
fn scan_source_checked(
    root: &File,
    source: BackupSource,
    budget: &mut Budget,
    after_read: impl FnOnce(),
) -> (BackupSourceInventory, Vec<Witness>) {
    let directory = Path::new(source.location().0);
    let mut scan = Scan {
        source,
        entries: 0,
        files: 0,
        bytes: 0,
        omitted: 0,
        primary: false,
        issues: BTreeSet::new(),
        witnesses: Vec::new(),
    };
    match walk(root, directory, true) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return (
                BackupSourceInventory {
                    source,
                    status: InventoryStatus::NotFound,
                    file_count: Some(0),
                    byte_count: Some(0),
                    omitted_entries: Some(0),
                    issues: vec![],
                    requires_database_snapshot: source.database(),
                },
                vec![],
            )
        }
        Err(_) => return (unavailable(source, InventoryIssue::UnsafeEntry), vec![]),
        Ok(folder) => {
            if let Err(issue) = scan.folder(root, &folder, directory, false, budget) {
                return (unavailable(source, issue), vec![]);
            }
        }
    }
    after_read();
    // Check descriptor identities/metadata again, never file contents or schema.
    for witness in &scan.witnesses {
        if budget.started.elapsed() >= SCAN_TIME {
            scan.issues.insert(InventoryIssue::TimeLimit);
            break;
        }
        let actual = walk(root, &witness.path, witness.directory).and_then(|f| f.metadata());
        if !actual.is_ok_and(|m| stamp(&m) == witness.stamp) {
            return (
                unavailable(source, InventoryIssue::ChangedDuringRead),
                vec![],
            );
        }
    }
    if !scan.primary && scan.files > 0 {
        scan.issues.insert(InventoryIssue::PrimaryMissing);
    }
    let status = if !scan.issues.is_empty() {
        InventoryStatus::Limited
    } else if scan.files == 0 {
        InventoryStatus::NotFound
    } else {
        InventoryStatus::MetadataOnly
    };
    let row = BackupSourceInventory {
        source,
        status,
        file_count: Some(scan.files),
        byte_count: Some(scan.bytes),
        omitted_entries: Some(scan.omitted),
        issues: scan.issues.into_iter().collect(),
        requires_database_snapshot: source.database(),
    };
    (row, scan.witnesses)
}
impl Scan {
    fn folder(
        &mut self,
        root: &File,
        folder: &File,
        path: &Path,
        payload: bool,
        budget: &mut Budget,
    ) -> Result<(), InventoryIssue> {
        let m = folder.metadata().map_err(|_| InventoryIssue::ReadFailed)?;
        if !m.is_dir() || !owned(&m, true) {
            return Err(InventoryIssue::UnsafeEntry);
        }
        self.witnesses.push(Witness {
            path: path.into(),
            stamp: stamp(&m),
            directory: true,
        });
        let entries = fs::read_dir(anchor(folder)).map_err(|_| InventoryIssue::ReadFailed)?;
        for entry in entries {
            if budget.started.elapsed() >= SCAN_TIME {
                self.issues.insert(InventoryIssue::TimeLimit);
                self.omitted += 1;
                break;
            }
            if self.entries >= MAX_ENTRIES || budget.entries >= MAX_GLOBAL_ENTRIES {
                self.issues.insert(InventoryIssue::EntryLimit);
                self.omitted += 1;
                break;
            }
            self.entries += 1;
            budget.entries += 1;
            let entry = entry.map_err(|_| InventoryIssue::ReadFailed)?;
            let name = entry.file_name();
            let text = name.to_str();
            let relative = path.join(&name);
            if !payload
                && self.source == BackupSource::Knowledge
                && matches!(text, Some("blobs" | "archives"))
            {
                let child = walk(root, &relative, true).map_err(|_| InventoryIssue::UnsafeEntry)?;
                self.folder(root, &child, &relative, true, budget)?;
                continue;
            }
            let primary = self.source.location().1;
            let known = if payload {
                text.is_some_and(|s| {
                    s.len() == 64
                        && s.bytes()
                            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                })
            } else {
                text == Some(primary)
                    || self.source.database()
                        && text.is_some_and(|s| {
                            [
                                format!("{primary}-wal"),
                                format!("{primary}-shm"),
                                format!("{primary}-journal"),
                            ]
                            .iter()
                            .any(|v| v == s)
                        })
            };
            if !known {
                self.omitted += 1;
                self.issues.insert(InventoryIssue::UnknownEntries);
                continue;
            }
            let handle = walk(root, &relative, false).map_err(|_| InventoryIssue::UnsafeEntry)?;
            let m = handle.metadata().map_err(|_| InventoryIssue::ReadFailed)?;
            let s = stamp(&m);
            // SQLite creates WAL/SHM before the store tightens the database mode.
            // Exact sidecar names may retain read bits inside the verified private
            // directory; never accept other-user write or execute permissions.
            let private_file = owned(&m, true)
                || !payload
                    && self.source.database()
                    && text != Some(primary)
                    && owned(&m, false)
                    && s.mode & 0o111 == 0;
            if !m.is_file() || !private_file || s.links != 1 {
                return Err(InventoryIssue::UnsafeEntry);
            }
            self.witnesses.push(Witness {
                path: relative,
                stamp: s,
                directory: false,
            });
            if m.len() > MAX_FILE_BYTES || budget.bytes.saturating_add(m.len()) > MAX_BYTES {
                self.omitted += 1;
                self.issues.insert(InventoryIssue::ByteLimit);
                continue;
            }
            if !payload && text == Some(primary) {
                self.primary = true;
            }
            self.files += 1;
            self.bytes += m.len();
            budget.bytes += m.len();
        }
        Ok(())
    }
}
#[cfg(test)]
#[path = "workspace_backup_tests.rs"]
mod tests;
