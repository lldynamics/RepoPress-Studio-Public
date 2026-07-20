#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT_DIR/script/app_store_window_capture.swift"
BUILD_DIR="${APP_STORE_SCREENSHOT_RENDERER_BUILD_DIR:-$ROOT_DIR/.build/screenshot-tools}"
BINARY="$BUILD_DIR/app-store-window-capture"
MODULE_CACHE="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/personal-site-publisher-clang-cache}"

fail() {
  echo "app store window capture: $*" >&2
  exit 1
}

[[ -f "$SOURCE" ]] || fail "capture source is missing"
command -v xcrun >/dev/null 2>&1 || fail "xcrun is required"

mkdir -p "$BUILD_DIR" "$MODULE_CACHE"
if [[ ! -x "$BINARY" || "$SOURCE" -nt "$BINARY" ]]; then
  xcrun swiftc -parse-as-library -module-cache-path "$MODULE_CACHE" "$SOURCE" -o "$BINARY"
fi

exec "$BINARY" "$@"
