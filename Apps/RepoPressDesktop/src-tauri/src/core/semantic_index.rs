//! Offline, session-scoped Markdown indexing for semantic search.
//!
//! The index deliberately has no persistence layer.  Repository content and
//! embeddings live only in this process and are discarded with the session.

use super::{CommandError, CommandResult};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::ffi::OsStr;
use std::fs::{self, OpenOptions};
use std::io::Read;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

pub const SEMANTIC_MODEL_ID: &str = "local-semantic-hash-v2";
pub const SEMANTIC_ENCODING_VERSION: u32 = 2;
pub(crate) const EMBEDDING_DIMENSIONS: usize = 384;
const MAX_FILES: usize = 20_000;
const MAX_ENTRIES: usize = 100_000;
const MAX_DEPTH: usize = 32;
const MAX_FILE_BYTES: u64 = 4 * 1024 * 1024;
const MAX_READ_BYTES: u64 = 64 * 1024 * 1024;
const MAX_CHUNKS: usize = 20_000;
const MAX_CHUNK_CHARS: usize = 1_800;
const EXCLUDED_DIRECTORIES: &[&str] = &[
    ".git",
    ".build",
    ".swiftpm",
    "node_modules",
    "target",
    "vendor",
    "build",
];

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SemanticIndexSnapshot {
    pub session_id: String,
    pub model_id: String,
    pub encoding_version: u32,
    pub indexed_files: usize,
    pub indexed_chunks: usize,
    pub indexed_bytes: u64,
    pub reused_chunks: usize,
}

#[derive(Clone, Debug)]
pub(crate) struct SemanticChunk {
    pub id: String,
    pub path: String,
    pub start_line: u32,
    pub end_line: u32,
    pub heading: Option<String>,
    pub text: String,
    pub embedding: Vec<f32>,
    pub terms: Vec<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct IndexedFile {
    pub(crate) sha256: String,
    pub(crate) chunks: Vec<SemanticChunk>,
}

#[derive(Clone, Debug)]
pub(crate) struct SemanticIndex {
    pub root: PathBuf,
    pub session_id: String,
    pub indexed_bytes: u64,
    pub files: BTreeMap<String, IndexedFile>,
}

impl SemanticIndex {
    fn chunk_count(&self) -> usize {
        self.files.values().map(|file| file.chunks.len()).sum()
    }
}

#[derive(Default, Debug)]
struct SemanticIndexState {
    generation: u64,
    active_session_id: Option<String>,
    indexes: HashMap<String, Arc<SemanticIndex>>,
}

#[derive(Default, Debug)]
pub struct SemanticIndexStore {
    state: Mutex<SemanticIndexState>,
}

impl SemanticIndexStore {
    /// Rebuild a session's in-memory index.  The old index is kept intact if
    /// scanning, decoding, or a configured resource limit fails.
    pub fn rebuild(&self, session_id: &str, root: &Path) -> CommandResult<SemanticIndexSnapshot> {
        validate_session_id(session_id)?;
        let (generation, previous) = self.prepare_rebuild(session_id)?;
        let root = validate_root(root)?;
        if let Some(index) = previous.as_ref() {
            if index.root != root {
                return Err(repository_changed_error());
            }
        }

        let mut files = Vec::new();
        let mut entries = 0usize;
        collect_markdown_files(&root, &root, 0, &mut entries, &mut files)?;
        files.sort();

        let mut candidate_files = BTreeMap::new();
        let mut indexed_bytes = 0u64;
        let mut reused_chunks = 0usize;
        let mut chunk_count = 0usize;
        for file_path in files {
            let relative = portable_path(file_path.strip_prefix(&root).map_err(|_| {
                CommandError::new(
                    "semantic_document_outside_repository",
                    "A semantic-search document was outside the repository root.",
                )
            })?);
            let remaining_bytes = MAX_READ_BYTES.saturating_sub(indexed_bytes);
            let bytes = read_markdown_file(&root, &file_path, remaining_bytes)?;
            indexed_bytes += bytes.len() as u64;
            let sha256 = sha256_hex(&bytes);
            if let Some(old_file) = previous
                .as_ref()
                .and_then(|index| index.files.get(&relative))
                .filter(|old_file| old_file.sha256 == sha256)
            {
                if chunk_count.saturating_add(old_file.chunks.len()) > MAX_CHUNKS {
                    return Err(chunk_limit_error());
                }
                reused_chunks += old_file.chunks.len();
                chunk_count += old_file.chunks.len();
                candidate_files.insert(relative, old_file.clone());
                continue;
            }

            let text = decode_utf8(&bytes)?;
            let chunks = make_chunks(&relative, text, MAX_CHUNKS.saturating_sub(chunk_count))?;
            if chunk_count.saturating_add(chunks.len()) > MAX_CHUNKS {
                return Err(chunk_limit_error());
            }
            chunk_count += chunks.len();
            candidate_files.insert(relative, IndexedFile { sha256, chunks });
        }

        let candidate = Arc::new(SemanticIndex {
            root,
            session_id: session_id.to_string(),
            indexed_bytes,
            files: candidate_files,
        });
        let snapshot = snapshot(&candidate, reused_chunks);
        self.commit_candidate(session_id, generation, candidate)?;
        Ok(snapshot)
    }

    fn commit_candidate(
        &self,
        session_id: &str,
        generation: u64,
        candidate: Arc<SemanticIndex>,
    ) -> CommandResult<()> {
        let mut state = self.state.lock().map_err(|_| mutex_error())?;
        if state.generation != generation || state.active_session_id.as_deref() != Some(session_id)
        {
            return Err(repository_changed_error());
        }
        state.indexes.insert(session_id.to_string(), candidate);
        Ok(())
    }

    /// Activates exactly one repository session and invalidates any rebuild
    /// that began before the switch. Cleanup never writes index content to
    /// disk, and a stale worker cannot publish its candidate afterward.
    pub fn activate_session(&self, session_id: &str) -> CommandResult<()> {
        validate_session_id(session_id)?;
        let mut state = self.state.lock().map_err(|_| mutex_error())?;
        state.generation = state.generation.wrapping_add(1);
        state.active_session_id = Some(session_id.to_string());
        state.indexes.clear();
        Ok(())
    }

    pub fn status(&self, session_id: &str) -> CommandResult<SemanticIndexSnapshot> {
        let index = self.index_for_search(session_id)?;
        Ok(snapshot(&index, 0))
    }

    pub(crate) fn index_for_search(&self, session_id: &str) -> CommandResult<Arc<SemanticIndex>> {
        let state = self.state.lock().map_err(|_| mutex_error())?;
        if state
            .active_session_id
            .as_deref()
            .is_some_and(|active| active != session_id)
        {
            return Err(repository_changed_error());
        }
        state.indexes.get(session_id).cloned().ok_or_else(|| {
            CommandError::new(
                "semantic_index_not_ready",
                "Build the offline semantic index before searching it.",
            )
        })
    }

    fn prepare_rebuild(
        &self,
        session_id: &str,
    ) -> CommandResult<(u64, Option<Arc<SemanticIndex>>)> {
        let mut state = self.state.lock().map_err(|_| mutex_error())?;
        match state.active_session_id.as_deref() {
            Some(active) if active != session_id => return Err(repository_changed_error()),
            None => state.active_session_id = Some(session_id.to_string()),
            _ => {}
        }
        Ok((state.generation, state.indexes.get(session_id).cloned()))
    }
}

fn snapshot(index: &SemanticIndex, reused_chunks: usize) -> SemanticIndexSnapshot {
    SemanticIndexSnapshot {
        session_id: index.session_id.clone(),
        model_id: SEMANTIC_MODEL_ID.to_string(),
        encoding_version: SEMANTIC_ENCODING_VERSION,
        indexed_files: index.files.len(),
        indexed_chunks: index.chunk_count(),
        indexed_bytes: index.indexed_bytes,
        reused_chunks,
    }
}

fn validate_session_id(session_id: &str) -> CommandResult<()> {
    if session_id.is_empty() || session_id.len() > 200 || session_id.chars().any(char::is_control) {
        return Err(CommandError::new(
            "invalid_semantic_session",
            "Semantic-search session identifiers must be non-empty printable text.",
        ));
    }
    Ok(())
}

fn validate_root(root: &Path) -> CommandResult<PathBuf> {
    if !root.is_absolute() {
        return Err(CommandError::new(
            "semantic_repository_invalid",
            "The semantic-search repository root must be absolute.",
        ));
    }
    let metadata = fs::symlink_metadata(root).map_err(|error| {
        CommandError::io(
            "semantic_repository_unavailable",
            "Unable to inspect the semantic-search repository root",
            error,
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(CommandError::new(
            "semantic_repository_invalid",
            "A symbolic link or non-directory cannot be indexed.",
        ));
    }
    let canonical = fs::canonicalize(root).map_err(|error| {
        CommandError::io(
            "semantic_repository_unavailable",
            "Unable to resolve the semantic-search repository root",
            error,
        )
    })?;
    if canonical != root {
        return Err(CommandError::new(
            "semantic_repository_changed",
            "The semantic-search repository root changed after validation.",
        ));
    }
    Ok(canonical)
}

fn collect_markdown_files(
    root: &Path,
    directory: &Path,
    depth: usize,
    entries: &mut usize,
    files: &mut Vec<PathBuf>,
) -> CommandResult<()> {
    if depth > MAX_DEPTH {
        return Err(CommandError::new(
            "semantic_depth_limit_exceeded",
            format!("Semantic indexing scans at most {MAX_DEPTH} directory levels."),
        ));
    }
    let directory_entries = fs::read_dir(directory).map_err(|error| {
        CommandError::io(
            "semantic_scan_failed",
            "Unable to read a repository directory during semantic indexing",
            error,
        )
    })?;
    // Reserve each entry against the global budget while collecting it. This
    // keeps a single huge directory from allocating an unbounded Vec before
    // the traversal notices MAX_ENTRIES.
    let mut children = Vec::new();
    for child in directory_entries {
        let child = child.map_err(|error| {
            CommandError::io(
                "semantic_scan_failed",
                "Unable to inspect a repository entry during semantic indexing",
                error,
            )
        })?;
        *entries = entries.saturating_add(1);
        if *entries > MAX_ENTRIES {
            return Err(CommandError::new(
                "semantic_entry_limit_exceeded",
                format!("Semantic indexing scans at most {MAX_ENTRIES} filesystem entries."),
            ));
        }
        children.push(child);
    }
    children.sort_by_key(|entry| entry.file_name());
    for child in children {
        let path = child.path();
        let metadata = fs::symlink_metadata(&path).map_err(|error| {
            CommandError::io(
                "semantic_scan_failed",
                "Unable to inspect a repository entry during semantic indexing",
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
            collect_markdown_files(root, &path, depth + 1, entries, files)?;
        } else if metadata.is_file() && is_markdown(&path) {
            if files.len() >= MAX_FILES {
                return Err(CommandError::new(
                    "semantic_file_limit_exceeded",
                    format!("Semantic indexing reads at most {MAX_FILES} Markdown files."),
                ));
            }
            if path.strip_prefix(root).is_ok() {
                files.push(path);
            }
        }
    }
    Ok(())
}

/// Opens the selected directory entry without following its final component,
/// then reads only from that stable descriptor. The `/proc/self/fd` checks
/// also catch an ancestor being exchanged for a symlink between traversal and
/// open, while before/after fstat prevents indexing a concurrently rewritten
/// mixture of bytes.
fn read_markdown_file(root: &Path, path: &Path, remaining_bytes: u64) -> CommandResult<Vec<u8>> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|error| {
            CommandError::io(
                "semantic_scan_failed",
                "Unable to securely open a Markdown file during semantic indexing",
                error,
            )
        })?;
    let before = file.metadata().map_err(|error| {
        CommandError::io(
            "semantic_scan_failed",
            "Unable to inspect an opened Markdown file during semantic indexing",
            error,
        )
    })?;
    if !before.is_file() || before.nlink() == 0 {
        return Err(semantic_file_changed_error());
    }
    if before.len() > MAX_FILE_BYTES {
        return Err(CommandError::new(
            "semantic_file_too_large",
            format!("Semantic indexing only reads files up to {MAX_FILE_BYTES} bytes."),
        ));
    }
    if before.len() > remaining_bytes {
        return Err(CommandError::new(
            "semantic_read_limit_exceeded",
            format!("Semantic indexing reads at most {MAX_READ_BYTES} bytes per rebuild."),
        ));
    }
    ensure_open_file_path(root, path, file.as_raw_fd())?;

    let maximum = MAX_FILE_BYTES.min(remaining_bytes);
    let capacity = usize::try_from(before.len().min(maximum)).unwrap_or(0);
    let mut bytes = Vec::with_capacity(capacity);
    (&mut file)
        .take(maximum.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|error| {
            CommandError::io(
                "semantic_scan_failed",
                "Unable to read a Markdown file during semantic indexing",
                error,
            )
        })?;
    if bytes.len() as u64 > MAX_FILE_BYTES {
        return Err(CommandError::new(
            "semantic_file_too_large",
            format!("Semantic indexing only reads files up to {MAX_FILE_BYTES} bytes."),
        ));
    }
    if bytes.len() as u64 > remaining_bytes {
        return Err(CommandError::new(
            "semantic_read_limit_exceeded",
            format!("Semantic indexing reads at most {MAX_READ_BYTES} bytes per rebuild."),
        ));
    }

    let after = file.metadata().map_err(|error| {
        CommandError::io(
            "semantic_scan_failed",
            "Unable to re-inspect an opened Markdown file during semantic indexing",
            error,
        )
    })?;
    ensure_open_file_path(root, path, file.as_raw_fd())?;
    if bytes.len() as u64 != before.len() || !same_file_state(&before, &after) {
        return Err(semantic_file_changed_error());
    }
    Ok(bytes)
}

fn ensure_open_file_path(root: &Path, expected: &Path, descriptor: i32) -> CommandResult<()> {
    let descriptor_path = PathBuf::from("/proc/self/fd").join(descriptor.to_string());
    let resolved = fs::canonicalize(descriptor_path).map_err(|error| {
        CommandError::io(
            "semantic_scan_failed",
            "Unable to verify an opened Markdown file during semantic indexing",
            error,
        )
    })?;
    if resolved != expected || !resolved.starts_with(root) {
        return Err(semantic_file_changed_error());
    }
    Ok(())
}

fn same_file_state(left: &fs::Metadata, right: &fs::Metadata) -> bool {
    left.dev() == right.dev()
        && left.ino() == right.ino()
        && left.len() == right.len()
        && left.mtime() == right.mtime()
        && left.mtime_nsec() == right.mtime_nsec()
        && left.ctime() == right.ctime()
        && left.ctime_nsec() == right.ctime_nsec()
        && right.nlink() > 0
}

fn semantic_file_changed_error() -> CommandError {
    CommandError::new(
        "semantic_file_changed",
        "A Markdown file changed while the semantic index was being built; rebuild it again.",
    )
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

fn decode_utf8(bytes: &[u8]) -> CommandResult<&str> {
    let bytes = bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(bytes);
    std::str::from_utf8(bytes).map_err(|_| {
        CommandError::new(
            "semantic_unsupported_encoding",
            "Offline semantic search only indexes UTF-8 Markdown documents.",
        )
    })
}

fn make_chunks(path: &str, text: &str, maximum_chunks: usize) -> CommandResult<Vec<SemanticChunk>> {
    let mut chunks = Vec::new();
    let mut heading: Option<String> = None;
    let mut buffer: Vec<(u32, &str)> = Vec::new();
    let mut in_fence = false;
    for (zero_based, line) in text.lines().enumerate() {
        let line_number = zero_based as u32 + 1;
        let trimmed = line.trim();
        let fence = trimmed.starts_with("```") || trimmed.starts_with("~~~");
        let is_heading = !in_fence && markdown_heading(trimmed).is_some();
        if (is_heading || (!in_fence && trimmed.is_empty())) && !buffer.is_empty() {
            flush_buffer(
                path,
                heading.as_deref(),
                &mut buffer,
                &mut chunks,
                maximum_chunks,
            )?;
        }
        if let Some(next_heading) = markdown_heading(trimmed) {
            heading = Some(next_heading.to_string());
            buffer.push((line_number, line));
        } else if !trimmed.is_empty() || in_fence || fence {
            buffer.push((line_number, line));
        }
        if fence {
            in_fence = !in_fence;
            if !in_fence && !buffer.is_empty() {
                flush_buffer(
                    path,
                    heading.as_deref(),
                    &mut buffer,
                    &mut chunks,
                    maximum_chunks,
                )?;
            }
        }
    }
    if !buffer.is_empty() {
        flush_buffer(
            path,
            heading.as_deref(),
            &mut buffer,
            &mut chunks,
            maximum_chunks,
        )?;
    }
    Ok(chunks)
}

fn markdown_heading(line: &str) -> Option<&str> {
    let hashes = line.bytes().take_while(|byte| *byte == b'#').count();
    (hashes > 0 && hashes <= 6 && line.as_bytes().get(hashes) == Some(&b' '))
        .then(|| line[hashes..].trim())
}

fn flush_buffer(
    path: &str,
    heading: Option<&str>,
    buffer: &mut Vec<(u32, &str)>,
    chunks: &mut Vec<SemanticChunk>,
    maximum_chunks: usize,
) -> CommandResult<()> {
    let mut current: Vec<(u32, &str)> = Vec::new();
    let mut chars = 0usize;
    for &(line, value) in buffer.iter() {
        let line_chars = value.chars().count().saturating_add(1);
        if line_chars > MAX_CHUNK_CHARS {
            if !current.is_empty() {
                push_chunk(path, heading, &current, chunks, maximum_chunks)?;
                current.clear();
                chars = 0;
            }
            for fragment in split_long_line(value) {
                push_chunk(path, heading, &[(line, fragment)], chunks, maximum_chunks)?;
            }
            continue;
        }
        if !current.is_empty() && chars.saturating_add(line_chars) > MAX_CHUNK_CHARS {
            push_chunk(path, heading, &current, chunks, maximum_chunks)?;
            current.clear();
            chars = 0;
        }
        current.push((line, value));
        chars = chars.saturating_add(line_chars);
    }
    if !current.is_empty() {
        push_chunk(path, heading, &current, chunks, maximum_chunks)?;
    }
    buffer.clear();
    Ok(())
}

fn split_long_line(value: &str) -> Vec<&str> {
    let mut fragments = Vec::new();
    let mut start = 0usize;
    let mut count = 0usize;
    for (offset, _) in value.char_indices() {
        if count == MAX_CHUNK_CHARS {
            fragments.push(&value[start..offset]);
            start = offset;
            count = 0;
        }
        count += 1;
    }
    if start < value.len() {
        fragments.push(&value[start..]);
    }
    fragments
}

fn push_chunk(
    path: &str,
    heading: Option<&str>,
    lines: &[(u32, &str)],
    chunks: &mut Vec<SemanticChunk>,
    maximum_chunks: usize,
) -> CommandResult<()> {
    if chunks.len() >= maximum_chunks {
        return Err(chunk_limit_error());
    }
    let start_line = lines.first().map(|(line, _)| *line).unwrap_or(1);
    let end_line = lines.last().map(|(line, _)| *line).unwrap_or(start_line);
    let text = lines
        .iter()
        .map(|(_, line)| *line)
        .collect::<Vec<_>>()
        .join("\n");
    if text.trim().is_empty() {
        return Ok(());
    }
    let id = sha256_hex(format!("{path}\0{start_line}\0{end_line}\0{text}").as_bytes());
    let terms = semantic_features(&text);
    let embedding = normalized_embedding(&terms);
    chunks.push(SemanticChunk {
        id,
        path: path.to_string(),
        start_line,
        end_line,
        heading: heading.map(str::to_string),
        text,
        embedding,
        terms,
    });
    Ok(())
}

pub(crate) fn semantic_features(text: &str) -> Vec<String> {
    let lower = text.to_lowercase();
    let mut features = Vec::new();
    let mut english = String::new();
    let mut chinese = Vec::new();
    let flush_english = |token: &mut String, target: &mut Vec<String>| {
        if token.len() >= 2 {
            target.push(format!("en:{token}"));
            push_synonym_feature(token, target);
        }
        token.clear();
    };
    for character in lower.chars() {
        if character.is_ascii_alphanumeric() {
            english.push(character);
            continue;
        }
        flush_english(&mut english, &mut features);
        if is_cjk(character) {
            let item = character.to_string();
            features.push(format!("zh:{item}"));
            chinese.push(item);
        } else if !character.is_whitespace() && !character.is_control() {
            features.push(format!("sym:u{:x}", character as u32));
        }
    }
    flush_english(&mut english, &mut features);
    for window in chinese.windows(2) {
        let bigram = format!("{}{}", window[0], window[1]);
        features.push(format!("zh2:{bigram}"));
        push_synonym_feature(&bigram, &mut features);
    }
    features.sort();
    features.dedup();
    features
}

fn is_cjk(character: char) -> bool {
    matches!(character as u32, 0x3400..=0x4dbf | 0x4e00..=0x9fff | 0xf900..=0xfaff)
}

fn push_synonym_feature(token: &str, target: &mut Vec<String>) {
    let group = match token {
        "car" | "automobile" | "vehicle" | "汽车" | "车辆" | "轿车" => Some("vehicle"),
        "error" | "failure" | "issue" | "bug" | "错误" | "失败" | "异常" => Some("problem"),
        "search" | "find" | "query" | "retrieval" | "搜索" | "检索" | "查询" => {
            Some("search")
        }
        "deploy" | "publish" | "release" | "deployment" | "部署" | "发布" | "上线" => {
            Some("publish")
        }
        "install" | "setup" | "configuration" | "配置" | "安装" | "设置" => Some("setup"),
        "维护" | "保养" | "maintenance" => Some("maintenance"),
        _ => None,
    };
    if let Some(group) = group {
        target.push(format!("syn:{group}"));
    }
}

pub(crate) fn normalized_embedding(features: &[String]) -> Vec<f32> {
    let mut vector = vec![0.0; EMBEDDING_DIMENSIONS];
    for feature in features {
        let hash = Sha256::digest(feature.as_bytes());
        for offset in [0usize, 2, 4] {
            let bucket = u16::from_be_bytes([hash[offset], hash[offset + 1]]) as usize
                % EMBEDDING_DIMENSIONS;
            let sign = if hash[offset + 6] & 1 == 0 { 1.0 } else { -1.0 };
            vector[bucket] += sign;
        }
    }
    let norm = vector.iter().map(|value| value * value).sum::<f32>().sqrt();
    if norm > 0.0 {
        for value in &mut vector {
            *value /= norm;
        }
    }
    vector
}

pub(crate) fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut output = String::with_capacity(digest.len() * 2);
    for byte in digest {
        use std::fmt::Write as _;
        let _ = write!(output, "{byte:02x}");
    }
    output
}

pub(crate) fn portable_path(path: &Path) -> String {
    path.to_string_lossy()
        .replace(std::path::MAIN_SEPARATOR, "/")
}

fn chunk_limit_error() -> CommandError {
    CommandError::new(
        "semantic_chunk_limit_exceeded",
        format!("Semantic indexing creates at most {MAX_CHUNKS} chunks per rebuild."),
    )
}

fn repository_changed_error() -> CommandError {
    CommandError::new(
        "semantic_repository_changed",
        "The semantic-search session belongs to another repository.",
    )
}

fn mutex_error() -> CommandError {
    CommandError::new(
        "semantic_index_unavailable",
        "The offline semantic index is temporarily unavailable.",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn stable_hash_embedding_is_normalized_for_chinese_and_emoji() {
        let features = semantic_features("中文搜索 😀 RepoPress");
        let first = normalized_embedding(&features);
        let second = normalized_embedding(&features);
        let norm = first.iter().map(|value| value * value).sum::<f32>().sqrt();
        assert_eq!(first, second);
        assert!((norm - 1.0).abs() < 0.0001);
        assert_eq!(first.len(), EMBEDDING_DIMENSIONS);
    }

    #[test]
    fn rebuild_reuses_unchanged_chunks_and_removes_deleted_files() {
        let directory = tempfile::tempdir().unwrap();
        fs::write(directory.path().join("one.md"), "# Alpha\nHello").unwrap();
        fs::write(directory.path().join("two.md"), "# Beta\nWorld").unwrap();
        let store = SemanticIndexStore::default();
        let first = store.rebuild("session", directory.path()).unwrap();
        assert_eq!(first.indexed_files, 2);
        assert_eq!(first.reused_chunks, 0);
        fs::remove_file(directory.path().join("two.md")).unwrap();
        let second = store.rebuild("session", directory.path()).unwrap();
        assert_eq!(second.indexed_files, 1);
        // The deleted document must disappear; only the one still-present,
        // byte-identical document is eligible for reuse.
        assert_eq!(second.reused_chunks, first.indexed_chunks - 1);
    }

    #[test]
    fn excluded_directories_and_symlinks_are_not_indexed() {
        let directory = tempfile::tempdir().unwrap();
        fs::create_dir(directory.path().join("target")).unwrap();
        fs::write(directory.path().join("target/no.md"), "no").unwrap();
        fs::write(directory.path().join("yes.md"), "yes").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(
            directory.path().join("yes.md"),
            directory.path().join("link.md"),
        )
        .unwrap();
        let result = SemanticIndexStore::default()
            .rebuild("session", directory.path())
            .unwrap();
        assert_eq!(result.indexed_files, 1);
    }

    #[test]
    fn failed_rebuild_preserves_the_previous_index() {
        let directory = tempfile::tempdir().unwrap();
        fs::write(directory.path().join("ok.md"), "# Stable\ncontent").unwrap();
        let store = SemanticIndexStore::default();
        store.rebuild("session", directory.path()).unwrap();
        fs::write(directory.path().join("broken.md"), vec![0xff, 0xfe]).unwrap();
        assert!(store.rebuild("session", directory.path()).is_err());
        assert_eq!(store.status("session").unwrap().indexed_files, 1);
    }

    #[test]
    fn chunk_budget_is_enforced_before_a_file_builds_extra_embeddings() {
        let error = make_chunks("many.md", "# One\nfirst\n\n# Two\nsecond", 1).unwrap_err();
        assert_eq!(error.code, "semantic_chunk_limit_exceeded");
    }

    #[cfg(unix)]
    #[test]
    fn descriptor_reader_rejects_a_final_symlink() {
        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("target.md");
        let link = directory.path().join("link.md");
        fs::write(&target, "safe").unwrap();
        std::os::unix::fs::symlink(&target, &link).unwrap();
        assert!(read_markdown_file(directory.path(), &link, MAX_READ_BYTES).is_err());
    }

    #[test]
    fn repository_switch_rejects_a_stale_rebuild_commit() {
        let directory = tempfile::tempdir().unwrap();
        fs::write(directory.path().join("one.md"), "# One\ncontent").unwrap();
        let store = SemanticIndexStore::default();
        store.activate_session("first").unwrap();
        store.rebuild("first", directory.path()).unwrap();
        let (generation, candidate) = {
            let state = store.state.lock().unwrap();
            (
                state.generation,
                state.indexes.get("first").cloned().unwrap(),
            )
        };

        store.activate_session("second").unwrap();
        assert_eq!(
            store
                .commit_candidate("first", generation, candidate)
                .unwrap_err()
                .code,
            "semantic_repository_changed"
        );
        assert_eq!(
            store.status("first").unwrap_err().code,
            "semantic_repository_changed"
        );
    }
}
