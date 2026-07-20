#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/screenshot-specifications.XXXXXX")"
SCREENSHOT_DIR="$TMP_DIR/screenshots"
MANIFEST="$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "screenshot specifications test: $*" >&2
  exit 1
}

mkdir -p "$SCREENSHOT_DIR"
cat >"$MANIFEST" <<'MANIFEST'
| ID | Target file | Screen | Purpose | Status |
| --- | --- | --- | --- | --- |
| `writing` | `writing.png` | Writing | Editing | Pending capture |
MANIFEST

source_image="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns"
[[ -f "$source_image" ]] || fail "system fixture image is missing"
sips -s format png "$source_image" --out "$TMP_DIR/source.png" >/dev/null
bash "$ROOT_DIR/script/normalize_app_store_screenshot.sh" \
  "$TMP_DIR/source.png" "$SCREENSHOT_DIR/writing.png" >/dev/null

SCREENSHOT_DIR="$SCREENSHOT_DIR" SCREENSHOT_MANIFEST_FILE="$MANIFEST" STRICT_SCREENSHOTS=1 \
  bash "$ROOT_DIR/script/check_screenshots.sh" >/dev/null \
  || fail "normalized 2880x1800 alpha-free screenshot should pass"

properties="$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$SCREENSHOT_DIR/writing.png")"
grep -q 'pixelWidth: 2880' <<<"$properties" || fail "normalizer should default to 2880 pixels wide"
grep -q 'pixelHeight: 1800' <<<"$properties" || fail "normalizer should default to 1800 pixels high"
grep -q 'hasAlpha: no' <<<"$properties" || fail "normalizer should remove alpha without JPEG"

bash "$ROOT_DIR/script/compose_app_store_marketing_screenshot.sh" \
  writing "$TMP_DIR/source.png" "$TMP_DIR/marketing.png" >/dev/null
marketing_properties="$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$TMP_DIR/marketing.png")"
grep -q 'pixelWidth: 2880' <<<"$marketing_properties" || fail "marketing output should be 2880 pixels wide"
grep -q 'pixelHeight: 1800' <<<"$marketing_properties" || fail "marketing output should be 1800 pixels high"
grep -q 'hasAlpha: no' <<<"$marketing_properties" || fail "marketing output should be alpha-free"

sips -z 750 1200 "$SCREENSHOT_DIR/writing.png" --out "$TMP_DIR/wrong-size.png" >/dev/null
mv "$TMP_DIR/wrong-size.png" "$SCREENSHOT_DIR/writing.png"
if SCREENSHOT_DIR="$SCREENSHOT_DIR" SCREENSHOT_MANIFEST_FILE="$MANIFEST" STRICT_SCREENSHOTS=1 \
  bash "$ROOT_DIR/script/check_screenshots.sh" >/dev/null 2>&1; then
  fail "unsupported dimensions should fail"
fi

sips -s format png -z 900 1440 "$source_image" --out "$SCREENSHOT_DIR/writing.png" >/dev/null
if SCREENSHOT_DIR="$SCREENSHOT_DIR" SCREENSHOT_MANIFEST_FILE="$MANIFEST" STRICT_SCREENSHOTS=1 \
  bash "$ROOT_DIR/script/check_screenshots.sh" >/dev/null 2>&1; then
  fail "accepted dimensions with an alpha channel should fail"
fi

echo "screenshot specifications test: passed"
