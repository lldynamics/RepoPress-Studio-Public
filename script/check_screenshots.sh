#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$ROOT_DIR/docs/app-store-screenshots}"
MANIFEST="${SCREENSHOT_MANIFEST_FILE:-$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md}"
ACCEPTED_DIMENSIONS="${SCREENSHOT_ACCEPTED_DIMENSIONS:-1280x800 1440x900 2560x1600 2880x1800}"

fail() {
  echo "screenshot gate: $*" >&2
  exit 1
}

[[ -f "$MANIFEST" ]] || fail "SCREENSHOT_MANIFEST.md is missing"
command -v sips >/dev/null 2>&1 || fail "sips is required to verify screenshot image dimensions"

is_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

image_properties() {
  local file="$1"
  local output width height has_alpha
  output="$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$file" 2>/dev/null)" || return 1
  width="$(printf "%s\n" "$output" | awk '/pixelWidth:/ { print $2; exit }')"
  height="$(printf "%s\n" "$output" | awk '/pixelHeight:/ { print $2; exit }')"
  has_alpha="$(printf "%s\n" "$output" | awk '/hasAlpha:/ { print $2; exit }')"
  is_integer "$width" && is_integer "$height" || return 1
  [[ "$has_alpha" == "yes" || "$has_alpha" == "no" ]] || return 1
  printf "%s %s %s" "$width" "$height" "$has_alpha"
}

is_accepted_dimensions() {
  local candidate="$1"
  local accepted
  for accepted in $ACCEPTED_DIMENSIONS; do
    [[ "$candidate" == "$accepted" ]] && return 0
  done
  return 1
}

required_ids=()
while IFS= read -r id; do
  [[ -n "$id" ]] && required_ids+=("$id")
done < <(sed -nE 's/^\| `([^`]+)` \|.*/\1/p' "$MANIFEST")
[[ "${#required_ids[@]}" -gt 0 ]] || fail "screenshot manifest contains no required screenshot IDs"

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
    if ! properties="$(image_properties "$file")"; then
      invalid_images+=("$(basename "$file"): unreadable image")
      continue
    fi
    read -r width height has_alpha <<<"$properties"
    if ! is_accepted_dimensions "${width}x${height}"; then
      invalid_images+=("$(basename "$file"): ${width}x${height} is not an accepted Mac App Store size (${ACCEPTED_DIMENSIONS})")
    fi
    if [[ "$has_alpha" == "yes" ]]; then
      invalid_images+=("$(basename "$file"): alpha channel/transparency is not accepted by App Store Connect")
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
  echo "screenshot gate: manifest covers ${#required_ids[@]} required screens; images found: $image_count; accepted Mac sizes: ${ACCEPTED_DIMENSIONS}; missing: ${missing_images[*]}"
else
  echo "screenshot gate: manifest covers ${#required_ids[@]} required screens; images found: $image_count; accepted Mac sizes: ${ACCEPTED_DIMENSIONS}; alpha-free"
fi
