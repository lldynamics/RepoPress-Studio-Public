#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/dist/browser-extension}"
LEDGER_MODE="${2:-record-ledger}"

case "$LEDGER_MODE" in
  record-ledger)
    ;;
  --no-record-ledger)
    ;;
  *)
    echo "usage: $0 [output-directory] [--no-record-ledger]" >&2
    exit 2
    ;;
esac

python3 "$ROOT_DIR/script/generate_browser_extension_protocol.py" --check
"$ROOT_DIR/script/sync_firefox_browser_extension.sh" --check
if [[ "$LEDGER_MODE" == "--no-record-ledger" ]]; then
  exec python3 "$ROOT_DIR/script/firefox_extension_release.py" package \
    --output-dir "$OUTPUT_DIR" \
    --no-record-ledger
fi
exec python3 "$ROOT_DIR/script/firefox_extension_release.py" package \
  --output-dir "$OUTPUT_DIR"
