#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT_DIR/script/check_accessibility_runtime.sh"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-app-store-ui-regression.XXXXXX)"
APP_PATH="$TMP_DIR/RepoPress Studio.app"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
ARGUMENT_LOG="$TMP_DIR/xcodebuild-arguments.log"
APP_PATH_LOG="$TMP_DIR/xcodebuild-app-path.log"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "App Store UI regression gate test: $*" >&2
  exit 1
}

mkdir -p "$APP_PATH/Contents" "$TMP_DIR/bin"
plutil -create xml1 "$INFO_PLIST"
plutil -insert PersonalSitePublisherDistributionChannel -string Development "$INFO_PLIST"
plutil -insert PersonalSitePublisherBuildConfiguration -string Debug "$INFO_PLIST"
plutil -insert PersonalSitePublisherScreenshotCaptureBuild -bool false "$INFO_PLIST"

cat >"$TMP_DIR/bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"${XCODEBUILD_ARGUMENT_LOG:?}"
printf '%s\n' "${WORKBENCH_XCUI_APP_PATH:-}" >"${XCODEBUILD_APP_PATH_LOG:?}"
STUB
chmod +x "$TMP_DIR/bin/xcodebuild"

run_gate() {
  PATH="$TMP_DIR/bin:$PATH" \
    XCODEBUILD_ARGUMENT_LOG="$ARGUMENT_LOG" \
    XCODEBUILD_APP_PATH_LOG="$APP_PATH_LOG" \
    WORKBENCH_XCUI_APP_PATH="$APP_PATH" \
    bash "$CHECK" "$@"
}

assert_rejected_before_xcodebuild() {
  local expected_message="$1"
  shift
  rm -f "$ARGUMENT_LOG" "$APP_PATH_LOG"
  if output="$(run_gate "$@" 2>&1)"; then
    fail "invalid artifact unexpectedly passed: $output"
  fi
  grep -Fq "$expected_message" <<<"$output" \
    || fail "rejection omitted expected diagnostic: $expected_message"
  [[ ! -e "$ARGUMENT_LOG" ]] \
    || fail "xcodebuild ran before the App Store artifact was rejected"
}

if output="$(
  WORKBENCH_XCUI_APP_PATH="" bash "$CHECK" --require-app-store 2>&1
)"; then
  fail "App Store mode accepted a missing explicit app path: $output"
fi
grep -Fq "requires an explicit WORKBENCH_XCUI_APP_PATH" <<<"$output" \
  || fail "missing explicit app path did not produce a clear diagnostic"

assert_rejected_before_xcodebuild \
  "requires distribution channel AppStore" \
  --require-app-store

plutil -replace PersonalSitePublisherDistributionChannel -string AppStore "$INFO_PLIST"
assert_rejected_before_xcodebuild \
  "requires a Release bundle" \
  --require-app-store

plutil -replace PersonalSitePublisherBuildConfiguration -string Release "$INFO_PLIST"
plutil -replace PersonalSitePublisherScreenshotCaptureBuild -bool true "$INFO_PLIST"
assert_rejected_before_xcodebuild \
  "must not use a screenshot-capture binary" \
  --require-app-store

plutil -replace PersonalSitePublisherScreenshotCaptureBuild -bool false "$INFO_PLIST"
output="$(run_gate --require-app-store 2>&1)" \
  || fail "valid AppStore Release artifact was rejected: $output"
grep -Fq "verified explicit AppStore Release bundle before XCUITest" <<<"$output" \
  || fail "valid artifact preflight was not reported"
grep -Fxq -- \
  "-only-testing:WorkspaceAccessibilityUITests/WorkspaceAccessibilityUITests/testAppStoreEnglishMenusExposeFreeBYOKAIAndReopenMainWindow" \
  "$ARGUMENT_LOG" \
  || fail "App Store mode did not select the non-skippable App Store regression"
[[ "$(cat "$APP_PATH_LOG")" == "$APP_PATH" ]] \
  || fail "xcodebuild did not receive the preflighted app path"

run_gate >/dev/null \
  || fail "default accessibility mode rejected the existing generic test path"
if grep -Fq -- "-only-testing:" "$ARGUMENT_LOG"; then
  fail "default accessibility mode unexpectedly narrowed the generic test suite"
fi

echo "App Store UI regression gate test: passed"
