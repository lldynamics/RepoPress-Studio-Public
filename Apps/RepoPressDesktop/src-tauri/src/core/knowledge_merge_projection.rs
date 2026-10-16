//! Pure merged-manifest projection and explicit one-time memory validation. Never installs.
use super::*;
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProjectionSummary {
    state: &'static str,
    reason: &'static str,
    manifest_sha256: Option<String>,
    manifest_byte_size: Option<usize>,
    item_count: Option<u64>,
    revision_count: Option<u64>,
    folder_count: Option<u64>,
    file_count: Option<usize>,
    resource_byte_size: Option<u64>,
    body_byte_size: Option<u64>,
    archive_byte_size: Option<u64>,
    imported_items: Option<u64>,
    imported_folders: Option<u64>,
    reset_permission_items: Option<u64>,
    completed_operations_excluded: bool,
}
impl ProjectionSummary {
    pub(crate) fn blocked(reason: &'static str) -> Self {
        Self {
            state: "blocked",
            reason,
            manifest_sha256: None,
            manifest_byte_size: None,
            item_count: None,
            revision_count: None,
            folder_count: None,
            file_count: None,
            resource_byte_size: None,
            body_byte_size: None,
            archive_byte_size: None,
            imported_items: None,
            imported_folders: None,
            reset_permission_items: None,
            completed_operations_excluded: true,
        }
    }
}
pub(crate) fn project_material(
    candidate: &Value,
    current: Option<&Value>,
    resources: &ResourceSummary,
    strategy: KnowledgeRestoreStrategy,
    started: Instant,
) -> CommandResult<(ProjectionSummary, Option<Vec<u8>>)> {
    bounded(started)?;
    let Some(current) = current.filter(|_| resources.is_checked()) else {
        return Ok((ProjectionSummary::blocked("qualificationBlocked"), None));
    };
    let conflicts = compare(candidate, current)?;
    if strategy == KnowledgeRestoreStrategy::RequireNoIdentityConflicts
        && conflicts.changed_items + conflicts.changed_folders > 0
    {
        return Ok((ProjectionSummary::blocked("qualificationBlocked"), None));
    }
    let current_items = keyed(current, "items")?;
    let current_folders = keyed(current, "folders")?;
    let imported_items = keyed(candidate, "items")?
        .into_iter()
        .filter(|(id, _)| !current_items.contains_key(id))
        .map(|(_, v)| v)
        .collect::<Vec<_>>();
    let imported_folders = keyed(candidate, "folders")?
        .into_iter()
        .filter(|(id, _)| !current_folders.contains_key(id))
        .map(|(_, v)| v)
        .collect::<Vec<_>>();
    if current_items.len() + imported_items.len() > 2000
        || current_folders.len() + imported_folders.len() > 128
    {
        return Ok((ProjectionSummary::blocked("capacityExceeded"), None));
    }
    let mut names = current_folders
        .values()
        .map(|v| {
            v.get("name")
                .and_then(Value::as_str)
                .map(str::to_lowercase)
                .ok_or_else(invalid)
        })
        .collect::<CommandResult<BTreeSet<_>>>()?;
    for folder in &imported_folders {
        if !names.insert(
            folder
                .get("name")
                .and_then(Value::as_str)
                .ok_or_else(invalid)?
                .to_lowercase(),
        ) {
            return Ok((ProjectionSummary::blocked("folderNameCollision"), None));
        }
    }
    let mut items = current
        .get("items")
        .and_then(Value::as_array)
        .ok_or_else(invalid)?
        .clone();
    let mut reset = 0u64;
    for value in &imported_items {
        bounded(started)?;
        let mut value = (*value).clone();
        let summary = value
            .get_mut("summary")
            .and_then(Value::as_object_mut)
            .ok_or_else(invalid)?;
        if summary.get("allowsRemoteAiUse").and_then(Value::as_bool) == Some(true)
            || summary
                .get("allowsLocalSemanticIndex")
                .and_then(Value::as_bool)
                == Some(true)
        {
            reset += 1;
        }
        summary.insert("allowsRemoteAiUse".into(), Value::Bool(false));
        summary.insert("allowsLocalSemanticIndex".into(), Value::Bool(false));
        items.push(value);
    }
    let mut folders = current
        .get("folders")
        .and_then(Value::as_array)
        .ok_or_else(invalid)?
        .clone();
    folders.extend(imported_folders.iter().map(|v| (*v).clone()));
    let merged = serde_json::json!({"schemaVersion":4,"items":items,"folders":folders,"completedOperations":[]});
    let bytes = serde_json::to_vec(&merged).map_err(|_| invalid())?;
    if bytes.len() > MANIFEST {
        return Ok((ProjectionSummary::blocked("capacityExceeded"), None));
    }
    if knowledge_package_check::parse_json(&bytes, started).is_err() {
        bounded(started)?;
        return Ok((ProjectionSummary::blocked("manifestInvalid"), None));
    }
    let refs = match manifest::project(&bytes) {
        Ok(r) => r,
        Err(_) => return Ok((ProjectionSummary::blocked("manifestInvalid"), None)),
    };
    manifest::validate_completed_operations(&bytes).map_err(|_| invalid())?;
    let body = refs
        .files
        .iter()
        .filter(|r| r.kind == "body")
        .map(|r| r.byte_size)
        .sum::<u64>();
    let archive = refs
        .files
        .iter()
        .filter(|r| r.kind == "archive")
        .map(|r| r.byte_size)
        .sum::<u64>();
    if refs.files.len() > 2048 || body + archive > 64 * 1024 * 1024 {
        return Ok((ProjectionSummary::blocked("capacityExceeded"), None));
    }
    // Every merged reference must be contained in the already content-verified inputs.
    let mut available = BTreeMap::new();
    for raw in [current, candidate] {
        bounded(started)?;
        let input = manifest::project(&serde_json::to_vec(raw).map_err(|_| invalid())?)
            .map_err(|_| invalid())?;
        for reference in input.files {
            let key = (reference.kind, reference.digest.clone());
            if let Some(existing) = available.get_mut(&key) {
                let existing:&mut crate::core::knowledge_library::knowledge_integrity_manifest::IntegrityReference=existing;
                if existing.byte_size != reference.byte_size {
                    return Ok((ProjectionSummary::blocked("referenceMismatch"), None));
                }
                existing.formats.extend(reference.formats);
            } else {
                available.insert(key, reference);
            }
        }
    }
    for reference in &refs.files {
        let Some(input) = available.get(&(reference.kind, reference.digest.clone())) else {
            return Ok((ProjectionSummary::blocked("referenceMismatch"), None));
        };
        if input.byte_size != reference.byte_size || !reference.formats.is_subset(&input.formats) {
            return Ok((ProjectionSummary::blocked("referenceMismatch"), None));
        }
    }
    bounded(started)?;
    Ok((
        ProjectionSummary {
            state: "validated",
            reason: "none",
            manifest_sha256: Some(hash(&bytes)),
            manifest_byte_size: Some(bytes.len()),
            item_count: Some(refs.items),
            revision_count: Some(refs.revisions),
            folder_count: Some(merged["folders"].as_array().ok_or_else(invalid)?.len() as u64),
            file_count: Some(refs.files.len()),
            resource_byte_size: Some(body + archive),
            body_byte_size: Some(body),
            archive_byte_size: Some(archive),
            imported_items: Some(imported_items.len() as u64),
            imported_folders: Some(imported_folders.len() as u64),
            reset_permission_items: Some(reset),
            completed_operations_excluded: true,
        },
        Some(bytes),
    ))
}
pub(crate) fn project(
    candidate: &Value,
    current: Option<&Value>,
    resources: &ResourceSummary,
    strategy: KnowledgeRestoreStrategy,
    started: Instant,
) -> CommandResult<ProjectionSummary> {
    project_material(candidate, current, resources, strategy, started).map(|r| r.0)
}
#[path = "knowledge_restore_install.rs"]
pub(super) mod install;
pub(crate) use install::normal_library_access;
pub use install::{
    KnowledgeRestoreArchiveAction, KnowledgeRestoreArchivePlan, KnowledgeRestoreArchiveReceipt,
    KnowledgeRestoreArchiveStatus, KnowledgeRestoreArchiveStore, KnowledgeRestoreCleanupAction,
    KnowledgeRestoreCleanupPlan, KnowledgeRestoreCleanupReceipt, KnowledgeRestoreCleanupStatus,
    KnowledgeRestoreCleanupStore, KnowledgeRestoreDiagnosis, KnowledgeRestoreHistoryExportPlan,
    KnowledgeRestoreHistoryExportReceipt, KnowledgeRestoreHistoryExportStatus,
    KnowledgeRestoreHistoryExportStore, KnowledgeRestoreInstallPlan, KnowledgeRestoreInstallStore,
    KnowledgeRestoreReceipt, KnowledgeRestoreRecoveryAction, KnowledgeRestoreRecoveryPlan,
};
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ProjectionLimits {
    manifest_bytes: usize,
    items: usize,
    folders: usize,
    resource_files: usize,
    resource_bytes: usize,
    body_bytes: usize,
    archive_bytes: usize,
    json_nodes: usize,
    duration_ms: u64,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeMergeProjectionPlan {
    schema_version: u8,
    scope: &'static str,
    pub plan_id: String,
    source: KnowledgeRestoreQualificationPlan,
    projection: ProjectionSummary,
    limits: ProjectionLimits,
    privacy_mode: &'static str,
    privacy_reset_acknowledgement_required: bool,
    current_permissions_preserved: bool,
    source_permissions_copied: bool,
    projected_manifest_validated: bool,
    filesystem_writes: bool,
    current_library_changed: bool,
    restore_ready: bool,
    consistent_snapshot: bool,
    checked_at_epoch_ms: u64,
    expires_at_epoch_ms: u64,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeMergeProjectionReceipt {
    plan_id: String,
    projection_manifest_sha256: String,
    item_count: u64,
    revision_count: u64,
    folder_count: u64,
    imported_items: u64,
    imported_folders: u64,
    reset_permission_items: u64,
    privacy_reset_acknowledged: bool,
    imported_permissions_disabled: bool,
    current_permissions_preserved: bool,
    source_permissions_copied: bool,
    validated_in_memory: bool,
    filesystem_writes: bool,
    current_library_changed: bool,
    restore_ready: bool,
    consistent_snapshot: bool,
    completed_at_epoch_ms: u64,
}
struct StoredProjection {
    observation: Stored,
    strategy: KnowledgeRestoreStrategy,
    projection: ProjectionSummary,
}
#[derive(Default)]
pub struct KnowledgeMergeProjectionStore {
    check: KnowledgeRestoreQualificationStore,
    plans: Mutex<HashMap<String, StoredProjection>>,
}
impl KnowledgeMergeProjectionStore {
    pub fn new(root: PathBuf) -> Self {
        Self {
            check: KnowledgeRestoreQualificationStore::new(root),
            plans: Mutex::new(HashMap::new()),
        }
    }
    pub fn plan(
        &self,
        path: &Path,
        strategy: KnowledgeRestoreStrategy,
    ) -> CommandResult<KnowledgeMergeProjectionPlan> {
        self.plan_checked(path, strategy, |_| {})
    }
    fn plan_checked(
        &self,
        path: &Path,
        strategy: KnowledgeRestoreStrategy,
        hook: impl FnMut(u8),
    ) -> CommandResult<KnowledgeMergeProjectionPlan> {
        let mut plans = self.plans.lock().map_err(|_| invalid())?;
        let time = now()?;
        plans.retain(|_, p| p.observation.created.elapsed() < TTL && p.observation.expires > time);
        if plans.len() >= 2 {
            return Err(invalid());
        }
        let (plan, stored) = self.capture(path, strategy, hook)?;
        plans.insert(plan.plan_id.clone(), stored);
        Ok(plan)
    }
    pub fn discard(&self, id: &str) -> CommandResult<()> {
        self.plans.lock().map_err(|_| invalid())?.remove(id);
        Ok(())
    }
    pub fn preflight(
        &self,
        id: &str,
        acknowledge_privacy_reset: bool,
    ) -> CommandResult<KnowledgeMergeProjectionReceipt> {
        let mut plans = self.plans.lock().map_err(|_| invalid())?;
        let old = plans.remove(id).ok_or_else(invalid)?;
        if !acknowledge_privacy_reset
            || old.projection.state != "validated"
            || old.observation.created.elapsed() >= TTL
            || now()? >= old.observation.expires
        {
            return Err(invalid());
        }
        let (fresh, stored) = self.capture(&old.observation.path, old.strategy, |_| {})?;
        let completed = now()?;
        if old.observation.created.elapsed() >= TTL
            || completed >= old.observation.expires
            || completed < old.observation.expires - 300000
            || fresh.projection.state != "validated"
            || stored.observation.fingerprint != old.observation.fingerprint
        {
            return Err(invalid());
        }
        let p = fresh.projection;
        Ok(KnowledgeMergeProjectionReceipt {
            plan_id: id.into(),
            projection_manifest_sha256: p.manifest_sha256.ok_or_else(invalid)?,
            item_count: p.item_count.ok_or_else(invalid)?,
            revision_count: p.revision_count.ok_or_else(invalid)?,
            folder_count: p.folder_count.ok_or_else(invalid)?,
            imported_items: p.imported_items.ok_or_else(invalid)?,
            imported_folders: p.imported_folders.ok_or_else(invalid)?,
            reset_permission_items: p.reset_permission_items.ok_or_else(invalid)?,
            privacy_reset_acknowledged: true,
            imported_permissions_disabled: true,
            current_permissions_preserved: true,
            source_permissions_copied: false,
            validated_in_memory: true,
            filesystem_writes: false,
            current_library_changed: false,
            restore_ready: false,
            consistent_snapshot: false,
            completed_at_epoch_ms: completed,
        })
    }
    fn capture(
        &self,
        path: &Path,
        strategy: KnowledgeRestoreStrategy,
        hook: impl FnMut(u8),
    ) -> CommandResult<(KnowledgeMergeProjectionPlan, StoredProjection)> {
        let (source, stored, projection) = self.check.capture_mode(path, strategy, hook, true)?;
        let projection = projection.ok_or_else(invalid)?;
        if projection.state == "validated" && source.qualification.state != "evidenceReady" {
            return Err(invalid());
        }
        let plan = KnowledgeMergeProjectionPlan {
            schema_version: 1,
            scope: "knowledgeMergeProjection",
            plan_id: Uuid::new_v4().to_string(),
            projected_manifest_validated: projection.state == "validated",
            projection: projection.clone(),
            limits: ProjectionLimits {
                manifest_bytes: MANIFEST,
                items: 2000,
                folders: 128,
                resource_files: 2048,
                resource_bytes: 64 * 1024 * 1024,
                body_bytes: 64 * 1024 * 1024,
                archive_bytes: 512 * 1024 * 1024,
                json_nodes: 131072,
                duration_ms: 5000,
            },
            privacy_mode: "disableImportedPermissions",
            privacy_reset_acknowledgement_required: true,
            current_permissions_preserved: true,
            source_permissions_copied: false,
            filesystem_writes: false,
            current_library_changed: false,
            restore_ready: false,
            consistent_snapshot: false,
            checked_at_epoch_ms: source.checked_at_epoch_ms,
            expires_at_epoch_ms: source.expires_at_epoch_ms,
            source,
        };
        bounded(stored.observation.created)?;
        Ok((
            plan,
            StoredProjection {
                observation: stored.observation,
                strategy,
                projection,
            },
        ))
    }
}
#[cfg(test)]
#[path = "knowledge_merge_projection_tests.rs"]
mod tests;
