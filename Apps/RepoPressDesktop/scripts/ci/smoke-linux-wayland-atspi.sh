#!/usr/bin/env bash
# Launch the immutable AppImage against a native, headless Weston compositor.
# Passing requires both a Wayland output at the requested scale and the named
# RepoPress controls in the live AT-SPI tree. This is not a GNOME/KDE or IME
# candidate-window substitute; those observations belong to the P14 real-host
# evidence contract.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: smoke-linux-wayland-atspi.sh --bundle-dir DIRECTORY --diagnostics-dir DIRECTORY [--scale 1|2] [--window-title TITLE] [--timeout-ms N]

Requires weston, wayland-info, dbus-run-session, setsid, and Python 3 with the
Atspi 2.0 GI binding. The bundle directory must contain exactly one AppImage.
EOF
}

original_args=("$@")
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bundle_dir=""
diagnostics_dir=""
scale=1
window_title="RepoPress Studio"
timeout_ms=20000

while (($# > 0)); do
  case "$1" in
    --bundle-dir)
      bundle_dir="${2:-}"
      shift 2
      ;;
    --diagnostics-dir)
      diagnostics_dir="${2:-}"
      shift 2
      ;;
    --scale)
      scale="${2:-}"
      shift 2
      ;;
    --window-title)
      window_title="${2:-}"
      shift 2
      ;;
    --timeout-ms)
      timeout_ms="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$bundle_dir" || -z "$diagnostics_dir" ]]; then
  printf '%s\n' '--bundle-dir and --diagnostics-dir are required.' >&2
  usage >&2
  exit 2
fi
if [[ "$scale" != "1" && "$scale" != "2" ]]; then
  printf 'Scale must be exactly 1 or 2: %s\n' "$scale" >&2
  exit 2
fi
if ! [[ "$timeout_ms" =~ ^[1-9][0-9]*$ ]] || ((timeout_ms > 120000)); then
  printf 'Timeout must be an integer from 1 through 120000 milliseconds: %s\n' "$timeout_ms" >&2
  exit 2
fi

# AT-SPI must be observed on the same fresh session bus as the application.
# Re-exec after argument validation so malformed invocations never start a bus.
if [[ "${REPOPRESS_WAYLAND_SMOKE_DBUS:-0}" != "1" ]]; then
  if ! command -v dbus-run-session >/dev/null 2>&1; then
    printf 'Required command is unavailable: dbus-run-session\n' >&2
    exit 1
  fi
  exec env REPOPRESS_WAYLAND_SMOKE_DBUS=1 \
    dbus-run-session -- "$script_dir/smoke-linux-wayland-atspi.sh" "${original_args[@]}"
fi
if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
  printf 'The isolated D-Bus session did not provide a bus address.\n' >&2
  exit 1
fi

mkdir -p "$diagnostics_dir"
diagnostics_dir="$(cd "$diagnostics_dir" && pwd)"
work_dir="$(mktemp -d)"
weston_pid=""
app_pid=""
startup_ms=""
result="setup_failed"
failure_stage="setup"
socket_name="repopress-wayland"
logical_width=1440
logical_height=900
output_width=$((logical_width * scale))
output_height=$((logical_height * scale))

write_session_report() {
  python3 - "$diagnostics_dir/wayland-session.json" "$result" "$failure_stage" \
    "$scale" "$output_width" "$output_height" "$window_title" "$startup_ms" "$timeout_ms" <<'PY'
import json
import pathlib
import sys

path, result, stage, scale, width, height, title, startup, budget = sys.argv[1:]
payload = {
    "result": result,
    "failure_stage": None if stage == "complete" else stage,
    "backend": "wayland",
    "compositor": "weston-headless",
    "scale": int(scale),
    "output_width_px": int(width),
    "output_height_px": int(height),
    "window_title": title,
    "startup_ms": int(startup) if startup else None,
    "budget_ms": int(budget),
}
with pathlib.Path(path).open("w", encoding="utf-8") as stream:
    json.dump(payload, stream, ensure_ascii=False, separators=(",", ":"))
    stream.write("\n")
PY
}

dump_diagnostics() {
  {
    printf '=== process tree ===\n'
    ps -eo pid,ppid,pgid,stat,etime,args --forest || true
    printf '\n=== Weston log ===\n'
    [[ -f "$diagnostics_dir/weston.log" ]] && tail -n 300 "$diagnostics_dir/weston.log" || true
    printf '\n=== application log ===\n'
    [[ -f "$diagnostics_dir/application.log" ]] && tail -n 300 "$diagnostics_dir/application.log" || true
    printf '\n=== Wayland globals ===\n'
    [[ -f "$diagnostics_dir/wayland-info.log" ]] && tail -n 300 "$diagnostics_dir/wayland-info.log" || true
    printf '\n=== AT-SPI result ===\n'
    [[ -f "$diagnostics_dir/atspi.json" ]] && cat "$diagnostics_dir/atspi.json" || true
  } >"$diagnostics_dir/wayland-smoke-diagnostics.log" 2>&1
}

stop_process_group() {
  local pid="$1"
  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    return
  fi
  kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  for _ in {1..20}; do
    kill -0 "$pid" 2>/dev/null || return
    sleep 0.1
  done
  kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
}

cleanup() {
  local status=$?
  set +e
  write_session_report
  dump_diagnostics
  stop_process_group "$app_pid"
  stop_process_group "$weston_pid"
  rm -rf "$work_dir"
  exit "$status"
}
trap cleanup EXIT

for command in weston wayland-info setsid python3 timeout; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Required command is unavailable: %s\n' "$command" >&2
    failure_stage="dependencies"
    exit 1
  fi
done
if [[ ! -d "$bundle_dir/appimage" ]]; then
  printf 'AppImage bundle directory is unavailable: %s/appimage\n' "$bundle_dir" >&2
  failure_stage="artifact_selection"
  exit 1
fi
mapfile -d '' -t appimages < <(find "$bundle_dir/appimage" -maxdepth 1 -type f -name '*.AppImage' -print0 | sort -z)
if ((${#appimages[@]} != 1)) || [[ ! -x "${appimages[0]}" ]]; then
  printf 'Expected exactly one executable AppImage under %s/appimage.\n' "$bundle_dir" >&2
  failure_stage="artifact_selection"
  exit 1
fi
launcher="${appimages[0]}"

mkdir -p "$work_dir/runtime" "$work_dir/config" "$work_dir/cache" "$work_dir/data"
chmod 700 "$work_dir/runtime"

weston_help="$(weston --help 2>&1 || true)"
renderer_option=()
if grep -q -- '--renderer' <<<"$weston_help"; then
  renderer_option=(--renderer=pixman)
elif grep -q -- '--use-pixman' <<<"$weston_help"; then
  renderer_option=(--use-pixman)
fi

failure_stage="weston_startup"
DISPLAY='' WAYLAND_DISPLAY='' XDG_RUNTIME_DIR="$work_dir/runtime" \
  setsid weston \
    --backend=headless-backend.so \
    --socket="$socket_name" \
    --idle-time=0 \
    --no-config \
    --width="$output_width" \
    --height="$output_height" \
    --scale="$scale" \
    "${renderer_option[@]}" \
    >"$diagnostics_dir/weston.log" 2>&1 &
weston_pid=$!

for _ in {1..100}; do
  if [[ -S "$work_dir/runtime/$socket_name" ]]; then
    break
  fi
  if ! kill -0 "$weston_pid" 2>/dev/null; then
    printf 'Weston exited before its Wayland socket became available.\n' >&2
    exit 1
  fi
  sleep 0.1
done
if [[ ! -S "$work_dir/runtime/$socket_name" ]]; then
  printf 'Timed out waiting for the Weston Wayland socket.\n' >&2
  exit 1
fi

failure_stage="wayland_output"
if ! DISPLAY='' XDG_RUNTIME_DIR="$work_dir/runtime" WAYLAND_DISPLAY="$socket_name" \
  timeout 5s wayland-info >"$diagnostics_dir/wayland-info.log" 2>&1; then
  printf 'wayland-info could not inspect the isolated compositor.\n' >&2
  exit 1
fi
if ! grep -Eq "scale:[[:space:]]*$scale([[:space:]]|$)" "$diagnostics_dir/wayland-info.log"; then
  printf 'The isolated compositor did not advertise the requested scale %s.\n' "$scale" >&2
  exit 1
fi

failure_stage="application_startup"
launch_started_ms="$(date +%s%3N)"
DISPLAY='' \
  WAYLAND_DISPLAY="$socket_name" \
  XDG_RUNTIME_DIR="$work_dir/runtime" \
  XDG_CONFIG_HOME="$work_dir/config" \
  XDG_CACHE_HOME="$work_dir/cache" \
  XDG_DATA_HOME="$work_dir/data" \
  XDG_SESSION_TYPE=wayland \
  GDK_BACKEND=wayland \
  GDK_SCALE="$scale" \
  GDK_DPI_SCALE=1 \
  GTK_A11Y=1 \
  GTK_MODULES=gail:atk-bridge \
  NO_AT_BRIDGE=0 \
  LANG=zh_CN.UTF-8 \
  LC_ALL=zh_CN.UTF-8 \
  APPIMAGE_EXTRACT_AND_RUN=1 \
  LIBGL_ALWAYS_SOFTWARE=1 \
  WEBKIT_DISABLE_COMPOSITING_MODE=1 \
  WEBKIT_DISABLE_DMABUF_RENDERER=1 \
  setsid "$launcher" >"$diagnostics_dir/application.log" 2>&1 &
app_pid=$!

failure_stage="atspi"
if ! DISPLAY='' WAYLAND_DISPLAY="$socket_name" XDG_RUNTIME_DIR="$work_dir/runtime" \
  python3 "$script_dir/check-linux-atspi.py" \
    --window-name "$window_title" \
    --require-name "跳到工作区" \
    --require-name "选择仓库" \
    --require-name "RepoPress 编辑工作区" \
    --timeout-ms "$timeout_ms" \
    --output "$diagnostics_dir/atspi.json"; then
  printf 'The AppImage did not expose the required AT-SPI window and control names.\n' >&2
  result="atspi_failed"
  exit 1
fi
if ! kill -0 "$app_pid" 2>/dev/null; then
  wait "$app_pid" || true
  printf 'The AppImage exited before the accessibility check completed.\n' >&2
  result="application_exited"
  failure_stage="application_startup"
  exit 1
fi

observed_ms="$(date +%s%3N)"
startup_ms=$((observed_ms - launch_started_ms))
if ((startup_ms > timeout_ms)); then
  printf 'Wayland/AT-SPI readiness exceeded the %sms budget (%sms).\n' "$timeout_ms" "$startup_ms" >&2
  result="exceeded_budget"
  failure_stage="budget"
  exit 1
fi

result="passed"
failure_stage="complete"
printf 'Wayland/AT-SPI smoke passed at %sx after %sms (budget %sms).\n' \
  "$scale" "$startup_ms" "$timeout_ms"
