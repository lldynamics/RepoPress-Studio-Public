#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/RepoPress Studio.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/PersonalSitePublisherMac"
OUTPUT_DIRECTORY="$ROOT_DIR/.build/performance-traces"
SCENARIO="launch"
DURATION="20s"
TEMPLATE=""
NOTE=""
SKIP_BUILD=0
DRY_RUN=0
DOCUMENT_LENGTH=100000
DOCUMENT_LENGTH_WAS_SET=0
SCROLL_PATTERN="ping-pong"
SCROLL_PATTERN_WAS_SET=0
SCROLL_CYCLES=4
SCROLL_CYCLES_WAS_SET=0
SCROLL_START_DELAY_SECONDS="4"
INTERACTION_DRIVER="programmatic"
INTERACTION_DRIVER_WAS_SET=0
TYPING_EDITS=24
TYPING_EDITS_WAS_SET=0
TYPING_START_DELAY_SECONDS="4"
TYPING_START_DELAY_WAS_SET=0
TYPING_INTERVAL_MILLISECONDS="120"
TYPING_INTERVAL_WAS_SET=0
TYPING_EDITING_SETTLE_DELAY_SECONDS="0.5"
TYPING_ANALYSIS_SETTLE_GRACE_MILLISECONDS="500"
MINIMUM_APPLY_SAMPLES=5
MINIMUM_APPLY_SAMPLES_WAS_SET=0
FRAME_BUDGET_MILLISECONDS="16.667"
FRAME_BUDGET_WAS_SET=0
HANG_THRESHOLD_MILLISECONDS="250"
HANG_THRESHOLD_WAS_SET=0
READ_ONLY_PRESENTATION="${REPOPRESS_TEXTKIT2_READ_ONLY_PRESENTATION:-0}"

usage() {
  cat <<'EOF'
usage: script/capture_release_performance_trace.sh [options]

Options:
  --scenario <launch|typing|markdown-scroll|markdown-rich-scroll|markdown-typing|rss|image-batch|ai-streaming>
  --interaction-driver <programmatic|manual>
                           Markdown interaction driver (default: programmatic).
                           Manual is native operator-controlled scrolling or
                           typing and is valid for every Markdown scenario.
  --duration <Ns|Nm>       Recording duration (default: 20s).
  --template <name>        Instruments template (default: App Launch for launch,
                           SwiftUI for interactive scenarios).
  --note <text>            Required reproduction note except for launch.
  --output-directory <dir> Trace output root.
  --document-length <n>    Markdown fixture UTF-16 minimum (1,000...1,000,000).
  --scroll-pattern <name>  Markdown scroll pattern: forward, ping-pong, or loop.
  --scroll-cycles <n>      Ping-pong/loop traversals (1...32, default: 4).
  --typing-edits <n>       Deterministic NSTextView edits (6...240, default: 24).
  --typing-start-delay-seconds <n>
                           Delay before the typing interaction (default: 4).
  --typing-interval-ms <n> Delay between deterministic edits (16...2000, default: 120).
  --minimum-apply-samples <n>
                           Minimum ApplyAttributes samples for a valid gate
                           (default: 5 for markdown-scroll/markdown-rich-scroll,
                           1 for markdown-typing).
  --frame-budget-ms <n>    ApplyAttributes P95 budget in milliseconds (default: 16.667).
  --hang-threshold-ms <n> Blocking hang threshold in milliseconds (default: 250).
  --skip-build             Reuse an existing packaged Release app.
  --dry-run                Validate inputs and print the xctrace command only.
  --help
EOF
}

is_markdown_scroll_scenario() {
  [[ "$SCENARIO" == "markdown-scroll" || "$SCENARIO" == "markdown-rich-scroll" ]]
}

is_markdown_scenario() {
  is_markdown_scroll_scenario || [[ "$SCENARIO" == "markdown-typing" ]]
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
    --document-length)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      DOCUMENT_LENGTH="$2"
      DOCUMENT_LENGTH_WAS_SET=1
      shift 2
      ;;
    --scroll-pattern)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      SCROLL_PATTERN="$2"
      SCROLL_PATTERN_WAS_SET=1
      shift 2
      ;;
    --scroll-cycles)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      SCROLL_CYCLES="$2"
      SCROLL_CYCLES_WAS_SET=1
      shift 2
      ;;
    --interaction-driver)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      INTERACTION_DRIVER="$2"
      INTERACTION_DRIVER_WAS_SET=1
      shift 2
      ;;
    --typing-edits)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      TYPING_EDITS="$2"
      TYPING_EDITS_WAS_SET=1
      shift 2
      ;;
    --typing-start-delay-seconds)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      TYPING_START_DELAY_SECONDS="$2"
      TYPING_START_DELAY_WAS_SET=1
      shift 2
      ;;
    --typing-interval-ms)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      TYPING_INTERVAL_MILLISECONDS="$2"
      TYPING_INTERVAL_WAS_SET=1
      shift 2
      ;;
    --minimum-apply-samples)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      MINIMUM_APPLY_SAMPLES="$2"
      MINIMUM_APPLY_SAMPLES_WAS_SET=1
      shift 2
      ;;
    --frame-budget-ms)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      FRAME_BUDGET_MILLISECONDS="$2"
      FRAME_BUDGET_WAS_SET=1
      shift 2
      ;;
    --hang-threshold-ms)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      HANG_THRESHOLD_MILLISECONDS="$2"
      HANG_THRESHOLD_WAS_SET=1
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
  launch|typing|markdown-scroll|markdown-rich-scroll|markdown-typing|rss|image-batch|ai-streaming) ;;
  *)
    echo "unsupported performance scenario: $SCENARIO" >&2
    exit 2
    ;;
esac

markdown_scroll_scenario=0
markdown_scenario=0
if is_markdown_scroll_scenario; then
  markdown_scroll_scenario=1
  markdown_scenario=1
elif [[ "$SCENARIO" == "markdown-typing" ]]; then
  markdown_scenario=1
fi

if [[ "$SCENARIO" == "markdown-typing" && "$MINIMUM_APPLY_SAMPLES_WAS_SET" == "0" ]]; then
  MINIMUM_APPLY_SAMPLES=1
fi

case "$INTERACTION_DRIVER" in
  programmatic|manual) ;;
  *)
    echo "interaction driver must be programmatic or manual" >&2
    exit 2
    ;;
esac
if [[ "$INTERACTION_DRIVER" == "manual" && "$markdown_scenario" == "0" ]]; then
  echo "manual interaction driver is only valid for Markdown scenarios" >&2
  exit 2
fi
if [[ "$INTERACTION_DRIVER" == "manual" ]]; then
  if [[ "$DOCUMENT_LENGTH_WAS_SET" == "1" && "$DOCUMENT_LENGTH" != "100000" ]]; then
    echo "manual Markdown scrolling requires the fixed 100000 UTF-16 fixture" >&2
    exit 2
  fi
  DOCUMENT_LENGTH=100000
fi
if [[ "$INTERACTION_DRIVER" == "manual" \
  && ("$SCROLL_PATTERN_WAS_SET" == "1" || "$SCROLL_CYCLES_WAS_SET" == "1") ]]; then
  echo "manual interaction driver does not accept a programmatic scroll pattern or cycle count" >&2
  exit 2
fi
if [[ "$INTERACTION_DRIVER" == "manual" \
  && ("$TYPING_EDITS_WAS_SET" == "1" || "$TYPING_START_DELAY_WAS_SET" == "1" \
    || "$TYPING_INTERVAL_WAS_SET" == "1") ]]; then
  echo "manual interaction driver does not accept programmatic typing controls" >&2
  exit 2
fi

if [[ ! "$DURATION" =~ ^[1-9][0-9]*(s|m)$ ]]; then
  echo "duration must be a positive whole number of seconds or minutes" >&2
  exit 2
fi
if [[ ! "$DOCUMENT_LENGTH" =~ ^[0-9]+$ ]] \
  || (( DOCUMENT_LENGTH < 1000 || DOCUMENT_LENGTH > 1000000 )); then
  echo "document length must be between 1000 and 1000000 UTF-16 units" >&2
  exit 2
fi
if [[ "$DOCUMENT_LENGTH_WAS_SET" == "1" && "$markdown_scenario" == "0" ]]; then
  echo "--document-length is only valid for markdown-scroll, markdown-rich-scroll, or markdown-typing" >&2
  exit 2
fi
case "$SCROLL_PATTERN" in
  forward|ping-pong|loop) ;;
  *)
    echo "scroll pattern must be forward, ping-pong, or loop" >&2
    exit 2
    ;;
esac
if [[ ! "$SCROLL_CYCLES" =~ ^[1-9][0-9]*$ ]] \
  || (( SCROLL_CYCLES < 1 || SCROLL_CYCLES > 32 )); then
  echo "scroll cycles must be an integer between 1 and 32" >&2
  exit 2
fi
if [[ ! "$TYPING_EDITS" =~ ^[1-9][0-9]*$ ]] \
  || (( TYPING_EDITS < 6 || TYPING_EDITS > 240 )); then
  echo "typing edits must be an integer between 6 and 240" >&2
  exit 2
fi
if [[ ! "$MINIMUM_APPLY_SAMPLES" =~ ^[1-9][0-9]*$ ]] \
  || (( MINIMUM_APPLY_SAMPLES < 1 || MINIMUM_APPLY_SAMPLES > 10000 )); then
  echo "minimum apply samples must be an integer between 1 and 10000" >&2
  exit 2
fi
positive_decimal='^([1-9][0-9]*([.][0-9]+)?|0[.]([0-9]*[1-9][0-9]*))$'
if [[ ! "$FRAME_BUDGET_MILLISECONDS" =~ $positive_decimal ]]; then
  echo "frame budget must be a positive number of milliseconds" >&2
  exit 2
fi
if [[ ! "$HANG_THRESHOLD_MILLISECONDS" =~ $positive_decimal ]]; then
  echo "hang threshold must be a positive number of milliseconds" >&2
  exit 2
fi
if [[ ! "$TYPING_START_DELAY_SECONDS" =~ $positive_decimal ]]; then
  echo "typing start delay must be a positive number of seconds" >&2
  exit 2
fi
if [[ ! "$TYPING_INTERVAL_MILLISECONDS" =~ ^[1-9][0-9]*$ ]] \
  || (( TYPING_INTERVAL_MILLISECONDS < 16 || TYPING_INTERVAL_MILLISECONDS > 2000 )); then
  echo "typing interval must be an integer between 16 and 2000 milliseconds" >&2
  exit 2
fi
if [[ "$SCROLL_PATTERN_WAS_SET" == "1" && "$markdown_scroll_scenario" == "0" ]] \
  || [[ "$SCROLL_CYCLES_WAS_SET" == "1" && "$markdown_scroll_scenario" == "0" ]] \
  || [[ "$TYPING_EDITS_WAS_SET" == "1" && "$SCENARIO" != "markdown-typing" ]] \
  || [[ "$TYPING_START_DELAY_WAS_SET" == "1" && "$SCENARIO" != "markdown-typing" ]] \
  || [[ "$TYPING_INTERVAL_WAS_SET" == "1" && "$SCENARIO" != "markdown-typing" ]] \
  || [[ "$INTERACTION_DRIVER_WAS_SET" == "1" && "$markdown_scenario" == "0" ]] \
  || [[ "$MINIMUM_APPLY_SAMPLES_WAS_SET" == "1" && "$markdown_scenario" == "0" ]] \
  || [[ "$FRAME_BUDGET_WAS_SET" == "1" && "$markdown_scenario" == "0" ]] \
  || [[ "$HANG_THRESHOLD_WAS_SET" == "1" && "$markdown_scenario" == "0" ]]; then
  echo "scroll options are only valid for Markdown scroll scenarios; typing options are only valid for markdown-typing" >&2
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
  elif is_markdown_scenario; then
    TEMPLATE="Time Profiler"
  else
    TEMPLATE="SwiftUI"
  fi
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
scenario_directory="$OUTPUT_DIRECTORY/$SCENARIO-$timestamp"
if is_markdown_scenario; then
  scenario_directory="$OUTPUT_DIRECTORY/$SCENARIO-$DOCUMENT_LENGTH-$timestamp"
fi
trace_path="$scenario_directory/$SCENARIO.trace"
metadata_path="$scenario_directory/metadata.json"
analysis_path="$scenario_directory/analysis.json"
runtime_home="$scenario_directory/runtime-home"
runtime_tmp="$scenario_directory/runtime-tmp"
performance_fixture="markdown-scroll"
if [[ "$SCENARIO" == "markdown-rich-scroll" ]]; then
  performance_fixture="markdown-rich-scroll"
fi
record_command=(
  xcrun xctrace record
  --template "$TEMPLATE"
  --time-limit "$DURATION"
  --output "$trace_path"
)
capture_launch_command=()
if is_markdown_scenario; then
  record_command+=(
    --instrument os_signpost
    --instrument Hangs
  )
  capture_launch_command=(
    /usr/bin/env
    -i
    "HOME=$runtime_home"
    "CFFIXED_USER_HOME=$runtime_home"
    "TMPDIR=$runtime_tmp/"
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
    "LANG=C.UTF-8"
    "LC_CTYPE=C.UTF-8"
    "PERSONAL_SITE_PUBLISHER_PERFORMANCE_PERSISTENCE_ROOT=$runtime_tmp"
    "PERSONAL_SITE_PUBLISHER_PERFORMANCE_FIXTURE=$performance_fixture"
    "PERSONAL_SITE_PUBLISHER_PERFORMANCE_FIXTURE_UTF16_LENGTH=$DOCUMENT_LENGTH"
    "PERSONAL_SITE_PUBLISHER_PERFORMANCE_INTERACTION_DRIVER=$INTERACTION_DRIVER"
    "REPOPRESS_TEXTKIT2_READ_ONLY_PRESENTATION=$READ_ONLY_PRESENTATION"
  )
  if is_markdown_scroll_scenario && [[ "$INTERACTION_DRIVER" == "programmatic" ]]; then
    capture_launch_command+=(
      "PERSONAL_SITE_PUBLISHER_PERFORMANCE_AUTO_SCROLL=1"
      "PERSONAL_SITE_PUBLISHER_PERFORMANCE_AUTO_SCROLL_PATTERN=$SCROLL_PATTERN"
      "PERSONAL_SITE_PUBLISHER_PERFORMANCE_AUTO_SCROLL_CYCLES=$SCROLL_CYCLES"
      "PERSONAL_SITE_PUBLISHER_PERFORMANCE_AUTO_SCROLL_DURATION_SECONDS=12"
      "PERSONAL_SITE_PUBLISHER_PERFORMANCE_AUTO_SCROLL_START_DELAY_SECONDS=$SCROLL_START_DELAY_SECONDS"
    )
  elif [[ "$SCENARIO" == "markdown-typing" && "$INTERACTION_DRIVER" == "programmatic" ]]; then
    capture_launch_command+=(
      "PERSONAL_SITE_PUBLISHER_PERFORMANCE_AUTO_TYPING=1"
      "PERSONAL_SITE_PUBLISHER_PERFORMANCE_AUTO_TYPING_EDITS=$TYPING_EDITS"
      "PERSONAL_SITE_PUBLISHER_PERFORMANCE_AUTO_TYPING_INTERVAL_MILLISECONDS=$TYPING_INTERVAL_MILLISECONDS"
      "PERSONAL_SITE_PUBLISHER_PERFORMANCE_AUTO_TYPING_START_DELAY_SECONDS=$TYPING_START_DELAY_SECONDS"
      "PERSONAL_SITE_PUBLISHER_PERFORMANCE_AUTO_TYPING_SETTLE_DELAY_SECONDS=$TYPING_EDITING_SETTLE_DELAY_SECONDS"
    )
  fi
  capture_launch_command+=("$APP_BINARY")
else
  record_command+=(--launch -- "$APP_BUNDLE")
fi

if [[ "$DRY_RUN" == "1" ]]; then
  if is_markdown_scenario; then
    record_command+=(--attach '<capture-pid>')
  fi
  printf 'scenario=%s\n' "$SCENARIO"
  printf 'interaction_driver=%s\n' "$INTERACTION_DRIVER"
  printf 'note=%s\n' "$NOTE"
  printf 'metadata=%s\n' "$metadata_path"
  if is_markdown_scroll_scenario; then
    printf 'document_length=%s\n' "$DOCUMENT_LENGTH"
    printf 'automatic_interaction=%s\n' "$([[ "$INTERACTION_DRIVER" == "programmatic" ]] && echo true || echo false)"
    if [[ "$INTERACTION_DRIVER" == "programmatic" ]]; then
      printf 'scroll_pattern=%s\n' "$SCROLL_PATTERN"
      printf 'scroll_cycles=%s\n' "$SCROLL_CYCLES"
      printf 'scroll_start_delay_seconds=%s\n' "$SCROLL_START_DELAY_SECONDS"
    fi
    printf 'minimum_apply_samples=%s\n' "$MINIMUM_APPLY_SAMPLES"
    printf 'frame_budget_ms=%s\n' "$FRAME_BUDGET_MILLISECONDS"
    printf 'hang_threshold_ms=%s\n' "$HANG_THRESHOLD_MILLISECONDS"
    if [[ "$SCENARIO" == "markdown-rich-scroll" ]]; then
      printf 'fixture_kind=markdown-rich-scroll\n'
      printf 'source_document_fixture=markdown-rich-attachments\n'
      printf 'contains_inline_images=true\n'
      printf 'contains_math_attachments=true\n'
    fi
    if [[ "$INTERACTION_DRIVER" == "manual" ]]; then
      printf 'manual_scroll_contract=native-operator-controlled\n'
      printf 'physical_input_identified=false\n'
    fi
  elif [[ "$SCENARIO" == "markdown-typing" ]]; then
    printf 'document_length=%s\n' "$DOCUMENT_LENGTH"
    printf 'automatic_interaction=%s\n' "$([[ "$INTERACTION_DRIVER" == "programmatic" ]] && echo true || echo false)"
    if [[ "$INTERACTION_DRIVER" == "programmatic" ]]; then
      printf 'typing_edits=%s\n' "$TYPING_EDITS"
      printf 'typing_start_delay_seconds=%s\n' "$TYPING_START_DELAY_SECONDS"
      printf 'typing_interval_ms=%s\n' "$TYPING_INTERVAL_MILLISECONDS"
      printf 'typing_editing_settle_delay_seconds=%s\n' "$TYPING_EDITING_SETTLE_DELAY_SECONDS"
      printf 'typing_analysis_settle_grace_ms=%s\n' "$TYPING_ANALYSIS_SETTLE_GRACE_MILLISECONDS"
    else
      printf 'manual_typing_contract=native-text-input-client\n'
      printf 'input_source_identified=false\n'
      printf 'ime_candidate_window_traceable=false\n'
    fi
    printf 'minimum_apply_samples=%s\n' "$MINIMUM_APPLY_SAMPLES"
    printf 'frame_budget_ms=%s\n' "$FRAME_BUDGET_MILLISECONDS"
    printf 'hang_threshold_ms=%s\n' "$HANG_THRESHOLD_MILLISECONDS"
  fi
  if is_markdown_scenario; then
    printf 'launch='
    printf '%q ' "${capture_launch_command[@]}"
    printf '\n'
  fi
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
  if is_markdown_scenario; then
    PERSONAL_SITE_PUBLISHER_CAPTURE_BUILD=1 \
      bash "$ROOT_DIR/script/build_and_run.sh" --package-only --release
  else
    bash "$ROOT_DIR/script/build_and_run.sh" --package-only --release
  fi
fi

[[ -d "$APP_BUNDLE" ]] || {
  echo "packaged Release app is missing: $APP_BUNDLE" >&2
  exit 1
}
[[ -x "$APP_BINARY" ]] || {
  echo "packaged Release executable is missing: $APP_BINARY" >&2
  exit 1
}
if is_markdown_scenario; then
  capture_build="$(/usr/libexec/PlistBuddy \
    -c 'Print :PersonalSitePublisherScreenshotCaptureBuild' \
    "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$capture_build" == "true" ]] || {
    echo "markdown-scroll, markdown-rich-scroll, and markdown-typing require a Release capture build; rerun without --skip-build" >&2
    exit 1
  }
fi
[[ ! -e "$scenario_directory" ]] || {
  echo "trace output already exists: $scenario_directory" >&2
  exit 1
}
mkdir -p "$scenario_directory"
if is_markdown_scenario; then
  mkdir -p "$runtime_home" "$runtime_tmp"
  "${capture_launch_command[@]}" &
  capture_app_pid="$!"
  cleanup_capture_app() {
    if kill -0 "$capture_app_pid" 2>/dev/null; then
      kill "$capture_app_pid" 2>/dev/null || true
      wait "$capture_app_pid" 2>/dev/null || true
    fi
  }
  trap cleanup_capture_app EXIT
  record_command+=(--attach "$capture_app_pid")
fi

printf 'Performance scenario: %s\n' "$SCENARIO"
printf 'Reproduction note: %s\n' "$NOTE"
printf 'Interact only with that scenario until the %s recording ends.\n' "$DURATION"
if [[ "$INTERACTION_DRIVER" == "manual" ]]; then
  if [[ "$SCENARIO" == "markdown-typing" ]]; then
    printf '%s\n' 'Manual interaction: keep the Markdown editor focused and use the selected native input method for the recording window; do not scroll or switch apps.'
    printf '%s\n' 'This capture deliberately does not enable PERFORMANCE_AUTO_TYPING. The trace cannot identify the input source or prove that a candidate window was shown.'
  else
    printf '%s\n' 'Manual interaction: keep the Markdown editor focused and use native scrolling for the recording window; do not type or switch apps.'
    printf '%s\n' 'This capture deliberately does not enable PERFORMANCE_AUTO_SCROLL. The trace does not identify a physical input device.'
  fi
fi
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

# Capture provenance as digests only. The helper hashes tracked/untracked
# workspace state and the packaged artifacts without putting Git diff text or
# workspace paths into the trace metadata.
trace_provenance="$(
  python3 "$ROOT_DIR/script/capture_trace_provenance.py" \
    --root "$ROOT_DIR" \
    --bundle "$APP_BUNDLE" \
    --binary "$APP_BINARY"
)"

TRACE_SCENARIO="$SCENARIO" \
TRACE_INTERACTION_DRIVER="$INTERACTION_DRIVER" \
TRACE_NOTE="$NOTE" \
TRACE_TEMPLATE="$TEMPLATE" \
TRACE_DURATION="$DURATION" \
TRACE_RECORDING_EXIT_CODE="$recording_exit_code" \
TRACE_PATH="$trace_path" \
TRACE_METADATA_PATH="$metadata_path" \
TRACE_ANALYSIS_PATH="$analysis_path" \
TRACE_DOCUMENT_LENGTH="$DOCUMENT_LENGTH" \
TRACE_SCROLL_PATTERN="$SCROLL_PATTERN" \
TRACE_SCROLL_CYCLES="$SCROLL_CYCLES" \
TRACE_SCROLL_START_DELAY_SECONDS="$SCROLL_START_DELAY_SECONDS" \
TRACE_TYPING_EDITS="$TYPING_EDITS" \
TRACE_TYPING_START_DELAY_SECONDS="$TYPING_START_DELAY_SECONDS" \
TRACE_TYPING_INTERVAL_MILLISECONDS="$TYPING_INTERVAL_MILLISECONDS" \
TRACE_TYPING_EDITING_SETTLE_DELAY_SECONDS="$TYPING_EDITING_SETTLE_DELAY_SECONDS" \
TRACE_TYPING_ANALYSIS_SETTLE_GRACE_MILLISECONDS="$TYPING_ANALYSIS_SETTLE_GRACE_MILLISECONDS" \
TRACE_MINIMUM_APPLY_SAMPLES="$MINIMUM_APPLY_SAMPLES" \
TRACE_FRAME_BUDGET_MILLISECONDS="$FRAME_BUDGET_MILLISECONDS" \
TRACE_HANG_THRESHOLD_MILLISECONDS="$HANG_THRESHOLD_MILLISECONDS" \
TRACE_ROOT_DIR="$ROOT_DIR" \
TRACE_PROVENANCE="$trace_provenance" \
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
source_provenance = json.loads(os.environ["TRACE_PROVENANCE"])
is_markdown_scenario = os.environ["TRACE_SCENARIO"] in (
    "markdown-scroll",
    "markdown-rich-scroll",
    "markdown-typing",
)
payload = {
    "schemaVersion": 4,
    "scenario": os.environ["TRACE_SCENARIO"],
    "interactionDriver": (
        os.environ["TRACE_INTERACTION_DRIVER"] if is_markdown_scenario else None
    ),
    "manualReviewRequired": (
        os.environ["TRACE_INTERACTION_DRIVER"] == "manual"
        if is_markdown_scenario
        else False
    ),
    "reproductionNote": os.environ["TRACE_NOTE"],
    "template": os.environ["TRACE_TEMPLATE"],
    "duration": os.environ["TRACE_DURATION"],
    "xctraceExitCode": int(os.environ["TRACE_RECORDING_EXIT_CODE"]),
    "tracePath": os.environ["TRACE_PATH"],
    # Keep commit at the historical top-level location for consumers that
    # already read it, while the explicit source object prevents a dirty
    # checkout from being mistaken for a reproducible clean commit.
    "commit": source_provenance["commit"],
    "workingTreeDirty": source_provenance["workingTreeDirty"],
    "workingTreeStateHash": source_provenance["workingTreeStateHash"],
    "sourceProvenance": {
        "commit": source_provenance["commit"],
        "workingTreeDirty": source_provenance["workingTreeDirty"],
        "workingTreeStateHash": source_provenance["workingTreeStateHash"],
        "reproducibleCleanCommit": source_provenance["reproducibleCleanCommit"],
        "interactionDriver": (
            os.environ["TRACE_INTERACTION_DRIVER"] if is_markdown_scenario else None
        ),
    },
    "artifacts": {
        "appBundleSHA256": source_provenance["appBundleSHA256"],
        "appBinarySHA256": source_provenance["appBinarySHA256"],
    },
    "toolchain": capture("xcodebuild", "-version"),
    "operatingSystem": platform.platform(),
    "machine": capture("sysctl", "-n", "hw.model"),
}
if is_markdown_scenario:
    payload["fixture"] = {
        "kind": payload["scenario"],
        "minimumDocumentUTF16Length": int(os.environ["TRACE_DOCUMENT_LENGTH"]),
        "interactionDriver": os.environ["TRACE_INTERACTION_DRIVER"],
        "automaticInteraction": os.environ["TRACE_INTERACTION_DRIVER"] == "programmatic",
        "isolatedRuntime": True,
        "minimumApplySamples": int(os.environ["TRACE_MINIMUM_APPLY_SAMPLES"]),
        "frameBudgetMilliseconds": float(os.environ["TRACE_FRAME_BUDGET_MILLISECONDS"]),
        "hangThresholdMilliseconds": float(os.environ["TRACE_HANG_THRESHOLD_MILLISECONDS"]),
    }
    if os.environ["TRACE_INTERACTION_DRIVER"] == "manual":
        is_manual_typing = payload["scenario"] == "markdown-typing"
        payload["fixture"].update({
            "manualInteractionContract": (
                "native-text-input-client"
                if is_manual_typing
                else "native-operator-controlled-scroll"
            ),
            "operatorControlled": True,
            "fixedDocumentUTF16Length": 100000,
        })
        if is_manual_typing:
            payload["fixture"].update({
                "inputSourceIdentified": False,
                "imeCandidateWindowTraceable": False,
            })
        else:
            payload["fixture"]["physicalInputIdentified"] = False
    if payload["scenario"] in ("markdown-scroll", "markdown-rich-scroll"):
        if os.environ["TRACE_INTERACTION_DRIVER"] == "programmatic":
            payload["fixture"].update({
                "scrollPattern": os.environ["TRACE_SCROLL_PATTERN"],
                "scrollCycles": int(os.environ["TRACE_SCROLL_CYCLES"]),
                "scrollStartDelaySeconds": float(os.environ["TRACE_SCROLL_START_DELAY_SECONDS"]),
            })
        if payload["scenario"] == "markdown-rich-scroll":
            payload["fixture"].update({
                "sourceDocumentFixture": "markdown-rich-attachments",
                "containsInlineImages": True,
                "containsMathAttachments": True,
            })
    else:
        payload["fixture"]["sourceDocumentFixture"] = "markdown-scroll"
        if os.environ["TRACE_INTERACTION_DRIVER"] == "programmatic":
            payload["fixture"].update({
                "typingEdits": int(os.environ["TRACE_TYPING_EDITS"]),
                "typingStartDelaySeconds": float(os.environ["TRACE_TYPING_START_DELAY_SECONDS"]),
                "typingIntervalMilliseconds": float(os.environ["TRACE_TYPING_INTERVAL_MILLISECONDS"]),
                "editingSettleDelaySeconds": float(
                    os.environ["TRACE_TYPING_EDITING_SETTLE_DELAY_SECONDS"]
                ),
                "analysisSettleGraceMilliseconds": float(
                    os.environ["TRACE_TYPING_ANALYSIS_SETTLE_GRACE_MILLISECONDS"]
                ),
                "editingEntryPoint": "NSTextView.insertText:replacementRange",
                "programmaticEditing": True,
                "imeComposition": False,
            })
        else:
            payload["fixture"].update({
                "editingEntryPoint": "native NSTextInputClient via operator",
                "programmaticEditing": False,
                "imeComposition": None,
                "operatorEvidenceRequired": True,
            })
    payload["analysisPath"] = os.environ["TRACE_ANALYSIS_PATH"]
metadata_path = Path(os.environ["TRACE_METADATA_PATH"])
metadata_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

if is_markdown_scenario; then
  export_directory="$scenario_directory/exports"
  mkdir -p "$export_directory"
  xcrun xctrace export \
    --input "$trace_path" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]' \
    --output "$export_directory/os-signpost.xml"
  xcrun xctrace export \
    --input "$trace_path" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-sample"]' \
    --output "$export_directory/time-sample.xml"
  xcrun xctrace export \
    --input "$trace_path" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="potential-hangs"]' \
    --output "$export_directory/potential-hangs.xml"
  set +e
  python3 "$ROOT_DIR/script/analyze_markdown_scroll_trace.py" \
    --scenario "$SCENARIO" \
    --interaction-driver "$INTERACTION_DRIVER" \
    --signposts "$export_directory/os-signpost.xml" \
    --time-samples "$export_directory/time-sample.xml" \
    --hangs "$export_directory/potential-hangs.xml" \
    --minimum-apply-samples "$MINIMUM_APPLY_SAMPLES" \
    --frame-budget-ms "$FRAME_BUDGET_MILLISECONDS" \
    --hang-threshold-ms "$HANG_THRESHOLD_MILLISECONDS" \
    --output "$analysis_path"
  analysis_exit_code="$?"
  set -e
  if [[ "$analysis_exit_code" == "2" ]]; then
    if [[ "$INTERACTION_DRIVER" == "manual" ]]; then
      echo "$SCENARIO manual trace did not contain a measurable capture window" >&2
    else
      echo "$SCENARIO trace did not contain a complete automatic interaction" >&2
    fi
    exit 2
  elif [[ "$analysis_exit_code" != "0" ]]; then
    echo "$SCENARIO performance gate failed; inspect: $analysis_path" >&2
    exit "$analysis_exit_code"
  fi
  if [[ "$INTERACTION_DRIVER" == "manual" ]]; then
    echo "manual trace metric gate passed; performancePassed remains false until operator review confirms the interaction evidence"
  fi
  printf 'performance analysis: %s\n' "$analysis_path"
fi

printf 'performance trace: %s\n' "$trace_path"
printf 'performance metadata: %s\n' "$metadata_path"
