#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT_DIR/script/check_repository_source_boundary.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mac-editor-source-boundary.XXXXXX" 2>/dev/null || mktemp -d "$ROOT_DIR/.build/tmp/mac-editor-source-boundary.XXXXXX")"
LINKED_DIR="$TMP_DIR-linked"

cleanup() {
  git -C "$TMP_DIR" worktree remove --force "$LINKED_DIR" >/dev/null 2>&1 || true
  rm -rf "$LINKED_DIR"
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "repository source boundary test: $*" >&2
  exit 1
}

git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" config user.email "release-boundary@example.invalid"
git -C "$TMP_DIR" config user.name "Release Boundary Test"
mkdir -p "$TMP_DIR/Sources/App" "$TMP_DIR/docs"
printf 'let tracked = true\n' >"$TMP_DIR/Sources/App/Tracked.swift"
printf 'notes\n' >"$TMP_DIR/docs/local-notes.md"
git -C "$TMP_DIR" add Sources/App/Tracked.swift
git -C "$TMP_DIR" commit -qm "fixture"

git -C "$TMP_DIR" worktree add -qb source-boundary-linked "$LINKED_DIR"
REPOSITORY_SOURCE_BOUNDARY_ROOT="$LINKED_DIR" bash "$CHECK" >/dev/null \
  || fail "linked worktrees with a .git file should pass"
git -C "$TMP_DIR" worktree remove --force "$LINKED_DIR"

REPOSITORY_SOURCE_BOUNDARY_ROOT="$TMP_DIR" bash "$CHECK" >/dev/null \
  || fail "tracked sources and untracked noncritical notes should pass"
if REPOSITORY_SOURCE_BOUNDARY_ROOT="$TMP_DIR" bash "$CHECK" --release >/dev/null 2>&1; then
  fail "release mode should reject untracked files outside critical paths"
fi
rm -f "$TMP_DIR/docs/local-notes.md"
REPOSITORY_SOURCE_BOUNDARY_ROOT="$TMP_DIR" bash "$CHECK" --release >/dev/null \
  || fail "clean committed checkout should pass release mode"

printf 'let missing = true\n' >"$TMP_DIR/Sources/App/Missing.swift"
if REPOSITORY_SOURCE_BOUNDARY_ROOT="$TMP_DIR" bash "$CHECK" >/dev/null 2>&1; then
  fail "untracked source file should fail"
fi

git -C "$TMP_DIR" add Sources/App/Missing.swift
REPOSITORY_SOURCE_BOUNDARY_ROOT="$TMP_DIR" bash "$CHECK" >/dev/null \
  || fail "staged source file should be present in the clean-checkout boundary"

printf '{"pins": []}\n' >"$TMP_DIR/Package.resolved"
if REPOSITORY_SOURCE_BOUNDARY_ROOT="$TMP_DIR" bash "$CHECK" >/dev/null 2>&1; then
  fail "untracked Package.resolved should fail"
fi
git -C "$TMP_DIR" add Package.resolved
REPOSITORY_SOURCE_BOUNDARY_ROOT="$TMP_DIR" bash "$CHECK" >/dev/null \
  || fail "staged Package.resolved should be present in the clean-checkout boundary"

for extension in ShareExtension ShortcutExtension; do
  mkdir -p "$TMP_DIR/$extension/$extension.xcodeproj"
  for relative in "$extension/App.swift" \
    "$extension/$extension.xcodeproj/project.pbxproj" \
    "$extension/Development.entitlements"; do
    case "$relative" in
      *.swift) printf '// extension source\n' >"$TMP_DIR/$relative" ;;
      *.pbxproj) printf '// project\n' >"$TMP_DIR/$relative" ;;
      *.entitlements) printf '// configuration\n' >"$TMP_DIR/$relative" ;;
    esac
    if output=$(REPOSITORY_SOURCE_BOUNDARY_ROOT="$TMP_DIR" bash "$CHECK" 2>&1); then
      fail "untracked $relative should fail"
    fi
    [[ "$output" == *"$relative"* ]] \
      || fail "untracked $relative failure should identify the relative path"
    git -C "$TMP_DIR" add "$relative"
    REPOSITORY_SOURCE_BOUNDARY_ROOT="$TMP_DIR" bash "$CHECK" >/dev/null \
      || fail "staged $relative should be present in the clean-checkout boundary"
    if REPOSITORY_SOURCE_BOUNDARY_ROOT="$TMP_DIR" bash "$CHECK" --release >/dev/null 2>&1; then
      fail "release mode should reject staged $relative"
    fi
  done
done

mkdir -p "$TMP_DIR/UITests"
printf '// UI test input\n' >"$TMP_DIR/UITests/WorkspaceUITests.swift"
if REPOSITORY_SOURCE_BOUNDARY_ROOT="$TMP_DIR" bash "$CHECK" >/dev/null 2>&1; then
  fail "untracked UI test input should fail"
fi
git -C "$TMP_DIR" add UITests/WorkspaceUITests.swift
REPOSITORY_SOURCE_BOUNDARY_ROOT="$TMP_DIR" bash "$CHECK" >/dev/null \
  || fail "staged UI test input should be present in the clean-checkout boundary"

mkdir -p "$TMP_DIR/Shared/RepoPressCoreContracts/swift"
printf '// shared source\n' >"$TMP_DIR/Shared/RepoPressCoreContracts/swift/Package.swift"
if REPOSITORY_SOURCE_BOUNDARY_ROOT="$TMP_DIR" bash "$CHECK" >/dev/null 2>&1; then
  fail "untracked shared package source should fail"
fi
git -C "$TMP_DIR" add Shared/RepoPressCoreContracts/swift/Package.swift
REPOSITORY_SOURCE_BOUNDARY_ROOT="$TMP_DIR" bash "$CHECK" >/dev/null \
  || fail "staged shared package source should be present in the clean-checkout boundary"
if REPOSITORY_SOURCE_BOUNDARY_ROOT="$TMP_DIR" bash "$CHECK" --release >/dev/null 2>&1; then
  fail "release mode should reject staged changes"
fi
git -C "$TMP_DIR" commit -qm "track source input"
REPOSITORY_SOURCE_BOUNDARY_ROOT="$TMP_DIR" bash "$CHECK" --release >/dev/null \
  || fail "release mode should pass after committing build inputs"

printf '#!/usr/bin/env bash\n' >"$TMP_DIR/script-new.sh"
REPOSITORY_SOURCE_BOUNDARY_ROOT="$TMP_DIR" bash "$CHECK" >/dev/null \
  || fail "untracked file outside the critical paths should not fail"
if REPOSITORY_SOURCE_BOUNDARY_ROOT="$TMP_DIR" bash "$CHECK" --release >/dev/null 2>&1; then
  fail "release mode should reject any untracked file"
fi
rm -f "$TMP_DIR/script-new.sh"

printf 'let tracked = false\n' >"$TMP_DIR/Sources/App/Tracked.swift"
REPOSITORY_SOURCE_BOUNDARY_ROOT="$TMP_DIR" bash "$CHECK" >/dev/null \
  || fail "daily boundary should allow tracked worktree edits"
if REPOSITORY_SOURCE_BOUNDARY_ROOT="$TMP_DIR" bash "$CHECK" --release >/dev/null 2>&1; then
  fail "release mode should reject tracked worktree edits"
fi

echo "repository source boundary test: passed"
