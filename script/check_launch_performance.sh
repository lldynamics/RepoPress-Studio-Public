#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export LAUNCH_BASELINE_MAX_SECONDS="${LAUNCH_BASELINE_MAX_SECONDS:-5.0}"
build_arguments=(--launch-baseline)
if [[ "${1:-}" == "--release" ]]; then
  build_arguments+=(--release)
elif [[ "$#" -gt 0 ]]; then
  echo "usage: check_launch_performance.sh [--release]" >&2
  exit 2
fi
bash "$ROOT_DIR/script/build_and_run.sh" "${build_arguments[@]}"
