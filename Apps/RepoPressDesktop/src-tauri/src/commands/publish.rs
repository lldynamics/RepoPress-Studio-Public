use super::{blocking_task_failed, AppState};
use crate::core::{
    inspect_update_readiness, read_git_status, read_publish_remote_default_branch,
    read_publish_remote_url, read_push_retry_remote_url, secret_service_available, BrowserProtocol,
    CommandError, CommandResult, CredentialScope, CredentialStorage, DeploymentSnapshot,
    GitPublishOperation, GitPublishStore, GitPushRetryPlan, GitPushRetryResult, LinuxPackageKind,
    RemoteProvider, RemotePublishError, RemotePublishStore, RepositoryCredential,
    RepositoryCredentialStore, ReviewRequestDraft, UpdaterConfiguration,
};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::State;
use time::{format_description::well_known::Rfc3339, OffsetDateTime};
use uuid::Uuid;

const PUBLISH_REMOTE_FALLBACK: &str = "origin";
const MAX_GIT_PUSH_RETRY_BINDINGS: usize = 32;
const GIT_PUSH_RETRY_BINDING_LIFETIME: Duration = Duration::from_secs(5 * 60);

pub(super) struct PublishState {
    verification_bindings: Mutex<HashMap<String, VerificationBinding>>,
    review_verification_bindings: Mutex<HashMap<String, ReviewVerificationBinding>>,
    credential_store: RepositoryCredentialStore,
    credential_bindings: Mutex<HashMap<String, CredentialBinding>>,
    git_store: GitPublishStore,
    git_bindings: Mutex<HashMap<String, GitPlanBinding>>,
    git_push_retry_bindings: Mutex<HashMap<String, GitPushRetryBinding>>,
    remote_store: Option<RemotePublishStore>,
    remote_bindings: Mutex<HashMap<String, RemotePlanBinding>>,
}

impl Default for PublishState {
    fn default() -> Self {
        Self {
            verification_bindings: Mutex::new(HashMap::new()),
            review_verification_bindings: Mutex::new(HashMap::new()),
            credential_store: RepositoryCredentialStore::default(),
            credential_bindings: Mutex::new(HashMap::new()),
            git_store: GitPublishStore::default(),
            git_bindings: Mutex::new(HashMap::new()),
            git_push_retry_bindings: Mutex::new(HashMap::new()),
            remote_store: RemotePublishStore::new().ok(),
            remote_bindings: Mutex::new(HashMap::new()),
        }
    }
}

#[derive(Clone)]
struct CredentialBinding {
    credential_id: String,
    root: PathBuf,
    provider: RemoteProvider,
    host: String,
    account: Option<String>,
    username: Option<String>,
    scope: CredentialScope,
    storage: CredentialStorage,
}

#[derive(Clone)]
struct GitPlanBinding {
    session_id: String,
    root: PathBuf,
    operation: GitPublishOperation,
    remote: Option<HostedRemote>,
}

#[derive(Clone)]
struct GitPushRetryBinding {
    session_id: String,
    root: PathBuf,
    remote: HostedRemote,
    created_at: Instant,
}

#[derive(Clone)]
struct RemotePlanBinding {
    session_id: String,
    root: PathBuf,
    remote: HostedRemote,
    evidence: crate::core::RemoteReviewEvidence,
    created_at: Instant,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct HostedRemote {
    provider: RemoteProvider,
    host: String,
    owner: String,
    project: String,
    transport: GitTransport,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum GitTransport {
    Https,
    Ssh,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
enum CredentialStorageView {
    SecretService,
    SessionOnly,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RepositoryCredentialSnapshot {
    credential_id: String,
    provider: RemoteProvider,
    host: String,
    account: Option<String>,
    username: Option<String>,
    storage: CredentialStorageView,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CredentialStatusSnapshot {
    storage: CredentialStorageView,
    secret_service_available: bool,
    credentials: Vec<RepositoryCredentialSnapshot>,
    warning: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitOperationPlanView {
    plan_id: String,
    operation: GitPublishOperation,
    branch: Option<String>,
    head: Option<String>,
    staged_files: Vec<String>,
    remote: Option<String>,
    remote_url: Option<String>,
    summary: String,
    expires_at: String,
    warnings: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitOperationResultView {
    operation: GitPublishOperation,
    summary: String,
    branch: Option<String>,
    head: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitPushRetryPlanView {
    plan_id: String,
    branch: String,
    head: String,
    remote: String,
    remote_url: String,
    observed_remote_sha: String,
    pending_commit_count: usize,
    changed_paths: Vec<String>,
    summary: String,
    expires_at: String,
    warnings: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitPushRetryResultView {
    branch: String,
    head: String,
    remote_sha: String,
    verified: bool,
    summary: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteReviewPlanView {
    plan_id: String,
    provider: RemoteProvider,
    host: String,
    title: String,
    base_branch: Option<String>,
    head_branch: Option<String>,
    summary: String,
    expires_at: String,
    warnings: Vec<String>,
    source_sha: String,
    request_marker: String,
    body_preview: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteReviewResultView {
    provider: RemoteProvider,
    url: Option<String>,
    summary: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeploymentCheckSnapshot {
    configured: bool,
    provider: Option<String>,
    status: String,
    url: Option<String>,
    summary: String,
    checked_at: Option<String>,
    warning: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadinessSnapshot {
    configured: bool,
    ready: bool,
    summary: String,
    warning: Option<String>,
}

#[tauri::command(rename_all = "camelCase")]
pub async fn credential_status(
    session_id: String,
    state: State<'_, AppState>,
) -> CommandResult<CredentialStatusSnapshot> {
    let repositories = state.repositories.clone();
    let publish = state.publish.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id)?;
        publish.discover_persisted_credential(&root)?;
        publish.credential_snapshot(&root)
    })
    .await
    .map_err(|_| blocking_task_failed("credential_status_task_failed", "read credentials"))?
}

#[tauri::command(rename_all = "camelCase")]
#[allow(clippy::too_many_arguments)]
pub async fn store_repository_credential(
    session_id: String,
    provider: String,
    host: String,
    account: Option<String>,
    username: Option<String>,
    token: String,
    state: State<'_, AppState>,
) -> CommandResult<CredentialStatusSnapshot> {
    let repositories = state.repositories.clone();
    let publish = state.publish.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id)?;
        let provider = parse_provider_and_host(&provider, &host)?;
        let account = normalized_optional(account, 256, "credential_account_invalid")?;
        let username = normalized_optional(username, 256, "credential_username_invalid")?;
        let scope = repository_credential_scope(provider, &host, &root)?;
        let credential = RepositoryCredential::from_token(token)?;
        let status = publish.credential_store.save(scope.clone(), credential)?;

        let mut bindings = publish
            .credential_bindings
            .lock()
            .map_err(|_| publish_state_unavailable())?;
        let existing_id = bindings
            .values()
            .find(|binding| {
                binding.root == root && binding.provider == provider && binding.host == host
            })
            .map(|binding| binding.credential_id.clone());
        let credential_id = existing_id.unwrap_or_else(|| Uuid::new_v4().to_string());
        bindings.retain(|_, binding| {
            !(binding.root == root && binding.provider == provider && binding.host == host)
        });
        bindings.insert(
            credential_id.clone(),
            CredentialBinding {
                credential_id,
                root: root.clone(),
                provider,
                host,
                account,
                username,
                scope,
                storage: status.storage,
            },
        );
        drop(bindings);
        publish.credential_snapshot(&root)
    })
    .await
    .map_err(|_| blocking_task_failed("credential_store_task_failed", "store the credential"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn delete_repository_credential(
    session_id: String,
    credential_id: String,
    state: State<'_, AppState>,
) -> CommandResult<CredentialStatusSnapshot> {
    let repositories = state.repositories.clone();
    let publish = state.publish.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id)?;
        let binding = publish
            .credential_bindings
            .lock()
            .map_err(|_| publish_state_unavailable())?
            .get(&credential_id)
            .filter(|binding| binding.root == root)
            .cloned()
            .ok_or_else(|| {
                CommandError::new(
                    "credential_not_found",
                    "The repository credential is unavailable.",
                )
            })?;
        publish.credential_store.delete(&binding.scope)?;
        publish
            .credential_bindings
            .lock()
            .map_err(|_| publish_state_unavailable())?
            .remove(&credential_id);
        publish.credential_snapshot(&root)
    })
    .await
    .map_err(|_| blocking_task_failed("credential_delete_task_failed", "delete the credential"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn plan_git_operation(
    session_id: String,
    operation: String,
    commit_message: Option<String>,
    state: State<'_, AppState>,
) -> CommandResult<GitOperationPlanView> {
    let repositories = state.repositories.clone();
    let publish = state.publish.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id)?;
        let status = read_git_status(&root)?;
        if !status.available {
            return Err(CommandError::new(
                "git_repository_required",
                "A Git repository is required for publish operations.",
            ));
        }
        let operation = parse_git_operation(&operation)?;
        let remote_name = default_remote_name(&status);
        let plan = match operation {
            GitPublishOperation::Commit => publish.git_store.plan_commit(
                &session_id,
                &root,
                commit_message.as_deref().unwrap_or_default(),
            )?,
            GitPublishOperation::Fetch => {
                publish
                    .git_store
                    .plan_fetch(&session_id, &root, &remote_name)?
            }
            GitPublishOperation::Push => {
                publish
                    .git_store
                    .plan_push(&session_id, &root, &remote_name)?
            }
        };
        let remote = plan
            .summary
            .remote_url
            .as_deref()
            .map(parse_hosted_remote)
            .transpose()?;
        let staged_files = if operation == GitPublishOperation::Commit {
            status
                .changed_files
                .iter()
                .filter(|file| {
                    file.status
                        .as_bytes()
                        .first()
                        .is_some_and(|value| !matches!(value, b' ' | b'?'))
                })
                .map(|file| file.relative_path.clone())
                .collect::<Vec<_>>()
        } else {
            Vec::new()
        };
        let (summary, warnings) = git_plan_description(operation, staged_files.len());
        let view = GitOperationPlanView {
            plan_id: plan.plan_id.clone(),
            operation,
            branch: plan.summary.branch.clone(),
            head: Some(plan.summary.head.clone()),
            staged_files,
            remote: plan.summary.remote.clone(),
            remote_url: plan.summary.remote_url.clone(),
            summary,
            expires_at: rfc3339_from_millis(plan.expires_at_unix_ms)?,
            warnings,
        };
        publish
            .git_bindings
            .lock()
            .map_err(|_| publish_state_unavailable())?
            .insert(
                plan.plan_id,
                GitPlanBinding {
                    session_id,
                    root,
                    operation,
                    remote,
                },
            );
        Ok(view)
    })
    .await
    .map_err(|_| blocking_task_failed("git_plan_task_failed", "plan the Git operation"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn execute_git_operation(
    session_id: String,
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<GitOperationResultView> {
    let log = Arc::clone(&state.operation_log);
    let scope = super::operation_log::repository_scope(&state, Some(&session_id));
    super::operation_log::run_logged(
        log,
        crate::core::OperationKind::GitOperation,
        scope,
        async {
            let repositories = state.repositories.clone();
            let publish = state.publish.clone();
            let ledger = state.publish_ledger.clone();
            tauri::async_runtime::spawn_blocking(move || {
                let binding = publish
                    .git_bindings
                    .lock()
                    .map_err(|_| publish_state_unavailable())?
                    .remove(&plan_id)
                    .ok_or_else(plan_not_found)?;
                let root = repositories.root_for_session(&session_id)?;
                if binding.session_id != session_id || binding.root != root {
                    return Err(CommandError::new(
                        "publish_session_mismatch",
                        "The reviewed plan belongs to another repository session.",
                    ));
                }
                let credential = match binding.remote.as_ref() {
                    Some(remote) if remote.transport == GitTransport::Https => {
                        publish.lookup_credential(&root, remote.provider, &remote.host)?
                    }
                    _ => None,
                };
                let receipt = publish.git_store.execute_recorded(
                    &plan_id,
                    &session_id,
                    true,
                    credential.as_ref(),
                    &ledger,
                )?;
                let summary = match binding.operation {
                    GitPublishOperation::Commit => "已提交审阅过的暂存区内容。",
                    GitPublishOperation::Fetch => "已更新远端跟踪引用；工作区和当前分支未被合并。",
                    GitPublishOperation::Push => {
                        "远端分支已精确核实为冻结提交，执行记录已持久保存。"
                    }
                }
                .to_string();
                Ok(GitOperationResultView {
                    operation: receipt.operation,
                    summary,
                    branch: receipt.summary.branch,
                    head: receipt.revision.or(Some(receipt.summary.head)),
                })
            })
            .await
            .map_err(|_| {
                blocking_task_failed("git_execute_task_failed", "execute the Git operation")
            })?
        },
    )
    .await
}

#[tauri::command(rename_all = "camelCase")]
pub async fn plan_git_push_retry(
    session_id: String,
    state: State<'_, AppState>,
) -> CommandResult<GitPushRetryPlanView> {
    let repositories = state.repositories.clone();
    let publish = state.publish.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id)?;
        let status = read_git_status(&root)?;
        if !status.available {
            return Err(CommandError::new(
                "git_repository_required",
                "A Git repository is required for push retry.",
            ));
        }
        let remote_name = default_remote_name(&status);
        let remote_url = read_push_retry_remote_url(&root, &remote_name)?;
        let remote = parse_hosted_remote(&remote_url)?;
        let credential = if remote.transport == GitTransport::Https {
            publish.lookup_credential(&root, remote.provider, &remote.host)?
        } else {
            None
        };
        let mut bindings = publish
            .git_push_retry_bindings
            .lock()
            .map_err(|_| publish_state_unavailable())?;
        bindings.retain(|_, binding| binding.created_at.elapsed() < GIT_PUSH_RETRY_BINDING_LIFETIME);
        if bindings.len() >= MAX_GIT_PUSH_RETRY_BINDINGS {
            return Err(CommandError::new(
                "git_push_retry_plan_limit",
                "Too many pending push retry plans; inspect or wait for an existing plan to expire.",
            ));
        }
        let plan: GitPushRetryPlan = publish.git_store.plan_push_retry_for_url(
            &session_id,
            &root,
            &remote_name,
            &remote_url,
            credential.as_ref(),
        )?;
        let view = GitPushRetryPlanView {
            plan_id: plan.plan_id.clone(),
            branch: plan.branch,
            head: plan.head,
            remote: plan.remote,
            remote_url: plan.remote_url,
            observed_remote_sha: plan.observed_remote_sha,
            pending_commit_count: plan.pending_commit_count,
            changed_paths: plan.changed_paths,
            summary: "将把已审阅的本地提交以非强制方式推送到实时核对过的远端分支。".to_string(),
            expires_at: rfc3339_from_millis(plan.expires_at_unix_ms)?,
            warnings: vec![
                "计划只适用于无暂存或工作区改动的已提交内容。".to_string(),
                "确认后会重新检查仓库和远端；只有远端精确等于冻结 SHA 才会报告成功。".to_string(),
            ],
        };
        bindings.insert(
            plan.plan_id,
            GitPushRetryBinding {
                session_id,
                root,
                remote,
                created_at: Instant::now(),
            },
        );
        Ok(view)
    })
    .await
    .map_err(|_| blocking_task_failed("git_push_retry_plan_task_failed", "inspect push retry"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn execute_git_push_retry(
    session_id: String,
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<GitPushRetryResultView> {
    let log = Arc::clone(&state.operation_log);
    let scope = super::operation_log::repository_scope(&state, Some(&session_id));
    super::operation_log::run_logged(
        log,
        crate::core::OperationKind::GitOperation,
        scope,
        async {
            let repositories = state.repositories.clone();
            let publish = state.publish.clone();
            let ledger = state.publish_ledger.clone();
            tauri::async_runtime::spawn_blocking(move || {
                let binding = publish
                    .git_push_retry_bindings
                    .lock()
                    .map_err(|_| publish_state_unavailable())?
                    .remove(&plan_id)
                    .ok_or_else(|| {
                        CommandError::new(
                            "git_push_retry_plan_not_found",
                            "The push retry plan is unavailable or has already been used.",
                        )
                    })?;
                let root = repositories.root_for_session(&session_id)?;
                if binding.session_id != session_id || binding.root != root {
                    return Err(CommandError::new(
                        "git_push_retry_session_mismatch",
                        "The push retry plan belongs to another repository session.",
                    ));
                }
                let credential = if binding.remote.transport == GitTransport::Https {
                    publish.lookup_credential(
                        &root,
                        binding.remote.provider,
                        &binding.remote.host,
                    )?
                } else {
                    None
                };
                let receipt = publish.git_store.execute_push_retry_recorded(
                    &plan_id,
                    &session_id,
                    credential.as_ref(),
                    &ledger,
                )?;
                Ok(push_retry_result_view(receipt))
            })
            .await
            .map_err(|_| {
                blocking_task_failed("git_push_retry_execute_task_failed", "execute push retry")
            })?
        },
    )
    .await
}

#[tauri::command(rename_all = "camelCase")]
#[allow(clippy::too_many_arguments)]
pub async fn plan_remote_review(
    session_id: String,
    provider: String,
    host: String,
    title: String,
    body: Option<String>,
    base_branch: Option<String>,
    head_branch: Option<String>,
    state: State<'_, AppState>,
) -> CommandResult<RemoteReviewPlanView> {
    let repositories = state.repositories.clone();
    let publish = state.publish.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id)?;
        let requested_provider = parse_provider_and_host(&provider, &host)?;
        let status = read_git_status(&root)?;
        let remote_name = default_remote_name(&status);
        let target = crate::core::capture_review_target(&root, &remote_name)?;
        let remote = parse_hosted_remote(&target.remote_url)?;
        if remote.provider != requested_provider || remote.host != host {
            return Err(CommandError::new(
                "remote_provider_mismatch",
                "The selected provider does not match the repository publish remote.",
            ));
        }
        let current_branch = status.branch.ok_or_else(|| {
            CommandError::new(
                "remote_review_detached_head",
                "Creating a review requires a checked-out branch.",
            )
        })?;
        let source_branch = normalized_branch(head_branch)?.unwrap_or(current_branch.clone());
        if source_branch != current_branch {
            return Err(CommandError::new(
                "remote_review_head_mismatch",
                "The review source must be the currently checked-out branch.",
            ));
        }
        let target_branch = match normalized_branch(base_branch)? {
            Some(value) => value,
            None => read_publish_remote_default_branch(&root, &remote_name)?.ok_or_else(|| {
                CommandError::new(
                    "remote_default_branch_unknown",
                    "Enter a target branch because the remote default branch is unavailable locally.",
                )
            })?,
        };
        let draft = ReviewRequestDraft {
            provider: requested_provider,
            owner: remote.owner.clone(),
            project: remote.project.clone(),
            source_branch: source_branch.clone(),
            target_branch: target_branch.clone(),
            title,
            body: body.unwrap_or_default(),
        };
        let remote_store = publish.remote_store.as_ref().ok_or_else(|| {
            CommandError::new(
                "remote_client_unavailable",
                "The remote publishing client is unavailable.",
            )
        })?;
        let (plan, evidence, body_preview) = remote_store
            .plan_recorded_review_request(draft, target)
            .map_err(remote_error)?;
        let has_credential = publish.has_credential(&root, remote.provider, &remote.host)?;
        let mut warnings = vec!["说明末尾会加入本计划的关联标记，便于结果不明后只读核实；下方展示实际发送内容。".to_string(), "执行前会读取远端项目和来源提交；只有来源 SHA 与本计划一致才创建，结果不明不会自动重建。".to_string()];
        if !has_credential {
            warnings.push("执行前需先为此仓库保存对应平台的访问令牌。".to_string());
        }
        let summary = format!(
            "将在 {}/{} 创建 {} → {} 的{}。",
            remote.owner,
            remote.project,
            source_branch,
            target_branch,
            if requested_provider == RemoteProvider::Github {
                " Pull Request"
            } else {
                " Merge Request"
            }
        );
        let view = RemoteReviewPlanView {
            plan_id: plan.plan_id.clone(),
            provider: requested_provider,
            host: host.clone(),
            title: plan.request_summary.title,
            base_branch: Some(target_branch),
            head_branch: Some(source_branch.clone()),
            summary,
            expires_at: rfc3339_from_seconds(plan.expires_at_unix_seconds)?,
            warnings,
            source_sha: evidence.source_sha.clone(),
            request_marker: evidence.marker.clone(),
            body_preview,
        };
        let mut bindings = publish.remote_bindings.lock().map_err(|_| publish_state_unavailable())?;
        bindings.retain(|_, binding| binding.created_at.elapsed() < GIT_PUSH_RETRY_BINDING_LIFETIME);
        if bindings.len() >= MAX_GIT_PUSH_RETRY_BINDINGS { return Err(publish_state_unavailable()); }
        bindings.insert(plan.plan_id, RemotePlanBinding { session_id, root, remote, evidence, created_at: Instant::now() });
        Ok(view)
    })
    .await
    .map_err(|_| blocking_task_failed("remote_plan_task_failed", "plan the remote review"))?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn execute_remote_review(
    session_id: String,
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<RemoteReviewResultView> {
    let log = Arc::clone(&state.operation_log);
    let scope = super::operation_log::repository_scope(&state, Some(&session_id));
    super::operation_log::run_logged(
        log,
        crate::core::OperationKind::RemoteReview,
        scope,
        async {
            let repositories = state.repositories.clone();
            let publish = state.publish.clone();
            let ledger = state.remote_review_ledger.clone();
            let lookup_state = publish.clone();
            let lookup_plan_id = plan_id.clone();
            let (binding, credential) = tauri::async_runtime::spawn_blocking(move || {
                let binding = lookup_state
                    .remote_bindings
                    .lock()
                    .map_err(|_| publish_state_unavailable())?
                    .remove(&lookup_plan_id)
                    .ok_or_else(plan_not_found)?;
                let root = repositories.root_for_session(&session_id)?;
                if binding.session_id != session_id
                    || binding.root != root
                    || binding.created_at.elapsed() >= GIT_PUSH_RETRY_BINDING_LIFETIME
                {
                    return Err(CommandError::new(
                        "publish_session_mismatch",
                        "The reviewed plan belongs to another repository session.",
                    ));
                }
                crate::core::validate_review_repository(&binding.evidence, true)?;
                let credential = lookup_state
                    .lookup_credential(&root, binding.remote.provider, &binding.remote.host)?
                    .ok_or_else(|| {
                        CommandError::new(
                            "remote_credential_required",
                            "Save a repository credential before creating the review.",
                        )
                    })?;
                Ok((binding, credential))
            })
            .await
            .map_err(|_| {
                blocking_task_failed("remote_execute_task_failed", "validate the remote plan")
            })??;

            let remote_store = publish.remote_store.as_ref().ok_or_else(|| {
                CommandError::new(
                    "remote_client_unavailable",
                    "The remote publishing client is unavailable.",
                )
            })?;
            let receipt = remote_store
                .create_recorded_review_request(
                    &plan_id,
                    &binding.evidence,
                    credential.token(),
                    &ledger,
                )
                .await?;
            Ok(RemoteReviewResultView {
                provider: receipt.provider,
                url: Some(receipt.web_url.clone()),
                summary: format!(
                    "已核实 {} #{}，执行记录已保存",
                    if binding.remote.provider == RemoteProvider::Github {
                        "Pull Request"
                    } else {
                        "Merge Request"
                    },
                    receipt.review_number
                ),
            })
        },
    )
    .await
}

#[tauri::command(rename_all = "camelCase")]
pub async fn check_deployment(
    session_id: String,
    state: State<'_, AppState>,
) -> CommandResult<DeploymentCheckSnapshot> {
    let repositories = state.repositories.clone();
    let publish = state.publish.clone();
    let lookup_state = publish.clone();
    let context = tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id)?;
        let Ok((status, _, _, remote)) = repository_remote_context(&root) else {
            return Ok(None);
        };
        let Some(branch) = status.branch else {
            return Ok(None);
        };
        let credential = lookup_state.lookup_credential(&root, remote.provider, &remote.host)?;
        Ok(Some((remote, branch, credential)))
    })
    .await
    .map_err(|_| {
        blocking_task_failed("deployment_check_task_failed", "prepare deployment check")
    })??;

    let Some((remote, branch, credential)) = context else {
        return Ok(DeploymentCheckSnapshot::not_configured(
            "仓库没有受支持的 GitHub/GitLab 发布远端或当前分支。",
        ));
    };
    let Some(remote_store) = publish.remote_store.as_ref() else {
        return Ok(DeploymentCheckSnapshot::not_configured(
            "远端部署客户端不可用。",
        ));
    };
    let provider = provider_name(remote.provider).to_string();
    match remote_store
        .check_deployment(
            remote.provider,
            &remote.owner,
            &remote.project,
            &branch,
            credential.as_ref().map(RepositoryCredential::token),
        )
        .await
    {
        Ok(snapshot) => Ok(deployment_view(snapshot)),
        Err(error) => Ok(DeploymentCheckSnapshot {
            configured: true,
            provider: Some(provider),
            status: "unavailable".to_string(),
            url: None,
            summary: "暂时无法读取远端部署状态。".to_string(),
            checked_at: Some(now_rfc3339()?),
            warning: Some(format!("{}: {}", error.code, error.message)),
        }),
    }
}

#[tauri::command(rename_all = "camelCase")]
pub async fn browser_protocol_status(
    session_id: String,
    state: State<'_, AppState>,
) -> CommandResult<ReadinessSnapshot> {
    let repositories = state.repositories.clone();
    let browser_capture = state.browser_capture.clone();
    let browser_capture_warning = state.browser_capture_warning.clone();
    tauri::async_runtime::spawn_blocking(move || {
        repositories.root_for_session(&session_id)?;
        let protocol = BrowserProtocol::load_embedded().map_err(|_| {
            CommandError::new(
                "browser_protocol_incompatible",
                "The embedded browser extension protocol is incompatible.",
            )
        })?;
        let snapshot = protocol.snapshot();
        let bridge = browser_capture.as_ref().map(|service| service.status());
        let ready = snapshot.compatible
            && snapshot.import_capability
            && bridge.as_ref().is_some_and(|status| status.running);
        let warning = snapshot
            .reason
            .or_else(|| bridge.as_ref().and_then(|status| status.warning.clone()))
            .or(browser_capture_warning);
        Ok(ReadinessSnapshot {
            configured: snapshot.compatible,
            ready,
            summary: if ready {
                "浏览器采集协议、本机桥和资料库存储均已就绪。".to_string()
            } else {
                "浏览器采集尚未完全就绪。".to_string()
            },
            warning,
        })
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "browser_protocol_task_failed",
            "inspect the browser protocol",
        )
    })?
}

#[tauri::command]
pub async fn update_readiness() -> CommandResult<ReadinessSnapshot> {
    let kind = current_package_kind();
    let configuration = match (
        option_env!("REPOPRESS_UPDATER_ENDPOINT"),
        option_env!("REPOPRESS_UPDATER_PUBKEY"),
    ) {
        (Some(endpoint), Some(public_key)) => Some(UpdaterConfiguration {
            endpoint,
            public_key,
        }),
        _ => None,
    };
    let has_configuration = configuration.is_some();
    let readiness = inspect_update_readiness(kind, configuration);
    let supports_in_app_updates = matches!(kind, LinuxPackageKind::AppImage);
    Ok(ReadinessSnapshot {
        configured: supports_in_app_updates && has_configuration,
        ready: supports_in_app_updates && readiness.ready,
        summary: readiness.reason.clone(),
        warning: (!(supports_in_app_updates && readiness.ready)).then_some(readiness.reason),
    })
}

impl PublishState {
    fn discover_persisted_credential(&self, root: &Path) -> CommandResult<()> {
        let Ok((_, _, _, remote)) = repository_remote_context(root) else {
            return Ok(());
        };
        if self.has_credential(root, remote.provider, &remote.host)? {
            return Ok(());
        }
        let scope = repository_credential_scope(remote.provider, &remote.host, root)?;
        if self.credential_store.lookup(&scope)?.is_none() {
            return Ok(());
        }
        let credential_id = Uuid::new_v4().to_string();
        self.credential_bindings
            .lock()
            .map_err(|_| publish_state_unavailable())?
            .insert(
                credential_id.clone(),
                CredentialBinding {
                    credential_id,
                    root: root.to_path_buf(),
                    provider: remote.provider,
                    host: remote.host,
                    account: None,
                    username: None,
                    scope,
                    storage: CredentialStorage::SecretService,
                },
            );
        Ok(())
    }

    fn credential_snapshot(&self, root: &Path) -> CommandResult<CredentialStatusSnapshot> {
        let service_available = secret_service_available();
        let bindings = self
            .credential_bindings
            .lock()
            .map_err(|_| publish_state_unavailable())?
            .values()
            .filter(|binding| binding.root == root)
            .cloned()
            .collect::<Vec<_>>();
        let mut credentials = Vec::with_capacity(bindings.len());
        for binding in bindings {
            let storage = self
                .credential_store
                .status(&binding.scope)?
                .map(|status| status.storage)
                .unwrap_or(binding.storage);
            credentials.push(RepositoryCredentialSnapshot {
                credential_id: binding.credential_id.clone(),
                provider: binding.provider,
                host: binding.host.clone(),
                account: binding.account.clone(),
                username: binding.username.clone(),
                storage: storage_view(storage),
            });
        }
        credentials.sort_by(|left, right| {
            (provider_name(left.provider), left.host.as_str())
                .cmp(&(provider_name(right.provider), right.host.as_str()))
        });
        let has_session_only = credentials
            .iter()
            .any(|entry| entry.storage == CredentialStorageView::SessionOnly);
        let storage = if has_session_only || !service_available {
            CredentialStorageView::SessionOnly
        } else {
            CredentialStorageView::SecretService
        };
        Ok(CredentialStatusSnapshot {
            storage,
            secret_service_available: service_available,
            credentials,
            warning: (has_session_only || !service_available).then(|| {
                "系统 Secret Service 不可用；相关令牌仅保存在本次应用会话内。".to_string()
            }),
        })
    }

    fn has_credential(
        &self,
        root: &Path,
        provider: RemoteProvider,
        host: &str,
    ) -> CommandResult<bool> {
        Ok(self
            .credential_bindings
            .lock()
            .map_err(|_| publish_state_unavailable())?
            .values()
            .any(|binding| {
                binding.root == root && binding.provider == provider && binding.host == host
            }))
    }

    fn lookup_credential(
        &self,
        root: &Path,
        provider: RemoteProvider,
        host: &str,
    ) -> CommandResult<Option<RepositoryCredential>> {
        let scope = self
            .credential_bindings
            .lock()
            .map_err(|_| publish_state_unavailable())?
            .values()
            .find(|binding| {
                binding.root == root && binding.provider == provider && binding.host == host
            })
            .map(|binding| binding.scope.clone());
        scope
            .as_ref()
            .map(|scope| self.credential_store.lookup(scope))
            .transpose()
            .map(Option::flatten)
    }
}

impl DeploymentCheckSnapshot {
    fn not_configured(summary: &str) -> Self {
        Self {
            configured: false,
            provider: None,
            status: "unavailable".to_string(),
            url: None,
            summary: summary.to_string(),
            checked_at: None,
            warning: None,
        }
    }
}

fn repository_credential_scope(
    provider: RemoteProvider,
    host: &str,
    root: &Path,
) -> CommandResult<CredentialScope> {
    let digest = Sha256::digest(root.to_string_lossy().as_bytes());
    let repository_key = format!("repo-{digest:x}");
    CredentialScope::new(
        provider_name(provider),
        host,
        &repository_key,
        "access-token",
    )
}

fn storage_view(storage: CredentialStorage) -> CredentialStorageView {
    match storage {
        CredentialStorage::SecretService => CredentialStorageView::SecretService,
        CredentialStorage::ProcessMemory => CredentialStorageView::SessionOnly,
    }
}

fn parse_provider_and_host(value: &str, host: &str) -> CommandResult<RemoteProvider> {
    let provider = match value {
        "github" => RemoteProvider::Github,
        "gitlab" => RemoteProvider::Gitlab,
        _ => {
            return Err(CommandError::new(
                "remote_provider_invalid",
                "Provider must be GitHub or GitLab.",
            ))
        }
    };
    let expected = match provider {
        RemoteProvider::Github => "github.com",
        RemoteProvider::Gitlab => "gitlab.com",
    };
    if host != expected {
        return Err(CommandError::new(
            "remote_host_not_supported",
            "This release supports only the official GitHub and GitLab hosts.",
        ));
    }
    Ok(provider)
}

fn provider_name(provider: RemoteProvider) -> &'static str {
    match provider {
        RemoteProvider::Github => "github",
        RemoteProvider::Gitlab => "gitlab",
    }
}

fn normalized_optional(
    value: Option<String>,
    maximum_bytes: usize,
    code: &str,
) -> CommandResult<Option<String>> {
    let value = value.map(|value| value.trim().to_string());
    match value {
        Some(value)
            if value.len() > maximum_bytes
                || value.contains('\0')
                || value.chars().any(|character| character.is_control()) =>
        {
            Err(CommandError::new(code, "Credential metadata is invalid."))
        }
        Some(value) if value.is_empty() => Ok(None),
        value => Ok(value),
    }
}

fn normalized_branch(value: Option<String>) -> CommandResult<Option<String>> {
    let value = normalized_optional(value, 255, "remote_branch_invalid")?;
    if value.as_deref().is_some_and(|branch| {
        branch.starts_with('-')
            || branch.starts_with('/')
            || branch.ends_with('/')
            || branch.contains("..")
            || branch.contains("@{")
            || branch.bytes().any(|byte| {
                byte <= b' ' || matches!(byte, b'~' | b'^' | b':' | b'?' | b'*' | b'[' | b'\\')
            })
    }) {
        return Err(CommandError::new(
            "remote_branch_invalid",
            "The review branch is invalid.",
        ));
    }
    Ok(value)
}

fn parse_git_operation(value: &str) -> CommandResult<GitPublishOperation> {
    match value {
        "commit" => Ok(GitPublishOperation::Commit),
        "fetch" => Ok(GitPublishOperation::Fetch),
        "push" => Ok(GitPublishOperation::Push),
        _ => Err(CommandError::new(
            "git_operation_invalid",
            "Git operation must be commit, fetch, or push.",
        )),
    }
}

fn default_remote_name(status: &crate::core::GitStatusSnapshot) -> String {
    status
        .upstream
        .as_deref()
        .and_then(|upstream| upstream.split_once('/').map(|(remote, _)| remote))
        .filter(|remote| {
            !remote.is_empty()
                && remote.len() <= 128
                && remote
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        })
        .unwrap_or(PUBLISH_REMOTE_FALLBACK)
        .to_string()
}

fn repository_remote_context(
    root: &Path,
) -> CommandResult<(crate::core::GitStatusSnapshot, String, String, HostedRemote)> {
    let status = read_git_status(root)?;
    if !status.available {
        return Err(CommandError::new(
            "git_repository_required",
            "A Git repository is required for remote publishing.",
        ));
    }
    let remote_name = default_remote_name(&status);
    let remote_url = read_publish_remote_url(root, &remote_name)?;
    let remote = parse_hosted_remote(&remote_url)?;
    Ok((status, remote_name, remote_url, remote))
}

fn parse_hosted_remote(value: &str) -> CommandResult<HostedRemote> {
    let (host, path, transport) = if let Some(rest) = value.strip_prefix("https://") {
        let (host, path) = rest.split_once('/').ok_or_else(remote_url_invalid)?;
        (host, path, GitTransport::Https)
    } else if let Some(rest) = value.strip_prefix("git@") {
        let (host, path) = rest.split_once(':').ok_or_else(remote_url_invalid)?;
        (host, path, GitTransport::Ssh)
    } else if let Some(rest) = value.strip_prefix("ssh://git@") {
        let (host, path) = rest.split_once('/').ok_or_else(remote_url_invalid)?;
        (host, path, GitTransport::Ssh)
    } else {
        return Err(remote_url_invalid());
    };
    let provider = match host {
        "github.com" => RemoteProvider::Github,
        "gitlab.com" => RemoteProvider::Gitlab,
        _ => return Err(remote_url_invalid()),
    };
    let path = path.strip_suffix(".git").unwrap_or(path);
    let segments = path.split('/').collect::<Vec<_>>();
    if segments.len() < 2
        || segments
            .iter()
            .any(|segment| segment.is_empty() || matches!(*segment, "." | ".."))
        || (provider == RemoteProvider::Github && segments.len() != 2)
    {
        return Err(remote_url_invalid());
    }
    let project = segments.last().unwrap_or(&"").to_string();
    let owner = segments[..segments.len() - 1].join("/");
    Ok(HostedRemote {
        provider,
        host: host.to_string(),
        owner,
        project,
        transport,
    })
}

fn remote_url_invalid() -> CommandError {
    CommandError::new(
        "remote_url_invalid",
        "The publish remote is not a supported GitHub or GitLab repository URL.",
    )
}

fn git_plan_description(
    operation: GitPublishOperation,
    staged_files: usize,
) -> (String, Vec<String>) {
    match operation {
        GitPublishOperation::Commit => (
            format!("将提交 {staged_files} 个已暂存文件。"),
            vec!["不会自动暂存文件；Git hooks 与 GPG 签名在此受控操作中禁用。".to_string()],
        ),
        GitPublishOperation::Fetch => (
            "将只更新远端跟踪引用。".to_string(),
            vec!["不会合并、rebase、切换分支、抓取 tags 或更新子模块。".to_string()],
        ),
        GitPublishOperation::Push => (
            "将当前分支推送到同名远端分支。".to_string(),
            vec!["不会强制推送，也不会运行 hooks 或递归推送子模块。".to_string()],
        ),
    }
}

fn push_retry_result_view(receipt: GitPushRetryResult) -> GitPushRetryResultView {
    GitPushRetryResultView {
        branch: receipt.branch,
        head: receipt.head,
        remote_sha: receipt.remote_sha,
        verified: receipt.verified,
        summary: "已确认远端分支精确指向已审阅的冻结提交 SHA。".to_string(),
    }
}

fn deployment_view(snapshot: DeploymentSnapshot) -> DeploymentCheckSnapshot {
    let summary = match snapshot.conclusion.as_deref() {
        Some(conclusion) => format!("{} · {}", snapshot.status, conclusion),
        None => snapshot.status.clone(),
    };
    DeploymentCheckSnapshot {
        configured: true,
        provider: Some(provider_name(snapshot.provider).to_string()),
        status: snapshot.status,
        url: Some(snapshot.web_url),
        summary,
        checked_at: now_rfc3339().ok(),
        warning: None,
    }
}

fn current_package_kind() -> LinuxPackageKind {
    if std::env::var_os("APPIMAGE").is_some() {
        LinuxPackageKind::AppImage
    } else if std::env::current_exe().is_ok_and(|path| path.starts_with("/usr/bin")) {
        LinuxPackageKind::Deb
    } else {
        LinuxPackageKind::Other
    }
}

fn rfc3339_from_millis(value: u128) -> CommandResult<String> {
    let seconds = i64::try_from(value / 1_000).map_err(|_| invalid_clock())?;
    rfc3339_from_unix(seconds)
}

fn rfc3339_from_seconds(value: u64) -> CommandResult<String> {
    let seconds = i64::try_from(value).map_err(|_| invalid_clock())?;
    rfc3339_from_unix(seconds)
}

fn now_rfc3339() -> CommandResult<String> {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .map_err(|_| invalid_clock())
}

fn rfc3339_from_unix(seconds: i64) -> CommandResult<String> {
    OffsetDateTime::from_unix_timestamp(seconds)
        .map_err(|_| invalid_clock())?
        .format(&Rfc3339)
        .map_err(|_| invalid_clock())
}

fn invalid_clock() -> CommandError {
    CommandError::new(
        "publish_clock_invalid",
        "The system clock cannot represent the publish plan expiry.",
    )
}

fn remote_error(error: RemotePublishError) -> CommandError {
    CommandError::new(error.code, error.message)
}

fn publish_state_unavailable() -> CommandError {
    CommandError::new(
        "publish_state_unavailable",
        "Publish state is temporarily unavailable.",
    )
}

fn plan_not_found() -> CommandError {
    CommandError::new(
        "publish_plan_not_found",
        "The reviewed plan is unavailable, expired, or already used.",
    )
}

struct VerificationBinding {
    session_id: String,
    root: PathBuf,
    record: crate::core::PublishRecord,
    created_at: Instant,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PublishVerificationPlanView {
    plan_id: String,
    record_id: String,
    remote_url: String,
    branch: String,
    expected_sha: String,
    expires_at: String,
}
#[tauri::command(rename_all = "camelCase")]
pub async fn list_publish_records(
    session_id: String,
    state: State<'_, AppState>,
) -> CommandResult<Vec<crate::core::PublishRecord>> {
    let repositories = state.repositories.clone();
    let ledger = state.publish_ledger.clone();
    tauri::async_runtime::spawn_blocking(move || {
        ledger.list(&repositories.root_for_session(&session_id)?)
    })
    .await
    .map_err(|_| blocking_task_failed("publish_record_task_failed", "read local push records"))?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn plan_publish_verification(
    session_id: String,
    record_id: String,
    state: State<'_, AppState>,
) -> CommandResult<PublishVerificationPlanView> {
    let repositories = state.repositories.clone();
    let ledger = state.publish_ledger.clone();
    let publish = state.publish.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id)?;
        let record = ledger.get(&root, &record_id)?;
        crate::core::validate_recorded_push_target(&root, &record)?;
        // Only local metadata above. No network or credential lookup on planning.
        let mut bindings = publish
            .verification_bindings
            .lock()
            .map_err(|_| publish_state_unavailable())?;
        bindings
            .retain(|_, binding| binding.created_at.elapsed() < GIT_PUSH_RETRY_BINDING_LIFETIME);
        if bindings.len() >= MAX_GIT_PUSH_RETRY_BINDINGS {
            return Err(publish_state_unavailable());
        }
        let plan_id = Uuid::new_v4().to_string();
        let expires_at = rfc3339_from_millis(
            (OffsetDateTime::now_utc().unix_timestamp_nanos() / 1_000_000) as u128
                + GIT_PUSH_RETRY_BINDING_LIFETIME.as_millis(),
        )?;
        let view = PublishVerificationPlanView {
            plan_id: plan_id.clone(),
            record_id,
            remote_url: record.evidence.remote_url.clone(),
            branch: record.evidence.branch.clone(),
            expected_sha: record.evidence.expected_sha.clone(),
            expires_at,
        };
        bindings.insert(
            plan_id,
            VerificationBinding {
                session_id,
                root,
                record,
                created_at: Instant::now(),
            },
        );
        Ok(view)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "publish_record_task_failed",
            "prepare read-only verification",
        )
    })?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn execute_publish_verification(
    session_id: String,
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<crate::core::PublishRecord> {
    let repositories = state.repositories.clone();
    let ledger = state.publish_ledger.clone();
    let publish = state.publish.clone();
    tauri::async_runtime::spawn_blocking(move || {
        // One-use even on expiry, credential failure, and changed repository.
        let binding = publish
            .verification_bindings
            .lock()
            .map_err(|_| publish_state_unavailable())?
            .remove(&plan_id)
            .ok_or_else(plan_not_found)?;
        let root = repositories.root_for_session(&session_id)?;
        if binding.session_id != session_id
            || binding.root != root
            || binding.created_at.elapsed() >= GIT_PUSH_RETRY_BINDING_LIFETIME
        {
            return Err(plan_not_found());
        }
        crate::core::validate_recorded_push_target(&root, &binding.record)?;
        let remote = parse_hosted_remote(&binding.record.evidence.remote_url)?;
        let credential = if remote.transport == GitTransport::Https {
            publish.lookup_credential(&root, remote.provider, &remote.host)?
        } else {
            None
        };
        ledger.verify(&binding.record, || {
            crate::core::observe_recorded_push(&root, &binding.record, credential.as_ref())
        })
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "publish_record_task_failed",
            "verify the remote branch without pushing",
        )
    })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn remove_publish_record(
    session_id: String,
    record_id: String,
    revision: u64,
    state: State<'_, AppState>,
) -> CommandResult<Vec<crate::core::PublishRecord>> {
    let repositories = state.repositories.clone();
    let ledger = state.publish_ledger.clone();
    tauri::async_runtime::spawn_blocking(move || {
        ledger.remove_checked(
            &repositories.root_for_session(&session_id)?,
            &record_id,
            revision,
        )
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "publish_record_task_failed",
            "remove the reviewed local push record",
        )
    })?
}

struct ReviewVerificationBinding {
    session_id: String,
    root: PathBuf,
    record: crate::core::RemoteReviewRecord,
    created_at: Instant,
}

#[tauri::command(rename_all = "camelCase")]
pub async fn plan_rollback_candidate(
    session_id: String,
    record_id: String,
    revision: u64,
    state: State<'_, AppState>,
) -> CommandResult<crate::core::RollbackCandidatePlan> {
    let repositories = state.repositories.clone();
    let ledger = state.publish_ledger.clone();
    let candidates = state.rollback_candidate.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id)?;
        let view = candidates.plan(&session_id, &root, &ledger, &record_id, revision)?;
        if repositories.root_for_session(&session_id).ok().as_ref() != Some(&root) {
            if let Some(id) = &view.plan_id {
                let _ = candidates.discard(&session_id, id);
            }
            return Err(CommandError::new(
                "rollback_candidate_changed",
                "Repository session changed; prepare again.",
            ));
        }
        Ok(view)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "rollback_candidate_task_failed",
            "prepare local inverse candidate",
        )
    })?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn generate_rollback_candidate(
    session_id: String,
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<crate::core::RollbackCandidateReport> {
    let repositories = state.repositories.clone();
    let ledger = state.publish_ledger.clone();
    let candidates = state.rollback_candidate.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id);
        let expected_root = root.as_ref().ok().cloned();
        let view = candidates.generate(&session_id, root, &ledger, &plan_id)?;
        if repositories.root_for_session(&session_id).ok() != expected_root {
            return Err(CommandError::new(
                "rollback_candidate_changed",
                "Repository session changed; prepare again.",
            ));
        }
        Ok(view)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "rollback_candidate_task_failed",
            "generate local inverse candidate",
        )
    })?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn discard_rollback_candidate(
    session_id: String,
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<()> {
    // Removing an in-memory plan needs no filesystem session lookup.
    state.rollback_candidate.discard(&session_id, &plan_id)
}

#[tauri::command(rename_all = "camelCase")]
pub async fn inspect_rollback_changes(
    session_id: String,
    record_id: String,
    revision: u64,
    state: State<'_, AppState>,
) -> CommandResult<crate::core::RollbackChangePreview> {
    let repositories = state.repositories.clone();
    let ledger = state.publish_ledger.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id)?;
        let view = crate::core::inspect_rollback_changes(
            &session_id,
            &root,
            &ledger,
            &record_id,
            revision,
        )?;
        if repositories.root_for_session(&session_id)? != root {
            return Err(CommandError::new(
                "rollback_preview_changed",
                "Repository session changed; inspect again.",
            ));
        }
        Ok(view)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "rollback_preview_task_failed",
            "read local single-commit changes",
        )
    })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn plan_rollback_qualification(
    session_id: String,
    record_id: String,
    revision: u64,
    state: State<'_, AppState>,
) -> CommandResult<crate::core::RollbackQualificationPlan> {
    let repositories = state.repositories.clone();
    let ledger = state.publish_ledger.clone();
    let qualifications = state.rollback_qualification.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id)?;
        let result = qualifications.plan(&session_id, &root, &ledger, &record_id, revision)?;
        if repositories.root_for_session(&session_id)? != root {
            return Err(CommandError::new(
                "rollback_qualification_plan_invalid",
                "Repository session changed; inspect again.",
            ));
        }
        Ok(result)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "rollback_qualification_task_failed",
            "inspect local rollback conditions",
        )
    })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn check_rollback_qualification(
    session_id: String,
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<crate::core::RollbackQualificationReport> {
    let repositories = state.repositories.clone();
    let ledger = state.publish_ledger.clone();
    let qualifications = state.rollback_qualification.clone();
    let publish = state.publish.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id);
        let result =
            qualifications.check(&session_id, root.clone(), &ledger, &plan_id, |record| {
                let root = root.as_ref().map_err(Clone::clone)?;
                if repositories.root_for_session(&session_id)? != *root {
                    return Err(CommandError::new(
                        "rollback_qualification_plan_invalid",
                        "Repository session changed; inspect again.",
                    ));
                }
                // Credential lookup is reachable only after the store consumes and
                // revalidates the reviewed candidate. The observer is ls-remote only.
                let remote = parse_hosted_remote(&record.evidence.remote_url)?;
                let credential = if remote.transport == GitTransport::Https {
                    publish.lookup_credential(root, remote.provider, &remote.host)?
                } else {
                    None
                };
                crate::core::observe_recorded_push(root, record, credential.as_ref())
            })?;
        if repositories.root_for_session(&session_id)? != root? {
            return Err(CommandError::new(
                "rollback_qualification_plan_invalid",
                "Repository session changed; inspect again.",
            ));
        }
        Ok(result)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "rollback_qualification_task_failed",
            "query read-only rollback conditions",
        )
    })?
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteReviewVerificationPlanView {
    plan_id: String,
    record_id: String,
    remote_url: String,
    provider: RemoteProvider,
    owner: String,
    project: String,
    source_branch: String,
    target_branch: String,
    source_sha: String,
    expires_at: String,
}
#[tauri::command(rename_all = "camelCase")]
pub async fn list_remote_review_records(
    session_id: String,
    state: State<'_, AppState>,
) -> CommandResult<Vec<crate::core::RemoteReviewRecord>> {
    let repositories = state.repositories.clone();
    let ledger = state.remote_review_ledger.clone();
    tauri::async_runtime::spawn_blocking(move || {
        ledger.list(&repositories.root_for_session(&session_id)?)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "remote_review_record_task_failed",
            "read local PR/MR records",
        )
    })?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn plan_remote_review_verification(
    session_id: String,
    record_id: String,
    state: State<'_, AppState>,
) -> CommandResult<RemoteReviewVerificationPlanView> {
    let repositories = state.repositories.clone();
    let ledger = state.remote_review_ledger.clone();
    let publish = state.publish.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id)?;
        let record = ledger.get(&root, &record_id)?;
        crate::core::validate_review_repository(&record.evidence, false)?;
        let mut bindings = publish
            .review_verification_bindings
            .lock()
            .map_err(|_| publish_state_unavailable())?;
        bindings
            .retain(|_, binding| binding.created_at.elapsed() < GIT_PUSH_RETRY_BINDING_LIFETIME);
        if bindings.len() >= MAX_GIT_PUSH_RETRY_BINDINGS {
            return Err(publish_state_unavailable());
        }
        let plan_id = Uuid::new_v4().to_string();
        let e = &record.evidence;
        let view = RemoteReviewVerificationPlanView {
            plan_id: plan_id.clone(),
            record_id,
            remote_url: e.remote_url.clone(),
            provider: e.provider,
            owner: e.owner.clone(),
            project: e.project.clone(),
            source_branch: e.source_branch.clone(),
            target_branch: e.target_branch.clone(),
            source_sha: e.source_sha.clone(),
            expires_at: rfc3339_from_millis(
                (OffsetDateTime::now_utc().unix_timestamp_nanos() / 1_000_000) as u128
                    + GIT_PUSH_RETRY_BINDING_LIFETIME.as_millis(),
            )?,
        };
        bindings.insert(
            plan_id,
            ReviewVerificationBinding {
                session_id,
                root,
                record,
                created_at: Instant::now(),
            },
        );
        Ok(view)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "remote_review_record_task_failed",
            "plan read-only PR/MR verification",
        )
    })?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn execute_remote_review_verification(
    session_id: String,
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<crate::core::RemoteReviewRecord> {
    let repositories = state.repositories.clone();
    let publish = state.publish.clone();
    let lookup = publish.clone();
    let ledger = state.remote_review_ledger.clone();
    let (binding, credential) = tauri::async_runtime::spawn_blocking(move || {
        let binding = lookup
            .review_verification_bindings
            .lock()
            .map_err(|_| publish_state_unavailable())?
            .remove(&plan_id)
            .ok_or_else(plan_not_found)?;
        let root = repositories.root_for_session(&session_id)?;
        if binding.session_id != session_id
            || binding.root != root
            || binding.created_at.elapsed() >= GIT_PUSH_RETRY_BINDING_LIFETIME
        {
            return Err(plan_not_found());
        }
        crate::core::validate_review_repository(&binding.record.evidence, false)?;
        let remote = parse_hosted_remote(&binding.record.evidence.remote_url)?;
        let credential = lookup
            .lookup_credential(&root, remote.provider, &remote.host)?
            .ok_or_else(|| {
                CommandError::new(
                    "remote_credential_required",
                    "Save a repository credential to verify its PR/MR record.",
                )
            })?;
        Ok((binding, credential))
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "remote_review_record_task_failed",
            "prepare read-only PR/MR verification",
        )
    })??;
    let lease = ledger.acquire(&binding.record)?;
    crate::core::validate_review_repository(&binding.record.evidence, false)?;
    let client = publish
        .remote_store
        .as_ref()
        .ok_or_else(publish_state_unavailable)?;
    let observation = client
        .observe_review(&binding.record, credential.token())
        .await;
    let (status, receipt) =
        if crate::core::validate_review_repository(&binding.record.evidence, false).is_ok() {
            observation.unwrap_or((crate::core::ReviewVerification::Unavailable, None))
        } else {
            (crate::core::ReviewVerification::Unavailable, None)
        };
    lease.finish(status, receipt)
}
#[tauri::command(rename_all = "camelCase")]
pub async fn remove_remote_review_record(
    session_id: String,
    record_id: String,
    revision: u64,
    state: State<'_, AppState>,
) -> CommandResult<Vec<crate::core::RemoteReviewRecord>> {
    let repositories = state.repositories.clone();
    let ledger = state.remote_review_ledger.clone();
    tauri::async_runtime::spawn_blocking(move || {
        ledger.remove(
            &repositories.root_for_session(&session_id)?,
            &record_id,
            revision,
        )
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "remote_review_record_task_failed",
            "remove the reviewed local PR/MR record",
        )
    })?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_only_supported_hosted_repository_urls() {
        let github = parse_hosted_remote("https://github.com/owner/project.git").unwrap();
        assert_eq!(github.provider, RemoteProvider::Github);
        assert_eq!(github.owner, "owner");
        assert_eq!(github.project, "project");
        assert_eq!(github.transport, GitTransport::Https);

        let gitlab = parse_hosted_remote("git@gitlab.com:group/subgroup/project.git").unwrap();
        assert_eq!(gitlab.provider, RemoteProvider::Gitlab);
        assert_eq!(gitlab.owner, "group/subgroup");
        assert_eq!(gitlab.project, "project");
        assert_eq!(gitlab.transport, GitTransport::Ssh);

        assert!(parse_hosted_remote("https://github.com.evil.test/owner/project").is_err());
        assert!(parse_hosted_remote("https://github.com/owner/extra/project").is_err());
        assert!(parse_hosted_remote("file:///tmp/project").is_err());
    }

    #[test]
    fn formats_expiry_as_browser_parseable_rfc3339() {
        assert_eq!(
            rfc3339_from_seconds(1_700_000_000).unwrap(),
            "2023-11-14T22:13:20Z"
        );
    }

    #[test]
    fn capability_storage_names_match_the_frontend_contract() {
        assert_eq!(
            serde_json::to_string(&CredentialStorageView::SecretService).unwrap(),
            "\"secret_service\""
        );
        assert_eq!(
            serde_json::to_string(&CredentialStorageView::SessionOnly).unwrap(),
            "\"session_only\""
        );
    }
}

// P38: credentials are resolved only inside explicitly requested network steps.
fn rollback_network_credential(
    publish: &PublishState,
    root: &Path,
    source: &crate::core::PublishRecord,
) -> CommandResult<Option<RepositoryCredential>> {
    crate::core::validate_recorded_push_target(root, source)?;
    let remote = parse_hosted_remote(&source.evidence.remote_url)?;
    if remote.transport == GitTransport::Https {
        publish.lookup_credential(root, remote.provider, &remote.host)
    } else {
        Ok(None)
    }
}
#[tauri::command(rename_all = "camelCase")]
pub async fn plan_rollback_transaction(
    session_id: String,
    record_id: String,
    revision: u64,
    state: State<'_, AppState>,
) -> CommandResult<crate::core::RollbackTransactionPlan> {
    let repositories = state.repositories.clone();
    let pushes = state.publish_ledger.clone();
    let transactions = state.rollback_transaction.clone();
    let publish = state.publish.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id)?;
        let result = transactions.plan(
            &session_id,
            &root,
            &pushes,
            &record_id,
            revision,
            |source| {
                if repositories.root_for_session(&session_id)? != root {
                    return Err(plan_not_found());
                }
                let credential = rollback_network_credential(&publish, &root, source)?;
                crate::core::observe_recorded_push(&root, source, credential.as_ref())
            },
        )?;
        if repositories.root_for_session(&session_id)? != root {
            if let Some(id) = &result.plan_id {
                let _ = transactions.discard(&session_id, id);
            }
            return Err(plan_not_found());
        }
        Ok(result)
    })
    .await
    .map_err(|_| blocking_task_failed("rollback_task_failed", "prepare remote rollback"))?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn execute_rollback_transaction(
    session_id: String,
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<crate::core::RollbackRecord> {
    let repositories = state.repositories.clone();
    let pushes = state.publish_ledger.clone();
    let transactions = state.rollback_transaction.clone();
    let publish = state.publish.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id);
        let session_current = || -> CommandResult<()> {
            if repositories.root_for_session(&session_id)?
                != *root.as_ref().map_err(Clone::clone)?
            {
                return Err(plan_not_found());
            }
            Ok(())
        };
        let result = transactions.execute(
            &session_id,
            root.clone(),
            &pushes,
            &plan_id,
            |source| {
                session_current()?;
                let root = root.as_ref().map_err(Clone::clone)?;
                let credential = rollback_network_credential(&publish, root, source)?;
                crate::core::observe_recorded_push(root, source, credential.as_ref())
            },
            |isolated, receipt, gate| {
                session_current()?;
                let root = root.as_ref().map_err(Clone::clone)?;
                let credential = rollback_network_credential(&publish, root, &receipt.source)?;
                crate::core::push_rollback_candidate(
                    root,
                    isolated,
                    receipt,
                    credential.as_ref(),
                    || {
                        session_current()?;
                        gate()
                    },
                )
            },
        )?;
        session_current()?;
        Ok(result)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "rollback_task_failed",
            "execute rollback; inspect durable evidence before any further action",
        )
    })?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn discard_rollback_transaction(
    session_id: String,
    plan_id: String,
    state: State<'_, AppState>,
) -> CommandResult<()> {
    state.rollback_transaction.discard(&session_id, &plan_id)
}
#[tauri::command(rename_all = "camelCase")]
pub async fn list_rollback_records(
    session_id: String,
    state: State<'_, AppState>,
) -> CommandResult<Vec<crate::core::RollbackRecord>> {
    let repositories = state.repositories.clone();
    let transactions = state.rollback_transaction.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id)?;
        let records = transactions.list(&root)?;
        if repositories.root_for_session(&session_id)? != root {
            return Err(plan_not_found());
        }
        Ok(records)
    })
    .await
    .map_err(|_| blocking_task_failed("rollback_task_failed", "read local rollback evidence"))?
}
#[tauri::command(rename_all = "camelCase")]
pub async fn verify_rollback_record(
    session_id: String,
    record_id: String,
    revision: u64,
    state: State<'_, AppState>,
) -> CommandResult<crate::core::RollbackRecord> {
    let repositories = state.repositories.clone();
    let transactions = state.rollback_transaction.clone();
    let publish = state.publish.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let root = repositories.root_for_session(&session_id)?;
        let result = transactions.verify(&root, &record_id, revision, |source| {
            if repositories.root_for_session(&session_id)? != root {
                return Err(plan_not_found());
            }
            let credential = rollback_network_credential(&publish, &root, source)?;
            crate::core::observe_recorded_push(&root, source, credential.as_ref())
        })?;
        if repositories.root_for_session(&session_id)? != root {
            return Err(plan_not_found());
        }
        Ok(result)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "rollback_task_failed",
            "query the remote branch without retrying rollback",
        )
    })?
}
