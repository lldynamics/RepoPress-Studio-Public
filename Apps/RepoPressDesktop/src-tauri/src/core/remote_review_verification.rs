//! Correlated PR/MR execution and bounded, GET-only reconciliation.
use super::*;
use crate::core::remote_review_ledger::{
    RemoteReviewEvidence, RemoteReviewLedgerStore, RemoteReviewRecord, ReviewVerification,
};
use crate::core::{CommandError, CommandResult, PublishEvidence, PushOperation};
use sha2::{Digest, Sha256};
use std::path::Path;

const PAGE_SIZE: usize = 20;
const MAX_PAGES: usize = 5;
const MAX_PLANS: usize = 32;
fn command_error(error: RemotePublishError) -> CommandError {
    CommandError::new(error.code, error.message)
}
fn unknown() -> CommandError {
    CommandError::new(
        "remote_review_outcome_unknown",
        "The PR/MR may have been created. Verify its durable record without creating it again.",
    )
}
fn invalid() -> RemotePublishError {
    RemotePublishError::new(
        "invalid_review_evidence",
        "The frozen review evidence is invalid.",
    )
}
pub(super) fn text_hash(text: &str) -> String {
    format!("{:x}", Sha256::digest(text.as_bytes()))
}
pub(super) fn marker_text(id: &str) -> String {
    format!("<!-- repopress-review-plan:{id} -->")
}
fn push_target(e: &RemoteReviewEvidence) -> PublishEvidence {
    PublishEvidence {
        repository_path: e.repository_path.clone(),
        repository_identity: e.repository_identity.clone(),
        operation: PushOperation::Push,
        remote: e.remote.clone(),
        remote_url: e.remote_url.clone(),
        branch: e.source_branch.clone(),
        expected_sha: e.source_sha.clone(),
        observed_before_sha: None,
        changed_paths: Vec::new(),
    }
}
pub fn validate_review_repository(
    e: &RemoteReviewEvidence,
    require_head: bool,
) -> CommandResult<()> {
    validate_review_evidence(e).map_err(command_error)?;
    let root = Path::new(&e.repository_path);
    crate::core::git_publish::validate_publish_target(root, &push_target(e))?;
    if require_head {
        let current = crate::core::git_publish::capture_review_target(root, &e.remote)?;
        if current != push_target(e) {
            return Err(CommandError::new(
                "remote_review_baseline_changed",
                "The reviewed repository, branch or commit changed.",
            ));
        }
    }
    Ok(())
}
pub fn validate_review_evidence(e: &RemoteReviewEvidence) -> Result<(), RemotePublishError> {
    crate::core::git_publish::validate_publish_evidence(&push_target(e)).map_err(|_| invalid())?;
    validate_owner(e.provider, &e.owner)?;
    validate_identifier(&e.project)?;
    validate_branch(&e.source_branch)?;
    validate_branch(&e.target_branch)?;
    if e.source_branch == e.target_branch
        || e.remote_project_id > 9_007_199_254_740_991
        || e.title_sha256.len() != 64
        || e.body_sha256.len() != 64
        || !crate::core::publish_ledger::valid_sha(&e.title_sha256)
        || !crate::core::publish_ledger::valid_sha(&e.body_sha256)
        || Uuid::parse_str(&e.marker).is_err()
    {
        return Err(invalid());
    }
    let host = match e.provider {
        RemoteProvider::Github => "github.com",
        RemoteProvider::Gitlab => "gitlab.com",
    };
    let path = format!("{}/{}", e.owner, e.project);
    let allowed = [
        format!("https://{host}/{path}"),
        format!("https://{host}/{path}.git"),
        format!("git@{host}:{path}"),
        format!("git@{host}:{path}.git"),
        format!("ssh://git@{host}/{path}"),
        format!("ssh://git@{host}/{path}.git"),
    ];
    if !allowed.contains(&e.remote_url) {
        return Err(invalid());
    }
    Ok(())
}
pub fn validate_review_url(
    e: &RemoteReviewEvidence,
    number: u64,
    url: &str,
) -> Result<(), RemotePublishError> {
    if number == 0 || number > 9_007_199_254_740_991 {
        return Err(invalid());
    }
    let expected = match e.provider {
        RemoteProvider::Github => {
            format!("https://github.com/{}/{}/pull/{number}", e.owner, e.project)
        }
        RemoteProvider::Gitlab => format!(
            "https://gitlab.com/{}/{}/-/merge_requests/{number}",
            e.owner, e.project
        ),
    };
    let same_url = if e.provider == RemoteProvider::Github {
        url.strip_prefix("https://github.com/")
            .and_then(|path| path.strip_suffix(&format!("/pull/{number}")))
            .is_some_and(|path| same_project_path(e, path))
    } else {
        url == expected
    };
    if !same_url {
        return Err(invalid());
    }
    Ok(())
}
fn same_project_path(e: &RemoteReviewEvidence, actual: &str) -> bool {
    let expected = format!("{}/{}", e.owner, e.project);
    if e.provider == RemoteProvider::Github {
        actual.eq_ignore_ascii_case(&expected)
    } else {
        actual == expected
    }
}
impl RemotePublishStore {
    pub fn plan_recorded_review_request(
        &self,
        mut draft: ReviewRequestDraft,
        target: PublishEvidence,
    ) -> Result<(RemotePublishPlan, RemoteReviewEvidence, String), RemotePublishError> {
        validate_draft(&draft)?;
        if draft.source_branch != target.branch {
            return Err(invalid());
        }
        let plan_id = Uuid::new_v4().to_string();
        draft.body = format!(
            "{}\n\n{}",
            draft.body.replace("\r\n", "\n").replace('\r', "\n"),
            marker_text(&plan_id)
        );
        validate_draft(&draft)?;
        let evidence = RemoteReviewEvidence {
            repository_path: target.repository_path,
            repository_identity: target.repository_identity,
            remote: target.remote,
            remote_url: target.remote_url,
            provider: draft.provider,
            owner: draft.owner.clone(),
            project: draft.project.clone(),
            remote_project_id: 0,
            source_branch: draft.source_branch.clone(),
            target_branch: draft.target_branch.clone(),
            source_sha: target.expected_sha,
            title_sha256: text_hash(&draft.title),
            body_sha256: text_hash(&draft.body),
            marker: plan_id.clone(),
        };
        validate_review_evidence(&evidence)?;
        let expires_at = unix_seconds().saturating_add(PLAN_LIFETIME.as_secs());
        let plan = RemotePublishPlan {
            plan_id: plan_id.clone(),
            expires_at_unix_seconds: expires_at,
            request_summary: summary(&draft),
        };
        let body_preview = draft.body.clone();
        let mut plans = self.plans.lock().map_err(|_| invalid())?;
        plans.retain(|_, plan| plan.expires_at > unix_seconds());
        if plans.len() >= MAX_PLANS {
            return Err(RemotePublishError::new(
                "review_plan_limit",
                "Too many pending review plans.",
            ));
        }
        plans.insert(
            plan_id,
            PendingPlan {
                draft,
                expires_at,
                evidence: Some(evidence.clone()),
            },
        );
        Ok((plan, evidence, body_preview))
    }

    /// The sole production POST path. Every possible POST has a durable record.
    pub async fn create_recorded_review_request(
        &self,
        plan_id: &str,
        expected: &RemoteReviewEvidence,
        token: &str,
        ledger: &RemoteReviewLedgerStore,
    ) -> CommandResult<RemotePublishReceipt> {
        let pending = self
            .plans
            .lock()
            .map_err(|_| command_error(invalid()))?
            .remove(plan_id)
            .ok_or_else(|| {
                CommandError::new(
                    "plan_not_found",
                    "The creation plan was already used or expired.",
                )
            })?;
        if pending.expires_at <= unix_seconds() || pending.evidence.as_ref() != Some(expected) {
            return Err(CommandError::new(
                "plan_expired",
                "The creation plan expired or changed.",
            ));
        }
        validate_token(token).map_err(command_error)?;
        validate_review_repository(expected, true)?;
        // Freeze the hosted numeric identity and require the remote source ref to
        // equal the locally reviewed SHA before making any creation request.
        let mut evidence = expected.clone();
        evidence.remote_project_id = self
            .read_project_id(&evidence, token)
            .await
            .map_err(command_error)?;
        self.require_source_sha(&evidence, token)
            .await
            .map_err(command_error)?;
        validate_review_repository(&evidence, true)?;
        let request = build_create_request(&pending.draft, token).map_err(command_error)?;
        let attempt = ledger.begin(evidence.clone())?;
        validate_review_repository(&evidence, true)?;
        let observation = async {
            let response = self.transport.execute(request).await?;
            require_success(&response)?;
            let receipt = parse_receipt(evidence.provider, &response.body)?;
            validate_review_url(&evidence, receipt.review_number, &receipt.web_url)?;
            self.read_matching_detail(&evidence, receipt.review_number, token)
                .await
        }
        .await;
        if validate_review_repository(&evidence, false).is_err() {
            let _ = attempt.finish(ReviewVerification::Unavailable, None);
            return Err(unknown());
        }
        match observation {
            Ok(Some(receipt)) => {
                attempt
                    .finish(ReviewVerification::Matched, Some(receipt.clone()))
                    .map_err(|_| unknown())?;
                Ok(receipt)
            }
            _ => {
                let _ = attempt.finish(ReviewVerification::Unavailable, None);
                Err(unknown())
            }
        }
    }

    /// Only GET requests. Bounded scans never infer that creation did not occur.
    pub async fn observe_review(
        &self,
        record: &RemoteReviewRecord,
        token: &str,
    ) -> Result<(ReviewVerification, Option<RemotePublishReceipt>), RemotePublishError> {
        let e = &record.evidence;
        validate_review_evidence(e)?;
        validate_token(token)?;
        if e.remote_project_id == 0 {
            return Err(invalid());
        }
        if self.read_project_id(e, token).await? != e.remote_project_id {
            return Err(invalid());
        }
        if let Some(number) = record.review_number {
            return Ok(match self.read_matching_detail(e, number, token).await? {
                Some(receipt) => (ReviewVerification::Matched, Some(receipt)),
                None => (ReviewVerification::NoMatch, None),
            });
        }
        let mut candidates = Vec::new();
        let mut complete = false;
        for page in 1..=MAX_PAGES {
            let query = match e.provider {
                RemoteProvider::Github => format!("?state=all&head={}&base={}&sort=created&direction=desc&per_page={PAGE_SIZE}&page={page}", percent_encode(&format!("{}:{}", e.owner, e.source_branch)), percent_encode(&e.target_branch)),
                RemoteProvider::Gitlab => format!("?state=all&source_branch={}&target_branch={}&order_by=created_at&sort=desc&per_page={PAGE_SIZE}&page={page}", percent_encode(&e.source_branch), percent_encode(&e.target_branch)),
            };
            let value = self
                .get_json(e, &format!("{}{}", review_endpoint(e), query), token)
                .await?;
            let rows = value.as_array().ok_or_else(invalid)?;
            if rows.len() > PAGE_SIZE {
                return Err(invalid());
            }
            for row in rows {
                let body_key = if e.provider == RemoteProvider::Github {
                    "body"
                } else {
                    "description"
                };
                if row
                    .get(body_key)
                    .and_then(serde_json::Value::as_str)
                    .is_some_and(|body| body.contains(&marker_text(&e.marker)))
                {
                    let number_key = if e.provider == RemoteProvider::Github {
                        "number"
                    } else {
                        "iid"
                    };
                    let number = row
                        .get(number_key)
                        .and_then(serde_json::Value::as_u64)
                        .ok_or_else(invalid)?;
                    candidates.push(number);
                }
            }
            if candidates.len() > 1 {
                return Ok((ReviewVerification::Ambiguous, None));
            }
            if rows.len() < PAGE_SIZE {
                complete = true;
                break;
            }
        }
        if !complete {
            return Ok((ReviewVerification::Ambiguous, None));
        }
        if candidates.is_empty() {
            return Ok((ReviewVerification::NoMatch, None));
        }
        Ok(
            match self.read_matching_detail(e, candidates[0], token).await? {
                Some(receipt) => (ReviewVerification::Matched, Some(receipt)),
                None => (ReviewVerification::NoMatch, None),
            },
        )
    }
    async fn get_json(
        &self,
        e: &RemoteReviewEvidence,
        url: &str,
        token: &str,
    ) -> Result<serde_json::Value, RemotePublishError> {
        ensure_official_api(e.provider, url)?;
        let mut headers = vec![
            ("Accept".into(), "application/json".into()),
            ("User-Agent".into(), "RepoPressDesktop/0.1".into()),
        ];
        match e.provider {
            RemoteProvider::Github => {
                headers.push(("Authorization".into(), format!("Bearer {token}")));
                headers.push(("X-GitHub-Api-Version".into(), "2022-11-28".into()));
            }
            RemoteProvider::Gitlab => headers.push(("PRIVATE-TOKEN".into(), token.to_string())),
        }
        let response = self
            .transport
            .execute(PreparedRequest {
                method: HttpMethod::Get,
                url: url.to_string(),
                headers,
                json_body: None,
            })
            .await?;
        require_success(&response)?;
        parse_json(&response.body)
    }
    async fn read_project_id(
        &self,
        e: &RemoteReviewEvidence,
        token: &str,
    ) -> Result<u64, RemotePublishError> {
        let value = self.get_json(e, &project_endpoint(e), token).await?;
        let id = value
            .get("id")
            .and_then(serde_json::Value::as_u64)
            .filter(|id| *id > 0 && *id <= 9_007_199_254_740_991)
            .ok_or_else(invalid)?;
        let path_key = if e.provider == RemoteProvider::Github {
            "full_name"
        } else {
            "path_with_namespace"
        };
        if !value
            .get(path_key)
            .and_then(serde_json::Value::as_str)
            .is_some_and(|path| same_project_path(e, path))
        {
            return Err(invalid());
        }
        Ok(id)
    }
    async fn require_source_sha(
        &self,
        e: &RemoteReviewEvidence,
        token: &str,
    ) -> Result<(), RemotePublishError> {
        let path = match e.provider {
            RemoteProvider::Github => format!(
                "{}/branches/{}",
                project_endpoint(e),
                percent_encode(&e.source_branch)
            ),
            RemoteProvider::Gitlab => format!(
                "{}/repository/branches/{}",
                project_endpoint(e),
                percent_encode(&e.source_branch)
            ),
        };
        let value = self.get_json(e, &path, token).await?;
        let key = if e.provider == RemoteProvider::Github {
            "/commit/sha"
        } else {
            "/commit/id"
        };
        if value.get("name").and_then(serde_json::Value::as_str) != Some(e.source_branch.as_str())
            || value.pointer(key).and_then(serde_json::Value::as_str) != Some(e.source_sha.as_str())
        {
            return Err(RemotePublishError::new(
                "remote_review_source_changed",
                "Push the reviewed commit first; the hosted branch does not match its frozen SHA.",
            ));
        }
        Ok(())
    }
    async fn read_matching_detail(
        &self,
        e: &RemoteReviewEvidence,
        number: u64,
        token: &str,
    ) -> Result<Option<RemotePublishReceipt>, RemotePublishError> {
        if number == 0 || number > 9_007_199_254_740_991 {
            return Err(invalid());
        }
        let value = self
            .get_json(e, &format!("{}/{number}", review_endpoint(e)), token)
            .await?;
        match_detail(e, number, &value)
    }
}
fn project_endpoint(e: &RemoteReviewEvidence) -> String {
    match e.provider {
        RemoteProvider::Github => format!("https://api.github.com/repos/{}/{}", e.owner, e.project),
        RemoteProvider::Gitlab => format!(
            "https://gitlab.com/api/v4/projects/{}",
            encoded_project_path(&e.owner, &e.project)
        ),
    }
}
fn review_endpoint(e: &RemoteReviewEvidence) -> String {
    format!(
        "{}/{}",
        project_endpoint(e),
        if e.provider == RemoteProvider::Github {
            "pulls"
        } else {
            "merge_requests"
        }
    )
}
fn match_detail(
    e: &RemoteReviewEvidence,
    number: u64,
    value: &serde_json::Value,
) -> Result<Option<RemotePublishReceipt>, RemotePublishError> {
    let field = |key: &str| value.pointer(key).and_then(serde_json::Value::as_str);
    let integer = |key: &str| value.pointer(key).and_then(serde_json::Value::as_u64);
    let (body, url, actual_number, matches_target) = match e.provider {
        RemoteProvider::Github => (
            field("/body"),
            field("/html_url"),
            integer("/number"),
            field("/head/ref") == Some(e.source_branch.as_str())
                && field("/base/ref") == Some(e.target_branch.as_str())
                && field("/head/sha") == Some(e.source_sha.as_str())
                && field("/head/repo/full_name").is_some_and(|path| same_project_path(e, path))
                && field("/base/repo/full_name").is_some_and(|path| same_project_path(e, path))
                && integer("/head/repo/id") == Some(e.remote_project_id)
                && integer("/base/repo/id") == Some(e.remote_project_id),
        ),
        RemoteProvider::Gitlab => (
            field("/description"),
            field("/web_url"),
            integer("/iid"),
            field("/source_branch") == Some(e.source_branch.as_str())
                && field("/target_branch") == Some(e.target_branch.as_str())
                && field("/sha") == Some(e.source_sha.as_str())
                && field("/diff_refs/head_sha") == Some(e.source_sha.as_str())
                && integer("/project_id") == Some(e.remote_project_id)
                && integer("/source_project_id") == Some(e.remote_project_id)
                && integer("/target_project_id") == Some(e.remote_project_id),
        ),
    };
    let Some(body) = body else { return Ok(None) };
    let Some(title) = field("/title") else {
        return Ok(None);
    };
    let Some(url) = url else { return Ok(None) };
    if !matches_target
        || actual_number != Some(number)
        || !body.contains(&marker_text(&e.marker))
        || text_hash(body) != e.body_sha256
        || text_hash(title) != e.title_sha256
    {
        return Ok(None);
    }
    validate_review_url(e, number, url)?;
    Ok(Some(RemotePublishReceipt {
        provider: e.provider,
        review_number: number,
        web_url: url.to_string(),
    }))
}

#[cfg(test)]
#[path = "remote_review_verification_tests.rs"]
mod tests;
