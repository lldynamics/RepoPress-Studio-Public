#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAFARI_SOURCE="$ROOT_DIR/BrowserExtension/Safari"
BUILD_ROOT="${SAFARI_WEB_EXTENSION_BUILD_ROOT:-$ROOT_DIR/.build/safari-web-extension}"
PROJECT_LOCATION="$BUILD_ROOT/generated"
PROJECT_ROOT="$PROJECT_LOCATION/RepoPressSafari"
PROJECT_PATH="$PROJECT_ROOT/RepoPressSafari.xcodeproj"
SYMROOT="$BUILD_ROOT/products"
OBJROOT="$BUILD_ROOT/intermediates"
PRODUCT_BUNDLE="$BUILD_ROOT/product/RepoPressSafariExtension.appex"
LOCALIZATION_ROOT="$ROOT_DIR/Packaging/SafariWebExtension"
SAFARI_APP_NAME="RepoPressSafari"
SAFARI_TARGET="RepoPressSafari Extension"
SAFARI_EXTENSION_BUNDLE_ID="com.jinfang.PersonalSitePublisherMac.SafariExtension"
MINIMUM_SYSTEM_VERSION="14.0"
CONFIGURATION="Release"
MARKETING_VERSION=""
BUILD_NUMBER=""
MODE="build"

usage() {
  cat >&2 <<'EOF'
usage: script/build_safari_web_extension.sh [--check|--print-product]
       [--configuration debug|release]

Builds the RepoPress Safari Web Extension with Apple's official packager and
places the unsigned .appex at a deterministic project-local path. The
containing app owns final nested-code signing.
EOF
}

fail() {
  echo "safari web extension: $*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --check)
      MODE="check"
      shift
      ;;
    --print-product)
      MODE="print-product"
      shift
      ;;
    --configuration)
      [[ "$#" -ge 2 ]] || fail "--configuration requires debug or release"
      case "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" in
        debug) CONFIGURATION="Debug" ;;
        release) CONFIGURATION="Release" ;;
        *) fail "--configuration requires debug or release" ;;
      esac
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[[ -f "$SAFARI_SOURCE/manifest.json" ]] || fail "manifest is missing"
[[ -f "$ROOT_DIR/Packaging/SafariWebExtension.entitlements" ]] \
  || fail "SafariWebExtension.entitlements is missing"
command -v xcrun >/dev/null 2>&1 || fail "xcrun is required"
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild is required"
xcrun -f safari-web-extension-packager >/dev/null \
  || fail "Xcode does not provide safari-web-extension-packager"

bash "$ROOT_DIR/script/sync_safari_browser_extension.sh" --check >/dev/null
python3 "$ROOT_DIR/script/generate_browser_extension_protocol.py" --check >/dev/null

version_values="$(bash "$ROOT_DIR/script/check_build_version.sh" --print-values)"
IFS=$'\t' read -r MARKETING_VERSION BUILD_NUMBER <<<"$version_values"

if [[ "$MODE" == "check" ]]; then
  python3 - "$SAFARI_SOURCE/manifest.json" "$SAFARI_EXTENSION_BUNDLE_ID" <<'PY'
import json
from pathlib import Path
import sys

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
required = {
    "manifest_version": 3,
    "background": {"service_worker": "background.js"},
    "host_permissions": ["http://127.0.0.1:17843/*"],
}
for key, expected in required.items():
    if manifest.get(key) != expected:
        raise SystemExit(f"safari web extension: unexpected {key}")
permissions = set(manifest.get("permissions", []))
if "pageCapture" in permissions or "nativeMessaging" in permissions:
    raise SystemExit("safari web extension: unsupported or disallowed permission present")
if not {"activeTab", "scripting", "storage"}.issubset(permissions):
    raise SystemExit("safari web extension: required user-initiated capture permissions are missing")
bundle_id = sys.argv[2]
if not bundle_id.startswith("com.jinfang.PersonalSitePublisherMac."):
    raise SystemExit("safari web extension: bundle identifier is outside the containing app prefix")
PY
  echo "safari web extension: source contract passed"
  exit 0
fi

mkdir -p "$BUILD_ROOT" "$BUILD_ROOT/product"
packager_log="$BUILD_ROOT/packager.log"
xcrun safari-web-extension-packager "$SAFARI_SOURCE" \
  --project-location "$PROJECT_LOCATION" \
  --app-name "$SAFARI_APP_NAME" \
  --bundle-identifier "com.jinfang.PersonalSitePublisherMac" \
  --swift \
  --macos-only \
  --copy-resources \
  --no-open \
  --no-prompt \
  --force >"$packager_log" 2>&1

if grep -Fq "Warning:" "$packager_log"; then
  sed -n '1,160p' "$packager_log" >&2
  fail "Apple packager reported a Safari manifest compatibility warning"
fi
[[ -f "$PROJECT_PATH/project.pbxproj" ]] \
  || fail "Apple packager did not create the expected Xcode project"

xcodebuild \
  -project "$PROJECT_PATH" \
  -target "$SAFARI_TARGET" \
  -configuration "$CONFIGURATION" \
  SYMROOT="$SYMROOT" \
  OBJROOT="$OBJROOT" \
  CODE_SIGNING_ALLOWED=NO \
  MACOSX_DEPLOYMENT_TARGET="$MINIMUM_SYSTEM_VERSION" \
  PRODUCT_BUNDLE_IDENTIFIER="$SAFARI_EXTENSION_BUNDLE_ID" \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  INFOPLIST_KEY_CFBundleDisplayName="RepoPress Safari Capture" \
  clean build >/dev/null

built_product="$SYMROOT/$CONFIGURATION/$SAFARI_TARGET.appex"
[[ -d "$built_product" ]] || fail "Xcode did not create the Safari .appex"

case "$PRODUCT_BUNDLE" in
  "$BUILD_ROOT"/product/*.appex) ;;
  *) fail "refusing unsafe product path: $PRODUCT_BUNDLE" ;;
esac
rm -rf "$PRODUCT_BUNDLE"
ditto "$built_product" "$PRODUCT_BUNDLE"
for language in en zh-Hans; do
  source_strings="$LOCALIZATION_ROOT/$language.lproj/InfoPlist.strings"
  destination="$PRODUCT_BUNDLE/Contents/Resources/$language.lproj"
  [[ -f "$source_strings" ]] || fail "missing $language InfoPlist.strings"
  mkdir -p "$destination"
  cp "$source_strings" "$destination/InfoPlist.strings"
done

info_plist="$PRODUCT_BUNDLE/Contents/Info.plist"
manifest="$PRODUCT_BUNDLE/Contents/Resources/manifest.json"
plutil -lint "$info_plist" >/dev/null || fail "generated Info.plist is invalid"
python3 -m json.tool "$manifest" >/dev/null \
  || fail "embedded Safari manifest is invalid"

actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
extension_point="$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$info_plist")"
minimum_system="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info_plist")"
[[ "$actual_bundle_id" == "$SAFARI_EXTENSION_BUNDLE_ID" ]] \
  || fail "generated bundle identifier is $actual_bundle_id"
[[ "$extension_point" == "com.apple.Safari.web-extension" ]] \
  || fail "generated extension point is $extension_point"
[[ "$minimum_system" == "$MINIMUM_SYSTEM_VERSION" ]] \
  || fail "generated minimum system version is $minimum_system"

if [[ "$MODE" == "print-product" ]]; then
  printf '%s\n' "$PRODUCT_BUNDLE"
else
  echo "safari web extension: built $PRODUCT_BUNDLE"
fi
