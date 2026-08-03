#!/usr/bin/env bash
set -euo pipefail

CODESIGN_TOOL="${CODESIGN_TOOL:-/usr/bin/codesign}"
PLUTIL_TOOL="${PLUTIL_TOOL:-/usr/bin/plutil}"
PYTHON_TOOL="${PYTHON_TOOL:-/usr/bin/python3}"
FRAMEWORK=""
IDENTITY=""
EXPECTED_TEAM=""
TIMESTAMP=0
VALIDATE_ONLY=0
REQUIRE_DEVELOPER_ID=0
TMP_DIR=""

usage() {
  cat <<'USAGE'
Usage: script/sign_sparkle_framework.sh --framework <Sparkle.framework> [options]

Explicitly signs Sparkle's nested code in the required inside-out order:
Installer.xpc, Downloader.xpc (retaining its shipped entitlements),
Autoupdate, Updater.app, and finally Sparkle.framework.

Options:
  --identity <identity>       Signing identity; required unless --validate-only.
  --timestamp                 Request Apple's secure signing timestamp.
  --validate-only             Verify layout and signatures without changing code.
  --require-developer-id      Require Developer ID Application authorities.
  --expected-team <team-id>   Require every component to use this team.
USAGE
}

fail() {
  echo "Sparkle signing: $*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --framework)
      [[ "$#" -ge 2 ]] || fail "--framework requires a path"
      FRAMEWORK="$2"
      shift 2
      ;;
    --identity)
      [[ "$#" -ge 2 ]] || fail "--identity requires a value"
      IDENTITY="$2"
      shift 2
      ;;
    --timestamp)
      TIMESTAMP=1
      shift
      ;;
    --validate-only)
      VALIDATE_ONLY=1
      shift
      ;;
    --require-developer-id)
      REQUIRE_DEVELOPER_ID=1
      shift
      ;;
    --expected-team)
      [[ "$#" -ge 2 ]] || fail "--expected-team requires a value"
      EXPECTED_TEAM="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "$FRAMEWORK" ]] || fail "--framework is required"
[[ -d "$FRAMEWORK" ]] || fail "framework is missing: $FRAMEWORK"
if [[ "$VALIDATE_ONLY" == "0" && -z "$IDENTITY" ]]; then
  fail "--identity is required when signing"
fi
[[ -x "$CODESIGN_TOOL" ]] || fail "codesign is unavailable: $CODESIGN_TOOL"
[[ -x "$PLUTIL_TOOL" ]] || fail "plutil is unavailable: $PLUTIL_TOOL"
[[ -x "$PYTHON_TOOL" ]] || fail "python3 is unavailable: $PYTHON_TOOL"

[[ -L "$FRAMEWORK/Versions/Current" ]] \
  || fail "Versions/Current is not a preserved framework symlink"
[[ -L "$FRAMEWORK/Sparkle" ]] \
  || fail "the top-level Sparkle binary is not a preserved framework symlink"
version_root="$FRAMEWORK/Versions/Current"
installer="$version_root/XPCServices/Installer.xpc"
downloader="$version_root/XPCServices/Downloader.xpc"
autoupdate="$version_root/Autoupdate"
updater="$version_root/Updater.app"
for component in "$installer" "$downloader" "$autoupdate" "$updater"; do
  [[ -e "$component" ]] || fail "required nested component is missing: $component"
done

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/repopress-sparkle-signing.XXXXXX")"
downloader_entitlements="$TMP_DIR/downloader-entitlements.plist"

signature_report() {
  local component="$1"
  local report="$2"
  "$CODESIGN_TOOL" -dv --verbose=4 "$component" >"$report" 2>&1 \
    || fail "could not inspect signature: $component"
}

validate_component() {
  local component="$1"
  local label="$2"
  local report="$TMP_DIR/$label-signature.txt"
  local team=""

  "$CODESIGN_TOOL" --verify --strict --verbose=2 "$component" \
    || fail "$label signature verification failed"
  signature_report "$component" "$report"
  grep -Eq '^CodeDirectory .*flags=.*runtime' "$report" \
    || fail "$label signature does not prove hardened runtime"
  if [[ "$REQUIRE_DEVELOPER_ID" == "1" ]]; then
    grep -Eq '^Authority=Developer ID Application:' "$report" \
      || fail "$label is not signed with Developer ID Application"
  fi
  team="$(sed -n 's/^TeamIdentifier=//p' "$report" | head -n 1)"
  if [[ -n "$EXPECTED_TEAM" && "$team" != "$EXPECTED_TEAM" ]]; then
    fail "$label TeamIdentifier does not match $EXPECTED_TEAM"
  fi
}

if [[ "$VALIDATE_ONLY" == "0" ]]; then
  "$CODESIGN_TOOL" -d --entitlements :- "$downloader" \
    >"$downloader_entitlements" 2>/dev/null \
    || fail "could not extract the shipped Downloader.xpc entitlements"
  "$PLUTIL_TOOL" -lint "$downloader_entitlements" >/dev/null \
    || fail "the shipped Downloader.xpc entitlements are invalid"

  sign_arguments=(--force --options runtime --sign "$IDENTITY")
  if [[ "$TIMESTAMP" == "1" ]]; then
    sign_arguments+=(--timestamp)
  fi
  "$CODESIGN_TOOL" "${sign_arguments[@]}" "$installer"
  "$CODESIGN_TOOL" "${sign_arguments[@]}" \
    --entitlements "$downloader_entitlements" "$downloader"
  "$CODESIGN_TOOL" "${sign_arguments[@]}" "$autoupdate"
  "$CODESIGN_TOOL" "${sign_arguments[@]}" "$updater"
  "$CODESIGN_TOOL" "${sign_arguments[@]}" "$FRAMEWORK"

  retained_entitlements="$TMP_DIR/retained-downloader-entitlements.plist"
  "$CODESIGN_TOOL" -d --entitlements :- "$downloader" \
    >"$retained_entitlements" 2>/dev/null \
    || fail "could not re-read Downloader.xpc entitlements after signing"
  "$PYTHON_TOOL" - "$downloader_entitlements" "$retained_entitlements" <<'PY'
import plistlib
from pathlib import Path
import sys

with Path(sys.argv[1]).open("rb") as handle:
    before = plistlib.load(handle)
with Path(sys.argv[2]).open("rb") as handle:
    after = plistlib.load(handle)
if before != after:
    raise SystemExit("Sparkle signing: Downloader.xpc entitlements changed while re-signing")
PY
fi

validate_component "$installer" installer
validate_component "$downloader" downloader
validate_component "$autoupdate" autoupdate
validate_component "$updater" updater
validate_component "$FRAMEWORK" framework

if [[ "$VALIDATE_ONLY" == "1" ]]; then
  echo "Sparkle signing: nested signature validation passed"
else
  echo "Sparkle signing: explicit inside-out signing and validation passed"
fi
