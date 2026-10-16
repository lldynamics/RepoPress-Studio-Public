//! Minimal, fail-closed clients for creating hosted review requests.
//!
//! Tokens intentionally never enter a plan, receipt, error, or `Debug` output.

use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    future::Future,
    pin::Pin,
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;
#[path = "remote_review_verification.rs"]
mod verification;
pub use verification::{validate_review_evidence, validate_review_repository, validate_review_url};

const MAX_RESPONSE_BYTES: usize = 1024 * 1024;
const PLAN_LIFETIME: Duration = Duration::from_secs(5 * 60);

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum RemoteProvider {
    Github,
    Gitlab,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReviewRequestDraft {
    pub provider: RemoteProvider,
    pub owner: String,
    pub project: String,
    pub source_branch: String,
    pub target_branch: String,
    pub title: String,
    pub body: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteRequestSummary {
    pub provider: RemoteProvider,
    pub owner: String,
    pub project: String,
    pub source_branch: String,
    pub target_branch: String,
    pub title: String,
    pub body_bytes: usize,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RemotePublishPlan {
    pub plan_id: String,
    pub expires_at_unix_seconds: u64,
    pub request_summary: RemoteRequestSummary,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RemotePublishReceipt {
    pub provider: RemoteProvider,
    pub review_number: u64,
    pub web_url: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeploymentSnapshot {
    pub provider: RemoteProvider,
    pub status: String,
    pub conclusion: Option<String>,
    pub web_url: String,
    #[serde(rename = "ref")]
    pub git_ref: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RemotePublishError {
    pub code: &'static str,
    pub message: &'static str,
}

impl RemotePublishError {
    const fn new(code: &'static str, message: &'static str) -> Self {
        Self { code, message }
    }
}

impl std::fmt::Display for RemotePublishError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for RemotePublishError {}

/// A deliberately small seam used by tests. Implementations must not follow redirects.
pub trait RemoteTransport: Send + Sync {
    fn execute(
        &self,
        request: PreparedRequest,
    ) -> Pin<Box<dyn Future<Output = Result<TransportResponse, RemotePublishError>> + Send + '_>>;
}

/// Request information is passed only to the transport. Do not log or derive Debug for it:
/// headers can contain a caller-supplied bearer token.
pub struct PreparedRequest {
    pub method: HttpMethod,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub json_body: Option<serde_json::Value>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HttpMethod {
    Get,
    Post,
}

#[derive(Clone, Debug)]
pub struct TransportResponse {
    pub status: u16,
    pub content_length: Option<usize>,
    pub body: Vec<u8>,
}

/// The production transport has no proxy setting, no redirect support, and bounded timeouts.
pub struct ReqwestTransport {
    client: reqwest::Client,
}

impl ReqwestTransport {
    pub fn new() -> Result<Self, RemotePublishError> {
        let client = reqwest::Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(30))
            .build()
            .map_err(|_| {
                RemotePublishError::new("transport_setup_failed", "transport unavailable")
            })?;
        Ok(Self { client })
    }
}

impl RemoteTransport for ReqwestTransport {
    fn execute(
        &self,
        request: PreparedRequest,
    ) -> Pin<Box<dyn Future<Output = Result<TransportResponse, RemotePublishError>> + Send + '_>>
    {
        Box::pin(async move {
            let mut builder = match request.method {
                HttpMethod::Get => self.client.get(&request.url),
                HttpMethod::Post => self.client.post(&request.url),
            };
            for (name, value) in request.headers {
                builder = builder.header(name, value);
            }
            if let Some(json) = request.json_body {
                builder = builder.json(&json);
            }
            let mut response = builder.send().await.map_err(|_| {
                RemotePublishError::new("network_unavailable", "remote service unavailable")
            })?;
            if response.status().is_redirection() {
                return Err(RemotePublishError::new(
                    "redirect_rejected",
                    "redirects are not allowed",
                ));
            }
            let content_length = response.content_length().map(|length| length as usize);
            if content_length.is_some_and(|length| length > MAX_RESPONSE_BYTES) {
                return Err(RemotePublishError::new(
                    "response_too_large",
                    "remote response exceeded limit",
                ));
            }
            let status = response.status().as_u16();
            let mut body = Vec::with_capacity(content_length.unwrap_or(0).min(MAX_RESPONSE_BYTES));
            while let Some(chunk) = response.chunk().await.map_err(|_| {
                RemotePublishError::new("network_unavailable", "remote service unavailable")
            })? {
                if body.len().saturating_add(chunk.len()) > MAX_RESPONSE_BYTES {
                    return Err(RemotePublishError::new(
                        "response_too_large",
                        "remote response exceeded limit",
                    ));
                }
                body.extend_from_slice(&chunk);
            }
            Ok(TransportResponse {
                status,
                content_length,
                body,
            })
        })
    }
}

/// Keeps short-lived confirmation plans in memory only. A plan is consumed before I/O, so a
/// network failure cannot accidentally make the destructive request replayable.
pub struct RemotePublishStore {
    transport: Arc<dyn RemoteTransport>,
    plans: Mutex<HashMap<String, PendingPlan>>,
}

#[derive(Clone)]
struct PendingPlan {
    draft: ReviewRequestDraft,
    expires_at: u64,
    evidence: Option<super::remote_review_ledger::RemoteReviewEvidence>,
}

impl RemotePublishStore {
    pub fn new() -> Result<Self, RemotePublishError> {
        Ok(Self::with_transport(Arc::new(ReqwestTransport::new()?)))
    }

    pub fn with_transport(transport: Arc<dyn RemoteTransport>) -> Self {
        Self {
            transport,
            plans: Mutex::new(HashMap::new()),
        }
    }

    #[cfg(test)]
    pub fn plan_review_request(
        &self,
        draft: ReviewRequestDraft,
    ) -> Result<RemotePublishPlan, RemotePublishError> {
        validate_draft(&draft)?;
        let now = unix_seconds();
        let expires_at = now.saturating_add(PLAN_LIFETIME.as_secs());
        let plan_id = Uuid::new_v4().to_string();
        let pending = PendingPlan {
            draft: draft.clone(),
            expires_at,
            evidence: None,
        };
        self.plans
            .lock()
            .map_err(|_| {
                RemotePublishError::new("plan_store_unavailable", "plan store unavailable")
            })?
            .insert(plan_id.clone(), pending);
        Ok(RemotePublishPlan {
            plan_id,
            expires_at_unix_seconds: expires_at,
            request_summary: summary(&draft),
        })
    }

    #[cfg(test)]
    pub async fn create_review_request(
        &self,
        plan_id: &str,
        confirmed: bool,
        token: &str,
    ) -> Result<RemotePublishReceipt, RemotePublishError> {
        if !confirmed {
            return Err(RemotePublishError::new(
                "confirmation_required",
                "explicit confirmation is required",
            ));
        }
        validate_token(token)?;
        let pending = self
            .plans
            .lock()
            .map_err(|_| {
                RemotePublishError::new("plan_store_unavailable", "plan store unavailable")
            })?
            .remove(plan_id)
            .ok_or_else(|| {
                RemotePublishError::new(
                    "plan_not_found",
                    "plan is missing, expired, or already used",
                )
            })?;
        if pending.expires_at < unix_seconds() {
            return Err(RemotePublishError::new("plan_expired", "plan has expired"));
        }
        let request = build_create_request(&pending.draft, token)?;
        let response = self.transport.execute(request).await?;
        require_success(&response)?;
        parse_receipt(pending.draft.provider, &response.body)
    }

    pub async fn check_deployment(
        &self,
        provider: RemoteProvider,
        owner: &str,
        project: &str,
        git_ref: &str,
        token: Option<&str>,
    ) -> Result<DeploymentSnapshot, RemotePublishError> {
        validate_owner(provider, owner)?;
        validate_identifier(project)?;
        validate_branch(git_ref)?;
        if let Some(token) = token {
            validate_token(token)?;
        }
        let request = build_deployment_request(provider, owner, project, git_ref, token)?;
        let response = self.transport.execute(request).await?;
        require_success(&response)?;
        parse_deployment(provider, git_ref, &response.body)
    }
}

fn build_create_request(
    draft: &ReviewRequestDraft,
    token: &str,
) -> Result<PreparedRequest, RemotePublishError> {
    let (url, body, token_header) = match draft.provider {
        RemoteProvider::Github => (
            format!(
                "https://api.github.com/repos/{}/{}/pulls",
                draft.owner, draft.project
            ),
            serde_json::json!({ "title": draft.title, "head": draft.source_branch, "base": draft.target_branch, "body": draft.body }),
            ("Authorization".to_string(), format!("Bearer {token}")),
        ),
        RemoteProvider::Gitlab => (
            format!(
                "https://gitlab.com/api/v4/projects/{}/merge_requests",
                encoded_project_path(&draft.owner, &draft.project)
            ),
            serde_json::json!({ "title": draft.title, "source_branch": draft.source_branch, "target_branch": draft.target_branch, "description": draft.body }),
            ("PRIVATE-TOKEN".to_string(), token.to_string()),
        ),
    };
    ensure_official_api(draft.provider, &url)?;
    Ok(PreparedRequest {
        method: HttpMethod::Post,
        url,
        headers: vec![
            ("Accept".into(), "application/json".into()),
            ("User-Agent".into(), "RepoPressDesktop/0.1".into()),
            token_header,
        ],
        json_body: Some(body),
    })
}

fn build_deployment_request(
    provider: RemoteProvider,
    owner: &str,
    project: &str,
    git_ref: &str,
    token: Option<&str>,
) -> Result<PreparedRequest, RemotePublishError> {
    let escaped_ref = percent_encode(git_ref);
    let url = match provider {
        RemoteProvider::Github => format!("https://api.github.com/repos/{owner}/{project}/actions/runs?branch={escaped_ref}&per_page=1"),
        RemoteProvider::Gitlab => format!(
            "https://gitlab.com/api/v4/projects/{}/pipelines?ref={escaped_ref}&per_page=1",
            encoded_project_path(owner, project)
        ),
    };
    ensure_official_api(provider, &url)?;
    let mut headers = vec![
        ("Accept".into(), "application/json".into()),
        ("User-Agent".into(), "RepoPressDesktop/0.1".into()),
    ];
    if let Some(token) = token {
        match provider {
            RemoteProvider::Github => {
                headers.push(("Authorization".into(), format!("Bearer {token}")))
            }
            RemoteProvider::Gitlab => headers.push(("PRIVATE-TOKEN".into(), token.to_string())),
        }
    }
    Ok(PreparedRequest {
        method: HttpMethod::Get,
        url,
        headers,
        json_body: None,
    })
}

fn parse_receipt(
    provider: RemoteProvider,
    body: &[u8],
) -> Result<RemotePublishReceipt, RemotePublishError> {
    let value: serde_json::Value = parse_json(body)?;
    let (number, web_url) = match provider {
        RemoteProvider::Github => (
            value.get("number").and_then(serde_json::Value::as_u64),
            value.get("html_url").and_then(serde_json::Value::as_str),
        ),
        RemoteProvider::Gitlab => (
            value.get("iid").and_then(serde_json::Value::as_u64),
            value.get("web_url").and_then(serde_json::Value::as_str),
        ),
    };
    let number = number.ok_or_else(|| {
        RemotePublishError::new(
            "invalid_remote_response",
            "remote response missing review number",
        )
    })?;
    let web_url = web_url.ok_or_else(|| {
        RemotePublishError::new(
            "invalid_remote_response",
            "remote response missing review URL",
        )
    })?;
    ensure_official_web(provider, web_url)?;
    Ok(RemotePublishReceipt {
        provider,
        review_number: number,
        web_url: web_url.to_string(),
    })
}

fn parse_deployment(
    provider: RemoteProvider,
    git_ref: &str,
    body: &[u8],
) -> Result<DeploymentSnapshot, RemotePublishError> {
    let value: serde_json::Value = parse_json(body)?;
    let record = match provider {
        RemoteProvider::Github => value
            .get("workflow_runs")
            .and_then(serde_json::Value::as_array)
            .and_then(|runs| runs.first()),
        RemoteProvider::Gitlab => value.as_array().and_then(|runs| runs.first()),
    }
    .ok_or_else(|| {
        RemotePublishError::new("deployment_not_found", "no deployment status was found")
    })?;
    let status = record
        .get("status")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| {
            RemotePublishError::new(
                "invalid_remote_response",
                "remote response missing deployment status",
            )
        })?;
    let conclusion = record
        .get("conclusion")
        .or_else(|| record.get("detailed_status"))
        .and_then(serde_json::Value::as_str)
        .map(ToOwned::to_owned);
    let web_url = record
        .get("html_url")
        .or_else(|| record.get("web_url"))
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| {
            RemotePublishError::new(
                "invalid_remote_response",
                "remote response missing deployment URL",
            )
        })?;
    ensure_official_web(provider, web_url)?;
    Ok(DeploymentSnapshot {
        provider,
        status: status.to_string(),
        conclusion,
        web_url: web_url.to_string(),
        git_ref: git_ref.to_string(),
    })
}

fn require_success(response: &TransportResponse) -> Result<(), RemotePublishError> {
    if (300..400).contains(&response.status) {
        return Err(RemotePublishError::new(
            "redirect_rejected",
            "redirects are not allowed",
        ));
    }
    if !(200..300).contains(&response.status) {
        let error = match response.status {
            401 | 403 => {
                RemotePublishError::new("remote_unauthorized", "remote authorization was rejected")
            }
            404 => RemotePublishError::new("remote_not_found", "remote project was not found"),
            408 | 429 | 500..=599 => {
                RemotePublishError::new("remote_unavailable", "remote service unavailable")
            }
            _ => RemotePublishError::new("remote_rejected", "remote request was rejected"),
        };
        return Err(error);
    }
    if response.body.len() > MAX_RESPONSE_BYTES
        || response
            .content_length
            .is_some_and(|value| value > MAX_RESPONSE_BYTES)
    {
        return Err(RemotePublishError::new(
            "response_too_large",
            "remote response exceeded limit",
        ));
    }
    Ok(())
}

fn parse_json(body: &[u8]) -> Result<serde_json::Value, RemotePublishError> {
    serde_json::from_slice(body).map_err(|_| {
        RemotePublishError::new("invalid_remote_response", "remote response was invalid")
    })
}

fn validate_draft(draft: &ReviewRequestDraft) -> Result<(), RemotePublishError> {
    validate_owner(draft.provider, &draft.owner)?;
    validate_identifier(&draft.project)?;
    validate_branch(&draft.source_branch)?;
    validate_branch(&draft.target_branch)?;
    if draft.source_branch == draft.target_branch {
        return Err(RemotePublishError::new(
            "invalid_branch",
            "source and target branches must differ",
        ));
    }
    validate_text(&draft.title, 1, 256, false, "invalid_title")?;
    validate_text(&draft.body, 0, 65_536, true, "invalid_body")
}

fn validate_owner(provider: RemoteProvider, value: &str) -> Result<(), RemotePublishError> {
    match provider {
        RemoteProvider::Github => validate_identifier(value),
        RemoteProvider::Gitlab => {
            if value.is_empty()
                || value.len() > 255
                || value
                    .split('/')
                    .any(|segment| validate_identifier(segment).is_err())
            {
                Err(RemotePublishError::new(
                    "invalid_project",
                    "owner or project is invalid",
                ))
            } else {
                Ok(())
            }
        }
    }
}

fn validate_identifier(value: &str) -> Result<(), RemotePublishError> {
    if value.is_empty()
        || value.len() > 100
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return Err(RemotePublishError::new(
            "invalid_project",
            "owner or project is invalid",
        ));
    }
    Ok(())
}

fn validate_branch(value: &str) -> Result<(), RemotePublishError> {
    if value.is_empty()
        || value.len() > 255
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-' | b'/'))
        || value.contains("//")
        || value.starts_with('/')
        || value.ends_with('/')
    {
        return Err(RemotePublishError::new(
            "invalid_branch",
            "branch name is invalid",
        ));
    }
    Ok(())
}

fn validate_text(
    value: &str,
    min: usize,
    max: usize,
    allow_newlines: bool,
    code: &'static str,
) -> Result<(), RemotePublishError> {
    if value.len() < min
        || value.len() > max
        || value.chars().any(|character| {
            character.is_control() && !(allow_newlines && matches!(character, '\n' | '\r' | '\t'))
        })
    {
        return Err(RemotePublishError::new(code, "request text is invalid"));
    }
    Ok(())
}

fn validate_token(token: &str) -> Result<(), RemotePublishError> {
    if token.is_empty() || token.len() > 4096 || !token.bytes().all(|byte| byte.is_ascii_graphic())
    {
        return Err(RemotePublishError::new(
            "invalid_token",
            "remote token is invalid",
        ));
    }
    Ok(())
}

fn summary(draft: &ReviewRequestDraft) -> RemoteRequestSummary {
    RemoteRequestSummary {
        provider: draft.provider,
        owner: draft.owner.clone(),
        project: draft.project.clone(),
        source_branch: draft.source_branch.clone(),
        target_branch: draft.target_branch.clone(),
        title: draft.title.clone(),
        body_bytes: draft.body.len(),
    }
}

fn ensure_official_api(provider: RemoteProvider, value: &str) -> Result<(), RemotePublishError> {
    let expected = match provider {
        RemoteProvider::Github => "api.github.com",
        RemoteProvider::Gitlab => "gitlab.com",
    };
    ensure_https_host(value, expected, "invalid_remote_url")
}

fn ensure_official_web(provider: RemoteProvider, value: &str) -> Result<(), RemotePublishError> {
    let expected = match provider {
        RemoteProvider::Github => "github.com",
        RemoteProvider::Gitlab => "gitlab.com",
    };
    ensure_https_host(value, expected, "invalid_remote_response")
}

fn ensure_https_host(
    value: &str,
    expected_host: &str,
    code: &'static str,
) -> Result<(), RemotePublishError> {
    let parsed = reqwest::Url::parse(value)
        .map_err(|_| RemotePublishError::new(code, "remote URL is invalid"))?;
    if parsed.scheme() != "https"
        || parsed.host_str() != Some(expected_host)
        || parsed.port().is_some()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
    {
        return Err(RemotePublishError::new(
            code,
            "remote URL is not an official HTTPS URL",
        ));
    }
    Ok(())
}

fn percent_encode(value: &str) -> String {
    value
        .bytes()
        .flat_map(|byte| {
            if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
                vec![byte as char]
            } else {
                format!("%{byte:02X}").chars().collect()
            }
        })
        .collect()
}

fn encoded_project_path(owner: &str, project: &str) -> String {
    percent_encode(&format!("{owner}/{project}"))
}

fn unix_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    struct MockTransport {
        response: Mutex<Result<TransportResponse, RemotePublishError>>,
        requests: Mutex<Vec<PreparedRequest>>,
    }
    impl MockTransport {
        fn ok(json: &str) -> Self {
            Self {
                response: Mutex::new(Ok(TransportResponse {
                    status: 201,
                    content_length: Some(json.len()),
                    body: json.as_bytes().to_vec(),
                })),
                requests: Mutex::new(Vec::new()),
            }
        }
    }
    impl RemoteTransport for MockTransport {
        fn execute(
            &self,
            request: PreparedRequest,
        ) -> Pin<Box<dyn Future<Output = Result<TransportResponse, RemotePublishError>> + Send + '_>>
        {
            self.requests.lock().unwrap().push(request);
            Box::pin(async move { self.response.lock().unwrap().clone() })
        }
    }
    fn draft() -> ReviewRequestDraft {
        ReviewRequestDraft {
            provider: RemoteProvider::Github,
            owner: "owner".into(),
            project: "project".into(),
            source_branch: "feature/x".into(),
            target_branch: "main".into(),
            title: "Title".into(),
            body: "Body".into(),
        }
    }

    #[test]
    fn plan_is_one_time_and_token_never_enters_receipt() {
        let transport = Arc::new(MockTransport::ok(
            r#"{"number":4,"html_url":"https://github.com/owner/project/pull/4"}"#,
        ));
        let store = RemotePublishStore::with_transport(transport.clone());
        let plan = store.plan_review_request(draft()).unwrap();
        assert!(!format!("{:?}", plan).contains("secret-token"));
        let receipt = tauri::async_runtime::block_on(store.create_review_request(
            &plan.plan_id,
            true,
            "secret-token",
        ))
        .unwrap();
        assert!(!format!("{:?}", receipt).contains("secret-token"));
        assert_eq!(
            tauri::async_runtime::block_on(store.create_review_request(
                &plan.plan_id,
                true,
                "secret-token"
            ))
            .unwrap_err()
            .code,
            "plan_not_found"
        );
        let requests = transport.requests.lock().unwrap();
        assert_eq!(requests[0].headers[2].0, "Authorization");
        assert_eq!(requests[0].headers[2].1, "Bearer secret-token");
    }

    #[test]
    fn rejects_redirect_and_oversized_responses_without_network() {
        assert_eq!(
            require_success(&TransportResponse {
                status: 302,
                content_length: Some(0),
                body: vec![]
            })
            .unwrap_err()
            .code,
            "redirect_rejected"
        );
        assert_eq!(
            require_success(&TransportResponse {
                status: 200,
                content_length: Some(MAX_RESPONSE_BYTES + 1),
                body: vec![]
            })
            .unwrap_err()
            .code,
            "response_too_large"
        );
        let error = require_success(&TransportResponse {
            status: 401,
            content_length: Some(12),
            body: b"secret-token".to_vec(),
        })
        .unwrap_err();
        assert_eq!(error.code, "remote_unauthorized");
        assert!(!format!("{error:?}").contains("secret-token"));
    }

    #[test]
    fn rejects_non_official_response_urls() {
        assert!(ensure_official_web(RemoteProvider::Github, "http://github.com/a").is_err());
        assert!(
            ensure_official_web(RemoteProvider::Github, "https://github.com.evil.test/a").is_err()
        );
    }

    #[test]
    fn encodes_gitlab_nested_namespaces_as_one_project_identifier() {
        let draft = ReviewRequestDraft {
            provider: RemoteProvider::Gitlab,
            owner: "group/subgroup".into(),
            project: "project".into(),
            source_branch: "feature".into(),
            target_branch: "main".into(),
            title: "Title".into(),
            body: String::new(),
        };
        validate_draft(&draft).unwrap();
        let request = build_create_request(&draft, "secret-token").unwrap();
        assert_eq!(
            request.url,
            "https://gitlab.com/api/v4/projects/group%2Fsubgroup%2Fproject/merge_requests"
        );
    }
}
