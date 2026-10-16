use super::{blocking_task_failed, AppState};
use crate::core::{
    BrowserCapture, BrowserCaptureConflict, BrowserCaptureDuplicateResolution,
    BrowserCaptureFolder, BrowserCaptureService, BrowserCaptureSink, BrowserCaptureSinkReceipt,
    BrowserCaptureStatus, BrowserKnowledgeImportOutcome, BrowserKnowledgeImportRequest,
    CommandError, CommandResult, KnowledgeArchiveExportPlan, KnowledgeArchiveExportResult,
    KnowledgeExportPlan, KnowledgeExportResult, KnowledgeFolder, KnowledgeImportRequest,
    KnowledgeImportResult, KnowledgeItem, KnowledgeItemSummary, KnowledgeLibrarySnapshot,
    KnowledgeLibraryStatus, KnowledgeLibraryStore, KnowledgeRevision, KnowledgeRevisionSummary,
    KnowledgeSearchSnapshot,
};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tauri::State;
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;
use url::Url;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeExportRequest {
    session_id: String,
    item_id: String,
    relative_path: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExecuteKnowledgeExportRequest {
    session_id: String,
    plan_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeArchiveExportRequest {
    session_id: String,
    item_id: String,
    relative_path: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExecuteKnowledgeArchiveExportRequest {
    session_id: String,
    plan_id: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeFolderSnapshot {
    folders: Vec<KnowledgeFolder>,
    total: usize,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeRevisionSnapshot {
    item_id: String,
    revisions: Vec<KnowledgeRevisionSummary>,
}

#[tauri::command]
pub async fn knowledge_library_status(
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeLibraryStatus> {
    let knowledge = Arc::clone(&state.knowledge);
    tauri::async_runtime::spawn_blocking(move || knowledge.status())
        .await
        .map_err(|_| {
            blocking_task_failed("knowledge_status_task_failed", "read the knowledge library")
        })?
}

#[tauri::command]
pub async fn list_knowledge_items(
    limit: Option<usize>,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeLibrarySnapshot> {
    let knowledge = Arc::clone(&state.knowledge);
    tauri::async_runtime::spawn_blocking(move || knowledge.list(limit.unwrap_or(100)))
        .await
        .map_err(|_| blocking_task_failed("knowledge_list_task_failed", "list knowledge items"))?
}

#[tauri::command]
pub async fn list_knowledge_folders(
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeFolderSnapshot> {
    let knowledge = Arc::clone(&state.knowledge);
    tauri::async_runtime::spawn_blocking(move || {
        let folders = knowledge.list_folders()?;
        Ok(KnowledgeFolderSnapshot {
            total: folders.len(),
            folders,
        })
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "knowledge_folder_list_task_failed",
            "list knowledge folders",
        )
    })?
}

#[tauri::command]
pub async fn create_knowledge_folder(
    name: String,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeFolder> {
    let knowledge = Arc::clone(&state.knowledge);
    tauri::async_runtime::spawn_blocking(move || knowledge.create_folder(&name))
        .await
        .map_err(|_| {
            blocking_task_failed(
                "knowledge_folder_create_task_failed",
                "create a knowledge folder",
            )
        })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn move_knowledge_item(
    item_id: String,
    folder_id: Option<String>,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeItemSummary> {
    let knowledge = Arc::clone(&state.knowledge);
    tauri::async_runtime::spawn_blocking(move || {
        knowledge.move_item(&item_id, folder_id.as_deref())
    })
    .await
    .map_err(|_| blocking_task_failed("knowledge_item_move_task_failed", "move a knowledge item"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn list_knowledge_revisions(
    item_id: String,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeRevisionSnapshot> {
    let knowledge = Arc::clone(&state.knowledge);
    tauri::async_runtime::spawn_blocking(move || {
        let revisions = knowledge.list_revisions(&item_id)?;
        Ok(KnowledgeRevisionSnapshot { item_id, revisions })
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "knowledge_revision_list_task_failed",
            "list knowledge revisions",
        )
    })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn get_knowledge_revision(
    item_id: String,
    revision_number: u32,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeRevision> {
    let knowledge = Arc::clone(&state.knowledge);
    tauri::async_runtime::spawn_blocking(move || knowledge.get_revision(&item_id, revision_number))
        .await
        .map_err(|_| {
            blocking_task_failed(
                "knowledge_revision_get_task_failed",
                "open a knowledge revision",
            )
        })?
}

#[tauri::command]
pub async fn take_knowledge_open_request(
    state: State<'_, AppState>,
) -> CommandResult<Option<String>> {
    let knowledge = Arc::clone(&state.knowledge);
    tauri::async_runtime::spawn_blocking(move || knowledge.take_open_request())
        .await
        .map_err(|_| {
            blocking_task_failed(
                "knowledge_open_request_task_failed",
                "read a browser open request",
            )
        })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn get_knowledge_item(
    item_id: String,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeItem> {
    let knowledge = Arc::clone(&state.knowledge);
    tauri::async_runtime::spawn_blocking(move || knowledge.get(&item_id))
        .await
        .map_err(|_| blocking_task_failed("knowledge_get_task_failed", "open a knowledge item"))?
}

#[tauri::command]
pub async fn import_knowledge_text(
    request: KnowledgeImportRequest,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeImportResult> {
    let log = Arc::clone(&state.operation_log);
    let scope = super::operation_log::repository_scope(&state, None);
    super::operation_log::run_logged(
        log,
        crate::core::OperationKind::KnowledgeImport,
        scope,
        async {
            let knowledge = Arc::clone(&state.knowledge);
            tauri::async_runtime::spawn_blocking(move || knowledge.import(request))
                .await
                .map_err(|_| {
                    blocking_task_failed("knowledge_import_task_failed", "import a knowledge item")
                })?
        },
    )
    .await
}

#[tauri::command]
pub async fn search_knowledge_items(
    query: String,
    limit: Option<usize>,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeSearchSnapshot> {
    let knowledge = Arc::clone(&state.knowledge);
    tauri::async_runtime::spawn_blocking(move || knowledge.search(&query, limit.unwrap_or(20)))
        .await
        .map_err(|_| {
            blocking_task_failed("knowledge_search_task_failed", "search knowledge items")
        })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn update_knowledge_progress(
    item_id: String,
    progress_percent: u8,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeItemSummary> {
    let knowledge = Arc::clone(&state.knowledge);
    tauri::async_runtime::spawn_blocking(move || {
        knowledge.update_progress(&item_id, progress_percent)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "knowledge_progress_task_failed",
            "update knowledge reading progress",
        )
    })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn set_knowledge_remote_ai_permission(
    item_id: String,
    allows_remote_ai_use: bool,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeItemSummary> {
    let knowledge = Arc::clone(&state.knowledge);
    tauri::async_runtime::spawn_blocking(move || {
        knowledge.set_remote_ai_permission(&item_id, allows_remote_ai_use)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "knowledge_remote_ai_permission_task_failed",
            "update a knowledge item's remote AI permission",
        )
    })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn delete_knowledge_item(
    item_id: String,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeLibraryStatus> {
    let knowledge = Arc::clone(&state.knowledge);
    tauri::async_runtime::spawn_blocking(move || {
        knowledge.delete(&item_id)?;
        knowledge.status()
    })
    .await
    .map_err(|_| blocking_task_failed("knowledge_delete_task_failed", "delete a knowledge item"))?
}

#[tauri::command]
pub async fn plan_knowledge_export(
    request: KnowledgeExportRequest,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeExportPlan> {
    let repositories = Arc::clone(&state.repositories);
    let knowledge = Arc::clone(&state.knowledge);
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&request.session_id)?;
        knowledge.plan_export(
            &request.session_id,
            &root,
            &request.item_id,
            &request.relative_path,
        )
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "knowledge_export_plan_task_failed",
            "plan a knowledge export",
        )
    })?
}

#[tauri::command]
pub async fn execute_knowledge_export(
    request: ExecuteKnowledgeExportRequest,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeExportResult> {
    let log = Arc::clone(&state.operation_log);
    let scope = super::operation_log::repository_scope(&state, Some(&request.session_id));
    super::operation_log::run_logged(
        log,
        crate::core::OperationKind::KnowledgeExport,
        scope,
        async {
            let repositories = Arc::clone(&state.repositories);
            let knowledge = Arc::clone(&state.knowledge);
            tauri::async_runtime::spawn_blocking(move || {
                let root = repositories.root_for_session(&request.session_id)?;
                knowledge.execute_export(&request.session_id, &root, &request.plan_id)
            })
            .await
            .map_err(|_| {
                blocking_task_failed(
                    "knowledge_export_execute_task_failed",
                    "execute a knowledge export",
                )
            })?
        },
    )
    .await
}

/// Intentionally left unregistered here; the application command registry owns exposure.
#[tauri::command]
pub async fn plan_knowledge_archive_export(
    request: KnowledgeArchiveExportRequest,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeArchiveExportPlan> {
    let repositories = Arc::clone(&state.repositories);
    let knowledge = Arc::clone(&state.knowledge);
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&request.session_id)?;
        knowledge.plan_archive_export(
            &request.session_id,
            &root,
            &request.item_id,
            &request.relative_path,
        )
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "knowledge_archive_export_plan_task_failed",
            "plan an offline archive export",
        )
    })?
}

/// Intentionally left unregistered here; the application command registry owns exposure.
#[tauri::command]
pub async fn execute_knowledge_archive_export(
    request: ExecuteKnowledgeArchiveExportRequest,
    state: State<'_, AppState>,
) -> CommandResult<KnowledgeArchiveExportResult> {
    let log = Arc::clone(&state.operation_log);
    let scope = super::operation_log::repository_scope(&state, Some(&request.session_id));
    super::operation_log::run_logged(
        log,
        crate::core::OperationKind::KnowledgeArchiveExport,
        scope,
        async {
            let repositories = Arc::clone(&state.repositories);
            let knowledge = Arc::clone(&state.knowledge);
            tauri::async_runtime::spawn_blocking(move || {
                let root = repositories.root_for_session(&request.session_id)?;
                knowledge.execute_archive_export(&request.session_id, &root, &request.plan_id)
            })
            .await
            .map_err(|_| {
                blocking_task_failed(
                    "knowledge_archive_export_execute_task_failed",
                    "export an offline archive",
                )
            })?
        },
    )
    .await
}

#[tauri::command]
pub fn browser_capture_status(state: State<'_, AppState>) -> BrowserCaptureStatus {
    state
        .browser_capture
        .as_ref()
        .map(|service| service.status())
        .unwrap_or_else(|| {
            unavailable_browser_capture_status(state.browser_capture_warning.clone())
        })
}

#[tauri::command]
pub fn rotate_browser_capture_token(
    state: State<'_, AppState>,
) -> CommandResult<BrowserCaptureStatus> {
    state
        .browser_capture
        .as_ref()
        .ok_or_else(|| {
            CommandError::new(
                "browser_capture_unavailable",
                state.browser_capture_warning.clone().unwrap_or_else(|| {
                    "Browser capture is unavailable until the desktop app is restarted.".to_string()
                }),
            )
        })?
        .rotate_token()
}

impl BrowserCaptureSink for KnowledgeLibraryStore {
    fn list_folders(&self) -> CommandResult<Vec<BrowserCaptureFolder>> {
        KnowledgeLibraryStore::list_folders(self).map(|folders| {
            folders
                .into_iter()
                .map(|folder| BrowserCaptureFolder {
                    id: folder.folder_id,
                    name: folder.name,
                })
                .collect()
        })
    }

    fn request_open(&self, document_id: &str) -> CommandResult<bool> {
        KnowledgeLibraryStore::request_open(self, document_id)?;
        Ok(true)
    }

    fn accept_capture(&self, capture: BrowserCapture) -> CommandResult<BrowserCaptureSinkReceipt> {
        let source_name = Url::parse(&capture.source_url)
            .ok()
            .and_then(|url| url.host_str().map(ToOwned::to_owned))
            .unwrap_or_else(|| "Browser capture".to_string());
        let duplicate_resolution = capture.duplicate_resolution.as_ref().map(|resolution| {
            match resolution {
                BrowserCaptureDuplicateResolution::SaveNewVersion => "save-new-version",
                BrowserCaptureDuplicateResolution::MoveOnly => "move-only",
                BrowserCaptureDuplicateResolution::KeepCopy => "keep-copy",
            }
            .to_string()
        });
        let outcome = self.import_browser_capture(
            BrowserKnowledgeImportRequest {
                operation_id: capture.operation_id.clone(),
                source_url: capture.source_url.clone(),
                title: capture.title.clone(),
                source_name,
                text: capture.content_text.clone(),
                allows_local_semantic_index: capture.allows_local_semantic_index,
                allows_remote_ai_use: capture.allows_remote_ai_use,
                folder_id: capture.folder_id.clone(),
                new_folder_name: capture.new_folder_name.clone(),
                duplicate_resolution,
            },
            capture.archive.as_ref(),
        )?;

        match outcome {
            BrowserKnowledgeImportOutcome::Conflict { conflict } => Ok(BrowserCaptureSinkReceipt {
                conflict: Some(BrowserCaptureConflict {
                    document_id: conflict.document_id,
                    title: conflict.title,
                    folder: browser_folder(self, conflict.folder_id.as_deref())?,
                    file_size_bytes: conflict.byte_size,
                    updated_at: epoch_seconds_rfc3339(conflict.updated_at_epoch_seconds)?,
                    incoming_has_changes: conflict.incoming_has_changes,
                }),
                ..BrowserCaptureSinkReceipt::default()
            }),
            BrowserKnowledgeImportOutcome::Imported { receipt } => {
                let (inserted_count, updated_count, skipped_count) = match receipt.action.as_str() {
                    "inserted" | "copied" => (1, 0, 0),
                    "new-version" | "moved" => (0, 1, 0),
                    _ => (0, 0, 1),
                };
                Ok(BrowserCaptureSinkReceipt {
                    inserted_count: Some(inserted_count),
                    updated_count: Some(updated_count),
                    skipped_count: Some(skipped_count),
                    action: Some(receipt.action),
                    document_id: Some(receipt.document_id),
                    title: Some(receipt.title),
                    folder: browser_folder(self, receipt.folder_id.as_deref())?,
                    file_size_bytes: Some(receipt.file_size_bytes),
                    archive_type: Some(receipt.archive_type),
                    index_status: Some(
                        if receipt.allows_local_semantic_index {
                            "ready"
                        } else {
                            "not-requested"
                        }
                        .to_string(),
                    ),
                    allows_local_semantic_index: Some(receipt.allows_local_semantic_index),
                    allows_remote_ai_use: Some(receipt.allows_remote_ai_use),
                    saved_at: Some(epoch_seconds_rfc3339(receipt.saved_at_epoch_seconds)?),
                    replayed: Some(receipt.replayed),
                    conflict: None,
                })
            }
        }
    }
}

fn browser_folder(
    store: &KnowledgeLibraryStore,
    folder_id: Option<&str>,
) -> CommandResult<Option<BrowserCaptureFolder>> {
    let Some(folder_id) = folder_id else {
        return Ok(None);
    };
    KnowledgeLibraryStore::list_folders(store)?
        .into_iter()
        .find(|folder| folder.folder_id == folder_id)
        .map(|folder| {
            Some(BrowserCaptureFolder {
                id: folder.folder_id,
                name: folder.name,
            })
        })
        .ok_or_else(|| {
            CommandError::new(
                "knowledge_folder_not_found",
                "Knowledge folder was not found.",
            )
        })
}

fn epoch_seconds_rfc3339(epoch_seconds: u64) -> CommandResult<String> {
    let seconds = i64::try_from(epoch_seconds).map_err(|_| {
        CommandError::new(
            "knowledge_timestamp_invalid",
            "Knowledge timestamp is outside the supported range.",
        )
    })?;
    let value = OffsetDateTime::from_unix_timestamp(seconds).map_err(|_| {
        CommandError::new(
            "knowledge_timestamp_invalid",
            "Knowledge timestamp is outside the supported range.",
        )
    })?;
    value.format(&Rfc3339).map_err(|_| {
        CommandError::new(
            "knowledge_timestamp_invalid",
            "Knowledge timestamp is outside the supported range.",
        )
    })
}

pub(super) fn start_browser_capture(
    knowledge: Arc<KnowledgeLibraryStore>,
) -> CommandResult<BrowserCaptureService> {
    knowledge.status()?;

    let sink: Arc<dyn BrowserCaptureSink> = knowledge;
    BrowserCaptureService::start(sink)
}

fn unavailable_browser_capture_status(warning: Option<String>) -> BrowserCaptureStatus {
    BrowserCaptureStatus {
        running: false,
        endpoint: "http://127.0.0.1:17843".to_string(),
        connection_token: String::new(),
        token_expires_at: 0,
        allowed_origins: Vec::new(),
        maximum_input_bytes: 0,
        summary: "Browser capture is not running.".to_string(),
        warning: Some(warning.unwrap_or_else(|| {
            "Browser capture is unavailable until the desktop app is restarted.".to_string()
        })),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn browser_capture(local_semantic_index: bool) -> BrowserCapture {
        BrowserCapture {
            operation_id: "550e8400-e29b-41d4-a716-446655440000".to_string(),
            folder_id: None,
            new_folder_name: None,
            duplicate_resolution: None,
            source_url: "https://example.test/article".to_string(),
            title: "Captured article".to_string(),
            authors: vec!["Ada".to_string()],
            language: Some("en".to_string()),
            summary: "Summary".to_string(),
            tags: vec!["reference".to_string()],
            captured_at: "2026-01-01T00:00:00Z".to_string(),
            content_text: "A local browser capture.".to_string(),
            capture_mode: "cleaned-article".to_string(),
            allows_local_semantic_index: local_semantic_index,
            allows_remote_ai_use: true,
            archive: None,
        }
    }

    fn browser_capture_with_archive() -> BrowserCapture {
        let mut capture = browser_capture(true);
        capture.operation_id = "550e8400-e29b-41d4-a716-446655440001".to_string();
        capture.capture_mode = "full-page".into();
        capture.archive = Some(crate::core::BrowserCaptureArchive {
            format: "html".into(),
            bytes: b"<!doctype html><html><body>offline</body></html>".to_vec(),
            embedded_resource_count: Some(1),
            missing_resource_count: Some(0),
            was_truncated: None,
        });
        capture
    }

    #[test]
    fn browser_sink_requires_explicit_url_conflict_resolution_and_replays_receipts() {
        let store = KnowledgeLibraryStore::default();
        let inserted = store.accept_capture(browser_capture(false)).unwrap();
        assert_eq!(inserted.inserted_count, Some(1));
        assert_eq!(inserted.updated_count, Some(0));
        assert_eq!(inserted.skipped_count, Some(0));
        assert_eq!(inserted.allows_local_semantic_index, Some(false));
        assert_eq!(inserted.allows_remote_ai_use, Some(true));

        let mut version = browser_capture_with_archive();
        let conflict = store.accept_capture(version.clone()).unwrap();
        assert!(conflict.conflict.is_some());
        assert_eq!(conflict.inserted_count, None);

        version.duplicate_resolution = Some(BrowserCaptureDuplicateResolution::SaveNewVersion);
        let updated = store.accept_capture(version.clone()).unwrap();
        assert_eq!(updated.inserted_count, Some(0));
        assert_eq!(updated.updated_count, Some(1));
        assert_eq!(updated.skipped_count, Some(0));
        assert_eq!(updated.action.as_deref(), Some("new-version"));
        assert_eq!(updated.allows_local_semantic_index, Some(true));
        assert_eq!(updated.allows_remote_ai_use, Some(true));
        assert_eq!(updated.replayed, Some(false));

        let replayed = store.accept_capture(version).unwrap();
        assert_eq!(replayed.document_id, updated.document_id);
        assert_eq!(replayed.saved_at, updated.saved_at);
        assert_eq!(replayed.replayed, Some(true));
        assert_eq!(replayed.allows_remote_ai_use, Some(true));
        assert_eq!(store.status().unwrap().item_count, 1);
    }
}
