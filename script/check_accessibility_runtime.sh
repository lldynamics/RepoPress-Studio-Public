#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${WORKBENCH_XCUI_APP_PATH:-}"
DERIVED_DATA_PATH="${WORKBENCH_XCUI_DERIVED_DATA_PATH:-/private/tmp/PersonalSitePublisherMac-AccessibilityUITests}"
RUNTIME_HOME="${PERSONAL_SITE_PUBLISHER_RUNTIME_HOME:-${HOME:?HOME is required}}"
TEST_DIST_DIR=""
TEST_BUNDLE_ID=""
REQUIRE_APP_STORE=0
LSREGISTER_TOOL="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

usage() {
  echo "usage: check_accessibility_runtime.sh [--require-app-store]" >&2
}

case "${1:-}" in
  "")
    ;;
  --require-app-store)
    REQUIRE_APP_STORE=1
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
if [[ "$REQUIRE_APP_STORE" == "1" && -z "$APP_PATH" ]]; then
  echo "runtime accessibility gate: --require-app-store requires an explicit WORKBENCH_XCUI_APP_PATH" >&2
  exit 2
fi

cleanup() {
  if [[ -n "$TEST_DIST_DIR" ]]; then
    test_app="$TEST_DIST_DIR/PersonalSitePublisherMac.app"
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
  if [[ "${RELEASE_GATE_PROFILE:-}" == "app-store" ]]; then
    build_arguments+=(--app-store)
  fi
  PERSONAL_SITE_PUBLISHER_DIST_DIR="$TEST_DIST_DIR" \
    PERSONAL_SITE_PUBLISHER_CAPTURE_BUILD=1 \
    PERSONAL_SITE_PUBLISHER_BUNDLE_ID="$TEST_BUNDLE_ID" \
    "$ROOT_DIR/script/build_and_run.sh" "${build_arguments[@]}"
  APP_PATH="$TEST_DIST_DIR/PersonalSitePublisherMac.app"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "runtime accessibility gate: app bundle not found: $APP_PATH" >&2
  exit 1
fi

if [[ "$REQUIRE_APP_STORE" == "1" ]]; then
  info_plist="$APP_PATH/Contents/Info.plist"
  [[ -f "$info_plist" ]] || {
    echo "runtime accessibility gate: App Store app Info.plist is missing: $info_plist" >&2
    exit 1
  }
  plutil -lint "$info_plist" >/dev/null || {
    echo "runtime accessibility gate: App Store app Info.plist is invalid" >&2
    exit 1
  }
  distribution_channel="$(
    /usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherDistributionChannel' \
      "$info_plist" 2>/dev/null || true
  )"
  build_configuration="$(
    /usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherBuildConfiguration' \
      "$info_plist" 2>/dev/null || true
  )"
  screenshot_capture_build="$(
    /usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherScreenshotCaptureBuild' \
      "$info_plist" 2>/dev/null || true
  )"
  [[ "$distribution_channel" == "AppStore" ]] || {
    echo "runtime accessibility gate: App Store UI regression requires distribution channel AppStore, got: ${distribution_channel:-missing}" >&2
    exit 1
  }
  [[ "$build_configuration" == "Release" ]] || {
    echo "runtime accessibility gate: App Store UI regression requires a Release bundle, got: ${build_configuration:-missing}" >&2
    exit 1
  }
  [[ "$screenshot_capture_build" == "false" ]] || {
    echo "runtime accessibility gate: App Store UI regression must not use a screenshot-capture binary" >&2
    exit 1
  }
  echo "runtime accessibility gate: verified explicit AppStore Release bundle before XCUITest"
fi

xcodebuild_arguments=(
  -project "$ROOT_DIR/UITests/WorkspaceAccessibilityUITests.xcodeproj"
  -scheme WorkspaceAccessibilityUITests
  -destination "platform=macOS"
  -derivedDataPath "$DERIVED_DATA_PATH"
  WORKBENCH_XCUI_APP_PATH="$APP_PATH"
  PERSONAL_SITE_PUBLISHER_RUNTIME_HOME="$RUNTIME_HOME"
)
if [[ "$REQUIRE_APP_STORE" == "1" ]]; then
  xcodebuild_arguments+=(
    "-only-testing:WorkspaceAccessibilityUITests/WorkspaceAccessibilityUITests/testAppStoreEnglishMenusExposeFreeBYOKAIAndReopenMainWindow"
  )
fi

HOME="$RUNTIME_HOME" \
  PERSONAL_SITE_PUBLISHER_RUNTIME_HOME="$RUNTIME_HOME" \
  WORKBENCH_XCUI_APP_PATH="$APP_PATH" \
  xcodebuild "${xcodebuild_arguments[@]}" test

if [[ "$REQUIRE_APP_STORE" == "1" ]]; then
  echo "runtime accessibility gate: App Store UI regression passed"
else
  echo "runtime accessibility gate: passed"
fi
