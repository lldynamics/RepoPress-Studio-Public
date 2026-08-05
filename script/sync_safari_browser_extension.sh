#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-sync}"

case "$MODE" in
  sync|--check|check)
    python3 "$ROOT_DIR/script/build_browser_extension_source.py" --browser safari --check
    echo "Safari browser extension shared source: validated"
    ;;
  *)
    echo "usage: $0 [sync|--check]" >&2
    exit 2
    ;;
esac
