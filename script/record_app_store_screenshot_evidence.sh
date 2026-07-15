#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$ROOT_DIR/docs/app-store-screenshots}"
MANIFEST_FILE="${SCREENSHOT_MANIFEST_FILE:-$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md}"
FINGERPRINT_SCRIPT="$ROOT_DIR/script/screenshot_evidence_fingerprint.py"
CAPTURE_PROVENANCE_SCRIPT="$ROOT_DIR/script/screenshot_capture_provenance.py"
EXECUTE=0

required_ids=()

load_required_ids() {
  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] && required_ids+=("$id")
  done < <(sed -nE 's/^\| `([^`]+)` \|.*/\1/p' "$MANIFEST_FILE")
  [[ "${#required_ids[@]}" -gt 0 ]] || fail "screenshot manifest contains no required screenshot IDs"
}

joined_required_ids() {
  local joined=""
  local id
  for id in "${required_ids[@]}"; do
    if [[ -n "$joined" ]]; then
      joined="$joined, $id"
    else
      joined="$id"
    fi
  done
  printf "%s" "$joined"
}

usage() {
  cat <<'USAGE'
Usage: script/record_app_store_screenshot_evidence.sh [--execute]
       script/record_app_store_screenshot_evidence.sh --dry-run

Validates the App Store screenshot set with strict screenshot, manifest-sync,
and screenshot privacy gates, then records the structured app-store-screenshots
external verification evidence item.

Use --execute only after all required screenshot images have been captured.
USAGE
}

fail() {
  echo "app store screenshot evidence recorder: $*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
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

[[ -d "$SCREENSHOT_DIR" ]] || fail "screenshot directory is missing: ${SCREENSHOT_DIR#$ROOT_DIR/}"
[[ -f "$MANIFEST_FILE" ]] || fail "screenshot manifest is missing: ${MANIFEST_FILE#$ROOT_DIR/}"
[[ -f "$FINGERPRINT_SCRIPT" ]] || fail "screenshot fingerprint helper is missing"
[[ -f "$CAPTURE_PROVENANCE_SCRIPT" ]] || fail "screenshot capture provenance helper is missing"
load_required_ids
source_fingerprint="$(python3 "$FINGERPRINT_SCRIPT" --root "$ROOT_DIR" --manifest "$MANIFEST_FILE")"

captured_ids=()
missing_ids=()
for id in "${required_ids[@]}"; do
  if find "$SCREENSHOT_DIR" -maxdepth 1 -type f \( -name "$id.png" -o -name "$id.jpg" -o -name "$id.jpeg" \) | grep -q .; then
    captured_ids+=("$id")
  else
    missing_ids+=("$id")
  fi
done

run_strict_gates() {
  python3 "$CAPTURE_PROVENANCE_SCRIPT" check \
    --root "$ROOT_DIR" --manifest "$MANIFEST_FILE" --screenshot-dir "$SCREENSHOT_DIR" >/dev/null || return 1
  SCREENSHOT_DIR="$SCREENSHOT_DIR" SCREENSHOT_MANIFEST_FILE="$MANIFEST_FILE" \
    bash "$ROOT_DIR/script/sync_screenshot_manifest_status.sh" --check >/dev/null || return 1
  SCREENSHOT_DIR="$SCREENSHOT_DIR" STRICT_SCREENSHOTS=1 \
    bash "$ROOT_DIR/script/check_screenshots.sh" >/dev/null || return 1
  SCREENSHOT_DIR="$SCREENSHOT_DIR" \
    bash "$ROOT_DIR/script/check_screenshot_privacy.sh" >/dev/null || return 1
}

if [[ "$EXECUTE" == "0" ]]; then
  echo "app store screenshot evidence recorder: dry-run"
  echo "- screenshot directory: ${SCREENSHOT_DIR#$ROOT_DIR/}"
  echo "- screenshot manifest: ${MANIFEST_FILE#$ROOT_DIR/}"
  echo "- captured screenshots: ${#captured_ids[@]}/${#required_ids[@]}"
  if [[ "${#missing_ids[@]}" -gt 0 ]]; then
    echo "- missing screenshots: ${missing_ids[*]}"
    echo "- execute: capture all screenshots, sync the manifest, then pass --execute"
  else
    if run_strict_gates; then
      echo "- strict screenshot gate: ready"
      echo "- screenshot privacy gate: ready"
      echo "- screenshot source fingerprint: $source_fingerprint"
      echo "- execute: pass --execute to record app-store-screenshots evidence"
    else
      fail "strict screenshot gates are not ready"
    fi
  fi
  exit 0
fi

[[ "${#missing_ids[@]}" -eq 0 ]] || fail "missing screenshot image(s): ${missing_ids[*]}"
run_strict_gates || fail "strict screenshot gates failed"

bash "$ROOT_DIR/script/record_external_verification_evidence.sh" \
  --item app-store-screenshots \
  --summary "${#required_ids[@]} App Store screenshots captured; screenshot privacy and strict screenshot gates passed." \
  --screenshot-set "${APP_STORE_SCREENSHOT_SET_SUMMARY:-Captured manifest screenshot IDs: $(joined_required_ids).}" \
  --screenshot-privacy-gate "${APP_STORE_SCREENSHOT_PRIVACY_GATE_SUMMARY:-check_screenshot_privacy.sh passed with no local paths, tokens, or private article text.}" \
  --screenshot-strict-gate "${APP_STORE_SCREENSHOT_STRICT_GATE_SUMMARY:-STRICT_SCREENSHOTS=1 check_screenshots.sh and screenshot manifest sync passed.}" \
  --screenshot-source-fingerprint "$source_fingerprint" \
  --execute

echo "app store screenshot evidence recorder: recorded app-store-screenshots"
