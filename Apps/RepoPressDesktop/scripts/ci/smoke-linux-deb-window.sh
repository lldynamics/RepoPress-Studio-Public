#!/usr/bin/env bash
# Launch the packaged Debian binary in Xvfb and require its declared window to
# become visible. This tests a real release executable, not `tauri dev`.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: smoke-linux-deb-window.sh --bundle-dir DIRECTORY --diagnostics-dir DIRECTORY [--kind deb|appimage] [--launcher PATH] [--window-title TITLE] [--timeout-ms N]

When --launcher is omitted, the executable is extracted from the Debian bundle.
Requires Xvfb, xdotool, xwininfo, dbus-run-session, and setsid; extraction also
requires dpkg-deb.
EOF
}

bundle_dir=""
diagnostics_dir=""
launcher_path=""
kind="deb"
window_title="RepoPress Studio"
timeout_ms=20000
timeout_seconds_compat=""
timeout_ms_set=0
timeout_seconds_set=0

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
    --launcher)
      launcher_path="${2:-}"
      shift 2
      ;;
    --kind)
      kind="${2:-}"
      shift 2
      ;;
    --window-title)
      window_title="${2:-}"
      shift 2
      ;;
    --timeout-ms)
      timeout_ms="${2:-}"
      timeout_ms_set=1
      shift 2
      ;;
    --timeout-seconds)
      timeout_seconds_compat="${2:-}"
      timeout_seconds_set=1
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

if [[ "$kind" != "deb" && "$kind" != "appimage" ]]; then
  printf 'Kind must be deb or appimage: %s\n' "$kind" >&2
  exit 2
fi

if ((timeout_ms_set && timeout_seconds_set)); then
  printf 'Specify only one timeout budget option.\n' >&2
  exit 2
fi
if [[ -n "$timeout_seconds_compat" ]]; then
  if ! [[ "$timeout_seconds_compat" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Timeout must be a positive integer number of seconds: %s\n' "$timeout_seconds_compat" >&2
    exit 2
  fi
  timeout_ms=$((timeout_seconds_compat * 1000))
fi
if ! [[ "$timeout_ms" =~ ^[1-9][0-9]*$ ]]; then
  printf 'Timeout must be a strict positive integer number of milliseconds: %s\n' "$timeout_ms" >&2
  exit 2
fi

for command in Xvfb xdotool xwininfo xdpyinfo dbus-run-session setsid; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Required command is unavailable: %s\n' "$command" >&2
    exit 1
  fi
done

mkdir -p "$diagnostics_dir"
diagnostics_dir="$(cd "$diagnostics_dir" && pwd)"
work_dir="$(mktemp -d)"
xvfb_pid=""
app_pid=""
launch_started_ms=""
display=99

dump_diagnostics() {
  {
    printf '=== process tree ===\n'
    ps -eo pid,ppid,pgid,stat,etime,args --forest || true
    printf '\n=== Xvfb log ===\n'
    [[ -f "$diagnostics_dir/xvfb.log" ]] && tail -n 200 "$diagnostics_dir/xvfb.log" || true
    printf '\n=== application log ===\n'
    [[ -f "$diagnostics_dir/application.log" ]] && tail -n 300 "$diagnostics_dir/application.log" || true
    printf '\n=== visible X windows ===\n'
    DISPLAY=":$display" xwininfo -root -tree || true
    printf '\n=== xdotool window search ===\n'
    DISPLAY=":$display" xdotool search --onlyvisible --name "$window_title" || true
  } >"$diagnostics_dir/window-smoke-diagnostics.log" 2>&1
}

write_timing() {
  local visible_ms="$1"
  local elapsed_ms=$((visible_ms - launch_started_ms))
  local result="passed"
  if ((elapsed_ms > timeout_ms)); then
    result="exceeded_budget"
  fi
  python3 - "$diagnostics_dir/window-startup.json" "$kind" "$window_title" "$elapsed_ms" "$timeout_ms" "$result" <<'PY'
import json, pathlib, sys
path, kind, title, elapsed, budget, result = sys.argv[1:]
with pathlib.Path(path).open("w", encoding="utf-8") as stream:
    json.dump({"kind": kind, "window_title": title, "startup_ms": int(elapsed),
              "budget_ms": int(budget), "result": result},
              stream, separators=(",", ":"))
    stream.write("\n")
PY
  printf 'Window visible after %sms (budget %sms)\n' "$elapsed_ms" "$timeout_ms" \
    | tee -a "$diagnostics_dir/application.log"
  if [[ "$result" == "exceeded_budget" ]]; then
    printf 'Window startup exceeded the %sms budget.\n' "$timeout_ms" >&2
    return 1
  fi
}

write_timeout() {
  python3 - "$diagnostics_dir/window-startup.json" "$kind" "$window_title" "$timeout_ms" <<'PY'
import json, pathlib, sys
path, kind, title, budget = sys.argv[1:]
with pathlib.Path(path).open("w", encoding="utf-8") as stream:
    json.dump({"kind": kind, "window_title": title, "startup_ms": None,
              "budget_ms": int(budget), "result": "timed_out"},
              stream, separators=(",", ":"))
    stream.write("\n")
PY
}

cleanup() {
  cleanup_status=$?
  dump_diagnostics
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill -- "-$app_pid" 2>/dev/null || true
    for _ in {1..20}; do
      kill -0 "$app_pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL -- "-$app_pid" 2>/dev/null || true
  fi
  if [[ -n "$xvfb_pid" ]] && kill -0 "$xvfb_pid" 2>/dev/null; then
    kill "$xvfb_pid" 2>/dev/null || true
  fi
  rm -rf "$work_dir"
  exit "$cleanup_status"
}
trap cleanup EXIT

if [[ -n "$launcher_path" ]]; then
  if [[ ! -x "$launcher_path" ]]; then
    printf 'Installed launcher is missing or not executable: %s\n' "$launcher_path" >&2
    exit 1
  fi
  launcher="$launcher_path"
elif [[ "$kind" == "deb" ]]; then
  if ! command -v dpkg-deb >/dev/null 2>&1; then
    printf 'Required command is unavailable: dpkg-deb\n' >&2
    exit 1
  fi
  mapfile -d '' -t debs < <(find "$bundle_dir/deb" -maxdepth 1 -type f -name '*.deb' -print0 2>/dev/null | sort -z)
  if ((${#debs[@]} != 1)); then
    printf 'Expected exactly one Debian bundle under %s/deb; found %d.\n' "$bundle_dir" "${#debs[@]}" >&2
    exit 1
  fi
  dpkg-deb --extract "${debs[0]}" "$work_dir/package"
  mapfile -d '' -t launchers < <(find "$work_dir/package/usr/bin" -maxdepth 1 -type f -perm -111 -print0 2>/dev/null | sort -z)
  if ((${#launchers[@]} != 1)); then
    printf 'Expected exactly one executable under the package usr/bin directory; found %d.\n' "${#launchers[@]}" >&2
    printf '  %s\n' "${launchers[@]:-<none>}" >&2
    exit 1
  fi
  launcher="${launchers[0]}"
else
  mapfile -d '' -t appimages < <(find "$bundle_dir/appimage" -maxdepth 1 -type f -name '*.AppImage' -print0 2>/dev/null | sort -z)
  if ((${#appimages[@]} != 1)) || [[ ! -x "${appimages[0]}" ]]; then
    printf 'Expected exactly one executable AppImage under %s/appimage.\n' "$bundle_dir" >&2
    exit 1
  fi
  launcher="${appimages[0]}"
fi

Xvfb ":$display" -screen 0 1440x900x24 -nolisten tcp -ac >"$diagnostics_dir/xvfb.log" 2>&1 &
xvfb_pid=$!
for _ in {1..50}; do
  if DISPLAY=":$display" xdpyinfo >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$xvfb_pid" 2>/dev/null; then
    printf 'Xvfb exited before its display became available.\n' >&2
    exit 1
  fi
  sleep 0.1
done
if ! DISPLAY=":$display" xdpyinfo >/dev/null 2>&1; then
  printf 'Timed out waiting for Xvfb display :%s.\n' "$display" >&2
  exit 1
fi

mkdir -p "$work_dir/config" "$work_dir/cache" "$work_dir/data" "$work_dir/runtime"
chmod 700 "$work_dir/runtime"
launch_started_ms="$(date +%s%3N)"
DISPLAY=":$display" \
  GDK_BACKEND=x11 \
  APPIMAGE_EXTRACT_AND_RUN=1 \
  WEBKIT_DISABLE_COMPOSITING_MODE=1 \
  XDG_CONFIG_HOME="$work_dir/config" \
  XDG_CACHE_HOME="$work_dir/cache" \
  XDG_DATA_HOME="$work_dir/data" \
  XDG_RUNTIME_DIR="$work_dir/runtime" \
  setsid dbus-run-session -- "$launcher" >"$diagnostics_dir/application.log" 2>&1 &
app_pid=$!

deadline_ms=$((launch_started_ms + timeout_ms))
while :; do
  if ! kill -0 "$app_pid" 2>/dev/null; then
    wait "$app_pid" || true
    printf 'Packaged application exited before opening a visible window.\n' >&2
    exit 1
  fi

  mapfile -t window_ids < <(DISPLAY=":$display" xdotool search --onlyvisible --name "$window_title" 2>/dev/null || true)
  if ((${#window_ids[@]} > 0)); then
    visible_ms="$(date +%s%3N)"
    write_timing "$visible_ms"
    printf 'Window smoke passed: %s (X11 window IDs: %s)\n' "$window_title" "${window_ids[*]}"
    exit 0
  fi
  now_ms="$(date +%s%3N)"
  if ((now_ms >= deadline_ms)); then
    break
  fi
  sleep 0.25
done

write_timeout
printf 'Timed out after %sms waiting for a visible window named %q.\n' "$timeout_ms" "$window_title" >&2
exit 1
