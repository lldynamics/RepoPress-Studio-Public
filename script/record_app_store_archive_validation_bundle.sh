#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECORDER="$ROOT_DIR/script/record_app_store_archive_validation_evidence.sh"
EVIDENCE_FILE="${APP_STORE_ARCHIVE_EVIDENCE_FILE:-$ROOT_DIR/docs/release-evidence/APP_STORE_ARCHIVE_VALIDATION.md}"
CLEAN_RELEASE_ARCHIVE=""
DISTRIBUTION_SIGNING_RUNTIME=""
TRANSPORTER_VALIDATION=""
EXECUTE=0

usage() {
  cat <<'USAGE'
Usage: script/record_app_store_archive_validation_bundle.sh \
  --clean-release-archive <summary> \
  --distribution-signing-runtime <summary> \
  --transporter-validation <summary> \
  --execute

       script/record_app_store_archive_validation_bundle.sh --dry-run

Records all three App Store archive/upload validation evidence items after the
external validation has actually been performed. It delegates each item to
script/record_app_store_archive_validation_evidence.sh so the same redaction
rules and evidence-file format are used.
USAGE
}

fail() {
  echo "app store archive evidence bundle: $*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --clean-release-archive)
      [[ "$#" -ge 2 ]] || fail "--clean-release-archive requires text"
      CLEAN_RELEASE_ARCHIVE="$2"
      shift 2
      ;;
    --distribution-signing-runtime)
      [[ "$#" -ge 2 ]] || fail "--distribution-signing-runtime requires text"
      DISTRIBUTION_SIGNING_RUNTIME="$2"
      shift 2
      ;;
    --transporter-validation)
      [[ "$#" -ge 2 ]] || fail "--transporter-validation requires text"
      TRANSPORTER_VALIDATION="$2"
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
      usage
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -f "$RECORDER" ]] || fail "missing script/record_app_store_archive_validation_evidence.sh"
[[ -f "$EVIDENCE_FILE" ]] || fail "evidence file is missing: ${EVIDENCE_FILE#$ROOT_DIR/}"

require_execute_summary() {
  local value="$1"
  local flag="$2"
  [[ -n "${value//[[:space:]]/}" ]] || fail "$flag is required with --execute"
}

if [[ "$EXECUTE" == "1" ]]; then
  require_execute_summary "$CLEAN_RELEASE_ARCHIVE" "--clean-release-archive"
  require_execute_summary "$DISTRIBUTION_SIGNING_RUNTIME" "--distribution-signing-runtime"
  require_execute_summary "$TRANSPORTER_VALIDATION" "--transporter-validation"
fi

summary_for() {
  local explicit="$1"
  local fallback="$2"
  if [[ -n "${explicit//[[:space:]]/}" ]]; then
    printf "%s" "$explicit"
  else
    printf "%s" "$fallback"
  fi
}

clean_summary="$(summary_for "$CLEAN_RELEASE_ARCHIVE" "Clean Release archive produced from a fresh checkout and reproducible release command.")"
signing_summary="$(summary_for "$DISTRIBUTION_SIGNING_RUNTIME" "Distribution signature verified and hardened runtime flag confirmed on the archive.")"
transporter_summary="$(summary_for "$TRANSPORTER_VALIDATION" "Archive validated successfully in Transporter before upload; no private account identifiers recorded.")"

record_item() {
  local item="$1"
  local summary="$2"
  if [[ "$EXECUTE" == "1" ]]; then
    APP_STORE_ARCHIVE_EVIDENCE_FILE="$EVIDENCE_FILE" \
      bash "$RECORDER" --item "$item" --summary "$summary" --execute >/dev/null
  else
    APP_STORE_ARCHIVE_EVIDENCE_FILE="$EVIDENCE_FILE" \
      bash "$RECORDER" --item "$item" --summary "$summary" --dry-run >/dev/null
  fi
}

if [[ "$EXECUTE" == "0" ]]; then
  echo "app store archive evidence bundle: dry-run"
  echo "- evidence file: ${EVIDENCE_FILE#$ROOT_DIR/}"
  echo "- clean release archive: $([[ -n "${CLEAN_RELEASE_ARCHIVE//[[:space:]]/}" ]] && echo provided || echo default-summary)"
  echo "- distribution signing/runtime: $([[ -n "${DISTRIBUTION_SIGNING_RUNTIME//[[:space:]]/}" ]] && echo provided || echo default-summary)"
  echo "- transporter validation: $([[ -n "${TRANSPORTER_VALIDATION//[[:space:]]/}" ]] && echo provided || echo default-summary)"
  echo "- execute: pass --execute only after the external archive validation is complete"
fi

record_item clean-release-archive "$clean_summary"
record_item distribution-signing-runtime "$signing_summary"
record_item transporter-validation "$transporter_summary"

if [[ "$EXECUTE" == "1" ]]; then
  STRICT_ARCHIVE_EVIDENCE_ONLY=1 APP_STORE_ARCHIVE_EVIDENCE_FILE="$EVIDENCE_FILE" \
    bash "$ROOT_DIR/script/check_app_store_archive_readiness.sh" --dry-run >/dev/null
  echo "app store archive evidence bundle: recorded clean archive, signing/runtime, and Transporter validation"
fi
