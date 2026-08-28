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
printf '%s\n' '{"schemaVersion":2,"sourceLineCoveragePercentMinimum":1,"sourceLineCoveragePercentMinimumByTarget":{"TargetA":1},"changedExecutableSourceLineCoveragePercentMinimum":1,"swiftFormatWarningMaximums":{"sourcesByTarget":{"TargetA":1},"testsByTarget":{"TargetATests":1},"packageSwift":0,"changedLines":0}}' >"$TMP_DIR/baseline.json"
stub() { printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$1" >"$TMP_DIR/swift-format"; chmod +x "$TMP_DIR/swift-format"; }
run_gate() { env QUALITY_GATE_ROOT="$FIXTURE" QUALITY_BASELINES_PATH="$TMP_DIR/baseline.json" SWIFT_FORMAT_BIN="$TMP_DIR/swift-format" SWIFT_FORMAT_LOG_PATH="$1" SWIFT_FORMAT_RESULT_JSON="$TMP_DIR/result.json" bash "$ROOT_DIR/script/check_swift_format.sh"; }
stub "echo '$FIXTURE/Tests/TargetATests/FeatureTests.swift:1:1: warning: [Fixture] old'"
run_gate "$TMP_DIR/pass.log" >/dev/null
grep -q '"warningCount": 0' "$TMP_DIR/result.json" || fail "changed-line result was not recorded"
stub "echo '$FIXTURE/Tests/TargetATests/FeatureTests.swift:1:1: warning: [Fixture] one'; echo '$FIXTURE/Tests/TargetATests/FeatureTests.swift:1:2: warning: [Fixture] two'"
if run_gate "$TMP_DIR/target-fail.log" >/dev/null 2>&1; then fail "per-target maximum was not enforced"; fi
stub "echo '$FIXTURE/Sources/TargetA/Feature.swift:2:1: warning: [Fixture] changed'"
if run_gate "$TMP_DIR/changed-fail.log" >/dev/null 2>&1; then fail "changed-line warning was accepted"; fi
if env QUALITY_GATE_ROOT="$FIXTURE" QUALITY_BASELINES_PATH="$TMP_DIR/baseline.json" QUALITY_DIFF_BASE=does-not-exist SWIFT_FORMAT_BIN="$TMP_DIR/swift-format" bash "$ROOT_DIR/script/check_swift_format.sh" >"$TMP_DIR/base-fail.log" 2>&1; then fail "invalid base was accepted"; fi
grep -q 'invalid QUALITY_DIFF_BASE' "$TMP_DIR/base-fail.log" || fail "invalid base did not fail closed"
printf '%s\n' '{"schemaVersion":1}' >"$TMP_DIR/invalid-baseline.json"
if env QUALITY_GATE_ROOT="$FIXTURE" QUALITY_BASELINES_PATH="$TMP_DIR/invalid-baseline.json" SWIFT_FORMAT_BIN="$TMP_DIR/swift-format" bash "$ROOT_DIR/script/check_swift_format.sh" >"$TMP_DIR/schema-fail.log" 2>&1; then fail "invalid schema was accepted"; fi
grep -q 'schemaVersion' "$TMP_DIR/schema-fail.log" || fail "invalid schema was not reported"
if env QUALITY_GATE_ROOT="$FIXTURE" QUALITY_BASELINES_PATH="$TMP_DIR/baseline.json" SWIFT_FORMAT_BIN="$TMP_DIR/missing-swift-format" SWIFT_FORMAT_DISABLE_XCRUN=1 bash "$ROOT_DIR/script/check_swift_format.sh" >"$TMP_DIR/missing.log" 2>&1; then fail "missing tool was accepted"; fi
grep -q '\[environment:tool-unavailable\]' "$TMP_DIR/missing.log" || fail "missing tool was not classified"
echo "swift-format lint gate test: passed"
