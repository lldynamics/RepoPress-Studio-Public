use super::{CommandError, CommandResult};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::ffi::OsStr;
use std::fs;
use std::fs::{File, OpenOptions};
use std::io::Read;
use std::path::{Path, PathBuf};

const MAX_SCAN_DEPTH: usize = 64;
const MAX_ENTRIES: usize = 100_000;
const MAX_FILES: usize = 100_000;
const MAX_DOCUMENTS: usize = 1_000;
const MAX_FILE_BYTES: u64 = 4 * 1024 * 1024;
const MAX_TOTAL_BYTES: u64 = 32 * 1024 * 1024;
const MAX_OMISSIONS: usize = 100;
const EXCLUDED_DIRECTORIES: &[&str] = &[
    ".git",
    ".build",
    ".swiftpm",
    "node_modules",
    "target",
    "vendor",
];

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ContentHealthSourceDocument {
    pub relative_path: String,
    pub display_name: String,
    pub text: String,
    pub byte_size: u64,
    pub sha256: String,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ContentHealthSourceOmission {
    pub relative_path: Option<String>,
    pub code: String,
    pub message: String,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ContentHealthSourceSnapshot {
    pub documents: Vec<ContentHealthSourceDocument>,
    pub total_files: u64,
    pub scanned_files: u64,
    pub scanned_bytes: u64,
    pub omitted_files: u64,
    pub truncated: bool,
    pub omissions: Vec<ContentHealthSourceOmission>,
    pub warnings: Vec<String>,
}

#[derive(Clone, Copy)]
struct Limits {
    max_depth: usize,
    max_entries: usize,
    max_files: usize,
    max_documents: usize,
    max_file_bytes: u64,
    max_total_bytes: u64,
    max_omissions: usize,
}

impl Limits {
    const DEFAULT: Self = Self {
        max_depth: MAX_SCAN_DEPTH,
        max_entries: MAX_ENTRIES,
        max_files: MAX_FILES,
        max_documents: MAX_DOCUMENTS,
        max_file_bytes: MAX_FILE_BYTES,
        max_total_bytes: MAX_TOTAL_BYTES,
        max_omissions: MAX_OMISSIONS,
    };
}

struct Candidate {
    path: PathBuf,
    relative_path: String,
    display_name: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum StableReadFailure {
    Changed,
    ReadFailed,
    OutsideRepository,
    TooLarge,
    TotalByteLimit,
}

struct ScanState {
    visited_entries: usize,
    candidates: Vec<Candidate>,
    total_files: u64,
    omitted_files: u64,
    truncated: bool,
    omissions: Vec<ContentHealthSourceOmission>,
    warnings: Vec<String>,
}

impl ScanState {
    fn new() -> Self {
        Self {
            visited_entries: 0,
            candidates: Vec::new(),
            total_files: 0,
            omitted_files: 0,
            truncated: false,
            omissions: Vec::new(),
            warnings: Vec::new(),
        }
    }

    fn omit(&mut self, limits: Limits, relative_path: Option<String>, code: &str, message: &str) {
        self.omitted_files = self.omitted_files.saturating_add(1);
        if self.omissions.len() < limits.max_omissions {
            self.omissions.push(ContentHealthSourceOmission {
                relative_path,
                code: code.to_string(),
                message: message.to_string(),
            });
        }
    }

    fn warn(&mut self, value: &str) {
        if !self.warnings.iter().any(|warning| warning == value) {
            self.warnings.push(value.to_string());
        }
    }

    fn truncate(&mut self, value: &str) {
        self.truncated = true;
        self.warn(value);
    }
}

/// Reads bounded, repository-contained Markdown sources for local content-health analysis.
/// This operation never invokes Git, follows no symlinks, and does not write repository or
/// application state. `scanned_files` and `scanned_bytes` count successfully decoded sources;
/// `total_files` includes every regular Markdown candidate discovered before scan limits stop it.
pub fn read_content_health_sources(
    root: &Path,
    scan_root: &Path,
) -> CommandResult<ContentHealthSourceSnapshot> {
    read_content_health_sources_with_limits(root, scan_root, Limits::DEFAULT)
}

fn read_content_health_sources_with_limits(
    root: &Path,
    scan_root: &Path,
    limits: Limits,
) -> CommandResult<ContentHealthSourceSnapshot> {
    let root = validated_root(root)?;
    let scan_root = validated_scan_root(&root, scan_root)?;
    let mut state = ScanState::new();
    collect_candidates(&root, &scan_root, 0, limits, &mut state)?;
    state
        .candidates
        .sort_by(|left, right| left.relative_path.cmp(&right.relative_path));

    let mut documents = Vec::new();
    let mut scanned_files = 0u64;
    let mut scanned_bytes = 0u64;
    let mut read_bytes = 0u64;
    let candidates = std::mem::take(&mut state.candidates);
    for candidate in candidates {
        if documents.len() >= limits.max_documents {
            state.truncate("content_health_document_limit_reached");
            state.omit(
                limits,
                Some(candidate.relative_path),
                "content_health_document_limit_reached",
                "The content-health document result limit was reached.",
            );
            continue;
        }

        let bytes = match read_stable_source(
            &root,
            &candidate.path,
            limits.max_file_bytes,
            limits.max_total_bytes,
            &mut read_bytes,
        ) {
            Ok(bytes) => bytes,
            Err(StableReadFailure::TooLarge) => {
                state.omit(
                    limits,
                    Some(candidate.relative_path),
                    "content_health_file_too_large",
                    "The source exceeds the content-health per-file size limit.",
                );
                continue;
            }
            Err(StableReadFailure::TotalByteLimit) => {
                state.truncate("content_health_total_byte_limit_reached");
                state.omit(
                    limits,
                    Some(candidate.relative_path),
                    "content_health_total_byte_limit_reached",
                    "The content-health total source size limit was reached.",
                );
                continue;
            }
            Err(StableReadFailure::OutsideRepository) => {
                state.omit(
                    limits,
                    Some(candidate.relative_path),
                    "content_health_source_outside_repository",
                    "The source could not be verified inside the repository.",
                );
                continue;
            }
            Err(StableReadFailure::Changed) => {
                state.truncate("content_health_source_changed_during_scan");
                state.omit(
                    limits,
                    Some(candidate.relative_path),
                    "content_health_source_changed",
                    "The source changed while it was being scanned.",
                );
                continue;
            }
            Err(StableReadFailure::ReadFailed) => {
                state.omit(
                    limits,
                    Some(candidate.relative_path),
                    "content_health_read_failed",
                    "The source could not be read.",
                );
                continue;
            }
        };
        let payload = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(&bytes);
        let text = match std::str::from_utf8(payload) {
            Ok(value) => value.replace("\r\n", "\n").replace('\r', "\n"),
            Err(_) => {
                state.omit(
                    limits,
                    Some(candidate.relative_path),
                    "content_health_unsupported_encoding",
                    "Only UTF-8 Markdown sources can be scanned.",
                );
                continue;
            }
        };
        scanned_files = scanned_files.saturating_add(1);
        scanned_bytes = scanned_bytes.saturating_add(bytes.len() as u64);
        documents.push(ContentHealthSourceDocument {
            relative_path: candidate.relative_path,
            display_name: candidate.display_name,
            text,
            byte_size: bytes.len() as u64,
            sha256: sha256_hex(&bytes),
        });
    }

    Ok(ContentHealthSourceSnapshot {
        documents,
        total_files: state.total_files,
        scanned_files,
        scanned_bytes,
        omitted_files: state.omitted_files,
        truncated: state.truncated,
        omissions: state.omissions,
        warnings: state.warnings,
    })
}

fn validated_root(root: &Path) -> CommandResult<PathBuf> {
    let metadata = fs::symlink_metadata(root).map_err(|_| {
        CommandError::new(
            "content_health_repository_unavailable",
            "The repository root is unavailable for content-health scanning.",
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(outside_error());
    }
    fs::canonicalize(root).map_err(|_| {
        CommandError::new(
            "content_health_repository_unavailable",
            "The repository root is unavailable for content-health scanning.",
        )
    })
}

fn validated_scan_root(root: &Path, scan_root: &Path) -> CommandResult<PathBuf> {
    let metadata = fs::symlink_metadata(scan_root).map_err(|_| {
        CommandError::new(
            "content_health_scan_root_unavailable",
            "The content-health scan directory is unavailable.",
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(outside_error());
    }
    let canonical = fs::canonicalize(scan_root).map_err(|_| {
        CommandError::new(
            "content_health_scan_root_unavailable",
            "The content-health scan directory is unavailable.",
        )
    })?;
    if !canonical.starts_with(root) {
        return Err(outside_error());
    }
    Ok(canonical)
}

fn collect_candidates(
    root: &Path,
    directory: &Path,
    depth: usize,
    limits: Limits,
    state: &mut ScanState,
) -> CommandResult<()> {
    if depth > limits.max_depth {
        state.truncate("content_health_depth_limit_reached");
        state.omit(
            limits,
            relative_path(root, directory),
            "content_health_depth_limit_reached",
            "The content-health directory depth limit was reached.",
        );
        return Ok(());
    }
    let directory_entries = match fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(_) => {
            state.omit(
                limits,
                relative_path(root, directory),
                "content_health_directory_read_failed",
                "A repository directory could not be read.",
            );
            return Ok(());
        }
    };
    let mut entries = Vec::new();
    for entry in directory_entries {
        if state.visited_entries >= limits.max_entries {
            state.truncate("content_health_entry_limit_reached");
            state.omit(
                limits,
                relative_path(root, directory),
                "content_health_entry_limit_reached",
                "The content-health directory entry limit was reached.",
            );
            return Ok(());
        }
        state.visited_entries += 1;
        match entry {
            Ok(entry) => entries.push(entry),
            Err(_) => state.omit(
                limits,
                relative_path(root, directory),
                "content_health_directory_entry_failed",
                "A repository directory entry could not be inspected.",
            ),
        }
    }
    entries.sort_by_key(|entry| entry.file_name());

    for entry in entries {
        let path = entry.path();
        let metadata = match fs::symlink_metadata(&path) {
            Ok(metadata) => metadata,
            Err(_) => {
                state.omit(
                    limits,
                    relative_path(root, &path),
                    "content_health_source_unavailable",
                    "A repository source could not be inspected.",
                );
                continue;
            }
        };
        if metadata.file_type().is_symlink() {
            continue;
        }
        if metadata.is_dir() {
            if EXCLUDED_DIRECTORIES
                .iter()
                .any(|excluded| entry.file_name().eq_ignore_ascii_case(OsStr::new(excluded)))
            {
                continue;
            }
            collect_candidates(root, &path, depth + 1, limits, state)?;
        } else if metadata.is_file() && is_markdown(&path) {
            state.total_files = state.total_files.saturating_add(1);
            if state.candidates.len() >= limits.max_files {
                state.truncate("content_health_file_limit_reached");
                state.omit(
                    limits,
                    relative_path(root, &path),
                    "content_health_file_limit_reached",
                    "The content-health Markdown file limit was reached.",
                );
                continue;
            }
            let Some(relative_path) = relative_path(root, &path) else {
                state.omit(
                    limits,
                    None,
                    "content_health_path_not_representable",
                    "A Markdown source path is not representable as UTF-8.",
                );
                continue;
            };
            let Some(display_name) = path.file_name().and_then(OsStr::to_str).map(str::to_string)
            else {
                state.omit(
                    limits,
                    Some(relative_path),
                    "content_health_path_not_representable",
                    "A Markdown source path is not representable as UTF-8.",
                );
                continue;
            };
            state.candidates.push(Candidate {
                path,
                relative_path,
                display_name,
            });
        }
    }
    Ok(())
}

fn is_markdown(path: &Path) -> bool {
    path.extension()
        .and_then(OsStr::to_str)
        .map(|extension| {
            matches!(
                extension.to_ascii_lowercase().as_str(),
                "md" | "markdown" | "mdx"
            )
        })
        .unwrap_or(false)
}

fn relative_path(root: &Path, path: &Path) -> Option<String> {
    path.strip_prefix(root)
        .ok()?
        .to_str()
        .map(|value| value.replace(std::path::MAIN_SEPARATOR, "/"))
}

#[cfg(target_os = "linux")]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct StableFileIdentity {
    device: u64,
    inode: u64,
    byte_size: u64,
    modified_seconds: i64,
    modified_nanoseconds: i64,
    changed_seconds: i64,
    changed_nanoseconds: i64,
    hard_link_count: u64,
}

#[cfg(target_os = "linux")]
fn stable_file_identity(metadata: &fs::Metadata) -> StableFileIdentity {
    use std::os::unix::fs::MetadataExt;

    StableFileIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
        byte_size: metadata.len(),
        modified_seconds: metadata.mtime(),
        modified_nanoseconds: metadata.mtime_nsec(),
        changed_seconds: metadata.ctime(),
        changed_nanoseconds: metadata.ctime_nsec(),
        hard_link_count: metadata.nlink(),
    }
}

#[cfg(target_os = "linux")]
fn verify_linux_descriptor_path(
    file: &File,
    expected: &Path,
    root: &Path,
) -> Result<(), StableReadFailure> {
    use std::os::fd::AsRawFd;

    let descriptor_path = PathBuf::from(format!("/proc/self/fd/{}", file.as_raw_fd()));
    let resolved = fs::canonicalize(descriptor_path).map_err(|_| StableReadFailure::Changed)?;
    if !resolved.starts_with(root) {
        return Err(StableReadFailure::OutsideRepository);
    }
    (resolved == expected)
        .then_some(())
        .ok_or(StableReadFailure::Changed)
}

#[cfg(target_os = "linux")]
fn read_stable_source(
    root: &Path,
    candidate: &Path,
    max_file_bytes: u64,
    max_total_bytes: u64,
    read_bytes: &mut u64,
) -> Result<Vec<u8>, StableReadFailure> {
    use std::os::unix::fs::OpenOptionsExt;

    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(candidate)
        .map_err(|error| {
            if error.raw_os_error() == Some(libc::ELOOP) {
                StableReadFailure::Changed
            } else {
                StableReadFailure::ReadFailed
            }
        })?;
    let before = file.metadata().map_err(|_| StableReadFailure::ReadFailed)?;
    if !before.is_file() {
        return Err(StableReadFailure::Changed);
    }
    verify_linux_descriptor_path(&file, candidate, root)?;
    let before_identity = stable_file_identity(&before);
    if before_identity.hard_link_count == 0 {
        return Err(StableReadFailure::Changed);
    }
    if before_identity.byte_size > max_file_bytes {
        return Err(StableReadFailure::TooLarge);
    }
    if before_identity.byte_size > max_total_bytes.saturating_sub(*read_bytes) {
        return Err(StableReadFailure::TotalByteLimit);
    }

    let read_limit = before_identity.byte_size;
    *read_bytes = (*read_bytes).saturating_add(read_limit);
    let mut bytes = Vec::with_capacity(before_identity.byte_size as usize);
    (&mut file)
        .take(read_limit.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|_| StableReadFailure::ReadFailed)?;
    let after = file.metadata().map_err(|_| StableReadFailure::ReadFailed)?;
    verify_linux_descriptor_path(&file, candidate, root)?;
    let after_identity = stable_file_identity(&after);
    if bytes.len() as u64 != before_identity.byte_size
        || bytes.len() as u64 > read_limit
        || after_identity.hard_link_count == 0
        || after_identity != before_identity
    {
        return Err(StableReadFailure::Changed);
    }
    Ok(bytes)
}

#[cfg(not(target_os = "linux"))]
#[derive(Clone, Debug, Eq, PartialEq)]
struct StableFileIdentity {
    byte_size: u64,
    modified_at: Option<std::time::SystemTime>,
    is_regular_file: bool,
}

#[cfg(not(target_os = "linux"))]
fn stable_file_identity(metadata: &fs::Metadata) -> StableFileIdentity {
    StableFileIdentity {
        byte_size: metadata.len(),
        modified_at: metadata.modified().ok(),
        is_regular_file: metadata.is_file(),
    }
}

#[cfg(not(target_os = "linux"))]
fn read_stable_source(
    root: &Path,
    candidate: &Path,
    max_file_bytes: u64,
    max_total_bytes: u64,
    read_bytes: &mut u64,
) -> Result<Vec<u8>, StableReadFailure> {
    let before_path = fs::canonicalize(candidate).map_err(|_| StableReadFailure::ReadFailed)?;
    let before_metadata =
        fs::symlink_metadata(candidate).map_err(|_| StableReadFailure::ReadFailed)?;
    if before_metadata.file_type().is_symlink()
        || !before_metadata.is_file()
        || before_path != candidate
        || !before_path.starts_with(root)
    {
        return Err(StableReadFailure::OutsideRepository);
    }
    let before_identity = stable_file_identity(&before_metadata);
    if before_identity.byte_size > max_file_bytes {
        return Err(StableReadFailure::TooLarge);
    }
    if before_identity.byte_size > max_total_bytes.saturating_sub(*read_bytes) {
        return Err(StableReadFailure::TotalByteLimit);
    }
    let mut file = File::open(candidate).map_err(|_| StableReadFailure::ReadFailed)?;
    let read_limit = before_identity.byte_size;
    *read_bytes = (*read_bytes).saturating_add(read_limit);
    let mut bytes = Vec::with_capacity(before_identity.byte_size as usize);
    (&mut file)
        .take(read_limit.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|_| StableReadFailure::ReadFailed)?;
    let after_path = fs::canonicalize(candidate).map_err(|_| StableReadFailure::Changed)?;
    let after_metadata = fs::symlink_metadata(candidate).map_err(|_| StableReadFailure::Changed)?;
    if bytes.len() as u64 != before_identity.byte_size
        || bytes.len() as u64 > read_limit
        || after_path != before_path
        || after_path != candidate
        || !after_path.starts_with(root)
        || stable_file_identity(&after_metadata) != before_identity
    {
        return Err(StableReadFailure::Changed);
    }
    Ok(bytes)
}

fn sha256_hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn outside_error() -> CommandError {
    CommandError::new(
        "content_health_outside_repository",
        "The content-health scan path is outside the repository.",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn limits() -> Limits {
        Limits {
            max_depth: 64,
            max_entries: 100,
            max_files: 100,
            max_documents: 100,
            max_file_bytes: 100,
            max_total_bytes: 1_000,
            max_omissions: 100,
        }
    }

    #[test]
    fn reads_bom_documents_normalizes_line_endings_and_hashes_raw_bytes() {
        let temporary = tempfile::tempdir().unwrap();
        let content = temporary.path().join("content");
        fs::create_dir(&content).unwrap();
        let bytes = b"\xEF\xBB\xBFone\r\ntwo\rthree\n";
        fs::write(content.join("article.MD"), bytes).unwrap();

        let snapshot = read_content_health_sources(temporary.path(), &content).unwrap();

        assert_eq!(snapshot.total_files, 1);
        assert_eq!(snapshot.scanned_files, 1);
        assert_eq!(snapshot.scanned_bytes, bytes.len() as u64);
        assert_eq!(snapshot.documents[0].text, "one\ntwo\nthree\n");
        assert_eq!(snapshot.documents[0].sha256, sha256_hex(bytes));
        assert_eq!(snapshot.documents[0].relative_path, "content/article.MD");
    }

    #[test]
    fn records_invalid_utf8_as_an_omission() {
        let temporary = tempfile::tempdir().unwrap();
        fs::write(temporary.path().join("invalid.md"), [0xff, 0xfe]).unwrap();

        let snapshot = read_content_health_sources(temporary.path(), temporary.path()).unwrap();

        assert!(snapshot.documents.is_empty());
        assert_eq!(snapshot.total_files, 1);
        assert_eq!(snapshot.scanned_files, 0);
        assert_eq!(snapshot.omitted_files, 1);
        assert_eq!(
            snapshot.omissions[0].code,
            "content_health_unsupported_encoding"
        );
    }

    #[test]
    fn invalid_utf8_still_consumes_the_total_read_budget() {
        let temporary = tempfile::tempdir().unwrap();
        fs::write(temporary.path().join("a-invalid.md"), [0xff, 0xfe]).unwrap();
        fs::write(temporary.path().join("b-valid.md"), "x").unwrap();
        let limits = Limits {
            max_total_bytes: 2,
            ..limits()
        };

        let snapshot =
            read_content_health_sources_with_limits(temporary.path(), temporary.path(), limits)
                .unwrap();

        assert!(snapshot.documents.is_empty());
        assert_eq!(snapshot.scanned_bytes, 0);
        assert!(snapshot.truncated);
        assert!(snapshot
            .omissions
            .iter()
            .any(|omission| omission.code == "content_health_unsupported_encoding"));
        assert!(snapshot
            .omissions
            .iter()
            .any(|omission| omission.code == "content_health_total_byte_limit_reached"));
    }

    #[test]
    fn enforces_file_and_total_budgets_with_bounded_test_limits() {
        let temporary = tempfile::tempdir().unwrap();
        fs::write(temporary.path().join("a.md"), "1234").unwrap();
        fs::write(temporary.path().join("b.md"), "5678").unwrap();
        fs::write(temporary.path().join("large.md"), "x".repeat(20)).unwrap();
        let limits = Limits {
            max_file_bytes: 10,
            max_total_bytes: 5,
            ..limits()
        };

        let snapshot =
            read_content_health_sources_with_limits(temporary.path(), temporary.path(), limits)
                .unwrap();

        assert_eq!(snapshot.documents.len(), 1);
        assert_eq!(snapshot.documents[0].relative_path, "a.md");
        assert!(snapshot.truncated);
        assert!(snapshot
            .omissions
            .iter()
            .any(|omission| omission.code == "content_health_total_byte_limit_reached"));
        assert!(snapshot
            .omissions
            .iter()
            .any(|omission| omission.code == "content_health_file_too_large"));
    }

    #[test]
    fn limits_markdown_file_collection_without_silent_loss() {
        let temporary = tempfile::tempdir().unwrap();
        fs::write(temporary.path().join("a.md"), "a").unwrap();
        fs::write(temporary.path().join("b.md"), "b").unwrap();
        let limits = Limits {
            max_files: 1,
            ..limits()
        };

        let snapshot =
            read_content_health_sources_with_limits(temporary.path(), temporary.path(), limits)
                .unwrap();

        assert_eq!(snapshot.total_files, 2);
        assert_eq!(snapshot.documents.len(), 1);
        assert!(snapshot.truncated);
        assert!(snapshot
            .omissions
            .iter()
            .any(|omission| omission.code == "content_health_file_limit_reached"));
    }

    #[cfg(unix)]
    #[test]
    fn ignores_symlinks_and_rejects_scan_roots_outside_the_repository() {
        use std::os::unix::fs::symlink;

        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        fs::write(root.path().join("inside.md"), "inside").unwrap();
        fs::write(outside.path().join("outside.md"), "outside").unwrap();
        symlink(
            outside.path().join("outside.md"),
            root.path().join("linked.md"),
        )
        .unwrap();
        symlink(outside.path(), root.path().join("linked-directory")).unwrap();

        let snapshot = read_content_health_sources(root.path(), root.path()).unwrap();
        assert_eq!(snapshot.documents.len(), 1);
        assert_eq!(snapshot.documents[0].relative_path, "inside.md");
        let error = read_content_health_sources(root.path(), outside.path()).unwrap_err();
        assert_eq!(error.code, "content_health_outside_repository");
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn stable_descriptor_read_accepts_regular_file_and_rejects_final_symlink() {
        use std::os::unix::fs::symlink;

        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("source.md");
        let link = root.path().join("link.md");
        fs::write(&source, "stable source").unwrap();
        symlink(&source, &link).unwrap();
        let mut read_bytes = 0;

        assert_eq!(
            read_stable_source(root.path(), &source, 100, 100, &mut read_bytes).unwrap(),
            b"stable source"
        );
        assert_eq!(
            read_stable_source(root.path(), &link, 100, 100, &mut read_bytes),
            Err(StableReadFailure::Changed)
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn descriptor_path_verification_rejects_an_unexpected_source_path() {
        use std::os::unix::fs::OpenOptionsExt;

        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("source.md");
        let other = root.path().join("other.md");
        fs::write(&source, "source").unwrap();
        fs::write(&other, "other").unwrap();
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&source)
            .unwrap();

        assert_eq!(
            verify_linux_descriptor_path(&file, &other, root.path()),
            Err(StableReadFailure::Changed)
        );
    }

    #[test]
    fn sorts_documents_and_marks_result_truncation_stably() {
        let temporary = tempfile::tempdir().unwrap();
        fs::write(temporary.path().join("z.md"), "z").unwrap();
        fs::write(temporary.path().join("b.md"), "b").unwrap();
        fs::write(temporary.path().join("a.md"), "a").unwrap();
        let limits = Limits {
            max_documents: 2,
            ..limits()
        };

        let snapshot =
            read_content_health_sources_with_limits(temporary.path(), temporary.path(), limits)
                .unwrap();

        assert_eq!(
            snapshot
                .documents
                .iter()
                .map(|document| document.relative_path.as_str())
                .collect::<Vec<_>>(),
            ["a.md", "b.md"]
        );
        assert_eq!(snapshot.total_files, 3);
        assert!(snapshot.truncated);
        assert_eq!(snapshot.omitted_files, 1);
        assert_eq!(
            snapshot.omissions[0].code,
            "content_health_document_limit_reached"
        );
    }
}
