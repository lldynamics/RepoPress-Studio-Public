#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-swift6-migration.XXXXXX)"
BIN_DIR="$TMP_DIR/bin"
ARGS_FILE="$TMP_DIR/args"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "swift 6 migration diagnostic test: $*" >&2
  exit 1
}

mkdir -p "$BIN_DIR"
cat >"$BIN_DIR/swift" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$SWIFT6_ARGS_FILE"
exit "${SWIFT6_STUB_EXIT:-0}"
STUB
chmod +x "$BIN_DIR/swift"

SWIFT6_ARGS_FILE="$ARGS_FILE" \
PATH="$BIN_DIR:$PATH" \
SWIFT_BUILD_HOME="$TMP_DIR/swift-home" \
  bash "$ROOT_DIR/script/check_swift6_migration.sh" >/dev/null

grep -Fxq "build" "$ARGS_FILE" || fail "diagnostic did not run swift build"
grep -Fxq -- "--disable-sandbox" "$ARGS_FILE" || fail "diagnostic omitted --disable-sandbox"
grep -Fxq "$ROOT_DIR/.build/swift6-migration" "$ARGS_FILE" || fail "diagnostic used an unexpected scratch path"
grep -Fxq "$TMP_DIR/swift-home/Library/Caches/org.swift.swiftpm" "$ARGS_FILE" || fail "diagnostic omitted isolated SwiftPM cache path"
grep -Fxq -- "-swift-version" "$ARGS_FILE" || fail "diagnostic omitted -swift-version"
grep -Fxq -- "6" "$ARGS_FILE" || fail "diagnostic did not use true Swift 6 language mode"
grep -Fxq -- "-strict-concurrency=complete" "$ARGS_FILE" || fail "diagnostic omitted complete concurrency"
grep -Fxq -- "-warnings-as-errors" "$ARGS_FILE" || fail "diagnostic omitted warnings-as-errors"

if SWIFT6_ARGS_FILE="$ARGS_FILE" \
  SWIFT6_STUB_EXIT=23 \
  PATH="$BIN_DIR:$PATH" \
  SWIFT_BUILD_HOME="$TMP_DIR/swift-home-failure" \
  bash "$ROOT_DIR/script/check_swift6_migration.sh" >/dev/null 2>&1; then
  fail "diagnostic accepted a failing Swift 6 build"
fi

echo "swift 6 migration diagnostic test: passed"
