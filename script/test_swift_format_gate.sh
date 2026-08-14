#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mac-editor-swift-format.XXXXXX" 2>/dev/null || mktemp -d "$ROOT_DIR/.build/tmp/mac-editor-swift-format.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "swift-format lint gate test: $*" >&2
  exit 1
}

cat >"$TMP_DIR/swift-format" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "/fixture/A.swift:1:1: warning: [Fixture] one"
echo "/fixture/B.swift:2:1: warning: [Fixture] two"
STUB
chmod +x "$TMP_DIR/swift-format"

cat >"$TMP_DIR/baseline-pass.json" <<'JSON'
{"schemaVersion":1,"swiftFormatWarningMaximum":2,"sourceLineCoveragePercentMinimum":0}
JSON
QUALITY_BASELINES_PATH="$TMP_DIR/baseline-pass.json" \
SWIFT_FORMAT_BIN="$TMP_DIR/swift-format" \
SWIFT_FORMAT_LOG_PATH="$TMP_DIR/pass.log" \
  bash "$ROOT_DIR/script/check_swift_format.sh" >/dev/null

cat >"$TMP_DIR/baseline-fail.json" <<'JSON'
{"schemaVersion":1,"swiftFormatWarningMaximum":1,"sourceLineCoveragePercentMinimum":0}
JSON
if QUALITY_BASELINES_PATH="$TMP_DIR/baseline-fail.json" \
  SWIFT_FORMAT_BIN="$TMP_DIR/swift-format" \
  SWIFT_FORMAT_LOG_PATH="$TMP_DIR/fail.log" \
    bash "$ROOT_DIR/script/check_swift_format.sh" >/dev/null 2>&1; then
  fail "gate accepted a warning count above the progressive baseline"
fi

if QUALITY_BASELINES_PATH="$TMP_DIR/baseline-pass.json" \
  SWIFT_FORMAT_BIN="$TMP_DIR/missing-swift-format" \
  SWIFT_FORMAT_DISABLE_XCRUN=1 \
    bash "$ROOT_DIR/script/check_swift_format.sh" >"$TMP_DIR/missing.log" 2>&1; then
  fail "gate accepted a missing swift-format executable"
fi
grep -q '\[environment:tool-unavailable\]' "$TMP_DIR/missing.log" \
  || fail "missing tool was not classified as an environment failure"
grep -q 'install is intentionally not attempted' "$TMP_DIR/missing.log" \
  || fail "missing tool path suggested an implicit install"

echo "swift-format lint gate test: passed"
