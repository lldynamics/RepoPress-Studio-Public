#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUMMARY="$ROOT_DIR/script/print_remaining_external_verification.sh"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-remaining-external.XXXXXX)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "remaining external verification summary test: $*" >&2
  exit 1
}

[[ -f "$SUMMARY" ]] || fail "print_remaining_external_verification.sh is missing"

current_output="$(bash "$SUMMARY")"
grep -q "remaining external verification: 5 target(s)" <<<"$current_output" \
  || fail "current summary did not report 5 remaining targets"
for target in app-store-archive remote-publish storekit remote-recovery app-store-screenshots; do
  grep -q -- "- $target" <<<"$current_output" \
    || fail "current summary omitted $target"
done
grep -q "prepare_external_verification_envs.sh --output-dir /private/tmp/personal-site-publisher-release-envs --target remaining" <<<"$current_output" \
  || fail "current summary omitted target-aware prepare command"
grep -q "check_external_verification_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --mode filled --target remaining --report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md" <<<"$current_output" \
  || fail "current summary omitted redacted env status report command"
grep -q "run_external_verification_from_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --target remaining --env-status-report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md" <<<"$current_output" \
  || fail "current summary omitted status-report-aware runner command"
grep -q "run_external_verification_from_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --target remaining --env-status-report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md --execute" <<<"$current_output" \
  || fail "current summary omitted execute command"
for checklist_item in \
  "Confirm distribution signing team and hardened runtime on the archived app" \
  "Produce a clean Release archive from a clean checkout" \
  "Validate the archive with App Store Connect or Transporter before upload" \
  "Verify StoreKit product ID, purchase, restore, and free quota behavior in sandbox" \
  "Verify GitHub direct commit and PR publishing with a least-privilege token" \
  "Verify GitLab direct commit and MR publishing with a least-privilege token" \
  "Verify remote conflict preview, pending/offline states, deployment checks, and rollback guidance"
do
  grep -q "$checklist_item" <<<"$current_output" \
    || fail "current summary omitted checklist item: $checklist_item"
done

custom_env_dir="$TMP_DIR/custom-envs"
custom_report="$TMP_DIR/custom-env-status.md"
custom_output="$(EXTERNAL_VERIFY_ENV_DIR="$custom_env_dir" EXTERNAL_VERIFY_ENV_STATUS_REPORT_FILE="$custom_report" bash "$SUMMARY")"
grep -q "check_external_verification_envs.sh --env-dir $custom_env_dir --mode filled --target remaining --report-file $custom_report" <<<"$custom_output" \
  || fail "custom summary omitted overridden redacted env status report command"
grep -q "run_external_verification_from_envs.sh --env-dir $custom_env_dir --target remaining --env-status-report-file $custom_report" <<<"$custom_output" \
  || fail "custom summary omitted overridden runner status report command"

external_file="$TMP_DIR/EXTERNAL_VERIFICATION_EVIDENCE.md"
archive_file="$TMP_DIR/APP_STORE_ARCHIVE_VALIDATION.md"
checklist_file="$TMP_DIR/APP_STORE_CHECKLIST.md"
cp "$ROOT_DIR/docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md" "$external_file"
cp "$ROOT_DIR/APP_STORE_CHECKLIST.md" "$checklist_file"

perl -0pi -e 's/- \[ \] `github-direct-publish`/- [x] `github-direct-publish`/g;
              s/- \[ \] `github-review-publish`/- [x] `github-review-publish`/g;
              s/- \[ \] `gitlab-direct-publish`/- [x] `gitlab-direct-publish`/g;
              s/- \[ \] `gitlab-review-publish`/- [x] `gitlab-review-publish`/g;
              s/- \[ \] `remote-conflict-deployment-rollback`/- [x] `remote-conflict-deployment-rollback`/g;
              s/- \[ \] `storekit-sandbox`/- [x] `storekit-sandbox`/g;
              s/- \[ \] `app-store-screenshots`/- [x] `app-store-screenshots`/g;' "$external_file"
cat >"$archive_file" <<'EOF_ARCHIVE'
# App Store Archive Validation Evidence

- [x] Clean Release archive produced from a clean checkout.
  Evidence: Clean Release archive was produced from a fresh checkout with the release command.
- [x] Distribution signing and hardened runtime verified on the archive.
  Evidence: Distribution signature and hardened runtime were verified on the archived app.
- [x] Archive validated with App Store Connect or Transporter before upload.
  Evidence: Transporter validation completed successfully before upload.
EOF_ARCHIVE

complete_output="$(EXTERNAL_VERIFY_EVIDENCE_FILE="$external_file" APP_STORE_ARCHIVE_EVIDENCE_FILE="$archive_file" APP_STORE_CHECKLIST_FILE="$checklist_file" bash "$SUMMARY")"
grep -q "remaining external verification: 0 target(s)" <<<"$complete_output" \
  || fail "complete summary did not report 0 remaining targets"
grep -q "all external verification evidence is complete" <<<"$complete_output" \
  || fail "complete summary omitted complete message"
grep -q "./script/check_release_gate.sh --strict" <<<"$complete_output" \
  || fail "complete summary omitted final strict gate"

echo "remaining external verification summary test: passed"
