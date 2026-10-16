#!/usr/bin/env bash
# Offline orchestration tests for the Weston/AT-SPI smoke script.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$root/smoke-linux-wayland-atspi.sh"
tmp="$(mktemp -d)"
cleanup() {
  local status=$?
  if ((status != 0)) && [[ -d "$tmp" ]]; then
    find "$tmp" -maxdepth 3 -type f -print -exec sed -n '1,160p' {} \; >&2 || true
  fi
  rm -rf "$tmp"
  exit "$status"
}
trap cleanup EXIT

bash -n "$script"
if "$script" --unknown >/dev/null 2>&1; then
  printf 'Wayland smoke accepted an unknown argument.\n' >&2
  exit 1
fi
for invalid_scale in 0 3 1.5 ''; do
  if "$script" --bundle-dir "$tmp" --diagnostics-dir "$tmp/diag" \
    --scale "$invalid_scale" >/dev/null 2>&1; then
    printf 'Wayland smoke accepted an invalid scale: %s\n' "$invalid_scale" >&2
    exit 1
  fi
done
for invalid_timeout in 0 -1 1.5 120001 ''; do
  if "$script" --bundle-dir "$tmp" --diagnostics-dir "$tmp/diag" \
    --timeout-ms "$invalid_timeout" >/dev/null 2>&1; then
    printf 'Wayland smoke accepted an invalid timeout: %s\n' "$invalid_timeout" >&2
    exit 1
  fi
done

real_python="$(command -v python3)"
shim_bin="$tmp/shims"
mkdir -p "$shim_bin" "$tmp/bundle/appimage"

# Some repository sandboxes deliberately block AF_UNIX creation. Argument and
# syntax coverage above still runs there; ordinary CI continues through the
# complete fake-compositor orchestration path below.
if ! "$real_python" - "$tmp/socket-capability" >/dev/null 2>&1 <<'PY'
import pathlib
import socket
import sys

path = pathlib.Path(sys.argv[1])
server = socket.socket(socket.AF_UNIX)
try:
    server.bind(str(path))
finally:
    server.close()
    path.unlink(missing_ok=True)
PY
then
  if [[ "${REPOPRESS_REQUIRE_UNIX_SOCKET_FIXTURE:-0}" == "1" ]]; then
    printf 'Wayland/AT-SPI orchestration fixture requires AF_UNIX, but it is blocked.\n' >&2
    exit 1
  fi
  printf 'Wayland/AT-SPI orchestration fixture skipped: AF_UNIX is blocked.\n'
  exit 0
fi

cat >"$shim_bin/dbus-run-session" <<'SH'
#!/usr/bin/env bash
if [[ ${1:-} == -- ]]; then shift; fi
export DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/repopress-fixture-bus
exec "$@"
SH

cat >"$shim_bin/weston" <<SH
#!/usr/bin/env bash
if [[ \${1:-} == --help ]]; then
  printf '%s\n' '--renderer=TYPE --use-pixman'
  exit 0
fi
socket_name=''
scale=''
for argument in "\$@"; do
  case "\$argument" in
    --socket=*) socket_name="\${argument#--socket=}" ;;
    --scale=*) scale="\${argument#--scale=}" ;;
  esac
done
printf '%s\n' "\$scale" >"\$XDG_RUNTIME_DIR/fixture-scale"
exec "$real_python" - "\$XDG_RUNTIME_DIR/\$socket_name" <<'PY'
import socket
import sys
import time

server = socket.socket(socket.AF_UNIX)
server.bind(sys.argv[1])
server.listen()
time.sleep(30)
PY
SH

cat >"$shim_bin/wayland-info" <<'SH'
#!/usr/bin/env bash
printf "interface: 'wl_output'\n\tscale: %s\n" "$(cat "$XDG_RUNTIME_DIR/fixture-scale")"
SH

cat >"$shim_bin/python3" <<SH
#!/usr/bin/env bash
if [[ \${1:-} == */check-linux-atspi.py ]]; then
  output=''
  joined=" \$* "
  for required in '跳到工作区' '选择仓库' 'RepoPress 编辑工作区'; do
    if [[ "\$joined" != *" --require-name \$required "* ]]; then
      printf 'Missing required AT-SPI fixture name: %s\n' "\$required" >&2
      exit 9
    fi
  done
  while ((\$# > 0)); do
    if [[ \$1 == --output ]]; then output=\$2; shift 2; else shift; fi
  done
  printf '%s\n' '{"result":"passed","startup_ms":1,"window_name":"RepoPress Studio","matched_required_names":["跳到工作区","选择仓库","RepoPress 编辑工作区"]}' >"\$output"
  exit 0
fi
exec "$real_python" "\$@"
SH

cat >"$tmp/bundle/appimage/RepoPress.AppImage" <<'SH'
#!/usr/bin/env bash
printf 'backend=%s display=%s scale=%s session=%s locale=%s bridge=%s\n' \
  "${GDK_BACKEND:-}" "${DISPLAY:-}" "${GDK_SCALE:-}" "${XDG_SESSION_TYPE:-}" \
  "${LC_ALL:-}" "${NO_AT_BRIDGE:-}"
exec sleep 30
SH
chmod +x "$shim_bin"/* "$tmp/bundle/appimage/RepoPress.AppImage"

diagnostics="$tmp/diagnostics"
PATH="$shim_bin:$PATH" "$script" \
  --bundle-dir "$tmp/bundle" \
  --diagnostics-dir "$diagnostics" \
  --scale 2 \
  --timeout-ms 5000

"$real_python" - "$diagnostics/wayland-session.json" "$diagnostics/atspi.json" <<'PY'
import json
import pathlib
import sys

session = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
atspi = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
assert session["result"] == "passed" and session["failure_stage"] is None
assert session["backend"] == "wayland" and session["compositor"] == "weston-headless"
assert session["scale"] == 2 and session["output_width_px"] == 2880
assert session["output_height_px"] == 1800 and session["startup_ms"] <= 5000
assert atspi["result"] == "passed"
PY
grep -Fq 'backend=wayland display= scale=2 session=wayland locale=zh_CN.UTF-8 bridge=0' \
  "$diagnostics/application.log"
grep -Eq 'scale:[[:space:]]*2' "$diagnostics/wayland-info.log"

printf 'Wayland/AT-SPI smoke script self-test passed.\n'
