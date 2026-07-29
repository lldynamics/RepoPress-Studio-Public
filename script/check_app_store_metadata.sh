#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="PersonalSitePublisherMac"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
APP_ICON="$APP_BUNDLE/Contents/Resources/AppIcon.icns"
SAFARI_EXTENSION="$APP_BUNDLE/Contents/PlugIns/RepoPressSafariExtension.appex"
SAFARI_EXTENSION_INFO="$SAFARI_EXTENSION/Contents/Info.plist"
SAFARI_EXTENSION_MANIFEST="$SAFARI_EXTENSION/Contents/Resources/manifest.json"
SAFARI_EXTENSION_ENTITLEMENTS="$ROOT_DIR/Packaging/SafariWebExtension.entitlements"
SAFARI_EXTENSION_BUNDLE_ID="com.jinfang.PersonalSitePublisherMac.SafariExtension"
CORE_RESOURCE_INFO="$APP_BUNDLE/Contents/Resources/${APP_NAME}_PublishingWorkbenchCore.bundle/Info.plist"
ENTITLEMENTS="$ROOT_DIR/Sources/PersonalSitePublisherMac/AppStore.entitlements"
FEATURE_POLICY="$ROOT_DIR/Sources/PublishingWorkbenchCore/Models/DistributionFeaturePolicy.swift"
LAUNCH_COORDINATOR="$ROOT_DIR/Sources/PersonalSitePublisherMac/App/WorkbenchLaunchCoordinator.swift"
LOCALIZED_INFO_PLIST_KEYS=(CFBundleDisplayName CFBundleName)
EXPECTED_DISPLAY_NAME="RepoPress Studio"

fail() {
  echo "app store metadata gate: $*" >&2
  exit 1
}

bash "$ROOT_DIR/script/build_and_run.sh" --package-only --app-store >/dev/null

[[ -d "$APP_BUNDLE" ]] || fail "app bundle was not created"
[[ -x "$APP_BINARY" ]] || fail "app executable is missing or not executable"
[[ -s "$APP_ICON" ]] || fail "AppIcon.icns is missing from the app bundle"
[[ -d "$SAFARI_EXTENSION" ]] || fail "embedded Safari Web Extension is missing"
[[ -f "$SAFARI_EXTENSION_INFO" ]] || fail "Safari Web Extension Info.plist is missing"
[[ -f "$SAFARI_EXTENSION_MANIFEST" ]] || fail "Safari Web Extension manifest is missing"
[[ -f "$ENTITLEMENTS" ]] || fail "AppStore.entitlements is missing"
[[ -f "$SAFARI_EXTENSION_ENTITLEMENTS" ]] || fail "SafariWebExtension.entitlements is missing"
[[ -f "$FEATURE_POLICY" ]] || fail "DistributionFeaturePolicy.swift is missing"
[[ -f "$LAUNCH_COORDINATOR" ]] || fail "WorkbenchLaunchCoordinator.swift is missing"

plutil -lint "$INFO_PLIST" >/dev/null || fail "Info.plist is invalid"
plutil -lint "$SAFARI_EXTENSION_INFO" >/dev/null \
  || fail "Safari Web Extension Info.plist is invalid"
python3 -m json.tool "$SAFARI_EXTENSION_MANIFEST" >/dev/null \
  || fail "Safari Web Extension manifest is invalid"
[[ -f "$CORE_RESOURCE_INFO" ]] || fail "PublishingWorkbenchCore resource bundle Info.plist is missing"
plutil -lint "$CORE_RESOURCE_INFO" >/dev/null || fail "PublishingWorkbenchCore resource bundle Info.plist is invalid"
plutil -lint "$ENTITLEMENTS" >/dev/null || fail "AppStore.entitlements is invalid"
plutil -lint "$SAFARI_EXTENSION_ENTITLEMENTS" >/dev/null \
  || fail "SafariWebExtension.entitlements is invalid"

for language in zh-Hans en; do
  localized_info="$APP_BUNDLE/Contents/Resources/$language.lproj/InfoPlist.strings"
  [[ -f "$localized_info" ]] || fail "$language InfoPlist.strings is missing from the app bundle"
  plutil -lint "$localized_info" >/dev/null || fail "$localized_info is invalid"
  for required_key in "${LOCALIZED_INFO_PLIST_KEYS[@]}"; do
    grep -Eq "^[[:space:]]*\"$required_key\"[[:space:]]*=" "$localized_info" \
      || fail "$language InfoPlist.strings is missing $required_key"
  done
  grep -Eq '^[[:space:]]*"CFBundleDisplayName"[[:space:]]*=[[:space:]]*"RepoPress Studio";' "$localized_info" \
    || fail "$language CFBundleDisplayName must be RepoPress Studio"
  grep -Eq '^[[:space:]]*"CFBundleName"[[:space:]]*=[[:space:]]*"RepoPress Studio";' "$localized_info" \
    || fail "$language CFBundleName must be RepoPress Studio"
done

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
[[ "$bundle_id" == "com.jinfang.PersonalSitePublisherMac" ]] || fail "unexpected bundle identifier: $bundle_id"

display_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$INFO_PLIST" 2>/dev/null || true)"
bundle_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$INFO_PLIST" 2>/dev/null || true)"
[[ "$display_name" == "$EXPECTED_DISPLAY_NAME" ]] \
  || fail "CFBundleDisplayName must be $EXPECTED_DISPLAY_NAME"
[[ "$bundle_name" == "$EXPECTED_DISPLAY_NAME" ]] \
  || fail "CFBundleName must be $EXPECTED_DISPLAY_NAME"

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
[[ "$application_category" == "public.app-category.developer-tools" ]] \
  || fail "LSApplicationCategoryType must be public.app-category.developer-tools"

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
external_ai_available="$(/usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherExternalAIAvailable' "$INFO_PLIST" 2>/dev/null || true)"
screenshot_capture_build="$(/usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherScreenshotCaptureBuild' "$INFO_PLIST" 2>/dev/null || true)"
browser_extension_available="$(/usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherBrowserExtensionAvailable' "$INFO_PLIST" 2>/dev/null || true)"
safari_extension_available="$(/usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherSafariWebExtensionAvailable' "$INFO_PLIST" 2>/dev/null || true)"
[[ "$marketing_version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || fail "CFBundleShortVersionString must be numeric, got: $marketing_version"
[[ "$build_number" =~ ^[0-9]+$ ]] || fail "CFBundleVersion must be numeric, got: $build_number"
[[ "$build_configuration" == "Release" ]] || fail "App Store metadata must come from a Release bundle, got: ${build_configuration:-missing configuration evidence}"
[[ "$distribution_channel" == "AppStore" ]] || fail "App Store metadata must come from the AppStore distribution channel"
[[ "$external_ai_available" == "true" ]] \
  || fail "App Store metadata must declare free user-configured AI providers available"
[[ "$screenshot_capture_build" == "false" ]] || fail "App Store submission bundle must not contain screenshot demo data"
[[ "$browser_extension_available" == "false" ]] || fail "App Store metadata must disable the unpacked browser extension"
[[ "$safari_extension_available" == "true" ]] \
  || fail "App Store metadata must declare the embedded Safari Web Extension"
[[ ! -e "$APP_BUNDLE/Contents/Resources/BrowserExtension" ]] \
  || fail "App Store bundle must not contain unpacked browser-extension assets"
[[ ! -e "$APP_BUNDLE/Contents/MacOS/KnowledgeNativeMessagingHost" ]] \
  || fail "App Store bundle must not contain the Native Messaging host"
bash "$ROOT_DIR/script/build_safari_web_extension.sh" --check >/dev/null
safari_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SAFARI_EXTENSION_INFO")"
safari_package_type="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$SAFARI_EXTENSION_INFO")"
safari_extension_point="$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$SAFARI_EXTENSION_INFO")"
safari_minimum_system="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$SAFARI_EXTENSION_INFO")"
[[ "$safari_bundle_id" == "$SAFARI_EXTENSION_BUNDLE_ID" ]] \
  || fail "unexpected Safari Web Extension bundle identifier: $safari_bundle_id"
[[ "$safari_package_type" == "XPC!" ]] \
  || fail "Safari Web Extension must use CFBundlePackageType=XPC!"
[[ "$safari_extension_point" == "com.apple.Safari.web-extension" ]] \
  || fail "unexpected Safari Web Extension point: $safari_extension_point"
[[ "$safari_minimum_system" == "14.0" ]] \
  || fail "unexpected Safari Web Extension minimum system: $safari_minimum_system"
codesign --verify --strict "$SAFARI_EXTENSION" \
  || fail "Safari Web Extension signature does not verify"
grep -Fq "public static var allowsExternalAIProviders" "$FEATURE_POLICY" \
  || fail "distribution policy does not define the App Store AI boundary"
grep -Fq "Every distribution channel exposes the same free BYOK AI integration" "$FEATURE_POLICY" \
  || fail "distribution policy does not document the shared free BYOK AI boundary"
grep -Fq "APP_STORE_BUILD" "$ROOT_DIR/script/build_and_run.sh" \
  || fail "App Store packaging does not pass the compiled distribution boundary"
grep -Fq "APP_STORE_SWIFT_SCRATCH_PATH" "$ROOT_DIR/script/build_and_run.sh" \
  || fail "App Store packaging does not isolate SwiftPM artifacts by distribution channel"
grep -Fq "public static var allowsBrowserCapture" "$FEATURE_POLICY" \
  || fail "distribution policy does not define the App Store browser-capture boundary"
grep -Fq "let browserBridge = KnowledgeBrowserBridge(" "$LAUNCH_COORDINATOR" \
  || fail "App Store launch path does not construct the sandboxed browser bridge"
grep -Fq "browserBridge.start()" "$LAUNCH_COORDINATOR" \
  || fail "App Store launch path does not start the sandboxed browser bridge"
bash "$ROOT_DIR/script/check_build_version.sh" --info-plist "$INFO_PLIST" >/dev/null

sandbox_enabled="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$ENTITLEMENTS" 2>/dev/null || true)"
[[ "$sandbox_enabled" == "true" ]] || fail "App Sandbox entitlement must be enabled"

network_enabled="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' "$ENTITLEMENTS" 2>/dev/null || true)"
[[ "$network_enabled" == "true" ]] || fail "network client entitlement must be enabled for API publishing and deployment checks"

file_access_enabled="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.user-selected.read-write' "$ENTITLEMENTS" 2>/dev/null || true)"
[[ "$file_access_enabled" == "true" ]] || fail "user-selected read/write entitlement must be enabled for local repository access"

bookmarks_enabled="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.bookmarks.app-scope' "$ENTITLEMENTS" 2>/dev/null || true)"
[[ "$bookmarks_enabled" == "true" ]] || fail "app-scope bookmarks entitlement must be enabled for persisted repository access"

network_server_enabled="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.server' "$ENTITLEMENTS" 2>/dev/null || true)"
[[ "$network_server_enabled" == "true" ]] \
  || fail "network server entitlement must be enabled for the authenticated loopback browser-capture bridge"

safari_sandbox_enabled="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$SAFARI_EXTENSION_ENTITLEMENTS" 2>/dev/null || true)"
[[ "$safari_sandbox_enabled" == "true" ]] \
  || fail "Safari Web Extension App Sandbox entitlement must be enabled"

echo "app store metadata gate: AppStore Release bundle id, version $marketing_version ($build_number), free BYOK AI enabled and excluded from Pro, embedded Safari Web Extension, sandboxed loopback browser capture, icon, RepoPress Studio display name, category, copyright, minimum macOS, and sandbox entitlements verified"
