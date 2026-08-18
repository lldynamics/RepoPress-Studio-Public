#!/usr/bin/env bash
set -euo pipefail

# Keep byte-oriented assertions deterministic when the repository path contains
# non-ASCII characters and Bash renders shell-escaped command arguments.
export LC_ALL=C

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/script/capture_release_performance_trace.sh"

launch_output="$(bash "$SCRIPT" --dry-run --scenario launch --duration 12s)"
grep -Fq 'scenario=launch' <<<"$launch_output"
grep -Fq -- '--template App\ Launch' <<<"$launch_output"
grep -Fq -- '--time-limit 12s' <<<"$launch_output"
grep -Fq 'PersonalSitePublisherMac.app' <<<"$launch_output"

typing_output="$(
  bash "$SCRIPT" \
    --dry-run \
    --scenario typing \
    --duration 30s \
    --note 'Type continuously in the large Markdown fixture.'
)"
grep -Fq 'scenario=typing' <<<"$typing_output"
grep -Fq 'Type continuously in the large Markdown fixture.' <<<"$typing_output"
grep -Fq -- '--template SwiftUI' <<<"$typing_output"

if bash "$SCRIPT" --dry-run --scenario typing >/dev/null 2>&1; then
  echo "interactive scenario accepted a missing reproduction note" >&2
  exit 1
fi
if bash "$SCRIPT" --dry-run --scenario unsupported --note test >/dev/null 2>&1; then
  echo "unsupported scenario was accepted" >&2
  exit 1
fi
if bash "$SCRIPT" --dry-run --duration 0s >/dev/null 2>&1; then
  echo "zero duration was accepted" >&2
  exit 1
fi

echo "release performance trace contract: passed"
