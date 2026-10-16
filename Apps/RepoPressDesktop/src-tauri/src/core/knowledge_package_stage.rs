//! Consent-bound private candidate directory. Never installs, activates, migrates or cleans a library.
use super::{
    knowledge_package_check::{self, source::Source, KnowledgePackageCheckReport, Validated},
    workspace_backup, CommandError, CommandResult,
};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashMap},
    fs::File,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
    sync::Mutex,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;
#[path = "knowledge_package_stage_disk.rs"]
mod disk;
const TTL: Duration = Duration::from_secs(300);
const TIME: Duration = Duration::from_secs(30);
const FILES: usize = 1026;
const BYTES: usize = 34 * 1024 * 1024 + 4096;
const FORMAT: &str = "repopress-knowledge-isolated-candidate";
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Limits {
    candidate_files: usize,
    candidate_bytes: usize,
    duration_ms: u64,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgePackageStagePlan {
    pub plan_id: String,
    pub source_path: String,
    pub parent_path: String,
    pub candidate_path: String,
    format: &'static str,
    schema_version: u8,
    package: KnowledgePackageCheckReport,
    candidate_file_count: usize,
    candidate_byte_size: usize,
    candidate_inventory_sha256: String,
    limits: Limits,
    requires_sensitive_plaintext_consent: bool,
    candidate_only: bool,
    current_library_changed: bool,
    restore_ready: bool,
    created_at_epoch_ms: u64,
    expires_at_epoch_ms: u64,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgePackageStageResult {
    plan_id: String,
    source_path: String,
    candidate_path: String,
    package_sha256: String,
    manifest_sha256: String,
    candidate_file_count: usize,
    candidate_byte_size: usize,
    candidate_inventory_sha256: String,
    private_permissions_verified: bool,
    contents_verified: bool,
    source_revalidated: bool,
    candidate_only: bool,
    current_library_changed: bool,
    restore_ready: bool,
}
struct Root {
    path: PathBuf,
    file: File,
    identity: (u64, u64, u32, u32),
}
fn identity(file: &File) -> CommandResult<(u64, u64, u32, u32)> {
    let m = file.metadata().map_err(|_| invalid())?;
    Ok((m.dev(), m.ino(), m.mode(), m.uid()))
}
impl Root {
    fn new(path: PathBuf) -> Option<Self> {
        let file = workspace_backup::root_handle(&path).ok()?;
        let identity = identity(&file).ok()?;
        Some(Self {
            path,
            file,
            identity,
        })
    }
    fn verify(&self) -> CommandResult<()> {
        let current = workspace_backup::root_handle(&self.path).map_err(|_| invalid())?;
        if identity(&current)? != self.identity || identity(&self.file)? != self.identity {
            return Err(invalid());
        }
        Ok(())
    }
}
struct Binding {
    plan: KnowledgePackageStagePlan,
    source: Source,
    target: disk::Target,
    created: Instant,
}
#[derive(Default)]
pub struct KnowledgePackageStageStore {
    root: Option<Root>,
    bindings: Mutex<HashMap<String, Binding>>,
}
fn invalid() -> CommandError {
    CommandError::new("knowledge_package_stage_invalid", "Source, private candidate location, limits, consent or one-time plan is unsafe, expired or changed. Prepare and review a new candidate; no library was installed or replaced.")
}
fn unconfirmed() -> CommandError {
    CommandError::new("knowledge_package_stage_unconfirmed", "Candidate creation could not be confirmed. A private partial directory may remain at the reviewed candidate path. Inspect it before preparing a new plan; do not retry this plan. No automatic cleanup or current-library replacement was performed.")
}
fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn bounded(started: Instant) -> CommandResult<()> {
    if started.elapsed() >= TIME {
        Err(invalid())
    } else {
        Ok(())
    }
}
fn now() -> CommandResult<u64> {
    let value = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| invalid())?
        .as_millis();
    if value == 0 || value > 8_639_999_999_700_000 {
        return Err(invalid());
    }
    Ok(value as u64)
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CandidateMarker<'a> {
    format: &'static str,
    schema_version: u8,
    plan_id: &'a str,
    source_package_sha256: &'a str,
    manifest_sha256: &'a str,
    candidate_only: bool,
    includes_credential_stores: bool,
    includes_completed_operations: bool,
    external_references_included: bool,
    current_library_changed: bool,
    restore_ready: bool,
}
struct Layout {
    files: BTreeMap<String, Vec<u8>>,
    byte_size: usize,
    inventory_sha256: String,
}
impl Layout {
    fn new(staged: Validated, id: &str, source_sha: &str) -> CommandResult<Self> {
        let marker = serde_json::to_vec(&CandidateMarker {
            format: FORMAT,
            schema_version: 1,
            plan_id: id,
            source_package_sha256: source_sha,
            manifest_sha256: &staged.manifest_sha256,
            candidate_only: true,
            includes_credential_stores: false,
            includes_completed_operations: false,
            external_references_included: false,
            current_library_changed: false,
            restore_ready: false,
        })
        .map_err(|_| invalid())?;
        let mut files: BTreeMap<String, Vec<u8>> = staged
            .files
            .into_iter()
            .map(|(path, bytes)| (format!("knowledge-v1/{path}"), bytes))
            .collect();
        files.insert("knowledge-v1/manifest.json".into(), staged.manifest);
        files.insert("candidate.json".into(), marker);
        let byte_size = files
            .values()
            .try_fold(0usize, |total, bytes| total.checked_add(bytes.len()))
            .ok_or_else(invalid)?;
        if files.len() > FILES || byte_size > BYTES {
            return Err(invalid());
        }
        // Stable inventory binds every intended path, size and content digest without disclosing content.
        let inventory: Vec<_> = files.iter().map(|(path,bytes)| serde_json::json!({"path":path,"byteSize":bytes.len(),"sha256":hash(bytes)})).collect();
        let inventory_sha256 = hash(&serde_json::to_vec(&inventory).map_err(|_| invalid())?);
        Ok(Self {
            files,
            byte_size,
            inventory_sha256,
        })
    }
}
impl KnowledgePackageStageStore {
    pub fn new(path: PathBuf) -> Self {
        Self {
            root: Root::new(path),
            bindings: Mutex::new(HashMap::new()),
        }
    }
    fn root(&self) -> CommandResult<&Root> {
        let r = self.root.as_ref().ok_or_else(invalid)?;
        r.verify()?;
        Ok(r)
    }
    pub fn plan(
        &self,
        source_path: &Path,
        parent: &Path,
    ) -> CommandResult<KnowledgePackageStagePlan> {
        self.plan_checked(source_path, parent, |_| {})
    }
    fn plan_checked(
        &self,
        source_path: &Path,
        parent: &Path,
        mut hook: impl FnMut(u8),
    ) -> CommandResult<KnowledgePackageStagePlan> {
        let mut bindings = self.bindings.lock().map_err(|_| invalid())?;
        let current = now()?;
        bindings.retain(|_, b| b.created.elapsed() < TTL && b.plan.expires_at_epoch_ms > current);
        if bindings.len() >= 2 {
            return Err(invalid());
        }
        let root = self.root()?;
        let started = Instant::now();
        let source = Source::open(source_path).map_err(|_| invalid())?;
        hook(0);
        let bytes = source.read(started).map_err(|_| invalid())?;
        let staged = knowledge_package_check::validate(&bytes, started).map_err(|_| invalid())?;
        let package_sha = hash(&bytes);
        let id = Uuid::new_v4().to_string();
        let created_at_epoch_ms = now()?;
        let package = staged.report(
            id.clone(),
            source_path.to_str().ok_or_else(invalid)?.into(),
            bytes.len(),
            package_sha.clone(),
            created_at_epoch_ms,
        );
        let layout = Layout::new(staged, &id, &package_sha)?;
        hook(1);
        let target = disk::Target::new(parent, &root.path, &id)?;
        let plan = KnowledgePackageStagePlan {
            plan_id: id,
            source_path: package.source_path.clone(),
            parent_path: parent.to_str().ok_or_else(invalid)?.into(),
            candidate_path: target.path.to_str().ok_or_else(invalid)?.into(),
            format: FORMAT,
            schema_version: 1,
            package,
            candidate_file_count: layout.files.len(),
            candidate_byte_size: layout.byte_size,
            candidate_inventory_sha256: layout.inventory_sha256,
            limits: Limits {
                candidate_files: FILES,
                candidate_bytes: BYTES,
                duration_ms: 30000,
            },
            requires_sensitive_plaintext_consent: true,
            candidate_only: true,
            current_library_changed: false,
            restore_ready: false,
            created_at_epoch_ms,
            expires_at_epoch_ms: created_at_epoch_ms + 300000,
        };
        hook(2);
        source.verify().map_err(|_| invalid())?;
        target.verify()?;
        root.verify()?;
        bounded(started)?;
        if now()? >= plan.expires_at_epoch_ms {
            return Err(invalid());
        }
        bindings.insert(
            plan.plan_id.clone(),
            Binding {
                plan: plan.clone(),
                source,
                target,
                created: Instant::now(),
            },
        );
        Ok(plan)
    }
    pub fn discard(&self, id: &str) -> CommandResult<()> {
        self.bindings.lock().map_err(|_| invalid())?.remove(id);
        Ok(())
    }
    pub fn execute(
        &self,
        id: &str,
        confirm_sensitive_plaintext: bool,
    ) -> CommandResult<KnowledgePackageStageResult> {
        self.execute_checked(id, confirm_sensitive_plaintext, |_| {})
    }
    fn execute_checked(
        &self,
        id: &str,
        confirm: bool,
        mut hook: impl FnMut(u8),
    ) -> CommandResult<KnowledgePackageStageResult> {
        // Serialize bounded decoding and writing; remove before any consent/expiry/source validation.
        let mut bindings = self.bindings.lock().map_err(|_| invalid())?;
        let b = bindings.remove(id).ok_or_else(invalid)?;
        if !confirm || b.created.elapsed() >= TTL || now()? >= b.plan.expires_at_epoch_ms {
            return Err(invalid());
        }
        let root = self.root()?;
        let started = Instant::now();
        hook(0);
        let bytes = b.source.read(started).map_err(|_| invalid())?;
        if bytes.len() != b.plan.package.byte_size || hash(&bytes) != b.plan.package.sha256 {
            return Err(invalid());
        }
        let staged = knowledge_package_check::validate(&bytes, started).map_err(|_| invalid())?;
        let manifest_sha = staged.manifest_sha256.clone();
        let layout = Layout::new(staged, id, &b.plan.package.sha256)?;
        if layout.files.len() != b.plan.candidate_file_count
            || layout.byte_size != b.plan.candidate_byte_size
            || layout.inventory_sha256 != b.plan.candidate_inventory_sha256
        {
            return Err(invalid());
        }
        let check = || {
            bounded(started)?;
            if b.created.elapsed() >= TTL || now()? >= b.plan.expires_at_epoch_ms {
                return Err(invalid());
            }
            root.verify()?;
            b.target.verify()?;
            b.source.verify().map_err(|_| invalid())
        };
        hook(1);
        check()?;
        b.target.absent()?;
        // From this call onward, every error may leave a private partial candidate. Never delete it.
        let candidate = b.target.create().map_err(|_| unconfirmed())?;
        let written = (|| {
            hook(2);
            check()?;
            candidate.verify()?;
            let candidate = candidate.write(&layout, started, &mut || check(), &mut hook)?;
            hook(6);
            check()?;
            candidate.verify_contents(&layout, started)?;
            let read_started = Instant::now();
            let current = b.source.read(read_started).map_err(|_| invalid())?;
            if current.len() != b.plan.package.byte_size || hash(&current) != b.plan.package.sha256
            {
                return Err(invalid());
            }
            check()?;
            candidate.verify_contents(&layout, started)?;
            Ok(KnowledgePackageStageResult {
                plan_id: b.plan.plan_id.clone(),
                source_path: b.plan.source_path.clone(),
                candidate_path: b.plan.candidate_path.clone(),
                package_sha256: b.plan.package.sha256.clone(),
                manifest_sha256: manifest_sha,
                candidate_file_count: layout.files.len(),
                candidate_byte_size: layout.byte_size,
                candidate_inventory_sha256: layout.inventory_sha256.clone(),
                private_permissions_verified: true,
                contents_verified: true,
                source_revalidated: true,
                candidate_only: true,
                current_library_changed: false,
                restore_ready: false,
            })
        })();
        written.map_err(|_| unconfirmed())
    }
}
#[cfg(test)]
#[path = "knowledge_package_stage_tests.rs"]
mod tests;
