#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-screenshot-privacy.XXXXXX)"
SCREENSHOT_DIR="$TMP_DIR/app-store-screenshots"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "screenshot privacy test: $*" >&2
  exit 1
}

mkdir -p "$SCREENSHOT_DIR"

output="$(SCREENSHOT_DIR="$SCREENSHOT_DIR" bash "$ROOT_DIR/script/check_screenshot_privacy.sh")"
grep -q "no screenshot images to audit yet" <<<"$output" || fail "empty screenshot directory did not pass with explicit message"

printf 'clean screenshot placeholder' >"$SCREENSHOT_DIR/writing.png"
output="$(SCREENSHOT_DIR="$SCREENSHOT_DIR" bash "$ROOT_DIR/script/check_screenshot_privacy.sh")"
grep -q "audited 1 screenshot image" <<<"$output" || fail "clean screenshot placeholder was not audited"

printf 'visible path /Users/example/private-site/content/post.md' >"$SCREENSHOT_DIR/local-path.png"
if SCREENSHOT_DIR="$SCREENSHOT_DIR" bash "$ROOT_DIR/script/check_screenshot_privacy.sh" >/dev/null 2>&1; then
  fail "privacy gate accepted screenshot containing a local path"
fi
rm -f "$SCREENSHOT_DIR/local-path.png"

printf 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz1234567890' >"$SCREENSHOT_DIR/token.png"
if SCREENSHOT_DIR="$SCREENSHOT_DIR" bash "$ROOT_DIR/script/check_screenshot_privacy.sh" >/dev/null 2>&1; then
  fail "privacy gate accepted screenshot containing an authorization token"
fi
rm -f "$SCREENSHOT_DIR/token.png"

printf 'github_pat_abcdefghijklmnopqrstuvwxyz1234567890' >"$SCREENSHOT_DIR/github-token.jpeg"
if SCREENSHOT_DIR="$SCREENSHOT_DIR" bash "$ROOT_DIR/script/check_screenshot_privacy.sh" >/dev/null 2>&1; then
  fail "privacy gate accepted screenshot containing a GitHub token"
fi

echo "screenshot privacy test: passed"
