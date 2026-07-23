#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT_DIR/script/check_app_store_archive_readiness.sh"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-archive-artifact.XXXXXX)"
APP="$TMP_DIR/Explicit.app"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "app store archive artifact test: $*" >&2
  exit 1
}

marketing_version="$(sed -nE 's/^MARKETING_VERSION[[:space:]]*=[[:space:]]*(.+)$/\1/p' "$ROOT_DIR/Packaging/BuildVersion.xcconfig")"
build_number="$(sed -nE 's/^CURRENT_PROJECT_VERSION[[:space:]]*=[[:space:]]*(.+)$/\1/p' "$ROOT_DIR/Packaging/BuildVersion.xcconfig")"
CORE_RESOURCES="$APP/Contents/Resources/PersonalSitePublisherMac_PublishingWorkbenchCore.bundle"
SAFARI_EXTENSION="$APP/Contents/PlugIns/RepoPressSafariExtension.appex"
mkdir -p \
  "$APP/Contents/MacOS" \
  "$CORE_RESOURCES" \
  "$SAFARI_EXTENSION/Contents/Resources"
plutil -create xml1 "$APP/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string com.jinfang.PersonalSitePublisherMac "$APP/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string "$marketing_version" "$APP/Contents/Info.plist"
plutil -insert CFBundleVersion -string "$build_number" "$APP/Contents/Info.plist"
plutil -insert PersonalSitePublisherBuildConfiguration -string Release "$APP/Contents/Info.plist"
plutil -insert LSApplicationCategoryType -string public.app-category.developer-tools "$APP/Contents/Info.plist"
plutil -insert NSHumanReadableCopyright -string "Copyright © 2026 Jinfang. All rights reserved." "$APP/Contents/Info.plist"
plutil -insert ITSAppUsesNonExemptEncryption -bool false "$APP/Contents/Info.plist"

plutil -create xml1 "$CORE_RESOURCES/Info.plist"
plutil -insert CFBundleIdentifier -string com.jinfang.PersonalSitePublisherMac.PublishingWorkbenchCoreResources "$CORE_RESOURCES/Info.plist"
plutil -insert CFBundlePackageType -string BNDL "$CORE_RESOURCES/Info.plist"

plutil -create xml1 "$SAFARI_EXTENSION/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string com.jinfang.PersonalSitePublisherMac.SafariExtension "$SAFARI_EXTENSION/Contents/Info.plist"
plutil -insert CFBundlePackageType -string 'XPC!' "$SAFARI_EXTENSION/Contents/Info.plist"
plutil -insert LSMinimumSystemVersion -string 14.0 "$SAFARI_EXTENSION/Contents/Info.plist"
plutil -insert NSExtension -xml '<dict><key>NSExtensionPointIdentifier</key><string>com.apple.Safari.web-extension</string></dict>' "$SAFARI_EXTENSION/Contents/Info.plist"
cp "$ROOT_DIR/BrowserExtension/Safari/manifest.json" "$SAFARI_EXTENSION/Contents/Resources/manifest.json"

printf '#!/usr/bin/env bash\nexit 0\n' >"$APP/Contents/MacOS/PersonalSitePublisherMac"
chmod +x "$APP/Contents/MacOS/PersonalSitePublisherMac"

output="$(bash "$CHECK" --app-bundle "$APP" 2>&1)" \
  || fail "explicit unsigned app should pass non-strict local checks"
grep -q "validated explicit app bundle" <<<"$output" \
  || fail "explicit app bundle was not reported as the validated artifact"

if bash "$CHECK" --strict >/dev/null 2>&1; then
  fail "strict mode accepted an implicit rebuilt package"
fi

archive="$TMP_DIR/Explicit.xcarchive"
mkdir -p "$archive/Products/Applications"
cp -R "$APP" "$archive/Products/Applications/PersonalSitePublisherMac.app"
archive_output="$(bash "$CHECK" --archive "$archive" 2>&1)" \
  || fail "explicit archive should pass non-strict local checks"
grep -q "validated explicit xcarchive app" <<<"$archive_output" \
  || fail "explicit archive was not reported as the validated artifact"

echo "app store archive artifact test: passed"
