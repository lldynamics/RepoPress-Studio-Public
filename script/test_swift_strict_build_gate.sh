#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mac-editor-swift-strict.XXXXXX" 2>/dev/null || mktemp -d "$ROOT_DIR/.build/tmp/mac-editor-swift-strict.XXXXXX")"
BIN_DIR="$TMP_DIR/bin"
ARGS_FILE="$TMP_DIR/args"
ENV_FILE="$TMP_DIR/env"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "swift strict build gate test: $*" >&2
  exit 1
}

mkdir -p "$BIN_DIR"
cat >"$BIN_DIR/swift" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$STRICT_BUILD_ARGS_FILE"
printf '%s\n' "$XDG_CACHE_HOME" "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULE_CACHE_PATH" >"$STRICT_BUILD_ENV_FILE"
exit "${STRICT_BUILD_STUB_EXIT:-0}"
STUB
chmod +x "$BIN_DIR/swift"

env -u XDG_CACHE_HOME -u CLANG_MODULE_CACHE_PATH -u SWIFT_MODULE_CACHE_PATH \
  STRICT_BUILD_ARGS_FILE="$ARGS_FILE" \
  STRICT_BUILD_ENV_FILE="$ENV_FILE" \
  PATH="$BIN_DIR:$PATH" \
  SWIFT_BUILD_HOME="$TMP_DIR/swift-home" \
  SWIFT_PACKAGE_CACHE_PATH="$TMP_DIR/swift-cache" \
  STRICT_BUILD_SCRATCH_PATH="$TMP_DIR/strict-concurrency" \
  bash "$ROOT_DIR/script/check_swift_strict_build.sh" >/dev/null

grep -Fxq "build" "$ARGS_FILE" || fail "gate did not run swift build"
grep -Fxq -- "--disable-sandbox" "$ARGS_FILE" || fail "gate omitted --disable-sandbox"
grep -Fxq -- "--scratch-path" "$ARGS_FILE" || fail "gate omitted isolated strict-build scratch path"
grep -Fxq "$TMP_DIR/strict-concurrency" "$ARGS_FILE" || fail "gate used an unexpected strict-build scratch path"
grep -Fxq "$TMP_DIR/swift-cache" "$ARGS_FILE" || fail "gate omitted isolated SwiftPM cache path"
grep -Fxq "$TMP_DIR/swift-home/Library/org.swift.swiftpm/configuration" "$ARGS_FILE" || fail "gate omitted isolated SwiftPM configuration path"
grep -Fxq "$TMP_DIR/swift-home/Library/org.swift.swiftpm/security" "$ARGS_FILE" || fail "gate omitted isolated SwiftPM security path"
grep -Fxq -- "-swift-version" "$ARGS_FILE" || fail "gate omitted an explicit Swift language mode"
grep -Fxq -- "5" "$ARGS_FILE" || fail "gate must use Swift 5 language mode"
grep -Fxq -- "-strict-concurrency=complete" "$ARGS_FILE" || fail "gate omitted complete strict concurrency"
grep -Fxq -- "-warnings-as-errors" "$ARGS_FILE" || fail "gate omitted warnings-as-errors"
grep -Fq "$TMP_DIR/swift-home" "$ENV_FILE" || fail "gate did not isolate Swift build caches"

if env -u XDG_CACHE_HOME -u CLANG_MODULE_CACHE_PATH -u SWIFT_MODULE_CACHE_PATH \
  STRICT_BUILD_ARGS_FILE="$ARGS_FILE" \
  STRICT_BUILD_ENV_FILE="$ENV_FILE" \
  STRICT_BUILD_STUB_EXIT=17 \
  PATH="$BIN_DIR:$PATH" \
  SWIFT_BUILD_HOME="$TMP_DIR/swift-home-failure" \
  SWIFT_PACKAGE_CACHE_PATH="$TMP_DIR/swift-cache-failure" \
  STRICT_BUILD_SCRATCH_PATH="$TMP_DIR/strict-concurrency-failure" \
  bash "$ROOT_DIR/script/check_swift_strict_build.sh" >/dev/null 2>&1; then
  fail "gate accepted a failing Swift build"
fi

echo "swift 5 complete-concurrency gate test: passed"
