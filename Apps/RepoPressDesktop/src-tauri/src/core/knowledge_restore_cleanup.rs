//! Explicit deletion of the newest closed history only, under a durable immutable intent.
use super::*;
const CLEAN_INTENT: &str = "knowledge-restore-cleanup-intent.json";
const QUARANTINE_PREFIX: &str = ".repopress-knowledge-cleanup-";
const RECEIPT_PREFIX: &str = ".repopress-knowledge-cleanup-receipt-";
const CLEAN_BYTES: usize = 8 * 1024 * 1024;
const AUDIT_BYTES: usize = 8 * 1024;
const RECEIPT_LIMIT: usize = 128;
const MAX_CLEAN_BYTES: u64 = 69 * 1024 * 1024;
pub(super) fn access(root: &File) -> CommandResult<()> {
    if disk::observe(root, CLEAN_INTENT, false) != disk::Observation::Missing {
        return Err(blocked());
    }
    Ok(())
}
fn cleanup_invalid() -> CommandError {
    CommandError::new("knowledge_restore_cleanup_invalid", "Cleanup evidence or consent could not be confirmed. Files may have been permanently removed; inspect cleanup state before retrying.")
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum KnowledgeRestoreCleanupAction {
    Delete,
    Resume,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeRestoreCleanupStatus {
    schema_version: u8,
    scope: &'static str,
    state: &'static str,
    cleanup_id: Option<String>,
    selected: Option<KnowledgeRestoreArchiveEntry>,
    history_count: Option<usize>,
    history_limit: usize,
    receipt_count: Option<usize>,
    receipt_limit: usize,
    current_manifest_sha256: Option<String>,
    remaining_file_count: Option<usize>,
    remaining_byte_size: Option<u64>,
    can_delete: bool,
    can_resume: bool,
    history_slot_released: bool,
    library_access_blocked: bool,
    filesystem_writes: bool,
}
impl KnowledgeRestoreCleanupStatus {
    fn empty(state: &'static str, blocked: bool) -> Self {
        Self {
            schema_version: 1,
            scope: "knowledgeRestoreCleanupStatus",
            state,
            cleanup_id: None,
            selected: None,
            history_count: None,
            history_limit: HISTORY_LIMIT,
            receipt_count: None,
            receipt_limit: RECEIPT_LIMIT,
            current_manifest_sha256: None,
            remaining_file_count: None,
            remaining_byte_size: None,
            can_delete: false,
            can_resume: false,
            history_slot_released: false,
            library_access_blocked: blocked,
            filesystem_writes: false,
        }
    }
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeRestoreCleanupPlan {
    schema_version: u8,
    scope: &'static str,
    pub plan_id: String,
    action: KnowledgeRestoreCleanupAction,
    status: KnowledgeRestoreCleanupStatus,
    requires_acknowledgement: bool,
    irreversible: bool,
    current_library_changed: bool,
    deletes_snapshot: bool,
    deletes_history: bool,
    preserves_audit_receipt: bool,
    reclaims_history_slot: bool,
    physical_space_reclaimed_unknown: bool,
    checked_at_epoch_ms: u64,
    expires_at_epoch_ms: u64,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeRestoreCleanupReceipt {
    schema_version: u8,
    scope: &'static str,
    plan_id: String,
    cleanup_id: String,
    transaction_id: String,
    action: KnowledgeRestoreCleanupAction,
    state: &'static str,
    selected: KnowledgeRestoreArchiveEntry,
    removed_file_count: usize,
    removed_byte_size: u64,
    current_library_changed: bool,
    history_slot_released: bool,
    audit_receipt_persisted: bool,
    physical_space_reclaimed_unknown: bool,
    completed_at_epoch_ms: u64,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ExpectedFile {
    stamp: disk::Stamp,
    sha256: String,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ActiveTransaction {
    journal: Journal,
    stamp: disk::Stamp,
    sha256: String,
    snapshot: Option<TreeEvidence>,
}
// A completed active transaction can coexist with four closed histories. Never delete
// its journal or retained snapshot; unresolved or changed active evidence stays blocked.
fn active_transaction(root: &File) -> CommandResult<Option<ActiveTransaction>> {
    let Some(read) = read_journal(root)? else {
        if !reserved(root)?.is_empty() {
            return Err(cleanup_invalid());
        }
        return Ok(None);
    };
    let j = &read.journal;
    if !j.phase.terminal() || active_identity(root) != Some(expected_active(j)?) {
        return Err(cleanup_invalid());
    }
    let name = stage_name(j);
    if reserved(root)?.iter().any(|n| n != &name) {
        return Err(cleanup_invalid());
    }
    let snapshot = expected_snapshot(j)?;
    match &snapshot {
        Some(expected) => {
            if audit_tree(root, &name, MAX_RESOURCES, MAX_RESOURCE_BYTES)? != *expected {
                return Err(cleanup_invalid());
            }
        }
        None => {
            if disk::observe(root, &name, true) != disk::Observation::Missing {
                return Err(cleanup_invalid());
            }
        }
    }
    Ok(Some(ActiveTransaction {
        journal: read.journal,
        stamp: read.stamp,
        sha256: read.hash,
        snapshot,
    }))
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct CleanupIntent {
    schema_version: u8,
    scope: String,
    cleanup_id: String,
    root_identity: (u64, u64, u32, u32),
    root_mount_id: u64,
    archive: ArchiveRecord,
    active: ActiveEvidence,
    active_transaction: Option<ActiveTransaction>,
    current_resources: BTreeMap<String, disk::Stamp>,
    files: BTreeMap<String, ExpectedFile>,
    directories: BTreeMap<String, disk::Stamp>,
    prefix_fingerprint: String,
    receipts_fingerprint: String,
    started_at_epoch_ms: u64,
}
impl CleanupIntent {
    fn total_bytes(&self) -> u64 {
        self.files.values().map(|f| disk::byte_size(&f.stamp)).sum()
    }
    fn quarantine(&self) -> String {
        format!("{}{}", QUARANTINE_PREFIX, self.cleanup_id)
    }
    fn receipt_name(&self) -> String {
        format!("{}{}.json", RECEIPT_PREFIX, self.cleanup_id)
    }
    fn audit(&self) -> AuditReceipt {
        AuditReceipt {
            schema_version: 1,
            scope: "knowledgeRestoreCleanupAudit".into(),
            cleanup_id: self.cleanup_id.clone(),
            transaction_id: self.archive.transaction_id.clone(),
            root_identity: self.root_identity,
            phase: self.archive.journal.phase,
            archive_record_sha256: self.files[RECORD].sha256.clone(),
            transaction_journal_sha256: self.files[JOURNAL].sha256.clone(),
            snapshot_manifest_sha256: self
                .archive
                .snapshot
                .as_ref()
                .map(|s| s.manifest_sha256.clone()),
            snapshot_file_count: self.archive.entry().snapshot_file_count,
            snapshot_byte_size: self.archive.entry().snapshot_byte_size,
            removed_file_count: self.files.len(),
            removed_byte_size: self.total_bytes(),
            prefix_fingerprint: self.prefix_fingerprint.clone(),
            started_at_epoch_ms: self.started_at_epoch_ms,
            current_library_changed: false,
            history_slot_released: true,
            physical_space_reclaimed_unknown: true,
        }
    }
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct AuditReceipt {
    schema_version: u8,
    scope: String,
    cleanup_id: String,
    transaction_id: String,
    root_identity: (u64, u64, u32, u32),
    phase: Phase,
    archive_record_sha256: String,
    transaction_journal_sha256: String,
    snapshot_manifest_sha256: Option<String>,
    snapshot_file_count: usize,
    snapshot_byte_size: u64,
    removed_file_count: usize,
    removed_byte_size: u64,
    prefix_fingerprint: String,
    started_at_epoch_ms: u64,
    current_library_changed: bool,
    history_slot_released: bool,
    physical_space_reclaimed_unknown: bool,
}
struct IntentRead {
    intent: CleanupIntent,
    stamp: disk::Stamp,
    hash: String,
    witness: disk::Witness,
}
struct HeldTree {
    name: String,
    dirs: BTreeMap<String, disk::Dir>,
    allowed_names: BTreeMap<String, BTreeSet<String>>,
    files: Vec<String>,
    bytes: u64,
    fingerprint: String,
}
struct Observation {
    status: KnowledgeRestoreCleanupStatus,
    intent: Option<IntentRead>,
    material: Option<CleanupIntent>,
    fingerprint: String,
}
struct CleanupPending {
    created: Instant,
    expires: u64,
    action: KnowledgeRestoreCleanupAction,
    transaction_id: String,
    fingerprint: String,
}
impl CleanupPending {
    fn valid(&self) -> CommandResult<()> {
        let t = now()?;
        if self.created.elapsed() >= TTL
            || t >= self.expires
            || t < self.expires.saturating_sub(300000)
        {
            return Err(cleanup_invalid());
        }
        Ok(())
    }
}
#[derive(Default)]
pub struct KnowledgeRestoreCleanupStore {
    install: KnowledgeRestoreInstallStore,
    plans: Mutex<HashMap<String, CleanupPending>>,
}
impl KnowledgeRestoreCleanupStore {
    pub fn new(root: PathBuf) -> Self {
        Self {
            install: KnowledgeRestoreInstallStore::new(root),
            plans: Mutex::new(HashMap::new()),
        }
    }
    pub fn inspect(&self) -> CommandResult<KnowledgeRestoreCleanupStatus> {
        let lease = match self.install.unrestricted_lease() {
            Ok(l) => l,
            Err(_) => return Ok(KnowledgeRestoreCleanupStatus::empty("unavailable", true)),
        };
        match observe_cleanup(&lease) {
            Ok(o) => Ok(o.status),
            Err(_) => Ok(KnowledgeRestoreCleanupStatus::empty(
                "blocked",
                normal_library_access(&lease.file).is_err(),
            )),
        }
    }
    pub fn plan(
        &self,
        transaction_id: &str,
        action: KnowledgeRestoreCleanupAction,
    ) -> CommandResult<KnowledgeRestoreCleanupPlan> {
        if !disk::valid_id(transaction_id) {
            return Err(cleanup_invalid());
        }
        let lease = self.install.unrestricted_lease()?;
        let o = observe_cleanup(&lease)?;
        if o.status
            .selected
            .as_ref()
            .map(|e| e.transaction_id.as_str())
            != Some(transaction_id)
            || !match action {
                KnowledgeRestoreCleanupAction::Delete => o.status.can_delete,
                KnowledgeRestoreCleanupAction::Resume => o.status.can_resume,
            }
        {
            return Err(cleanup_invalid());
        }
        let time = now()?;
        let expires = time.checked_add(300000).ok_or_else(cleanup_invalid)?;
        let id = Uuid::new_v4().to_string();
        let mut plans = self.plans.lock().map_err(|_| cleanup_invalid())?;
        plans.retain(|_, p| p.valid().is_ok());
        if plans.len() >= 2 {
            return Err(cleanup_invalid());
        }
        plans.insert(
            id.clone(),
            CleanupPending {
                created: Instant::now(),
                expires,
                action,
                transaction_id: transaction_id.into(),
                fingerprint: o.fingerprint,
            },
        );
        Ok(KnowledgeRestoreCleanupPlan {
            schema_version: 1,
            scope: "knowledgeRestoreCleanupPlan",
            plan_id: id,
            action,
            deletes_snapshot: o
                .status
                .selected
                .as_ref()
                .is_some_and(|e| e.snapshot_present),
            status: o.status,
            requires_acknowledgement: true,
            irreversible: true,
            current_library_changed: false,
            deletes_history: true,
            preserves_audit_receipt: true,
            reclaims_history_slot: true,
            physical_space_reclaimed_unknown: true,
            checked_at_epoch_ms: time,
            expires_at_epoch_ms: expires,
        })
    }
    pub fn discard(&self, id: &str) -> CommandResult<()> {
        self.plans.lock().map_err(|_| cleanup_invalid())?.remove(id);
        Ok(())
    }
    pub fn execute(
        &self,
        id: &str,
        acknowledge_deletion: bool,
    ) -> CommandResult<KnowledgeRestoreCleanupReceipt> {
        self.execute_checked(id, acknowledge_deletion, |_| Ok(()), sync_dir)
    }
    fn execute_checked(
        &self,
        id: &str,
        ack: bool,
        mut hook: impl FnMut(u8) -> CommandResult<()>,
        mut release_sync: impl FnMut(&File) -> CommandResult<()>,
    ) -> CommandResult<KnowledgeRestoreCleanupReceipt> {
        let p = self
            .plans
            .lock()
            .map_err(|_| cleanup_invalid())?
            .remove(id)
            .ok_or_else(cleanup_invalid)?;
        if !ack {
            return Err(cleanup_invalid());
        }
        p.valid()?;
        let lease = self.install.unrestricted_lease()?;
        let o = observe_cleanup(&lease)?;
        if p.fingerprint != o.fingerprint
            || o.status
                .selected
                .as_ref()
                .map(|e| e.transaction_id.as_str())
                != Some(&p.transaction_id)
        {
            return Err(cleanup_invalid());
        }
        let i = o.material.ok_or_else(cleanup_invalid)?;
        if p.action == KnowledgeRestoreCleanupAction::Delete {
            if !o.status.can_delete || o.intent.is_some() {
                return Err(cleanup_invalid());
            }
            let bytes = serde_json::to_vec(&i).map_err(|_| cleanup_invalid())?;
            if bytes.len() > CLEAN_BYTES {
                return Err(cleanup_invalid());
            }
            write_new(&lease.file, CLEAN_INTENT, &bytes)?;
            sync_dir(&lease.file)?;
        } else if !o.status.can_resume || o.intent.is_none() {
            return Err(cleanup_invalid());
        }
        hook(0)?;
        p.valid()?;
        let intent = read_intent(&lease.file)?;
        if intent.intent != i {
            return Err(cleanup_invalid());
        }
        let selected = history_name(&i.archive.transaction_id);
        let quarantine = i.quarantine();
        let observed = observe_cleanup(&lease)?;
        if observed.material.as_ref() != Some(&i) {
            return Err(cleanup_invalid());
        }
        if disk::observe(&lease.file, &selected, true) != disk::Observation::Missing {
            guard(&lease, &intent)?;
            cross_rename(&lease.file, &selected, &lease.file, &quarantine)?;
            sync_dir(&lease.file)?;
        }
        // A visible resumed rename may not have been synced by the previous attempt.
        // Persist the quarantine name before permanently deleting any of its children.
        guard(&lease, &intent)?;
        sync_dir(&lease.file)?;
        hook(1)?;
        p.valid()?;
        let started = Instant::now();
        let mut tree = inspect_tree(&lease.file, &quarantine, &i, true, started)?;
        for path in tree.files.clone() {
            // Metadata goes last, after all snapshot data; no generic recursive deletion.
            if path == RECORD || path == JOURNAL {
                continue;
            }
            archive_bounded(started)?;
            p.valid()?;
            guard(&lease, &intent)?;
            verify_held(&lease.file, &tree, &i)?;
            delete_file(&lease.file, &tree, &path, &i, started, || {
                p.valid()?;
                guard(&lease, &intent)
            })?;
            hook(2)?;
        }
        hook(3)?;
        p.valid()?;
        guard(&lease, &intent)?;
        tree = inspect_tree(&lease.file, &quarantine, &i, true, Instant::now())?;
        for path in ["snapshot/archives", "snapshot/blobs", "snapshot"] {
            if let Some(dir) = tree.dirs.get(path) {
                p.valid()?;
                guard(&lease, &intent)?;
                verify_held(&lease.file, &tree, &i)?;
                if !disk::bounded_names(&dir.file, 1)?.is_empty() {
                    return Err(cleanup_invalid());
                }
                // Persist child deletions even when resume observed them already absent.
                sync_dir(&dir.file)?;
                guard(&lease, &intent)?;
                p.valid()?;
                let (parent, name) = split(path);
                let base = &tree.dirs.get(parent).ok_or_else(cleanup_invalid)?.file;
                unlink(base, name, true)?;
                sync_dir(base)?;
                tree.dirs.remove(path);
            }
        }
        hook(4)?;
        p.valid()?;
        tree = inspect_tree(&lease.file, &quarantine, &i, true, Instant::now())?;
        for path in [JOURNAL, RECORD] {
            if tree.files.iter().any(|f| f == path) {
                p.valid()?;
                guard(&lease, &intent)?;
                verify_held(&lease.file, &tree, &i)?;
                delete_file(&lease.file, &tree, path, &i, Instant::now(), || {
                    p.valid()?;
                    guard(&lease, &intent)
                })?;
            }
        }
        if let Some(dir) = tree.dirs.get("") {
            p.valid()?;
            guard(&lease, &intent)?;
            verify_held(&lease.file, &tree, &i)?;
            if !disk::bounded_names(&dir.file, 1)?.is_empty() {
                return Err(cleanup_invalid());
            }
            sync_dir(&dir.file)?;
            guard(&lease, &intent)?;
            p.valid()?;
            unlink(&lease.file, &quarantine, true)?;
            sync_dir(&lease.file)?;
        }
        hook(5)?;
        p.valid()?;
        let complete = observe_cleanup(&lease)?;
        if complete.material.as_ref() != Some(&i)
            || complete.status.remaining_file_count != Some(0)
            || !complete.status.history_slot_released
        {
            return Err(cleanup_invalid());
        }
        let audit = i.audit();
        let receipt = i.receipt_name();
        if disk::observe(&lease.file, &receipt, false) == disk::Observation::Missing {
            let bytes = serde_json::to_vec(&audit).map_err(|_| cleanup_invalid())?;
            if bytes.len() > AUDIT_BYTES {
                return Err(cleanup_invalid());
            }
            p.valid()?;
            guard(&lease, &intent)?;
            write_new(&lease.file, &receipt, &bytes)?;
        }
        release_sync(&lease.file)?;
        hook(6)?;
        p.valid()?;
        // Always persist the final root namespace, including previously visible resumed deletions/receipt.
        release_sync(&lease.file)?;
        let complete = observe_cleanup(&lease)?;
        if complete.status.state != "cleaned" || complete.material.as_ref() != Some(&i) {
            return Err(cleanup_invalid());
        }
        guard(&lease, &intent)?;
        p.valid()?;
        if !intent.witness.verify(&lease.file, CLEAN_INTENT) {
            return Err(cleanup_invalid());
        }
        unlink(&lease.file, CLEAN_INTENT, false)?;
        sync_dir(&lease.file)?;
        hook(7)?;
        lease.verify()?;
        if active(&lease.file)? != i.active
            || current_resources(&lease.file, i.root_mount_id)? != i.current_resources
            || active_transaction(&lease.file)? != i.active_transaction
            || histories(&lease.file, None, Instant::now())?.1 != i.prefix_fingerprint
            || read_audit(&lease.file, &receipt)?.0 != audit
        {
            return Err(cleanup_invalid());
        }
        Ok(KnowledgeRestoreCleanupReceipt {
            schema_version: 1,
            scope: "knowledgeRestoreCleanupReceipt",
            plan_id: id.into(),
            cleanup_id: i.cleanup_id.clone(),
            transaction_id: i.archive.transaction_id.clone(),
            action: p.action,
            state: "cleaned",
            selected: i.archive.entry(),
            removed_file_count: i.files.len(),
            removed_byte_size: i.total_bytes(),
            current_library_changed: false,
            history_slot_released: true,
            audit_receipt_persisted: true,
            physical_space_reclaimed_unknown: true,
            completed_at_epoch_ms: now()?,
        })
    }
}
fn mount_id(file: &File) -> CommandResult<u64> {
    let name = cstring("")?;
    let mut stat = std::mem::MaybeUninit::<libc::statx>::zeroed();
    if unsafe {
        libc::statx(
            file.as_raw_fd(),
            name.as_ptr(),
            libc::AT_EMPTY_PATH | libc::AT_SYMLINK_NOFOLLOW,
            libc::STATX_MNT_ID,
            stat.as_mut_ptr(),
        )
    } != 0
    {
        return Err(cleanup_invalid());
    }
    let stat = unsafe { stat.assume_init() };
    if stat.stx_mask & libc::STATX_MNT_ID == 0 {
        return Err(cleanup_invalid());
    }
    Ok(stat.stx_mnt_id)
}
fn split(path: &str) -> (&str, &str) {
    path.rsplit_once('/').unwrap_or(("", path))
}
fn unlink(base: &File, name: &str, dir: bool) -> CommandResult<()> {
    let name = cstring(name)?;
    if unsafe {
        libc::unlinkat(
            base.as_raw_fd(),
            name.as_ptr(),
            if dir { libc::AT_REMOVEDIR } else { 0 },
        )
    } != 0
    {
        return Err(cleanup_invalid());
    }
    Ok(())
}
fn guard(lease: &KnowledgeRootLease, read: &IntentRead) -> CommandResult<()> {
    lease.verify()?;
    if mount_id(&lease.file)? != read.intent.root_mount_id
        || !read.witness.verify(&lease.file, CLEAN_INTENT)
    {
        return Err(cleanup_invalid());
    }
    match &read.intent.active_transaction {
        Some(t) => {
            if disk::observe(&lease.file, JOURNAL, false)
                != disk::Observation::Found(t.stamp.clone())
            {
                return Err(cleanup_invalid());
            }
            let name = stage_name(&t.journal);
            match &t.snapshot {
                Some(s) => {
                    let dir = disk::directory(&lease.file, &name).map_err(|_| cleanup_invalid())?;
                    if disk::identity(&dir.before) != s.identity
                        || disk::observe(&dir.file, "blobs", true)
                            != disk::Observation::Found(s.blobs.clone())
                        || disk::observe(&dir.file, "archives", true)
                            != disk::Observation::Found(s.archives.clone())
                    {
                        return Err(cleanup_invalid());
                    }
                }
                None => {
                    if disk::observe(&lease.file, &name, true) != disk::Observation::Missing {
                        return Err(cleanup_invalid());
                    }
                }
            }
        }
        None => {
            if disk::observe(&lease.file, JOURNAL, false) != disk::Observation::Missing
                || !reserved(&lease.file)?.is_empty()
            {
                return Err(cleanup_invalid());
            }
        }
    }
    let a = &read.intent.active;
    if disk::observe(&lease.file, "knowledge-v1", true) != disk::Observation::Found(a.top.clone()) {
        return Err(cleanup_invalid());
    }
    let dir = disk::directory(&lease.file, "knowledge-v1").map_err(|_| cleanup_invalid())?;
    if disk::observe(&dir.file, "blobs", true) != disk::Observation::Found(a.blobs.clone())
        || disk::observe(&dir.file, "archives", true)
            != disk::Observation::Found(a.archives.clone())
        || disk::observe(&dir.file, "manifest.json", false)
            != disk::Observation::Found(a.manifest.clone())
    {
        return Err(cleanup_invalid());
    }
    Ok(())
}
fn verify_held(root: &File, tree: &HeldTree, i: &CleanupIntent) -> CommandResult<()> {
    let Some(top) = tree.dirs.get("") else {
        return Ok(());
    };
    if !matches!(disk::observe(root,&tree.name,true),disk::Observation::Found(s) if disk::identity(&s)==disk::identity(&top.before))
    {
        return Err(cleanup_invalid());
    }
    for (path, dir) in &tree.dirs {
        if !disk::bounded_names(&dir.file, MAX_RESOURCES + 4)?
            .is_subset(tree.allowed_names.get(path).ok_or_else(cleanup_invalid)?)
        {
            return Err(cleanup_invalid());
        }
        if disk::identity(&disk::file_stamp(&dir.file)?) != disk::identity(&i.directories[path])
            || mount_id(&dir.file)? != i.root_mount_id
        {
            return Err(cleanup_invalid());
        }
        if !path.is_empty()
            && !matches!(disk::observe(&top.file,path,true),disk::Observation::Found(s) if disk::identity(&s)==disk::identity(&dir.before))
        {
            return Err(cleanup_invalid());
        }
    }
    Ok(())
}
fn delete_file(
    root: &File,
    tree: &HeldTree,
    path: &str,
    i: &CleanupIntent,
    started: Instant,
    before_unlink: impl FnOnce() -> CommandResult<()>,
) -> CommandResult<()> {
    archive_bounded(started)?;
    let (parent, name) = split(path);
    let base = &tree.dirs.get(parent).ok_or_else(cleanup_invalid)?.file;
    let e = i.files.get(path).ok_or_else(cleanup_invalid)?;
    let read = disk::read(
        base,
        name,
        disk::byte_size(&e.stamp) as usize,
        Instant::now(),
    )
    .map_err(|_| cleanup_invalid())?;
    let held =
        workspace_backup::walk(base, Path::new(name), false).map_err(|_| cleanup_invalid())?;
    if read.witness.before != e.stamp
        || hash(&read.bytes) != e.sha256
        || mount_id(&held)? != i.root_mount_id
        || disk::file_stamp(&held)? != e.stamp
        || !read.witness.verify(base, name)
    {
        return Err(cleanup_invalid());
    }
    verify_held(root, tree, i)?;
    // Reading/hashing can outlast the plan or expose changed root/current evidence.
    // Consume no further data unless that capability is still valid at the unlink.
    before_unlink()?;
    if !read.witness.verify(base, name) {
        return Err(cleanup_invalid());
    }
    unlink(base, name, false)?;
    sync_dir(base)?;
    Ok(())
}
// Metadata only: reject any current-library mount or inode alias before authorizing
// irreversible deletion. Current resource contents are neither read nor rewritten.
fn current_resources(root: &File, mount: u64) -> CommandResult<BTreeMap<String, disk::Stamp>> {
    let top = disk::directory(root, "knowledge-v1").map_err(|_| cleanup_invalid())?;
    if mount_id(&top.file)? != mount {
        return Err(cleanup_invalid());
    }
    let mut out = BTreeMap::new();
    for name in ["blobs", "archives"] {
        let dir = disk::directory(&top.file, name).map_err(|_| cleanup_invalid())?;
        if mount_id(&dir.file)? != mount {
            return Err(cleanup_invalid());
        }
        for file in disk::bounded_names(&dir.file, 4097)? {
            if out.len() >= 4096 {
                return Err(cleanup_invalid());
            }
            let held = workspace_backup::walk(&dir.file, Path::new(&file), false)
                .map_err(|_| cleanup_invalid())?;
            use std::os::unix::fs::MetadataExt;
            let m = held.metadata().map_err(|_| cleanup_invalid())?;
            if !m.is_file()
                || m.mode() & 0o7777 != 0o600
                || m.uid() != unsafe { libc::geteuid() }
                || m.nlink() != 1
                || mount_id(&held)? != mount
            {
                return Err(cleanup_invalid());
            }
            out.insert(format!("{}/{}", name, file), disk::file_stamp(&held)?);
        }
        if !disk::verify_dir(&top.file, name, &dir) {
            return Err(cleanup_invalid());
        }
    }
    if !disk::verify_dir(root, "knowledge-v1", &top) {
        return Err(cleanup_invalid());
    }
    Ok(out)
}
fn valid_intent(i: &CleanupIntent, root: &File) -> CommandResult<()> {
    valid_record(&i.archive, disk::identity(&disk::file_stamp(root)?))?;
    if i.schema_version != 1
        || i.scope != "knowledgeRestoreCleanupIntent"
        || !disk::valid_id(&i.cleanup_id)
        || i.root_identity != disk::identity(&disk::file_stamp(root)?)
        || i.root_mount_id != mount_id(root)?
        || i.prefix_fingerprint != i.archive.existing_history_fingerprint
        || !valid_digest(&i.receipts_fingerprint)
        || i.started_at_epoch_ms == 0
        || i.started_at_epoch_ms > now()?
        || i.started_at_epoch_ms < i.archive.archived_at_epoch_ms
        || i.files.len() != i.archive.entry().snapshot_file_count + 2
        || i.files.len() > MAX_RESOURCES + 3
        || i.files.values().any(|f| !valid_digest(&f.sha256))
        || i.files
            .values()
            .map(|f| disk::byte_size(&f.stamp))
            .try_fold(0u64, |a, b| a.checked_add(b))
            .is_none_or(|b| b > MAX_CLEAN_BYTES)
        || disk::identity(&i.active.top)
            == disk::identity(i.directories.get("").ok_or_else(cleanup_invalid)?)
    {
        return Err(cleanup_invalid());
    }
    if active_transaction(root)? != i.active_transaction
        || current_resources(root, i.root_mount_id)? != i.current_resources
    {
        return Err(cleanup_invalid());
    }
    let current_dirs = [
        disk::identity(&i.active.top),
        disk::identity(&i.active.blobs),
        disk::identity(&i.active.archives),
    ];
    let current_files = i
        .current_resources
        .values()
        .map(disk::identity)
        .chain(std::iter::once(disk::identity(&i.active.manifest)))
        .collect::<BTreeSet<_>>();
    if i.directories
        .values()
        .any(|s| current_dirs.contains(&disk::identity(s)))
        || i.files
            .values()
            .any(|f| current_files.contains(&disk::identity(&f.stamp)))
    {
        return Err(cleanup_invalid());
    }
    if let Some(t) = &i.active_transaction {
        let mut retained_files = BTreeSet::from([disk::identity(&t.stamp)]);
        if let Some(snapshot) = &t.snapshot {
            retained_files.extend(snapshot.files.values().map(disk::identity));
            if i.directories.values().any(|d| {
                let id = disk::identity(d);
                id == snapshot.identity
                    || id == disk::identity(&snapshot.blobs)
                    || id == disk::identity(&snapshot.archives)
            }) {
                return Err(cleanup_invalid());
            }
        }
        if i.files
            .values()
            .any(|f| retained_files.contains(&disk::identity(&f.stamp)))
        {
            return Err(cleanup_invalid());
        }
    }
    // A bind-mounted retained file can have nlink == 1 while sharing the selected
    // file's inode. Never unlink the sole durable name behind another history/receipt.
    let selected_dirs = i
        .directories
        .values()
        .map(disk::identity)
        .collect::<BTreeSet<_>>();
    let selected_files = i
        .files
        .values()
        .map(|f| disk::identity(&f.stamp))
        .collect::<BTreeSet<_>>();
    let source = history_name(&i.archive.transaction_id);
    for name in names(root)? {
        if name.starts_with(HISTORY_PREFIX) && name != source {
            let dir = disk::directory(root, &name).map_err(|_| cleanup_invalid())?;
            let read = read_record(&dir.file, RECORD, i.root_identity)?;
            let journal = archived_journal(&dir.file, &read.record)?.0;
            if selected_dirs.contains(&disk::identity(&dir.before))
                || selected_files.contains(&disk::identity(&read.stamp))
                || selected_files.contains(&disk::identity(&journal))
            {
                return Err(cleanup_invalid());
            }
            if let Some(s) = &read.record.snapshot {
                if [
                    s.identity,
                    disk::identity(&s.blobs),
                    disk::identity(&s.archives),
                ]
                .iter()
                .any(|id| selected_dirs.contains(id))
                    || s.files
                        .values()
                        .any(|s| selected_files.contains(&disk::identity(s)))
                {
                    return Err(cleanup_invalid());
                }
            }
            if !disk::verify_dir(root, &name, &dir) {
                return Err(cleanup_invalid());
            }
        } else if name.starts_with(RECEIPT_PREFIX) && name != i.receipt_name() {
            let (_, stamp, _) = read_audit(root, &name)?;
            if selected_files.contains(&disk::identity(&stamp)) {
                return Err(cleanup_invalid());
            }
        }
    }
    let mut expected = BTreeMap::new();
    expected.insert(
        RECORD.to_string(),
        hash(&serde_json::to_vec(&i.archive).map_err(|_| cleanup_invalid())?),
    );
    expected.insert(JOURNAL.to_string(), i.archive.source_journal_sha256.clone());
    let mut dir_names = BTreeSet::from([String::new()]);
    if let Some(s) = &i.archive.snapshot {
        dir_names.extend(
            ["snapshot", "snapshot/blobs", "snapshot/archives"]
                .into_iter()
                .map(String::from),
        );
        if disk::identity(i.directories.get(SNAPSHOT).ok_or_else(cleanup_invalid)?) != s.identity
            || i.directories.get("snapshot/blobs") != Some(&s.blobs)
            || i.directories.get("snapshot/archives") != Some(&s.archives)
            || s.identity == disk::identity(&i.active.top)
        {
            return Err(cleanup_invalid());
        }
        for (path, stamp) in &s.files {
            let key = format!("snapshot/{}", path);
            if i.files.get(&key).is_none_or(|f| &f.stamp != stamp) {
                return Err(cleanup_invalid());
            }
            expected.insert(
                key,
                if path == "manifest.json" {
                    s.manifest_sha256.clone()
                } else {
                    split(path).1.to_string()
                },
            );
        }
    }
    if i.directories.keys().cloned().collect::<BTreeSet<_>>() != dir_names
        || i.files.keys().cloned().collect::<BTreeSet<_>>() != expected.keys().cloned().collect()
        || expected
            .iter()
            .any(|(p, sha)| i.files.get(p).is_none_or(|f| &f.sha256 != sha))
        || !disk::same_renamed_file(&i.archive.source_journal_stamp, &i.files[JOURNAL].stamp)
        || disk::byte_size(&i.files[JOURNAL].stamp) > JOURNAL_BYTES as u64
        || disk::byte_size(&i.files[RECORD].stamp) > RECORD_BYTES as u64
    {
        return Err(cleanup_invalid());
    }
    Ok(())
}
fn read_intent(root: &File) -> CommandResult<IntentRead> {
    let read = disk::read(root, CLEAN_INTENT, CLEAN_BYTES, Instant::now())
        .map_err(|_| cleanup_invalid())?;
    knowledge_package_check::parse_json(&read.bytes, Instant::now())?;
    let intent: CleanupIntent =
        serde_json::from_slice(&read.bytes).map_err(|_| cleanup_invalid())?;
    valid_intent(&intent, root)?;
    if !read.witness.verify(root, CLEAN_INTENT) {
        return Err(cleanup_invalid());
    }
    Ok(IntentRead {
        intent,
        stamp: read.witness.before.clone(),
        hash: hash(&read.bytes),
        witness: read.witness,
    })
}
fn read_audit(root: &File, name: &str) -> CommandResult<(AuditReceipt, disk::Stamp, String)> {
    let read =
        disk::read(root, name, AUDIT_BYTES, Instant::now()).map_err(|_| cleanup_invalid())?;
    knowledge_package_check::parse_json(&read.bytes, Instant::now())?;
    let a: AuditReceipt = serde_json::from_slice(&read.bytes).map_err(|_| cleanup_invalid())?;
    if a.schema_version != 1
        || a.scope != "knowledgeRestoreCleanupAudit"
        || !disk::valid_id(&a.cleanup_id)
        || !disk::valid_id(&a.transaction_id)
        || name != format!("{}{}.json", RECEIPT_PREFIX, a.cleanup_id)
        || a.root_identity != disk::identity(&disk::file_stamp(root)?)
        || !a.phase.terminal()
        || !valid_digest(&a.archive_record_sha256)
        || !valid_digest(&a.transaction_journal_sha256)
        || !valid_digest(&a.prefix_fingerprint)
        || a.snapshot_manifest_sha256
            .as_ref()
            .is_some_and(|s| !valid_digest(s))
        || (a.snapshot_manifest_sha256.is_some() != (a.snapshot_file_count > 0))
        || a.snapshot_file_count > MAX_RESOURCES + 1
        || a.snapshot_byte_size > (MAX_RESOURCE_BYTES + MANIFEST) as u64
        || (a.snapshot_file_count == 0) != (a.snapshot_byte_size == 0)
        || a.removed_file_count != a.snapshot_file_count + 2
        || a.removed_byte_size < a.snapshot_byte_size
        || a.removed_byte_size > MAX_CLEAN_BYTES
        || a.started_at_epoch_ms == 0
        || a.started_at_epoch_ms > now()?
        || a.current_library_changed
        || !a.history_slot_released
        || !a.physical_space_reclaimed_unknown
        || !read.witness.verify(root, name)
    {
        return Err(cleanup_invalid());
    }
    Ok((a, read.witness.before, hash(&read.bytes)))
}
fn receipts(root: &File, exclude: Option<&str>) -> CommandResult<(usize, String)> {
    let mut witnesses = BTreeMap::new();
    for name in names(root)? {
        if !name.starts_with(RECEIPT_PREFIX) || exclude == Some(name.as_str()) {
            continue;
        }
        if witnesses.len() >= RECEIPT_LIMIT {
            return Err(cleanup_invalid());
        }
        let (_, stamp, sha) = read_audit(root, &name)?;
        witnesses.insert(name, (stamp, sha));
    }
    Ok((
        witnesses.len(),
        hash(&serde_json::to_vec(&witnesses).map_err(|_| cleanup_invalid())?),
    ))
}
fn quarantine_names(root: &File) -> CommandResult<BTreeSet<String>> {
    Ok(names(root)?
        .into_iter()
        .filter(|n| n.starts_with(QUARANTINE_PREFIX) && !n.starts_with(RECEIPT_PREFIX))
        .collect())
}
fn inspect_tree(
    root: &File,
    name: &str,
    i: &CleanupIntent,
    partial: bool,
    started: Instant,
) -> CommandResult<HeldTree> {
    let mut dirs = BTreeMap::new();
    let mut allowed_names = BTreeMap::new();
    let mut files = vec![];
    let mut bytes = 0u64;
    let mut stamps = BTreeMap::new();
    if disk::observe(root, name, true) == disk::Observation::Missing {
        if !partial {
            return Err(cleanup_invalid());
        }
        return Ok(HeldTree {
            name: name.into(),
            dirs,
            allowed_names,
            files,
            bytes,
            fingerprint: hash(b"missing"),
        });
    }
    let top = disk::directory(root, name).map_err(|_| cleanup_invalid())?;
    if disk::identity(&top.before) != disk::identity(&i.directories[""])
        || mount_id(&top.file)? != i.root_mount_id
    {
        return Err(cleanup_invalid());
    }
    dirs.insert(String::new(), top);
    for path in i.directories.keys().filter(|p| !p.is_empty()) {
        let top = &dirs[""].file;
        if disk::observe(top, path, true) == disk::Observation::Missing {
            if partial {
                continue;
            } else {
                return Err(cleanup_invalid());
            }
        }
        let dir = disk::directory(top, path).map_err(|_| cleanup_invalid())?;
        if disk::identity(&dir.before) != disk::identity(&i.directories[path])
            || mount_id(&dir.file)? != i.root_mount_id
            || (!partial && dir.before != i.directories[path])
        {
            return Err(cleanup_invalid());
        }
        dirs.insert(path.clone(), dir);
    }
    for (path, dir) in &dirs {
        archive_bounded(started)?;
        let expected = i
            .files
            .keys()
            .chain(i.directories.keys())
            .filter_map(|p| {
                let (parent, name) = split(p);
                if parent == path && !name.is_empty() {
                    Some(name.to_string())
                } else {
                    None
                }
            })
            .collect::<BTreeSet<_>>();
        let actual = disk::bounded_names(&dir.file, MAX_RESOURCES + 4)?;
        if !actual.is_subset(&expected) || (!partial && actual != expected) {
            return Err(cleanup_invalid());
        }
        allowed_names.insert(path.clone(), expected);
        stamps.insert(format!("dir:{}", path), dir.before.clone());
    }
    for (path, e) in &i.files {
        let (parent, name) = split(path);
        let Some(dir) = dirs.get(parent) else {
            if partial {
                continue;
            }
            return Err(cleanup_invalid());
        };
        if disk::observe(&dir.file, name, false) == disk::Observation::Missing {
            if partial {
                continue;
            }
            return Err(cleanup_invalid());
        }
        let read = disk::read(
            &dir.file,
            name,
            disk::byte_size(&e.stamp) as usize,
            Instant::now(),
        )
        .map_err(|_| cleanup_invalid())?;
        let held = workspace_backup::walk(&dir.file, Path::new(name), false)
            .map_err(|_| cleanup_invalid())?;
        if read.witness.before != e.stamp
            || hash(&read.bytes) != e.sha256
            || mount_id(&held)? != i.root_mount_id
            || disk::file_stamp(&held)? != e.stamp
            || !read.witness.verify(&dir.file, name)
        {
            return Err(cleanup_invalid());
        }
        bytes = bytes
            .checked_add(disk::byte_size(&e.stamp))
            .ok_or_else(cleanup_invalid)?;
        files.push(path.clone());
        stamps.insert(path.clone(), e.stamp.clone());
        archive_bounded(started)?;
    }
    let tree = HeldTree {
        name: name.into(),
        dirs,
        allowed_names,
        files,
        bytes,
        fingerprint: hash(&serde_json::to_vec(&stamps).map_err(|_| cleanup_invalid())?),
    };
    verify_held(root, &tree, i)?;
    Ok(tree)
}
fn capture_selected(
    root: &File,
    id: &str,
    current: ActiveEvidence,
    prefix: String,
    receipt_fp: String,
) -> CommandResult<CleanupIntent> {
    let name = history_name(id);
    let dir = disk::directory(root, &name).map_err(|_| cleanup_invalid())?;
    let read = read_record(&dir.file, RECORD, disk::identity(&disk::file_stamp(root)?))?;
    if read.record.transaction_id != id
        || read.hash != hash(&serde_json::to_vec(&read.record).map_err(|_| cleanup_invalid())?)
    {
        return Err(cleanup_invalid());
    }
    let (journal_stamp, journal_hash) = archived_journal(&dir.file, &read.record)?;
    let mut files = BTreeMap::from([
        (
            RECORD.into(),
            ExpectedFile {
                stamp: read.stamp,
                sha256: read.hash,
            },
        ),
        (
            JOURNAL.into(),
            ExpectedFile {
                stamp: journal_stamp,
                sha256: journal_hash,
            },
        ),
    ]);
    let mut directories = BTreeMap::from([(String::new(), dir.before)]);
    if let Some(s) = &read.record.snapshot {
        let snapshot = disk::directory(&dir.file, SNAPSHOT).map_err(|_| cleanup_invalid())?;
        directories.insert(SNAPSHOT.into(), snapshot.before);
        directories.insert("snapshot/blobs".into(), s.blobs.clone());
        directories.insert("snapshot/archives".into(), s.archives.clone());
        for (p, stamp) in &s.files {
            files.insert(
                format!("snapshot/{}", p),
                ExpectedFile {
                    stamp: stamp.clone(),
                    sha256: if p == "manifest.json" {
                        s.manifest_sha256.clone()
                    } else {
                        split(p).1.into()
                    },
                },
            );
        }
    }
    let i = CleanupIntent {
        schema_version: 1,
        scope: "knowledgeRestoreCleanupIntent".into(),
        cleanup_id: Uuid::new_v4().to_string(),
        root_identity: disk::identity(&disk::file_stamp(root)?),
        root_mount_id: mount_id(root)?,
        archive: read.record,
        active: current,
        active_transaction: active_transaction(root)?,
        current_resources: current_resources(root, mount_id(root)?)?,
        files,
        directories,
        prefix_fingerprint: prefix,
        receipts_fingerprint: receipt_fp,
        started_at_epoch_ms: now()?,
    };
    valid_intent(&i, root)?;
    inspect_tree(root, &name, &i, false, Instant::now())?;
    Ok(i)
}
fn observe_cleanup(lease: &KnowledgeRootLease) -> CommandResult<Observation> {
    lease.verify()?;
    let started = Instant::now();
    let root = &lease.file;
    if disk::observe(root, INTENT, false) != disk::Observation::Missing {
        return Err(cleanup_invalid());
    }
    active_transaction(root)?;
    let present = disk::observe(root, CLEAN_INTENT, false) != disk::Observation::Missing;
    let mut intent = None;
    let (status, material, tree_fp, receipt_fp) = if present {
        let read = read_intent(root)?;
        let i = &read.intent;
        if active(root)? != i.active || quarantine_names(root)?.iter().any(|n| n != &i.quarantine())
        {
            return Err(cleanup_invalid());
        }
        let source = history_name(&i.archive.transaction_id);
        let source_present = disk::observe(root, &source, true) != disk::Observation::Missing;
        let quarantine_present =
            disk::observe(root, &i.quarantine(), true) != disk::Observation::Missing;
        if source_present && quarantine_present {
            return Err(cleanup_invalid());
        }
        let (prefix, prefix_fp) = histories(root, Some(&source), started)?;
        if prefix_fp != i.prefix_fingerprint || prefix.len() >= HISTORY_LIMIT {
            return Err(cleanup_invalid());
        }
        let receipt = i.receipt_name();
        let (count, fp) = receipts(root, Some(&receipt))?;
        if count >= RECEIPT_LIMIT || fp != i.receipts_fingerprint {
            return Err(cleanup_invalid());
        }
        let tree = if source_present {
            inspect_tree(root, &source, i, false, started)?
        } else {
            inspect_tree(root, &i.quarantine(), i, true, started)?
        };
        let receipt_present = disk::observe(root, &receipt, false) != disk::Observation::Missing;
        if receipt_present
            && (source_present || quarantine_present || read_audit(root, &receipt)?.0 != i.audit())
        {
            return Err(cleanup_invalid());
        }
        let state = if receipt_present {
            "cleaned"
        } else {
            "cleaning"
        };
        let status = KnowledgeRestoreCleanupStatus {
            schema_version: 1,
            scope: "knowledgeRestoreCleanupStatus",
            state,
            cleanup_id: Some(i.cleanup_id.clone()),
            selected: Some(i.archive.entry()),
            history_count: Some(prefix.len() + usize::from(source_present)),
            history_limit: HISTORY_LIMIT,
            receipt_count: Some(count + usize::from(receipt_present)),
            receipt_limit: RECEIPT_LIMIT,
            current_manifest_sha256: Some(i.active.manifest_sha256.clone()),
            remaining_file_count: Some(tree.files.len()),
            remaining_byte_size: Some(tree.bytes),
            can_delete: false,
            can_resume: true,
            history_slot_released: !source_present,
            library_access_blocked: true,
            filesystem_writes: false,
        };
        let mat = i.clone();
        intent = Some(read);
        (status, Some(mat), tree.fingerprint, fp)
    } else {
        if !quarantine_names(root)?.is_empty() {
            return Err(cleanup_invalid());
        }
        let (history, all_fp) = histories(root, None, started)?;
        let (count, fp) = receipts(root, None)?;
        if let Some(last) = history.last() {
            let current = active(root)?;
            let prefix = histories(root, Some(&history_name(&last.transaction_id)), started)?.1;
            let i = capture_selected(root, &last.transaction_id, current, prefix, fp.clone())?;
            let status = KnowledgeRestoreCleanupStatus {
                schema_version: 1,
                scope: "knowledgeRestoreCleanupStatus",
                state: "eligible",
                cleanup_id: None,
                selected: Some(i.archive.entry()),
                history_count: Some(history.len()),
                history_limit: HISTORY_LIMIT,
                receipt_count: Some(count),
                receipt_limit: RECEIPT_LIMIT,
                current_manifest_sha256: Some(i.active.manifest_sha256.clone()),
                remaining_file_count: Some(i.files.len()),
                remaining_byte_size: Some(i.total_bytes()),
                can_delete: count < RECEIPT_LIMIT,
                can_resume: false,
                history_slot_released: false,
                library_access_blocked: false,
                filesystem_writes: false,
            };
            (status, Some(i), all_fp, fp)
        } else {
            let mut status = KnowledgeRestoreCleanupStatus::empty("none", false);
            status.history_count = Some(0);
            status.receipt_count = Some(count);
            (status, None, all_fp, fp)
        }
    };
    archive_bounded(started)?;
    if let Some(i) = &material {
        if active(root)? != i.active
            || current_resources(root, i.root_mount_id)? != i.current_resources
            || active_transaction(root)? != i.active_transaction
            || histories(
                root,
                Some(&history_name(&i.archive.transaction_id)),
                started,
            )?
            .1 != i.prefix_fingerprint
        {
            return Err(cleanup_invalid());
        }
    }
    let exclude = material
        .as_ref()
        .filter(|_| present)
        .map(|i| i.receipt_name());
    if receipts(root, exclude.as_deref())?.1 != receipt_fp {
        return Err(cleanup_invalid());
    }
    if let Some(read) = &intent {
        if !read.witness.verify(root, CLEAN_INTENT) {
            return Err(cleanup_invalid());
        }
    } else {
        access(root)?;
    }
    lease.verify()?;
    let fp=hash(&serde_json::to_vec(&serde_json::json!({"status":status,"material":material.as_ref().map(|i|{let mut i=i.clone();if !present{i.cleanup_id.clear();i.started_at_epoch_ms=0;}i}),
        "tree":tree_fp,"receipts":receipt_fp,"intent":intent.as_ref().map(|r|(&r.stamp,&r.hash))})).map_err(|_|cleanup_invalid())?);
    Ok(Observation {
        status,
        intent,
        material,
        fingerprint: fp,
    })
}
#[cfg(test)]
#[path = "knowledge_restore_cleanup_tests.rs"]
mod tests;
