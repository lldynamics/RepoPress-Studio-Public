//! Bounded proof for the main editor only. No credentials or full-workspace backup.
use super::workspace_state::{validate_snapshot, RecoveryDraftSnapshot};
use super::{CommandError, CommandResult, WorkspaceStateSnapshot, WorkspaceStateStore};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use uuid::Uuid;

const MAX_FILE_BYTES: u64 = 16 * 1024 * 1024;
const PROOF_TTL: Duration = Duration::from_secs(60);
const INSTRUCTIONS: &str = "RepoPress 当前文章恢复包\n\n正文完整保存在 draft.md，可使用任意文本编辑器打开。\nrecovery.json 记录原仓库、相对路径、原始基线和正文 SHA-256。\n恢复时请先保留原文件，再比对 draft.md 并手动合并；不要直接覆盖已被外部修改的文章。\n本包不包含图片、附件、其他面板输入、资料库、RSS、聊天、发布状态或凭据。\n";

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorExitPlan {
    pub plan_id: String,
    pub export_path: Option<String>,
}

struct PackageProof {
    directory: PathBuf,
    files: Vec<(&'static str, Vec<u8>)>,
}

enum Evidence {
    Workspace(Box<WorkspaceStateSnapshot>),
    // No current dirty buffer: retain an unreadable startup file verbatim.
    UntouchedWorkspace(Box<WorkspaceStateSnapshot>),
    Package(PackageProof),
}

struct ExitProof {
    id: String,
    created: Instant,
    evidence: Evidence,
}

#[derive(Default)]
pub struct EditorExitStore {
    proof: Mutex<Option<ExitProof>>,
}

impl EditorExitStore {
    pub fn prepare(
        &self,
        workspace: &WorkspaceStateStore,
        draft: Option<RecoveryDraftSnapshot>,
        export_directory: Option<&Path>,
    ) -> CommandResult<EditorExitPlan> {
        let mut pending = self.proof.lock().map_err(|_| unavailable())?;
        // Every new attempt invalidates the previous ticket, including failure.
        *pending = None;
        let (evidence, export_path) = if let Some(directory) = export_directory {
            let draft = draft
                .ok_or_else(|| CommandError::new("exit_no_draft", "No current draft to export."))?;
            let package = export_package(directory, &draft)?;
            let path = package
                .directory
                .to_str()
                .ok_or_else(unavailable)?
                .to_owned();
            (Evidence::Package(package), Some(path))
        } else {
            let snapshot = workspace.snapshot()?;
            if draft.is_none() && snapshot.warning.is_some() {
                (Evidence::UntouchedWorkspace(Box::new(snapshot)), None)
            } else {
                (
                    Evidence::Workspace(Box::new(workspace.persist_for_exit(draft)?)),
                    None,
                )
            }
        };
        let id = Uuid::new_v4().to_string();
        *pending = Some(ExitProof {
            id: id.clone(),
            created: Instant::now(),
            evidence,
        });
        Ok(EditorExitPlan {
            plan_id: id,
            export_path,
        })
    }

    pub fn complete(&self, workspace: &WorkspaceStateStore, plan_id: &str) -> CommandResult<()> {
        // Consume before every check. Failure and replay both require a fresh preparation.
        let proof = self
            .proof
            .lock()
            .map_err(|_| unavailable())?
            .take()
            .ok_or_else(unavailable)?;
        if proof.id != plan_id || proof.created.elapsed() >= PROOF_TTL {
            return Err(unavailable());
        }
        match proof.evidence {
            Evidence::Workspace(snapshot) => workspace.verify_exit_snapshot(&snapshot),
            Evidence::Package(package) => verify_package(&package),
            Evidence::UntouchedWorkspace(snapshot) => {
                if snapshot.warning.is_none() || workspace.snapshot()? != *snapshot {
                    return Err(unavailable());
                }
                // Deliberately neither write nor certify the unreadable primary file.
                Ok(())
            }
        }
    }
}

fn unavailable() -> CommandError {
    CommandError::new(
        "exit_proof_invalid",
        "Exit proof is absent, expired, or changed. Prepare again.",
    )
}

fn io_error(error: std::io::Error) -> CommandError {
    CommandError::io(
        "exit_export_failed",
        "Unable to write or verify the recovery package",
        error,
    )
}

fn real_directory(path: &Path) -> CommandResult<File> {
    if !path.is_absolute()
        || path
            .components()
            .any(|p| matches!(p, std::path::Component::ParentDir))
    {
        return Err(unavailable());
    }
    // Reject symlinks in every component, including the destination parent.
    let mut cursor = PathBuf::new();
    for part in path.components() {
        cursor.push(part);
        let metadata = fs::symlink_metadata(&cursor).map_err(io_error)?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            return Err(unavailable());
        }
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_DIRECTORY | libc::O_CLOEXEC);
    }
    options.open(path).map_err(io_error)
}

// Linux uses an open directory descriptor for all child I/O; swapping its pathname
// cannot redirect writes. Other targets still use unique private export directories.
fn anchored_path(directory: &File, path: &Path) -> PathBuf {
    #[cfg(target_os = "linux")]
    {
        use std::os::fd::AsRawFd;
        let _ = path;
        PathBuf::from(format!("/proc/self/fd/{}", directory.as_raw_fd()))
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = directory;
        path.to_owned()
    }
}

fn export_package(parent: &Path, draft: &RecoveryDraftSnapshot) -> CommandResult<PackageProof> {
    if draft.text.len() as u64 > MAX_FILE_BYTES {
        return Err(CommandError::new(
            "exit_export_too_large",
            "Recovery package text exceeds 16 MiB.",
        ));
    }
    // The emergency copy also preserves buffers that a normal 4 MiB/LF-only
    // recovery save rejects. Validate all metadata, without transforming text.
    let mut metadata_draft = draft.clone();
    metadata_draft.text.clear();
    validate_snapshot(&WorkspaceStateSnapshot {
        recovery_draft: Some(metadata_draft),
        ..WorkspaceStateSnapshot::default()
    })?;
    let parent_handle = real_directory(parent)?;
    let anchored_parent = anchored_path(&parent_handle, parent);
    let temporary = tempfile::Builder::new()
        .prefix("RepoPress-recovery-")
        .tempdir_in(&anchored_parent)
        .map_err(io_error)?;
    let name = temporary
        .path()
        .file_name()
        .ok_or_else(unavailable)?
        .to_owned();
    // Once created, retain even a failed/partial package for diagnosis; never delete user data.
    let anchored_directory = temporary.keep();
    let directory = parent.join(name);
    let handle = File::open(&anchored_directory).map_err(io_error)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        handle
            .set_permissions(fs::Permissions::from_mode(0o700))
            .map_err(io_error)?;
    }
    let metadata = serde_json::json!({
        "format": "repopress-editor-recovery", "schemaVersion": 1,
        "repositoryPath": draft.repository_path, "relativePath": draft.relative_path,
        "baselineSha256": draft.baseline_sha256, "savedAtEpochSeconds": draft.saved_at_epoch_seconds,
        "textFile": "draft.md", "textSha256": format!("{:x}", Sha256::digest(draft.text.as_bytes())),
        "textByteSize": draft.text.len()
    });
    let files = vec![
        ("draft.md", draft.text.as_bytes().to_vec()),
        (
            "recovery.json",
            serde_json::to_vec_pretty(&metadata).map_err(|_| unavailable())?,
        ),
        ("README.txt", INSTRUCTIONS.as_bytes().to_vec()),
    ];
    let anchored = anchored_path(&handle, &directory);
    for (name, bytes) in &files {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
        }
        let mut file = options.open(anchored.join(name)).map_err(io_error)?;
        file.write_all(bytes).map_err(io_error)?;
        file.sync_all().map_err(io_error)?;
    }
    handle.sync_all().map_err(io_error)?;
    parent_handle.sync_all().map_err(io_error)?;
    let proof = PackageProof { directory, files };
    verify_package(&proof)?;
    Ok(proof)
}

fn verify_package(proof: &PackageProof) -> CommandResult<()> {
    let directory = real_directory(&proof.directory)?;
    let anchored = anchored_path(&directory, &proof.directory);
    for (name, expected) in &proof.files {
        let mut options = OpenOptions::new();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC);
        }
        let file = options.open(anchored.join(name)).map_err(io_error)?;
        let metadata = file.metadata().map_err(io_error)?;
        if !metadata.is_file()
            || metadata.len() > MAX_FILE_BYTES
            || metadata.len() != expected.len() as u64
        {
            return Err(unavailable());
        }
        let mut actual = Vec::new();
        file.take(MAX_FILE_BYTES + 1)
            .read_to_end(&mut actual)
            .map_err(io_error)?;
        if actual != *expected {
            return Err(unavailable());
        }
    }
    Ok(())
}

#[cfg(test)]
#[path = "editor_exit_tests.rs"]
mod tests;
