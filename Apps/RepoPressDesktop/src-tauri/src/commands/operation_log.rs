use super::{blocking_task_failed, AppState};
use crate::core::{
    operation_repository_key, CommandResult, OperationKind, OperationLogSnapshot,
    OperationLogStore, OperationOutcome,
};
use std::future::Future;
use std::sync::Arc;
use std::time::Instant;
use tauri::State;

/// Only a verified session root contributes to the opaque repository association.
/// An invalid session is recorded without an association; no user input is logged.
pub(super) fn repository_scope(state: &AppState, session_id: Option<&str>) -> Option<String> {
    session_id
        .and_then(|id| state.repositories.root_for_session(id).ok())
        .map(|root| operation_repository_key(&root))
}

/// Record the original command result exactly once after completion. The logger runs
/// independently of the business transaction and cannot change its return value.
pub(super) async fn run_logged<T>(
    log: Arc<OperationLogStore>,
    kind: OperationKind,
    repository_key: Option<String>,
    operation: impl Future<Output = CommandResult<T>>,
) -> CommandResult<T> {
    let started = Instant::now();
    let result = operation.await;
    let outcome = if result.is_ok() {
        OperationOutcome::Succeeded
    } else {
        OperationOutcome::Failed
    };
    let duration_ms = started.elapsed().as_millis().min(86_400_000) as u64;
    let _ = tauri::async_runtime::spawn_blocking(move || {
        log.record(kind, outcome, repository_key, duration_ms);
    })
    .await;
    result
}

#[tauri::command(rename_all = "camelCase")]
pub async fn get_operation_log(
    session_id: Option<String>,
    state: State<'_, AppState>,
) -> CommandResult<OperationLogSnapshot> {
    let log = Arc::clone(&state.operation_log);
    let repositories = Arc::clone(&state.repositories);
    tauri::async_runtime::spawn_blocking(move || {
        let key = session_id
            .as_deref()
            .map(|id| {
                repositories
                    .root_for_session(id)
                    .map(|root| operation_repository_key(&root))
            })
            .transpose()?;
        let mut snapshot = log.snapshot()?;
        snapshot.current_repository_key = key;
        Ok(snapshot)
    })
    .await
    .map_err(|_| blocking_task_failed("operation_log_read_task_failed", "read operation records"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn clear_operation_log(
    through_sequence: u64,
    session_id: Option<String>,
    state: State<'_, AppState>,
) -> CommandResult<OperationLogSnapshot> {
    let log = Arc::clone(&state.operation_log);
    let repositories = Arc::clone(&state.repositories);
    tauri::async_runtime::spawn_blocking(move || {
        // Check the requested association before mutating the display journal.
        let key = session_id
            .as_deref()
            .map(|id| {
                repositories
                    .root_for_session(id)
                    .map(|root| operation_repository_key(&root))
            })
            .transpose()?;
        let mut snapshot = log.clear_through(through_sequence)?;
        snapshot.current_repository_key = key;
        Ok(snapshot)
    })
    .await
    .map_err(|_| {
        blocking_task_failed("operation_log_clear_task_failed", "clear operation records")
    })?
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::CommandError;

    #[test]
    fn records_command_results_without_retaining_payloads_or_errors() {
        let log = Arc::new(OperationLogStore::default());
        tauri::async_runtime::block_on(async {
            let original = "private document content with token=secret";
            let result = run_logged(Arc::clone(&log), OperationKind::SaveDocument, None, async {
                Ok(original)
            })
            .await;
            assert_eq!(result.unwrap(), original);
            let error = CommandError::new(
                "save_conflict",
                "secret /private/path https://token@example.com",
            );
            let failed: CommandResult<()> =
                run_logged(Arc::clone(&log), OperationKind::SaveDocument, None, async {
                    Err(error)
                })
                .await;
            assert_eq!(failed.unwrap_err().code, "save_conflict");
        });
        let snapshot = log.snapshot().unwrap();
        assert_eq!(snapshot.entries.len(), 2);
        assert_eq!(snapshot.entries[0].outcome, OperationOutcome::Failed);
        assert_eq!(snapshot.entries[1].outcome, OperationOutcome::Succeeded);
        let json = serde_json::to_string(&snapshot).unwrap();
        for private in ["private", "secret", "example.com", "save_conflict"] {
            assert!(!json.contains(private));
        }
    }

    #[test]
    fn log_storage_failure_does_not_change_a_completed_operation() {
        let temp = tempfile::tempdir().unwrap();
        let invalid = temp.path().join("not-a-directory");
        std::fs::write(&invalid, "existing data").unwrap();
        let log = Arc::new(OperationLogStore::new(invalid));
        let result = tauri::async_runtime::block_on(run_logged(
            Arc::clone(&log),
            OperationKind::CreateDocument,
            None,
            async { Ok(42) },
        ));
        assert_eq!(result.unwrap(), 42);
        let snapshot = log.snapshot().unwrap();
        assert_eq!(snapshot.entries.len(), 1);
        assert!(!snapshot.persistent);
        assert!(snapshot.warning.is_some());
    }

    #[test]
    fn real_document_save_and_conflict_keep_their_results_and_log_only_completion() {
        let temp = tempfile::tempdir().unwrap();
        let article = temp.path().join("private-title.md");
        std::fs::write(&article, "# original private text\n").unwrap();
        let state = AppState::default();
        let repository = state
            .repositories
            .open_repository(temp.path().to_str().unwrap())
            .unwrap();
        let document = state
            .repositories
            .open_document(&repository.session_id, "private-title.md")
            .unwrap();
        let key = repository_scope(&state, Some(&repository.session_id));
        assert!(key.is_some());
        assert!(repository_scope(&state, Some("/untrusted/input")).is_none());
        assert!(state.operation_log.snapshot().unwrap().entries.is_empty());

        tauri::async_runtime::block_on(async {
            let saved = run_logged(
                Arc::clone(&state.operation_log),
                OperationKind::SaveDocument,
                key.clone(),
                async {
                    state.repositories.save_document(
                        &repository.session_id,
                        &document.document_id,
                        "# changed private text\n",
                        &document.baseline_sha256,
                    )
                },
            )
            .await
            .unwrap();
            assert_eq!(saved.revision, 2);
            assert_eq!(std::fs::read_to_string(&article).unwrap(), saved.text);

            std::fs::write(&article, "# external private text\n").unwrap();
            let error = run_logged(
                Arc::clone(&state.operation_log),
                OperationKind::SaveDocument,
                key.clone(),
                async {
                    state.repositories.save_document(
                        &repository.session_id,
                        &document.document_id,
                        "must not overwrite",
                        &saved.baseline_sha256,
                    )
                },
            )
            .await
            .unwrap_err();
            assert_eq!(error.code, "save_conflict");
            assert_eq!(
                std::fs::read_to_string(&article).unwrap(),
                "# external private text\n"
            );
        });
        let snapshot = state.operation_log.snapshot().unwrap();
        assert_eq!(snapshot.entries.len(), 2);
        assert_eq!(snapshot.entries[0].outcome, OperationOutcome::Failed);
        assert_eq!(snapshot.entries[1].outcome, OperationOutcome::Succeeded);
        assert!(snapshot
            .entries
            .iter()
            .all(|entry| entry.repository_key == key));
        let json = serde_json::to_string(&snapshot).unwrap();
        assert!(!json.contains("private"));
        assert!(!json.contains(temp.path().to_str().unwrap()));
    }
}
