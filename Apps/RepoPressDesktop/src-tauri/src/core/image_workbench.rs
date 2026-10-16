//! Bounded, local-only image inventory and preview helpers for an already-open repository.
//!
//! The command layer is responsible for resolving a `RepositoryStore` session before calling
//! this module.  This module deliberately does not follow links, launch tools, or write files.

use super::{CommandError, CommandResult};
use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::ffi::{CString, OsStr, OsString};
use std::fs::{self, File};
use std::io::Read;
#[cfg(unix)]
use std::os::unix::ffi::OsStrExt;
#[cfg(unix)]
use std::os::unix::io::{AsRawFd, FromRawFd};
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

const MAX_DEPTH: usize = 64;
const MAX_ENTRIES: usize = 100_000;
const MAX_IMAGES: usize = 1_000;
const MAX_CANDIDATES: usize = 1_000;
const MAX_FILE_BYTES: u64 = 8 * 1024 * 1024;
const MAX_TOTAL_BYTES: u64 = 64 * 1024 * 1024;
const MAX_PIXELS: u64 = 40_000_000;
const MAX_WARNINGS: usize = 30;
const EXCLUDED_DIRECTORIES: &[&str] = &[
    ".git",
    ".build",
    ".swiftpm",
    "node_modules",
    "target",
    "vendor",
    "dist",
    "build",
];

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RepositoryImage {
    pub relative_path: String,
    pub file_name: String,
    pub byte_size: u64,
    pub mime_type: String,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub sha256: String,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RepositoryImageSnapshot {
    pub images: Vec<RepositoryImage>,
    pub scanned_entries: u64,
    pub scanned_bytes: u64,
    pub omitted_files: u64,
    pub truncated: bool,
    pub warnings: Vec<String>,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RepositoryImagePreview {
    pub relative_path: String,
    pub mime_type: String,
    pub data_base64: String,
    pub sha256: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ImageFormat {
    Png,
    Jpeg,
    Gif,
    Webp,
}

impl ImageFormat {
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

struct Candidate {
    parent: Arc<File>,
    name: OsString,
    expected_path: PathBuf,
    relative_path: String,
    file_name: String,
}

struct ScanState {
    entries: u64,
    omitted: u64,
    truncated: bool,
    warnings: Vec<String>,
    candidates: Vec<Candidate>,
}

impl ScanState {
    fn warn(&mut self, warning: impl Into<String>) {
        let warning = warning.into();
        if self.warnings.len() < MAX_WARNINGS && !self.warnings.contains(&warning) {
            self.warnings.push(warning);
        }
    }

    fn omit(&mut self, warning: impl Into<String>) {
        self.omitted = self.omitted.saturating_add(1);
        self.warn(warning);
    }

    fn truncate(&mut self, warning: impl Into<String>) {
        self.truncated = true;
        self.warn(warning);
    }
}

/// Returns an inventory of supported raster files below `root`.  It never follows symlinks and
/// always marks capacity and read failures as partial inventory through `truncated` or warnings.
pub fn inspect_repository_images(root: &Path) -> CommandResult<RepositoryImageSnapshot> {
    let root = validate_root(root)?;
    let root_directory =
        Arc::new(open_directory(&root.canonical).map_err(|_| repository_unavailable())?);
    let mut state = ScanState {
        entries: 0,
        omitted: 0,
        truncated: false,
        warnings: Vec::new(),
        candidates: Vec::new(),
    };
    collect_candidates(
        &root.canonical,
        &root.canonical,
        &root_directory,
        0,
        &mut state,
    )?;
    state
        .candidates
        .sort_by(|left, right| left.relative_path.cmp(&right.relative_path));

    let candidates = std::mem::take(&mut state.candidates);
    let mut images = Vec::new();
    let mut scanned_bytes = 0u64;
    for candidate in candidates {
        if images.len() >= MAX_IMAGES {
            state.truncate("image_inventory_limit_reached");
            state.omit("image_inventory_limit_reached");
            continue;
        }
        let remaining = MAX_TOTAL_BYTES.saturating_sub(scanned_bytes);
        let (bytes, charged_bytes) = match read_stable_file(
            &root.canonical,
            &candidate.parent,
            &candidate.name,
            &candidate.expected_path,
            remaining,
        ) {
            Ok(value) => value,
            Err((ReadFailure::TooLarge, charged)) => {
                scanned_bytes = scanned_bytes.saturating_add(charged);
                state.truncate("image_file_too_large");
                state.omit("image_file_too_large");
                continue;
            }
            Err((ReadFailure::TotalLimit, charged)) => {
                scanned_bytes = scanned_bytes.saturating_add(charged);
                state.truncate("image_total_byte_limit_reached");
                state.omit("image_total_byte_limit_reached");
                continue;
            }
            Err((ReadFailure::Changed, charged)) => {
                scanned_bytes = scanned_bytes.saturating_add(charged);
                state.truncate("image_changed_during_scan");
                state.omit("image_changed_during_scan");
                continue;
            }
            Err((ReadFailure::Unavailable, charged)) => {
                scanned_bytes = scanned_bytes.saturating_add(charged);
                state.truncate("image_read_failed");
                state.omit("image_read_failed");
                continue;
            }
        };
        scanned_bytes = scanned_bytes.saturating_add(charged_bytes);
        let Some(format) = image_format(&bytes) else {
            state.omit("image_signature_invalid");
            continue;
        };
        let extension = Path::new(&candidate.name)
            .extension()
            .and_then(OsStr::to_str);
        if !extension.is_some_and(|extension| format.accepts_extension(extension)) {
            state.omit("image_extension_mismatch");
            continue;
        }
        let (width, height) = match dimensions(format, &bytes) {
            Ok(dimensions) => dimensions,
            Err(DimensionFailure::PixelLimit) => {
                state.omit("image_pixel_limit_exceeded");
                continue;
            }
            Err(DimensionFailure::Unknown) => {
                state.omit("image_dimensions_unknown");
                continue;
            }
        };
        images.push(RepositoryImage {
            relative_path: candidate.relative_path,
            file_name: candidate.file_name,
            byte_size: bytes.len() as u64,
            mime_type: format.mime_type().to_string(),
            width: Some(width),
            height: Some(height),
            sha256: sha256_hex(&bytes),
        });
    }
    ensure_root_unchanged(&root)?;
    Ok(RepositoryImageSnapshot {
        images,
        scanned_entries: state.entries,
        scanned_bytes,
        omitted_files: state.omitted,
        truncated: state.truncated,
        warnings: state.warnings,
    })
}

/// Reopens one previously inventoried raster file and fails closed unless its exact digest still
/// matches.  This deliberately returns bare base64, never a data URL or SVG markup.
pub fn read_repository_image(
    root: &Path,
    relative_path: &str,
    expected_sha256: &str,
) -> CommandResult<RepositoryImagePreview> {
    let root = validate_root(root)?;
    let relative = validate_relative_path(relative_path)?;
    ensure_root_unchanged(&root)?;
    let (parent, name, candidate) = validate_ancestors(&root.canonical, &relative)?;
    let (bytes, _) = read_stable_file(&root.canonical, &parent, &name, &candidate, MAX_FILE_BYTES)
        .map_err(|(failure, _)| preview_read_error(failure))?;
    ensure_root_unchanged(&root)?;
    let actual_sha256 = sha256_hex(&bytes);
    if !valid_sha256(expected_sha256) || !constant_time_eq(expected_sha256, &actual_sha256) {
        return Err(CommandError::new(
            "image_preview_changed",
            "The repository image no longer matches the inventoried content.",
        ));
    }
    let format = image_format(&bytes).ok_or_else(|| {
        CommandError::new(
            "image_preview_unsupported",
            "Only verified PNG, JPEG, GIF, and WebP images can be previewed.",
        )
    })?;
    let extension = candidate.extension().and_then(OsStr::to_str);
    if !extension.is_some_and(|extension| format.accepts_extension(extension)) {
        return Err(CommandError::new(
            "image_preview_unsupported",
            "The image filename extension does not match its file signature.",
        ));
    }
    dimensions(format, &bytes).map_err(|failure| match failure {
        DimensionFailure::PixelLimit => CommandError::new(
            "image_preview_pixel_limit",
            "The image dimensions exceed the local preview safety limit.",
        ),
        DimensionFailure::Unknown => CommandError::new(
            "image_preview_dimensions_unknown",
            "The image dimensions could not be safely confirmed.",
        ),
    })?;
    Ok(RepositoryImagePreview {
        relative_path: relative_path.to_string(),
        mime_type: format.mime_type().to_string(),
        data_base64: STANDARD.encode(bytes),
        sha256: actual_sha256,
    })
}

struct RepositoryRoot {
    input: PathBuf,
    canonical: PathBuf,
    identity: RootIdentity,
}

#[cfg(target_os = "linux")]
#[derive(Clone, Copy, Eq, PartialEq)]
struct RootIdentity {
    device: u64,
    inode: u64,
}

#[cfg(target_os = "linux")]
fn root_identity(metadata: &fs::Metadata) -> RootIdentity {
    use std::os::unix::fs::MetadataExt;
    RootIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
    }
}

#[cfg(not(target_os = "linux"))]
#[derive(Clone, Copy, Eq, PartialEq)]
struct RootIdentity;
#[cfg(not(target_os = "linux"))]
fn root_identity(_: &fs::Metadata) -> RootIdentity {
    RootIdentity
}

fn validate_root(root: &Path) -> CommandResult<RepositoryRoot> {
    let metadata = fs::symlink_metadata(root).map_err(|_| repository_unavailable())?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(repository_unavailable());
    }
    let canonical = fs::canonicalize(root).map_err(|_| repository_unavailable())?;
    let canonical_metadata =
        fs::symlink_metadata(&canonical).map_err(|_| repository_unavailable())?;
    if canonical_metadata.file_type().is_symlink() || !canonical_metadata.is_dir() {
        return Err(repository_unavailable());
    }
    Ok(RepositoryRoot {
        input: root.to_path_buf(),
        canonical,
        identity: root_identity(&canonical_metadata),
    })
}

fn ensure_root_unchanged(root: &RepositoryRoot) -> CommandResult<()> {
    let current = validate_root(&root.input).map_err(|_| {
        CommandError::new(
            "image_repository_changed",
            "The repository root changed while reading the image.",
        )
    })?;
    if current.canonical != root.canonical || current.identity != root.identity {
        return Err(CommandError::new(
            "image_repository_changed",
            "The repository root changed while reading the image.",
        ));
    }
    Ok(())
}

fn collect_candidates(
    root: &Path,
    directory: &Path,
    directory_file: &Arc<File>,
    depth: usize,
    state: &mut ScanState,
) -> CommandResult<()> {
    if depth > MAX_DEPTH {
        state.truncate("image_depth_limit_reached");
        state.omit("image_depth_limit_reached");
        return Ok(());
    }
    if verify_descriptor_path(directory_file, directory, root).is_err() {
        state.truncate("image_directory_changed");
        state.omit("image_directory_changed");
        return Ok(());
    }
    let directory_entries = match fs::read_dir(descriptor_path(directory_file)) {
        Ok(entries) => entries,
        Err(_) => {
            state.truncate("image_directory_read_failed");
            state.omit("image_directory_read_failed");
            return Ok(());
        }
    };
    let mut entries: Vec<fs::DirEntry> = Vec::new();
    for entry in directory_entries {
        if state.entries as usize >= MAX_ENTRIES {
            state.truncate("image_entry_limit_reached");
            state.omit("image_entry_limit_reached");
            break;
        }
        state.entries = state.entries.saturating_add(1);
        match entry {
            Ok(entry) => entries.push(entry),
            Err(_) => {
                state.truncate("image_directory_entry_failed");
                state.omit("image_directory_entry_failed");
            }
        }
    }
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        let name = entry.file_name();
        let path = directory.join(&name);
        let metadata = match fs::symlink_metadata(entry.path()) {
            Ok(metadata) => metadata,
            Err(_) => {
                state.truncate("image_entry_unavailable");
                state.omit("image_entry_unavailable");
                continue;
            }
        };
        if metadata.file_type().is_symlink() {
            state.omit("image_symlink_skipped");
            continue;
        }
        if metadata.is_dir() {
            if is_excluded(&entry.file_name()) {
                continue;
            }
            let child = match open_directory_at(directory_file, &name) {
                Ok(child) => Arc::new(child),
                Err(_) => {
                    state.truncate("image_directory_changed");
                    state.omit("image_directory_changed");
                    continue;
                }
            };
            collect_candidates(root, &path, &child, depth + 1, state)?;
        } else if metadata.is_file() && is_image_candidate(&path) {
            let Some(relative_path) = relative_path(root, &path) else {
                state.omit("image_path_not_utf8");
                continue;
            };
            let Some(file_name) = path.file_name().and_then(OsStr::to_str).map(str::to_owned)
            else {
                state.omit("image_path_not_utf8");
                continue;
            };
            if path
                .extension()
                .and_then(OsStr::to_str)
                .is_some_and(|ext| ext.eq_ignore_ascii_case("svg"))
            {
                state.omit("image_svg_not_supported");
                continue;
            }
            if state.candidates.len() >= MAX_CANDIDATES {
                state.truncate("image_candidate_limit_reached");
                state.omit("image_candidate_limit_reached");
                continue;
            }
            state.candidates.push(Candidate {
                parent: Arc::clone(directory_file),
                name,
                expected_path: path,
                relative_path,
                file_name,
            });
        } else if !metadata.is_file() {
            state.omit("image_special_file_skipped");
        }
    }
    Ok(())
}

fn is_excluded(name: &OsStr) -> bool {
    EXCLUDED_DIRECTORIES
        .iter()
        .any(|excluded| name.eq_ignore_ascii_case(OsStr::new(excluded)))
}

fn is_image_candidate(path: &Path) -> bool {
    path.extension()
        .and_then(OsStr::to_str)
        .is_some_and(|extension| {
            matches!(
                extension.to_ascii_lowercase().as_str(),
                "png" | "jpg" | "jpeg" | "gif" | "webp" | "svg"
            )
        })
}

fn relative_path(root: &Path, path: &Path) -> Option<String> {
    path.strip_prefix(root)
        .ok()?
        .to_str()
        .map(|value| value.replace(std::path::MAIN_SEPARATOR, "/"))
}

fn validate_relative_path(relative_path: &str) -> CommandResult<PathBuf> {
    if relative_path.is_empty()
        || relative_path.contains('\\')
        || relative_path.bytes().any(|byte| byte.is_ascii_control())
        || relative_path.starts_with('/')
        || relative_path.ends_with('/')
        || relative_path
            .split('/')
            .any(|part| part.is_empty() || part == "." || part == "..")
    {
        return Err(invalid_preview_path());
    }
    let path = Path::new(relative_path);
    if path.is_absolute()
        || path
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return Err(invalid_preview_path());
    }
    Ok(path.to_path_buf())
}

fn validate_ancestors(root: &Path, relative: &Path) -> CommandResult<(File, OsString, PathBuf)> {
    let mut current = root.to_path_buf();
    let mut directory = open_directory(root).map_err(|_| invalid_preview_path())?;
    let components: Vec<_> = relative.components().collect();
    for component in &components[..components.len().saturating_sub(1)] {
        current.push(component.as_os_str());
        if is_excluded(component.as_os_str()) {
            return Err(invalid_preview_path());
        }
        directory = open_directory_at(&directory, component.as_os_str())
            .map_err(|_| invalid_preview_path())?;
        if verify_descriptor_path(&directory, &current, root).is_err() {
            return Err(invalid_preview_path());
        }
    }
    let file_name = components
        .last()
        .ok_or_else(invalid_preview_path)?
        .as_os_str();
    if is_excluded(file_name) {
        return Err(invalid_preview_path());
    }
    Ok((directory, file_name.to_os_string(), root.join(relative)))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ReadFailure {
    Changed,
    Unavailable,
    TooLarge,
    TotalLimit,
}

#[cfg(unix)]
fn c_path(path: &OsStr) -> Result<CString, ReadFailure> {
    CString::new(path.as_bytes()).map_err(|_| ReadFailure::Unavailable)
}

#[cfg(unix)]
fn open_directory(path: &Path) -> Result<File, ReadFailure> {
    let path = c_path(path.as_os_str())?;
    // SAFETY: `path` is NUL-terminated and this takes ownership of no Rust resources.
    let descriptor = unsafe {
        libc::open(
            path.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if descriptor < 0 {
        return Err(ReadFailure::Unavailable);
    }
    // SAFETY: `open` returned a new owned descriptor.
    Ok(unsafe { File::from_raw_fd(descriptor) })
}

#[cfg(unix)]
fn open_directory_at(parent: &File, name: &OsStr) -> Result<File, ReadFailure> {
    let name = c_path(name)?;
    // SAFETY: the parent descriptor is valid for this call and `name` is NUL-terminated.
    let descriptor = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if descriptor < 0 {
        return Err(ReadFailure::Unavailable);
    }
    // SAFETY: `openat` returned a new owned descriptor.
    Ok(unsafe { File::from_raw_fd(descriptor) })
}

#[cfg(unix)]
fn open_file_at(parent: &File, name: &OsStr) -> Result<File, ReadFailure> {
    let name = c_path(name)?;
    // O_NONBLOCK prevents a manually supplied FIFO from blocking a preview before metadata
    // rejects it as non-regular.
    // SAFETY: the parent descriptor is valid for this call and `name` is NUL-terminated.
    let descriptor = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    };
    if descriptor < 0 {
        return Err(ReadFailure::Unavailable);
    }
    // SAFETY: `openat` returned a new owned descriptor.
    Ok(unsafe { File::from_raw_fd(descriptor) })
}

#[cfg(not(unix))]
fn open_directory(path: &Path) -> Result<File, ReadFailure> {
    File::open(path).map_err(|_| ReadFailure::Unavailable)
}
#[cfg(not(unix))]
fn open_directory_at(parent: &File, name: &OsStr) -> Result<File, ReadFailure> {
    File::open(descriptor_path(parent).join(name)).map_err(|_| ReadFailure::Unavailable)
}
#[cfg(not(unix))]
fn open_file_at(parent: &File, name: &OsStr) -> Result<File, ReadFailure> {
    File::open(descriptor_path(parent).join(name)).map_err(|_| ReadFailure::Unavailable)
}

#[cfg(target_os = "linux")]
fn descriptor_path(file: &File) -> PathBuf {
    PathBuf::from(format!("/proc/self/fd/{}", file.as_raw_fd()))
}

#[cfg(not(target_os = "linux"))]
fn descriptor_path(_file: &File) -> PathBuf {
    PathBuf::new()
}

fn read_stable_file(
    root: &Path,
    parent: &File,
    name: &OsStr,
    candidate: &Path,
    byte_budget: u64,
) -> Result<(Vec<u8>, u64), (ReadFailure, u64)> {
    let mut file = open_file_at(parent, name).map_err(|failure| (failure, 0))?;
    let before = file.metadata().map_err(|_| (ReadFailure::Unavailable, 0))?;
    if !before.is_file() {
        return Err((ReadFailure::Changed, 0));
    }
    verify_descriptor_path(&file, candidate, root).map_err(|failure| (failure, 0))?;
    let before_identity = file_identity(&before);
    if before_identity.size > MAX_FILE_BYTES {
        return Err((ReadFailure::TooLarge, 0));
    }
    if before_identity.size > byte_budget {
        return Err((ReadFailure::TotalLimit, 0));
    }
    // Charge the reserved size before I/O. A file that changes or fails to read cannot be used
    // to make repeated failed attempts bypass the operation's 64 MiB read budget.
    let charged_bytes = before_identity.size;
    let mut bytes = Vec::with_capacity(before_identity.size as usize);
    (&mut file)
        .take(before_identity.size)
        .read_to_end(&mut bytes)
        .map_err(|_| (ReadFailure::Unavailable, charged_bytes))?;
    let after = file
        .metadata()
        .map_err(|_| (ReadFailure::Unavailable, charged_bytes))?;
    verify_descriptor_path(&file, candidate, root).map_err(|failure| (failure, charged_bytes))?;
    if bytes.len() as u64 != before_identity.size || file_identity(&after) != before_identity {
        return Err((ReadFailure::Changed, charged_bytes));
    }
    Ok((bytes, charged_bytes))
}

#[cfg(target_os = "linux")]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct FileIdentity {
    device: u64,
    inode: u64,
    size: u64,
    mtime: i64,
    mtime_nsec: i64,
    ctime: i64,
    ctime_nsec: i64,
    links: u64,
}

#[cfg(target_os = "linux")]
fn file_identity(metadata: &fs::Metadata) -> FileIdentity {
    use std::os::unix::fs::MetadataExt;
    FileIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
        size: metadata.len(),
        mtime: metadata.mtime(),
        mtime_nsec: metadata.mtime_nsec(),
        ctime: metadata.ctime(),
        ctime_nsec: metadata.ctime_nsec(),
        links: metadata.nlink(),
    }
}

#[cfg(target_os = "linux")]
fn verify_descriptor_path(file: &File, expected: &Path, root: &Path) -> Result<(), ReadFailure> {
    use std::os::fd::AsRawFd;
    let descriptor = PathBuf::from(format!("/proc/self/fd/{}", file.as_raw_fd()));
    let resolved = fs::canonicalize(descriptor).map_err(|_| ReadFailure::Changed)?;
    if resolved == expected && resolved.starts_with(root) {
        Ok(())
    } else {
        Err(ReadFailure::Changed)
    }
}

#[cfg(not(target_os = "linux"))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct FileIdentity {
    size: u64,
    modified: Option<std::time::SystemTime>,
}
#[cfg(not(target_os = "linux"))]
fn file_identity(metadata: &fs::Metadata) -> FileIdentity {
    FileIdentity {
        size: metadata.len(),
        modified: metadata.modified().ok(),
    }
}
#[cfg(not(target_os = "linux"))]
fn verify_descriptor_path(_file: &File, expected: &Path, root: &Path) -> Result<(), ReadFailure> {
    let resolved = fs::canonicalize(expected).map_err(|_| ReadFailure::Changed)?;
    if resolved == expected && resolved.starts_with(root) {
        Ok(())
    } else {
        Err(ReadFailure::Changed)
    }
}

fn preview_read_error(error: ReadFailure) -> CommandError {
    let code = match error {
        ReadFailure::Changed => "image_preview_changed",
        ReadFailure::Unavailable => "image_preview_unavailable",
        ReadFailure::TooLarge => "image_preview_too_large",
        ReadFailure::TotalLimit => "image_preview_too_large",
    };
    CommandError::new(
        code,
        "The repository image could not be safely read for preview.",
    )
}

fn invalid_preview_path() -> CommandError {
    CommandError::new(
        "image_preview_invalid_path",
        "The image path is not a safe repository-relative path.",
    )
}

fn repository_unavailable() -> CommandError {
    CommandError::new(
        "image_repository_unavailable",
        "The repository root is unavailable for image inspection.",
    )
}

fn image_format(bytes: &[u8]) -> Option<ImageFormat> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some(ImageFormat::Png)
    } else if bytes.len() >= 3 && bytes[..3] == [0xff, 0xd8, 0xff] {
        Some(ImageFormat::Jpeg)
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        Some(ImageFormat::Gif)
    } else if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some(ImageFormat::Webp)
    } else {
        None
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DimensionFailure {
    Unknown,
    PixelLimit,
}

fn dimensions(format: ImageFormat, bytes: &[u8]) -> Result<(u32, u32), DimensionFailure> {
    let dimensions = match format {
        ImageFormat::Png if bytes.len() >= 24 && &bytes[12..16] == b"IHDR" => Some((
            u32::from_be_bytes(bytes[16..20].try_into().ok().unwrap()),
            u32::from_be_bytes(bytes[20..24].try_into().ok().unwrap()),
        )),
        ImageFormat::Gif if bytes.len() >= 10 => Some((
            u16::from_le_bytes(bytes[6..8].try_into().ok().unwrap()) as u32,
            u16::from_le_bytes(bytes[8..10].try_into().ok().unwrap()) as u32,
        )),
        ImageFormat::Jpeg => jpeg_dimensions(bytes),
        ImageFormat::Webp => webp_dimensions(bytes),
        _ => None,
    };
    let (width, height) = dimensions.ok_or(DimensionFailure::Unknown)?;
    if width == 0 || height == 0 || u64::from(width) * u64::from(height) > MAX_PIXELS {
        Err(DimensionFailure::PixelLimit)
    } else {
        Ok((width, height))
    }
}

fn jpeg_dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    if !bytes.starts_with(&[0xff, 0xd8]) {
        return None;
    }
    let mut index = 2;
    while index + 9 <= bytes.len() {
        if bytes[index] != 0xff {
            index += 1;
            continue;
        }
        while index < bytes.len() && bytes[index] == 0xff {
            index += 1;
        }
        let marker = *bytes.get(index)?;
        index += 1;
        if marker == 0xd8 || marker == 0xd9 || (0xd0..=0xd7).contains(&marker) {
            continue;
        }
        let length = u16::from_be_bytes([*bytes.get(index)?, *bytes.get(index + 1)?]) as usize;
        if length < 2 || index + length > bytes.len() {
            return None;
        }
        if matches!(marker, 0xc0..=0xc3 | 0xc5..=0xc7 | 0xc9..=0xcb | 0xcd..=0xcf) && length >= 8 {
            return Some((
                u16::from_be_bytes([bytes[index + 5], bytes[index + 6]]) as u32,
                u16::from_be_bytes([bytes[index + 3], bytes[index + 4]]) as u32,
            ));
        }
        index += length;
    }
    None
}

fn webp_dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    if bytes.len() < 12 || &bytes[..4] != b"RIFF" || &bytes[8..12] != b"WEBP" {
        return None;
    }
    let declared = u32::from_le_bytes(bytes[4..8].try_into().ok()?) as usize;
    let end = declared.checked_add(8)?.min(bytes.len());
    let mut index = 12usize;
    while index.checked_add(8)? <= end {
        let kind = &bytes[index..index + 4];
        let size = u32::from_le_bytes(bytes[index + 4..index + 8].try_into().ok()?) as usize;
        let body_start = index + 8;
        let body_end = body_start.checked_add(size)?;
        if body_end > end {
            return None;
        }
        let body = &bytes[body_start..body_end];
        let dimensions = match kind {
            b"VP8X" if body.len() >= 10 => Some((
                1 + u32::from_le_bytes([body[4], body[5], body[6], 0]),
                1 + u32::from_le_bytes([body[7], body[8], body[9], 0]),
            )),
            b"VP8 " if body.len() >= 10 && body[3..6] == [0x9d, 0x01, 0x2a] => Some((
                (u16::from_le_bytes([body[6], body[7]]) & 0x3fff) as u32,
                (u16::from_le_bytes([body[8], body[9]]) & 0x3fff) as u32,
            )),
            b"VP8L" if body.len() >= 5 && body[0] == 0x2f => {
                let value = u32::from_le_bytes([body[1], body[2], body[3], body[4]]);
                Some(((value & 0x3fff) + 1, ((value >> 14) & 0x3fff) + 1))
            }
            _ => None,
        };
        if dimensions.is_some() {
            return dimensions;
        }
        index = body_end.checked_add(size & 1)?;
    }
    None
}

fn sha256_hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn valid_sha256(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}
fn constant_time_eq(left: &str, right: &str) -> bool {
    left.len() == right.len()
        && left
            .bytes()
            .zip(right.bytes())
            .fold(0u8, |difference, (a, b)| difference | (a ^ b))
            == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn rejects_a_replaced_root_even_when_the_path_is_identical() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("repository");
        fs::create_dir(&path).unwrap();
        let original = validate_root(&path).unwrap();
        fs::rename(&path, temp.path().join("old-repository")).unwrap();
        fs::create_dir(&path).unwrap();
        assert_eq!(
            ensure_root_unchanged(&original).unwrap_err().code,
            "image_repository_changed"
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn held_directory_does_not_follow_a_replacement_symlink() {
        let temp = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let directory = temp.path().join("images");
        fs::create_dir(&directory).unwrap();
        let bytes = png(1, 1);
        fs::write(directory.join("cover.png"), &bytes).unwrap();
        fs::write(outside.path().join("cover.png"), png(2, 2)).unwrap();
        let held = open_directory(&directory).unwrap();
        fs::rename(&directory, temp.path().join("moved-images")).unwrap();
        std::os::unix::fs::symlink(outside.path(), &directory).unwrap();
        assert!(matches!(
            read_stable_file(
                temp.path(),
                &held,
                OsStr::new("cover.png"),
                &directory.join("cover.png"),
                MAX_FILE_BYTES
            ),
            Err((ReadFailure::Changed, _))
        ));
        assert!(
            read_repository_image(temp.path(), "images/cover.png", &sha256_hex(&bytes)).is_err()
        );
    }

    fn png(width: u32, height: u32) -> Vec<u8> {
        let mut bytes = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
        bytes.extend(width.to_be_bytes());
        bytes.extend(height.to_be_bytes());
        bytes
    }
    fn jpeg(width: u16, height: u16) -> Vec<u8> {
        vec![
            0xff,
            0xd8,
            0xff,
            0xc0,
            0,
            8,
            8,
            (height >> 8) as u8,
            height as u8,
            (width >> 8) as u8,
            width as u8,
            3,
        ]
    }
    fn gif(width: u16, height: u16) -> Vec<u8> {
        let mut bytes = b"GIF89a".to_vec();
        bytes.extend(width.to_le_bytes());
        bytes.extend(height.to_le_bytes());
        bytes
    }
    fn webp(width: u32, height: u32) -> Vec<u8> {
        let mut bytes = b"RIFF\x16\0\0\0WEBPVP8X\n\0\0\0\0\0\0\0".to_vec();
        for value in [width - 1, height - 1] {
            bytes.extend(&value.to_le_bytes()[..3]);
        }
        bytes
    }

    #[test]
    fn inventories_supported_formats_in_stable_order_with_dimensions() {
        let temp = tempfile::tempdir().unwrap();
        fs::write(temp.path().join("z.png"), png(2, 3)).unwrap();
        fs::write(temp.path().join("a.jpg"), jpeg(4, 5)).unwrap();
        fs::write(temp.path().join("m.gif"), gif(6, 7)).unwrap();
        fs::write(temp.path().join("w.webp"), webp(8, 9)).unwrap();
        let snapshot = inspect_repository_images(temp.path()).unwrap();
        assert_eq!(
            snapshot
                .images
                .iter()
                .map(|image| image.relative_path.as_str())
                .collect::<Vec<_>>(),
            vec!["a.jpg", "m.gif", "w.webp", "z.png"]
        );
        assert_eq!(
            (snapshot.images[0].width, snapshot.images[0].height),
            (Some(4), Some(5))
        );
        assert_eq!(snapshot.omitted_files, 0);
    }

    #[test]
    fn rejects_bad_signature_and_svg_and_enforces_bounds() {
        let temp = tempfile::tempdir().unwrap();
        fs::write(temp.path().join("bad.png"), b"nope").unwrap();
        fs::write(temp.path().join("vector.svg"), b"<svg/>").unwrap();
        fs::write(temp.path().join("bomb.png"), png(10_000, 10_000)).unwrap();
        let snapshot = inspect_repository_images(temp.path()).unwrap();
        assert!(snapshot.images.is_empty());
        assert!(snapshot
            .warnings
            .contains(&"image_svg_not_supported".to_string()));
        assert!(snapshot
            .warnings
            .contains(&"image_signature_invalid".to_string()));
        assert!(snapshot
            .warnings
            .contains(&"image_pixel_limit_exceeded".to_string()));
    }

    #[test]
    fn preview_rejects_traversal_excluded_and_symlink_paths() {
        let temp = tempfile::tempdir().unwrap();
        let image = png(1, 1);
        fs::write(temp.path().join("ok.png"), &image).unwrap();
        fs::create_dir(temp.path().join(".git")).unwrap();
        fs::write(temp.path().join(".git/hidden.png"), &image).unwrap();
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink("ok.png", temp.path().join("link.png")).unwrap();
            fs::create_dir(temp.path().join("linked")).unwrap();
            std::os::unix::fs::symlink(temp.path().join("linked"), temp.path().join("parent"))
                .unwrap();
        }
        let hash = sha256_hex(&image);
        assert!(read_repository_image(temp.path(), "../ok.png", &hash).is_err());
        assert!(read_repository_image(temp.path(), ".git/hidden.png", &hash).is_err());
        assert!(read_repository_image(temp.path(), "/ok.png", &hash).is_err());
        #[cfg(unix)]
        {
            assert!(read_repository_image(temp.path(), "link.png", &hash).is_err());
            assert!(read_repository_image(temp.path(), "parent/nope.png", &hash).is_err());
        }
    }

    #[test]
    fn preview_rechecks_hash_after_inventory() {
        let temp = tempfile::tempdir().unwrap();
        let first = png(1, 1);
        fs::write(temp.path().join("ok.png"), &first).unwrap();
        let snapshot = inspect_repository_images(temp.path()).unwrap();
        fs::write(temp.path().join("ok.png"), png(2, 2)).unwrap();
        let error =
            read_repository_image(temp.path(), "ok.png", &snapshot.images[0].sha256).unwrap_err();
        assert_eq!(error.code, "image_preview_changed");
    }

    #[test]
    fn rejects_unknown_dimensions_and_accepts_bounded_webp_chunks() {
        let temp = tempfile::tempdir().unwrap();
        let malformed_png = b"\x89PNG\r\n\x1a\nnot-an-ihdr";
        fs::write(temp.path().join("unknown.png"), malformed_png).unwrap();
        fs::write(temp.path().join("unknown.jpg"), [0xff, 0xd8, 0xff, 0xc0]).unwrap();
        let mut vp8l = b"RIFF\x1b\0\0\0WEBPJUNK\x01\0\0\0x\0VP8L\x05\0\0\0/".to_vec();
        let packed: u32 = (11 - 1) | ((12 - 1) << 14);
        vp8l.extend(packed.to_le_bytes());
        fs::write(temp.path().join("chunked.webp"), &vp8l).unwrap();
        let snapshot = inspect_repository_images(temp.path()).unwrap();
        assert_eq!(snapshot.images.len(), 1);
        assert_eq!(snapshot.images[0].relative_path, "chunked.webp");
        assert!(snapshot
            .warnings
            .contains(&"image_dimensions_unknown".to_string()));
        let error = read_repository_image(temp.path(), "unknown.png", &sha256_hex(malformed_png))
            .unwrap_err();
        assert_eq!(error.code, "image_preview_dimensions_unknown");
        assert_eq!(
            dimensions(ImageFormat::Webp, &webp(10_000, 10_000)),
            Err(DimensionFailure::PixelLimit)
        );
    }

    #[cfg(unix)]
    #[test]
    fn preview_rejects_fifo_without_blocking() {
        use std::os::unix::ffi::OsStrExt;
        let temp = tempfile::tempdir().unwrap();
        let fifo = temp.path().join("input.png");
        let fifo_name = CString::new(fifo.as_os_str().as_bytes()).unwrap();
        // SAFETY: this creates a test FIFO at a private temporary path.
        assert_eq!(unsafe { libc::mkfifo(fifo_name.as_ptr(), 0o600) }, 0);
        let error = read_repository_image(temp.path(), "input.png", &"0".repeat(64)).unwrap_err();
        assert_eq!(error.code, "image_preview_changed");
    }

    #[test]
    fn stable_read_respects_remaining_budget() {
        let temp = tempfile::tempdir().unwrap();
        let image = png(1, 1);
        fs::write(temp.path().join("ok.png"), &image).unwrap();
        let root = validate_root(temp.path()).unwrap();
        let directory = open_directory(&root.canonical).unwrap();
        let failure = read_stable_file(
            &root.canonical,
            &directory,
            OsStr::new("ok.png"),
            &temp.path().join("ok.png"),
            1,
        )
        .unwrap_err();
        assert_eq!(failure, (ReadFailure::TotalLimit, 0));
    }
}
