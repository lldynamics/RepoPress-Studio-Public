#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFIER="$ROOT_DIR/script/verify_remote_publish_live.sh"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-remote-live-verifier.XXXXXX)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "remote publish live verifier test: $*" >&2
  exit 1
}

[[ -f "$VERIFIER" ]] || fail "verify_remote_publish_live.sh is missing"

script_text="$(cat "$VERIFIER")"

required_patterns=(
  "permissions.push"
  "GitHub repository permissions from API"
  "GitLab project permissions from API"
  "combined_token_scope_summary"
  "Operator note:"
  'contents/$encoded_path'
  "curl_json PUT"
  "/pulls"
  "repository/commits"
  "merge_requests"
  "PRIVATE-TOKEN"
  "Authorization: Bearer"
  "Repository Commits API"
  "record_external_verification_evidence.sh"
  "--evidence-url"
  "github-direct-publish"
  "github-review-publish"
  "gitlab-direct-publish"
  "gitlab-review-publish"
  "REMOTE_VERIFY_DEPLOYMENT_STATUS"
  "REMOTE_VERIFY_RELEASE_LEDGER"
  "REMOTE_VERIFY_RELEASE_LEDGER is required when writing publish evidence"
  "REMOTE_VERIFY_ROLLBACK_DRAFT"
  "REMOTE_VERIFY_REVIEW_CLEANUP"
  "append_review_cleanup_to_rollback_draft"
  "review_cleanup_summary"
  "close PR/MR"
  "state_event"
  "git/refs/heads/"
  "repository/branches"
  "generated_review_rollback_draft"
  "provider_review_artifact"
  "--provider-review-artifact"
  "GitHub Pull Request API returned number"
  "GitLab Merge Request API returned iid"
  "curl_json_optional"
  "ensure_deployment_status"
  "github_deployment_status_summary"
  "gitlab_deployment_status_summary"
  "GitHub deployment status checked"
  "GitLab deployment status checked"
  '- rollback draft: $ROLLBACK_DRAFT'
  '- deployment status: $DEPLOYMENT_STATUS'
  "--no-write-evidence"
  "REMOTE_VERIFY_ALLOW_CUSTOM_PATH"
  "REMOTE_VERIFY_ALLOW_CUSTOM_BRANCH"
  "validate_disposable_path"
  "validate_disposable_review_branch"
  "codex-live-verification/"
  "codex/live-verify-"
  "start_branch"
  'evidence_url="https://github.com/$OWNER/$REPO/commit/$commit_sha"'
  'evidence_url="$web_url/-/commit/$commit_sha"'
  '- evidence: $evidence_url'
  'Created or updated $TEST_PATH through the provider API.'
)

for pattern in "${required_patterns[@]}"; do
  if [[ "$script_text" != *"$pattern"* ]]; then
    fail "live verifier is missing required implementation marker: $pattern"
  fi
done

for provider in github gitlab; do
  for mode in direct review; do
    output="$(bash "$VERIFIER" --provider "$provider" --mode "$mode")"
    grep -Fq -- "- provider: $provider" <<<"$output" || fail "dry-run omitted provider $provider"
    grep -Fq -- "- mode: $mode" <<<"$output" || fail "dry-run omitted mode $mode"
    grep -Fq -- "- execute: pass --execute" <<<"$output" || fail "dry-run omitted execute guidance"
    if [[ "$mode" == "review" ]]; then
      grep -Fq -- "- rollback draft:" <<<"$output" || fail "dry-run omitted generated rollback draft"
      grep -Fq -- "- review cleanup:" <<<"$output" || fail "dry-run omitted review cleanup setting"
      grep -Fq -- "deleting review branch" <<<"$output" || fail "generated rollback draft omitted branch cleanup"
    fi
  done
done

if REMOTE_VERIFY_REVIEW_CLEANUP=2 \
  bash "$VERIFIER" --provider github --mode review >/dev/null 2>&1; then
  fail "live verifier accepted invalid review cleanup value"
fi

if REMOTE_VERIFY_REVIEW_CLEANUP=1 \
  bash "$VERIFIER" --provider github --mode direct >/dev/null 2>&1; then
  fail "live verifier accepted review cleanup in direct mode"
fi

if bash "$VERIFIER" --provider github --mode invalid >/dev/null 2>&1; then
  fail "live verifier accepted invalid mode"
fi

if bash "$VERIFIER" --provider invalid --mode direct >/dev/null 2>&1; then
  fail "live verifier accepted invalid provider"
fi

if bash "$VERIFIER" --provider github --mode direct --execute >/dev/null 2>&1; then
  fail "live verifier accepted --execute without token"
fi

if REMOTE_VERIFY_PATH="content/posts/real-post.md" \
  bash "$VERIFIER" --provider github --mode direct >/dev/null 2>&1; then
  fail "live verifier accepted non-disposable test path without override"
fi

REMOTE_VERIFY_ALLOW_CUSTOM_PATH=1 \
  REMOTE_VERIFY_PATH="content/posts/real-post.md" \
  bash "$VERIFIER" --provider github --mode direct >/dev/null

if REMOTE_VERIFY_PATH="../outside.md" \
  REMOTE_VERIFY_ALLOW_CUSTOM_PATH=1 \
  bash "$VERIFIER" --provider github --mode direct >/dev/null 2>&1; then
  fail "live verifier accepted parent-directory traversal in test path"
fi

if REMOTE_VERIFY_BRANCH_NAME="release/main" \
  bash "$VERIFIER" --provider gitlab --mode review >/dev/null 2>&1; then
  fail "live verifier accepted non-disposable review branch without override"
fi

REMOTE_VERIFY_ALLOW_CUSTOM_BRANCH=1 \
  REMOTE_VERIFY_BRANCH_NAME="release/main" \
  bash "$VERIFIER" --provider gitlab --mode review >/dev/null

if REMOTE_VERIFY_BRANCH_NAME="codex/live-verify bad" \
  REMOTE_VERIFY_ALLOW_CUSTOM_BRANCH=1 \
  bash "$VERIFIER" --provider gitlab --mode review >/dev/null 2>&1; then
  fail "live verifier accepted whitespace in review branch"
fi

cp "$ROOT_DIR/docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md" "$TMP_DIR/evidence.md"
if REMOTE_VERIFY_TOKEN="redacted-token" \
  REMOTE_VERIFY_OWNER="owner" \
  REMOTE_VERIFY_REPO="repo" \
  REMOTE_VERIFY_EVIDENCE_FILE="$TMP_DIR/evidence.md" \
  bash "$VERIFIER" --provider github --mode direct --execute >/dev/null 2>&1; then
  fail "direct verifier accepted missing release-ledger summary"
fi

direct_missing_summary_output="$(
  REMOTE_VERIFY_TOKEN="redacted-token" \
    REMOTE_VERIFY_OWNER="owner" \
    REMOTE_VERIFY_REPO="repo" \
    REMOTE_VERIFY_EVIDENCE_FILE="$TMP_DIR/evidence.md" \
    bash "$VERIFIER" --provider github --mode direct --execute 2>&1 || true
)"
if grep -Fq "REMOTE_VERIFY_DEPLOYMENT_STATUS is required" <<<"$direct_missing_summary_output"; then
  fail "direct verifier still requires manual deployment summary"
fi

review_missing_release_ledger_output="$(
  REMOTE_VERIFY_TOKEN="redacted-token" \
    REMOTE_VERIFY_OWNER="owner" \
    REMOTE_VERIFY_REPO="repo" \
    REMOTE_VERIFY_EVIDENCE_FILE="$TMP_DIR/evidence.md" \
    bash "$VERIFIER" --provider github --mode review --execute 2>&1 || true
)"
grep -Fq "REMOTE_VERIFY_RELEASE_LEDGER is required when writing publish evidence" <<<"$review_missing_release_ledger_output" \
  || fail "review verifier did not require release ledger before writing evidence"

review_missing_rollback_output="$(
  REMOTE_VERIFY_TOKEN="redacted-token" \
    REMOTE_VERIFY_OWNER="owner" \
    REMOTE_VERIFY_REPO="repo" \
    REMOTE_VERIFY_DEPLOYMENT_STATUS="Deployment reached success." \
    REMOTE_VERIFY_EVIDENCE_FILE="$TMP_DIR/evidence.md" \
    bash "$VERIFIER" --provider gitlab --mode review --execute 2>&1 || true
)"
if grep -Fq "REMOTE_VERIFY_ROLLBACK_DRAFT is required" <<<"$review_missing_rollback_output"; then
  fail "review verifier still requires manual rollback summary"
fi

review_missing_deployment_output="$(
  REMOTE_VERIFY_TOKEN="redacted-token" \
    REMOTE_VERIFY_OWNER="owner" \
    REMOTE_VERIFY_REPO="repo" \
    REMOTE_VERIFY_EVIDENCE_FILE="$TMP_DIR/evidence.md" \
    bash "$VERIFIER" --provider gitlab --mode review --execute 2>&1 || true
)"
if grep -Fq "REMOTE_VERIFY_DEPLOYMENT_STATUS is required" <<<"$review_missing_deployment_output"; then
  fail "review verifier still requires manual deployment summary"
fi

echo "remote publish live verifier test: passed"
