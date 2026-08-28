#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${QUALITY_GATE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BASELINES_PATH="${QUALITY_BASELINES_PATH:-$ROOT_DIR/script/quality_baselines.json}"
LOG_PATH="${SWIFT_FORMAT_LOG_PATH:-$ROOT_DIR/.build/swift-format-lint.log}"
RESULT_PATH="${SWIFT_FORMAT_RESULT_JSON:-$ROOT_DIR/.build/swift-format-result.json}"

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
swift_format="$(resolve_swift_format)"
mkdir -p "$(dirname "$LOG_PATH")"
set +e
"$swift_format" lint --recursive --parallel \
  "$ROOT_DIR/Sources" "$ROOT_DIR/Tests" "$ROOT_DIR/Package.swift" >"$LOG_PATH" 2>&1
tool_status=$?
set -e
if [[ "$tool_status" -ne 0 ]]; then
  sed -n '1,80p' "$LOG_PATH" >&2
  fail "swift-format exited with status $tool_status"
fi

set +e
PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 - "$ROOT_DIR" "$BASELINES_PATH" "$LOG_PATH" "$RESULT_PATH" "${QUALITY_DIFF_BASE:-${GITHUB_BASE_REF:-}}" <<'PY'
import json
import re
import sys
from pathlib import Path

from quality_gate_common import (
    QualityGateError, changed_lines, load_quality_baseline, resolve_diff_base, target_directories,
    validate_target_mapping,
)

root = Path(sys.argv[1]).resolve()
baseline_path = Path(sys.argv[2])
log_path = Path(sys.argv[3])
result_path = Path(sys.argv[4])
configured_base = sys.argv[5] or None

try:
    baseline = load_quality_baseline(baseline_path)
    maximums = baseline["swiftFormatWarningMaximums"]
    assert isinstance(maximums, dict)
    sources = maximums["sourcesByTarget"]
    tests = maximums["testsByTarget"]
    assert isinstance(sources, dict) and isinstance(tests, dict)
    validate_target_mapping(sources, target_directories(root, "Sources"), "swiftFormatWarningMaximums.sourcesByTarget")
    validate_target_mapping(tests, target_directories(root, "Tests"), "swiftFormatWarningMaximums.testsByTarget")
    diff_base = resolve_diff_base(root, configured_base)
    changed = changed_lines(root, diff_base.resolved)
except QualityGateError as error:
    print(f"swift-format lint gate: {error}", file=sys.stderr)
    raise SystemExit(1)

warning = re.compile(r"^(.*?):(\d+):(\d+): warning: ")
counts = {"sources": {target: 0 for target in sources}, "tests": {target: 0 for target in tests}, "packageSwift": 0}
changed_warning_count = 0
unclassified = []
for raw in log_path.read_text(encoding="utf-8", errors="replace").splitlines():
    match = warning.match(raw)
    if not match:
        continue
    raw_path, line = match.group(1), int(match.group(2))
    path = Path(raw_path)
    resolved = (path if path.is_absolute() else root / path).resolve()
    try:
        relative = resolved.relative_to(root).as_posix()
    except ValueError:
        unclassified.append(raw)
        continue
    parts = Path(relative).parts
    if len(parts) >= 3 and parts[0] == "Sources" and parts[1] in sources:
        counts["sources"][parts[1]] += 1
    elif len(parts) >= 3 and parts[0] == "Tests" and parts[1] in tests:
        counts["tests"][parts[1]] += 1
    elif relative == "Package.swift":
        counts["packageSwift"] += 1
    else:
        unclassified.append(raw)
        continue
    if line in changed.get(relative, set()):
        changed_warning_count += 1

result = {
    "schemaVersion": 2,
    "warnings": counts,
    "targets": {
        **{f"Sources/{target}": {"count": count, "maximum": sources[target]} for target, count in counts["sources"].items()},
        **{f"Tests/{target}": {"count": count, "maximum": tests[target]} for target, count in counts["tests"].items()},
    },
    "packageSwift": {"count": counts["packageSwift"], "maximum": maximums["packageSwift"]},
    "overall": {"count": sum(counts["sources"].values()) + sum(counts["tests"].values()) + counts["packageSwift"]},
    "changedLines": {
        "lineCount": sum(len(lines) for path, lines in changed.items() if path == "Package.swift" or path.startswith("Sources/") or path.startswith("Tests/")),
        "warningCount": changed_warning_count, "maximum": maximums["changedLines"],
    },
    "diffBase": diff_base.resolved,
    "requestedDiffBase": diff_base.requested,
    "usedAllZeroDiffBaseFallback": diff_base.used_all_zero_fallback,
    "log": str(log_path),
}
result_path.parent.mkdir(parents=True, exist_ok=True)
result_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
if unclassified:
    print("swift-format lint gate: unclassified warning path: " + unclassified[0], file=sys.stderr)
    raise SystemExit(1)
violations = []
for target, count in counts["sources"].items():
    if count > sources[target]:
        violations.append(f"Sources/{target} {count}>{sources[target]}")
for target, count in counts["tests"].items():
    if count > tests[target]:
        violations.append(f"Tests/{target} {count}>{tests[target]}")
if counts["packageSwift"] > maximums["packageSwift"]:
    violations.append(f"Package.swift {counts['packageSwift']}>{maximums['packageSwift']}")
if changed_warning_count > maximums["changedLines"]:
    violations.append(f"changed lines {changed_warning_count}>{maximums['changedLines']}")
if violations:
    print("swift-format lint gate: warning maximum exceeded: " + "; ".join(violations), file=sys.stderr)
    raise SystemExit(1)
print(
    "swift-format lint gate: passed "
    f"({result['overall']['count']} warning(s); changed-line warnings {changed_warning_count}/{maximums['changedLines']}; "
    f"full log: {log_path})"
)
PY
format_status=$?
set -e
if [[ "$format_status" -ne 0 ]]; then
  exit "$format_status"
fi
