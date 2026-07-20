#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${WORKBENCH_XCUI_APP_PATH:-}"
DERIVED_DATA_PATH="${WORKBENCH_XCUI_DERIVED_DATA_PATH:-/private/tmp/PersonalSitePublisherMac-AccessibilityUITests}"

if [[ -z "$APP_PATH" ]]; then
  HOME=/private/tmp \
    XDG_CACHE_HOME=/private/tmp \
    CLANG_MODULE_CACHE_PATH=/private/tmp/clang-cache \
    "$ROOT_DIR/script/build_and_run.sh" --package-only
  APP_PATH="$ROOT_DIR/dist/PersonalSitePublisherMac.app"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "runtime accessibility gate: app bundle not found: $APP_PATH" >&2
  exit 1
fi

WORKBENCH_XCUI_APP_PATH="$APP_PATH" \
  xcodebuild \
    -project "$ROOT_DIR/UITests/WorkspaceAccessibilityUITests.xcodeproj" \
    -scheme WorkspaceAccessibilityUITests \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    test

echo "runtime accessibility gate: passed"
