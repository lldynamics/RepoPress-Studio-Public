#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-screenshot-manifest.XXXXXX)"
SCREENSHOT_DIR="$TMP_DIR/app-store-screenshots"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "screenshot manifest sync test: $*" >&2
  exit 1
}

mkdir -p "$SCREENSHOT_DIR"
cp "$ROOT_DIR/docs/app-store-screenshots/SCREENSHOT_MANIFEST.md" "$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md"
SCREENSHOT_DIR="$SCREENSHOT_DIR" \
SCREENSHOT_MANIFEST_FILE="$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md" \
  bash "$ROOT_DIR/script/sync_screenshot_manifest_status.sh" >/dev/null

create_png() {
  local path="$1"
  local width="$2"
  local height="$3"
  python3 - "$path" "$width" "$height" <<'PY'
from pathlib import Path
import struct
import sys
import zlib

path = Path(sys.argv[1])
width = int(sys.argv[2])
height = int(sys.argv[3])

def chunk(kind: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    )

raw = b"".join(b"\x00" + (b"\xff\xff\xff" * width) for _ in range(height))
png = (
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(raw, 9))
    + chunk(b"IEND", b"")
)
path.write_bytes(png)
PY
}

SCREENSHOT_DIR="$SCREENSHOT_DIR" SCREENSHOT_MANIFEST_FILE="$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md" \
  bash "$ROOT_DIR/script/sync_screenshot_manifest_status.sh" --check >/dev/null

create_png "$SCREENSHOT_DIR/writing.png" 1440 900

if SCREENSHOT_DIR="$SCREENSHOT_DIR" SCREENSHOT_MANIFEST_FILE="$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md" \
  bash "$ROOT_DIR/script/sync_screenshot_manifest_status.sh" --check >/dev/null 2>&1; then
  fail "check mode accepted stale manifest after captured image"
fi

SCREENSHOT_DIR="$SCREENSHOT_DIR" SCREENSHOT_MANIFEST_FILE="$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md" \
  bash "$ROOT_DIR/script/sync_screenshot_manifest_status.sh" >/dev/null
grep -q '| `writing` | `writing.png` | Writing workspace | Markdown editing, preview, metadata, and contextual writing actions. | Captured 1440x900 |' \
  "$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md" || fail "captured screenshot status was not written"

SCREENSHOT_DIR="$SCREENSHOT_DIR" SCREENSHOT_MANIFEST_FILE="$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md" \
  bash "$ROOT_DIR/script/sync_screenshot_manifest_status.sh" --check >/dev/null

create_png "$SCREENSHOT_DIR/ai-chat.png" 10 10
SCREENSHOT_DIR="$SCREENSHOT_DIR" SCREENSHOT_MANIFEST_FILE="$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md" \
  bash "$ROOT_DIR/script/sync_screenshot_manifest_status.sh" >/dev/null
grep -q '| `ai-chat` | `ai-chat.png` | AI assistant Inspector | Keep the article editor visible while showing conversation, context, quick prompts, and apply actions. | Invalid: 10x10 is not an accepted Mac App Store size |' \
  "$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md" || fail "invalid screenshot status was not written"

create_png "$SCREENSHOT_DIR/sync-api-publish.png" 1440 900
printf '/Users/example/private-site/content/post.md' >>"$SCREENSHOT_DIR/sync-api-publish.png"
SCREENSHOT_DIR="$SCREENSHOT_DIR" SCREENSHOT_MANIFEST_FILE="$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md" \
  bash "$ROOT_DIR/script/sync_screenshot_manifest_status.sh" >/dev/null
grep -q '| `sync-api-publish` | `sync-api-publish.png` | Sync workspace | GitHub/GitLab token check, remote conflict preview, direct API publish, and PR/MR flow. | Invalid: possible private content (local path) |' \
  "$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md" || fail "local path privacy status was not written"

create_png "$SCREENSHOT_DIR/seo-social-preview.png" 1440 900
printf 'github_pat_abcdefghijklmnopqrstuvwxyz1234567890' >>"$SCREENSHOT_DIR/seo-social-preview.png"
SCREENSHOT_DIR="$SCREENSHOT_DIR" SCREENSHOT_MANIFEST_FILE="$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md" \
  bash "$ROOT_DIR/script/sync_screenshot_manifest_status.sh" >/dev/null
grep -q '| `seo-social-preview` | `seo-social-preview.png` | SEO/social preview | Search, Open Graph, Twitter card, cache state, and manual refresh. | Invalid: possible private content (token-like secret) |' \
  "$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md" || fail "token privacy status was not written"

dry_run="$TMP_DIR/dry-run.md"
SCREENSHOT_DIR="$SCREENSHOT_DIR" SCREENSHOT_MANIFEST_FILE="$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md" \
  bash "$ROOT_DIR/script/sync_screenshot_manifest_status.sh" --dry-run >"$dry_run"
grep -q 'Captured 1440x900' "$dry_run" || fail "dry-run did not print synchronized manifest"

echo "screenshot manifest sync test: passed"
