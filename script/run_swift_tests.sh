#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Keep this entry point intentionally small.  The Python helper owns the
# inventory contract, deterministic partition, per-shard evidence, and child
# process-group cleanup so that a cancelled release gate cannot strand xctest.
exec python3 "$ROOT_DIR/script/run_swift_test_process.py" --root "$ROOT_DIR"
