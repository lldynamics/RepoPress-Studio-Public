#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATED_AT="$(date -u +"%Y-%m-%dT%H%M%SZ")"
DEFAULT_OUTPUT="$ROOT_DIR/docs/release-evidence/snapshots/LOCAL_RELEASE_EVIDENCE-$GENERATED_AT.md"
OUTPUT="$DEFAULT_OUTPUT"
DRY_RUN=0
INCLUDE_TESTS=0

usage() {
  cat <<'USAGE'
Usage: script/export_release_evidence_bundle.sh [--output <path>] [--include-tests] [--dry-run]

Exports a redacted local release evidence bundle. This summarizes local gates,
known strict-release gaps, screenshot manifest status, external evidence status,
and App Store checklist progress. It does not mark external GitHub/GitLab,
StoreKit sandbox, or screenshot evidence as complete.

Options:
  --output <path>   Write the bundle to a custom path. Defaults to a timestamped snapshot under docs/release-evidence/snapshots/.
  --include-tests   Also run `swift test --disable-sandbox` and include output.
  --dry-run         Validate inputs and print the planned output path only.
USAGE
}

fail() {
  echo "release evidence export: $*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --output)
      [[ "$#" -ge 2 ]] || fail "--output requires a path"
      OUTPUT="$2"
      shift 2
      ;;
    --include-tests)
      INCLUDE_TESTS=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
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

required_files=(
  "script/check_localization_gate.sh"
  "script/check_app_store_metadata.sh"
  "script/check_app_store_archive_readiness.sh"
  "script/record_app_store_build_metadata_evidence.sh"
  "script/test_app_store_build_metadata_evidence.sh"
  "script/check_ui_runtime.sh"
  "script/check_clean_runtime_evidence.sh"
  "script/record_clean_runtime_evidence.sh"
  "script/test_clean_runtime_evidence.sh"
  "script/check_privacy_support_copy.sh"
  "script/test_privacy_support_copy.sh"
  "script/check_storekit.sh"
  "script/record_storekit_sandbox_evidence.sh"
  "script/test_storekit_sandbox_evidence.sh"
  "script/prepare_external_verification_envs.sh"
  "script/check_external_verification_envs.sh"
  "script/print_remaining_external_verification.sh"
  "script/run_external_verification_from_envs.sh"
  "script/test_external_verification_env_prep.sh"
  "script/test_external_verification_env_check.sh"
  "script/test_external_verification_env_runner.sh"
  "script/test_remaining_external_verification_summary.sh"
  "script/check_screenshots.sh"
  "script/check_external_verification_evidence.sh"
  "script/verify_remote_publish_live.sh"
  "script/test_remote_publish_live_verifier.sh"
  "script/verify_remote_publish_live_matrix.sh"
  "script/test_remote_publish_live_matrix.sh"
  "script/record_external_verification_evidence.sh"
  "script/record_remote_recovery_evidence.sh"
  "script/test_remote_recovery_evidence.sh"
  "script/check_screenshot_surface_map.sh"
  "script/test_screenshot_surface_map.sh"
  "script/sync_app_store_checklist.sh"
  "script/check_screenshot_privacy.sh"
  "script/test_screenshot_privacy.sh"
  "docs/privacy-support-copy.md"
  "docs/release-evidence/CLEAN_RUNTIME_VALIDATION.md"
  "docs/release-evidence/APP_STORE_BUILD_METADATA.md"
  "docs/app-store-screenshots/SCREENSHOT_MANIFEST.md"
  "docs/release-evidence/APP_STORE_ARCHIVE_VALIDATION.md"
  "docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md"
  "docs/release-evidence/app-store-archive-validation.env.example"
  "docs/release-evidence/app-store-screenshots.env.example"
  "docs/release-evidence/remote-publish-live.env.example"
  "docs/release-evidence/remote-recovery.env.example"
  "docs/release-evidence/storekit-sandbox.env.example"
  "APP_STORE_CHECKLIST.md"
)

missing_files=()
for file in "${required_files[@]}"; do
  [[ -f "$ROOT_DIR/$file" ]] || missing_files+=("$file")
done
[[ "${#missing_files[@]}" -eq 0 ]] || fail "missing required file(s): ${missing_files[*]}"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "release evidence export: ready to write ${OUTPUT#$ROOT_DIR/}"
  exit 0
fi

mkdir -p "$(dirname "$OUTPUT")"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/release-evidence.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

run_check() {
  local name="$1"
  shift
  local output_file="$TMP_DIR/${name}.log"
  set +e
  (cd "$ROOT_DIR" && "$@") >"$output_file" 2>&1
  local status=$?
  set -e
  echo "$status" >"$TMP_DIR/${name}.status"
}

run_check localization bash script/check_localization_gate.sh
run_check app_store_metadata bash script/check_app_store_metadata.sh
run_check app_store_archive_readiness bash script/check_app_store_archive_readiness.sh
run_check ui_runtime bash script/check_ui_runtime.sh
run_check clean_runtime_evidence bash script/check_clean_runtime_evidence.sh
run_check privacy_support_copy bash script/check_privacy_support_copy.sh
run_check storekit bash script/check_storekit.sh
run_check screenshot_surface_map bash script/check_screenshot_surface_map.sh
run_check screenshots bash script/check_screenshots.sh
run_check external_verification bash script/check_external_verification_evidence.sh
run_check screenshot_privacy bash script/check_screenshot_privacy.sh
if [[ "$INCLUDE_TESTS" == "1" ]]; then
  run_check swift_tests swift test --disable-sandbox
fi

unchecked_checklist_count="$(grep -c '^- \[ \]' "$ROOT_DIR/APP_STORE_CHECKLIST.md" || true)"
unchecked_archive_validation_count="$(grep -c '^- \[ \]' "$ROOT_DIR/docs/release-evidence/APP_STORE_ARCHIVE_VALIDATION.md" || true)"
unchecked_clean_runtime_count="$(grep -c '^- \[ \]' "$ROOT_DIR/docs/release-evidence/CLEAN_RUNTIME_VALIDATION.md" || true)"
screenshot_count="$(find "$ROOT_DIR/docs/app-store-screenshots" -maxdepth 1 -type f \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' \) | wc -l | tr -d ' ')"
external_completed_count="$(grep -Ec '^- \[[xX]\][[:space:]]+`' "$ROOT_DIR/docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md" || true)"
generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

check_section() {
  local name="$1"
  local title="$2"
  local command="$3"
  local status
  status="$(cat "$TMP_DIR/${name}.status")"
  {
    echo "### $title"
    echo
    echo "- Command: \`$command\`"
    echo "- Exit code: $status"
    echo
    echo '```text'
    sed -E \
      -e 's#(/Users|/Volumes)/[^[:space:]]+#<redacted-local-path>#g' \
      -e 's#(github_pat_|ghp_|glpat-|sk-)[A-Za-z0-9_-]{8,}#<redacted-token>#g' \
      -e 's#Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._-]+#Authorization: Bearer <redacted>#g' \
      "$TMP_DIR/${name}.log"
    echo '```'
    echo
  }
}

{
  echo "# Local Release Evidence Bundle"
  echo
  echo "- Generated at: $generated_at"
  echo "- Scope: local automated evidence only"
  echo "- Privacy: command output is redacted for local paths and token-like strings"
  echo
  echo "## Current Strict-Release Gaps"
  echo
  echo "- Screenshot images: $screenshot_count/9 captured"
  echo "- External verification evidence: $external_completed_count/7 completed"
  echo "- App Store archive validation: $unchecked_archive_validation_count unchecked item(s)"
  echo "- Clean runtime validation: $unchecked_clean_runtime_count unchecked item(s)"
  echo "- App Store checklist: $unchecked_checklist_count unchecked item(s)"
  echo "- Final strict command: \`./script/check_release_gate.sh --strict\`"
  echo
  echo "This bundle does not replace the required live GitHub/GitLab, StoreKit sandbox, screenshot, or App Store upload validation evidence."
  echo
  echo "## Local Gate Outputs"
  echo
  check_section localization "Localization Gate" "bash script/check_localization_gate.sh"
  check_section app_store_metadata "App Store Metadata Gate" "bash script/check_app_store_metadata.sh"
  check_section app_store_archive_readiness "App Store Archive Readiness Gate" "bash script/check_app_store_archive_readiness.sh"
  check_section ui_runtime "UI Runtime Gate" "bash script/check_ui_runtime.sh"
  check_section clean_runtime_evidence "Clean Runtime Evidence Gate" "bash script/check_clean_runtime_evidence.sh"
  check_section privacy_support_copy "Privacy Support Copy Gate" "bash script/check_privacy_support_copy.sh"
  check_section storekit "StoreKit Static Gate" "bash script/check_storekit.sh"
  check_section screenshot_surface_map "Screenshot Surface Map Gate" "bash script/check_screenshot_surface_map.sh"
  check_section screenshots "Screenshot Manifest Gate" "bash script/check_screenshots.sh"
  check_section external_verification "External Verification Template Gate" "bash script/check_external_verification_evidence.sh"
  check_section screenshot_privacy "Screenshot Privacy Gate" "bash script/check_screenshot_privacy.sh"
  if [[ "$INCLUDE_TESTS" == "1" ]]; then
    check_section swift_tests "Swift Tests" "swift test --disable-sandbox"
  fi
  echo "## Evidence Files To Complete"
  echo
  echo "- \`docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md\`"
  echo "- \`docs/release-evidence/APP_STORE_BUILD_METADATA.md\`"
  echo "- \`script/record_app_store_build_metadata_evidence.sh\`"
  echo "- \`script/prepare_external_verification_envs.sh\`"
  echo "- \`script/check_external_verification_envs.sh\`"
  echo "- \`script/print_remaining_external_verification.sh\`"
  echo "- \`script/run_external_verification_from_envs.sh\`"
  echo "- \`script/verify_remote_publish_live.sh\`"
  echo "- \`script/verify_remote_publish_live_matrix.sh\`"
  echo "- \`docs/release-evidence/remote-publish-live.env.example\`"
  echo "- \`script/record_external_verification_evidence.sh\`"
  echo "- \`docs/release-evidence/remote-recovery.env.example\`"
  echo "- \`docs/release-evidence/storekit-sandbox.env.example\`"
  echo "- \`docs/release-evidence/app-store-screenshots.env.example\`"
  echo "- \`script/sync_app_store_checklist.sh\`"
  echo "- \`docs/release-evidence/APP_STORE_ARCHIVE_VALIDATION.md\`"
  echo "- \`docs/release-evidence/app-store-archive-validation.env.example\`"
  echo "- \`docs/release-evidence/CLEAN_RUNTIME_VALIDATION.md\`"
  echo "- \`docs/app-store-screenshots/SCREENSHOT_MANIFEST.md\`"
  echo "- \`APP_STORE_CHECKLIST.md\`"
} >"$OUTPUT"

if [[ "$OUTPUT" == "$DEFAULT_OUTPUT" ]]; then
  index_path="$ROOT_DIR/docs/release-evidence/LOCAL_RELEASE_EVIDENCE.md"
  snapshot_relative="${OUTPUT#$ROOT_DIR/}"
  {
    echo "# Local Release Evidence Bundle"
    echo
    echo "This file is an index for generated local release evidence snapshots. It is not proof that the current tree passes release gates."
    echo
    echo "- Latest generated snapshot: \`$snapshot_relative\`"
    echo "- Snapshot generated at: $generated_at"
    echo "- Refresh command: \`script/export_release_evidence_bundle.sh\`"
    echo
    echo "Generated snapshots include each local gate command and its exit code. If a gate fails, the snapshot records that failure instead of preserving stale pass text."
  } >"$index_path"
fi

echo "release evidence export: wrote ${OUTPUT#$ROOT_DIR/}"
