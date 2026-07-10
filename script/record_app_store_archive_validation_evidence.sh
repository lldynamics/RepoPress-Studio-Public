#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_FILE="${APP_STORE_ARCHIVE_EVIDENCE_FILE:-$ROOT_DIR/docs/release-evidence/APP_STORE_ARCHIVE_VALIDATION.md}"
ITEM_ID=""
SUMMARY=""
EXECUTE=0

usage() {
  cat <<'USAGE'
Usage: script/record_app_store_archive_validation_evidence.sh --item <id> --summary <text> --execute
       script/record_app_store_archive_validation_evidence.sh --dry-run

Records redacted App Store archive validation evidence. Use only after the
external archive/signing/upload validation has actually been performed.

Allowed item IDs:
  clean-release-archive
  distribution-signing-runtime
  transporter-validation

Examples:
  script/record_app_store_archive_validation_evidence.sh --dry-run

  script/record_app_store_archive_validation_evidence.sh \
    --item transporter-validation \
    --summary "Archive validated successfully in Transporter; no account identifiers or receipt IDs recorded." \
    --execute
USAGE
}

fail() {
  echo "app store archive evidence recorder: $*" >&2
  exit 1
}

title_for_id() {
  case "$1" in
    clean-release-archive) echo "Clean Release archive produced from a clean checkout." ;;
    distribution-signing-runtime) echo "Distribution signing and hardened runtime verified on the archive." ;;
    transporter-validation) echo "Archive validated with App Store Connect or Transporter before upload." ;;
    *) fail "unsupported item id: $1" ;;
  esac
}

reject_private_content() {
  local value="$1"
  local label="$2"
  if printf "%s" "$value" | grep -Eq '(/Users/|/Volumes/|file:///Users/|file:///Volumes/)'; then
    fail "$label contains a local filesystem path"
  fi
  if printf "%s" "$value" | grep -Eq '(github_pat_|ghp_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{20,}|Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._-]{20,})'; then
    fail "$label contains a token-like secret"
  fi
  if printf "%s" "$value" | grep -Eq '([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|Apple[[:space:]]*ID|TeamIdentifier=|Receipt[[:space:]]*ID|receipt[[:space:]]*id)'; then
    fail "$label contains account, team, or receipt-like private content"
  fi
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --item)
      [[ "$#" -ge 2 ]] || fail "--item requires an evidence item ID"
      ITEM_ID="$2"
      shift 2
      ;;
    --summary)
      [[ "$#" -ge 2 ]] || fail "--summary requires text"
      SUMMARY="$2"
      shift 2
      ;;
    --execute)
      EXECUTE=1
      shift
      ;;
    --dry-run)
      EXECUTE=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -f "$EVIDENCE_FILE" ]] || fail "evidence file is missing: ${EVIDENCE_FILE#$ROOT_DIR/}"

if [[ -z "$ITEM_ID" && "$EXECUTE" == "0" ]]; then
  echo "app store archive evidence recorder: ready"
  echo "- evidence file: ${EVIDENCE_FILE#$ROOT_DIR/}"
  echo "- allowed items: 3"
  exit 0
fi

[[ -n "$ITEM_ID" ]] || fail "--item is required"
TITLE="$(title_for_id "$ITEM_ID")"
[[ -n "${SUMMARY//[[:space:]]/}" ]] || fail "--summary is required"
reject_private_content "$SUMMARY" "summary"

if [[ "$EXECUTE" != "1" ]]; then
  echo "app store archive evidence recorder: dry-run"
  echo "- item: $ITEM_ID"
  echo "- title: $TITLE"
  echo "- evidence file: ${EVIDENCE_FILE#$ROOT_DIR/}"
  echo "- execute: pass --execute to write the completed archive evidence item"
  exit 0
fi

python3 - "$EVIDENCE_FILE" "$TITLE" "$SUMMARY" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
title, summary = sys.argv[2:4]
text = path.read_text()
pattern = re.compile(
    rf"^- \[[ xX]\] {re.escape(title)}\n(?:[ \t]*Evidence:.*\n?)?",
    re.MULTILINE,
)
replacement = f"- [x] {title}\n  Evidence: {summary}\n"
if pattern.search(text):
    text = pattern.sub(replacement, text, count=1)
else:
    text = text.rstrip() + "\n" + replacement
path.write_text(text)
PY

echo "app store archive evidence recorder: recorded $ITEM_ID"
echo "- updated: ${EVIDENCE_FILE#$ROOT_DIR/}"
