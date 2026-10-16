//! Bounded local single-commit inverse metadata. No transport, text export or writes.
use super::git_publish::read_local_rollback_object;
use super::rollback_qualification::{local_conditions, QualificationIdentity, RollbackBlocker};
use super::{CommandError, CommandResult, PublishLedgerStore, PublishRecord};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::path::Path;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const MAX_ROWS: usize = 200;
const MAX_TREES: usize = 512;
const MAX_DEPTH: usize = 32;
const MAX_OBJECT_BYTES: usize = 64 * 1024;
const MAX_TOTAL_BYTES: usize = 4 * 1024 * 1024;
const INSPECTION_TIME: Duration = Duration::from_secs(20);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum PreviewStatus {
    Complete,
    Partial,
    Blocked,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum PreviewWarning {
    EntryLimit,
    TreeLimit,
    TimeLimit,
    ByteLimit,
    UnsafePathsOmitted,
    ObjectsUnavailable,
    UnsupportedTypes,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum FileIssue {
    UnsupportedType,
    ObjectMissing,
    ObjectTooLarge,
    ObjectHashMismatch,
    BudgetLimit,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum InverseAction {
    Delete,
    Restore,
    Replace,
    Unsupported,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ObjectVerification {
    Verified,
    Unavailable,
    Unsupported,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ObjectSide {
    pub mode: String,
    pub object_id: String,
    pub byte_size: Option<usize>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileChange {
    pub path: String,
    pub action: InverseAction,
    pub published: Option<ObjectSide>,
    pub restore: Option<ObjectSide>,
    pub verification: ObjectVerification,
    pub issues: Vec<FileIssue>,
}
#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PreviewSummary {
    pub visible: usize,
    pub delete_files: usize,
    pub restore_files: usize,
    pub replace_files: usize,
    pub unsupported_files: usize,
    pub verified_files: usize,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RollbackChangePreview {
    #[serde(flatten)]
    pub identity: QualificationIdentity,
    pub status: PreviewStatus,
    pub changes: Vec<FileChange>,
    pub omitted_paths: Option<usize>,
    pub blockers: Vec<RollbackBlocker>,
    pub warnings: Vec<PreviewWarning>,
    pub summary: PreviewSummary,
    pub checked_at_epoch_ms: u64,
}
#[derive(Clone, Debug, PartialEq, Eq)]
struct TreeEntry {
    mode: String,
    oid: String,
}
type Tree = BTreeMap<Vec<u8>, TreeEntry>;
struct CachedObject {
    kind: &'static str,
    bytes: Vec<u8>,
}
struct Inspection<'a> {
    root: &'a Path,
    sha_width: usize,
    cache: HashMap<String, CachedObject>,
    trees: usize,
    bytes: usize,
    deadline: Instant,
    rows: Vec<FileChange>,
    omitted: Option<usize>,
    warnings: Vec<PreviewWarning>,
}
pub(super) fn digest_matches(kind: &str, bytes: &[u8], oid: &str) -> bool {
    let header = format!("{kind} {}\0", bytes.len());
    let result = if oid.len() == 40 {
        let mut hash = ring::digest::Context::new(&ring::digest::SHA1_FOR_LEGACY_USE_ONLY);
        hash.update(header.as_bytes());
        hash.update(bytes);
        hash.finish()
            .as_ref()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>()
    } else {
        let mut hash = Sha256::new();
        hash.update(header.as_bytes());
        hash.update(bytes);
        format!("{:x}", hash.finalize())
    };
    result == oid
}
fn safe_component(bytes: &[u8]) -> Option<&str> {
    let name = std::str::from_utf8(bytes).ok()?;
    if name.is_empty()
        || name == "."
        || name == ".."
        || name.eq_ignore_ascii_case(".git")
        || name.ends_with(['.', ' '])
        || name.contains(['/', '\\', ':', '<', '>', '"', '|', '?', '*'])
        || name.chars().any(char::is_control)
    {
        return None;
    }
    let stem = name.split('.').next()?.to_ascii_uppercase();
    if matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || ((stem.starts_with("COM") || stem.starts_with("LPT"))
            && stem.len() == 4
            && matches!(stem.as_bytes()[3], b'1'..=b'9'))
    {
        return None;
    }
    Some(name)
}
fn valid_oid(value: &str, width: usize) -> bool {
    value.len() == width * 2 && super::publish_ledger::valid_sha(value)
}
fn parse_tree(bytes: &[u8], width: usize) -> Result<Tree, FileIssue> {
    let mut tree = Tree::new();
    let mut pos = 0;
    while pos < bytes.len() {
        let space = bytes[pos..]
            .iter()
            .position(|b| *b == b' ')
            .ok_or(FileIssue::ObjectMissing)?
            + pos;
        let mode = match &bytes[pos..space] {
            b"40000" => "040000",
            b"100644" => "100644",
            b"100755" => "100755",
            b"120000" => "120000",
            b"160000" => "160000",
            _ => return Err(FileIssue::UnsupportedType),
        };
        let start = space + 1;
        let nul = bytes[start..]
            .iter()
            .position(|b| *b == 0)
            .ok_or(FileIssue::ObjectMissing)?
            + start;
        let end = nul + 1 + width;
        if nul == start || end > bytes.len() {
            return Err(FileIssue::ObjectMissing);
        }
        let oid = bytes[nul + 1..end]
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        if tree
            .insert(
                bytes[start..nul].to_vec(),
                TreeEntry {
                    mode: mode.into(),
                    oid,
                },
            )
            .is_some()
        {
            return Err(FileIssue::ObjectMissing);
        }
        pos = end;
    }
    Ok(tree)
}
pub(super) fn commit_tree(bytes: &[u8], width: usize) -> Result<(String, Vec<String>), FileIssue> {
    let header = bytes
        .split(|b| *b == b'\n')
        .take_while(|line| !line.is_empty());
    let mut tree = None;
    let mut parents = Vec::new();
    for line in header {
        if let Some(value) = line.strip_prefix(b"tree ") {
            let value = std::str::from_utf8(value).map_err(|_| FileIssue::ObjectMissing)?;
            if !valid_oid(value, width) || tree.replace(value.to_string()).is_some() {
                return Err(FileIssue::ObjectMissing);
            }
        } else if let Some(value) = line.strip_prefix(b"parent ") {
            let value = std::str::from_utf8(value).map_err(|_| FileIssue::ObjectMissing)?;
            if !valid_oid(value, width) {
                return Err(FileIssue::ObjectMissing);
            }
            parents.push(value.into());
        }
    }
    Ok((tree.ok_or(FileIssue::ObjectMissing)?, parents))
}
impl Inspection<'_> {
    fn commit_pair(&mut self, source: &str, parent: &str) -> Result<(String, String), FileIssue> {
        let (a, parents) = commit_tree(&self.object("commit", source)?, self.sha_width)?;
        if parents != vec![parent.to_string()] {
            return Err(FileIssue::ObjectMissing);
        }
        let (b, _) = commit_tree(&self.object("commit", parent)?, self.sha_width)?;
        self.tree(&a)?;
        self.tree(&b)?;
        Ok((a, b))
    }
    fn warn(&mut self, value: PreviewWarning) {
        if !self.warnings.contains(&value) {
            self.warnings.push(value);
        }
    }
    fn unknown_omission(&mut self, warning: PreviewWarning) {
        self.omitted = None;
        self.warn(warning);
    }
    fn object(&mut self, kind: &'static str, oid: &str) -> Result<Vec<u8>, FileIssue> {
        if let Some(value) = self.cache.get(oid) {
            return if value.kind == kind {
                Ok(value.bytes.clone())
            } else {
                Err(FileIssue::ObjectMissing)
            };
        }
        let remaining = match self.deadline.checked_duration_since(Instant::now()) {
            Some(v) if !v.is_zero() => v,
            _ => {
                self.warn(PreviewWarning::TimeLimit);
                return Err(FileIssue::BudgetLimit);
            }
        };
        if kind == "tree" && self.trees >= MAX_TREES {
            self.warn(PreviewWarning::TreeLimit);
            return Err(FileIssue::BudgetLimit);
        }
        let cap = MAX_OBJECT_BYTES.min(MAX_TOTAL_BYTES.saturating_sub(self.bytes));
        let bytes =
            read_local_rollback_object(self.root, kind, oid, cap, remaining).map_err(|error| {
                match error.code.as_str() {
                    "rollback_object_too_large" if cap < MAX_OBJECT_BYTES => {
                        self.warn(PreviewWarning::ByteLimit);
                        FileIssue::BudgetLimit
                    }
                    "rollback_object_too_large" => FileIssue::ObjectTooLarge,
                    "git_timeout" => {
                        self.warn(PreviewWarning::TimeLimit);
                        FileIssue::BudgetLimit
                    }
                    _ => FileIssue::ObjectMissing,
                }
            })?;
        self.bytes += bytes.len();
        if !digest_matches(kind, &bytes, oid) {
            return Err(FileIssue::ObjectHashMismatch);
        }
        if kind == "tree" {
            self.trees += 1;
        }
        self.cache.insert(
            oid.into(),
            CachedObject {
                kind,
                bytes: bytes.clone(),
            },
        );
        Ok(bytes)
    }
    fn tree(&mut self, oid: &str) -> Result<Tree, FileIssue> {
        parse_tree(&self.object("tree", oid)?, self.sha_width)
    }
    fn row(&mut self, path: String, published: Option<TreeEntry>, restore: Option<TreeEntry>) {
        let regular = |side: &TreeEntry| matches!(side.mode.as_str(), "100644" | "100755");
        let unsupported = published.as_ref().is_some_and(|s| !regular(s))
            || restore.as_ref().is_some_and(|s| !regular(s));
        let mut issues = vec![];
        let mut side = |entry: Option<TreeEntry>| {
            entry.map(|e| {
                let byte_size = if !unsupported {
                    match self.object("blob", &e.oid) {
                        Ok(bytes) => Some(bytes.len()),
                        Err(issue) => {
                            if !issues.contains(&issue) {
                                issues.push(issue);
                            }
                            None
                        }
                    }
                } else {
                    None
                };
                ObjectSide {
                    mode: e.mode,
                    object_id: e.oid,
                    byte_size,
                }
            })
        };
        let published = side(published);
        let restore = side(restore);
        let action = if unsupported {
            InverseAction::Unsupported
        } else if restore.is_none() {
            InverseAction::Delete
        } else if published.is_none() {
            InverseAction::Restore
        } else {
            InverseAction::Replace
        };
        let verification = if unsupported {
            issues.push(FileIssue::UnsupportedType);
            self.warn(PreviewWarning::UnsupportedTypes);
            ObjectVerification::Unsupported
        } else if !issues.is_empty() {
            self.warn(PreviewWarning::ObjectsUnavailable);
            ObjectVerification::Unavailable
        } else {
            ObjectVerification::Verified
        };
        self.rows.push(FileChange {
            path,
            action,
            published,
            restore,
            verification,
            issues,
        });
    }
    fn walk(&mut self, path: &str, published: Option<&str>, restore: Option<&str>, depth: usize) {
        if depth > MAX_DEPTH {
            self.unknown_omission(PreviewWarning::TreeLimit);
            return;
        }
        let a = match published {
            Some(oid) => match self.tree(oid) {
                Ok(t) => t,
                Err(_) => {
                    self.unknown_omission(PreviewWarning::ObjectsUnavailable);
                    return;
                }
            },
            None => Tree::new(),
        };
        let b = match restore {
            Some(oid) => match self.tree(oid) {
                Ok(t) => t,
                Err(_) => {
                    self.unknown_omission(PreviewWarning::ObjectsUnavailable);
                    return;
                }
            },
            None => Tree::new(),
        };
        let mut pairs: BTreeMap<Vec<u8>, (Option<TreeEntry>, Option<TreeEntry>)> = BTreeMap::new();
        for (name, e) in a {
            pairs.entry(name).or_default().0 = Some(e);
        }
        for (name, e) in b {
            pairs.entry(name).or_default().1 = Some(e);
        }
        for (name, (a, b)) in pairs {
            if a == b {
                continue;
            }
            if self.rows.len() >= MAX_ROWS {
                self.unknown_omission(PreviewWarning::EntryLimit);
                return;
            }
            if Instant::now() >= self.deadline {
                self.unknown_omission(PreviewWarning::TimeLimit);
                return;
            }
            let component = match safe_component(&name) {
                Some(v) => v,
                None => {
                    if a.as_ref().is_some_and(|e| e.mode == "040000")
                        || b.as_ref().is_some_and(|e| e.mode == "040000")
                    {
                        self.omitted = None;
                    } else if let Some(count) = &mut self.omitted {
                        *count += 1;
                    }
                    self.warn(PreviewWarning::UnsafePathsOmitted);
                    continue;
                }
            };
            let child = if path.is_empty() {
                component.into()
            } else {
                format!("{path}/{component}")
            };
            if child.len() > 4096 {
                self.omitted = None;
                self.warn(PreviewWarning::UnsafePathsOmitted);
                continue;
            }
            let a_tree = a.as_ref().is_some_and(|e| e.mode == "040000");
            let b_tree = b.as_ref().is_some_and(|e| e.mode == "040000");
            if (a_tree && (b_tree || b.is_none())) || (b_tree && a.is_none()) {
                self.walk(
                    &child,
                    a.as_ref().map(|e| e.oid.as_str()),
                    b.as_ref().map(|e| e.oid.as_str()),
                    depth + 1,
                );
            } else {
                self.row(child, a, b);
            }
        }
    }
}
fn stale() -> CommandError {
    CommandError::new(
        "rollback_preview_changed",
        "Recorded target or evidence changed; inspect again.",
    )
}
fn now_ms() -> CommandResult<u64> {
    let value = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| stale())?
        .as_millis();
    if value == 0 || value > 9_007_199_254_740_991 {
        return Err(stale());
    }
    Ok(value as u64)
}
fn preview_record(
    session: &str,
    root: &Path,
    record: &PublishRecord,
    conditions: (Option<String>, Vec<RollbackBlocker>),
) -> CommandResult<RollbackChangePreview> {
    let (parent, blockers) = conditions;
    let mut view = RollbackChangePreview {
        identity: QualificationIdentity {
            session_id: session.into(),
            record_id: record.record_id.clone(),
            revision: record.revision,
            branch: record.evidence.branch.clone(),
            remote_url: record.evidence.remote_url.clone(),
            expected_sha: record.evidence.expected_sha.clone(),
            parent_sha: parent.clone(),
        },
        status: PreviewStatus::Blocked,
        changes: vec![],
        omitted_paths: None,
        blockers,
        warnings: vec![],
        summary: PreviewSummary::default(),
        checked_at_epoch_ms: now_ms()?,
    };
    let Some(parent) = parent.filter(|_| view.blockers.is_empty()) else {
        return Ok(view);
    };
    let mut inspection = Inspection {
        root,
        sha_width: record.evidence.expected_sha.len() / 2,
        cache: HashMap::new(),
        trees: 0,
        bytes: 0,
        deadline: Instant::now() + INSPECTION_TIME,
        rows: vec![],
        omitted: Some(0),
        warnings: vec![],
    };
    let roots = inspection.commit_pair(&record.evidence.expected_sha, &parent);
    let (a, b) = match roots {
        Ok(v) => v,
        Err(_) => {
            view.blockers.push(RollbackBlocker::ObjectsUnavailable);
            return Ok(view);
        }
    };
    if a != b {
        inspection.walk("", Some(&a), Some(&b), 0);
    }
    inspection.rows.sort_by(|a, b| a.path.cmp(&b.path));
    view.status = if inspection.warnings.is_empty() {
        PreviewStatus::Complete
    } else {
        PreviewStatus::Partial
    };
    view.omitted_paths = inspection.omitted;
    view.warnings = inspection.warnings;
    view.changes = inspection.rows;
    for row in &view.changes {
        view.summary.visible += 1;
        match row.action {
            InverseAction::Delete => view.summary.delete_files += 1,
            InverseAction::Restore => view.summary.restore_files += 1,
            InverseAction::Replace => view.summary.replace_files += 1,
            InverseAction::Unsupported => view.summary.unsupported_files += 1,
        }
        if row.verification == ObjectVerification::Verified {
            view.summary.verified_files += 1;
        }
    }
    view.checked_at_epoch_ms = now_ms()?;
    Ok(view)
}
pub fn inspect_rollback_changes(
    session: &str,
    root: &Path,
    ledger: &PublishLedgerStore,
    id: &str,
    revision: u64,
) -> CommandResult<RollbackChangePreview> {
    let record = ledger.get(root, id)?;
    if record.revision != revision {
        return Err(stale());
    }
    let before = local_conditions(root, &record);
    let view = preview_record(session, root, &record, before.clone())?;
    validate_final_preview(root, ledger, &record, &before)?;
    Ok(view)
}

pub(super) fn validate_final_preview(
    root: &Path,
    ledger: &PublishLedgerStore,
    record: &PublishRecord,
    before: &(Option<String>, Vec<RollbackBlocker>),
) -> CommandResult<()> {
    if ledger.get(root, &record.record_id)? != *record || local_conditions(root, record) != *before
    {
        return Err(stale());
    }
    Ok(())
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct SnapshotObject {
    pub oid: String,
    pub kind: &'static str,
    pub bytes: Vec<u8>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct CandidateSnapshot {
    pub source_tree: String,
    pub target_tree: String,
    pub changed_paths: usize,
    pub target_files: usize,
    pub objects: Vec<SnapshotObject>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SnapshotProblem {
    PreviewIncomplete,
    TargetSnapshotUnsupported,
    TargetSnapshotUnsafe,
    SnapshotLimit,
    ObjectsUnavailable,
    NoChanges,
}
fn snapshot_issue(issue: FileIssue) -> SnapshotProblem {
    match issue {
        FileIssue::UnsupportedType => SnapshotProblem::TargetSnapshotUnsupported,
        FileIssue::ObjectTooLarge | FileIssue::BudgetLimit => SnapshotProblem::SnapshotLimit,
        _ => SnapshotProblem::ObjectsUnavailable,
    }
}
impl Inspection<'_> {
    fn full_target(
        &mut self,
        oid: &str,
        prefix: &str,
        depth: usize,
        files: &mut usize,
    ) -> Result<(), SnapshotProblem> {
        if depth > MAX_DEPTH || Instant::now() >= self.deadline {
            return Err(SnapshotProblem::SnapshotLimit);
        }
        for (name, entry) in self.tree(oid).map_err(snapshot_issue)? {
            let component = safe_component(&name).ok_or(SnapshotProblem::TargetSnapshotUnsafe)?;
            let path = if prefix.is_empty() {
                component.into()
            } else {
                format!("{prefix}/{component}")
            };
            if path.len() > 4096 {
                return Err(SnapshotProblem::TargetSnapshotUnsafe);
            }
            match entry.mode.as_str() {
                "040000" => self.full_target(&entry.oid, &path, depth + 1, files)?,
                "100644" | "100755" => {
                    if *files >= MAX_ROWS {
                        return Err(SnapshotProblem::SnapshotLimit);
                    }
                    *files += 1;
                    self.object("blob", &entry.oid).map_err(snapshot_issue)?;
                }
                _ => return Err(SnapshotProblem::TargetSnapshotUnsupported),
            }
        }
        Ok(())
    }
}
/// Includes the full target tree closure, not the whole ancestry of either commit.
pub(super) fn candidate_snapshot(
    root: &Path,
    record: &PublishRecord,
    parent: &str,
) -> Result<CandidateSnapshot, SnapshotProblem> {
    let mut inspection = Inspection {
        root,
        sha_width: record.evidence.expected_sha.len() / 2,
        cache: HashMap::new(),
        trees: 0,
        bytes: 0,
        deadline: Instant::now() + INSPECTION_TIME,
        rows: vec![],
        omitted: Some(0),
        warnings: vec![],
    };
    let (source_tree, target_tree) = inspection
        .commit_pair(&record.evidence.expected_sha, parent)
        .map_err(snapshot_issue)?;
    if source_tree == target_tree {
        return Err(SnapshotProblem::NoChanges);
    }
    inspection.walk("", Some(&source_tree), Some(&target_tree), 0);
    if !inspection.warnings.is_empty() || inspection.omitted != Some(0) {
        return Err(SnapshotProblem::PreviewIncomplete);
    }
    if inspection.rows.is_empty() {
        return Err(SnapshotProblem::NoChanges);
    }
    let mut target_files = 0;
    inspection.full_target(&target_tree, "", 0, &mut target_files)?;
    let mut objects: Vec<_> = inspection
        .cache
        .into_iter()
        .map(|(oid, value)| SnapshotObject {
            oid,
            kind: value.kind,
            bytes: value.bytes,
        })
        .collect();
    objects.sort_by(|a, b| a.oid.cmp(&b.oid));
    Ok(CandidateSnapshot {
        source_tree,
        target_tree,
        changed_paths: inspection.rows.len(),
        target_files,
        objects,
    })
}

#[cfg(test)]
#[path = "rollback_change_preview_tests.rs"]
mod tests;
