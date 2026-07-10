#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-archive-evidence.XXXXXX)"
EVIDENCE_FILE="$TMP_DIR/APP_STORE_ARCHIVE_VALIDATION.md"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "app store archive evidence test: $*" >&2
  exit 1
}

cp "$ROOT_DIR/docs/release-evidence/APP_STORE_ARCHIVE_VALIDATION.md" "$EVIDENCE_FILE"

if APP_STORE_ARCHIVE_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/record_app_store_archive_validation_evidence.sh" \
  --item transporter-validation \
  --summary "/Users/example/archive validated" \
  --dry-run >/dev/null 2>&1; then
  fail "archive evidence accepted a local filesystem path"
fi

legacy_file="$TMP_DIR/legacy.md"
cp "$ROOT_DIR/docs/release-evidence/APP_STORE_ARCHIVE_VALIDATION.md" "$legacy_file"
python3 - "$legacy_file" <<'PY'
from pathlib import Path

path = Path(__import__("sys").argv[1])
text = path.read_text().replace(
    "- [ ] Archive validated with App Store Connect or Transporter before upload.\n  Evidence:",
    "- [x] Archive validated with App Store Connect or Transporter before upload.\n  Evidence:",
)
path.write_text(text)
PY
if APP_STORE_ARCHIVE_EVIDENCE_FILE="$legacy_file" bash "$ROOT_DIR/script/check_app_store_archive_readiness.sh" --dry-run >/dev/null 2>&1; then
  :
fi
if STRICT_ARCHIVE_EVIDENCE_ONLY=1 APP_STORE_ARCHIVE_EVIDENCE_FILE="$legacy_file" \
  bash "$ROOT_DIR/script/check_app_store_archive_readiness.sh" --dry-run >/dev/null 2>&1; then
  fail "archive evidence strict check accepted an empty Evidence field"
fi

record() {
  APP_STORE_ARCHIVE_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/record_app_store_archive_validation_evidence.sh" "$@" --execute >/dev/null
}

record --item clean-release-archive \
  --summary "Clean Release archive produced from a fresh checkout and reproducible release command."
record --item distribution-signing-runtime \
  --summary "Distribution signature verified and hardened runtime flag confirmed on the archive."
record --item transporter-validation \
  --summary "Archive validated successfully in Transporter before upload; no private account identifiers recorded."

STRICT_ARCHIVE_EVIDENCE_ONLY=1 APP_STORE_ARCHIVE_EVIDENCE_FILE="$EVIDENCE_FILE" \
  bash "$ROOT_DIR/script/check_app_store_archive_readiness.sh" --dry-run >/dev/null

echo "app store archive evidence test: passed"
