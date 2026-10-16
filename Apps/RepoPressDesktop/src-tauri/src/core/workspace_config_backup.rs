//! Explicit, structurally validated JSON configuration slice; never a full workspace backup.
use super::{rollback_archive::Destination, workspace_backup, CommandError, CommandResult};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeSet, HashMap};
use std::fs::{self, File};
use std::io::Read;
use std::path::{Component, Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

const TTL: Duration = Duration::from_secs(300);
const MAX_PLANS: usize = 8;
const MAX_BYTES: usize = 8 * 1024 * 1024;
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
const EXCLUDED_SOURCES: [&str; 4] = ["knowledge", "rss", "generalDrafts", "draftHistory"];

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ConfigBackupSource {
    Workspace,
    SiteProfiles,
    AiProfiles,
}
impl ConfigBackupSource {
    fn location(self) -> (&'static str, &'static str, usize) {
        match self {
            Self::Workspace => ("workspace", "workspace-state.json", 5 * 1024 * 1024),
            Self::SiteProfiles => ("site-profiles", "registry.json", 256 * 1024),
            Self::AiProfiles => ("ai-provider-profiles-v1", "profiles.json", 128 * 1024),
        }
    }
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfigBackupSummary {
    pub source: ConfigBackupSource,
    pub source_byte_size: usize,
    pub item_count: usize,
    pub recovery_draft_count: u8,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceConfigBackupPlan {
    pub plan_id: String,
    pub scope: &'static str,
    pub format: &'static str,
    pub schema_version: u8,
    pub destination_path: String,
    pub selected_sources: Vec<ConfigBackupSource>,
    pub sources: Vec<ConfigBackupSummary>,
    pub excluded_sources: Vec<&'static str>,
    pub exclusions: Vec<&'static str>,
    pub structure_verified: bool,
    pub consistent_snapshot: bool,
    pub includes_credentials: bool,
    pub byte_size: usize,
    pub sha256: String,
    pub created_at_epoch_ms: u64,
    pub expires_at_epoch_ms: u64,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceConfigBackupResult {
    pub plan_id: String,
    pub destination_path: String,
    pub selected_sources: Vec<ConfigBackupSource>,
    pub byte_size: usize,
    pub sha256: String,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Configuration {
    source: ConfigBackupSource,
    schema_version: u8,
    data_sha256: String,
    data: Value,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Archive {
    format: &'static str,
    schema_version: u8,
    captured_at_epoch_ms: u64,
    selected_sources: Vec<ConfigBackupSource>,
    excluded_sources: Vec<&'static str>,
    exclusions: Vec<&'static str>,
    includes_credentials: bool,
    consistent_snapshot: bool,
    configurations: Vec<Configuration>,
}
#[derive(Clone, Eq, PartialEq)]
struct Signature([u64; 11]);
fn signature(m: &fs::Metadata) -> Signature {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Signature([
            m.dev(),
            m.ino(),
            m.mode().into(),
            m.uid().into(),
            m.gid().into(),
            m.nlink(),
            m.len(),
            m.mtime() as u64,
            m.mtime_nsec() as u64,
            m.ctime() as u64,
            m.ctime_nsec() as u64,
        ])
    }
    #[cfg(not(unix))]
    {
        let _ = m;
        Signature([0; 11])
    }
}
fn private(m: &fs::Metadata, directory: bool) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        m.uid() == unsafe { libc::geteuid() }
            && m.mode() & 0o777 == if directory { 0o700 } else { 0o600 }
            && if directory {
                m.is_dir()
            } else {
                m.is_file() && m.nlink() == 1
            }
    }
    #[cfg(not(unix))]
    {
        let _ = (m, directory);
        false
    }
}
struct Root {
    path: PathBuf,
    handle: File,
    identity: [u64; 4],
}
fn identity(file: &File) -> CommandResult<[u64; 4]> {
    let s = signature(&file.metadata().map_err(|_| invalid())?).0;
    Ok([s[0], s[1], s[2], s[3]])
}
struct CapturedSource {
    source: ConfigBackupSource,
    directory: Signature,
    file: Signature,
    bytes: Vec<u8>,
    data: Value,
    summary: ConfigBackupSummary,
}
struct Binding {
    preview: WorkspaceConfigBackupPlan,
    sources: Vec<CapturedSource>,
    destination: Destination,
    bytes: Vec<u8>,
    created: Instant,
}
#[derive(Default)]
pub struct WorkspaceConfigBackupStore {
    root: Option<Root>,
    plans: Mutex<HashMap<String, Binding>>,
}
fn invalid() -> CommandError {
    CommandError::new("workspace_config_backup_invalid", "Configuration source, preview or destination is missing, unsafe, invalid, expired or changed. No existing file will be overwritten. Select the saved configuration scope and review a new destination.")
}
fn failed() -> CommandError {
    CommandError::new("workspace_config_backup_unconfirmed", "Configuration export could not be confirmed. A private file may already exist at the selected destination; inspect it before choosing a new filename. Source configuration was not modified.")
}
fn time() -> CommandResult<u64> {
    let ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| invalid())?
        .as_millis();
    if ms == 0 || ms > 8_639_999_999_700_000 {
        return Err(invalid());
    }
    Ok(ms as u64)
}
fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

impl WorkspaceConfigBackupStore {
    pub fn new(path: PathBuf) -> Self {
        let root = workspace_backup::root_handle(&path)
            .ok()
            .and_then(|handle| {
                identity(&handle).ok().map(|identity| Root {
                    path,
                    handle,
                    identity,
                })
            });
        Self {
            root,
            plans: Mutex::new(HashMap::new()),
        }
    }
    fn root(&self) -> CommandResult<&Root> {
        let root = self.root.as_ref().ok_or_else(invalid)?;
        if identity(&workspace_backup::root_handle(&root.path).map_err(|_| invalid())?)?
            != root.identity
        {
            return Err(invalid());
        }
        Ok(root)
    }
    pub fn plan(
        &self,
        mut selected: Vec<ConfigBackupSource>,
        destination_path: &Path,
    ) -> CommandResult<WorkspaceConfigBackupPlan> {
        if selected.is_empty()
            || selected.len() > 3
            || selected.iter().copied().collect::<BTreeSet<_>>().len() != selected.len()
        {
            return Err(invalid());
        }
        selected.sort();
        let root = self.root()?;
        reject_git_ancestors(destination_path.parent().ok_or_else(invalid)?)?;
        let destination = Destination::new(destination_path, &root.path).map_err(|_| invalid())?;
        let mut sources = Vec::new();
        for source in &selected {
            sources.push(read_source(root, *source)?);
        }
        self.verify_sources(&sources)?;
        let created_at_epoch_ms = time()?;
        let configurations = sources
            .iter()
            .map(|s| {
                let data = serde_json::to_vec(&s.data).map_err(|_| invalid())?;
                Ok(Configuration {
                    source: s.source,
                    schema_version: 1,
                    data_sha256: hash(&data),
                    data: s.data.clone(),
                })
            })
            .collect::<CommandResult<Vec<_>>>()?;
        let bytes = serde_json::to_vec(&Archive {
            format: "repopress-workspace-config",
            schema_version: 1,
            captured_at_epoch_ms: created_at_epoch_ms,
            selected_sources: selected.clone(),
            excluded_sources: EXCLUDED_SOURCES.to_vec(),
            exclusions: EXCLUSIONS.to_vec(),
            includes_credentials: false,
            consistent_snapshot: false,
            configurations,
        })
        .map_err(|_| invalid())?;
        if bytes.len() > MAX_BYTES {
            return Err(invalid());
        }
        let preview = WorkspaceConfigBackupPlan {
            plan_id: Uuid::new_v4().to_string(),
            scope: "applicationPrivateConfiguration",
            format: "repopress-workspace-config",
            schema_version: 1,
            destination_path: destination_path.to_str().ok_or_else(invalid)?.into(),
            selected_sources: selected,
            sources: sources.iter().map(|s| s.summary.clone()).collect(),
            excluded_sources: EXCLUDED_SOURCES.to_vec(),
            exclusions: EXCLUSIONS.to_vec(),
            structure_verified: true,
            consistent_snapshot: false,
            includes_credentials: false,
            byte_size: bytes.len(),
            sha256: hash(&bytes),
            created_at_epoch_ms,
            expires_at_epoch_ms: created_at_epoch_ms + 300_000,
        };
        let mut plans = self.plans.lock().map_err(|_| invalid())?;
        plans.retain(|_, b| b.created.elapsed() < TTL);
        if plans.len() >= MAX_PLANS {
            return Err(invalid());
        }
        plans.insert(
            preview.plan_id.clone(),
            Binding {
                preview: preview.clone(),
                sources,
                destination,
                bytes,
                created: Instant::now(),
            },
        );
        Ok(preview)
    }
    pub fn discard(&self, id: &str) -> CommandResult<()> {
        self.plans.lock().map_err(|_| invalid())?.remove(id);
        Ok(())
    }
    pub fn execute(
        &self,
        id: &str,
        confirm_sensitive_plaintext: bool,
    ) -> CommandResult<WorkspaceConfigBackupResult> {
        self.execute_checked(id, confirm_sensitive_plaintext, |_| {})
    }
    fn execute_checked(
        &self,
        id: &str,
        confirm_sensitive_plaintext: bool,
        mut after_check: impl FnMut(bool),
    ) -> CommandResult<WorkspaceConfigBackupResult> {
        // Burn before consent, expiry, source or destination checks. Never auto retry.
        let binding = self
            .plans
            .lock()
            .map_err(|_| invalid())?
            .remove(id)
            .ok_or_else(invalid)?;
        if !confirm_sensitive_plaintext
            || binding.created.elapsed() >= TTL
            || time()? >= binding.preview.expires_at_epoch_ms
        {
            return Err(invalid());
        }
        let check = || {
            if binding.created.elapsed() >= TTL || time()? >= binding.preview.expires_at_epoch_ms {
                return Err(invalid());
            }
            self.verify_sources(&binding.sources)?;
            reject_git_ancestors(
                Path::new(&binding.preview.destination_path)
                    .parent()
                    .ok_or_else(invalid)?,
            )
        };
        check()?;
        after_check(false);
        binding
            .destination
            .write(&binding.bytes, &mut || {
                check()?;
                after_check(false);
                Ok(())
            })
            .map_err(|_| failed())?;
        after_check(true);
        check().map_err(|_| failed())?;
        Ok(WorkspaceConfigBackupResult {
            plan_id: binding.preview.plan_id,
            destination_path: binding.preview.destination_path,
            selected_sources: binding.preview.selected_sources,
            byte_size: binding.preview.byte_size,
            sha256: binding.preview.sha256,
        })
    }
    fn verify_sources(&self, sources: &[CapturedSource]) -> CommandResult<()> {
        let root = self.root()?;
        for expected in sources {
            let actual = read_source(root, expected.source)?;
            if expected.directory != actual.directory
                || expected.file != actual.file
                || expected.bytes != actual.bytes
            {
                return Err(invalid());
            }
        }
        self.root()?;
        Ok(())
    }
}

pub(super) fn reject_git_ancestors(parent: &Path) -> CommandResult<()> {
    if !parent.is_absolute()
        || parent
            .components()
            .any(|c| matches!(c, Component::CurDir | Component::ParentDir))
    {
        return Err(invalid());
    }
    let mut directory = File::open("/").map_err(|_| invalid())?;
    for part in std::iter::once(None).chain(parent.components().filter_map(|c| match c {
        Component::Normal(s) => Some(Some(s)),
        _ => None,
    })) {
        if let Some(part) = part {
            directory =
                workspace_backup::walk(&directory, Path::new(part), true).map_err(|_| invalid())?;
        }
        let exists = |name: &str| -> CommandResult<bool> {
            match workspace_backup::walk(&directory, Path::new(name), false) {
                Ok(_) => Ok(true),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
                Err(_) => Err(invalid()),
            }
        };
        let git_metadata = match workspace_backup::walk(&directory, Path::new(".git"), false) {
            Ok(git) => {
                if !git.metadata().map_err(|_| invalid())?.is_dir() {
                    return Err(invalid());
                }
                // An empty .git directory (including sandbox metadata sentinels) is
                // not an initialized repository. Never read gitdir pointer contents.
                let marker = |name: &str| -> CommandResult<bool> {
                    match workspace_backup::walk(&git, Path::new(name), false) {
                        Ok(_) => Ok(true),
                        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
                        Err(_) => Err(invalid()),
                    }
                };
                marker("HEAD")? || marker("config")? || marker("commondir")?
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => false,
            Err(_) => return Err(invalid()),
        };
        if git_metadata || exists("HEAD")? && exists("objects")? && exists("config")? {
            return Err(invalid());
        }
    }
    Ok(())
}
fn open_content(parent: &File, name: &str) -> CommandResult<File> {
    #[cfg(target_os = "linux")]
    {
        use std::ffi::CString;
        use std::os::fd::{AsRawFd, FromRawFd};
        let name = CString::new(name).map_err(|_| invalid())?;
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return Err(invalid());
        }
        Ok(unsafe { File::from_raw_fd(fd) })
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (parent, name);
        Err(invalid())
    }
}
fn read_source(root: &Root, source: ConfigBackupSource) -> CommandResult<CapturedSource> {
    let (folder, name, max) = source.location();
    let directory =
        workspace_backup::walk(&root.handle, Path::new(folder), true).map_err(|_| invalid())?;
    let dm = directory.metadata().map_err(|_| invalid())?;
    if !private(&dm, true) {
        return Err(invalid());
    }
    let dm = signature(&dm);
    let metadata = workspace_backup::walk(&directory, Path::new(name), false)
        .and_then(|f| f.metadata())
        .map_err(|_| invalid())?;
    if !private(&metadata, false) || metadata.len() == 0 || metadata.len() > max as u64 {
        return Err(invalid());
    }
    let expected = signature(&metadata);
    let mut file = open_content(&directory, name)?;
    if signature(&file.metadata().map_err(|_| invalid())?) != expected {
        return Err(invalid());
    }
    let mut bytes = Vec::new();
    file.by_ref()
        .take((max + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| invalid())?;
    if bytes.len() as u64 != metadata.len()
        || bytes.len() > max
        || signature(&file.metadata().map_err(|_| invalid())?) != expected
    {
        return Err(invalid());
    }
    let current_directory = workspace_backup::walk(&root.handle, Path::new(folder), true)
        .and_then(|f| f.metadata())
        .map_err(|_| invalid())?;
    let current_file = workspace_backup::walk(&directory, Path::new(name), false)
        .and_then(|f| f.metadata())
        .map_err(|_| invalid())?;
    if signature(&current_directory) != dm || signature(&current_file) != expected {
        return Err(invalid());
    }
    let data: Value = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
    let (item_count, recovery_draft_count) = validate_json(source, &bytes, &data)?;
    Ok(CapturedSource {
        source,
        directory: dm,
        file: expected,
        summary: ConfigBackupSummary {
            source,
            source_byte_size: bytes.len(),
            item_count,
            recovery_draft_count,
        },
        bytes,
        data,
    })
}
fn keys(value: &Value, allowed: &[&str]) -> CommandResult<()> {
    if !value
        .as_object()
        .is_some_and(|map| map.keys().all(|key| allowed.contains(&key.as_str())))
    {
        return Err(invalid());
    }
    Ok(())
}
fn validate_json(
    source: ConfigBackupSource,
    bytes: &[u8],
    data: &Value,
) -> CommandResult<(usize, u8)> {
    match source {
        ConfigBackupSource::Workspace => {
            keys(
                data,
                &[
                    "schemaVersion",
                    "preferences",
                    "recentRepositories",
                    "lastRepositoryPath",
                    "lastDocumentPath",
                    "recoveryDraft",
                    "warning",
                ],
            )?;
            keys(
                &data["preferences"],
                &[
                    "theme",
                    "uiLanguage",
                    "editorFontSize",
                    "editorLineSpacing",
                    "editorBodyWidth",
                    "spellCheckEnabled",
                    "typewriterModeEnabled",
                    "currentParagraphHighlightEnabled",
                    "warmPaperBackgroundEnabled",
                    "automaticPairingEnabled",
                    "paragraphSpotlightEnabled",
                    "writingToolDensity",
                    "writingToolbarItemIds",
                    "restoreLastWorkspace",
                    "recoveryEnabled",
                ],
            )?;
            if let Some(recent) = data["recentRepositories"].as_array() {
                for item in recent {
                    keys(item, &["path", "displayName", "lastOpenedAtEpochSeconds"])?;
                }
            }
            if !data["recoveryDraft"].is_null() {
                keys(
                    &data["recoveryDraft"],
                    &[
                        "recoveryId",
                        "repositoryPath",
                        "relativePath",
                        "text",
                        "baselineSha256",
                        "savedAtEpochSeconds",
                    ],
                )?;
            }
            // Typed deserialization also rejects duplicate recognized fields. Unknown fields
            // above are stricter than the tolerant application startup loader.
            let state: super::workspace_state::WorkspaceStateSnapshot =
                serde_json::from_slice(bytes).map_err(|_| invalid())?;
            super::workspace_state::validate_snapshot(&state).map_err(|_| invalid())?;
            if state.warning.is_some() {
                return Err(invalid());
            }
            Ok((1, u8::from(state.recovery_draft.is_some())))
        }
        ConfigBackupSource::SiteProfiles => Ok((
            super::site_profiles::validate_backup_json(bytes).map_err(|_| invalid())?,
            0,
        )),
        ConfigBackupSource::AiProfiles => Ok((
            super::ai_provider_profiles::validate_backup_json(bytes).map_err(|_| invalid())?,
            0,
        )),
    }
}

#[cfg(test)]
#[path = "workspace_config_backup_tests.rs"]
mod tests;
