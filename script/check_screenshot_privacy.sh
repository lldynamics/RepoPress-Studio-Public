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

if [[ "${#blocked[@]}" -gt 0 ]]; then
  fail "possible private content found: ${blocked[*]}"
fi

echo "screenshot privacy gate: audited ${#image_files[@]} screenshot image(s)"
