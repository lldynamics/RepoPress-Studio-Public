#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/dist/browser-extension}"

"$ROOT_DIR/script/sync_firefox_browser_extension.sh" --check
exec python3 "$ROOT_DIR/script/firefox_extension_release.py" package --output-dir "$OUTPUT_DIR"
