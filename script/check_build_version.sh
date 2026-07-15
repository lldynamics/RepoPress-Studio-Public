#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_PATH="${BUILD_VERSION_CONFIG:-$ROOT_DIR/Packaging/BuildVersion.xcconfig}"
INFO_PLIST=""
PRINT_VALUES=0

usage() {
  cat >&2 <<'USAGE'
Usage: script/check_build_version.sh [--config <path>] [--info-plist <path>] [--print-values]

Validates the single app-version source. When --info-plist is provided, the
packaged CFBundleShortVersionString and CFBundleVersion must match it exactly.

Options:
  --config <path>       Override Packaging/BuildVersion.xcconfig.
  --info-plist <path>   Also verify a packaged Info.plist.
  --print-values        Print marketing version and build number separated by a tab.
USAGE
}

fail() {
  echo "build version gate: $*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --config)
      [[ "$#" -ge 2 ]] || fail "--config requires a path"
      CONFIG_PATH="$2"
      shift 2
      ;;
    --info-plist)
      [[ "$#" -ge 2 ]] || fail "--info-plist requires a path"
      INFO_PLIST="$2"
      shift 2
      ;;
    --print-values)
      PRINT_VALUES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      fail "unknown argument: $1"
      ;;
  esac
done

if [[ "$CONFIG_PATH" != /* ]]; then
  CONFIG_PATH="$ROOT_DIR/$CONFIG_PATH"
fi
if [[ -n "$INFO_PLIST" && "$INFO_PLIST" != /* ]]; then
  INFO_PLIST="$ROOT_DIR/$INFO_PLIST"
fi

[[ -f "$CONFIG_PATH" ]] || fail "version config is missing: ${CONFIG_PATH#$ROOT_DIR/}"

read_config_value() {
  local key="$1"
  local declaration_count
  local value
  declaration_count="$(
    awk -v key="$key" '
      $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { count += 1 }
      END { print count + 0 }
    ' "$CONFIG_PATH"
  )"
  [[ "$declaration_count" -gt 0 ]] || fail "$key is missing from ${CONFIG_PATH#$ROOT_DIR/}"
  [[ "$declaration_count" -eq 1 ]] || fail "$key must be declared exactly once in ${CONFIG_PATH#$ROOT_DIR/}"
  value="$(
    awk -v key="$key" '
      $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
        sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "")
        sub(/[[:space:]]*\r?$/, "")
        print
        exit
      }
    ' "$CONFIG_PATH"
  )"
  printf '%s' "$value"
}

marketing_version="$(read_config_value MARKETING_VERSION)"
build_number="$(read_config_value CURRENT_PROJECT_VERSION)"

[[ "$marketing_version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] \
  || fail "MARKETING_VERSION must contain two or three numeric components, got: $marketing_version"
[[ "$marketing_version" =~ [1-9] ]] \
  || fail "MARKETING_VERSION must not be a zero placeholder"
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] \
  || fail "CURRENT_PROJECT_VERSION must be a positive integer, got: $build_number"

if [[ -n "$INFO_PLIST" ]]; then
  [[ -f "$INFO_PLIST" ]] || fail "Info.plist is missing: ${INFO_PLIST#$ROOT_DIR/}"
  /usr/bin/plutil -lint "$INFO_PLIST" >/dev/null || fail "Info.plist is invalid: ${INFO_PLIST#$ROOT_DIR/}"
  packaged_marketing_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)"
  packaged_build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST" 2>/dev/null || true)"
  [[ "$packaged_marketing_version" == "$marketing_version" ]] \
    || fail "CFBundleShortVersionString $packaged_marketing_version does not match MARKETING_VERSION $marketing_version"
  [[ "$packaged_build_number" == "$build_number" ]] \
    || fail "CFBundleVersion $packaged_build_number does not match CURRENT_PROJECT_VERSION $build_number"
fi

if [[ "$PRINT_VALUES" == "1" ]]; then
  printf '%s\t%s\n' "$marketing_version" "$build_number"
else
  echo "build version gate: version $marketing_version ($build_number) is valid and consistent"
fi
