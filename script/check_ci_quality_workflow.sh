#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/quality.yml"
TOOLING_WORKFLOW="$ROOT_DIR/.github/workflows/tooling.yml"
ACCESSIBILITY_RUNTIME_GATE="$ROOT_DIR/script/check_accessibility_runtime.sh"
CHECKOUT_ACTION="actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803"
UPLOAD_ARTIFACT_ACTION="actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02"

fail() {
  echo "CI quality workflow gate: $*" >&2
  exit 1
}

[[ -f "$WORKFLOW" ]] || fail "missing .github/workflows/quality.yml"
[[ -f "$TOOLING_WORKFLOW" ]] || fail "missing .github/workflows/tooling.yml"
[[ -f "$ACCESSIBILITY_RUNTIME_GATE" ]] || fail "missing script/check_accessibility_runtime.sh"
grep -Eq '^[[:space:]]*push:' "$WORKFLOW" || fail "quality workflow must run on pushes"
grep -Fq -- '- main' "$WORKFLOW" || fail "quality workflow push trigger must be limited to main"
grep -Fq -- '- "v*"' "$WORKFLOW" \
  || fail "quality workflow must run the release layer for version tags"
grep -Eq '^[[:space:]]*push:' "$TOOLING_WORKFLOW" \
  || fail "release tooling must run for version tags"
grep -Fq -- '- "v*"' "$TOOLING_WORKFLOW" \
  || fail "release tooling push trigger must be limited to version tags"
if grep -Eq '^[[:space:]]*branches:' "$TOOLING_WORKFLOW"; then
  fail "path-heavy release tooling must not run on branch pushes"
fi
grep -Eq '^[[:space:]]*pull_request:' "$WORKFLOW" || fail "workflow must run on pull requests"
grep -Eq '^[[:space:]]*workflow_dispatch:' "$WORKFLOW" || fail "workflow must support manual runs"
grep -Fq 'risk_level:' "$WORKFLOW" \
  || fail "manual quality runs must expose a risk-level selector"
for risk_level in quick pr release; do
  grep -Fq -- "- $risk_level" "$WORKFLOW" \
    || fail "manual quality risk selector must include: $risk_level"
done
grep -Fq 'contents: read' "$WORKFLOW" || fail "workflow token permissions must be read-only"
grep -Fq 'contents: read' "$TOOLING_WORKFLOW" \
  || fail "release-tooling workflow token permissions must be read-only"
grep -Fq 'DEVELOPER_DIR: /Applications/Xcode_26.3.app/Contents/Developer' "$TOOLING_WORKFLOW" \
  || fail "release-tooling workflow must select the Xcode 26.3 Safari extension toolchain"
for quality_lane in quality-build quality-runtime; do
  grep -Fq 'DEVELOPER_DIR: /Applications/Xcode_26.3.app/Contents/Developer' \
    < <(sed -n "/^  $quality_lane:/,/^  [a-z]/p" "$WORKFLOW") \
    || fail "$quality_lane must select the Xcode 26.3 Safari extension toolchain"
done
grep -Fq 'echo "PLAYWRIGHT_BROWSERS_PATH=$RUNNER_TEMP/ms-playwright" >> "$GITHUB_ENV"' "$TOOLING_WORKFLOW" \
  || fail "release-tooling workflow must share one Playwright browser path across install and gates"
grep -Fq 'xcrun -f safari-web-extension-packager' "$TOOLING_WORKFLOW" \
  || fail "release-tooling workflow must verify the Safari extension packager before running gates"
for quality_lane in quality-build quality-runtime; do
  grep -Fq 'xcrun -f safari-web-extension-packager' \
    < <(sed -n "/^  $quality_lane:/,/^  [a-z]/p" "$WORKFLOW") \
    || fail "$quality_lane must verify the Safari extension packager before running"
done
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
grep -Fq 'timeout-minutes: 25' \
  < <(sed -n '/^  quality-quick:/,/^  quality-coverage:/p' "$WORKFLOW") \
  || fail "pull-request quick lane must keep a bounded independent timeout"
grep -Fq 'timeout-minutes: 45' \
  < <(sed -n '/^  quality-coverage:/,/^  quality-build:/p' "$WORKFLOW") \
  || fail "pull-request coverage lane must keep its independent timeout"
grep -Fq 'timeout-minutes: 35' \
  < <(sed -n '/^  quality-build:/,/^  quality-runtime:/p' "$WORKFLOW") \
  || fail "pull-request build lane must keep a bounded independent timeout"
grep -Fq 'timeout-minutes: 75' \
  < <(sed -n '/^  quality-runtime:/,/^  quality:/p' "$WORKFLOW") \
  || fail "release runtime lane must reserve enough time for the complete UI suite"
grep -Fq 'timeout-minutes: 45' \
  < <(sed -n '/^  release-performance:/,$p' "$WORKFLOW") \
  || fail "release performance lane must tolerate hosted-runner variance"
for required_lane in quality-quick quality-coverage quality-build swift6-migration; do
  grep -Fq -- "- $required_lane" \
    < <(sed -n '/^  quality:/,/^  release-performance:/p' "$WORKFLOW") \
    || fail "final quality check must depend on $required_lane"
done
grep -Fq 'runs-on: ubuntu-24.04' \
  < <(sed -n '/^  quality:/,/^  release-performance:/p' "$WORKFLOW") \
  || fail "final quality aggregation must use the lightweight Linux runner"
grep -Fq 'name: Require every PR quality lane' "$WORKFLOW" \
  || fail "final quality check must fail closed when any independent lane fails"
for required_lane in quality-quick quality-coverage quality-runtime release-performance swift6-migration; do
  grep -Fq -- "- $required_lane" \
    < <(sed -n '/^  release-quality:/,$p' "$WORKFLOW") \
    || fail "final release check must depend on $required_lane"
done
grep -Fq 'name: Require every release quality lane' "$WORKFLOW" \
  || fail "final release check must fail closed when any release lane fails"
grep -Fq './script/check_release_gate.sh' "$WORKFLOW" \
  || fail "workflow must invoke the shared release gate"
grep -Fq "if: github.event_name == 'push' && startsWith(github.ref, 'refs/heads/')" "$WORKFLOW" \
  || fail "main pushes must use a dedicated quick-only job"
grep -Fq "github.event.inputs.risk_level == 'pr'" \
  < <(sed -n '/^  quality-build:/,/^  quality-runtime:/p' "$WORKFLOW") \
  || fail "PR distribution builds must be available only in the PR risk layer"
for release_lane in quality-runtime release-performance; do
  release_lane_body="$(sed -n "/^  $release_lane:/,/^  [a-z]/p" "$WORKFLOW")"
  grep -Fq "startsWith(github.ref, 'refs/tags/v')" <<<"$release_lane_body" \
    || fail "$release_lane must run for version tags"
  grep -Fq "github.event.inputs.risk_level == 'release'" <<<"$release_lane_body" \
    || fail "$release_lane must run only for manual release risk"
done
for deterministic_language_setting in \
  'name: Configure deterministic test language' \
  'defaults write NSGlobalDomain AppleLanguages -array "zh-Hans"' \
  'defaults write NSGlobalDomain AppleLocale "zh_CN"'; do
  setting_count="$(grep -Fc "$deterministic_language_setting" "$WORKFLOW" || true)"
  [[ "$setting_count" -eq 5 ]] \
    || fail "main push, PR code lanes, and release runtime must configure deterministic Simplified Chinese tests"
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
grep -Fq 'name: quality-quick-result' "$WORKFLOW" \
  || fail "quick quality lane must upload independent evidence"
grep -Fq 'name: quality-coverage-result' "$WORKFLOW" \
  || fail "coverage lane must upload independent evidence"
grep -Fq 'name: quality-build-result' "$WORKFLOW" \
  || fail "PR build lane must upload independent evidence"
grep -Fq 'name: release-runtime-result' "$WORKFLOW" \
  || fail "release runtime lane must upload independent evidence"
grep -Fq 'GITHUB_STEP_SUMMARY' "$WORKFLOW" \
  || fail "quality workflow must publish its readable summary"
swift_test_artifact_count="$(grep -Fc '.build/swift-test-shards/' "$WORKFLOW" || true)"
[[ "$swift_test_artifact_count" -eq 2 ]] \
  || fail "main-push and pull-request quality artifacts must both retain Swift test shard diagnostics"
pr_build_body="$(sed -n '/^  quality-build:/,/^  quality-runtime:/p' "$WORKFLOW")"
release_runtime_body="$(sed -n '/^  quality-runtime:/,/^  quality:/p' "$WORKFLOW")"
for runtime_contract in \
  'bash script/check_ui_runtime.sh --launch' \
  'WORKBENCH_XCUI_APP_PATH="$PWD/dist/PersonalSitePublisherMac.app"' \
  'bash script/check_accessibility_runtime.sh --non-screenshot-regression' \
  'env -u RELEASE_GATE_PROFILE bash script/check_accessibility_runtime.sh' \
  'WORKBENCH_XCUI_RETRY_FAILURES: 1'; do
  grep -Fq "$runtime_contract" <<<"$release_runtime_body" \
    || fail "release runtime lane must retain UI contract: $runtime_contract"
  if grep -Fq "$runtime_contract" <<<"$pr_build_body"; then
    fail "PR build lane must not run release-only UI contract: $runtime_contract"
  fi
done
for retry_argument in \
  '-retry-tests-on-failure' \
  '-test-iterations 2' \
  '-test-repetition-relaunch-enabled YES'; do
  grep -Fq -- "$retry_argument" "$ACCESSIBILITY_RUNTIME_GATE" \
    || fail "accessibility runtime retry must include: $retry_argument"
done
grep -Fq 'name: release-ui-smoke-result' "$WORKFLOW" \
  || fail "release workflow must retain UI smoke logs and test evidence"
for release_check in ui-runtime swift-release-build; do
  grep -Fq -- "--check $release_check" <<<"$pr_build_body" \
    || fail "PR build lane must exercise distribution check: $release_check"
  grep -Fq -- "--check $release_check" <<<"$release_runtime_body" \
    || fail "release runtime lane must exercise distribution check: $release_check"
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

echo "CI quality workflow gate: main-push quick layer, parallel PR quick/coverage/Swift 6/Release-build layer, version-tag or manual-release runtime/performance/UI layer, fail-closed aggregators, pinned actions, read-only permissions, summaries, and evidence verified"
