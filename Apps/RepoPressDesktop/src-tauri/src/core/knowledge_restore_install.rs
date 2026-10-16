//! Durable, explicit one-transaction install and recovery. No automatic repair or cleanup.
use super::*;
use crate::core::knowledge_restore_gate::{blocked, KnowledgeRootLease};
use std::{
    ffi::CString,
    fs::{File, OpenOptions},
    io::Write,
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::fs::OpenOptionsExt,
    },
};

fn invalid() -> CommandError {
    CommandError::new("knowledge_restore_invalid","Restore evidence, consent or transaction could not be confirmed. Files may have been written; inspect the persistent restore state before retrying.")
}
const JOURNAL: &str = "knowledge-restore-intent.json";
const STAGE_PREFIX: &str = ".repopress-knowledge-restore-";
const TEMP_PREFIX: &str = ".repopress-knowledge-journal-";
const JOURNAL_BYTES: usize = 1024 * 1024;
const MAX_RESOURCES: usize = 2048;
const MAX_RESOURCE_BYTES: usize = 64 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum KnowledgeRestoreRecoveryAction {
    Finalize,
    Rollback,
    Cancel,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
enum Phase {
    Preparing,
    Intent,
    Committed,
    RolledBack,
    Cancelled,
}
impl Phase {
    fn name(self) -> &'static str {
        match self {
            Self::Preparing => "preparing",
            Self::Intent => "intent",
            Self::Committed => "committed",
            Self::RolledBack => "rolledBack",
            Self::Cancelled => "cancelled",
        }
    }
    fn terminal(self) -> bool {
        matches!(self, Self::Committed | Self::RolledBack | Self::Cancelled)
    }
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeRestoreInstallPlan {
    schema_version: u8,
    scope: &'static str,
    pub plan_id: String,
    projection: KnowledgeMergeProjectionPlan,
    requires_acknowledgement: bool,
    writes_current_library: bool,
    preserves_rollback_snapshot: bool,
    imported_permissions_disabled: bool,
    current_only_preserved: bool,
    completed_operations_excluded: bool,
    transaction_limit: u8,
    checked_at_epoch_ms: u64,
    expires_at_epoch_ms: u64,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeRestoreDiagnosis {
    schema_version: u8,
    scope: &'static str,
    state: &'static str,
    transaction_id: Option<String>,
    phase: Option<&'static str>,
    previous_manifest_sha256: Option<String>,
    projected_manifest_sha256: Option<String>,
    can_finalize: bool,
    can_rollback: bool,
    can_cancel: bool,
    library_access_blocked: bool,
    snapshot_retained: bool,
    filesystem_writes: bool,
}
impl KnowledgeRestoreDiagnosis {
    fn empty(state: &'static str, blocked: bool) -> Self {
        Self {
            schema_version: 1,
            scope: "knowledgeRestoreDiagnosis",
            state,
            transaction_id: None,
            phase: None,
            previous_manifest_sha256: None,
            projected_manifest_sha256: None,
            can_finalize: false,
            can_rollback: false,
            can_cancel: false,
            library_access_blocked: blocked,
            snapshot_retained: false,
            filesystem_writes: false,
        }
    }
    fn allows(&self, action: KnowledgeRestoreRecoveryAction) -> bool {
        match action {
            KnowledgeRestoreRecoveryAction::Finalize => self.can_finalize,
            KnowledgeRestoreRecoveryAction::Rollback => self.can_rollback,
            KnowledgeRestoreRecoveryAction::Cancel => self.can_cancel,
        }
    }
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeRestoreRecoveryPlan {
    schema_version: u8,
    scope: &'static str,
    pub plan_id: String,
    transaction_id: String,
    action: KnowledgeRestoreRecoveryAction,
    diagnosis: KnowledgeRestoreDiagnosis,
    requires_acknowledgement: bool,
    preserves_snapshot: bool,
    checked_at_epoch_ms: u64,
    expires_at_epoch_ms: u64,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeRestoreReceipt {
    schema_version: u8,
    scope: &'static str,
    plan_id: String,
    transaction_id: String,
    state: &'static str,
    action: &'static str,
    previous_manifest_sha256: String,
    projected_manifest_sha256: String,
    imported_permissions_disabled: bool,
    snapshot_retained: bool,
    journal_persisted: bool,
    library_access_blocked: bool,
    completed_at_epoch_ms: u64,
}
#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct TreeEvidence {
    // renameat2 changes only the exchanged top directory's ctime; bind its inode instead.
    identity: (u64, u64, u32, u32),
    blobs: disk::Stamp,
    archives: disk::Stamp,
    files: BTreeMap<String, disk::Stamp>,
    manifest_sha256: String,
}
#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Journal {
    schema_version: u8,
    scope: String,
    transaction_id: String,
    phase: Phase,
    root_identity: (u64, u64, u32, u32),
    previous: TreeEvidence,
    projected: Option<TreeEvidence>,
    projected_manifest_sha256: String,
}
struct JournalRead {
    journal: Journal,
    stamp: disk::Stamp,
    hash: String,
}
struct RecoveryObservation {
    diagnosis: KnowledgeRestoreDiagnosis,
    journal: Option<JournalRead>,
    fingerprint: String,
}
enum Pending {
    Install {
        stored: Box<StoredProjection>,
        previous: TreeEvidence,
    },
    Recovery {
        created: Instant,
        expires: u64,
        transaction_id: String,
        action: KnowledgeRestoreRecoveryAction,
        fingerprint: String,
    },
}
impl Pending {
    fn valid(&self) -> CommandResult<()> {
        let (created, expires) = match self {
            Self::Install { stored, .. } => {
                (stored.observation.created, stored.observation.expires)
            }
            Self::Recovery {
                created, expires, ..
            } => (*created, *expires),
        };
        let time = now()?;
        if created.elapsed() >= TTL || time >= expires || time < expires.saturating_sub(300000) {
            return Err(invalid());
        }
        Ok(())
    }
}
#[derive(Default)]
pub struct KnowledgeRestoreInstallStore {
    root: Option<PathBuf>,
    check: KnowledgeMergeProjectionStore,
    plans: Mutex<HashMap<String, Pending>>,
}
impl KnowledgeRestoreInstallStore {
    pub fn new(root: PathBuf) -> Self {
        Self {
            check: KnowledgeMergeProjectionStore::new(root.clone()),
            root: Some(root),
            plans: Mutex::new(HashMap::new()),
        }
    }
    fn unrestricted_lease(&self) -> CommandResult<KnowledgeRootLease> {
        let root = self.check.check.check.root.as_ref().ok_or_else(blocked)?;
        root.verify().map_err(|_| blocked())?;
        let lease = KnowledgeRootLease::acquire(self.root.as_deref().ok_or_else(blocked)?)?;
        if disk::identity(&disk::file_stamp(&lease.file)?) != root.identity {
            return Err(blocked());
        }
        root.verify().map_err(|_| blocked())?;
        Ok(lease)
    }
    fn lease(&self) -> CommandResult<KnowledgeRootLease> {
        let lease = self.unrestricted_lease()?;
        archive::access(&lease.file)?;
        Ok(lease)
    }
    fn insert(&self, id: String, pending: Pending) -> CommandResult<()> {
        let mut plans = self.plans.lock().map_err(|_| invalid())?;
        plans.retain(|_, p| p.valid().is_ok());
        if plans.len() >= 2 {
            return Err(invalid());
        }
        plans.insert(id, pending);
        Ok(())
    }
    fn consume(&self, id: &str, ack: bool) -> CommandResult<Pending> {
        let p = self
            .plans
            .lock()
            .map_err(|_| invalid())?
            .remove(id)
            .ok_or_else(invalid)?;
        if !ack {
            return Err(invalid());
        }
        p.valid()?;
        Ok(p)
    }
    pub fn discard(&self, id: &str) -> CommandResult<()> {
        self.plans.lock().map_err(|_| invalid())?.remove(id);
        Ok(())
    }
    pub fn plan(
        &self,
        path: &Path,
        strategy: KnowledgeRestoreStrategy,
    ) -> CommandResult<KnowledgeRestoreInstallPlan> {
        let lease = self.lease()?;
        empty_slot(&lease.file)?;
        let (projection, stored) = self.check.capture(path, strategy, |_| {})?;
        if stored.projection.state != "validated" {
            return Err(invalid());
        }
        let previous = audit_tree(&lease.file, "knowledge-v1", 1024, RESOURCE_BYTES)?;
        lease.verify()?;
        let id = Uuid::new_v4().to_string();
        let checked = projection.checked_at_epoch_ms;
        let expires = projection.expires_at_epoch_ms;
        self.insert(
            id.clone(),
            Pending::Install {
                stored: Box::new(stored),
                previous,
            },
        )?;
        Ok(KnowledgeRestoreInstallPlan {
            schema_version: 1,
            scope: "knowledgeRestoreInstall",
            plan_id: id,
            projection,
            requires_acknowledgement: true,
            writes_current_library: true,
            preserves_rollback_snapshot: true,
            imported_permissions_disabled: true,
            current_only_preserved: true,
            completed_operations_excluded: true,
            transaction_limit: 1,
            checked_at_epoch_ms: checked,
            expires_at_epoch_ms: expires,
        })
    }
    pub fn execute(&self, id: &str, ack: bool) -> CommandResult<KnowledgeRestoreReceipt> {
        self.execute_checked(id, ack, |_| Ok(()))
            .map_err(|_| invalid())
    }
    fn execute_checked(
        &self,
        id: &str,
        ack: bool,
        mut hook: impl FnMut(u8) -> CommandResult<()>,
    ) -> CommandResult<KnowledgeRestoreReceipt> {
        let pending = self.consume(id, ack)?;
        let Pending::Install { stored, previous } = &pending else {
            return Err(invalid());
        };
        let lease = self.lease()?;
        empty_slot(&lease.file)?;
        let (_, observation, _, summary, material) = self.check.check.check.capture_extended(
            &stored.observation.path,
            |_| {},
            true,
            Some(stored.strategy),
            true,
        )?;
        let summary = summary.ok_or_else(invalid)?;
        if summary.state != "validated"
            || observation.fingerprint != stored.observation.fingerprint
            || summary.manifest_sha256 != stored.projection.manifest_sha256
            || audit_tree(&lease.file, "knowledge-v1", 1024, RESOURCE_BYTES)? != *previous
        {
            return Err(invalid());
        }
        let material = material.ok_or_else(invalid)?;
        pending.valid()?;
        lease.verify()?;
        let mut journal = Journal {
            schema_version: 1,
            scope: "knowledgeRestoreIntent".into(),
            transaction_id: Uuid::new_v4().to_string(),
            phase: Phase::Preparing,
            root_identity: disk::identity(&disk::file_stamp(&lease.file)?),
            previous: previous.clone(),
            projected: None,
            projected_manifest_sha256: summary.manifest_sha256.ok_or_else(invalid)?,
        };
        write_journal(&lease, &journal, None)?;
        hook(0)?;
        let stage = stage_name(&journal);
        stage_tree(&lease, &stage, &material)?;
        let projected = audit_tree(&lease.file, &stage, MAX_RESOURCES, MAX_RESOURCE_BYTES)?;
        if projected.manifest_sha256 != journal.projected_manifest_sha256 {
            return Err(invalid());
        }
        journal.projected = Some(projected.clone());
        journal.phase = Phase::Intent;
        let prior = read_journal(&lease.file)?.ok_or_else(invalid)?;
        write_journal(&lease, &journal, Some(&prior))?;
        hook(1)?;
        let (_, fresh) = self
            .check
            .capture(&stored.observation.path, stored.strategy, |_| {})?;
        if fresh.observation.fingerprint != stored.observation.fingerprint
            || audit_tree(&lease.file, "knowledge-v1", 1024, RESOURCE_BYTES)? != *previous
            || audit_tree(&lease.file, &stage, MAX_RESOURCES, MAX_RESOURCE_BYTES)? != projected
        {
            return Err(invalid());
        }
        pending.valid()?;
        lease.verify()?;
        exchange(&lease.file, "knowledge-v1", &stage)?;
        sync_dir(&lease.file)?;
        hook(2)?;
        if audit_tree(
            &lease.file,
            "knowledge-v1",
            MAX_RESOURCES,
            MAX_RESOURCE_BYTES,
        )? != projected
            || audit_tree(&lease.file, &stage, 1024, RESOURCE_BYTES)? != *previous
        {
            return Err(invalid());
        }
        pending.valid()?;
        journal.phase = Phase::Committed;
        let prior = read_journal(&lease.file)?.ok_or_else(invalid)?;
        write_journal(&lease, &journal, Some(&prior))?;
        hook(3)?;
        lease.verify()?;
        pending.valid()?;
        Ok(receipt(id, &journal, "install", true, now()?))
    }
    pub fn inspect(&self) -> CommandResult<KnowledgeRestoreDiagnosis> {
        let lease = match self.lease() {
            Ok(l) => l,
            Err(_) => return Ok(KnowledgeRestoreDiagnosis::empty("unavailable", true)),
        };
        match observe(&lease) {
            Ok(o) => Ok(o.diagnosis),
            Err(_) => Ok(KnowledgeRestoreDiagnosis::empty("invalid", true)),
        }
    }
    pub fn plan_recovery(
        &self,
        transaction_id: &str,
        action: KnowledgeRestoreRecoveryAction,
    ) -> CommandResult<KnowledgeRestoreRecoveryPlan> {
        let lease = self.lease()?;
        let observed = observe(&lease)?;
        if observed.diagnosis.transaction_id.as_deref() != Some(transaction_id)
            || !observed.diagnosis.allows(action)
        {
            return Err(invalid());
        }
        let checked = now()?;
        let expires = checked.checked_add(300000).ok_or_else(invalid)?;
        let id = Uuid::new_v4().to_string();
        self.insert(
            id.clone(),
            Pending::Recovery {
                created: Instant::now(),
                expires,
                transaction_id: transaction_id.into(),
                action,
                fingerprint: observed.fingerprint,
            },
        )?;
        Ok(KnowledgeRestoreRecoveryPlan {
            schema_version: 1,
            scope: "knowledgeRestoreRecovery",
            plan_id: id,
            transaction_id: transaction_id.into(),
            action,
            diagnosis: observed.diagnosis,
            requires_acknowledgement: true,
            preserves_snapshot: true,
            checked_at_epoch_ms: checked,
            expires_at_epoch_ms: expires,
        })
    }
    pub fn execute_recovery(&self, id: &str, ack: bool) -> CommandResult<KnowledgeRestoreReceipt> {
        let pending = self.consume(id, ack)?;
        let Pending::Recovery {
            transaction_id,
            action,
            fingerprint,
            ..
        } = &pending
        else {
            return Err(invalid());
        };
        let lease = self.lease()?;
        let fresh = observe(&lease)?;
        if fresh.fingerprint != *fingerprint
            || fresh.diagnosis.transaction_id.as_deref() != Some(transaction_id)
            || !fresh.diagnosis.allows(*action)
        {
            return Err(invalid());
        }
        let mut prior = fresh.journal.ok_or_else(invalid)?;
        let mut journal = prior.journal.clone();
        pending.valid()?;
        lease.verify()?;
        let action_name = match action {
            KnowledgeRestoreRecoveryAction::Finalize => {
                sync_dir(&lease.file)?;
                journal.phase = Phase::Committed;
                "finalize"
            }
            KnowledgeRestoreRecoveryAction::Rollback => {
                // A crash after the reverse exchange must remain diagnosable as an intent.
                if journal.phase == Phase::Committed {
                    journal.phase = Phase::Intent;
                    write_journal(&lease, &journal, Some(&prior))?;
                    prior = read_journal(&lease.file)?.ok_or_else(invalid)?;
                }
                exchange(&lease.file, "knowledge-v1", &stage_name(&journal))?;
                sync_dir(&lease.file)?;
                if audit_tree(
                    &lease.file,
                    "knowledge-v1",
                    MAX_RESOURCES,
                    MAX_RESOURCE_BYTES,
                )? != journal.previous
                    || Some(audit_tree(
                        &lease.file,
                        &stage_name(&journal),
                        MAX_RESOURCES,
                        MAX_RESOURCE_BYTES,
                    )?) != journal.projected
                {
                    return Err(invalid());
                }
                journal.phase = Phase::RolledBack;
                "rollback"
            }
            KnowledgeRestoreRecoveryAction::Cancel => {
                journal.phase = Phase::Cancelled;
                "cancel"
            }
        };
        write_journal(&lease, &journal, Some(&prior))?;
        lease.verify()?;
        pending.valid()?;
        Ok(receipt(
            id,
            &journal,
            action_name,
            fresh.diagnosis.snapshot_retained,
            now()?,
        ))
    }
}
fn receipt(
    id: &str,
    journal: &Journal,
    action: &'static str,
    snapshot: bool,
    time: u64,
) -> KnowledgeRestoreReceipt {
    KnowledgeRestoreReceipt {
        schema_version: 1,
        scope: "knowledgeRestoreReceipt",
        plan_id: id.into(),
        transaction_id: journal.transaction_id.clone(),
        state: journal.phase.name(),
        action,
        previous_manifest_sha256: journal.previous.manifest_sha256.clone(),
        projected_manifest_sha256: journal.projected_manifest_sha256.clone(),
        imported_permissions_disabled: true,
        snapshot_retained: snapshot,
        journal_persisted: true,
        library_access_blocked: false,
        completed_at_epoch_ms: time,
    }
}
fn valid_digest(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn stage_name(j: &Journal) -> String {
    format!("{}{}", STAGE_PREFIX, j.transaction_id)
}
fn reserved(root: &File) -> CommandResult<BTreeSet<String>> {
    let mut names = BTreeSet::new();
    // App root can contain other application data. Bound traversal independently.
    for (i, e) in std::fs::read_dir(format!("/proc/self/fd/{}", root.as_raw_fd()))
        .map_err(|_| invalid())?
        .enumerate()
    {
        if i >= 4096 {
            return Err(invalid());
        }
        let name = e
            .map_err(|_| invalid())?
            .file_name()
            .into_string()
            .map_err(|_| invalid())?;
        if name.starts_with(STAGE_PREFIX) || name.starts_with(TEMP_PREFIX) {
            names.insert(name);
        }
    }
    Ok(names)
}
fn empty_slot(root: &File) -> CommandResult<()> {
    archive::access(root)?;
    if disk::observe(root, JOURNAL, false) != disk::Observation::Missing
        || !reserved(root)?.is_empty()
    {
        return Err(blocked());
    }
    Ok(())
}
fn valid_evidence(e: &TreeEvidence) -> bool {
    e.files.len() <= MAX_RESOURCES + 1
        && e.files.contains_key("manifest.json")
        && valid_digest(&e.manifest_sha256)
        && e.files.keys().all(|p| {
            p == "manifest.json"
                || p.strip_prefix("blobs/")
                    .or_else(|| p.strip_prefix("archives/"))
                    .is_some_and(valid_digest)
        })
}
fn read_journal(root: &File) -> CommandResult<Option<JournalRead>> {
    if disk::observe(root, JOURNAL, false) == disk::Observation::Missing {
        return Ok(None);
    }
    let read = disk::read(root, JOURNAL, JOURNAL_BYTES, Instant::now()).map_err(|_| invalid())?;
    // Reject duplicate keys/deep JSON before typed deserialization.
    knowledge_package_check::parse_json(&read.bytes, Instant::now())?;
    let j: Journal = serde_json::from_slice(&read.bytes).map_err(|_| invalid())?;
    if j.schema_version != 1
        || j.scope != "knowledgeRestoreIntent"
        || !disk::valid_id(&j.transaction_id)
        || j.root_identity != disk::identity(&disk::file_stamp(root)?)
        || !valid_evidence(&j.previous)
        || !valid_digest(&j.projected_manifest_sha256)
        || j.projected
            .as_ref()
            .is_some_and(|e| !valid_evidence(e) || e.manifest_sha256 != j.projected_manifest_sha256)
        || (j.projected.is_none() && !matches!(j.phase, Phase::Preparing | Phase::Cancelled))
        || (j.phase == Phase::Preparing && j.projected.is_some())
    {
        return Err(invalid());
    }
    if !read.witness.verify(root, JOURNAL) {
        return Err(invalid());
    }
    Ok(Some(JournalRead {
        journal: j,
        stamp: read.witness.before,
        hash: hash(&read.bytes),
    }))
}
fn audit_tree(
    root: &File,
    name: &str,
    max_files: usize,
    max_bytes: usize,
) -> CommandResult<TreeEvidence> {
    let started = Instant::now();
    let dir = disk::directory(root, name).map_err(|_| invalid())?;
    let expected = ["archives", "blobs", "manifest.json"]
        .into_iter()
        .map(String::from)
        .collect();
    if disk::bounded_names(&dir.file, 4)? != expected {
        return Err(invalid());
    }
    let blobs = disk::directory(&dir.file, "blobs").map_err(|_| invalid())?;
    let archives = disk::directory(&dir.file, "archives").map_err(|_| invalid())?;
    let raw = disk::read(&dir.file, "manifest.json", MANIFEST, started).map_err(|_| invalid())?;
    knowledge_package_check::parse_json(&raw.bytes, started)?;
    manifest::validate_completed_operations(&raw.bytes)?;
    let refs = manifest::project(&raw.bytes)?;
    if refs.files.len() > max_files
        || refs.missing_archives + refs.truncated_archives + refs.unknown_archives > 0
    {
        return Err(invalid());
    }
    let mut files = BTreeMap::new();
    files.insert("manifest.json".into(), raw.witness.before.clone());
    let mut bodies = BTreeSet::new();
    let mut archive_names = BTreeSet::new();
    let mut witnesses = Vec::new();
    let mut bytes = 0usize;
    for r in &refs.files {
        let (kind, base, names) = if r.kind == "body" {
            ("blobs", &blobs.file, &mut bodies)
        } else {
            ("archives", &archives.file, &mut archive_names)
        };
        if r.byte_size > max_bytes.saturating_sub(bytes) as u64 {
            return Err(invalid());
        }
        let read =
            disk::read(base, &r.digest, r.byte_size as usize, started).map_err(|_| invalid())?;
        if !manifest::content_matches(r, &read.bytes) {
            return Err(invalid());
        }
        bytes += read.bytes.len();
        names.insert(r.digest.clone());
        files.insert(
            format!("{}/{}", kind, r.digest),
            read.witness.before.clone(),
        );
        witnesses.push((kind, r.digest.clone(), read.witness));
    }
    if disk::bounded_names(&blobs.file, max_files + 1)? != bodies
        || disk::bounded_names(&archives.file, max_files + 1)? != archive_names
        || !disk::verify_dir(&dir.file, "blobs", &blobs)
        || !disk::verify_dir(&dir.file, "archives", &archives)
        || !raw.witness.verify(&dir.file, "manifest.json")
        || !disk::verify_dir(root, name, &dir)
    {
        return Err(invalid());
    }
    for (kind, name, w) in witnesses {
        if !w.verify(
            if kind == "blobs" {
                &blobs.file
            } else {
                &archives.file
            },
            &name,
        ) {
            return Err(invalid());
        }
    }
    bounded(started)?;
    Ok(TreeEvidence {
        identity: disk::identity(&dir.before),
        blobs: blobs.before,
        archives: archives.before,
        files,
        manifest_sha256: hash(&raw.bytes),
    })
}
fn partial_fingerprint(root: &File, name: &str) -> CommandResult<Value> {
    if disk::observe(root, name, true) == disk::Observation::Missing {
        return Ok(Value::Null);
    }
    let dir = disk::directory(root, name).map_err(|_| invalid())?;
    let mut stamps = BTreeMap::new();
    stamps.insert(".".to_string(), dir.before.clone());
    for n in disk::bounded_names(&dir.file, 4)? {
        if n == "blobs" || n == "archives" {
            let child = disk::directory(&dir.file, &n).map_err(|_| invalid())?;
            stamps.insert(n.clone(), child.before.clone());
            for f in disk::bounded_names(&child.file, MAX_RESOURCES + 1)? {
                if !valid_digest(&f) {
                    return Err(invalid());
                }
                // O_PATH only: reject special nodes before any possible content open.
                let held = workspace_backup::walk(&child.file, Path::new(&f), false)
                    .map_err(|_| invalid())?;
                let m = held.metadata().map_err(|_| invalid())?;
                use std::os::unix::fs::MetadataExt;
                if !m.is_file()
                    || m.nlink() != 1
                    || m.mode() & 0o7777 != 0o600
                    || m.uid() != unsafe { libc::geteuid() }
                    || m.len() > MAX_RESOURCE_BYTES as u64
                {
                    return Err(invalid());
                }
                stamps.insert(format!("{}/{}", n, f), disk::file_stamp(&held)?);
            }
            if !disk::verify_dir(&dir.file, &n, &child) {
                return Err(invalid());
            }
        } else if n == "manifest.json" {
            let r = disk::read(&dir.file, &n, MANIFEST, Instant::now()).map_err(|_| invalid())?;
            stamps.insert(n, r.witness.before);
        } else {
            return Err(invalid());
        }
    }
    if !disk::verify_dir(root, name, &dir) {
        return Err(invalid());
    }
    serde_json::to_value(stamps).map_err(|_| invalid())
}
fn observe(lease: &KnowledgeRootLease) -> CommandResult<RecoveryObservation> {
    let Some(jr) = read_journal(&lease.file)? else {
        empty_slot(&lease.file)?;
        lease.verify()?;
        return Ok(RecoveryObservation {
            diagnosis: KnowledgeRestoreDiagnosis::empty("none", false),
            journal: None,
            fingerprint: String::new(),
        });
    };
    let j = &jr.journal;
    let stage = stage_name(j);
    let active = audit_tree(
        &lease.file,
        "knowledge-v1",
        MAX_RESOURCES,
        MAX_RESOURCE_BYTES,
    )
    .ok();
    let staged = audit_tree(&lease.file, &stage, MAX_RESOURCES, MAX_RESOURCE_BYTES).ok();
    let extras = reserved(&lease.file)?
        .into_iter()
        .filter(|n| n != &stage)
        .collect::<BTreeSet<_>>();
    let old_active = active.as_ref() == Some(&j.previous);
    let new_active = j.projected.is_some() && active.as_ref() == j.projected.as_ref();
    let old_stage = staged.as_ref() == Some(&j.previous);
    let new_stage = j.projected.is_some() && staged.as_ref() == j.projected.as_ref();
    let mut d = KnowledgeRestoreDiagnosis::empty("changed", !j.phase.terminal());
    d.transaction_id = Some(j.transaction_id.clone());
    d.phase = Some(j.phase.name());
    d.previous_manifest_sha256 = Some(j.previous.manifest_sha256.clone());
    d.projected_manifest_sha256 = Some(j.projected_manifest_sha256.clone());
    let expected_identity = if j.phase == Phase::Committed {
        j.projected.as_ref().map(|t| t.identity)
    } else {
        Some(j.previous.identity)
    };
    // Terminal normal writes may change content; the active directory must still be ours.
    if j.phase.terminal() {
        d.library_access_blocked =
            active_identity(&lease.file).is_none_or(|i| Some(i) != expected_identity);
    }
    let partial = if j.phase == Phase::Preparing || j.phase == Phase::Cancelled {
        partial_fingerprint(&lease.file, &stage).ok()
    } else {
        None
    };
    if extras.is_empty() {
        match j.phase {
            Phase::Preparing if old_active && partial.is_some() => {
                d.state = "preparing";
                d.can_cancel = true;
            }
            Phase::Intent if old_active && new_stage => {
                d.state = "prepared";
                d.can_cancel = true;
                d.snapshot_retained = true;
            }
            Phase::Intent if new_active && old_stage => {
                d.state = "installed";
                d.can_finalize = true;
                d.can_rollback = true;
                d.snapshot_retained = true;
            }
            Phase::Committed if new_active && old_stage => {
                d.state = "committed";
                d.can_rollback = true;
                d.snapshot_retained = true;
            }
            Phase::RolledBack if old_active && new_stage => {
                d.state = "rolledBack";
                d.snapshot_retained = true;
            }
            Phase::Cancelled if old_active && partial.is_some() => {
                d.state = "cancelled";
                d.snapshot_retained = new_stage;
            }
            _ => {}
        }
    }
    // No action after any observed drift. Include journal stamp and all eligible tree evidence.
    let fingerprint = hash(
        &serde_json::to_vec(&serde_json::json!({"journal":jr.hash,"stamp":jr.stamp,
        "active":active,"staged":staged,"partial":partial,"extras":extras,"diagnosis":d}))
        .map_err(|_| invalid())?,
    );
    if read_journal(&lease.file)?.is_none_or(|r| r.stamp != jr.stamp || r.hash != jr.hash) {
        return Err(invalid());
    }
    lease.verify()?;
    Ok(RecoveryObservation {
        diagnosis: d,
        journal: Some(jr),
        fingerprint,
    })
}
fn active_identity(root: &File) -> Option<(u64, u64, u32, u32)> {
    disk::directory(root, "knowledge-v1")
        .ok()
        .map(|d| disk::identity(&d.before))
}
/// Called before any ordinary read/write/startup GC. Never reads a retained snapshot's content.
pub(crate) fn normal_library_access(root: &File) -> CommandResult<()> {
    archive::access(root)?;
    match read_journal(root)? {
        None => empty_slot(root),
        Some(r) => {
            let j = r.journal;
            if !j.phase.terminal() {
                return Err(blocked());
            }
            let expected = if j.phase == Phase::Committed {
                j.projected.as_ref().map(|t| t.identity)
            } else {
                Some(j.previous.identity)
            };
            if active_identity(root).is_none_or(|i| Some(i) != expected) {
                return Err(blocked());
            }
            Ok(())
        }
    }
}
fn cstring(s: &str) -> CommandResult<CString> {
    CString::new(s).map_err(|_| invalid())
}
fn rename(root: &File, from: &str, to: &str, flags: u32) -> CommandResult<()> {
    let from = cstring(from)?;
    let to = cstring(to)?;
    if unsafe {
        libc::renameat2(
            root.as_raw_fd(),
            from.as_ptr(),
            root.as_raw_fd(),
            to.as_ptr(),
            flags,
        )
    } != 0
    {
        return Err(blocked());
    }
    Ok(())
}
fn exchange(root: &File, a: &str, b: &str) -> CommandResult<()> {
    rename(root, a, b, libc::RENAME_EXCHANGE)
}
fn sync_dir(dir: &File) -> CommandResult<()> {
    // Source directory descriptors can be O_PATH. Reopen only that held inode.
    let real = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_CLOEXEC)
        .open(format!("/proc/self/fd/{}", dir.as_raw_fd()))
        .map_err(|_| invalid())?;
    if disk::identity(&disk::file_stamp(&real)?) != disk::identity(&disk::file_stamp(dir)?) {
        return Err(invalid());
    }
    real.sync_all().map_err(|_| invalid())
}
fn mkdir(base: &File, name: &str) -> CommandResult<disk::Dir> {
    let c = cstring(name)?;
    if unsafe { libc::mkdirat(base.as_raw_fd(), c.as_ptr(), 0o700) } != 0 {
        return Err(invalid());
    }
    disk::directory(base, name).map_err(|_| invalid())
}
fn write_new(base: &File, name: &str, bytes: &[u8]) -> CommandResult<()> {
    let c = cstring(name)?;
    let fd = unsafe {
        libc::openat(
            base.as_raw_fd(),
            c.as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0o600,
        )
    };
    if fd < 0 {
        return Err(invalid());
    }
    let mut file = unsafe { File::from_raw_fd(fd) };
    file.write_all(bytes)
        .and_then(|_| file.sync_all())
        .map_err(|_| invalid())?;
    let m = file.metadata().map_err(|_| invalid())?;
    use std::os::unix::fs::MetadataExt;
    if !m.is_file()
        || m.mode() & 0o7777 != 0o600
        || m.nlink() != 1
        || m.uid() != unsafe { libc::geteuid() }
    {
        return Err(invalid());
    }
    if disk::observe(base, name, false) != disk::Observation::Found(disk::file_stamp(&file)?) {
        return Err(invalid());
    }
    Ok(())
}
fn write_journal(
    lease: &KnowledgeRootLease,
    j: &Journal,
    prior: Option<&JournalRead>,
) -> CommandResult<()> {
    lease.verify()?;
    let bytes = serde_json::to_vec(j).map_err(|_| invalid())?;
    if bytes.len() > JOURNAL_BYTES {
        return Err(invalid());
    }
    let temp = format!("{}{}", TEMP_PREFIX, Uuid::new_v4());
    write_new(&lease.file, &temp, &bytes)?;
    let current = read_journal(&lease.file)?;
    match (prior, current) {
        (None, None) => rename(&lease.file, &temp, JOURNAL, libc::RENAME_NOREPLACE)?,
        (Some(old), Some(current)) if old.stamp == current.stamp && old.hash == current.hash => {
            rename(&lease.file, &temp, JOURNAL, 0)?
        }
        _ => return Err(invalid()),
    }
    sync_dir(&lease.file)?;
    lease.verify()?;
    Ok(())
}
fn stage_tree(
    lease: &KnowledgeRootLease,
    name: &str,
    material: &InstallMaterial,
) -> CommandResult<()> {
    let started = Instant::now();
    let refs = manifest::project(&material.manifest)?;
    if material.manifest.len() > MANIFEST || refs.files.len() > MAX_RESOURCES {
        return Err(invalid());
    }
    let stage = mkdir(&lease.file, name)?;
    let blobs = mkdir(&stage.file, "blobs")?;
    let archives = mkdir(&stage.file, "archives")?;
    let mut bytes = 0usize;
    for reference in refs.files {
        if started.elapsed() > Duration::from_secs(30) {
            return Err(invalid());
        }
        let (kind, base) = if reference.kind == "body" {
            ("blobs", &blobs.file)
        } else {
            ("archives", &archives.file)
        };
        let resource = material
            .resources
            .get(&format!("{}/{}", kind, reference.digest))
            .ok_or_else(invalid)?;
        if !manifest::content_matches(&reference, resource)
            || resource.len() > MAX_RESOURCE_BYTES.saturating_sub(bytes)
        {
            return Err(invalid());
        }
        bytes += resource.len();
        write_new(base, &reference.digest, resource)?;
    }
    write_new(&stage.file, "manifest.json", &material.manifest)?;
    sync_dir(&blobs.file)?;
    sync_dir(&archives.file)?;
    sync_dir(&stage.file)?;
    sync_dir(&lease.file)?;
    lease.verify()?;
    Ok(())
}
#[cfg(test)]
#[path = "knowledge_restore_install_tests.rs"]
mod tests;

#[path = "knowledge_restore_archive.rs"]
mod archive;
pub use archive::{
    KnowledgeRestoreArchiveAction, KnowledgeRestoreArchivePlan, KnowledgeRestoreArchiveReceipt,
    KnowledgeRestoreArchiveStatus, KnowledgeRestoreArchiveStore, KnowledgeRestoreCleanupAction,
    KnowledgeRestoreCleanupPlan, KnowledgeRestoreCleanupReceipt, KnowledgeRestoreCleanupStatus,
    KnowledgeRestoreCleanupStore, KnowledgeRestoreHistoryExportPlan,
    KnowledgeRestoreHistoryExportReceipt, KnowledgeRestoreHistoryExportStatus,
    KnowledgeRestoreHistoryExportStore,
};
