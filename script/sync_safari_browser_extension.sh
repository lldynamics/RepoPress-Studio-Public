#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHROMIUM_DIR="$ROOT_DIR/BrowserExtension"
SAFARI_DIR="$CHROMIUM_DIR/Safari"
MODE="${1:-sync}"
SHARED_FILES=(
  protocol.generated.js
  background-capture.js
  background-queue-operations.js
  background-queue-storage.js
  background-security.js
  background.js
  popup.js
  popup.html
  popup.css
  _locales/en/messages.json
  _locales/zh_CN/messages.json
  icons/icon16.png
  icons/icon32.png
  icons/icon48.png
  icons/icon128.png
)

[[ -f "$SAFARI_DIR/manifest.json" ]] || {
  echo "Safari extension manifest is missing: $SAFARI_DIR/manifest.json" >&2
  exit 1
}

case "$MODE" in
  sync)
    for file in "${SHARED_FILES[@]}"; do
      mkdir -p "$(dirname "$SAFARI_DIR/$file")"
      cp "$CHROMIUM_DIR/$file" "$SAFARI_DIR/$file"
    done
    echo "Safari browser extension assets synchronized."
    ;;
  --check|check)
    for file in "${SHARED_FILES[@]}"; do
      cmp -s "$CHROMIUM_DIR/$file" "$SAFARI_DIR/$file" || {
        echo "Safari extension asset is out of sync: $file" >&2
        exit 1
      }
    done
    echo "Safari browser extension assets: synchronized"
    ;;
  *)
    echo "usage: $0 [sync|--check]" >&2
    exit 2
    ;;
esac
