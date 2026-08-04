#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT_DIR/script/check_build_version.sh"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-build-version.XXXXXX)"
CONFIG="$TMP_DIR/BuildVersion.xcconfig"
INFO_PLIST="$TMP_DIR/Info.plist"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "build version gate test: $*" >&2
  exit 1
}

write_config() {
  printf '%s\n' "$@" >"$CONFIG"
}

write_info_plist() {
  local marketing_version="$1"
  local build_number="$2"
  /usr/bin/plutil -create xml1 "$INFO_PLIST"
  /usr/bin/plutil -insert CFBundleShortVersionString -string "$marketing_version" "$INFO_PLIST"
  /usr/bin/plutil -insert CFBundleVersion -string "$build_number" "$INFO_PLIST"
}

expect_failure() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "$description"
  fi
}

[[ -f "$GATE" ]] || fail "check_build_version.sh is missing"

write_config \
  'MARKETING_VERSION = 2.4.1' \
  'CURRENT_PROJECT_VERSION = 37'
values="$(bash "$GATE" --config "$CONFIG" --print-values)"
[[ "$values" == $'2.4.1\t37' ]] || fail "valid config returned unexpected values: $values"

write_info_plist 2.4.1 37
bash "$GATE" --config "$CONFIG" --info-plist "$INFO_PLIST" >/dev/null

expect_failure "gate accepted a missing config" \
  bash "$GATE" --config "$TMP_DIR/missing.xcconfig"

write_config 'CURRENT_PROJECT_VERSION = 37'
expect_failure "gate accepted a missing marketing version" \
  bash "$GATE" --config "$CONFIG"

write_config \
  'MARKETING_VERSION = 2.beta' \
  'CURRENT_PROJECT_VERSION = 37'
expect_failure "gate accepted a nonnumeric marketing version" \
  bash "$GATE" --config "$CONFIG"

write_config \
  'MARKETING_VERSION = 0.0' \
  'CURRENT_PROJECT_VERSION = 37'
expect_failure "gate accepted a zero marketing-version placeholder" \
  bash "$GATE" --config "$CONFIG"

write_config \
  'MARKETING_VERSION = 2.4.1' \
  'CURRENT_PROJECT_VERSION = 0'
expect_failure "gate accepted a zero build-number placeholder" \
  bash "$GATE" --config "$CONFIG"

write_config \
  'MARKETING_VERSION = 2.4.1' \
  'MARKETING_VERSION = 2.4.2' \
  'CURRENT_PROJECT_VERSION = 37'
expect_failure "gate accepted a duplicate marketing version" \
  bash "$GATE" --config "$CONFIG"

write_config \
  'MARKETING_VERSION = 2.4.1' \
  'CURRENT_PROJECT_VERSION = 37'
write_info_plist 2.4.0 37
expect_failure "gate accepted an inconsistent packaged marketing version" \
  bash "$GATE" --config "$CONFIG" --info-plist "$INFO_PLIST"

write_info_plist 2.4.1 38
expect_failure "gate accepted an inconsistent packaged build number" \
  bash "$GATE" --config "$CONFIG" --info-plist "$INFO_PLIST"

if grep -En '^(MARKETING_VERSION|BUILD_NUMBER)="[0-9]' "$ROOT_DIR/script/build_and_run.sh" >/dev/null; then
  fail "build_and_run.sh still hardcodes app version values"
fi
for consumer in \
  build_and_run.sh \
  check_app_store_metadata.sh \
  check_app_store_archive_readiness.sh \
  record_app_store_build_metadata_evidence.sh; do
  grep -Eq 'check_build_version\.sh' "$ROOT_DIR/script/$consumer" \
    || fail "$consumer does not consume the shared version gate"
done

quick_checks="$(bash "$ROOT_DIR/script/check_release_gate.sh" --quick --list)"
grep -q $'^build-version\talways\t' <<<"$quick_checks" \
  || fail "quick release gate omitted the lightweight version check"
grep -q $'^build-version-tests\talways\t' <<<"$quick_checks" \
  || fail "quick release gate omitted version behavior tests"

echo "build version gate test: passed"
