//! Untrusted saved-file package validation and transient memory staging. No library initialization,
//! migration, disk staging, filesystem writes, HTML rendering, network or restore authority.
use super::{knowledge_library::knowledge_integrity_manifest, CommandError, CommandResult};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{
    de::{DeserializeSeed, Error, MapAccess, SeqAccess, Visitor},
    Deserialize, Serialize,
};
use serde_json::{Map, Number, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashMap},
    fmt,
    path::Path,
    sync::Mutex,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;
#[path = "knowledge_package_source.rs"]
pub(super) mod source;
const TTL: Duration = Duration::from_secs(300);
const TIME: Duration = Duration::from_secs(5);
const MAX_REPORTS: usize = 2;
const MANIFEST_BYTES: usize = 2 * 1024 * 1024;
const RESOURCE_BYTES: u64 = 32 * 1024 * 1024;
const RESOURCE_FILES: usize = 1024;
const PACKAGE_BYTES: usize = 48 * 1024 * 1024;
const JSON_NODES: usize = 131072;
const FORMAT: &str = "repopress-knowledge-saved-files";
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
struct Limits {
    manifest_bytes: usize,
    resource_files: usize,
    resource_bytes: u64,
    package_bytes: usize,
    duration_ms: u64,
    json_nodes: usize,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgePackageCheckReport {
    pub report_id: String,
    pub source_path: String,
    format: &'static str,
    schema_version: u8,
    source_manifest_schema_version: u8,
    scope: &'static str,
    item_count: u64,
    revision_count: u64,
    body_file_count: usize,
    archive_file_count: usize,
    resource_byte_size: u64,
    pub byte_size: usize,
    pub sha256: String,
    manifest_sha256: String,
    exclusions: Vec<&'static str>,
    limits: Limits,
    structure_verified: bool,
    content_verified: bool,
    all_saved_references_included: bool,
    source_manifest_hash_verified: bool,
    consistent_snapshot: bool,
    includes_credential_stores: bool,
    includes_completed_operations: bool,
    external_references_included: bool,
    filesystem_writes: bool,
    current_library_changed: bool,
    restore_ready: bool,
    checked_at_epoch_ms: u64,
    expires_at_epoch_ms: u64,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgePackageMemoryPreflight {
    report_id: String,
    source_path: String,
    byte_size: usize,
    sha256: String,
    manifest_sha256: String,
    staged_file_count: usize,
    staged_byte_size: u64,
    staging: &'static str,
    source_revalidated: bool,
    filesystem_writes: bool,
    current_library_changed: bool,
    restore_ready: bool,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct PackageFile {
    path: String,
    kind: String,
    byte_size: u64,
    sha256: String,
    encoding: String,
    data: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Package {
    format: String,
    schema_version: u8,
    source_manifest_schema_version: u8,
    scope: String,
    captured_at_epoch_ms: u64,
    manifest: Value,
    manifest_sha256: String,
    source_manifest_sha256: String,
    files: Vec<PackageFile>,
    exclusions: Vec<String>,
    all_saved_references_included: bool,
    consistent_snapshot: bool,
    includes_credential_stores: bool,
    includes_completed_operations: bool,
    external_references_included: bool,
}
pub(super) struct Validated {
    pub(super) items: u64,
    pub(super) revisions: u64,
    pub(super) bodies: usize,
    pub(super) archives: usize,
    pub(super) resource_bytes: u64,
    pub(super) manifest_sha256: String,
    // Isolated payloads keyed only by generated content addresses; never use package paths for I/O.
    pub(super) files: BTreeMap<String, Vec<u8>>,
    pub(super) manifest: Vec<u8>,
}
struct Binding {
    report: KnowledgePackageCheckReport,
    source: source::Source,
    created: Instant,
}
#[derive(Default)]
pub struct KnowledgePackageCheckStore {
    bindings: Mutex<HashMap<String, Binding>>,
}
fn invalid() -> CommandError {
    CommandError::new("knowledge_package_check_invalid", "Selected package, layout, limits, hashes, source identity or report is unsafe, expired or changed. Select and inspect a private saved-file JSON package again. No filesystem staging or restore was performed.")
}
fn bounded(started: Instant) -> CommandResult<()> {
    if started.elapsed() >= TIME {
        Err(invalid())
    } else {
        Ok(())
    }
}
fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn digest(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
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
// serde_json::Value normally collapses duplicate keys. Reject them recursively before projection.
struct Budget {
    nodes: usize,
    started: Instant,
}
struct Seed<'a>(&'a mut Budget);
impl<'de> DeserializeSeed<'de> for Seed<'_> {
    type Value = Value;
    fn deserialize<D: serde::Deserializer<'de>>(self, d: D) -> Result<Value, D::Error> {
        if self.0.nodes >= JSON_NODES || self.0.started.elapsed() >= TIME {
            return Err(D::Error::custom("JSON budget exceeded"));
        }
        self.0.nodes += 1;
        d.deserialize_any(self)
    }
}
impl<'de> Visitor<'de> for Seed<'_> {
    type Value = Value;
    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("bounded JSON without duplicate keys")
    }
    fn visit_bool<E: Error>(self, v: bool) -> Result<Value, E> {
        Ok(Value::Bool(v))
    }
    fn visit_unit<E: Error>(self) -> Result<Value, E> {
        Ok(Value::Null)
    }
    fn visit_i64<E: Error>(self, v: i64) -> Result<Value, E> {
        Ok(Value::Number(v.into()))
    }
    fn visit_u64<E: Error>(self, v: u64) -> Result<Value, E> {
        Ok(Value::Number(v.into()))
    }
    fn visit_f64<E: Error>(self, v: f64) -> Result<Value, E> {
        Number::from_f64(v)
            .map(Value::Number)
            .ok_or_else(|| E::custom("invalid number"))
    }
    fn visit_str<E: Error>(self, v: &str) -> Result<Value, E> {
        Ok(Value::String(v.into()))
    }
    fn visit_string<E: Error>(self, v: String) -> Result<Value, E> {
        Ok(Value::String(v))
    }
    fn visit_seq<A: SeqAccess<'de>>(self, mut a: A) -> Result<Value, A::Error> {
        let mut v = Vec::new();
        while let Some(entry) = a.next_element_seed(Seed(&mut *self.0))? {
            v.push(entry);
        }
        Ok(Value::Array(v))
    }
    fn visit_map<A: MapAccess<'de>>(self, mut a: A) -> Result<Value, A::Error> {
        let mut v = Map::new();
        while let Some(key) = a.next_key::<String>()? {
            if v.contains_key(&key) {
                return Err(A::Error::custom("duplicate JSON key"));
            }
            v.insert(key, a.next_value_seed(Seed(&mut *self.0))?);
        }
        Ok(Value::Object(v))
    }
}
pub(super) fn parse_json(bytes: &[u8], started: Instant) -> CommandResult<Value> {
    bounded(started)?;
    if bytes.is_empty() || bytes.len() > PACKAGE_BYTES {
        return Err(invalid());
    }
    let mut deserializer = serde_json::Deserializer::from_slice(bytes);
    let raw = Seed(&mut Budget { nodes: 0, started })
        .deserialize(&mut deserializer)
        .map_err(|_| invalid())?;
    deserializer.end().map_err(|_| invalid())?;
    Ok(raw)
}
pub(super) fn validate(bytes: &[u8], started: Instant) -> CommandResult<Validated> {
    let raw = parse_json(bytes, started)?;
    if raw
        .get("files")
        .and_then(Value::as_array)
        .is_none_or(|a| a.len() > RESOURCE_FILES)
    {
        return Err(invalid());
    }
    let p: Package = serde_json::from_value(raw).map_err(|_| invalid())?;
    if p.format != FORMAT
        || p.schema_version != 1
        || p.source_manifest_schema_version != 4
        || p.scope != "applicationSavedKnowledge"
        || p.captured_at_epoch_ms == 0
        || p.captured_at_epoch_ms > 8_639_999_999_700_000
        || !digest(&p.manifest_sha256)
        || !digest(&p.source_manifest_sha256)
        || p.exclusions != EXCLUSIONS
        || !p.all_saved_references_included
        || p.consistent_snapshot
        || p.includes_credential_stores
        || p.includes_completed_operations
        || p.external_references_included
        || p.manifest
            .get("completedOperations")
            .and_then(Value::as_array)
            .is_none_or(|a| !a.is_empty())
    {
        return Err(invalid());
    }
    let manifest = serde_json::to_vec(&p.manifest).map_err(|_| invalid())?;
    if manifest.len() > MANIFEST_BYTES || hash(&manifest) != p.manifest_sha256 {
        return Err(invalid());
    }
    let refs = knowledge_integrity_manifest::project(&manifest).map_err(|_| invalid())?;
    if refs.files.len() != p.files.len()
        || refs.files.len() > RESOURCE_FILES
        || refs.missing_archives > 0
        || refs.truncated_archives > 0
        || refs.unknown_archives > 0
    {
        return Err(invalid());
    }
    let expected: BTreeMap<_, _> = refs
        .files
        .iter()
        .map(|r| {
            (
                format!(
                    "{}/{}",
                    if r.kind == "body" {
                        "blobs"
                    } else {
                        "archives"
                    },
                    r.digest
                ),
                r,
            )
        })
        .collect();
    let mut files = BTreeMap::new();
    let mut resource_bytes = 0u64;
    for f in p.files {
        bounded(started)?;
        let r = expected.get(&f.path).ok_or_else(invalid)?;
        if f.kind != r.kind
            || f.sha256 != r.digest
            || f.byte_size != r.byte_size
            || f.encoding != "base64"
            || files.contains_key(&f.path)
            || f.byte_size > RESOURCE_BYTES - resource_bytes
            || f.data.len() as u64 != 4 * f.byte_size.div_ceil(3)
        {
            return Err(invalid());
        }
        let decoded = STANDARD.decode(f.data.as_bytes()).map_err(|_| invalid())?;
        if decoded.len() as u64 != f.byte_size
            || STANDARD.encode(&decoded) != f.data
            || !knowledge_integrity_manifest::content_matches(r, &decoded)
        {
            return Err(invalid());
        }
        resource_bytes += f.byte_size;
        files.insert(f.path, decoded);
    }
    bounded(started)?;
    Ok(Validated {
        items: refs.items,
        revisions: refs.revisions,
        bodies: refs.files.iter().filter(|r| r.kind == "body").count(),
        archives: refs.files.iter().filter(|r| r.kind == "archive").count(),
        resource_bytes,
        manifest_sha256: p.manifest_sha256,
        files,
        manifest,
    })
}
impl Validated {
    pub(super) fn report(
        &self,
        id: String,
        path: String,
        byte_size: usize,
        package_sha256: String,
        checked_at_epoch_ms: u64,
    ) -> KnowledgePackageCheckReport {
        let staged = self;
        KnowledgePackageCheckReport {
            report_id: id,
            source_path: path,
            format: FORMAT,
            schema_version: 1,
            source_manifest_schema_version: 4,
            scope: "selectedKnowledgePackage",
            item_count: staged.items,
            revision_count: staged.revisions,
            body_file_count: staged.bodies,
            archive_file_count: staged.archives,
            resource_byte_size: staged.resource_bytes,
            byte_size,
            sha256: package_sha256,
            manifest_sha256: staged.manifest_sha256.clone(),
            exclusions: EXCLUSIONS.to_vec(),
            limits: Limits {
                manifest_bytes: MANIFEST_BYTES,
                resource_files: RESOURCE_FILES,
                resource_bytes: RESOURCE_BYTES,
                package_bytes: PACKAGE_BYTES,
                duration_ms: 5000,
                json_nodes: JSON_NODES,
            },
            structure_verified: true,
            content_verified: true,
            all_saved_references_included: true,
            source_manifest_hash_verified: false,
            consistent_snapshot: false,
            includes_credential_stores: false,
            includes_completed_operations: false,
            external_references_included: false,
            filesystem_writes: false,
            current_library_changed: false,
            restore_ready: false,
            checked_at_epoch_ms,
            expires_at_epoch_ms: checked_at_epoch_ms + 300_000,
        }
    }
}

impl KnowledgePackageCheckStore {
    pub fn inspect(&self, path: &Path) -> CommandResult<KnowledgePackageCheckReport> {
        self.inspect_checked(path, |_| {})
    }
    fn inspect_checked(
        &self,
        path: &Path,
        mut hook: impl FnMut(u8),
    ) -> CommandResult<KnowledgePackageCheckReport> {
        // Serialize bounded parsing/decoding, preventing renderer requests from multiplying memory use.
        let mut bindings = self.bindings.lock().map_err(|_| invalid())?;
        bindings.retain(|_, b| b.created.elapsed() < TTL);
        if bindings.len() >= MAX_REPORTS {
            return Err(invalid());
        }
        let started = Instant::now();
        let source = source::Source::open(path)?;
        hook(0);
        let bytes = source.read(started)?;
        hook(1);
        let staged = validate(&bytes, started)?;
        let package_sha256 = hash(&bytes);
        hook(2);
        source.verify()?;
        bounded(started)?;
        let checked_at_epoch_ms = now()?;
        let report = staged.report(
            Uuid::new_v4().to_string(),
            path.to_str().ok_or_else(invalid)?.into(),
            bytes.len(),
            package_sha256,
            checked_at_epoch_ms,
        );
        bindings.insert(
            report.report_id.clone(),
            Binding {
                report: report.clone(),
                source,
                created: Instant::now(),
            },
        );
        Ok(report)
    }
    pub fn discard(&self, id: &str) -> CommandResult<()> {
        self.bindings.lock().map_err(|_| invalid())?.remove(id);
        Ok(())
    }
    pub fn preflight(&self, id: &str) -> CommandResult<KnowledgePackageMemoryPreflight> {
        self.preflight_checked(id, |_| {})
    }
    fn preflight_checked(
        &self,
        id: &str,
        mut hook: impl FnMut(u8),
    ) -> CommandResult<KnowledgePackageMemoryPreflight> {
        let mut bindings = self.bindings.lock().map_err(|_| invalid())?;
        let b = bindings.remove(id).ok_or_else(invalid)?;
        // Consume even on expiry, drift or failure. Hold the lock throughout bounded memory staging.
        if b.created.elapsed() >= TTL || now()? >= b.report.expires_at_epoch_ms {
            return Err(invalid());
        }
        let started = Instant::now();
        hook(0);
        let bytes = b.source.read(started)?;
        if bytes.len() != b.report.byte_size || hash(&bytes) != b.report.sha256 {
            return Err(invalid());
        }
        hook(1);
        let staged = validate(&bytes, started)?;
        hook(2);
        b.source.verify()?;
        bounded(started)?;
        if b.created.elapsed() >= TTL || now()? >= b.report.expires_at_epoch_ms {
            return Err(invalid());
        }
        if staged.manifest_sha256 != b.report.manifest_sha256
            || staged.resource_bytes != b.report.resource_byte_size
            || staged.files.len() != b.report.body_file_count + b.report.archive_file_count
            || staged.manifest.is_empty()
        {
            return Err(invalid());
        }
        let result = KnowledgePackageMemoryPreflight {
            report_id: b.report.report_id,
            source_path: b.report.source_path,
            byte_size: b.report.byte_size,
            sha256: b.report.sha256,
            manifest_sha256: staged.manifest_sha256,
            staged_file_count: staged.files.len(),
            staged_byte_size: staged.resource_bytes,
            staging: "ephemeralMemory",
            source_revalidated: true,
            filesystem_writes: false,
            current_library_changed: false,
            restore_ready: false,
        };
        // Dropping `staged` releases decoded resources; neither a persistent stage nor a restore token exists.
        Ok(result)
    }
}
#[cfg(test)]
#[path = "knowledge_package_check_tests.rs"]
mod tests;
