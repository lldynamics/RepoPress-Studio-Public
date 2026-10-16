//! Read-only evidence and policy preview. No projected manifest or restore authority.
use super::*;
#[path = "knowledge_merge_projection.rs"]
pub(super) mod projection;
pub(crate) use projection::normal_library_access;
pub use projection::{
    KnowledgeMergeProjectionPlan, KnowledgeMergeProjectionReceipt, KnowledgeMergeProjectionStore,
    KnowledgeRestoreArchiveAction, KnowledgeRestoreArchivePlan, KnowledgeRestoreArchiveReceipt,
    KnowledgeRestoreArchiveStatus, KnowledgeRestoreArchiveStore, KnowledgeRestoreCleanupAction,
    KnowledgeRestoreCleanupPlan, KnowledgeRestoreCleanupReceipt, KnowledgeRestoreCleanupStatus,
    KnowledgeRestoreCleanupStore, KnowledgeRestoreDiagnosis, KnowledgeRestoreHistoryExportPlan,
    KnowledgeRestoreHistoryExportReceipt, KnowledgeRestoreHistoryExportStatus,
    KnowledgeRestoreHistoryExportStore, KnowledgeRestoreInstallPlan, KnowledgeRestoreInstallStore,
    KnowledgeRestoreReceipt, KnowledgeRestoreRecoveryAction, KnowledgeRestoreRecoveryPlan,
};
#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum KnowledgeRestoreStrategy {
    RequireNoIdentityConflicts,
    KeepCurrentIdentities,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ResourceSummary {
    state: &'static str,
    file_count: Option<usize>,
    byte_size: Option<usize>,
    inventory_sha256: Option<String>,
    unreferenced_files_verified: bool,
    external_references_verified: bool,
}
impl ResourceSummary {
    pub(super) fn is_checked(&self) -> bool {
        self.state == "checked"
    }

    fn unavailable(state: &'static str) -> Self {
        Self {
            state,
            file_count: None,
            byte_size: None,
            inventory_sha256: None,
            unreferenced_files_verified: false,
            external_references_verified: false,
        }
    }
}
struct ObservedResource {
    kind: &'static str,
    name: String,
    observation: disk::Observation,
    witness: Option<disk::Witness>,
}
pub(super) struct ResourceAudit {
    pub summary: ResourceSummary,
    enabled: bool,
    collect: bool,
    pub(super) material: BTreeMap<String, Vec<u8>>,
    bodies_observation: Option<disk::Observation>,
    archives_observation: Option<disk::Observation>,
    bodies: Option<disk::Dir>,
    archives: Option<disk::Dir>,
    files: Vec<ObservedResource>,
}
impl ResourceAudit {
    pub fn capture(current: &Current, started: Instant, enabled: bool, collect: bool) -> Self {
        let mut audit = Self {
            summary: ResourceSummary::unavailable("notChecked"),
            enabled,
            collect,
            material: BTreeMap::new(),
            bodies_observation: None,
            archives_observation: None,
            bodies: None,
            archives: None,
            files: Vec::new(),
        };
        if !enabled || current.summary.state != "checked" {
            return audit;
        }
        let Some(dir) = &current.dir else {
            return audit;
        };
        audit.bodies_observation = Some(disk::observe(&dir.file, "blobs", true));
        audit.archives_observation = Some(disk::observe(&dir.file, "archives", true));
        if let Err(state) = audit.read(current, started) {
            audit.summary = ResourceSummary::unavailable(state);
        }
        audit
    }
    fn read(&mut self, current: &Current, started: Instant) -> Result<(), &'static str> {
        let base = &current.dir.as_ref().ok_or("notChecked")?.file;
        self.bodies = Some(disk::directory(base, "blobs")?);
        self.archives = Some(disk::directory(base, "archives")?);
        let bytes =
            serde_json::to_vec(current.raw.as_ref().ok_or("notChecked")?).map_err(|_| "invalid")?;
        let refs = manifest::project(&bytes).map_err(|_| "invalid")?;
        if refs.files.len() > 1024 {
            return Err("overLimit");
        }
        if refs.missing_archives > 0 || refs.truncated_archives > 0 || refs.unknown_archives > 0 {
            return Err("incomplete");
        }
        let mut total = 0usize;
        let mut inventory = Vec::new();
        for reference in &refs.files {
            bounded(started).map_err(|_| "unreadable")?;
            if reference.byte_size > RESOURCE_BYTES.saturating_sub(total) as u64 {
                return Err("overLimit");
            }
            let kind = if reference.kind == "body" {
                "blobs"
            } else {
                "archives"
            };
            let dir = if kind == "blobs" {
                &self.bodies
            } else {
                &self.archives
            };
            let dir = &dir.as_ref().ok_or("unsafe")?.file;
            let observation = disk::observe(dir, &reference.digest, false);
            self.files.push(ObservedResource {
                kind,
                name: reference.digest.clone(),
                observation,
                witness: None,
            });
            let read = disk::read(
                dir,
                &reference.digest,
                reference.byte_size as usize,
                started,
            )?;
            self.files.last_mut().ok_or("invalid")?.witness = Some(read.witness);
            if !manifest::content_matches(reference, &read.bytes) {
                return Err("invalid");
            }
            total += read.bytes.len();
            inventory.push(serde_json::json!({"path":format!("{}/{}",kind,reference.digest),"byteSize":read.bytes.len(),"sha256":hash(&read.bytes)}));
            if self.collect {
                self.material
                    .insert(format!("{}/{}", kind, reference.digest), read.bytes);
            }
        }
        inventory.sort_by(|a, b| a["path"].as_str().cmp(&b["path"].as_str()));
        self.summary = ResourceSummary {
            state: "checked",
            file_count: Some(inventory.len()),
            byte_size: Some(total),
            inventory_sha256: Some(hash(
                &serde_json::to_vec(&inventory).map_err(|_| "invalid")?,
            )),
            unreferenced_files_verified: false,
            external_references_verified: false,
        };
        Ok(())
    }
    pub fn verify(&mut self, current: &Current) {
        if !self.enabled {
            return;
        }
        if current.summary.state != "checked" {
            if current.summary.state == "changed" {
                self.summary = ResourceSummary::unavailable("changed");
            }
            return;
        }
        let Some(base) = current.dir.as_ref().map(|d| &d.file) else {
            self.summary = ResourceSummary::unavailable("changed");
            return;
        };
        let changed = self.bodies_observation.as_ref() != Some(&disk::observe(base, "blobs", true))
            || self.archives_observation.as_ref() != Some(&disk::observe(base, "archives", true))
            || self
                .bodies
                .as_ref()
                .is_some_and(|d| !disk::verify_dir(base, "blobs", d))
            || self
                .archives
                .as_ref()
                .is_some_and(|d| !disk::verify_dir(base, "archives", d))
            || self.files.iter().any(|file| {
                let dir = if file.kind == "blobs" {
                    &self.bodies
                } else {
                    &self.archives
                };
                dir.as_ref().is_none_or(|d| {
                    disk::observe(&d.file, &file.name, false) != file.observation
                        || file
                            .witness
                            .as_ref()
                            .is_some_and(|w| !w.verify(&d.file, &file.name))
                })
            });
        if changed {
            self.summary = ResourceSummary::unavailable("changed");
        }
    }
    pub fn fingerprint(&self) -> CommandResult<String> {
        Ok(hash(
            &serde_json::to_vec(&(
                &self.summary,
                &self.bodies_observation,
                &self.archives_observation,
                self.files
                    .iter()
                    .map(|f| {
                        (
                            &f.kind,
                            &f.name,
                            &f.observation,
                            f.witness.as_ref().map(|w| &w.before),
                        )
                    })
                    .collect::<Vec<_>>(),
            ))
            .map_err(|_| invalid())?,
        ))
    }
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Qualification {
    state: &'static str,
    reason: &'static str,
    add_items: Option<u64>,
    retain_items: Option<u64>,
    skip_candidate_items: Option<u64>,
    add_folders: Option<u64>,
    retain_folders: Option<u64>,
    skip_candidate_folders: Option<u64>,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeRestoreQualificationPlan {
    schema_version: u8,
    scope: &'static str,
    pub plan_id: String,
    target_scope: &'static str,
    candidate: KnowledgeCandidateCheckReport,
    current_resources: ResourceSummary,
    strategy: KnowledgeRestoreStrategy,
    qualification: Qualification,
    current_only_preserved: bool,
    candidate_permissions_applied: bool,
    projected_manifest_validated: bool,
    consistent_snapshot: bool,
    filesystem_writes: bool,
    restore_ready: bool,
    checked_at_epoch_ms: u64,
    expires_at_epoch_ms: u64,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeRestoreQualificationRecheck {
    plan: KnowledgeRestoreQualificationPlan,
    comparison: &'static str,
}
struct StoredPlan {
    observation: Stored,
    strategy: KnowledgeRestoreStrategy,
}
#[derive(Default)]
pub struct KnowledgeRestoreQualificationStore {
    check: KnowledgeCandidateCheckStore,
    plans: Mutex<HashMap<String, StoredPlan>>,
}
impl KnowledgeRestoreQualificationStore {
    pub fn new(root: PathBuf) -> Self {
        Self {
            check: KnowledgeCandidateCheckStore::new(root),
            plans: Mutex::new(HashMap::new()),
        }
    }
    pub fn plan(
        &self,
        path: &Path,
        strategy: KnowledgeRestoreStrategy,
    ) -> CommandResult<KnowledgeRestoreQualificationPlan> {
        self.plan_checked(path, strategy, |_| {})
    }
    fn plan_checked(
        &self,
        path: &Path,
        strategy: KnowledgeRestoreStrategy,
        hook: impl FnMut(u8),
    ) -> CommandResult<KnowledgeRestoreQualificationPlan> {
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
    pub fn recheck(&self, id: &str) -> CommandResult<KnowledgeRestoreQualificationRecheck> {
        let mut plans = self.plans.lock().map_err(|_| invalid())?;
        let old = plans.remove(id).ok_or_else(invalid)?;
        if old.observation.created.elapsed() >= TTL || now()? >= old.observation.expires {
            return Err(invalid());
        }
        let (plan, stored) = self.capture(&old.observation.path, old.strategy, |_| {})?;
        if old.observation.created.elapsed() >= TTL || now()? >= old.observation.expires {
            return Err(invalid());
        }
        let comparison = if !old.observation.comparable || !stored.observation.comparable {
            "inconclusive"
        } else if old.observation.fingerprint == stored.observation.fingerprint {
            "unchanged"
        } else {
            "changed"
        };
        plans.insert(plan.plan_id.clone(), stored);
        Ok(KnowledgeRestoreQualificationRecheck { plan, comparison })
    }
    fn capture(
        &self,
        path: &Path,
        strategy: KnowledgeRestoreStrategy,
        hook: impl FnMut(u8),
    ) -> CommandResult<(KnowledgeRestoreQualificationPlan, StoredPlan)> {
        let (plan, stored, _) = self.capture_mode(path, strategy, hook, false)?;
        Ok((plan, stored))
    }
    fn capture_mode(
        &self,
        path: &Path,
        strategy: KnowledgeRestoreStrategy,
        hook: impl FnMut(u8),
        project: bool,
    ) -> CommandResult<(
        KnowledgeRestoreQualificationPlan,
        StoredPlan,
        Option<projection::ProjectionSummary>,
    )> {
        let (candidate, mut observation, resources, projected, _) =
            self.check
                .capture_extended(path, hook, true, project.then_some(strategy), false)?;
        let reason = if candidate.current_library.state != "checked" {
            "currentManifestUnavailable"
        } else if resources.state != "checked" {
            "currentResourcesUnavailable"
        } else if matches!(
            strategy,
            KnowledgeRestoreStrategy::RequireNoIdentityConflicts
        ) && candidate
            .conflicts
            .as_ref()
            .is_none_or(|c| c.changed_items + c.changed_folders > 0)
        {
            "identityConflicts"
        } else {
            "none"
        };
        let counts = candidate.conflicts.as_ref().filter(|_| reason == "none");
        let qualification = Qualification {
            state: if reason == "none" {
                "evidenceReady"
            } else {
                "blocked"
            },
            reason,
            add_items: counts.map(|c| c.candidate_only_items),
            retain_items: counts.and(candidate.current_library.item_count),
            skip_candidate_items: counts.map(|c| c.changed_items + c.identical_items),
            add_folders: counts.map(|c| c.candidate_only_folders),
            retain_folders: counts.and(candidate.current_library.folder_count),
            skip_candidate_folders: counts.map(|c| c.changed_folders + c.identical_folders),
        };
        observation.comparable =
            candidate.current_library.state == "checked" && resources.state == "checked";
        let plan = KnowledgeRestoreQualificationPlan {
            schema_version: 1,
            scope: "knowledgeRestoreQualification",
            plan_id: Uuid::new_v4().to_string(),
            target_scope: "currentAppKnowledgeLibrary",
            strategy,
            qualification,
            current_resources: resources,
            current_only_preserved: true,
            candidate_permissions_applied: false,
            projected_manifest_validated: false,
            consistent_snapshot: false,
            filesystem_writes: false,
            restore_ready: false,
            checked_at_epoch_ms: candidate.checked_at_epoch_ms,
            expires_at_epoch_ms: candidate.expires_at_epoch_ms,
            candidate,
        };
        bounded(observation.created)?;
        Ok((
            plan,
            StoredPlan {
                observation,
                strategy,
            },
            projected,
        ))
    }
}
#[cfg(test)]
#[path = "knowledge_restore_qualification_tests.rs"]
mod tests;
