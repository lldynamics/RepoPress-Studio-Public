use super::*;
use crate::core::remote_review_ledger::ReviewOutcome;
use serde_json::{json, Value};
use std::{
    collections::VecDeque,
    fs,
    future::Future,
    path::Path,
    pin::Pin,
    process::Command,
    sync::{Arc, Mutex},
};

type PostObserver = Arc<dyn Fn(&PreparedRequest) + Send + Sync>;
struct MockTransport {
    responses: Mutex<VecDeque<Result<TransportResponse, RemotePublishError>>>,
    requests: Mutex<Vec<PreparedRequest>>,
    post_observer: Option<PostObserver>,
}

impl MockTransport {
    fn new(responses: Vec<Result<TransportResponse, RemotePublishError>>) -> Self {
        Self {
            responses: Mutex::new(responses.into()),
            requests: Mutex::new(Vec::new()),
            post_observer: None,
        }
    }

    fn with_post_observer(
        responses: Vec<Result<TransportResponse, RemotePublishError>>,
        observer: Arc<dyn Fn(&PreparedRequest) + Send + Sync>,
    ) -> Self {
        Self {
            responses: Mutex::new(responses.into()),
            requests: Mutex::new(Vec::new()),
            post_observer: Some(observer),
        }
    }

    fn requests(&self) -> Vec<(HttpMethod, String)> {
        self.requests
            .lock()
            .unwrap()
            .iter()
            .map(|request| (request.method, request.url.clone()))
            .collect()
    }
}

impl RemoteTransport for MockTransport {
    fn execute(
        &self,
        request: PreparedRequest,
    ) -> Pin<Box<dyn Future<Output = Result<TransportResponse, RemotePublishError>> + Send + '_>>
    {
        if request.method == HttpMethod::Post {
            if let Some(observer) = &self.post_observer {
                observer(&request);
            }
        }
        self.requests.lock().unwrap().push(request);
        let response = self
            .responses
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or_else(|| {
                Err(RemotePublishError::new(
                    "unexpected_request",
                    "test transport received an unexpected request",
                ))
            });
        Box::pin(async move { response })
    }
}

fn response(status: u16, value: Value) -> Result<TransportResponse, RemotePublishError> {
    let body = serde_json::to_vec(&value).unwrap();
    Ok(TransportResponse {
        status,
        content_length: Some(body.len()),
        body,
    })
}

fn evidence(provider: RemoteProvider) -> RemoteReviewEvidence {
    let marker = "123e4567-e89b-42d3-a456-426614174000".to_string();
    let body = format!("Review body\n\n{}", marker_text(&marker));
    let (owner, remote_url) = match provider {
        RemoteProvider::Github => ("owner", "https://github.com/owner/project.git"),
        RemoteProvider::Gitlab => ("group", "git@gitlab.com:group/project.git"),
    };
    RemoteReviewEvidence {
        repository_path: "/tmp/repopress-remote-review-test".into(),
        repository_identity: "a".repeat(64),
        remote: "origin".into(),
        remote_url: remote_url.into(),
        provider,
        owner: owner.into(),
        project: "project".into(),
        remote_project_id: 42,
        source_branch: "feature/test".into(),
        target_branch: "main".into(),
        source_sha: "0123456789abcdef0123456789abcdef01234567".into(),
        title_sha256: text_hash("Recorded review"),
        body_sha256: text_hash(&body),
        marker,
    }
}

fn record(evidence: RemoteReviewEvidence) -> RemoteReviewRecord {
    RemoteReviewRecord {
        record_id: evidence.marker.clone(),
        revision: 1,
        evidence,
        outcome: ReviewOutcome::Unconfirmed,
        verification: ReviewVerification::NotChecked,
        review_number: None,
        web_url: None,
        started_at_epoch_ms: 1,
        checked_at_epoch_ms: None,
    }
}

fn body(evidence: &RemoteReviewEvidence) -> String {
    format!("Review body\n\n{}", marker_text(&evidence.marker))
}

fn github_project() -> Value {
    json!({ "id": 42, "full_name": "owner/project" })
}

fn github_detail(evidence: &RemoteReviewEvidence, number: u64) -> Value {
    json!({
        "number": number,
        "html_url": format!("https://github.com/owner/project/pull/{number}"),
        "title": "Recorded review",
        "body": body(evidence),
        "head": {
            "ref": evidence.source_branch,
            "sha": evidence.source_sha,
            "repo": { "id": 42, "full_name": "owner/project" }
        },
        "base": {
            "ref": evidence.target_branch,
            "repo": { "id": 42, "full_name": "owner/project" }
        }
    })
}

fn github_candidate(evidence: &RemoteReviewEvidence, number: u64) -> Value {
    json!({ "number": number, "body": body(evidence) })
}

fn gitlab_project() -> Value {
    json!({ "id": 42, "path_with_namespace": "group/project" })
}

fn gitlab_detail(evidence: &RemoteReviewEvidence, iid: u64) -> Value {
    json!({
        "iid": iid,
        "web_url": format!("https://gitlab.com/group/project/-/merge_requests/{iid}"),
        "title": "Recorded review",
        "description": body(evidence),
        "source_branch": evidence.source_branch,
        "target_branch": evidence.target_branch,
        "sha": evidence.source_sha,
        "diff_refs": { "head_sha": evidence.source_sha },
        "project_id": 42,
        "source_project_id": 42,
        "target_project_id": 42
    })
}

fn gitlab_candidate(evidence: &RemoteReviewEvidence, iid: u64) -> Value {
    json!({ "iid": iid, "description": body(evidence) })
}

fn observe(
    transport: Arc<MockTransport>,
    record: &RemoteReviewRecord,
) -> Result<(ReviewVerification, Option<RemotePublishReceipt>), RemotePublishError> {
    tauri::async_runtime::block_on(
        RemotePublishStore::with_transport(transport).observe_review(record, "token"),
    )
}

fn review_draft() -> ReviewRequestDraft {
    ReviewRequestDraft {
        provider: RemoteProvider::Github,
        owner: "owner".into(),
        project: "project".into(),
        source_branch: "feature/x".into(),
        target_branch: "main".into(),
        title: "Recorded review".into(),
        body: "Review body".into(),
    }
}

fn git(root: &Path, args: &[&str]) {
    let output = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn temporary_review_repository() -> tempfile::TempDir {
    let repository = tempfile::tempdir().unwrap();
    let root = repository.path();
    git(root, &["init", "-q", "-b", "feature/x"]);
    git(root, &["config", "user.name", "Remote review test"]);
    git(
        root,
        &["config", "user.email", "remote-review@example.invalid"],
    );
    fs::write(root.join("review.md"), "review\n").unwrap();
    git(root, &["add", "review.md"]);
    git(root, &["commit", "-q", "-m", "review fixture"]);
    git(
        root,
        &[
            "remote",
            "add",
            "origin",
            "https://github.com/owner/project.git",
        ],
    );
    repository
}

fn source_branch(evidence: &RemoteReviewEvidence) -> Value {
    json!({
        "name": evidence.source_branch,
        "commit": { "sha": evidence.source_sha }
    })
}

fn recorded_plan(
    store: &RemotePublishStore,
    root: &Path,
) -> (RemotePublishPlan, RemoteReviewEvidence, String) {
    let target = crate::core::git_publish::capture_review_target(root, "origin").unwrap();
    store
        .plan_recorded_review_request(review_draft(), target)
        .unwrap()
}

fn create_recorded(
    store: &RemotePublishStore,
    plan: &RemotePublishPlan,
    evidence: &RemoteReviewEvidence,
    ledger: &RemoteReviewLedgerStore,
) -> CommandResult<RemotePublishReceipt> {
    tauri::async_runtime::block_on(store.create_recorded_review_request(
        &plan.plan_id,
        evidence,
        "token",
        ledger,
    ))
}

fn assert_get_only(transport: &MockTransport) {
    assert!(
        transport
            .requests()
            .iter()
            .all(|(method, _)| *method == HttpMethod::Get),
        "reconciliation must never issue a POST"
    );
}

#[test]
fn evidence_requires_hashes_and_a_uuid_marker_and_observation_requires_project_id() {
    let valid = evidence(RemoteProvider::Github);
    assert!(validate_review_evidence(&valid).is_ok());

    let mut invalid_marker = valid.clone();
    invalid_marker.marker = "not-a-uuid".into();
    assert_eq!(
        validate_review_evidence(&invalid_marker).unwrap_err().code,
        "invalid_review_evidence"
    );
    let mut invalid_hash = valid.clone();
    invalid_hash.body_sha256 = "not-a-sha".into();
    assert_eq!(
        validate_review_evidence(&invalid_hash).unwrap_err().code,
        "invalid_review_evidence"
    );

    let mut no_project_identity = valid;
    no_project_identity.remote_project_id = 0;
    let transport = Arc::new(MockTransport::new(Vec::new()));
    assert_eq!(
        observe(transport.clone(), &record(no_project_identity))
            .unwrap_err()
            .code,
        "invalid_review_evidence"
    );
    assert!(transport.requests().is_empty());
}

#[test]
fn github_exact_marker_hash_sha_and_repository_ids_verify_after_detail_read() {
    let evidence = evidence(RemoteProvider::Github);
    let record = record(evidence.clone());
    let transport = Arc::new(MockTransport::new(vec![
        response(200, github_project()),
        response(200, json!([github_candidate(&evidence, 17)])),
        response(200, github_detail(&evidence, 17)),
    ]));

    let (verification, receipt) = observe(transport.clone(), &record).unwrap();

    assert_eq!(verification, ReviewVerification::Matched);
    assert_eq!(
        receipt.unwrap().web_url,
        "https://github.com/owner/project/pull/17"
    );
    let requests = transport.requests();
    assert_eq!(requests.len(), 3);
    assert!(requests[1].1.contains("state=all"));
    assert!(requests[1].1.contains("head=owner%3Afeature%2Ftest"));
    assert!(requests[2].1.ends_with("/pulls/17"));
    assert_get_only(&transport);
}

#[test]
fn gitlab_exact_marker_hash_sha_and_project_ids_verify_after_detail_read() {
    let evidence = evidence(RemoteProvider::Gitlab);
    let record = record(evidence.clone());
    let transport = Arc::new(MockTransport::new(vec![
        response(200, gitlab_project()),
        response(200, json!([gitlab_candidate(&evidence, 9)])),
        response(200, gitlab_detail(&evidence, 9)),
    ]));

    let (verification, receipt) = observe(transport.clone(), &record).unwrap();

    assert_eq!(verification, ReviewVerification::Matched);
    assert_eq!(
        receipt.unwrap().web_url,
        "https://gitlab.com/group/project/-/merge_requests/9"
    );
    let requests = transport.requests();
    assert!(requests[1].1.contains("source_branch=feature%2Ftest"));
    assert!(requests[2].1.ends_with("/merge_requests/9"));
    assert_get_only(&transport);
}

#[test]
fn github_repository_casing_preserves_identity_but_not_other_url_changes() {
    let evidence = evidence(RemoteProvider::Github);
    let mut project = github_project();
    project["full_name"] = json!("Owner/Project");
    let mut detail = github_detail(&evidence, 17);
    detail["head"]["repo"]["full_name"] = json!("Owner/Project");
    detail["base"]["repo"]["full_name"] = json!("Owner/Project");
    detail["html_url"] = json!("https://github.com/Owner/Project/pull/17");
    let transport = Arc::new(MockTransport::new(vec![
        response(200, project),
        response(200, json!([github_candidate(&evidence, 17)])),
        response(200, detail),
    ]));
    assert_eq!(
        observe(transport.clone(), &record(evidence.clone()))
            .unwrap()
            .0,
        ReviewVerification::Matched
    );
    assert_get_only(&transport);
    for url in [
        "https://github.com/Owner/Project/pull/17?token=bad",
        "https://github.com/Owner/Project/pull/17#fragment",
        "https://github.com.evil.test/Owner/Project/pull/17",
        "https://github.com/Owner/Other/pull/17",
    ] {
        assert!(validate_review_url(&evidence, 17, url).is_err());
    }
}

#[test]
fn empty_complete_scan_has_no_receipt_and_never_posts() {
    let evidence = evidence(RemoteProvider::Github);
    let record = record(evidence);
    let transport = Arc::new(MockTransport::new(vec![
        response(200, github_project()),
        response(200, json!([])),
    ]));

    let (verification, receipt) = observe(transport.clone(), &record).unwrap();

    assert_eq!(verification, ReviewVerification::NoMatch);
    assert!(receipt.is_none());
    assert_get_only(&transport);
    assert_eq!(transport.requests().len(), 2);
}

#[test]
fn multiple_marker_candidates_are_ambiguous_without_detail_or_post() {
    let evidence = evidence(RemoteProvider::Gitlab);
    let record = record(evidence.clone());
    let transport = Arc::new(MockTransport::new(vec![
        response(200, gitlab_project()),
        response(
            200,
            json!([
                gitlab_candidate(&evidence, 3),
                gitlab_candidate(&evidence, 4)
            ]),
        ),
    ]));

    let (verification, receipt) = observe(transport.clone(), &record).unwrap();

    assert_eq!(verification, ReviewVerification::Ambiguous);
    assert!(receipt.is_none());
    assert_eq!(transport.requests().len(), 2);
    assert_get_only(&transport);
}

#[test]
fn full_five_page_scan_is_incomplete_and_stays_ambiguous() {
    let evidence = evidence(RemoteProvider::Github);
    let record = record(evidence.clone());
    let mut responses = vec![response(200, github_project())];
    for _ in 0..5 {
        let rows = (0..20)
            .map(|number| json!({ "number": number + 1, "body": "unrelated" }))
            .collect::<Vec<_>>();
        responses.push(response(200, json!(rows)));
    }
    let transport = Arc::new(MockTransport::new(responses));

    let (verification, receipt) = observe(transport.clone(), &record).unwrap();

    assert_eq!(verification, ReviewVerification::Ambiguous);
    assert!(receipt.is_none());
    assert_eq!(transport.requests().len(), 6);
    assert_get_only(&transport);
}

#[test]
fn unauthorized_rate_limited_redirect_and_oversized_observations_fail_closed() {
    for (status, content_length, expected) in [
        (401, Some(2), "remote_unauthorized"),
        (429, Some(2), "remote_unavailable"),
        (302, Some(2), "redirect_rejected"),
        (200, Some(MAX_RESPONSE_BYTES + 1), "response_too_large"),
    ] {
        let evidence = evidence(RemoteProvider::Github);
        let record = record(evidence);
        let transport = Arc::new(MockTransport::new(vec![Ok(TransportResponse {
            status,
            content_length,
            body: b"[]".to_vec(),
        })]));

        let error = observe(transport.clone(), &record).unwrap_err();
        assert_eq!(error.code, expected, "status {status}");
        assert_eq!(transport.requests().len(), 1);
        assert_get_only(&transport);
    }
}

#[test]
fn cross_project_sha_body_and_url_drift_never_verify() {
    #[derive(Clone, Copy)]
    enum Drift {
        CrossProject,
        Sha,
        Body,
        Url,
    }
    for drift in [Drift::CrossProject, Drift::Sha, Drift::Body, Drift::Url] {
        let evidence = evidence(RemoteProvider::Github);
        let record = record(evidence.clone());
        let mut detail = github_detail(&evidence, 23);
        match drift {
            Drift::CrossProject => {
                detail["head"]["repo"]["id"] = json!(88);
                detail["head"]["repo"]["full_name"] = json!("other/project");
            }
            Drift::Sha => detail["head"]["sha"] = json!("abcdefabcdefabcdefabcdefabcdefabcdefabcd"),
            Drift::Body => {
                detail["body"] = json!(format!("changed\n\n{}", marker_text(&evidence.marker)))
            }
            Drift::Url => {
                detail["html_url"] = json!("https://github.com/owner/project/pull/23?changed=1")
            }
        }
        let transport = Arc::new(MockTransport::new(vec![
            response(200, github_project()),
            response(200, json!([github_candidate(&evidence, 23)])),
            response(200, detail),
        ]));

        let result = observe(transport.clone(), &record);
        match drift {
            Drift::Url => assert_eq!(result.unwrap_err().code, "invalid_review_evidence"),
            _ => {
                let (verification, receipt) = result.unwrap();
                assert_eq!(verification, ReviewVerification::NoMatch);
                assert!(receipt.is_none());
            }
        }
        assert_get_only(&transport);
    }
}

#[test]
fn recorded_creation_persists_unconfirmed_before_the_only_post_and_then_verifies_detail() {
    let repository = temporary_review_repository();
    let root = repository.path().to_path_buf();
    let data = tempfile::tempdir().unwrap();
    let ledger = Arc::new(RemoteReviewLedgerStore::new(data.path().to_path_buf()));
    let expected_root = root.clone();
    let expected_ledger = ledger.clone();
    let observer = Arc::new(move |request: &PreparedRequest| {
        assert_eq!(request.method, HttpMethod::Post);
        let records = expected_ledger.list(&expected_root).unwrap();
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].outcome, ReviewOutcome::Unconfirmed);
        assert_eq!(records[0].verification, ReviewVerification::NotChecked);
        assert_eq!(records[0].evidence.remote_project_id, 42);
        assert!(records[0].review_number.is_none());
    });
    let transport = Arc::new(MockTransport::with_post_observer(
        vec![
            response(200, github_project()),
            response(
                200,
                json!({ "name": "feature/x", "commit": { "sha": "placeholder" } }),
            ),
            response(
                201,
                json!({
                    "number": 31,
                    "html_url": "https://github.com/owner/project/pull/31"
                }),
            ),
            response(200, json!({})),
        ],
        observer,
    ));
    let store = RemotePublishStore::with_transport(transport.clone());
    let (plan, evidence, body_preview) = recorded_plan(&store, repository.path());
    assert!(body_preview.contains(&marker_text(&plan.plan_id)));
    assert_eq!(evidence.marker, plan.plan_id);

    let mut responses = transport.responses.lock().unwrap();
    responses[1] = response(200, source_branch(&evidence));
    responses[3] = response(200, github_detail(&evidence, 31));
    drop(responses);
    let receipt = create_recorded(&store, &plan, &evidence, ledger.as_ref()).unwrap();

    assert_eq!(receipt.review_number, 31);
    let records = ledger.list(repository.path()).unwrap();
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].outcome, ReviewOutcome::Verified);
    assert_eq!(records[0].verification, ReviewVerification::Matched);
    assert_eq!(records[0].review_number, Some(31));
    let requests = transport.requests();
    assert_eq!(
        requests
            .iter()
            .filter(|(method, _)| *method == HttpMethod::Post)
            .count(),
        1
    );
    assert_eq!(requests[2].0, HttpMethod::Post);
}

#[test]
fn unavailable_ledger_consumes_plan_without_a_post() {
    let repository = temporary_review_repository();
    let transport = Arc::new(MockTransport::new(vec![
        response(200, github_project()),
        response(
            200,
            json!({ "name": "feature/x", "commit": { "sha": "placeholder" } }),
        ),
    ]));
    let store = RemotePublishStore::with_transport(transport.clone());
    let (plan, evidence, _) = recorded_plan(&store, repository.path());
    transport.responses.lock().unwrap()[1] = response(200, source_branch(&evidence));
    let unavailable = RemoteReviewLedgerStore::default();

    assert_eq!(
        create_recorded(&store, &plan, &evidence, &unavailable)
            .unwrap_err()
            .code,
        "publish_ledger_unavailable"
    );
    assert_get_only(&transport);
    assert_eq!(transport.requests().len(), 2);
    assert_eq!(
        create_recorded(&store, &plan, &evidence, &unavailable)
            .unwrap_err()
            .code,
        "plan_not_found"
    );
}

#[test]
fn mismatched_hosted_source_sha_consumes_plan_before_any_post() {
    let repository = temporary_review_repository();
    let transport = Arc::new(MockTransport::new(vec![
        response(200, github_project()),
        response(
            200,
            json!({
                "name": "feature/x",
                "commit": { "sha": "abcdefabcdefabcdefabcdefabcdefabcdefabcd" }
            }),
        ),
    ]));
    let store = RemotePublishStore::with_transport(transport.clone());
    let (plan, evidence, _) = recorded_plan(&store, repository.path());
    let data = tempfile::tempdir().unwrap();
    let ledger = RemoteReviewLedgerStore::new(data.path().to_path_buf());

    assert_eq!(
        create_recorded(&store, &plan, &evidence, &ledger)
            .unwrap_err()
            .code,
        "remote_review_source_changed"
    );
    assert_get_only(&transport);
    assert_eq!(transport.requests().len(), 2);
    assert!(ledger.list(repository.path()).unwrap().is_empty());
    assert_eq!(
        create_recorded(&store, &plan, &evidence, &ledger)
            .unwrap_err()
            .code,
        "plan_not_found"
    );
}

#[test]
fn post_timeout_or_server_failure_stays_unconfirmed_and_restarted_observation_can_verify() {
    for post in [
        Err(RemotePublishError::new("network_unavailable", "timeout")),
        response(500, json!({ "message": "temporary failure" })),
    ] {
        let repository = temporary_review_repository();
        let data = tempfile::tempdir().unwrap();
        let transport = Arc::new(MockTransport::new(vec![
            response(200, github_project()),
            response(
                200,
                json!({ "name": "feature/x", "commit": { "sha": "placeholder" } }),
            ),
            post,
        ]));
        let store = RemotePublishStore::with_transport(transport.clone());
        let (plan, evidence, _) = recorded_plan(&store, repository.path());
        transport.responses.lock().unwrap()[1] = response(200, source_branch(&evidence));
        let ledger = RemoteReviewLedgerStore::new(data.path().to_path_buf());

        assert_eq!(
            create_recorded(&store, &plan, &evidence, &ledger)
                .unwrap_err()
                .code,
            "remote_review_outcome_unknown"
        );
        let initial = ledger.list(repository.path()).unwrap().pop().unwrap();
        assert_eq!(initial.outcome, ReviewOutcome::Unconfirmed);
        assert_eq!(initial.verification, ReviewVerification::Unavailable);
        drop(ledger);

        let restarted = RemoteReviewLedgerStore::new(data.path().to_path_buf());
        let pending = restarted.list(repository.path()).unwrap().pop().unwrap();
        let verification_transport = Arc::new(MockTransport::new(vec![
            response(200, github_project()),
            response(200, json!([github_candidate(&evidence, 47)])),
            response(200, github_detail(&evidence, 47)),
        ]));
        let (verification, receipt) = observe(verification_transport.clone(), &pending).unwrap();
        assert_eq!(verification, ReviewVerification::Matched);
        assert_eq!(receipt.unwrap().review_number, 47);
        assert_get_only(&verification_transport);
        assert_eq!(
            transport
                .requests()
                .iter()
                .filter(|(method, _)| *method == HttpMethod::Post)
                .count(),
            1
        );
    }
}

#[test]
fn successful_post_with_nonmatching_detail_is_not_reported_as_created() {
    let repository = temporary_review_repository();
    let data = tempfile::tempdir().unwrap();
    let transport = Arc::new(MockTransport::new(vec![
        response(200, github_project()),
        response(
            200,
            json!({ "name": "feature/x", "commit": { "sha": "placeholder" } }),
        ),
        response(
            201,
            json!({
                "number": 52,
                "html_url": "https://github.com/owner/project/pull/52"
            }),
        ),
        response(200, json!({})),
    ]));
    let store = RemotePublishStore::with_transport(transport.clone());
    let (plan, evidence, _) = recorded_plan(&store, repository.path());
    let mut mismatched = github_detail(&evidence, 52);
    mismatched["head"]["sha"] = json!("abcdefabcdefabcdefabcdefabcdefabcdefabcd");
    let mut responses = transport.responses.lock().unwrap();
    responses[1] = response(200, source_branch(&evidence));
    responses[3] = response(200, mismatched);
    drop(responses);
    let ledger = RemoteReviewLedgerStore::new(data.path().to_path_buf());

    assert_eq!(
        create_recorded(&store, &plan, &evidence, &ledger)
            .unwrap_err()
            .code,
        "remote_review_outcome_unknown"
    );
    let record = ledger.list(repository.path()).unwrap().pop().unwrap();
    assert_eq!(record.outcome, ReviewOutcome::Unconfirmed);
    assert_eq!(record.verification, ReviewVerification::Unavailable);
    assert!(record.review_number.is_none());
    assert_eq!(
        transport
            .requests()
            .iter()
            .filter(|(method, _)| *method == HttpMethod::Post)
            .count(),
        1
    );
}

#[test]
fn local_head_or_remote_url_drift_blocks_creation_before_any_request() {
    for drift in ["head", "url"] {
        let repository = temporary_review_repository();
        let transport = Arc::new(MockTransport::new(Vec::new()));
        let store = RemotePublishStore::with_transport(transport.clone());
        let (plan, evidence, _) = recorded_plan(&store, repository.path());
        if drift == "head" {
            fs::write(repository.path().join("later.md"), "later\n").unwrap();
            git(repository.path(), &["add", "later.md"]);
            git(repository.path(), &["commit", "-q", "-m", "later"]);
            fs::write(repository.path().join("unsaved.md"), "new work\n").unwrap();
            // Reconciliation is against the old frozen request, so newer local
            // commits and worktree edits must remain allowed.
            assert!(validate_review_repository(&evidence, false).is_ok());
        } else {
            git(
                repository.path(),
                &[
                    "remote",
                    "set-url",
                    "--push",
                    "origin",
                    "https://github.com/owner/replaced.git",
                ],
            );
            assert!(validate_review_repository(&evidence, false).is_err());
        }
        let data = tempfile::tempdir().unwrap();
        let ledger = RemoteReviewLedgerStore::new(data.path().to_path_buf());

        let error = create_recorded(&store, &plan, &evidence, &ledger).unwrap_err();
        assert_eq!(
            error.code,
            if drift == "head" {
                "remote_review_baseline_changed"
            } else {
                "publish_record_target_changed"
            }
        );
        assert!(transport.requests().is_empty());
        assert!(ledger.list(repository.path()).unwrap().is_empty());
    }
}
