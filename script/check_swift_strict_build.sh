#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TARGET_NAME=""
if [[ "$#" -eq 0 ]]; then
  :
elif [[ "$#" -eq 2 && "$1" == "--target" ]]; then
  TARGET_NAME="$2"
  if [[ -z "$TARGET_NAME" || "$TARGET_NAME" == -* ]]; then
    echo "swift complete-concurrency gate: --target requires a target name" >&2
    exit 2
  fi
else
  echo "swift complete-concurrency gate: usage: $0 [--target TARGET]" >&2
  exit 2
fi

package_target_names() {
  awk '
    function emit_name(line) {
      sub(/^.*name:[[:space:]]*"/, "", line)
      sub(/".*$/, "", line)
      if (line != "") print line
    }
    /^[[:space:]]*\.(target|executableTarget|testTarget)\([[:space:]]*name:/ {
      emit_name($0)
      in_target = 0
      next
    }
    /^[[:space:]]*\.(target|executableTarget|testTarget)\(/ {
      in_target = 1
      next
    }
    in_target && /name:[[:space:]]*"/ {
      emit_name($0)
      in_target = 0
    }
  ' "$ROOT_DIR/Package.swift"
}

if [[ -n "$TARGET_NAME" ]]; then
  PACKAGE_TARGET_NAMES="$(package_target_names)"
  if [[ -z "$PACKAGE_TARGET_NAMES" ]] || ! grep -Fxq "$TARGET_NAME" <<<"$PACKAGE_TARGET_NAMES"; then
    echo "swift complete-concurrency gate: unknown target: $TARGET_NAME" >&2
    exit 2
  fi
fi

if [[ -z "${SWIFT_BUILD_HOME:-}" ]]; then
  if [[ -n "${TMPDIR:-}" ]] && ( mkdir -p "$TMPDIR/test-write.$$" 2>/dev/null ); then
    rm -rf "$TMPDIR/test-write.$$" 2>/dev/null || true
    SWIFT_BUILD_HOME="$TMPDIR/personal-site-publisher-swift-home"
  elif ( mkdir -p "/private/tmp/test-write.$$" 2>/dev/null ); then
    rm -rf "/private/tmp/test-write.$$" 2>/dev/null || true
    SWIFT_BUILD_HOME="/private/tmp/personal-site-publisher-swift-home"
  else
    SWIFT_BUILD_HOME="$ROOT_DIR/.build/tmp/swift-home"
  fi
fi
SWIFT_PACKAGE_CACHE_PATH="${SWIFT_PACKAGE_CACHE_PATH:-$ROOT_DIR/.build}"
if [[ -d "$ROOT_DIR/.build/checkouts/Sparkle" && -d "$ROOT_DIR/.build/artifacts/sparkle" ]]; then
  DEFAULT_STRICT_BUILD_SCRATCH_PATH="$ROOT_DIR/.build"
else
  DEFAULT_STRICT_BUILD_SCRATCH_PATH="$ROOT_DIR/.build/strict-concurrency"
fi
STRICT_BUILD_SCRATCH_PATH="${STRICT_BUILD_SCRATCH_PATH:-$DEFAULT_STRICT_BUILD_SCRATCH_PATH}"

export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$SWIFT_BUILD_HOME/.cache}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$SWIFT_BUILD_HOME/.swift-clang-cache}"
export SWIFT_MODULE_CACHE_PATH="${SWIFT_MODULE_CACHE_PATH:-$SWIFT_BUILD_HOME/.swift-module-cache}"

mkdir -p \
  "$SWIFT_BUILD_HOME" \
  "$XDG_CACHE_HOME" \
  "$CLANG_MODULE_CACHE_PATH" \
  "$SWIFT_MODULE_CACHE_PATH" \
  "$SWIFT_BUILD_HOME/Library/org.swift.swiftpm/configuration" \
  "$SWIFT_BUILD_HOME/Library/org.swift.swiftpm/security" \
  "$SWIFT_BUILD_HOME/Library/Caches/org.swift.swiftpm" \
  "$SWIFT_PACKAGE_CACHE_PATH"

cd "$ROOT_DIR"
SWIFT_BUILD_ARGUMENTS=(
  build
  --disable-sandbox \
  --scratch-path "$STRICT_BUILD_SCRATCH_PATH" \
  --cache-path "$SWIFT_PACKAGE_CACHE_PATH" \
  --config-path "$SWIFT_BUILD_HOME/Library/org.swift.swiftpm/configuration" \
  --security-path "$SWIFT_BUILD_HOME/Library/org.swift.swiftpm/security" \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
)
if [[ -n "$TARGET_NAME" ]]; then
  SWIFT_BUILD_ARGUMENTS+=(--target "$TARGET_NAME")
else
  SWIFT_BUILD_ARGUMENTS+=(--build-tests)
fi
swift "${SWIFT_BUILD_ARGUMENTS[@]}"

echo "swift complete-concurrency gate: Package.swift language modes, complete concurrency checking, and warnings-as-errors passed"
