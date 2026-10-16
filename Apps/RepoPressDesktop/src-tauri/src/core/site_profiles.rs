use super::{CommandError, CommandResult};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};
use tempfile::Builder;
use uuid::Uuid;

const STORAGE_DIRECTORY: &str = "site-profiles";
const REGISTRY_FILE: &str = "registry.json";
const SCHEMA_VERSION: u32 = 1;
const MAX_PROFILES: usize = 32;
const MAX_REGISTRY_BYTES: u64 = 256 * 1024;
const MAX_NAME_BYTES: usize = 256;
const MAX_ROOT_BYTES: usize = 4096;
const JS_SAFE_MAX: u64 = 9_007_199_254_740_991;
const READ_ONLY_WARNING: &str = "站点注册表不可用，当前为只读模式。";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SiteProfile {
    pub profile_id: String,
    pub name: String,
    pub root_path: String,
    pub created_at_epoch_ms: u64,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SiteProfileSnapshot {
    pub profiles: Vec<SiteProfile>,
    pub revision: u64,
    pub persistent: bool,
    pub writable: bool,
    pub warning: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PersistedRegistry {
    schema_version: u32,
    profiles: Vec<SiteProfile>,
    revision: u64,
}

impl Default for PersistedRegistry {
    fn default() -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            profiles: Vec::new(),
            revision: 0,
        }
    }
}

struct StoragePaths {
    directory: PathBuf,
    registry_file: PathBuf,
    expected_digest: Option<[u8; 32]>,
}

struct SiteProfileState {
    registry: PersistedRegistry,
    storage: Option<StoragePaths>,
    writable: bool,
    warning: Option<String>,
}

pub struct SiteProfileStore {
    state: Mutex<SiteProfileState>,
}

impl Default for SiteProfileStore {
    fn default() -> Self {
        Self {
            state: Mutex::new(SiteProfileState {
                registry: PersistedRegistry::default(),
                storage: None,
                writable: true,
                warning: None,
            }),
        }
    }
}

impl SiteProfileStore {
    /// Site registration is optional at startup; unsafe storage is deliberately read-only.
    pub fn new(app_data_dir: PathBuf) -> Self {
        match prepare_storage(&app_data_dir).and_then(|mut storage| {
            let (registry, digest) = load_registry(&storage)?;
            storage.expected_digest = digest;
            Ok((registry, storage))
        }) {
            Ok((registry, storage)) => Self {
                state: Mutex::new(SiteProfileState {
                    registry,
                    storage: Some(storage),
                    writable: true,
                    warning: None,
                }),
            },
            Err(_) => Self {
                state: Mutex::new(SiteProfileState {
                    registry: PersistedRegistry::default(),
                    storage: None,
                    writable: false,
                    warning: Some(READ_ONLY_WARNING.to_string()),
                }),
            },
        }
    }

    pub fn snapshot(&self) -> CommandResult<SiteProfileSnapshot> {
        let state = self.state.lock().map_err(|_| unavailable())?;
        Ok(snapshot_from_state(&state))
    }

    pub fn register(
        &self,
        root: &Path,
        name: &str,
        expected_revision: u64,
    ) -> CommandResult<SiteProfileSnapshot> {
        let normalized_root = normalize_registered_root(root)?;
        let normalized_name = normalize_name(name)?;
        self.mutate(expected_revision, move |candidate| {
            if candidate.profiles.len() >= MAX_PROFILES {
                return Err(CommandError::new(
                    "site_profiles_limit_reached",
                    "At most 32 site profiles may be registered.",
                ));
            }
            if candidate
                .profiles
                .iter()
                .any(|profile| profile.root_path == normalized_root)
            {
                return Err(CommandError::new(
                    "site_profile_root_exists",
                    "This repository is already registered.",
                ));
            }
            candidate.profiles.push(SiteProfile {
                profile_id: Uuid::new_v4().to_string(),
                name: normalized_name,
                root_path: normalized_root,
                created_at_epoch_ms: now_epoch_ms(),
            });
            Ok(())
        })
    }

    pub fn rename(
        &self,
        profile_id: &str,
        name: &str,
        expected_revision: u64,
    ) -> CommandResult<SiteProfileSnapshot> {
        let profile_id = canonical_profile_id(profile_id)?;
        let normalized_name = normalize_name(name)?;
        self.mutate(expected_revision, move |candidate| {
            let profile = candidate
                .profiles
                .iter_mut()
                .find(|profile| profile.profile_id == profile_id)
                .ok_or_else(profile_not_found)?;
            profile.name = normalized_name;
            Ok(())
        })
    }

    pub fn remove(
        &self,
        profile_id: &str,
        expected_revision: u64,
    ) -> CommandResult<SiteProfileSnapshot> {
        let profile_id = canonical_profile_id(profile_id)?;
        self.mutate(expected_revision, move |candidate| {
            let before = candidate.profiles.len();
            candidate
                .profiles
                .retain(|profile| profile.profile_id != profile_id);
            if candidate.profiles.len() == before {
                return Err(profile_not_found());
            }
            Ok(())
        })
    }

    /// This is registry lookup only. RepositoryStore must validate the returned root on each open.
    pub fn resolve_root(&self, profile_id: &str) -> CommandResult<PathBuf> {
        let profile_id = canonical_profile_id(profile_id)?;
        let state = self.state.lock().map_err(|_| unavailable())?;
        state
            .registry
            .profiles
            .iter()
            .find(|profile| profile.profile_id == profile_id)
            .map(|profile| PathBuf::from(&profile.root_path))
            .ok_or_else(profile_not_found)
    }

    fn mutate(
        &self,
        expected_revision: u64,
        change: impl FnOnce(&mut PersistedRegistry) -> CommandResult<()>,
    ) -> CommandResult<SiteProfileSnapshot> {
        let mut state = self.state.lock().map_err(|_| unavailable())?;
        if !state.writable {
            return Err(read_only());
        }
        if state.registry.revision != expected_revision {
            return Err(CommandError::new(
                "site_profiles_revision_conflict",
                "The site profile list changed. Refresh it before trying again.",
            ));
        }
        if state.registry.revision >= JS_SAFE_MAX {
            return Err(CommandError::new(
                "site_profiles_revision_exhausted",
                "The site profile revision limit has been reached.",
            ));
        }
        let mut candidate = state.registry.clone();
        change(&mut candidate)?;
        candidate.revision += 1;
        validate_registry(&candidate)?;
        if let Some(storage) = state.storage.as_mut() {
            if write_registry(storage, &candidate).is_err() {
                state.storage = None;
                state.writable = false;
                state.warning = Some(READ_ONLY_WARNING.to_string());
                return Err(CommandError::new(
                    "site_profiles_persist_failed",
                    "Unable to safely update site profiles.",
                ));
            }
        }
        state.registry = candidate;
        Ok(snapshot_from_state(&state))
    }
}

fn snapshot_from_state(state: &SiteProfileState) -> SiteProfileSnapshot {
    SiteProfileSnapshot {
        profiles: state.registry.profiles.clone(),
        revision: state.registry.revision,
        persistent: state.storage.is_some(),
        writable: state.writable,
        warning: state.warning.clone(),
    }
}

fn normalize_registered_root(root: &Path) -> CommandResult<String> {
    if !root.is_absolute() {
        return Err(invalid_root());
    }
    let metadata = fs::symlink_metadata(root).map_err(|_| invalid_root())?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(invalid_root());
    }
    let canonical = fs::canonicalize(root).map_err(|_| invalid_root())?;
    let canonical_metadata = fs::symlink_metadata(&canonical).map_err(|_| invalid_root())?;
    if canonical_metadata.file_type().is_symlink() || !canonical_metadata.is_dir() {
        return Err(invalid_root());
    }
    let value = canonical.to_str().ok_or_else(invalid_root)?.to_string();
    validate_root_path(&value)?;
    Ok(value)
}

fn normalize_name(name: &str) -> CommandResult<String> {
    let trimmed = name.trim();
    if trimmed.is_empty() || trimmed.len() > MAX_NAME_BYTES || trimmed.chars().any(char::is_control)
    {
        return Err(CommandError::new(
            "site_profile_name_invalid",
            "Site profile names must be non-empty, private display text.",
        ));
    }
    Ok(trimmed.to_string())
}

fn canonical_profile_id(profile_id: &str) -> CommandResult<String> {
    let id = Uuid::parse_str(profile_id).map_err(|_| profile_not_found())?;
    let canonical = id.to_string();
    if canonical != profile_id {
        return Err(profile_not_found());
    }
    Ok(canonical)
}

fn validate_registry(registry: &PersistedRegistry) -> CommandResult<()> {
    if registry.schema_version != SCHEMA_VERSION
        || registry.profiles.len() > MAX_PROFILES
        || registry.revision > JS_SAFE_MAX
    {
        return Err(storage_error());
    }
    let mut ids = HashSet::with_capacity(registry.profiles.len());
    let mut roots = HashSet::with_capacity(registry.profiles.len());
    for profile in &registry.profiles {
        if canonical_profile_id(&profile.profile_id).is_err()
            || normalize_name(&profile.name).as_deref() != Ok(profile.name.as_str())
            || validate_root_path(&profile.root_path).is_err()
            || !ids.insert(&profile.profile_id)
            || !roots.insert(&profile.root_path)
        {
            return Err(storage_error());
        }
    }
    Ok(())
}

/// Pure validation of an already bounded private backup source; no store fallback or I/O.
pub(super) fn validate_backup_json(bytes: &[u8]) -> CommandResult<usize> {
    let registry: PersistedRegistry = serde_json::from_slice(bytes).map_err(|_| storage_error())?;
    validate_registry(&registry)?;
    Ok(registry.profiles.len())
}

fn validate_root_path(value: &str) -> CommandResult<()> {
    let path = Path::new(value);
    let normalized = lexical_normalize_absolute_path(path);
    if value.is_empty()
        || value.len() > MAX_ROOT_BYTES
        || value.chars().any(char::is_control)
        || !path.is_absolute()
        || normalized.as_deref().and_then(Path::to_str) != Some(value)
    {
        return Err(invalid_root());
    }
    Ok(())
}

fn lexical_normalize_absolute_path(path: &Path) -> Option<PathBuf> {
    if !path.is_absolute() {
        return None;
    }
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Prefix(prefix) => normalized.push(prefix.as_os_str()),
            Component::RootDir => normalized.push(std::path::MAIN_SEPARATOR_STR),
            Component::Normal(segment) => normalized.push(segment),
            Component::CurDir | Component::ParentDir => return None,
        }
    }
    Some(normalized)
}

fn prepare_storage(app_data_dir: &Path) -> CommandResult<StoragePaths> {
    fs::create_dir_all(app_data_dir).map_err(|_| storage_error())?;
    let directory = app_data_dir.join(STORAGE_DIRECTORY);
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
        registry_file: directory.join(REGISTRY_FILE),
        directory,
        expected_digest: None,
    })
}

fn load_registry(storage: &StoragePaths) -> CommandResult<(PersistedRegistry, Option<[u8; 32]>)> {
    validate_storage_directory(&storage.directory)?;
    let metadata = match fs::symlink_metadata(&storage.registry_file) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok((PersistedRegistry::default(), None));
        }
        Err(_) => return Err(storage_error()),
    };
    validate_private_file(&metadata)?;
    if metadata.len() > MAX_REGISTRY_BYTES {
        return Err(storage_error());
    }
    let bytes = read_registry_file(&storage.registry_file)?;
    if bytes.len() as u64 > MAX_REGISTRY_BYTES {
        return Err(storage_error());
    }
    let registry = serde_json::from_slice(&bytes).map_err(|_| storage_error())?;
    validate_registry(&registry)?;
    Ok((registry, Some(Sha256::digest(&bytes).into())))
}

fn write_registry(storage: &mut StoragePaths, registry: &PersistedRegistry) -> CommandResult<()> {
    validate_registry(registry)?;
    validate_storage_directory(&storage.directory)?;
    let encoded = serde_json::to_vec(registry).map_err(|_| storage_error())?;
    if encoded.len() as u64 > MAX_REGISTRY_BYTES {
        return Err(storage_error());
    }
    verify_storage_unchanged(storage)?;
    let mut temporary = Builder::new()
        .prefix(".site-profiles-")
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
    validate_storage_directory(&storage.directory)?;
    temporary
        .persist(&storage.registry_file)
        .map_err(|_| storage_error())?;
    set_private_file_permissions(&storage.registry_file)?;
    sync_directory(&storage.directory)?;
    storage.expected_digest = Some(Sha256::digest(&encoded).into());
    Ok(())
}

fn verify_storage_unchanged(storage: &StoragePaths) -> CommandResult<()> {
    validate_storage_directory(&storage.directory)?;
    let metadata = match fs::symlink_metadata(&storage.registry_file) {
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
    validate_private_file(&metadata)?;
    if metadata.len() > MAX_REGISTRY_BYTES {
        return Err(storage_error());
    }
    let bytes = read_registry_file(&storage.registry_file)?;
    if bytes.len() as u64 > MAX_REGISTRY_BYTES {
        return Err(storage_error());
    }
    let digest: [u8; 32] = Sha256::digest(&bytes).into();
    if storage.expected_digest != Some(digest) {
        return Err(storage_error());
    }
    Ok(())
}

fn read_registry_file(path: &Path) -> CommandResult<Vec<u8>> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let mut file = options.open(path).map_err(|_| storage_error())?;
    let metadata = file.metadata().map_err(|_| storage_error())?;
    validate_private_file(&metadata)?;
    if metadata.len() > MAX_REGISTRY_BYTES {
        return Err(storage_error());
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    Read::by_ref(&mut file)
        .take(MAX_REGISTRY_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| storage_error())?;
    Ok(bytes)
}

fn validate_private_file(metadata: &fs::Metadata) -> CommandResult<()> {
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
    validate_storage_directory(path)?;
    File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(|_| storage_error())
}

#[cfg(not(unix))]
fn sync_directory(_path: &Path) -> CommandResult<()> {
    Ok(())
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
        "site_profiles_unavailable",
        "Site profiles are temporarily unavailable.",
    )
}

fn read_only() -> CommandError {
    CommandError::new(
        "site_profiles_read_only",
        "Site profile storage is read-only.",
    )
}

fn profile_not_found() -> CommandError {
    CommandError::new("site_profile_not_found", "The site profile was not found.")
}

fn invalid_root() -> CommandError {
    CommandError::new(
        "site_profile_root_invalid",
        "Site profile roots must be verified directories.",
    )
}

fn storage_error() -> CommandError {
    CommandError::new(
        "site_profiles_storage_unsafe",
        "Site profile storage is unavailable.",
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> (tempfile::TempDir, tempfile::TempDir, SiteProfileStore) {
        let app_data = tempfile::tempdir().unwrap();
        let repository = tempfile::tempdir().unwrap();
        let store = SiteProfileStore::new(app_data.path().to_path_buf());
        assert!(store.snapshot().unwrap().persistent);
        (app_data, repository, store)
    }

    fn register(
        store: &SiteProfileStore,
        root: &Path,
        name: &str,
        revision: u64,
    ) -> SiteProfileSnapshot {
        store.register(root, name, revision).unwrap()
    }

    #[test]
    fn default_memory_store_is_writable() {
        let store = SiteProfileStore::default();
        let snapshot = store.snapshot().unwrap();
        assert!(!snapshot.persistent);
        assert!(snapshot.writable);
        assert_eq!(snapshot.warning, None);
    }

    #[test]
    fn register_rename_remove_and_restart_preserve_stable_fields() {
        let (app_data, repository, store) = store();
        let first = register(&store, repository.path(), "  Primary  ", 0);
        let profile = first.profiles[0].clone();
        assert_eq!(profile.name, "Primary");
        let renamed = store.rename(&profile.profile_id, "Renamed", 1).unwrap();
        assert_eq!(renamed.revision, 2);
        assert_eq!(renamed.profiles[0].profile_id, profile.profile_id);
        assert_eq!(renamed.profiles[0].root_path, profile.root_path);
        assert_eq!(
            renamed.profiles[0].created_at_epoch_ms,
            profile.created_at_epoch_ms
        );
        drop(store);
        let restored = SiteProfileStore::new(app_data.path().to_path_buf());
        assert_eq!(restored.snapshot().unwrap().profiles[0].name, "Renamed");
        let removed = restored.remove(&profile.profile_id, 2).unwrap();
        assert!(removed.profiles.is_empty());
        assert_eq!(removed.revision, 3);
    }

    #[test]
    fn supports_distinct_roots_and_rejects_duplicate_normalized_root() {
        let (_app_data, repository, store) = store();
        let other = tempfile::tempdir().unwrap();
        let first = register(&store, repository.path(), "Same name", 0);
        let second = register(&store, other.path(), "Same name", 1);
        assert_eq!(second.profiles.len(), 2);
        let duplicate = store.register(repository.path(), "Another", 2).unwrap_err();
        assert_eq!(duplicate.code, "site_profile_root_exists");
        assert_eq!(first.profiles[0].name, second.profiles[0].name);
    }

    #[test]
    fn caps_registration_at_thirty_two_profiles() {
        let (_app_data, repository, store) = store();
        for index in 0..MAX_PROFILES {
            let root = repository.path().join(format!("site-{index}"));
            fs::create_dir(&root).unwrap();
            register(&store, &root, &format!("Site {index}"), index as u64);
        }
        let extra = repository.path().join("site-extra");
        fs::create_dir(&extra).unwrap();
        let error = store
            .register(&extra, "Extra", MAX_PROFILES as u64)
            .unwrap_err();
        assert_eq!(error.code, "site_profiles_limit_reached");
        let snapshot = store.snapshot().unwrap();
        assert_eq!(snapshot.profiles.len(), MAX_PROFILES);
        assert_eq!(snapshot.revision, MAX_PROFILES as u64);
    }

    #[test]
    fn stale_revision_and_invalid_name_do_not_change_state() {
        let (_app_data, repository, store) = store();
        let snapshot = register(&store, repository.path(), "One", 0);
        let stale = store
            .rename(&snapshot.profiles[0].profile_id, "Two", 0)
            .unwrap_err();
        assert_eq!(stale.code, "site_profiles_revision_conflict");
        let invalid = store
            .rename(&snapshot.profiles[0].profile_id, "\n", 1)
            .unwrap_err();
        assert_eq!(invalid.code, "site_profile_name_invalid");
        assert_eq!(store.snapshot().unwrap().profiles[0].name, "One");
        assert_eq!(store.snapshot().unwrap().revision, 1);
    }

    #[test]
    fn resolve_is_registry_lookup_even_if_root_later_disappears() {
        let (_app_data, repository, store) = store();
        let snapshot = register(&store, repository.path(), "One", 0);
        let profile = &snapshot.profiles[0];
        fs::remove_dir(repository.path()).unwrap();
        assert_eq!(
            store.resolve_root(&profile.profile_id).unwrap(),
            PathBuf::from(&profile.root_path)
        );
    }

    #[test]
    fn malformed_and_noncanonical_registries_enter_read_only_mode() {
        let fixtures: [(&[u8], bool); 7] = [
            (b"not json", true),
            (br#"{"schemaVersion":2,"profiles":[],"revision":0}"#, false),
            (br#"{"schemaVersion":1,"profiles":[],"revision":0,"extra":true}"#, true),
            (br#"{"schemaVersion":1,"profiles":[{"profileId":"550e8400-e29b-41d4-a716-446655440000","name":"One","rootPath":"/tmp/../not-normal","createdAtEpochMs":1}],"revision":1}"#, false),
            (br#"{"schemaVersion":1,"profiles":[{"profileId":"550e8400-e29b-41d4-a716-446655440000","name":"One","rootPath":"/tmp/./not-normal","createdAtEpochMs":1}],"revision":1}"#, false),
            (br#"{"schemaVersion":1,"profiles":[{"profileId":"550e8400-e29b-41d4-a716-446655440000","name":"One","rootPath":"/tmp//not-normal","createdAtEpochMs":1}],"revision":1}"#, false),
            (br#"{"schemaVersion":1,"profiles":[{"profileId":"550e8400-e29b-41d4-a716-446655440000","name":"One","rootPath":"/tmp/not-normal/","createdAtEpochMs":1}],"revision":1}"#, false),
        ];
        for (content, rejects_deserialization) in fixtures {
            let parsed = serde_json::from_slice::<PersistedRegistry>(content);
            if rejects_deserialization {
                assert!(parsed.is_err());
            } else {
                assert!(validate_registry(&parsed.unwrap()).is_err());
            }
            let app_data = tempfile::tempdir().unwrap();
            let directory = app_data.path().join(STORAGE_DIRECTORY);
            fs::create_dir(&directory).unwrap();
            set_private_directory_permissions(&directory).unwrap();
            let file = directory.join(REGISTRY_FILE);
            fs::write(&file, content).unwrap();
            set_private_file_permissions(&file).unwrap();
            let store = SiteProfileStore::new(app_data.path().to_path_buf());
            let snapshot = store.snapshot().unwrap();
            assert!(!snapshot.persistent);
            assert!(!snapshot.writable);
            assert_eq!(snapshot.warning.as_deref(), Some(READ_ONLY_WARNING));
            assert_eq!(fs::read(&file).unwrap(), content);
        }
    }

    #[test]
    fn strict_registry_validation_rejects_duplicate_identity_and_root() {
        let fixtures = [
            br#"{"schemaVersion":1,"profiles":[{"profileId":"550e8400-e29b-41d4-a716-446655440000","name":"One","rootPath":"/one","createdAtEpochMs":1},{"profileId":"550e8400-e29b-41d4-a716-446655440000","name":"Two","rootPath":"/two","createdAtEpochMs":2}],"revision":2}"#,
            br#"{"schemaVersion":1,"profiles":[{"profileId":"550e8400-e29b-41d4-a716-446655440000","name":"One","rootPath":"/one","createdAtEpochMs":1},{"profileId":"660e8400-e29b-41d4-a716-446655440000","name":"Two","rootPath":"/one","createdAtEpochMs":2}],"revision":2}"#,
        ];
        for fixture in fixtures {
            let registry = serde_json::from_slice::<PersistedRegistry>(fixture).unwrap();
            assert!(validate_registry(&registry).is_err());
        }
    }

    #[test]
    fn oversized_registry_is_preserved_and_write_failure_keeps_old_state() {
        let app_data = tempfile::tempdir().unwrap();
        let directory = app_data.path().join(STORAGE_DIRECTORY);
        fs::create_dir(&directory).unwrap();
        set_private_directory_permissions(&directory).unwrap();
        let file = directory.join(REGISTRY_FILE);
        fs::write(&file, vec![b'x'; MAX_REGISTRY_BYTES as usize + 1]).unwrap();
        set_private_file_permissions(&file).unwrap();
        let read_only_store = SiteProfileStore::new(app_data.path().to_path_buf());
        assert!(!read_only_store.snapshot().unwrap().writable);
        assert_eq!(fs::metadata(&file).unwrap().len(), MAX_REGISTRY_BYTES + 1);

        let (app_data, repository, store) = store();
        let registered = register(&store, repository.path(), "One", 0);
        let file = app_data.path().join(STORAGE_DIRECTORY).join(REGISTRY_FILE);
        let replacement = br#"{"schemaVersion":1,"profiles":[],"revision":0}"#;
        fs::write(&file, replacement).unwrap();
        set_private_file_permissions(&file).unwrap();
        let error = store
            .rename(&registered.profiles[0].profile_id, "Two", 1)
            .unwrap_err();
        assert_eq!(error.code, "site_profiles_persist_failed");
        let snapshot = store.snapshot().unwrap();
        assert_eq!(snapshot.profiles[0].name, "One");
        assert_eq!(snapshot.revision, 1);
        assert!(!snapshot.writable);
        assert_eq!(fs::read(&file).unwrap(), replacement);
    }

    #[cfg(unix)]
    #[test]
    fn unsafe_fifo_and_symlink_storage_are_rejected_without_writes() {
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;
        use std::os::unix::fs::symlink;

        let app_data = tempfile::tempdir().unwrap();
        let directory = app_data.path().join(STORAGE_DIRECTORY);
        fs::create_dir(&directory).unwrap();
        set_private_directory_permissions(&directory).unwrap();
        let fifo = directory.join(REGISTRY_FILE);
        let fifo_path = CString::new(fifo.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo_path.as_ptr(), 0o600) }, 0);
        assert!(read_registry_file(&fifo).is_err());
        assert!(
            !SiteProfileStore::new(app_data.path().to_path_buf())
                .snapshot()
                .unwrap()
                .writable
        );

        let (app_data, repository, store) = store();
        register(&store, repository.path(), "One", 0);
        let directory = app_data.path().join(STORAGE_DIRECTORY);
        let moved = app_data.path().join("site-profiles-moved");
        let outside = app_data.path().join("outside");
        fs::rename(&directory, &moved).unwrap();
        fs::create_dir(&outside).unwrap();
        set_private_directory_permissions(&outside).unwrap();
        symlink(&outside, &directory).unwrap();
        let snapshot = store.snapshot().unwrap();
        let error = store
            .rename(&snapshot.profiles[0].profile_id, "Two", 1)
            .unwrap_err();
        assert_eq!(error.code, "site_profiles_persist_failed");
        assert!(!outside.join(REGISTRY_FILE).exists());
    }

    #[cfg(unix)]
    #[test]
    fn new_storage_permissions_are_private() {
        use std::os::unix::fs::MetadataExt;
        let (app_data, repository, store) = store();
        register(&store, repository.path(), "One", 0);
        assert_eq!(
            fs::metadata(app_data.path().join(STORAGE_DIRECTORY))
                .unwrap()
                .mode()
                & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(app_data.path().join(STORAGE_DIRECTORY).join(REGISTRY_FILE))
                .unwrap()
                .mode()
                & 0o777,
            0o600
        );
    }

    #[cfg(unix)]
    #[test]
    fn register_rejects_symlink_and_non_directory_roots() {
        use std::os::unix::fs::symlink;
        let (_app_data, repository, store) = store();
        assert_eq!(
            store
                .register(Path::new("relative-root"), "Relative", 0)
                .unwrap_err()
                .code,
            "site_profile_root_invalid"
        );
        let target = tempfile::tempdir().unwrap();
        let link = repository.path().join("linked-root");
        symlink(target.path(), &link).unwrap();
        assert_eq!(
            store.register(&link, "Link", 0).unwrap_err().code,
            "site_profile_root_invalid"
        );
        let file = repository.path().join("not-directory");
        fs::write(&file, b"x").unwrap();
        assert_eq!(
            store.register(&file, "File", 0).unwrap_err().code,
            "site_profile_root_invalid"
        );
        let control = repository.path().join("control\nroot");
        fs::create_dir(&control).unwrap();
        assert_eq!(
            store.register(&control, "Control", 0).unwrap_err().code,
            "site_profile_root_invalid"
        );
    }
}
