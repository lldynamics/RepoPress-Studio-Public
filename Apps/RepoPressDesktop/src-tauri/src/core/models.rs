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
    pub git_index: bool,
    pub remote_auth: bool,
    pub ai_editing: bool,
    pub semantic_search: bool,
    pub pdf_text_extraction: bool,
    pub ocr_readiness: bool,
    pub knowledge_library: bool,
    pub content_health: bool,
    pub image_workbench: bool,
    pub operation_log: bool,
    pub site_profiles: bool,
    pub metadata_batch: bool,
}

impl CapabilitySnapshot {
    pub fn from_git_availability(git_status: bool) -> Self {
        Self {
            local_edit: true,
            markdown_preview: true,
            git_status,
            site_runtime: true,
            git_commit: git_status,
            git_push: git_status,
            git_fetch: git_status,
            git_index: git_status,
            remote_auth: true,
            ai_editing: true,
            semantic_search: true,
            pdf_text_extraction: true,
            ocr_readiness: true,
            knowledge_library: true,
            content_health: true,
            image_workbench: true,
            operation_log: true,
            site_profiles: true,
            metadata_batch: cfg!(unix),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::CapabilitySnapshot;

    #[test]
    fn keeps_local_editing_available_when_git_is_unavailable() {
        let capabilities = CapabilitySnapshot::from_git_availability(false);

        assert!(capabilities.local_edit);
        assert!(capabilities.markdown_preview);
        assert!(!capabilities.git_status);
        assert!(capabilities.site_runtime);
        assert!(capabilities.ai_editing);
        assert!(capabilities.semantic_search);
        assert!(capabilities.pdf_text_extraction);
        assert!(capabilities.ocr_readiness);
        assert!(capabilities.knowledge_library);
        assert!(capabilities.content_health);
        assert!(capabilities.image_workbench);
        assert!(capabilities.operation_log);
        assert!(capabilities.site_profiles);
    }

    #[test]
    fn enables_reviewed_p2_git_operations_when_git_is_available() {
        let capabilities = CapabilitySnapshot::from_git_availability(true);

        assert!(capabilities.git_status);
        assert!(capabilities.git_commit);
        assert!(capabilities.git_push);
        assert!(capabilities.git_fetch);
        assert!(capabilities.git_index);
        assert!(capabilities.remote_auth);
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
pub struct MarkdownLinkMetadata {
    pub relative_path: String,
    pub title: Option<String>,
    pub slug: Option<String>,
    pub permalink: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeleteMarkdownDocumentResult {
    pub relative_path: String,
    pub recycle_id: String,
}

/// A repository-owned copy of an image selected by the user for a Markdown document.
/// `relative_path` is the physical path relative to the repository; `markdown_path` is the
/// site-root path which can be placed directly in Markdown image syntax.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WritingImageImportResult {
    pub relative_path: String,
    pub markdown_path: String,
    pub file_name: String,
    pub byte_size: u64,
    pub mime_type: String,
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
