#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/quality.yml"

fail() {
  echo "CI quality workflow gate: $*" >&2
  exit 1
}

[[ -f "$WORKFLOW" ]] || fail "missing .github/workflows/quality.yml"
if grep -Eq '^[[:space:]]*push:' "$WORKFLOW"; then
  fail "expensive macOS workflow must not run on every push"
fi
grep -Eq '^[[:space:]]*pull_request:' "$WORKFLOW" || fail "workflow must run on pull requests"
grep -Eq '^[[:space:]]*workflow_dispatch:' "$WORKFLOW" || fail "workflow must support manual runs"
grep -Fq 'contents: read' "$WORKFLOW" || fail "workflow token permissions must be read-only"
grep -Fq 'uses: actions/checkout@v6' "$WORKFLOW" || fail "workflow must use the current checkout major"
grep -Fq 'runs-on: macos-15' "$WORKFLOW" || fail "workflow must use a macOS runner"
grep -Fq 'timeout-minutes:' "$WORKFLOW" || fail "workflow must have a job timeout"
grep -Fq './script/check_release_gate.sh --quick' "$WORKFLOW" || fail "workflow must run the shared quick gate"
for release_check in app-store-metadata app-store-package-path ui-runtime swift-release-build; do
  grep -Fq -- "--check $release_check" "$WORKFLOW" \
    || fail "workflow must exercise distribution check: $release_check"
done

if grep -Eq '(github_pat_|ghp_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|Authorization:[[:space:]]*Bearer)' "$WORKFLOW"; then
  fail "workflow contains token-like content"
fi

echo "CI quality workflow gate: balanced triggers, read-only permissions, quick checks, and distribution path verified"
