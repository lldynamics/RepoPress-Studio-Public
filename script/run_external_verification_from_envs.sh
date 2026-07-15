#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_DIR="${EXTERNAL_VERIFY_ENV_DIR:-/private/tmp/personal-site-publisher-release-envs}"
ENV_STATUS_REPORT_FILE="${EXTERNAL_VERIFY_ENV_STATUS_REPORT_FILE:-}"
TARGET="all"
EXECUTE=0
WRITE_EVIDENCE=1

usage() {
  cat <<'USAGE'
Usage: script/run_external_verification_from_envs.sh [--env-dir <path>] [--target <name>] [--execute] [--no-write-evidence] [--env-status-report-file <path>]

Runs release external-verification commands from private env files without
printing secret values. Default mode is dry-run.

Targets:
  all
  remaining
  remote-publish
  storekit
  remote-recovery
  app-store-screenshots
  app-store-archive

Options:
  --env-dir <path>     Directory produced by prepare_external_verification_envs.sh.
  --target <name>      One target above. Defaults to all.
  --execute            Perform live/provider or evidence-writing actions.
  --no-write-evidence  Remote-publish only: run provider checks without writing evidence.
  --env-status-report-file <path>
                       Redacted env status report path. Defaults to
                       <env-dir>/ENV_STATUS.md.
USAGE
}

write_env_status_report() {
  [[ -n "$ENV_STATUS_REPORT_FILE" ]] || return 0
  case "$ENV_STATUS_REPORT_FILE" in
    "$ROOT_DIR"|"$ROOT_DIR"/*)
      return 0
      ;;
  esac
  if bash "$ROOT_DIR/script/check_external_verification_envs.sh" \
    --env-dir "$ENV_DIR" \
    --mode filled \
    --target "$TARGET" \
    --report-file "$ENV_STATUS_REPORT_FILE" >/dev/null 2>&1; then
    echo "external verification runner: wrote redacted env status report $ENV_STATUS_REPORT_FILE" >&2
  elif [[ -f "$ENV_STATUS_REPORT_FILE" ]]; then
    echo "external verification runner: wrote redacted env status report $ENV_STATUS_REPORT_FILE" >&2
  fi
}

fail() {
  echo "external verification runner: $*" >&2
  write_env_status_report
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --env-dir)
      [[ "$#" -ge 2 ]] || fail "--env-dir requires a path"
      ENV_DIR="$2"
      shift 2
      ;;
    --target)
      [[ "$#" -ge 2 ]] || fail "--target requires a value"
      TARGET="$2"
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
    --env-status-report-file)
      [[ "$#" -ge 2 ]] || fail "--env-status-report-file requires a path"
      ENV_STATUS_REPORT_FILE="$2"
      shift 2
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

if [[ "$ENV_DIR" != /* ]]; then
  ENV_DIR="$(pwd -P)/$ENV_DIR"
fi
if [[ -z "$ENV_STATUS_REPORT_FILE" ]]; then
  ENV_STATUS_REPORT_FILE="$ENV_DIR/ENV_STATUS.md"
elif [[ "$ENV_STATUS_REPORT_FILE" != /* ]]; then
  ENV_STATUS_REPORT_FILE="$(pwd -P)/$ENV_STATUS_REPORT_FILE"
fi

case "$ENV_DIR" in
  "$ROOT_DIR"|"$ROOT_DIR"/*)
    fail "env directory must be outside the repository"
    ;;
esac

case "$TARGET" in
  all|remaining|remote-publish|storekit|remote-recovery|app-store-screenshots|app-store-archive) ;;
  *) fail "unsupported target: $TARGET" ;;
esac

require_file_mode() {
  local file="$1"
  [[ -f "$file" ]] || fail "missing private env file: ${file##*/}"
  local mode
  mode="$(stat -f "%Lp" "$file")"
  [[ "$mode" == "600" ]] || fail "${file##*/} mode is $mode, expected 600"
}

require_value() {
  local name="$1"
  local value="${!name:-}"
  local lower
  lower="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "${value//[[:space:]]/}" || "$lower" == todo* || "$lower" == *"todo:"* || "$lower" == *"<"* || "$lower" == *"待填写"* ]]; then
    fail "$name is missing or still a placeholder"
  fi
}

external_evidence_file() {
  printf '%s' "${EXTERNAL_VERIFY_EVIDENCE_FILE:-$ROOT_DIR/docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md}"
}

external_item_complete() {
  local item_id="$1"
  local file
  file="$(external_evidence_file)"
  [[ -f "$file" ]] && grep -Eq "^- \[[xX]\][[:space:]]+\`$item_id\`" "$file"
}

app_store_archive_complete() {
  STRICT_ARCHIVE_EVIDENCE_ONLY=1 APP_STORE_ARCHIVE_EVIDENCE_FILE="${APP_STORE_ARCHIVE_EVIDENCE_FILE:-}" \
    bash "$ROOT_DIR/script/check_app_store_archive_readiness.sh" --dry-run >/dev/null 2>&1
}

remaining_targets() {
  local targets=()
  if ! app_store_archive_complete; then
    targets+=(app-store-archive)
  fi
  if ! external_item_complete github-direct-publish \
    || ! external_item_complete github-review-publish \
    || ! external_item_complete gitlab-direct-publish \
    || ! external_item_complete gitlab-review-publish; then
    targets+=(remote-publish)
  fi
  if ! external_item_complete storekit-sandbox; then
    targets+=(storekit)
  fi
  if ! external_item_complete remote-conflict-deployment-rollback; then
    targets+=(remote-recovery)
  fi
  if ! external_item_complete app-store-screenshots; then
    targets+=(app-store-screenshots)
  fi
  if [[ "${#targets[@]}" -gt 0 ]]; then
    printf '%s\n' "${targets[@]}"
  fi
}

selected_remaining_targets=()
if [[ "$TARGET" == "remaining" ]]; then
  while IFS= read -r target; do
    [[ -n "$target" ]] && selected_remaining_targets+=("$target")
  done < <(remaining_targets)
  if [[ "${#selected_remaining_targets[@]}" -eq 0 ]]; then
    echo "external verification runner: no remaining targets"
    echo "external verification runner: remaining completed in $([[ "$EXECUTE" == "1" ]] && echo execute || echo dry-run) mode"
    exit 0
  fi
fi

[[ -d "$ENV_DIR" ]] || fail "env directory is missing: $ENV_DIR"
dir_mode="$(stat -f "%Lp" "$ENV_DIR")"
[[ "$dir_mode" == "700" ]] || fail "env directory mode is $dir_mode, expected 700"

if ! bash "$ROOT_DIR/script/check_external_verification_envs.sh" \
  --env-dir "$ENV_DIR" \
  --mode filled \
  --target "$TARGET" \
  --report-file "$ENV_STATUS_REPORT_FILE"; then
  echo "external verification runner: private env preflight failed for target $TARGET" >&2
  exit 1
fi
echo "external verification runner: private env preflight passed for target $TARGET"

target_plan_lines() {
  local target="$1"
  case "$target" in
    app-store-archive)
      cat <<'PLAN'
  env: app-store-archive-validation.env
  evidence: docs/release-evidence/APP_STORE_ARCHIVE_VALIDATION.md
  records: clean Release archive; distribution signing/runtime; Transporter/App Store Connect validation
  checklist: Confirm distribution signing team and hardened runtime on the archived app; Produce a clean Release archive from a clean checkout; Validate the archive with App Store Connect or Transporter before upload.
PLAN
      ;;
    remote-publish)
      cat <<'PLAN'
  env: remote-publish-live.env
  evidence: docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md
  records: github-direct-publish; github-review-publish; gitlab-direct-publish; gitlab-review-publish
  checklist: Verify GitHub direct commit and PR publishing with a least-privilege token; Verify GitLab direct commit and MR publishing with a least-privilege token.
PLAN
      ;;
    storekit)
      cat <<'PLAN'
  env: storekit-sandbox.env
  evidence: docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md
  records: storekit-sandbox
  checklist: Verify StoreKit product ID, purchase, restore, and free quota behavior in sandbox.
PLAN
      ;;
    remote-recovery)
      cat <<'PLAN'
  env: remote-recovery.env
  evidence: docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md
  records: remote-conflict-deployment-rollback
  checklist: Verify remote conflict preview, pending/offline states, deployment checks, and rollback guidance.
PLAN
      ;;
    app-store-screenshots)
      cat <<'PLAN'
  env: app-store-screenshots.env
  evidence: docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md
  records: app-store-screenshots
  checklist: Capture the nine screens listed in the screenshot manifest; Verify screenshots contain no private content, local tokens, or personal paths.
PLAN
      ;;
    *)
      fail "unsupported target in plan: $target"
      ;;
  esac
}

print_execution_plan() {
  local mode="$1"
  shift
  local targets=("$@")
  echo "external verification runner: execution plan ($mode)"
  if [[ "${#targets[@]}" -eq 0 ]]; then
    echo "- no targets"
    return
  fi
  for target in "${targets[@]}"; do
    echo "- $target"
    target_plan_lines "$target"
  done
}

source_env_file() {
  local filename="$1"
  local path="$ENV_DIR/$filename"
  require_file_mode "$path"
  local had_allexport=0
  case "$-" in
    *a*) had_allexport=1 ;;
  esac
  set -a
  # shellcheck disable=SC1090
  source "$path"
  if [[ "$had_allexport" != "1" ]]; then
    set +a
  fi
}

execute_flag() {
  [[ "$EXECUTE" == "1" ]] && printf '%s' "--execute" || printf '%s' "--dry-run"
}

run_remote_publish() {
  source_env_file "remote-publish-live.env"
  require_value REMOTE_VERIFY_GITHUB_TOKEN
  require_value REMOTE_VERIFY_GITHUB_OWNER
  require_value REMOTE_VERIFY_GITHUB_REPO
  require_value REMOTE_VERIFY_GITHUB_DIRECT_RELEASE_LEDGER
  require_value REMOTE_VERIFY_GITHUB_REVIEW_RELEASE_LEDGER
  require_value REMOTE_VERIFY_GITLAB_TOKEN
  require_value REMOTE_VERIFY_GITLAB_OWNER
  require_value REMOTE_VERIFY_GITLAB_REPO
  require_value REMOTE_VERIFY_GITLAB_DIRECT_RELEASE_LEDGER
  require_value REMOTE_VERIFY_GITLAB_REVIEW_RELEASE_LEDGER

  args=()
  if [[ "$EXECUTE" == "1" ]]; then
    args+=(--execute)
  fi
  if [[ "$WRITE_EVIDENCE" == "0" ]]; then
    args+=(--no-write-evidence)
  fi

  echo "external verification runner: remote-publish $([[ "$EXECUTE" == "1" ]] && echo execute || echo dry-run)"
  if [[ "${#args[@]}" -eq 0 ]]; then
    bash "$ROOT_DIR/script/verify_remote_publish_live_matrix.sh"
  else
    bash "$ROOT_DIR/script/verify_remote_publish_live_matrix.sh" "${args[@]}"
  fi
}

run_storekit() {
  source_env_file "storekit-sandbox.env"
  require_value STOREKIT_PRODUCT_ID
  require_value STOREKIT_SANDBOX_PRODUCT_LOOKUP_SUMMARY
  require_value STOREKIT_SANDBOX_PURCHASE_SUMMARY
  require_value STOREKIT_SANDBOX_RESTORE_SUMMARY
  require_value STOREKIT_SANDBOX_FREE_QUOTA_SUMMARY
  require_value STOREKIT_SANDBOX_BOUNDARY_EVENTS_SUMMARY

  args=(
    --product-lookup "$STOREKIT_SANDBOX_PRODUCT_LOOKUP_SUMMARY"
    --purchase "$STOREKIT_SANDBOX_PURCHASE_SUMMARY"
    --restore "$STOREKIT_SANDBOX_RESTORE_SUMMARY"
    --free-quota "$STOREKIT_SANDBOX_FREE_QUOTA_SUMMARY"
    --boundary-events "$STOREKIT_SANDBOX_BOUNDARY_EVENTS_SUMMARY"
  )
  if [[ -n "${STOREKIT_SANDBOX_EVIDENCE_URL:-}" ]]; then
    args+=(--evidence-url "$STOREKIT_SANDBOX_EVIDENCE_URL")
  fi
  args+=("$(execute_flag)")

  echo "external verification runner: storekit $([[ "$EXECUTE" == "1" ]] && echo execute || echo dry-run)"
  STOREKIT_PRODUCT_ID="$STOREKIT_PRODUCT_ID" EXTERNAL_VERIFY_EVIDENCE_FILE="${EXTERNAL_VERIFY_EVIDENCE_FILE:-}" \
    bash "$ROOT_DIR/script/record_storekit_sandbox_evidence.sh" "${args[@]}"
}

run_remote_recovery() {
  source_env_file "remote-recovery.env"
  require_value REMOTE_RECOVERY_CONFLICT_PREVIEW_SUMMARY
  require_value REMOTE_RECOVERY_PENDING_OFFLINE_SUMMARY
  require_value REMOTE_RECOVERY_DEPLOYMENT_RETRY_SUMMARY
  require_value REMOTE_RECOVERY_ROLLBACK_PACKAGE_SUMMARY

  args=(
    --remote-conflict-preview "$REMOTE_RECOVERY_CONFLICT_PREVIEW_SUMMARY"
    --pending-offline-state "$REMOTE_RECOVERY_PENDING_OFFLINE_SUMMARY"
    --deployment-retry "$REMOTE_RECOVERY_DEPLOYMENT_RETRY_SUMMARY"
    --rollback-package "$REMOTE_RECOVERY_ROLLBACK_PACKAGE_SUMMARY"
  )
  if [[ -n "${REMOTE_RECOVERY_EVIDENCE_URL:-}" ]]; then
    args+=(--evidence-url "$REMOTE_RECOVERY_EVIDENCE_URL")
  fi
  args+=("$(execute_flag)")

  echo "external verification runner: remote-recovery $([[ "$EXECUTE" == "1" ]] && echo execute || echo dry-run)"
  EXTERNAL_VERIFY_EVIDENCE_FILE="${EXTERNAL_VERIFY_EVIDENCE_FILE:-}" \
    bash "$ROOT_DIR/script/record_remote_recovery_evidence.sh" "${args[@]}"
}

run_app_store_screenshots() {
  source_env_file "app-store-screenshots.env"
  require_value APP_STORE_SCREENSHOT_SET_SUMMARY
  require_value APP_STORE_SCREENSHOT_PRIVACY_GATE_SUMMARY
  require_value APP_STORE_SCREENSHOT_STRICT_GATE_SUMMARY

  args=("$(execute_flag)")

  echo "external verification runner: app-store-screenshots $([[ "$EXECUTE" == "1" ]] && echo execute || echo dry-run)"
  APP_STORE_SCREENSHOT_SET_SUMMARY="$APP_STORE_SCREENSHOT_SET_SUMMARY" \
    APP_STORE_SCREENSHOT_PRIVACY_GATE_SUMMARY="$APP_STORE_SCREENSHOT_PRIVACY_GATE_SUMMARY" \
    APP_STORE_SCREENSHOT_STRICT_GATE_SUMMARY="$APP_STORE_SCREENSHOT_STRICT_GATE_SUMMARY" \
    SCREENSHOT_DIR="${APP_STORE_SCREENSHOT_DIR:-}" \
    SCREENSHOT_MANIFEST_FILE="${APP_STORE_SCREENSHOT_MANIFEST_FILE:-}" \
    bash "$ROOT_DIR/script/record_app_store_screenshot_evidence.sh" "${args[@]}"
}

run_app_store_archive() {
  source_env_file "app-store-archive-validation.env"
  require_value APP_STORE_ARCHIVE_CLEAN_RELEASE_SUMMARY
  require_value APP_STORE_ARCHIVE_SIGNING_RUNTIME_SUMMARY
  require_value APP_STORE_ARCHIVE_TRANSPORTER_SUMMARY

  echo "external verification runner: app-store-archive $([[ "$EXECUTE" == "1" ]] && echo execute || echo dry-run)"
  APP_STORE_ARCHIVE_EVIDENCE_FILE="${APP_STORE_ARCHIVE_EVIDENCE_FILE:-}" \
    bash "$ROOT_DIR/script/record_app_store_archive_validation_bundle.sh" \
      --clean-release-archive "$APP_STORE_ARCHIVE_CLEAN_RELEASE_SUMMARY" \
      --distribution-signing-runtime "$APP_STORE_ARCHIVE_SIGNING_RUNTIME_SUMMARY" \
      --transporter-validation "$APP_STORE_ARCHIVE_TRANSPORTER_SUMMARY" \
      "$(execute_flag)"
}

case "$TARGET" in
  all)
    print_execution_plan "$([[ "$EXECUTE" == "1" ]] && echo execute || echo dry-run)" \
      remote-publish storekit remote-recovery app-store-screenshots app-store-archive
    run_remote_publish
    run_storekit
    run_remote_recovery
    run_app_store_screenshots
    run_app_store_archive
    ;;
  remaining)
    echo "external verification runner: remaining targets: ${selected_remaining_targets[*]}"
    print_execution_plan "$([[ "$EXECUTE" == "1" ]] && echo execute || echo dry-run)" "${selected_remaining_targets[@]}"
    for target in "${selected_remaining_targets[@]}"; do
      case "$target" in
        app-store-archive) run_app_store_archive ;;
        remote-publish) run_remote_publish ;;
        storekit) run_storekit ;;
        remote-recovery) run_remote_recovery ;;
        app-store-screenshots) run_app_store_screenshots ;;
      esac
    done
    ;;
  remote-publish)
    print_execution_plan "$([[ "$EXECUTE" == "1" ]] && echo execute || echo dry-run)" remote-publish
    run_remote_publish
    ;;
  storekit)
    print_execution_plan "$([[ "$EXECUTE" == "1" ]] && echo execute || echo dry-run)" storekit
    run_storekit
    ;;
  remote-recovery)
    print_execution_plan "$([[ "$EXECUTE" == "1" ]] && echo execute || echo dry-run)" remote-recovery
    run_remote_recovery
    ;;
  app-store-screenshots)
    print_execution_plan "$([[ "$EXECUTE" == "1" ]] && echo execute || echo dry-run)" app-store-screenshots
    run_app_store_screenshots
    ;;
  app-store-archive)
    print_execution_plan "$([[ "$EXECUTE" == "1" ]] && echo execute || echo dry-run)" app-store-archive
    run_app_store_archive
    ;;
  *)
    fail "unsupported target: $TARGET"
    ;;
esac

echo "external verification runner: $TARGET completed in $([[ "$EXECUTE" == "1" ]] && echo execute || echo dry-run) mode"
