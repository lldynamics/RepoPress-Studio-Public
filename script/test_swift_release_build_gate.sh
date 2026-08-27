#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mac-editor-swift-release.XXXXXX" 2>/dev/null || mktemp -d "$ROOT_DIR/.build/tmp/mac-editor-swift-release.XXXXXX")"
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
printf '<call>\n%s\n' "$@" >>"$RELEASE_BUILD_ARGS_FILE"
printf '%s\n' "$HOME" "$XDG_CACHE_HOME" "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULE_CACHE_PATH" \
  >"$RELEASE_BUILD_ENV_FILE"
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
grep -Fxq "release" "$ARGS_FILE" || fail "gate omitted release configuration"
grep -Fxq -- "--disable-sandbox" "$ARGS_FILE" || fail "gate omitted --disable-sandbox"
grep -Fxq "PersonalSitePublisherMac" "$ARGS_FILE" || fail "gate omitted the app product"
if grep -Fq "KnowledgeNativeMessagingHost" "$ARGS_FILE"; then
  fail "gate still builds the deleted Native Messaging host"
fi
grep -Fxq -- "--show-bin-path" "$ARGS_FILE" \
  || fail "gate did not verify the Release binary directory"
grep -Fq "$TMP_DIR/swift-home" "$ENV_FILE" \
  || fail "gate did not isolate Swift build caches"

if RELEASE_BUILD_ARGS_FILE="$ARGS_FILE" \
  RELEASE_BUILD_ENV_FILE="$ENV_FILE" \
  RELEASE_BUILD_STUB_BIN_DIR="$TMP_DIR/.build/arm64-apple-macosx/release" \
  RELEASE_BUILD_STUB_EXIT=19 \
  PATH="$BIN_DIR:$PATH" \
  SWIFT_BUILD_HOME="$TMP_DIR/swift-home-failure" \
  bash "$ROOT_DIR/script/check_swift_release_build.sh" >/dev/null 2>&1; then
  fail "gate accepted a failing Release build"
fi

for path in \
  "$ROOT_DIR/Package.swift" \
  "$ROOT_DIR/script/build_and_run.sh" \
  "$ROOT_DIR/script/release_checks.json"; do
  if grep -Eq 'KnowledgeNativeMessagingHost' "$path"; then
    fail "${path#$ROOT_DIR/} still exposes the deleted Native Messaging host"
  fi
done
[[ -f "$ROOT_DIR/Packaging/DirectDistribution.entitlements" ]] \
  || fail "DirectDistribution.entitlements is missing"
[[ -x "$ROOT_DIR/script/package_direct_release.sh" ]] \
  || fail "Developer ID packaging entrypoint is missing"
grep -Fq 'DIRECT_DISTRIBUTION_BUILD' "$ROOT_DIR/script/build_and_run.sh" \
  || fail "build_and_run.sh does not expose the Direct Release packaging channel"
grep -Fq 'DISTRIBUTION_CHANNEL="Development"' "$ROOT_DIR/script/build_and_run.sh" \
  || fail "build_and_run.sh does not expose the Development packaging channel"
grep -Fq 'DISTRIBUTION_CHANNEL="Direct"' "$ROOT_DIR/script/build_and_run.sh" \
  || fail "build_and_run.sh does not expose the Developer ID packaging channel"
if grep -Eq '^[[:space:]]*-Xswiftc[[:space:]]+(APP_STORE_BUILD|DIRECT_DISTRIBUTION_BUILD)[[:space:]]*$' \
  "$ROOT_DIR/script/build_and_run.sh"; then
  fail "distribution packaging must not change the compiled Swift capability set"
fi
if [[ -e "$ROOT_DIR/Sources/PersonalSitePublisherMac/AppStore.entitlements" ]]; then
  fail "obsolete App Store entitlements must remain deleted"
fi
for path in \
  "$ROOT_DIR/Package.swift" \
  "$ROOT_DIR/script/build_and_run.sh" \
  "$ROOT_DIR/script/check_launch_performance.sh" \
  "$ROOT_DIR/script/check_ui_runtime.sh" \
  "$ROOT_DIR/script/check_accessibility_runtime.sh" \
  "$ROOT_DIR/UITests/WorkspaceAccessibilityUITests/WorkspaceAccessibilityUITests.swift"; do
  if grep -Ein 'APP_STORE|--app-store|require-app-store|RELEASE_GATE_PROFILE[[:space:]]*=[[:space:]]*app-store' "$path"; then
    fail "${path#$ROOT_DIR/} still exposes the removed App Store build path"
  fi
done
grep -Fq 'APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"' "$ROOT_DIR/script/build_and_run.sh" \
  || fail "build_and_run.sh does not create the standard Frameworks directory"
grep -Fq 'SPARKLE_FRAMEWORK_BUNDLE="$APP_FRAMEWORKS/Sparkle.framework"' \
  "$ROOT_DIR/script/build_and_run.sh" \
  || fail "build_and_run.sh does not stage Sparkle.framework"
for notice_file in \
  NOTICE-MANIFEST.txt \
  Sparkle-LICENSE.txt \
  TreeSitter-LICENSE.txt \
  Tiktoken-Encoding-Data.txt; do
  [[ -s "$ROOT_DIR/Packaging/ThirdPartyNotices/$notice_file" ]] \
    || fail "bundled third-party notice is missing: $notice_file"
  grep -Fq "\"$notice_file\"" "$ROOT_DIR/script/build_and_run.sh" \
    || fail "build_and_run.sh does not copy $notice_file"
done
grep -Fq 'cmp -s "$notice_source" "$notice_bundle"' \
  "$ROOT_DIR/script/build_and_run.sh" \
  || fail "build_and_run.sh does not verify copied third-party notices"
grep -Fq 'APP_BUNDLE_NAME="${PERSONAL_SITE_PUBLISHER_BUNDLE_NAME:-$APP_DISPLAY_NAME}"' \
  "$ROOT_DIR/script/build_and_run.sh" \
  || fail "build_and_run.sh does not derive the bundle path from the display name"
if grep -Fq 'PersonalSitePublisherMac.app' "$ROOT_DIR/script/build_and_run.sh"; then
  fail "build_and_run.sh still uses the legacy executable-named app bundle"
fi
grep -Fq 'SUEnableInstallerLauncherService' "$ROOT_DIR/script/build_and_run.sh" \
  || fail "Direct Release Info.plist omits Sparkle installer launcher support"
if [[ -e "$ROOT_DIR/Packaging/CodexRuntime" ]]; then
  fail "obsolete bundled Codex runtime packaging directory still exists"
fi
for path in \
  "$ROOT_DIR/script/build_and_run.sh" \
  "$ROOT_DIR/Sources/PublishingWorkbenchCore/Services/CodexAppServerClient.swift"; do
  if grep -Eq 'CodexRuntime|REPOPRESS_CODEX_RUNTIME_PATH|REPOPRESS_CODEX_LICENSE_PATH' "$path"; then
    fail "${path#$ROOT_DIR/} still exposes bundled Codex runtime packaging"
  fi
done
grep -Fq 'build_arguments=(--package-only --release)' "$ROOT_DIR/script/check_ui_runtime.sh" \
  || fail "packaged UI artifact gate does not build a Release app bundle"
grep -Fq 'packaged app must use the Release configuration' "$ROOT_DIR/script/check_ui_runtime.sh" \
  || fail "packaged UI artifact gate does not verify its embedded build configuration"

# Release performance and XCUI tooling may opt into capture-only compilation,
# while ordinary run/package builds must keep that code path disabled.
grep -Fq 'if [[ "${PERSONAL_SITE_PUBLISHER_CAPTURE_BUILD:-0}" == "1" ]]; then' \
  "$ROOT_DIR/script/build_and_run.sh" \
  || fail "ordinary run/package builds do not retain the capture-build default-off path"
if grep -Eq -- '--screenshot-demo|--screenshot-surface|--list-screenshot-surfaces' \
  "$ROOT_DIR/script/build_and_run.sh"; then
  fail "build_and_run.sh still exposes the removed App Store screenshot demo mode"
fi

chrome_checks="$(bash "$ROOT_DIR/script/check_release_gate.sh" --profile chrome --list)"
grep -q $'^chrome-extension-store-readiness\tstrict\t' <<<"$chrome_checks" \
  || fail "Chrome profile omitted Chrome Web Store readiness"

direct_checks="$(bash "$ROOT_DIR/script/check_release_gate.sh" --profile direct --list)"
grep -q $'^direct-release-package-path\talways\t' <<<"$direct_checks" \
  || fail "Direct profile omitted the Developer ID package workflow"
grep -q $'^swift-coverage\tstandard\t' <<<"$direct_checks" \
  || fail "Direct profile omitted the standard coverage gate"
grep -q $'^release-performance\tstandard\t' <<<"$direct_checks" \
  || fail "Direct profile omitted the standard performance gate"
grep -q $'^direct-release-notarization-readiness\tstrict\t' <<<"$direct_checks" \
  || fail "Direct profile omitted signed/notarized artifact validation"
if grep -Eq '^chrome-extension-store-readiness\t' \
  <<<"$direct_checks"; then
  fail "Direct profile included a Chrome-only release check"
fi

for removed_profile in edge firefox; do
  if bash "$ROOT_DIR/script/check_release_gate.sh" \
    --profile "$removed_profile" --list >/dev/null 2>&1; then
    fail "removed $removed_profile channel still has a release profile"
  fi
done

all_profile_checks="$(bash "$ROOT_DIR/script/check_release_gate.sh" --profile all --list)"
strict_alias_checks="$(bash "$ROOT_DIR/script/check_release_gate.sh" --strict --list)"
[[ "$all_profile_checks" == "$strict_alias_checks" ]] \
  || fail "--strict is no longer an exact compatibility alias for --profile all"

echo "swift release build gate test: passed"
