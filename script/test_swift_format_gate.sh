#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/mac-editor-swift-format.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { echo "swift-format lint gate test: $*" >&2; exit 1; }
FIXTURE="$TMP_DIR/repo"
mkdir -p "$FIXTURE/Sources/TargetA" "$FIXTURE/Tests/TargetATests" "$FIXTURE/Tests/Fixtures"
printf 'let retained = 1\n' >"$FIXTURE/Sources/TargetA/Feature.swift"
printf 'func testRetained() {}\n' >"$FIXTURE/Tests/TargetATests/FeatureTests.swift"
printf '{"fixture":true}\n' >"$FIXTURE/Tests/Fixtures/data.json"
printf '// package\n' >"$FIXTURE/Package.swift"
git -C "$FIXTURE" init -q
git -C "$FIXTURE" add Sources Tests Package.swift
git -C "$FIXTURE" -c user.name=gate -c user.email=gate@example.invalid commit -qm baseline
printf 'let retained = 1\nlet changed = 2\n' >"$FIXTURE/Sources/TargetA/Feature.swift"
printf '%s\n' '{"schemaVersion":2,"sourceLineCoveragePercentMinimum":1,"sourceLineCoveragePercentMinimumByTarget":{"TargetA":1},"changedExecutableSourceLineCoveragePercentMinimum":1,"sourceFileLineMaximums":{"defaultMaximum":600,"existingFileMaximums":{}},"swiftFormatWarningMaximums":{"sourcesByTarget":{"TargetA":1},"testsByTarget":{"TargetATests":1},"packageSwift":0,"changedLines":0}}' >"$TMP_DIR/baseline.json"
stub() { printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$1" >"$TMP_DIR/swift-format"; chmod +x "$TMP_DIR/swift-format"; }
run_gate() { env QUALITY_GATE_ROOT="$FIXTURE" QUALITY_BASELINES_PATH="$TMP_DIR/baseline.json" SWIFT_FORMAT_BIN="$TMP_DIR/swift-format" SWIFT_FORMAT_LOG_PATH="$1" SWIFT_FORMAT_RESULT_JSON="${2:-$TMP_DIR/result.json}" SWIFT_FORMAT_TEST_ROLE="${3:-}" SWIFT_FORMAT_TEST_FIXTURE="$FIXTURE" SWIFT_FORMAT_TEST_SYNC="$TMP_DIR" bash "$ROOT_DIR/script/check_swift_format.sh"; }
stub "echo '$FIXTURE/Tests/TargetATests/FeatureTests.swift:1:1: warning: [Fixture] old'"
run_gate "$TMP_DIR/pass.log" >/dev/null
grep -q '"warningCount": 0' "$TMP_DIR/result.json" || fail "changed-line result was not recorded"
stub "echo '$FIXTURE/Tests/TargetATests/FeatureTests.swift:1:1: warning: [Fixture] one'; echo '$FIXTURE/Tests/TargetATests/FeatureTests.swift:1:2: warning: [Fixture] two'"
if run_gate "$TMP_DIR/target-fail.log" >/dev/null 2>&1; then fail "per-target maximum was not enforced"; fi
stub "echo '$FIXTURE/Sources/TargetA/Feature.swift:2:1: warning: [Fixture] changed'"
if run_gate "$TMP_DIR/changed-fail.log" >/dev/null 2>&1; then fail "changed-line warning was accepted"; fi
stub "printf '%s\\0%s\\n' '$FIXTURE/Sources/TargetA/Feature.swift' ':1:1: warning: [Fixture] corrupt'"
if run_gate "$TMP_DIR/corrupt.log" >"$TMP_DIR/corrupt-gate.log" 2>&1; then fail "corrupt diagnostic was accepted"; fi
grep -q 'unclassified warning path' "$TMP_DIR/corrupt-gate.log" || fail "corrupt diagnostic was not reported"
cat >"$TMP_DIR/swift-format" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
wait_for_marker() {
  for ((attempt=0; attempt<200; attempt++)); do
    [[ ! -f "$SWIFT_FORMAT_TEST_SYNC/$1" ]] || return 0
    sleep 0.01
  done
  exit 2
}
if [[ "$SWIFT_FORMAT_TEST_ROLE" == A ]]; then
  printf '%s\n' "$SWIFT_FORMAT_TEST_FIXTURE/Sources/TargetA/Feature.swift:1:1: warning: [Fixture] allowed"
  touch "$SWIFT_FORMAT_TEST_SYNC/a-ready"
  wait_for_marker b-written
else
  wait_for_marker a-ready
  printf '%s\n' "$SWIFT_FORMAT_TEST_FIXTURE/Sources/TargetA/Feature.swift:2:1: warning: [Fixture] changed"
  touch "$SWIFT_FORMAT_TEST_SYNC/b-written"
fi
SH
run_gate "$TMP_DIR/concurrent.log" "$TMP_DIR/results/concurrent-a.json" A >/dev/null 2>&1 & pid_a=$!
run_gate "$TMP_DIR/concurrent.log" "$TMP_DIR/results/concurrent-b.json" B >/dev/null 2>&1 & pid_b=$!
status_a=0; wait "$pid_a" || status_a=$?
status_b=0; wait "$pid_b" || status_b=$?
[[ "$status_a" == 0 ]] || fail "first concurrent format gate failed"
[[ "$status_b" != 0 ]] || fail "concurrent changed-line warning was accepted"
python3 - "$TMP_DIR" <<'PY' || fail "concurrent results lost their own diagnostics"
import json
import sys
from pathlib import Path
root = Path(sys.argv[1])
a = json.loads((root / "results/concurrent-a.json").read_text())
b = json.loads((root / "results/concurrent-b.json").read_text())
assert a["changedLines"]["warningCount"] == 0
assert b["changedLines"]["warningCount"] == 1
assert a["log"] != b["log"]
assert "allowed" in Path(a["log"]).read_text() and "changed" not in Path(a["log"]).read_text()
assert "changed" in Path(b["log"]).read_text() and "allowed" not in Path(b["log"]).read_text()
assert b"\0" not in (root / "concurrent.log").read_bytes()
PY
stub 'echo "formatter tool failed"; exit 3'
if run_gate "$TMP_DIR/tool-failed.log" "$TMP_DIR/tool-failed/result.json" >"$TMP_DIR/tool-failed-gate.log" 2>&1; then fail "formatter tool failure was accepted"; fi
grep -q 'swift-format exited with status 3' "$TMP_DIR/tool-failed-gate.log" || fail "formatter tool failure was not reported"
[[ ! -e "$TMP_DIR/tool-failed/result.json" ]] || fail "tool failure published an empty result"
stub "echo '$FIXTURE/Sources/TargetA/Feature.swift:1:1: warning: [Fixture] old'"
if env QUALITY_GATE_ROOT="$FIXTURE" QUALITY_BASELINES_PATH="$TMP_DIR/baseline.json" QUALITY_DIFF_BASE=does-not-exist SWIFT_FORMAT_BIN="$TMP_DIR/swift-format" bash "$ROOT_DIR/script/check_swift_format.sh" >"$TMP_DIR/base-fail.log" 2>&1; then fail "invalid base was accepted"; fi
grep -q 'invalid QUALITY_DIFF_BASE' "$TMP_DIR/base-fail.log" || fail "invalid base did not fail closed"
printf '%s\n' '{"schemaVersion":1}' >"$TMP_DIR/invalid-baseline.json"
if env QUALITY_GATE_ROOT="$FIXTURE" QUALITY_BASELINES_PATH="$TMP_DIR/invalid-baseline.json" SWIFT_FORMAT_BIN="$TMP_DIR/swift-format" bash "$ROOT_DIR/script/check_swift_format.sh" >"$TMP_DIR/schema-fail.log" 2>&1; then fail "invalid schema was accepted"; fi
grep -q 'schemaVersion' "$TMP_DIR/schema-fail.log" || fail "invalid schema was not reported"
if env QUALITY_GATE_ROOT="$FIXTURE" QUALITY_BASELINES_PATH="$TMP_DIR/baseline.json" SWIFT_FORMAT_BIN="$TMP_DIR/missing-swift-format" SWIFT_FORMAT_DISABLE_XCRUN=1 bash "$ROOT_DIR/script/check_swift_format.sh" >"$TMP_DIR/missing.log" 2>&1; then fail "missing tool was accepted"; fi
grep -q '\[environment:tool-unavailable\]' "$TMP_DIR/missing.log" || fail "missing tool was not classified"
echo "swift-format lint gate test: passed"
