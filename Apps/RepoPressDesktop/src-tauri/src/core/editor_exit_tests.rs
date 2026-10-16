use super::*;
use crate::core::WorkspacePreferences;
use sha2::Digest;
use std::fs;
use std::path::PathBuf;
use std::time::Instant;

fn durable_store() -> (tempfile::TempDir, WorkspaceStateStore) {
    let directory = tempfile::tempdir().unwrap();
    let store = WorkspaceStateStore::new(directory.path().to_path_buf()).unwrap();
    (directory, store)
}

fn draft(text: &str) -> RecoveryDraftSnapshot {
    RecoveryDraftSnapshot {
        recovery_id: uuid::Uuid::new_v4().to_string(),
        repository_path: "/tmp/repository".to_string(),
        relative_path: "article.md".to_string(),
        text: text.to_string(),
        baseline_sha256: "a".repeat(64),
        saved_at_epoch_seconds: 1,
    }
}

fn export_path(plan: &EditorExitPlan) -> PathBuf {
    PathBuf::from(plan.export_path.as_ref().unwrap())
}

fn expect_error<T>(result: CommandResult<T>) -> CommandError {
    match result {
        Ok(_) => panic!("expected command to fail"),
        Err(error) => error,
    }
}

#[test]
fn durable_primary_prepare_complete_survives_reload_and_replay_is_rejected() {
    let (directory, workspace) = durable_store();
    let exit = EditorExitStore::default();
    let plan = exit
        .prepare(&workspace, Some(draft("draft")), None)
        .unwrap();
    let reloaded = WorkspaceStateStore::new(directory.path().to_path_buf()).unwrap();

    exit.complete(&reloaded, &plan.plan_id).unwrap();
    let replay = exit.complete(&reloaded, &plan.plan_id).unwrap_err();
    assert_eq!(replay.code, "exit_proof_invalid");
}

#[test]
fn memory_only_store_is_rejected_for_primary_proof() {
    let exit = EditorExitStore::default();
    let error = expect_error(exit.prepare(&WorkspaceStateStore::default(), None, None));
    assert_eq!(error.code, "exit_storage_unavailable");
}

#[test]
fn changed_missing_and_corrupt_workspace_state_refuse_completion() {
    for mutation in ["changed", "missing", "corrupt"] {
        let (directory, workspace) = durable_store();
        let exit = EditorExitStore::default();
        let plan = exit.prepare(&workspace, None, None).unwrap();
        let state_file = directory
            .path()
            .join("workspace")
            .join("workspace-state.json");
        match mutation {
            "changed" => {
                workspace
                    .update_preferences(WorkspacePreferences {
                        theme: "dark".to_string(),
                        ..WorkspacePreferences::default()
                    })
                    .unwrap();
            }
            "missing" => fs::remove_file(&state_file).unwrap(),
            "corrupt" => fs::write(&state_file, b"not json").unwrap(),
            _ => unreachable!(),
        }
        let error = exit.complete(&workspace, &plan.plan_id).unwrap_err();
        assert_eq!(error.code, "exit_verification_failed", "{mutation}");
    }
}

#[test]
fn disabled_recovery_rejects_primary_draft_but_allows_export() {
    let (directory, workspace) = durable_store();
    workspace
        .update_preferences(WorkspacePreferences {
            recovery_enabled: false,
            ..WorkspacePreferences::default()
        })
        .unwrap();
    let exit = EditorExitStore::default();
    let error = expect_error(exit.prepare(&workspace, Some(draft("draft")), None));
    assert_eq!(error.code, "exit_recovery_disabled");

    let plan = exit
        .prepare(&workspace, Some(draft("draft")), Some(directory.path()))
        .unwrap();
    exit.complete(&workspace, &plan.plan_id).unwrap();
}

#[cfg(unix)]
#[test]
fn export_package_preserves_unicode_empty_text_metadata_and_private_permissions() {
    use std::os::unix::fs::PermissionsExt;

    let (directory, workspace) = durable_store();
    let exit = EditorExitStore::default();
    let plan = exit
        .prepare(&workspace, Some(draft("")), Some(directory.path()))
        .unwrap();
    let package = export_path(&plan);
    let metadata: serde_json::Value =
        serde_json::from_slice(&fs::read(package.join("recovery.json")).unwrap()).unwrap();
    assert_eq!(fs::read(package.join("draft.md")).unwrap(), b"");
    assert_eq!(metadata["repositoryPath"], "/tmp/repository");
    assert_eq!(metadata["relativePath"], "article.md");
    assert_eq!(metadata["textByteSize"], 0);
    assert_eq!(
        metadata["textSha256"],
        format!("{:x}", sha2::Sha256::digest(b""))
    );
    assert!(
        String::from_utf8(fs::read(package.join("README.txt")).unwrap())
            .unwrap()
            .contains("恢复包")
    );
    assert_eq!(
        fs::metadata(&package).unwrap().permissions().mode() & 0o777,
        0o700
    );
    for name in ["draft.md", "recovery.json", "README.txt"] {
        assert_eq!(
            fs::metadata(package.join(name))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
    exit.complete(&workspace, &plan.plan_id).unwrap();
}

#[test]
fn oversized_text_is_rejected_before_export() {
    let (directory, workspace) = durable_store();
    let oversized = draft(&"x".repeat(16 * 1024 * 1024 + 1));
    let error = expect_error(EditorExitStore::default().prepare(
        &workspace,
        Some(oversized),
        Some(directory.path()),
    ));
    assert_eq!(error.code, "exit_export_too_large");
}

#[test]
fn wrong_ticket_consumes_proof_and_expired_ticket_is_rejected() {
    let (_directory, workspace) = durable_store();
    let exit = EditorExitStore::default();
    let plan = exit.prepare(&workspace, None, None).unwrap();
    let wrong = exit.complete(&workspace, "wrong-ticket").unwrap_err();
    assert_eq!(wrong.code, "exit_proof_invalid");
    assert_eq!(
        exit.complete(&workspace, &plan.plan_id).unwrap_err().code,
        "exit_proof_invalid"
    );

    let plan = exit.prepare(&workspace, None, None).unwrap();
    exit.proof.lock().unwrap().as_mut().unwrap().created = Instant::now() - PROOF_TTL;
    assert_eq!(
        exit.complete(&workspace, &plan.plan_id).unwrap_err().code,
        "exit_proof_invalid"
    );
}

#[cfg(unix)]
#[test]
fn package_tamper_missing_file_and_symlink_refuse_proof() {
    use std::os::unix::fs::symlink;

    for mutation in ["tamper", "missing", "symlink"] {
        let (directory, workspace) = durable_store();
        let exit = EditorExitStore::default();
        let plan = exit
            .prepare(&workspace, Some(draft("safe")), Some(directory.path()))
            .unwrap();
        let package = export_path(&plan);
        let draft_file = package.join("draft.md");
        match mutation {
            "tamper" => fs::write(&draft_file, b"changed").unwrap(),
            "missing" => fs::remove_file(&draft_file).unwrap(),
            "symlink" => {
                fs::remove_file(&draft_file).unwrap();
                let outside = directory.path().join("outside.md");
                fs::write(&outside, b"safe").unwrap();
                symlink(&outside, &draft_file).unwrap();
            }
            _ => unreachable!(),
        }
        let error = exit.complete(&workspace, &plan.plan_id).unwrap_err();
        assert!(
            matches!(
                error.code.as_str(),
                "exit_proof_invalid" | "exit_export_failed"
            ),
            "{mutation}: unexpected error code {}",
            error.code
        );
    }
}

#[cfg(unix)]
#[test]
fn symlink_export_destination_is_rejected() {
    use std::os::unix::fs::symlink;

    let (directory, workspace) = durable_store();
    let target = directory.path().join("target");
    fs::create_dir(&target).unwrap();
    let link = directory.path().join("export-link");
    symlink(&target, &link).unwrap();
    let error = expect_error(EditorExitStore::default().prepare(
        &workspace,
        Some(draft("draft")),
        Some(&link),
    ));
    assert_eq!(error.code, "exit_proof_invalid");
}

#[test]
fn untrusted_startup_state_is_preserved_and_cannot_issue_primary_proof() {
    let (directory, workspace) = durable_store();
    workspace.persist_for_exit(None).unwrap();
    let path = directory.path().join("workspace/workspace-state.json");
    fs::write(&path, b"corrupt recovery data").unwrap();
    let reloaded = WorkspaceStateStore::new(directory.path().to_path_buf()).unwrap();
    assert!(reloaded.snapshot().unwrap().warning.is_some());
    assert_eq!(
        expect_error(EditorExitStore::default().prepare(&reloaded, Some(draft("unsaved")), None))
            .code,
        "exit_untrusted_workspace"
    );
    assert_eq!(fs::read(&path).unwrap(), b"corrupt recovery data");
    // No current unsaved buffer: allow leaving without rewriting or certifying
    // the fallback. This is not a primary-file persistence proof.
    let exit = EditorExitStore::default();
    let plan = exit.prepare(&reloaded, None, None).unwrap();
    exit.complete(&reloaded, &plan.plan_id).unwrap();
    assert_eq!(fs::read(&path).unwrap(), b"corrupt recovery data");
    assert!(reloaded.snapshot().unwrap().warning.is_some());
}

#[test]
fn emergency_export_preserves_text_rejected_by_normal_recovery() {
    let (directory, workspace) = durable_store();
    let text = format!("{}\r\n尾部", "a".repeat(4 * 1024 * 1024));
    let exit = EditorExitStore::default();
    assert!(exit.prepare(&workspace, Some(draft(&text)), None).is_err());
    let plan = exit
        .prepare(&workspace, Some(draft(&text)), Some(directory.path()))
        .unwrap();
    assert_eq!(
        fs::read_to_string(export_path(&plan).join("draft.md")).unwrap(),
        text
    );
    exit.complete(&workspace, &plan.plan_id).unwrap();
}

#[test]
fn emergency_export_metadata_survives_unavailable_source_repository() {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path().join("repository");
    fs::create_dir(&root).unwrap();
    fs::write(root.join("article.md"), "original").unwrap();
    let repositories = crate::core::RepositoryStore::default();
    let session = repositories
        .open_repository(root.to_str().unwrap())
        .unwrap();
    let document = repositories
        .open_document(&session.session_id, "article.md")
        .unwrap();
    fs::rename(&root, directory.path().join("moved-repository")).unwrap();
    assert!(repositories
        .recovery_context_for_session(&session.session_id, &document.document_id)
        .is_err());
    let (source, path, baseline) = repositories
        .recovery_export_context(&session.session_id, &document.document_id)
        .unwrap();
    assert_eq!(source, root);
    assert_eq!(path, "article.md");
    assert_eq!(baseline, document.baseline_sha256);
    assert!(repositories
        .recovery_export_context(&session.session_id, "unknown")
        .is_err());
}
