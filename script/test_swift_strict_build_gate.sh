#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mac-editor-swift-strict.XXXXXX" 2>/dev/null || mktemp -d "$ROOT_DIR/.build/tmp/mac-editor-swift-strict.XXXXXX")"
BIN_DIR="$TMP_DIR/bin"
ARGS_FILE="$TMP_DIR/args"
ENV_FILE="$TMP_DIR/env"
ORIGINAL_HOME="$TMP_DIR/original-home"

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
printf '%s\n' "$XDG_CACHE_HOME" "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULE_CACHE_PATH" "HOME=$HOME" >"$STRICT_BUILD_ENV_FILE"
exit "${STRICT_BUILD_STUB_EXIT:-0}"
STUB
chmod +x "$BIN_DIR/swift"

env -u XDG_CACHE_HOME -u CLANG_MODULE_CACHE_PATH -u SWIFT_MODULE_CACHE_PATH \
  STRICT_BUILD_ARGS_FILE="$ARGS_FILE" \
  STRICT_BUILD_ENV_FILE="$ENV_FILE" \
  PATH="$BIN_DIR:$PATH" \
  SWIFT_BUILD_HOME="$TMP_DIR/swift-home" \
  HOME="$ORIGINAL_HOME" \
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
if grep -Fxq -- "-swift-version" "$ARGS_FILE"; then
  fail "gate must inherit the Swift language modes declared by Package.swift"
fi
grep -Fxq -- "-strict-concurrency=complete" "$ARGS_FILE" || fail "gate omitted complete strict concurrency"
grep -Fxq -- "-warnings-as-errors" "$ARGS_FILE" || fail "gate omitted warnings-as-errors"
grep -Fq "$TMP_DIR/swift-home" "$ENV_FILE" || fail "gate did not isolate Swift build caches"
grep -Fxq "HOME=$ORIGINAL_HOME" "$ENV_FILE" || fail "gate repurposed HOME instead of using explicit SwiftPM paths"
if grep -Fxq -- "--target" "$ARGS_FILE"; then
  fail "default gate invocation unexpectedly selected a target"
fi
[[ "$(grep -Fxc -- "--build-tests" "$ARGS_FILE")" -eq 1 ]] || fail "default gate must pass --build-tests exactly once"

: >"$ARGS_FILE"
env -u XDG_CACHE_HOME -u CLANG_MODULE_CACHE_PATH -u SWIFT_MODULE_CACHE_PATH \
  STRICT_BUILD_ARGS_FILE="$ARGS_FILE" \
  STRICT_BUILD_ENV_FILE="$ENV_FILE" \
  PATH="$BIN_DIR:$PATH" \
  SWIFT_BUILD_HOME="$TMP_DIR/swift-home-target" \
  HOME="$ORIGINAL_HOME" \
  SWIFT_PACKAGE_CACHE_PATH="$TMP_DIR/swift-cache-target" \
  STRICT_BUILD_SCRATCH_PATH="$TMP_DIR/strict-concurrency-target" \
  bash "$ROOT_DIR/script/check_swift_strict_build.sh" --target PublishingGitCore >/dev/null

grep -Fxq -- "--target" "$ARGS_FILE" || fail "targeted gate invocation omitted --target"
[[ "$(grep -Fxc -- "--target" "$ARGS_FILE")" -eq 1 ]] || fail "targeted gate invocation emitted --target more than once"
TARGET_FLAG_LINE="$(grep -n -Fx -- "--target" "$ARGS_FILE" | cut -d: -f1)"
TARGET_VALUE_LINE="$((TARGET_FLAG_LINE + 1))"
sed -n "${TARGET_VALUE_LINE}p" "$ARGS_FILE" | grep -Fxq "PublishingGitCore" || fail "targeted gate selected an unexpected target"
grep -Fxq -- "-strict-concurrency=complete" "$ARGS_FILE" || fail "targeted gate omitted complete strict concurrency"
grep -Fxq -- "-warnings-as-errors" "$ARGS_FILE" || fail "targeted gate omitted warnings-as-errors"
if grep -Fxq -- "--build-tests" "$ARGS_FILE"; then
  fail "targeted gate invocation unexpectedly selected --build-tests"
fi

: >"$ARGS_FILE"
env -u XDG_CACHE_HOME -u CLANG_MODULE_CACHE_PATH -u SWIFT_MODULE_CACHE_PATH \
  STRICT_BUILD_ARGS_FILE="$ARGS_FILE" \
  STRICT_BUILD_ENV_FILE="$ENV_FILE" \
  PATH="$BIN_DIR:$PATH" \
  SWIFT_BUILD_HOME="$TMP_DIR/swift-home-workbench" \
  HOME="$ORIGINAL_HOME" \
  SWIFT_PACKAGE_CACHE_PATH="$TMP_DIR/swift-cache-workbench" \
  STRICT_BUILD_SCRATCH_PATH="$TMP_DIR/strict-concurrency-workbench" \
  bash "$ROOT_DIR/script/check_swift_strict_build.sh" --target PublishingWorkbenchCore >/dev/null

[[ "$(grep -Fxc -- "--target" "$ARGS_FILE")" -eq 1 ]] || fail "Workbench target invocation emitted --target more than once"
TARGET_FLAG_LINE="$(grep -n -Fx -- "--target" "$ARGS_FILE" | cut -d: -f1)"
TARGET_VALUE_LINE="$((TARGET_FLAG_LINE + 1))"
sed -n "${TARGET_VALUE_LINE}p" "$ARGS_FILE" | grep -Fxq "PublishingWorkbenchCore" || fail "Workbench target invocation selected an unexpected target"
if grep -Fxq -- "--build-tests" "$ARGS_FILE"; then
  fail "Workbench target invocation unexpectedly selected --build-tests"
fi

for invalid_args in \
  "--unknown" \
  "--target" \
  "--target -looks-like-an-option" \
  "--target --looks-like-an-option" \
  "--target PublishingGitCore --target PublishingAICore" \
  "--target=PublishingGitCore" \
  "--target DoesNotExist"; do
  : >"$ARGS_FILE"
  if env -u XDG_CACHE_HOME -u CLANG_MODULE_CACHE_PATH -u SWIFT_MODULE_CACHE_PATH \
    STRICT_BUILD_ARGS_FILE="$ARGS_FILE" \
    STRICT_BUILD_ENV_FILE="$ENV_FILE" \
    PATH="$BIN_DIR:$PATH" \
    SWIFT_BUILD_HOME="$TMP_DIR/swift-home-invalid" \
    HOME="$ORIGINAL_HOME" \
    SWIFT_PACKAGE_CACHE_PATH="$TMP_DIR/swift-cache-invalid" \
    STRICT_BUILD_SCRATCH_PATH="$TMP_DIR/strict-concurrency-invalid" \
    bash -c 'bash "$1" $2' _ "$ROOT_DIR/script/check_swift_strict_build.sh" "$invalid_args" >/dev/null 2>&1; then
    fail "gate accepted invalid CLI arguments: $invalid_args"
  fi
  if [[ -s "$ARGS_FILE" ]]; then
    fail "gate invoked Swift for invalid CLI arguments: $invalid_args"
  fi
done

README_SWIFT_LABEL="Swift"
README_LEGACY_LANGUAGE_MODE="5"
if grep -Fq "$README_SWIFT_LABEL $README_LEGACY_LANGUAGE_MODE" "$ROOT_DIR/README.public.md"; then
  fail "README.public.md still describes a legacy Swift target"
fi

if env -u XDG_CACHE_HOME -u CLANG_MODULE_CACHE_PATH -u SWIFT_MODULE_CACHE_PATH \
  STRICT_BUILD_ARGS_FILE="$ARGS_FILE" \
  STRICT_BUILD_ENV_FILE="$ENV_FILE" \
  STRICT_BUILD_STUB_EXIT=17 \
  PATH="$BIN_DIR:$PATH" \
  SWIFT_BUILD_HOME="$TMP_DIR/swift-home-failure" \
  HOME="$ORIGINAL_HOME" \
  SWIFT_PACKAGE_CACHE_PATH="$TMP_DIR/swift-cache-failure" \
  STRICT_BUILD_SCRATCH_PATH="$TMP_DIR/strict-concurrency-failure" \
  bash "$ROOT_DIR/script/check_swift_strict_build.sh" --target PublishingGitCore >/dev/null 2>&1; then
  fail "gate accepted a failing Swift build"
fi

echo "manifest Swift 6 complete-concurrency gate test: passed"
