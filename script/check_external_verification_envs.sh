#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_DIR="${EXTERNAL_VERIFY_ENV_DIR:-/private/tmp/personal-site-publisher-release-envs}"
MODE="filled"
TARGET="all"
REPORT_FILE=""

usage() {
  cat <<'USAGE'
Usage: script/check_external_verification_envs.sh [--env-dir <path>] [--mode template|filled] [--target <name>] [--report-file <path>]

Checks private release-verification env files without printing secret values.

Modes:
  template  Validate repository env templates and required variable names.
  filled    Validate copied env files outside the repository, restrictive
            permissions, and required values for live verification.

Targets:
  all
  remaining
  remote-publish
  storekit
  remote-recovery
  app-store-screenshots
  app-store-archive

Options:
  --report-file <path>  Write a redacted Markdown status report outside the
                        repository. Secret values are never included.
USAGE
}

fail() {
  echo "external verification env check: $*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --env-dir)
      [[ "$#" -ge 2 ]] || fail "--env-dir requires a path"
      ENV_DIR="$2"
      shift 2
      ;;
    --mode)
      [[ "$#" -ge 2 ]] || fail "--mode requires template or filled"
      MODE="$2"
      shift 2
      ;;
    --target)
      [[ "$#" -ge 2 ]] || fail "--target requires a value"
      TARGET="$2"
      shift 2
      ;;
    --report-file)
      [[ "$#" -ge 2 ]] || fail "--report-file requires a path"
      REPORT_FILE="$2"
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
if [[ -n "$REPORT_FILE" && "$REPORT_FILE" != /* ]]; then
  REPORT_FILE="$(pwd -P)/$REPORT_FILE"
fi

[[ "$MODE" == "template" || "$MODE" == "filled" ]] || fail "--mode must be template or filled"
case "$TARGET" in
  all|remaining|remote-publish|storekit|remote-recovery|app-store-screenshots|app-store-archive) ;;
  *) fail "--target must be all, remaining, remote-publish, storekit, remote-recovery, app-store-screenshots, or app-store-archive" ;;
esac

if [[ "$MODE" == "filled" ]]; then
  case "$ENV_DIR" in
    "$ROOT_DIR"|"$ROOT_DIR"/*)
      fail "env directory must be outside the repository"
      ;;
  esac
  [[ -d "$ENV_DIR" ]] || fail "env directory is missing: $ENV_DIR"
  dir_mode="$(stat -f "%Lp" "$ENV_DIR")"
  [[ "$dir_mode" == "700" ]] || fail "env directory mode is $dir_mode, expected 700"
fi

if [[ -n "$REPORT_FILE" ]]; then
  case "$REPORT_FILE" in
    "$ROOT_DIR"|"$ROOT_DIR"/*)
      fail "report file must be outside the repository"
      ;;
  esac
fi

env_specs=(
  "remote-publish:remote-publish-live.env:docs/release-evidence/remote-publish-live.env.example:REMOTE_VERIFY_GITHUB_TOKEN,REMOTE_VERIFY_GITHUB_OWNER,REMOTE_VERIFY_GITHUB_REPO,REMOTE_VERIFY_GITHUB_DIRECT_RELEASE_LEDGER,REMOTE_VERIFY_GITHUB_REVIEW_RELEASE_LEDGER,REMOTE_VERIFY_GITLAB_TOKEN,REMOTE_VERIFY_GITLAB_OWNER,REMOTE_VERIFY_GITLAB_REPO,REMOTE_VERIFY_GITLAB_DIRECT_RELEASE_LEDGER,REMOTE_VERIFY_GITLAB_REVIEW_RELEASE_LEDGER"
  "remote-recovery:remote-recovery.env:docs/release-evidence/remote-recovery.env.example:REMOTE_RECOVERY_CONFLICT_PREVIEW_SUMMARY,REMOTE_RECOVERY_PENDING_OFFLINE_SUMMARY,REMOTE_RECOVERY_DEPLOYMENT_RETRY_SUMMARY,REMOTE_RECOVERY_ROLLBACK_PACKAGE_SUMMARY"
  "storekit:storekit-sandbox.env:docs/release-evidence/storekit-sandbox.env.example:STOREKIT_PRODUCT_ID,STOREKIT_SANDBOX_PRODUCT_LOOKUP_SUMMARY,STOREKIT_SANDBOX_PURCHASE_SUMMARY,STOREKIT_SANDBOX_RESTORE_SUMMARY,STOREKIT_SANDBOX_FREE_QUOTA_SUMMARY,STOREKIT_SANDBOX_BOUNDARY_EVENTS_SUMMARY"
  "app-store-screenshots:app-store-screenshots.env:docs/release-evidence/app-store-screenshots.env.example:APP_STORE_SCREENSHOT_SET_SUMMARY,APP_STORE_SCREENSHOT_PRIVACY_GATE_SUMMARY,APP_STORE_SCREENSHOT_STRICT_GATE_SUMMARY"
  "app-store-archive:app-store-archive-validation.env:docs/release-evidence/app-store-archive-validation.env.example:APP_STORE_ARCHIVE_CLEAN_RELEASE_SUMMARY,APP_STORE_ARCHIVE_SIGNING_RUNTIME_SUMMARY,APP_STORE_ARCHIVE_TRANSPORTER_SUMMARY"
)

external_evidence_file() {
  printf '%s' "${EXTERNAL_VERIFY_EVIDENCE_FILE:-$ROOT_DIR/docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md}"
}

app_store_archive_evidence_file() {
  printf '%s' "${APP_STORE_ARCHIVE_EVIDENCE_FILE:-$ROOT_DIR/docs/release-evidence/APP_STORE_ARCHIVE_VALIDATION.md}"
}

external_item_complete() {
  local item_id="$1"
  local file
  file="$(external_evidence_file)"
  [[ -f "$file" ]] && grep -Eq "^- \[[xX]\][[:space:]]+\`$item_id\`" "$file"
}

archive_item_complete() {
  local item_title="$1"
  local file
  file="$(app_store_archive_evidence_file)"
  [[ -f "$file" ]] && grep -Eq "^- \[[xX]\][[:space:]]+$item_title$" "$file"
}

app_store_archive_complete() {
  STRICT_ARCHIVE_EVIDENCE_ONLY=1 APP_STORE_ARCHIVE_EVIDENCE_FILE="${APP_STORE_ARCHIVE_EVIDENCE_FILE:-}" \
    bash "$ROOT_DIR/script/check_app_store_archive_readiness.sh" --dry-run >/dev/null 2>&1
}

target_is_remaining() {
  local target="$1"
  case "$target" in
    app-store-archive)
      ! app_store_archive_complete
      ;;
    remote-publish)
      ! external_item_complete github-direct-publish \
        || ! external_item_complete github-review-publish \
        || ! external_item_complete gitlab-direct-publish \
        || ! external_item_complete gitlab-review-publish
      ;;
    storekit)
      ! external_item_complete storekit-sandbox
      ;;
    remote-recovery)
      ! external_item_complete remote-conflict-deployment-rollback
      ;;
    app-store-screenshots)
      ! external_item_complete app-store-screenshots
      ;;
    *)
      return 1
      ;;
  esac
}

should_check_target() {
  local target="$1"
  if [[ "$TARGET" == "all" ]]; then
    return 0
  fi
  if [[ "$TARGET" == "remaining" ]]; then
    target_is_remaining "$target"
    return $?
  fi
  [[ "$TARGET" == "$target" ]]
}

value_for_key() {
  local file="$1"
  local key="$2"
  local line
  line="$(grep -E "^${key}=" "$file" | tail -n 1 || true)"
  [[ -n "$line" ]] || return 1
  local value="${line#*=}"
  value="${value%$'\r'}"
  value="${value#\"}"
  value="${value%\"}"
  value="${value#\'}"
  value="${value%\'}"
  printf '%s' "$value"
}

is_placeholder_value() {
  local value="$1"
  local lower
  lower="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  [[ -z "$value" || "$lower" == todo* || "$lower" == *"todo:"* || "$lower" == *"<"* || "$lower" == *"待填写"* ]]
}

validation_errors=()
checked_reports=()
ok_reports=()

join_with_comma_space() {
  local joined=""
  local item
  for item in "$@"; do
    if [[ -z "$joined" ]]; then
      joined="$item"
    else
      joined="$joined, $item"
    fi
  done
  printf '%s' "$joined"
}

evidence_records_for_target() {
  local target="$1"
  case "$target" in
    remote-publish)
      printf '%s' '`github-direct-publish`, `github-review-publish`, `gitlab-direct-publish`, `gitlab-review-publish`'
      ;;
    remote-recovery)
      printf '%s' '`remote-conflict-deployment-rollback`'
      ;;
    storekit)
      printf '%s' '`storekit-sandbox`'
      ;;
    app-store-screenshots)
      printf '%s' '`app-store-screenshots`'
      ;;
    app-store-archive)
      printf '%s' 'clean Release archive, distribution signing/runtime, Transporter/App Store Connect validation'
      ;;
    *)
      printf '%s' 'No mapped external evidence item.'
      ;;
  esac
}

evidence_status_line() {
  local complete="$1"
  local label="$2"
  if [[ "$complete" == "1" ]]; then
    printf -- '- [x] %s\n' "$label"
  else
    printf -- '- [ ] %s\n' "$label"
  fi
}

external_evidence_status_line() {
  local item_id="$1"
  if external_item_complete "$item_id"; then
    evidence_status_line 1 "\`$item_id\`"
  else
    evidence_status_line 0 "\`$item_id\`"
  fi
}

archive_evidence_status_line() {
  local item_title="$1"
  if archive_item_complete "$item_title"; then
    evidence_status_line 1 "$item_title"
  else
    evidence_status_line 0 "$item_title"
  fi
}

evidence_status_lines_for_target() {
  local target="$1"
  case "$target" in
    remote-publish)
      external_evidence_status_line github-direct-publish
      external_evidence_status_line github-review-publish
      external_evidence_status_line gitlab-direct-publish
      external_evidence_status_line gitlab-review-publish
      ;;
    remote-recovery)
      external_evidence_status_line remote-conflict-deployment-rollback
      ;;
    storekit)
      external_evidence_status_line storekit-sandbox
      ;;
    app-store-screenshots)
      external_evidence_status_line app-store-screenshots
      ;;
    app-store-archive)
      archive_evidence_status_line "Clean Release archive produced from a clean checkout."
      archive_evidence_status_line "Distribution signing and hardened runtime verified on the archive."
      archive_evidence_status_line "Archive validated with App Store Connect or Transporter before upload."
      ;;
    *)
      printf -- '- [ ] No mapped evidence status.\n'
      ;;
  esac
}

for spec in "${env_specs[@]}"; do
  target="${spec%%:*}"
  rest="${spec#*:}"
  filename="${rest%%:*}"
  rest="${rest#*:}"
  template_path="${rest%%:*}"
  required_csv="${rest#*:}"

  should_check_target "$target" || continue
  checked_reports+=("$target|$filename|$required_csv")

  if [[ "$MODE" == "template" ]]; then
    file="$ROOT_DIR/$template_path"
  else
    file="$ENV_DIR/$filename"
  fi

  file_errors=0

  if [[ ! -f "$file" ]]; then
    validation_errors+=("$filename is missing")
    continue
  fi

  if [[ "$MODE" == "filled" ]]; then
    file_mode="$(stat -f "%Lp" "$file")"
    if [[ "$file_mode" != "600" ]]; then
      validation_errors+=("$filename mode is $file_mode, expected 600")
      file_errors=1
    fi
  fi

  IFS=',' read -r -a required_keys <<<"$required_csv"
  for key in "${required_keys[@]}"; do
    if ! value="$(value_for_key "$file" "$key")"; then
      validation_errors+=("$filename is missing required variable $key")
      file_errors=1
      continue
    fi
    if [[ "$MODE" == "filled" ]] && is_placeholder_value "$value"; then
      validation_errors+=("$filename has empty or placeholder value for $key")
      file_errors=1
    fi
  done

  if [[ "$MODE" == "filled" ]] && grep -Eq '(/Users/|/Volumes/|file:///Users/|file:///Volumes/|Authorization:[[:space:]]*Bearer)' "$file"; then
    validation_errors+=("$filename contains a local path or authorization header")
    file_errors=1
  fi

  if [[ "$file_errors" == "0" ]]; then
    echo "external verification env check: $filename ok"
    ok_reports+=("$target|$filename")
  fi
done

write_report() {
  [[ -n "$REPORT_FILE" ]] || return 0
  local report_dir
  report_dir="$(dirname "$REPORT_FILE")"
  mkdir -p "$report_dir"
  {
    echo "# External Verification Env Status"
    echo
    echo "- Mode: \`$MODE\`"
    echo "- Target: \`$TARGET\`"
    echo "- Env directory: \`$ENV_DIR\`"
    echo "- Checked targets: ${#checked_reports[@]}"
    echo "- Passing env files: ${#ok_reports[@]}"
    echo "- Issues: ${#validation_errors[@]}"
    echo
    echo "This report is redacted. It lists file names, target names, required variable names, and validation messages only."
    echo
    echo "## Required Fields"
    if [[ "${#checked_reports[@]}" -eq 0 ]]; then
      echo
      echo "- No env files were required for this target."
    else
      echo
      for row in "${checked_reports[@]}"; do
        IFS='|' read -r target filename required_csv <<<"$row"
        local formatted_keys=()
        IFS=',' read -r -a keys <<<"$required_csv"
        for key in "${keys[@]}"; do
          formatted_keys+=("\`$key\`")
        done
        local joined
        joined="$(join_with_comma_space "${formatted_keys[@]}")"
        echo "- \`$filename\` (\`$target\`): $joined"
      done
    fi
    echo
    echo "## Evidence Targets"
    if [[ "${#checked_reports[@]}" -eq 0 ]]; then
      echo
      echo "- No external evidence targets were required."
    else
      echo
      for row in "${checked_reports[@]}"; do
        IFS='|' read -r target filename required_csv <<<"$row"
        echo "- \`$target\` via \`$filename\`: $(evidence_records_for_target "$target")"
      done
    fi
    echo
    echo "## Evidence Completion"
    if [[ "${#checked_reports[@]}" -eq 0 ]]; then
      echo
      echo "- No external evidence targets were required."
    else
      echo
      for row in "${checked_reports[@]}"; do
        IFS='|' read -r target filename required_csv <<<"$row"
        echo "### \`$target\`"
        evidence_status_lines_for_target "$target"
        echo
      done
    fi
    echo
    echo "## Issues"
    if [[ "${#validation_errors[@]}" -eq 0 ]]; then
      echo
      echo "- None."
    else
      echo
      for error in "${validation_errors[@]}"; do
        echo "- $error"
      done
    fi
    echo
    echo "## Next Commands"
    echo
    echo '```sh'
    if [[ -n "$REPORT_FILE" ]]; then
      echo "script/check_external_verification_envs.sh --env-dir $ENV_DIR --mode filled --target $TARGET --report-file $REPORT_FILE"
      echo "script/run_external_verification_from_envs.sh --env-dir $ENV_DIR --target $TARGET --env-status-report-file $REPORT_FILE"
      echo "script/run_external_verification_from_envs.sh --env-dir $ENV_DIR --target $TARGET --env-status-report-file $REPORT_FILE --execute"
    else
      echo "script/check_external_verification_envs.sh --env-dir $ENV_DIR --mode filled --target $TARGET"
      echo "script/run_external_verification_from_envs.sh --env-dir $ENV_DIR --target $TARGET"
      echo "script/run_external_verification_from_envs.sh --env-dir $ENV_DIR --target $TARGET --execute"
    fi
    echo '```'
  } >"$REPORT_FILE"
  chmod 600 "$REPORT_FILE"
  echo "external verification env check: wrote redacted report $REPORT_FILE"
}

if [[ "${#validation_errors[@]}" -gt 0 ]]; then
  write_report
  echo "external verification env check: found ${#validation_errors[@]} issue(s):" >&2
  printf '  - %s\n' "${validation_errors[@]}" >&2
  exit 1
fi

write_report
echo "external verification env check: $MODE mode passed for target $TARGET"
