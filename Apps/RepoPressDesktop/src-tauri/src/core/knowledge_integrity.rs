//! Bounded read-only manifest reference inspection. No initialization, GC or filesystem writes.
use super::{
    knowledge_library::knowledge_integrity_manifest::{self, IntegrityReference},
    workspace_backup, CommandError, CommandResult,
};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    fs::{File, Metadata, OpenOptions},
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    sync::Mutex,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;
const MAX_MANIFEST: u64 = 2 * 1024 * 1024;
const MAX_FILES: usize = 1024;
const MAX_BYTES: u64 = 64 * 1024 * 1024;
const TIME: Duration = Duration::from_secs(5);
const TTL: Duration = Duration::from_secs(300);
const EXCLUSIONS: [&str; 6] = [
    "credentials",
    "otherWorkspaceSources",
    "repositoryFiles",
    "externalReferences",
    "unreferencedFiles",
    "runtimeState",
];
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IntegrityLimits {
    manifest_bytes: u64,
    resource_files: usize,
    resource_bytes: u64,
    duration_ms: u64,
}
#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IntegrityResourceSummary {
    kind: &'static str,
    reference_count: u64,
    unique_files: u64,
    verified: u64,
    missing: u64,
    unsafe_: u64,
    unreadable: u64,
    invalid: u64,
    changed: u64,
    omitted: u64,
    verified_bytes: u64,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeIntegrityReport {
    pub report_id: String,
    schema_version: u8,
    scope: &'static str,
    checked_at_epoch_ms: u64,
    expires_at_epoch_ms: u64,
    status: &'static str,
    manifest_state: &'static str,
    manifest_schema_version: Option<u64>,
    manifest_sha256: Option<String>,
    item_count: Option<u64>,
    revision_count: Option<u64>,
    resources: Vec<IntegrityResourceSummary>,
    archive_missing_resources: u64,
    archive_truncated: u64,
    archive_unknown_completeness: u64,
    issues: Vec<&'static str>,
    exclusions: Vec<&'static str>,
    limits: IntegrityLimits,
    all_referenced_files_verified: bool,
    consistent_snapshot: bool,
    backup_ready: bool,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeIntegrityRecheck {
    pub report: KnowledgeIntegrityReport,
    pub comparison: &'static str,
}
#[derive(Clone, Debug, Eq, PartialEq)]
struct Stamp {
    dev: u64,
    ino: u64,
    mode: u32,
    uid: u32,
    links: u64,
    len: u64,
    mtime: i64,
    mtime_ns: i64,
    ctime: i64,
    ctime_ns: i64,
}
fn stamp(m: Metadata) -> Stamp {
    Stamp {
        dev: m.dev(),
        ino: m.ino(),
        mode: m.mode(),
        uid: m.uid(),
        links: m.nlink(),
        len: m.len(),
        mtime: m.mtime(),
        mtime_ns: m.mtime_nsec(),
        ctime: m.ctime(),
        ctime_ns: m.ctime_nsec(),
    }
}
fn identity(s: &Stamp) -> (u64, u64, u32, u32) {
    (s.dev, s.ino, s.mode, s.uid)
}
fn private(s: &Stamp, dir: bool) -> bool {
    s.uid == unsafe { libc::geteuid() }
        && s.mode & 0o777 == if dir { 0o700 } else { 0o600 }
        && s.mode & libc::S_IFMT == if dir { libc::S_IFDIR } else { libc::S_IFREG }
        && (dir || s.links == 1)
}
#[derive(Clone, Debug, Eq, PartialEq)]
enum Observation {
    Found(Stamp),
    Missing,
    Failed,
}
fn observe(base: &File, name: &str) -> Observation {
    match workspace_backup::walk(base, Path::new(name), false).and_then(|f| f.metadata()) {
        Ok(m) => Observation::Found(stamp(m)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Observation::Missing,
        Err(_) => Observation::Failed,
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Outcome {
    Verified,
    Missing,
    Unsafe,
    Unreadable,
    Invalid,
    Changed,
    Omitted,
}
#[derive(Debug)]
struct ReadFailure {
    outcome: Outcome,
    issue: &'static str,
}
fn failure(outcome: Outcome, issue: &'static str) -> ReadFailure {
    ReadFailure { outcome, issue }
}
fn read(
    base: &File,
    name: &str,
    max: u64,
    budget: &mut u64,
    started: Instant,
) -> Result<(Vec<u8>, Stamp), ReadFailure> {
    let path = workspace_backup::walk(base, Path::new(name), false).map_err(|e| {
        if e.kind() == std::io::ErrorKind::NotFound {
            failure(Outcome::Missing, "missingFile")
        } else {
            failure(Outcome::Unreadable, "readFailed")
        }
    })?;
    let before = stamp(
        path.metadata()
            .map_err(|_| failure(Outcome::Unreadable, "readFailed"))?,
    );
    if !private(&before, false) {
        return Err(failure(Outcome::Unsafe, "unsafeFile"));
    }
    if before.len > max {
        return Err(failure(Outcome::Invalid, "invalidContent"));
    }
    if before.len > *budget {
        return Err(failure(Outcome::Omitted, "byteLimit"));
    }
    if started.elapsed() >= TIME {
        return Err(failure(Outcome::Omitted, "timeLimit"));
    }
    // Reopen the already validated regular inode, not its mutable pathname. O_PATH
    // ensures a FIFO/device/symlink is rejected before any content-open operation.
    use std::os::fd::AsRawFd;
    let mut f = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(format!("/proc/self/fd/{}", path.as_raw_fd()))
        .map_err(|_| failure(Outcome::Unreadable, "readFailed"))?;
    if stamp(
        f.metadata()
            .map_err(|_| failure(Outcome::Unreadable, "readFailed"))?,
    ) != before
    {
        return Err(failure(Outcome::Changed, "changedDuringRead"));
    }
    let mut bytes = Vec::with_capacity(before.len as usize);
    let mut chunk = [0u8; 64 * 1024];
    loop {
        if started.elapsed() >= TIME {
            return Err(failure(Outcome::Omitted, "timeLimit"));
        }
        if *budget == 0 {
            // The descriptor size check below cannot prove EOF if the file grew.
            if bytes.len() as u64 == before.len {
                break;
            }
            return Err(failure(Outcome::Omitted, "byteLimit"));
        }
        let remaining = before
            .len
            .saturating_add(1)
            .saturating_sub(bytes.len() as u64)
            .min(*budget)
            .min(chunk.len() as u64) as usize;
        if remaining == 0 {
            return Err(failure(Outcome::Changed, "changedDuringRead"));
        }
        let n = f
            .read(&mut chunk[..remaining])
            .map_err(|_| failure(Outcome::Unreadable, "readFailed"))?;
        if n == 0 {
            break;
        }
        *budget -= n as u64;
        bytes.extend_from_slice(&chunk[..n]);
        if bytes.len() as u64 > before.len {
            return Err(failure(Outcome::Changed, "changedDuringRead"));
        }
    }
    if bytes.len() as u64 != before.len
        || stamp(
            f.metadata()
                .map_err(|_| failure(Outcome::Unreadable, "readFailed"))?,
        ) != before
        || observe(base, name) != Observation::Found(before.clone())
    {
        return Err(failure(Outcome::Changed, "changedDuringRead"));
    }
    Ok((bytes, before))
}
fn issue(report: &mut KnowledgeIntegrityReport, value: &'static str) {
    if !report.issues.contains(&value) {
        report.issues.push(value);
    }
}
fn count(row: &mut IntegrityResourceSummary, outcome: Outcome, bytes: u64) {
    match outcome {
        Outcome::Verified => {
            row.verified += 1;
            row.verified_bytes += bytes
        }
        Outcome::Missing => row.missing += 1,
        Outcome::Unsafe => row.unsafe_ += 1,
        Outcome::Unreadable => row.unreadable += 1,
        Outcome::Invalid => row.invalid += 1,
        Outcome::Changed => row.changed += 1,
        Outcome::Omitted => row.omitted += 1,
    }
}
fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn invalid() -> CommandError {
    CommandError::new("knowledge_integrity_unavailable","The read-only knowledge inspection is unavailable or expired. Discard old reports and explicitly inspect again.")
}
struct Root {
    path: PathBuf,
    file: File,
    identity: (u64, u64, u32, u32),
}
impl Root {
    fn new(path: PathBuf) -> Option<Self> {
        let file = workspace_backup::root_handle(&path).ok()?;
        let id = identity(&stamp(file.metadata().ok()?));
        Some(Self {
            path,
            file,
            identity: id,
        })
    }
    fn verify(&self) -> bool {
        workspace_backup::root_handle(&self.path)
            .and_then(|f| f.metadata().map_err(|_| invalid()))
            .ok()
            .is_some_and(|m| identity(&stamp(m)) == self.identity)
    }
}
struct Stored {
    created: Instant,
    fingerprint: String,
    comparable: bool,
}
#[derive(Default)]
pub struct KnowledgeIntegrityStore {
    root: Option<Root>,
    reports: Mutex<HashMap<String, Stored>>,
}
impl KnowledgeIntegrityStore {
    pub fn new(root: PathBuf) -> Self {
        Self {
            root: Root::new(root),
            reports: Mutex::new(HashMap::new()),
        }
    }
    pub fn inspect(&self) -> CommandResult<KnowledgeIntegrityReport> {
        let mut reports = self.reports.lock().map_err(|_| invalid())?;
        reports.retain(|_, s| s.created.elapsed() < TTL);
        if reports.len() >= 2 {
            return Err(invalid());
        }
        self.capture(&mut reports).map(|r| r.0)
    }
    pub fn recheck(&self, id: &str) -> CommandResult<KnowledgeIntegrityRecheck> {
        let mut reports = self.reports.lock().map_err(|_| invalid())?;
        let old = reports.remove(id).ok_or_else(invalid)?;
        if old.created.elapsed() >= TTL {
            return Err(invalid());
        }
        let (report, fingerprint, comparable) = self.capture(&mut reports)?;
        let comparison = if !old.comparable || !comparable {
            "inconclusive"
        } else if old.fingerprint == fingerprint {
            "unchanged"
        } else {
            "changed"
        };
        Ok(KnowledgeIntegrityRecheck { report, comparison })
    }
    pub fn discard(&self, id: &str) -> CommandResult<()> {
        self.reports.lock().map_err(|_| invalid())?.remove(id);
        Ok(())
    }
    fn capture(
        &self,
        reports: &mut HashMap<String, Stored>,
    ) -> CommandResult<(KnowledgeIntegrityReport, String, bool)> {
        self.capture_with_hook(reports, |_| {})
    }
    fn capture_with_hook(
        &self,
        reports: &mut HashMap<String, Stored>,
        mut hook: impl FnMut(u8),
    ) -> CommandResult<(KnowledgeIntegrityReport, String, bool)> {
        let started = Instant::now();
        let created = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| invalid())?
            .as_millis();
        if created == 0 || created > 8_639_999_999_700_000 {
            return Err(invalid());
        }
        let mut r = KnowledgeIntegrityReport {
            report_id: Uuid::new_v4().to_string(),
            schema_version: 1,
            scope: "applicationKnowledgeReferences",
            checked_at_epoch_ms: created as u64,
            expires_at_epoch_ms: created as u64 + 300_000,
            status: "unavailable",
            manifest_state: "unreadable",
            manifest_schema_version: None,
            manifest_sha256: None,
            item_count: None,
            revision_count: None,
            resources: Vec::new(),
            archive_missing_resources: 0,
            archive_truncated: 0,
            archive_unknown_completeness: 0,
            issues: Vec::new(),
            exclusions: EXCLUSIONS.to_vec(),
            limits: IntegrityLimits {
                manifest_bytes: MAX_MANIFEST,
                resource_files: MAX_FILES,
                resource_bytes: MAX_BYTES,
                duration_ms: 5000,
            },
            all_referenced_files_verified: false,
            consistent_snapshot: false,
            backup_ready: false,
        };
        let fingerprint = self.scan(&mut r, &mut hook);
        let comparable = r.status == "checked";
        reports.insert(
            r.report_id.clone(),
            Stored {
                created: started,
                fingerprint: fingerprint.clone(),
                comparable,
            },
        );
        Ok((r, fingerprint, comparable))
    }
    fn scan(&self, r: &mut KnowledgeIntegrityReport, hook: &mut impl FnMut(u8)) -> String {
        let started = Instant::now();
        let Some(root) = self.root.as_ref().filter(|r| r.verify()) else {
            issue(r, "manifestUnreadable");
            return String::new();
        };
        let directory = match workspace_backup::walk(&root.file, Path::new("knowledge-v1"), true) {
            Ok(f) => f,
            Err(e) => {
                if e.kind() == std::io::ErrorKind::NotFound {
                    r.manifest_state = "missing";
                    issue(r, "manifestMissing");
                } else {
                    issue(r, "unsafeDirectory");
                }
                return String::new();
            }
        };
        let directory_before = match directory.metadata() {
            Ok(m) => stamp(m),
            Err(_) => {
                issue(r, "manifestUnreadable");
                return String::new();
            }
        };
        if !private(&directory_before, true) {
            r.manifest_state = "unsafe";
            issue(r, "unsafeDirectory");
            return String::new();
        }
        let mut manifest_budget = MAX_MANIFEST + 1;
        let manifest = match read(
            &directory,
            "manifest.json",
            MAX_MANIFEST,
            &mut manifest_budget,
            started,
        ) {
            Ok((bytes, s)) => (bytes, s),
            Err(e) => {
                r.manifest_state = match e.outcome {
                    Outcome::Missing => "missing",
                    Outcome::Unsafe => "unsafe",
                    Outcome::Invalid => "tooLarge",
                    Outcome::Changed => "changed",
                    _ => "unreadable",
                };
                issue(
                    r,
                    match r.manifest_state {
                        "missing" => "manifestMissing",
                        "unsafe" => "manifestUnsafe",
                        "tooLarge" => "manifestTooLarge",
                        "changed" => "changedDuringRead",
                        _ => "manifestUnreadable",
                    },
                );
                return String::new();
            }
        };
        r.manifest_sha256 = Some(hash(&manifest.0));
        let raw = serde_json::from_slice::<serde_json::Value>(&manifest.0).ok();
        let source_version = raw
            .as_ref()
            .and_then(|v| v.get("schemaVersion"))
            .and_then(|v| v.as_u64());
        r.manifest_schema_version = source_version.filter(|v| *v <= u32::MAX as u64);
        if source_version.is_some_and(|v| v != 4) {
            r.manifest_state = "unsupported";
            issue(r, "unsupportedVersion");
            return String::new();
        }
        let mut references = match knowledge_integrity_manifest::project(&manifest.0) {
            Ok(x) => x,
            Err(_) => {
                r.manifest_state = "invalid";
                issue(r, "manifestInvalid");
                return String::new();
            }
        };
        r.manifest_state = "verified";
        r.item_count = Some(references.items);
        r.revision_count = Some(references.revisions);
        r.archive_missing_resources = references.missing_archives;
        r.archive_truncated = references.truncated_archives;
        r.archive_unknown_completeness = references.unknown_archives;
        if references.missing_archives > 0 || references.truncated_archives > 0 {
            issue(r, "incompleteArchive");
        }
        if references.unknown_archives > 0 {
            issue(r, "unknownArchiveCompleteness");
        }
        references
            .files
            .sort_by_key(|f| (if f.kind == "body" { 0 } else { 1 }, f.digest.clone()));
        r.resources = vec![
            IntegrityResourceSummary {
                kind: "body",
                reference_count: references.revisions,
                unique_files: references.files.iter().filter(|f| f.kind == "body").count() as u64,
                ..Default::default()
            },
            IntegrityResourceSummary {
                kind: "archive",
                reference_count: references.archive_references,
                unique_files: references
                    .files
                    .iter()
                    .filter(|f| f.kind == "archive")
                    .count() as u64,
                ..Default::default()
            },
        ];
        hook(0);
        let mut directories: Vec<Option<(File, Stamp)>> = Vec::new();
        for name in ["blobs", "archives"] {
            let d = workspace_backup::walk(&directory, Path::new(name), true)
                .ok()
                .and_then(|f| f.metadata().ok().map(|m| (f, stamp(m))))
                .filter(|(_, s)| private(s, true));
            if d.is_none() {
                issue(r, "unsafeDirectory");
            }
            directories.push(d);
        }
        let mut budget = MAX_BYTES;
        let mut attempts = 0;
        let mut checks: Vec<(usize, IntegrityReference, Observation, Outcome)> = Vec::new();
        for reference in references.files {
            let idx = usize::from(reference.kind == "archive");
            let Some((dir, _)) = &directories[idx] else {
                count(&mut r.resources[idx], Outcome::Unsafe, 0);
                issue(r, "unsafeFile");
                continue;
            };
            let bound = if started.elapsed() >= TIME {
                Some("timeLimit")
            } else if attempts >= MAX_FILES {
                Some("fileLimit")
            } else if reference.byte_size > budget {
                Some("byteLimit")
            } else {
                None
            };
            if let Some(b) = bound {
                count(&mut r.resources[idx], Outcome::Omitted, 0);
                issue(r, b);
                continue;
            }
            attempts += 1;
            let observation = observe(dir, &reference.digest);
            let outcome = match read(
                dir,
                &reference.digest,
                if idx == 0 {
                    5 * 1024 * 1024
                } else {
                    24 * 1024 * 1024
                },
                &mut budget,
                started,
            ) {
                Ok((bytes, _)) => {
                    if knowledge_integrity_manifest::content_matches(&reference, &bytes) {
                        Outcome::Verified
                    } else {
                        issue(r, "invalidContent");
                        Outcome::Invalid
                    }
                }
                Err(e) => {
                    issue(r, e.issue);
                    e.outcome
                }
            };
            count(&mut r.resources[idx], outcome, reference.byte_size);
            checks.push((idx, reference, observation, outcome));
        }
        hook(1);
        let mut digest = Sha256::new();
        digest.update(&manifest.0);
        // Check every attempted name again after all reads, including missing/unsafe files.
        for (idx, reference, before, outcome) in checks {
            if started.elapsed() >= TIME {
                issue(r, "timeLimit");
                break;
            }
            let current = observe(
                &directories[idx].as_ref().expect("attempted directory").0,
                &reference.digest,
            );
            if current != before && outcome != Outcome::Changed {
                let row = &mut r.resources[idx];
                match outcome {
                    Outcome::Verified => {
                        row.verified -= 1;
                        row.verified_bytes -= reference.byte_size
                    }
                    Outcome::Missing => row.missing -= 1,
                    Outcome::Unsafe => row.unsafe_ -= 1,
                    Outcome::Unreadable => row.unreadable -= 1,
                    Outcome::Invalid => row.invalid -= 1,
                    Outcome::Omitted => row.omitted -= 1,
                    Outcome::Changed => {}
                }
                row.changed += 1;
                issue(r, "changedDuringRead");
            }
            digest.update(reference.kind);
            digest.update(reference.digest);
            digest.update(format!("{before:?}"));
        }
        hook(2);
        let mut changed = !root.verify()
            || observe(&directory, "manifest.json") != Observation::Found(manifest.1)
            || workspace_backup::walk(&root.file, Path::new("knowledge-v1"), true)
                .ok()
                .and_then(|f| f.metadata().ok())
                .map(stamp)
                != Some(directory_before.clone());
        digest.update(format!("{directory_before:?}"));
        for (idx, name) in ["blobs", "archives"].iter().enumerate() {
            if let Some((_, before)) = &directories[idx] {
                changed |= workspace_backup::walk(&directory, Path::new(name), true)
                    .ok()
                    .and_then(|f| f.metadata().ok())
                    .map(stamp)
                    != Some(before.clone());
                digest.update(format!("{before:?}"));
            }
        }
        if changed {
            issue(r, "changedDuringRead");
        }
        r.all_referenced_files_verified = r
            .resources
            .iter()
            .all(|row| row.verified == row.unique_files)
            && !r.issues.contains(&"changedDuringRead")
            && !r.issues.contains(&"unsafeDirectory")
            && !r.issues.contains(&"timeLimit");
        r.status = if r.all_referenced_files_verified && r.issues.is_empty() {
            "checked"
        } else {
            "partial"
        };
        format!("{:x}", digest.finalize())
    }
}
#[cfg(test)]
#[path = "knowledge_integrity_tests.rs"]
mod tests;
