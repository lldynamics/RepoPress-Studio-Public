//! Confirmation-bound JSON saved-file package; no migration, GC, restore or atomic snapshot.
use super::{
    rollback_archive::Destination, workspace_config_backup::reject_git_ancestors, CommandError,
    CommandResult,
};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::Mutex,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;
#[path = "knowledge_backup_capture.rs"]
mod capture;
const TTL: Duration = Duration::from_secs(300);
const TIME: Duration = Duration::from_secs(5);
const MAX_PLANS: usize = 2;
const MANIFEST_BYTES: u64 = 2 * 1024 * 1024;
const RESOURCE_BYTES: u64 = 32 * 1024 * 1024;
const RESOURCE_FILES: usize = 1024;
pub(super) const PACKAGE_BYTES: usize = 48 * 1024 * 1024;
const FORMAT: &str = "repopress-knowledge-saved-files";
const SCOPE: &str = "applicationSavedKnowledge";
const EXCLUSIONS: [&str; 9] = [
    "credentialStores",
    "otherWorkspaceSources",
    "repositoryFiles",
    "externalReferences",
    "unreferencedFiles",
    "completedOperations",
    "runtimeState",
    "sourcePdfFiles",
    "attachmentFiles",
];
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeBackupLimits {
    manifest_bytes: u64,
    resource_files: usize,
    resource_bytes: u64,
    package_bytes: usize,
    duration_ms: u64,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeBackupPlan {
    pub plan_id: String,
    scope: &'static str,
    format: &'static str,
    schema_version: u8,
    source_manifest_schema_version: u8,
    pub destination_path: String,
    item_count: u64,
    revision_count: u64,
    body_file_count: usize,
    archive_file_count: usize,
    resource_byte_size: u64,
    pub byte_size: usize,
    pub sha256: String,
    exclusions: Vec<&'static str>,
    limits: KnowledgeBackupLimits,
    structure_verified: bool,
    content_verified: bool,
    all_saved_references_included: bool,
    consistent_snapshot: bool,
    includes_credential_stores: bool,
    includes_completed_operations: bool,
    external_references_included: bool,
    created_at_epoch_ms: u64,
    expires_at_epoch_ms: u64,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeBackupResult {
    pub plan_id: String,
    pub destination_path: String,
    pub byte_size: usize,
    pub sha256: String,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PackageFile {
    path: String,
    kind: &'static str,
    byte_size: u64,
    sha256: String,
    encoding: &'static str,
    data: String,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Package {
    format: &'static str,
    schema_version: u8,
    source_manifest_schema_version: u8,
    scope: &'static str,
    captured_at_epoch_ms: u64,
    manifest: serde_json::Value,
    manifest_sha256: String,
    source_manifest_sha256: String,
    files: Vec<PackageFile>,
    exclusions: Vec<&'static str>,
    all_saved_references_included: bool,
    consistent_snapshot: bool,
    includes_credential_stores: bool,
    includes_completed_operations: bool,
    external_references_included: bool,
}
struct Binding {
    preview: KnowledgeBackupPlan,
    witness: capture::Witness,
    destination: Destination,
    bytes: Vec<u8>,
    created: Instant,
}
#[derive(Default)]
pub struct KnowledgeBackupStore {
    root: Option<capture::Root>,
    plans: Mutex<HashMap<String, Binding>>,
}
fn invalid() -> CommandError {
    CommandError::new("knowledge_backup_invalid", "Saved knowledge, layout, references, limits, preview, consent or destination is unavailable, unsafe, expired or changed. Review a new complete saved-file package and filename; no existing file will be overwritten.")
}
fn failed() -> CommandError {
    CommandError::new("knowledge_backup_unconfirmed", "Saved-file package export could not be confirmed. A private file may already exist at the selected destination; inspect it before choosing a new filename. Source knowledge was not restored or cleaned up.")
}
fn now() -> CommandResult<u64> {
    let n = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| invalid())?
        .as_millis();
    if n == 0 || n > 8_639_999_999_700_000 {
        return Err(invalid());
    }
    Ok(n as u64)
}
fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
impl KnowledgeBackupStore {
    pub fn new(path: PathBuf) -> Self {
        Self {
            root: capture::Root::new(path),
            plans: Mutex::new(HashMap::new()),
        }
    }
    fn root(&self) -> CommandResult<&capture::Root> {
        let root = self.root.as_ref().ok_or_else(invalid)?;
        root.verify()?;
        Ok(root)
    }
    pub fn plan(&self, path: &Path) -> CommandResult<KnowledgeBackupPlan> {
        self.plan_checked(path, |_| {})
    }
    fn plan_checked(
        &self,
        path: &Path,
        hook: impl FnMut(u8),
    ) -> CommandResult<KnowledgeBackupPlan> {
        let mut plans = self.plans.lock().map_err(|_| invalid())?;
        plans.retain(|_, b| b.created.elapsed() < TTL);
        if plans.len() >= MAX_PLANS {
            return Err(invalid());
        }
        let root = self.root()?;
        reject_git_ancestors(path.parent().ok_or_else(invalid)?).map_err(|_| invalid())?;
        let destination =
            Destination::knowledge_package(path, &root.path).map_err(|_| invalid())?;
        let captured = capture::capture(root, hook)?;
        let created_at_epoch_ms = now()?;
        let body_file_count = captured
            .files
            .iter()
            .filter(|f| f.reference.kind == "body")
            .count();
        let archive_file_count = captured.files.len() - body_file_count;
        let files = captured
            .files
            .into_iter()
            .map(|f| PackageFile {
                path: format!(
                    "{}/{}",
                    if f.reference.kind == "body" {
                        "blobs"
                    } else {
                        "archives"
                    },
                    f.reference.digest
                ),
                kind: f.reference.kind,
                byte_size: f.reference.byte_size,
                sha256: f.reference.digest,
                encoding: "base64",
                data: STANDARD.encode(&f.bytes),
            })
            .collect();
        let manifest_sha256 = hash(&serde_json::to_vec(&captured.manifest).map_err(|_| invalid())?);
        let bytes = serde_json::to_vec(&Package {
            format: FORMAT,
            schema_version: 1,
            source_manifest_schema_version: 4,
            scope: SCOPE,
            captured_at_epoch_ms: created_at_epoch_ms,
            manifest: captured.manifest,
            manifest_sha256,
            source_manifest_sha256: captured.witness.manifest_sha256.clone(),
            files,
            exclusions: EXCLUSIONS.to_vec(),
            all_saved_references_included: true,
            consistent_snapshot: false,
            includes_credential_stores: false,
            includes_completed_operations: false,
            external_references_included: false,
        })
        .map_err(|_| invalid())?;
        if bytes.len() > PACKAGE_BYTES {
            return Err(invalid());
        }
        let preview = KnowledgeBackupPlan {
            plan_id: Uuid::new_v4().to_string(),
            scope: SCOPE,
            format: FORMAT,
            schema_version: 1,
            source_manifest_schema_version: 4,
            destination_path: path.to_str().ok_or_else(invalid)?.into(),
            item_count: captured.item_count,
            revision_count: captured.revision_count,
            body_file_count,
            archive_file_count,
            resource_byte_size: captured.resource_bytes,
            byte_size: bytes.len(),
            sha256: hash(&bytes),
            exclusions: EXCLUSIONS.to_vec(),
            limits: KnowledgeBackupLimits {
                manifest_bytes: MANIFEST_BYTES,
                resource_files: RESOURCE_FILES,
                resource_bytes: RESOURCE_BYTES,
                package_bytes: PACKAGE_BYTES,
                duration_ms: 5000,
            },
            structure_verified: true,
            content_verified: true,
            all_saved_references_included: true,
            consistent_snapshot: false,
            includes_credential_stores: false,
            includes_completed_operations: false,
            external_references_included: false,
            created_at_epoch_ms,
            expires_at_epoch_ms: created_at_epoch_ms + 300_000,
        };
        plans.insert(
            preview.plan_id.clone(),
            Binding {
                preview: preview.clone(),
                witness: captured.witness,
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
    ) -> CommandResult<KnowledgeBackupResult> {
        self.execute_checked(id, confirm_sensitive_plaintext, |_| {})
    }
    fn execute_checked(
        &self,
        id: &str,
        consent: bool,
        mut hook: impl FnMut(u8),
    ) -> CommandResult<KnowledgeBackupResult> {
        // Consume before every check, including false consent, expiry and drift.
        let b = self
            .plans
            .lock()
            .map_err(|_| invalid())?
            .remove(id)
            .ok_or_else(invalid)?;
        let check = || {
            if !consent || b.created.elapsed() >= TTL || now()? >= b.preview.expires_at_epoch_ms {
                return Err(invalid());
            }
            capture::revalidate(self.root()?, &b.witness)?;
            reject_git_ancestors(
                Path::new(&b.preview.destination_path)
                    .parent()
                    .ok_or_else(invalid)?,
            )
            .map_err(|_| invalid())
        };
        check()?;
        hook(0);
        b.destination
            .write(&b.bytes, &mut || {
                hook(1);
                check()
            })
            .map_err(|_| failed())?;
        hook(2);
        check().map_err(|_| failed())?;
        Ok(KnowledgeBackupResult {
            plan_id: b.preview.plan_id,
            destination_path: b.preview.destination_path,
            byte_size: b.preview.byte_size,
            sha256: b.preview.sha256,
        })
    }
}
#[cfg(test)]
#[path = "knowledge_backup_tests.rs"]
mod tests;

/// Encode already pinned historical saved files using the same P46/P47 contract.
/// The caller must bind and revalidate the original filesystem evidence separately.
pub(crate) struct SavedSnapshotPackage {
    pub bytes: Vec<u8>,
    pub manifest_sha256: String,
    pub source_manifest_sha256: String,
    pub item_count: u64,
    pub revision_count: u64,
    pub body_file_count: usize,
    pub archive_file_count: usize,
    pub resource_byte_size: u64,
    pub exclusions: Vec<&'static str>,
}
pub(crate) fn saved_snapshot_package(
    source_manifest: &[u8],
    resources: &std::collections::BTreeMap<String, Vec<u8>>,
    captured_at: u64,
) -> CommandResult<SavedSnapshotPackage> {
    use super::{
        knowledge_library::knowledge_integrity_manifest as manifest, knowledge_package_check,
    };
    let started = Instant::now();
    if source_manifest.len() > MANIFEST_BYTES as usize || resources.len() > RESOURCE_FILES {
        return Err(invalid());
    }
    let mut value = knowledge_package_check::parse_json(source_manifest, started)?;
    let projected = manifest::project(source_manifest)?;
    manifest::validate_completed_operations(source_manifest)?;
    if projected.missing_archives != 0
        || projected.truncated_archives != 0
        || projected.unknown_archives != 0
    {
        return Err(invalid());
    }
    let expected = projected
        .files
        .iter()
        .map(|r| {
            format!(
                "{}/{}",
                if r.kind == "body" {
                    "blobs"
                } else {
                    "archives"
                },
                r.digest
            )
        })
        .collect::<std::collections::BTreeSet<_>>();
    if expected != resources.keys().cloned().collect() {
        return Err(invalid());
    }
    let resource_byte_size = resources
        .values()
        .try_fold(0u64, |n, b| n.checked_add(b.len() as u64))
        .ok_or_else(invalid)?;
    if resource_byte_size > RESOURCE_BYTES {
        return Err(invalid());
    }
    value["completedOperations"] = serde_json::Value::Array(Vec::new());
    let manifest_sha256 = hash(&serde_json::to_vec(&value).map_err(|_| invalid())?);
    let source_manifest_sha256 = hash(source_manifest);
    let body_file_count = projected.files.iter().filter(|r| r.kind == "body").count();
    let archive_file_count = projected.files.len() - body_file_count;
    let mut files = Vec::new();
    for r in projected.files {
        let path = format!(
            "{}/{}",
            if r.kind == "body" {
                "blobs"
            } else {
                "archives"
            },
            r.digest
        );
        let bytes = resources.get(&path).ok_or_else(invalid)?;
        if !manifest::content_matches(&r, bytes) {
            return Err(invalid());
        }
        files.push(PackageFile {
            path,
            kind: r.kind,
            byte_size: r.byte_size,
            sha256: r.digest,
            encoding: "base64",
            data: STANDARD.encode(bytes),
        });
    }
    let bytes = serde_json::to_vec(&Package {
        format: FORMAT,
        schema_version: 1,
        source_manifest_schema_version: 4,
        scope: SCOPE,
        captured_at_epoch_ms: captured_at,
        manifest: value,
        manifest_sha256: manifest_sha256.clone(),
        source_manifest_sha256: source_manifest_sha256.clone(),
        files,
        exclusions: EXCLUSIONS.to_vec(),
        all_saved_references_included: true,
        consistent_snapshot: false,
        includes_credential_stores: false,
        includes_completed_operations: false,
        external_references_included: false,
    })
    .map_err(|_| invalid())?;
    if bytes.len() > PACKAGE_BYTES {
        return Err(invalid());
    }
    // Reject any serialization/format mismatch before making an export capability.
    knowledge_package_check::validate(&bytes, Instant::now())?;
    Ok(SavedSnapshotPackage {
        bytes,
        manifest_sha256,
        source_manifest_sha256,
        item_count: projected.items,
        revision_count: projected.revisions,
        body_file_count,
        archive_file_count,
        resource_byte_size,
        exclusions: EXCLUSIONS.to_vec(),
    })
}
