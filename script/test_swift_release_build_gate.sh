#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-swift-release.XXXXXX)"
BIN_DIR="$TMP_DIR/bin"
ARGS_FILE="$TMP_DIR/args"
ENV_FILE="$TMP_DIR/env"

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
  "$FIXTURE_ROOT/Sources/PersonalSitePublisherMac/Resources/en.lproj" \
  "$FIXTURE_ROOT/Sources/PersonalSitePublisherMac/Resources/zh-Hans.lproj" \
  "$FIXTURE_BIN"
cp "$ROOT_DIR/script/build_and_run.sh" "$FIXTURE_ROOT/script/build_and_run.sh"
cp "$ROOT_DIR/script/check_build_version.sh" "$FIXTURE_ROOT/script/check_build_version.sh"
printf '%s\n' \
  'MARKETING_VERSION = 1.2.3' \
  'CURRENT_PROJECT_VERSION = 42' \
  >"$FIXTURE_ROOT/Packaging/BuildVersion.xcconfig"
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
printf 'fixture-%s-binary\n' "$configuration" \
  >"$PACKAGE_STUB_BUILD_ROOT/arm64-apple-macosx/$configuration/PersonalSitePublisherMac"
chmod +x "$PACKAGE_STUB_BUILD_ROOT/arm64-apple-macosx/$configuration/PersonalSitePublisherMac"
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

run_package_fixture() {
  PATH="$FIXTURE_BIN:$PATH" \
  SWIFT_BUILD_HOME="$TMP_DIR/package-swift-home" \
  PACKAGE_STUB_BUILD_ROOT="$FIXTURE_ROOT/.build" \
  PACKAGE_STUB_CALLS="$PACKAGE_CALLS" \
    bash "$FIXTURE_ROOT/script/build_and_run.sh" "$@" >/dev/null
}

: >"$PACKAGE_CALLS"
run_package_fixture --package-only
debug_source="$FIXTURE_ROOT/.build/arm64-apple-macosx/debug/PersonalSitePublisherMac"
packaged_binary="$FIXTURE_ROOT/dist/PersonalSitePublisherMac.app/Contents/MacOS/PersonalSitePublisherMac"
cmp -s "$debug_source" "$packaged_binary" || fail "default package did not copy the Debug binary"
debug_configuration="$(/usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherBuildConfiguration' "$FIXTURE_ROOT/dist/PersonalSitePublisherMac.app/Contents/Info.plist")"
[[ "$debug_configuration" == "Debug" ]] || fail "default package did not record Debug configuration"

: >"$PACKAGE_CALLS"
run_package_fixture --package-only --configuration release
release_source="$FIXTURE_ROOT/.build/arm64-apple-macosx/release/PersonalSitePublisherMac"
cmp -s "$release_source" "$packaged_binary" || fail "Release package did not copy the Release binary"
release_configuration="$(/usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherBuildConfiguration' "$FIXTURE_ROOT/dist/PersonalSitePublisherMac.app/Contents/Info.plist")"
[[ "$release_configuration" == "Release" ]] || fail "Release package did not record Release configuration"
grep -q $'^release\t.*-c release.*--product PersonalSitePublisherMac' "$PACKAGE_CALLS" \
  || fail "Release package did not pass the Release configuration to SwiftPM"

if PATH="$FIXTURE_BIN:$PATH" \
  SWIFT_BUILD_HOME="$TMP_DIR/package-swift-home-wrong-path" \
  PACKAGE_STUB_BUILD_ROOT="$FIXTURE_ROOT/.build" \
  PACKAGE_STUB_CALLS="$PACKAGE_CALLS" \
  PACKAGE_STUB_FORCE_DEBUG_PATH=1 \
    bash "$FIXTURE_ROOT/script/build_and_run.sh" --package-only --release >/dev/null 2>&1; then
  fail "Release packaging accepted a Debug binary directory"
fi

for gate in check_app_store_metadata.sh check_app_store_archive_readiness.sh; do
  grep -Fq 'build_and_run.sh" --package-only --release' "$ROOT_DIR/script/$gate" \
    || fail "$gate does not force a fresh Release package"
  grep -Fq 'PersonalSitePublisherBuildConfiguration' "$ROOT_DIR/script/$gate" \
    || fail "$gate does not verify Release configuration evidence"
done
grep -Fq 'build_and_run.sh" --package-only --release' "$ROOT_DIR/script/record_app_store_build_metadata_evidence.sh" \
  || fail "build metadata recorder does not create a Release package when missing"
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

echo "swift release build gate test: passed"
