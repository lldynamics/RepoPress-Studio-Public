#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="PersonalSitePublisherMac"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
APP_ICON="$APP_BUNDLE/Contents/Resources/AppIcon.icns"
CORE_RESOURCE_INFO="$APP_BUNDLE/Contents/Resources/${APP_NAME}_PublishingWorkbenchCore.bundle/Info.plist"
ENTITLEMENTS="$ROOT_DIR/Sources/PersonalSitePublisherMac/AppStore.entitlements"
LOCALIZED_INFO_PLIST_KEYS=(CFBundleDisplayName CFBundleName)

fail() {
  echo "app store metadata gate: $*" >&2
  exit 1
}

bash "$ROOT_DIR/script/build_and_run.sh" --package-only --app-store >/dev/null

[[ -d "$APP_BUNDLE" ]] || fail "app bundle was not created"
[[ -x "$APP_BINARY" ]] || fail "app executable is missing or not executable"
[[ -s "$APP_ICON" ]] || fail "AppIcon.icns is missing from the app bundle"
[[ -f "$ENTITLEMENTS" ]] || fail "AppStore.entitlements is missing"

plutil -lint "$INFO_PLIST" >/dev/null || fail "Info.plist is invalid"
[[ -f "$CORE_RESOURCE_INFO" ]] || fail "PublishingWorkbenchCore resource bundle Info.plist is missing"
plutil -lint "$CORE_RESOURCE_INFO" >/dev/null || fail "PublishingWorkbenchCore resource bundle Info.plist is invalid"
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

core_resource_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CORE_RESOURCE_INFO" 2>/dev/null || true)"
[[ "$core_resource_bundle_id" == "$bundle_id.PublishingWorkbenchCoreResources" ]] \
  || fail "PublishingWorkbenchCore resource bundle is missing its expected CFBundleIdentifier"
core_resource_package_type="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$CORE_RESOURCE_INFO" 2>/dev/null || true)"
[[ "$core_resource_package_type" == "BNDL" ]] \
  || fail "PublishingWorkbenchCore resource bundle must declare CFBundlePackageType=BNDL"

package_type="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$INFO_PLIST")"
[[ "$package_type" == "APPL" ]] || fail "unexpected package type: $package_type"

minimum_system="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")"
[[ "$minimum_system" == "14.0" ]] || fail "unexpected minimum system version: $minimum_system"

application_category="$(/usr/libexec/PlistBuddy -c 'Print :LSApplicationCategoryType' "$INFO_PLIST" 2>/dev/null || true)"
[[ "$application_category" == public.app-category.* ]] \
  || fail "LSApplicationCategoryType must use a public.app-category value"

human_readable_copyright="$(/usr/libexec/PlistBuddy -c 'Print :NSHumanReadableCopyright' "$INFO_PLIST" 2>/dev/null || true)"
[[ -n "${human_readable_copyright//[[:space:]]/}" ]] \
  || fail "NSHumanReadableCopyright must not be empty"

uses_non_exempt_encryption="$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$INFO_PLIST" 2>/dev/null || true)"
[[ "$uses_non_exempt_encryption" == "false" ]] \
  || fail "ITSAppUsesNonExemptEncryption must be false for the audited system-HTTPS/SHA-256 boundary"

marketing_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
build_configuration="$(/usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherBuildConfiguration' "$INFO_PLIST" 2>/dev/null || true)"
distribution_channel="$(/usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherDistributionChannel' "$INFO_PLIST" 2>/dev/null || true)"
browser_extension_available="$(/usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherBrowserExtensionAvailable' "$INFO_PLIST" 2>/dev/null || true)"
[[ "$marketing_version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || fail "CFBundleShortVersionString must be numeric, got: $marketing_version"
[[ "$build_number" =~ ^[0-9]+$ ]] || fail "CFBundleVersion must be numeric, got: $build_number"
[[ "$build_configuration" == "Release" ]] || fail "App Store metadata must come from a Release bundle, got: ${build_configuration:-missing configuration evidence}"
[[ "$distribution_channel" == "AppStore" ]] || fail "App Store metadata must come from the AppStore distribution channel"
[[ "$browser_extension_available" == "false" ]] || fail "App Store metadata must disable the unpacked browser extension"
[[ ! -e "$APP_BUNDLE/Contents/Resources/BrowserExtension" ]] \
  || fail "App Store bundle must not contain unpacked browser-extension assets"
bash "$ROOT_DIR/script/check_build_version.sh" --info-plist "$INFO_PLIST" >/dev/null

sandbox_enabled="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$ENTITLEMENTS" 2>/dev/null || true)"
[[ "$sandbox_enabled" == "true" ]] || fail "App Sandbox entitlement must be enabled"

network_enabled="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' "$ENTITLEMENTS" 2>/dev/null || true)"
[[ "$network_enabled" == "true" ]] || fail "network client entitlement must be enabled for API publishing and AI/deployment checks"

file_access_enabled="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.user-selected.read-write' "$ENTITLEMENTS" 2>/dev/null || true)"
[[ "$file_access_enabled" == "true" ]] || fail "user-selected read/write entitlement must be enabled for local repository access"

bookmarks_enabled="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.bookmarks.app-scope' "$ENTITLEMENTS" 2>/dev/null || true)"
[[ "$bookmarks_enabled" == "true" ]] || fail "app-scope bookmarks entitlement must be enabled for persisted repository access"

network_server_enabled="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.server' "$ENTITLEMENTS" 2>/dev/null || true)"
[[ "$network_server_enabled" != "true" ]] || fail "App Store entitlements must not expose the browser bridge's Network Server capability"

echo "app store metadata gate: AppStore Release bundle id, version $marketing_version ($build_number), browser-extension boundary, icon, localized display names, category, copyright, minimum macOS, and sandbox entitlements verified"
