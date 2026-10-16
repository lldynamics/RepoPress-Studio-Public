//! A small, local-only library for material a user deliberately imports.
//!
//! This module intentionally does not discover files or fetch URLs.  The
//! caller supplies already acquired UTF-8 text, and the store keeps it under
//! the application's private data directory.  Keeping the boundary this
//! narrow makes the library useful without giving it ambient filesystem or
//! network authority.

#[path = "knowledge_integrity_manifest.rs"]
pub(super) mod knowledge_integrity_manifest;

use super::browser_capture::BrowserCaptureArchive;
use super::knowledge_restore_gate::KnowledgeRootLease;
use super::semantic_index::{
    normalized_embedding, semantic_features, SEMANTIC_ENCODING_VERSION, SEMANTIC_MODEL_ID,
};
use super::{CommandError, CommandResult};
use serde::{Deserialize, Deserializer, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::ops::{Deref, DerefMut};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};
use tempfile::NamedTempFile;
use url::Url;
use uuid::Uuid;

const SCHEMA_VERSION: u32 = 4;
const MAX_ITEM_BYTES: usize = 5 * 1024 * 1024;
const MAX_LIBRARY_BYTES: u64 = 64 * 1024 * 1024;
const MAX_ITEMS: usize = 2_000;
const MAX_TITLE_BYTES: usize = 512;
const MAX_SOURCE_NAME_BYTES: usize = 1_024;
const MAX_URL_BYTES: usize = 2_048;
const MAX_QUERY_BYTES: usize = 1_024;
const MAX_RELATIVE_PATH_BYTES: usize = 1_024;
const MAX_SEARCH_LIMIT: usize = 100;
const MAX_SNIPPET_CHARS: usize = 280;
const MAX_FEATURE_TEXT_BYTES: usize = 64 * 1024;
const EXPORT_TTL_SECONDS: u64 = 5 * 60;
const MAX_EXPORT_PLANS: usize = 128;
const MAX_ARCHIVE_BYTES: usize = 24 * 1024 * 1024;
const MAX_ARCHIVE_LIBRARY_BYTES: u64 = 512 * 1024 * 1024;
const MAX_FOLDERS: usize = 128;
const MAX_FOLDER_NAME_BYTES: usize = 128;
const MAX_REVISIONS_PER_ITEM: usize = 32;
const MAX_COMPLETED_OPERATIONS: usize = 256;
const COMPLETED_OPERATION_TTL_SECONDS: u64 = 30 * 24 * 60 * 60;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum KnowledgeSourceKind {
    Web,
    Pdf,
    Text,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeImportRequest {
    pub source_kind: KnowledgeSourceKind,
    pub title: String,
    pub source_name: String,
    pub source_url: Option<String>,
    pub text: String,
    pub allows_local_semantic_index: bool,
    /// Remote AI use is opt-in per item. Older callers and manifests remain local-only.
    #[serde(default)]
    pub allows_remote_ai_use: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeItemSummary {
    pub item_id: String,
    pub title: String,
    pub source_kind: KnowledgeSourceKind,
    pub source_name: String,
    pub source_url: Option<String>,
    pub byte_size: u64,
    pub created_at_epoch_seconds: u64,
    pub updated_at_epoch_seconds: u64,
    pub reading_progress_percent: u8,
    pub allows_local_semantic_index: bool,
    /// Whether this item's body may be sent to a remote AI service.
    #[serde(default)]
    pub allows_remote_ai_use: bool,
    /// `None` is the deliberately supported "Uncategorized" folder.
    #[serde(default)]
    pub folder_id: Option<String>,
    #[serde(default = "default_revision_number")]
    pub revision_number: u32,
    #[serde(default = "default_revision_number")]
    pub revision_count: u32,
    #[serde(default)]
    pub archive: Option<KnowledgeArchiveMetadata>,
}

fn default_revision_number() -> u32 {
    1
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeFolder {
    pub folder_id: String,
    pub name: String,
    pub created_at_epoch_seconds: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeRevisionSummary {
    pub revision_number: u32,
    pub content_sha256: String,
    pub byte_size: u64,
    pub created_at_epoch_seconds: u64,
    #[serde(default)]
    pub archive: Option<KnowledgeArchiveMetadata>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeRevision {
    #[serde(flatten)]
    pub summary: KnowledgeRevisionSummary,
    pub text: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserKnowledgeImportRequest {
    pub operation_id: String,
    pub source_url: String,
    pub title: String,
    pub source_name: String,
    pub text: String,
    pub allows_local_semantic_index: bool,
    /// Explicit browser choice; absence is local-only for backwards compatibility.
    #[serde(default)]
    pub allows_remote_ai_use: bool,
    #[serde(default)]
    pub folder_id: Option<String>,
    #[serde(default)]
    pub new_folder_name: Option<String>,
    #[serde(default)]
    pub duplicate_resolution: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct BrowserKnowledgeDuplicateConflict {
    pub document_id: String,
    pub title: String,
    pub folder_id: Option<String>,
    pub byte_size: u64,
    pub updated_at_epoch_seconds: u64,
    pub incoming_has_changes: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct BrowserKnowledgeImportReceipt {
    pub document_id: String,
    pub title: String,
    pub action: String,
    pub folder_id: Option<String>,
    pub file_size_bytes: u64,
    pub archive_type: String,
    pub allows_local_semantic_index: bool,
    /// The permission actually persisted by the storage operation.
    #[serde(default)]
    pub allows_remote_ai_use: bool,
    /// Stable completion timestamp retained in the ledger; adapters must not replace it on replay.
    #[serde(default)]
    pub saved_at_epoch_seconds: u64,
    pub replayed: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum BrowserKnowledgeImportOutcome {
    Imported {
        receipt: BrowserKnowledgeImportReceipt,
    },
    Conflict {
        conflict: BrowserKnowledgeDuplicateConflict,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeArchiveMetadata {
    pub format: String,
    pub byte_size: u64,
    pub embedded_resource_count: Option<u32>,
    pub missing_resource_count: Option<u32>,
    #[serde(default, deserialize_with = "deserialize_bool_or_default")]
    pub was_truncated: bool,
    pub sha256: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeItem {
    #[serde(flatten)]
    pub summary: KnowledgeItemSummary,
    pub text: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeImportResult {
    pub item: KnowledgeItem,
    pub deduplicated: bool,
    pub archive_attached: bool,
    pub summary: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeLibrarySnapshot {
    pub items: Vec<KnowledgeItemSummary>,
    pub total: usize,
    pub truncated: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeSearchResult {
    pub item: KnowledgeItemSummary,
    pub score: f32,
    pub lexical_score: f32,
    pub semantic_score: f32,
    pub snippet: String,
    pub reason: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeSearchSnapshot {
    pub query: String,
    pub model_id: String,
    pub encoding_version: u32,
    pub results: Vec<KnowledgeSearchResult>,
    pub truncated: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeLibraryStatus {
    pub ready: bool,
    pub persistent: bool,
    pub item_count: usize,
    pub total_bytes: u64,
    pub summary: String,
    pub warning: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeDeleteResult {
    pub item_id: String,
    pub deleted: bool,
    pub summary: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeExportPlan {
    pub plan_id: String,
    pub item_id: String,
    pub relative_path: String,
    pub title: String,
    pub content_sha256: String,
    pub expires_at_epoch_seconds: u64,
    pub summary: String,
    pub warnings: Vec<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeExportResult {
    pub item_id: String,
    pub relative_path: String,
    pub byte_size: u64,
    pub summary: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeArchiveExportPlan {
    pub plan_id: String,
    pub item_id: String,
    pub relative_path: String,
    pub format: String,
    pub archive_sha256: String,
    pub byte_size: u64,
    pub expires_at_epoch_seconds: u64,
    pub summary: String,
    pub warnings: Vec<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeArchiveExportResult {
    pub item_id: String,
    pub relative_path: String,
    pub byte_size: u64,
    pub format: String,
    pub summary: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct StoredItem {
    summary: KnowledgeItemSummary,
    content_sha256: String,
    #[serde(default)]
    revisions: Vec<KnowledgeRevisionSummary>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Manifest {
    schema_version: u32,
    #[serde(default)]
    items: Vec<StoredItem>,
    #[serde(default)]
    folders: Vec<KnowledgeFolder>,
    #[serde(default)]
    completed_operations: Vec<CompletedOperation>,
}

/// Only a digest of the request and a small completion receipt are retained.  In particular,
/// this ledger never serializes captured body or archive bytes.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct CompletedOperation {
    operation_id: String,
    fingerprint: String,
    completed_at_epoch_seconds: u64,
    receipt: BrowserKnowledgeImportReceipt,
}

type LoadedManifest = (
    BTreeMap<String, StoredItem>,
    BTreeMap<String, KnowledgeFolder>,
    BTreeMap<String, CompletedOperation>,
    bool,
);

#[derive(Clone, Debug)]
struct Storage {
    directory: PathBuf,
    blobs_directory: PathBuf,
    archives_directory: PathBuf,
    manifest_file: PathBuf,
    generation: Arc<Mutex<Option<String>>>,
    app_data_dir: PathBuf,
    root_anchor: Arc<File>,
}

#[derive(Clone, Debug)]
struct ExportPlanState {
    public: KnowledgeExportPlan,
    session_id: String,
    repository_root: PathBuf,
}

#[derive(Clone, Debug)]
struct ArchiveExportPlanState {
    public: KnowledgeArchiveExportPlan,
    session_id: String,
    repository_root: PathBuf,
}

#[derive(Clone, Debug, Default)]
struct LibraryState {
    items: BTreeMap<String, StoredItem>,
    folders: BTreeMap<String, KnowledgeFolder>,
    completed_operations: BTreeMap<String, CompletedOperation>,
    memory_blobs: BTreeMap<String, String>,
    export_plans: BTreeMap<String, ExportPlanState>,
    archive_export_plans: BTreeMap<String, ArchiveExportPlanState>,
    memory_archives: BTreeMap<String, Vec<u8>>,
    open_request: Option<String>,
}

/// Thread-safe local library.  `Default` is deliberately in-memory so unit
/// tests and previews cannot accidentally create user data on disk.
#[derive(Debug)]
pub struct KnowledgeLibraryStore {
    storage: Option<Storage>,
    state: Mutex<LibraryState>,
}

impl Default for KnowledgeLibraryStore {
    fn default() -> Self {
        Self {
            storage: None,
            state: Mutex::new(LibraryState::default()),
        }
    }
}

struct LibraryGuard<'a> {
    state: MutexGuard<'a, LibraryState>,
    _lease: Option<KnowledgeRootLease>,
}
impl Deref for LibraryGuard<'_> {
    type Target = LibraryState;
    fn deref(&self) -> &LibraryState {
        &self.state
    }
}
impl DerefMut for LibraryGuard<'_> {
    fn deref_mut(&mut self) -> &mut LibraryState {
        &mut self.state
    }
}
fn storage_context(storage: &Storage) -> CommandResult<String> {
    super::knowledge_restore_gate::verify_anchor(&storage.app_data_dir, &storage.root_anchor)?;
    let dir = super::workspace_backup::walk(&storage.root_anchor, Path::new("knowledge-v1"), true)
        .map_err(|_| super::knowledge_restore_gate::blocked())?;
    let mut ids = Vec::new();
    for file in [
        dir.try_clone()
            .map_err(|_| super::knowledge_restore_gate::blocked())?,
        super::workspace_backup::walk(&dir, Path::new("blobs"), true)
            .map_err(|_| super::knowledge_restore_gate::blocked())?,
        super::workspace_backup::walk(&dir, Path::new("archives"), true)
            .map_err(|_| super::knowledge_restore_gate::blocked())?,
    ] {
        let m = file
            .metadata()
            .map_err(|_| super::knowledge_restore_gate::blocked())?;
        if !m.is_dir() || m.mode() & 0o7777 != 0o700 || m.uid() != unsafe { libc::geteuid() } {
            return Err(super::knowledge_restore_gate::blocked());
        }
        ids.push(format!("{}:{}:{}:{}", m.dev(), m.ino(), m.mode(), m.uid()));
    }
    Ok(ids.join("/"))
}
fn storage_generation(storage: &Storage) -> CommandResult<String> {
    let context = storage_context(storage)?;
    let manifest = match fs::symlink_metadata(&storage.manifest_file) {
        Ok(m)
            if m.is_file()
                && m.nlink() == 1
                && m.mode() & 0o7777 == 0o600
                && m.uid() == unsafe { libc::geteuid() } =>
        {
            format!(
                "{}:{}:{}:{}:{}:{}:{}",
                m.dev(),
                m.ino(),
                m.len(),
                m.mtime(),
                m.mtime_nsec(),
                m.ctime(),
                m.ctime_nsec()
            )
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => "missing".into(),
        _ => return Err(super::knowledge_restore_gate::blocked()),
    };
    Ok(format!("{}:{}", context, manifest))
}
impl KnowledgeLibraryStore {
    fn checked_operation<T>(
        &self,
        operation: impl FnOnce() -> CommandResult<T>,
    ) -> CommandResult<T> {
        let before = self.storage.as_ref().map(storage_context).transpose()?;
        let result = operation();
        let after = self.storage.as_ref().map(storage_context).transpose()?;
        if before != after {
            return Err(super::knowledge_restore_gate::blocked());
        }
        result
    }
    pub fn new(app_data_dir: PathBuf) -> CommandResult<Self> {
        let lease = KnowledgeRootLease::acquire(&app_data_dir)?;
        let root_anchor = Arc::new(
            lease
                .file
                .try_clone()
                .map_err(|_| super::knowledge_restore_gate::blocked())?,
        );
        // Resolve all ordinary I/O under the held inode, even if the named app root moves.
        let directory = PathBuf::from(format!(
            "/proc/self/fd/{}/knowledge-v1",
            root_anchor.as_raw_fd()
        ));
        let blobs_directory = directory.join("blobs");
        let archives_directory = directory.join("archives");
        let storage = Storage {
            manifest_file: directory.join("manifest.json"),
            directory,
            blobs_directory,
            archives_directory,
            generation: Arc::new(Mutex::new(None)),
            app_data_dir,
            root_anchor,
        };
        if super::normal_library_access(&lease.file).is_err() {
            // Recovery remains available through its independent store. Never migrate/GC a pending tree.
            return Ok(Self {
                storage: Some(storage),
                state: Mutex::new(LibraryState::default()),
            });
        }
        ensure_private_directory(&storage.directory, "knowledge_storage_unavailable")?;
        ensure_private_directory(&storage.blobs_directory, "knowledge_storage_unavailable")?;
        ensure_private_directory(&storage.archives_directory, "knowledge_storage_unavailable")?;
        let (items, folders, completed_operations, needs_migration) = load_manifest(&storage)?;
        garbage_collect_unreferenced_blobs(&storage, &items)?;
        garbage_collect_unreferenced_archives(&storage, &items)?;
        let store = Self {
            storage: Some(storage),
            state: Mutex::new(LibraryState {
                items,
                folders,
                completed_operations,
                ..LibraryState::default()
            }),
        };
        if needs_migration {
            let state = store
                .state
                .lock()
                .map_err(|_| super::knowledge_restore_gate::blocked())?;
            store.persist(&state)?;
        }
        let storage = store.storage.as_ref().expect("persistent storage");
        *storage
            .generation
            .lock()
            .map_err(|_| super::knowledge_restore_gate::blocked())? =
            Some(storage_generation(storage)?);
        lease.verify()?;
        Ok(store)
    }

    pub fn status(&self) -> CommandResult<KnowledgeLibraryStatus> {
        self.checked_operation(|| {
        let state = self.lock()?;
        let cleanup_warning = self.storage.as_ref().and_then(|storage| {
            garbage_collect_unreferenced_blobs(storage, &state.items)
                .and_then(|_| garbage_collect_unreferenced_archives(storage, &state.items))
                .err()
                .map(|error| {
                    format!(
                        "Private knowledge cleanup is pending ({}). Restart after checking application-data permissions.",
                        error.code
                    )
                })
        });
        let bytes = total_unique_bytes(&state.items);
        Ok(KnowledgeLibraryStatus {
            ready: true,
            persistent: self.storage.is_some(),
            item_count: state.items.len(),
            total_bytes: bytes,
            summary: format!(
                "{} item(s), {} byte(s) of unique content.",
                state.items.len(),
                bytes
            ),
            warning: cleanup_warning,
        })

        })
    }

    pub fn list(&self, limit: usize) -> CommandResult<KnowledgeLibrarySnapshot> {
        self.checked_operation(|| {
            let state = self.lock()?;
            let mut items = state
                .items
                .values()
                .map(|item| item.summary.clone())
                .collect::<Vec<_>>();
            items.sort_by(|a, b| {
                b.updated_at_epoch_seconds
                    .cmp(&a.updated_at_epoch_seconds)
                    .then_with(|| a.item_id.cmp(&b.item_id))
            });
            let total = items.len();
            items.truncate(limit.min(MAX_ITEMS));
            Ok(KnowledgeLibrarySnapshot {
                truncated: total > items.len(),
                items,
                total,
            })
        })
    }

    pub fn list_folders(&self) -> CommandResult<Vec<KnowledgeFolder>> {
        self.checked_operation(|| {
            let state = self.lock()?;
            let mut folders = state.folders.values().cloned().collect::<Vec<_>>();
            folders.sort_by(|left, right| {
                folder_name_key(&left.name)
                    .cmp(&folder_name_key(&right.name))
                    .then_with(|| left.folder_id.cmp(&right.folder_id))
            });
            Ok(folders)
        })
    }

    pub fn create_folder(&self, name: &str) -> CommandResult<KnowledgeFolder> {
        self.checked_operation(|| {
            let name = validate_folder_name(name)?;
            let mut state = self.lock()?;
            if state.folders.len() >= MAX_FOLDERS {
                return Err(limit_error(
                    "knowledge_folder_limit",
                    "The knowledge library holds at most 128 folders.",
                ));
            }
            if state
                .folders
                .values()
                .any(|folder| folder_name_key(&folder.name) == folder_name_key(&name))
            {
                return Err(CommandError::new(
                    "knowledge_folder_conflict",
                    "A folder with this name already exists.",
                ));
            }
            let folder = KnowledgeFolder {
                folder_id: Uuid::new_v4().to_string(),
                name,
                created_at_epoch_seconds: now_epoch_seconds(),
            };
            let mut candidate = state.clone();
            candidate
                .folders
                .insert(folder.folder_id.clone(), folder.clone());
            self.persist(&candidate)?;
            *state = candidate;
            Ok(folder)
        })
    }

    pub fn move_item(
        &self,
        item_id: &str,
        folder_id: Option<&str>,
    ) -> CommandResult<KnowledgeItemSummary> {
        self.checked_operation(|| {
            validate_item_id(item_id)?;
            let folder_id = validate_optional_folder_id(folder_id)?;
            let mut state = self.lock()?;
            if let Some(folder_id) = &folder_id {
                if !state.folders.contains_key(folder_id) {
                    return Err(CommandError::new(
                        "knowledge_folder_not_found",
                        "Knowledge folder was not found.",
                    ));
                }
            }
            let mut candidate = state.clone();
            let item = candidate.items.get_mut(item_id).ok_or_else(not_found)?;
            item.summary.folder_id = folder_id;
            item.summary.updated_at_epoch_seconds = now_epoch_seconds();
            let summary = item.summary.clone();
            self.persist(&candidate)?;
            *state = candidate;
            Ok(summary)
        })
    }

    /// Atomically updates the explicit remote-AI permission without exposing the item's body.
    pub fn set_remote_ai_permission(
        &self,
        item_id: &str,
        allowed: bool,
    ) -> CommandResult<KnowledgeItemSummary> {
        self.checked_operation(|| {
            validate_item_id(item_id)?;
            let mut state = self.lock()?;
            let mut candidate = state.clone();
            let item = candidate.items.get_mut(item_id).ok_or_else(not_found)?;
            item.summary.allows_remote_ai_use = allowed;
            item.summary.updated_at_epoch_seconds = now_epoch_seconds();
            let summary = item.summary.clone();
            self.persist(&candidate)?;
            *state = candidate;
            Ok(summary)
        })
    }

    pub fn list_revisions(&self, item_id: &str) -> CommandResult<Vec<KnowledgeRevisionSummary>> {
        self.checked_operation(|| {
            validate_item_id(item_id)?;
            let state = self.lock()?;
            let item = state.items.get(item_id).ok_or_else(not_found)?;
            Ok(item.revisions.clone())
        })
    }

    pub fn get_revision(
        &self,
        item_id: &str,
        revision_number: u32,
    ) -> CommandResult<KnowledgeRevision> {
        self.checked_operation(|| {
            validate_item_id(item_id)?;
            let state = self.lock()?;
            let item = state.items.get(item_id).ok_or_else(not_found)?;
            let summary = item
                .revisions
                .iter()
                .find(|revision| revision.revision_number == revision_number)
                .cloned()
                .ok_or_else(|| {
                    CommandError::new(
                        "knowledge_revision_not_found",
                        "Knowledge revision was not found.",
                    )
                })?;
            let text = self.read_body(&state, &summary.content_sha256)?;
            Ok(KnowledgeRevision { summary, text })
        })
    }

    /// Queue a one-shot UI open request.  It is deliberately runtime-only and cannot survive a
    /// restart, avoiding an unexpected document opening later.
    pub fn request_open(&self, item_id: &str) -> CommandResult<()> {
        self.checked_operation(|| {
            validate_item_id(item_id)?;
            let mut state = self.lock()?;
            if !state.items.contains_key(item_id) {
                return Err(not_found());
            }
            state.open_request = Some(item_id.to_string());
            Ok(())
        })
    }

    pub fn take_open_request(&self) -> CommandResult<Option<String>> {
        self.checked_operation(|| Ok(self.lock()?.open_request.take()))
    }

    pub fn get(&self, item_id: &str) -> CommandResult<KnowledgeItem> {
        self.checked_operation(|| {
            validate_item_id(item_id)?;
            let state = self.lock()?;
            let stored = state.items.get(item_id).ok_or_else(not_found)?;
            Ok(KnowledgeItem {
                summary: stored.summary.clone(),
                text: self.read_body(&state, &stored.content_sha256)?,
            })
        })
    }

    pub fn import(&self, request: KnowledgeImportRequest) -> CommandResult<KnowledgeImportResult> {
        self.checked_operation(|| self.import_with_archive(request, None))
    }

    /// Browser captures may attach one validated full-page archive.  Other import paths pass
    /// `None`, so archives never enter text indexing or Markdown export.
    pub fn import_with_archive(
        &self,
        request: KnowledgeImportRequest,
        archive: Option<&BrowserCaptureArchive>,
    ) -> CommandResult<KnowledgeImportResult> {
        self.checked_operation(|| {
        let request = validate_import_request(request)?;
        let archive = archive.map(validate_archive).transpose()?;
        let digest = sha256_hex(request.text.as_bytes());
        let mut state = self.lock()?;
        if let Some(existing) = state
            .items
            .values()
            .find(|item| item.content_sha256 == digest)
        {
            if existing.summary.archive.is_none() {
                if let Some(archive) = archive.as_ref() {
                    let archive_was_referenced =
                        archive_is_referenced(&state.items, &archive.sha256);
                    if !archive_was_referenced
                        && !archive_capacity_allows(
                            total_unique_archive_bytes(&state.items),
                            archive.bytes.len() as u64,
                        )
                    {
                        return Err(limit_error(
                            "knowledge_archive_size_limit",
                            "Offline archives are limited to 512 MiB of unique content.",
                        ));
                    }
                    let mut candidate = state.clone();
                    let archive_digest = archive.sha256.clone();
                    self.write_archive_if_absent(&mut candidate, &archive_digest, &archive.bytes)?;
                    let item = candidate
                        .items
                        .get_mut(&existing.summary.item_id)
                        .expect("existing item");
                    item.summary.archive = Some(archive.metadata());
                    item.summary.updated_at_epoch_seconds = now_epoch_seconds();
                    if let Some(revision) = item.revisions.last_mut() {
                        revision.archive = item.summary.archive.clone();
                    }
                    if let Err(error) = self.persist(&candidate) {
                        if !archive_was_referenced {
                            let _ = self.remove_archive(&mut candidate, &archive_digest);
                        }
                        return Err(error);
                    }
                    let updated = candidate
                        .items
                        .get(&existing.summary.item_id)
                        .expect("updated item");
                    let result = KnowledgeItem {
                        summary: updated.summary.clone(),
                        text: self.read_body(&candidate, &digest)?,
                    };
                    *state = candidate;
                    return Ok(KnowledgeImportResult { item: result, deduplicated: true, archive_attached: true, summary: "This content was already in your library; its offline archive was attached.".into() });
                }
            }
            let item = KnowledgeItem {
                summary: existing.summary.clone(),
                text: self.read_body(&state, &digest)?,
            };
            return Ok(KnowledgeImportResult {
                item,
                deduplicated: true,
                archive_attached: false,
                summary: "This content was already in your library.".into(),
            });
        }
        if state.items.len() >= MAX_ITEMS {
            return Err(limit_error(
                "knowledge_item_limit",
                "The knowledge library holds at most 2000 items.",
            ));
        }
        let new_bytes = request.text.len() as u64;
        let body_was_referenced = blob_is_referenced(&state.items, &digest);
        if !body_was_referenced
            && total_unique_bytes(&state.items).saturating_add(new_bytes) > MAX_LIBRARY_BYTES
        {
            return Err(limit_error(
                "knowledge_size_limit",
                "The knowledge library is limited to 64 MiB of unique content.",
            ));
        }
        let archive_was_referenced = archive
            .as_ref()
            .is_some_and(|archive| archive_is_referenced(&state.items, &archive.sha256));
        if let Some(archive) = archive.as_ref() {
            if !archive_was_referenced
                && !archive_capacity_allows(
                    total_unique_archive_bytes(&state.items),
                    archive.bytes.len() as u64,
                )
            {
                return Err(limit_error(
                    "knowledge_archive_size_limit",
                    "Offline archives are limited to 512 MiB of unique content.",
                ));
            }
        }
        let now = now_epoch_seconds();
        let summary = KnowledgeItemSummary {
            item_id: Uuid::new_v4().to_string(),
            title: request.title,
            source_kind: request.source_kind,
            source_name: request.source_name,
            source_url: request.source_url,
            byte_size: new_bytes,
            created_at_epoch_seconds: now,
            updated_at_epoch_seconds: now,
            reading_progress_percent: 0,
            allows_local_semantic_index: request.allows_local_semantic_index,
            allows_remote_ai_use: request.allows_remote_ai_use,
            folder_id: None,
            revision_number: 1,
            revision_count: 1,
            archive: archive.as_ref().map(ValidatedArchive::metadata),
        };
        let mut candidate = state.clone();
        if let Err(error) = self.write_body_if_absent(&mut candidate, &digest, &request.text) {
            if !body_was_referenced {
                let _ = self.remove_body(&mut candidate, &digest);
            }
            return Err(error);
        }
        if let Some(archive) = archive.as_ref() {
            if let Err(error) =
                self.write_archive_if_absent(&mut candidate, &archive.sha256, &archive.bytes)
            {
                if !body_was_referenced {
                    let _ = self.remove_body(&mut candidate, &digest);
                }
                return Err(error);
            }
        }
        let item = KnowledgeItem {
            summary: summary.clone(),
            text: request.text,
        };
        candidate.items.insert(
            summary.item_id.clone(),
            StoredItem {
                revisions: vec![KnowledgeRevisionSummary {
                    revision_number: 1,
                    content_sha256: digest.clone(),
                    byte_size: new_bytes,
                    created_at_epoch_seconds: now,
                    archive: summary.archive.clone(),
                }],
                summary,
                content_sha256: digest.clone(),
            },
        );
        if let Err(error) = self.persist(&candidate) {
            // The manifest never referenced this object. Remove it immediately; startup and
            // status-time reachability collection provide recovery if cleanup itself is blocked.
            if !body_was_referenced {
                let _ = self.remove_body(&mut candidate, &digest);
            }
            if let Some(archive) = archive.as_ref() {
                if !archive_was_referenced {
                    let _ = self.remove_archive(&mut candidate, &archive.sha256);
                }
            }
            return Err(error);
        }
        *state = candidate;
        Ok(KnowledgeImportResult {
            item,
            deduplicated: false,
            archive_attached: false,
            summary: "Added to your local knowledge library.".into(),
        })

        })
    }

    /// Browser-only import with URL conflict decisions and a persistent operation ledger.  A
    /// `Conflict` result is intentionally not a completed operation: the extension can safely
    /// retry it once the user has chosen a resolution.
    pub fn import_browser_capture(
        &self,
        request: BrowserKnowledgeImportRequest,
        archive: Option<&BrowserCaptureArchive>,
    ) -> CommandResult<BrowserKnowledgeImportOutcome> {
        self.checked_operation(|| {
            let (request, import) = validate_browser_import_request(request)?;
            let archive = archive.map(validate_archive).transpose()?;
            let fingerprint = browser_operation_fingerprint(&request, &archive);
            let mut state = self.lock()?;
            purge_completed_operations(&mut state);
            if let Some(completed) = state.completed_operations.get(&request.operation_id) {
                let matches_current = completed.fingerprint == fingerprint;
                // P10 stored a v2 digest before per-item remote-AI permission existed. Preserve
                // idempotent local-only retries after migrating the manifest, but never let that
                // legacy digest authorize a request whose new permission bit is true.
                let matches_local_only_legacy = !request.allows_remote_ai_use
                    && completed.fingerprint
                        == browser_operation_legacy_v2_fingerprint(&request, &archive);
                if !matches_current && !matches_local_only_legacy {
                    return Err(CommandError::new(
                        "knowledge_operation_conflict",
                        "This browser operation ID was already used for different content.",
                    ));
                }
                let mut receipt = completed.receipt.clone();
                receipt.replayed = true;
                return Ok(BrowserKnowledgeImportOutcome::Imported { receipt });
            }

            let duplicate = state
                .items
                .values()
                .filter(|item| {
                    item.summary.source_url.as_deref() == Some(request.source_url.as_str())
                })
                // Explicit copies retain the source URL. Future captures consistently target the
                // original (oldest) item instead of depending on random UUID ordering.
                .min_by(|left, right| {
                    left.summary
                        .created_at_epoch_seconds
                        .cmp(&right.summary.created_at_epoch_seconds)
                        .then_with(|| left.summary.item_id.cmp(&right.summary.item_id))
                })
                .cloned();
            if let Some(ref existing) = duplicate {
                match request.duplicate_resolution.as_deref() {
                    None => {
                        return Ok(BrowserKnowledgeImportOutcome::Conflict {
                            conflict: BrowserKnowledgeDuplicateConflict {
                                document_id: existing.summary.item_id.clone(),
                                title: existing.summary.title.clone(),
                                folder_id: existing.summary.folder_id.clone(),
                                byte_size: existing.summary.byte_size,
                                updated_at_epoch_seconds: existing.summary.updated_at_epoch_seconds,
                                incoming_has_changes: existing.content_sha256
                                    != sha256_hex(import.text.as_bytes())
                                    || existing.summary.archive.as_ref().map(|value| &value.sha256)
                                        != archive.as_ref().map(|value| &value.sha256),
                            },
                        })
                    }
                    Some("move-only") => {
                        let mut candidate = state.clone();
                        let folder_id = resolve_folder_for_request(
                            &mut candidate,
                            request.folder_id.as_deref(),
                            request.new_folder_name.as_deref(),
                        )?;
                        let item = candidate
                            .items
                            .get_mut(&existing.summary.item_id)
                            .expect("duplicate exists");
                        item.summary.folder_id = folder_id.clone();
                        item.summary.updated_at_epoch_seconds = now_epoch_seconds();
                        let receipt = browser_receipt(item, "moved", false);
                        record_completed_operation(
                            &mut candidate,
                            &request.operation_id,
                            fingerprint,
                            receipt.clone(),
                        );
                        self.persist(&candidate)?;
                        *state = candidate;
                        return Ok(BrowserKnowledgeImportOutcome::Imported { receipt });
                    }
                    Some("save-new-version") => {
                        let mut candidate = state.clone();
                        let folder_id = resolve_folder_for_request(
                            &mut candidate,
                            request.folder_id.as_deref(),
                            request.new_folder_name.as_deref(),
                        )?;
                        let current = candidate
                            .items
                            .get(&existing.summary.item_id)
                            .expect("duplicate exists");
                        if current.revisions.len() >= MAX_REVISIONS_PER_ITEM {
                            return Err(limit_error(
                                "knowledge_revision_limit",
                                "A knowledge item holds at most 32 revisions.",
                            ));
                        }
                        let digest = sha256_hex(import.text.as_bytes());
                        if !blob_is_referenced(&candidate.items, &digest)
                            && total_unique_bytes(&candidate.items)
                                .saturating_add(import.text.len() as u64)
                                > MAX_LIBRARY_BYTES
                        {
                            return Err(limit_error(
                                "knowledge_size_limit",
                                "The knowledge library is limited to 64 MiB of unique content.",
                            ));
                        }
                        if let Some(archive) = archive.as_ref() {
                            if !archive_is_referenced(&candidate.items, &archive.sha256)
                                && !archive_capacity_allows(
                                    total_unique_archive_bytes(&candidate.items),
                                    archive.bytes.len() as u64,
                                )
                            {
                                return Err(limit_error(
                                    "knowledge_archive_size_limit",
                                    "Offline archives are limited to 512 MiB of unique content.",
                                ));
                            }
                        }
                        let body_existed = blob_is_referenced(&state.items, &digest);
                        let archive_existed = archive.as_ref().is_some_and(|value| {
                            archive_is_referenced(&state.items, &value.sha256)
                        });
                        self.write_body_if_absent(&mut candidate, &digest, &import.text)?;
                        if let Some(archive) = archive.as_ref() {
                            if let Err(error) = self.write_archive_if_absent(
                                &mut candidate,
                                &archive.sha256,
                                &archive.bytes,
                            ) {
                                if !body_existed {
                                    let _ = self.remove_body(&mut candidate, &digest);
                                }
                                return Err(error);
                            }
                        }
                        let now = now_epoch_seconds();
                        let receipt = {
                            let item = candidate
                                .items
                                .get_mut(&existing.summary.item_id)
                                .expect("duplicate exists");
                            let revision_number = item
                                .revisions
                                .last()
                                .map(|revision| revision.revision_number + 1)
                                .unwrap_or(1);
                            let archive_metadata = archive.as_ref().map(ValidatedArchive::metadata);
                            item.revisions.push(KnowledgeRevisionSummary {
                                revision_number,
                                content_sha256: digest.clone(),
                                byte_size: import.text.len() as u64,
                                created_at_epoch_seconds: now,
                                archive: archive_metadata.clone(),
                            });
                            item.content_sha256 = digest.clone();
                            item.summary.title = import.title;
                            item.summary.source_name = import.source_name;
                            item.summary.source_url = Some(request.source_url.clone());
                            item.summary.byte_size = import.text.len() as u64;
                            item.summary.updated_at_epoch_seconds = now;
                            item.summary.folder_id = folder_id;
                            item.summary.allows_local_semantic_index =
                                import.allows_local_semantic_index;
                            item.summary.allows_remote_ai_use = import.allows_remote_ai_use;
                            item.summary.archive = archive_metadata;
                            item.summary.revision_number = revision_number;
                            item.summary.revision_count = item.revisions.len() as u32;
                            browser_receipt(item, "new-version", false)
                        };
                        record_completed_operation(
                            &mut candidate,
                            &request.operation_id,
                            fingerprint,
                            receipt.clone(),
                        );
                        if let Err(error) = self.persist(&candidate) {
                            if !body_existed {
                                let _ = self.remove_body(&mut candidate, &digest);
                            }
                            if let Some(archive) = archive.as_ref() {
                                if !archive_existed {
                                    let _ = self.remove_archive(&mut candidate, &archive.sha256);
                                }
                            }
                            return Err(error);
                        }
                        *state = candidate;
                        return Ok(BrowserKnowledgeImportOutcome::Imported { receipt });
                    }
                    Some("keep-copy") => {}
                    Some(_) => return Err(CommandError::new(
                        "knowledge_duplicate_resolution_invalid",
                        "Duplicate resolution must be save-new-version, move-only, or keep-copy.",
                    )),
                }
            }

            if state.items.len() >= MAX_ITEMS {
                return Err(limit_error(
                    "knowledge_item_limit",
                    "The knowledge library holds at most 2000 items.",
                ));
            }
            let mut candidate = state.clone();
            let folder_id = resolve_folder_for_request(
                &mut candidate,
                request.folder_id.as_deref(),
                request.new_folder_name.as_deref(),
            )?;
            let digest = sha256_hex(import.text.as_bytes());
            if !blob_is_referenced(&state.items, &digest)
                && total_unique_bytes(&state.items).saturating_add(import.text.len() as u64)
                    > MAX_LIBRARY_BYTES
            {
                return Err(limit_error(
                    "knowledge_size_limit",
                    "The knowledge library is limited to 64 MiB of unique content.",
                ));
            }
            if let Some(archive) = archive.as_ref() {
                if !archive_is_referenced(&state.items, &archive.sha256)
                    && !archive_capacity_allows(
                        total_unique_archive_bytes(&state.items),
                        archive.bytes.len() as u64,
                    )
                {
                    return Err(limit_error(
                        "knowledge_archive_size_limit",
                        "Offline archives are limited to 512 MiB of unique content.",
                    ));
                }
            }
            let body_existed = blob_is_referenced(&state.items, &digest);
            let archive_existed = archive
                .as_ref()
                .is_some_and(|value| archive_is_referenced(&state.items, &value.sha256));
            self.write_body_if_absent(&mut candidate, &digest, &import.text)?;
            if let Some(archive) = archive.as_ref() {
                if let Err(error) =
                    self.write_archive_if_absent(&mut candidate, &archive.sha256, &archive.bytes)
                {
                    if !body_existed {
                        let _ = self.remove_body(&mut candidate, &digest);
                    }
                    return Err(error);
                }
            }
            let now = duplicate
                .as_ref()
                .map_or_else(now_epoch_seconds, |existing| {
                    now_epoch_seconds()
                        .max(existing.summary.created_at_epoch_seconds.saturating_add(1))
                });
            let title = if duplicate.is_some() {
                copy_title(&import.title)?
            } else {
                import.title
            };
            let summary = KnowledgeItemSummary {
                item_id: Uuid::new_v4().to_string(),
                title,
                source_kind: KnowledgeSourceKind::Web,
                source_name: import.source_name,
                source_url: Some(request.source_url),
                byte_size: import.text.len() as u64,
                created_at_epoch_seconds: now,
                updated_at_epoch_seconds: now,
                reading_progress_percent: 0,
                allows_local_semantic_index: import.allows_local_semantic_index,
                allows_remote_ai_use: import.allows_remote_ai_use,
                folder_id,
                revision_number: 1,
                revision_count: 1,
                archive: archive.as_ref().map(ValidatedArchive::metadata),
            };
            let item_id = summary.item_id.clone();
            candidate.items.insert(
                item_id.clone(),
                StoredItem {
                    content_sha256: digest.clone(),
                    revisions: vec![KnowledgeRevisionSummary {
                        revision_number: 1,
                        content_sha256: digest.clone(),
                        byte_size: summary.byte_size,
                        created_at_epoch_seconds: now,
                        archive: summary.archive.clone(),
                    }],
                    summary,
                },
            );
            let receipt = browser_receipt(
                candidate.items.get(&item_id).expect("inserted"),
                if duplicate.is_some() {
                    "copied"
                } else {
                    "inserted"
                },
                false,
            );
            record_completed_operation(
                &mut candidate,
                &request.operation_id,
                fingerprint,
                receipt.clone(),
            );
            if let Err(error) = self.persist(&candidate) {
                if !body_existed {
                    let _ = self.remove_body(&mut candidate, &digest);
                }
                if let Some(archive) = archive.as_ref() {
                    if !archive_existed {
                        let _ = self.remove_archive(&mut candidate, &archive.sha256);
                    }
                }
                return Err(error);
            }
            *state = candidate;
            Ok(BrowserKnowledgeImportOutcome::Imported { receipt })
        })
    }

    pub fn search(&self, query: &str, limit: usize) -> CommandResult<KnowledgeSearchSnapshot> {
        self.checked_operation(|| {
            let query = clean_string(
                query,
                MAX_QUERY_BYTES,
                "knowledge_query_invalid",
                "Search query",
            )?;
            if query.trim().is_empty() {
                return Err(CommandError::new(
                    "knowledge_query_invalid",
                    "Search query cannot be empty.",
                ));
            }
            let query_features = semantic_features(&query);
            let query_set = query_features.iter().cloned().collect::<BTreeSet<_>>();
            let query_embedding = normalized_embedding(&query_features);
            let state = self.lock()?;
            let mut results = Vec::new();
            for stored in state.items.values() {
                let text = self.read_body(&state, &stored.content_sha256)?;
                // Literal on-device search remains available for every imported item. The explicit
                // consent flag gates only semantic embeddings, never basic local discoverability.
                let lexical_haystack = bounded_feature_text(&format!(
                    "{}\n{}\n{}",
                    stored.summary.title, stored.summary.source_name, text
                ));
                let lexical_features = semantic_features(&lexical_haystack);
                let lexical_set = lexical_features.iter().collect::<BTreeSet<_>>();
                let intersection = query_set
                    .iter()
                    .filter(|term| lexical_set.contains(*term))
                    .count() as f32;
                let union = query_set.len() + lexical_set.len() - intersection as usize;
                let lexical_score = if union == 0 {
                    0.0
                } else {
                    intersection / union as f32
                };
                let semantic_score = if stored.summary.allows_local_semantic_index {
                    normalized_embedding(&semantic_features(&bounded_feature_text(&text)))
                        .iter()
                        .zip(&query_embedding)
                        .map(|(a, b)| a * b)
                        .sum::<f32>()
                        .max(0.0)
                } else {
                    0.0
                };
                let score = if stored.summary.allows_local_semantic_index {
                    lexical_score * 0.45 + semantic_score * 0.55
                } else {
                    lexical_score
                };
                if score <= 0.0 {
                    continue;
                }
                let reason = match (lexical_score > 0.0, semantic_score > 0.0) {
                    (true, true) => "Lexical and local semantic match",
                    (true, false) => "Lexical match",
                    (false, true) => "Local semantic match",
                    _ => "Match",
                }
                .to_string();
                results.push(KnowledgeSearchResult {
                    item: stored.summary.clone(),
                    score,
                    lexical_score,
                    semantic_score,
                    snippet: snippet_for(&text, &query),
                    reason,
                });
            }
            results.sort_by(|a, b| {
                b.score
                    .total_cmp(&a.score)
                    .then_with(|| b.lexical_score.total_cmp(&a.lexical_score))
                    .then_with(|| a.item.title.cmp(&b.item.title))
                    .then_with(|| a.item.item_id.cmp(&b.item.item_id))
            });
            let bounded_limit = limit.min(MAX_SEARCH_LIMIT);
            let truncated = results.len() > bounded_limit;
            results.truncate(bounded_limit);
            Ok(KnowledgeSearchSnapshot {
                query,
                model_id: SEMANTIC_MODEL_ID.into(),
                encoding_version: SEMANTIC_ENCODING_VERSION,
                results,
                truncated,
            })
        })
    }

    pub fn update_progress(
        &self,
        item_id: &str,
        progress_percent: u8,
    ) -> CommandResult<KnowledgeItemSummary> {
        self.checked_operation(|| {
            validate_item_id(item_id)?;
            if progress_percent > 100 {
                return Err(CommandError::new(
                    "knowledge_progress_invalid",
                    "Reading progress must be between 0 and 100.",
                ));
            }
            let mut state = self.lock()?;
            let mut candidate = state.clone();
            let summary = {
                let item = candidate.items.get_mut(item_id).ok_or_else(not_found)?;
                item.summary.reading_progress_percent = progress_percent;
                item.summary.updated_at_epoch_seconds = now_epoch_seconds();
                item.summary.clone()
            };
            self.persist(&candidate)?;
            *state = candidate;
            Ok(summary)
        })
    }

    pub fn delete(&self, item_id: &str) -> CommandResult<KnowledgeDeleteResult> {
        self.checked_operation(|| {
            validate_item_id(item_id)?;
            let mut state = self.lock()?;
            let mut candidate = state.clone();
            let removed = candidate.items.remove(item_id).ok_or_else(not_found)?;
            let removable_bodies = removed
                .revisions
                .iter()
                .map(|revision| revision.content_sha256.clone())
                .collect::<BTreeSet<_>>()
                .into_iter()
                .filter(|digest| !blob_is_referenced(&candidate.items, digest))
                .collect::<Vec<_>>();
            let removable_archives = removed
                .revisions
                .iter()
                .filter_map(|revision| {
                    revision
                        .archive
                        .as_ref()
                        .map(|archive| archive.sha256.clone())
                })
                .collect::<BTreeSet<_>>()
                .into_iter()
                .filter(|digest| !archive_is_referenced(&candidate.items, digest))
                .collect::<Vec<_>>();
            self.persist(&candidate)?;
            *state = candidate;
            let cleanup_pending = removable_bodies
                .iter()
                .any(|digest| self.remove_body(&mut state, digest).is_err());
            let archive_cleanup_pending = removable_archives
                .iter()
                .any(|digest| self.remove_archive(&mut state, digest).is_err());
            Ok(KnowledgeDeleteResult {
                item_id: item_id.into(),
                deleted: true,
                summary: if cleanup_pending || archive_cleanup_pending {
                    "Removed from your local knowledge library; private object cleanup will retry."
                        .into()
                } else {
                    "Removed from your local knowledge library.".into()
                },
            })
        })
    }

    pub fn plan_export(
        &self,
        session_id: &str,
        repository_root: &Path,
        item_id: &str,
        relative_path: &str,
    ) -> CommandResult<KnowledgeExportPlan> {
        self.checked_operation(|| {
        validate_item_id(item_id)?;
        let session_id = clean_single_line(
            session_id,
            256,
            "knowledge_export_invalid",
            "Session identifier",
        )?;
        if session_id.is_empty() {
            return Err(CommandError::new(
                "knowledge_export_invalid",
                "Session identifier cannot be empty.",
            ));
        }
        let relative_path = validate_relative_markdown_path(relative_path)?;
        let repository_root = validate_repository_root(repository_root)?;
        let state = self.lock()?;
        let stored = state.items.get(item_id).ok_or_else(not_found)?;
        validate_export_destination(&repository_root, &relative_path)?;
        let creates_parent_directories =
            export_parent_is_missing(&repository_root, &relative_path)?;
        let mut warnings =
            vec!["Export is limited to a new .md file inside the selected repository.".into()];
        if creates_parent_directories {
            warnings.push("Missing parent directories will be created as private, non-symlink directories when the export is confirmed.".into());
        }
        let public = KnowledgeExportPlan { plan_id: Uuid::new_v4().to_string(), item_id: item_id.into(), relative_path, title: stored.summary.title.clone(), content_sha256: stored.content_sha256.clone(), expires_at_epoch_seconds: now_epoch_seconds() + EXPORT_TTL_SECONDS, summary: "Confirming this plan will create one new Markdown file; it will not stage or commit it.".into(), warnings };
        drop(state);
        let mut state = self.lock()?;
        purge_expired_plans(&mut state);
        if state.export_plans.len() >= MAX_EXPORT_PLANS {
            return Err(CommandError::new("knowledge_export_plan_limit", "Too many pending export confirmations. Confirm or wait for an existing plan to expire."));
        }
        state.export_plans.insert(
            public.plan_id.clone(),
            ExportPlanState {
                public: public.clone(),
                session_id,
                repository_root,
            },
        );
        Ok(public)

        })
    }

    pub fn execute_export(
        &self,
        session_id: &str,
        repository_root: &Path,
        plan_id: &str,
    ) -> CommandResult<KnowledgeExportResult> {
        self.checked_operation(|| {
            let session_id = clean_single_line(
                session_id,
                256,
                "knowledge_export_invalid",
                "Session identifier",
            )?;
            let repository_root = validate_repository_root(repository_root)?;
            validate_item_id(plan_id)?;
            let (plan, stored, text) = {
                let mut state = self.lock()?;
                purge_expired_plans(&mut state);
                let plan = state.export_plans.remove(plan_id).ok_or_else(|| {
                    CommandError::new(
                        "knowledge_export_plan_invalid",
                        "Export plan is missing, expired, or already used.",
                    )
                })?;
                if plan.session_id != session_id
                    || plan.repository_root != repository_root
                    || plan.public.expires_at_epoch_seconds < now_epoch_seconds()
                {
                    return Err(CommandError::new(
                        "knowledge_export_plan_invalid",
                        "Export plan is not valid for this session, repository, or time.",
                    ));
                }
                let stored = state
                    .items
                    .get(&plan.public.item_id)
                    .ok_or_else(not_found)?
                    .clone();
                if stored.content_sha256 != plan.public.content_sha256 {
                    return Err(CommandError::new(
                        "knowledge_export_changed",
                        "Library content changed after this export was planned.",
                    ));
                }
                let text = self.read_body(&state, &stored.content_sha256)?;
                (plan, stored, text)
            };
            validate_export_destination(&repository_root, &plan.public.relative_path)?;
            let bytes = render_export_markdown(&stored.summary, &text).into_bytes();
            write_new_export(&repository_root, &plan.public.relative_path, &bytes)?;
            Ok(KnowledgeExportResult {
                item_id: plan.public.item_id,
                relative_path: plan.public.relative_path,
                byte_size: bytes.len() as u64,
                summary: "Created a new Markdown file. It has not been staged or committed.".into(),
            })
        })
    }

    pub fn plan_archive_export(
        &self,
        session_id: &str,
        repository_root: &Path,
        item_id: &str,
        relative_path: &str,
    ) -> CommandResult<KnowledgeArchiveExportPlan> {
        self.checked_operation(|| {
        validate_item_id(item_id)?;
        let session_id = clean_single_line(
            session_id,
            256,
            "knowledge_archive_export_invalid",
            "Session identifier",
        )?;
        if session_id.is_empty() {
            return Err(CommandError::new(
                "knowledge_archive_export_invalid",
                "Session identifier cannot be empty.",
            ));
        }
        let repository_root = validate_repository_root(repository_root)?;
        let state = self.lock()?;
        let stored = state.items.get(item_id).ok_or_else(not_found)?;
        let archive = stored.summary.archive.as_ref().ok_or_else(|| {
            CommandError::new(
                "knowledge_archive_missing",
                "This knowledge item has no offline archive.",
            )
        })?;
        let relative_path = validate_relative_archive_path(relative_path, &archive.format)?;
        validate_export_destination(&repository_root, &relative_path)?;
        let creates_parent_directories =
            export_parent_is_missing(&repository_root, &relative_path)?;
        let mut warnings = vec![
            "Export is limited to one new offline archive inside the selected repository."
                .to_string(),
        ];
        if creates_parent_directories {
            warnings.push("Missing parent directories will be created as private, non-symlink directories when the export is confirmed.".to_string());
        }
        let public = KnowledgeArchiveExportPlan { plan_id: Uuid::new_v4().to_string(), item_id: item_id.into(), relative_path, format: archive.format.clone(), archive_sha256: archive.sha256.clone(), byte_size: archive.byte_size, expires_at_epoch_seconds: now_epoch_seconds() + EXPORT_TTL_SECONDS, summary: "Confirming this plan will create one new offline archive; it will not stage or commit it.".to_string(), warnings };
        drop(state);
        let mut state = self.lock()?;
        purge_expired_plans(&mut state);
        if state.archive_export_plans.len() >= MAX_EXPORT_PLANS {
            return Err(CommandError::new(
                "knowledge_archive_export_plan_limit",
                "Too many pending archive export confirmations.",
            ));
        }
        state.archive_export_plans.insert(
            public.plan_id.clone(),
            ArchiveExportPlanState {
                public: public.clone(),
                session_id,
                repository_root,
            },
        );
        Ok(public)

        })
    }

    pub fn execute_archive_export(
        &self,
        session_id: &str,
        repository_root: &Path,
        plan_id: &str,
    ) -> CommandResult<KnowledgeArchiveExportResult> {
        self.checked_operation(|| {
            let session_id = clean_single_line(
                session_id,
                256,
                "knowledge_archive_export_invalid",
                "Session identifier",
            )?;
            let repository_root = validate_repository_root(repository_root)?;
            validate_item_id(plan_id)?;
            let (plan, bytes) = {
                let mut state = self.lock()?;
                purge_expired_plans(&mut state);
                let plan = state.archive_export_plans.remove(plan_id).ok_or_else(|| {
                    CommandError::new(
                        "knowledge_archive_export_plan_invalid",
                        "Archive export plan is missing, expired, or already used.",
                    )
                })?;
                if plan.session_id != session_id
                    || plan.repository_root != repository_root
                    || plan.public.expires_at_epoch_seconds < now_epoch_seconds()
                {
                    return Err(CommandError::new(
                        "knowledge_archive_export_plan_invalid",
                        "Archive export plan is not valid for this session, repository, or time.",
                    ));
                }
                let stored = state
                    .items
                    .get(&plan.public.item_id)
                    .ok_or_else(not_found)?;
                let archive = stored.summary.archive.as_ref().ok_or_else(|| {
                    CommandError::new(
                        "knowledge_archive_missing",
                        "This knowledge item no longer has an offline archive.",
                    )
                })?;
                if archive.sha256 != plan.public.archive_sha256
                    || archive.format != plan.public.format
                    || archive.byte_size != plan.public.byte_size
                {
                    return Err(CommandError::new(
                        "knowledge_archive_export_changed",
                        "Offline archive changed after export was planned.",
                    ));
                }
                (plan, self.read_archive(&state, &archive.sha256)?)
            };
            validate_relative_archive_path(&plan.public.relative_path, &plan.public.format)?;
            validate_export_destination(&repository_root, &plan.public.relative_path)?;
            write_new_export(&repository_root, &plan.public.relative_path, &bytes)?;
            Ok(KnowledgeArchiveExportResult {
                item_id: plan.public.item_id,
                relative_path: plan.public.relative_path,
                byte_size: bytes.len() as u64,
                format: plan.public.format,
                summary: "Created a new offline archive. It has not been staged or committed."
                    .to_string(),
            })
        })
    }

    fn lock(&self) -> CommandResult<LibraryGuard<'_>> {
        let mut state = self.state.lock().map_err(|_| {
            CommandError::new(
                "knowledge_library_unavailable",
                "Knowledge library state is unavailable.",
            )
        })?;
        let lease = if let Some(storage) = &self.storage {
            super::knowledge_restore_gate::verify_anchor(
                &storage.app_data_dir,
                &storage.root_anchor,
            )?;
            let lease = KnowledgeRootLease::acquire(&storage.app_data_dir)?;
            super::normal_library_access(&lease.file)?;
            let generation = storage_generation(storage)?;
            let mut cached = storage
                .generation
                .lock()
                .map_err(|_| super::knowledge_restore_gate::blocked())?;
            if cached.as_ref() != Some(&generation) {
                let (items, folders, completed_operations, needs_migration) =
                    load_manifest(storage)?;
                if needs_migration {
                    return Err(super::knowledge_restore_gate::blocked());
                }
                let after = storage_generation(storage)?;
                if after != generation {
                    return Err(super::knowledge_restore_gate::blocked());
                }
                state.items = items;
                state.folders = folders;
                state.completed_operations = completed_operations;
                state.export_plans.clear();
                state.archive_export_plans.clear();
                state.open_request = None;
                *cached = Some(generation);
            }
            lease.verify()?;
            Some(lease)
        } else {
            None
        };
        Ok(LibraryGuard {
            state,
            _lease: lease,
        })
    }

    fn read_body(&self, state: &LibraryState, digest: &str) -> CommandResult<String> {
        match &self.storage {
            Some(storage) => read_blob(storage, digest),
            None => state.memory_blobs.get(digest).cloned().ok_or_else(|| {
                CommandError::new("knowledge_content_missing", "Knowledge content is missing.")
            }),
        }
    }

    fn write_body_if_absent(
        &self,
        state: &mut LibraryState,
        digest: &str,
        text: &str,
    ) -> CommandResult<()> {
        match &self.storage {
            Some(storage) => write_blob_if_absent(storage, digest, text.as_bytes()),
            None => {
                state
                    .memory_blobs
                    .entry(digest.into())
                    .or_insert_with(|| text.into());
                Ok(())
            }
        }
    }

    fn remove_body(&self, state: &mut LibraryState, digest: &str) -> CommandResult<()> {
        match &self.storage {
            Some(storage) => remove_blob(storage, digest),
            None => {
                state.memory_blobs.remove(digest);
                Ok(())
            }
        }
    }

    fn read_archive(&self, state: &LibraryState, digest: &str) -> CommandResult<Vec<u8>> {
        match &self.storage {
            Some(storage) => read_archive(storage, digest),
            None => state.memory_archives.get(digest).cloned().ok_or_else(|| {
                CommandError::new("knowledge_archive_missing", "Offline archive is missing.")
            }),
        }
    }

    fn write_archive_if_absent(
        &self,
        state: &mut LibraryState,
        digest: &str,
        bytes: &[u8],
    ) -> CommandResult<()> {
        match &self.storage {
            Some(storage) => write_archive_if_absent(storage, digest, bytes),
            None => {
                state
                    .memory_archives
                    .entry(digest.into())
                    .or_insert_with(|| bytes.to_vec());
                Ok(())
            }
        }
    }

    fn remove_archive(&self, state: &mut LibraryState, digest: &str) -> CommandResult<()> {
        match &self.storage {
            Some(storage) => remove_archive(storage, digest),
            None => {
                state.memory_archives.remove(digest);
                Ok(())
            }
        }
    }

    fn persist(&self, state: &LibraryState) -> CommandResult<()> {
        if let Some(storage) = &self.storage {
            write_manifest(storage, state)?;
            *storage
                .generation
                .lock()
                .map_err(|_| super::knowledge_restore_gate::blocked())? =
                Some(storage_generation(storage)?);
        }
        Ok(())
    }
}

fn validate_import_request(
    mut request: KnowledgeImportRequest,
) -> CommandResult<KnowledgeImportRequest> {
    request.title = clean_single_line(
        &request.title,
        MAX_TITLE_BYTES,
        "knowledge_import_invalid",
        "Title",
    )?;
    request.source_name = clean_single_line(
        &request.source_name,
        MAX_SOURCE_NAME_BYTES,
        "knowledge_import_invalid",
        "Source name",
    )?;
    request.text = clean_string(
        &request.text,
        MAX_ITEM_BYTES,
        "knowledge_import_invalid",
        "Text",
    )?;
    if request.title.trim().is_empty() || request.source_name.trim().is_empty() {
        return Err(CommandError::new(
            "knowledge_import_invalid",
            "Title and source name cannot be empty.",
        ));
    }
    if request.text.len() > MAX_ITEM_BYTES {
        return Err(limit_error(
            "knowledge_item_too_large",
            "Imported text must not exceed 5 MiB.",
        ));
    }
    match request.source_kind {
        KnowledgeSourceKind::Web => {
            let value = request.source_url.take().ok_or_else(|| {
                CommandError::new(
                    "knowledge_import_invalid",
                    "Web sources require an http or https URL.",
                )
            })?;
            request.source_url = Some(validate_web_url(&value)?);
        }
        KnowledgeSourceKind::Pdf | KnowledgeSourceKind::Text => {
            if request.source_url.is_some() {
                return Err(CommandError::new(
                    "knowledge_import_invalid",
                    "Only web sources may include a URL.",
                ));
            }
        }
    }
    Ok(request)
}

fn validate_folder_name(value: &str) -> CommandResult<String> {
    let name = clean_single_line(
        value,
        MAX_FOLDER_NAME_BYTES,
        "knowledge_folder_invalid",
        "Folder name",
    )?;
    let name = name.trim().to_string();
    if name.is_empty() {
        return Err(CommandError::new(
            "knowledge_folder_invalid",
            "Folder name cannot be empty.",
        ));
    }
    Ok(name)
}

fn folder_name_key(value: &str) -> String {
    value.to_lowercase()
}

fn validate_optional_folder_id(folder_id: Option<&str>) -> CommandResult<Option<String>> {
    folder_id
        .map(|value| {
            validate_item_id(value)
                .map(|_| value.to_string())
                .map_err(|_| {
                    CommandError::new(
                        "knowledge_folder_invalid",
                        "Knowledge folder identifier is invalid.",
                    )
                })
        })
        .transpose()
}

fn validate_browser_import_request(
    request: BrowserKnowledgeImportRequest,
) -> CommandResult<(BrowserKnowledgeImportRequest, KnowledgeImportRequest)> {
    validate_item_id(&request.operation_id).map_err(|_| {
        CommandError::new(
            "knowledge_operation_invalid",
            "Browser operation identifier is invalid.",
        )
    })?;
    if request.folder_id.is_some() && request.new_folder_name.is_some() {
        return Err(CommandError::new(
            "knowledge_folder_invalid",
            "folderId and newFolderName are mutually exclusive.",
        ));
    }
    if request
        .duplicate_resolution
        .as_deref()
        .is_some_and(|value| !matches!(value, "save-new-version" | "move-only" | "keep-copy"))
    {
        return Err(CommandError::new(
            "knowledge_duplicate_resolution_invalid",
            "Duplicate resolution must be save-new-version, move-only, or keep-copy.",
        ));
    }
    let folder_id = validate_optional_folder_id(request.folder_id.as_deref())?;
    let new_folder_name = request
        .new_folder_name
        .as_deref()
        .map(validate_folder_name)
        .transpose()?;
    let import = validate_import_request(KnowledgeImportRequest {
        source_kind: KnowledgeSourceKind::Web,
        title: request.title.clone(),
        source_name: request.source_name.clone(),
        source_url: Some(request.source_url.clone()),
        text: request.text.clone(),
        allows_local_semantic_index: request.allows_local_semantic_index,
        allows_remote_ai_use: request.allows_remote_ai_use,
    })?;
    let mut request = request;
    request.source_url = import.source_url.clone().expect("web URL is validated");
    request.title = import.title.clone();
    request.source_name = import.source_name.clone();
    request.text = import.text.clone();
    request.folder_id = folder_id;
    request.new_folder_name = new_folder_name;
    Ok((request, import))
}

fn resolve_folder_for_request(
    state: &mut LibraryState,
    folder_id: Option<&str>,
    new_folder_name: Option<&str>,
) -> CommandResult<Option<String>> {
    if folder_id.is_some() && new_folder_name.is_some() {
        return Err(CommandError::new(
            "knowledge_folder_invalid",
            "folderId and newFolderName are mutually exclusive.",
        ));
    }
    if let Some(folder_id) = validate_optional_folder_id(folder_id)? {
        if !state.folders.contains_key(&folder_id) {
            return Err(CommandError::new(
                "knowledge_folder_not_found",
                "Knowledge folder was not found.",
            ));
        }
        return Ok(Some(folder_id));
    }
    let Some(name) = new_folder_name else {
        return Ok(None);
    };
    let name = validate_folder_name(name)?;
    if let Some(folder) = state
        .folders
        .values()
        .find(|folder| folder_name_key(&folder.name) == folder_name_key(&name))
    {
        return Ok(Some(folder.folder_id.clone()));
    }
    if state.folders.len() >= MAX_FOLDERS {
        return Err(limit_error(
            "knowledge_folder_limit",
            "The knowledge library holds at most 128 folders.",
        ));
    }
    let folder = KnowledgeFolder {
        folder_id: Uuid::new_v4().to_string(),
        name,
        created_at_epoch_seconds: now_epoch_seconds(),
    };
    let id = folder.folder_id.clone();
    state.folders.insert(id.clone(), folder);
    Ok(Some(id))
}

fn copy_title(title: &str) -> CommandResult<String> {
    const SUFFIX: &str = "（副本）";
    let maximum_base_bytes = MAX_TITLE_BYTES.saturating_sub(SUFFIX.len());
    let mut end = title.len().min(maximum_base_bytes);
    while !title.is_char_boundary(end) {
        end = end.saturating_sub(1);
    }
    let copied = format!("{}{}", &title[..end], SUFFIX);
    clean_single_line(
        &copied,
        MAX_TITLE_BYTES,
        "knowledge_import_invalid",
        "Title",
    )
}

fn browser_operation_fingerprint(
    request: &BrowserKnowledgeImportRequest,
    archive: &Option<ValidatedArchive>,
) -> String {
    let archive_format = archive
        .as_ref()
        .map(|value| value.format.as_str())
        .unwrap_or("");
    let archive_digest = archive
        .as_ref()
        .map(|value| value.sha256.as_str())
        .unwrap_or("");
    let embedded_resources = archive
        .as_ref()
        .and_then(|value| value.embedded_resource_count)
        .map(|value| value.to_string())
        .unwrap_or_default();
    let missing_resources = archive
        .as_ref()
        .and_then(|value| value.missing_resource_count)
        .map(|value| value.to_string())
        .unwrap_or_default();
    let was_truncated = archive
        .as_ref()
        .map(|value| value.was_truncated.to_string())
        .unwrap_or_default();
    let input = format!(
        "v3\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
        request.source_url,
        request.title,
        request.source_name,
        sha256_hex(request.text.as_bytes()),
        request.allows_local_semantic_index,
        request.allows_remote_ai_use,
        request.folder_id.as_deref().unwrap_or(""),
        request.new_folder_name.as_deref().unwrap_or(""),
        request.duplicate_resolution.as_deref().unwrap_or(""),
        archive_format,
        archive_digest,
        embedded_resources,
        missing_resources,
        was_truncated,
    );
    sha256_hex(input.as_bytes())
}

/// P10's operation digest, retained only to verify an already completed local-only retry.
/// New operations are always stored with `browser_operation_fingerprint` above.
fn browser_operation_legacy_v2_fingerprint(
    request: &BrowserKnowledgeImportRequest,
    archive: &Option<ValidatedArchive>,
) -> String {
    let archive_format = archive
        .as_ref()
        .map(|value| value.format.as_str())
        .unwrap_or("");
    let archive_digest = archive
        .as_ref()
        .map(|value| value.sha256.as_str())
        .unwrap_or("");
    let embedded_resources = archive
        .as_ref()
        .and_then(|value| value.embedded_resource_count)
        .map(|value| value.to_string())
        .unwrap_or_default();
    let missing_resources = archive
        .as_ref()
        .and_then(|value| value.missing_resource_count)
        .map(|value| value.to_string())
        .unwrap_or_default();
    let was_truncated = archive
        .as_ref()
        .map(|value| value.was_truncated.to_string())
        .unwrap_or_default();
    let input = format!(
        "v2\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
        request.source_url,
        request.title,
        request.source_name,
        sha256_hex(request.text.as_bytes()),
        request.allows_local_semantic_index,
        request.folder_id.as_deref().unwrap_or(""),
        request.new_folder_name.as_deref().unwrap_or(""),
        request.duplicate_resolution.as_deref().unwrap_or(""),
        archive_format,
        archive_digest,
        embedded_resources,
        missing_resources,
        was_truncated,
    );
    sha256_hex(input.as_bytes())
}

fn browser_receipt(
    item: &StoredItem,
    action: &str,
    replayed: bool,
) -> BrowserKnowledgeImportReceipt {
    BrowserKnowledgeImportReceipt {
        document_id: item.summary.item_id.clone(),
        title: item.summary.title.clone(),
        action: action.to_string(),
        folder_id: item.summary.folder_id.clone(),
        file_size_bytes: item
            .summary
            .archive
            .as_ref()
            .map(|archive| archive.byte_size)
            .unwrap_or(item.summary.byte_size),
        archive_type: item
            .summary
            .archive
            .as_ref()
            .map(|archive| archive.format.clone())
            .unwrap_or_else(|| "none".to_string()),
        allows_local_semantic_index: item.summary.allows_local_semantic_index,
        allows_remote_ai_use: item.summary.allows_remote_ai_use,
        saved_at_epoch_seconds: now_epoch_seconds(),
        replayed,
    }
}

fn record_completed_operation(
    state: &mut LibraryState,
    operation_id: &str,
    fingerprint: String,
    receipt: BrowserKnowledgeImportReceipt,
) {
    purge_completed_operations(state);
    state.completed_operations.insert(
        operation_id.to_string(),
        CompletedOperation {
            operation_id: operation_id.to_string(),
            fingerprint,
            completed_at_epoch_seconds: now_epoch_seconds(),
            receipt,
        },
    );
    while state.completed_operations.len() > MAX_COMPLETED_OPERATIONS {
        let oldest = state
            .completed_operations
            .iter()
            .min_by_key(|(_, value)| value.completed_at_epoch_seconds)
            .map(|(key, _)| key.clone());
        if let Some(oldest) = oldest {
            state.completed_operations.remove(&oldest);
        } else {
            break;
        }
    }
}

fn purge_completed_operations(state: &mut LibraryState) {
    let threshold = now_epoch_seconds().saturating_sub(COMPLETED_OPERATION_TTL_SECONDS);
    state
        .completed_operations
        .retain(|_, operation| operation.completed_at_epoch_seconds >= threshold);
}

fn validate_web_url(value: &str) -> CommandResult<String> {
    let value = clean_single_line(
        value,
        MAX_URL_BYTES,
        "knowledge_import_invalid",
        "Source URL",
    )?;
    let mut url = Url::parse(&value).map_err(|_| {
        CommandError::new(
            "knowledge_import_invalid",
            "Source URL must be a valid http or https URL.",
        )
    })?;
    if !matches!(url.scheme(), "http" | "https")
        || !url.username().is_empty()
        || url.password().is_some()
        || url.host_str().is_none()
    {
        return Err(CommandError::new(
            "knowledge_import_invalid",
            "Source URL must be an http or https URL without credentials.",
        ));
    }
    url.set_fragment(None);
    Ok(url.to_string())
}

fn clean_string(value: &str, max_bytes: usize, code: &str, name: &str) -> CommandResult<String> {
    let normalized = value.replace("\r\n", "\n").replace('\r', "\n");
    if normalized.len() > max_bytes {
        return Err(limit_error(code, &format!("{name} is too large.")));
    }
    if normalized
        .chars()
        .any(|character| character.is_control() && character != '\n' && character != '\t')
    {
        return Err(CommandError::new(
            code,
            format!("{name} contains unsupported control characters."),
        ));
    }
    Ok(normalized)
}

/// Bodies and queries retain LF/tab as useful text formatting.  Identifiers,
/// provenance, URLs, and paths are deliberately single-line metadata.
fn clean_single_line(
    value: &str,
    max_bytes: usize,
    code: &str,
    name: &str,
) -> CommandResult<String> {
    let cleaned = clean_string(value, max_bytes, code, name)?;
    if cleaned.contains('\n') || cleaned.contains('\t') {
        return Err(CommandError::new(
            code,
            format!("{name} must not contain line breaks or tabs."),
        ));
    }
    Ok(cleaned)
}

fn validate_item_id(item_id: &str) -> CommandResult<()> {
    let parsed = Uuid::parse_str(item_id).map_err(|_| {
        CommandError::new(
            "knowledge_item_invalid",
            "Knowledge item identifier is invalid.",
        )
    })?;
    if parsed.hyphenated().to_string() != item_id {
        return Err(CommandError::new(
            "knowledge_item_invalid",
            "Knowledge item identifier is invalid.",
        ));
    }
    Ok(())
}

fn not_found() -> CommandError {
    CommandError::new("knowledge_item_not_found", "Knowledge item was not found.")
}
fn limit_error(code: &str, message: &str) -> CommandError {
    CommandError::new(code, message)
}
fn now_epoch_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
fn sha256_hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn deserialize_bool_or_default<'de, D>(deserializer: D) -> Result<bool, D::Error>
where
    D: Deserializer<'de>,
{
    Ok(Option::<bool>::deserialize(deserializer)?.unwrap_or(false))
}

#[derive(Clone, Debug)]
struct ValidatedArchive {
    format: String,
    bytes: Vec<u8>,
    embedded_resource_count: Option<u32>,
    missing_resource_count: Option<u32>,
    was_truncated: bool,
    sha256: String,
}

impl ValidatedArchive {
    fn metadata(&self) -> KnowledgeArchiveMetadata {
        KnowledgeArchiveMetadata {
            format: self.format.clone(),
            byte_size: self.bytes.len() as u64,
            embedded_resource_count: self.embedded_resource_count,
            missing_resource_count: self.missing_resource_count,
            was_truncated: self.was_truncated,
            sha256: self.sha256.clone(),
        }
    }
}

fn validate_archive(archive: &BrowserCaptureArchive) -> CommandResult<ValidatedArchive> {
    if !matches!(archive.format.as_str(), "html" | "mhtml") || archive.bytes.is_empty() {
        return Err(CommandError::new(
            "knowledge_archive_invalid",
            "Offline archive has an invalid format.",
        ));
    }
    if archive.bytes.len() > MAX_ARCHIVE_BYTES {
        return Err(limit_error(
            "knowledge_archive_too_large",
            "Offline archive must not exceed 24 MiB.",
        ));
    }
    if !archive_bytes_match_format(&archive.format, &archive.bytes) {
        return Err(CommandError::new(
            "knowledge_archive_invalid",
            "Offline archive content does not match its declared format.",
        ));
    }
    if archive
        .embedded_resource_count
        .is_some_and(|value| value > 100_000)
        || archive
            .missing_resource_count
            .is_some_and(|value| value > 100_000)
    {
        return Err(CommandError::new(
            "knowledge_archive_invalid",
            "Offline archive resource counts are invalid.",
        ));
    }
    Ok(ValidatedArchive {
        format: archive.format.clone(),
        bytes: archive.bytes.clone(),
        embedded_resource_count: archive.embedded_resource_count,
        missing_resource_count: archive.missing_resource_count,
        was_truncated: archive.was_truncated.unwrap_or(false),
        sha256: sha256_hex(&archive.bytes),
    })
}

fn archive_bytes_match_format(format: &str, bytes: &[u8]) -> bool {
    match format {
        "html" => std::str::from_utf8(bytes).ok().is_some_and(|text| {
            let sample = text
                .trim_start_matches('\u{feff}')
                .chars()
                .take(16_384)
                .collect::<String>()
                .to_ascii_lowercase();
            sample.contains("<html") || sample.contains("<!doctype html")
        }),
        "mhtml" => {
            let sample = String::from_utf8_lossy(&bytes[..bytes.len().min(64 * 1024)]);
            let headers = sample
                .split_once("\r\n\r\n")
                .or_else(|| sample.split_once("\n\n"))
                .map(|(headers, _)| headers)
                .unwrap_or(&sample)
                .to_ascii_lowercase();
            headers
                .lines()
                .any(|line| line.trim() == "mime-version: 1.0")
                && headers.lines().any(|line| {
                    line.trim_start()
                        .starts_with("content-type: multipart/related")
                })
        }
        _ => false,
    }
}

fn total_unique_bytes(items: &BTreeMap<String, StoredItem>) -> u64 {
    let mut unique = BTreeMap::<&str, u64>::new();
    for item in items.values() {
        for revision in &item.revisions {
            unique
                .entry(&revision.content_sha256)
                .or_insert(revision.byte_size);
        }
    }
    unique.values().copied().sum()
}

fn total_unique_archive_bytes(items: &BTreeMap<String, StoredItem>) -> u64 {
    items
        .values()
        .flat_map(|item| item.revisions.iter())
        .filter_map(|revision| revision.archive.as_ref())
        .map(|archive| (archive.sha256.as_str(), archive.byte_size))
        .collect::<BTreeMap<_, _>>()
        .values()
        .copied()
        .sum()
}

fn archive_is_referenced(items: &BTreeMap<String, StoredItem>, digest: &str) -> bool {
    items.values().any(|item| {
        item.revisions.iter().any(|revision| {
            revision
                .archive
                .as_ref()
                .is_some_and(|archive| archive.sha256 == digest)
        })
    })
}

fn blob_is_referenced(items: &BTreeMap<String, StoredItem>, digest: &str) -> bool {
    items.values().any(|item| {
        item.revisions
            .iter()
            .any(|revision| revision.content_sha256 == digest)
    })
}

fn archive_capacity_allows(current_bytes: u64, additional_bytes: u64) -> bool {
    current_bytes.saturating_add(additional_bytes) <= MAX_ARCHIVE_LIBRARY_BYTES
}

fn bounded_feature_text(value: &str) -> String {
    if value.len() <= MAX_FEATURE_TEXT_BYTES {
        return value.into();
    }
    let end = value
        .char_indices()
        .take_while(|(index, _)| *index < MAX_FEATURE_TEXT_BYTES)
        .last()
        .map(|(index, character)| index + character.len_utf8())
        .unwrap_or(0);
    value[..end].into()
}

fn snippet_for(text: &str, query: &str) -> String {
    let lower_text = text.to_lowercase();
    let lower_query = query.to_lowercase();
    // Lowercasing can change a Unicode scalar's byte length.  Map a matched
    // byte offset back to a real boundary in the original string before
    // slicing so a surprising title/body cannot make search panic.
    let lowered_offset = lower_text.find(&lower_query).unwrap_or(0);
    let byte_start = text
        .char_indices()
        .take_while(|(index, _)| *index <= lowered_offset)
        .last()
        .map(|(index, _)| index)
        .unwrap_or(0);
    let start = text[..byte_start]
        .char_indices()
        .rev()
        .nth(80)
        .map(|(index, _)| index)
        .unwrap_or(0);
    let end = text[start..]
        .char_indices()
        .nth(MAX_SNIPPET_CHARS)
        .map(|(index, _)| start + index)
        .unwrap_or(text.len());
    text[start..end].replace('\n', " ").trim().to_string()
}

fn ensure_private_directory(path: &Path, code: &str) -> CommandResult<()> {
    use std::os::unix::fs::DirBuilderExt;
    match fs::symlink_metadata(path) {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            let mut builder = fs::DirBuilder::new();
            builder.mode(0o700);
            if let Err(e) = builder.create(path) {
                if e.kind() != std::io::ErrorKind::AlreadyExists {
                    return Err(CommandError::io(
                        code,
                        "Unable to create knowledge storage",
                        e,
                    ));
                }
            }
        }
        Err(e) => {
            return Err(CommandError::io(
                code,
                "Unable to inspect knowledge storage",
                e,
            ))
        }
    }
    let m = fs::symlink_metadata(path)
        .map_err(|e| CommandError::io(code, "Unable to inspect knowledge storage", e))?;
    if !m.is_dir()
        || m.file_type().is_symlink()
        || m.mode() & 0o7777 != 0o700
        || m.uid() != unsafe { libc::geteuid() }
    {
        return Err(CommandError::new(
            code,
            "Existing knowledge storage is not private. No permission repair was performed.",
        ));
    }
    Ok(())
}

fn load_manifest(storage: &Storage) -> CommandResult<LoadedManifest> {
    let metadata = match fs::symlink_metadata(&storage.manifest_file) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok((BTreeMap::new(), BTreeMap::new(), BTreeMap::new(), false))
        }
        Err(error) => {
            return Err(CommandError::io(
                "knowledge_manifest_invalid",
                "Unable to inspect knowledge manifest",
                error,
            ))
        }
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() || metadata.len() > 2 * 1024 * 1024
    {
        return Err(CommandError::new(
            "knowledge_manifest_invalid",
            "Knowledge manifest is not a safe regular file.",
        ));
    }
    let manifest: Manifest = serde_json::from_slice(&read_regular_file(
        &storage.manifest_file,
        2 * 1024 * 1024,
        "knowledge_manifest_invalid",
    )?)
    .map_err(|_| {
        CommandError::new(
            "knowledge_manifest_invalid",
            "Knowledge manifest is malformed.",
        )
    })?;
    if !(1..=SCHEMA_VERSION).contains(&manifest.schema_version) || manifest.items.len() > MAX_ITEMS
    {
        return Err(CommandError::new(
            "knowledge_manifest_invalid",
            "Knowledge manifest has an unsupported or unsafe shape.",
        ));
    }
    let needs_migration = manifest.schema_version < SCHEMA_VERSION;
    let mut folders = BTreeMap::new();
    if manifest.folders.len() > MAX_FOLDERS {
        return Err(CommandError::new(
            "knowledge_manifest_invalid",
            "Knowledge manifest exceeds the folder limit.",
        ));
    }
    for folder in manifest.folders {
        validate_item_id(&folder.folder_id).map_err(|_| {
            CommandError::new(
                "knowledge_manifest_invalid",
                "Knowledge manifest contains an invalid folder.",
            )
        })?;
        let name = validate_folder_name(&folder.name).map_err(|_| {
            CommandError::new(
                "knowledge_manifest_invalid",
                "Knowledge manifest contains an invalid folder.",
            )
        })?;
        if folder.name != name
            || folders.values().any(|other: &KnowledgeFolder| {
                folder_name_key(&other.name) == folder_name_key(&folder.name)
            })
            || folders.insert(folder.folder_id.clone(), folder).is_some()
        {
            return Err(CommandError::new(
                "knowledge_manifest_invalid",
                "Knowledge manifest has duplicate or invalid folders.",
            ));
        }
    }
    let mut items = BTreeMap::new();
    for mut stored in manifest.items {
        if needs_migration {
            // Versions 1–3 had no remote-AI capability. Treat even a hand-added field as false.
            stored.summary.allows_remote_ai_use = false;
        }
        migrate_stored_item(&mut stored);
        validate_stored_item(&stored)?;
        if let Some(folder_id) = &stored.summary.folder_id {
            if !folders.contains_key(folder_id) {
                return Err(CommandError::new(
                    "knowledge_manifest_invalid",
                    "Knowledge item references an unknown folder.",
                ));
            }
        }
        if items
            .insert(stored.summary.item_id.clone(), stored)
            .is_some()
        {
            return Err(CommandError::new(
                "knowledge_manifest_invalid",
                "Knowledge manifest has duplicate item identifiers.",
            ));
        }
    }
    if total_unique_bytes(&items) > MAX_LIBRARY_BYTES {
        return Err(CommandError::new(
            "knowledge_manifest_invalid",
            "Knowledge manifest exceeds the library limit.",
        ));
    }
    if total_unique_archive_bytes(&items) > MAX_ARCHIVE_LIBRARY_BYTES {
        return Err(CommandError::new(
            "knowledge_manifest_invalid",
            "Knowledge manifest exceeds the offline archive limit.",
        ));
    }
    for stored in items.values() {
        for revision in &stored.revisions {
            let text = read_blob(storage, &revision.content_sha256)?;
            if text.len() as u64 != revision.byte_size
                || sha256_hex(text.as_bytes()) != revision.content_sha256
            {
                return Err(CommandError::new(
                    "knowledge_manifest_invalid",
                    "Knowledge content does not match its manifest.",
                ));
            }
            if let Some(archive) = &revision.archive {
                let bytes = read_archive(storage, &archive.sha256)?;
                if bytes.len() as u64 != archive.byte_size || sha256_hex(&bytes) != archive.sha256 {
                    return Err(CommandError::new(
                        "knowledge_manifest_invalid",
                        "Offline archive does not match its manifest.",
                    ));
                }
                if !archive_bytes_match_format(&archive.format, &bytes) {
                    return Err(CommandError::new(
                        "knowledge_manifest_invalid",
                        "Offline archive content does not match its manifest format.",
                    ));
                }
            }
        }
    }
    let mut completed_operations = BTreeMap::new();
    let threshold = now_epoch_seconds().saturating_sub(COMPLETED_OPERATION_TTL_SECONDS);
    for operation in manifest.completed_operations {
        if operation.completed_at_epoch_seconds < threshold {
            continue;
        }
        let mut operation = operation;
        if needs_migration {
            operation.receipt.allows_remote_ai_use = false;
        }
        validate_completed_operation(&operation, &folders)?;
        if completed_operations
            .insert(operation.operation_id.clone(), operation)
            .is_some()
        {
            return Err(CommandError::new(
                "knowledge_manifest_invalid",
                "Knowledge manifest contains an invalid completed operation.",
            ));
        }
    }
    if completed_operations.len() > MAX_COMPLETED_OPERATIONS {
        return Err(CommandError::new(
            "knowledge_manifest_invalid",
            "Knowledge manifest exceeds the completed operation limit.",
        ));
    }
    Ok((items, folders, completed_operations, needs_migration))
}

fn validate_completed_operation(
    operation: &CompletedOperation,
    folders: &BTreeMap<String, KnowledgeFolder>,
) -> CommandResult<()> {
    let invalid = || {
        CommandError::new(
            "knowledge_manifest_invalid",
            "Knowledge manifest contains an invalid completed operation.",
        )
    };
    validate_item_id(&operation.operation_id).map_err(|_| invalid())?;
    validate_item_id(&operation.receipt.document_id).map_err(|_| invalid())?;
    let title = clean_single_line(
        &operation.receipt.title,
        MAX_TITLE_BYTES,
        "knowledge_manifest_invalid",
        "Completed operation title",
    )
    .map_err(|_| invalid())?;
    let maximum_size = if operation.receipt.archive_type == "none" {
        MAX_ITEM_BYTES as u64
    } else {
        MAX_ARCHIVE_BYTES as u64
    };
    if title != operation.receipt.title
        || !is_sha256_hex(&operation.fingerprint)
        || operation.fingerprint != operation.fingerprint.to_ascii_lowercase()
        || !matches!(
            operation.receipt.action.as_str(),
            "inserted" | "new-version" | "moved" | "copied"
        )
        || !matches!(
            operation.receipt.archive_type.as_str(),
            "none" | "html" | "mhtml"
        )
        || operation.receipt.file_size_bytes == 0
        || operation.receipt.file_size_bytes > maximum_size
        || operation.receipt.replayed
        || operation.receipt.saved_at_epoch_seconds == 0
        || operation.completed_at_epoch_seconds == 0
        || operation.receipt.saved_at_epoch_seconds > operation.completed_at_epoch_seconds
        || operation
            .receipt
            .folder_id
            .as_ref()
            .is_some_and(|folder_id| !folders.contains_key(folder_id))
    {
        return Err(invalid());
    }
    Ok(())
}

fn migrate_stored_item(stored: &mut StoredItem) {
    if stored.revisions.is_empty() {
        let revision_number = stored.summary.revision_number.max(1);
        stored.revisions.push(KnowledgeRevisionSummary {
            revision_number,
            content_sha256: stored.content_sha256.clone(),
            byte_size: stored.summary.byte_size,
            created_at_epoch_seconds: stored
                .summary
                .updated_at_epoch_seconds
                .max(stored.summary.created_at_epoch_seconds),
            archive: stored.summary.archive.clone(),
        });
    }
    let latest = stored
        .revisions
        .last()
        .expect("migration creates a revision")
        .clone();
    stored.content_sha256 = latest.content_sha256.clone();
    stored.summary.byte_size = latest.byte_size;
    stored.summary.archive = latest.archive;
    stored.summary.revision_number = latest.revision_number;
    stored.summary.revision_count = stored.revisions.len() as u32;
}

fn validate_stored_item(stored: &StoredItem) -> CommandResult<()> {
    validate_item_id(&stored.summary.item_id)?;
    let _ = clean_single_line(
        &stored.summary.title,
        MAX_TITLE_BYTES,
        "knowledge_manifest_invalid",
        "Title",
    )?;
    let _ = clean_single_line(
        &stored.summary.source_name,
        MAX_SOURCE_NAME_BYTES,
        "knowledge_manifest_invalid",
        "Source name",
    )?;
    if stored.summary.byte_size as usize > MAX_ITEM_BYTES
        || stored.summary.reading_progress_percent > 100
        || !is_sha256_hex(&stored.content_sha256)
        || stored.revisions.is_empty()
        || stored.revisions.len() > MAX_REVISIONS_PER_ITEM
    {
        return Err(CommandError::new(
            "knowledge_manifest_invalid",
            "Knowledge manifest contains an invalid item.",
        ));
    }
    let mut previous_revision = 0;
    for revision in &stored.revisions {
        if revision.revision_number == 0
            || revision.revision_number <= previous_revision
            || revision.byte_size as usize > MAX_ITEM_BYTES
            || !is_sha256_hex(&revision.content_sha256)
        {
            return Err(CommandError::new(
                "knowledge_manifest_invalid",
                "Knowledge manifest contains an invalid revision.",
            ));
        }
        previous_revision = revision.revision_number;
        if let Some(archive) = &revision.archive {
            validate_archive_metadata(archive)?;
        }
    }
    let latest = stored
        .revisions
        .last()
        .expect("validated nonempty revisions");
    if latest.content_sha256 != stored.content_sha256
        || latest.byte_size != stored.summary.byte_size
        || latest.archive != stored.summary.archive
        || latest.revision_number != stored.summary.revision_number
        || stored.summary.revision_count != stored.revisions.len() as u32
    {
        return Err(CommandError::new(
            "knowledge_manifest_invalid",
            "Knowledge manifest's current revision is inconsistent.",
        ));
    }
    match (&stored.summary.source_kind, &stored.summary.source_url) {
        (KnowledgeSourceKind::Web, Some(value)) => {
            validate_web_url(value)?;
        }
        (KnowledgeSourceKind::Web, None) => {
            return Err(CommandError::new(
                "knowledge_manifest_invalid",
                "Web item has no URL.",
            ))
        }
        (KnowledgeSourceKind::Pdf | KnowledgeSourceKind::Text, None) => {}
        _ => {
            return Err(CommandError::new(
                "knowledge_manifest_invalid",
                "Non-web item has a URL.",
            ))
        }
    }
    if let Some(archive) = &stored.summary.archive {
        validate_archive_metadata(archive)?;
    }
    Ok(())
}

fn validate_archive_metadata(archive: &KnowledgeArchiveMetadata) -> CommandResult<()> {
    if !matches!(archive.format.as_str(), "html" | "mhtml")
        || archive.byte_size == 0
        || archive.byte_size as usize > MAX_ARCHIVE_BYTES
        || !is_sha256_hex(&archive.sha256)
        || archive
            .embedded_resource_count
            .is_some_and(|value| value > 100_000)
        || archive
            .missing_resource_count
            .is_some_and(|value| value > 100_000)
    {
        return Err(CommandError::new(
            "knowledge_manifest_invalid",
            "Knowledge manifest contains an invalid offline archive.",
        ));
    }
    Ok(())
}

fn is_sha256_hex(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn read_regular_file(path: &Path, maximum: u64, code: &str) -> CommandResult<Vec<u8>> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|error| CommandError::io(code, "Unable to safely open knowledge data", error))?;
    let metadata = file
        .metadata()
        .map_err(|error| CommandError::io(code, "Unable to inspect knowledge data", error))?;
    if !metadata.is_file() || metadata.len() > maximum || metadata.mode() & 0o077 != 0 {
        return Err(CommandError::new(
            code,
            "Knowledge data is not a private regular file.",
        ));
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.read_to_end(&mut bytes)
        .map_err(|error| CommandError::io(code, "Unable to read knowledge data", error))?;
    if bytes.len() as u64 != metadata.len() {
        return Err(CommandError::new(
            code,
            "Knowledge data changed while it was being read.",
        ));
    }
    Ok(bytes)
}

fn blob_path(storage: &Storage, digest: &str) -> CommandResult<PathBuf> {
    if !is_sha256_hex(digest) {
        return Err(CommandError::new(
            "knowledge_content_invalid",
            "Knowledge content hash is invalid.",
        ));
    }
    Ok(storage.blobs_directory.join(digest))
}

fn read_blob(storage: &Storage, digest: &str) -> CommandResult<String> {
    let bytes = read_regular_file(
        &blob_path(storage, digest)?,
        MAX_ITEM_BYTES as u64,
        "knowledge_content_invalid",
    )?;
    if sha256_hex(&bytes) != digest {
        return Err(CommandError::new(
            "knowledge_content_invalid",
            "Knowledge content does not match its content address.",
        ));
    }
    String::from_utf8(bytes).map_err(|_| {
        CommandError::new(
            "knowledge_content_invalid",
            "Knowledge content is not valid UTF-8.",
        )
    })
}

fn write_blob_if_absent(storage: &Storage, digest: &str, bytes: &[u8]) -> CommandResult<()> {
    let path = blob_path(storage, digest)?;
    match fs::symlink_metadata(&path) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() || !metadata.is_file() {
                return Err(CommandError::new(
                    "knowledge_content_invalid",
                    "Knowledge object is not a safe regular file.",
                ));
            }
            let current =
                read_regular_file(&path, MAX_ITEM_BYTES as u64, "knowledge_content_invalid")?;
            if current != bytes {
                return Err(CommandError::new(
                    "knowledge_content_invalid",
                    "Knowledge object hash collision or corruption detected.",
                ));
            }
            return Ok(());
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(CommandError::io(
                "knowledge_content_invalid",
                "Unable to inspect knowledge object",
                error,
            ))
        }
    }
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&path)
        .map_err(|error| {
            CommandError::io(
                "knowledge_content_write_failed",
                "Unable to create knowledge object",
                error,
            )
        })?;
    file.write_all(bytes)
        .and_then(|_| file.sync_all())
        .map_err(|error| {
            CommandError::io(
                "knowledge_content_write_failed",
                "Unable to write knowledge object",
                error,
            )
        })?;
    sync_directory(&storage.blobs_directory, "knowledge_content_write_failed")
}

fn remove_blob(storage: &Storage, digest: &str) -> CommandResult<()> {
    let path = blob_path(storage, digest)?;
    match fs::symlink_metadata(&path) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
            Err(CommandError::new(
                "knowledge_content_invalid",
                "Knowledge object is not a safe regular file.",
            ))
        }
        Ok(_) => {
            fs::remove_file(&path).map_err(|error| {
                CommandError::io(
                    "knowledge_content_delete_failed",
                    "Unable to remove knowledge object",
                    error,
                )
            })?;
            sync_directory(&storage.blobs_directory, "knowledge_content_delete_failed")
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(CommandError::io(
            "knowledge_content_delete_failed",
            "Unable to inspect knowledge object",
            error,
        )),
    }
}

fn archive_path(storage: &Storage, digest: &str) -> CommandResult<PathBuf> {
    if !is_sha256_hex(digest) {
        return Err(CommandError::new(
            "knowledge_archive_invalid",
            "Offline archive hash is invalid.",
        ));
    }
    Ok(storage.archives_directory.join(digest))
}

fn read_archive(storage: &Storage, digest: &str) -> CommandResult<Vec<u8>> {
    let bytes = read_regular_file(
        &archive_path(storage, digest)?,
        MAX_ARCHIVE_BYTES as u64,
        "knowledge_archive_invalid",
    )?;
    if sha256_hex(&bytes) != digest {
        return Err(CommandError::new(
            "knowledge_archive_invalid",
            "Offline archive does not match its content address.",
        ));
    }
    Ok(bytes)
}

fn write_archive_if_absent(storage: &Storage, digest: &str, bytes: &[u8]) -> CommandResult<()> {
    let path = archive_path(storage, digest)?;
    match fs::symlink_metadata(&path) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() || !metadata.is_file() {
                return Err(CommandError::new(
                    "knowledge_archive_invalid",
                    "Offline archive object is not a safe regular file.",
                ));
            }
            if read_archive(storage, digest)? != bytes {
                return Err(CommandError::new(
                    "knowledge_archive_invalid",
                    "Offline archive hash collision or corruption detected.",
                ));
            }
            return Ok(());
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(CommandError::io(
                "knowledge_archive_invalid",
                "Unable to inspect offline archive",
                error,
            ))
        }
    }
    let mut temporary = NamedTempFile::new_in(&storage.archives_directory).map_err(|error| {
        CommandError::io(
            "knowledge_archive_write_failed",
            "Unable to create temporary offline archive",
            error,
        )
    })?;
    temporary
        .as_file_mut()
        .set_permissions(fs::Permissions::from_mode(0o600))
        .map_err(|error| {
            CommandError::io(
                "knowledge_archive_write_failed",
                "Unable to secure temporary offline archive",
                error,
            )
        })?;
    temporary
        .as_file_mut()
        .write_all(bytes)
        .and_then(|_| temporary.as_file_mut().sync_all())
        .map_err(|error| {
            CommandError::io(
                "knowledge_archive_write_failed",
                "Unable to write offline archive",
                error,
            )
        })?;
    temporary.persist_noclobber(&path).map_err(|error| {
        if error.error.kind() == std::io::ErrorKind::AlreadyExists {
            CommandError::new(
                "knowledge_archive_invalid",
                "Offline archive destination appeared unexpectedly.",
            )
        } else {
            CommandError::io(
                "knowledge_archive_write_failed",
                "Unable to atomically save offline archive",
                error.error,
            )
        }
    })?;
    sync_directory(
        &storage.archives_directory,
        "knowledge_archive_write_failed",
    )
}

fn remove_archive(storage: &Storage, digest: &str) -> CommandResult<()> {
    let path = archive_path(storage, digest)?;
    match fs::symlink_metadata(&path) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
            Err(CommandError::new(
                "knowledge_archive_invalid",
                "Offline archive object is not a safe regular file.",
            ))
        }
        Ok(_) => {
            fs::remove_file(&path).map_err(|error| {
                CommandError::io(
                    "knowledge_archive_delete_failed",
                    "Unable to remove offline archive",
                    error,
                )
            })?;
            sync_directory(
                &storage.archives_directory,
                "knowledge_archive_delete_failed",
            )
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(CommandError::io(
            "knowledge_archive_delete_failed",
            "Unable to inspect offline archive",
            error,
        )),
    }
}

fn garbage_collect_unreferenced_blobs(
    storage: &Storage,
    items: &BTreeMap<String, StoredItem>,
) -> CommandResult<usize> {
    let referenced = items
        .values()
        .flat_map(|item| {
            item.revisions
                .iter()
                .map(|revision| revision.content_sha256.as_str())
        })
        .collect::<BTreeSet<_>>();
    let entries = fs::read_dir(&storage.blobs_directory).map_err(|error| {
        CommandError::io(
            "knowledge_cleanup_failed",
            "Unable to inspect private knowledge objects",
            error,
        )
    })?;
    let mut removed = 0usize;
    for entry in entries {
        let entry = entry.map_err(|error| {
            CommandError::io(
                "knowledge_cleanup_failed",
                "Unable to inspect a private knowledge object",
                error,
            )
        })?;
        let name = entry.file_name().into_string().map_err(|_| {
            CommandError::new(
                "knowledge_cleanup_failed",
                "Private knowledge storage contains an invalid object name.",
            )
        })?;
        if referenced.contains(name.as_str()) {
            continue;
        }
        let metadata = fs::symlink_metadata(entry.path()).map_err(|error| {
            CommandError::io(
                "knowledge_cleanup_failed",
                "Unable to inspect an unreferenced knowledge object",
                error,
            )
        })?;
        if !is_sha256_hex(&name) || metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err(CommandError::new(
                "knowledge_cleanup_failed",
                "Private knowledge storage contains an unsafe unreferenced object.",
            ));
        }
        fs::remove_file(entry.path()).map_err(|error| {
            CommandError::io(
                "knowledge_cleanup_failed",
                "Unable to remove an unreferenced knowledge object",
                error,
            )
        })?;
        removed += 1;
    }
    if removed > 0 {
        sync_directory(&storage.blobs_directory, "knowledge_cleanup_failed")?;
    }
    Ok(removed)
}

fn garbage_collect_unreferenced_archives(
    storage: &Storage,
    items: &BTreeMap<String, StoredItem>,
) -> CommandResult<usize> {
    let referenced = items
        .values()
        .flat_map(|item| {
            item.revisions
                .iter()
                .filter_map(|revision| revision.archive.as_ref())
        })
        .map(|archive| archive.sha256.as_str())
        .collect::<BTreeSet<_>>();
    let entries = fs::read_dir(&storage.archives_directory).map_err(|error| {
        CommandError::io(
            "knowledge_cleanup_failed",
            "Unable to inspect private offline archives",
            error,
        )
    })?;
    let mut removed = 0usize;
    for entry in entries {
        let entry = entry.map_err(|error| {
            CommandError::io(
                "knowledge_cleanup_failed",
                "Unable to inspect an offline archive",
                error,
            )
        })?;
        let name = entry.file_name().into_string().map_err(|_| {
            CommandError::new(
                "knowledge_cleanup_failed",
                "Private knowledge storage contains an invalid archive name.",
            )
        })?;
        if referenced.contains(name.as_str()) {
            continue;
        }
        let metadata = fs::symlink_metadata(entry.path()).map_err(|error| {
            CommandError::io(
                "knowledge_cleanup_failed",
                "Unable to inspect an unreferenced offline archive",
                error,
            )
        })?;
        if !is_sha256_hex(&name) || metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err(CommandError::new(
                "knowledge_cleanup_failed",
                "Private knowledge storage contains an unsafe unreferenced archive.",
            ));
        }
        fs::remove_file(entry.path()).map_err(|error| {
            CommandError::io(
                "knowledge_cleanup_failed",
                "Unable to remove an unreferenced offline archive",
                error,
            )
        })?;
        removed += 1;
    }
    if removed > 0 {
        sync_directory(&storage.archives_directory, "knowledge_cleanup_failed")?;
    }
    Ok(removed)
}

fn write_manifest(storage: &Storage, state: &LibraryState) -> CommandResult<()> {
    if let Ok(metadata) = fs::symlink_metadata(&storage.manifest_file) {
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err(CommandError::new(
                "knowledge_manifest_invalid",
                "Knowledge manifest is not a safe regular file.",
            ));
        }
    }
    let manifest = Manifest {
        schema_version: SCHEMA_VERSION,
        items: state.items.values().cloned().collect(),
        folders: state.folders.values().cloned().collect(),
        completed_operations: state.completed_operations.values().cloned().collect(),
    };
    let encoded = serde_json::to_vec(&manifest).map_err(|_| {
        CommandError::new(
            "knowledge_manifest_write_failed",
            "Unable to encode knowledge manifest.",
        )
    })?;
    let mut temporary = NamedTempFile::new_in(&storage.directory).map_err(|error| {
        CommandError::io(
            "knowledge_manifest_write_failed",
            "Unable to create temporary knowledge manifest",
            error,
        )
    })?;
    temporary
        .as_file_mut()
        .set_permissions(fs::Permissions::from_mode(0o600))
        .map_err(|error| {
            CommandError::io(
                "knowledge_manifest_write_failed",
                "Unable to secure temporary knowledge manifest",
                error,
            )
        })?;
    temporary
        .as_file_mut()
        .write_all(&encoded)
        .and_then(|_| temporary.as_file_mut().sync_all())
        .map_err(|error| {
            CommandError::io(
                "knowledge_manifest_write_failed",
                "Unable to write knowledge manifest",
                error,
            )
        })?;
    temporary.persist(&storage.manifest_file).map_err(|error| {
        CommandError::io(
            "knowledge_manifest_write_failed",
            "Unable to atomically replace knowledge manifest",
            error.error,
        )
    })?;
    fs::set_permissions(&storage.manifest_file, fs::Permissions::from_mode(0o600)).map_err(
        |error| {
            CommandError::io(
                "knowledge_manifest_write_failed",
                "Unable to secure knowledge manifest",
                error,
            )
        },
    )?;
    sync_directory(&storage.directory, "knowledge_manifest_write_failed")
}

fn sync_directory(path: &Path, code: &str) -> CommandResult<()> {
    File::open(path)
        .and_then(|file| file.sync_all())
        .map_err(|error| CommandError::io(code, "Unable to flush knowledge storage", error))
}

fn validate_relative_markdown_path(value: &str) -> CommandResult<String> {
    let value = clean_single_line(
        value,
        MAX_RELATIVE_PATH_BYTES,
        "knowledge_export_invalid",
        "Export path",
    )?;
    let path = Path::new(&value);
    if value.is_empty()
        || path.extension().and_then(|extension| extension.to_str()) != Some("md")
        || path
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
        || path.components().any(|component| {
            matches!(component, Component::Normal(value) if value == std::ffi::OsStr::new(".git"))
        })
    {
        return Err(CommandError::new(
            "knowledge_export_invalid",
            "Export path must be a relative, normalized .md path.",
        ));
    }
    Ok(path.to_string_lossy().into_owned())
}

fn validate_relative_archive_path(value: &str, format: &str) -> CommandResult<String> {
    let value = clean_single_line(
        value,
        MAX_RELATIVE_PATH_BYTES,
        "knowledge_archive_export_invalid",
        "Archive export path",
    )?;
    let path = Path::new(&value);
    let expected = match format {
        "html" => "html",
        "mhtml" => "mhtml",
        _ => {
            return Err(CommandError::new(
                "knowledge_archive_export_invalid",
                "Archive format is invalid.",
            ))
        }
    };
    if value.is_empty() || path.extension().and_then(|extension| extension.to_str()) != Some(expected)
        || path.components().any(|component| !matches!(component, Component::Normal(_)))
        || path.components().any(|component| matches!(component, Component::Normal(part) if part == std::ffi::OsStr::new(".git")))
    {
        return Err(CommandError::new("knowledge_archive_export_invalid", "Archive export path must be a relative, normalized path with the matching extension."));
    }
    Ok(path.to_string_lossy().into_owned())
}

fn validate_repository_root(root: &Path) -> CommandResult<PathBuf> {
    let metadata = fs::symlink_metadata(root).map_err(|error| {
        CommandError::io(
            "knowledge_export_invalid",
            "Unable to inspect repository root",
            error,
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(CommandError::new(
            "knowledge_export_invalid",
            "Repository root must be a real directory.",
        ));
    }
    fs::canonicalize(root).map_err(|error| {
        CommandError::io(
            "knowledge_export_invalid",
            "Unable to canonicalize repository root",
            error,
        )
    })
}

fn validate_export_destination(root: &Path, relative_path: &str) -> CommandResult<PathBuf> {
    let path = root.join(relative_path);
    let relative_parent = Path::new(relative_path)
        .parent()
        .unwrap_or_else(|| Path::new(""));
    let mut cursor = root.to_path_buf();
    let mut missing_parent = false;
    for component in relative_parent.components() {
        if let Component::Normal(part) = component {
            cursor.push(part);
            if !missing_parent {
                match fs::symlink_metadata(&cursor) {
                    Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
                        return Err(CommandError::new(
                            "knowledge_export_invalid",
                            "Export path cannot traverse a symlink or non-directory.",
                        ))
                    }
                    Ok(_) => {}
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                        missing_parent = true
                    }
                    Err(error) => {
                        return Err(CommandError::io(
                            "knowledge_export_invalid",
                            "Unable to inspect export parent directory",
                            error,
                        ))
                    }
                }
            }
        }
    }
    match fs::symlink_metadata(&path) {
        Ok(_) => Err(CommandError::new(
            "knowledge_export_conflict",
            "Export will not overwrite an existing file.",
        )),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(path),
        Err(error) => Err(CommandError::io(
            "knowledge_export_invalid",
            "Unable to inspect export destination",
            error,
        )),
    }
}

fn export_parent_is_missing(root: &Path, relative_path: &str) -> CommandResult<bool> {
    let parent = root
        .join(relative_path)
        .parent()
        .expect("relative export has parent")
        .to_path_buf();
    match fs::symlink_metadata(parent) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
            Err(CommandError::new(
                "knowledge_export_invalid",
                "Export path cannot traverse a symlink or non-directory.",
            ))
        }
        Ok(_) => Ok(false),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(true),
        Err(error) => Err(CommandError::io(
            "knowledge_export_invalid",
            "Unable to inspect export parent directory",
            error,
        )),
    }
}

fn ensure_export_parent(root: &Path, relative_path: &str) -> CommandResult<()> {
    let relative_parent = Path::new(relative_path)
        .parent()
        .unwrap_or_else(|| Path::new(""));
    let mut cursor = root.to_path_buf();
    for component in relative_parent.components() {
        let Component::Normal(part) = component else {
            continue;
        };
        cursor.push(part);
        match fs::symlink_metadata(&cursor) {
            Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
                return Err(CommandError::new(
                    "knowledge_export_invalid",
                    "Export path cannot traverse a symlink or non-directory.",
                ))
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                match fs::create_dir(&cursor) {
                    Ok(()) => {}
                    Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
                    Err(error) => {
                        return Err(CommandError::io(
                            "knowledge_export_write_failed",
                            "Unable to create export parent directory",
                            error,
                        ))
                    }
                }
                let metadata = fs::symlink_metadata(&cursor).map_err(|error| {
                    CommandError::io(
                        "knowledge_export_write_failed",
                        "Unable to inspect export parent directory",
                        error,
                    )
                })?;
                if metadata.file_type().is_symlink() || !metadata.is_dir() {
                    return Err(CommandError::new(
                        "knowledge_export_invalid",
                        "Export path cannot traverse a symlink or non-directory.",
                    ));
                }
                fs::set_permissions(&cursor, fs::Permissions::from_mode(0o700)).map_err(
                    |error| {
                        CommandError::io(
                            "knowledge_export_write_failed",
                            "Unable to secure export parent directory",
                            error,
                        )
                    },
                )?;
            }
            Err(error) => {
                return Err(CommandError::io(
                    "knowledge_export_invalid",
                    "Unable to inspect export parent directory",
                    error,
                ))
            }
        }
    }
    Ok(())
}

fn purge_expired_plans(state: &mut LibraryState) {
    let now = now_epoch_seconds();
    state
        .export_plans
        .retain(|_, plan| plan.public.expires_at_epoch_seconds >= now);
    state
        .archive_export_plans
        .retain(|_, plan| plan.public.expires_at_epoch_seconds >= now);
}

fn render_export_markdown(summary: &KnowledgeItemSummary, text: &str) -> String {
    let mut output = format!("# {}\n\n", summary.title);
    output.push_str(&format!("_Imported from {}_", summary.source_name));
    if let Some(url) = &summary.source_url {
        output.push_str(&format!(" ([source]({url}))"));
    }
    output.push_str("\n\n");
    output.push_str(text);
    if !output.ends_with('\n') {
        output.push('\n');
    }
    output
}

fn write_new_export(root: &Path, relative_path: &str, bytes: &[u8]) -> CommandResult<()> {
    ensure_export_parent(root, relative_path)?;
    let path = validate_export_destination(root, relative_path)?;
    let parent = path.parent().expect("validated path has parent");
    let mut temporary = NamedTempFile::new_in(parent).map_err(|error| {
        CommandError::io(
            "knowledge_export_write_failed",
            "Unable to create temporary export",
            error,
        )
    })?;
    temporary
        .as_file_mut()
        .set_permissions(fs::Permissions::from_mode(0o600))
        .map_err(|error| {
            CommandError::io(
                "knowledge_export_write_failed",
                "Unable to secure temporary export",
                error,
            )
        })?;
    temporary
        .as_file_mut()
        .write_all(bytes)
        .and_then(|_| temporary.as_file_mut().sync_all())
        .map_err(|error| {
            CommandError::io(
                "knowledge_export_write_failed",
                "Unable to write export",
                error,
            )
        })?;
    temporary.persist_noclobber(&path).map_err(|error| {
        CommandError::io(
            "knowledge_export_conflict",
            "Export destination appeared before confirmation",
            error.error,
        )
    })?;
    sync_directory(parent, "knowledge_export_write_failed")
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn request(text: &str) -> KnowledgeImportRequest {
        KnowledgeImportRequest {
            source_kind: KnowledgeSourceKind::Text,
            title: "Notes".into(),
            source_name: "Test".into(),
            source_url: None,
            text: text.into(),
            allows_local_semantic_index: true,
            allows_remote_ai_use: false,
        }
    }

    fn html_archive(body: &str) -> BrowserCaptureArchive {
        BrowserCaptureArchive {
            format: "html".into(),
            bytes: format!("<!doctype html><html><body>{body}</body></html>").into_bytes(),
            embedded_resource_count: Some(1),
            missing_resource_count: Some(0),
            was_truncated: Some(false),
        }
    }

    fn browser_request(operation_id: String, text: &str) -> BrowserKnowledgeImportRequest {
        BrowserKnowledgeImportRequest {
            operation_id,
            source_url: "https://example.test/article#fragment".into(),
            title: "Captured article".into(),
            source_name: "example.test".into(),
            text: text.into(),
            allows_local_semantic_index: true,
            allows_remote_ai_use: false,
            folder_id: None,
            new_folder_name: None,
            duplicate_resolution: None,
        }
    }

    #[test]
    fn browser_conflicts_versions_folders_and_operation_replays_are_atomic() {
        let store = KnowledgeLibraryStore::default();
        let operation_id = Uuid::new_v4().to_string();
        let first = store
            .import_browser_capture(browser_request(operation_id.clone(), "first body"), None)
            .unwrap();
        let document_id = match first {
            BrowserKnowledgeImportOutcome::Imported { receipt } => receipt.document_id,
            _ => panic!("first import must insert"),
        };
        let conflict = store
            .import_browser_capture(
                browser_request(Uuid::new_v4().to_string(), "second body"),
                None,
            )
            .unwrap();
        assert!(matches!(
            conflict,
            BrowserKnowledgeImportOutcome::Conflict { .. }
        ));
        assert_eq!(store.status().unwrap().item_count, 1);

        let mut version = browser_request(Uuid::new_v4().to_string(), "first body");
        version.duplicate_resolution = Some("save-new-version".into());
        version.new_folder_name = Some("  Reading  ".into());
        let receipt = match store.import_browser_capture(version, None).unwrap() {
            BrowserKnowledgeImportOutcome::Imported { receipt } => receipt,
            _ => panic!("resolution must import"),
        };
        assert_eq!(receipt.action, "new-version");
        assert_eq!(store.get(&document_id).unwrap().summary.revision_count, 2);
        assert_eq!(
            store.get_revision(&document_id, 1).unwrap().text,
            "first body"
        );
        assert_eq!(store.list_folders().unwrap()[0].name, "Reading");

        let mut moved = browser_request(Uuid::new_v4().to_string(), "ignored");
        moved.duplicate_resolution = Some("move-only".into());
        moved.folder_id = receipt.folder_id.clone();
        let moved = store.import_browser_capture(moved, None).unwrap();
        assert!(matches!(
            moved,
            BrowserKnowledgeImportOutcome::Imported { .. }
        ));
        assert_eq!(store.get(&document_id).unwrap().text, "first body");

        let mut copied = browser_request(Uuid::new_v4().to_string(), "copy body");
        copied.duplicate_resolution = Some("keep-copy".into());
        let copied = store.import_browser_capture(copied, None).unwrap();
        assert!(matches!(
            copied,
            BrowserKnowledgeImportOutcome::Imported { .. }
        ));
        assert_eq!(store.status().unwrap().item_count, 2);

        let replay = store
            .import_browser_capture(browser_request(operation_id.clone(), "first body"), None)
            .unwrap();
        match replay {
            BrowserKnowledgeImportOutcome::Imported { receipt } => assert!(receipt.replayed),
            _ => panic!("completed operation must replay"),
        }
        assert_eq!(
            store
                .import_browser_capture(browser_request(operation_id, "different body"), None)
                .unwrap_err()
                .code,
            "knowledge_operation_conflict"
        );
    }

    #[test]
    fn remote_ai_permission_defaults_migrates_and_can_be_revoked() {
        let directory = TempDir::new().unwrap();
        let item_id = {
            let store = KnowledgeLibraryStore::new(directory.path().into()).unwrap();
            let mut import = request("local-only body");
            import.allows_remote_ai_use = true;
            let imported = store.import(import).unwrap();
            assert!(imported.item.summary.allows_remote_ai_use);
            imported.item.summary.item_id
        };

        let manifest_path = directory.path().join("knowledge-v1/manifest.json");
        let mut manifest: serde_json::Value =
            serde_json::from_slice(&fs::read(&manifest_path).unwrap()).unwrap();
        manifest["schemaVersion"] = serde_json::json!(3);
        manifest["items"][0]
            .as_object_mut()
            .unwrap()
            .get_mut("summary")
            .unwrap()
            .as_object_mut()
            .unwrap()
            .remove("allowsRemoteAiUse");
        fs::write(&manifest_path, serde_json::to_vec(&manifest).unwrap()).unwrap();

        let store = KnowledgeLibraryStore::new(directory.path().into()).unwrap();
        assert!(!store.get(&item_id).unwrap().summary.allows_remote_ai_use);
        let enabled = store.set_remote_ai_permission(&item_id, true).unwrap();
        assert!(enabled.allows_remote_ai_use);
        let revoked = store.set_remote_ai_permission(&item_id, false).unwrap();
        assert!(!revoked.allows_remote_ai_use);
        let migrated: serde_json::Value =
            serde_json::from_slice(&fs::read(manifest_path).unwrap()).unwrap();
        assert_eq!(migrated["schemaVersion"], 4);
        assert_eq!(migrated["items"][0]["summary"]["allowsRemoteAiUse"], false);
    }

    #[test]
    fn migrated_p10_operation_replays_only_as_local_only() {
        let directory = TempDir::new().unwrap();
        let operation_id = Uuid::new_v4().to_string();
        let original = browser_request(operation_id, "legacy body");
        let (normalized, _) = validate_browser_import_request(original.clone()).unwrap();
        let legacy_fingerprint = browser_operation_legacy_v2_fingerprint(&normalized, &None);
        {
            let store = KnowledgeLibraryStore::new(directory.path().into()).unwrap();
            assert!(matches!(
                store
                    .import_browser_capture(original.clone(), None)
                    .unwrap(),
                BrowserKnowledgeImportOutcome::Imported { .. }
            ));
        }

        let manifest_path = directory.path().join("knowledge-v1/manifest.json");
        let mut manifest: serde_json::Value =
            serde_json::from_slice(&fs::read(&manifest_path).unwrap()).unwrap();
        manifest["schemaVersion"] = serde_json::json!(3);
        manifest["completedOperations"][0]["fingerprint"] = serde_json::json!(legacy_fingerprint);
        manifest["items"][0]["summary"]
            .as_object_mut()
            .unwrap()
            .remove("allowsRemoteAiUse");
        manifest["completedOperations"][0]["receipt"]
            .as_object_mut()
            .unwrap()
            .remove("allowsRemoteAiUse");
        fs::write(&manifest_path, serde_json::to_vec(&manifest).unwrap()).unwrap();

        let store = KnowledgeLibraryStore::new(directory.path().into()).unwrap();
        let replay = match store
            .import_browser_capture(original.clone(), None)
            .unwrap()
        {
            BrowserKnowledgeImportOutcome::Imported { receipt } => receipt,
            _ => panic!("a matching P10 operation must replay"),
        };
        assert!(replay.replayed);
        assert!(!replay.allows_remote_ai_use);
        assert_eq!(store.status().unwrap().item_count, 1);

        let mut escalation = original.clone();
        escalation.allows_remote_ai_use = true;
        assert_eq!(
            store
                .import_browser_capture(escalation, None)
                .unwrap_err()
                .code,
            "knowledge_operation_conflict"
        );

        let mut changed_body = original;
        changed_body.text = "different body".to_string();
        assert_eq!(
            store
                .import_browser_capture(changed_body, None)
                .unwrap_err()
                .code,
            "knowledge_operation_conflict"
        );
    }

    #[test]
    fn browser_remote_ai_permission_is_persisted_by_each_conflict_strategy() {
        let store = KnowledgeLibraryStore::default();
        let operation_id = Uuid::new_v4().to_string();
        let mut first = browser_request(operation_id.clone(), "first body");
        first.allows_remote_ai_use = true;
        let initial_receipt = match store.import_browser_capture(first.clone(), None).unwrap() {
            BrowserKnowledgeImportOutcome::Imported { receipt } => {
                assert!(receipt.allows_remote_ai_use);
                receipt
            }
            _ => panic!("first import must insert"),
        };
        let document_id = initial_receipt.document_id.clone();
        let replay = match store.import_browser_capture(first.clone(), None).unwrap() {
            BrowserKnowledgeImportOutcome::Imported { receipt } => receipt,
            _ => panic!("completed operation must replay"),
        };
        assert!(replay.replayed);
        assert!(replay.allows_remote_ai_use);
        assert_eq!(
            replay.saved_at_epoch_seconds,
            initial_receipt.saved_at_epoch_seconds
        );

        let mut changed_permission = first;
        changed_permission.allows_remote_ai_use = false;
        assert_eq!(
            store
                .import_browser_capture(changed_permission, None)
                .unwrap_err()
                .code,
            "knowledge_operation_conflict"
        );

        let mut version = browser_request(Uuid::new_v4().to_string(), "new body");
        version.allows_remote_ai_use = false;
        version.duplicate_resolution = Some("save-new-version".into());
        let versioned = match store.import_browser_capture(version, None).unwrap() {
            BrowserKnowledgeImportOutcome::Imported { receipt } => receipt,
            _ => panic!("version must import"),
        };
        assert!(!versioned.allows_remote_ai_use);
        assert!(
            !store
                .get(&document_id)
                .unwrap()
                .summary
                .allows_remote_ai_use
        );

        let mut moved = browser_request(Uuid::new_v4().to_string(), "ignored");
        moved.allows_remote_ai_use = true;
        moved.duplicate_resolution = Some("move-only".into());
        let moved = match store.import_browser_capture(moved, None).unwrap() {
            BrowserKnowledgeImportOutcome::Imported { receipt } => receipt,
            _ => panic!("move must import"),
        };
        assert!(!moved.allows_remote_ai_use);
        assert!(
            !store
                .get(&document_id)
                .unwrap()
                .summary
                .allows_remote_ai_use
        );

        let mut copied = browser_request(Uuid::new_v4().to_string(), "copied body");
        copied.allows_remote_ai_use = true;
        copied.duplicate_resolution = Some("keep-copy".into());
        let copied = match store.import_browser_capture(copied, None).unwrap() {
            BrowserKnowledgeImportOutcome::Imported { receipt } => receipt,
            _ => panic!("copy must import"),
        };
        assert!(copied.allows_remote_ai_use);
        assert!(
            store
                .get(&copied.document_id)
                .unwrap()
                .summary
                .allows_remote_ai_use
        );
    }

    #[test]
    fn history_references_survive_until_delete_and_open_requests_are_one_shot() {
        let directory = TempDir::new().unwrap();
        let store = KnowledgeLibraryStore::new(directory.path().into()).unwrap();
        let first = browser_request(Uuid::new_v4().to_string(), "old revision");
        let id = match store.import_browser_capture(first, None).unwrap() {
            BrowserKnowledgeImportOutcome::Imported { receipt } => receipt.document_id,
            _ => panic!("insert"),
        };
        let mut second = browser_request(Uuid::new_v4().to_string(), "new revision");
        second.duplicate_resolution = Some("save-new-version".into());
        store.import_browser_capture(second, None).unwrap();
        assert_eq!(store.get_revision(&id, 1).unwrap().text, "old revision");
        store.request_open(&id).unwrap();
        assert_eq!(
            store.take_open_request().unwrap().as_deref(),
            Some(id.as_str())
        );
        assert_eq!(store.take_open_request().unwrap(), None);
        store.delete(&id).unwrap();
        assert_eq!(
            fs::read_dir(directory.path().join("knowledge-v1/blobs"))
                .unwrap()
                .count(),
            0
        );
    }

    #[test]
    fn reloads_persistent_library_and_deduplicates_bodies() {
        let directory = TempDir::new().unwrap();
        let store = KnowledgeLibraryStore::new(directory.path().into()).unwrap();
        let first = store
            .import(request("A vehicle needs regular maintenance."))
            .unwrap();
        let second = store
            .import(request("A vehicle needs regular maintenance."))
            .unwrap();
        assert!(!first.deduplicated);
        assert!(second.deduplicated);
        assert_eq!(store.status().unwrap().item_count, 1);
        let reloaded = KnowledgeLibraryStore::new(directory.path().into()).unwrap();
        assert_eq!(
            reloaded.get(&first.item.summary.item_id).unwrap().text,
            "A vehicle needs regular maintenance."
        );
        reloaded.delete(&first.item.summary.item_id).unwrap();
        assert_eq!(
            KnowledgeLibraryStore::new(directory.path().into())
                .unwrap()
                .status()
                .unwrap()
                .item_count,
            0
        );
        assert_eq!(
            fs::read_dir(directory.path().join("knowledge-v1/blobs"))
                .unwrap()
                .count(),
            0
        );
    }

    #[test]
    fn validates_limits_urls_and_paths() {
        let store = KnowledgeLibraryStore::default();
        let mut too_large = request(&"x".repeat(MAX_ITEM_BYTES + 1));
        assert!(store.import(too_large).is_err());
        too_large = request("safe");
        too_large.source_kind = KnowledgeSourceKind::Web;
        too_large.source_url = Some("ftp://example.test".into());
        assert!(store.import(too_large).is_err());
        let mut web = request("web content");
        web.source_kind = KnowledgeSourceKind::Web;
        web.source_url = Some("https://example.test/article#private-fragment".into());
        assert_eq!(
            store
                .import(web)
                .unwrap()
                .item
                .summary
                .source_url
                .as_deref(),
            Some("https://example.test/article")
        );
        assert!(validate_relative_markdown_path("../escape.md").is_err());
        assert!(validate_relative_markdown_path("/escape.md").is_err());
        assert!(validate_relative_markdown_path("note.txt").is_err());
        assert!(validate_relative_markdown_path(".git/private.md").is_err());
    }

    #[test]
    fn failed_manifest_import_removes_the_unreferenced_private_blob() {
        let directory = TempDir::new().unwrap();
        let store = KnowledgeLibraryStore::new(directory.path().into()).unwrap();
        fs::create_dir(directory.path().join("knowledge-v1/manifest.json")).unwrap();

        assert!(store.import(request("private failed import")).is_err());
        assert_eq!(
            fs::read_dir(directory.path().join("knowledge-v1/blobs"))
                .unwrap()
                .count(),
            0
        );
    }

    #[test]
    fn failed_archive_import_leaves_no_unreferenced_archive() {
        let directory = TempDir::new().unwrap();
        let store = KnowledgeLibraryStore::new(directory.path().into()).unwrap();
        fs::create_dir(directory.path().join("knowledge-v1/manifest.json")).unwrap();
        assert!(store
            .import_with_archive(
                request("archive failed import"),
                Some(&html_archive("failed"))
            )
            .is_err());
        assert_eq!(
            fs::read_dir(directory.path().join("knowledge-v1/archives"))
                .unwrap()
                .count(),
            0
        );
    }

    #[test]
    fn startup_collects_unreferenced_blobs_and_reads_verify_the_content_address() {
        let directory = TempDir::new().unwrap();
        let store = KnowledgeLibraryStore::new(directory.path().into()).unwrap();
        let imported = store.import(request("original private body")).unwrap();
        let digest = sha256_hex(b"original private body");
        let blob = directory.path().join("knowledge-v1/blobs").join(&digest);
        fs::write(&blob, b"tampered private body").unwrap();
        assert!(store.get(&imported.item.summary.item_id).is_err());
        drop(store);

        fs::remove_file(&blob).unwrap();
        let orphan_digest = sha256_hex(b"unreferenced");
        let orphan = directory
            .path()
            .join("knowledge-v1/blobs")
            .join(orphan_digest);
        fs::write(&orphan, b"unreferenced").unwrap();
        fs::set_permissions(&orphan, fs::Permissions::from_mode(0o600)).unwrap();
        let reloaded = KnowledgeLibraryStore::new(directory.path().into()).unwrap_err();
        assert_eq!(reloaded.code, "knowledge_content_invalid");

        // Once the referenced corruption is removed from the test manifest, reachability GC is
        // covered independently by a fresh empty store.
        let clean_directory = TempDir::new().unwrap();
        let empty_store = KnowledgeLibraryStore::new(clean_directory.path().into()).unwrap();
        drop(empty_store);
        let orphan = clean_directory
            .path()
            .join("knowledge-v1/blobs")
            .join(sha256_hex(b"orphan"));
        fs::write(&orphan, b"orphan").unwrap();
        fs::set_permissions(&orphan, fs::Permissions::from_mode(0o600)).unwrap();
        KnowledgeLibraryStore::new(clean_directory.path().into()).unwrap();
        assert!(!orphan.exists());
    }

    #[test]
    fn search_progress_and_export_plan_lifecycle() {
        let root = TempDir::new().unwrap();
        let store = KnowledgeLibraryStore::default();
        let item = store
            .import(request("İstanbul: an automobile is a vehicle."))
            .unwrap()
            .item;
        assert_eq!(store.search("car", 10).unwrap().results.len(), 1);
        // The dotted capital I expands when lowercased; the combining dot is
        // at byte one in the lowercase copy, but byte one is not a boundary
        // in the original string.
        assert!(!snippet_for("İstanbul", "\u{307}").is_empty());
        assert_eq!(
            store
                .update_progress(&item.summary.item_id, 100)
                .unwrap()
                .reading_progress_percent,
            100
        );
        assert!(store.update_progress(&item.summary.item_id, 101).is_err());
        let plan = store
            .plan_export("session", root.path(), &item.summary.item_id, "notes.md")
            .unwrap();
        let result = store
            .execute_export("session", root.path(), &plan.plan_id)
            .unwrap();
        assert_eq!(result.relative_path, "notes.md");
        assert!(store
            .execute_export("session", root.path(), &plan.plan_id)
            .is_err());
        assert!(store
            .plan_export("session", root.path(), &item.summary.item_id, "notes.md")
            .is_err());
    }

    #[test]
    fn semantic_opt_out_keeps_literal_body_search_without_embedding_it() {
        let store = KnowledgeLibraryStore::default();
        let mut imported = request("A literal-only phrase: cobalt-orchid-731.");
        imported.allows_local_semantic_index = false;
        store.import(imported).unwrap();

        let result = store.search("cobalt-orchid-731", 10).unwrap();
        assert_eq!(result.results.len(), 1);
        assert_eq!(result.results[0].semantic_score, 0.0);
        assert!(result.results[0].lexical_score > 0.0);
    }

    #[test]
    fn persists_archives_attaches_once_and_cleans_them_on_delete() {
        let directory = TempDir::new().unwrap();
        let store = KnowledgeLibraryStore::new(directory.path().into()).unwrap();
        let archive = html_archive("first");
        let inserted = store.import(request("deduplicated browser text")).unwrap();
        assert_eq!(inserted.item.summary.archive, None);
        let attached = store
            .import_with_archive(request("deduplicated browser text"), Some(&archive))
            .unwrap();
        assert!(attached.deduplicated);
        assert!(attached.summary.contains("archive was attached"));
        let metadata = attached.item.summary.archive.clone().unwrap();
        assert_eq!(metadata.format, "html");
        assert!(!metadata.was_truncated);
        assert_eq!(
            serde_json::to_value(&metadata).unwrap()["wasTruncated"],
            false
        );
        let path = directory
            .path()
            .join("knowledge-v1/archives")
            .join(&metadata.sha256);
        assert!(path.exists());
        let other = html_archive("different");
        let duplicate = store
            .import_with_archive(request("deduplicated browser text"), Some(&other))
            .unwrap();
        assert_eq!(
            duplicate.item.summary.archive.unwrap().sha256,
            metadata.sha256
        );
        drop(store);
        let reloaded = KnowledgeLibraryStore::new(directory.path().into()).unwrap();
        assert_eq!(
            reloaded
                .get(&inserted.item.summary.item_id)
                .unwrap()
                .summary
                .archive
                .unwrap()
                .sha256,
            metadata.sha256
        );
        reloaded.delete(&inserted.item.summary.item_id).unwrap();
        assert!(!path.exists());
    }

    #[test]
    fn archive_export_is_bound_to_one_confirmation_and_matching_extension() {
        let root = TempDir::new().unwrap();
        let store = KnowledgeLibraryStore::default();
        let item = store
            .import_with_archive(request("archive export"), Some(&html_archive("archive")))
            .unwrap()
            .item;
        assert!(store
            .plan_archive_export("session", root.path(), &item.summary.item_id, "bad.mhtml")
            .is_err());
        let plan = store
            .plan_archive_export(
                "session",
                root.path(),
                &item.summary.item_id,
                "offline/page.html",
            )
            .unwrap();
        assert!(store
            .execute_archive_export("other", root.path(), &plan.plan_id)
            .is_err());
        // The invalid attempt consumes the plan, so confirmation cannot be replayed.
        assert!(store
            .execute_archive_export("session", root.path(), &plan.plan_id)
            .is_err());
        let plan = store
            .plan_archive_export(
                "session",
                root.path(),
                &item.summary.item_id,
                "offline/page.html",
            )
            .unwrap();
        assert_eq!(plan.format, "html");
        assert_eq!(
            plan.byte_size,
            item.summary.archive.as_ref().unwrap().byte_size
        );
        let json = serde_json::to_value(&plan).unwrap();
        assert!(json.get("archiveSha256").is_some());
        assert!(json.get("format").is_some());
        assert!(json.get("byteSize").is_some());
        let result = store
            .execute_archive_export("session", root.path(), &plan.plan_id)
            .unwrap();
        assert_eq!(result.format, "html");
        assert!(root.path().join("offline/page.html").exists());
        assert!(store
            .plan_archive_export(
                "session",
                root.path(),
                &item.summary.item_id,
                "offline/page.html"
            )
            .is_err());
    }

    #[test]
    fn reads_v1_manifest_without_archive_field() {
        let directory = TempDir::new().unwrap();
        let store = KnowledgeLibraryStore::new(directory.path().into()).unwrap();
        let item = store.import(request("legacy text")).unwrap().item;
        drop(store);
        let manifest = directory.path().join("knowledge-v1/manifest.json");
        let mut value: serde_json::Value =
            serde_json::from_slice(&fs::read(&manifest).unwrap()).unwrap();
        value["schemaVersion"] = serde_json::json!(1);
        value["items"][0]["summary"]
            .as_object_mut()
            .unwrap()
            .remove("archive");
        fs::write(&manifest, serde_json::to_vec(&value).unwrap()).unwrap();
        fs::set_permissions(&manifest, fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(
            KnowledgeLibraryStore::new(directory.path().into())
                .unwrap()
                .get(&item.summary.item_id)
                .unwrap()
                .summary
                .archive,
            None
        );
    }

    #[test]
    fn archive_capacity_boundary_rejects_without_allocating_large_test_data() {
        assert!(archive_capacity_allows(MAX_ARCHIVE_LIBRARY_BYTES - 1, 1));
        assert!(!archive_capacity_allows(MAX_ARCHIVE_LIBRARY_BYTES, 1));
        assert!(!archive_capacity_allows(u64::MAX, 1));
    }

    #[test]
    fn shared_archive_survives_failed_attach_and_deleting_one_reference() {
        let directory = TempDir::new().unwrap();
        let store = KnowledgeLibraryStore::new(directory.path().into()).unwrap();
        let archive = html_archive("shared");
        let first = store
            .import_with_archive(request("first shared body"), Some(&archive))
            .unwrap()
            .item;
        let second = store.import(request("second shared body")).unwrap().item;
        let digest = first.summary.archive.as_ref().unwrap().sha256.clone();
        let archive_path = directory.path().join("knowledge-v1/archives").join(&digest);
        let manifest = directory.path().join("knowledge-v1/manifest.json");
        fs::remove_file(&manifest).unwrap();
        fs::create_dir(&manifest).unwrap();
        assert!(store
            .import_with_archive(request("second shared body"), Some(&archive))
            .is_err());
        assert!(archive_path.exists());
        // An unsafe disk generation now blocks public reads instead of publishing cached metadata.
        assert!(store.get(&first.summary.item_id).is_err());
        assert_eq!(fs::read(&archive_path).unwrap(), archive.bytes);

        // Test-only repair from the cached pre-failure state; production restore never auto-repairs.
        fs::remove_dir(&manifest).unwrap();
        let state = store.state.lock().unwrap();
        store.persist(&state).unwrap();
        drop(state);
        store
            .import_with_archive(request("second shared body"), Some(&archive))
            .unwrap();
        store.delete(&first.summary.item_id).unwrap();
        assert!(archive_path.exists());
        assert_eq!(
            store.get(&second.summary.item_id).unwrap().text,
            "second shared body"
        );
    }

    #[test]
    fn export_rejects_symlinks_and_expired_or_overwriting_plans() {
        use std::os::unix::fs::symlink;

        let root = TempDir::new().unwrap();
        let outside = TempDir::new().unwrap();
        let store = KnowledgeLibraryStore::default();
        let item = store.import(request("A durable note.")).unwrap().item;
        symlink(outside.path(), root.path().join("linked")).unwrap();
        assert!(store
            .plan_export(
                "session",
                root.path(),
                &item.summary.item_id,
                "linked/note.md"
            )
            .is_err());

        let plan = store
            .plan_export(
                "session",
                root.path(),
                &item.summary.item_id,
                "nested/note.md",
            )
            .unwrap();
        assert!(plan
            .warnings
            .iter()
            .any(|warning| warning.contains("parent directories")));
        {
            let mut state = store.lock().unwrap();
            state
                .export_plans
                .get_mut(&plan.plan_id)
                .unwrap()
                .public
                .expires_at_epoch_seconds = now_epoch_seconds().saturating_sub(1);
        }
        assert!(store
            .execute_export("session", root.path(), &plan.plan_id)
            .is_err());

        let existing = root.path().join("taken.md");
        fs::write(&existing, "do not replace").unwrap();
        assert!(store
            .plan_export("session", root.path(), &item.summary.item_id, "taken.md")
            .is_err());
        assert_eq!(fs::read_to_string(existing).unwrap(), "do not replace");
    }
    #[test]
    fn root_replacement_during_io_never_writes_replacement_tree_or_reports_success() {
        let temp = TempDir::new().unwrap();
        let root = temp.path().join("data");
        fs::create_dir(&root).unwrap();
        let store = KnowledgeLibraryStore::new(root.clone()).unwrap();
        store.import(request("anchored body")).unwrap();
        let moved = temp.path().join("moved");
        let result = store.checked_operation(|| {
            let state = store.lock()?;
            fs::rename(&root, &moved).unwrap();
            fs::create_dir(&root).unwrap();
            fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
            // Exercise the normal manifest writer while the operation still holds its root lease.
            write_manifest(store.storage.as_ref().unwrap(), &state)?;
            Ok(())
        });
        assert!(result.is_err());
        assert!(moved.join("knowledge-v1/manifest.json").is_file());
        assert!(!root.join("knowledge-v1").exists());
        assert!(store.status().is_err());
    }
}
