#!/usr/bin/env bash
# Offline regression checks for argument validation, artifact selection, and signed updater trust.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
desktop_root="$(cd "$root/../.." && pwd)"
repo_root="$(cd "$desktop_root/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
python3 "$root/check-linux-ocr-workflow.py" \
  "$repo_root/.github/workflows/tauri-desktop.yml"
python3 "$root/test-linux-atspi.py"
python3 "$root/test-linux-release-evidence.py"
bash "$root/test-linux-wayland-atspi.sh"
if "$root/smoke-linux-deb-window.sh" --unknown >/dev/null 2>&1; then
  printf 'smoke script accepted an unknown argument.\n' >&2; exit 1
fi
for invalid_timeout in 0 -1 1.5 1x ''; do
  if "$root/smoke-linux-deb-window.sh" --bundle-dir "$tmp" --diagnostics-dir "$tmp/diag" \
    --timeout-ms "$invalid_timeout" >/dev/null 2>&1; then
    printf 'smoke script accepted an invalid millisecond budget: %s\n' "$invalid_timeout" >&2
    exit 1
  fi
done
if "$root/smoke-linux-deb-window.sh" --bundle-dir "$tmp" --diagnostics-dir "$tmp/diag" \
  --timeout-ms 1 --timeout-seconds 1 >/dev/null 2>&1; then
  printf 'smoke script accepted conflicting timeout options.\n' >&2; exit 1
fi
# Use command shims to exercise the real timeout path without requiring a
# desktop session. The launcher never creates a window, so a 1ms budget must
# produce a timed_out JSON result and a non-zero exit status.
shim_bin="$tmp/shims"; mkdir -p "$shim_bin"
printf '#!/usr/bin/env bash\nsleep 30\n' >"$shim_bin/Xvfb"
printf '#!/usr/bin/env bash\nexit 1\n' >"$shim_bin/xdotool"
printf '#!/usr/bin/env bash\nexit 0\n' >"$shim_bin/xwininfo"
printf '#!/usr/bin/env bash\nexit 0\n' >"$shim_bin/xdpyinfo"
printf '#!/usr/bin/env bash\nif [[ ${1:-} == -- ]]; then shift; fi\nexec "$@"\n' >"$shim_bin/dbus-run-session"
chmod +x "$shim_bin"/*
printf '#!/usr/bin/env bash\nsleep 30\n' >"$tmp/fake-appimage"; chmod +x "$tmp/fake-appimage"
mkdir -p "$tmp/fake-bundle/appimage"
cp "$tmp/fake-appimage" "$tmp/fake-bundle/appimage/Fake.AppImage"
timeout_diag="$tmp/timeout-diag"
if PATH="$shim_bin:$PATH" "$root/smoke-linux-deb-window.sh" --kind appimage \
  --bundle-dir "$tmp/fake-bundle" --diagnostics-dir "$timeout_diag" --timeout-ms 1 >/dev/null 2>&1; then
  printf 'smoke script did not fail when the window budget elapsed.\n' >&2; exit 1
fi
python3 - "$timeout_diag/window-startup.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["budget_ms"] == 1 and data["result"] == "timed_out"
PY
# Freeze the clock and report a window after the budget to exercise the
# write_timing decision/serialization branch without relying on wall-clock
# scheduling.
overrun_shims="$tmp/overrun-shims"; cp -a "$shim_bin" "$overrun_shims"
printf '#!/usr/bin/env bash\nif [[ -e "%s/date-seen" ]]; then printf "1000000000005\\n"; else touch "%s/date-seen"; printf "1000000000000\\n"; fi\n' "$tmp" "$tmp" >"$overrun_shims/date"
printf '#!/usr/bin/env bash\nprintf "window-id\\n"\n' >"$overrun_shims/xdotool"
chmod +x "$overrun_shims/date" "$overrun_shims/xdotool"
overrun_diag="$tmp/overrun-diag"
if PATH="$overrun_shims:$PATH" "$root/smoke-linux-deb-window.sh" --kind appimage \
  --bundle-dir "$tmp/fake-bundle" --diagnostics-dir "$overrun_diag" \
  --timeout-ms 1 >/dev/null 2>&1; then
  printf 'smoke script accepted a window observed after the budget.\n' >&2; exit 1
fi
python3 - "$overrun_diag/window-startup.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["startup_ms"] == 5 and data["budget_ms"] == 1
assert data["result"] == "exceeded_budget"
PY
# Fixture assertion: a package-owned directory may remain; only leaf files are
# candidates for the post-uninstall check.
fixture_dir="$tmp/package/usr/bin"; mkdir -p "$fixture_dir"; fixture_file="$fixture_dir/repopress"
printf 'fixture\n' >"$fixture_file"
if [[ ! -d "$fixture_dir" || -d "$fixture_file" ]]; then exit 1; fi
if ! grep -Fq '[[ -L "$path" ]]' "$root/check-deb-uninstall.sh"; then
  printf 'uninstall checker does not filter directory paths.\n' >&2; exit 1
fi
tauri="$desktop_root/node_modules/.bin/tauri"
if [[ ! -x "$tauri" ]]; then printf 'Locked Tauri CLI is unavailable: %s\n' "$tauri" >&2; exit 1; fi
mkdir -p "$tmp/bundle"
printf 'AppImage fixture\n' >"$tmp/bundle/RepoPress.AppImage"
"$tauri" signer generate --ci --write-keys "$tmp/test-only-key" >/dev/null 2>&1
"$tauri" signer sign --private-key-path "$tmp/test-only-key" --password '' \
  "$tmp/bundle/RepoPress.AppImage" >/dev/null 2>&1
python3 - "$tmp/bundle/latest.json" "$tmp/bundle/RepoPress.AppImage.sig" <<'PY'
import json, pathlib, sys
signature = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").strip()
json.dump({
    "version": "0.1.0",
    "notes": "test-only updater fixture",
    "pub_date": "2026-01-01T00:00:00Z",
    "platforms": {"linux-x86_64": {
        "signature": signature,
        "url": "https://downloads.example.test/RepoPress.AppImage",
    }},
}, open(sys.argv[1], "w", encoding="utf-8"))
PY
validate=(python3 "$root/validate-updater-manifest.py"
  --bundle-dir "$tmp/bundle"
  --manifest "$tmp/bundle/latest.json"
  --version 0.1.0
  --release-tag v0.1.0
  --public-key "$tmp/test-only-key.pub"
  --review-summary "$tmp/bundle/updater-review.json")
result="$("${validate[@]}")"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["sha256"] and d["signature_algorithm"] == "ED" and d["signing_key_id"]' "$result"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["release_tag"] == "v0.1.0"' "$tmp/bundle/updater-review.json"
cp "$tmp/bundle/latest.json" "$tmp/valid-latest.json"
cp "$tmp/bundle/RepoPress.AppImage.sig" "$tmp/valid-signature"

expect_validation_failure() {
  local message="$1"
  if "${validate[@]}" >/dev/null 2>&1; then
    printf '%s\n' "$message" >&2
    exit 1
  fi
}

mutate_manifest() {
  local operation="$1"
  local value="${2-}"
  python3 - "$tmp/bundle/latest.json" "$operation" "$value" <<'PY'
import json, os, pathlib, sys, tempfile
manifest = pathlib.Path(sys.argv[1])
operation, value = sys.argv[2:4]
data = json.loads(manifest.read_text(encoding="utf-8"))
if operation == "url":
    data["platforms"]["linux-x86_64"]["url"] = value
elif operation == "notes-control":
    data["notes"] = "unsafe\nnotes"
elif operation == "pub-date":
    data["pub_date"] = value
elif operation == "extra-platform":
    data["platforms"]["darwin-x86_64"] = data["platforms"]["linux-x86_64"].copy()
elif operation == "signature":
    data["platforms"]["linux-x86_64"]["signature"] = value
else:
    raise AssertionError(f"unknown fixture operation: {operation}")
temporary = None
try:
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=manifest.parent, prefix=".fixture-", delete=False
    ) as stream:
        temporary = pathlib.Path(stream.name)
        json.dump(data, stream)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, manifest)
    temporary = None
finally:
    if temporary is not None:
        temporary.unlink(missing_ok=True)
PY
}

# The same signature must fail after any payload mutation.
cp "$tmp/bundle/RepoPress.AppImage" "$tmp/original.AppImage"
printf 'tampered\n' >>"$tmp/bundle/RepoPress.AppImage"
expect_validation_failure 'updater validator accepted a modified AppImage.'
cp "$tmp/original.AppImage" "$tmp/bundle/RepoPress.AppImage"

# Content signatures are not portable to a renamed artifact: the globally
# signed trusted-comment file field must still name the selected basename.
mv "$tmp/bundle/RepoPress.AppImage" "$tmp/bundle/Renamed.AppImage"
mv "$tmp/bundle/RepoPress.AppImage.sig" "$tmp/bundle/Renamed.AppImage.sig"
cp "$tmp/valid-latest.json" "$tmp/bundle/latest.json"
mutate_manifest url "https://downloads.example.test/Renamed.AppImage"
expect_validation_failure 'updater validator accepted a renamed AppImage with an unchanged signature.'
mv "$tmp/bundle/Renamed.AppImage" "$tmp/bundle/RepoPress.AppImage"
mv "$tmp/bundle/Renamed.AppImage.sig" "$tmp/bundle/RepoPress.AppImage.sig"
cp "$tmp/valid-latest.json" "$tmp/bundle/latest.json"

# A different, well-formed public key must not verify the candidate.
"$tauri" signer generate --ci --write-keys "$tmp/wrong-test-only-key" >/dev/null 2>&1
wrong_key_validate=("${validate[@]}")
wrong_key_validate[11]="$tmp/wrong-test-only-key.pub"
if "${wrong_key_validate[@]}" >/dev/null 2>&1; then
  printf 'updater validator accepted a signature from a different key.\n' >&2; exit 1
fi

# Tag/version and URL/artifact bindings fail before release review output is trusted.
mismatched_tag_validate=("${validate[@]}")
mismatched_tag_validate[9]="v0.2.0"
if "${mismatched_tag_validate[@]}" >/dev/null 2>&1; then
  printf 'updater validator accepted a mismatched release tag.\n' >&2; exit 1
fi

cp "$tmp/valid-latest.json" "$tmp/bundle/latest.json"
mutate_manifest url "https://downloads.example.test/Other.AppImage"
expect_validation_failure 'updater validator accepted a URL for a different AppImage.'

for unsafe_url in \
  'http://downloads.example.test/RepoPress.AppImage' \
  'https://user:secret@downloads.example.test/RepoPress.AppImage' \
  'https://@downloads.example.test/RepoPress.AppImage' \
  'https://%40downloads.example.test/RepoPress.AppImage' \
  'https://downloads_example.test/RepoPress.AppImage' \
  'https://downloads.example.test:444/RepoPress.AppImage' \
  'https://127.1/RepoPress.AppImage' \
  'https://localhost/RepoPress.AppImage' \
  'https://downloads.local/RepoPress.AppImage' \
  'https://downloads.example.test/RepoPress.AppImage#fragment' \
  'https://downloads.example.test/RepoPress.AppImage#' \
  'https://downloads.example.test/RepoPress.AppImage;'; do
  cp "$tmp/valid-latest.json" "$tmp/bundle/latest.json"
  mutate_manifest url "$unsafe_url"
  expect_validation_failure "updater validator accepted unsafe URL: $unsafe_url"
done

cp "$tmp/valid-latest.json" "$tmp/bundle/latest.json"
mutate_manifest notes-control
expect_validation_failure 'updater validator accepted control characters in release notes.'

cp "$tmp/valid-latest.json" "$tmp/bundle/latest.json"
mutate_manifest pub-date '2026-01-01'
expect_validation_failure 'updater validator accepted a non-RFC3339 publication date.'

cp "$tmp/valid-latest.json" "$tmp/bundle/latest.json"
mutate_manifest extra-platform
expect_validation_failure 'updater validator accepted an extra update platform.'

cp "$tmp/valid-latest.json" "$tmp/bundle/latest.json"
noncanonical_signature="$(<"$tmp/valid-signature")="
printf '%s' "$noncanonical_signature" >"$tmp/bundle/RepoPress.AppImage.sig"
mutate_manifest signature "$noncanonical_signature"
expect_validation_failure 'updater validator accepted a noncanonical signature encoding.'
cp "$tmp/valid-signature" "$tmp/bundle/RepoPress.AppImage.sig"
cp "$tmp/valid-latest.json" "$tmp/bundle/latest.json"
printf 'Linux CI script self-test passed.\n'
