#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export LAUNCH_BASELINE_MAX_SECONDS="${LAUNCH_BASELINE_MAX_SECONDS:-5.0}"
bash "$ROOT_DIR/script/build_and_run.sh" --launch-baseline
