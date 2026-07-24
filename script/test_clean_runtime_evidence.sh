#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-clean-runtime-evidence.XXXXXX)"
EVIDENCE_FILE="$TMP_DIR/CLEAN_RUNTIME_VALIDATION.md"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "clean runtime evidence test: $*" >&2
  exit 1
}

write_fixture() {
  local path="$1"
  cat >"$path" <<'MD'
# Clean Runtime Validation Evidence

This file records a real clean-user runtime smoke test. Do not paste local
filesystem paths, Apple IDs, emails, account names, tokens, private article
text, or screenshots containing private content.

- [ ] App launched from `script/build_and_run.sh --verify` on a clean macOS account or equivalent test user.
  Evidence:
- [ ] Quick hide, private-content masking, settings, and workspace switching were verified without exposing private content.
  Evidence:
- [ ] Keyboard navigation, focus visibility, VoiceOver labels, and primary commands were smoke checked in the running app.
  Evidence:
MD
}

write_fixture "$EVIDENCE_FILE"

CLEAN_RUNTIME_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/check_clean_runtime_evidence.sh" >/dev/null

if CLEAN_RUNTIME_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/record_clean_runtime_evidence.sh" \
  --item clean-launch \
  --summary "/Users/example launched the app" \
  --dry-run >/dev/null 2>&1; then
  fail "clean runtime evidence accepted a local filesystem path"
fi

legacy_file="$TMP_DIR/legacy.md"
write_fixture "$legacy_file"
python3 - "$legacy_file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8").replace(
    "- [ ] App launched from `script/build_and_run.sh --verify` on a clean macOS account or equivalent test user.\n  Evidence:",
    "- [x] App launched from `script/build_and_run.sh --verify` on a clean macOS account or equivalent test user.\n  Evidence:",
)
path.write_text(text, encoding="utf-8")
PY
if CLEAN_RUNTIME_EVIDENCE_FILE="$legacy_file" bash "$ROOT_DIR/script/check_clean_runtime_evidence.sh" --strict >/dev/null 2>&1; then
  fail "strict clean runtime check accepted an empty Evidence field"
fi

record() {
  CLEAN_RUNTIME_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/record_clean_runtime_evidence.sh" "$@" --execute >/dev/null
}

record --item clean-launch \
  --summary "Clean test user launched the app through build_and_run --verify and reached the main workspace without migration or permission failures."
record --item privacy-settings-workspace \
  --summary "Quick hide, private-content masking, settings, and workspace switching were verified with sample data and redacted screenshots only."
record --item accessibility-keyboard-smoke \
  --summary "Keyboard navigation, visible focus, VoiceOver labels, and primary menu commands were smoke checked in the running app."

CLEAN_RUNTIME_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/check_clean_runtime_evidence.sh" --strict >/dev/null

echo "clean runtime evidence test: passed"
