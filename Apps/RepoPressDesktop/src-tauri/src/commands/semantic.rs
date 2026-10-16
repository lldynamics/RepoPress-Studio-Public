use super::{blocking_task_failed, AppState};
use crate::core::{CommandResult, SemanticIndexSnapshot, SemanticSearchSnapshot};
use serde::Serialize;
use tauri::State;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SemanticIndexStatusView {
    ready: bool,
    session_only: bool,
    model_id: String,
    encoding_version: u32,
    indexed_files: usize,
    indexed_chunks: usize,
    indexed_bytes: u64,
    reused_chunks: usize,
    summary: String,
}

#[tauri::command(rename_all = "camelCase")]
pub async fn semantic_index_status(
    session_id: String,
    state: State<'_, AppState>,
) -> CommandResult<SemanticIndexStatusView> {
    let repositories = state.repositories.clone();
    let semantic = state.semantic.clone();
    tauri::async_runtime::spawn_blocking(move || {
        repositories.root_for_session(&session_id)?;
        Ok(match semantic.status(&session_id) {
            Ok(snapshot) => semantic_status_view(snapshot),
            Err(_) => SemanticIndexStatusView {
                ready: false,
                session_only: true,
                model_id: "local-semantic-hash-v2".to_string(),
                encoding_version: 2,
                indexed_files: 0,
                indexed_chunks: 0,
                indexed_bytes: 0,
                reused_chunks: 0,
                summary: "尚未为当前仓库建立离线语义索引。".to_string(),
            },
        })
    })
    .await
    .map_err(|_| blocking_task_failed("semantic_status_task_failed", "read semantic status"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn rebuild_semantic_index(
    session_id: String,
    state: State<'_, AppState>,
) -> CommandResult<SemanticIndexStatusView> {
    let repositories = state.repositories.clone();
    let semantic = state.semantic.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id)?;
        semantic
            .rebuild(&session_id, &root)
            .map(semantic_status_view)
    })
    .await
    .map_err(|_| blocking_task_failed("semantic_rebuild_task_failed", "build semantic index"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn semantic_search(
    session_id: String,
    query: String,
    limit: Option<usize>,
    state: State<'_, AppState>,
) -> CommandResult<SemanticSearchSnapshot> {
    let repositories = state.repositories.clone();
    let semantic = state.semantic.clone();
    tauri::async_runtime::spawn_blocking(move || {
        repositories.root_for_session(&session_id)?;
        semantic.search(&session_id, &query, limit.unwrap_or(20))
    })
    .await
    .map_err(|_| blocking_task_failed("semantic_search_task_failed", "search semantic index"))?
}

fn semantic_status_view(snapshot: SemanticIndexSnapshot) -> SemanticIndexStatusView {
    SemanticIndexStatusView {
        ready: true,
        session_only: true,
        model_id: snapshot.model_id,
        encoding_version: snapshot.encoding_version,
        indexed_files: snapshot.indexed_files,
        indexed_chunks: snapshot.indexed_chunks,
        indexed_bytes: snapshot.indexed_bytes,
        reused_chunks: snapshot.reused_chunks,
        summary: format!(
            "已在本次会话内索引 {} 个文件、{} 个片段。",
            snapshot.indexed_files, snapshot.indexed_chunks
        ),
    }
}
