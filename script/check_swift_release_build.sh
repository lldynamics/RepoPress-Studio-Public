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
  -c release \
  --disable-sandbox \
  --product PersonalSitePublisherMac

release_bin_dir="$(swift build -c release --disable-sandbox --show-bin-path)"
case "$release_bin_dir" in
  */release) ;;
  *)
    echo "swift release build gate: SwiftPM returned a non-release binary directory: $release_bin_dir" >&2
    exit 1
    ;;
esac
[[ -x "$release_bin_dir/PersonalSitePublisherMac" ]] || {
  echo "swift release build gate: release app executable is missing or not executable" >&2
  exit 1
}
echo "swift release build gate: release app product passed"
