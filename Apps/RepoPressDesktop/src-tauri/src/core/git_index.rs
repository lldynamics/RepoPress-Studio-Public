//! Reviewed, one-time Git index updates for the Linux desktop client.
//!
//! This deliberately exposes only raw-blob `hash-object` plus one atomic
//! `update-index --index-info -z`, and `git restore --staged -- <paths>`.
//! Stage never supplies a pathname to Git's content conversion machinery, so
//! repository clean/process filters cannot run. It never changes the working
//! tree, contacts a remote, or runs hooks. Every mutation is preceded by a
//! short-lived plan whose repository, index, selected status entries, and
//! selected working-tree snapshots are revalidated at execution time.

use super::{CommandError, CommandResult};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

const PLAN_LIFETIME: Duration = Duration::from_secs(5 * 60);
const GIT_TIMEOUT: Duration = Duration::from_secs(20);
const MAX_GIT_OUTPUT: usize = 128 * 1024;
const MAX_INDEX_SNAPSHOT_BYTES: usize = 8 * 1024 * 1024;
const MAX_PATHS: usize = 100;
const MAX_PATH_BYTES: usize = 4 * 1024;
const MAX_FILE_BYTES: u64 = 4 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum GitIndexAction {
    Stage,
    Unstage,
}

impl GitIndexAction {
    pub fn parse(value: &str) -> CommandResult<Self> {
        match value {
            "stage" => Ok(Self::Stage),
            "unstage" => Ok(Self::Unstage),
            _ => Err(CommandError::new(
                "git_index_action_invalid",
                "Git index action must be stage or unstage.",
            )),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitIndexPlan {
    pub plan_id: String,
    pub action: GitIndexAction,
    pub paths: Vec<String>,
    pub expires_at: String,
    pub summary: String,
    pub warnings: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitIndexUpdateResult {
    pub action: GitIndexAction,
    pub paths: Vec<String>,
    pub summary: String,
}

#[derive(Clone, Eq, PartialEq)]
struct IndexBaseline {
    head: String,
    index_digest: String,
    object_format: GitObjectFormat,
}

#[derive(Clone, Eq, PartialEq)]
enum WorktreeFingerprint {
    RegularFile {
        digest: String,
        byte_size: u64,
        mode: GitFileMode,
    },
    Missing,
}

#[derive(Clone)]
enum StagedInput {
    File {
        path: String,
        bytes: Vec<u8>,
        mode: GitFileMode,
    },
    Delete {
        path: String,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum GitFileMode {
    Regular,
    Executable,
}

impl GitFileMode {
    fn index_mode(self) -> &'static str {
        match self {
            Self::Regular => "100644",
            Self::Executable => "100755",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum GitObjectFormat {
    Sha1,
    Sha256,
}

impl GitObjectFormat {
    fn parse(value: &str) -> CommandResult<Self> {
        match value {
            "sha1" => Ok(Self::Sha1),
            "sha256" => Ok(Self::Sha256),
            _ => Err(CommandError::new(
                "git_index_object_format_invalid",
                "Repository object format is unsupported for a Git index update.",
            )),
        }
    }

    fn zero_oid(self) -> &'static str {
        match self {
            Self::Sha1 => "0000000000000000000000000000000000000000",
            Self::Sha256 => "0000000000000000000000000000000000000000000000000000000000000000",
        }
    }

    fn oid_length(self) -> usize {
        self.zero_oid().len()
    }
}

#[derive(Clone)]
struct PlannedPath {
    value: String,
    status: String,
    fingerprint: WorktreeFingerprint,
}

struct PlannedIndexUpdate {
    root: PathBuf,
    session_id: String,
    action: GitIndexAction,
    paths: Vec<PlannedPath>,
    baseline: IndexBaseline,
    expires_at: SystemTime,
}

#[derive(Default)]
pub struct GitIndexStore {
    plans: Mutex<HashMap<String, PlannedIndexUpdate>>,
}

impl GitIndexStore {
    pub fn plan(
        &self,
        session_id: &str,
        root: &Path,
        action: GitIndexAction,
        requested_paths: &[String],
    ) -> CommandResult<GitIndexPlan> {
        validate_session(session_id)?;
        let root = validate_root(root)?;
        let paths = prepare_paths(&root, action, requested_paths)?;
        let baseline = capture_baseline(&root)?;
        let plan_id = Uuid::new_v4().to_string();
        let expires_at = SystemTime::now() + PLAN_LIFETIME;
        let response_paths = paths
            .iter()
            .map(|path| path.value.clone())
            .collect::<Vec<_>>();
        let plan = GitIndexPlan {
            plan_id: plan_id.clone(),
            action,
            paths: response_paths,
            expires_at: rfc3339_from_system_time(expires_at)?,
            summary: summary_for(action, paths.len()),
            warnings: Vec::new(),
        };
        let mut plans = self.plans.lock().map_err(|_| plans_unavailable())?;
        plans.retain(|_, entry| entry.expires_at > SystemTime::now());
        plans.insert(
            plan_id,
            PlannedIndexUpdate {
                root,
                session_id: session_id.to_string(),
                action,
                paths,
                baseline,
                expires_at,
            },
        );
        Ok(plan)
    }

    /// Consumption is intentionally before every revalidation and before Git is
    /// started. A failed execution therefore cannot be retried with a stale plan.
    pub fn execute(&self, session_id: &str, plan_id: &str) -> CommandResult<GitIndexUpdateResult> {
        validate_session(session_id)?;
        validate_plan_id(plan_id)?;
        let plan = {
            let mut plans = self.plans.lock().map_err(|_| plans_unavailable())?;
            plans.remove(plan_id).ok_or_else(|| {
                CommandError::new(
                    "git_index_plan_not_found",
                    "The Git index plan is unavailable or has already been used.",
                )
            })?
        };
        if plan.expires_at <= SystemTime::now() {
            return Err(CommandError::new(
                "git_index_plan_expired",
                "The Git index plan expired; review a new plan.",
            ));
        }
        if plan.session_id != session_id {
            return Err(CommandError::new(
                "git_index_session_mismatch",
                "The Git index plan belongs to another repository session.",
            ));
        }
        let root = validate_root(&plan.root)?;
        if root != plan.root || capture_baseline(&root)? != plan.baseline {
            return Err(baseline_changed());
        }
        let staged_inputs = revalidate_paths(&root, plan.action, &plan.paths)?;
        let selected_count = plan.paths.len();
        let output = match (plan.action, staged_inputs) {
            (GitIndexAction::Stage, Some(inputs)) => {
                stage_verified_inputs(&root, &inputs, plan.baseline.object_format)?
            }
            (GitIndexAction::Unstage, None) => {
                let path_values = plan
                    .paths
                    .iter()
                    .map(|path| path.value.as_str())
                    .collect::<Vec<_>>();
                run_git(&root, "restore-staged", &path_values)?
            }
            _ => return Err(baseline_changed()),
        };
        ensure_success(&output, "git_index_update_failed")?;
        Ok(GitIndexUpdateResult {
            action: plan.action,
            paths: plan.paths.into_iter().map(|path| path.value).collect(),
            summary: result_summary(plan.action, selected_count),
        })
    }
}

fn prepare_paths(
    root: &Path,
    action: GitIndexAction,
    requested_paths: &[String],
) -> CommandResult<Vec<PlannedPath>> {
    if requested_paths.is_empty() || requested_paths.len() > MAX_PATHS {
        return Err(CommandError::new(
            "git_index_path_count_invalid",
            format!("Select between 1 and {MAX_PATHS} files for a Git index update."),
        ));
    }
    let mut values = BTreeMap::new();
    for value in requested_paths {
        validate_relative_path(value)?;
        if values.insert(value.clone(), ()).is_some() {
            return Err(CommandError::new(
                "git_index_duplicate_path",
                "A Git index plan cannot contain the same path more than once.",
            ));
        }
    }
    let statuses = status_by_path(root)?;
    requested_paths
        .iter()
        .map(|value| {
            let status = statuses.get(value).ok_or_else(|| {
                CommandError::new(
                    "git_index_path_not_changed",
                    "Every selected path must be a current Git change.",
                )
            })?;
            ensure_actionable_status(action, status)?;
            ensure_not_indexed_symlink(root, value)?;
            let fingerprint = capture_fingerprint(root, value)?;
            Ok(PlannedPath {
                value: value.clone(),
                status: status.clone(),
                fingerprint,
            })
        })
        .collect()
}

fn revalidate_paths(
    root: &Path,
    action: GitIndexAction,
    paths: &[PlannedPath],
) -> CommandResult<Option<Vec<StagedInput>>> {
    let statuses = status_by_path(root)?;
    let mut staged_inputs = Vec::new();
    for planned in paths {
        let status = statuses.get(&planned.value).ok_or_else(baseline_changed)?;
        if status != &planned.status {
            return Err(baseline_changed());
        }
        ensure_actionable_status(action, status).map_err(|_| baseline_changed())?;
        ensure_not_indexed_symlink(root, &planned.value).map_err(|_| baseline_changed())?;
        let snapshot = capture_path_snapshot(root, &planned.value)?;
        if snapshot.fingerprint() != planned.fingerprint {
            return Err(baseline_changed());
        }
        if action == GitIndexAction::Stage {
            staged_inputs.push(snapshot.into_staged_input(planned.value.clone())?);
        }
    }
    Ok((action == GitIndexAction::Stage).then_some(staged_inputs))
}

fn ensure_actionable_status(action: GitIndexAction, status: &str) -> CommandResult<()> {
    let bytes = status.as_bytes();
    if bytes.len() != 2 {
        return Err(CommandError::new(
            "git_index_status_invalid",
            "Git status is invalid.",
        ));
    }
    let index = bytes[0];
    let worktree = bytes[1];
    if matches!(index, b'R' | b'C') || matches!(worktree, b'R' | b'C') {
        return Err(CommandError::new(
            "git_index_rename_copy_unsupported",
            "Renamed and copied paths must be resolved outside this Git index flow.",
        ));
    }
    match action {
        GitIndexAction::Stage => {
            if status == "??" || !matches!(worktree, b' ' | b'?') {
                Ok(())
            } else {
                Err(CommandError::new(
                    "git_index_no_worktree_change",
                    "Selected paths must have an unstaged change to stage.",
                ))
            }
        }
        GitIndexAction::Unstage => {
            if !matches!(index, b' ' | b'?') {
                Ok(())
            } else {
                Err(CommandError::new(
                    "git_index_no_staged_change",
                    "Selected paths must have a staged change to unstage.",
                ))
            }
        }
    }
}

fn status_by_path(root: &Path) -> CommandResult<BTreeMap<String, String>> {
    let output = run_git_raw(
        root,
        &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
    )?;
    ensure_success(&output, "git_index_status_failed")?;
    parse_status(&output.stdout)
}

fn parse_status(bytes: &[u8]) -> CommandResult<BTreeMap<String, String>> {
    let mut fields = bytes
        .split(|byte| *byte == 0)
        .filter(|field| !field.is_empty());
    let mut results = BTreeMap::new();
    while let Some(field) = fields.next() {
        if field.len() < 4 || field[2] != b' ' {
            return Err(CommandError::new(
                "git_index_status_invalid",
                "Git status is invalid.",
            ));
        }
        let status = std::str::from_utf8(&field[..2]).map_err(|_| {
            CommandError::new("git_index_path_invalid", "Git changed paths are invalid.")
        })?;
        let path = std::str::from_utf8(&field[3..]).map_err(|_| {
            CommandError::new("git_index_path_invalid", "Git changed paths are invalid.")
        })?;
        validate_relative_path(path)?;
        if status
            .as_bytes()
            .iter()
            .any(|code| matches!(*code, b'R' | b'C'))
        {
            // Porcelain v1 emits a second NUL-delimited source path for a
            // rename/copy. Preserve the destination status so only a selected
            // rename/copy is rejected; unrelated changes must not block safe
            // selected files.
            let source = fields.next().ok_or_else(|| {
                CommandError::new("git_index_status_invalid", "Git rename status is invalid.")
            })?;
            let source = std::str::from_utf8(source).map_err(|_| {
                CommandError::new("git_index_path_invalid", "Git changed paths are invalid.")
            })?;
            validate_relative_path(source)?;
        }
        if results
            .insert(path.to_string(), status.to_string())
            .is_some()
        {
            return Err(CommandError::new(
                "git_index_status_invalid",
                "Git status is invalid.",
            ));
        }
    }
    Ok(results)
}

fn capture_fingerprint(root: &Path, value: &str) -> CommandResult<WorktreeFingerprint> {
    Ok(capture_path_snapshot(root, value)?.fingerprint())
}

enum PathSnapshot {
    File {
        bytes: Vec<u8>,
        fingerprint: WorktreeFingerprint,
    },
    Missing,
}

impl PathSnapshot {
    fn fingerprint(&self) -> WorktreeFingerprint {
        match self {
            Self::File { fingerprint, .. } => fingerprint.clone(),
            Self::Missing => WorktreeFingerprint::Missing,
        }
    }

    fn into_staged_input(self, path: String) -> CommandResult<StagedInput> {
        match self {
            Self::File { bytes, fingerprint } => match fingerprint {
                WorktreeFingerprint::RegularFile { mode, .. } => {
                    Ok(StagedInput::File { path, bytes, mode })
                }
                WorktreeFingerprint::Missing => Err(baseline_changed()),
            },
            Self::Missing => Ok(StagedInput::Delete { path }),
        }
    }
}

fn capture_path_snapshot(root: &Path, value: &str) -> CommandResult<PathSnapshot> {
    let relative = validate_relative_path(value)?;
    validate_ancestor_components(root, &relative)?;
    let path = root.join(relative);
    match fs::symlink_metadata(&path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(PathSnapshot::Missing),
        Err(_) => Err(baseline_changed()),
        Ok(metadata) => {
            if metadata.file_type().is_symlink() {
                return Err(CommandError::new(
                    "git_index_symlink_unsupported",
                    "Symbolic links cannot be changed through this Git index flow.",
                ));
            }
            if !metadata.is_file() || metadata.len() > MAX_FILE_BYTES {
                return Err(CommandError::new(
                    "git_index_file_unsupported",
                    "Selected Git paths must be regular files within the supported size limit.",
                ));
            }
            let mut file = fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(&path)
                .map_err(|_| baseline_changed())?;
            let before = file.metadata().map_err(|_| baseline_changed())?;
            if !before.is_file()
                || before.nlink() == 0
                || before.len() > MAX_FILE_BYTES
                || !same_file_state(&metadata, &before)
            {
                return Err(baseline_changed());
            }
            ensure_open_path(root, &path, file.as_raw_fd())?;
            let mut bytes = Vec::with_capacity(usize::try_from(before.len()).unwrap_or(0));
            (&mut file)
                .take(MAX_FILE_BYTES.saturating_add(1))
                .read_to_end(&mut bytes)
                .map_err(|_| baseline_changed())?;
            let after = file.metadata().map_err(|_| baseline_changed())?;
            ensure_open_path(root, &path, file.as_raw_fd())?;
            if bytes.len() as u64 != before.len() || !same_file_state(&before, &after) {
                return Err(baseline_changed());
            }
            Ok(PathSnapshot::File {
                fingerprint: WorktreeFingerprint::RegularFile {
                    digest: digest(&[&bytes]),
                    byte_size: bytes.len() as u64,
                    mode: file_mode(&before),
                },
                bytes,
            })
        }
    }
}

fn ensure_open_path(root: &Path, expected: &Path, descriptor: i32) -> CommandResult<()> {
    let descriptor_path = PathBuf::from("/proc/self/fd").join(descriptor.to_string());
    let resolved = fs::canonicalize(descriptor_path).map_err(|_| baseline_changed())?;
    if resolved != expected || !resolved.starts_with(root) {
        return Err(baseline_changed());
    }
    Ok(())
}

fn same_file_state(left: &fs::Metadata, right: &fs::Metadata) -> bool {
    left.dev() == right.dev()
        && left.ino() == right.ino()
        && left.len() == right.len()
        && left.mtime() == right.mtime()
        && left.mtime_nsec() == right.mtime_nsec()
        && left.ctime() == right.ctime()
        && left.ctime_nsec() == right.ctime_nsec()
        && right.nlink() > 0
}

fn validate_ancestor_components(root: &Path, relative: &Path) -> CommandResult<()> {
    let mut current = root.to_path_buf();
    let components = relative.components().collect::<Vec<_>>();
    for component in components.iter().take(components.len().saturating_sub(1)) {
        current.push(component.as_os_str());
        let metadata = fs::symlink_metadata(&current).map_err(|_| baseline_changed())?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(CommandError::new(
                "git_index_symlink_unsupported",
                "Symbolic links cannot be changed through this Git index flow.",
            ));
        }
    }
    Ok(())
}

#[cfg(unix)]
fn file_mode(metadata: &fs::Metadata) -> GitFileMode {
    use std::os::unix::fs::PermissionsExt;
    if metadata.permissions().mode() & 0o111 != 0 {
        GitFileMode::Executable
    } else {
        GitFileMode::Regular
    }
}

#[cfg(not(unix))]
fn file_mode(_metadata: &fs::Metadata) -> GitFileMode {
    GitFileMode::Regular
}

fn ensure_not_indexed_symlink(root: &Path, value: &str) -> CommandResult<()> {
    let output = run_git_raw(root, &["ls-files", "--stage", "--", value])?;
    ensure_success(&output, "git_index_inspection_failed")?;
    let output = std::str::from_utf8(&output.stdout).map_err(|_| {
        CommandError::new("git_index_inspection_failed", "Git returned invalid text.")
    })?;
    if output
        .lines()
        .any(|line| line.split_ascii_whitespace().next() == Some("120000"))
    {
        return Err(CommandError::new(
            "git_index_symlink_unsupported",
            "Symbolic links cannot be changed through this Git index flow.",
        ));
    }
    Ok(())
}

fn capture_baseline(root: &Path) -> CommandResult<IndexBaseline> {
    let head = git_text(root, &["rev-parse", "HEAD"])?;
    let object_format =
        GitObjectFormat::parse(&git_text(root, &["rev-parse", "--show-object-format"])?)?;
    let index = run_git_raw_with_limit(
        root,
        &["ls-files", "--stage", "-z"],
        None,
        GitInvocation::ReadOnly,
        MAX_INDEX_SNAPSHOT_BYTES,
    )?;
    ensure_success(&index, "git_index_inspection_failed")?;
    Ok(IndexBaseline {
        head,
        // `ls-files --stage -z` is a bounded, read-only index representation.
        // Unlike `.git/index`, it works when a linked worktree's `.git` is a
        // safe indirection file.
        index_digest: digest(&[&index.stdout]),
        object_format,
    })
}

fn validate_root(root: &Path) -> CommandResult<PathBuf> {
    if !root.is_absolute() {
        return Err(CommandError::new(
            "git_index_repository_invalid",
            "Repository is unavailable for a Git index update.",
        ));
    }
    let metadata = fs::symlink_metadata(root).map_err(|_| {
        CommandError::new(
            "git_index_repository_invalid",
            "Repository is unavailable for a Git index update.",
        )
    })?;
    let canonical = root.canonicalize().map_err(|_| {
        CommandError::new(
            "git_index_repository_invalid",
            "Repository is unavailable for a Git index update.",
        )
    })?;
    let git_metadata = fs::symlink_metadata(root.join(".git")).ok();
    if metadata.file_type().is_symlink()
        || !metadata.is_dir()
        || canonical != root
        || !matches!(git_metadata, Some(ref value) if !value.file_type().is_symlink() && (value.is_file() || value.is_dir()))
    {
        return Err(CommandError::new(
            "git_index_repository_invalid",
            "Repository is unavailable for a Git index update.",
        ));
    }
    super::git_boundary::validate_git_metadata(&canonical).map_err(|_| {
        CommandError::new(
            "git_index_repository_invalid",
            "Repository is unavailable for a Git index update.",
        )
    })?;
    Ok(canonical)
}

fn validate_relative_path(value: &str) -> CommandResult<PathBuf> {
    if value.is_empty()
        || value.len() > MAX_PATH_BYTES
        || value.chars().any(char::is_control)
        || value.contains('\\')
        || value.contains("//")
        || value.ends_with('/')
    {
        return Err(CommandError::new(
            "git_index_path_invalid",
            "Selected Git paths are invalid.",
        ));
    }
    let path = Path::new(value);
    if path.is_absolute()
        || path.components().any(|component| {
            matches!(
                component,
                Component::ParentDir
                    | Component::CurDir
                    | Component::RootDir
                    | Component::Prefix(_)
            )
        })
        || path
            .components()
            .any(|component| component.as_os_str() == ".git")
    {
        return Err(CommandError::new(
            "git_index_path_invalid",
            "Selected Git paths are invalid.",
        ));
    }
    Ok(path.to_path_buf())
}

fn validate_session(value: &str) -> CommandResult<()> {
    Uuid::parse_str(value).map(|_| ()).map_err(|_| {
        CommandError::new(
            "git_index_session_invalid",
            "Repository session is invalid.",
        )
    })
}

fn validate_plan_id(value: &str) -> CommandResult<()> {
    Uuid::parse_str(value)
        .map(|_| ())
        .map_err(|_| CommandError::new("git_index_plan_invalid", "Git index plan is invalid."))
}

fn rfc3339_from_system_time(time: SystemTime) -> CommandResult<String> {
    let duration = time
        .duration_since(UNIX_EPOCH)
        .map_err(|_| CommandError::new("git_index_clock_invalid", "System clock is invalid."))?;
    time::OffsetDateTime::from_unix_timestamp(duration.as_secs() as i64)
        .map_err(|_| CommandError::new("git_index_clock_invalid", "System clock is invalid."))?
        .format(&time::format_description::well_known::Rfc3339)
        .map_err(|_| CommandError::new("git_index_clock_invalid", "System clock is invalid."))
}

fn plans_unavailable() -> CommandError {
    CommandError::new(
        "git_index_plans_unavailable",
        "Git index plans are temporarily unavailable.",
    )
}

fn baseline_changed() -> CommandError {
    CommandError::new(
        "git_index_baseline_changed",
        "Repository state changed; review a new Git index plan.",
    )
}

fn summary_for(action: GitIndexAction, count: usize) -> String {
    match action {
        GitIndexAction::Stage => format!("Review staging for {count} selected file(s)."),
        GitIndexAction::Unstage => format!("Review unstaging for {count} selected file(s)."),
    }
}

fn result_summary(action: GitIndexAction, count: usize) -> String {
    match action {
        GitIndexAction::Stage => {
            format!("Staged {count} selected file(s); the working tree was not changed.")
        }
        GitIndexAction::Unstage => {
            format!("Unstaged {count} selected file(s); the working tree was not changed.")
        }
    }
}

#[derive(PartialEq)]
struct GitOutput {
    status: ExitStatus,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

#[derive(Clone, Copy)]
enum GitInvocation {
    ReadOnly,
    IndexMutation,
}

fn stage_verified_inputs(
    root: &Path,
    inputs: &[StagedInput],
    object_format: GitObjectFormat,
) -> CommandResult<GitOutput> {
    let mut index_info = Vec::new();
    for input in inputs {
        match input {
            StagedInput::File { path, bytes, mode } => {
                let oid = hash_raw_blob(root, bytes, object_format)?;
                index_info.extend_from_slice(mode.index_mode().as_bytes());
                index_info.push(b' ');
                index_info.extend_from_slice(oid.as_bytes());
                index_info.push(b'\t');
                index_info.extend_from_slice(path.as_bytes());
                index_info.push(0);
            }
            StagedInput::Delete { path } => {
                index_info.extend_from_slice(b"0 ");
                index_info.extend_from_slice(object_format.zero_oid().as_bytes());
                index_info.push(b'\t');
                index_info.extend_from_slice(path.as_bytes());
                index_info.push(0);
            }
        }
    }
    // This is the only index mutation. Git writes through its index lock and
    // either replaces the index once or leaves it untouched on failure.
    run_git_raw_with_limit(
        root,
        &["update-index", "-z", "--index-info"],
        Some(&index_info),
        GitInvocation::IndexMutation,
        MAX_GIT_OUTPUT,
    )
}

fn hash_raw_blob(
    root: &Path,
    bytes: &[u8],
    object_format: GitObjectFormat,
) -> CommandResult<String> {
    let output = run_git_raw_with_limit(
        root,
        &["hash-object", "-w", "--stdin"],
        Some(bytes),
        GitInvocation::ReadOnly,
        MAX_GIT_OUTPUT,
    )?;
    ensure_success(&output, "git_index_hash_failed")?;
    let oid = std::str::from_utf8(&output.stdout)
        .map_err(|_| CommandError::new("git_index_hash_failed", "Git blob hashing failed."))?
        .trim();
    if oid.len() != object_format.oid_length() || !oid.bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        return Err(CommandError::new(
            "git_index_hash_failed",
            "Git blob hashing failed.",
        ));
    }
    Ok(oid.to_ascii_lowercase())
}

fn run_git(root: &Path, operation: &str, paths: &[&str]) -> CommandResult<GitOutput> {
    if operation != "restore-staged" {
        return Err(CommandError::new(
            "git_index_operation_invalid",
            "Git index action is invalid.",
        ));
    }
    let mut arguments = vec!["restore", "--staged", "--"];
    arguments.extend(paths.iter().copied());
    run_git_raw_with_limit(
        root,
        &arguments,
        None,
        GitInvocation::IndexMutation,
        MAX_GIT_OUTPUT,
    )
}

fn run_git_raw(root: &Path, arguments: &[&str]) -> CommandResult<GitOutput> {
    run_git_raw_with_limit(
        root,
        arguments,
        None,
        GitInvocation::ReadOnly,
        MAX_GIT_OUTPUT,
    )
}

fn run_git_raw_with_limit(
    root: &Path,
    arguments: &[&str],
    input: Option<&[u8]>,
    invocation: GitInvocation,
    output_limit: usize,
) -> CommandResult<GitOutput> {
    super::git_boundary::validate_git_metadata(root).map_err(|_| {
        CommandError::new(
            "git_index_repository_invalid",
            "Repository is unavailable for a Git index update.",
        )
    })?;
    let mut command = Command::new("git");
    command
        .arg("--literal-pathspecs")
        .arg("-c")
        .arg("core.hooksPath=/dev/null")
        .arg("-c")
        .arg("credential.helper=")
        .arg("-c")
        .arg("core.fsmonitor=false")
        .arg("-c")
        .arg("protocol.ext.allow=never")
        .arg("-c")
        .arg("http.proxy=")
        .arg("-C")
        .arg(root)
        .args(arguments)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("LC_ALL", "C")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if matches!(invocation, GitInvocation::ReadOnly) {
        command.env("GIT_OPTIONAL_LOCKS", "0");
    }
    let mut child = command
        .spawn()
        .map_err(|_| CommandError::new("git_unavailable", "Git executable is unavailable."))?;
    if let Some(input) = input {
        let mut stdin = child.stdin.take().ok_or_else(|| {
            CommandError::new("git_index_input_unavailable", "Git input is unavailable.")
        })?;
        stdin.write_all(input).map_err(|_| {
            CommandError::new("git_index_input_unavailable", "Unable to write Git input.")
        })?;
    }
    let stdout = child.stdout.take().ok_or_else(|| {
        CommandError::new("git_index_output_unavailable", "Git output is unavailable.")
    })?;
    let stderr = child.stderr.take().ok_or_else(|| {
        CommandError::new("git_index_output_unavailable", "Git output is unavailable.")
    })?;
    let stdout_reader = thread::spawn(move || read_output(stdout, output_limit));
    let stderr_reader = thread::spawn(move || read_output(stderr, output_limit));
    let deadline = Instant::now() + GIT_TIMEOUT;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(CommandError::new(
                    "git_timeout",
                    "Git did not finish in time.",
                ));
            }
            Ok(None) => thread::sleep(Duration::from_millis(10)),
            Err(_) => {
                return Err(CommandError::new(
                    "git_wait_failed",
                    "Unable to wait for Git.",
                ))
            }
        }
    };
    let stdout = stdout_reader
        .join()
        .map_err(|_| CommandError::new("git_index_output_unavailable", "Git output failed."))??;
    let stderr = stderr_reader
        .join()
        .map_err(|_| CommandError::new("git_index_output_unavailable", "Git output failed."))??;
    Ok(GitOutput {
        status,
        stdout,
        stderr,
    })
}

fn read_output(reader: impl Read, output_limit: usize) -> CommandResult<Vec<u8>> {
    let mut bytes = Vec::new();
    reader
        .take((output_limit + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| {
            CommandError::new("git_index_output_unavailable", "Unable to read Git output.")
        })?;
    if bytes.len() > output_limit {
        Err(CommandError::new(
            "git_index_output_too_large",
            "Git produced too much output.",
        ))
    } else {
        Ok(bytes)
    }
}

fn ensure_success(output: &GitOutput, code: &str) -> CommandResult<()> {
    // Diagnostics may include repository paths. They are deliberately never
    // included in IPC errors.
    let _ = &output.stderr;
    if output.status.success() {
        Ok(())
    } else {
        Err(CommandError::new(code, "Git index update failed."))
    }
}

fn git_text(root: &Path, arguments: &[&str]) -> CommandResult<String> {
    let output = run_git_raw(root, arguments)?;
    ensure_success(&output, "git_index_inspection_failed")?;
    let value = std::str::from_utf8(&output.stdout)
        .map_err(|_| {
            CommandError::new("git_index_inspection_failed", "Git returned invalid text.")
        })?
        .trim();
    if value.is_empty() || value.len() > MAX_GIT_OUTPUT {
        Err(CommandError::new(
            "git_index_inspection_failed",
            "Git returned invalid text.",
        ))
    } else {
        Ok(value.to_string())
    }
}

fn digest(parts: &[&[u8]]) -> String {
    let mut hash = Sha256::new();
    for part in parts {
        hash.update(part);
    }
    format!("{:x}", hash.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::GitPublishStore;
    use std::fs;
    use std::sync::Mutex;

    static FIXTURE_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn stages_only_selected_literal_unicode_space_and_glob_paths() {
        let _guard = FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let repo = fixture();
        for path in ["文章 [1].md", "other.md"] {
            fs::write(repo.path().join(path), "changed\n").unwrap();
        }
        let store = GitIndexStore::default();
        let session_id = session();
        let plan = store
            .plan(
                &session_id,
                repo.path(),
                GitIndexAction::Stage,
                &["文章 [1].md".to_string()],
            )
            .unwrap();
        let result = store.execute(&session_id, &plan.plan_id).unwrap();
        assert_eq!(result.paths, ["文章 [1].md"]);
        assert_eq!(
            git_text(repo.path(), &["show", ":文章 [1].md"]).unwrap(),
            "changed"
        );
        assert_eq!(
            git_text(repo.path(), &["show", ":other.md"]).unwrap(),
            "before"
        );
        assert_eq!(
            fs::read_to_string(repo.path().join("文章 [1].md")).unwrap(),
            "changed\n"
        );
    }

    #[test]
    fn stages_deletion_and_unstage_never_changes_worktree() {
        let _guard = FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let repo = fixture();
        fs::remove_file(repo.path().join("delete.md")).unwrap();
        fs::write(repo.path().join("first.md"), "executable change\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(
                repo.path().join("first.md"),
                fs::Permissions::from_mode(0o755),
            )
            .unwrap();
        }
        let store = GitIndexStore::default();
        let session_id = session();
        let plan = store
            .plan(
                &session_id,
                repo.path(),
                GitIndexAction::Stage,
                &["first.md".to_string(), "delete.md".to_string()],
            )
            .unwrap();
        store.execute(&session_id, &plan.plan_id).unwrap();
        let staged = git_text(repo.path(), &["diff", "--cached", "--name-only"]).unwrap();
        assert!(staged.contains("first.md") && staged.contains("delete.md"));
        assert!(
            git_text(repo.path(), &["ls-files", "--stage", "--", "first.md"])
                .unwrap()
                .starts_with("100755 ")
        );
        let unstage = store
            .plan(
                &session_id,
                repo.path(),
                GitIndexAction::Unstage,
                &["first.md".to_string(), "delete.md".to_string()],
            )
            .unwrap();
        store.execute(&session_id, &unstage.plan_id).unwrap();
        assert!(!repo.path().join("delete.md").exists());
        assert_eq!(
            fs::read_to_string(repo.path().join("first.md")).unwrap(),
            "executable change\n"
        );
        assert_eq!(
            git_text(repo.path(), &["show", ":delete.md"]).unwrap(),
            "before"
        );
    }

    #[test]
    fn rejects_symlink_rename_and_dangerous_paths() {
        let _guard = FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let repo = fixture();
        #[cfg(unix)]
        std::os::unix::fs::symlink("first.md", repo.path().join("link.md")).unwrap();
        #[cfg(unix)]
        {
            let store = GitIndexStore::default();
            let error = store
                .plan(
                    &session(),
                    repo.path(),
                    GitIndexAction::Stage,
                    &["link.md".to_string()],
                )
                .unwrap_err();
            assert_eq!(error.code, "git_index_symlink_unsupported");
        }
        fixture_git(repo.path(), &["mv", "first.md", "renamed.md"]);
        let store = GitIndexStore::default();
        let error = store
            .plan(
                &session(),
                repo.path(),
                GitIndexAction::Stage,
                &["renamed.md".to_string()],
            )
            .unwrap_err();
        assert_eq!(error.code, "git_index_rename_copy_unsupported");
        for path in ["../x.md", ".git/config", "/tmp/x", "a\\b.md", "a\n.md"] {
            let error = store
                .plan(
                    &session(),
                    repo.path(),
                    GitIndexAction::Stage,
                    &[path.to_string()],
                )
                .unwrap_err();
            assert_eq!(error.code, "git_index_path_invalid");
        }
    }

    #[test]
    fn rejects_expired_reused_and_cross_session_plans() {
        let _guard = FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let repo = fixture();
        fs::write(repo.path().join("first.md"), "changed\n").unwrap();
        let store = GitIndexStore::default();
        let session_id = session();
        let plan = store
            .plan(
                &session_id,
                repo.path(),
                GitIndexAction::Stage,
                &["first.md".to_string()],
            )
            .unwrap();
        assert_eq!(
            store.execute(&session(), &plan.plan_id).unwrap_err().code,
            "git_index_session_mismatch"
        );
        assert_eq!(
            store.execute(&session_id, &plan.plan_id).unwrap_err().code,
            "git_index_plan_not_found"
        );
        let expired = store
            .plan(
                &session_id,
                repo.path(),
                GitIndexAction::Stage,
                &["first.md".to_string()],
            )
            .unwrap();
        store
            .plans
            .lock()
            .unwrap()
            .get_mut(&expired.plan_id)
            .unwrap()
            .expires_at = SystemTime::now() - Duration::from_secs(1);
        assert_eq!(
            store
                .execute(&session_id, &expired.plan_id)
                .unwrap_err()
                .code,
            "git_index_plan_expired"
        );
    }

    #[test]
    fn rejects_head_index_and_worktree_drift() {
        let _guard = FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let repo = fixture();
        let session = session();
        let store = GitIndexStore::default();
        fs::write(repo.path().join("first.md"), "first change\n").unwrap();
        let worktree = store
            .plan(
                &session,
                repo.path(),
                GitIndexAction::Stage,
                &["first.md".to_string()],
            )
            .unwrap();
        fs::write(repo.path().join("first.md"), "second change\n").unwrap();
        assert_eq!(
            store.execute(&session, &worktree.plan_id).unwrap_err().code,
            "git_index_baseline_changed"
        );
        let index = store
            .plan(
                &session,
                repo.path(),
                GitIndexAction::Stage,
                &["first.md".to_string()],
            )
            .unwrap();
        fs::write(repo.path().join("other.md"), "other change\n").unwrap();
        fixture_git(repo.path(), &["add", "other.md"]);
        assert_eq!(
            store.execute(&session, &index.plan_id).unwrap_err().code,
            "git_index_baseline_changed"
        );
        fixture_git(repo.path(), &["restore", "--staged", "other.md"]);
        let head = store
            .plan(
                &session,
                repo.path(),
                GitIndexAction::Stage,
                &["first.md".to_string()],
            )
            .unwrap();
        fixture_git(repo.path(), &["add", "first.md"]);
        fixture_git(repo.path(), &["commit", "-m", "external"]);
        assert_eq!(
            store.execute(&session, &head.plan_id).unwrap_err().code,
            "git_index_baseline_changed"
        );
    }

    #[test]
    fn staged_output_can_create_existing_commit_plan() {
        let _guard = FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let repo = fixture();
        fs::write(repo.path().join("first.md"), "ready\n").unwrap();
        let store = GitIndexStore::default();
        let session = session();
        let stage = store
            .plan(
                &session,
                repo.path(),
                GitIndexAction::Stage,
                &["first.md".to_string()],
            )
            .unwrap();
        store.execute(&session, &stage.plan_id).unwrap();
        let publish = GitPublishStore::default();
        assert!(publish
            .plan_commit(&session, repo.path(), "docs: ready")
            .is_ok());
    }

    #[test]
    fn staging_raw_bytes_never_runs_a_repository_clean_filter() {
        let _guard = FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let repo = fixture();
        fixture_git(
            repo.path(),
            &[
                "config",
                "filter.marker.clean",
                "sh -c 'echo executed > filter-marker; cat'",
            ],
        );
        fs::write(
            repo.path().join(".gitattributes"),
            "filtered.md filter=marker\n",
        )
        .unwrap();
        fs::write(repo.path().join("filtered.md"), b"raw\0bytes\n").unwrap();
        let store = GitIndexStore::default();
        let session = session();
        let plan = store
            .plan(
                &session,
                repo.path(),
                GitIndexAction::Stage,
                &["filtered.md".to_string()],
            )
            .unwrap();
        store.execute(&session, &plan.plan_id).unwrap();
        assert!(!repo.path().join("filter-marker").exists());
        assert_eq!(
            git_bytes(repo.path(), &["show", ":filtered.md"]),
            b"raw\0bytes\n"
        );
    }

    #[test]
    fn rejects_git_file_pointing_to_another_repository() {
        let _guard = FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let victim = fixture();
        let supplied = tempfile::tempdir().unwrap();
        fs::write(
            supplied.path().join(".git"),
            format!("gitdir: {}\n", victim.path().join(".git").display()),
        )
        .unwrap();
        fs::write(supplied.path().join("first.md"), "attacker supplied\n").unwrap();
        let before = git_bytes(victim.path(), &["ls-files", "--stage", "-z"]);
        let result = GitIndexStore::default().plan(
            &session(),
            supplied.path(),
            GitIndexAction::Stage,
            &["first.md".to_owned()],
        );
        assert!(result.is_err(), "foreign Git metadata must not be accepted");
        assert_eq!(
            git_bytes(victim.path(), &["ls-files", "--stage", "-z"]),
            before
        );
    }

    #[test]
    fn supports_safe_git_file_in_a_linked_worktree() {
        let _guard = FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let repo = fixture();
        let temporary = tempfile::tempdir().unwrap();
        let linked_path = temporary.path().to_path_buf();
        drop(temporary);
        let linked_argument = linked_path.to_str().unwrap();
        fixture_git(
            repo.path(),
            &[
                "worktree",
                "add",
                "-q",
                "-b",
                "linked-index-test",
                linked_argument,
            ],
        );
        assert!(fs::symlink_metadata(linked_path.join(".git"))
            .unwrap()
            .is_file());
        fs::write(linked_path.join("first.md"), "linked change\n").unwrap();
        let store = GitIndexStore::default();
        let session = session();
        let plan = store
            .plan(
                &session,
                &linked_path,
                GitIndexAction::Stage,
                &["first.md".to_string()],
            )
            .unwrap();
        store.execute(&session, &plan.plan_id).unwrap();
        assert_eq!(
            git_text(&linked_path, &["show", ":first.md"]).unwrap(),
            "linked change"
        );
        fixture_git(
            repo.path(),
            &["worktree", "remove", "--force", linked_argument],
        );
    }

    #[test]
    fn supports_git_file_in_a_submodule() {
        let _guard = FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let parent = fixture();
        let source = fixture();
        let source_before = git_bytes(source.path(), &["show", ":first.md"]);
        fixture_git(
            parent.path(),
            &[
                "-c",
                "protocol.file.allow=always",
                "submodule",
                "add",
                "-q",
                source.path().to_str().unwrap(),
                "child",
            ],
        );
        let root = parent.path().join("child");
        fs::write(root.join("first.md"), "submodule change\n").unwrap();
        let store = GitIndexStore::default();
        let session = session();
        let plan = store
            .plan(
                &session,
                &root,
                GitIndexAction::Stage,
                &["first.md".to_owned()],
            )
            .unwrap();
        store.execute(&session, &plan.plan_id).unwrap();
        assert_eq!(
            git_text(&root, &["show", ":first.md"]).unwrap(),
            "submodule change"
        );
        assert_eq!(
            git_bytes(source.path(), &["show", ":first.md"]),
            source_before
        );
    }

    fn session() -> String {
        Uuid::new_v4().to_string()
    }

    fn fixture() -> tempfile::TempDir {
        let repository = tempfile::tempdir().unwrap();
        fixture_git(repository.path(), &["init", "-q", "-b", "main"]);
        fixture_git(repository.path(), &["config", "user.name", "Tests"]);
        fixture_git(
            repository.path(),
            &["config", "user.email", "tests@example.invalid"],
        );
        for path in ["first.md", "other.md", "delete.md", "文章 [1].md"] {
            fs::write(repository.path().join(path), "before\n").unwrap();
        }
        fixture_git(repository.path(), &["add", "."]);
        fixture_git(repository.path(), &["commit", "-q", "-m", "initial"]);
        repository
    }

    fn fixture_git(root: &Path, arguments: &[&str]) {
        assert!(Command::new("git")
            .arg("-C")
            .arg(root)
            .args(arguments)
            .status()
            .unwrap()
            .success());
    }

    fn git_bytes(root: &Path, arguments: &[&str]) -> Vec<u8> {
        let output = Command::new("git")
            .arg("-C")
            .arg(root)
            .args(arguments)
            .output()
            .unwrap();
        assert!(output.status.success());
        output.stdout
    }
}
