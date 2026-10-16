use super::*;
use serde_json::json;
use std::os::unix::fs::{symlink, PermissionsExt};

fn dir(path: &Path) {
    fs::create_dir_all(path).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
}
fn write(path: &Path, bytes: &[u8]) {
    dir(path.parent().unwrap());
    fs::write(path, bytes).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
}
fn path(root: &Path, source: ConfigBackupSource) -> PathBuf {
    let (folder, file, _) = source.location();
    root.join(folder).join(file)
}
fn selected() -> Vec<ConfigBackupSource> {
    vec![
        ConfigBackupSource::Workspace,
        ConfigBackupSource::SiteProfiles,
        ConfigBackupSource::AiProfiles,
    ]
}
fn workspace() -> Value {
    let mut value =
        serde_json::to_value(super::super::workspace_state::WorkspaceStateSnapshot::default())
            .unwrap();
    value["recentRepositories"] = json!([{ "path":"/private/repository", "displayName":"private site", "lastOpenedAtEpochSeconds":10 }]);
    value["recoveryDraft"] = json!({ "recoveryId":Uuid::new_v4().to_string(), "repositoryPath":"/private/repository", "relativePath":"draft.md", "text":"private recovered body with user secrets", "baselineSha256":"a".repeat(64), "savedAtEpochSeconds":10 });
    value
}
fn site() -> Value {
    json!({"schemaVersion":1,"revision":2,"profiles":[{"profileId":Uuid::new_v4().to_string(),"name":"Private site","rootPath":"/private/repository","createdAtEpochMs":10}]})
}
fn ai() -> Value {
    json!({"schemaVersion":1,"profiles":[{"profileId":Uuid::new_v4().to_string(),"name":"Private AI","provider":"openai_compatible","endpoint":"https://private.example/v1","model":"private-model","streaming":true,"createdAtEpochSeconds":10,"updatedAtEpochSeconds":11}]})
}
fn fixtures(root: &Path) {
    for (source, data) in [
        (ConfigBackupSource::Workspace, workspace()),
        (ConfigBackupSource::SiteProfiles, site()),
        (ConfigBackupSource::AiProfiles, ai()),
    ] {
        write(&path(root, source), &serde_json::to_vec(&data).unwrap());
    }
}
fn setup() -> (
    tempfile::TempDir,
    PathBuf,
    PathBuf,
    WorkspaceConfigBackupStore,
) {
    let temp = tempfile::tempdir().unwrap();
    let app = temp.path().join("app");
    dir(&app);
    fixtures(&app);
    let destination = temp.path().join("config.json");
    let store = WorkspaceConfigBackupStore::new(app.clone());
    (temp, app, destination, store)
}

#[test]
fn validated_selected_configuration_is_frozen_checksummed_and_written_privately_without_source_mutation(
) {
    let (_temp, app, destination, store) = setup();
    let before: Vec<_> = selected()
        .iter()
        .map(|s| fs::read(path(&app, *s)).unwrap())
        .collect();
    write(
        &app.join("ai-credentials-v1/secret"),
        b"excluded credential sentinel",
    );
    let plan = store
        .plan(selected().into_iter().rev().collect(), &destination)
        .unwrap();
    assert_eq!(plan.selected_sources, selected());
    assert!(!plan.includes_credentials);
    assert!(!plan.consistent_snapshot);
    assert!(plan.structure_verified);
    assert_eq!(plan.sources[0].recovery_draft_count, 1);
    assert_eq!(plan.sources[1].item_count, 1);
    assert_eq!(plan.sources[2].item_count, 1);
    assert!(!destination.exists());
    let public = serde_json::to_string(&plan).unwrap();
    for private in [
        "private recovered body",
        "/private/repository",
        "private.example",
        "excluded credential sentinel",
    ] {
        assert!(!public.contains(private));
    }
    let result = store.execute(&plan.plan_id, true).unwrap();
    let bytes = fs::read(&destination).unwrap();
    assert_eq!(bytes.len(), plan.byte_size);
    assert_eq!(hash(&bytes), plan.sha256);
    assert_eq!(result.sha256, plan.sha256);
    assert_ne!(
        plan.byte_size,
        plan.sources
            .iter()
            .map(|s| s.source_byte_size)
            .sum::<usize>()
    );
    use std::os::unix::fs::MetadataExt;
    assert_eq!(fs::metadata(&destination).unwrap().mode() & 0o777, 0o600);
    let archive: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(archive["format"], "repopress-workspace-config");
    assert_eq!(archive["configurations"].as_array().unwrap().len(), 3);
    assert!(String::from_utf8(bytes)
        .unwrap()
        .contains("private recovered body"));
    for entry in archive["configurations"].as_array().unwrap() {
        assert_eq!(
            entry["dataSha256"],
            hash(&serde_json::to_vec(&entry["data"]).unwrap())
        );
    }
    assert!(!serde_json::to_string(&archive)
        .unwrap()
        .contains("excluded credential sentinel"));
    for (source, old) in selected().iter().zip(before) {
        assert_eq!(fs::read(path(&app, *source)).unwrap(), old);
    }
    assert!(store.execute(&plan.plan_id, true).is_err());
}

#[test]
fn missing_or_memory_storage_never_becomes_healthy_empty_and_valid_empty_registry_is_distinct() {
    let temp = tempfile::tempdir().unwrap();
    let app = temp.path().join("missing");
    let dest = temp.path().join("out.json");
    let unavailable = WorkspaceConfigBackupStore::new(app.clone());
    assert!(unavailable
        .plan(vec![ConfigBackupSource::Workspace], &dest)
        .is_err());
    assert!(!app.exists());
    assert!(WorkspaceConfigBackupStore::default()
        .plan(vec![ConfigBackupSource::Workspace], &dest)
        .is_err());
    dir(&app);
    let store = WorkspaceConfigBackupStore::new(app.clone());
    assert!(store
        .plan(vec![ConfigBackupSource::AiProfiles], &dest)
        .is_err());
    write(
        &path(&app, ConfigBackupSource::AiProfiles),
        br#"{"schemaVersion":1,"profiles":[]}"#,
    );
    let p = store
        .plan(vec![ConfigBackupSource::AiProfiles], &dest)
        .unwrap();
    assert_eq!(p.sources[0].item_count, 0);
    store.execute(&p.plan_id, true).unwrap();
}

#[test]
fn malformed_future_unknown_and_duplicate_workspace_fields_reject_without_export_or_fallback() {
    let (_temp, app, dest, store) = setup();
    let file = path(&app, ConfigBackupSource::Workspace);
    let mut cases = vec![
        b"corrupt".to_vec(),
        br#"{"schemaVersion":1,"schemaVersion":2}"#.to_vec(),
    ];
    for target in [
        "version",
        "warning",
        "top",
        "preferences",
        "recent",
        "recovery",
    ] {
        let mut v = workspace();
        match target {
            "version" => v["schemaVersion"] = json!(2),
            "warning" => v["warning"] = json!("degraded"),
            "top" => v["apiKey"] = json!("secret"),
            "preferences" => v["preferences"]["futureField"] = json!(true),
            "recent" => v["recentRepositories"][0]["token"] = json!("secret"),
            _ => v["recoveryDraft"]["token"] = json!("secret"),
        }
        cases.push(serde_json::to_vec(&v).unwrap());
    }
    let valid = serde_json::to_string(&workspace()).unwrap();
    cases.push(
        valid
            .replacen(
                "\"schemaVersion\":1",
                "\"schemaVersion\":1,\"schemaVersion\":1",
                1,
            )
            .into_bytes(),
    );
    for bytes in cases {
        write(&file, &bytes);
        assert!(store
            .plan(vec![ConfigBackupSource::Workspace], &dest)
            .is_err());
        assert_eq!(fs::read(&file).unwrap(), bytes);
        assert!(!dest.exists());
    }
}

#[test]
fn site_and_ai_payloads_keep_existing_strict_business_rules_and_reject_credentials() {
    let (_temp, app, dest, store) = setup();
    let mut bad_site = site();
    let duplicate = bad_site["profiles"][0].clone();
    bad_site["profiles"].as_array_mut().unwrap().push(duplicate);
    let mut bad_ai = ai();
    bad_ai["profiles"][0]["credential"] = json!("secret");
    for (s, value) in [
        (ConfigBackupSource::SiteProfiles, bad_site),
        (ConfigBackupSource::AiProfiles, bad_ai),
    ] {
        write(&path(&app, s), &serde_json::to_vec(&value).unwrap());
        assert!(store.plan(vec![s], &dest).is_err());
    }
    let mut value = ai();
    value["profiles"][0]["endpoint"] = json!("https://user:secret@private.example/v1");
    write(
        &path(&app, ConfigBackupSource::AiProfiles),
        &serde_json::to_vec(&value).unwrap(),
    );
    assert!(store
        .plan(vec![ConfigBackupSource::AiProfiles], &dest)
        .is_err());
}

#[test]
fn unselected_corrupt_sources_and_sensitive_or_unknown_files_are_not_opened_or_copied() {
    let (_temp, app, dest, store) = setup();
    fs::remove_file(path(&app, ConfigBackupSource::SiteProfiles)).unwrap();
    symlink(
        "/does-not-exist",
        path(&app, ConfigBackupSource::SiteProfiles),
    )
    .unwrap();
    write(&path(&app, ConfigBackupSource::AiProfiles), b"corrupt");
    write(&app.join("workspace/private-token"), b"excluded sentinel");
    dir(&app.join("ai-chat-vault"));
    fs::set_permissions(app.join("ai-chat-vault"), fs::Permissions::from_mode(0o000)).unwrap();
    let p = store
        .plan(vec![ConfigBackupSource::Workspace], &dest)
        .unwrap();
    fs::write(
        path(&app, ConfigBackupSource::AiProfiles),
        b"other unselected change",
    )
    .unwrap();
    store.execute(&p.plan_id, true).unwrap();
    assert!(!String::from_utf8(fs::read(dest).unwrap())
        .unwrap()
        .contains("excluded sentinel"));
    assert_eq!(
        fs::read(app.join("workspace/private-token")).unwrap(),
        b"excluded sentinel"
    );
    fs::set_permissions(app.join("ai-chat-vault"), fs::Permissions::from_mode(0o700)).unwrap();
}

#[test]
fn symlink_fifo_hardlinks_and_nonprivate_source_permissions_fail_closed() {
    let (_temp, app, dest, store) = setup();
    let source = path(&app, ConfigBackupSource::Workspace);
    let original = fs::read(&source).unwrap();
    fs::rename(&source, app.join("old.json")).unwrap();
    symlink(app.join("old.json"), &source).unwrap();
    assert!(store
        .plan(vec![ConfigBackupSource::Workspace], &dest)
        .is_err());
    fs::remove_file(&source).unwrap();
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    let name = CString::new(source.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    assert!(store
        .plan(vec![ConfigBackupSource::Workspace], &dest)
        .is_err());
    fs::remove_file(&source).unwrap();
    fs::hard_link(app.join("old.json"), &source).unwrap();
    assert!(store
        .plan(vec![ConfigBackupSource::Workspace], &dest)
        .is_err());
    fs::remove_file(&source).unwrap();
    write(&source, &original);
    for mode in [0o644, 0o660, 0o700] {
        fs::set_permissions(&source, fs::Permissions::from_mode(mode)).unwrap();
        assert!(store
            .plan(vec![ConfigBackupSource::Workspace], &dest)
            .is_err());
    }
    fs::set_permissions(&source, fs::Permissions::from_mode(0o600)).unwrap();
    fs::set_permissions(source.parent().unwrap(), fs::Permissions::from_mode(0o755)).unwrap();
    assert!(store
        .plan(vec![ConfigBackupSource::Workspace], &dest)
        .is_err());
}

#[test]
fn selected_content_identity_addition_and_directory_or_root_changes_invalidate_one_time_plan() {
    for mode in ["bytes", "replacement", "directory", "root"] {
        let (temp, app, dest, store) = setup();
        let source = path(&app, ConfigBackupSource::Workspace);
        let p = store
            .plan(vec![ConfigBackupSource::Workspace], &dest)
            .unwrap();
        match mode {
            "bytes" => {
                let mut v = workspace();
                v["preferences"]["editorFontSize"] = json!(16);
                fs::write(&source, serde_json::to_vec(&v).unwrap()).unwrap();
            }
            "replacement" => {
                let bytes = fs::read(&source).unwrap();
                fs::rename(&source, app.join("old.json")).unwrap();
                write(&source, &bytes);
            }
            "directory" => {
                fs::rename(source.parent().unwrap(), app.join("old-workspace")).unwrap();
                write(&source, &serde_json::to_vec(&workspace()).unwrap());
            }
            _ => {
                fs::rename(&app, temp.path().join("old-app")).unwrap();
                dir(&app);
                fixtures(&app);
            }
        }
        assert!(store.execute(&p.plan_id, true).is_err());
        assert!(!dest.exists());
        assert!(store.execute(&p.plan_id, true).is_err());
    }
}

#[test]
fn existing_targets_symlink_parents_application_data_and_git_destinations_are_rejected() {
    let (temp, app, dest, store) = setup();
    let scope = || vec![ConfigBackupSource::Workspace];
    write(&dest, b"keep");
    assert!(store.plan(scope(), &dest).is_err());
    assert_eq!(fs::read(&dest).unwrap(), b"keep");
    fs::remove_file(&dest).unwrap();
    symlink("/missing", &dest).unwrap();
    assert!(store.plan(scope(), &dest).is_err());
    fs::remove_file(&dest).unwrap();
    assert!(store.plan(scope(), &app.join("backup.json")).is_err());
    assert!(store.plan(scope(), Path::new("relative.json")).is_err());
    assert!(store.plan(scope(), &dest.with_extension("txt")).is_err());
    let git = temp.path().join("repo");
    dir(&git);
    write(&git.join(".git"), b"gitdir: /private");
    assert!(store.plan(scope(), &git.join("out.json")).is_err());
    fs::remove_file(git.join(".git")).unwrap();
    write(&git.join("HEAD"), b"ref: refs/heads/main");
    write(&git.join("config"), b"bare=true");
    dir(&git.join("objects"));
    assert!(store.plan(scope(), &git.join("out.json")).is_err());
    let real = temp.path().join("real");
    dir(&real);
    let alias = temp.path().join("alias");
    symlink(&real, &alias).unwrap();
    assert!(store.plan(scope(), &alias.join("out.json")).is_err());
    fs::set_permissions(&real, fs::Permissions::from_mode(0o777)).unwrap();
    assert!(store.plan(scope(), &real.join("out.json")).is_err());
}

#[test]
fn collision_and_parent_replacement_preserve_existing_files_and_burn_execution() {
    let (_temp, _app, dest, store) = setup();
    let p = store
        .plan(vec![ConfigBackupSource::Workspace], &dest)
        .unwrap();
    write(&dest, b"existing");
    assert!(store.execute(&p.plan_id, true).is_err());
    assert_eq!(fs::read(&dest).unwrap(), b"existing");
    assert!(store.execute(&p.plan_id, true).is_err());
    let (temp, _app, _dest, store) = setup();
    let parent = temp.path().join("target");
    dir(&parent);
    let dest = parent.join("new.json");
    let p = store
        .plan(vec![ConfigBackupSource::Workspace], &dest)
        .unwrap();
    fs::rename(&parent, temp.path().join("old-target")).unwrap();
    dir(&parent);
    assert!(store.execute(&p.plan_id, true).is_err());
    assert!(!dest.exists());
    assert!(!temp.path().join("old-target/new.json").exists());
}

#[test]
fn source_drift_before_publication_refuses_and_post_publication_drift_is_unconfirmed() {
    let (_temp, app, dest, store) = setup();
    let p = store
        .plan(vec![ConfigBackupSource::Workspace], &dest)
        .unwrap();
    let mut changed = false;
    assert!(store
        .execute_checked(&p.plan_id, true, |published| {
            if !published && !changed {
                fs::write(path(&app, ConfigBackupSource::Workspace), b"changed").unwrap();
                changed = true;
            }
        })
        .is_err());
    assert!(!dest.exists());
    let (_temp, app, dest, store) = setup();
    let p = store
        .plan(vec![ConfigBackupSource::Workspace], &dest)
        .unwrap();
    let e = store
        .execute_checked(&p.plan_id, true, |published| {
            if published {
                fs::write(path(&app, ConfigBackupSource::Workspace), b"changed").unwrap();
            }
        })
        .unwrap_err();
    assert_eq!(e.code, "workspace_config_backup_unconfirmed");
    assert!(dest.exists());
    assert_eq!(hash(&fs::read(dest).unwrap()), p.sha256);
    assert!(store.execute(&p.plan_id, true).is_err());
}

#[test]
fn consent_expiry_discard_capacity_and_invalid_scopes_are_enforced_before_export() {
    let (temp, _app, dest, store) = setup();
    let source = ConfigBackupSource::Workspace;
    assert!(store.plan(vec![], &dest).is_err());
    assert!(store.plan(vec![source, source], &dest).is_err());
    let p = store.plan(vec![source], &dest).unwrap();
    assert!(store.execute(&p.plan_id, false).is_err());
    assert!(store.execute(&p.plan_id, true).is_err());
    let p = store.plan(vec![source], &dest).unwrap();
    store.discard(&p.plan_id).unwrap();
    assert!(store.execute(&p.plan_id, true).is_err());
    for wall in [false, true] {
        let p = store.plan(vec![source], &dest).unwrap();
        let mut plans = store.plans.lock().unwrap();
        let b = plans.get_mut(&p.plan_id).unwrap();
        if wall {
            b.preview.expires_at_epoch_ms = 1;
        } else {
            b.created = Instant::now() - TTL;
        }
        drop(plans);
        assert!(store.execute(&p.plan_id, true).is_err());
    }
    for i in 0..MAX_PLANS {
        store
            .plan(vec![source], &temp.path().join(format!("{i}.json")))
            .unwrap();
    }
    assert!(store.plan(vec![source], &dest).is_err());
    assert!(!dest.exists());
}

#[test]
fn oversized_sparse_files_and_oversized_or_invalid_recovery_content_are_never_exported() {
    let (_temp, app, dest, store) = setup();
    let source = ConfigBackupSource::Workspace;
    let file = path(&app, source);
    fs::OpenOptions::new()
        .write(true)
        .open(&file)
        .unwrap()
        .set_len(5 * 1024 * 1024 + 1)
        .unwrap();
    assert!(store.plan(vec![source], &dest).is_err());
    let mut v = workspace();
    v["recoveryDraft"]["text"] = json!("x".repeat(4 * 1024 * 1024 + 1));
    write(&file, &serde_json::to_vec(&v).unwrap());
    assert!(store.plan(vec![source], &dest).is_err());
    assert!(!dest.exists());
}

#[test]
fn metadata_only_preflight_ids_do_not_authorize_configuration_export() {
    let (_temp, app, dest, store) = setup();
    let preflight = super::super::WorkspaceBackupStore::new(app);
    let report = preflight
        .inspect(vec![super::super::BackupSource::Workspace])
        .unwrap();
    assert!(store.execute(&report.report_id, true).is_err());
    assert!(!dest.exists());
}

#[test]
fn initialized_git_directory_added_after_preview_rejects_export_but_empty_marker_is_not_a_repository(
) {
    let (temp, _app, _dest, store) = setup();
    let parent = temp.path().join("target");
    dir(&parent);
    dir(&parent.join(".git"));
    let destination = parent.join("new.json");
    let preview = store
        .plan(vec![ConfigBackupSource::Workspace], &destination)
        .unwrap();
    write(&parent.join(".git/HEAD"), b"ref: refs/heads/main");
    assert!(store.execute(&preview.plan_id, true).is_err());
    assert!(!destination.exists());
    assert!(store.execute(&preview.plan_id, true).is_err());
}
