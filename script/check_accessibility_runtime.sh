#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${WORKBENCH_XCUI_APP_PATH:-}"
DERIVED_DATA_PATH="${WORKBENCH_XCUI_DERIVED_DATA_PATH:-/private/tmp/PersonalSitePublisherMac-AccessibilityUITests}"
RUNTIME_HOME="${PERSONAL_SITE_PUBLISHER_RUNTIME_HOME:-${HOME:?HOME is required}}"
TEST_DIST_DIR=""

cleanup() {
  if [[ -n "$TEST_DIST_DIR" ]]; then
    test_binary="$TEST_DIST_DIR/PersonalSitePublisherMac.app/Contents/MacOS/PersonalSitePublisherMac"
    while IFS= read -r pid; do
      [[ -z "$pid" ]] || kill "$pid" >/dev/null 2>&1 || true
    done < <(pgrep -f "^${test_binary}([[:space:]]|$)" 2>/dev/null || true)
    rm -rf "$TEST_DIST_DIR"
  fi
}
trap cleanup EXIT

if [[ -z "$APP_PATH" ]]; then
  TEST_DIST_DIR="$(mktemp -d /private/tmp/PersonalSitePublisherMac-AccessibilityApp.XXXXXX)"
  build_arguments=(--package-only)
  if [[ "${RELEASE_GATE_PROFILE:-}" == "app-store" ]]; then
    build_arguments+=(--app-store)
  fi
  PERSONAL_SITE_PUBLISHER_DIST_DIR="$TEST_DIST_DIR" \
    PERSONAL_SITE_PUBLISHER_CAPTURE_BUILD=1 \
    PERSONAL_SITE_PUBLISHER_BUNDLE_ID="com.jinfang.PersonalSitePublisherMac.AccessibilityTests" \
    "$ROOT_DIR/script/build_and_run.sh" "${build_arguments[@]}"
  APP_PATH="$TEST_DIST_DIR/PersonalSitePublisherMac.app"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "runtime accessibility gate: app bundle not found: $APP_PATH" >&2
  exit 1
fi

HOME="$RUNTIME_HOME" \
  PERSONAL_SITE_PUBLISHER_RUNTIME_HOME="$RUNTIME_HOME" \
  WORKBENCH_XCUI_APP_PATH="$APP_PATH" \
  xcodebuild \
    -project "$ROOT_DIR/UITests/WorkspaceAccessibilityUITests.xcodeproj" \
    -scheme WorkspaceAccessibilityUITests \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    WORKBENCH_XCUI_APP_PATH="$APP_PATH" \
    PERSONAL_SITE_PUBLISHER_RUNTIME_HOME="$RUNTIME_HOME" \
    test

echo "runtime accessibility gate: passed"
