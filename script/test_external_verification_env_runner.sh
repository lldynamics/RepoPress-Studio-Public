#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREP="$ROOT_DIR/script/prepare_external_verification_envs.sh"
RUNNER="$ROOT_DIR/script/run_external_verification_from_envs.sh"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-env-runner.XXXXXX)"
ENV_DIR="$TMP_DIR/private-envs"
version_values="$(bash "$ROOT_DIR/script/check_build_version.sh" --print-values)"
IFS=$'\t' read -r marketing_version build_number <<<"$version_values"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "external verification env runner test: $*" >&2
  exit 1
}

[[ -f "$RUNNER" ]] || fail "run_external_verification_from_envs.sh is missing"

bash "$PREP" --output-dir "$ENV_DIR" >/dev/null
cp "$ROOT_DIR/docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md" "$TMP_DIR/EXTERNAL_VERIFICATION_EVIDENCE.md"
cp "$ROOT_DIR/docs/release-evidence/APP_STORE_ARCHIVE_VALIDATION.md" "$TMP_DIR/APP_STORE_ARCHIVE_VALIDATION.md"
perl -0pi -e 's/- \[[xX]\] `(github-direct-publish|github-review-publish|gitlab-direct-publish|gitlab-review-publish|remote-conflict-deployment-rollback|storekit-sandbox)`/- [ ] `$1`/g;
              s/- \[ \] `app-store-screenshots`/- [x] `app-store-screenshots`/g;' "$TMP_DIR/EXTERNAL_VERIFICATION_EVIDENCE.md"
perl -0pi -e 's/- \[[xX]\]/- [ ]/g' "$TMP_DIR/APP_STORE_ARCHIVE_VALIDATION.md"
export EXTERNAL_VERIFY_EVIDENCE_FILE="$TMP_DIR/EXTERNAL_VERIFICATION_EVIDENCE.md"
export APP_STORE_ARCHIVE_EVIDENCE_FILE="$TMP_DIR/APP_STORE_ARCHIVE_VALIDATION.md"

SCREENSHOT_FIXTURE_DIR="$TMP_DIR/app-store-screenshots"
mkdir -p "$SCREENSHOT_FIXTURE_DIR"
cp "$ROOT_DIR/docs/app-store-screenshots/SCREENSHOT_MANIFEST.md" "$SCREENSHOT_FIXTURE_DIR/SCREENSHOT_MANIFEST.md"
cp "$ROOT_DIR/docs/app-store-screenshots/"*.png "$SCREENSHOT_FIXTURE_DIR/"
SCREENSHOT_DIR="$SCREENSHOT_FIXTURE_DIR" \
  SCREENSHOT_MANIFEST_FILE="$SCREENSHOT_FIXTURE_DIR/SCREENSHOT_MANIFEST.md" \
  bash "$ROOT_DIR/script/sync_screenshot_manifest_status.sh" >/dev/null
while IFS= read -r screenshot_id; do
  [[ -n "$screenshot_id" ]] || continue
  python3 "$ROOT_DIR/script/screenshot_capture_provenance.py" record \
    --root "$ROOT_DIR" \
    --manifest "$SCREENSHOT_FIXTURE_DIR/SCREENSHOT_MANIFEST.md" \
    --screenshot-dir "$SCREENSHOT_FIXTURE_DIR" \
    --id "$screenshot_id" \
    --image "$SCREENSHOT_FIXTURE_DIR/$screenshot_id.png" >/dev/null
done < <(sed -nE 's/^\| `([^`]+)` \|.*/\1/p' "$SCREENSHOT_FIXTURE_DIR/SCREENSHOT_MANIFEST.md")
OCR_STUB="$TMP_DIR/screenshot-privacy-ocr-stub"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$OCR_STUB"
chmod 700 "$OCR_STUB"
export SCREENSHOT_PRIVACY_OCR_EXECUTABLE="$OCR_STUB"

cat >"$ENV_DIR/remote-publish-live.env" <<ENV
REMOTE_VERIFY_BRANCH="main"
REMOTE_VERIFY_TOKEN_SCOPE_SUMMARY="Least-privilege repository write permission was confirmed by provider API."
REMOTE_VERIFY_ALLOW_CUSTOM_PATH="0"
REMOTE_VERIFY_ALLOW_CUSTOM_BRANCH="0"
REMOTE_VERIFY_REVIEW_CLEANUP="0"
REMOTE_VERIFY_GITHUB_TOKEN="gh-runner-private-token"
REMOTE_VERIFY_GITHUB_OWNER="disposable-owner"
REMOTE_VERIFY_GITHUB_REPO="disposable-repo"
REMOTE_VERIFY_GITHUB_DIRECT_RELEASE_LEDGER="Release ledger contains GitHub direct publish evidence."
REMOTE_VERIFY_GITHUB_REVIEW_RELEASE_LEDGER="Release ledger contains GitHub PR publish evidence."
REMOTE_VERIFY_GITHUB_BASE_URL=""
REMOTE_VERIFY_GITHUB_DIRECT_PATH=""
REMOTE_VERIFY_GITHUB_REVIEW_PATH=""
REMOTE_VERIFY_GITHUB_REVIEW_BRANCH_NAME=""
REMOTE_VERIFY_GITLAB_TOKEN="gl-runner-private-token"
REMOTE_VERIFY_GITLAB_OWNER="disposable-group"
REMOTE_VERIFY_GITLAB_REPO="disposable-project"
REMOTE_VERIFY_GITLAB_DIRECT_RELEASE_LEDGER="Release ledger contains GitLab direct publish evidence."
REMOTE_VERIFY_GITLAB_REVIEW_RELEASE_LEDGER="Release ledger contains GitLab MR publish evidence."
REMOTE_VERIFY_GITLAB_BASE_URL=""
REMOTE_VERIFY_GITLAB_DIRECT_PATH=""
REMOTE_VERIFY_GITLAB_REVIEW_PATH=""
REMOTE_VERIFY_GITLAB_REVIEW_BRANCH_NAME=""
REMOTE_VERIFY_EVIDENCE_FILE="$TMP_DIR/EXTERNAL_VERIFICATION_EVIDENCE.md"
ENV

cat >"$ENV_DIR/remote-recovery.env" <<ENV
REMOTE_RECOVERY_CONFLICT_PREVIEW_SUMMARY="Remote same-path conflict preview blocked direct publish before writing."
REMOTE_RECOVERY_PENDING_OFFLINE_SUMMARY="Unknown deployment stayed pending for retry in the release ledger."
REMOTE_RECOVERY_DEPLOYMENT_RETRY_SUMMARY="Deployment retry refreshed provider status."
REMOTE_RECOVERY_ROLLBACK_PACKAGE_SUMMARY="Rollback package included branch, files, and PR draft."
REMOTE_RECOVERY_EVIDENCE_URL=""
EXTERNAL_VERIFY_EVIDENCE_FILE="$TMP_DIR/EXTERNAL_VERIFICATION_EVIDENCE.md"
ENV

cat >"$ENV_DIR/storekit-sandbox.env" <<ENV
STOREKIT_PRODUCT_ID="personal.site.publisher.pro"
STOREKIT_SANDBOX_PRODUCT_LOOKUP_SUMMARY="Sandbox product lookup loaded personal.site.publisher.pro from App Store sandbox catalog."
STOREKIT_SANDBOX_PURCHASE_SUMMARY="Sandbox purchase completed and entitlement source changed to StoreKit."
STOREKIT_SANDBOX_RESTORE_SUMMARY="Sandbox restore reapplied Pro entitlement after clearing local state."
STOREKIT_SANDBOX_FREE_QUOTA_SUMMARY="Free quota boundary showed upgrade copy before purchase and no quota consumption after Pro unlock."
STOREKIT_SANDBOX_BOUNDARY_EVENTS_SUMMARY="Recent StoreKit boundary events showed free-plan block before purchase and Pro no-quota allow after unlock."
STOREKIT_SANDBOX_EVIDENCE_URL=""
EXTERNAL_VERIFY_EVIDENCE_FILE="$TMP_DIR/EXTERNAL_VERIFICATION_EVIDENCE.md"
ENV

cat >"$ENV_DIR/app-store-archive-validation.env" <<ENV
APP_STORE_ARCHIVE_CLEAN_RELEASE_SUMMARY="Clean Release archive produced from a fresh checkout and reproducible release command."
APP_STORE_ARCHIVE_SIGNING_RUNTIME_SUMMARY="Distribution signature and hardened runtime were verified on the archive."
APP_STORE_ARCHIVE_TRANSPORTER_SUMMARY="App Store build $marketing_version ($build_number) validated successfully before upload with no private account identifiers recorded."
APP_STORE_ARCHIVE_EVIDENCE_FILE="$TMP_DIR/APP_STORE_ARCHIVE_VALIDATION.md"
ENV

cat >"$ENV_DIR/app-store-screenshots.env" <<ENV
APP_STORE_SCREENSHOT_SET_SUMMARY="Captured all required App Store screenshot surfaces with redacted demo content."
APP_STORE_SCREENSHOT_PRIVACY_GATE_SUMMARY="Screenshot privacy gate passed without local paths or token-like strings."
APP_STORE_SCREENSHOT_STRICT_GATE_SUMMARY="Strict screenshot count and manifest sync gates passed."
APP_STORE_SCREENSHOT_DIR="$SCREENSHOT_FIXTURE_DIR"
APP_STORE_SCREENSHOT_MANIFEST_FILE="$SCREENSHOT_FIXTURE_DIR/SCREENSHOT_MANIFEST.md"
ENV

chmod 600 "$ENV_DIR"/*.env

remote_output="$(bash "$RUNNER" --env-dir "$ENV_DIR" --target remote-publish)"
grep -q "external verification runner: execution plan (dry-run)" <<<"$remote_output" \
  || fail "remote target did not print execution plan"
grep -q -- "- remote-publish" <<<"$remote_output" \
  || fail "remote target plan omitted target name"
grep -q "records: github-direct-publish; github-review-publish; gitlab-direct-publish; gitlab-review-publish" <<<"$remote_output" \
  || fail "remote target plan omitted evidence records"
grep -q "Verify GitHub direct commit and PR publishing with a least-privilege token" <<<"$remote_output" \
  || fail "remote target plan omitted checklist mapping"
grep -q "external verification runner: remote-publish dry-run" <<<"$remote_output" \
  || fail "remote target did not run dry-run"
grep -q "remote publish live matrix: dry-run=yes" <<<"$remote_output" \
  || fail "remote target did not delegate to matrix dry-run"
grep -q -- "- token: configured" <<<"$remote_output" \
  || fail "remote target did not export sourced token configuration to matrix"
grep -q -- "- release ledger: configured" <<<"$remote_output" \
  || fail "remote target did not export sourced release ledger configuration to matrix"
if grep -q "gh-runner-private-token" <<<"$remote_output"; then
  fail "remote dry-run leaked token"
fi
DEFAULT_RUNNER_REPORT="$ENV_DIR/ENV_STATUS.md"
[[ -f "$DEFAULT_RUNNER_REPORT" ]] \
  || fail "runner did not write default env status report inside custom env dir"
default_runner_report_text="$(cat "$DEFAULT_RUNNER_REPORT")"
grep -q "Env directory: \`$ENV_DIR\`" <<<"$default_runner_report_text" \
  || fail "runner default env status report did not use custom env dir"
grep -q 'Target: `remote-publish`' <<<"$default_runner_report_text" \
  || fail "runner default env status report omitted target"
grep -q '## Evidence Completion' <<<"$default_runner_report_text" \
  || fail "runner default env status report omitted evidence completion section"
for record in github-direct-publish github-review-publish gitlab-direct-publish gitlab-review-publish; do
  grep -q -- "- \\[ \\] \`$record\`" <<<"$default_runner_report_text" \
    || fail "runner default env status report omitted pending evidence record: $record"
done
if grep -q "gh-runner-private-token" "$DEFAULT_RUNNER_REPORT"; then
  fail "runner default env status report leaked a token value"
fi

storekit_output="$(bash "$RUNNER" --env-dir "$ENV_DIR" --target storekit)"
grep -q "external verification runner: storekit dry-run" <<<"$storekit_output" \
  || fail "storekit target did not run dry-run"
grep -q "shared external recorder validation: ready" <<<"$storekit_output" \
  || fail "storekit target did not validate recorder"

archive_output="$(bash "$RUNNER" --env-dir "$ENV_DIR" --target app-store-archive)"
[[ "$(grep -c "app store archive evidence recorder: ready" <<<"$archive_output")" == "3" ]] \
  || fail "archive target did not record all three archive evidence items"

screenshots_output="$(bash "$RUNNER" --env-dir "$ENV_DIR" --target app-store-screenshots)"
grep -q "external verification runner: app-store-screenshots dry-run" <<<"$screenshots_output" \
  || fail "screenshots target did not run dry-run"
grep -q "app store screenshot evidence recorder: dry-run" <<<"$screenshots_output" \
  || fail "screenshots target did not delegate to screenshot recorder"

all_output="$(bash "$RUNNER" --env-dir "$ENV_DIR" --target all)"
grep -q -- "- app-store-archive" <<<"$all_output" \
  || fail "all target plan omitted app-store-archive"
grep -q "records: clean Release archive; distribution signing/runtime; Transporter/App Store Connect validation" <<<"$all_output" \
  || fail "all target plan omitted archive evidence records"
grep -q "external verification runner: all completed in dry-run mode" <<<"$all_output" \
  || fail "all target did not complete dry-run"
if grep -q "private-token" <<<"$all_output"; then
  fail "all dry-run leaked a token-like value"
fi

remaining_output="$(EXTERNAL_VERIFY_EVIDENCE_FILE="$TMP_DIR/EXTERNAL_VERIFICATION_EVIDENCE.md" bash "$RUNNER" --env-dir "$ENV_DIR" --target remaining)"
grep -q "external verification runner: remaining targets: app-store-archive remote-publish storekit remote-recovery" <<<"$remaining_output" \
  || fail "remaining target did not summarize the expected incomplete targets"
grep -q "external verification runner: execution plan (dry-run)" <<<"$remaining_output" \
  || fail "remaining target did not print execution plan"
grep -q "records: remote-conflict-deployment-rollback" <<<"$remaining_output" \
  || fail "remaining target plan omitted remote recovery record"
grep -q "Verify StoreKit product ID, purchase, restore, and free quota behavior in sandbox" <<<"$remaining_output" \
  || fail "remaining target plan omitted storekit checklist mapping"
grep -q "external verification runner: remote-publish dry-run" <<<"$remaining_output" \
  || fail "remaining target did not run remote publish"
grep -q "external verification runner: storekit dry-run" <<<"$remaining_output" \
  || fail "remaining target did not run storekit"
grep -q "external verification runner: remote-recovery dry-run" <<<"$remaining_output" \
  || fail "remaining target did not run remote recovery"
grep -q "app store archive evidence bundle: dry-run" <<<"$remaining_output" \
  || fail "remaining target did not run app store archive"
if grep -q "app-store-screenshots" <<<"$remaining_output"; then
  fail "remaining target ran screenshots even though screenshot evidence is already complete"
fi

complete_external_file="$TMP_DIR/EXTERNAL_VERIFICATION_COMPLETE.md"
complete_archive_file="$TMP_DIR/APP_STORE_ARCHIVE_COMPLETE.md"
cp "$TMP_DIR/EXTERNAL_VERIFICATION_EVIDENCE.md" "$complete_external_file"
perl -0pi -e 's/- \[ \] `github-direct-publish`/- [x] `github-direct-publish`/g;
              s/- \[ \] `github-review-publish`/- [x] `github-review-publish`/g;
              s/- \[ \] `gitlab-direct-publish`/- [x] `gitlab-direct-publish`/g;
              s/- \[ \] `gitlab-review-publish`/- [x] `gitlab-review-publish`/g;
              s/- \[ \] `remote-conflict-deployment-rollback`/- [x] `remote-conflict-deployment-rollback`/g;
              s/- \[ \] `storekit-sandbox`/- [x] `storekit-sandbox`/g;' "$complete_external_file"
cat >"$complete_archive_file" <<'EOF_ARCHIVE'
# App Store Archive Validation Evidence

- [x] Clean Release archive produced from a clean checkout.
  Evidence: Clean Release archive was produced from a fresh checkout with the release command.
- [x] Distribution signing and hardened runtime verified on the archive.
  Evidence: Distribution signature and hardened runtime were verified on the archived app.
- [x] Archive validated with App Store Connect or Transporter before upload.
  Evidence: Transporter validation completed successfully before upload.
EOF_ARCHIVE
complete_remaining_output="$(
  EXTERNAL_VERIFY_EVIDENCE_FILE="$complete_external_file" \
    APP_STORE_ARCHIVE_EVIDENCE_FILE="$complete_archive_file" \
    bash "$RUNNER" --env-dir "$TMP_DIR/missing-env-dir" --target remaining
)"
grep -q "external verification runner: no remaining targets" <<<"$complete_remaining_output" \
  || fail "complete remaining target did not report no remaining targets"
grep -q "external verification runner: remaining completed in dry-run mode" <<<"$complete_remaining_output" \
  || fail "complete remaining target did not complete without env directory"
if grep -q "private env preflight" <<<"$complete_remaining_output"; then
  fail "complete remaining target ran private env preflight even though no targets remain"
fi

perl -0pi -e 's/REMOTE_VERIFY_GITHUB_TOKEN="[^"]+"/REMOTE_VERIFY_GITHUB_TOKEN=""/' "$ENV_DIR/remote-publish-live.env"
RUNNER_REPORT="$TMP_DIR/runner-env-status.md"
if missing_token_output="$(bash "$RUNNER" --env-dir "$ENV_DIR" --target remote-publish --env-status-report-file "$RUNNER_REPORT" 2>&1)"; then
  fail "runner accepted missing required remote token"
fi
grep -q "private env preflight failed for target remote-publish" <<<"$missing_token_output" \
  || fail "runner did not fail during private env preflight"
if grep -q "execution plan" <<<"$missing_token_output"; then
  fail "runner printed an execution plan after env preflight failed"
fi
if grep -q "external verification runner: remote-publish dry-run" <<<"$missing_token_output"; then
  fail "runner executed remote publish after env preflight failed"
fi
[[ -f "$RUNNER_REPORT" ]] || fail "runner did not write redacted env status report after missing token"
runner_report_text="$(cat "$RUNNER_REPORT")"
grep -q 'Target: `remote-publish`' <<<"$runner_report_text" \
  || fail "runner env status report omitted target"
grep -q 'remote-publish-live.env has empty or placeholder value for REMOTE_VERIFY_GITHUB_TOKEN' <<<"$runner_report_text" \
  || fail "runner env status report omitted missing token issue"
runner_report_mode="$(stat -f "%Lp" "$RUNNER_REPORT")"
[[ "$runner_report_mode" == "600" ]] || fail "runner env status report mode is $runner_report_mode, expected 600"
if grep -q "gl-runner-private-token" "$RUNNER_REPORT"; then
  fail "runner env status report leaked a token value"
fi

if bash "$RUNNER" --env-dir "$ROOT_DIR/docs/release-evidence" --target storekit >/dev/null 2>&1; then
  fail "runner accepted env directory inside repository"
fi

echo "external verification env runner test: passed"
