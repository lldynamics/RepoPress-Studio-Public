#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_STORE_BUILD_APP_NAME:-PersonalSitePublisherMac}"
APP_BUNDLE="${APP_STORE_BUILD_APP_BUNDLE:-$ROOT_DIR/dist/$APP_NAME.app}"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
APP_ICON="$APP_BUNDLE/Contents/Resources/AppIcon.icns"
ENTITLEMENTS="${APP_STORE_BUILD_ENTITLEMENTS:-$ROOT_DIR/Sources/PersonalSitePublisherMac/AppStore.entitlements}"
OUTPUT="${APP_STORE_BUILD_METADATA_EVIDENCE_FILE:-$ROOT_DIR/docs/release-evidence/APP_STORE_BUILD_METADATA.md}"
EXECUTE=0

usage() {
  cat <<'USAGE'
Usage: script/record_app_store_build_metadata_evidence.sh [--execute] [--dry-run] [--output <path>]

Validates and records local App Store build metadata: bundle identifier,
marketing version, build number, minimum macOS, icon, localized InfoPlist
strings, and sandbox/network/file-access entitlements.

This local evidence does not prove distribution signing team, hardened runtime,
clean Release archive reproducibility, or Transporter/App Store Connect upload
validation.
USAGE
}

fail() {
  echo "app store build metadata evidence: $*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --execute)
      EXECUTE=1
      shift
      ;;
    --dry-run)
      EXECUTE=0
      shift
      ;;
    --output)
      [[ "$#" -ge 2 ]] || fail "--output requires a path"
      OUTPUT="$2"
      shift 2
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

if [[ "$OUTPUT" != /* ]]; then
  OUTPUT="$ROOT_DIR/$OUTPUT"
fi

if [[ ! -d "$APP_BUNDLE" ]]; then
  if [[ "${APP_STORE_BUILD_METADATA_SKIP_BUILD:-0}" == "1" ]]; then
    fail "app bundle is missing: ${APP_BUNDLE#$ROOT_DIR/}"
  fi
  bash "$ROOT_DIR/script/build_and_run.sh" --package-only >/dev/null
fi

[[ -d "$APP_BUNDLE" ]] || fail "app bundle is missing: ${APP_BUNDLE#$ROOT_DIR/}"
[[ -f "$INFO_PLIST" ]] || fail "Info.plist is missing from app bundle"
[[ -x "$APP_BINARY" ]] || fail "app executable is missing or not executable"
[[ -s "$APP_ICON" ]] || fail "AppIcon.icns is missing from app bundle"
[[ -f "$ENTITLEMENTS" ]] || fail "AppStore entitlements file is missing"

plutil -lint "$INFO_PLIST" >/dev/null || fail "Info.plist is invalid"
plutil -lint "$ENTITLEMENTS" >/dev/null || fail "AppStore entitlements are invalid"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
marketing_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
minimum_system="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")"
package_type="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$INFO_PLIST")"

[[ "$bundle_id" == "com.jinfang.PersonalSitePublisherMac" ]] || fail "unexpected bundle identifier: $bundle_id"
[[ "$marketing_version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || fail "invalid marketing version: $marketing_version"
[[ "$build_number" =~ ^[0-9]+$ ]] || fail "invalid build number: $build_number"
[[ "$minimum_system" == "14.0" ]] || fail "unexpected minimum macOS version: $minimum_system"
[[ "$package_type" == "APPL" ]] || fail "unexpected package type: $package_type"

localized_languages=()
for language in zh-Hans en; do
  localized_info="$APP_BUNDLE/Contents/Resources/$language.lproj/InfoPlist.strings"
  [[ -f "$localized_info" ]] || fail "$language InfoPlist.strings is missing"
  plutil -lint "$localized_info" >/dev/null || fail "$language InfoPlist.strings is invalid"
  grep -Eq '^[[:space:]]*"CFBundleDisplayName"[[:space:]]*=' "$localized_info" \
    || fail "$language InfoPlist.strings is missing CFBundleDisplayName"
  grep -Eq '^[[:space:]]*"CFBundleName"[[:space:]]*=' "$localized_info" \
    || fail "$language InfoPlist.strings is missing CFBundleName"
  localized_languages+=("$language")
done

sandbox_enabled="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$ENTITLEMENTS" 2>/dev/null || true)"
network_enabled="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' "$ENTITLEMENTS" 2>/dev/null || true)"
file_access_enabled="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.user-selected.read-write' "$ENTITLEMENTS" 2>/dev/null || true)"

[[ "$sandbox_enabled" == "true" ]] || fail "App Sandbox entitlement must be enabled"
[[ "$network_enabled" == "true" ]] || fail "Network Client entitlement must be enabled"
[[ "$file_access_enabled" == "true" ]] || fail "User Selected Read/Write entitlement must be enabled"

metadata_markdown="$(
  cat <<EOF
# App Store Build Metadata Evidence

This file records local App Store build metadata checks. It does not replace
the required clean Release archive, distribution signing team, hardened runtime,
or Transporter/App Store Connect validation evidence in
\`APP_STORE_ARCHIVE_VALIDATION.md\`.

## Latest Local Metadata Check

- Status: Local build metadata verified.
- Bundle identifier: \`$bundle_id\`
- Marketing version: \`$marketing_version\`
- Build number: \`$build_number\`
- Minimum macOS: \`$minimum_system\`
- App package type: \`$package_type\`
- App icon: bundled AppIcon.icns verified.
- Localized InfoPlist strings: ${localized_languages[*]} verified.
- App Sandbox entitlement: enabled.
- Network Client entitlement: enabled.
- User Selected Read/Write entitlement: enabled.

## Boundary

This local metadata evidence does not verify distribution signing team,
hardened runtime on the signed archive, clean checkout archive reproducibility,
or Transporter/App Store Connect validation.
EOF
)"

if grep -Eq '(/Users/|/Volumes/|file:///Users/|file:///Volumes/|Authorization:[[:space:]]*Bearer|TeamIdentifier=|Apple[[:space:]]*ID|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})' <<<"$metadata_markdown"; then
  fail "generated metadata evidence contains private-looking content"
fi

if [[ "$EXECUTE" == "1" ]]; then
  mkdir -p "$(dirname "$OUTPUT")"
  printf '%s\n' "$metadata_markdown" >"$OUTPUT"
  echo "app store build metadata evidence: wrote ${OUTPUT#$ROOT_DIR/}"
else
  echo "app store build metadata evidence: dry-run"
  echo "- bundle identifier: $bundle_id"
  echo "- marketing version: $marketing_version"
  echo "- build number: $build_number"
  echo "- minimum macOS: $minimum_system"
  echo "- entitlements: sandbox, network client, user-selected read/write"
  echo "- output: ${OUTPUT#$ROOT_DIR/}"
fi
