#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
READINESS="$ROOT_DIR/script/check_app_store_screenshot_capture_readiness.sh"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-screenshot-readiness.XXXXXX)"
SCREENSHOT_DIR="$TMP_DIR/app-store-screenshots"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "app store screenshot capture readiness test: $*" >&2
  exit 1
}

[[ -f "$READINESS" ]] || fail "check_app_store_screenshot_capture_readiness.sh is missing"
mkdir -p "$SCREENSHOT_DIR"
cp "$ROOT_DIR/docs/app-store-screenshots/SCREENSHOT_MANIFEST.md" "$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md"
SCREENSHOT_DIR="$SCREENSHOT_DIR" \
SCREENSHOT_MANIFEST_FILE="$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md" \
  bash "$ROOT_DIR/script/sync_screenshot_manifest_status.sh" >/dev/null

output="$(
  SCREENSHOT_DIR="$SCREENSHOT_DIR" \
  SCREENSHOT_MANIFEST_FILE="$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md" \
    bash "$READINESS"
)"
grep -q "screenshot capture readiness: ready" <<<"$output" || fail "readiness did not print ready"
grep -q "captured screenshots: 0/10" <<<"$output" || fail "readiness did not report missing screenshots"
grep -q "next capture command: script/capture_app_screenshots.sh --auto-window --force-relaunch" <<<"$output" \
  || fail "readiness did not print the auto capture command"

broken_manifest="$TMP_DIR/broken-manifest.md"
cp "$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md" "$broken_manifest"
perl -0pi -e 's/\| `release-readiness` \| `release-readiness\.png`[^\n]*\n//' "$broken_manifest"
if SCREENSHOT_DIR="$SCREENSHOT_DIR" SCREENSHOT_MANIFEST_FILE="$broken_manifest" \
  bash "$READINESS" >/dev/null 2>&1; then
  fail "readiness accepted a manifest missing release-readiness"
fi

broken_capture="$TMP_DIR/capture_app_screenshots.sh"
cp "$ROOT_DIR/script/capture_app_screenshots.sh" "$broken_capture"
perl -0pi -e 's/seo-social-preview\n//' "$broken_capture"
if SCREENSHOT_DIR="$SCREENSHOT_DIR" \
  SCREENSHOT_MANIFEST_FILE="$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md" \
  SCREENSHOT_CAPTURE_SCRIPT="$broken_capture" \
  bash "$READINESS" >/dev/null 2>&1; then
  fail "readiness accepted a capture script with a missing surface"
fi

echo "app store screenshot capture readiness test: passed"
