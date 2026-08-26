#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${WORKBENCH_XCUI_APP_PATH:-}"
DERIVED_DATA_PATH="${WORKBENCH_XCUI_DERIVED_DATA_PATH:-/private/tmp/PersonalSitePublisherMac-AccessibilityUITests}"
RUNTIME_HOME="${PERSONAL_SITE_PUBLISHER_RUNTIME_HOME:-${HOME:?HOME is required}}"
TEST_DIST_DIR=""
TEST_BUNDLE_ID=""
NON_SCREENSHOT_REGRESSION=0
LSREGISTER_TOOL="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

usage() {
  echo "usage: check_accessibility_runtime.sh [--non-screenshot-regression]" >&2
}

case "${1:-}" in
  "")
    ;;
  --non-screenshot-regression)
    NON_SCREENSHOT_REGRESSION=1
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage
    echo "runtime accessibility gate: unknown argument: $1" >&2
    exit 2
    ;;
esac
if [[ "$#" -gt 1 ]]; then
  usage
  echo "runtime accessibility gate: expected at most one argument" >&2
  exit 2
fi
if [[ "$NON_SCREENSHOT_REGRESSION" == "1" && -z "$APP_PATH" ]]; then
  echo "runtime accessibility gate: --non-screenshot-regression requires an explicit WORKBENCH_XCUI_APP_PATH" >&2
  exit 2
fi

cleanup() {
  if [[ -n "$TEST_DIST_DIR" ]]; then
    test_app="$TEST_DIST_DIR/RepoPress Studio.app"
    test_binary="$test_app/Contents/MacOS/PersonalSitePublisherMac"
    while IFS= read -r pid; do
      [[ -z "$pid" ]] || kill "$pid" >/dev/null 2>&1 || true
    done < <(pgrep -f "^${test_binary}([[:space:]]|$)" 2>/dev/null || true)
    if [[ -x "$LSREGISTER_TOOL" ]]; then
      "$LSREGISTER_TOOL" -u "$test_app" >/dev/null 2>&1 || true
    fi
    rm -rf "$TEST_DIST_DIR"
  fi
  case "$TEST_BUNDLE_ID" in
    com.jinfang.PersonalSitePublisherMac.AccessibilityTests.*)
      # ContainerManager owns the protected metadata at the container root.
      # Remove only test-owned data and leave the system metadata shell intact.
      rm -rf "$RUNTIME_HOME/Library/Containers/$TEST_BUNDLE_ID/Data"
      ;;
  esac
}
trap cleanup EXIT

if [[ -z "$APP_PATH" ]]; then
  TEST_DIST_DIR="$(mktemp -d /private/tmp/PersonalSitePublisherMac-AccessibilityApp.XXXXXX)"
  TEST_BUNDLE_ID="com.jinfang.PersonalSitePublisherMac.AccessibilityTests.${TEST_DIST_DIR##*.}"
  build_arguments=(--package-only)
  PERSONAL_SITE_PUBLISHER_DIST_DIR="$TEST_DIST_DIR" \
    PERSONAL_SITE_PUBLISHER_CAPTURE_BUILD=1 \
    PERSONAL_SITE_PUBLISHER_BUNDLE_ID="$TEST_BUNDLE_ID" \
    "$ROOT_DIR/script/build_and_run.sh" "${build_arguments[@]}"
  APP_PATH="$TEST_DIST_DIR/RepoPress Studio.app"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "runtime accessibility gate: app bundle not found: $APP_PATH" >&2
  exit 1
fi

if [[ "$NON_SCREENSHOT_REGRESSION" == "1" ]]; then
  info_plist="$APP_PATH/Contents/Info.plist"
  [[ -f "$info_plist" ]] || {
    echo "runtime accessibility gate: packaged app Info.plist is missing: $info_plist" >&2
    exit 1
  }
  plutil -lint "$info_plist" >/dev/null || {
    echo "runtime accessibility gate: packaged app Info.plist is invalid" >&2
    exit 1
  }
  build_configuration="$(
    /usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherBuildConfiguration' \
      "$info_plist" 2>/dev/null || true
  )"
  screenshot_capture_build="$(
    /usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherScreenshotCaptureBuild' \
      "$info_plist" 2>/dev/null || true
  )"
  [[ "$build_configuration" == "Release" ]] || {
    echo "runtime accessibility gate: packaged UI regression requires a Release bundle, got: ${build_configuration:-missing}" >&2
    exit 1
  }
  [[ "$screenshot_capture_build" == "false" ]] || {
    echo "runtime accessibility gate: packaged UI regression must not use a screenshot-capture binary" >&2
    exit 1
  }
  echo "runtime accessibility gate: verified explicit non-screenshot Release bundle before XCUITest"
fi

xcodebuild_arguments=(
  -project "$ROOT_DIR/UITests/WorkspaceAccessibilityUITests.xcodeproj"
  -scheme WorkspaceAccessibilityUITests
  -destination "platform=macOS"
  -derivedDataPath "$DERIVED_DATA_PATH"
  WORKBENCH_XCUI_APP_PATH="$APP_PATH"
  PERSONAL_SITE_PUBLISHER_RUNTIME_HOME="$RUNTIME_HOME"
)
if [[ "$NON_SCREENSHOT_REGRESSION" == "1" ]]; then
  xcodebuild_arguments+=(
    "-only-testing:WorkspaceAccessibilityUITests/WorkspaceAccessibilityUITests/testReleaseBundleLaunchesWithoutScreenshotFixture"
  )
elif [[ "${WORKBENCH_XCUI_RETRY_FAILURES:-0}" == "1" ]]; then
  # The complete macOS UI suite has occasionally lost one synthetic navigation
  # event on hosted runners even though the same test passes in isolation. Retry
  # only the failed case once, in a fresh test-runner process, instead of
  # rebuilding the app and rerunning the entire suite.
  xcodebuild_arguments+=(
    -retry-tests-on-failure
    -test-iterations 2
    -test-repetition-relaunch-enabled YES
  )
fi

HOME="$RUNTIME_HOME" \
  PERSONAL_SITE_PUBLISHER_RUNTIME_HOME="$RUNTIME_HOME" \
  WORKBENCH_XCUI_APP_PATH="$APP_PATH" \
  xcodebuild "${xcodebuild_arguments[@]}" test

if [[ "$NON_SCREENSHOT_REGRESSION" == "1" ]]; then
  echo "runtime accessibility gate: non-screenshot Release regression passed"
else
  echo "runtime accessibility gate: passed"
fi
