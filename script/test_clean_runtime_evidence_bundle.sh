#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="$ROOT_DIR/script/record_clean_runtime_evidence_bundle.sh"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-clean-runtime-bundle.XXXXXX)"
EVIDENCE_FILE="$TMP_DIR/CLEAN_RUNTIME_VALIDATION.md"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "clean runtime evidence bundle test: $*" >&2
  exit 1
}

[[ -f "$BUNDLE" ]] || fail "record_clean_runtime_evidence_bundle.sh is missing"
cat >"$EVIDENCE_FILE" <<'MD'
# Clean Runtime Validation Evidence

This file records a real clean-user runtime smoke test. Do not paste local
filesystem paths, Apple IDs, emails, account names, tokens, private article
text, or screenshots containing private content.

- [ ] App launched from `script/build_and_run.sh --verify` on a clean macOS account or equivalent test user.
  Evidence:
- [ ] First launch, privacy lock, settings, and workspace switching were verified without exposing private content.
  Evidence:
- [ ] Keyboard navigation, focus visibility, VoiceOver labels, and primary commands were smoke checked in the running app.
  Evidence:
MD

dry_output="$(CLEAN_RUNTIME_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$BUNDLE" --dry-run)"
grep -q "clean runtime evidence bundle: dry-run" <<<"$dry_output" || fail "dry-run did not print header"
grep -q "clean launch: default-summary" <<<"$dry_output" || fail "dry-run omitted clean launch default"
grep -q "privacy/settings/workspace: default-summary" <<<"$dry_output" || fail "dry-run omitted privacy default"
grep -q "accessibility/keyboard smoke: default-summary" <<<"$dry_output" || fail "dry-run omitted accessibility default"

if CLEAN_RUNTIME_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$BUNDLE" --execute >/dev/null 2>&1; then
  fail "--execute accepted missing evidence summaries"
fi

if CLEAN_RUNTIME_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$BUNDLE" \
  --clean-launch "Launched from /Users/example/private workspace." \
  --privacy-settings-workspace "Privacy lock and settings were smoke checked." \
  --accessibility-keyboard-smoke "Keyboard navigation was smoke checked." \
  --execute >/dev/null 2>&1; then
  fail "--execute accepted a private local path in evidence"
fi

CLEAN_RUNTIME_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$BUNDLE" \
  --clean-launch "Clean test user launched the app through build_and_run --verify and reached the main workspace without migration or permission failures." \
  --privacy-settings-workspace "First launch, privacy lock, settings, and workspace switching were verified with sample data and redacted screenshots only." \
  --accessibility-keyboard-smoke "Keyboard navigation, visible focus, VoiceOver labels, and primary menu commands were smoke checked in the running app." \
  --execute >/dev/null

grep -q '^- \[x\] App launched from `script/build_and_run.sh --verify` on a clean macOS account or equivalent test user.' "$EVIDENCE_FILE" \
  || fail "clean launch item was not completed"
grep -q "^- \\[x\\] First launch, privacy lock, settings, and workspace switching were verified without exposing private content." "$EVIDENCE_FILE" \
  || fail "privacy/settings/workspace item was not completed"
grep -q "^- \\[x\\] Keyboard navigation, focus visibility, VoiceOver labels, and primary commands were smoke checked in the running app." "$EVIDENCE_FILE" \
  || fail "accessibility/keyboard smoke item was not completed"

CLEAN_RUNTIME_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/check_clean_runtime_evidence.sh" --strict >/dev/null

echo "clean runtime evidence bundle test: passed"
