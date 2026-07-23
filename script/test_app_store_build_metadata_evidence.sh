#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECORDER="$ROOT_DIR/script/record_app_store_build_metadata_evidence.sh"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-build-metadata.XXXXXX)"
APP_NAME="PersonalSitePublisherMac"
APP_BUNDLE="$TMP_DIR/dist/$APP_NAME.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
ENTITLEMENTS="$TMP_DIR/AppStore.entitlements"
OUTPUT="$TMP_DIR/APP_STORE_BUILD_METADATA.md"
VERSION_CONFIG="$TMP_DIR/BuildVersion.xcconfig"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "app store build metadata evidence test: $*" >&2
  exit 1
}

[[ -f "$RECORDER" ]] || fail "record_app_store_build_metadata_evidence.sh is missing"

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/zh-Hans.lproj" "$APP_BUNDLE/Contents/Resources/en.lproj"
printf '#!/bin/sh\nexit 0\n' >"$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
printf 'fake icon bytes\n' >"$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cat >"$INFO_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>PersonalSitePublisherMac</string>
  <key>CFBundleIdentifier</key>
  <string>com.jinfang.PersonalSitePublisherMac</string>
  <key>CFBundleName</key>
  <string>PersonalSitePublisherMac</string>
  <key>CFBundleDisplayName</key>
  <string>RepoPress</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleShortVersionString</key>
  <string>1.2.3</string>
  <key>CFBundleVersion</key>
  <string>42</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>PersonalSitePublisherBuildConfiguration</key>
  <string>Release</string>
</dict>
</plist>
PLIST

for language in zh-Hans en; do
  cat >"$APP_BUNDLE/Contents/Resources/$language.lproj/InfoPlist.strings" <<'STRINGS'
"CFBundleDisplayName" = "RepoPress";
"CFBundleName" = "PersonalSitePublisherMac";
STRINGS
done

cat >"$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key>
  <true/>
  <key>com.apple.security.network.client</key>
  <true/>
  <key>com.apple.security.files.user-selected.read-write</key>
  <true/>
</dict>
</plist>
PLIST

printf '%s\n' \
  'MARKETING_VERSION = 1.2.3' \
  'CURRENT_PROJECT_VERSION = 42' \
  >"$VERSION_CONFIG"

dry_output="$(
  BUILD_VERSION_CONFIG="$VERSION_CONFIG" \
  APP_STORE_BUILD_METADATA_SKIP_BUILD=1 \
  APP_STORE_BUILD_APP_BUNDLE="$APP_BUNDLE" \
  APP_STORE_BUILD_ENTITLEMENTS="$ENTITLEMENTS" \
  APP_STORE_BUILD_METADATA_EVIDENCE_FILE="$OUTPUT" \
    bash "$RECORDER" --dry-run
)"
grep -q "app store build metadata evidence: dry-run" <<<"$dry_output" || fail "dry-run did not print header"
grep -q "bundle identifier: com.jinfang.PersonalSitePublisherMac" <<<"$dry_output" || fail "dry-run omitted bundle id"
[[ ! -f "$OUTPUT" ]] || fail "dry-run wrote output evidence"

BUILD_VERSION_CONFIG="$VERSION_CONFIG" \
APP_STORE_BUILD_METADATA_SKIP_BUILD=1 \
APP_STORE_BUILD_APP_BUNDLE="$APP_BUNDLE" \
APP_STORE_BUILD_ENTITLEMENTS="$ENTITLEMENTS" \
APP_STORE_BUILD_METADATA_EVIDENCE_FILE="$OUTPUT" \
  bash "$RECORDER" --execute >/dev/null

[[ -f "$OUTPUT" ]] || fail "execute did not write evidence"
grep -q "Version source: \`Packaging/BuildVersion.xcconfig\`" "$OUTPUT" || fail "evidence omits version source"
grep -q "Bundle identifier: \`com.jinfang.PersonalSitePublisherMac\`" "$OUTPUT" || fail "evidence omits bundle id"
grep -q "Marketing version: \`1.2.3\`" "$OUTPUT" || fail "evidence omits marketing version"
grep -q "Build number: \`42\`" "$OUTPUT" || fail "evidence omits build number"
grep -q "Build configuration: \`Release\`" "$OUTPUT" || fail "evidence omits Release configuration"
grep -q "App Sandbox entitlement: enabled" "$OUTPUT" || fail "evidence omits sandbox entitlement"
grep -q "does not verify distribution signing team" "$OUTPUT" || fail "evidence omits boundary warning"
if grep -Eq '(/Users/|/Volumes/|Authorization:[[:space:]]*Bearer|TeamIdentifier=|Apple[[:space:]]*ID)' "$OUTPUT"; then
  fail "evidence contains private-looking content"
fi

perl -0pi -e 's/<string>Release<\/string>/<string>Debug<\/string>/' "$INFO_PLIST"
if APP_STORE_BUILD_METADATA_SKIP_BUILD=1 \
  APP_STORE_BUILD_APP_BUNDLE="$APP_BUNDLE" \
  APP_STORE_BUILD_ENTITLEMENTS="$ENTITLEMENTS" \
  BUILD_VERSION_CONFIG="$VERSION_CONFIG" \
    bash "$RECORDER" --dry-run >/dev/null 2>&1; then
  fail "recorder accepted Debug bundle metadata as App Store build evidence"
fi
perl -0pi -e 's/<string>Debug<\/string>/<string>Release<\/string>/' "$INFO_PLIST"

perl -0pi -e 's/<key>com\.apple\.security\.network\.client<\/key>\n  <true\/>\n//' "$ENTITLEMENTS"
if APP_STORE_BUILD_METADATA_SKIP_BUILD=1 \
  APP_STORE_BUILD_APP_BUNDLE="$APP_BUNDLE" \
  APP_STORE_BUILD_ENTITLEMENTS="$ENTITLEMENTS" \
  BUILD_VERSION_CONFIG="$VERSION_CONFIG" \
    bash "$RECORDER" --dry-run >/dev/null 2>&1; then
  fail "recorder accepted missing network entitlement"
fi

echo "app store build metadata evidence test: passed"
