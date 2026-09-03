use super::{
    CommandError, CommandResult, DocumentSnapshot, LineEnding, MarkdownFileEntry,
    RepositorySessionSnapshot,
};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::ffi::OsStr;
use std::fs;
use std::io::Write;
use std::path::{Component, Path, PathBuf};
use std::sync::Mutex;
use tempfile::Builder;
use uuid::Uuid;

const MAX_DOCUMENT_BYTES: u64 = 4 * 1024 * 1024;
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

#[derive(Debug)]
struct RepositorySession {
    root: PathBuf,
    content_root: Option<PathBuf>,
    documents: HashMap<String, DocumentRecord>,
}

#[derive(Default, Debug)]
pub struct RepositoryStore {
    sessions: Mutex<HashMap<String, RepositorySession>>,
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

    pub fn root_for_session(&self, session_id: &str) -> CommandResult<PathBuf> {
        let sessions = self.lock_sessions()?;
        let session = sessions.get(session_id).ok_or_else(session_not_found)?;
        revalidate_root(&session.root)?;
        Ok(session.root.clone())
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
    let candidate = root.join("content");
    let metadata = fs::symlink_metadata(&candidate).ok()?;
    if metadata.is_dir() && !metadata.file_type().is_symlink() {
        Some(candidate)
    } else {
        None
    }
}

fn detect_site_kind(root: &Path) -> String {
    if root.join("zola.toml").is_file()
        || (root.join("config.toml").is_file() && root.join("content").is_dir())
    {
        "zola".to_string()
    } else if root.join("hugo.toml").is_file() || root.join("config.yaml").is_file() {
        "hugo".to_string()
    } else if ["astro.config.mjs", "astro.config.js", "astro.config.ts"]
        .iter()
        .any(|name| root.join(name).is_file())
    {
        "astro".to_string()
    } else if root.join("_config.yml").is_file() {
        "jekyll-or-hexo".to_string()
    } else {
        "unknown".to_string()
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

fn sha256_hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

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
}
