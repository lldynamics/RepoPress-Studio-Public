//! Independent saved-candidate inspection and manifest-only conflict counts. Never restores.
use super::{
    knowledge_library::knowledge_integrity_manifest as manifest, knowledge_package_check,
    workspace_backup, CommandError, CommandResult,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet, HashMap},
    fs::File,
    path::{Path, PathBuf},
    sync::Mutex,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;
#[path = "knowledge_candidate_check_disk.rs"]
mod disk;
#[path = "knowledge_restore_qualification.rs"]
mod qualification;
pub(crate) use qualification::normal_library_access;
pub use qualification::{
    KnowledgeMergeProjectionPlan, KnowledgeMergeProjectionReceipt, KnowledgeMergeProjectionStore,
    KnowledgeRestoreArchiveAction, KnowledgeRestoreArchivePlan, KnowledgeRestoreArchiveReceipt,
    KnowledgeRestoreArchiveStatus, KnowledgeRestoreArchiveStore, KnowledgeRestoreCleanupAction,
    KnowledgeRestoreCleanupPlan, KnowledgeRestoreCleanupReceipt, KnowledgeRestoreCleanupStatus,
    KnowledgeRestoreCleanupStore, KnowledgeRestoreDiagnosis, KnowledgeRestoreHistoryExportPlan,
    KnowledgeRestoreHistoryExportReceipt, KnowledgeRestoreHistoryExportStatus,
    KnowledgeRestoreHistoryExportStore, KnowledgeRestoreInstallPlan, KnowledgeRestoreInstallStore,
    KnowledgeRestoreQualificationPlan, KnowledgeRestoreQualificationRecheck,
    KnowledgeRestoreQualificationStore, KnowledgeRestoreReceipt, KnowledgeRestoreRecoveryAction,
    KnowledgeRestoreRecoveryPlan, KnowledgeRestoreStrategy,
};
const TTL: Duration = Duration::from_secs(300);
const TIME: Duration = Duration::from_secs(5);
const MAX_FILES: usize = 1026;
const MANIFEST: usize = 2 * 1024 * 1024;
const RESOURCE_BYTES: usize = 32 * 1024 * 1024;
const CANDIDATE_BYTES: usize = 34 * 1024 * 1024 + 4096;
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Limits {
    manifest_bytes: usize,
    resource_files: usize,
    resource_bytes: usize,
    candidate_files: usize,
    candidate_bytes: usize,
    marker_bytes: usize,
    json_nodes: usize,
    duration_ms: u64,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct CurrentSummary {
    state: &'static str,
    manifest_sha256: Option<String>,
    item_count: Option<u64>,
    revision_count: Option<u64>,
    folder_count: Option<u64>,
}
impl CurrentSummary {
    fn unavailable(state: &'static str) -> Self {
        Self {
            state,
            manifest_sha256: None,
            item_count: None,
            revision_count: None,
            folder_count: None,
        }
    }
}
#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct Conflicts {
    candidate_only_items: u64,
    current_only_items: u64,
    identical_items: u64,
    changed_items: u64,
    candidate_only_folders: u64,
    current_only_folders: u64,
    identical_folders: u64,
    changed_folders: u64,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeCandidateCheckReport {
    pub report_id: String,
    pub candidate_path: String,
    schema_version: u8,
    scope: &'static str,
    stage_plan_id: String,
    source_package_sha256: String,
    manifest_sha256: String,
    candidate_inventory_sha256: String,
    candidate_file_count: usize,
    candidate_byte_size: usize,
    item_count: u64,
    revision_count: u64,
    folder_count: u64,
    current_library: CurrentSummary,
    conflicts: Option<Conflicts>,
    limits: Limits,
    candidate_structure_verified: bool,
    candidate_contents_verified: bool,
    private_permissions_verified: bool,
    source_package_hash_verified: bool,
    candidate_authenticity_verified: bool,
    current_library_resources_verified: bool,
    comparison_scope: &'static str,
    consistent_snapshot: bool,
    filesystem_writes: bool,
    current_library_changed: bool,
    restore_ready: bool,
    checked_at_epoch_ms: u64,
    expires_at_epoch_ms: u64,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeCandidateRecheck {
    pub report: KnowledgeCandidateCheckReport,
    comparison: &'static str,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Marker {
    format: String,
    schema_version: u8,
    plan_id: String,
    source_package_sha256: String,
    manifest_sha256: String,
    candidate_only: bool,
    includes_credential_stores: bool,
    includes_completed_operations: bool,
    external_references_included: bool,
    current_library_changed: bool,
    restore_ready: bool,
}
fn invalid() -> CommandError {
    CommandError::new("knowledge_candidate_check_invalid",
    "Selected candidate layout, private permissions, content, limits, context or one-time report is unsafe, expired or changed. Inspect the selected candidate again. No filesystem write, cleanup or library restore was performed.")
}
fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn digest(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn bounded(started: Instant) -> CommandResult<()> {
    if started.elapsed() >= TIME {
        Err(invalid())
    } else {
        Ok(())
    }
}
fn now() -> CommandResult<u64> {
    let n = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| invalid())?
        .as_millis();
    if n == 0 || n > 8_639_999_999_700_000 {
        Err(invalid())
    } else {
        Ok(n as u64)
    }
}
struct Root {
    path: PathBuf,
    file: File,
    identity: (u64, u64, u32, u32),
}
impl Root {
    fn new(path: PathBuf) -> Option<Self> {
        let file = workspace_backup::root_handle(&path).ok()?;
        let identity = disk::identity(&disk::file_stamp(&file).ok()?);
        Some(Self {
            path,
            file,
            identity,
        })
    }
    fn verify(&self) -> CommandResult<()> {
        let current = workspace_backup::root_handle(&self.path).map_err(|_| invalid())?;
        if disk::identity(&disk::file_stamp(&current)?) != self.identity
            || disk::identity(&disk::file_stamp(&self.file)?) != self.identity
        {
            Err(invalid())
        } else {
            Ok(())
        }
    }
}
struct Current {
    summary: CurrentSummary,
    raw: Option<Value>,
    dir: Option<disk::Dir>,
    witness: Option<disk::Witness>,
    dir_observation: disk::Observation,
    file_observation: Option<disk::Observation>,
    content_digest: Option<String>,
}
impl Current {
    fn capture(root: &Root, started: Instant) -> Self {
        let dir_observation = disk::observe(&root.file, "knowledge-v1", true);
        let mut c = Self {
            summary: CurrentSummary::unavailable("unreadable"),
            raw: None,
            dir: None,
            witness: None,
            dir_observation,
            file_observation: None,
            content_digest: None,
        };
        let dir = match disk::directory(&root.file, "knowledge-v1") {
            Ok(d) => d,
            Err(state) => {
                c.summary = CurrentSummary::unavailable(state);
                return c;
            }
        };
        c.file_observation = Some(disk::observe(&dir.file, "manifest.json", false));
        let read = disk::read(&dir.file, "manifest.json", MANIFEST, started);
        c.dir = Some(dir);
        let read = match read {
            Ok(read) => read,
            Err(state) => {
                c.summary = CurrentSummary::unavailable(state);
                return c;
            }
        };
        c.content_digest = Some(hash(&read.bytes));
        c.witness = Some(read.witness);
        let parsed = (|| {
            let raw =
                knowledge_package_check::parse_json(&read.bytes, started).map_err(|_| invalid())?;
            let refs = manifest::project(&read.bytes).map_err(|_| invalid())?;
            manifest::validate_completed_operations(&read.bytes).map_err(|_| invalid())?;
            Ok::<_, CommandError>((raw, refs))
        })();
        match parsed {
            Ok((raw, refs)) => {
                c.summary = CurrentSummary {
                    state: "checked",
                    manifest_sha256: c.content_digest.clone(),
                    item_count: Some(refs.items),
                    revision_count: Some(refs.revisions),
                    folder_count: raw
                        .get("folders")
                        .and_then(Value::as_array)
                        .map(|v| v.len() as u64),
                };
                c.raw = Some(raw);
            }
            Err(_) => c.summary = CurrentSummary::unavailable("invalid"),
        }
        c
    }
    fn verify(&mut self, root: &Root) {
        let changed = disk::observe(&root.file, "knowledge-v1", true) != self.dir_observation
            || self.dir.as_ref().is_some_and(|dir| {
                !disk::verify_dir(&root.file, "knowledge-v1", dir)
                    || self.file_observation.as_ref()
                        != Some(&disk::observe(&dir.file, "manifest.json", false))
                    || self
                        .witness
                        .as_ref()
                        .is_some_and(|w| !w.verify(&dir.file, "manifest.json"))
            });
        if changed {
            self.summary = CurrentSummary::unavailable("changed");
            self.raw = None;
        }
    }
    fn fingerprint(&self) -> CommandResult<String> {
        Ok(hash(
            &serde_json::to_vec(&(
                &self.summary.state,
                &self.dir_observation,
                &self.file_observation,
                &self.content_digest,
            ))
            .map_err(|_| invalid())?,
        ))
    }
}
fn keyed<'a>(raw: &'a Value, kind: &str) -> CommandResult<BTreeMap<String, &'a Value>> {
    let values = raw
        .get(kind)
        .and_then(Value::as_array)
        .ok_or_else(invalid)?;
    values
        .iter()
        .map(|value| {
            let id = if kind == "items" {
                value.get("summary").and_then(|s| s.get("itemId"))
            } else {
                value.get("folderId")
            };
            Ok((
                id.and_then(Value::as_str).ok_or_else(invalid)?.into(),
                value,
            ))
        })
        .collect()
}
fn differences(
    candidate: &Value,
    current: &Value,
    kind: &str,
) -> CommandResult<(u64, u64, u64, u64)> {
    let a = keyed(candidate, kind)?;
    let b = keyed(current, kind)?;
    let mut only = 0;
    let mut identical = 0;
    let mut changed = 0;
    for (id, value) in &a {
        match b.get(id) {
            None => only += 1,
            Some(other) if value == other => identical += 1,
            Some(_) => changed += 1,
        }
    }
    let current_only = b.keys().filter(|id| !a.contains_key(*id)).count() as u64;
    Ok((only, current_only, identical, changed))
}
fn compare(candidate: &Value, current: &Value) -> CommandResult<Conflicts> {
    let (candidate_only_items, current_only_items, identical_items, changed_items) =
        differences(candidate, current, "items")?;
    let (candidate_only_folders, current_only_folders, identical_folders, changed_folders) =
        differences(candidate, current, "folders")?;
    Ok(Conflicts {
        candidate_only_items,
        current_only_items,
        identical_items,
        changed_items,
        candidate_only_folders,
        current_only_folders,
        identical_folders,
        changed_folders,
    })
}
type CapturedProjection = (
    KnowledgeCandidateCheckReport,
    Stored,
    qualification::ResourceSummary,
    Option<qualification::projection::ProjectionSummary>,
    Option<InstallMaterial>,
);
struct InstallMaterial {
    manifest: Vec<u8>,
    resources: BTreeMap<String, Vec<u8>>,
}
struct Stored {
    created: Instant,
    expires: u64,
    path: PathBuf,
    fingerprint: String,
    comparable: bool,
}
#[derive(Default)]
pub struct KnowledgeCandidateCheckStore {
    root: Option<Root>,
    reports: Mutex<HashMap<String, Stored>>,
}
impl KnowledgeCandidateCheckStore {
    pub fn new(path: PathBuf) -> Self {
        Self {
            root: Root::new(path),
            reports: Mutex::new(HashMap::new()),
        }
    }
    pub fn inspect(&self, path: &Path) -> CommandResult<KnowledgeCandidateCheckReport> {
        self.inspect_checked(path, |_| {})
    }
    fn inspect_checked(
        &self,
        path: &Path,
        hook: impl FnMut(u8),
    ) -> CommandResult<KnowledgeCandidateCheckReport> {
        let mut reports = self.reports.lock().map_err(|_| invalid())?;
        let current = now()?;
        reports.retain(|_, r| r.created.elapsed() < TTL && r.expires > current);
        if reports.len() >= 2 {
            return Err(invalid());
        }
        let (report, stored) = self.capture(path, hook)?;
        reports.insert(report.report_id.clone(), stored);
        Ok(report)
    }
    pub fn discard(&self, id: &str) -> CommandResult<()> {
        self.reports.lock().map_err(|_| invalid())?.remove(id);
        Ok(())
    }
    pub fn recheck(&self, id: &str) -> CommandResult<KnowledgeCandidateRecheck> {
        let mut reports = self.reports.lock().map_err(|_| invalid())?;
        let old = reports.remove(id).ok_or_else(invalid)?;
        if old.created.elapsed() >= TTL || now()? >= old.expires {
            return Err(invalid());
        }
        let (report, stored) = self.capture(&old.path, |_| {})?;
        if old.created.elapsed() >= TTL || now()? >= old.expires {
            return Err(invalid());
        }
        let comparison = if !old.comparable || !stored.comparable {
            "inconclusive"
        } else if old.fingerprint == stored.fingerprint {
            "unchanged"
        } else {
            "changed"
        };
        reports.insert(report.report_id.clone(), stored);
        Ok(KnowledgeCandidateRecheck { report, comparison })
    }
    fn capture(
        &self,
        path: &Path,
        hook: impl FnMut(u8),
    ) -> CommandResult<(KnowledgeCandidateCheckReport, Stored)> {
        let (report, stored, _) = self.capture_qualified(path, hook, false)?;
        Ok((report, stored))
    }
    fn capture_qualified(
        &self,
        path: &Path,
        hook: impl FnMut(u8),
        include_resources: bool,
    ) -> CommandResult<(
        KnowledgeCandidateCheckReport,
        Stored,
        qualification::ResourceSummary,
    )> {
        let (report, stored, resources, _, _) =
            self.capture_extended(path, hook, include_resources, None, false)?;
        Ok((report, stored, resources))
    }
    fn capture_extended(
        &self,
        path: &Path,
        mut hook: impl FnMut(u8),
        include_resources: bool,
        projection_strategy: Option<KnowledgeRestoreStrategy>,
        include_material: bool,
    ) -> CommandResult<CapturedProjection> {
        let started = Instant::now();
        let checked = now()?;
        let root = self.root.as_ref().ok_or_else(invalid)?;
        root.verify()?;
        let mut tree = disk::Tree::open(path, &root.path)?;
        hook(0);
        let marker_bytes = tree.read("candidate.json", 4096, started)?;
        let marker: Marker =
            serde_json::from_value(knowledge_package_check::parse_json(&marker_bytes, started)?)
                .map_err(|_| invalid())?;
        if marker.format != "repopress-knowledge-isolated-candidate"
            || marker.schema_version != 1
            || !disk::valid_id(&marker.plan_id)
            || marker.plan_id != tree.stage_id
            || !digest(&marker.source_package_sha256)
            || !digest(&marker.manifest_sha256)
            || !marker.candidate_only
            || marker.includes_credential_stores
            || marker.includes_completed_operations
            || marker.external_references_included
            || marker.current_library_changed
            || marker.restore_ready
        {
            return Err(invalid());
        }
        let bytes = tree.read("knowledge-v1/manifest.json", MANIFEST, started)?;
        let raw = knowledge_package_check::parse_json(&bytes, started)?;
        if serde_json::to_vec(&raw).map_err(|_| invalid())? != bytes
            || hash(&bytes) != marker.manifest_sha256
            || raw
                .get("completedOperations")
                .and_then(Value::as_array)
                .is_none_or(|v| !v.is_empty())
        {
            return Err(invalid());
        }
        let refs = manifest::project(&bytes).map_err(|_| invalid())?;
        if refs.files.len() > 1024
            || refs.missing_archives > 0
            || refs.truncated_archives > 0
            || refs.unknown_archives > 0
        {
            return Err(invalid());
        }
        hook(1);
        let expected: BTreeSet<_> = refs
            .files
            .iter()
            .map(|r| {
                format!(
                    "knowledge-v1/{}/{}",
                    if r.kind == "body" {
                        "blobs"
                    } else {
                        "archives"
                    },
                    r.digest
                )
            })
            .collect();
        tree.check_resources(&expected)?;
        let mut inventory = BTreeMap::new();
        inventory.insert(
            "candidate.json".to_string(),
            (marker_bytes.len(), hash(&marker_bytes)),
        );
        inventory.insert(
            "knowledge-v1/manifest.json".to_string(),
            (bytes.len(), hash(&bytes)),
        );
        let mut material_resources = BTreeMap::new();
        let mut resource_bytes = 0usize;
        for reference in &refs.files {
            bounded(started)?;
            if reference.byte_size > RESOURCE_BYTES.saturating_sub(resource_bytes) as u64 {
                return Err(invalid());
            }
            let relative = format!(
                "knowledge-v1/{}/{}",
                if reference.kind == "body" {
                    "blobs"
                } else {
                    "archives"
                },
                reference.digest
            );
            let content = tree.read(&relative, reference.byte_size as usize, started)?;
            if !manifest::content_matches(reference, &content) {
                return Err(invalid());
            }
            resource_bytes += content.len();
            inventory.insert(relative.clone(), (content.len(), hash(&content)));
            if include_material {
                material_resources.insert(
                    relative
                        .strip_prefix("knowledge-v1/")
                        .ok_or_else(invalid)?
                        .into(),
                    content,
                );
            }
        }
        let candidate_byte_size = inventory.values().map(|(n, _)| n).sum::<usize>();
        if candidate_byte_size > CANDIDATE_BYTES || inventory.len() > MAX_FILES {
            return Err(invalid());
        }
        let entries: Vec<_> = inventory
            .iter()
            .map(
                |(path, (size, sha))| serde_json::json!({"path":path,"byteSize":size,"sha256":sha}),
            )
            .collect();
        let candidate_inventory_sha256 =
            hash(&serde_json::to_vec(&entries).map_err(|_| invalid())?);
        hook(2);
        let mut current = Current::capture(root, started);
        let mut resources = qualification::ResourceAudit::capture(
            &current,
            started,
            include_resources,
            include_material,
        );
        let projected_material = projection_strategy
            .map(|strategy| {
                if include_material {
                    qualification::projection::project_material(
                        &raw,
                        current.raw.as_ref(),
                        &resources.summary,
                        strategy,
                        started,
                    )
                } else {
                    qualification::projection::project(
                        &raw,
                        current.raw.as_ref(),
                        &resources.summary,
                        strategy,
                        started,
                    )
                    .map(|summary| (summary, None))
                }
            })
            .transpose()?;
        let (mut projected, mut material_manifest) = match projected_material {
            Some((summary, manifest)) => (Some(summary), manifest),
            None => (None, None),
        };
        hook(3);
        current.verify(root);
        resources.verify(&current);
        tree.verify()?;
        root.verify()?;
        bounded(started)?;
        hook(4);
        current.verify(root);
        resources.verify(&current);
        tree.verify()?;
        root.verify()?;
        bounded(started)?;
        let conflicts = current.raw.as_ref().map(|c| compare(&raw, c)).transpose()?;

        let mut report = KnowledgeCandidateCheckReport {
            report_id: Uuid::new_v4().to_string(),
            candidate_path: tree.path.to_str().ok_or_else(invalid)?.into(),
            schema_version: 1,
            scope: "selectedKnowledgeCandidate",
            stage_plan_id: marker.plan_id,
            source_package_sha256: marker.source_package_sha256,
            manifest_sha256: marker.manifest_sha256,
            candidate_inventory_sha256,
            candidate_file_count: inventory.len(),
            candidate_byte_size,
            item_count: refs.items,
            revision_count: refs.revisions,
            folder_count: raw
                .get("folders")
                .and_then(Value::as_array)
                .ok_or_else(invalid)?
                .len() as u64,
            current_library: current.summary.clone(),
            conflicts,
            limits: Limits {
                manifest_bytes: MANIFEST,
                resource_files: 1024,
                resource_bytes: RESOURCE_BYTES,
                candidate_files: MAX_FILES,
                candidate_bytes: CANDIDATE_BYTES,
                marker_bytes: 4096,
                json_nodes: 131072,
                duration_ms: 5000,
            },
            candidate_structure_verified: true,
            candidate_contents_verified: true,
            private_permissions_verified: true,
            source_package_hash_verified: false,
            candidate_authenticity_verified: false,
            current_library_resources_verified: false,
            comparison_scope: "manifestIdentityAndMetadataOnly",
            consistent_snapshot: false,
            filesystem_writes: false,
            current_library_changed: false,
            restore_ready: false,
            checked_at_epoch_ms: checked,
            expires_at_epoch_ms: checked + 300000,
        };
        current.verify(root);
        resources.verify(&current);
        tree.verify()?;
        root.verify()?;
        bounded(started)?;
        if current.summary.state != "checked" {
            report.current_library = current.summary.clone();
            report.conflicts = None;
        }
        if projected.is_some()
            && (current.summary.state != "checked" || !resources.summary.is_checked())
        {
            material_manifest = None;
            projected = Some(qualification::projection::ProjectionSummary::blocked(
                "qualificationBlocked",
            ));
        }
        let comparable = current.summary.state == "checked";
        let fingerprint = if include_resources {
            hash(
                &serde_json::to_vec(&(
                    tree.fingerprint()?,
                    &report.candidate_inventory_sha256,
                    current.fingerprint()?,
                    &root.identity,
                    resources.fingerprint()?,
                ))
                .map_err(|_| invalid())?,
            )
        } else {
            hash(
                &serde_json::to_vec(&(
                    tree.fingerprint()?,
                    &report.candidate_inventory_sha256,
                    current.fingerprint()?,
                    &root.identity,
                ))
                .map_err(|_| invalid())?,
            )
        };
        let fingerprint = if let Some(p) = &projected {
            hash(
                &serde_json::to_vec(&(&fingerprint, &projection_strategy, p))
                    .map_err(|_| invalid())?,
            )
        } else {
            fingerprint
        };
        bounded(started)?;
        Ok((
            report,
            Stored {
                created: started,
                expires: checked + 300000,
                path: path.into(),
                fingerprint,
                comparable,
            },
            resources.summary.clone(),
            projected,
            material_manifest.map(|manifest| {
                material_resources.extend(resources.material);
                InstallMaterial {
                    manifest,
                    resources: material_resources,
                }
            }),
        ))
    }
}
#[cfg(test)]
#[path = "knowledge_candidate_check_tests.rs"]
mod tests;
