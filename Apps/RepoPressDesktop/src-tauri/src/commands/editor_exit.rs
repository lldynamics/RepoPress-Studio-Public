use super::{blocking_task_failed, AppState};
use crate::core::{
    CommandError, CommandResult, EditorExitPlan, EditorExitStore, RecoveryDraftSnapshot,
};
use serde::Deserialize;
use std::path::Path;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, State, WebviewWindow};

#[derive(Default)]
pub struct EditorExitRuntime {
    store: Arc<EditorExitStore>,
    permitted: AtomicBool,
}
impl EditorExitRuntime {
    pub fn permitted(&self) -> bool {
        self.permitted.load(Ordering::SeqCst)
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ExitDraftInput {
    session_id: String,
    document_id: String,
    text: String,
    expected_sha256: String,
}

#[tauri::command(rename_all = "camelCase")]
pub async fn prepare_editor_exit(
    draft: Option<ExitDraftInput>,
    export_directory: Option<String>,
    window: WebviewWindow,
    state: State<'_, AppState>,
    exit: State<'_, EditorExitRuntime>,
) -> CommandResult<EditorExitPlan> {
    require_main_window(&window)?;
    let repositories = state.repositories.clone();
    let workspace = state.workspace.clone();
    let ai = state.ai.clone();
    let store = exit.store.clone();
    tauri::async_runtime::spawn_blocking(move || {
        ai.ensure_exit_idle()?;
        let _operation = repositories.lock_recovery_operation()?;
        let draft = draft
            .map(|draft| {
                let (root, relative_path, baseline) = if export_directory.is_some() {
                    repositories.recovery_export_context(&draft.session_id, &draft.document_id)?
                } else {
                    let (root, path, baseline, _) = repositories
                        .recovery_context_for_session(&draft.session_id, &draft.document_id)?;
                    (root, path, baseline)
                };
                if baseline != draft.expected_sha256 {
                    return Err(CommandError::new(
                        "exit_document_changed",
                        "The document changed. Prepare exit again.",
                    ));
                }
                Ok(RecoveryDraftSnapshot {
                    recovery_id: uuid::Uuid::new_v4().to_string(),
                    repository_path: root
                        .to_str()
                        .ok_or_else(|| {
                            CommandError::new("exit_invalid_path", "Repository path is not UTF-8.")
                        })?
                        .to_string(),
                    relative_path,
                    text: draft.text,
                    baseline_sha256: baseline,
                    saved_at_epoch_seconds: SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_secs(),
                })
            })
            .transpose()?;
        store.prepare(
            &workspace,
            draft,
            export_directory.as_deref().map(Path::new),
        )
    })
    .await
    .map_err(|_| blocking_task_failed("exit_prepare_failed", "prepare editor recovery"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn complete_editor_exit(
    plan_id: String,
    window: WebviewWindow,
    app: AppHandle,
    state: State<'_, AppState>,
    exit: State<'_, EditorExitRuntime>,
) -> CommandResult<()> {
    require_main_window(&window)?;
    let workspace = state.workspace.clone();
    let store = exit.store.clone();
    let ai = state.ai.clone();
    tauri::async_runtime::spawn_blocking(move || {
        store.complete(&workspace, &plan_id)?;
        ai.ensure_exit_idle()
    })
    .await
    .map_err(|_| blocking_task_failed("exit_verify_failed", "verify editor recovery"))??;
    exit.permitted.store(true, Ordering::SeqCst);
    app.exit(0);
    Ok(())
}

fn require_main_window(window: &WebviewWindow) -> CommandResult<()> {
    if window.label() != "main" {
        return Err(CommandError::new(
            "exit_wrong_window",
            "Only the main window can prepare exit.",
        ));
    }
    Ok(())
}
