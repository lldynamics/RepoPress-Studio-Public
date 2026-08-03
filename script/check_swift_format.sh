#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINES_PATH="${QUALITY_BASELINES_PATH:-$ROOT_DIR/script/quality_baselines.json}"
LOG_PATH="${SWIFT_FORMAT_LOG_PATH:-$ROOT_DIR/.build/swift-format-lint.log}"

fail() {
  echo "swift-format lint gate: $*" >&2
  exit 1
}

tool_unavailable() {
  echo "swift-format lint gate [environment:tool-unavailable]: $*" >&2
  echo "swift-format lint gate: install is intentionally not attempted; use the swift-format bundled with Xcode." >&2
  exit 69
}

resolve_swift_format() {
  if [[ -n "${SWIFT_FORMAT_BIN:-}" ]]; then
    [[ -x "$SWIFT_FORMAT_BIN" ]] || tool_unavailable "SWIFT_FORMAT_BIN is not executable: $SWIFT_FORMAT_BIN"
    printf '%s\n' "$SWIFT_FORMAT_BIN"
    return
  fi
  if command -v swift-format >/dev/null 2>&1; then
    command -v swift-format
    return
  fi
  if [[ "${SWIFT_FORMAT_DISABLE_XCRUN:-0}" != "1" ]] && command -v xcrun >/dev/null 2>&1; then
    local xcode_tool
    xcode_tool="$(xcrun --find swift-format 2>/dev/null || true)"
    if [[ -n "$xcode_tool" && -x "$xcode_tool" ]]; then
      printf '%s\n' "$xcode_tool"
      return
    fi
  fi
  tool_unavailable "swift-format was not found on PATH or in the active Xcode toolchain"
}

[[ -f "$BASELINES_PATH" ]] || fail "missing quality baseline: $BASELINES_PATH"
warning_maximum="$(
  python3 - "$BASELINES_PATH" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
value = payload.get("swiftFormatWarningMaximum")
if payload.get("schemaVersion") != 1 or not isinstance(value, int) or value < 0:
    raise SystemExit("quality baseline must contain a non-negative integer swiftFormatWarningMaximum")
print(value)
PY
)" || fail "invalid quality baseline"

swift_format="$(resolve_swift_format)"
mkdir -p "$(dirname "$LOG_PATH")"
set +e
"$swift_format" lint --recursive --parallel \
  "$ROOT_DIR/Sources" \
  "$ROOT_DIR/Tests" \
  "$ROOT_DIR/Package.swift" >"$LOG_PATH" 2>&1
tool_status=$?
set -e
if [[ "$tool_status" -ne 0 ]]; then
  sed -n '1,80p' "$LOG_PATH" >&2
  fail "swift-format exited with status $tool_status"
fi

warning_count="$(awk '/: warning: / { count += 1 } END { print count + 0 }' "$LOG_PATH")"
if (( warning_count > warning_maximum )); then
  sed -n '1,80p' "$LOG_PATH" >&2
  fail "warning count increased to $warning_count (progressive baseline: $warning_maximum)"
fi

echo "swift-format lint gate: passed ($warning_count warning(s), progressive maximum $warning_maximum; full log: ${LOG_PATH#$ROOT_DIR/})"
