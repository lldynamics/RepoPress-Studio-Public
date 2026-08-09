#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_BIN="${SWIFT_BIN:-swift}"

CACHE_TEST_FILTER='^PersonalSitePublisherMacTests\.WorkbenchImageTwoTierCacheTests'
MAC_TEST_FILTER='^PersonalSitePublisherMacTests\.'
CORE_TEST_FILTER='^PublishingWorkbenchCoreTests\.'

fail() {
  echo "swift test shards: $*" >&2
  exit 1
}

[[ -f "$ROOT_DIR/Package.swift" ]] || fail "Package.swift is missing"
cd "$ROOT_DIR"

# Keep the allowlist closed over the package manifest. A new test target must be
# explicitly reviewed here before it can be included in a release run.
test_targets="$(python3 - "$ROOT_DIR/Package.swift" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path

package_path = Path(sys.argv[1])
try:
    lines = package_path.read_text(encoding="utf-8").splitlines()
except OSError as error:
    print(f"cannot read Package.swift: {error}", file=sys.stderr)
    raise SystemExit(2)

in_test_target = False
found_name = False
parenthesis_depth = 0
names: list[str] = []
for line_number, line in enumerate(lines, start=1):
    if re.search(r"\.testTarget\s*\(", line):
        if in_test_target:
            print(
                f"nested testTarget declaration before line {line_number}",
                file=sys.stderr,
            )
            raise SystemExit(2)
        in_test_target = True
        found_name = False
        parenthesis_depth = 0
    if not in_test_target:
        continue
    parenthesis_depth += line.count("(") - line.count(")")
    match = re.search(r"\bname\s*:\s*\"([^\"]+)\"", line)
    if match:
        if found_name:
            print(f"duplicate testTarget name before line {line_number}", file=sys.stderr)
            raise SystemExit(2)
        names.append(match.group(1))
        found_name = True
    if found_name and parenthesis_depth <= 0:
        in_test_target = False
        found_name = False

if in_test_target:
    print("unterminated testTarget declaration", file=sys.stderr)
    raise SystemExit(2)
if not names:
    print("Package.swift declares no test targets", file=sys.stderr)
    raise SystemExit(2)
print("\n".join(names))
PY
)" || fail "could not inspect Package.swift test targets"

expected_targets=$'PersonalSitePublisherMacTests\nPublishingWorkbenchCoreTests'
actual_targets="$(printf '%s\n' "$test_targets" | LC_ALL=C sort)"
if [[ "$actual_targets" != "$expected_targets" ]]; then
  printf '%s\n' \
    "unexpected Swift test target set; expected exactly:" \
    "  PersonalSitePublisherMacTests" \
    "  PublishingWorkbenchCoreTests" \
    "found:" >&2
  printf '  %s\n' "$test_targets" >&2
  fail "refusing to run incomplete test shards"
fi

run_shard() {
  local label="$1"
  shift
  echo "swift test shards: running $label"
  "$SWIFT_BIN" test "$@"
}

# The first invocation builds the complete test product. The remaining shards
# are independent processes that reuse that exact build artifact.
run_shard \
  "PersonalSitePublisherMacTests.WorkbenchImageTwoTierCacheTests" \
  --disable-sandbox \
  --filter "$CACHE_TEST_FILTER"
run_shard \
  "PersonalSitePublisherMacTests (excluding cache)" \
  --disable-sandbox \
  --skip-build \
  --filter "$MAC_TEST_FILTER" \
  --skip "$CACHE_TEST_FILTER"
run_shard \
  "PublishingWorkbenchCoreTests" \
  --disable-sandbox \
  --skip-build \
  --filter "$CORE_TEST_FILTER"

echo "swift test shards: three isolated test processes passed"
