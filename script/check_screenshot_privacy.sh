#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$ROOT_DIR/docs/app-store-screenshots}"

fail() {
  echo "screenshot privacy gate: $*" >&2
  exit 1
}

[[ -d "$SCREENSHOT_DIR" ]] || fail "screenshot directory is missing: ${SCREENSHOT_DIR#$ROOT_DIR/}"

image_files=()
while IFS= read -r file; do
  image_files+=("$file")
done < <(find "$SCREENSHOT_DIR" -maxdepth 1 -type f \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' \) | sort)

if [[ "${#image_files[@]}" -eq 0 ]]; then
  echo "screenshot privacy gate: no screenshot images to audit yet"
  exit 0
fi

blocked=()
for file in "${image_files[@]}"; do
  extracted="$(LC_ALL=C strings "$file" 2>/dev/null || true)"
  if echo "$extracted" | grep -Eq '(/Users/|/Volumes/|file:///Users/|file:///Volumes/)'; then
    blocked+=("$(basename "$file"): local path")
  fi
  if echo "$extracted" | grep -Eq '(github_pat_|ghp_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{20,}|Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._-]{20,})'; then
    blocked+=("$(basename "$file"): token-like secret")
  fi
done

OCR_HELPER="$ROOT_DIR/script/screenshot_privacy_ocr.swift"
[[ -f "$OCR_HELPER" ]] || fail "Vision OCR helper is missing"
if [[ -n "${SCREENSHOT_PRIVACY_OCR_EXECUTABLE:-}" ]]; then
  ocr_command=("$SCREENSHOT_PRIVACY_OCR_EXECUTABLE")
else
  ocr_module_cache="${SCREENSHOT_PRIVACY_OCR_MODULE_CACHE:-/private/tmp/personal-site-publisher-ocr-module-cache}"
  mkdir -p "$ocr_module_cache"
  ocr_command=(/usr/bin/xcrun swift -module-cache-path "$ocr_module_cache" "$OCR_HELPER")
fi

set +e
ocr_output="$("${ocr_command[@]}" "${image_files[@]}" 2>&1)"
ocr_status=$?
set -e
if [[ "$ocr_status" -eq 2 ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && blocked+=("$line")
  done <<<"$ocr_output"
elif [[ "$ocr_status" -ne 0 ]]; then
  fail "Vision OCR could not audit screenshots: $ocr_output"
fi

if [[ "${#blocked[@]}" -gt 0 ]]; then
  fail "possible private content found: ${blocked[*]}"
fi

echo "screenshot privacy gate: audited ${#image_files[@]} screenshot image(s) with embedded-text scan and Vision OCR"
