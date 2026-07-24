#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_DIR="${EXTERNAL_VERIFY_ENV_DIR:-/private/tmp/personal-site-publisher-release-envs}"
ENV_STATUS_REPORT_FILE="${EXTERNAL_VERIFY_ENV_STATUS_REPORT_FILE:-$ENV_DIR/ENV_STATUS.md}"
EXTERNAL_EVIDENCE_FILE="${EXTERNAL_VERIFY_EVIDENCE_FILE:-$ROOT_DIR/docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md}"
ARCHIVE_EVIDENCE_FILE="${APP_STORE_ARCHIVE_EVIDENCE_FILE:-$ROOT_DIR/docs/release-evidence/APP_STORE_ARCHIVE_VALIDATION.md}"
CHECKLIST_FILE="${APP_STORE_CHECKLIST_FILE:-$ROOT_DIR/APP_STORE_CHECKLIST.md}"

usage() {
  cat <<'USAGE'
Usage: script/print_remaining_external_verification.sh

Prints the remaining external verification targets, private env files, and
next commands without creating files, sourcing secrets, or writing evidence.

Environment overrides:
  EXTERNAL_VERIFY_ENV_DIR       Private env directory to show in commands.
  EXTERNAL_VERIFY_ENV_STATUS_REPORT_FILE Redacted env status Markdown path.
  EXTERNAL_VERIFY_EVIDENCE_FILE External evidence markdown to inspect.
  APP_STORE_ARCHIVE_EVIDENCE_FILE App Store archive evidence markdown to inspect.
  APP_STORE_CHECKLIST_FILE      App Store checklist markdown to reference.
USAGE
}

fail() {
  echo "remaining external verification: $*" >&2
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

[[ "$#" -eq 0 ]] || fail "unknown argument: $1"
[[ -f "$EXTERNAL_EVIDENCE_FILE" ]] || fail "external evidence file is missing: $EXTERNAL_EVIDENCE_FILE"
[[ -f "$ARCHIVE_EVIDENCE_FILE" ]] || fail "App Store archive evidence file is missing: $ARCHIVE_EVIDENCE_FILE"
[[ -f "$CHECKLIST_FILE" ]] || fail "App Store checklist file is missing: $CHECKLIST_FILE"

external_item_complete() {
  local item_id="$1"
  grep -Eq "^- \[[xX]\][[:space:]]+\`$item_id\`" "$EXTERNAL_EVIDENCE_FILE"
}

app_store_archive_complete() {
  STRICT_ARCHIVE_EVIDENCE_ONLY=1 APP_STORE_ARCHIVE_EVIDENCE_FILE="$ARCHIVE_EVIDENCE_FILE" \
    bash "$ROOT_DIR/script/check_app_store_archive_readiness.sh" --dry-run >/dev/null 2>&1
}

target_rows=()
add_target() {
  local id="$1"
  local env_file="$2"
  local evidence="$3"
  local detail="$4"
  local checklist="$5"
  target_rows+=("$id|$env_file|$evidence|$detail|$checklist")
}

if ! app_store_archive_complete; then
  add_target \
    "app-store-archive" \
    "app-store-archive-validation.env" \
    "docs/release-evidence/APP_STORE_ARCHIVE_VALIDATION.md" \
    "Clean Release archive, distribution signing/hardened runtime, and Transporter/App Store Connect validation." \
    "Confirm distribution signing team and hardened runtime on the archived app; Produce a clean Release archive from a clean checkout; Validate the archive with App Store Connect or Transporter before upload."
fi

if ! external_item_complete github-direct-publish \
  || ! external_item_complete github-review-publish \
  || ! external_item_complete gitlab-direct-publish \
  || ! external_item_complete gitlab-review-publish; then
  add_target \
    "remote-publish" \
    "remote-publish-live.env" \
    "docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md" \
    "GitHub direct/PR and GitLab direct/MR disposable repository live API verification." \
    "Verify GitHub direct commit and PR publishing with a least-privilege token; Verify GitLab direct commit and MR publishing with a least-privilege token."
fi

if ! external_item_complete storekit-sandbox; then
  add_target \
    "storekit" \
    "storekit-sandbox.env" \
    "docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md" \
    "StoreKit sandbox product lookup, purchase, restore, free quota, and Pro boundary evidence." \
    "Verify StoreKit product ID, purchase, restore, and free quota behavior in sandbox."
fi

if ! external_item_complete remote-conflict-deployment-rollback; then
  add_target \
    "remote-recovery" \
    "remote-recovery.env" \
    "docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md" \
    "Remote conflict preview, pending/offline deployment, retry, and rollback package evidence." \
    "Verify remote conflict preview, pending/offline states, deployment checks, and rollback guidance."
fi

if ! external_item_complete app-store-screenshots; then
  add_target \
    "app-store-screenshots" \
    "app-store-screenshots.env" \
    "docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md" \
    "App Store screenshot capture, screenshot privacy, and strict screenshot gate evidence." \
    "Capture the nine screens listed in the screenshot manifest; Verify screenshots contain no private content, local tokens, or personal paths."
fi

echo "remaining external verification: ${#target_rows[@]} target(s)"

if [[ "${#target_rows[@]}" -eq 0 ]]; then
  echo "- all external verification evidence is complete"
  echo
  echo "final App Store gate:"
  echo "  ./script/check_release_gate.sh --profile app-store"
  exit 0
fi

for row in "${target_rows[@]}"; do
  IFS='|' read -r id env_file evidence detail checklist <<<"$row"
  echo "- $id"
  echo "  env: $ENV_DIR/$env_file"
  echo "  evidence: $evidence"
  echo "  checklist: $checklist"
  echo "  detail: $detail"
done

echo
echo "next commands:"
echo "  script/prepare_external_verification_envs.sh --output-dir $ENV_DIR --target remaining"
echo "  script/check_external_verification_envs.sh --env-dir $ENV_DIR --mode filled --target remaining"
echo "  script/check_external_verification_envs.sh --env-dir $ENV_DIR --mode filled --target remaining --report-file $ENV_STATUS_REPORT_FILE"
echo "  script/run_external_verification_from_envs.sh --env-dir $ENV_DIR --target remaining --env-status-report-file $ENV_STATUS_REPORT_FILE"
echo "  script/run_external_verification_from_envs.sh --env-dir $ENV_DIR --target remaining --env-status-report-file $ENV_STATUS_REPORT_FILE --execute"
