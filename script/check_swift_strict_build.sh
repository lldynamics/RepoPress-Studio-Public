#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_BUILD_HOME="${SWIFT_BUILD_HOME:-/private/tmp/personal-site-publisher-swift-home}"
STRICT_BUILD_SCRATCH_PATH="${STRICT_BUILD_SCRATCH_PATH:-$ROOT_DIR/.build/strict-concurrency}"

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
  "$SWIFT_BUILD_HOME/Library/Caches/org.swift.swiftpm"

cd "$ROOT_DIR"
swift build \
  --disable-sandbox \
  --scratch-path "$STRICT_BUILD_SCRATCH_PATH" \
  --cache-path "$SWIFT_BUILD_HOME/Library/Caches/org.swift.swiftpm" \
  --config-path "$SWIFT_BUILD_HOME/Library/org.swift.swiftpm/configuration" \
  --security-path "$SWIFT_BUILD_HOME/Library/org.swift.swiftpm/security" \
  -Xswiftc -swift-version \
  -Xswiftc 5 \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors

echo "swift complete-concurrency gate: Swift 5 mode, complete concurrency checking, and warnings-as-errors passed"
