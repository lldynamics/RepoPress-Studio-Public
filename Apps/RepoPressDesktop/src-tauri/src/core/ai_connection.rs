//! Deliberately narrow AI connection discovery and health probes.
//!
//! This is not a general AI client. A caller first creates a short-lived plan
//! that binds the provider settings and the current credential fingerprint. The
//! one-use plan is then rechecked immediately before the only allowed request:
//! listing `/models` or sending a tiny fixed `/chat/completions` probe.

use super::{
    ai_credentials::AiCredential,
    ai_provider::{
        validate_endpoint, AiError, AiProviderKind, MAX_MODEL_BYTES, MAX_RESPONSE_BYTES,
    },
};
use reqwest::{header::CONTENT_TYPE, redirect::Policy, Client, StatusCode};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, VecDeque},
    net::{IpAddr, SocketAddr},
    sync::Mutex,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use url::Url;
use uuid::Uuid;

const PLAN_TTL: Duration = Duration::from_secs(5 * 60);
const MAX_PLANS: usize = 32;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const TOTAL_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_MODELS: usize = 200;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AiConnectionOperation {
    Models,
    Probe,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AiConnectionRequest {
    pub operation: AiConnectionOperation,
    pub provider: AiProviderKind,
    pub endpoint: String,
    pub model: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AiConnectionPlan {
    pub plan_id: String,
    pub operation: AiConnectionOperation,
    pub provider: AiProviderKind,
    pub endpoint: String,
    pub request_url: String,
    pub model: Option<String>,
    pub expires_at: u64,
    pub request_summary: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AiConnectionStatus {
    ModelsAvailable,
    ProbeSucceeded,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AiConnectionResult {
    pub plan_id: String,
    pub operation: AiConnectionOperation,
    pub provider: AiProviderKind,
    pub endpoint: String,
    pub model: Option<String>,
    pub models: Vec<String>,
    pub checked_at: u64,
    pub status: AiConnectionStatus,
    pub warnings: Vec<String>,
    pub elapsed_ms: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct BoundRequest {
    operation: AiConnectionOperation,
    provider: AiProviderKind,
    endpoint: String,
    model: Option<String>,
}

struct StoredPlan {
    request: BoundRequest,
    credential_fingerprint: Option<[u8; 32]>,
    expires_at: u64,
}

/// A consumed approval, moved once into execution. Fields are private and the
/// ticket cannot be cloned or reconstructed by an IPC caller.
pub(crate) struct AiConnectionExecution {
    plan_id: String,
    stored: StoredPlan,
}

struct PlanState {
    plans: HashMap<String, StoredPlan>,
    order: VecDeque<String>,
}

/// Owns no credentials. It stores only a SHA-256 fingerprint for each pending
/// plan, so a credential rotation invalidates a plan without exposing the token.
pub struct AiConnectionStore {
    client: Client,
    state: Mutex<PlanState>,
}

impl AiConnectionStore {
    pub fn new() -> Result<Self, AiError> {
        let client = Client::builder()
            .no_proxy()
            .redirect(Policy::none())
            // `localhost` is fixed to loopback instead of trusting a resolver
            // result. Numeric loopback hosts are checked in `normalize_request`.
            .resolve("localhost", SocketAddr::from(([127, 0, 0, 1], 0)))
            .connect_timeout(CONNECT_TIMEOUT)
            .timeout(TOTAL_TIMEOUT)
            .build()
            .map_err(|_| AiError::new("network", "AI connection is unavailable."))?;
        Ok(Self {
            client,
            state: Mutex::new(PlanState {
                plans: HashMap::new(),
                order: VecDeque::new(),
            }),
        })
    }

    /// Creates a reviewable, five-minute one-use plan. This method never makes
    /// a network request.
    pub fn plan(
        &self,
        request: AiConnectionRequest,
        credential: Option<&AiCredential>,
    ) -> Result<AiConnectionPlan, AiError> {
        let bound = normalize_request(request)?;
        let credential_fingerprint = credential_fingerprint(bound.provider, credential)?;
        let now = now_ms()?;
        let expires_at = now
            .checked_add(PLAN_TTL.as_millis() as u64)
            .ok_or_else(clock_error)?;
        let plan_id = Uuid::new_v4().to_string();
        let plan = public_plan(&plan_id, &bound, expires_at)?;

        let mut state = self.state.lock().map_err(|_| store_error())?;
        purge_expired(&mut state, now);
        while state.plans.len() >= MAX_PLANS {
            if let Some(oldest) = state.order.pop_front() {
                state.plans.remove(&oldest);
            } else {
                break;
            }
        }
        state.order.push_back(plan_id.clone());
        state.plans.insert(
            plan_id,
            StoredPlan {
                request: bound,
                credential_fingerprint,
                expires_at,
            },
        );
        Ok(plan)
    }

    /// Consume before credential lookup or request validation. Dropping this
    /// ticket on any preparation failure never restores the approval.
    pub(crate) fn take_execution(&self, plan_id: &str) -> Result<AiConnectionExecution, AiError> {
        if plan_id.is_empty()
            || plan_id.len() > 160
            || plan_id.bytes().any(|byte| byte.is_ascii_control())
        {
            return Err(AiError::new(
                "invalid_response",
                "AI connection plan is invalid.",
            ));
        }
        let now = now_ms()?;
        let stored = {
            let mut state = self.state.lock().map_err(|_| store_error())?;
            purge_expired(&mut state, now);
            let stored = state.plans.remove(plan_id).ok_or_else(|| {
                AiError::new("invalid_response", "AI connection plan is unavailable.")
            })?;
            state.order.retain(|id| id != plan_id);
            stored
        };
        Ok(AiConnectionExecution {
            plan_id: plan_id.to_string(),
            stored,
        })
    }

    pub(crate) async fn execute_prepared(
        &self,
        execution: AiConnectionExecution,
        request: AiConnectionRequest,
        credential: Option<&AiCredential>,
    ) -> Result<AiConnectionResult, AiError> {
        let AiConnectionExecution { plan_id, stored } = execution;
        // Secret Service lookup can suspend preparation long enough to expire.
        if now_ms()? >= stored.expires_at {
            return Err(AiError::new(
                "invalid_response",
                "AI connection plan expired.",
            ));
        }

        let bound = normalize_request(request)?;
        if bound != stored.request {
            return Err(AiError::new(
                "invalid_response",
                "AI connection settings changed; create a new plan.",
            ));
        }
        let current_fingerprint = credential_fingerprint(bound.provider, credential)?;
        if current_fingerprint != stored.credential_fingerprint {
            return Err(AiError::new(
                "auth",
                "AI credential changed; create a new plan.",
            ));
        }

        let started = Instant::now();
        let request_url = request_url(&bound)?;
        let response = match bound.operation {
            AiConnectionOperation::Models => {
                self.send_get(&request_url, bound.provider, credential)
                    .await?
            }
            AiConnectionOperation::Probe => {
                let model = bound.model.as_deref().expect("probe model is normalized");
                self.send_probe(&request_url, model, bound.provider, credential)
                    .await?
            }
        };
        let body = read_response_body(response, started).await?;
        let elapsed_ms = started.elapsed().as_millis().min(u64::MAX as u128) as u64;
        let checked_at = now_ms()?;

        match bound.operation {
            AiConnectionOperation::Models => {
                let (models, warnings) = parse_models(&body)?;
                Ok(AiConnectionResult {
                    plan_id: plan_id.to_string(),
                    operation: bound.operation,
                    provider: bound.provider,
                    endpoint: bound.endpoint,
                    model: bound.model,
                    models,
                    checked_at,
                    status: AiConnectionStatus::ModelsAvailable,
                    warnings,
                    elapsed_ms,
                })
            }
            AiConnectionOperation::Probe => {
                validate_probe_response(&body)?;
                Ok(AiConnectionResult {
                    plan_id: plan_id.to_string(),
                    operation: bound.operation,
                    provider: bound.provider,
                    endpoint: bound.endpoint,
                    model: bound.model,
                    models: Vec::new(),
                    checked_at,
                    status: AiConnectionStatus::ProbeSucceeded,
                    warnings: Vec::new(),
                    elapsed_ms,
                })
            }
        }
    }

    #[cfg(test)]
    async fn execute(
        &self,
        plan_id: &str,
        request: AiConnectionRequest,
        credential: Option<&AiCredential>,
    ) -> Result<AiConnectionResult, AiError> {
        let execution = self.take_execution(plan_id)?;
        self.execute_prepared(execution, request, credential).await
    }

    async fn send_get(
        &self,
        url: &str,
        provider: AiProviderKind,
        credential: Option<&AiCredential>,
    ) -> Result<reqwest::Response, AiError> {
        let mut request = self.client.get(url).header("accept", "application/json");
        if provider == AiProviderKind::OpenaiCompatible {
            request = request.bearer_auth(required_token(credential)?);
        }
        send_checked(request).await
    }

    async fn send_probe(
        &self,
        url: &str,
        model: &str,
        provider: AiProviderKind,
        credential: Option<&AiCredential>,
    ) -> Result<reqwest::Response, AiError> {
        let body = serde_json::json!({
            "model": model,
            "messages": [{"role": "user", "content": "Reply with OK."}],
            "max_tokens": 8,
            "stream": false
        });
        let mut request = self.client.post(url).json(&body);
        if provider == AiProviderKind::OpenaiCompatible {
            request = request.bearer_auth(required_token(credential)?);
        }
        send_checked(request).await
    }
}

fn normalize_request(request: AiConnectionRequest) -> Result<BoundRequest, AiError> {
    let endpoint = validate_endpoint(request.provider, &request.endpoint)?;
    if request.provider == AiProviderKind::OllamaLocal && !strict_loopback_endpoint(&endpoint) {
        return Err(AiError::new(
            "ai_endpoint_policy_rejected",
            "Ollama endpoints must use localhost or a numeric loopback address.",
        ));
    }
    let model = if request.model.is_empty() {
        if request.operation != AiConnectionOperation::Models {
            return Err(AiError::new(
                "invalid_response",
                "A model is required for a connection probe.",
            ));
        }
        None
    } else {
        validate_model_id(&request.model)?;
        Some(request.model)
    };
    Ok(BoundRequest {
        operation: request.operation,
        provider: request.provider,
        endpoint,
        model,
    })
}

fn strict_loopback_endpoint(endpoint: &str) -> bool {
    let Ok(url) = Url::parse(endpoint) else {
        return false;
    };
    let Some(host) = url.host_str() else {
        return false;
    };
    if host.eq_ignore_ascii_case("localhost") {
        return true;
    }
    match host.trim_matches(['[', ']']).parse::<IpAddr>() {
        Ok(IpAddr::V4(address)) => address.is_loopback(),
        Ok(IpAddr::V6(address)) => address.is_loopback(),
        Err(_) => false,
    }
}

fn validate_model_id(value: &str) -> Result<(), AiError> {
    if value.trim().is_empty()
        || value.trim() != value
        || value.len() > MAX_MODEL_BYTES
        || value.bytes().any(|byte| byte.is_ascii_control())
    {
        return Err(AiError::new("invalid_response", "AI model is invalid."));
    }
    Ok(())
}

fn credential_fingerprint(
    provider: AiProviderKind,
    credential: Option<&AiCredential>,
) -> Result<Option<[u8; 32]>, AiError> {
    match provider {
        AiProviderKind::OpenaiCompatible => {
            let token = required_token(credential)?;
            Ok(Some(Sha256::digest(token.as_bytes()).into()))
        }
        AiProviderKind::OllamaLocal => {
            if credential.is_some() {
                return Err(AiError::new(
                    "invalid_response",
                    "Ollama connection checks do not accept credentials.",
                ));
            }
            Ok(None)
        }
    }
}

fn required_token(credential: Option<&AiCredential>) -> Result<&str, AiError> {
    credential
        .map(AiCredential::token)
        .ok_or_else(|| AiError::new("auth", "AI credential is required."))
}

fn public_plan(
    plan_id: &str,
    request: &BoundRequest,
    expires_at: u64,
) -> Result<AiConnectionPlan, AiError> {
    let request_url = request_url(request)?;
    let request_summary = match request.operation {
        AiConnectionOperation::Models => "List available model identifiers.".to_string(),
        AiConnectionOperation::Probe => "Send a minimal AI connection probe.".to_string(),
    };
    Ok(AiConnectionPlan {
        plan_id: plan_id.to_string(),
        operation: request.operation,
        provider: request.provider,
        endpoint: request.endpoint.clone(),
        request_url,
        model: request.model.clone(),
        expires_at,
        request_summary,
    })
}

fn request_url(request: &BoundRequest) -> Result<String, AiError> {
    let suffix = match request.operation {
        AiConnectionOperation::Models => "models",
        AiConnectionOperation::Probe => "chat/completions",
    };
    let mut url = Url::parse(&request.endpoint)
        .map_err(|_| AiError::new("invalid_response", "AI endpoint is invalid."))?;
    let base = url.path().trim_end_matches('/');
    url.set_path(&format!("{base}/{suffix}"));
    Ok(url.into())
}

async fn send_checked(request: reqwest::RequestBuilder) -> Result<reqwest::Response, AiError> {
    let response = request.send().await.map_err(map_reqwest_error)?;
    if response.status().is_redirection() {
        return Err(AiError::new("unsupported", "AI redirects are not allowed."));
    }
    if !response.status().is_success() {
        return Err(http_error(response.status()));
    }
    if response
        .content_length()
        .is_some_and(|length| length > MAX_RESPONSE_BYTES as u64)
    {
        return Err(AiError::new("too_large", "AI response exceeded the limit."));
    }
    Ok(response)
}

async fn read_response_body(
    mut response: reqwest::Response,
    started: Instant,
) -> Result<Vec<u8>, AiError> {
    if response
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|header| header.to_str().ok())
        .is_some_and(|value| !value.to_ascii_lowercase().starts_with("application/json"))
    {
        return Err(AiError::new("invalid_response", "AI response is invalid."));
    }
    let mut body = Vec::new();
    loop {
        let remaining = TOTAL_TIMEOUT
            .checked_sub(started.elapsed())
            .ok_or_else(|| AiError::new("timeout", "AI connection timed out."))?;
        let chunk = tokio::time::timeout(remaining, response.chunk())
            .await
            .map_err(|_| AiError::new("timeout", "AI connection timed out."))?
            .map_err(map_reqwest_error)?;
        let Some(chunk) = chunk else { break };
        if body.len().saturating_add(chunk.len()) > MAX_RESPONSE_BYTES {
            return Err(AiError::new("too_large", "AI response exceeded the limit."));
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

fn map_reqwest_error(error: reqwest::Error) -> AiError {
    if error.is_timeout() {
        AiError::new("timeout", "AI connection timed out.")
    } else {
        AiError::new("network", "AI connection is unavailable.")
    }
}

fn http_error(status: StatusCode) -> AiError {
    match status.as_u16() {
        401 => AiError::new("auth", "AI credential was rejected."),
        403 => AiError::new("denied", "AI request was denied."),
        408 | 504 => AiError::new("timeout", "AI connection timed out."),
        413 => AiError::new("too_large", "AI response exceeded the limit."),
        429 => AiError::new("rate_limit", "AI service rate limit reached."),
        404 | 405 | 406 | 415 | 422 | 501 => {
            AiError::new("unsupported", "AI service does not support this check.")
        }
        _ if status.is_server_error() => AiError::new("network", "AI connection is unavailable."),
        _ => AiError::new(
            "invalid_response",
            "AI service returned an invalid response.",
        ),
    }
}

fn parse_models(body: &[u8]) -> Result<(Vec<String>, Vec<String>), AiError> {
    let value: serde_json::Value = serde_json::from_slice(body)
        .map_err(|_| AiError::new("invalid_response", "AI model response is invalid."))?;
    let object = value
        .as_object()
        .ok_or_else(|| AiError::new("invalid_response", "AI model response is invalid."))?;
    let data = object
        .get("data")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| AiError::new("invalid_response", "AI model response is invalid."))?;

    let mut models = Vec::new();
    let mut seen = std::collections::HashSet::new();
    let mut truncated = pagination_is_present(object);
    for entry in data {
        let id = entry
            .as_object()
            .and_then(|object| object.get("id"))
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| AiError::new("invalid_response", "AI model response is invalid."))?;
        validate_model_id(id)
            .map_err(|_| AiError::new("invalid_response", "AI model response is invalid."))?;
        if seen.insert(id.to_string()) {
            if models.len() < MAX_MODELS {
                models.push(id.to_string());
            } else {
                truncated = true;
            }
        }
    }
    let warnings = if truncated {
        vec!["Model list is partial; additional pages were not requested.".to_string()]
    } else {
        Vec::new()
    };
    Ok((models, warnings))
}

fn pagination_is_present(object: &serde_json::Map<String, serde_json::Value>) -> bool {
    ["has_more", "hasMore"]
        .iter()
        .any(|key| object.get(*key).and_then(serde_json::Value::as_bool) == Some(true))
        || ["next", "next_page", "nextPage", "cursor", "after"]
            .iter()
            .any(|key| object.get(*key).is_some_and(pagination_value_present))
}

fn pagination_value_present(value: &serde_json::Value) -> bool {
    !value.is_null()
        && match value {
            serde_json::Value::Bool(value) => *value,
            serde_json::Value::String(value) => !value.is_empty(),
            serde_json::Value::Array(value) => !value.is_empty(),
            serde_json::Value::Object(value) => !value.is_empty(),
            serde_json::Value::Number(_) => true,
            serde_json::Value::Null => false,
        }
}

fn validate_probe_response(body: &[u8]) -> Result<(), AiError> {
    let value: serde_json::Value = serde_json::from_slice(body)
        .map_err(|_| AiError::new("invalid_response", "AI probe response is invalid."))?;
    let content = value
        .as_object()
        .and_then(|object| object.get("choices"))
        .and_then(serde_json::Value::as_array)
        .and_then(|choices| choices.first())
        .and_then(serde_json::Value::as_object)
        .and_then(|choice| choice.get("message"))
        .and_then(serde_json::Value::as_object)
        .and_then(|message| message.get("content"))
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| AiError::new("invalid_response", "AI probe response is invalid."))?;
    if content.trim().is_empty() {
        return Err(AiError::new(
            "invalid_response",
            "AI probe response is invalid.",
        ));
    }
    Ok(())
}

fn purge_expired(state: &mut PlanState, now: u64) {
    state.plans.retain(|_, plan| plan.expires_at >= now);
    state.order.retain(|id| state.plans.contains_key(id));
}

fn now_ms() -> Result<u64, AiError> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis().min(u64::MAX as u128) as u64)
        .map_err(|_| clock_error())
}

fn clock_error() -> AiError {
    AiError::new("invalid_response", "System clock is invalid.")
}

fn store_error() -> AiError {
    AiError::new("network", "AI connection storage is unavailable.")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{Read, Write},
        net::{TcpListener, TcpStream},
        sync::mpsc,
        thread,
    };

    fn local_request(
        operation: AiConnectionOperation,
        model: &str,
        port: u16,
    ) -> AiConnectionRequest {
        AiConnectionRequest {
            operation,
            provider: AiProviderKind::OllamaLocal,
            endpoint: format!("http://127.0.0.1:{port}/v1"),
            model: model.to_string(),
        }
    }

    fn external_request(operation: AiConnectionOperation, model: &str) -> AiConnectionRequest {
        AiConnectionRequest {
            operation,
            provider: AiProviderKind::OpenaiCompatible,
            endpoint: "https://api.example.test/v1".to_string(),
            model: model.to_string(),
        }
    }

    fn credential(value: &str) -> AiCredential {
        AiCredential::from_token(value.to_string()).unwrap()
    }

    fn fixture<F>(handler: F) -> (u16, mpsc::Receiver<String>)
    where
        F: FnOnce(TcpStream, String) + Send + 'static,
    {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let (tx, rx) = mpsc::channel();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let request = read_request(&mut stream);
            let _ = tx.send(request.clone());
            handler(stream, request);
        });
        (port, rx)
    }

    fn read_request(stream: &mut TcpStream) -> String {
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let mut bytes = Vec::new();
        let mut buffer = [0u8; 1024];
        while !bytes.windows(4).any(|window| window == b"\r\n\r\n") {
            let read = stream.read(&mut buffer).unwrap();
            if read == 0 {
                break;
            }
            bytes.extend_from_slice(&buffer[..read]);
        }
        let header_end = bytes
            .windows(4)
            .position(|window| window == b"\r\n\r\n")
            .unwrap()
            + 4;
        let headers = String::from_utf8_lossy(&bytes[..header_end]).to_string();
        let length = headers
            .lines()
            .find_map(|line| {
                line.strip_prefix("content-length: ")
                    .or_else(|| line.strip_prefix("Content-Length: "))
            })
            .and_then(|value| value.parse::<usize>().ok())
            .unwrap_or(0);
        while bytes.len() < header_end + length {
            let read = stream.read(&mut buffer).unwrap();
            if read == 0 {
                break;
            }
            bytes.extend_from_slice(&buffer[..read]);
        }
        String::from_utf8_lossy(&bytes).to_string()
    }

    fn json_response(mut stream: TcpStream, status: &str, body: &str) {
        write!(
            stream,
            "HTTP/1.1 {status}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
            body.len()
        )
        .unwrap();
    }

    #[test]
    fn plans_expire_are_one_use_and_bind_settings_and_credential() {
        let store = AiConnectionStore::new().unwrap();
        let request = external_request(AiConnectionOperation::Probe, "m");
        let first = store
            .plan(request.clone(), Some(&credential("one")))
            .unwrap();
        {
            let mut state = store.state.lock().unwrap();
            state.plans.get_mut(&first.plan_id).unwrap().expires_at = 0;
        }
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        assert_eq!(
            runtime
                .block_on(store.execute(&first.plan_id, request.clone(), Some(&credential("one"))))
                .unwrap_err()
                .code,
            "invalid_response"
        );

        let second = store
            .plan(request.clone(), Some(&credential("one")))
            .unwrap();
        let mut changed = request.clone();
        changed.model = "different".to_string();
        assert_eq!(
            runtime
                .block_on(store.execute(&second.plan_id, changed, Some(&credential("one"))))
                .unwrap_err()
                .code,
            "invalid_response"
        );
        assert_eq!(
            runtime
                .block_on(store.execute(&second.plan_id, request.clone(), Some(&credential("one"))))
                .unwrap_err()
                .code,
            "invalid_response"
        );

        let third = store
            .plan(request.clone(), Some(&credential("one")))
            .unwrap();
        assert_eq!(
            runtime
                .block_on(store.execute(&third.plan_id, request, Some(&credential("two"))))
                .unwrap_err()
                .code,
            "auth"
        );
    }

    #[test]
    fn consumed_execution_rechecks_expiry_after_credential_preparation() {
        let store = AiConnectionStore::new().unwrap();
        let request = external_request(AiConnectionOperation::Probe, "m");
        let token = credential("fixture");
        let plan = store.plan(request.clone(), Some(&token)).unwrap();
        let mut execution = store.take_execution(&plan.plan_id).unwrap();
        execution.stored.expires_at = 0;
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        assert_eq!(
            runtime
                .block_on(store.execute_prepared(execution, request, Some(&token)))
                .unwrap_err()
                .code,
            "invalid_response"
        );
        assert!(store.take_execution(&plan.plan_id).is_err());
    }

    #[test]
    fn rejects_hosted_local_endpoint_and_any_ollama_credential() {
        let store = AiConnectionStore::new().unwrap();
        let request = AiConnectionRequest {
            operation: AiConnectionOperation::Models,
            provider: AiProviderKind::OpenaiCompatible,
            endpoint: "https://localhost:11434/v1".to_string(),
            model: String::new(),
        };
        assert_eq!(
            store
                .plan(request, Some(&credential("x")))
                .unwrap_err()
                .code,
            "ai_endpoint_policy_rejected"
        );
        let request = local_request(AiConnectionOperation::Models, "", 11434);
        assert_eq!(
            store
                .plan(request, Some(&credential("x")))
                .unwrap_err()
                .code,
            "invalid_response"
        );
    }

    #[test]
    fn lists_models_on_the_exact_path_without_local_authorization() {
        let (port, received) = fixture(|stream, _| {
            json_response(stream, "200 OK", r#"{"data":[{"id":"one"}]}"#);
        });
        let store = AiConnectionStore::new().unwrap();
        let request = local_request(AiConnectionOperation::Models, "", port);
        let plan = store.plan(request.clone(), None).unwrap();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let result = runtime
            .block_on(store.execute(&plan.plan_id, request, None))
            .unwrap();
        assert_eq!(result.models, vec!["one"]);
        let request = received.recv_timeout(Duration::from_secs(2)).unwrap();
        assert!(request.starts_with("GET /v1/models HTTP/1.1\r\n"));
        assert!(!request.to_ascii_lowercase().contains("authorization:"));
    }

    #[test]
    fn rejects_redirects_oversized_bodies_malformed_json_and_http_states() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        for (status, expected) in [
            ("401 Unauthorized", "auth"),
            ("403 Forbidden", "denied"),
            ("429 Too Many Requests", "rate_limit"),
            ("404 Not Found", "unsupported"),
            ("500 Internal Server Error", "network"),
        ] {
            let (port, _) = fixture(move |stream, _| json_response(stream, status, "{}"));
            let store = AiConnectionStore::new().unwrap();
            let request = local_request(AiConnectionOperation::Models, "", port);
            let plan = store.plan(request.clone(), None).unwrap();
            assert_eq!(
                runtime
                    .block_on(store.execute(&plan.plan_id, request, None))
                    .unwrap_err()
                    .code,
                expected
            );
        }
        let (port, _) = fixture(|mut stream, _| {
            write!(stream, "HTTP/1.1 302 Found\r\nlocation: /other\r\ncontent-length: 0\r\nconnection: close\r\n\r\n").unwrap();
        });
        let store = AiConnectionStore::new().unwrap();
        let request = local_request(AiConnectionOperation::Models, "", port);
        let plan = store.plan(request.clone(), None).unwrap();
        assert_eq!(
            runtime
                .block_on(store.execute(&plan.plan_id, request, None))
                .unwrap_err()
                .code,
            "unsupported"
        );

        let (port, _) = fixture(|mut stream, _| {
            write!(
                stream,
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\nconnection: close\r\n\r\n"
            )
            .unwrap();
            stream
                .write_all(&vec![b'x'; MAX_RESPONSE_BYTES + 1])
                .unwrap();
        });
        let store = AiConnectionStore::new().unwrap();
        let request = local_request(AiConnectionOperation::Models, "", port);
        let plan = store.plan(request.clone(), None).unwrap();
        assert_eq!(
            runtime
                .block_on(store.execute(&plan.plan_id, request, None))
                .unwrap_err()
                .code,
            "too_large"
        );

        let (port, _) = fixture(|stream, _| json_response(stream, "200 OK", "not-json"));
        let store = AiConnectionStore::new().unwrap();
        let request = local_request(AiConnectionOperation::Models, "", port);
        let plan = store.plan(request.clone(), None).unwrap();
        assert_eq!(
            runtime
                .block_on(store.execute(&plan.plan_id, request, None))
                .unwrap_err()
                .code,
            "invalid_response"
        );
    }

    #[test]
    fn bounds_model_results_and_reports_partial_pagination() {
        let data = (0..205)
            .map(|index| serde_json::json!({"id": format!("model-{index}")}))
            .collect::<Vec<_>>();
        let body = serde_json::json!({"data": data, "has_more": true}).to_string();
        let (port, _) = fixture(move |stream, _| json_response(stream, "200 OK", &body));
        let store = AiConnectionStore::new().unwrap();
        let request = local_request(AiConnectionOperation::Models, "", port);
        let plan = store.plan(request.clone(), None).unwrap();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let result = runtime
            .block_on(store.execute(&plan.plan_id, request, None))
            .unwrap();
        assert_eq!(result.models.len(), MAX_MODELS);
        assert_eq!(result.warnings.len(), 1);
        assert_eq!(
            parse_models(br#"{"data":[{"id":"bad\n"}]}"#)
                .unwrap_err()
                .code,
            "invalid_response"
        );
    }

    #[test]
    fn sends_only_the_fixed_probe_payload_and_requires_textual_content() {
        let (port, received) = fixture(|stream, _| {
            json_response(
                stream,
                "200 OK",
                r#"{"choices":[{"message":{"content":"OK"}}]}"#,
            );
        });
        let store = AiConnectionStore::new().unwrap();
        let request = local_request(AiConnectionOperation::Probe, "tiny-model", port);
        let plan = store.plan(request.clone(), None).unwrap();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let result = runtime
            .block_on(store.execute(&plan.plan_id, request, None))
            .unwrap();
        assert_eq!(result.status, AiConnectionStatus::ProbeSucceeded);
        let received = received.recv_timeout(Duration::from_secs(2)).unwrap();
        let body = received.split("\r\n\r\n").nth(1).unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(body).unwrap(),
            serde_json::json!({
                "model": "tiny-model",
                "messages": [{"role": "user", "content": "Reply with OK."}],
                "max_tokens": 8,
                "stream": false
            })
        );
        assert!(!body.to_ascii_lowercase().contains("article"));
        assert_eq!(
            validate_probe_response(br#"{"choices":[{"message":{"content":" "}}]}"#)
                .unwrap_err()
                .code,
            "invalid_response"
        );
    }

    #[test]
    fn plan_capacity_is_bounded() {
        let store = AiConnectionStore::new().unwrap();
        let request = external_request(AiConnectionOperation::Models, "");
        let token = credential("one");
        let mut first = None;
        for _ in 0..=MAX_PLANS {
            let plan = store.plan(request.clone(), Some(&token)).unwrap();
            first.get_or_insert(plan.plan_id);
        }
        let state = store.state.lock().unwrap();
        assert_eq!(state.plans.len(), MAX_PLANS);
        assert!(!state.plans.contains_key(first.as_deref().unwrap()));
    }
}
