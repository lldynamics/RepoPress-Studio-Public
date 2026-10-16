//! Fail-closed Linux AppImage updater.
//!
//! The webview can only ask for a short-lived review plan and consume that
//! plan once. Network access, signature verification, and replacement remain
//! here; generic Tauri updater commands are never used.

use super::{CommandError, CommandResult, UpdaterConfiguration};
use base64::{engine::general_purpose::STANDARD, Engine as _};
use futures_util::StreamExt;
use minisign_verify::{PublicKey, Signature};
use reqwest::{header::ACCEPT_ENCODING, redirect::Policy, Client};
use semver::Version;
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, VecDeque},
    env,
    ffi::CString,
    fs::{self, OpenOptions},
    io::Write,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    os::unix::{
        ffi::OsStrExt,
        fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    },
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex,
    },
    time::{Duration, Instant},
};
use time::{format_description::well_known::Rfc3339, OffsetDateTime};
use url::Url;
use uuid::Uuid;

const MANIFEST_MAX_BYTES: usize = 64 * 1024;
const ARTIFACT_MAX_BYTES: u64 = 512 * 1024 * 1024;
const PUBLIC_KEY_MAX_BYTES: usize = 8 * 1024;
const SIGNATURE_MAX_BYTES: usize = 64 * 1024;
const URL_MAX_CHARS: usize = 8 * 1024;
const NOTES_MAX_CHARS: usize = 4 * 1024;
const PLAN_LIFETIME: Duration = Duration::from_secs(5 * 60);
const DNS_TIMEOUT: Duration = Duration::from_secs(5);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const MANIFEST_TIMEOUT: Duration = Duration::from_secs(30);
const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(10 * 60);
const MAX_STORED_PLANS: usize = 16;
const LINUX_TARGET: &str = "linux-x86_64";

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppUpdatePlan {
    pub plan_id: String,
    pub current_version: String,
    pub version: String,
    pub published_at: Option<String>,
    pub notes: Option<String>,
    pub download_host: String,
    pub artifact_name: String,
    pub expires_at: String,
    pub warnings: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppUpdateCheck {
    pub supported: bool,
    pub configured: bool,
    pub available: bool,
    pub summary: String,
    pub plan: Option<AppUpdatePlan>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppUpdateInstallResult {
    pub version: String,
    pub installed: bool,
    pub requires_restart: bool,
    pub summary: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AppImageIdentity {
    canonical_path: PathBuf,
    device: u64,
    inode: u64,
    size: u64,
    modified_seconds: i64,
    modified_nanoseconds: i64,
    changed_seconds: i64,
    changed_nanoseconds: i64,
    mode: u32,
}

impl AppImageIdentity {
    fn same_file_state(&self, other: &Self) -> bool {
        self.device == other.device
            && self.inode == other.inode
            && self.size == other.size
            && self.modified_seconds == other.modified_seconds
            && self.modified_nanoseconds == other.modified_nanoseconds
            && self.changed_seconds == other.changed_seconds
            && self.changed_nanoseconds == other.changed_nanoseconds
            && self.mode == other.mode
    }

    // renameat2(RENAME_EXCHANGE) can advance ctime even though the exchanged
    // inode and its contents are unchanged. All other recorded identity fields
    // must still match the file approved before the exchange.
    fn same_exchanged_file(&self, other: &Self) -> bool {
        self.device == other.device
            && self.inode == other.inode
            && self.size == other.size
            && self.modified_seconds == other.modified_seconds
            && self.modified_nanoseconds == other.modified_nanoseconds
            && self.mode == other.mode
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct Candidate {
    version: Version,
    published_at: String,
    notes: String,
    url: Url,
    artifact_name: String,
    signature: String,
}

struct StoredPlan {
    view: AppUpdatePlan,
    candidate: Candidate,
    appimage: AppImageIdentity,
    expires_at: Instant,
}

pub struct UpdateStore {
    plans: Mutex<VecDeque<StoredPlan>>,
    installing: AtomicBool,
}

impl Default for UpdateStore {
    fn default() -> Self {
        Self {
            plans: Mutex::new(VecDeque::new()),
            installing: AtomicBool::new(false),
        }
    }
}

struct InstallPermit<'a>(&'a AtomicBool);

impl Drop for InstallPermit<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

impl UpdateStore {
    fn insert(&self, plan: StoredPlan) -> CommandResult<AppUpdatePlan> {
        let mut plans = self.plans.lock().map_err(|_| {
            error(
                "update_store_unavailable",
                "Update approvals are temporarily unavailable.",
            )
        })?;
        let now = Instant::now();
        plans.retain(|stored| stored.expires_at > now);
        while plans.len() >= MAX_STORED_PLANS {
            plans.pop_front();
        }
        let view = plan.view.clone();
        plans.push_back(plan);
        Ok(view)
    }

    fn consume(&self, plan_id: &str) -> CommandResult<StoredPlan> {
        let mut plans = self.plans.lock().map_err(|_| {
            error(
                "update_store_unavailable",
                "Update approvals are temporarily unavailable.",
            )
        })?;
        let index = plans
            .iter()
            .position(|stored| stored.view.plan_id == plan_id)
            .ok_or_else(|| {
                error(
                    "update_plan_not_found",
                    "The update approval is missing, expired, or already used.",
                )
            })?;
        let stored = plans.remove(index).ok_or_else(|| {
            error(
                "update_plan_not_found",
                "The update approval is missing, expired, or already used.",
            )
        })?;
        if stored.expires_at <= Instant::now() {
            return Err(error(
                "update_plan_expired",
                "The update approval expired. Check for updates again.",
            ));
        }
        Ok(stored)
    }

    fn begin_install(&self) -> CommandResult<InstallPermit<'_>> {
        self.installing
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .map_err(|_| {
                error(
                    "update_install_in_progress",
                    "Another update installation is already in progress.",
                )
            })?;
        Ok(InstallPermit(&self.installing))
    }
}

pub async fn check(store: &UpdateStore) -> CommandResult<AppUpdateCheck> {
    let Some(appimage) = current_appimage()? else {
        return Ok(AppUpdateCheck {
            supported: false,
            configured: embedded_configuration().is_some(),
            available: false,
            summary: "In-app updates are supported only by the AppImage package.".to_string(),
            plan: None,
        });
    };
    let Some(configuration) = embedded_configuration() else {
        return Ok(AppUpdateCheck {
            supported: true,
            configured: false,
            available: false,
            summary: "This AppImage was built without an approved update endpoint and public key."
                .to_string(),
            plan: None,
        });
    };

    let public_key = parse_public_key(configuration.public_key)?;
    let current_version = current_version()?;
    let endpoint = endpoint_url(configuration.endpoint, &current_version)?;
    let candidate = fetch_candidate(&endpoint, &current_version).await?;
    let Some(candidate) = candidate else {
        return Ok(AppUpdateCheck {
            supported: true,
            configured: true,
            available: false,
            summary: "No newer signed AppImage release is available.".to_string(),
            plan: None,
        });
    };
    validate_signature(&public_key, &candidate.signature, &candidate.artifact_name)?;

    let expires_at = Instant::now().checked_add(PLAN_LIFETIME).ok_or_else(|| {
        error(
            "update_clock_invalid",
            "The update approval expiry could not be calculated.",
        )
    })?;
    let duration_seconds = i64::try_from(PLAN_LIFETIME.as_secs()).map_err(|_| {
        error(
            "update_clock_invalid",
            "The update approval expiry could not be calculated.",
        )
    })?;
    let expires_display = OffsetDateTime::now_utc()
        .checked_add(time::Duration::seconds(duration_seconds))
        .ok_or_else(|| {
            error(
                "update_clock_invalid",
                "The update approval expiry could not be calculated.",
            )
        })?
        .format(&Rfc3339)
        .map_err(|_| {
            error(
                "update_clock_invalid",
                "The update approval expiry could not be formatted.",
            )
        })?;
    let plan = AppUpdatePlan {
        plan_id: Uuid::new_v4().to_string(),
        current_version: current_version.to_string(),
        version: candidate.version.to_string(),
        published_at: Some(candidate.published_at.clone()),
        notes: Some(candidate.notes.clone()),
        download_host: candidate.url.host_str().unwrap_or_default().to_string(),
        artifact_name: candidate.artifact_name.clone(),
        expires_at: expires_display,
        warnings: vec![
            "Installation is explicit, replaces only this AppImage, and requires a manual restart."
                .to_string(),
        ],
    };
    let plan = store.insert(StoredPlan {
        view: plan,
        candidate,
        appimage,
        expires_at,
    })?;
    Ok(AppUpdateCheck {
        supported: true,
        configured: true,
        available: true,
        summary: "A signed AppImage update is ready for review.".to_string(),
        plan: Some(plan),
    })
}

pub async fn install(
    store: &UpdateStore,
    plan_id: String,
) -> CommandResult<AppUpdateInstallResult> {
    let _permit = store.begin_install()?;
    let approved = store.consume(&plan_id)?;
    let configuration = embedded_configuration().ok_or_else(|| {
        error(
            "update_configuration_missing",
            "The embedded updater configuration is unavailable.",
        )
    })?;
    let current = current_appimage()?.ok_or_else(|| {
        error(
            "update_unsupported",
            "This process is not running from an approved AppImage.",
        )
    })?;
    if current.canonical_path != approved.appimage.canonical_path
        || !current.same_file_state(&approved.appimage)
    {
        return Err(error(
            "update_identity_changed",
            "The running AppImage changed after the update was approved.",
        ));
    }

    let public_key = parse_public_key(configuration.public_key)?;
    let current_version = current_version()?;
    let endpoint = endpoint_url(configuration.endpoint, &current_version)?;
    let candidate = fetch_candidate(&endpoint, &current_version)
        .await?
        .ok_or_else(|| {
            error(
                "update_candidate_changed",
                "The approved update is no longer available.",
            )
        })?;
    if candidate != approved.candidate {
        return Err(error(
            "update_candidate_changed",
            "The update manifest changed after approval. Check again before installing.",
        ));
    }
    let signature =
        validate_signature(&public_key, &candidate.signature, &candidate.artifact_name)?;

    let before_download = inspect_appimage(&approved.appimage.canonical_path)?;
    if !before_download.same_file_state(&approved.appimage) {
        return Err(error(
            "update_identity_changed",
            "The running AppImage changed before the download began.",
        ));
    }
    let staged =
        download_candidate(&candidate, &public_key, &signature, &approved.appimage).await?;
    let before_replace = inspect_appimage(&approved.appimage.canonical_path)?;
    if !before_replace.same_file_state(&approved.appimage) {
        return Err(error(
            "update_identity_changed",
            "The running AppImage changed before replacement.",
        ));
    }
    if let Err(replace_error) = exchange_replace(
        &approved.appimage.canonical_path,
        staged.path(),
        &approved.appimage,
        staged.identity()?,
    ) {
        // If the kernel exchange happened but rollback failed, both files are
        // evidence/recovery material. Do not let the temporary-file guard
        // delete the exchanged old AppImage.
        if replace_error.code == "update_replace_uncertain" {
            staged.disarm();
        }
        return Err(replace_error);
    }
    staged.disarm();

    Ok(AppUpdateInstallResult {
        version: candidate.version.to_string(),
        installed: true,
        requires_restart: true,
        summary: "The signed AppImage was installed. Restart RepoPress when you are ready."
            .to_string(),
    })
}

pub(super) fn configuration_is_valid(endpoint: &str, public_key: &str) -> bool {
    Version::parse("0.0.0").is_ok_and(|version| {
        endpoint_url(endpoint, &version).is_ok() && parse_public_key(public_key).is_ok()
    })
}

fn embedded_configuration() -> Option<UpdaterConfiguration<'static>> {
    match (
        option_env!("REPOPRESS_UPDATER_ENDPOINT"),
        option_env!("REPOPRESS_UPDATER_PUBKEY"),
    ) {
        (Some(endpoint), Some(public_key)) if configuration_is_valid(endpoint, public_key) => {
            Some(UpdaterConfiguration {
                endpoint,
                public_key,
            })
        }
        _ => None,
    }
}

fn current_version() -> CommandResult<Version> {
    Version::parse(env!("CARGO_PKG_VERSION")).map_err(|_| {
        error(
            "update_version_invalid",
            "The installed application version is not valid semantic versioning.",
        )
    })
}

fn current_appimage() -> CommandResult<Option<AppImageIdentity>> {
    if !cfg!(target_os = "linux") {
        return Ok(None);
    }
    let Some(path) = env::var_os("APPIMAGE") else {
        return Ok(None);
    };
    inspect_appimage(Path::new(&path)).map(Some)
}

fn endpoint_url(template: &str, current_version: &Version) -> CommandResult<Url> {
    let expanded = template
        .replace("{{target}}", "linux")
        .replace("{{arch}}", "x86_64")
        .replace("{{current_version}}", &current_version.to_string());
    if expanded.contains("{{") || expanded.contains("}}") {
        return Err(error(
            "update_endpoint_invalid",
            "The update endpoint contains an unsupported template field.",
        ));
    }
    parse_public_https_url(&expanded, "update_endpoint_invalid")
}

async fn fetch_candidate(
    endpoint: &Url,
    current_version: &Version,
) -> CommandResult<Option<Candidate>> {
    let client = pinned_client(endpoint).await?;
    let response = client
        .get(endpoint.clone())
        .header(ACCEPT_ENCODING, "identity")
        .timeout(MANIFEST_TIMEOUT)
        .send()
        .await
        .map_err(|_| {
            error(
                "update_manifest_unavailable",
                "The update manifest could not be retrieved.",
            )
        })?;
    if !response.status().is_success() {
        return Err(error(
            "update_manifest_status",
            "The update manifest returned an unsuccessful status.",
        ));
    }
    if response
        .content_length()
        .is_some_and(|length| length > MANIFEST_MAX_BYTES as u64)
    {
        return Err(error(
            "update_manifest_too_large",
            "The update manifest exceeds its size limit.",
        ));
    }
    let mut bytes = Vec::new();
    let mut stream = response.bytes_stream();
    while let Some(next) = stream.next().await {
        let chunk = next.map_err(|_| {
            error(
                "update_manifest_unavailable",
                "The update manifest could not be read.",
            )
        })?;
        if bytes.len().saturating_add(chunk.len()) > MANIFEST_MAX_BYTES {
            return Err(error(
                "update_manifest_too_large",
                "The update manifest exceeds its size limit.",
            ));
        }
        bytes.extend_from_slice(&chunk);
    }
    parse_manifest(&bytes, current_version)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    version: String,
    notes: String,
    pub_date: String,
    platforms: BTreeMap<String, Platform>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Platform {
    signature: String,
    url: String,
}

fn parse_manifest(bytes: &[u8], current_version: &Version) -> CommandResult<Option<Candidate>> {
    let manifest: Manifest = serde_json::from_slice(bytes).map_err(|_| {
        error(
            "update_manifest_invalid",
            "The update manifest is not valid strict JSON.",
        )
    })?;
    let version = Version::parse(&manifest.version).map_err(|_| {
        error(
            "update_manifest_invalid",
            "The update manifest contains an invalid version.",
        )
    })?;
    if version.to_string() != manifest.version {
        return Err(error(
            "update_manifest_invalid",
            "The update version is not canonical semantic versioning.",
        ));
    }
    if manifest.platforms.len() != 1 {
        return Err(error(
            "update_target_invalid",
            "The update manifest must contain exactly one approved Linux target.",
        ));
    }
    let platform = manifest.platforms.get(LINUX_TARGET).ok_or_else(|| {
        error(
            "update_target_missing",
            "The update manifest has no approved Linux target.",
        )
    })?;
    let notes = validate_notes(manifest.notes)?;
    let published_at = validate_publication_date(manifest.pub_date)?;
    if platform.signature.is_empty()
        || platform.signature.len() > SIGNATURE_MAX_BYTES
        || platform.signature.chars().any(char::is_control)
    {
        return Err(error(
            "update_signature_invalid",
            "The update signature is malformed or exceeds its size limit.",
        ));
    }
    let url = parse_public_https_url(&platform.url, "update_artifact_url_invalid")?;
    let artifact_name = artifact_name(&url, &version)?;
    let candidate = Candidate {
        version,
        published_at,
        notes,
        url,
        artifact_name,
        signature: platform.signature.clone(),
    };
    if candidate.version <= *current_version {
        Ok(None)
    } else {
        Ok(Some(candidate))
    }
}

fn validate_notes(value: String) -> CommandResult<String> {
    if value.is_empty()
        || value.chars().count() > NOTES_MAX_CHARS
        || value.chars().any(char::is_control)
    {
        return Err(error(
            "update_notes_invalid",
            "The release notes must contain 1-4096 characters without control characters.",
        ));
    }
    Ok(value)
}

fn validate_publication_date(value: String) -> CommandResult<String> {
    if value.is_empty()
        || value.len() > 64
        || value
            .chars()
            .any(|character| character.is_control() || character.is_whitespace())
        || OffsetDateTime::parse(&value, &Rfc3339).is_err()
    {
        return Err(error(
            "update_publication_date_invalid",
            "The update publication date must be RFC 3339.",
        ));
    }
    Ok(value)
}

fn parse_public_https_url(value: &str, code: &str) -> CommandResult<Url> {
    if value.is_empty()
        || value.chars().count() > URL_MAX_CHARS
        || value
            .chars()
            .any(|character| character.is_control() || character.is_whitespace())
    {
        return Err(error(code, "The URL is outside the approved HTTPS policy."));
    }
    let url = Url::parse(value)
        .map_err(|_| error(code, "The URL is outside the approved HTTPS policy."))?;
    let host = url
        .host_str()
        .ok_or_else(|| error(code, "The URL is outside the approved HTTPS policy."))?;
    let lower_host = host.to_ascii_lowercase();
    if url.scheme() != "https"
        || url.port_or_known_default() != Some(443)
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
        || lower_host.ends_with('.')
        || !lower_host.contains('.')
        || lower_host == "localhost"
        || lower_host.ends_with(".localhost")
        || lower_host.ends_with(".local")
        || host.parse::<IpAddr>().is_ok()
    {
        return Err(error(code, "The URL is outside the approved HTTPS policy."));
    }
    Ok(url)
}

fn artifact_name(url: &Url, version: &Version) -> CommandResult<String> {
    let raw = url
        .path_segments()
        .and_then(|mut segments| segments.next_back())
        .ok_or_else(|| {
            error(
                "update_artifact_invalid",
                "The update URL does not contain an artifact filename.",
            )
        })?;
    let decoded = percent_encoding::percent_decode_str(raw)
        .decode_utf8()
        .map_err(|_| {
            error(
                "update_artifact_invalid",
                "The update artifact filename is not valid UTF-8.",
            )
        })?
        .into_owned();
    if decoded.is_empty()
        || decoded == "."
        || decoded == ".."
        || decoded.chars().count() > 255
        || decoded
            .chars()
            .any(|character| character.is_control() || matches!(character, '/' | '\\' | '%'))
        || !decoded.ends_with(".AppImage")
        || !contains_exact_version(&decoded, &version.to_string())
    {
        return Err(error(
            "update_artifact_invalid",
            "The update artifact filename is not approved for this version.",
        ));
    }
    Ok(decoded)
}

fn contains_exact_version(filename: &str, version: &str) -> bool {
    filename.match_indices(version).any(|(start, _)| {
        let before = filename[..start].chars().next_back();
        let end = start + version.len();
        let after = filename[end..].chars().next();
        !before.is_some_and(|character| character.is_ascii_alphanumeric())
            && !after.is_some_and(|character| character.is_ascii_alphanumeric())
    })
}

fn parse_public_key(encoded: &str) -> CommandResult<PublicKey> {
    let text = decode_outer_base64(
        encoded,
        PUBLIC_KEY_MAX_BYTES,
        "update_key_invalid",
        "The embedded updater public key is malformed.",
    )?;
    let lines = exact_minisign_lines(&text, 2, "update_key_invalid")?;
    if !lines[0].starts_with("untrusted comment: minisign public key") {
        return Err(error(
            "update_key_invalid",
            "The embedded updater public key has an invalid comment.",
        ));
    }
    let packet = canonical_base64_line(lines[1], "update_key_invalid")?;
    if packet.len() != 42 || !matches!(&packet[0..2], b"Ed" | b"ED") {
        return Err(error(
            "update_key_invalid",
            "The embedded updater public key packet is invalid.",
        ));
    }
    PublicKey::decode(&text).map_err(|_| {
        error(
            "update_key_invalid",
            "The embedded updater public key could not be decoded.",
        )
    })
}

fn validate_signature(
    public_key: &PublicKey,
    encoded: &str,
    expected_artifact: &str,
) -> CommandResult<Signature> {
    let text = decode_outer_base64(
        encoded,
        SIGNATURE_MAX_BYTES,
        "update_signature_invalid",
        "The update signature is malformed.",
    )?;
    let lines = exact_minisign_lines(&text, 4, "update_signature_invalid")?;
    if !lines[0].starts_with("untrusted comment:") || !lines[2].starts_with("trusted comment: ") {
        return Err(error(
            "update_signature_invalid",
            "The update signature comments are malformed.",
        ));
    }
    let packet = canonical_base64_line(lines[1], "update_signature_invalid")?;
    let global = canonical_base64_line(lines[3], "update_signature_invalid")?;
    if packet.len() != 74 || &packet[0..2] != b"ED" || global.len() != 64 {
        return Err(error(
            "update_signature_invalid",
            "Only canonical pre-hashed updater signatures are accepted.",
        ));
    }
    validate_trusted_comment(
        lines[2]
            .strip_prefix("trusted comment: ")
            .unwrap_or_default(),
        expected_artifact,
    )?;
    let signature = Signature::decode(&text).map_err(|_| {
        error(
            "update_signature_invalid",
            "The update signature could not be decoded.",
        )
    })?;
    public_key.verify_stream(&signature).map_err(|_| {
        error(
            "update_signature_invalid",
            "The update signature does not match the embedded public key or is not pre-hashed.",
        )
    })?;
    Ok(signature)
}

fn validate_trusted_comment(value: &str, expected_artifact: &str) -> CommandResult<()> {
    let fields: Vec<&str> = value.split('\t').collect();
    if fields.len() != 2 || !fields[0].starts_with("timestamp:") || !fields[1].starts_with("file:")
    {
        return Err(error(
            "update_signature_invalid",
            "The trusted comment must contain exactly timestamp and file fields.",
        ));
    }
    let timestamp = fields[0].strip_prefix("timestamp:").unwrap_or_default();
    let canonical_timestamp = timestamp
        .parse::<u64>()
        .ok()
        .is_some_and(|parsed| parsed.to_string() == timestamp);
    let filename = fields[1].strip_prefix("file:").unwrap_or_default();
    if !canonical_timestamp
        || filename != expected_artifact
        || filename.is_empty()
        || filename
            .chars()
            .any(|character| character.is_control() || matches!(character, '/' | '\\' | '%'))
    {
        return Err(error(
            "update_signature_filename",
            "The signed trusted comment does not bind the exact artifact filename.",
        ));
    }
    Ok(())
}

fn decode_outer_base64(
    value: &str,
    maximum_length: usize,
    code: &str,
    message: &str,
) -> CommandResult<String> {
    if value.is_empty() || value.len() > maximum_length || value.trim() != value {
        return Err(error(code, message));
    }
    let decoded = STANDARD.decode(value).map_err(|_| error(code, message))?;
    if STANDARD.encode(&decoded) != value {
        return Err(error(code, message));
    }
    String::from_utf8(decoded).map_err(|_| error(code, message))
}

fn canonical_base64_line(value: &str, code: &str) -> CommandResult<Vec<u8>> {
    if value.is_empty() || value.chars().any(char::is_whitespace) {
        return Err(error(code, "The Minisign packet is not canonical base64."));
    }
    let decoded = STANDARD
        .decode(value)
        .map_err(|_| error(code, "The Minisign packet is not canonical base64."))?;
    if STANDARD.encode(&decoded) != value {
        return Err(error(code, "The Minisign packet is not canonical base64."));
    }
    Ok(decoded)
}

fn exact_minisign_lines<'a>(
    text: &'a str,
    count: usize,
    code: &str,
) -> CommandResult<Vec<&'a str>> {
    if text.contains('\r') || text.contains('\0') {
        return Err(error(
            code,
            "The Minisign text contains forbidden controls.",
        ));
    }
    let normalized = text.strip_suffix('\n').unwrap_or(text);
    let lines: Vec<&str> = normalized.split('\n').collect();
    if lines.len() != count || lines.iter().any(|line| line.is_empty()) {
        return Err(error(
            code,
            "The Minisign text does not contain the expected exact lines.",
        ));
    }
    Ok(lines)
}

async fn pinned_client(url: &Url) -> CommandResult<Client> {
    let host = url.host_str().ok_or_else(|| {
        error(
            "update_dns_invalid",
            "The update URL does not have an approved host.",
        )
    })?;
    let port = url.port_or_known_default().unwrap_or(443);
    let resolved = tokio::time::timeout(DNS_TIMEOUT, tokio::net::lookup_host((host, port)))
        .await
        .map_err(|_| {
            error(
                "update_dns_unavailable",
                "The update host could not be resolved within the time limit.",
            )
        })?
        .map_err(|_| {
            error(
                "update_dns_unavailable",
                "The update host could not be resolved.",
            )
        })?;
    let mut addresses: Vec<SocketAddr> = resolved.collect();
    addresses.sort_unstable();
    addresses.dedup();
    if addresses.is_empty() || addresses.iter().any(|address| !is_public_ip(address.ip())) {
        return Err(error(
            "update_dns_unsafe",
            "The update host resolved outside the public network policy.",
        ));
    }
    Client::builder()
        .use_rustls_tls()
        .https_only(true)
        .no_proxy()
        .redirect(Policy::none())
        .connect_timeout(CONNECT_TIMEOUT)
        .pool_max_idle_per_host(0)
        .resolve_to_addrs(host, &addresses)
        .build()
        .map_err(|_| {
            error(
                "update_client_unavailable",
                "The bounded update network client could not be created.",
            )
        })
}

fn is_public_ip(address: IpAddr) -> bool {
    match address {
        IpAddr::V4(address) => is_public_ipv4(address),
        IpAddr::V6(address) => is_public_ipv6(address),
    }
}

fn is_public_ipv4(address: Ipv4Addr) -> bool {
    let [first, second, third, _] = address.octets();
    !(first == 0
        || first == 10
        || first == 127
        || first >= 224
        || (first == 100 && (64..=127).contains(&second))
        || (first == 169 && second == 254)
        || (first == 172 && (16..=31).contains(&second))
        || (first == 192 && second == 0)
        || (first == 192 && second == 168)
        || (first == 198 && matches!(second, 18 | 19))
        || (first == 198 && second == 51 && third == 100)
        || (first == 203 && second == 0 && third == 113))
}

fn is_public_ipv6(address: Ipv6Addr) -> bool {
    if let Some(mapped) = address.to_ipv4_mapped() {
        return is_public_ipv4(mapped);
    }
    let octets = address.octets();
    if octets[..12].iter().all(|byte| *byte == 0) {
        return is_public_ipv4(Ipv4Addr::new(
            octets[12], octets[13], octets[14], octets[15],
        ));
    }
    let segments = address.segments();
    let special_transition_prefix =
        (segments[0] == 0x0064 && segments[1] == 0xff9b && (segments[2] == 0 || segments[2] == 1))
            || (segments[0] == 0x0100 && segments[1..4] == [0, 0, 0])
            || segments[0] == 0x2002;
    let special_documentation_or_benchmark = segments[0] == 0x2001
        && (segments[1] == 0x0db8
            || segments[1] == 0x0002
            || (0x0010..=0x001f).contains(&segments[1]));
    if address.is_unspecified()
        || address.is_loopback()
        || address.is_multicast()
        || address.is_unique_local()
        || address.is_unicast_link_local()
        || special_transition_prefix
        || special_documentation_or_benchmark
    {
        return false;
    }
    true
}

struct StagedDownload {
    path: PathBuf,
    identity: Option<AppImageIdentity>,
    armed: AtomicBool,
}

impl StagedDownload {
    fn path(&self) -> &Path {
        &self.path
    }

    fn identity(&self) -> CommandResult<&AppImageIdentity> {
        self.identity.as_ref().ok_or_else(|| {
            error(
                "update_stage_failed",
                "The verified update staging identity is unavailable.",
            )
        })
    }

    fn disarm(&self) {
        self.armed.store(false, Ordering::Release);
    }
}

impl Drop for StagedDownload {
    fn drop(&mut self) {
        if self.armed.load(Ordering::Acquire) {
            let _ = fs::remove_file(&self.path);
        }
    }
}

async fn download_candidate(
    candidate: &Candidate,
    public_key: &PublicKey,
    signature: &Signature,
    appimage: &AppImageIdentity,
) -> CommandResult<StagedDownload> {
    let client = pinned_client(&candidate.url).await?;
    let response = client
        .get(candidate.url.clone())
        .header(ACCEPT_ENCODING, "identity")
        .timeout(DOWNLOAD_TIMEOUT)
        .send()
        .await
        .map_err(|_| {
            error(
                "update_download_unavailable",
                "The update artifact could not be downloaded.",
            )
        })?;
    if !response.status().is_success() {
        return Err(error(
            "update_download_status",
            "The update artifact returned an unsuccessful status.",
        ));
    }
    if response
        .content_length()
        .is_some_and(|length| length == 0 || length > ARTIFACT_MAX_BYTES)
    {
        return Err(error(
            "update_artifact_too_large",
            "The update artifact is empty or exceeds its size limit.",
        ));
    }

    let parent = appimage.canonical_path.parent().ok_or_else(|| {
        error(
            "update_install_invalid",
            "The running AppImage has no approved parent directory.",
        )
    })?;
    inspect_safe_parent(parent)?;
    let mut staged = StagedDownload {
        path: parent.join(format!(
            ".repopress-update-{}-{}.tmp",
            std::process::id(),
            Uuid::new_v4()
        )),
        identity: None,
        armed: AtomicBool::new(true),
    };
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(staged.path())
        .map_err(|_| {
            error(
                "update_stage_failed",
                "A private update staging file could not be created.",
            )
        })?;
    let metadata = file.metadata().map_err(|_| {
        error(
            "update_stage_failed",
            "The private update staging file could not be inspected.",
        )
    })?;
    if !metadata.is_file()
        || metadata.uid() != effective_uid()
        || metadata.nlink() != 1
        || metadata.mode() & 0o077 != 0
    {
        return Err(error(
            "update_stage_unsafe",
            "The update staging file does not meet safe ownership requirements.",
        ));
    }

    let mut verifier = public_key.verify_stream(signature).map_err(|_| {
        error(
            "update_signature_invalid",
            "The update signature is not usable for streaming verification.",
        )
    })?;
    let mut total = 0_u64;
    let mut stream = response.bytes_stream();
    while let Some(next) = stream.next().await {
        let chunk = next.map_err(|_| {
            error(
                "update_download_unavailable",
                "The update artifact download was interrupted.",
            )
        })?;
        total = total
            .checked_add(u64::try_from(chunk.len()).unwrap_or(u64::MAX))
            .ok_or_else(|| {
                error(
                    "update_artifact_too_large",
                    "The update artifact exceeds its size limit.",
                )
            })?;
        if total > ARTIFACT_MAX_BYTES {
            return Err(error(
                "update_artifact_too_large",
                "The update artifact exceeds its size limit.",
            ));
        }
        verifier.update(&chunk);
        file.write_all(&chunk).map_err(|_| {
            error(
                "update_stage_failed",
                "The update artifact could not be written to its private staging file.",
            )
        })?;
    }
    if total == 0 {
        return Err(error(
            "update_artifact_empty",
            "The downloaded update artifact is empty.",
        ));
    }
    verifier.finalize().map_err(|_| {
        error(
            "update_signature_invalid",
            "The downloaded AppImage failed signature verification.",
        )
    })?;
    file.set_permissions(fs::Permissions::from_mode(appimage.mode & 0o777))
        .map_err(|_| {
            error(
                "update_stage_failed",
                "The verified AppImage permissions could not be prepared.",
            )
        })?;
    file.sync_all().map_err(|_| {
        error(
            "update_stage_failed",
            "The verified AppImage could not be synchronized to disk.",
        )
    })?;
    drop(file);
    staged.identity = Some(file_identity_at(staged.path())?);
    Ok(staged)
}

pub fn inspect_appimage(path: &Path) -> CommandResult<AppImageIdentity> {
    if !path.is_absolute() {
        return Err(unsafe_appimage());
    }
    let canonical_path = fs::canonicalize(path).map_err(|_| unsafe_appimage())?;
    if canonical_path != path {
        return Err(unsafe_appimage());
    }
    let path_metadata = fs::symlink_metadata(path).map_err(|_| unsafe_appimage())?;
    if path_metadata.file_type().is_symlink() || !path_metadata.file_type().is_file() {
        return Err(unsafe_appimage());
    }
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)
        .map_err(|_| unsafe_appimage())?;
    let metadata = file.metadata().map_err(|_| unsafe_appimage())?;
    if !metadata.is_file()
        || metadata.uid() != effective_uid()
        || metadata.nlink() != 1
        || metadata.mode() & 0o111 == 0
        || metadata.mode() & 0o022 != 0
        || metadata.dev() != path_metadata.dev()
        || metadata.ino() != path_metadata.ino()
    {
        return Err(unsafe_appimage());
    }
    inspect_safe_parent(canonical_path.parent().ok_or_else(unsafe_appimage)?)?;
    Ok(identity_from_metadata(canonical_path, &metadata))
}

fn identity_from_metadata(path: PathBuf, metadata: &fs::Metadata) -> AppImageIdentity {
    AppImageIdentity {
        canonical_path: path,
        device: metadata.dev(),
        inode: metadata.ino(),
        size: metadata.size(),
        modified_seconds: metadata.mtime(),
        modified_nanoseconds: metadata.mtime_nsec(),
        changed_seconds: metadata.ctime(),
        changed_nanoseconds: metadata.ctime_nsec(),
        mode: metadata.mode(),
    }
}

fn inspect_safe_parent(parent: &Path) -> CommandResult<()> {
    let metadata = fs::symlink_metadata(parent).map_err(|_| unsafe_appimage())?;
    if !metadata.is_dir()
        || metadata.file_type().is_symlink()
        || metadata.uid() != effective_uid()
        || metadata.mode() & 0o022 != 0
    {
        return Err(unsafe_appimage());
    }
    Ok(())
}

fn exchange_replace(
    target: &Path,
    staged: &Path,
    expected_old: &AppImageIdentity,
    expected_new: &AppImageIdentity,
) -> CommandResult<()> {
    inspect_safe_parent(target.parent().ok_or_else(unsafe_appimage)?)?;
    let staged_metadata = fs::symlink_metadata(staged).map_err(|_| {
        error(
            "update_stage_failed",
            "The verified update staging file disappeared.",
        )
    })?;
    if !staged_metadata.is_file()
        || staged_metadata.file_type().is_symlink()
        || staged_metadata.uid() != effective_uid()
        || staged_metadata.nlink() != 1
    {
        return Err(error(
            "update_stage_unsafe",
            "The verified update staging file is no longer safe.",
        ));
    }
    let staged_identity = identity_from_metadata(staged.to_path_buf(), &staged_metadata);
    if !staged_identity.same_file_state(expected_new) {
        return Err(error(
            "update_stage_changed",
            "The verified update staging file changed before replacement.",
        ));
    }
    rename_exchange(target, staged)?;
    let old_matches =
        file_identity_at(staged).is_ok_and(|identity| identity.same_exchanged_file(expected_old));
    let new_matches =
        file_identity_at(target).is_ok_and(|identity| identity.same_exchanged_file(expected_new));
    if !old_matches || !new_matches {
        return match rename_exchange(target, staged) {
            Ok(()) => Err(error(
                "update_replace_rolled_back",
                "The AppImage changed during replacement, so the update was rolled back.",
            )),
            Err(_) => Err(error(
                "update_replace_uncertain",
                "The replacement could not be verified or rolled back. Do not restart until the AppImage is inspected.",
            )),
        };
    }
    fs::remove_file(staged).map_err(|_| {
        error(
            "update_cleanup_failed",
            "The previous AppImage could not be removed after replacement.",
        )
    })?;
    sync_parent(target)
}

fn file_identity_at(path: &Path) -> CommandResult<AppImageIdentity> {
    let metadata = fs::symlink_metadata(path).map_err(|_| unsafe_appimage())?;
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || metadata.uid() != effective_uid()
        || metadata.nlink() != 1
    {
        return Err(unsafe_appimage());
    }
    Ok(identity_from_metadata(path.to_path_buf(), &metadata))
}

fn rename_exchange(first: &Path, second: &Path) -> CommandResult<()> {
    let first = CString::new(first.as_os_str().as_bytes()).map_err(|_| {
        error(
            "update_install_invalid",
            "The AppImage path cannot be used for atomic replacement.",
        )
    })?;
    let second = CString::new(second.as_os_str().as_bytes()).map_err(|_| {
        error(
            "update_install_invalid",
            "The update staging path cannot be used for atomic replacement.",
        )
    })?;
    // SAFETY: both C strings are NUL-terminated and remain alive for the call.
    let result = unsafe {
        libc::renameat2(
            libc::AT_FDCWD,
            first.as_ptr(),
            libc::AT_FDCWD,
            second.as_ptr(),
            libc::RENAME_EXCHANGE,
        )
    };
    if result != 0 {
        return Err(error(
            "update_replace_failed",
            "Atomic AppImage replacement is unavailable on this filesystem.",
        ));
    }
    Ok(())
}

fn sync_parent(path: &Path) -> CommandResult<()> {
    let parent = path.parent().ok_or_else(unsafe_appimage)?;
    let directory = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_DIRECTORY)
        .open(parent)
        .map_err(|_| {
            error(
                "update_sync_failed",
                "The AppImage directory could not be opened for synchronization.",
            )
        })?;
    directory.sync_all().map_err(|_| {
        error(
            "update_sync_failed",
            "The AppImage directory could not be synchronized.",
        )
    })
}

fn effective_uid() -> u32 {
    // SAFETY: geteuid has no preconditions and no side effects.
    unsafe { libc::geteuid() }
}

fn unsafe_appimage() -> CommandError {
    error(
        "update_appimage_unsafe",
        "The AppImage or its parent directory does not meet safe ownership and path requirements.",
    )
}

fn error(code: &str, message: &str) -> CommandError {
    CommandError::new(code, message)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn version(value: &str) -> Version {
        Version::parse(value).expect("valid fixture version")
    }

    fn manifest(version: &str, url: &str) -> Vec<u8> {
        format!(
            r#"{{"version":"{version}","notes":"安全更新","pub_date":"2026-01-01T00:00:00Z","platforms":{{"linux-x86_64":{{"signature":"AAAA","url":"{url}"}}}}}}"#
        )
        .into_bytes()
    }

    #[test]
    fn public_url_policy_rejects_local_and_ambiguous_hosts() {
        for value in [
            "http://updates.example.com/latest.json",
            "https://127.0.0.1/latest.json",
            "https://localhost/latest.json",
            "https://updates.local/latest.json",
            "https://updates.example.com.:443/latest.json",
            "https://user@updates.example.com/latest.json",
            "https://updates.example.com:444/latest.json",
            "https://updates.example.com/latest.json#fragment",
        ] {
            assert!(parse_public_https_url(value, "invalid").is_err(), "{value}");
        }
        assert!(
            parse_public_https_url("https://updates.example.com/latest.json", "invalid").is_ok()
        );
    }

    #[test]
    fn ip_policy_rejects_non_public_ranges() {
        for value in [
            "127.0.0.1",
            "10.0.0.1",
            "100.64.0.1",
            "169.254.1.1",
            "172.16.0.1",
            "192.168.1.1",
            "198.51.100.2",
            "203.0.113.2",
            "::1",
            "fc00::1",
            "fe80::1",
            "2001:db8::1",
            "::127.0.0.1",
            "64:ff9b::7f00:1",
            "64:ff9b:1::7f00:1",
            "100::1",
            "2002:7f00:1::1",
        ] {
            assert!(
                !is_public_ip(value.parse().expect("valid fixture IP")),
                "{value}"
            );
        }
        assert!(is_public_ip("1.1.1.1".parse().expect("valid fixture IP")));
    }

    #[test]
    fn manifest_is_strict_and_version_bound() {
        let candidate = parse_manifest(
            &manifest(
                "1.2.3",
                "https://downloads.example.com/RepoPress_1.2.3_amd64.AppImage",
            ),
            &version("1.0.0"),
        )
        .expect("valid manifest")
        .expect("newer candidate");
        assert_eq!(candidate.version, version("1.2.3"));
        let extra = br#"{"version":"1.2.3","notes":"x","pub_date":"2026-01-01T00:00:00Z","extra":true,"platforms":{"linux-x86_64":{"signature":"AAAA","url":"https://downloads.example.com/RepoPress_1.2.3_amd64.AppImage"}}}"#;
        assert!(parse_manifest(extra, &version("1.0.0")).is_err());
        assert!(parse_manifest(
            &manifest(
                "1.2.3",
                "https://downloads.example.com/RepoPress_11.2.30_amd64.AppImage",
            ),
            &version("1.0.0"),
        )
        .is_err());
    }

    #[test]
    fn manifest_rejects_extra_target_controls_and_double_encoding() {
        let extra_target = br#"{"version":"1.2.3","notes":"x","pub_date":"2026-01-01T00:00:00Z","platforms":{"linux-x86_64":{"signature":"AAAA","url":"https://downloads.example.com/RepoPress_1.2.3_amd64.AppImage"},"darwin-x86_64":{"signature":"AAAA","url":"https://downloads.example.com/RepoPress_1.2.3_amd64.AppImage"}}}"#;
        assert!(parse_manifest(extra_target, &version("1.0.0")).is_err());
        assert!(parse_manifest(
            &manifest(
                "1.2.3",
                "https://downloads.example.com/RepoPress_1.2.3_%252F.AppImage",
            ),
            &version("1.0.0"),
        )
        .is_err());
        let bad_notes = br#"{"version":"1.2.3","notes":"line\nline","pub_date":"2026-01-01T00:00:00Z","platforms":{"linux-x86_64":{"signature":"AAAA","url":"https://downloads.example.com/RepoPress_1.2.3_amd64.AppImage"}}}"#;
        assert!(parse_manifest(bad_notes, &version("1.0.0")).is_err());
    }

    #[test]
    fn no_candidate_for_current_version() {
        assert!(parse_manifest(
            &manifest(
                "1.0.0",
                "https://downloads.example.com/RepoPress_1.0.0_amd64.AppImage",
            ),
            &version("1.0.0"),
        )
        .expect("valid current manifest")
        .is_none());
    }

    #[test]
    fn trusted_comment_is_exactly_filename_bound() {
        assert!(validate_trusted_comment(
            "timestamp:1\tfile:RepoPress_1.2.3_amd64.AppImage",
            "RepoPress_1.2.3_amd64.AppImage"
        )
        .is_ok());
        assert!(validate_trusted_comment(
            "timestamp:01\tfile:RepoPress_1.2.3_amd64.AppImage",
            "RepoPress_1.2.3_amd64.AppImage"
        )
        .is_err());
        assert!(validate_trusted_comment(
            "timestamp:1\tfile:other.AppImage",
            "RepoPress_1.2.3_amd64.AppImage"
        )
        .is_err());
    }

    #[test]
    fn tauri_outer_base64_prehashed_signature_verifies_as_a_stream() {
        let public_key_text = "untrusted comment: minisign public key E7620F1842B4E81F\n\
            RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3\n";
        let signature_text = "untrusted comment: signature from minisign secret key\n\
            RUQf6LRCGA9i559r3g7V1qNyJDApGip8MfqcadIgT9CuhV3EMhHoN1mGTkUidF/z7SrlQgXdy8ofjb7bNJJylDOocrCo8KLzZwo=\n\
            trusted comment: timestamp:1556193335\tfile:test\n\
            y/rUw2y8/hOUYjZU71eHp/Wo1KZ40fGy2VJEDl34XMJM+TX48Ss/17u3IvIfbVR1FkZZSNCisQbuQY+bHwhEBg==\n";
        let public_key = parse_public_key(&STANDARD.encode(public_key_text))
            .expect("Tauri outer-base64 public key");
        let signature = validate_signature(&public_key, &STANDARD.encode(signature_text), "test")
            .expect("Tauri outer-base64 ED signature");
        let mut verifier = public_key
            .verify_stream(&signature)
            .expect("pre-hashed stream verifier");
        verifier.update(b"test");
        verifier.finalize().expect("valid fixture signature");
    }

    #[test]
    fn install_permit_is_global_and_resets_on_drop() {
        let store = UpdateStore::default();
        let permit = store.begin_install().expect("first installer");
        assert!(store.begin_install().is_err());
        drop(permit);
        assert!(store.begin_install().is_ok());
    }

    #[test]
    fn atomic_exchange_replaces_only_expected_file() {
        let directory = tempfile::tempdir().expect("temporary directory");
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700))
            .expect("safe directory permissions");
        let target = directory.path().join("RepoPress_1.0.0_amd64.AppImage");
        let staged = directory.path().join(".verified-update.tmp");
        fs::write(&target, b"old image").expect("write old image");
        fs::write(&staged, b"new signed image").expect("write new image");
        fs::set_permissions(&target, fs::Permissions::from_mode(0o700))
            .expect("target permissions");
        fs::set_permissions(&staged, fs::Permissions::from_mode(0o700))
            .expect("staged permissions");
        let expected = inspect_appimage(&target).expect("safe fixture AppImage");
        let expected_new = file_identity_at(&staged).expect("verified update identity");
        exchange_replace(&target, &staged, &expected, &expected_new).expect("atomic replacement");
        assert!(!staged.exists());
        assert_eq!(
            fs::read(&target).expect("replacement content"),
            b"new signed image"
        );
    }

    #[test]
    fn unsafe_parent_and_symlink_are_rejected() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let target = directory.path().join("RepoPress.AppImage");
        fs::write(&target, b"image").expect("write fixture");
        fs::set_permissions(&target, fs::Permissions::from_mode(0o700))
            .expect("target permissions");
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o777))
            .expect("unsafe directory permissions");
        assert!(inspect_appimage(&target).is_err());
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700))
            .expect("safe directory permissions");
        let link = directory.path().join("linked.AppImage");
        std::os::unix::fs::symlink(&target, &link).expect("create fixture symlink");
        assert!(inspect_appimage(&link).is_err());
    }
}
