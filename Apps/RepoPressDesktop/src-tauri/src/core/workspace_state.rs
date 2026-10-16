use super::{CommandError, CommandResult};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};
use tempfile::Builder;
use uuid::Uuid;

const SCHEMA_VERSION: u32 = 1;
const MAX_STATE_BYTES: u64 = 5 * 1024 * 1024;
const MAX_DRAFT_BYTES: usize = 4 * 1024 * 1024;
const MAX_RECENT_REPOSITORIES: usize = 10;
const MAX_PATH_BYTES: usize = 4096;
const MAX_DISPLAY_NAME_BYTES: usize = 256;
const MAX_WARNING_BYTES: usize = 512;
const STATE_FILE: &str = "workspace-state.json";
const WRITING_TOOLBAR_ITEM_IDS: [&str; 12] = [
    "bold",
    "italic",
    "strike",
    "code",
    "link",
    "heading",
    "quote",
    "unorderedList",
    "orderedList",
    "taskList",
    "codeBlock",
    "horizontalRule",
];

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct WorkspacePreferences {
    pub theme: String,
    #[serde(default = "default_ui_language")]
    pub ui_language: String,
    pub editor_font_size: u16,
    #[serde(default = "default_editor_line_spacing")]
    pub editor_line_spacing: u8,
    #[serde(default = "default_editor_body_width")]
    pub editor_body_width: u16,
    #[serde(default)]
    pub spell_check_enabled: bool,
    #[serde(default)]
    pub typewriter_mode_enabled: bool,
    #[serde(default = "default_current_paragraph_highlight_enabled")]
    pub current_paragraph_highlight_enabled: bool,
    #[serde(default)]
    pub warm_paper_background_enabled: bool,
    #[serde(default = "default_automatic_pairing_enabled")]
    pub automatic_pairing_enabled: bool,
    #[serde(default)]
    pub paragraph_spotlight_enabled: bool,
    #[serde(default = "default_writing_tool_density")]
    pub writing_tool_density: String,
    #[serde(default = "default_writing_toolbar_item_ids")]
    pub writing_toolbar_item_ids: Vec<String>,
    pub restore_last_workspace: bool,
    pub recovery_enabled: bool,
}

impl Default for WorkspacePreferences {
    fn default() -> Self {
        Self {
            theme: "system".to_string(),
            ui_language: default_ui_language(),
            editor_font_size: 15,
            editor_line_spacing: default_editor_line_spacing(),
            editor_body_width: default_editor_body_width(),
            spell_check_enabled: false,
            typewriter_mode_enabled: false,
            current_paragraph_highlight_enabled: default_current_paragraph_highlight_enabled(),
            warm_paper_background_enabled: false,
            automatic_pairing_enabled: default_automatic_pairing_enabled(),
            paragraph_spotlight_enabled: false,
            writing_tool_density: default_writing_tool_density(),
            writing_toolbar_item_ids: default_writing_toolbar_item_ids(),
            restore_last_workspace: true,
            recovery_enabled: true,
        }
    }
}

fn default_ui_language() -> String {
    "zh-CN".to_string()
}

fn default_editor_line_spacing() -> u8 {
    4
}

fn default_editor_body_width() -> u16 {
    820
}

fn default_current_paragraph_highlight_enabled() -> bool {
    true
}

fn default_automatic_pairing_enabled() -> bool {
    true
}

fn default_writing_tool_density() -> String {
    "basic".to_string()
}

fn default_writing_toolbar_item_ids() -> Vec<String> {
    WRITING_TOOLBAR_ITEM_IDS
        .iter()
        .map(|item| (*item).to_string())
        .collect()
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RecentRepositorySnapshot {
    pub path: String,
    pub display_name: String,
    pub last_opened_at_epoch_seconds: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RecoveryDraftSnapshot {
    pub recovery_id: String,
    pub repository_path: String,
    pub relative_path: String,
    pub text: String,
    pub baseline_sha256: String,
    pub saved_at_epoch_seconds: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceStateSnapshot {
    pub schema_version: u32,
    pub preferences: WorkspacePreferences,
    pub recent_repositories: Vec<RecentRepositorySnapshot>,
    pub last_repository_path: Option<String>,
    pub last_document_path: Option<String>,
    pub recovery_draft: Option<RecoveryDraftSnapshot>,
    pub warning: Option<String>,
}

impl Default for WorkspaceStateSnapshot {
    fn default() -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            preferences: WorkspacePreferences::default(),
            recent_repositories: Vec::new(),
            last_repository_path: None,
            last_document_path: None,
            recovery_draft: None,
            warning: None,
        }
    }
}

#[derive(Debug)]
struct StoragePaths {
    directory: PathBuf,
    state_file: PathBuf,
}

/// Small private state store. `Default` deliberately has no filesystem backing and is only for
/// isolated tests; the desktop app always constructs this with Tauri's app data directory.
#[derive(Debug)]
pub struct WorkspaceStateStore {
    storage: Option<StoragePaths>,
    state: Mutex<WorkspaceStateSnapshot>,
}

impl Default for WorkspaceStateStore {
    fn default() -> Self {
        Self {
            storage: None,
            state: Mutex::new(WorkspaceStateSnapshot::default()),
        }
    }
}

impl WorkspaceStateStore {
    /// Exit proof must be backed by the primary file, never a memory-only store
    /// or the tolerant startup loader's empty/corrupt fallback.
    pub fn persist_for_exit(
        &self,
        draft: Option<RecoveryDraftSnapshot>,
    ) -> CommandResult<WorkspaceStateSnapshot> {
        if self.storage.is_none() {
            return Err(CommandError::new(
                "exit_storage_unavailable",
                "No durable workspace storage.",
            ));
        }
        let mut state = self.state.lock().map_err(|_| {
            CommandError::new(
                "workspace_state_unavailable",
                "Workspace state lock is poisoned.",
            )
        })?;
        if state.warning.is_some() {
            return Err(CommandError::new(
                "exit_untrusted_workspace",
                "Startup recovery could not be loaded reliably. Export the current draft instead.",
            ));
        }
        let mut snapshot = state.clone();
        if let Some(draft) = draft {
            if !snapshot.preferences.recovery_enabled {
                return Err(CommandError::new(
                    "exit_recovery_disabled",
                    "Recovery is disabled. Export the draft before exiting.",
                ));
            }
            snapshot.recovery_draft = Some(draft);
        }
        snapshot.warning = None;
        validate_snapshot(&snapshot)?;
        write_state(self.storage.as_ref().expect("checked above"), &snapshot)?;
        *state = snapshot.clone();
        drop(state);
        self.verify_exit_snapshot(&snapshot)?;
        Ok(snapshot)
    }

    pub fn verify_exit_snapshot(&self, expected: &WorkspaceStateSnapshot) -> CommandResult<()> {
        let state = self.state.lock().map_err(|_| {
            CommandError::new(
                "workspace_state_unavailable",
                "Workspace state lock is poisoned.",
            )
        })?;
        let storage = self.storage.as_ref().ok_or_else(|| {
            CommandError::new("exit_storage_unavailable", "No durable workspace storage.")
        })?;
        validate_storage_directory(storage)?;
        // Missing must fail, even when `expected` is the default empty snapshot.
        let metadata = fs::symlink_metadata(&storage.state_file).map_err(|error| {
            CommandError::io(
                "exit_verification_failed",
                "Recovery state is missing",
                error,
            )
        })?;
        if !metadata.is_file()
            || metadata.file_type().is_symlink()
            || &*state != expected
            || expected.warning.is_some()
            || load_state(storage)? != *expected
        {
            return Err(CommandError::new(
                "exit_verification_failed",
                "Recovery state changed or cannot be verified.",
            ));
        }
        Ok(())
    }

    pub fn new(app_data_dir: PathBuf) -> CommandResult<Self> {
        let storage = prepare_storage(&app_data_dir)?;
        let state = load_state(&storage)?;
        Ok(Self {
            storage: Some(storage),
            state: Mutex::new(state),
        })
    }

    pub fn snapshot(&self) -> CommandResult<WorkspaceStateSnapshot> {
        Ok(self.lock_state()?.clone())
    }

    pub fn update_preferences(
        &self,
        preferences: WorkspacePreferences,
    ) -> CommandResult<WorkspaceStateSnapshot> {
        validate_preferences(&preferences)?;
        self.mutate(|state| {
            state.preferences = preferences;
            if !state.preferences.recovery_enabled {
                state.recovery_draft = None;
            }
        })
    }

    pub fn record_repository_opened(
        &self,
        path: &Path,
        display_name: &str,
    ) -> CommandResult<WorkspaceStateSnapshot> {
        let path = path_to_string(path)?;
        validate_string(&path, MAX_PATH_BYTES, "repository path")?;
        validate_string(
            display_name,
            MAX_DISPLAY_NAME_BYTES,
            "repository display name",
        )?;
        self.mutate(|state| {
            state.recent_repositories.retain(|entry| entry.path != path);
            state.recent_repositories.insert(
                0,
                RecentRepositorySnapshot {
                    path: path.clone(),
                    display_name: display_name.to_string(),
                    last_opened_at_epoch_seconds: now_epoch_seconds(),
                },
            );
            state.recent_repositories.truncate(MAX_RECENT_REPOSITORIES);
            state.last_repository_path = Some(path);
        })
    }

    pub fn record_document_opened(
        &self,
        repository_path: &Path,
        relative_path: &str,
    ) -> CommandResult<WorkspaceStateSnapshot> {
        let repository_path = path_to_string(repository_path)?;
        validate_string(&repository_path, MAX_PATH_BYTES, "repository path")?;
        validate_relative_path(relative_path)?;
        self.mutate(|state| {
            state.last_repository_path = Some(repository_path);
            state.last_document_path = Some(relative_path.to_string());
        })
    }

    pub fn save_recovery_draft(
        &self,
        repository_path: &Path,
        relative_path: &str,
        text: &str,
        baseline_sha256: &str,
    ) -> CommandResult<WorkspaceStateSnapshot> {
        validate_draft(text, baseline_sha256)?;
        let repository_path = path_to_string(repository_path)?;
        validate_string(&repository_path, MAX_PATH_BYTES, "repository path")?;
        validate_relative_path(relative_path)?;
        self.mutate(|state| {
            if !state.preferences.recovery_enabled {
                return;
            }
            state.recovery_draft = Some(RecoveryDraftSnapshot {
                recovery_id: Uuid::new_v4().to_string(),
                repository_path,
                relative_path: relative_path.to_string(),
                text: text.to_string(),
                baseline_sha256: baseline_sha256.to_string(),
                saved_at_epoch_seconds: now_epoch_seconds(),
            });
        })
    }

    pub fn clear_recovery_draft(&self, recovery_id: &str) -> CommandResult<WorkspaceStateSnapshot> {
        parse_recovery_id(recovery_id)?;
        self.mutate(|state| {
            if state
                .recovery_draft
                .as_ref()
                .is_some_and(|draft| draft.recovery_id == recovery_id)
            {
                state.recovery_draft = None;
            }
        })
    }

    pub fn clear_matching_recovery(
        &self,
        repository_path: &Path,
        relative_path: &str,
        baseline_sha256: &str,
    ) -> CommandResult<WorkspaceStateSnapshot> {
        let repository_path = path_to_string(repository_path)?;
        self.mutate(|state| {
            if state.recovery_draft.as_ref().is_some_and(|draft| {
                draft.repository_path == repository_path
                    && draft.relative_path == relative_path
                    && draft.baseline_sha256 == baseline_sha256
            }) {
                state.recovery_draft = None;
            }
        })
    }

    fn mutate(
        &self,
        change: impl FnOnce(&mut WorkspaceStateSnapshot),
    ) -> CommandResult<WorkspaceStateSnapshot> {
        let mut state = self.lock_state()?;
        let mut next = state.clone();
        change(&mut next);
        next.schema_version = SCHEMA_VERSION;
        next.warning = None;
        validate_snapshot(&next)?;
        if let Some(storage) = &self.storage {
            write_state(storage, &next)?;
        }
        *state = next.clone();
        Ok(next)
    }

    fn lock_state(&self) -> CommandResult<std::sync::MutexGuard<'_, WorkspaceStateSnapshot>> {
        self.state.lock().map_err(|_| {
            CommandError::new(
                "workspace_state_unavailable",
                "Workspace state is temporarily unavailable.",
            )
        })
    }
}

fn prepare_storage(app_data_dir: &Path) -> CommandResult<StoragePaths> {
    fs::create_dir_all(app_data_dir).map_err(|error| {
        CommandError::io(
            "workspace_storage_unavailable",
            "Unable to create the application data directory",
            error,
        )
    })?;
    let directory = app_data_dir.join("workspace");
    match fs::symlink_metadata(&directory) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() || !metadata.is_dir() {
                return Err(CommandError::new(
                    "workspace_storage_unsafe",
                    "Workspace storage must be a private directory.",
                ));
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            fs::create_dir(&directory).map_err(|error| {
                CommandError::io(
                    "workspace_storage_unavailable",
                    "Unable to create private workspace storage",
                    error,
                )
            })?;
        }
        Err(error) => {
            return Err(CommandError::io(
                "workspace_storage_unavailable",
                "Unable to inspect workspace storage",
                error,
            ));
        }
    }
    set_private_directory_permissions(&directory)?;
    Ok(StoragePaths {
        state_file: directory.join(STATE_FILE),
        directory,
    })
}

fn load_state(storage: &StoragePaths) -> CommandResult<WorkspaceStateSnapshot> {
    let metadata = match fs::symlink_metadata(&storage.state_file) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(WorkspaceStateSnapshot::default());
        }
        Err(error) => {
            return Err(CommandError::io(
                "workspace_state_unavailable",
                "Unable to inspect workspace state",
                error,
            ));
        }
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(CommandError::new(
            "workspace_state_unsafe",
            "Workspace state is not a regular private file.",
        ));
    }
    if metadata.len() > MAX_STATE_BYTES {
        return Err(CommandError::new(
            "workspace_state_too_large",
            "Workspace state exceeds the safety limit.",
        ));
    }
    let mut file = open_state_file(&storage.state_file).map_err(|error| {
        CommandError::io(
            "workspace_state_unavailable",
            "Unable to read workspace state",
            error,
        )
    })?;
    let opened_metadata = file.metadata().map_err(|error| {
        CommandError::io(
            "workspace_state_unavailable",
            "Unable to inspect the opened workspace state",
            error,
        )
    })?;
    if !opened_metadata.is_file() || opened_metadata.len() > MAX_STATE_BYTES {
        return Err(CommandError::new(
            "workspace_state_unsafe",
            "Workspace state changed while it was being opened.",
        ));
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    Read::by_ref(&mut file)
        .take(MAX_STATE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| {
            CommandError::io(
                "workspace_state_unavailable",
                "Unable to read workspace state",
                error,
            )
        })?;
    if bytes.len() as u64 > MAX_STATE_BYTES {
        return Err(CommandError::new(
            "workspace_state_too_large",
            "Workspace state exceeds the safety limit.",
        ));
    }
    match serde_json::from_slice::<WorkspaceStateSnapshot>(&bytes) {
        Ok(state) if validate_snapshot_json(&state).is_ok() => Ok(state),
        _ => Ok(WorkspaceStateSnapshot {
            warning: Some(
                "Saved workspace state is invalid and was ignored; it will be replaced after your next workspace update."
                    .to_string(),
            ),
            ..WorkspaceStateSnapshot::default()
        }),
    }
}

fn open_state_file(path: &Path) -> std::io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC);
    }
    options.open(path)
}

fn write_state(storage: &StoragePaths, state: &WorkspaceStateSnapshot) -> CommandResult<()> {
    validate_storage_directory(storage)?;
    let encoded = serde_json::to_vec(state).map_err(|error| {
        CommandError::new(
            "workspace_state_encode_failed",
            format!("Unable to encode workspace state: {error}"),
        )
    })?;
    if encoded.len() as u64 > MAX_STATE_BYTES {
        return Err(CommandError::new(
            "workspace_state_too_large",
            "Workspace state exceeds the safety limit.",
        ));
    }
    let current = fs::symlink_metadata(&storage.state_file);
    if let Ok(metadata) = current {
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err(CommandError::new(
                "workspace_state_unsafe",
                "Workspace state is not a regular private file.",
            ));
        }
    } else if let Err(error) = current {
        if error.kind() != std::io::ErrorKind::NotFound {
            return Err(CommandError::io(
                "workspace_state_unavailable",
                "Unable to inspect workspace state",
                error,
            ));
        }
    }
    let mut temporary = Builder::new()
        .prefix(".workspace-state-")
        .tempfile_in(&storage.directory)
        .map_err(|error| {
            CommandError::io(
                "workspace_state_write_failed",
                "Unable to create temporary workspace state",
                error,
            )
        })?;
    set_private_file_permissions(temporary.path())?;
    temporary
        .as_file_mut()
        .write_all(&encoded)
        .map_err(|error| {
            CommandError::io(
                "workspace_state_write_failed",
                "Unable to write workspace state",
                error,
            )
        })?;
    temporary.as_file_mut().sync_all().map_err(|error| {
        CommandError::io(
            "workspace_state_write_failed",
            "Unable to flush workspace state",
            error,
        )
    })?;
    temporary.persist(&storage.state_file).map_err(|error| {
        CommandError::io(
            "workspace_state_write_failed",
            "Unable to atomically replace workspace state",
            error.error,
        )
    })?;
    sync_directory(&storage.directory)?;
    Ok(())
}

fn validate_storage_directory(storage: &StoragePaths) -> CommandResult<()> {
    let metadata = fs::symlink_metadata(&storage.directory).map_err(|error| {
        CommandError::io(
            "workspace_storage_unavailable",
            "Unable to inspect workspace storage",
            error,
        )
    })?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(CommandError::new(
            "workspace_state_unsafe",
            "Workspace storage must be a real directory.",
        ));
    }
    Ok(())
}

fn validate_snapshot_json(state: &WorkspaceStateSnapshot) -> Result<(), ()> {
    validate_snapshot(state).map_err(|_| ())
}

pub(super) fn validate_snapshot(state: &WorkspaceStateSnapshot) -> CommandResult<()> {
    if state.schema_version != SCHEMA_VERSION {
        return Err(CommandError::new(
            "workspace_state_invalid",
            "Workspace state has an unsupported schema version.",
        ));
    }
    validate_preferences(&state.preferences)?;
    if state.recent_repositories.len() > MAX_RECENT_REPOSITORIES {
        return Err(CommandError::new(
            "workspace_state_invalid",
            "Workspace state has too many recent repositories.",
        ));
    }
    for repository in &state.recent_repositories {
        validate_string(&repository.path, MAX_PATH_BYTES, "repository path")?;
        validate_string(
            &repository.display_name,
            MAX_DISPLAY_NAME_BYTES,
            "repository display name",
        )?;
    }
    if let Some(path) = &state.last_repository_path {
        validate_string(path, MAX_PATH_BYTES, "last repository path")?;
    }
    if let Some(path) = &state.last_document_path {
        validate_relative_path(path)?;
    }
    if let Some(draft) = &state.recovery_draft {
        parse_recovery_id(&draft.recovery_id)?;
        validate_string(
            &draft.repository_path,
            MAX_PATH_BYTES,
            "draft repository path",
        )?;
        validate_relative_path(&draft.relative_path)?;
        validate_draft(&draft.text, &draft.baseline_sha256)?;
    }
    if let Some(warning) = &state.warning {
        validate_string(warning, MAX_WARNING_BYTES, "workspace warning")?;
    }
    Ok(())
}

fn validate_preferences(preferences: &WorkspacePreferences) -> CommandResult<()> {
    if !matches!(
        preferences.ui_language.as_str(),
        "system" | "zh-CN" | "en-US"
    ) {
        return Err(CommandError::new(
            "invalid_workspace_preferences",
            "UI language must be system, zh-CN, or en-US.",
        ));
    }
    if !matches!(preferences.theme.as_str(), "system" | "light" | "dark") {
        return Err(CommandError::new(
            "invalid_workspace_preferences",
            "Theme must be system, light, or dark.",
        ));
    }
    if !(12..=28).contains(&preferences.editor_font_size) {
        return Err(CommandError::new(
            "invalid_workspace_preferences",
            "Editor font size must be between 12 and 28.",
        ));
    }
    if preferences.editor_line_spacing > 12 {
        return Err(CommandError::new(
            "invalid_workspace_preferences",
            "Editor line spacing must be between 0 and 12.",
        ));
    }
    if !(560..=1200).contains(&preferences.editor_body_width) {
        return Err(CommandError::new(
            "invalid_workspace_preferences",
            "Editor body width must be between 560 and 1200.",
        ));
    }
    if !matches!(
        preferences.writing_tool_density.as_str(),
        "basic" | "professional"
    ) {
        return Err(CommandError::new(
            "invalid_workspace_preferences",
            "Writing tool density must be basic or professional.",
        ));
    }
    if preferences.writing_toolbar_item_ids.len() > WRITING_TOOLBAR_ITEM_IDS.len() {
        return Err(CommandError::new(
            "invalid_workspace_preferences",
            "Writing toolbar contains too many items.",
        ));
    }
    let mut seen = HashSet::with_capacity(preferences.writing_toolbar_item_ids.len());
    for item_id in &preferences.writing_toolbar_item_ids {
        if !WRITING_TOOLBAR_ITEM_IDS.contains(&item_id.as_str()) || !seen.insert(item_id) {
            return Err(CommandError::new(
                "invalid_workspace_preferences",
                "Writing toolbar items must be known and unique.",
            ));
        }
    }
    Ok(())
}

fn validate_draft(text: &str, baseline_sha256: &str) -> CommandResult<()> {
    if text.contains('\r') || text.len() > MAX_DRAFT_BYTES {
        return Err(CommandError::new(
            "invalid_recovery_draft",
            "Recovery text must use LF line endings and be at most 4 MiB.",
        ));
    }
    if baseline_sha256.len() != 64 || !baseline_sha256.bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        return Err(CommandError::new(
            "invalid_recovery_baseline",
            "Recovery baseline must be a SHA-256 digest.",
        ));
    }
    Ok(())
}

fn validate_relative_path(value: &str) -> CommandResult<()> {
    validate_string(value, MAX_PATH_BYTES, "document path")?;
    if Path::new(value).is_absolute()
        || value.contains('\\')
        || value.split('/').any(|part| part == "." || part == "..")
    {
        return Err(CommandError::new(
            "workspace_state_invalid",
            "Document path must be a portable relative path.",
        ));
    }
    Ok(())
}

fn validate_string(value: &str, maximum: usize, label: &str) -> CommandResult<()> {
    if value.is_empty() || value.contains('\0') || value.len() > maximum {
        return Err(CommandError::new(
            "workspace_state_invalid",
            format!("{label} is missing or exceeds the safety limit."),
        ));
    }
    Ok(())
}

fn parse_recovery_id(recovery_id: &str) -> CommandResult<()> {
    Uuid::parse_str(recovery_id)
        .map(|_| ())
        .map_err(|_| CommandError::new("invalid_recovery_id", "Recovery identifier is invalid."))
}

fn path_to_string(path: &Path) -> CommandResult<String> {
    path.to_str().map(str::to_owned).ok_or_else(|| {
        CommandError::new(
            "workspace_state_invalid",
            "Workspace paths must be valid UTF-8.",
        )
    })
}

fn now_epoch_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(unix)]
fn set_private_directory_permissions(path: &Path) -> CommandResult<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(|error| {
        CommandError::io(
            "workspace_storage_unavailable",
            "Unable to secure workspace storage",
            error,
        )
    })
}

#[cfg(not(unix))]
fn set_private_directory_permissions(_path: &Path) -> CommandResult<()> {
    Ok(())
}

#[cfg(unix)]
fn set_private_file_permissions(path: &Path) -> CommandResult<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(|error| {
        CommandError::io(
            "workspace_state_write_failed",
            "Unable to secure workspace state",
            error,
        )
    })
}

#[cfg(not(unix))]
fn set_private_file_permissions(_path: &Path) -> CommandResult<()> {
    Ok(())
}

#[cfg(unix)]
fn sync_directory(path: &Path) -> CommandResult<()> {
    OpenOptions::new()
        .read(true)
        .open(path)
        .and_then(|file| file.sync_all())
        .map_err(|error| {
            CommandError::io(
                "workspace_state_write_failed",
                "Unable to flush workspace storage",
                error,
            )
        })
}

#[cfg(not(unix))]
fn sync_directory(_path: &Path) -> CommandResult<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> (tempfile::TempDir, WorkspaceStateStore) {
        let directory = tempfile::tempdir().unwrap();
        let store = WorkspaceStateStore::new(directory.path().to_path_buf()).unwrap();
        (directory, store)
    }

    #[test]
    fn defaults_and_validates_preferences() {
        let (_directory, store) = store();
        assert_eq!(
            store.snapshot().unwrap().preferences,
            WorkspacePreferences::default()
        );
        let error = store
            .update_preferences(WorkspacePreferences {
                theme: "blue".into(),
                ..WorkspacePreferences::default()
            })
            .unwrap_err();
        assert_eq!(error.code, "invalid_workspace_preferences");

        for preferences in [
            WorkspacePreferences {
                ui_language: "fr".into(),
                ..WorkspacePreferences::default()
            },
            WorkspacePreferences {
                editor_line_spacing: 13,
                ..WorkspacePreferences::default()
            },
            WorkspacePreferences {
                editor_body_width: 559,
                ..WorkspacePreferences::default()
            },
            WorkspacePreferences {
                writing_tool_density: "compact".into(),
                ..WorkspacePreferences::default()
            },
            WorkspacePreferences {
                writing_toolbar_item_ids: vec!["unknown".into()],
                ..WorkspacePreferences::default()
            },
            WorkspacePreferences {
                writing_toolbar_item_ids: vec!["bold".into(), "bold".into()],
                ..WorkspacePreferences::default()
            },
            WorkspacePreferences {
                writing_toolbar_item_ids: vec!["bold".into(); WRITING_TOOLBAR_ITEM_IDS.len() + 1],
                ..WorkspacePreferences::default()
            },
        ] {
            assert_eq!(
                store.update_preferences(preferences).unwrap_err().code,
                "invalid_workspace_preferences"
            );
        }
        assert!(store
            .update_preferences(WorkspacePreferences {
                writing_toolbar_item_ids: Vec::new(),
                ..WorkspacePreferences::default()
            })
            .is_ok());
    }

    #[test]
    fn ui_language_preferences_round_trip_without_changing_other_preferences() {
        let (directory, store) = store();
        for language in ["system", "zh-CN", "en-US"] {
            let preferences = WorkspacePreferences {
                ui_language: language.into(),
                editor_font_size: 21,
                recovery_enabled: false,
                ..WorkspacePreferences::default()
            };
            store.update_preferences(preferences.clone()).unwrap();
            let reloaded = WorkspaceStateStore::new(directory.path().to_path_buf()).unwrap();
            assert_eq!(reloaded.snapshot().unwrap().preferences, preferences);
            let json = serde_json::to_value(preferences).unwrap();
            assert_eq!(json["uiLanguage"], language);
        }
    }

    #[test]
    fn older_workspace_state_preferences_receive_comfort_defaults() {
        let old_state = serde_json::json!({
            "schemaVersion": 1,
            "preferences": {
                "theme": "dark",
                "editorFontSize": 16,
                "restoreLastWorkspace": false,
                "recoveryEnabled": true
            },
            "recentRepositories": [],
            "lastRepositoryPath": null,
            "lastDocumentPath": null,
            "recoveryDraft": null,
            "warning": null
        });
        let directory = tempfile::tempdir().unwrap();
        let state_directory = directory.path().join("workspace");
        fs::create_dir(&state_directory).unwrap();
        fs::write(state_directory.join(STATE_FILE), old_state.to_string()).unwrap();
        let state = WorkspaceStateStore::new(directory.path().to_path_buf())
            .unwrap()
            .snapshot()
            .unwrap();

        assert_eq!(state.preferences.theme, "dark");
        assert_eq!(state.preferences.ui_language, "zh-CN");
        assert_eq!(state.preferences.editor_font_size, 16);
        assert_eq!(state.preferences.editor_line_spacing, 4);
        assert_eq!(state.preferences.editor_body_width, 820);
        assert!(!state.preferences.spell_check_enabled);
        assert!(!state.preferences.typewriter_mode_enabled);
        assert!(state.preferences.current_paragraph_highlight_enabled);
        assert!(!state.preferences.warm_paper_background_enabled);
        assert!(state.preferences.automatic_pairing_enabled);
        assert!(!state.preferences.paragraph_spotlight_enabled);
        assert_eq!(state.preferences.writing_tool_density, "basic");
        assert_eq!(
            state.preferences.writing_toolbar_item_ids,
            default_writing_toolbar_item_ids()
        );
        validate_snapshot(&state).unwrap();
    }

    #[test]
    fn orders_and_bounds_recent_repositories_and_reloads_atomically() {
        let (directory, store) = store();
        for number in 0..12 {
            let path = directory.path().join(format!("repo-{number}"));
            store
                .record_repository_opened(&path, &format!("Repo {number}"))
                .unwrap();
        }
        let state = store.snapshot().unwrap();
        assert_eq!(state.recent_repositories.len(), 10);
        assert!(state.recent_repositories[0].path.ends_with("repo-11"));
        drop(store);
        let reloaded = WorkspaceStateStore::new(directory.path().to_path_buf()).unwrap();
        assert_eq!(reloaded.snapshot().unwrap().recent_repositories.len(), 10);
    }

    #[cfg(unix)]
    #[test]
    fn persisted_state_uses_private_unix_permissions() {
        use std::os::unix::fs::PermissionsExt;

        let (directory, store) = store();
        store
            .update_preferences(WorkspacePreferences::default())
            .unwrap();
        let workspace = directory.path().join("workspace");
        assert_eq!(
            fs::metadata(&workspace).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(workspace.join(STATE_FILE))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }

    #[test]
    fn corrupt_state_is_ignored_without_overwrite_until_mutation() {
        let directory = tempfile::tempdir().unwrap();
        let state_dir = directory.path().join("workspace");
        fs::create_dir(&state_dir).unwrap();
        fs::write(state_dir.join(STATE_FILE), b"not json").unwrap();
        let store = WorkspaceStateStore::new(directory.path().to_path_buf()).unwrap();
        assert!(store.snapshot().unwrap().warning.is_some());
        store
            .update_preferences(WorkspacePreferences::default())
            .unwrap();
        assert!(store.snapshot().unwrap().warning.is_none());
    }

    #[test]
    fn rejects_oversized_state_and_symlink() {
        let directory = tempfile::tempdir().unwrap();
        let state_dir = directory.path().join("workspace");
        fs::create_dir(&state_dir).unwrap();
        let state_file = state_dir.join(STATE_FILE);
        fs::write(&state_file, vec![0; (MAX_STATE_BYTES + 1) as usize]).unwrap();
        assert_eq!(
            WorkspaceStateStore::new(directory.path().to_path_buf())
                .unwrap_err()
                .code,
            "workspace_state_too_large"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;
            fs::remove_file(&state_file).unwrap();
            symlink("/dev/null", &state_file).unwrap();
            assert_eq!(
                WorkspaceStateStore::new(directory.path().to_path_buf())
                    .unwrap_err()
                    .code,
                "workspace_state_unsafe"
            );
        }
    }

    #[test]
    fn recovery_rejects_bad_text_and_stale_clear_cannot_remove_newer_draft() {
        let (_directory, store) = store();
        let root = Path::new("/tmp/repository");
        let baseline = "a".repeat(64);
        assert_eq!(
            store
                .save_recovery_draft(root, "a.md", "line\r\n", &baseline)
                .unwrap_err()
                .code,
            "invalid_recovery_draft"
        );
        let first = store
            .save_recovery_draft(root, "a.md", "one\n", &baseline)
            .unwrap()
            .recovery_draft
            .unwrap();
        let second = store
            .save_recovery_draft(root, "a.md", "two\n", &baseline)
            .unwrap()
            .recovery_draft
            .unwrap();
        assert_ne!(first.recovery_id, second.recovery_id);
        let state = store.clear_recovery_draft(&first.recovery_id).unwrap();
        assert_eq!(
            state.recovery_draft.unwrap().recovery_id,
            second.recovery_id
        );
        assert!(store
            .clear_matching_recovery(root, "a.md", &baseline)
            .unwrap()
            .recovery_draft
            .is_none());
    }
}
