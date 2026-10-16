use super::{CommandError, CommandResult};
use serde::Serialize;
use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};

const MAX_QUERY_CHARS: usize = 200;
const MAX_RESULTS: usize = 100;
const MAX_FILES: usize = 100_000;
const MAX_ENTRIES: usize = 100_000;
const MAX_DEPTH: usize = 64;
const MAX_FILE_BYTES: u64 = 4 * 1024 * 1024;
const MAX_READ_BYTES: u64 = 64 * 1024 * 1024;
const EXCLUDED: &[&str] = &[
    ".git",
    ".build",
    ".swiftpm",
    "node_modules",
    "target",
    "vendor",
];

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum MarkdownSearchMatchKind {
    Path,
    Content,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct MarkdownSearchResult {
    pub relative_path: String,
    pub display_name: String,
    pub directory: String,
    pub match_kind: MarkdownSearchMatchKind,
    pub line_number: Option<u32>,
    pub snippet: String,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct MarkdownSearchSnapshot {
    pub query: String,
    pub results: Vec<MarkdownSearchResult>,
    pub truncated: bool,
}

pub fn search_markdown_files(
    root: &Path,
    scan_root: &Path,
    query: &str,
    requested_limit: usize,
) -> CommandResult<MarkdownSearchSnapshot> {
    let query = query.trim();
    if query.is_empty() {
        return Ok(MarkdownSearchSnapshot {
            query: String::new(),
            results: Vec::new(),
            truncated: false,
        });
    }
    if query.chars().count() > MAX_QUERY_CHARS {
        return Err(CommandError::new(
            "invalid_search_query",
            "Search query must be at most 200 characters.",
        ));
    }
    let limit = requested_limit.clamp(1, MAX_RESULTS);
    let root = validated_root(root)?;
    let scan_root = validated_scan_root(&root, scan_root)?;
    let folded_query = query.to_lowercase();
    let mut paths = Vec::new();
    let mut visited_entries = 0usize;
    let hit_file_limit = collect_paths(&root, &scan_root, 0, &mut visited_entries, &mut paths)?;
    paths.sort();

    let mut path_results = Vec::new();
    let mut content_results = Vec::new();
    let mut read_bytes = 0u64;
    let mut content_budget_exhausted = false;
    let mut truncated = hit_file_limit;
    for path in paths {
        let metadata = match fs::symlink_metadata(&path) {
            Ok(value) => value,
            Err(_) => continue,
        };
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            continue;
        }
        let canonical = match fs::canonicalize(&path) {
            Ok(value) if value == path && value.starts_with(&root) => value,
            _ => continue,
        };
        let relative = path.strip_prefix(&root).map_err(|_| outside_error())?;
        let relative_path = portable(relative);
        let display_name = path
            .file_name()
            .and_then(OsStr::to_str)
            .unwrap_or("Untitled")
            .to_string();
        let directory = relative
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .map(portable)
            .unwrap_or_default();
        let path_match = relative_path.to_lowercase().contains(&folded_query);
        if path_match {
            if path_results.len() <= limit {
                path_results.push(MarkdownSearchResult {
                    relative_path: relative_path.clone(),
                    display_name,
                    directory,
                    match_kind: MarkdownSearchMatchKind::Path,
                    line_number: None,
                    snippet: bound_single_line(&relative_path),
                });
            } else {
                truncated = true;
            }
            continue;
        }

        // One result beyond the requested limit is enough to prove that the
        // response is truncated. Continue walking only to discover later path
        // matches, which are globally ranked ahead of content matches.
        if path_results.len() > limit || content_results.len() > limit || content_budget_exhausted {
            truncated = true;
            continue;
        }
        if metadata.len() > MAX_FILE_BYTES {
            continue;
        }
        if read_bytes.saturating_add(metadata.len()) > MAX_READ_BYTES {
            truncated = true;
            content_budget_exhausted = true;
            continue;
        }
        let bytes = match fs::read(&canonical) {
            Ok(value) => value,
            Err(_) => continue,
        };
        read_bytes += bytes.len() as u64;
        let payload = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(&bytes);
        let Ok(text) = std::str::from_utf8(payload) else {
            continue;
        };
        let mut found = None;
        for (index, line) in text.lines().enumerate() {
            if line.to_lowercase().contains(&folded_query) {
                found = Some((index as u32 + 1, bound_single_line(line)));
                break;
            }
        }
        let Some((line, snippet)) = found else {
            continue;
        };
        content_results.push(MarkdownSearchResult {
            relative_path,
            display_name,
            directory,
            match_kind: MarkdownSearchMatchKind::Content,
            line_number: Some(line),
            snippet,
        });
    }
    path_results.extend(content_results);
    if path_results.len() > limit {
        path_results.truncate(limit);
        truncated = true;
    }
    Ok(MarkdownSearchSnapshot {
        query: query.to_string(),
        results: path_results,
        truncated,
    })
}

fn validated_root(root: &Path) -> CommandResult<PathBuf> {
    let metadata = fs::symlink_metadata(root).map_err(|e| {
        CommandError::io(
            "repository_unavailable",
            "Unable to inspect repository root",
            e,
        )
    })?;
    if !root.is_absolute() || metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(outside_error());
    }
    let canonical = fs::canonicalize(root).map_err(|e| {
        CommandError::io(
            "repository_unavailable",
            "Unable to resolve repository root",
            e,
        )
    })?;
    if canonical != root {
        return Err(outside_error());
    }
    Ok(canonical)
}

fn validated_scan_root(root: &Path, scan_root: &Path) -> CommandResult<PathBuf> {
    let metadata = fs::symlink_metadata(scan_root).map_err(|e| {
        CommandError::io(
            "repository_scan_failed",
            "Unable to inspect search directory",
            e,
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(outside_error());
    }
    let canonical = fs::canonicalize(scan_root).map_err(|e| {
        CommandError::io(
            "repository_scan_failed",
            "Unable to resolve search directory",
            e,
        )
    })?;
    if !canonical.starts_with(root) {
        return Err(outside_error());
    }
    Ok(canonical)
}

fn collect_paths(
    root: &Path,
    directory: &Path,
    depth: usize,
    visited_entries: &mut usize,
    paths: &mut Vec<PathBuf>,
) -> CommandResult<bool> {
    if depth > MAX_DEPTH {
        return Ok(true);
    }
    let directory_entries = fs::read_dir(directory).map_err(|e| {
        CommandError::io(
            "repository_scan_failed",
            "Unable to read search directory",
            e,
        )
    })?;
    let mut entries = Vec::new();
    for entry in directory_entries.filter_map(Result::ok) {
        if *visited_entries >= MAX_ENTRIES {
            return Ok(true);
        }
        *visited_entries += 1;
        entries.push(entry);
    }
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        let path = entry.path();
        let metadata = match fs::symlink_metadata(&path) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if metadata.file_type().is_symlink() {
            continue;
        }
        if metadata.is_dir() {
            if EXCLUDED
                .iter()
                .any(|name| entry.file_name().eq_ignore_ascii_case(OsStr::new(name)))
            {
                continue;
            }
            if collect_paths(root, &path, depth + 1, visited_entries, paths)? {
                return Ok(true);
            }
        } else if metadata.is_file() && is_markdown(&path) {
            if paths.len() >= MAX_FILES {
                return Ok(true);
            }
            if path.strip_prefix(root).is_ok() {
                paths.push(path);
            }
        }
    }
    Ok(false)
}

fn is_markdown(path: &Path) -> bool {
    path.extension()
        .and_then(OsStr::to_str)
        .map(|e| matches!(e.to_ascii_lowercase().as_str(), "md" | "markdown" | "mdx"))
        .unwrap_or(false)
}
fn portable(path: &Path) -> String {
    path.to_string_lossy()
        .replace(std::path::MAIN_SEPARATOR, "/")
}
fn bound_single_line(value: &str) -> String {
    let value = value.replace(['\r', '\n'], " ");
    value.chars().take(240).collect()
}
fn outside_error() -> CommandError {
    CommandError::new(
        "document_outside_repository",
        "Search path is outside the repository.",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn finds_chinese_text_in_a_bom_document() {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir(dir.path().join("content")).unwrap();
        let mut bom_text = vec![0xef, 0xbb, 0xbf];
        bom_text.extend_from_slice("第一行\n中文命中".as_bytes());
        fs::write(dir.path().join("content/路径.md"), bom_text).unwrap();
        let result =
            search_markdown_files(dir.path(), &dir.path().join("content"), "中文", 100).unwrap();
        assert_eq!(result.results.len(), 1);
        assert!(!result.truncated);
        assert_eq!(
            result.results[0].match_kind,
            MarkdownSearchMatchKind::Content
        );
        assert_eq!(result.results[0].line_number, Some(2));
    }

    #[test]
    fn marks_a_limited_result_set_as_truncated() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("a.md"), "needle").unwrap();
        fs::write(dir.path().join("b.md"), "needle").unwrap();
        let result = search_markdown_files(dir.path(), dir.path(), "needle", 1).unwrap();
        assert_eq!(result.results.len(), 1);
        assert!(result.truncated);
        assert_eq!(result.results[0].relative_path, "a.md");
    }

    #[test]
    fn skips_symlinks_and_excluded_directories() {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir(dir.path().join("target")).unwrap();
        fs::write(dir.path().join("target/no.md"), "needle").unwrap();
        fs::write(dir.path().join("yes.md"), "needle").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(dir.path().join("yes.md"), dir.path().join("link.md")).unwrap();
        let result = search_markdown_files(dir.path(), dir.path(), "needle", 100).unwrap();
        assert_eq!(result.results.len(), 1);
    }

    #[test]
    fn rejects_invalid_queries() {
        let dir = tempfile::tempdir().unwrap();
        assert!(search_markdown_files(dir.path(), dir.path(), "  ", 0)
            .unwrap()
            .results
            .is_empty());
        assert!(search_markdown_files(dir.path(), dir.path(), &"x".repeat(201), 1).is_err());
    }

    #[test]
    fn path_matches_do_not_require_readable_utf8_content() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("路径.md"), [0xff, 0xfe]).unwrap();
        let result = search_markdown_files(dir.path(), dir.path(), "路径", 100).unwrap();
        assert_eq!(result.results.len(), 1);
        assert_eq!(result.results[0].match_kind, MarkdownSearchMatchKind::Path);
        assert_eq!(result.results[0].line_number, None);
    }

    #[test]
    fn ranks_path_matches_ahead_of_earlier_content_matches() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("a.md"), "needle in content").unwrap();
        fs::write(dir.path().join("z-needle.md"), "no body match").unwrap();

        let result = search_markdown_files(dir.path(), dir.path(), "needle", 1).unwrap();

        assert_eq!(result.results.len(), 1);
        assert_eq!(result.results[0].relative_path, "z-needle.md");
        assert_eq!(result.results[0].match_kind, MarkdownSearchMatchKind::Path);
        assert!(result.truncated);
    }
}
