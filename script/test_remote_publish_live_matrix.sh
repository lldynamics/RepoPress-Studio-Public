#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MATRIX="$ROOT_DIR/script/verify_remote_publish_live_matrix.sh"
ENV_TEMPLATE="$ROOT_DIR/docs/release-evidence/remote-publish-live.env.example"

fail() {
  echo "remote publish live matrix test: $*" >&2
  exit 1
}

[[ -f "$MATRIX" ]] || fail "verify_remote_publish_live_matrix.sh is missing"
[[ -f "$ENV_TEMPLATE" ]] || fail "remote publish live env template is missing"

output="$(bash "$MATRIX")"
grep -q "remote publish live matrix: dry-run=yes, write evidence=1" <<<"$output" || fail "dry-run did not print matrix header"
for provider in github gitlab; do
  for mode in direct review; do
    grep -q "remote publish live matrix: $provider $mode" <<<"$output" || fail "dry-run omitted $provider $mode"
    grep -q "script/verify_remote_publish_live.sh --provider $provider --mode $mode" <<<"$output" || fail "dry-run omitted verifier command for $provider $mode"
  done
done
grep -q -- "- release ledger: missing" <<<"$output" || fail "dry-run did not expose missing publish release ledger"
if grep -q -- "- release ledger: not-required" <<<"$output"; then
  fail "dry-run still treats review release ledger as optional"
fi

configured_output="$(
  REMOTE_VERIFY_GITHUB_TOKEN="redacted-github" \
  REMOTE_VERIFY_GITHUB_OWNER="owner" \
  REMOTE_VERIFY_GITHUB_REPO="repo" \
  REMOTE_VERIFY_GITHUB_DIRECT_RELEASE_LEDGER="Release ledger contains GitHub direct publish evidence." \
  REMOTE_VERIFY_GITHUB_REVIEW_RELEASE_LEDGER="Release ledger contains GitHub PR publish evidence." \
  REMOTE_VERIFY_GITLAB_TOKEN="redacted-gitlab" \
  REMOTE_VERIFY_GITLAB_OWNER="group" \
  REMOTE_VERIFY_GITLAB_REPO="project" \
  REMOTE_VERIFY_GITLAB_DIRECT_RELEASE_LEDGER="Release ledger contains GitLab direct publish evidence." \
  REMOTE_VERIFY_GITLAB_REVIEW_RELEASE_LEDGER="Release ledger contains GitLab MR publish evidence." \
    bash "$MATRIX" --no-write-evidence
)"
grep -q "remote publish live matrix: dry-run=yes, write evidence=0" <<<"$configured_output" || fail "--no-write-evidence did not update header"
grep -q -- "- token: configured" <<<"$configured_output" || fail "configured dry-run did not report tokens"
grep -q -- "- release ledger: configured" <<<"$configured_output" || fail "configured dry-run did not report publish release ledger"

if bash "$MATRIX" --execute >/dev/null 2>&1; then
  fail "matrix accepted --execute without provider credentials"
fi

missing_direct_ledger_output="$(
  REMOTE_VERIFY_GITHUB_TOKEN="redacted-github" \
  REMOTE_VERIFY_GITHUB_OWNER="owner" \
  REMOTE_VERIFY_GITHUB_REPO="repo" \
  REMOTE_VERIFY_GITLAB_TOKEN="redacted-gitlab" \
  REMOTE_VERIFY_GITLAB_OWNER="group" \
  REMOTE_VERIFY_GITLAB_REPO="project" \
    bash "$MATRIX" --execute 2>&1 || true
)"
grep -q "REMOTE_VERIFY_GITHUB_DIRECT_RELEASE_LEDGER is required with --execute" <<<"$missing_direct_ledger_output" \
  || fail "matrix did not require GitHub publish release ledger when writing evidence"

no_write_output="$(
  REMOTE_VERIFY_GITHUB_TOKEN="redacted-github" \
  REMOTE_VERIFY_GITHUB_OWNER="owner" \
  REMOTE_VERIFY_GITHUB_REPO="repo" \
  REMOTE_VERIFY_GITHUB_DIRECT_PATH="../outside.md" \
  REMOTE_VERIFY_GITLAB_TOKEN="redacted-gitlab" \
  REMOTE_VERIFY_GITLAB_OWNER="group" \
  REMOTE_VERIFY_GITLAB_REPO="project" \
    bash "$MATRIX" --execute --no-write-evidence 2>&1 || true
)"
if grep -q "RELEASE_LEDGER is required" <<<"$no_write_output"; then
  fail "matrix required release ledger while evidence writing was disabled"
fi
grep -q "REMOTE_VERIFY_PATH cannot contain parent directory traversal" <<<"$no_write_output" \
  || fail "matrix did not reach delegated verifier path validation with --no-write-evidence"

script_text="$(cat "$MATRIX")"
template_text="$(cat "$ENV_TEMPLATE")"
required_markers=(
  "REMOTE_VERIFY_GITHUB_TOKEN"
  "REMOTE_VERIFY_GITLAB_TOKEN"
  "REMOTE_VERIFY_GITHUB_DIRECT_PATH"
  "REMOTE_VERIFY_GITLAB_REVIEW_BRANCH_NAME"
  "verify_remote_publish_live.sh"
  "--no-write-evidence"
  "REMOTE_VERIFY_RELEASE_LEDGER"
)
for marker in "${required_markers[@]}"; do
  [[ "$script_text" == *"$marker"* ]] || fail "matrix script missing marker: $marker"
done

template_required_markers=(
  "REMOTE_VERIFY_BRANCH"
  "REMOTE_VERIFY_TOKEN_SCOPE_SUMMARY"
  "provider API permission"
  "REMOTE_VERIFY_ALLOW_CUSTOM_PATH"
  "REMOTE_VERIFY_ALLOW_CUSTOM_BRANCH"
  "REMOTE_VERIFY_REVIEW_CLEANUP"
  "REMOTE_VERIFY_GITHUB_TOKEN"
  "REMOTE_VERIFY_GITHUB_OWNER"
  "REMOTE_VERIFY_GITHUB_REPO"
  "REMOTE_VERIFY_GITHUB_DIRECT_RELEASE_LEDGER"
  "REMOTE_VERIFY_GITHUB_REVIEW_RELEASE_LEDGER"
  "REMOTE_VERIFY_GITHUB_BASE_URL"
  "REMOTE_VERIFY_GITHUB_DIRECT_PATH"
  "REMOTE_VERIFY_GITHUB_REVIEW_PATH"
  "REMOTE_VERIFY_GITHUB_REVIEW_BRANCH_NAME"
  "REMOTE_VERIFY_GITLAB_TOKEN"
  "REMOTE_VERIFY_GITLAB_OWNER"
  "REMOTE_VERIFY_GITLAB_REPO"
  "REMOTE_VERIFY_GITLAB_DIRECT_RELEASE_LEDGER"
  "REMOTE_VERIFY_GITLAB_REVIEW_RELEASE_LEDGER"
  "REMOTE_VERIFY_GITLAB_BASE_URL"
  "REMOTE_VERIFY_GITLAB_DIRECT_PATH"
  "REMOTE_VERIFY_GITLAB_REVIEW_PATH"
  "REMOTE_VERIFY_GITLAB_REVIEW_BRANCH_NAME"
  "REMOTE_VERIFY_EVIDENCE_FILE"
)
for marker in "${template_required_markers[@]}"; do
  [[ "$template_text" == *"$marker"* ]] || fail "env template missing optional marker: $marker"
done

if grep -Eq '(github_pat_|ghp_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|Authorization:[[:space:]]*Bearer|redacted-token|redacted-github|redacted-gitlab)' "$ENV_TEMPLATE"; then
  fail "env template contains token-like or copyable placeholder secret text"
fi

echo "remote publish live matrix test: passed"
