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
mkdir -p "$APP/Contents/MacOS"
plutil -create xml1 "$APP/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string com.jinfang.PersonalSitePublisherMac "$APP/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string "$marketing_version" "$APP/Contents/Info.plist"
plutil -insert CFBundleVersion -string "$build_number" "$APP/Contents/Info.plist"
plutil -insert PersonalSitePublisherBuildConfiguration -string Release "$APP/Contents/Info.plist"
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
