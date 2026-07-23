#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-swift-release.XXXXXX)"
BIN_DIR="$TMP_DIR/bin"
ARGS_FILE="$TMP_DIR/args"
ENV_FILE="$TMP_DIR/env"
FIREFOX_RELEASE_CALLS="$TMP_DIR/firefox-release-calls"
DIRECT_CODE_SIGN_CALLS="$TMP_DIR/direct-codesign-calls"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "swift release build gate test: $*" >&2
  exit 1
}

mkdir -p "$BIN_DIR"
cat >"$BIN_DIR/swift" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
{
  printf '%s\n' '<call>'
  printf '%s\n' "$@"
} >>"$RELEASE_BUILD_ARGS_FILE"
printf '%s\n' "$HOME" "$XDG_CACHE_HOME" "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULE_CACHE_PATH" >"$RELEASE_BUILD_ENV_FILE"
if [[ " $* " == *" --show-bin-path "* ]]; then
  printf '%s\n' "$RELEASE_BUILD_STUB_BIN_DIR"
  exit 0
fi
mkdir -p "$RELEASE_BUILD_STUB_BIN_DIR"
printf '#!/usr/bin/env bash\nexit 0\n' >"$RELEASE_BUILD_STUB_BIN_DIR/PersonalSitePublisherMac"
chmod +x "$RELEASE_BUILD_STUB_BIN_DIR/PersonalSitePublisherMac"
printf '#!/usr/bin/env bash\nexit 0\n' >"$RELEASE_BUILD_STUB_BIN_DIR/KnowledgeNativeMessagingHost"
chmod +x "$RELEASE_BUILD_STUB_BIN_DIR/KnowledgeNativeMessagingHost"
exit "${RELEASE_BUILD_STUB_EXIT:-0}"
STUB
chmod +x "$BIN_DIR/swift"

: >"$ARGS_FILE"
RELEASE_BUILD_ARGS_FILE="$ARGS_FILE" \
RELEASE_BUILD_ENV_FILE="$ENV_FILE" \
RELEASE_BUILD_STUB_BIN_DIR="$TMP_DIR/.build/arm64-apple-macosx/release" \
PATH="$BIN_DIR:$PATH" \
SWIFT_BUILD_HOME="$TMP_DIR/swift-home" \
  bash "$ROOT_DIR/script/check_swift_release_build.sh" >/dev/null

grep -Fxq "build" "$ARGS_FILE" || fail "gate did not run swift build"
grep -Fxq -- "-c" "$ARGS_FILE" || fail "gate omitted -c"
grep -Fxq "release" "$ARGS_FILE" || fail "gate omitted release configuration"
grep -Fxq -- "--disable-sandbox" "$ARGS_FILE" || fail "gate omitted --disable-sandbox"
grep -Fxq -- "--product" "$ARGS_FILE" || fail "gate omitted the app product"
grep -Fxq "PersonalSitePublisherMac" "$ARGS_FILE" || fail "gate omitted the app product name"
grep -Fxq "KnowledgeNativeMessagingHost" "$ARGS_FILE" || fail "gate omitted the native messaging host product"
grep -Fxq -- "--show-bin-path" "$ARGS_FILE" || fail "gate did not verify the Release binary directory"
grep -Fq "$TMP_DIR/swift-home" "$ENV_FILE" || fail "gate did not isolate Swift build caches"

: >"$ARGS_FILE"
if RELEASE_BUILD_ARGS_FILE="$ARGS_FILE" \
  RELEASE_BUILD_ENV_FILE="$ENV_FILE" \
  RELEASE_BUILD_STUB_BIN_DIR="$TMP_DIR/.build/arm64-apple-macosx/release" \
  RELEASE_BUILD_STUB_EXIT=19 \
  PATH="$BIN_DIR:$PATH" \
  SWIFT_BUILD_HOME="$TMP_DIR/swift-home-failure" \
  bash "$ROOT_DIR/script/check_swift_release_build.sh" >/dev/null 2>&1; then
  fail "gate accepted a failing Release build"
fi

: >"$ARGS_FILE"
if RELEASE_BUILD_ARGS_FILE="$ARGS_FILE" \
  RELEASE_BUILD_ENV_FILE="$ENV_FILE" \
  RELEASE_BUILD_STUB_BIN_DIR="$TMP_DIR/.build/arm64-apple-macosx/debug" \
  PATH="$BIN_DIR:$PATH" \
  SWIFT_BUILD_HOME="$TMP_DIR/swift-home-wrong-path" \
  bash "$ROOT_DIR/script/check_swift_release_build.sh" >/dev/null 2>&1; then
  fail "gate accepted a Debug binary directory as Release output"
fi

FIXTURE_ROOT="$TMP_DIR/package-project"
FIXTURE_BIN="$TMP_DIR/package-bin"
PACKAGE_CALLS="$TMP_DIR/package-calls"
mkdir -p \
  "$FIXTURE_ROOT/script" \
  "$FIXTURE_ROOT/Packaging" \
  "$FIXTURE_ROOT/BrowserExtension/Firefox" \
  "$FIXTURE_ROOT/Sources/PersonalSitePublisherMac/Resources/en.lproj" \
  "$FIXTURE_ROOT/Sources/PersonalSitePublisherMac/Resources/zh-Hans.lproj" \
  "$FIXTURE_BIN"
cp "$ROOT_DIR/script/build_and_run.sh" "$FIXTURE_ROOT/script/build_and_run.sh"
cp "$ROOT_DIR/script/check_build_version.sh" "$FIXTURE_ROOT/script/check_build_version.sh"
printf '#!/usr/bin/env python3\nraise SystemExit(0)\n' \
  >"$FIXTURE_ROOT/script/generate_browser_extension_protocol.py"
printf '#!/usr/bin/env bash\nexit 0\n' >"$FIXTURE_ROOT/script/sync_firefox_browser_extension.sh"
chmod +x "$FIXTURE_ROOT/script/sync_firefox_browser_extension.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$FIXTURE_ROOT/script/sync_safari_browser_extension.sh"
chmod +x "$FIXTURE_ROOT/script/sync_safari_browser_extension.sh"
cat >"$FIXTURE_ROOT/script/build_safari_web_extension.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
product="$root_dir/.build/safari-web-extension/product/RepoPressSafariExtension.appex"
mkdir -p "$product/Contents/MacOS" "$product/Contents/Resources"
printf 'fixture Safari extension\n' >"$product/Contents/MacOS/RepoPressSafariExtension"
chmod +x "$product/Contents/MacOS/RepoPressSafariExtension"
printf '{"manifest_version":3,"version":"0.30.0"}\n' \
  >"$product/Contents/Resources/manifest.json"
STUB
chmod +x "$FIXTURE_ROOT/script/build_safari_web_extension.sh"
cat >"$FIXTURE_ROOT/script/firefox_extension_release.py" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FIREFOX_RELEASE_STUB_CALLS"
[[ "${FIREFOX_RELEASE_STUB_FAIL:-0}" != "1" ]] || exit 23
command_name="${1:-}"
shift || true
case "$command_name" in
  verify-signed)
    while [[ "$#" -gt 0 ]]; do
      if [[ "$1" == "--signed-xpi" ]]; then
        [[ -f "$2" ]] || exit 24
        break
      fi
      shift
    done
    ;;
  updates)
    output=""
    while [[ "$#" -gt 0 ]]; do
      if [[ "$1" == "--output" ]]; then
        output="$2"
        break
      fi
      shift
    done
    [[ -n "$output" ]] || exit 25
    mkdir -p "$(dirname "$output")"
    printf '{"fixture":true}\n' >"$output"
    ;;
  verify-updates)
    ;;
  *)
    exit 26
    ;;
esac
STUB
chmod +x "$FIXTURE_ROOT/script/firefox_extension_release.py"
printf '{"manifest_version":3}\n' >"$FIXTURE_ROOT/BrowserExtension/manifest.json"
printf '{"manifest_version":3,"version":"0.12.0"}\n' >"$FIXTURE_ROOT/BrowserExtension/Firefox/manifest.json"
printf '%s\n' \
  'MARKETING_VERSION = 1.2.3' \
  'CURRENT_PROJECT_VERSION = 42' \
  >"$FIXTURE_ROOT/Packaging/BuildVersion.xcconfig"
printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>' \
  >"$FIXTURE_ROOT/Packaging/LocalDevelopment.entitlements"
printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<plist version="1.0"><dict/></plist>' \
  >"$FIXTURE_ROOT/Packaging/DirectDistribution.entitlements"
printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>' \
  >"$FIXTURE_ROOT/Sources/PersonalSitePublisherMac/AppStore.entitlements"
printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>' \
  >"$FIXTURE_ROOT/Packaging/SafariWebExtension.entitlements"
printf 'fixture icon\n' >"$FIXTURE_ROOT/Sources/PersonalSitePublisherMac/Resources/AppIcon.icns"
printf '{"sourceLanguage":"en","strings":{},"version":"1.0"}\n' \
  >"$FIXTURE_ROOT/Sources/PersonalSitePublisherMac/Resources/Localizable.xcstrings"
for language in en zh-Hans; do
  printf '"CFBundleDisplayName" = "Fixture";\n"CFBundleName" = "Fixture";\n' \
    >"$FIXTURE_ROOT/Sources/PersonalSitePublisherMac/Resources/$language.lproj/InfoPlist.strings"
done

cat >"$FIXTURE_BIN/swift" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
configuration="debug"
previous=""
for argument in "$@"; do
  if [[ "$previous" == "-c" ]]; then
    configuration="$argument"
  fi
  previous="$argument"
done
reported_configuration="$configuration"
if [[ "${PACKAGE_STUB_FORCE_DEBUG_PATH:-0}" == "1" && "$configuration" == "release" ]]; then
  reported_configuration="debug"
fi
bin_dir="$PACKAGE_STUB_BUILD_ROOT/arm64-apple-macosx/$reported_configuration"
printf '%s\t%s\n' "$configuration" "$*" >>"$PACKAGE_STUB_CALLS"
if [[ " $* " == *" --show-bin-path "* ]]; then
  printf '%s\n' "$bin_dir"
  exit 0
fi
mkdir -p "$PACKAGE_STUB_BUILD_ROOT/arm64-apple-macosx/$configuration"
mkdir -p "$PACKAGE_STUB_BUILD_ROOT/arm64-apple-macosx/$configuration/PersonalSitePublisherMac_PublishingWorkbenchCore.bundle"
printf 'fixture-%s-binary\n' "$configuration" \
  >"$PACKAGE_STUB_BUILD_ROOT/arm64-apple-macosx/$configuration/PersonalSitePublisherMac"
chmod +x "$PACKAGE_STUB_BUILD_ROOT/arm64-apple-macosx/$configuration/PersonalSitePublisherMac"
printf 'fixture-%s-native-host\n' "$configuration" \
  >"$PACKAGE_STUB_BUILD_ROOT/arm64-apple-macosx/$configuration/KnowledgeNativeMessagingHost"
chmod +x "$PACKAGE_STUB_BUILD_ROOT/arm64-apple-macosx/$configuration/KnowledgeNativeMessagingHost"
STUB
chmod +x "$FIXTURE_BIN/swift"

cat >"$FIXTURE_BIN/xcrun" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
output_directory=""
previous=""
for argument in "$@"; do
  if [[ "$previous" == "--output-directory" ]]; then
    output_directory="$argument"
  fi
  previous="$argument"
done
[[ -z "$output_directory" ]] || mkdir -p "$output_directory"
STUB
chmod +x "$FIXTURE_BIN/xcrun"

cat >"$FIXTURE_BIN/codesign-direct" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$DIRECT_CODE_SIGN_CALLS"
STUB
chmod +x "$FIXTURE_BIN/codesign-direct"

cat >"$FIXTURE_BIN/security-direct" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${DIRECT_SECURITY_IDENTITY_KIND:-developer-id}" == "apple-development" ]]; then
  printf '%s\n' '  1) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Apple Development: Fixture Publisher (TEAM123456)"'
else
  printf '%s\n' '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Fixture Publisher (TEAM123456)"'
fi
printf '%s\n' '     1 valid identities found'
STUB
chmod +x "$FIXTURE_BIN/security-direct"

run_package_fixture() {
  PATH="$FIXTURE_BIN:$PATH" \
  SWIFT_BUILD_HOME="$TMP_DIR/package-swift-home" \
  PACKAGE_STUB_BUILD_ROOT="$FIXTURE_ROOT/.build" \
  PACKAGE_STUB_CALLS="$PACKAGE_CALLS" \
  FIREFOX_RELEASE_STUB_CALLS="$FIREFOX_RELEASE_CALLS" \
    bash "$FIXTURE_ROOT/script/build_and_run.sh" "$@" >/dev/null
}

: >"$PACKAGE_CALLS"
: >"$FIREFOX_RELEASE_CALLS"
run_package_fixture --package-only
debug_source="$FIXTURE_ROOT/.build/arm64-apple-macosx/debug/PersonalSitePublisherMac"
packaged_binary="$FIXTURE_ROOT/dist/PersonalSitePublisherMac.app/Contents/MacOS/PersonalSitePublisherMac"
cmp -s "$debug_source" "$packaged_binary" || fail "default package did not copy the Debug binary"
debug_configuration="$(/usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherBuildConfiguration' "$FIXTURE_ROOT/dist/PersonalSitePublisherMac.app/Contents/Info.plist")"
[[ "$debug_configuration" == "Debug" ]] || fail "default package did not record Debug configuration"
[[ -d "$FIXTURE_ROOT/dist/PersonalSitePublisherMac.app/Contents/Resources/BrowserExtension" ]] \
  || fail "direct package omitted browser-extension assets"
[[ -d "$FIXTURE_ROOT/dist/PersonalSitePublisherMac.app/Contents/PlugIns/RepoPressSafariExtension.appex" ]] \
  || fail "direct package omitted the Safari Web Extension"
[[ -x "$FIXTURE_ROOT/dist/PersonalSitePublisherMac.app/Contents/MacOS/KnowledgeNativeMessagingHost" ]] \
  || fail "direct package omitted Firefox native messaging host"
debug_firefox_signed="$(/usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherFirefoxSignedPackageAvailable' "$FIXTURE_ROOT/dist/PersonalSitePublisherMac.app/Contents/Info.plist")"
[[ "$debug_firefox_signed" == "false" ]] || fail "Debug package falsely claimed a signed Firefox XPI"
[[ ! -e "$FIXTURE_ROOT/dist/PersonalSitePublisherMac.app/Contents/Resources/BrowserExtension/Release" ]] \
  || fail "Debug package created a Firefox Release directory without a signed XPI"
direct_channel="$(/usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherDistributionChannel' "$FIXTURE_ROOT/dist/PersonalSitePublisherMac.app/Contents/Info.plist")"
[[ "$direct_channel" == "Direct" ]] || fail "default package did not record the Direct distribution channel"

: >"$PACKAGE_CALLS"
: >"$FIREFOX_RELEASE_CALLS"
if run_package_fixture --package-only --configuration release 2>/dev/null; then
  fail "Direct Release packaging accepted a missing signed Firefox XPI"
fi
mkdir -p "$FIXTURE_ROOT/dist/browser-extension"
printf 'fixture signed XPI\n' \
  >"$FIXTURE_ROOT/dist/browser-extension/knowledge-capture-firefox-.xpi"
firefox_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version", ""))' "$FIXTURE_ROOT/BrowserExtension/Firefox/manifest.json")"
mv "$FIXTURE_ROOT/dist/browser-extension/knowledge-capture-firefox-.xpi" \
  "$FIXTURE_ROOT/dist/browser-extension/knowledge-capture-firefox-$firefox_version.xpi"
run_package_fixture --package-only --configuration release
release_source="$FIXTURE_ROOT/.build/arm64-apple-macosx/release/PersonalSitePublisherMac"
cmp -s "$release_source" "$packaged_binary" || fail "Release package did not copy the Release binary"
release_configuration="$(/usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherBuildConfiguration' "$FIXTURE_ROOT/dist/PersonalSitePublisherMac.app/Contents/Info.plist")"
[[ "$release_configuration" == "Release" ]] || fail "Release package did not record Release configuration"
grep -q $'^release\t.*-c release.*--product PersonalSitePublisherMac' "$PACKAGE_CALLS" \
  || fail "Release package did not pass the Release configuration to SwiftPM"
release_firefox_signed="$(/usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherFirefoxSignedPackageAvailable' "$FIXTURE_ROOT/dist/PersonalSitePublisherMac.app/Contents/Info.plist")"
[[ "$release_firefox_signed" == "true" ]] || fail "Direct Release package did not record its signed Firefox XPI"
release_firefox_dir="$FIXTURE_ROOT/dist/PersonalSitePublisherMac.app/Contents/Resources/BrowserExtension/Release"
[[ -f "$release_firefox_dir/knowledge-capture-firefox-$firefox_version.xpi" ]] \
  || fail "Direct Release package omitted the verified signed Firefox XPI"
[[ -f "$release_firefox_dir/updates.json" ]] \
  || fail "Direct Release package omitted the Firefox update manifest"
grep -Fq "verify-signed --signed-xpi" "$FIREFOX_RELEASE_CALLS" \
  || fail "Direct Release package did not verify the signed Firefox XPI"
grep -Fq "verify-updates --signed-xpi" "$FIREFOX_RELEASE_CALLS" \
  || fail "Direct Release package did not verify its bundled Firefox update manifest"

if FIREFOX_RELEASE_STUB_FAIL=1 run_package_fixture --package-only --configuration release 2>/dev/null; then
  fail "Direct Release packaging accepted a Firefox signature verification failure"
fi

: >"$DIRECT_CODE_SIGN_CALLS"
DIRECT_DISTRIBUTION_BUILD=1 \
CODE_SIGN_IDENTITY="Developer ID Application: Fixture Publisher (TEAM123456)" \
CODESIGN_TOOL="$FIXTURE_BIN/codesign-direct" \
SECURITY_TOOL="$FIXTURE_BIN/security-direct" \
DIRECT_CODE_SIGN_CALLS="$DIRECT_CODE_SIGN_CALLS" \
  run_package_fixture --package-only --release
direct_hardened_runtime="$(/usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherHardenedRuntimeEnabled' "$FIXTURE_ROOT/dist/PersonalSitePublisherMac.app/Contents/Info.plist")"
[[ "$direct_hardened_runtime" == "true" ]] \
  || fail "Developer ID package did not record Hardened Runtime evidence"
runtime_sign_count="$(grep -c -- '--options runtime' "$DIRECT_CODE_SIGN_CALLS")"
[[ "$runtime_sign_count" == "3" ]] \
  || fail "Developer ID package did not enable Hardened Runtime on app, native host, and Safari extension"
timestamp_sign_count="$(grep -c -- '--timestamp' "$DIRECT_CODE_SIGN_CALLS")"
[[ "$timestamp_sign_count" == "3" ]] \
  || fail "Developer ID package did not request secure timestamps for app, native host, and Safari extension"
grep -Fq -- "--entitlements $FIXTURE_ROOT/Packaging/DirectDistribution.entitlements" "$DIRECT_CODE_SIGN_CALLS" \
  || fail "Developer ID package omitted the dedicated Direct entitlements"

if DIRECT_DISTRIBUTION_BUILD=1 \
  CODESIGN_TOOL="$FIXTURE_BIN/codesign-direct" \
  SECURITY_TOOL="$FIXTURE_BIN/security-direct" \
  DIRECT_CODE_SIGN_CALLS="$DIRECT_CODE_SIGN_CALLS" \
    run_package_fixture --package-only --release 2>/dev/null; then
  fail "Developer ID mode accepted a missing explicit signing identity"
fi
if DIRECT_DISTRIBUTION_BUILD=1 \
  CODE_SIGN_IDENTITY="Apple Development: Fixture Publisher (TEAM123456)" \
  CODESIGN_TOOL="$FIXTURE_BIN/codesign-direct" \
  SECURITY_TOOL="$FIXTURE_BIN/security-direct" \
  DIRECT_SECURITY_IDENTITY_KIND="apple-development" \
  DIRECT_CODE_SIGN_CALLS="$DIRECT_CODE_SIGN_CALLS" \
    run_package_fixture --package-only --release 2>/dev/null; then
  fail "Developer ID mode accepted an Apple Development identity"
fi
if DIRECT_DISTRIBUTION_BUILD=1 \
  CODE_SIGN_IDENTITY="Developer ID Application: Fixture Publisher (TEAM123456)" \
  CODESIGN_TOOL="$FIXTURE_BIN/codesign-direct" \
  SECURITY_TOOL="$FIXTURE_BIN/security-direct" \
  DIRECT_CODE_SIGN_CALLS="$DIRECT_CODE_SIGN_CALLS" \
    run_package_fixture --package-only --configuration debug 2>/dev/null; then
  fail "Developer ID mode accepted a Debug build"
fi

: >"$PACKAGE_CALLS"
run_package_fixture --package-only --app-store
app_store_configuration="$(/usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherBuildConfiguration' "$FIXTURE_ROOT/dist/PersonalSitePublisherMac.app/Contents/Info.plist")"
[[ "$app_store_configuration" == "Release" ]] || fail "App Store package did not record Release configuration"
app_store_channel="$(/usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherDistributionChannel' "$FIXTURE_ROOT/dist/PersonalSitePublisherMac.app/Contents/Info.plist")"
[[ "$app_store_channel" == "AppStore" ]] || fail "App Store package did not record its distribution channel"
uses_non_exempt_encryption="$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$FIXTURE_ROOT/dist/PersonalSitePublisherMac.app/Contents/Info.plist")"
[[ "$uses_non_exempt_encryption" == "false" ]] || fail "App Store package did not declare the audited exempt-encryption boundary"
browser_extension_available="$(/usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherBrowserExtensionAvailable' "$FIXTURE_ROOT/dist/PersonalSitePublisherMac.app/Contents/Info.plist")"
[[ "$browser_extension_available" == "false" ]] || fail "App Store package did not disable the browser extension"
app_store_firefox_signed="$(/usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherFirefoxSignedPackageAvailable' "$FIXTURE_ROOT/dist/PersonalSitePublisherMac.app/Contents/Info.plist")"
[[ "$app_store_firefox_signed" == "false" ]] || fail "App Store package claimed a bundled Firefox XPI"
core_resource_info="$FIXTURE_ROOT/dist/PersonalSitePublisherMac.app/Contents/Resources/PersonalSitePublisherMac_PublishingWorkbenchCore.bundle/Info.plist"
core_resource_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$core_resource_info")"
[[ "$core_resource_bundle_id" == "com.jinfang.PersonalSitePublisherMac.PublishingWorkbenchCoreResources" ]] \
  || fail "App Store package did not assign the Core resource bundle identifier"
core_resource_package_type="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$core_resource_info")"
[[ "$core_resource_package_type" == "BNDL" ]] \
  || fail "App Store package did not identify the Core resource bundle as BNDL"
[[ ! -e "$FIXTURE_ROOT/dist/PersonalSitePublisherMac.app/Contents/Resources/BrowserExtension" ]] \
  || fail "App Store package contained unpacked browser-extension assets"
[[ ! -e "$FIXTURE_ROOT/dist/PersonalSitePublisherMac.app/Contents/MacOS/KnowledgeNativeMessagingHost" ]] \
  || fail "App Store package contained the direct-distribution native messaging host"
[[ -d "$FIXTURE_ROOT/dist/PersonalSitePublisherMac.app/Contents/PlugIns/RepoPressSafariExtension.appex" ]] \
  || fail "App Store package omitted the Safari Web Extension"
grep -Fq "APP_STORE_BUILD" "$PACKAGE_CALLS" \
  || fail "App Store package did not pass the APP_STORE_BUILD compile condition"

if PATH="$FIXTURE_BIN:$PATH" \
  SWIFT_BUILD_HOME="$TMP_DIR/package-swift-home-wrong-path" \
  PACKAGE_STUB_BUILD_ROOT="$FIXTURE_ROOT/.build" \
  PACKAGE_STUB_CALLS="$PACKAGE_CALLS" \
  PACKAGE_STUB_FORCE_DEBUG_PATH=1 \
    bash "$FIXTURE_ROOT/script/build_and_run.sh" --package-only --release >/dev/null 2>&1; then
  fail "Release packaging accepted a Debug binary directory"
fi

for gate in check_app_store_metadata.sh check_app_store_archive_readiness.sh; do
  grep -Fq 'build_and_run.sh" --package-only --app-store' "$ROOT_DIR/script/$gate" \
    || fail "$gate does not force a fresh App Store Release package"
  grep -Fq 'PersonalSitePublisherBuildConfiguration' "$ROOT_DIR/script/$gate" \
    || fail "$gate does not verify Release configuration evidence"
done
grep -Fq 'build_and_run.sh" --package-only --app-store' "$ROOT_DIR/script/record_app_store_build_metadata_evidence.sh" \
  || fail "build metadata recorder does not create an App Store Release package when missing"
grep -Fq 'PersonalSitePublisherBuildConfiguration' "$ROOT_DIR/script/record_app_store_build_metadata_evidence.sh" \
  || fail "build metadata recorder does not reject Debug bundle evidence"

all_checks="$(bash "$ROOT_DIR/script/check_release_gate.sh" --list)"
grep -q $'^swift-release-build\talways\t' <<<"$all_checks" \
  || fail "shared release manifest omitted the Release build"
if grep -q $'^swift-release-build-tests\t' <<<"$all_checks"; then
  fail "normal release gate still duplicates release-tooling behavior tests"
fi
tooling_checks="$(bash "$ROOT_DIR/script/check_release_gate.sh" --tooling --list)"
grep -q $'^swift-release-build-tests\talways\t' <<<"$tooling_checks" \
  || fail "shared release manifest omitted Release build behavior tests"

quick_checks="$(bash "$ROOT_DIR/script/check_release_gate.sh" --quick --list)"
if grep -q $'^swift-release-build\t' <<<"$quick_checks"; then
  fail "quick gate unexpectedly runs the expensive Release build"
fi
if grep -q $'^app-store-metadata\t' <<<"$quick_checks"; then
  fail "quick gate unexpectedly packages a Release bundle through the metadata gate"
fi

app_store_checks="$(bash "$ROOT_DIR/script/check_release_gate.sh" --profile app-store --list)"
grep -q $'^archive-readiness-strict\tstrict\t' <<<"$app_store_checks" \
  || fail "App Store profile omitted strict archive readiness"
if grep -Eq '^(chrome-extension-store-readiness|direct-release-notarization-readiness)\t' <<<"$app_store_checks"; then
  fail "App Store profile included another distribution channel"
fi

direct_checks="$(bash "$ROOT_DIR/script/check_release_gate.sh" --profile direct --list)"
grep -q $'^direct-release-notarization-readiness\tstrict\t' <<<"$direct_checks" \
  || fail "direct profile omitted notarization readiness"
if grep -Eq '^(archive-readiness-strict|chrome-extension-store-readiness)\t' <<<"$direct_checks"; then
  fail "direct profile included another distribution channel"
fi

chrome_checks="$(bash "$ROOT_DIR/script/check_release_gate.sh" --profile chrome --list)"
grep -q $'^chrome-extension-store-readiness\tstrict\t' <<<"$chrome_checks" \
  || fail "Chrome profile omitted Chrome Web Store readiness"
if grep -Eq '^(archive-readiness-strict|direct-release-notarization-readiness)\t' <<<"$chrome_checks"; then
  fail "Chrome profile included another distribution channel"
fi

if bash "$ROOT_DIR/script/check_release_gate.sh" --profile edge --list >/dev/null 2>&1; then
  fail "deferred Edge channel still has a release profile"
fi
if bash "$ROOT_DIR/script/check_release_gate.sh" --profile firefox --list >/dev/null 2>&1; then
  fail "deferred Firefox channel still has a release profile"
fi

all_profile_checks="$(bash "$ROOT_DIR/script/check_release_gate.sh" --profile all --list)"
strict_alias_checks="$(bash "$ROOT_DIR/script/check_release_gate.sh" --strict --list)"
[[ "$all_profile_checks" == "$strict_alias_checks" ]] \
  || fail "--strict is no longer an exact compatibility alias for --profile all"

echo "swift release build gate test: passed"
