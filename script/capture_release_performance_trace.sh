#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/PersonalSitePublisherMac.app"
OUTPUT_DIRECTORY="$ROOT_DIR/.build/performance-traces"
SCENARIO="launch"
DURATION="20s"
TEMPLATE=""
NOTE=""
SKIP_BUILD=0
DRY_RUN=0

usage() {
  cat <<'EOF'
usage: script/capture_release_performance_trace.sh [options]

Options:
  --scenario <launch|typing|rss|image-batch|ai-streaming>
  --duration <Ns|Nm>       Recording duration (default: 20s).
  --template <name>        Instruments template (default: App Launch for launch,
                           SwiftUI for interactive scenarios).
  --note <text>            Required reproduction note except for launch.
  --output-directory <dir> Trace output root.
  --skip-build             Reuse an existing packaged Release app.
  --dry-run                Validate inputs and print the xctrace command only.
  --help
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --scenario)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      SCENARIO="$2"
      shift 2
      ;;
    --duration)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      DURATION="$2"
      shift 2
      ;;
    --template)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      TEMPLATE="$2"
      shift 2
      ;;
    --note)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      NOTE="$2"
      shift 2
      ;;
    --output-directory)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      OUTPUT_DIRECTORY="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$SCENARIO" in
  launch|typing|rss|image-batch|ai-streaming) ;;
  *)
    echo "unsupported performance scenario: $SCENARIO" >&2
    exit 2
    ;;
esac

if [[ ! "$DURATION" =~ ^[1-9][0-9]*(s|m)$ ]]; then
  echo "duration must be a positive whole number of seconds or minutes" >&2
  exit 2
fi

if [[ -z "${NOTE//[[:space:]]/}" ]]; then
  if [[ "$SCENARIO" == "launch" ]]; then
    NOTE="Cold launch through the initial visible workspace window."
  else
    echo "--note is required for interactive performance scenarios" >&2
    exit 2
  fi
fi

if [[ -z "$TEMPLATE" ]]; then
  if [[ "$SCENARIO" == "launch" ]]; then
    TEMPLATE="App Launch"
  else
    TEMPLATE="SwiftUI"
  fi
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
scenario_directory="$OUTPUT_DIRECTORY/$SCENARIO-$timestamp"
trace_path="$scenario_directory/$SCENARIO.trace"
metadata_path="$scenario_directory/metadata.json"
record_command=(
  xcrun xctrace record
  --template "$TEMPLATE"
  --time-limit "$DURATION"
  --output "$trace_path"
  --launch -- "$APP_BUNDLE"
)

if [[ "$DRY_RUN" == "1" ]]; then
  printf 'scenario=%s\n' "$SCENARIO"
  printf 'note=%s\n' "$NOTE"
  printf 'metadata=%s\n' "$metadata_path"
  printf 'command='
  printf '%q ' "${record_command[@]}"
  printf '\n'
  exit 0
fi

command -v xcrun >/dev/null || {
  echo "xcrun is required for Instruments capture" >&2
  exit 1
}

if [[ "$SKIP_BUILD" != "1" ]]; then
  bash "$ROOT_DIR/script/build_and_run.sh" --package-only --release
fi

[[ -d "$APP_BUNDLE" ]] || {
  echo "packaged Release app is missing: $APP_BUNDLE" >&2
  exit 1
}
[[ ! -e "$scenario_directory" ]] || {
  echo "trace output already exists: $scenario_directory" >&2
  exit 1
}
mkdir -p "$scenario_directory"

printf 'Performance scenario: %s\n' "$SCENARIO"
printf 'Reproduction note: %s\n' "$NOTE"
printf 'Interact only with that scenario until the %s recording ends.\n' "$DURATION"
set +e
"${record_command[@]}"
recording_exit_code="$?"
set -e

if [[ "$recording_exit_code" != "0" ]]; then
  if [[ "$recording_exit_code" != "54" \
    || ! -d "$trace_path" \
    || ! -e "$trace_path/Trace1.run" ]]; then
    echo "xctrace recording failed with exit code $recording_exit_code" >&2
    exit "$recording_exit_code"
  fi
  if ! xcrun xctrace export --input "$trace_path" --toc >/dev/null; then
    echo "xctrace saved an unreadable trace after exit code $recording_exit_code" >&2
    exit "$recording_exit_code"
  fi
  echo "xctrace ended the launched process at the time limit (exit 54); the saved trace is readable."
fi

TRACE_SCENARIO="$SCENARIO" \
TRACE_NOTE="$NOTE" \
TRACE_TEMPLATE="$TEMPLATE" \
TRACE_DURATION="$DURATION" \
TRACE_RECORDING_EXIT_CODE="$recording_exit_code" \
TRACE_PATH="$trace_path" \
TRACE_METADATA_PATH="$metadata_path" \
TRACE_ROOT_DIR="$ROOT_DIR" \
python3 - <<'PY'
import json
import os
import platform
import subprocess
from pathlib import Path


def capture(*command: str) -> str:
    try:
        return subprocess.check_output(command, text=True, stderr=subprocess.STDOUT).strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


root = Path(os.environ["TRACE_ROOT_DIR"])
payload = {
    "schemaVersion": 1,
    "scenario": os.environ["TRACE_SCENARIO"],
    "reproductionNote": os.environ["TRACE_NOTE"],
    "template": os.environ["TRACE_TEMPLATE"],
    "duration": os.environ["TRACE_DURATION"],
    "xctraceExitCode": int(os.environ["TRACE_RECORDING_EXIT_CODE"]),
    "tracePath": os.environ["TRACE_PATH"],
    "commit": capture("git", "-C", str(root), "rev-parse", "HEAD"),
    "toolchain": capture("xcodebuild", "-version"),
    "operatingSystem": platform.platform(),
    "machine": capture("sysctl", "-n", "hw.model"),
}
metadata_path = Path(os.environ["TRACE_METADATA_PATH"])
metadata_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

printf 'performance trace: %s\n' "$trace_path"
printf 'performance metadata: %s\n' "$metadata_path"
