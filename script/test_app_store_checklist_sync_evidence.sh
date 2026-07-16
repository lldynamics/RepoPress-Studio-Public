#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-checklist-sync.XXXXXX)"
CHECKLIST_FILE="$TMP_DIR/APP_STORE_CHECKLIST.md"
EXTERNAL_FILE="$TMP_DIR/EXTERNAL_VERIFICATION_EVIDENCE.md"
ARCHIVE_FILE="$TMP_DIR/APP_STORE_ARCHIVE_VALIDATION.md"
SCREENSHOT_DIR="$TMP_DIR/app-store-screenshots"
SCREENSHOT_MANIFEST_FILE="$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "app store checklist sync evidence test: $*" >&2
  exit 1
}

cp "$ROOT_DIR/APP_STORE_CHECKLIST.md" "$CHECKLIST_FILE"
cp "$ROOT_DIR/docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md" "$EXTERNAL_FILE"
cp "$ROOT_DIR/docs/release-evidence/APP_STORE_ARCHIVE_VALIDATION.md" "$ARCHIVE_FILE"
mkdir -p "$SCREENSHOT_DIR"
cp "$ROOT_DIR/docs/app-store-screenshots/SCREENSHOT_MANIFEST.md" "$SCREENSHOT_MANIFEST_FILE"

python3 - "$EXTERNAL_FILE" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = re.sub(
    r"^- \[ \] `storekit-sandbox` - .*$",
    "- [x] `storekit-sandbox` - Legacy StoreKit evidence without structured fields.",
    text,
    count=1,
    flags=re.MULTILINE,
)
path.write_text(text)
PY

if APP_STORE_CHECKLIST_FILE="$CHECKLIST_FILE" \
  EXTERNAL_VERIFY_EVIDENCE_FILE="$EXTERNAL_FILE" \
  APP_STORE_ARCHIVE_EVIDENCE_FILE="$ARCHIVE_FILE" \
  SCREENSHOT_DIR="$SCREENSHOT_DIR" \
  SCREENSHOT_MANIFEST_FILE="$SCREENSHOT_MANIFEST_FILE" \
  bash "$ROOT_DIR/script/sync_app_store_checklist.sh" --dry-run >/dev/null 2>&1; then
  fail "checklist sync accepted legacy external evidence without structured fields"
fi

cp "$ROOT_DIR/docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md" "$EXTERNAL_FILE"
cat >"$CHECKLIST_FILE" <<'MD'
# App Store Release Checklist

## Build And Signing

- [ ] Confirm bundle identifier, version, build number, minimum macOS, and sandbox entitlements.
- [ ] Confirm distribution signing team and hardened runtime on the archived app.
MD

metadata_sync_output="$(
  APP_STORE_CHECKLIST_FILE="$CHECKLIST_FILE" \
    EXTERNAL_VERIFY_EVIDENCE_FILE="$EXTERNAL_FILE" \
    APP_STORE_ARCHIVE_EVIDENCE_FILE="$ARCHIVE_FILE" \
    SCREENSHOT_DIR="$SCREENSHOT_DIR" \
    SCREENSHOT_MANIFEST_FILE="$SCREENSHOT_MANIFEST_FILE" \
    bash "$ROOT_DIR/script/sync_app_store_checklist.sh" --dry-run
)"
grep -q "Confirm bundle identifier, version, build number, minimum macOS, and sandbox entitlements." <<<"$metadata_sync_output" \
  || fail "checklist sync did not treat local App Store metadata as evidence-backed"
if grep -q "Confirm distribution signing team and hardened runtime on the archived app." <<<"$metadata_sync_output"; then
  fail "checklist sync marked signing/runtime complete without archive evidence"
fi

python3 - "$ARCHIVE_FILE" <<'PY'
from pathlib import Path

path = Path(__import__("sys").argv[1])
text = path.read_text()
text = text.replace(
    "- [ ] Clean Release archive produced from a clean checkout.\n  Evidence:",
    "- [x] Clean Release archive produced from a clean checkout.\n  Evidence:",
)
text = text.replace(
    "- [ ] Distribution signing and hardened runtime verified on the archive.\n  Evidence:",
    "- [x] Distribution signing and hardened runtime verified on the archive.\n  Evidence:",
)
text = text.replace(
    "- [ ] Archive validated with App Store Connect or Transporter before upload.\n  Evidence:",
    "- [x] Archive validated with App Store Connect or Transporter before upload.\n  Evidence:",
)
path.write_text(text)
PY

if APP_STORE_CHECKLIST_FILE="$CHECKLIST_FILE" \
  EXTERNAL_VERIFY_EVIDENCE_FILE="$EXTERNAL_FILE" \
  APP_STORE_ARCHIVE_EVIDENCE_FILE="$ARCHIVE_FILE" \
  SCREENSHOT_DIR="$SCREENSHOT_DIR" \
  SCREENSHOT_MANIFEST_FILE="$SCREENSHOT_MANIFEST_FILE" \
  bash "$ROOT_DIR/script/sync_app_store_checklist.sh" --dry-run >/dev/null 2>&1; then
  fail "checklist sync accepted archive evidence with empty Evidence fields"
fi

echo "app store checklist sync evidence test: passed"
