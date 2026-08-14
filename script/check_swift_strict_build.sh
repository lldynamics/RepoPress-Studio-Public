#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
export HOME="$SWIFT_BUILD_HOME"
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
swift build \
  --disable-sandbox \
  --scratch-path "$STRICT_BUILD_SCRATCH_PATH" \
  --cache-path "$SWIFT_PACKAGE_CACHE_PATH" \
  --config-path "$SWIFT_BUILD_HOME/Library/org.swift.swiftpm/configuration" \
  --security-path "$SWIFT_BUILD_HOME/Library/org.swift.swiftpm/security" \
  -Xswiftc -swift-version \
  -Xswiftc 5 \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors

echo "swift complete-concurrency gate: Swift 5 mode, complete concurrency checking, and warnings-as-errors passed"
