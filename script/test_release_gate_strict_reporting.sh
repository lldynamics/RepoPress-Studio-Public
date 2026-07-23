#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-release-gate-strict.XXXXXX)"
FIXTURE_ROOT="$TMP_DIR/project"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "release gate strict reporting test: $*" >&2
  exit 1
}

mkdir -p "$FIXTURE_ROOT/script" "$FIXTURE_ROOT/bin"
cp "$ROOT_DIR/script/check_release_gate.sh" "$FIXTURE_ROOT/script/check_release_gate.sh"
cp "$ROOT_DIR/script/release_gate_runner.py" "$FIXTURE_ROOT/script/release_gate_runner.py"
cp "$ROOT_DIR/script/release_checks.json" "$FIXTURE_ROOT/script/release_checks.json"

cat >"$FIXTURE_ROOT/script/package_direct_release.py" <<'PY'
#!/usr/bin/env python3
import os
import sys

if sys.argv[1:] != ["--check-readiness"]:
    raise SystemExit("unexpected direct release fixture arguments")
if os.environ.get("FAIL_DIRECT_READINESS") == "1":
    raise SystemExit("direct release fixture: intentional failure")
print("direct release fixture: ok")
PY

cat >"$FIXTURE_ROOT/script/chromium_extension_release.py" <<'PY'
#!/usr/bin/env python3
import os
import sys

arguments = sys.argv[1:]
if arguments == ["readiness", "--channel", "chrome"] and os.environ.get("FAIL_CHROME_ID") == "1":
    raise SystemExit("Chrome production ID fixture: intentional failure")
print("Chromium release fixture: ok")
PY

for python_script in \
  check_app_store_listing_metadata.py \
  test_app_store_listing_metadata.py \
  test_browser_extension_protocol_generation.py \
  test_chromium_extension_release.py \
  test_direct_release_notarization.py \
  check_typography.py \
  test_typography_gate.py; do
  cat >"$FIXTURE_ROOT/script/$python_script" <<'PY'
#!/usr/bin/env python3
print("App Store listing fixture: ok")
PY
done

stub_scripts=(
  check_browser_extension_release.sh
  check_localization_gate.sh
  check_repository_source_boundary.sh
  test_repository_source_boundary.sh
  check_build_version.sh
  test_build_version_gate.sh
  check_app_store_metadata.sh
  package_app_store.sh
  test_package_app_store_safety.sh
  record_app_store_build_metadata_evidence.sh
  test_app_store_build_metadata_evidence.sh
  record_app_store_archive_validation_evidence.sh
  test_app_store_archive_validation_evidence.sh
  test_app_store_archive_artifact_selection.sh
  check_ui_runtime.sh
  check_accessibility_runtime.sh
  check_clean_runtime_evidence.sh
  record_clean_runtime_evidence.sh
  test_clean_runtime_evidence.sh
  check_privacy_support_copy.sh
  test_privacy_support_copy.sh
  check_storekit.sh
  record_storekit_sandbox_evidence.sh
  test_storekit_sandbox_evidence.sh
  prepare_external_verification_envs.sh
  check_external_verification_envs.sh
  print_remaining_external_verification.sh
  run_external_verification_from_envs.sh
  test_external_verification_env_prep.sh
  test_external_verification_env_check.sh
  test_external_verification_env_runner.sh
  test_remaining_external_verification_summary.sh
  export_release_evidence_bundle.sh
  test_release_evidence_bundle_export.sh
  record_external_verification_evidence.sh
  record_remote_recovery_evidence.sh
  test_remote_publish_live_verifier.sh
  verify_remote_publish_live_matrix.sh
  test_remote_publish_live_matrix.sh
  test_remote_recovery_evidence.sh
  test_external_verification_evidence.sh
  check_screenshot_surface_map.sh
  test_screenshot_surface_map.sh
  check_app_store_screenshot_capture_readiness.sh
  test_app_store_screenshot_capture_readiness.sh
  record_app_store_screenshot_evidence.sh
  test_app_store_screenshot_evidence.sh
  test_screenshot_manifest_sync.sh
  test_screenshot_specifications.sh
  test_screenshot_privacy.sh
  test_app_store_checklist_sync_evidence.sh
  test_browser_extension_release_gate.sh
  test_release_gate_strict_reporting.sh
  check_ci_quality_workflow.sh
  check_swift_strict_build.sh
  test_swift_strict_build_gate.sh
  check_swift_release_build.sh
  test_swift_release_build_gate.sh
  sync_screenshot_manifest_status.sh
  sync_app_store_checklist.sh
  check_screenshot_privacy.sh
)

for script_name in "${stub_scripts[@]}"; do
  cat >"$FIXTURE_ROOT/script/$script_name" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "${0##*/}: ok"
STUB
done

cat >"$FIXTURE_ROOT/script/check_ui_runtime.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${PROFILE_LOG:-}" ]]; then
  printf 'ui-runtime\t%s\t%s\n' "${RELEASE_GATE_PROFILE:-missing}" "${1:-}" >>"$PROFILE_LOG"
fi
STUB

cat >"$FIXTURE_ROOT/script/check_accessibility_runtime.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${PROFILE_LOG:-}" ]]; then
  printf 'accessibility-runtime\t%s\n' "${RELEASE_GATE_PROFILE:-missing}" >>"$PROFILE_LOG"
fi
STUB

cat >"$FIXTURE_ROOT/script/check_app_store_archive_readiness.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--strict" ]]; then
  echo "archive strict failed" >&2
  exit 1
fi
echo "archive readiness: ok"
STUB

cat >"$FIXTURE_ROOT/script/check_screenshots.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${STRICT_SCREENSHOTS:-0}" == "1" ]]; then
  echo "screenshot strict failed" >&2
  exit 1
fi
echo "screenshots: ok"
STUB

cat >"$FIXTURE_ROOT/script/check_external_verification_evidence.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${STRICT_EXTERNAL_VERIFICATION:-0}" == "1" ]]; then
  echo "external strict failed" >&2
  exit 1
fi
echo "external verification: ok"
STUB

cat >"$FIXTURE_ROOT/script/print_remaining_external_verification.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "remaining external verification: 2 target(s)"
echo "- remote-publish"
echo "  checklist: Verify GitHub direct commit and PR publishing with a least-privilege token; Verify GitLab direct commit and MR publishing with a least-privilege token."
echo "- storekit"
echo "  checklist: Verify StoreKit product ID, purchase, restore, and free quota behavior in sandbox."
STUB

cat >"$FIXTURE_ROOT/bin/swift" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  test)
    echo "swift test: ok"
    ;;
  run)
    echo "swift release tooling: ok"
    ;;
  *)
    exit 1
    ;;
esac
STUB
chmod +x "$FIXTURE_ROOT/bin/swift"

cat >"$FIXTURE_ROOT/APP_STORE_CHECKLIST.md" <<'MD'
# App Store Release Checklist

- [ ] Capture screenshots.
- [ ] Verify external evidence.
MD

if output="$(
  PROFILE_LOG="$TMP_DIR/profile.log" \
    PATH="$FIXTURE_ROOT/bin:$PATH" \
    bash "$FIXTURE_ROOT/script/check_release_gate.sh" --strict 2>&1
)"; then
  fail "strict release gate fixture unexpectedly passed"
fi

grep -q $'^ui-runtime\tall\t--package-only$' "$TMP_DIR/profile.log" \
  || fail "strict gate did not propagate the all profile to packaged UI verification"
grep -q $'^ui-runtime\tall\t--launch$' "$TMP_DIR/profile.log" \
  || fail "strict gate did not propagate the all profile to launch verification"
grep -q $'^accessibility-runtime\tall$' "$TMP_DIR/profile.log" \
  || fail "strict gate did not propagate the all profile to accessibility verification"

grep -q "release gate: strict mode has 4 blocker(s):" <<<"$output" \
  || fail "strict output did not summarize all blockers"
grep -q "App Store archive readiness" <<<"$output" \
  || fail "strict output missed archive blocker"
grep -q "App Store screenshots" <<<"$output" \
  || fail "strict output missed screenshot blocker"
grep -q "external verification evidence" <<<"$output" \
  || fail "strict output missed external evidence blocker"
grep -q "APP_STORE_CHECKLIST.md (2 unchecked items)" <<<"$output" \
  || fail "strict output missed checklist blocker"
grep -q "release gate: remaining external verification targets:" <<<"$output" \
  || fail "strict output omitted remaining target heading"
grep -q "remaining external verification: 2 target(s)" <<<"$output" \
  || fail "strict output omitted remaining target summary"
grep -q -- "- remote-publish" <<<"$output" \
  || fail "strict output omitted remote-publish target"
grep -q "release gate: rerun after recording evidence:" <<<"$output" \
  || fail "strict output omitted rerun heading"
grep -q "./script/check_release_gate.sh --strict" <<<"$output" \
  || fail "strict output omitted strict rerun command"
grep -q "swift test: ok" <<<"$output" \
  || fail "strict gate did not continue through Swift tests before reporting blockers"
python3 - "$FIXTURE_ROOT/.build/release-gate-result.json" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["mode"] == "strict", payload
assert payload["profile"] == "all", payload
PY

chrome_json="$TMP_DIR/chrome-profile.json"
if ! chrome_output="$(
  PATH="$FIXTURE_ROOT/bin:$PATH" \
  FAIL_DIRECT_READINESS=1 \
  bash "$FIXTURE_ROOT/script/check_release_gate.sh" \
    --profile chrome \
    --result-json "$chrome_json" 2>&1
)"; then
  fail "Chrome profile was blocked by another distribution channel: $chrome_output"
fi
grep -q "release gate: chrome profile passed" <<<"$chrome_output" \
  || fail "Chrome profile did not report its independent success"
python3 - "$chrome_json" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["mode"] == "strict", payload
assert payload["profile"] == "chrome", payload
assert payload["summary"]["uncheckedChecklistCount"] == 0, payload
check_ids = {check["id"] for check in payload["checks"]}
assert "chrome-extension-store-readiness" in check_ids, payload
assert "edge-extension-store-readiness" not in check_ids, payload
assert "firefox-extension-remote-release" not in check_ids, payload
assert "direct-release-notarization-readiness" not in check_ids, payload
assert "archive-readiness-strict" not in check_ids, payload
PY

for script_name in check_app_store_archive_readiness.sh check_screenshots.sh check_external_verification_evidence.sh; do
  cat >"$FIXTURE_ROOT/script/$script_name" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "${0##*/}: ok"
STUB
done
checklist_only_json="$TMP_DIR/checklist-only.json"
if checklist_output="$(PATH="$FIXTURE_ROOT/bin:$PATH" bash "$FIXTURE_ROOT/script/check_release_gate.sh" \
  --strict --result-json "$checklist_only_json" 2>&1)"; then
  fail "strict release gate passed despite unchecked checklist items"
fi
python3 - "$checklist_only_json" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["summary"]["status"] == "failed", payload
assert payload["summary"]["uncheckedChecklistCount"] == 2, payload
assert payload["summary"]["blockerCount"] == 1, payload
assert payload["blockers"] == ["APP_STORE_CHECKLIST.md (2 unchecked items)"], payload
PY

for script_name in check_localization_gate.sh check_build_version.sh; do
  cat >"$FIXTURE_ROOT/script/$script_name" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "${0##*/}: intentional failure" >&2
exit 1
STUB
done
if selected_output="$(PATH="$FIXTURE_ROOT/bin:$PATH" bash "$FIXTURE_ROOT/script/check_release_gate.sh" \
  --check localization --check build-version 2>&1)"; then
  fail "selected release gate fixture unexpectedly passed"
fi
grep -q "release gate: selected mode has 2 failure(s):" <<<"$selected_output" \
  || fail "selected output did not aggregate both failures"
grep -q "Localization coverage" <<<"$selected_output" \
  || fail "selected output omitted localization failure"
grep -q "Single-source build version" <<<"$selected_output" \
  || fail "selected output omitted build-version failure"

echo "release gate strict reporting test: passed"
