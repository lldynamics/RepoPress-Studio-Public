#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$ROOT_DIR/docs/app-store-screenshots}"
MANIFEST_FILE="${SCREENSHOT_MANIFEST_FILE:-$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md}"
CAPTURE_SCRIPT="${SCREENSHOT_CAPTURE_SCRIPT:-$ROOT_DIR/script/capture_app_screenshots.sh}"
BUILD_SCRIPT="${SCREENSHOT_BUILD_SCRIPT:-$ROOT_DIR/script/build_and_run.sh}"

required_ids=(
  writing
  ai-chat
  sync-api-publish
  seo-social-preview
  deployment-status
  maintenance
  general-drafts
  pro-settings
  privacy-lock
  release-readiness
)

fail() {
  echo "screenshot capture readiness: $*" >&2
  exit 1
}

join_by_space() {
  local IFS=" "
  echo "$*"
}

list_from_script() {
  local script="$1"
  local label="$2"
  [[ -f "$script" ]] || fail "$label script is missing: ${script#$ROOT_DIR/}"
  bash "$script" --list 2>/dev/null || fail "$label script must support --list"
}

list_build_surfaces() {
  [[ -f "$BUILD_SCRIPT" ]] || fail "build script is missing: ${BUILD_SCRIPT#$ROOT_DIR/}"
  bash "$BUILD_SCRIPT" --list-screenshot-surfaces 2>/dev/null \
    || fail "build script must support --list-screenshot-surfaces"
}

expect_same_surface_list() {
  local label="$1"
  local actual="$2"
  local expected actual_normalized expected_normalized
  expected="$(printf '%s\n' "${required_ids[@]}")"
  actual_normalized="$(printf '%s\n' "$actual" | sed '/^[[:space:]]*$/d')"
  expected_normalized="$(printf '%s\n' "$expected" | sed '/^[[:space:]]*$/d')"
  [[ "$actual_normalized" == "$expected_normalized" ]] \
    || fail "$label surface list does not match required ids. expected: $(join_by_space "${required_ids[@]}")"
}

[[ -d "$SCREENSHOT_DIR" ]] || fail "screenshot directory is missing: ${SCREENSHOT_DIR#$ROOT_DIR/}"
[[ -f "$MANIFEST_FILE" ]] || fail "screenshot manifest is missing: ${MANIFEST_FILE#$ROOT_DIR/}"
[[ -f "$CAPTURE_SCRIPT" ]] || fail "capture script is missing: ${CAPTURE_SCRIPT#$ROOT_DIR/}"
[[ -f "$BUILD_SCRIPT" ]] || fail "build script is missing: ${BUILD_SCRIPT#$ROOT_DIR/}"
command -v sips >/dev/null 2>&1 || fail "sips is required for screenshot dimension checks"
command -v screencapture >/dev/null 2>&1 || fail "screencapture is required for App Store screenshot capture"
command -v osascript >/dev/null 2>&1 || fail "osascript is required for --auto-window screenshot capture"

capture_list="$(list_from_script "$CAPTURE_SCRIPT" "capture")"
build_list="$(list_build_surfaces)"
expect_same_surface_list "capture script" "$capture_list"
expect_same_surface_list "build script" "$build_list"

for id in "${required_ids[@]}"; do
  grep -q "\`$id\`" "$MANIFEST_FILE" || fail "manifest is missing required screenshot id: $id"
  grep -Eq "\`${id}\.(png|jpg|jpeg)\`" "$MANIFEST_FILE" \
    || fail "manifest is missing target image filename for screenshot id: $id"
done

SCREENSHOT_SURFACE_ROOT="$ROOT_DIR" \
SCREENSHOT_MANIFEST_FILE="$MANIFEST_FILE" \
SCREENSHOT_CAPTURE_SCRIPT="$CAPTURE_SCRIPT" \
SCREENSHOT_BUILD_SCRIPT="$BUILD_SCRIPT" \
  bash "$ROOT_DIR/script/check_screenshot_surface_map.sh" >/dev/null

SCREENSHOT_DIR="$SCREENSHOT_DIR" SCREENSHOT_MANIFEST_FILE="$MANIFEST_FILE" \
  bash "$ROOT_DIR/script/sync_screenshot_manifest_status.sh" --check >/dev/null
SCREENSHOT_DIR="$SCREENSHOT_DIR" SCREENSHOT_MANIFEST_FILE="$MANIFEST_FILE" \
  bash "$ROOT_DIR/script/check_screenshots.sh" >/dev/null
SCREENSHOT_DIR="$SCREENSHOT_DIR" \
  bash "$ROOT_DIR/script/check_screenshot_privacy.sh" >/dev/null

captured_ids=()
missing_ids=()
for id in "${required_ids[@]}"; do
  if find "$SCREENSHOT_DIR" -maxdepth 1 -type f \( -name "$id.png" -o -name "$id.jpg" -o -name "$id.jpeg" \) | grep -q .; then
    captured_ids+=("$id")
  else
    missing_ids+=("$id")
  fi
done

echo "screenshot capture readiness: ready"
echo "- required surfaces: $(join_by_space "${required_ids[@]}")"
echo "- captured screenshots: ${#captured_ids[@]}/${#required_ids[@]}"
if [[ "${#missing_ids[@]}" -gt 0 ]]; then
  echo "- missing screenshots: $(join_by_space "${missing_ids[@]}")"
  echo "- next capture command: script/capture_app_screenshots.sh --auto-window --force-relaunch"
else
  echo "- strict evidence command: script/record_app_store_screenshot_evidence.sh --execute"
fi
