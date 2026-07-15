#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT_DIR/script/check_repository_source_boundary.sh"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-source-boundary.XXXXXX)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "repository source boundary test: $*" >&2
  exit 1
}

git -C "$TMP_DIR" init -q
mkdir -p "$TMP_DIR/Sources/App" "$TMP_DIR/docs"
printf 'let tracked = true\n' >"$TMP_DIR/Sources/App/Tracked.swift"
printf 'notes\n' >"$TMP_DIR/docs/local-notes.md"
git -C "$TMP_DIR" add Sources/App/Tracked.swift

REPOSITORY_SOURCE_BOUNDARY_ROOT="$TMP_DIR" bash "$CHECK" >/dev/null \
  || fail "tracked sources and untracked noncritical notes should pass"

printf 'let missing = true\n' >"$TMP_DIR/Sources/App/Missing.swift"
if REPOSITORY_SOURCE_BOUNDARY_ROOT="$TMP_DIR" bash "$CHECK" >/dev/null 2>&1; then
  fail "untracked source file should fail"
fi

git -C "$TMP_DIR" add Sources/App/Missing.swift
REPOSITORY_SOURCE_BOUNDARY_ROOT="$TMP_DIR" bash "$CHECK" >/dev/null \
  || fail "staged source file should be present in the clean-checkout boundary"

printf '#!/usr/bin/env bash\n' >"$TMP_DIR/script-new.sh"
REPOSITORY_SOURCE_BOUNDARY_ROOT="$TMP_DIR" bash "$CHECK" >/dev/null \
  || fail "untracked file outside the critical paths should not fail"

echo "repository source boundary test: passed"
