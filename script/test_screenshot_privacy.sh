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

OCR_COMPILE_CHECK="$TMP_DIR/screenshot-privacy-ocr-compiled"
OCR_EXECUTABLE="$TMP_DIR/screenshot-privacy-ocr-stub"
RENDER_EXECUTABLE="$TMP_DIR/render-text-png"
MODULE_CACHE="$TMP_DIR/module-cache"
mkdir -p "$MODULE_CACHE"
/usr/bin/xcrun swiftc -module-cache-path "$MODULE_CACHE" "$ROOT_DIR/script/screenshot_privacy_ocr.swift" -o "$OCR_COMPILE_CHECK"
/usr/bin/xcrun swiftc -module-cache-path "$MODULE_CACHE" "$ROOT_DIR/script/test_support/render_text_png.swift" -o "$RENDER_EXECUTABLE"
python3 - "$OCR_EXECUTABLE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_text(
    """#!/usr/bin/env python3
from pathlib import Path
import sys

blocked = []
for value in sys.argv[1:]:
    name = Path(value).name
    if name == "local-path.png":
        blocked.append(f"{name}: local path")
    elif name in {"token.png", "github-token.jpeg"}:
        blocked.append(f"{name}: token-like secret")
if blocked:
    print("\\n".join(blocked))
    raise SystemExit(2)
""",
    encoding="utf-8",
)
path.chmod(0o755)
PY
export SCREENSHOT_PRIVACY_OCR_EXECUTABLE="$OCR_EXECUTABLE"

output="$(SCREENSHOT_DIR="$SCREENSHOT_DIR" bash "$ROOT_DIR/script/check_screenshot_privacy.sh")"
grep -q "no screenshot images to audit yet" <<<"$output" || fail "empty screenshot directory did not pass with explicit message"

"$RENDER_EXECUTABLE" "$SCREENSHOT_DIR/writing.png" "Public writing workspace"
output="$(SCREENSHOT_DIR="$SCREENSHOT_DIR" bash "$ROOT_DIR/script/check_screenshot_privacy.sh")"
grep -q "audited 1 screenshot image" <<<"$output" || fail "clean screenshot placeholder was not audited"

"$RENDER_EXECUTABLE" "$SCREENSHOT_DIR/local-path.png" "/Users/example/private-site/content/post.md"
if SCREENSHOT_DIR="$SCREENSHOT_DIR" bash "$ROOT_DIR/script/check_screenshot_privacy.sh" >/dev/null 2>&1; then
  fail "privacy gate accepted pixels containing a local path"
fi
rm -f "$SCREENSHOT_DIR/local-path.png"

"$RENDER_EXECUTABLE" "$SCREENSHOT_DIR/token.png" "Authorization: Bearer abcdefghijklmnopqrstuvwxyz1234567890"
if SCREENSHOT_DIR="$SCREENSHOT_DIR" bash "$ROOT_DIR/script/check_screenshot_privacy.sh" >/dev/null 2>&1; then
  fail "privacy gate accepted pixels containing an authorization token"
fi
rm -f "$SCREENSHOT_DIR/token.png"

"$RENDER_EXECUTABLE" "$SCREENSHOT_DIR/github-token.jpeg" "github_pat_abcdefghijklmnopqrstuvwxyz1234567890"
if SCREENSHOT_DIR="$SCREENSHOT_DIR" bash "$ROOT_DIR/script/check_screenshot_privacy.sh" >/dev/null 2>&1; then
  fail "privacy gate accepted pixels containing a GitHub token"
fi

echo "screenshot privacy test: passed"
