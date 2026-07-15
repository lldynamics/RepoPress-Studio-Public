#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="PersonalSitePublisherMac"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
APP_ICON="$APP_BUNDLE/Contents/Resources/AppIcon.icns"
ENTITLEMENTS="$ROOT_DIR/Sources/PersonalSitePublisherMac/AppStore.entitlements"
LOCALIZED_INFO_PLIST_KEYS=(CFBundleDisplayName CFBundleName)

fail() {
  echo "app store metadata gate: $*" >&2
  exit 1
}

bash "$ROOT_DIR/script/build_and_run.sh" --package-only --release >/dev/null

[[ -d "$APP_BUNDLE" ]] || fail "app bundle was not created"
[[ -x "$APP_BINARY" ]] || fail "app executable is missing or not executable"
[[ -s "$APP_ICON" ]] || fail "AppIcon.icns is missing from the app bundle"
[[ -f "$ENTITLEMENTS" ]] || fail "AppStore.entitlements is missing"

plutil -lint "$INFO_PLIST" >/dev/null || fail "Info.plist is invalid"
plutil -lint "$ENTITLEMENTS" >/dev/null || fail "AppStore.entitlements is invalid"

for language in zh-Hans en; do
  localized_info="$APP_BUNDLE/Contents/Resources/$language.lproj/InfoPlist.strings"
  [[ -f "$localized_info" ]] || fail "$language InfoPlist.strings is missing from the app bundle"
  plutil -lint "$localized_info" >/dev/null || fail "$localized_info is invalid"
  for required_key in "${LOCALIZED_INFO_PLIST_KEYS[@]}"; do
    grep -Eq "^[[:space:]]*\"$required_key\"[[:space:]]*=" "$localized_info" \
      || fail "$language InfoPlist.strings is missing $required_key"
  done
done

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
[[ "$bundle_id" == "com.jinfang.PersonalSitePublisherMac" ]] || fail "unexpected bundle identifier: $bundle_id"

package_type="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$INFO_PLIST")"
[[ "$package_type" == "APPL" ]] || fail "unexpected package type: $package_type"

minimum_system="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")"
[[ "$minimum_system" == "14.0" ]] || fail "unexpected minimum system version: $minimum_system"

marketing_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
build_configuration="$(/usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherBuildConfiguration' "$INFO_PLIST" 2>/dev/null || true)"
[[ "$marketing_version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || fail "CFBundleShortVersionString must be numeric, got: $marketing_version"
[[ "$build_number" =~ ^[0-9]+$ ]] || fail "CFBundleVersion must be numeric, got: $build_number"
[[ "$build_configuration" == "Release" ]] || fail "App Store metadata must come from a Release bundle, got: ${build_configuration:-missing configuration evidence}"
bash "$ROOT_DIR/script/check_build_version.sh" --info-plist "$INFO_PLIST" >/dev/null

sandbox_enabled="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$ENTITLEMENTS" 2>/dev/null || true)"
[[ "$sandbox_enabled" == "true" ]] || fail "App Sandbox entitlement must be enabled"

network_enabled="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' "$ENTITLEMENTS" 2>/dev/null || true)"
[[ "$network_enabled" == "true" ]] || fail "network client entitlement must be enabled for API publishing and AI/deployment checks"

file_access_enabled="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.user-selected.read-write' "$ENTITLEMENTS" 2>/dev/null || true)"
[[ "$file_access_enabled" == "true" ]] || fail "user-selected read/write entitlement must be enabled for local repository access"

echo "app store metadata gate: Release bundle id, version $marketing_version ($build_number), icon, localized display names, minimum macOS, and sandbox entitlements verified"
