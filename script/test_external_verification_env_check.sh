#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREP="$ROOT_DIR/script/prepare_external_verification_envs.sh"
CHECK="$ROOT_DIR/script/check_external_verification_envs.sh"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-env-check.XXXXXX)"
ENV_DIR="$TMP_DIR/private-envs"
EVIDENCE_FIXTURE="$TMP_DIR/external-verification-evidence.md"
ARCHIVE_FIXTURE="$TMP_DIR/app-store-archive-evidence.md"

printf '%s\n' \
  '- [ ] `github-direct-publish`' \
  '- [ ] `github-review-publish`' \
  '- [ ] `gitlab-direct-publish`' \
  '- [ ] `gitlab-review-publish`' \
  '- [ ] `remote-conflict-deployment-rollback`' \
  '- [x] `app-store-screenshots`' >"$EVIDENCE_FIXTURE"
printf '%s\n' \
  '# App Store Archive Validation Evidence' \
  '- [ ] Clean Release archive produced from a clean checkout.' >"$ARCHIVE_FIXTURE"
export EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FIXTURE"
export APP_STORE_ARCHIVE_EVIDENCE_FILE="$ARCHIVE_FIXTURE"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "external verification env check test: $*" >&2
  exit 1
}

[[ -f "$CHECK" ]] || fail "check_external_verification_envs.sh is missing"

bash "$CHECK" --mode template >/dev/null
bash "$PREP" --output-dir "$ENV_DIR" >/dev/null

if empty_output="$(bash "$CHECK" --env-dir "$ENV_DIR" --mode filled 2>&1)"; then
  fail "filled mode accepted empty copied templates"
fi
grep -q "found " <<<"$empty_output" || fail "empty env output did not aggregate issues"
grep -q "remote-publish-live.env has empty or placeholder value for REMOTE_VERIFY_GITHUB_TOKEN" <<<"$empty_output" \
  || fail "empty env output omitted GitHub token field"
grep -q "remote-publish-live.env has empty or placeholder value for REMOTE_VERIFY_GITLAB_TOKEN" <<<"$empty_output" \
  || fail "empty env output omitted GitLab token field"
grep -q "app-store-archive-validation.env has empty or placeholder value for APP_STORE_ARCHIVE_TRANSPORTER_SUMMARY" <<<"$empty_output" \
  || fail "empty env output omitted archive transporter summary"

EMPTY_REPORT="$TMP_DIR/empty-env-status.md"
if bash "$CHECK" --env-dir "$ENV_DIR" --mode filled --target remaining --report-file "$EMPTY_REPORT" >/dev/null 2>&1; then
  fail "filled mode with report accepted empty copied templates"
fi
[[ -f "$EMPTY_REPORT" ]] || fail "empty env check did not write redacted report"
empty_report_text="$(cat "$EMPTY_REPORT")"
grep -q "# External Verification Env Status" <<<"$empty_report_text" \
  || fail "empty env report missing title"
grep -q 'Target: `remaining`' <<<"$empty_report_text" \
  || fail "empty env report missing target"
grep -q 'REMOTE_VERIFY_GITHUB_TOKEN' <<<"$empty_report_text" \
  || fail "empty env report missing required field names"
grep -q '`REMOTE_VERIFY_GITHUB_TOKEN`, `REMOTE_VERIFY_GITHUB_OWNER`' <<<"$empty_report_text" \
  || fail "empty env report did not separate required fields with comma and space"
grep -q '`remote-publish` via `remote-publish-live.env`: `github-direct-publish`, `github-review-publish`, `gitlab-direct-publish`, `gitlab-review-publish`' <<<"$empty_report_text" \
  || fail "empty env report omitted remote publish evidence target mapping"
grep -q '`app-store-archive` via `app-store-archive-validation.env`: clean Release archive, distribution signing/runtime, Transporter/App Store Connect validation' <<<"$empty_report_text" \
  || fail "empty env report omitted archive evidence target mapping"
grep -q 'remote-publish-live.env has empty or placeholder value for REMOTE_VERIFY_GITHUB_TOKEN' <<<"$empty_report_text" \
  || fail "empty env report missing validation issue"
grep -q "check_external_verification_envs.sh --env-dir $ENV_DIR --mode filled --target remaining --report-file $EMPTY_REPORT" <<<"$empty_report_text" \
  || fail "empty env report next command did not preserve report file"
grep -q "run_external_verification_from_envs.sh --env-dir $ENV_DIR --target remaining --env-status-report-file $EMPTY_REPORT" <<<"$empty_report_text" \
  || fail "empty env report runner command did not preserve status report file"
report_mode="$(stat -f "%Lp" "$EMPTY_REPORT")"
[[ "$report_mode" == "600" ]] || fail "empty env report mode is $report_mode, expected 600"

cat >"$ENV_DIR/remote-publish-live.env" <<'ENV'
REMOTE_VERIFY_BRANCH="main"
REMOTE_VERIFY_TOKEN_SCOPE_SUMMARY="Least-privilege repository write permission was confirmed by provider API."
REMOTE_VERIFY_ALLOW_CUSTOM_PATH="0"
REMOTE_VERIFY_ALLOW_CUSTOM_BRANCH="0"
REMOTE_VERIFY_REVIEW_CLEANUP="0"
REMOTE_VERIFY_GITHUB_TOKEN="gh-test-private-token"
REMOTE_VERIFY_GITHUB_OWNER="disposable-owner"
REMOTE_VERIFY_GITHUB_REPO="disposable-repo"
REMOTE_VERIFY_GITHUB_DIRECT_RELEASE_LEDGER="Release ledger contains GitHub direct publish evidence."
REMOTE_VERIFY_GITHUB_REVIEW_RELEASE_LEDGER="Release ledger contains GitHub PR publish evidence."
REMOTE_VERIFY_GITHUB_BASE_URL=""
REMOTE_VERIFY_GITHUB_DIRECT_PATH=""
REMOTE_VERIFY_GITHUB_REVIEW_PATH=""
REMOTE_VERIFY_GITHUB_REVIEW_BRANCH_NAME=""
REMOTE_VERIFY_GITLAB_TOKEN="gl-test-private-token"
REMOTE_VERIFY_GITLAB_OWNER="disposable-group"
REMOTE_VERIFY_GITLAB_REPO="disposable-project"
REMOTE_VERIFY_GITLAB_DIRECT_RELEASE_LEDGER="Release ledger contains GitLab direct publish evidence."
REMOTE_VERIFY_GITLAB_REVIEW_RELEASE_LEDGER="Release ledger contains GitLab MR publish evidence."
REMOTE_VERIFY_GITLAB_BASE_URL=""
REMOTE_VERIFY_GITLAB_DIRECT_PATH=""
REMOTE_VERIFY_GITLAB_REVIEW_PATH=""
REMOTE_VERIFY_GITLAB_REVIEW_BRANCH_NAME=""
REMOTE_VERIFY_EVIDENCE_FILE=""
ENV

cat >"$ENV_DIR/remote-recovery.env" <<'ENV'
REMOTE_RECOVERY_CONFLICT_PREVIEW_SUMMARY="Remote same-path conflict preview blocked direct publish before writing."
REMOTE_RECOVERY_PENDING_OFFLINE_SUMMARY="Unknown deployment stayed pending for retry in the release ledger."
REMOTE_RECOVERY_DEPLOYMENT_RETRY_SUMMARY="Deployment retry refreshed provider status."
REMOTE_RECOVERY_ROLLBACK_PACKAGE_SUMMARY="Rollback package included branch, files, and PR draft."
REMOTE_RECOVERY_EVIDENCE_URL=""
EXTERNAL_VERIFY_EVIDENCE_FILE=""
ENV

cat >"$ENV_DIR/app-store-screenshots.env" <<'ENV'
APP_STORE_SCREENSHOT_SET_SUMMARY="Captured all required App Store screenshot surfaces with redacted demo content."
APP_STORE_SCREENSHOT_PRIVACY_GATE_SUMMARY="Screenshot privacy gate passed without local paths or token-like strings."
APP_STORE_SCREENSHOT_STRICT_GATE_SUMMARY="Strict screenshot count and manifest sync gates passed."
APP_STORE_SCREENSHOT_DIR=""
APP_STORE_SCREENSHOT_MANIFEST_FILE=""
ENV

cat >"$ENV_DIR/app-store-archive-validation.env" <<'ENV'
APP_STORE_ARCHIVE_CLEAN_RELEASE_SUMMARY="Clean Release archive produced from a fresh checkout and reproducible release command."
APP_STORE_ARCHIVE_SIGNING_RUNTIME_SUMMARY="Distribution signature and hardened runtime were verified on the archive."
APP_STORE_ARCHIVE_TRANSPORTER_SUMMARY="Archive validated successfully before upload with no private account identifiers recorded."
APP_STORE_ARCHIVE_EVIDENCE_FILE=""
ENV

chmod 600 "$ENV_DIR"/*.env

filled_output="$(bash "$CHECK" --env-dir "$ENV_DIR" --mode filled)"
grep -q "filled mode passed" <<<"$filled_output" || fail "filled mode did not pass completed private env files"
if grep -q "gh-test-private-token" <<<"$filled_output"; then
  fail "filled mode leaked a token value"
fi

FILLED_REPORT="$TMP_DIR/filled-env-status.md"
filled_report_output="$(bash "$CHECK" --env-dir "$ENV_DIR" --mode filled --target remote-publish --report-file "$FILLED_REPORT")"
grep -q "wrote redacted report" <<<"$filled_report_output" \
  || fail "filled env check did not report status file write"
filled_report_text="$(cat "$FILLED_REPORT")"
grep -q 'Issues: 0' <<<"$filled_report_text" || fail "filled report did not show zero issues"
grep -q 'remote-publish-live.env' <<<"$filled_report_text" || fail "filled report omitted target env file"
grep -q '`remote-publish` via `remote-publish-live.env`: `github-direct-publish`, `github-review-publish`, `gitlab-direct-publish`, `gitlab-review-publish`' <<<"$filled_report_text" \
  || fail "filled report omitted target evidence mapping"
grep -q "check_external_verification_envs.sh --env-dir $ENV_DIR --mode filled --target remote-publish --report-file $FILLED_REPORT" <<<"$filled_report_text" \
  || fail "filled report next command did not preserve report file"
if grep -q "gh-test-private-token" "$FILLED_REPORT"; then
  fail "filled report leaked a token value"
fi
if bash "$CHECK" --env-dir "$ENV_DIR" --mode filled --report-file "$ROOT_DIR/docs/release-evidence/env-status.md" >/dev/null 2>&1; then
  fail "env check accepted a report file inside the repository"
fi

perl -0pi -e 's/APP_STORE_SCREENSHOT_SET_SUMMARY="[^"]+"/APP_STORE_SCREENSHOT_SET_SUMMARY=""/' "$ENV_DIR/app-store-screenshots.env"
remaining_output="$(bash "$CHECK" --env-dir "$ENV_DIR" --mode filled --target remaining)"
grep -q "filled mode passed for target remaining" <<<"$remaining_output" \
  || fail "remaining target did not pass without already-completed screenshot env"
if grep -q "app-store-screenshots.env ok" <<<"$remaining_output"; then
  fail "remaining target checked screenshot env even though screenshot evidence is complete"
fi
if screenshot_missing_output="$(bash "$CHECK" --env-dir "$ENV_DIR" --mode filled --target app-store-screenshots 2>&1)"; then
  fail "specific screenshot target accepted missing screenshot summary"
fi
grep -q "app-store-screenshots.env has empty or placeholder value for APP_STORE_SCREENSHOT_SET_SUMMARY" <<<"$screenshot_missing_output" \
  || fail "specific screenshot target did not report missing screenshot summary"
perl -0pi -e 's/APP_STORE_SCREENSHOT_SET_SUMMARY=""/APP_STORE_SCREENSHOT_SET_SUMMARY="Captured all required App Store screenshot surfaces with redacted demo content."/' "$ENV_DIR/app-store-screenshots.env"

chmod 644 "$ENV_DIR/remote-recovery.env"
if weak_mode_output="$(bash "$CHECK" --env-dir "$ENV_DIR" --mode filled 2>&1)"; then
  fail "filled mode accepted weak env file permissions"
fi
grep -q "remote-recovery.env mode is 644, expected 600" <<<"$weak_mode_output" \
  || fail "weak permission output did not name the offending env file"
chmod 600 "$ENV_DIR/remote-recovery.env"

perl -0pi -e 's/REMOTE_RECOVERY_ROLLBACK_PACKAGE_SUMMARY="[^"]+"/REMOTE_RECOVERY_ROLLBACK_PACKAGE_SUMMARY="TODO: fill rollback"/' "$ENV_DIR/remote-recovery.env"
if placeholder_output="$(bash "$CHECK" --env-dir "$ENV_DIR" --mode filled 2>&1)"; then
  fail "filled mode accepted TODO placeholder"
fi
grep -q "remote-recovery.env has empty or placeholder value for REMOTE_RECOVERY_ROLLBACK_PACKAGE_SUMMARY" <<<"$placeholder_output" \
  || fail "placeholder output did not name the rollback summary field"

if bash "$CHECK" --env-dir "$ROOT_DIR/docs/release-evidence" --mode filled >/dev/null 2>&1; then
  fail "filled mode accepted an env directory inside the repository"
fi

echo "external verification env check test: passed"
