//! Private, non-secret storage for reusable AI provider profiles.
//!
//! Credentials and arbitrary headers are deliberately absent from both the
//! public DTO and the on-disk schema. Provider endpoint/model validation is
//! delegated to `AiProviderConfig` so saved profiles obey request-time policy.

use serde::{Deserialize, Serialize};
use std::{
    fs::{self, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;

#[cfg(unix)]
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};

use super::ai_provider::{AiError, AiProviderConfig, AiProviderKind};

pub const MAX_AI_PROVIDER_PROFILES: usize = 16;

const PROFILE_SCHEMA_VERSION: u32 = 1;
const PROFILE_DIRECTORY_NAME: &str = "ai-provider-profiles-v1";
const PROFILE_FILE_NAME: &str = "profiles.json";
const MAX_PROFILE_FILE_BYTES: u64 = 128 * 1024;
const MAX_PROFILE_NAME_BYTES: usize = 80;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct AiProviderProfile {
    pub profile_id: String,
    pub name: String,
    pub provider: AiProviderKind,
    pub endpoint: String,
    pub model: String,
    pub streaming: bool,
    pub created_at_epoch_seconds: i64,
    pub updated_at_epoch_seconds: i64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AiProviderProfileDeleteResult {
    pub profile_id: String,
    pub deleted: bool,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct StoredProfiles {
    schema_version: u32,
    profiles: Vec<AiProviderProfile>,
}

pub struct AiProviderProfileStore {
    app_data_directory: PathBuf,
    storage_directory: PathBuf,
    profiles_file: PathBuf,
}

impl AiProviderProfileStore {
    pub fn new(app_data_directory: PathBuf) -> Self {
        let storage_directory = app_data_directory.join(PROFILE_DIRECTORY_NAME);
        let profiles_file = storage_directory.join(PROFILE_FILE_NAME);
        Self {
            app_data_directory,
            storage_directory,
            profiles_file,
        }
    }

    #[cfg(test)]
    pub fn profiles_path(&self) -> &Path {
        &self.profiles_file
    }

    pub fn list(&self) -> Result<Vec<AiProviderProfile>, AiError> {
        let mut profiles = self.load()?;
        sort_profiles(&mut profiles);
        Ok(profiles)
    }

    pub fn save(
        &self,
        profile_id: Option<&str>,
        name: &str,
        config: AiProviderConfig,
        streaming: bool,
    ) -> Result<AiProviderProfile, AiError> {
        validate_profile_name(name)?;
        let config = AiProviderConfig::new(config.provider, &config.endpoint, &config.model)?;
        let mut profiles = self.load()?;
        let now = epoch_seconds()?;
        let saved = if let Some(profile_id) = profile_id {
            let canonical_id = validate_profile_id(profile_id)?;
            let existing = profiles
                .iter_mut()
                .find(|profile| profile.profile_id == canonical_id)
                .ok_or_else(|| {
                    AiError::new("ai_profile_not_found", "AI provider profile was not found.")
                })?;
            existing.name = name.to_string();
            existing.provider = config.provider;
            existing.endpoint = config.endpoint;
            existing.model = config.model;
            existing.streaming = streaming;
            existing.updated_at_epoch_seconds = now.max(existing.updated_at_epoch_seconds);
            existing.clone()
        } else {
            if profiles.len() >= MAX_AI_PROVIDER_PROFILES {
                return Err(AiError::new(
                    "ai_profile_limit_reached",
                    "The AI provider profile limit has been reached.",
                ));
            }
            let profile = AiProviderProfile {
                profile_id: Uuid::new_v4().to_string(),
                name: name.to_string(),
                provider: config.provider,
                endpoint: config.endpoint,
                model: config.model,
                streaming,
                created_at_epoch_seconds: now,
                updated_at_epoch_seconds: now,
            };
            profiles.push(profile.clone());
            profile
        };
        self.persist(&profiles)?;
        Ok(saved)
    }

    pub fn delete(&self, profile_id: &str) -> Result<AiProviderProfileDeleteResult, AiError> {
        let canonical_id = validate_profile_id(profile_id)?;
        let mut profiles = self.load()?;
        let original_len = profiles.len();
        profiles.retain(|profile| profile.profile_id != canonical_id);
        let deleted = profiles.len() != original_len;
        if deleted {
            self.persist(&profiles)?;
        }
        Ok(AiProviderProfileDeleteResult {
            profile_id: canonical_id,
            deleted,
        })
    }

    fn load(&self) -> Result<Vec<AiProviderProfile>, AiError> {
        if !inspect_storage_directory(&self.app_data_directory, &self.storage_directory)? {
            return Ok(Vec::new());
        }
        let Some(expected_size) = inspect_optional_profile_file(&self.profiles_file)? else {
            return Ok(Vec::new());
        };
        let serialized = read_profile_file(&self.profiles_file, expected_size)?;
        let stored: StoredProfiles = serde_json::from_slice(&serialized).map_err(|_| {
            AiError::new(
                "ai_profile_store_invalid",
                "AI provider profile storage is malformed.",
            )
        })?;
        if stored.schema_version != PROFILE_SCHEMA_VERSION
            || stored.profiles.len() > MAX_AI_PROVIDER_PROFILES
        {
            return Err(AiError::new(
                "ai_profile_store_invalid",
                "AI provider profile storage has an unsupported shape.",
            ));
        }
        let mut ids = std::collections::HashSet::with_capacity(stored.profiles.len());
        for profile in &stored.profiles {
            validate_loaded_profile(profile)?;
            if !ids.insert(&profile.profile_id) {
                return Err(AiError::new(
                    "ai_profile_store_invalid",
                    "AI provider profile storage contains duplicate IDs.",
                ));
            }
        }
        Ok(stored.profiles)
    }

    fn persist(&self, profiles: &[AiProviderProfile]) -> Result<(), AiError> {
        if profiles.len() > MAX_AI_PROVIDER_PROFILES {
            return Err(AiError::new(
                "ai_profile_limit_reached",
                "The AI provider profile limit has been reached.",
            ));
        }
        ensure_profile_storage_directory(&self.app_data_directory, &self.storage_directory)?;
        let target_exists = inspect_optional_profile_file(&self.profiles_file)?.is_some();
        let serialized = serde_json::to_vec(&StoredProfiles {
            schema_version: PROFILE_SCHEMA_VERSION,
            profiles: profiles.to_vec(),
        })
        .map_err(|_| {
            AiError::new(
                "ai_profile_store_write_failed",
                "Unable to encode AI provider profiles.",
            )
        })?;
        if serialized.len() as u64 > MAX_PROFILE_FILE_BYTES {
            return Err(AiError::new(
                "ai_profile_store_write_failed",
                "AI provider profiles exceeded the storage limit.",
            ));
        }
        atomic_write_profiles(
            &self.storage_directory,
            &self.profiles_file,
            &serialized,
            target_exists,
        )
    }
}

fn validate_profile_name(name: &str) -> Result<(), AiError> {
    if name.is_empty()
        || name.trim() != name
        || name.len() > MAX_PROFILE_NAME_BYTES
        || name.chars().any(char::is_control)
    {
        return Err(AiError::new(
            "ai_profile_name_invalid",
            "AI provider profile name is invalid.",
        ));
    }
    Ok(())
}

fn validate_profile_id(profile_id: &str) -> Result<String, AiError> {
    let parsed = Uuid::parse_str(profile_id).map_err(|_| {
        AiError::new(
            "ai_profile_id_invalid",
            "AI provider profile ID is invalid.",
        )
    })?;
    let canonical = parsed.to_string();
    if canonical != profile_id {
        return Err(AiError::new(
            "ai_profile_id_invalid",
            "AI provider profile ID is invalid.",
        ));
    }
    Ok(canonical)
}

fn validate_loaded_profile(profile: &AiProviderProfile) -> Result<(), AiError> {
    validate_profile_id(&profile.profile_id).map_err(|_| invalid_profile_store())?;
    validate_profile_name(&profile.name).map_err(|_| invalid_profile_store())?;
    let canonical = AiProviderConfig::new(profile.provider, &profile.endpoint, &profile.model)
        .map_err(|_| invalid_profile_store())?;
    if canonical.endpoint != profile.endpoint
        || canonical.model != profile.model
        || profile.created_at_epoch_seconds < 0
        || profile.updated_at_epoch_seconds < profile.created_at_epoch_seconds
    {
        return Err(invalid_profile_store());
    }
    Ok(())
}

/// Pure validation for an already bounded private backup source, without optional-store defaults.
pub(super) fn validate_backup_json(bytes: &[u8]) -> Result<usize, AiError> {
    let stored: StoredProfiles =
        serde_json::from_slice(bytes).map_err(|_| invalid_profile_store())?;
    if stored.schema_version != PROFILE_SCHEMA_VERSION
        || stored.profiles.len() > MAX_AI_PROVIDER_PROFILES
    {
        return Err(invalid_profile_store());
    }
    let mut ids = std::collections::HashSet::new();
    for profile in &stored.profiles {
        validate_loaded_profile(profile)?;
        if !ids.insert(&profile.profile_id) {
            return Err(invalid_profile_store());
        }
    }
    Ok(stored.profiles.len())
}

fn invalid_profile_store() -> AiError {
    AiError::new(
        "ai_profile_store_invalid",
        "AI provider profile storage contains invalid data.",
    )
}

fn epoch_seconds() -> Result<i64, AiError> {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| {
            AiError::new(
                "ai_profile_store_write_failed",
                "The system clock is unavailable.",
            )
        })?
        .as_secs();
    i64::try_from(seconds).map_err(|_| {
        AiError::new(
            "ai_profile_store_write_failed",
            "The system clock is unavailable.",
        )
    })
}

fn sort_profiles(profiles: &mut [AiProviderProfile]) {
    profiles.sort_by(|left, right| {
        right
            .updated_at_epoch_seconds
            .cmp(&left.updated_at_epoch_seconds)
            .then_with(|| left.profile_id.cmp(&right.profile_id))
    });
}

/// Returns `false` for a clean missing app-data/profile directory and rejects
/// symlinks or non-directories without creating anything.
fn inspect_storage_directory(
    app_data_directory: &Path,
    storage_directory: &Path,
) -> Result<bool, AiError> {
    if !app_data_directory.is_absolute() {
        return Err(invalid_profile_store());
    }
    match fs::symlink_metadata(app_data_directory) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
            return Err(invalid_profile_store())
        }
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(_) => return Err(invalid_profile_store()),
    }
    match fs::symlink_metadata(storage_directory) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
            Err(invalid_profile_store())
        }
        Ok(metadata) => {
            #[cfg(unix)]
            if metadata.mode() & 0o077 != 0 {
                return Err(invalid_profile_store());
            }
            Ok(true)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(_) => Err(invalid_profile_store()),
    }
}

fn inspect_optional_profile_file(path: &Path) -> Result<Option<u64>, AiError> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(invalid_profile_store()),
    };
    if metadata.file_type().is_symlink()
        || !metadata.is_file()
        || metadata.len() > MAX_PROFILE_FILE_BYTES
    {
        return Err(invalid_profile_store());
    }
    #[cfg(unix)]
    if metadata.mode() & 0o077 != 0 {
        return Err(invalid_profile_store());
    }
    Ok(Some(metadata.len()))
}

fn read_profile_file(path: &Path, expected_size: u64) -> Result<Vec<u8>, AiError> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    let mut file = options.open(path).map_err(|_| invalid_profile_store())?;
    let metadata = file.metadata().map_err(|_| invalid_profile_store())?;
    if !metadata.is_file()
        || metadata.len() != expected_size
        || metadata.len() > MAX_PROFILE_FILE_BYTES
    {
        return Err(invalid_profile_store());
    }
    #[cfg(unix)]
    if metadata.mode() & 0o077 != 0 {
        return Err(invalid_profile_store());
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.read_to_end(&mut bytes)
        .map_err(|_| invalid_profile_store())?;
    if bytes.len() as u64 != metadata.len() {
        return Err(invalid_profile_store());
    }
    Ok(bytes)
}

fn ensure_profile_storage_directory(
    app_data_directory: &Path,
    storage_directory: &Path,
) -> Result<(), AiError> {
    if !app_data_directory.is_absolute() {
        return Err(AiError::new(
            "ai_profile_store_write_failed",
            "AI provider profile storage path is invalid.",
        ));
    }
    match fs::symlink_metadata(app_data_directory) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
            return Err(AiError::new(
                "ai_profile_store_write_failed",
                "AI provider profile storage path is not safe.",
            ))
        }
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            fs::create_dir_all(app_data_directory).map_err(|_| {
                AiError::new(
                    "ai_profile_store_write_failed",
                    "Unable to create AI provider profile storage.",
                )
            })?;
            let metadata = fs::symlink_metadata(app_data_directory).map_err(|_| {
                AiError::new(
                    "ai_profile_store_write_failed",
                    "Unable to inspect AI provider profile storage.",
                )
            })?;
            if metadata.file_type().is_symlink() || !metadata.is_dir() {
                return Err(AiError::new(
                    "ai_profile_store_write_failed",
                    "AI provider profile storage path is not safe.",
                ));
            }
        }
        Err(_) => {
            return Err(AiError::new(
                "ai_profile_store_write_failed",
                "Unable to inspect AI provider profile storage.",
            ))
        }
    }
    match fs::symlink_metadata(storage_directory) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
            return Err(AiError::new(
                "ai_profile_store_write_failed",
                "AI provider profile storage path is not safe.",
            ))
        }
        Ok(metadata) =>
        {
            #[cfg(unix)]
            if metadata.mode() & 0o077 != 0 {
                return Err(AiError::new(
                    "ai_profile_store_write_failed",
                    "AI provider profile storage path is not private.",
                ));
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let mut builder = fs::DirBuilder::new();
            #[cfg(unix)]
            builder.mode(0o700);
            builder
                .create(storage_directory)
                .or_else(|create_error| {
                    if create_error.kind() == std::io::ErrorKind::AlreadyExists {
                        Ok(())
                    } else {
                        Err(create_error)
                    }
                })
                .map_err(|_| {
                    AiError::new(
                        "ai_profile_store_write_failed",
                        "Unable to create AI provider profile storage.",
                    )
                })?;
            let metadata = fs::symlink_metadata(storage_directory).map_err(|_| {
                AiError::new(
                    "ai_profile_store_write_failed",
                    "Unable to inspect AI provider profile storage.",
                )
            })?;
            if metadata.file_type().is_symlink() || !metadata.is_dir() {
                return Err(AiError::new(
                    "ai_profile_store_write_failed",
                    "AI provider profile storage path is not safe.",
                ));
            }
            #[cfg(unix)]
            if metadata.mode() & 0o077 != 0 {
                return Err(AiError::new(
                    "ai_profile_store_write_failed",
                    "AI provider profile storage path is not private.",
                ));
            }
        }
        Err(_) => {
            return Err(AiError::new(
                "ai_profile_store_write_failed",
                "Unable to inspect AI provider profile storage.",
            ))
        }
    }
    Ok(())
}

fn atomic_write_profiles(
    directory: &Path,
    target: &Path,
    bytes: &[u8],
    target_exists: bool,
) -> Result<(), AiError> {
    let mut temporary = None;
    let mut temporary_file = None;
    for _ in 0..8 {
        let path = directory.join(format!(".profiles-{}.tmp", Uuid::new_v4()));
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        options
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
        match options.open(&path) {
            Ok(file) => {
                temporary = Some(path);
                temporary_file = Some(file);
                break;
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(_) => break,
        }
    }
    let temporary = temporary.ok_or_else(|| {
        AiError::new(
            "ai_profile_store_write_failed",
            "Unable to create temporary AI provider profile storage.",
        )
    })?;
    let mut file = temporary_file.expect("temporary file accompanies its path");
    let result = (|| {
        file.write_all(bytes)
            .and_then(|_| file.sync_all())
            .map_err(|_| {
                AiError::new(
                    "ai_profile_store_write_failed",
                    "Unable to write AI provider profiles.",
                )
            })?;
        drop(file);
        let current_exists = inspect_optional_profile_file(target)?.is_some();
        if current_exists != target_exists {
            return Err(AiError::new(
                "ai_profile_store_write_failed",
                "AI provider profile storage changed before replacement.",
            ));
        }
        let rename_result = if target_exists {
            fs::rename(&temporary, target)
        } else {
            rename_profile_noreplace(&temporary, target)
        };
        rename_result.map_err(|_| {
            AiError::new(
                "ai_profile_store_write_failed",
                "Unable to replace AI provider profiles.",
            )
        })?;
        let _ = sync_profile_directory(directory);
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

#[cfg(target_os = "linux")]
fn rename_profile_noreplace(source: &Path, target: &Path) -> std::io::Result<()> {
    use std::{ffi::CString, os::unix::ffi::OsStrExt};
    let source = CString::new(source.as_os_str().as_bytes())
        .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
    let target = CString::new(target.as_os_str().as_bytes())
        .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
    let result = unsafe {
        libc::renameat2(
            libc::AT_FDCWD,
            source.as_ptr(),
            libc::AT_FDCWD,
            target.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    if result == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(not(target_os = "linux"))]
fn rename_profile_noreplace(source: &Path, target: &Path) -> std::io::Result<()> {
    if target.try_exists()? {
        return Err(std::io::Error::from(std::io::ErrorKind::AlreadyExists));
    }
    fs::rename(source, target)
}

fn sync_profile_directory(directory: &Path) -> Result<(), AiError> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    options.custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC);
    options
        .open(directory)
        .and_then(|file| file.sync_all())
        .map_err(|_| {
            AiError::new(
                "ai_profile_store_write_failed",
                "Unable to synchronize AI provider profile storage.",
            )
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> (tempfile::TempDir, AiProviderProfileStore) {
        let directory = tempfile::tempdir().unwrap();
        let store = AiProviderProfileStore::new(directory.path().join("app-data"));
        (directory, store)
    }

    fn config(model: &str) -> AiProviderConfig {
        AiProviderConfig::new(
            AiProviderKind::OpenaiCompatible,
            "https://api.example.com/v1",
            model,
        )
        .unwrap()
    }

    #[test]
    fn persists_only_bounded_non_secret_fields_and_reloads() {
        let (_directory, store) = store();
        let saved = store.save(None, "Work", config("model-a"), true).unwrap();
        let raw = fs::read_to_string(store.profiles_path()).unwrap();
        for forbidden in ["token", "authorization", "header", "passphrase", "secret"] {
            assert!(!raw.to_ascii_lowercase().contains(forbidden));
        }
        let restarted = AiProviderProfileStore::new(store.app_data_directory.clone());
        assert_eq!(restarted.list().unwrap(), vec![saved]);
    }

    #[test]
    fn validates_name_endpoint_id_and_limit() {
        let (_directory, store) = store();
        assert_eq!(
            store
                .save(None, " bad ", config("model"), true)
                .unwrap_err()
                .code,
            "ai_profile_name_invalid"
        );
        let unsafe_config = AiProviderConfig {
            provider: AiProviderKind::OpenaiCompatible,
            endpoint: "http://api.example.com".to_string(),
            model: "model".to_string(),
        };
        assert_eq!(
            store
                .save(None, "Bad", unsafe_config, true)
                .unwrap_err()
                .code,
            "ai_endpoint_policy_rejected"
        );
        assert_eq!(
            store.delete("not-a-uuid").unwrap_err().code,
            "ai_profile_id_invalid"
        );
        for index in 0..MAX_AI_PROVIDER_PROFILES {
            store
                .save(None, &format!("Profile {index}"), config("model"), false)
                .unwrap();
        }
        assert_eq!(
            store
                .save(None, "Too many", config("model"), false)
                .unwrap_err()
                .code,
            "ai_profile_limit_reached"
        );
    }

    #[test]
    fn update_preserves_creation_and_delete_reports_missing() {
        let (_directory, store) = store();
        let original = store.save(None, "One", config("model-a"), true).unwrap();
        let updated = store
            .save(
                Some(&original.profile_id),
                "Renamed",
                config("model-b"),
                false,
            )
            .unwrap();
        assert_eq!(
            updated.created_at_epoch_seconds,
            original.created_at_epoch_seconds
        );
        assert_eq!(updated.name, "Renamed");
        assert_eq!(updated.model, "model-b");
        assert!(!updated.streaming);
        let missing_id = Uuid::new_v4().to_string();
        assert!(!store.delete(&missing_id).unwrap().deleted);
        assert!(store.delete(&original.profile_id).unwrap().deleted);
    }

    #[test]
    fn list_orders_updated_descending_then_id() {
        let (_directory, store) = store();
        ensure_profile_storage_directory(&store.app_data_directory, &store.storage_directory)
            .unwrap();
        let first_id = "00000000-0000-4000-8000-000000000001".to_string();
        let second_id = "00000000-0000-4000-8000-000000000002".to_string();
        let stored = StoredProfiles {
            schema_version: PROFILE_SCHEMA_VERSION,
            profiles: vec![
                AiProviderProfile {
                    profile_id: second_id.clone(),
                    name: "Second".to_string(),
                    provider: AiProviderKind::OpenaiCompatible,
                    endpoint: "https://api.example.com/v1".to_string(),
                    model: "model".to_string(),
                    streaming: true,
                    created_at_epoch_seconds: 1,
                    updated_at_epoch_seconds: 4,
                },
                AiProviderProfile {
                    profile_id: first_id.clone(),
                    name: "First".to_string(),
                    provider: AiProviderKind::OpenaiCompatible,
                    endpoint: "https://api.example.com/v1".to_string(),
                    model: "model".to_string(),
                    streaming: true,
                    created_at_epoch_seconds: 1,
                    updated_at_epoch_seconds: 4,
                },
                AiProviderProfile {
                    profile_id: Uuid::new_v4().to_string(),
                    name: "Old".to_string(),
                    provider: AiProviderKind::OpenaiCompatible,
                    endpoint: "https://api.example.com/v1".to_string(),
                    model: "model".to_string(),
                    streaming: false,
                    created_at_epoch_seconds: 1,
                    updated_at_epoch_seconds: 3,
                },
            ],
        };
        atomic_write_profiles(
            &store.storage_directory,
            &store.profiles_file,
            &serde_json::to_vec(&stored).unwrap(),
            false,
        )
        .unwrap();
        let listed = store.list().unwrap();
        assert_eq!(listed[0].profile_id, first_id);
        assert_eq!(listed[1].profile_id, second_id);
        assert_eq!(listed[2].updated_at_epoch_seconds, 3);
    }

    #[test]
    fn malformed_store_fails_closed_and_is_not_overwritten() {
        let (_directory, store) = store();
        store.save(None, "One", config("model"), true).unwrap();
        fs::write(store.profiles_path(), b"{malformed").unwrap();
        let corrupt = fs::read(store.profiles_path()).unwrap();
        assert_eq!(store.list().unwrap_err().code, "ai_profile_store_invalid");
        assert_eq!(
            store
                .save(None, "Two", config("model"), false)
                .unwrap_err()
                .code,
            "ai_profile_store_invalid"
        );
        assert_eq!(fs::read(store.profiles_path()).unwrap(), corrupt);
    }

    #[cfg(unix)]
    #[test]
    fn creates_private_storage_and_rejects_symlink_file() {
        use std::os::unix::fs::{symlink, PermissionsExt};

        let (directory, store) = store();
        store.save(None, "One", config("model"), true).unwrap();
        assert_eq!(
            fs::metadata(&store.storage_directory)
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(store.profiles_path())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        fs::remove_file(store.profiles_path()).unwrap();
        let target = directory.path().join("target");
        fs::write(&target, b"{}").unwrap();
        symlink(target, store.profiles_path()).unwrap();
        assert_eq!(store.list().unwrap_err().code, "ai_profile_store_invalid");
        assert_eq!(
            store
                .save(None, "Must fail", config("model"), true)
                .unwrap_err()
                .code,
            "ai_profile_store_invalid"
        );
        assert_eq!(fs::read(directory.path().join("target")).unwrap(), b"{}");

        let linked_root = directory.path().join("linked-root");
        symlink(directory.path(), &linked_root).unwrap();
        let linked = AiProviderProfileStore::new(linked_root);
        assert_eq!(linked.list().unwrap_err().code, "ai_profile_store_invalid");
    }
}
