#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECORDER="$ROOT_DIR/script/record_clean_runtime_evidence.sh"
EVIDENCE_FILE="${CLEAN_RUNTIME_EVIDENCE_FILE:-$ROOT_DIR/docs/release-evidence/CLEAN_RUNTIME_VALIDATION.md}"
CLEAN_LAUNCH=""
PRIVACY_SETTINGS_WORKSPACE=""
ACCESSIBILITY_KEYBOARD_SMOKE=""
EXECUTE=0

usage() {
  cat <<'USAGE'
Usage: script/record_clean_runtime_evidence_bundle.sh \
  --clean-launch <summary> \
  --privacy-settings-workspace <summary> \
  --accessibility-keyboard-smoke <summary> \
  --execute

       script/record_clean_runtime_evidence_bundle.sh --dry-run

Records all three clean-user runtime evidence items after the clean account or
equivalent test-user smoke run has actually been performed. It delegates each
item to script/record_clean_runtime_evidence.sh so the same redaction rules and
evidence-file format are used.
USAGE
}

fail() {
  echo "clean runtime evidence bundle: $*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --clean-launch)
      [[ "$#" -ge 2 ]] || fail "--clean-launch requires text"
      CLEAN_LAUNCH="$2"
      shift 2
      ;;
    --privacy-settings-workspace)
      [[ "$#" -ge 2 ]] || fail "--privacy-settings-workspace requires text"
      PRIVACY_SETTINGS_WORKSPACE="$2"
      shift 2
      ;;
    --accessibility-keyboard-smoke)
      [[ "$#" -ge 2 ]] || fail "--accessibility-keyboard-smoke requires text"
      ACCESSIBILITY_KEYBOARD_SMOKE="$2"
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

[[ -f "$RECORDER" ]] || fail "missing script/record_clean_runtime_evidence.sh"
[[ -f "$EVIDENCE_FILE" ]] || fail "evidence file is missing: ${EVIDENCE_FILE#$ROOT_DIR/}"

require_execute_summary() {
  local value="$1"
  local flag="$2"
  [[ -n "${value//[[:space:]]/}" ]] || fail "$flag is required with --execute"
}

if [[ "$EXECUTE" == "1" ]]; then
  require_execute_summary "$CLEAN_LAUNCH" "--clean-launch"
  require_execute_summary "$PRIVACY_SETTINGS_WORKSPACE" "--privacy-settings-workspace"
  require_execute_summary "$ACCESSIBILITY_KEYBOARD_SMOKE" "--accessibility-keyboard-smoke"
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

clean_launch_summary="$(summary_for "$CLEAN_LAUNCH" "Clean test user launched the app through build_and_run --verify and reached the main workspace without migration or permission failures.")"
privacy_summary="$(summary_for "$PRIVACY_SETTINGS_WORKSPACE" "First launch, privacy lock, settings, and workspace switching were verified with sample data and redacted screenshots only.")"
accessibility_summary="$(summary_for "$ACCESSIBILITY_KEYBOARD_SMOKE" "Keyboard navigation, visible focus, VoiceOver labels, and primary menu commands were smoke checked in the running app.")"

record_item() {
  local item="$1"
  local summary="$2"
  if [[ "$EXECUTE" == "1" ]]; then
    CLEAN_RUNTIME_EVIDENCE_FILE="$EVIDENCE_FILE" \
      bash "$RECORDER" --item "$item" --summary "$summary" --execute >/dev/null
  else
    CLEAN_RUNTIME_EVIDENCE_FILE="$EVIDENCE_FILE" \
      bash "$RECORDER" --item "$item" --summary "$summary" --dry-run >/dev/null
  fi
}

if [[ "$EXECUTE" == "0" ]]; then
  echo "clean runtime evidence bundle: dry-run"
  echo "- evidence file: ${EVIDENCE_FILE#$ROOT_DIR/}"
  echo "- clean launch: $([[ -n "${CLEAN_LAUNCH//[[:space:]]/}" ]] && echo provided || echo default-summary)"
  echo "- privacy/settings/workspace: $([[ -n "${PRIVACY_SETTINGS_WORKSPACE//[[:space:]]/}" ]] && echo provided || echo default-summary)"
  echo "- accessibility/keyboard smoke: $([[ -n "${ACCESSIBILITY_KEYBOARD_SMOKE//[[:space:]]/}" ]] && echo provided || echo default-summary)"
  echo "- execute: pass --execute only after the clean-user runtime smoke test is complete"
fi

record_item clean-launch "$clean_launch_summary"
record_item privacy-settings-workspace "$privacy_summary"
record_item accessibility-keyboard-smoke "$accessibility_summary"

if [[ "$EXECUTE" == "1" ]]; then
  CLEAN_RUNTIME_EVIDENCE_FILE="$EVIDENCE_FILE" \
    bash "$ROOT_DIR/script/check_clean_runtime_evidence.sh" --strict >/dev/null
  echo "clean runtime evidence bundle: recorded clean launch, privacy/settings/workspace, and accessibility smoke evidence"
fi
