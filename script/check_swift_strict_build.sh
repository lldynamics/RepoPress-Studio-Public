#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_BUILD_HOME="${SWIFT_BUILD_HOME:-/private/tmp/personal-site-publisher-swift-home}"
STRICT_BUILD_SCRATCH_PATH="${STRICT_BUILD_SCRATCH_PATH:-$ROOT_DIR/.build/strict-concurrency}"

export HOME="$SWIFT_BUILD_HOME"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$HOME/.swift-clang-cache}"
export SWIFT_MODULE_CACHE_PATH="${SWIFT_MODULE_CACHE_PATH:-$HOME/.swift-module-cache}"

mkdir -p \
  "$HOME" \
  "$XDG_CACHE_HOME" \
  "$CLANG_MODULE_CACHE_PATH" \
  "$SWIFT_MODULE_CACHE_PATH" \
  "$HOME/Library/org.swift.swiftpm/configuration" \
  "$HOME/Library/org.swift.swiftpm/security" \
  "$HOME/Library/Caches/org.swift.swiftpm"

cd "$ROOT_DIR"
swift build \
  --disable-sandbox \
  --scratch-path "$STRICT_BUILD_SCRATCH_PATH" \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors

echo "swift strict build gate: complete concurrency checking and warnings-as-errors passed"
