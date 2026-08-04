#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPORTER="$ROOT_DIR/script/export_release_evidence_bundle.sh"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-release-evidence-export.XXXXXX)"
OUTPUT="$TMP_DIR/LOCAL_RELEASE_EVIDENCE.md"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "release evidence bundle export test: $*" >&2
  exit 1
}

[[ -f "$EXPORTER" ]] || fail "export_release_evidence_bundle.sh is missing"

required_templates=(
  "docs/release-evidence/app-store-archive-validation.env.example"
  "docs/release-evidence/app-store-screenshots.env.example"
  "docs/release-evidence/remote-publish-live.env.example"
  "docs/release-evidence/remote-recovery.env.example"
)
required_scripts=(
  "script/record_app_store_build_metadata_evidence.sh"
  "script/test_app_store_build_metadata_evidence.sh"
  "script/prepare_external_verification_envs.sh"
  "script/check_external_verification_envs.sh"
  "script/print_remaining_external_verification.sh"
  "script/run_external_verification_from_envs.sh"
  "script/test_external_verification_env_prep.sh"
  "script/test_external_verification_env_check.sh"
  "script/test_external_verification_env_runner.sh"
  "script/test_remaining_external_verification_summary.sh"
)

script_text="$(cat "$EXPORTER")"
[[ "$script_text" == *"docs/release-evidence/snapshots/LOCAL_RELEASE_EVIDENCE-"* ]] \
  || fail "exporter default output must be a timestamped snapshot"
[[ "$script_text" == *"This file is an index for generated local release evidence snapshots."* ]] \
  || fail "exporter must keep LOCAL_RELEASE_EVIDENCE.md as an index, not a stale pass bundle"
for template in "${required_templates[@]}"; do
  [[ -f "$ROOT_DIR/$template" ]] || fail "required env template is missing: $template"
  [[ "$script_text" == *"\"$template\""* ]] || fail "exporter required_files omit $template"
done
for script in "${required_scripts[@]}"; do
  [[ -f "$ROOT_DIR/$script" ]] || fail "required env prep script is missing: $script"
  [[ "$script_text" == *"\"$script\""* ]] || fail "exporter required_files omit $script"
done

dry_output="$(bash "$EXPORTER" --output "$OUTPUT" --dry-run)"
grep -q "release evidence export: ready to write" <<<"$dry_output" \
  || fail "dry-run did not report ready output"

bash "$EXPORTER" --output "$OUTPUT" >/dev/null

[[ -f "$OUTPUT" ]] || fail "exporter did not create output bundle"
bundle_text="$(cat "$OUTPUT")"
grep -q "# Local Release Evidence Bundle" "$OUTPUT" || fail "bundle heading missing"
grep -q "Evidence Files To Complete" "$OUTPUT" || fail "evidence completion section missing"
for template in "${required_templates[@]}"; do
  [[ "$bundle_text" == *"\`$template\`"* ]] || fail "bundle output omits $template"
done
[[ "$bundle_text" == *"\`script/prepare_external_verification_envs.sh\`"* ]] \
  || fail "bundle output omits private env prep script"
[[ "$bundle_text" == *"\`script/record_app_store_build_metadata_evidence.sh\`"* ]] \
  || fail "bundle output omits build metadata evidence script"
[[ "$bundle_text" == *"\`docs/release-evidence/APP_STORE_BUILD_METADATA.md\`"* ]] \
  || fail "bundle output omits build metadata evidence file"
[[ "$bundle_text" == *"\`script/check_external_verification_envs.sh\`"* ]] \
  || fail "bundle output omits private env check script"
[[ "$bundle_text" == *"\`script/print_remaining_external_verification.sh\`"* ]] \
  || fail "bundle output omits remaining external verification summary script"
[[ "$bundle_text" == *"\`script/run_external_verification_from_envs.sh\`"* ]] \
  || fail "bundle output omits private env runner script"
grep -q "External verification evidence:" "$OUTPUT" || fail "external evidence summary missing"
grep -q "App Store archive validation:" "$OUTPUT" || fail "archive validation summary missing"

echo "release evidence bundle export test: passed"
