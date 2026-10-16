use super::{
    CommandError, CommandResult, DeleteMarkdownDocumentResult, DocumentSnapshot, LineEnding,
    MarkdownFileEntry, MarkdownLinkMetadata, RepositorySessionSnapshot, WritingImageImportResult,
};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::ffi::OsStr;
use std::fs;
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::Mutex;
use tempfile::Builder;
use uuid::Uuid;

const MAX_DOCUMENT_BYTES: u64 = 4 * 1024 * 1024;
const MAX_WRITING_IMAGE_BYTES: u64 = 20 * 1024 * 1024;
const MAX_MARKDOWN_FILES: usize = 100_000;
const MAX_SCAN_DEPTH: usize = 64;
const EXCLUDED_DIRECTORIES: &[&str] = &[
    ".git",
    ".build",
    ".swiftpm",
    "node_modules",
    "target",
    "vendor",
];

#[derive(Debug)]
struct DocumentRecord {
    relative_path: PathBuf,
    encoding: String,
    line_ending: LineEnding,
    baseline_sha256: String,
    revision: u64,
    writable: bool,
    read_only_reason: Option<String>,
}

/// A live, validated document binding for private history operations. This deliberately keeps
/// the filesystem path private to `RepositoryStore`; callers receive repository identity and
/// decoded text only after presenting a session-bound document id and its current baseline.
#[derive(Clone, Debug)]
pub struct DocumentHistoryContext {
    pub root: PathBuf,
    pub relative_path: String,
    pub text: String,
    pub baseline_sha256: String,
}

#[derive(Debug)]
struct RepositorySession {
    root: PathBuf,
    content_root: Option<PathBuf>,
    documents: HashMap<String, DocumentRecord>,
}

#[derive(Default, Debug)]
pub struct RepositoryStore {
    sessions: Mutex<HashMap<String, RepositorySession>>,
    /// Coordinates recovery writes with document saves. It is intentionally separate from the
    /// session map so recovery persistence never holds the session mutex during disk I/O.
    recovery_gate: Mutex<()>,
}

impl RepositoryStore {
    pub fn open_repository(&self, path: &str) -> CommandResult<RepositorySessionSnapshot> {
        let requested = Path::new(path);
        if !requested.is_absolute() {
            return Err(CommandError::new(
                "repository_path_not_absolute",
                "Repository path must be absolute.",
            ));
        }

        let metadata = fs::symlink_metadata(requested).map_err(|error| {
            CommandError::io(
                "repository_unavailable",
                "Unable to inspect the selected repository",
                error,
            )
        })?;
        if metadata.file_type().is_symlink() {
            return Err(CommandError::new(
                "repository_root_is_symlink",
                "A symbolic link cannot be used as the repository root.",
            ));
        }
        if !metadata.is_dir() {
            return Err(CommandError::new(
                "repository_not_directory",
                "The selected repository path is not a directory.",
            ));
        }

        let root = fs::canonicalize(requested).map_err(|error| {
            CommandError::io(
                "repository_unavailable",
                "Unable to resolve the selected repository",
                error,
            )
        })?;
        let content_root = safe_content_root(&root);
        let is_git_repository = root.join(".git").exists();
        let mut warnings = Vec::new();
        if !is_git_repository {
            warnings.push("not_git_repository".to_string());
        }
        if content_root.is_none() {
            warnings.push("content_directory_not_found".to_string());
        }

        let session_id = Uuid::new_v4().to_string();
        let snapshot = RepositorySessionSnapshot {
            session_id: session_id.clone(),
            root_path: root.to_string_lossy().into_owned(),
            display_name: root
                .file_name()
                .and_then(OsStr::to_str)
                .unwrap_or("Repository")
                .to_string(),
            site_kind: detect_site_kind(&root),
            content_root: content_root
                .as_ref()
                .and_then(|path| path.strip_prefix(&root).ok())
                .map(path_to_portable_string),
            is_git_repository,
            warnings,
        };

        let mut sessions = self.lock_sessions()?;
        sessions.insert(
            session_id,
            RepositorySession {
                root,
                content_root,
                documents: HashMap::new(),
            },
        );
        Ok(snapshot)
    }

    pub fn list_markdown_files(&self, session_id: &str) -> CommandResult<Vec<MarkdownFileEntry>> {
        let (root, scan_root) = {
            let sessions = self.lock_sessions()?;
            let session = sessions.get(session_id).ok_or_else(session_not_found)?;
            revalidate_root(&session.root)?;
            (
                session.root.clone(),
                session
                    .content_root
                    .clone()
                    .unwrap_or_else(|| session.root.clone()),
            )
        };

        let mut entries = Vec::new();
        scan_markdown_files(&root, &scan_root, 0, &mut entries)?;
        entries.sort_by(|left, right| left.relative_path.cmp(&right.relative_path));
        Ok(entries)
    }

    pub fn open_document(
        &self,
        session_id: &str,
        relative_path: &str,
    ) -> CommandResult<DocumentSnapshot> {
        let root = self.root_for_session(session_id)?;
        let relative = validate_markdown_relative_path(relative_path)?;
        let file_path = resolve_existing_file(&root, &relative)?;
        let metadata = fs::metadata(&file_path).map_err(|error| {
            CommandError::io(
                "document_unavailable",
                "Unable to inspect the selected document",
                error,
            )
        })?;
        if !metadata.is_file() {
            return Err(CommandError::new(
                "document_not_file",
                "The selected document is not a regular file.",
            ));
        }
        if metadata.len() > MAX_DOCUMENT_BYTES {
            return Err(CommandError::new(
                "document_too_large",
                format!("Documents larger than {MAX_DOCUMENT_BYTES} bytes are not supported."),
            ));
        }

        let bytes = fs::read(&file_path).map_err(|error| {
            CommandError::io(
                "document_unavailable",
                "Unable to read the selected document",
                error,
            )
        })?;
        let decoded = decode_document(&bytes)?;
        let document_id = Uuid::new_v4().to_string();
        let baseline_sha256 = sha256_hex(&bytes);
        let record = DocumentRecord {
            relative_path: relative.clone(),
            encoding: decoded.encoding.clone(),
            line_ending: decoded.line_ending,
            baseline_sha256: baseline_sha256.clone(),
            revision: 1,
            writable: decoded.writable,
            read_only_reason: decoded.read_only_reason.clone(),
        };

        let snapshot = DocumentSnapshot {
            document_id: document_id.clone(),
            relative_path: path_to_portable_string(&relative),
            text: decoded.text,
            encoding: decoded.encoding,
            line_ending: decoded.line_ending,
            byte_size: bytes.len() as u64,
            baseline_sha256,
            revision: 1,
            writable: decoded.writable,
            read_only_reason: decoded.read_only_reason,
        };

        let mut sessions = self.lock_sessions()?;
        let session = sessions.get_mut(session_id).ok_or_else(session_not_found)?;
        revalidate_root(&session.root)?;
        session.documents.insert(document_id, record);
        Ok(snapshot)
    }

    /// Release a temporary document binding owned by a batch operation, never an editor binding.
    pub(crate) fn release_internal_document(
        &self,
        session_id: &str,
        document_id: &str,
    ) -> CommandResult<()> {
        if let Some(session) = self.lock_sessions()?.get_mut(session_id) {
            session.documents.remove(document_id);
        }
        Ok(())
    }

    pub fn inspect_markdown_link_metadata(
        &self,
        session_id: &str,
        relative_path: &str,
    ) -> CommandResult<MarkdownLinkMetadata> {
        let root = self.root_for_session(session_id)?;
        let relative = validate_markdown_relative_path(relative_path)?;
        let file_path = resolve_existing_file(&root, &relative)?;
        let metadata = fs::metadata(&file_path).map_err(|error| {
            CommandError::io(
                "document_unavailable",
                "Unable to inspect the selected document",
                error,
            )
        })?;
        if !metadata.is_file() {
            return Err(CommandError::new(
                "document_not_file",
                "The selected document is not a regular file.",
            ));
        }
        if metadata.len() > MAX_DOCUMENT_BYTES {
            return Err(CommandError::new(
                "document_too_large",
                format!("Documents larger than {MAX_DOCUMENT_BYTES} bytes are not supported."),
            ));
        }
        let bytes = fs::read(&file_path).map_err(|error| {
            CommandError::io(
                "document_unavailable",
                "Unable to read the selected document",
                error,
            )
        })?;
        let decoded = decode_document(&bytes)?;
        let fields = parse_markdown_front_matter(&decoded.text);
        Ok(MarkdownLinkMetadata {
            relative_path: path_to_portable_string(&relative),
            title: fields.0,
            slug: fields.1,
            permalink: fields.2,
        })
    }

    pub fn save_document(
        &self,
        session_id: &str,
        document_id: &str,
        text: &str,
        expected_sha256: &str,
    ) -> CommandResult<DocumentSnapshot> {
        if text.contains('\r') {
            return Err(CommandError::new(
                "invalid_document_line_endings",
                "Editor text must use normalized LF line endings.",
            ));
        }

        let mut sessions = self.lock_sessions()?;
        let session = sessions.get_mut(session_id).ok_or_else(session_not_found)?;
        revalidate_root(&session.root)?;
        let record = session.documents.get_mut(document_id).ok_or_else(|| {
            CommandError::new("document_session_not_found", "Document session expired.")
        })?;

        if !record.writable {
            return Err(CommandError::new(
                "document_read_only",
                record
                    .read_only_reason
                    .clone()
                    .unwrap_or_else(|| "The document is read-only.".to_string()),
            ));
        }
        if expected_sha256 != record.baseline_sha256 {
            return Err(save_conflict());
        }

        let file_path = resolve_existing_file(&session.root, &record.relative_path)?;
        let current_bytes = fs::read(&file_path).map_err(|error| {
            CommandError::io(
                "document_unavailable",
                "Unable to re-read the document before saving",
                error,
            )
        })?;
        if sha256_hex(&current_bytes) != expected_sha256 {
            return Err(save_conflict());
        }

        let output = encode_document(text, &record.encoding, record.line_ending)?;
        if output.len() as u64 > MAX_DOCUMENT_BYTES {
            return Err(CommandError::new(
                "document_too_large",
                format!("Documents larger than {MAX_DOCUMENT_BYTES} bytes are not supported."),
            ));
        }
        atomic_replace(&file_path, &output)?;

        record.baseline_sha256 = sha256_hex(&output);
        record.revision += 1;
        Ok(DocumentSnapshot {
            document_id: document_id.to_string(),
            relative_path: path_to_portable_string(&record.relative_path),
            text: text.to_string(),
            encoding: record.encoding.clone(),
            line_ending: record.line_ending,
            byte_size: output.len() as u64,
            baseline_sha256: record.baseline_sha256.clone(),
            revision: record.revision,
            writable: record.writable,
            read_only_reason: record.read_only_reason.clone(),
        })
    }

    pub fn create_markdown_document(
        &self,
        session_id: &str,
        relative_path: &str,
        initial_text: &str,
    ) -> CommandResult<DocumentSnapshot> {
        if initial_text.contains('\r') {
            return Err(CommandError::new(
                "invalid_document_line_endings",
                "Editor text must use normalized LF line endings.",
            ));
        }
        if initial_text.len() as u64 > MAX_DOCUMENT_BYTES {
            return Err(CommandError::new(
                "document_too_large",
                format!("Documents larger than {MAX_DOCUMENT_BYTES} bytes are not supported."),
            ));
        }

        let relative = validate_new_markdown_relative_path(relative_path)?;
        let mut sessions = self.lock_sessions()?;
        let session = sessions.get_mut(session_id).ok_or_else(session_not_found)?;
        revalidate_root(&session.root)?;
        ensure_writable_document_location(session, &relative)?;
        let file_path = resolve_new_file_path(&session.root, &relative)?;
        atomic_create(&file_path, initial_text.as_bytes())?;

        let document_id = Uuid::new_v4().to_string();
        let baseline_sha256 = sha256_hex(initial_text.as_bytes());
        let record = DocumentRecord {
            relative_path: relative.clone(),
            encoding: "utf-8".to_string(),
            line_ending: LineEnding::Lf,
            baseline_sha256: baseline_sha256.clone(),
            revision: 1,
            writable: true,
            read_only_reason: None,
        };
        session.documents.insert(document_id.clone(), record);
        Ok(DocumentSnapshot {
            document_id,
            relative_path: path_to_portable_string(&relative),
            text: initial_text.to_string(),
            encoding: "utf-8".to_string(),
            line_ending: LineEnding::Lf,
            byte_size: initial_text.len() as u64,
            baseline_sha256,
            revision: 1,
            writable: true,
            read_only_reason: None,
        })
    }

    pub fn rename_markdown_document(
        &self,
        session_id: &str,
        document_id: &str,
        new_relative_path: &str,
        expected_sha256: &str,
    ) -> CommandResult<DocumentSnapshot> {
        let new_relative = validate_new_markdown_relative_path(new_relative_path)?;
        let mut sessions = self.lock_sessions()?;
        let session = sessions.get_mut(session_id).ok_or_else(session_not_found)?;
        revalidate_root(&session.root)?;
        ensure_writable_document_location(session, &new_relative)?;
        let record = session.documents.get_mut(document_id).ok_or_else(|| {
            CommandError::new("document_session_not_found", "Document session expired.")
        })?;
        if !record.writable {
            return Err(CommandError::new(
                "document_read_only",
                record
                    .read_only_reason
                    .clone()
                    .unwrap_or_else(|| "The document is read-only.".to_string()),
            ));
        }
        if expected_sha256 != record.baseline_sha256 {
            return Err(save_conflict());
        }

        let source_path = resolve_existing_file(&session.root, &record.relative_path)?;
        let source_bytes = fs::read(&source_path).map_err(|error| {
            CommandError::io(
                "document_unavailable",
                "Unable to re-read the document before renaming",
                error,
            )
        })?;
        if sha256_hex(&source_bytes) != expected_sha256 {
            return Err(save_conflict());
        }
        let decoded = decode_document(&source_bytes)?;
        let destination_path = resolve_new_file_path(&session.root, &new_relative)?;
        // `rename` would replace a destination created by another process between our checks.
        // Linking a regular source file first gives this operation no-clobber semantics on Linux;
        // unlinking the old name then completes the move inside the same repository filesystem.
        fs::hard_link(&source_path, &destination_path).map_err(|error| {
            CommandError::io(
                "document_rename_failed",
                "Unable to rename the document without replacing an existing file",
                error,
            )
        })?;
        if let Err(error) = fs::remove_file(&source_path) {
            // Keep the original document usable if unlinking fails after the no-clobber link.
            // The cleanup is best effort; returning an error avoids updating the session record.
            let _ = fs::remove_file(&destination_path);
            return Err(CommandError::io(
                "document_rename_failed",
                "Unable to remove the original document after creating its new name",
                error,
            ));
        }

        record.relative_path = new_relative.clone();
        record.revision += 1;
        Ok(DocumentSnapshot {
            document_id: document_id.to_string(),
            relative_path: path_to_portable_string(&new_relative),
            text: decoded.text,
            encoding: record.encoding.clone(),
            line_ending: record.line_ending,
            byte_size: source_bytes.len() as u64,
            baseline_sha256: record.baseline_sha256.clone(),
            revision: record.revision,
            writable: record.writable,
            read_only_reason: record.read_only_reason.clone(),
        })
    }

    pub fn delete_markdown_document(
        &self,
        session_id: &str,
        document_id: &str,
        expected_sha256: &str,
    ) -> CommandResult<DeleteMarkdownDocumentResult> {
        let mut sessions = self.lock_sessions()?;
        let session = sessions.get_mut(session_id).ok_or_else(session_not_found)?;
        revalidate_root(&session.root)?;
        let record = session.documents.get(document_id).ok_or_else(|| {
            CommandError::new("document_session_not_found", "Document session expired.")
        })?;
        if !record.writable {
            return Err(CommandError::new(
                "document_read_only",
                record
                    .read_only_reason
                    .clone()
                    .unwrap_or_else(|| "The document is read-only.".to_string()),
            ));
        }
        if expected_sha256 != record.baseline_sha256 {
            return Err(save_conflict());
        }
        let relative_path = record.relative_path.clone();
        let file_path = resolve_existing_file(&session.root, &relative_path)?;
        let current_bytes = fs::read(&file_path).map_err(|error| {
            CommandError::io(
                "document_unavailable",
                "Unable to re-read the document before deleting",
                error,
            )
        })?;
        if sha256_hex(&current_bytes) != expected_sha256 {
            return Err(save_conflict());
        }
        fs::remove_file(&file_path).map_err(|error| {
            CommandError::io(
                "document_delete_failed",
                "Unable to delete the document",
                error,
            )
        })?;
        session.documents.remove(document_id);
        Ok(DeleteMarkdownDocumentResult {
            relative_path: path_to_portable_string(&relative_path),
            // Command integration replaces this with the durable private recycle identifier.
            // Keeping the core store filesystem-only preserves its direct unit-test boundary.
            recycle_id: String::new(),
        })
    }

    /// Copies a user-selected image into a public site directory. The document binding prevents
    /// this command from becoming a generic arbitrary-path file writer: a live, writable document
    /// in the caller's repository session is required before an asset can be created.
    pub fn import_writing_image(
        &self,
        session_id: &str,
        source_path: &str,
        document_id: &str,
    ) -> CommandResult<WritingImageImportResult> {
        let source = Path::new(source_path);
        if !source.is_absolute() {
            return Err(CommandError::new(
                "image_source_path_not_absolute",
                "Image source path must be absolute.",
            ));
        }

        let (root, site_kind, content_root) = {
            let sessions = self.lock_sessions()?;
            let session = sessions.get(session_id).ok_or_else(session_not_found)?;
            revalidate_root(&session.root)?;
            let document = session.documents.get(document_id).ok_or_else(|| {
                CommandError::new("document_session_not_found", "Document session expired.")
            })?;
            if !document.writable {
                return Err(CommandError::new(
                    "document_read_only",
                    document
                        .read_only_reason
                        .clone()
                        .unwrap_or_else(|| "The document is read-only.".to_string()),
                ));
            }
            // Ensure the document identity is still a normal file within this repository before
            // creating an otherwise-unreferenced asset.
            let _ = resolve_existing_file(&session.root, &document.relative_path)?;
            (
                session.root.clone(),
                detect_site_kind(&session.root),
                session.content_root.clone(),
            )
        };

        let (bytes, format) = read_verified_image(source)?;
        let asset_target = writing_image_target(&site_kind, content_root.as_deref(), &root)?;
        let destination_directory = resolve_asset_directory(&root, &asset_target.directory)?;
        let stem = sanitized_asset_stem(source);
        let (destination, file_name) = atomic_create_image_with_suffix(
            &destination_directory,
            &stem,
            format.extension(),
            &bytes,
        )?;
        let relative_path = destination.strip_prefix(&root).map_err(|_| {
            CommandError::new(
                "repository_identity_changed",
                "The image destination escaped the opened repository.",
            )
        })?;
        let markdown_path = format!("{}/{}", asset_target.public_prefix, file_name);
        Ok(WritingImageImportResult {
            relative_path: path_to_portable_string(relative_path),
            markdown_path,
            file_name,
            byte_size: bytes.len() as u64,
            mime_type: format.mime_type().to_string(),
        })
    }

    pub fn root_for_session(&self, session_id: &str) -> CommandResult<PathBuf> {
        let sessions = self.lock_sessions()?;
        let session = sessions.get(session_id).ok_or_else(session_not_found)?;
        revalidate_root(&session.root)?;
        Ok(session.root.clone())
    }

    /// Checks a prospective Markdown import destination without creating any directories or
    /// accepting a filesystem path from outside the live repository session.  Transfer planning
    /// uses this to report an occupied target before `create_markdown_document` enforces the
    /// same no-clobber guarantee at execution time.
    pub fn markdown_import_target_available(
        &self,
        session_id: &str,
        relative_path: &str,
    ) -> CommandResult<bool> {
        let relative = validate_new_markdown_relative_path(relative_path)?;
        let sessions = self.lock_sessions()?;
        let session = sessions.get(session_id).ok_or_else(session_not_found)?;
        revalidate_root(&session.root)?;
        ensure_writable_document_location(session, &relative)?;
        inspect_new_file_path(&session.root, &relative)
    }

    pub fn document_context_for_session(
        &self,
        session_id: &str,
        document_id: &str,
    ) -> CommandResult<(PathBuf, u64, bool)> {
        let sessions = self.lock_sessions()?;
        let session = sessions.get(session_id).ok_or_else(session_not_found)?;
        revalidate_root(&session.root)?;
        let document = session.documents.get(document_id).ok_or_else(|| {
            CommandError::new("document_session_not_found", "Document session expired.")
        })?;
        Ok((session.root.clone(), document.revision, document.writable))
    }

    /// Returns only the live document identity needed by crash recovery. The baseline is the
    /// server-side baseline, never a value supplied by the renderer.
    pub fn recovery_context_for_session(
        &self,
        session_id: &str,
        document_id: &str,
    ) -> CommandResult<(PathBuf, String, String, bool)> {
        let sessions = self.lock_sessions()?;
        let session = sessions.get(session_id).ok_or_else(session_not_found)?;
        revalidate_root(&session.root)?;
        let document = session.documents.get(document_id).ok_or_else(|| {
            CommandError::new("document_session_not_found", "Document session expired.")
        })?;
        Ok((
            session.root.clone(),
            path_to_portable_string(&document.relative_path),
            document.baseline_sha256.clone(),
            document.writable,
        ))
    }

    /// Metadata only: an emergency copy must remain possible if the source
    /// repository was removed/unmounted. This grants no filesystem authority.
    pub fn recovery_export_context(
        &self,
        session_id: &str,
        document_id: &str,
    ) -> CommandResult<(PathBuf, String, String)> {
        let sessions = self.lock_sessions()?;
        let session = sessions.get(session_id).ok_or_else(session_not_found)?;
        let document = session.documents.get(document_id).ok_or_else(|| {
            CommandError::new("document_session_not_found", "Document session expired.")
        })?;
        Ok((
            session.root.clone(),
            path_to_portable_string(&document.relative_path),
            document.baseline_sha256.clone(),
        ))
    }

    /// Validates the live binding and re-reads its current on-disk content before a history
    /// record is created. In particular, an arbitrary history command cannot turn a renderer
    /// supplied path into filesystem authority.
    pub fn history_context_for_session(
        &self,
        session_id: &str,
        document_id: &str,
        expected_sha256: &str,
    ) -> CommandResult<DocumentHistoryContext> {
        let (root, relative_path, baseline_sha256, writable, read_only_reason) = {
            let sessions = self.lock_sessions()?;
            let session = sessions.get(session_id).ok_or_else(session_not_found)?;
            revalidate_root(&session.root)?;
            let document = session.documents.get(document_id).ok_or_else(|| {
                CommandError::new("document_session_not_found", "Document session expired.")
            })?;
            (
                session.root.clone(),
                document.relative_path.clone(),
                document.baseline_sha256.clone(),
                document.writable,
                document.read_only_reason.clone(),
            )
        };
        if !writable {
            return Err(CommandError::new(
                "document_read_only",
                read_only_reason.unwrap_or_else(|| "The document is read-only.".to_string()),
            ));
        }
        if expected_sha256 != baseline_sha256 {
            return Err(save_conflict());
        }
        let file_path = resolve_existing_file(&root, &relative_path)?;
        let bytes = fs::read(&file_path).map_err(|error| {
            CommandError::io(
                "document_unavailable",
                "Unable to re-read the document for history",
                error,
            )
        })?;
        if sha256_hex(&bytes) != baseline_sha256 {
            return Err(save_conflict());
        }
        let decoded = decode_document(&bytes)?;
        Ok(DocumentHistoryContext {
            root,
            relative_path: path_to_portable_string(&relative_path),
            text: decoded.text,
            baseline_sha256,
        })
    }

    pub fn lock_recovery_operation(&self) -> CommandResult<std::sync::MutexGuard<'_, ()>> {
        self.recovery_gate.lock().map_err(|_| {
            CommandError::new(
                "repository_state_unavailable",
                "Repository state is temporarily unavailable.",
            )
        })
    }

    /// Return the validated repository root and the session's content root.
    /// No filesystem scan is performed while the session mutex is held.
    pub fn search_roots_for_session(&self, session_id: &str) -> CommandResult<(PathBuf, PathBuf)> {
        let (root, content_root) = {
            let sessions = self.lock_sessions()?;
            let session = sessions.get(session_id).ok_or_else(session_not_found)?;
            revalidate_root(&session.root)?;
            (session.root.clone(), session.content_root.clone())
        };

        let scan_root = if let Some(content_root) = content_root {
            if !is_existing_directory_without_symlink(&content_root) {
                return Err(CommandError::new(
                    "repository_identity_changed",
                    "The repository content directory changed after it was opened.",
                ));
            }
            fs::canonicalize(&content_root).map_err(|error| {
                CommandError::io(
                    "repository_unavailable",
                    "Unable to resolve the repository content directory",
                    error,
                )
            })?
        } else {
            root.clone()
        };
        if !scan_root.starts_with(&root) {
            return Err(CommandError::new(
                "repository_identity_changed",
                "The repository content directory is outside the opened repository.",
            ));
        }
        Ok((root, scan_root))
    }

    pub fn site_context_for_session(&self, session_id: &str) -> CommandResult<(PathBuf, String)> {
        let root = {
            let sessions = self.lock_sessions()?;
            let session = sessions.get(session_id).ok_or_else(session_not_found)?;
            revalidate_root(&session.root)?;
            session.root.clone()
        };
        Ok((root.clone(), detect_site_kind(&root)))
    }

    fn lock_sessions(
        &self,
    ) -> CommandResult<std::sync::MutexGuard<'_, HashMap<String, RepositorySession>>> {
        self.sessions.lock().map_err(|_| {
            CommandError::new(
                "repository_state_unavailable",
                "Repository state is temporarily unavailable.",
            )
        })
    }
}

fn session_not_found() -> CommandError {
    CommandError::new(
        "repository_session_not_found",
        "Repository session expired.",
    )
}

fn save_conflict() -> CommandError {
    CommandError::new(
        "save_conflict",
        "The document changed on disk after it was opened. Reload before saving.",
    )
}

fn safe_content_root(root: &Path) -> Option<PathBuf> {
    // Prefer the conventional roots used by the static-site families RepoPress already detects.
    // The first match remains conservative: every component must be an ordinary directory and
    // the canonical result must stay under the already-canonical repository root.
    ["content", "source/_posts", "_posts", "src/content"]
        .into_iter()
        .map(|relative| root.join(relative))
        .find(|candidate| {
            let mut current = root.to_path_buf();
            let relative = candidate.strip_prefix(root).ok();
            let safe_components =
                relative
                    .into_iter()
                    .flat_map(Path::components)
                    .all(|component| {
                        let Component::Normal(name) = component else {
                            return false;
                        };
                        current.push(name);
                        fs::symlink_metadata(&current)
                            .map(|metadata| metadata.is_dir() && !metadata.file_type().is_symlink())
                            .unwrap_or(false)
                    });
            safe_components
                && fs::canonicalize(candidate)
                    .map(|canonical| canonical.starts_with(root))
                    .unwrap_or(false)
        })
}

fn is_existing_directory_without_symlink(path: &Path) -> bool {
    fs::symlink_metadata(path)
        .map(|metadata| metadata.is_dir() && !metadata.file_type().is_symlink())
        .unwrap_or(false)
}

fn ensure_writable_document_location(
    session: &RepositorySession,
    relative: &Path,
) -> CommandResult<()> {
    let Some(content_root) = &session.content_root else {
        return Ok(());
    };
    if !is_existing_directory_without_symlink(content_root) {
        return Err(CommandError::new(
            "repository_identity_changed",
            "The repository content directory changed after it was opened.",
        ));
    }
    let canonical_content_root = fs::canonicalize(content_root).map_err(|error| {
        CommandError::io(
            "repository_unavailable",
            "Unable to resolve the repository content directory",
            error,
        )
    })?;
    if !canonical_content_root.starts_with(&session.root) {
        return Err(CommandError::new(
            "repository_identity_changed",
            "The repository content directory is outside the opened repository.",
        ));
    }
    let content_relative = canonical_content_root
        .strip_prefix(&session.root)
        .map_err(|_| {
            CommandError::new(
                "repository_identity_changed",
                "The repository content directory changed after it was opened.",
            )
        })?;
    if !relative.starts_with(content_relative) {
        return Err(CommandError::new(
            "document_outside_content_root",
            "New documents must be located inside the repository content directory.",
        ));
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WritingImageFormat {
    Png,
    Jpeg,
    Gif,
    Webp,
}

impl WritingImageFormat {
    fn extension(self) -> &'static str {
        match self {
            Self::Png => "png",
            Self::Jpeg => "jpg",
            Self::Gif => "gif",
            Self::Webp => "webp",
        }
    }

    fn mime_type(self) -> &'static str {
        match self {
            Self::Png => "image/png",
            Self::Jpeg => "image/jpeg",
            Self::Gif => "image/gif",
            Self::Webp => "image/webp",
        }
    }

    fn accepts_extension(self, extension: &str) -> bool {
        match self {
            Self::Png => extension.eq_ignore_ascii_case("png"),
            Self::Jpeg => {
                extension.eq_ignore_ascii_case("jpg") || extension.eq_ignore_ascii_case("jpeg")
            }
            Self::Gif => extension.eq_ignore_ascii_case("gif"),
            Self::Webp => extension.eq_ignore_ascii_case("webp"),
        }
    }
}

struct WritingImageTarget {
    directory: PathBuf,
    public_prefix: String,
}

/// Mirrors the desktop publishing profiles. Unknown repositories deliberately use `static/`,
/// never the document content directory, because content roots are not universally public
/// directories.
fn writing_image_target(
    site_kind: &str,
    content_root: Option<&Path>,
    root: &Path,
) -> CommandResult<WritingImageTarget> {
    let year = current_image_year();
    let (directory, public_prefix, includes_year) = match site_kind {
        "hugo" | "zola" => (PathBuf::from("static/images"), "/images", true),
        "astro" | "nextjs" => (PathBuf::from("public/images"), "/images", true),
        "vitepress" => (PathBuf::from("docs/public/images"), "/images", true),
        "hexo" => (PathBuf::from("source/images"), "/images", true),
        "jekyll" => (PathBuf::from("assets/images"), "/assets/images", true),
        "quartz" => (PathBuf::from("content/attachments"), "/attachments", false),
        "foam" => (PathBuf::from("attachments"), "/attachments", false),
        // Sessions created before the precise Hexo/Jekyll detection existed retain the safest
        // compatible mapping based on their already-validated content root.
        "jekyll-or-hexo"
            if content_root
                .and_then(|path| path.strip_prefix(root).ok())
                .is_some_and(|path| path == Path::new("source/_posts")) =>
        {
            (PathBuf::from("source/images"), "/images", true)
        }
        "jekyll-or-hexo" => (PathBuf::from("assets/images"), "/assets/images", true),
        _ => (PathBuf::from("static/images"), "/images", true),
    };
    let directory = if includes_year {
        directory.join(&year)
    } else {
        directory
    };
    let public_prefix = if includes_year {
        format!("{public_prefix}/{year}")
    } else {
        public_prefix.to_string()
    };
    Ok(WritingImageTarget {
        directory,
        public_prefix,
    })
}

fn current_image_year() -> String {
    time::OffsetDateTime::now_utc().year().to_string()
}

fn read_verified_image(source: &Path) -> CommandResult<(Vec<u8>, WritingImageFormat)> {
    let metadata = fs::symlink_metadata(source).map_err(|error| {
        CommandError::io(
            "image_source_unavailable",
            "Unable to inspect the selected image",
            error,
        )
    })?;
    if metadata.file_type().is_symlink() {
        return Err(CommandError::new(
            "image_source_is_symlink",
            "Symbolic links cannot be imported as writing images.",
        ));
    }
    if !metadata.is_file() {
        return Err(CommandError::new(
            "image_source_not_regular_file",
            "The selected image must be a regular file.",
        ));
    }
    if metadata.len() > MAX_WRITING_IMAGE_BYTES {
        return Err(CommandError::new(
            "image_too_large",
            format!("Images larger than {MAX_WRITING_IMAGE_BYTES} bytes are not supported."),
        ));
    }

    #[cfg(unix)]
    let file = {
        use std::os::unix::fs::OpenOptionsExt;
        fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(source)
    };
    #[cfg(not(unix))]
    let mut file = fs::File::open(source);
    let mut file = file.map_err(|error| {
        CommandError::io(
            "image_source_unavailable",
            "Unable to open the selected image",
            error,
        )
    })?;
    let opened_metadata = file.metadata().map_err(|error| {
        CommandError::io(
            "image_source_unavailable",
            "Unable to inspect the selected image",
            error,
        )
    })?;
    if !opened_metadata.is_file() {
        return Err(CommandError::new(
            "image_source_not_regular_file",
            "The selected image must be a regular file.",
        ));
    }
    if opened_metadata.len() > MAX_WRITING_IMAGE_BYTES {
        return Err(CommandError::new(
            "image_too_large",
            format!("Images larger than {MAX_WRITING_IMAGE_BYTES} bytes are not supported."),
        ));
    }

    let mut bytes = Vec::with_capacity(opened_metadata.len() as usize);
    file.read_to_end(&mut bytes).map_err(|error| {
        CommandError::io(
            "image_source_unavailable",
            "Unable to read the selected image",
            error,
        )
    })?;
    if bytes.len() as u64 > MAX_WRITING_IMAGE_BYTES {
        return Err(CommandError::new(
            "image_too_large",
            format!("Images larger than {MAX_WRITING_IMAGE_BYTES} bytes are not supported."),
        ));
    }
    let format = image_format_from_signature(&bytes).ok_or_else(|| {
        CommandError::new(
            "unsupported_image_type",
            "Only PNG, JPEG, GIF, and WebP images with matching file signatures are supported.",
        )
    })?;
    let extension = source.extension().and_then(OsStr::to_str).ok_or_else(|| {
        CommandError::new(
            "image_extension_missing",
            "The selected image must have a supported filename extension.",
        )
    })?;
    if !format.accepts_extension(extension) {
        return Err(CommandError::new(
            "image_extension_mismatch",
            "The image filename extension does not match its file signature.",
        ));
    }
    Ok((bytes, format))
}

fn image_format_from_signature(bytes: &[u8]) -> Option<WritingImageFormat> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some(WritingImageFormat::Png)
    } else if bytes.len() >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff {
        Some(WritingImageFormat::Jpeg)
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        Some(WritingImageFormat::Gif)
    } else if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some(WritingImageFormat::Webp)
    } else {
        None
    }
}

fn sanitized_asset_stem(source: &Path) -> String {
    let original = source
        .file_stem()
        .and_then(OsStr::to_str)
        .unwrap_or("image");
    let mut output = String::with_capacity(original.len().min(64));
    let mut previous_dash = false;
    for character in original.chars() {
        if character.is_ascii_alphanumeric() {
            output.push(character.to_ascii_lowercase());
            previous_dash = false;
        } else if (character == '-' || character == '_') && !output.is_empty() {
            output.push(character);
            previous_dash = false;
        } else if !previous_dash && !output.is_empty() {
            output.push('-');
            previous_dash = true;
        }
        if output.len() >= 64 {
            break;
        }
    }
    let trimmed = output.trim_matches(['-', '_']);
    if trimmed.is_empty() {
        "image".to_string()
    } else {
        trimmed.to_string()
    }
}

fn resolve_asset_directory(root: &Path, relative: &Path) -> CommandResult<PathBuf> {
    let mut directory = root.to_path_buf();
    for component in relative.components() {
        let Component::Normal(name) = component else {
            return Err(CommandError::new(
                "invalid_image_destination",
                "Image destination contains a forbidden path component.",
            ));
        };
        directory.push(name);
        match fs::symlink_metadata(&directory) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err(CommandError::new(
                    "image_destination_is_symlink",
                    "Symbolic links are not accepted in the image destination.",
                ));
            }
            Ok(metadata) if !metadata.is_dir() => {
                return Err(CommandError::new(
                    "image_destination_not_directory",
                    "A parent component of the image destination is not a directory.",
                ));
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                fs::create_dir(&directory).map_err(|create_error| {
                    CommandError::io(
                        "image_directory_create_failed",
                        "Unable to create the image destination directory.",
                        create_error,
                    )
                })?;
                let created = fs::symlink_metadata(&directory).map_err(|inspect_error| {
                    CommandError::io(
                        "image_directory_create_failed",
                        "Unable to inspect the created image destination directory.",
                        inspect_error,
                    )
                })?;
                if created.file_type().is_symlink() || !created.is_dir() {
                    return Err(CommandError::new(
                        "image_destination_is_symlink",
                        "Symbolic links are not accepted in the image destination.",
                    ));
                }
            }
            Err(error) => {
                return Err(CommandError::io(
                    "image_destination_unavailable",
                    "Unable to inspect the image destination directory.",
                    error,
                ));
            }
        }
    }
    let canonical = fs::canonicalize(&directory).map_err(|error| {
        CommandError::io(
            "image_destination_unavailable",
            "Unable to resolve the image destination directory.",
            error,
        )
    })?;
    if !canonical.starts_with(root) {
        return Err(CommandError::new(
            "image_destination_outside_repository",
            "The image destination resolves outside the opened repository.",
        ));
    }
    Ok(canonical)
}

fn atomic_create_image_with_suffix(
    directory: &Path,
    stem: &str,
    extension: &str,
    bytes: &[u8],
) -> CommandResult<(PathBuf, String)> {
    for index in 0..10_000usize {
        let file_name = if index == 0 {
            format!("{stem}.{extension}")
        } else {
            format!("{stem}-{}.{extension}", index + 1)
        };
        let destination = directory.join(&file_name);
        let mut temporary = Builder::new()
            .prefix(".repopress-image-")
            .tempfile_in(directory)
            .map_err(|error| {
                CommandError::io(
                    "image_import_failed",
                    "Unable to create a temporary image file.",
                    error,
                )
            })?;
        temporary.as_file_mut().write_all(bytes).map_err(|error| {
            CommandError::io(
                "image_import_failed",
                "Unable to write the temporary image file.",
                error,
            )
        })?;
        temporary.as_file_mut().sync_all().map_err(|error| {
            CommandError::io(
                "image_import_failed",
                "Unable to flush the temporary image file.",
                error,
            )
        })?;
        match temporary.persist_noclobber(&destination) {
            Ok(_) => return Ok((destination, file_name)),
            Err(error) if error.error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(CommandError::io(
                    "image_import_failed",
                    "Unable to copy the image without replacing an existing file.",
                    error.error,
                ));
            }
        }
    }
    Err(CommandError::new(
        "image_name_exhausted",
        "Unable to allocate a unique image filename.",
    ))
}

fn detect_site_kind(root: &Path) -> String {
    if ["astro.config.mjs", "astro.config.js", "astro.config.ts"]
        .iter()
        .any(|name| marker_file(root, name))
    {
        "astro".to_string()
    } else if [
        "next.config.js",
        "next.config.mjs",
        "next.config.cjs",
        "next.config.ts",
    ]
    .iter()
    .any(|name| marker_file(root, name))
    {
        "nextjs".to_string()
    } else if [
        "docs/.vitepress/config.ts",
        "docs/.vitepress/config.js",
        "docs/.vitepress/config.mjs",
    ]
    .iter()
    .any(|name| marker_relative_file(root, name))
    {
        "vitepress".to_string()
    } else if ["quartz.config.ts", "quartz.config.js", "quartz.config.mjs"]
        .iter()
        .any(|name| marker_file(root, name))
    {
        "quartz".to_string()
    } else if ["hugo.toml", "hugo.yaml", "hugo.yml", "hugo.json"]
        .iter()
        .any(|name| marker_file(root, name))
    {
        "hugo".to_string()
    } else if marker_file(root, "zola.toml") {
        "zola".to_string()
    } else if let Some(kind) = detect_toml_site_kind(root) {
        kind.to_string()
    } else if is_existing_directory_without_symlink(&root.join("source/_posts")) {
        "hexo".to_string()
    } else if is_existing_directory_without_symlink(&root.join("_posts")) {
        "jekyll".to_string()
    } else if marker_file(root, "_config.yml") {
        // A standalone Jekyll config is more common; a Hexo repository is distinguished above
        // by its conventional source/_posts root that RepoPress already recognizes.
        "jekyll".to_string()
    } else if ["foam.json", ".foamrc"]
        .iter()
        .any(|name| marker_file(root, name))
    {
        "foam".to_string()
    } else {
        "unknown".to_string()
    }
}

fn marker_file(root: &Path, name: &str) -> bool {
    fs::symlink_metadata(root.join(name))
        .map(|metadata| {
            metadata.is_file() && !metadata.file_type().is_symlink() && metadata.len() <= 64 * 1024
        })
        .unwrap_or(false)
}

fn marker_relative_file(root: &Path, relative: &str) -> bool {
    let path = Path::new(relative);
    if path.is_absolute()
        || path
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return false;
    }
    marker_file(root, relative)
}

fn detect_toml_site_kind(root: &Path) -> Option<&'static str> {
    let path = root.join("config.toml");
    let metadata = fs::symlink_metadata(&path).ok()?;
    if metadata.file_type().is_symlink() || !metadata.is_file() || metadata.len() > 64 * 1024 {
        return None;
    }
    let text = fs::read_to_string(path).ok()?;
    let mut zola_score = 0usize;
    let mut hugo_score = 0usize;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with('[') {
            continue;
        }
        let Some((key, _)) = line.split_once('=') else {
            continue;
        };
        match key
            .trim()
            .trim_matches(['"', '\''])
            .to_ascii_lowercase()
            .as_str()
        {
            "base_url" | "compile_sass" | "build_search_index" | "generate_feeds" => {
                zola_score += 1
            }
            "baseurl" | "languagecode" | "contentdir" | "paginate" => hugo_score += 1,
            _ => {}
        }
    }
    match zola_score.cmp(&hugo_score) {
        std::cmp::Ordering::Greater if zola_score > 0 => Some("zola"),
        std::cmp::Ordering::Less if hugo_score > 0 => Some("hugo"),
        _ => None,
    }
}

fn revalidate_root(root: &Path) -> CommandResult<()> {
    let metadata = fs::symlink_metadata(root).map_err(|error| {
        CommandError::io(
            "repository_unavailable",
            "Unable to revalidate the repository root",
            error,
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(CommandError::new(
            "repository_identity_changed",
            "The repository root is no longer the directory that was opened.",
        ));
    }
    let canonical = fs::canonicalize(root).map_err(|error| {
        CommandError::io(
            "repository_unavailable",
            "Unable to resolve the repository root",
            error,
        )
    })?;
    if canonical != root {
        return Err(CommandError::new(
            "repository_identity_changed",
            "The repository root changed after it was opened.",
        ));
    }
    Ok(())
}

fn validate_markdown_relative_path(value: &str) -> CommandResult<PathBuf> {
    if value.is_empty() || value.contains('\0') || value.contains('\\') {
        return Err(CommandError::new(
            "invalid_relative_path",
            "Document path must be a portable, non-empty relative path.",
        ));
    }
    let path = Path::new(value);
    if path.is_absolute() {
        return Err(CommandError::new(
            "invalid_relative_path",
            "Absolute document paths are not accepted.",
        ));
    }
    for component in path.components() {
        match component {
            Component::Normal(name) if !name.eq_ignore_ascii_case(OsStr::new(".git")) => {}
            _ => {
                return Err(CommandError::new(
                    "invalid_relative_path",
                    "Document path contains a forbidden component.",
                ));
            }
        }
    }
    if !is_markdown_path(path) {
        return Err(CommandError::new(
            "unsupported_document_type",
            "Only Markdown documents can be opened in this prototype.",
        ));
    }
    Ok(path.to_path_buf())
}

fn validate_new_markdown_relative_path(value: &str) -> CommandResult<PathBuf> {
    let path = validate_markdown_relative_path(value)?;
    let is_writable_markdown = path
        .extension()
        .and_then(OsStr::to_str)
        .map(|extension| {
            extension.eq_ignore_ascii_case("md") || extension.eq_ignore_ascii_case("markdown")
        })
        .unwrap_or(false);
    if !is_writable_markdown {
        return Err(CommandError::new(
            "unsupported_document_type",
            "New documents must use a .md or .markdown extension.",
        ));
    }
    Ok(path)
}

fn resolve_existing_file(root: &Path, relative: &Path) -> CommandResult<PathBuf> {
    let mut candidate = root.to_path_buf();
    for component in relative.components() {
        let Component::Normal(name) = component else {
            return Err(CommandError::new(
                "invalid_relative_path",
                "Document path contains a forbidden component.",
            ));
        };
        candidate.push(name);
        let metadata = fs::symlink_metadata(&candidate).map_err(|error| {
            CommandError::io(
                "document_unavailable",
                "Unable to inspect the document path",
                error,
            )
        })?;
        if metadata.file_type().is_symlink() {
            return Err(CommandError::new(
                "document_path_is_symlink",
                "Symbolic links are not accepted for editable documents.",
            ));
        }
    }
    let canonical = fs::canonicalize(&candidate).map_err(|error| {
        CommandError::io(
            "document_unavailable",
            "Unable to resolve the document path",
            error,
        )
    })?;
    if !canonical.starts_with(root) {
        return Err(CommandError::new(
            "document_outside_repository",
            "The selected document resolves outside the repository.",
        ));
    }
    Ok(canonical)
}

/// Resolve a new repository-relative path, creating only ordinary parent directories and never
/// traversing an existing symbolic link. The final path must not exist: callers use no-clobber
/// persistence so a concurrent creation is still rejected at the filesystem boundary.
fn resolve_new_file_path(root: &Path, relative: &Path) -> CommandResult<PathBuf> {
    let parent = relative.parent().unwrap_or_else(|| Path::new(""));
    let mut candidate = root.to_path_buf();
    for component in parent.components() {
        let Component::Normal(name) = component else {
            return Err(CommandError::new(
                "invalid_relative_path",
                "Document path contains a forbidden component.",
            ));
        };
        candidate.push(name);
        match fs::symlink_metadata(&candidate) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err(CommandError::new(
                    "document_path_is_symlink",
                    "Symbolic links are not accepted for editable documents.",
                ));
            }
            Ok(metadata) if !metadata.is_dir() => {
                return Err(CommandError::new(
                    "document_parent_not_directory",
                    "A parent component of the new document path is not a directory.",
                ));
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                fs::create_dir(&candidate).map_err(|create_error| {
                    CommandError::io(
                        "document_directory_create_failed",
                        "Unable to create a directory for the new document",
                        create_error,
                    )
                })?;
                let metadata = fs::symlink_metadata(&candidate).map_err(|inspect_error| {
                    CommandError::io(
                        "document_directory_create_failed",
                        "Unable to inspect a created document directory",
                        inspect_error,
                    )
                })?;
                if metadata.file_type().is_symlink() || !metadata.is_dir() {
                    return Err(CommandError::new(
                        "document_path_is_symlink",
                        "Symbolic links are not accepted for editable documents.",
                    ));
                }
            }
            Err(error) => {
                return Err(CommandError::io(
                    "document_unavailable",
                    "Unable to inspect the new document path",
                    error,
                ));
            }
        }
    }
    let file_name = relative.file_name().ok_or_else(|| {
        CommandError::new("invalid_relative_path", "Document path must name a file.")
    })?;
    candidate.push(file_name);
    match fs::symlink_metadata(&candidate) {
        Ok(_) => Err(CommandError::new(
            "document_already_exists",
            "A document already exists at the requested path.",
        )),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(candidate),
        Err(error) => Err(CommandError::io(
            "document_unavailable",
            "Unable to inspect the new document path",
            error,
        )),
    }
}

/// Non-mutating counterpart to `resolve_new_file_path`. Missing parent directories are valid:
/// execution will create them one component at a time after it repeats all validation.
fn inspect_new_file_path(root: &Path, relative: &Path) -> CommandResult<bool> {
    let parent = relative.parent().unwrap_or_else(|| Path::new(""));
    let mut candidate = root.to_path_buf();
    for component in parent.components() {
        let Component::Normal(name) = component else {
            return Err(CommandError::new(
                "invalid_relative_path",
                "Document path contains a forbidden component.",
            ));
        };
        candidate.push(name);
        match fs::symlink_metadata(&candidate) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err(CommandError::new(
                    "document_path_is_symlink",
                    "Symbolic links are not accepted for editable documents.",
                ));
            }
            Ok(metadata) if !metadata.is_dir() => {
                return Err(CommandError::new(
                    "document_parent_not_directory",
                    "A parent component of the new document path is not a directory.",
                ));
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(true),
            Err(error) => {
                return Err(CommandError::io(
                    "document_unavailable",
                    "Unable to inspect the new document path",
                    error,
                ));
            }
        }
    }
    let file_name = relative.file_name().ok_or_else(|| {
        CommandError::new("invalid_relative_path", "Document path must name a file.")
    })?;
    candidate.push(file_name);
    match fs::symlink_metadata(&candidate) {
        Ok(_) => Ok(false),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(true),
        Err(error) => Err(CommandError::io(
            "document_unavailable",
            "Unable to inspect the new document path",
            error,
        )),
    }
}

fn scan_markdown_files(
    root: &Path,
    directory: &Path,
    depth: usize,
    entries: &mut Vec<MarkdownFileEntry>,
) -> CommandResult<()> {
    if depth > MAX_SCAN_DEPTH {
        return Err(CommandError::new(
            "repository_scan_depth_exceeded",
            format!("Repository scan exceeded {MAX_SCAN_DEPTH} directory levels."),
        ));
    }
    let children = fs::read_dir(directory).map_err(|error| {
        CommandError::io(
            "repository_scan_failed",
            "Unable to read a repository directory",
            error,
        )
    })?;
    for child in children {
        let child = child.map_err(|error| {
            CommandError::io(
                "repository_scan_failed",
                "Unable to inspect a repository entry",
                error,
            )
        })?;
        let path = child.path();
        let metadata = fs::symlink_metadata(&path).map_err(|error| {
            CommandError::io(
                "repository_scan_failed",
                "Unable to inspect a repository entry",
                error,
            )
        })?;
        if metadata.file_type().is_symlink() {
            continue;
        }
        if metadata.is_dir() {
            if EXCLUDED_DIRECTORIES
                .iter()
                .any(|excluded| child.file_name().eq_ignore_ascii_case(OsStr::new(excluded)))
            {
                continue;
            }
            scan_markdown_files(root, &path, depth + 1, entries)?;
        } else if metadata.is_file() && is_markdown_path(&path) {
            if entries.len() >= MAX_MARKDOWN_FILES {
                return Err(CommandError::new(
                    "repository_file_limit_exceeded",
                    format!("Repository contains more than {MAX_MARKDOWN_FILES} Markdown files."),
                ));
            }
            let relative = path.strip_prefix(root).map_err(|_| {
                CommandError::new(
                    "document_outside_repository",
                    "A scanned document was outside the repository root.",
                )
            })?;
            let Some(relative_path) = relative.to_str() else {
                continue;
            };
            entries.push(MarkdownFileEntry {
                relative_path: relative_path.replace(std::path::MAIN_SEPARATOR, "/"),
                display_name: path
                    .file_name()
                    .and_then(OsStr::to_str)
                    .unwrap_or("Untitled")
                    .to_string(),
                directory: relative
                    .parent()
                    .filter(|parent| !parent.as_os_str().is_empty())
                    .map(path_to_portable_string)
                    .unwrap_or_default(),
                byte_size: metadata.len(),
            });
        }
    }
    Ok(())
}

fn is_markdown_path(path: &Path) -> bool {
    path.extension()
        .and_then(OsStr::to_str)
        .map(|extension| {
            extension.eq_ignore_ascii_case("md")
                || extension.eq_ignore_ascii_case("markdown")
                || extension.eq_ignore_ascii_case("mdx")
        })
        .unwrap_or(false)
}

fn path_to_portable_string(path: &Path) -> String {
    path.to_string_lossy()
        .replace(std::path::MAIN_SEPARATOR, "/")
}

struct DecodedDocument {
    text: String,
    encoding: String,
    line_ending: LineEnding,
    writable: bool,
    read_only_reason: Option<String>,
}

fn parse_markdown_front_matter(text: &str) -> (Option<String>, Option<String>, Option<String>) {
    let mut lines = text.lines();
    let Some(first) = lines.next().map(|line| line.trim_end_matches([' ', '\t'])) else {
        return (None, None, None);
    };
    let style = match first {
        "---" => ':',
        "+++" => '=',
        _ => return (None, None, None),
    };
    let mut title = None;
    let mut slug = None;
    let mut permalink = None;
    let mut seen_title = false;
    let mut seen_slug = false;
    let mut seen_permalink = false;
    let mut invalid_title = false;
    let mut invalid_slug = false;
    let mut invalid_permalink = false;
    let mut closed = false;
    for line in lines {
        let exact_line = line.trim_end_matches([' ', '\t']);
        if exact_line == first || (style == ':' && exact_line == "...") {
            closed = true;
            break;
        }
        let Some((key, raw)) = line.split_once(style) else {
            continue;
        };
        let key = key.trim().to_ascii_lowercase();
        if !matches!(key.as_str(), "title" | "slug" | "permalink") {
            continue;
        }
        let decoded = decode_markdown_front_matter_scalar(raw);
        match key.as_str() {
            "title" if !seen_title => {
                title = decoded;
                seen_title = true;
            }
            "slug" if !seen_slug => {
                slug = decoded;
                seen_slug = true;
            }
            "permalink" if !seen_permalink => {
                permalink = decoded;
                seen_permalink = true;
            }
            "title" => {
                title = None;
                invalid_title = true;
            }
            "slug" => {
                slug = None;
                invalid_slug = true;
            }
            "permalink" => {
                permalink = None;
                invalid_permalink = true;
            }
            _ => {}
        }
    }
    if closed {
        (
            (!invalid_title).then_some(title).flatten(),
            (!invalid_slug).then_some(slug).flatten(),
            (!invalid_permalink).then_some(permalink).flatten(),
        )
    } else {
        (None, None, None)
    }
}

fn decode_markdown_front_matter_scalar(raw: &str) -> Option<String> {
    let value = raw.trim();
    if value.is_empty()
        || value.len() > 512
        || matches!(value.as_bytes()[0], b'[' | b'{' | b'|' | b'>')
    {
        return None;
    }
    let decoded = if value.starts_with('"') {
        serde_json::from_str::<String>(value).ok()?
    } else if value.starts_with('\'') {
        let inner = value.strip_prefix('\'')?.strip_suffix('\'')?;
        inner.replace("''", "'")
    } else {
        value
            .split_once(" #")
            .map_or(value, |(plain, _)| plain)
            .trim()
            .to_string()
    };
    let decoded = decoded.trim();
    (!decoded.is_empty() && decoded.len() <= 512).then(|| decoded.to_string())
}

fn decode_document(bytes: &[u8]) -> CommandResult<DecodedDocument> {
    let (encoding, payload) = if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
        ("utf-8-bom", &bytes[3..])
    } else {
        ("utf-8", bytes)
    };
    let raw = std::str::from_utf8(payload).map_err(|_| {
        CommandError::new(
            "unsupported_document_encoding",
            "Only UTF-8 Markdown documents are supported.",
        )
    })?;
    let line_ending = detect_line_ending(payload);
    let writable = line_ending != LineEnding::Mixed;
    let text = raw.replace("\r\n", "\n").replace('\r', "\n");
    Ok(DecodedDocument {
        text,
        encoding: encoding.to_string(),
        line_ending,
        writable,
        read_only_reason: (!writable).then(|| "mixed_line_endings".to_string()),
    })
}

fn detect_line_ending(bytes: &[u8]) -> LineEnding {
    let mut saw_crlf = false;
    let mut saw_lf = false;
    let mut saw_bare_cr = false;
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'\r' if bytes.get(index + 1) == Some(&b'\n') => {
                saw_crlf = true;
                index += 2;
            }
            b'\r' => {
                saw_bare_cr = true;
                index += 1;
            }
            b'\n' => {
                saw_lf = true;
                index += 1;
            }
            _ => index += 1,
        }
    }
    if saw_bare_cr || (saw_crlf && saw_lf) {
        LineEnding::Mixed
    } else if saw_crlf {
        LineEnding::Crlf
    } else if saw_lf {
        LineEnding::Lf
    } else {
        LineEnding::None
    }
}

fn encode_document(text: &str, encoding: &str, line_ending: LineEnding) -> CommandResult<Vec<u8>> {
    if line_ending == LineEnding::Mixed {
        return Err(CommandError::new(
            "document_read_only",
            "Documents with mixed line endings are read-only.",
        ));
    }
    let normalized = match line_ending {
        LineEnding::Crlf => text.replace('\n', "\r\n"),
        LineEnding::None | LineEnding::Lf => text.to_string(),
        LineEnding::Mixed => unreachable!(),
    };
    let mut output = Vec::with_capacity(normalized.len() + 3);
    if encoding == "utf-8-bom" {
        output.extend_from_slice(&[0xEF, 0xBB, 0xBF]);
    }
    output.extend_from_slice(normalized.as_bytes());
    Ok(output)
}

fn atomic_replace(path: &Path, bytes: &[u8]) -> CommandResult<()> {
    let parent = path.parent().ok_or_else(|| {
        CommandError::new(
            "document_save_failed",
            "Document path does not have a parent directory.",
        )
    })?;
    let permissions = fs::metadata(path)
        .map_err(|error| {
            CommandError::io(
                "document_save_failed",
                "Unable to inspect document permissions",
                error,
            )
        })?
        .permissions();
    let mut temporary = Builder::new()
        .prefix(".repopress-save-")
        .tempfile_in(parent)
        .map_err(|error| {
            CommandError::io(
                "document_save_failed",
                "Unable to create a temporary save file",
                error,
            )
        })?;
    temporary.as_file_mut().write_all(bytes).map_err(|error| {
        CommandError::io(
            "document_save_failed",
            "Unable to write the temporary save file",
            error,
        )
    })?;
    temporary.as_file_mut().sync_all().map_err(|error| {
        CommandError::io(
            "document_save_failed",
            "Unable to flush the temporary save file",
            error,
        )
    })?;
    fs::set_permissions(temporary.path(), permissions).map_err(|error| {
        CommandError::io(
            "document_save_failed",
            "Unable to preserve document permissions",
            error,
        )
    })?;
    temporary.persist(path).map_err(|error| {
        CommandError::io(
            "document_save_failed",
            "Unable to atomically replace the document",
            error.error,
        )
    })?;
    Ok(())
}

fn atomic_create(path: &Path, bytes: &[u8]) -> CommandResult<()> {
    let parent = path.parent().ok_or_else(|| {
        CommandError::new(
            "document_create_failed",
            "Document path does not have a parent directory.",
        )
    })?;
    let mut temporary = Builder::new()
        .prefix(".repopress-create-")
        .tempfile_in(parent)
        .map_err(|error| {
            CommandError::io(
                "document_create_failed",
                "Unable to create a temporary document file",
                error,
            )
        })?;
    temporary.as_file_mut().write_all(bytes).map_err(|error| {
        CommandError::io(
            "document_create_failed",
            "Unable to write the temporary document file",
            error,
        )
    })?;
    temporary.as_file_mut().sync_all().map_err(|error| {
        CommandError::io(
            "document_create_failed",
            "Unable to flush the temporary document file",
            error,
        )
    })?;
    temporary.persist_noclobber(path).map_err(|error| {
        let code = if error.error.kind() == std::io::ErrorKind::AlreadyExists {
            "document_already_exists"
        } else {
            "document_create_failed"
        };
        let message = if code == "document_already_exists" {
            "A document already exists at the requested path."
        } else {
            "Unable to create the document without replacing an existing file"
        };
        CommandError::io(code, message, error.error)
    })?;
    Ok(())
}

fn sha256_hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn parses_only_exact_safe_link_front_matter_fields() {
        assert_eq!(
            parse_markdown_front_matter(
                "---\ntitle: \"Guide\"\nslug: guide # note\npermalink: /docs/guide/\n---\nBody"
            ),
            (
                Some("Guide".into()),
                Some("guide".into()),
                Some("/docs/guide/".into())
            )
        );
        assert_eq!(
            parse_markdown_front_matter(
                "+++\ntitle = 'Guide'\nslug = \"guide\"\npermalink = \"/docs/guide/\"\n+++\nBody"
            ),
            (
                Some("Guide".into()),
                Some("guide".into()),
                Some("/docs/guide/".into())
            )
        );
        assert_eq!(
            parse_markdown_front_matter("---\ntitle = wrong-style\n---oops\nBody"),
            (None, None, None)
        );
        assert_eq!(
            parse_markdown_front_matter("---\ntitle: [complex]\nslug: one\nslug: two\n---\nBody"),
            (None, None, None)
        );
    }

    #[test]
    fn opens_lists_saves_and_detects_external_conflicts() {
        let temporary = tempfile::tempdir().expect("temporary repository");
        fs::create_dir(temporary.path().join(".git")).expect("git marker");
        fs::create_dir(temporary.path().join("content")).expect("content directory");
        let article = temporary.path().join("content/中文🙂.md");
        fs::write(&article, "# 初稿\r\n\r\n正文\r\n").expect("fixture article");

        let store = RepositoryStore::default();
        let session = store
            .open_repository(temporary.path().to_str().expect("utf-8 path"))
            .expect("open repository");
        let files = store
            .list_markdown_files(&session.session_id)
            .expect("list Markdown files");
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].relative_path, "content/中文🙂.md");

        let document = store
            .open_document(&session.session_id, &files[0].relative_path)
            .expect("open document");
        assert_eq!(document.line_ending, LineEnding::Crlf);
        assert_eq!(document.text, "# 初稿\n\n正文\n");
        let saved = store
            .save_document(
                &session.session_id,
                &document.document_id,
                "# 已保存\n\n正文🙂\n",
                &document.baseline_sha256,
            )
            .expect("save document");
        assert_eq!(saved.revision, 2);
        assert_eq!(
            fs::read(&article).expect("saved bytes"),
            "# 已保存\r\n\r\n正文🙂\r\n".as_bytes()
        );

        fs::write(&article, "# 外部修改\r\n").expect("external edit");
        let error = store
            .save_document(
                &session.session_id,
                &document.document_id,
                "# 不应覆盖\n",
                &saved.baseline_sha256,
            )
            .expect_err("external edit must conflict");
        assert_eq!(error.code, "save_conflict");
        assert_eq!(
            fs::read_to_string(&article).expect("external content remains"),
            "# 外部修改\r\n"
        );
    }

    #[test]
    fn rejects_parent_paths_and_marks_mixed_line_endings_read_only() {
        let temporary = tempfile::tempdir().expect("temporary repository");
        fs::create_dir(temporary.path().join("content")).expect("content directory");
        fs::write(
            temporary.path().join("content/mixed.md"),
            b"one\r\ntwo\nthree\r",
        )
        .expect("mixed fixture");
        let store = RepositoryStore::default();
        let session = store
            .open_repository(temporary.path().to_str().expect("utf-8 path"))
            .expect("open repository");
        let path_error = store
            .open_document(&session.session_id, "../outside.md")
            .expect_err("parent path must be rejected");
        assert_eq!(path_error.code, "invalid_relative_path");

        let mixed = store
            .open_document(&session.session_id, "content/mixed.md")
            .expect("open mixed document");
        assert!(!mixed.writable);
        assert_eq!(
            mixed.read_only_reason.as_deref(),
            Some("mixed_line_endings")
        );
    }

    #[test]
    fn validates_search_roots_and_site_context() {
        let temporary = tempfile::tempdir().expect("temporary repository");
        fs::create_dir(temporary.path().join("content")).expect("content directory");
        fs::write(temporary.path().join("hugo.toml"), "baseURL = '/'").expect("site marker");
        let store = RepositoryStore::default();
        let session = store
            .open_repository(temporary.path().to_str().unwrap())
            .unwrap();
        let (root, scan_root) = store.search_roots_for_session(&session.session_id).unwrap();
        assert_eq!(root, fs::canonicalize(temporary.path()).unwrap());
        assert_eq!(scan_root, root.join("content"));
        assert_eq!(
            store
                .site_context_for_session(&session.session_id)
                .unwrap()
                .1,
            "hugo"
        );
    }

    #[test]
    fn does_not_misclassify_arbitrary_config_yaml() {
        let temporary = tempfile::tempdir().expect("temporary repository");
        fs::write(temporary.path().join("config.yaml"), "not a Hugo site").unwrap();
        let store = RepositoryStore::default();
        let session = store
            .open_repository(temporary.path().to_str().unwrap())
            .unwrap();
        assert_eq!(
            store
                .site_context_for_session(&session.session_id)
                .unwrap()
                .1,
            "unknown"
        );
    }

    #[test]
    fn distinguishes_bounded_zola_and_hugo_toml_markers() {
        let zola = tempfile::tempdir().expect("zola repository");
        fs::write(
            zola.path().join("config.toml"),
            "base_url = 'https://example.test'",
        )
        .unwrap();
        assert_eq!(detect_site_kind(zola.path()), "zola");

        let hugo = tempfile::tempdir().expect("hugo repository");
        fs::write(
            hugo.path().join("config.toml"),
            "baseURL = 'https://example.test'",
        )
        .unwrap();
        assert_eq!(detect_site_kind(hugo.path()), "hugo");

        let ambiguous = tempfile::tempdir().expect("ambiguous repository");
        fs::create_dir(ambiguous.path().join("content")).unwrap();
        fs::write(ambiguous.path().join("config.toml"), "title = 'Docs'").unwrap();
        assert_eq!(detect_site_kind(ambiguous.path()), "unknown");
    }

    #[cfg(unix)]
    #[test]
    fn rejects_document_symlinks() {
        use std::os::unix::fs::symlink;

        let temporary = tempfile::tempdir().expect("temporary repository");
        fs::create_dir(temporary.path().join("content")).expect("content directory");
        fs::write(temporary.path().join("outside.md"), "outside").expect("outside file");
        symlink(
            temporary.path().join("outside.md"),
            temporary.path().join("content/link.md"),
        )
        .expect("document symlink");
        let store = RepositoryStore::default();
        let session = store
            .open_repository(temporary.path().to_str().expect("utf-8 path"))
            .expect("open repository");
        let error = store
            .open_document(&session.session_id, "content/link.md")
            .expect_err("symlink must be rejected");
        assert_eq!(error.code, "document_path_is_symlink");
    }

    #[test]
    fn creates_renames_and_deletes_session_bound_markdown_documents() {
        let temporary = tempfile::tempdir().expect("temporary repository");
        fs::create_dir(temporary.path().join("content")).expect("content directory");
        let store = RepositoryStore::default();
        let session = store
            .open_repository(temporary.path().to_str().expect("utf-8 path"))
            .expect("open repository");

        let created = store
            .create_markdown_document(&session.session_id, "content/drafts/初稿.md", "# 初稿\n")
            .expect("create Markdown document");
        assert!(created.writable);
        assert_eq!(created.relative_path, "content/drafts/初稿.md");
        assert_eq!(
            fs::read_to_string(temporary.path().join("content/drafts/初稿.md")).unwrap(),
            "# 初稿\n"
        );

        let duplicate = store
            .create_markdown_document(&session.session_id, "content/drafts/初稿.md", "other")
            .expect_err("must not overwrite an existing document");
        assert_eq!(duplicate.code, "document_already_exists");
        let traversal = store
            .create_markdown_document(&session.session_id, "content/../escape.md", "x")
            .expect_err("path traversal must be rejected");
        assert_eq!(traversal.code, "invalid_relative_path");
        let outside_content = store
            .create_markdown_document(&session.session_id, "outside.md", "x")
            .expect_err("content-root sessions restrict new documents");
        assert_eq!(outside_content.code, "document_outside_content_root");
        let mdx = store
            .create_markdown_document(&session.session_id, "content/drafts/component.mdx", "x")
            .expect_err("new document extensions are constrained");
        assert_eq!(mdx.code, "unsupported_document_type");

        let renamed = store
            .rename_markdown_document(
                &session.session_id,
                &created.document_id,
                "content/published/文章.markdown",
                &created.baseline_sha256,
            )
            .expect("rename Markdown document");
        assert_eq!(renamed.document_id, created.document_id);
        assert_eq!(renamed.revision, 2);
        assert!(!temporary.path().join("content/drafts/初稿.md").exists());
        assert!(temporary
            .path()
            .join("content/published/文章.markdown")
            .is_file());

        fs::write(temporary.path().join("content/published/taken.md"), "taken").unwrap();
        let target_exists = store
            .rename_markdown_document(
                &session.session_id,
                &created.document_id,
                "content/published/taken.md",
                &renamed.baseline_sha256,
            )
            .expect_err("rename cannot overwrite a target");
        assert_eq!(target_exists.code, "document_already_exists");
        let stale_rename = store
            .rename_markdown_document(
                &session.session_id,
                &created.document_id,
                "content/published/next.md",
                "not-the-baseline",
            )
            .expect_err("rename requires the current baseline");
        assert_eq!(stale_rename.code, "save_conflict");

        let stale_delete = store
            .delete_markdown_document(
                &session.session_id,
                &created.document_id,
                "not-the-baseline",
            )
            .expect_err("delete requires the current baseline");
        assert_eq!(stale_delete.code, "save_conflict");
        let deleted = store
            .delete_markdown_document(
                &session.session_id,
                &created.document_id,
                &renamed.baseline_sha256,
            )
            .expect("delete Markdown document");
        assert_eq!(deleted.relative_path, "content/published/文章.markdown");
        assert!(!temporary
            .path()
            .join("content/published/文章.markdown")
            .exists());
        let expired = store
            .save_document(
                &session.session_id,
                &created.document_id,
                "# changed\n",
                &renamed.baseline_sha256,
            )
            .expect_err("delete invalidates the session document");
        assert_eq!(expired.code, "document_session_not_found");
    }

    #[cfg(unix)]
    #[test]
    fn refuses_symlinked_parent_directories_for_new_documents() {
        use std::os::unix::fs::symlink;

        let temporary = tempfile::tempdir().expect("temporary repository");
        fs::create_dir(temporary.path().join("content")).unwrap();
        fs::create_dir(temporary.path().join("outside")).unwrap();
        symlink(
            temporary.path().join("outside"),
            temporary.path().join("content/link"),
        )
        .unwrap();
        let store = RepositoryStore::default();
        let session = store
            .open_repository(temporary.path().to_str().unwrap())
            .expect("open repository");
        let error = store
            .create_markdown_document(&session.session_id, "content/link/unsafe.md", "x")
            .expect_err("symlinked parent must not be traversed");
        assert_eq!(error.code, "document_path_is_symlink");
    }

    #[test]
    fn detects_common_static_site_content_roots_for_new_documents() {
        for relative in ["source/_posts", "_posts", "src/content"] {
            let temporary = tempfile::tempdir().expect("temporary repository");
            fs::create_dir_all(temporary.path().join(relative)).expect("content root");
            let store = RepositoryStore::default();
            let session = store
                .open_repository(temporary.path().to_str().expect("utf-8 path"))
                .expect("open repository");
            assert_eq!(session.content_root.as_deref(), Some(relative));
            let created_path = format!("{relative}/new.md");
            store
                .create_markdown_document(&session.session_id, &created_path, "# New\n")
                .expect("create in detected content root");
            assert!(temporary.path().join(created_path).is_file());
        }
    }

    #[test]
    fn permits_new_documents_at_repository_root_without_a_content_directory() {
        let temporary = tempfile::tempdir().expect("temporary repository");
        let store = RepositoryStore::default();
        let session = store
            .open_repository(temporary.path().to_str().expect("utf-8 path"))
            .expect("open repository");
        assert_eq!(session.content_root, None);
        let created = store
            .create_markdown_document(&session.session_id, "root.md", "# Root\n")
            .expect("create at repository root without content directory");
        assert_eq!(created.relative_path, "root.md");
        assert_eq!(
            fs::read_to_string(temporary.path().join("root.md")).unwrap(),
            "# Root\n"
        );
    }

    #[test]
    fn imports_verified_images_into_the_matching_public_site_roots() {
        let fixtures = [
            (
                "hugo",
                "content",
                Some(("hugo.toml", "baseURL = '/'")),
                "static/images",
                "/images",
            ),
            (
                "zola",
                "content",
                Some(("zola.toml", "base_url = '/'")),
                "static/images",
                "/images",
            ),
            (
                "astro",
                "src/content",
                Some(("astro.config.mjs", "export default {}")),
                "public/images",
                "/images",
            ),
            (
                "hexo",
                "source/_posts",
                Some(("_config.yml", "title: Hexo")),
                "source/images",
                "/images",
            ),
            (
                "jekyll",
                "_posts",
                Some(("_config.yml", "title: Jekyll")),
                "assets/images",
                "/assets/images",
            ),
        ];
        let year = current_image_year();
        for (expected_kind, content_root, marker, asset_root, public_prefix) in fixtures {
            let temporary = tempfile::tempdir().unwrap();
            fs::create_dir_all(temporary.path().join(content_root)).unwrap();
            if let Some((name, body)) = marker {
                fs::write(temporary.path().join(name), body).unwrap();
            }
            let source = temporary.path().join("cover image.png");
            fs::write(&source, b"\x89PNG\r\n\x1a\nfixture").unwrap();
            let store = RepositoryStore::default();
            let session = store
                .open_repository(temporary.path().to_str().unwrap())
                .unwrap();
            assert_eq!(session.site_kind, expected_kind);
            let document = store
                .create_markdown_document(
                    &session.session_id,
                    &format!("{content_root}/post.md"),
                    "# Post\n",
                )
                .unwrap();

            let imported = store
                .import_writing_image(
                    &session.session_id,
                    source.to_str().unwrap(),
                    &document.document_id,
                )
                .unwrap();
            assert_eq!(
                imported.relative_path,
                format!("{asset_root}/{year}/cover-image.png")
            );
            assert_eq!(
                imported.markdown_path,
                format!("{public_prefix}/{year}/cover-image.png")
            );
            assert_eq!(imported.mime_type, "image/png");
            assert_eq!(imported.byte_size, 15);
            assert!(temporary.path().join(&imported.relative_path).is_file());
        }
    }

    #[test]
    fn imports_verified_images_for_next_vitepress_quartz_and_foam_profiles() {
        let fixtures = [
            (
                "nextjs",
                "content/post.md",
                "next.config.ts",
                "export default {}",
                "public/images",
                "/images",
                true,
            ),
            (
                "vitepress",
                "docs/posts/post.md",
                "docs/.vitepress/config.ts",
                "export default {}",
                "docs/public/images",
                "/images",
                true,
            ),
            (
                "quartz",
                "content/post.md",
                "quartz.config.ts",
                "export default {}",
                "content/attachments",
                "/attachments",
                false,
            ),
            (
                "foam",
                "post.md",
                "foam.json",
                "{}",
                "attachments",
                "/attachments",
                false,
            ),
        ];
        let year = current_image_year();
        for (
            expected_kind,
            document_path,
            marker_path,
            marker_body,
            asset_root,
            public_prefix,
            includes_year,
        ) in fixtures
        {
            let temporary = tempfile::tempdir().unwrap();
            if let Some(parent) = Path::new(document_path)
                .parent()
                .filter(|path| !path.as_os_str().is_empty())
            {
                fs::create_dir_all(temporary.path().join(parent)).unwrap();
            }
            let marker = temporary.path().join(marker_path);
            if let Some(parent) = marker.parent() {
                fs::create_dir_all(parent).unwrap();
            }
            fs::write(&marker, marker_body).unwrap();
            let source = temporary.path().join("cover.png");
            fs::write(&source, b"\x89PNG\r\n\x1a\nfixture").unwrap();
            let store = RepositoryStore::default();
            let session = store
                .open_repository(temporary.path().to_str().unwrap())
                .unwrap();
            assert_eq!(session.site_kind, expected_kind);
            let document = store
                .create_markdown_document(&session.session_id, document_path, "# Post\n")
                .unwrap();
            let imported = store
                .import_writing_image(
                    &session.session_id,
                    source.to_str().unwrap(),
                    &document.document_id,
                )
                .unwrap();
            let expected_relative = if includes_year {
                format!("{asset_root}/{year}/cover.png")
            } else {
                format!("{asset_root}/cover.png")
            };
            let expected_markdown = if includes_year {
                format!("{public_prefix}/{year}/cover.png")
            } else {
                format!("{public_prefix}/cover.png")
            };
            assert_eq!(imported.relative_path, expected_relative);
            assert_eq!(imported.markdown_path, expected_markdown);
            assert!(temporary.path().join(&imported.relative_path).is_file());
        }
    }

    #[test]
    fn image_import_rejects_bad_inputs_and_never_overwrites_existing_names() {
        let temporary = tempfile::tempdir().unwrap();
        fs::create_dir(temporary.path().join("content")).unwrap();
        fs::write(temporary.path().join("hugo.toml"), "baseURL = '/'").unwrap();
        let source = temporary.path().join("dangerous .. name.png");
        fs::write(&source, b"\x89PNG\r\n\x1a\nfixture").unwrap();
        let store = RepositoryStore::default();
        let session = store
            .open_repository(temporary.path().to_str().unwrap())
            .unwrap();
        let document = store
            .create_markdown_document(&session.session_id, "content/post.md", "# Post\n")
            .unwrap();

        let first = store
            .import_writing_image(
                &session.session_id,
                source.to_str().unwrap(),
                &document.document_id,
            )
            .unwrap();
        let second = store
            .import_writing_image(
                &session.session_id,
                source.to_str().unwrap(),
                &document.document_id,
            )
            .unwrap();
        assert!(first.file_name.starts_with("dangerous-name."));
        assert!(second.file_name.starts_with("dangerous-name-2."));
        assert_ne!(first.relative_path, second.relative_path);

        let mismatch = temporary.path().join("spoof.jpg");
        fs::write(&mismatch, b"\x89PNG\r\n\x1a\nfixture").unwrap();
        let mismatch = store
            .import_writing_image(
                &session.session_id,
                mismatch.to_str().unwrap(),
                &document.document_id,
            )
            .unwrap_err();
        assert_eq!(mismatch.code, "image_extension_mismatch");

        let oversized = temporary.path().join("large.png");
        fs::File::create(&oversized)
            .unwrap()
            .set_len(MAX_WRITING_IMAGE_BYTES + 1)
            .unwrap();
        let oversized = store
            .import_writing_image(
                &session.session_id,
                oversized.to_str().unwrap(),
                &document.document_id,
            )
            .unwrap_err();
        assert_eq!(oversized.code, "image_too_large");
        let expired_session = store
            .import_writing_image("expired", source.to_str().unwrap(), &document.document_id)
            .unwrap_err();
        assert_eq!(expired_session.code, "repository_session_not_found");
        let expired_document = store
            .import_writing_image(&session.session_id, source.to_str().unwrap(), "expired")
            .unwrap_err();
        assert_eq!(expired_document.code, "document_session_not_found");
    }

    #[cfg(unix)]
    #[test]
    fn image_import_rejects_symbolic_link_sources_and_destinations() {
        use std::os::unix::fs::symlink;

        let temporary = tempfile::tempdir().unwrap();
        fs::create_dir(temporary.path().join("content")).unwrap();
        fs::write(temporary.path().join("hugo.toml"), "baseURL = '/'").unwrap();
        let actual_source = temporary.path().join("actual.png");
        fs::write(&actual_source, b"\x89PNG\r\n\x1a\nfixture").unwrap();
        let source_link = temporary.path().join("linked.png");
        symlink(&actual_source, &source_link).unwrap();
        let store = RepositoryStore::default();
        let session = store
            .open_repository(temporary.path().to_str().unwrap())
            .unwrap();
        let document = store
            .create_markdown_document(&session.session_id, "content/post.md", "# Post\n")
            .unwrap();
        let source_error = store
            .import_writing_image(
                &session.session_id,
                source_link.to_str().unwrap(),
                &document.document_id,
            )
            .unwrap_err();
        assert_eq!(source_error.code, "image_source_is_symlink");

        fs::create_dir_all(temporary.path().join("outside")).unwrap();
        fs::create_dir(temporary.path().join("static")).unwrap();
        symlink(
            temporary.path().join("outside"),
            temporary.path().join("static/images"),
        )
        .unwrap();
        let destination_error = store
            .import_writing_image(
                &session.session_id,
                actual_source.to_str().unwrap(),
                &document.document_id,
            )
            .unwrap_err();
        assert_eq!(destination_error.code, "image_destination_is_symlink");
    }
}
