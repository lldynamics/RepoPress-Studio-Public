#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="$ROOT_DIR/script/record_app_store_archive_validation_bundle.sh"
ENV_TEMPLATE="$ROOT_DIR/docs/release-evidence/app-store-archive-validation.env.example"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-archive-bundle.XXXXXX)"
EVIDENCE_FILE="$TMP_DIR/APP_STORE_ARCHIVE_VALIDATION.md"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "app store archive evidence bundle test: $*" >&2
  exit 1
}

[[ -f "$BUNDLE" ]] || fail "record_app_store_archive_validation_bundle.sh is missing"
[[ -f "$ENV_TEMPLATE" ]] || fail "app store archive validation env template is missing"
cp "$ROOT_DIR/docs/release-evidence/APP_STORE_ARCHIVE_VALIDATION.md" "$EVIDENCE_FILE"

template_text="$(cat "$ENV_TEMPLATE")"
template_required_markers=(
  "APP_STORE_ARCHIVE_CLEAN_RELEASE_SUMMARY"
  "APP_STORE_ARCHIVE_SIGNING_RUNTIME_SUMMARY"
  "APP_STORE_ARCHIVE_TRANSPORTER_SUMMARY"
  "APP_STORE_ARCHIVE_EVIDENCE_FILE"
  "record_app_store_archive_validation_bundle.sh"
  "sync_app_store_checklist.sh"
)
for marker in "${template_required_markers[@]}"; do
  [[ "$template_text" == *"$marker"* ]] || fail "env template missing marker: $marker"
done

if grep -Eq '(/Users/|/Volumes/|file:///Users/|file:///Volumes/|github_pat_|ghp_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{20,}|Authorization:[[:space:]]*Bearer|Apple[[:space:]]*ID|TeamIdentifier=|Receipt[[:space:]]*ID|receipt[[:space:]]*id)' "$ENV_TEMPLATE"; then
  fail "env template contains private-looking archive validation content"
fi

dry_output="$(APP_STORE_ARCHIVE_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$BUNDLE" --dry-run)"
grep -q "app store archive evidence bundle: dry-run" <<<"$dry_output" || fail "dry-run did not print header"
grep -q "clean release archive: default-summary" <<<"$dry_output" || fail "dry-run omitted clean archive default"
grep -q "distribution signing/runtime: default-summary" <<<"$dry_output" || fail "dry-run omitted signing default"
grep -q "transporter validation: default-summary" <<<"$dry_output" || fail "dry-run omitted transporter default"

if APP_STORE_ARCHIVE_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$BUNDLE" --execute >/dev/null 2>&1; then
  fail "--execute accepted missing evidence summaries"
fi

if APP_STORE_ARCHIVE_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$BUNDLE" \
  --clean-release-archive "Clean Release archive was produced from /Users/example/archive." \
  --distribution-signing-runtime "Distribution signature and hardened runtime verified." \
  --transporter-validation "Transporter validation succeeded." \
  --execute >/dev/null 2>&1; then
  fail "--execute accepted a private local path in evidence"
fi

APP_STORE_ARCHIVE_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$BUNDLE" \
  --clean-release-archive "Clean Release archive produced from a fresh checkout and reproducible release command." \
  --distribution-signing-runtime "Distribution signature verified and hardened runtime flag confirmed on the archive." \
  --transporter-validation "Archive validated successfully in Transporter before upload; no private account identifiers recorded." \
  --execute >/dev/null

grep -q "^- \\[x\\] Clean Release archive produced from a clean checkout." "$EVIDENCE_FILE" \
  || fail "clean release archive item was not completed"
grep -q "^- \\[x\\] Distribution signing and hardened runtime verified on the archive." "$EVIDENCE_FILE" \
  || fail "distribution signing/runtime item was not completed"
grep -q "^- \\[x\\] Archive validated with App Store Connect or Transporter before upload." "$EVIDENCE_FILE" \
  || fail "transporter validation item was not completed"

STRICT_ARCHIVE_EVIDENCE_ONLY=1 APP_STORE_ARCHIVE_EVIDENCE_FILE="$EVIDENCE_FILE" \
  bash "$ROOT_DIR/script/check_app_store_archive_readiness.sh" --dry-run >/dev/null

echo "app store archive evidence bundle test: passed"
