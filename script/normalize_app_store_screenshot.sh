#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_WIDTH="${SCREENSHOT_TARGET_WIDTH:-2880}"
TARGET_HEIGHT="${SCREENSHOT_TARGET_HEIGHT:-1800}"
CANVAS_COLOR="${SCREENSHOT_CANVAS_COLOR:-F5F2EA}"
ACCEPTED_DIMENSIONS="${SCREENSHOT_ACCEPTED_DIMENSIONS:-1280x800 1440x900 2560x1600 2880x1800}"
RENDERER="${APP_STORE_SCREENSHOT_RENDERER:-$ROOT_DIR/script/run_app_store_screenshot_renderer.sh}"

fail() {
  echo "screenshot normalize: $*" >&2
  exit 1
}

[[ "$#" -eq 2 ]] || fail "usage: normalize_app_store_screenshot.sh <input-image> <output-png>"
input="$1"
output="$2"
[[ -s "$input" ]] || fail "input image is missing or empty: $input"
command -v sips >/dev/null 2>&1 || fail "sips is required"
[[ -f "$RENDERER" ]] || fail "lossless screenshot renderer is missing: $RENDERER"

target="${TARGET_WIDTH}x${TARGET_HEIGHT}"
case " $ACCEPTED_DIMENSIONS " in
  *" $target "*) ;;
  *) fail "target $target is not an accepted Mac App Store screenshot size" ;;
esac

properties="$(sips -g pixelWidth -g pixelHeight "$input" 2>/dev/null)" \
  || fail "could not read input image"
source_width="$(printf '%s\n' "$properties" | awk '/pixelWidth:/ { print $2; exit }')"
source_height="$(printf '%s\n' "$properties" | awk '/pixelHeight:/ { print $2; exit }')"
[[ "$source_width" =~ ^[0-9]+$ && "$source_height" =~ ^[0-9]+$ ]] \
  || fail "could not read input dimensions"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/app-store-screenshot.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
final="$tmp_dir/final.png"

# Composite directly into a three-channel RGB bitmap. This keeps text and icon
# edges lossless while removing alpha without the previous JPEG round-trip.
bash "$RENDERER" normalize \
  "$input" "$final" "$TARGET_WIDTH" "$TARGET_HEIGHT" "$CANVAS_COLOR"

final_properties="$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$final" 2>/dev/null)"
final_width="$(printf '%s\n' "$final_properties" | awk '/pixelWidth:/ { print $2; exit }')"
final_height="$(printf '%s\n' "$final_properties" | awk '/pixelHeight:/ { print $2; exit }')"
final_alpha="$(printf '%s\n' "$final_properties" | awk '/hasAlpha:/ { print $2; exit }')"
[[ "$final_width" == "$TARGET_WIDTH" && "$final_height" == "$TARGET_HEIGHT" ]] \
  || fail "normalized image has unexpected dimensions: ${final_width}x${final_height}"
[[ "$final_alpha" == "no" ]] || fail "normalized image still has an alpha channel"

mkdir -p "$(dirname "$output")"
mv "$final" "$output"
echo "screenshot normalize: wrote $output (${TARGET_WIDTH}x${TARGET_HEIGHT}, alpha-free)"
