//! Explicit archival of terminal restore evidence. No snapshot deletion or automatic repair.
use super::*;
const INTENT: &str = "knowledge-restore-archive-intent.json";
const HISTORY_PREFIX: &str = ".repopress-knowledge-history-";
const RECORD: &str = "record.json";
const SNAPSHOT: &str = "snapshot";
const RECORD_BYTES: usize = 2 * 1024 * 1024;
const HISTORY_LIMIT: usize = 4;
const ARCHIVE_TIME: Duration = Duration::from_secs(30);

pub(super) fn access(root: &File) -> CommandResult<()> {
    cleanup::access(root)?;
    if disk::observe(root, INTENT, false) != disk::Observation::Missing {
        return Err(blocked());
    }
    Ok(())
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum KnowledgeRestoreArchiveAction {
    Archive,
    Resume,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeRestoreArchiveEntry {
    transaction_id: String,
    phase: &'static str,
    previous_manifest_sha256: String,
    projected_manifest_sha256: String,
    snapshot_manifest_sha256: Option<String>,
    snapshot_present: bool,
    snapshot_file_count: usize,
    snapshot_byte_size: u64,
    archived_at_epoch_ms: u64,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeRestoreArchiveStatus {
    schema_version: u8,
    scope: &'static str,
    state: &'static str,
    transaction_id: Option<String>,
    phase: Option<&'static str>,
    current_manifest_sha256: Option<String>,
    transaction_journal_sha256: Option<String>,
    snapshot_manifest_sha256: Option<String>,
    snapshot_present: bool,
    snapshot_file_count: Option<usize>,
    snapshot_byte_size: Option<u64>,
    history: Vec<KnowledgeRestoreArchiveEntry>,
    history_limit: usize,
    can_archive: bool,
    can_resume: bool,
    transaction_slot_released: bool,
    library_access_blocked: bool,
    filesystem_writes: bool,
}
impl KnowledgeRestoreArchiveStatus {
    fn empty(state: &'static str, blocked: bool) -> Self {
        Self {
            schema_version: 1,
            scope: "knowledgeRestoreArchiveStatus",
            state,
            transaction_id: None,
            phase: None,
            current_manifest_sha256: None,
            transaction_journal_sha256: None,
            snapshot_manifest_sha256: None,
            snapshot_present: false,
            snapshot_file_count: None,
            snapshot_byte_size: None,
            history: vec![],
            history_limit: HISTORY_LIMIT,
            can_archive: false,
            can_resume: false,
            transaction_slot_released: state == "none",
            library_access_blocked: blocked,
            filesystem_writes: false,
        }
    }
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeRestoreArchivePlan {
    schema_version: u8,
    scope: &'static str,
    pub plan_id: String,
    action: KnowledgeRestoreArchiveAction,
    status: KnowledgeRestoreArchiveStatus,
    requires_acknowledgement: bool,
    preserves_snapshot: bool,
    current_library_changed: bool,
    disables_direct_rollback: bool,
    releases_transaction_slot: bool,
    checked_at_epoch_ms: u64,
    expires_at_epoch_ms: u64,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeRestoreArchiveReceipt {
    schema_version: u8,
    scope: &'static str,
    plan_id: String,
    transaction_id: String,
    action: KnowledgeRestoreArchiveAction,
    state: &'static str,
    entry: KnowledgeRestoreArchiveEntry,
    snapshot_retained: bool,
    current_library_changed: bool,
    transaction_slot_released: bool,
    journal_archived: bool,
    library_access_blocked: bool,
    completed_at_epoch_ms: u64,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ActiveEvidence {
    top: disk::Stamp,
    blobs: disk::Stamp,
    archives: disk::Stamp,
    manifest: disk::Stamp,
    manifest_sha256: String,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct ArchiveRecord {
    schema_version: u8,
    scope: String,
    transaction_id: String,
    root_identity: (u64, u64, u32, u32),
    journal: Journal,
    source_journal_stamp: disk::Stamp,
    source_journal_sha256: String,
    active: ActiveEvidence,
    snapshot: Option<TreeEvidence>,
    existing_history_fingerprint: String,
    archived_at_epoch_ms: u64,
}
impl ArchiveRecord {
    fn entry(&self) -> KnowledgeRestoreArchiveEntry {
        KnowledgeRestoreArchiveEntry {
            transaction_id: self.transaction_id.clone(),
            phase: self.journal.phase.name(),
            previous_manifest_sha256: self.journal.previous.manifest_sha256.clone(),
            projected_manifest_sha256: self.journal.projected_manifest_sha256.clone(),
            snapshot_manifest_sha256: self.snapshot.as_ref().map(|s| s.manifest_sha256.clone()),
            snapshot_present: self.snapshot.is_some(),
            snapshot_file_count: self.snapshot.as_ref().map_or(0, |s| s.files.len()),
            snapshot_byte_size: self
                .snapshot
                .as_ref()
                .map_or(0, |s| s.files.values().map(disk::byte_size).sum()),
            archived_at_epoch_ms: self.archived_at_epoch_ms,
        }
    }
}
struct RecordRead {
    record: ArchiveRecord,
    bytes: Vec<u8>,
    stamp: disk::Stamp,
    hash: String,
}
#[derive(Serialize)]
struct HistoryWitness {
    directory: disk::Stamp,
    record: disk::Stamp,
    record_hash: String,
    journal: disk::Stamp,
    journal_hash: String,
    snapshot: Option<TreeEvidence>,
}
struct ArchiveObservation {
    status: KnowledgeRestoreArchiveStatus,
    record: Option<ArchiveRecord>,
    intent: Option<RecordRead>,
    fingerprint: String,
}
struct ArchivePending {
    created: Instant,
    expires: u64,
    action: KnowledgeRestoreArchiveAction,
    transaction_id: String,
    fingerprint: String,
}
impl ArchivePending {
    fn valid(&self) -> CommandResult<()> {
        let t = now()?;
        if self.created.elapsed() >= TTL
            || t >= self.expires
            || t < self.expires.saturating_sub(300000)
        {
            return Err(invalid());
        }
        Ok(())
    }
}
#[derive(Default)]
pub struct KnowledgeRestoreArchiveStore {
    install: KnowledgeRestoreInstallStore,
    plans: Mutex<HashMap<String, ArchivePending>>,
}
impl KnowledgeRestoreArchiveStore {
    pub fn new(root: PathBuf) -> Self {
        Self {
            install: KnowledgeRestoreInstallStore::new(root),
            plans: Mutex::new(HashMap::new()),
        }
    }
    pub fn inspect(&self) -> CommandResult<KnowledgeRestoreArchiveStatus> {
        let lease = match self.install.unrestricted_lease() {
            Ok(l) => l,
            Err(_) => return Ok(KnowledgeRestoreArchiveStatus::empty("unavailable", true)),
        };
        match observe_archive(&lease) {
            Ok(o) => Ok(o.status),
            Err(_) => Ok(KnowledgeRestoreArchiveStatus::empty(
                "blocked",
                normal_library_access(&lease.file).is_err(),
            )),
        }
    }
    pub fn plan(
        &self,
        transaction_id: &str,
        action: KnowledgeRestoreArchiveAction,
    ) -> CommandResult<KnowledgeRestoreArchivePlan> {
        if !disk::valid_id(transaction_id) {
            return Err(invalid());
        }
        let lease = self.install.unrestricted_lease()?;
        let o = observe_archive(&lease)?;
        if o.status.transaction_id.as_deref() != Some(transaction_id)
            || !(match action {
                KnowledgeRestoreArchiveAction::Archive => o.status.can_archive,
                KnowledgeRestoreArchiveAction::Resume => o.status.can_resume,
            })
        {
            return Err(invalid());
        }
        let time = now()?;
        let expires = time.checked_add(300000).ok_or_else(invalid)?;
        let id = Uuid::new_v4().to_string();
        let mut plans = self.plans.lock().map_err(|_| invalid())?;
        plans.retain(|_, p| p.valid().is_ok());
        if plans.len() >= 2 {
            return Err(invalid());
        }
        plans.insert(
            id.clone(),
            ArchivePending {
                created: Instant::now(),
                expires,
                action,
                transaction_id: transaction_id.into(),
                fingerprint: o.fingerprint,
            },
        );
        Ok(KnowledgeRestoreArchivePlan {
            schema_version: 1,
            scope: "knowledgeRestoreArchivePlan",
            plan_id: id,
            action,
            status: o.status,
            requires_acknowledgement: true,
            preserves_snapshot: true,
            current_library_changed: false,
            disables_direct_rollback: true,
            releases_transaction_slot: true,
            checked_at_epoch_ms: time,
            expires_at_epoch_ms: expires,
        })
    }
    pub fn discard(&self, id: &str) -> CommandResult<()> {
        self.plans.lock().map_err(|_| invalid())?.remove(id);
        Ok(())
    }
    pub fn execute(
        &self,
        id: &str,
        acknowledge_archive: bool,
    ) -> CommandResult<KnowledgeRestoreArchiveReceipt> {
        self.execute_checked(id, acknowledge_archive, |_| Ok(()))
    }
    fn execute_checked(
        &self,
        id: &str,
        ack: bool,
        hook: impl FnMut(u8) -> CommandResult<()>,
    ) -> CommandResult<KnowledgeRestoreArchiveReceipt> {
        self.execute_with_release_sync(id, ack, hook, sync_dir)
    }
    fn execute_with_release_sync(
        &self,
        id: &str,
        ack: bool,
        mut hook: impl FnMut(u8) -> CommandResult<()>,
        mut release_sync: impl FnMut(&File) -> CommandResult<()>,
    ) -> CommandResult<KnowledgeRestoreArchiveReceipt> {
        // Consume before acknowledgement, root acquisition, validation or filesystem writes.
        let pending = self
            .plans
            .lock()
            .map_err(|_| invalid())?
            .remove(id)
            .ok_or_else(invalid)?;
        if !ack {
            return Err(invalid());
        }
        pending.valid()?;
        let lease = self.install.unrestricted_lease()?;
        let fresh = observe_archive(&lease)?;
        if fresh.fingerprint != pending.fingerprint
            || fresh.status.transaction_id.as_deref() != Some(&pending.transaction_id)
        {
            return Err(invalid());
        }
        let record = fresh.record.ok_or_else(invalid)?;
        let bytes = serde_json::to_vec(&record).map_err(|_| invalid())?;
        if bytes.len() > RECORD_BYTES {
            return Err(invalid());
        }
        if pending.action == KnowledgeRestoreArchiveAction::Archive {
            if !fresh.status.can_archive || fresh.intent.is_some() {
                return Err(invalid());
            }
            write_new(&lease.file, INTENT, &bytes)?;
            sync_dir(&lease.file)?;
        } else if !fresh.status.can_resume || fresh.intent.is_none() {
            return Err(invalid());
        }
        lease.verify()?;
        hook(0)?;
        pending.valid()?;
        // Re-observe each bookend; intent is immutable, unknown or partial metadata stays blocked.
        checked_record(&lease, &record)?;
        let name = history_name(&record.transaction_id);
        if disk::observe(&lease.file, &name, true) == disk::Observation::Missing {
            mkdir(&lease.file, &name)?;
            sync_dir(&lease.file)?;
        }
        let dir = disk::directory(&lease.file, &name).map_err(|_| invalid())?;
        if disk::observe(&dir.file, RECORD, false) == disk::Observation::Missing {
            write_new(&dir.file, RECORD, &bytes)?;
        }
        sync_dir(&dir.file)?;
        sync_dir(&lease.file)?;
        hook(1)?;
        pending.valid()?;
        checked_record(&lease, &record)?;
        if record.snapshot.is_some()
            && disk::observe(&lease.file, &stage_name(&record.journal), true)
                != disk::Observation::Missing
        {
            let dir = disk::directory(&lease.file, &name).map_err(|_| invalid())?;
            if !disk::verify_dir(&lease.file, &name, &dir) {
                return Err(invalid());
            }
            cross_rename(
                &lease.file,
                &stage_name(&record.journal),
                &dir.file,
                SNAPSHOT,
            )?;
            sync_dir(&dir.file)?;
            sync_dir(&lease.file)?;
        }
        hook(2)?;
        pending.valid()?;
        checked_record(&lease, &record)?;
        if disk::observe(&lease.file, JOURNAL, false) != disk::Observation::Missing {
            let dir = disk::directory(&lease.file, &name).map_err(|_| invalid())?;
            if !disk::verify_dir(&lease.file, &name, &dir) {
                return Err(invalid());
            }
            cross_rename(&lease.file, JOURNAL, &dir.file, JOURNAL)?;
            sync_dir(&dir.file)?;
            sync_dir(&lease.file)?;
        }
        hook(3)?;
        pending.valid()?;
        let o = checked_record(&lease, &record)?;
        if o.status.state != "archived" {
            return Err(invalid());
        }
        // Resume may see a rename whose earlier directory fsync failed. Visibility alone
        // is insufficient: persist BOTH destination and source before removing the marker.
        let destination = disk::directory(&lease.file, &name).map_err(|_| invalid())?;
        release_sync(&destination.file)?;
        release_sync(&lease.file)?;
        let o = checked_record(&lease, &record)?;
        if o.status.state != "archived" || !disk::verify_dir(&lease.file, &name, &destination) {
            return Err(invalid());
        }
        let intent = o.intent.ok_or_else(invalid)?;
        lease.verify()?;
        pending.valid()?;
        // Only this transient marker is removed; all original journal/snapshot bytes remain.
        let current = read_record(&lease.file, INTENT, record.root_identity)?;
        if current.stamp != intent.stamp || current.hash != intent.hash {
            return Err(invalid());
        }
        let c = cstring(INTENT)?;
        if unsafe { libc::unlinkat(lease.file.as_raw_fd(), c.as_ptr(), 0) } != 0 {
            return Err(invalid());
        }
        sync_dir(&lease.file)?;
        hook(4)?;
        lease.verify()?;
        let final_o = observe_archive(&lease)?;
        if active(&lease.file)? != record.active
            || !final_o.status.transaction_slot_released
            || !final_o.status.history.iter().any(|e| e == &record.entry())
        {
            return Err(invalid());
        }
        Ok(KnowledgeRestoreArchiveReceipt {
            schema_version: 1,
            scope: "knowledgeRestoreArchiveReceipt",
            plan_id: id.into(),
            transaction_id: record.transaction_id.clone(),
            action: pending.action,
            state: "archived",
            entry: record.entry(),
            snapshot_retained: record.snapshot.is_some(),
            current_library_changed: false,
            transaction_slot_released: true,
            journal_archived: true,
            library_access_blocked: false,
            completed_at_epoch_ms: now()?,
        })
    }
}
fn cross_rename(from: &File, source: &str, to: &File, destination: &str) -> CommandResult<()> {
    let source = cstring(source)?;
    let destination = cstring(destination)?;
    if unsafe {
        libc::renameat2(
            from.as_raw_fd(),
            source.as_ptr(),
            to.as_raw_fd(),
            destination.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    } != 0
    {
        return Err(invalid());
    }
    Ok(())
}
fn history_name(id: &str) -> String {
    format!("{}{}", HISTORY_PREFIX, id)
}
fn archive_bounded(started: Instant) -> CommandResult<()> {
    if started.elapsed() >= ARCHIVE_TIME {
        return Err(invalid());
    }
    Ok(())
}
fn active(root: &File) -> CommandResult<ActiveEvidence> {
    let dir = disk::directory(root, "knowledge-v1").map_err(|_| invalid())?;
    let blobs = disk::directory(&dir.file, "blobs").map_err(|_| invalid())?;
    let archives = disk::directory(&dir.file, "archives").map_err(|_| invalid())?;
    let read =
        disk::read(&dir.file, "manifest.json", MANIFEST, Instant::now()).map_err(|_| invalid())?;
    knowledge_package_check::parse_json(&read.bytes, Instant::now())?;
    manifest::validate_completed_operations(&read.bytes)?;
    manifest::project(&read.bytes)?;
    if !read.witness.verify(&dir.file, "manifest.json")
        || !disk::verify_dir(&dir.file, "blobs", &blobs)
        || !disk::verify_dir(&dir.file, "archives", &archives)
        || !disk::verify_dir(root, "knowledge-v1", &dir)
    {
        return Err(invalid());
    }
    Ok(ActiveEvidence {
        top: dir.before,
        blobs: blobs.before,
        archives: archives.before,
        manifest: read.witness.before,
        manifest_sha256: hash(&read.bytes),
    })
}
fn expected_snapshot(j: &Journal) -> CommandResult<Option<TreeEvidence>> {
    match j.phase {
        Phase::Committed => Ok(Some(j.previous.clone())),
        Phase::RolledBack => Ok(Some(j.projected.clone().ok_or_else(invalid)?)),
        Phase::Cancelled => Ok(j.projected.clone()),
        _ => Err(invalid()),
    }
}
fn expected_active(j: &Journal) -> CommandResult<(u64, u64, u32, u32)> {
    if j.phase == Phase::Committed {
        Ok(j.projected.as_ref().ok_or_else(invalid)?.identity)
    } else if j.phase.terminal() {
        Ok(j.previous.identity)
    } else {
        Err(invalid())
    }
}
fn valid_record(r: &ArchiveRecord, root_identity: (u64, u64, u32, u32)) -> CommandResult<()> {
    let j = &r.journal;
    if r.schema_version != 1
        || r.scope != "knowledgeRestoreArchiveRecord"
        || !disk::valid_id(&r.transaction_id)
        || r.transaction_id != j.transaction_id
        || r.root_identity != root_identity
        || j.root_identity != root_identity
        || j.schema_version != 1
        || j.scope != "knowledgeRestoreIntent"
        || !j.phase.terminal()
        || !valid_evidence(&j.previous)
        || !valid_digest(&j.projected_manifest_sha256)
        || j.projected
            .as_ref()
            .is_some_and(|p| !valid_evidence(p) || p.manifest_sha256 != j.projected_manifest_sha256)
        || r.snapshot != expected_snapshot(j)?
        || disk::identity(&r.active.top) != expected_active(j)?
        || !valid_digest(&r.active.manifest_sha256)
        || !valid_digest(&r.source_journal_sha256)
        || !valid_digest(&r.existing_history_fingerprint)
        || r.archived_at_epoch_ms == 0
        || r.snapshot.as_ref().is_some_and(|s| {
            s.identity == disk::identity(&r.active.top)
                || s.files.len() > MAX_RESOURCES + 1
                || s.files
                    .values()
                    .map(disk::byte_size)
                    .try_fold(0u64, |a, b| a.checked_add(b))
                    .is_none_or(|b| b > (MAX_RESOURCE_BYTES + MANIFEST) as u64)
        })
    {
        return Err(invalid());
    }
    Ok(())
}
fn read_record(base: &File, name: &str, root: (u64, u64, u32, u32)) -> CommandResult<RecordRead> {
    let read = disk::read(base, name, RECORD_BYTES, Instant::now()).map_err(|_| invalid())?;
    knowledge_package_check::parse_json(&read.bytes, Instant::now())?;
    let record: ArchiveRecord = serde_json::from_slice(&read.bytes).map_err(|_| invalid())?;
    valid_record(&record, root)?;
    if !read.witness.verify(base, name) {
        return Err(invalid());
    }
    Ok(RecordRead {
        record,
        hash: hash(&read.bytes),
        bytes: read.bytes,
        stamp: read.witness.before,
    })
}
fn archived_journal(base: &File, r: &ArchiveRecord) -> CommandResult<(disk::Stamp, String)> {
    let read = disk::read(base, JOURNAL, JOURNAL_BYTES, Instant::now()).map_err(|_| invalid())?;
    knowledge_package_check::parse_json(&read.bytes, Instant::now())?;
    let j: Journal = serde_json::from_slice(&read.bytes).map_err(|_| invalid())?;
    let sha = hash(&read.bytes);
    if j != r.journal
        || sha != r.source_journal_sha256
        || !disk::same_renamed_file(&r.source_journal_stamp, &read.witness.before)
        || !read.witness.verify(base, JOURNAL)
    {
        return Err(invalid());
    }
    Ok((read.witness.before, sha))
}
fn names(root: &File) -> CommandResult<BTreeSet<String>> {
    disk::bounded_names(root, 4096)
}
fn histories(
    root: &File,
    exclude: Option<&str>,
    started: Instant,
) -> CommandResult<(Vec<KnowledgeRestoreArchiveEntry>, String)> {
    let root_identity = disk::identity(&disk::file_stamp(root)?);
    let mut pending = vec![];
    let mut witnesses = BTreeMap::<String, HistoryWitness>::new();
    for name in names(root)? {
        archive_bounded(started)?;
        if !name.starts_with(HISTORY_PREFIX) || exclude == Some(name.as_str()) {
            continue;
        }
        let id = name
            .strip_prefix(HISTORY_PREFIX)
            .filter(|id| disk::valid_id(id))
            .ok_or_else(invalid)?;
        if pending.len() >= HISTORY_LIMIT {
            return Err(invalid());
        }
        let dir = disk::directory(root, &name).map_err(|_| invalid())?;
        let read = read_record(&dir.file, RECORD, root_identity)?;
        if read.record.transaction_id != id {
            return Err(invalid());
        }
        let mut expected = BTreeSet::from([RECORD.to_string(), JOURNAL.to_string()]);
        let snapshot = if let Some(e) = &read.record.snapshot {
            expected.insert(SNAPSHOT.into());
            let tree = audit_tree(&dir.file, SNAPSHOT, MAX_RESOURCES, MAX_RESOURCE_BYTES)?;
            if &tree != e {
                return Err(invalid());
            }
            Some(tree)
        } else {
            None
        };
        if disk::bounded_names(&dir.file, 4)? != expected {
            return Err(invalid());
        }
        let (journal, journal_hash) = archived_journal(&dir.file, &read.record)?;
        if !disk::verify_dir(root, &name, &dir) {
            return Err(invalid());
        }
        pending.push((
            name,
            read.record.entry(),
            read.record.existing_history_fingerprint,
            HistoryWitness {
                directory: dir.before,
                record: read.stamp,
                record_hash: read.hash,
                journal,
                journal_hash,
                snapshot,
            },
        ));
    }
    let mut entries = vec![];
    let mut fingerprint = hash(&serde_json::to_vec(&witnesses).map_err(|_| invalid())?);
    while !pending.is_empty() {
        archive_bounded(started)?;
        let matching = pending
            .iter()
            .enumerate()
            .filter(|(_, p)| p.2 == fingerprint)
            .map(|(i, _)| i)
            .collect::<Vec<_>>();
        if matching.len() != 1 {
            return Err(invalid());
        }
        let (name, entry, _, witness) = pending.remove(matching[0]);
        witnesses.insert(name, witness);
        entries.push(entry);
        fingerprint = hash(&serde_json::to_vec(&witnesses).map_err(|_| invalid())?);
    }
    archive_bounded(started)?;
    Ok((entries, fingerprint))
}
fn status_record(
    r: &ArchiveRecord,
    state: &'static str,
    history: Vec<KnowledgeRestoreArchiveEntry>,
) -> KnowledgeRestoreArchiveStatus {
    let entry = r.entry();
    KnowledgeRestoreArchiveStatus {
        schema_version: 1,
        scope: "knowledgeRestoreArchiveStatus",
        state,
        transaction_id: Some(r.transaction_id.clone()),
        phase: Some(r.journal.phase.name()),
        current_manifest_sha256: Some(r.active.manifest_sha256.clone()),
        transaction_journal_sha256: Some(r.source_journal_sha256.clone()),
        snapshot_manifest_sha256: entry.snapshot_manifest_sha256,
        snapshot_present: entry.snapshot_present,
        snapshot_file_count: Some(entry.snapshot_file_count),
        snapshot_byte_size: Some(entry.snapshot_byte_size),
        can_archive: state == "eligible" && history.len() < HISTORY_LIMIT,
        can_resume: state == "archiving" || state == "archived",
        history,
        history_limit: HISTORY_LIMIT,
        transaction_slot_released: false,
        library_access_blocked: state != "eligible",
        filesystem_writes: false,
    }
}
fn observe_archive(lease: &KnowledgeRootLease) -> CommandResult<ArchiveObservation> {
    cleanup::access(&lease.file)?;
    let started = Instant::now();
    lease.verify()?;
    let root = &lease.file;
    let identity = disk::identity(&disk::file_stamp(root)?);
    let intent_present = disk::observe(root, INTENT, false) != disk::Observation::Missing;
    let intent = if intent_present {
        Some(read_record(root, INTENT, identity)?)
    } else {
        None
    };
    let exclude = intent
        .as_ref()
        .map(|i| history_name(&i.record.transaction_id));
    let (history, history_fp) = histories(root, exclude.as_deref(), started)?;
    let (status, record, partial) = if let Some(intent) = &intent {
        let r = &intent.record;
        if history.len() >= HISTORY_LIMIT
            || history_fp != r.existing_history_fingerprint
            || active(root)? != r.active
        {
            return Err(invalid());
        }
        let stage = stage_name(&r.journal);
        let extras = reserved(root)?;
        if extras.iter().any(|n| n != &stage) {
            return Err(invalid());
        }
        let name = history_name(&r.transaction_id);
        let dest = if disk::observe(root, &name, true) == disk::Observation::Missing {
            None
        } else {
            Some(disk::directory(root, &name).map_err(|_| invalid())?)
        };
        let dest_names = match &dest {
            Some(d) => disk::bounded_names(&d.file, 4)?,
            None => BTreeSet::new(),
        };
        if dest_names
            .iter()
            .any(|s| s != RECORD && s != JOURNAL && s != SNAPSHOT)
            || (!dest_names.contains(RECORD) && !dest_names.is_empty())
        {
            return Err(invalid());
        }
        let mut destination_record = None;
        if dest_names.contains(RECORD) {
            let dr = read_record(&dest.as_ref().ok_or_else(invalid)?.file, RECORD, identity)?;
            if dr.bytes != intent.bytes {
                return Err(invalid());
            }
            destination_record = Some((dr.stamp, dr.hash));
        }
        let source_journal = read_journal(root)?;
        let destination_journal = if dest_names.contains(JOURNAL) {
            Some(archived_journal(
                &dest.as_ref().ok_or_else(invalid)?.file,
                r,
            )?)
        } else {
            None
        };
        match (&source_journal, &destination_journal) {
            (Some(j), None)
                if j.journal == r.journal
                    && j.stamp == r.source_journal_stamp
                    && j.hash == r.source_journal_sha256 => {}
            (None, Some(_)) => {}
            _ => return Err(invalid()),
        }
        let stage_present = disk::observe(root, &stage, true) != disk::Observation::Missing;
        let snapshot_present = dest_names.contains(SNAPSHOT);
        let snapshot = match (&r.snapshot, stage_present, snapshot_present) {
            (Some(expected), true, false) => {
                let t = audit_tree(root, &stage, MAX_RESOURCES, MAX_RESOURCE_BYTES)?;
                if &t != expected {
                    return Err(invalid());
                }
                Some(t)
            }
            (Some(expected), false, true) => {
                let t = audit_tree(
                    &dest.as_ref().ok_or_else(invalid)?.file,
                    SNAPSHOT,
                    MAX_RESOURCES,
                    MAX_RESOURCE_BYTES,
                )?;
                if &t != expected {
                    return Err(invalid());
                }
                Some(t)
            }
            (None, false, false) => None,
            _ => return Err(invalid()),
        };
        // Journal is moved last: an archived journal with source snapshot is never a known bookend.
        if destination_journal.is_some() && stage_present {
            return Err(invalid());
        }
        let complete = destination_record.is_some()
            && destination_journal.is_some()
            && (snapshot_present == r.snapshot.is_some());
        let partial = serde_json::json!({"destination":dest.as_ref().map(|d| &d.before),
            "record":destination_record,"sourceJournal":source_journal.map(|j| (j.stamp,j.hash)),
            "journal":destination_journal,"sourceSnapshot":stage_present,"snapshot":snapshot});
        if let Some(d) = &dest {
            if !disk::verify_dir(root, &name, d) {
                return Err(invalid());
            }
        }
        (
            status_record(r, if complete { "archived" } else { "archiving" }, history),
            Some(r.clone()),
            partial,
        )
    } else if let Some(jr) = read_journal(root)? {
        let j = jr.journal;
        let active = active(root)?;
        if !j.phase.terminal() || disk::identity(&active.top) != expected_active(&j)? {
            return Err(invalid());
        }
        let stage = stage_name(&j);
        let extras = reserved(root)?;
        if extras.iter().any(|n| n != &stage) {
            return Err(invalid());
        }
        let snapshot = expected_snapshot(&j)?;
        match &snapshot {
            Some(e) => {
                if audit_tree(root, &stage, MAX_RESOURCES, MAX_RESOURCE_BYTES)? != *e
                    || e.identity == disk::identity(&active.top)
                {
                    return Err(invalid());
                }
            }
            None => {
                if disk::observe(root, &stage, true) != disk::Observation::Missing {
                    return Err(invalid());
                }
            }
        }
        if disk::observe(root, &history_name(&j.transaction_id), true) != disk::Observation::Missing
        {
            return Err(invalid());
        }
        let r = ArchiveRecord {
            schema_version: 1,
            scope: "knowledgeRestoreArchiveRecord".into(),
            transaction_id: j.transaction_id.clone(),
            root_identity: identity,
            journal: j,
            source_journal_stamp: jr.stamp,
            source_journal_sha256: jr.hash,
            active,
            snapshot,
            existing_history_fingerprint: history_fp.clone(),
            archived_at_epoch_ms: now()?,
        };
        valid_record(&r, identity)?;
        // Timestamp is assigned during execution, not part of the read-only observation fingerprint.
        (status_record(&r, "eligible", history), Some(r), Value::Null)
    } else {
        empty_slot(root)?;
        let mut status = KnowledgeRestoreArchiveStatus::empty("none", false);
        status.history = history;
        (status, None, Value::Null)
    };
    archive_bounded(started)?;
    // A second history pass binds inode/stamp/content drift across the selected transaction scan.
    if histories(root, exclude.as_deref(), started)?.1 != history_fp {
        return Err(invalid());
    }
    if let Some(r) = &record {
        if active(root)? != r.active {
            return Err(invalid());
        }
        if intent.is_none()
            && read_journal(root)?.is_none_or(|j| {
                j.stamp != r.source_journal_stamp || j.hash != r.source_journal_sha256
            })
        {
            return Err(invalid());
        }
    }
    if let Some(i) = &intent {
        let fresh = read_record(root, INTENT, identity)?;
        if i.stamp != fresh.stamp || i.hash != fresh.hash {
            return Err(invalid());
        }
    } else {
        access(root)?;
    }
    lease.verify()?;
    let fingerprint = hash(&serde_json::to_vec(&serde_json::json!({"status":status,
        "record":record.as_ref().map(|r| { let mut r=r.clone(); if intent.is_none() {r.archived_at_epoch_ms=0;} r }),
        "history":history_fp,"intent":intent.as_ref().map(|i| (&i.stamp,&i.hash)),"partial":partial})).map_err(|_| invalid())?);
    Ok(ArchiveObservation {
        status,
        record,
        intent,
        fingerprint,
    })
}
fn checked_record(
    lease: &KnowledgeRootLease,
    r: &ArchiveRecord,
) -> CommandResult<ArchiveObservation> {
    let o = observe_archive(lease)?;
    if o.record.as_ref() != Some(r) || !o.status.can_resume {
        return Err(invalid());
    }
    Ok(o)
}
#[cfg(test)]
#[path = "knowledge_restore_archive_tests.rs"]
mod tests;

#[path = "knowledge_restore_cleanup.rs"]
mod cleanup;
pub use cleanup::{
    KnowledgeRestoreCleanupAction, KnowledgeRestoreCleanupPlan, KnowledgeRestoreCleanupReceipt,
    KnowledgeRestoreCleanupStatus, KnowledgeRestoreCleanupStore,
};

#[path = "knowledge_restore_history_export.rs"]
mod history_export;
pub use history_export::{
    KnowledgeRestoreHistoryExportPlan, KnowledgeRestoreHistoryExportReceipt,
    KnowledgeRestoreHistoryExportStatus, KnowledgeRestoreHistoryExportStore,
};
