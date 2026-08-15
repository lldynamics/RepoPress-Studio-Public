#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/quality.yml"
TOOLING_WORKFLOW="$ROOT_DIR/.github/workflows/tooling.yml"
CHECKOUT_ACTION="actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803"
UPLOAD_ARTIFACT_ACTION="actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02"

fail() {
  echo "CI quality workflow gate: $*" >&2
  exit 1
}

[[ -f "$WORKFLOW" ]] || fail "missing .github/workflows/quality.yml"
[[ -f "$TOOLING_WORKFLOW" ]] || fail "missing .github/workflows/tooling.yml"
grep -Eq '^[[:space:]]*push:' "$WORKFLOW" || fail "quality workflow must run on pushes"
grep -Fq -- '- main' "$WORKFLOW" || fail "quality workflow push trigger must be limited to main"
if grep -Eq '^[[:space:]]*push:' "$TOOLING_WORKFLOW"; then
  fail "path-heavy release tooling must not run on every push"
fi
grep -Eq '^[[:space:]]*pull_request:' "$WORKFLOW" || fail "workflow must run on pull requests"
grep -Eq '^[[:space:]]*workflow_dispatch:' "$WORKFLOW" || fail "workflow must support manual runs"
grep -Fq 'contents: read' "$WORKFLOW" || fail "workflow token permissions must be read-only"
grep -Fq 'contents: read' "$TOOLING_WORKFLOW" \
  || fail "release-tooling workflow token permissions must be read-only"
grep -Fq 'DEVELOPER_DIR: /Applications/Xcode_26.3.app/Contents/Developer' "$TOOLING_WORKFLOW" \
  || fail "release-tooling workflow must select the Xcode 26.3 Safari extension toolchain"
grep -Fq 'DEVELOPER_DIR: /Applications/Xcode_26.3.app/Contents/Developer' \
  < <(sed -n '/name: Exercise distribution build and package path/,/name: Publish quality summary/p' "$WORKFLOW") \
  || fail "pull-request distribution gate must select the Xcode 26.3 Safari extension toolchain"
grep -Fq 'echo "PLAYWRIGHT_BROWSERS_PATH=$RUNNER_TEMP/ms-playwright" >> "$GITHUB_ENV"' "$TOOLING_WORKFLOW" \
  || fail "release-tooling workflow must share one Playwright browser path across install and gates"
grep -Fq 'xcrun -f safari-web-extension-packager' "$TOOLING_WORKFLOW" \
  || fail "release-tooling workflow must verify the Safari extension packager before running gates"
grep -Fq 'xcrun -f safari-web-extension-packager' \
  < <(sed -n '/name: Exercise distribution build and package path/,/name: Publish quality summary/p' "$WORKFLOW") \
  || fail "pull-request distribution gate must verify the Safari extension packager before running"
for workflow_path in "$WORKFLOW" "$TOOLING_WORKFLOW"; do
  grep -Fq "uses: $CHECKOUT_ACTION" "$workflow_path" \
    || fail "$(basename "$workflow_path") must pin actions/checkout to the approved commit"
  grep -Fq "uses: $UPLOAD_ARTIFACT_ACTION" "$workflow_path" \
    || fail "$(basename "$workflow_path") must pin actions/upload-artifact to the approved commit"
  while IFS= read -r uses_line; do
    [[ "$uses_line" =~ @[0-9a-f]{40}([[:space:]]+#[[:space:]]*.*)?$ ]] \
      || fail "$(basename "$workflow_path") contains an unpinned third-party action: $uses_line"
  done < <(grep -E 'uses:[[:space:]]+[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@' "$workflow_path" || true)
done
grep -Fq 'runs-on: macos-15' "$WORKFLOW" || fail "workflow must use a macOS runner"
grep -Fq 'timeout-minutes:' "$WORKFLOW" || fail "workflow must have a job timeout"
grep -Fq './script/check_release_gate.sh' "$WORKFLOW" \
  || fail "workflow must invoke the shared release gate"
grep -Fq "if: github.event_name == 'push'" "$WORKFLOW" \
  || fail "main pushes must use a dedicated quick-only job"
grep -Fq "if: github.event_name != 'push'" "$WORKFLOW" \
  || fail "distribution and UI jobs must not run on main pushes"
for deterministic_language_setting in \
  'name: Configure deterministic test language' \
  'defaults write NSGlobalDomain AppleLanguages -array "zh-Hans"' \
  'defaults write NSGlobalDomain AppleLocale "zh_CN"'; do
  setting_count="$(grep -Fc "$deterministic_language_setting" "$WORKFLOW" || true)"
  [[ "$setting_count" -eq 2 ]] \
    || fail "main-push and pull-request quality jobs must both configure deterministic Simplified Chinese tests"
done
grep -Fq -- '--quick' "$WORKFLOW" \
  || fail "workflow must run the shared quick gate"
grep -Fq -- '--check swift-coverage' "$WORKFLOW" \
  || fail "pull requests must enforce the measured Swift coverage baseline"
grep -Fq 'bash script/check_swift6_migration.sh' "$WORKFLOW" \
  || fail "workflow must run a real Swift 6 language-mode migration diagnostic"
if grep -Fq 'continue-on-error: true' "$WORKFLOW"; then
  fail "the Swift 6 migration diagnostic must be blocking"
fi
grep -Fq -- '--summary-markdown .build/quality-gate-summary.md' "$WORKFLOW" \
  || fail "quality workflow must produce a readable quick-gate summary"
grep -Fq -- '--summary-markdown .build/distribution-gate-summary.md' "$WORKFLOW" \
  || fail "quality workflow must produce a readable distribution summary"
grep -Fq 'GITHUB_STEP_SUMMARY' "$WORKFLOW" \
  || fail "quality workflow must publish its readable summary"
swift_test_artifact_count="$(grep -Fc '.build/swift-test-shards/' "$WORKFLOW" || true)"
[[ "$swift_test_artifact_count" -eq 2 ]] \
  || fail "main-push and pull-request quality artifacts must both retain Swift test shard diagnostics"
grep -Fq 'bash script/check_ui_runtime.sh --launch' "$WORKFLOW" \
  || fail "quality workflow must verify a real visible Release app launch"
grep -Fq 'WORKBENCH_XCUI_APP_PATH="$PWD/dist/PersonalSitePublisherMac.app"' "$WORKFLOW" \
  || fail "quality workflow must reuse the verified Release app for UI smoke"
grep -Fq 'env -u RELEASE_GATE_PROFILE bash script/check_accessibility_runtime.sh' "$WORKFLOW" \
  || fail "quality workflow must preserve the complete isolated accessibility suite"
grep -Fq 'name: ui-smoke-result' "$WORKFLOW" \
  || fail "quality workflow must retain UI smoke logs and test evidence"
for release_check in ui-runtime swift-release-build; do
  grep -Fq -- "--check $release_check" "$WORKFLOW" \
    || fail "workflow must exercise distribution check: $release_check"
done
for dependency_path in \
  "Sources/PublishingWorkbenchCore/Models/**" \
  Sources/PublishingWorkbenchCore/Services/KeychainTokenStore.swift; do
  grep -Fq "$dependency_path" "$TOOLING_WORKFLOW" \
    || fail "release-tooling workflow must watch browser dependency: $dependency_path"
done
grep -Fq -- '--summary-markdown .build/browser-extension-gate-summary.md' "$TOOLING_WORKFLOW" \
  || fail "release-tooling workflow must summarize the browser extension gate"
grep -Fq -- '--summary-markdown .build/tooling-gate-summary.md' "$TOOLING_WORKFLOW" \
  || fail "release-tooling workflow must summarize tooling self-tests"
grep -Fq 'npm ci --ignore-scripts' "$TOOLING_WORKFLOW" \
  || fail "release-tooling workflow must disable dependency lifecycle scripts"
grep -Fq 'python3 script/check_node_toolchain_security.py' "$TOOLING_WORKFLOW" \
  || fail "release-tooling workflow must reject retired Firefox dependency residue"
grep -Fq 'python3 script/test_node_toolchain_security.py' "$TOOLING_WORKFLOW" \
  || fail "release-tooling workflow must run Node security gate regressions"
grep -Fq 'npm audit --audit-level=high --omit=optional' "$TOOLING_WORKFLOW" \
  || fail "release-tooling workflow must reject high-severity npm advisories"
grep -Fq 'GITHUB_STEP_SUMMARY' "$TOOLING_WORKFLOW" \
  || fail "release-tooling workflow must publish its readable summary"

if grep -Eq '(github_pat_|ghp_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|Authorization:[[:space:]]*Bearer)' \
  "$WORKFLOW" "$TOOLING_WORKFLOW"; then
  fail "workflow contains token-like content"
fi

echo "CI quality workflow gate: main push quick path, pull-request coverage/distribution/UI path, blocking Swift 6 diagnostic, pinned actions, read-only permissions, summaries, and distribution evidence verified"
