use super::site_preview_http::wait_for_page;
use super::site_preview_plan::{safe_article_path, PreviewGuard};
pub use super::site_preview_plan::{SitePreviewPlan, SitePreviewPlanRequest};
use super::{CommandError, CommandResult};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

const PAGE_TIMEOUT: Duration = Duration::from_secs(10);
const PLAN_TTL: Duration = Duration::from_secs(300);
const VERSION_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_VERSION_BYTES: u64 = 4096;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SitePreviewReadiness {
    pub site_kind: String,
    pub supported: bool,
    pub runtime_available: bool,
    pub executable: Option<String>,
    pub version: Option<String>,
    pub reason: Option<String>,
    pub warning: Option<String>,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SitePreviewSnapshot {
    pub preview_id: Option<String>,
    pub running: bool,
    pub url: Option<String>,
    pub site_kind: String,
    pub message: String,
}
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SitePreviewPageTarget {
    Article,
    Home,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SitePreviewPageSnapshot {
    pub preview_id: String,
    pub requested_url: String,
    pub url: String,
    pub ready: bool,
    pub status_code: Option<u16>,
    pub reason: String,
}
#[derive(Default, Debug)]
pub struct SitePreviewStore {
    state: Mutex<PreviewState>,
}
#[derive(Default, Debug)]
struct PreviewState {
    processes: HashMap<String, PreviewProcess>,
    plans: HashMap<String, StoredPreviewPlan>,
    owners: HashMap<String, String>,
    pending_starts: HashMap<String, String>,
}
#[derive(Clone, Debug)]
struct StoredPreviewPlan {
    session_id: String,
    plan: SitePreviewPlan,
    guard: PreviewGuard,
    deadline: Instant,
}
#[derive(Debug)]
struct PreviewProcess {
    child: Child,
    id: String,
    site_kind: String,
    root_url: String,
    plan: SitePreviewPlan,
    guard: PreviewGuard,
}
impl Drop for PreviewProcess {
    fn drop(&mut self) {
        stop_process(&mut self.child);
    }
}

/// Fixed trusted runtimes only; never executes repository scripts.
pub fn inspect_site_preview(root: &Path, site_kind: &str) -> CommandResult<SitePreviewReadiness> {
    let Some(tool_name) = supported_tool_name(site_kind) else {
        return Ok(unsupported_readiness(site_kind));
    };
    let reason = if validate_repository_root(root).is_err() {
        Some("repository_root_not_safe")
    } else {
        None
    };
    if let Some(reason) = reason {
        return Ok(SitePreviewReadiness {
            site_kind: site_kind.into(),
            supported: true,
            runtime_available: false,
            executable: None,
            version: None,
            reason: Some(reason.into()),
            warning: Some(trust_warning()),
        });
    }
    let Some(executable) = resolve_trusted_executable(tool_name) else {
        return Ok(SitePreviewReadiness {
            site_kind: site_kind.into(),
            supported: true,
            runtime_available: false,
            executable: None,
            version: None,
            reason: Some("runtime_not_found_in_trusted_locations".into()),
            warning: Some(trust_warning()),
        });
    };
    if executable_is_within_repository(&executable, root) {
        return Ok(SitePreviewReadiness {
            site_kind: site_kind.into(),
            supported: true,
            runtime_available: false,
            executable: None,
            version: None,
            reason: Some("runtime_inside_repository_rejected".into()),
            warning: Some(trust_warning()),
        });
    }
    let version = capture_version(&executable, root).ok().flatten();
    Ok(SitePreviewReadiness {
        site_kind: site_kind.into(),
        supported: true,
        runtime_available: true,
        executable: Some(executable.display().to_string()),
        version,
        reason: None,
        warning: Some(trust_warning()),
    })
}
fn validate_preview_id(id: &str) -> CommandResult<()> {
    if id.is_empty()
        || id.len() > 128
        || !id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        return Err(CommandError::new(
            "preview_invalid_id",
            "Preview instance is invalid.",
        ));
    }
    Ok(())
}
fn preview_error(code: &str) -> CommandError {
    CommandError::new(
        code,
        "Preview could not be verified. Prepare a new preview plan.",
    )
}
impl SitePreviewStore {
    fn lock(&self) -> CommandResult<std::sync::MutexGuard<'_, PreviewState>> {
        self.state
            .lock()
            .map_err(|_| preview_error("preview_store_unavailable"))
    }
    pub fn plan_preview(
        &self,
        session_id: &str,
        root: &Path,
        site_kind: &str,
        mut request: SitePreviewPlanRequest,
        document_path: Option<&str>,
    ) -> CommandResult<SitePreviewPlan> {
        validate_session_id(session_id)?;
        let root = validate_repository_root(root)?;
        let name = supported_tool_name(site_kind)
            .ok_or_else(|| preview_error("preview_site_kind_unsupported"))?;
        let executable = resolve_trusted_executable(name)
            .ok_or_else(|| preview_error("preview_runtime_unavailable"))?;
        if executable_is_within_repository(&executable, &root) {
            return Err(preview_error("preview_runtime_rejected"));
        }
        request.article_path = safe_article_path(request.article_path.as_deref())?;
        if request.document.is_none() && request.article_path.is_some() {
            return Err(preview_error("preview_context_invalid"));
        }
        let guard =
            PreviewGuard::capture(&root, &executable, document_path, request.document.as_ref())?;
        self.store_plan(session_id, site_kind, request, guard)
    }
    fn store_plan(
        &self,
        session_id: &str,
        site_kind: &str,
        request: SitePreviewPlanRequest,
        guard: PreviewGuard,
    ) -> CommandResult<SitePreviewPlan> {
        let expires = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| preview_error("preview_clock_invalid"))?
            .as_millis()
            .checked_add(PLAN_TTL.as_millis())
            .and_then(|v| u64::try_from(v).ok())
            .ok_or_else(|| preview_error("preview_clock_invalid"))?;
        let plan = SitePreviewPlan {
            plan_id: Uuid::new_v4().to_string(),
            site_kind: site_kind.into(),
            executable: guard.executable.display().to_string(),
            expires_at_epoch_ms: expires,
            config_fingerprint: guard.config_fingerprint.clone(),
            document: request.document,
            article_path: request.article_path,
        };
        let mut state = self.lock()?;
        state
            .plans
            .retain(|_, value| value.deadline > Instant::now() && value.session_id != session_id);
        if state.plans.len() >= 64 {
            return Err(preview_error("preview_plan_capacity"));
        }
        state.plans.insert(
            plan.plan_id.clone(),
            StoredPreviewPlan {
                session_id: session_id.into(),
                plan: plan.clone(),
                guard,
                deadline: Instant::now() + PLAN_TTL,
            },
        );
        Ok(plan)
    }
    fn consume_plan(&self, session_id: &str, plan_id: &str) -> CommandResult<StoredPreviewPlan> {
        validate_preview_id(plan_id)?;
        let mut state = self.lock()?;
        let valid = state
            .plans
            .get(plan_id)
            .is_some_and(|p| p.session_id == session_id && p.deadline > Instant::now());
        if !valid {
            if state
                .plans
                .get(plan_id)
                .is_some_and(|p| p.session_id == session_id)
            {
                state.plans.remove(plan_id);
            }
            return Err(preview_error("preview_plan_expired"));
        }
        let stored = state
            .plans
            .remove(plan_id)
            .ok_or_else(|| preview_error("preview_plan_expired"))?;
        if state.pending_starts.len() >= 64 && !state.pending_starts.contains_key(session_id) {
            return Err(preview_error("preview_process_capacity"));
        }
        state
            .pending_starts
            .insert(session_id.into(), plan_id.into());
        Ok(stored)
    }
    fn pending_is_current(&self, session_id: &str, id: &str) -> bool {
        self.lock()
            .is_ok_and(|state| state.pending_starts.get(session_id).map(String::as_str) == Some(id))
    }
    fn clear_pending(&self, session_id: &str, id: &str) {
        if let Ok(mut state) = self.lock() {
            if state.pending_starts.get(session_id).map(String::as_str) == Some(id) {
                state.pending_starts.remove(session_id);
            }
        }
    }

    pub fn start_preview(
        &self,
        session_id: &str,
        plan_id: &str,
        confirmed: bool,
        context: impl Fn() -> CommandResult<(PathBuf, String)>,
        validate_document: impl Fn(&SitePreviewPlanRequest) -> CommandResult<()>,
    ) -> CommandResult<SitePreviewSnapshot> {
        validate_session_id(session_id)?;
        let stored = self.consume_plan(session_id, plan_id)?;
        let result = (|| {
            if !confirmed {
                return Err(preview_error("preview_trust_confirmation_required"));
            }
            let (root, site_kind) = context()?;
            if !self.pending_is_current(session_id, plan_id) {
                return Err(preview_error("preview_context_changed"));
            }
            if root != stored.guard.root || site_kind != stored.plan.site_kind {
                return Err(preview_error("preview_context_changed"));
            }
            let tool = supported_tool_name(&site_kind)
                .ok_or_else(|| preview_error("preview_site_kind_unsupported"))?;
            if resolve_trusted_executable(tool).as_ref() != Some(&stored.guard.executable) {
                return Err(preview_error("preview_context_changed"));
            }
            let request = SitePreviewPlanRequest {
                document: stored.plan.document.clone(),
                article_path: stored.plan.article_path.clone(),
            };
            validate_document(&request)?;
            stored.guard.revalidate()?;
            let port = allocate_loopback_port()?;
            let arguments = preview_arguments(&site_kind, port)?;
            let previous = self.reserve_spawn(session_id, plan_id)?;
            drop(previous); // Never wait/kill/spawn under the shared state mutex.
            let spawned = Command::new(&stored.guard.executable)
                .args(&arguments)
                .current_dir(&root)
                .env("PATH", trusted_tool_path(&root))
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn();
            let child = match spawned {
                Ok(child) => child,
                Err(_) => {
                    self.clear_owner(session_id, plan_id);
                    return Err(preview_error("preview_start_failed"));
                }
            };
            let mut process = PreviewProcess {
                child,
                id: plan_id.into(),
                site_kind: site_kind.clone(),
                root_url: format!("http://127.0.0.1:{port}/"),
                plan: stored.plan,
                guard: stored.guard,
            };
            let verified = (|| {
                validate_document(&request)?;
                process.guard.revalidate()?;
                if process
                    .child
                    .try_wait()
                    .map_err(|_| preview_error("preview_start_failed"))?
                    .is_some()
                {
                    return Err(preview_error("preview_process_exited"));
                }
                let mut state = self.lock()?;
                if state.owners.get(session_id).map(String::as_str) != Some(plan_id)
                    || state.pending_starts.get(session_id).map(String::as_str) != Some(plan_id)
                {
                    return Err(preview_error("preview_context_changed"));
                }
                let snapshot = SitePreviewSnapshot {
                    preview_id: Some(plan_id.into()),
                    running: true,
                    url: Some(process.root_url.clone()),
                    site_kind,
                    message: "preview_process_started_page_unchecked".into(),
                };
                state.processes.insert(session_id.into(), process);
                Ok(snapshot)
            })();
            if verified.is_err() {
                self.clear_owner(session_id, plan_id);
            }
            verified
        })();
        self.clear_pending(session_id, plan_id);
        result
    }
    fn reserve_spawn(&self, session_id: &str, id: &str) -> CommandResult<Option<PreviewProcess>> {
        let mut state = self.lock()?;
        if state.pending_starts.get(session_id).map(String::as_str) != Some(id) {
            return Err(preview_error("preview_context_changed"));
        }
        if state.owners.len() >= 32 && !state.owners.contains_key(session_id) {
            return Err(preview_error("preview_process_capacity"));
        }
        state.owners.insert(session_id.into(), id.into());
        Ok(state.processes.remove(session_id))
    }
    fn clear_owner(&self, session_id: &str, id: &str) {
        if let Ok(mut state) = self.lock() {
            if state.owners.get(session_id).map(String::as_str) == Some(id) {
                state.owners.remove(session_id);
            }
        }
    }
    fn current(&self, session_id: &str, id: &str) -> bool {
        if validate_preview_id(id).is_err() {
            return false;
        }
        let Ok(mut state) = self.lock() else {
            return false;
        };
        if state.owners.get(session_id).map(String::as_str) != Some(id) {
            return false;
        }
        if !state.processes.contains_key(session_id)
            && state.pending_starts.get(session_id).map(String::as_str) == Some(id)
        {
            return false; // Reading a pending instance cannot revoke its start reservation.
        }
        let alive = state
            .processes
            .get_mut(session_id)
            .is_some_and(|p| p.id == id && matches!(p.child.try_wait(), Ok(None)));
        let dead = if !alive {
            state.owners.remove(session_id);
            state.processes.remove(session_id)
        } else {
            None
        };
        drop(state);
        drop(dead);
        alive
    }
    pub fn request_for_preview(
        &self,
        session_id: &str,
        id: &str,
    ) -> CommandResult<SitePreviewPlanRequest> {
        if !self.current(session_id, id) {
            return Err(preview_error("preview_process_exited"));
        }
        let state = self.lock()?;
        let process = state
            .processes
            .get(session_id)
            .filter(|p| p.id == id)
            .ok_or_else(|| preview_error("preview_process_exited"))?;
        Ok(SitePreviewPlanRequest {
            document: process.plan.document.clone(),
            article_path: process.plan.article_path.clone(),
        })
    }
    pub fn check_page(
        &self,
        session_id: &str,
        id: &str,
        target: SitePreviewPageTarget,
        validate_document: impl Fn(&SitePreviewPlanRequest) -> CommandResult<()>,
    ) -> CommandResult<SitePreviewPageSnapshot> {
        validate_session_id(session_id)?;
        let request = self.request_for_preview(session_id, id)?;
        let (guard, root_url, path) = {
            let state = self.lock()?;
            let process = state
                .processes
                .get(session_id)
                .filter(|p| p.id == id)
                .ok_or_else(|| preview_error("preview_process_exited"))?;
            let path = match target {
                SitePreviewPageTarget::Home => "/".to_string(),
                SitePreviewPageTarget::Article => process
                    .plan
                    .article_path
                    .clone()
                    .ok_or_else(|| preview_error("preview_article_unavailable"))?,
            };
            (process.guard.clone(), process.root_url.clone(), path)
        };
        let validate = || {
            validate_document(&request)?;
            guard.revalidate()
        };
        if let Err(error) = validate() {
            let _ = self.stop_preview(session_id, Some(id));
            return Err(error);
        }
        let requested = url::Url::parse(&root_url)
            .and_then(|url| url.join(&path))
            .map_err(|_| preview_error("preview_context_invalid"))?
            .to_string();
        let result = wait_for_page(&requested, PAGE_TIMEOUT, || self.current(session_id, id))?;
        if !self.current(session_id, id) {
            return Err(preview_error("preview_process_exited"));
        }
        if let Err(error) = validate() {
            let _ = self.stop_preview(session_id, Some(id));
            return Err(error);
        }
        if !self.current(session_id, id) {
            return Err(preview_error("preview_process_exited"));
        }
        Ok(SitePreviewPageSnapshot {
            preview_id: id.into(),
            requested_url: requested,
            url: result.url,
            ready: result.ready,
            status_code: result.status_code,
            reason: result.reason.into(),
        })
    }
    pub fn stop_preview(
        &self,
        session_id: &str,
        id: Option<&str>,
    ) -> CommandResult<SitePreviewSnapshot> {
        validate_session_id(session_id)?;
        if let Some(id) = id {
            validate_preview_id(id)?;
        }
        let previous = {
            let mut state = self.lock()?;
            state
                .plans
                .retain(|key, p| p.session_id != session_id || id.is_some_and(|id| id != key));
            if id.is_none()
                || id.is_some_and(|id| {
                    state.pending_starts.get(session_id).map(String::as_str) == Some(id)
                })
            {
                state.pending_starts.remove(session_id);
            }
            if id.is_some_and(|id| state.owners.get(session_id).map(String::as_str) != Some(id)) {
                None
            } else {
                state.owners.remove(session_id);
                state.processes.remove(session_id)
            }
        };
        let site_kind = previous
            .as_ref()
            .map(|p| p.site_kind.clone())
            .unwrap_or_else(|| "unknown".into());
        let stopped = previous.is_some();
        drop(previous);
        Ok(SitePreviewSnapshot {
            preview_id: id.map(str::to_owned),
            running: false,
            url: None,
            site_kind,
            message: if stopped {
                "Preview stopped."
            } else {
                "No preview was running for this session."
            }
            .into(),
        })
    }
}

fn supported_tool_name(site_kind: &str) -> Option<&'static str> {
    match site_kind {
        "zola" => Some("zola"),
        "hugo" => Some("hugo"),
        _ => None,
    }
}

fn unsupported_readiness(site_kind: &str) -> SitePreviewReadiness {
    SitePreviewReadiness {
        site_kind: site_kind.to_string(),
        supported: false,
        runtime_available: false,
        executable: None,
        version: None,
        reason: Some("preview_site_kind_unsupported".to_string()),
        warning: None,
    }
}

fn trust_warning() -> String {
    "A real preview processes content from this trusted repository.".to_string()
}

fn validate_session_id(session_id: &str) -> CommandResult<()> {
    if session_id.is_empty() || session_id.len() > 128 || !session_id.is_ascii() {
        return Err(CommandError::new(
            "invalid_preview_session",
            "Preview session is invalid.",
        ));
    }
    Ok(())
}

fn validate_repository_root(root: &Path) -> CommandResult<PathBuf> {
    let metadata = fs::symlink_metadata(root).map_err(|_| {
        CommandError::new(
            "preview_repository_root_invalid",
            "Repository root is unavailable for preview.",
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(CommandError::new(
            "preview_repository_root_invalid",
            "Repository root is unavailable for preview.",
        ));
    }
    let canonical = root.canonicalize().map_err(|_| {
        CommandError::new(
            "preview_repository_root_invalid",
            "Repository root is unavailable for preview.",
        )
    })?;
    if canonical != root {
        return Err(CommandError::new(
            "preview_repository_root_invalid",
            "Repository root is unavailable for preview.",
        ));
    }
    Ok(canonical)
}

fn trusted_tool_directories() -> Vec<PathBuf> {
    let mut directories = vec![
        PathBuf::from("/usr/local/bin"),
        PathBuf::from("/usr/bin"),
        PathBuf::from("/bin"),
    ];
    #[cfg(target_os = "linux")]
    if let Some(home) = std::env::var_os("HOME") {
        let home = PathBuf::from(home);
        directories.push(home.join(".local/bin"));
        directories.push(home.join(".cargo/bin"));
    }
    directories
}

fn resolve_trusted_executable(name: &str) -> Option<PathBuf> {
    let trusted_directories: Vec<PathBuf> = trusted_tool_directories()
        .into_iter()
        .filter_map(|directory| directory.canonicalize().ok())
        .collect();
    for directory in &trusted_directories {
        let candidate = directory.join(name);
        let metadata = match fs::symlink_metadata(&candidate) {
            Ok(metadata) if metadata.file_type().is_file() => metadata,
            _ => continue,
        };
        if !is_executable(&metadata) {
            continue;
        }
        let resolved = match candidate.canonicalize() {
            Ok(resolved) => resolved,
            Err(_) => continue,
        };
        if resolved
            .parent()
            .is_some_and(|parent| trusted_directories.contains(&parent.to_path_buf()))
        {
            return Some(resolved);
        }
    }
    None
}

fn executable_is_within_repository(executable: &Path, root: &Path) -> bool {
    executable.starts_with(root)
}

fn trusted_tool_path(root: &Path) -> std::ffi::OsString {
    std::env::join_paths(
        trusted_tool_directories()
            .into_iter()
            .filter_map(|directory| directory.canonicalize().ok())
            .filter(|directory| !directory.starts_with(root)),
    )
    .unwrap_or_default()
}

#[cfg(unix)]
fn is_executable(metadata: &fs::Metadata) -> bool {
    use std::os::unix::fs::PermissionsExt;
    metadata.permissions().mode() & 0o111 != 0
}

#[cfg(not(unix))]
fn is_executable(_metadata: &fs::Metadata) -> bool {
    false
}

fn preview_arguments(site_kind: &str, port: u16) -> CommandResult<Vec<String>> {
    let port = port.to_string();
    match site_kind {
        "zola" => Ok(vec![
            "serve".to_string(),
            "--interface".to_string(),
            "127.0.0.1".to_string(),
            "--port".to_string(),
            port,
        ]),
        "hugo" => Ok(vec![
            "server".to_string(),
            "--bind".to_string(),
            "127.0.0.1".to_string(),
            "--port".to_string(),
            port,
            "--renderToMemory".to_string(),
            "--ignoreCache".to_string(),
            "--noHTTPCache".to_string(),
            "--noBuildLock".to_string(),
        ]),
        _ => Err(CommandError::new(
            "preview_site_kind_unsupported",
            "Preview is supported only for Zola and Hugo.",
        )),
    }
}

fn allocate_loopback_port() -> CommandResult<u16> {
    let listener = TcpListener::bind("127.0.0.1:0").map_err(|_| {
        CommandError::new(
            "preview_port_unavailable",
            "Unable to allocate a loopback port.",
        )
    })?;
    let port = listener
        .local_addr()
        .map_err(|_| {
            CommandError::new(
                "preview_port_unavailable",
                "Unable to allocate a loopback port.",
            )
        })?
        .port();
    drop(listener);
    Ok(port)
}

fn stop_process(child: &mut Child) {
    if child.try_wait().ok().flatten().is_none() {
        let _ = child.kill();
    }
    let _ = child.wait();
}

fn capture_version(executable: &Path, root: &Path) -> CommandResult<Option<String>> {
    let mut output = tempfile::tempfile().map_err(|_| {
        CommandError::new(
            "preview_version_unavailable",
            "Unable to inspect preview runtime.",
        )
    })?;
    let writer = output.try_clone().map_err(|_| {
        CommandError::new(
            "preview_version_unavailable",
            "Unable to inspect preview runtime.",
        )
    })?;
    let mut child = Command::new(executable)
        .arg("--version")
        .env("PATH", trusted_tool_path(root))
        .current_dir(executable.parent().unwrap_or(root))
        .stdin(Stdio::null())
        .stdout(Stdio::from(writer))
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| {
            CommandError::new(
                "preview_version_unavailable",
                "Unable to inspect preview runtime.",
            )
        })?;
    match wait_for_preview_child(&mut child, VERSION_TIMEOUT)? {
        Some(status) if status.success() => {}
        Some(_) => return Ok(None),
        None => {
            let _ = child.kill();
            let _ = child.wait();
            return Ok(None);
        }
    }
    output.seek(SeekFrom::Start(0)).map_err(|_| {
        CommandError::new(
            "preview_version_unavailable",
            "Unable to inspect preview runtime.",
        )
    })?;
    let mut bytes = Vec::new();
    output
        .take(MAX_VERSION_BYTES)
        .read_to_end(&mut bytes)
        .map_err(|_| {
            CommandError::new(
                "preview_version_unavailable",
                "Unable to inspect preview runtime.",
            )
        })?;
    let version_output = String::from_utf8_lossy(&bytes);
    let text = version_output.lines().next().unwrap_or("").trim();
    Ok((!text.is_empty()).then(|| text.to_string()))
}

fn wait_for_preview_child(
    child: &mut Child,
    timeout: Duration,
) -> CommandResult<Option<ExitStatus>> {
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Ok(Some(status)),
            Ok(None) if Instant::now() >= deadline => return Ok(None),
            Ok(None) => thread::sleep(Duration::from_millis(10)),
            Err(_) => {
                return Err(CommandError::new(
                    "preview_version_unavailable",
                    "Unable to inspect preview runtime.",
                ))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn supports_only_zola_and_hugo() {
        assert_eq!(supported_tool_name("zola"), Some("zola"));
        assert_eq!(supported_tool_name("hugo"), Some("hugo"));
        assert_eq!(supported_tool_name("astro"), None);
        assert!(!unsupported_readiness("jekyll").supported);
    }

    #[test]
    fn plans_loopback_only_arguments() {
        let zola = preview_arguments("zola", 43123).expect("zola plan");
        assert_eq!(
            zola,
            ["serve", "--interface", "127.0.0.1", "--port", "43123"]
        );
        let hugo = preview_arguments("hugo", 43124).expect("hugo plan");
        assert_eq!(hugo[0], "server");
        assert!(hugo.windows(2).any(|pair| pair == ["--bind", "127.0.0.1"]));
        assert!(hugo.iter().any(|argument| argument == "--renderToMemory"));
        assert!(hugo.iter().any(|argument| argument == "--noBuildLock"));
    }

    #[test]
    fn rejects_unconfirmed_or_invalid_session_inputs() {
        assert!(validate_session_id("").is_err());
        assert!(validate_session_id("会话").is_err());
        assert!(SitePreviewStore::default()
            .start_preview(
                "safe",
                "missing",
                false,
                || unreachable!(),
                |_| unreachable!()
            )
            .is_err());
    }

    #[test]
    fn requires_canonical_root_and_rejects_repository_executables() {
        let temporary = tempfile::tempdir().expect("temporary root");
        let root = temporary.path().canonicalize().expect("canonical root");
        assert!(validate_repository_root(&root).is_ok());
        assert!(validate_repository_root(Path::new(".")).is_err());
        assert!(executable_is_within_repository(
            &root.join(".local/bin/hugo"),
            &root
        ));
        assert!(!executable_is_within_repository(
            Path::new("/usr/bin/hugo"),
            &root
        ));
    }
}

#[cfg(test)]
#[path = "site_preview_p63_tests.rs"]
mod p63_tests;
