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
if grep -Eq '^[[:space:]]*push:' "$WORKFLOW" "$TOOLING_WORKFLOW"; then
  fail "expensive macOS workflows must not run on every push"
fi
grep -Eq '^[[:space:]]*pull_request:' "$WORKFLOW" || fail "workflow must run on pull requests"
grep -Eq '^[[:space:]]*workflow_dispatch:' "$WORKFLOW" || fail "workflow must support manual runs"
grep -Fq 'contents: read' "$WORKFLOW" || fail "workflow token permissions must be read-only"
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
grep -Fq -- '--quick' "$WORKFLOW" \
  || fail "workflow must run the shared quick gate"
grep -Fq -- '--summary-markdown .build/quality-gate-summary.md' "$WORKFLOW" \
  || fail "quality workflow must produce a readable quick-gate summary"
grep -Fq -- '--summary-markdown .build/distribution-gate-summary.md' "$WORKFLOW" \
  || fail "quality workflow must produce a readable distribution summary"
grep -Fq 'GITHUB_STEP_SUMMARY' "$WORKFLOW" \
  || fail "quality workflow must publish its readable summary"
grep -Fq 'bash script/check_ui_runtime.sh --launch' "$WORKFLOW" \
  || fail "quality workflow must verify a real visible Release app launch"
grep -Fq 'WORKBENCH_XCUI_APP_PATH="$PWD/dist/PersonalSitePublisherMac.app"' "$WORKFLOW" \
  || fail "quality workflow must reuse the verified Release app for UI smoke"
grep -Fq 'bash script/check_accessibility_runtime.sh' "$WORKFLOW" \
  || fail "quality workflow must run the macOS accessibility UI smoke"
grep -Fq 'name: ui-smoke-result' "$WORKFLOW" \
  || fail "quality workflow must retain UI smoke logs and test evidence"
for release_check in app-store-metadata app-store-package-path ui-runtime swift-release-build; do
  grep -Fq -- "--check $release_check" "$WORKFLOW" \
    || fail "workflow must exercise distribution check: $release_check"
done
for dependency_path in \
  Sources/PublishingWorkbenchCore/Models/KnowledgeModels.swift \
  Sources/PublishingWorkbenchCore/Services/KeychainTokenStore.swift; do
  grep -Fq "$dependency_path" "$TOOLING_WORKFLOW" \
    || fail "release-tooling workflow must watch browser dependency: $dependency_path"
done
grep -Fq -- '--summary-markdown .build/browser-extension-gate-summary.md' "$TOOLING_WORKFLOW" \
  || fail "release-tooling workflow must summarize the browser extension gate"
grep -Fq -- '--summary-markdown .build/tooling-gate-summary.md' "$TOOLING_WORKFLOW" \
  || fail "release-tooling workflow must summarize tooling self-tests"
grep -Fq 'GITHUB_STEP_SUMMARY' "$TOOLING_WORKFLOW" \
  || fail "release-tooling workflow must publish its readable summary"

if grep -Eq '(github_pat_|ghp_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|Authorization:[[:space:]]*Bearer)' \
  "$WORKFLOW" "$TOOLING_WORKFLOW"; then
  fail "workflow contains token-like content"
fi

echo "CI quality workflow gate: balanced triggers, pinned actions, real launch, UI smoke, read-only permissions, dependency paths, summaries, and distribution path verified"
