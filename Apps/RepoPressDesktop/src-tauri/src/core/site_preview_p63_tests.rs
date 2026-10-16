use super::super::site_preview_plan::SitePreviewDocumentBinding;
use super::*;
use sha2::{Digest, Sha256};
use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::sync::Arc;

fn fixture() -> (tempfile::TempDir, PathBuf, PreviewGuard) {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().canonicalize().unwrap();
    let executable = root.join("synthetic-runtime");
    fs::write(&executable, b"fixed runtime").unwrap();
    let guard = PreviewGuard::capture(&root, &executable, None, None).unwrap();
    (temp, root, guard)
}
fn request() -> SitePreviewPlanRequest {
    SitePreviewPlanRequest {
        document: None,
        article_path: Some("/posts/a/".into()),
    }
}
fn stored(store: &SitePreviewStore, guard: PreviewGuard) -> SitePreviewPlan {
    store
        .store_plan("session", "hugo", request(), guard)
        .unwrap()
}
fn child() -> Child {
    Command::new("/usr/bin/sleep")
        .arg("30")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap()
}
fn install(
    store: &SitePreviewStore,
    plan: SitePreviewPlan,
    guard: PreviewGuard,
    root_url: String,
) -> u32 {
    let child = child();
    let pid = child.id();
    let mut state = store.lock().unwrap();
    state.owners.insert("session".into(), plan.plan_id.clone());
    state.processes.insert(
        "session".into(),
        PreviewProcess {
            child,
            id: plan.plan_id.clone(),
            site_kind: "hugo".into(),
            root_url,
            plan,
            guard,
        },
    );
    pid
}
#[test]
fn plans_are_single_use_and_new_plans_invalidate_old_for_the_session() {
    let (_temp, _root, guard) = fixture();
    let store = SitePreviewStore::default();
    let first = stored(&store, guard.clone());
    let second = stored(&store, guard);
    assert_ne!(first.plan_id, second.plan_id);
    assert!(store.consume_plan("session", &first.plan_id).is_err());
    assert!(store.consume_plan("session", &second.plan_id).is_ok());
    assert!(store.consume_plan("session", &second.plan_id).is_err());
}
#[test]
fn expired_plans_are_consumed_but_wrong_session_does_not_burn_another_plan() {
    let (_temp, _root, guard) = fixture();
    let store = SitePreviewStore::default();
    let plan = stored(&store, guard.clone());
    store
        .lock()
        .unwrap()
        .plans
        .get_mut(&plan.plan_id)
        .unwrap()
        .deadline = Instant::now() - Duration::from_secs(1);
    assert!(store.consume_plan("session", &plan.plan_id).is_err());
    assert!(!store.lock().unwrap().plans.contains_key(&plan.plan_id));
    let plan = stored(&store, guard);
    assert!(store.consume_plan("other", &plan.plan_id).is_err());
    assert!(store.consume_plan("session", &plan.plan_id).is_ok());
}
#[test]
fn unconfirmed_start_and_invalid_context_consume_without_spawning() {
    let (_temp, root, guard) = fixture();
    let store = SitePreviewStore::default();
    let plan = stored(&store, guard.clone());
    assert!(store
        .start_preview(
            "session",
            &plan.plan_id,
            false,
            || unreachable!(),
            |_| unreachable!()
        )
        .is_err());
    assert!(store.consume_plan("session", &plan.plan_id).is_err());
    let plan = stored(&store, guard);
    assert!(store
        .start_preview(
            "session",
            &plan.plan_id,
            true,
            || Ok((root.join("changed"), "hugo".into())),
            |_| unreachable!()
        )
        .is_err());
    assert!(store.lock().unwrap().processes.is_empty());
    assert!(store.consume_plan("session", &plan.plan_id).is_err());
}
#[test]
fn targeted_stop_never_kills_or_cancels_a_replacement_owner() {
    let (_temp, _root, guard) = fixture();
    let store = SitePreviewStore::default();
    let plan = stored(&store, guard.clone());
    let id = plan.plan_id.clone();
    install(&store, plan, guard, "http://127.0.0.1:1234/".into());
    store
        .stop_preview("session", Some("stale-preview-id"))
        .unwrap();
    assert!(store.current("session", &id));
    store.stop_preview("session", Some(&id)).unwrap();
    assert!(!store.current("session", &id));
    assert!(store.lock().unwrap().processes.is_empty());
}
#[test]
fn stop_invalidates_the_matching_pending_start_reservation_only() {
    let store = SitePreviewStore::default();
    store
        .lock()
        .unwrap()
        .owners
        .insert("session".into(), "new".into());
    store.stop_preview("session", Some("old")).unwrap();
    assert_eq!(store.lock().unwrap().owners.get("session").unwrap(), "new");
    store.stop_preview("session", Some("new")).unwrap();
    assert!(!store.lock().unwrap().owners.contains_key("session"));
}
#[test]
fn check_page_rejects_wrong_owner_before_http_and_detects_exited_child() {
    let (_temp, _root, guard) = fixture();
    let store = SitePreviewStore::default();
    let plan = stored(&store, guard.clone());
    let id = plan.plan_id.clone();
    install(&store, plan, guard, "http://127.0.0.1:1234/".into());
    assert!(store
        .check_page(
            "session",
            "wrong",
            SitePreviewPageTarget::Home,
            |_| unreachable!()
        )
        .is_err());
    assert!(store.current("session", &id));
    store
        .lock()
        .unwrap()
        .processes
        .get_mut("session")
        .unwrap()
        .child
        .kill()
        .unwrap();
    store
        .lock()
        .unwrap()
        .processes
        .get_mut("session")
        .unwrap()
        .child
        .wait()
        .unwrap();
    assert!(store
        .check_page(
            "session",
            &id,
            SitePreviewPageTarget::Home,
            |_| unreachable!()
        )
        .is_err());
    assert!(store.lock().unwrap().processes.is_empty());
}
#[test]
fn validates_exact_owned_article_without_waiting_for_body() {
    let (_temp, _root, guard) = fixture();
    let store = SitePreviewStore::default();
    let plan = stored(&store, guard.clone());
    let id = plan.plan_id.clone();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let mut reader = BufReader::new(socket.try_clone().unwrap());
        let mut first = String::new();
        reader.read_line(&mut first).unwrap();
        assert_eq!(first, "GET /posts/a/ HTTP/1.1\r\n");
        socket
            .write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
            .unwrap();
        thread::sleep(Duration::from_millis(100));
    });
    install(&store, plan, guard, format!("http://{address}/"));
    let result = store
        .check_page("session", &id, SitePreviewPageTarget::Article, |_| Ok(()))
        .unwrap();
    assert!(result.ready);
    assert_eq!(result.status_code, Some(200));
    assert_eq!(result.requested_url, format!("http://{address}/posts/a/"));
    store.stop_preview("session", Some(&id)).unwrap();
    server.join().unwrap();
}
#[test]
fn configuration_drift_stops_only_the_owned_preview_before_request() {
    let (_temp, root, guard) = fixture();
    let store = SitePreviewStore::default();
    let plan = stored(&store, guard.clone());
    let id = plan.plan_id.clone();
    install(&store, plan, guard, "http://127.0.0.1:1234/".into());
    fs::write(root.join("hugo.toml"), b"title='changed'").unwrap();
    assert!(store
        .check_page("session", &id, SitePreviewPageTarget::Home, |_| Ok(()))
        .is_err());
    assert!(!store.current("session", &id));
}
#[test]
fn revalidates_document_and_configuration_after_http_before_ready() {
    let (_temp, root, guard) = fixture();
    let store = SitePreviewStore::default();
    let plan = stored(&store, guard.clone());
    let id = plan.plan_id.clone();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let root2 = root.clone();
    let server = thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        let mut buffer = [0; 4096];
        assert!(socket.read(&mut buffer).unwrap() > 0);
        fs::write(root2.join("hugo.toml"), b"title='changed'").unwrap();
        socket
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
            .unwrap();
    });
    install(&store, plan, guard, format!("http://{address}/"));
    assert!(store
        .check_page("session", &id, SitePreviewPageTarget::Home, |_| Ok(()))
        .is_err());
    assert!(!store.current("session", &id));
    server.join().unwrap();
}
#[test]
fn check_cancellation_is_not_blocked_by_a_slow_header_or_shared_mutex() {
    let (_temp, _root, guard) = fixture();
    let store = Arc::new(SitePreviewStore::default());
    let plan = stored(&store, guard.clone());
    let id = plan.plan_id.clone();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let (sent, received) = std::sync::mpsc::channel();
    let server = thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        let mut buffer = [0; 4096];
        assert!(socket.read(&mut buffer).unwrap() > 0);
        sent.send(()).unwrap();
        thread::sleep(Duration::from_millis(400));
    });
    install(&store, plan, guard, format!("http://{address}/"));
    let worker_store = Arc::clone(&store);
    let worker_id = id.clone();
    let checker = thread::spawn(move || {
        worker_store.check_page("session", &worker_id, SitePreviewPageTarget::Home, |_| {
            Ok(())
        })
    });
    received.recv_timeout(Duration::from_secs(2)).unwrap();
    let began = Instant::now();
    store.stop_preview("session", Some(&id)).unwrap();
    assert!(began.elapsed() < Duration::from_millis(300));
    assert!(checker.join().unwrap().is_err());
    server.join().unwrap();
}
#[test]
fn disk_article_drift_rejects_a_bound_preview_before_probe() {
    let (_temp, root, _guard) = fixture();
    fs::create_dir(root.join("content")).unwrap();
    fs::write(root.join("content/a.md"), b"article").unwrap();
    let binding = SitePreviewDocumentBinding {
        document_id: "doc".into(),
        expected_sha256: format!("{:x}", Sha256::digest(b"article")),
        revision: 1,
    };
    let guard = PreviewGuard::capture(
        &root,
        &root.join("synthetic-runtime"),
        Some("content/a.md"),
        Some(&binding),
    )
    .unwrap();
    let store = SitePreviewStore::default();
    let plan = store
        .store_plan(
            "session",
            "hugo",
            SitePreviewPlanRequest {
                document: Some(binding),
                article_path: Some("/a/".into()),
            },
            guard.clone(),
        )
        .unwrap();
    let id = plan.plan_id.clone();
    install(&store, plan, guard, "http://127.0.0.1:1234/".into());
    fs::write(root.join("content/a.md"), b"new article").unwrap();
    assert!(store
        .check_page("session", &id, SitePreviewPageTarget::Article, |_| Ok(()))
        .is_err());
    assert!(!store.current("session", &id));
}

#[test]
fn later_start_cancels_an_older_start_before_expensive_validation_finishes() {
    let (_temp, root, guard) = fixture();
    let store = Arc::new(SitePreviewStore::default());
    let first = stored(&store, guard.clone());
    let (entered, wait_entered) = std::sync::mpsc::channel();
    let (release, wait_release) = std::sync::mpsc::channel();
    let wait_release = Mutex::new(wait_release);
    let root2 = root.clone();
    let store2 = Arc::clone(&store);
    let id1 = first.plan_id.clone();
    let old = thread::spawn(move || {
        store2.start_preview(
            "session",
            &id1,
            true,
            || {
                entered.send(()).unwrap();
                wait_release.lock().unwrap().recv().unwrap();
                Ok((root2.clone(), "hugo".into()))
            },
            |_| panic!("cancelled old start must not validate or spawn"),
        )
    });
    wait_entered.recv_timeout(Duration::from_secs(2)).unwrap();
    let newer = stored(&store, guard);
    store.consume_plan("session", &newer.plan_id).unwrap();
    release.send(()).unwrap();
    assert!(old.join().unwrap().is_err());
    assert!(store.pending_is_current("session", &newer.plan_id));
}
#[test]
fn targeted_stop_cancels_a_consumed_start_while_it_is_still_validating() {
    let (_temp, root, guard) = fixture();
    let store = Arc::new(SitePreviewStore::default());
    let plan = stored(&store, guard);
    let (entered, wait_entered) = std::sync::mpsc::channel();
    let (release, wait_release) = std::sync::mpsc::channel();
    let wait_release = Mutex::new(wait_release);
    let store2 = Arc::clone(&store);
    let id = plan.plan_id.clone();
    let pending = thread::spawn(move || {
        store2.start_preview(
            "session",
            &id,
            true,
            || {
                entered.send(()).unwrap();
                wait_release.lock().unwrap().recv().unwrap();
                Ok((root.clone(), "hugo".into()))
            },
            |_| panic!("stopped start must not validate or spawn"),
        )
    });
    wait_entered.recv_timeout(Duration::from_secs(2)).unwrap();
    store.stop_preview("session", Some(&plan.plan_id)).unwrap();
    release.send(()).unwrap();
    assert!(pending.join().unwrap().is_err());
    assert!(store.lock().unwrap().pending_starts.is_empty());
    assert!(store.lock().unwrap().processes.is_empty());
}

#[test]
fn early_read_does_not_cancel_a_reserved_start() {
    let store = SitePreviewStore::default();
    {
        let mut state = store.lock().unwrap();
        state.owners.insert("session".into(), "pending".into());
        state
            .pending_starts
            .insert("session".into(), "pending".into());
    }
    assert!(!store.current("session", "pending"));
    assert!(store.pending_is_current("session", "pending"));
    assert_eq!(
        store.lock().unwrap().owners.get("session").unwrap(),
        "pending"
    );
    assert!(store.request_for_preview("session", "pending").is_err());
    assert!(store.pending_is_current("session", "pending"));
}
#[test]
fn capacity_counts_reserved_starts_before_their_children_are_installed() {
    let store = SitePreviewStore::default();
    {
        let mut state = store.lock().unwrap();
        for index in 0..32 {
            state
                .owners
                .insert(format!("session-{index}"), format!("reserved-{index}"));
        }
    }
    store
        .lock()
        .unwrap()
        .pending_starts
        .insert("other-session".into(), "new".into());
    let error = store.reserve_spawn("other-session", "new").unwrap_err();
    assert_eq!(error.code, "preview_process_capacity");
    store
        .lock()
        .unwrap()
        .pending_starts
        .insert("session-1".into(), "replacement".into());
    assert!(store.reserve_spawn("session-1", "replacement").is_ok());
    assert_eq!(
        store.lock().unwrap().owners.get("session-1").unwrap(),
        "replacement"
    );
}
