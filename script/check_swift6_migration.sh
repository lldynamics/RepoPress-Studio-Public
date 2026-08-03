#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_BUILD_HOME="${SWIFT_BUILD_HOME:-/private/tmp/personal-site-publisher-swift6-home}"
SWIFT6_MIGRATION_SCRATCH_PATH="${SWIFT6_MIGRATION_SCRATCH_PATH:-$ROOT_DIR/.build/swift6-migration}"

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
  --scratch-path "$SWIFT6_MIGRATION_SCRATCH_PATH" \
  --cache-path "$SWIFT_BUILD_HOME/Library/Caches/org.swift.swiftpm" \
  --config-path "$SWIFT_BUILD_HOME/Library/org.swift.swiftpm/configuration" \
  --security-path "$SWIFT_BUILD_HOME/Library/org.swift.swiftpm/security" \
  -Xswiftc -swift-version \
  -Xswiftc 6 \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors

echo "swift 6 migration diagnostic: true Swift 6 language-mode build passed"
