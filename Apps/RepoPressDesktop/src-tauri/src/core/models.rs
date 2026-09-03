use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilitySnapshot {
    pub local_edit: bool,
    pub markdown_preview: bool,
    pub git_status: bool,
    pub site_runtime: bool,
    pub git_commit: bool,
    pub git_push: bool,
    pub git_fetch: bool,
    pub remote_auth: bool,
}

impl Default for CapabilitySnapshot {
    fn default() -> Self {
        Self {
            local_edit: true,
            markdown_preview: true,
            git_status: true,
            site_runtime: false,
            git_commit: false,
            git_push: false,
            git_fetch: false,
            remote_auth: false,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RepositorySessionSnapshot {
    pub session_id: String,
    pub root_path: String,
    pub display_name: String,
    pub site_kind: String,
    pub content_root: Option<String>,
    pub is_git_repository: bool,
    pub warnings: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MarkdownFileEntry {
    pub relative_path: String,
    pub display_name: String,
    pub directory: String,
    pub byte_size: u64,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum LineEnding {
    None,
    Lf,
    Crlf,
    Mixed,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DocumentSnapshot {
    pub document_id: String,
    pub relative_path: String,
    pub text: String,
    pub encoding: String,
    pub line_ending: LineEnding,
    pub byte_size: u64,
    pub baseline_sha256: String,
    pub revision: u64,
    pub writable: bool,
    pub read_only_reason: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitChangedFile {
    pub status: String,
    pub relative_path: String,
    pub source_path: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitStatusSnapshot {
    pub available: bool,
    pub branch: Option<String>,
    pub upstream: Option<String>,
    pub ahead: u32,
    pub behind: u32,
    pub detached: bool,
    pub changed_files: Vec<GitChangedFile>,
    pub warnings: Vec<String>,
}
