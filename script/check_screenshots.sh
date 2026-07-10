#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$ROOT_DIR/docs/app-store-screenshots}"
MANIFEST="${SCREENSHOT_MANIFEST_FILE:-$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md}"
MIN_WIDTH="${SCREENSHOT_MIN_WIDTH:-800}"
MIN_HEIGHT="${SCREENSHOT_MIN_HEIGHT:-500}"

fail() {
  echo "screenshot gate: $*" >&2
  exit 1
}

[[ -f "$MANIFEST" ]] || fail "SCREENSHOT_MANIFEST.md is missing"
command -v sips >/dev/null 2>&1 || fail "sips is required to verify screenshot image dimensions"

is_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

image_dimensions() {
  local file="$1"
  local output width height
  output="$(sips -g pixelWidth -g pixelHeight "$file" 2>/dev/null)" || return 1
  width="$(printf "%s\n" "$output" | awk '/pixelWidth:/ { print $2; exit }')"
  height="$(printf "%s\n" "$output" | awk '/pixelHeight:/ { print $2; exit }')"
  is_integer "$width" && is_integer "$height" || return 1
  printf "%s %s" "$width" "$height"
}

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

for id in "${required_ids[@]}"; do
  grep -q "\`$id\`" "$MANIFEST" || fail "manifest is missing required screen id: $id"
  grep -Eq "\`${id}\.(png|jpg|jpeg)\`" "$MANIFEST" || fail "manifest is missing target image filename for screen id: $id"
done

missing_images=()
for id in "${required_ids[@]}"; do
  if ! find "$SCREENSHOT_DIR" -maxdepth 1 -type f \( -name "${id}.png" -o -name "${id}.jpg" -o -name "${id}.jpeg" \) | grep -q .; then
    missing_images+=("$id")
  fi
done

image_files=()
while IFS= read -r file; do
  image_files+=("$file")
done < <(find "$SCREENSHOT_DIR" -maxdepth 1 -type f \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' \) | sort)

invalid_images=()
if [[ "${#image_files[@]}" -gt 0 ]]; then
  for file in "${image_files[@]}"; do
    if ! dimensions="$(image_dimensions "$file")"; then
      invalid_images+=("$(basename "$file"): unreadable image")
      continue
    fi
    width="${dimensions%% *}"
    height="${dimensions##* }"
    if (( width < MIN_WIDTH || height < MIN_HEIGHT )); then
      invalid_images+=("$(basename "$file"): ${width}x${height} below ${MIN_WIDTH}x${MIN_HEIGHT}")
    fi
  done
fi

if [[ "${#invalid_images[@]}" -gt 0 ]]; then
  fail "invalid screenshot image(s): ${invalid_images[*]}"
fi

image_count="$(find "$SCREENSHOT_DIR" -maxdepth 1 -type f \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' \) | wc -l | tr -d ' ')"
if [[ "${STRICT_SCREENSHOTS:-0}" == "1" && "${#missing_images[@]}" -gt 0 ]]; then
  fail "strict mode requires screenshot images for: ${missing_images[*]}"
fi

if [[ "${#missing_images[@]}" -gt 0 ]]; then
  echo "screenshot gate: manifest covers ${#required_ids[@]} required screens; images found: $image_count; validated minimum: ${MIN_WIDTH}x${MIN_HEIGHT}; missing: ${missing_images[*]}"
else
  echo "screenshot gate: manifest covers ${#required_ids[@]} required screens; images found: $image_count; validated minimum: ${MIN_WIDTH}x${MIN_HEIGHT}"
fi
