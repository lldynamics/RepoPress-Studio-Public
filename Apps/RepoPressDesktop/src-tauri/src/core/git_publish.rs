//! Deliberately narrow Git mutation API.  A caller first obtains a short-lived
//! reviewed plan, then explicitly confirms its one-time execution.

use super::{
    CommandError, CommandResult, PublishEvidence, PublishLedgerStore, PublishRecord, PushOperation,
    RepositoryCredential,
};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::{BTreeSet, HashMap};
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

const PLAN_LIFETIME: Duration = Duration::from_secs(5 * 60);
const GIT_TIMEOUT: Duration = Duration::from_secs(20);
const MAX_GIT_OUTPUT: usize = 128 * 1024;
const MAX_MESSAGE_BYTES: usize = 4 * 1024;
const MAX_PUSH_RETRY_PLANS: usize = 32;
const MAX_PUSH_RETRY_COMMITS: usize = 10_000;
const MAX_PUSH_RETRY_PATHS: usize = 1_000;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum GitPublishOperation {
    Commit,
    Fetch,
    Push,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitPublishPlan {
    pub plan_id: String,
    pub operation: GitPublishOperation,
    pub session_id: String,
    pub summary: GitPublishSummary,
    pub expires_at_unix_ms: u128,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitPublishSummary {
    pub head: String,
    pub branch: Option<String>,
    pub remote: Option<String>,
    pub remote_url: Option<String>,
    pub staged_tree: Option<String>,
    pub message_preview: Option<String>,
    pub baseline_digest: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitPublishReceipt {
    pub plan_id: String,
    pub operation: GitPublishOperation,
    pub completed_at_unix_ms: u128,
    pub revision: Option<String>,
    pub summary: GitPublishSummary,
}

/// A bounded review of commits that are already local but absent from the live
/// push remote.  This intentionally does not reuse the generic push plan: it
/// performs a live remote check and binds that observation into its own plan.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitPushRetryPlan {
    pub plan_id: String,
    pub session_id: String,
    pub branch: String,
    pub head: String,
    pub remote: String,
    pub remote_url: String,
    pub observed_remote_sha: String,
    pub pending_commit_count: usize,
    pub changed_paths: Vec<String>,
    pub expires_at_unix_ms: u128,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitPushRetryResult {
    pub plan_id: String,
    pub branch: String,
    pub head: String,
    pub remote_sha: String,
    pub verified: bool,
    pub completed_at_unix_ms: u128,
}

#[derive(Clone)]
struct Baseline {
    head: String,
    branch: Option<String>,
    index_digest: String,
    remote_digest: Option<String>,
}

struct PlannedOperation {
    push_identity: Option<String>,
    root: PathBuf,
    session_id: String,
    operation: GitPublishOperation,
    message: Option<String>,
    remote: Option<String>,
    remote_url: Option<String>,
    baseline: Baseline,
    summary: GitPublishSummary,
    expires_at: SystemTime,
}

#[derive(Clone)]
struct PushRetryBaseline {
    root_identity: DirectoryIdentity,
    git_common_directory: PathBuf,
    git_common_directory_identity: DirectoryIdentity,
    object_format: String,
    head: String,
    branch: String,
    index_digest: String,
    worktree_digest: String,
    remote_url: String,
    observed_remote_sha: String,
}

struct NetworkIsolation {
    _directory: tempfile::TempDir,
    root: PathBuf,
}

#[cfg(unix)]
#[derive(Clone, Debug, Eq, PartialEq)]
struct DirectoryIdentity {
    device: u64,
    inode: u64,
}

struct PlannedPushRetry {
    root: PathBuf,
    session_id: String,
    remote: String,
    baseline: PushRetryBaseline,
    changed_paths: Vec<String>,
    pending_commit_count: usize,
    expires_at: SystemTime,
}

#[derive(Default)]
pub struct GitPublishStore {
    plans: Mutex<HashMap<String, PlannedOperation>>,
    retry_plans: Mutex<HashMap<String, PlannedPushRetry>>,
}

impl GitPublishStore {
    pub fn plan_commit(
        &self,
        session_id: &str,
        root: &Path,
        message: &str,
    ) -> CommandResult<GitPublishPlan> {
        validate_session(session_id)?;
        validate_message(message)?;
        let root = validate_root(root)?;
        let baseline = capture_baseline(&root, None)?;
        ensure_staged_changes(&root)?;
        ensure_local_commit_identity(&root)?;
        let summary = GitPublishSummary {
            head: baseline.head.clone(),
            branch: baseline.branch.clone(),
            remote: None,
            remote_url: None,
            staged_tree: Some(baseline.index_digest.clone()),
            message_preview: Some(message.to_string()),
            baseline_digest: baseline_digest(&baseline),
        };
        self.insert_plan(
            session_id,
            root,
            GitPublishOperation::Commit,
            Some(message.to_string()),
            None,
            None,
            baseline,
            summary,
        )
    }

    pub fn plan_fetch(
        &self,
        session_id: &str,
        root: &Path,
        remote: &str,
    ) -> CommandResult<GitPublishPlan> {
        self.plan_remote(session_id, root, remote, GitPublishOperation::Fetch)
    }

    pub fn plan_push(
        &self,
        session_id: &str,
        root: &Path,
        remote: &str,
    ) -> CommandResult<GitPublishPlan> {
        self.plan_remote(session_id, root, remote, GitPublishOperation::Push)
    }

    fn plan_remote(
        &self,
        session_id: &str,
        root: &Path,
        remote: &str,
        operation: GitPublishOperation,
    ) -> CommandResult<GitPublishPlan> {
        validate_session(session_id)?;
        validate_remote_name(remote)?;
        let root = validate_root(root)?;
        let url = if operation == GitPublishOperation::Push {
            retry_push_remote_url(&root, remote)?
        } else {
            remote_url(&root, remote)?
        };
        validate_remote_url(&url)?;
        let baseline = capture_baseline(&root, Some(remote))?;
        if operation == GitPublishOperation::Push && baseline.branch.is_none() {
            return Err(CommandError::new(
                "git_push_detached_head",
                "Push requires a checked-out branch.",
            ));
        }
        let summary = GitPublishSummary {
            head: baseline.head.clone(),
            branch: baseline.branch.clone(),
            remote: Some(remote.to_string()),
            remote_url: Some(url.clone()),
            staged_tree: None,
            message_preview: None,
            baseline_digest: baseline_digest(&baseline),
        };
        self.insert_plan(
            session_id,
            root,
            operation,
            None,
            Some(remote.to_string()),
            Some(url),
            baseline,
            summary,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn insert_plan(
        &self,
        session_id: &str,
        root: PathBuf,
        operation: GitPublishOperation,
        message: Option<String>,
        remote: Option<String>,
        remote_url: Option<String>,
        baseline: Baseline,
        summary: GitPublishSummary,
    ) -> CommandResult<GitPublishPlan> {
        let plan_id = Uuid::new_v4().to_string();
        let expires_at = SystemTime::now() + PLAN_LIFETIME;
        let plan = GitPublishPlan {
            plan_id: plan_id.clone(),
            operation,
            session_id: session_id.to_string(),
            summary: summary.clone(),
            expires_at_unix_ms: millis(expires_at)?,
        };
        let mut plans = self.plans.lock().map_err(|_| plans_unavailable())?;
        plans.retain(|_, entry| entry.expires_at > SystemTime::now());
        let push_identity = if operation == GitPublishOperation::Push {
            Some(repository_identity_for_root(&root)?)
        } else {
            None
        };
        plans.insert(
            plan_id,
            PlannedOperation {
                push_identity,
                root,
                session_id: session_id.to_string(),
                operation,
                message,
                remote,
                remote_url,
                baseline,
                summary,
                expires_at,
            },
        );
        Ok(plan)
    }

    /// `confirmed` must come from an explicit final user acknowledgement.  Once it
    /// is accepted the plan is removed before any Git process starts, including if
    /// revalidation later rejects it.
    #[cfg(test)]
    pub fn execute(
        &self,
        plan_id: &str,
        session_id: &str,
        confirmed: bool,
        credential: Option<&RepositoryCredential>,
    ) -> CommandResult<GitPublishReceipt> {
        self.execute_inner(plan_id, session_id, confirmed, credential, None)
    }
    pub fn execute_recorded(
        &self,
        plan_id: &str,
        session_id: &str,
        confirmed: bool,
        credential: Option<&RepositoryCredential>,
        ledger: &PublishLedgerStore,
    ) -> CommandResult<GitPublishReceipt> {
        self.execute_inner(plan_id, session_id, confirmed, credential, Some(ledger))
    }
    fn execute_inner(
        &self,
        plan_id: &str,
        session_id: &str,
        confirmed: bool,
        credential: Option<&RepositoryCredential>,
        ledger: Option<&PublishLedgerStore>,
    ) -> CommandResult<GitPublishReceipt> {
        if !confirmed {
            return Err(CommandError::new(
                "git_publish_confirmation_required",
                "A final confirmation is required.",
            ));
        }
        validate_plan_id(plan_id)?;
        validate_session(session_id)?;
        let plan = {
            let mut plans = self.plans.lock().map_err(|_| plans_unavailable())?;
            let Some(plan) = plans.remove(plan_id) else {
                return Err(CommandError::new(
                    "git_publish_plan_not_found",
                    "The publish plan is unavailable or has already been used.",
                ));
            };
            plan
        };
        if plan.expires_at <= SystemTime::now() {
            return Err(CommandError::new(
                "git_publish_plan_expired",
                "The publish plan expired; review a new plan.",
            ));
        }
        if plan.session_id != session_id {
            return Err(CommandError::new(
                "git_publish_session_mismatch",
                "The publish plan belongs to another repository session.",
            ));
        }
        let root = validate_root(&plan.root)?;
        if let Some(remote) = plan.remote.as_deref() {
            let current_url = if plan.operation == GitPublishOperation::Push {
                retry_push_remote_url(&root, remote)?
            } else {
                remote_url(&root, remote)?
            };
            if plan.remote_url.as_deref() != Some(current_url.as_str())
                || validate_remote_url(&current_url).is_err()
            {
                return Err(CommandError::new(
                    "git_publish_baseline_changed",
                    "Repository state changed; review a new plan.",
                ));
            }
        }
        let current = capture_baseline(&root, plan.remote.as_deref())?;
        if !same_baseline(&plan.baseline, &current) {
            return Err(CommandError::new(
                "git_publish_baseline_changed",
                "Repository state changed; review a new plan.",
            ));
        }
        match plan.operation {
            GitPublishOperation::Commit => {
                if credential.is_some() {
                    return Err(CommandError::new(
                        "git_credential_not_applicable",
                        "Credentials cannot be used for a local commit.",
                    ));
                }
                ensure_staged_changes(&root)?;
                let message = plan.message.as_deref().ok_or_else(|| {
                    CommandError::new("git_publish_plan_invalid", "Commit plan is invalid.")
                })?;
                let output = run_git(
                    &root,
                    &["commit", "--no-verify", "--no-gpg-sign", "-m", message],
                    None,
                    None,
                )?;
                ensure_git_success(&output, "git_commit_failed")?;
                let revision = git_text(&root, &["rev-parse", "HEAD"])?;
                Ok(receipt(
                    plan_id,
                    plan.operation,
                    Some(revision),
                    plan.summary,
                ))
            }
            GitPublishOperation::Fetch => {
                let remote = plan.remote.as_deref().ok_or_else(invalid_plan)?;
                let url = plan.remote_url.as_deref().ok_or_else(invalid_plan)?;
                let authentication = auth_for_url(url, credential)?;
                // A refspec only writes remote-tracking refs. It cannot merge, rebase,
                // alter HEAD, or fetch tags/submodules.
                let refspec = format!("+refs/heads/*:refs/remotes/{remote}/*");
                let output = run_git(
                    &root,
                    &[
                        "fetch",
                        "--no-tags",
                        "--no-recurse-submodules",
                        "--no-write-fetch-head",
                        "--upload-pack=git-upload-pack",
                        remote,
                        &refspec,
                    ],
                    authentication,
                    Some(remote),
                )?;
                ensure_git_success(&output, "git_fetch_failed")?;
                Ok(receipt(plan_id, plan.operation, None, plan.summary))
            }
            GitPublishOperation::Push => {
                let remote = plan.remote.as_deref().ok_or_else(invalid_plan)?;
                let url = plan.remote_url.as_deref().ok_or_else(invalid_plan)?;
                let branch = plan.baseline.branch.as_deref().ok_or_else(invalid_plan)?;
                validate_branch(branch)?;
                if plan.push_identity.as_deref() != Some(&repository_identity_for_root(&root)?) {
                    return Err(CommandError::new(
                        "git_publish_baseline_changed",
                        "Repository identity changed since review.",
                    ));
                }
                let baseline = network_baseline(&root, remote, &plan.baseline.head, branch)?;
                if baseline.remote_url != url {
                    return Err(invalid_plan());
                }
                let isolation = network_isolation(&baseline)?;
                let evidence =
                    push_evidence(&root, remote, &baseline, PushOperation::Push, Vec::new());
                run_recorded_push(&isolation, plan_id, evidence, credential, ledger)?;
                Ok(receipt(
                    plan_id,
                    plan.operation,
                    Some(plan.baseline.head),
                    plan.summary,
                ))
            }
        }
    }

    #[cfg(test)]
    pub fn plan_push_retry(
        &self,
        session_id: &str,
        root: &Path,
        remote: &str,
        credential: Option<&RepositoryCredential>,
    ) -> CommandResult<GitPushRetryPlan> {
        validate_session(session_id)?;
        validate_remote_name(remote)?;
        let root = validate_root(root)?;
        let expected_url = retry_push_remote_url(&root, remote)?;
        self.plan_push_retry_for_url(session_id, &root, remote, &expected_url, credential)
    }

    pub fn plan_push_retry_for_url(
        &self,
        session_id: &str,
        root: &Path,
        remote: &str,
        expected_url: &str,
        credential: Option<&RepositoryCredential>,
    ) -> CommandResult<GitPushRetryPlan> {
        validate_session(session_id)?;
        validate_remote_name(remote)?;
        let root = validate_root(root)?;
        validate_remote_url(expected_url)?;
        let snapshot = inspect_push_retry(&root, remote, Some(expected_url), None, credential)?;
        let plan_id = Uuid::new_v4().to_string();
        let expires_at = SystemTime::now() + PLAN_LIFETIME;
        let plan = GitPushRetryPlan {
            plan_id: plan_id.clone(),
            session_id: session_id.to_string(),
            branch: snapshot.baseline.branch.clone(),
            head: snapshot.baseline.head.clone(),
            remote: remote.to_string(),
            remote_url: snapshot.baseline.remote_url.clone(),
            observed_remote_sha: snapshot.baseline.observed_remote_sha.clone(),
            pending_commit_count: snapshot.pending_commit_count,
            changed_paths: snapshot.changed_paths.clone(),
            expires_at_unix_ms: millis(expires_at)?,
        };
        let mut plans = self.retry_plans.lock().map_err(|_| plans_unavailable())?;
        let now = SystemTime::now();
        plans.retain(|_, entry| entry.expires_at > now);
        if plans.len() >= MAX_PUSH_RETRY_PLANS {
            return Err(CommandError::new(
                "git_push_retry_plan_limit",
                "Too many pending push retry plans; review or wait for an existing plan to expire.",
            ));
        }
        plans.insert(
            plan_id,
            PlannedPushRetry {
                root,
                session_id: session_id.to_string(),
                remote: remote.to_string(),
                baseline: snapshot.baseline,
                changed_paths: snapshot.changed_paths,
                pending_commit_count: snapshot.pending_commit_count,
                expires_at,
            },
        );
        Ok(plan)
    }

    /// Executes only an already reviewed retry.  Any attempt that cannot be
    /// followed by an exact live-remote confirmation is deliberately reported
    /// as unknown, rather than encouraging a blind second push.
    #[cfg(test)]
    pub fn execute_push_retry(
        &self,
        plan_id: &str,
        session_id: &str,
        credential: Option<&RepositoryCredential>,
    ) -> CommandResult<GitPushRetryResult> {
        self.execute_push_retry_inner(plan_id, session_id, credential, None)
    }
    pub fn execute_push_retry_recorded(
        &self,
        plan_id: &str,
        session_id: &str,
        credential: Option<&RepositoryCredential>,
        ledger: &PublishLedgerStore,
    ) -> CommandResult<GitPushRetryResult> {
        self.execute_push_retry_inner(plan_id, session_id, credential, Some(ledger))
    }
    fn execute_push_retry_inner(
        &self,
        plan_id: &str,
        session_id: &str,
        credential: Option<&RepositoryCredential>,
        ledger: Option<&PublishLedgerStore>,
    ) -> CommandResult<GitPushRetryResult> {
        validate_plan_id(plan_id)?;
        validate_session(session_id)?;
        let plan = {
            let mut plans = self.retry_plans.lock().map_err(|_| plans_unavailable())?;
            plans.remove(plan_id).ok_or_else(|| {
                CommandError::new(
                    "git_push_retry_plan_not_found",
                    "The push retry plan is unavailable or has already been used.",
                )
            })?
        };
        if plan.expires_at <= SystemTime::now() {
            return Err(CommandError::new(
                "git_push_retry_plan_expired",
                "The push retry plan expired; inspect the remote again.",
            ));
        }
        if plan.session_id != session_id {
            return Err(CommandError::new(
                "git_push_retry_session_mismatch",
                "The push retry plan belongs to another repository session.",
            ));
        }
        let root = validate_root(&plan.root)?;
        // Do not contact a newly configured destination. Local identity, HEAD,
        // index/worktree state, and the one literal push URL must first match the
        // reviewed plan.
        let local = inspect_push_retry_local(&root, &plan.remote)?;
        if !same_push_retry_local_baseline(&plan.baseline, &local) {
            return Err(CommandError::new(
                "git_push_retry_baseline_changed",
                "Repository or push URL changed; inspect a new push retry plan.",
            ));
        }
        let current = inspect_push_retry(
            &root,
            &plan.remote,
            Some(&plan.baseline.remote_url),
            Some(&plan.baseline),
            credential,
        )?;
        if !same_push_retry_baseline(&plan.baseline, &current.baseline)
            || plan.changed_paths != current.changed_paths
            || plan.pending_commit_count != current.pending_commit_count
        {
            return Err(CommandError::new(
                "git_push_retry_baseline_changed",
                "Repository or remote state changed; inspect a new push retry plan.",
            ));
        }
        let isolation = network_isolation(&plan.baseline)?;
        let evidence = push_evidence(
            &root,
            &plan.remote,
            &plan.baseline,
            PushOperation::PushRetry,
            plan.changed_paths,
        );
        let remote_sha = run_recorded_push(&isolation, plan_id, evidence, credential, ledger)?;
        Ok(GitPushRetryResult {
            plan_id: plan_id.to_string(),
            branch: plan.baseline.branch,
            head: plan.baseline.head,
            remote_sha,
            verified: true,
            completed_at_unix_ms: millis(SystemTime::now()).unwrap_or(0),
        })
    }
}

fn receipt(
    plan_id: &str,
    operation: GitPublishOperation,
    revision: Option<String>,
    summary: GitPublishSummary,
) -> GitPublishReceipt {
    GitPublishReceipt {
        plan_id: plan_id.to_string(),
        operation,
        completed_at_unix_ms: millis(SystemTime::now()).unwrap_or(0),
        revision,
        summary,
    }
}

fn invalid_plan() -> CommandError {
    CommandError::new("git_publish_plan_invalid", "The publish plan is invalid.")
}
fn plans_unavailable() -> CommandError {
    CommandError::new(
        "git_publish_plans_unavailable",
        "Publish plans are temporarily unavailable.",
    )
}

fn millis(time: SystemTime) -> CommandResult<u128> {
    time.duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .map_err(|_| CommandError::new("git_publish_clock_invalid", "System clock is invalid."))
}

fn validate_session(value: &str) -> CommandResult<()> {
    if Uuid::parse_str(value).is_ok() {
        Ok(())
    } else {
        Err(CommandError::new(
            "git_publish_session_invalid",
            "Repository session is invalid.",
        ))
    }
}
fn validate_plan_id(value: &str) -> CommandResult<()> {
    if Uuid::parse_str(value).is_ok() {
        Ok(())
    } else {
        Err(CommandError::new(
            "git_publish_plan_invalid",
            "Publish plan is invalid.",
        ))
    }
}
fn validate_message(value: &str) -> CommandResult<()> {
    if value.is_empty()
        || value.len() > MAX_MESSAGE_BYTES
        || value.contains('\0')
        || value.chars().any(|c| c.is_control() && c != '\n')
    {
        Err(CommandError::new(
            "git_commit_message_invalid",
            "Commit message is invalid.",
        ))
    } else {
        Ok(())
    }
}
fn validate_remote_name(value: &str) -> CommandResult<()> {
    if value.is_empty()
        || value.len() > 128
        || !value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
    {
        Err(CommandError::new(
            "git_remote_invalid",
            "Remote name is invalid.",
        ))
    } else {
        Ok(())
    }
}
fn validate_branch(value: &str) -> CommandResult<()> {
    if value.is_empty()
        || value.starts_with('-')
        || value.contains("..")
        || value.contains("@{")
        || value.ends_with('.')
        || value.ends_with('/')
        || value
            .bytes()
            .any(|b| b <= b' ' || matches!(b, b'~' | b'^' | b':' | b'?' | b'*' | b'[' | b'\\'))
    {
        Err(CommandError::new(
            "git_branch_invalid",
            "Current branch name is unsafe.",
        ))
    } else {
        Ok(())
    }
}

fn validate_root(root: &Path) -> CommandResult<PathBuf> {
    if !root.is_absolute() {
        return Err(CommandError::new(
            "git_repository_root_invalid",
            "Repository root is unavailable.",
        ));
    }
    let metadata = fs::symlink_metadata(root).map_err(|_| {
        CommandError::new(
            "git_repository_root_invalid",
            "Repository root is unavailable.",
        )
    })?;
    let canonical = root.canonicalize().map_err(|_| {
        CommandError::new(
            "git_repository_root_invalid",
            "Repository root is unavailable.",
        )
    })?;
    let dot_git = root.join(".git");
    let git_metadata = fs::symlink_metadata(dot_git).ok();
    if !metadata.is_dir()
        || metadata.file_type().is_symlink()
        || canonical != root
        || !matches!(git_metadata, Some(ref value) if !value.file_type().is_symlink() && (value.is_file() || value.is_dir()))
    {
        Err(CommandError::new(
            "git_repository_root_invalid",
            "Repository root is unavailable.",
        ))
    } else {
        super::git_boundary::validate_git_metadata(&canonical)?;
        Ok(canonical)
    }
}

fn capture_baseline(root: &Path, remote: Option<&str>) -> CommandResult<Baseline> {
    let head = git_text(root, &["rev-parse", "HEAD"])?;
    let branch_output = run_git(
        root,
        &["symbolic-ref", "--quiet", "--short", "HEAD"],
        None,
        None,
    )?;
    let branch = if branch_output.status.success() {
        Some(text_output(&branch_output.stdout)?)
    } else {
        None
    };
    if let Some(branch) = &branch {
        validate_branch(branch)?;
    }
    let tree = git_text(root, &["write-tree"])?;
    let index_bytes = fs::read(root.join(".git/index")).unwrap_or_default();
    let index_digest = digest(&[tree.as_bytes(), &index_bytes]);
    let remote_digest = remote.map(|name| remote_baseline(root, name)).transpose()?;
    Ok(Baseline {
        head,
        branch,
        index_digest,
        remote_digest,
    })
}

fn remote_baseline(root: &Path, remote: &str) -> CommandResult<String> {
    validate_remote_name(remote)?;
    let prefix = format!("refs/remotes/{remote}/");
    let output = run_git(
        root,
        &["for-each-ref", "--format=%(refname) %(objectname)", &prefix],
        None,
        None,
    )?;
    ensure_git_success(&output, "git_remote_baseline_failed")?;
    Ok(digest(&[&output.stdout]))
}

fn same_baseline(left: &Baseline, right: &Baseline) -> bool {
    left.head == right.head
        && left.branch == right.branch
        && left.index_digest == right.index_digest
        && left.remote_digest == right.remote_digest
}

struct PushRetrySnapshot {
    baseline: PushRetryBaseline,
    changed_paths: Vec<String>,
    pending_commit_count: usize,
}

fn inspect_push_retry(
    root: &Path,
    remote: &str,
    expected_url: Option<&str>,
    expected: Option<&PushRetryBaseline>,
    credential: Option<&RepositoryCredential>,
) -> CommandResult<PushRetrySnapshot> {
    let mut baseline = inspect_push_retry_local(root, remote)?;
    if expected_url.is_some_and(|url| baseline.remote_url != url) {
        return Err(CommandError::new(
            "git_push_retry_push_remote_changed",
            "The configured push URL changed; inspect a new push retry plan.",
        ));
    }
    if let Some(expected) = expected {
        if !same_push_retry_local_baseline(expected, &baseline) {
            return Err(CommandError::new(
                "git_push_retry_baseline_changed",
                "Repository or push URL changed; inspect a new push retry plan.",
            ));
        }
    }
    let head = baseline.head.clone();
    let branch = baseline.branch.clone();
    let frozen_url = expected_url.unwrap_or(baseline.remote_url.as_str());
    let isolation = network_isolation(&baseline)?;
    let observed_remote_sha = live_remote_sha(&isolation.root, frozen_url, &branch, credential)?;
    let ancestry = run_git(
        &isolation.root,
        &["merge-base", "--is-ancestor", &observed_remote_sha, &head],
        None,
        None,
    )?;
    if ancestry.status.code() != Some(0) {
        return Err(CommandError::new(
            "git_push_retry_diverged",
            "The live remote branch is not an ancestor of local HEAD; fetch and review before pushing.",
        ));
    }
    let count_text = git_text(
        &isolation.root,
        &[
            "rev-list",
            "--count",
            &format!("{observed_remote_sha}..{head}"),
        ],
    )?;
    let pending_commit_count = count_text.parse::<usize>().map_err(|_| {
        CommandError::new(
            "git_push_retry_inspection_failed",
            "Unable to count commits awaiting push.",
        )
    })?;
    if pending_commit_count == 0 {
        return Err(CommandError::new(
            "git_push_retry_nothing_to_push",
            "Local HEAD is already the live remote branch.",
        ));
    }
    if pending_commit_count > MAX_PUSH_RETRY_COMMITS {
        return Err(CommandError::new(
            "git_push_retry_commit_limit",
            "Too many commits await push for a bounded retry review.",
        ));
    }
    let changed_paths = changed_paths_between(&isolation.root, &observed_remote_sha, &head)?;
    let final_baseline = inspect_push_retry_local(root, remote)?;
    if expected_url.is_some_and(|url| final_baseline.remote_url != url) {
        return Err(CommandError::new(
            "git_push_retry_push_remote_changed",
            "The configured push URL changed; inspect a new push retry plan.",
        ));
    }
    if let Some(expected) = expected {
        if !same_push_retry_local_baseline(expected, &final_baseline) {
            return Err(CommandError::new(
                "git_push_retry_baseline_changed",
                "Repository or push URL changed; inspect a new push retry plan.",
            ));
        }
    }
    if !same_push_retry_local_baseline(&baseline, &final_baseline) {
        return Err(CommandError::new(
            "git_push_retry_inspection_drift",
            "Repository or push remote changed during inspection; inspect a new push retry plan.",
        ));
    }
    let final_remote_sha = live_remote_sha(
        &isolation.root,
        frozen_url,
        &final_baseline.branch,
        credential,
    )?;
    if observed_remote_sha != final_remote_sha {
        return Err(CommandError::new(
            "git_push_retry_inspection_drift",
            "Repository or push remote changed during inspection; inspect a new push retry plan.",
        ));
    }
    baseline.observed_remote_sha = observed_remote_sha;
    Ok(PushRetrySnapshot {
        baseline,
        changed_paths,
        pending_commit_count,
    })
}

fn inspect_push_retry_local(root: &Path, remote: &str) -> CommandResult<PushRetryBaseline> {
    validate_remote_name(remote)?;
    let root_identity = directory_identity(root)?;
    let git_common_directory = git_common_directory(root)?;
    let git_common_directory_identity = directory_identity(&git_common_directory)?;
    let object_format = git_object_format(root)?;
    let head = git_text(root, &["rev-parse", "--verify", "HEAD"])?;
    validate_object_id(&head)?;
    let branch = current_push_retry_branch(root)?;
    let remote_url = retry_push_remote_url(root, remote)?;
    let index_digest = git_text(root, &["write-tree"])?;
    validate_object_id(&index_digest)?;
    let worktree_digest = ensure_clean_push_retry_worktree(root)?;
    Ok(PushRetryBaseline {
        root_identity,
        git_common_directory,
        git_common_directory_identity,
        object_format,
        head,
        branch,
        index_digest,
        worktree_digest,
        remote_url,
        observed_remote_sha: String::new(),
    })
}

fn same_push_retry_baseline(left: &PushRetryBaseline, right: &PushRetryBaseline) -> bool {
    same_push_retry_local_baseline(left, right)
        && left.observed_remote_sha == right.observed_remote_sha
}

fn same_push_retry_local_baseline(left: &PushRetryBaseline, right: &PushRetryBaseline) -> bool {
    left.root_identity == right.root_identity
        && left.git_common_directory == right.git_common_directory
        && left.git_common_directory_identity == right.git_common_directory_identity
        && left.object_format == right.object_format
        && left.head == right.head
        && left.branch == right.branch
        && left.index_digest == right.index_digest
        && left.worktree_digest == right.worktree_digest
        && left.remote_url == right.remote_url
}

#[cfg(unix)]
fn directory_identity(path: &Path) -> CommandResult<DirectoryIdentity> {
    use std::os::unix::fs::MetadataExt;
    let metadata = fs::metadata(path).map_err(|_| {
        CommandError::new(
            "git_push_retry_repository_identity_invalid",
            "Unable to validate repository directory identity.",
        )
    })?;
    if !metadata.is_dir() {
        return Err(CommandError::new(
            "git_push_retry_repository_identity_invalid",
            "Unable to validate repository directory identity.",
        ));
    }
    Ok(DirectoryIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
    })
}

fn current_push_retry_branch(root: &Path) -> CommandResult<String> {
    let branch_output = run_git(
        root,
        &["symbolic-ref", "--quiet", "--short", "HEAD"],
        None,
        None,
    )?;
    if !branch_output.status.success() {
        return Err(CommandError::new(
            "git_push_retry_detached_head",
            "Push retry requires a checked-out branch.",
        ));
    }
    let branch = text_output(&branch_output.stdout)?;
    validate_branch(&branch)?;
    Ok(branch)
}

fn git_common_directory(root: &Path) -> CommandResult<PathBuf> {
    let value = git_text(root, &["rev-parse", "--git-common-dir"])?;
    let candidate = Path::new(&value);
    let absolute = if candidate.is_absolute() {
        candidate.to_path_buf()
    } else {
        root.join(candidate)
    };
    absolute.canonicalize().map_err(|_| {
        CommandError::new(
            "git_push_retry_repository_identity_invalid",
            "Unable to validate Git metadata for this repository.",
        )
    })
}

fn git_object_format(root: &Path) -> CommandResult<String> {
    let value = git_text(root, &["rev-parse", "--show-object-format"])?;
    match value.as_str() {
        "sha1" | "sha256" => Ok(value),
        _ => Err(CommandError::new(
            "git_push_retry_object_format_invalid",
            "Repository object format is unsupported for push retry.",
        )),
    }
}

fn network_isolation(baseline: &PushRetryBaseline) -> CommandResult<NetworkIsolation> {
    if directory_identity(&baseline.git_common_directory)? != baseline.git_common_directory_identity
    {
        return Err(CommandError::new(
            "git_push_retry_repository_identity_invalid",
            "Git metadata changed before network isolation could be created.",
        ));
    }
    let objects = baseline.git_common_directory.join("objects");
    let metadata = fs::symlink_metadata(&objects).map_err(|_| {
        CommandError::new(
            "git_push_retry_repository_identity_invalid",
            "Unable to validate the Git object directory.",
        )
    })?;
    let canonical_objects = objects.canonicalize().map_err(|_| {
        CommandError::new(
            "git_push_retry_repository_identity_invalid",
            "Unable to validate the Git object directory.",
        )
    })?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() || canonical_objects != objects {
        return Err(CommandError::new(
            "git_push_retry_repository_identity_invalid",
            "Unable to validate the Git object directory.",
        ));
    }
    let objects_text = canonical_objects
        .to_str()
        .filter(|value| !value.is_empty() && !value.contains(['\n', '\r', '\0']))
        .ok_or_else(|| {
            CommandError::new(
                "git_push_retry_repository_identity_invalid",
                "Git object directory cannot be safely isolated for push retry.",
            )
        })?;
    let directory = tempfile::Builder::new()
        .prefix("repopress-git-push-retry-")
        .tempdir()
        .map_err(|_| {
            CommandError::new(
                "git_push_retry_isolation_unavailable",
                "Unable to create an isolated Git directory for push retry.",
            )
        })?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).map_err(|_| {
            CommandError::new(
                "git_push_retry_isolation_unavailable",
                "Unable to secure the isolated Git directory.",
            )
        })?;
        if fs::metadata(directory.path())
            .map_err(|_| {
                CommandError::new(
                    "git_push_retry_isolation_unavailable",
                    "Unable to validate the isolated Git directory.",
                )
            })?
            .permissions()
            .mode()
            & 0o077
            != 0
        {
            return Err(CommandError::new(
                "git_push_retry_isolation_unavailable",
                "The isolated Git directory has unsafe permissions.",
            ));
        }
    }
    let init_format = format!("--object-format={}", baseline.object_format);
    let initialized = run_git(
        directory.path(),
        &["init", "--bare", "--quiet", "--template=", &init_format],
        None,
        None,
    )?;
    ensure_git_success(&initialized, "git_push_retry_isolation_unavailable")?;
    let redirects = run_git(
        directory.path(),
        &["config", "--local", "http.followRedirects", "false"],
        None,
        None,
    )?;
    ensure_git_success(&redirects, "git_push_retry_isolation_unavailable")?;
    let alternates = directory
        .path()
        .join("objects")
        .join("info")
        .join("alternates");
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&alternates)
        .map_err(|_| {
            CommandError::new(
                "git_push_retry_isolation_unavailable",
                "Unable to configure isolated Git object access.",
            )
        })?;
    file.write_all(objects_text.as_bytes())
        .and_then(|_| file.write_all(b"\n"))
        .map_err(|_| {
            CommandError::new(
                "git_push_retry_isolation_unavailable",
                "Unable to configure isolated Git object access.",
            )
        })?;
    Ok(NetworkIsolation {
        root: directory.path().to_path_buf(),
        _directory: directory,
    })
}

fn ensure_clean_push_retry_worktree(root: &Path) -> CommandResult<String> {
    let index = run_git(
        root,
        &[
            "diff",
            "--cached",
            "--quiet",
            "--no-ext-diff",
            "--no-textconv",
        ],
        None,
        None,
    )?;
    if index.status.code() != Some(0) {
        return Err(CommandError::new(
            "git_push_retry_dirty_index",
            "Stage or unstage changes separately before retrying a push of existing commits.",
        ));
    }
    let status = run_git(
        root,
        &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
        None,
        None,
    )?;
    ensure_git_success(&status, "git_push_retry_status_failed")?;
    if !status.stdout.is_empty() {
        return Err(CommandError::new(
            "git_push_retry_dirty_worktree",
            "Commit, stash, or discard local worktree changes before retrying a push.",
        ));
    }
    Ok(digest(&[&status.stdout]))
}

fn changed_paths_between(root: &Path, remote_sha: &str, head: &str) -> CommandResult<Vec<String>> {
    let range = format!("{remote_sha}..{head}");
    let output = run_git(
        root,
        &[
            "log",
            "--format=",
            "--name-only",
            "-z",
            "-m",
            "--no-renames",
            &range,
            "--",
        ],
        None,
        None,
    )?;
    ensure_git_success(&output, "git_push_retry_inspection_failed")?;
    let mut paths = BTreeSet::new();
    for value in output.stdout.split(|byte| *byte == 0) {
        if value.is_empty() {
            continue;
        }
        let path = std::str::from_utf8(value).map_err(|_| {
            CommandError::new(
                "git_push_retry_unsafe_path",
                "A pending path cannot be safely shown for review.",
            )
        })?;
        validate_push_retry_path(path)?;
        let inserted = paths.insert(path.to_string());
        if inserted && paths.len() > MAX_PUSH_RETRY_PATHS {
            return Err(CommandError::new(
                "git_push_retry_path_limit",
                "Too many changed paths await push for a bounded retry review.",
            ));
        }
    }
    Ok(paths.into_iter().collect())
}

fn validate_push_retry_path(path: &str) -> CommandResult<()> {
    if path.is_empty()
        || path.starts_with('/')
        || path.contains('\\')
        || path
            .split('/')
            .any(|part| part.is_empty() || part == "." || part == "..")
        || path == ".git"
        || path.starts_with(".git/")
        || path.chars().any(char::is_control)
    {
        return Err(CommandError::new(
            "git_push_retry_unsafe_path",
            "A pending path cannot be safely shown for review.",
        ));
    }
    Ok(())
}

fn validate_object_id(value: &str) -> CommandResult<()> {
    if !(value.len() == 40 || value.len() == 64)
        || !value.bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        return Err(CommandError::new(
            "git_push_retry_remote_sha_invalid",
            "Git returned an invalid object ID.",
        ));
    }
    Ok(())
}

fn live_remote_sha(
    root: &Path,
    url: &str,
    branch: &str,
    credential: Option<&RepositoryCredential>,
) -> CommandResult<String> {
    validate_branch(branch)?;
    validate_remote_url(url)?;
    let authentication = auth_for_url(url, credential)?;
    let expected_ref = format!("refs/heads/{branch}");
    let output = run_git(
        root,
        &["ls-remote", "--heads", "--refs", url, &expected_ref],
        authentication,
        None,
    )
    .map_err(|_| {
        CommandError::new(
            "git_push_retry_remote_unavailable",
            "Unable to inspect the configured push remote; check the network and credentials.",
        )
    })?;
    if !output.status.success() {
        return Err(CommandError::new(
            "git_push_retry_remote_unavailable",
            "Unable to inspect the configured push remote; check the network and credentials.",
        ));
    }
    let text = std::str::from_utf8(&output.stdout).map_err(|_| {
        CommandError::new(
            "git_push_retry_remote_sha_invalid",
            "The configured push remote returned invalid branch data.",
        )
    })?;
    let mut lines = text.lines();
    let Some(line) = lines.next() else {
        return Err(CommandError::new(
            "git_push_retry_remote_branch_missing",
            "The configured push remote has no branch with the current name.",
        ));
    };
    if lines.next().is_some() {
        return Err(CommandError::new(
            "git_push_retry_remote_sha_invalid",
            "The configured push remote returned ambiguous branch data.",
        ));
    }
    let mut parts = line.split_ascii_whitespace();
    let sha = parts.next().unwrap_or_default();
    let reference = parts.next().unwrap_or_default();
    if parts.next().is_some() || reference != expected_ref {
        return Err(CommandError::new(
            "git_push_retry_remote_sha_invalid",
            "The configured push remote returned invalid branch data.",
        ));
    }
    validate_object_id(sha)?;
    Ok(sha.to_ascii_lowercase())
}

fn push_retry_outcome_unknown() -> CommandError {
    CommandError::new(
        "git_push_retry_outcome_unknown",
        "Push may have reached the remote, but the app could not verify the exact remote SHA. Inspect the remote before retrying.",
    )
}

fn baseline_digest(baseline: &Baseline) -> String {
    digest(&[
        baseline.head.as_bytes(),
        baseline.branch.as_deref().unwrap_or("").as_bytes(),
        baseline.index_digest.as_bytes(),
        baseline.remote_digest.as_deref().unwrap_or("").as_bytes(),
    ])
}

fn ensure_staged_changes(root: &Path) -> CommandResult<()> {
    let output = run_git(
        root,
        &[
            "diff",
            "--cached",
            "--quiet",
            "--no-ext-diff",
            "--no-textconv",
        ],
        None,
        None,
    )?;
    match output.status.code() {
        Some(1) => Ok(()),
        Some(0) => Err(CommandError::new(
            "git_commit_empty_index",
            "Commit requires already-staged changes.",
        )),
        _ => Err(CommandError::new(
            "git_commit_index_unavailable",
            "Unable to inspect staged changes.",
        )),
    }
}

fn ensure_local_commit_identity(root: &Path) -> CommandResult<()> {
    for key in ["user.name", "user.email"] {
        let output = run_git(root, &["config", "--local", "--get", key], None, None)?;
        if !output.status.success() {
            return Err(CommandError::new(
                "git_commit_identity_required",
                "Configure repository-local user.name and user.email before committing.",
            ));
        }
        let value = text_output(&output.stdout)?;
        if value.len() > 256 || value.chars().any(char::is_control) {
            return Err(CommandError::new(
                "git_commit_identity_invalid",
                "The repository-local Git identity is invalid.",
            ));
        }
    }
    Ok(())
}

fn remote_url(root: &Path, remote: &str) -> CommandResult<String> {
    let value = git_text(root, &["remote", "get-url", "--push", remote])?;
    if value.len() > 2048 || value.contains('\0') {
        return Err(CommandError::new(
            "git_remote_invalid",
            "Remote URL is invalid.",
        ));
    }
    Ok(value)
}

/// Returns a validated, credential-free URL for a named publish remote.
/// This shares the same allowlist as fetch and push planning.
pub fn read_publish_remote_url(root: &Path, remote: &str) -> CommandResult<String> {
    validate_remote_name(remote)?;
    let root = validate_root(root)?;
    let value = remote_url(&root, remote)?;
    validate_remote_url(&value)?;
    Ok(value)
}

/// Resolves exactly one effective push URL for the retry-only lane. Generic
/// publish operations intentionally retain their existing remote behavior.
pub fn read_push_retry_remote_url(root: &Path, remote: &str) -> CommandResult<String> {
    validate_remote_name(remote)?;
    let root = validate_root(root)?;
    retry_push_remote_url(&root, remote)
}

fn retry_push_remote_url(root: &Path, remote: &str) -> CommandResult<String> {
    validate_remote_name(remote)?;
    reject_retry_url_rewrites(root)?;
    reject_retry_mirror_configuration(root, remote)?;
    let output = run_git(
        root,
        &["remote", "get-url", "--push", "--all", remote],
        None,
        None,
    )?;
    if !output.status.success() {
        return Err(CommandError::new(
            "git_push_retry_push_remote_invalid",
            "Unable to resolve one configured push URL for retry.",
        ));
    }
    let value = std::str::from_utf8(&output.stdout).map_err(|_| {
        CommandError::new(
            "git_push_retry_push_remote_invalid",
            "The configured push URL is invalid.",
        )
    })?;
    let values = value.lines().collect::<Vec<_>>();
    if values.len() != 1 || values[0].is_empty() || values[0].contains('\r') {
        return Err(CommandError::new(
            "git_push_retry_push_remote_ambiguous",
            "Push retry requires exactly one configured push URL.",
        ));
    }
    let url = values[0].to_string();
    validate_remote_url(&url)?;
    Ok(url)
}

fn reject_retry_url_rewrites(root: &Path) -> CommandResult<()> {
    // This reads effective config through the constrained runner, including
    // configured includes. Any URL rewrite can redirect a literal transport URL.
    let output = run_git(root, &["config", "--get-regexp", "^url\\."], None, None)?;
    match output.status.code() {
        Some(1) => Ok(()),
        Some(0) => Err(CommandError::new(
            "git_push_retry_url_rewrite_not_allowed",
            "Push retry is unavailable while effective Git URL rewrite configuration exists.",
        )),
        _ => Err(CommandError::new(
            "git_push_retry_push_remote_invalid",
            "Unable to inspect Git URL rewrite configuration.",
        )),
    }
}

fn reject_retry_mirror_configuration(root: &Path, remote: &str) -> CommandResult<()> {
    let key = format!("^remote\\.{remote}\\.mirror$");
    let output = run_git(root, &["config", "--get-regexp", &key], None, None)?;
    match output.status.code() {
        Some(1) => Ok(()),
        Some(0) => Err(CommandError::new(
            "git_push_retry_mirror_not_allowed",
            "Push retry is unavailable for a remote with mirror configuration.",
        )),
        _ => Err(CommandError::new(
            "git_push_retry_push_remote_invalid",
            "Unable to inspect Git mirror configuration.",
        )),
    }
}

/// Reads the remote's symbolic default branch without contacting the network.
/// Missing metadata is represented as `None` so callers can require an explicit
/// target branch rather than guessing.
pub fn read_publish_remote_default_branch(
    root: &Path,
    remote: &str,
) -> CommandResult<Option<String>> {
    validate_remote_name(remote)?;
    let root = validate_root(root)?;
    let reference = format!("refs/remotes/{remote}/HEAD");
    let output = run_git(
        &root,
        &["symbolic-ref", "--quiet", "--short", &reference],
        None,
        None,
    )?;
    if !output.status.success() {
        return Ok(None);
    }
    let value = text_output(&output.stdout)?;
    let prefix = format!("{remote}/");
    let branch = value.strip_prefix(&prefix).ok_or_else(|| {
        CommandError::new(
            "git_remote_default_invalid",
            "The remote default branch is invalid.",
        )
    })?;
    validate_branch(branch)?;
    Ok(Some(branch.to_string()))
}

#[derive(Clone, Copy)]
enum RemoteTransport {
    Https,
    SshAmbient,
    #[cfg(test)]
    TestLocal,
}

fn validate_remote_url(value: &str) -> CommandResult<RemoteTransport> {
    #[cfg(test)]
    if value.starts_with("file://") {
        return Ok(RemoteTransport::TestLocal);
    }
    if value.is_empty()
        || value.len() > 2048
        || value
            .bytes()
            .any(|b| b <= b' ' || matches!(b, b'\\' | b'?' | b'#'))
    {
        return unsafe_remote();
    }
    if let Some(rest) = value.strip_prefix("https://") {
        let Some((host, path)) = rest.split_once('/') else {
            return unsafe_remote();
        };
        if is_allowed_host(host)
            && valid_repo_path(path)
            && !host.contains('@')
            && !host.contains(':')
        {
            return Ok(RemoteTransport::Https);
        }
    }
    if let Some(rest) = value.strip_prefix("git@") {
        let Some((host, path)) = rest.split_once(':') else {
            return unsafe_remote();
        };
        if is_allowed_host(host) && valid_repo_path(path) && !path.contains(':') {
            return Ok(RemoteTransport::SshAmbient);
        }
    }
    if let Some(rest) = value.strip_prefix("ssh://git@") {
        let Some((host, path)) = rest.split_once('/') else {
            return unsafe_remote();
        };
        if is_allowed_host(host) && valid_repo_path(path) && !host.contains(':') {
            return Ok(RemoteTransport::SshAmbient);
        }
    }
    unsafe_remote()
}
fn unsafe_remote<T>() -> CommandResult<T> {
    Err(CommandError::new(
        "git_remote_not_allowed",
        "Remote must be a credential-free GitHub or GitLab HTTPS URL, or ambient SSH URL.",
    ))
}
fn is_allowed_host(host: &str) -> bool {
    matches!(host, "github.com" | "gitlab.com")
}
fn valid_repo_path(value: &str) -> bool {
    !value.is_empty()
        && !value.starts_with('/')
        && value
            .split('/')
            .all(|part| !part.is_empty() && part != "." && part != "..")
}

struct AskPass<'a> {
    username: &'a str,
    token: &'a str,
}
fn auth_for_url<'a>(
    url: &str,
    credential: Option<&'a RepositoryCredential>,
) -> CommandResult<Option<AskPass<'a>>> {
    match (validate_remote_url(url)?, credential) {
        (RemoteTransport::Https, Some(credential)) => Ok(Some(AskPass {
            username: if url.starts_with("https://gitlab.com/") {
                "oauth2"
            } else {
                "x-access-token"
            },
            token: credential.token(),
        })),
        (RemoteTransport::Https, None) => Ok(None),
        (RemoteTransport::SshAmbient, None) => Ok(None),
        (RemoteTransport::SshAmbient, Some(_)) => Err(CommandError::new(
            "git_credential_not_applicable",
            "Token credentials are only permitted for HTTPS remotes.",
        )),
        #[cfg(test)]
        (RemoteTransport::TestLocal, None) => Ok(None),
        #[cfg(test)]
        (RemoteTransport::TestLocal, Some(_)) => Err(CommandError::new(
            "git_credential_not_applicable",
            "Token credentials are not permitted for a test-only local remote.",
        )),
    }
}

struct GitOutput {
    status: ExitStatus,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

fn run_git(
    root: &Path,
    args: &[&str],
    askpass: Option<AskPass<'_>>,
    remote: Option<&str>,
) -> CommandResult<GitOutput> {
    run_git_mode(root, args, askpass, remote, false)
}

fn run_git_mode(
    root: &Path,
    args: &[&str],
    askpass: Option<AskPass<'_>>,
    remote: Option<&str>,
    local_objects_only: bool,
) -> CommandResult<GitOutput> {
    run_git_mode_timeout(root, args, askpass, remote, local_objects_only, GIT_TIMEOUT)
}

fn run_git_mode_timeout(
    root: &Path,
    args: &[&str],
    askpass: Option<AskPass<'_>>,
    remote: Option<&str>,
    local_objects_only: bool,
    timeout: Duration,
) -> CommandResult<GitOutput> {
    run_git_mode_io(
        root,
        args,
        askpass,
        remote,
        local_objects_only,
        timeout,
        None,
    )
}

fn run_git_mode_io(
    root: &Path,
    args: &[&str],
    askpass: Option<AskPass<'_>>,
    remote: Option<&str>,
    local_objects_only: bool,
    timeout: Duration,
    input: Option<&[u8]>,
) -> CommandResult<GitOutput> {
    if let Some(remote) = remote {
        validate_remote_name(remote)?;
    }
    super::git_boundary::validate_git_metadata_if_present(root)?;
    let file_protocol = if cfg!(test) {
        "protocol.file.allow=always"
    } else {
        "protocol.file.allow=never"
    };
    let mut command = Command::new("git");
    command
        .arg("--literal-pathspecs")
        .arg("-c")
        .arg("core.hooksPath=/dev/null")
        .arg("-c")
        .arg("credential.helper=")
        .arg("-c")
        .arg("core.fsmonitor=false")
        .arg("-c")
        .arg("protocol.ext.allow=never")
        .arg("-c")
        .arg(file_protocol)
        .arg("-c")
        .arg("http.proxy=")
        .arg("-c")
        .arg("http.https://github.com.proxy=")
        .arg("-c")
        .arg("http.https://gitlab.com.proxy=")
        .arg("-c")
        .arg("core.sshCommand=/usr/bin/ssh -oBatchMode=yes");
    if let Some(remote) = remote {
        command.arg("-c").arg(format!("remote.{remote}.proxy="));
    }
    command
        .arg("-C")
        .arg(root)
        .args(args)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("LC_ALL", "C")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_SSH_COMMAND", "/usr/bin/ssh -oBatchMode=yes")
        .env("GIT_SSH_VARIANT", "ssh")
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if local_objects_only {
        // Even Git versions predating NO_LAZY_FETCH must not use a transport.
        command
            .env("GIT_NO_REPLACE_OBJECTS", "1")
            .env("GIT_NO_LAZY_FETCH", "1")
            .env("GIT_ALLOW_PROTOCOL", "");
    }
    #[cfg(test)]
    command.env("GIT_PROTOCOL_FROM_USER", "1");
    if let Some(askpass) = askpass {
        let executable = std::env::current_exe().map_err(|_| {
            CommandError::new(
                "git_askpass_unavailable",
                "Credential prompt handler is unavailable.",
            )
        })?;
        command
            .env("GIT_ASKPASS", executable)
            .env("GIT_ASKPASS_REQUIRE", "force")
            .env("REPOPRESS_GIT_ASKPASS_V1", "1")
            .env("REPOPRESS_GIT_ASKPASS_USERNAME", askpass.username)
            .env("REPOPRESS_GIT_ASKPASS_TOKEN", askpass.token);
    }
    let mut child = command
        .spawn()
        .map_err(|_| CommandError::new("git_unavailable", "Git executable is unavailable."))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| CommandError::new("git_output_unavailable", "Git output is unavailable."))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| CommandError::new("git_output_unavailable", "Git output is unavailable."))?;
    let stdout_reader = thread::spawn(move || read_child_output(stdout));
    let stderr_reader = thread::spawn(move || read_child_output(stderr));
    let input_writer = input.map(|bytes| {
        let mut pipe = child.stdin.take();
        let bytes = bytes.to_vec();
        thread::spawn(move || -> std::io::Result<()> {
            pipe.as_mut()
                .ok_or_else(|| std::io::Error::other("missing input"))?
                .write_all(&bytes)
        })
    });
    let deadline = Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(CommandError::new(
                    "git_timeout",
                    "Git did not finish in time.",
                ));
            }
            Ok(None) => thread::sleep(Duration::from_millis(10)),
            Err(_) => {
                return Err(CommandError::new(
                    "git_wait_failed",
                    "Unable to wait for Git.",
                ))
            }
        }
    };
    let stdout = stdout_reader
        .join()
        .map_err(|_| CommandError::new("git_output_unavailable", "Git output failed."))??;
    let stderr = stderr_reader
        .join()
        .map_err(|_| CommandError::new("git_output_unavailable", "Git output failed."))??;
    if let Some(writer) = input_writer {
        writer
            .join()
            .map_err(|_| invalid_plan())?
            .map_err(|_| invalid_plan())?;
    }
    Ok(GitOutput {
        status,
        stdout,
        stderr,
    })
}

fn read_child_output(reader: impl Read) -> CommandResult<Vec<u8>> {
    let mut bytes = Vec::new();
    reader
        .take((MAX_GIT_OUTPUT + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| CommandError::new("git_output_unavailable", "Unable to read Git output."))?;
    if bytes.len() > MAX_GIT_OUTPUT {
        Err(CommandError::new(
            "git_output_too_large",
            "Git produced too much output.",
        ))
    } else {
        Ok(bytes)
    }
}
fn ensure_git_success(output: &GitOutput, code: &str) -> CommandResult<()> {
    // Git diagnostics may contain paths, proxy settings, or credential-related text.
    // Return only stable text; never surface stderr to an IPC client or log.
    let _ = &output.stderr;
    if output.status.success() {
        Ok(())
    } else {
        Err(CommandError::new(code, "Git operation failed."))
    }
}
fn git_text(root: &Path, args: &[&str]) -> CommandResult<String> {
    let output = run_git(root, args, None, None)?;
    ensure_git_success(&output, "git_repository_inspection_failed")?;
    text_output(&output.stdout)
}
fn text_output(bytes: &[u8]) -> CommandResult<String> {
    let value = std::str::from_utf8(bytes)
        .map_err(|_| {
            CommandError::new(
                "git_repository_inspection_failed",
                "Git returned invalid text.",
            )
        })?
        .trim();
    if value.is_empty() || value.len() > MAX_GIT_OUTPUT {
        Err(CommandError::new(
            "git_repository_inspection_failed",
            "Git returned invalid text.",
        ))
    } else {
        Ok(value.to_string())
    }
}
fn digest(parts: &[&[u8]]) -> String {
    let mut hash = Sha256::new();
    for part in parts {
        hash.update(part);
    }
    format!("{:x}", hash.finalize())
}

/// Call this at the beginning of the desktop executable.  It writes exactly one
/// askpass response to stdout and returns `true` when this invocation is an askpass
/// child.  Secrets are never logged or put in command-line arguments.
pub fn git_askpass_response_from_environment() -> bool {
    if std::env::var_os("REPOPRESS_GIT_ASKPASS_V1").as_deref() != Some(std::ffi::OsStr::new("1")) {
        return false;
    }
    let prompt = std::env::args().nth(1).unwrap_or_default();
    let username = std::env::var("REPOPRESS_GIT_ASKPASS_USERNAME").unwrap_or_default();
    let token = std::env::var("REPOPRESS_GIT_ASKPASS_TOKEN").unwrap_or_default();
    let Some(response) = askpass_response(&prompt, &username, &token) else {
        return true;
    };
    let _ = std::io::stdout().write_all(response.as_bytes());
    let _ = std::io::stdout().write_all(b"\n");
    true
}

fn askpass_response<'a>(prompt: &str, username: &'a str, token: &'a str) -> Option<&'a str> {
    let prompt = prompt.to_ascii_lowercase();
    let response = if prompt.contains("username") {
        username
    } else if prompt.contains("password") || prompt.contains("token") {
        token
    } else {
        return None;
    };
    (!response.is_empty() && !response.contains('\0') && !response.contains('\n'))
        .then_some(response)
}

fn repository_identity_for_root(root: &Path) -> CommandResult<String> {
    let common = git_common_directory(root)?;
    let root_id = directory_identity(root)?;
    let common_id = directory_identity(&common)?;
    Ok(digest(&[
        root.as_os_str().as_encoded_bytes(),
        common.as_os_str().as_encoded_bytes(),
        format!("{root_id:?}/{common_id:?}/{}", git_object_format(root)?).as_bytes(),
    ]))
}
fn network_baseline(
    root: &Path,
    remote: &str,
    head: &str,
    branch: &str,
) -> CommandResult<PushRetryBaseline> {
    validate_object_id(head)?;
    validate_branch(branch)?;
    let common = git_common_directory(root)?;
    Ok(PushRetryBaseline {
        root_identity: directory_identity(root)?,
        git_common_directory_identity: directory_identity(&common)?,
        git_common_directory: common,
        object_format: git_object_format(root)?,
        head: head.to_string(),
        branch: branch.to_string(),
        remote_url: retry_push_remote_url(root, remote)?,
        index_digest: String::new(),
        worktree_digest: String::new(),
        observed_remote_sha: String::new(),
    })
}
fn push_evidence(
    root: &Path,
    remote: &str,
    baseline: &PushRetryBaseline,
    operation: PushOperation,
    changed_paths: Vec<String>,
) -> PublishEvidence {
    PublishEvidence {
        repository_path: root.to_string_lossy().into_owned(),
        repository_identity: digest(&[
            root.as_os_str().as_encoded_bytes(),
            baseline.git_common_directory.as_os_str().as_encoded_bytes(),
            format!(
                "{:?}/{:?}/{}",
                baseline.root_identity,
                baseline.git_common_directory_identity,
                baseline.object_format
            )
            .as_bytes(),
        ]),
        operation,
        remote: remote.to_string(),
        remote_url: baseline.remote_url.clone(),
        branch: baseline.branch.clone(),
        expected_sha: baseline.head.clone(),
        observed_before_sha: (!baseline.observed_remote_sha.is_empty())
            .then(|| baseline.observed_remote_sha.clone()),
        changed_paths,
    }
}
fn run_recorded_push(
    isolation: &NetworkIsolation,
    plan_id: &str,
    evidence: PublishEvidence,
    credential: Option<&RepositoryCredential>,
    ledger: Option<&PublishLedgerStore>,
) -> CommandResult<String> {
    let authentication = auth_for_url(&evidence.remote_url, credential)?;
    validate_publish_evidence(&evidence)?;
    // Only tests can omit the ledger. Both production push entrypoints require it.
    let attempt = ledger
        .map(|ledger| ledger.begin(plan_id, evidence.clone()))
        .transpose()?;
    let source = format!("{}:refs/heads/{}", evidence.expected_sha, evidence.branch);
    let _attempted = run_git(
        &isolation.root,
        &[
            "push",
            "--porcelain",
            "--no-verify",
            "--no-recurse-submodules",
            "--no-follow-tags",
            "--receive-pack=git-receive-pack",
            &evidence.remote_url,
            &source,
        ],
        authentication,
        None,
    );
    let observed = live_remote_sha(
        &isolation.root,
        &evidence.remote_url,
        &evidence.branch,
        credential,
    )
    .ok();
    if let Some(attempt) = attempt {
        attempt.finish(observed.clone()).map_err(|_| CommandError::new("publish_outcome_unknown", "Push may have reached the remote but its final record could not be persisted. Inspect the recorded attempt before retrying."))?;
    }
    match observed {
        Some(sha) if sha == evidence.expected_sha => Ok(sha),
        _ => Err(push_retry_outcome_unknown()),
    }
}

pub(super) fn validate_publish_evidence(evidence: &PublishEvidence) -> CommandResult<()> {
    validate_remote_name(&evidence.remote)?;
    validate_remote_url(&evidence.remote_url)?;
    validate_branch(&evidence.branch)?;
    if !Path::new(&evidence.repository_path).is_absolute()
        || evidence.repository_path.len() > 4096
        || evidence.repository_path.chars().any(char::is_control)
        || evidence.repository_identity.len() != 64
        || !super::publish_ledger::valid_sha(&evidence.repository_identity)
        || !super::publish_ledger::valid_sha(&evidence.expected_sha)
        || evidence.changed_paths.len() > MAX_PUSH_RETRY_PATHS
    {
        return Err(invalid_plan());
    }
    if let Some(sha) = &evidence.observed_before_sha {
        if !super::publish_ledger::valid_sha(sha) {
            return Err(invalid_plan());
        }
    }
    for path in &evidence.changed_paths {
        if path.len() > 4096 {
            return Err(invalid_plan());
        }
        validate_push_retry_path(path)?;
    }
    Ok(())
}

pub fn validate_recorded_push_target(root: &Path, record: &PublishRecord) -> CommandResult<()> {
    validate_publish_target(root, &record.evidence)
}
pub(super) fn validate_publish_target(
    root: &Path,
    evidence: &PublishEvidence,
) -> CommandResult<()> {
    validate_publish_evidence(evidence)?;
    let root = validate_root(root)?;
    if root != Path::new(&evidence.repository_path)
        || repository_identity_for_root(&root)? != evidence.repository_identity
        || retry_push_remote_url(&root, &evidence.remote)? != evidence.remote_url
    {
        return Err(CommandError::new(
            "publish_record_target_changed",
            "Repository identity or push destination changed. No remote request was made.",
        ));
    }
    Ok(())
}
pub fn capture_review_target(root: &Path, remote: &str) -> CommandResult<PublishEvidence> {
    let root = validate_root(root)?;
    let head = git_text(&root, &["rev-parse", "HEAD"])?;
    let branch = git_text(&root, &["symbolic-ref", "--quiet", "--short", "HEAD"])?;
    let baseline = network_baseline(&root, remote, &head, &branch)?;
    let evidence = push_evidence(&root, remote, &baseline, PushOperation::Push, Vec::new());
    validate_publish_evidence(&evidence)?;
    Ok(evidence)
}

pub(super) enum RecordedCommitShape {
    Root,
    Merge,
    SingleParent(String),
}

/// Canonical raw objects, size-gated before reading. Never hydrates or runs
/// filters/diff drivers. The caller verifies the type-prefixed object digest.
pub(super) fn read_local_rollback_object(
    root: &Path,
    kind: &str,
    sha: &str,
    max_bytes: usize,
    timeout: Duration,
) -> CommandResult<Vec<u8>> {
    validate_object_id(sha)?;
    if !matches!(kind, "commit" | "tree" | "blob") || max_bytes > 64 * 1024 {
        return Err(invalid_plan());
    }
    let deadline = Instant::now() + timeout.min(GIT_TIMEOUT);
    let run = |args: &[&str]| -> CommandResult<GitOutput> {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or_else(|| CommandError::new("git_timeout", "Object inspection timed out."))?;
        let output = run_git_mode_timeout(root, args, None, None, true, remaining)?;
        ensure_git_success(&output, "rollback_object_missing")?;
        Ok(output)
    };
    if text_output(&run(&["cat-file", "-t", sha])?.stdout)? != kind {
        return Err(CommandError::new(
            "rollback_object_missing",
            "Recorded object type differs.",
        ));
    }
    let size: usize = text_output(&run(&["cat-file", "-s", sha])?.stdout)?
        .parse()
        .map_err(|_| invalid_plan())?;
    if size > max_bytes {
        return Err(CommandError::new(
            "rollback_object_too_large",
            "Recorded object exceeds the inspection limit.",
        ));
    }
    let bytes = run(&["cat-file", kind, sha])?.stdout;
    if bytes.len() != size || bytes.len() > max_bytes {
        return Err(invalid_plan());
    }
    Ok(bytes)
}

pub(super) fn initialize_local_candidate(
    root: &Path,
    format: &str,
    timeout: Duration,
) -> CommandResult<()> {
    if !matches!(format, "sha1" | "sha256") {
        return Err(invalid_plan());
    }
    let flag = format!("--object-format={format}");
    let output = run_git_mode_timeout(
        root,
        &["init", "--bare", "--quiet", "--template=", &flag],
        None,
        None,
        true,
        timeout,
    )?;
    ensure_git_success(&output, "rollback_candidate_isolation_failed")
}
pub(super) fn write_local_candidate_object(
    root: &Path,
    kind: &str,
    bytes: &[u8],
    timeout: Duration,
) -> CommandResult<String> {
    if !matches!(kind, "commit" | "tree" | "blob") || bytes.len() > 64 * 1024 {
        return Err(invalid_plan());
    }
    let output = run_git_mode_io(
        root,
        &["hash-object", "-w", "-t", kind, "--stdin"],
        None,
        None,
        true,
        timeout,
        Some(bytes),
    )?;
    ensure_git_success(&output, "rollback_candidate_object_write_failed")?;
    let oid = text_output(&output.stdout)?;
    validate_object_id(&oid)?;
    Ok(oid)
}

/// Reads actual commit headers and root-tree objects only. It neither hydrates
/// partial clones nor proves that every blob or a revert's conflict result exists.
pub(super) fn inspect_recorded_rollback_objects(
    root: &Path,
    sha: &str,
) -> CommandResult<RecordedCommitShape> {
    fn text(root: &Path, args: &[&str]) -> CommandResult<String> {
        let output = run_git_mode(root, args, None, None, true)?;
        ensure_git_success(&output, "rollback_objects_unavailable")?;
        text_output(&output.stdout)
    }
    fn header(root: &Path, sha: &str) -> CommandResult<(String, Vec<String>)> {
        validate_object_id(sha)?;
        if text(root, &["cat-file", "-t", sha])? != "commit" {
            return Err(invalid_plan());
        }
        let commit = text(root, &["cat-file", "-p", sha])?;
        let mut tree = None;
        let mut parents = Vec::new();
        for line in commit.lines().take_while(|line| !line.is_empty()) {
            if let Some(value) = line.strip_prefix("tree ") {
                validate_object_id(value)?;
                if tree.replace(value.to_string()).is_some() {
                    return Err(invalid_plan());
                }
            } else if let Some(value) = line.strip_prefix("parent ") {
                validate_object_id(value)?;
                parents.push(value.to_string());
            }
        }
        let tree = tree.ok_or_else(invalid_plan)?;
        if text(root, &["cat-file", "-t", &tree])? != "tree" {
            return Err(invalid_plan());
        }
        Ok((tree, parents))
    }
    let replacements = run_git_mode(
        root,
        &["for-each-ref", "--format=%(refname)", "refs/replace/"],
        None,
        None,
        true,
    )?;
    ensure_git_success(&replacements, "rollback_objects_unavailable")?;
    if !replacements.stdout.is_empty() {
        return Err(invalid_plan());
    }
    let (_, parents) = header(root, sha)?;
    match parents.as_slice() {
        [] => Ok(RecordedCommitShape::Root),
        [parent] => {
            header(root, parent)?;
            Ok(RecordedCommitShape::SingleParent(parent.clone()))
        }
        _ => Ok(RecordedCommitShape::Merge),
    }
}
/// ls-remote only; permits local HEAD/index/worktree changes after the push.
pub fn observe_recorded_push(
    root: &Path,
    record: &PublishRecord,
    credential: Option<&RepositoryCredential>,
) -> CommandResult<Option<String>> {
    validate_recorded_push_target(root, record)?;
    let baseline = network_baseline(
        root,
        &record.evidence.remote,
        &record.evidence.expected_sha,
        &record.evidence.branch,
    )?;
    let isolation = network_isolation(&baseline)?;
    // Recheck immediately before any credential-bearing network request.
    validate_recorded_push_target(root, record)?;
    let observed = live_remote_sha(
        &isolation.root,
        &record.evidence.remote_url,
        &record.evidence.branch,
        credential,
    )
    .ok();
    validate_recorded_push_target(root, record)?;
    Ok(observed)
}

/// An isolated snapshot has a single-parent candidate, plus a shallow boundary
/// at the already-published source. No source alternates or ancestor fetching.
pub(crate) fn push_rollback_candidate(
    root: &Path,
    isolated: &Path,
    record: &super::rollback_ledger::RollbackRecord,
    credential: Option<&RepositoryCredential>,
    before_write: impl FnOnce() -> CommandResult<()>,
) -> CommandResult<()> {
    validate_recorded_push_target(root, &record.source)?;
    let expected = &record.source.evidence.expected_sha;
    let raw = read_local_rollback_object(
        isolated,
        "commit",
        &record.candidate_sha,
        64 * 1024,
        GIT_TIMEOUT,
    )?;
    let (tree, parents) = super::rollback_change_preview::commit_tree(&raw, expected.len() / 2)
        .map_err(|_| invalid_plan())?;
    if !super::rollback_change_preview::digest_matches("commit", &raw, &record.candidate_sha)
        || tree != record.target_tree_sha
        || parents != vec![expected.clone()]
        || isolated.join("objects/info/alternates").exists()
        || fs::read(isolated.join("shallow")).ok().as_deref()
            != Some(format!("{expected}\n").as_bytes())
    {
        return Err(invalid_plan());
    }
    let url = &record.source.evidence.remote_url;
    let authentication = auth_for_url(url, credential)?;
    let reference = format!("refs/heads/{}", record.source.evidence.branch);
    let lease = format!("--force-with-lease={reference}:{expected}");
    let refspec = format!("{}:{reference}", record.candidate_sha);
    // Exact lease supplies atomic compare-and-swap. The checked single-parent
    // relation above independently proves the only permitted update is FF.
    validate_recorded_push_target(root, &record.source)?;
    before_write()?;
    let output = run_git(
        isolated,
        &[
            "-c",
            "http.followRedirects=false",
            "push",
            "--porcelain",
            "--no-thin",
            "--no-verify",
            "--no-follow-tags",
            "--no-signed",
            "--recurse-submodules=no",
            &lease,
            "--",
            url,
            &refspec,
        ],
        authentication,
        None,
    )?;
    ensure_git_success(&output, "rollback_remote_write_unconfirmed")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    static FIXTURE_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn plan_is_one_time_and_rejects_changed_baseline() {
        let _lock = FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let repo = fixture();
        fs::write(repo.path().join("a.md"), "changed\n").unwrap();
        fixture_git(repo.path(), &["add", "a.md"]);
        let store = GitPublishStore::default();
        let session = Uuid::new_v4().to_string();
        let plan = store.plan_commit(&session, repo.path(), "update").unwrap();
        fs::write(repo.path().join("a.md"), "changed again\n").unwrap();
        fixture_git(repo.path(), &["add", "a.md"]);
        assert_eq!(
            store
                .execute(&plan.plan_id, &session, true, None)
                .unwrap_err()
                .code,
            "git_publish_baseline_changed"
        );
        assert_eq!(
            store
                .execute(&plan.plan_id, &session, true, None)
                .unwrap_err()
                .code,
            "git_publish_plan_not_found"
        );
    }

    #[test]
    fn commit_uses_staged_content_and_disables_hooks() {
        let _lock = FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let repo = fixture();
        fs::write(repo.path().join("a.md"), "staged\n").unwrap();
        fixture_git(repo.path(), &["add", "a.md"]);
        let hooks = repo.path().join(".git/hooks/pre-commit");
        fs::write(&hooks, "#!/bin/sh\nexit 23\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&hooks, fs::Permissions::from_mode(0o755)).unwrap();
        }
        fs::write(repo.path().join("a.md"), "unstaged\n").unwrap();
        let store = GitPublishStore::default();
        let session = Uuid::new_v4().to_string();
        let plan = store
            .plan_commit(&session, repo.path(), "staged only")
            .unwrap();
        store.execute(&plan.plan_id, &session, true, None).unwrap();
        assert_eq!(
            git_text(repo.path(), &["show", "HEAD:a.md"]).unwrap(),
            "staged"
        );
        assert_eq!(
            fs::read_to_string(repo.path().join("a.md")).unwrap(),
            "unstaged\n"
        );
    }

    #[test]
    fn rejects_dangerous_remote_urls() {
        for remote in [
            "https://token@github.com/o/r.git",
            "git@evil.example:o/r.git",
            "ext::sh -c x",
            "https://github.com/o/r.git?x=1",
        ] {
            assert!(validate_remote_url(remote).is_err(), "accepted {remote}");
        }
        assert!(matches!(
            validate_remote_url("https://github.com/o/r.git"),
            Ok(RemoteTransport::Https)
        ));
    }

    #[test]
    fn askpass_distinguishes_username_and_password() {
        assert_eq!(
            askpass_response("Username for remote:", "user", "secret"),
            Some("user")
        );
        assert_eq!(
            askpass_response("Password for remote:", "user", "secret"),
            Some("secret")
        );
        assert_eq!(askpass_response("unknown", "user", "secret"), None);
    }

    #[test]
    fn push_retry_uses_a_frozen_sha_and_is_one_time_after_exact_remote_confirmation() {
        let _lock = FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let (repo, remote) = retry_fixture();
        commit_file(repo.path(), "a.md", "pending\n", "pending");
        let store = GitPublishStore::default();
        let session = Uuid::new_v4().to_string();
        let plan = store
            .plan_push_retry(&session, repo.path(), "origin", None)
            .unwrap();
        assert_eq!(plan.pending_commit_count, 1);
        assert_eq!(plan.changed_paths, vec!["a.md"]);
        let local = inspect_push_retry_local(repo.path(), "origin").unwrap();
        let isolated = network_isolation(&local).unwrap();
        assert!(run_git(
            &isolated.root,
            &["cat-file", "-e", &format!("{}^{{commit}}", plan.head)],
            None,
            None,
        )
        .unwrap()
        .status
        .success());
        let receipt = store
            .execute_push_retry(&plan.plan_id, &session, None)
            .unwrap();
        assert!(receipt.verified);
        assert_eq!(receipt.head, plan.head);
        assert_eq!(
            fixture_git_text(remote.path(), &["rev-parse", "refs/heads/main"]),
            plan.head
        );
        assert_eq!(
            store
                .execute_push_retry(&plan.plan_id, &session, None)
                .unwrap_err()
                .code,
            "git_push_retry_plan_not_found"
        );
    }

    #[test]
    fn push_retry_uses_the_unique_push_url_not_the_fetch_url() {
        let _lock = FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let repo = fixture();
        let fetch_remote = bare_remote();
        let push_remote = bare_remote();
        let fetch_url = format!("file://{}", fetch_remote.path().display());
        let push_url = format!("file://{}", push_remote.path().display());
        fixture_git(repo.path(), &["remote", "add", "origin", &fetch_url]);
        fixture_git(
            repo.path(),
            &["remote", "set-url", "--push", "origin", &push_url],
        );
        fixture_git(
            repo.path(),
            &["push", "-q", &push_url, "main:refs/heads/main"],
        );
        commit_file(repo.path(), "a.md", "pending\n", "pending");
        let store = GitPublishStore::default();
        let session = Uuid::new_v4().to_string();
        let plan = store
            .plan_push_retry(&session, repo.path(), "origin", None)
            .unwrap();
        assert_eq!(plan.remote_url, push_url);
        store
            .execute_push_retry(&plan.plan_id, &session, None)
            .unwrap();
        assert_eq!(
            fixture_git_text(push_remote.path(), &["rev-parse", "refs/heads/main"]),
            plan.head
        );
        assert!(!fixture_git_status(
            fetch_remote.path(),
            &["show-ref", "--verify", "refs/heads/main"]
        ));
    }

    #[test]
    fn push_retry_reviews_paths_touched_by_intermediate_commits() {
        let _lock = FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let (repo, _remote) = retry_fixture();
        commit_file(repo.path(), "secret.md", "temporary\n", "add temporary");
        fixture_git(repo.path(), &["rm", "-q", "secret.md"]);
        fixture_git(repo.path(), &["commit", "-q", "-m", "remove temporary"]);
        let store = GitPublishStore::default();
        let session = Uuid::new_v4().to_string();
        let plan = store
            .plan_push_retry(&session, repo.path(), "origin", None)
            .unwrap();
        assert_eq!(plan.pending_commit_count, 2);
        assert_eq!(plan.changed_paths, vec!["secret.md"]);
    }

    #[test]
    fn push_retry_reviews_paths_added_only_while_resolving_a_merge() {
        let _lock = FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let (repo, _remote) = retry_fixture();
        fixture_git(repo.path(), &["checkout", "-q", "-b", "side"]);
        commit_file(repo.path(), "side.md", "side\n", "side");
        fixture_git(repo.path(), &["checkout", "-q", "main"]);
        commit_file(repo.path(), "main.md", "main\n", "main");
        fixture_git(repo.path(), &["merge", "--no-commit", "side"]);
        fs::write(repo.path().join("merge-only.md"), "resolution\n").unwrap();
        fixture_git(repo.path(), &["add", "merge-only.md"]);
        fixture_git(repo.path(), &["commit", "-q", "-m", "merge side"]);
        let store = GitPublishStore::default();
        let session = Uuid::new_v4().to_string();
        let plan = store
            .plan_push_retry(&session, repo.path(), "origin", None)
            .unwrap();
        assert_eq!(
            plan.changed_paths,
            vec![
                "main.md".to_string(),
                "merge-only.md".to_string(),
                "side.md".to_string(),
            ]
        );
    }

    #[test]
    fn push_retry_ignores_source_repository_replace_refs_when_reviewing_history() {
        let _lock = FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let (repo, remote) = retry_fixture();
        commit_file(repo.path(), "secret.md", "pending\n", "pending secret");
        fixture_git(repo.path(), &["rm", "-q", "secret.md"]);
        fixture_git(
            repo.path(),
            &["commit", "-q", "-m", "remove pending secret"],
        );
        let head = fixture_git_text(repo.path(), &["rev-parse", "HEAD"]);
        let base = fixture_git_text(remote.path(), &["rev-parse", "refs/heads/main"]);
        let head_tree = format!("{head}^{{tree}}");
        let replacement = fixture_git_text(
            repo.path(),
            &[
                "commit-tree",
                &head_tree,
                "-p",
                &base,
                "-m",
                "replace pending history",
            ],
        );
        fixture_git(repo.path(), &["replace", &head, &replacement]);
        assert!(fixture_git_text(
            repo.path(),
            &[
                "log",
                "--format=",
                "--name-only",
                "-z",
                "-m",
                "--no-renames",
                &format!("{base}..{head}"),
                "--",
            ],
        )
        .is_empty());
        let store = GitPublishStore::default();
        let session = Uuid::new_v4().to_string();
        let plan = store
            .plan_push_retry(&session, repo.path(), "origin", None)
            .unwrap();
        assert_eq!(plan.pending_commit_count, 2);
        assert_eq!(plan.changed_paths, vec!["secret.md"]);
    }

    #[test]
    fn isolated_retry_network_does_not_read_a_rewritten_source_repository_config() {
        let _lock = FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let (repo, remote) = retry_fixture();
        let other_remote = bare_remote();
        commit_file(repo.path(), "a.md", "pending\n", "pending");
        let baseline = inspect_push_retry_local(repo.path(), "origin").unwrap();
        let remote_before = fixture_git_text(remote.path(), &["rev-parse", "refs/heads/main"]);
        let isolation = network_isolation(&baseline).unwrap();
        let other_url = format!("file://{}", other_remote.path().display());
        fixture_git(
            repo.path(),
            &[
                "config",
                &format!("url.{other_url}.insteadOf"),
                &baseline.remote_url,
            ],
        );
        assert!(fixture_git_text(
            repo.path(),
            &[
                "ls-remote",
                "--heads",
                "--refs",
                &baseline.remote_url,
                "refs/heads/main",
            ],
        )
        .is_empty());
        assert_eq!(
            live_remote_sha(&isolation.root, &baseline.remote_url, "main", None).unwrap(),
            remote_before
        );
        let source = format!("{}:refs/heads/main", baseline.head);
        let pushed = run_git(
            &isolation.root,
            &[
                "push",
                "--porcelain",
                "--no-verify",
                "--no-recurse-submodules",
                "--no-follow-tags",
                "--receive-pack=git-receive-pack",
                &baseline.remote_url,
                &source,
            ],
            None,
            None,
        )
        .unwrap();
        assert!(pushed.status.success());
        assert_eq!(
            fixture_git_text(remote.path(), &["rev-parse", "refs/heads/main"]),
            baseline.head
        );
        assert!(!fixture_git_status(
            other_remote.path(),
            &["show-ref", "--verify", "refs/heads/main"]
        ));
    }

    #[test]
    fn push_retry_rejects_multiple_push_urls_and_effective_url_rewrites() {
        let _lock = FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let (repo, _remote) = retry_fixture();
        let additional = bare_remote();
        let primary_url = fixture_git_text(repo.path(), &["remote", "get-url", "--push", "origin"]);
        let additional_url = format!("file://{}", additional.path().display());
        fixture_git(
            repo.path(),
            &["remote", "set-url", "--push", "origin", &primary_url],
        );
        fixture_git(
            repo.path(),
            &[
                "remote",
                "set-url",
                "--add",
                "--push",
                "origin",
                &additional_url,
            ],
        );
        let store = GitPublishStore::default();
        let session = Uuid::new_v4().to_string();
        assert_eq!(
            store
                .plan_push_retry(&session, repo.path(), "origin", None)
                .unwrap_err()
                .code,
            "git_push_retry_push_remote_ambiguous"
        );
        fixture_git(
            repo.path(),
            &[
                "remote",
                "set-url",
                "--delete",
                "--push",
                "origin",
                &additional_url,
            ],
        );
        fixture_git(
            repo.path(),
            &[
                "config",
                "url.file:///tmp/.insteadOf",
                "https://github.com/",
            ],
        );
        assert_eq!(
            store
                .plan_push_retry(&session, repo.path(), "origin", None)
                .unwrap_err()
                .code,
            "git_push_retry_url_rewrite_not_allowed"
        );
    }

    #[test]
    fn push_retry_does_not_follow_annotated_tags() {
        let _lock = FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let (repo, remote) = retry_fixture();
        commit_file(repo.path(), "a.md", "pending\n", "pending");
        fixture_git(repo.path(), &["tag", "-a", "retry-tag", "-m", "retry tag"]);
        fixture_git(repo.path(), &["config", "push.followTags", "true"]);
        let store = GitPublishStore::default();
        let session = Uuid::new_v4().to_string();
        let plan = store
            .plan_push_retry(&session, repo.path(), "origin", None)
            .unwrap();
        store
            .execute_push_retry(&plan.plan_id, &session, None)
            .unwrap();
        assert!(!fixture_git_status(
            remote.path(),
            &["show-ref", "--verify", "refs/tags/retry-tag"],
        ));
    }

    #[test]
    fn push_retry_rejects_head_drift_before_any_push_attempt() {
        let _lock = FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let (repo, _remote) = retry_fixture();
        commit_file(repo.path(), "a.md", "pending\n", "pending");
        let store = GitPublishStore::default();
        let session = Uuid::new_v4().to_string();
        let plan = store
            .plan_push_retry(&session, repo.path(), "origin", None)
            .unwrap();
        commit_file(repo.path(), "later.md", "later\n", "later");
        assert_eq!(
            store
                .execute_push_retry(&plan.plan_id, &session, None)
                .unwrap_err()
                .code,
            "git_push_retry_baseline_changed"
        );
    }

    #[test]
    fn push_retry_rejects_a_repository_directory_replaced_at_the_same_path() {
        let _lock = FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let (repo, remote) = retry_fixture();
        commit_file(repo.path(), "a.md", "pending\n", "pending");
        let store = GitPublishStore::default();
        let session = Uuid::new_v4().to_string();
        let plan = store
            .plan_push_retry(&session, repo.path(), "origin", None)
            .unwrap();
        let replacement_holder = tempfile::tempdir().unwrap();
        let backup = replacement_holder.path().join("original");
        let root_path = repo.path().to_path_buf();
        fs::rename(&root_path, &backup).unwrap();
        let backup_url = format!("file://{}", backup.display());
        assert!(Command::new("git")
            .args(["clone", "-q", "-b", "main", &backup_url])
            .arg(&root_path)
            .status()
            .unwrap()
            .success());
        let remote_url = format!("file://{}", remote.path().display());
        fixture_git(&root_path, &["remote", "set-url", "origin", &remote_url]);
        assert_eq!(
            store
                .execute_push_retry(&plan.plan_id, &session, None)
                .unwrap_err()
                .code,
            "git_push_retry_baseline_changed"
        );
    }

    #[test]
    fn push_retry_rejects_dirty_index_and_worktree_before_contacting_remote() {
        let _lock = FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let (repo, _remote) = retry_fixture();
        let store = GitPublishStore::default();
        let session = Uuid::new_v4().to_string();
        fs::write(repo.path().join("a.md"), "staged\n").unwrap();
        fixture_git(repo.path(), &["add", "a.md"]);
        assert_eq!(
            store
                .plan_push_retry(&session, repo.path(), "origin", None)
                .unwrap_err()
                .code,
            "git_push_retry_dirty_index"
        );
        fixture_git(repo.path(), &["reset", "--", "a.md"]);
        fs::write(repo.path().join("a.md"), "unstaged\n").unwrap();
        assert_eq!(
            store
                .plan_push_retry(&session, repo.path(), "origin", None)
                .unwrap_err()
                .code,
            "git_push_retry_dirty_worktree"
        );
    }

    #[test]
    fn push_retry_rejects_remote_drift_and_consumes_the_review() {
        let _lock = FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let (repo, remote) = retry_fixture();
        commit_file(repo.path(), "a.md", "local\n", "local");
        let store = GitPublishStore::default();
        let session = Uuid::new_v4().to_string();
        let plan = store
            .plan_push_retry(&session, repo.path(), "origin", None)
            .unwrap();
        let other = tempfile::tempdir().unwrap();
        let remote_url = format!("file://{}", remote.path().display());
        fixture_git(
            other.path(),
            &["clone", "-q", "-b", "main", &remote_url, "."],
        );
        fixture_git(other.path(), &["config", "user.name", "Other"]);
        fixture_git(
            other.path(),
            &["config", "user.email", "other@example.invalid"],
        );
        commit_file(other.path(), "remote.md", "remote\n", "remote");
        fixture_git(other.path(), &["push", "-q", "origin", "main"]);
        assert_eq!(
            store
                .execute_push_retry(&plan.plan_id, &session, None)
                .unwrap_err()
                .code,
            "git_push_retry_diverged"
        );
        assert_eq!(
            store
                .execute_push_retry(&plan.plan_id, &session, None)
                .unwrap_err()
                .code,
            "git_push_retry_plan_not_found"
        );
    }

    #[test]
    fn push_retry_reports_unknown_when_remote_cannot_be_exactly_confirmed() {
        let _lock = FIXTURE_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let (repo, remote) = retry_fixture();
        commit_file(repo.path(), "a.md", "pending\n", "pending");
        let original = fixture_git_text(remote.path(), &["rev-parse", "refs/heads/main"]);
        let hook = remote.path().join("hooks/post-receive");
        fs::write(
            &hook,
            format!("#!/bin/sh\ngit update-ref refs/heads/main {original}\n"),
        )
        .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&hook, fs::Permissions::from_mode(0o755)).unwrap();
        }
        let store = GitPublishStore::default();
        let session = Uuid::new_v4().to_string();
        let plan = store
            .plan_push_retry(&session, repo.path(), "origin", None)
            .unwrap();
        assert_eq!(
            store
                .execute_push_retry(&plan.plan_id, &session, None)
                .unwrap_err()
                .code,
            "git_push_retry_outcome_unknown"
        );
    }

    #[test]
    fn expired_push_retry_plan_is_rejected_before_repository_access() {
        let store = GitPublishStore::default();
        let id = Uuid::new_v4().to_string();
        let session = Uuid::new_v4().to_string();
        store.retry_plans.lock().unwrap().insert(
            id.clone(),
            PlannedPushRetry {
                root: PathBuf::from("/"),
                session_id: session.clone(),
                remote: "origin".to_string(),
                baseline: PushRetryBaseline {
                    root_identity: DirectoryIdentity {
                        device: 0,
                        inode: 0,
                    },
                    git_common_directory: PathBuf::from("/"),
                    git_common_directory_identity: DirectoryIdentity {
                        device: 0,
                        inode: 0,
                    },
                    object_format: "sha1".to_string(),
                    head: "a".repeat(40),
                    branch: "main".to_string(),
                    index_digest: "b".repeat(40),
                    worktree_digest: String::new(),
                    remote_url: "https://github.com/example/repo.git".to_string(),
                    observed_remote_sha: "c".repeat(40),
                },
                changed_paths: vec!["a.md".to_string()],
                pending_commit_count: 1,
                expires_at: SystemTime::now() - Duration::from_secs(1),
            },
        );
        assert_eq!(
            store
                .execute_push_retry(&id, &session, None)
                .unwrap_err()
                .code,
            "git_push_retry_plan_expired"
        );
        assert_eq!(
            store
                .execute_push_retry(&id, &session, None)
                .unwrap_err()
                .code,
            "git_push_retry_plan_not_found"
        );
    }

    #[test]
    fn expired_entry_is_rejected() {
        let store = GitPublishStore::default();
        let id = Uuid::new_v4().to_string();
        store.plans.lock().unwrap().insert(
            id.clone(),
            PlannedOperation {
                push_identity: None,
                root: PathBuf::from("/"),
                session_id: Uuid::new_v4().to_string(),
                operation: GitPublishOperation::Fetch,
                message: None,
                remote: None,
                remote_url: None,
                baseline: Baseline {
                    head: String::new(),
                    branch: None,
                    index_digest: String::new(),
                    remote_digest: None,
                },
                summary: GitPublishSummary {
                    head: String::new(),
                    branch: None,
                    remote: None,
                    remote_url: None,
                    staged_tree: None,
                    message_preview: None,
                    baseline_digest: String::new(),
                },
                expires_at: SystemTime::now() - Duration::from_secs(1),
            },
        );
        let err = store
            .execute(&id, &Uuid::new_v4().to_string(), true, None)
            .unwrap_err();
        assert_eq!(err.code, "git_publish_plan_expired");
    }

    fn fixture() -> tempfile::TempDir {
        let repo = tempfile::tempdir().unwrap();
        fixture_git(repo.path(), &["init", "-q", "-b", "main"]);
        fixture_git(repo.path(), &["config", "user.name", "Tests"]);
        fixture_git(
            repo.path(),
            &["config", "user.email", "tests@example.invalid"],
        );
        fs::write(repo.path().join("a.md"), "before\n").unwrap();
        fixture_git(repo.path(), &["add", "a.md"]);
        fixture_git(repo.path(), &["commit", "-q", "-m", "initial"]);
        repo
    }
    fn retry_fixture() -> (tempfile::TempDir, tempfile::TempDir) {
        let repo = fixture();
        let remote = tempfile::tempdir().unwrap();
        fixture_git(remote.path(), &["init", "--bare", "-q"]);
        let remote_url = format!("file://{}", remote.path().display());
        fixture_git(repo.path(), &["remote", "add", "origin", &remote_url]);
        fixture_git(
            repo.path(),
            &["push", "-q", "origin", "main:refs/heads/main"],
        );
        (repo, remote)
    }
    fn bare_remote() -> tempfile::TempDir {
        let remote = tempfile::tempdir().unwrap();
        fixture_git(remote.path(), &["init", "--bare", "-q"]);
        remote
    }
    fn commit_file(root: &Path, path: &str, contents: &str, message: &str) {
        fs::write(root.join(path), contents).unwrap();
        fixture_git(root, &["add", path]);
        fixture_git(root, &["commit", "-q", "-m", message]);
    }
    fn fixture_git_text(root: &Path, args: &[&str]) -> String {
        let output = Command::new("git")
            .arg("-C")
            .arg(root)
            .args(args)
            .output()
            .unwrap();
        assert!(output.status.success());
        String::from_utf8(output.stdout).unwrap().trim().to_string()
    }
    fn fixture_git_status(root: &Path, args: &[&str]) -> bool {
        Command::new("git")
            .arg("-C")
            .arg(root)
            .args(args)
            .status()
            .unwrap()
            .success()
    }
    fn fixture_git(root: &Path, args: &[&str]) {
        assert!(Command::new("git")
            .arg("-C")
            .arg(root)
            .args(args)
            .status()
            .unwrap()
            .success());
    }
}

#[cfg(test)]
#[path = "git_publish_ledger_tests.rs"]
mod ledger_tests;
