//! Pure reference projection. Never initialize, migrate, read files, persist or collect garbage.
use super::*;
#[derive(Clone, Debug)]
pub(crate) struct IntegrityReference {
    pub kind: &'static str,
    pub digest: String,
    pub byte_size: u64,
    pub formats: BTreeSet<String>,
}
pub(crate) struct IntegrityReferences {
    pub items: u64,
    pub revisions: u64,
    pub archive_references: u64,
    pub missing_archives: u64,
    pub truncated_archives: u64,
    pub unknown_archives: u64,
    pub files: Vec<IntegrityReference>,
}
fn invalid() -> CommandError {
    CommandError::new(
        "knowledge_integrity_invalid",
        "The saved knowledge reference manifest could not be validated.",
    )
}
fn fields(v: &serde_json::Value, allowed: &[&str]) -> CommandResult<()> {
    let obj = v.as_object().ok_or_else(invalid)?;
    if obj.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err(invalid());
    }
    Ok(())
}
fn archive_fields(v: &serde_json::Value) -> CommandResult<()> {
    if v.is_null() {
        return Ok(());
    }
    fields(
        v,
        &[
            "format",
            "byteSize",
            "embeddedResourceCount",
            "missingResourceCount",
            "wasTruncated",
            "sha256",
        ],
    )
}
pub(crate) fn project(bytes: &[u8]) -> CommandResult<IntegrityReferences> {
    let raw: serde_json::Value = serde_json::from_slice(bytes).map_err(|_| invalid())?;
    fields(
        &raw,
        &["schemaVersion", "items", "folders", "completedOperations"],
    )?;
    if raw.get("schemaVersion").and_then(|v| v.as_u64()) != Some(4) {
        return Err(invalid());
    }
    let items = raw
        .get("items")
        .and_then(|v| v.as_array())
        .ok_or_else(invalid)?;
    let folders = raw
        .get("folders")
        .and_then(|v| v.as_array())
        .ok_or_else(invalid)?;
    let operations = raw
        .get("completedOperations")
        .and_then(|v| v.as_array())
        .ok_or_else(invalid)?;
    if items.len() > MAX_ITEMS
        || folders.len() > MAX_FOLDERS
        || operations.len() > MAX_COMPLETED_OPERATIONS
    {
        return Err(invalid());
    }
    for f in folders {
        fields(f, &["folderId", "name", "createdAtEpochSeconds"])?;
    }
    for item in items {
        fields(item, &["summary", "contentSha256", "revisions"])?;
        let s = item.get("summary").ok_or_else(invalid)?;
        fields(
            s,
            &[
                "itemId",
                "title",
                "sourceKind",
                "sourceName",
                "sourceUrl",
                "byteSize",
                "createdAtEpochSeconds",
                "updatedAtEpochSeconds",
                "readingProgressPercent",
                "allowsLocalSemanticIndex",
                "allowsRemoteAiUse",
                "folderId",
                "revisionNumber",
                "revisionCount",
                "archive",
            ],
        )?;
        if let Some(a) = s.get("archive") {
            archive_fields(a)?;
        }
        let revs = item
            .get("revisions")
            .and_then(|v| v.as_array())
            .ok_or_else(invalid)?;
        if revs.len() > MAX_REVISIONS_PER_ITEM {
            return Err(invalid());
        }
        for r in revs {
            fields(
                r,
                &[
                    "revisionNumber",
                    "contentSha256",
                    "byteSize",
                    "createdAtEpochSeconds",
                    "archive",
                ],
            )?;
            if let Some(a) = r.get("archive") {
                archive_fields(a)?;
            }
        }
    }
    // Decode original bytes as well, so duplicate recognized fields are rejected by serde.
    let manifest: Manifest = serde_json::from_slice(bytes).map_err(|_| invalid())?;
    let mut folders = BTreeMap::<String, KnowledgeFolder>::new();
    for f in manifest.folders {
        validate_item_id(&f.folder_id).map_err(|_| invalid())?;
        if validate_folder_name(&f.name).map_err(|_| invalid())? != f.name
            || folders
                .values()
                .any(|other| folder_name_key(&other.name) == folder_name_key(&f.name))
            || folders.insert(f.folder_id.clone(), f).is_some()
        {
            return Err(invalid());
        }
    }
    let mut ids = BTreeSet::new();
    let mut references = BTreeMap::<(&'static str, String), IntegrityReference>::new();
    let mut result = IntegrityReferences {
        items: manifest.items.len() as u64,
        revisions: 0,
        archive_references: 0,
        missing_archives: 0,
        truncated_archives: 0,
        unknown_archives: 0,
        files: Vec::new(),
    };
    for stored in manifest.items {
        validate_stored_item(&stored).map_err(|_| invalid())?;
        if !ids.insert(stored.summary.item_id.clone())
            || stored
                .summary
                .folder_id
                .as_ref()
                .is_some_and(|id| !folders.contains_key(id))
        {
            return Err(invalid());
        }
        for revision in stored.revisions {
            result.revisions += 1;
            insert(
                &mut references,
                "body",
                &revision.content_sha256,
                revision.byte_size,
                None,
            )?;
            if let Some(a) = revision.archive {
                result.archive_references += 1;
                result.missing_archives +=
                    u64::from(a.missing_resource_count.is_some_and(|n| n > 0));
                result.truncated_archives += u64::from(a.was_truncated);
                result.unknown_archives += u64::from(
                    a.missing_resource_count.is_none() || a.embedded_resource_count.is_none(),
                );
                insert(
                    &mut references,
                    "archive",
                    &a.sha256,
                    a.byte_size,
                    Some(&a.format),
                )?;
            }
        }
    }
    let total = |kind| {
        references
            .values()
            .filter(|r| r.kind == kind)
            .map(|r| r.byte_size)
            .sum::<u64>()
    };
    if total("body") > MAX_LIBRARY_BYTES || total("archive") > MAX_ARCHIVE_LIBRARY_BYTES {
        return Err(invalid());
    }
    result.files = references.into_values().collect();
    Ok(result)
}
fn insert(
    map: &mut BTreeMap<(&'static str, String), IntegrityReference>,
    kind: &'static str,
    digest: &str,
    size: u64,
    format: Option<&str>,
) -> CommandResult<()> {
    // Generated content addresses are lowercase; never accept path syntax or alternate names.
    if digest.len() != 64
        || !digest
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(invalid());
    }
    let r = map
        .entry((kind, digest.into()))
        .or_insert_with(|| IntegrityReference {
            kind,
            digest: digest.into(),
            byte_size: size,
            formats: BTreeSet::new(),
        });
    if r.byte_size != size {
        return Err(invalid());
    }
    if let Some(f) = format {
        r.formats.insert(f.into());
    }
    Ok(())
}
pub(crate) fn content_matches(r: &IntegrityReference, bytes: &[u8]) -> bool {
    bytes.len() as u64 == r.byte_size
        && sha256_hex(bytes) == r.digest
        && if r.kind == "body" {
            std::str::from_utf8(bytes).is_ok()
        } else {
            r.formats
                .iter()
                .all(|f| archive_bytes_match_format(f, bytes))
        }
}

/// Export validates even excluded completion receipts before clearing them. Unlike loading,
/// this pure check never purges expired receipts, migrates consent or restores business state.
pub(crate) fn validate_completed_operations(bytes: &[u8]) -> CommandResult<()> {
    let raw: serde_json::Value = serde_json::from_slice(bytes).map_err(|_| invalid())?;
    let operations = raw
        .get("completedOperations")
        .and_then(|v| v.as_array())
        .ok_or_else(invalid)?;
    if operations.len() > MAX_COMPLETED_OPERATIONS {
        return Err(invalid());
    }
    for operation in operations {
        fields(
            operation,
            &[
                "operationId",
                "fingerprint",
                "completedAtEpochSeconds",
                "receipt",
            ],
        )?;
        fields(
            operation.get("receipt").ok_or_else(invalid)?,
            &[
                "documentId",
                "title",
                "action",
                "folderId",
                "fileSizeBytes",
                "archiveType",
                "allowsLocalSemanticIndex",
                "allowsRemoteAiUse",
                "savedAtEpochSeconds",
                "replayed",
            ],
        )?;
    }
    let manifest: Manifest = serde_json::from_slice(bytes).map_err(|_| invalid())?;
    let folders = manifest
        .folders
        .into_iter()
        .map(|f| (f.folder_id.clone(), f))
        .collect::<BTreeMap<_, _>>();
    let mut ids = BTreeSet::new();
    for operation in manifest.completed_operations {
        validate_completed_operation(&operation, &folders).map_err(|_| invalid())?;
        if !ids.insert(operation.operation_id) {
            return Err(invalid());
        }
    }
    Ok(())
}
