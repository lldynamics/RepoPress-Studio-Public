#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROVIDER="${REMOTE_VERIFY_PROVIDER:-}"
MODE="${REMOTE_VERIFY_MODE:-}"
EXECUTE=0
WRITE_EVIDENCE=1
EVIDENCE_FILE="${REMOTE_VERIFY_EVIDENCE_FILE:-$ROOT_DIR/docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md}"
TIMESTAMP="$(date -u +"%Y%m%d%H%M%S")"

usage() {
  cat <<'USAGE'
Usage: script/verify_remote_publish_live.sh --provider github|gitlab --mode direct|review [--execute] [--no-write-evidence]

Runs a live, redacted external verification against a disposable test repository.
By default it only validates configuration and prints the planned operation.
Pass --execute to create a test commit or PR/MR through the provider API.

Required for --execute:
  REMOTE_VERIFY_TOKEN       Least-privilege test token.
  REMOTE_VERIFY_OWNER       GitHub owner or GitLab namespace/group.
  REMOTE_VERIFY_REPO        GitHub repo or GitLab project name.

Optional:
  REMOTE_VERIFY_BRANCH      Target branch. Default: main
  REMOTE_VERIFY_BASE_URL    GitHub API base or GitLab web base.
  REMOTE_VERIFY_PATH        Test file path to create/update.
  REMOTE_VERIFY_BRANCH_NAME Review branch for PR/MR mode.
  REMOTE_VERIFY_ALLOW_CUSTOM_PATH   Set to 1 to allow a path outside codex-live-verification/.
  REMOTE_VERIFY_ALLOW_CUSTOM_BRANCH Set to 1 to allow a review branch outside codex/live-verify-.
  REMOTE_VERIFY_EVIDENCE_FILE Evidence file to update.
  REMOTE_VERIFY_DEPLOYMENT_STATUS Optional redacted deployment status override. When omitted, the script checks provider deployment status.
  REMOTE_VERIFY_RELEASE_LEDGER    Redacted release ledger summary required when writing publish evidence.
  REMOTE_VERIFY_ROLLBACK_DRAFT    Optional redacted rollback draft summary for review mode.
  REMOTE_VERIFY_REVIEW_CLEANUP    Set to 1 in review mode to close PR/MR and delete the disposable review branch after evidence is recorded.
  REMOTE_VERIFY_TOKEN_SCOPE_SUMMARY Optional operator token-scope note appended to provider API permission evidence.

Examples:
  REMOTE_VERIFY_TOKEN=... REMOTE_VERIFY_OWNER=me REMOTE_VERIFY_REPO=test \
    script/verify_remote_publish_live.sh --provider github --mode direct --execute

  REMOTE_VERIFY_TOKEN=... REMOTE_VERIFY_OWNER=group REMOTE_VERIFY_REPO=site \
    script/verify_remote_publish_live.sh --provider gitlab --mode review --execute
USAGE
}

fail() {
  echo "remote publish live verification: $*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --provider)
      [[ "$#" -ge 2 ]] || fail "--provider requires github or gitlab"
      PROVIDER="$2"
      shift 2
      ;;
    --mode)
      [[ "$#" -ge 2 ]] || fail "--mode requires direct or review"
      MODE="$2"
      shift 2
      ;;
    --execute)
      EXECUTE=1
      shift
      ;;
    --no-write-evidence)
      WRITE_EVIDENCE=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ "$PROVIDER" == "github" || "$PROVIDER" == "gitlab" ]] || fail "provider must be github or gitlab"
[[ "$MODE" == "direct" || "$MODE" == "review" ]] || fail "mode must be direct or review"

TARGET_BRANCH="${REMOTE_VERIFY_BRANCH:-main}"
OWNER="${REMOTE_VERIFY_OWNER:-}"
REPO="${REMOTE_VERIFY_REPO:-}"
TOKEN="${REMOTE_VERIFY_TOKEN:-}"
TEST_PATH="${REMOTE_VERIFY_PATH:-codex-live-verification/${PROVIDER}-${MODE}-${TIMESTAMP}.md}"
REVIEW_BRANCH="${REMOTE_VERIFY_BRANCH_NAME:-codex/live-verify-${PROVIDER}-${MODE}-${TIMESTAMP}}"
DEPLOYMENT_STATUS="${REMOTE_VERIFY_DEPLOYMENT_STATUS:-}"
RELEASE_LEDGER="${REMOTE_VERIFY_RELEASE_LEDGER:-}"
ROLLBACK_DRAFT="${REMOTE_VERIFY_ROLLBACK_DRAFT:-}"
REVIEW_CLEANUP="${REMOTE_VERIFY_REVIEW_CLEANUP:-0}"
TOKEN_SCOPE_NOTE="${REMOTE_VERIFY_TOKEN_SCOPE_SUMMARY:-}"
ALLOW_CUSTOM_PATH="${REMOTE_VERIFY_ALLOW_CUSTOM_PATH:-0}"
ALLOW_CUSTOM_BRANCH="${REMOTE_VERIFY_ALLOW_CUSTOM_BRANCH:-0}"
provider_permission_summary=""
provider_review_artifact=""
review_cleanup_summary=""

validate_disposable_path() {
  local path="$1"
  [[ -n "$path" ]] || fail "REMOTE_VERIFY_PATH cannot be empty"
  [[ "$path" != /* ]] || fail "REMOTE_VERIFY_PATH must be repository-relative"
  [[ "$path" != *".."* ]] || fail "REMOTE_VERIFY_PATH cannot contain parent directory traversal"
  [[ "$path" != *"//"* ]] || fail "REMOTE_VERIFY_PATH cannot contain empty path segments"
  [[ "$path" != *"\\"* ]] || fail "REMOTE_VERIFY_PATH cannot contain backslashes"
  [[ "$path" != ".git"* && "$path" != *"/.git"* ]] || fail "REMOTE_VERIFY_PATH cannot target git internals"
  if [[ "$ALLOW_CUSTOM_PATH" != "1" && "$path" != codex-live-verification/* ]]; then
    fail "REMOTE_VERIFY_PATH must stay under codex-live-verification/ unless REMOTE_VERIFY_ALLOW_CUSTOM_PATH=1"
  fi
}

validate_disposable_review_branch() {
  local branch="$1"
  [[ -n "$branch" ]] || fail "REMOTE_VERIFY_BRANCH_NAME cannot be empty"
  [[ "$branch" != *".."* ]] || fail "REMOTE_VERIFY_BRANCH_NAME cannot contain parent directory traversal"
  [[ "$branch" != *" "* && "$branch" != *$'\t'* ]] || fail "REMOTE_VERIFY_BRANCH_NAME cannot contain whitespace"
  [[ "$branch" != /* && "$branch" != */ ]] || fail "REMOTE_VERIFY_BRANCH_NAME cannot start or end with slash"
  if [[ "$ALLOW_CUSTOM_BRANCH" != "1" && "$branch" != codex/live-verify-* ]]; then
    fail "REMOTE_VERIFY_BRANCH_NAME must start with codex/live-verify- unless REMOTE_VERIFY_ALLOW_CUSTOM_BRANCH=1"
  fi
}

validate_disposable_path "$TEST_PATH"
if [[ "$MODE" == "review" ]]; then
  validate_disposable_review_branch "$REVIEW_BRANCH"
fi
if [[ "$REVIEW_CLEANUP" != "0" && "$REVIEW_CLEANUP" != "1" ]]; then
  fail "REMOTE_VERIFY_REVIEW_CLEANUP must be 0 or 1"
fi
if [[ "$MODE" != "review" && "$REVIEW_CLEANUP" == "1" ]]; then
  fail "REMOTE_VERIFY_REVIEW_CLEANUP=1 is only valid with review mode"
fi

generated_review_rollback_draft() {
  echo "Generated review can be rolled back by closing the PR/MR, deleting review branch $REVIEW_BRANCH, and removing disposable verification file $TEST_PATH if it was merged into $TARGET_BRANCH."
}

if [[ "$MODE" == "review" && -z "${ROLLBACK_DRAFT//[[:space:]]/}" ]]; then
  ROLLBACK_DRAFT="$(generated_review_rollback_draft)"
fi

if [[ "$EXECUTE" == "1" ]]; then
  [[ -n "$TOKEN" ]] || fail "REMOTE_VERIFY_TOKEN is required with --execute"
  [[ -n "$OWNER" ]] || fail "REMOTE_VERIFY_OWNER is required with --execute"
  [[ -n "$REPO" ]] || fail "REMOTE_VERIFY_REPO is required with --execute"
  [[ -f "$EVIDENCE_FILE" ]] || fail "evidence file is missing: ${EVIDENCE_FILE#$ROOT_DIR/}"
  if [[ "$WRITE_EVIDENCE" == "1" ]]; then
    [[ -n "${RELEASE_LEDGER//[[:space:]]/}" ]] || fail "REMOTE_VERIFY_RELEASE_LEDGER is required when writing publish evidence"
  fi
else
  echo "remote publish live verification: dry-run"
  echo "- provider: $PROVIDER"
  echo "- mode: $MODE"
  echo "- target branch: $TARGET_BRANCH"
  echo "- test path: $TEST_PATH"
  echo "- review branch: $REVIEW_BRANCH"
  if [[ "$MODE" == "review" ]]; then
    echo "- rollback draft: $ROLLBACK_DRAFT"
    echo "- review cleanup: $([[ "$REVIEW_CLEANUP" == "1" ]] && echo will-close-review-and-delete-branch || echo disabled)"
  fi
  echo "- write evidence: $WRITE_EVIDENCE"
  echo "- execute: pass --execute with REMOTE_VERIFY_TOKEN, REMOTE_VERIFY_OWNER, and REMOTE_VERIFY_REPO"
  exit 0
fi

json_get() {
  local expression="$1"
  python3 -c 'import json,sys
data=json.load(sys.stdin)
expr=sys.argv[1]
value=data
for part in expr.split("."):
    if not part:
        continue
    if isinstance(value, list):
        value=value[int(part)]
    else:
        value=value.get(part)
    if value is None:
        break
if value is None:
    sys.exit(1)
print(value)' "$expression"
}

json_quote() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

url_encode() {
  python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

curl_json() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  local output
  output="$(mktemp "${TMPDIR:-/tmp}/remote-verify.XXXXXX")"
  local status
  if [[ -n "$body" ]]; then
    status="$(curl -sS -o "$output" -w "%{http_code}" -X "$method" "$url" "${CURL_HEADERS[@]}" -H "Content-Type: application/json" --data "$body")"
  else
    status="$(curl -sS -o "$output" -w "%{http_code}" -X "$method" "$url" "${CURL_HEADERS[@]}")"
  fi
  if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
    echo "remote publish live verification: HTTP $status from $url" >&2
    sed -E \
      -e 's#(github_pat_|ghp_|glpat-|sk-)[A-Za-z0-9_-]{8,}#<redacted-token>#g' \
      -e 's#Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._-]+#Authorization: Bearer <redacted>#g' \
      "$output" >&2
    rm -f "$output"
    exit 1
  fi
  cat "$output"
  rm -f "$output"
}

curl_json_optional() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  local output
  output="$(mktemp "${TMPDIR:-/tmp}/remote-verify-optional.XXXXXX")"
  local status
  if [[ -n "$body" ]]; then
    status="$(curl -sS -o "$output" -w "%{http_code}" -X "$method" "$url" "${CURL_HEADERS[@]}" -H "Content-Type: application/json" --data "$body" || true)"
  else
    status="$(curl -sS -o "$output" -w "%{http_code}" -X "$method" "$url" "${CURL_HEADERS[@]}" || true)"
  fi
  if [[ "$status" =~ ^[0-9]+$ && "$status" -ge 200 && "$status" -lt 300 ]]; then
    cat "$output"
    rm -f "$output"
    return 0
  fi
  rm -f "$output"
  return 1
}

github_deployment_status_summary() {
  local branch="$1"
  local sha="$2"
  local pages_status="GitHub Pages status unavailable"
  local pages_json
  if pages_json="$(curl_json_optional GET "$BASE_URL/repos/$(url_encode "$OWNER")/$(url_encode "$REPO")/pages")"; then
    local status
    status="$(printf "%s" "$pages_json" | json_get status || true)"
    local html_url
    html_url="$(printf "%s" "$pages_json" | json_get html_url || true)"
    pages_status="GitHub Pages: ${status:-configured}${html_url:+ ($html_url)}"
  fi

  local actions_status="GitHub Actions latest run unavailable"
  local runs_json
  if runs_json="$(curl_json_optional GET "$BASE_URL/repos/$(url_encode "$OWNER")/$(url_encode "$REPO")/actions/runs?branch=$(url_encode "$branch")&per_page=1")"; then
    local run_status
    run_status="$(printf "%s" "$runs_json" | json_get workflow_runs.0.status || true)"
    local conclusion
    conclusion="$(printf "%s" "$runs_json" | json_get workflow_runs.0.conclusion || true)"
    local run_url
    run_url="$(printf "%s" "$runs_json" | json_get workflow_runs.0.html_url || true)"
    if [[ -n "${run_status//[[:space:]]/}" ]]; then
      actions_status="GitHub Actions latest run: $run_status${conclusion:+ / $conclusion}${run_url:+ ($run_url)}"
    fi
  fi

  echo "GitHub deployment status checked for branch $branch after commit ${sha:0:12}: $pages_status; $actions_status."
}

gitlab_deployment_status_summary() {
  local branch="$1"
  local sha="$2"
  local pipeline_status="GitLab Pipeline latest run unavailable"
  local pipelines_json
  if pipelines_json="$(curl_json_optional GET "$API_URL/projects/$project_id/pipelines?ref=$(url_encode "$branch")&per_page=1")"; then
    local status
    status="$(printf "%s" "$pipelines_json" | json_get 0.status || true)"
    local pipeline_url
    pipeline_url="$(printf "%s" "$pipelines_json" | json_get 0.web_url || true)"
    if [[ -n "${status//[[:space:]]/}" ]]; then
      pipeline_status="GitLab Pipeline latest run: $status${pipeline_url:+ ($pipeline_url)}"
    fi
  fi

  echo "GitLab deployment status checked for branch $branch after commit ${sha:0:12}: $pipeline_status."
}

ensure_deployment_status() {
  local provider="$1"
  local branch="$2"
  local sha="$3"
  if [[ -n "${DEPLOYMENT_STATUS//[[:space:]]/}" ]]; then
    return 0
  fi
  case "$provider" in
    github)
      DEPLOYMENT_STATUS="$(github_deployment_status_summary "$branch" "$sha")"
      ;;
    gitlab)
      DEPLOYMENT_STATUS="$(gitlab_deployment_status_summary "$branch" "$sha")"
      ;;
  esac
}

combined_token_scope_summary() {
  local summary="$provider_permission_summary"
  if [[ -n "${TOKEN_SCOPE_NOTE//[[:space:]]/}" ]]; then
    summary="$summary Operator note: $TOKEN_SCOPE_NOTE"
  fi
  printf "%s" "$summary"
}

append_review_cleanup_to_rollback_draft() {
  [[ -n "${review_cleanup_summary//[[:space:]]/}" ]] || return 0
  ROLLBACK_DRAFT="$ROLLBACK_DRAFT Cleanup exercised: $review_cleanup_summary"
}

write_evidence() {
  local item_id="$1"
  local title="$2"
  local summary="$3"
  local evidence_url="$4"
  [[ "$WRITE_EVIDENCE" == "1" ]] || return 0
  local file_changes="Created or updated $TEST_PATH through the provider API."
  case "$item_id" in
    github-direct-publish|gitlab-direct-publish)
      EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/record_external_verification_evidence.sh" \
        --item "$item_id" \
        --summary "$summary" \
        --token-scope "$(combined_token_scope_summary)" \
        --commit-sha "$commit_sha" \
        --deployment-status "$DEPLOYMENT_STATUS" \
        --release-ledger "$RELEASE_LEDGER" \
        --evidence-url "$evidence_url" \
        --execute >/dev/null
      ;;
    github-review-publish)
      EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/record_external_verification_evidence.sh" \
        --item "$item_id" \
        --summary "$summary" \
        --pr-url "$evidence_url" \
        --provider-review-artifact "$provider_review_artifact" \
        --review-branch "$REVIEW_BRANCH" \
        --target-branch "$TARGET_BRANCH" \
        --file-changes "$file_changes" \
        --deployment-status "$DEPLOYMENT_STATUS" \
        --release-ledger "$RELEASE_LEDGER" \
        --rollback-draft "$ROLLBACK_DRAFT" \
        --evidence-url "$evidence_url" \
        --execute >/dev/null
      ;;
    gitlab-review-publish)
      EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/record_external_verification_evidence.sh" \
        --item "$item_id" \
        --summary "$summary" \
        --mr-url "$evidence_url" \
        --provider-review-artifact "$provider_review_artifact" \
        --source-branch "$REVIEW_BRANCH" \
        --target-branch "$TARGET_BRANCH" \
        --file-changes "$file_changes" \
        --deployment-status "$DEPLOYMENT_STATUS" \
        --release-ledger "$RELEASE_LEDGER" \
        --rollback-draft "$ROLLBACK_DRAFT" \
        --evidence-url "$evidence_url" \
        --execute >/dev/null
      ;;
  esac
}

content="# Live remote publish verification

- Provider: $PROVIDER
- Mode: $MODE
- Generated: $TIMESTAMP

This disposable file was created by Personal Site Publisher Mac release verification."
content_json="$(printf "%s" "$content" | json_quote)"

case "$PROVIDER" in
  github)
    BASE_URL="${REMOTE_VERIFY_BASE_URL:-https://api.github.com}"
    CURL_HEADERS=(-H "Accept: application/vnd.github+json" -H "Authorization: Bearer $TOKEN" -H "X-GitHub-Api-Version: 2022-11-28")
    repo_json="$(curl_json GET "$BASE_URL/repos/$(url_encode "$OWNER")/$(url_encode "$REPO")")"
    can_push="$(printf "%s" "$repo_json" | json_get permissions.push || true)"
    can_maintain="$(printf "%s" "$repo_json" | json_get permissions.maintain || true)"
    can_admin="$(printf "%s" "$repo_json" | json_get permissions.admin || true)"
    [[ "$can_push" == "True" || "$can_push" == "true" ]] || fail "GitHub token can read the repository but push permission was not confirmed"
    provider_permission_summary="GitHub repository permissions from API: push=$can_push, maintain=${can_maintain:-unknown}, admin=${can_admin:-unknown}; write path verified by Contents API."
    encoded_path="$(python3 -c 'import urllib.parse,sys; print("/".join(urllib.parse.quote(p, safe="") for p in sys.argv[1].split("/")))' "$TEST_PATH")"
    branch="$TARGET_BRANCH"
    if [[ "$MODE" == "review" ]]; then
      ref_json="$(curl_json GET "$BASE_URL/repos/$(url_encode "$OWNER")/$(url_encode "$REPO")/git/ref/heads/$TARGET_BRANCH")"
      base_sha="$(printf "%s" "$ref_json" | json_get object.sha)"
      create_ref_body="{\"ref\":\"refs/heads/$REVIEW_BRANCH\",\"sha\":\"$base_sha\"}"
      curl_json POST "$BASE_URL/repos/$(url_encode "$OWNER")/$(url_encode "$REPO")/git/refs" "$create_ref_body" >/dev/null
      branch="$REVIEW_BRANCH"
    fi
    encoded_content="$(printf "%s" "$content" | base64 | tr -d '\n')"
    put_body="{\"message\":\"Live verification: $PROVIDER $MODE\",\"content\":\"$encoded_content\",\"branch\":\"$branch\"}"
    put_json="$(curl_json PUT "$BASE_URL/repos/$(url_encode "$OWNER")/$(url_encode "$REPO")/contents/$encoded_path" "$put_body")"
    commit_sha="$(printf "%s" "$put_json" | json_get commit.sha)"
    evidence_url="https://github.com/$OWNER/$REPO/commit/$commit_sha"
    item_id="github-direct-publish"
    title="GitHub API 直接提交"
    summary="GitHub live direct commit verified on branch $branch with commit $commit_sha and path $TEST_PATH."
    if [[ "$MODE" == "review" ]]; then
      pr_body="{\"title\":\"Live verification: Personal Site Publisher Mac\",\"head\":\"$REVIEW_BRANCH\",\"base\":\"$TARGET_BRANCH\",\"body\":\"Live PR verification generated by release evidence script.\"}"
      pr_json="$(curl_json POST "$BASE_URL/repos/$(url_encode "$OWNER")/$(url_encode "$REPO")/pulls" "$pr_body")"
      evidence_url="$(printf "%s" "$pr_json" | json_get html_url)"
      pr_number="$(printf "%s" "$pr_json" | json_get number)"
      pr_state="$(printf "%s" "$pr_json" | json_get state)"
      pr_draft="$(printf "%s" "$pr_json" | json_get draft || true)"
      provider_review_artifact="GitHub Pull Request API returned number #$pr_number, state $pr_state, draft=${pr_draft:-unknown}."
      item_id="github-review-publish"
      title="GitHub PR 发布"
      summary="GitHub live PR verified from $REVIEW_BRANCH to $TARGET_BRANCH with commit $commit_sha and path $TEST_PATH."
    fi
    ensure_deployment_status github "$branch" "$commit_sha"
    if [[ "$MODE" == "review" && "$REVIEW_CLEANUP" == "1" ]]; then
      close_pr_body='{"state":"closed"}'
      close_pr_json="$(curl_json PATCH "$BASE_URL/repos/$(url_encode "$OWNER")/$(url_encode "$REPO")/pulls/$pr_number" "$close_pr_body")"
      close_pr_state="$(printf "%s" "$close_pr_json" | json_get state)"
      curl_json DELETE "$BASE_URL/repos/$(url_encode "$OWNER")/$(url_encode "$REPO")/git/refs/heads/$REVIEW_BRANCH" >/dev/null
      review_cleanup_summary="GitHub PR #$pr_number was closed with state $close_pr_state and review branch $REVIEW_BRANCH was deleted."
      append_review_cleanup_to_rollback_draft
    fi
    ;;
  gitlab)
    BASE_URL="${REMOTE_VERIFY_BASE_URL:-https://gitlab.com}"
    API_URL="${BASE_URL%/}/api/v4"
    CURL_HEADERS=(-H "PRIVATE-TOKEN: $TOKEN")
    project_path="$OWNER/$REPO"
    project_id="$(url_encode "$project_path")"
    project_json="$(curl_json GET "$API_URL/projects/$project_id")"
    web_url="$(printf "%s" "$project_json" | json_get web_url)"
    access_level="$(printf "%s" "$project_json" | python3 -c 'import json,sys
d=json.load(sys.stdin)
perms=d.get("permissions") or {}
levels=[
  ((perms.get("project_access") or {}).get("access_level") or 0),
  ((perms.get("group_access") or {}).get("access_level") or 0),
]
print(max(levels))')"
    [[ "$access_level" -ge 30 ]] || fail "GitLab token can read the project but write permission was not confirmed"
    access_role="Developer"
    if [[ "$access_level" -ge 50 ]]; then
      access_role="Owner"
    elif [[ "$access_level" -ge 40 ]]; then
      access_role="Maintainer"
    fi
    provider_permission_summary="GitLab project permissions from API: max access_level=$access_level ($access_role); write path verified by Repository Commits API."
    branch="$TARGET_BRANCH"
    start_branch_json="null"
    if [[ "$MODE" == "review" ]]; then
      branch="$REVIEW_BRANCH"
      start_branch_json="$(printf "%s" "$TARGET_BRANCH" | json_quote)"
    fi
    commit_body="$(python3 - "$branch" "$TARGET_BRANCH" "$TEST_PATH" "$content" "$MODE" <<'PY'
import json
import sys
branch, target, path, content, mode = sys.argv[1:6]
body = {
  "branch": branch,
  "commit_message": f"Live verification: gitlab {mode}",
  "actions": [{"action": "create", "file_path": path, "content": content}],
}
if mode == "review":
  body["start_branch"] = target
print(json.dumps(body))
PY
)"
    commit_json="$(curl_json POST "$API_URL/projects/$project_id/repository/commits" "$commit_body")"
    commit_sha="$(printf "%s" "$commit_json" | json_get id)"
    evidence_url="$web_url/-/commit/$commit_sha"
    item_id="gitlab-direct-publish"
    title="GitLab API 直接提交"
    summary="GitLab live direct commit verified on branch $branch with commit $commit_sha and path $TEST_PATH."
    if [[ "$MODE" == "review" ]]; then
      mr_body="$(python3 - "$REVIEW_BRANCH" "$TARGET_BRANCH" <<'PY'
import json
import sys
source, target = sys.argv[1:3]
print(json.dumps({
  "source_branch": source,
  "target_branch": target,
  "title": "Live verification: Personal Site Publisher Mac",
  "description": "Live MR verification generated by release evidence script.",
  "remove_source_branch": False,
}))
PY
)"
      mr_json="$(curl_json POST "$API_URL/projects/$project_id/merge_requests" "$mr_body")"
      evidence_url="$(printf "%s" "$mr_json" | json_get web_url)"
      mr_iid="$(printf "%s" "$mr_json" | json_get iid)"
      mr_state="$(printf "%s" "$mr_json" | json_get state)"
      mr_merge_status="$(printf "%s" "$mr_json" | json_get detailed_merge_status || printf "%s" "$mr_json" | json_get merge_status || true)"
      provider_review_artifact="GitLab Merge Request API returned iid !$mr_iid, state $mr_state, merge status ${mr_merge_status:-unknown}."
      item_id="gitlab-review-publish"
      title="GitLab MR 发布"
      summary="GitLab live MR verified from $REVIEW_BRANCH to $TARGET_BRANCH with commit $commit_sha and path $TEST_PATH."
    fi
    ensure_deployment_status gitlab "$branch" "$commit_sha"
    if [[ "$MODE" == "review" && "$REVIEW_CLEANUP" == "1" ]]; then
      close_mr_body='{"state_event":"close"}'
      close_mr_json="$(curl_json PUT "$API_URL/projects/$project_id/merge_requests/$mr_iid" "$close_mr_body")"
      close_mr_state="$(printf "%s" "$close_mr_json" | json_get state)"
      curl_json DELETE "$API_URL/projects/$project_id/repository/branches/$(url_encode "$REVIEW_BRANCH")" >/dev/null
      review_cleanup_summary="GitLab MR !$mr_iid was closed with state $close_mr_state and review branch $REVIEW_BRANCH was deleted."
      append_review_cleanup_to_rollback_draft
    fi
    ;;
esac

write_evidence "$item_id" "$title" "$summary" "$evidence_url"

echo "remote publish live verification: completed"
echo "- item: $item_id"
echo "- branch: ${branch:-$TARGET_BRANCH}"
echo "- commit: $commit_sha"
echo "- evidence: $evidence_url"
if [[ "$MODE" == "review" ]]; then
  echo "- provider review artifact: $provider_review_artifact"
  if [[ -n "${review_cleanup_summary//[[:space:]]/}" ]]; then
    echo "- review cleanup: $review_cleanup_summary"
  fi
fi
echo "- deployment status: $DEPLOYMENT_STATUS"
if [[ "$WRITE_EVIDENCE" == "1" ]]; then
  echo "- updated: ${EVIDENCE_FILE#$ROOT_DIR/}"
fi
