//! Authenticated, loopback-only bridge for the browser capture extension.
//!
//! This module deliberately keeps persistence outside the HTTP listener.  Callers provide a
//! [`BrowserCaptureSink`], so the bridge can validate and minimise untrusted extension input
//! before any application storage code sees it.

use super::browser_protocol::BrowserProtocol;
use super::error::{CommandError, CommandResult};
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fs::File;
use std::io::{ErrorKind, Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration as StdDuration;
use time::format_description::well_known::Rfc3339;
use time::{Duration, OffsetDateTime};
use url::Url;
use uuid::Uuid;

const LOOPBACK_ENDPOINT: &str = "http://127.0.0.1:17843";
const MAXIMUM_HEADERS_BYTES: usize = 16 * 1024;
const MAXIMUM_IMPORT_TEXT_BYTES: usize = 5 * 1024 * 1024;
const MAXIMUM_ARCHIVE_BYTES: usize = 24 * 1024 * 1024;
// A 24 MiB binary archive needs 32 MiB as unwrapped base64.
const MAXIMUM_ARCHIVE_BASE64_BYTES: usize = MAXIMUM_ARCHIVE_BYTES.div_ceil(3) * 4;
const MAXIMUM_BROWSER_FOLDERS: usize = 128;
const TOKEN_LIFETIME_HOURS: i64 = 24;
const SOCKET_TIMEOUT: StdDuration = StdDuration::from_secs(5);

/// A cleaned browser capture. Raw page HTML is never retained; an optional validated archive is.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserCapture {
    pub operation_id: String,
    pub folder_id: Option<String>,
    pub new_folder_name: Option<String>,
    pub duplicate_resolution: Option<BrowserCaptureDuplicateResolution>,
    pub source_url: String,
    pub title: String,
    pub authors: Vec<String>,
    pub language: Option<String>,
    pub summary: String,
    pub tags: Vec<String>,
    pub captured_at: String,
    pub content_text: String,
    pub capture_mode: String,
    pub allows_local_semantic_index: bool,
    pub allows_remote_ai_use: bool,
    /// A validated, decoded full-page archive. It is intentionally excluded from receipts.
    #[serde(skip)]
    pub archive: Option<BrowserCaptureArchive>,
}

/// The extension's explicit choice for an incoming capture that conflicts with an existing item.
/// This is deliberately an enum rather than free text so storage never has to interpret browser
/// supplied policy strings.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum BrowserCaptureDuplicateResolution {
    SaveNewVersion,
    MoveOnly,
    KeepCopy,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BrowserCaptureArchive {
    pub format: String,
    pub bytes: Vec<u8>,
    pub embedded_resource_count: Option<u32>,
    pub missing_resource_count: Option<u32>,
    pub was_truncated: Option<bool>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserCaptureFolder {
    pub id: String,
    pub name: String,
}

/// The existing item that requires a browser-side duplicate-resolution choice.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserCaptureConflict {
    #[serde(rename = "documentID")]
    pub document_id: String,
    pub title: String,
    pub folder: Option<BrowserCaptureFolder>,
    pub file_size_bytes: u64,
    /// RFC 3339 timestamp supplied by the storage implementation.
    pub updated_at: String,
    pub incoming_has_changes: bool,
}

/// Optional storage-specific data used to complete an extension-compatible receipt.
#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserCaptureSinkReceipt {
    pub inserted_count: Option<u32>,
    pub updated_count: Option<u32>,
    pub skipped_count: Option<u32>,
    pub action: Option<String>,
    pub document_id: Option<String>,
    /// Storage's final title (for example, a duplicate copy renamed by the store).
    pub title: Option<String>,
    pub folder: Option<BrowserCaptureFolder>,
    pub file_size_bytes: Option<u64>,
    pub archive_type: Option<String>,
    pub index_status: Option<String>,
    /// The permissions that were actually persisted, which can be narrower than requested.
    pub allows_local_semantic_index: Option<bool>,
    pub allows_remote_ai_use: Option<bool>,
    /// Storage's original RFC 3339 save timestamp, retained for idempotent replays.
    pub saved_at: Option<String>,
    pub replayed: Option<bool>,
    /// When set, no import occurred. The bridge returns this conflict verbatim enough for the
    /// extension to ask the user for one of [`BrowserCaptureDuplicateResolution`].
    pub conflict: Option<BrowserCaptureConflict>,
}

/// Receives a fully validated and minimised capture.  Implementations own all persistence.
pub trait BrowserCaptureSink: Send + Sync {
    /// Returns only folders that are safe to expose to the paired extension.
    fn list_folders(&self) -> CommandResult<Vec<BrowserCaptureFolder>> {
        Ok(Vec::new())
    }

    /// Requests that the exact existing document be revealed in the desktop library.
    /// `Ok(false)` means the document does not exist (or cannot be opened); the default keeps
    /// lightweight sinks and tests safe by exposing no documents.
    fn request_open(&self, _document_id: &str) -> CommandResult<bool> {
        Ok(false)
    }

    fn accept_capture(&self, capture: BrowserCapture) -> CommandResult<BrowserCaptureSinkReceipt>;
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserCaptureStatus {
    pub running: bool,
    pub endpoint: String,
    /// Pairing token.  This is returned only by the in-process API, never by HTTP status.
    pub connection_token: String,
    /// Unix epoch seconds for UI countdowns. HTTP folder responses use RFC 3339 instead.
    pub token_expires_at: i64,
    pub allowed_origins: Vec<String>,
    pub maximum_input_bytes: u64,
    pub summary: String,
    pub warning: Option<String>,
}

#[derive(Clone)]
struct TokenState {
    value: String,
    expires_at: OffsetDateTime,
}

struct SharedState {
    protocol: BrowserProtocol,
    token: Mutex<TokenState>,
    sink: Arc<dyn BrowserCaptureSink>,
    running: Arc<AtomicBool>,
}

/// Owns the loopback listener.  Dropping it signals the worker and joins it.
pub struct BrowserCaptureService {
    shared: Arc<SharedState>,
    stop: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}

impl BrowserCaptureService {
    pub fn start(sink: Arc<dyn BrowserCaptureSink>) -> CommandResult<Self> {
        let protocol = BrowserProtocol::load_embedded().map_err(|_| {
            CommandError::new("browser-protocol", "Browser bridge protocol is invalid")
        })?;
        let listener = TcpListener::bind("127.0.0.1:17843").map_err(|error| {
            CommandError::io(
                "browser-bridge-bind",
                "Unable to bind browser bridge",
                error,
            )
        })?;
        listener.set_nonblocking(true).map_err(|error| {
            CommandError::io(
                "browser-bridge-listen",
                "Unable to configure browser bridge",
                error,
            )
        })?;

        let running = Arc::new(AtomicBool::new(true));
        let stop = Arc::new(AtomicBool::new(false));
        let shared = Arc::new(SharedState {
            protocol,
            token: Mutex::new(new_token_state()?),
            sink,
            running: Arc::clone(&running),
        });
        let worker_shared = Arc::clone(&shared);
        let worker_stop = Arc::clone(&stop);
        let worker = thread::Builder::new()
            .name("repopress-browser-capture".to_string())
            .spawn(move || run_listener(listener, worker_shared, worker_stop, running))
            .map_err(|error| {
                CommandError::io(
                    "browser-bridge-thread",
                    "Unable to start browser bridge",
                    error,
                )
            })?;

        Ok(Self {
            shared,
            stop,
            worker: Some(worker),
        })
    }

    pub fn status(&self) -> BrowserCaptureStatus {
        status_from_shared(&self.shared)
    }

    pub fn rotate_token(&self) -> CommandResult<BrowserCaptureStatus> {
        let replacement = new_token_state()?;
        let mut token = self.shared.token.lock().map_err(|_| {
            CommandError::new(
                "browser-bridge-state",
                "Browser bridge state is unavailable",
            )
        })?;
        *token = replacement;
        drop(token);
        Ok(self.status())
    }
}

impl Drop for BrowserCaptureService {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

fn run_listener(
    listener: TcpListener,
    shared: Arc<SharedState>,
    stop: Arc<AtomicBool>,
    running: Arc<AtomicBool>,
) {
    while !stop.load(Ordering::Acquire) {
        match listener.accept() {
            Ok((stream, address)) if address.ip().is_loopback() && address.is_ipv4() => {
                let _ = handle_connection(stream, &shared);
            }
            Ok((stream, _)) => {
                let _ = stream.shutdown(Shutdown::Both);
            }
            Err(error) if error.kind() == ErrorKind::WouldBlock => {
                thread::sleep(StdDuration::from_millis(25))
            }
            Err(error) if error.kind() == ErrorKind::Interrupted => continue,
            Err(_) => thread::sleep(StdDuration::from_millis(100)),
        }
    }
    running.store(false, Ordering::Release);
}

fn status_from_shared(shared: &SharedState) -> BrowserCaptureStatus {
    let token = shared
        .token
        .lock()
        .ok()
        .map(|token| token.clone())
        .unwrap_or(TokenState {
            value: String::new(),
            expires_at: OffsetDateTime::UNIX_EPOCH,
        });
    let snapshot = shared.protocol.snapshot();
    BrowserCaptureStatus {
        running: shared.running.load(Ordering::Acquire),
        endpoint: LOOPBACK_ENDPOINT.to_string(),
        connection_token: token.value,
        token_expires_at: token.expires_at.unix_timestamp(),
        allowed_origins: public_allowed_origins(&snapshot.allowed_origins),
        maximum_input_bytes: snapshot.maximum_input_bytes,
        summary: if shared.running.load(Ordering::Acquire) {
            "Browser capture bridge is ready for authenticated extension requests".to_string()
        } else {
            "Browser capture bridge is stopped".to_string()
        },
        warning: (!shared.running.load(Ordering::Acquire)).then(|| {
            "Browser capture is unavailable until the desktop bridge is restarted".to_string()
        }),
    }
}

fn public_allowed_origins(origins: &[String]) -> Vec<String> {
    let mut values: Vec<String> = origins
        .iter()
        .filter(|origin| origin.starts_with("chrome-extension://"))
        .cloned()
        .collect();
    // Firefox assigns a UUID at install time, so it cannot be enumerated from the manifest.
    values.push("moz-extension://<canonical-runtime-uuid>".to_string());
    values
}

fn new_token_state() -> CommandResult<TokenState> {
    Ok(TokenState {
        value: random_token()?,
        expires_at: OffsetDateTime::now_utc() + Duration::hours(TOKEN_LIFETIME_HOURS),
    })
}

fn random_token() -> CommandResult<String> {
    let mut bytes = [0u8; 32];
    File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(&mut bytes))
        .map_err(|error| {
            CommandError::io(
                "browser-token",
                "Unable to generate browser pairing token",
                error,
            )
        })?;
    let mut token = String::with_capacity(64);
    for byte in bytes {
        use std::fmt::Write as _;
        let _ = write!(token, "{byte:02x}");
    }
    Ok(token)
}

fn format_time(value: OffsetDateTime) -> String {
    value
        .format(&Rfc3339)
        .unwrap_or_else(|_| value.unix_timestamp().to_string())
}

fn handle_connection(mut stream: TcpStream, shared: &SharedState) -> std::io::Result<()> {
    let _ = stream.set_read_timeout(Some(SOCKET_TIMEOUT));
    let _ = stream.set_write_timeout(Some(SOCKET_TIMEOUT));
    let response = match read_request(
        &mut stream,
        shared.protocol.snapshot().maximum_input_bytes as usize,
    ) {
        Ok(request) => handle_request(&request, shared),
        Err(error) => error_response(error.status, error.code),
    };
    stream.write_all(&response.to_bytes())?;
    let _ = stream.flush();
    let _ = stream.shutdown(Shutdown::Both);
    Ok(())
}

#[derive(Debug)]
struct HttpRequest {
    method: String,
    path: String,
    headers: BTreeMap<String, String>,
    body: Vec<u8>,
}

#[derive(Debug)]
struct RequestError {
    status: u16,
    code: &'static str,
}

fn request_error(status: u16, code: &'static str) -> RequestError {
    RequestError { status, code }
}

fn read_request(
    stream: &mut TcpStream,
    maximum_body_bytes: usize,
) -> Result<HttpRequest, RequestError> {
    let mut bytes = Vec::with_capacity(1024);
    let header_end = loop {
        if bytes.len() > MAXIMUM_HEADERS_BYTES {
            return Err(request_error(431, "headers-too-large"));
        }
        let mut chunk = [0u8; 2048];
        let read = stream
            .read(&mut chunk)
            .map_err(|_| request_error(408, "request-timeout"))?;
        if read == 0 {
            return Err(request_error(400, "malformed-request"));
        }
        bytes.extend_from_slice(&chunk[..read]);
        if let Some(position) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
            break position + 4;
        }
    };
    if header_end > MAXIMUM_HEADERS_BYTES {
        return Err(request_error(431, "headers-too-large"));
    }
    let header_text = std::str::from_utf8(&bytes[..header_end - 4])
        .map_err(|_| request_error(400, "malformed-request"))?;
    let mut lines = header_text.split("\r\n");
    let request_line = lines
        .next()
        .ok_or_else(|| request_error(400, "malformed-request"))?;
    let mut parts = request_line.split_ascii_whitespace();
    let method = parts
        .next()
        .ok_or_else(|| request_error(400, "malformed-request"))?;
    let path = parts
        .next()
        .ok_or_else(|| request_error(400, "malformed-request"))?;
    let version = parts
        .next()
        .ok_or_else(|| request_error(400, "malformed-request"))?;
    if parts.next().is_some()
        || !matches!(method, "GET" | "POST" | "OPTIONS")
        || version != "HTTP/1.1"
        || !path.starts_with('/')
        || path.contains('?')
        || path.contains('#')
    {
        return Err(request_error(400, "malformed-request"));
    }

    let mut headers = BTreeMap::new();
    for line in lines {
        let (name, value) = line
            .split_once(':')
            .ok_or_else(|| request_error(400, "malformed-header"))?;
        if name.is_empty()
            || !name
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
            || value
                .bytes()
                .any(|byte| byte == 0 || byte == b'\r' || byte == b'\n')
        {
            return Err(request_error(400, "malformed-header"));
        }
        let name = name.to_ascii_lowercase();
        let value = value.trim().to_string();
        if headers.insert(name, value).is_some() {
            return Err(request_error(400, "duplicate-header"));
        }
    }
    if headers.contains_key("transfer-encoding") {
        return Err(request_error(400, "chunked-not-supported"));
    }
    if !matches!(
        headers.get("host").map(String::as_str),
        Some("127.0.0.1") | Some("127.0.0.1:17843")
    ) {
        return Err(request_error(400, "invalid-host"));
    }
    let content_length = match headers.get("content-length") {
        Some(value) if !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit()) => {
            value
                .parse::<usize>()
                .map_err(|_| request_error(400, "invalid-content-length"))?
        }
        Some(_) => return Err(request_error(400, "invalid-content-length")),
        None if method == "POST" => return Err(request_error(411, "content-length-required")),
        None => 0,
    };
    if content_length > maximum_body_bytes {
        return Err(request_error(413, "payload-too-large"));
    }
    if method != "POST" && content_length != 0 {
        return Err(request_error(400, "unexpected-request-data"));
    }
    let mut body = bytes[header_end..].to_vec();
    if body.len() > content_length {
        return Err(request_error(400, "unexpected-request-data"));
    }
    while body.len() < content_length {
        let remaining = content_length - body.len();
        let mut chunk = [0u8; 8192];
        let read_size = remaining.min(chunk.len());
        let read = stream
            .read(&mut chunk[..read_size])
            .map_err(|_| request_error(408, "request-timeout"))?;
        if read == 0 {
            return Err(request_error(400, "incomplete-body"));
        }
        body.extend_from_slice(&chunk[..read]);
    }
    Ok(HttpRequest {
        method: method.to_string(),
        path: path.to_string(),
        headers,
        body,
    })
}

#[derive(Debug)]
struct HttpResponse {
    status: u16,
    headers: Vec<(String, String)>,
    body: Value,
}

impl HttpResponse {
    fn to_bytes(&self) -> Vec<u8> {
        let body = serde_json::to_vec(&self.body)
            .unwrap_or_else(|_| b"{\"code\":\"response-error\"}".to_vec());
        let reason = match self.status {
            200 => "OK",
            201 => "Created",
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            408 => "Request Timeout",
            409 => "Conflict",
            411 => "Length Required",
            413 => "Payload Too Large",
            415 => "Unsupported Media Type",
            422 => "Unprocessable Content",
            431 => "Request Header Fields Too Large",
            500 => "Internal Server Error",
            501 => "Not Implemented",
            _ => "Error",
        };
        let mut response = format!(
            "HTTP/1.1 {} {}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\nCache-Control: no-store\r\n",
            self.status, reason, body.len()
        );
        for (name, value) in &self.headers {
            response.push_str(name);
            response.push_str(": ");
            response.push_str(value);
            response.push_str("\r\n");
        }
        response.push_str("\r\n");
        let mut bytes = response.into_bytes();
        bytes.extend_from_slice(&body);
        bytes
    }
}

fn error_response(status: u16, code: &'static str) -> HttpResponse {
    HttpResponse {
        status,
        headers: Vec::new(),
        body: json!({ "code": code, "error": "Browser bridge request was rejected" }),
    }
}

fn handle_request(request: &HttpRequest, shared: &SharedState) -> HttpResponse {
    if request.method == "OPTIONS" {
        return handle_preflight(request, &shared.protocol);
    }
    let origin = match request.headers.get("origin") {
        Some(value) if is_allowed_origin(value, &shared.protocol) => value,
        _ => return error_response(403, "origin-not-allowed"),
    };
    let cors = vec![
        ("Access-Control-Allow-Origin".to_string(), origin.clone()),
        ("Vary".to_string(), "Origin".to_string()),
    ];
    if !is_authorized(request, shared) {
        return HttpResponse {
            status: 401,
            headers: cors,
            body: json!({ "code": "invalid-token", "error": "Browser bridge request was rejected" }),
        };
    }
    if request
        .headers
        .get("x-repopress-protocol")
        .map(String::as_str)
        != Some("1")
    {
        return HttpResponse {
            status: 403,
            headers: cors,
            body: json!({ "code": "protocol-required", "error": "Browser bridge request was rejected" }),
        };
    }
    match (request.path.as_str(), request.method.as_str()) {
        ("/v1/folders", "GET") => match shared.sink.list_folders() {
            Ok(folders) => match folder_payload(&folders) {
                Ok(folders) => success(
                    cors,
                    json!({ "folders": folders, "tokenExpiresAt": token_expiry(shared) }),
                ),
                Err(()) => response_with(cors, 500, "folders-unavailable"),
            },
            Err(_) => response_with(cors, 500, "folders-unavailable"),
        },
        ("/v1/status", "GET") => success(cors, status_payload(shared)),
        ("/v1/suggestions", "POST") => {
            if !is_json(request) {
                return response_with(cors, 415, "json-required");
            }
            if serde_json::from_slice::<Value>(&request.body).is_err() {
                return response_with(cors, 400, "invalid-json");
            }
            match shared.sink.list_folders() {
                Ok(folders) => match folder_payload(&folders) {
                    Ok(folders) => success(cors, json!({ "folders": folders, "tags": [] })),
                    Err(()) => response_with(cors, 500, "suggestions-unavailable"),
                },
                Err(_) => response_with(cors, 500, "suggestions-unavailable"),
            }
        }
        ("/v1/open", "POST") => {
            if !is_json(request) {
                return response_with(cors, 415, "json-required");
            }
            match parse_open_request(&request.body) {
                Ok(document_id) => match shared.sink.request_open(&document_id) {
                    Ok(true) => success(cors, json!({ "documentID": document_id, "opened": true })),
                    Ok(false) => response_with(cors, 404, "document-not-found"),
                    Err(error) => sink_open_error(cors, &error),
                },
                Err(error) => response_with(cors, error.status, error.code),
            }
        }
        ("/v1/import", "POST") => {
            if !is_json(request) {
                return response_with(cors, 415, "json-required");
            }
            match parse_capture(&request.body) {
                Ok(capture) => match shared.sink.accept_capture(capture.clone()) {
                    Ok(sink_receipt) => match receipt_json(&capture, sink_receipt) {
                        Ok(receipt) => success(cors, receipt),
                        Err(()) => response_with(cors, 500, "capture-unavailable"),
                    },
                    Err(error) => sink_capture_error(cors, &error),
                },
                Err(error) => HttpResponse {
                    status: error.status,
                    headers: cors,
                    body: json!({ "code": error.code, "error": "Browser capture was rejected" }),
                },
            }
        }
        ("/v1/folders" | "/v1/import" | "/v1/status" | "/v1/suggestions" | "/v1/open", _) => {
            HttpResponse {
                status: 405,
                headers: cors,
                body: json!({ "code": "method-not-allowed", "error": "Browser bridge request was rejected" }),
            }
        }
        _ => HttpResponse {
            status: 404,
            headers: cors,
            body: json!({ "code": "route-not-found", "error": "Browser bridge request was rejected" }),
        },
    }
}

/// Serialize the narrowly scoped folder projection and fail closed if a sink violates the
/// bridge contract. In particular, this avoids turning storage's optional/internal fields into
/// browser-visible metadata.
fn folder_payload(folders: &[BrowserCaptureFolder]) -> Result<Value, ()> {
    if folders.len() > MAXIMUM_BROWSER_FOLDERS {
        return Err(());
    }
    let mut projected = Vec::with_capacity(folders.len());
    for folder in folders {
        if !is_canonical_uuid(&folder.id)
            || clean_text(&folder.name).is_empty()
            || folder.name.chars().count() > 120
        {
            return Err(());
        }
        projected.push(json!({ "id": folder.id, "name": folder.name }));
    }
    Ok(Value::Array(projected))
}

fn parse_open_request(body: &[u8]) -> Result<String, RequestError> {
    let value: Value =
        serde_json::from_slice(body).map_err(|_| request_error(400, "invalid-json"))?;
    let object = value
        .as_object()
        .ok_or_else(|| request_error(400, "invalid-open-request"))?;
    // `/v1/open` is intentionally a one-field request. Reject unknown fields rather than
    // silently accepting an accidental broader capability in a future extension build.
    if object.len() != 1 || !object.contains_key("documentID") {
        return Err(request_error(400, "invalid-open-request"));
    }
    let document_id = object
        .get("documentID")
        .and_then(Value::as_str)
        .ok_or_else(|| request_error(400, "invalid-document-id"))?;
    if !is_canonical_uuid(document_id) {
        return Err(request_error(400, "invalid-document-id"));
    }
    Ok(document_id.to_string())
}

fn is_canonical_uuid(value: &str) -> bool {
    Uuid::parse_str(value)
        .ok()
        .is_some_and(|parsed| parsed.hyphenated().to_string() == value)
}

fn sink_open_error(headers: Vec<(String, String)>, error: &CommandError) -> HttpResponse {
    // Storage errors never cross the extension boundary. These known result codes indicate a
    // normal absent item; every other failure is intentionally collapsed to a generic 5xx.
    if matches!(
        error.code.as_str(),
        "document-not-found"
            | "knowledge-item-not-found"
            | "knowledge_item_not_found"
            | "not-found"
    ) {
        response_with(headers, 404, "document-not-found")
    } else {
        response_with(headers, 500, "open-unavailable")
    }
}

fn sink_capture_error(headers: Vec<(String, String)>, error: &CommandError) -> HttpResponse {
    // Only stable categories cross the bridge. Invalid/stale user choices are non-retryable;
    // storage and I/O failures remain retryable 5xx responses for the extension queue.
    match error.code.as_str() {
        "knowledge_operation_conflict" => response_with(headers, 409, "operation-conflict"),
        "knowledge_folder_not_found" => response_with(headers, 422, "folder-not-found"),
        "knowledge_folder_invalid"
        | "knowledge_folder_conflict"
        | "knowledge_folder_limit"
        | "knowledge_duplicate_resolution_invalid"
        | "knowledge_item_limit"
        | "knowledge_item_too_large"
        | "knowledge_size_limit"
        | "knowledge_archive_size_limit"
        | "knowledge_revision_limit" => response_with(headers, 422, "capture-rejected"),
        _ => response_with(headers, 500, "capture-unavailable"),
    }
}

fn success(headers: Vec<(String, String)>, body: Value) -> HttpResponse {
    HttpResponse {
        status: 200,
        headers,
        body,
    }
}
fn response_with(headers: Vec<(String, String)>, status: u16, code: &'static str) -> HttpResponse {
    HttpResponse {
        status,
        headers,
        body: json!({ "code": code, "error": "Browser bridge request was rejected" }),
    }
}
fn is_json(request: &HttpRequest) -> bool {
    request.headers.get("content-type").is_some_and(|value| {
        value
            .split(';')
            .next()
            .is_some_and(|mime| mime.trim().eq_ignore_ascii_case("application/json"))
    })
}

fn handle_preflight(request: &HttpRequest, protocol: &BrowserProtocol) -> HttpResponse {
    let Some(origin) = request.headers.get("origin") else {
        return error_response(403, "origin-not-allowed");
    };
    if !is_allowed_origin(origin, protocol) {
        return error_response(403, "origin-not-allowed");
    }
    let requested_method = request
        .headers
        .get("access-control-request-method")
        .map(String::as_str);
    let requested_headers = request
        .headers
        .get("access-control-request-headers")
        .map(String::as_str)
        .unwrap_or("");
    let expected_method = match request.path.as_str() {
        "/v1/folders" | "/v1/status" => "GET",
        "/v1/import" | "/v1/suggestions" | "/v1/open" => "POST",
        _ => {
            return HttpResponse {
                status: 404,
                headers: Vec::new(),
                body: json!({ "code": "route-not-found", "error": "Browser bridge request was rejected" }),
            }
        }
    };
    let requested: Vec<String> = requested_headers
        .split(',')
        .map(|header| header.trim().to_ascii_lowercase())
        .filter(|header| !header.is_empty())
        .collect();
    if requested_method != Some(expected_method)
        || requested.iter().any(|header| {
            !matches!(
                header.as_str(),
                "authorization" | "content-type" | "x-repopress-protocol"
            )
        })
    {
        return HttpResponse {
            status: 403,
            headers: Vec::new(),
            body: json!({ "code": "preflight-rejected", "error": "Browser bridge request was rejected" }),
        };
    }
    HttpResponse {
        status: 200,
        headers: vec![
            ("Access-Control-Allow-Origin".to_string(), origin.clone()),
            (
                "Access-Control-Allow-Methods".to_string(),
                expected_method.to_string(),
            ),
            (
                "Access-Control-Allow-Headers".to_string(),
                "Authorization, Content-Type, X-RepoPress-Protocol".to_string(),
            ),
            ("Access-Control-Max-Age".to_string(), "600".to_string()),
            (
                "Vary".to_string(),
                "Origin, Access-Control-Request-Method, Access-Control-Request-Headers".to_string(),
            ),
        ],
        body: json!({}),
    }
}

fn is_allowed_origin(origin: &str, protocol: &BrowserProtocol) -> bool {
    if origin.is_empty() || origin.bytes().any(|byte| byte.is_ascii_control()) {
        return false;
    }
    let snapshot = protocol.snapshot();
    if snapshot
        .allowed_origins
        .iter()
        .any(|allowed| allowed == origin && allowed.starts_with("chrome-extension://"))
    {
        return true;
    }
    let Some(uuid) = origin.strip_prefix("moz-extension://") else {
        return false;
    };
    Uuid::parse_str(uuid)
        .ok()
        .is_some_and(|parsed| parsed.hyphenated().to_string() == uuid.to_ascii_lowercase())
        && uuid == uuid.to_ascii_lowercase()
}

fn is_authorized(request: &HttpRequest, shared: &SharedState) -> bool {
    let Some(token) = request
        .headers
        .get("authorization")
        .and_then(|value| value.strip_prefix("Bearer "))
    else {
        return false;
    };
    let Ok(current) = shared.token.lock() else {
        return false;
    };
    current.expires_at > OffsetDateTime::now_utc()
        && constant_time_eq(token.as_bytes(), current.value.as_bytes())
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    let mut difference = left.len() ^ right.len();
    let longest = left.len().max(right.len());
    for index in 0..longest {
        difference |= usize::from(*left.get(index).unwrap_or(&0) ^ *right.get(index).unwrap_or(&0));
    }
    difference == 0
}

fn token_expiry(shared: &SharedState) -> String {
    shared
        .token
        .lock()
        .map(|token| format_time(token.expires_at))
        .unwrap_or_default()
}

fn status_payload(shared: &SharedState) -> Value {
    let snapshot = shared.protocol.snapshot();
    json!({
        "payloadVersion": 6,
        "running": shared.running.load(Ordering::Acquire),
        "endpoint": LOOPBACK_ENDPOINT,
        "maximumInputBytes": snapshot.maximum_input_bytes,
        "tokenExpiresAt": token_expiry(shared),
        "importCapability": true,
    })
}

fn parse_capture(body: &[u8]) -> Result<BrowserCapture, RequestError> {
    let value: Value =
        serde_json::from_slice(body).map_err(|_| request_error(400, "invalid-json"))?;
    let envelope = value
        .as_object()
        .ok_or_else(|| request_error(400, "invalid-envelope"))?;
    let operation_id = required_string(envelope, "operationID", 36)?;
    if !is_canonical_uuid(&operation_id) {
        return Err(request_error(400, "invalid-operation-id"));
    }
    let folder_id = optional_folder_id(envelope.get("folderID"))?;
    let new_folder_name = optional_folder_name(envelope.get("newFolderName"))?;
    if folder_id.is_some() && new_folder_name.is_some() {
        return Err(request_error(400, "folder-selection-conflict"));
    }
    let duplicate_resolution = optional_duplicate_resolution(envelope.get("duplicateResolution"))?;
    let capture = envelope
        .get("capture")
        .and_then(Value::as_object)
        .ok_or_else(|| request_error(400, "invalid-capture"))?;
    if capture.get("schemaVersion").and_then(Value::as_u64) != Some(1) {
        return Err(request_error(400, "unsupported-capture-schema"));
    }
    let source_url = validated_source_url(required_string(capture, "sourceURL", 8192)?)?;
    let title = clean_required_characters(
        capture.get("title").and_then(Value::as_str).unwrap_or(""),
        300,
        "invalid-title",
    )?;
    let content_text = clean_required(
        capture
            .get("contentText")
            .and_then(Value::as_str)
            .unwrap_or(""),
        MAXIMUM_IMPORT_TEXT_BYTES,
        "invalid-content",
    )?;
    if content_text.len() > MAXIMUM_IMPORT_TEXT_BYTES {
        return Err(request_error(413, "content-too-large"));
    }
    let capture_mode = required_string(capture, "captureMode", 32)?;
    if !matches!(
        capture_mode.as_str(),
        "cleaned-article" | "full-page" | "selection" | "link-only"
    ) {
        return Err(request_error(400, "invalid-capture-mode"));
    }
    let captured_at = required_string(capture, "capturedAt", 64)?;
    if OffsetDateTime::parse(&captured_at, &Rfc3339).is_err() {
        return Err(request_error(400, "invalid-captured-at"));
    }
    let archive = parse_archive(capture, &capture_mode)?;
    Ok(BrowserCapture {
        // Preserve the caller's validated operation ID so the receipt is an exact echo.
        operation_id,
        folder_id,
        new_folder_name,
        duplicate_resolution,
        source_url,
        title,
        authors: clean_list(capture.get("authors"), 30, 120)?,
        language: optional_clean(capture.get("language").and_then(Value::as_str), 40),
        summary: optional_clean(capture.get("summary").and_then(Value::as_str), 20_000)
            .unwrap_or_default(),
        tags: clean_list(capture.get("tags"), 50, 80)?,
        captured_at,
        content_text,
        capture_mode,
        allows_local_semantic_index: capture
            .get("allowsLocalSemanticIndex")
            .and_then(Value::as_bool)
            .unwrap_or(true),
        allows_remote_ai_use: capture
            .get("allowsRemoteAIUse")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        archive,
    })
}

fn optional_folder_id(value: Option<&Value>) -> Result<Option<String>, RequestError> {
    let Some(value) = value.filter(|value| !value.is_null()) else {
        return Ok(None);
    };
    let value = value
        .as_str()
        .ok_or_else(|| request_error(400, "invalid-folder-id"))?;
    if !is_canonical_uuid(value) {
        return Err(request_error(400, "invalid-folder-id"));
    }
    Ok(Some(value.to_string()))
}

fn optional_folder_name(value: Option<&Value>) -> Result<Option<String>, RequestError> {
    let Some(value) = value.filter(|value| !value.is_null()) else {
        return Ok(None);
    };
    let value = value
        .as_str()
        .ok_or_else(|| request_error(400, "invalid-folder-name"))?;
    let value = clean_text(value);
    if value.is_empty() || value.chars().count() > 120 {
        return Err(request_error(400, "invalid-folder-name"));
    }
    Ok(Some(value))
}

fn optional_duplicate_resolution(
    value: Option<&Value>,
) -> Result<Option<BrowserCaptureDuplicateResolution>, RequestError> {
    let Some(value) = value.filter(|value| !value.is_null()) else {
        return Ok(None);
    };
    match value.as_str() {
        Some("save-new-version") => Ok(Some(BrowserCaptureDuplicateResolution::SaveNewVersion)),
        Some("move-only") => Ok(Some(BrowserCaptureDuplicateResolution::MoveOnly)),
        Some("keep-copy") => Ok(Some(BrowserCaptureDuplicateResolution::KeepCopy)),
        _ => Err(request_error(400, "invalid-duplicate-resolution")),
    }
}

fn parse_archive(
    capture: &serde_json::Map<String, Value>,
    capture_mode: &str,
) -> Result<Option<BrowserCaptureArchive>, RequestError> {
    let format = capture
        .get("archiveFormat")
        .filter(|value| !value.is_null());
    let data = capture.get("archiveData").filter(|value| !value.is_null());
    if format.is_none() && data.is_none() {
        return Ok(None);
    }
    let format = format
        .and_then(Value::as_str)
        .ok_or_else(|| request_error(400, "invalid-archive"))?;
    let data = data
        .and_then(Value::as_str)
        .ok_or_else(|| request_error(400, "invalid-archive"))?;
    if capture_mode != "full-page" || !matches!(format, "html" | "mhtml") {
        return Err(request_error(400, "invalid-archive"));
    }
    if data.is_empty() || data.len() > MAXIMUM_ARCHIVE_BASE64_BYTES {
        return Err(request_error(413, "archive-too-large"));
    }
    // Do not accept URL-safe or whitespace-tolerant variants: the wire format is canonical
    // standard base64, making the byte limit and digest unambiguous.
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data)
        .map_err(|_| request_error(400, "invalid-archive-base64"))?;
    if bytes.is_empty() {
        return Err(request_error(400, "invalid-archive"));
    }
    if bytes.len() > MAXIMUM_ARCHIVE_BYTES {
        return Err(request_error(413, "archive-too-large"));
    }
    let structurally_valid = match format {
        "html" => looks_like_html(&bytes),
        "mhtml" => looks_like_mhtml(&bytes),
        _ => false,
    };
    if !structurally_valid {
        return Err(request_error(400, "invalid-archive-format"));
    }
    let embedded_resource_count = optional_archive_count(capture, "archiveEmbeddedResourceCount")?;
    let missing_resource_count = optional_archive_count(capture, "archiveMissingResourceCount")?;
    let was_truncated = match capture
        .get("archiveWasTruncated")
        .filter(|value| !value.is_null())
    {
        Some(Value::Bool(value)) => Some(*value),
        Some(_) => return Err(request_error(400, "invalid-archive")),
        None => None,
    };
    Ok(Some(BrowserCaptureArchive {
        format: format.to_string(),
        bytes,
        embedded_resource_count,
        missing_resource_count,
        was_truncated,
    }))
}

fn optional_archive_count(
    capture: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<Option<u32>, RequestError> {
    match capture.get(key).filter(|value| !value.is_null()) {
        Some(value) => value
            .as_u64()
            .filter(|value| *value <= 100_000)
            .map(|value| value as u32)
            .ok_or_else(|| request_error(400, "invalid-archive"))
            .map(Some),
        None => Ok(None),
    }
}

fn looks_like_html(bytes: &[u8]) -> bool {
    let Ok(value) = std::str::from_utf8(bytes) else {
        return false;
    };
    let sample = value
        .trim_start_matches('\u{feff}')
        .chars()
        .take(16_384)
        .collect::<String>()
        .to_ascii_lowercase();
    sample.contains("<html") || sample.contains("<!doctype html")
}

fn looks_like_mhtml(bytes: &[u8]) -> bool {
    let sample = String::from_utf8_lossy(&bytes[..bytes.len().min(64 * 1024)]);
    let headers = sample
        .split_once("\r\n\r\n")
        .or_else(|| sample.split_once("\n\n"))
        .map(|(headers, _)| headers)
        .unwrap_or(&sample)
        .to_ascii_lowercase();
    headers
        .lines()
        .any(|line| line.trim() == "mime-version: 1.0")
        && headers.lines().any(|line| {
            line.trim_start()
                .starts_with("content-type: multipart/related")
        })
}

fn required_string(
    object: &serde_json::Map<String, Value>,
    key: &str,
    maximum_bytes: usize,
) -> Result<String, RequestError> {
    let value = object
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| request_error(400, "missing-required-field"))?;
    if value.is_empty()
        || value.len() > maximum_bytes
        || value.bytes().any(|byte| byte.is_ascii_control())
    {
        return Err(request_error(400, "invalid-required-field"));
    }
    Ok(value.to_string())
}

fn validated_source_url(value: String) -> Result<String, RequestError> {
    let mut url = Url::parse(&value).map_err(|_| request_error(400, "invalid-source-url"))?;
    if !matches!(url.scheme(), "http" | "https")
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err(request_error(400, "invalid-source-url"));
    }
    url.set_fragment(None);
    Ok(url.to_string())
}

fn clean_required(
    value: &str,
    maximum_bytes: usize,
    code: &'static str,
) -> Result<String, RequestError> {
    let value = clean_text(value);
    if value.is_empty() {
        return Err(request_error(400, code));
    }
    if value.len() > maximum_bytes {
        return Err(request_error(413, code));
    }
    Ok(value)
}

fn clean_required_characters(
    value: &str,
    maximum_characters: usize,
    code: &'static str,
) -> Result<String, RequestError> {
    let value = clean_text(value);
    if value.is_empty() {
        return Err(request_error(400, code));
    }
    if value.chars().count() > maximum_characters {
        return Err(request_error(400, code));
    }
    Ok(value)
}

fn optional_clean(value: Option<&str>, maximum_characters: usize) -> Option<String> {
    let value = clean_text(value?);
    if value.is_empty() {
        None
    } else {
        Some(truncate_characters(value, maximum_characters))
    }
}

fn clean_list(
    value: Option<&Value>,
    maximum_count: usize,
    maximum_characters: usize,
) -> Result<Vec<String>, RequestError> {
    let Some(value) = value else {
        return Ok(Vec::new());
    };
    let values = value
        .as_array()
        .ok_or_else(|| request_error(400, "invalid-list"))?;
    if values.len() > maximum_count {
        return Err(request_error(400, "list-too-large"));
    }
    let mut cleaned = Vec::with_capacity(values.len());
    for value in values {
        let value = value
            .as_str()
            .ok_or_else(|| request_error(400, "invalid-list"))?;
        let value = truncate_characters(clean_text(value), maximum_characters);
        if !value.is_empty() {
            cleaned.push(value);
        }
    }
    Ok(cleaned)
}

fn clean_text(value: &str) -> String {
    value
        .chars()
        .filter_map(|character| match character {
            '\r' => Some('\n'),
            '\n' | '\t' => Some(character),
            character if character.is_control() => None,
            character => Some(character),
        })
        .collect::<String>()
        .trim()
        .to_string()
}

fn truncate_characters(value: String, maximum: usize) -> String {
    if value.chars().count() <= maximum {
        value
    } else {
        value.chars().take(maximum).collect()
    }
}

fn receipt_json(capture: &BrowserCapture, receipt: BrowserCaptureSinkReceipt) -> Result<Value, ()> {
    if let Some(conflict) = receipt.conflict {
        if !is_valid_conflict(&conflict) {
            return Err(());
        }
        return Ok(json!({
            "operationID": capture.operation_id,
            "requiresDuplicateResolution": true,
            "conflict": conflict,
        }));
    }
    let inserted_count = receipt.inserted_count.unwrap_or(1);
    let updated_count = receipt.updated_count.unwrap_or(0);
    let skipped_count = receipt.skipped_count.unwrap_or(0);
    let action = receipt.action.unwrap_or_else(|| {
        if inserted_count > 0 {
            "inserted".to_string()
        } else if updated_count > 0 {
            "updated".to_string()
        } else {
            "existing".to_string()
        }
    });
    let document_id = receipt.document_id.ok_or(())?;
    let title = clean_required_characters(
        receipt.title.as_deref().unwrap_or(&capture.title),
        300,
        "invalid-receipt-title",
    )
    .map_err(|_| ())?;
    let saved_at = match receipt.saved_at {
        Some(saved_at) if OffsetDateTime::parse(&saved_at, &Rfc3339).is_ok() => saved_at,
        Some(_) => return Err(()),
        None => format_time(OffsetDateTime::now_utc()),
    };
    if !is_canonical_uuid(&document_id)
        || action.len() > 64
        || receipt
            .folder
            .as_ref()
            .is_some_and(|folder| folder_payload(std::slice::from_ref(folder)).is_err())
        || receipt
            .archive_type
            .as_ref()
            .is_some_and(|value| value.len() > 64)
        || receipt
            .index_status
            .as_ref()
            .is_some_and(|value| value.len() > 64)
    {
        return Err(());
    }
    Ok(json!({
        "operationID": capture.operation_id,
        "insertedCount": inserted_count,
        "updatedCount": updated_count,
        "skippedCount": skipped_count,
        "action": action,
        "documentID": document_id,
        "title": title,
        "sourceURL": capture.source_url,
        "folder": receipt.folder,
        "fileSizeBytes": receipt.file_size_bytes.unwrap_or(capture.content_text.len() as u64),
        "archiveType": receipt.archive_type.unwrap_or_else(|| "none".to_string()),
        "indexStatus": receipt.index_status.unwrap_or_else(|| if capture.allows_local_semantic_index { "ready".to_string() } else { "not-requested".to_string() }),
        "allowsLocalSemanticIndex": receipt.allows_local_semantic_index.unwrap_or(capture.allows_local_semantic_index),
        "allowsRemoteAIUse": receipt.allows_remote_ai_use.unwrap_or(false),
        "savedAt": saved_at,
        "replayed": receipt.replayed.unwrap_or(false),
        "requiresDuplicateResolution": false,
    }))
}

fn is_valid_conflict(conflict: &BrowserCaptureConflict) -> bool {
    is_canonical_uuid(&conflict.document_id)
        && !clean_text(&conflict.title).is_empty()
        && conflict.title.chars().count() <= 300
        && OffsetDateTime::parse(&conflict.updated_at, &Rfc3339).is_ok()
        && conflict
            .folder
            .as_ref()
            .is_none_or(|folder| folder_payload(std::slice::from_ref(folder)).is_ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TestSink;
    impl BrowserCaptureSink for TestSink {
        fn accept_capture(&self, _: BrowserCapture) -> CommandResult<BrowserCaptureSinkReceipt> {
            Ok(BrowserCaptureSinkReceipt {
                document_id: Some("550e8400-e29b-41d4-a716-446655440003".to_string()),
                ..BrowserCaptureSinkReceipt::default()
            })
        }
    }

    struct FolderOpenSink;
    impl BrowserCaptureSink for FolderOpenSink {
        fn list_folders(&self) -> CommandResult<Vec<BrowserCaptureFolder>> {
            Ok(vec![BrowserCaptureFolder {
                id: "550e8400-e29b-41d4-a716-446655440001".to_string(),
                name: "Research".to_string(),
            }])
        }

        fn request_open(&self, document_id: &str) -> CommandResult<bool> {
            Ok(document_id == "550e8400-e29b-41d4-a716-446655440002")
        }

        fn accept_capture(&self, _: BrowserCapture) -> CommandResult<BrowserCaptureSinkReceipt> {
            Ok(BrowserCaptureSinkReceipt {
                document_id: Some("550e8400-e29b-41d4-a716-446655440003".to_string()),
                ..BrowserCaptureSinkReceipt::default()
            })
        }
    }

    fn shared(token: &str) -> SharedState {
        shared_with_sink(token, Arc::new(TestSink))
    }

    fn shared_with_sink(token: &str, sink: Arc<dyn BrowserCaptureSink>) -> SharedState {
        SharedState {
            protocol: BrowserProtocol::load_embedded().unwrap(),
            token: Mutex::new(TokenState {
                value: token.to_string(),
                expires_at: OffsetDateTime::now_utc() + Duration::hours(1),
            }),
            sink,
            running: Arc::new(AtomicBool::new(true)),
        }
    }
    fn request(method: &str, path: &str, token: &str, origin: &str, body: Value) -> HttpRequest {
        HttpRequest {
            method: method.to_string(),
            path: path.to_string(),
            headers: BTreeMap::from([
                ("authorization".to_string(), format!("Bearer {token}")),
                ("origin".to_string(), origin.to_string()),
                ("x-repopress-protocol".to_string(), "1".to_string()),
                ("content-type".to_string(), "application/json".to_string()),
            ]),
            body: serde_json::to_vec(&body).unwrap(),
        }
    }

    fn parse_raw(raw: Vec<u8>, maximum_body_bytes: usize) -> Result<(), (u16, &'static str)> {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let worker = thread::spawn(move || {
            let (mut server, _) = listener.accept().unwrap();
            read_request(&mut server, maximum_body_bytes)
                .map(|_| ())
                .map_err(|error| (error.status, error.code))
        });
        let mut client = TcpStream::connect(address).unwrap();
        client.write_all(&raw).unwrap();
        client.shutdown(Shutdown::Write).unwrap();
        worker.join().unwrap()
    }
    fn valid_capture() -> Value {
        json!({
            "operationID": "550e8400-e29b-41d4-a716-446655440000", "folderID": null, "newFolderName": null,
            "capture": { "schemaVersion": 1, "sourceURL": "https://example.test/path#fragment", "title": "An example", "authors": ["Ada"], "language": "en", "summary": "Summary", "tags": ["test"], "capturedAt": "2026-01-01T00:00:00Z", "contentText": "Text\u{0000} with controls", "captureMode": "cleaned-article", "allowsLocalSemanticIndex": true, "allowsRemoteAIUse": false, "originalHTML": "<p>ignored</p>", "archiveData": null }
        })
    }

    #[test]
    fn rejects_bad_and_rotated_tokens_in_constant_time_path() {
        let state = shared("new-token");
        let origin = "chrome-extension://lnibkmfhfikfbkeehcjbiaalhkiankam";
        assert_eq!(
            handle_request(
                &request("POST", "/v1/import", "old-token", origin, valid_capture()),
                &state
            )
            .status,
            401
        );
        assert_eq!(
            handle_request(
                &request("POST", "/v1/import", "new-token", origin, valid_capture()),
                &state
            )
            .status,
            200
        );
    }

    #[test]
    fn rejects_expired_tokens() {
        let state = shared("token");
        state.token.lock().unwrap().expires_at = OffsetDateTime::now_utc() - Duration::seconds(1);
        let response = handle_request(
            &request(
                "POST",
                "/v1/import",
                "token",
                "chrome-extension://lnibkmfhfikfbkeehcjbiaalhkiankam",
                valid_capture(),
            ),
            &state,
        );
        assert_eq!(response.status, 401);
    }

    #[test]
    fn rejects_web_origins_and_wrong_protocol() {
        let state = shared("token");
        assert_eq!(
            handle_request(
                &request(
                    "POST",
                    "/v1/import",
                    "token",
                    "https://example.test",
                    valid_capture()
                ),
                &state
            )
            .status,
            403
        );
        let mut bad_protocol = request(
            "POST",
            "/v1/import",
            "token",
            "chrome-extension://lnibkmfhfikfbkeehcjbiaalhkiankam",
            valid_capture(),
        );
        bad_protocol
            .headers
            .insert("x-repopress-protocol".to_string(), "2".to_string());
        assert_eq!(handle_request(&bad_protocol, &state).status, 403);
    }

    #[test]
    fn only_accepts_canonical_firefox_runtime_origins() {
        let protocol = BrowserProtocol::load_embedded().unwrap();
        assert!(is_allowed_origin(
            "moz-extension://550e8400-e29b-41d4-a716-446655440000",
            &protocol
        ));
        assert!(!is_allowed_origin(
            "moz-extension://knowledge-capture@jinfang.local",
            &protocol
        ));
        assert!(!is_allowed_origin(
            "moz-extension://550e8400-e29b-41d4-a716-446655440000/path",
            &protocol
        ));
    }

    #[test]
    fn validates_capture_and_echoes_operation_id() {
        let state = shared("token");
        let response = handle_request(
            &request(
                "POST",
                "/v1/import",
                "token",
                "chrome-extension://lnibkmfhfikfbkeehcjbiaalhkiankam",
                valid_capture(),
            ),
            &state,
        );
        assert_eq!(response.status, 200);
        assert_eq!(
            response.body["operationID"],
            "550e8400-e29b-41d4-a716-446655440000"
        );
        let capture = parse_capture(&serde_json::to_vec(&valid_capture()).unwrap()).unwrap();
        assert!(!capture.content_text.contains('\0'));
        assert_eq!(capture.source_url, "https://example.test/path");
    }

    #[test]
    fn folders_and_suggestions_expose_only_the_sink_folder_projection() {
        let state = shared_with_sink("token", Arc::new(FolderOpenSink));
        let origin = "chrome-extension://lnibkmfhfikfbkeehcjbiaalhkiankam";
        let folders = handle_request(
            &request("GET", "/v1/folders", "token", origin, json!({})),
            &state,
        );
        assert_eq!(folders.status, 200);
        assert_eq!(
            folders.body["folders"],
            json!([{
                "id": "550e8400-e29b-41d4-a716-446655440001",
                "name": "Research"
            }])
        );
        assert!(folders.body["tokenExpiresAt"].as_str().is_some());

        let suggestions = handle_request(
            &request("POST", "/v1/suggestions", "token", origin, json!({})),
            &state,
        );
        assert_eq!(suggestions.status, 200);
        assert_eq!(suggestions.body["folders"], folders.body["folders"]);
        assert_eq!(suggestions.body["tags"], json!([]));
    }

    #[test]
    fn open_requires_an_authorized_exact_document_id() {
        let state = shared_with_sink("token", Arc::new(FolderOpenSink));
        let origin = "chrome-extension://lnibkmfhfikfbkeehcjbiaalhkiankam";
        let valid = json!({ "documentID": "550e8400-e29b-41d4-a716-446655440002" });
        let opened = handle_request(&request("POST", "/v1/open", "token", origin, valid), &state);
        assert_eq!(opened.status, 200);
        assert_eq!(opened.body["opened"], true);

        let invalid = handle_request(
            &request(
                "POST",
                "/v1/open",
                "token",
                origin,
                json!({ "documentID": "bad", "extra": true }),
            ),
            &state,
        );
        assert_eq!(invalid.status, 400);
        let unauthorized = handle_request(
            &request(
                "POST",
                "/v1/open",
                "wrong-token",
                origin,
                json!({ "documentID": "550e8400-e29b-41d4-a716-446655440002" }),
            ),
            &state,
        );
        assert_eq!(unauthorized.status, 401);
        let missing = handle_request(
            &request(
                "POST",
                "/v1/open",
                "token",
                origin,
                json!({ "documentID": "550e8400-e29b-41d4-a716-446655440003" }),
            ),
            &state,
        );
        assert_eq!(missing.status, 404);
    }

    #[test]
    fn capture_requires_a_valid_duplicate_resolution_and_one_folder_target() {
        for (wire_value, expected) in [
            (
                "save-new-version",
                BrowserCaptureDuplicateResolution::SaveNewVersion,
            ),
            ("move-only", BrowserCaptureDuplicateResolution::MoveOnly),
            ("keep-copy", BrowserCaptureDuplicateResolution::KeepCopy),
        ] {
            let mut capture = valid_capture();
            capture["duplicateResolution"] = json!(wire_value);
            let parsed = parse_capture(&serde_json::to_vec(&capture).unwrap()).unwrap();
            assert_eq!(parsed.duplicate_resolution, Some(expected));
        }
        let mut capture = valid_capture();
        capture["duplicateResolution"] = json!("overwrite");
        assert_eq!(
            parse_capture(&serde_json::to_vec(&capture).unwrap())
                .unwrap_err()
                .code,
            "invalid-duplicate-resolution"
        );

        let mut both_folders = valid_capture();
        both_folders["folderID"] = json!("550e8400-e29b-41d4-a716-446655440001");
        both_folders["newFolderName"] = json!("Research");
        assert_eq!(
            parse_capture(&serde_json::to_vec(&both_folders).unwrap())
                .unwrap_err()
                .code,
            "folder-selection-conflict"
        );
        both_folders["folderID"] = Value::Null;
        both_folders["newFolderName"] = json!("  \t\n ");
        assert_eq!(
            parse_capture(&serde_json::to_vec(&both_folders).unwrap())
                .unwrap_err()
                .code,
            "invalid-folder-name"
        );
    }

    #[test]
    fn conflict_receipt_never_fabricates_a_document_id() {
        let capture = parse_capture(&serde_json::to_vec(&valid_capture()).unwrap()).unwrap();
        let receipt = receipt_json(
            &capture,
            BrowserCaptureSinkReceipt {
                conflict: Some(BrowserCaptureConflict {
                    document_id: "550e8400-e29b-41d4-a716-446655440002".to_string(),
                    title: "Existing article".to_string(),
                    folder: Some(BrowserCaptureFolder {
                        id: "550e8400-e29b-41d4-a716-446655440001".to_string(),
                        name: "Research".to_string(),
                    }),
                    file_size_bytes: 42,
                    updated_at: "2026-01-01T00:00:00Z".to_string(),
                    incoming_has_changes: true,
                }),
                ..BrowserCaptureSinkReceipt::default()
            },
        )
        .unwrap();
        assert_eq!(receipt["requiresDuplicateResolution"], true);
        assert_eq!(
            receipt["conflict"]["documentID"],
            "550e8400-e29b-41d4-a716-446655440002"
        );
        assert!(receipt.get("documentID").is_none());
    }

    #[test]
    fn validates_full_page_html_and_mhtml_archives_strictly() {
        let html = b"<!doctype html><html><body>offline</body></html>";
        let mut valid = valid_capture();
        valid["capture"]["captureMode"] = json!("full-page");
        valid["capture"]["archiveFormat"] = json!("html");
        valid["capture"]["archiveData"] =
            json!(base64::engine::general_purpose::STANDARD.encode(html));
        valid["capture"]["archiveEmbeddedResourceCount"] = json!(2);
        valid["capture"]["archiveMissingResourceCount"] = json!(1);
        valid["capture"]["archiveWasTruncated"] = json!(true);
        let parsed = parse_capture(&serde_json::to_vec(&valid).unwrap()).unwrap();
        let archive = parsed.archive.unwrap();
        assert_eq!(archive.bytes, html);
        assert_eq!(archive.embedded_resource_count, Some(2));
        assert_eq!(archive.missing_resource_count, Some(1));
        assert_eq!(archive.was_truncated, Some(true));

        let mhtml = b"MIME-Version: 1.0\r\nContent-Type: multipart/related; boundary=x\r\n\r\n--x";
        valid["capture"]["archiveFormat"] = json!("mhtml");
        valid["capture"]["archiveData"] =
            json!(base64::engine::general_purpose::STANDARD.encode(mhtml));
        assert!(parse_capture(&serde_json::to_vec(&valid).unwrap()).is_ok());

        valid["capture"]["archiveData"] = json!("%%%not base64%%%");
        assert_eq!(
            parse_capture(&serde_json::to_vec(&valid).unwrap())
                .unwrap_err()
                .status,
            400
        );
        valid["capture"]["archiveData"] =
            json!(base64::engine::general_purpose::STANDARD.encode(b"not html"));
        valid["capture"]["archiveFormat"] = json!("html");
        assert_eq!(
            parse_capture(&serde_json::to_vec(&valid).unwrap())
                .unwrap_err()
                .status,
            400
        );
        valid["capture"]["captureMode"] = json!("cleaned-article");
        valid["capture"]["archiveData"] =
            json!(base64::engine::general_purpose::STANDARD.encode(html));
        assert_eq!(
            parse_capture(&serde_json::to_vec(&valid).unwrap())
                .unwrap_err()
                .status,
            400
        );
    }

    #[test]
    fn receipt_reports_the_permissions_the_sink_actually_persisted() {
        let capture = parse_capture(&serde_json::to_vec(&valid_capture()).unwrap()).unwrap();
        let receipt = receipt_json(
            &capture,
            BrowserCaptureSinkReceipt {
                document_id: Some("550e8400-e29b-41d4-a716-446655440003".to_string()),
                allows_local_semantic_index: Some(false),
                allows_remote_ai_use: Some(true),
                title: Some("An example (copy)".to_string()),
                saved_at: Some("2026-01-01T00:00:00Z".to_string()),
                ..BrowserCaptureSinkReceipt::default()
            },
        )
        .unwrap();
        assert_eq!(receipt["allowsLocalSemanticIndex"], false);
        assert_eq!(receipt["allowsRemoteAIUse"], true);
        assert_eq!(receipt["title"], "An example (copy)");
        assert_eq!(receipt["savedAt"], "2026-01-01T00:00:00Z");
    }

    #[test]
    fn rejects_oversized_text_bad_urls_and_bad_ids() {
        let mut invalid = valid_capture();
        invalid["operationID"] = json!("not-a-uuid");
        assert!(parse_capture(&serde_json::to_vec(&invalid).unwrap()).is_err());
        invalid["operationID"] = json!("550E8400-E29B-41D4-A716-446655440000");
        assert_eq!(
            parse_capture(&serde_json::to_vec(&invalid).unwrap())
                .unwrap_err()
                .code,
            "invalid-operation-id"
        );
        let mut invalid = valid_capture();
        invalid["capture"]["sourceURL"] = json!("https://user:password@example.test/");
        assert!(parse_capture(&serde_json::to_vec(&invalid).unwrap()).is_err());
        let mut invalid = valid_capture();
        invalid["capture"]["contentText"] = json!("x".repeat(MAXIMUM_IMPORT_TEXT_BYTES + 1));
        assert_eq!(
            parse_capture(&serde_json::to_vec(&invalid).unwrap())
                .unwrap_err()
                .status,
            413
        );
    }

    #[test]
    fn rejects_disallowed_methods_and_preflight_headers() {
        let state = shared("token");
        let response = handle_request(
            &request(
                "GET",
                "/v1/import",
                "token",
                "chrome-extension://lnibkmfhfikfbkeehcjbiaalhkiankam",
                json!({}),
            ),
            &state,
        );
        assert_eq!(response.status, 405);
        let mut options = request(
            "OPTIONS",
            "/v1/import",
            "",
            "chrome-extension://lnibkmfhfikfbkeehcjbiaalhkiankam",
            json!({}),
        );
        options.headers.insert(
            "access-control-request-method".to_string(),
            "POST".to_string(),
        );
        options.headers.insert(
            "access-control-request-headers".to_string(),
            "authorization, x-repopress-protocol, x-nope".to_string(),
        );
        assert_eq!(handle_request(&options, &state).status, 403);
    }

    #[test]
    fn raw_parser_requires_loopback_host_and_rejects_duplicates_and_large_headers() {
        assert_eq!(
            parse_raw(b"GET /v1/status HTTP/1.1\r\n\r\n".to_vec(), 0),
            Err((400, "invalid-host"))
        );
        assert_eq!(
            parse_raw(
                b"GET /v1/status HTTP/1.1\r\nHost: 127.0.0.1:17843\r\nHost: 127.0.0.1:17843\r\n\r\n".to_vec(),
                0,
            ),
            Err((400, "duplicate-header"))
        );
        assert_eq!(
            parse_raw(
                b"POST /v1/import HTTP/1.1\r\nHost: 127.0.0.1:17843\r\nContent-Length: 4\r\n\r\nbody".to_vec(),
                3,
            ),
            Err((413, "payload-too-large"))
        );
        let mut oversized =
            b"GET /v1/status HTTP/1.1\r\nHost: 127.0.0.1:17843\r\nX-Fill: ".to_vec();
        oversized.extend(std::iter::repeat_n(b'a', MAXIMUM_HEADERS_BYTES));
        oversized.extend_from_slice(b"\r\n\r\n");
        assert_eq!(parse_raw(oversized, 0), Err((431, "headers-too-large")));
    }
}
