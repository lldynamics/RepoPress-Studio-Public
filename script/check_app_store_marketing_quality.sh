#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT_DIR/script/app_store_marketing_quality.swift"
BUILD_DIR="${APP_STORE_SCREENSHOT_RENDERER_BUILD_DIR:-$ROOT_DIR/.build/screenshot-tools}"
BINARY="$BUILD_DIR/app-store-marketing-quality"
MODULE_CACHE="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/personal-site-publisher-clang-cache}"
INPUT="${1:-$ROOT_DIR/docs/app-store-screenshots/marketing}"

mkdir -p "$BUILD_DIR" "$MODULE_CACHE"
if [[ ! -x "$BINARY" || "$SOURCE" -nt "$BINARY" ]]; then
  xcrun swiftc -module-cache-path "$MODULE_CACHE" "$SOURCE" -o "$BINARY"
fi

exec "$BINARY" "$INPUT"
