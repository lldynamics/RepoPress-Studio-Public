//! Confirmed export of a closed history snapshot. No historical or current-library mutation.
use super::*;
use crate::core::{
    knowledge_backup::{self, SavedSnapshotPackage},
    rollback_archive::Destination,
    workspace_config_backup::reject_git_ancestors,
};

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeRestoreHistoryExportStatus {
    schema_version: u8,
    scope: &'static str,
    state: &'static str,
    history: Vec<KnowledgeRestoreArchiveEntry>,
    history_limit: usize,
    library_access_blocked: bool,
    filesystem_writes: bool,
}
impl KnowledgeRestoreHistoryExportStatus {
    fn empty(state: &'static str, blocked: bool) -> Self {
        Self {
            schema_version: 1,
            scope: "knowledgeRestoreHistoryExportStatus",
            state,
            history: vec![],
            history_limit: HISTORY_LIMIT,
            library_access_blocked: blocked,
            filesystem_writes: false,
        }
    }
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeRestoreHistoryExportPlan {
    schema_version: u8,
    scope: &'static str,
    pub plan_id: String,
    selected: KnowledgeRestoreArchiveEntry,
    destination_path: String,
    byte_size: usize,
    sha256: String,
    manifest_sha256: String,
    source_manifest_sha256: String,
    item_count: u64,
    revision_count: u64,
    body_file_count: usize,
    archive_file_count: usize,
    resource_byte_size: u64,
    exclusions: Vec<&'static str>,
    requires_sensitive_plaintext_consent: bool,
    current_library_changed: bool,
    source_history_changed: bool,
    restore_ready: bool,
    includes_credential_stores: bool,
    includes_completed_operations: bool,
    external_references_included: bool,
    consistent_snapshot: bool,
    checked_at_epoch_ms: u64,
    expires_at_epoch_ms: u64,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeRestoreHistoryExportReceipt {
    schema_version: u8,
    scope: &'static str,
    plan_id: String,
    selected: KnowledgeRestoreArchiveEntry,
    destination_path: String,
    byte_size: usize,
    sha256: String,
    manifest_sha256: String,
    source_manifest_sha256: String,
    source_revalidated: bool,
    contents_verified: bool,
    private_permissions_verified: bool,
    current_library_changed: bool,
    source_history_changed: bool,
    restore_ready: bool,
    completed_at_epoch_ms: u64,
}
struct Pending {
    plan: KnowledgeRestoreHistoryExportPlan,
    destination: Destination,
    parent: File,
    fingerprint: String,
    bytes: Vec<u8>,
    created: Instant,
}
impl Pending {
    fn valid(&self) -> CommandResult<()> {
        let t = now()?;
        if self.created.elapsed() >= TTL
            || t < self.plan.checked_at_epoch_ms
            || t >= self.plan.expires_at_epoch_ms
        {
            return Err(export_invalid());
        }
        Ok(())
    }
}
#[derive(Default)]
pub struct KnowledgeRestoreHistoryExportStore {
    install: KnowledgeRestoreInstallStore,
    plans: Mutex<HashMap<String, Pending>>,
}
fn export_invalid() -> CommandError {
    CommandError::new("knowledge_restore_history_export_invalid", "Closed history, destination, consent, limits or one-time export plan is unavailable, changed or expired. Inspect and prepare a new export plan.")
}
fn export_unconfirmed() -> CommandError {
    CommandError::new("knowledge_restore_history_export_unconfirmed", "History export outcome is unknown. A private JSON file may remain at the reviewed destination; inspect it before using a new path. The plan is consumed and no automatic retry or history/current-library mutation was performed.")
}
fn mount_id(file: &File) -> CommandResult<u64> {
    let mut stat: libc::statx = unsafe { std::mem::zeroed() };
    let empty = CString::new("").map_err(|_| export_invalid())?;
    if unsafe {
        libc::statx(
            file.as_raw_fd(),
            empty.as_ptr(),
            libc::AT_EMPTY_PATH | libc::AT_SYMLINK_NOFOLLOW,
            libc::STATX_MNT_ID,
            &mut stat,
        )
    } != 0
        || stat.stx_mask & libc::STATX_MNT_ID == 0
    {
        return Err(export_invalid());
    }
    Ok(stat.stx_mnt_id)
}
fn output_parent(lease: &KnowledgeRootLease, path: &Path) -> CommandResult<File> {
    let parent_path = path.parent().ok_or_else(export_invalid)?;
    reject_git_ancestors(parent_path)?;
    let parent = crate::core::rollback_archive::directory(parent_path)?;
    // P55 conservatively supports the same mount only, rejecting bind aliases of
    // application storage that would evade lexical containment checks.
    if mount_id(&parent)? != mount_id(&lease.file)?
        || disk::identity(&disk::file_stamp(&parent)?)
            == disk::identity(&disk::file_stamp(&lease.file)?)
    {
        return Err(export_invalid());
    }
    Ok(parent)
}
fn observe(
    lease: &KnowledgeRootLease,
) -> CommandResult<(Vec<KnowledgeRestoreArchiveEntry>, String)> {
    lease.verify()?;
    normal_library_access(&lease.file)?;
    let started = Instant::now();
    let first = histories(&lease.file, None, started)?;
    if histories(&lease.file, None, started)? != first {
        return Err(export_invalid());
    }
    normal_library_access(&lease.file)?;
    lease.verify()?;
    archive_bounded(started)?;
    Ok(first)
}
fn capture(
    lease: &KnowledgeRootLease,
    entry: &KnowledgeRestoreArchiveEntry,
    time: u64,
) -> CommandResult<SavedSnapshotPackage> {
    if !entry.snapshot_present
        || entry.snapshot_file_count > 1025
        || entry.snapshot_byte_size > 34 * 1024 * 1024
    {
        return Err(export_invalid());
    }
    let started = Instant::now();
    let name = history_name(&entry.transaction_id);
    let dir = disk::directory(&lease.file, &name).map_err(|_| export_invalid())?;
    let record = read_record(
        &dir.file,
        RECORD,
        disk::identity(&disk::file_stamp(&lease.file)?),
    )?;
    if record.record.entry() != *entry {
        return Err(export_invalid());
    }
    let expected = record.record.snapshot.as_ref().ok_or_else(export_invalid)?;
    let snapshot = disk::directory(&dir.file, SNAPSHOT).map_err(|_| export_invalid())?;
    if audit_tree(&dir.file, SNAPSHOT, MAX_RESOURCES, MAX_RESOURCE_BYTES)? != *expected {
        return Err(export_invalid());
    }
    let mut files = BTreeMap::new();
    for (path, stamp) in &expected.files {
        archive_bounded(started)?;
        let read = disk::read(
            &snapshot.file,
            path,
            disk::byte_size(stamp) as usize,
            Instant::now(),
        )
        .map_err(|_| export_invalid())?;
        if read.witness.before != *stamp || !read.witness.verify(&snapshot.file, path) {
            return Err(export_invalid());
        }
        files.insert(path.clone(), read.bytes);
    }
    let manifest = files.remove("manifest.json").ok_or_else(export_invalid)?;
    let package = knowledge_backup::saved_snapshot_package(&manifest, &files, time)?;
    if package.source_manifest_sha256 != expected.manifest_sha256
        || audit_tree(&dir.file, SNAPSHOT, MAX_RESOURCES, MAX_RESOURCE_BYTES)? != *expected
        || !disk::verify_dir(&lease.file, &name, &dir)
    {
        return Err(export_invalid());
    }
    archive_bounded(started)?;
    lease.verify()?;
    Ok(package)
}
impl KnowledgeRestoreHistoryExportStore {
    pub fn new(root: PathBuf) -> Self {
        Self {
            install: KnowledgeRestoreInstallStore::new(root),
            plans: Mutex::new(HashMap::new()),
        }
    }
    pub fn inspect(&self) -> CommandResult<KnowledgeRestoreHistoryExportStatus> {
        let lease = match self.install.unrestricted_lease() {
            Ok(l) => l,
            Err(_) => {
                return Ok(KnowledgeRestoreHistoryExportStatus::empty(
                    "unavailable",
                    true,
                ))
            }
        };
        match observe(&lease) {
            Ok((history, _)) => Ok(KnowledgeRestoreHistoryExportStatus {
                state: if history.is_empty() { "none" } else { "ready" },
                history,
                ..KnowledgeRestoreHistoryExportStatus::empty("none", false)
            }),
            Err(_) => Ok(KnowledgeRestoreHistoryExportStatus::empty(
                "blocked",
                normal_library_access(&lease.file).is_err(),
            )),
        }
    }
    pub fn plan(
        &self,
        transaction_id: &str,
        path: &Path,
    ) -> CommandResult<KnowledgeRestoreHistoryExportPlan> {
        if !disk::valid_id(transaction_id) {
            return Err(export_invalid());
        }
        let mut plans = self.plans.lock().map_err(|_| export_invalid())?;
        plans.retain(|_, p| p.valid().is_ok());
        if plans.len() >= 2 {
            return Err(export_invalid());
        }
        let lease = self.install.unrestricted_lease()?;
        let (history, fingerprint) = observe(&lease)?;
        let selected = history
            .iter()
            .find(|e| e.transaction_id == transaction_id)
            .ok_or_else(export_invalid)?
            .clone();
        reject_git_ancestors(path.parent().ok_or_else(export_invalid)?)?;
        let root_path = self.install.root.as_deref().ok_or_else(export_invalid)?;
        let destination = Destination::knowledge_package(path, root_path)?;
        let parent = output_parent(&lease, path)?;
        let checked = now()?;
        let package = capture(&lease, &selected, checked)?;
        if observe(&lease)?.1 != fingerprint {
            return Err(export_invalid());
        }
        let plan = KnowledgeRestoreHistoryExportPlan {
            schema_version: 1,
            scope: "knowledgeRestoreHistoryExportPlan",
            plan_id: Uuid::new_v4().to_string(),
            selected,
            destination_path: path.to_str().ok_or_else(export_invalid)?.into(),
            byte_size: package.bytes.len(),
            sha256: hash(&package.bytes),
            manifest_sha256: package.manifest_sha256,
            source_manifest_sha256: package.source_manifest_sha256,
            item_count: package.item_count,
            revision_count: package.revision_count,
            body_file_count: package.body_file_count,
            archive_file_count: package.archive_file_count,
            resource_byte_size: package.resource_byte_size,
            exclusions: package.exclusions,
            requires_sensitive_plaintext_consent: true,
            current_library_changed: false,
            source_history_changed: false,
            restore_ready: false,
            includes_credential_stores: false,
            includes_completed_operations: false,
            external_references_included: false,
            consistent_snapshot: false,
            checked_at_epoch_ms: checked,
            expires_at_epoch_ms: checked.checked_add(300000).ok_or_else(export_invalid)?,
        };
        let current = now()?;
        if current < plan.checked_at_epoch_ms || current >= plan.expires_at_epoch_ms {
            return Err(export_invalid());
        }
        plans.insert(
            plan.plan_id.clone(),
            Pending {
                plan: plan.clone(),
                destination,
                parent,
                fingerprint,
                bytes: package.bytes,
                created: Instant::now(),
            },
        );
        Ok(plan)
    }
    pub fn discard(&self, id: &str) -> CommandResult<()> {
        self.plans.lock().map_err(|_| export_invalid())?.remove(id);
        Ok(())
    }
    pub fn execute(
        &self,
        id: &str,
        consent: bool,
    ) -> CommandResult<KnowledgeRestoreHistoryExportReceipt> {
        self.execute_checked(id, consent, |_| Ok(()))
    }
    fn execute_checked(
        &self,
        id: &str,
        consent: bool,
        mut hook: impl FnMut(u8) -> CommandResult<()>,
    ) -> CommandResult<KnowledgeRestoreHistoryExportReceipt> {
        let p = self
            .plans
            .lock()
            .map_err(|_| export_invalid())?
            .remove(id)
            .ok_or_else(export_invalid)?;
        if !consent {
            return Err(export_invalid());
        }
        p.valid()?;
        let lease = self.install.unrestricted_lease()?;
        let check = || {
            p.valid()?;
            if observe(&lease)?.1 != p.fingerprint {
                return Err(export_invalid());
            }
            let parent = output_parent(&lease, Path::new(&p.plan.destination_path))?;
            if disk::identity(&disk::file_stamp(&parent)?)
                != disk::identity(&disk::file_stamp(&p.parent)?)
            {
                return Err(export_invalid());
            }
            Ok(())
        };
        check()?;
        // Regenerate the same captured-at package and verify every source byte before any output.
        let package = capture(&lease, &p.plan.selected, p.plan.checked_at_epoch_ms)?;
        if package.bytes != p.bytes || hash(&package.bytes) != p.plan.sha256 {
            return Err(export_invalid());
        }
        hook(0)?;
        check()?;
        p.destination
            .write(&p.bytes, &mut || {
                hook(1)?;
                check()
            })
            .map_err(|_| export_unconfirmed())?;
        let name = Path::new(&p.plan.destination_path)
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or_else(export_unconfirmed)?;
        let output = disk::read(
            &p.parent,
            name,
            knowledge_backup::PACKAGE_BYTES,
            Instant::now(),
        )
        .map_err(|_| export_unconfirmed())?;
        if output.bytes != p.bytes {
            return Err(export_unconfirmed());
        }
        hook(2).map_err(|_| export_unconfirmed())?;
        check().map_err(|_| export_unconfirmed())?;
        hook(3).map_err(|_| export_unconfirmed())?;
        check().map_err(|_| export_unconfirmed())?;
        let final_output = disk::read(
            &p.parent,
            name,
            knowledge_backup::PACKAGE_BYTES,
            Instant::now(),
        )
        .map_err(|_| export_unconfirmed())?;
        if final_output.bytes != p.bytes
            || final_output.witness.before != output.witness.before
            || !output.witness.verify(&p.parent, name)
        {
            return Err(export_unconfirmed());
        }
        p.valid().map_err(|_| export_unconfirmed())?;
        Ok(KnowledgeRestoreHistoryExportReceipt {
            schema_version: 1,
            scope: "knowledgeRestoreHistoryExportReceipt",
            plan_id: p.plan.plan_id,
            selected: p.plan.selected,
            destination_path: p.plan.destination_path,
            byte_size: p.plan.byte_size,
            sha256: p.plan.sha256,
            manifest_sha256: p.plan.manifest_sha256,
            source_manifest_sha256: p.plan.source_manifest_sha256,
            source_revalidated: true,
            contents_verified: true,
            private_permissions_verified: true,
            current_library_changed: false,
            source_history_changed: false,
            restore_ready: false,
            completed_at_epoch_ms: now()?,
        })
    }
}
#[cfg(test)]
#[path = "knowledge_restore_history_export_tests.rs"]
mod tests;
